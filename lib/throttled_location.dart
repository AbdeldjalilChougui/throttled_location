/// Battery- and data-friendly location reporting policy: decide when to
/// send a position, what to send, and what to do while offline.
///
/// Platform-independent. The file-backed backlog store lives in
/// `package:throttled_location/io.dart`.
library;

export 'src/backlog.dart' show BacklogOverflow, BacklogPolicy;
export 'src/geo.dart';
export 'src/location_fix.dart';
export 'src/reasons.dart';
