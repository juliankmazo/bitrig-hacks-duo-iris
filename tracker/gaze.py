"""Gaze estimation from MediaPipe FaceLandmarker results.

Pipeline per frame:
  landmarks + blendshapes + head matrix -> feature vector (extract_all = v1 2D features + v2 pose-invariant)
  feature vector -> screen point (x, y in 0..1) via a ridge model fitted at calibration (calib.py)
  screen point -> median-3 -> One Euro filter -> zone with hysteresis

Everything here is pure numpy; no MediaPipe import so it can be unit-tested headless.
"""

from __future__ import annotations

import math
import time
from collections import deque
from dataclasses import dataclass

import numpy as np

# ---------------------------------------------------------------------------
# Landmark indices (MediaPipe face mesh, 478 points incl. iris)
# ---------------------------------------------------------------------------
# "Left"/"right" are the subject's own sides (MediaPipe convention).
L_OUTER, L_INNER, L_UPPER, L_LOWER = 33, 133, 159, 145
R_INNER, R_OUTER, R_UPPER, R_LOWER = 362, 263, 386, 374
L_IRIS = (468, 469, 470, 471, 472)
R_IRIS = (473, 474, 475, 476, 477)
NOSE_TIP = 1

BLENDSHAPE_KEYS = (
    "eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeLookDownLeft",
    "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeLookDownRight",
)

FEATURE_NAMES = (
    "iris_h_l", "iris_v_l", "iris_h_r", "iris_v_r",       # 0..3   iris along eye axis / between eyelids
    *BLENDSHAPE_KEYS,                                      # 4..11  eye blendshapes
    "yaw", "pitch", "roll",                                # 12..14 head rotation (rad)
    "nose_x", "nose_y", "head_z",                          # 15..17 head position
    "iris_off_l", "iris_off_r",                            # 18..19 iris offset perpendicular to the eye axis
    "aperture_l", "aperture_r",                            # 20..21 eyelid opening / eye width
)
N_FEATURES = len(FEATURE_NAMES)
# Features that get quadratic terms in the regression (the ones that carry gaze).
CORE_IDX = (0, 1, 2, 3, 12, 13)
# --mode head: ignore everything eye-related.
HEAD_ONLY_IDX = (12, 13, 14, 15, 16, 17)


def _project_ratio(p: np.ndarray, a: np.ndarray, b: np.ndarray) -> float:
    """Position of p along segment a->b, 0 at a, 1 at b (projected, so robust to roll)."""
    ab = b - a
    denom = float(ab @ ab)
    if denom < 1e-9:
        return 0.5
    return float(((p - a) @ ab) / denom)


def extract_features(pts: np.ndarray, blend: dict[str, float], matrix: np.ndarray | None,
                     size: tuple[int, int]) -> np.ndarray:
    """pts: (478, 2) landmark pixel coords. blend: name -> score. matrix: 4x4 or None. size: (w, h)."""
    f = np.zeros(N_FEATURES, dtype=np.float64)

    l_iris = pts[list(L_IRIS)].mean(axis=0)
    r_iris = pts[list(R_IRIS)].mean(axis=0)
    f[0] = _project_ratio(l_iris, pts[L_OUTER], pts[L_INNER])
    f[1] = _project_ratio(l_iris, pts[L_UPPER], pts[L_LOWER])
    f[2] = _project_ratio(r_iris, pts[R_INNER], pts[R_OUTER])
    f[3] = _project_ratio(r_iris, pts[R_UPPER], pts[R_LOWER])
    # roll-invariant: iris offset perpendicular to the corner axis, and eyelid aperture, both / eye width
    for k, (iris, a, b, up, lo) in enumerate(((l_iris, pts[L_OUTER], pts[L_INNER], pts[L_UPPER], pts[L_LOWER]),
                                              (r_iris, pts[R_INNER], pts[R_OUTER], pts[R_UPPER], pts[R_LOWER]))):
        axis = b - a
        width = float(np.linalg.norm(axis)) + 1e-6
        perp = np.array([-axis[1], axis[0]]) / width
        f[18 + k] = float((iris - (a + b) / 2) @ perp) / width
        f[20 + k] = float(np.linalg.norm(up - lo)) / width

    for i, k in enumerate(BLENDSHAPE_KEYS):
        f[4 + i] = blend.get(k, 0.0)

    if matrix is not None:
        R = matrix[:3, :3]
        sy = math.sqrt(R[0, 0] ** 2 + R[1, 0] ** 2)
        f[12] = math.atan2(-R[2, 0], sy)          # yaw
        f[13] = math.atan2(R[2, 1], R[2, 2])      # pitch
        f[14] = math.atan2(R[1, 0], R[0, 0])      # roll
        f[17] = float(matrix[2, 3]) / 100.0       # depth (cm -> m-ish scale)
    f[15] = pts[NOSE_TIP, 0] / size[0]
    f[16] = pts[NOSE_TIP, 1] / size[1]
    return f


