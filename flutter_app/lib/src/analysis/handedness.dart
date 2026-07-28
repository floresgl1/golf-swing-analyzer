/// Which hand is the lead (target-side) hand. Right-handed golfers lead with
/// the left wrist; lefties with the right. Mirrors `HANDEDNESS` in
/// `src/swing_phases.py`.
///
/// This lives in the pure-Dart analysis layer rather than next to the pose
/// backend because it is a property of the *golfer*, not of the detector: it
/// selects which wrist the phase detector tracks, and it is recorded on every
/// stored swing so a record analyzed on the wrong wrist stays identifiable
/// after the fact.
library;

enum Handedness {
  right,
  left;

  /// Stable on-disk value. Kept separate from [name] so a rename of the enum
  /// constant can never silently rewrite the corpus's meaning.
  String get id => switch (this) {
        Handedness.right => 'right',
        Handedness.left => 'left',
      };

  /// Parse a stored value. Returns null for an absent or unrecognized value
  /// rather than defaulting — a record that does not say which wrist was
  /// tracked must stay distinguishable from one that says "right", because
  /// every swing recorded before this field existed was analyzed as
  /// right-handed whether or not the golfer was.
  static Handedness? tryParse(Object? value) => switch (value) {
        'right' => Handedness.right,
        'left' => Handedness.left,
        _ => null,
      };
}
