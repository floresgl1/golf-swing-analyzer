# Roadmap

## Beta

Goal of the beta is to test **retention** and to passively accumulate a corpus of
real swings — not to prove the detectors are right. The fault thresholds in
`faults.py` / `faults.dart` have never been validated against a labelled corpus,
so the app's presentation was pulled back to match what the data can actually
support.

- **Fault presentation is tentative, not definitive.** A flagged fault renders as
  "Possible early extension" with a `POSSIBLE` chip, the measured value, and the
  threshold labelled a "beta reference" rather than a verdict line. The report
  carries a standing caveat that measurements are indicative and unvalidated.
  Detection, thresholds, and the drill recommendations attached to each flagged
  fault are unchanged.

- **Cross-session judgment is not rendered.** The report's comparison card shows
  only raw previous → current measured values ("Last swing vs this swing"). The
  improved/worsened/unchanged trends, the FIXED / NEW FAULT badges, and the
  "you cleared X" / "the practice is paying off" callouts have been removed from
  the UI.

  Reason: with unvalidated thresholds, a threshold crossing between two swings
  may be measurement noise rather than a change in the golfer's swing, so
  "improved", "fixed", and "new fault" are conclusions the data cannot support.
  Telling a beta tester they improved when we cannot show it is the one claim
  most likely to cost trust.

  The `Trend` / `Crossing` machinery in `swing_history.dart` is **kept and stays
  unit-tested** — it is computed on every comparison and simply not read by the
  view. See the guardrail note on `SwingComparison.between`. Do not re-surface it
  in the UI until the thresholds are validated.

### Exit criteria for restoring cross-session verdicts

1. Enough beta swings collected to form a labelled corpus (currently the history
   is device-local only, so collection needs a path off the device first).
2. Per-fault thresholds validated against that corpus, with a known false-positive
   rate.
3. Per-fault measurement noise quantified, so a between-session delta can be
   distinguished from repeat-measurement variance.

Until all three hold, the report measures and shows; it does not judge.
