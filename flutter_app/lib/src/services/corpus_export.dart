/// Getting swings off the device, by hand.
///
/// The corpus is device-local, so a beta that never exports is a beta that
/// collects nothing usable: the swings die with the install. This is the
/// no-server path to that — the system share sheet, driven by the golfer.
///
/// Deliberately not an upload. There is no backend, no account, and no
/// background transfer, so nothing leaves the device without someone choosing
/// to send it and choosing where.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// What an export attempt produced.
class ExportResult {
  /// Files that existed and were handed to the share sheet.
  final List<String> fileNames;

  /// Records in the corpus file, or null when it could not be read.
  final int? recordCount;

  const ExportResult({required this.fileNames, this.recordCount});

  bool get isEmpty => fileNames.isEmpty;
}

/// Collects the corpus files and opens the system share sheet.
class CorpusExporter {
  const CorpusExporter();

  /// File names that make up the corpus, in the order they are most useful to
  /// whoever receives them.
  static const List<String> corpusFileNames = [
    'swing_history.jsonl',
    'participant.json',
    'swing_history_failures.jsonl',
  ];

  /// Share whichever corpus files exist.
  ///
  /// Returns an empty result when there is nothing to send, so the caller can
  /// say so rather than opening an empty share sheet.
  Future<ExportResult> share({Rect? sharePositionOrigin}) async {
    final dir = await getApplicationDocumentsDirectory();
    final present = <XFile>[];
    final names = <String>[];
    for (final name in corpusFileNames) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) {
        present.add(XFile(file.path));
        names.add(name);
      }
    }
    if (present.isEmpty) {
      return const ExportResult(fileNames: []);
    }

    final count = await _countRecords(File(p.join(dir.path, corpusFileNames.first)));
    await Share.shareXFiles(
      present,
      subject: 'Golf swing corpus export',
      text: 'Swing history export'
          '${count == null ? '' : ' — $count swing${count == 1 ? '' : 's'}'}.',
      sharePositionOrigin: sharePositionOrigin,
    );
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
