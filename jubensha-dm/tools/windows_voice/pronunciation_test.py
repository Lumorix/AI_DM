"""Compare Chinese pronunciation with the same Yachiyo reference on 0.6B/1.7B."""
from pathlib import Path
import argparse
import json
import os
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--reference', type=Path, required=True)
    ap.add_argument('--size', choices=['0.6', '1.7'], default='1.7')
    ap.add_argument('--text', default='各位玩家，欢迎来到听涛居。请仔细观察线索，找出隐藏的真相。')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    tts = root/'data/LocalTTS'
    os.environ.setdefault('HF_HOME', str(tts/'hf-cache/windows'))
    import numpy as np
    import soundfile as sf
    import torch
    from huggingface_hub import HfApi, snapshot_download
    from qwen_tts import Qwen3TTSModel
    model_id = f'Qwen/Qwen3-TTS-12Hz-{args.size}B-Base'
    revision = HfApi().model_info(model_id).sha
    dest = tts/f'models/Qwen3-TTS-12Hz-{args.size}B-Base-pytorch'
    print(f'Download {model_id} revision {revision}',flush=True)
    snapshot_download(model_id, revision=revision, local_dir=dest, max_workers=2)
    (dest/'download-revision.json').write_text(json.dumps({'model':model_id,'revision':revision},indent=2))
    ref,sr = sf.read(args.reference,dtype='float32')
    model = Qwen3TTSModel.from_pretrained(str(dest),device_map='cuda:0',dtype=torch.bfloat16,
        attn_implementation='sdpa',local_files_only=True)
    model.model.eval()
    torch.manual_seed(42)
    torch.cuda.reset_peak_memory_stats()
    start = time.perf_counter()
    with torch.inference_mode():
        wavs,out_sr=model.generate_voice_clone(text=args.text,language='Chinese',ref_audio=(ref,sr),
            x_vector_only_mode=True,max_new_tokens=512,do_sample=True,temperature=0.9,
            subtalker_dosample=True,subtalker_temperature=0.9)
    torch.cuda.synchronize()
    elapsed=time.perf_counter()-start
    wav=np.asarray(wavs[0])
    if not wav.size or not np.isfinite(wav).all() or np.max(np.abs(wav))<1e-6:
        raise RuntimeError('Invalid output audio')
    output=tts/'windows/outputs'/f'yachiyo-chinese-{args.size}b-{time.strftime("%Y%m%d-%H%M%S")}'
    output.mkdir(parents=True,exist_ok=False)
    sf.write(output/'chinese.wav',wav,out_sr)
    result={'model':model_id,'revision':revision,'reference':str(args.reference.resolve()),
        'text':args.text,'seed':42,'audio_seconds':len(wav)/out_sr,'generation_seconds':elapsed,
        'peak_allocated_mib':torch.cuda.max_memory_allocated()/1024**2,
        'peak_reserved_mib':torch.cuda.max_memory_reserved()/1024**2,
        'adaptation':'reference voice cloning only, no LoRA applied',
        'quality_status':'Pronunciation and accent require listening; larger model is not a guarantee.'}
    (output/'metrics.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
    print(f'OUTPUT: {output}',flush=True)


if __name__=='__main__':
    main()
