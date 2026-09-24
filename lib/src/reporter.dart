import 'dart:async';

import 'backlog.dart';
import 'location_fix.dart';
import 'policy.dart';
import 'policy_engine.dart';
import 'reasons.dart';
import 'sink.dart';
import 'source.dart';
import 'stats.dart';
import 'store.dart';

/// Sends location fixes to a [LocationSink] following a [ReportingPolicy],
/// with an offline backlog, an in-flight guard and retry with backoff.
///
/// Every fix the policy accepts goes into the backlog, and the backlog is
/// drained oldest-first in batches of up to [batchSize] while online. Only
/// one batch is ever in flight. A thrown error keeps the batch and retries
/// after [retry]'s delay; going online again retries at once.
///
/// Nothing starts on construction. Call [start].
class ThrottledLocationReporter {
  /// Creates a reporter.
  ///
  /// [connectivity] reports network availability (`true` = online). Until
  /// it emits, [initiallyOnline] is assumed. [clock] supplies "now" for
  /// the policy and the backlog age bound. Timers use `dart:async`.
  ThrottledLocationReporter({
    required this.source,
    required this.sink,
    ReportingPolicy policy = const ReportingPolicy(),
    BacklogPolicy? backlog,
    BacklogStore? store,
    Stream<bool>? connectivity,
    bool initiallyOnline = true,
    this.batchSize = 50,
    this.retry = const RetryBackoff(),
    DateTime Function()? clock,
  })  : engine = ReportingPolicyEngine(policy),
        backlogPolicy = backlog ?? BacklogPolicy(),
        store = store ?? InMemoryBacklogStore(),
        _connectivity = connectivity,
        _online = initiallyOnline,
        _clock = clock ?? DateTime.now {
    if (batchSize < 1) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be >= 1');
    }
    _backlog = Backlog(backlogPolicy);
  }

  /// Where fixes come from.
  final LocationSource source;

  /// Where batches go.
  final LocationSink sink;

  /// The policy engine. Read it for the last sent fix or the current
  /// interval, or call `setServerInterval` directly.
  final ReportingPolicyEngine engine;

  /// Bounds for the offline backlog.
  final BacklogPolicy backlogPolicy;

  /// Persistence for the backlog.
  final BacklogStore store;

  /// Most fixes per sink call.
  final int batchSize;

  /// Delay schedule after failed sends.
  final RetryBackoff retry;

  final Stream<bool>? _connectivity;
  final DateTime Function() _clock;
  final _statsController = StreamController<ReporterStats>.broadcast();

  late Backlog _backlog;
  ReporterState _state = ReporterState.idle;
  bool _online;
  bool _inFlight = false;
  bool _closing = false;
  int _sent = 0;
  int _failures = 0;
  final _dropped = <DropReason, int>{};
  final _skipped = <SkipReason, int>{};

  StreamSubscription<LocationFix>? _fixSub;
  StreamSubscription<bool>? _netSub;
  Timer? _heartbeatTimer;
  Timer? _retryTimer;
  Future<void>? _drainFuture;
  Future<void> _persistTail = Future.value();
  ReporterStats _stats = const ReporterStats();

  /// Current lifecycle state.
  ReporterState get state => _state;

  /// Latest counters.
  ReporterStats get stats => _stats;

  /// Emits a snapshot after every change. Closed by [stop].
  Stream<ReporterStats> get statsStream => _statsController.stream;

  /// Loads the persisted backlog, starts listening to the source and the
  /// connectivity stream, and sends what is queued. Throws [StateError]
  /// unless the reporter is idle, synchronously. Errors from [BacklogStore.read]
  /// propagate.
  Future<void> start() {
    if (_state != ReporterState.idle) {
      throw StateError('start() called in state ${_state.name}');
    }
    _state = ReporterState.running;
    return _load();
  }

  Future<void> _load() async {
    final persisted = await store.read();
    if (_closing) return; // stop() was called while loading
    _backlog = Backlog(backlogPolicy, initial: persisted);
    _netSub = _connectivity?.listen(_onConnectivity);
    _listen();
    _emit();
    _pump();
  }

  /// Stops listening to the source and cancels heartbeats. Points already
  /// queued are still delivered. No-op unless running.
  void pause() {
    if (_state != ReporterState.running) return;
    _state = ReporterState.paused;
    _unlisten();
    _emit();
  }

  /// Listens to the source again. The next valid fix is sent at once.
  /// No-op unless paused.
  void resume() {
    if (_state != ReporterState.paused) return;
    _state = ReporterState.running;
    engine.reset();
    _listen();
    _emit();
  }

  /// Ends the session: cancels the source, the connectivity stream and
  /// all timers, waits for the in-flight send, makes one last delivery
  /// attempt when [flush] is true and the device is online, persists what
  /// is left and closes [statsStream]. Idempotent.
  Future<void> stop({bool flush = true}) async {
    if (_state == ReporterState.stopped || _closing) return;
    _closing = true;
    _unlisten();
    await _netSub?.cancel();
    _netSub = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _drainFuture;
    if (flush && _online && !_backlog.isEmpty) await _drain();
    await _persistTail;
    _state = ReporterState.stopped;
    _emit();
    await _statsController.close();
  }

  void _listen() {
    _fixSub = source.watch().listen(_onFix, onError: (Object _) {});
    _scheduleHeartbeat();
  }

  void _unlisten() {
    _fixSub?.cancel();
    _fixSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _onFix(LocationFix fix) {
    if (_state != ReporterState.running || _closing) return;
    final now = _clock();
    switch (engine.evaluate(fix, now)) {
      case SendDecision():
        _enqueue(fix, now);
      case SkipDecision(:final reason):
        _skipped[reason] = (_skipped[reason] ?? 0) + 1;
      case DropDecision(:final reason):
        _count(reason, 1);
    }
    _scheduleHeartbeat();
    _emit();
  }

  void _scheduleHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final due = engine.nextHeartbeatAt;
    if (due == null || _state != ReporterState.running) return;
    var wait = due.difference(_clock());
    if (wait < Duration.zero) wait = Duration.zero;
    _heartbeatTimer = Timer(wait, () {
      _heartbeatTimer = null;
      if (_state != ReporterState.running || _closing) return;
      final now = _clock();
      final fix = engine.heartbeat(now);
      if (fix != null) _enqueue(fix, now);
      _scheduleHeartbeat();
      _emit();
    });
  }

  void _enqueue(LocationFix fix, DateTime now) {
    _backlog.add(fix, now).forEach(_count);
    _persist();
    _pump();
  }

  void _onConnectivity(bool online) {
    if (online == _online) return;
    _online = online;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (online) _failures = 0;
    _emit();
    _pump();
  }

  void _pump() {
    if (_inFlight || _closing) return;
    _drainFuture = _drain();
  }

  Future<void> _drain() async {
    if (_inFlight) return;
    _inFlight = true;
    try {
      while (_online && _retryTimer == null && !_backlog.isEmpty) {
        final expired = _backlog.expire(_clock());
        if (expired > 0) _count(DropReason.expired, expired);
        if (_backlog.isEmpty) break;
        final batch = _backlog.lockBatch(batchSize);
        final SinkResult result;
        try {
          result = await sink.send(batch);
        } catch (_) {
          _backlog.releaseLocked();
          _failures++;
          if (!_closing && _online) {
            _retryTimer = Timer(retry.delay(_failures), () {
              _retryTimer = null;
              _pump();
            });
          }
          _emit();
          break;
        }
        _backlog.commitLocked();
        _failures = 0;
        if (result.accepted) {
          _sent += batch.length;
        } else {
          _count(DropReason.rejectedByServer, batch.length);
        }
        final next = result.nextInterval;
        if (next != null) engine.setServerInterval(next);
        _persist();
        _emit();
      }
    } finally {
      _inFlight = false;
    }
  }

  void _count(DropReason reason, int n) =>
      _dropped[reason] = (_dropped[reason] ?? 0) + n;

  void _persist() {
    final snapshot = _backlog.items;
    _persistTail = _persistTail
        .then((_) => store.write(snapshot))
        .catchError((Object _) {});
  }

  void _emit() {
    _stats = ReporterStats(
      state: _state,
      sent: _sent,
      queued: _backlog.length,
      droppedByReason: Map.unmodifiable(_dropped),
      skippedByReason: Map.unmodifiable(_skipped),
      isOnline: _online,
      isStationary: engine.isStationary,
      interval: engine.currentInterval,
      consecutiveFailures: _failures,
    );
    if (!_statsController.isClosed) _statsController.add(_stats);
  }
}
