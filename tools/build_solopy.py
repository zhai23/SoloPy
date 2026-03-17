from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

# Tsinghua mirror URLs
TSINGHUA_PYPI_INDEX = "https://pypi.tuna.tsinghua.edu.cn/simple"
TSINGHUA_PYTHON_MIRROR = "https://mirrors.tuna.tsinghua.edu.cn/python"


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("[run]", " ".join(cmd))
    subprocess.run(cmd, cwd=cwd, check=True)


def download(url: str, out_file: Path) -> None:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    print(f"[download] {url}")
    tmp_file = out_file.with_suffix(out_file.suffix + ".tmp")
    with urllib.request.urlopen(url, timeout=120) as response, tmp_file.open("wb") as writer:
        shutil.copyfileobj(response, writer)
    if tmp_file.stat().st_size == 0:
        tmp_file.unlink(missing_ok=True)
        raise RuntimeError(f"Downloaded file is empty: {url}")
    tmp_file.replace(out_file)


def patch_embed_pth(runtime_dir: Path) -> None:
    pth_files = sorted(runtime_dir.glob("python*._pth"))
    if not pth_files:
        raise RuntimeError(f"Cannot find python*._pth in {runtime_dir}")

    pth_path = pth_files[0]
    lines = [line.strip() for line in pth_path.read_text(encoding="utf-8").splitlines()]

    rebuilt: list[str] = []
    for line in lines:
        if not line or line.startswith("#"):
            continue
        rebuilt.append(line)

    for extra in ["Lib", "Lib/site-packages", "import site"]:
        if extra not in rebuilt:
            rebuilt.append(extra)

    pth_path.write_text("\n".join(rebuilt) + "\n", encoding="utf-8")
    print(f"[patch] Updated {pth_path.name}")


def build_runtime(
    workspace: Path,
    build_dir: Path,
    version: str,
    arch: str,
    requirements_file: Path,
    embed_zip_override: str | None,
    use_tsinghua: bool,
) -> Path:
    runtime_dir = build_dir / "py-runtime"
    if runtime_dir.exists():
        shutil.rmtree(runtime_dir)
    runtime_dir.mkdir(parents=True, exist_ok=True)

    embed_zip = build_dir / f"python-{version}-embed-{arch}.zip"
    if embed_zip_override:
        src_zip = Path(embed_zip_override).resolve()
        if not src_zip.exists():
            raise FileNotFoundError(f"embed zip not found: {src_zip}")
        shutil.copy2(src_zip, embed_zip)
        print(f"[copy] {src_zip} -> {embed_zip}")
    elif not embed_zip.exists() or embed_zip.stat().st_size == 0:
        if use_tsinghua:
            embed_url = f"{TSINGHUA_PYTHON_MIRROR}/{version}/python-{version}-embed-{arch}.zip"
        else:
            embed_url = f"https://www.python.org/ftp/python/{version}/python-{version}-embed-{arch}.zip"
        download(embed_url, embed_zip)
    else:
        print(f"[cache] Reusing {embed_zip}")

    print(f"[extract] {embed_zip.name}")
    with zipfile.ZipFile(embed_zip, "r") as zf:
        zf.extractall(runtime_dir)

    patch_embed_pth(runtime_dir)

    # Install pip using embedded Python
    python_exe = runtime_dir / "python.exe"
    if not python_exe.exists():
        raise RuntimeError(f"Embedded python.exe not found in {runtime_dir}")

    get_pip = workspace / "tools" / "get-pip.py"
    if not get_pip.exists():
        raise FileNotFoundError(
            f"get-pip.py not found at {get_pip}. "
            f"Please download from https://bootstrap.pypa.io/get-pip.py"
        )

    pip_cmd = [str(python_exe), str(get_pip), "--disable-pip-version-check"]
    if use_tsinghua:
        pip_cmd.extend(["-i", TSINGHUA_PYPI_INDEX])
    run(pip_cmd)

    # Install requirements using embedded Python's pip
    site_packages = runtime_dir / "Lib" / "site-packages"
    site_packages.mkdir(parents=True, exist_ok=True)

    install_cmd = [
        str(python_exe),
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--upgrade",
        "-r",
        str(requirements_file),
    ]
    if use_tsinghua:
        install_cmd.extend(["-i", TSINGHUA_PYPI_INDEX])

    run(install_cmd)

    # Remove pip from runtime to reduce size (optional)
    pip_pkg = site_packages / "pip"
    if pip_pkg.exists():
        shutil.rmtree(pip_pkg)
    for pip_dist in site_packages.glob("pip-*.dist-info"):
        shutil.rmtree(pip_dist)

    return runtime_dir


