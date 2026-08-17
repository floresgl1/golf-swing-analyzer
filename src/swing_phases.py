import cv2
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision
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


def detect_phases(wrist_y, fps=BASELINE_FPS, smooth=None):
    """Locate the key swing events from the lead-wrist vertical trajectory.

    Works on wrist *height* (1 - y, so up is positive), which rises through the
    backswing to a peak (top), drops to a valley (impact), then rises again to
    the finish. Returns frame indices for takeaway, top, impact and finish.

    The smoothing kernel is a duration (SMOOTH_WINDOW_S) resolved to an odd
    frame count at `fps`; at BASELINE_FPS this is the historic smooth=5. Pass an
    explicit `smooth` to override the frame count directly.
    """
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
      - The backswing must outlast the downswing. The downswing is gravity- and
        release-assisted and is universally the faster half — tour players
        average ~3:1 and amateurs less, but the ordering itself does not
        invert. This is an empirical invariant of golf swings rather than a law
        of physics, so it is deliberately set AT the inversion point: it
        rejects 0.1:1, and passes 1.1:1 even though that is a strange swing.
        Judging *how good* a tempo is needs the corpus; judging that a swing
        took ten times longer coming down than going up does not.

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

    backswing_frames = top - takeaway
    downswing_frames = impact - top
    if backswing_frames <= downswing_frames:
        return (f'the downswing ({downswing_frames} frames) is not shorter '
                f'than the backswing ({backswing_frames} frames), which does '
                'not happen in a golf swing')

    return None


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
    # Step 1: Configure the PoseLandmarker
    base_options = python.BaseOptions(model_asset_path='data/pose_landmarker.task')
    options = vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO
    )

    # Collect the lead-wrist y-coordinate from every frame
    wrist_y = []

    # Step 2: Create the landmarker and open the video
    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        cap = cv2.VideoCapture('data/videos/videoplayback.mp4')
        # CONTAINER fps: correct for the tempo RATIO (frame-based, so it cancels)
        # and for timestamps, but NOT the CAPTURE fps the windows scale with --
        # for slow-mo clips they differ (see BASELINE_FPS notes). detect_phases
        # is therefore left on its BASELINE_FPS default; wire a real capture_fps
        # here once the corpus carries it as metadata.
        fps = require_valid_fps(cap.get(cv2.CAP_PROP_FPS), 'data/videos/videoplayback.mp4')
        frame_count = 0

        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break

            # Step 3: Convert to MediaPipe Image (BGR → RGB, then wrap)
            rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb_frame)

            # Step 4: Calculate timestamp and detect
            timestamp_ms = int(frame_count * 1000 / fps)
            results = landmarker.detect_for_video(mp_image, timestamp_ms)
            frame_count += 1

            # Step 5: Record the lead-wrist y (normalized 0..1).
            # Append nan when no pose is found so the frame still occupies an
            # x-axis slot and the plot shows a gap instead of shifting everything.
            if results.pose_landmarks:
                wrist_y.append(results.pose_landmarks[0][LEAD_WRIST].y)
            else:
                wrist_y.append(float('nan'))

        cap.release()

    # Step 6: Detect the swing phases from the trajectory
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
