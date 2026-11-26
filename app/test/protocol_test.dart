// Every frame here is built from invented numbers (frames.dart); none comes from a ring.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loophole/ring/protocol.dart';

import 'frames.dart';

Uint8List record(
  int index, {
  int hr = 111,
  int rmssd = 22,
  int spo2 = 99,
  double skin = 30.5,
}) => layout(32, {
  0: u32(fakeTime + index),
  4: [hr],
  5: [rmssd],
  6: [spo2],
  7: [3],
  12: f32(skin),
  16: f32(20.25),
  24: u16(777),
  26: u16(4321),
  28: [33],
  29: [12],
  30: u16(index),
});

Record one(Uint8List r) => parseRecords(reply(0x04, r)).single;

void main() {
  test('crc16: published check value, and every frame kind', () {
    expect(crc16(ascii.encode('123456789')), 0x29B1); // public-ok: CRC check
    final frames = [
      reply(0x05, u32(fakeTime)),
      stream(0x52, List.generate(14, (i) => i)),
      debugPage(15, List.generate(24, (i) => i)),
      frame([0x14, 0, 1, 1, 0], [17]),
      frame([0x10, 0, 1, 2, 0], List.generate(25, (i) => i)),
      frame([0x0f, 0, 1, 4, 0], List.generate(8, (i) => i)),
    ];
    for (final f in frames) {
      expect(crcOk(f), isTrue, reason: hex(f));
      f[f.length - 1] ^= 1;
      expect(crcOk(f), isFalse, reason: hex(f));
    }
  });

  test('allowlist: every one and two byte packet, then longer shapes', () {
    bool ok(List<int> p) => isAllowed(Uint8List.fromList(p));
    const one = {
      ...{0x05, 0x07, 0x08, 0x09, 0x20},
      ...{0x52, 0x53, 0x59, 0x72, 0x74},
      ...{0xA1, 0xD1, 0xD2, 0xD3, 0xD4},
      ...{0xFB, 0xFC},
    };
    expect({
      for (var a = 0; a < 256; a++)
        if (ok([a])) a,
    }, one);
    expect(
      {
        for (var a = 0; a < 256; a++)
          for (var b = 0; b < 256; b++)
            if (ok([a, b])) (a, b),
      },
      {(0x0f, 1), for (var g = 2; g <= 6; g++) (0x80, g)},
    );
    expect(ok([]), isFalse);
    expect(
      [
        for (var i = 0; i < 256; i++)
          if (ok([0x79, 0x29, 0x07, i, 0])) i,
      ],
      [0, 4, 13, 14, 15, 28, 29, 30], // public-ok: page numbers
    );
    for (final p in [
      [0x04, 1, 0],
      [0x0f, 0x04, 0, 0],
      [0x79, 0x29, 0x07, 14, 0],
    ]) {
      expect(ok(p), isTrue, reason: '$p');
      expect(ok([...p, 0]), isFalse, reason: '$p');
    }
    expect(ok([0x79, 0x29, 0x07, 14, 1]), isFalse);
    expect(ok([0x79, 0x28, 0x07, 14, 0]), isFalse);
    expect(ok([0x0f, 0x05, 0, 0]), isFalse);
    expect(ok([0x02, ...u32(1)]), isFalse);
  });

  test('errors never carry the bytes', () {
    final bad = Uint8List.fromList([0xEE, 0, 1, ...List.filled(8, 0xC7)]);
    for (final parse in <Object? Function(Uint8List)>[
      parseTime,
      parseIndex,
      parseRecords,
      parseLiveHr,
      parseBreath,
      parseStatusFlags,
    ]) {
      expect(
        () => parse(bad),
        throwsA(
          isA<ProtocolError>().having(
            (e) => '$e',
            'text',
            isNot(contains('c7c7')),
          ),
        ),
      );
    }
  });

  test('clock and index replies', () {
    expect(parseTime(reply(0x05, u32(fakeTime))), fakeTime);
    expect(parseIndex(reply(0x07, u16(258))), 258);
    expect(parseIndex(reply(0x08, u16(4660))), 4660);
    expect(parseIndex(reply(0x08, [], result: 0xEE)), isNull);
    expect(() => parseTime(reply(0x07, u32(1))), throwsA(isA<ProtocolError>()));
    expect(
      () => parseIndex(reply(0x05, u16(1))),
      throwsA(isA<ProtocolError>()),
    );
  });

  test('state record', () {
    final s = parseState(
      layout(76, {
        0: [77],
        1: u32(-120000),
        5: [3],
        6: [21],
        7: u16be(4100),
        15: u16be(99),
        29: u32(fakeTime),
      }),
    );
    expect(
      [s.batteryPct, s.microamps, s.tempC, s.millivolts, s.cellMah],
      [77, -120000, 21, 4100, 99],
    );
    expect((s.charging, s.timestamp), (true, fakeTime));
    expect(() => parseState(Uint8List(76)), throwsA(isA<ProtocolError>()));
    expect(
      parseState(
        layout(76, {
          0: [50],
        }),
      ).timestamp,
      isNull,
    );
    expect(
      parseState(
        layout(76, {
          0: [50],
          29: [1],
        }),
      ).timestamp,
      1,
    );
  });

  test('history record: every field', () {
    final r = one(record(513));
    expect(
      [r.index, r.timestamp, r.hr, r.rmssdMs, r.spo2, r.pulseConfidence],
      [513, fakeTime + 513, 111, 22, 99, 3],
    );
    expect(
      [r.skinTempC, r.secondTempC, r.motion, r.steps, r.byte28],
      [30.5, 20.25, 777, 4321, 33],
    );
    expect(r.byte29, 12);
    expect(one(record(1, skin: double.nan)).skinTempC, isNull);
  });

  test('history page of seven, and the end marker', () {
    final recs = parseRecords(
      reply(0x04, [
        for (var i = 0; i < 7; i++) ...record(100 + i, hr: 100 + i),
      ], detail: 7),
    );
    expect(recs.map((r) => r.index), [for (var i = 0; i < 7; i++) 100 + i]);
    expect(recs.map((r) => r.hr), [for (var i = 0; i < 7; i++) 100 + i]);
    expect(parseRecords(reply(0x04, [], result: 0x13, detail: 0)), isEmpty);
  });

  test('what counts as a reading', () {
    final ok = one(record(1));
    expect(
      [ok.validHr, ok.validHrv, ok.validSpo2, ok.validSkinTemp],
      [111, 22, 99, 30.5],
    );

    final off = one(record(1, hr: 0));
    expect(off.worn, isFalse);
    expect([
      off.validHr,
      off.validHrv,
      off.validSpo2,
      off.validSkinTemp,
    ], everyElement(isNull));

    expect(one(record(1, hr: 24)).validHr, isNull);
    expect(one(record(1, hr: 25)).validHr, 25);
    expect(one(record(1, rmssd: 0)).validHrv, isNull);
    expect(one(record(1, spo2: 0)).validSpo2, isNull);
    expect(one(record(1, spo2: 100)).validSpo2, 100);
    expect(one(record(1, spo2: 101)).validSpo2, isNull);
    expect(one(record(1, skin: 0)).validSkinTemp, isNull);
    expect(one(record(1, skin: 44.5)).validSkinTemp, isNull);
  });

  test('live HR and breathing samples', () {
    final h = parseLiveHr(
      stream(
        0x52,
        layout(14, {
          0: u32(fakeTime),
          4: [123],
          5: [7],
          6: [45],
          8: u16(2468),
          10: f32(31.25),
        }),
      ),
    );
    expect(
      [h.timestamp, h.hr, h.pulseConfidence, h.rmssdMs, h.steps, h.skinTempC],
      [fakeTime, 123, 7, 45, 2468, 31.25],
    );
    final b = parseBreath(
      stream(
        0x72,
        layout(22, {
          0: u32(fakeTime),
          4: [98],
          5: [6],
          6: [54],
          7: [76],
          8: f32(32.5),
        }),
      ),
    );
    expect(
      [b.timestamp, b.hr, b.pulseConfidence, b.rmssdMs, b.sdnnMs],
      [fakeTime, 98, 6, 54, 76],
    );
    expect(b.skinTempC, 32.5);
    expect(() => parseLiveHr(reply(0x52, [0])), throwsA(isA<ProtocolError>()));
  });

  test('commands that change the ring', () {
    expect((Op.spo2On, Op.spo2Off), (0xd1, 0xd2));
    expect((Op.criticalOn, Op.criticalOff), (0xd3, 0xd4));
    expect((Op.chillOn, Op.chillOff), (0xfb, 0xfc));
    expect((Op.liveHrStart, Op.liveHrStop), (0x52, 0x53));
    expect((Op.breathingStart, Op.breathingStop), (0x72, 0x74));
  });

  test('a short history page keeps its whole records', () {
    final page = reply(0x04, [...record(1), ...record(2)], detail: 2);
    expect(parseRecords(page.sublist(0, 60)).map((r) => r.index), [1]);
  });

  test('modes and status flags', () {
    expect(BatteryMode.chill.commands, [0xd4, 0xfb]);
    expect(BatteryMode.turbo.commands, [0xd4, 0xfc]);
    expect(BatteryMode.critical.commands, [0xd3]);
    StatusFlags flags(Map<int, List<int>> f) =>
        parseStatusFlags(reply(0x20, layout(26, f)));
    expect(flags({}).mode, BatteryMode.turbo);
    expect(
      flags({
        10: [1],
      }).mode,
      BatteryMode.chill,
    );
    expect(
      flags({
        10: [1],
        11: [1],
      }).mode,
      BatteryMode.critical,
    );
    expect(
      flags({
        12: [1],
      }).mode,
      BatteryMode.critical,
    );
    expect(
      flags({
        15: [1],
      }).spo2On,
      isTrue,
    );
    expect(
      flags({
        9: [1],
      }).chillRunning,
      isTrue,
    );
  });

  test('event log', () {
    const anchor = 1 << 30, event = 3 << 30;
    Uint8List page(List<int> words) =>
        frame([0x0f, 0, 1, 4, 0], [for (final w in words) ...u32(w)]);
    final ev = decodeEvents([
      page([anchor | 1000, event | 32 << 22 | 60]),
      page([event | 86 << 22 | 120]),
      reply(0x0f, [], result: 0xff),
    ]);
    expect(ev.map((e) => e.code), [null, 32, 86]);
    expect(ev.map((e) => e.time - eventsBaseEpoch), [1000, 1060, 1120]);
    expect(
      decodeEvents([
        page([event | 32 << 22 | 5]),
      ]).single.valid,
      isFalse,
    ); // no anchor yet
    expect(
      DateTime.fromMillisecondsSinceEpoch(eventsBaseEpoch * 1000, isUtc: true),
      DateTime.utc(2026),
    );
  });

  test('event word: full width of code and offset', () {
    const code = 0xFE, offset = (1 << 22) - 1;
    final ev = decodeEvents([
      frame(
        [0x0f, 0, 1, 4, 0],
        [...u32(1 << 30 | 5), ...u32(3 << 30 | code << 22 | offset)],
      ),
    ]);
    expect((ev[1].code, ev[1].time - ev[0].time), (code, offset));
    expect(crcOk(frame([0x0f, 0, 1, 4, 0], u32(7))), isTrue);
  });

  test('every event label', () {
    expect(
      {
        for (var c = 0; c < 256; c++)
          if (friendlyEvent(c) != null) c: friendlyEvent(c),
      },
      {
        23: 'Daily restart',
        26: 'Restarted after hanging',
        32: 'Ring powered on',
        36: 'Firmware updated',
        38: 'Power dipped',
        40: 'Restarted after hanging',
        49: 'Paired with a phone',
        79: 'Low-power mode on',
        80: 'Low-power mode off',
        81: 'Chill mode on',
        82: 'Chill mode off',
        83: 'Charging',
        84: 'Battery down 10%',
        85: 'Battery up 10%',
        86: 'Battery critically low',
        87: 'SpO2 sensing on',
        88: 'SpO2 sensing off',
        89: 'Pairing changed',
        97: 'Factory reset',
        98: 'Firmware updated',
        103: 'Firmware updated',
        104: 'Firmware updated',
      },
    );
  });

  test('event labels', () {
    expect(friendlyEvent(86), 'Battery critically low');
    expect(eventName(86), 'Battery critically low');
    expect(friendlyEvent(200), isNull);
    expect(eventName(200), 'Event 200');
  });

  test('firmware version', () {
    expect(
      parseFirmware(debugPage(30, layout(40, {20: u32(0x090A0B0C)}))),
      '09.10.11.12',
    );
    expect(parseFirmware(debugPage(30, layout(10, {}))), isNull);
  });
}
