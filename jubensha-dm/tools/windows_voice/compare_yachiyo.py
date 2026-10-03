"""Compare the same Chinese prompt/reference before and after a LoRA pilot."""
from pathlib import Path
import argparse
import json
import os
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', type=Path, required=True)
    ap.add_argument('--text', default='各位玩家，欢迎来到听涛居。请仔细观察线索，找出隐藏的真相。')
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2]
    os.environ.setdefault('HF_HOME', str(root/'data/LocalTTS/hf-cache/windows'))
    import numpy as np
    import soundfile as sf
    import torch
    from peft import PeftModel
    from qwen_tts import Qwen3TTSModel
    run = args.run.resolve()
    meta = json.loads((run/'metrics.json').read_text(encoding='utf-8'))
    dataset = Path(meta['dataset'])
    ref, ref_sr = sf.read(dataset/'ref.wav', dtype='float32')
    model = Qwen3TTSModel.from_pretrained(meta['base'], device_map='cuda:0',
        dtype=torch.bfloat16, attn_implementation='sdpa', local_files_only=True)
    output = run / ('comparison-'+time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(exist_ok=False)
    sf.write(output/'reference.wav', ref, ref_sr)
    scores = {}
    with torch.inference_mode():
        ref_embedding = model.model.extract_speaker_embedding(ref, ref_sr)
        for mode in ['before', 'after']:
            if mode == 'after':
                model.model.talker = PeftModel.from_pretrained(model.model.talker,run/'adapter').merge_and_unload()
            model.model.eval()
            torch.manual_seed(42)
            torch.cuda.reset_peak_memory_stats()
            start = time.perf_counter()
            wavs, sr = model.generate_voice_clone(text=args.text, language='Chinese',
                ref_audio=(ref,ref_sr), x_vector_only_mode=True, max_new_tokens=512)
            torch.cuda.synchronize()
            elapsed = time.perf_counter()-start
            wav = np.asarray(wavs[0])
            if not wav.size or not np.isfinite(wav).all() or np.max(np.abs(wav)) < 1e-6:
                raise RuntimeError(f'{mode}: invalid or silent audio')
            sf.write(output/f'{mode}.wav',wav,sr)
            embedding = model.model.extract_speaker_embedding(wav,sr)
            similarity = torch.nn.functional.cosine_similarity(ref_embedding,embedding,dim=-1).mean().item()
            scores[mode] = {'seconds':len(wav)/sr,'generation_seconds':elapsed,
                'reference_speaker_cosine':similarity,
                'peak_allocated_mib':torch.cuda.max_memory_allocated()/1024**2}
            print(f'{mode}: {json.dumps(scores[mode])}',flush=True)
    (output/'comparison.json').write_text(json.dumps({'text':args.text,'scores':scores,
        'note':'Same seed, Japanese reference and Chinese text. Speaker-embedding cosine is only a proxy; human listening and pronunciation review are still required.'},ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'COMPARISON: {output}',flush=True)


if __name__ == '__main__':
    main()
