import 'package:flutter_test/flutter_test.dart';
import 'package:loophole/analysis/daily.dart';
import 'package:loophole/ring/protocol.dart';

Record rec(
  DateTime t, {
  required int hr,
  required int hrv,
  double temp = 35.0,
}) => Record(
  index: 0,
  timestamp: t.millisecondsSinceEpoch ~/ 1000,
  hr: hr,
  rmssdMs: hrv,
  spo2: 0,
  pulseConfidence: 2,
  skinTempC: temp,
  secondTempC: 30,
  motion: 0,
  steps: 0,
  byte28: 0,
  byte29: 0,
);

/// One 7-hour night ending on [morning], records every 6 minutes.
List<Record> night(
  DateTime morning, {
  int hr = 55,
  int hrv = 60,
  double temp = 35.0,
}) {
  final start = morning.subtract(const Duration(hours: 1)); // 23:00
  return [
    for (var m = 0; m < 7 * 60; m += 6)
      rec(
        start.add(Duration(minutes: m)),
        hr: hr,
        hrv: hrv,
        temp: temp,
      ),
  ];
}

void main() {
  final today = DateTime(2030, 1, 15);
  List<Record> history({required Map<int, (int, int, double)> overrides}) => [
    for (var i = 6; i >= 0; i--)
      ...() {
        final d = today.subtract(Duration(days: i));
        final o = overrides[i];
        return night(d, hr: o?.$1 ?? 55, hrv: o?.$2 ?? 60, temp: o?.$3 ?? 35.0);
      }(),
  ];

  test('baseline comes from earlier nights only and needs three', () {
    final ns = nights(history(overrides: {}), days: 7, today: today);
    expect(ns.length, 7);
    expect(baselineBefore(ns, ns[1]).ready, isFalse);
    final b = baselineBefore(ns, ns.last);
    expect((b.nights, b.lowestHr, b.hrv), (6, 55.0, 60.0));
  });

  test('a normal night scores higher than a rough one', () {
    final ok = nights(history(overrides: {}), days: 7, today: today);
    final rough = nights(
      history(overrides: {0: (63, 40, 35.8)}),
      days: 7,
      today: today,
    );
    final good = recovery(ok, ok.last), bad = recovery(rough, rough.last);
    expect(good.score, greaterThan(bad.score));
    expect(bad.hrDelta, 8);
    expect(bad.hrvDelta, -20);
    expect(bad.tempDelta, closeTo(0.8, 1e-6));
    expect(bad.label, 'Low');
  });

  test('daily totals', () {
    final t = dailyTotals(history(overrides: {}), days: 2, today: today);
    expect(t.length, 2);
    expect(t.last.avgHr, 55);
    expect(
      t.last.worn.inMinutes,
      6 * 60 - 6,
    ); // the part of the night after midnight
  });

  test('worn time sums real gaps, capped', () {
    final t0 = DateTime(2030, 1, 15, 12);
    final dense = [
      for (var s = 0; s < 600; s += 2)
        rec(t0.add(Duration(seconds: s)), hr: 60, hrv: 50),
    ];
    expect(
      wornDuration(dense).inMinutes,
      9,
    ); // 10 minutes of 2-second samples, not 300 x 6 min
    final sparse = [
      rec(t0, hr: 60, hrv: 50),
      rec(t0.add(const Duration(hours: 3)), hr: 60, hrv: 50),
    ];
    expect(
      wornDuration(sparse).inMinutes,
      10,
    ); // a 3-hour gap counts as at most 10 minutes
  });
}
