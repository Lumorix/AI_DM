# 语音素材清单与保留方案 · 2026-10-04

本轮保留全部素材，没有删除、移动、停止跟踪或改写历史。仅补充忽略规则、只读清单脚本与SHA-256清单。

## 实际检查

扫描当前Harry工作树中已由Git跟踪的 data/LocalTTS 音频/权重，共124个文件、162872843字节（约155.3 MiB）。未扫描完整Git历史，也未对被忽略的大模型、虚拟环境和所有输出目录做全量哈希。

| 类别（按路径初步分类） | 文件数 | MiB |
|---|---:|---:|
| 原始或参考音频 | 4 | 100.05 |
| 训练切片 | 93 | 18.25 |
| 第三方示例音频 | 13 | 7.36 |
| 评测生成音频 | 12 | 2.71 |
| 模型文件 | 2 | 26.95 |

未发现字节完全一致的重复文件。source_44k.wav 和 vocals_clean_44k.wav 均约49.6 MiB，但SHA-256不同，不能只看名称或大小合并。内容相似度、静音或音质未由此次哈希检查判断。

## 已落实的安全修正

- 忽略 seedvc-venv/，防止独立变声Python环境被误提交。
- 对 campplus_cn_common.bin 添加明确下载产物规则。它当前已被跟踪，仍然保留在Git中。
- 忽略今后新增的 voices/*/eval/ 下WAV生成音频，评测文本和配置不受影响；现有12段已跟踪评测音频仍然保留并继续显示修改。
- 没有整体忽略 voices/ 或 dataset/，不妨碍现有训练切片协作。
- 没有整体忽略或移动 seed-vc 源码，保留其LICENSE和示例。

`.gitignore` 不会停止跟踪现有文件，也不会减少现有提交或仓库历史的体积。

## 后续清理顺序与具体影响

1. 原始录音、参考录音、训练切片：先由参与训练的人确认用途和独立备份，继续保留；仅凭此次检查不能列为可删除。
2. 评测生成音频：先确认脚本、模型版本、参数足以复现，再考虑只保留代表性样本。若停止Git跟踪，会使新的克隆缺少音频，须先提供复现方式。
3. campplus模型：本地Seed-VC inference.py 已通过 hf_utils 从 funasr/campplus 下载到checkpoints缓存，但尚未验证离线部署能否移除根目录副本。先完成下载版本固定和干净环境测试，再决定是否停止跟踪。
4. 如需Git LFS或历史瘦身，另行协调main、Harry、Eric，明确会变更哪些提交和朋友如何同步；本轮不执行这些操作。

## 清单复现

voice-assets.manifest.json 保存相对路径、文件大小、SHA-256和扫描时HEAD。只表示该次工作树文件，不是备份。素材更改后请重新生成；清单文件本身没有音频内容。

从 jubensha-dm 目录运行：

```powershell
.\.venv\Scripts\python.exe -X utf8 tools/windows_voice/inventory_voice_assets.py --project . --output tools/windows_voice/voice-assets.manifest.json
```

脚本只读取Git索引和素材，在指定output写报告；不执行git add/rm或删除素材。
