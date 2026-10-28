import 'dart:convert' as convert;
import 'dart:io';

import 'model.dart';

enum RequestTextEncoding {
  utf8(convert.utf8, null, 'UTF-8'),
  ascii(convert.ascii, 0x7f, 'ASCII'),
  latin1(convert.latin1, 0xff, 'ISO-8859-1');

  const RequestTextEncoding(this._codec, this._maximumCodePoint, this._label);

  final convert.Encoding _codec;
  final int? _maximumCodePoint;
  final String _label;

  static RequestTextEncoding forMedia(
    String mediaType, {
    bool rawBody = false,
  }) {
    final type = ContentType.parse(mediaType);
    final charset = type.charset?.toLowerCase();
    if (charset == null || charset == 'utf-8') return utf8;
    if (charset == 'us-ascii') return ascii;
    // RFC 2046 §4.1.2 / RFC 9110 §8.3.2: the declared charset selects
    // entity bytes. URI/form/MIME field codecs retain their own policies.
    if (rawBody &&
        type.mimeType == 'text/plain' &&
        (charset == 'iso-8859-1' || charset == 'latin1')) {
      return latin1;
    }
    throw CoreFailure(
      'request.charset.unsupported',
      'Choose UTF-8; this request charset is unsupported.',
    );
  }

  void validate(Iterable<String> values) {
    final maximum = _maximumCodePoint;
    if (maximum != null &&
        values.any((value) => value.runes.any((rune) => rune > maximum))) {
      throw CoreFailure(
        'request.charset',
        'The selected $_label charset cannot encode this value.',
      );
    }
  }

  List<int> encode(String value) {
    validate([value]);
    return _codec.encode(value);
  }
}
