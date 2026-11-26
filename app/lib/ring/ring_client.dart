// BLE client for the ring. Sends only allowlisted packets (protocol.isAllowed) as Write Requests and never
// touches the firmware-update (SMP) service.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'protocol.dart';

final ble = FlutterReactiveBle();

class FoundRing {
  FoundRing(this.id, this.name, this.rssi);
  final String id; // platform device id (MAC on Android, UUID on iOS)
  final String name;
  final int rssi;
}

/// Scan for advertising rings (`UH_` + 12 hex digits). A ring connected to another phone may not show.
Stream<FoundRing> scanRings() => ble
    .scanForDevices(
      withServices: const [],
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: false,
    )
    .where((d) => d.name.startsWith('UH_'))
    .map((d) => FoundRing(d.id, d.name, d.rssi));

Uuid _u(String s) => Uuid.parse(s);
String _service(String charUuid) =>
    '${charUuid.substring(0, 7)}0${charUuid.substring(8)}'; // 86f6xxx1 -> 86f6xxx0

class RingClient {
  RingClient._(this.deviceId, this.name, this._conn);

  final String deviceId, name;
  final StreamSubscription<ConnectionStateUpdate> _conn;
  final _replies = StreamController<Uint8List>.broadcast();
  final _streamPackets = StreamController<Uint8List>.broadcast();
  final _states = StreamController<BatteryState>.broadcast();
  final _disconnected = Completer<void>();
  final _subs = <StreamSubscription<List<int>>>[];
  Future<void> _lock = Future.value();

  Future<void> get disconnected => _disconnected.future;

  QualifiedCharacteristic _q(String charUuid) => QualifiedCharacteristic(
    serviceId: _u(_service(charUuid)),
    characteristicId: _u(charUuid),
    deviceId: deviceId,
  );

  static Future<RingClient> connect(String deviceId, String name) async {
    final ready = Completer<void>();
    late RingClient client;
    final conn = ble
        .connectToDevice(
          id: deviceId,
          connectionTimeout: const Duration(seconds: 20),
        )
        .listen(
          (u) {
            if (u.connectionState == DeviceConnectionState.connected &&
                !ready.isCompleted) {
              ready.complete();
            }
            if (u.connectionState == DeviceConnectionState.disconnected) {
              if (!ready.isCompleted) {
                ready.completeError(StateError('could not connect'));
              }
              if (!client._disconnected.isCompleted) {
                client._disconnected.complete();
              }
            }
          },
          onError: (Object e) =>
              ready.isCompleted ? null : ready.completeError(e),
        );
    client = RingClient._(deviceId, name, conn);
    await ready.future;
    await ble.discoverAllServices(deviceId);
    await client._subscribe();
    return client;
  }

  Future<void> _subscribe() async {
    void on(String uuid, void Function(Uint8List) f) => _subs.add(
      ble
          .subscribeToCharacteristic(_q(uuid))
          .listen(
            (v) => f(Uint8List.fromList(v)),
            onError: (Object _) {
              // the link dropped; the connection stream reports it and the controller reconnects
            },
          ),
    );

    on(respChar, _replies.add);
    on(streamChar, (p) {
      if (p.isEmpty) return;
      // Wear-log and fault-log replies arrive on the stream characteristic.
      if (p[0] == Op.wearLog || p[0] == Op.faultLog) {
        _replies.add(p);
      } else {
        _streamPackets.add(p);
      }
    });
    on(stateChar, (p) {
      try {
        _states.add(parseState(p));
      } on ProtocolError {
        // an empty record says nothing
      }
    });
    await Future<void>.delayed(
      const Duration(milliseconds: 300),
    ); // let the CCCD writes land
  }

