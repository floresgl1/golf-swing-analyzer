import cv2

from swing_phases import detect_phases, LEAD_SIDE

# MediaPipe pose landmark indices for the joints we care about
LEFT_SHOULDER = 11
RIGHT_SHOULDER = 12
LEFT_ELBOW = 13
RIGHT_ELBOW = 14
LEFT_WRIST = 15
RIGHT_WRIST = 16
LEFT_HIP = 23
RIGHT_HIP = 24
LEFT_KNEE = 25
RIGHT_KNEE = 26
LEFT_ANKLE = 27
RIGHT_ANKLE = 28

# Pairs of landmark indices to connect with a line
CONNECTIONS = [
    # Arms
    (LEFT_SHOULDER, LEFT_ELBOW),
    (LEFT_ELBOW, LEFT_WRIST),
    (RIGHT_SHOULDER, RIGHT_ELBOW),
    (RIGHT_ELBOW, RIGHT_WRIST),
    # Torso
    (LEFT_SHOULDER, RIGHT_SHOULDER),
    (LEFT_SHOULDER, LEFT_HIP),
    (RIGHT_SHOULDER, RIGHT_HIP),
    (LEFT_HIP, RIGHT_HIP),
    # Legs
    (LEFT_HIP, LEFT_KNEE),
    (LEFT_KNEE, LEFT_ANKLE),
    (RIGHT_HIP, RIGHT_KNEE),
    (RIGHT_KNEE, RIGHT_ANKLE),
]

VIDEO_PATH = 'data/videos/videoplayback.mp4'
OUTPUT_PATH = 'output/annotated.mp4'

# Colors (BGR) used for the burnt-in phase label, matching the plot's palette
PHASE_COLORS = {
    'Address': (255, 170, 60),
    'Backswing': (90, 200, 90),
    'Downswing': (60, 170, 255),
    'Follow-through': (210, 120, 220),
}


def phase_for_frame(i, phases):
    """Return the swing-phase name for frame index i, or None if unknown."""
    if phases is None:
        return None
    if i < phases['takeaway']:
        return 'Address'
    if i < phases['top']:
        return 'Backswing'
    if i < phases['impact']:
        return 'Downswing'
    return 'Follow-through'


def main():
    from pose_pipeline import run_pose_detection
    result = run_pose_detection(VIDEO_PATH)
    per_frame_landmarks = result.landmarks
    wrist_y = result.wrist_y()
    fps = result.fps
    width = result.width
    height = result.height
    torso, hip_x = result.localization_series()

    # ---- Detect the swing phases from the collected trajectory ----
    phases = detect_phases(wrist_y, fps=fps, torso=torso, hip_x=hip_x)

    # ---- Pass 2: redraw the skeleton, burn in the phase label, and write the video ----
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    writer = cv2.VideoWriter(OUTPUT_PATH, fourcc, fps, (width, height))

    cap = cv2.VideoCapture(VIDEO_PATH)
    frame_idx = 0

    while cap.isOpened():
        ret, frame = cap.read()
        if not ret or frame_idx >= len(per_frame_landmarks):
            break

        h, w = frame.shape[:2]
        landmarks = per_frame_landmarks[frame_idx]

        # Draw the skeleton from the cached landmarks
        if landmarks is not None:
            # Lines first, so the keypoints sit on top
            for a, b in CONNECTIONS:
                pa = (int(landmarks[a].x * w), int(landmarks[a].y * h))
                pb = (int(landmarks[b].x * w), int(landmarks[b].y * h))
                cv2.line(frame, pa, pb, (255, 0, 0), 2)
            for landmark in landmarks:
                cv2.circle(frame, (int(landmark.x * w), int(landmark.y * h)), 4, (0, 255, 0), -1)

        # Burn in the current swing phase (colored text with a dark outline)
        label = phase_for_frame(frame_idx, phases)
        if label:
            seconds = frame_idx / fps if fps else 0.0
            text = f'{label}  {seconds:0.1f}s'
            origin = (15, 40)
            cv2.putText(frame, text, origin, cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 4, cv2.LINE_AA)
            cv2.putText(frame, text, origin, cv2.FONT_HERSHEY_SIMPLEX, 0.8, PHASE_COLORS[label], 2, cv2.LINE_AA)

        # Flash the key events for a few frames so they stand out
        event = None
        if phases:
            if abs(frame_idx - phases['top']) <= 2:
                event = 'TOP OF BACKSWING'
            elif abs(frame_idx - phases['impact']) <= 2:
                event = 'IMPACT'
        if event:
            cv2.putText(frame, event, (15, 75), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 4, cv2.LINE_AA)
            cv2.putText(frame, event, (15, 75), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 255), 2, cv2.LINE_AA)

        writer.write(frame)

        cv2.imshow('Golf Swing Analysis', frame)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break
        frame_idx += 1

    cap.release()
    writer.release()
    cv2.destroyAllWindows()


if __name__ == '__main__':
    main()
