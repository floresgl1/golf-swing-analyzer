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
- **Location**: `flutter_app/` in the trunk. (Was the `flutter-mvp` branch; merged — see Branch reconciliation below.)

### Phase 7 — Verification Loop ✅
- `data/swing_history.json`: per-session storage of all fault values, tempo, and optional target fault
- Session comparison: previous → current value per fault, improved/worsened/unchanged (epsilon-aware)
- Threshold crossing callouts: "fault fixed!" / "NEW fault" — **Python only. Removed from the app UI**; see the Beta decision record below
- New faults auto-recommend the easiest drill from the library — Python only, same reason
- Targeting: `python src/faults.py head_sway` marks focus fault, next run annotates with "← your focus". In the app this is a picker on the record screen
- Tempo judged by distance from 3:1 benchmark (not raw lower-is-better)
- Dart port with `SwingHistoryStore` and `SwingComparisonView` widget. **The Dart widget renders previous → current values only** — the trend and crossing machinery is computed, kept unit-tested, and deliberately not surfaced
- **Key files**: `src/swing_history.py`, `flutter_app/lib/src/analysis/swing_history.dart`, `flutter_app/lib/src/ui/widgets/swing_comparison_view.dart`

---

## Beta — decision record (2026-07-26)

*Folded in from a second `ROADMAP.md` that existed on `flutter-mvp`. The two
files shared only a filename: this one tracked the project, that one recorded
the beta presentation decisions. This is now the single canonical roadmap.*

Goal of the beta is to test **retention** and to passively accumulate a corpus of
real swings — not to prove the detectors are right. The fault thresholds in
`faults.py` / `faults.dart` have never been validated against a labelled corpus,
so the app's presentation was pulled back to match what the data can actually
support.

- **Fault presentation is tentative, not definitive.** A flagged fault renders as
  "Possible early extension" with a `POSSIBLE` chip, the measured value, and the
  threshold labelled a "beta reference" rather than a verdict line. The report
  carries a standing caveat that measurements are indicative and unvalidated.
  Detection, thresholds, and the drill recommendations attached to each flagged
  fault are unchanged.

- **Cross-session judgment is not rendered.** The report's comparison card shows
  only raw previous → current measured values ("Last swing vs this swing"). The
  improved/worsened/unchanged trends, the FIXED / NEW FAULT badges, and the
  "you cleared X" / "the practice is paying off" callouts have been removed from
  the UI.

  Reason: with unvalidated thresholds, a threshold crossing between two swings
  may be measurement noise rather than a change in the golfer's swing, so
  "improved", "fixed", and "new fault" are conclusions the data cannot support.
  Telling a beta tester they improved when we cannot show it is the one claim
  most likely to cost trust.

  The `Trend` / `Crossing` machinery in `swing_history.dart` is **kept and stays
  unit-tested** — it is computed on every comparison and simply not read by the
  view. See the guardrail note on `SwingComparison.between`. Do not re-surface it
  in the UI until the thresholds are validated.

- **The reassuring direction was softened too (Phase 0).** The original pass
  hedged flagged faults and left "Nothing flagged in this swing." confident and
  green, and printed the tempo ratio beside a "tour average ~3 : 1" benchmark.
  The false-negative rate is as unmeasured as the false-positive rate, and at
  phone frame rates the tempo ratio's error spans most of the band that would
  make that comparison meaningful. Both are now stated honestly.

**Note the asymmetry with Python.** `src/swing_history.py` still prints the full
verdict set — direction words, "fault fixed!", "NEW fault", the focus-fault
callout. That is deliberate and not an oversight: the Python side is a research
tool read by people who know the thresholds are uncalibrated. The app is read by
beta testers who do not. Do not "restore parity" by copying the Python
presentation into Dart, and do not strip it from Python to match the app.

### Exit criteria for restoring cross-session verdicts

1. Enough beta swings collected to form a labelled corpus. Collection is now
   possible (see Phase 0) but still needs a path off the device beyond manual
   export.
2. Per-fault thresholds validated against that corpus, with a known false-positive
   rate. This is **P0.1 + P0.2** below — the same work, not a second effort.
3. Per-fault measurement noise quantified, so a between-session delta can be
   distinguished from repeat-measurement variance. This is the noise floor P0.1
   specifies; the corpus fields added in Phase 0 are what make it measurable.

Until all three hold, the report measures and shows; it does not judge.

---

## Branch reconciliation (2026-07-27)

`main` and `flutter-mvp` are merged into one trunk. Previously `main` held the
Python pipeline, validation harness and pytest suite but no `flutter_app/`,
because `e86c8cf` ("Revert 'Add Flutter MVP port of the golf swing analyzer'")
was in its history; `flutter-mvp` held the app plus an older copy of `src/`.

A direct merge in either direction proposed **deleting 19 Flutter files
silently**, because the merge base contained `flutter_app/` and `main` had
deleted it. The fix was to neutralize the revert first (`git revert e86c8cf`)
and then merge on content, which reduced the conflict set to two documentation
files.

Verified before merging: `flutter-mvp` carried **no unique Python edit** —
`git diff origin/main...origin/flutter-mvp -- src/` was empty, every `src/` blob
on `flutter-mvp` existed in `main`'s history, and no commit unique to
`flutter-mvp` touched any `.py` file. So `main`'s `src/` is a strict superset and
was taken wholesale.

