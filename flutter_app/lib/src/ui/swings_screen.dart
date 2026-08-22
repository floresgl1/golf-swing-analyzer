import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/swing_history.dart';
import '../analysis/swing_history_store.dart';
import 'swing_detail_screen.dart';
import 'theme/app_theme.dart';

/// Past-swings list (ROADMAP item 6).
///
/// Shows every swing in the on-device corpus, newest first. Each row carries
/// the date, how many faults were flagged, and the tempo ratio; tapping through
/// opens [SwingDetailScreen] with the full measurement set.
///
/// **This does not breach the Beta decision record.** A list of past
/// measurements makes no trend or improvement claim, so the `Trend` /
/// `Crossing` machinery stays unsurfaced exactly as required.
class SwingsScreen extends StatefulWidget {
  const SwingsScreen({super.key});

  @override
  State<SwingsScreen> createState() => _SwingsScreenState();
}

class _SwingsScreenState extends State<SwingsScreen> {
  List<SwingSession>? _sessions;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dir = await getApplicationDocumentsDirectory();
      final store = SwingHistoryStore(
        File(p.join(dir.path, 'swing_history.jsonl')),
        legacyFile: File(p.join(dir.path, 'swing_history.json')),
      );
      final result = await store.load();
      if (!mounted) return;
      setState(() {
        // Newest first.
        _sessions = result.sessions.reversed.toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load swing history.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Swings')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48,
                  color: Theme.of(context).colorScheme.error),
              Gap.md,
              Text(_error!, textAlign: TextAlign.center),
              Gap.md,
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final sessions = _sessions;
    if (sessions == null || sessions.isEmpty) {
      return _EmptyState(onRefresh: _load);
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 32),
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final session = sessions[index];
          return _SwingRow(
            session: session,
            onTap: () => _openDetail(session),
          );
        },
      ),
    );
  }

  void _openDetail(SwingSession session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SwingDetailScreen(session: session),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
          Icon(Icons.golf_course, size: 48,
              color: theme.colorScheme.outline),
          Gap.md,
          Text(
            'No swings recorded yet',
            style: theme.textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          Gap.sm,
          Text(
            'Record a swing to get started.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Swing row
// ---------------------------------------------------------------------------

class _SwingRow extends StatelessWidget {
  const _SwingRow({required this.session, required this.onTap});

  final SwingSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sc = SwingColors.of(context);
    final flaggedCount = session.faults.values.where((f) => f.flagged).length;
    final isCalibration = session.swingKind == SwingKind.calibration;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Fault count indicator.
            _FaultCountBadge(count: flaggedCount),
            Gap.hmd,
            // Date + summary.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _formatDate(session.timestamp),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (isCalibration)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: sc.drillAdvanced.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Calibration',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: sc.drillAdvanced,
                            ),
                          ),
                        ),
                    ],
                  ),
                  Gap.xs,
                  Text(
                    _subtitle(session, flaggedCount),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            Gap.hsm,
            Icon(Icons.chevron_right, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }

  static String _subtitle(SwingSession session, int flaggedCount) {
    final parts = <String>[];
    if (flaggedCount == 0) {
      parts.add('No faults flagged');
    } else {
      parts.add('$flaggedCount possible fault${flaggedCount == 1 ? '' : 's'}');
    }
    final ratio = session.tempoRatio;
    if (ratio != null) {
      parts.add('${ratio.toStringAsFixed(1)} : 1');
    }
    return parts.join(' · ');
  }
}

// ---------------------------------------------------------------------------
// Fault count badge
// ---------------------------------------------------------------------------

class _FaultCountBadge extends StatelessWidget {
  const _FaultCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final sc = SwingColors.of(context);
    final color = count == 0 ? sc.notSeen : sc.flagged;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.15),
      ),
      alignment: Alignment.center,
      child: Text(
        '$count',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Date formatting
// ---------------------------------------------------------------------------

/// Format a timestamp as a human-friendly string.
///
/// - Same day → "Today, 2:03 PM"
/// - Yesterday → "Yesterday, 2:03 PM"
/// - This year → "Aug 20, 2:03 PM"
/// - Other year → "Aug 20, 2025"
String _formatDate(DateTime dt) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final date = DateTime(dt.year, dt.month, dt.day);
  final time = _formatTime(dt);

  if (date == today) return 'Today, $time';
  if (date == today.subtract(const Duration(days: 1))) {
    return 'Yesterday, $time';
  }
  final month = _monthAbbr[dt.month] ?? '${dt.month}';
  if (dt.year == now.year) return '$month ${dt.day}, $time';
  return '$month ${dt.day}, ${dt.year}';
}

String _formatTime(DateTime dt) {
  final hour = dt.hour;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = hour >= 12 ? 'PM' : 'AM';
  final h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  return '$h:$minute $period';
}

const _monthAbbr = {
  1: 'Jan', 2: 'Feb', 3: 'Mar', 4: 'Apr', 5: 'May', 6: 'Jun',
  7: 'Jul', 8: 'Aug', 9: 'Sep', 10: 'Oct', 11: 'Nov', 12: 'Dec',
};
