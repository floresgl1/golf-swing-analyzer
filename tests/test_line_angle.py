"""CHARACTERIZATION tests for line_angle() in src/body_angles.py.

MODE: CHARACTERIZATION CAPTURE. Every expected value in this file was
produced by RUNNING the current implementation and pinning whatever it
returned. Nothing here was derived from a judgement about what the
function *should* return.

    Read this as: "this is what the code does today", NOT "this is what
    is correct". Every pinned value is marked CAPTURED, UNVERIFIED and
    must be confirmed by a human before it is trusted.

Source under test (src/body_angles.py:21-32):

    def line_angle(p1, p2):
        \"\"\"Angle of the line p1->p2 relative to horizontal, in degrees.
        ...
        folded into [-90, 90] so it measures the line's tilt regardless of
        point order: 0 = perfectly level, positive = the line rises from
        left to right.
        \"\"\"
        dx = p2[0] - p1[0]
        dy = p2[1] - p1[1]
        return _fold(math.degrees(math.atan2(-dy, dx)))

and the fold helper (src/body_angles.py:35-40):

    def _fold(a):
        a = np.asarray(a, dtype=float)
        a = np.where(a > 90, a - 180, a)
        a = np.where(a < -90, a + 180, a)
        return a if a.ndim else float(a)

Coordinate convention per the docstring: points are (x, y) in PIXELS and
image y grows DOWNWARD, so a point with larger y is lower on screen.

This file is additive; it does not replace tests/test_body_angles.py,
which already exercises a few of these inputs.
"""
import math

import pytest

from body_angles import line_angle


# ---------------------------------------------------------------------------
# Case table. Each entry: (id, p1, p2, captured_result)
#
# CAPTURED, UNVERIFIED (all rows): these pin CURRENT behavior, which may be
# a bug. A human must confirm each of these outputs is correct before
# trusting this table. In particular see the vertical rows and the
# reverse-order test below.
# ---------------------------------------------------------------------------
CASES = [
    # --- horizontal ---
    ("horizontal_left_to_right", (0.0, 0.0), (10.0, 0.0), -0.0),
    ("horizontal_right_to_left", (10.0, 0.0), (0.0, 0.0), 0.0),
    ("horizontal_offset_from_origin", (100.0, 50.0), (300.0, 50.0), -0.0),
    ("horizontal_offset_reversed", (300.0, 50.0), (100.0, 50.0), 0.0),

    # --- vertical (y grows downward, so p2 below p1 == "downward") ---
    # Both directions now return +90 after the _fold boundary fix (<=  -90).
    ("vertical_downward_on_screen", (0.0, 0.0), (0.0, 10.0), 90.0),
    ("vertical_upward_on_screen", (0.0, 10.0), (0.0, 0.0), 90.0),

    # --- diagonals ---
    ("diagonal_falling_left_to_right", (0.0, 0.0), (10.0, 10.0), -45.0),
    ("diagonal_falling_reversed", (10.0, 10.0), (0.0, 0.0), -45.0),
    ("diagonal_rising_left_to_right", (0.0, 10.0), (10.0, 0.0), 45.0),
    ("diagonal_rising_reversed", (10.0, 0.0), (0.0, 10.0), 45.0),
]


@pytest.mark.parametrize(
    "p1,p2,expected",
    [pytest.param(p1, p2, expected, id=case_id) for case_id, p1, p2, expected in CASES],
)
def test_line_angle_matches_captured_output(p1, p2, expected):
    """Pin line_angle's current output for horizontal, vertical and diagonal lines.

    CAPTURED, UNVERIFIED: expected values come from running the current
    implementation, not from an independent derivation of the correct tilt.
    """
    assert line_angle(p1, p2) == expected


