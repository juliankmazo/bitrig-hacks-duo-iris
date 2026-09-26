"""Mac webcam -> gaze feature vector -> WebSocket (ws://127.0.0.1:8777) for the IrisGaze simulator build.

Run from gaze/mac:  uv run --python 3.12 gaze_server.py [--show] [--camera 0] [--port 8777]

Message (one per camera frame, ~30 Hz):
  {"type":"gaze","f":[eye_x, eye_y, yaw, pitch, roll] | null, "fl":[x, y], "fr":[x, y], "x":f, "y":f,
   "face":b, "blink":b, "ear":f, "seq":n}
- eye_x: iris centre along the eye-corner axis, 0 = image-left corner, 1 = image-right corner (avg both eyes)
- eye_y: iris centre between the lids, 0 = upper lid, 1 = lower lid (avg both eyes)
- fl / fr: the same iris x/y for the subject's left / right eye separately
- yaw/pitch/roll: head rotation (rad) from the facial transformation matrix
- f2: {name: value} pose-invariant features (features.py F2_NAMES); "key": raw key landmarks (normalized
  x, y, z), head matrix "m", eye blendshapes "bs", frame size "wh" for offline recompute (replay.py --recompute)
- f is null while the face is lost or the eyes are closed (no stale points during blinks).
x/y are kept for older app builds (roughly -1..1). The app fits a regression at calibration.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import threading
import time
import urllib.request
from collections import deque
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
from websockets.asyncio.server import serve

from features import BLENDSHAPE_KEYS, F2_NAMES, KEY_LANDMARKS, extract_f2

HERE = Path(__file__).resolve().parent
MODEL = HERE / "face_landmarker.task"
MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/"
             "face_landmarker/float16/1/face_landmarker.task")

# MediaPipe face mesh indices (478 points incl. iris). Image-left eye = subject's right eye.
A_OUTER, A_INNER, A_UPPER, A_LOWER = 33, 133, 159, 145      # image-left eye
B_INNER, B_OUTER, B_UPPER, B_LOWER = 362, 263, 386, 374     # image-right eye
A_IRIS = (468, 469, 470, 471, 472)
B_IRIS = (473, 474, 475, 476, 477)

EAR_BLINK = 0.14          # eyelid gap / eye width below this = closed (checked in the startup stats)
MEDIAN_N = 5
FEATURE_NAMES = ("eye_x", "eye_y", "yaw", "pitch", "roll")


def _ratio(p: np.ndarray, a: np.ndarray, b: np.ndarray) -> float:
    """Position of p projected on a->b: 0 at a, 1 at b (robust to head roll)."""
    ab = b - a
    d = float(ab @ ab)
    return 0.5 if d < 1e-9 else float(((p - a) @ ab) / d)


def eye_features(pts: np.ndarray) -> tuple[float, float, float, tuple[float, float], tuple[float, float]]:
    """pts: (478, 2) in pixels. Returns eye_x, eye_y, ear (both eyes averaged), then per-eye (x, y) for the
    subject's left eye (image-right, B) and right eye (image-left, A)."""
    ia = pts[list(A_IRIS)].mean(axis=0)
    ib = pts[list(B_IRIS)].mean(axis=0)
    # Horizontal: both measured image-left -> image-right, so they move together.
    hx_a = _ratio(ia, pts[A_OUTER], pts[A_INNER])
    hx_b = _ratio(ib, pts[B_INNER], pts[B_OUTER])
    vy_a = _ratio(ia, pts[A_UPPER], pts[A_LOWER])
    vy_b = _ratio(ib, pts[B_UPPER], pts[B_LOWER])
    ear_a = np.linalg.norm(pts[A_UPPER] - pts[A_LOWER]) / (np.linalg.norm(pts[A_OUTER] - pts[A_INNER]) + 1e-6)
    ear_b = np.linalg.norm(pts[B_UPPER] - pts[B_LOWER]) / (np.linalg.norm(pts[B_OUTER] - pts[B_INNER]) + 1e-6)
    return ((hx_a + hx_b) / 2, (vy_a + vy_b) / 2, float(ear_a + ear_b) / 2,
            (hx_b, vy_b), (hx_a, vy_a))


