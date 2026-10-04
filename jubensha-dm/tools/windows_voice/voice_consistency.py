"""Controlled audition of speaker-only versus full reference prompting; no training."""
from pathlib import Path
import argparse
import gc
import html
import json
import os
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--text', help='Reproduce a user sentence with original and full-reference sampling')
    ap.add_argument('--whole-text', action='store_true', help='Condition on all text before audio generation')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    tts = root/'data/LocalTTS'
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ.setdefault('HF_HOME', str(tts/'hf-cache/windows'))
    import numpy as np
    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel
    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    source = tts/'windows/outputs/yachiyo-data-20261003-094046'
    output = tts/'windows/outputs'/('consistency-'+time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True)
    print('OUTPUT: '+str(output), flush=True)
    (output/'reference.wav').write_bytes((source/'ref.wav').read_bytes())
    reference_text = (source/'ref.txt').read_text(encoding='utf-8').strip()
    model = Qwen3TTSModel.from_pretrained(str(tts/'models/Qwen3-TTS-12Hz-0.6B-Base-pytorch'),
        device_map='cuda:0', dtype=torch.bfloat16, attn_implementation='sdpa', local_files_only=True)
    model.model.eval()
    with torch.inference_mode():
        speaker = model.create_voice_clone_prompt(ref_audio=str(source/'ref.wav'), x_vector_only_mode=True)
        full = model.create_voice_clone_prompt(ref_audio=str(source/'ref.wav'), ref_text=reference_text,
                                               x_vector_only_mode=False)
    variants = [('original', '原设置：说话人特征 + 随机采样', speaker, True),
                ('greedy', '实验 1：说话人特征 + 关闭随机采样', speaker, False),
                ('full', '实验 2：完整日语参考提示 + 关闭随机采样', full, False)]
    texts = ['各位玩家，欢迎来到听涛居。', '现在请大家开始讨论，仔细观察线索。']
    if args.text:
        texts = [args.text]
        variants = [('original', '原设置：说话人特征 + 随机采样', speaker, True),
                    ('full-sampled', '实验：完整日语参考提示 + 相同随机采样', full, True)]
    rows = []
    for name, label, prompt, sample in variants:
        for index, text in enumerate(texts):
            torch.manual_seed(42)
            torch.cuda.synchronize()
            start = time.perf_counter()
            with torch.inference_mode():
                wavs, sr = model.generate_voice_clone(text=text, language='Chinese', voice_clone_prompt=prompt,
                    non_streaming_mode=args.whole_text,
                    max_new_tokens=768 if args.text else 256, do_sample=sample, subtalker_dosample=sample,
                    temperature=0.9, subtalker_temperature=0.9)
            torch.cuda.synchronize()
            wav = np.asarray(wavs[0])
            assert wav.size and np.isfinite(wav).all() and abs(wav).max() > 1e-6
            filename = f'{name}-{index+1}.wav'
            sf.write(output/filename, wav, sr)
            sf.write(output/f'{name}-{index+1}-start.wav', wav[:int(sr*1.5)], sr)
            row = dict(variant=name, label=label, text=text, file=filename,
                       seconds=len(wav)/sr, generation_seconds=time.perf_counter()-start)
            rows.append(row)
            (output/'generation.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
            print(json.dumps(row, ensure_ascii=False), flush=True)
    del model, speaker, full, variants, prompt
    gc.collect()
    torch.cuda.empty_cache()
    from faster_whisper import WhisperModel
    from scipy.signal import resample_poly
    from math import gcd
    asr = WhisperModel(str(tts/'models/faster-whisper-medium'), device='cpu', compute_type='int8', cpu_threads=4)
    for row in [dict(file='reference.wav', variant='reference')] + rows:
        audio, rate = sf.read(output/row['file'], dtype='float32')
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        factor = gcd(rate, 16000)
        audio = resample_poly(audio, 16000//factor, rate//factor)
        segments, info = asr.transcribe(audio, beam_size=3)
        row['asr_detected_language'] = info.language
        row['asr_text'] = ''.join(s.text for s in segments)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        if row['variant'] == 'reference':
            reference_asr = row
    report = dict(reference_text=reference_text, reference_human_reviewed=False, reference_asr=reference_asr,
                  training=False, seed=42, non_streaming_mode=args.whole_text,
                  max_new_tokens=768 if args.text else 256, rows=rows,
                  caveat='ASR cannot establish naturalness, tone accuracy or speaker consistency; human audition required.')
    (output/'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    page = '<!doctype html><meta charset="utf-8"><title>八千代一致性排查</title><style>body{max-width:900px;margin:40px auto;background:#171923;color:#eee;font:17px/1.8 system-ui}section{padding:18px;background:#242838;margin:14px 0}audio{width:100%}</style><h1>八千代：音色与中文开头对照</h1><p>比较同组两句是否像同一个人，并听中文开头是否清楚。实验结果尚未替换默认声音。ASR 正确不等于发音标准。</p><h2>日语参考原声</h2><audio controls src="reference.wav"></audio>'
    page += '<p>整段文本预先输入：' + str(args.whole_text) + '</p>'
    for row in rows:
        page += f'<section><h2>{html.escape(row["label"])}</h2><p>{html.escape(row["text"])}</p><audio controls src="{row["file"]}"></audio><details><summary>单独听开头 1.5 秒 / 自动转录</summary><audio controls src="{row["file"].replace(".wav", "-start.wav")}"></audio><p>{html.escape(row["asr_detected_language"]+": "+row["asr_text"])}</p></details></section>'
    page += '<script>document.querySelectorAll("audio").forEach(a=>a.onplay=()=>document.querySelectorAll("audio").forEach(b=>{if(a!==b)b.pause()}));</script>'
    (output/'index.html').write_text(page, encoding='utf-8')
    print('DONE: '+str(output), flush=True)


if __name__ == '__main__':
    main()
