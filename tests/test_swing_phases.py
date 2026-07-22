"""Synthetic-landmark characterization tests for src/swing_phases.py.

The lead-wrist trajectory is hand-crafted so the four swing events land at known
frames, then the detected indices and tempo are locked in. Also covers the
fps==0 guard on swing_tempo.
"""
import numpy as np
import pytest

from swing_phases import detect_phases, swing_tempo, require_valid_fps


def _synthetic_wrist_y():
    """A lead-wrist y trajectory (normalized, y grows downward).

    Low y = wrist high. The shape is: address sit with a dip (takeaway), a climb
    to the top of the backswing (low y), a drop to impact (high y), then a rise
    to the finish.
    """
    return (
        [0.55] * 4 + [0.60]                     # address, dip (takeaway) at 4
        + list(np.linspace(0.58, 0.15, 8))      # climb to top
        + list(np.linspace(0.18, 0.70, 8))      # drop to impact
        + list(np.linspace(0.66, 0.25, 6))      # rise to finish
    )


def test_detect_phases_orders_events():
    phases = detect_phases(_synthetic_wrist_y())
    assert phases == {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}
    # Events must occur in swing order.
    assert (phases['takeaway'] < phases['top']
            < phases['impact'] < phases['finish'])


def test_detect_phases_tolerates_missing_frames():
    wy = _synthetic_wrist_y()
    wy[15] = float('nan')  # a frame with no detection
    phases = detect_phases(wy)
    assert phases == {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}


def test_detect_phases_returns_none_without_enough_data():
    assert detect_phases([float('nan')] * 10) is None
    assert detect_phases([0.5]) is None


def test_swing_tempo_ratio():
    phases = {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}
    tempo = swing_tempo(phases, fps=30)
    assert tempo['backswing_frames'] == 9
    assert tempo['downswing_frames'] == 8
    assert tempo['ratio'] == pytest.approx(9 / 8)


def test_swing_tempo_none_when_fps_zero():
    """fps==0 must not raise -- swing_tempo returns None."""
    phases = {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}
    assert swing_tempo(phases, fps=0) is None
    assert swing_tempo(phases, fps=None) is None


def test_swing_tempo_none_without_phases():
    assert swing_tempo(None, fps=30) is None


def test_require_valid_fps_accepts_positive():
    assert require_valid_fps(30, 'x.mp4') == 30.0
    assert require_valid_fps('59.94', 'x.mp4') == pytest.approx(59.94)


@pytest.mark.parametrize('bad', [0, 0.0, -1, float('nan'), float('inf'), None, 'abc'])
def test_require_valid_fps_rejects_invalid(bad):
    """Invalid fps must exit cleanly (SystemExit), not raise ZeroDivision etc."""
    with pytest.raises(SystemExit):
        require_valid_fps(bad, 'missing.mp4')
