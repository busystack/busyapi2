import 'model.dart';

enum RequestDataKind { string, number, boolean, nullValue, array, object }

/// User execution data parsed by the strict engine CST. Numeric wire leaves
/// are lexemes; raw JSON retains their kinds and exact content for validation.
/// This is independent of the canonical contract graph and grants no file IO.
class RequestFormValue {
  const RequestFormValue._(
    this.kind,
    this.raw,
    this.text,
    this.value,
    this.items,
  );
  final RequestDataKind kind;
  final String raw, text;
  final Object? value;
  final List<RequestFormValue> items;

  factory RequestFormValue.fromJson(Object? input, [int depth = 0]) {
    if (depth > 128 ||
        input is! Map ||
        input['raw'] is! String ||
        input['text'] is! String ||
        !input.containsKey('value')) {
      throw _protocol();
    }
    final kind = switch (input['kind']) {
      'string' => RequestDataKind.string,
      'number' => RequestDataKind.number,
      'boolean' => RequestDataKind.boolean,
      'null' => RequestDataKind.nullValue,
      'array' => RequestDataKind.array,
      'object' => RequestDataKind.object,
      _ => throw _protocol(),
    };
    final value = input['value'];
    if (kind == RequestDataKind.number &&
            (input['raw'] != input['text'] || input['raw'] != value) ||
        kind == RequestDataKind.string && input['text'] != value ||
        kind == RequestDataKind.nullValue &&
            (input['raw'] != 'null' || input['text'] != 'null')) {
      throw _protocol();
    }
    if (!_wireValue(value, depth) ||
        switch (kind) {
          RequestDataKind.string || RequestDataKind.number => value is! String,
          RequestDataKind.boolean => value is! bool,
          RequestDataKind.nullValue => value != null,
          RequestDataKind.array => value is! List,
          RequestDataKind.object => value is! Map,
        })
      throw _protocol();
    final rawItems = input['items'];
    if (kind == RequestDataKind.array &&
        (rawItems is! List || rawItems.length != (value as List).length))
      throw _protocol();
    final items = kind == RequestDataKind.array
        ? [
            for (final item in rawItems as List)
              RequestFormValue.fromJson(item, depth + 1),
          ]
        : <RequestFormValue>[];
    return RequestFormValue._(
      kind,
      input['raw'] as String,
      input['text'] as String,
      _freeze(value),
      List.unmodifiable(items),
    );
  }

  static bool _wireValue(Object? value, int depth) =>
      depth <= 128 &&
      switch (value) {
        null || String() || bool() => true,
        List() => value.every((item) => _wireValue(item, depth + 1)),
        Map() =>
          value.keys.every((key) => key is String) &&
              value.values.every((item) => _wireValue(item, depth + 1)),
        _ => false,
      };

  static Object? _freeze(Object? value) => switch (value) {
    List() => List<Object?>.unmodifiable(value.map(_freeze)),
    Map() => Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freeze(entry.value),
    }),
    _ => value,
  };

  static CoreFailure _protocol() => CoreFailure(
    'request.form.protocol',
    'The engine returned malformed exact form data.',
  );
}

class RequestFormData {
  const RequestFormData._(this.raw, this.fields);
  final String raw;
  final Map<String, RequestFormValue> fields;

  factory RequestFormData.fromJson(Map<String, dynamic> result, String input) {
    if (result['version'] != 1 ||
        result['input'] != textIdentity(input) ||
        result['raw'] is! String ||
        result['fields'] is! List ||
        (result['fields'] as List).length > 2048) {
      throw RequestFormValue._protocol();
    }
    final fields = <String, RequestFormValue>{};
    for (final field in result['fields'] as List) {
      if (field is! Map ||
          field['name'] is! String ||
          fields.containsKey(field['name']))
        throw RequestFormValue._protocol();
      fields[field['name'] as String] = RequestFormValue.fromJson(field);
    }
    return RequestFormData._(result['raw'] as String, Map.unmodifiable(fields));
  }
}
