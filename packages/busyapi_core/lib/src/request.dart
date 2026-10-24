import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'model.dart';
import 'content_selection.dart';
import 'header_serialization.dart';
import 'swagger_serialization.dart';
import 'form_serialization.dart';
import 'form_media_types.dart';
import 'multipart_encoding.dart';
import 'multipart_transfer.dart';
import 'request_form_values.dart';
import 'project.dart';
import 'atomic_file_writer.dart';
import 'storage.dart';
import 'gzip_framing.dart';
import 'exact_http_method.dart';

typedef SecretResolver = Future<String?> Function(String reference);

// Representation headers on these responses describe content that HTTP does
// not transfer. Keep this decision shared by decoding, validation and display.
bool _responseBodyPermitted(String method, int status) =>
    method != 'HEAD' && status >= 200 && !{204, 205, 304}.contains(status);

// Keep possible gzip member headers on fresh input chunks. The pinned SDK's
// streaming inflater can reject a following member after an empty member when
// both share a chunk. Splitting at additional magic occurrences is harmless;
// the received-only framing/CRC checks still decide validity.
Stream<List<int>> _gzipMemberChunks(Stream<List<int>> input) async* {
  var tail = <int>[];
  await for (final chunk in input) {
    final bytes = [...tail, ...chunk];
    final end = max(0, bytes.length - 2);
    var start = 0;
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 31 && bytes[i + 1] == 139 && bytes[i + 2] == 8) {
        if (i > start) yield bytes.sublist(start, i);
        start = i;
      }
    }
    if (start < end) yield bytes.sublist(start, end);
    tail = bytes.sublist(end);
  }
  if (tail.isNotEmpty) yield tail;
}

Map? _selectedRequestMedia(Iterable<Map> declarations, String? mediaType) =>
    declarations
        .where((media) => media['mediaType'] == mediaType)
        .firstOrNull ??
    selectDeclaredMedia(declarations, mediaType);

bool isInspectableTextMedia(String? contentType) {
  if (contentType == null) return false;
  try {
    final type = ContentType.parse(contentType).mimeType;
    return type.startsWith('text/') ||
        type == 'application/json' ||
        type.endsWith('+json') ||
        type.contains('xml') ||
        type.contains('jsonl') ||
        type.contains('ndjson');
  } on Object {
    return false;
  }
}

enum RequestValueRepresentation {
  text,
  json,
  serializedParameter,
  serializedMedia,
}

class RequestValue {
  const RequestValue.absent()
    : present = false,
      text = '',
      json = false,
      representation = RequestValueRepresentation.text;
  const RequestValue.text(this.text)
    : present = true,
      json = false,
      representation = RequestValueRepresentation.text;
  const RequestValue.json(this.text)
    : present = true,
      json = true,
      representation = RequestValueRepresentation.json;
  const RequestValue.serialized(this.text, {bool mediaLevel = false})
    : present = true,
      json = false,
      representation = mediaLevel
          ? RequestValueRepresentation.serializedMedia
          : RequestValueRepresentation.serializedParameter;
  final RequestValueRepresentation representation;
  final bool present, json;
  final String text;
}

class RequestHeaderValue {
  const RequestHeaderValue(this.name, this.value, {this.enabled = true});
  final String name, value;
  final bool enabled;
}

enum RequestBodyKind { none, raw, form, multipart, binaryFile }

class MultipartFileValue {
  const MultipartFileValue({
    required this.name,
    required this.path,
    this.filename,
    this.mediaType = 'application/octet-stream',
    this.selectedMediaType,
  });
  final String name, path, mediaType;
  final String? filename;
  final String? selectedMediaType;
}

class RequestFormField {
  const RequestFormField(this.name, this.value);
  final String name, value;
}

class RequestBodyDraft {
  const RequestBodyDraft.none()
    : kind = RequestBodyKind.none,
      mediaType = null,
      text = null,
      file = null,
      partMediaTypes = const {},
      fields = const [],
      files = const [];
  const RequestBodyDraft.raw({required this.mediaType, required this.text})
    : kind = RequestBodyKind.raw,
      file = null,
      partMediaTypes = const {},
      fields = const [],
      files = const [];
  const RequestBodyDraft.form(
    this.fields, {
    this.mediaType = 'application/x-www-form-urlencoded',
    this.partMediaTypes = const {},
  }) : kind = RequestBodyKind.form,
       text = null,
       file = null,
       files = const [];
  const RequestBodyDraft.formValue({
    required String json,
    this.mediaType = 'application/x-www-form-urlencoded',
    this.partMediaTypes = const {},
  }) : kind = RequestBodyKind.form,
       text = json,
       file = null,
       fields = const [],
       files = const [];
  const RequestBodyDraft.multipart(
    this.fields,
    this.files, {
    this.mediaType = 'multipart/form-data',
    this.partMediaTypes = const {},
  }) : kind = RequestBodyKind.multipart,
       text = null,
       file = null;
  const RequestBodyDraft.multipartValue({
    required String json,
    this.files = const [],
    this.mediaType = 'multipart/form-data',
    this.partMediaTypes = const {},
  }) : kind = RequestBodyKind.multipart,
       text = json,
       file = null,
       fields = const [];
  const RequestBodyDraft.binaryFile({
    required this.mediaType,
    required this.file,
  }) : kind = RequestBodyKind.binaryFile,
       text = null,
       partMediaTypes = const {},
       fields = const [],
       files = const [];
  final RequestBodyKind kind;
  final String? mediaType, text, file;
  final List<RequestFormField> fields;
  final List<MultipartFileValue> files;
  final Map<String, String> partMediaTypes;
}

class OperationRequestDraft {
  const OperationRequestDraft({
    required this.planIdentity,
    this.environment,
    this.server = 0,
    this.securityAlternative,
    this.parameters = const {},
    this.headers = const [],
    this.variables = const {},
    this.body = const RequestBodyDraft.none(),
    this.tlsFiles = const {},
    this.connectTimeout = const Duration(seconds: 15),
    this.overallTimeout = const Duration(seconds: 60),
    this.inactivityTimeout = const Duration(seconds: 15),
  });
  final String planIdentity;
  final String? environment;
  final int server;
  final int? securityAlternative;
  final Map<String, RequestValue> parameters;
  final List<RequestHeaderValue> headers;
  final Map<String, String> variables;
  final RequestBodyDraft body;
  final Map<String, String> tlsFiles;
  final Duration connectTimeout, overallTimeout, inactivityTimeout;

  static String parameterKey(String location, String name) =>
      '$location\u0000$name';
}

class PreparedRequestBody {
  PreparedRequestBody(
    this.length,
    this.open, {
    this.mediaType,
    this.release,
    this.formInstance,
    this.formParameters,
  });
  final int length;
  final Stream<List<int>> Function() open;
  final String? mediaType;
  final String? formInstance;
  final List<RuntimeSchemaInstance>? formParameters;
  final Future<void> Function()? release;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _releaseOwned();
  Future<void> _releaseOwned() async {
    await release?.call();
  }
}

class PreparedContractRequest {
  const PreparedContractRequest({
    required this.runId,
    required this.plan,
    required this.environment,
    required this.method,
    required this.uri,
    required this.displayUri,
    required this.headers,
    required this.body,
    required this.sensitiveHeaders,
    required this.sensitiveQueryNames,
    required this.connectTimeout,
    required this.overallTimeout,
    required this.inactivityTimeout,
    required this.securityAlternative,
    required this.tls,
  });
  final String runId, method, displayUri;
  final OperationRequestPlan plan;
  final String? environment;
  final Uri uri;
  final List<(String, String)> headers;
  final PreparedRequestBody? body;
  final Set<String> sensitiveHeaders, sensitiveQueryNames;
  final Duration connectTimeout, overallTimeout, inactivityTimeout;
  final int? securityAlternative;
  final RequestTlsConfiguration tls;
}

class RequestTlsConfiguration {
  const RequestTlsConfiguration({
    this.ca,
    this.certificate,
    this.privateKey,
    this.privateKeyPassword,
  });
  final Uint8List? ca, certificate, privateKey;
  final String? privateKeyPassword;
  bool get custom => ca != null || certificate != null || privateKey != null;
}

class ContractRequestBuilder {
  const ContractRequestBuilder({this.maximumUploadBytes = 128 * 1024 * 1024});
  final int maximumUploadBytes;

  /// The selected API base, shared by HTTP requests and relative OAuth URLs.
  /// It deliberately uses Server retrieval context rather than schema/OAD identity.
  Uri serverBase(OperationRequestPlan plan, OperationRequestDraft draft) {
    plan.ensureCurrentPreparation();
    if (draft.planIdentity != plan.identity) {
      throw CoreFailure(
        'request.draft.stale',
        'Reconcile the changed request before authorization',
      );
    }
    final environment = draft.environment == null
        ? null
        : plan.configuration.environments[draft.environment];
    if (draft.environment != null && environment == null) {
      throw CoreFailure(
        'environment.missing',
        'The selected environment is no longer declared',
      );
    }
    return _server(plan, draft, environment).$1;
  }

