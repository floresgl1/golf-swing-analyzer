"""Snapshot (characterization) test for the MediaPipe pose-estimation step.

This locks in the landmark output produced for a small committed sample video
(tests/fixtures/sample_swing.mp4) so a later refactor -- e.g. extracting the
duplicated detection loops into a shared pose_pipeline.py -- can be checked
against a golden file instead of eyeballed.

The detection loop here is a deliberate, self-contained copy of the loop used
in src/ (pose_estimation.py, faults.py, ...). It is NOT a refactor of the
source: the source keeps its duplicated loops for now; this copy exists only so
the test can drive detection without importing a script module.

Requirements to run:
  * MediaPipe model at data/pose_landmarker.task (a large binary, gitignored and
    not committed). The test SKIPS when it is absent.

The golden (tests/fixtures/pose_landmarks_golden.json) was generated in this
environment with the pinned mediapipe==0.10.35 and the *lite* Pose Landmarker
model. Landmark values are model-variant specific, so if you run this against a
different model file the snapshot will differ; regenerate the golden with:

    UPDATE_POSE_GOLDEN=1 pytest tests/test_pose_estimation.py

Only do that when you have intentionally changed the model or the sample video.
"""
import json
import os
from pathlib import Path

import pytest

FIXTURES = Path(__file__).resolve().parent / 'fixtures'
SAMPLE_VIDEO = FIXTURES / 'sample_swing.mp4'
GOLDEN = FIXTURES / 'pose_landmarks_golden.json'
MODEL = Path(__file__).resolve().parent.parent / 'data' / 'pose_landmarker.task'

# Landmark detection is deterministic on CPU for a fixed model + input (verified
# to 6 decimals run-to-run); round to 5 for a small safety margin.
ROUND = 5


def _extract_landmarks(video_path):
    """Run the pose landmarker over a video and return per-frame landmarks.

    Returns a list with one entry per frame: either None (no pose detected) or a
    list of 33 [x, y, z, visibility] lists rounded to ROUND decimals.
    """
    import cv2
    import mediapipe as mp
    from mediapipe.tasks import python
    from mediapipe.tasks.python import vision

    base_options = python.BaseOptions(model_asset_path=str(MODEL))
    options = vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO,
    )

    frames = []
    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        cap = cv2.VideoCapture(str(video_path))
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
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
                lm = result.pose_landmarks[0]
                frames.append([[round(p.x, ROUND), round(p.y, ROUND),
                                round(p.z, ROUND), round(p.visibility, ROUND)]
                               for p in lm])
            else:
                frames.append(None)
        cap.release()
    return frames


requires_model = pytest.mark.skipif(
    not MODEL.exists(),
    reason=f"MediaPipe model {MODEL} not present (gitignored large binary)")


@requires_model
def test_pose_landmarks_match_golden():
    assert SAMPLE_VIDEO.exists(), f"missing sample video fixture {SAMPLE_VIDEO}"
    landmarks = _extract_landmarks(SAMPLE_VIDEO)

    if os.environ.get('UPDATE_POSE_GOLDEN') or not GOLDEN.exists():
        GOLDEN.write_text(json.dumps(landmarks, indent=2) + '\n')
        pytest.skip(f"wrote golden file {GOLDEN} -- re-run to assert against it")

    expected = json.loads(GOLDEN.read_text())
    assert landmarks == expected, (
        "pose landmark output changed vs the golden snapshot. If this is an "
        "intentional change (new model or sample video), regenerate with "
        "UPDATE_POSE_GOLDEN=1 pytest tests/test_pose_estimation.py")


@requires_model
def test_sample_video_detects_a_pose():
    """Guard the fixture itself: it must actually yield some detections."""
    landmarks = _extract_landmarks(SAMPLE_VIDEO)
    assert any(f is not None for f in landmarks)
    for frame in landmarks:
        if frame is not None:
            assert len(frame) == 33  # MediaPipe pose returns 33 landmarks
