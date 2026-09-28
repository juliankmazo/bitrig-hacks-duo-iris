#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["numpy>=1.26,<2"]
# ///
"""Offline tuning for the Iris tracker: replay logged calibration / zone-test frames through candidate models.

    uv run --python 3.12 tracker/tune.py                    # latest calibration session + its zone tests
    uv run --python 3.12 tracker/tune.py --list             # sessions / test runs on disk
    uv run --python 3.12 tracker/tune.py --session 20260926-140512 --recompute --settle 0.6
    uv run --python 3.12 tracker/tune.py --synthetic        # self-test on generated data (no recordings needed)

Reports, per candidate model (see calib.py): best ridge lambda, leave-one-calibration-point-out error
(normalized screen units) and zone accuracy, the head-tolerance error ("head err": fit on the still frames,
predict the head-moving frames; old recordings: fit without the sweep, predict it), and,
when test_samples.jsonl has frames for this calibration, the zone-test score replayed through the live
pipeline (median-3 + One Euro + hysteresis), scored like the UI (last 1.5 s of each 2 s target).

--recompute rebuilds every feature from the logged raw landmarks/blendshapes/matrix with the current
gaze.py, so feature changes can be evaluated on old recordings.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from gaze import ALL_NAMES, IDX, N_ALL, GazeEstimator, extract_all, landmarks_from_key  # noqa: E402
from calib import AUTO_CANDIDATES, DEFAULT_LAMBDAS, SPECS, fit_one, lopo, sample_weights, zones_of  # noqa: E402


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def features_of(rec: dict, recompute: bool) -> np.ndarray | None:
    if recompute and rec.get("lm") is not None:
        bs = rec.get("bs") or {}
        M = None if rec.get("M") is None else np.array(rec["M"], dtype=np.float64).reshape(4, 4)
        size = tuple(rec.get("size") or (1280, 720))
        return extract_all(landmarks_from_key(rec["lm"], size), bs, M, size)
    f = rec.get("feats")
    if f is None or len(f) != N_ALL:
        return None
    return np.array(f, dtype=np.float64)


def cal_arrays(recs: list[dict], recompute: bool, settle: float | None, blink_thr: float = 0.5):
    F, T, G, S = [], [], [], []
    for r in recs:
        if settle is None:
            if not r.get("used"):
                continue
        else:
            bs = r.get("bs") or {}
            closed = bs.get("eyeBlinkLeft", 0) > blink_thr and bs.get("eyeBlinkRight", 0) > blink_thr
            if r.get("since", 0) < settle or closed:
                continue
        f = features_of(r, recompute)
        if f is None:
            continue
        F.append(f); T.append((r["tx"], r["ty"])); G.append(r["point"]); S.append(r.get("stage", "point"))
    return np.array(F), np.array(T), np.array(G), np.array(S)


# ---------------------------------------------------------------------------
# Live-pipeline replay of the zone test
# ---------------------------------------------------------------------------
class _FixedModel:
    """Adapter so GazeEstimator can run a calib.Fitted model."""

    def __init__(self, fitted, cols, rows, n_points):
        self.fitted, self.cols, self.rows, self.n_points = fitted, cols, rows, n_points
        self.ready = True

    def predict(self, feats):
        p = self.fitted.predict(feats[None, :])
        return float(p[0, 0]), float(p[0, 1])


def replay_test(frames: list[dict], fitted, args, recompute: bool, n_points: int) -> dict:
    """frames: one test run, time ordered. Returns {"overall", "per_zone", "pred"} scored like the UI;
    pred = expected zone -> list of predicted zones on the scored frames."""
    est = GazeEstimator(_FixedModel(fitted, args.cols, args.rows, n_points), min_cutoff=args.min_cutoff,
                        beta=args.beta, hyst_frames=args.hyst_frames, hyst_margin=args.dead_band)
    hits: dict[int, list[int]] = defaultdict(list)
    pred: dict[int, list[int]] = defaultdict(list)
    for r in frames:
        f = features_of(r, recompute)
        bs = r.get("bs") or {}
        s = est.update(f, bs.get("eyeBlinkLeft", 0.0), bs.get("eyeBlinkRight", 0.0), r["t"])
        if r["since"] >= args.hold - args.window:
            zone = s.zone if (s.face and s.calibrated) else -1
            hits[r["zone"]].append(int(zone == r["zone"]))
            pred[r["zone"]].append(zone)
    per = {z: float(np.mean(v)) for z, v in hits.items() if v}
    return {"overall": float(np.mean(list(per.values()))) if per else float("nan"), "per_zone": per, "pred": pred}


def live_score(frames: list[dict], args) -> dict:
    hits: dict[int, list[int]] = defaultdict(list)
    pred: dict[int, list[int]] = defaultdict(list)
    for r in frames:
        if r["since"] >= args.hold - args.window:
            hits[r["zone"]].append(int(r["live"]["zone"] == r["zone"]))
            pred[r["zone"]].append(r["live"]["zone"])
    per = {z: float(np.mean(v)) for z, v in hits.items() if v}
    return {"overall": float(np.mean(list(per.values()))) if per else float("nan"), "per_zone": per, "pred": pred}


def confusion(pred: dict[int, list[int]], cols: int, rows: int) -> str:
    """expected zone -> most common predicted zone (share), plus the runner-up when it matters."""
    out = []
    for z in range(cols * rows):
        v = pred.get(z)
        if not v:
            continue
        vals, counts = np.unique(np.array(v), return_counts=True)
        order = np.argsort(-counts)
        top = f"{int(vals[order[0]]):>2} ({counts[order[0]] / len(v) * 100:3.0f}%)"
        mark = "  ok" if vals[order[0]] == z else "  MISS"
        second = ""
        if len(order) > 1 and counts[order[1]] / len(v) >= 0.15:
            second = f", then {int(vals[order[1]])} ({counts[order[1]] / len(v) * 100:.0f}%)"
        out.append(f"      {z:>2} -> {top}{second}{mark}")
    return "\n".join(out)


def grid(per: dict, cols: int, rows: int) -> str:
    lines = []
    for r in range(rows):
        cells = []
        for c in range(cols):
            v = per.get(r * cols + c)
            cells.append("  -- " if v is None else f"{v * 100:4.0f}%")
        lines.append("      " + " ".join(cells))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Synthetic recordings (self-test)
# ---------------------------------------------------------------------------
def synthesize(out: Path, hold: bool, seed: int = 0, cols: int = 4, rows: int = 3) -> tuple[Path, Path]:
    """Toy physics: gaze angle = head angle + eye-in-head angle. The v1 2D iris ratios pick up a spurious
    term from head rotation (the iris sits in front of the eye corners), the v2 canonical ones don't.
    Test frames use a shifted head pose (the user moved after calibrating)."""
    rng = np.random.default_rng(seed)
    out.mkdir(parents=True, exist_ok=True)
    cal_p, test_p = out / "cal_samples.jsonl", out / "test_samples.jsonl"
    fov_x, fov_y = 0.40, 0.26                     # screen extent in radians at the user's distance

    def frame(tx, ty, yaw, pitch):
        gx, gy = (tx - 0.5) * fov_x, (0.5 - ty) * fov_y
        nose_x = 0.5 - 0.35 * yaw + rng.normal(0, 0.002)
        nose_y = 0.55 - 0.35 * pitch + rng.normal(0, 0.002)
        # head translation also changes the eye angle needed to hit the target
        ex = gx - yaw + 0.25 * (nose_x - 0.5)
        ey = gy - pitch + 0.25 * (nose_y - 0.55)
        f = np.zeros(N_ALL)
        n = lambda s: rng.normal(0, s)  # noqa: E731
        f[IDX["iris_h_l"]] = 0.5 + 0.9 * ex + 0.35 * yaw + n(0.012)
        f[IDX["iris_h_r"]] = 0.5 + 0.9 * ex + 0.35 * yaw + n(0.012)
        f[IDX["iris_v_l"]] = 0.5 - 0.8 * ey - 0.4 * pitch + n(0.02)
        f[IDX["iris_v_r"]] = 0.5 - 0.8 * ey - 0.4 * pitch + n(0.02)
        f[IDX["iris_off_l"]] = f[IDX["iris_off_r"]] = 0.3 * ey + 0.2 * pitch + n(0.01)
        f[IDX["aperture_l"]] = f[IDX["aperture_r"]] = 0.3 + 0.3 * ey + n(0.01)
        for k, v in (("eyeLookOutLeft", ex), ("eyeLookInRight", ex), ("eyeLookInLeft", -ex), ("eyeLookOutRight", -ex),
                     ("eyeLookUpLeft", ey), ("eyeLookUpRight", ey), ("eyeLookDownLeft", -ey), ("eyeLookDownRight", -ey)):
            f[IDX[k]] = max(0.0, 2.5 * v + n(0.03))
        f[IDX["yaw"]], f[IDX["pitch"]], f[IDX["roll"]] = yaw + n(0.004), pitch + n(0.004), n(0.004)
        f[IDX["nose_x"]], f[IDX["nose_y"]], f[IDX["head_z"]] = nose_x, nose_y, -0.5 + n(0.003)
        for s in ("l", "r"):
            f[IDX[f"c_eh_{s}"]] = 0.9 * ex + n(0.012)
            f[IDX[f"c_ev_{s}"]] = 0.8 * ey + n(0.02)
            f[IDX[f"c_lid_{s}"]] = 0.5 * ey + n(0.02)
            f[IDX[f"c_ap_{s}"]] = 0.3 + 0.3 * ey + n(0.01)
        f[IDX["eye_h"]] = (f[IDX["c_eh_l"]] + f[IDX["c_eh_r"]]) / 2
        f[IDX["eye_v"]] = (f[IDX["c_ev_l"]] + f[IDX["c_ev_r"]]) / 2
        f[IDX["lid_v"]] = (f[IDX["c_lid_l"]] + f[IDX["c_lid_r"]]) / 2
        f[IDX["bs_h"]] = (f[IDX["eyeLookOutLeft"]] + f[IDX["eyeLookInRight"]] - f[IDX["eyeLookInLeft"]] - f[IDX["eyeLookOutRight"]]) / 2
        f[IDX["bs_v"]] = (f[IDX["eyeLookUpLeft"]] + f[IDX["eyeLookUpRight"]] - f[IDX["eyeLookDownLeft"]] - f[IDX["eyeLookDownRight"]]) / 2
        f[IDX["face_w"]] = 0.25 + n(0.002)
        return {"feats": [round(float(v), 6) for v in f], "lm": None, "M": None,
                "bs": {"eyeBlinkLeft": 0.1, "eyeBlinkRight": 0.1}, "size": [1280, 720]}

    session = "synthetic-hold" if hold else "synthetic-move"
    t = 1000.0
    head_amp = 0.004 if hold else 0.06
    with cal_p.open("w") as fc:
        fc.write(json.dumps({"kind": "session", "session": session, "names": ALL_NAMES}) + "\n")
        targets = [(((z % cols) + .5) / cols, ((z // cols) + .5) / rows, "point") for z in range(cols * rows)]

        for p, (tx, ty, stage) in enumerate(targets):
            n = 24 if hold else (120 if stage == "sweep" else 81)
            ph = rng.uniform(0, 6.3)
            for k in range(n + 12):
                since = k / 30
                used_k = k - 12
                if hold:
                    fstage, amp = "point", head_amp
                elif stage == "sweep":
                    fstage, amp = "sweep", 0.12
                else:  # two-phase dot: 36 still frames then 45 moving
                    fstage = "still" if used_k < 36 else "move"
                    amp = 0.004 if fstage == "still" else head_amp
                yaw = amp * np.sin(2 * np.pi * 0.5 * since + ph)
                pitch = amp * 0.7 * np.sin(2 * np.pi * 0.37 * since + 2 * ph)
                rec = {"kind": "cal", "session": session, "t": t, "point": p, "stage": fstage, "tx": tx, "ty": ty,
                       "zone": min(cols - 1, int(tx * cols)) + cols * min(rows - 1, int(ty * rows)),
                       "since": since, "used": k >= 12, **frame(tx, ty, yaw, pitch)}
                fc.write(json.dumps(rec) + "\n")
                t += 1 / 30
    with test_p.open("w") as ft:
        for i, z in enumerate(rng.permutation(cols * rows)):
            tx, ty = ((z % cols) + .5) / cols, ((z // cols) + .5) / rows
            for k in range(60):
                since = k / 30
                # the user has settled into a slightly different pose and keeps moving a little
                yaw = 0.07 + 0.03 * np.sin(t)
                pitch = -0.05 + 0.02 * np.cos(0.7 * t)
                # the eyes need ~0.3 s to reach the new target
                sx = tx if since > 0.3 else 0.5
                sy = ty if since > 0.3 else 0.5
                rec = {"kind": "test", "run": "synthetic", "cal_session": session, "i": i, "t": t, "zone": int(z),
                       "since": since, "live": {"zone": -1}, **frame(sx, sy, yaw, pitch)}
                ft.write(json.dumps(rec) + "\n")
                t += 1 / 30
    return cal_p, test_p


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cal", type=Path, default=HERE / "cal_samples.jsonl")
    ap.add_argument("--test", type=Path, default=HERE / "test_samples.jsonl")
    ap.add_argument("--session", help="calibration session id (default: latest with >= 4 points)")
    ap.add_argument("--list", action="store_true", help="list sessions and test runs")
    ap.add_argument("--models", default=",".join(AUTO_CANDIDATES), help=f"comma list from {', '.join(SPECS)}")
    ap.add_argument("--lambdas", default=",".join(f"{v:g}" for v in DEFAULT_LAMBDAS))
    ap.add_argument("--recompute", action="store_true", help="recompute features from raw landmarks")
    ap.add_argument("--settle", type=float, default=None,
                    help="use frames with since >= SETTLE (default: the frames the server used)")
    ap.add_argument("--no-sweep", action="store_true", help="drop the head-sweep frames from training")
    ap.add_argument("--no-move", action="store_true", help="drop the phase-B (head moving) frames from training")
    ap.add_argument("--move-weight", "--sweep-weight", dest="move_weight", type=float, default=1.0,
                    help="fit weight of head-motion frames (move/sweep) relative to still frames")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--rows", type=int, default=3)
    ap.add_argument("--min-cutoff", type=float, default=1.0)
    ap.add_argument("--beta", type=float, default=8.0)
    ap.add_argument("--hyst-frames", type=int, default=3)
    ap.add_argument("--dead-band", type=float, default=0.1)
    ap.add_argument("--hold", type=float, default=2.0, help="zone-test target duration (s)")
    ap.add_argument("--window", type=float, default=1.5, help="scored tail of each target (s)")
    ap.add_argument("--synthetic", action="store_true", help="generate toy recordings and tune on them")
    ap.add_argument("--synthetic-hold", action="store_true", help="synthetic still-head calibration (old flow)")
    args = ap.parse_args()

    if args.synthetic or args.synthetic_hold:
        import tempfile
        d = Path(tempfile.mkdtemp(prefix="iris-synth-"))
        args.cal, args.test = synthesize(d, hold=args.synthetic_hold)
        print(f"synthetic recordings in {d}")

    cal_recs = read_jsonl(args.cal)
    test_recs = read_jsonl(args.test)
    by_session: dict[str, list[dict]] = defaultdict(list)
    for r in cal_recs:
        if r.get("kind") == "cal":
            by_session[r["session"]].append(r)
    runs: dict[str, list[dict]] = defaultdict(list)
    for r in test_recs:
        if r.get("kind") == "test":
            runs[r["run"]].append(r)

    if args.list or not by_session:
        print(f"{args.cal}: {len(by_session)} calibration session(s)")
        for s, rs in by_session.items():
            pts = len({r["point"] for r in rs})
            stages = sorted({r.get("stage", "point") for r in rs})
            print(f"  {s}: {len(rs)} frames, {pts} points, stages {stages}, hold={rs[0].get('hold')}")
        print(f"{args.test}: {len(runs)} test run(s)")
        for run, rs in runs.items():
            print(f"  {run}: {len(rs)} frames, cal_session {rs[0].get('cal_session')}")
        if not by_session:
            print("no calibration frames yet: calibrate in the UI (space) with the server running, or use --synthetic")
        return

    full = [k for k, v in by_session.items() if len({r["point"] for r in v}) >= 4]
    session = args.session or (full or list(by_session))[-1]
    recs = by_session[session]
    F, T, G, S = cal_arrays(recs, args.recompute, args.settle)
    drop = [st for st, flag in (("sweep", args.no_sweep), ("move", args.no_move)) if flag]
    if drop and len(S):
        keep = ~np.isin(S, drop)
        F, T, G, S = F[keep], T[keep], G[keep], S[keep]
    weights = sample_weights(S, args.move_weight)
    if len(F) < 6:
        sys.exit(f"session {session}: only {len(F)} usable frames")
    n_points = len({(round(x, 3), round(y, 3)) for (x, y), s in zip(T, S) if s != "sweep"})
    quad_on = n_points >= 7
    lams = [float(v) for v in args.lambdas.split(",")]
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    session_runs = {k: v for k, v in runs.items() if v[0].get("cal_session") == session}

    stage_counts = ", ".join(f"{k} {int((S == k).sum())}" for k in dict.fromkeys(S.tolist()))
    print(f"session {session}: {len(F)} frames, {n_points} points ({stage_counts}), move weight {args.move_weight:g}, "
          f"features {'recomputed' if args.recompute else 'as logged'}, settle {args.settle or 'server'}")
    print(f"test runs for this session: {len(session_runs)}"
          + "".join(f"\n  {k}: live score {live_score(sorted(v, key=lambda r: r['t']), args)['overall'] * 100:.0f}%"
                    for k, v in session_runs.items() if any(r.get("live", {}).get("zone", -1) >= 0 for r in v)))
    print()
    print(f"{'model':9} {'λ':>5} {'LOPO err':>9} {'LOPO acc':>9} {'head err':>10} {'test acc':>9}")
    results = []
    for name in models:
        spec = SPECS[name]
        res = lopo(F, T, G, S, spec, lams, quad_on, args.cols, args.rows, weights)
        if not res:
            print(f"{name:9} (not enough points for LOPO)")
            continue
        lam = min(res, key=lambda k: res[k]["err"])
        r = res[lam]
        fitted = fit_one(F, T, spec, lam, quad_on, weights)
        tests = [replay_test(sorted(v, key=lambda x: x["t"]), fitted, args, args.recompute, n_points)
                 for v in session_runs.values()]
        test_acc = float(np.mean([t["overall"] for t in tests])) if tests else None
        sw = "" if r["sweep_err"] is None else f"{r['sweep_err']:.3f}"
        ta = "" if test_acc is None else f"{test_acc * 100:.0f}%"
        print(f"{name:9} {lam:5g} {r['err']:9.3f} {r['acc'] * 100:8.0f}% {sw:>10} {ta:>9}")
        results.append((name, lam, r, tests, test_acc))

    if not results:
        return
    key = (lambda x: -x[4]) if all(x[4] is not None for x in results) else (lambda x: x[2]["err"])
    best = min(results, key=key)
    print(f"\nbest: {best[0]} (λ {best[1]:g}) by {'zone-test accuracy' if best[4] is not None else 'LOPO error'}")
    print("  LOPO zone accuracy per held-out calibration point (grid = cell centres):")
    per_zone = {}
    for g, (e, a) in best[2]["per_group"].items():
        m = G == g
        x, y = T[m][0]
        if S[m][0] != "sweep":
            per_zone[int(zones_of(np.array([[x, y]]), args.cols, args.rows)[0])] = a
    print(grid(per_zone, args.cols, args.rows))
    for t in best[3]:
        print("  zone test replay:")
        print(grid(t["per_zone"], args.cols, args.rows))
        print("  where the test frames went (expected -> most common predicted):")
        print(confusion(t["pred"], args.cols, args.rows))
    for k, v in session_runs.items():
        live = live_score(sorted(v, key=lambda r: r["t"]), args)
        if any(z >= 0 for zs in live["pred"].values() for z in zs):
            print(f"  live run {k} (what the user saw, {live['overall'] * 100:.0f}%):")
            print(confusion(live["pred"], args.cols, args.rows))
    print(f"\nrun the server with it:  uv run --python 3.12 tracker/server.py --model {best[0]} --ridge {best[1]:g}")


if __name__ == "__main__":
    main()
