# Windows 整体检查记录 · 2026-10-04

范围：Harry 当前工作区的 Python 游戏、Windows 语音服务、浏览器播报控制、启动脚本、依赖和已跟踪大文件。未切换分支、未提交或推送、未修改已有游戏存档或模型素材，未重写 Git 历史。

## 本轮修复

- 阶段切换无论是否开启新旁白，都会取消旧旁白任务；已生成的部分记录归属原阶段。
- AI 回答绑定发问时的阶段索引、阶段开始时间和玩家设备令牌。阶段变化、角色释放或换设备后，过期回答不写入日志、不发线索、不返回回答内容。
- 同一角色并发提问在游戏锁内占用忙碌状态，避免两个等待请求同时调用AI；落盘异常也释放忙碌状态。
- 线索在写入前再次检查可发范围、持有和公开状态，避免等待期间重复发放。
- 管理员跳转阶段的非法参数返回400，避免字符串、对象、布尔值、越界索引触发500或误跳转。
- 语音生成、音频播放及浏览器朗读失败时关闭朗读开关，清理待播内容，避免后续文字反复请求失败服务；按钮允许重新开启。
- Windows启动器直接调用项目虚拟环境，检查核心依赖，创建/安装失败时停止，不落到系统Python继续运行；游戏进程显式UTF-8，修复输出重定向时的中文编码错误。
- 更新过时说明：磁盘缓存和游戏播放集成已经存在，GPU正在执行的推理尚不能强制取消。

## 验证结果

- Python游戏/会话/代理：15项通过，包括完整demo流程、角色冲突、搜证次数、线索权限、投票、存档恢复、换设备、异步旧回答和旁白取消。
- Windows语音API/缓存：10项通过。
- JavaScript重连/播放：19项通过，使用模拟fetch、Audio和speechSynthesis。
- 两个Python虚拟环境 `pip check` 均正常。
- `start.bat --help` 实际通过；应用、测试和Windows语音工具24个Python文件通过AST语法检查。
- Git差异空白检查通过。未重新下载模型、运行训练或产生付费模型调用。

## 尚未通过或尚未完成

- 真实Chrome/Edge出声测试：前轮控制工具授权超时，尚未操作浏览器完成播放、停止、跳过、阶段切换的端到端验证。本轮代码测试不能替代该项。
- Windows语音音色与中文发音仍有已知问题；缓存和接口修复不代表音质通过。
- Mac Swift应用未在Windows编译，本轮Python异步状态修复未宣称覆盖Swift实现。
- 尚未批量预生成完整剧本，仍是播放时逐条填充缓存。
- 语音代理仅供主持电脑localhost大屏使用；手机语音播放和远程Mac调用不在已完成范围。

## 仓库体积

当前分支仍跟踪下列大文件（约值）：

| 文件 | MiB |
|---|---:|
| data/LocalTTS/voices/yachiyo/vocals_clean_44k.wav | 49.6 |
| data/LocalTTS/voices/yachiyo/source_44k.wav | 49.6 |
| data/LocalTTS/seed-vc/campplus_cn_common.bin | 26.7 |

建议将未来模型下载和可再生成素材改为校验和清单+独立存储，协作确有需要的资产再评估Git LFS。当前未移除跟踪、迁移LFS或重写历史，避免影响朋友分支与已有素材。本轮仅检查当前本地分支，不是完整远端Git历史审计。

复现测试（jubensha-dm目录）：

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -p 'test_*.py'
.\data\LocalTTS\windows\.venv\Scripts\python.exe -m unittest discover -s tools/windows_voice -p 'test_voice_*.py'
node --test tests/playback.test.cjs tests/connect.test.cjs
```

Node在本机使用Codex随附运行时执行；若终端node不可用，先配置Node路径。以上测试不使用真实玩家存档。
