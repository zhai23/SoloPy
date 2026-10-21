# SoloPy

![](solopy_banner0.png)

把 Python 解释器和依赖打包为单文件 Windows EXE，在目标机器上直接运行外部 Python 脚本，无需安装 Python。

## 快速开始

当前发布配置为 **Windows x64（amd64）、CPython 3.12.10**。Python 运行时版本及下载摘要固定，依赖在每次构建时根据 `requirements.txt` 解析；普通构建只需要 Windows PowerShell 和网络，不需要系统 Python 或 C 编译器。

```powershell
.\build.bat --no-pause
.\dist\solopy.exe -V
.\dist\solopy.exe -c "print('hello')"
.\dist\solopy.exe main.py
.\dist\solopyw.exe gui.py
```

产物位于 `dist/`：`solopy.exe`、`solopyw.exe`、记录运行时摘要与包版本的 `build-info.json`。

修改 `requirements.txt` 后直接重新构建：

```powershell
.\build.bat --no-pause
```

每次构建会在独立的 `.build/build-*` 目录中临时生成 `requirements.lock` 和 `requirements.lock.json`，记录本次解析的依赖版本与摘要，并通过 `--require-hashes` 校验安装包。构建成功或失败后均自动清理这两个文件及解析报告；它们不放在根目录，也不提交 Git。实际安装的版本保留在 `dist/build-info.json` 中。需要固定依赖版本时，直接在 `requirements.txt` 中指定 `包名==版本号`。

