// Ring BLE protocol: framing, parsers and the command allowlist. Same layouts as loophole_ring/protocol.py.
// notes/protocol.md says where each fact comes from. Error text never includes the bytes: a frame can hold an ID.
import 'dart:typed_data';

const _base = '-f706-58a0-95b2-1fb9261e4dc7';
const stateChar = '86f61001$_base'; // notify: 76-byte state record
const cmdChar = '86f65001$_base'; // write requests
const respChar = '86f65002$_base'; // notify: command replies
const streamChar =
    '86f66001$_base'; // notify: live HR, breathing, PPG, 0x9A/0xA1 replies
const smpService =
    '8d53dc1d-1db7-4cd3-868b-8a527460aa84'; // firmware update: never touched

abstract final class Op {
  static const history = 0x04;
  static const clock = 0x05;
  static const oldestRecord = 0x07;
  static const newestRecord = 0x08;
  static const recordRange = 0x09;
  static const eventLog = 0x0F;
  static const statusFlags = 0x20;
  static const liveHrStart = 0x52;
  static const liveHrStop = 0x53;
  static const sensorMode = 0x59;
  static const breathingStart = 0x72;
  static const breathingStop = 0x74;
  static const debugPage = 0x79;
  static const configPage = 0x80;
  static const wearLog = 0x9A;
  static const faultLog = 0xA1;
  static const spo2On = 0xD1;
  static const spo2Off = 0xD2;
  static const criticalOn = 0xD3;
  static const criticalOff = 0xD4;
  static const chillOn = 0xFB;
  static const chillOff = 0xFC;
}

const resultOk = 0x00;
const resultNoData = 0xEE;

/// Commands that are one byte and nothing else. Everything else must match an exact shape in [isAllowed].
/// Never sent: 0x02 set clock, 0x0a/0x10 sleep window and clock management, 0x70 airplane, 0x98 reset, 0xF0 firmware
/// update, 0xBF bond removal, and the SMP service.
const _oneByte = {
  Op.clock,
  Op.oldestRecord,
  Op.newestRecord,
  Op.recordRange,
  Op.statusFlags,
  Op.liveHrStart,
  Op.liveHrStop,
  Op.sensorMode,
  Op.breathingStart,
  Op.breathingStop,
  Op.faultLog,
  Op.spo2On,
  Op.spo2Off,
  Op.criticalOn,
  Op.criticalOff,
  Op.chillOn,
  Op.chillOff,
};
const _debugPages = {0, 4, 13, 14, 15, 28, 29, 30}; // public-ok: page numbers

bool isAllowed(Uint8List p) {
  if (p.isEmpty) return false;
  final op = p[0];
  if (_oneByte.contains(op)) return p.length == 1;
  return switch (op) {
    Op.history => p.length == 3,
    Op.eventLog =>
      (p.length == 2 && p[1] == 0x01) || (p.length == 4 && p[1] == 0x04),
    Op.debugPage =>
      p.length == 5 &&
          p[1] == 0x29 &&
          p[2] == 0x07 &&
          _debugPages.contains(p[3] | p[4] << 8),
    Op.configPage => p.length == 2 && p[1] >= 2 && p[1] <= 6,
    _ => false,
  };
}

class ProtocolError implements Exception {
  ProtocolError(this.message);
  final String message;
  @override
  String toString() => 'ProtocolError: $message';
}

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

int _u16(Uint8List b, int o) => b[o] | b[o + 1] << 8;
int _u32(Uint8List b, int o) =>
    ByteData.sublistView(b).getUint32(o, Endian.little);
int _i32(Uint8List b, int o) =>
    ByteData.sublistView(b).getInt32(o, Endian.little);
double? _f32(Uint8List b, int o) {
  final v = ByteData.sublistView(b).getFloat32(o, Endian.little);
  return v.isNaN ? null : (v * 100).roundToDouble() / 100;
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF). What it covers: [crcOk].
int crc16(List<int> data) {
  var c = 0xFFFF;
  for (final b in data) {
    c ^= b << 8;
    for (var i = 0; i < 8; i++) {
      c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
    }
  }
  return c;
}

