# 八千代中文发音对照 · 2026-10-03

目标：八千代音色朗读中文。用户反馈上一轮中文发音/口音不自然，因此本轮优先比较中文基础能力，没有继续增加日语 LoRA 训练步数。

## 已完成

- 使用 Whisper medium 对原有切片重新转录；相同筛选门槛下仅接受 8 段，低于该流程设定的 15 段最低数量，未建立新训练集。保留候选记录于 `data/LocalTTS/windows/outputs/yachiyo-data-20261003-100746/`。
- 下载并运行官方 Qwen3-TTS 1.7B Base（PyTorch），固定版本 `fd4b254389122332181a7c3db7f27e918eec64e3`。
- 与旧版使用同一段八千代日语参考录音、同一句中文和随机种子 42。0.6B 与 1.7B 的采样配置一致。
- 新音频：5.52 秒；生成耗时 20.95 秒；PyTorch 峰值已分配显存 4161 MiB，峰值保留显存 4226 MiB。仅验证了这一短句，不代表长文本负载。
- 将三版音频交给同一 Whisper medium 再识别，均保留主要句子；“听涛居”出现“聽陶居/听道具”误识。自动转录不能证明声调、口音或自然度更好。
- 原始模型及原有 LoRA 都保留；没有把实验结果替换到应用中。

## 试听

本机试听页：<http://127.0.0.1:8772/>。包含原声、0.6B 基础版、0.6B LoRA 版和 1.7B 基础版。已检查页面与四段 WAV 均返回 HTTP 200。

若本机试听服务已停止，从 `jubensha-dm` 目录重新运行：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -m http.server 8772 --bind 127.0.0.1 --directory .\data\LocalTTS\windows\outputs\yachiyo-listening-review
```

原始结果和识别记录保存在 `data/LocalTTS/windows/outputs/yachiyo-chinese-1.7b-20261003-101038/`。播放器副本及模型均被 Git 忽略。

## 如何复现 1.7B 测试

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\pronunciation_test.py --size 1.7 --reference .\data\LocalTTS\windows\outputs\yachiyo-data-20261003-094046\ref.wav
```

该命令是参考音色克隆推理，不会更新权重。脚本每次查询官方模型版本并保存版本号，未来运行可能下载较新版本。此次对照版本已记录在 metrics.json。

## 尚待确认

1. 用户试听 A/B/C，判断哪一版中文最自然、是否保留八千代音色。尚无证据说明 1.7B 的口音一定改善。
2. 若三版均有明显日语口音，优先验证“清晰的中文语音 → 音色转换”路线，或准备人工校对的训练数据；不因日语训练损失下降就增加步数。
3. Mac 远程调用 Windows 语音 API 尚未接入，本页仅供当前 Windows 电脑试听。

## 已确认的用户选择与实时性目标

用户认可 A（0.6B Base）和 C（1.7B Base）目前基本可用，要求音色稍亮；明确否定 B（30步日语 LoRA）方向。后续不继续这条 B 微调路线，实验文件保留。

试听页新增 A+、C+：3 kHz、+2 dB 高架 EQ，保持时长和音高；先匹配 RMS，再限制峰值以避免削波。这只是可逆的后处理试听，不是新训练音色。brighten_audio.py 保存了可复现操作。

实时目标需要分别测试首段出声延迟与持续生成速度。现有单句实测：A 生成6.4秒音频用21.96秒（实时倍率3.43）；C生成5.52秒音频用20.95秒（实时倍率3.80）。时间不含模型下载和载入；这是首轮单句结果，尚未测常驻服务的多次延迟分布。当前 qwen-tts 0.1.1 的 generate_voice_clone 接口说明 non_streaming_mode=False 仅模拟流式文字输入，不提供真正流式音频输出。

本地8GB显存可以运行这两种推理，当前速度尚不足以持续实时朗读。下一阶段先测常驻模型、参考音色缓存和分句队列；仅做分句不能弥补持续吞吐慢于播放的问题。剧本固定台词可提前生成缓存，即兴回应可比较云端支持克隆音色的流式 TTS。云端声线与本地模型并不保证一致，必须用同样的八千代参考音频试听。尚未建立云端调用或上传参考音频。