  static (Uri, String Function(String)) _server(
    OperationRequestPlan plan,
    OperationRequestDraft draft,
    ExecutionEnvironment? environment,
  ) {
    final variables = <String, String>{
      ...?environment?.variables,
      ...draft.variables,
    };
    final servers = (plan.result['servers'] as List).cast<Map>();
    if (draft.server < 0 || draft.server >= servers.length) {
      throw CoreFailure('request.server', 'Select a current operation server');
    }
    final server = servers[draft.server];
    String substitute(String value) {
      const escaped = '\u0000busyapi-dollar-open\u0000';
      value = value.replaceAll(r'$${', escaped);
      final unresolved = <String>[];
      value = value.replaceAllMapped(
        RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_.-]{0,127})\}'),
        (match) {
          final replacement = variables[match.group(1)!];
          if (replacement == null) {
            unresolved.add(match.group(1)!);
            return match.group(0)!;
          }
          return replacement;
        },
      );
      if (unresolved.isNotEmpty) {
        throw CoreFailure(
          'environment.variable',
          'Resolve environment variable ${unresolved.toSet().join(', ')} before execution',
        );
      }
      return value.replaceAll(escaped, r'${');
    }

    final declaredVariables = server['variables'] is Map
        ? Map<String, dynamic>.from(server['variables'] as Map)
        : const <String, dynamic>{};
    String expandServer(String value) => value.replaceAllMapped(
      RegExp(r'\{([^{}]+)\}'),
      (match) {
        final name = match.group(1)!, configured = variables[name];
        final definition = declaredVariables[name];
        final fallback = definition is Map ? definition['default'] : null;
        final selected = configured ?? (fallback is String ? fallback : null);
        if (selected == null) {
          throw CoreFailure(
            'request.server.variable',
            'Set server variable $name before execution',
          );
        }
        if (definition is Map && definition['enum'] is List) {
          final options = (definition['enum'] as List).map((v) => '$v').toSet();
          if (!options.contains(selected)) {
            throw CoreFailure(
              'request.server.variable',
              'Server variable $name is outside its declared choices',
            );
          }
        }
        return selected;
      },
    );
    final configuredBase = environment?.baseUrl;
    Uri base;
    if (configuredBase != null && configuredBase.isNotEmpty) {
      base = _httpUri(substitute(configuredBase), 'environment base URL');
    } else {
      final authored = expandServer(substitute(server['url'] as String));
      if (RegExp(r'[\x00-\x20\x7f{}\\]').hasMatch(authored)) {
        throw CoreFailure(
          'request.url',
          'The completed server URL contains invalid or unresolved characters',
        );
      }
      final parsed = Uri.tryParse(authored);
      if (parsed == null) {
        throw CoreFailure('request.url', 'The selected server URL is invalid');
      }
      if (parsed.hasScheme) {
        base = _httpUri(authored, 'server URL');
      } else {
        final sourceBase = Uri.tryParse(server['base'] as String? ?? '');
        if (sourceBase == null ||
            !sourceBase.isAbsolute ||
            !const ['http', 'https'].contains(sourceBase.scheme)) {
          throw CoreFailure(
            'request.server.relative',
            'Choose an environment base URL for this relative server; a local file path is not an API origin',
          );
        }
        base = _httpUri(sourceBase.resolveUri(parsed).toString(), 'server URL');
      }
    }
    return (base, substitute);
  }

  Future<PreparedContractRequest> build(
    OperationRequestPlan plan,
    OperationRequestDraft draft, {
    required SecretResolver resolveSecret,
    bool previewOnly = false,
    RunCancellation? cancellation,
  }) async {
    plan.ensureCurrentPreparation();
    if (draft.planIdentity != plan.identity) {
      throw CoreFailure(
        'request.draft.stale',
        'Reconcile this draft with the changed operation before sending it',
      );
    }
    _positiveTimeout(draft.connectTimeout, 'connect');
    _positiveTimeout(draft.overallTimeout, 'overall');
    _positiveTimeout(draft.inactivityTimeout, 'inactivity');
    final environment = draft.environment == null
        ? null
        : plan.configuration.environments[draft.environment];
    if (draft.environment != null && environment == null) {
      throw CoreFailure(
        'environment.missing',
        'The selected environment is no longer declared',
      );
    }
    final (base, substitute) = _server(plan, draft, environment);
    var path = plan.operation['path'] as String;
    final query = <(String, String, bool, bool)>[];
    final cookies = <(String, String)>[];
    final cookieOwners = <String>{};
    final headers = <(String, String)>[];
    final structured = await plan.parameterValues({
      for (final entry in draft.parameters.entries)
        if (entry.value.present && entry.value.json)
          entry.key: entry.value.text,
    });
    plan.ensureCurrentPreparation();
    for (final value
        in environment?.headers.entries ??
            const Iterable<MapEntry<String, String>>.empty()) {
      _addHeader(headers, value.key, substitute(value.value));
    }
    for (final raw in (plan.result['parameters'] as List).cast<Map>()) {
      final name = raw['name'] as String, location = raw['in'] as String;
      final supplied =
          draft.parameters[OperationRequestDraft.parameterKey(
            location,
            name,
          )] ??
          const RequestValue.absent();
      if (!supplied.present) {
        if (raw['required'] == true) {
          throw CoreFailure(
            'request.parameter.required',
            'Enter required $location parameter $name',
          );
        }
        continue;
      }
      final value = supplied.json
          ? structured[OperationRequestDraft.parameterKey(location, name)]
          : supplied.text;
      final serialized =
          supplied.representation ==
              RequestValueRepresentation.serializedParameter
          ? _serializedParameter(raw, supplied.text)
          : _serializeParameter(
              raw,
              value,
              supplied.text,
              structured: supplied.json,
            );
      switch (location) {
        case 'path':
          final marker = '{$name}';
          if (!path.contains(marker)) {
            throw CoreFailure(
              'request.parameter.path',
              'Path parameter $name has no matching template expression',
            );
          }
          path = path.replaceAll(marker, serialized.single.$2);
          break;
        case 'query':
          for (final item in serialized) {
            query.add((item.$1, item.$2, raw['allowReserved'] == true, true));
          }
          break;
        case 'querystring':
          if (query.isNotEmpty) {
            throw CoreFailure(
              'request.parameter.querystring',
              'A querystring parameter cannot be combined with query parameters',
            );
          }
          query.add(('', serialized.single.$2, true, true));
          break;
        case 'header':
          _addHeader(
            headers,
            name,
            serialized.single.$2,
            allowHorizontalTab:
                raw['family'] == '2.0' && raw['collectionFormat'] == 'tsv',
          );
          break;
        case 'cookie':
          for (final item in serialized) {
            if (cookieOwners.contains(item.$1)) {
              throw CoreFailure(
                'request.cookie.duplicate',
                'Cookie parameter ${item.$1} is supplied more than once',
              );
            }
            cookies.add(item);
          }
          cookieOwners.addAll(serialized.map((item) => item.$1));
          break;
        default:
          throw CoreFailure(
            'request.parameter.location',
            'Parameter location $location is not executable',
          );
      }
    }
    for (final header in draft.headers.where((value) => value.enabled)) {
      _addHeader(headers, header.name, substitute(header.value));
    }
    final sensitiveHeaders = <String>{'authorization', 'proxy-authorization'};
    final sensitiveQuery = <String>{};
    final security = Map<String, dynamic>.from(plan.result['security'] as Map);
    final requirements = (security['requirements'] as List? ?? const [])
        .cast<Map>();
    int? alternative = draft.securityAlternative;
    if (alternative == null &&
        requirements.isNotEmpty &&
        environment?.authentication['alternative'] is int) {
      alternative = environment!.authentication['alternative'] as int;
    }
    if (alternative != null) {
      if (alternative < 0 || alternative >= requirements.length) {
        throw CoreFailure(
          'request.security.alternative',
          'Select one current security alternative',
        );
      }
      final configured = environment?.authentication['schemes'];
      final schemeConfiguration = configured is Map
          ? Map<String, dynamic>.from(configured)
          : const <String, dynamic>{};
      final declarations = Map<String, dynamic>.from(
        security['schemes'] as Map,
      );
      for (final schemeName
          in (requirements[alternative]['schemes'] as List).cast<String>()) {
        final declaration = declarations[schemeName];
        final configuredScheme = schemeConfiguration[schemeName];
        if (declaration is! Map || configuredScheme is! Map) {
          throw CoreFailure(
            'request.security.configuration',
            'Configure credentials for $schemeName in the selected environment',
          );
        }
        await _applySecurity(
          schemeName,
          Map<String, dynamic>.from(declaration),
          Map<String, dynamic>.from(configuredScheme),
          previewOnly ? (_) async => '[REDACTED]' : resolveSecret,
          headers,
          query,
          base,
          cookies,
          sensitiveHeaders,
          sensitiveQuery,
        );
      }
    } else if (requirements.isNotEmpty && security['anonymous'] != true) {
      throw CoreFailure(
        'request.security.required',
        'Select and configure one operation security alternative',
      );
    }
    if (cookies.isNotEmpty) {
      for (final pair in cookies) {
        if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(pair.$1) ||
            !RegExp(r'^[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*$')
                .hasMatch(pair.$2)) {
          throw CoreFailure(
            'request.cookie.value',
            'A cookie name/value contains forbidden cookie characters. Use the declaration’s encoding layer; cookie style preserves literal percent sequences.',
          );
        }
      }
      _addHeader(
        headers,
        'Cookie',
        cookies.map((entry) => '${entry.$1}=${entry.$2}').join('; '),
      );
      if (cookies.any((entry) => sensitiveQuery.contains(entry.$1))) {
        sensitiveHeaders.add('cookie');
      }
    }
    final rawBodyDeclaration = plan.result['requestBody'];
    final selectedBodyMedia = rawBodyDeclaration is Map
        ? _selectedRequestMedia(
            (rawBodyDeclaration['content'] as List).whereType<Map>(),
            draft.body.mediaType,
          )
        : null;
    if (draft.body.kind != RequestBodyKind.none &&
        rawBodyDeclaration is Map &&
        (selectedBodyMedia == null ||
            !_mediaMatches(
              draft.body.mediaType ?? '',
              selectedBodyMedia['mediaType'] as String,
            ))) {
      throw CoreFailure(
        'request.body.media-type',
        'Choose the exact current request media declaration.',
      );
    }
    if (draft.body.mediaType != null &&
        draft.body.kind != RequestBodyKind.binaryFile) {
      validateTextCharset(draft.body.mediaType!, [
        draft.body.text ?? '',
        for (final field in draft.body.fields) ...[field.name, field.value],
      ]);
    }
    final body = previewOnly
        ? (draft.body.kind == RequestBodyKind.none
              ? null
              : PreparedRequestBody(
                  0,
                  () => const Stream.empty(),
                  mediaType: draft.body.mediaType,
                ))
        : await _body(
            plan,
            draft.body,
            selectedBodyMedia,
            cancellation,
            plan.ensureCurrentPreparation,
          );
    try {
      final bodyDeclaration = plan.result['requestBody'];
      if (bodyDeclaration is Map &&
          bodyDeclaration['required'] == true &&
          body == null) {
        throw CoreFailure(
          'request.body.required',
          'Enter the required request body before sending',
        );
      }
      if (body != null && bodyDeclaration is Map) {
        final choices = (bodyDeclaration['content'] as List? ?? const [])
            .whereType<Map>()
            .map((choice) => choice['mediaType'])
            .whereType<String>();
        final selected = draft.body.mediaType;
        if (selected != null &&
            choices.isNotEmpty &&
            !choices.any((choice) => _mediaMatches(selected, choice))) {
          throw CoreFailure(
            'request.body.media-type',
            'Choose a request body media type declared by the operation',
          );
        }
      }
      if (body != null) {
        _addHeader(
          headers,
          'Content-Type',
          body.mediaType ?? draft.body.mediaType ?? 'application/octet-stream',
        );
      }
      final combinedPath = _joinUrlPath(base.path, path);
      final encodedQuery = <String>[
        if (base.hasQuery) base.query,
        for (final item in query)
          if (item.$1.isEmpty)
            item.$2
          else
            '${_encode(item.$1, false)}=${item.$4 ? item.$2 : _encode(item.$2, item.$3)}',
      ].where((value) => value.isNotEmpty).join('&');
      // The parameter serializer has already percent-encoded each path/query
      // value. Uri.replace would encode those percent signs a second time.
      final uri = Uri.parse(
        '${base.scheme}://${base.authority}$combinedPath${encodedQuery.isEmpty ? '' : '?$encodedQuery'}',
      );
      final displayUri = _redactedUri(uri, sensitiveQuery);
      final tls = previewOnly
          ? const RequestTlsConfiguration()
          : await _tls(plan, environment, resolveSecret, draft.tlsFiles);
      // Credential resolution can outlive its native dialog or project. Never
      // let that delayed completion construct a request for a closed owner.
      plan.ensureCurrentPreparation();
      return PreparedContractRequest(
        runId: previewOnly ? 'preview' : _runIdentity(),
        plan: plan,
        environment: environment?.name,
        method: plan.operation['method'] as String,
        uri: uri,
        displayUri: displayUri,
        headers: List.unmodifiable(headers),
        body: body,
        sensitiveHeaders: Set.unmodifiable(sensitiveHeaders),
        sensitiveQueryNames: Set.unmodifiable(sensitiveQuery),
        connectTimeout: draft.connectTimeout,
        overallTimeout: draft.overallTimeout,
        inactivityTimeout: draft.inactivityTimeout,
        securityAlternative: alternative,
        tls: tls,
      );
    } on Object {
      await body?.close();
      rethrow;
    }
  }

  static void _positiveTimeout(Duration value, String name) {
    if (value <= Duration.zero || value > const Duration(minutes: 10)) {
      throw CoreFailure(
        'request.timeout',
        'The $name timeout must be between zero and ten minutes',
      );
    }
  }

  static Uri _httpUri(String text, String label) {
    final uri = Uri.tryParse(text);
    if (RegExp(r'[\x00-\x20\x7f{}\\]').hasMatch(text) ||
        uri == null ||
        !uri.isAbsolute ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw CoreFailure(
        'request.url',
        'The $label must be an absolute HTTP(S) URL without credentials or a fragment',
      );
    }
    return uri;
  }

  static List<(String, String)> _serializedParameter(
    Map parameter,
    String text,
  ) {
    final location = parameter['in'];
    final url =
        location == 'path' || location == 'query' || location == 'querystring';
    if ((url ? RegExp(r'[\x00-\x20\x7f#]') : RegExp(r'[\x00-\x1f\x7f]'))
            .hasMatch(text) ||
        url && RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(text)) {
      throw CoreFailure(
        'request.example.serialization',
        'The serialized parameter contains invalid URI/header structure. Edit its complete representation.',
      );
    }
    if (location == 'query' || location == 'querystring') return [('', text)];
    if (location == 'path' && (text.contains('/') || text.contains('?'))) {
      throw CoreFailure(
        'request.example.serialization',
        'Serialized path delimiters must be percent encoded.',
      );
    }
    if (location == 'cookie') {
      return text.split(';').map((part) {
        final at = part.indexOf('=');
        if (at <= 0) {
          throw CoreFailure(
            'request.example.serialization',
            'Serialized cookies require name=value pairs.',
          );
        }
        return (part.substring(0, at).trim(), part.substring(at + 1));
      }).toList();
    }
    return [(parameter['name'] as String, text)];
  }

  static List<(String, String)> _serializeParameter(
    Map parameter,
    Object? value,
    String original, {
    bool structured = false,
    String Function(String)? encodeValue,
  }) {
    final name = parameter['name'] as String;
    if (parameter['content'] is List &&
        (parameter['content'] as List).isNotEmpty) {
      final content = (parameter['content'] as List).whereType<Map>().toList();
      if (content.length != 1) {
        throw CoreFailure(
          'request.parameter.content',
          'A content parameter must select exactly one media declaration.',
        );
      }
      try {
        validateTextCharset(content.single['mediaType'] as String, [
          original,
          if ((content.single['mediaType'] as String).toLowerCase().startsWith(
                'application/x-www-form-urlencoded',
              ) &&
              value is Map)
            for (final item in value.values) '$item',
        ]);
      } on CoreFailure catch (error) {
        throw CoreFailure(error.code, 'Parameter $name: ${error.message}');
      }
      final media = (content.single['mediaType'] as String)
          .split(';')
          .first
          .toLowerCase();
      var representation = original;
      final jsonMedia = media == 'application/json' || media.endsWith('+json');
      if (structured &&
          !jsonMedia &&
          media != 'application/x-www-form-urlencoded') {
        if (media != 'text/plain' || value is Map || value is List) {
          throw CoreFailure(
            'request.parameter.media',
            'Parameter $name has no supported structured serializer for this media type. Use a literal serialized representation.',
          );
        }
        representation = value == null ? 'null' : '$value';
      }
      if (media == 'application/x-www-form-urlencoded' && value is Map) {
        if (value.values.any(
          (v) =>
              v is Map ||
              v is List && v.any((item) => item is Map || item is List),
        )) {
          throw CoreFailure(
            'request.parameter.media',
            'Parameter $name requires a complex form serializer. Use an explicitly serialized media example.',
          );
        }
        representation = [
          for (final entry in value.entries)
            for (final item
                in entry.value is List ? entry.value as List : [entry.value])
              '${Uri.encodeQueryComponent(entry.key as String)}=${Uri.encodeQueryComponent(item == null ? 'null' : '$item')}',
        ].join('&');
      }
      validateTextCharset(content.single['mediaType'] as String, [
        representation,
      ]);
      return [
        (
          name,
          parameter['in'] == 'path'
              ? _encode(representation, false)
              : parameter['in'] == 'query'
              ? _encode(representation, parameter['allowReserved'] == true)
              : parameter['in'] == 'querystring'
              ? _wholeQuery(parameter, representation)
              : representation,
        ),
      ];
    }
    if (parameter['family'] == '2.0')
      return serializeSwaggerParameter(parameter, value);
    final location = parameter['in'] as String,
        style =
            parameter['style'] as String? ??
            (location == 'query' || location == 'cookie' ? 'form' : 'simple'),
        explode = parameter['explode'] == true;
    String scalar(Object? item) {
      if (item == null) return 'null';
      if (item is bool) return item ? 'true' : 'false';
      if (item is String) return item;
      if (item is num &&
          value == item &&
          RegExp(r'^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$')
              .hasMatch(original.trim())) {
        return original.trim();
      }
      return '$item';
    }

    final array = value is List ? value.map(scalar).toList() : null;
    final object = value is Map
        ? <String, String>{
            for (final entry in value.entries)
              '${entry.key}': scalar(entry.value),
          }
        : null;
    List<String> flattened(String delimiter, {bool equals = false}) {
      if (array != null) return array;
      if (object != null) {
        return [
          for (final entry in object.entries)
            if (equals)
              '${entry.key}=${entry.value}'
            else ...[
              entry.key,
              entry.value,
            ],
        ];
      }
      return [scalar(value)];
    }

    switch (location) {
      case 'path':
        if (style == 'label') {
          final serialized = object != null && explode
              ? object.entries
                    .map(
                      (entry) =>
                          '${_encode(entry.key, false)}=${_encode(entry.value, false)}',
                    )
                    .join('.')
              : flattened(',')
                    .map((item) => _encode(item, false))
                    .join(array != null && explode ? '.' : ',');
          return [(name, '.$serialized')];
        }
        if (style == 'matrix') {
          if (object != null && explode) {
            return [
              (
                name,
                object.entries
                    .map(
                      (e) =>
                          ';${_encode(e.key, false)}=${_encode(e.value, false)}',
                    )
                    .join(),
              ),
            ];
          }
          if (array != null && explode) {
            return [
              (
                name,
                array
                    .map(
                      (item) =>
                          ';${_encode(name, false)}=${_encode(item, false)}',
                    )
                    .join(),
              ),
            ];
          }
          return [
            (
              name,
              ';${_encode(name, false)}=${flattened(',').map((v) => _encode(v, false)).join(',')}',
            ),
          ];
        }
        final serialized = object != null && explode
            ? object.entries
                  .map(
                    (entry) =>
                        '${_encode(entry.key, false)}=${_encode(entry.value, false)}',
                  )
                  .join(',')
            : flattened(',').map((item) => _encode(item, false)).join(',');
        return [(name, serialized)];
      case 'header':
        return [
          (name, flattened(',', equals: object != null && explode).join(',')),
        ];
      case 'cookie':
      case 'query':
        if (location == 'cookie') {
          if (style == 'cookie' && parameter['family'] != '3.2' ||
              parameter['family'] == '3.2' && parameter['explode'] == false) {
            throw CoreFailure(
              'request.cookie.style',
              'This cookie style/explode declaration is invalid for its OpenAPI version.',
            );
          }
          if (style == 'form' && (array != null || object != null)) {
            throw CoreFailure(
              'request.cookie.style',
              'Composite form-style cookie serialization is unsupported; use the declared cookie style where available.',
            );
          }
          if (style != 'cookie' && style != 'form') {
            throw CoreFailure(
              'request.cookie.style',
              'Unsupported cookie style.',
            );
          }
        }
        String encode(String text) => encodeValue != null
            ? encodeValue(text)
            : location == 'query'
            ? _encode(text, parameter['allowReserved'] == true)
            : style == 'form'
            ? _encode(text, false)
            : text;
        if (style == 'deepObject') {
          if (object == null) {
            throw CoreFailure(
              'request.parameter.style',
              'deepObject parameter $name requires an object value',
            );
          }
          return [
            for (final entry in object.entries)
              ('$name[${entry.key}]', encode(entry.value)),
          ];
        }
        final separator = style == 'spaceDelimited'
            ? ' '
            : style == 'pipeDelimited'
            ? '|'
            : style == 'tabDelimited'
            ? '\t'
            : ',';
        if (explode && array != null) {
          return [for (final item in array) (name, encode(item))];
        }
        if (explode && object != null) {
          return [
            for (final entry in object.entries)
              (entry.key, encode(entry.value)),
          ];
        }
        return [
          (
            name,
            flattened(separator)
                .map(encode)
                .join(
                  location == 'query' && separator != ','
                      ? encodeValue?.call(separator) ??
                            _encode(separator, false)
                      : separator,
                ),
          ),
        ];
      case 'querystring':
        return [('', scalar(value))];
      default:
        throw CoreFailure(
          'request.parameter.location',
          'Unsupported parameter location',
        );
    }
  }

  static String _wholeQuery(Map parameter, String text) {
    final content = (parameter['content'] as List).whereType<Map>().toList();
    if (content.length != 1) {
      throw CoreFailure(
        'request.querystring.media',
        'Select a single whole-query representation.',
      );
    }
    final media = (content.single['mediaType'] as String)
        .split(';')
        .first
        .toLowerCase();
    if (media == 'application/x-www-form-urlencoded') {
      if (RegExp(r'[\x00-\x20\x7f#]').hasMatch(text) ||
          RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(text)) {
        throw CoreFailure(
          'request.querystring.encoding',
          'Whole-query form content must already be valid form-encoded pairs.',
        );
      }
      return text;
    }
    if (media == 'application/json' ||
        media.endsWith('+json') ||
        media == 'text/plain') {
      return _encode(text, false);
    }
    throw CoreFailure(
      'request.querystring.media',
      'This whole-query media representation is unsupported.',
    );
  }

  static String _encode(String value, bool allowReserved) {
    var encoded = Uri.encodeComponent(value).replaceAllMapped(
      RegExp(r"[!'()*]"),
      (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
    );
    if (allowReserved) {
      const retained = {
        '%3A': ':',
        '%2F': '/',
        '%3F': '?',
        '%5B': '[',
        '%5D': ']',
        '%40': '@',
        '%21': '!',
        '%24': r'$',
        '%27': "'",
        '%28': '(',
        '%29': ')',
        '%2A': '*',
        '%2B': '+',
        '%2C': ',',
        '%3B': ';',
      };
      for (final entry in retained.entries) {
        encoded = encoded
            .replaceAll(entry.key, entry.value)
            .replaceAll(entry.key.toLowerCase(), entry.value);
      }
      // Reserved expansion passes existing percent triples through once. Do
      // this after restoring reserved characters so %26/%3D/%23 stay encoded.
      encoded = encoded.replaceAllMapped(
        RegExp(r'%25([0-9A-Fa-f]{2})'),
        (match) => '%${match[1]}',
      );
    }
    return encoded;
  }

  // OAS Encoding Objects use query expansion with additional form delimiters
  // escaped. A literal plus must survive form decoding as plus, not space.
  static String _formStyleEncode(String value, bool allowReserved) => _encode(
    value,
    allowReserved,
  ).replaceAll('+', '%2B').replaceAll('[', '%5B').replaceAll(']', '%5D');

  static void _addHeader(
    List<(String, String)> headers,
    String name,
    String value, {
    bool allowHorizontalTab = false,
  }) {
    if (!RegExp(r"^[!#\$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(name) ||
        (allowHorizontalTab
                ? RegExp(r'[\x00-\x08\x0a-\x1f\x7f]')
                : RegExp(r'[\x00-\x1f\x7f]'))
            .hasMatch(value)) {
      throw CoreFailure(
        'request.header.injection',
        'Header names and values must not contain control characters',
      );
    }
    final lower = name.toLowerCase();
    if (name.length > 1024 ||
        value.length > 65536 ||
        headers.length >= 2048 ||
        headers.fold<int>(0, (n, h) => n + h.$1.length + h.$2.length) +
                name.length +
                value.length >
            1024 * 1024) {
      throw CoreFailure(
        'request.headers.limit',
        'Request headers exceed their bounded field or total size. Reduce the supplied headers.',
      );
    }
    if (const {
      'host',
      'content-length',
      'transfer-encoding',
      'connection',
      'proxy-connection',
      'keep-alive',
      'upgrade',
      'te',
      'trailer',
    }.contains(lower)) {
      throw CoreFailure(
        'request.header.restricted',
        'Header $name is owned by the native transport',
      );
    }
    if (const {
          'content-type',
          'authorization',
          'proxy-authorization',
          'cookie',
        }.contains(lower) &&
        headers.any((entry) => entry.$1.toLowerCase() == lower)) {
      throw CoreFailure(
        'request.header.collision',
        'Header $name is supplied by conflicting independent inputs. Remove one source before Send.',
      );
    }
    headers.add((name, value));
  }

  static Future<void> _applySecurity(
    String schemeName,
    Map<String, dynamic> declaration,
    Map<String, dynamic> configuration,
    SecretResolver resolver,
    List<(String, String)> headers,
    List<(String, String, bool, bool)> query,
    Uri base,
    List<(String, String)> cookies,
    Set<String> sensitiveHeaders,
    Set<String> sensitiveQuery,
  ) async {
    Future<String> secret(String key) async {
      final reference = configuration[key] ?? configuration['secretRef'];
      if (reference is! String || !_secretReference.hasMatch(reference)) {
        throw CoreFailure(
          'secret.reference',
          'Configure a BusyAPI secret reference for $schemeName',
        );
      }
      final value = await resolver(reference);
      if (value == null || value.isEmpty) {
        throw CoreFailure(
          'secret.unavailable',
          'The selected $schemeName secret is unavailable; choose session-only input or unlock Secret Service',
        );
      }
      if (value.length > 64 * 1024 || value.contains('\u0000')) {
        throw CoreFailure(
          'secret.value',
          'A resolved secret is invalid or too large',
        );
      }
      return value;
    }

    final type = declaration['type'];
    if (type == 'apiKey') {
      final value = await secret('secretRef'),
          name = declaration['parameterName'];
      if (name is! String || name.isEmpty) {
        throw CoreFailure(
          'request.security.scheme',
          'API key scheme $schemeName is incomplete',
        );
      }
      switch (declaration['in']) {
        case 'header':
          if (headers.any(
            (entry) => entry.$1.toLowerCase() == name.toLowerCase(),
          )) {
            throw CoreFailure(
              'request.security.collision',
              'Header $name already has an explicit value',
            );
          }
          _addHeader(headers, name, value);
          sensitiveHeaders.add(name.toLowerCase());
        case 'query':
          if (base.query
                  .split('&')
                  .any(
                    (part) =>
                        Uri.decodeQueryComponent(part.split('=').first) == name,
                  ) ||
              query.any(
                (entry) =>
                    entry.$1 == name ||
                    entry.$1.isEmpty &&
                        entry.$2
                            .split('&')
                            .any(
                              (pair) =>
                                  Uri.decodeQueryComponent(
                                    pair.split('=').first,
                                  ) ==
                                  name,
                            ),
              )) {
            throw CoreFailure(
              'request.security.collision',
              'Query input $name already has an explicit value',
            );
          }
          query.add((name, value, false, false));
          sensitiveQuery.add(name);
        case 'cookie':
          if (cookies.any((entry) => entry.$1 == name)) {
            throw CoreFailure(
              'request.security.collision',
              'Cookie $name already has an explicit value',
            );
          }
          cookies.add((name, value));
          sensitiveQuery.add(name);
        default:
          throw CoreFailure(
            'request.security.scheme',
            'API key scheme $schemeName has an unsupported location',
          );
      }
      return;
    }
    if (type == 'http' &&
        '${declaration['scheme']}'.toLowerCase() == 'bearer') {
      if (headers.any((entry) => entry.$1.toLowerCase() == 'authorization')) {
        throw CoreFailure(
          'request.security.collision',
          'Authorization already has an explicit value',
        );
      }
      _addHeader(
        headers,
        'Authorization',
        'Bearer ${await secret('tokenRef')}',
      );
      return;
    }
    if (type == 'http' && '${declaration['scheme']}'.toLowerCase() == 'basic') {
      final username = configuration['username'];
      if (username is! String ||
          username.contains(':') ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(username)) {
        throw CoreFailure(
          'request.security.configuration',
          'Basic authentication requires a username without a colon',
        );
      }
      final encoded = base64.encode(
        utf8.encode('$username:${await secret('passwordRef')}'),
      );
      if (headers.any((entry) => entry.$1.toLowerCase() == 'authorization')) {
        throw CoreFailure(
          'request.security.collision',
          'Authorization already has an explicit value',
        );
      }
      _addHeader(headers, 'Authorization', 'Basic $encoded');
      return;
    }
    if (type == 'oauth2') {
      if (headers.any((entry) => entry.$1.toLowerCase() == 'authorization')) {
        throw CoreFailure(
          'request.security.collision',
          'Authorization already has an explicit value',
        );
      }
      _addHeader(
        headers,
        'Authorization',
        'Bearer ${await secret('accessTokenRef')}',
      );
      return;
    }
    if (type == 'mutualTLS') return;
    throw CoreFailure(
      'request.security.unsupported',
      'Security scheme $schemeName is authored but not supported for execution',
    );
  }

  Future<PreparedRequestBody?> _body(
    OperationRequestPlan plan,
    RequestBodyDraft body,
    Map? declaration,
    RunCancellation? cancellation,
    void Function() checkOwner,
  ) async {
    checkOwner();
    if (body.fields.length > 2048) {
      throw CoreFailure(
        'limit.request.fields',
        'Form input exceeds 2048 fields.',
      );
    }
    // Picker metadata is captured input even when the contract selects another
    // media type. Reject malformed headers before acquiring any file bytes.
    for (final file in body.files) {
      _mediaType(file.mediaType);
      if (file.selectedMediaType != null) _mediaType(file.selectedMediaType!);
    }
    if (body.kind == RequestBodyKind.multipart &&
        (declaration?['prefixEncoding'] != null ||
            declaration?['itemEncoding'] != null)) {
      throw CoreFailure(
        'request.multipart.encoding',
        'Positional multipart encodings are unsupported; no request was sent.',
        kind: CoreFailureKind.unsupported,
      );
    }
    final nativeForm =
        body.kind == RequestBodyKind.form ||
            body.kind == RequestBodyKind.multipart
        ? (declaration?['swaggerForm'] as List?)?.whereType<Map>().toList()
        : null;
    final data =
        body.text != null &&
            (body.kind == RequestBodyKind.form ||
                body.kind == RequestBodyKind.multipart)
        ? await plan.formData(
            body.text!,
            requestId: 'form-${_runIdentity()}',
            cancellation: cancellation,
          )
        : null;
    checkOwner();
    cancellation?.throwIfCancelled();
    final resolvedMediaTypes =
        (body.kind == RequestBodyKind.form ||
            body.kind == RequestBodyKind.multipart)
        ? await plan.formMediaTypes(
            body.mediaType!,
            {
              ...body.fields.map((field) => field.name),
              if (data != null)
                ...data.fields.entries
                    .where(
                      (entry) =>
                          entry.value.kind != RequestDataKind.array ||
                          entry.value.items.isNotEmpty,
                    )
                    .map((entry) => entry.key),
            },
            body.partMediaTypes,
            files: [
              for (final file in body.files)
                {
                  'name': file.name,
                  'fallback': file.mediaType,
                  if (file.selectedMediaType != null)
                    'selected': file.selectedMediaType!,
                },
            ],
            requestId: 'form-media-${_runIdentity()}',
            cancellation: cancellation,
          )
        : const ResolvedFormMediaTypes({}, []);
    final partMediaTypes = resolvedMediaTypes.fields;
    checkOwner();
    cancellation?.throwIfCancelled();
    final transfers = body.kind == RequestBodyKind.multipart
        ? await plan.multipartEncoding(
            body.mediaType!,
            data == null
                ? [
                    for (final field in body.fields)
                      {'name': field.name, 'kind': 'literal'},
                  ]
                : [
                    for (final entry in data.fields.entries)
                      for (final value
                          in entry.value.kind == RequestDataKind.array
                              ? entry.value.items
                              : [entry.value])
                        {
                          'name': entry.key,
                          'kind':
                              '${entry.value.kind == RequestDataKind.array ? 'item-' : ''}${value.kind == RequestDataKind.string ? 'string' : 'other'}',
                        },
                  ],
            [for (final file in body.files) file.name],
            requestId: 'multipart-${_runIdentity()}',
            cancellation: cancellation,
          )
        : const <String, MultipartPartEncoding>{};
    checkOwner();
    cancellation?.throwIfCancelled();
    var fields = nativeForm == null
        ? body.fields
        : data != null
        ? swaggerFormDataFields(
            data,
            nativeForm,
            body.files.map((file) => file.name),
          ).map((field) => RequestFormField(field.$1, field.$2)).toList()
        : swaggerFormFields(
            [for (final field in body.fields) (field.name, field.value)],
            nativeForm,
            body.files.map((file) => file.name),
          ).map((field) => RequestFormField(field.$1, field.$2)).toList();
    final formParameters = data == null || nativeForm == null
        ? null
        : <RuntimeSchemaInstance>[
            for (final declaration in nativeForm)
              if (declaration['type'] != 'file' &&
                  data.fields.containsKey(declaration['name']) &&
                  !(data.fields[declaration['name']]!.kind ==
                          RequestDataKind.array &&
                      data.fields[declaration['name']]!.items.isEmpty))
                RuntimeSchemaInstance(
                  subject: 'request-parameter',
                  location: 'formData:${declaration['name']}',
                  text: data.fields[declaration['name']]!.raw,
                  schemaResource:
                      (declaration['schema'] as Map)['resource'] as String,
                  schemaPointer:
                      (declaration['schema'] as Map)['pointer'] as String,
                ),
          ];
    PreparedFormValues? form;
    final partTypes = <String, String>{};
    final encodedFields = <RequestFormField>{};
    final fieldOwners = <RequestFormField, String>{};
    final fieldTransfers = <RequestFormField, MultipartTransferEncoding?>{};
    final multipart = body.kind == RequestBodyKind.multipart;
    if (nativeForm == null &&
        declaration?['form'] is Map &&
        (multipart || body.kind == RequestBodyKind.form)) {
      cancellation?.throwIfCancelled();
      form = await prepareFormValues(
        [for (final field in fields) (field.name, field.value)],
        declaration!,
        multipart,
        plan.parameterValues,
        data: data,
        mediaTypes: partMediaTypes,
        transfers: transfers,
      );
      checkOwner();
      cancellation?.throwIfCancelled();
      final serialized = <RequestFormField>[
        for (final part in form.content) RequestFormField(part.name, part.text),
      ];
      for (final (index, part) in form.content.indexed) {
        fieldTransfers[serialized[index]] = part.transfer;
      }
      for (final part in form.content) {
        validateTextCharset(part.contentType, [part.text]);
        validateTextCharset(body.mediaType!, [part.name, part.text]);
        partTypes[part.name] = part.contentType;
      }
      for (final group in form.styled) {
        final value = group.value;
        if (value is List && value.any((v) => v is List || v is Map) ||
            value is Map && value.values.any((v) => v is List || v is Map)) {
          throw CoreFailure(
            'request.form.style',
            'Nested RFC6570 form values have no defined serialization. Choose a content encoding.',
          );
        }
        validateTextCharset(body.mediaType!, [
          group.name,
          if (value is List)
            for (final item in value) item == null ? 'null' : '$item'
          else if (value is Map)
            for (final entry in value.entries) ...[
              '${entry.key}',
              entry.value == null ? 'null' : '${entry.value}',
            ]
          else
            value == null ? 'null' : '$value',
        ]);
        final style = group.rule['style'] as String? ?? 'form';
        final pairs = _serializeParameter(
          {
            'name': group.name,
            'in': 'query',
            'style': style,
            'explode': group.rule['explode'] ?? (style == 'form'),
            'allowReserved': group.rule['allowReserved'] == true,
          },
          value,
          '',
          structured: true,
          encodeValue: multipart
              ? (value) => value
              : (value) => _formStyleEncode(
                  value,
                  group.rule['allowReserved'] == true,
                ),
        );
        for (final pair in pairs) {
          final field = RequestFormField(pair.$1, pair.$2);
          final options = transfers[group.name];
          final transfer = options?.strings ?? options?.other;
          if (transfer?.schemaEncoded == true && value is! String) {
            throw CoreFailure(
              'request.multipart.encoding.undefined',
              'A combined style value cannot use one item transfer encoding.',
              kind: CoreFailureKind.unsupported,
            );
          }
          serialized.add(field);
          fieldTransfers[field] = transfer;
          encodedFields.add(field);
          fieldOwners[field] = group.name;
          partTypes[pair.$1] = 'text/plain';
        }
      }
      fields = serialized;
    }
    switch (body.kind) {
      case RequestBodyKind.none:
        return null;
      case RequestBodyKind.raw:
        final bytes = Uint8List.fromList(utf8.encode(body.text ?? ''));
        _uploadLimit(bytes.length);
        return PreparedRequestBody(
          bytes.length,
          () => Stream.value(bytes),
          mediaType: body.mediaType,
        );
      case RequestBodyKind.form:
        // Style values already contain the RFC6570 separators and escapes.
        // Content values use RFC1866 form encoding after media serialization.
        final text = [
          for (final field in fields)
            '${encodedFields.contains(field) ? _formStyleEncode(field.name, false) : Uri.encodeQueryComponent(field.name)}=${encodedFields.contains(field) ? field.value : Uri.encodeQueryComponent(field.value)}',
        ].join('&');
        final bytes = Uint8List.fromList(utf8.encode(text));
        _uploadLimit(bytes.length);
        return PreparedRequestBody(
          bytes.length,
          () => Stream.value(bytes),
          mediaType: body.mediaType,
          formInstance: form?.instance,
          formParameters: formParameters,
        );
      case RequestBodyKind.binaryFile:
        return _fileBody(
          body.file!,
          body.mediaType,
          cancellation,
          checkOwner: checkOwner,
        );
      case RequestBodyKind.multipart:
        if (ContentType.parse(body.mediaType!).parameters
            .containsKey('boundary')) {
          throw CoreFailure(
            'request.multipart.boundary',
            'This declaration fixes a multipart boundary. Use its complete serialized example, or choose a declaration whose boundary can be generated.',
          );
        }
        final random = Random.secure();
        final boundary =
            'busyapi-${List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
        final chunks = <Object>[];
        final captures = <PreparedRequestBody>[];
        try {
          var length = 0;
          var typedFiles = form?.instance != null;
          var instanceBytes = form?.instance == null
              ? 0
              : utf8.encode(form!.instance!).length;
          final fileInstances = <String, List<String>>{};
          final replacedFields = <String>{};
          void bytes(String value) {
            final encoded = Uint8List.fromList(utf8.encode(value));
            _uploadLimit(length + encoded.length);
            chunks.add(encoded);
            length += encoded.length;
          }

          void octets(List<int> value) {
            _uploadLimit(length + value.length);
            chunks.add(Uint8List.fromList(value));
            length += value.length;
          }

          String partHeaders(
            String name, {
            String? text,
            String? mediaType,
            MultipartTransferEncoding? transfer,
          }) {
            final type = mediaType ?? partMediaTypes[name] ?? partTypes[name];
            var output = '';
            if (type != null) {
              _mediaType(type);
              if (text != null) validateTextCharset(type, [text]);
              output = 'Content-Type: $type\r\n';
            }
            if (transfer?.encoding case final String value) {
              final validated = <(String, String)>[];
              _addHeader(validated, 'Content-Transfer-Encoding', value);
              output += 'Content-Transfer-Encoding: $value\r\n';
            }
            return output;
          }

          for (final field in fields) {
            _partName(field.name);
            final transfer = fieldTransfers[field];
            final type =
                partMediaTypes[fieldOwners[field] ?? field.name] ??
                partTypes[field.name] ??
                'text/plain';
            final Uint8List content;
            try {
              content = await multipartTextBytes(
                field.value,
                transfer,
                textual: ContentType.parse(type).primaryType == 'text',
              );
            } on CoreFailure catch (failure) {
              throw _multipartFailure(failure, transfer, field.name);
            }
            if (typedFiles &&
                transfer?.instanceEncoding ==
                    MultipartInstanceEncoding.octets) {
              final instance = await multipartOctetInstance(
                utf8.encode(field.value),
                16 * 1024 * 1024 - instanceBytes,
              );
              if (instance == null) {
                typedFiles = false;
              } else {
                final name = fieldOwners[field] ?? field.name;
                instanceBytes += instance.byteLength;
                (fileInstances[name] ??= []).add(instance.json);
                replacedFields.add(name);
              }
            }
            checkOwner();
            cancellation?.throwIfCancelled();
            bytes(
              '--$boundary\r\nContent-Disposition: form-data; name="${_quoted(field.name)}"\r\n${partHeaders(fieldOwners[field] ?? field.name, text: field.value, transfer: transfer)}\r\n',
            );
            octets(content);
            bytes('\r\n');
          }
          for (final (index, item) in body.files.indexed) {
            _partName(item.name);
            final mediaType = resolvedMediaTypes.files[index];
            _mediaType(mediaType);
            _uploadLimit(length);
            final captured = await _fileBody(
              item.path,
              mediaType,
              cancellation,
              remainingBytes: maximumUploadBytes - length,
              checkOwner: checkOwner,
            );
            captures.add(captured);
            final transfer = transfers[item.name]?.strings;
            final encoded = transfer?.encoding == null
                ? captured
                : await _multipartFile(
                    captured,
                    transfer!,
                    cancellation,
                    checkOwner,
                    maximumUploadBytes - length,
                  ).onError<CoreFailure>(
                    (failure, _) =>
                        throw _multipartFailure(failure, transfer, item.name),
                  );
            if (!identical(encoded, captured)) captures.add(encoded);
            final size = encoded.length;
            final octets =
                transfer?.instanceEncoding == MultipartInstanceEncoding.octets;
            final instanceBody = octets ? captured : encoded;
            if (typedFiles &&
                (octets || transfer?.schemaEncoded == true) &&
                instanceBytes + instanceBody.length < 16 * 1024 * 1024) {
              final capturedBytes = BytesBuilder(copy: false);
              await for (final chunk in instanceBody.open()) {
                checkOwner();
                cancellation?.throwIfCancelled();
                capturedBytes.add(chunk);
              }
              try {
                final ({String json, int byteLength})? instance;
                if (octets) {
                  instance = await multipartOctetInstance(
                    capturedBytes.takeBytes(),
                    16 * 1024 * 1024 - instanceBytes,
                  );
                } else {
                  var text = utf8.decode(capturedBytes.takeBytes());
                  if (transfer!.encoding!.toLowerCase() == 'base64')
                    text = text.replaceAll('\r\n', '');
                  final json = jsonEncode(text);
                  instance = (json: json, byteLength: utf8.encode(json).length);
                }
                if (instance == null) {
                  typedFiles = false;
                } else {
                  instanceBytes += instance.byteLength;
                  (fileInstances[item.name] ??= []).add(instance.json);
                }
              } on FormatException {
                typedFiles = false;
              }
            } else {
              typedFiles = false;
            }
            final filename = item.filename ?? p.basename(item.path);
            _partName(filename);
            final headers = partHeaders(
              item.name,
              mediaType: mediaType,
              transfer: transfer,
            );
            bytes(
              '--$boundary\r\nContent-Disposition: form-data; name="${_quoted(item.name)}"; filename="${_quoted(filename)}"\r\n$headers\r\n',
            );
            chunks.add(encoded);
            length += size;
            bytes('\r\n');
          }
          bytes('--$boundary--\r\n');
          _uploadLimit(length);
          var instance = typedFiles ? form?.instance : null;
          if (fileInstances.isNotEmpty &&
              typedFiles &&
              instanceBytes < 16 * 1024 * 1024) {
            final values = await plan.formData(
              form!.instance!,
              requestId: 'multipart-instance-${_runIdentity()}',
              cancellation: cancellation,
            );
            instance = multipartInstanceWithFiles(
              values,
              fileInstances,
              declaration!,
              replacedFields: replacedFields,
            );
            if (utf8.encode(instance).length > 16 * 1024 * 1024)
              instance = null;
          }
          checkOwner();
          cancellation?.throwIfCancelled();
          return PreparedRequestBody(
            length,
            () async* {
              for (final chunk in chunks) {
                if (chunk is Uint8List) {
                  yield chunk;
                } else {
                  yield* (chunk as PreparedRequestBody).open();
                }
              }
            },
            mediaType: '${body.mediaType}; boundary=$boundary',
            formInstance: instance,
            formParameters: formParameters,
            release: () async {
              for (final captured in captures) {
                await captured.close();
              }
            },
          );
        } on Object {
          for (final captured in captures) {
            await captured.close();
          }
          rethrow;
        }
    }
  }

  CoreFailure _multipartFailure(
    CoreFailure failure,
    MultipartTransferEncoding? transfer,
    String name,
  ) {
    if (!failure.code.startsWith('request.multipart.')) return failure;
    final resource = transfer?.resource,
        pointer = transfer?.pointer,
        range = transfer?.range;
    return CoreFailure(
      failure.code,
      'Part $name: ${failure.message}',
      kind: failure.kind,
      source:
          failure.source ??
          (resource != null && pointer != null && range != null
              ? CoreFailureSource(resource, pointer, range)
              : null),
    );
  }

  Future<PreparedRequestBody> _multipartFile(
    PreparedRequestBody source,
    MultipartTransferEncoding transfer,
    RunCancellation? cancellation,
    void Function() checkOwner,
    int remainingBytes,
  ) async {
    if (transfer.encoding == 'binary' || transfer.encoding == 'identity')
      return source;
    final temp = await Directory.systemTemp.createTemp('busyapi-multipart-');
    final file = File(p.join(temp.path, 'part.bin'));
    final sink = file.openWrite();
    var length = 0, buffered = 0;
    try {
      await for (final bytes in multipartTransferBytes(
        source.open(),
        transfer,
        textual:
            source.mediaType != null &&
            ContentType.parse(source.mediaType!).primaryType == 'text',
      )) {
        checkOwner();
        cancellation?.throwIfCancelled();
        if (length + bytes.length > remainingBytes) {
          throw CoreFailure(
            'limit.request.body',
            'The encoded multipart file exceeds the remaining transport limit.',
          );
        }
        sink.add(bytes);
        length += bytes.length;
        buffered += bytes.length;
        if (buffered >= 262144) {
          await sink.flush();
          buffered = 0;
        }
      }
      await sink.flush();
      await sink.close();
      checkOwner();
      cancellation?.throwIfCancelled();
      return PreparedRequestBody(
        length,
        file.openRead,
        release: () async {
          if (await temp.exists()) await temp.delete(recursive: true);
        },
      );
    } on Object {
      try {
        await sink.close();
      } on FileSystemException {
        /* Preserve the preparation failure. */
      }
      if (await temp.exists()) await temp.delete(recursive: true);
      rethrow;
    }
  }

  Future<PreparedRequestBody> _fileBody(
    String path,
    String? mediaType,
    RunCancellation? cancellation, {
    int? remainingBytes,
    void Function()? checkOwner,
  }) async {
    final temp = await Directory.systemTemp.createTemp('busyapi-upload-');
    final captured = File(p.join(temp.path, 'body.bin'));
    ProjectAccess? access;
    try {
      access = await ProjectAccess.open(p.dirname(path));
      final length = await access.captureUpload(
        path,
        captured,
        maximumBytes: min(
          maximumUploadBytes,
          remainingBytes ?? maximumUploadBytes,
        ),
        checkCurrent: () {
          checkOwner?.call();
          cancellation?.throwIfCancelled();
        },
      );
      cancellation?.throwIfCancelled();
      return PreparedRequestBody(
        length,
        captured.openRead,
        mediaType: mediaType,
        release: () async {
          try {
            if (await temp.exists()) await temp.delete(recursive: true);
          } on FileSystemException {
            /* Best effort private-resource cleanup. */
          }
        },
      );
    } on Object {
      await temp.delete(recursive: true);
      rethrow;
    } finally {
      access?.close();
    }
  }

  void _uploadLimit(int length) {
    if (length > maximumUploadBytes) {
      throw CoreFailure(
        'limit.request.body',
        'Request body exceeds the $maximumUploadBytes-byte transport limit',
      );
    }
  }

  static void _partName(String value) {
    if (value.isEmpty ||
        value.length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw CoreFailure(
        'request.multipart.name',
        'Multipart names must be bounded printable text',
      );
    }
  }

  static String _quoted(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  static void validateTextCharset(String mediaType, Iterable<String> values) {
    _mediaType(mediaType);
    final charset = ContentType.parse(mediaType).charset?.toLowerCase();
    if (charset != null && charset != 'utf-8' && charset != 'us-ascii') {
      throw CoreFailure(
        'request.charset.unsupported',
        'Choose UTF-8; this request charset is unsupported.',
      );
    }
    if (charset == 'us-ascii' &&
        values.any((v) => v.runes.any((r) => r > 127))) {
      throw CoreFailure(
        'request.charset',
        'The selected ASCII charset cannot encode this value.',
      );
    }
  }

  static void _mediaType(String value) {
    try {
      final parsed = ContentType.parse(value);
      if (RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+$")
              .hasMatch(parsed.mimeType) &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        return;
      }
    } on FormatException {
      /* The authored wire media type remains invalid. */
    } on HttpException {
      /* The pinned header parser also rejects malformed parameters this way. */
    }
    throw CoreFailure('request.media-type', 'Choose a valid media type');
  }

  static Map<String, Object?> effectiveTls(
    ExecutionEnvironment? environment,
    Map<String, String> selectedFiles,
  ) =>
      <String, Object?>{...?environment?.tls, ...selectedFiles}
        ..removeWhere((_, value) => value == '');

  static Future<RequestTlsConfiguration> _tls(
    OperationRequestPlan plan,
    ExecutionEnvironment? environment,
    SecretResolver resolver,
    Map<String, String> selectedFiles,
  ) async {
    if (selectedFiles.keys.any(
      (key) => !const [
        'caFile',
        'clientCertificateFile',
        'clientKeyFile',
      ].contains(key),
    )) {
      throw CoreFailure('environment.tls', 'Unknown selected TLS material');
    }
    final tls = effectiveTls(environment, selectedFiles);
    Future<Uint8List?> read(String key) async {
      final value = tls[key];
      if (value == null) return null;
      return plan.readProjectFile(value as String);
    }

    String? password;
    final reference = tls['clientKeyPasswordRef'];
    if (reference != null) {
      if (reference is! String || !_secretReference.hasMatch(reference)) {
        throw CoreFailure(
          'secret.reference',
          'TLS key password requires a BusyAPI secret reference',
        );
      }
      password = tls['clientKeyFile'] == null
          ? null
          : await resolver(reference);
      if (tls['clientKeyFile'] != null && password == null) {
        throw CoreFailure(
          'secret.unavailable',
          'The selected client-certificate key secret is unavailable',
        );
      }
    }
    final result = RequestTlsConfiguration(
      ca: await read('caFile'),
      certificate: await read('clientCertificateFile'),
      privateKey: await read('clientKeyFile'),
      privateKeyPassword: password,
    );
    if ((result.certificate == null) != (result.privateKey == null)) {
      throw CoreFailure(
        'environment.tls',
        'Client certificate and private key must be configured together',
      );
    }
    return result;
  }

  static String _joinUrlPath(String base, String operation) {
    if (!operation.startsWith('/')) {
      throw CoreFailure('request.path', 'Operation path must start with /');
    }
    if (base.isEmpty || base == '/') return operation;
    return '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}$operation';
  }

  static String _redactedUri(Uri uri, Set<String> sensitive) {
    if (sensitive.isEmpty || !uri.hasQuery) return uri.toString();
    final parts = uri.query
        .split('&')
        .map((part) {
          final index = part.indexOf('=');
          final name = Uri.decodeQueryComponent(
            index < 0 ? part : part.substring(0, index),
          );
          return sensitive.contains(name)
              ? '${Uri.encodeQueryComponent(name)}=%5BREDACTED%5D'
              : part;
        })
        .join('&');
    final value = uri.toString(), queryAt = value.indexOf('?');
    return '${queryAt < 0 ? value : value.substring(0, queryAt)}?$parts';
  }

  static String _runIdentity() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return sha256.convert(bytes).toString();
  }

  static bool _mediaMatches(String actual, String declared) =>
      selectDeclaredMedia([
        {'mediaType': declared},
      ], actual) !=
      null;
}

final RegExp _secretReference = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class ContractHttpResponse {
  ContractHttpResponse({
    required this.runId,
    required this.status,
    required this.reason,
    required this.headers,
    required this.bodyFile,
    required this.bodyLength,
    required this.bodyIdentity,
    required this.receiptComplete,
    required this.elapsed,
    required this.firstByte,
    required this.redirects,
    required this.displayBytes,
    this.incompleteReason,
    this.decodedBodyFile,
    this.ownedDirectory,
    int? decodedLength,
    int? receivedLength,
    this.decodingComplete = true,
    this.decodingReason,
  }) : decodedLength = decodedLength ?? bodyLength,
       receivedLength = receivedLength ?? bodyLength;
  final String runId, reason, bodyFile, bodyIdentity;
  final int status, bodyLength;
  final List<(String, String)> headers;
  final bool receiptComplete;
  final Duration elapsed, firstByte;
  final List<String> redirects;
  final Uint8List displayBytes;
  final String? incompleteReason;

  /// Original entity bytes remain in bodyFile. Inspection uses this separately
  /// bounded representation; receipt and decoding have independent outcomes.
  final String? decodedBodyFile, decodingReason, ownedDirectory;
  final int decodedLength, receivedLength;
  final bool decodingComplete;
  bool? _exampleSupported;
  bool get exampleEligible =>
      !_closed &&
      receiptComplete &&
      decodingComplete &&
      (_exampleSupported ??= _supportsExample());
  bool _supportsExample() {
    try {
      final contentType = headers
          .where((h) => h.$1.toLowerCase() == 'content-type')
          .firstOrNull;
      final charset = contentType == null
          ? null
          : ContentType.parse(contentType.$2).charset?.toLowerCase();
      if (charset == 'us-ascii') {
        return decodedLength == displayBytes.length &&
            !displayBytes.any((byte) => byte > 127);
      }
      return charset == null || charset == 'utf-8' || charset == 'utf8';
    } on Object {
      return false;
    }
  }

  bool _closed = false;
  Stream<List<int>> decodedChunks() async* {
    if (!decodingComplete) {
      throw CoreFailure(
        'response.decoding',
        'Complete decoded content is unavailable.',
      );
    }
    if (_closed) {
      throw CoreFailure('response.closed', 'Response bytes were released');
    }
    await for (final chunk in File(decodedBodyFile ?? bodyFile).openRead()) {
      if (_closed) {
        throw CoreFailure('response.closed', 'Response bytes were released');
      }
      yield chunk;
    }
  }

  Future<Uint8List> bytes() async {
    if (_closed) {
      throw CoreFailure('response.closed', 'Response bytes were released');
    }
    return File(bodyFile).readAsBytes();
  }

  Future<Uint8List> decodedBytes() async {
    if (_closed) {
      throw CoreFailure('response.closed', 'Response bytes were released');
    }
    if (!decodingComplete) {
      throw CoreFailure(
        'response.decoding',
        'Complete decoded content is unavailable: $decodingReason',
      );
    }
    return File(decodedBodyFile ?? bodyFile).readAsBytes();
  }

  Future<void> export(
    String destination, {
    Future<void> Function()? beforePublish,
    RunCancellation? cancellation,
    bool decoded = false,
  }) async {
    if (decoded && !decodingComplete) {
      throw CoreFailure(
        'response.decoding',
        'Complete decoded export is unavailable. Export original entity bytes instead.',
      );
    }
    if (_closed) {
      throw CoreFailure('response.closed', 'Response bytes were released');
    }
    cancellation?.throwIfCancelled();
    Stream<List<int>> bytes() async* {
      await for (final chunk in File(
        decoded ? decodedBodyFile ?? bodyFile : bodyFile,
      ).openRead()) {
        cancellation?.throwIfCancelled();
        yield chunk;
      }
    }

    await const AtomicFileWriter().writeStream(
      destination,
      bytes(),
      overwrite: false,
      beforePublish: () async {
        await beforePublish?.call();
        cancellation?.throwIfCancelled();
        if (_closed) {
          throw CoreFailure('response.closed', 'Response bytes were released');
        }
      },
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (ownedDirectory != null) {
        await Directory(ownedDirectory!).delete(recursive: true);
      } else if (await File(bodyFile).exists()) {
        await File(bodyFile).delete();
      }
    } on Object {
      /* Private temporary cleanup is best effort. */
    }
  }
}

abstract interface class ResponseStorage {
  Future<void> write(List<int> bytes);
  Future<void> flush();
  Future<void> close();
}

class FileResponseStorage implements ResponseStorage {
  FileResponseStorage._(this.file);
  final RandomAccessFile file;
  static Future<ResponseStorage> open(File file) async =>
      FileResponseStorage._(await file.open(mode: FileMode.write));
  @override
  Future<void> write(List<int> bytes) async {
    await file.writeFrom(bytes);
  }

  @override
  Future<void> flush() async {
    await file.flush();
  }

  @override
  Future<void> close() => file.close();
}

class ContractHttpTransport {
  const ContractHttpTransport({
    this.maximumResponseBytes = 256 * 1024 * 1024,
    this.maximumDisplayBytes = 1024 * 1024,
    this.maximumDecodedBytes = 256 * 1024 * 1024,
    this.maximumRedirects = 5,
    this.openResponseStorage,
    this.createResponseDirectory,
  });
  final int maximumResponseBytes, maximumDisplayBytes, maximumRedirects;
  final int maximumDecodedBytes;
  final Future<ResponseStorage> Function(File file)? openResponseStorage;
  final Future<Directory> Function()? createResponseDirectory;

  /// Explicit import acquisition: credential-free GET, one overall deadline,
  /// and exact-URL approval before *each* connection (including redirects).
  Future<(Uri, Uint8List)> acquireResource(
    Uri initial, {
    required bool Function(Uri) approved,
    RunCancellation? cancellation,
    int maximumBytes = 16 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..autoUncompress = false;
    final deadline = _HttpDeadline(client, timeout, cancellation);
    var uri = initial;
    try {
      for (var redirects = 0; ; redirects++) {
        if (!['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            !approved(uri)) {
          throw CoreFailure(
            'import.approval',
            'A resource or redirect URL needs explicit approval',
          );
        }
        final request = await deadline.wait(client.getUrl(uri));
        deadline.request = request;
        unawaited(
          request.done.then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          ),
        );
        request.followRedirects = false;
        final response = await deadline.wait(request.close());
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (redirects >= maximumRedirects || location == null) {
            throw CoreFailure(
              'import.redirect',
              'Import redirect limit or missing location',
            );
          }
          final target = uri.resolve(location);
          // Close the owned connection rather than draining an unbounded body.
          if (target.origin != uri.origin &&
              uri.scheme == 'https' &&
              target.scheme != 'https') {
            throw CoreFailure(
              'import.redirect',
              'HTTPS import cannot redirect to an unencrypted target',
            );
          }
          if (!approved(target)) {
            throw CoreFailure(
              'import.approval',
              'A redirect destination needs explicit approval',
            );
          }
          final iterator = StreamIterator<List<int>>(response);
          await iterator.cancel();
          uri = target;
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw CoreFailure(
            'import.http',
            'Import target did not return a successful HTTP response',
          );
        }
        final bytes = BytesBuilder(copy: false),
            iterator = StreamIterator<List<int>>(response);
        try {
          while (await deadline.wait(iterator.moveNext())) {
            bytes.add(iterator.current);
            if (bytes.length > maximumBytes) {
              throw CoreFailure(
                'limit.import',
                'Import resource exceeds its bounded byte limit',
              );
            }
          }
        } finally {
          await iterator.cancel();
        }
        final encoded = bytes.takeBytes();
        void active() {
          cancellation?.throwIfCancelled();
          if (deadline.reason != null) deadline.failure();
        }

        active();
        final encodings = response.headers[HttpHeaders.contentEncodingHeader];
        if (encodings == null) return (uri, encoded);
        // Import shares the response decoder's codecs and expansion bounds.
        // The acquired entity and every decoded layer have independent limits.
        final directory = await Directory.systemTemp.createTemp(
          'busyapi-import-',
        );
        late Uint8List acquired;
        try {
          privatePermissions(directory.path, 448);
          final original = File(p.join(directory.path, 'entity.bin'));
          await original.writeAsBytes(encoded);
          active();
          final decoded = await _decode(
            original,
            [
              for (final value in encodings)
                (HttpHeaders.contentEncodingHeader, value),
            ],
            cancellation,
            true,
            active,
            deadline: deadline,
            maximumBytes: maximumBytes,
          );
          active();
          if (decoded.$4 != null)
            throw CoreFailure(
              decoded.$4 == 'decoded-size-limit'
                  ? 'limit.import'
                  : 'import.encoding',
              'Import content decoding failed: ${decoded.$4}',
            );
          acquired = await File(decoded.$1!).readAsBytes();
        } finally {
          await directory.delete(recursive: true);
        }
        active();
        return (uri, acquired);
      }
    } on Object {
      if (cancellation?.cancelled == true || deadline.reason == 'cancelled') {
        throw CoreFailure('cancelled', 'Execution was cancelled');
      }
      if (deadline.reason == null) rethrow;
      throw CoreFailure(
        'import.timeout',
        'Import acquisition exceeded its overall deadline',
      );
    } finally {
      deadline.dispose();
      client.close(force: true);
    }
  }

  Future<ContractHttpResponse> send(
    PreparedContractRequest input, {
    RunCancellation? cancellation,
  }) async {
    try {
      input.plan.ensureCurrentPreparation();
      cancellation?.throwIfCancelled();
      final exact = input.method == input.method.toUpperCase()
          ? null
          : ExactHttpMethod(input.method);
      SecurityContext? context;
      try {
        context = input.tls.custom
            ? SecurityContext(withTrustedRoots: true)
            : null;
        if (input.tls.ca != null) {
          context!.setTrustedCertificatesBytes(input.tls.ca!);
        }
        if (input.tls.certificate != null) {
          context!.useCertificateChainBytes(input.tls.certificate!);
        }
        if (input.tls.privateKey != null) {
          context!.usePrivateKeyBytes(
            input.tls.privateKey!,
            password: input.tls.privateKeyPassword,
          );
        }
      } on Object {
        throw CoreFailure(
          'request.tls.material',
          'The selected TLS certificate/key could not be loaded. Check the matching files and the private-key password.',
        );
      }
      final client = HttpClient(context: context)
        ..connectionTimeout = input.connectTimeout
        ..autoUncompress = false;
      if (exact != null) {
        client.connectionFactory = (uri, proxyHost, proxyPort) =>
            exact.connect(uri, proxyHost, proxyPort, context: context);
      }
      final clock = Stopwatch()..start();
      final deadline = _HttpDeadline(
        client,
        input.overallTimeout,
        cancellation,
      );
      var uri = input.uri, method = input.method;
      final redirects = <String>[];
      try {
        for (var redirect = 0; ; redirect++) {
          cancellation?.throwIfCancelled();
          final request = await deadline.wait(
            client.openUrl(
              exact == null ? method : ExactHttpMethod.wireMethod,
              uri,
            ),
            limit: input.connectTimeout,
          );
          // Abort may happen before close() (for example during upload). Observe
          // the owned completion from creation so its error is never unhandled.
          unawaited(
            request.done.then<void>(
              (_) {},
              onError: (Object _, StackTrace __) {},
            ),
          );
          deadline.request = request;
          request.followRedirects = false;
          request.maxRedirects = 0;
          if (exact != null) request.persistentConnection = false;
          for (final header in input.headers) {
            request.headers.add(header.$1, header.$2, preserveHeaderCase: true);
          }
          if (input.body != null) {
            request.contentLength = input.body!.length;
            final upload = StreamIterator(input.body!.open());
            deadline.upload = upload;
            try {
              while (await deadline.wait(
                upload.moveNext(),
                limit: input.inactivityTimeout,
              )) {
                request.add(upload.current);
                await deadline.wait(
                  request.flush(),
                  limit: input.inactivityTimeout,
                );
              }
            } finally {
              await upload.cancel();
              deadline.upload = null;
            }
          }
          final response = await deadline.wait(
            request.close(),
            limit: input.inactivityTimeout,
          );
          final location = response.headers.value(HttpHeaders.locationHeader);
          final redirectStatus = const {
            301,
            302,
            303,
            307,
            308,
          }.contains(response.statusCode);
          if (redirectStatus &&
              location != null &&
              redirect < maximumRedirects &&
              (method == 'GET' || method == 'HEAD')) {
            final target = uri.resolve(location);
            if (!_sameOrigin(uri, target) || target.userInfo.isNotEmpty) {
              redirects.add(_sanitized(target, input));
              return await _collect(
                input,
                response,
                clock,
                redirects,
                cancellation,
                deadline,
                incompleteReason: target.userInfo.isNotEmpty
                    ? 'credential-bearing-redirect-not-followed'
                    : 'cross-origin-redirect-not-followed',
              );
            }
            await deadline.wait(
              response.timeout(input.inactivityTimeout).drain<void>(),
            );
            redirects.add(_sanitized(target, input));
            uri = target;
            continue;
          }
          return await _collect(
            input,
            response,
            clock,
            redirects,
            cancellation,
            deadline,
          );
        }
      } on TimeoutException {
        cancellation?.throwIfCancelled();
        throw CoreFailure(
          'request.timeout',
          'The request timed out without automatic replay',
        );
      } on SocketException {
        if (cancellation?.cancelled == true) {
          throw CoreFailure('cancelled', 'Execution was cancelled');
        }
        if (deadline.reason != null) {
          throw CoreFailure(
            'request.timeout',
            'The request timed out without automatic replay',
          );
        }
        throw CoreFailure(
          'request.transport',
          'The native HTTP transport could not reach the selected target',
        );
      } on HttpException {
        cancellation?.throwIfCancelled();
        if (deadline.reason != null) {
          throw CoreFailure(
            'request.timeout',
            'The request timed out without automatic replay',
          );
        }
        // HttpException can contain the complete URI, including credentials.
        throw CoreFailure(
          'request.transport.protocol',
          'The native HTTP exchange failed before a complete response was available',
        );
      } on HandshakeException {
        throw CoreFailure(
          'request.tls',
          'TLS verification or client authentication failed',
        );
      } on Object catch (error) {
        if (error is CoreFailure &&
            (error.code == 'response.storage' ||
                error.code == 'request.closed')) {
          rethrow;
        }
        cancellation?.throwIfCancelled();
        if (deadline.reason != null) {
          throw CoreFailure(
            'request.timeout',
            'The request timed out without automatic replay',
          );
        }
        rethrow;
      } finally {
        deadline.dispose();
        client.close(force: true);
      }
    } finally {
      await input.body?.close();
    }
  }

  Future<ContractHttpResponse> _collect(
    PreparedContractRequest input,
    HttpClientResponse response,
    Stopwatch clock,
    List<String> redirects,
    RunCancellation? cancellation,
    _HttpDeadline deadline, {
    String? incompleteReason,
  }) async {
    final firstByte = clock.elapsed;
    Directory? temp;
    final headers = <(String, String)>[];
    response.headers.forEach((name, values) {
      for (final value in values) {
        headers.add((name, value));
      }
    });
    final digest = _DigestSink();
    // Each write is awaited before asking the socket for another chunk. There
    // is no unobserved IOSink completion or unbounded pending write queue.
    ResponseStorage? storage;
    var count = 0, receivedCount = 0, complete = true, streamEnded = false;
    String? reason = incompleteReason;
    final hash = sha256.startChunkedConversion(digest);
    StreamSubscription<List<int>>? subscription;
    Future<void>? pendingWrite;
    Object? storageError;
    Timer? inactivity;
    try {
      cancellation?.throwIfCancelled();
      input.plan.ensureCurrentOwner();
      temp =
          await (createResponseDirectory?.call() ??
              Directory.systemTemp.createTemp('busyapi-response-'));
      cancellation?.throwIfCancelled();
      input.plan.ensureCurrentOwner();
      final file = File(p.join(temp.path, 'body.bin'));
      storage = await (openResponseStorage ?? FileResponseStorage.open)(file);
      final done = Completer<void>();
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      void arm() {
        inactivity?.cancel();
        inactivity = Timer(input.inactivityTimeout, () {
          reason = 'response-inactivity-timeout';
          complete = false;
          finish();
        });
      }

      subscription = response.listen(
        (chunk) {
          receivedCount += chunk.length;
          subscription!.pause();
          inactivity?.cancel();
          pendingWrite = () async {
            try {
              final retained = chunk.length > maximumResponseBytes - count
                  ? chunk.sublist(0, maximumResponseBytes - count)
                  : chunk;
              await storage!.write(retained);
              hash.add(retained);
              count += retained.length;
              if (retained.length != chunk.length) {
                reason = 'response-size-limit';
                complete = false;
                finish();
              } else if (!done.isCompleted) {
                arm();
                subscription!.resume();
              }
            } on Object catch (error) {
              storageError = error;
              finish();
            }
          }();
        },
        onDone: () {
          streamEnded = true;
          finish();
        },
        onError: (Object _) {
          complete = false;
          reason = cancellation?.cancelled == true
              ? 'cancelled'
              : 'response-stream-failed';
          finish();
        },
        cancelOnError: true,
      );
      arm();
      try {
        await deadline.wait(done.future);
      } on TimeoutException {
        complete = false;
        reason = deadline.reason ?? 'overall-timeout';
      } on CoreFailure catch (error) {
        if (error.code != 'cancelled') rethrow;
        complete = false;
        reason = 'cancelled';
      }
      inactivity?.cancel();
      await pendingWrite;
      await subscription.cancel();
      subscription = null;
      if (storageError != null) {
        throw CoreFailure('response.storage', 'Response storage write failed.');
      }
      // Do not detach writes on cancellation: close waits for the one owned
      // write to settle before either returning the owner or removing output.
      await storage.flush();
      await storage.close();
      storage = null;
      hash.close();
      if (deadline.reason != null && !streamEnded) {
        complete = false;
        reason = deadline.reason;
      }
      // No-body metadata needs no decoding. Some parsers still deliver illegal
      // content (notably for 205); retain it only as original bytes, never as a
      // successfully decoded empty representation.
      final decoded = _responseBodyPermitted(input.method, response.statusCode)
          ? await _decode(
              file,
              headers,
              cancellation,
              complete,
              input.plan.ensureCurrentOwner,
              deadline: deadline,
            )
          : receivedCount == 0
          ? (file.path, 0, Uint8List(0), null)
          : (null, 0, Uint8List(0), 'forbidden-response-content');
      input.plan.ensureCurrentOwner();
      return ContractHttpResponse(
        runId: input.runId,
        status: response.statusCode,
        reason: response.reasonPhrase,
        headers: List.unmodifiable(headers),
        bodyFile: file.path,
        ownedDirectory: temp.path,
        bodyLength: count,
        receivedLength: receivedCount,
        bodyIdentity: digest.single.toString(),
        receiptComplete: complete,
        elapsed: clock.elapsed,
        firstByte: firstByte,
        redirects: List.unmodifiable(redirects),
        displayBytes: decoded.$3,
        incompleteReason: reason,
        decodedBodyFile: decoded.$1,
        decodedLength: decoded.$2,
        decodingComplete: decoded.$4 == null,
        decodingReason: decoded.$4,
      );
    } on Object catch (error) {
      deadline.stop('response-storage-failed');
      await subscription?.cancel();
      try {
        await storage?.close();
      } on Object {
        /* Already failed. */
      }
      try {
        await temp?.delete(recursive: true);
      } on Object {
        /* Best effort. */
      }
      if (cancellation?.cancelled == true) cancellation!.throwIfCancelled();
      input.plan.ensureCurrentOwner();
      if (error is CoreFailure &&
          (error.code == 'cancelled' || error.code == 'request.closed')) {
        rethrow;
      }
      throw CoreFailure(
        'response.storage',
        'Response storage failed; check temporary disk space and permissions.',
      );
    } finally {
      inactivity?.cancel();
    }
  }

  Future<(String?, int, Uint8List, String?)> _decode(
    File original,
    List<(String, String)> headers,
    RunCancellation? cancellation,
    bool receiptComplete,
    void Function() checkOwner, {
    required _HttpDeadline deadline,
    int? maximumBytes,
  }) async {
    final decodedLimit = min(
      maximumDecodedBytes,
      maximumBytes ?? maximumDecodedBytes,
    );
    final encodings = headers
        .where((h) => h.$1.toLowerCase() == 'content-encoding')
        .expand((h) => h.$2.split(','))
        .map((e) => e.trim().toLowerCase())
        .where((e) => e != 'identity')
        .toList();
    if (encodings.any(
      (e) => e.isEmpty || !RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(e),
    )) {
      return (null, 0, Uint8List(0), 'malformed-content-encoding');
    }
    if (encodings.length > 8 || encodings.any((e) => e != 'gzip')) {
      return (null, 0, Uint8List(0), 'unsupported-content-encoding');
    }
    var source = original;
    var length = 0;
    final display = BytesBuilder(copy: false);
    String? problem;
    // Bound encoded input chunks as well as decoder output. A converter cannot
    // synchronously accumulate a whole expansion from a large socket chunk.
    Stream<List<int>> boundedInput(File file) async* {
      await for (final chunk in file.openRead()) {
        for (var offset = 0; offset < chunk.length; offset += 1024) {
          checkOwner();
          cancellation?.throwIfCancelled();
          yield chunk.sublist(offset, min(offset + 1024, chunk.length));
        }
      }
    }

    for (var layer = 0; layer < max(1, encodings.length); layer++) {
      final compressed = encodings.isNotEmpty;
      final target = File(
        p.join(p.dirname(original.path), 'decoded-$layer.bin'),
      );
      RandomAccessFile? output;
      length = 0;
      display.clear();
      try {
        output = await target.open(mode: FileMode.write);
        final stream = compressed
            ? gzip.decoder.bind(_gzipMemberChunks(boundedInput(source)))
            : boundedInput(source);
        await for (final chunk in stream) {
          cancellation?.throwIfCancelled();
          checkOwner();
          final remaining = decodedLimit - length;
          final retained = chunk.length > remaining
              ? chunk.sublist(0, remaining)
              : chunk;
          await output.writeFrom(retained);
          if (display.length < maximumDisplayBytes) {
            display.add(
              retained.sublist(
                0,
                min(retained.length, maximumDisplayBytes - display.length),
              ),
            );
          }
          length += retained.length;
          if (retained.length != chunk.length) {
            problem = 'decoded-size-limit';
            break;
          }
        }
        if (compressed && problem == null) {
          checkOwner();
          cancellation?.throwIfCancelled();
          await _verifyGzipFraming(source.path, decodedLimit, length, deadline);
          checkOwner();
          cancellation?.throwIfCancelled();
        }
      } on CoreFailure catch (error) {
        problem = error.code == 'cancelled' ? 'cancelled' : 'decoding-failed';
      } on FileSystemException {
        problem = 'decoded-storage-failed';
      } on Object {
        problem = receiptComplete
            ? 'malformed-content-encoding'
            : 'encoded-receipt-incomplete';
      } finally {
        try {
          await output?.close();
        } on Object {
          problem = 'decoded-storage-failed';
        }
      }
      if (source.path != original.path) {
        try {
          await source.delete();
        } on Object {
          /* Owned directory cleanup also removes it. */
        }
      }
      source = target;
      if (problem != null) break;
    }
    return (source.path, length, display.takeBytes(), problem);
  }

  Future<void> _verifyGzipFraming(
    String path,
    int limit,
    int expectedLength,
    _HttpDeadline deadline,
  ) async {
    final reply = ReceivePort(), exits = ReceivePort();
    final exited = exits.first, result = Completer<Object?>();
    final subscription = reply.listen((message) {
      if (!result.isCompleted) result.complete(message);
    });
    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        GzipFramingCheck.worker,
        (GzipFramingCheck(path, limit), reply.sendPort),
        onError: reply.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
      );
      deadline.decodingWorker = worker;
      final message = await deadline.wait(result.future);
      if (message is! int || message != expectedLength) {
        throw message is Exception
            ? message
            : const FormatException('Invalid gzip framing');
      }
    } finally {
      worker?.kill(priority: Isolate.immediate);
      if (identical(deadline.decodingWorker, worker))
        deadline.decodingWorker = null;
      if (worker != null) await exited;
      await subscription.cancel();
      reply.close();
      exits.close();
    }
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
  static String _sanitized(Uri uri, PreparedContractRequest input) {
    var summary = ContractRequestBuilder._redactedUri(
      uri.userInfo.isEmpty ? uri : uri.replace(userInfo: '%5BREDACTED%5D'),
      input.sensitiveQueryNames,
    );
    final values = <String>{
      if (input.tls.privateKeyPassword case final String password) password,
      if (input.sensitiveQueryNames.isNotEmpty)
        for (final part in input.uri.query.split('&'))
          if (input.sensitiveQueryNames.contains(
            Uri.decodeQueryComponent(part.split('=').first),
          ))
            Uri.decodeQueryComponent(
              part.contains('=') ? part.substring(part.indexOf('=') + 1) : '',
            ),
    };
    for (final header in input.headers) {
      if (!input.sensitiveHeaders.contains(header.$1.toLowerCase())) continue;
      values.add(header.$2);
      if (header.$1.toLowerCase() == 'cookie') {
        for (final pair in header.$2.split(';')) {
          final separator = pair.indexOf('=');
          if (separator > 0 &&
              input.sensitiveQueryNames.contains(
                pair.substring(0, separator).trim(),
              )) {
            values.add(pair.substring(separator + 1));
          }
        }
      } else if (header.$1.toLowerCase() == 'authorization') {
        final separator = header.$2.indexOf(' ');
        if (separator > 0) values.add(header.$2.substring(separator + 1));
        if (header.$2.toLowerCase().startsWith('basic ')) {
          try {
            final credential = utf8.decode(
              base64.decode(header.$2.substring(6)),
            );
            values.add(credential.substring(credential.indexOf(':') + 1));
          } on Object {
            /* An explicit opaque header remains inspectable. */
          }
        }
      }
    }
    final ordered = values.where((v) => v.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final value in ordered) {
      summary = _redactUriSecret(summary, value);
    }
    return summary;
  }

  static String _redactUriSecret(String summary, String value) {
    summary = summary.replaceAll(value, '[REDACTED]');
    final needle = utf8.encode(value);
    final prefix = Uint32List(needle.length);
    // KMP uses bounded, iterative prefix fallback even for repetitive secrets.
    for (var i = 1, matched = 0; i < needle.length; i++) {
      while (matched > 0 && needle[i] != needle[matched]) {
        matched = prefix[matched - 1];
      }
      if (needle[i] == needle[matched]) matched++;
      prefix[i] = matched;
    }
    for (final querySpaces in [false, if (value.contains(' ')) true]) {
      final raw = utf8.encode(summary), starts = Uint32List(needle.length);
      final output = BytesBuilder(copy: false);
      var matched = 0, tokens = 0, retained = 0;
      for (var at = 0; at < raw.length;) {
        final start = at;
        var byte = raw[at++];
        if (querySpaces && byte == 43) {
          byte = 32;
        } else if (byte == 37 && at + 1 < raw.length) {
          final high = _uriHex(raw[at]), low = _uriHex(raw[at + 1]);
          if (high >= 0 && low >= 0) {
            byte = high * 16 + low;
            at += 2;
          }
        }
        starts[tokens++ % needle.length] = start;
        while (matched > 0 && byte != needle[matched]) {
          matched = prefix[matched - 1];
        }
        if (byte == needle[matched]) matched++;
        if (matched == needle.length) {
          output.add(
            raw.sublist(
              retained,
              starts[(tokens - needle.length) % needle.length],
            ),
          );
          output.add(const [91, 82, 69, 68, 65, 67, 84, 69, 68, 93]);
          retained = at;
          matched = 0;
        }
      }
      if (retained != 0) {
        output.add(raw.sublist(retained));
        // Decode original UTF-8 URI slices, never percent-decoded query values.
        summary = utf8.decode(output.takeBytes());
      }
    }
    return summary;
  }

  static int _uriHex(int byte) => byte >= 48 && byte <= 57
      ? byte - 48
      : byte >= 65 && byte <= 70
      ? byte - 55
      : byte >= 97 && byte <= 102
      ? byte - 87
      : -1;
}

