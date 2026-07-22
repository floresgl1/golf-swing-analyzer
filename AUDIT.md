# Golf Swing Analyzer — Code Audit

**Scope:** Python analyzer (`src/`, present on both `main` and `flutter-mvp`) and the Flutter port (`flutter_app/`, on `flutter-mvp`).
**Ground rule honored:** no thresholds or core detection logic changed. Only one trivial fix applied (an unused import); everything else is described, not implemented.

## Preliminary notes (read first)

- **`ROADMAP.md` does not exist** — not in the working tree and not in git history on any branch. It could not be used for architecture context; this audit treats the code as the source of truth. If a ROADMAP exists elsewhere, some "intended design" judgments below may need revisiting.
- **`swing_history.json` does not exist** either — no references anywhere in the code. It appears to be a planned/future feature. Item 8 is answered on that basis.
- **Branch reality:** `flutter-mvp` contains *both* the Python code (including `drill_recommender.py`) and the Flutter app; `main` has the Python prototype **without** `drill_recommender.py` or the drill integration in `faults.py`. Python findings below apply to both branches unless noted.

## Severity legend

🔴 High · 🟠 Medium · 🟡 Low · ✅ Fixed (trivial) · 🟢 No issue found

---

## Code quality

### 1. Unused imports / dead code / unreachable branches

| Sev | Location | Finding |
| --- | --- | --- |
| ✅ | `src/pose_estimation.py:6` | `LEAD_SIDE` was imported but never used. **Fixed** (removed from the import). |
| 🟢 | `flutter_app/lib/src/models/swing_analysis.dart:6` | `import '../analysis/faults.dart'` looks unused but is referenced by the dartdoc link `[faultHeadSway]` (line 14), which the analyzer counts as a use. Left as-is. |
| 🟢 | Other Python modules | `faults.py`, `body_angles.py`, `swing_phases.py`, `phase_montage.py` imports all used. |
| 🟡 | `flutter_app/lib/src/analysis/faults.dart` | The `HeadMovementResult` still carries `swayFlagged`/`dipFlagged`; `dipFlagged` isn't consumed by the app (only by tests). Intentional (mirrors the informational dip verdict) — keep. |

No unreachable branches found. Error/guard branches (`if not phases`, `if scale else nan`, `if goodCount < 2`) are all reachable.

### 2. Naming conventions

🟢 **Consistent.** Python is uniformly `snake_case` (functions/vars) with `UPPER_SNAKE` constants; Dart is uniformly `lowerCamelCase` with `lowerCamel` constants (correct Dart style); JSON fault ids are `snake_case` in both `data/drills.json` and the Dart `fault*` constants. The fault-id vocabulary matches across Python and Dart. No cross-convention leakage found.

Minor: the four Dart fault constants use camelCase names for snake_case values (`faultHeadSway = 'head_sway'`) — correct and intended.

### 3. Functions doing too much (>~50 lines)

| Sev | Location | Lines (approx) | Note |
| --- | --- | --- | --- |
| 🟠 | `src/faults.py` `main()` | ~165 | Does pose collection **+** phase detection **+** all four detectors **+** console report **+** drill recommendation **+** four OpenCV visualizations **+** file writes. Biggest offender. Split into `collect_series()`, `run_detectors()`, `print_report()`, `render_visuals()`. |
| 🟠 | `src/swing_phases.py` `main()` | ~95 | Collection + detect + print + matplotlib plot. |
| 🟠 | `src/body_angles.py` `main()` | ~83 | Collection + angle math + print + plot. |
| 🟠 | `src/pose_estimation.py` (module body) | ~100 | Two full passes at module top level (see item 15). |
| 🟠 | `src/phase_montage.py` (module body) | ~80 | Collection + checkpoint selection + montage render at module top level. |
| 🟡 | `flutter_app/.../swing_analyzer.dart` `_buildReport()` | ~90 | Array assembly + four detectors + four verdict-string builders + recommendation. Extract the verdict-string construction (`FaultVerdict` list) into a helper. |

