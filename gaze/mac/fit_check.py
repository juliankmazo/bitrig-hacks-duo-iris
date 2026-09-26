"""Numerical self-test of the first (linear, fixed-lambda) calibration regression.
The current app model (spec + lambda chosen by leave-one-cell-out, head floors) is ported in replay.py.

uv run --python 3.12 fit_check.py

Synthetic features come from a known map (screen point -> eye/head features) plus noise, with the
ranges observed on Julian's webcam. We calibrate on 12 cell medians, then classify fresh noisy frames.
"""

from __future__ import annotations

import numpy as np

COLS, ROWS = 4, 3
LAMBDA = 0.1
rng = np.random.default_rng(7)

# Laptop-pose grid (normalized in the view): top half, 12 cells.
GAP = 0.02
cell_w = (1 - 2 * 0.035 - GAP * (COLS - 1)) / COLS
cell_h = (0.47 - 0.07 - GAP * (ROWS - 1)) / ROWS
cells = [(0.035 + c * (cell_w + GAP), 0.07 + r * (cell_h + GAP), cell_w, cell_h) for r in range(ROWS) for c in range(COLS)]
centers = np.array([(x + w / 2, y + h / 2) for x, y, w, h in cells])


def zone_of(p: np.ndarray) -> int:
    for i, (x, y, w, h) in enumerate(cells):
        if x <= p[0] <= x + w and y <= p[1] <= y + h:
            return i
    return int(np.argmin(np.linalg.norm(centers - p, axis=1)))


def design(z: np.ndarray) -> np.ndarray:
    """z: (n, d) standardized. Same terms as the app."""
    one = np.ones((len(z), 1))
    if z.shape[1] >= 4:
        ex, ey, yaw, pitch = z[:, 0:1], z[:, 1:2], z[:, 2:3], z[:, 3:4]
        return np.hstack([one, ex, ey, yaw, pitch, ex * yaw, ey * pitch])
    return np.hstack([one, z[:, :2]])


def fit(medians: np.ndarray, targets: np.ndarray):
    mu = medians.mean(axis=0)
    sd = medians.std(axis=0)
    sd[sd < 1e-6] = 1.0
    X = design((medians - mu) / sd)
    lam = LAMBDA * np.eye(X.shape[1])
    lam[0, 0] = 0
    W = np.linalg.solve(X.T @ X + lam, X.T @ targets)
    return mu, sd, W


def predict(model, f: np.ndarray) -> np.ndarray:
    mu, sd, W = model
    return design(((f - mu) / sd)[None, :])[0] @ W


def features(p: np.ndarray, eye_gain_y: float, head_share: float) -> np.ndarray:
    """Known map, ranges like the observed ones: eye_x 0.49-0.61, eye_y 0.38-0.59, yaw +-0.1, pitch +-0.2."""
    dx, dy = p[0] - 0.5, p[1] - 0.5
    ex = 0.55 + 0.10 * (1 - head_share) * dx + 0.01 * dx * dy
    ey = 0.47 + eye_gain_y * (1 - head_share) * dy
    yaw = -0.20 * head_share * dx
    pitch = 0.30 * head_share * dy
    return np.array([ex, ey, yaw, pitch, 0.0])


NOISE = np.array([0.006, 0.012, 0.006, 0.008, 0.01])  # per-frame sd, ~ what the 5-frame median leaves


def run(name: str, eye_gain_y: float, head_share: float, noise_mult: float = 1.0) -> None:
    noise = NOISE * noise_mult
    meds = np.array([np.median([features(c, eye_gain_y, head_share) + rng.normal(0, noise)
                                for _ in range(30)], axis=0) for c in centers])
    model = fit(meds, centers)
    train = np.array([predict(model, m) for m in meds])
    err_px = np.linalg.norm((train - centers) * np.array([466, 678]), axis=1).mean()
    train_ok = sum(zone_of(p) == i for i, p in enumerate(train))
    # fresh frames, with the app's EMA 0.3 over 20 frames per cell
    ok = total = 0
    for i, c in enumerate(centers):
        s = None
        for _ in range(20):
            p = predict(model, features(c, eye_gain_y, head_share) + rng.normal(0, noise))
            s = p if s is None else 0.3 * p + 0.7 * s
        ok += zone_of(s) == i
        total += 1
    single = sum(zone_of(predict(model, features(c, eye_gain_y, head_share) + rng.normal(0, noise))) == i
                 for i, c in enumerate(centers) for _ in range(20))
    print(f"{name:42s} cal err {err_px:5.1f} px  train {train_ok}/12  "
          f"smoothed {ok}/{total}  single-frame {single}/{12 * 20}")


if __name__ == "__main__":
    run("eyes + head (head share 0.5)", eye_gain_y=0.2, head_share=0.5)
    run("eyes only, head still", eye_gain_y=0.2, head_share=0.0)
    run("eye_y dead (constant), head carries y", eye_gain_y=0.0, head_share=0.5)
    run("head only (nose pointer)", eye_gain_y=0.2, head_share=1.0)
    run("eyes only, 2x noise", eye_gain_y=0.2, head_share=0.0, noise_mult=2.0)
    # singular: all medians identical -> must not crash (app falls back to nearest centroid)
    try:
        fit(np.tile(np.array([0.5, 0.5, 0, 0, 0]), (12, 1)), centers)
        print("degenerate fit: solved (ridge keeps it non-singular)")
    except np.linalg.LinAlgError:
        print("degenerate fit: singular -> fallback")
