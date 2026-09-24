import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:throttled_location/throttled_location.dart';

import 'support/harness.dart';
import 'support/tracks.dart';

class Rig {
  Rig(
    this.async, {
    ReportingPolicy policy = const ReportingPolicy(),
    BacklogPolicy? backlog,
    BacklogStore? store,
    Stream<bool>? connectivity,
    bool initiallyOnline = true,
    int batchSize = 50,
    RetryBackoff retry = const RetryBackoff(),
  }) {
    DateTime now() => async.getClock(t0).now();
    sink = RecordingSink(now);
    reporter = ThrottledLocationReporter(
      source: source,
      sink: sink,
      policy: policy,
      backlog: backlog,
      store: store,
      connectivity: connectivity,
      initiallyOnline: initiallyOnline,
      batchSize: batchSize,
      retry: retry,
      clock: now,
    );
    reporter.statsStream.listen(emitted.add);
  }

  final FakeAsync async;
  final source = ManualSource();
  late final RecordingSink sink;
  late final ThrottledLocationReporter reporter;
  final emitted = <ReporterStats>[];

  void start() {
    reporter.start();
    async.flushMicrotasks();
  }

  void stop({bool flush = true}) {
    reporter.stop(flush: flush);
    async.flushMicrotasks();
  }

  List<int> callSeconds() => [for (final c in sink.calls) c.atSecond];
}

