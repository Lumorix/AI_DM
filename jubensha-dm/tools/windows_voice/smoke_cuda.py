"""Download Qwen 0.6B, clone a reference voice and measure CUDA inference."""
from pathlib import Path
import argparse
import json
import os
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--text', default='欢迎来到听涛居。请大家选择角色，我们的故事即将开始。')
    parser.add_argument('--voice', default='mandarin-ref')
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    tts = root / 'data' / 'LocalTTS'
    os.environ.setdefault('HF_HOME', str(tts / 'hf-cache' / 'windows'))
    import numpy as np
    import soundfile as sf
    import torch
    from huggingface_hub import HfApi, snapshot_download
    from qwen_tts import Qwen3TTSModel

    if not torch.cuda.is_available():
        raise RuntimeError('CUDA unavailable: install the CUDA PyTorch wheels first.')
    voice = (tts / 'voices' / args.voice).resolve()
    if not voice.is_relative_to((tts / 'voices').resolve()):
        raise ValueError('Voice must be inside data/LocalTTS/voices')
    ref = voice / 'ref.wav'
    transcript = (voice / 'ref.txt').read_text(encoding='utf-8').strip()
    audio, ref_sr = sf.read(ref, dtype='float32')
    print(f'GPU: {torch.cuda.get_device_name(0)}; reference: {len(audio)/ref_sr:.2f}s', flush=True)
    model_id = 'Qwen/Qwen3-TTS-12Hz-0.6B-Base'
    model_path = tts / 'models' / 'Qwen3-TTS-12Hz-0.6B-Base-pytorch'
    revision_file = model_path / 'download-revision.json'
    if args.offline:
        revision = json.loads(revision_file.read_text())['revision']
    else:
        revision = HfApi().model_info(model_id).sha
        print(f'Downloading {model_id} at {revision}', flush=True)
        snapshot_download(model_id, revision=revision, local_dir=model_path, max_workers=2)
        revision_file.write_text(json.dumps({'model': model_id, 'revision': revision}, indent=2))
    started = time.perf_counter()
    model = Qwen3TTSModel.from_pretrained(
        str(model_path), device_map='cuda:0', dtype=torch.bfloat16,
        attn_implementation='sdpa', local_files_only=True,
    )
    torch.cuda.synchronize()
    load_seconds = time.perf_counter() - started
    torch.manual_seed(42)
    torch.cuda.reset_peak_memory_stats()
    started = time.perf_counter()
    with torch.inference_mode():
        wavs, sr = model.generate_voice_clone(
            text=args.text, language='Chinese', ref_audio=(audio, ref_sr),
            ref_text=transcript, max_new_tokens=512,
        )
    torch.cuda.synchronize()
    seconds = time.perf_counter() - started
    wav = np.asarray(wavs[0])
    if wav.size == 0 or not np.isfinite(wav).all() or np.max(np.abs(wav)) < 1e-6:
        raise RuntimeError('Generated audio is empty, invalid or silent')
    output = tts / 'windows' / 'outputs' / time.strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    sf.write(output / 'smoke.wav', wav, sr)
    stats = {
        'model': model_id, 'revision': revision, 'gpu': torch.cuda.get_device_name(0),
        'torch': torch.__version__, 'cuda': torch.version.cuda, 'voice': args.voice,
        'text': args.text, 'sample_rate': sr, 'audio_seconds': len(wav)/sr,
        'load_seconds': load_seconds, 'generation_seconds': seconds,
        'real_time_factor': seconds/(len(wav)/sr),
        'peak_allocated_mib': torch.cuda.max_memory_allocated()/1024**2,
        'peak_reserved_mib': torch.cuda.max_memory_reserved()/1024**2,
    }
    (output / 'metrics.json').write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(stats, ensure_ascii=False, indent=2), flush=True)
    print(f'OUTPUT: {output / "smoke.wav"}', flush=True)


if __name__ == '__main__':
    main()
