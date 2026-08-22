import matplotlib.pyplot as plt
import math
import numpy as np

# MediaPipe wrist landmark indices
LEFT_WRIST = 15
RIGHT_WRIST = 16

# Configuration
HANDEDNESS = 'right'  # 'right' or 'left'
# The tracked hand is the LEAD hand (closer to the target):
# left wrist for a right-handed golfer, right wrist for a lefty.
LEAD_WRIST = LEFT_WRIST if HANDEDNESS == 'right' else RIGHT_WRIST
LEAD_SIDE = 'Left' if HANDEDNESS == 'right' else 'Right'


# --------------------------------------------------------------------------- #
# Frame-rate-invariant windowing config
#
# Every smoothing/median window in the pipeline is a physical DURATION, but the
# code historically hard-coded it as a frame COUNT (smooth=5, radius=2, ...). A
# frame count only maps to a fixed duration at one frame rate. The calibration
# clip (data/videos/videoplayback.mp4) reports 30 fps in its container but is an
# 8x slow-motion render of a ~240 fps capture: its downswing is 64 frames
# (~0.27 s) and takeaway->finish is 272 frames (~1.13 s). So the original
# constants were implicitly tuned at 240 fps -- that is BASELINE_FPS, the rate
# at which frames_for() reproduces them exactly. Deriving the seconds constants
# from any other baseline (e.g. the container's 30) would be wrong.
#
# CONTAINER vs CAPTURE fps: cv2.CAP_PROP_FPS returns the *container* rate (30
# for the slow-mo clip), NOT the *capture* rate the windows must scale with.
# The capture rate cannot be recovered from a slow-mo file -- it has to be
# supplied as metadata (see the capture_fps note in main()). Until that exists,
# windowing stays pinned to BASELINE_FPS via the fps defaults below, which
# preserves the tuned behavior. Do NOT feed CAP_PROP_FPS into the windowing: at
# 30 fps every window collapses to a single frame.
BASELINE_FPS = 240.0

SMOOTH_WINDOW_S = 5 / BASELINE_FPS     # 0.021 s  <- was smooth=5  (centered kernel)
IMPACT_RADIUS_S = 2 / BASELINE_FPS     # 0.008 s  <- was radius=2  (impact: kept tight)
DEFAULT_RADIUS_S = 3 / BASELINE_FPS    # 0.012 s  <- was radius=3  (top/finish/impact-posture)

# KNOWN ISSUE -- do NOT "clean up" this constant to a rounder value ----------
# ADDRESS_OFFSET_S is the look-back from the wrist-defined takeaway used to
# sample the "settled" address pose. On the calibration clip this window does
# NOT sample a settled address. Body motion (shoulder+hip speed) begins at frame
# 23, but the wrist-defined takeaway fires at frame 55 -- 32 frames / 133 ms
# later, because in a one-piece takeaway the body rotates before the wrist
# climbs. The ta-10 window [45,55] therefore sits fully inside the takeaway
# motion: shoulders already rotated, torso foreshortened ~4%, spine tilt +2.6
# deg vs settled. That inflates every fault baseline (head sway ~+17%,
# loss-of-posture straighten +2.6 deg on a 12 deg threshold, ~+22%), and the
# 0.13 / 12 deg thresholds have SILENTLY ABSORBED that inflation.
# The fix is not a different offset -- the *anchor* (wrist takeaway) is itself
# past motion onset, so no window ending at takeaway is settled. It needs a
# body-motion-onset anchor (detect_address_onset) PLUS recalibration of all four
# thresholds against the validation corpus. Tracked in ROADMAP.md P0; blocked on
# the corpus. Preserved as-is (10 frames @240) to keep this refactor behavior-
# preserving.
ADDRESS_OFFSET_S = 10 / BASELINE_FPS   # 0.042 s  <- was takeaway-10  (SEE KNOWN ISSUE)


