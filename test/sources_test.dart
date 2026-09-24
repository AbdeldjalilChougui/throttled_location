import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:throttled_location/throttled_location.dart';

import 'support/tracks.dart';

void main() {
  group('PollingLocationSource', () {
    test('reads at once and then every period', () {
      fakeAsync((async) {
        var n = 0;
        final src = PollingLocationSource(() async => fixAt(0, 0, 1000 * n++),
            period: const Duration(seconds: 10));
        final got = <LocationFix>[];
        final sub = src.watch().listen(got.add);
        async.elapse(const Duration(seconds: 35));
        expect(got.map(sec), [0, 1, 2, 3]);
        sub.cancel();
        async.elapse(const Duration(minutes: 1));
        expect(got, hasLength(4));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('never overlaps a slow read', () {
      fakeAsync((async) {
        var inFlight = 0, maxInFlight = 0, n = 0;
        final src = PollingLocationSource(() async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(seconds: 25));
          inFlight--;
          return fixAt(0, 0, 1000 * n++);
        }, period: const Duration(seconds: 10));
        final got = <LocationFix>[];
        final sub = src.watch().listen(got.add);
        async.elapse(const Duration(seconds: 61));
        expect(maxInFlight, 1);
        expect(got, hasLength(2));
        sub.cancel();
        async.elapse(const Duration(minutes: 1));
      });
    });

    test('read errors are forwarded and polling continues', () {
      fakeAsync((async) {
        var n = 0;
        final src = PollingLocationSource(() async {
          if (n++ == 0) throw StateError('no GPS');
          return fixAt(0, 0, 0);
        }, period: const Duration(seconds: 5));
        final errors = <Object>[];
        final got = <LocationFix>[];
        final sub = src.watch().listen(got.add, onError: errors.add);
        async.elapse(const Duration(seconds: 6));
        expect(errors, hasLength(1));
        expect(got, hasLength(1));
        sub.cancel();
      });
    });
  });

  test('LocationSource.fromStream opens a fresh stream per watch()', () {
    var opened = 0;
    final src = LocationSource.fromStream(() {
      opened++;
      return Stream.value(fixAt(0, 0, 0));
    });
    src.watch();
    src.watch();
    expect(opened, 2);
  });

  test('LocationSink.fromFunction delegates', () async {
    final sink = LocationSink.fromFunction((batch) async =>
        SinkResult.accepted(nextInterval: Duration(seconds: batch.length)));
    final r = await sink.send([fixAt(0, 0, 0), fixAt(1, 0, 1000)]);
    expect(r.accepted, isTrue);
    expect(r.nextInterval, const Duration(seconds: 2));
  });

  test('InMemoryBacklogStore round-trips', () async {
    final s = InMemoryBacklogStore();
    expect(await s.read(), isEmpty);
    await s.write([fixAt(0, 0, 0)]);
    expect(await s.read(), [fixAt(0, 0, 0)]);
  });
}
