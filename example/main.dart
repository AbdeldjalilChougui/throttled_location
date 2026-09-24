// Replays a short synthetic drive through the reporter and prints what
// would be sent. Run with: dart run example/main.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:throttled_location/throttled_location.dart';

Future<void> main() async {
  // A fake GPS: 1 fix per second, driving east at 25 m/s (90 km/h).
  final start = DateTime.now().toUtc();
  const metersPerDegree = 2 * math.pi * earthRadiusMeters / 360;
  var i = 0;
  final source = PollingLocationSource(
    () async {
      final t = i++;
      return LocationFix(
        lat: 36.75,
        lon: 3.06 +
            25.0 * t / (metersPerDegree * math.cos(36.75 * math.pi / 180)),
        speed: 25,
        heading: 90,
        accuracy: 5,
        timestamp: start.add(Duration(seconds: t)),
      );
    },
    period: const Duration(seconds: 1),
  );

  // Stand-in for an HTTP call. A real server could return a
  // `next_update_seconds` field and pass it back as nextInterval.
  final sink = LocationSink.fromFunction((batch) async {
    for (final f in batch) {
      print('POST ${f.lat.toStringAsFixed(5)}, ${f.lon.toStringAsFixed(5)}');
    }
    return const SinkResult.accepted();
  });

  final reporter = ThrottledLocationReporter(source: source, sink: sink);
  await reporter.start();
  await Future<void>.delayed(const Duration(seconds: 16));
  await reporter.stop();
  final s = reporter.stats;
  print('sent ${s.sent}, skipped ${s.skipped}, dropped ${s.dropped}');
}
