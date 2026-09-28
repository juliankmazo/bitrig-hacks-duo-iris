# Webcam gaze tracking for Iris — research (2026-09-26)

Target: gaze zone 0–8 (or a screen point) + deliberate-blink signal at ≥ 20 Hz, low jitter, tolerant of small head motion, ≤ 9-point calibration, fully local on an M3 Max (macOS 26.7, FaceTime HD 1080p30), Python 3.12 + MediaPipe 0.10.21, 4-hour build.

## TL;DR

**Top pick: MediaPipe FaceLandmarker (Tasks API) geometric features → per-user ridge regression → One-Euro filter → 9-zone classifier with hysteresis; blink from `eyeBlink*` blendshapes with a 0.45–1.5 s duration window.** It is the only approach that is (a) already verified on this Mac, (b) measured at 8.8 ms/frame here, (c) backed by 2025–2026 papers showing ~3° still-head / ~6° with head motion after a 9-point calibration, and (d) buildable in about an hour. No deep gaze model beats it for a 9-zone task after calibration; un-calibrated appearance models sit at 10–13° cross-subject error, which cannot separate three rows on a laptop screen.

**Runner-up: add MobileGaze MobileOne-S0 (ONNX, 4.8 MB, measured 1.9 ms on the CoreML EP) pitch/yaw as two extra features into the same ridge model.** Cheap, gives an appearance-based signal that is less coupled to eyelid shape, and makes the debug overlay look impressive (a gaze arrow on the face). Do it only after the top pick works end-to-end.

**Not worth the time:** L2CS-Net (95 MB, non-commercial Gaze360 weights on Google Drive, 10.4° cross-subject), Gaze-LLE (predicts gaze *targets inside a photo*, wrong task), 3DGazeNet / GazeTR / ETH-XGaze baselines (research weights, need camera-normalized inputs), OpenFace 2 (C++ build on macOS), dlib (no iris points), Apple Vision (one pupil point per eye; Swift-only, and the tracker runs in Python on the Mac), WebGazer (8–13° in real deployments), eyeGestures (GPLv3, Python ≥ 3.13 conflicts with MediaPipe 0.10.21).

## Ranked recommendation table

Accuracy numbers are what the literature reports for *calibrated per-user* use unless noted. FPS/latency marked **measured** were run on this M3 Max today (`uv run --python 3.12`, scripts in the scratchpad; 80 timed frames after 10 warm-up).

