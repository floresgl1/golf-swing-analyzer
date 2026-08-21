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

#### P0.4 — The Python threshold tests were vacuous — FIXED 2026-08-19

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

**FIXED 2026-08-19.** `tests/test_faults.py` no longer imports the thresholds at all. Each detector is probed with a table of absolute values written out by hand — clearly below, exactly on the boundary, a hair above, clearly above — and the constant it straddles is named only in a comment.

**The vacuity was worse than recorded before it was fixed.** The note above claims `tests/test_faults.py` stayed green under mutation. Re-run on 2026-08-19 with all four constants mutated at once: **the entire suite, 81 tests, stayed green.** No test anywhere in `tests/` could see a 3× threshold change.

**Verified by mutation, one constant at a time** — the step the old file never had. Each threshold was moved and `tests/test_faults.py` re-run:

```
                       sway  dip  reverse  early-ext  posture
downward, 1 ULP        RED   RED  RED      RED        RED
upward, +0.0001        RED   ***  RED      ***        RED
upward, +0.005         RED   RED  RED      RED        RED
upward, 1.5-2.5x       RED    -    -        -         RED
```

The two directions are not symmetric, and the file says so: **any downward move is caught immediately** by the on-boundary probe, because the boundary value starts flagging. An **upward** move is only caught once it clears the nearest above-probe, so probe spacing is the resolution — the suite pins each boundary to within 0.0001, which is a bound, not a guarantee of zero.

`***` marks the one degenerate case, recorded so it is not rediscovered as a bug: moving a threshold to land **exactly** on the hair-above probe value — `EARLY_EXTENSION_THRESHOLD` to 0.1001, `DIP_THRESHOLD` to 0.2501 — stays green, because whether the computed metric compares greater than it is then decided by floating-point rounding inside the detector. The other three go red at the same offset. Anywhere off a probe value the bound holds.

**`DIP_THRESHOLD` had no test of any kind** and is the fifth threshold in `src/faults.py` — the audit above only ever counted four. It is informational rather than a verdict (`flagged` keys on sway alone) but is still printed, so a wrong constant is still a wrong claim shown to a golfer. It now has the same four probes as the rest, plus an assertion that a dip never sets the head-movement fault.

**The equality convention is now tested.** The note below observes that nothing anywhere tested exact equality, which is the one input where a strict-vs-inclusive slip is invisible. Each detector now has an on-boundary probe asserting the value **exactly** (`== 0.13`, not `approx`) and asserting it does not flag. All four probe values divide exactly in IEEE double — 13/100, 12/100, 10/100, and `degrees(atan2(·, 100))` round-tripping 12.0 — so these are exact comparisons, not near-misses.

**Incidental finding, not fixed:** three of the four detectors return a numpy bool for `flagged` and one returns a Python bool, so `is True` fails on three of them. The tests cast with `bool()`; the inconsistency in `src/faults.py` is left alone rather than changed under an unrelated commit.

**The Dart side had the same defect, weaker but real — audited and FIXED 2026-08-19.** The note calling `flutter_app/test/faults_test.dart` "already structurally correct, and the model to copy" was right about *form* and wrong about *strength*. Its probes were absolute, which is the part worth copying. But:

- **Every probe sat far from its boundary.** Sway was probed at 0.20 and 0.05 against a threshold of 0.13, so the constant could move anywhere in `(0.05, 0.20)` — a band 58% as wide as the constant itself — with the suite green. Confirmed by mutation: `swayThreshold` 0.13 → 0.18 was invisible.
- **Only sway had a below-threshold probe at all.** Early extension, loss of posture and reverse pivot had flag-true cases only, so a threshold moved *down* to zero would still have passed.
- **No on-boundary case anywhere**, the same equality gap the Python side had.
- **One derived assertion survived:** `expect(r.reverse, greaterThan(reversePivotThreshold))` — the vacuous form, true for any threshold below the probe.
- **`dipThreshold` was untested here too.**

Rewritten to the same shape as the Python file — four probes per detector, thresholds named only in comments — and verified the same way, by mutating each of the five constants and re-running `flutter test`:

```
                       sway  dip  reverse  early-ext  posture
downward, 1 ULP        RED   RED  RED      RED        RED
upward, +0.0001        RED   ***  RED      RED        ***
upward, +0.005 .. 2x   RED    -    -       RED        RED
old blind spot (0.18)  RED    -    -        -          -
```

97 Dart tests pass; `flutter analyze` is clean on the file.

Not a parity divergence to reconcile: probe values are test inputs, not detector constants, so the byte-parallel rule does not apply. The two suites agree on discipline, not on numbers.

**A real (if tiny) numerical divergence surfaced while doing it.** The degenerate `***` case lands on *different detectors* in each language — Python is blind at early extension and catches posture; Dart is the reverse. Cause: Python computes `math.degrees(x)`, Dart computes `x * 180.0 / math.pi`, and the two round differently in the last place. Measured at a 12.001-degree tilt:

```
python  straighten = 12.001
dart    straighten = 12.001000000000001
```

One ULP. It cannot change a verdict on any real swing — a golfer's spine angle is not measured to 15 significant figures — so this is recorded rather than fixed, so that the parity checker does not flag it as drift and a future session does not rediscover it.

**Still open in P0.4:** `faults.py:139`'s `hip_fin >= hip_addr` tie-break — the one place equality resolves to the positive side, and the thing that decides which way "toward target" points — is still unverified, and `_fold`'s ±90 boundary (Architecture Notes) is still untested. Both are equality-convention gaps of the same family.

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

**Related defect — the tempo caveat was keyed on the wrong variable. FIXED 2026-08-19.**
`report_screen.dart`'s `_tempoCaveat` branched on **fps alone**, so below 120 fps
it always printed "the downswing spans only a few frames". On this report the
detected downswing was **58 frames**. The hedge described a condition that was
not true, which spends credibility exactly where the user most needs to trust
it.

It now keys on the frames the phases actually span, and rather than grading the
swing against an invented cutoff it **states the precision it has**:
`tempoRatioPrecision()` in `swing_phases.dart` returns
`(1/backswing + 1/downswing) * ratio` — the events are located to the nearest
frame, so each duration carries about a frame of slack, and relative errors add
across a quotient. **No constant, and nothing borrowed from P0.1:** this is the
arithmetic of counting in frames, not a judgement about golf.

What the golfer now reads:

```
device 2026-08-17 (6 up, 58 down, 30fps)   ... within about 0.02 either way.
a real swing      (27 up, 9 down, 30fps)   ... within about 0.4 either way.
a 240fps swing    (216 up, 72 down)        ... within about 0.06 either way.
```

The middle row is the case the old hedge was reaching for and never actually
detected; the first is the case it got wrong. Note the ordering is not by frame
rate — the 30fps swing with a real downswing is the *least* precise of the
three, which is exactly why keying on fps could not work.

The number is printed at whatever precision it actually has and is never
rounded up to a friendlier figure. A first draft of this clamped anything under
0.1 up to "0.1"; overstating uncertainty is a smaller lie than understating it,
but it is still a lie, and it was removed before commit.

App-only: Python prints full verdicts and has no equivalent hedge, so there is
nothing to port and this is not a parity divergence. Verified by mutating the
precision formula three ways — all three go red.

