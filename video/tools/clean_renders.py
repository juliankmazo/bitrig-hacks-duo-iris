# /// script
# dependencies = ["numpy", "opencv-python-headless"]
# ///
# Device Hub 3D renders -> black stage: levels the #191919 backdrop to black, hides the "iPhone" pill,
# and removes the mouse cursor (template match + inpaint, so it also disappears when it sits over the phone).
import subprocess, sys, numpy as np, cv2
SRC = "source/screenshots-and-videos-for-render/"
W, H = 1236, 1248
# name: (source, black out everything right of this x while the phone is narrower than the frame, times when it is not)
JOBS = {"opening": ("opening-screen-iris.mov", 1045, [(20.4, 28.4)]),
        "rotation": ("i-love-you-iphone-rotation-render.mov", 1032, [])}
ref = cv2.cvtColor(cv2.imread("assets/ref/cursor_frame.png"), cv2.COLOR_BGR2GRAY)
tpl = ref[710:731, 1025:1040]                       # macOS arrow cursor (black body, light outline)
body = (tpl < 5).astype(np.float32)     # solid black core
ring = (tpl > 45).astype(np.float32)    # light outline (backdrop is 25, so it is excluded)
lut = np.clip((np.arange(256) - 25) * 255 / 230, 0, 255).astype(np.uint8)
name = sys.argv[1]; src, xmask, keep = JOBS[name]
dec = subprocess.Popen(["ffmpeg", "-v", "error", "-i", SRC + src, "-vf", "fps=30", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", "30", "-i", "-",
                        "-vf", "format=yuv420p", "-c:v", "libx264", "-crf", "14", "-preset", "slow", "-g", "30", f"assets/clips/{name}.mp4"], stdin=subprocess.PIPE)
n = hits = 0
while True:
    b = dec.stdout.read(W * H * 3)
    if len(b) < W * H * 3: break
    f = np.frombuffer(b, np.uint8).reshape(H, W, 3).copy()
    g = cv2.cvtColor(f, cv2.COLOR_RGB2GRAY)
    # the arrow's shape: every body pixel near-black and (almost) every ring pixel light, on any background
    sb = cv2.matchTemplate((g < 40).astype(np.float32), body, cv2.TM_CCORR)
    so = cv2.matchTemplate((g > 70).astype(np.float32), ring, cv2.TM_CCORR)
    hit = (sb >= body.sum() * 0.85) & (so >= ring.sum() * 0.8)
    if hit.any():
        y, x = np.unravel_index(np.argmax(np.where(hit, so, -1)), hit.shape)
        th, tw = tpl.shape
        box = g[max(y - 5, 0):y + th + 5, max(x - 5, 0):x + tw + 5].astype(float)
        edge = np.concatenate([box[:3].ravel(), box[-3:].ravel(), box[:, :3].ravel(), box[:, -3:].ravel()])
        # the cursor sits on the #191919 backdrop or on the phone body; a pure-black surround means display text, not the cursor
        if (edge < 12).mean() > 0.3: hit[:] = False
    if hit.any():
        m = np.zeros((H, W), np.uint8); m[y - 3:y + tpl.shape[0] + 3, x - 3:x + tpl.shape[1] + 3] = 255
        f = cv2.inpaint(f, m, 5, cv2.INPAINT_TELEA); hits += 1
    f = lut[f]
    f[:80, 520:720] = 0
    if not any(a <= n / 30 <= z for a, z in keep):
        f[:, xmask:] = 0
    enc.stdin.write(f.tobytes()); n += 1
enc.stdin.close(); enc.wait(); print(name, n, "frames, cursor removed in", hits)
