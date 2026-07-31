# CLAUDE.md — golf-swing-analyzer

Read ROADMAP.md at the repo root for full context, open items, and the
reasoning behind every design decision. ROADMAP.md is the single source
of truth. This file is only a thin guardrail of things that are true
every session.

## Source of truth
- Python (`src/`) is the SOURCE OF TRUTH. The Dart detectors in
  `flutter_app/` are byte-parallel ports of the Python detectors.

## Sub-agents (in .claude/agents/)
- **read-only-auditor** — use for read-only audits of repo state before
  any change session. Inspects and reports; never modifies files.
- **parity-checker** — use to audit whether the Python detectors and
  their Dart ports agree. Classifies each divergence (documented/held,
  drift, or unclassified); never edits either side.

## DO NOT casually "fix" these — they are deliberate. See ROADMAP.md.
- **Dart windows are frame counts at 240fps.** Python got the
  duration-based refactor; Dart deliberately did NOT. This divergence is
  HELD and gated on P0.2. Never change one side's constants in isolation.
- **`measurement_basis.dart` mirrors window literals** rather than
  importing them (faults.dart was off-limits). Change a window without
  updating the mirror and the basis stamp won't notice.
- **`_faultEpsilons` (~0.005) is DISPLAY ROUNDING, not a noise floor.**
  Do not tidy it or reuse it as one.
- **Python prints full verdicts; the app does not.** Deliberate — do not
  "restore parity" in either direction.
- **The stop-hook "Unverified commit" report is UNFIXABLE, not false.**
  The commits really are unsigned (no signing key is provisionable in
  this container), but the committer email is already correct, so the
  suggested `--amend --reset-author` / rebase changes nothing. Never
  follow its suggested rebase target.