  Stream<BatteryState> get states => _states.stream;
  Stream<LiveHr> get liveHr => _streamPackets.stream
      .where((p) => p[0] == Op.liveHrStart)
      .map(parseLiveHr);
  Stream<BreathSample> get breath => _streamPackets.stream
      .where((p) => p[0] == Op.breathingStart)
      .map(parseBreath);

  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _conn.cancel(); // cancelling the connection stream disconnects
  }

  /// Send one allowlisted command and collect replies with the same opcode: [count] replies, or (when [untilEnd])
  /// until one with a non-zero status, or until [timeout] passes without a reply.
  Future<List<Uint8List>> command(
    List<int> packet, {
    int count = 1,
    bool untilEnd = false,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final p = Uint8List.fromList(packet);
    if (!isAllowed(p)) {
      throw ArgumentError('that packet is not on the allowlist');
    }
    final run = _lock.then((_) async {
      final out = <Uint8List>[];
      final done = Completer<void>();
      Timer? quiet;
      void arm() {
        quiet?.cancel();
        quiet = Timer(timeout, () => done.isCompleted ? null : done.complete());
      }

      final sub = _replies.stream
          .where((r) => r.isNotEmpty && r[0] == p[0])
          .listen((r) {
            out.add(r);
            arm();
            if ((!untilEnd && out.length >= count) ||
                (untilEnd && r.length > 1 && r[1] != 0)) {
              if (!done.isCompleted) done.complete();
            }
          });
      arm();
      await ble.writeCharacteristicWithResponse(_q(cmdChar), value: p);
      await done.future;
      quiet?.cancel();
      await sub.cancel();
      return out;
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Uint8List> query(List<int> packet) async {
    final r = await command(packet);
    if (r.isEmpty) throw TimeoutException('no reply');
    return r.first;
  }

  Future<int> ringTime() async => parseTime(await query([Op.clock]));

  Future<StatusFlags> diag() async =>
      parseStatusFlags(await query([Op.statusFlags]));

  Future<(int?, int?)> historyBounds() async => (
    parseIndex(await query([Op.oldestRecord])),
    parseIndex(await query([Op.newestRecord])),
  );

  /// History records from [start] to the newest, page by page (7 records per page).
  Future<List<Record>> records(int start) async {
    final pages = await command([
      Op.history,
      start & 0xFF,
      start >> 8 & 0xFF,
    ], untilEnd: true);
    return [for (final pg in pages) ...parseRecords(pg)];
  }

  Future<List<LogEntry>> events() async => decodeEvents(
    await command(
      [Op.eventLog, 0x04, 0, 0],
      untilEnd: true,
      timeout: const Duration(seconds: 4),
    ),
  );

  Future<bool> setMode(BatteryMode mode) async {
    for (final op in mode.commands) {
      if (!parseReply(await query([op])).ok) return false;
    }
    return true;
  }

  Future<bool> startLiveHr() async =>
      parseReply(await query([Op.liveHrStart])).ok;
  Future<void> stopLiveHr() async =>
      query([Op.liveHrStop]).then((_) {}, onError: (_) {});
  Future<bool> startBreath() async =>
      parseReply(await query([Op.breathingStart])).ok;
  Future<bool> stopBreath() async =>
      parseReply(await query([Op.breathingStop])).ok;

  Future<String?> firmware() async =>
      parseFirmware(await query(debugPageRequest(30)));

  /// D1 turns SpO2 sensing on, D2 off (GB).
  Future<bool> setSpo2(bool on) async =>
      parseReply(await query([on ? Op.spo2On : Op.spo2Off])).ok;

  /// Read the battery/state record now instead of waiting for the next push.
  Future<BatteryState?> readState() async {
    try {
      return parseState(
        Uint8List.fromList(await ble.readCharacteristic(_q(stateChar))),
      );
    } on Object {
      return null;
    }
  }

  /// Serial number from the standard Device Information service (0x180A / 0x2A25).
  Future<String?> serial() async {
    try {
      final q = QualifiedCharacteristic(
        serviceId: Uuid.parse('180a'),
        characteristicId: Uuid.parse('2a25'),
        deviceId: deviceId,
      );
      return String.fromCharCodes(await ble.readCharacteristic(q)).trim();
    } on Object {
      return null;
    }
  }
}
