/// Data model for a single corrective drill, mirroring one entry in
/// `assets/drills.json`.
library;

class Drill {
  final String id;
  final String name;

  /// One of: head_sway, reverse_pivot, early_extension, loss_of_posture.
  final String fault;
  final String description;

  /// One of: beginner, intermediate, advanced.
  final String difficulty;

  /// Optional gear; empty or "none" means no equipment needed.
  final String equipment;

  /// Asset path to a short demo clip (e.g. "drills/head_against_wall.mp4").
  /// Empty when no clip has been filmed yet. The app ships a placeholder in
  /// that case — the container is ready before the content.
  final String media;

  const Drill({
    required this.id,
    required this.name,
    required this.fault,
    required this.description,
    required this.difficulty,
    required this.equipment,
    this.media = '',
  });

  factory Drill.fromJson(Map<String, dynamic> json) => Drill(
        id: (json['id'] ?? '') as String,
        name: (json['name'] ?? '') as String,
        fault: (json['fault'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        difficulty: (json['difficulty'] ?? '') as String,
        equipment: (json['equipment'] ?? '') as String,
        media: (json['media'] ?? '') as String,
      );

  /// True when this drill calls for equipment worth surfacing to the golfer.
  bool get needsEquipment =>
      equipment.trim().isNotEmpty && equipment.trim().toLowerCase() != 'none';

  /// True when a demo clip is bundled for this drill.
  bool get hasMedia => media.trim().isNotEmpty;
}
