"""Shared pytest configuration for the golf-swing-analyzer test suite.

The src/ modules import each other by bare module name (e.g.
`from swing_phases import ...`), which is how they are run from the project
root. Put src/ on sys.path so the tests can import them the same way.
"""
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / 'src'
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))
