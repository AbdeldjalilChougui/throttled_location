import 'dart:async';

import 'location_fix.dart';

/// Where fixes come from. Implement it over any location plugin.
///
/// The reporter calls [watch] on `start` and `resume` and cancels the
/// subscription on `pause` and `stop`, so a plugin can switch the GPS off
/// while nobody listens.
abstract interface class LocationSource {
  /// Wraps a function that opens a fresh fix stream on every [watch].
  factory LocationSource.fromStream(Stream<LocationFix> Function() open) =
      _FunctionSource;

  /// Opens a stream of fixes. Errors on the stream are ignored by the
  /// reporter.
  Stream<LocationFix> watch();
}

class _FunctionSource implements LocationSource {
  _FunctionSource(this._open);

  final Stream<LocationFix> Function() _open;

  @override
  Stream<LocationFix> watch() => _open();
}

/// A [LocationSource] that asks for one fix at a time on a fixed period,
/// for plugins that only offer a "current position" call.
///
/// Reads never overlap: a tick that finds the previous read still running
/// is skipped. A failed read is forwarded as a stream error.
class PollingLocationSource implements LocationSource {
  /// Calls [read] once on listen and then every [period].
  PollingLocationSource(this.read, {this.period = const Duration(seconds: 5)});

  /// Reads one fix.
  final Future<LocationFix> Function() read;

  /// Time between reads.
  final Duration period;

  @override
  Stream<LocationFix> watch() {
    Timer? timer;
    var busy = false;
    var closed = false;
    late final StreamController<LocationFix> controller;

    Future<void> tick() async {
      if (busy || closed) return;
      busy = true;
      try {
        final fix = await read();
        if (!closed) controller.add(fix);
      } catch (e, st) {
        if (!closed) controller.addError(e, st);
      } finally {
        busy = false;
      }
    }

    controller = StreamController<LocationFix>(
      onListen: () {
        timer = Timer.periodic(period, (_) => tick());
        tick();
      },
      onCancel: () {
        closed = true;
        timer?.cancel();
      },
    );
    return controller.stream;
  }
}