def ensure_pyinstaller() -> None:
    try:
        __import__("PyInstaller")
        return
    except ModuleNotFoundError:
        pass

    run([sys.executable, "-m", "pip", "install", "pyinstaller"])


def build_exe(workspace: Path, build_dir: Path, runtime_dir: Path, name: str) -> Path:
    ensure_pyinstaller()

    runner = workspace / "tools" / "solopy_runner.py"
    if not runner.exists():
        raise RuntimeError(f"Missing launcher: {runner}")

    dist_dir = workspace / "dist"
    pyi_work = build_dir / "pyi-work"
    pyi_spec = build_dir / "pyi-spec"
    pyi_work.mkdir(parents=True, exist_ok=True)
    pyi_spec.mkdir(parents=True, exist_ok=True)

    add_data = f"{runtime_dir};py"
    cmd = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onefile",
        "--name",
        name,
        "--distpath",
        str(dist_dir),
        "--workpath",
        str(pyi_work),
        "--specpath",
        str(pyi_spec),
        "--add-data",
        add_data,
        str(runner),
    ]
    run(cmd)

    exe_path = dist_dir / f"{name}.exe"
    if not exe_path.exists():
        raise RuntimeError(f"Build completed but exe not found: {exe_path}")
    return exe_path


def smoke_test(exe_path: Path, requirements_file: Path) -> None:
    run([str(exe_path), "-V"])
    
    # Simple import test
    req_content = requirements_file.read_text(encoding="utf-8")
    if "fastapi" in req_content or "flask" in req_content:
        run([str(exe_path), "-c", "import sys; print('Python', sys.version)"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Build SoloPy single-file exe with embedded Python runtime")
    parser.add_argument("--python-version", default="3.12.8", help="Embedded Python version, e.g. 3.12.8")
    parser.add_argument("--arch", default="amd64", choices=["amd64", "win32", "arm64"], help="Windows architecture")
    parser.add_argument("--name", default="solopy", help="Output exe name")
    parser.add_argument("--requirements", default="solorequirements.txt", help="Path to requirements file for embedded runtime")
    parser.add_argument("--embed-zip", default=None, help="Optional local python-embed zip path")
    parser.add_argument("--skip-smoke-test", action="store_true", help="Skip basic runtime checks")
    parser.add_argument("--no-tsinghua", action="store_true", help="Do not use Tsinghua mirror")
    args = parser.parse_args()

    workspace = Path(__file__).resolve().parents[1]
    build_dir = workspace / ".build"
    build_dir.mkdir(parents=True, exist_ok=True)

    requirements_file = (workspace / args.requirements).resolve()
    if not requirements_file.exists():
        raise FileNotFoundError(f"requirements not found: {requirements_file}")

    use_tsinghua = not args.no_tsinghua
    if use_tsinghua:
        print("[mirror] Using Tsinghua mirror for Python and PyPI")

    runtime_dir = build_runtime(
        workspace=workspace,
        build_dir=build_dir,
        version=args.python_version,
        arch=args.arch,
        requirements_file=requirements_file,
        embed_zip_override=args.embed_zip,
        use_tsinghua=use_tsinghua,
    )
    exe_path = build_exe(workspace=workspace, build_dir=build_dir, runtime_dir=runtime_dir, name=args.name)

    if not args.skip_smoke_test:
        smoke_test(exe_path, requirements_file)

    print(f"\n[done] Built executable: {exe_path}")
    print(f"[usage] {exe_path.name} script.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