| # | Approach | Expected accuracy | Latency on M3 Max | Setup time | Risk | Verdict |
|---|---|---|---|---|---|---|
| 1 | **MediaPipe FaceLandmarker 0.10.21 → iris/eyelid/head features → Ridge → One-Euro → 9 zones** | ~2.9° still head, ~5.8° with head motion, 9-point cal (EMC-Gaze 2026, landmark+ridge); ~2.4° RMSE (UnitEye, ridge cal); vertical is the weak axis | **8.8 ms median / 9.3 ms p95 at 1080p, blendshapes on or off (measured), camera-bound at 30 fps** | 45–90 min | Low. Already running on this Mac. Vertical rows may need head-pitch help ("hybrid") | **Build this** |
| 2 | #1 + **MobileGaze MobileOne-S0 ONNX pitch/yaw as extra ridge features** | Same as #1, more robust to eyelid/lighting; standalone (no cal) 12.6° MAE on Gaze360 — useless alone for 9 zones | **1.9 ms CoreML EP / 6.6 ms CPU (measured)** + a 448² face crop from MediaPipe's landmarks | +30 min | Low–medium: crop alignment must match training (RetinaFace-style face box) or angles drift | **Add if time** |
| 3 | **EyeTrax 0.4.0 (`pip install eyetrax`)** — same MediaPipe Tasks + Ridge(α=1) on 150 head-normalized landmarks + yaw/pitch/roll, 9-point cal UI, Kalman/KDE filters, adaptive EAR blink | Untested by authors; underlying method is #1 with a fat 480-dim feature vector (overfits 9 points more than #1's ~15 features) | Same as #1 (it is FaceLandmarker VIDEO mode inside) | 15 min to a demo; longer to bend its full-screen calibration to the sim window | Medium: `numpy<2`, `pyvirtualcam`, `screeninfo` deps; calibration assumes a full screen. Imports fine with `mediapipe==0.10.21` on 3.12 (verified) | Use as reference code / fallback, not as the server |
| 4 | **WebEyeTrack / BlazeGaze** (MIT, Vanderbilt 2025) — 0.16 M-param CNN on homography-warped eye strip + MAML few-shot (k ≤ 9) | 4.56 cm on MPIIFaceGaze (~5° at 50 cm), 2.32 cm GazeCapture (phone); 20 % drift over 20 min | 0.88 ms on an i7 (paper); MacGaze's CoreML port 17 ms + ~170 ms MediaPipe pixel-conversion bottleneck | Hours: Python pkg pins TF 2.11 / Python 3.10, models built by a 2-stage training pipeline; JS pkg is the deployable one | High for 4 h | Skip; good citation for "prior art" |
| 5 | **MediaPipe `eyeLook*` blendshapes only** (8 numbers, no landmark math) | Coarse; left/right reliable, up/down weak (values 0.03–0.36 in my frame at rest) | free (in #1) | 10 min | Medium: blendshapes are a face-rig abstraction, not calibrated gaze | Use as *extra features* in #1, never alone |
| 6 | **Nose/head pointer** (`facial_transformation_matrixes` yaw/pitch → zone) | Excellent stability, no eye info; real AAC devices ship this | free (in #1) | 15 min | Low | Keep as `--mode head` fallback (README already plans it) |
| 7 | **L2CS-Net ResNet-50** | 10.41° Gaze360 / 3.92° MPIIGaze (within-dataset), + ridge cal ≈ #2 | ~5 ms CoreML est., 40+ ms CPU | 45 min + Google Drive weights (95.8 MB, HF mirror exists) | Medium: Gaze360 weights are research/non-commercial, no redistribution | Superseded by #2 |
| 8 | **OpenFace 3.0** (`pip install openface-test`, torch, yaw/pitch) | Multitask model; no published gaze MAE on README | Unknown on macOS | 30–60 min | Medium–high (torch + `openface download`) | Skip |
| 9 | **Apple Vision `VNDetectFaceLandmarksRequest`** (`leftPupil`/`rightPupil`, 76-pt constellation) | One pupil point per eye, no iris contour; fine for left/right | ~5 ms on ANE | Swift only | High (would move the tracker into Swift; sim has no camera) | Skip for Mac-side tracker |
| 10 | **WebGazer.js** | 4–5° headline, 8–11° deployed; 10.3–13.6° in a 2025 systematic eval | 33 ms median in browser | 20 min | High accuracy risk | Skip |
| 11 | **Gaze-LLE, 3DGazeNet, GazeTR, XGaze baselines** | Wrong task (Gaze-LLE) or research weights needing camera-normalized crops | DINOv2-B/L (Gaze-LLE) is heavy | hours | High | Skip |

## Why the geometric MediaPipe pipeline wins here

1. **It is the fastest thing available and it is already free.** Measured on this machine at 1920×1080 input: FaceLandmarker `detect_for_video` = 8.8 ms median, 9.3 ms p95, face found 90/90 frames, wall-clock 30 fps limited by the camera. Enabling blendshapes + the facial transformation matrix cost nothing measurable (8.8 ms both ways). The model bundle is 3.76 MB (`face_landmarker.task`, float16). A 2024 MediaPipe issue reports FaceLandmarker ≈ 2.4× slower than the legacy FaceMesh on an M2 — irrelevant at 9 ms. Metal GPU delegate on macOS is flaky in 0.10.x (aborts / leaks reported); stay on CPU (XNNPACK).
2. **The 2026 literature says landmark + ridge is ~3–6° after a 9-point calibration.** EMC-Gaze ("Deployment-Oriented Session-wise Meta-Calibration for Landmark-Based Webcam Gaze Tracking", arXiv 2603.12388, built on EyeTrax) reports, over 33 interactive sessions with 9-point calibration (45 samples): **2.92 ± 0.75° with the head still, 6.42 ± 1.89° while holding a different head pose, 5.79° overall**; their plain Elastic-Net-on-landmarks baseline is 6.49°. UnitEye (MediaPipe FaceMesh + ridge calibration) reports **~2.5 cm RMSE ≈ 2.4°** at 60 cm on a 24" monitor. The browser benchmark paper (arXiv 2608.11566, 2026) gets 6.5–8° from FaceMesh + kernel ridge vs 11° for WebGazer at N=1.
3. **9 zones need ~5° horizontal and ~4° vertical.** Looking at a MacBook 14" panel (31 × 20 cm) from ~50 cm: columns span ~11° each, rows ~7.5° each. A 3–6° error separates columns comfortably and rows marginally — which is exactly the README's observation ("decent left/right, weak up/down"). The fix is not a bigger model; it is (a) eyelid-aperture features for vertical, (b) head pitch in the feature vector so natural head nods help, and (c) big targets.
4. **Appearance models do not fix vertical.** Their cross-subject error on in-the-wild data is 10–13° (MobileGaze 12.6°/11.3°, L2CS 10.4°); on the easy MPIIGaze split L2CS reaches 3.9° but that is within-dataset. They still need the same per-user ridge calibration to reach 9 zones, so they only earn their place as *additional features*.

### Gotcha: the "screen" is the simulator window

The patient looks at the iPhone Duo **simulator window on the Mac**, not the Mac screen. If that window is 12 cm wide at 50 cm, the whole 3×3 grid spans ~14° × 14° — each cell ~4.5°, at the limit of webcam gaze. Mitigations, in order: run the simulator at 100 %/large scale and put it directly under the webcam; calibrate on the 9 cell centres of the *window* (the README already does this) rather than screen corners; let head motion be part of the signal (hybrid); and treat the centre cell as the rest zone with a dead band. Record the demo with the window as large as the Duo renders.

## Exact assets for the top 3 candidates

**1. MediaPipe FaceLandmarker (top pick)**
- pip: `mediapipe==0.10.21` on Python 3.12 (1.0.x aborts on macOS CPU: "graph_service Service is unavailable"); `opencv-python`, `numpy`, `scikit-learn`, `websockets`.
- Model (3.76 MB): `https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task` (docs: https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker; Python guide: https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/python). Apache-2.0.
- Options: `running_mode=VIDEO`, `num_faces=1`, `output_face_blendshapes=True`, `output_facial_transformation_matrixes=True`. Outputs 478 landmarks (468 mesh + 5 iris per eye: left iris 468–472 with 468 = centre, right iris 473–477 with 473 = centre), 52 blendshapes, 4×4 head matrix.
- Landmark indices used below: left eye outer/inner corners 33/133, right 362/263; left eyelid top/bottom 159/145, right 386/374; nose tip 4; chin 152; forehead 10. (Same indices EyeTrax and the honest-benchmark paper use.)

**2. MobileGaze (runner-up feature source)** — https://github.com/yakhyo/gaze-estimation (MIT)
- `mobileone_s0_gaze.onnx` (4.97 MB, 12.58° Gaze360): `https://github.com/yakhyo/gaze-estimation/releases/download/weights/mobileone_s0_gaze.onnx`
- `resnet18_gaze.onnx` (45 MB, 12.84°): `https://github.com/yakhyo/gaze-estimation/releases/download/weights/resnet18_gaze.onnx`
- Input `[1,3,448,448]` float32, ImageNet-normalized RGB face crop; outputs two `[1,90]` logits (pitch, yaw bins, 4° each, −180..180); decode `angle = sum(softmax(logits) * idx) * 4 − 180` (L2CS formulation). Measured here: S0 **6.6 ms CPU / 1.9 ms CoreML EP**; R18 **41 ms CPU / 1.6 ms CoreML EP** (`pip install onnxruntime`, `providers=["CoreMLExecutionProvider","CPUExecutionProvider"]`). Training crops are RetinaFace boxes (`uniface`); use MediaPipe's face bounding box expanded ~20 % and made square, which is close enough for a feature that ridge re-scales anyway.

**3. EyeTrax (reference implementation / fallback)** — https://github.com/ck-zhang/EyeTrax, `pip install eyetrax` (0.4.0, MIT)
- Deps: `mediapipe>=0.10`, `numpy<2`, `opencv-python`, `scikit-learn`, `scipy`, `pyvirtualcam`, `screeninfo`. Verified `uv run --python 3.12 --with eyetrax --with mediapipe==0.10.21` imports and constructs `GazeEstimator` on this Mac.
- Internals (read from source): FaceLandmarker VIDEO mode; builds a head frame from corners 33/263 and top-of-head 10, rotates all points into it and divides by inter-corner distance; features = 150 eye-region + 9 anchor landmarks × 3 + (yaw, pitch, roll) → `sklearn.linear_model.Ridge(alpha=1.0)`; blink = EAR < 0.8 × rolling-mean EAR over 50 frames (0.2 until 15 frames of history). Filters: Kalman, Kalman+EMA (α 0.25), KDE. Calibration: 9-point, 5-point, Lissajous, dense grid.
- Related: `gazecontrol` (PyPI) ensembles L2CS-Net + EyeTrax with Kalman, EAR blink and PnP head pose — a heavier version of #2.

Others with URLs, for the record: L2CS-Net https://github.com/Ahmednull/L2CS-Net (weights: Google Drive folder in README; HF mirror `https://huggingface.co/dorni/SpeakerVid-5M-data-curation-models/blob/main/L2CSNet_gaze360.pkl`, 95.8 MB; Gaze360 licence is non-commercial). WebEyeTrack https://github.com/RedForestAi/WebEyeTrack (paper https://arxiv.org/abs/2508.19544). MacGaze https://github.com/AACTools/MacGaze (Swift, BlazeGaze CoreML 725 KB @ 17 ms, 4-point RBF, "8.1 % mean error", MediaPipe path ~170 ms/frame). Gaze-LLE https://github.com/fkryan/gazelle. 3DGazeNet https://github.com/Vagver/3DGazeNet. GazeTR https://github.com/yihuacheng/GazeTR. OpenFace 3.0 https://github.com/CMU-MultiComp-Lab/OpenFace-3.0. OpenFace 2 macOS build wiki https://github.com/TadasBaltrusaitis/OpenFace/wiki/Mac-installation. WebGazer https://webgazer.cs.brown.edu/.

## The algorithm: raw landmarks → smoothed zone

All coordinates are MediaPipe normalized image coords (x,y in [0,1], z relative). Work per frame; every step is O(1).

### 1. Per-frame feature vector (~19 numbers)

For each eye e ∈ {L, R}, with corners `o` (outer), `i` (inner), iris centre `c` (468 / 473), eyelid top `t`, bottom `b`:

```
w      = |i - o|                              # inter-corner width (head distance proxy)
mid    = (i + o) / 2
u_axis = (i - o) / w                          # eye axis (handles roll)
v_axis = perp(u_axis)
hx     = dot(c - mid, u_axis) / w             # horizontal iris offset, roll-invariant
hy     = dot(c - mid, v_axis) / w             # vertical iris offset (weak: eyelids)
lid    = dot(c - (t + b)/2, v_axis) / w       # iris vs eyelid-aperture centre — the best cheap vertical cue
open   = |t - b| / w                          # aperture (EAR-like); also drives blink
```

Head: from `facial_transformation_matrixes[0]` take yaw, pitch, roll (decompose the 3×3 rotation), plus nose tip 4 normalized to the frame (nx, ny) and face scale = |454 − 234| (head distance). Optional extras: the 8 `eyeLook{In,Out,Up,Down}{Left,Right}` blendshape scores. Do **not** use `UIScreen`-style pixel coordinates anywhere; everything is dimensionless.

Feature vector `f = [hxL, hyL, lidL, openL, hxR, hyR, lidR, openR, wL, wR, yaw, pitch, roll, nx, ny, scale, (8 blendshapes), (S0 pitch, S0 yaw)]`. Cheap, roll-invariant, head-distance-normalized; the head terms let the regressor subtract head rotation (or in hybrid mode, exploit it).

### 2. Calibration (9 cells, ≤ 30 s)

On `{"type":"cal","zone":k}`: wait 300 ms (saccade + settle), then collect 24 frames (0.8 s). Drop frames where blink is active or the face is missing. Store `(f_t, target_k)` with `target_k` = the cell centre in normalized window coords (cx, cy ∈ {1/6, 1/2, 5/6}). Also keep the per-cell feature mean and covariance for the nearest-centroid fallback.

Fit after ≥ 5 cells (all 9 for the demo):
```
X = StandardScaler().fit_transform(F)         # ~216 × 19
model = Ridge(alpha=3.0).fit(X, T)             # T: 216 × 2, screen (x, y) in [0,1]
```
Ridge on ~19 features with 216 samples is well-conditioned; α in 1–10 barely matters. If vertical is still poor, add degree-2 terms of the 4 iris features only (`PolynomialFeatures(2)` on `[hxL, hyL, hxR, hyR]`, keep the rest linear) — that is the "polynomial calibration" WebGazer-style systems use, without blowing up dimensionality. Report leave-one-cell-out accuracy in the console (fit on 8 cells, predict the 9th) so you know before recording whether each cell is separable; EMC-Gaze's numbers say expect ~3° here.

Fallback classifier for `--mode head` or if ridge validation fails: nearest centroid on the standardized features with a per-cell diagonal Mahalanobis distance; zone = argmin, `-1` if the best distance > 3σ.

### 3. Smoothing: One-Euro on the predicted point

Predict `(x, y) = model.predict(scaler.transform(f))` every frame (30 Hz), then One-Euro filter per axis (Casiez et al. CHI 2012): adaptive cutoff `fc = mincutoff + beta · |ẋ|`. Start with **mincutoff = 1.0 Hz, beta = 0.007** (values the 2026 browser-benchmark paper used at 30 Hz in pixel units; convert beta to normalized units by multiplying by your window width in px, ≈ 0.007 × 1000 ≈ 7 in [0,1] units — tune by the two-step procedure: beta = 0, lower mincutoff until a fixation stops jittering, then raise beta until saccades stop lagging; try 0.3–1.0 Hz and 5–50 respectively). One-Euro beats a fixed EMA (README's 0.4) because fixations get heavy smoothing and saccades get almost none; the Kalman in EyeTrax is a constant-velocity model that overshoots on saccades unless its noise covariances are tuned.

Also gate: if `face == False` or blink active, hold the last filtered point and send `zone = -1` only after 400 ms without a face.

### 4. Zone decision with hysteresis

`zone_raw = 3·row + col` with `row = floor(3·y_filtered)`, `col = floor(3·x_filtered)`, clipped. Add a dead band: only switch zones when the point is ≥ 0.04 (of window size) inside the new cell, and require **3 consecutive frames** (100 ms) of the same `zone_raw` before publishing. Publish at 20 Hz (send every frame you have; the app's dwell timer is what matters). Optional: I-VT saccade detector (velocity > ~18°/s ≈ 1200 px/s in the paper's setup; in normalized units ~0.6 window-widths/s) to suppress zone changes mid-saccade.

Dwell: 1.0 s with a progress ring is conservative and correct for a first-time user on camera (literature: 500–600 ms preferred by practised users, 1000 ms "long enough to prevent false selections"; range 300–1100 ms). Keep the 0.8 s cooldown from the README.

### 5. Deliberate blink

Signal: `closed = 0.5·(eyeBlinkLeft + eyeBlinkRight) > 0.5` from blendshapes (my resting values were 0.13–0.17, so 0.5 has margin; use 0.45 to enter and 0.35 to exit for hysteresis). Fallback: EAR-style `open < 0.7 × rolling-median(open over 2 s)` — that is EyeTrax's adaptive threshold and is robust across users where a fixed 0.2–0.3 is not.

Timing: natural blinks last 100–300 ms; deliberate/voluntary blinks are longer (≥ 400 ms; high-speed-camera kinematics confirm voluntary "squeeze" blinks are the long tail). Emit `blink: true` when both eyes have been closed for **≥ 0.45 s and ≤ 1.5 s** (longer = eyes resting, not a command), with a 0.8 s refractory period. Emit on the 0.45 s crossing (fast feedback), not on reopening. Freeze the published zone to its value from **150 ms before onset** for the whole closure — eyelids dragging the iris landmarks down produce a bogus downward gaze jump exactly when you least want it. Require both eyes so winks and squints do not trigger.

### 6. Latency budget

Camera exposure/transfer ~33 ms + FaceLandmarker 9 ms + features/ridge/filter < 1 ms + One-Euro lag ~1 frame + hysteresis 100 ms + WebSocket < 1 ms ≈ **~150 ms glass-to-zone**, well inside a 1 s dwell. Do not add threads for the model; a single loop at 30 fps is enough. Convert BGR→RGB with `cv2.cvtColor` and wrap in `mp.Image(SRGB)` (that is what I benchmarked).

## Practical gotchas (with sources)

- **Vertical is the weak axis for every webcam system.** Iris is partly occluded by eyelids, and the vertical pixel resolution of the eye is tiny; older work explicitly added upper-eyelid features to improve vertical accuracy. Hence the `lid`/`open` features and head-pitch coupling above.
- **Head-pose coupling.** EMC-Gaze drops from 2.9° (still) to 6.4° when the head moves after calibration; the honest-benchmark paper only uses inter-corner distance as a distance proxy. Include yaw/pitch/roll/scale features and calibrate with the head in the demo posture. For the demo, a chair + tray means a mostly still head anyway.
- **Drift.** WebEyeTrack measured +20 % error over 20 minutes (WebGazer +49 %). Recalibrate right before recording; a `cal_reset` is one message.
- **Glasses and lighting.** WebGazer-style trackers drop from ~54 % to ~20 % hit-rate for glasses wearers; iris landmarks suffer similarly with reflections. Front-light the face, avoid a window behind the user.
- **Marketing numbers.** "0.5–1°" claims on hobby repos and "<1°" from GazeFlow are not reproducible; take 2–3° still-head as the best case and 5–6° realistic. WebGazer's "4–5°" is 8–13° in the wild.
- **MediaPipe on macOS.** Stay on `mediapipe==0.10.21`/Python 3.12; 1.0.x aborts at graph build on macOS CPU. Don't use the GPU delegate (Metal issues in Tasks). Timestamps passed to `detect_for_video` must be strictly increasing.
- **`reservedRegions` / `UIScreen`** are app-side concerns, not the tracker's; the tracker only emits normalized zones.

## Sources

- MediaPipe Face Landmarker guide — https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker ; Python guide — https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/python ; FaceLandmarker vs FaceMesh perf issue (M2) — https://github.com/google-ai-edge/mediapipe/issues/5130 ; macOS CPU abort on 1.0.1 — https://github.com/google-ai-edge/mediapipe/issues/6356 ; Metal delegate issues — https://github.com/google-ai-edge/mediapipe/issues/5656 ; MediaPipe Iris — https://github.com/google/mediapipe/blob/master/docs/solutions/iris.md
- EMC-Gaze / session-wise meta-calibration for landmark gaze (2026) — https://arxiv.org/html/2603.12388
- Measuring Browser Webcam Gaze Honestly (2026; FaceMesh+KRR 13-feature vector, One-Euro β=0.007/minCutoff=1.0, I-VT 1200 px/s) — https://arxiv.org/html/2608.11566v2
- WebEyeTrack / BlazeGaze (2025) — https://arxiv.org/html/2508.19544v1 , https://github.com/RedForestAi/WebEyeTrack ; MacGaze (Swift port) — https://github.com/AACTools/MacGaze
- EyeTrax — https://github.com/ck-zhang/EyeTrax , https://pypi.org/project/eyetrax/ ; gazecontrol — https://pypi.org/project/gazecontrol/1.0.0/
- MobileGaze — https://github.com/yakhyo/gaze-estimation ; L2CS-Net — https://github.com/Ahmednull/L2CS-Net , paper https://arxiv.org/abs/2203.03339 ; HF weight mirror — https://huggingface.co/dorni/SpeakerVid-5M-data-curation-models/blob/main/L2CSNet_gaze360.pkl
- Gaze-LLE — https://github.com/fkryan/gazelle ; 3DGazeNet — https://github.com/Vagver/3DGazeNet ; GazeTR — https://github.com/yihuacheng/GazeTR ; OpenFace 3.0 — https://github.com/CMU-MultiComp-Lab/OpenFace-3.0 ; OpenFace 2 Mac build — https://github.com/TadasBaltrusaitis/OpenFace/wiki/Mac-installation
- UnitEye (MediaPipe + ridge, ~2.4°) — https://github.com/wgnrto/uniteye ; gaze_track_webcam (poly-2, edge weighting) — https://github.com/ChiShengChen/gaze_track_webcam ; Eye_Tracking1 (corner-normalized iris + yaw/pitch + Ridge, 9+4 points) — https://github.com/aryanjh1001/Eye_Tracking1
- WebGazer — https://webgazer.cs.brown.edu/ ; systematic WebGazer evaluation 2025 (10.3–13.6°) — https://www.mdpi.com/1995-8692/19/5/99 ; efficient webcam calibration (2°/1° validation with 9 points) — https://dl.acm.org/doi/10.1145/3517031.3529645 ; webcam gaze eyelid/vertical features — https://www.researchgate.net/publication/221356355_Webcam-Based_Visual_Gaze_Estimation ; vertical/eyelid occlusion — https://arxiv.org/pdf/1907.04325
- Apple Vision landmarks — https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest
- Blink: PyImageSearch EAR (0.2–0.3, 3 frames) — https://pyimagesearch.com/2017/04/24/eye-blink-detection-opencv-python-dlib/ ; deliberate-vs-natural blink durations — https://github.com/karankapse/iris/issues/1 ; voluntary blink kinematics — https://pmc.ncbi.nlm.nih.gov/articles/PMC4043155/ ; blink phases — https://www.reviewofophthalmology.com/article/breaking-down-the-blink
- One-Euro filter tuning — https://gery.casiez.net/1euro/ ; dwell time studies (500–600 ms preferred, 1000 ms safe) — https://arxiv.org/html/2002.08455v2 , https://www.yorku.ca/mack/uais2006.html , https://arxiv.org/pdf/2404.13829
- ONNX Runtime CoreML EP — https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html
- eyeGestures (GPLv3, Py ≥ 3.13) — https://pypi.org/project/eyeGestures/