# ---------------------------------------------------------------------------
# v2: pose-invariant eye features (canonical face frame)
# ---------------------------------------------------------------------------
# Landmarks logged raw so tune.py can recompute any feature offline.
FACE_L, FACE_R, FOREHEAD, CHIN = 234, 454, 10, 152
KEY_LANDMARKS = (NOSE_TIP, FOREHEAD, CHIN, FACE_L, FACE_R, L_OUTER, L_INNER, L_UPPER, L_LOWER,
                 R_INNER, R_OUTER, R_UPPER, R_LOWER, *L_IRIS, *R_IRIS)

V2_NAMES = (
    "c_eh_l", "c_eh_r",        # iris horizontal offset from the eye-corner midpoint, canonical frame / eye width
    "c_ev_l", "c_ev_r",        # iris vertical offset from the eye-corner midpoint, canonical frame / eye width
    "c_lid_l", "c_lid_r",      # iris vertical offset from the eyelid midpoint, canonical frame / eye width
    "c_ap_l", "c_ap_r",        # eyelid aperture, canonical frame / eye width
    "eye_h", "eye_v", "lid_v", # both-eye means of the above (less noise)
    "bs_h", "bs_v",            # signed eyeLook* blendshape combos (MediaPipe computes them in the face frame)
    "face_w",                  # face width / frame width (distance proxy)
)
ALL_NAMES = FEATURE_NAMES + V2_NAMES
N_ALL = len(ALL_NAMES)
IDX = {n: i for i, n in enumerate(ALL_NAMES)}

# pixel space (x right, y down, z away from camera) -> MediaPipe camera space (x right, y up, z toward viewer)
_PIX_TO_CAM = np.array([1.0, -1.0, -1.0])


def head_rotation(matrix: np.ndarray | None) -> np.ndarray:
    """Pure rotation part of the facial transformation matrix (canonical face -> camera)."""
    if matrix is None:
        return np.eye(3)
    u, _, vt = np.linalg.svd(np.asarray(matrix, dtype=np.float64)[:3, :3])
    R = u @ vt
    if np.linalg.det(R) < 0:
        return np.eye(3)
    return R


def _eye_canonical(P3: np.ndarray, R: np.ndarray, iris, a: int, b: int, up: int, lo: int):
    """Iris position relative to the eye, rotated into the canonical face frame (x right, y up in the image
    of a frontal face). a->b are the eye corners left->right in the image. Returns (h, v, lid, aperture)."""
    def can(v: np.ndarray) -> np.ndarray:        # delta in pixel space -> canonical face frame
        return (v * _PIX_TO_CAM) @ R              # == R^T @ v_cam
    c = P3[list(iris)].mean(axis=0)
    mid = (P3[a] + P3[b]) / 2
    width = float(np.linalg.norm(can(P3[b] - P3[a]))) + 1e-6
    d = can(c - mid)
    lid = can(c - (P3[up] + P3[lo]) / 2)
    return d[0] / width, d[1] / width, lid[1] / width, float(np.linalg.norm(can(P3[up] - P3[lo]))) / width


