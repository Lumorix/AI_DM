# AI 剧本杀主持

主持人在电脑上控制流程，玩家用手机浏览器查看角色本、搜证、问 DM 和投票。项目包含 **Windows Python 网页版**和 **Mac Swift 原生版**，两套实现的入口、配置、界面和功能范围不同。

当前状态按 2026-10-04 本地代码整理，包含本轮防剧透修复；原功能审计保留修复前快照。“有实现”不代表真实设备或外部服务全部验收通过。Windows 已有基础流程及语音接口自动化测试；Mac 原生版仍需在 Mac 上编译和验收。详细核对见 [功能审计](jubensha-dm/README-FEATURE-AUDIT.md)，现有测试与运行流程见 [项目状态](jubensha-dm/PROJECT-STATUS.md)。

## 先选择运行版本

| 项目 | Windows：Python 网页版 | Mac：Swift 原生版 |
|---|---|---|
| 入口 | `jubensha-dm/start.bat` | `jubensha-dm/build.sh` → `.app` |
| 主持台 / 大屏 | 浏览器管理页面 / `/screen` | 原生主持台 / 大屏窗口 |
| 玩家 | 手机浏览器 `/player` | 手机浏览器 `/player` |
| 基础游戏 | 阶段、读本、搜证、线索、问答、投票、存档 | 有对应实现，需 Mac 验收 |
| AI 配置 | `config.yaml` / 环境变量 | 应用设置 / macOS 钥匙串 |
| PDF 导入 | Python 命令行 OCR、整理工具 | 图形导入向导、Apple OCR、AI 整理 |
| 剧本编辑 | 编辑 YAML / 文本 | 表单编辑器、校验、复制示例 |
| Live2D | **尚未接入网页大屏** | 模型导入、动作、表情、嘴型代码已实现 |
| 语音 | 浏览器朗读；本机 NVIDIA 语音服务（实验） | 系统朗读、云端克隆、本机 MLX 相关入口 |
| 阶段禁用词规则 | 支持 `词@阶段id` / `dm.forbidden_until` | 支持阶段解禁规则 |
| 跨机器 GPU 语音 | 目前仅 Windows 本机访问 | **尚未接通 Windows GPU 服务** |

Python 网页版也有 Mac/Linux 的 `start.sh` 入口；在 Mac 运行它仍然是 **Python 网页版**，不会变成 Swift 原生版。两版配置、存档路径和部分剧本规则不同，不保证直接互换。

## Windows：Python 网页版

### 1. 安装与启动游戏

先安装可在终端运行的 Python；当前本地环境使用 Python 3.12。基础游戏无需 NVIDIA GPU，也无需先安装语音模型。首次启动会创建游戏 `.venv` 并安装依赖，需要网络。

在仓库根目录打开 PowerShell：

```powershell
cd .\jubensha-dm
.\start.bat --script scripts/demo --port 8000
```

没有 `config.yaml` 时会使用模拟模式：原文旁白、固定问答，不调用真实 AI。若已有配置，先检查 `llm.provider`；设为 `mock` 才是模拟模式。

1. 主持电脑打开 `http://127.0.0.1:8000/screen`。
2. 管理页面使用启动终端打印的 **带 admin 令牌的链接**，不要分享给玩家。
3. 手机与电脑连接同一局域网，扫描二维码或打开终端打印的 `http://电脑局域网IP:8000/player`。手机不能用 `127.0.0.1` 访问主持电脑。
4. 选择《听涛居》的角色，管理员推进阅读、搜证、讨论、投票和复盘。

大屏有浏览器全屏按钮；电视/投影的显示连接由系统和设备完成。手机无法连接时，检查 Windows 防火墙是否允许 Python 的局域网连接、端口是否一致，以及路由器是否开启设备隔离。

默认读取 `saves/<剧本文件夹名>.json` 继续游戏。需要新局时加 `--new`，启动器会先备份同名旧存档。两个同名剧本文件夹会使用同名存档，应避免重名。

### 2. 接上真实 AI

如果还没有本机配置，执行以下命令；已有配置不会被覆盖：

```powershell
if (!(Test-Path .\config.yaml)) {
    Copy-Item .\config.example.yaml .\config.yaml
}
```

编辑 `config.yaml` 的 `llm`：

