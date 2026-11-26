// Battery-life estimate. The ring leaves its own time-to-empty/full fields at zero, so we work it out:
// charge left (capacity x %) over the average current draw, preferring the observed % slope once there's
// enough history (the draw varies a lot).
class BatterySample {
  BatterySample(this.time, this.pct, this.microamps, this.charging);
  final DateTime time;
  final int pct, microamps;
  final bool charging;
}

class BatteryEstimate {
  BatteryEstimate({required this.charging, this.timeLeft, this.basis = ''});
  final bool charging;
  final Duration? timeLeft; // to empty, or to full when charging
  final String basis;

  String get label {
    final t = timeLeft;
    if (t == null) return charging ? 'Charging' : 'Estimating…';
    final h = t.inHours, m = t.inMinutes % 60;
    final s = h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
    return charging ? 'Full in $s' : '$s left';
  }
}

BatteryEstimate estimateBattery(
  List<BatterySample> samples, {
  int? cellMah,
  DateTime? now,
}) {
  if (samples.isEmpty) return BatteryEstimate(charging: false);
  final last = samples.last;
  final at = now ?? last.time;
  final recent = samples
      .where(
        (s) =>
            s.charging == last.charging &&
            at.difference(s.time) <= const Duration(minutes: 15),
      )
      .toList();
  if (last.charging && last.pct >= 100) {
    return BatteryEstimate(charging: true, timeLeft: Duration.zero);
  }

  // 1) observed % slope over at least 20 minutes of the same charging state
  final span = samples.where((s) => s.charging == last.charging).toList();
  if (span.length >= 2) {
    final first = span.first;
    final minutes = last.time.difference(first.time).inSeconds / 60;
    final dPct = last.pct - first.pct;
    if (minutes >= 20 && dPct.abs() >= 2) {
      final perMin = dPct / minutes; // + charging, - draining
      final left = last.charging
          ? (100 - last.pct) / perMin
          : last.pct / -perMin;
      if (left.isFinite && left > 0) {
        return BatteryEstimate(
          charging: last.charging,
          timeLeft: Duration(minutes: left.round()),
          basis: 'from the last ${minutes.round()} min of battery readings',
        );
      }
    }
  }

  // 2) charge left over the average current, if the ring told us its capacity
  if (cellMah == null) return BatteryEstimate(charging: last.charging);
  final avgUa =
      recent.map((s) => s.microamps.abs()).fold<int>(0, (a, b) => a + b) /
      recent.length;
  if (avgUa < 50) {
    return BatteryEstimate(charging: last.charging); // too small to divide by
  }
  final mAh = cellMah * (last.charging ? 100 - last.pct : last.pct) / 100;
  return BatteryEstimate(
    charging: last.charging,
    timeLeft: Duration(minutes: (mAh / (avgUa / 1000) * 60).round()),
    basis: 'from the current draw',
  );
}
