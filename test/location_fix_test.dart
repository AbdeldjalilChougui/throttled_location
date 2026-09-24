import 'package:test/test.dart';
import 'package:throttled_location/throttled_location.dart';

void main() {
  final t = DateTime.utc(2026, 9, 24, 8, 30, 15, 250);

  test('round-trips through JSON with every field', () {
    final fix = LocationFix(
      lat: 36.7538,
      lon: 3.0588,
      accuracy: 4.5,
      speed: 12.25,
      heading: 271.5,
      altitude: 23.0,
      timestamp: t,
      isMocked: true,
    );
    final back = LocationFix.fromJson(fix.toJson());
    expect(back, fix);
    expect(back.hashCode, fix.hashCode);
    expect(back.timestamp.isUtc, isTrue);
  });

  test('optional fields are omitted from JSON and default on read', () {
    final fix = LocationFix(lat: 1, lon: 2, timestamp: t);
    final json = fix.toJson();
    expect(json.keys, unorderedEquals(['lat', 'lon', 'timestamp']));
    final back = LocationFix.fromJson(json);
    expect(back.accuracy, isNull);
    expect(back.speed, isNull);
    expect(back.heading, isNull);
    expect(back.altitude, isNull);
    expect(back.isMocked, isFalse);
  });

  test('timestamp is serialised as UTC ISO-8601', () {
    final local = DateTime(2026, 1, 2, 3, 4, 5);
    final json = LocationFix(lat: 0, lon: 0, timestamp: local).toJson();
    expect(json['timestamp'], local.toUtc().toIso8601String());
  });

  test('fromJson rejects a payload without coordinates', () {
    expect(
      () => LocationFix.fromJson({'timestamp': t.toIso8601String()}),
      throwsFormatException,
    );
  });

  test('copyWith replaces only the given fields', () {
    final fix = LocationFix(lat: 1, lon: 2, speed: 3, timestamp: t);
    final moved = fix.copyWith(lat: 5);
    expect(moved.lat, 5);
    expect(moved.lon, 2);
    expect(moved.speed, 3);
    expect(moved.timestamp, t);
  });

  test('rejects out-of-range coordinates', () {
    expect(
        () => LocationFix(lat: 91, lon: 0, timestamp: t), throwsArgumentError);
    expect(
        () => LocationFix(lat: 0, lon: 181, timestamp: t), throwsArgumentError);
  });
}