/// Replies that repeat a two-byte sub-command (or page number) before the payload. 0x10 is never sent.
const _subCommandReplies = {Op.eventLog, 0x10, 0x14, Op.debugPage};

/// The payload starts after 5 bytes for [_subCommandReplies], after 3 for everything else.
bool crcOk(Uint8List raw) {
  if (raw.isEmpty) return false;
  final start = _subCommandReplies.contains(raw[0]) ? 5 : 3;
  if (raw.length < start + 2) return false;
  return crc16(raw.sublist(start, raw.length - 2)) == _u16(raw, raw.length - 2);
}

class Reply {
  Reply(this.opcode, this.result, this.detail, this.data);
  final int opcode, result, detail;
  final Uint8List data; // after the 3-byte header, CRC included
  bool get ok => result == resultOk;
}

Reply parseReply(Uint8List raw) {
  if (raw.length < 3) {
    throw ProtocolError('a reply needs 3 header bytes, got ${raw.length}');
  }
  return Reply(raw[0], raw[1], raw[2], raw.sublist(3));
}

Reply _expect(Uint8List raw, Set<int> opcodes) {
  final r = parseReply(raw);
  if (!opcodes.contains(r.opcode)) {
    throw ProtocolError('got opcode ${r.opcode} where another was expected');
  }
  return r;
}

void _need(Uint8List data, int size, String what) {
  if (data.length < size) {
    throw ProtocolError('$what: ${data.length} of $size bytes');
  }
}

/// `05 00 01 <u32 unix time> <crc>`
int parseTime(Uint8List raw) {
  final r = _expect(raw, {Op.clock});
  if (!r.ok) throw ProtocolError('clock request refused: ${r.result}');
  _need(r.data, 4, 'clock reply');
  return _u32(r.data, 0);
}

/// `07|08 00 01 <u16 index> <crc>`; null when the ring has no data.
int? parseIndex(Uint8List raw) {
  final r = _expect(raw, {Op.oldestRecord, Op.newestRecord});
  if (r.result == resultNoData) return null;
  if (!r.ok) throw ProtocolError('index request refused: ${r.result}');
  _need(r.data, 2, 'index reply');
  return _u16(r.data, 0);
}

/// Battery and charging state pushed on [stateChar].
class BatteryState {
  BatteryState({
    required this.batteryPct,
    required this.microamps,
    required this.chargeState,
    required this.tempC,
    this.millivolts,
    this.cellMah,
    this.timestamp,
  });
  final int batteryPct, microamps, chargeState, tempC;
  final int? millivolts, cellMah, timestamp;
  bool get charging => chargeState == 3;
}

BatteryState parseState(Uint8List raw) {
  if (raw.length < 7 || raw.every((b) => b == 0)) {
    throw ProtocolError('the state record is empty or cut off');
  }
  int? be(int o) => raw.length >= o + 2 ? raw[o] << 8 | raw[o + 1] : null;
  final ts = raw.length >= 33 ? _u32(raw, 29) : 0;
  return BatteryState(
    batteryPct: raw[0],
    microamps: _i32(raw, 1),
    chargeState: raw[5],
    tempC: raw[6],
    millivolts: be(7),
    cellMah: be(15),
    timestamp: ts == 0 ? null : ts,
  );
}

/// One 32-byte history record. Field offsets are in [_record].
class Record {
  Record({
    required this.index,
    required this.timestamp,
    required this.hr,
    required this.rmssdMs,
    required this.spo2,
    required this.pulseConfidence,
    required this.skinTempC,
    required this.secondTempC,
    required this.motion,
    required this.steps,
    required this.byte28,
    required this.byte29,
  });
  final int index,
      timestamp,
      hr,
      rmssdMs,
      spo2,
      pulseConfidence,
      motion,
      steps,
      byte28, // raw: the sources disagree about 28 and 29
      byte29;
  final double? skinTempC, secondTempC;

