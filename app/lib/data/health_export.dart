// Writes ring readings to Health Connect, so other apps can use them. Untested. Not offered on iOS: Apple Health needs
// an entitlement this project doesn't have yet.
// Write-only: Loophole never reads other apps' health data. No breathing rate: the byte that might hold it isn't
// understood (notes/protocol.md).
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/sleep.dart';
import '../ring/protocol.dart';

const healthTypes = [
  HealthDataType.HEART_RATE,
  HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
  HealthDataType.STEPS,
  HealthDataType.SLEEP_SESSION,
  HealthDataType.BLOOD_OXYGEN,
];

class HealthExport {
  HealthExport(this.ringName);
  final String ringName;
  final _health = Health();
  bool _configured = false;

  String get _key => 'healthExportedUntil_$ringName';

  Future<void> _configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  /// Health Connect must be installed (built in on Android 14+).
  Future<bool> available() async {
    await _configure();
    final s = await _health.getHealthConnectSdkStatus();
    return s == null || s == HealthConnectSdkStatus.sdkAvailable; // null on iOS
  }

  Future<bool> requestPermission() async {
    await _configure();
    return _health.requestAuthorization(
      healthTypes,
      permissions: [for (final _ in healthTypes) HealthDataAccess.WRITE],
    );
  }

  Future<bool> hasPermission() async {
    await _configure();
    return await _health.hasPermissions(
          healthTypes,
          permissions: [for (final _ in healthTypes) HealthDataAccess.WRITE],
        ) ??
        false;
  }

  /// Write everything newer than the last export. Returns (written, skipped) data points.
  Future<(int, int)> export(List<Record> records) async {
    await _configure();
    final prefs = await SharedPreferences.getInstance();
    final since = prefs.getInt(_key) ?? 0;
    final fresh = records.where((r) => r.timestamp > since).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (fresh.isEmpty) return (0, 0);
    var n = 0, skipped = 0;
    Future<void> put(
      double v,
      HealthDataType t,
      DateTime start, [
      DateTime? end,
    ]) async {
      try {
        if (await _health.writeHealthData(
          value: v,
          type: t,
          startTime: start,
          endTime: end ?? start,
        )) {
          n++;
        }
      } on Exception {
        skipped++; // one bad point shouldn't stop the export
      }
    }

    int? prevTs;
    for (final r in fresh) {
      final at = DateTime.fromMillisecondsSinceEpoch(r.timestamp * 1000);
      if (r.validHr != null) {
        await put(r.validHr!.toDouble(), HealthDataType.HEART_RATE, at);
      }
      if (r.validHrv != null) {
        await put(
          r.validHrv!.toDouble(),
          HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
          at,
        );
      }
      if (r.validSpo2 != null) {
        await put(r.validSpo2!.toDouble(), HealthDataType.BLOOD_OXYGEN, at);
      }
      if (r.steps > 0) {
        // steps were counted since the previous record (at most 10 minutes back)
        final from =
            prevTs != null &&
                r.timestamp - prevTs <= 600 &&
                prevTs < r.timestamp
            ? prevTs
            : r.timestamp - 60; // needs a non-empty interval
        await put(
          r.steps.toDouble(),
          HealthDataType.STEPS,
          DateTime.fromMillisecondsSinceEpoch(from * 1000),
          at,
        );
      }
      prevTs = r.timestamp;
    }

    // Sleep: nights that ended after the last export.
    final lastDay = DateTime.fromMillisecondsSinceEpoch(
      fresh.last.timestamp * 1000,
    );
    for (
      var d = DateTime.fromMillisecondsSinceEpoch(fresh.first.timestamp * 1000);
      !d.isAfter(lastDay);
      d = d.add(const Duration(days: 1))
    ) {
      final s = estimateSleep(records, DateTime(d.year, d.month, d.day));
      if (s != null && s.end > since && s.end <= fresh.last.timestamp - 3600) {
        // only nights that are over (an hour without sleep after the end)
        await put(
          s.duration.inMinutes.toDouble(),
          HealthDataType.SLEEP_SESSION,
          DateTime.fromMillisecondsSinceEpoch(s.start * 1000),
          DateTime.fromMillisecondsSinceEpoch(s.end * 1000),
        );
      }
    }
    await prefs.setInt(_key, fresh.last.timestamp);
    return (n, skipped);
  }
}
