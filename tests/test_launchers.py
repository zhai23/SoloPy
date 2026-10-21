"""Integration regressions against real EXEs and isolated caches (Windows only)."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--console", type=Path, default=ROOT / "dist/solopy.exe")
parser.add_argument("--gui", type=Path, default=ROOT / "dist/solopyw.exe")
OPTIONS, UNIT_ARGS = parser.parse_known_args()


class Launchers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.console, cls.gui = OPTIONS.console.resolve(), OPTIONS.gui.resolve()
        cls.work = Path(tempfile.mkdtemp(prefix="verify-", dir=ROOT / ".build"))
        cls.env = dict(os.environ, LOCALAPPDATA=str(cls.work), PYTHONUTF8="1")
        cls.env.pop("PYTHONPATH", None)
        cls.env.pop("PYTHONHOME", None)
        with cls.console.open("rb") as stream:
            stream.seek(-32, 2)
            cls.trailer = stream.read(32)
            zip_size = struct.unpack("<Q", cls.trailer[16:24])[0]
            stream.seek(0)
            cls.stub = stream.read(cls.console.stat().st_size - zip_size - 32)
        cls.cache = cls.work / "SoloPy" / ("rt-" + cls.trailer[:16].hex())
        # Four simultaneous first launches must share one complete installation.
        def start(_):
            return subprocess.run([str(cls.console), "-c", "import ssl; print('ready')"],
                                  env=cls.env, capture_output=True, text=True, timeout=120)
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(start, range(4)))
        for result in results:
            if result.returncode or result.stdout.strip() != "ready":
                raise AssertionError(f"Concurrent cold launch failed: {result}")
        cls.app = cls.work / "external app 中文"
        cls.app.mkdir()
        (cls.app / "helper.py").write_text("VALUE = 42\n", encoding="utf-8")
        (cls.app / "main.py").write_text("import helper; print(helper.VALUE)\n", encoding="utf-8")
        (cls.app / "local_module.py").write_text("import helper; print(helper.VALUE)\n", encoding="utf-8")
        print(f"Isolated regression files: {cls.work}", flush=True)

    def launch(self, *args, cwd=None, env=None, input=None, check=True):
        result = subprocess.run([str(self.console), *map(str, args)], cwd=cwd or ROOT,
                                env=env or self.env, input=input, capture_output=True,
                                encoding="utf-8", errors="replace", timeout=120)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_console_tool(self):
        data = json.loads(self.launch(ROOT / "tests/console_tool.py", "--self-test").stdout)
        self.assertTrue(data["ok"] and data["sibling_import"])
        result = json.loads(self.launch(ROOT / "tests/console_tool.py", "abc").stdout)
        self.assertEqual(result["sha256"], hashlib.sha256(b"abc").hexdigest())
        file = self.work / "hash file 中文.txt"
        file.write_bytes(b"file contents")
        result = json.loads(self.launch(ROOT / "tests/console_tool.py", file).stdout)
        self.assertEqual(result["kind"], "file")
        self.assertEqual(result["sha256"], hashlib.sha256(b"file contents").hexdigest())

    def test_gui_tool(self):
        report = self.work / "gui-result.json"
        result = subprocess.run([str(self.gui), str(ROOT / "tests/gui_tool.py"),
                                 "--self-test", "--report", str(report)], env=self.env, timeout=120)
        self.assertEqual(result.returncode, 0)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if report.exists():
                try:
                    data = json.loads(report.read_text(encoding="utf-8"))
                    break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.05)
        else:
            self.fail("GUI did not finish its self-test within 20 seconds")
        self.assertTrue(data["ok"], data)
        self.assertTrue(data["window_created"] and data["button_test"])
        self.assertFalse(data["has_console"], data)

    def test_external_script_and_module(self):
        self.assertEqual(self.launch(self.app / "main.py").stdout.strip(), "42")
        self.assertEqual(self.launch("-m", "local_module", cwd=self.app).stdout.strip(), "42")

    def test_argv_and_stdio(self):
        args = ["", "a b", "中文", 'a"b', "ends\\", "\\\"quoted"]
        result = self.launch("-c", "import json,sys; print(json.dumps(sys.argv[1:])); "
                             "print(sys.stdin.read()); print('err',file=sys.stderr)", *args, input="input ok")
        lines = result.stdout.splitlines()
        self.assertEqual(json.loads(lines[0]), args)
        self.assertEqual(lines[1], "input ok")
        self.assertEqual(result.stderr.strip(), "err")

    def test_exit_code(self):
        self.assertEqual(self.launch("-c", "raise SystemExit(17)", check=False).returncode, 17)

    def test_native_options(self):
        result = self.launch("-S", "-c", "import sys,json; print(json.dumps(['site' in sys.modules,sys.flags.no_site]))")
        self.assertEqual(json.loads(result.stdout), [False, 1])
        result = self.launch("-I", "-c", "import sys,json; print(json.dumps([sys.flags.isolated,sys.flags.safe_path]))")
        self.assertEqual(json.loads(result.stdout), [1, True])
        result = self.launch("-X", "utf8", "-c", "import sys; print(sys.flags.utf8_mode)")
        self.assertEqual(result.stdout.strip(), "1")
        self.assertNotEqual(self.launch("-P", self.app / "main.py", check=False).returncode, 0)
        self.assertNotEqual(self.launch("-I", self.app / "main.py", check=False).returncode, 0)

    def test_pythonpath_and_home(self):
        env = dict(self.env, PYTHONPATH=str(self.app), PYTHONHOME=str(self.work / "nonexistent"))
        self.assertEqual(self.launch("-c", "import helper; print(helper.VALUE)", env=env).stdout.strip(), "42")
        for flag in ("-E", "-I"):
            result = self.launch(flag, "-c", "import helper", env=env, check=False)
            self.assertNotEqual(result.returncode, 0)
        paths = json.loads(self.launch("-c", "import sys,json; print(json.dumps(sys.path))").stdout)
        self.assertTrue(all(not p or str(self.cache).lower() in p.lower() for p in paths), paths)

    def test_spawn(self):
        source = self.app / "spawn_check.py"
        source.write_text("from multiprocessing import Process\nfrom helper import VALUE\n"
                          "def worker():\n    assert VALUE == 42\n"
                          "if __name__ == '__main__':\n"
                          "    p = Process(target=worker)\n    p.start()\n    p.join(10)\n"
                          "    assert p.exitcode == 0, p.exitcode\n    print('spawn ok')\n", encoding="utf-8")
        self.assertEqual(self.launch(source).stdout.strip(), "spawn ok")

    def test_in_process_and_cancellation(self):
        process = subprocess.Popen([str(self.console), "-u", "-c",
                                    "import os,time; print(os.getpid(),flush=True); time.sleep(60)"],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            # The Python PID must be the launcher PID: no wrapper survives cancellation.
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(process.stdout.readline)
                try:
                    line = future.result(timeout=15)
                except Exception:
                    process.kill()
                    raise
            self.assertEqual(int(line.strip()), process.pid)
            process.kill()
            process.wait(timeout=10)
        finally:
            if process.poll() is None:
                process.kill(); process.wait(timeout=10)
            process.stdout.close(); process.stderr.close()

    def test_missing_file_repairs_cache(self):
        ssl = self.cache / "_ssl.pyd"
        size = ssl.stat().st_size
        ssl.rename(ssl.with_suffix(".missing"))
        self.launch("-c", "import ssl; print(ssl.OPENSSL_VERSION)")
        self.assertEqual(ssl.stat().st_size, size)

    def test_truncated_file_repairs_cache(self):
        sqlite = self.cache / "_sqlite3.pyd"
        size = sqlite.stat().st_size
        sqlite.write_bytes(b"broken")
        self.launch("-c", "import sqlite3")
        self.assertEqual(sqlite.stat().st_size, size)

    def test_corrupt_manifest_repairs_cache(self):
        manifest = self.cache / ".solopy-manifest"
        manifest.write_bytes(b"broken")
        self.launch("-c", "import ssl,sqlite3")
        self.assertEqual(manifest.read_bytes()[:8], b"SPMF0001")

    def test_repair_does_not_follow_junction(self):
        independent = self.work / "independent-data"
        independent.mkdir()
        sentinel = independent / "preserve.txt"
        sentinel.write_text("must survive", encoding="utf-8")
        link = self.cache / "external-link"
        # PowerShell creates only this test junction; deletion is performed by the EXE under test.
        command = "New-Item -ItemType Junction -Path $env:SOLOPY_TEST_LINK -Target $env:SOLOPY_TEST_TARGET | Out-Null"
        subprocess.run(["powershell", "-NoProfile", "-Command", command], check=True,
                       env=dict(self.env, SOLOPY_TEST_LINK=str(link), SOLOPY_TEST_TARGET=str(independent)),
                       capture_output=True)
        self.launch("--solopy-repair")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "must survive")
        self.assertFalse(link.exists())

    def test_dependency_imports(self):
        # Exercise this project's installed web stack when selected in requirements.
        code = """import json,sys,pathlib,importlib
