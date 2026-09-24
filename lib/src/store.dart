import 'location_fix.dart';

/// Persists the offline backlog so it survives an app restart.
///
/// The reporter reads it once on `start` and writes the whole backlog
/// after each change. Writes are issued one at a time, never concurrently.
abstract interface class BacklogStore {
  /// Returns the persisted points, oldest first.
  Future<List<LocationFix>> read();

  /// Replaces the persisted points with [fixes].
  Future<void> write(List<LocationFix> fixes);
}

/// A [BacklogStore] that keeps points in memory only. It is the default,
/// and the backlog is lost when the process ends.
class InMemoryBacklogStore implements BacklogStore {
  List<LocationFix> _fixes = const [];

  /// The currently stored points.
  List<LocationFix> get fixes => _fixes;

  @override
  Future<List<LocationFix>> read() async => _fixes;

  @override
  Future<void> write(List<LocationFix> fixes) async =>
      _fixes = List.unmodifiable(fixes);
}
