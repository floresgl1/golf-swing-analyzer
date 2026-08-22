import cv2
import matplotlib.pyplot as plt

from swing_phases import detect_phases

VIDEO_PATH = 'data/videos/videoplayback.mp4'
OUTPUT_PATH = 'output/swing_phases_montage.png'

# Skeleton connections (arms, torso, legs) for a clean stick figure
CONNECTIONS = [
    (11, 13), (13, 15), (12, 14), (14, 16),   # arms
    (11, 12), (11, 23), (12, 24), (23, 24),   # torso
    (23, 25), (25, 27), (24, 26), (26, 28),   # legs
]


def draw_skeleton(frame, landmarks):
    """Draw the pose lines and keypoints onto a frame in place."""
    h, w = frame.shape[:2]
    for a, b in CONNECTIONS:
        pa = (int(landmarks[a].x * w), int(landmarks[a].y * h))
        pb = (int(landmarks[b].x * w), int(landmarks[b].y * h))
        cv2.line(frame, pa, pb, (255, 0, 0), 2)
    for lm in landmarks:
        cv2.circle(frame, (int(lm.x * w), int(lm.y * h)), 4, (0, 255, 0), -1)


def main():
    from pose_pipeline import run_pose_detection
    result = run_pose_detection(VIDEO_PATH)
    per_frame_landmarks = result.landmarks
    wrist_y = result.wrist_y()
    fps = result.fps
    torso, hip_x = result.localization_series()

    # Step 3: Detect phases and pick the four iconic checkpoint frames
    phases = detect_phases(wrist_y, fps=fps, torso=torso, hip_x=hip_x)
    n = len(wrist_y)
    if phases:
        checkpoints = [
            ('Address', phases['takeaway'] // 2),
            ('Top of Backswing', phases['top']),
            ('Impact', phases['impact']),
            ('Finish', phases['finish']),
        ]
    else:                                    # fallback: evenly spaced frames
        checkpoints = [(name, int(f * (n - 1))) for name, f in
                       [('Address', 0.1), ('Backswing', 0.4),
                        ('Impact', 0.7), ('Finish', 0.95)]]

    # Step 4: Re-read only the chosen frames and draw the skeleton on each
    cap = cv2.VideoCapture(VIDEO_PATH)
    panels = []
    for name, idx in checkpoints:
        cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
        ret, frame = cap.read()
        if not ret:
            continue
        landmarks = per_frame_landmarks[idx] if idx < len(per_frame_landmarks) else None
        if landmarks is not None:
            draw_skeleton(frame, landmarks)
        seconds = idx / fps if fps else 0.0
        panels.append((f'{name}\n{seconds:.1f}s', cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)))
    cap.release()

    # Step 5: Lay the checkpoints out left-to-right as a swing-sequence strip
    fig, axes = plt.subplots(1, len(panels), figsize=(3.2 * len(panels), 6))
    if len(panels) == 1:
        axes = [axes]
    for ax, (title, image) in zip(axes, panels):
        ax.imshow(image)
        ax.set_title(title, fontsize=12)
        ax.axis('off')
    fig.tight_layout()
    # Place the suptitle above the per-panel titles (y > 1) so they don't overlap
    fig.suptitle('Golf Swing - Key Positions', fontsize=15, fontweight='bold', y=1.04)
    fig.savefig(OUTPUT_PATH, dpi=120, bbox_inches='tight')
    print(f'Saved montage to {OUTPUT_PATH}')


if __name__ == '__main__':
    main()
