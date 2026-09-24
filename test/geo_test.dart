import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:throttled_location/throttled_location.dart';

void main() {
  group('haversineMeters', () {
    test('is zero for the same point', () {
      expect(haversineMeters(36.75, 3.05, 36.75, 3.05), 0);
    });

    test('one degree along the equator is 2*pi*R/360', () {
      const expected = 2 * math.pi * earthRadiusMeters / 360;
      expect(haversineMeters(0, 0, 0, 1), closeTo(expected, 1e-6));
    });

    test('one degree of latitude along a meridian is 2*pi*R/360', () {
      const expected = 2 * math.pi * earthRadiusMeters / 360;
      expect(haversineMeters(10, 20, 11, 20), closeTo(expected, 1e-6));
    });

    test('pole to pole is half a great circle', () {
      expect(haversineMeters(90, 0, -90, 0),
          closeTo(math.pi * earthRadiusMeters, 1e-3));
    });

    test('is symmetric', () {
      expect(haversineMeters(36.7, 3.0, 35.6, -0.6),
          closeTo(haversineMeters(35.6, -0.6, 36.7, 3.0), 1e-9));
    });
  });

  group('bearingDegrees', () {
    test('cardinal directions', () {
      expect(bearingDegrees(0, 0, 1, 0), closeTo(0, 1e-9));
      expect(bearingDegrees(0, 0, 0, 1), closeTo(90, 1e-9));
      expect(bearingDegrees(1, 0, 0, 0), closeTo(180, 1e-9));
      expect(bearingDegrees(0, 1, 0, 0), closeTo(270, 1e-9));
    });
  });

  group('headingDelta', () {
    test('takes the short way round', () {
      expect(headingDelta(350, 10), 20);
      expect(headingDelta(10, 350), 20);
      expect(headingDelta(0, 180), 180);
      expect(headingDelta(90, 90), 0);
      expect(headingDelta(720 + 45, 0), 45);
    });
  });

  test('distanceBetween works on fixes', () {
    final t = DateTime.utc(2026);
    final a = LocationFix(lat: 0, lon: 0, timestamp: t);
    final b = LocationFix(lat: 0, lon: 1, timestamp: t);
    expect(distanceBetween(a, b), closeTo(haversineMeters(0, 0, 0, 1), 1e-9));
  });
}