void main() {
  group('lifecycle', () {
    test('is inert until start()', () {
      fakeAsync((async) {
        final rig = Rig(async);
        async.elapse(const Duration(minutes: 1));
        expect(rig.source.listens, 0);
        expect(rig.reporter.state, ReporterState.idle);
        expect(rig.sink.calls, isEmpty);
      });
    });

    test('start() listens and sends the first fix at once', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        expect(rig.reporter.state, ReporterState.running);
        expect(rig.source.hasListener, isTrue);
        rig.source.add(fixAt(0, 0, 0));
        async.flushMicrotasks();
        expect(rig.sink.calls, hasLength(1));
        expect(rig.reporter.stats.sent, 1);
        expect(rig.reporter.stats.queued, 0);
        rig.stop();
      });
    });

    test('start() twice throws', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        expect(rig.reporter.start, throwsStateError);
        rig.stop();
      });
    });

    test('pause() releases the source; resume() re-listens and sends at once',
        () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        play(async, rig.source, straightTrack(const Duration(seconds: 20)));
        final before = rig.sink.calls.length;
        rig.reporter.pause();
        expect(rig.reporter.state, ReporterState.paused);
        expect(rig.source.hasListener, isFalse);

        async.elapse(const Duration(minutes: 10));
        expect(rig.sink.calls.length, before,
            reason: 'no heartbeat while paused');

        rig.reporter.resume();
        expect(rig.source.hasListener, isTrue);
        rig.source.add(fixAt(0, 0, 10 * 60 * 1000 + 21000, speed: 30));
        async.flushMicrotasks();
        expect(rig.sink.calls.length, before + 1);
        rig.stop();
      });
    });

    test('queued points keep flowing while paused', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig = Rig(async, connectivity: online.stream)..start();
        online.add(false);
        play(async, rig.source, straightTrack(const Duration(seconds: 30)));
        expect(rig.reporter.stats.queued, greaterThan(0));
        rig.reporter.pause();
        online.add(true);
        async.flushMicrotasks();
        expect(rig.reporter.stats.queued, 0);
        rig.stop();
      });
    });

    test('stop() flushes, closes the stats stream and is final', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        var done = false;
        rig.reporter.statsStream.listen(null, onDone: () => done = true);
        rig.stop();
        expect(rig.reporter.state, ReporterState.stopped);
        expect(done, isTrue);
        expect(rig.source.hasListener, isFalse);
        expect(rig.reporter.start, throwsStateError);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('stop() waits for the in-flight send', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        final gate = Completer<SinkResult>();
        rig.sink.handler = (_) => gate.future;
        rig.source.add(fixAt(0, 0, 0));
        async.flushMicrotasks();
        var stopped = false;
        rig.reporter.stop().then((_) => stopped = true);
        async.flushMicrotasks();
        expect(stopped, isFalse);
        gate.complete(const SinkResult.accepted());
        async.flushMicrotasks();
        expect(stopped, isTrue);
        expect(rig.reporter.stats.sent, 1);
      });
    });
  });

  group('scenarios', () {
    test('highway: one request every 5 s instead of every second', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        play(async, rig.source, straightTrack(const Duration(minutes: 2)));
        expect(rig.callSeconds(), [for (var s = 0; s < 120; s += 5) s]);
        expect(rig.sink.calls.every((c) => c.batch.length == 1), isTrue);
        expect(rig.reporter.stats.skipped, 120 - 24);
        rig.stop();
      });
    });

    test('city drive: corners go out early as turns', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        play(async, rig.source, legTrack(cityLegs));
        expect(
            rig.callSeconds(), [0, 10, 20, 30, 35, 45, 55, 60, 70, 75, 85, 95]);
        rig.stop();
      });
    });

    test('stationary: heartbeats only, driven by a timer when GPS is silent',
        () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        play(async, rig.source, stationaryTrack(const Duration(minutes: 3)));
        expect(rig.reporter.stats.isStationary, isTrue);
        // The OS stops sending fixes while parked.
        async.elapse(const Duration(minutes: 13));
        expect(rig.callSeconds(), [0, 300, 600, 900]);
        final hb = rig.sink.calls.last.batch.single;
        expect(hb, rig.reporter.engine.lastValid);
        rig.stop();
      });
    });

    test('GPS jump: the spike is counted as dropped and never sent', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        final track = straightTrack(const Duration(minutes: 1), speed: 10);
        play(async, rig.source, [
          ...track.take(30),
          fixAt(300, 3000, 30000, speed: 10, heading: 90),
          ...track.skip(31),
        ]);
        expect(rig.reporter.stats.droppedByReason,
            {DropReason.implausibleJump: 1});
        expect(rig.reporter.stats.dropped, 1);
        expect(rig.sink.sentFixes.map((f) => f.lat),
            everyElement(closeTo(originLat, 1e-9)));
        rig.stop();
      });
    });

    test('tunnel: queue while offline, replay oldest-first in batches', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig = Rig(async, connectivity: online.stream, batchSize: 10)
          ..start();
        var queuedAtReconnect = -1;
        play(async, rig.source, straightTrack(const Duration(minutes: 5)),
            before: (f) {
          if (sec(f) == 60) online.add(false);
          if (sec(f) == 240) {
            queuedAtReconnect = rig.reporter.stats.queued;
            online.add(true);
          }
        });
        // Nothing is attempted inside the tunnel.
        expect(rig.callSeconds().where((s) => s > 60 && s < 240), isEmpty);
        // 36 points were queued (every 5 s from 60 to 235 s) and replayed
        // at 240 s in batches of 10, oldest first, followed by the live fix.
        final replay = rig.sink.calls.where((c) => c.atSecond == 240).toList();
        expect(replay.map((c) => c.batch.length), [10, 10, 10, 7]);
        final sent = rig.sink.sentFixes.map(sec).toList();
        expect(sent, [for (var s = 0; s < 300; s += 5) s]);
        expect(rig.reporter.stats.queued, 0);
        expect(rig.reporter.stats.dropped, 0);
        expect(queuedAtReconnect, 36);
        rig.stop();
      });
    });

    test('initiallyOnline: false queues until connectivity says true', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig =
            Rig(async, connectivity: online.stream, initiallyOnline: false)
              ..start();
        rig.source.add(fixAt(0, 0, 0));
        async.flushMicrotasks();
        expect(rig.sink.calls, isEmpty);
        expect(rig.reporter.stats.isOnline, isFalse);
        online.add(true);
        async.flushMicrotasks();
        expect(rig.sink.calls, hasLength(1));
        rig.stop();
      });
    });
  });

  group('backlog bounds in the reporter', () {
    void offlineFor(Rig rig, StreamController<bool> online, Duration d) {
      online.add(false);
      play(rig.async, rig.source, straightTrack(d));
    }

    test('drop-oldest keeps the newest maxCount points', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig = Rig(async,
            connectivity: online.stream, backlog: BacklogPolicy(maxCount: 10))
          ..start();
        offlineFor(rig, online, const Duration(minutes: 2)); // 24 points
        expect(rig.reporter.stats.queued, 10);
        expect(rig.reporter.stats.droppedByReason, {DropReason.overflow: 14});
        online.add(true);
        async.flushMicrotasks();
        expect(
            rig.sink.sentFixes.map(sec), [for (var s = 70; s < 120; s += 5) s]);
        rig.stop();
      });
    });

    test('downsampling keeps the start of the outage and the newest point', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig = Rig(async,
            connectivity: online.stream,
            backlog: BacklogPolicy(
                maxCount: 10,
                overflow: BacklogOverflow.downsample(keepEvery: 2)))
          ..start();
        offlineFor(rig, online, const Duration(minutes: 2));
        final dropped = rig.reporter.stats.droppedByReason;
        expect(dropped.keys, [DropReason.downsampled]);
        expect(rig.reporter.stats.queued + dropped.values.single, 24);
        online.add(true);
        async.flushMicrotasks();
        final sent = rig.sink.sentFixes.map(sec).toList();
        expect(sent.first, 0);
        expect(sent.last, 115);
        expect(sent, orderedEquals([...sent]..sort()));
        rig.stop();
      });
    });

    test('points older than maxAge are expired before replay', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig = Rig(async,
            connectivity: online.stream,
            backlog: BacklogPolicy(maxAge: const Duration(minutes: 1)))
          ..start();
        offlineFor(rig, online, const Duration(minutes: 3));
        online.add(true);
        async.flushMicrotasks();
        final sent = rig.sink.sentFixes.map(sec).toList();
        expect(sent.first, greaterThanOrEqualTo(179 - 60));
        expect(rig.reporter.stats.droppedByReason[DropReason.expired],
            greaterThan(0));
        rig.stop();
      });
    });
  });

  group('server interval', () {
    test('nextInterval from the sink sets the cadence', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        rig.sink.handler = (_) async =>
            const SinkResult.accepted(nextInterval: Duration(seconds: 20));
        play(async, rig.source, straightTrack(const Duration(minutes: 1)));
        expect(rig.callSeconds(), [0, 20, 40]);
        expect(rig.reporter.stats.interval, const Duration(seconds: 20));
        rig.stop();
      });
    });

    test('is clamped to the policy bounds', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        rig.sink.handler = (_) async =>
            const SinkResult.accepted(nextInterval: Duration(seconds: 1));
        play(async, rig.source, straightTrack(const Duration(seconds: 30)));
        expect(rig.callSeconds(), [0, 5, 10, 15, 20, 25]);
        rig.stop();
      });
    });

    test('a rejected batch is dropped, not retried, and can still pace', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        rig.sink.handler = (_) async =>
            const SinkResult.rejected(nextInterval: Duration(seconds: 30));
        play(async, rig.source, straightTrack(const Duration(minutes: 1)));
        expect(rig.callSeconds(), [0, 30]);
        expect(rig.reporter.stats.droppedByReason,
            {DropReason.rejectedByServer: 2});
        expect(rig.reporter.stats.sent, 0);
        expect(rig.reporter.stats.queued, 0);
        rig.stop();
      });
    });
  });

  group('in-flight guard and retry', () {
    test('sends never overlap; points queued meanwhile go in the next batch',
        () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        rig.sink.handler = (_) async {
          await Future<void>.delayed(const Duration(seconds: 12));
          return const SinkResult.accepted();
        };
        play(async, rig.source, straightTrack(const Duration(minutes: 1)));
        async.elapse(const Duration(minutes: 1));
        expect(rig.sink.maxInFlight, 1);
        expect(rig.callSeconds(), [0, 12, 24, 36, 48, 60]);
        expect(rig.sink.calls.map((c) => c.batch.length), [1, 2, 2, 3, 2, 2]);
        expect(
            rig.sink.sentFixes.map(sec), [for (var s = 0; s < 60; s += 5) s]);
        rig.stop();
      });
    });

    test('failures back off exponentially, then succeed', () {
      fakeAsync((async) {
        final rig = Rig(async,
            retry: const RetryBackoff(
                initial: Duration(seconds: 2), max: Duration(seconds: 60)))
          ..start();
        var failures = 3;
        rig.sink.handler = (_) async {
          if (failures-- > 0) throw Exception('HTTP 503');
          return const SinkResult.accepted();
        };
        rig.source.add(fixAt(0, 0, 0));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        expect(rig.callSeconds(), [0, 2, 6, 14]);
        expect(rig.reporter.stats.sent, 1);
        expect(rig.reporter.stats.consecutiveFailures, 0);
        rig.stop();
      });
    });

    test('new fixes do not bypass the backoff', () {
      fakeAsync((async) {
        final rig = Rig(async,
            retry: const RetryBackoff(initial: Duration(seconds: 20)))
          ..start();
        var fail = true;
        rig.sink.handler = (_) async {
          if (fail) {
            fail = false;
            throw Exception('down');
          }
          return const SinkResult.accepted();
        };
        play(async, rig.source, straightTrack(const Duration(seconds: 30)));
        // The retry at 20 s carries everything queued during the backoff.
        expect(rig.callSeconds(), [0, 20, 20, 25]);
        expect(rig.sink.calls[1].batch.map(sec), [0, 5, 10, 15]);
        rig.stop();
      });
    });

    test('reconnecting retries at once and resets the backoff', () {
      fakeAsync((async) {
        final online = StreamController<bool>();
        final rig = Rig(async,
            connectivity: online.stream,
            retry: const RetryBackoff(initial: Duration(minutes: 1)))
          ..start();
        var fail = true;
        rig.sink.handler = (_) async {
          if (fail) {
            fail = false;
            throw Exception('down');
          }
          return const SinkResult.accepted();
        };
        rig.source.add(fixAt(0, 0, 0));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        online
          ..add(false)
          ..add(true);
        async.flushMicrotasks();
        expect(rig.callSeconds(), [0, 3]);
        expect(rig.reporter.stats.consecutiveFailures, 0);
        rig.stop();
      });
    });

    test('RetryBackoff doubles up to its cap', () {
      const b = RetryBackoff(
          initial: Duration(seconds: 1), max: Duration(seconds: 10));
      expect([for (var i = 1; i <= 6; i++) b.delay(i).inSeconds],
          [1, 2, 4, 8, 10, 10]);
    });
  });

  group('persistence', () {
    test('the backlog survives a restart and is replayed first', () {
      fakeAsync((async) {
        final store = InMemoryBacklogStore();
        final online = StreamController<bool>();
        final first = Rig(async, store: store, connectivity: online.stream)
          ..start();
        online.add(false);
        play(async, first.source, straightTrack(const Duration(seconds: 30)));
        first.stop();
        expect(first.sink.calls, isEmpty);
        expect(store.fixes.map(sec), [0, 5, 10, 15, 20, 25]);

        final second = Rig(async, store: store)..start();
        expect(second.sink.sentFixes.map(sec), [0, 5, 10, 15, 20, 25]);
        expect(store.fixes, isEmpty);
        second.stop();
      });
    });

    test('stop(flush: false) keeps everything in the store', () {
      fakeAsync((async) {
        final store = InMemoryBacklogStore();
        final online = StreamController<bool>();
        final rig = Rig(async, store: store, connectivity: online.stream)
          ..start();
        online.add(false);
        play(async, rig.source, straightTrack(const Duration(seconds: 10)));
        rig.stop(flush: false);
        expect(rig.sink.calls, isEmpty);
        expect(store.fixes.map(sec), [0, 5]);
      });
    });
  });

  group('stats', () {
    test('stream reports sent, skipped, dropped and queued', () {
      fakeAsync((async) {
        final rig = Rig(async)..start();
        play(async, rig.source, [
          fixAt(0, 0, 0, speed: 30),
          fixAt(30, 0, 1000, speed: 30),
          fixAt(60, 0, 2000, speed: 30, accuracy: 500),
        ]);
        final s = rig.reporter.stats;
        expect(s.sent, 1);
        expect(s.skipped, 1);
        expect(s.dropped, 1);
        expect(s.droppedByReason, {DropReason.inaccurate: 1});
        expect(s.skippedByReason, {SkipReason.tooSoon: 1});
        expect(rig.emitted.last, s);
        rig.stop();
      });
    });
  });
}