def extract_v2(P3: np.ndarray, blend: dict[str, float], matrix: np.ndarray | None,
               size: tuple[int, int]) -> np.ndarray:
    """P3: (478, 3) landmarks in pixels (x*w, y*h, z*w). Head yaw/pitch/roll and position stay in v1."""
    R = head_rotation(matrix)
    lh, lv, llid, lap = _eye_canonical(P3, R, L_IRIS, L_OUTER, L_INNER, L_UPPER, L_LOWER)
    rh, rv, rlid, rap = _eye_canonical(P3, R, R_IRIS, R_INNER, R_OUTER, R_UPPER, R_LOWER)
    g = blend.get
    bs_h = (g("eyeLookOutLeft", 0.0) + g("eyeLookInRight", 0.0) - g("eyeLookInLeft", 0.0) - g("eyeLookOutRight", 0.0)) / 2
    bs_v = (g("eyeLookUpLeft", 0.0) + g("eyeLookUpRight", 0.0) - g("eyeLookDownLeft", 0.0) - g("eyeLookDownRight", 0.0)) / 2
    face_w = float(np.linalg.norm(P3[FACE_R, :2] - P3[FACE_L, :2])) / size[0]
    return np.array([lh, rh, lv, rv, llid, rlid, lap, rap,
                     (lh + rh) / 2, (lv + rv) / 2, (llid + rlid) / 2, bs_h, bs_v, face_w], dtype=np.float64)


def extract_all(P3: np.ndarray, blend: dict[str, float], matrix: np.ndarray | None,
                size: tuple[int, int]) -> np.ndarray:
    """Full feature vector (ALL_NAMES): legacy 2D features followed by the v2 canonical-frame features."""
    return np.concatenate([extract_features(P3[:, :2], blend, matrix, size), extract_v2(P3, blend, matrix, size)])


