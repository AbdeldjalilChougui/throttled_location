import 'dart:convert';
import 'dart:io';

import 'location_fix.dart';
import 'store.dart';

/// A [BacklogStore] that keeps the backlog in one JSON file.
///
/// Each [write] goes to `<path>.tmp`, is flushed, and is then renamed over
/// `<path>`, so a crash leaves either the old or the new file. Writes are
/// serialised. Suits backlogs of up to a few thousand points.
class JsonFileBacklogStore implements BacklogStore {
  /// Creates a store at [path]. Parent directories are created on the
  /// first write.
  JsonFileBacklogStore(this.path);

  /// Location of the JSON file.
  final String path;

  Future<void> _tail = Future.value();

  @override
  Future<List<LocationFix>> read() => _serialized(() async {
        final file = File(path);
        if (!await file.exists()) return const [];
        final Object? doc;
        try {
          doc = jsonDecode(await file.readAsString());
        } on FormatException catch (e) {
          throw FormatException('Corrupt backlog file $path: ${e.message}');
        }
        if (doc is! Map<String, Object?> || doc['fixes'] is! List) {
          throw FormatException('Unexpected backlog file layout in $path');
        }
        return [
          for (final raw in doc['fixes'] as List)
            if (raw is Map<String, Object?>)
              LocationFix.fromJson(raw)
            else
              throw FormatException('Unexpected backlog entry in $path'),
        ];
      });

  @override
  Future<void> write(List<LocationFix> fixes) {
    final body = jsonEncode({
      'version': 1,
      'fixes': [for (final f in fixes) f.toJson()],
    });
    return _serialized(() async {
      final tmp = File('$path.tmp');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(path);
    });
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}
