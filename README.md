# SoloPy

![](solopy_banner0.png)
生成自定义单文件 `Python 解释器`
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

```shell
https://bootstrap.pypa.io/get-pip.py
```

2. 按需修改 `build.bat` 顶部配置

```bat
set "PYTHON_VERSION=3.12"
set "PYTHON_ARCH=amd64"
set "EXE_NAME=solopy"
set "ICON_FILE=tools\\solopy.ico"
set "MIRROR_LABEL=Tsinghua"
set "PYTHON_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/python"
set "PYPI_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple"
```

3. 修改 `requirements.txt`

4. 双击或执行：

```powershell
build.bat
```

构建成功后输出：`dist/solopy.exe`

## 配置说明

- `PYTHON_VERSION`：同时用于构建环境和最终打包运行时的 Python 版本；可写完整版本如 `3.12.8`，也可写主次版本如 `3.12`，构建时会自动联网解析到当前可下载的最新补丁版本
- `PYTHON_ARCH`：`amd64` / `win32` / `arm64`
- `EXE_NAME`：输出 exe 名称
- `ICON_FILE`：exe 图标文件路径（建议 `.ico`）
- `MIRROR_LABEL`：构建日志里显示的镜像名称
- `PYTHON_MIRROR`：嵌入式 Python 下载地址前缀
- `PYPI_INDEX`：`get-pip` 和 `pip install` 使用的索引地址

说明：即使系统完全没装 Python，也可以构建；前提是机器有 PowerShell，并且能访问你配置的下载源。

例如：

- `3.12` -> 自动解析成当前可下载的最新 `3.12.x`
- `3.12.8` -> 直接使用该精确版本

## 使用方式

```powershell
solopy.exe -c "print('hello')"
solopy.exe -V
solopy.exe main.py
```

## 注意事项

- `tools/get-pip.py` 需要你提前放好
- `.build/` 中的嵌入式 Python zip 会被保留复用，其余中间文件会在每次构建前自动清理
- 如果依赖带 C 扩展，请确保目标架构与构建架构一致
- 当前 `solopy_runner.py` 保持与系统 Python 尽量一致的透明行为
