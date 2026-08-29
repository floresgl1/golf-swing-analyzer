/// Getting swings off the device, by hand.
///
/// The corpus is device-local, so a beta that never exports is a beta that
/// collects nothing usable: the swings die with the install. This is the
/// no-server path to that — the system share sheet, driven by the golfer.
///
/// Deliberately not an upload. There is no backend, no account, and no
/// background transfer, so nothing leaves the device without someone choosing
/// to send it and choosing where.
///
/// **Why zip?** iOS mangles bare `.jsonl` files sent via iMessage: the share
/// target receives a binary plist bookmark pointing at the iMessage attachment
/// path, not the file content. `participant.json` survives because iOS
/// recognises `application/json`; `.jsonl` (MIME `text/plain`) does not.
/// Wrapping everything in a single `.zip` fixes every share target — email,
/// AirDrop, iMessage, Save to Files — because iOS treats a zip as an opaque
/// blob and passes it through.
library;

import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A share origin iOS will accept, given the rect of the tapped control.
///
/// `UIActivityViewController` is a popover on iPad and must be anchored, and
/// share_plus enforces that on every iOS device: a null or zero-sized origin
/// fails the whole export with
///
///     PlatformException(error, sharePositionOrigin: argument must be set,
///     {{0, 0}, {0, 0}} must be non-zero and within coordinate space of
///     source view: {{0, 0}, {430, 932}})
///
/// which is what a golfer saw on device 2026-08-17 when the caller omitted the
/// argument entirely.
///
/// **There are two rejection conditions, not one**, and passing a non-empty
/// rect only satisfies the first. From the plugin's `FPPSharePlusPlugin.m`:
///
///     BOOL isCoordinateSpaceOfSourceView =
///         CGRectContainsRect(controller.view.frame, origin);
///     if (hasPopoverPresentationController &&
///         (!isCoordinateSpaceOfSourceView || CGRectIsEmpty(origin))) { ... }
///
/// So the rect must *also* lie entirely inside the presenting view. Anchoring
/// to the button gives the right iPad behaviour — the popover points at the
/// control that was tapped — but a button rect is only contained if the
/// control is fully on screen, which a scrolled list does not guarantee.
/// Intersecting with the screen makes containment true by construction and
/// still points at the visible part of the button.
Rect shareOriginOrFallback(Rect? fromControl, Size screen) {
  final bounds = Offset.zero & screen;
  final clamped = fromControl?.intersect(bounds);
  // `intersect` returns a negative-sized rect when they do not overlap at all;
  // `isEmpty` covers that as well as a genuinely zero-sized control.
  if (clamped != null && !clamped.isEmpty) return clamped;
  return Rect.fromCenter(center: bounds.center, width: 1, height: 1);
}

/// What an export attempt produced.
class ExportResult {
  /// Files that were packed into the zip and handed to the share sheet.
  final List<String> fileNames;

  /// Records in the corpus file, or null when it could not be read.
  final int? recordCount;

  const ExportResult({required this.fileNames, this.recordCount});

  bool get isEmpty => fileNames.isEmpty;
}

/// Collects the corpus files into a zip and opens the system share sheet.
class CorpusExporter {
  const CorpusExporter();

  /// File names that make up the corpus, in the order they are most useful to
  /// whoever receives them.
  static const List<String> corpusFileNames = [
    'swing_history.jsonl',
    'participant.json',
    // Clips the app refused to report on. Exported alongside the swings
    // because a gate whose rejections never leave the device cannot be
    // measured -- see rejection_log.dart.
    'swing_history_rejections.jsonl',
    'swing_history_failures.jsonl',
  ];

  /// Pack all corpus files into a zip and share it.
  ///
  /// Returns an empty result when there is nothing to send, so the caller can
  /// say so rather than opening an empty share sheet.
  Future<ExportResult> share({Rect? sharePositionOrigin}) async {
    final dir = await getApplicationDocumentsDirectory();

    // Collect whichever corpus files exist.
    final present = <File>[];
    final names = <String>[];
    for (final name in corpusFileNames) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) {
        present.add(file);
        names.add(name);
      }
    }
    if (present.isEmpty) {
      return const ExportResult(fileNames: []);
    }

    final count = await _countRecords(
      File(p.join(dir.path, corpusFileNames.first)),
    );

    // Build a zip archive containing all present corpus files.
    final archive = Archive();
    for (final file in present) {
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(
        p.basename(file.path),
        bytes.length,
        bytes,
      ));
    }
    final zipBytes = ZipEncoder().encode(archive);

    // Write the zip to a temp file. Named with today's date so multiple
    // exports on the same day overwrite rather than accumulating, and the
    // recipient can tell when it was sent.
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final zipName = 'swing_export_$stamp.zip';
    final zipFile = File(p.join(dir.path, zipName));
    await zipFile.writeAsBytes(zipBytes!);

    try {
      await Share.shareXFiles(
        [XFile(zipFile.path, mimeType: 'application/zip')],
        subject: 'Swing data export',
        text: 'Swing history export'
            '${count == null ? '' : ' — $count swing${count == 1 ? '' : 's'}'}.',
        sharePositionOrigin: sharePositionOrigin,
      );
    } finally {
      // Clean up the temp zip. Best-effort: a stale zip in Documents is
      // harmless and will be overwritten on the next export.
      try {
        await zipFile.delete();
      } on FileSystemException {
        // Nothing to do.
      }
    }

    return ExportResult(fileNames: names, recordCount: count);
  }

  /// Count records without parsing them: every line but the header.
  Future<int?> _countRecords(File file) async {
    try {
      if (!await file.exists()) return null;
      final lines = (await file.readAsString())
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) return 0;
      // First line is the schema header on any file this build wrote.
      return lines.first.contains('"schema_version"')
          ? lines.length - 1
          : lines.length;
    } catch (_) {
      return null;
    }
  }
}
