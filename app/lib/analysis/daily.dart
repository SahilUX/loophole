// Nightly summaries, personal baselines and an experimental recovery score. Loophole's own transparent
// method (not Ultrahuman's): every number here can be explained from the ring's raw readings.
import 'dart:math' as math;

import '../ring/protocol.dart';
import 'sleep.dart';

class Night {
  Night(this.day, this.sleep);
  final DateTime day; // the morning the night ends on
  final SleepEstimate sleep;

  int? get lowestHr => sleep.lowestHr;
  double? get hrv => sleep.avgHrv;
  double? get skinTemp => sleep.avgSkinTemp;

  /// Share of sleep records with movement: a rough restlessness measure.
  double get restlessness {
    final r = sleep.records;
    if (r.isEmpty) return 0;
    return r.where((x) => x.motion > 5 || x.steps > 0).length / r.length;
  }
}

class Baseline {
  Baseline(this.nights, this.lowestHr, this.hrv, this.skinTemp);
  final int nights; // how many earlier nights it's built from
  final double? lowestHr, hrv, skinTemp;
  bool get ready => nights >= 3;
}

class Recovery {
  Recovery(
    this.score,
    this.hrvDelta,
    this.hrDelta,
    this.tempDelta,
    this.sleepHours,
    this.baseline,
  );
  final int score; // 0..100
  final double? hrvDelta, hrDelta, tempDelta; // vs baseline: ms, bpm, °C
  final double sleepHours;
  final Baseline baseline;

  String get label => score >= 75
      ? 'Good'
      : score >= 55
      ? 'Fair'
      : 'Low';
}

double? _median(Iterable<num?> xs) {
  final v = xs.whereType<num>().map((e) => e.toDouble()).toList()..sort();
  if (v.isEmpty) return null;
  final m = v.length ~/ 2;
  return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
}

/// Nights for each of the last [days] mornings that have a sleep estimate, oldest first.
List<Night> nights(List<Record> records, {int days = 30, DateTime? today}) {
  final end = DateTime(
    (today ?? DateTime.now()).year,
    (today ?? DateTime.now()).month,
    (today ?? DateTime.now()).day,
  );
  final out = <Night>[];
  for (var i = days - 1; i >= 0; i--) {
    final day = end.subtract(Duration(days: i));
    final s = estimateSleep(records, day);
    if (s != null) out.add(Night(day, s));
  }
  return out;
}

/// Median of up to 14 nights before [night] (the night itself is excluded).
Baseline baselineBefore(List<Night> all, Night night) {
  final prior = all.where((n) => n.day.isBefore(night.day)).toList();
  final window = prior.length > 14 ? prior.sublist(prior.length - 14) : prior;
  return Baseline(
    window.length,
    _median(window.map((n) => n.lowestHr)),
    _median(window.map((n) => n.hrv)),
    _median(window.map((n) => n.skinTemp)),
  );
}

/// Experimental recovery score. Starts at 70 and moves with:
/// HRV vs baseline (+/-15 at +/-30%), lowest HR vs baseline (-/+10 at +/-5 bpm),
/// skin temperature vs baseline (-10 at +0.6 °C or more), and sleep length (-15 under 5 h, +5 over 7 h).
/// Without 3 earlier nights there's no baseline, so only sleep length counts.
Recovery recovery(List<Night> all, Night night) {
  final b = baselineBefore(all, night);
  final hours = night.sleep.duration.inMinutes / 60;
  var score = 70.0;
  double? dHrv, dHr, dTemp;
  if (b.ready) {
    if (night.hrv != null && b.hrv != null && b.hrv! > 0) {
      dHrv = night.hrv! - b.hrv!;
      score += (dHrv / b.hrv! / 0.30 * 15).clamp(-15, 15);
    }
    if (night.lowestHr != null && b.lowestHr != null) {
      dHr = night.lowestHr! - b.lowestHr!;
      score -= (dHr / 5 * 10).clamp(-10, 10);
    }
    if (night.skinTemp != null && b.skinTemp != null) {
      dTemp = night.skinTemp! - b.skinTemp!;
      score -= (math.max(0, dTemp) / 0.6 * 10).clamp(0, 10);
    }
  }
  if (hours < 5) score -= 15 * (5 - hours) / 5;
  if (hours > 7) score += 5;
  return Recovery(score.round().clamp(0, 100), dHrv, dHr, dTemp, hours, b);
}

/// Per-day totals for trends.
class DayTotals {
  DayTotals(this.day, this.steps, this.avgHr, this.worn);
  final DateTime day;
  final int steps;
  final double? avgHr;
  final Duration worn;
}

List<DayTotals> dailyTotals(
  List<Record> records, {
  int days = 30,
  DateTime? today,
}) {
  final now = today ?? DateTime.now();
  final end = DateTime(now.year, now.month, now.day);
  return [
    for (var i = days - 1; i >= 0; i--)
      () {
        final d = end.subtract(Duration(days: i));
        final a = d.millisecondsSinceEpoch ~/ 1000;
        final b = d.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
        final rs = records
            .where((r) => r.timestamp >= a && r.timestamp < b)
            .toList();
        final hrs = rs.map((r) => r.validHr).whereType<int>().toList();
        return DayTotals(
          d,
          rs.fold(0, (s, r) => s + r.steps),
          hrs.isEmpty ? null : hrs.reduce((x, y) => x + y) / hrs.length,
          wornDuration(rs),
        );
      }(),
  ];
}

/// Time the ring was worn: gaps between consecutive worn readings, each capped at [cap] so off-finger stretches
/// don't count. (Readings come every ~6 min normally and every few seconds during live sessions.)
Duration wornDuration(
  List<Record> records, {
  Duration cap = const Duration(minutes: 10),
}) {
  final ts = records.where((r) => r.worn).map((r) => r.timestamp).toList()
    ..sort();
  var total = 0;
  for (var i = 1; i < ts.length; i++) {
    total += math.min(ts[i] - ts[i - 1], cap.inSeconds);
  }
  return Duration(seconds: total);
}