# --------------------------------------------------------------------------- #
# Swing localization in a long clip (P1.3, 2026-08-17)
#
# Filming yourself means the clip contains a walk-in, the swing, and a walk-back:
# the first five real recordings ran 15-18 s for a 1-2 s swing. `detect_phases`
# anchors `top` on the FIRST peak clearing half the height range, which in a
# 16 s clip is incidental hand movement during setup -- it put `top` at frames
# 1, 4, 8 and 15, so every fault value was measured between meaningless anchors.
#
# The fix is a different anchor. A golf swing's unmistakable signature is not a
# tall peak, it is the FASTEST DOWNWARD WRIST MOTION in the clip: nothing else a
# golfer does between walking in and walking out drops the lead wrist that hard.
# Locate that, then read the other events off it within bounded look-arounds.
#
# These bounds are DURATIONS, in seconds, so they are frame-rate invariant like
# the P0.3 windowing constants. They are generous limits on swing geometry -- a
# backswing does not take 2 s, a downswing does not take 1 s -- and NOT tuned
# thresholds on a measured quantity. Nothing here borrows against the P0.1
# corpus: widen them and the answer does not drift, it only admits clips that
# were never swings.
DESCENT_SMOOTH_S = 0.10    # smoothing for wrist height and its derivative
TOP_SEARCH_S = 1.5         # look back from the steepest descent for the top
IMPACT_SEARCH_S = 1.0      # look forward from the top for impact
TAKEAWAY_SEARCH_S = 2.0    # look back from the top for the takeaway
FINISH_SEARCH_S = 1.5      # look forward from impact for the finish

# How far the hips may travel, in torso lengths, over a one-second window and
# still count as standing still. This bounds the swing search to the stance --
# see `stance_bounds`. It is normalised by torso length, so it does not depend
# on the golfer's distance from the camera or the video's resolution.
#
# Measured, not chosen by eye: the result is IDENTICAL from 0.25 through 1.5,
# a six-fold range, on the six video-labelled swings. 0.4 sits in the middle of
# that plateau. It only starts to matter at 2.0, where the window grows enough
# to swallow part of the walk-in again.
STANCE_TRAVEL_MAX = 0.4


def frames_for(seconds, fps, minimum=1, odd=False):
    """Convert a duration in seconds to a frame count at the given fps.

    Never returns 0: a zero-width window silently disables the thing it is
    windowing rather than raising, so the result is clamped to `minimum` (>=1).
    The policy question "is this fps too low to trust?" belongs at the input
    gate (require_valid_fps / the capture spec), not here -- this stays a total
    function and the clamp is a safety net, not the gate.

    Pass odd=True for a centered moving-average kernel (the smoothing window):
    an even-length kernel offsets the average by half a frame, which shifts the
    minima/maxima detect_phases locates. Even results are bumped up to the next
    odd frame (never down -- bumping up never under-smooths).
    """
    n = int(round(seconds * fps))
    if odd and n % 2 == 0:
        n += 1
    return max(n, minimum)


def require_valid_fps(fps, video_path):
    """Return fps as a float, or exit with a clear error when it is unusable.

    OpenCV reports 0 (or nan) for the FPS of a missing, unreadable, or corrupt
    video; downstream timestamp and tempo math divides by fps, so a bad value
    must stop the run before it turns into a ZeroDivisionError traceback.
    """
    try:
        fps = float(fps)
    except (TypeError, ValueError):
        fps = 0.0
    if not math.isfinite(fps) or fps <= 0:
        raise SystemExit(
            f"Error: could not read a valid frame rate from '{video_path}' "
            f"(got {fps!r}). The video file may be missing, unreadable, or corrupt."
        )
    return fps


def _moving_average(a, w):
    """Smooth a 1-D array with a centered moving average (edge-padded)."""
    if w <= 1:
        return a.astype(float)
    pad = w // 2
    padded = np.pad(a, pad, mode='edge')
    kernel = np.ones(w) / w
    return np.convolve(padded, kernel, mode='valid')[:len(a)]


