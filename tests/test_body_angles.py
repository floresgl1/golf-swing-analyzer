"""Synthetic characterization tests for src/body_angles.py.

Covers the pure geometry helpers: line_angle (tilt vs. horizontal), _fold
(collapsing a line and its reverse), and smooth_line_angles (period-180
complex smoothing that down-weights foreshortened / missing frames).
"""
import numpy as np
import pytest

from body_angles import line_angle, _fold, smooth_line_angles


def test_line_angle_level():
    # image y grows downward; a left->right horizontal line is "level" = 0 deg
    assert line_angle((0, 0), (1, 0)) == 0.0
    # a line and its reverse fold to the same tilt
    assert line_angle((0, 0), (-1, 0)) == 0.0


def test_line_angle_diagonal():
    # (1, 1) with y-down is a downward slope -> -45 deg
    assert line_angle((0, 0), (1, 1)) == -45.0
    # straight up folds to +90
    assert line_angle((0, 0), (0, -1)) == 90.0


def test_fold_wraps_into_pm90():
    assert _fold(170.0) == pytest.approx(-10.0)
    assert _fold(-170.0) == pytest.approx(10.0)
    assert _fold(45.0) == 45.0


def test_smooth_line_angles_constant_level():
    vx = [1.0] * 9
    vy = [0.0] * 9
    out = smooth_line_angles(vx, vy)
    assert np.allclose(out, 0.0)


def test_smooth_line_angles_diagonal():
    vx = [1.0] * 9
    vy = [1.0] * 9
    out = smooth_line_angles(vx, vy)
    assert out[4] == pytest.approx(45.0)


def test_smooth_line_angles_bridges_missing_frame():
    """A nan (undetected) frame is filled from its neighbours, not left nan."""
    vx = [1.0] * 9
    vy = [1.0] * 9
    vx[4] = np.nan
    vy[4] = np.nan
    out = smooth_line_angles(vx, vy)
    assert out[4] == pytest.approx(45.0)


def test_smooth_line_angles_all_missing_is_nan():
    out = smooth_line_angles([np.nan] * 9, [np.nan] * 9)
    assert np.isnan(out).all()


def test_fold_boundary_at_pm90():
    """Exactly +90 survives; exactly -90 folds to +90 (order-independence).

    _fold uses `a > 90` and `a <= -90`: the inclusive lower boundary means
    a vertical line and its reverse both return +90, so the docstring's
    "regardless of point order" claim holds unconditionally.

    VERIFIED: the decision to fold at -90 was made explicitly (Option A in
    Architecture Notes / ROADMAP.md).
    """
    assert _fold(90.0) == 90.0       # exactly +90: NOT folded (> 90 is False)
    assert _fold(-90.0) == 90.0      # exactly -90: FOLDED to +90 (<= -90)
    # a hair beyond the boundary IS folded
    assert _fold(90.001) == pytest.approx(-89.999)
    assert _fold(-90.001) == pytest.approx(89.999)
