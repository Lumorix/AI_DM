# Windows 语音 API v1

此服务仅提供整句 WAV 生成。当前八千代参考音色仍是实验版本，接口完善不代表中文发音或音色一致性已经修好。不自动下载模型，不训练，不上传录音。

将 voice_service.py、voice_config.example.json 放在 jubensha-dm/tools/windows_voice。配置路径均相对于 JSON 所在目录解析；可以使用绝对路径。更换模型目录、参考录音和生成参数后重启服务，内存缓存会清空，避免混用旧音色。当前支持 Qwen3-TTS Base 兼容模型；朋友的 LoRA adapter 不能直接当作完整模型目录。

从 jubensha-dm 运行：

```powershell
.\data\LocalTTS\windows\.venv\Scripts\python.exe -X utf8 .\tools\windows_voice\voice_service.py --config .\tools\windows_voice\voice_config.example.json
```

默认仅监听 127.0.0.1:8775，不影响旧试听服务8773。暂不开放局域网访问。Ctrl+C 停止服务。

## 接口

- GET /health：就绪返回200，加载中/失败返回503。JSON包含status、busy、error、api_version、quality、streaming、max_chars。
- POST /v1/audio/speech：Content-Type: application/json，请求为 `{"text":"现在请大家开始讨论。"}`，成功返回audio/wav。/synthesize为相同接口的兼容别名。
- X-Cache为hit/miss，X-Audio-Seconds为音频时长，X-Generation-Seconds为该音频原始生成耗时（缓存命中时也保留原值）。
- 错误统一为 `{"error":{"code":"busy","message":"..."}}`。400非法文本、403跨源拒绝、404未知接口、413请求体过大、415类型错误、429生成忙碌、503模型未就绪、500生成失败。

```powershell
Invoke-RestMethod http://127.0.0.1:8775/health
$payload = @{text='现在请大家开始讨论。'} | ConvertTo-Json
Invoke-WebRequest http://127.0.0.1:8775/v1/audio/speech -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -OutFile "$env:TEMP\voice-test.wav"
```

接口不接受客户端传模型路径或任意参考文件。内存缓存最多32条；示例配置已启用512 MiB磁盘缓存，按模型、参考录音和参数隔离，详见 CACHE.md。游戏播放队列、停止和跳过已接入，详见 PLAYBACK.md；停止播放不会强行中止已提交的GPU计算。

不加载GPU的协议测试（测试文件与服务文件位于同一目录）：`python -m unittest test_voice_service.py`。这些测试使用假引擎验证HTTP协议、状态、缓存和错误恢复，不能证明真实模型的音质。
