# Golf Swing Analyzer — Flutter MVP

A cross-platform (Android/iOS) port of the Python golf swing analyzer. It
follows a **record → analyze** flow: record one swing with the device camera,
then run on-device pose estimation, phase detection, fault detection, and drill
recommendation, and show a report. Real-time analysis is intentionally out of
scope for this MVP.

## Pipeline

```
RecordScreen (camera)  ->  video file
        │
        ▼
FrameExtractor (ffmpeg)          extract every frame as JPEG + read fps
        │
        ▼
PoseEstimator (ML Kit)           per-frame landmarks -> eye/shoulder/hip
        │                        midpoints, torso length, lead-wrist y
        ▼
SwingAnalyzer                    assemble trajectory arrays, then:
   detectPhases  ->  swingTempo
   detectHeadMovement / detectReversePivot /
   detectEarlyExtension / detectLossOfPosture
   recommendDrills (from bundled assets/drills.json)
        │
        ▼
ReportScreen                     tempo + 4 fault measurements + drills per fault
```

Every analyzed swing is also appended to the on-device corpus
(`analysis/swing_history_store.dart`) with the capture context needed to
interpret it later — frame rate, handedness, pose coverage, the per-frame
arrays, and the measurement-basis stamps from `analysis/measurement_basis.dart`.

## What was ported from Python

The detection logic is a faithful, line-by-line port. It is **pure Dart** (no
Flutter imports) so it is unit-testable off-device and matches the Python
numerically.

| Python (`src/`) | Dart (`lib/src/analysis/`) |
| --- | --- |
| `swing_phases.py` → `detect_phases`, `swing_tempo`, `_moving_average` | `swing_phases.dart`, `num_utils.dart` |
| `faults.py` → 4 detectors, `_addr_median`, `_window_median`, `_spine_tilt` | `faults.dart` |
| `drill_recommender.py` → load + recommend | `drill_recommender.dart` |
| `data/drills.json` | `assets/drills.json` (bundled) |
| `swing_history.py` → sessions, save/load, comparison | `swing_history.dart` (stored in the app documents dir; rendered by `ui/widgets/swing_comparison_view.dart` on the report screen as raw previous → current values, with the trend/crossing verdicts computed but not shown — see the guardrail note on `SwingComparison.between`) |

Key details preserved exactly:

- **Torso-length normalization** — every fault metric is divided by the
  shoulder→hip distance measured at address, so thresholds are resolution- and
  size-independent.
- **Median windowing** — address values use the median over the 10 frames
  ending at the takeaway; impact/top/finish use a small median window (radius 2
  for head/pelvis at impact, radius 3 otherwise) so one bad frame can't flip a
  result. **These are frame counts, and that is a known divergence** — the
  Python side converted them to durations in P0.3, and the Dart port is held at
  frame counts deliberately until P0.2 recalibrates. A frame count is a fixed
  duration only at one frame rate; these were tuned at 240 fps, so phone capture
  measures over different windows than the thresholds assume. See `ROADMAP.md`.
- **Thresholds** — sway `0.13`, dip `0.25` (informational), reverse pivot
  `0.12`, early extension `0.10`, loss of posture `12°`.
- **Phase detection** — interpolate missing frames, smooth wrist *height*
  (`1 − y`) with an edge-padded moving average, then locate the first tall peak
  (top), the following trough (impact), and the later peak (finish).

Coordinate note: MediaPipe landmarks are normalized (0..1); ML Kit landmarks are
already in image pixels. Because every detector normalizes by torso length and
phase detection depends only on the trajectory's shape, the change of units
requires no code change.

### Cross-checked against Python

The Dart unit tests in `test/` use synthetic swings whose expected phase indices
and fault results were verified against the original Python detectors
(`top=29, impact=45, finish=60`; sway/early-extension/posture/reverse-pivot all
flag at the constructed magnitudes). Run them with `flutter test`.

