"""Tests for the robustness fixes: corrupt drills.json and corrupt/atomic
swing history. (The fps==0 guard is covered in test_swing_phases.py.)
"""
import json

import pytest

import drill_recommender as DR
import swing_history as SH


# ---------------------------------------------------------------- drills.json

def test_load_drills_reads_valid_library(tmp_path):
    p = tmp_path / 'drills.json'
    p.write_text(json.dumps({'drills': [{'id': 'a', 'fault': 'head_sway'}]}))
    assert DR.load_drills(p) == [{'id': 'a', 'fault': 'head_sway'}]


def test_load_drills_corrupt_json_falls_back_to_empty(tmp_path):
    p = tmp_path / 'drills.json'
    p.write_text('{"drills": [ truncated garbage')
    assert DR.load_drills(p) == []


def test_load_drills_missing_file_falls_back_to_empty(tmp_path):
    assert DR.load_drills(tmp_path / 'does_not_exist.json') == []


def test_load_drills_wrong_shape_falls_back_to_empty(tmp_path):
    p = tmp_path / 'drills.json'
    p.write_text(json.dumps({'drills': 'not a list'}))
    assert DR.load_drills(p) == []
    p.write_text(json.dumps({'no_drills_key': []}))
    assert DR.load_drills(p) == []


def test_recommendations_still_work_with_corrupt_library(tmp_path):
    """The app-startup path must not crash on a broken library."""
    p = tmp_path / 'drills.json'
    p.write_text('not json at all')
    drills = DR.load_drills(p)
    recs = DR.recommend_drills({'head_sway': {'flagged': True}}, drills)
    assert recs == {'head_sway': []}


# ------------------------------------------------------------- swing history

def _session(ts):
    return {'timestamp': ts, 'faults': {}, 'tempo_ratio': None, 'targeting': None}


def test_load_sessions_missing_file_is_empty(tmp_path):
    assert SH.load_sessions(tmp_path / 'history.json') == []


def test_corrupt_history_is_backed_up_and_reset(tmp_path):
    p = tmp_path / 'history.json'
    p.write_text('{"sessions": [ not valid json')
    sessions = SH.load_sessions(p)
    assert sessions == []                                   # started fresh
    backup = tmp_path / 'history.json.corrupt.bak'
    assert backup.exists()                                  # original preserved
    assert not p.exists()                                   # moved aside
    assert backup.read_text() == '{"sessions": [ not valid json'


def test_wrong_shape_history_is_treated_as_corrupt(tmp_path):
    p = tmp_path / 'history.json'
    p.write_text(json.dumps({'sessions': 'not a list'}))
    assert SH.load_sessions(p) == []
    assert (tmp_path / 'history.json.corrupt.bak').exists()


def test_save_session_round_trips(tmp_path):
    p = tmp_path / 'history.json'
    SH.save_session(_session('t1'), p)
    SH.save_session(_session('t2'), p)
    sessions = SH.load_sessions(p)
    assert [s['timestamp'] for s in sessions] == ['t1', 't2']
    # file on disk is valid JSON and no temp file is left behind
    assert json.loads(p.read_text())['sessions']
    assert not (tmp_path / 'history.json.tmp').exists()


def test_save_session_recovers_from_corrupt_history(tmp_path):
    p = tmp_path / 'history.json'
    p.write_text('totally broken')
    SH.save_session(_session('t3'), p)
    assert [s['timestamp'] for s in SH.load_sessions(p)] == ['t3']
    assert (tmp_path / 'history.json.corrupt.bak').exists()


def test_save_session_write_is_atomic(tmp_path, monkeypatch):
    """If the write fails mid-way, the previous good history is untouched.

    Simulate a crash during json.dump by making it raise after the temp file is
    opened; the real history file must still hold the prior contents and no
    temp file should survive... but os.replace never ran, so the original is
    intact.
    """
    p = tmp_path / 'history.json'
    SH.save_session(_session('good'), p)
    good_bytes = p.read_bytes()

    real_dump = json.dump

    def boom(*a, **k):
        raise RuntimeError("simulated crash mid-write")

    monkeypatch.setattr(SH.json, 'dump', boom)
    with pytest.raises(RuntimeError):
        SH.save_session(_session('never'), p)

    # original file is byte-for-byte unchanged (replace never happened)
    assert p.read_bytes() == good_bytes
    monkeypatch.setattr(SH.json, 'dump', real_dump)
    assert [s['timestamp'] for s in SH.load_sessions(p)] == ['good']


# ------------------------------------------- swing_history pure helpers (bonus)

def test_build_session_shapes_detector_output():
    fault_report = {
        'head_sway': {'lateral': 0.2, 'sway_threshold': 0.13, 'flagged': True},
        'reverse_pivot': {'reverse': -0.05, 'threshold': 0.12, 'flagged': False},
        'early_extension': {'rise': 0.04, 'threshold': 0.10, 'flagged': False},
        'loss_of_posture': {'straighten': 5.0, 'threshold': 12.0, 'flagged': False},
    }
    session = SH.build_session(fault_report, tempo={'ratio': 2.5}, targeting='head_sway')
    assert session['faults']['head_sway'] == {
        'value': 0.2, 'threshold': 0.13, 'flagged': True}
    assert session['tempo_ratio'] == 2.5
    assert session['targeting'] == 'head_sway'
