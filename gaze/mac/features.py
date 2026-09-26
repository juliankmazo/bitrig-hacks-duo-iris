"""Gaze features shared by gaze_server.py (live) and replay.py (--recompute from logged raw landmarks).

Ported from the browser tracker (PR #2, tracker/gaze.py): pose-invariant eye features in the canonical face
frame (head_rotation / _eye_canonical / extract_v2) plus head pose and head position (extract_features).
"""

from __future__ import annotations

import math

import numpy as np

# MediaPipe face mesh indices (478 points incl. iris). "Left"/"right" = the subject's own sides.
L_OUTER, L_INNER, L_UPPER, L_LOWER = 33, 133, 159, 145
R_INNER, R_OUTER, R_UPPER, R_LOWER = 362, 263, 386, 374
L_IRIS = (468, 469, 470, 471, 472)
R_IRIS = (473, 474, 475, 476, 477)
NOSE_TIP, FOREHEAD, CHIN, FACE_L, FACE_R = 1, 10, 152, 234, 454
KEY_LANDMARKS = (NOSE_TIP, FOREHEAD, CHIN, FACE_L, FACE_R, L_OUTER, L_INNER, L_UPPER, L_LOWER,
                 R_INNER, R_OUTER, R_UPPER, R_LOWER, *L_IRIS, *R_IRIS)
BLENDSHAPE_KEYS = ("eyeLookInLeft", "eyeLookOutLeft", "eyeLookUpLeft", "eyeLookDownLeft",
                   "eyeLookInRight", "eyeLookOutRight", "eyeLookUpRight", "eyeLookDownRight")

# Must match FeatureLayout.mac in GazeRegression.swift.
F2_NAMES = ("eye_h", "eye_v", "lid_v", "yaw", "pitch", "roll", "nose_x", "nose_y", "head_z", "face_w",
            "bs_h", "bs_v", "c_eh_l", "c_eh_r", "c_ev_l", "c_ev_r", "c_lid_l", "c_lid_r", "c_ap_l", "c_ap_r")

# pixel space (x right, y down, z away from camera) -> MediaPipe camera space (x right, y up, z toward viewer)
_PIX_TO_CAM = np.array([1.0, -1.0, -1.0])


def head_rotation(matrix: np.ndarray | None) -> np.ndarray:
    """Pure rotation part of the facial transformation matrix (canonical face -> camera), via SVD."""
    if matrix is None:
        return np.eye(3)
    u, _, vt = np.linalg.svd(np.asarray(matrix, dtype=np.float64)[:3, :3])
    R = u @ vt
    return np.eye(3) if np.linalg.det(R) < 0 else R


def head_angles(matrix: np.ndarray | None) -> tuple[float, float, float]:
    if matrix is None:
        return 0.0, 0.0, 0.0
    R = np.asarray(matrix)[:3, :3]
    sy = math.sqrt(R[0, 0] ** 2 + R[1, 0] ** 2)
    return math.atan2(-R[2, 0], sy), math.atan2(R[2, 1], R[2, 2]), math.atan2(R[1, 0], R[0, 0])


def _eye_canonical(P3: np.ndarray, R: np.ndarray, iris, a: int, b: int, up: int, lo: int):
    """Iris relative to the eye in the canonical face frame, / eye width (not lid gap).
    a->b are the eye corners left->right in the image. Returns (h, v, lid, aperture):
    h, v: iris offset from the eye-corner midpoint; lid: vertical offset from the eyelid midpoint."""
    def can(v: np.ndarray) -> np.ndarray:        # delta in pixel space -> canonical face frame
        return (v * _PIX_TO_CAM) @ R              # == R^T @ v_cam
    c = P3[list(iris)].mean(axis=0)
    mid = (P3[a] + P3[b]) / 2
    width = float(np.linalg.norm(can(P3[b] - P3[a]))) + 1e-6
    d = can(c - mid)
    lid = can(c - (P3[up] + P3[lo]) / 2)
    return d[0] / width, d[1] / width, lid[1] / width, float(np.linalg.norm(can(P3[up] - P3[lo]))) / width


def extract_f2(P3: np.ndarray, blend: dict[str, float], matrix: np.ndarray | None, size: tuple[int, int]) -> dict:
    """P3: (478, 3) landmarks in pixels (x*w, y*h, z*w). Returns {name: value} for F2_NAMES."""
    w, h = size
    R = head_rotation(matrix)
    lh, lv, llid, lap = _eye_canonical(P3, R, L_IRIS, L_OUTER, L_INNER, L_UPPER, L_LOWER)
    rh, rv, rlid, rap = _eye_canonical(P3, R, R_IRIS, R_INNER, R_OUTER, R_UPPER, R_LOWER)
    g = blend.get
    yaw, pitch, roll = head_angles(matrix)
    return {
        "eye_h": (lh + rh) / 2, "eye_v": (lv + rv) / 2, "lid_v": (llid + rlid) / 2,
        "yaw": yaw, "pitch": pitch, "roll": roll,
        "nose_x": P3[NOSE_TIP, 0] / w, "nose_y": P3[NOSE_TIP, 1] / h,
        "head_z": float(matrix[2, 3]) / 100.0 if matrix is not None else 0.0,
        "face_w": float(np.linalg.norm(P3[FACE_R, :2] - P3[FACE_L, :2])) / w,
        "bs_h": (g("eyeLookOutLeft", 0.0) + g("eyeLookInRight", 0.0) - g("eyeLookInLeft", 0.0) - g("eyeLookOutRight", 0.0)) / 2,
        "bs_v": (g("eyeLookUpLeft", 0.0) + g("eyeLookUpRight", 0.0) - g("eyeLookDownLeft", 0.0) - g("eyeLookDownRight", 0.0)) / 2,
        "c_eh_l": lh, "c_eh_r": rh, "c_ev_l": lv, "c_ev_r": rv,
        "c_lid_l": llid, "c_lid_r": rlid, "c_ap_l": lap, "c_ap_r": rap,
    }


def landmarks_from_key(key_norm, size: tuple[int, int]) -> np.ndarray:
    """Rebuild a (478, 3) pixel array from logged KEY_LANDMARKS (normalized x, y, z; flat or (n, 3))."""
    w, h = size
    P3 = np.zeros((478, 3), dtype=np.float64)
    k = np.asarray(key_norm, dtype=np.float64).reshape(-1, 3)
    P3[list(KEY_LANDMARKS)] = k * np.array([w, h, w])
    return P3


def f2_from_raw(raw: dict) -> dict:
    """Recompute features from a logged raw frame {"key", "m", "bs", "wh"}."""
    w, h = raw["wh"]
    P3 = landmarks_from_key(raw["key"], (w, h))
    m = np.array(raw["m"], dtype=np.float64).reshape(4, 4) if raw.get("m") else None
    blend = dict(zip(BLENDSHAPE_KEYS, raw.get("bs") or []))
    return extract_f2(P3, blend, m, (w, h))
