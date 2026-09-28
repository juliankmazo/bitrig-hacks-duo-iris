# /// script
# dependencies = ["numpy", "scipy", "soundfile"]
# ///
import numpy as np, soundfile as sf, sys
from scipy.signal import fftconvolve, butter, sosfilt
SR = 44100
rng = np.random.default_rng(7)
def midi(n): return 440 * 2 ** ((n - 69) / 12)
def piano(f, dur, vel=0.5):
    t = np.arange(int(SR * dur)) / SR
    out = np.zeros_like(t)
    for h, a in enumerate([1, .45, .22, .12, .06, .03], 1):
        fh = f * h * np.sqrt(1 + 0.0004 * h * h)
        out += a * np.sin(2 * np.pi * fh * t) * np.exp(-t * (0.9 + 0.8 * h))
    att = np.minimum(1, t / 0.006)
    return vel * out * att
def pad(freqs, dur, amp=0.08):
    t = np.arange(int(SR * dur)) / SR
    out = np.zeros_like(t)
    for f in freqs:
        for det in (-0.07, 0, 0.07):
            ff = f * 2 ** (det / 12)
            for h, a in enumerate([1, .3, .12], 1):
                out += a * np.sin(2 * np.pi * ff * h * t + rng.uniform(0, 6.28))
    env = np.minimum(1, t / 1.6) * np.minimum(1, (dur - t) / 1.6)
    return amp * out * env / len(freqs)
def reverb(x, sec=2.8, mix=0.45):
    n = int(SR * sec); t = np.arange(n) / SR
    outs = []
    for ch in range(2):
        ir = rng.standard_normal(n) * np.exp(-t / (sec / 5))
        ir = sosfilt(butter(2, 5000, 'low', fs=SR, output='sos'), ir); ir /= np.abs(ir).sum() ** 0.5 * 12
        outs.append((1 - mix) * x + mix * fftconvolve(x, ir)[:len(x)])
    return np.stack(outs, 1)
def render(total, bar=4.0, pulse=False):
    N = int(SR * total); mono = np.zeros(N + SR * 6)
    # D major, gentle: Dmaj9  Bm7  Gmaj7  Asus
    prog = [[50, 57, 62, 64, 66, 69], [47, 54, 57, 62, 66], [43, 50, 55, 59, 62, 66], [45, 52, 57, 62, 64]]
    mel = [[74, 76, 78, 81], [74, 78, 81, 83], [74, 79, 81, 83], [76, 79, 81, 76]]
    b = 0; t0 = 0.0
    while t0 < total:
        ch = prog[b % 4]; i = int(t0 * SR)
        p = pad([midi(n) for n in ch], bar + 1.6); mono[i:i + len(p)] += p
        lo = piano(midi(ch[0] - 12), 4.0, 0.22); mono[i:i + len(lo)] += lo
        if t0 >= bar * 2:   # piano enters after two bars
            steps = 8 if pulse else 4
            for k in range(steps):
                if not pulse and k % 2 == 1 and rng.random() < 0.5: continue
                n = mel[b % 4][k % 4] if not pulse else ch[1 + k % (len(ch) - 1)] + 12
                j = i + int(k * bar / steps * SR)
                nt = piano(midi(n), 3.0, 0.16 if pulse else 0.2); mono[j:j + len(nt)] += nt
        if pulse:
            for k in range(4):   # soft heartbeat kick
                j = i + int(k * bar / 4 * SR); tt = np.arange(int(0.35 * SR)) / SR
                kick = 0.5 * np.sin(2 * np.pi * (48 + 60 * np.exp(-tt * 30)) * tt) * np.exp(-tt * 9)
                mono[j:j + len(kick)] += kick
        t0 += bar; b += 1
    st = reverb(mono[:N + SR * 3])[:N]
    fade = np.ones(N); fl = int(SR * 3); fade[-fl:] = np.linspace(1, 0, fl); fade[:int(SR * 1.5)] = np.linspace(0, 1, int(SR * 1.5))
    st *= fade[:, None]; st /= np.abs(st).max() / 0.8
    return st
name, total, pulse = sys.argv[1], float(sys.argv[2]), sys.argv[3] == "1"
sf.write(f"assets/music/{name}.wav", render(total, 4.0 if not pulse else 2.4, pulse), SR)
print(name, "ok")
