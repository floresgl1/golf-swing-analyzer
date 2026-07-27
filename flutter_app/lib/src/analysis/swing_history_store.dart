/// On-device persistence for the swing corpus.
///
/// ## Format: JSON Lines, append-only
///
/// One JSON object per line, oldest first. This replaces the previous
/// `{"sessions": [...]}` document, which was rewritten in full on every swing.
/// That mattered once records started carrying the per-frame arrays (~10 KB
/// each): a 200-swing history would have meant re-serializing ~2 MB to record
/// one swing, and — far worse — putting the entire corpus at risk on every
/// single write.
///
/// ## Recovery: a damaged file must never cost more than the damaged part
///
/// The pattern is ported from `_read_history` / `save_session` in
/// `src/swing_history.py` on `main`, adapted to a line-oriented file:
///
/// * A file that cannot be read or holds nothing parseable is renamed to
///   `<name>.corrupt.bak` and treated as empty, so the next append starts a
///   fresh file instead of failing forever.
/// * A single unparseable *line* is skipped and counted, not fatal. This is the
///   main advantage of the line format: damage costs those records, not all of
///   them.
///
/// The bug this replaces: `load()` and `append()` both threw on a corrupt file,
/// and the throw was swallowed at the call site, so a tester whose file was
/// damaged once silently contributed **zero** swings from then on, permanently,
/// with nothing surfaced. Recovery here is what makes that unreachable;
/// [HistoryFailureLog] and the call site's handling are what make a write
/// failure visible rather than mistaken for a first swing.
///
/// ## Atomicity
///
/// Whole-file rewrites (corrupt-file recovery, legacy migration) go through
/// [_writeLinesAtomically] — temp file then rename — exactly as the Python
/// `save_session` does, so an interrupted rewrite can never leave a truncated
/// corpus behind.
///
/// Appending a record deliberately does **not** use that pattern: temp-and-
/// rename requires copying the whole file, which is the very cost the line
/// format exists to avoid. A record is appended to the open file instead, and
/// the durability gap that leaves — a crash mid-append can write a partial
/// trailing line — is covered by the reader, which skips and counts an
/// unparseable line. The worst case is losing the in-flight swing, never the
/// corpus.
library;

import 'dart:convert';
import 'dart:io';

import 'swing_history.dart';

/// Result of reading the corpus.
class HistoryLoad {
  /// Parsed records, oldest first.
  final List<SwingSession> sessions;

  /// Lines that were present but could not be parsed. Non-zero means records
  /// were lost to damage — worth surfacing, never worth throwing over.
  final int skippedLines;

  /// Whether the whole file was unusable and got quarantined to
  /// `<name>.corrupt.bak`.
  final bool recoveredFromCorruption;

  const HistoryLoad({
    required this.sessions,
    this.skippedLines = 0,
    this.recoveredFromCorruption = false,
  });
}

/// How the attempt to record a swing ended.
///
/// Exists so the report screen can tell "this is your first swing" apart from
/// "this swing was not saved". Both used to arrive as `comparison == null`.
enum HistoryWriteStatus {
  /// The record was written.
  saved,

  /// The record could not be written. The swing is not in the corpus.
  failed,
}

/// Outcome of appending one swing.
class AppendResult {
  /// Comparison against the previous stored swing, or null when there was no
  /// comparable previous record.
  final SwingComparison? comparison;

  /// True when this was genuinely the first swing in the corpus. Distinct from
  /// `comparison == null`, which is also true when the previous record existed
  /// but was unreadable.
  final bool isFirstSwing;

  /// Whether a damaged file was quarantined while appending.
  final bool recoveredFromCorruption;

  const AppendResult({
    required this.comparison,
    required this.isFirstSwing,
    this.recoveredFromCorruption = false,
  });
}

/// Reads and appends swing records in a JSON Lines file on the device.
///
/// In the app, build the store with a file under the app documents directory
/// (package `path_provider`):
///
/// ```dart
/// final dir = await getApplicationDocumentsDirectory();
/// final store = SwingHistoryStore(
///   File(p.join(dir.path, 'swing_history.jsonl')),
///   legacyFile: File(p.join(dir.path, 'swing_history.json')),
/// );
/// final result = await store.append(session);
/// ```
class SwingHistoryStore {
  SwingHistoryStore(this.file, {this.legacyFile});

  /// The JSON Lines corpus.
  final File file;

  /// The pre-JSONL `{"sessions": [...]}` file, if one may exist from an earlier
  /// build. Migrated into [file] once, then renamed aside. Null disables
  /// migration (tests that start from a clean directory).
  final File? legacyFile;

  static const _jsonl = JsonEncoder();

  // ---- Reading ----

  /// Every stored record, oldest first, recovering from damage rather than
  /// throwing.
  ///
  /// Reads and parses the whole corpus including the per-frame arrays, so it is
  /// the export path, not the append path — [append] uses [lastSession].
  Future<HistoryLoad> load() async {
    await _migrateLegacyIfPresent();
    if (!await file.exists()) return const HistoryLoad(sessions: []);

    final String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      // Unreadable or not valid UTF-8 — nothing to salvage line by line.
      await _quarantine();
      return const HistoryLoad(sessions: [], recoveredFromCorruption: true);
    }

    final lines = _contentLines(text);
    final sessions = <SwingSession>[];
    var skipped = 0;
    for (final line in lines) {
      final session = _tryParse(line);
      if (session == null) {
        skipped++;
      } else {
        sessions.add(session);
      }
    }