All the pure detection functions (`detect_phases`, the four detectors, `detectPhases`) are comfortably under 50 lines.

### 4. Duplicated data-collection loop

🟠 **Confirmed, 5 copies.** The "configure `PoseLandmarker` → open `VideoCapture` → loop `read()` → BGR→RGB → `mp.Image` → `detect_for_video` → append landmarks/`wrist_y` or `nan`" block is duplicated with small variations in:

- `src/faults.py` (collects eye/shoulder/hip/torso/wrist)
- `src/body_angles.py` (collects shoulder/hip vectors + wrist)
- `src/swing_phases.py` (collects wrist only)
- `src/pose_estimation.py` (caches full landmarks + wrist)
- `src/phase_montage.py` (caches full landmarks + wrist)

**Proposed fix (substantive — see item 14).** Extract one module, e.g. `src/pose_pipeline.py`, exposing a single pass that returns cached per-frame landmarks plus `fps`/`width`/`height`; each script derives the series it needs from the cached landmarks. Removes ~30 duplicated lines ×5 and gives one place to fix bugs (e.g., the `fps==0` risk in item 7).

---

## Robustness

### 5. No detectable pose in *any* frame — per-module trace

| Module | Behavior | Verdict |
| --- | --- | --- |
| `swing_phases.detect_phases` | `good.sum() < 2` → returns `None`. | 🟢 Clean guard |
| `faults.py main()` | `if not phases: print("Could not detect swing phases…"); return`. | 🟢 Handled |
| `body_angles.py main()` | `if phases:` guards the printout; plot renders NaN series as gaps. | 🟢 No crash |
| `pose_estimation.py` | `phase_for_frame(i, None)` returns `None` (guarded); skeleton skipped for `None` landmarks; writes source frames. | 🟢 No crash |
| `phase_montage.py` | Falls back to evenly-spaced checkpoints. **But** on a *truly empty* video (`n==0`) the fallback computes `int(f*(n-1))` with `n-1 == -1`, and if all reads fail `panels` is empty → `plt.subplots(1, 0)` raises. | 🟠 Edge crash on empty video |
| Flutter `swing_analyzer.analyze` | `detectPhases` → `null` → throws `SwingAnalysisException` → caught in `analyzing_screen` → error UI with "Record again". | 🟢 Best-handled path |

### 6. Extremely short video (< 30 frames)

🟠 **No minimum-length guard anywhere.** With 2–29 frames, `detect_phases` still returns indices, but they can be degenerate (e.g., `takeaway == top == 0`, `impact == top`). Downstream:
- `swing_tempo` guards `downswing_s == 0` (→ `ratio = nan`), so no crash, but backswing/downswing frame counts can be `0`.
- The detectors' `_addr_median`/`_window_median` clamp their slices, so they return a value (possibly from a 1-frame window) rather than crashing.
- Result: **plausible-looking but meaningless numbers**, silently. Recommend a guard: if `n < MIN_FRAMES` (or `impact - takeaway < k`), emit a "swing too short / not enough frames" verdict instead of a report. Dart should mirror it in `SwingAnalyzer`.

### 7. Division-by-zero risks beyond those already guarded

Already guarded: torso `scale` in all four detectors, `downswing_s` in `swing_tempo`, `_t()` in `swing_phases.main`.

| Sev | Location | Risk |
| --- | --- | --- |
| 🔴 | `src/swing_phases.py:124`, `src/body_angles.py:94`, `src/pose_estimation.py:95`, `src/phase_montage.py:55` | `timestamp_ms = int(frame_count * 1000 / fps)` — **`fps` is unguarded**. `cv2.CAP_PROP_FPS` returns `0.0` for some containers/streams, which raises `ZeroDivisionError` on the first frame. This is the most likely real-world crash. Fix once in the shared pipeline (item 14): `fps = cap.get(...) or DEFAULT_FPS`. |
| 🟢 | Dart | `FrameExtractor._probeFps` falls back to `30.0`; `swingTempo` guards `fps == 0`; `movingAverageEdge` divides by the constant window `w`. No unguarded division found. |
| 🟢 | `detect_phases` | `0.5 * span` with `span == 0` (flat signal) is multiplication, not division — safe (all peaks then qualify). |

