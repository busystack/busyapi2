import 'dart:io';

/// Select the applicable declaration without reordering authored content.
/// RFC 9110 media ranges rank type/subtype before parameter specificity.
Map? selectDeclaredMedia(Iterable<Map> declarations, String? actual) {
  if (actual == null) return null;
  ContentType wire;
  try {
    wire = ContentType.parse(actual);
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
  if (wire.primaryType == '*' || wire.subType.isEmpty || wire.subType == '*') {
    return null;
  }
  Map? selected;
  var specificity = -1, parameterCount = -1;
  for (final declaration in declarations) {
    final value = declaration['mediaType'];
    if (value is! String) continue;
    ContentType range;
    try {
      range = ContentType.parse(value);
    } on FormatException {
      continue;
    } on HttpException {
      continue;
    }
    final rank = range.primaryType == '*' && range.subType == '*'
        ? 0
        : range.primaryType == wire.primaryType && range.subType == '*'
        ? 1
        : range.primaryType == wire.primaryType && range.subType == wire.subType
        ? 2
        : -1;
    if (rank < 0 ||
        range.parameters.entries.any(
          (entry) => wire.parameters[entry.key] != entry.value,
        ))
      continue;
    if (rank > specificity ||
        rank == specificity && range.parameters.length > parameterCount) {
      selected = declaration;
      specificity = rank;
      parameterCount = range.parameters.length;
    }
  }
  return selected;
}
