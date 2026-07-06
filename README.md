# SoloPy

![](solopy_banner0.png)
生成自定义单文件 `Python 解释器`
将 Python 解释器和依赖打包为单一 `solopy.exe`，并在目标 Windows 机器上直接运行外部 `.py` 脚本，无需预装 Python。

## 架构（极速启动）

`solopy.exe` 不再使用 PyInstaller 打包，而是由一个**原生 C 启动器 stub**加上追加在其后的嵌入式 Python 运行时组成：

```text
solopy.exe = [ 原生 stub.exe ] [ runtime.zip ] [ 32 字节尾部 ]
```

- 首次运行（冷启动）：stub 把追加的运行时**一次性**解压到 `%LOCALAPPDATA%\SoloPy\rt-<buildid>\`，再直接运行其中的 `python.exe`
- 之后每次运行（热启动）：stub 只读取尾部 32 字节，命中缓存后**直接**运行缓存里的 `python.exe`，不再解压
- 缓存目录以 `buildid` 命名，每次构建生成新的 `buildid`，因此更新 exe 后会自动重新解压，不会与旧版本冲突

对比旧的 PyInstaller `--onefile` 方案：

| 场景 | 旧方案 | 新方案 |
| --- | --- | --- |
| `solopy.exe -c "pass"`（热启动） | ~3940 ms | ~85 ms |
| 首次运行（一次性解压） | ~3940 ms | ~1100 ms |
| exe 体积 | ~33 MB | ~16.6 MB |

热启动约提速 **46 倍**，且行为与直接运行 `python.exe` 完全一致（参数、stdio、退出码、Ctrl+C、`-X`/`-m`/`-c`/脚本、编码行为均透明透传）。

## 两个可执行文件：solopy.exe 与 solopyw.exe

和官方 Python 的 `python.exe` / `pythonw.exe` 一样，构建会产出**一对姊妹 exe**，二者由同一份 stub 源码编译、共用同一份运行时缓存：

| 产物 | 子系统 | 调用解释器 | 用途 |
| --- | --- | --- | --- |
| `dist/solopy.exe` | Console | `python.exe` | 命令行 / 带控制台，可看日志与报错 |
| `dist/solopyw.exe` | GUI（无控制台） | `pythonw.exe` | 启动 GUI，**零控制台、零闪现** |

启动 GUI 程序时用 `solopyw.exe`，双击、快捷方式、拖拽都不会弹出任何控制台窗口：

```powershell
solopyw.exe main.py
```

> 为什么需要两个 exe：一个 exe 弹不弹控制台是由 PE 头的 `Subsystem` 字段在**编译期**决定的，操作系统在进程创建的瞬间就读取它——早于程序自身代码运行。因此靠"加参数"无法阻止 Console 子系统 exe 弹控制台；必须像 Python 一样提供一个独立的 GUI 子系统 exe。两个 exe 用**相同的 buildid**，所以运行时只解压一份、彼此复用缓存。

## 现在的构建方式

- `build.bat` 不依赖系统已安装的 Python，也不再依赖 PyInstaller
- 构建时下载一个随 exe 分发的嵌入式 Python 到 `.build/py-runtime`
- `pip` 与业务依赖由下载下来的嵌入式 Python 自己安装
- 安装完成后会裁剪运行时（移除 `pip` / `setuptools` / `__pycache__` 等仅构建期需要的内容）以减小体积、加快首次解压
- 最后把启动器 stub + 运行时 zip + 尾部拼接成 `dist/solopy.exe` 与 `dist/solopyw.exe`（共用同一份运行时）
- 每次构建前会清理 `.build/` 中除嵌入式 Python zip 以外的中间文件

### 关于启动器 stub

- 源码：`tools/solopy_stub.c`（仅依赖 Win32 API 与 vendored `tools/vendor/miniz.*` 解压库，静态链接 CRT，目标机无需 VC++ 运行库）
- 同一份源码编译两次：Console 版 → `tools/solopy_stub.exe`；GUI 版（定义 `SOLOPY_WINDOWED` 宏、`/SUBSYSTEM:WINDOWS`）→ `tools/solopyw_stub.exe`
- 两个预编译产物已随仓库提交，因此常规构建（`build.bat`）**不需要 C 编译器**
- 仅当修改了 `tools/solopy_stub.c` 或图标时，才需要重新编译：运行 `tools/build_stub.bat`（需要安装了「C++ 桌面开发」工作负载的 Visual Studio 2022 或 VC++ Build Tools）

## 目录结构

```text
SoloPy/
├── tools/
│   ├── get-pip.py
│   ├── solopy_stub.c        # 原生启动器源码（console 与 windowed 共用）
│   ├── solopy_stub.exe      # 预编译 Console 启动器（已提交）
│   ├── solopyw_stub.exe     # 预编译 GUI 启动器（已提交，无控制台）
│   ├── build_stub.bat       # 仅在改动 stub 源码时重新编译（产出上面两个）
│   └── vendor/
│       └── miniz.*          # vendored 解压库
├── .build/
├── dist/                    # 产出 solopy.exe 与 solopyw.exe
├── tests/
├── build.bat
└── requirements.txt
```

- `tools/get-pip.py`：固定放置的 pip 安装脚本
- `tools/solopy_stub.c`：原生启动器源码（一份源码编译出 console 与 windowed 两个 stub）
- `tools/solopy_stub.exe` / `tools/solopyw_stub.exe`：预编译的 Console / GUI 启动器
- `tools/build_stub.bat`：重新编译启动器（需要 MSVC，仅在改 stub 时用）
- `tools/vendor/`：vendored 的 miniz 解压库
- `.build/`：所有下载文件、嵌入式 Python、构建中间文件
- `dist/`：最终构建产物（`solopy.exe` + `solopyw.exe`）
- `requirements.txt`：要打包进最终 exe 的依赖

## 使用步骤

1. 准备 `tools/get-pip.py`

```shell
https://bootstrap.pypa.io/get-pip.py
```

2. 按需修改 `build.bat` 顶部配置

```bat
set "PYTHON_VERSION=3.12"
set "PYTHON_ARCH=amd64"
set "EXE_NAME=solopy"
set "MIRROR_LABEL=Tsinghua"
set "PYTHON_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/python"
set "PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple"
```

3. 修改 `requirements.txt`

4. 双击或执行：

```powershell
build.bat
```

构建成功后输出：`dist/solopy.exe` 与 `dist/solopyw.exe`

## 配置说明

- `PYTHON_VERSION`：同时用于构建环境和最终打包运行时的 Python 版本；可写完整版本如 `3.12.8`，也可写主次版本如 `3.12`，构建时会自动联网解析到当前可下载的最新补丁版本
- `PYTHON_ARCH`：`amd64` / `win32` / `arm64`
- `EXE_NAME`：输出 exe 名称（同时决定 `<EXE_NAME>.exe` 与 `<EXE_NAME>w.exe`）
- `MIRROR_LABEL`：构建日志里显示的镜像名称
- `PYTHON_MIRROR`：嵌入式 Python 下载地址前缀
- `PYPI_INDEX`：`get-pip` 和 `pip install` 使用的索引地址

说明：即使系统完全没装 Python，也可以构建；前提是机器有 PowerShell，并且能访问你配置的下载源。

例如：

- `3.12` -> 自动解析成当前可下载的最新 `3.12.x`
- `3.12.8` -> 直接使用该精确版本

## 使用方式

命令行 / 需要看输出，用 `solopy.exe`（带控制台）：

```powershell
solopy.exe -c "print('hello')"
solopy.exe -V
solopy.exe main.py
```

启动 GUI 程序、不想弹控制台，用 `solopyw.exe`（无控制台、零闪现）：

```powershell
solopyw.exe main.py
```

## 注意事项

- `tools/get-pip.py` 需要你提前放好
- `.build/` 中的嵌入式 Python zip 会被保留复用，其余中间文件会在每次构建前自动清理
- 如果依赖带 C 扩展，请确保目标架构与构建架构一致
- `solopyw.exe` 采用 fire-and-forget 方式启动 `pythonw.exe`：启动器立即退出、GUI 独立运行，因此不透传退出码（GUI 场景无需）；需要退出码/日志时请用 `solopy.exe`