**What did work**, and is worth not re-testing: the camera permission prompt
appeared with its usage string (the failure no compile check could catch, and
the patcher's whole reason for existing), the full pipeline ran on-device
(capture → ffmpeg extraction → ML Kit pose → phases → faults → drills), and the
beta banner rendered and hedged accurately. The banner is not a substitute for
this gate, though: it qualifies *precision*, and the claim needed here is about
the *input*.

#### P1.2 — Corpus export was broken on iOS, blocking P0.1 (fixed 2026-08-17)

**This was a P0.1 blocker, not a UI annoyance.** Export is the *only* way swings
leave the device — no backend, no account, by design — so while it failed, the
corpus P0.1 depends on could not be collected at all. Found the first time
anyone pressed the button on a real phone:

```
Export failed: PlatformException(error, sharePositionOrigin: argument must be
set, {{0, 0}, {0, 0}} must be non-zero and within coordinate space of source
view: {{0, 0}, {430, 932}})
```

`UIActivityViewController` is a popover on iPad and must be anchored, and
share_plus enforces that on **every** iOS device: a null or zero-sized origin
fails the entire export. `CorpusExporter.share()` had always accepted a
`Rect? sharePositionOrigin` — the plumbing was there from the start — and
`profile_screen.dart` simply never passed one. The parameter existed, was
optional, and defaulted to the one value iOS rejects.

Fixed by anchoring to the export button via a `GlobalKey`, which is also the
correct iPad behaviour: the popover should point at the control that was tapped.
`shareOriginOrFallback` guarantees the result is never degenerate, since both
`null` and `Rect.zero` are rejected.

**Why no test caught it and what now does.** The failure lives in the gap
between an optional Dart parameter and a platform requirement — nothing in the
Dart type system objects to omitting it, and no unit test exercises UIKit. The
boundary rule was therefore extracted into a pure function so it *is* testable,
and verified non-vacuous by mutation: making the fallback return `Rect.zero`
turns the test red, and reverting the caller to `share()` trips `flutter
analyze` with an unused `_shareOrigin`. Neither is a substitute for pressing the
button on a phone.

**The transferable lesson: an optional parameter that a platform requires is a
required parameter with a bug in it.** Worth a look wherever else the app hands
something to a plugin with a nullable positional or named argument.

**It took four builds, and two more failures behind it (2026-08-17).** The
anchor fix above was necessary and not sufficient:

1. **Containment, not just non-emptiness.** `CGRectContainsRect(controller.view.frame, origin)`
   is a second condition, and a button inside a scrolled list can have a
   non-empty rect that still extends past the screen edge. The origin is now
   intersected with the screen, making containment true by construction.
2. **iOS silently dropped the `.jsonl` attachment.** With the share sheet
   finally opening, `participant.json` transferred every time and
   `swing_history.jsonl` never did — twice, with no error, while the sheet's
   own text said "5 swings". iOS classifies attachments by type and `.jsonl`
   has no registered one, so the exporter now declares `text/plain` for it.

**Three of those four builds were spent on a phone running none of the code.**
"Released" and "installed" are different claims, and the message format was
what eventually proved it — the diagnostic build printed extra lines the device
never showed. **Do not debug a device report without first establishing which
build produced it.** A visible build number in the app would have saved most of
this.

**Consequence: the share sheet is no longer the only way out.** The patcher now
sets `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, so the
corpus appears under Files → On My iPhone → the app. That path depends on
nothing but the filesystem. The share sheet remains, but a corpus P0.1 cannot
proceed without should not have a single route off the device, and that route
should not be the one with four builds of platform quirks behind it.

#### P1.3 — `detect_phases` does not find the swing in a real phone clip (2026-08-17)

**The first five real recordings are off the device, and they invalidate more
than the gate.** Replaying `detect_phases` on the stored per-frame `wrist_y`:

```
#   clip_s  cover  take   top   imp   fin  back  down  ratio
1      5.6   0.61     0     4    63   138     4    59  0.068   <- clip of nothing
2     16.0   0.81     0     1   443   456     1   442  0.002
3     15.4   0.73     0    15    66   412    15    51  0.294
4     16.3   0.62     0   130   265   474   130   135  0.963
5     18.5   0.79     0     8   526   540     8   518  0.015
```

**`top` lands at frame 1, 4, 8, 15 of a 15-18 second clip.** The detector is not
finding the swing; it locks onto incidental hand movement during setup, because
`top` is "the first peak clearing half the height range" and a 16-second clip is
overwhelmingly not-swing. Every fault value in those reports — the 0.44 head
sway included — was measured between meaningless anchors.

**Consequence 1: the tempo-inversion gate is removed.** It rejected 3 of the 4
genuine swings. It assumed the detected phases meant something; on real clips
they do not, so a ratio below 1:1 says the *detector* failed, not that the
input lacked a swing. The zero-duration checks stay — those are still
impossibilities. The five recordings above are pinned as regression tests in
both suites; reinstating the tempo check turns all four real-swing tests red.

**Consequence 2: there is currently NO valid presence signal, so P1.1 is open
again.** A clip of nothing still produces a full report. Note `pose_coverage`
cannot substitute: the nothing-clip scored **0.61** against 0.62-0.81 for real
swings — ML Kit found a "person" in 61% of frames of nothing, and the ranges
overlap. The upstream likelihood gate (option A) would not have separated these
either.

**Consequence 3: capture length is a first-class variable.** A golf swing is
1-2 seconds; these clips are 15-18. Until phase location is fixed, the cheapest
mitigation is recording only the swing — start just before, stop just after.
Worth a record-screen prompt regardless.

**This is P0.2's `detect_address_onset()`, arriving from the other direction.**
P0.2 wanted onset detection to fix the fault-baseline anchor and the top search
bound. This is the same function needed to answer "where in this clip is the
swing at all". Do not attempt a separate fix; it is the same work.

**Observed: the held Python/Dart divergence bites on real data.** On recording
4 the app stored `tempo_ratio` 1.512 while Python replaying the same `wrist_y`
gives 0.963 — different smoothing windows (Dart's fixed `smooth = 5` frames vs
Python's duration-based kernel at 29.97 fps) land `top` in different places.
The divergence is documented and held pending P0.2, but this is the first time
it has been seen changing a reported number rather than a theoretical one.

**Corpus status: 5 recordings, one participant, one session.** Not P0.1's
corpus — the spec calls for multiple subjects and repeat sessions — but the
first real data the project has, and the export path that produced it now
works.

#### P1.4 — Swing localization: prototyped, NOT shipped, blocked on ground truth (2026-08-17)

Filming yourself makes a long clip unavoidable: tripod, hit record, walk in,
settle, swing, walk back, stop. **"Record a shorter clip" is not advice anyone
can follow**, so P1.3's failure is a missing capability, not bad input. Remove
that framing from any user-facing guidance.

**The body-speed structure is real and clean.** Speed of the shoulder/hip
midpoint, one character per second, `#`>8 `+`>3 `.`>1 torso-lengths/s:

```
nothing  |######|                 walk only, never settles
swing 1  |######++.++.+###|       walk in | settle+swing | walk back
swing 2  |#####+..++.+####|
swing 3  |#####+...++.+####|
swing 4  |#####+.+...+.++####|
```

**Trimming to the quiet middle is not enough.** It produces the right window
(~5-13 s) and tempo stays inverted, because 8 s is still 5x a swing and
`top = first peak clearing half the range` keeps catching an early hand raise.

**Anchoring on the downswing works much better.** A swing's signature is the
fastest downward wrist motion, not a tall peak. `locate_swing()` in
`src/swing_phases.py` does this and puts the events *inside* the swing on all
five recordings instead of at frame 1. Tempo ratios came out 3.00 / 2.42 /
3.93 / 2.00 in one prototype — the right order of magnitude for real golfers.

**It is not shipped, and here is why.** The answer moves with the smoothing
constant. At `DESCENT_SMOOTH_S` 0.05 s one clip anchors at frame 447; at 0.10 s
the same clip anchors at 272 — six seconds apart. A constant that swings the
answer that far is doing real work, which falsifies the "no calibration debt"
claim its neighbours can make honestly. Two different smoothing choices gave
tempo sets of 3.00/2.42/3.93/2.00 and 1.10/1.93/4.00/2.78, and **the only
reason to prefer the first is that it looks more like golf** — which is
eyeball calibration, the thing P0 exists to prevent.

**Why the ambiguity is real, not a tuning failure.** Counting distinct wrist
drops (>=50% of the largest, >=1 s apart) per clip: **4, 4, 4, 5 events — and
only one clip has a dominant one** (4.07 torso-lengths against ~1.3 for the
rest). Practice swings, waggles and setting down the club all produce drops
comparable to the swing. Choosing among them needs to know which one the
golfer meant.

**A hypothesis worth recording as refuted:** the missing pose frames are *not*
in the swing. Coverage during the swing region is 0.80-0.89, *higher* than the
0.61-0.81 overall; the gaps (up to 3.9 s) are in the walk-in, before the
golfer is in frame. Motion blur at 30 fps is not the problem here.

#### P1.4 — FIRST MEASUREMENT AGAINST LABELS (2026-08-20)

The golfer watched the three retained clips and reported: **"the swings all
start around 7 seconds into each video."** One coarse number per swing, good to
about a second. That is far short of the four precise events, and it settles
more than expected — the errors under measurement are *seconds* wide, so a
one-second label separates a detector that finds the swing from one that finds
the walk-in. Recorded in `labels.json` with its provenance, and scored by
`validation/device_corpus/score.py` against an explicit `--window`, never
against a precision the label does not have.

```
                    detect_phases      locate_swing     label
swing_..._193824.mp4   top 0.47s        top 6.84s       ~7.0s
swing_..._193851.mp4   top 0.17s        top 2.97s       ~7.0s
swing_..._193916.mp4   top 0.30s        top 8.44s       ~7.0s
--------------------------------------------------------------
found the swing            0/3               2/3
```

**`detect_phases` is refuted, not merely suspected.** It has now missed on
three labelled swings and eight unlabelled ones, always anchoring in the
walk-in. This is measurement, not inference from plots.

**The DESCENT_SMOOTH_S objection is weaker than recorded.** The block above
says the answer moves six seconds between 0.05 and 0.10 — true on the
2026-08-17 clips. Swept against the labelled ones, the answer is **identical
from 0.07 through 0.30** (2/3 at every setting; 0.05 drops to 1/3). So on
clips where a swing can be checked, the constant is not doing the load-bearing
work the earlier note feared. It is still not enough to ship on: three labels.

**Why the third clip fails — measured, and it is not the smoothing.**
`locate_swing` anchors at 2.97 s on `swing_..._193851.mp4`. The cause is a
single-frame tracking discontinuity:

```
frame 88->89   +1.04 -> +1.20   jump +0.16 torso-lengths in 33ms
frame 89->90   +1.20 -> +1.04   jump -0.17
frame 90->91   +1.13            jump +0.09
frame 91->92   +1.13 -> +0.21   jump -0.92   <-- the anchor
frame 92->93   +0.21 -> +0.29   jump +0.08
```

A wrist cannot travel 0.92 torso-lengths — roughly 45 cm — in 33 ms; that is
~13 m/s, clubhead speed, not wrist speed. The median per-frame jump in this
clip is **0.027** torso-lengths, so the anchor is **34x** the typical frame,
with ordinary 0.08-0.17 motion on both sides. It is a pose discontinuity being
read as the fastest descent in the clip. Every clip in the corpus carries a
few: 3 to 19 jumps over 0.5 torso-lengths each.

#### P1.1 — THE GATE IS WRONG IN BOTH DIRECTIONS (2026-08-20)

Six clips were filmed to test it: three varied swing routines and three
deliberate negatives. The gate's full behaviour, for the first time:

```
clip                                    contains   gate said        verdict
1  walk in, club already down, swing     a swing   "not a swing"    FALSE NEGATIVE
2  walk in, settle, pause, swing         a swing    full report     ok
3  practice swing, then the real one     a swing    full report     ok
4  empty range, nobody in frame          nothing   "not a swing"    ok
5  walk in, stand there, walk out        nothing    full report     FALSE POSITIVE
6  set up to the ball, then step away    nothing    full report     FALSE POSITIVE
```

**It rejected a real swing and accepted two non-swings.** The false negative is
in some ways the worse one: the golfer did everything asked — side-on, whole
body in frame, camera still — and was told *"that didn't look like a golf
swing."* Being wrong in both directions at once means the gate is not
mis-tuned; it is not measuring the thing it claims to measure.

**Clip 1's data is gone**, which is precisely the defect the rejection log
fixes: a hard fail wrote nothing, so the one clip that would explain *why* a
real swing gets rejected cannot be examined. The fix is committed and is not on
the phone yet. **Re-film clip 1 after the next release**, because it is the
most diagnostic clip in the set.

**The negatives are now three, not one.** Clips 5 and 6 are recorded as
`no_swing` with `basis: video`. Against them:

```
                    07:12:22    180317    180347
detect_phases        invents    invents   invents
locate_swing         invents    invents   invents
stance_bounded       invents   DECLINES   invents
```

One decline out of three, and it came from a mechanism rather than a threshold:
on 180317 the golfer never stood still long enough to form a stance, so there
was nothing to search. **That is the first time any localizer has correctly
refused a clip with a person in it.** It is one clip. It is not a gate.

**A flaw in the stance work, found by these clips and fixed.** When stance
bounding found no stance, `detect_phases` fell through to peak localization —
measured at 0/10 — and turned that decline into an invented swing at 0.2 s. A
caller who opts into stance bounding is asking a question whose answer may be
"there is no stance"; swallowing that answer to produce a guess is strictly
worse than returning it.

**The practice swing beats the stance bound, as predicted.** Clip 3 holds two
excursions, ~8 s and ~13-14 s, and the stance (5.2-16.1 s) contains both. The
golfer confirms **the first is the practice swing**; the real one is the second.
The stance-bounded search anchors at 8.01 s — **five seconds early, on the
practice swing.**

This was predicted before the clip was filmed, which is the only reason it is
worth anything: a stance bound cannot separate two swings that both happen
while the golfer is standing still. It is now measured rather than argued.

**Why this distractor is different in kind from the others.** Every failure
before it came from something that was not a swing — pose garbage in the
walk-in, a club being lowered into address. Those can, in principle, be
cleaned away. A practice swing **is a swing**: it happens inside the stance, it
has the correct shape, the correct duration, the correct descent rate. No
amount of signal processing distinguishes it, because there is nothing wrong
with it. Only something that knows *which swing the golfer meant* can choose.

That is a product problem wearing a signal-processing costume, and it points
at the scrubber ("was this the swing?") already sketched under P1.4 — or at
the simpler answer of taking the LAST qualifying swing in the stance, on the
grounds that a golfer practices and then hits. **The last-swing rule is a
guess with one supporting clip, and it is not being implemented on that.**

Running totals with clip 3 labelled to the real swing:

```
                    video labels   sheet labels
detect_phases           0/7            0/4
locate_swing            2/7            0/4
stance_bounded          6/7            3/4
```

#### P1.1 — THE GATE WORKS ON AN EMPTY FRAME, AND THE APP WAS BINNING THE EVIDENCE (2026-08-20)

Filming the empty range — camera running, nobody in frame — produced the hard
fail: *"That didn't look like a golf swing — no phases were detected."* So the
shipped gate **does** catch one class of negative, and this is the first
measured evidence of it.

**Which sharpens what P1.1 actually is.** The gate catches *no pose anywhere*
(`detectPhases` returns null below two detected frames). It does not catch
*poses found, but no swing* — the 2026-08-17 nothing-clip had `pose_coverage`
0.61 and sailed through to a full fault report. Two different negatives, one
of them handled. Nothing before this said which.

**The serious finding is what happened to the clip.** A hard fail wrote
**nothing at all**: `_logWriteFailure` only fires when the history write
breaks, not when a swing is rejected. So the corpus could only ever contain
clips that passed the gate — which makes the gate's own error rate
unmeasurable from the data it produces. Ten positives and one negative on
record, and a golfer had just filmed a negative that the app discarded.

**Fixed.** `SwingAnalysisException` now carries the measurements taken before
the rejection — frame series, fps, frame count, pose coverage — and
`RejectionLog` appends them to `swing_history_rejections.jsonl`, joined to the
retained clip by `clip_name` and exported with the rest of the corpus. A
rejected swing is now a corpus record with the same per-frame shape as an
accepted one, so the scorer reads both with one parser.

Kept in a separate file rather than mixed into `swing_history.jsonl`: these
records have no faults, no tempo and no phases, and a reader assuming those
fields would break on them.

**Two bugs the tests caught before the golfer could.** JSON has no NaN, so a
frame series holding raw NaN cannot be encoded and `record()` would have
dropped it silently — exactly the empty-frame case this exists to capture.
Production is safe because `FrameSeries.fromFeatures` maps NaN to null, and the
test now goes through that path rather than constructing a series production
never builds. The second was mine: the "unwritable log" test passed a deleted
directory, which `record()` simply recreates.

**Still open, and unchanged by any of this:** all three localizers invent a
swing in the 2026-08-17 nothing-clip. Catching an empty frame is not the same
as knowing whether a person in frame swung, and the gate still cannot tell.
That needs negatives of the second kind — someone in frame, not swinging — and
now the app will keep them instead of throwing them away.

#### P1.4 — STANCE-BOUNDED SEARCH PASSES THE NECESSARY CONDITION (2026-08-20)

Every localization failure on record happens **outside the stance**. Filming
yourself produces walk-in, stance, walk-away; only the stance can contain a
swing. `stance_bounds()` finds the longest run where the hips do not travel —
hip displacement over a one-second window, in torso lengths — and
`locate_swing(..., hip_x=)` searches only inside it.

```
                    detect_phases   locate_swing   stance_bounded
video labels (6)         0/6             2/6            6/6
sheet labels (4)         0/4             0/4            3/4
nothing-clip          invents         invents        invents
```

**It works for the mechanism it was built on, not by luck.** The windows it
finds start after the walk-in and end before the walk-away on all eleven clips
— 4.0-5.8 s to 10.1-15.6 s — and every labelled swing falls inside. On
`swing_..._193851.mp4`, the clip that defeated `locate_swing`, the stance
begins at 4.0 s, which excludes the club being lowered at ~3 s, and the anchor
moves from 2.97 s to 6.9 s.

**The constant does not carry the result.** `STANCE_TRAVEL_MAX` gives an
identical answer from **0.25 through 1.5**, a six-fold range; it only degrades
at 2.0, where the window grows enough to re-admit part of the walk-in. Compare
`DESCENT_SMOOTH_S`, whose plateau had to be discovered after the fact.

**This is NOT validation, and the reason is written down before anyone quotes
the 6/6.** All six video-labelled clips are the same golfer doing the same
routine — one condition measured six times. `locate_swing` scored 2/3 on
exactly this kind of evidence and then 0/3 on the next three identical swings.
**A number that looks like this has already fooled this project once.** What
6/6 buys is the *necessary* condition stated in advance: a stance-bounded
search that could not find these six would have been dead on arrival. It
cleared that bar and nothing more.

**What would validate it:** clips where the routine varies — club already down
during the walk-in, a pause after settling, a practice swing before the real
one. Different setups are the whole point, since the bound's claim is about
separating setup from swing.

**One label is now suspect, in the detector's favour.** On `07:55:17` the
stance-bounded anchor lands at 11.4 s against a label of 9.0 s, scored as the
single sheet-label miss. But the per-second readout of that clip puts its
excursion at s11-s12, so the *label* is probably wrong: the golfer gave "8-10
seconds" as one range for four clips, and that one swing came later. Recorded
rather than corrected — changing a label because a detector disagrees with it
is how ground truth stops being ground truth.

**Not shipped, and still not reachable from the app.** `hip_x` is opt-in, the
app passes neither `torso` nor `hip_x`, and behaviour is unchanged. **No Dart
port**, deliberately: porting an unvalidated localizer would put it one call
site away from a golfer.

**P1.1 is untouched by this.** The stance-bounded search still invents a swing
in the nothing-clip (takeaway 3.5 s, top 3.7 s, impact 4.1 s, finish 4.6 s) —
better-placed nonsense, but nonsense. All three localizers invent one. Finding
the swing and knowing whether there *is* one are separate problems, and no
amount of work on the first will close the second.

**RESULT: THE PREDICTION FAILED, AND `locate_swing` IS DEAD (2026-08-20).**
Three more same-routine swings, labelled from video at ~7 s. Predicted
`detect_phases` 0/3 and `locate_swing` 2/3. Outcome:

```
clip                        detect_phases   locate_swing   swing is at
swing_20260820_171840.mp4      top 0.47s      top 2.07s     ~8-9s
swing_20260820_171911.mp4      top 0.13s      top 4.04s     ~8-9s
swing_20260820_171938.mp4      top 0.30s      top 0.00s     ~8-9s
```

`detect_phases` 0/3 as predicted. **`locate_swing` scored 0/3, not 2/3.**

**The earlier 2/3 was noise.** Same golfer, same routine, same camera, same
constants — 2/3 one evening and 0/3 the next. A heuristic whose score moves
that far between identical conditions is not a heuristic that half-works; it is
one with no stable signal that got lucky twice. Running totals:

```
                   video labels   sheet labels   all
detect_phases          0/6            0/4        0/10
locate_swing           2/6            0/4        2/10
```

**Both localizations are now refuted by measurement**, not by argument. This is
the outcome the "NOT VALIDATED, NOT USED BY THE APP" guard on `locate_swing`
existed for: it was never enabled, so nothing shipped on the strength of a
number that turned out to be luck.

**The competing-descent story survives.** The three failures anchor at 2.07 s,
4.04 s and 0.00 s — all in the walk-in, none in the swing. The pre-registered
"what would change the plan" case was a failure *outside* the walk-in, and it
did not happen. So "the walk-in out-descends the swing" still explains every
failure on record.

**The signal itself is not the problem, and that is the useful part.** Across
all six 2026-08-19/20 clips the golfer's routine is strikingly consistent: the
address period sits flat at **0.04-0.15** torso-lengths for three to four
seconds, then the swing rises to **1.10-1.25** and drops away, always at s8-s9.
A human reads it instantly. Both detectors fail not because the swing is
ambiguous but because they search the entire clip, including a walk-in whose
pose garbage spikes as high as 2.26 torso-lengths.

That is a strong argument for bounding the search to the settled address rather
than for a better descent metric — and it is still only an argument. Six clips
of one routine cannot validate the bound, exactly as pre-registered. What they
can now do is act as a **necessary condition**: a settle-bounded search that
cannot find these six is dead on arrival.

**PRE-REGISTERED PREDICTION, written before the data arrived (2026-08-20).**
Three more swings were recorded with the same routine as the 2026-08-19 set and
labelled from video at ~7 s. Recording the expectation first, because every
wrong call in this section so far was rationalised after the fact:

  * `detect_phases`: **0/3**. It has missed 7/7 labelled and 8/8 unlabelled;
    a hit here would mean something about the clip changed, not the detector.
  * `locate_swing`: **2/3**, matching the previous same-routine set. Anything
    from 1 to 3 is inside what three samples can produce, so 3/3 would NOT be
    evidence it works, and 1/3 would not be evidence it got worse.
  * The failure, if there is one, lands in the **walk-in around 3 s**, where
    lowering the club into address out-descends the downswing (-12.9 against
    -8.9 torso-lengths/s on `swing_..._193851.mp4`).

**What would actually change the plan:** a failure that is NOT in the walk-in.
That would mean the competing-descent story is incomplete, and "search after
address onset" — the last idea standing — is not the fix either.

**What this cannot settle**, no matter how it comes out: whether the address
bound works, since none of these six clips vary the routine. Six samples of one
routine is one condition measured six times.

**`locate_swing` IS NOT "DEMONSTRABLY BETTER". MEASURED 2026-08-20.** The
paragraph above claims it "puts the events *inside* the swing on all five
recordings instead of at frame 1". That claim was made by looking at plots.
With all eight clips labelled it is **false**:

```
                         detect_phases   locate_swing   label      basis
07:12:22  (nothing)       invents one     invents one    no swing   video
07:51:50                    top 0.03s      top  4.80s    ~9.0s      sheet
07:53:41                    top 0.50s      top 13.78s    ~9.0s      sheet
07:54:23                    top 4.34s      top 15.82s    ~9.0s      sheet
07:55:17                    top 0.20s      top 11.38s    ~9.0s      sheet
193824                      top 0.47s      top  6.84s    ~7.0s      video
193851                      top 0.17s      top  2.97s    ~7.0s      video
193916                      top 0.30s      top  8.44s    ~7.0s      video
--------------------------------------------------------------------------
found the swing (video labels)   0/3            2/3
found the swing (sheet labels)   0/4            0/4
```

**Two out of seven.** On the 2026-08-17 clips it misses by -4.2, +4.8, +6.8 and
+2.4 seconds — a scatter on both sides, which is worse than a consistent bias
because there is no offset to correct. The "inside the swing on all five"
reading was eyeball assessment of unlabelled data, which is the exact failure
mode P0.4 exists to record and this project keeps rediscovering: **a claim
checked against the same intuition that produced it is not checked.**

It remains better than `detect_phases`, which is 0/7 and also invents a swing
in the nothing-clip. That is a low bar and not an argument for shipping.

**Both detectors fail the P1.1 negative.** On the clip containing no swing at
all, `detect_phases` reports takeaway 0.0s / top 0.1s / impact 2.1s / finish
4.6s and `locate_swing` reports 0.0 / 1.2 / 2.1 / 2.4. Neither declines. The
hard-fail gate shipped in the app is a presence check on phase *ordering*, and
both of these produce well-ordered phases, so it does not catch either. P1.1 is
open, and swapping localizers will not close it.

**Label quality, stated so it is not overread.** The four 2026-08-17 labels are
`basis: sheet` and worse than that: the golfer first read "around 6-7 seconds",
then revised to "8-10 seconds into each" after being shown a per-second readout
of wrist height that I produced. **The revision followed my own analysis of the
same series, so the label is partly mine.** It is strong enough to confirm a
four-to-seven-second miss and far too weak to adjudicate anything finer. The
three 2026-08-19 labels are `basis: video` and carry no such problem.

**TWO hypotheses tried and refuted, recorded so they are not retried.**

*First:* the jump sits four frames after a 0.53 s pose gap (frames 85-87), so
refuse to compute the descent rate across interpolated frames — mask any rate
whose smoothing window touches an untracked frame. **Does not work.** With
`DESCENT_SMOOTH_S` at 0.10 s the window is three frames wide and frames 90-92
are all tracked, so the mask never sees the artifact. (The same masking did
move two *unlabelled* 2026-08-17 clips from the end toward the middle, 13.78s
-> 9.08s and 15.82s -> 9.81s, which looks like an improvement and cannot be
called one without labels.)

*Second — and this one retracts a claim made earlier in this same section:*
reject per-frame jumps far outside the clip's own distribution. **Also does not
work, and the reason matters more than the fix.** A 3-frame median filter — the
smallest window that can remove a one-frame outlier at all — barely moves the
descent rate at the false anchor, from **-12.92 to -12.35** torso-lengths/s,
still beating the real swing's **-8.94**. The anchor survives at 2.97 s.

The drop is a **step, not a spike**: frames 92, 93 and 94 are all low
(+0.21, +0.29, +0.20) after +1.13 at frame 91. A median cannot remove it
because there is nothing transient to remove.

**What is actually happening, from the golfer (2026-08-20): "around 3 seconds
in I am walking with the club into position."** The wrist sits ~1.1
torso-lengths above the hips because the club is being carried, and then it
comes down into address. **That descent genuinely out-runs the downswing** —
-12.9 against -8.9 torso-lengths/s — so this is not a tracking artifact to be
filtered away. Setting up to hit the ball is a faster normalized wrist descent
than hitting it.

**So the anchor is wrong, not the data.** "Fastest descent" is not sufficient,
and no amount of cleaning will make it sufficient, because the competing event
is real. This is the same wall the earlier note hit from the other side —
"practice swings, waggles and setting down the club all produce drops
comparable to the swing" — now with a measured example and a golfer's account
of what the motion was.

**Where that points.** The swing is not merely a fast descent; it is a fast
descent *out of a settled address*. The body-speed structure sketched above
already separates `walk in | settle+swing | walk back`, and bounding the search
to after the golfer settles is exactly what `detect_address_onset()` (P0.2) is
for. That makes P1.4 and P0.2 one problem rather than two — which is a change
in the plan, not a detail, and should be decided deliberately rather than
drifted into.

**What unblocks this: labels, and they are cheap.** Noting the second at which
each swing happens converts every question above from taste into measurement.
Without it, any localizer is tuned to look right. The natural product form is a
scrubber on the report — "was this the swing?" — which collects labels as a
side effect of use, and is the same UI that would serve as a manual-trim
fallback.

**The obvious way to get those labels is not available: the clips are gone.**
`record_screen.dart` hands `stopVideoRecording()`'s path straight to the
analyzer and keeps no copy; nothing writes the video into the app's Documents
directory, so the `UIFileSharingEnabled` route added for the corpus export
cannot see it; and the file sits in the app's temp directory, which iOS
reclaims. **The five recordings of 2026-08-17 cannot be rewatched** — retention came
after them, so they stay label-from-data only. Anything
that wants video ground truth has to retain the video first.

**Retention shipped 2026-08-19, on the golfer's decision to keep the data.**
`clip_store.dart` moves each recording into `<Documents>/clips` as
`swing_<YYYYMMDD>_<HHMMSS>.mp4`, which the `UIFileSharingEnabled` /
`LSSupportsOpeningDocumentsInPlace` keys already expose in the Files app.
Nothing new leaves the device: there is no backend, and this writes to the same
container the corpus lives in.

Four decisions worth not relitigating:

- **Move, not copy.** A copy leaves two of a ~50 MB file on the phone, one of
  them in a directory iOS reclaims on its own schedule — and analysis would be
  reading the doomed one. Analysis now runs against the retained file.
- **Retained BEFORE analysis, not after.** A swing that fails to analyze is the
  most useful one to be able to rewatch, and the P1.1 hard-fail path throws.
  Retaining afterwards would have lost exactly the clips worth keeping.
- **The join is a written field, not a derived one.** Records carry
  `clip_name`; nothing infers the clip from `timestamp`. A derived join breaks
  silently the first time either side rounds differently, and this join is the
  entire point of retaining.
- **Deletion is part of the feature, not a follow-up.** These are videos of a
  person and the only copy is on their phone. `Profile > Saved videos` shows
  the count and size and deletes them all behind a confirmation. Deleting clips
  does **not** touch the corpus — the measurements stay, so space can be
  reclaimed without losing swing history.

**No schema bump.** `historySchemaVersion` describes the file's *shape* (header
present or not), and `clip_name` is an optional record field: old readers
preserve it through `_source`, new readers read a missing key as "no clip".
Both directions are tested. Every record written before 2026-08-19 has no clip
and correctly says so.