- `provider: openai` 表示使用 OpenAI 兼容接口协议，不限定供应商。
- `base_url`、`model`、`api_key` 填入实际服务提供的值；Key 也可通过 `JUBENSHA_API_KEY` 环境变量提供。
- 本地 Ollama / LM Studio 需要另外安装、加载模型并启动兼容服务。
- 可选 `llm.cheap` 用于记忆压缩；未配置时使用主模型。
- `game.narration: verbatim` 使用原文旁白；`ai` 使用模型润色。原文也应由主持人检查。

修改后重启游戏，先测试普通问答、私聊和线索发放。模板模型名及供应商预设并非可用性保证；包括 Claude 在内的服务都需核验实际接口协议、鉴权和模型名称。

### 3. 导入与编辑剧本

Windows 当前没有 Mac 的图形导入向导或表单编辑器。可参考 `scripts/demo/script.yaml` 编辑剧本；扫描资料使用以下工具：

```powershell
.\.venv\Scripts\python.exe -X utf8 .\tools\ocr.py --help
.\.venv\Scripts\python.exe -X utf8 .\tools\draft.py --help
```

`ocr.py` 支持 RapidOCR、Tesseract、AI 视觉识别，以及 DPI 和双页切分参数。相应 OCR 引擎需要另行准备，基础游戏启动成功不代表 OCR 依赖已齐全。`draft.py` 接收 DM 手册、角色本及线索文本并整理为初稿。角色分幕依赖标题匹配；阶段、真相、凶手、搜证地点与线索关联必须人工检查。

Python 已支持 `禁用词@阶段id`：到指定阶段才解禁。不带 `@` 的词按 `dm.forbidden_until` 解禁，未配置时默认在首次复盘解禁；没有复盘则保持锁定。无效的单词阶段配置会阻止加载；不存在的全局目标会提醒并保持锁定。

### 4. Windows 本机语音（实验）

先用大屏的浏览器朗读测试游戏。八千代本机语音使用独立的 NVIDIA / PyTorch 环境，与游戏 `.venv` 分开；准备方法见 [Windows 语音 README](jubensha-dm/tools/windows_voice/README.md)。