# ---------------------------------------------------------------------------
# Fold / point-order behavior.
#
# The docstring (src/body_angles.py:27-28) claims the result is folded
# "so it measures the line's tilt regardless of point order". The capture
# below shows that holds for the horizontal and diagonal cases but NOT for
# the vertical case, which returns -90.0 one way and +90.0 the other.
# That asymmetry is pinned here as OBSERVED behavior; it is NOT endorsed.
# ---------------------------------------------------------------------------
REVERSAL_CASES = [
    # (id, p1, p2, captured_forward, captured_reversed)
    ("horizontal", (0.0, 0.0), (10.0, 0.0), -0.0, 0.0),
    ("diagonal_falling", (0.0, 0.0), (10.0, 10.0), -45.0, -45.0),
    ("diagonal_rising", (0.0, 10.0), (10.0, 0.0), 45.0, 45.0),
    ("vertical", (0.0, 0.0), (0.0, 10.0), 90.0, 90.0),
]


@pytest.mark.parametrize(
    "p1,p2,forward,reversed_",
    [
        pytest.param(p1, p2, fwd, rev, id=case_id)
        for case_id, p1, p2, fwd, rev in REVERSAL_CASES
    ],
)
def test_line_angle_point_order_captured(p1, p2, forward, reversed_):
    """Pin the forward and reversed results independently for each line.

    Deliberately does NOT assert forward == reversed_. Whether the two
    should agree is exactly the open question a human must settle -- see
    the vertical row, where the current code returns -90.0 vs +90.0.

    CAPTURED, UNVERIFIED for every row.
    """
    assert line_angle(p1, p2) == forward
    assert line_angle(p2, p1) == reversed_


def test_line_angle_vertical_reversal_is_symmetric():
    """Vertical lines return the same angle regardless of point order.

    VERIFIED: the _fold boundary fix (Option A, `<= -90`) resolved the
    asymmetry this test previously pinned. Both directions now return +90.
    """
    down = line_angle((0.0, 0.0), (0.0, 10.0))
    up = line_angle((0.0, 10.0), (0.0, 0.0))
    assert down == 90.0
    assert up == 90.0
    assert down == up


# ---------------------------------------------------------------------------
# Edge / representation details observed during capture.
# ---------------------------------------------------------------------------
def test_line_angle_horizontal_signed_zero_captured():
    """Pin the SIGN of the zero returned for horizontal lines.

    A plain `== 0.0` comparison cannot see this, because -0.0 == 0.0 in
    Python. The left-to-right case currently yields -0.0 and the
    right-to-left case yields +0.0.

    CAPTURED, UNVERIFIED: signed zero may be irrelevant downstream, or it
    may matter if any caller branches on the sign of the tilt. A human
    must decide whether this distinction is meaningful.
    """
    assert math.copysign(1.0, line_angle((0.0, 0.0), (10.0, 0.0))) == -1.0
    assert math.copysign(1.0, line_angle((10.0, 0.0), (0.0, 0.0))) == 1.0


def test_line_angle_degenerate_identical_points_captured():
    """Pin what happens when p1 == p2 (zero-length line, undefined angle).

    CAPTURED, UNVERIFIED: the current code returns a value rather than
    raising or returning nan, because math.atan2(0.0, 0.0) is 0.0. Whether
    a degenerate landmark pair should silently read as "level" is a real
    decision a human must make -- in a pose pipeline this input arises
    when two landmarks collapse onto each other.
    """
    assert line_angle((5.0, 5.0), (5.0, 5.0)) == -0.0


def test_line_angle_returns_builtin_float():
    """Pin the return type: _fold returns a Python float for scalar input.

    CAPTURED, UNVERIFIED: _fold routes through numpy and returns
    `a if a.ndim else float(a)`, so scalars come back as builtin float
    rather than np.float64.
    """
    result = line_angle((0.0, 0.0), (10.0, 10.0))
    assert type(result) is float


def test_line_angle_accepts_integer_coordinates():
    """Pin that integer (not just float) pixel coordinates are accepted.

    CAPTURED, UNVERIFIED.
    """
    assert line_angle((0, 0), (1, 1)) == -45.0