/// One monotonic transport lifetime. A timeout/cancel closes the actual socket
/// owner and upload subscription, not just the future presented to callers.
class _HttpDeadline {
  _HttpDeadline(this.client, Duration duration, this.cancellation) {
    timer = Timer(duration, () => stop('overall-timeout'));
    cancellation?.whenCancelled.then((_) {
      if (!disposed) stop('cancelled');
    });
  }
  final HttpClient client;
  final RunCancellation? cancellation;
  final stopped = Completer<void>();
  late final Timer timer;
  HttpClientRequest? request;
  Isolate? decodingWorker;
  StreamIterator<List<int>>? upload;
  String? reason;
  bool disposed = false;

  void stop(String value) {
    if (reason != null || disposed) return;
    reason = value;
    request?.abort();
    decodingWorker?.kill(priority: Isolate.immediate);
    client.close(force: true);
    final cancelledUpload = upload?.cancel();
    if (cancelledUpload != null) {
      unawaited(cancelledUpload.catchError((Object _, StackTrace _) {}));
    }
    stopped.complete();
  }

  Never failure() {
    if (reason == 'cancelled') {
      throw CoreFailure('cancelled', 'Execution was cancelled');
    }
    throw TimeoutException('HTTP deadline expired');
  }

  Future<T> wait<T>(Future<T> work, {Duration? limit}) async {
    if (reason != null) failure();
    Timer? stage;
    if (limit != null) stage = Timer(limit, () => stop('stage-timeout'));
    try {
      return await Future.any([work, stopped.future.then<T>((_) => failure())]);
    } finally {
      stage?.cancel();
    }
  }

