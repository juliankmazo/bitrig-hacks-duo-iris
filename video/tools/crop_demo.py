# /// script
# dependencies = ["numpy", "pillow"]
# ///
# Crops the demo screen recording (source/demo.mov: Device Hub + webcam, 3586x2316) into the two clips the films use:
#   assets/clips/screen.mp4  the simulator's inner display, with the webcam window (and its drop shadow) that
#                            overlapped its right edge removed
#   assets/clips/face.mp4    the webcam picture-in-picture
# Run from video/: uv run tools/crop_demo.py
import io, subprocess, numpy as np
from PIL import Image
SRC = "source/demo.mov"
W, H = 1322, 1882
X0, X1, YMAX, KEY_Y = 1232, 1277, 772, 612
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", SRC, "-vf", "crop=596:334:2414:177,fps=30,scale=1192:668:flags=lanczos,format=yuv420p",
                "-c:v", "libx264", "-crf", "19", "-g", "30", "-an", "assets/clips/face.mp4"], check=True)
# reference frame during calibration: the strip under the webcam window is plain white there
png = subprocess.run(["ffmpeg", "-v", "error", "-ss", "40", "-i", SRC, "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "-"], capture_output=True, check=True).stdout
ref = np.asarray(Image.open(io.BytesIO(png)).convert("RGB")).astype(np.float32)[251:251 + H, 1134:1134 + W]
# per-column darkening from a white row (y=400 in crop), relative to the white level left of the shadow
white = ref[400, 1200:1230].mean()
gain = np.clip(white / np.maximum(ref[400, X0:X1].mean(1), 1), 1, 6)[None, :, None]
dec = subprocess.Popen(["ffmpeg", "-v", "error", "-i", SRC, "-vf", f"crop={W}:{H}:1134:251,fps=30", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", "30", "-i", "-",
                        "-vf", "scale=1320:1880:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-crf", "14", "-preset", "slow", "-g", "30", "assets/clips/screen.mp4"], stdin=subprocess.PIPE)
n = 0
while True:
    buf = dec.stdout.read(W * H * 3)
    if len(buf) < W * H * 3: break
    f = np.frombuffer(buf, np.uint8).reshape(H, W, 3).astype(np.float32)
    t = n / 30
    f[:YMAX, X0:X1] = np.minimum(f[:YMAX, X0:X1] * gain, 255)
    f[:KEY_Y, X1:] = white
    key = (197, 217, 245) if t < 83 else (153, 194, 238)
    f[KEY_Y:YMAX, X1:1289] = key
    f[KEY_Y:YMAX, 1289:] = white
    enc.stdin.write(f.astype(np.uint8).tobytes()); n += 1
enc.stdin.close(); enc.wait(); print("frames", n)
