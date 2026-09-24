import 'package:test/test.dart';
import 'package:throttled_location/src/backlog.dart';
import 'package:throttled_location/throttled_location.dart';

final t0 = DateTime.utc(2026, 9, 24, 8);

LocationFix fixAt(int second) => LocationFix(
    lat: 36 + second * 1e-4,
    lon: 3,
    timestamp: t0.add(Duration(seconds: second)));

List<int> seconds(Backlog b) =>
    b.items.map((f) => f.timestamp.difference(t0).inSeconds).toList();

void main() {
  group('BacklogPolicy', () {
    test('rejects nonsense bounds', () {
      expect(() => BacklogPolicy(maxCount: 0), throwsArgumentError);
      expect(() => BacklogPolicy(maxAge: Duration.zero), throwsArgumentError);
      expect(
          () => BacklogOverflow.downsample(keepEvery: 1), throwsArgumentError);
    });
  });

  group('drop-oldest overflow', () {
    test('keeps the newest maxCount points in order', () {
      final b = Backlog(BacklogPolicy(maxCount: 3));
      final drops = <DropReason, int>{};
      for (var s = 0; s < 5; s++) {
        b
            .add(fixAt(s), t0.add(Duration(seconds: s)))
            .forEach((k, v) => drops[k] = (drops[k] ?? 0) + v);
      }
      expect(seconds(b), [2, 3, 4]);
      expect(drops, {DropReason.overflow: 2});
    });
  });

  group('downsample overflow', () {
    test('keeps every k-th point plus the newest when full', () {
      final b = Backlog(BacklogPolicy(
          maxCount: 6, overflow: BacklogOverflow.downsample(keepEvery: 2)));
      for (var s = 0; s < 6; s++) {
        expect(b.add(fixAt(s), t0), isEmpty);
      }
      // The 7th point overflows: indices 0,2,4 survive plus the new one.
      final drops = b.add(fixAt(6), t0);
      expect(seconds(b), [0, 2, 4, 6]);
      expect(drops, {DropReason.downsampled: 3});
    });

    test('older history ends up coarser than recent history', () {
      final b = Backlog(BacklogPolicy(
          maxCount: 8, overflow: BacklogOverflow.downsample(keepEvery: 2)));
      for (var s = 0; s < 40; s++) {
        b.add(fixAt(s), t0);
      }
      final kept = seconds(b);
      expect(kept.length, lessThanOrEqualTo(8));
      expect(kept.first, 0, reason: 'the oldest breadcrumb survives');
      expect(kept.last, 39, reason: 'the newest point always survives');
      expect(kept, orderedEquals([...kept]..sort()));
      final firstGap = kept[1] - kept[0];
      final lastGap = kept[kept.length - 1] - kept[kept.length - 2];
      expect(firstGap, greaterThan(lastGap));
    });

    test('keepEvery 3 keeps indices 0,3,6...', () {
      final b = Backlog(BacklogPolicy(
          maxCount: 9, overflow: BacklogOverflow.downsample(keepEvery: 3)));
      for (var s = 0; s < 10; s++) {
        b.add(fixAt(s), t0);
      }
      expect(seconds(b), [0, 3, 6, 9]);
    });
  });

  group('age bound', () {
    test('expire() drops points older than maxAge', () {
      final b = Backlog(BacklogPolicy(maxAge: const Duration(minutes: 10)));
      for (var s = 0; s <= 1200; s += 300) {
        b.add(fixAt(s), t0.add(Duration(seconds: s)));
      }
      expect(seconds(b), [0, 300, 600, 900, 1200]);
      final dropped = b.expire(t0.add(const Duration(seconds: 1200)));
      expect(dropped, 2);
      expect(seconds(b), [600, 900, 1200]);
    });

    test('add() rejects a point that is already too old', () {
      final b = Backlog(BacklogPolicy(maxAge: const Duration(minutes: 1)));
      final drops = b.add(fixAt(0), t0.add(const Duration(minutes: 5)));
      expect(drops, {DropReason.expired: 1});
      expect(b.isEmpty, isTrue);
    });
  });

  group('batches and locking', () {
    test('lockBatch returns the oldest points; commit removes them', () {
      final b = Backlog(BacklogPolicy());
      for (var s = 0; s < 5; s++) {
        b.add(fixAt(s), t0);
      }
      final batch = b.lockBatch(2);
      expect(batch.map((f) => f.timestamp.difference(t0).inSeconds), [0, 1]);
      expect(b.locked, 2);
      b.commitLocked();
      expect(seconds(b), [2, 3, 4]);
      expect(b.locked, 0);
    });

    test('release keeps the points for a retry', () {
      final b = Backlog(BacklogPolicy());
      b.add(fixAt(0), t0);
      b.lockBatch(10);
      b.releaseLocked();
      expect(seconds(b), [0]);
      expect(b.locked, 0);
    });

    test('overflow never drops a point that is in flight', () {
      final b = Backlog(BacklogPolicy(maxCount: 3));
      for (var s = 0; s < 3; s++) {
        b.add(fixAt(s), t0);
      }
      b.lockBatch(2);
      b.add(fixAt(3), t0);
      expect(seconds(b), [0, 1, 3]);
      b.commitLocked();
      expect(seconds(b), [3]);
    });

    test('downsampling skips in-flight points', () {
      final b = Backlog(BacklogPolicy(
          maxCount: 5, overflow: BacklogOverflow.downsample(keepEvery: 2)));
      for (var s = 0; s < 5; s++) {
        b.add(fixAt(s), t0);
      }
      b.lockBatch(2); // 0, 1 in flight
      b.add(fixAt(5), t0); // unlocked part 2,3,4,5 -> keep 2,4 and newest 5
      expect(seconds(b), [0, 1, 2, 4, 5]);
    });

    test('expire skips in-flight points', () {
      final b = Backlog(BacklogPolicy(maxAge: const Duration(seconds: 30)));
      b.add(fixAt(0), t0);
      b.add(fixAt(10), t0);
      b.lockBatch(1);
      expect(b.expire(t0.add(const Duration(seconds: 100))), 1);
      expect(seconds(b), [0]);
    });

    test('can be seeded from persisted points and trims them to bounds', () {
      final b = Backlog(BacklogPolicy(maxCount: 2),
          initial: [fixAt(0), fixAt(1), fixAt(2)]);
      expect(seconds(b), [1, 2]);
    });
  });
}