  void dispose() {
    disposed = true;
    timer.cancel();
  }
}

class ContractConformance {
  const ContractConformance({
    required this.complete,
    required this.valid,
    required this.findings,
    required this.producer,
    required this.producerVersion,
    required this.coverage,
  });
  final bool complete, valid;
  final List<Map<String, Object?>> findings;
  final String producer, producerVersion;
  final Map<String, Object?> coverage;
  Map<String, Object?> toJson() => {
    'complete': complete,
    'valid': valid,
    'findings': findings,
    'producer': producer,
    'producerVersion': producerVersion,
    'coverage': coverage,
  };
}

class ContractRequestResult {
  const ContractRequestResult({
    required this.request,
    required this.response,
    required this.outgoing,
    required this.received,
  });
  final PreparedContractRequest request;
  final ContractHttpResponse response;
  final ContractConformance outgoing, received;
  bool get bodyPermitted =>
      _responseBodyPermitted(request.method, response.status);
  bool get outdated => request.plan.outdated;
  bool get conforming =>
      outgoing.complete &&
      outgoing.valid &&
      received.complete &&
      received.valid;
  Future<void> close() => response.close();
}

/// Body-, header-, and URL-free metadata suitable for bounded local history.
/// This intentionally cannot reconstruct or replay a request.
class ContractRequestRecord {
  const ContractRequestRecord({
    required this.recordedAt,
    required this.snapshot,
    required this.method,
    required this.operationPath,
    required this.environment,
    required this.status,
    required this.elapsedMilliseconds,
    required this.responseBytes,
    required this.receiptComplete,
    required this.conformanceComplete,
    required this.conforming,
  });

