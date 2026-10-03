# Windows GPU 语音测试

在 Mac 编写应用，在 Windows 的 NVIDIA GPU 上运行此测试。此目录是独立的 PyTorch 语音入口，不修改现有 Mac MLX 服务。

## 环境

Python 3.12、NVIDIA 驱动、PyTorch 2.8.0 CUDA 12.8、torchaudio 2.8.0、qwen-tts 0.1.1。
`nvidia-smi` 的 CUDA 版本是驱动支持的信息，不要求安装同版本 CUDA Toolkit。
从 `jubensha-dm` 目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\windows_voice\setup.ps1
```

首次创建环境需要 `python` 指向 Python 3.12。此次由 Codex 建立的环境依赖本机 Codex 自带 Python 的路径；如果该运行时移除，使用独立安装的 Python 3.12 重建环境。

## 克隆与测量

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\smoke_cuda.py
```

首次从官方 `Qwen/Qwen3-TTS-12Hz-0.6B-Base` 下载模型，记录下载版本。默认用 `voices/mandarin-ref/ref.wav` 和 `ref.txt` 生成中文测试音频。
下载完成后可离线复测：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\smoke_cuda.py --offline --text "各位玩家，请开始第一轮讨论。"
```

`--voice` 指定 `data/LocalTTS/voices/` 下同时包含 `ref.wav` 与准确 `ref.txt` 的子目录。目前八千代素材尚未整理成该格式。

输出写到 `data/LocalTTS/windows/outputs/<时间>/smoke.wav` 和 `metrics.json`。指标包括模型载入时间、合成时间、音频长度和 PyTorch 显存峰值。显存峰值不包含桌面/浏览器或 CUDA 驱动等全部占用；实时倍率小于 1 表示合成比播放快。首次运行还可能包含初始化开销。

使用 BF16 和 PyTorch SDPA，无需编译 FlashAttention。脚本验证音频非空、有限且非静音；音色相似度与发音质量需试听确认。这是参考音频克隆推理，不是训练。

## 保存与协作

- 提交本目录的脚本和说明。
- `.venv/`、模型、HF 缓存和 `outputs/` 已由项目规则忽略，不提交 Git。
- Mac 与 Windows 分别建立环境，不复制虚拟环境。
- Mac 当前仍调用本机 MLX 服务；远程 Windows 语音 API 与 Mac 设置尚待接入。
- 训练前先用固定文本建立试听基准，审查数据切片及转录。该 8GB GPU 尚未验证微调配置。

## RTX 4060 首次实测（2026-10-02）

- 模型版本：`5d83992436eae1d760afd27aff78a71d676296fc`
- 测试文本：欢迎来到听涛居。请大家选择角色，我们的故事即将开始。
- 音频：6.32 秒，24 kHz；生成用时：22.56 秒；模型加载：3.43 秒。
- 实时倍率：3.57；PyTorch 峰值已分配显存：2440 MiB，峰值保留显存：2684 MiB。
- 已通过 CUDA 实际运算、依赖一致性及非静音 WAV 输出检查。音色和发音需要用户试听。
- 未启动训练，未修改 Mac 语音接口，未提供跨机器服务。
- 本次导入时提示缺少 SoX 和 FlashAttention；该 WAV 参考录音测试无需它们且已经成功，不代表所有音频处理功能均可用。

## 八千代 LoRA 小规模微调（2026-10-03）

目标：八千代音色朗读中文。原有 93 个切片编号与 107 段旧转录不可靠对应，因此本次用本地 faster-whisper-small 逐片重新生成日语标签，未修改原素材。

自动筛选得到 15 段候选：12 段训练、2 段验证、1 段在分界处排除。标签未经人工校对，筛选不保证无背景音乐或字词完全正确。本次仅验证训练及跨语言试听流程，不代表生产质量。

- Qwen 0.6B Base 保持原样，仅训练 talker 注意力 q/v 的 rank-8 LoRA。
- 30 次优化更新，batch 1、累计 2 次梯度，学习率 5e-5；1351680 个可训练参数。
- 验证损失 14.9217 → 10.6256；验证集只有 2 段，不能据此推断中文发音或音色质量。
- 更新参数 L2 差异 1.0917，确认不是单纯运行推理。
- 训练与验证用时约 37.18 秒（不含转录、下载、音频编码），峰值已分配显存约 2229 MiB。
- 独立 adapter 约 5.4 MB，保存在被忽略的 outputs 下；原模型未改。

从 jubensha-dm 目录运行：

```powershell
$voicePython = '.\data\LocalTTS\windows\.venv\Scripts\python.exe'
& $voicePython -X utf8 .\tools\windows_voice\prepare_yachiyo.py
# 把下面路径替换为上一步打印的 DATASET；每次创建新输出，不覆盖原数据。
& $voicePython -X utf8 .\tools\windows_voice\train_yachiyo.py --dataset '.\data\LocalTTS\windows\outputs\yachiyo-data-20261003-094046' --steps 30
# 指定训练输出目录（含 metrics.json 和 adapter）。
& $voicePython -X utf8 .\tools\windows_voice\compare_yachiyo.py --run '.\data\LocalTTS\windows\outputs\yachiyo-lora-20261003-094225'
```

train_yachiyo.py 每次从基础模型开始一个新实验，不是恢复优化器状态。checkpoint 是独立 LoRA 推理权重；数据编码会缓存在所选数据输出目录中。修改数据后请建立新数据目录。

对照使用相同中文、参考录音和随机种子；before/after 都使用八千代参考音色。speaker cosine 只作自动代理指标，不是人耳相似度百分比。试听发音、音色、断句和杂音后再决定是否扩大训练。

官方数据布局源自 vendor/qwen_finetuning/dataset.py，来源版本记在 SOURCE.json，许可证随附。LoRA 与低显存训练循环为本项目适配。依赖版本已记录到 requirements.lock.txt。

本轮中文对照已生成：comparison-20261003-094325/before.wav（6.40秒）与 after.wav（4.24秒），文本为“各位玩家，欢迎来到听涛居。请仔细观察线索，找出隐藏的真相。”。自动转录识别出主要句子，但剧本名出现误识；音色余弦代理指标均为0.9766，没有显示改善。未替换应用模型，后续应先试听与校对，不根据训练损失继续盲目增加步数。
