"""Calibration models: candidate feature sets -> ridge regression -> screen (x, y).

Candidates (all ridge on standardized features, optional quadratic / interaction terms):
  v1       legacy: 22 2D features, quadratics on the 4 iris ratios + yaw/pitch (exactly the old model)
  v1f      v1 with sd floors on the head features (see SD_FLOOR)
  v2       canonical-frame (pose-invariant) eye features + blendshapes + head pose
  phys     compact "gaze = head angle + eye angle" model: [eye_h, eye_v, lid_v, yaw, pitch, roll, nose_x,
           nose_y, head_z] + eye quadratics + head*eye interactions
  phys_bs  phys + signed eyeLook* blendshape combos
  head     head pose only (--mode head)

`fit()` scores every candidate x ridge strength with leave-one-calibration-point-out cross-validation
(cheap: per-group Gram matrices are subtracted from the total) and keeps the best, unless a model is forced.

Why the SD floors: with a still-head calibration, yaw/pitch/nose barely vary, so dividing by their sd
turns a 2-degree head turn after calibration into a 30-sigma input and the prediction flies off. A floor
in physical units (e.g. 0.03 rad) keeps head terms at their true scale.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from gaze import ALL_NAMES, IDX, N_ALL, BLENDSHAPE_KEYS, FEATURE_NAMES

SD_FLOOR = {"yaw": 0.03, "pitch": 0.03, "roll": 0.03, "nose_x": 0.01, "nose_y": 0.01, "head_z": 0.01,
            "face_w": 0.005}
DEFAULT_LAMBDAS = (0.3, 1.0, 3.0, 10.0, 30.0)
_HEAD = ("yaw", "pitch", "roll", "nose_x", "nose_y", "head_z")


@dataclass(frozen=True)
class Spec:
    name: str
    lin: tuple[str, ...]
    quad: tuple[str, ...] = ()                   # squares + pairwise products among these
    inter: tuple[tuple[str, str], ...] = ()      # extra products
    floors: bool = True


SPECS: dict[str, Spec] = {s.name: s for s in (
    Spec("v1", FEATURE_NAMES, quad=("iris_h_l", "iris_v_l", "iris_h_r", "iris_v_r", "yaw", "pitch"), floors=False),
    Spec("v1f", FEATURE_NAMES, quad=("iris_h_l", "iris_v_l", "iris_h_r", "iris_v_r", "yaw", "pitch")),
    Spec("v2", ("c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r", "c_lid_l", "c_lid_r", "c_ap_l", "c_ap_r",
                *BLENDSHAPE_KEYS, *_HEAD),
         quad=("c_eh_l", "c_ev_l", "c_eh_r", "c_ev_r", "yaw", "pitch")),
    Spec("phys", ("eye_h", "eye_v", "lid_v", *_HEAD),
         quad=("eye_h", "eye_v", "lid_v"),
         inter=(("yaw", "eye_h"), ("pitch", "eye_v"), ("pitch", "lid_v"), ("yaw", "eye_v"), ("pitch", "eye_h"),
                ("yaw", "pitch"))),
    Spec("phys_bs", ("eye_h", "eye_v", "lid_v", "bs_h", "bs_v", *_HEAD),
         quad=("eye_h", "eye_v", "lid_v"),
         inter=(("yaw", "eye_h"), ("pitch", "eye_v"), ("pitch", "lid_v"), ("yaw", "eye_v"), ("pitch", "eye_h"),
                ("yaw", "pitch"))),
    Spec("head", _HEAD, quad=("yaw", "pitch")),
)}
AUTO_CANDIDATES = ("v1", "v1f", "v2", "phys", "phys_bs")


def zones_of(P: np.ndarray, cols: int, rows: int) -> np.ndarray:
    c = np.clip(np.floor(P[:, 0] * cols), 0, cols - 1)
    r = np.clip(np.floor(P[:, 1] * rows), 0, rows - 1)
    return (r * cols + c).astype(int)


class Design:
    """Standardization + design-matrix builder for one spec."""

    def __init__(self, spec: Spec, F: np.ndarray, quad_on: bool):
        self.spec, self.quad_on = spec, quad_on
        self.cols = [IDX[n] for n in spec.lin]
        sub = F[:, self.cols]
        self.mu = sub.mean(axis=0)
        sd = sub.std(axis=0) + 1e-6
        if spec.floors:
            sd = np.maximum(sd, [SD_FLOOR.get(n, 0.0) for n in spec.lin])
        self.sd = sd
        self.q = [spec.lin.index(n) for n in spec.quad]
        self.inter = [(spec.lin.index(a), spec.lin.index(b)) for a, b in spec.inter]

    def __call__(self, F: np.ndarray) -> np.ndarray:
        Z = (F[:, self.cols] - self.mu) / self.sd
        parts = [np.ones((Z.shape[0], 1)), Z]
        if self.quad_on:
            if self.q:
                C = Z[:, self.q]
                parts.append(C * C)
                parts += [C[:, a:a + 1] * C[:, b:b + 1] for a in range(len(self.q)) for b in range(a + 1, len(self.q))]
            parts += [Z[:, a:a + 1] * Z[:, b:b + 1] for a, b in self.inter]
        return np.hstack(parts)


def _penalty(n: int, lam: float) -> np.ndarray:
    P = lam * np.eye(n)
    P[0, 0] = 0.0   # don't shrink the bias
    return P


@dataclass
class Fitted:
    spec: Spec
    lam: float
    design: Design
    W: np.ndarray

    def predict(self, F: np.ndarray) -> np.ndarray:
        return self.design(F) @ self.W


def fit_one(F: np.ndarray, T: np.ndarray, spec: Spec, lam: float, quad_on: bool,
            weights: np.ndarray | None = None) -> Fitted:
    d = Design(spec, F, quad_on)
    X = d(F)
    Xw = X if weights is None else X * weights[:, None]
    W = np.linalg.solve(Xw.T @ X + _penalty(X.shape[1], lam), Xw.T @ T)
    return Fitted(spec, lam, d, W)


def lopo(F: np.ndarray, T: np.ndarray, groups: np.ndarray, stages: np.ndarray, spec: Spec,
         lams, quad_on: bool, cols: int, rows: int) -> dict[float, dict]:
    """Leave-one-calibration-point-out CV. Sweep groups are never held out as points (they are always in
    training) but get their own score: fit without the sweep, predict the sweep frames (= head tolerance).
    Returns {lam: {"err", "acc", "per_group": {g: (err, acc)}, "sweep_err"}}."""
    d = Design(spec, F, quad_on)           # global standardization (tiny leak, fine for model selection)
    X = d(F)
    G, B = X.T @ X, X.T @ T
    point_groups = sorted({int(g) for g, s in zip(groups, stages) if s == "point"})
    sweep_mask = stages == "sweep"
    stats = {g: (X[groups == g].T @ X[groups == g], X[groups == g].T @ T[groups == g]) for g in point_groups}
    tz = zones_of(T, cols, rows)
    out = {}
    for lam in lams:
        P = _penalty(X.shape[1], lam)
        per = {}
        for g in point_groups:
            Gg, Bg = stats[g]
            try:
                W = np.linalg.solve(G - Gg + P, B - Bg)
            except np.linalg.LinAlgError:
                continue
            m = groups == g
            pred = X[m] @ W
            per[g] = (float(np.linalg.norm(pred - T[m], axis=1).mean()),
                      float((zones_of(pred, cols, rows) == tz[m]).mean()))
        sweep_err = None
        if sweep_mask.any() and (~sweep_mask).sum() > X.shape[1]:
            Xs = X[~sweep_mask]
            W = np.linalg.solve(Xs.T @ Xs + P, Xs.T @ T[~sweep_mask])
            sweep_err = float(np.linalg.norm(X[sweep_mask] @ W - T[sweep_mask], axis=1).mean())
        if per:
            out[lam] = {"err": float(np.mean([e for e, _ in per.values()])),
                        "acc": float(np.mean([a for _, a in per.values()])),
                        "per_group": per, "sweep_err": sweep_err}
    return out


class CalibrationModel:
    def __init__(self, mode: str = "hybrid", ridge: float = 3.0, cols: int = 4, rows: int = 3,
                 model: str = "auto", lambdas=DEFAULT_LAMBDAS, verbose: bool = True):
        self.mode, self.ridge, self.cols, self.rows = mode, ridge, cols, rows
        self.model_choice = "head" if mode == "head" else model
        self.lambdas = tuple(sorted(set(lambdas) | {ridge}))
        self.verbose = verbose
        self.F: list[np.ndarray] = []
        self.T: list[tuple[float, float]] = []
        self.groups: list[int] = []
        self.stages: list[str] = []
        self.fitted: Fitted | None = None
        self.report: dict[str, dict] = {}     # candidate -> best LOPO metrics

    # ---- data --------------------------------------------------------------
    def add(self, feats: np.ndarray, x: float, y: float, group: int = -1, stage: str = "point") -> None:
        self.F.append(np.asarray(feats, dtype=np.float64))
        self.T.append((float(x), float(y)))
        self.groups.append(int(group))
        self.stages.append(stage)

    def clear(self) -> None:
        self.F.clear(); self.T.clear(); self.groups.clear(); self.stages.clear()
        self.fitted = None
        self.report = {}

    @property
    def samples(self) -> list:
        return self.F

    @property
    def n_points(self) -> int:
        return len({(round(x, 3), round(y, 3)) for (x, y), s in zip(self.T, self.stages) if s != "sweep"})

    @property
    def ready(self) -> bool:
        return self.fitted is not None

    def arrays(self):
        return (np.array(self.F), np.array(self.T), np.array(self.groups), np.array(self.stages))

    # ---- fit ---------------------------------------------------------------
    def fit(self) -> bool:
        if len(self.F) < 6:
            self.fitted = None
            return False
        F, T, groups, stages = self.arrays()
        # legacy fallback: samples without a group id get one per distinct target
        if (groups < 0).any():
            keys = {k: i for i, k in enumerate(sorted({(round(x, 3), round(y, 3)) for x, y in T}))}
            groups = np.array([keys[(round(x, 3), round(y, 3))] for x, y in T])
        quad_on = self.n_points >= 7
        names = AUTO_CANDIDATES if self.model_choice == "auto" else (self.model_choice,)
        n_groups = len({g for g, s in zip(groups, stages) if s == "point"})
        # too few points for CV -> the compact physical model (or the forced one) at --ridge
        best = (float("inf"), "phys" if self.model_choice == "auto" else self.model_choice, self.ridge)
        self.report = {}
        if n_groups >= 4:
            lams = self.lambdas if self.model_choice == "auto" else (self.ridge,)
            for name in names:
                res = lopo(F, T, groups, stages, SPECS[name], lams, quad_on, self.cols, self.rows)
                if not res:
                    continue
                lam = min(res, key=lambda k: res[k]["err"])
                self.report[name] = {"lam": lam, **{k: v for k, v in res[lam].items() if k != "per_group"},
                                     "per_group": res[lam]["per_group"]}
                if res[lam]["err"] < best[0]:
                    best = (res[lam]["err"], name, lam)
        _, name, lam = best
        self.fitted = fit_one(F, T, SPECS[name], lam, quad_on)
        if self.verbose and self.report:
            print("[cal] " + self.summary(), flush=True)
        return True

    def summary(self) -> str:
        if not self.fitted:
            return "not fitted"
        parts = []
        for name, r in self.report.items():
            sw = f" sw {r['sweep_err']:.3f}" if r.get("sweep_err") is not None else ""
            mark = "*" if name == self.fitted.spec.name else ""
            parts.append(f"{mark}{name}(λ{r['lam']:g}) err {r['err']:.3f} acc {r['acc'] * 100:.0f}%{sw}")
        head = f"{self.n_points} pts, {len(self.F)} samples, using {self.fitted.spec.name} λ{self.fitted.lam:g}"
        return head + (" | LOPO: " + " | ".join(parts) if parts else "")

    # ---- predict -----------------------------------------------------------
    def predict(self, feats: np.ndarray) -> tuple[float, float] | None:
        if self.fitted is None:
            return None
        p = self.fitted.predict(np.asarray(feats, dtype=np.float64)[None, :])
        return float(p[0, 0]), float(p[0, 1])

    @property
    def name(self) -> str:
        return self.fitted.spec.name if self.fitted else "none"

    # ---- persistence -------------------------------------------------------
    def save(self, path: Path) -> None:
        path.write_text(json.dumps({
            "version": 2, "mode": self.mode, "names": ALL_NAMES,
            "samples": [[[round(float(v), 6) for v in f], x, y, g, s]
                        for f, (x, y), g, s in zip(self.F, self.T, self.groups, self.stages)],
        }))

    @classmethod
    def load(cls, path: Path, mode: str, ridge: float, cols: int = 4, rows: int = 3,
             model: str = "auto") -> "CalibrationModel":
        m = cls(mode=mode, ridge=ridge, cols=cols, rows=rows, model=model)
        try:
            data = json.loads(path.read_text())
            if data.get("version") == 2 and tuple(data.get("names", ())) == ALL_NAMES:
                for f, x, y, g, s in data.get("samples", []):
                    if len(f) == N_ALL:
                        m.add(np.array(f), x, y, g, s)
                m.fit()
            elif data:
                print(f"[cal] {path.name} is from an older feature set; recalibrate", flush=True)
        except (OSError, ValueError, KeyError, TypeError):
            pass
        return m
