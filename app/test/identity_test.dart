import 'package:flutter_test/flutter_test.dart';
import 'package:loophole/ring/identity.dart';

void main() {
  test('finish code and size come from the one matching segment', () {
    final id = parseIdentity('zz-QQ12-fake');
    expect((id.finishCode, id.size), ('QQ', 12));
  });

  test('no match, or more than one, gives nothing', () {
    for (final s in ['', 'fake', 'QQ1-fake', 'QQ12-XX34']) {
      final id = parseIdentity(s);
      expect((id.finishCode, id.size), (null, null), reason: s);
    }
  });
}
