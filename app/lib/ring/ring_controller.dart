// App-wide ring state: which ring is ours, the connection (with reconnects), and the data we've read from it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/battery.dart';
import '../data/health_export.dart';
import '../data/record_store.dart';
import '../analysis/daily.dart';
import '../ui/widget_image.dart';
import 'identity.dart';
import 'protocol.dart';
import 'ring_client.dart';

/// What went wrong, without the details: Bluetooth error text can hold the ring's name or address.
String errorKind(Object e) => e.runtimeType.toString();

enum LinkState { noRing, searching, connecting, connected }

class RingController extends ChangeNotifier {
  String? ringId, ringName;
  LinkState link = LinkState.noRing;
  RingClient? client;
  BatteryState? state;
  BatteryMode? mode;
  LiveHr? liveHr;
  String? firmware;
  RingIdentity? identity;
  bool? spo2On;
  List<LogEntry> events = const [];
  BreathSample? breath;
  bool breathRunning = false;
  final List<BatterySample> battery =
      []; // last hour of state records, for the battery-life estimate
  bool? backgroundAllowed; // Android: exempt from battery optimisation
  bool healthOn = false; // write readings to Health Connect after each sync
  String? healthStatus;
  final List<(int, int)> breathHr =
      []; // (unix time, bpm) during the current session
  bool liveRunning = false;
  bool syncing = false;
  String? message;
  final List<Record> records = [];
  int? lastIndex;

