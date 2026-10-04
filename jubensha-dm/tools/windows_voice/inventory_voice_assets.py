"""Inventory tracked voice assets without changing any input file or Git index."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--project',type=Path,required=True,help='jubensha-dm directory')
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args()
    root=args.project.resolve()
    raw=subprocess.check_output(['git','ls-files','-z','--','data/LocalTTS'],cwd=root)
    rows=[]
    groups=defaultdict(list)
    for name in raw.decode('utf-8').split('\0'):
        if not name:
            continue
        file=root/name
        if file.suffix.lower() not in ('.wav','.mp3','.flac','.bin','.onnx','.pt','.pth','.safetensors','.ckpt'):
            continue
        if not file.is_file():
            rows.append({'path':name,'missing':True})
            continue
        digest=hashlib.sha256()
        with file.open('rb') as reader:
            for chunk in iter(lambda:reader.read(1024*1024),b''):
                digest.update(chunk)
        category=('model' if file.suffix.lower() not in ('.wav','.mp3','.flac') else
                  'evaluation_audio' if '/eval/' in name else
                  'training_clip' if '/dataset/' in name else
                  'vendor_example' if '/seed-vc/examples/' in name else 'source_or_reference_audio')
        row={'path':name,'bytes':file.stat().st_size,'sha256':digest.hexdigest(),'category':category}
        rows.append(row)
        groups[(row['bytes'],row['sha256'])].append(name)
    manifest={'git_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
              'scope':'Currently tracked data/LocalTTS audio/model files, current working-tree bytes; no Git history or ignored outputs.',
              'file_count':len(rows),'total_bytes':sum(r.get('bytes',0) for r in rows),
              'exact_duplicates':[{'bytes_each':size,'sha256':sha,'paths':paths}
                                   for (size,sha),paths in groups.items() if len(paths)>1],
              'files':rows}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in manifest.items() if k!='files'},ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
