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
    uv run --python 3.12 tracker/server.py --cal-hold      # old still-head calibration (24 frames/point)

Calibration is two-phase by default: per dot ~1.2 s with the head still (eyes only) then ~1.5 s of gentle
head turns/nods while fixating, so the model sees both "eyes do the work" and "head does the work". Every calibration / zone-test frame is logged to cal_samples.jsonl /
test_samples.jsonl so tune.py can compare models offline.

WebSocket ws://127.0.0.1:8765  (see README "Shared contract"; gaze messages add x, y, conf)
HTTP      http://127.0.0.1:8766/  demo UI, /outer.html simulated outer display
"""

from __future__ import annotations

import os

# Single-threaded BLAS: the calibration fit is tiny, and multi-threaded BLAS next to MediaPipe's worker
# threads turned a 30 ms fit into 5 s of camera-thread stall. Must be set before numpy is imported.
for _v in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import argparse  # noqa: E402
import asyncio  # noqa: E402
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
    GazeEstimator, GazeState, SyntheticGaze, extract_all, zone_target, raw_zone, ALL_NAMES, KEY_LANDMARKS,
    BLENDSHAPE_KEYS, L_IRIS, R_IRIS, L_OUTER, L_INNER, L_UPPER, L_LOWER, R_OUTER, R_INNER, R_UPPER, R_LOWER,
    NOSE_TIP,
)
from calib import CalibrationModel, SPECS  # noqa: E402

MODEL_PATH = HERE / "face_landmarker.task"
CAL_PATH = HERE / "calibration.json"
TEST_LOG = HERE / "test_results.jsonl"
CAL_SAMPLES = HERE / "cal_samples.jsonl"
TEST_SAMPLES = HERE / "test_samples.jsonl"
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
    n: int = 90
    settle: float = 0.4
    timeout: float = 7.4
    stage: str = "point"            # point | sweep (request kind)
    still_n: int = 0                # two-phase dots: first still_n used frames are "still", the rest "move"
    point: int = 0                  # group id within the calibration session
    started: float = 0.0
    count: int = 0
    frames: int = 0
    future: asyncio.Future | None = None
    loop: asyncio.AbstractEventLoop | None = None

    def phase(self) -> str:
        """Stage label for the next captured frame."""
        if self.stage == "point" and self.still_n > 0:
            return "still" if self.count < self.still_n else "move"
        return self.stage


class Recorder:
    """Appends one JSON line per calibration / zone-test frame (raw landmarks + all features + target)."""

    def __init__(self, enabled: bool = True):
        self.enabled = enabled
        self._files: dict[Path, object] = {}
        self.lock = threading.Lock()

    def write(self, path: Path, rec: dict) -> None:
        if not self.enabled:
            return
        with self.lock:
            f = self._files.get(path)
            if f is None:
                f = self._files[path] = path.open("a")
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")

    def flush(self) -> None:
        """Flush, and reopen next time if a file was deleted/moved while open (so `rm` starts a fresh log)."""
        with self.lock:
            for path, f in list(self._files.items()):
                f.flush()
                if not path.exists():
                    f.close()
                    del self._files[path]


def frame_payload(feats, key_norm, matrix, blend: dict, size) -> dict:
    """Everything tune.py needs to recompute features offline."""
    return {
        "feats": None if feats is None else [round(float(v), 6) for v in feats],
        "lm": None if key_norm is None else [[round(float(v), 5) for v in p] for p in key_norm],
        "M": None if matrix is None else [round(float(v), 5) for v in np.asarray(matrix).ravel()],
        "bs": {k: round(float(blend.get(k, 0.0)), 4) for k in (*BLENDSHAPE_KEYS, "eyeBlinkLeft", "eyeBlinkRight")},
        "size": list(size),
    }


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
        # calibration flow settings (sent to the UI in `config`)
        self.cal_frames, self.cal_settle, self.cal_hold = 81, 0.4, False
        self.cal_still_frames, self.cal_move_frames = 36, 45     # two-phase dots (0 still = single phase)
        self.sweep_frames, self.cal_sweep, self.cal_corners = 0, False, False
        self.model_name = "none"
        # recording
        self.recorder = Recorder()
        self.session = time.strftime("%Y%m%d-%H%M%S")
        self.next_point = 0
        self.test: dict | None = None     # {"zone", "t0", "run", "i"} while a zone-test target is shown
        self.emit = lambda msg: None      # thread-safe broadcast, set by Server.run

    def new_session(self) -> None:
        self.session = time.strftime("%Y%m%d-%H%M%S")
        self.next_point = 0
        self.recorder.flush()

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
                    "mode": self.mode, "camera": self.camera, "model": self.model_name}

    def config(self) -> dict:
        return {"type": "config", "cols": self.cols, "rows": self.rows, "mode": self.mode,
                "camera": self.camera, "cal_points": self.cal_points,
                "cal_frames": self.cal_frames, "cal_settle": self.cal_settle, "cal_hold": self.cal_hold,
                "cal_sweep": self.cal_sweep, "cal_corners": self.cal_corners, "sweep_frames": self.sweep_frames,
                "cal_still_frames": self.cal_still_frames, "cal_move_frames": self.cal_move_frames,
                "model": self.model_name}


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
        feats = key_norm = None
        blend: dict = {}
        blink_l = blink_r = 0.0
        if res.face_landmarks:
            lm = res.face_landmarks[0]
            norm = np.array([[p.x, p.y, p.z] for p in lm], dtype=np.float64)
            P3 = norm * np.array([w, h, w])
            pts = P3[:, :2]
            key_norm = norm[list(KEY_LANDMARKS)]
            blend = {c.category_name: c.score for c in res.face_blendshapes[0]} if res.face_blendshapes else {}
            blink_l, blink_r = blend.get("eyeBlinkLeft", 0.0), blend.get("eyeBlinkRight", 0.0)
            if res.facial_transformation_matrixes:
                matrix = np.array(res.facial_transformation_matrixes[0], dtype=np.float64)
            feats = extract_all(P3, blend, matrix, (w, h))
        payload = None

        # calibration capture / reset requests from the websocket side
        if hub.cal_reset:
            hub.cal_reset = False
            model.clear()
            est.reset_filters()
            hub.cal_points = 0
            hub.model_name = "none"
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
            used = feats is not None and eyes_open and elapsed >= req.settle
            stage = req.phase()
            if used:
                model.add(feats, req.x, req.y, req.point, stage)
                req.count += 1
            req.frames += 1
            payload = frame_payload(feats, key_norm, matrix, blend, (w, h))
            hub.recorder.write(CAL_SAMPLES, {
                "kind": "cal", "session": hub.session, "t": round(t0, 4), "point": req.point, "stage": stage,
                "tx": req.x, "ty": req.y, "zone": req.zone, "since": round(elapsed, 4), "used": used,
                "hold": hub.cal_hold, **payload})
            if req.frames % 3 == 0 or req.count >= req.n:
                hub.emit({"type": "cal_progress", "zone": req.zone, "stage": req.stage, "phase": req.phase(),
                          "count": req.count, "n": req.n, "still_n": req.still_n, "settling": elapsed < req.settle})
            if req.count >= req.n or elapsed >= req.timeout:
                hub.cal_request = None
                hub.recorder.flush()
                t_fit = time.monotonic()
                fitted = model.fit()
                if fitted:
                    model.save(CAL_PATH)
                    print(f"[cal] fit in {(time.monotonic() - t_fit) * 1000:.0f} ms", flush=True)
                est.reset_filters()
                hub.cal_points = model.n_points
                hub.model_name = model.name
                best = model.report.get(model.name, {})
                if req.loop and req.future:
                    req.loop.call_soon_threadsafe(req.future.set_result, {
                        "count": req.count, "points": model.n_points, "fitted": fitted, "model": model.name,
                        "lopo_err": round(best["err"], 4) if best else None,
                        "lopo_acc": round(best["acc"], 3) if best else None})

        state = est.update(feats, blink_l, blink_r, t0)
        t2 = time.monotonic()

        test = hub.test
        if test is not None and test["zone"] >= 0:
            if payload is None:
                payload = frame_payload(feats, key_norm, matrix, blend, (w, h))
            hub.recorder.write(TEST_SAMPLES, {
                "kind": "test", "run": test["run"], "cal_session": hub.session, "i": test["i"],
                "t": round(t0, 4), "zone": test["zone"], "since": round(t0 - test["t0"], 4),
                "live": {"x": round(state.x, 4), "y": round(state.y, 4), "zone": state.zone if state.calibrated else -1,
                         "raw": None if state.raw is None else [round(v, 4) for v in state.raw],
                         "face": state.face, "closed": state.eyes_closed, "model": model.name},
                **payload})

        frame_times.append(t2)
        infer_hist.append((t1 - t0) * 1000)
        e2e_hist.append((t2 - t0) * 1000)
        fps = (len(frame_times) - 1) / (frame_times[-1] - frame_times[0]) if len(frame_times) > 1 else 0.0
        hub.publish(state, float(np.mean(infer_hist)), float(np.mean(e2e_hist)), fps)

        if t2 - last_print >= 2.0:
            last_print = t2
            print(f"[track] fps {fps:5.1f} | infer {np.mean(infer_hist):5.1f} ms | e2e {np.mean(e2e_hist):5.1f} ms"
                  f" | face {state.face!s:5} | zone {state.zone:2d} | conf {state.conf:.2f}"
                  f" | cal {model.n_points} pts ({model.name})", flush=True)

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
            elapsed = t0 - req.started
            if elapsed >= req.settle:
                req.count += 1
            req.frames += 1
            if req.frames % 3 == 0 or req.count >= req.n:
                hub.emit({"type": "cal_progress", "zone": req.zone, "stage": req.stage, "phase": req.phase(),
                          "count": req.count, "n": req.n, "still_n": req.still_n, "settling": elapsed < req.settle})
            if req.count >= req.n:
                hub.cal_request = None
                hub.cal_points = hub.cols * hub.rows
                if req.loop and req.future:
                    req.loop.call_soon_threadsafe(req.future.set_result, {
                        "count": req.count, "points": hub.cols * hub.rows, "fitted": True, "model": "synthetic"})
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
        hub = self.hub
        stage = "sweep" if msg.get("stage") == "sweep" else "point"
        default_n = (hub.sweep_frames or 120) if stage == "sweep" else hub.cal_frames
        n = max(1, int(msg.get("frames") or default_n))
        still_n = 0
        if stage == "point" and hub.cal_still_frames > 0 and hub.cal_move_frames > 0:
            # two-phase dot; a `frames` override keeps the still:move ratio
            still_n = int(msg.get("still_frames")
                          or round(n * hub.cal_still_frames / (hub.cal_still_frames + hub.cal_move_frames)))
        settle = float(msg.get("settle", hub.cal_settle))
        timeout = settle + n / 30 * 2.0 + 1.0     # blinks / lost face frames don't count
        async with self.cal_lock:
            fut = self.loop.create_future()
            point = hub.next_point
            hub.next_point += 1
            hub.cal_request = CalRequest(x=x, y=y, zone=zone, n=n, settle=settle, timeout=timeout, stage=stage,
                                         still_n=still_n, point=point, future=fut, loop=self.loop)
            try:
                result = await asyncio.wait_for(fut, timeout=timeout + 3.0)
            except asyncio.TimeoutError:
                hub.cal_request = None
                result = {"count": 0, "points": hub.cal_points, "fitted": False}
        await self.broadcast({"type": "cal_done", "zone": zone, "x": x, "y": y, "stage": stage,
                             "count": result["count"], "points": result["points"], "fitted": result["fitted"],
                             "model": result.get("model"), "lopo_err": result.get("lopo_err"),
                             "lopo_acc": result.get("lopo_acc")})

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
                    self.hub.new_session()
                    self.hub.recorder.write(CAL_SAMPLES, {
                        "kind": "session", "session": self.hub.session, "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
                        "names": ALL_NAMES, "key_landmarks": KEY_LANDMARKS, "cols": self.hub.cols,
                        "rows": self.hub.rows, "mode": self.hub.mode, "cal_frames": self.hub.cal_frames,
                        "settle": self.hub.cal_settle, "hold": self.hub.cal_hold, "camera": self.hub.camera})
                    await self.broadcast({"type": "cal_done", "zone": -1, "count": 0, "points": 0, "fitted": False})
                elif t == "caption":
                    await self.broadcast({"type": "caption", "text": msg.get("text", ""), "final": bool(msg.get("final"))})
                elif t == "suggest":
                    asyncio.create_task(self.handle_suggest(ws, msg))
                elif t == "status":
                    await self._send(ws, json.dumps(self.hub.status()))
                elif t == "config":
                    await self._send(ws, json.dumps(self.hub.config()))
                elif t == "test_zone":
                    self.on_test_zone(msg)
                elif t == "test_result":
                    self.hub.test = None
                    self.hub.recorder.flush()
                    self.log_test_result(msg)
        finally:
            self.clients.discard(ws)
            print(f"[ws] client disconnected ({len(self.clients)} total)", flush=True)

    def on_test_zone(self, msg: dict) -> None:
        """UI highlights a zone-test target (zone -1 = test over). Frames get labelled with it."""
        zone = int(msg.get("zone", -1))
        if zone < 0:
            self.hub.test = None
            self.hub.recorder.flush()
            return
        i = int(msg.get("i", 0))
        if i == 0:
            self.hub.recorder.flush()
        prev = self.hub.test
        run = prev["run"] if prev and i > 0 else time.strftime("%Y%m%d-%H%M%S")
        self.hub.test = {"zone": zone, "t0": time.monotonic(), "run": run, "i": i}

    def log_test_result(self, msg: dict) -> None:
        rec = {k: v for k, v in msg.items() if k != "type"}
        rec.update({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "mode": self.hub.mode, "camera": self.hub.camera,
                    "cols": self.hub.cols, "rows": self.hub.rows, "fps": round(self.hub.fps, 1),
                    "cal_session": self.hub.session, "model": self.hub.model_name, "cal_hold": self.hub.cal_hold})
        with TEST_LOG.open("a") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
        print(f"[test] overall {rec.get('overall')} -> {TEST_LOG.name}", flush=True)

    async def run(self) -> None:
        import websockets
        self.loop = asyncio.get_running_loop()
        self.cal_lock = asyncio.Lock()
        loop = self.loop

        def emit(msg: dict) -> None:
            loop.call_soon_threadsafe(lambda: asyncio.ensure_future(self.broadcast(msg)))
        self.hub.emit = emit
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
    ap.add_argument("--model", choices=["auto", *SPECS], default="auto",
                    help="calibration model; auto = best leave-one-point-out candidate")
    ap.add_argument("--cal-hold", action="store_true",
                    help="old single-phase still-head calibration: 24 frames/point, 0.35 s settle, corner points")
    ap.add_argument("--cal-still-frames", type=int, default=36, help="phase A per dot: head still, eyes only (~1.2 s)")
    ap.add_argument("--cal-move-frames", type=int, default=45, help="phase B per dot: gentle head turns/nods (~1.5 s)")
    ap.add_argument("--cal-frames", type=int, default=None,
                    help="total frames per dot (default still+move = 81; 24 with --cal-hold); two-phase keeps the ratio")
    ap.add_argument("--cal-settle", type=float, default=None, help="seconds discarded after each dot appears (0.4)")
    ap.add_argument("--sweep-frames", type=int, default=0, help="optional final central head sweep (e.g. 120 ≈ 4 s); 0 = off")
    ap.add_argument("--no-sweep", action="store_true", help="force the head sweep off")
    ap.add_argument("--move-weight", "--sweep-weight", dest="move_weight", type=float, default=1.0,
                    help="fit weight of head-motion frames (move/sweep) relative to still frames")
    ap.add_argument("--cal-corners", action="store_true", help="add the 4 corner points (default only with --cal-hold)")
    ap.add_argument("--no-record", action="store_true", help="don't log cal/test frames to *_samples.jsonl")
    ap.add_argument("--ws-port", type=int, default=WS_PORT)
    ap.add_argument("--http-port", type=int, default=HTTP_PORT)
    args = ap.parse_args()
    WS_PORT, HTTP_PORT = args.ws_port, args.http_port

    hub = Hub()
    hub.mode = args.mode
    hub.cols, hub.rows = args.cols, args.rows
    hub.cal_hold = args.cal_hold
    if args.cal_hold:
        hub.cal_still_frames = hub.cal_move_frames = 0
        hub.cal_frames = args.cal_frames or 24
    else:
        hub.cal_still_frames, hub.cal_move_frames = args.cal_still_frames, args.cal_move_frames
        hub.cal_frames = args.cal_frames or (args.cal_still_frames + args.cal_move_frames)
    hub.cal_settle = args.cal_settle if args.cal_settle is not None else (0.35 if args.cal_hold else 0.4)
    hub.cal_sweep = args.sweep_frames > 0 and not (args.no_sweep or args.cal_hold)
    hub.cal_corners = args.cal_corners or args.cal_hold
    hub.sweep_frames = args.sweep_frames
    hub.recorder.enabled = not (args.no_record or args.no_camera)
    model = CalibrationModel(mode=args.mode, ridge=args.ridge, cols=args.cols, rows=args.rows, model=args.model,
                             move_weight=args.move_weight) \
        if args.fresh or args.no_camera else CalibrationModel.load(CAL_PATH, args.mode, args.ridge, args.cols, args.rows,
                                                                    model=args.model, move_weight=args.move_weight)
    hub.cal_points = model.n_points if model.ready else 0
    hub.model_name = model.name
    hub.next_point = max(model.groups, default=-1) + 1   # new points extend a loaded calibration
    if model.ready:
        print(f"[cal] loaded {CAL_PATH.name}: {model.n_points} points, {len(model.samples)} samples, "
              f"model {model.name}", flush=True)
    flow = "hold (still head)" if hub.cal_hold else f"two-phase {hub.cal_still_frames} still + {hub.cal_move_frames} move"
    print(f"[cal] flow: {flow}, {hub.cal_frames} frames/point, move weight {args.move_weight:g}, "
          f"settle {hub.cal_settle}s, sweep {'on' if hub.cal_sweep else 'off'}, corners {'on' if hub.cal_corners else 'off'}, "
          f"model {args.model}", flush=True)
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