### 8. `drills.json` / `swing_history.json` corruption

- **`swing_history.json`:** does not exist yet. If/when added, load it behind a `try/except (FileNotFoundError, JSONDecodeError)` returning an empty history, so a corrupt/absent file degrades gracefully.
- **`drills.json` — Python:** 🟠 `load_drills` does `json.load(f)` then `data['drills']` with no error handling. Invalid JSON → `JSONDecodeError`; missing top-level `drills` key → `KeyError`; missing file → `FileNotFoundError`. In `faults.py` the report prints first, so the crash surfaces as a traceback *after* the report. Wrap `load_drills` and return `[]` (or a clear message) on failure.
- **`drills.json` — Flutter:** 🟠 `main.dart` awaits `loadDrillLibrary()` at startup with **no** try/catch, and `jsonDecode(raw) as Map<String,dynamic>` throws on malformed JSON or a non-object root. Since the whole point is that a **non-developer edits this file**, a bad edit crashes the app at launch with no message. `parseDrillLibrary` itself is defensively written (`whereType<Map>`, `?? ''` field defaults), so the exposure is purely the decode/cast + the unguarded `await`. Wrap startup load in try/catch and show a "drill library could not be loaded" state (or ship a hard-coded fallback).

---

## Python ↔ Dart parity

### 9. Thresholds, window sizes, epsilons

| Constant | Python (`faults.py`) | Dart (`faults.dart`) | Match |
| --- | --- | --- | --- |
| Sway | `SWAY_THRESHOLD = 0.13` | `swayThreshold = 0.13` | ✅ |
| Dip | `DIP_THRESHOLD = 0.25` | `dipThreshold = 0.25` | ✅ |
| Reverse pivot | `REVERSE_PIVOT_THRESHOLD = 0.12` | `reversePivotThreshold = 0.12` | ✅ |
| Early extension | `EARLY_EXTENSION_THRESHOLD = 0.10` | `earlyExtensionThreshold = 0.10` | ✅ |
| Loss of posture | `POSTURE_THRESHOLD = 12.0` | `postureThreshold = 12.0` | ✅ |
| Phase smoothing window | `detect_phases(smooth=5)` | `detectPhases(smooth: 5)` | ✅ |
| Address window | `takeaway-10 … takeaway` | `takeaway-10 … takeaway` | ✅ |

🟢 **No epsilons exist** in either implementation — both rely on exact `>` comparisons against the thresholds. Nothing to mismatch.

Two **benign** representational differences (same output, worth knowing):
- **"has scale" test:** Python `x/scale if scale else nan` treats a `NaN` scale as truthy and divides (`x/NaN → NaN`); Dart uses `hasScale = scale != 0 && scale.isFinite` and returns `NaN` explicitly. Both yield `NaN`. 🟡
- **valid-sample test:** Python uses `~np.isnan` (excludes NaN only); Dart uses `.isFinite` (also excludes ±∞). Pose coordinates are never infinite, so no behavioral difference. 🟡

### 10. `detect_phases` step-by-step

| Step | Python | Dart | Match |
| --- | --- | --- | --- |
| Guard | `good.sum() < 2 → None` | `goodCount < 2 → null` | ✅ (see 9 note on isnan vs isFinite) |
| Fill gaps | `np.interp(idx, idx[good], y[good])` (clamps ends) | `fillNaNLinear` (clamps ends) | ✅ |
| Height | `1.0 - y` | `1.0 - y` | ✅ |
| Smoothing | `_moving_average` edge-pad, `/w` | `movingAverageEdge` clamp-to-edge, `/w` | ✅ (edge-pad ≡ index clamp) |
| Peaks | `h[i] >= h[i-1] and h[i] > h[i+1]` | `h[i] >= h[i-1] && h[i] > h[i+1]` | ✅ |
| Top | first peak `≥ min + 0.5·span`, else `argmax(h[:n//2])` | same | ✅ |
| Impact | `argmin(h[top:]) + top` | `argMinSlice(h, top, n)` | ✅ (both first-occurrence) |
| Finish | `argmax(h[impact:]) + impact` | `argMaxSlice(h, impact, n)` | ✅ |
| Takeaway | `argmin(h[:top]) if top>0 else 0` | `top>0 ? argMinSlice(h,0,top) : 0` | ✅ |

