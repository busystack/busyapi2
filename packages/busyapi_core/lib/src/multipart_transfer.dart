import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'model.dart';
import 'multipart_encoding.dart';

/// RFC 2045 §§2,6 and RFC 4648. Schema strings already contain their encoding;
/// selected files contain raw octets. Serialization checks are distinct from
/// JSON Schema's annotation-only content vocabulary.
Future<Uint8List> multipartTextBytes(
  String text,
  MultipartTransferEncoding? transfer, {
  bool textual = false,
}) async {
  if (text.length >= 262144)
    return Isolate.run(() => _textBytes(text, transfer, textual));
  return _textBytes(text, transfer, textual);
}

Uint8List _textBytes(
  String text,
  MultipartTransferEncoding? transfer,
  bool textual,
) {
  final encoding = transfer?.encoding?.toLowerCase();
  if (encoding == null) return Uint8List.fromList(utf8.encode(text));
  if (transfer!.schemaEncoded) {
    final raw = _decode(text, encoding, textual);
    if (['binary', 'identity', '7bit', '8bit'].contains(encoding)) {
      return Uint8List.fromList(
        _encode(
          [raw],
          encoding,
          textual: textual,
        ).expand((chunk) => chunk).toList(),
      );
    }
    if (encoding != 'base64') return Uint8List.fromList(ascii.encode(text));
    // Preserve the encoded spelling, including valid MIME whitespace. Only
    // required transport line folding is added; decoding is not normalization.
    final bytes = <int>[];
    var column = 0;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit == 13) {
        if (index + 1 >= text.length || text.codeUnitAt(index + 1) != 10)
          _invalid();
        bytes.addAll([13, 10]);
        index++;
        column = 0;
        continue;
      }
      if (unit == 10) _invalid();
      if (column == 76) {
        bytes.addAll([13, 10]);
        column = 0;
      }
      bytes.add(unit);
      column++;
    }
    return Uint8List.fromList(bytes);
  }
  return Uint8List.fromList(
    _encode(
      [utf8.encode(text)],
      encoding,
      textual: textual,
    ).expand((chunk) => chunk).toList(),
  );
}

Stream<List<int>> multipartTransferBytes(
  Stream<List<int>> source,
  MultipartTransferEncoding transfer, {
  bool textual = false,
}) async* {
  final encoding = transfer.encoding?.toLowerCase();
  if (encoding == null || encoding == 'binary' || encoding == 'identity') {
    yield* source;
    return;
  }
  // One state spans input chunks: padding, line limits and bit groups must not
  // depend on filesystem read boundaries.
  final codec = _TransferEncoder(encoding, textual: textual);
  await for (final chunk in source) {
    final bytes = codec.add(chunk);
    if (bytes.isNotEmpty) yield bytes;
  }
  final tail = codec.finish();
  if (tail.isNotEmpty) yield tail;
}

Iterable<List<int>> _encode(
  Iterable<List<int>> source,
  String encoding, {
  bool textual = false,
}) sync* {
  final codec = _TransferEncoder(encoding, textual: textual);
  for (final chunk in source) yield codec.add(chunk);
  yield codec.finish();
}

List<int> _decode(String text, String encoding, bool textual) {
  if (encoding == 'binary' ||
      encoding == 'identity' ||
      encoding == '7bit' ||
      encoding == '8bit')
    return utf8.encode(text);
  if (text.codeUnits.any((value) => value > 127)) _invalid();
  if (encoding == 'base64' || encoding == 'base64url') {
    final value = encoding == 'base64'
        ? text.replaceAll(RegExp(r'[\r\n\t ]'), '')
        : text;
    final alphabet = encoding == 'base64'
        ? RegExp(r'^[A-Za-z0-9+/]*={0,2}$')
        : RegExp(r'^[A-Za-z0-9_-]*={0,2}$');
    if (value.length % 4 != 0 || !alphabet.hasMatch(value)) _invalid();
    try {
      return (encoding == 'base64' ? base64 : base64Url).decode(value);
    } on FormatException {
      _invalid();
    }
  }
  if (encoding == 'base16') {
    if (text.length.isOdd || !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(text))
      _invalid();
    return [
      for (var index = 0; index < text.length; index += 2)
        int.parse(text.substring(index, index + 2), radix: 16),
    ];
  }
  if (encoding == 'base32' || encoding == 'base32hex') {
    final alphabet = encoding == 'base32'
        ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
        : '0123456789ABCDEFGHIJKLMNOPQRSTUV';
    if (text.length % 8 != 0) _invalid();
    final startPadding = text.indexOf('='),
        end = startPadding < 0 ? text.length : startPadding;
    final padding = text.length - end;
    if (![0, 1, 3, 4, 6].contains(padding) ||
        text.substring(end).split('').any((value) => value != '='))
      _invalid();
    var bits = 0, value = 0;
    final result = <int>[];
    for (final unit in text.substring(0, end).codeUnits) {
      final digit = alphabet.indexOf(String.fromCharCode(unit).toUpperCase());
      if (digit < 0) _invalid();
      value = (value << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        result.add(value >> bits);
        value &= (1 << bits) - 1;
      }
    }
    if (value != 0 || {0: 0, 1: 3, 3: 1, 4: 4, 6: 2}[padding] != bits)
      _invalid();
    return result;
  }
  if (encoding == 'quoted-printable') {
    final output = <int>[];
    var column = 0;
    for (var index = 0; index < text.length; index++) {
      final unit = text.codeUnitAt(index);
      if (unit == 61) {
        if (index + 2 >= text.length) _invalid();
        final pair = text.substring(index + 1, index + 3);
        if (pair == '\r\n') {
          if (column + 1 > 76) _invalid();
          column = 0;
        } else {
          if (column + 3 > 76 || !RegExp(r'^[0-9A-F]{2}$').hasMatch(pair))
            _invalid();
          final byte = int.tryParse(pair, radix: 16);
          if (byte == null) _invalid();
          output.add(byte);
          column += 3;
        }
        index += 2;
      } else if (unit == 13 &&
          index + 1 < text.length &&
          text.codeUnitAt(index + 1) == 10) {
        if (!textual) _invalid();
        output.addAll([13, 10]);
        index++;
        column = 0;
      } else {
        if (unit != 9 && unit != 32 && !(unit >= 33 && unit <= 126) ||
            ++column > 76 ||
            (unit == 9 || unit == 32) &&
                (index + 1 == text.length || text.codeUnitAt(index + 1) == 13))
          _invalid();
        output.add(unit);
      }
    }
    return output;
  }
  throw CoreFailure(
    'request.multipart.encoding.unsupported',
    'No native codec exists for this captured transfer encoding.',
  );
}

