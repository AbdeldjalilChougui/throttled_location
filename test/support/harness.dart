import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:throttled_location/throttled_location.dart';

import 'tracks.dart';

/// A source whose fixes the test pushes by hand.
class ManualSource implements LocationSource {
  final controller = StreamController<LocationFix>.broadcast();
  int listens = 0;

  bool get hasListener => controller.hasListener;

  @override
  Stream<LocationFix> watch() {
    listens++;
    return controller.stream;
  }

  void add(LocationFix fix) => controller.add(fix);
}

/// One call to the sink, with the fake time it happened at.
typedef SinkCall = ({int atSecond, List<LocationFix> batch});

/// A sink that records calls. [handler] decides each outcome.
class RecordingSink implements LocationSink {
  RecordingSink(this.clock);

  final DateTime Function() clock;
  final calls = <SinkCall>[];
  int inFlight = 0;
  int maxInFlight = 0;
  Future<SinkResult> Function(List<LocationFix> batch) handler =
      (_) async => const SinkResult.accepted();

  List<LocationFix> get sentFixes => [for (final c in calls) ...c.batch];

  @override
  Future<SinkResult> send(List<LocationFix> batch) async {
    calls.add((atSecond: clock().difference(t0).inSeconds, batch: batch));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return await handler(batch);
    } finally {
      inFlight--;
    }
  }
}

/// Emits each fix of [track] when the fake clock reaches its timestamp.
void play(FakeAsync async, ManualSource source, Iterable<LocationFix> track,
    {void Function(LocationFix fix)? before}) {
  for (final f in track) {
    final wait = f.timestamp.difference(async.getClock(t0).now());
    if (wait > Duration.zero) async.elapse(wait);
    before?.call(f);
    source.add(f);
    async.flushMicrotasks();
  }
}
