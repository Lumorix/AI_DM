"""Local-only Windows voice audition and warm inference benchmark (no training)."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import threading
import time

PAGE = '''<!doctype html><meta charset="utf-8"><title>八千代本机语音</title>
<style>body{max-width:760px;margin:50px auto;font:18px/1.7 system-ui;background:#171923;color:#eee}textarea{width:100%;height:130px;font:inherit}button{padding:12px;margin:12px 0}audio{width:100%}</style>
<h1>八千代 · Windows 本机语音</h1><p>当前为 A 基础音色。输入短句，生成后播放。首次运行会慢一些，相同台词再次播放使用缓存。</p>
<textarea id="text" maxlength="120">各位玩家，欢迎来到听涛居。请仔细观察线索，找出隐藏的真相。</textarea>
<button id="go">生成并试听</button><p id="status">模型已加载，可以开始。</p><audio id="audio" controls></audio>
<p>此页用于测量整句生成延迟，尚不是真正逐帧流式语音。</p>
<script>
let url; const go=document.getElementById('go'), status=document.getElementById('status'), audio=document.getElementById('audio');
go.onclick=async()=>{go.disabled=true;status.textContent='正在生成…';audio.pause();const start=performance.now();
try {const r=await fetch('/synthesize',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text:document.getElementById('text').value})});
if(!r.ok)throw Error(await r.text());const blob=await r.blob();if(url)URL.revokeObjectURL(url);url=URL.createObjectURL(blob);audio.src=url;
status.textContent=`音频就绪：${((performance.now()-start)/1000).toFixed(2)} 秒；音频时长 ${r.headers.get('X-Audio-Seconds')} 秒；${r.headers.get('X-Cache')==='hit'?'命中缓存':'新生成'}`;
try{await audio.play()}catch(e){status.textContent+='。请点击播放器播放。'}
}catch(e){status.textContent='失败：'+e.message}finally{go.disabled=false}};
</script>'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--benchmark', action='store_true')
    ap.add_argument('--serve', action='store_true')
    ap.add_argument('--port', type=int, default=8773)
    ap.add_argument('--threads', type=int, default=4)
    args = ap.parse_args()
    if not (args.benchmark or args.serve):
        ap.error('Select --benchmark and/or --serve')
    root = Path(__file__).resolve().parents[2]
    tts = root/'data/LocalTTS'
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ.setdefault('HF_HOME', str(tts/'hf-cache/windows'))
    import numpy as np
    import soundfile as sf
    import torch
    from qwen_tts import Qwen3TTSModel
    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    if not torch.cuda.is_available():
        raise RuntimeError('CUDA is required for this benchmark')
    base = tts/'models/Qwen3-TTS-12Hz-0.6B-Base-pytorch'
    reference = tts/'windows/outputs/yachiyo-data-20261003-094046/ref.wav'
    output = tts/'windows/outputs'/('realtime-'+time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True, exist_ok=False)
    print('OUTPUT: '+str(output), flush=True)
    start = time.perf_counter()
    model = Qwen3TTSModel.from_pretrained(str(base), device_map='cuda:0', dtype=torch.bfloat16,
                                        attn_implementation='sdpa', local_files_only=True)
    model.model.eval()
    with torch.inference_mode():
        prompt = model.create_voice_clone_prompt(ref_audio=str(reference), x_vector_only_mode=True)
    torch.cuda.synchronize()
    load_seconds = time.perf_counter()-start
    print(f'Model and reference ready: {load_seconds:.2f}s', flush=True)
    lock = threading.Lock()
    cache = {}

    def synthesize(text, cached=True):
        key = hashlib.sha256(text.encode()).hexdigest()
        if cached and key in cache:
            data, metrics = cache[key]
            return data, dict(metrics, cache='hit')
        torch.manual_seed(42)
        torch.cuda.reset_peak_memory_stats()
        torch.cuda.synchronize()
        start = time.perf_counter()
        with torch.inference_mode():
            wavs, sr = model.generate_voice_clone(text=text, language='Chinese', voice_clone_prompt=prompt,
                max_new_tokens=512, do_sample=True, temperature=0.9,
                subtalker_dosample=True, subtalker_temperature=0.9)
        torch.cuda.synchronize()
        elapsed = time.perf_counter()-start
        wav = np.asarray(wavs[0])
        if not wav.size or not np.isfinite(wav).all() or np.max(np.abs(wav)) < 1e-6:
            raise RuntimeError('Invalid or silent generated audio')
        buf = io.BytesIO()
        sf.write(buf, wav, sr, format='WAV', subtype='PCM_16')
        data = buf.getvalue()
        metrics = dict(text=text, generation_seconds=elapsed, audio_seconds=len(wav)/sr,
                       rtf=elapsed/(len(wav)/sr), peak_allocated_mib=torch.cuda.max_memory_allocated()/1024**2,
                       peak_reserved_mib=torch.cuda.max_memory_reserved()/1024**2, cache='miss')
        if len(cache) >= 32:
            cache.pop(next(iter(cache)))
        cache[key] = (data, metrics)
        return data, metrics

    if args.benchmark:
        rows = []
        texts = ['各位玩家，欢迎来到听涛居。请仔细观察线索，找出隐藏的真相。',
                 '各位玩家，欢迎来到听涛居。',
                 '请仔细观察线索，找出隐藏的真相。',
                 '各位玩家，欢迎来到听涛居。请仔细观察线索，找出隐藏的真相。']
        for i, text in enumerate(texts):
            data, result = synthesize(text, cached=False)
            (output/f'trial-{i+1}.wav').write_bytes(data)
            rows.append(dict(result, trial=i+1, cold_generation=i == 0))
            print(json.dumps(rows[-1], ensure_ascii=False), flush=True)
            (output/'metrics.json').write_text(json.dumps(dict(model=str(base), reference=str(reference),
                torch=torch.__version__, threads=args.threads, device=torch.cuda.get_device_name(),
                model_load_seconds=load_seconds, training=False, streaming_audio=False, trials=rows),
                ensure_ascii=False, indent=2), encoding='utf-8')

    if args.serve:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path != '/':
                    self.send_error(404)
                    return
                data = PAGE.encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if self.path != '/synthesize':
                    self.send_error(404)
                    return
                if self.headers.get('Origin') not in (None, f'http://127.0.0.1:{args.port}', f'http://localhost:{args.port}'):
                    self.send_error(403)
                    return
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= 4096:
                        raise ValueError()
                    payload = json.loads(self.rfile.read(size))
                    text = payload.get('text') if isinstance(payload, dict) else None
                    if not isinstance(text, str) or not 1 <= len(text.strip()) <= 120:
                        raise ValueError()
                    text = text.strip()
                except (ValueError, TypeError):
                    self.send_error(400, 'Use 1 to 120 characters')
                    return
                if not lock.acquire(blocking=False):
                    self.send_error(429, 'Voice model is busy')
                    return
                try:
                    data, metrics = synthesize(text)
                except Exception as exc:
                    print(f'Synthesis failed: {exc}', flush=True)
                    self.send_error(500, 'Synthesis failed; see server log')
                    return
                finally:
                    lock.release()
                self.send_response(200)
                self.send_header('Content-Type', 'audio/wav')
                self.send_header('Content-Length', str(len(data)))
                self.send_header('X-Audio-Seconds', f"{metrics['audio_seconds']:.2f}")
                self.send_header('X-Generation-Seconds', f"{metrics['generation_seconds']:.3f}")
                self.send_header('X-Cache', metrics['cache'])
                self.end_headers()
                self.wfile.write(data)

        print(f'READY http://127.0.0.1:{args.port}/', flush=True)
        ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