def head_angles(matrix: np.ndarray) -> tuple[float, float, float]:
    R = matrix[:3, :3]
    sy = math.sqrt(R[0, 0] ** 2 + R[1, 0] ** 2)
    yaw = math.atan2(-R[2, 0], sy)
    pitch = math.atan2(R[2, 1], R[2, 2])
    roll = math.atan2(R[1, 0], R[0, 0])
    return yaw, pitch, roll


class Shared:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.seq = 0
        self.msg: dict = {"type": "gaze", "f": None, "x": 0.0, "y": 0.0, "face": False,
                          "blink": False, "ear": 0.0, "seq": 0}


def camera_loop(shared: Shared, args: argparse.Namespace, stop: threading.Event) -> None:
    if not MODEL.exists():
        print("downloading face_landmarker.task ...", flush=True)
        urllib.request.urlretrieve(MODEL_URL, MODEL)
    options = vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=str(MODEL)),
        running_mode=vision.RunningMode.VIDEO,
        num_faces=1,
        output_face_blendshapes=True,
        output_facial_transformation_matrixes=True,
    )
    landmarker = vision.FaceLandmarker.create_from_options(options)
    cap = cv2.VideoCapture(args.camera)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    cap.set(cv2.CAP_PROP_FPS, 30)
    if not cap.isOpened():
        print("ERROR: cannot open camera", args.camera, flush=True)
        stop.set()
        return

    hist: deque[np.ndarray] = deque(maxlen=MEDIAN_N)
    hist2: deque[np.ndarray] = deque(maxlen=MEDIAN_N)
    frames = faces = blinks = 0
    t_report = time.monotonic()
    t0 = time.monotonic()
    last_ts = -1
    stats: list[np.ndarray] = []
    ears: list[float] = []
    stats_done = False
    while not stop.is_set():
        ok, frame = cap.read()
        if not ok:
            time.sleep(0.005)
            continue
        h0, w0 = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)  # full res: iris landmarks need the pixels
        ts = max(int((time.monotonic() - t0) * 1000), last_ts + 1)
        last_ts = ts
        res = landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), ts)
        frames += 1

        face = bool(res.face_landmarks) and len(res.face_landmarks[0]) >= 478
        feat = None
        f2 = None
        raw_frame = None
        blink = False
        ear = 0.0
        pts = None
        if face:
            faces += 1
            norm = np.array([(lm.x, lm.y, lm.z) for lm in res.face_landmarks[0]], dtype=np.float64)
            P3 = norm * np.array([w0, h0, w0])
            pts = P3[:, :2]
            ex, ey, ear, (lx, ly), (rx, ry) = eye_features(pts)
            blend = {c.category_name: c.score for c in res.face_blendshapes[0]} if res.face_blendshapes else {}
            blink = ear < EAR_BLINK or (blend.get("eyeBlinkLeft", 0) > 0.5 and blend.get("eyeBlinkRight", 0) > 0.5)
            yaw = pitch = roll = 0.0
            matrix = None
            if res.facial_transformation_matrixes:
                matrix = np.array(res.facial_transformation_matrixes[0], dtype=np.float64)
                yaw, pitch, roll = head_angles(matrix)
            raw = np.array([ex, ey, yaw, pitch, roll, lx, ly, rx, ry])
            # f2: pose-invariant eye features + head pose/position (features.py, ported from PR #2)
            f2_vec = np.array([extract_f2(P3, blend, matrix, (w0, h0))[n] for n in F2_NAMES])
            raw_frame = {
                "key": [round(float(v), 6) for v in norm[list(KEY_LANDMARKS)].ravel()],
                "m": [round(float(v), 6) for v in matrix.ravel()] if matrix is not None else None,
                "bs": [round(float(blend.get(k, 0.0)), 5) for k in BLENDSHAPE_KEYS],
                "wh": [w0, h0],
            }
            if not stats_done:
                ears.append(ear)
            if blink:
                blinks += 1
            else:
                hist.append(raw)
                feat = np.median(np.array(hist), axis=0)  # 5-frame median: kills single-frame outliers
                hist2.append(f2_vec)
                f2 = np.median(np.array(hist2), axis=0)
                if not stats_done:
                    stats.append(raw)
        else:
            hist.clear()
            hist2.clear()

        with shared.lock:
            shared.seq += 1
            shared.msg = {
                "type": "gaze",
                "f": [round(float(v), 5) for v in feat[:5]] if feat is not None else None,
                "fl": [round(float(v), 5) for v in feat[5:7]] if feat is not None else None,
                "fr": [round(float(v), 5) for v in feat[7:9]] if feat is not None else None,
                # backward compat: roughly -1..1
                "x": round(float((feat[0] - 0.5) * 4 - feat[2] * 2) if feat is not None else 0.0, 4),
                "y": round(float((feat[1] - 0.5) * 4 - feat[3] * 3) if feat is not None else 0.0, 4),
                "f2": {n: round(float(v), 6) for n, v in zip(F2_NAMES, f2)} if f2 is not None else None,
                "key": raw_frame,
                "face": face, "blink": blink, "ear": round(ear, 4), "seq": shared.seq,
            }

        now = time.monotonic()
        if not stats_done and now - t0 >= 5.0:
            stats_done = True
            if stats:
                S = np.array(stats)
                print("feature ranges over first 5 s (n=%d):" % len(S), flush=True)
                for i, n in enumerate(FEATURE_NAMES):
                    print(f"  {n:6s} min {S[:, i].min():+.4f}  max {S[:, i].max():+.4f}  "
                          f"std {S[:, i].std():.4f}", flush=True)
            if ears:
                print(f"  ear    min {min(ears):.3f}  max {max(ears):.3f}  median {float(np.median(ears)):.3f}",
                      flush=True)
            if not stats:
                print("feature ranges: no face in the first 5 s", flush=True)
        if now - t_report >= 1.0:
            fs = " ".join(f"{v:+.3f}" for v in feat) if feat is not None else "-"
            print(f"fps {frames / (now - t_report):5.1f}  face {faces}/{frames}  blink {blinks}  "
                  f"ear {ear:.3f}  f [{fs}]", flush=True)
            frames = faces = blinks = 0
            t_report = now

        if args.show:
            vis = frame.copy()
            if pts is not None:
                for i in (A_OUTER, A_INNER, A_UPPER, A_LOWER, B_OUTER, B_INNER, B_UPPER, B_LOWER):
                    cv2.circle(vis, tuple(int(v) for v in pts[i]), 3, (0, 200, 0), -1)
                for iris in (A_IRIS, B_IRIS):
                    c = pts[list(iris)].mean(axis=0)
                    cv2.circle(vis, tuple(int(v) for v in c), 4, (0, 220, 255), -1)
                if feat is not None:
                    cv2.putText(vis, "ex %.3f ey %.3f yaw %+.2f pitch %+.2f" % tuple(feat[:4]), (30, 60),
                                cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 220, 255), 3)
            cv2.imshow("IrisGaze (q quits)", cv2.resize(vis, (960, 540)))
            if cv2.waitKey(1) & 0xFF == ord("q"):
                stop.set()
            if args.show_seconds and now - t0 > args.show_seconds:
                cv2.imwrite(str(HERE / "show_last.jpg"), vis)
                stop.set()
    cap.release()


