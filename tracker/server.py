#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["mediapipe==0.10.21", "opencv-python>=4.9", "numpy>=1.26,<2", "websockets>=12"]
# ///
"""Iris eye tracker: webcam -> MediaPipe FaceLandmarker -> gaze point/zone -> WebSocket.

    uv run --python 3.12 tracker/server.py                 # camera + tracking
    uv run --python 3.12 tracker/server.py --debug         # + OpenCV window with landmarks
    uv run --python 3.12 tracker/server.py --no-camera     # synthetic gaze, relay only
    uv run --python 3.12 tracker/server.py --mode head     # nose-pointer fallback

WebSocket ws://127.0.0.1:8765  (see README "Shared contract"; gaze messages add x, y, conf)
HTTP      http://127.0.0.1:8766/  demo UI, /outer.html simulated outer display
"""

from __future__ import annotations

import argparse
import asyncio
import functools
import http.server
import json
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO))

from gaze import (  # noqa: E402
    CalibrationModel, GazeEstimator, GazeState, SyntheticGaze, extract_features, zone_target, raw_zone,
    L_IRIS, R_IRIS, L_OUTER, L_INNER, L_UPPER, L_LOWER, R_OUTER, R_INNER, R_UPPER, R_LOWER, NOSE_TIP,
)

MODEL_PATH = HERE / "face_landmarker.task"
CAL_PATH = HERE / "calibration.json"
TEST_LOG = HERE / "test_results.jsonl"
STATIC_DIR = HERE / "static"
WS_HOST, WS_PORT, HTTP_PORT = "127.0.0.1", 8765, 8766


# ---------------------------------------------------------------------------
# Shared state between the camera thread and asyncio
# ---------------------------------------------------------------------------
@dataclass
class CalRequest:
    x: float
    y: float
    zone: int
    n: int = 24
    settle: float = 0.35
    timeout: float = 3.0
    started: float = 0.0
    count: int = 0
    future: asyncio.Future | None = None
    loop: asyncio.AbstractEventLoop | None = None


class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.state = GazeState()
        self.seq = 0
        self.fps = 0.0
        self.infer_ms = 0.0
        self.e2e_ms = 0.0
        self.cal_points = 0
        self.cal_request: CalRequest | None = None
        self.cal_reset = False
        self.stop = threading.Event()
        self.mode = "hybrid"
        self.camera = "none"
        self.cols, self.rows = 4, 3

    def publish(self, s: GazeState, infer_ms: float, e2e_ms: float, fps: float) -> None:
        with self.lock:
            self.state = GazeState(**vars(s))
            self.seq += 1
            self.infer_ms, self.e2e_ms, self.fps = infer_ms, e2e_ms, fps

    def snapshot(self) -> tuple[GazeState, int]:
        with self.lock:
            return self.state, self.seq

    def status(self) -> dict:
        with self.lock:
            return {"type": "status", "fps": round(self.fps, 1), "infer_ms": round(self.infer_ms, 1),
                    "latency_ms": round(self.e2e_ms, 1), "cal_points": self.cal_points,
                    "mode": self.mode, "camera": self.camera}

    def config(self) -> dict:
        return {"type": "config", "cols": self.cols, "rows": self.rows, "mode": self.mode,
                "camera": self.camera, "cal_points": self.cal_points}


# ---------------------------------------------------------------------------
# Camera + landmarker loop (runs on the main thread)
# ---------------------------------------------------------------------------
def open_camera(index: int, width: int, height: int):
    import cv2
    for attempt in range(6):
        cap = cv2.VideoCapture(index, cv2.CAP_AVFOUNDATION)
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        cap.set(cv2.CAP_PROP_FPS, 30)
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        ok, frame = cap.read() if cap.isOpened() else (False, None)
        if ok and frame is not None:
            print(f"[camera] opened index {index} at {frame.shape[1]}x{frame.shape[0]}", flush=True)
            return cap
        cap.release()
        print(f"[camera] open failed (attempt {attempt + 1}/6), retrying...", flush=True)
        time.sleep(1.0)
    return None