Clips travel by the Files app, **not** the corpus export — the share sheet
carries the measurements, and putting hundreds of megabytes of video through it
would break the one path P0.1 depends on.

**The Files route did not reach the golfer, and a share route was added
(2026-08-19).** The app correctly reported "3 recordings, 18 MB" — read
straight off the directory — while the folder could not be found in Files at
all. Note the corpus file `swing_history.jsonl` sits at the top level of the
same Documents directory, so this is not about clips being in a subfolder: the
app's folder itself is not appearing under On My iPhone. `UIFileSharingEnabled`
and `LSSupportsOpeningDocumentsInPlace` are verifiably in the shipped plist
(the patcher asserts them after writing), and `getApplicationDocumentsDirectory()`
verifiably maps to `NSDocumentDirectory` (checked in
`path_provider_foundation_real.dart`), so the cause is on the iOS side —
provider-list caching or navigation — not in anything the app controls.

Rather than keep guessing at the Files browser across round trips, `Profile >
Saved videos` now lists each clip and shares it through the same sheet the
corpus export uses. **The useful destination is "Save Video", which puts the
clip in Photos** — where there is a frame-accurate scrubber. Labelling a swing
means reading times off a scrubber, so Photos is a better answer than Files
was, not merely a workaround for it.

Files is kept as the second path, not removed. Two independent routes off the
device is the same lesson P1.2 taught: the share sheet cost four builds to
platform quirks, and the fallback is what made it recoverable.

