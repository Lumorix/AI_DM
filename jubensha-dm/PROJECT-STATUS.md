# AI_DM 当前完成任务与可用流程

更新：2026-10-04。依据当前本地 Harry 分支（检查时 HEAD a37e9dd）、代码、启动配置、测试和实验记录整理。检索范围包括应用源码、网页、工具、配置、测试、文档及素材清单；没有重新验证全部大型模型内容或远端Git历史。

## 当前结论

Windows Python 网页版已经具备可做整局测试的基础功能，本地语音API、播放队列和持久缓存已经接入。44项自动化测试本次重新运行全部通过。真实多人联网/浏览器实际出声尚未完成端到端验收，八千代声音的中文发音和一致性也没有通过质量验收。

项目同时有Mac Swift原生版。Mac界面、Live2D和原生导入流程存在于源码中，不代表已在Windows实现；近期Python修复也不保证Swift版具有相同实现。

## 完成任务清单

| 模块 | 当前完成内容 | 验证边界 |
|---|---|---|
| 游戏基本流程 | 示例《听涛居》、角色加入、阶段推进、搜证次数、私有/公开线索、投票、存档恢复 | 自动化demo流程通过 |
| 角色与会话 | 换手机释放角色、继承线索进度、令牌失效、旧SSE会话被踢出 | 会话回归通过 |
| 网页连接 | 断线重连、清理计时器/监听器、避免恢复前台时重复连接 | JavaScript模拟测试通过 |
| AI问答时序 | 并发问题忙碌控制；阶段/设备变更后丢弃过期回答；发线索前再次验证 | Python并发测试通过 |
| 旁白时序 | 换阶段取消旧任务；部分旁白记录属于原阶段 | Python回归通过 |
| 管理接口 | 非法阶段编号返回400，非对象JSON有容错 | API测试通过 |
| Windows启动 | 直接使用项目虚拟环境、检查核心依赖、失败停止、UTF-8输出 | start.bat --help实测通过 |
| 统一语音API | 配置模型/参考音频/参数；health；WAV合成；限长、忙碌与错误响应 | 模拟测试及此前一次真实GPU请求通过 |
| 游戏语音接入 | 大屏可选浏览器声音/八千代实验音色；本机代理到语音API | 代理自动化测试通过 |
| 播放控制 | 排队、停止本段、跳过当前句、阶段/声音切换清理、过期结果丢弃、失败关闭朗读 | 模拟Audio/fetch测试通过，实际声卡未验收 |
| 缓存 | 32条内存缓存；示例配置512 MiB磁盘缓存；按模型内容、参考音频、参数和依赖隔离；损坏重建 | 缓存自动化测试通过 |
| 音色实验 | CUDA验证、0.6B/1.7B参考音色克隆、30步LoRA试验、中文对照、亮度EQ、速度及开头错读复现 | 实验已完成，不等于音质达标 |
| 素材管理 | 124个音频/权重的相对路径/大小/SHA-256清单，无字节完全相同项，素材保留 | 本地当前跟踪文件检查 |
| Git保护 | 根目录与应用忽略规则，虚拟环境、模型格式、日志、本机配置及生成物保护 | check-ignore已验证；历史文件仍需单独治理 |

音色结论：A（0.6B）和C（1.7B）曾被用户认为短句基本可用；B（日语LoRA试验）被否定。后续长句“夜幕低垂……”暴露开头错读及音色不一致，因此没有确定可正式使用的最终声音。参考录音和训练转录仍需人工审核，不应继续用错读合成音频训练。

## 文件导航

- `run.py`、`start.bat`：Windows游戏入口。
- `config.example.yaml`：游戏/AI配置模板；`config.yaml`为本机实际配置。
- `jubensha/engine.py`、`state.py`、`server.py`：流程、存档、接口。
- `jubensha/static/`：Windows网页大屏、玩家、管理页面。
- `jubensha/voice_proxy.py`：游戏至本机语音服务的固定目标代理。
- `scripts/demo/script.yaml`：Windows演示剧本。
- `tools/ocr.py`、`tools/draft.py`：Python OCR和剧本整理工具；存在于代码，本轮未做真实PDF导入验收。
- `tools/windows_voice/voice_service.py`、`voice_cache.py`：统一语音服务和缓存。
- `tools/windows_voice/voice_config.example.json`：当前A版模型与参考音频路径。
- `tools/windows_voice/prepare_yachiyo.py`、`train_yachiyo.py`、`compare_yachiyo.py`：数据准备、LoRA试验、前后对照。train脚本从基础模型开始新试验，并非恢复优化器训练。
- `pronunciation_test.py`、`voice_consistency.py`、`realtime_voice.py`：音质/一致性/速度诊断工具（均位于上述Windows语音目录）。
- `Sources/AIDM/`、`Resources/web/`、`Resources/live2d/`、`build.sh`：Mac原生实现，不等于Windows网页功能。
- `tests/`、`tools/windows_voice/test_voice_*.py`：自动化测试。

## 流程一：Windows先跑游戏（不必启用八千代）

在PowerShell进入应用目录：