  factory ContractRequestRecord.fromResult(
    ContractRequestResult result, {
    required DateTime recordedAt,
  }) => ContractRequestRecord(
    recordedAt: recordedAt.toUtc(),
    snapshot: result.request.plan.snapshot.identity,
    method: result.request.method,
    operationPath: result.request.plan.operation['path'] as String,
    environment: result.request.environment,
    status: result.response.status,
    elapsedMilliseconds: result.response.elapsed.inMilliseconds,
    responseBytes: result.response.bodyLength,
    receiptComplete: result.response.receiptComplete,
    conformanceComplete: result.outgoing.complete && result.received.complete,
    conforming: result.conforming,
  );

  final DateTime recordedAt;
  final String snapshot, method, operationPath;
  final String? environment;
  final int status, elapsedMilliseconds, responseBytes;
  final bool receiptComplete, conformanceComplete, conforming;

  Map<String, Object?> toJson() => {
    'version': 1,
    'recordedAt': recordedAt.toIso8601String(),
    'snapshot': snapshot,
    'operation': {'method': method, 'path': operationPath},
    if (environment != null) 'environment': environment,
    'response': {
      'status': status,
      'elapsedMilliseconds': elapsedMilliseconds,
      'bytes': responseBytes,
      'receiptComplete': receiptComplete,
    },
    'conformance': {'complete': conformanceComplete, 'conforming': conforming},
  };
}