**Retention verified on device 2026-08-19 (build 17).** Three swings recorded
after the update came back carrying `clip_name`
(`swing_20260819_193824.mp4` and two more), so the clips are on the phone and
joined to their measurements. Committed as
`tests/fixtures/device_corpus_2026_08_19.jsonl`.

**The written join earned itself immediately.** The clip is named when the
recording is retained; the record's `timestamp` is minted when analysis
finishes. On these three that gap is **8, 8 and 10 seconds** —
`swing_20260819_193824.mp4` belongs to the record stamped `19:38:32`. Any join
derived from the timestamp would already be matching swings to the wrong
videos, silently. This is why the field is written rather than computed.

**The detector is still nowhere near the swing.** On the three new clips,
against swings that are plainly visible on the sheets at ~6.2-7.5 s, ~7 s and
~8-9.5 s:

```
clip                        takeaway   top    impact   finish   length
swing_20260819_193824.mp4     0.0 s   0.4 s   0.7 s   12.1 s   12.6 s
swing_20260819_193851.mp4     0.1 s   0.1 s  11.3 s   11.8 s   12.4 s
swing_20260819_193916.mp4     0.0 s   0.2 s   1.9 s   13.4 s   13.9 s
```

Eight recordings now, and `detect_phases` has anchored in the walk-in on every
single one. P1.3 is not an edge case.

