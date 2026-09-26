"""Replay an IrisGaze calibration recording and compare gaze models on its validation frames.

The app writes one JSONL per calibration run to its Documents dir (path shown in the Test overlay):
  xcrun simctl get_app_container AD775DC3-2265-4E6F-B044-05A7BE06FAC8 dev.julian.irisgaze data
  -> Documents/calib-*.jsonl

uv run --python 3.12 replay.py [file.jsonl ...]     # default: newest recording in the simulator app
uv run --python 3.12 replay.py --synth out.jsonl    # write a synthetic session (for testing this script)

Numpy port of GazeRegression.swift: standardize by the calibration-median spread with floors (0.03 rad head,
0.01 otherwise), weighted ridge, lambda by leave-one-cell-out CV. Calibration medians are recomputed from the
recorded "sample" frames; models are scored on the "validate" frames (never used for fitting).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np

LAMBDAS = (0.1, 0.3, 1.0, 3.0, 10.0)
DUO = "AD775DC3-2265-4E6F-B044-05A7BE06FAC8"


def terms(spec: str, z: np.ndarray) -> np.ndarray:
    """z: (n, d) standardized features. Same terms as GazeModelSpec.terms."""
    one = np.ones((len(z), 1))
    if z.shape[1] < 4:
        return np.hstack([one, z[:, :2]])
    ex, ey, yaw, pitch = (z[:, i:i + 1] for i in range(4))
    if spec == "linear":
        return np.hstack([one, ex, ey, yaw, pitch, ex * yaw, ey * pitch])
    if spec == "quadratic":
        return np.hstack([one, ex, ey, yaw, pitch, ex * yaw, ey * pitch, ex * ex, ey * ey, ex * ey, yaw * yaw,
                          pitch * pitch])
    if spec == "perEye":
        if z.shape[1] < 9:
            return terms("linear", z)
        return np.hstack([one, z[:, 5:9], yaw, pitch, ex * yaw, ey * pitch])
    if spec == "headOnly":
        return np.hstack([one, yaw, pitch, yaw * pitch])
    if spec == "eyesOnly":
        return np.hstack([one, ex, ey, ex * ey])
    raise ValueError(spec)


def floors(d: int) -> np.ndarray:
    return np.array([0.03 if d >= 4 and 2 <= j <= 4 else 0.01 for j in range(d)])


def fit(F: np.ndarray, T: np.ndarray, spec: str, lam: float, w: np.ndarray | None = None):
    mu = F.mean(axis=0)
    sd = np.maximum(F.std(axis=0), floors(F.shape[1]))
    X = terms(spec, (F - mu) / sd)
    W = np.ones(len(F)) if w is None else w
    A = X.T @ (X * W[:, None])
    reg = lam * np.eye(X.shape[1])
    reg[0, 0] = 0
    B = np.linalg.solve(A + reg, X.T @ (T * W[:, None]))
    return mu, sd, B, spec


def predict(model, F: np.ndarray) -> np.ndarray:
    mu, sd, B, spec = model
    return terms(spec, (F - mu) / sd) @ B


def loco(F, T, G, spec, size) -> tuple[float, float]:
    """Best (lambda, error px) by leave-one-cell-out."""
    best = (LAMBDAS[0], float("inf"))
    for lam in LAMBDAS:
        errs = []
        for g in np.unique(G):
            tr, te = G != g, G == g
            try:
                m = fit(F[tr], T[tr], spec, lam)
            except np.linalg.LinAlgError:
                errs = []
                break
            errs.extend(np.linalg.norm((predict(m, F[te]) - T[te]) * size, axis=1))
        if errs and np.mean(errs) < best[1]:
            best = (lam, float(np.mean(errs)))
    return best


def zone_of(P: np.ndarray, cells: np.ndarray) -> np.ndarray:
    """Cell containing each point, else nearest centre (like GridLayout.zone)."""
    centers = cells[:, :2] + cells[:, 2:] / 2
    out = np.empty(len(P), dtype=int)
    for i, p in enumerate(P):
        inside = np.where((cells[:, 0] <= p[0]) & (p[0] <= cells[:, 0] + cells[:, 2]) &
                          (cells[:, 1] <= p[1]) & (p[1] <= cells[:, 1] + cells[:, 3]))[0]
        out[i] = inside[0] if len(inside) else int(np.argmin(np.linalg.norm(centers - p, axis=1)))
    return out


def load(path: Path):
    session, frames = None, []
    for line in path.read_text().splitlines():
        rec = json.loads(line)
        if rec["type"] == "session":
            session = rec
        elif rec["type"] == "frame" and rec.get("f") and rec.get("face") and not rec.get("blink"):
            frames.append(rec)
    if session is None:
        raise SystemExit(f"{path}: no session header")
    return session, frames


def evaluate(path: Path) -> None:
    session, frames = load(path)
    size = np.array(session["size"], dtype=float)
    cells = np.array(session["cells"], dtype=float)
    centers = cells[:, :2] + cells[:, 2:] / 2

    # calibration medians per (pass, cell) from the "sample" frames
    groups: dict[tuple[int, int], list] = {}
    for fr in frames:
        if fr["phase"] == "sample":
            groups.setdefault((fr["pass"], fr["cell"]), []).append(fr["f"])
    dims = {len(v[0]) for v in groups.values()}
    if not groups or len(dims) != 1:
        raise SystemExit(f"{path}: no calibration samples")
    keys = sorted(groups)
    F = np.array([np.median(np.array(groups[k]), axis=0) for k in keys])
    G = np.array([k[1] for k in keys])
    T = centers[G]

    val = [fr for fr in frames if fr["phase"] == "validate" and len(fr["f"]) == F.shape[1]]
    Fv = np.array([fr["f"] for fr in val]) if val else np.zeros((0, F.shape[1]))
    Gv = np.array([fr["cell"] for fr in val], dtype=int)

    print(f"\n{path.name}: backend {session.get('backend')}, {len(keys)} calibration medians "
          f"({len(set(G))} cells), {len(val)} validation frames, feature dim {F.shape[1]}")
    specs = ["linear"] if F.shape[1] < 4 else ["linear", "quadratic", "perEye", "headOnly", "eyesOnly"]
    if F.shape[1] < 9 and "perEye" in specs:
        specs.remove("perEye")
    print(f"{'model':10} {'λ':>5} {'LOCO px':>8} {'val acc':>8} {'val px':>7}   per-cell val acc (0..11)")
    rows = []
    for spec in specs:
        lam, cv = loco(F, T, G, spec, size)
        m = fit(F, T, spec, lam)
        if len(val):
            P = predict(m, Fv)
            acc = float(np.mean(zone_of(P, cells) == Gv))
            px = float(np.mean(np.linalg.norm((P - centers[Gv]) * size, axis=1)))
            per = " ".join(f"{int(100 * np.mean(zone_of(P[Gv == c], cells) == c)):3d}" if np.any(Gv == c) else "  -"
                           for c in range(len(cells)))
        else:
            acc, px, per = float("nan"), float("nan"), "(no validation frames)"
        rows.append((spec, lam, cv, acc, px))
        print(f"{spec:10} {lam:5g} {cv:8.1f} {acc:8.1%} {px:7.1f}   {per}")
    best = max(rows, key=lambda r: (np.nan_to_num(r[3]), -r[2]))
    print(f"best on validation: {best[0]} (λ {best[1]:g}); the app picks by LOCO: "
          f"{min(rows, key=lambda r: r[2])[0]}")


def synth(out: Path, seed: int = 1) -> None:
    """Synthetic 9-D session in the app's format: 1 calibration pass + validation, known map + noise."""
    rng = np.random.default_rng(seed)
    size = [466.0, 678.0]
    gap, cw, ch = 0.02, (1 - 0.07 - 0.06) / 4, (0.45 - 0.07 - 0.04) / 3
    cells = [[0.035 + c * (cw + gap), 0.07 + r * (ch + gap), cw, ch] for r in range(3) for c in range(4)]
    centers = [(x + w / 2, y + h / 2) for x, y, w, h in cells]

    def feats(p):
        dx, dy = p[0] - 0.5, p[1] - 0.25
        yaw, pitch = -0.08 * dx, 0.15 * dy
        lx = 0.55 + 0.06 * dx + 0.04 * dx * dx
        rx = 0.53 + 0.05 * dx
        ly, ry = 0.47 + 0.10 * dy, 0.46 + 0.08 * dy
        f = np.array([(lx + rx) / 2, (ly + ry) / 2, yaw, pitch, 0.0, lx, ly, rx, ry])
        return f + rng.normal(0, [0.006, 0.012, 0.006, 0.008, 0.01, 0.008, 0.014, 0.008, 0.014])

    lines = [{"type": "session", "backend": "synth", "passes": 1, "size": size, "cells": cells}]
    order = [0, 1, 2, 3, 7, 6, 5, 4, 8, 9, 10, 11]
    for k in order:
        for _ in range(45):
            lines.append({"type": "frame", "phase": "sample", "cell": k, "pass": 0, "face": True, "blink": False,
                          "f": feats(centers[k]).round(5).tolist()})
    for k in [5, 10, 3, 8, 1, 6, 11, 0, 9, 2, 7, 4]:
        for _ in range(45):
            lines.append({"type": "frame", "phase": "validate", "cell": k, "pass": -1, "face": True, "blink": False,
                          "f": feats(centers[k]).round(5).tolist()})
    out.write_text("\n".join(json.dumps(x) for x in lines) + "\n")
    print(f"wrote {out}")


def newest_recording() -> list[Path]:
    try:
        data = subprocess.run(["xcrun", "simctl", "get_app_container", DUO, "dev.julian.irisgaze", "data"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []
    files = sorted(glob.glob(os.path.join(data, "Documents", "calib-*.jsonl")), key=os.path.getmtime)
    return [Path(files[-1])] if files else []


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*", type=Path)
    ap.add_argument("--synth", type=Path, help="write a synthetic session to this path and evaluate it")
    args = ap.parse_args()
    if args.synth:
        synth(args.synth)
        args.files.append(args.synth)
    files = args.files or newest_recording()
    if not files:
        sys.exit("no recording found (calibrate in the app first, or pass --synth out.jsonl)")
    for f in files:
        evaluate(f)


if __name__ == "__main__":
    main()
