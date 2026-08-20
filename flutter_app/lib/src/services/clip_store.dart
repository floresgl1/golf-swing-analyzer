/// Keeping the recorded video after the swing has been analyzed.
///
/// The clips used to be thrown away. `record_screen.dart` handed
/// `stopVideoRecording()`'s path straight to the analyzer, nothing copied it
/// anywhere, and it sat in the app's temp directory for iOS to reclaim. That
/// cost the project the five recordings of 2026-08-17: their per-frame series
/// survived in the corpus, but the video they were measured from could not be
/// rewatched, so nobody could say where the swing actually was. P1.4 — locating
/// the swing in a long clip — is blocked on exactly that ground truth. See
/// ROADMAP.md.
///
/// So the clip is now moved into the app's Documents directory, which the
/// `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` keys already
/// expose in the Files app. **Nothing new leaves the device**: there is no
/// backend and no upload, and this writes to the same container the corpus
/// already lives in.
///
/// Deliberately a MOVE, not a copy. A copy would leave two of a ~50 MB file on
/// a phone, one of them in a directory iOS deletes on its own schedule, and
/// analysis would then be reading the doomed one.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A retained recording.
class StoredClip {
  /// File name within the clips directory, e.g. `swing_20260817_075150.mp4`.
  final String name;

  /// Absolute path on disk.
  final String path;

  final int sizeBytes;
  final DateTime modified;

  const StoredClip({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });
}

/// Hand one retained clip to the system share sheet.
///
/// The Files route was supposed to be enough — `UIFileSharingEnabled` exposes
/// the Documents directory, and that is genuinely where the clips are. On
/// device 2026-08-19 it was not enough: the app reported "3 recordings, 18 MB"
/// while the golfer could not find the folder in Files at all. Rather than
/// keep guessing at the Files browser, this offers the clip through the same
/// share sheet the corpus export already uses.
///
/// The useful destination is **Save Video**, which puts the clip in Photos —
/// where there is a frame-accurate scrubber. Labelling a swing means reading
/// times off a scrubber, so Photos is a better answer than Files was.
///
/// [origin] must be a non-degenerate rect inside the presenting view or iOS
/// rejects the whole share; see `shareOriginOrFallback` in `corpus_export.dart`
/// for the two conditions and what they cost to learn.
Future<void> shareClip(StoredClip clip, {required Rect origin}) {
  return Share.shareXFiles(
    [XFile(clip.path, mimeType: 'video/mp4')],
    subject: clip.name,
    text: 'Swing recording ${clip.name}',
    sharePositionOrigin: origin,
  );
}

/// Total size of a set of clips, formatted for a person rather than a machine.
///
/// Whole MB up to a gigabyte, then one decimal — a golfer deciding whether to
/// clear space does not need three significant figures, and "0.7 GB" is easier
/// to weigh against a phone's free space than "716 MB".
String formatClipBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const mb = 1024 * 1024;
  if (bytes < mb) return 'under 1 MB';
  final megabytes = bytes / mb;
  if (megabytes < 1024) return '${megabytes.round()} MB';
  return '${(megabytes / 1024).toStringAsFixed(1)} GB';
}

/// Clip file name for a swing recorded at [at].
///
/// Local time, seconds precision, sortable, and free of the characters a
/// timestamp normally carries that a filesystem would rather it did not. It
/// deliberately does NOT try to be the record's `timestamp` field: the join
/// between a clip and its corpus record is the `clip_name` written onto the
/// record, not a name two pieces of code have to derive identically.
String clipFileName(DateTime at, {int sequence = 1}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${at.year}${two(at.month)}${two(at.day)}_'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
  final suffix = sequence > 1 ? '_$sequence' : '';
  return 'swing_$stamp$suffix.mp4';
}

/// Retains recorded clips in the app's Documents directory.
class ClipStore {
  /// Directory holding the clips. Injected so this is testable without a
  /// device; production callers use [ClipStore.forApp].
  final Directory directory;

  const ClipStore(this.directory);

  /// The store rooted at `<Documents>/clips`.
  static Future<ClipStore> forApp() async {
    final docs = await getApplicationDocumentsDirectory();
    return ClipStore(Directory(p.join(docs.path, 'clips')));
  }

  /// Move the recording at [sourcePath] into the store and return its clip.
  ///
  /// Returns null when the source is not there to move — a missing recording
  /// is a reason to carry on analyzing nothing, not a reason to crash. Any
  /// other failure is thrown, because silently not retaining is the bug this
  /// whole file exists to fix.
  Future<StoredClip?> retain(String sourcePath, {DateTime? at}) async {
    final source = File(sourcePath);
    if (!await source.exists()) return null;

    await directory.create(recursive: true);
    final when = at ?? DateTime.now();

    // Two swings can land in the same second; the sequence suffix keeps the
    // second one rather than overwriting the first.
    var sequence = 1;
    var target = File(p.join(directory.path, clipFileName(when)));
    while (await target.exists()) {
      sequence += 1;
      target = File(
        p.join(directory.path, clipFileName(when, sequence: sequence)),
      );
    }

    File stored;
    try {
      stored = await source.rename(target.path);
    } on FileSystemException {
      // rename() cannot cross filesystems. Falling back to copy-then-delete
      // keeps one copy in the end, which is the invariant that matters; the
      // delete is best-effort because a retained clip we failed to tidy up
      // after is better than no retained clip.
      stored = await source.copy(target.path);
      try {
        await source.delete();
      } on FileSystemException {
        // The temp copy stays until iOS reclaims it. Nothing to do.
      }
    }

    final stat = await stored.stat();
    return StoredClip(
      name: p.basename(stored.path),
      path: stored.path,
      sizeBytes: stat.size,
      modified: stat.modified,
    );
  }

  /// Every retained clip, newest first.
  Future<List<StoredClip>> list() async {
    if (!await directory.exists()) return const [];
    final clips = <StoredClip>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.mp4')) continue;
      final stat = await entity.stat();
      clips.add(StoredClip(
        name: p.basename(entity.path),
        path: entity.path,
        sizeBytes: stat.size,
        modified: stat.modified,
      ));
    }
    clips.sort((a, b) => b.modified.compareTo(a.modified));
    return clips;
  }

  /// Bytes held by retained clips.
  Future<int> totalBytes() async {
    final clips = await list();
    return clips.fold<int>(0, (sum, clip) => sum + clip.sizeBytes);
  }

  /// Delete every retained clip, returning how many went.
  ///
  /// Retention without a way out of it is a trap: these are videos of a person,
  /// and the only copy is on their phone. Deleting clips does NOT touch the
  /// corpus — the measurements stay, so a golfer can reclaim the space without
  /// losing their swing history.
  Future<int> deleteAll() async {
    final clips = await list();
    var deleted = 0;
    for (final clip in clips) {
      try {
        await File(clip.path).delete();
        deleted += 1;
      } on FileSystemException {
        // Skip what will not go and report the honest count.
      }
    }
    return deleted;
  }
}
