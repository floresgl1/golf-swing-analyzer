# GolfDB validation harness

External-dataset validation for the golf-swing analyzer, built in two stages so
the first stage's answer gates whether the second is worth building.

Dataset: GolfDB (McNally et al., CVPRW 2019, github.com/wmcnally/golfdb) — 1,400
annotated real golf swings. The annotation DB is redistributed; videos are not
(they are YouTube IDs to re-download and trim).

> **LICENSE / PROVENANCE — read before shipping.** GolfDB is **CC BY-NC 4.0
> (NonCommercial)**. Using it to *validate* the analyzer during development is
> fine. But if this app ever ships commercially and **any threshold or design
> number traces back to values derived from GolfDB**, that provenance is a
> question someone will eventually ask. Any such number must be re-derived from
> a license-clean corpus (the P0.1 self-captured set) before productization.
> GolfDB is used here as a validation *check*, never as a source of shipped
> constants.

## Stage 1 — ingestion + screening (DONE)

`python validation/golfdb/screen.py` — annotation-level only, **no video
downloads**. Writes `manifest_dtl.csv` (down-the-line clips) with the Stage-2
metadata discipline pre-created and blank (`capture_fps`, `capture_fps_source`,
`model_sha256`).

### Result (1,400 clips)

| filter | count |
|---|---|
| down-the-line (view) | **585** |
| └ real-time (`slow`=0) | 310 |
| └ slow-mo (`slow`=1) | 275 |
| any pre-address frames | 585 / 585 (100%) |
| ≥15 pre-address frames | 543 (93%) |
| **body-type metadata** | **none (sex only)** |

### Verdict

- **GolfDB cannot substitute for P0.1 collection.** No height/build field exists,
  so the body-type axis — the actual P0 goal — is unrecoverable. And no clip meets
  the ≥120 fps capture spec: real-time clips are ~30 fps (below floor), slow-mo
  clips have a deceptive container rate. GolfDB is a **validation aid, not a
  spec-meeting corpus.** The range/afternoon capture is still required.
- **It is viable for Stage 2 validation**: 585 down-the-line clips with real
  event labels, and pre-address footage is abundant (not the limiter).
- **fps is the gate, not a detail.** `slow` is a better screen than CAP_PROP_FPS:
  for slow-mo, CAP_PROP_FPS returns the container rate — the exact bug the
  pipeline just fixed. Stage 2 must **establish capture fps per clip and refuse
  to run where it can't**, never falling back to CAP_PROP_FPS.

## Stage 2 — validation (NOT built; gated on a download-availability probe)

Order matters (cleaner signal first):
1. **Phase-detection error** vs GolfDB event labels — signed per-event frame
   offsets, distribution not just mean. Ground truth, threshold-independent.
   Target the **310 real-time clips**: for `slow`=0, container fps = capture fps,
   so the refuse-to-run gate can establish it; `slow`=1 is refused (container
   rate untrustworthy). This measures phase accuracy at ~30 fps — itself useful
   degradation data.
2. **FPR on pros** — second, and weaker evidence: it measures the *uncorrected*
   pipeline (address window still biased +17–22%, see ROADMAP P0.2). A baseline
   to compare against after P0.2, not an absolute verdict.

**Before building the comparison, probe download availability** on the 310
real-time IDs — years-old YouTube links attrit (deleted, region-locked). That
count gates Stage 2 the same way the screening count gated Stage 1. Stamp
`model_sha256` per clip on every detector run.

### Distribution: use `videos_160`, NOT yt-dlp, for phase detection (Stage 2a)

The authors distribute the preprocessed 160×160 clips directly (Google Drive,
linked in the GolfDB README) — all 1,400 clips in one file, **no scraping, no
attrition, no ToS issue.** The preprocessing (bbox crop → resize max=160 →
letterbox) destroys torso normalization, so `videos_160` is **useless for the FPR
half** (fault detection needs fine landmarks), but it preserves the wrist-height
trajectory `detect_phases` needs.

Verified the 160×160 degradation is tolerable before downloading anything: GolfDB's
exact preprocessing applied to our full-res calibration clip gave **100% pose
detection** and offsets **impact +1, finish +0, takeaway +3, top +7** frames.
`top` is the least robust (flat peak) and will have the widest offset spread;
impact/finish are near-exact. Caveat: the calibration clip is sharper than GolfDB
real-time YouTube, so spot-check ~5 real `videos_160` clips before the full run.

