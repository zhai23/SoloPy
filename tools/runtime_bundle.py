"""Deterministic SoloPy v2 bundles. No third-party Python dependencies."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import zipfile

MAGIC = b"SOLOPY02"
MANIFEST = ".solopy-manifest"


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def runtime_files(runtime: Path):
    for path in sorted(runtime.rglob("*")):
        if path.is_symlink() or path.is_junction():
            raise ValueError(f"Runtime links are not supported: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(runtime)
        if ("__pycache__" in relative.parts or relative.parts[0] == "Scripts"
                or path.suffix in {".pyc", "._pth"} or relative.as_posix() == MANIFEST):
            continue
        yield relative.as_posix(), path


def make_bundle(runtime: Path, work: Path, pairs: list[tuple[Path, Path]]) -> dict:
    """Write a size manifest and a deterministic ZIP; cache key covers all ZIP bytes."""
    files = list(runtime_files(runtime))
    manifest = bytearray(b"SPMF0001" + struct.pack("<I", len(files)))
    for relative, path in files:
        name = relative.encode("utf-8")
        manifest += struct.pack("<QI", path.stat().st_size, len(name)) + name
    archive_path = work / "runtime.zip"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=6, allowZip64=False) as archive:
        for relative, path in files:
            info = zipfile.ZipInfo(relative, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0
            info.external_attr = 0x20
            with path.open("rb") as source, archive.open(info, "w") as target:
                shutil.copyfileobj(source, target)
        info = zipfile.ZipInfo(MANIFEST, date_time=(2020, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.create_system = 0
        info.external_attr = 0x20
        archive.writestr(info, manifest)
    digest = sha256(archive_path)
    trailer = bytes.fromhex(digest)[:16] + struct.pack("<Q", archive_path.stat().st_size) + MAGIC
    for stub, output in pairs:
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_suffix(".pending")
        with temporary.open("wb") as target:
            for source in (stub, archive_path):
                with source.open("rb") as stream:
                    shutil.copyfileobj(stream, target)
            target.write(trailer)
        temporary.replace(output)
    return {"format": 2, "runtime_sha256": digest, "cache_id": digest[:32],
            "files": len(files), "zip_bytes": archive_path.stat().st_size}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--pair", action="append", nargs=2, required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(make_bundle(args.runtime, args.work_dir, args.pair), indent=2))