def make_landmarker():
    import mediapipe as mp
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision
    if not MODEL_PATH.exists():
        sys.exit(f"missing {MODEL_PATH}: download it from "
                 "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task")
    opts = vision.FaceLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=str(MODEL_PATH)),
        running_mode=vision.RunningMode.VIDEO,
        num_faces=1,
        output_face_blendshapes=True,
        output_facial_transformation_matrixes=True,
        min_face_detection_confidence=0.5,
        min_face_presence_confidence=0.5,
        min_tracking_confidence=0.5,
    )
    return vision.FaceLandmarker.create_from_options(opts), mp


def draw_debug(frame, pts, matrix, state: GazeState, hub: Hub):
    import cv2
    h, w = frame.shape[:2]
    if pts is not None:
        for (x, y) in pts.astype(int):
            cv2.circle(frame, (int(x), int(y)), 1, (90, 90, 90), -1)
        for idx in (L_OUTER, L_INNER, L_UPPER, L_LOWER, R_OUTER, R_INNER, R_UPPER, R_LOWER):
            cv2.circle(frame, tuple(pts[idx].astype(int)), 3, (0, 200, 255), -1)
        for iris in (L_IRIS, R_IRIS):
            c = pts[list(iris)].mean(axis=0)
            r = max(2.0, float(np.linalg.norm(pts[iris[1]] - pts[iris[3]]) / 2))
            cv2.circle(frame, tuple(c.astype(int)), int(r), (80, 255, 80), 2)
            cv2.circle(frame, tuple(c.astype(int)), 2, (80, 255, 80), -1)
        if matrix is not None:
            R = matrix[:3, :3]
            o = pts[NOSE_TIP]
            for i, col in enumerate(((0, 0, 255), (0, 255, 0), (255, 0, 0))):
                d = np.array([R[0, i], -R[1, i]]) * 70
                cv2.arrowedLine(frame, tuple(o.astype(int)), tuple((o + d).astype(int)), col, 2, tipLength=0.2)
    frame = cv2.flip(frame, 1)
    lines = [
        f"fps {hub.fps:4.1f}  infer {hub.infer_ms:4.1f} ms  e2e {hub.e2e_ms:4.1f} ms",
        f"face {state.face}  zone {state.zone}  conf {state.conf:.2f}  cal {hub.cal_points} pts",
        f"x {state.x:.2f} y {state.y:.2f}  closed {state.eyes_closed}  blink {state.blink}",
    ]
    for i, txt in enumerate(lines):
        cv2.putText(frame, txt, (12, 28 + 26 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (0, 0, 0), 4)
        cv2.putText(frame, txt, (12, 28 + 26 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 1)
    # mini grid with the active zone
    cols, rows, gs = hub.cols, hub.rows, 32
    gx, gy = w - cols * gs - 20, 20
    for z in range(cols * rows):
        c, r = z % cols, z // cols
        p1 = (gx + c * gs, gy + r * gs)
        p2 = (gx + (c + 1) * gs - 2, gy + (r + 1) * gs - 2)
        cv2.rectangle(frame, p1, p2, (255, 180, 60) if z == state.zone else (120, 120, 120),
                      -1 if z == state.zone else 1)
    if state.face and state.calibrated:
        cv2.circle(frame, (int(gx + state.x * gs * cols), int(gy + state.y * gs * rows)), 4, (255, 255, 255), -1)
    return frame


def camera_loop(args, hub: Hub, model: CalibrationModel, est: GazeEstimator) -> None:
    import cv2
    cap = open_camera(args.camera, args.width, args.height)
    if cap is None:
        print("[camera] giving up; run with --no-camera to test the UI", flush=True)
        hub.stop.set()
        return
    hub.camera = f"{int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))}x{int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))}"
    landmarker, mp = make_landmarker()
    print("[landmarker] ready (VIDEO mode, blendshapes + transform matrix)", flush=True)

    frame_times: deque[float] = deque(maxlen=60)
    infer_hist: deque[float] = deque(maxlen=60)
    e2e_hist: deque[float] = deque(maxlen=60)
    last_print = time.monotonic()
    last_ts_ms = 0

    while not hub.stop.is_set():
        ok, frame = cap.read()
        t0 = time.monotonic()
        if not ok or frame is None:
            time.sleep(0.01)
            continue
        h, w = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        ts_ms = max(int(t0 * 1000), last_ts_ms + 1)
        last_ts_ms = ts_ms
        res = landmarker.detect_for_video(mp_img, ts_ms)
        t1 = time.monotonic()

        pts = matrix = None
        feats = None
        blink_l = blink_r = 0.0
        if res.face_landmarks:
            lm = res.face_landmarks[0]
            pts = np.array([[p.x * w, p.y * h] for p in lm], dtype=np.float64)
            blend = {c.category_name: c.score for c in res.face_blendshapes[0]} if res.face_blendshapes else {}
            blink_l, blink_r = blend.get("eyeBlinkLeft", 0.0), blend.get("eyeBlinkRight", 0.0)
            if res.facial_transformation_matrixes:
                matrix = np.array(res.facial_transformation_matrixes[0], dtype=np.float64)
            feats = extract_features(pts, blend, matrix, (w, h))

        # calibration capture / reset requests from the websocket side
        if hub.cal_reset:
            hub.cal_reset = False
            model.clear()
            est.reset_filters()
            hub.cal_points = 0
            try:
                CAL_PATH.unlink()
            except OSError:
                pass
        req = hub.cal_request
        if req is not None:
            if req.started == 0.0:
                req.started = t0
            elapsed = t0 - req.started
            eyes_open = not (blink_l > 0.5 and blink_r > 0.5)
            if feats is not None and eyes_open and elapsed >= req.settle:
                model.add(feats, req.x, req.y)
                req.count += 1
            if req.count >= req.n or elapsed >= req.timeout:
                hub.cal_request = None
                fitted = model.fit()
                if fitted:
                    model.save(CAL_PATH)
                est.reset_filters()
                hub.cal_points = model.n_points
                if req.loop and req.future:
                    req.loop.call_soon_threadsafe(req.future.set_result,
                                                  {"count": req.count, "points": model.n_points, "fitted": fitted})

        state = est.update(feats, blink_l, blink_r, t0)
        t2 = time.monotonic()

        frame_times.append(t2)
        infer_hist.append((t1 - t0) * 1000)
        e2e_hist.append((t2 - t0) * 1000)
        fps = (len(frame_times) - 1) / (frame_times[-1] - frame_times[0]) if len(frame_times) > 1 else 0.0
        hub.publish(state, float(np.mean(infer_hist)), float(np.mean(e2e_hist)), fps)

        if t2 - last_print >= 2.0:
            last_print = t2
            print(f"[track] fps {fps:5.1f} | infer {np.mean(infer_hist):5.1f} ms | e2e {np.mean(e2e_hist):5.1f} ms"
                  f" | face {state.face!s:5} | zone {state.zone:2d} | conf {state.conf:.2f}"
                  f" | cal {model.n_points} pts", flush=True)

        if args.debug:
            cv2.imshow("iris tracker", draw_debug(frame, pts, matrix, state, hub))
            if cv2.waitKey(1) & 0xFF in (27, ord("q")):
                hub.stop.set()

    cap.release()
    landmarker.close()
    if args.debug:
        cv2.destroyAllWindows()


def synthetic_loop(hub: Hub) -> None:
    syn = SyntheticGaze(hub.cols, hub.rows)
    hub.camera = "synthetic"
    hub.cal_points = hub.cols * hub.rows
    last_print = time.monotonic()
    while not hub.stop.is_set():
        t0 = time.monotonic()
        if hub.cal_reset:
            hub.cal_reset = False
        req = hub.cal_request
        if req is not None:
            if req.started == 0.0:
                req.started = t0
            if t0 - req.started >= 0.8:
                hub.cal_request = None
                if req.loop and req.future:
                    req.loop.call_soon_threadsafe(req.future.set_result,
                                                  {"count": 24, "points": hub.cols * hub.rows, "fitted": True})
        hub.publish(syn.sample(), 0.0, 0.0, 30.0)
        if t0 - last_print >= 5.0:
            last_print = t0
            print("[track] synthetic gaze (no camera)", flush=True)
        time.sleep(max(0.0, 1 / 30 - (time.monotonic() - t0)))


# ---------------------------------------------------------------------------
# WebSocket + HTTP (asyncio, background thread)
# ---------------------------------------------------------------------------
class Server:
    def __init__(self, hub: Hub):
        self.hub = hub
        self.clients: set = set()
        self.loop: asyncio.AbstractEventLoop | None = None
        self.cal_lock = asyncio.Lock()
        self.predict = self._load_intent()

    @staticmethod
    def _load_intent():
        try:
            from intent.predict import predict  # type: ignore
            print("[intent] using intent/predict.py", flush=True)
            return predict
        except Exception as e:  # noqa: BLE001
            print(f"[intent] intent/predict.py unavailable ({e.__class__.__name__}); replying with empty words",
                  flush=True)
            return None

    async def broadcast(self, msg: dict) -> None:
        if not self.clients:
            return
        data = json.dumps(msg, separators=(",", ":"))
        await asyncio.gather(*(self._send(ws, data) for ws in list(self.clients)), return_exceptions=True)

    @staticmethod
    async def _send(ws, data: str) -> None:
        try:
            await ws.send(data)
        except Exception:  # noqa: BLE001
            pass

    async def gaze_pump(self) -> None:
        last_seq = -1
        last_sent = 0.0
        last_status = 0.0
        while not self.hub.stop.is_set():
            state, seq = self.hub.snapshot()
            now = time.monotonic()
            if seq != last_seq or now - last_sent > 0.2:
                last_seq, last_sent = seq, now
                calibrated_zone = state.zone if state.face and state.calibrated else -1
                await self.broadcast({
                    "type": "gaze", "zone": calibrated_zone,
                    "x": round(state.x, 4), "y": round(state.y, 4),
                    "blink": state.blink, "face": state.face, "conf": round(state.conf, 3),
                    "closed": state.eyes_closed,
                })
            if now - last_status >= 1.0:
                last_status = now
                await self.broadcast(self.hub.status())
            await asyncio.sleep(1 / 30)

    async def handle_cal(self, ws, msg: dict) -> None:
        cols, rows = self.hub.cols, self.hub.rows
        if "zone" in msg and ("x" not in msg or "y" not in msg):
            zone = int(msg["zone"])
            x, y = zone_target(zone, cols, rows)
        else:
            x, y = float(msg["x"]), float(msg["y"])
            zone = raw_zone(x, y, cols, rows)
        async with self.cal_lock:
            fut = self.loop.create_future()
            self.hub.cal_request = CalRequest(x=x, y=y, zone=zone, n=int(msg.get("frames", 24)),
                                              future=fut, loop=self.loop)
            try:
                result = await asyncio.wait_for(fut, timeout=6.0)
            except asyncio.TimeoutError:
                self.hub.cal_request = None
                result = {"count": 0, "points": self.hub.cal_points, "fitted": False}
        await self.broadcast({"type": "cal_done", "zone": zone, "x": x, "y": y,
                             "count": result["count"], "points": result["points"], "fitted": result["fitted"]})

    async def handle_suggest(self, ws, msg: dict) -> None:
        mid = msg.get("id", 0)
        keys, text, history = msg.get("keys", []), msg.get("text", ""), msg.get("history", [])
        if self.predict is None:
            await self._send(ws, json.dumps({"type": "words", "id": mid, "source": "local", "words": [], "phrases": []}))
            return
        try:
            out = await self.predict(keys, text, history)
            await self._send(ws, json.dumps({"type": "words", "id": mid, "source": out.get("source", "model"),
                                             "words": out.get("words", []), "phrases": out.get("phrases", [])}))
        except Exception as e:  # noqa: BLE001
            print(f"[intent] predict failed: {e}", flush=True)

    async def handler(self, ws) -> None:
        self.clients.add(ws)
        print(f"[ws] client connected ({len(self.clients)} total)", flush=True)
        try:
            await self._send(ws, json.dumps(self.hub.config()))
            await self._send(ws, json.dumps(self.hub.status()))
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except ValueError:
                    continue
                t = msg.get("type")
                if t == "cal":
                    asyncio.create_task(self.handle_cal(ws, msg))
                elif t == "cal_reset":
                    self.hub.cal_reset = True
                    self.hub.cal_points = 0
                    await self.broadcast({"type": "cal_done", "zone": -1, "count": 0, "points": 0, "fitted": False})
                elif t == "caption":
                    await self.broadcast({"type": "caption", "text": msg.get("text", ""), "final": bool(msg.get("final"))})
                elif t == "suggest":
                    asyncio.create_task(self.handle_suggest(ws, msg))
                elif t == "status":
                    await self._send(ws, json.dumps(self.hub.status()))
                elif t == "config":
                    await self._send(ws, json.dumps(self.hub.config()))
                elif t == "test_result":
                    self.log_test_result(msg)
        finally:
            self.clients.discard(ws)
            print(f"[ws] client disconnected ({len(self.clients)} total)", flush=True)

    def log_test_result(self, msg: dict) -> None:
        rec = {k: v for k, v in msg.items() if k != "type"}
        rec.update({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "mode": self.hub.mode, "camera": self.hub.camera,
                    "cols": self.hub.cols, "rows": self.hub.rows, "fps": round(self.hub.fps, 1)})
        with TEST_LOG.open("a") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        print(f"[test] overall {rec.get('overall')} -> {TEST_LOG.name}", flush=True)

    async def run(self) -> None:
        import websockets
        self.loop = asyncio.get_running_loop()
        self.cal_lock = asyncio.Lock()
        async with websockets.serve(self.handler, WS_HOST, WS_PORT, max_queue=4):
            print(f"[ws] ws://{WS_HOST}:{WS_PORT}", flush=True)
            pump = asyncio.create_task(self.gaze_pump())
            while not self.hub.stop.is_set():
                await asyncio.sleep(0.2)
            pump.cancel()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):  # noqa: D102
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def start_http() -> http.server.ThreadingHTTPServer:
    handler = functools.partial(QuietHandler, directory=str(STATIC_DIR))
    httpd = http.server.ThreadingHTTPServer((WS_HOST, HTTP_PORT), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True, name="http").start()
    print(f"[http] http://{WS_HOST}:{HTTP_PORT}/  (outer: /outer.html)", flush=True)
    return httpd


# ---------------------------------------------------------------------------
def main() -> None:
    global WS_PORT, HTTP_PORT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-camera", action="store_true", help="stream synthetic gaze")
    ap.add_argument("--debug", action="store_true", help="OpenCV window with landmarks and head axes")
    ap.add_argument("--mode", choices=["hybrid", "head"], default="hybrid")
    ap.add_argument("--cols", type=int, default=4, help="grid columns (zone = row*cols + col)")
    ap.add_argument("--rows", type=int, default=3, help="grid rows")
    ap.add_argument("--camera", type=int, default=0)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--ridge", type=float, default=3.0, help="ridge regularisation (standardized features)")
    ap.add_argument("--min-cutoff", type=float, default=1.0, help="One Euro min cutoff (Hz)")
    ap.add_argument("--beta", type=float, default=8.0, help="One Euro speed coefficient (normalized units)")
    ap.add_argument("--hyst-frames", type=int, default=3, help="frames a new zone must persist")
    ap.add_argument("--dead-band", type=float, default=0.1, help="zone dead band as a fraction of a cell")
    ap.add_argument("--fresh", action="store_true", help="ignore saved calibration.json")
    ap.add_argument("--ws-port", type=int, default=WS_PORT)
    ap.add_argument("--http-port", type=int, default=HTTP_PORT)
    args = ap.parse_args()
    WS_PORT, HTTP_PORT = args.ws_port, args.http_port

    hub = Hub()
    hub.mode = args.mode
    hub.cols, hub.rows = args.cols, args.rows
    model = CalibrationModel(mode=args.mode, ridge=args.ridge, cols=args.cols, rows=args.rows) \
        if args.fresh or args.no_camera else CalibrationModel.load(CAL_PATH, args.mode, args.ridge, args.cols, args.rows)
    hub.cal_points = model.n_points if model.ready else 0
    if model.ready:
        print(f"[cal] loaded {CAL_PATH.name}: {model.n_points} points, {len(model.samples)} samples", flush=True)
    est = GazeEstimator(model, min_cutoff=args.min_cutoff, beta=args.beta,
                        hyst_frames=args.hyst_frames, hyst_margin=args.dead_band)

    httpd = start_http()
    server = Server(hub)
    ws_thread = threading.Thread(target=lambda: asyncio.run(server.run()), daemon=True, name="ws")
    ws_thread.start()

    try:
        if args.no_camera:
            synthetic_loop(hub)
        else:
            camera_loop(args, hub, model, est)
    except KeyboardInterrupt:
        pass
    finally:
        hub.stop.set()
        httpd.shutdown()
        print("[main] bye", flush=True)


if __name__ == "__main__":
    main()
