"""Tests for src/swing_history.py's corrupt-history recovery.

Focus: a well-formed JSON file that holds a *structurally* malformed session
(e.g. a fault dict missing 'value') must trigger the existing backup-and-recover
path at load time, not crash later in compare_sessions/print_comparison. Also
guards that valid data -- including additive unknown keys and a legitimately
absent fault -- is never mistaken for corruption.
"""
import json

import pytest

from swing_history import load_sessions


def _valid_session():
    """A well-formed session, the shape build_session() writes."""
    return {
        'timestamp': '2026-07-21T18:40:00-06:00',
        'faults': {
            'head_sway': {'value': 0.18, 'threshold': 0.13, 'flagged': True},
            'reverse_pivot': {'value': -0.05, 'threshold': 0.12, 'flagged': False},
            'early_extension': {'value': 0.04, 'threshold': 0.10, 'flagged': False},
            'loss_of_posture': {'value': 5.0, 'threshold': 12.0, 'flagged': False},
        },
        'tempo_ratio': 2.4,
        'targeting': 'head_sway',
    }


def _write(path, data):
    path.write_text(json.dumps(data), encoding='utf-8')


def _backup_of(path):
    return path.with_suffix(path.suffix + '.corrupt.bak')


@pytest.mark.parametrize('missing_key', ['value', 'threshold', 'flagged'])
def test_missing_fault_key_triggers_recovery(tmp_path, missing_key):
    # Well-formed JSON, but one fault dict is missing a required key -- this used
    # to sail through load and raise KeyError later, outside any handler.
    path = tmp_path / 'swing_history.json'
    session = _valid_session()
    del session['faults']['reverse_pivot'][missing_key]
    _write(path, {'sessions': [session]})

    sessions = load_sessions(path)  # must recover, not raise

    assert sessions == []                       # recovered to an empty history
    assert not path.exists()                    # original moved aside...
    assert _backup_of(path).exists()            # ...to <name>.corrupt.bak


def test_non_dict_session_triggers_recovery(tmp_path):
    # 'sessions' is a list (container shape is fine), but an entry is a string.
    path = tmp_path / 'swing_history.json'
    _write(path, {'sessions': ['not a session']})

    assert load_sessions(path) == []
    assert not path.exists()
    assert _backup_of(path).exists()


def test_non_numeric_value_triggers_recovery(tmp_path):
    # A fault 'value' that is a string would TypeError in the delta arithmetic.
    path = tmp_path / 'swing_history.json'
    session = _valid_session()
    session['faults']['early_extension']['value'] = 'oops'
    _write(path, {'sessions': [session]})

    assert load_sessions(path) == []
    assert _backup_of(path).exists()


def test_valid_session_with_unknown_keys_loads(tmp_path):
    # Additive keys (container, session, and fault level) are harmless and must
    # survive the load untouched -- not be mistaken for corruption.
    path = tmp_path / 'swing_history.json'
    session = _valid_session()
    session['future_field'] = 'whatever'
    session['faults']['head_sway']['note'] = 'extra'
    _write(path, {'_comment': 'notes', 'sessions': [session]})

    sessions = load_sessions(path)

    assert len(sessions) == 1
    assert sessions[0]['future_field'] == 'whatever'
    assert sessions[0]['faults']['head_sway']['note'] == 'extra'
    assert path.exists()  # left in place, not backed up


def test_session_missing_a_whole_fault_is_not_corrupt(tmp_path):
    # compare_sessions tolerates an absent fault; only a *malformed* present one
    # is corruption. Dropping a whole fault must still load.
    path = tmp_path / 'swing_history.json'
    session = _valid_session()
    del session['faults']['loss_of_posture']
    _write(path, {'sessions': [session]})

    sessions = load_sessions(path)

    assert len(sessions) == 1
    assert 'loss_of_posture' not in sessions[0]['faults']
    assert path.exists()


def test_absent_and_null_optional_fields_load(tmp_path):
    # tempo_ratio null and targeting absent entirely are both valid.
    path = tmp_path / 'swing_history.json'
    session = _valid_session()
    session['tempo_ratio'] = None
    del session['targeting']
    _write(path, {'sessions': [session]})

    sessions = load_sessions(path)

    assert len(sessions) == 1
    assert path.exists()