class _TransferEncoder {
  _TransferEncoder(this.encoding, {this.textual = false}) {
    if (encoding == 'base64' || encoding == 'base64url') {
      base64Sink = (encoding == 'base64' ? base64 : base64Url).encoder
          .startChunkedConversion(
            StringConversionSink.fromStringSink(_EncodedSink(this)),
          );
    }
  }
  final String encoding;
  final bool textual;
  ByteConversionSink? base64Sink;
  final _pending = <int>[];
  var column = 0, bits = 0, value = 0, symbols = 0;
  bool carriage = false;

  void encoded(String text) {
    for (final unit in text.codeUnits) {
      if (encoding == 'base64' && column == 76) {
        _pending.addAll([13, 10]);
        column = 0;
      }
      _pending.add(unit);
      column++;
    }
  }

  List<int> add(List<int> bytes) {
    if (base64Sink != null) {
      base64Sink!.add(bytes);
    } else
      for (final byte in bytes) {
        switch (encoding) {
          case 'binary':
          case 'identity':
            _pending.add(byte);
          case '7bit':
          case '8bit':
            if (byte == 0 ||
                encoding == '7bit' && byte > 127 ||
                carriage && byte != 10 ||
                byte == 10 && !carriage)
              _invalid();
            if (byte == 13)
              carriage = true;
            else if (byte == 10) {
              carriage = false;
              column = 0;
            } else if (++column > 998)
              _invalid();
            _pending.add(byte);
          case 'base16':
            encoded(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
          case 'base32':
          case 'base32hex':
            final alphabet = encoding == 'base32'
                ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
                : '0123456789ABCDEFGHIJKLMNOPQRSTUV';
            value = (value << 8) | byte;
            bits += 8;
            while (bits >= 5) {
              bits -= 5;
              encoded(alphabet[(value >> bits) & 31]);
              symbols++;
            }
            value &= (1 << bits) - 1;
          case 'quoted-printable':
            if (textual && carriage) {
              if (byte != 10) _invalid();
              _pending.addAll([13, 10]);
              carriage = false;
              column = 0;
            } else if (textual && byte == 13) {
              carriage = true;
            } else {
              if (textual && byte == 10) _invalid();
              if (column + 3 > 75) {
                _pending.addAll([61, 13, 10]);
                column = 0;
              }
              encoded(
                '=${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}',
              );
            }
          default:
            throw CoreFailure(
              'request.multipart.encoding.unsupported',
              'No native codec exists for this captured transfer encoding.',
            );
        }
      }
    return _take();
  }

  List<int> finish() {
    if (carriage) _invalid();
    base64Sink?.close();
    if (encoding == 'base32' || encoding == 'base32hex') {
      final alphabet = encoding == 'base32'
          ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
          : '0123456789ABCDEFGHIJKLMNOPQRSTUV';
      if (bits > 0) {
        encoded(alphabet[value << (5 - bits)]);
        symbols++;
      }
      while (symbols % 8 != 0) {
        encoded('=');
        symbols++;
      }
    }
    return _take();
  }

  List<int> _take() {
    final bytes = Uint8List.fromList(_pending);
    _pending.clear();
    return bytes;
  }
}

class _EncodedSink implements StringSink {
  _EncodedSink(this.owner);
  final _TransferEncoder owner;
  @override
  void write(Object? object) => owner.encoded('$object');
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
}

Never _invalid() => throw CoreFailure(
  'request.multipart.encoded-input',
  'The multipart value cannot be represented by its declared transfer encoding.',
);
