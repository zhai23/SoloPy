from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def _runtime_root() -> Path:
    # In PyInstaller one-file mode, resources are extracted under _MEIPASS.
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))
    return base / "py"


def main() -> int:
    runtime = _runtime_root()
    python_exe = runtime / "python.exe"

    if not python_exe.exists():
        print(f"[SoloPy] Embedded interpreter not found: {python_exe}", file=sys.stderr)
        return 2

    cmd = [str(python_exe), *sys.argv[1:]]
    # Fully transparent: behave exactly like system Python
    # All signals, exceptions, and outputs are passed through
    completed = subprocess.run(cmd)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
