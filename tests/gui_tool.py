"""Native Windows GUI SHA-256 tool. No tkinter/wxPython dependency required."""
from __future__ import annotations

import argparse
import ctypes as C
from ctypes import wintypes as W
import json
from pathlib import Path
import sys
import traceback
from tool_common import fingerprint, self_check

user32 = C.WinDLL("user32", use_last_error=True)
kernel32 = C.WinDLL("kernel32", use_last_error=True)
gdi32 = C.WinDLL("gdi32", use_last_error=True)
LRESULT = C.c_ssize_t
WNDPROC = C.WINFUNCTYPE(LRESULT, W.HWND, W.UINT, W.WPARAM, W.LPARAM)


class WNDCLASS(C.Structure):
    _fields_ = [("style", W.UINT), ("lpfnWndProc", WNDPROC), ("cbClsExtra", C.c_int),
                ("cbWndExtra", C.c_int), ("hInstance", W.HINSTANCE), ("hIcon", W.HICON),
                ("hCursor", W.HANDLE), ("hbrBackground", W.HBRUSH),
                ("lpszMenuName", W.LPCWSTR), ("lpszClassName", W.LPCWSTR)]


def bind(lib, name, result, *args):
    function = getattr(lib, name)
    function.restype, function.argtypes = result, args
    return function


CreateWindow = bind(user32, "CreateWindowExW", W.HWND, W.DWORD, W.LPCWSTR, W.LPCWSTR,
                    W.DWORD, C.c_int, C.c_int, C.c_int, C.c_int, W.HWND, W.HMENU, W.HINSTANCE, W.LPVOID)
DefWindowProc = bind(user32, "DefWindowProcW", LRESULT, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
RegisterClass = bind(user32, "RegisterClassW", W.ATOM, C.POINTER(WNDCLASS))
GetModuleHandle = bind(kernel32, "GetModuleHandleW", W.HMODULE, W.LPCWSTR)
GetConsoleWindow = bind(kernel32, "GetConsoleWindow", W.HWND)
SetWindowText = bind(user32, "SetWindowTextW", W.BOOL, W.HWND, W.LPCWSTR)
GetWindowText = bind(user32, "GetWindowTextW", C.c_int, W.HWND, W.LPWSTR, C.c_int)
SendMessage = bind(user32, "SendMessageW", LRESULT, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
ShowWindow = bind(user32, "ShowWindow", W.BOOL, W.HWND, C.c_int)
DestroyWindow = bind(user32, "DestroyWindow", W.BOOL, W.HWND)
GetMessage = bind(user32, "GetMessageW", W.BOOL, C.POINTER(W.MSG), W.HWND, W.UINT, W.UINT)
DispatchMessage = bind(user32, "DispatchMessageW", LRESULT, C.POINTER(W.MSG))
TranslateMessage = bind(user32, "TranslateMessage", W.BOOL, C.POINTER(W.MSG))
PostQuitMessage = bind(user32, "PostQuitMessage", None, C.c_int)
PostMessage = bind(user32, "PostMessageW", W.BOOL, W.HWND, W.UINT, W.WPARAM, W.LPARAM)
GetStockObject = bind(gdi32, "GetStockObject", W.HANDLE, C.c_int)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.self_test and not args.report:
        parser.error("--self-test requires --report")
    instance = GetModuleHandle(None)
    controls = {}
    failed = False

    def output(result):
        SetWindowText(controls["output"], json.dumps(result, ensure_ascii=False, indent=2).replace("\n", "\r\n"))

    @WNDPROC
    def window_proc(hwnd, message, wparam, lparam):
        nonlocal failed
        try:
            if message == 0x0111:  # WM_COMMAND
                command = wparam & 0xFFFF
                if command == 101:
                    value = C.create_unicode_buffer(32768)
                    GetWindowText(controls["input"], value, len(value))
                    output(fingerprint(value.value.strip('"')))
                elif command == 102:
                    output(self_check())
                return 0
            if message == 0x8001:  # exercise the real window/control callback path
                SendMessage(controls["hash"], 0x00F5, 0, 0)  # BM_CLICK
                displayed = C.create_unicode_buffer(8192)
                GetWindowText(controls["output"], displayed, len(displayed))
                calculated = json.loads(displayed.value)
                assert calculated["sha256"] == fingerprint("abc")["sha256"]
                SendMessage(controls["check"], 0x00F5, 0, 0)
                result = self_check()
                result.update(window_created=bool(hwnd), has_console=bool(GetConsoleWindow()),
                              button_test=True, argv=sys.argv)
                args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
                DestroyWindow(hwnd)
                return 0
            if message == 0x0002:  # WM_DESTROY
                PostQuitMessage(1 if failed else 0)
                return 0
        except Exception:
            failed = True
            error = {"ok": False, "error": traceback.format_exc()}
            if args.report:
                args.report.write_text(json.dumps(error), encoding="utf-8")
                DestroyWindow(hwnd)
            elif "output" in controls:
                output(error)
            return 0
        return DefWindowProc(hwnd, message, wparam, lparam)

    wc = WNDCLASS()
    wc.lpfnWndProc, wc.hInstance = window_proc, instance
    wc.hbrBackground, wc.lpszClassName = W.HBRUSH(6), "SoloPyTestTool"
    if not RegisterClass(C.byref(wc)):
        raise C.WinError(C.get_last_error())
    hwnd = CreateWindow(0, wc.lpszClassName, "SoloPy GUI 测试工具", 0x00CF0000,
                        200, 160, 760, 510, None, None, instance, None)
    if not hwnd:
        raise C.WinError(C.get_last_error())

    def control(kind, text, x, y, width, height, ident=0, style=0):
        handle = CreateWindow(0, kind, text, 0x50000000 | style, x, y, width, height,
                              hwnd, W.HMENU(ident), instance, None)
        if not handle:
            raise C.WinError(C.get_last_error())
        SendMessage(handle, 0x0030, GetStockObject(17), 1)
        return handle

    control("STATIC", "输入文本或文件路径，计算 SHA-256；也可运行 Python 环境自检。", 20, 18, 700, 30)
    controls["input"] = control("EDIT", "abc", 20, 58, 700, 30, style=0x00810080)
    controls["hash"] = control("BUTTON", "计算 SHA-256", 20, 104, 160, 36, 101, 0x10000)
    controls["check"] = control("BUTTON", "运行环境自检", 196, 104, 160, 36, 102, 0x10000)
    controls["output"] = control("EDIT", "等待操作……", 20, 160, 700, 240, style=0x00A00844)
    control("STATIC", f"Python {sys.version.split()[0]}  |  无额外 GUI 依赖", 20, 420, 700, 25)
    ShowWindow(hwnd, 0 if args.self_test else 5)
    if args.self_test:
        PostMessage(hwnd, 0x8001, 0, 0)
    message = W.MSG()
    while True:
        result = GetMessage(C.byref(message), None, 0, 0)
        if result == -1:
            raise C.WinError(C.get_last_error())
        if result == 0:
            return int(message.wParam)
        TranslateMessage(C.byref(message))
        DispatchMessage(C.byref(message))


if __name__ == "__main__":
    raise SystemExit(main())