🟢 **Identical**, including tie-breaking (numpy `argmin/argmax` return the first extreme; the Dart helpers use strict `<`/`>` so they also return the first). This was cross-checked earlier by running the real Python `detect_phases` on a synthetic swing (`top=29, impact=45, finish=60`) and matching the Dart test expectations.

### 11. Fault detector median window radii

| Window | Python | Dart | Match |
| --- | --- | --- | --- |
| Address (all detectors) | `_addr_median`: `[takeaway-10 : takeaway+1]` | `_addrMedian`: `nanMedianSlice(a, takeaway-10, takeaway+1)` | ✅ |
| Head impact | `_window_median(…, 2)` | `_windowMedian(…, radius: 2)` | ✅ |
| Early-extension impact | `_window_median(…, 2)` | `_windowMedian(…, radius: 2)` | ✅ |
| Reverse-pivot top / finish | default `radius=3` | default `radius: 3` | ✅ |
| Loss-of-posture impact (sh & hip) | default `radius=3` | default `radius: 3` | ✅ |

🟢 All radii match, including the radius-2 impact windows for head and pelvis and the 11-frame (`takeaway-10…takeaway` inclusive) address window.

**One documented API difference (not a logic mismatch):** Dart `detectReversePivot(headX, hipX, torso, phases)` drops the Python `head_y`/`hip_y` parameters, which Python uses **only** to build debug-overlay pixel points. The computed `reverse` value is identical.

---

## Testing

### 12. Existing coverage

- **Python: none.** No `test_*.py` / `*_test.py` anywhere. The "source of truth" implementation is entirely untested in CI terms.
- **Dart: good coverage of the ported pure logic** —
  - `num_utils_test.dart` — `nanMedian`, `fillNaNLinear`, `movingAverageEdge`, argmin/argmax.
  - `swing_phases_test.dart` — `detectPhases` (null guard + synthetic swing) and `swingTempo`.
  - `faults_test.dart` — all four detectors at flag/no-flag magnitudes.
  - `drill_recommender_test.dart` — parsing, difficulty sort, flagged-only recommendation.
- **Untested (Dart):** `SwingAnalyzer` orchestration, `PoseEstimator` (needs device/ML Kit), `FrameExtractor` (needs ffmpeg), UI widgets.

### 13. Proposed test plan

**Highest value — port the Dart tests to Python** (mirrors the numbers already cross-validated), giving parity coverage on the source of truth:
1. `detect_phases`: `< 2` valid frames → `None`; synthetic swing → expected `takeaway<top<impact≤finish` and approximate indices; all-NaN input.
2. `swing_tempo`: ratio math; `None` when `fps==0` or `phases is None`.
3. Each detector: one flag and one no-flag case using constant-torso synthetic arrays (same fixtures as `faults_test.dart`).
4. `drill_recommender`: 3-per-fault count, difficulty sort, flagged-only, unknown-fault-id ignored, empty report.
5. Helpers: `_addr_median`/`_window_median` clamping at array ends; `_moving_average` edge behavior.

**Edge cases that matter most:** `fps == 0` (item 7), video shorter than the address window (item 6), no-pose video (item 5), corrupt/missing `drills.json` (item 8), and a `NaN` torso `scale`.

**Dart additions:** a `SwingAnalyzer._buildReport` test using injected `FrameFeatures` lists (no camera/ffmpeg needed) to lock the end-to-end verdict wiring; a corrupt-asset test for the drill loader.

