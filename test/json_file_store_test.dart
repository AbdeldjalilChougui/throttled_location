@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:throttled_location/io.dart';

import 'support/tracks.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('throttled_location_');
    path = '${dir.path}/nested/backlog.json';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a missing file reads as empty', () async {
    expect(await JsonFileBacklogStore(path).read(), isEmpty);
  });

  test('round-trips points in order and creates parent directories', () async {
    final fixes = [
      fixAt(0, 0, 0, speed: 3, heading: 90),
      fixAt(10, 5, 1000, accuracy: null, isMocked: true),
    ];
    await JsonFileBacklogStore(path).write(fixes);
    expect(await JsonFileBacklogStore(path).read(), fixes);
  });

  test('an empty write leaves an empty backlog', () async {
    final store = JsonFileBacklogStore(path);
    await store.write([fixAt(0, 0, 0)]);
    await store.write(const []);
    expect(await JsonFileBacklogStore(path).read(), isEmpty);
  });

  test('writes replace the file atomically and leave no temp file', () async {
    final store = JsonFileBacklogStore(path);
    await Future.wait([
      for (var i = 0; i < 20; i++)
        store.write([for (var j = 0; j <= i; j++) fixAt(0, 0, j * 1000)]),
    ]);
    expect(await JsonFileBacklogStore(path).read(), hasLength(20));
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('a leftover temp file from a crash is ignored', () async {
    await JsonFileBacklogStore(path).write([fixAt(0, 0, 0)]);
    File('$path.tmp').writeAsStringSync('{"torn');
    expect(await JsonFileBacklogStore(path).read(), [fixAt(0, 0, 0)]);
  });

  test('a corrupt file throws FormatException', () async {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('not json');
    expect(JsonFileBacklogStore(path).read(), throwsFormatException);
    File(path).writeAsStringSync('{"version": 1}');
    expect(JsonFileBacklogStore(path).read(), throwsFormatException);
  });
}
