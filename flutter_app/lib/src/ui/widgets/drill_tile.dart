import 'package:flutter/material.dart';

import '../../models/drill.dart';

/// One recommended drill: name + difficulty badge, optional equipment line, and
/// the how-to description.
class DrillTile extends StatelessWidget {
  const DrillTile({super.key, required this.drill});

  final Drill drill;

  Color _difficultyColor(BuildContext context) {
    switch (drill.difficulty) {
      case 'beginner':
        return Colors.green.shade600;
      case 'intermediate':
        return Colors.orange.shade700;
      case 'advanced':
        return Colors.red.shade600;
      default:
        return Theme.of(context).colorScheme.outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  drill.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _difficultyColor(context).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  drill.difficulty,
                  style: TextStyle(
                    color: _difficultyColor(context),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          if (drill.needsEquipment)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Equipment: ${drill.equipment}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                    ),
              ),
            ),
          const SizedBox(height: 4),
          Text(drill.description,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