class ContractRequestExecutor {
  const ContractRequestExecutor({
    this.builder = const ContractRequestBuilder(),
    this.transport = const ContractHttpTransport(),
    this.maximumEvaluationBytes = 64 * 1024 * 1024,
  }) : assert(
         maximumEvaluationBytes > 0 &&
             maximumEvaluationBytes <= 64 * 1024 * 1024,
       );
  final ContractRequestBuilder builder;
  final ContractHttpTransport transport;
  final int maximumEvaluationBytes;
  int get _evaluationLimit => min(maximumEvaluationBytes, 64 * 1024 * 1024);

  Future<ContractRequestResult> execute(
    OperationRequestPlan plan,
    OperationRequestDraft draft, {
    required SecretResolver resolveSecret,
    RunCancellation? cancellation,
    void Function()? onRequestDispatched,
  }) async {
    final secretValues = <String>{};
    Future<String?> ownedSecret(String reference) async {
      cancellation?.throwIfCancelled();
      plan.ensureCurrentPreparation();
      final value = await resolveSecret(reference);
      cancellation?.throwIfCancelled();
      plan.ensureCurrentPreparation();
      if (value != null && value.isNotEmpty) secretValues.add(value);
      return value;
    }

    final preparing = builder.build(
      plan,
      draft,
      resolveSecret: ownedSecret,
      cancellation: cancellation,
    );
    final PreparedContractRequest request;
    try {
      request = cancellation == null
          ? await preparing
          : await Future.any<PreparedContractRequest>([
              preparing,
              cancellation.whenCancelled.then((_) {
                throw CoreFailure(
                  'cancelled',
                  'Request preparation was cancelled.',
                );
              }),
            ]);
    } on CoreFailure catch (error) {
      if (error.code == 'cancelled') {
        // Only a cancelled preparation owns late cleanup. Once acquisition
        // succeeds, transport/executor share the body's idempotent owner.
        unawaited(
          preparing.then<void>((late) async {
            try {
              await late.body?.close();
            } on Object {
              /* Owner was discarded. */
            }
          }, onError: (Object _, StackTrace _) {}),
        );
      }
      rethrow;
    }
    for (final header in request.headers) {
      if (request.sensitiveHeaders.contains(header.$1.toLowerCase())) {
        secretValues.add(header.$2);
        if (header.$2.startsWith('Basic ')) {
          secretValues.add(header.$2.substring(6));
        }
      }
    }
    try {
      cancellation?.throwIfCancelled();
      final outgoing = await validateOutgoing(
        plan,
        draft,
        request.runId,
        preparedBody: request.body,
        cancellation: cancellation,
      );
      cancellation?.throwIfCancelled();
      // A dispatch is a transport attempt; it does not prove server execution.
      plan.ensureCurrentPreparation();
      onRequestDispatched?.call();
      final response = await transport.send(
        request,
        cancellation: cancellation,
      );
      try {
        ContractConformance received;
        try {
          received = await validateResponse(
            plan,
            response,
            request.runId,
            cancellation: cancellation,
          );
          cancellation?.throwIfCancelled();
          plan.ensureCurrentOwner();
        } on CoreFailure catch (error) {
          if (error.code != 'cancelled') rethrow;
          received = ContractConformance(
            complete: false,
            valid: true,
            findings: [
              _finding(
                'runtime.cancelled',
                'warning',
                'Response evaluation was cancelled; no complete conformance is claimed.',
                location: 'response',
              ),
            ],
            producer: 'busyapi-runtime',
            producerVersion: '1',
            coverage: const {'body': 'cancelled'},
          );
        }
        return ContractRequestResult(
          request: request,
          response: response,
          outgoing: _redact(outgoing, secretValues),
          received: _redact(received, secretValues),
        );
      } on Object {
        await response.close();
        rethrow;
      }
    } finally {
      await request.body?.close();
    }
  }