```powershell
cd C:\Users\crazy\OneDrive\Desktop\AI_DM\jubensha-dm
.\start.bat --script scripts/demo --port 8000
```

没有config.yaml时，程序使用模拟AI。若已有config.yaml，先确认llm.provider是否为mock；真实模型配置会触发相应服务调用。无需先安装/训练语音模型才能测游戏。

1. 主持电脑打开 `http://127.0.0.1:8000/screen`。
2. 管理页面使用启动终端打印的带admin令牌链接，勿分享给玩家。
3. 玩家同一局域网打开终端给出的 `http://电脑局域网IP:8000/player`，选择角色。手机不能用127.0.0.1访问主持电脑。
4. 管理员推进阅读→搜证→讨论→投票→复盘，玩家查看角色本、搜证和公开线索。
5. 需要换手机：管理员释放角色，新手机重新选择，继承进度。
6. 下次相同命令默认读取 `saves/demo.json`。`--new`会开新局，并备份已有同名存档；日常续玩不要加该参数。

浏览器声音可在大屏开启。实际设备声音和手机网络连通性仍需现场测试，不保证当前每台设备都已可用。

## 流程二：接入真实AI回答

若config.yaml不存在，复制config.example.yaml；已有配置不要覆盖。设置llm.provider为openai并填写兼容接口base_url和model；api_key可用本机配置或JUBENSHA_API_KEY环境变量。这里的openai表示接口协议，不要求特定供应商。以实际服务文档为准，不把模板里的示例模型名当作当前可用保证。

重新启动游戏后测试一条普通提问，再检查公开/私聊、阶段权限和线索发放。模拟模式用于流程测试，不提供真实推理。原文旁白可设game.narration为verbatim。

## 流程三：Windows本机八千代实验播报

现有主机已经有独立语音环境；不需要每次重新运行setup.ps1。换一台电脑时需要另外准备环境、模型和参考音频，因为Git克隆不保证包含这些被忽略文件。

终端A在jubensha-dm目录启动：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\voice_service.py --config .\tools\windows_voice\voice_config.example.json
```

终端B检查：

```powershell
Invoke-RestMethod http://127.0.0.1:8775/health
```

模型加载中会返回503，就绪时status为ready。启动时计算模型校验摘要可能需要等待。

然后保持终端A运行，另开终端启动游戏。在主持电脑 `http://127.0.0.1:8000/screen` 选择“八千代（本机实验）”，开启朗读。切换到此声音本身不代表已开始播放。

- 使用“停止本段”或“跳过当前句”；阶段变化会清理旧播放。
- 当前整句生成后才播放，不是真正流式；短句测试不能代表长句质量或实时能力。
- 停止会取消浏览器等待并丢弃旧结果，GPU仍可能算完正在执行的一句。
- 服务/播放失败后开关变为关，文字照常显示；解决问题后重新开启。
- 语音代理只允许主持电脑localhost，手机或Mac远程调用尚未接入。
- 更换模型或参考音频可复制示例为voice_config.local.json（已忽略），修改后以--config指定该文件。LoRA adapter不能直接当作完整Base模型目录。
- 同一配置的同一句台词会复用缓存。512 MiB上限到达后不写新缓存，不自动删除旧文件。

单独试听页 `realtime_voice.py --serve` 默认8773属于早期实验工具，不是游戏统一API的8775；旧试听地址只有对应服务运行时才有效。

## 流程四：开发与协作

继续在Harry开发，main作为合并目标，朋友在自己的分支工作。先检查git status再提交指定源码/配置模板/测试；不要重新git init或反复使用--allow-unrelated-histories。跨电脑各自创建虚拟环境，模型和素材按清单另行同步。

检查时Harry与本地origin/Harry引用一致，HEAD为a37e9dd；这只是本地引用，未重新fetch。近期主体代码已在当前提交中；仍未提交的是两层gitignore及素材清单/整理文档，本总览也是新增文件。本轮未执行commit/push。

仍有185个已跟踪文件匹配忽略规则（OCR168、LocalTTS14、存档1、语音缓存2）；gitignore不能停止跟踪既有文件。未删除素材或迁移历史，push安全不能只靠忽略规则保证。README中较早的“data不会上传”描述不适用于所有现有受控文件。

## 验证结果与剩余工作

本次复跑44项：游戏/会话/代理15、语音接口/缓存10、连接/播放器19，全部通过。此前两个环境pip check、Windows启动器帮助命令和Python语法检查通过。

优先剩余任务：

1. 真实Chrome/Edge出声和多手机整局现场验收（前次浏览器控制授权超时）。
2. 人工审核八千代参考录音/转录，解决中文开头错读和跨句音色漂移。
3. 固定剧本批量预生成、一键联合启动游戏与语音（现在为两个服务分别启动）。
4. 与朋友约定完整模型/adapter、基础模型版本、参考素材与校验值的交付格式。
5. 已跟踪生成物清理方案，以及Mac编译和跨机器语音集成。

具体记录：tools/windows_voice/ 下 WINDOWS-AUDIT.md、VOICE-API.md、PLAYBACK.md、CACHE.md、CONSISTENCY-REVIEW.md、REALTIME-REVIEW.md、ASSET-CLEANUP.md。
