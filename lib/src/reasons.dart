/// Why a fix was discarded and will never reach the server.
enum DropReason {
  /// Accuracy radius was worse than `ReportingPolicy.maxAccuracyMeters`.
  inaccurate,

  /// The fix came from a mock provider and `rejectMocked` is on.
  mocked,

  /// The fix is not newer than the previous valid fix.
  outOfOrder,

  /// Reaching the fix would need an impossible speed (GPS jump).
  implausibleJump,

  /// The backlog was full and the oldest queued point was dropped.
  overflow,

  /// The backlog was full and the point was removed by downsampling.
  downsampled,

  /// The queued point became older than `BacklogPolicy.maxAge`.
  expired,

  /// The sink returned `SinkResult.rejected` for the batch.
  rejectedByServer,
}

/// Why a valid fix was not sent. Skips are the policy doing its job, not
/// data loss.
enum SkipReason {
  /// Less time than the current interval has passed since the last send.
  tooSoon,

  /// The interval has passed but the device has not moved far enough.
  notMoved,

  /// The device is stationary and no heartbeat is due.
  stationary,
}

/// Why a fix was sent.
enum SendReason {
  /// First fix after `start` or `resume`.
  first,

  /// The current interval has passed and the device moved far enough.
  interval,

  /// The heading changed by more than the turn threshold.
  turn,

  /// The device left the stationary radius.
  resumedMoving,

  /// No send for `heartbeatInterval`; the latest position is re-sent.
  heartbeat,
}
