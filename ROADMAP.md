# Golf Swing Analyzer — Roadmap

## Project Overview

A CV-powered golf swing coaching app that analyzes a golfer's swing from phone video, detects faults, recommends corrective drills, and verifies improvement over time. The key differentiator is the **closed coaching loop**: diagnose → prescribe → verify — all AI-driven, no human coach required.

The project has two codebases: a **Python prototype** (root) used for rapid iteration, and a **Flutter app** (`flutter_app/`) that ports the analysis logic to mobile.

---

## Completed Phases

### Phase 1 — Pose Estimation ✅
- MediaPipe Tasks API (heavy model) extracts 33 BlazePose keypoints per frame
- Full skeleton overlay with named landmark constants and grouped connections
- Annotated video output saved to `output/`
- **Key files**: `src/pose_estimation.py`, `data/pose_landmarker.task`

### Phase 2 — Swing Phase Detection ✅
- Lead wrist y-trajectory (configurable for left/right-handed golfers)
- Phase detection: address, backswing (takeaway), top, downswing, impact, follow-through, finish
- NaN interpolation, edge-padded moving average smoothing
- Takeaway = lowest wrist point before top (not threshold-based)
- Color-coded wrist trajectory plot with phase regions
- Phase labels and event flashes burned into annotated video
- **Key files**: `src/swing_phases.py`

### Phase 3 — Biomechanical Measurements ✅
- **Swing tempo**: backswing/downswing frame ratio (tour benchmark ~3:1)
- **Shoulder and hip line angles**: per-frame tilt vs. horizontal with circular smoothing (complex-number period-180 method)
- All angles computed in pixel space to avoid aspect-ratio distortion
- Measurements reported at address, top, and impact
- **Key files**: `src/body_angles.py`, `src/swing_phases.py` (tempo)

### Phase 4 — Fault Detection ✅
Four fault detectors, all using torso-length normalization and median-windowed position estimates:

| Fault | What it measures | Threshold | Key landmarks |
|---|---|---|---|
| Head sway | Lateral drift of eye midpoint, address→impact | 0.13 torso-lengths | Eyes 2/5, shoulders, hips |
| Reverse pivot | Head lean toward target relative to hips, address→top | 0.12 torso-lengths | Eyes, hips (target direction auto-inferred) |
| Early extension | Pelvis rise (y-axis), address→impact | 0.10 torso-lengths | Hips, shoulders |
| Loss of posture | Spine tilt straightening (degrees), address→impact | 12° | Shoulders, hips |

Design notes:
- Eye midpoint (not nose) for head tracking — sits near the skull's rotation axis, avoids inflating on normal head turn through impact
- Vertical dip tracked as informational, not a flagged fault
- Target direction derived from hip translation (address→finish), not hardcoded
- **Key files**: `src/faults.py`

### Phase 5 — Drill Recommendations ✅
- `data/drills.json`: 12 drills (3 per fault), instructor-editable with a comment header explaining the schema
- Each drill has: id, name, fault, description, difficulty (beginner/intermediate/advanced), equipment
- Drills sorted by difficulty when recommended
- Clean "nothing to fix" message when no faults are flagged
- **Key files**: `src/drill_recommender.py`, `data/drills.json`

### Phase 6 — Flutter MVP ✅
- Record → analyze flow (not real-time)
- Camera recording → ffmpeg frame extraction → ML Kit pose estimation → analysis → report screen
- All detection logic ported to pure Dart (no Flutter deps in analysis modules)
- Dart analysis modules mirror Python logic with identical thresholds and windowing
- drills.json bundled as asset
- **Key files**: `flutter_app/lib/src/analysis/`, `flutter_app/lib/src/ui/`
- **Branch**: `flutter-mvp`

### Phase 7 — Verification Loop ✅
- `data/swing_history.json`: per-session storage of all fault values, tempo, and optional target fault
- Session comparison: previous → current value per fault, improved/worsened/unchanged (epsilon-aware)
- Threshold crossing callouts: "fault fixed!" / "NEW fault"
- New faults auto-recommend the easiest drill from the library
- Targeting: `python src/faults.py head_sway` marks focus fault, next run annotates with "← your focus"
- Tempo judged by distance from 3:1 benchmark (not raw lower-is-better)
- Dart port with `SwingHistoryStore` and `SwingComparisonView` widget
- **Key files**: `src/swing_history.py`, `flutter_app/lib/src/analysis/swing_history.dart`, `flutter_app/lib/src/ui/widgets/swing_comparison_view.dart` (on `flutter-mvp`)

---

## Current Priorities (in order)

