"""Shared by the console and GUI tools; also exercises sibling-module imports."""
from __future__ import annotations

import hashlib
import platform
from pathlib import Path
import sqlite3
import ssl
import sys


def fingerprint(value: str) -> dict:
    path = Path(value)
    if value and path.is_file():
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        return {"kind": "file", "input": str(path.resolve()), "sha256": digest}
    return {"kind": "text", "input": value,
            "sha256": hashlib.sha256(value.encode("utf-8")).hexdigest()}


def self_check() -> dict:
    with sqlite3.connect(":memory:") as database:
        assert database.execute("select 6 * 7").fetchone()[0] == 42
    ssl.create_default_context()
    assert fingerprint("abc")["sha256"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    return {"ok": True, "python": platform.python_version(), "executable": sys.executable,
            "sibling_import": True, "sqlite": True, "ssl": True, "sha256": True}
