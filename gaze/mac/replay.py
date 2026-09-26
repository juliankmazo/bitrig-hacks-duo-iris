"""Replay an IrisGaze calibration recording and compare gaze models on its validation frames.

The app writes one JSONL per calibration run to its Documents dir (path shown in the Test overlay):
  xcrun simctl get_app_container AD775DC3-2265-4E6F-B044-05A7BE06FAC8 dev.julian.irisgaze data
  -> Documents/calib-*.jsonl

uv run --python 3.12 replay.py [file.jsonl ...]     # default: newest recording in the simulator app
uv run --python 3.12 replay.py --recompute f.jsonl  # rebuild f2 features from the logged raw landmarks
uv run --python 3.12 replay.py --synth out.jsonl    # write a synthetic session (for testing this script)

Numpy port of GazeRegression.swift: per-axis designs, standardization with head floors, weighted ridge
(move frames 0.5), fit on every calibration frame, lambda by leave-one-target-out CV. Models are scored on
the "validate" frames, which are never used for fitting. Also prints per-column / per-row feature means
(which features can separate columns and rows at all) and a confusion table.
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

LAMBDAS = (0.3, 1.0, 3.0, 10.0, 30.0)
MOVE_WEIGHT = 0.5
DUO = "AD775DC3-2265-4E6F-B044-05A7BE06FAC8"

MAC = ["eye_h", "eye_v", "lid_v", "yaw", "pitch", "roll", "nose_x", "nose_y", "head_z", "face_w",
       "bs_h", "bs_v", "c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r", "c_lid_l", "c_lid_r", "c_ap_l", "c_ap_r"]
MAC_LEGACY = ["eye_h", "eye_v", "yaw", "pitch", "roll", "l_x", "l_y", "r_x", "r_y"]
POINT = ["x", "y"]
FLOORS = {"yaw": 0.03, "pitch": 0.03, "roll": 0.03, "nose_x": 0.01, "nose_y": 0.01, "head_z": 0.01, "face_w": 0.005}


def T(lin, quad=(), inter=()):
    return {"lin": list(lin), "quad": list(quad), "inter": list(inter)}


PHYS_INTER = [("yaw", "eye_h"), ("pitch", "eye_v"), ("pitch", "lid_v"), ("yaw", "eye_v"), ("pitch", "eye_h"),
              ("yaw", "pitch")]
# (name, x terms, y terms) -- same as GazeModelSpec in GazeRegression.swift
SPECS = [
    ("hybrid", T(["eye_h", "c_eh_l", "c_eh_r", "yaw"]), T(["pitch", "nose_y", "head_z", "eye_v"])),
    ("hybrid", T(["eye_h", "l_x", "r_x", "yaw"]), T(["pitch", "eye_v"])),
    ("linear", T(["x", "y"]), None),
    ("linear", T(["eye_h", "eye_v", "yaw", "pitch"], inter=[("yaw", "eye_h"), ("pitch", "eye_v")]), None),
    ("perEye", T(["c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r", "c_lid_l", "c_lid_r", "yaw", "pitch"]), None),
    ("perEye", T(["l_x", "l_y", "r_x", "r_y", "yaw", "pitch"]), None),
    ("headOnly", T(["yaw", "pitch", "roll", "nose_x", "nose_y", "head_z"], quad=["yaw", "pitch"]), None),
    ("headOnly", T(["yaw", "pitch", "roll"], quad=["yaw", "pitch"]), None),
    ("phys", T(["eye_h", "eye_v", "lid_v", "yaw", "pitch", "roll", "nose_x", "nose_y", "head_z"],
               quad=["eye_h", "eye_v", "lid_v"], inter=PHYS_INTER), None),
    ("physBS", T(["eye_h", "eye_v", "lid_v", "bs_h", "bs_v", "yaw", "pitch", "roll", "nose_x", "nose_y", "head_z"],
                 quad=["eye_h", "eye_v", "lid_v"], inter=PHYS_INTER), None),
]


def candidates(names):
    have, seen, out = set(names), set(), []
    for name, tx, ty in SPECS:
        ty = ty or tx
        need = set(tx["lin"] + tx["quad"] + [a for p in tx["inter"] for a in p]) | \
            set(ty["lin"] + ty["quad"] + [a for p in ty["inter"] for a in p])
        if need <= have and name not in seen:
            seen.add(name)
            out.append((name, tx, ty))
    return out


class Design:
    def __init__(self, terms, names, F, quad_on):
        idx = {n: i for i, n in enumerate(names)}
        self.cols = [idx[n] for n in terms["lin"]]
        sub = F[:, self.cols]
        self.mu = sub.mean(axis=0)
        self.sd = np.maximum(sub.std(axis=0) + 1e-6, [FLOORS.get(n, 0.0) for n in terms["lin"]])
        self.q = [terms["lin"].index(n) for n in terms["quad"]]
        self.inter = [(terms["lin"].index(a), terms["lin"].index(b)) for a, b in terms["inter"]]
        self.quad_on = quad_on

    def __call__(self, F):
        Z = (F[:, self.cols] - self.mu) / self.sd
        parts = [np.ones((len(Z), 1)), Z]
        if self.quad_on:
            for a in range(len(self.q)):
                parts.append(Z[:, self.q[a]:self.q[a] + 1] ** 2)
                for b in range(a + 1, len(self.q)):
                    parts.append(Z[:, self.q[a]:self.q[a] + 1] * Z[:, self.q[b]:self.q[b] + 1])
            parts += [Z[:, a:a + 1] * Z[:, b:b + 1] for a, b in self.inter]
        return np.hstack(parts)


def solve(X, y, w, lam):
    A = (X * w[:, None]).T @ X
    P = lam * np.eye(X.shape[1])
    P[0, 0] = 0
    return np.linalg.solve(A + P, (X * w[:, None]).T @ y)


class Model:
    def __init__(self, name, tx, ty, names, F, Tg, w, lam, quad_on):
        self.name, self.lam = name, lam
        self.dx, self.dy = Design(tx, names, F, quad_on), Design(ty, names, F, quad_on)
        self.wx = solve(self.dx(F), Tg[:, 0], w, lam)
        self.wy = solve(self.dy(F), Tg[:, 1], w, lam)

    def predict(self, F):
        return np.stack([self.dx(F) @ self.wx, self.dy(F) @ self.wy], axis=1)


def zone_of(P, cells):
    centers = cells[:, :2] + cells[:, 2:] / 2
    inside = ((cells[None, :, 0] <= P[:, None, 0]) & (P[:, None, 0] <= cells[None, :, 0] + cells[None, :, 2]) &
              (cells[None, :, 1] <= P[:, None, 1]) & (P[:, None, 1] <= cells[None, :, 1] + cells[None, :, 3]))
    nearest = np.argmin(np.linalg.norm(centers[None] - P[:, None], axis=2), axis=1)
    return np.where(inside.any(axis=1), inside.argmax(axis=1), nearest)


def rolling_median(F, n=5):
    return np.array([np.median(F[max(0, i - n + 1):i + 1], axis=0) for i in range(len(F))])


def load(path: Path, recompute: bool):
    session, frames = None, []
    for line in path.read_text().splitlines():
        rec = json.loads(line)
        if rec["type"] == "session":
            session = rec
        elif rec["type"] == "frame" and rec.get("face") and not rec.get("blink") and (rec.get("f") or rec.get("raw")):
            frames.append(rec)
    if session is None:
        raise SystemExit(f"{path}: no session header")
    names = session.get("names")
    if recompute:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from features import F2_NAMES, f2_from_raw
        frames = [fr for fr in frames if fr.get("raw")]
        if not frames:
            raise SystemExit(f"{path}: no raw landmarks logged (recorded before the server sent 'key')")
        F = np.array([[f2_from_raw(fr["raw"])[n] for n in F2_NAMES] for fr in frames])
        F = rolling_median(F)   # the live server applies a 5-frame median
        for fr, f in zip(frames, F):
            fr["f"] = f.tolist()
        names = list(F2_NAMES)
    frames = [fr for fr in frames if fr.get("f")]
    dims = {len(fr["f"]) for fr in frames}
    if len(dims) != 1:
        raise SystemExit(f"{path}: mixed feature dimensions {dims}")
    d = dims.pop()
    if not names or len(names) != d:
        names = MAC if d == len(MAC) else MAC_LEGACY if d == len(MAC_LEGACY) else POINT[:d]
    return session, frames, names


def discriminability(F, cells_of, names, label):
    """Per-column / per-row means of the key features and the within-cell spread."""
    cols, rows = cells_of % 4, cells_of // 4
    show = [n for n in ("eye_h", "eye_v", "lid_v", "c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r", "l_x", "r_x", "l_y",
                        "r_y", "bs_h", "bs_v", "yaw", "pitch", "nose_y", "x", "y") if n in names]
    print(f"  feature discriminability ({label}): column means 0..3 | row means 0..2 | within-cell std | "
          f"step/σ cols, rows")
    for n in show:
        j = names.index(n)
        cm = [F[cols == c, j].mean() for c in range(4) if (cols == c).any()]
        rm = [F[rows == r, j].mean() for r in range(3) if (rows == r).any()]
        wstd = np.mean([F[cells_of == c, j].std() for c in np.unique(cells_of)])
        sc = np.min(np.abs(np.diff(cm))) / max(wstd, 1e-9) if len(cm) > 1 else 0
        sr = np.min(np.abs(np.diff(rm))) / max(wstd, 1e-9) if len(rm) > 1 else 0
        print(f"    {n:7s} cols [{' '.join(f'{v:+.3f}' for v in cm)}] rows [{' '.join(f'{v:+.3f}' for v in rm)}] "
              f"σ {wstd:.4f}  {sc:5.1f} {sr:5.1f}")


def evaluate(path: Path, recompute: bool) -> None:
    session, frames, names = load(path, recompute)
    size = np.array(session["size"], dtype=float)
    cells = np.array(session["cells"], dtype=float)
    centers = cells[:, :2] + cells[:, 2:] / 2
    corners = np.array(session.get("corners_xy") or [], dtype=float).reshape(-1, 2)

    def target(g):
        return centers[g] if g < 12 else corners[g - 12]

    cal = [fr for fr in frames if fr["phase"] in ("sample", "still", "move")]
    val = [fr for fr in frames if fr["phase"] == "validate"]
    if not cal:
        raise SystemExit(f"{path}: no calibration frames")
    F = np.array([fr["f"] for fr in cal])
    G = np.array([fr["cell"] for fr in cal])
    Tg = np.array([target(g) for g in G])
    stage = np.array([fr["phase"] for fr in cal])
    w = np.where(stage == "move", MOVE_WEIGHT, 1.0)
    Fv = np.array([fr["f"] for fr in val]) if val else np.zeros((0, F.shape[1]))
    Gv = np.array([fr["cell"] for fr in val], dtype=int)
    quad_on = len(set(G.tolist())) >= 7

    print(f"\n{path.name}{' (recomputed f2)' if recompute else ''}: backend {session.get('backend')}, "
          f"{len(cal)} calibration frames over {len(set(G.tolist()))} targets "
          f"({(stage == 'still').sum()} still / {(stage == 'move').sum()} move / {(stage == 'sample').sum()} single-phase), "
          f"{len(val)} validation frames, {len(names)} features")
    cm = G < 12
    discriminability(F[cm], G[cm], names, "calibration")
    if len(val):
        discriminability(Fv, Gv, names, "validation")

    print(f"  {'model':9} {'λ':>5} {'LOTO px':>8} {'s→m px':>7} {'val acc':>8} {'val px':>7} {'col acc':>8} {'row acc':>8}"
          f"   per-cell val acc 0..11")
    results = []
    for name, tx, ty in candidates(names):
        best = None
        for lam in LAMBDAS:
            errs = []
            try:
                for g in np.unique(G):
                    tr = G != g
                    m = Model(name, tx, ty, names, F[tr], Tg[tr], w[tr], lam, quad_on)
                    errs.append(np.linalg.norm((m.predict(F[~tr]) - Tg[~tr]) * size, axis=1).mean())
            except np.linalg.LinAlgError:
                continue
            e = float(np.mean(errs))
            s2m = None
            if (stage == "move").any() and (stage == "still").sum() > 10:
                st = stage == "still"
                m = Model(name, tx, ty, names, F[st], Tg[st], w[st], lam, quad_on)
                s2m = float(np.linalg.norm((m.predict(F[stage == "move"]) - Tg[stage == "move"]) * size, axis=1).mean())
            if best is None or e < best[1]:
                best = (lam, e, s2m)
        if best is None:
            continue
        lam, e, s2m = best
        m = Model(name, tx, ty, names, F, Tg, w, lam, quad_on)
        if len(val):
            P = m.predict(Fv)
            Z = zone_of(P, cells)
            acc = float(np.mean(Z == Gv))
            col_acc, row_acc = float(np.mean(Z % 4 == Gv % 4)), float(np.mean(Z // 4 == Gv // 4))
            px = float(np.mean(np.linalg.norm((P - centers[Gv]) * size, axis=1)))
            per = " ".join(f"{int(100 * np.mean(Z[Gv == c] == c)):3d}" if np.any(Gv == c) else "  -" for c in range(12))
        else:
            acc = col_acc = row_acc = px = float("nan")
            per, Z = "(no validation frames)", None
        results.append((name, lam, e, s2m, acc, px, Z))
        print(f"  {name:9} {lam:5g} {e:8.1f} {(s2m if s2m is not None else float('nan')):7.1f} {acc:8.1%} {px:7.1f} "
              f"{col_acc:8.1%} {row_acc:8.1%}   {per}")
    if not results:
        return
    by_val = max(results, key=lambda r: np.nan_to_num(r[4]))
    by_cv = min(results, key=lambda r: r[2])
    print(f"  best on validation: {by_val[0]} (λ {by_val[1]:g}); lowest LOTO (app with -model auto): {by_cv[0]}; "
          f"app default: hybrid")
    if by_val[6] is not None:
        print(f"  confusion for {by_val[0]} (rows = expected cell, cols = predicted cell, % of frames):")
        print("        " + " ".join(f"{c:4d}" for c in range(12)))
        for c in range(12):
            if not np.any(Gv == c):
                continue
            row = [int(round(100 * np.mean(by_val[6][Gv == c] == p))) for p in range(12)]
            print(f"    {c:2d}  " + " ".join(f"{v:4d}" if v else "   ." for v in row))


def synth(out: Path, seed: int = 1) -> None:
    """Synthetic 20-D session in the app's current format: still + move phases, validation with a still head."""
    rng = np.random.default_rng(seed)
    size = [669.0, 951.0]
    gap, cw, ch = 0.02, (1 - 0.07 - 0.06) / 4, (0.45 - 0.07 - 0.04) / 3
    cells = [[0.035 + c * (cw + gap), 0.07 + r * (ch + gap), cw, ch] for r in range(3) for c in range(4)]
    centers = [(x + w / 2, y + h / 2) for x, y, w, h in cells]

    def feats(p, nod):
        # columns: eyes; rows: head pitch only when nodding (like Julian's data), no vertical eye signal
        dx, dy = p[0] - 0.5, p[1] - 0.25
        f = dict.fromkeys(MAC, 0.0)
        f.update(eye_h=-0.12 * dx, c_eh_l=-0.13 * dx, c_eh_r=-0.11 * dx, yaw=0.02 * dx,
                 pitch=0.06 + (0.25 * dy if nod else 0.0), nose_y=0.5 + (0.05 * dy if nod else 0.0),
                 eye_v=-0.05 * dx, head_z=-0.4)
        noise = {"eye_h": 0.004, "c_eh_l": 0.005, "c_eh_r": 0.005, "pitch": 0.005, "nose_y": 0.002, "eye_v": 0.006,
                 "yaw": 0.004}
        return [f[n] + rng.normal(0, noise.get(n, 0.001)) for n in MAC]

    lines = [{"type": "session", "backend": "synth", "names": MAC, "size": size, "cells": cells}]
    for k in [0, 1, 2, 3, 7, 6, 5, 4, 8, 9, 10, 11]:
        for phase, n in (("still", 36), ("move", 45)):
            for _ in range(n):
                lines.append({"type": "frame", "phase": phase, "cell": k, "pass": 0, "face": True, "blink": False,
                              "f": feats(centers[k], nod=True)})
    for k in [5, 10, 3, 8, 1, 6, 11, 0, 9, 2, 7, 4]:
        for _ in range(45):
            lines.append({"type": "frame", "phase": "validate", "cell": k, "pass": -1, "face": True, "blink": False,
                          "f": feats(centers[k], nod=True)})
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
    ap.add_argument("--recompute", action="store_true", help="rebuild f2 features from logged raw landmarks")
    ap.add_argument("--synth", type=Path, help="write a synthetic session to this path and evaluate it")
    args = ap.parse_args()
    if args.synth:
        synth(args.synth)
        args.files.append(args.synth)
    files = args.files or newest_recording()
    if not files:
        sys.exit("no recording found (calibrate in the app first, or pass --synth out.jsonl)")
    for f in files:
        evaluate(f, args.recompute)


if __name__ == "__main__":
    main()
