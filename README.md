# throttled_location

Battery- and data-friendly location reporting for delivery, courier and
ride-hailing apps. It decides **when** to send a position, **what** to send,
and **what to do while offline**. It works with any location plugin.

[![pub package](https://img.shields.io/pub/v/throttled_location.svg)](https://pub.dev/packages/throttled_location)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A phone can produce a fix every second. Sending every one wastes battery,
mobile data and server writes, and still leaves a gap on the map as soon as
the courier drives into a tunnel. This package puts a policy between the GPS
and your API. On a highway it sends one request every 5 s instead of every
second. While the courier is parked it sends a heartbeat every 5 minutes.
When the network drops it queues the trail and replays it in order once the
network comes back.

## Features

- **`LocationFix`** holds lat, lon, accuracy, speed, heading, altitude,
  timestamp and isMocked, with JSON round-trip.
- **`ThrottledLocationReporter`** takes fixes from a `LocationSource` and
  sends batches through a `LocationSink`.
- **Sending policy** (`ReportingPolicy`). Every rule can be configured, and
  they combine:
  - a minimum interval between sends (a hard floor);
  - an interval that adapts to speed (`SpeedBand`s): 30 s when walking or
    idle, 15 s on a bike, 10 s in city traffic and 5 s on a highway, by
    default;
  - a minimum distance moved, measured with Haversine, before an interval
    send;
  - a heading-change threshold, so that turns are sent early;
  - an accuracy filter that drops fixes with an accuracy radius worse than
    X metres;
  - an optional filter for mocked fixes;
  - a stationary detector. It pauses sending and sends a heartbeat every
    N minutes. Leaving the radius is sent at once;
  - a server override of the interval (such as `next_update_seconds`),
    clamped to `[minInterval, maxInterval]`.
- **Jitter filter.** It rejects impossible jumps by checking that the speed
  between fixes is plausible, after subtracting both accuracy radii. It
  re-syncs after N consistent fixes when the device really did move.
- **Offline backlog.**
  - Bounded by count and by age.
  - When full, it either drops the oldest points or downsamples, keeping
    every k-th point.
  - Replayed oldest-first, in batches of a configurable size, when your
    `Stream<bool>` reports that connectivity is back.
- **`BacklogStore`** is pluggable. `InMemoryBacklogStore` is the default,
  and `JsonFileBacklogStore` (from `io.dart`) writes the file atomically.
- **In-flight guard.** Sends never overlap. A failed send is retried with
  exponential backoff (`RetryBackoff`). A reconnect retries at once.
- **Lifecycle:** `start`, `pause`, `resume` and `stop`, plus a
  `statsStream` with sent, queued, skipped, and dropped counts by reason.
- **Injectable clock.** Every timer uses `dart:async`, so the whole
  pipeline is deterministic under `fake_async`.
- Pure Dart, with no dependencies. The core library runs on every
  platform, including the web.

## Install

```yaml
dependencies:
  throttled_location: ^0.1.0
```

## Usage

```dart
import 'package:throttled_location/io.dart';
import 'package:throttled_location/throttled_location.dart';

Future<ThrottledLocationReporter> startTracking({
  required LocationSource source, // see "Adapters" below
  required Stream<bool> online, // e.g. from connectivity_plus
  required String backlogPath, // e.g. from path_provider
  required Future<Map<String, Object?>> Function(List<Map<String, Object?>>)
      postPoints, // your HTTP call
}) async {
  final reporter = ThrottledLocationReporter(
    source: source,
    sink: LocationSink.fromFunction((batch) async {
      // Throwing (offline, timeout, 5xx) keeps the batch and retries.
      final body = await postPoints([for (final f in batch) f.toJson()]);
      final next = body['next_update_seconds'];
      return SinkResult.accepted(
        nextInterval: next is int ? Duration(seconds: next) : null,
      );
    }),
    policy: const ReportingPolicy(
      minInterval: Duration(seconds: 5),
      maxInterval: Duration(minutes: 2),
      maxAccuracyMeters: 50,
      heartbeatInterval: Duration(minutes: 5),
    ),
    backlog: BacklogPolicy(
      maxCount: 500,
      maxAge: const Duration(hours: 1),
      overflow: BacklogOverflow.downsample(keepEvery: 2),
    ),
    store: JsonFileBacklogStore(backlogPath),
    connectivity: online,
    batchSize: 50,
  );
  reporter.statsStream.listen((s) => print(s));
  await reporter.start();
  return reporter;
}
```

Call `pause()` when the courier goes off duty, `resume()` when they come
back, and `stop()` when the job ends. `stop()` makes one last delivery
attempt and then persists whatever is still queued.

`ReportingPolicyEngine` is the synchronous core. It does no I/O and starts
no timers, so you can use it on its own, for example to thin a recorded
track: `engine.evaluate(fix, now)` returns a `SendDecision`, a
`SkipDecision` or a `DropDecision`.

### How a fix is judged

The rules run in this order:

1. The mock filter, the accuracy filter, the out-of-order filter and the
   jitter filter. A fix that fails any of them is **dropped**.
2. The first fix after `start` or `resume` is **sent**.
3. A fix less than `minInterval` after the last send is **skipped**.
4. A fix that leaves the stationary radius is **sent**.
5. While stationary, a fix is skipped unless a heartbeat is due.
6. Once the interval (server override, else the speed band) has passed and
   the device has moved at least `minDistanceMeters`, the fix is **sent**.
7. A course change of at least `turnDegrees`, at a speed of at least
   `turnMinSpeedMps`, is **sent**.
8. If a heartbeat is due, the fix is **sent**. Otherwise it is skipped.

A heartbeat timer also re-sends the last valid fix when the GPS goes quiet.

### Adapters

#### geolocator

```dart
import 'package:geolocator/geolocator.dart';
import 'package:throttled_location/throttled_location.dart';

final geolocatorSource = LocationSource.fromStream(
  () => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0, // the policy does the throttling
    ),
  ).map(
    (p) => LocationFix(
      lat: p.latitude,
      lon: p.longitude,
      accuracy: p.accuracy,
      // Platforms report -1 (or 0 on some devices) when unknown.
      speed: p.speed >= 0 ? p.speed : null,
      heading: p.heading >= 0 ? p.heading : null,
      altitude: p.altitude,
      timestamp: p.timestamp,
      isMocked: p.isMocked,
    ),
  ),
);
```

Ask for location permission before calling `start()`. This package never
asks for permissions.

For plugins that only offer a one-shot "current position" call, wrap the
call in `PollingLocationSource(read, period: ...)`. Reads never overlap.

#### background_location_free

`background_location_free` is a sibling package that provides a
foreground-service location stream on Android. It is **still being built
and has not been published**, so the snippet below is a sketch against its
planned shape. The final API may differ.

```dart
// Sketch only: names may change before background_location_free ships.
final backgroundSource = LocationSource.fromStream(
  () => BackgroundLocation.positions(interval: const Duration(seconds: 1))
      .map((p) => LocationFix(
            lat: p.latitude,
            lon: p.longitude,
            accuracy: p.accuracy,
            speed: p.speed,
            heading: p.bearing,
            altitude: p.altitude,
            timestamp: p.time,
            isMocked: p.isMock,
          )),
);
```

## Limitations

- The package does not read the GPS or ask for permissions. You supply the
  `LocationSource`.
- Distances use a spherical Earth, the Haversine formula with the IUGG mean
  radius of 6 371 008.8 m. That is off by up to about 0.5% from the WGS-84
  ellipsoid, which is well below GPS noise at the distances involved.
- Age limits and the stationary timer compare the fix's own `timestamp`
  with the injected clock. A device with a badly wrong clock can expire
  points early or late.
- The default policy numbers (speed bands, 30 m stationary radius, 70 m/s
  jump limit) are engineering defaults tuned on synthetic tracks. They are
  not values from a study. Tune them for your fleet.
- `JsonFileBacklogStore` rewrites the whole file on every change. That is
  fine for a few thousand points. For more, implement `BacklogStore` on a
  database. It needs `dart:io`, so it is not available on the web.
- `stop()` is final. Create a new reporter to track again.

## License

MIT. See [LICENSE](LICENSE).

Made by [Abdeldjalil Chougui](https://abdeldjalilchougui.biz/).
