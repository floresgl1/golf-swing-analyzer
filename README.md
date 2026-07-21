# Golf Swing Analyzer

Analyze a golf swing from a single video using [MediaPipe Pose](https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker)
and OpenCV. The pipeline estimates body pose per frame, segments the swing into
phases, measures tempo and body angles, and flags common swing faults.

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
| `python src/faults.py` | Fault report (console) + one annotated still per fault |

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
data/                  model + video (not tracked)
output/                generated plots, montage, annotated video (not tracked)
```