This checks that the **port matches Python**, which is the only claim it makes.
It is not evidence that the detectors are correct: the reference values have
never been validated against a labelled corpus. See `ROADMAP.md`.

## Requirements

- **Flutter SDK ≥ 3.19.0** with **Dart ≥ 3.3.0** (declared in `pubspec.yaml`).
  Check yours with `flutter --version`; upgrade with `flutter upgrade`.
- A **physical device** — the camera, ML Kit pose model, and ffmpeg do not run
  on simulators/emulators reliably. Use a real Android phone or iPhone.
- **Android**: `minSdkVersion 24` (ML Kit needs 21, ffmpeg needs 24, so 24 wins).
- **iOS**: deployment target **15.5+** — the floor imposed by ML Kit
  (`google_mlkit_commons`); anything lower fails `pod install`. Applied by
  `tool/configure_ios.py`, which is the authoritative value; this line is a
  summary of it.

## Building and running

This directory holds the Dart source, tests, and assets but not the generated
platform folders (they're git-ignored — see the repo root README). Generate them
and fetch packages before the first run:

```bash
cd flutter_app
flutter create .        # regenerates android/ and ios/ around this source
flutter pub get         # resolve dependencies from pubspec.yaml
```

Then wire up permissions (below), connect a device, and run:

```bash
flutter devices         # confirm your phone is listed
flutter run             # debug build on the connected device
# or: flutter run --release   for a faster, production-like build
```

Run the ported-logic unit tests (no device needed):

```bash
flutter test
```

### Permissions

`flutter create .` scaffolds the platform folders; then add the camera
permission to each. (Audio is disabled in the recorder, so no microphone
permission is required.)

**Android** — in `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`
and above the `<application>` tag:

```xml
<uses-permission android:name="android.permission.CAMERA"/>
```

And set the minimum SDK in `android/app/build.gradle`:

```gradle
android {
    defaultConfig {
        minSdkVersion 24
    }
}
```

**iOS** — do not hand-edit anything under `ios/`. Run:

```bash
python3 tool/configure_ios.py     # after every `flutter create .`
```

That sets `NSCameraUsageDescription` in `Runner/Info.plist` and raises the
deployment target to 15.5 in both the Podfile and every Xcode build
configuration. 15.5 is not a preference — it is the minimum
`google_mlkit_commons` accepts, and `pod install` fails outright below it.

**On Windows and Linux the Podfile half is skipped, by design.** `flutter
create` only generates a Podfile on a host with a working Xcode, so off a Mac
there is no Podfile to patch and the script says so loudly and exits 0 — the
`Info.plist` and `project.pbxproj` patches still run. A tree generated on a Mac
and copied to another host still has its Podfile patched; only a genuinely
absent one is skipped. On a Mac (and on the CI runner) a missing Podfile stays
a hard error, because there it means something is wrong with the tree.

The script exists because `ios/` is gitignored and regenerated, so a hand-edited
`Info.plist` or Podfile survives on one machine and reaches nothing else — not a
fresh clone, not CI. It is idempotent, and it exits non-zero rather than
silently doing nothing, which matters because a missing camera description
produces a build that compiles cleanly and crashes the moment the camera opens.

The CI workflow (`.github/workflows/ios-build.yml`) runs the same script, so
these values have one source. Change them in `tool/configure_ios.py`.

## Editing the drill library

`assets/drills.json` is the same instructor-editable format as the Python
project: add or edit entries and rebuild. The header comment in the file lists
the allowed `fault` and `difficulty` values.

## Notes / next steps

- `detectReversePivot` omits the Python function's `head_y`/`hip_y` arguments,
  which existed only to draw debug overlay points — the computed `reverse` value
  is identical.
- Frame extraction dumps all frames to a temp dir and deletes them after
  analysis. For long clips, sampling every Nth frame would cut analysis time.
- A future iteration could move to the camera image stream for real-time
  feedback; the pure-Dart detectors would be reused unchanged.