**Spot-check on 5 real `videos_160` clips (DONE — the gate).** 5 real-time
down-the-line clips (Gal, DiMarco, Henderson, Watney, Stanley), pose + lead-wrist:

| id | wrist vis (med) | vis @top±3 | %vis<0.5 | detTop−labTop | detImpact−labImpact | detFinish−labFinish |
|---|---|---|---|---|---|---|
| 0 | 0.51 | 0.53 | 36% | −3 | −1 | −6 |
| 2 | **0.24** | 0.36 | 84% | **0** | +1 | −5 |
| 4 | 0.64 | 0.75 | 31% | −2 | −1 | −6 |
| 6 | 0.50 | 0.57 | 53% | −2 | 0 | −9 |
| 12 | 0.60 | 0.69 | 38% | −1 | −1 | −7 |

Findings:
- **Pose detection 100%** on all 5.
- **Wrist visibility is marginal — resolution IS a limiter at 160×160, as predicted.**
  Medians 0.24–0.64; often <0.5; DiMarco sits at 0.24 (84% of frames <0.5).
- **But Top/Impact detection is robust to it:** matches ground-truth labels to
  **±3 (Top) and ±1 (Impact)** — even on the 0.24-visibility clip, which hit Top
  *exactly*. Reason: `detect_phases` keys off the smoothed-trajectory SHAPE
  (argmin/argmax, high inflection-SNR), not per-frame confidence. Low visibility ≠
  broken phase detection here.
- **Finish has a systematic −5 to −9 offset = DEFINITIONAL**, not error: our finish
  (wrist-height peak in follow-through) precedes GolfDB's posed Finish. A finding
  to report, not a miss.
- **Takeaway is NOT reliably testable on `videos_160`:** the plot shows spurious
  wrist spikes in the settled-address region (id 0), which corrupt "lowest wrist
  before top", on top of the known Address-vs-takeaway definitional gap (P0.2).

**Verdict: `videos_160` validates Top/Impact phase detection — scope the harness to
those two events.** Report the Finish offset separately as a definitional finding;
exclude takeaway; add an inflection-SNR gate to drop clips whose trajectory shape
is too degraded rather than trusting all blindly. Full-res is NOT warranted —
Top/Impact already validate cleanly at 160×160. (Trajectory montage:
`spotcheck_wrist.png`.)

Consequences:
- **Stage 2a (phase detection): `videos_160`.** The availability probe below and
  its yt-dlp download plan are therefore MOOT for Stage 2a — kept only for a
  possible Stage 2b (FPR), which needs full-res and is the weaker signal anyway.
- **License: GolfDB is CC BY-NC.** Fine for internal validation; NOT for
  redistribution or shipping inside a commercial product. Flag before Stage 2b or
  any productization.

### Pre-registered abort threshold (decided BEFORE the probe ran)

Fixed in advance so the result can't be rationalized after the fact. Applied to
**clips covered by resolvable YouTube IDs** (probe by unique id; multiple clips
share one video):

| resolvable clips | decision |
|---|---|
| **< 40** | **ABORT** the comparison harness — spot-check ~10 clips by hand instead. Below this the per-event offset distribution is a shaky mean with no visible tails. |
| 40–150 | **BUILD, tails under-powered** — report per-event mean + IQR; label p90/p99 outlier behavior as under-sampled. |
| > 150 | **BUILD, full** — mean, spread, and the tail behavior that actually matters. |

**Probe result (`probe_availability.py`, oembed):** 274/274 unique ids resolve,
covering **310/310 clips → verdict BUILD, full.** The probe was checked against
known-dead ids (404/400) and a known-live one (200), so the sweep is real, not a
stuck-200 bug. Caveat: oembed tests existence + embeddability, NOT downloadability
— it misses region-locks, age-gates, and channel re-edits that yt-dlp will hit,
so 310 is an upper bound and the real-download count will be lower. Even a 25–30%
haircut stays >150, so the verdict holds; confirm the true count with yt-dlp at
download time (and re-check the biased-attrition caveat below against whatever
actually survives).

### Smoothing at 30 fps — decision: validate NATIVE (smooth→1), do NOT override to 5