  // What counts as a reading, from first principles rather than from any app:
  // - heart rate: 0 means not measured. Below 25 a minute is under the slowest resting rates seen in healthy adults.
  // - a record only counts as worn when it has a heart rate: off the finger the ring usually repeats its last HRV value.
  // - HRV: 0 means not measured; the byte can't hold anything else that is obviously wrong.
  // - SpO2 is a percentage, so over 100 can't be a reading (the ring sends that with SpO2 sensing off).
  // - skin temperature: the ring sends 0.0 in empty records. In degrees Celsius, live skin isn't below 10, and 44 burns it.
  bool get worn => hr >= 25;
  int? get validHr => worn ? hr : null;
  int? get validHrv => worn && rmssdMs > 0 ? rmssdMs : null;
  int? get validSpo2 => worn && spo2 >= 1 && spo2 <= 100 ? spo2 : null;
  double? get validSkinTemp =>
      (worn && skinTempC != null && skinTempC! >= 10 && skinTempC! <= 44)
      ? skinTempC
      : null;
}

/// `04 00 <count> <count x 32-byte records> <crc>`; results ee and 13 mean none and end of data.
List<Record> parseRecords(Uint8List raw) {
  final r = _expect(raw, {Op.history});
  if (!r.ok) return const [];
  return [
    for (var i = 0; i < r.detail; i++)
      if ((i + 1) * 32 <= r.data.length) // a short page keeps its whole records
        _record(Uint8List.sublistView(r.data, i * 32, (i + 1) * 32)),
  ];
}

Record _record(Uint8List b) => Record(
  timestamp: _u32(b, 0),
  hr: b[4],
  rmssdMs: b[5],
  spo2: b[6],
  pulseConfidence: b[7],
  skinTempC: _f32(b, 12),
  secondTempC: _f32(b, 16),
  motion: _u16(b, 24),
  steps: _u16(b, 26),
  byte28: b[28],
  byte29: b[29],
  index: _u16(b, 30),
);

/// `<opcode> <u16 length> <payload> <crc>` on [streamChar] -> payload.
Uint8List _streamPayload(Uint8List raw, int opcode, int size) {
  _need(raw, 3, 'stream frame');
  if (raw[0] != opcode) {
    throw ProtocolError('got opcode ${raw[0]} where another was expected');
  }
  final end = 3 + _u16(raw, 1);
  final payload = raw.sublist(3, end < raw.length ? end : raw.length);
  _need(payload, size, 'stream payload');
  return payload;
}

/// Live sample: time, heart rate, confidence, RMSSD, one unknown byte, steps u16, skin temperature f32.
class LiveHr {
  LiveHr(
    this.timestamp,
    this.hr,
    this.pulseConfidence,
    this.rmssdMs,
    this.steps,
    this.skinTempC,
  );
  final int timestamp, hr, pulseConfidence, rmssdMs, steps;
  final double? skinTempC;
}

LiveHr parseLiveHr(Uint8List raw) {
  final b = _streamPayload(raw, Op.liveHrStart, 14);
  return LiveHr(_u32(b, 0), b[4], b[5], b[6], _u16(b, 8), _f32(b, 10));
}

/// Breathing sample: time, heart rate, confidence, RMSSD, SDNN, skin temperature f32. The rest of the 22-byte payload
/// stayed zero in all my samples, so it isn't decoded.
class BreathSample {
  BreathSample(
    this.timestamp,
    this.hr,
    this.pulseConfidence,
    this.rmssdMs,
    this.sdnnMs,
    this.skinTempC,
  );
  final int timestamp, hr, pulseConfidence, rmssdMs, sdnnMs;
  final double? skinTempC;
}

BreathSample parseBreath(Uint8List raw) {
  final b = _streamPayload(raw, Op.breathingStart, 12);
  return BreathSample(_u32(b, 0), b[4], b[5], b[6], b[7], _f32(b, 8));
}

/// Battery modes are command pairs.
enum BatteryMode {
  turbo([Op.criticalOff, Op.chillOff]),
  chill([Op.criticalOff, Op.chillOn]),
  critical([Op.criticalOn]);

  const BatteryMode(this.commands);
  final List<int> commands;
}

/// 0x20 status flags.
class StatusFlags {
  StatusFlags(
    this.chillOn,
    this.chillRunning,
    this.criticalOn,
    this.criticalFromLowBattery,
    this.spo2On,
  );
  final bool chillOn, chillRunning, criticalOn, criticalFromLowBattery, spo2On;