### P0 — Threshold Validation
**Status**: Not started
**Goal**: Confirm fault thresholds work across diverse swings before building more features.

- Test against 5–10 swing videos: amateur swings, different skill levels, different camera angles, different body types
- Track false positives (pro swing flagged) and false negatives (obvious fault missed)
- Adjust thresholds based on findings — document the calibration rationale
- Consider per-fault sensitivity/specificity if enough test data is available
- Note: the current thresholds were calibrated against a single tour pro slow-motion video

### P1 — Flutter Device Testing
**Status**: Not started
**Goal**: Validate the mobile experience end-to-end on a real device.

- Run `flutter create .` to generate platform folders, add camera permissions per README
- Record a real swing and run the full pipeline
- Compare ML Kit pose quality against MediaPipe heavy model — numbers may shift
- Profile frame extraction and analysis time — is the user waiting too long?
- Test on both iOS and Android if possible
- Address any ML Kit keypoint accuracy issues (may need threshold adjustments for mobile)

---

## Future Feature Roadmap

### Additional Faults
- **Casting**: early wrist unhinge in the downswing (wrist-to-shoulder angle flattening before impact)
- **Over-the-top**: club path moving outside-in during downswing transition (requires club or hand path tracking)
- **Sway vs. slide**: distinguish backswing lateral hip movement (sway) from downswing lateral hip movement (slide) — currently only head sway is tracked
- **Tempo refinement**: flag tempo ratios significantly outside the 2.5:1–3.5:1 range

### Second Camera Angle
- **Face-on view** for true rotational measurements (hip rotation, shoulder rotation, X-factor)
- Current side-on camera only captures projected tilt, not actual rotation
- Design decision: require two separate recordings, or guide the user through a two-angle capture flow?
- Alternative: monocular 3D pose lifting (e.g., MotionBERT, MHFormer) to estimate rotation from a single view — adds significant complexity

### Camera Angle Handling
- Current detectors validated for **side-on (down-the-line) view only**
- Face-on view causes false positives: head sway reads 0.55 due to rotation appearing as lateral movement
- Loss of posture measurements differ significantly between angles (different projection)
- Reverse pivot and early extension passed from face-on
- Options: auto-detect camera angle, restrict to side-on with user guidance, or angle-specific logic

### User Experience
- **Video playback**: slow-motion scrubbing with phase markers and fault annotations overlaid
- **Drill media**: short video clips or animations demonstrating each drill (replace text-only descriptions)
- **Progress dashboard**: chart fault values over time (weeks/months), show trends
- **User accounts**: cloud sync for swing history across devices
- **Sharing**: export swing reports as images or PDFs for sharing with an instructor
- **Onboarding**: guide for recording angle, distance, lighting for best results

### Performance & Architecture
- **Stream-based processing**: replace ffmpeg frame extraction with direct video stream processing to reduce memory usage and latency
- **Real-time mode**: live pose overlay while recording (display only, analysis still runs after)
- **Model optimization**: evaluate MediaPipe Lite or custom TFLite model for faster on-device inference
- **Offline-first**: ensure full functionality without network connectivity

### Multi-Sport Expansion (Long-term)
The pipeline architecture (pose → phases → features → faults → drills → verify) is sport-agnostic. Future sports would require:
- Sport-specific landmark tracking priorities
- Sport-specific phase definitions
- Sport-specific fault rules and drill libraries
- Candidates: tennis (serve, groundstrokes), baseball (batting), cricket (bowling, batting)
- **Do not pursue until golf is thoroughly validated and polished**

---

## Architecture Notes for Contributors

### Python ↔ Dart Parity
- Every analysis change in Python must be mirrored in Dart (and vice versa)
- `README.md` has a table mapping Python modules to Dart equivalents
- Keep `drills.json` in sync between `data/` and `flutter_app/assets/`
- Thresholds are defined as constants in both codebases — update both when calibrating

### Key Design Decisions (do not change without discussion)
- **Eye midpoint** for head tracking (not nose) — rotation-stable proxy
- **Torso-length normalization** for all distance-based faults — resolution/size-independent
- **Median windowing** at address (10 frames) and impact (radius 2–3) — jitter-resistant
- **Target direction auto-inferred** from hip translation — works regardless of camera side
- **Lower is always better** for fault values; **tempo uses distance from 3:1** — different semantics
- **Record-then-analyze** flow on mobile (not real-time) — simpler, more accurate

### Testing
- Python: run `python src/faults.py` against test videos, check all four verdicts
- Python: run `python src/swing_phases.py` to verify phase detection and tempo
- Dart: `flutter test` runs unit tests with synthetic swing data that must match Python outputs
- Any threshold change requires re-running against the full test video set