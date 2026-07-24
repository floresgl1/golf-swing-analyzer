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

- Track false positives (pro swing flagged) and false negatives (obvious fault missed)
- Adjust thresholds based on findings — document the calibration rationale
- Consider per-fault sensitivity/specificity if enough test data is available
- Note: the current thresholds were calibrated against a **single** tour-pro slow-motion clip, and (see P0.2) they have silently absorbed a 15–22% inflation from a flawed address window — recalibration is not optional cleanup, it is required to trust any threshold

#### P0.1 — Corpus collection spec
Controlled design: lock recording conditions (the only non-golfer axis), vary body type (the thing we're solving), sample across skill (a proxy for fault prevalence). Sample-size floor: **≥30 clean negatives that meet spec** — by the rule of three, zero flags on 30 caps the false-positive rate at ~10%; 5–10 videos proves nothing.

```
INCLUDE:
  - camera angle:  side-on / down-the-line, within ~10° of perpendicular
  - camera height: belt/hand height, on a tripod, locked off (no pan/zoom)
  - framing:       full swing, feet-to-head in frame address through finish
  - capture fps:   fixed at ONE rate across the whole corpus, >= 120 fps
                   *** HARD REQUIREMENT — reasons below, do not relax ***
  - settled address: >= 0.5 s of stillness before takeaway
                   *** HARD REQUIREMENT — reasons below, do not relax ***
  - handedness:    right-handed only (until HANDEDNESS is parameterized)
  - body type:     deliberately varied
  - skill level:   mixed, weighted amateur (sampling strategy, not a variable)

EXCLUDE:
  - face-on / any non-side-on view (known: head sway reads 0.55 from rotation)
  - variable / ramped slow-motion (destroys the tempo frame ratio at transition)
  - any cut, edit, or camera reposition within the swing
  - a second person/moving object in frame (pose[0] can jump to a caddie)
  - clips that start mid-waggle (no settled window to anchor address to)
```

Collection logistics (learned, keep):
- **Over-collect: shoot 45–50 to land 30 clean.** The spec is strict; clips fail screening on framing or a mid-swing waggle and you won't know until review.
- **Log metadata at capture time, not after** — height, build, handedness, and an eyeball "did the swing look clean?" recorded while the golfer is in front of you. Reconstructing body type from footage is guesswork, and body-type variation is the whole point.
- **Use the heavy pose model for all collection/validation** (`data/pose_landmarker.task`, ~30.6 MB). Thresholds were calibrated through it; the characterization golden is now pinned to it (see `tests/test_pose_estimation.py`). Do not validate against a lite/full model.

Two requirements are HARD, not stylistic — each is load-bearing for an algorithm we are committed to:
- **capture fps ≥ 120, fixed.** The downswing is ~0.25 s; at 30 fps that is ~7 frames and ±2 frames of impact-localization error spans the entire 2.5:1–3.5:1 tempo band. Below ~120 fps the smoothing window also rounds to 1 frame (no smoothing). And note **container fps ≠ capture fps**: `cv2.CAP_PROP_FPS` reports 30 for the 240 fps calibration clip. A properly collected real-time ≥120 fps corpus makes CAP_PROP_FPS correct; slow-mo renders do not (see `swing_phases.py` BASELINE_FPS / capture_fps notes). This kills YouTube as a primary source.
- **≥ 0.5 s settled address.** The address-onset fix (P0.2) locates where the body *leaves* address by the first sustained rise in shoulder+hip speed; it needs settled pre-swing frames to measure a baseline against. A clip that opens mid-waggle cannot be fixed in post.

#### P0.2 — `detect_address_onset()`: ONE function fixes TWO bugs + threshold recalibration (BLOCKED on P0.1 corpus)
**This is not "implement `detect_address_onset()`." It is that PLUS a full recalibration pass, and it must not be merged piecemeal.**

**Shared root cause: nothing in the pipeline knows when the swing starts.** Neither the fault-baseline window nor `detect_phases` has a concept of "the golfer is now leaving address," so both improvise a boundary — and both improvisations fail once the input isn't the one calibration clip.

- **Bug A — fault-baseline window (measured on the calibration clip).** The address baseline is sampled over `[takeaway-ADDRESS_OFFSET_S, takeaway]`, but the wrist-defined takeaway (frame 55) fires 32 frames / 133 ms *after* body motion begins (frame 23). The window sits inside the takeaway motion — torso foreshortened ~4%, spine tilt +2.6°, shoulders rotated — inflating every fault reading (head sway ~+17%, loss-of-posture +2.6° on a 12° threshold). See the `ADDRESS_OFFSET_S` KNOWN ISSUE in `src/swing_phases.py`.
- **Bug B — `detect_phases` top-detection (measured on GolfDB, `validation/golfdb/`).** `detect_phases` has no start bound, so it searches the *entire clip* for the first tall wrist peak. On the calibration clip the clip boundary happened to sit right at address and served as that bound. GolfDB clips carry generous lead-in, so the bound vanished and the heuristic latches onto spurious wrist motion in the settle — e.g. id 1203 (540 pre-address frames): real top at frame 577, detected at **frame 1**; impact then cascades wild. Confirmed on **real-time** clips: `corr(|Top err|, pre-address) = +0.35`, failing clips have 226 vs 134 pre-address frames (6% of real-time exceed 10% of swing). **Not the same as Bug A** — do NOT patch it with a separate "reject peaks in the settle" filter; that would be a second, overlapping mechanism doing what the onset bound already does.

**One fix for both:** `detect_address_onset()` (first sustained rise in shoulder+hip midpoint speed) supplies (a) the fault-baseline anchor for Bug A and (b) the lower search bound for `detect_phases`' top in Bug B. This is also why the P0.1 spec demands ≥0.5 s settled address — the onset detector needs it.

Required work, in order:
1. Add `detect_address_onset()`; re-point `_addr_median` at it (Bug A) **and** clamp the `detect_phases` top/takeaway search to start at onset (Bug B).
2. **Recalibrate all four thresholds** (`SWAY_THRESHOLD` 0.13, `REVERSE_PIVOT_THRESHOLD` 0.12, `EARLY_EXTENSION_THRESHOLD` 0.10, `POSTURE_THRESHOLD` 12°) against the P0.1 corpus. Fixing the window without lowering the thresholds flips borderline swings from false-positive to false-negative.
3. Update `tests/test_faults.py` (new windows) and add a `detect_phases` regression case with long pre-address lead-in; re-verify.
4. Only then mirror to Dart.

Why blocked: step 2 has no ground truth without the corpus. Doing step 1 alone silently changes fault detection and regresses accuracy. Do not start P0.2 before P0.1 exists.

**Open, NOT covered by this fix:** GolfDB slow-mo clips have a *separate, larger* Top-failure population (17%) with `corr(|Top err|, pre-address) ≈ 0` — the onset bound will not fix it and its driver is unknown (candidates: broad/dwelling top plateau over ~8× more frames; different source footage). Investigate after P0.2; do not assume onset closes it. Also note the **clarity gate was retired as a negative finding** (`validation/golfdb/`): trajectory-SNR was an intuitive discriminator but predicted nothing (r ≈ −0.06); the real predictor was pre-address length. Recorded so it is not re-proposed.

#### P0.3 — fps windowing refactor ✅ DONE
- Window constants converted from hard-coded frame counts to durations (`SMOOTH_WINDOW_S`, `IMPACT_RADIUS_S`, `ADDRESS_OFFSET_S`, `DEFAULT_RADIUS_S`) resolved via `frames_for(seconds, fps)`; behavior-preserving at `BASELINE_FPS = 240` (all 24 windowing characterization tests unchanged; verified the suite catches a perturbed constant).
- Remaining seam: `main()` still uses container fps and pins windowing to `BASELINE_FPS`. When P0.1 lands a `capture_fps` metadata field per video (defaulting to `CAP_PROP_FPS` when they agree), thread it into `detect_phases`/detectors — that is the point where slow-mo vs real-time stops being a hidden variable.
- **Left-handed golfers**: `HANDEDNESS` is a module constant with no per-run override — lefties are analyzed on the trail wrist (garbage phases). Parameterize before admitting lefties to the corpus.

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
- **KNOWN DIVERGENCE (intentional, tracked):** the P0.3 fps windowing refactor (duration-based constants + `frames_for`) is Python-only for now. The Dart port still uses hard-coded frame counts. This is deliberate — the port is held until the Python side is validated against the corpus (per P0.2), so an unvalidated change isn't mirrored into two codebases. Port `frames_for` + the seconds constants to Dart together with the P0.2 recalibration, not before.

### Key Design Decisions (do not change without discussion)
- **Eye midpoint** for head tracking (not nose) — rotation-stable proxy
- **Torso-length normalization** for all distance-based faults — resolution/size-independent
- **Median windowing** at address and impact, as durations resolved to frames at the capture rate (`ADDRESS_OFFSET_S`, `IMPACT_RADIUS_S`, `DEFAULT_RADIUS_S`; 10 / 2 / 3 frames at `BASELINE_FPS`=240) — jitter-resistant and frame-rate-invariant. **The address window has a KNOWN ISSUE** (samples into the takeaway motion, not settled address) — see P0.2 and the `swing_phases.py` comment; do not treat the current constant as validated
- **Target direction auto-inferred** from hip translation — works regardless of camera side
- **Lower is always better** for fault values; **tempo uses distance from 3:1** — different semantics
- **Record-then-analyze** flow on mobile (not real-time) — simpler, more accurate

### Testing
- Python: run `python src/faults.py` against test videos, check all four verdicts
- Python: run `python src/swing_phases.py` to verify phase detection and tempo
- Dart: `flutter test` runs unit tests with synthetic swing data that must match Python outputs
- Any threshold change requires re-running against the full test video set