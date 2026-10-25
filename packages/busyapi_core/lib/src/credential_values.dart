import 'dart:convert';

const maximumCredentialValueBytes = 64 * 1024;

/// Availability is represented by null. An explicitly supplied empty value
/// remains subject to the selected credential's wire rules.
bool credentialValueFitsStorage(String value, {bool allowEmpty = false}) =>
    (allowEmpty || value.isNotEmpty) &&
    value.length <= maximumCredentialValueBytes &&
    !value.contains('\u0000') &&
    !value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff) &&
    utf8.encode(value).length <= maximumCredentialValueBytes;

enum CredentialValuePolicy {
  opaque,
  apiKey,
  basicPassword,
  bearerToken;

  bool get allowsEmpty => this == apiKey || this == basicPassword;

  bool accepts(String value) {
    if (!credentialValueFitsStorage(value, allowEmpty: allowsEmpty))
      return false;
    // RFC 7617 §2 forbids CTL before Base64 encoding and permits password
    // colons. RFC 6750 §2.1 defines the actual Bearer field token grammar.
    return switch (this) {
      basicPassword => !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value),
      bearerToken => RegExp(r'^[A-Za-z0-9._~+/-]+=*$').hasMatch(value),
      _ => true,
    };
  }

  static CredentialValuePolicy forReferenceField(String field) =>
      switch (field) {
        'secretRef' => apiKey,
        'passwordRef' => basicPassword,
        'tokenRef' || 'accessTokenRef' => bearerToken,
        _ => opaque,
      };
}

bool validBasicUsername(String value) =>
    credentialValueFitsStorage(value, allowEmpty: true) &&
    !value.contains(':') &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
