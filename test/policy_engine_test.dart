import 'package:test/test.dart';
import 'package:throttled_location/throttled_location.dart';

import 'support/tracks.dart';

/// Feeds [track] to [engine] using each fix's timestamp as "now" and
/// returns the decisions alongside their fixes.
List<(LocationFix, PolicyDecision)> run(
        ReportingPolicyEngine engine, Iterable<LocationFix> track) =>
    [for (final f in track) (f, engine.evaluate(f, f.timestamp))];

List<(LocationFix, SendReason)> sends(
        List<(LocationFix, PolicyDecision)> decisions) =>
    [
      for (final (f, d) in decisions)
        if (d case SendDecision(:final reason)) (f, reason),
    ];

Map<DropReason, int> drops(List<(LocationFix, PolicyDecision)> decisions) {
  final out = <DropReason, int>{};
  for (final (_, d) in decisions) {
    if (d case DropDecision(:final reason))
      out[reason] = (out[reason] ?? 0) + 1;
  }
  return out;
}

List<int> gaps(List<(LocationFix, SendReason)> s) =>
    [for (var i = 1; i < s.length; i++) sec(s[i].$1) - sec(s[i - 1].$1)];

void main() {
  group('ReportingPolicy', () {
    test('picks the band for the speed', () {
      const p = ReportingPolicy();
      expect(p.intervalForSpeed(0), const Duration(seconds: 30));
      expect(p.intervalForSpeed(1), const Duration(seconds: 30));
      expect(p.intervalForSpeed(5), const Duration(seconds: 15));
      expect(p.intervalForSpeed(10), const Duration(seconds: 10));
      expect(p.intervalForSpeed(30), const Duration(seconds: 5));
    });

    test('without bands the base interval is used', () {
      const p =
          ReportingPolicy(speedBands: null, interval: Duration(seconds: 12));
      expect(p.intervalForSpeed(40), const Duration(seconds: 12));
    });
  });

  group('first fix', () {
    test('is sent immediately', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final d = e.evaluate(fixAt(0, 0, 0), t0);
      expect(d, isA<SendDecision>());
      expect((d as SendDecision).reason, SendReason.first);
      expect(e.lastSent, isNotNull);
    });

    test('reset() makes the next valid fix "first" again', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      e.evaluate(fixAt(0, 0, 0), t0);
      e.reset();
      final d =
          e.evaluate(fixAt(0, 0, 1000), t0.add(const Duration(seconds: 1)));
      expect((d as SendDecision).reason, SendReason.first);
    });
  });

  group('stationary scenario', () {
    test('20 min parked: first send, then only heartbeats every 5 min', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final d = run(e, stationaryTrack(const Duration(minutes: 20)));
      final s = sends(d);
      expect(s.first.$2, SendReason.first);
      expect(s.skip(1).map((x) => x.$2), everyElement(SendReason.heartbeat));
      expect(s.skip(1).map((x) => sec(x.$1)), [300, 600, 900]);
      expect(e.isStationary, isTrue);
      expect(drops(d), isEmpty);
    });

    test('becomes stationary after StationaryDetector.after', () {
      final e = ReportingPolicyEngine(const ReportingPolicy(
          stationary: StationaryDetector(after: Duration(minutes: 2))));
      final track = stationaryTrack(const Duration(minutes: 3));
      for (final f in track) {
        e.evaluate(f, f.timestamp);
        expect(e.isStationary, sec(f) >= 120, reason: 'at ${sec(f)} s');
      }
    });

    test('leaving the radius is sent at once as resumedMoving', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final parked = stationaryTrack(const Duration(minutes: 4));
      final drive = straightTrack(const Duration(seconds: 20),
          speed: 10, startSecond: 240);
      final s = sends(run(e, [...parked, ...drive]));
      final resumed = s.firstWhere((x) => x.$2 == SendReason.resumedMoving);
      // Radius 30 m at 10 m/s from x = 0: the fix at x = 40 (t = 244 s)
      // is the first beyond the radius from the anchor.
      expect(sec(resumed.$1), inInclusiveRange(243, 244));
      expect(e.isStationary, isFalse);
    });

    test('without a detector, GPS drift below minDistance is notMoved', () {
      final e = ReportingPolicyEngine(
          const ReportingPolicy(stationary: null, heartbeatInterval: null));
      final d = run(e, stationaryTrack(const Duration(minutes: 5)));
      expect(sends(d), hasLength(1));
      expect(
          d.where((x) =>
              x.$2 is SkipDecision &&
              (x.$2 as SkipDecision).reason == SkipReason.notMoved),
          isNotEmpty);
    });
  });

  group('highway drive', () {
    test('30 m/s: one send every 5 s, ~150 m apart', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final track = straightTrack(const Duration(minutes: 10));
      final s = sends(run(e, track));
      expect(gaps(s), everyElement(5));
      expect(s.length, 120);
      for (var i = 1; i < s.length; i++) {
        expect(distanceBetween(s[i - 1].$1, s[i].$1), closeTo(150, 0.5));
      }
      // Five-fold fewer requests than sending every fix.
      expect(s.length * 5, track.length);
    });

    test('speed is derived from positions when the fix has none', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final track = [
        for (final f in straightTrack(const Duration(minutes: 1)))
          LocationFix(lat: f.lat, lon: f.lon, timestamp: f.timestamp),
      ];
      final s = sends(run(e, track));
      expect(gaps(s).skip(1), everyElement(5));
      expect(e.currentSpeed, closeTo(30, 0.1));
    });
  });

  group('city drive', () {
    test('10 m/s cadence plus an early send at each corner', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final s = sends(run(e, legTrack(cityLegs)));
      final turns = [
        for (final x in s)
          if (x.$2 == SendReason.turn) sec(x.$1),
      ];
      expect(turns, [35, 60, 75]);
      expect(gaps(s), everyElement(greaterThanOrEqualTo(5)));
      expect(gaps(s), everyElement(lessThanOrEqualTo(10)));
    });

    test('turns are ignored below turnMinSpeedMps', () {
      final e = ReportingPolicyEngine(
          const ReportingPolicy(turnMinSpeedMps: 20, stationary: null));
      final s = sends(run(e, legTrack(cityLegs)));
      expect(s.map((x) => x.$2), isNot(contains(SendReason.turn)));
    });

    test('turn detection can be disabled', () {
      final e = ReportingPolicyEngine(const ReportingPolicy(turnDegrees: null));
      final s = sends(run(e, legTrack(cityLegs)));
      expect(s.map((x) => x.$2), isNot(contains(SendReason.turn)));
    });

    test('course is derived from positions when heading is missing', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final track = [
        for (final f in legTrack(cityLegs))
          LocationFix(
              lat: f.lat, lon: f.lon, timestamp: f.timestamp, speed: 10),
      ];
      final turns = [
        for (final x in sends(run(e, track)))
          if (x.$2 == SendReason.turn) sec(x.$1),
      ];
      // The derived course lags one fix behind the reported heading.
      expect(turns, [36, 61, 76]);
    });
  });

  group('GPS jump', () {
    test('a single 2 km spike is dropped and never sent', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      final track = straightTrack(const Duration(minutes: 2), speed: 10);
      final spike = track[60];
      final jumped = [
        ...track.take(60),
        fixAt(600, 2000, 60000, speed: 10, heading: 90),
        ...track.skip(61),
      ];
      final d = run(e, jumped);
      expect(drops(d), {DropReason.implausibleJump: 1});
      expect(sends(d).map((x) => x.$1.lat),
          everyElement(lessThan(spike.lat + 0.001)));
      expect(e.lastValid, track.last);
    });

    test('a real relocation is accepted after resyncAfter consistent fixes',
        () {
      final e = ReportingPolicyEngine(const ReportingPolicy(
          jitter: JitterFilter(maxSpeedMps: 70, resyncAfter: 3)));
      final before = straightTrack(const Duration(seconds: 30), speed: 10);
      final after = straightTrack(const Duration(seconds: 30),
          speed: 10, startSecond: 30, startX: 5000);
      final d = run(e, [...before, ...after]);
      expect(drops(d), {DropReason.implausibleJump: 2});
      expect(e.lastValid, after.last);
    });

    test('accuracy radii are subtracted before judging speed', () {
      final e = ReportingPolicyEngine(const ReportingPolicy(
          maxAccuracyMeters: null, jitter: JitterFilter(maxSpeedMps: 50)));
      e.evaluate(fixAt(0, 0, 0, accuracy: 40), t0);
      // 100 m in 1 s is 100 m/s raw, but 20 m/s once both 40 m radii
      // are taken off.
      final d = e.evaluate(fixAt(100, 0, 1000, accuracy: 40),
          t0.add(const Duration(seconds: 1)));
      expect(d, isNot(isA<DropDecision>()));
    });

    test('an out-of-order or duplicate fix is dropped', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      e.evaluate(fixAt(0, 0, 5000), t0);
      expect((e.evaluate(fixAt(1, 0, 5000), t0) as DropDecision).reason,
          DropReason.outOfOrder);
      expect((e.evaluate(fixAt(1, 0, 4000), t0) as DropDecision).reason,
          DropReason.outOfOrder);
    });
  });

  group('accuracy and mock filters', () {
    test('fixes worse than maxAccuracyMeters are dropped', () {
      final e =
          ReportingPolicyEngine(const ReportingPolicy(maxAccuracyMeters: 50));
      final track = [
        for (final f in straightTrack(const Duration(minutes: 1)))
          sec(f) % 3 == 1 ? f.copyWith(accuracy: 120) : f,
      ];
      final d = run(e, track);
      expect(drops(d), {DropReason.inaccurate: 20});
      expect(sends(d).map((x) => x.$1.accuracy), everyElement(5));
    });

    test('a fix without accuracy passes the filter', () {
      final e =
          ReportingPolicyEngine(const ReportingPolicy(maxAccuracyMeters: 10));
      expect(
          e.evaluate(fixAt(0, 0, 0, accuracy: null), t0), isA<SendDecision>());
    });

    test('mocked fixes are dropped only when rejectMocked is set', () {
      final strict =
          ReportingPolicyEngine(const ReportingPolicy(rejectMocked: true));
      final lax = ReportingPolicyEngine(const ReportingPolicy());
      final f = fixAt(0, 0, 0, isMocked: true);
      expect(
          (strict.evaluate(f, t0) as DropDecision).reason, DropReason.mocked);
      expect(lax.evaluate(f, t0), isA<SendDecision>());
    });
  });

  group('minimum interval and distance', () {
    test('nothing is sent sooner than minInterval, even a turn', () {
      final e = ReportingPolicyEngine(const ReportingPolicy(
          minInterval: Duration(seconds: 8),
          speedBands: null,
          interval: Duration(seconds: 8)));
      final s = sends(run(e, legTrack(cityLegs)));
      expect(gaps(s), everyElement(greaterThanOrEqualTo(8)));
    });

    test('an interval send needs minDistanceMeters of movement', () {
      final e = ReportingPolicyEngine(const ReportingPolicy(
          minDistanceMeters: 200, stationary: null, heartbeatInterval: null));
      // 30 m/s with a 5 s band = 150 m per interval: every other tick
      // goes out, so sends are 10 s apart.
      final s = sends(run(e, straightTrack(const Duration(minutes: 1))));
      expect(gaps(s), everyElement(7));
    });
  });

  group('server interval override', () {
    test('replaces the speed band', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      e.setServerInterval(const Duration(seconds: 60));
      expect(e.serverInterval, const Duration(seconds: 60));
      final s = sends(run(e, straightTrack(const Duration(minutes: 5))));
      expect(gaps(s), everyElement(60));
    });

    test('is clamped to [minInterval, maxInterval]', () {
      final e = ReportingPolicyEngine(const ReportingPolicy(
          minInterval: Duration(seconds: 5),
          maxInterval: Duration(minutes: 2)));
      e.setServerInterval(const Duration(seconds: 1));
      expect(e.serverInterval, const Duration(seconds: 5));
      e.setServerInterval(const Duration(hours: 1));
      expect(e.serverInterval, const Duration(minutes: 2));
      e.setServerInterval(Duration.zero);
      expect(e.serverInterval, const Duration(seconds: 5));
    });

    test('null clears it and the speed band applies again', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      e.setServerInterval(const Duration(seconds: 60));
      e.setServerInterval(null);
      expect(e.serverInterval, isNull);
      final s = sends(run(e, straightTrack(const Duration(minutes: 1))));
      expect(gaps(s), everyElement(5));
    });

    test('currentInterval reports the effective value', () {
      final e = ReportingPolicyEngine(const ReportingPolicy());
      run(e, straightTrack(const Duration(seconds: 3)));
      expect(e.currentInterval, const Duration(seconds: 5));
      e.setServerInterval(const Duration(seconds: 42));
      expect(e.currentInterval, const Duration(seconds: 42));
    });
  });

  group('heartbeat()', () {
    test('re-sends the latest valid fix once heartbeatInterval has passed', () {
      final e = ReportingPolicyEngine(
          const ReportingPolicy(heartbeatInterval: Duration(minutes: 5)));
      final f = fixAt(0, 0, 0);
      e.evaluate(f, t0);
      expect(e.heartbeat(t0.add(const Duration(minutes: 4))), isNull);
      expect(e.nextHeartbeatAt, t0.add(const Duration(minutes: 5)));
      expect(e.heartbeat(t0.add(const Duration(minutes: 5))), f);
      expect(e.nextHeartbeatAt, t0.add(const Duration(minutes: 10)));
    });

    test('is null before any fix or when disabled', () {
      expect(
          ReportingPolicyEngine(const ReportingPolicy()).heartbeat(t0), isNull);
      final e =
          ReportingPolicyEngine(const ReportingPolicy(heartbeatInterval: null));
      e.evaluate(fixAt(0, 0, 0), t0);
      expect(e.heartbeat(t0.add(const Duration(days: 1))), isNull);
      expect(e.nextHeartbeatAt, isNull);
    });
  });
}