Recovered in passing: `34094e9` ("Fall back to an empty drill list when
drills.json fails to parse") had a Dart half that `e86c8cf` deleted as collateral
damage and `flutter-mvp` never received. Reverting the revert restored it.

---

## Phase 0 — Make beta swings usable as a corpus ✅ (app side)

Changes **what is recorded**, never what is measured: no detector, threshold or
window was touched. Developed on `claude/phase0-corpus-fields` against the old
`flutter-mvp` tip and replayed onto this trunk after the reconciliation above.

The problem: the extracted frames are deleted as soon as analysis finishes, so
any field not written at record time is gone for that swing permanently. Swings
were being recorded with no frame rate, no golfer, no sitting, no handedness, no
quality signal, and no trajectory data — a log, not a corpus.

- **Capture context per record**: frame rate and frame count, handedness, pose
  coverage, and the per-frame trajectory arrays (~10 KB/swing). The arrays are
  the important one: they let a stored swing be re-measured offline at any
  threshold *and any window basis*, which is what makes the frame-count window
  divergence (see Architecture Notes) retrospectively fixable instead of a
  reason to discard everything collected before P0.2.
- **Grouping**: an anonymous local `participant_id` (no account) and a
  `capture_session_id` minted per app run. The latter is what yields P0.1's
  within-session repeats from ordinary beta use.
- **Measurement basis stamps**: derived `value_basis` and `threshold_basis`
  hashes per record, built to the spec in Practice Focus below, so records
  written before and after a recalibration are identifiably incomparable.
  ⚠️ One drift hazard: the window constants are inline literals in `faults.dart`,
  so the basis **mirrors** rather than imports them. P0.2 rewrites those windows
  anyway — name them there and import them here at the same time.
- **Calibration swings**: `swing_kind` (natural | calibration) plus the fault
  being deliberately exaggerated, so labelled positive controls are not counted
  among natural swings when computing a false-positive rate.
- **Coach self-report** on the participant record (not per swing): has a coach
  identified this fault in you? A weak prior for validation, never a verdict;
  unanswered stays null so "not asked" never reads as "no".
- **Durability**: storage moved to append-only JSON Lines with corrupt-file
  recovery and atomic whole-file rewrites, ported from `_read_history` /
  `save_session` in `src/swing_history.py`. This closes a bug where a corrupt
  history made every future write fail silently — a tester could contribute
  zero swings, permanently, with nothing surfaced.
- **Manual export** via the system share sheet. No backend, no upload.

**Still open after Phase 0:**
- **Off-device collection.** Manual export is the floor, not the answer; exit
  criterion 1 still needs a real path.
- **Video retention.** Not done, and a deliberate open question — without it no
  stored swing can be hand-labelled, so ground truth has to come from elsewhere.
  Carries storage, consent and privacy decisions that are not the app's to make
  unilaterally.
- **Left-handed golfers on the Python side.** The app now asks and records
  handedness, but `HANDEDNESS` in `src/swing_phases.py` is still a module
  constant imported by six call sites including the GolfDB harness. See P0.3.
- **Python↔Dart record-shape divergence.** The Dart store now writes JSON Lines
  with capture-context fields the Python `{"sessions": [...]}` document has no
  counterpart for. Field names are kept snake_case and aligned where they
  overlap, so a converter stays trivial, but the two files are no longer
  interchangeable. See the note on A1 in `AUDIT.md`.

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

**Repeated swings — measure the noise floor (corpus composition, not a per-clip rule).** Every "did this fault change?" judgment — the verification loop, and any persistent-focus *staleness* signal — rests on the measurement noise floor, which the codebase does **not** currently know. The `FAULT_FORMATS` epsilon (~0.005) that reads like a noise threshold is actually *display rounding* (half the last shown digit), far below true noise; building a change/staleness criterion on it fails in the dangerous direction — it flags noise as real movement constantly. P0.1 is the first chance to measure the real floor, and it takes two kinds of repeats:
- **≥ 5 swings per subject in one session** → *within-session* variance (pose/detection noise + swing-to-swing execution). This is the lower bound and the minimum.
- **2–3 subjects re-recorded across ≥ 2 sessions, a few days apart**, same protocol, no intended swing change → *between-session* variance, which adds camera re-setup and day-to-day physiological drift. This is the noise change-detection actually fights; within-session alone understates it. "A few days" is the honest middle — next-day and three-weeks-later carry different amounts of drift.

Consequence for whoever builds staleness/change-detection: make the noise floor an **explicit, unset parameter that refuses to run** until P0.1 supplies it — never default to the rounding epsilon. Over an *n*-session window, noise scales ~`floor · sqrt(n)` if hops were independent; they are not (same golfer, correlated errors), so treat sqrt(n) as an optimistic starting point to be validated against these repeats.

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

**Second GolfDB failure population (slow-mo) — driver identified: under-smoothing.** GolfDB slow-mo clips have a separate, larger Top-failure population (17%) with `corr(|Top err|, pre-address) ≈ 0`, so the onset *bound* (Bug B) does not fix it. Its driver: slow-mo swings span ~8× more frames, so a fixed-duration `SMOOTH_WINDOW_S` covers ~8× less of the swing and under-smooths, letting spurious peaks through (the P0.3 smoothing lesson again). Evidence: within slow-mo, failures track low clarity (`corr = −0.26`; the *pooled* −0.06 was a pooling artifact — real-time failures aren't clarity-driven), and smooth=1→5 helps slow-mo ~4× more than real-time. This is **largely a cross-fps validation artifact, not a production bug** — production is fixed ≥120 fps, so every swing spans a similar frame count and the fixed-duration kernel is already a roughly fixed *fraction* of the swing. It matters here only for reading the GolfDB slow-mo tail correctly. If variable-fps input ever becomes real, the fix is a **swing-duration-relative kernel** — a *third* thing `detect_address_onset()` enables (you can't compute swing duration until you know where the swing starts). Do not bundle it into P0.2's core (Bug A + Bug B); note it as the same function's third consumer.

**Clarity, corrected:** the clarity *gate* is retired (dropping clips is the wrong response), but "clarity measured nothing" was itself a pooling artifact — clarity predicts the slow-mo under-smoothing failures (`r = −0.26` within group). Retire the gate; keep the diagnostic. Do not re-propose clarity as a gate.

#### P0.3 — fps windowing refactor ✅ DONE
- Window constants converted from hard-coded frame counts to durations (`SMOOTH_WINDOW_S`, `IMPACT_RADIUS_S`, `ADDRESS_OFFSET_S`, `DEFAULT_RADIUS_S`) resolved via `frames_for(seconds, fps)`; behavior-preserving at `BASELINE_FPS = 240` (all 24 windowing characterization tests unchanged; verified the suite catches a perturbed constant).
- Remaining seam: `main()` still uses container fps and pins windowing to `BASELINE_FPS`. When P0.1 lands a `capture_fps` metadata field per video (defaulting to `CAP_PROP_FPS` when they agree), thread it into `detect_phases`/detectors — that is the point where slow-mo vs real-time stops being a hidden variable.
- **Left-handed golfers**: `HANDEDNESS` is a module constant with no per-run override — lefties are analyzed on the trail wrist (garbage phases). Parameterize before admitting lefties to the corpus.

#### P0.4 — The Python threshold tests are vacuous — audit before recalibrating (2026-07-31)

**`tests/test_faults.py` cannot detect a threshold change. This is measured, not suspected.** All four constants were mutated at once — `SWAY_THRESHOLD` 0.13→0.20, `REVERSE_PIVOT_THRESHOLD` 0.12→0.30, `EARLY_EXTENSION_THRESHOLD` 0.10→0.40, `POSTURE_THRESHOLD` 12.0→30.0, i.e. up to **3×** — and the suite stayed green:

```
=== pre-existing tests/test_faults.py AFTER mutation ===
10 passed in 0.65s
```

**Mechanism.** Every boundary probe is computed *from* the constant it is supposed to pin (`tests/test_faults.py:60-62`):

```python
below = (SWAY_THRESHOLD - 0.01) * SCALE   # 0.12 * 100
res = _head(below)
assert res['lateral'] == pytest.approx(SWAY_THRESHOLD - 0.01)
```

Both the input *and* the expected value are derived from the threshold, so they slide together when it moves. The test reads as "0.12 does not flag, 0.14 does," but it actually asserts "`threshold - 0.01` does not flag, `threshold + 0.01` does" — true by construction for **any** threshold, including a badly wrong one. The probe never sits at a fixed point; it re-centers on whatever the constant currently is.

**Why this blocks P0.** Recalibration's entire purpose is to change these constants. A green suite afterwards is not evidence the detectors still behave correctly — it is guaranteed in advance. Do not treat `tests/test_faults.py` as a safety net during the P0.2 recalibration; right now it is a net with no strings.

**P0.3 already got this right — copy that discipline.** The fps windowing refactor explicitly "verified the suite catches a perturbed constant" (see P0.3 above). That one verification step is exactly what the threshold tests never had. Any threshold work should end with the same check.

**The Dart side is already structurally correct, and is the model to copy.** `flutter_app/test/faults_test.dart:23-40` places its probes at fixed absolute values — `setRange(headX, 28, 32, 20)`, i.e. 0.20 torso-lengths, asserted with `closeTo(0.20, 1e-9)` — and mentions the threshold only in a comment. Move `swayThreshold` to 0.20 and that test goes red, correctly. (Checked for sway and early extension; the rest of the Dart suite was not audited.) This is one of the rare places where the port is in better shape than the Python source of truth.

**The fix is structural, not more coverage.** Boundary probes must be **fixed absolute values placed on the decision boundary by a human**, never expressions in terms of the threshold. Do not attempt to repair this by tightening epsilons or adding cases — that leaves the defect untouched. When a threshold then moves, the test fails loudly, and a human decides whether the new behavior is right and updates the expected values deliberately. That failure *is* the feature.

**Boundary convention, stated once so it stops being rediscovered per-detector: a value landing EXACTLY on a boundary falls on the no-action side.** Every verdict-producing comparison in `src/` is strict, without exception:

```
src/faults.py:113    'sway_flagged': lateral > sway_threshold
src/faults.py:114    'dip_flagged':  vertical > dip_threshold
src/faults.py:115    'flagged':      lateral > sway_threshold
src/faults.py:144    'flagged':      reverse > threshold
src/faults.py:169    'flagged':      rise > threshold
src/faults.py:193    'flagged':      (tilt_addr - tilt_impact) > threshold
src/body_angles.py:38-39   a > 90 / a < -90        (the _fold wrap)
```

So a metric exactly at its threshold is specified as **not** flagged, and an angle of exactly ±90 is specified as **not** folded. These read as two unrelated quirks — the fault-detector equality case and the `_fold` order-independence bug (see Architecture Notes) — but they are one convention appearing twice, and the second one is where it produces a documented defect.

**Nothing tests exact equality anywhere.** Not `tests/test_faults.py` (its probes are at `threshold ± 0.01`), not `tests/test_body_angles.py`. The boundary is the one input where a strict-vs-inclusive slip is invisible to the entire suite. The red scaffold on `scaffold/fault-threshold-boundaries` targets exactly this gap for the four detectors.

The `>=` comparisons elsewhere in `src/` are a different kind and are not counter-examples: they are tie-breaks and bounds guards (`faults.py:139` `hip_fin >= hip_addr` resolving the static-hip tie to `+1.0`, `faults.py:348` `len(path) >= 2`, the `swing_phases.py` fps/window guards), not verdicts. The `faults.py:139` tie-break is the one place equality is deliberately resolved to the positive side, and it is itself unverified — confirm it is intended when recalibrating, because it decides which way "toward target" points.

**Method, for whoever redoes this audit:** mutate a constant in `src/faults.py`, run pytest, confirm the suite goes red, restore the constant. If it stays green, the test is vacuous. This same property was independently reproduced in a generated characterization file during a sub-agent probe; that file was deleted and the finding above rests on `tests/test_faults.py` alone, which predates it.

### P1 — Flutter Device Testing
**Status**: In progress — app installed via TestFlight 2026-08-17, first finding below
**Goal**: Validate the mobile experience end-to-end on a real device.

- Run `flutter create .` to generate platform folders, then `python3 tool/configure_ios.py` (never hand-edit `ios/` — see below)
- Record a real swing and run the full pipeline
- Compare ML Kit pose quality against MediaPipe heavy model — numbers may shift
- Profile frame extraction and analysis time — is the user waiting too long?
- Test on both iOS and Android if possible
- Address any ML Kit keypoint accuracy issues (may need threshold adjustments for mobile)

#### P1.1 — The app cannot say "that wasn't a swing" (found on device 2026-08-17)

**First real device test, first finding.** A video of *nothing* — no golfer, no
swing — produced a complete report: a `POSSIBLE` head-sway verdict at 0.44
torso-lengths against a 0.13 reference, a tempo breakdown, and three
recommended drills. Nothing in the app expressed doubt that a swing existed.

This is **not a threshold problem**. It is a missing precondition, and no
amount of P0.1 recalibration touches it: a detector tuned perfectly still has
nothing to say about input that contains no swing.

**The chain, as it stands:**

1. **Pose confidence is never read.** `pose_estimator.dart` rejects a frame only
   when `poses.isEmpty` or a required landmark is `null`. ML Kit emits all 33
   landmarks *with a `likelihood` score* even when it is guessing, so landmarks
   are essentially never null once any pose is returned. Grepping `lib/` for
   `likelihood|confidence` returns **zero hits** — the one signal separating "a
   person is here" from "a person has been invented" is discarded at the source.
2. **Phase detection's only precondition is two frames.** `swing_phases.dart`:
   `if (goodCount < 2) return null`. After that `fillNaNLinear` interpolates
   gaps into a smooth curve, and `top` / `impact` / `finish` / `takeaway` are
   `argMax`/`argMin` over slices — which **always return an index**. So
   `detectPhases` effectively never returns null, and the
   "Could not detect swing phases" path in `swing_analyzer.dart` is close to
   unreachable in practice.
3. **The reported tempo proves it fired on noise.** Backswing 0.20 s (6 frames),
   downswing 1.94 s (58 frames), ratio **0.1 : 1**. A golf swing runs about
   **3 : 1** the other way. The detected downswing was ten times the backswing —
   not a bad swing, not a swing.

**Why this can be fixed before P0.1, unlike the fault thresholds.** "Is there a
swing at all" is a categorically different question from "is this sway 0.13 or
0.11", and two gates carry no calibration debt:

- **ML Kit's own `likelihood`** — the detector's self-assessment, not a
  golf-domain constant invented by us.
- **Physical plausibility of the detected phases** — a backswing shorter than
  its downswing is impossible at any frame rate, whatever the corpus later says
  about sway. Same for phase indices that collapse together.

Do **not** let this become a back door for guessed fault thresholds. The gate
answers presence, not severity; if a proposed check needs a number that only
the corpus can supply, it belongs in P0.2, not here.

**Related defect — the tempo caveat is keyed on the wrong variable.**
`report_screen.dart`'s `_tempoCaveat` branches on **fps alone**, so below 120 fps
it always prints "the downswing spans only a few frames". On this report the
detected downswing was **58 frames**. The hedge describes a condition that is
not true, which spends credibility exactly where the user most needs to trust
it. It should key on the detected frame counts, not the capture rate.

**What did work**, and is worth not re-testing: the camera permission prompt
appeared with its usage string (the failure no compile check could catch, and
the patcher's whole reason for existing), the full pipeline ran on-device
(capture → ffmpeg extraction → ML Kit pose → phases → faults → drills), and the
beta banner rendered and hedged accurately. The banner is not a substitute for
this gate, though: it qualifies *precision*, and the claim needed here is about
the *input*.

**iOS compile gate (added 2026-08-04)** — `.github/workflows/ios-build.yml`
builds iOS unsigned on a GitHub Actions `macos-latest` runner, so iOS
compilation is verified from Windows without Apple hardware.

**`ios/` is gitignored and regenerated on every run, so nothing under it can
be committed.** Every value the generated tree needs therefore lives in one
post-generate patcher — `flutter_app/tool/configure_ios.py`, run between
`flutter create` and `pod install`, landed 2026-08-09 (replacing the inline
`sed`/`grep` steps). It owns the **15.5** deployment target (the floor
`google_mlkit_commons` requires — `pod install` fails outright below it) in
both `project.pbxproj` and the `Podfile`, and `NSCameraUsageDescription` in
`Info.plist`. Adding an iOS-side value means extending that script; there is
no other place to put it.

**The design rule the script is built on: a patch that quietly does nothing
produces a green build that crashes on device, so silence is never success.**
Every patch re-reads its file from disk and fails the run unless the value
actually landed. Two specifics worth not re-deriving:

- **Idempotency is free for the plist half and earned for the pbxproj half.**
  `plist[KEY] = VALUE` is an assignment into a keyed structure the parser
  already normalized — same result on the first run and the fifth, no
  already-present branch, no duplicate key possible. `re.subn()` gets no such
  guarantee: it rewrites bytes with no model of the file, so idempotency holds
  only because the substitution pattern is written to *exclude its own
  output* (it matches a bare numeric version, and emits `15.5`; a second pass
  finds `15.5` and rewrites it to itself). That is a property of the pattern,
  not of the method — widen it to accept what it emits and reruns start
  stacking. The Podfile pattern buys the same property differently: it matches
  the line commented, active, at any version, so every state converges on one
  active line.
- **The check must not share the operation's blind spots.** Counting uses a
  *wider* pattern than substituting (`([^;]+);` vs `[\d.]+;`), so a value the
  script cannot rewrite — a quoted `"13.0"`, an `$(inherited)` — surfaces as
  stale instead of disappearing from numerator and denominator at once. This
  is not hypothetical caution: the shipped `grep -q` guard it replaced passed
  with 1 of 3 build configurations still on 13.0, because `grep -q` returns 0
  on the first match.

**The Podfile patch is conditional, and only its absence is (2026-08-16).**
`flutter create` generates a Podfile only when the host has a working Xcode —
`flutter_tools/lib/src/macos/cocoapods.dart` returns early from `setupPodfile()`
otherwise. Measured, not assumed: `flutter create --platforms=ios` on Linux with
the pinned SDK emits `Flutter/ Runner/ Runner.xcodeproj/ Runner.xcworkspace/
RunnerTests/` and **no Podfile**, and `flutter pub get` does not add one. So the
script's original unconditional Podfile requirement made its own documented
local workflow (`README.md`, and its docstring's "locally or in CI") exit 1 on
every Windows run. It was never caught because it had only been exercised
against a *copy of a Mac-generated tree*, which carries a Podfile.

The gate mirrors Flutter's own probe rather than approximating it: macOS **and**
`/usr/bin/xcodebuild` exists **and** `xcodebuild -version` parses. `which
xcodebuild` would be wrong — on a Command-Line-Tools-only Mac the shim is on
PATH but `-version` fails, and Flutter reads Xcode as absent. Predicting
Flutter's behaviour means running Flutter's check.

Note which way the condition points: **presence** decides whether the Podfile is
patched, **absence** is what gets judged against the host. A Mac-generated tree
copied to Windows still gets its Podfile patched. A missing Podfile on a host
with Xcode — CI — is still fatal, so the guarantee is untouched where the build
happens. And a skipped run still names the Podfile as unpatched in its summary
line: a partial run must never read as a configured tree, which is the same
silence-as-success hazard one level up.

**Narrowed gap.** CI now proves `NSCameraUsageDescription` is present in the
`Info.plist` it builds. What it still cannot prove is that the app *runs* —
a permission string can be present and wrong, and no compile check exercises
the camera at all. Verify by hand on the first running build. **A green CI
run proves the code compiles, not that the app runs.**

**Device path unblocked (2026-08-16).** Apple Developer Program enrollment is
complete ($99/yr), which makes the user's own iPhone a stable TestFlight
target and takes MacInCloud off the table. The deployment path is the existing
Actions pipeline → sign + upload → TestFlight → phone; no Mac at the desk.

**Increment two — split 2a / 2b by the same verification rule.** Manual signing
was chosen over `-allowProvisioningUpdates` (2026-08-16): an ephemeral runner
with an empty keychain risks exhausting Apple's small distribution-certificate
cap, and that failure arrives slowly, long after the pipeline looks healthy.

- **2a — the patcher's tree changes. Locally provable, landed.** Bundle
  identifier, `ITSAppUsesNonExemptEncryption`, and the signing xcconfig block.
  All verifiable against a generated tree on any host, exactly as increment one
  was, so they do not wait on secrets or on Apple.
- **2b — the workflow's signing and upload. Runner-only. ✅ WORKING
  2026-08-17.** `.github/workflows/ios-release.yml`: keychain import of the
  `.p12`, provisioning-profile install, signed `flutter build ipa
  --build-number=${{ github.run_number }}` (TestFlight permanently rejects a
  repeated build number), and upload via `altool` — behind `workflow_dispatch`
  so it never fires on a PR. First successful upload: run `32000315770`,
  61.9 MB IPA accepted by App Store Connect.

Splitting here is the same rule that put the Podfile gate on its own commit: an
increment is bounded by what its verification can actually prove.

**What 2b's three failures cost, and what they have in common.** Every one was
a difference between this container and the runner that no local check could
have caught — which is the entire argument for having split it out rather than
shipping it with 2a.

1. **xcconfig comments are `//`, not `#`.** `#` introduces a preprocessor
   directive, so the managed block's delimiters archived as `unsupported
   preprocessor directive '>>>'`. The file was written byte-for-byte as
   intended; the intent was wrong, and no post-condition comparing output to
   intent can catch that.
2. **BSD vs GNU `base64`.** GNU refuses to decode raw PEM (exit 1, zero bytes),
   which under `set -euo pipefail` would have aborted the step here. macOS's
   BSD `base64` exited 0 and passed garbage downstream. Same command, different
   tolerance; only the lenient one reaches a confusing error.
3. **The API-key secret can arrive in three forms** and altool accepts one.
   Raw PEM, base64-of-PEM, and — the trap — the `.p8`'s base64 **body** with
   its armor lines stripped, which is valid base64 that decodes to ~150 bytes
   of valid DER that no PEM parser will read. All three are now normalised.

**The transferable lesson: prove each input before the tool that consumes it.**
altool reads two files and reports both failures identically ("The file
couldn't be opened because it isn't in the correct format. (259)"), naming
neither. Adding a per-input check turned one ambiguous error into a named
cause on the very next run. Any step that hands several artefacts to one opaque
tool wants the same treatment.

**The rule that decides what goes in which increment: an increment is bounded
by what its verification can actually prove.** Increment one's property was
"provable locally before pushing"; signing's is "only provable on the runner."
That is why the Podfile gate above landed on its own, ahead of signing (locally
provable, and a prerequisite for developing signing on a non-Mac host), and why
these belong to increment two:

- **`PRODUCT_BUNDLE_IDENTIFIER` rewrite.** Measured against the pinned SDK: the
  generated tree emits `com.example.golfSwingAnalyzer` — camelCased, not
  flattened — in **six** places, as **two** shapes (3 × app, 3 ×
  `…​.RunnerTests`, the test target's being a derived suffix). The post-condition
  must assert 3 and 3 *separately*; a single count of 6 would pass even if the
  two identifiers collapsed into one, which is an invalid project. Register
  `io.github.floresgl1.golfSwingAnalyzer` — **not** the underscore form: Apple
  specifies bundle IDs as alphanumerics, hyphens and periods, and an App ID
  cannot be renamed after creation. Unverifiable until something signs against
  a profile expecting it, hence increment two.
- **`ITSAppUsesNonExemptEncryption`.** Structurally it is a plist key like the
  camera one; temporally it is TestFlight's. Its presence is trivially
  assertable and that assertion proves nothing about its purpose — there is no
  upload for it to unblock yet — so landing it in increment one would let it be
  marked verified on evidence that does not bear on it. It is also a compliance
  *declaration*, not a config toggle, and belongs next to the submission work
  that motivates it rather than inside a camera-permission commit.
- **Signing goes in the xcconfig, NOT the pbxproj** (corrects an earlier note in
  this file). The generated project's three `CODE_SIGN_STYLE = Automatic`
  entries belong to **RunnerTests**, which `flutter build ipa` never archives.
  The **Runner app target carries no signing settings at all**, in any of Debug
  / Release / Profile — measured per-configuration against the pinned SDK. With
  nothing at target level to override it, project-level xcconfig applies
  cleanly, so all four settings are written as a delimited managed block in
  `ios/Flutter/Release.xcconfig` (one line, `#include "Generated.xcconfig"`, in
  the generated tree). No surgical insertion into a NeXTSTEP plist, and the
  "you cannot count what was never there" problem never arises.
  Idempotency comes from *replacing* the delimited block, never appending —
  xcconfig takes the **last** assignment, so a stacked block would let stale
  values win silently. The post-condition is anchored to the whole file rather
  than the block for the same reason: an assignment placed after the block
  would win, and must fail the check.
- **Build numbering.** `pubspec.yaml` is at `0.1.0+1` and TestFlight
  permanently rejects a repeated build number; derive it from
  `github.run_number` rather than committing bumps.

The camera half is landed and green (run on `main` @ `067cab2`).

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

### Practice Focus (persistent) — makes the existing focus-fault legible; fixes a real bug

**Gating (read first):** buildable only *after* **P0.1** supplies the measurement noise floor (staleness has no valid threshold without it) and **P0.2** establishes the measurement-version boundary (trends can't cross it). Do NOT pick this up as a UI task and build the mechanism without the calibration — that reproduces exactly the "looks calibrated, isn't" failure this design exists to avoid.

**The bug this fixes (not just a feature).** The current focus-fault silently loses itself after one session: `targeting` defaults to `None` every run and `print_comparison` reads it from the *previous* session only, so forgetting the CLI arg once drops your focus with no signal. "Persistent focus is nicer UX" is arguable; "the model drops your focus if you forget an argument once" is a bug, and the fix and the feature are the same change.

**Scope.** The pick drives **drill filtering (prioritize, not hide)** and **result emphasis (highlight the focus, never filter out other detections)**, and **persists in swing history** alongside the measurements. It never touches detection or thresholds. Buildable with no schema change (the per-session `targeting` field already records declarations).

**Design decisions that look arbitrary cold but each have a reason — do not "simplify" these away:**
- **Reject user-set sensitivity (Interpretation B) — permanently, not just until P0.2.** A per-fault sensitivity slider corrupts the verification loop in a way recalibration *cannot* fix: a threshold crossing ("fault fixed!") becomes unattributable — the user can't tell whether their swing changed or they nudged the slider. That's a feature that lies. It's also redundant (the per-fault *value* is already shown every session, flagged or not). Someone will propose sensitivity again; this is why the answer is no.
- **The measurement basis-stamp is DERIVED (hash of output-affecting params), not a manual integer.** A hand-incremented version depends on a human remembering to bump it on every threshold/window change; the first person to touch it "simplifies" it to an integer and it silently stops tracking. Hash **only** params that affect output (window sizes, the four thresholds, an algo-version) — never cosmetic ones (formatting, log verbosity), or you invalidate trends for changes that moved no measurement and lose history for nothing. Split **value-basis** from **threshold-basis**: a threshold-only recalibration resets *crossings* but not *value trends*; a window change (P0.2) resets both.
- **The `FAULT_FORMATS` epsilon is NOT the noise floor.** It is display rounding (half the last shown digit, ~0.005), far below true measurement noise. Reusing it *looks* like reuse but is a mistake that fails dangerously — it flags noise as real movement constantly. The floor is an explicit parameter measured by P0.1's repeated swings; the mechanism must **refuse to run** until it's set, never default to the epsilon. Window noise scales ~`floor·sqrt(n)` over *n* sessions only if hops are independent (they aren't — same golfer, correlated errors), so treat sqrt(n) as an optimistic start to validate against the corpus.
- **CLEARED is an explicit sentinel; INHERIT is absence.** Looks asymmetric; isn't a mistake. Carry-forward means a missing/`None` `targeting` = *inherit the current focus* (this also makes legacy records read correctly with no migration). "Stop focusing on anything" therefore cannot be expressed by omission — it needs its own explicit marker. This is the one state that can't use the omit-over-magic-string rule, precisely because omission is already taken by inherit.

**Staleness / trend specifics:** trend the focus fault against its *focus-start* session (the headline "total progress since you began") **and** a recent rolling window (the input to staleness — total-since-start goes insensitive to recent plateaus after many sessions). Both, deliberately. All of it built on value-`direction`, never threshold-`crossing`.

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
- **KNOWN DIVERGENCE (intentional, tracked) — the parity rule's one standing exception.** The P0.3 fps windowing refactor (duration-based constants + `frames_for`) is **Python-only**. Python resolves every smoothing/median window from a duration at the capture rate; **Dart still uses hard-coded frame counts** (`takeaway - 10`, `radius: 2`, `radius: 3`, `smooth = 5`, inline literals in `faults.dart` / `swing_phases.dart`).

  This is deliberate — the port is held until the Python side is validated against the corpus (per P0.2), so an unvalidated change isn't mirrored into two codebases. Port `frames_for` + the seconds constants to Dart together with the P0.2 recalibration, not before.

  Now that both codebases live in one tree the divergence is easy to trip over, so state the consequence plainly: **a frame count is a fixed duration only at one frame rate.** The Dart constants were tuned at 240 fps; typical phone capture is 30, so the app measures over roughly 8× longer windows than the thresholds printed beside its numbers assume. The Dart values are therefore not directly comparable to the Python ones on the same clip. Do not "fix" this by changing either side's constants in isolation — that is P0.2's recalibration, and it must move Python first, then Dart, against the corpus.

### Key Design Decisions (do not change without discussion)
- **Eye midpoint** for head tracking (not nose) — rotation-stable proxy
- **Torso-length normalization** for all distance-based faults — resolution/size-independent
- **Median windowing** at address and impact, as durations resolved to frames at the capture rate (`ADDRESS_OFFSET_S`, `IMPACT_RADIUS_S`, `DEFAULT_RADIUS_S`; 10 / 2 / 3 frames at `BASELINE_FPS`=240) — jitter-resistant and frame-rate-invariant. **The address window has a KNOWN ISSUE** (samples into the takeaway motion, not settled address) — see P0.2 and the `swing_phases.py` comment; do not treat the current constant as validated
- **Target direction auto-inferred** from hip translation — works regardless of camera side
- **Lower is always better** for fault values; **tempo uses distance from 3:1** — different semantics
- **Record-then-analyze** flow on mobile (not real-time) — simpler, more accurate

### `_fold` is not order-independent at exactly ±90 — OPEN DECISION (2026-07-31)

**The docstring states an invariant the code does not hold.** `line_angle`'s docstring (`src/body_angles.py:27-28`) says the result is "folded into [-90, 90] so it measures the line's tilt regardless of point order." That holds for every orientation except exactly vertical.

`_fold` (`src/body_angles.py:35-40`) uses strict comparisons:

```python
a = np.where(a > 90, a - 180, a)
a = np.where(a < -90, a + 180, a)
```

Exactly `-90.0` is not `< -90`, and exactly `+90.0` is not `> 90`, so neither is folded. A line and its reverse differ by 180°, so a vertical line gives two answers that disagree:

```
line_angle((0,0), (0,10))  == -90.0
line_angle((0,10), (0,0))  == +90.0
```

Both values are already inside `[-90, 90]`, so both survive the fold unchanged. Every other orientation is fine — at `-89.9` the reverse is `+90.1`, which *does* fold back to `-89.9`. The defect is the boundary itself, not a general near-vertical instability.

**Scope — narrower than it looks; read this before prioritizing it.** The reported angles are unaffected. The shoulder/hip numbers that get printed and analyzed (`src/body_angles.py:119-130`) come from `smooth_line_angles`, which never calls `_fold` — it squares the complex line vector, so the 180° wrap is handled correctly by construction. `_fold` is reached only by (a) the scalar `line_angle` helper and (b) `raw_shoulder` / `raw_hip` (`:117-118`), which are drawn as faint reference traces on the plot (`:135-136`) and never measured against. It also requires `dx` to be exactly `0.0`. This is an API-contract bug, not a live measurement bug.

**The open decision (the human's to make):**

1. **Fold at the boundary** — make one comparison inclusive (`>= 90` or `<= -90`) so a vertical line and its reverse agree, and the docstring's claim becomes unconditional. This picks a winner between `-90.0` and `+90.0`; the choice is arbitrary but must be documented, and it flips the sign of the raw plot traces on exactly-vertical frames.
2. **Weaken the docstring** — record that order-independence holds except at exactly vertical, and leave the code alone. Cheapest, keeps every current output byte-identical, but leaves a sharp edge for any future caller that relies on the invariant.

Do not take option 1 casually. `_fold` is applied to arrays as well as scalars, and `tests/test_body_angles.py:24` already pins `line_angle((0, 0), (0, -1)) == 90.0` — the `+90` side of this very asymmetry. Changing the fold flips that existing assertion.

**A regression guard is already in place, and it is not a verdict.** `tests/test_line_angle.py::test_line_angle_vertical_reversal_is_asymmetric_today` asserts `down != up` deliberately, so the asymmetry cannot change silently. Those tests are CHARACTERIZATION captures: they pin current behavior, not confirmed-correct behavior. When this decision is settled, that test must be rewritten by hand — not deleted.

Two related captures from the same probe, equally unverified: horizontal lines return **signed zero** (`-0.0` left-to-right, `+0.0` right-to-left, invisible to `== 0.0`), and a **degenerate `p1 == p2`** returns `-0.0` rather than `nan` or an exception. In a pose pipeline that second input arises whenever two landmarks collapse onto each other, and silently reading as "level" may not be the behavior you want.

### Testing
- Python: run `python src/faults.py` against test videos, check all four verdicts
- Python: run `python src/swing_phases.py` to verify phase detection and tempo
- Dart: `flutter test` runs unit tests with synthetic swing data that must match Python outputs
- Any threshold change requires re-running against the full test video set

### Commit signing in the container — the stop-hook "Unverified" report

**The report describes a real condition, but the remedy it prints cannot fix it. Do not follow its suggested rebase target.** Both halves matter: dismissing the report as a false alarm is wrong, and so is running the fix it recommends.

**The condition is real.** Commits made in this container carry no signature (`git log --format=%G?` prints `N`), and GitHub does label them Unverified. Signing *is* configured, in `/root/.gitconfig` — `commit.gpgsign=true`, `gpg.format=ssh`, `user.signingkey=/home/claude/.ssh/commit_signing_key.pub` — but the key material is absent: the public key is a 0-byte file and the matching private key does not exist. Nothing in the container can produce a signature.

**The remedy cannot work.** The hook suggests setting `user.email`, then `git commit --amend --no-edit --reset-author` (or `git rebase --exec` for earlier commits). That addresses the *other* condition the hook checks — a committer email that isn't `noreply@anthropic.com` — which is already satisfied here; author and committer are both `Claude <noreply@anthropic.com>`. Amending rewrites authorship and commit hashes; it cannot conjure a key. Run against these commits it yields the identical unsigned result under new hashes, so the hook fires again on the rewritten history.

Two workarounds look tempting and are worse than the problem:
- **Generating a substitute SSH key.** GitHub verifies against keys registered to the account, so a container-made key still shows Unverified — while falsely asserting a signing identity.
- **Setting `commit.gpgsign=false`.** This silences a configured control without producing a single verified commit.

Resolving it for real requires a signing key provisioned in the environment *and* registered on the GitHub account. Once that exists, `git rebase --exec "git commit --amend --no-edit -S" <base>` signs the outstanding commits before push. Until then the badge is expected, and is not a defect in the change under review.