info=json.loads((pathlib.Path(sys.executable).parent/'solopy-build.json').read_text())
names={p['name'].lower().replace('_','-') for p in info['packages']}
for package,module in [('fastapi','fastapi'),('uvicorn','uvicorn'),('httpx','httpx'),('pydantic','pydantic'),('pydantic-settings','pydantic_settings')]:
    if package in names: importlib.import_module(module)
if {'fastapi','httpx'} <= names:
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    app=FastAPI()
    @app.get('/health')
    def health(): return {'ok':True}
    assert TestClient(app).get('/health').json()=={'ok':True}
print('dependencies ok')
"""
        self.assertEqual(self.launch("-c", code).stdout.strip(), "dependencies ok")

    def toy_bundle(self, name: str, filename: str, content=b"payload"):
        archive = io.BytesIO()
        encoded = filename.encode("utf-8")
        manifest = b"SPMF0001" + struct.pack("<I", 1) + struct.pack("<QI", len(content), len(encoded)) + encoded
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
            zipped.writestr(filename, content)
            zipped.writestr(".solopy-manifest", manifest)
        payload = archive.getvalue()
        digest = hashlib.sha256(payload).digest()[:16]
        exe = self.work / (name + ".exe")
        exe.write_bytes(self.stub + payload + digest + struct.pack("<Q", len(payload)) + b"SOLOPY02")
        return exe, self.work / "SoloPy" / ("rt-" + digest.hex())

    def test_long_unicode_zip_name(self):
        name = "a/" + "测" * 170 + ".txt"
        exe, cache = self.toy_bundle("long-name", name)
        result = subprocess.run([str(exe), "--solopy-repair"], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((cache / name).read_bytes(), b"payload")

    def test_repair_cache_root_junction(self):
        exe, cache = self.toy_bundle("root-junction", "safe.txt")
        target = self.work / "root-junction-target"
        target.mkdir()
        sentinel = target / "preserve.txt"
        sentinel.write_text("independent data", encoding="utf-8")
        command = "New-Item -ItemType Junction -Path $env:SOLOPY_TEST_LINK -Target $env:SOLOPY_TEST_TARGET | Out-Null"
        subprocess.run(["powershell", "-NoProfile", "-Command", command], check=True,
                       env=dict(self.env, SOLOPY_TEST_LINK=str(cache), SOLOPY_TEST_TARGET=str(target)),
                       capture_output=True)
        result = subprocess.run([str(exe), "--solopy-repair"], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "independent data")
        self.assertFalse(cache.is_junction())
        self.assertEqual((cache / "safe.txt").read_bytes(), b"payload")

    def test_reject_zip_traversal(self):
        exe, _ = self.toy_bundle("unsafe-name", "../../escape.txt")
        result = subprocess.run([str(exe), "--solopy-repair"], env=self.env, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"unsafe path", result.stderr)
        self.assertFalse((self.work / "escape.txt").exists())

    def test_corrupt_trailer_diagnostic(self):
        exe = self.work / "corrupt.exe"
        exe.write_bytes(self.stub)
        result = subprocess.run([str(exe)], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"trailer", result.stderr)
        exe.write_bytes(self.stub + b"\0" * 16 + struct.pack("<Q", 2**64-1) + b"SOLOPY02")
        result = subprocess.run([str(exe)], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"length", result.stderr)

    def test_deterministic_bundle(self):
        sys.path.insert(0, str(ROOT / "tools"))
        from runtime_bundle import make_bundle
        runtime = self.work / "tiny-runtime"
        runtime.mkdir()
        file = runtime / "example.txt"
        file.write_text("stable contents", encoding="utf-8")
        stub = self.work / "tiny-stub.exe"
        stub.write_bytes(self.stub)
        first, second = self.work / "first.exe", self.work / "second.exe"
        a = make_bundle(runtime, self.work, [(stub, first)])
        os.utime(file, (1700000000, 1700000000))
        b = make_bundle(runtime, self.work, [(stub, second)])
        self.assertEqual(a, b)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_matching_architecture_and_shared_cache(self):
        for exe, subsystem in ((self.console, 3), (self.gui, 2)):
            with exe.open("rb") as stream:
                stream.seek(0x3C)
                pe = struct.unpack("<I", stream.read(4))[0]
                stream.seek(pe + 4)
                self.assertEqual(struct.unpack("<H", stream.read(2))[0], 0x8664)
                stream.seek(pe + 24 + 68)
                self.assertEqual(struct.unpack("<H", stream.read(2))[0], subsystem)
                stream.seek(-32, 2)
                self.assertEqual(stream.read(32), self.trailer)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *UNIT_ARGS], verbosity=2)
