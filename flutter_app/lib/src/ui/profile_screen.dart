import 'package:flutter/material.dart';

import '../analysis/participant.dart';
import '../analysis/swing_history.dart';
import '../services/corpus_export.dart';

/// The golfer's own record: their anonymous id, what a coach has told them
/// about their swing, and the button that gets their swings off the device.
///
/// The coach report lives here rather than on the record screen because it
/// describes the *golfer*, not the swing just hit. Asking per swing would
/// imply it was observed for that swing and would let the answer drift between
/// records of the same person.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.participant,
    required this.store,
  });

  final Participant participant;

  /// Null when device storage was unavailable; edits then cannot be saved.
  final ParticipantStore? store;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Participant _participant = widget.participant;
  /// Anchors the iOS share popover to the export button.
  final GlobalKey _exportButtonKey = GlobalKey();
  bool _exporting = false;

  Future<void> _setReport(String faultId, CoachConfirmation value) async {
    final store = widget.store;
    setState(() {
      _participant = _participant.copyWith(
        coachReports: {..._participant.coachReports, faultId: value},
      );
    });
    if (store == null) return;
    try {
      final saved = await store.setCoachReport(faultId, value);
      if (mounted) setState(() => _participant = saved);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $error')),
      );
    }
  }

  /// Anchor the iOS share sheet to the export button.
  ///
  /// Omitting this is not a cosmetic slip: share_plus rejects a null or
  /// zero-sized origin and the export fails outright. See
  /// [shareOriginOrFallback].
  Rect _shareOrigin() {
    final box =
        _exportButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final fromControl = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    return shareOriginOrFallback(fromControl, MediaQuery.of(context).size);
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final result = await const CorpusExporter().share(
        sharePositionOrigin: _shareOrigin(),
      );
      if (!mounted) return;
      if (result.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No swings recorded yet.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your profile')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          if (widget.store == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Text(
                'Device storage is unavailable, so changes here will not be '
                'saved.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Anonymous id', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '${_participant.id}\n\nRandomly generated on this device. It is '
              'not linked to you, your phone, or any account — it only groups '
              'your swings together.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child:
                Text('What a coach has told you', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Optional. If a coach has pointed out one of these in your swing, '
              'saying so here helps us check whether the app agrees. It is not '
              'used to change your reports.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final faultId in coachReportFaultIds)
            _CoachReportRow(
              label: faultLabels[faultId] ?? faultId,
              value: _participant.coachReports[faultId],
              onChanged: (value) => _setReport(faultId, value),
            ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Send your swings', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Your swings are stored only on this phone and nothing is '
              'uploaded. Use this to send the file yourself when asked for it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              key: _exportButtonKey,
              onPressed: _exporting ? null : _export,
              icon: const Icon(Icons.ios_share),
              label: Text(_exporting ? 'Preparing…' : 'Export swing history'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoachReportRow extends StatelessWidget {
  const _CoachReportRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final CoachConfirmation? value;
  final ValueChanged<CoachConfirmation> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          SegmentedButton<CoachConfirmation>(
            segments: const [
              ButtonSegment(value: CoachConfirmation.yes, label: Text('Yes')),
              ButtonSegment(value: CoachConfirmation.no, label: Text('No')),
              ButtonSegment(
                  value: CoachConfirmation.unsure, label: Text('Not sure')),
            ],
            selected: value == null ? const {} : {value!},
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              if (selection.isNotEmpty) onChanged(selection.first);
            },
          ),
        ],
      ),
    );
  }
}