完成语音环境与模型准备后，在 `jubensha-dm` 下另开 PowerShell：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\voice_service.py --config .\tools\windows_voice\voice_config.example.json
```

先检查配置中的模型和参考音频路径；该服务不会自动下载模型。默认监听 `127.0.0.1:8775`，在本机打开 `/screen` 选择实验音色。详情见 [语音 API](jubensha-dm/tools/windows_voice/VOICE-API.md)、[播放控制](jubensha-dm/tools/windows_voice/PLAYBACK.md)、[缓存](jubensha-dm/tools/windows_voice/CACHE.md)。

- 已有整句 WAV 合成、排队、停止/跳句、内存与磁盘缓存。
- 停止播放不会强制终止正在进行的 GPU 运算；合成失败时网页关闭朗读并保留文字。
- 当前中文开头发音、长句音色一致性尚未达标，持续实时生成尚未验收。
- 服务及游戏代理目前仅支持本机使用，未提供 Mac/手机远程调用 Windows GPU 的完整流程。

## Mac：Swift 原生版

### 1. 编译与开局

需要 macOS 14+ 和支持 Swift 6 的 Xcode 命令行工具。Windows 无法编译此原生应用。

```bash
xcode-select --install
# 在仓库根目录执行：
cd jubensha-dm
./build.sh
open "build/AI 剧本杀.app"
```

首次构建需要获取依赖。生成的 `.app` 可放到“应用程序”文件夹；按 macOS 提示允许打开和局域网连接。

1. 在剧本库选择《听涛居》（4 人），使用模拟模式开始游戏。
2. 点“大屏”或“投屏”打开大屏/全屏窗口；电视连接由 macOS 和显示设备完成。
3. 玩家同 Wi-Fi 扫码选角色；主持人点“下一阶段”推进。
4. 模拟模式只使用固定回复/原文旁白，不执行真实 AI 推理。

快捷键：⌘→ 下一阶段、⌘← 上一阶段、⌘R 重播旁白、⌘B 大屏。下次在剧本库点“继续”恢复存档。

### 2. AI 设置

打开 **设置（⌘,）› AI 主持**，选择服务，填写实际地址、模型和 API Key，点“测试连接”。代码包含 DeepSeek、千问、Claude、Ollama、LM Studio 和自定义兼容服务预设；预设不等于已通过当前供应商验证。Claude 等服务的协议、鉴权及模型名需单独核对。

Key 使用 macOS 钥匙串保存；**记忆压缩**设置可配置独立模型。本地模型服务需单独启动，所需内存取决于模型、量化和上下文，项目不保证固定硬件配置下的速度。

### 3. 扫描 PDF 导入与剧本编辑

打开 **文件 › 导入扫描剧本（⌘I）**：

1. 添加 DM 手册、角色本、线索卡 PDF，设置类型；角色本填写角色名。只有 DM 手册时也有角色提取路径，完整程度取决于手册内容。
2. 默认使用 Apple 离线 OCR；可双页切分、提高 DPI，或配置 AI 视觉识别。识别后查看并修改人名、时间等文本。
3. 角色本按“第 X 幕”等标题切分并保留原文；AI 从 DM 手册和线索卡提取真相、流程、主持词、地点、线索、凶手和结局。没有 AI 可生成空白骨架。
4. 在表单编辑器检查阶段、搜证关联、真相、凶手、禁用词和秘密摘要，⌘S 保存。示例只读，先在剧本库“复制一份来修改”。

逐页缓存与整本输出现在按文件内容、DPI、引擎、切分及视觉配置等生成指纹；更换内容或参数后使用新目录，旧文件保留。AI 整理仅生成初稿，不能保证任意剧本自动可玩。

**阶段禁用词（Python 也已支持）**：`说法@阶段id` 在指定阶段解禁；不带 `@` 时，在首次复盘阶段或 `dm.forbidden_until` 指定阶段解禁。

原生 CLI 示例（从 `jubensha-dm` 执行，文件名替换为自己的）：

```bash
"build/AI 剧本杀.app/Contents/MacOS/AIDM" --ocr "剧本.pdf" --split --dpi 300
"build/AI 剧本杀.app/Contents/MacOS/AIDM" --check "剧本文件夹"
```

`--check` 可选 `--rewrite` 会重写剧本文件，使用前保留原文件。

### 4. Live2D（Mac 专属界面）

在 **设置 › DM 形象**选择或拖入含 `.model3.json` 的模型目录。代码面向 Cubism 3/4/5 模型，具体模型兼容性需实际加载验证。

- 支持嘴型、说话看向字幕、阶段动作；克隆音频嘴型可使用真实音量，无动作时有默认摆动。
- 自动发现 `.exp3.json`；按名字关键词匹配笑、哭、思考表情，效果取决于模型素材。
- 可选全身/半身/特写，调整大小、位置和字幕左右侧。
- 导入时先复制再把过大的贴图缩到 4096，保留源文件。
- 首次加载会下载 Cubism Core，需要网络；模型按原作者许可使用。

CLI 导入：`"build/AI 剧本杀.app/Contents/MacOS/AIDM" --import-live2d "模型文件夹"`。以上渲染功能尚待 Mac 实机验收。

### 5. Mac 语音

在 **设置 › 语音**选择已安装的系统声音，或配置阿里云 Qwen 克隆音色。云端路径有创建音色、回填 ID、试听功能：

1. 配置自己账号的 Key 和地区；AI 主持使用千问时有 Key 复用路径。
2. 准备清晰、单人、无背景音乐的参考录音；界面建议 10–20 秒，支持 wav/mp3/m4a，小于 10 MB。
3. 创建后试听；音色 ID 的账号权限和服务模型兼容性需要实际验证。

云端合成失败有系统声音回退；大屏可开关朗读。代码另有本机 MLX 相关语音入口，需 Mac 环境验证，不能使用 Windows PyTorch 环境替代。Mac 尚未接入当前 Windows GPU API。

## 两版共有的游戏流程与已知限制

主持人控制阶段；玩家查看已解锁剧本、按次数搜证、选择公开线索、问 DM 和投票。线下讨论要由主持人手工记录，程序不会自动听取现场对话。角色换手机时，主持人释放角色，新手机重新选择可继承进度。

阶段、线索、搜证次数和投票由程序状态控制。AI 可提出发放条件线索，程序校验阶段和允许集合；条件本身的自然语言判断仍依赖 AI。

### 上下文与秘密保护

- 通过摘要控制增长，默认以保留30条近期公开事件为压缩目标；摘要失败或积压时保留全部未压缩事件，避免记忆缺口；发送前有总预算检查。Python 配置 `llm.context_budget`，Mac 在高级设置调整，默认32768。按文本 UTF-8 字节保守估算并预留输出；超预算拒绝请求，不静默裁掉剧本。
- 摘要必须非空且不超过600个 Unicode 码点；不合格重试一次，仍失败则保留旧摘要、压缩游标和原日志。压缩按批次进行；预算估算不是模型精确 tokenizer，图片开销仅为估计，需按实际模型容量配置。
- 角色本和私聊按提问者组织；公开提问不再附带该角色秘密摘要。但问答仍可能包含全局真相及主持提示，不能保证模型绝不泄露。
- 问答有禁用词匹配与有限重试，不能覆盖同义改写或暗示。**旁白整段生成并检查通过后才公开和朗读**；命中则检查原文回退，原文也命中就不播出。开局原文同样检查，取消的未审核内容不会写入公开记录。首句需等待整段生成。
- 两版旁白均排除全局真相和 `dm_notes`。原文、简介或已有公开摘要仍可能包含秘密，正式游戏前应审查剧本；关键词检查不是语义剧透检测。
- 支持过滤 `<think>...</think>`，不保证处理任意供应商的所有推理输出格式。
- 两版旁白均在换阶段时取消并丢弃过期结果；Swift 问答也已加入阶段/会话校验与发线索前重验，新增 Mac 测试需在 Mac 上执行。真实多人、长局、声卡和 Mac 功能仍需端到端验收。

本地模型慢时可以提高等待超时，但不会提升生成速度。语音服务、文字模型和游戏服务是独立组件，应分别检查配置和状态。

## 数据位置与文件结构

| 数据 | Python 网页版 | Mac 原生版 |
|---|---|---|
| 剧本 | `jubensha-dm/scripts/` 或 `--script` 指定目录 | 内置 `Resources/Demo/`，用户剧本位于数据目录 |
| 存档 | `jubensha-dm/saves/` | 数据目录下 `Saves/` |
| OCR | 工具默认 `work/` 或 `--out` 指定位置 | 数据目录下 OCR 输出 |
| 模型与语音缓存 | Windows 工具使用 `data/LocalTTS/`、`data/VoiceCache/` | 原生数据目录下对应子目录 |

Mac 数据目录通常是项目 `data/`，离开项目运行时回退到 `~/Library/Application Support/AI DM/`，另可有自定义路径；以剧本库底部显示的位置为准。

```text
README.md
jubensha-dm/
  run.py、start.bat、start.sh    Python 网页版入口
  config.example.yaml          Python 配置模板
  jubensha/                    Python 引擎、服务、网页与语音代理
  scripts/demo/                Python 示例剧本
  tools/ocr.py、tools/draft.py  Python 剧本导入工具
  tools/windows_voice/         Windows GPU 语音、实验与文档
  tests/                       Python / JavaScript 回归测试
  Package.swift、build.sh      Mac 原生构建
  Sources/AIDM/                Mac 应用、引擎、服务、UI、导入、Live2D
  Resources/                  Mac 网页资源、示例、Live2D 与本机语音资源