**They can still be labelled, from the data instead of the video.**
`validation/device_corpus/label_sheet.py` renders one sheet per recording from
the committed per-frame series: wrist/shoulder/hip in image pixels with the
axis inverted and the y-range clipped to where the body actually is, wrist
height above the hips in torso lengths (which removes the golfer walking
toward a fixed camera), and a track of which frames had a pose at all. The
swing reads off the normalized panel unmistakably — a rise to ~1.5 torso
lengths, a drop through the hips, a follow-through peak — against an address
that holds flat near 0. The nothing-clip has no such excursion anywhere, so it
labels as a genuine negative for P1.1. Labels go in
`validation/device_corpus/labels.json` (`--write-template` writes the empty
slots), `null` where the labeller cannot tell.

The sheet deliberately does **not** draw `locate_swing()`'s answer on itself.
That answer is what the labels exist to judge; showing it to the labeller
would contaminate the ground truth with the hypothesis.

**What the current shipped detector does on these clips**, for scale — the
swing in recording 1 is around 9.5-11.5 s and in recording 4 around 11-13 s:

```
             takeaway      top       impact     finish     clip
nothing      0.0 s        0.2 s      2.1 s      4.5 s      5.6 s
swing 1      1.1 s        3.6 s     14.8 s     15.2 s     16.0 s
swing 2      0.0 s        0.5 s      2.4 s     13.8 s     15.4 s
swing 3      0.0 s        4.3 s      7.2 s     15.8 s     16.3 s
swing 4      0.0 s        0.2 s     17.6 s     18.1 s     18.5 s
```

