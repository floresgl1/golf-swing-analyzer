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


def detect_phases(wrist_y, smooth=5):
    """Locate the key swing events from the lead-wrist vertical trajectory.

    Works on wrist *height* (1 - y, so up is positive), which rises through the
    backswing to a peak (top), drops to a valley (impact), then rises again to
    the finish. Returns frame indices for takeaway, top, impact and finish.
    """
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