  static ContractConformance _redact(
    ContractConformance value,
    Set<String> secrets,
  ) {
    if (secrets.isEmpty) return value;
    final ordered = secrets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    Object? redact(Object? input) {
      if (input is String) {
        for (final secret in ordered) {
          input = (input as String).replaceAll(secret, '[REDACTED]');
        }
        return input;
      }
      if (input is List) return input.map(redact).toList();
      if (input is Map) {
        return {
          for (final entry in input.entries)
            entry.key:
                const {
                  'code',
                  'producer',
                  'producerVersion',
                }.contains(entry.key)
                ? entry.value
                : redact(entry.value),
        };
      }
      return input;
    }

    return ContractConformance(
      complete: value.complete,
      valid: value.valid,
      findings: [
        for (final finding in value.findings)
          Map<String, Object?>.from(redact(finding) as Map),
      ],
      producer: value.producer,
      producerVersion: value.producerVersion,
      coverage: value.coverage,
    );
  }

  Future<ContractConformance> validateOutgoing(
    OperationRequestPlan plan,
    OperationRequestDraft draft,
    String runId, {
    PreparedRequestBody? preparedBody,
    RunCancellation? cancellation,
  }) async {
    final instances = <RuntimeSchemaInstance>[];
    final findings = <Map<String, Object?>>[];
    var checksComplete = true;
    for (final parameter in (plan.result['parameters'] as List).cast<Map>()) {
      final location = parameter['in'] as String,
          name = parameter['name'] as String,
          value = draft
              .parameters[OperationRequestDraft.parameterKey(location, name)];
      if (value == null || !value.present) continue;
      Map? schema = parameter['schema'] as Map?;
      Map? contentMedia;
      var typedContentSupported = true, jsonContent = false;
      if (parameter['content'] is List) {
        final content = (parameter['content'] as List)
            .whereType<Map>()
            .toList();
        if (content.length == 1) {
          contentMedia = content.single;
          schema ??= content.single['schema'] as Map?;
          final mediaType = (content.single['mediaType'] as String)
              .split(';')
              .first
              .trim()
              .toLowerCase();
          jsonContent = _jsonMedia(mediaType);
          typedContentSupported =
              jsonContent ||
              mediaType == 'text/plain' ||
              mediaType == 'application/x-www-form-urlencoded' && value.json;
          if (content.single['itemSchema'] is Map &&
              !_nativeMedia(content.single)) {
            checksComplete = false;
            findings.add(
              _finding(
                'runtime.request.parameter.items.unchecked',
                'information',
                'Sequential parameter itemSchema evaluation is unsupported; item constraints were not evaluated.',
                location: '$location:$name',
              ),
            );
          }
        }
      }
      final wireFormParameter =
          _formMedia(contentMedia?['mediaType'] as String?) && !value.json;
      if (wireFormParameter ||
          _nativeMedia(contentMedia) &&
              value.representation !=
                  RequestValueRepresentation.serializedParameter) {
        var text = value.text;
        if (value.json && contentMedia?['dataModel'] == 'text') {
          final trimmed = text.trim();
          // Only a JSON string needs decoding. Numeric spelling is already
          // the exact scalar representation used by the request serializer.
          text = trimmed.startsWith('"')
              ? jsonDecode(trimmed) as String
              : trimmed;
        }
        if (utf8.encode(text).length > _evaluationLimit) {
          checksComplete = false;
          findings.add(
            _finding(
              'runtime.request.parameter.limit',
              'warning',
              'The parameter exceeds the bounded evaluation input.',
              location: '$location:$name',
            ),
          );
        } else {
          instances.add(
            _mediaInstance(
              contentMedia,
              subject: 'request-parameter',
              location: '$location:$name',
              text: text,
              mediaType: contentMedia!['mediaType'] as String,
            ),
          );
        }
        continue;
      }
      if (schema == null && !jsonContent) continue;
      if (jsonContent && utf8.encode(value.text).length > _evaluationLimit) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.request.parameter.limit',
            'warning',
            'The JSON parameter exceeds the bounded evaluation input.',
            location: '$location:$name',
          ),
        );
        continue;
      }
      if (!typedContentSupported && schema?['unconstrained'] != true) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.request.parameter.content.unchecked',
            'information',
            'This serialized parameter media type was retained, but its typed content was not decoded for schema evaluation.',
            location: '$location:$name',
          ),
        );
        continue;
      }
      if (value.representation ==
              RequestValueRepresentation.serializedParameter ||
          value.representation == RequestValueRepresentation.serializedMedia) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.request.parameter.unchecked',
            'information',
            'The serialized example was preserved; its typed value was not schema evaluated.',
            location: '$location:$name',
          ),
        );
        continue;
      }
      instances.add(
        RuntimeSchemaInstance(
          subject: 'request-parameter',
          location: '$location:$name',
          text:
              value.json ||
                  parameter['content'] is List &&
                      (parameter['content'] as List).whereType<Map>().any(
                        (m) => _jsonMedia(m['mediaType'] as String),
                      )
              ? value.text
              : jsonEncode(value.text),
          schemaResource: schema?['resource'] as String?,
          schemaPointer: schema?['pointer'] as String?,
        ),
      );
    }
    final body = plan.result['requestBody'];
    if (body is Map && draft.body.kind != RequestBodyKind.none) {
      final media = _selectedRequestMedia(
        (body['content'] as List? ?? const []).whereType<Map>(),
        draft.body.mediaType,
      );
      final schema = media?['schema'];
      final formDeclarations = (media?['swaggerForm'] as List?)
          ?.whereType<Map>();
      final wireForm =
          draft.body.kind == RequestBodyKind.raw &&
          _formMedia(draft.body.mediaType);
      if (preparedBody?.formParameters
          case final List<RuntimeSchemaInstance> parameters) {
        instances.addAll(parameters);
      } else if (formDeclarations != null)
        for (final declaration in formDeclarations) {
          final name = declaration['name'] as String,
              values = draft.body.fields
                  .where((field) => field.name == name)
                  .map((field) => field.value)
                  .toList();
          if (declaration['type'] == 'file') continue;
          if (values.isEmpty) continue;
          try {
            final schema = declaration['schema'] as Map;
            instances.add(
              RuntimeSchemaInstance(
                subject: 'request-parameter',
                location: 'formData:$name',
                text: swaggerFormInstance(declaration, values),
                schemaResource: schema['resource'] as String,
                schemaPointer: schema['pointer'] as String,
              ),
            );
          } on FormatException {
            findings.add(
              _finding(
                'runtime.request.form.type',
                'error',
                'The formData value does not match its primitive type.',
                location: 'formData:$name',
              ),
            );
          } on UnsupportedError {
            checksComplete = false;
            findings.add(
              _finding(
                'runtime.request.form.unchecked',
                'information',
                'This formData representation needs a structured value before its nested constraints can be evaluated.',
                location: 'formData:$name',
              ),
            );
          }
        }
      if (draft.body.kind == RequestBodyKind.raw &&
          !wireForm &&
          (media?['form'] is Map ||
              (draft.body.mediaType ?? '').toLowerCase().startsWith(
                'multipart/',
              )) &&
          (media?['encoding'] != null ||
              media?['prefixEncoding'] != null ||
              media?['itemEncoding'] != null)) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.request.encoding.unchecked',
            'information',
            'The authored serialized body was preserved; declared field/part encodings were not decoded for validation.',
            location: draft.body.mediaType ?? '',
          ),
        );
      }
      if (schema is Map && schema['unconstrained'] != true ||
          media?['itemSchema'] is Map ||
          _nativeMedia(media) ||
          wireForm ||
          _jsonMedia(draft.body.mediaType ?? '')) {
        if (preparedBody?.formInstance != null &&
            utf8.encode(preparedBody!.formInstance!).length <=
                _evaluationLimit) {
          instances.add(
            _mediaInstance(
              media,
              subject: 'request-body',
              location: draft.body.mediaType ?? '',
              text: preparedBody.formInstance!,
            ),
          );
        } else if (preparedBody != null &&
            preparedBody.formInstance == null &&
            preparedBody.length <= _evaluationLimit) {
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in preparedBody.open()) {
            cancellation?.throwIfCancelled();
            plan.ensureCurrentOwner();
            bytes.add(chunk);
            if (bytes.length > _evaluationLimit) {
              throw CoreFailure(
                'runtime.body.changed',
                'Captured request bytes exceeded their evaluation boundary.',
              );
            }
          }
          instances.add(
            _mediaInstance(
              media,
              subject: 'request-body',
              location: draft.body.mediaType ?? '',
              text: base64Encode(bytes.takeBytes()),
              mediaType: preparedBody.mediaType ?? draft.body.mediaType,
              mediaBase64: true,
              formOccurrence: plan.operation['occurrence'] as String?,
            ),
          );
        } else if (preparedBody == null &&
            draft.body.kind == RequestBodyKind.raw &&
            utf8.encode(draft.body.text ?? '').length <= _evaluationLimit) {
          instances.add(
            _mediaInstance(
              media,
              subject: 'request-body',
              location: draft.body.mediaType ?? '',
              text: draft.body.text ?? '',
              mediaType: draft.body.mediaType,
              formOccurrence: plan.operation['occurrence'] as String?,
            ),
          );
        } else if (_nativeMedia(media) ||
            wireForm ||
            _jsonMedia(draft.body.mediaType ?? '') ||
            schema?['unconstrained'] != true ||
            media?['itemSchema'] is Map) {
          checksComplete = false;
          findings.add(
            _finding(
              'runtime.request.body.unchecked',
              'information',
              'The body was sent as authored; its representation exceeded the bounded schema-evaluation input.',
              location: draft.body.mediaType ?? '',
            ),
          );
        }
      }
    }
    return _evaluate(
      plan,
      instances,
      findings,
      '$runId-outgoing',
      {
        'parameters': 'selected-values',
        'body': _bodyCoverage(
          instances,
          'request-body',
          'not-applicable-or-unchecked',
        ),
      },
      checksComplete: checksComplete,
      cancellation: cancellation,
    );
  }

  Future<ContractConformance> validateResponse(
    OperationRequestPlan plan,
    ContractHttpResponse response,
    String runId, {
    RunCancellation? cancellation,
  }) async {
    final findings = <Map<String, Object?>>[],
        instances = <RuntimeSchemaInstance>[];
    var checksComplete = true;
    final method = plan.operation['method'].toString();
    final bodyPermitted = _responseBodyPermitted(method, response.status);
    final forbiddenContent = !bodyPermitted && response.receivedLength > 0;
    if (forbiddenContent) {
      findings.add(
        _finding(
          'runtime.response.body.forbidden',
          'error',
          'HTTP ${response.status} for ${method.toUpperCase()} does not permit response content, '
              'but ${response.receivedLength} bytes were received. Export the original bytes to inspect the server response.',
          location: 'response-body',
        ),
      );
    }
    final responses = (plan.result['responses'] as List).cast<Map>();
    Map? declaration = responses
        .where((item) => item['status'] == '${response.status}')
        .firstOrNull;
    declaration ??= responses.where((item) {
      final value = '${item['status']}'.toUpperCase();
      return RegExp(r'^[1-5]XX$').hasMatch(value) &&
          value.codeUnitAt(0) - 48 == response.status ~/ 100;
    }).firstOrNull;
    declaration ??= responses
        .where((item) => '${item['status']}'.toLowerCase() == 'default')
        .firstOrNull;
    if (declaration == null) {
      findings.add(
        _finding(
          'runtime.response.status',
          'error',
          'HTTP ${response.status} is not declared by the captured operation.',
          location: 'status',
        ),
      );
      return ContractConformance(
        complete: response.receiptComplete,
        valid: false,
        findings: List.unmodifiable(findings),
        producer: 'busyapi-runtime',
        producerVersion: '1',
        coverage: {
          'status': 'checked',
          'headers': 'not-declared',
          'body': forbiddenContent ? 'forbidden-content' : 'not-declared',
        },
      );
    }
    final receivedHeaders = <String, List<String>>{};
    for (final header in response.headers) {
      receivedHeaders
          .putIfAbsent(header.$1.toLowerCase(), () => [])
          .add(header.$2);
    }
    for (final header
        in (declaration['headers'] as List? ?? const []).whereType<Map>()) {
      final name = header['name'] as String,
          values = receivedHeaders[name.toLowerCase()];
      if ((values == null || values.isEmpty) && header['required'] == true) {
        findings.add(
          _finding(
            'runtime.response.header.required',
            'error',
            'Required response header $name is absent.',
            location: 'header:$name',
          ),
        );
      }
      if (name.toLowerCase() == 'content-type' || values == null) continue;
      final headerMedia = (header['content'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      if (headerMedia.length == 1 &&
          (_nativeMedia(headerMedia.single) ||
              _formMedia(headerMedia.single['mediaType'] as String?)) &&
          values.length == 1) {
        if (utf8.encode(values.single).length > _evaluationLimit) {
          checksComplete = false;
          findings.add(
            _finding(
              'runtime.response.header.limit',
              'warning',
              'The header representation exceeds the bounded evaluation input.',
              location: name,
            ),
          );
        } else {
          instances.add(
            _mediaInstance(
              headerMedia.single,
              subject: 'response-header',
              location: name,
              text: values.single,
              mediaType: headerMedia.single['mediaType'] as String,
            ),
          );
        }
        continue;
      }
      if ((header['content'] as List? ?? const []).whereType<Map>().any(
        (media) => media['itemSchema'] is Map,
      )) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.response.header.items.unchecked',
            'information',
            'Sequential header itemSchema evaluation is unsupported; item constraints were not evaluated.',
            location: name,
          ),
        );
      }
      try {
        final decoded = decodeDeclaredHeader(header, values);
        if (decoded != null) {
          if (utf8.encode(decoded.$2).length > _evaluationLimit) {
            checksComplete = false;
            findings.add(
              _finding(
                'runtime.response.header.limit',
                'warning',
                'The header representation exceeds the bounded evaluation input.',
                location: name,
              ),
            );
            continue;
          }
          instances.add(
            RuntimeSchemaInstance(
              subject: 'response-header',
              location: name,
              text: decoded.$2,
              schemaResource: decoded.$1?['resource'] as String?,
              schemaPointer: decoded.$1?['pointer'] as String?,
            ),
          );
        }
      } on UnsupportedError {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.response.header.unchecked',
            'information',
            'The declared header representation could not be interpreted unambiguously; its schema check was not performed.',
            location: name,
          ),
        );
      } on FormatException {
        findings.add(
          _finding(
            'runtime.response.header.serialization',
            'error',
            'The received header does not use the declared scalar or collection representation.',
            location: name,
          ),
        );
      }
    }
    final contentType = receivedHeaders['content-type']?.first;
    final media = selectDeclaredMedia(
      (declaration['content'] as List? ?? const []).whereType<Map>(),
      contentType,
    );
    if (bodyPermitted &&
        (declaration['content'] as List? ?? const []).isNotEmpty &&
        media == null) {
      findings.add(
        _finding(
          'runtime.response.media-type',
          'error',
          contentType == null
              ? 'The response has no Content-Type for its declared body.'
              : 'Response media type $contentType is not declared for HTTP ${response.status}.',
          location: 'content-type',
        ),
      );
    }
    final schema = media?['schema'];
    String? charset;
    var validContentType = true;
    try {
      charset = contentType == null
          ? null
          : ContentType.parse(contentType).charset?.toLowerCase();
    } on Object {
      validContentType = false;
    }
    final supportedCharset =
        validContentType &&
        (media?['dataModel'] == 'event-stream' ||
            charset == null ||
            charset == 'utf-8' ||
            charset == 'utf8' ||
            charset == 'us-ascii' ||
            !_jsonMedia(contentType ?? '') &&
                (charset == 'iso-8859-1' || charset == 'latin1'));
    if (!validContentType) {
      findings.add(
        _finding(
          'runtime.response.content-type',
          'error',
          'The received Content-Type is malformed.',
          location: 'content-type',
        ),
      );
    } else if (bodyPermitted && !supportedCharset) {
      checksComplete = false;
      findings.add(
        _finding(
          'runtime.response.charset.unchecked',
          'warning',
          'The declared body charset is unsupported for schema evaluation.',
          location: 'content-type',
        ),
      );
    }
    var invalidTextEncoding = false;
    if (bodyPermitted &&
        response.receiptComplete &&
        response.decodingComplete &&
        supportedCharset &&
        media?['dataModel'] != 'event-stream' &&
        isInspectableTextMedia(contentType)) {
      try {
        final codec = charset == 'us-ascii'
            ? ascii
            : charset == 'iso-8859-1' || charset == 'latin1'
            ? latin1
            : utf8;
        await for (final _ in codec.decoder.bind(response.decodedChunks())) {
          cancellation?.throwIfCancelled();
          plan.ensureCurrentOwner();
        }
      } on FormatException {
        invalidTextEncoding = true;
        findings.add(
          _finding(
            'runtime.response.body.encoding',
            'error',
            'The response bytes are invalid for the declared ${charset ?? 'utf-8'} charset.',
            location: 'content-type',
          ),
        );
      }
    }
    if (bodyPermitted && !response.decodingComplete) {
      checksComplete = false;
      findings.add(
        _finding(
          'runtime.response.decoding',
          response.decodingReason == 'malformed-content-encoding'
              ? 'error'
              : 'warning',
          'Response decoding is incomplete: ${response.decodingReason}. Original bytes remain available.',
          location: 'content-encoding',
        ),
      );
    }
    if (bodyPermitted &&
        response.decodingComplete &&
        !invalidTextEncoding &&
        schema?['file'] != true &&
        supportedCharset &&
        (_jsonMedia(contentType ?? '') ||
            _nativeMedia(media) ||
            _formMedia(contentType) ||
            media?['itemSchema'] is Map ||
            schema is Map && schema['unconstrained'] != true)) {
      if (!response.receiptComplete) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.response.body.incomplete',
            'warning',
            'The response body was not received completely, so complete schema validation was not claimed.',
            location: contentType ?? '',
          ),
        );
      } else if (response.decodedLength > _evaluationLimit) {
        checksComplete = false;
        findings.add(
          _finding(
            'runtime.response.body.limit',
            'warning',
            'The response exceeds the bounded schema-evaluation input.',
            location: contentType ?? '',
          ),
        );
      } else {
        instances.add(
          _mediaInstance(
            media,
            subject: 'response-body',
            location: contentType ?? '',
            mediaType: contentType,
            text: base64Encode(await response.decodedBytes()),
            mediaBase64: true,
          ),
        );
      }
    }
    final evaluated = await _evaluate(
      plan,
      instances,
      findings,
      '$runId-response',
      {
        'status': 'checked',
        'mediaType': bodyPermitted ? 'checked' : 'not-applicable',
        'headers': 'declared-selected',
        'body': forbiddenContent
            ? 'forbidden-content'
            : !bodyPermitted
            ? 'not-applicable'
            : _bodyCoverage(
                instances,
                'response-body',
                'not-applicable-or-incomplete',
              ),
      },
      checksComplete: checksComplete,
      cancellation: cancellation,
    );
    if (!response.receiptComplete && evaluated.complete) {
      return ContractConformance(
        complete: false,
        valid: evaluated.valid,
        findings: evaluated.findings,
        producer: evaluated.producer,
        producerVersion: evaluated.producerVersion,
        coverage: evaluated.coverage,
      );
    }
    return evaluated;
  }

  static bool _nativeMedia(Map? media) =>
      media?['dataModel'] is String && media?['dataModel'] != 'opaque';

  static String _bodyCoverage(
    List<RuntimeSchemaInstance> instances,
    String subject,
    String absent,
  ) {
    final selected = instances.where((instance) => instance.subject == subject);
    if (selected.isEmpty) return absent;
    return selected.any(
          (instance) =>
              instance.mediaType != null && !_jsonMedia(instance.mediaType!),
        )
        ? 'selected-media-body'
        : 'selected-json-body';
  }

  static bool _formMedia(String? value) => const [
    'application/x-www-form-urlencoded',
    'multipart/form-data',
  ].contains(value?.split(';').first.trim().toLowerCase());

  static RuntimeSchemaInstance _mediaInstance(
    Map? media, {
    required String subject,
    required String location,
    required String text,
    String? mediaType,
    bool mediaBase64 = false,
    String? formOccurrence,
  }) {
    final schema = media?['schema'] as Map?,
        itemSchema = media?['itemSchema'] as Map?;
    RuntimeFormTarget? form;
    if (_formMedia(mediaType) && media != null) {
      final owner = media['definition'] ?? media['source'];
      if (owner case {'resource': String resource, 'pointer': String pointer}) {
        form = RuntimeFormTarget(
          resource: resource,
          pointer: pointer,
          occurrence: media['swaggerForm'] is List ? formOccurrence : null,
        );
      } else {
        throw CoreFailure(
          'runtime.form.owner',
          'The captured form media omitted its source owner.',
        );
      }
    }
    return RuntimeSchemaInstance(
      subject: subject,
      location: location,
      text: text,
      mediaType: mediaType,
      mediaBase64: mediaBase64,
      form: form,
      schemaResource: schema?['resource'] as String?,
      schemaPointer: schema?['pointer'] as String?,
      itemSchemaResource: itemSchema?['resource'] as String?,
      itemSchemaPointer: itemSchema?['pointer'] as String?,
    );
  }

  static Future<ContractConformance> _evaluate(
    OperationRequestPlan plan,
    List<RuntimeSchemaInstance> instances,
    List<Map<String, Object?>> findings,
    String requestId,
    Map<String, Object?> coverage, {
    bool checksComplete = true,
    RunCancellation? cancellation,
  }) async {
    var complete = checksComplete;
    var producer = 'busyapi-runtime', producerVersion = '1';
    if (instances.isNotEmpty) {
      final result = await plan.evaluateRuntime(
        instances,
        requestId: requestId,
        cancellation: cancellation,
      );
      complete = complete && result['complete'] == true;
      producer = result['producer'] as String;
      producerVersion = result['producerVersion'] as String;
      for (final finding
          in (result['runtimeFindings'] as List).whereType<Map>()) {
        findings.add(Map<String, Object?>.from(finding));
      }
    }
    final valid = !findings.any((finding) => finding['severity'] == 'error');
    return ContractConformance(
      complete: complete,
      valid: valid,
      findings: List.unmodifiable(findings),
      producer: producer,
      producerVersion: producerVersion,
      coverage: Map.unmodifiable(coverage),
    );
  }

  static Map<String, Object?> _finding(
    String code,
    String severity,
    String message, {
    required String location,
  }) => {
    'version': 1,
    'category': 'runtime',
    'code': code,
    'severity': severity,
    'message': message,
    'location': location,
    'producer': 'busyapi-runtime',
    'producerVersion': '1',
  };

  static bool _jsonMedia(String value) {
    final media = value.split(';').first.trim().toLowerCase();
    return media == 'application/json' || media.endsWith('+json');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
  Digest get single {
    final result = value;
    if (result == null) {
      throw StateError('Response digest was not completed');
    }
    return result;
  }
}