The real-time clips are ~30 fps, so `frames_for(SMOOTH_WINDOW_S, 30)` collapses the
kernel to 1 (no smoothing). The tempting fix — override to the production 5-frame
kernel — is **wrong here, and the reason has teeth:**

- Production smooths over `SMOOTH_WINDOW_S` = 21 ms (5 frames @240, 3 @120).
- One 30 fps frame **is 33 ms** — already *longer* than production's 21 ms window.
- So at 30 fps you cannot smooth as *little* as production does; 1 frame (no
  averaging) is the closest achievable to production's smoothing strength.
  Overriding to 5 frames means **167 ms** of smoothing — ~8× production's physical
  window, and ~8× stronger *relative to the swing* (a 30 fps swing spans ~34
  frames vs ~272 at 240). That validates a config *further* from production, not
  closer.

Original conclusion (native/smooth=1) was **REVERSED by the harness calibration
data** — recorded here honestly rather than edited away:

> The calibration run scored `detect_phases` at smooth=1 and smooth=5 on the same
> 5 clips. At **smooth=1**: Top offset mean −16.8, **sd 30.3** (id 0 detected 71
> frames early); Impact sd 15.5. At **smooth=5**: Top −1.6 **sd 1.1**, Impact −0.4
> sd 0.9. The smooth=1 blow-up is driven by 160px wrist-tracking spikes in the
> address region — a **GolfDB-resolution artifact production does not have**, not a
> property of the swing. So smooth=1 measures the tracking noise, not the
> event-location logic. Smoothing is load-bearing at this resolution.

**Decision: headline the run at smooth=5** (the production-shape kernel — your
original lean), which suppresses the resolution artifact and measures the actual
event-location logic. Keep smooth=1 in the output only as the load-bearing
comparison.

The reversal is subtler than "the original reasoning was wrong" — BOTH things are
true, and losing either loses the insight:
1. The physical-window argument was **correct on its own terms**: 5 frames at
   30 fps is 167 ms, ~8× production's 21 ms window. If matching production's
   *smoothing strength* were the goal, smooth=1 would indeed be closer.
2. But at 160 px the trajectory carries **tracking artifacts production doesn't
   have**, so the kernel is doing a *second* job — artifact suppression — that has
   nothing to do with matching production's smoothing. Here that second job is the
   one that matters: without it the offset measures noise, not the event logic.
So we're not matching production's kernel; we're using a kernel wide enough to
absorb a resolution artifact so the *rest* of the pipeline can be validated. That
has a consequence worth measuring (below).

**Consequence — clarity should correlate with Top offset too, not just Finish.**
If the kernel is absorbing artifact, a clip's residual offset partly reflects
*how much* artifact it had to absorb — i.e. how noisy the trajectory was. So even
at smooth=5, if Top |offset| rises as clarity falls, that is the **kernel's limit**
showing through, and it tells us where the 160 px approach degrades. The harness
now reports `corr(|Top offset|, clarity)` and `corr(|Impact offset|, clarity)` at
smooth=5 alongside the Finish check.

(Do not upsample to fake 240 fps — the
30 fps labels/source are quantized to ±1 frame, so a finer kernel would be false
precision.)

### PRE-REGISTERED clarity gate (decided BEFORE the full run)

`clarity = amplitude(5-smoothed height) / std(raw − 5-smoothed)` — swing size in
units of per-frame jitter. The 5 spot-check clips span **13.3–41.3** and all
detect Top/Impact well at smooth=5; the lowest (id 0, 13.3, visible address
spikes) is the marginal-but-working case. **Gate: clarity ≥ 10.0** — just below
id 0, so clips at least that clean are admitted, clearly-worse ones flagged. The
full run reports offsets both ungated and gated **and the drop rate**, so if the
gate excludes a large fraction the headline is honestly "works on the clean
clips, which are X% of them." Not tuned against the full-run offsets.

### Attrition is not random (README-level caveat for whatever survives)

Older clips and tour-broadcast footage die faster (rights takedowns) than
instructional content, so the surviving subsample is biased on top of GolfDB's
existing pro-heavy, homogeneous-build bias. Frame-offset error is fairly robust
to *which* swings are sampled, so the phase-detection test survives this. **The
FPR number does not** — never read it as representative of anything; it is a
baseline for the *same clips* before vs after P0.2, nothing more.
