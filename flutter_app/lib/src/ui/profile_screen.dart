import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../analysis/faults.dart' show faultIds, faultLabels;
import '../analysis/measurement_basis.dart' show appVersion;
import '../analysis/participant.dart';
import '../analysis/swing_history.dart';
import '../services/clip_store.dart';
import '../services/corpus_export.dart';
import 'theme/app_theme.dart';

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
    this.onParticipantChanged,
  });

  final Participant participant;

  /// Null when device storage was unavailable; edits then cannot be saved.
  final ParticipantStore? store;

  /// Called when the participant record is saved, so the navigation shell can
  /// propagate changes (e.g. handedness) to sibling tabs.
  final ValueChanged<Participant>? onParticipantChanged;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Participant _participant = widget.participant;

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant) {
      _participant = widget.participant;
    }
  }

  /// Anchors the iOS share popover to the export button.
  final GlobalKey _exportButtonKey = GlobalKey();
  bool _exporting = false;

  /// Retained recordings. Null until read — which is not the same as empty,
  /// and a golfer told "0 videos" when the read failed would reasonably
  /// conclude nothing was kept.
  List<StoredClip>? _clips;
  bool _deletingClips = false;

  /// Anchors each clip's share popover to the button that opened it.
  final Map<String, GlobalKey> _clipKeys = {};

  int get _clipCount => _clips?.length ?? 0;
  int get _clipBytes =>
      _clips?.fold<int>(0, (sum, c) => sum + c.sizeBytes) ?? 0;

  @override
  void initState() {
    super.initState();
    _loadClipUsage();
  }

  Future<void> _loadClipUsage() async {
    try {
      final store = await ClipStore.forApp();
      final clips = await store.list();
      if (!mounted) return;
      setState(() => _clips = clips);
    } catch (_) {
      // Leave it unknown rather than claiming zero.
      if (mounted) setState(() => _clips = null);
    }
  }

  /// Share one clip, anchored to its own button.
  ///
  /// This exists because the Files route did not reach the golfer: the app
  /// correctly reported "3 recordings, 18 MB" while the folder could not be
  /// found in Files. Sharing to Photos gives a frame-accurate scrubber, which
  /// is what reading a swing's timings actually needs.
  Future<void> _shareClip(StoredClip clip) async {
    final box = _clipKeys[clip.name]?.currentContext?.findRenderObject()
        as RenderBox?;
    final origin = shareOriginOrFallback(
      box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
      MediaQuery.of(context).size,
    );
    try {
      await shareClip(clip, origin: origin);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share ${clip.name}: $error')),
      );
    }
  }

  Future<void> _deleteClips() async {
    final count = _clipCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete saved videos?'),
        content: Text(
          'This deletes $count recording${count == 1 ? '' : 's'} from this '
          'phone and cannot be undone. Your swing measurements are kept — only '
          'the videos go.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _deletingClips = true);
    try {
      final store = await ClipStore.forApp();
      final deleted = await store.deleteAll();
      await _loadClipUsage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted $deleted video${deleted == 1 ? '' : 's'}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $error')),
      );
    } finally {
      if (mounted) setState(() => _deletingClips = false);
    }
  }

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
      if (mounted) {
        setState(() => _participant = saved);
        widget.onParticipantChanged?.call(saved);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $error')),
      );
    }
  }

  Future<void> _setCalibration({required bool enabled, String? fault}) async {
    final store = widget.store;
    setState(() {
      _participant = _participant.copyWith(
        calibrationMode: enabled,
        calibrationFault: fault ?? _participant.calibrationFault,
      );
    });
    if (store == null) return;
    try {
      final saved = await store.setCalibration(
        enabled: enabled,
        fault: fault ?? _participant.calibrationFault,
      );
      if (mounted) {
        setState(() => _participant = saved);
        widget.onParticipantChanged?.call(saved);
      }
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
    // Captured before the call so the failure message can report what we sent.
    // iOS rejects a share origin for two different reasons -- empty, or not
    // contained in the source view -- and its error prints only the rect it
    // received, which is indistinguishable from "we sent nothing" when that
    // rect is zero. Naming our own value separates the two without a rebuild.
    final origin = _shareOrigin();
    final screen = MediaQuery.of(context).size;
    try {
      final result = await const CorpusExporter().share(
        sharePositionOrigin: origin,
      );
      if (!mounted) return;
      if (result.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No swings recorded yet.')),
        );
      }
    } catch (error) {
      debugPrint('Share failed: origin=$origin screen=$screen error=$error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Share failed. Try again, or restart the app.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
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

          // -----------------------------------------------------------------
          // Recordings — the golfer's own clips, front and center.
          // -----------------------------------------------------------------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Recordings', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              _clips == null
                  ? 'Every swing you record is kept on this phone. '
                      'Nothing is uploaded.'
                  : '$_clipCount recording${_clipCount == 1 ? '' : 's'}, '
                      '${formatClipBytes(_clipBytes)}. '
                      'Tap one to open it in Photos for frame-by-frame playback.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final clip in _clips ?? const <StoredClip>[])
            ListTile(
              key: _clipKeys.putIfAbsent(clip.name, GlobalKey.new),
              dense: true,
              leading: const Icon(Icons.movie_outlined),
              title: Text(clip.name, style: theme.textTheme.bodyMedium),
              subtitle: Text(formatClipBytes(clip.sizeBytes)),
              trailing: const Icon(Icons.ios_share),
              onTap: () => _shareClip(clip),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed:
                      _deletingClips || _clipCount == 0 ? null : _deleteClips,
                  icon: const Icon(Icons.delete_outline),
                  label:
                      Text(_deletingClips ? 'Deleting…' : 'Delete all videos'),
                ),
                Gap.hsm,
                FilledButton.icon(
                  key: _exportButtonKey,
                  onPressed: _exporting ? null : _export,
                  icon: const Icon(Icons.ios_share),
                  label:
                      Text(_exporting ? 'Preparing…' : 'Export swing data'),
                ),
              ],
            ),
          ),
          const Divider(height: 32),

          // -----------------------------------------------------------------
          // Help improve the app — coach reports & calibration behind an
          // expansion tile so research controls don't dominate the page.
          // -----------------------------------------------------------------
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: const Icon(Icons.science_outlined, size: 20),
              title: const Text('Help improve the app'),
              childrenPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              children: [
                // Coach reports
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'If a coach has pointed out any of these faults, let us '
                    'know — it helps us check whether the app is seeing '
                    'the same thing. This won\'t change your reports.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                for (final faultId in coachReportFaultIds)
                  _CoachReportRow(
                    label: faultLabels[faultId] ?? faultId,
                    value: _participant.coachReports[faultId],
                    onChanged: (value) => _setReport(faultId, value),
                  ),
                Gap.lg,
                // Calibration mode
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Calibration mode',
                      style: theme.textTheme.titleSmall),
                ),
                Gap.xs,
                Text(
                  'Record a swing with one fault exaggerated on purpose '
                  'so we can check the detectors are seeing it.',
                  style: theme.textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Calibration swing'),
                  subtitle: _participant.calibrationMode
                      ? Text(
                          'Next swing recorded as calibration for '
                          '"${faultLabels[_participant.calibrationFault ?? faultIds.first] ?? faultIds.first}".',
                        )
                      : const Text('Off — swings recorded normally.'),
                  value: _participant.calibrationMode,
                  onChanged: widget.store == null
                      ? null
                      : (value) => _setCalibration(enabled: value),
                ),
                if (_participant.calibrationMode)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DropdownButtonFormField<String>(
                      value: _participant.calibrationFault ?? faultIds.first,
                      decoration: const InputDecoration(
                        labelText: 'Fault to exaggerate',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final id in faultIds)
                          DropdownMenuItem(
                            value: id,
                            child: Text(faultLabels[id] ?? id),
                          ),
                      ],
                      onChanged: widget.store == null
                          ? null
                          : (value) {
                              if (value != null) {
                                _setCalibration(enabled: true, fault: value);
                              }
                            },
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 32),

          // -----------------------------------------------------------------
          // About — version, anonymous ID, at the very bottom.
          // -----------------------------------------------------------------
          _DiagnosticsSection(participantId: _participant.id),
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
          Gap.xs,
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

/// Version and anonymous ID — small, at the bottom, for support and debugging.
class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection({required this.participantId});

  final String participantId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('About', style: theme.textTheme.titleMedium),
          Gap.sm,
          Row(
            children: [
              Expanded(
                child: Text(
                  participantId,
                  style: muted?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copy ID',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: participantId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ID copied')),
                  );
                },
              ),
            ],
          ),
          Text(
            'Random ID for this device — groups your swings together. '
            'Not linked to you or any account.',
            style: muted,
          ),
          Gap.sm,
          Text('Fore Swing $appVersion', style: muted),
        ],
      ),
    );
  }
}
