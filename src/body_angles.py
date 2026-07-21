import cv2
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision
import matplotlib.pyplot as plt
import numpy as np
import math

from swing_phases import detect_phases, LEAD_WRIST

# MediaPipe landmark indices
LEFT_SHOULDER = 11
RIGHT_SHOULDER = 12
LEFT_HIP = 23
RIGHT_HIP = 24

VIDEO_PATH = 'data/videos/videoplayback.mp4'
OUTPUT_PATH = 'output/body_angles.png'


def line_angle(p1, p2):
    """Angle of the line p1->p2 relative to horizontal, in degrees.

    Points are (x, y) in *pixels* (convert from normalized landmark coords
    first, or the frame's aspect ratio distorts the angle). Image y grows
    downward, so dy is negated to give the intuitive orientation. The result is
    folded into [-90, 90] so it measures the line's tilt regardless of point
    order: 0 = perfectly level, positive = the line rises from left to right.
    """
    dx = p2[0] - p1[0]
    dy = p2[1] - p1[1]
    return _fold(math.degrees(math.atan2(-dy, dx)))


def _fold(a):
    """Fold an angle (deg) into [-90, 90] so a line and its reverse match."""
    a = np.asarray(a, dtype=float)
    a = np.where(a > 90, a - 180, a)
    a = np.where(a < -90, a + 180, a)
    return a if a.ndim else float(a)


def smooth_line_angles(vx, vy, w=9):
    """Circular (period-180) smoothing of undirected line angles.

    vx, vy are per-frame line-vector components in pixels (nan where the pose
    was not detected). Each frame is mapped to z = (vx + i*vy)**2, whose angle
    is 2*theta (so opposite directions coincide and the 180-degree wrap is
    handled) and whose magnitude is length**2 (so foreshortened / unreliable
    lines are automatically down-weighted). The complex values are box-averaged
    over a window of w frames and converted back. Returns degrees in [-90, 90].
    """
    vx = np.asarray(vx, dtype=float)
    vy = np.asarray(vy, dtype=float)
    z = (vx + 1j * vy) ** 2
    valid = np.isfinite(z)
    z = np.where(valid, z, 0)
    kernel = np.ones(w)
    total = np.convolve(z, kernel, mode='same')
    count = np.convolve(valid.astype(float), kernel, mode='same')
    with np.errstate(invalid='ignore', divide='ignore'):
        mean = np.where(count > 0, total / count, np.nan)
    angle = 0.5 * np.degrees(np.angle(mean))
    angle[count == 0] = np.nan
    return angle


def main():
    # Configure the PoseLandmarker
    base_options = python.BaseOptions(model_asset_path='data/pose_landmarker.task')
    options = vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO
    )

    # Per-frame line vectors (pixels), with y negated so "up" is positive
    sx, sy, hx, hy = [], [], [], []
    wrist_y = []   # collected only so we can reuse detect_phases for context

    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        cap = cv2.VideoCapture(VIDEO_PATH)
        fps = cap.get(cv2.CAP_PROP_FPS)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        frame_count = 0

        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break

            rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb_frame)
            timestamp_ms = int(frame_count * 1000 / fps)
            results = landmarker.detect_for_video(mp_image, timestamp_ms)
            frame_count += 1

            if results.pose_landmarks:
                lm = results.pose_landmarks[0]
                lsx, lsy = lm[LEFT_SHOULDER].x * width, lm[LEFT_SHOULDER].y * height
                rsx, rsy = lm[RIGHT_SHOULDER].x * width, lm[RIGHT_SHOULDER].y * height
                lhx, lhy = lm[LEFT_HIP].x * width, lm[LEFT_HIP].y * height
                rhx, rhy = lm[RIGHT_HIP].x * width, lm[RIGHT_HIP].y * height
                sx.append(rsx - lsx); sy.append(-(rsy - lsy))
                hx.append(rhx - lhx); hy.append(-(rhy - lhy))
                wrist_y.append(lm[LEAD_WRIST].y)
            else:
                sx.append(np.nan); sy.append(np.nan)
                hx.append(np.nan); hy.append(np.nan)
                wrist_y.append(np.nan)

        cap.release()

    phases = detect_phases(wrist_y)

    # Raw (per-frame) angles for reference, and the smoothed signals
    raw_shoulder = _fold(np.degrees(np.arctan2(sy, sx)))
    raw_hip = _fold(np.degrees(np.arctan2(hy, hx)))
    shoulder = smooth_line_angles(sx, sy)
    hip = smooth_line_angles(hx, hy)

    # Report the smoothed angles at the key swing positions
    if phases:
        print("\nShoulder / hip line angle vs. horizontal (smoothed, degrees):")
        print(f"  {'Position':<10}{'Shoulders':>11}{'Hips':>9}{'Difference':>12}")
        for name, f in [('Address', phases['takeaway']),
                        ('Top', phases['top']),
                        ('Impact', phases['impact'])]:
            print(f"  {name:<10}{shoulder[f]:>+10.1f}{hip[f]:>+9.1f}"
                  f"{shoulder[f] - hip[f]:>+12.1f}")

    # Plot raw (faint) vs. smoothed (bold) for both lines
    plt.figure(figsize=(12, 4))
    plt.axhline(0, color='0.7', linewidth=0.8)   # "level" reference
    plt.plot(raw_shoulder, color='tab:red', alpha=0.25, linewidth=1)
    plt.plot(raw_hip, color='tab:blue', alpha=0.25, linewidth=1)
    plt.plot(shoulder, color='tab:red', label='Shoulders', zorder=3)
    plt.plot(hip, color='tab:blue', label='Hips', zorder=3)

    if phases:
        for f, color in [(phases['takeaway'], 'gray'), (phases['top'], 'green'),
                         (phases['impact'], 'red'), (phases['finish'], 'purple')]:
            plt.axvline(f, color=color, linestyle='--', linewidth=1)

    plt.title('Shoulder and Hip Line Angle vs. Horizontal (smoothed)')
    plt.xlabel('Frame')
    plt.ylabel('Angle (degrees, 0 = level)')
    plt.legend(loc='upper right', fontsize=9)
    plt.tight_layout()
    plt.savefig(OUTPUT_PATH, dpi=120)
    plt.show()


if __name__ == '__main__':
    main()