```

## Git 协作与生成文件

保留 `main` + 功能分支 + Pull Request 的协作流程。已有任务继续在自己的分支（例如 `Harry`）完成；不要为了切分支丢弃未提交工作。新任务在工作区处理妥当后，从最新 `main` 创建分支：

```bash
git status --untracked-files=all
git switch main
git pull --ff-only origin main
git switch -c feature/your-task
# 修改后，只添加本次文件并审查：
git add <本次修改的文件路径>
git diff --cached
git commit -m "Describe the change"
git push -u origin feature/your-task
```

PR 使用 `base: main`、`compare: 你的功能分支`。正常协作无需重新 `git init` 或使用 `--allow-unrelated-histories`。

`.venv/`、本机配置与 Key、模型下载、存档、OCR/语音缓存及实验输出不应直接提交。**`.gitignore` 只保护尚未跟踪的文件，不能保证整个 `data/` 不会上传。** 仓库已有部分运行数据受 Git 跟踪，应独立审查其保留、外置或 LFS 方案；不要删除素材或改写历史来代替审查。

稳定性细节、OCR 新输出路径与验证边界见 [STABILITY.md](jubensha-dm/STABILITY.md)；最新整体检查、修复与模拟整局验收见 [OVERALL-REVIEW.md](jubensha-dm/OVERALL-REVIEW.md)。

补充文档：[完整功能审计](jubensha-dm/README-FEATURE-AUDIT.md) · [当前流程与验证记录](jubensha-dm/PROJECT-STATUS.md) · [素材清单与清理建议](jubensha-dm/tools/windows_voice/ASSET-CLEANUP.md)。
