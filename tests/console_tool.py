"""Console SHA-256 tool. Run with solopy.exe; --self-test is non-interactive."""
import argparse
import json
import sys
from tool_common import fingerprint, self_check


def main():
    parser = argparse.ArgumentParser(description="SoloPy console test: hash text or a file")
    parser.add_argument("value", nargs="?", help="Text, or an existing file path")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        if args.self_test:
            result = self_check()
        else:
            value = args.value
            if value is None:
                print("SoloPy 控制台测试工具：计算文本或文件的 SHA-256")
                print(f"Python: {sys.version.split()[0]}\n解释器: {sys.executable}")
                value = input("请输入文本或文件路径：")
            result = fingerprint(value.strip('"'))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, EOFError, AssertionError) as exc:
        print(f"测试失败: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
