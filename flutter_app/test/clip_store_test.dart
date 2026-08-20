import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/services/clip_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late ClipStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('clip_store_test');
    store = ClipStore(Directory(p.join(root.path, 'clips')));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File fakeRecording(String name, {int bytes = 1024}) {
    final file = File(p.join(root.path, name));
    file.writeAsBytesSync(List<int>.filled(bytes, 7));
    return file;
  }

  group('clipFileName', () {
    test('is sortable, second-precise, and filesystem-safe', () {
      final name = clipFileName(DateTime(2026, 8, 17, 7, 51, 50));
      expect(name, 'swing_20260817_075150.mp4');
      expect(name, isNot(contains(':')));
    });

    test('pads every component', () {
      expect(clipFileName(DateTime(2026, 1, 2, 3, 4, 5)),
          'swing_20260102_030405.mp4');
    });

    test('names sort in the order the swings happened', () {
      final names = [
        clipFileName(DateTime(2026, 8, 17, 7, 51, 50)),
        clipFileName(DateTime(2026, 8, 17, 7, 9, 3)),
        clipFileName(DateTime(2026, 12, 1, 0, 0, 0)),
      ]..sort();
      expect(names.first, 'swing_20260817_070903.mp4');
      expect(names.last, 'swing_20261201_000000.mp4');
    });
  });

  group('retain', () {
    test('moves the recording out of temp rather than copying it', () async {
      final source = fakeRecording('temp_clip.mp4');
      final clip = await store.retain(source.path,
          at: DateTime(2026, 8, 17, 7, 51, 50));

      expect(clip, isNotNull);
      expect(clip!.name, 'swing_20260817_075150.mp4');
      expect(File(clip.path).existsSync(), isTrue);
      // The whole point: exactly one copy of a large file, and it is not the
      // one in the directory iOS reclaims.
      expect(source.existsSync(), isFalse);
      expect(clip.sizeBytes, 1024);
    });

    test('two swings in the same second both survive', () async {
      final at = DateTime(2026, 8, 17, 7, 51, 50);
      final first = await store.retain(fakeRecording('a.mp4').path, at: at);
      final second = await store.retain(fakeRecording('b.mp4').path, at: at);

      expect(first!.name, 'swing_20260817_075150.mp4');
      expect(second!.name, 'swing_20260817_075150_2.mp4');
      expect(File(first.path).existsSync(), isTrue);
      expect(File(second.path).existsSync(), isTrue);
      expect((await store.list()).length, 2);
    });

    test('a missing recording is null, not a crash', () async {
      expect(await store.retain(p.join(root.path, 'gone.mp4')), isNull);
    });

    test('creates the clips directory on first use', () async {
      expect(store.directory.existsSync(), isFalse);
      await store.retain(fakeRecording('a.mp4').path);
      expect(store.directory.existsSync(), isTrue);
    });
  });

  group('list and totalBytes', () {
    test('empty before anything is retained', () async {
      expect(await store.list(), isEmpty);
      expect(await store.totalBytes(), 0);
    });

    test('newest first, and sizes add up', () async {
      await store.retain(fakeRecording('a.mp4', bytes: 100).path,
          at: DateTime(2026, 8, 17, 7, 0, 0));
      await store.retain(fakeRecording('b.mp4', bytes: 250).path,
          at: DateTime(2026, 8, 17, 9, 0, 0));

      final clips = await store.list();
      expect(clips.map((c) => c.name), [
        'swing_20260817_090000.mp4',
        'swing_20260817_070000.mp4',
      ]);
      expect(await store.totalBytes(), 350);
    });

    test('ignores files that are not clips', () async {
      await store.retain(fakeRecording('a.mp4').path);
      File(p.join(store.directory.path, 'notes.txt')).writeAsStringSync('x');
      expect((await store.list()).length, 1);
    });
  });

  group('deleteAll', () {
    test('reclaims the space and reports the honest count', () async {
      await store.retain(fakeRecording('a.mp4').path,
          at: DateTime(2026, 8, 17, 7, 0, 0));
      await store.retain(fakeRecording('b.mp4').path,
          at: DateTime(2026, 8, 17, 8, 0, 0));

      expect(await store.deleteAll(), 2);
      expect(await store.list(), isEmpty);
      expect(await store.totalBytes(), 0);
    });

    test('is safe to call with nothing stored', () async {
      expect(await store.deleteAll(), 0);
    });
  });

  group('formatClipBytes', () {
    test('reads as a person would say it', () {
      expect(formatClipBytes(0), '0 MB');
      expect(formatClipBytes(500), 'under 1 MB');
      expect(formatClipBytes(50 * 1024 * 1024), '50 MB');
      expect(formatClipBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatClipBytes(1536 * 1024 * 1024), '1.5 GB');
    });
  });
}