    // Content that yielded nothing is damage, not history: quarantine it so the
    // next append starts clean instead of appending onto garbage forever.
    if (sessions.isEmpty && lines.isNotEmpty) {
      await _quarantine();
      return const HistoryLoad(sessions: [], recoveredFromCorruption: true);
    }
    return HistoryLoad(sessions: sessions, skippedLines: skipped);
  }

  /// The most recent parseable record, or null when there is none.
  ///
  /// Walks backwards and stops at the first line that parses, so appending stays
  /// cheap no matter how large the corpus has grown — it never parses the frame
  /// arrays of records it does not need.
  Future<SwingSession?> lastSession() async {
    if (!await file.exists()) return null;
    final String text;
    try {
      text = await file.readAsString();
    } catch (_) {
      await _quarantine();
      return null;
    }
    final lines = _contentLines(text);
    for (var i = lines.length - 1; i >= 0; i--) {
      final session = _tryParse(lines[i]);
      if (session != null) return session;
    }
    // Content, but not one parseable record in it: the same whole-file damage
    // [load] quarantines. Handled here too so [append] — which reads through
    // this method, not [load] — recovers identically instead of stacking good
    // records on top of garbage forever.
    if (lines.isNotEmpty) await _quarantine();
    return null;
  }

  /// Number of parseable records currently stored.
  Future<int> recordCount() async => (await load()).sessions.length;

  // ---- Writing ----

  /// Append [session] and compare it against the previous stored record.
  ///
  /// Throws on write failure. The caller must surface that — a swing that was
  /// not recorded has to be distinguishable from the first swing of a corpus,
  /// which is exactly the distinction the old blanket `catch` destroyed.
  Future<AppendResult> append(SwingSession session) async {
    await _migrateLegacyIfPresent();

    var recovered = false;
    SwingSession? previous;
    final existed = await file.exists();
    if (existed) {
      previous = await lastSession();
      // lastSession() quarantines an unreadable file; detect that it did.
      recovered = previous == null && !await file.exists();
    }

    await _appendLine(_jsonl.convert(session.toJson()));

    return AppendResult(
      comparison:
          previous == null ? null : SwingComparison.between(previous, session),
      isFirstSwing: !existed || recovered,
      recoveredFromCorruption: recovered,
    );
  }

  /// Rewrite the whole corpus atomically: temp file, then rename over the
  /// target, so an interrupted write cannot leave a truncated file behind.
  /// Used for recovery and migration, never for a plain append.
  Future<void> _writeLinesAtomically(List<String> lines) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Future<void> _appendLine(String line) async {
    await file.parent.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.append);
    try {
      sink.write('$line\n');
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  // ---- Recovery helpers ----

  static List<String> _contentLines(String text) =>
      [for (final l in text.split('\n')) if (l.trim().isNotEmpty) l];

  /// Parse one line, returning null rather than throwing on anything malformed
  /// — bad JSON, the wrong shape, or a record missing a field the model reads.
  static SwingSession? _tryParse(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['faults'] is! Map<String, dynamic>) return null;
      return SwingSession.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Move a damaged file aside so the next write starts fresh. Best effort: if
  /// the rename fails the file is left alone rather than deleted, since a file
  /// we cannot move is still better kept than destroyed.
  Future<void> _quarantine() async {
    try {
      await file.rename('${file.path}.corrupt.bak');
    } catch (_) {
      // Leave it; the corpus is already reported as empty to the caller.
    }
  }

  // ---- Legacy migration ----

  /// Carry a pre-JSONL `{"sessions": [...]}` file into the line format once.
  ///
  /// Beta devices already hold swings in the old format. They lack every
  /// capture-context field added here, but they are still real recorded swings,
  /// and silently orphaning them would be the same class of data loss this
  /// whole change exists to stop. Runs only when the new file does not yet
  /// exist, and renames the old file aside afterwards, so it cannot run twice.
  Future<void> _migrateLegacyIfPresent() async {
    final legacy = legacyFile;
    if (legacy == null) return;
    if (!await legacy.exists()) return;
    if (await file.exists()) return; // already migrated (or superseded)

    var lines = <String>[];
    try {
      final data = jsonDecode(await legacy.readAsString());
      if (data is Map<String, dynamic> && data['sessions'] is List) {
        for (final raw in data['sessions'] as List<dynamic>) {
          if (raw is! Map<String, dynamic>) continue;
          try {
            lines.add(_jsonl.convert(SwingSession.fromJson(raw).toJson()));
          } catch (_) {
            // Skip an individual malformed legacy record, keep the rest.
          }
        }
      }
    } catch (_) {
      lines = const [];
    }

    if (lines.isNotEmpty) await _writeLinesAtomically(lines);
    try {
      await legacy.rename('${legacy.path}.migrated.bak');
    } catch (_) {
      // If it cannot be renamed the `file.exists()` guard above still stops a
      // second migration.
    }
  }
}

/// Durable, best-effort record of history writes that failed.
///
/// Exists so a failed append is *counted* somewhere rather than only logged to a
/// console nobody reads on a beta device. Deliberately a separate file: the
/// reason a write failed is usually that the corpus file itself is unwritable.
class HistoryFailureLog {
  HistoryFailureLog(this.file);

  final File file;

  /// Append one failure. Never throws — if even this cannot be written there is
  /// nothing further to do, and losing the log entry must not also lose the
  /// report screen.
  Future<void> record(Object error) async {
    try {
      await file.parent.create(recursive: true);
      final line = jsonEncode({
        'timestamp': DateTime.now().toIso8601String(),
        'error': error.toString(),
      });
      final sink = file.openWrite(mode: FileMode.append);
      try {
        sink.write('$line\n');
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (_) {
      // Best effort by design.
    }
  }

  /// How many write failures have been recorded on this device.
  Future<int> count() async {
    try {
      if (!await file.exists()) return 0;
      return SwingHistoryStore._contentLines(await file.readAsString()).length;
    } catch (_) {
      return 0;
    }
  }
}
