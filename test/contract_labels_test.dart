import 'package:busyapi/src/app/contract_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bounded identity labels preserve complete source and non-BMP boundaries',
    () {
      const short = '/Model/雪😀';
      expect(contractIdentityLabel(short), short);
      final source = '${'a' * 479}😀${'b' * 10000}';
      expect(contractIdentityLabel(source), '${'a' * 479}…');
      expect(contractIdentityLabel(source, limit: 481), '${'a' * 479}😀…');
      expect(source.length, 10481);
    },
  );
}
