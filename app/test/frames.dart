// Builds ring frames for the tests from invented numbers: fields are placed by offset, and the CRC is written a
// different way from lib/ring/protocol.dart, so a mistake in the decoder isn't repeated here.
import 'dart:typed_data';

const fakeTime = 1000000000; // September 2001, long before any of these rings

int crcCcittFalse(List<int> data) {
  var c = 0xFFFF;
  for (final b in data) {
    var x = (c >> 8) ^ b;
    x ^= x >> 4;
    c = ((c << 8) ^ (x << 12) ^ (x << 5) ^ x) & 0xFFFF;
  }
  return c;
}

Uint8List frame(List<int> head, List<int> payload) {
  final c = crcCcittFalse(payload);
  return Uint8List.fromList([...head, ...payload, c & 0xFF, c >> 8]);
}

Uint8List reply(int op, List<int> payload, {int result = 0, int detail = 1}) =>
    frame([op, result, detail], payload);

Uint8List stream(int op, List<int> payload) =>
    frame([op, payload.length & 0xFF, payload.length >> 8], payload);

Uint8List debugPage(int page, List<int> payload) =>
    frame([0x79, 0, 1, page & 0xFF, page >> 8], payload);

/// [size] zero bytes with each field written at its offset.
Uint8List layout(int size, Map<int, List<int>> fields) {
  final out = Uint8List(size);
  fields.forEach((o, v) => out.setAll(o, v));
  return out;
}

List<int> u16(int v) => [v & 0xFF, v >> 8 & 0xFF];
List<int> u16be(int v) => [v >> 8 & 0xFF, v & 0xFF];
List<int> u32(int v) => [for (var i = 0; i < 32; i += 8) v >> i & 0xFF];
List<int> f32(double v) => Float32List.fromList([v]).buffer.asUint8List();