  BatteryMode get mode => criticalOn || criticalFromLowBattery
      ? BatteryMode.critical
      : (chillOn ? BatteryMode.chill : BatteryMode.turbo);
}

StatusFlags parseStatusFlags(Uint8List raw) {
  if (!_expect(raw, {Op.statusFlags}).ok) {
    throw ProtocolError('status flags refused');
  }
  _need(raw, 19, 'status flags');
  return StatusFlags(
    raw[13] != 0,
    raw[12] != 0,
    raw[14] != 0,
    raw[15] != 0,
    raw[18] != 0,
  );
}

// --- event log (0x0F 04) ------------------------------------------------------------------------------------
final eventsBaseEpoch = DateTime.utc(2026).millisecondsSinceEpoch ~/ 1000;

class LogEntry {
  LogEntry(this.code, this.time, this.valid);
  final int? code; // null = epoch anchor
  final int time; // unix seconds
  final bool valid;
}

/// Pages `0f 00 01 04 00 <words> <crc>`; bit 31 event/anchor, bit 30 valid, anchors count seconds from 2026-01-01,
/// events carry an 8-bit code (bits 22-29) and seconds after the latest anchor (bits 0-21).
List<LogEntry> decodeEvents(List<Uint8List> pages) {
  final out = <LogEntry>[];
  int? anchor;
  for (final pg in pages) {
    if (pg.length <= 7 || pg[1] != 0) continue;
    final data = Uint8List.sublistView(pg, 5, pg.length - 2);
    for (var i = 0; i + 3 < data.length; i += 4) {
      final w = _u32(data, i);
      final valid = (w >> 30 & 1) == 1;
      if (w >> 31 == 0) {
        final t = (w & 0x3FFFFFFF) + eventsBaseEpoch;
        if (valid) anchor = t;
        out.add(LogEntry(null, t, valid));
      } else {
        out.add(
          LogEntry(
            (w >> 22) & 0xFF,
            (anchor ?? eventsBaseEpoch) + (w & 0x3FFFFF),
            valid && anchor != null,
          ),
        );
      }
    }
  }
  return out;
}

/// Event codes this project shows; null = not one we know, hidden by default.
/// Where the meanings come from: notes/protocol.md.
String? friendlyEvent(int? code) => switch (code) {
  23 => 'Daily restart',
  26 || 40 => 'Restarted after hanging',
  32 => 'Ring powered on',
  36 || 98 || 103 || 104 => 'Firmware updated',
  38 => 'Power dipped',
  49 => 'Paired with a phone',
  79 => 'Low-power mode on',
  80 => 'Low-power mode off',
  81 => 'Chill mode on',
  82 => 'Chill mode off',
  83 => 'Charging',
  84 => 'Battery down 10%',
  85 => 'Battery up 10%',
  86 => 'Battery critically low',
  87 => 'SpO2 sensing on',
  88 => 'SpO2 sensing off',
  89 => 'Pairing changed',
  97 => 'Factory reset',
  _ => null,
};

/// Label for the "All" view of the event log.
String eventName(int? code) =>
    friendlyEvent(code) ?? (code == null ? 'Time mark' : 'Event $code');

/// `79 29 07 <u16 page>` debug query.
Uint8List debugPageRequest(int page) =>
    Uint8List.fromList([Op.debugPage, 0x29, 0x07, page & 0xFF, page >> 8]);

/// 0x79 page 30: firmware version as `aa.bb.cc.dd` from the u32 at payload offset 20.
String? parseFirmware(Uint8List raw) {
  if (raw.length < 7 + 24 || raw[0] != Op.debugPage || raw[1] != 0) return null;
  final p = Uint8List.sublistView(raw, 5, raw.length - 2);
  if (p.length < 24) return null;
  final v = _u32(p, 20);
  String two(int x) => x.toString().padLeft(2, '0');
  return '${two(v >> 24 & 0xFF)}.${two(v >> 16 & 0xFF)}.${two(v >> 8 & 0xFF)}.${two(v & 0xFF)}';
}
