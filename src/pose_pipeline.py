"""Shared MediaPipe pose-detection loop.

Every script in src/ that processes a golf-swing video was running its own
copy of the same detection loop (open video -> iterate frames -> BGR->RGB ->
mp.Image -> detect_for_video -> cache landmarks). This module extracts that
loop so a bug fix or a new series to collect happens in one place.

The test copy in tests/test_pose_estimation.py is deliberately separate
(see its docstring) and is NOT a consumer of this module.
"""
import math

import cv2
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

from swing_phases import require_valid_fps, LEAD_WRIST, lead_wrist_for

# MediaPipe landmark indices for the shoulder/hip midpoints used by
# localization_series(). Defined here rather than imported from faults.py
# so the pipeline module stays self-contained.
LEFT_SHOULDER = 11
RIGHT_SHOULDER = 12
LEFT_HIP = 23
RIGHT_HIP = 24

DEFAULT_MODEL = 'data/pose_landmarker.task'


class PoseResult:
    """Per-frame landmarks and video metadata from a pose-detection run.

    Attributes
    ----------
    landmarks : list
        One entry per frame: the raw MediaPipe landmark list
        (33 NormalizedLandmarks) or None when no pose was detected.
    fps : float
        Validated frame rate (guaranteed nonzero via ``require_valid_fps``).
    width : int
        Frame width in pixels.
    height : int
        Frame height in pixels.
    """
    __slots__ = ('landmarks', 'fps', 'width', 'height')

    def __init__(self, landmarks, fps, width, height):
        self.landmarks = landmarks
        self.fps = fps
        self.width = width
        self.height = height

    def __len__(self):
        return len(self.landmarks)

    def wrist_y(self, handedness='right'):
        """Lead-wrist y per frame (normalized 0..1, nan where undetected).

        The lead hand is the one closer to the target: left wrist for a
        right-handed golfer, right wrist for a lefty.
        """
        lw = lead_wrist_for(handedness)
        return [
            lm[lw].y if lm is not None else float('nan')
            for lm in self.landmarks
        ]

    def localization_series(self):
        """Torso length and hip-midpoint x, both in pixels, per frame.

        These are the two series ``detect_phases`` needs (beyond ``wrist_y``)
        for stance-bounded localization.  nan where no pose was detected.
        """
        torso, hip_x = [], []
        for lm in self.landmarks:
            if lm is not None:
                sx = (lm[LEFT_SHOULDER].x + lm[RIGHT_SHOULDER].x) / 2 * self.width
                sy = (lm[LEFT_SHOULDER].y + lm[RIGHT_SHOULDER].y) / 2 * self.height
                hx = (lm[LEFT_HIP].x + lm[RIGHT_HIP].x) / 2 * self.width
                hy = (lm[LEFT_HIP].y + lm[RIGHT_HIP].y) / 2 * self.height
                torso.append(math.dist((sx, sy), (hx, hy)))
                hip_x.append(hx)
            else:
                torso.append(float('nan'))
                hip_x.append(float('nan'))
        return torso, hip_x


def run_pose_detection(video_path, model_path=DEFAULT_MODEL):
    """Run MediaPipe pose detection over every frame of a video.

    Returns a ``PoseResult`` with cached per-frame landmarks plus
    fps / width / height.  Each caller derives the series it needs from
    the cached landmarks -- no re-running the model.
    """
    base_options = python.BaseOptions(model_asset_path=model_path)
    options = vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO,
    )

    per_frame = []

    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        cap = cv2.VideoCapture(video_path)
        fps = require_valid_fps(cap.get(cv2.CAP_PROP_FPS), video_path)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        frame_count = 0

        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            result = landmarker.detect_for_video(
                mp_image, int(frame_count * 1000 / fps))
            frame_count += 1

            if result.pose_landmarks:
                per_frame.append(result.pose_landmarks[0])
            else:
                per_frame.append(None)

        cap.release()

    return PoseResult(per_frame, fps, width, height)