def landmarks_from_key(key_norm, size: tuple[int, int]) -> np.ndarray:
    """Rebuild a (478, 3) pixel array from logged KEY_LANDMARKS (normalized x, y, z)."""
    w, h = size
    P3 = np.zeros((478, 3), dtype=np.float64)
    k = np.asarray(key_norm, dtype=np.float64)
    P3[list(KEY_LANDMARKS)] = k * np.array([w, h, w])
    return P3


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------
class OneEuroFilter:
    """Casiez et al. One Euro filter. Works on numpy vectors."""

    def __init__(self, min_cutoff: float = 1.0, beta: float = 8.0, d_cutoff: float = 1.0):
        self.min_cutoff, self.beta, self.d_cutoff = min_cutoff, beta, d_cutoff
        self.x_prev: np.ndarray | None = None
        self.dx_prev: np.ndarray | None = None
        self.t_prev: float | None = None

    @staticmethod
    def _alpha(cutoff: float, dt: float) -> float:
        tau = 1.0 / (2 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def reset(self) -> None:
        self.x_prev = self.dx_prev = self.t_prev = None

    def __call__(self, x: np.ndarray, t: float) -> np.ndarray:
        x = np.asarray(x, dtype=np.float64)
        if self.x_prev is None or self.t_prev is None:
            self.x_prev, self.dx_prev, self.t_prev = x.copy(), np.zeros_like(x), t
            return x
        dt = max(t - self.t_prev, 1e-3)
        self.t_prev = t
        dx = (x - self.x_prev) / dt
        a_d = self._alpha(self.d_cutoff, dt)
        dx_hat = a_d * dx + (1 - a_d) * self.dx_prev
        cutoff = self.min_cutoff + self.beta * float(np.linalg.norm(dx_hat))
        a = self._alpha(cutoff, dt)
        x_hat = a * x + (1 - a) * self.x_prev
        self.x_prev, self.dx_prev = x_hat, dx_hat
        return x_hat


def raw_zone(x: float, y: float, cols: int, rows: int) -> int:
    """Row-major zone index for a normalized point (top-left is 0)."""
    c = min(cols - 1, max(0, int(x * cols)))
    r = min(rows - 1, max(0, int(y * rows)))
    return r * cols + c


class ZoneHysteresis:
    """cols x rows zone from a point; switching needs `frames` consecutive frames and the point to be
    at least `margin` (fraction of a cell) past the border of the current zone (dead band)."""

    def __init__(self, frames: int = 3, margin: float = 0.1, cols: int = 4, rows: int = 3):
        self.frames, self.margin, self.cols, self.rows = frames, margin, cols, rows
        self.zone = -1
        self._cand = -1
        self._n = 0

    def raw_zone(self, x: float, y: float) -> int:
        return raw_zone(x, y, self.cols, self.rows)

    def _inside_expanded(self, zone: int, x: float, y: float) -> bool:
        c, r = zone % self.cols, zone // self.cols
        cw, rh = 1.0 / self.cols, 1.0 / self.rows
        mx, my = self.margin * cw, self.margin * rh
        return (c * cw - mx) <= x <= ((c + 1) * cw + mx) and (r * rh - my) <= y <= ((r + 1) * rh + my)

    def reset(self) -> None:
        self.zone, self._cand, self._n = -1, -1, 0

    def update(self, x: float, y: float) -> int:
        if self.zone >= 0 and self._inside_expanded(self.zone, x, y):
            self._cand, self._n = self.zone, 0
            return self.zone
        z = self.raw_zone(x, y)
        if z == self._cand:
            self._n += 1
        else:
            self._cand, self._n = z, 1
        if self._n >= self.frames or self.zone < 0:
            self.zone = z
        return self.zone


class BlinkDetector:
    """Both eyes closed for > hold seconds = one deliberate blink event.

    mean(eyeBlinkL, eyeBlinkR) > enter starts a closure, < exit ends it (hysteresis); the event fires
    once the closure lasts `hold` s, at most once per `refractory` s.
    """

    def __init__(self, enter: float = 0.45, exit_: float = 0.35, hold: float = 0.45, refractory: float = 0.8):
        self.enter, self.exit, self.hold, self.refractory = enter, exit_, hold, refractory
        self.closed = False
        self.closed_since: float | None = None
        self.fired = False
        self.last_fire = -1e9

    def update(self, blink_l: float, blink_r: float, t: float) -> tuple[bool, bool]:
        """Returns (eyes_closed, blink_event)."""
        v = (blink_l + blink_r) / 2
        self.closed = v > (self.exit if self.closed else self.enter)
        event = False
        if self.closed:
            if self.closed_since is None:
                self.closed_since = t
            elif not self.fired and t - self.closed_since >= self.hold and t - self.last_fire >= self.refractory:
                self.fired = event = True
                self.last_fire = t
        else:
            self.closed_since, self.fired = None, False
        return self.closed, event


# ---------------------------------------------------------------------------
# Calibration + regression
# ---------------------------------------------------------------------------
def zone_target(zone: int, cols: int, rows: int) -> tuple[float, float]:
    """Center of a zone in normalized screen coordinates."""
    return ((zone % cols) + 0.5) / cols, ((zone // cols) + 0.5) / rows


# ---------------------------------------------------------------------------
# Full estimator: raw features -> smoothed point, zone, blink, confidence
# ---------------------------------------------------------------------------
@dataclass
class GazeState:
    t: float = 0.0
    face: bool = False
    x: float = 0.5
    y: float = 0.5
    zone: int = -1
    blink: bool = False
    eyes_closed: bool = False
    conf: float = 0.0
    calibrated: bool = False
    raw: tuple[float, float] | None = None


class GazeEstimator:
    def __init__(self, model, min_cutoff: float = 1.0, beta: float = 8.0,
                 hyst_frames: int = 3, hyst_margin: float = 0.1):
        self.model = model
        self.filter = OneEuroFilter(min_cutoff=min_cutoff, beta=beta)
        self.zones = ZoneHysteresis(frames=hyst_frames, margin=hyst_margin, cols=model.cols, rows=model.rows)
        self.blinks = BlinkDetector()
        self.state = GazeState()
        self._raw_hist: list[np.ndarray] = []
        self._face_lost_since: float | None = None
        self._recent: deque[tuple[float, float, float, int]] = deque(maxlen=15)  # (t, x, y, zone)
        self._was_closed = False

    def reset_filters(self) -> None:
        self.filter.reset()
        self.zones.reset()
        self._raw_hist.clear()

    def update(self, feats: np.ndarray | None, blink_l: float, blink_r: float, t: float) -> GazeState:
        s = self.state
        s.t = t
        s.calibrated = self.model.ready
        s.blink = False
        if feats is None:
            s.face = False
            s.eyes_closed = False
            s.conf = 0.0
            if self._face_lost_since is None:
                self._face_lost_since = t
            elif t - self._face_lost_since > 1.0:
                s.zone = -1
                self.zones.reset()
            return s
        self._face_lost_since = None
        s.face = True

        closed, event = self.blinks.update(blink_l, blink_r, t)
        s.eyes_closed, s.blink = closed, event
        if closed:
            # Freeze the cursor while the eyes are shut: closed-eye landmarks are garbage. Rewind to
            # 150 ms before the onset so the eyelid-drop frames don't drag the point down.
            if not self._was_closed:
                self._was_closed = True
                for (tt, x, y, z) in self._recent:
                    if tt <= t - 0.15:
                        s.x, s.y, s.zone = x, y, z
                        self.zones.zone = z
                self.filter.reset()
            s.conf = min(s.conf, 0.5)
            return s
        self._was_closed = False

        raw = self.model.predict(feats)
        if raw is None:
            s.zone = -1
            s.conf = 0.25
            s.raw = None
            return s
        s.raw = raw
        self._raw_hist.append(np.array(raw))
        if len(self._raw_hist) > 12:
            self._raw_hist.pop(0)

        # median of the last 3 raw predictions rejects one-frame outliers, then One Euro.
        med = np.median(np.array(self._raw_hist[-3:]), axis=0)
        p = self.filter(med, t)
        x = float(min(1.0, max(0.0, p[0])))
        y = float(min(1.0, max(0.0, p[1])))
        s.x, s.y = x, y
        s.zone = self.zones.update(x, y)
        self._recent.append((t, x, y, s.zone))

        # confidence: low raw jitter + prediction inside the screen + enough cal points
        jitter = float(np.std(np.array(self._raw_hist), axis=0).mean()) if len(self._raw_hist) >= 4 else 0.05
        overshoot = max(0.0, -p[0], p[0] - 1.0, -p[1], p[1] - 1.0)
        conf = math.exp(-jitter / 0.06) * math.exp(-overshoot / 0.15)
        conf *= min(1.0, self.model.n_points / (self.model.cols * self.model.rows))
        s.conf = float(min(1.0, max(0.0, conf)))
        return s


# ---------------------------------------------------------------------------
# Synthetic gaze for --no-camera
# ---------------------------------------------------------------------------
class SyntheticGaze:
    """Smooth Lissajous path with a blink every ~6 s, so the UI can be exercised headless."""

    def __init__(self, cols: int = 4, rows: int = 3):
        self.t0 = time.monotonic()
        self.zones = ZoneHysteresis(cols=cols, rows=rows)
        self._last_blink = 0.0

    def sample(self) -> GazeState:
        t = time.monotonic() - self.t0
        x = 0.5 + 0.42 * math.sin(t * 0.55)
        y = 0.5 + 0.40 * math.sin(t * 0.37 + 1.3)
        blink = False
        if t - self._last_blink > 6.0:
            self._last_blink, blink = t, True
        return GazeState(t=t, face=True, x=x, y=y, zone=self.zones.update(x, y), blink=blink,
                         eyes_closed=False, conf=0.9, calibrated=True, raw=(x, y))
