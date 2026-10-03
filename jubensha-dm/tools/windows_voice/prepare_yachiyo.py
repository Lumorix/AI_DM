"""Relabel existing Yachiyo clips locally; keep originals unchanged."""
from pathlib import Path
import hashlib
import json
import os
import time

ROOT = Path(__file__).resolve().parents[2]
TTS = ROOT / 'data/LocalTTS'
os.environ.setdefault('HF_HOME', str(TTS / 'hf-cache/windows'))


def main():
    import torch
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly
    from math import gcd
    dll_dir = Path(torch.__file__).parent / 'lib'
    os.environ['PATH'] = str(dll_dir) + os.pathsep + os.environ['PATH']
    dll_handle = os.add_dll_directory(str(dll_dir)) if os.name == 'nt' else None
    from faster_whisper import WhisperModel
    from huggingface_hub import HfApi, snapshot_download
    source = TTS / 'voices/yachiyo/dataset'
    output = TTS / 'windows/outputs' / ('yachiyo-data-' + time.strftime('%Y%m%d-%H%M%S'))
    (output / 'clips').mkdir(parents=True, exist_ok=False)
    model_id = 'Systran/faster-whisper-small'
    revision = HfApi().model_info(model_id).sha
    model_dir = snapshot_download(model_id, revision=revision,
        local_dir=TTS / 'models/faster-whisper-small', max_workers=2)
    asr = WhisperModel(model_dir, device='cuda', compute_type='float16')
    accepted, rejected = [], []
    files = sorted(source.glob('*.wav'))
    for index, file in enumerate(files):
        audio, sr = sf.read(file, dtype='float32', always_2d=True)
        audio = audio.mean(axis=1)
        duration = len(audio) / sr
        if not 1.2 <= duration <= 7 or not np.isfinite(audio).all():
            rejected.append({'file': file.name, 'reason': 'duration_or_invalid_audio'})
            continue
        factor16 = gcd(sr, 16000)
        audio16 = resample_poly(audio, 16000//factor16, sr//factor16).astype(np.float32)
        parts, _ = asr.transcribe(audio16, language='ja', beam_size=5,
            condition_on_previous_text=False, vad_filter=False)
        parts = list(parts)
        text = ''.join(p.text for p in parts).strip()
        confidence = min((p.avg_logprob for p in parts), default=-99)
        silence = max((p.no_speech_prob for p in parts), default=1)
        if len(text) < 3 or confidence < -0.75 or silence > 0.2:
            rejected.append({'file': file.name, 'reason': 'asr_confidence', 'text': text,
                             'avg_logprob': confidence, 'no_speech_prob': silence})
            continue
        factor = gcd(sr, 24000)
        audio24 = resample_poly(audio, 24000//factor, sr//factor)
        dest = output / 'clips' / file.name
        sf.write(dest, audio24, 24000)
        item = {'audio': str(dest), 'text': text, 'language': 'Japanese',
                'source': str(file), 'source_sha256': hashlib.sha256(file.read_bytes()).hexdigest(),
                'seconds': duration, 'avg_logprob': confidence, 'human_reviewed': False}
        accepted.append(item)
        with (output / 'transcripts.jsonl').open('a', encoding='utf-8') as log:
            log.write(json.dumps(item, ensure_ascii=False) + '\n')
        print(f'{index+1}/{len(files)} accepted={len(accepted)} {file.name}: {text}', flush=True)
    if len(accepted) < 15:
        raise RuntimeError(f'Only {len(accepted)} accepted clips: inspect {output}')
    # Chronological split with a one-clip gap; do not train on validation clips.
    boundary = int(len(accepted) * 0.8)
    train, validation = accepted[:boundary], accepted[boundary+1:]
    reference = max((r for r in train if 2 <= r['seconds'] <= 6), key=lambda r: r['avg_logprob'])
    ref_audio = str(output / 'ref.wav')
    audio, sr = sf.read(reference['audio'])
    sf.write(ref_audio, audio, sr)
    (output / 'ref.txt').write_text(reference['text'], encoding='utf-8')
    for name, rows in [('train', train), ('validation', validation)]:
        for row in rows:
            row['ref_audio'] = ref_audio
        (output / f'{name}.jsonl').write_text('\n'.join(json.dumps(r, ensure_ascii=False) for r in rows)+'\n', encoding='utf-8')
    manifest = {'asr_model': model_id, 'asr_revision': revision, 'accepted': len(accepted),
                'train': len(train), 'validation': len(validation), 'rejected': rejected,
                'reference_source': reference['source'], 'human_reviewed': False,
                'warning': 'Automatic Japanese labels; experimental pilot only. Chinese pronunciation must be evaluated separately.'}
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'DATASET: {output}', flush=True)


if __name__ == '__main__':
    main()
