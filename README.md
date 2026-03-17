# SoloPy

将 Python 解释器和依赖打包为单一 `solopy.exe`，并在目标 Windows 机器上直接运行外部 `.py` 脚本（无需预装 Python）。

## 特性

- ✅ **单文件可执行**：一个 exe 包含 Python 运行时 + 所有依赖
- ✅ **外部脚本执行**：可运行任意外部 .py 文件，脚本可随时修改
- ✅ **完整 Python 支持**：支持 `-m`、`-c`、`-V` 等原生参数
- ✅ **清华镜像加速**：使用清华大学镜像源，国内下载更快
- ✅ **版本灵活**：构建机和目标运行时 Python 版本可以不同

## 目录结构

```
SoloPy/
├── tools/                      # 构建工具目录
│   ├── build_solopy.py        # 构建脚本（核心）
│   ├── solopy_runner.py       # 运行时启动器
│   └── get-pip.py             # pip 安装器（需手动下载）
├── .build/                    # 构建过程临时文件（自动生成）
├── dist/                      # 最终输出目录（自动生成）
│   └── solopy.exe            # 打包完成的可执行文件
├── tests/web_demo/           # 测试项目（Flask + FastAPI）
├── build.bat                  # 一键构建脚本
├── requirements.txt           # 构建机依赖（PyInstaller 等）
└── solorequirements.txt      # 要打包进 exe 的 Python 依赖
```

## 快速开始

### 1. 下载 get-pip.py

**必需步骤**：在构建前先下载 `get-pip.py`：

```powershell
# 方法 1：使用 curl（推荐）
curl -o tools/get-pip.py https://bootstrap.pypa.io/get-pip.py

# 方法 2：使用 PowerShell
powershell -Command "Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile 'tools/get-pip.py'"

# 方法 3：手动下载
# 访问 https://bootstrap.pypa.io/get-pip.py 保存到 tools/get-pip.py
```

### 2. 修改配置（可选）

打开 `build.bat`，修改顶部配置：

```batch
REM 构建机 Python 版本（必须已安装）
set "BUILD_PYTHON_VERSION=3.12"

REM 要打包进 exe 的嵌入式 Python 版本
set "EMBED_PYTHON_VERSION=3.12.8"

REM 目标架构：amd64（64位）、win32（32位）、arm64
set "PYTHON_ARCH=amd64"

REM 输出的 exe 文件名
set "EXE_NAME=solopy"

REM 使用清华镜像（1=是，0=否）
set "USE_TSINGHUA=1"
```

### 3. 配置依赖

编辑 `solorequirements.txt` 添加你要打包进 exe 的 Python 依赖：

```txt
# 当前示例（Web 框架）
fastapi
uvicorn[standard]
flask
jinja2
python-dotenv
```

### 4. 构建

双击运行：

```
build.bat
```

或命令行执行：

```powershell
build.bat
```

构建成功后，`dist/solopy.exe` 即可分发使用。

## 使用方式

```powershell
# 运行 Python 脚本
solopy.exe script.py

# 使用 -m 运行模块
solopy.exe -m uvicorn app:app --host 0.0.0.0 --port 8000

# 执行 Python 代码
solopy.exe -c "import flask; print(flask.__version__)"

# 查看 Python 版本
solopy.exe -V
```

## 测试项目

已提供 `tests/web_demo/` 用于验证打包是否成功：

```powershell
# 1. 创建测试环境配置
copy tests\web_demo\.env.example tests\web_demo\.env

# 2. 测试依赖加载
dist\solopy.exe tests\web_demo\dependency_check.py

# 3. 测试 Web 功能
dist\solopy.exe tests\web_demo\smoke_web.py

# 4. 启动 Flask 演示（双击或命令行）
tests\web_demo\run_flask_demo.bat
# 访问 http://127.0.0.1:5000

# 5. 启动 FastAPI 演示（双击或命令行）
tests\web_demo\run_fastapi_demo.bat
# 访问 http://127.0.0.1:8000
```

## 技术原理

1. **下载嵌入式 Python**：从清华镜像或官方源下载 `python-{version}-embed-{arch}.zip`
2. **配置运行时**：修补 `._pth` 文件启用 `site-packages`
3. **安装 pip**：使用 `get-pip.py` 为嵌入式 Python 安装 pip
4. **安装依赖**：**用嵌入式 Python 自己的 pip** 安装 `solorequirements.txt` 中的依赖
5. **打包 exe**：用 PyInstaller 将启动器 + 嵌入式运行时打包为单文件
6. **运行时行为**：`solopy.exe` 启动时解包到临时目录，然后转发参数给内置 `python.exe`

**关键优势**：构建机和嵌入式 Python 版本可以不同，因为依赖是用嵌入式 Python 自己安装的，避免了二进制兼容性问题。

## 常见问题

### Q: 构建机必须安装和目标 Python 相同版本吗？

**A:** 不需要。构建机只要有 Python 3.8+ 即可，目标嵌入式 Python 版本在 `build.bat` 中配置。

### Q: 如何使用官方源而不是清华镜像？

**A:** 在 `build.bat` 中设置 `set "USE_TSINGHUA=0"`

### Q: 为什么需要手动下载 get-pip.py？

**A:** `get-pip.py` 约 2MB，不区分 Python 版本，提前下载到 `tools/` 可重复使用，避免每次构建都下载。

### Q: 打包后的 exe 有多大？

**A:** 取决于依赖数量：
- 纯 Python + Flask：~50MB
- FastAPI + Uvicorn：~80MB
- 包含 Numpy/Pandas：150MB+

### Q: 首次运行为什么较慢？

**A:** PyInstaller onefile 模式会在首次运行时解包到临时目录（`%TEMP%/_MEI*`），后续运行会快很多。

### Q: 如何更新依赖？

**A:** 修改 `solorequirements.txt` 后重新运行 `build.bat` 即可。

## 注意事项

- 构建机需要能访问网络（下载 Python 和依赖包）
- 若依赖含 C 扩展，确保构建机架构与目标机一致（如都用 `amd64`）
- `.build/` 目录包含构建缓存，可以保留以加速后续构建
- `dist/` 目录中的 `.exe` 文件即为最终产物，可直接分发

## License

MIT
