"""Build in a fresh staging directory; publish only after both launchers pass tests."""
from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess
import sys

from runtime_bundle import make_bundle, sha256

ROOT = Path(__file__).resolve().parents[1]


def run(*args: str | Path):
    subprocess.run([str(x) for x in args], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--index-url", required=True)
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    stage = runtime.parent
    lock = stage / "requirements.lock"
    lock_meta = stage / "requirements.lock.json"
    report = stage / "resolution.json"
    try:
        build_runtime(args, runtime, stage, lock, lock_meta, report)
    finally:
        for temporary in (lock, lock_meta, report):
            temporary.unlink(missing_ok=True)


def build_runtime(args, runtime, stage, lock, lock_meta, report):
    python = runtime / "python.exe"
    requirements = ROOT / "requirements.txt"
    input_hash = hashlib.sha256(requirements.read_text(encoding="utf-8").encode("utf-8")).hexdigest()
    run(python, ROOT / "tools/get-pip.py", "pip==25.3", "--disable-pip-version-check", "--no-warn-script-location", "-i", args.index_url)
    pip = [python, "-m", "pip", "--disable-pip-version-check"]
    run(*pip, "install", "--dry-run", "--ignore-installed", "--only-binary=:all:",
        "--report", report, "-r", requirements, "-i", args.index_url)
    resolved = json.loads(report.read_text(encoding="utf-8"))["install"]
    lines = ["# Temporary dependency lock for this build: CPython 3.12 / Windows amd64."]
    for item in sorted(resolved, key=lambda x: x["metadata"]["name"].lower()):
        metadata = item["metadata"]
        digest = item["download_info"]["archive_info"]["hashes"]["sha256"]
        lines.append(f'{metadata["name"]}=={metadata["version"]} --hash=sha256:{digest}')
    lock.write_text("\n".join(lines) + "\n", encoding="utf-8")
    lock_meta.write_text(json.dumps({"requirements_sha256": input_hash, "python": "3.12",
        "architecture": "amd64", "lock_sha256": sha256(lock)}, indent=2) + "\n", encoding="utf-8")
    run(*pip, "install", "--require-hashes", "--only-binary=:all:", "--no-warn-script-location", "-r", lock, "-i", args.index_url)
    run(*pip, "check")
    # Retain every user dependency, including setuptools/pkg_resources/wheel.
    # Bootstrap pip is uninstalled only when it is not part of the resolved lock.
    locked_names = {line.split("==")[0].lower().replace("_", "-")
                    for line in lock.read_text().splitlines() if "==" in line}
    if "pip" not in locked_names:
        run(*pip, "uninstall", "-y", "pip")
    sp = runtime / "Lib/site-packages"
    # RECORD must describe the shipped files, not stage-specific script wrappers/pyc.
    for record in sp.glob("*.dist-info/RECORD"):
        rows = list(csv.reader(record.read_text(encoding="utf-8").splitlines()))
        rows = [row for row in rows if row and "__pycache__" not in row[0]
                and not row[0].endswith(".pyc") and "Scripts/" not in row[0].replace("\\", "/")]
        with record.open("w", encoding="utf-8", newline="") as output:
            csv.writer(output, lineterminator="\n").writerows(rows)
    packages = sorted(({"name": d.metadata["Name"], "version": d.version}
                       for d in importlib.metadata.distributions(path=[str(sp)])), key=lambda d: d["name"].lower())
    provenance = {"python": sys.version.split()[0], "architecture": "amd64",
                  "requirements_sha256": input_hash, "lock_sha256": sha256(lock), "packages": packages}
    (runtime / "solopy-build.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    shutil.copyfile(ROOT / "tools/vendor/miniz.LICENSE", runtime / "miniz.LICENSE")
    outputs = stage / "dist"
    console, gui = outputs / "solopy.exe", outputs / "solopyw.exe"
    info = make_bundle(runtime, stage, [(ROOT / "tools/solopy_stub.exe", console),
                                      (ROOT / "tools/solopyw_stub.exe", gui)])
    if not args.skip_tests:
        run(python, ROOT / "tests/test_launchers.py", "--console", console, "--gui", gui)
    info.update(provenance)
    info["executables"] = {p.name: sha256(p) for p in (console, gui)}
    (outputs / "build-info.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    # Prepare all outputs before replacing any previously working release.
    for name in ("solopy.exe", "solopyw.exe", "build-info.json"):
        shutil.copyfile(outputs / name, dist / (name + ".pending"))
    for name in ("solopy.exe", "solopyw.exe", "build-info.json"):
        (dist / (name + ".pending")).replace(dist / name)
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
