/// Battery- and data-friendly location reporting policy: decide when to
/// send a position, what to send, and what to do while offline.
///
/// Platform-independent. The file-backed backlog store lives in
/// `package:throttled_location/io.dart`.
library;

export 'src/backlog.dart' show BacklogOverflow, BacklogPolicy;
export 'src/geo.dart';
export 'src/location_fix.dart';
export 'src/policy.dart';
export 'src/policy_engine.dart';
export 'src/reasons.dart';
export 'src/reporter.dart';
export 'src/sink.dart';
export 'src/source.dart';
export 'src/stats.dart';
export 'src/store.dart';
