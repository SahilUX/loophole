// What the serial number in the standard Device Information service (0x2A25) says about the ring.
// Serials are dash-separated; one segment is a two-letter finish code plus two digits, most likely the ring size
// (inferred from one ring, unproven). There is no table of finish names: the code is shown as it is.
class RingIdentity {
  RingIdentity({this.finishCode, this.size});
  final String? finishCode;
  final int? size;
}

RingIdentity parseIdentity(String serial) {
  final found = serial
      .trim()
      .toUpperCase()
      .split('-')
      .map(RegExp(r'^([A-Z]{2})(\d{2})$').firstMatch)
      .nonNulls
      .toList();
  if (found.length != 1) return RingIdentity(); // missing or ambiguous
  final m = found.single;
  return RingIdentity(finishCode: m[1], size: int.parse(m[2]!));
}
