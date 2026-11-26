// A first, simple sleep estimate from ring history: the longest still stretch overnight.
// Our own heuristic (not Ultrahuman's model). Shown in the app as an estimate until it's validated.
import '../ring/protocol.dart';

class SleepEstimate {
  SleepEstimate(this.start, this.end, this.records);
  final int start, end; // unix seconds
  final List<Record> records;

  Duration get duration => Duration(seconds: end - start);
  int? get lowestHr {
    final hrs = records.map((r) => r.validHr).whereType<int>();
    return hrs.isEmpty ? null : hrs.reduce((a, b) => a < b ? a : b);
  }

  double? get avgHrv {
    final v = records.map((r) => r.validHrv).whereType<int>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }

  double? get avgSkinTemp {
    final v = records.map((r) => r.validSkinTemp).whereType<double>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }
}

/// Still = no steps and motion at or below [stillMotion]. A sleep block is the longest run of still records,
/// allowing gaps (movement or missing data) up to [maxGap], inside the night window 18:00 the day before [day]
/// to 14:00 on [day] (local time). Needs at least [minSleep] to count.
SleepEstimate? estimateSleep(
  List<Record> all,
  DateTime day, {
  int stillMotion = 5,
  Duration maxGap = const Duration(minutes: 20),
  Duration minSleep = const Duration(hours: 1),
}) {
  final from =
      DateTime(
        day.year,
        day.month,
        day.day,
      ).subtract(const Duration(hours: 6)).millisecondsSinceEpoch ~/
      1000;
  final to =
      DateTime(day.year, day.month, day.day, 14).millisecondsSinceEpoch ~/ 1000;
  final night =
      all
          .where(
            (r) => r.timestamp >= from && r.timestamp < to && r.validHr != null,
          )
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final still = night
      .where((r) => r.steps == 0 && r.motion <= stillMotion)
      .toList();
  if (still.isEmpty) return null;

  var bestStart = 0, bestEnd = 0, runStart = 0;
  for (var i = 1; i <= still.length; i++) {
    final broke =
        i == still.length ||
        still[i].timestamp - still[i - 1].timestamp > maxGap.inSeconds;
    if (broke) {
      if (still[i - 1].timestamp - still[runStart].timestamp >
          still[bestEnd].timestamp - still[bestStart].timestamp) {
        bestStart = runStart;
        bestEnd = i - 1;
      }
      runStart = i;
    }
  }
  final start = still[bestStart].timestamp, end = still[bestEnd].timestamp;
  if (end - start < minSleep.inSeconds) return null;
  return SleepEstimate(
    start,
    end,
    night.where((r) => r.timestamp >= start && r.timestamp <= end).toList(),
  );
}
