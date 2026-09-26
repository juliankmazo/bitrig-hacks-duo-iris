"""Mac webcam -> raw gaze feature -> WebSocket (ws://127.0.0.1:8777) for the IrisGaze simulator build.

Run from gaze/mac:  uv run --python 3.12 gaze_server.py [--show] [--camera 0] [--port 8777]

Message (~30 Hz):  {"type":"gaze","x":f,"y":f,"blink":b,"face":b}
x, y are a raw feature in roughly -1..1 (not screen aligned); the app calibrates 12 centroids.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import threading
import time
import urllib.request
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision
from websockets.asyncio.server import serve

HERE = Path(__file__).resolve().parent
MODEL = HERE / "face_landmarker.task"
MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/"
             "face_landmarker/float16/1/face_landmarker.task")

EMA = 0.5
EYE_W_X, EYE_W_Y = 0.6, 0.3          # webcam vertical eye signal is weak -> lean on head pitch for y
YAW_RANGE, PITCH_RANGE = 0.35, 0.25  # rad mapped to +-1
EYE_GAIN = 1.6
NOSE_TIP, L_OUTER, R_OUTER = 1, 33, 263


class Shared:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.msg = {"type": "gaze", "x": 0.0, "y": 0.0, "blink": False, "face": False}


def head_angles(matrix: np.ndarray) -> tuple[float, float]:
    R = matrix[:3, :3]
    sy = math.sqrt(R[0, 0] ** 2 + R[1, 0] ** 2)
    yaw = math.atan2(-R[2, 0], sy)
    pitch = math.atan2(R[2, 1], R[2, 2])
    return yaw, pitch


def feature(blend: dict[str, float], matrix: np.ndarray | None) -> tuple[float, float]:
    # Signed eye direction, + = toward the subject's right / down (screen right / down when facing it).
    eye_x = ((blend.get("eyeLookInLeft", 0) - blend.get("eyeLookOutLeft", 0))
             + (blend.get("eyeLookOutRight", 0) - blend.get("eyeLookInRight", 0))) / 2
    eye_y = ((blend.get("eyeLookDownLeft", 0) - blend.get("eyeLookUpLeft", 0))
             + (blend.get("eyeLookDownRight", 0) - blend.get("eyeLookUpRight", 0))) / 2
    yaw = pitch = 0.0
    if matrix is not None:
        yaw, pitch = head_angles(matrix)
    hx = -yaw / YAW_RANGE
    hy = -pitch / PITCH_RANGE
    x = EYE_W_X * eye_x * EYE_GAIN + (1 - EYE_W_X) * hx
    y = EYE_W_Y * eye_y * EYE_GAIN + (1 - EYE_W_Y) * hy
    return float(np.clip(x, -1.5, 1.5)), float(np.clip(y, -1.5, 1.5))


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

    sx = sy = None
    frames, faces, t_report = 0, 0, time.monotonic()
    t0 = time.monotonic()
    last_ts = -1
    while not stop.is_set():
        ok, frame = cap.read()
        if not ok:
            time.sleep(0.01)
            continue
        small = cv2.resize(frame, (960, 540))
        rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
        ts = int((time.monotonic() - t0) * 1000)
        if ts <= last_ts:
            ts = last_ts + 1
        last_ts = ts
        res = landmarker.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), ts)
        frames += 1

        face = bool(res.face_landmarks)
        blink = False
        if face:
            faces += 1
            blend = {c.category_name: c.score for c in res.face_blendshapes[0]} if res.face_blendshapes else {}
            matrix = (np.array(res.facial_transformation_matrixes[0])
                      if res.facial_transformation_matrixes else None)
            x, y = feature(blend, matrix)
            blink = blend.get("eyeBlinkLeft", 0) > 0.5 and blend.get("eyeBlinkRight", 0) > 0.5
            if not blink:  # closed-eye frames are garbage: hold the point
                sx = x if sx is None else EMA * x + (1 - EMA) * sx
                sy = y if sy is None else EMA * y + (1 - EMA) * sy
        else:
            sx = sy = None

        with shared.lock:
            shared.msg = {"type": "gaze", "x": round(sx or 0.0, 4), "y": round(sy or 0.0, 4),
                          "blink": blink, "face": face and sx is not None}

        now = time.monotonic()
        if now - t_report >= 1.0:
            print(f"fps {frames / (now - t_report):5.1f}  face {faces}/{frames}  "
                  f"x {sx if sx is not None else float('nan'):+.3f}  "
                  f"y {sy if sy is not None else float('nan'):+.3f}  blink {blink}", flush=True)
            frames, faces, t_report = 0, 0, now

        if args.show:
            vis = small.copy()
            if face:
                h, w = vis.shape[:2]
                for lm in res.face_landmarks[0][::4]:
                    cv2.circle(vis, (int(lm.x * w), int(lm.y * h)), 1, (0, 200, 0), -1)
                nose = res.face_landmarks[0][NOSE_TIP]
                c = (int(nose.x * w), int(nose.y * h))
                if sx is not None:
                    # mirror x so the arrow matches what you see
                    cv2.arrowedLine(vis, c, (int(c[0] - sx * 150), int(c[1] + sy * 150)), (0, 220, 255), 3)
            cv2.imshow("IrisGaze (q quits)", cv2.flip(vis, 1))
            if cv2.waitKey(1) & 0xFF == ord("q"):
                stop.set()
    cap.release()


async def serve_ws(shared: Shared, args: argparse.Namespace, stop: threading.Event) -> None:
    clients = set()

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
        while not stop.is_set():
            with shared.lock:
                payload = json.dumps(shared.msg)
            for ws in list(clients):
                try:
                    await ws.send(payload)
                except Exception:
                    clients.discard(ws)
            await asyncio.sleep(1 / 30)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true", help="OpenCV debug window")
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