def detect_phases(wrist_y, fps=BASELINE_FPS, smooth=None, torso=None,
                  hip_x=None):
    """Locate the key swing events from the lead-wrist vertical trajectory.

    Works on wrist *height* (1 - y, so up is positive), which rises through the
    backswing to a peak (top), drops to a valley (impact), then rises again to
    the finish. Returns frame indices for takeaway, top, impact and finish.

    The smoothing kernel is a duration (SMOOTH_WINDOW_S) resolved to an odd
    frame count at `fps`; at BASELINE_FPS this is the historic smooth=5. Pass an
    explicit `smooth` to override the frame count directly.
    """
    # Opt-in, because it needs signals the historic call sites do not pass.
    # Without `torso` the original peak-based localization runs unchanged,
    # which is what the calibration clip and the existing tests exercise.
    #
    # `hip_x` additionally bounds the search to the stance, and it is the only
    # form with any measured support: against labels, peak localization scores
    # 0/10, descent-anchored-over-the-whole-clip 2/10, and stance-bounded 9/10.
    # See locate_swing and P1.4 in ROADMAP.md.
    if torso is not None:
        located = locate_swing(wrist_y, torso, fps, hip_x=hip_x)
        if located is not None:
            return located
        # When the caller asked for stance bounding and no stance was found,
        # that is an ANSWER, not a gap to paper over. Falling through to peak
        # localization here would replace "the golfer never stood still, so
        # there is no swing to locate" with a guess from a method measured at
        # 0/10 -- and it did exactly that on a no-swing clip of 2026-08-20,
        # turning a usable decline into an invented swing at 0.2s.
        if hip_x is not None:
            return None

    if smooth is None:
        smooth = frames_for(SMOOTH_WINDOW_S, fps, odd=True)
    y = np.array(wrist_y, dtype=float)
    n = len(y)
    idx = np.arange(n)

    # Fill frames with no detection (nan) by linear interpolation
    good = ~np.isnan(y)
    if good.sum() < 2:
        return None
    y = np.interp(idx, idx[good], y[good])

    height = _moving_average(1.0 - y, smooth)   # up is positive

    # Local maxima of height (wrist momentarily highest)
    peaks = [i for i in range(1, n - 1)
             if height[i] >= height[i - 1] and height[i] > height[i + 1]]

    # Top of backswing = the first "tall" peak (wrist highest during backswing)
    span = height.max() - height.min()
    tall = [i for i in peaks if height[i] >= height.min() + 0.5 * span]
    top = tall[0] if tall else int(np.argmax(height[: n // 2]))

    # Impact = lowest wrist point after the top (the wrist only rises afterward,
    # so the global minimum of the tail is the impact trough).
    impact = int(np.argmin(height[top:]) + top)

    # Finish = highest wrist point after impact (top of the follow-through)
    finish = int(np.argmax(height[impact:]) + impact)

    # Takeaway = the lowest wrist point before the top, i.e. the bottom of the
    # address "sit" right before the wrist commits to its climb to the top.
    # This is the true start of the backswing, so the backswing duration and
    # tempo ratio aren't clipped by a later threshold crossing.
    takeaway = int(np.argmin(height[:top])) if top > 0 else 0

    return {'takeaway': takeaway, 'top': top, 'impact': impact, 'finish': finish}


def implausible_swing(phases):
    """Return why `phases` cannot describe a golf swing, or None if it might.

    This answers PRESENCE, not severity. `detect_phases` locates its events with
    argmin/argmax over slices, and those always return an index — so it reports
    phases for any trajectory whatsoever, including one interpolated out of a
    video containing no golfer. Found on device 2026-08-17: a clip of nothing
    produced a full fault report with drills. See P1.1 in ROADMAP.md.

    Every check here is an impossibility, not a tuned threshold, so none of them
    borrow against the P0.1 corpus:

      - The events must be strictly ordered. `detect_phases` guarantees only
        takeaway <= top <= impact by construction; equality means a phase has
        zero duration, which is not a swing that happened.

    REMOVED 2026-08-17: a tempo-inversion check (backswing must outlast the
    downswing) lived here and rejected 3 of the first 4 real swings measured on
    a phone. It rested on the detected phases meaning something; on real device
    clips they do not. See P1.3 in ROADMAP.md. Do not reinstate it without
    fixing phase location first.

    Deliberately NOT checked here: anything needing a calibrated number. If a
    proposed check requires a constant only P0.1 can supply, it belongs in P0.2.
    """
    if not phases:
        return 'no phases were detected'

    takeaway = phases['takeaway']
    top = phases['top']
    impact = phases['impact']

    if top <= takeaway:
        return ('the backswing has no duration (takeaway and top are the same '
                'frame)')
    if impact <= top:
        return ('the downswing has no duration (top and impact are the same '
                'frame)')

    return None



def stance_bounds(hip_x, torso, fps, travel_max=STANCE_TRAVEL_MAX):
    """Frame range over which the golfer is standing still, or None.

    Filming yourself means the clip contains a walk-in, a stance, and a walk
    away. Only the stance can contain a swing, and everything that has gone
    wrong with localization so far has gone wrong outside it: `detect_phases`
    anchors on walk-in pose garbage (0/10 against labels), and `locate_swing`
    anchors on the club being lowered into address, which out-descends the
    downswing itself (2/10). See P1.4 in ROADMAP.md.

    Standing still is measured as hip travel over a one-second window, in torso
    lengths. Returns the longest such run as a (lo, hi) frame range.
    """
    hip_x = np.asarray(hip_x, float)
    torso = np.asarray(torso, float)
    n = len(hip_x)
    if n == 0:
        return None

    tracked = np.isfinite(hip_x) & np.isfinite(torso)
    if tracked.sum() < 3:
        return None

    win = frames_for(1.0, fps)
    still = np.zeros(n, dtype=bool)
    for i in range(n):
        lo, hi = max(0, i - win // 2), min(n, i + win // 2 + 1)
        seg = hip_x[lo:hi][tracked[lo:hi]]
        scale = torso[lo:hi][tracked[lo:hi]]
        if len(seg) < 3:
            continue
        still[i] = (seg.max() - seg.min()) / max(np.median(scale), 1e-6) < travel_max

    best = None
    i = 0
    while i < n:
        if still[i]:
            j = i
            while j < n and still[j]:
                j += 1
            if best is None or j - i > best[1] - best[0]:
                best = (i, j)
            i = j
        else:
            i += 1
    return best


def locate_swing(wrist_y, torso, fps, hip_x=None):
    """Locate the four swing events by anchoring on the downswing.

    *** WITH `hip_x` THIS IS WHAT THE APP RUNS as of 2026-08-20. Without it,
    do not enable it: the unbounded form is measured at 2/14 against device
    labels. READ P1.4 IN ROADMAP.md BEFORE CHANGING EITHER. ***

    Scored against 14 labelled device swings and 3 labelled no-swing clips:

        peak localization (detect_phases)   0/14 found,  0/3 declined
        this, unbounded                     2/14 found,  0/3 declined
        this, bounded by `hip_x`           12/14 found,  1/3 declined

    **Two claims this docstring used to make were false and are recorded here
    so they are not repeated.** It said the method was "demonstrably better on
    the five real recordings" -- that was read off plots, and labels put the
    unbounded form at 2/14. It said the answer moves six seconds between
    DESCENT_SMOOTH_S 0.05 and 0.10 -- on clips where the swing can actually be
    checked the answer is identical from 0.07 through 0.30. Both claims were
    made by looking at unlabelled data, which is the failure mode P0.4 exists
    to record.

    The remaining known miss is a practice swing: clip 3 of 2026-08-20 holds
    one at ~8 s and the real swing at ~13 s, both inside the stance, and this
    takes the first. That is not a tuning problem. A practice swing IS a swing
    -- right shape, right duration, right descent rate -- so nothing in the
    signal separates them, and only something that knows which swing the golfer
    meant can choose.

    Returns the same dict as `detect_phases`, or None when the trajectory is
    too short, has no usable pose, or -- when `hip_x` was supplied -- when
    there is no stance. **That last None is an answer, not a gap:** the golfer
    never stood still, so there is no swing to locate. Do not let a caller fall
    back to peak localization on it; doing so turned a usable decline into an
    invented swing at 0.2 s on a no-swing clip.

    Why this exists, and why it anchors where it does, is in the block comment
    above the *_SEARCH_S constants. In one line: `detect_phases` looks for the
    first tall wrist peak, and in a clip that contains a walk-in that peak is
    not the top of the backswing.

    `torso` is required because the descent rate is normalised by torso length,
    making it torso-lengths per second -- scale-invariant, so it does not depend
    on the golfer's distance from the camera or the video's resolution. That is
    the same normalisation the fault detectors use.
    """
    y = np.array(wrist_y, dtype=float)
    t = np.array(torso, dtype=float)
    n = len(y)
    if n < 3 or len(t) != n:
        return None

    idx = np.arange(n)
    good = ~np.isnan(y)
    if good.sum() < 2:
        return None
    y = np.interp(idx, idx[good], y[good])

    good_t = ~np.isnan(t)
    if good_t.sum() < 1:
        return None
    t = np.interp(idx, idx[good_t], t[good_t])
    t = np.maximum(t, 1e-6)

    w = frames_for(DESCENT_SMOOTH_S, fps, odd=True)
    height = _moving_average(-y, w)

    # Descent rate in torso-lengths per second; most negative = fastest drop.
    rate = np.zeros(n)
    rate[1:] = np.diff(height) / t[1:] * fps
    rate = _moving_average(rate, w)

    # Bound the search to the stance when the hips are available. Without it
    # this is the localization measured at 2/10 -- kept reachable so the
    # comparison stays runnable, not because it is worth using.
    lo_b, hi_b = 0, n
    if hip_x is not None:
        bounds = stance_bounds(hip_x, t, fps)
        if bounds is None or bounds[1] - bounds[0] < frames_for(1.0, fps):
            return None
        lo_b, hi_b = bounds

    steepest = lo_b + int(np.argmin(rate[lo_b:hi_b]))

    def _back(frm, seconds):
        return max(lo_b, frm - frames_for(seconds, fps))

    def _fwd(frm, seconds):
        return min(hi_b, frm + frames_for(seconds, fps) + 1)

    lo = _back(steepest, TOP_SEARCH_S)
    top = lo + int(np.argmax(height[lo:steepest + 1]))

    hi = _fwd(top, IMPACT_SEARCH_S)
    impact = top + int(np.argmin(height[top:hi])) if hi > top else top

    lo2 = _back(top, TAKEAWAY_SEARCH_S)
    takeaway = lo2 + int(np.argmin(height[lo2:top + 1])) if top > lo2 else lo2

    hi2 = _fwd(impact, FINISH_SEARCH_S)
    finish = impact + int(np.argmax(height[impact:hi2])) if hi2 > impact else impact

    return {'takeaway': takeaway, 'top': top, 'impact': impact, 'finish': finish}


def swing_tempo(phases, fps):
    """Compute backswing/downswing durations and their tempo ratio.

    Backswing = takeaway -> top of backswing.
    Downswing = top of backswing -> impact.
    The ratio is expressed as backswing : downswing; tour players average ~3:1.
    """
    if not phases or not fps:
        return None
    backswing_frames = phases['top'] - phases['takeaway']
    downswing_frames = phases['impact'] - phases['top']
    backswing_s = backswing_frames / fps
    downswing_s = downswing_frames / fps
    ratio = backswing_s / downswing_s if downswing_s else float('nan')
    return {
        'backswing_frames': backswing_frames,
        'downswing_frames': downswing_frames,
        'backswing_s': backswing_s,
        'downswing_s': downswing_s,
        'ratio': ratio,
    }


def main():
    from pose_pipeline import run_pose_detection
    result = run_pose_detection('data/videos/videoplayback.mp4')
    wrist_y = result.wrist_y()
    # CONTAINER fps: correct for the tempo RATIO (frame-based, so it cancels)
    # and for timestamps, but NOT the CAPTURE fps the windows scale with --
    # for slow-mo clips they differ (see BASELINE_FPS notes). detect_phases
    # is therefore left on its BASELINE_FPS default; wire a real capture_fps
    # here once the corpus carries it as metadata.
    fps = result.fps

    # Detect the swing phases from the trajectory
    phases = detect_phases(wrist_y)
    n = len(wrist_y)

    def _t(f):
        return f / fps if fps else 0.0

    if phases:
        print("\nDetected swing phases:")
        print(f"  Address:        frames {0:>4}-{phases['takeaway']:<4} "
              f"({_t(0):.2f}-{_t(phases['takeaway']):.2f}s)")
        print(f"  Backswing:      frames {phases['takeaway']:>4}-{phases['top']:<4} "
              f"({_t(phases['takeaway']):.2f}-{_t(phases['top']):.2f}s)")
        print(f"  Downswing:      frames {phases['top']:>4}-{phases['impact']:<4} "
              f"({_t(phases['top']):.2f}-{_t(phases['impact']):.2f}s)")
        print(f"  Follow-through: frames {phases['impact']:>4}-{n - 1:<4} "
              f"({_t(phases['impact']):.2f}-{_t(n - 1):.2f}s)")
        print(f"  -> Top of backswing @ frame {phases['top']} ({_t(phases['top']):.2f}s)")
        print(f"  -> Impact           @ frame {phases['impact']} ({_t(phases['impact']):.2f}s)")

        tempo = swing_tempo(phases, fps)
        print("\nSwing tempo:")
        print(f"  Backswing: {tempo['backswing_s']:.2f}s ({tempo['backswing_frames']} frames)")
        print(f"  Downswing: {tempo['downswing_s']:.2f}s ({tempo['downswing_frames']} frames)")
        print(f"  Ratio (backswing:downswing): {tempo['ratio']:.1f} : 1  (tour avg ~3 : 1)")

    # Step 7: Plot the wrist trajectory with the phases annotated
    plt.figure(figsize=(12, 4))
    plt.plot(wrist_y, color='tab:blue', zorder=3)

    if phases:
        spans = [
            (0, phases['takeaway'], 'Address', '#cfe8ff'),
            (phases['takeaway'], phases['top'], 'Backswing', '#c7f0d8'),
            (phases['top'], phases['impact'], 'Downswing', '#ffe0b3'),
            (phases['impact'], n - 1, 'Follow-through', '#f3d0ff'),
        ]
        for start, end, label, color in spans:
            plt.axvspan(start, end, color=color, alpha=0.6, label=label)
        for f, color in [(phases['top'], 'green'),
                         (phases['impact'], 'red'),
                         (phases['finish'], 'purple')]:
            plt.axvline(f, color=color, linestyle='--', linewidth=1)
        plt.legend(loc='lower right', fontsize=8, ncol=4)

    plt.title(f'{LEAD_SIDE} Wrist Y-Position Over Time')
    plt.xlabel('Frame')
    plt.ylabel('Y (normalized)')
    # MediaPipe y grows downward (0 = top of frame), so invert the axis to make
    # a raised wrist read as a peak. Remove this line to see the raw values.
    plt.gca().invert_yaxis()
    plt.tight_layout()
    plt.savefig('output/wrist_trajectory.png', dpi=120)
    plt.show()


if __name__ == '__main__':
    main()
