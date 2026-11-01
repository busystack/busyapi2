import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'model.dart';

const _maximumMimeTextBytes = 64 * 1024 * 1024;

/// A deliberately malformed raw request retains a visible framing error.
class MimeTextPreparationProblem {
  const MimeTextPreparationProblem._(this.code, this.message);
  final String code, message;
}

/// Wire bytes from the engine's captured logical MIME text preparation.
class MimeTextMaterialization {
  MimeTextMaterialization._(this.bytes, this.problem);

  factory MimeTextMaterialization.fromJson(
    Object? value, {
    required String snapshot,
    required String text,
    required String mediaType,
  }) {
    CoreFailure invalid() => CoreFailure(
      'engine.mime-text',
      'The engine returned incomplete or stale MIME text bytes',
    );
    if (value case {
      'version': 1,
      'revision': '1',
      'snapshot': String captured,
      'input': String digest,
      'mediaType': String selected,
      'byteLength': int length,
      'base64': String encoded,
      'mode': String mode,
    }) {
      if (captured != snapshot ||
          selected != mediaType ||
          digest != sha256.convert(utf8.encode(text)).toString() ||
          length < 0 ||
          length > _maximumMimeTextBytes ||
          encoded.length > ((_maximumMimeTextBytes + 2) ~/ 3) * 4) {
        throw invalid();
      }
      final Uint8List decoded;
      try {
        decoded = base64.decode(encoded);
      } on FormatException {
        throw invalid();
      }
      if (decoded.length != length || base64.encode(decoded) != encoded) {
        throw invalid();
      }
      MimeTextPreparationProblem? problem;
      if (mode == 'literal-invalid') {
        if (value['problem'] case {
          'code': String code,
          'message': String message,
        }) {
          final literal = utf8.encode(text);
          if (!const {
                'runtime.form.syntax',
                'runtime.mime-text.transfer',
              }.contains(code) ||
              message.isEmpty ||
              message.length > 4096 ||
              literal.length != decoded.length ||
              base64.encode(literal) != encoded) {
            throw invalid();
          }
          problem = MimeTextPreparationProblem._(code, message);
        } else {
          throw invalid();
        }
      } else if (mode != 'encoded' || value.containsKey('problem')) {
        throw invalid();
      }
      return MimeTextMaterialization._(decoded.asUnmodifiableView(), problem);
    }
    throw invalid();
  }

  final Uint8List bytes;
  final MimeTextPreparationProblem? problem;
}
