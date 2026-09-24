// Synthetic GPS tracks for tests. Positions are generated on a local flat
// grid (metres east/north of an origin) and converted with the spherical
// degree length used by the Haversine code, so distances are predictable.
import 'dart:math' as math;

import 'package:throttled_location/throttled_location.dart';

final t0 = DateTime.utc(2026, 9, 24, 8);
const originLat = 36.75;
const originLon = 3.06;
const metersPerDegree = 2 * math.pi * earthRadiusMeters / 360;

/// A fix [x] metres east and [y] metres north of the origin, [ms]
/// milliseconds after [t0].
LocationFix fixAt(
  double x,
  double y,
  int ms, {
  double? speed,
  double? heading,
  double? accuracy = 5,
  bool isMocked = false,
}) =>
    LocationFix(
      lat: originLat + y / metersPerDegree,
      lon: originLon +
          x / (metersPerDegree * math.cos(originLat * math.pi / 180)),
      timestamp: t0.add(Duration(milliseconds: ms)),
      speed: speed,
      heading: heading,
      accuracy: accuracy,
      isMocked: isMocked,
    );

/// Seconds between [t0] and the fix.
int sec(LocationFix f) => f.timestamp.difference(t0).inSeconds;

/// Parked courier: 1 Hz fixes with up to ±3 m of deterministic noise per
/// axis and a near-zero reported speed.
List<LocationFix> stationaryTrack(Duration length, {int startSecond = 0}) => [
      for (var i = 0; i < length.inSeconds; i++)
        fixAt(3 * math.sin(i * 1.7), 3 * math.cos(i * 2.3),
            (startSecond + i) * 1000,
            speed: 0.2, accuracy: 8),
    ];

/// Straight drive due east at [speed] m/s, 1 Hz.
List<LocationFix> straightTrack(
  Duration length, {
  double speed = 30,
  int startSecond = 0,
  double startX = 0,
}) =>
    [
      for (var i = 0; i < length.inSeconds; i++)
        fixAt(startX + speed * i, 0, (startSecond + i) * 1000,
            speed: speed, heading: 90),
    ];

/// One leg of a drive: heading in degrees and duration in seconds.
typedef Leg = ({double heading, int seconds});

/// City drive at 10 m/s: east 35 s, north 25 s, west 15 s, north 25 s.
/// Corners are reached at t = 35, 60 and 75 s.
const cityLegs = <Leg>[
  (heading: 90, seconds: 35),
  (heading: 0, seconds: 25),
  (heading: 270, seconds: 15),
  (heading: 0, seconds: 25),
];

/// Drives [legs] at [speed] m/s with one fix per second. Each fix carries
/// the heading of the leg it is about to drive.
List<LocationFix> legTrack(List<Leg> legs, {double speed = 10}) {
  final out = <LocationFix>[];
  var x = 0.0, y = 0.0, t = 0;
  for (final leg in legs) {
    final rad = leg.heading * math.pi / 180;
    for (var i = 0; i < leg.seconds; i++) {
      out.add(fixAt(x, y, t * 1000, speed: speed, heading: leg.heading));
      x += speed * math.sin(rad);
      y += speed * math.cos(rad);
      t++;
    }
  }
  out.add(fixAt(x, y, t * 1000, speed: speed, heading: legs.last.heading));
  return out;
}
