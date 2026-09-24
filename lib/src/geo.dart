import 'dart:math' as math;

import 'location_fix.dart';

/// Mean Earth radius in metres (IUGG mean radius R1 = 6 371 008.8 m).
const double earthRadiusMeters = 6371008.8;

double _rad(double deg) => deg * math.pi / 180;

/// Great-circle distance in metres between two points, by the Haversine
/// formula on a sphere of radius [earthRadiusMeters].
///
/// The spherical model differs from the WGS-84 ellipsoid by up to about
/// 0.5%, which is far below GPS noise at the distances this package uses.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final a = s1 * s1 + math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * s2 * s2;
  return 2 * earthRadiusMeters * math.asin(math.min(1, math.sqrt(a)));
}

/// Haversine distance in metres between two fixes.
double distanceBetween(LocationFix a, LocationFix b) =>
    haversineMeters(a.lat, a.lon, b.lat, b.lon);

/// Initial great-circle bearing from point 1 to point 2, in degrees
/// clockwise from north, in `[0, 360)`.
double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dl = _rad(lon2 - lon1);
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  final deg = math.atan2(y, x) * 180 / math.pi;
  return (deg + 360) % 360;
}

/// Smallest angle in degrees between two headings, in `[0, 180]`.
double headingDelta(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}
