# SoloPy

将 Python 解释器和依赖打包为单一 `solopy.exe`，并在目标 Windows 机器上直接运行外部 `.py` 脚本，无需预装 Python。

## 现在的构建方式

- `build.bat` 不依赖系统已安装的 Python
- 构建时会先下载一个用于打包的嵌入式 Python 到 `.build/py-build`
- 再下载一个最终随 `solopy.exe` 分发的嵌入式 Python 到 `.build/py-runtime`
- `pip`、`PyInstaller`、业务依赖都由下载下来的嵌入式 Python 自己安装
- 每次构建前会清理 `.build/` 中除嵌入式 Python zip 以外的中间文件

## 目录结构

```text
SoloPy/
├── tools/
│   ├── get-pip.py
│   └── solopy_runner.py
├── .build/
├── dist/
├── tests/
├── build.bat
└── requirements.txt
```

- `tools/get-pip.py`：固定放置的 pip 安装脚本
- `tools/solopy_runner.py`：最终 exe 的入口启动器
- `.build/`：所有下载文件、嵌入式 Python、PyInstaller 中间文件
- `dist/`：最终构建产物
- `requirements.txt`：要打包进最终 exe 的依赖

## 使用步骤

1. 准备 `tools/get-pip.py`

```powershell
curl -L -o tools/get-pip.py https://bootstrap.pypa.io/get-pip.py
```

2. 按需修改 `build.bat` 顶部配置

```bat
set "PYTHON_VERSION=3.12.8"
set "PYTHON_ARCH=amd64"
set "EXE_NAME=solopy"
set "USE_TSINGHUA=1"
```

3. 修改 `requirements.txt`

4. 双击或执行：

```powershell
build.bat
```

构建成功后输出：`dist/solopy.exe`

## 配置说明

- `PYTHON_VERSION`：同时用于构建环境和最终打包运行时的 Python 版本
- `PYTHON_ARCH`：`amd64` / `win32` / `arm64`
- `EXE_NAME`：输出 exe 名称
- `USE_TSINGHUA`：`1` 使用清华镜像，`0` 使用官方源

说明：即使系统完全没装 Python，也可以构建；前提是机器有 PowerShell，并且能访问你配置的下载源。

## 使用方式

```powershell
solopy.exe script.py
solopy.exe -m uvicorn app:app --host 0.0.0.0 --port 8000
solopy.exe -c "print('hello')"
solopy.exe -V
```

## 测试项目

仓库内提供了 `tests/web_demo/` 用于验证外部脚本运行。

```powershell
copy tests\web_demo\.env.example tests\web_demo\.env
dist\solopy.exe tests\web_demo\dependency_check.py
dist\solopy.exe tests\web_demo\smoke_web.py
```

## 注意事项

- `tools/get-pip.py` 需要你提前放好
- `.build/` 中的嵌入式 Python zip 会被保留复用，其余中间文件会在每次构建前自动清理
- 如果依赖带 C 扩展，请确保目标架构与构建架构一致
- 当前 `solopy_runner.py` 保持与系统 Python 尽量一致的透明行为
