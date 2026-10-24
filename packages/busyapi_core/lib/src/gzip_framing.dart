import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// Verifies received RFC 1952 member boundaries. The SDK remains the decoder
/// and CRC verifier; its public API does not expose inflate's end-of-member
/// state. This bounded framing pass produces no decoded data and adds no input.
/// Only a private path and the existing decoded bound cross the worker boundary.
class GzipFramingCheck {
  const GzipFramingCheck(this.path, this.maximumDecodedBytes);
  final String path;
  final int maximumDecodedBytes;

  static void worker((GzipFramingCheck, SendPort) message) {
    try {
      Isolate.exit(message.$2, message.$1.run());
    } on Object catch (error) {
      Isolate.exit(message.$2, error);
    }
  }

  int run() {
    final file = File(path).openSync();
    try {
      final input = _Bits(file);
      var members = 0, total = 0;
      while (true) {
        final first = input.nextByte();
        if (first < 0) {
          if (members == 0) _invalid();
          return total;
        }
        if (first != 31 || input.byte() != 139 || input.byte() != 8) _invalid();
        final flags = input.byte();
        if (flags & 224 != 0) _invalid();
        input.skip(6); // MTIME, XFL, OS
        if (flags & 4 != 0) input.skip(input.little16());
        for (final flag in [8, 16]) {
          if (flags & flag != 0) {
            while (input.byte() != 0) {}
          }
        }
        if (flags & 2 != 0) input.skip(2); // SDK validates FHCRC.
        var size = 0;
        void produced(int count) {
          size += count;
          total += count;
          if (total > maximumDecodedBytes) _invalid();
        }

        var last = false;
        while (!last) {
          last = input.bits(1) != 0;
          final type = input.bits(2);
          if (type == 0) {
            input.align();
            final length = input.little16();
            if (length ^ input.little16() != 65535) _invalid();
            input.skip(length);
            produced(length);
            continue;
          }
          if (type == 3) _invalid();
          var literals = _fixedLiterals, distances = _fixedDistances;
          if (type == 2) {
            final literalCount = input.bits(5) + 257;
            final distanceCount = input.bits(5) + 1;
            final codeCount = input.bits(4) + 4;
            if (literalCount > 286) _invalid();
            const order = [
              16,
              17,
              18,
              0,
              8,
              7,
              9,
              6,
              10,
              5,
              11,
              4,
              12,
              3,
              13,
              2,
              14,
              1,
              15,
            ];
            final codeLengths = List.filled(19, 0);
            for (var i = 0; i < codeCount; i++) {
              codeLengths[order[i]] = input.bits(3);
            }
            final codes = _Codes(codeLengths), lengths = <int>[];
            final count = literalCount + distanceCount;
            while (lengths.length < count) {
              final symbol = codes.read(input);
              if (symbol < 16) {
                lengths.add(symbol);
              } else {
                if (symbol == 16 && lengths.isEmpty) _invalid();
                final repeat = switch (symbol) {
                  16 => input.bits(2) + 3,
                  17 => input.bits(3) + 3,
                  18 => input.bits(7) + 11,
                  _ => throw const FormatException('Invalid gzip framing'),
                };
                final value = symbol == 16 ? lengths.last : 0;
                if (lengths.length + repeat > count) _invalid();
                lengths.addAll(List.filled(repeat, value));
              }
            }
            if (lengths[256] == 0) _invalid();
            literals = _Codes(lengths.sublist(0, literalCount));
            distances = _Codes(lengths.sublist(literalCount));
          }
          while (true) {
            final symbol = literals.read(input);
            if (symbol < 256) {
              produced(1);
            } else if (symbol == 256) {
              break;
            } else {
              if (symbol > 285) _invalid();
              final at = symbol - 257;
              final length = _lengthBase[at] + input.bits(_lengthExtra[at]);
              final distance = distances.read(input);
              if (distance > 29) _invalid();
              final back =
                  _distanceBase[distance] +
                  input.bits(_distanceExtra[distance]);
              if (back > size) _invalid();
              produced(length);
            }
          }
        }
        input.align();
        input.skip(4); // SDK verifies CRC32 against the actual decoded bytes.
        if (input.little32() != size & 0xffffffff) _invalid();
        members++;
      }
    } finally {
      file.closeSync();
    }
  }
}

Never _invalid() =>
    throw const FormatException('Incomplete or invalid gzip framing');

class _Bits {
  _Bits(this.file);
  final RandomAccessFile file;
  final buffer = Uint8List(65536);
  int offset = 0, length = 0, held = 0, count = 0;
  int nextByte() {
    if (offset == length) {
      length = file.readIntoSync(buffer);
      offset = 0;
      if (length == 0) return -1;
    }
    return buffer[offset++];
  }

  int byte() {
    final value = nextByte();
    if (value < 0) _invalid();
    return value;
  }

  int bits(int width) {
    while (count < width) {
      held |= byte() << count;
      count += 8;
    }
    final value = held & ((1 << width) - 1);
    held >>= width;
    count -= width;
    return value;
  }

  void align() {
    held = 0;
    count = 0;
  }

  int little16() => byte() | byte() << 8;
  int little32() => little16() | little16() << 16;
  void skip(int bytes) {
    while (bytes > 0) {
      if (offset == length) {
        byte();
        bytes--;
      }
      final available = length - offset;
      final take = bytes < available ? bytes : available;
      offset += take;
      bytes -= take;
    }
  }
}

class _Codes {
  _Codes(List<int> lengths) {
    for (final length in lengths) {
      if (length != 0) counts[length]++;
    }
    var code = 0, start = 0, left = 1;
    for (var width = 1; width <= 15; width++) {
      code = (code + counts[width - 1]) << 1;
      first[width] = code;
      offsets[width] = start;
      start += counts[width];
      left = (left << 1) - counts[width];
      if (left < 0) _invalid();
      if (counts[width] != 0) maximum = width;
    }
    symbols.addAll(List.filled(start, 0));
    final positions = List.of(offsets);
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final width = lengths[symbol];
      if (width != 0) symbols[positions[width]++] = symbol;
    }
  }
  final counts = List.filled(16, 0),
      first = List.filled(16, 0),
      offsets = List.filled(16, 0);
  final symbols = <int>[];
  int maximum = 0;
  int read(_Bits input) {
    var code = 0;
    for (var width = 1; width <= maximum; width++) {
      code = code << 1 | input.bits(1);
      final at = code - first[width];
      if (at >= 0 && at < counts[width]) return symbols[offsets[width] + at];
    }
    return _invalid();
  }
}

final _fixedLiterals = _Codes([
  for (var i = 0; i < 288; i++)
    i < 144
        ? 8
        : i < 256
        ? 9
        : i < 280
        ? 7
        : 8,
]);
final _fixedDistances = _Codes(List.filled(32, 5));
const _lengthBase = [
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  13,
  15,
  17,
  19,
  23,
  27,
  31,
  35,
  43,
  51,
  59,
  67,
  83,
  99,
  115,
  131,
  163,
  195,
  227,
  258,
];
const _lengthExtra = [
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  0,
];
const _distanceBase = [
  1,
  2,
  3,
  4,
  5,
  7,
  9,
  13,
  17,
  25,
  33,
  49,
  65,
  97,
  129,
  193,
  257,
  385,
  513,
  769,
  1025,
  1537,
  2049,
  3073,
  4097,
  6145,
  8193,
  12289,
  16385,
  24577,
];
const _distanceExtra = [
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
];