async def serve_ws(shared: Shared, args: argparse.Namespace, stop: threading.Event) -> None:
    clients: set = set()

    async def handler(ws):
        clients.add(ws)
        print(f"client connected ({len(clients)})", flush=True)
        try:
            async for _ in ws:  # ignore incoming
                pass
        finally:
            clients.discard(ws)
            print(f"client left ({len(clients)})", flush=True)

    async with serve(handler, "127.0.0.1", args.port):
        print(f"serving ws://127.0.0.1:{args.port}", flush=True)
        last_seq = -1
        while not stop.is_set():
            with shared.lock:
                seq, payload = shared.seq, json.dumps(shared.msg)
            if seq != last_seq:  # only send new camera frames
                last_seq = seq
                for ws in list(clients):
                    try:
                        await ws.send(payload)
                    except Exception:
                        clients.discard(ws)
            await asyncio.sleep(0.005)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true", help="OpenCV debug window")
    ap.add_argument("--show-seconds", type=float, default=0, help="with --show: quit after N s, save show_last.jpg")
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--port", type=int, default=8777)
    args = ap.parse_args()

    shared, stop = Shared(), threading.Event()
    server = threading.Thread(target=lambda: asyncio.run(serve_ws(shared, args, stop)), daemon=True)
    server.start()
    try:
        camera_loop(shared, args, stop)  # main thread (OpenCV windows need it on macOS)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()


if __name__ == "__main__":
    main()