可以指定包索引：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -IndexUrl https://pypi.tuna.tsinghua.edu.cn/simple
```

当前只接受 `amd64`，不会再把 x64 启动器误标为 win32/arm64。启动器通过 CPython 3.12 的 `PyConfig` 初始化解释器；升级 Python 次版本或增加目标架构需要同时更新头文件、运行时校验值、预编译启动器及构建脚本中的目标配置，并重新验证依赖兼容性。

## 两个可单独运行的测试工具

两个工具都能计算文本或文件的 SHA-256，并验证标准库和同目录模块导入。

| 场景 | 双击入口 | 直接命令 |
| --- | --- | --- |
| 控制台／黑窗口 | `tests/run_console.bat` | `dist\solopy.exe tests\console_tool.py` |
| GUI | `tests/run_gui.bat` | `dist\solopyw.exe tests\gui_tool.py` |

双击 GUI 的 BAT 入口时，命令窗口可能短暂闪现，随后关闭；GUI 本身由 `solopyw.exe` 无控制台运行。需要完全避免命令窗口时，可创建指向 `solopyw.exe` 的快捷方式，并将 `gui_tool.py` 的完整路径作为参数。

控制台工具交互输入文本或文件路径，也接受命令行参数：

```powershell
.\dist\solopy.exe .\tests\console_tool.py "hello 中文"
.\dist\solopy.exe .\tests\console_tool.py .\README.md
.\dist\solopy.exe .\tests\console_tool.py --self-test
```

GUI 工具有输入框、“计算 SHA-256”和“运行环境自检”按钮，直接使用 Windows 原生窗口 API，不额外依赖 tkinter、wxPython 或 PySide。官方嵌入式 Python 默认不包含 tkinter。

GUI 自动自检会创建隐藏窗口，通过真实按钮消息触发操作，写入 JSON 结果并退出：

```powershell
.\dist\solopyw.exe .\tests\gui_tool.py --self-test --report .\dist\gui-test.json
```

`solopyw.exe` 异步启动，因此调用返回不代表 GUI 已完成；检查报告文件中的 `ok`，或使用下面的回归测试统一等待和判断结果。

## 自动回归与性能测量

```powershell
.\dist\solopy.exe .\tests\test_launchers.py
.\dist\solopy.exe .\tests\benchmark_startup.py --runs 20
```

默认构建在独立缓存中自动执行回归，全部通过后才发布产物。覆盖：

- 并发首次启动、console/GUI 共用缓存及 PE 架构/子系统。
- 两个示例工具、真实 GUI 控件回调、GUI 无控制台。
- 外部脚本同目录导入、当前目录 `-m`、`PYTHONPATH`、`-E/-I/-P/-S/-X`。
- 空参数、中文、空格、引号、标准输入输出、退出码。
- multiprocessing spawn、解释器 PID 与控制台启动器一致、强制终止。
- 缓存文件缺失/截断恢复、显式修复、junction 外部数据保护。
- 长 UTF-8 文件名、ZIP 路径穿越拒绝、损坏尾部与错误日志捕获。
- 依赖导入、FastAPI 内存请求、确定性封装。

测试和性能测量的缓存、报告保存在 `.build/verify-*`、`.build/benchmark-*`，不会改动用户正常的 SoloPy 缓存。构建中间文件保存在独立 `.build/build-*`，便于排错；不再每次递归清空整个 `.build`。

性能脚本先用全新缓存测首次解压，再交替测量 `solopy.exe -c pass` 和**同一缓存内**的 Python 入口，报告中位数和范围。旧 README 中不同依赖、不同环境的 46 倍数据已移除；实际速度受运行时大小、磁盘和防病毒软件影响。

仅在开发调试时可显式跳过回归：`build.bat --skip-tests --no-pause`。

## 运行时设计

```text
solopy.exe = [ 原生 C 启动器 ] [ 确定性 runtime.zip ] [ 32 字节 v2 尾部 ]
```

- 尾部为 16 字节内容摘要、8 字节 ZIP 长度、8 字节 `SOLOPY02` 标记。
- 首次运行解压到 `%LOCALAPPDATA%\SoloPy\rt-<内容摘要>\`；无 LOCALAPPDATA 时使用 TEMP。
- Console 版本在自身进程中加载 Python DLL，用 CPython 原生参数解析和主循环执行脚本，减少额外进程启动；取消此进程即可停止脚本。脚本自行创建的子进程遵循原生 Python 的生命周期语义。
- GUI 版本为 Windows 子系统 EXE，无控制台闪现，异步启动缓存内的 GUI Python 入口；不透传脚本退出码。
- `sys.executable` 指向缓存中的 `python.exe` / `pythonw.exe`。这两个入口也使用同一初始化策略，以支持 subprocess 和 multiprocessing。
- `PyConfig` 显式配置标准库、扩展模块和运行时根目录，避免注册表路径混入及 `._pth` 的强制隔离。支持脚本目录、`-m`、`PYTHONPATH` 和原生命令行选项。
- **隔离边界**：`PYTHONHOME` 不能替换随包运行时；默认不加载用户级 site-packages。显式 `PYTHONPATH` 受支持，`-E/-I` 可忽略它。使用 `-S` 会跳过 site-packages。SoloPy 不管理 venv。
- 缓存命中时不解压、不读取整个 ZIP；读取清单并检查包内文件的存在和大小。缺失或大小变化会重建。相同大小的内容改写不会被这个快速检查发现，可显式修复。
- 冷启动与修复使用文件锁，完成解压和清单检查后才安装；旧缓存先改名，清理不跟随 junction/reparse point。
- ZIP 路径使用动态 UTF-8 缓冲，拒绝 `..`、绝对路径和 ADS；支持长中文路径。
- 构建时固定 ZIP 排序、时间戳和属性，以 ZIP 的 SHA-256 前 16 字节作为缓存键。相同运行时字节复用缓存；两个 EXE 共用一份。

修复缓存：

```powershell
.\dist\solopy.exe --solopy-repair
```

修复前关闭使用该缓存的脚本；文件被占用时会报错，不强行结束业务进程。此参数只有作为唯一参数时才由启动器处理。v1 旧产物的缓存不会自动删除，也不会与 v2 混用。

## 构建流程与源码

| 文件 | 职责 |
| --- | --- |
| `build.bat` / `build.ps1` | 校验启动器与 Python 下载、创建独立构建目录 |
| `tools/build_runtime.py` | 锁定/安装依赖、运行测试、发布产物 |
| `tools/runtime_bundle.py` | 确定性 ZIP、文件清单、摘要与尾部 |
| `tools/make_runtime_zip.ps1` | 封装脚本的 PowerShell 兼容入口 |
| `tools/solopy_stub.c` | 缓存安装、诊断、CPython 原生入口 |
| `tools/stubs.json` | 预编译文件、源码摘要及 ABI/架构 |
| `tests/` | 控制台工具、GUI 工具、共享模块、回归和性能测试 |

默认只接受 wheel，避免构建时隐式要求 C/Rust 编译器。保留所有用户依赖，包括显式或传递依赖的 setuptools、pkg_resources、wheel；只在锁文件不需要 pip 时移除引导用 pip。封装不包含 `__pycache__`、`._pth` 和带构建路径的 Scripts 启动包装器；通过 `solopy.exe -m 包名` 使用模块入口。

修改 C 源码、图标或编译配置后运行：

```powershell
.\tools\build_stub.bat
.\build.bat --no-pause
```

重新编译需要 PATH 上的 **amd64 MinGW-w64 gcc/windres**，或 **x64 MSVC 开发者命令行**中的 cl/rc。脚本下载并校验固定的 CPython 头文件，开启栈保护、ASLR 和 DEP，构建四个原生 EXE 并更新 `stubs.json`。常规构建会检测源码与预编译文件不一致，避免忘记重新编译而继续分发旧代码。

源码和头文件摘要按 LF 规范化，避免 Git 换行转换造成误报。跨编译器、Python/zlib 版本的二进制完全一致性不作保证；同一预编译启动器、运行时、锁定依赖及封装实现下产物应保持一致。
