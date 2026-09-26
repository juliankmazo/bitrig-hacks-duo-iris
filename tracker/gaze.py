"""Gaze estimation from MediaPipe FaceLandmarker results.

Pipeline per frame:
  landmarks + blendshapes + head matrix -> feature vector (extract_features)
  feature vector -> screen point (x, y in 0..1) via ridge regression fitted at calibration
  screen point -> One Euro filter -> zone 0..8 with hysteresis

Everything here is pure numpy; no MediaPipe import so it can be unit-tested headless.
"""

from __future__ import annotations

import json
import math
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

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


@dataclass
class CalibrationModel:
    mode: str = "hybrid"                       # hybrid | head
    ridge: float = 3.0
    cols: int = 4
    rows: int = 3
    samples: list[tuple[list[float], float, float]] = field(default_factory=list)
    # fitted state
    mu: np.ndarray | None = None
    sd: np.ndarray | None = None
    W: np.ndarray | None = None                # (n_design, 2)
    centroids: dict[int, np.ndarray] = field(default_factory=dict)  # zone -> standardized feature mean
    quadratic: bool = True

    # ---- feature masking / design matrix ---------------------------------
    def _mask(self) -> np.ndarray:
        m = np.zeros(N_FEATURES, dtype=bool)
        if self.mode == "head":
            m[list(HEAD_ONLY_IDX)] = True
        else:
            m[:] = True
        return m

    def _standardize(self, F: np.ndarray) -> np.ndarray:
        return ((F - self.mu) / self.sd)[:, self._mask()]

    def _design(self, Z: np.ndarray) -> np.ndarray:
        cols = [np.ones((Z.shape[0], 1)), Z]
        if self.quadratic:
            core = [i for i, j in enumerate(np.flatnonzero(self._mask())) if j in CORE_IDX]
            if core:
                C = Z[:, core]
                cols.append(C * C)
                # pairwise products of the core terms (small: 6 -> 15)
                prods = [C[:, a:a + 1] * C[:, b:b + 1] for a in range(len(core)) for b in range(a + 1, len(core))]
                if prods:
                    cols.append(np.hstack(prods))
        return np.hstack(cols)

    # ---- data --------------------------------------------------------------
    def add(self, feats: np.ndarray, x: float, y: float) -> None:
        self.samples.append(([float(v) for v in feats], float(x), float(y)))

    def clear(self) -> None:
        self.samples.clear()
        self.mu = self.sd = self.W = None
        self.centroids.clear()

    @property
    def n_points(self) -> int:
        return len({(round(x, 3), round(y, 3)) for _, x, y in self.samples})

    @property
    def ready(self) -> bool:
        return self.W is not None

    # ---- fit ---------------------------------------------------------------
    def fit(self) -> bool:
        if len(self.samples) < 6:
            self.W = None
            return False
        F = np.array([s[0] for s in self.samples], dtype=np.float64)
        T = np.array([[s[1], s[2]] for s in self.samples], dtype=np.float64)
        self.mu = F.mean(axis=0)
        self.sd = F.std(axis=0) + 1e-6
        # Quadratic terms only make sense once there are enough distinct targets.
        self.quadratic = self.n_points >= 7
        Z = self._standardize(F)
        X = self._design(Z)
        lam = self.ridge * np.eye(X.shape[1])
        lam[0, 0] = 0.0  # don't shrink the bias
        self.W = np.linalg.solve(X.T @ X + lam, X.T @ T)

        # nearest-centroid fallback, keyed by the zone of the target
        self.centroids.clear()
        buckets: dict[int, list[np.ndarray]] = {}
        for z_row, (_, x, y) in zip(Z, self.samples):
            buckets.setdefault(raw_zone(x, y, self.cols, self.rows), []).append(z_row)
        for k, rows in buckets.items():
            self.centroids[k] = np.mean(rows, axis=0)
        return True

    # ---- predict -----------------------------------------------------------
    def predict(self, feats: np.ndarray) -> tuple[float, float] | None:
        if self.W is None:
            return None
        Z = self._standardize(feats[None, :])
        p = self._design(Z) @ self.W
        return float(p[0, 0]), float(p[0, 1])

    def nearest_zone(self, feats: np.ndarray) -> int:
        if not self.centroids or self.mu is None:
            return -1
        z = self._standardize(feats[None, :])[0]
        best, best_d = -1, float("inf")
        for k, c in self.centroids.items():
            d = float(np.sum((z - c) ** 2))
            if d < best_d:
                best, best_d = k, d
        return best

    # ---- persistence -------------------------------------------------------
    def save(self, path: Path) -> None:
        path.write_text(json.dumps({
            "version": 1, "mode": self.mode, "ridge": self.ridge,
            "features": FEATURE_NAMES, "samples": self.samples,
        }))

    @classmethod
    def load(cls, path: Path, mode: str, ridge: float, cols: int = 4, rows: int = 3) -> "CalibrationModel":
        m = cls(mode=mode, ridge=ridge, cols=cols, rows=rows)
        try:
            data = json.loads(path.read_text())
            if tuple(data.get("features", ())) == FEATURE_NAMES:
                m.samples = [(s[0], s[1], s[2]) for s in data.get("samples", [])]
                m.fit()
        except (OSError, ValueError, KeyError):
            pass
        return m


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
    def __init__(self, model: CalibrationModel, min_cutoff: float = 1.0, beta: float = 8.0,
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