Every one of them anchors in the walk-in, not the swing. This is P1.3 stated in
seconds rather than in frame indices.

**State of the code.** `locate_swing()` is committed, documented as
unvalidated, and reachable only by passing `torso=` to `detect_phases`. Nothing
in the app passes it, so behaviour is unchanged. The five recordings are
committed as `tests/fixtures/device_corpus_2026_08_17.jsonl` with
characterization tests that assert only what the data supports: the events are
ordered and inside the clip, and they land later than peak localization's. The
frame numbers are deliberately not pinned — a test asserting them would look
like evidence they are right.

**The app's name did not match its store listing — FIXED 2026-08-19.** Measured
against the pinned SDK rather than assumed: `flutter create --project-name
golf_swing_analyzer` writes `CFBundleDisplayName` "Golf Swing Analyzer" and
`CFBundleName` "golf_swing_analyzer", while the App Store listing is **Fore
Swing**. A tester installing from TestFlight would have found an icon whose name
did not match what they tapped to get it. `configure_ios.py` now patches both
keys (the generated `CFBundleName` is also past Apple's 15-character guidance).

Deliberately **not** renamed: `main.dart`'s `MaterialApp` title, still "Golf
Swing Analyzer". That is user-facing copy, and it belongs to the product-voice
pass below rather than to a plist patcher — renaming it here would scatter the
voice work across commits that are not about voice.

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

### Product voice — the app reads like it was generated, not written (2026-08-17)

Raised after seeing the shipped screens on device. The app is *accurate* and
*honest* and still reads like documentation. It has no voice, and a golfer can
tell. This is a real product problem, not polish.

**The tells, from the shipped Record and Report screens:**

- **Internal vocabulary leaks into user copy.** `NOT SEEN`, `POSSIBLE`,
  `— informational`, `beta reference 0.13`, `0.44 torso-lengths`. These are
  classifier states and calibration terms. No golfer thinks in torso-lengths,
  and "NOT SEEN" is what a program says, not a person.
- **Hedging stacked into one long sentence.** The beta banner is a 45-word
  single sentence carrying four separate qualifications. Everything in it is
  true. Nobody reads it.
- **Redundancy from parallel construction.** "Possible head sway" sitting next
  to a `POSSIBLE` badge. Every card built to the identical shape whether or not
  the content warrants it.
- **Explaining where it should be saying.** The banner explains the entire
  epistemic situation instead of saying the one thing that matters: these
  numbers are early, don't train on them yet.
- **Labels that describe the data model, not the user's intent.** "This swing
  is: Normal / Exaggerated", "Working on: Full swing check". Both are fields;
  neither is a question a golfer would ask themselves.

**The existing counter-example is in this repo.** `data/drills.json` reads
well — *"Do 10 reps feeling the head stay 'quiet' over the ball"* sounds like a
coach, because it was written for a human audience. The drill text is the proof
the project can do this; the surrounding chrome is where it slips. Match the
drills' register, don't invent a new one.

**THE CONSTRAINT THAT MAKES THIS HARD — read before touching any copy.** The
hedging is **load-bearing**. The beta banner, the `beta reference` values, and
the deliberate softness of "possible" all exist because the thresholds are
uncalibrated (see P0) and the app must not imply otherwise. A rewrite that
makes the copy punchy by deleting the caveats converts an honest product into a
confident wrong one, and it will look like an improvement in review.

Rewrite the **voice**, preserve the **epistemics**. Concretely: every claim the
current copy hedges must still be hedged afterwards, in fewer and better words.
"Early numbers — we haven't checked these against real swings yet" carries the
same meaning as the 45-word banner and is likelier to be read. If a proposed
line drops a qualification rather than compressing it, reject it.

**Sequencing.** Cheap to do, expensive to undo badly, and the fault vocabulary
will change anyway when P0.2 recalibrates and the verdict wording follows the
thresholds. Worth doing *after* P0.2 so the copy is written once against final
semantics — but the Record screen and the beta banner touch no thresholds and
can move earlier if the app goes in front of anyone.

**This is only half the problem.** The other half — the visual system, the
screen structure, and the fact that the report shows no image of the swing it
measured — is tracked in **Front-end UI** immediately below. Neither pass
fixes the other: rewriting every sentence in the app would leave it looking
exactly as template-built as it does now.

### Front-end UI — it looks generated before it reads generated (2026-08-20)

Companion to **Product voice** above, and meant to be read with it. That entry
covers the *copy*; this one covers the *visual system, the structure, and the
missing evidence*. The two failures are independent: fixing every sentence in
the app would leave it looking exactly as template-built as it does now.

**The tell is measurable, not a matter of taste.** The app is visually
indistinguishable from a `flutter create` template with correct content pasted
into it:

- `main.dart:78-88` — the entire design system is `colorSchemeSeed:
  Color(0xFF2E7D32)` plus `useMaterial3: true`, with light and dark identical
  apart from `brightness`. That is Material's own demo seed, default Roboto/SF,
  and no type scale.
- **23** hardcoded `Colors.*` literals inside `src/ui/` (`amber.shade800`,
  `green.shade600`, `orange.shade700`, `red.shade600`, `black54`, `black87`,
  `Colors.red`), none derived from the `ColorScheme`. Dark mode is therefore
  nominally supported and demonstrably never looked at.
- **0** typography customizations, **0** `ThemeExtension`s, **0** `SafeArea`s
  anywhere in `lib/`.
- Spacing is hand-placed and off-grid: `SizedBox` heights at 4, 8, 12, 16, 20,
  24, alongside `fromLTRB(16,16,16,0)`, `(16,0,16,8)`, `(16,8,16,4)`,
  `symmetric(h:16,v:6)` and `Divider(height: 32)`. Nothing sits on a scale.
- `report_screen.dart:57-72` — six near-identical `Card`s at margin 16 /
  padding 16 in a flat `ListView`. When everything is a card at one elevation,
  nothing is primary. This is the layout form of the "redundancy from parallel
  construction" tell recorded above.

A golfer reads all of that in about two seconds, before a single word.

#### Tier 1 — highest impact, and none of it is gated on P0.2

1. **One real theme file, and ban `Colors.*` from `src/ui/`.** A
   `lib/src/ui/theme/app_theme.dart` with a deliberate palette (a green that is
   not Material's stock `2E7D32`, a true near-black for camera surfaces, one
   accent), a type ramp, and **tabular figures for every measured value** —
   numbers that jitter in width as they change is a distinctly amateur detail
   on a measurement app. Then a `SwingColors` `ThemeExtension` carrying the
   semantic slots the app actually has (`flagged`, `notSeen`, `focus`, `scrim`,
   `onScrim`, the three drill difficulties), so `fault_card.dart:36` and
   `drill_tile.dart:13-22` stop inventing colors and dark mode starts working
   as a side effect. Add `Gap.xs/sm/md/lg` (4/8/16/24) and delete the ad-hoc
   `SizedBox`es.

2. **Rebuild the Record screen.** It is the first thing anyone sees and the
   weakest thing in the app: `record_screen.dart:145-200` puts a Material
   `AppBar` titled "Record your swing" above a live viewfinder, three stacked
   `Colors.black54` panels over the top third holding two `SegmentedButton`s,
   two `DropdownButton`s and a 20-word instruction paragraph, and a red
   `FloatingActionButton.extended` labelled "Stop & analyze". That is a
   settings form pasted onto a camera. Specifically:
   - Drop the AppBar, go edge-to-edge, and wrap the screen in its own
     permanently-dark `Theme`. The `SegmentedButton`s currently inherit the
     *light* scheme and render light-on-`black54` — which is exactly why
     `dropdownColor: Colors.black87` and `iconEnabledColor: Colors.white` had
     to be hand-patched at `:319-322` and `:472-475`. Fix the theme and those
     patches disappear.
   - Get handedness off the viewfinder. It is already persisted on the
     participant record (`record_screen.dart:66`), so the screen asks a settled
     question every launch. Onboarding once, then Profile.
   - Get `_SwingKindSelector` out of the golfer path entirely. "This swing is:
     Normal / Exaggerated", `Icons.science_outlined`, and a fault dropdown is
     P0.1 corpus instrumentation sitting on the primary screen of a TestFlight
     build. Put it behind a Profile toggle. Nothing says *internal tool* louder
     than a beaker icon.
   - What remains is one bottom control bar: focus picker, circular shutter
     with a recording ring, mm:ss elapsed readout, haptics on start and stop.
   - **Add a framing guide overlay** — a `CustomPainter` silhouette and
     vertical alignment line, with the instruction text attached to it instead
     of floating in a black slab. Highest-value visual addition available, and
     it directly serves the down-the-line framing spec P0.1's corpus depends
     on.
   - **Add a self-timer.** A golfer with a club in their hands and a phone on a
     tripod cannot reach the screen. Its absence is the clearest sign the flow
     has never been used by a golfer.

3. **Show the golfer the swing that was measured.** The report contains no
   imagery at all — the app claims to have looked at someone's body and then
   shows only sentences. Everything needed already exists: `ClipStore` retains
   every clip, `frame_extractor.dart` pulls frames, per-frame landmarks are in
   hand, and `phase_montage.py` already does this on the Python side. Put
   address / top / impact stills with the skeleton and the measured quantity
   drawn on them at the top of the report, plus scrubbing of the retained clip
   with phase markers. This **promotes the "Video playback" bullet under User
   Experience above** out of the someday list: it is what turns numbers into
   evidence, it touches no thresholds, and it finally gives retained clips a
   user-facing purpose beyond occupying storage.

4. **Render measurements as instruments, not as prose.**
   `swing_analyzer.dart:160-185` builds English sentences in the *service*
   layer ("Lateral sway 0.44 torso-lengths (beta reference 0.13). Vertical dip
   0.02 — informational."). That is a UI concern living in analysis code, and
   it forces the report to present data as a paragraph. Give `FaultVerdict`
   structured fields (`value`, `unit`, `reference`, `secondary`) and build one
   `MeasurementGauge`: a short scale, the measured value marked, the reference
   drawn as a **soft band rather than a hard line**, unit beneath.

   **This is the honest move, not a cosmetic one, and it is the answer to the
   constraint recorded in Product voice.** Uncertainty *drawn* is more truthful
   than uncertainty *described*, because it survives a glance and a paragraph
   does not. A shaded "not yet validated" band on every gauge carries the beta
   caveat structurally, every time the screen is opened. Same for tempo:
   `2.8 : 1 ±0.4` renders the interval `tempoRatioPrecision` already computes
   at `report_screen.dart:200-217`, in place of 30 words prosifying it.

5. **Give the report a hierarchy.** Hero (swing stills + tempo on one strong
   surface) → the four measurements as a dense list, not four elevated cards →
   drills collapsed under a flagged measurement, expanded only for the focus
   fault → comparison last. `_SectionHeader` (`report_screen.dart:219`) becomes
   a shared component, and the focus treatment (`fault_card.dart:44-49`, a
   1.5px border on an otherwise identical card) becomes one genuinely
   emphasized surface.

#### Tier 2 — the missing product surfaces

6. **There is no way to see your own past swings.** `swing_history.jsonl`
   accumulates, but the only readout is one previous-vs-current card, and
   Profile offers a count and an export button aimed at the developer. Data
   goes in and never comes back out — that is a research instrument, not a
   product. Add a **Swings** list (date, focus, the four values, tap through to
   the report and clip). **This does not breach the Beta decision record:** a
   list of past measurements makes no trend or improvement claim, so the
   `Trend` / `Crossing` machinery stays unsurfaced exactly as required.

7. **Decide the navigation instead of inheriting it.** Today: Record → push
   Analyzing → replace with Report, with "record another" as a `videocam` icon
   running `popUntil(isFirst)` (`report_screen.dart:44-50`). Camera-first is a
   defensible product choice; three-deep pushes with no shell is what happens
   when nobody chose. Either a three-tab shell (Record / Swings / Profile) or
   an explicit "we open straight into the viewfinder" decision recorded here.
   Either is fine; the accident is not.

8. **The Analyzing screen is the longest wait and the least reassuring.**
   `analyzing_screen.dart:196-228` shows a 220px `LinearProgressIndicator`,
   indeterminate for two of three stages, reading "Extracting frames…" — where
   the trailing ellipsis on every stage label is itself a generated-code tell.
   Make it a three-step stepper with a determinate arc, show the first frame of
   *their* swing behind it so the wait reads as work on their video, and add a
   cancel. This runs over a ~50 MB file.

9. **Profile is a document, not a settings screen** — hand-built `Padding` +
   `Text` + `Divider(height: 32)` sequences where list components belong. Two
   specifics: the raw participant UUID is the *headline* of the screen
   (`profile_screen.dart:196-206`) when it is a support identifier and belongs
   small, at the bottom, under Diagnostics with a copy button; and `_export`'s
   failure path shows a 20-second `SnackBar` dumping `sent origin`, `screen`
   and the raw exception at the user (`:170-178`). That snackbar exists for a
   good reason (see the four builds burned on the share-origin quirk), but in
   the golfer-facing path it is the most visible unfinished-internal-build
   artifact in the app. Move it to a Diagnostics screen with
   copy-to-clipboard, and tell the user "Export failed — details in
   Diagnostics."

10. **Show the version and build number.** The P1 record above spends three of
    four builds on a phone running none of the code and names a visible build
    number as the fix. A small `1.0.0 (42)` at the foot of Profile is both a
    professionalism signal and that fix.

11. **Settle the name, and give it a face.** `main.dart:76` still says
    `'Golf Swing Analyzer'` while the home-screen icon says **Fore Swing**
    (`configure_ios.py:78`, which correctly defers the in-app strings to this
    pass). Pick Fore Swing everywhere, and add a wordmark and launch screen in
    the dark camera-first palette. There is currently no icon, no launch
    screen, and no visual identity of any kind.

#### Tier 3 — details that read as unfinished

- **Misleading iconography.** `Icons.remove_circle_outline` for "not seen"
  (`fault_card.dart:75`) reads as *blocked*; a beaker marks both the beta
  banner and the calibration control; `videocam` means "record another".
  Curate a small set and drop icons where the label suffices.
- **Status is signalled by color alone** — amber vs `scheme.outline` is the
  only difference between `POSSIBLE` and `NOT SEEN` (`fault_card.dart:36`,
  `:88-98`). Add shape or a glyph, and `Semantics` labels, of which there are
  currently none anywhere.
- **Hand-formatted dates.** `_two()` produces `2026-08-20 14:03`
  (`swing_comparison_view.dart:38-43`). That is a log line; `intl`'s
  "Yesterday, 2:03 pm" is a product.
- **Fixed-width rows will overflow at large accessibility text sizes** —
  notably the `SizedBox(width: 26)` used as indentation at
  `record_screen.dart:333` and the label/control rows beside it.
- **No `SafeArea` anywhere.** Harmless while every screen has an AppBar;
  breaks the moment the camera screen goes edge-to-edge under item 2.
- **Uppercase micro-badges** (`POSSIBLE`, `NOT SEEN`, and lowercase
  `beginner`/`advanced` at `drill_tile.dart:52`) are generic-dashboard
  styling — and the difficulty badge prints the raw JSON enum value.

#### A likely bug found while reading — verify on device

`record_screen.dart:213-216` makes `CameraPreview` a non-positioned child of a
`Stack(fit: StackFit.expand)`, which passes it **tight** constraints. Its
internal `AspectRatio` cannot honor its ratio under tight constraints, so the
preview is very likely being **stretched to the screen** rather than
letterboxed or center-cropped. Check against a known-square subject.

This is not cosmetic: the golfer *frames the swing against this preview*, so a
distorted preview means they frame to a lie — a measurement-quality issue that
feeds straight into the P0.1 corpus. Fix with an explicit `AspectRatio`, or
`FittedBox(fit: BoxFit.cover)` with a deliberate crop.

#### The constraints — read before starting any of this

- **Do not buy punchiness by deleting hedges.** Same rule as Product voice
  above, and the same trap. Every qualification the current copy carries must
  survive, compressed rather than dropped. Item 4 is the way through: move the
  hedging out of prose and into *form*, where it is both shorter and harder to
  miss.
- **Do not rewrite the fault vocabulary yet.** "Possible", `NOT SEEN`,
  `beta reference` and `torso-lengths` all follow the thresholds, and P0.2 will
  change what they mean. Items 1, 2, 3, 5, 6, 10 and 11 are all
  threshold-independent and can proceed now; the fault wording gets written
  once, afterwards, against final semantics. Item 4 splits: build the
  `MeasurementGauge` and the structured `FaultVerdict` fields now, set the
  displayed reference values after P0.2.
- **Do not surface trends to fill the new history screen.** The list is a
  list. The moment it draws an arrow it makes a claim the calibration cannot
  support.

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
