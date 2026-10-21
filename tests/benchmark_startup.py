"""Measure cold extraction and warm startup against the exact same cached runtime."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--exe", type=Path, default=ROOT / "dist/solopy.exe")
parser.add_argument("--runs", type=int, default=20)
args = parser.parse_args()
if args.runs < 1:
    parser.error("--runs must be positive")
exe = args.exe.resolve()
work = Path(tempfile.mkdtemp(prefix="benchmark-", dir=ROOT / ".build"))
env = dict(os.environ, LOCALAPPDATA=str(work))
env.pop("PYTHONPATH", None)
env.pop("PYTHONHOME", None)


def measure(program, code):
    start = time.perf_counter()
    process = subprocess.run([str(program), "-c", code], env=env, capture_output=True,
                             text=True, check=True, timeout=120)
    return (time.perf_counter() - start) * 1000, process.stdout.strip()


cold, host = measure(exe, "import sys; print(sys.executable)")
samples = {"solopy": [], "cached_python": []}
for _ in range(args.runs):
    for name, program in (("solopy", exe), ("cached_python", host)):
        elapsed, _ = measure(program, "pass")
        samples[name].append(elapsed)
result = {"runs": args.runs, "exe_bytes": exe.stat().st_size, "cold_ms": round(cold, 2),
          "warm": {name: {"median_ms": round(statistics.median(values), 2),
                           "min_ms": round(min(values), 2), "max_ms": round(max(values), 2)}
                   for name, values in samples.items()}}
(work / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result, indent=2))
print(f"Report: {work / 'result.json'}")
