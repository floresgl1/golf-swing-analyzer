# Golf Swing Analyzer

Analyze a golf swing from a single video using [MediaPipe Pose](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker)
and OpenCV. The pipeline estimates body pose per frame, segments the swing into
phases, measures tempo and body angles, and flags common swing faults.

## Two codebases, one tree

| Part | Location | Role |
| --- | --- | --- |
| **Python prototype** | `src/`, `data/`, `tests/`, `validation/` | Reference implementation and research playground — where the detection logic is developed, tuned and validated. **Source of truth.** |
| **Flutter app** | [`flutter_app/`](flutter_app/) | Android/iOS MVP that ports the same logic to Dart and runs it on-device from a recorded swing. Its report shows the four fault **measurements**, presented tentatively — the reference values are unvalidated, so it measures and shows rather than judging. Every analyzed swing is also appended to an on-device corpus with the capture context needed to interpret it later (see Phase 0 in [ROADMAP.md](ROADMAP.md)). |

The Dart side is a faithful port of the Python detection logic — same algorithms,
same thresholds, same normalization:

| Concern | Python (`src/`) | Dart (`flutter_app/lib/src/analysis/`) |
| --- | --- | --- |
| Pose estimation | MediaPipe Tasks (`pose_estimation.py`) | ML Kit (`services/pose_estimator.dart`) |
| Swing phases + tempo | `swing_phases.py` | `swing_phases.dart` |
| Fault detectors (×4) | `faults.py` | `faults.dart` |
| Drill recommendation | `drill_recommender.py` | `drill_recommender.dart` |
| Drill library | `data/drills.json` | bundled `flutter_app/assets/drills.json` |
| Swing history + value comparison | `swing_history.py` (`data/swing_history.json`) | `swing_history.dart` (app documents dir) |

**Known divergence (intentional, tracked):** the P0.3 frame-rate-invariance
refactor — duration-based window constants resolved via `frames_for()` — is
**Python-only**. The Dart port still uses hard-coded frame counts. This is
deliberate: the port is held until the Python side is validated against a
corpus, so an unvalidated change isn't mirrored into two codebases. See
[ROADMAP.md](ROADMAP.md).

## Features

- **Pose estimation & skeleton overlay** — draws the body skeleton on every frame
  and writes an annotated video with live swing-phase labels.
- **Swing phase detection** — finds takeaway, top of backswing, impact, and finish
  from the lead wrist's vertical trajectory.
- **Tempo** — backswing/downswing durations and their ratio (tour average ≈ 3:1).
- **Body angles** — shoulder- and hip-line angle vs. horizontal over the swing,
  with circular (period-180°) smoothing that down-weights foreshortened frames.
- **Fault detection** — a combined report for head sway, reverse pivot, early
  extension, and loss of posture, each with an annotated still.
- **Progress tracking (verification loop)** — every run of `faults.py` is saved
  to [data/swing_history.json](data/swing_history.json) and compared against the
  previous session: per-fault previous → current values, improved/worsened
  verdicts, threshold crossings ("fault fixed" / "NEW fault" with a starter
  drill), and tempo drift vs. the 3:1 benchmark.
  **Python only.** The Dart port computes the same trends and crossings but the
  app deliberately does not render them — with unvalidated thresholds a crossing
  between two swings may be measurement noise rather than a change in the
  golfer's swing. See the guardrail note on `SwingComparison.between` and the
  Beta section of [ROADMAP.md](ROADMAP.md).

## Requirements

- Python 3.12
- `opencv-python==5.0.0.93`, `mediapipe==0.10.35` (see [requirements.txt](requirements.txt))
- The MediaPipe **Pose Landmarker** model file at `data/pose_landmarker.task`
- A swing video at `data/videos/videoplayback.mp4`

The model and video are not tracked in git (large binaries). See setup below.

## Setup

