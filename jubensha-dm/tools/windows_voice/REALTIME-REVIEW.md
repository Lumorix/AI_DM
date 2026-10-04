# Windows 八千代语音实时性验证 · 2026-10-03

当前使用用户认可的 A：Qwen3-TTS 0.6B Base + 原有八千代参考录音。未应用用户否定的 B LoRA；本轮是推理优化与测量，没有训练权重更新。C 及原训练产物保留。

## 已运行

新增 `realtime_voice.py`：模型常驻 GPU、参考音色提示缓存、最多 32 条台词的内存缓存、本机文字输入试听页、非空/长度/格式检查、单次推理互斥。只监听 127.0.0.1，不上传录音，不需要 Mac，不自动下载模型。

试听地址：http://127.0.0.1:8773/ 。本轮服务进程启动 PID 为 42120；退出后需重新运行。启动命令（在 jubensha-dm 目录）：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\realtime_voice.py --serve
```

复现测量并启动服务（请先关闭旧服务，避免端口冲突）：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\realtime_voice.py --benchmark --serve
```

脚本只使用已下载的本地模型。页面当前使用原 A 音色，未叠加 A+ 的高频 EQ。语音由整句生成完成后返回，不能称为逐帧流式。缓存仅在进程生命周期内有效；重启需重新生成。

## RTX 4060 8GB 实测

BF16、SDPA、PyTorch CPU 线程 4，参考音色提示预先提取。模型与参考加载用时 5.76 秒（不含 Python 依赖导入）。

| 测试 | 音频长度 | 生成用时 | RTF |
|---|---:|---:|---:|
| 首次完整句 | 6.40 秒 | 19.68 秒 | 3.08 |
| 热机第一短句 | 2.48 秒 | 6.64 秒 | 2.68 |
| 热机第二短句 | 3.04 秒 | 8.47 秒 | 2.79 |
| 热机完整句 | 6.40 秒 | 16.80 秒 | 2.63 |

RTF = 生成时间 / 音频时长；持续实时生成需要低于 1，并留出余量。峰值 PyTorch 已分配显存约 2245 MiB，保留显存约 2324 MiB；此数不包括桌面、其他程序或所有驱动占用。

另外通过真实 HTTP 调用验证新短句：1.68 秒音频首次请求 5.730 秒；再次命中缓存 0.00849 秒。该时间是客户端收到完整 WAV 的时间，不包括浏览器解码和声卡实际出声延迟。页面 HTTP 200、有效 PCM WAV、缓存命中及三种错误请求 HTTP 400 均已验证。音色自然度需人耳试听。

测量和四段 WAV：`data/LocalTTS/windows/outputs/realtime-20261003-201646/`。服务日志：同级 `realtime-service.stdout.log` / `realtime-service.stderr.log`。输出遵循现有 Git 忽略规则。

## 结论与下一步

- 现有 Windows 原生推理路径能运行，显存能容纳；当前瓶颈主要表现为生成速度。
- 固定剧本台词适合预生成缓存；当前测试尚未批量生成整个剧本，也未接入游戏播报。
- 即兴文本尚未达到连续实时。单纯把文本拆句或增加 LoRA 训练步数，不能据此认为推理会加速。
- 后续若追求低延迟，应单独验证更快的推理后端及真正音频流式输出；迁移前必须保持相同参考音色并重新试听，不先假定必须用云端。
- 继续改音色训练前，需要选定经过人工校对的训练素材；不沿用已否定的 B 方向。现有 accepted A/C 都是参考音色克隆基础版，不是已完成的新训练模型。

官方 API 示例可复用 `create_voice_clone_prompt`：https://github.com/QwenLM/Qwen3-TTS 。本机安装的 `generate_voice_clone` 文档明确说明 `non_streaming_mode=False` 不会开启真正的流式音频生成；本轮按本机实际接口测试，不套用其他后端的宣传延迟。
