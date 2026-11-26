import 'package:flutter_test/flutter_test.dart';
import 'package:loophole/analysis/sleep.dart';
import 'package:loophole/ring/protocol.dart';

Record rec(DateTime t, {int hr = 60, int motion = 0, int steps = 0}) => Record(
  index: 0,
  timestamp: t.millisecondsSinceEpoch ~/ 1000,
  hr: hr,
  rmssdMs: 60,
  spo2: 0,
  pulseConfidence: 2,
  skinTempC: 35.0,
  secondTempC: 30.0,
  motion: motion,
  steps: steps,
  byte28: 0,
  byte29: 0,
);

void main() {
  final day = DateTime(2030, 1, 15);
  List<Record> every5min(
    DateTime from,
    DateTime to,
    Record Function(DateTime) f,
  ) => [
    for (var t = from; t.isBefore(to); t = t.add(const Duration(minutes: 5)))
      f(t),
  ];

  test(
    'finds the longest still stretch overnight, tolerating short wake-ups',
    () {
      final recs = [
        ...every5min(
          DateTime(2030, 1, 14, 20),
          DateTime(2030, 1, 14, 23),
          (t) => rec(t, hr: 75, motion: 40, steps: 30),
        ),
        ...every5min(
          DateTime(2030, 1, 14, 23),
          DateTime(2030, 1, 15, 3),
          (t) => rec(t, hr: 55),
        ),
        rec(
          DateTime(2030, 1, 15, 3, 2),
          motion: 30,
          hr: 70,
        ), // brief wake, under the 20-minute gap
        ...every5min(
          DateTime(2030, 1, 15, 3, 10),
          DateTime(2030, 1, 15, 7),
          (t) => rec(t, hr: 52),
        ),
        ...every5min(
          DateTime(2030, 1, 15, 7),
          DateTime(2030, 1, 15, 10),
          (t) => rec(t, hr: 80, motion: 50, steps: 40),
        ),
      ];
      final s = estimateSleep(recs, day)!;
      expect(
        DateTime.fromMillisecondsSinceEpoch(s.start * 1000),
        DateTime(2030, 1, 14, 23),
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(s.end * 1000),
        DateTime(2030, 1, 15, 6, 55),
      );
      expect(s.lowestHr, 52);
    },
  );

  test('no sleep when the ring was moving or absent all night', () {
    final recs = every5min(
      DateTime(2030, 1, 14, 20),
      DateTime(2030, 1, 15, 10),
      (t) => rec(t, motion: 40, steps: 20),
    );
    expect(estimateSleep(recs, day), isNull);
    expect(estimateSleep(const [], day), isNull);
  });
}