  StreamSubscription<BatteryState>? _stateSub;
  StreamSubscription<LiveHr>? _liveSub;
  Timer? _liveStop;
  Timer? _autoSync;
  StreamSubscription<BreathSample>? _breathSub;
  Timer? _breathStop;
  bool _stopped = false;
  RecordStore? _store;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    ringId = prefs.getString('ringId');
    ringName = prefs.getString('ringName');
    healthOn = prefs.getBool('healthOn') ?? false;
    if (ringName != null) await _openStore();
    if (ringId != null) unawaited(_connectLoop());
    notifyListeners();
  }

  /// Load the stored history for the current ring; the newest stored index is where the next sync resumes.
  Future<void> _openStore() async {
    _store = await RecordStore.open(ringName!);
    records
      ..clear()
      ..addAll(await _store!.load())
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    lastIndex = records.isEmpty
        ? null
        : records.map((r) => r.index).reduce((a, b) => a > b ? a : b);
  }

  static Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true; // iOS asks on first Bluetooth use
    // Android 12+ only (minSdk 31): scanning is declared neverForLocation, so no location permission is needed.
    final r = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    return r[Permission.bluetoothScan]!.isGranted &&
        r[Permission.bluetoothConnect]!.isGranted;
  }

  Future<void> choose(FoundRing ring) async {
    await forget(notify: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ringId', ring.id);
    await prefs.setString('ringName', ring.name);
    ringId = ring.id;
    ringName = ring.name;
    await _openStore();
    _stopped = false;
    unawaited(_connectLoop());
    notifyListeners();
  }

  Future<void> forget({bool notify = true}) async {
    _stopped = true;
    await stopLiveHr();
    await client?.disconnect();
    client = null;
    state = null;
    mode = null;
    link = LinkState.noRing;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ringId');
    await prefs.remove('ringName');
    ringId = null;
    ringName = null;
    if (notify) notifyListeners();
  }

  Future<void> _connectLoop() async {
    while (!_stopped && ringId != null) {
      link = LinkState.connecting;
      notifyListeners();
      try {
        final c = await RingClient.connect(ringId!, ringName ?? 'ring');
        client = c;
        link = LinkState.connected;
        message = null;
        _stateSub = c.states.listen((s) {
          state = s;
          _addBattery(s);
          notifyListeners();
        });
        notifyListeners();
        unawaited(_afterConnect(c));
        // The ring writes a record every few minutes; pull them while we're connected.
        _autoSync = Timer.periodic(const Duration(minutes: 10), (_) => sync());
        await c.disconnected;
        _autoSync?.cancel();
      } catch (e) {
        message = 'Can\'t reach your ring. Is it nearby, and not connected to another phone?';
      }
      await _stateSub?.cancel();
      _liveSub?.cancel();
      liveRunning = false;
      client = null;
      if (_stopped) break;
      link = LinkState.searching;
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _afterConnect(RingClient c) async {
    try {
      if (_breathNeedsStop) {
        _breathNeedsStop = !(await c.stopBreath().catchError((_) => false));
      }
      state ??= await c.readState();
      if (state != null) _addBattery(state!);
      await checkBackground(request: true);
      final d = await c.diag();
      mode = d.mode;
      spo2On = d.spo2On;
      notifyListeners();
      firmware ??= await c.firmware().catchError((_) => null);
      if (identity == null) {
        final sn = await c.serial();
        if (sn != null) identity = parseIdentity(sn);
        notifyListeners();
      }
      await sync();
    } catch (e) {
      message = 'Ring connected, but a read failed (${errorKind(e)}).';
      notifyListeners();
    }
  }

  /// Download history records newer than the last ones we have.
  Future<void> sync() async {
    final c = client;
    if (c == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      final (first, last) = await c.historyBounds();
      if (last != null) {
        // First sync: everything the ring still holds. After that, only what's new. If the ring's index went
        // backwards (it was reset), start again from its oldest record.
        final resume = lastIndex != null && lastIndex! <= last
            ? lastIndex! + 1
            : null;
        final start = resume ?? (first ?? 0);
        if (start <= last) {
          final got = await c.records(start);
          records
            ..addAll(got)
            ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
          if (got.isNotEmpty) {
            lastIndex = got.map((r) => r.index).reduce((a, b) => a > b ? a : b);
            await _store?.append(got);
          }
        }
      }
    } catch (e) {
      message = 'Sync failed (${errorKind(e)}).';
    } finally {
      syncing = false;
      notifyListeners();
    }
    if (healthOn) await exportHealth();
  }

  Future<void> setMode(BatteryMode m) async {
    final c = client;
    if (c == null) return;
    final ok = await c.setMode(m);
    if (ok) mode = m;
    message = ok ? null : 'The ring refused that mode change.';
    notifyListeners();
  }

  Future<void> startLiveHr() async {
    final c = client;
    if (c == null || liveRunning) return;
    if (!await c.startLiveHr()) {
      message = 'The ring refused live heart rate. Critical mode may block it.';
      notifyListeners();
      return;
    }
    liveRunning = true;
    _liveSub = c.liveHr.listen((x) {
      liveHr = x;
      notifyListeners();
    });
    _liveStop = Timer(
      const Duration(minutes: 2),
      stopLiveHr,
    ); // never leave the sensors running
    notifyListeners();
  }

  Future<void> stopLiveHr() async {
    _liveStop?.cancel();
    await _liveSub?.cancel();
    if (liveRunning) await client?.stopLiveHr();
    liveRunning = false;
    notifyListeners();
  }

  Future<void> setSpo2(bool on) async {
    final c = client;
    if (c == null) return;
    if (await c.setSpo2(on)) spo2On = on;
    notifyListeners();
  }

  Future<void> loadEvents() async {
    final c = client;
    if (c == null) return;
    try {
      events = (await c.events()).reversed.toList();
    } catch (e) {
      message = 'Couldn\'t read the ring\'s event log (${errorKind(e)}).';
    }
    notifyListeners();
  }

  /// Breathing mode streams HR about once a second; it uses the sensors, so it always stops after [length].
  Future<void> startBreath(Duration length) async {
    final c = client;
    if (c == null || breathRunning) return;
    if (liveRunning) await stopLiveHr();
    breathHr.clear();
    breath = null;
    if (!await c.startBreath()) {
      message = 'The ring refused breathing mode.';
      notifyListeners();
      return;
    }
    breathRunning = true;
    _breathSub = c.breath.listen((b) {
      breath = b;
      if (b.hr > 0) breathHr.add((b.timestamp, b.hr));
      notifyListeners();
    });
    _breathStop = Timer(length, stopBreath);
    notifyListeners();
  }

  Future<void> stopBreath() async {
    _breathStop?.cancel();
    await _breathSub?.cancel();
    if (breathRunning) {
      try {
        await client?.stopBreath();
      } catch (_) {
        // link dropped; the ring is told again on the next connect
        _breathNeedsStop = true;
      }
    }
    breathRunning = false;
    notifyListeners();
  }

  bool _breathNeedsStop = false;

  Future<void> setHealth(bool on) async {
    if (ringName == null) return;
    final h = HealthExport(ringName!);
    if (on) {
      if (!await h.available()) {
        healthStatus = 'Health Connect isn\'t available on this phone.';
        notifyListeners();
        return;
      }
      if (!await h.requestPermission()) {
        healthStatus = 'Permission not granted.';
        notifyListeners();
        return;
      }
    }
    healthOn = on;
    (await SharedPreferences.getInstance()).setBool('healthOn', on);
    healthStatus = null;
    notifyListeners();
    if (on) await exportHealth();
  }

  Future<void> exportHealth() async {
    if (ringName == null || records.isEmpty) return;
    try {
      final (n, skipped) = await HealthExport(ringName!).export(records);
      healthStatus =
          'Last sent ${DateTime.now().toString().substring(11, 16)}: $n new readings'
          '${skipped > 0 ? ', $skipped skipped' : ''}';
    } catch (e) {
      healthStatus = 'Couldn\'t write to Health Connect (${errorKind(e)}).';
    }
    notifyListeners();
  }

  DateTime? _widgetAt;

  /// Push the latest numbers to the home-screen widget (at most once a minute).
  Future<void> updateWidget({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _widgetAt != null &&
        now.difference(_widgetAt!) < const Duration(minutes: 1)) {
      return;
    }
    _widgetAt = now;
    try {
      final s = state;
      final lastHr = records.reversed
          .map((r) => r.validHr)
          .whereType<int>()
          .firstOrNull;
      final ns = nights(records, days: 21);
      final today = DateTime(now.year, now.month, now.day);
      final rec = ns.isNotEmpty && ns.last.day == today
          ? recovery(ns, ns.last).score
          : null;
      final hh =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final png = await renderWidgetPng(
        battery: s?.batteryPct,
        charging: s?.charging ?? false,
        batteryLeft: s == null ? 'Battery' : batteryEstimate.label,
        hr: liveRunning && liveHr != null ? liveHr!.hr : lastHr,
        recovery: rec,
        status: link == LinkState.connected ? 'Connected $hh' : 'Offline $hh',
        connected: link == LinkState.connected,
      );
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/widget.png');
      await file.writeAsBytes(png, flush: true);
      await HomeWidget.saveWidgetData<String>('widget_image', file.path);
      await HomeWidget.updateWidget(androidName: 'RingWidgetProvider');
    } on Object catch (e) {
      debugPrint(
        'Loophole widget update failed (${errorKind(e)})',
      ); // e.g. no widget placed
    }
  }

  void _addBattery(BatteryState s) {
    final now = DateTime.now();
    battery
      ..add(BatterySample(now, s.batteryPct, s.microamps, s.charging))
      ..removeWhere((b) => now.difference(b.time) > const Duration(hours: 1));
    updateWidget();
  }

  BatteryEstimate get batteryEstimate =>
      estimateBattery(battery, cellMah: state?.cellMah);

  /// Android may stop background Bluetooth apps under battery optimisation; ask once to be exempt.
  Future<void> checkBackground({bool request = false}) async {
    if (!Platform.isAndroid) {
      backgroundAllowed = true;
      return;
    }
    var st = await Permission.ignoreBatteryOptimizations.status;
    final prefs = await SharedPreferences.getInstance();
    if (!st.isGranted &&
        request &&
        !(prefs.getBool('askedBackground') ?? false)) {
      await prefs.setBool('askedBackground', true);
      st = await Permission.ignoreBatteryOptimizations.request();
    }
    backgroundAllowed = st.isGranted;
    notifyListeners();
  }

  Future<void> allowBackground() async {
    if (!Platform.isAndroid) return;
    final st = await Permission.ignoreBatteryOptimizations.request();
    backgroundAllowed = st.isGranted;
    notifyListeners();
  }
}
