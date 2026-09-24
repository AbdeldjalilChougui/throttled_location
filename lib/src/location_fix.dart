/// One position sample from a location provider.
///
/// All units are SI: metres, metres per second and degrees. [heading] is
/// measured clockwise from true north in `[0, 360)`. Optional fields are
/// `null` when the provider does not report them.
class LocationFix {
  /// Creates a fix. Throws [ArgumentError] when [lat] or [lon] is out of
  /// range.
  LocationFix({
    required this.lat,
    required this.lon,
    required this.timestamp,
    this.accuracy,
    this.speed,
    this.heading,
    this.altitude,
    this.isMocked = false,
  }) {
    if (lat.isNaN || lat < -90 || lat > 90) {
      throw ArgumentError.value(lat, 'lat', 'must be within [-90, 90]');
    }
    if (lon.isNaN || lon < -180 || lon > 180) {
      throw ArgumentError.value(lon, 'lon', 'must be within [-180, 180]');
    }
  }

  /// Reads a fix written by [toJson]. Throws [FormatException] when a
  /// required field is missing or has the wrong type.
  factory LocationFix.fromJson(Map<String, Object?> json) {
    final lat = json['lat'];
    final lon = json['lon'];
    final ts = json['timestamp'];
    if (lat is! num || lon is! num || ts is! String) {
      throw FormatException('Invalid LocationFix JSON: $json');
    }
    final timestamp = DateTime.tryParse(ts);
    if (timestamp == null) {
      throw FormatException('Invalid LocationFix timestamp: $ts');
    }
    double? opt(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! num) throw FormatException('Invalid LocationFix $key: $v');
      return v.toDouble();
    }

    return LocationFix(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      timestamp: timestamp.toUtc(),
      accuracy: opt('accuracy'),
      speed: opt('speed'),
      heading: opt('heading'),
      altitude: opt('altitude'),
      isMocked: json['isMocked'] == true,
    );
  }

  /// Latitude in degrees, `[-90, 90]`.
  final double lat;

  /// Longitude in degrees, `[-180, 180]`.
  final double lon;

  /// Horizontal accuracy radius in metres (68% confidence on most
  /// platforms), or `null` when unknown.
  final double? accuracy;

  /// Ground speed in metres per second, or `null` when unknown.
  final double? speed;

  /// Course over ground in degrees clockwise from north, or `null`.
  final double? heading;

  /// Altitude in metres, or `null` when unknown.
  final double? altitude;

  /// When the provider produced this fix.
  final DateTime timestamp;

  /// Whether the platform flagged the fix as coming from a mock provider.
  final bool isMocked;

  /// Returns a copy with the given fields replaced.
  LocationFix copyWith({
    double? lat,
    double? lon,
    double? accuracy,
    double? speed,
    double? heading,
    double? altitude,
    DateTime? timestamp,
    bool? isMocked,
  }) =>
      LocationFix(
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        accuracy: accuracy ?? this.accuracy,
        speed: speed ?? this.speed,
        heading: heading ?? this.heading,
        altitude: altitude ?? this.altitude,
        timestamp: timestamp ?? this.timestamp,
        isMocked: isMocked ?? this.isMocked,
      );

  /// JSON form. `null` fields and a `false` [isMocked] are omitted; the
  /// timestamp is written as UTC ISO-8601.
  Map<String, Object?> toJson() => {
        'lat': lat,
        'lon': lon,
        if (accuracy != null) 'accuracy': accuracy,
        if (speed != null) 'speed': speed,
        if (heading != null) 'heading': heading,
        if (altitude != null) 'altitude': altitude,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (isMocked) 'isMocked': true,
      };

  @override
  bool operator ==(Object other) =>
      other is LocationFix &&
      other.lat == lat &&
      other.lon == lon &&
      other.accuracy == accuracy &&
      other.speed == speed &&
      other.heading == heading &&
      other.altitude == altitude &&
      other.timestamp.isAtSameMomentAs(timestamp) &&
      other.isMocked == isMocked;

  @override
  int get hashCode => Object.hash(lat, lon, accuracy, speed, heading, altitude,
      timestamp.microsecondsSinceEpoch, isMocked);

  @override
  String toString() => 'LocationFix($lat, $lon, acc: $accuracy, '
      'speed: $speed, heading: $heading, at: ${timestamp.toIso8601String()})';
}
