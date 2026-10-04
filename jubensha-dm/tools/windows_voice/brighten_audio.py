"""Create a subtle brightness audition with a +2 dB high shelf, no pitch shift."""
import argparse
from pathlib import Path
import json


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    import numpy as np
    import soundfile as sf
    from scipy.signal import lfilter
    if args.output.exists() or args.source.resolve() == args.output.resolve():
        raise ValueError('Choose a new output path; originals are preserved')
    x, sr = sf.read(args.source, dtype='float64')
    gain_db, frequency = 2.0, 3000.0
    # RBJ high-shelf, slope S=1.
    a = 10**(gain_db/40)
    w = 2*np.pi*frequency/sr
    c = np.cos(w)
    alpha = np.sin(w)/2*np.sqrt(2)
    term = 2*np.sqrt(a)*alpha
    b = a*np.array([(a+1)+(a-1)*c+term, -2*((a-1)+(a+1)*c), (a+1)+(a-1)*c-term])
    den = np.array([(a+1)-(a-1)*c+term, 2*((a-1)-(a+1)*c), (a+1)-(a-1)*c-term])
    y = lfilter(b/den[0], den/den[0], x, axis=0)
    rms_x, rms_y = np.sqrt(np.mean(x*x)), np.sqrt(np.mean(y*y))
    if rms_y == 0 or not np.isfinite(y).all():
        raise ValueError('Invalid audio')
    y *= rms_x/rms_y
    peak = float(np.max(np.abs(y)))
    if peak > 0.98:
        y *= 0.98/peak
    sf.write(args.output, y, sr, subtype='PCM_16')
    print(json.dumps({'output':str(args.output),'sample_rate':sr,'seconds':len(y)/sr,
        'high_shelf_db':gain_db,'frequency_hz':frequency,'pitch_shift':False,
        'peak':float(np.max(np.abs(y)))},ensure_ascii=False))


if __name__ == '__main__':
    main()