```bash
# from the project root
python -m venv venv

# activate the environment
venv\Scripts\activate          # Windows (cmd)
venv\Scripts\Activate.ps1      # Windows (PowerShell)
source venv/bin/activate       # macOS/Linux

pip install -r requirements.txt

# create the output directory (git ignores its contents)
mkdir output
```

Download the pose model (the "heavy" variant, ~30 MB, matches this project) and
save it as `data/pose_landmarker.task`:

```
https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task
```

Any Pose Landmarker variant (lite/full/heavy) works — just rename it to
`data/pose_landmarker.task`. Then place a swing clip at
`data/videos/videoplayback.mp4`.

## Usage

Run each script **from the project root** (paths to the model, video, and output
are relative to it):

| Command | Produces |
|---|---|
| `python src/swing_phases.py` | Phase breakdown + tempo (console); `output/wrist_trajectory.png` |
| `python src/pose_estimation.py` | `output/annotated.mp4` (skeleton + phase labels) |
| `python src/phase_montage.py` | `output/swing_phases_montage.png` (four key positions) |
| `python src/body_angles.py` | Shoulder/hip angles (console) + `output/body_angles.png` |
| `python src/faults.py` | Fault report + drills + progress vs. last session (console); one annotated still per fault |
| `python src/faults.py <fault_id>` | Same, recording which fault you practiced (e.g. `head_sway`) so the next run's comparison calls out whether the focus paid off |
| `python src/swing_history.py` | Demo of the progress comparison on two synthetic sessions |

Valid fault ids for the focus argument: `head_sway`, `reverse_pivot`,
`early_extension`, `loss_of_posture`. History accumulates in
[data/swing_history.json](data/swing_history.json); reset `"sessions"` to `[]`
to start over.

The scripts that open a plot window (`swing_phases`, `body_angles`) still save
their PNG whether or not the window is shown. Press `q` to quit the annotated
video window early in `pose_estimation.py`.

## Configuration

Set the golfer's handedness in [src/swing_phases.py](src/swing_phases.py):

```python
HANDEDNESS = 'right'   # 'right' or 'left'
```

This selects the **lead** wrist (left for a right-handed golfer) used for phase
detection, and flows through every script.

## How it works

- **Phases** come from the lead wrist's height (`1 - y`): it rises to a peak (top
  of backswing), drops to a valley (impact), then rises to the finish. Takeaway
  is the wrist's low point just before the climb.
- **Angles** are computed in pixels (not normalized coords) so the frame's aspect
  ratio doesn't distort them, then smoothed with a double-angle complex average.
- **Faults** are each measured as a change between swing positions, normalized by
  torso length so thresholds are resolution- and size-independent.

## Notes & limitations

- **Single 2D camera.** Metrics that depend on a toward/away-target or toward-ball
  direction (reverse pivot, early extension) are strongest from a **face-on** or
  true **down-the-line** view. In oblique views those motions partly fall on the
  camera's depth axis and read weaker; the code notes where a proxy is used.
- **Fault thresholds** are sensible defaults calibrated against a good swing. To
  trust them in both directions, validate against a known-faulty clip.

## Project layout

```
src/
  pose_estimation.py   skeleton + phase-label video (imports swing_phases)
  swing_phases.py      phase detection, tempo, wrist-trajectory plot
  phase_montage.py     four-position checkpoint montage
  body_angles.py       shoulder/hip line angles + smoothing
  faults.py            head sway, reverse pivot, early extension, loss of posture
  drill_recommender.py corrective drills for flagged faults (data/drills.json)
  swing_history.py     session history + swing-over-swing progress comparison
data/                  model + video (not tracked); drill library + swing history
output/                generated plots, montage, annotated video (not tracked)
```

```
flutter_app/           Android/iOS app: the Dart port + record-then-analyze UI
tests/                 pytest suite (characterization + robustness)
validation/golfdb/     GolfDB screening and phase-detection harness
```

See [`flutter_app/README.md`](flutter_app/README.md) for the Flutter SDK
version, camera-permission setup for iOS/Android, and build/run/test steps.