---

## Architecture

### 14. Extract the shared video/landmark loop?

🟠 **Yes — recommended.** This is the single biggest structural win. A `src/pose_pipeline.py` with something like:

```python
def collect_pose_series(video_path):
    """Run the pose model once; return cached per-frame landmarks + metadata."""
    # returns: landmarks_per_frame (list, None where undetected),
    #          fps (guarded != 0), width, height, frame_count
```

Benefits: removes 5× duplication (item 4), fixes the `fps==0` crash (item 7) in one place, and lets each script/detector pull just the series it needs from cached landmarks (no re-running the model). It also isolates the MediaPipe dependency behind one seam — useful if the model or API changes.

### 15. Module organization

🟠 **Split "library" from "script".** Today each Python file mixes reusable functions with a `main()`/plotting entry point, and two files have **no `__main__` guard**:

- `src/pose_estimation.py` and `src/phase_montage.py` execute their whole pipeline **at import time**. Any module importing them (or a test) would run video processing as a side effect. Wrap the module bodies in `def main(): … / if __name__ == '__main__': main()`.
- Suggested shape: `src/analysis/` (pure: `swing_phases.py`, `faults.py`, `drill_recommender.py`), `src/pipeline.py` (shared collection, item 14), `src/scripts/` or CLI entry points for the render/plot tools. This mirrors the clean `flutter_app/lib/src/analysis` vs `services` vs `ui` split the Dart side already has.
- `data/drills.json` is duplicated as `flutter_app/assets/drills.json` (by design, since the app bundles its own copy). Keep, but note the root README already flags they must be kept in sync — a small `make sync-drills` or a test asserting the two files are byte-identical would prevent drift.

### 16. `requirements.txt` pinning

```
opencv-python==5.0.0.93
mediapipe==0.10.35
```

| Sev | Finding |
| --- | --- |
| 🔴 | **`matplotlib` is missing.** It's imported directly in `swing_phases.py`, `body_angles.py`, `phase_montage.py` but is **not** a dependency of opencv or mediapipe. A clean `pip install -r requirements.txt` then `python swing_phases.py` fails with `ModuleNotFoundError: matplotlib`. Add a pinned `matplotlib`. |
| 🟠 | **`numpy` not pinned.** Used pervasively but only present transitively via mediapipe. Pin it explicitly. Note: mediapipe 0.10.x has historically needed `numpy < 2`; verify against whatever numpy resolves (a 2.x numpy can break mediapipe). |
| 🟠 | **`opencv-python==5.0.0.93` is bleeding-edge.** It *does* exist on PyPI (the newest release, first of the 5.x line). mediapipe and most tutorials target opencv 4.x. Confirm 5.x is intentional; otherwise pin a proven 4.x (e.g., `4.11.0.86`) to avoid surprise ABI/behavior changes. |
| 🟡 | No `requirements-dev`/test deps (pytest) — add when the Python tests from item 13 land. |
| 🟢 | Flutter `pubspec.yaml` uses caret ranges (`^`) with an SDK constraint — idiomatic; no pinning issue. |

---

## Summary of what to fix first

1. 🔴 `fps == 0` → `ZeroDivisionError` in all four collection loops (item 7) — fold into the shared pipeline (item 14).
2. 🔴 `matplotlib` missing from `requirements.txt` (item 16) — clean installs can't run the plotting scripts.
3. 🟠 Guard corrupt/missing `drills.json` on both sides, especially the Flutter startup crash (item 8).
4. 🟠 Add a minimum-frame guard (item 6) and fix the empty-video montage crash (item 5).
5. 🟠 Extract the shared collection module + add `__main__` guards (items 14, 15).
6. 🟠 Add Python unit tests mirroring the Dart suite (items 12–13) — the source of truth is currently untested.

**Applied in this pass:** removed the unused `LEAD_SIDE` import (`src/pose_estimation.py`). Nothing else changed.
