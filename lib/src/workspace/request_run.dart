import 'dart:async';
import 'dart:convert';
import 'dart:io' show ContentType;
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app/busyapi_design.dart';
import '../app/busyapi_disclosure.dart';
import '../app/command_registry.dart';
import '../app/shortcut_binding.dart';
import '../app/keyboard_shortcut_badge.dart';
import '../app/busyapi_dialogs.dart';
import '../app/busyapi_glyphs.dart';
import '../app/localization.dart';
import '../app/busyapi_toast.dart';
import '../designer/form_value_editor.dart';
import 'tool_surface.dart';
import '../comparison/review_comparison.dart';
import '../platform/secret_store.dart';
import '../platform/external_uri_service.dart';
import 'refactoring_review.dart';
import 'workspace_controller.dart';
import 'request_part_media.dart';

enum RequestTimeoutKind { connect, overall, inactivity }

const _setupReferences = {
  'secretRef',
  'tokenRef',
  'passwordRef',
  'clientSecretRef',
  'accessTokenRef',
};
const _setupSchemeFields = {
  ..._setupReferences,
  'username',
  'clientId',
  'clientAuthentication',
  'scopes',
};
const _setupTlsFields = {
  'caFile',
  'clientCertificateFile',
  'clientKeyFile',
  'clientKeyPasswordRef',
};

class _EnvironmentSetupDraft {
  _EnvironmentSetupDraft(
    this.name,
    this.base,
    this.variables,
    this.headers,
    Map<String, Map<String, Object?>> schemes,
    this.keyPassword,
  ) : schemes = {
        for (final entry in schemes.entries) entry.key: Map.of(entry.value),
      };
  final String name, base, variables, headers;
  final Map<String, Map<String, Object?>> schemes;
  final bool keyPassword;
}

class RequestRunController extends ChangeNotifier {
  RequestRunController(this.workspace, {EnvironmentSecretStore? secrets})
    : secrets = secrets ?? EnvironmentSecretStore() {
    workspace.addListener(_observe);
  }
  final WorkspaceController workspace;
  final EnvironmentSecretStore secrets;
  BusyProject? owner;
  OperationRequestPlan? plan;
  ContractRequestResult? result;
  RunCancellation? cancellation;
  String phase = 'idle';
  String? failure, environment, bodyMediaType;
  int server = 0;
  int? securityAlternative;
  bool expanded = true, _disposed = false;
  bool bodyEnabled = false;
  bool bodyStructured = false;
  final Map<String, String> partMediaTypes = {};
  int _epoch = 0;
  final Map<(BusyProject?, OperationRequestPlan?, String?), int>
  _credentialWrites = {};
  String? _operationKey, _draftIdentity;
  int _draftView = 0, _draftRevision = 0;
  int? _resultDraftRevision;
  bool get resultDraftChanged =>
      result != null && _resultDraftRevision != _draftRevision;
  final Map<(String, String?), _RequestDraftState> _drafts = {};
  final Map<(String, String?), _EnvironmentSetupDraft> _setupDrafts = {};
  final Map<String, String?> _lastEnvironment = {};
  final Map<String, String> values = {};
  final _composingInputs = <Object>{};
  final Map<Object, (OperationRequestPlan?, String?)> _pendingSecretInputs = {};
  bool get hasPendingSecretInput =>
      _pendingSecretInputs.values.any((scope) => scope == (plan, environment));
  bool get hasComposingInput => _composingInputs.isNotEmpty;
  final Set<String> structuredValues = {};
  final Set<String> omittedValues = {};
  final Map<String, RequestValueRepresentation> exampleRepresentations = {};
  final List<RequestHeaderValue> customHeaders = [];
  RequestBodyKind bodyKind = RequestBodyKind.raw;
  final Map<RequestTimeoutKind, String> timeoutInputs = {};
  final Map<String, int> _tlsSelections = {};
  Duration connectTimeout = const Duration(seconds: 15),
      overallTimeout = const Duration(seconds: 60),
      inactivityTimeout = const Duration(seconds: 15);
  String? effectiveRequest, previewFailure, failureMessage;
  Timer? _previewTimer;
  int _previewEpoch = 0;
  bool get timeoutsValid =>
      [connectTimeout, overallTimeout, inactivityTimeout].every(
        (value) =>
            value > Duration.zero && value <= const Duration(minutes: 10),
      );
  bool get requiredInputMissing {
    final captured = plan;
    if (captured == null) return true;
    final body = captured.result['requestBody'];
    if (body is Map && body['required'] == true && !bodyEnabled) return true;
    return (captured.result['parameters'] as List).whereType<Map>().any((
      parameter,
    ) {
      final key = OperationRequestDraft.parameterKey(
        parameter['in'] as String,
        parameter['name'] as String,
      );
      return parameter['required'] == true &&
          (!values.containsKey(key) || omittedValues.contains(key));
    });
  }

  bool get canSend =>
      !_disposed &&
      plan != null &&
      identical(owner, workspace.project) &&
      plan!.snapshot.root == workspace.root &&
      !busy &&
      (_credentialWrites[(owner, plan, environment)] ?? 0) == 0 &&
      !hasComposingInput &&
      !hasPendingSecretInput &&
      !outdated &&
      !hasUnavailableSelection &&
      !requiredInputMissing &&
      timeoutsValid &&
      !bodyMediaNeedsSelection;

  final List<MultipartFileValue> bodyFiles = [];
  final Map<String, String> tlsFiles = {};
  final List<ContractRequestRecord> history = [];
  String bodyText = '',
      bodyFilePart = 'file',
      headerName = '',
      headerValue = '';

  bool get busy =>
      phase == 'preparing' || phase == 'sending' || phase == 'authorizing';
  bool get outdated =>
      (plan?.outdated ?? false) ||
      plan != null && _draftIdentity != plan!.identity;
  bool get hasDeclaredBodyMediaType {
    if (bodyMediaType == null) return false;
    final body = plan?.result['requestBody'];
    final content = body is Map ? body['content'] : null;
    return content is List &&
        content.whereType<Map>().any(
          (media) => media['mediaType'] == bodyMediaType,
        );
  }

  bool get bodyMediaNeedsSelection => bodyEnabled && !hasDeclaredBodyMediaType;
  bool get hasUnavailableSelection {
    final captured = plan;
    if (captured == null) return false;
    final servers = captured.result['servers'] as List;
    final requirements = captured.result['security']['requirements'] as List;
    final alternative = securityAlternative;
    return environment != null &&
            !captured.configuration.environments.containsKey(environment) ||
        server < 0 ||
        server >= servers.length ||
        (alternative == null
            ? requirements.isNotEmpty
            : alternative < 0 || alternative >= requirements.length);
  }

  String get title {
    final operation = plan?.operation;
    return operation == null
        ? ''
        : '${operation['method']} ${operation['path']}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void refresh({bool draftChanged = true}) {
    if (_disposed) return;
    if (draftChanged && !busy && plan != null) {
      phase = 'ready';
      failure = failureMessage = null;
    }
    if (draftChanged) ++_draftRevision;
    _previewTimer?.cancel();
    final epoch = ++_previewEpoch;
    effectiveRequest = previewFailure = null;
    _previewTimer = Timer(const Duration(milliseconds: 120), () async {
      final captured = plan;
      if (captured == null ||
          outdated ||
          hasUnavailableSelection ||
          hasComposingInput) {
        return;
      }
      try {
        final prepared = await const ContractRequestBuilder().build(
          captured,
          draft(),
          resolveSecret: (_) async => '[REDACTED]',
          previewOnly: true,
        );
        if (_disposed || epoch != _previewEpoch || !identical(captured, plan)) {
          return;
        }
        effectiveRequest = '${prepared.method} ${prepared.displayUri}';
        previewFailure = null;
      } on CoreFailure catch (error) {
        if (_disposed || epoch != _previewEpoch) return;
        previewFailure = error.message;
      } finally {
        if (!_disposed && epoch == _previewEpoch) _notify();
      }
    });
    _notify();
  }

  OperationRequestDraft draft() {
    final parameters = <String, RequestValue>{};
    for (final entry in values.entries) {
      if (omittedValues.contains(entry.key)) continue;
      final representation = exampleRepresentations[entry.key];
      parameters[entry.key] =
          representation == RequestValueRepresentation.serializedParameter ||
              representation == RequestValueRepresentation.serializedMedia
          ? RequestValue.serialized(
              entry.value,
              mediaLevel:
                  representation == RequestValueRepresentation.serializedMedia,
            )
          : structuredValues.contains(entry.key)
          ? RequestValue.json(entry.value)
          : RequestValue.text(entry.value);
    }
    final body = !bodyEnabled || bodyMediaType == null
        ? const RequestBodyDraft.none()
        : switch (bodyKind) {
            RequestBodyKind.form =>
              bodyStructured
                  ? RequestBodyDraft.formValue(
                      json: bodyText,
                      mediaType: bodyMediaType!,
                      partMediaTypes: Map.of(partMediaTypes),
                    )
                  : RequestBodyDraft.form(
                      formRows(bodyText),
                      mediaType: bodyMediaType!,
                      partMediaTypes: Map.of(partMediaTypes),
                    ),
            RequestBodyKind.multipart =>
              bodyStructured
                  ? RequestBodyDraft.multipartValue(
                      json: bodyText,
                      files: List.of(bodyFiles),
                      mediaType: bodyMediaType!,
                      partMediaTypes: Map.of(partMediaTypes),
                    )
                  : RequestBodyDraft.multipart(
                      formRows(bodyText),
                      List.of(bodyFiles),
                      mediaType: bodyMediaType!,
                      partMediaTypes: Map.of(partMediaTypes),
                    ),
            RequestBodyKind.binaryFile =>
              bodyFiles.length == 1
                  ? RequestBodyDraft.binaryFile(
                      mediaType: bodyMediaType!,
                      file: bodyFiles.single.path,
                    )
                  : throw CoreFailure(
                      'request.file',
                      'Select one binary file or choose text input.',
                    ),
            _ => RequestBodyDraft.raw(
              mediaType: bodyMediaType!,
              text: bodyText,
            ),
          };
    return OperationRequestDraft(
      planIdentity: _draftIdentity ?? '',
      environment: environment,
      server: server,
      securityAlternative: securityAlternative,
      parameters: parameters,
      headers: [
        ...customHeaders,
        if (headerName.isNotEmpty) RequestHeaderValue(headerName, headerValue),
      ],
      body: body,
      tlsFiles: Map.of(tlsFiles),
      connectTimeout: connectTimeout,
      overallTimeout: overallTimeout,
      inactivityTimeout: inactivityTimeout,
    );
  }

  void selectBodyMedia(String? media) {
    if (busy || hasComposingInput) return;
    bodyMediaType = media;
    bodyFiles.clear();
    partMediaTypes.clear();
    bodyKind = _kindForMedia(media);
    if (bodyKind != RequestBodyKind.form &&
        bodyKind != RequestBodyKind.multipart) {
      bodyStructured = false;
    }
    refresh();
  }

  static RequestBodyKind _kindForMedia(String? media) =>
      switch (media?.split(';').first.trim().toLowerCase()) {
        'application/x-www-form-urlencoded' => RequestBodyKind.form,
        'multipart/form-data' => RequestBodyKind.multipart,
        _ => RequestBodyKind.raw,
      };

  void selectPartMedia(String name, String? media) {
    if (busy) return;
    if (media == null || media.isEmpty) {
      partMediaTypes.remove(name);
    } else {
      partMediaTypes[name] = media;
    }
    refresh();
  }

  void selectFileMedia(int index, String? media) {
    if (busy || index < 0 || index >= bodyFiles.length) return;
    final file = bodyFiles[index];
    bodyFiles[index] = MultipartFileValue(
      name: file.name,
      path: file.path,
      filename: file.filename,
      mediaType: file.mediaType,
      selectedMediaType: media == null || media.isEmpty ? null : media,
    );
    refresh();
  }

  void _observe() {
    if (owner == null) return;
    if (!identical(owner, workspace.project)) {
      clear();
    } else if (plan != null && plan!.snapshot.root != workspace.root) {
      clear(retainProjectDrafts: true);
    }
  }

  bool _remember() {
    final key = _operationKey;
    if (key == null || plan == null) return true;
    final draft = _RequestDraftState(this);
    if (draft.bytes > 16 * 1024 * 1024) {
      failure = 'request.draft.limit';
      phase = 'failed';
      _notify();
      return false;
    }
    _drafts.remove((key, environment));
    _drafts[(key, environment)] = draft;
    _lastEnvironment[key] = environment;
    while (_drafts.length > 32 ||
        _drafts.values.fold<int>(0, (n, d) => n + d.bytes) > 16 * 1024 * 1024) {
      _drafts.remove(_drafts.keys.first);
    }
    _lastEnvironment.removeWhere(
      (key, _) => !_drafts.keys.any((entry) => entry.$1 == key),
    );
    return true;
  }

  void _resetValues() {
    values.clear();
    structuredValues.clear();
    omittedValues.clear();
    exampleRepresentations.clear();
    customHeaders.clear();
    timeoutInputs.clear();
    bodyKind = RequestBodyKind.raw;
    bodyStructured = false;
    partMediaTypes.clear();
    connectTimeout = const Duration(seconds: 15);
    overallTimeout = const Duration(seconds: 60);
    inactivityTimeout = const Duration(seconds: 15);
    bodyFiles.clear();
    tlsFiles.clear();
    bodyText = headerName = headerValue = '';
    bodyFilePart = 'file';
    bodyEnabled = false;
    server = 0;
    securityAlternative = null;
    bodyMediaType = null;
    _draftView++;
  }

  void _initializeFreshDraft() {
    _resetValues();
    _environmentAuthentication();
    final body = plan?.result['requestBody'];
    if (body is Map && body['content'] is List) {
      bodyEnabled = body['required'] == true;
      bodyMediaType = (body['content'] as List)
          .whereType<Map>()
          .map((m) => m['mediaType'])
          .whereType<String>()
          .firstOrNull;
      bodyKind = _kindForMedia(bodyMediaType);
    }
  }

  Future<void> open(
    Map<String, dynamic> operation, {
    bool reconcile = false,
  }) async {
    if (hasComposingInput) return;
    final project = workspace.project, root = workspace.root;
    if (project == null ||
        root == null ||
        operation['resource'] is! String ||
        operation['pointer'] is! String) {
      return;
    }
    if (!await workspace.flush() ||
        _disposed ||
        !identical(project, workspace.project) ||
        root != workspace.root) {
      return;
    }
    if (identical(owner, project) && !_remember()) return;
    cancellation?.cancel();
    final epoch = ++_epoch;
    if (_disposed || epoch != _epoch) return;
    if (!identical(result?.request.plan, plan)) plan?.close();
    plan = null;
    owner = project;
    phase = 'preparing';
    failure = failureMessage = null;
    expanded = true;
    _resetValues();
    _operationKey = jsonEncode([
      root,
      operation['resource'],
      operation['pointer'],
      operation['occurrence'],
    ]);
    environment = _lastEnvironment[_operationKey];
    final draft = _drafts[(_operationKey!, environment)];
    _notify();
    try {
      final prepared = await project.prepareRequest(
        root,
        resource: operation['resource'] as String,
        pointer: operation['pointer'] as String,
        occurrence: operation['occurrence'] as String?,
        requestId: 'native-request-$epoch',
        cancelled: () => _disposed || epoch != _epoch,
        onResourceRefreshed: (resource) =>
            workspace.resourceRefreshed(project, resource),
      );
      if (_disposed ||
          epoch != _epoch ||
          !identical(project, workspace.project)) {
        prepared.close();
        return;
      }
      plan = prepared;
      _draftIdentity = prepared.identity;
      _initializeFreshDraft();
      if (draft != null) {
        draft.restore(this);
        if (reconcile) _draftIdentity = prepared.identity;
      }
      phase = 'ready';
      refresh();
    } on Object catch (error) {
      if (_disposed || epoch != _epoch) return;
      phase = error is CoreFailure && error.code == 'cancelled'
          ? 'cancelled'
          : 'failed';
      failure = error is CoreFailure ? error.code : 'request.prepare';
      failureMessage = error is CoreFailure ? error.message : null;
    } finally {
      if (epoch == _epoch) _notify();
    }
  }

  void selectEnvironment(String? value) {
    if (environment == value || busy || hasComposingInput) return;
    if (!_remember()) return;
    environment = value;
    _initializeFreshDraft();
    _draftIdentity = plan?.identity;
    _environmentAuthentication();
    final key = _operationKey;
    if (key != null) _drafts[(key, value)]?.restore(this);
    phase = 'ready';
    failure = null;
    refresh();
  }

  void _environmentAuthentication() {
    final captured = plan;
    if (captured == null) return;
    final configured = captured
        .configuration
        .environments[environment]
        ?.authentication['alternative'];
    if (configured is int) {
      securityAlternative = configured;
      return;
    }
    final requirements = captured.result['security']['requirements'] as List;
    final anonymous = requirements.indexWhere(
      (value) => (value['schemes'] as List).isEmpty,
    );
    securityAlternative = anonymous < 0 ? null : anonymous;
  }

  Future<void> reconcileDraft() async {
    final captured = plan;
    if (captured == null || busy || hasComposingInput) return;
    final source = captured.operation['source'] as Map;
    await open({
      'resource': source['resource'],
      'pointer': source['pointer'],
      'occurrence': captured.operation['occurrence'],
    }, reconcile: true);
  }

  void discardDraft() {
    if (busy || hasComposingInput) return;
    final key = _operationKey;
    if (key != null) _drafts.remove((key, environment));
    _initializeFreshDraft();
    failure = null;
    phase = 'ready';
    _draftIdentity = plan?.identity;
    refresh();
  }

  void useExample(Map parameter) {
    if (busy || hasComposingInput) return;
    Map? media;
    if (parameter['content'] is List) {
      final choices = (parameter['content'] as List).whereType<Map>();
      final selectedExample = parameter['example'];
      media =
          choices
              .where(
                (m) =>
                    selectedExample is Map &&
                    m['mediaType'] == selectedExample['mediaType'],
              )
              .firstOrNull ??
          choices.firstOrNull;
    }
    final example = parameter['example'] ?? media?['example'];
    if (example is! Map || example['raw'] is! String) return;
    if (example['conversionError'] is String) {
      failure = 'request.example.conversion';
      failureMessage = example['conversionError'] as String;
      _notify();
      return;
    }
    if (media != null && example['representation'] != 'serialized') {
      final type = (media['mediaType'] as String)
          .split(';')
          .first
          .toLowerCase();
      if (type == 'application/x-www-form-urlencoded' &&
              example['fields'] is! Map ||
          type != 'application/json' &&
              !type.endsWith('+json') &&
              type != 'application/x-www-form-urlencoded' &&
              example['dataKind'] != 'string') {
        failure = 'request.example.conversion';
        failureMessage = 'This media type has no supported structured example conversion. Choose a serialized example or edit its literal representation.';
        _notify();
        return;
      }
    }
    if (media != null &&
        (example['representation'] != 'serialized' ||
            example['level'] == 'media')) {
      try {
        final type = media['mediaType'] as String;
        final json = type.split(';').first.toLowerCase().endsWith('json');
        final fields = example['fields'];
        ContractRequestBuilder.validateTextCharset(type, [
          json ? example['raw'] as String : example['text'] as String,
          if (!json && fields is Map)
            for (final entry in fields.entries) ...[
              entry.key as String,
              ...(entry.value as List).cast<String>(),
            ],
        ]);
      } on CoreFailure catch (error) {
        failure = error.code;
        failureMessage = error.message;
        _notify();
        return;
      }
    }
    final key = OperationRequestDraft.parameterKey(
      parameter['in'] as String,
      parameter['name'] as String,
    );
    values[key] = example['raw'] as String;
    omittedValues.remove(key);
    exampleRepresentations.remove(key);
    if (example['representation'] == 'serialized') {
      structuredValues.remove(key);
      exampleRepresentations[key] = example['level'] == 'media'
          ? RequestValueRepresentation.serializedMedia
          : RequestValueRepresentation.serializedParameter;
    } else {
      final type = (media?['mediaType'] as String?)
          ?.split(';')
          .first
          .toLowerCase();
      if (type == 'application/x-www-form-urlencoded' &&
          example['fields'] is Map) {
        values[key] = [
          for (final entry in (example['fields'] as Map).entries)
            for (final value in entry.value as List)
              '${Uri.encodeQueryComponent(entry.key as String)}=${Uri.encodeQueryComponent(value as String)}',
        ].join('&');
        structuredValues.remove(key);
        exampleRepresentations[key] =
            RequestValueRepresentation.serializedMedia;
      } else if (type == 'text/plain' ||
          type != null &&
              type != 'application/json' &&
              !type.endsWith('+json') &&
              example['dataKind'] == 'string') {
        values[key] = example['text'] as String;
        structuredValues.remove(key);
      } else {
        structuredValues.add(key);
      }
    }
    refresh();
  }

  void useBodyExample(Map media) {
    if (busy || hasComposingInput) return;
    final example = media['example'];
    if (example is! Map || example['raw'] is! String) return;
    final type = media['mediaType'] as String;
    try {
      ContractRequestBuilder.validateTextCharset(type, const []);
    } on CoreFailure catch (error) {
      failure = error.code;
      failureMessage = error.message;
      _notify();
      return;
    }
    final kind = _kindForMedia(type);
    final mime = ContentType.parse(type).mimeType;
    // Exact data input bypasses the literal-row projection. The shared builder
    // retains its kinds and owns the applicable serialization checks.
    final formData =
        example['representation'] != 'serialized' &&
        example['dataKind'] == 'object' &&
        (kind == RequestBodyKind.form || kind == RequestBodyKind.multipart);
    if (!formData && example['conversionError'] is String ||
        example['representation'] != 'serialized' &&
            kind == RequestBodyKind.raw &&
            !(mime == 'application/json' || mime.endsWith('+json')) &&
            example['dataKind'] != 'string') {
      failure = 'request.example.conversion';
      failureMessage = example['conversionError'] as String? ?? 'This media type has no supported conversion for this data example. Choose a serialized example or edit the literal body.';
      _notify();
      return;
    }
    if (kind == RequestBodyKind.multipart &&
        example['representation'] == 'serialized' &&
        !ContentType.parse(type).parameters.containsKey('boundary')) {
      failure = 'request.example.conversion';
      failureMessage = 'This serialized multipart example has no declared boundary. Use its data representation or explicit multipart fields.';
      _notify();
      return;
    }
    var text = example['raw'] as String;
    if (example['representation'] != 'serialized') {
      if (!formData &&
          (kind == RequestBodyKind.form || kind == RequestBodyKind.multipart)) {
        final fields = example['fields'];
        if (fields is! Map ||
            fields.entries.any(
              (entry) =>
                  entry.value is! List ||
                  (entry.value as List).any(
                    (v) => v is! String || v.contains('\n'),
                  ) ||
                  entry.key.toString().contains('=') ||
                  entry.key.toString().contains('\n'),
            )) {
          failure = 'request.example.conversion';
          failureMessage = 'This example cannot be represented as literal form rows. Edit the representation explicitly.';
          _notify();
          return;
        }
        text = [
          for (final entry in fields.entries)
            for (final value in entry.value as List) '${entry.key}=$value',
        ].join('\n');
      } else if (!(mime == 'application/json' || mime.endsWith('+json'))) {
        text = example['text'] as String;
      }
    }
    try {
      ContractRequestBuilder.validateTextCharset(type, [text]);
    } on CoreFailure catch (error) {
      failure = error.code;
      failureMessage = error.message;
      _notify();
      return;
    }
    if (bodyMediaType != type) partMediaTypes.clear();
    bodyMediaType = type;
    bodyText = text;
    bodyStructured = formData;
    bodyKind = example['representation'] == 'serialized'
        ? RequestBodyKind.raw
        : kind;
    bodyFiles.clear();
    bodyEnabled = true;
    refresh();
  }

  void addBodyFile(XFile file) {
    final multipart = _kindForMedia(bodyMediaType) == RequestBodyKind.multipart;
    final part = multipart ? bodyFilePart.trim() : 'file';
    if (multipart && part.isEmpty) {
      throw CoreFailure(
        'request.multipart.name',
        'Enter a multipart field name before choosing a file',
      );
    }
    if (busy || hasComposingInput) return;
    if (_kindForMedia(bodyMediaType) != RequestBodyKind.multipart) {
      bodyFiles.clear();
    }
    bodyKind = _kindForMedia(bodyMediaType) == RequestBodyKind.multipart
        ? RequestBodyKind.multipart
        : RequestBodyKind.binaryFile;
    bodyFiles.add(
      MultipartFileValue(
        name: part,
        path: file.path,
        filename: file.name,
        mediaType: file.mimeType ?? 'application/octet-stream',
      ),
    );
    bodyEnabled = true;
    refresh();
  }

  void clearBodyFiles() {
    if (busy || hasComposingInput) return;
    bodyFiles.clear();
    bodyKind = _kindForMedia(bodyMediaType);
    refresh();
  }

  void clearHistory() {
    history.clear();
    _notify();
  }

  Future<void> exportHistory(
    String destination, {
    Future<void> Function()? beforePublish,
    List<ContractRequestRecord>? records,
  }) async {
    final bytes = utf8.encode(
      '${const JsonEncoder.withIndent(' ').convert({'version': 1, 'records': (records ?? history).map((entry) => entry.toJson()).toList()})}\n',
    );
    await const AtomicFileWriter().writeBytes(
      destination,
      bytes,
      overwrite: false,
      beforePublish: beforePublish,
    );
  }

  Future<void> selectTlsFile(String key) async {
    final project = owner, captured = plan, selectedEnvironment = environment;
    if (project == null || captured == null || busy || hasComposingInput) {
      return;
    }
    final selection = (_tlsSelections[key] ?? 0) + 1;
    _tlsSelections[key] = selection;
    final file = await openFile();
    bool current() =>
        !_disposed &&
        identical(owner, project) &&
        identical(plan, captured) &&
        environment == selectedEnvironment &&
        _tlsSelections[key] == selection;
    if (file == null || !current()) return;
    await project.approveExecutionFile(file.path);
    if (!current()) return;
    tlsFiles[key] = file.path;
    _notify();
  }

  static Map<String, List<String>> formFields(String text) {
    final result = <String, List<String>>{};
    for (final field in formRows(text)) {
      (result[field.name] ??= []).add(field.value);
    }
    return result;
  }

  static List<RequestFormField> formRows(String text) {
    final result = <RequestFormField>[];
    for (final line in text.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final equals = line.indexOf('=');
      if (equals <= 0) {
        throw CoreFailure(
          'request.form.field',
          'Form fields use one literal name=value entry per line',
        );
      }
      final name = line.substring(0, equals);
      final value = line.substring(equals + 1);
      result.add(RequestFormField(name, value));
    }
    return result;
  }

  Future<void> send() async {
    final captured = plan;
    if (!canSend || captured == null) return;
    final epoch = ++_epoch, draftRevision = _draftRevision;
    final token = RunCancellation();
    cancellation = token;
    phase = 'sending';
    failure = failureMessage = null;
    _notify();
    try {
      final selected = captured.configuration.environments[environment];
      final configured = selected?.authentication['schemes'];
      final requirements = captured.result['security']['requirements'] as List;
      final requiredGrants = <String, Set<String>>{};
      if (securityAlternative != null &&
          securityAlternative! >= 0 &&
          securityAlternative! < requirements.length) {
        final requirement = requirements[securityAlternative!] as Map;
        final scopes = requirement['scopes'];
        if (configured is Map && scopes is Map) {
          for (final scheme
              in (requirement['schemes'] as List).whereType<String>()) {
            final configuration = configured[scheme];
            final reference = configuration is Map
                ? configuration['accessTokenRef']
                : null;
            final required = scopes[scheme] is List
                ? (scopes[scheme] as List).cast<String>()
                : const <String>[];
            if (reference is String) {
              requiredGrants
                  .putIfAbsent(reference, () => <String>{})
                  .addAll(required);
            }
          }
        }
      }
      final completed = await const ContractRequestExecutor().execute(
        captured,
        draft(),
        resolveSecret: (reference) async {
          try {
            final value = await secrets.read(reference);
            // read verifies the credential digest/version before any known
            // expiry or grant can govern this Send, including backend edits.
            final metadata = secrets.metadata(reference);
            if (metadata != null &&
                !metadata.scopes.toSet().containsAll(
                  requiredGrants[reference] ?? const <String>{},
                )) {
              throw CoreFailure(
                'oauth.scopes.granted',
                'The known credential grant does not include this operation’s required scopes. Review setup and authorize again.',
              );
            }
            return value;
          } on SecretStoreFailure catch (error) {
            throw CoreFailure(error.code, error.message);
          }
        },
        cancellation: token,
      );
      if (_disposed ||
          epoch != _epoch ||
          !identical(captured, plan) ||
          !identical(owner, workspace.project)) {
        await completed.close();
        return;
      }
      final previous = result;
      result = completed;
      _resultDraftRevision = draftRevision;
      history.add(
        ContractRequestRecord.fromResult(completed, recordedAt: DateTime.now()),
      );
      if (history.length > 100) history.removeRange(0, history.length - 100);
      phase = token.cancelled
          ? 'cancelled'
          : completed.response.receiptComplete &&
                completed.received.complete &&
                completed.outgoing.complete
          ? 'complete'
          : 'incomplete';
      // Publish the entire owned result synchronously. Deleting an old private
      // response cannot delay publication or resume into another draft owner.
      if (previous != null) unawaited(_retireResult(previous));
    } on Object catch (error) {
      if (_disposed || epoch != _epoch) return;
      phase = error is CoreFailure && error.code == 'cancelled'
          ? 'cancelled'
          : 'failed';
      failure = error is CoreFailure ? error.code : 'request.execution';
      failureMessage = error is CoreFailure ? error.message : null;
    } finally {
      if (epoch == _epoch) {
        cancellation = null;
        _notify();
      }
    }
  }

  void cancel() {
    cancellation?.cancel();
    if (phase == 'preparing') {
      ++_epoch;
      phase = 'cancelled';
      _notify();
    }
  }

  Future<void> writeSecret(
    String reference,
    String value,
    SecretPersistence persistence, {
    bool allowEmpty = false,
  }) async {
    final scope = (owner, plan, environment);
    _credentialWrites[scope] = (_credentialWrites[scope] ?? 0) + 1;
    _notify();
    try {
      await secrets.write(
        reference,
        value,
        persistence: persistence,
        allowEmpty: allowEmpty,
      );
    } finally {
      final remaining = (_credentialWrites[scope] ?? 1) - 1;
      if (remaining == 0) {
        _credentialWrites.remove(scope);
      } else {
        _credentialWrites[scope] = remaining;
      }
      if (scope == (owner, plan, environment)) refresh();
    }
  }

  Future<void> authorizeOAuth(String scheme, {required bool browser}) async {
    final captured = plan, selectedEnvironment = environment;
    if (captured == null ||
        selectedEnvironment == null ||
        busy ||
        hasComposingInput ||
        outdated ||
        captured.outdated ||
        hasUnavailableSelection) {
      return;
    }
    final authorizationDraft = OperationRequestDraft(
      planIdentity: captured.identity,
      environment: selectedEnvironment,
      server: server,
      securityAlternative: securityAlternative,
    );
    final selected = captured.configuration.environments[selectedEnvironment];
    final configured = selected?.authentication['schemes'];
    final schemeConfiguration = configured is Map ? configured[scheme] : null;
    final tokenReference = schemeConfiguration is Map
        ? schemeConfiguration['accessTokenRef']
        : null;
    if (tokenReference is! String) {
      throw CoreFailure(
        'oauth.configuration',
        'Configure an accessTokenRef for the selected OAuth scheme',
      );
    }
    final epoch = ++_epoch, token = RunCancellation();
    cancellation = token;
    phase = 'authorizing';
    failure = failureMessage = null;
    _notify();
    try {
      final issued = browser
          ? await const OAuthClient().authorizationCode(
              captured,
              environment: selectedEnvironment,
              draft: authorizationDraft,
              scheme: scheme,
              launchBrowser: ExternalUriService().open,
              cancellation: token,
              resolveSecret: (reference) async {
                try {
                  return await secrets.read(reference, cancellation: token);
                } on SecretStoreFailure catch (error) {
                  throw CoreFailure(error.code, error.message);
                }
              },
            )
          : await const OAuthClient().clientCredentials(
              captured,
              environment: selectedEnvironment,
              draft: authorizationDraft,
              scheme: scheme,
              resolveSecret: (reference) async {
                try {
                  return await secrets.read(reference, cancellation: token);
                } on SecretStoreFailure catch (error) {
                  throw CoreFailure(error.code, error.message);
                }
              },
              cancellation: token,
            );
      if (_disposed ||
          epoch != _epoch ||
          token.cancelled ||
          !identical(captured, plan) ||
          captured.outdated ||
          environment != selectedEnvironment ||
          server != authorizationDraft.server ||
          securityAlternative != authorizationDraft.securityAlternative ||
          issued.owner != captured.identity ||
          issued.environment != selectedEnvironment) {
        return;
      }
      await secrets.write(
        tokenReference,
        issued.accessToken,
        persistence: SecretPersistence.sessionOnly,
      );
      if (_disposed ||
          epoch != _epoch ||
          token.cancelled ||
          !identical(captured, plan) ||
          captured.outdated ||
          environment != selectedEnvironment ||
          server != authorizationDraft.server ||
          securityAlternative != authorizationDraft.securityAlternative) {
        return;
      }
      secrets.rememberOAuth(
        tokenReference,
        issued.accessToken,
        issued.scope,
        issued.expiresAt,
      );
      phase = 'ready';
    } on Object catch (error) {
      if (_disposed || epoch != _epoch) return;
      phase = error is CoreFailure && error.code == 'cancelled'
          ? 'cancelled'
          : 'failed';
      failure = error is CoreFailure ? error.code : 'oauth.execution';
      failureMessage = error is CoreFailure ? error.message : null;
    } finally {
      if (epoch == _epoch) {
        if (phase == 'authorizing') {
          phase = token.cancelled ? 'cancelled' : 'incomplete';
          failure = token.cancelled ? 'cancelled' : 'oauth.stale';
          failureMessage = 'Authorization no longer matches the current request. Review the environment and authentication, then authorize again deliberately.';
        }
        cancellation = null;
        _notify();
      }
    }
  }

  Future<RefactoringPlan> planExample(String reviewedJson) async {
    final capturedPlan = plan, capturedResult = result;
    if (capturedPlan == null || capturedResult == null) {
      throw CoreFailure(
        'example.response',
        'No captured response is available',
      );
    }
    return capturedResult.request.plan.planResponseExample(
      reviewedJson,
      status: capturedResult.response.status,
      headers: capturedResult.response.headers,
      receiptComplete: capturedResult.response.exampleEligible,
      redacted: true,
    );
  }

  Future<void> _retireResult(ContractRequestResult previous) async {
    final oldPlan = previous.request.plan;
    try {
      await previous.close();
    } finally {
      // A newer retained response can still own the same captured plan while
      // another draft is being prepared (and plan is temporarily null).
      if (!identical(oldPlan, plan) &&
          !identical(oldPlan, result?.request.plan)) {
        oldPlan.close();
      }
    }
  }

  Future<void> _releaseResult() async {
    final previous = result;
    result = null;
    if (previous != null) {
      await _retireResult(previous);
    }
  }

  void toggle() {
    expanded = !expanded;
    _notify();
  }

  void clear({bool retainProjectDrafts = false}) {
    if (retainProjectDrafts) _remember();
    _previewTimer?.cancel();
    ++_previewEpoch;
    effectiveRequest = previewFailure = null;
    ++_epoch;
    cancellation?.cancel();
    cancellation = null;
    unawaited(_releaseResult());
    plan?.close();
    plan = null;
    owner = null;
    _operationKey = _draftIdentity = null;
    if (!retainProjectDrafts) {
      _drafts.clear();
      _setupDrafts.clear();
      _lastEnvironment.clear();
    }
    _resetValues();
    phase = 'idle';
    failure = null;
    if (!retainProjectDrafts) {
      history.clear();
      secrets.clearSession();
    }
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _setupDrafts.clear();
    _previewTimer?.cancel();
    ++_previewEpoch;
    workspace.removeListener(_observe);
    cancellation?.cancel();
    unawaited(_releaseResult());
    plan?.close();
    secrets.clearSession();
    super.dispose();
  }
}

String _semanticIdentity(Object? value) {
  Object? normalize(Object? value) {
    if (value is List) return value.map(normalize).toList();
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final key in keys) key: normalize(value[key])};
    }
    return value;
  }

  return jsonEncode(normalize(value));
}

String? _serverIdentity(RequestRunController run, int index) {
  final servers = run.plan?.result['servers'] as List? ?? [];
  if (index < 0 || index >= servers.length) return null;
  final declaration = servers[index] as Map;
  // Only these projection fields are presentation/provenance. Dictionary keys
  // inside variables are authored data, even when named source or description.
  final server = {
    for (final key in ['url', 'base', 'origin']) key: declaration[key],
    'variables': {
      for (final entry in (declaration['variables'] as Map).entries)
        entry.key: {
          for (final key in ['default', 'enum']) key: entry.value[key],
        },
    },
  };
  if (Uri.tryParse(server['url'] as String)?.isAbsolute == true) {
    server.remove('base');
  }
  final selected = run.plan?.configuration.environments[run.environment];
  final destination = '${server['url']} ${selected?.baseUrl ?? ''}';
  final usedVariables = RegExp(r'\$?\{([^{}]+)\}')
      .allMatches(destination)
      .map((m) => m[1]!)
      .toSet();
  final source = declaration['source'];
  return _semanticIdentity({
    'server': server,
    'context': source is Map
        ? [
            source['resource'],
            (source['pointer'] as String).replaceFirst(RegExp(r'/[0-9]+$'), ''),
          ]
        : null,
    'override': run.plan?.configuration.environments[run.environment]?.baseUrl,
    'variables': {
      for (final entry
          in (selected?.variables ?? const <String, String>{}).entries)
        if (usedVariables.contains(entry.key)) entry.key: entry.value,
    },
  });
}

String? _securityIdentity(RequestRunController run, int? index) {
  final security = run.plan?.result['security'];
  if (security is! Map) return null;
  final requirements = security['requirements'] as List;
  if (index == null) return requirements.isEmpty ? 'no-security' : null;
  if (index < 0 || index >= requirements.length) return null;
  final requirement = requirements[index] as Map;
  final names = (requirement['schemes'] as List).cast<String>().toList()
    ..sort();
  final rawScopes = requirement['scopes'];
  final scopes = {
    for (final name in names)
      name: rawScopes is Map && rawScopes[name] is List
          ? ((rawScopes[name] as List).cast<String>().toSet().toList()..sort())
          : <String>[],
  };
  final schemes = {
    for (final name in names)
      name: {
        for (final entry in (security['schemes'][name] as Map).entries)
          if (!{'source', 'definition', 'description'}.contains(entry.key))
            entry.key: entry.value,
        if (security['schemes'][name]['flows'] case final Map flows)
          'flows': {
            for (final flow in flows.entries)
              flow.key: {
                for (final key in [
                  'authorizationUrl',
                  'tokenUrl',
                  'refreshUrl',
                ])
                  key: flow.value[key],
                'scopes': ((flow.value['scopes'] as Map?)?.keys.toList() ?? [])
                  ..sort(),
              },
          },
      },
  };
  return _semanticIdentity({
    'names': names,
    'scopes': scopes,
    'schemes': schemes,
  });
}

class _RequestDraftState {
  _RequestDraftState(RequestRunController run)
    : identity = run._draftIdentity,
      serverIdentity = _serverIdentity(run, run.server),
      securityIdentity = _securityIdentity(run, run.securityAlternative),
      omitted = Set.of(run.omittedValues),
      representations = Map.of(run.exampleRepresentations),
      headers = List.of(run.customHeaders),
      kind = run.bodyKind,
      bodyStructured = run.bodyStructured,
      partMediaTypes = Map.of(run.partMediaTypes),
      timeoutInputs = Map.of(run.timeoutInputs),
      timeouts = (
        run.connectTimeout,
        run.overallTimeout,
        run.inactivityTimeout,
      ),
      values = Map.of(run.values),
      structured = Set.of(run.structuredValues),
      files = List.of(run.bodyFiles),
      tls = Map.of(run.tlsFiles),
      body = run.bodyText,
      part = run.bodyFilePart,
      header = run.headerName,
      headerValue = run.headerValue,
      enabled = run.bodyEnabled,
      media = run.bodyMediaType,
      server = run.server,
      security = run.securityAlternative;
  final String? identity, media, serverIdentity, securityIdentity;
  final Set<String> omitted;
  final Map<String, RequestValueRepresentation> representations;
  final List<RequestHeaderValue> headers;
  final RequestBodyKind kind;
  final bool bodyStructured;
  final Map<String, String> partMediaTypes;
  final (Duration, Duration, Duration) timeouts;
  final Map<RequestTimeoutKind, String> timeoutInputs;
  final Map<String, String> values, tls;
  final Set<String> structured;
  final List<MultipartFileValue> files;
  final String body, part, header, headerValue;
  final bool enabled;
  final int server;
  final int? security;
  int get bytes =>
      (body.length +
          partMediaTypes.entries.fold<int>(
            0,
            (n, entry) => n + entry.key.length + entry.value.length,
          ) +
          header.length +
          headerValue.length +
          values.entries.fold<int>(
            0,
            (n, v) => n + v.key.length + v.value.length,
          ) +
          headers.fold<int>(0, (n, h) => n + h.name.length + h.value.length) +
          timeoutInputs.values.fold<int>(0, (n, v) => n + v.length) +
          files.fold<int>(
            0,
            (n, f) =>
                n +
                f.name.length +
                f.path.length +
                (f.filename?.length ?? 0) +
                f.mediaType.length +
                (f.selectedMediaType?.length ?? 0),
          ) +
          tls.entries.fold<int>(
            0,
            (n, e) => n + e.key.length + e.value.length,
          )) *
      2;
  void restore(RequestRunController run) {
    run.values.addAll(values);
    run.omittedValues.addAll(omitted);
    run.exampleRepresentations.addAll(representations);
    run.customHeaders.addAll(headers);
    run.bodyKind = kind;
    run.bodyStructured = bodyStructured;
    run.partMediaTypes.addAll(partMediaTypes);
    run.timeoutInputs.addAll(timeoutInputs);
    run.connectTimeout = timeouts.$1;
    run.overallTimeout = timeouts.$2;
    run.inactivityTimeout = timeouts.$3;
    run.structuredValues.addAll(structured);
    run.bodyFiles.addAll(files);
    run.tlsFiles.addAll(tls);
    run.bodyText = body;
    run.bodyFilePart = part;
    run.headerName = header;
    run.headerValue = headerValue;
    run.bodyEnabled = enabled;
    run.bodyMediaType = media;
    final servers = run.plan!.result['servers'] as List;
    final serverMatches = [
      for (var i = 0; i < servers.length; i++)
        if (serverIdentity != null && _serverIdentity(run, i) == serverIdentity)
          i,
    ];
    run.server = serverMatches.length == 1
        ? serverMatches.single
        : server >= servers.length
        ? server
        : -1;
    final requirements = run.plan!.result['security']['requirements'] as List;
    final securityMatches = [
      for (var i = 0; i < requirements.length; i++)
        if (securityIdentity != null &&
            _securityIdentity(run, i) == securityIdentity)
          i,
    ];
    run.securityAlternative = securityIdentity == 'no-security'
        ? null
        : securityMatches.length == 1
        ? securityMatches.single
        : security != null && security! >= requirements.length
        ? security
        : -1;
    run._draftIdentity = identity;
  }
}

Future<void> _performRequestAction(
  BuildContext context,
  RequestRunController run,
  Future<void> Function() action,
) async {
  final owner = run.owner, captured = run.plan;
  try {
    await action();
  } on Object catch (error) {
    if (!context.mounted ||
        !identical(owner, run.owner) ||
        !identical(captured, run.plan)) {
      return;
    }
    final code = error is CoreFailure ? error.code : 'request.io';
    await showBusyApiModalDialog<void>(
      context: context,
      builder: (context) => BusyApiDialogShell(
        title: context.l10n.requestRun,
        actions: [
          BusyApiDialogButton(
            label: context.l10n.close,
            onPressed: () => Navigator.pop(context),
          ),
        ],
        children: [
          BusyApiStatusBox(
            message: switch (code) {
              'example.json' => context.l10n.responseExampleInvalidJson,
              'oauth.configuration' => context.l10n.oauthConfigurationRequired,
              'request.method.unsupported' =>
                context.l10n.requestMethodUnsupported,
              'request.trace.content' => context.l10n.requestTraceContent,
              'request.trace.credentials' =>
                context.l10n.requestTraceCredentials,
              _ =>
                error is CoreFailure
                    ? '${error.message}\n[$code]'
                    : context.l10n.requestFailed(code),
            },
            kind: BusyApiStatusKind.error,
          ),
        ],
      ),
    );
  }
}

class RequestRunPanel extends StatelessWidget {
  const RequestRunPanel({super.key, required this.run});
  final RequestRunController run;

  static String _reference() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> setup(BuildContext context) async {
    final captured = run.plan, owner = run.owner;
    if (captured == null ||
        owner == null ||
        run._operationKey == null ||
        run.busy ||
        run.hasComposingInput) {
      return;
    }
    final setupKey = (run._operationKey!, run.environment);
    final retainedSetup = run._setupDrafts[setupKey];
    final selected = captured.configuration.environments[run.environment];
    var name = retainedSetup?.name ?? run.environment ?? 'local',
        base = retainedSetup?.base ?? selected?.baseUrl ?? '';
    var variables =
        retainedSetup?.variables ??
        selected?.variables.entries
            .map((e) => '${e.key}=${e.value}')
            .join('\n') ??
        '';
    var headers =
        retainedSetup?.headers ??
        selected?.headers.entries
            .map((e) => '${e.key}=${e.value}')
            .join('\n') ??
        '';
    final schemes = <String, Map<String, Object?>>{};
    final declared = captured.result['security']['schemes'] as Map;
    final requirements = captured.result['security']['requirements'] as List;
    final alternative = run.securityAlternative;
    final requirement =
        alternative != null &&
            alternative >= 0 &&
            alternative < requirements.length
        ? requirements[alternative] as Map
        : const <String, Object?>{};
    final configured = selected?.authentication['schemes'];
    for (final entry in declared.entries) {
      final current = configured is Map ? configured[entry.key] : null;
      final config = current is Map
          ? {
              for (final field in current.entries)
                if (_setupSchemeFields.contains(field.key))
                  field.key as String: field.value,
            }
          : <String, Object?>{};
      final type = entry.value['type'];
      final key = type == 'apiKey'
          ? 'secretRef'
          : type == 'oauth2' || type == 'openIdConnect'
          ? 'accessTokenRef'
          : type == 'http' &&
                entry.value['scheme'].toString().toLowerCase() == 'basic'
          ? 'passwordRef'
          : type == 'http' &&
                entry.value['scheme'].toString().toLowerCase() == 'bearer'
          ? 'tokenRef'
          : null;
      if (key != null && config[key] == null) config[key] = _reference();
      if (type == 'http' &&
          '${entry.value['scheme']}'.toLowerCase() == 'basic') {
        config.putIfAbsent('username', () => '');
      }
      if (type == 'oauth2') {
        final flows = entry.value['flows'];
        config.putIfAbsent(
          'clientAuthentication',
          () => flows is Map && flows['authorizationCode'] is Map
              ? 'none'
              : 'basic',
        );
        if (config['clientAuthentication'] != 'none') {
          config.putIfAbsent('clientSecretRef', _reference);
        }
        final required = requirement['scopes'];
        config.putIfAbsent(
          'scopes',
          () => required is Map && required[entry.key] is List
              ? List<String>.from(required[entry.key] as List)
              : <String>[],
        );
      }
      schemes[entry.key as String] = config;
    }
    if (retainedSetup != null) {
      for (final entry in retainedSetup.schemes.entries) {
        schemes[entry.key] = {...?schemes[entry.key], ...entry.value};
      }
    }
    var keyPassword =
        retainedSetup?.keyPassword ??
        selected?.tls['clientKeyPasswordRef'] != null;
    var composing = false;
    String? error;
    Map<String, Object?>? accepted;
    final approved = await showBusyApiModalDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          final l = context.l10n;
          Widget input(
            String label,
            String value,
            void Function(String) changed, {
            bool multiline = false,
          }) => _SetupEntry(
            label: label,
            value: value,
            multiline: multiline,
            onChanged: changed,
            onComposition: (active) => setState(() => composing = active),
          );
          return BusyApiDialogShell(
            title: l.requestSetup,
            actions: [
              BusyApiDialogButton(
                label: l.cancel,
                onPressed: () => Navigator.pop(context, false),
              ),
              BusyApiDialogButton(
                label: l.requestSetupReview,
                suggested: true,
                onPressed: composing
                    ? null
                    : () {
                        try {
                          if (name.length +
                                  base.length +
                                  variables.length +
                                  headers.length >
                              65536) {
                            throw CoreFailure(
                              'limit.manifest',
                              'Setup input exceeds the 64 KiB configuration bound. Reduce it before review.',
                            );
                          }
                          Map<String, String> literals(String text) {
                            final rows = RequestRunController.formFields(text);
                            if (rows.values.any((v) => v.length != 1)) {
                              throw CoreFailure(
                                'environment.value',
                                'Environment mappings need unique names.',
                              );
                            }
                            return rows.map(
                              (key, value) => MapEntry(key, value.single),
                            );
                          }

                          if (name.isEmpty || name.length > 128) {
                            throw CoreFailure(
                              'environment.name',
                              'Enter an environment name of 1–128 characters.',
                            );
                          }
                          final environmentHeaders = literals(headers);
                          if (environmentHeaders.keys.any(
                            (key) => [
                              'authorization',
                              'proxy-authorization',
                              'cookie',
                              'host',
                              'content-length',
                              'content-type',
                              'transfer-encoding',
                            ].contains(key.toLowerCase()),
                          )) {
                            throw CoreFailure(
                              'environment.headers',
                              'Use authentication/body controls for generated credential and structural headers.',
                            );
                          }
                          bool validReference(Object? value) {
                            if (value is! String) return false;
                            try {
                              LibsecretBusyApiSecretStore.key(value);
                              return true;
                            } on SecretStoreFailure {
                              return false;
                            }
                          }

                          for (final scheme in schemes.entries) {
                            for (final reference in scheme.value.entries.where(
                              (e) => _setupReferences.contains(e.key),
                            )) {
                              if (!validReference(reference.value)) {
                                throw CoreFailure(
                                  'secret.reference',
                                  'Replace the invalid scoped credential reference for ${scheme.key}.',
                                );
                              }
                            }
                            for (final field in ['username', 'clientId']) {
                              if (scheme.value.containsKey(field) &&
                                  scheme.value[field] is! String) {
                                throw CoreFailure(
                                  'environment.authentication',
                                  'Edit $field for ${scheme.key}; it must be text.',
                                );
                              }
                            }
                            final scopes = scheme.value['scopes'];
                            if (scopes != null &&
                                (scopes is! List ||
                                    scopes.any(
                                      (s) =>
                                          s is! String ||
                                          s.isEmpty ||
                                          RegExp(r'[\x00-\x20\x7f]')
                                              .hasMatch(s),
                                    ))) {
                              throw CoreFailure(
                                'oauth.scopes',
                                'Edit the requested scopes for ${scheme.key}; use individual space-separated scope names.',
                              );
                            }
                            final mode = scheme.value['clientAuthentication'];
                            if (mode != null &&
                                !['basic', 'body', 'none'].contains(mode)) {
                              throw CoreFailure(
                                'oauth.configuration',
                                'Choose a supported client authentication mode for ${scheme.key}.',
                              );
                            }
                          }
                          final tls = <String, Object?>{
                            for (final field
                                in selected?.tls.entries ??
                                    const Iterable<
                                      MapEntry<String, Object?>
                                    >.empty())
                              if (_setupTlsFields.contains(field.key))
                                field.key: field.value,
                          };
                          if (keyPassword) {
                            if (!validReference(tls['clientKeyPasswordRef'])) {
                              tls['clientKeyPasswordRef'] = _reference();
                            }
                          } else {
                            tls.remove('clientKeyPasswordRef');
                          }
                          accepted = {
                            'variables': literals(variables),
                            'headers': environmentHeaders,
                            'tls': tls,
                            if (base.isNotEmpty) 'baseUrl': base,
                            'authentication': {
                              if (alternative != null && alternative >= 0)
                                'alternative': alternative,
                              'schemes': {...schemes},
                            },
                          };
                          ExecutionEnvironment.parse(
                            name,
                            accepted!,
                            owner.access.boundary,
                          );
                          if (utf8.encode(jsonEncode(accepted)).length >
                              65536) {
                            throw CoreFailure(
                              'limit.manifest',
                              'Setup exceeds the 64 KiB configuration bound. Reduce it before review.',
                            );
                          }
                          Navigator.pop(context, true);
                        } on CoreFailure catch (failure) {
                          setState(() => error = failure.message);
                        }
                      },
              ),
            ],
            children: [
              SelectableText(l.requestSetupHelp),
              if (retainedSetup != null)
                BusyApiStatusBox(message: l.requestSetupRetained),
              if (error != null)
                BusyApiStatusBox(
                  message: error!,
                  kind: BusyApiStatusKind.error,
                ),
              BusyApiGroupedList(
                children: [
                  input(l.requestSetupName, name, (v) => name = v),
                  input(l.requestSetupBase, base, (v) => base = v),
                  input(
                    l.requestSetupVariables,
                    variables,
                    (v) => variables = v,
                    multiline: true,
                  ),
                  input(
                    l.requestSetupHeaders,
                    headers,
                    (v) => headers = v,
                    multiline: true,
                  ),
                ],
              ),
              for (final entry in schemes.entries)
                BusyApiGroupedList(
                  title: declared.containsKey(entry.key)
                      ? entry.key
                      : '${entry.key} · ${l.requestSelectionUnavailable}',
                  children: [
                    if ((declared[entry.key] as Map?)?['type'] == 'http' &&
                        (declared[entry.key] as Map?)?['scheme']
                                .toString()
                                .toLowerCase() ==
                            'basic')
                      input(
                        l.requestSetupUsername,
                        '${entry.value['username'] ?? ''}',
                        (v) => entry.value['username'] = v,
                      ),
                    if ((declared[entry.key] as Map?)?['type'] == 'oauth2') ...[
                      input(
                        l.requestSetupClient,
                        '${entry.value['clientId'] ?? ''}',
                        (v) => entry.value['clientId'] = v,
                      ),
                      input(
                        l.requestSetupScopes,
                        entry.value['scopes'] is List
                            ? (entry.value['scopes'] as List).join(' ')
                            : '${entry.value['scopes'] ?? ''}',
                        (v) => entry.value['scopes'] = v
                            .split(RegExp(r'\s+'))
                            .where((s) => s.isNotEmpty)
                            .toList(),
                      ),
                      BusyApiComboRow<String>(
                        title: l.authentication,
                        selected:
                            '${entry.value['clientAuthentication'] ?? 'basic'}',
                        values: {
                          '${entry.value['clientAuthentication'] ?? 'basic'}',
                          'basic',
                          'body',
                          'none',
                        }.toList(),
                        labelFor: (v) => ['basic', 'body', 'none'].contains(v)
                            ? v
                            : '$v · ${l.requestSelectionUnavailable}',
                        enabledFor: (v) =>
                            ['basic', 'body', 'none'].contains(v),
                        onSelected: (v) => setState(() {
                          entry.value['clientAuthentication'] = v;
                          if (v != 'none') {
                            entry.value.putIfAbsent(
                              'clientSecretRef',
                              _reference,
                            );
                          }
                        }),
                      ),
                    ],
                    for (final reference in entry.value.entries.where(
                      (e) => _setupReferences.contains(e.key),
                    ))
                      BusyApiActionRow(
                        title: switch (reference.key) {
                          'secretRef' => l.secretApiKey,
                          'passwordRef' => l.secretBasicPassword,
                          'accessTokenRef' => l.secretOAuthToken,
                          'clientSecretRef' => l.secretOAuthClient,
                          _ => l.secretBearer,
                        },
                        subtitle:
                            '${reference.value ?? l.requestSelectionUnavailable}',
                        trailing: BusyApiCompactIconButton(
                          tooltip: l.requestReconcile,
                          icon: BusyApiGlyphs.clear,
                          onPressed: composing
                              ? null
                              : () => setState(
                                  () =>
                                      entry.value[reference.key] = _reference(),
                                ),
                        ),
                      ),
                  ],
                ),
              BusyApiSwitchRow(
                title: l.requestSetupTlsPassword,
                value: keyPassword,
                onChanged: (v) => setState(() => keyPassword = v),
              ),
            ],
          );
        },
      ),
    );
    if (approved != true || accepted == null) {
      if (identical(run._setupDrafts[setupKey], retainedSetup)) {
        run._setupDrafts.remove(setupKey);
      }
      return;
    }
    final savedSetup = _EnvironmentSetupDraft(
      name,
      base,
      variables,
      headers,
      schemes,
      keyPassword,
    );
    if (!run._disposed && identical(owner, run.workspace.project)) {
      run._setupDrafts.remove(setupKey);
      run._setupDrafts[setupKey] = savedSetup;
      while (run._setupDrafts.length > 32) {
        run._setupDrafts.remove(run._setupDrafts.keys.first);
      }
    }
    if (!context.mounted ||
        !identical(captured, run.plan) ||
        !identical(owner, run.owner)) {
      return;
    }
    final edit = await captured.planEnvironment(name, accepted!);
    if (!context.mounted || !identical(captured, run.plan)) return;
    await showRefactoringReview(
      context,
      run.workspace,
      owner,
      edit,
      onApplied: () {
        if (identical(run._setupDrafts[setupKey], savedSetup)) {
          run._setupDrafts.remove(setupKey);
        }
        run.failureMessage = null;
        run.refresh();
      },
    );
    if (!identical(captured, run.plan)) return;
    // Reconciliation preserves entered values. A changed destination/security
    // identity stays unavailable until deliberately selected in the current plan.
    await run.reconcileDraft();
    if (run.plan?.configuration.environments.containsKey(name) == true &&
        run.environment == null) {
      final retained = _RequestDraftState(run);
      run.selectEnvironment(name);
      retained.restore(run);
      run._draftIdentity = run.plan!.identity;
      run._environmentAuthentication();
      // This explicit setup selected the new environment; its destination
      // still requires a current server selection if its meaning changed.
      run.refresh();
    }
  }

  Future<void> export(BuildContext context) async {
    final response = run.result?.response;
    if (response == null) return;
    final location = await getSaveLocation(
      suggestedName: 'busyapi-response.bin',
      confirmButtonText: context.l10n.responseExport,
    );
    if (location == null) return;
    await response.export(location.path);
  }

  Future<void> saveExample(BuildContext context) async {
    final captured = run.result;
    if (captured == null) return;
    String reviewed;
    try {
      reviewed = utf8.decode(await captured.response.decodedBytes());
      jsonDecode(reviewed);
    } on Object {
      throw CoreFailure(
        'example.json',
        'The complete response is not strict UTF-8 JSON',
      );
    }
    if (!context.mounted || !identical(captured, run.result)) return;
    var acknowledged = false, composing = false;
    String? validationError, acceptedText;
    final edited = TextEditingController(text: reviewed);
    ModalRoute<bool>? reviewRoute;
    final accepted = await showBusyApiModalDialog<bool>(
      onRoutePushed: (route, _) => reviewRoute = route,
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => BusyApiDialogShell(
          title: context.l10n.saveResponseExample,
          closable: true,
          actions: [
            BusyApiDialogButton(
              label: context.l10n.cancel,
              onPressed: () => Navigator.pop(context, false),
            ),
            BusyApiDialogButton(
              label: context.l10n.reviewResponseExample,
              suggested: true,
              onPressed: acknowledged && !composing
                  ? () {
                      if (edited.value.composing.isValid) return;
                      try {
                        jsonDecode(edited.text);
                      } on FormatException {
                        setState(
                          () => validationError =
                              context.l10n.responseExampleInvalidJson,
                        );
                        return;
                      }
                      acceptedText = edited.text;
                      Navigator.pop(context, true);
                    }
                  : null,
            ),
          ],
          children: [
            Text(context.l10n.responseExampleImpact),
            if (validationError != null)
              BusyApiStatusBox(
                message: validationError!,
                kind: BusyApiStatusKind.error,
              ),
            BusyApiGroupedList(
              children: [
                FormValueEditor(
                  label: context.l10n.responseBody,
                  controller: edited,
                  enabled: true,
                  multiline: true,
                  json: true,
                  onCompositionChanged: (value) =>
                      setState(() => composing = value),
                ),
                BusyApiActionRow(
                  title: context.l10n.responseExampleRedacted,
                  onTap: () => setState(() => acknowledged = !acknowledged),
                  trailing: BusyApiCheckbox(
                    value: acknowledged,
                    onChanged: (value) =>
                        setState(() => acknowledged = value == true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await reviewRoute?.completed;
    final value = acceptedText;
    edited.dispose();
    if (accepted != true ||
        value == null ||
        !context.mounted ||
        !identical(captured, run.result)) {
      return;
    }
    jsonDecode(value);
    final plan = await run.planExample(value);
    if (!context.mounted || !identical(captured, run.result)) return;
    await showRefactoringReview(context, run.workspace, run.owner!, plan);
  }

  Future<void> exportHistory(BuildContext context) async {
    if (run.history.isEmpty) return;
    final owner = run.owner, epoch = run._epoch;
    final records = List<ContractRequestRecord>.of(run.history);
    final location = await getSaveLocation(
      suggestedName: 'busyapi-request-history.json',
      confirmButtonText: context.l10n.responseExport,
    );
    if (location == null ||
        !context.mounted ||
        !identical(owner, run.owner) ||
        epoch != run._epoch) {
      return;
    }
    await run.exportHistory(
      location.path,
      records: records,
      beforePublish: () async {
        if (!identical(owner, run.owner) || epoch != run._epoch) {
          throw CoreFailure(
            'cancelled',
            'History ownership changed; export again deliberately.',
          );
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([run, run.workspace]),
    builder: (context, _) {
      if (run.phase == 'idle') return const SizedBox.shrink();
      final l = context.l10n, plan = run.plan, result = run.result;
      final status = run.failure == 'request.draft.limit'
          ? l.requestDraftTooLarge
          : run.failure == 'request.method.unsupported'
          ? l.requestMethodUnsupported
          : run.failure == 'request.trace.content'
          ? l.requestTraceContent
          : run.failure == 'request.trace.credentials'
          ? l.requestTraceCredentials
          : switch (run.phase) {
              'preparing' => l.requestPreparing,
              'ready' =>
                run.hasPendingSecretInput
                    ? l.secretPending
                    : !run.timeoutsValid
                    ? l.requestTimeoutHelp
                    : run.hasUnavailableSelection || run.bodyMediaNeedsSelection
                    ? l.requestSelectionUnavailable
                    : run.requiredInputMissing ||
                          run.previewFailure != null ||
                          run.effectiveRequest == null
                    ? run.previewFailure ?? l.requestPreviewPending
                    : l.requestReady,
              'sending' => l.requestSending,
              'authorizing' => l.requestAuthorizing,
              'cancelled' => l.requestCancelled,
              'complete' || 'incomplete' =>
                result?.response.receiptComplete == true
                    ? '${result!.response.status} ${result.response.reason}'
                    : l.incomplete,
              _ => l.requestFailed(run.failure ?? 'request.execution'),
            };
      return BusyApiToolSurface(
        title: plan == null ? l.requestRun : '${l.requestRun} · ${run.title}',
        status: run.outdated ? l.requestOutdated : status,
        expanded: run.expanded,
        onToggle: run.toggle,
        kind: run.failure == null
            ? BusyApiStatusKind.information
            : BusyApiStatusKind.error,
        actions: [
          BusyApiCompactIconButton(
            tooltip: l.requestSend,
            icon: BusyApiGlyphs.play,
            onPressed: run.canSend ? run.send : null,
          ),
          if (run.busy)
            BusyApiCompactIconButton(
              tooltip: l.cancel,
              icon: BusyApiGlyphs.clear,
              onPressed: run.cancel,
            ),
        ],
        child: plan == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (run.failureMessage != null)
                    Semantics(
                      liveRegion: true,
                      child: SelectableText(run.failureMessage!),
                    ),
                  if (result != null)
                    _ResponseInspector(
                      run: run,
                      key: ValueKey(result.response.runId),
                      result: result,
                      previous: true,
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                key: ValueKey(
                  '${run._operationKey}/${run.environment}/${run._draftView}',
                ),
                children: [
                  Semantics(
                    liveRegion: true,
                    child: SelectableText(run.failureMessage ?? status),
                  ),
                  BusyApiGroupedList(
                    title: l.requestEffective,
                    children: [
                      BusyApiActionRow(
                        title:
                            run.effectiveRequest ??
                            run.previewFailure ??
                            l.requestPreviewPending,
                        titleWidget: SelectableText(
                          run.outdated || run.hasUnavailableSelection
                              ? l.requestSelectionUnavailable
                              : run.effectiveRequest ??
                                    run.previewFailure ??
                                    l.requestPreviewPending,
                        ),
                        subtitle:
                            '${run.environment ?? l.requestDefaultEnvironment} · ${plan.configuration.environments[run.environment]?.baseUrl != null ? l.requestEnvironmentOverride : l.requestAuthoredServer}',
                      ),
                      if (BusyApiCommandRegistryScope.maybeOf(
                            context,
                          )?['request-send']?.shortcut?.label
                          case final String binding)
                        BusyApiActionRow(
                          title: l.requestSend,
                          trailing: BusyApiKeyboardShortcutBadge(binding),
                        ),
                    ],
                  ),
                  if (result != null)
                    _ResponseInspector(
                      run: run,
                      key: ValueKey(result.response.runId),
                      result: result,
                      previous:
                          run.busy ||
                          run.failure != null ||
                          run.resultDraftChanged ||
                          run.hasPendingSecretInput,
                    ),
                  BusyApiGroupedList(
                    children: [
                      BusyApiActionRow(
                        title: l.requestSetup,
                        enabled:
                            !run.busy &&
                            !run.hasComposingInput &&
                            !run.outdated,
                        onTap: () => _performRequestAction(
                          context,
                          run,
                          () => setup(context),
                        ),
                      ),
                      _choice<String?>(
                        label: l.environment,
                        value: run.environment,
                        values: <String?>[
                          null,
                          ...plan.configuration.environments.keys,
                        ],
                        text: (value) => value ?? l.requestDefaultEnvironment,
                        unavailableText: (value) =>
                            l.requestUnavailableSelection(
                              value ?? l.requestDefaultEnvironment,
                            ),
                        onChanged: run.busy || run.hasComposingInput
                            ? null
                            : run.selectEnvironment,
                      ),
                      _choice<int>(
                        label: l.server,
                        value: run.server,
                        values: List.generate(
                          (plan.result['servers'] as List).length,
                          (index) => index,
                        ),
                        text: (value) =>
                            '${(plan.result['servers'] as List)[value]['url']}',
                        unavailableText: (value) =>
                            (plan.result['servers'] as List).isEmpty
                            ? l.requestNoServers
                            : l.requestUnavailableSelection('${value + 1}'),
                        onChanged: run.busy || run.hasComposingInput
                            ? null
                            : (value) {
                                if (run.hasComposingInput) return;
                                if (value != null) run.server = value;
                                run.refresh();
                              },
                      ),
                      if ((plan.result['security']['requirements'] as List)
                              .isNotEmpty ||
                          run.securityAlternative != null)
                        _choice<int?>(
                          label: l.authentication,
                          value: run.securityAlternative,
                          values: <int?>[
                            if ((plan.result['security']['requirements']
                                    as List)
                                .isEmpty)
                              null,
                            ...List.generate(
                              (plan.result['security']['requirements'] as List)
                                  .length,
                              (index) => index,
                            ),
                          ],
                          text: (value) => value == null
                              ? l.requestNoAuthentication
                              : ((plan.result['security']['requirements']
                                            as List)[value]['schemes']
                                        as List)
                                    .isEmpty
                              ? l.requestAnonymous
                              : ((plan.result['security']['requirements']
                                            as List)[value]['schemes']
                                        as List)
                                    .join(' + '),
                          unavailableText: (value) => value == null
                              ? l.authentication
                              : l.requestUnavailableSelection('${value + 1}'),
                          onChanged: run.busy || run.hasComposingInput
                              ? null
                              : (value) {
                                  if (run.hasComposingInput) return;
                                  run.securityAlternative = value;
                                  run.refresh();
                                },
                        ),
                    ],
                  ),
                  if (run.securityAlternative != null &&
                      run.securityAlternative! >= 0 &&
                      run.securityAlternative! <
                          (plan.result['security']['requirements'] as List)
                              .length)
                    BusyApiActionRow(
                      title: l.requestRequiredScopes,
                      subtitle:
                          '${(plan.result['security']['requirements'] as List)[run.securityAlternative!]['scopes'] ?? {}}',
                    ),
                  if (run.hasUnavailableSelection)
                    BusyApiStatusBox(
                      message: l.requestSelectionUnavailable,
                      kind: BusyApiStatusKind.warning,
                    ),
                  for (final credential in _secretPolicies(run).entries)
                    RequestSecretInput(
                      key: ValueKey(
                        '${plan.identity}/${run.environment}/${credential.key}',
                      ),
                      run: run,
                      reference: credential.key,
                      role: _secretRole(run, credential.key, context),
                      tokenCredential: _isTokenReference(run, credential.key),
                      valuePolicies: List.unmodifiable(credential.value),
                    ),
                  BusyApiDisclosure(
                    title: Text(l.requestTls),
                    children: [
                      for (final entry in {
                        'caFile': l.requestTlsCa,
                        'clientCertificateFile': l.requestTlsCertificate,
                        'clientKeyFile': l.requestTlsKey,
                      }.entries) ...[
                        BusyApiActionRow(
                          title: entry.value,
                          subtitle:
                              run.tlsFiles[entry.key] ??
                              plan
                                      .configuration
                                      .environments[run.environment]
                                      ?.tls[entry.key]
                                  as String?,
                          enabled: !run.busy,
                          leading: const Icon(BusyApiGlyphs.documentOpen),
                          onTap: run.busy
                              ? null
                              : () => _performRequestAction(
                                  context,
                                  run,
                                  () => run.selectTlsFile(entry.key),
                                ),
                        ),
                        BusyApiActionRow(
                          title: '${entry.value} · ${l.requestTlsRemove}',
                          enabled: !run.busy,
                          onTap: () {
                            run.tlsFiles[entry.key] = '';
                            run.refresh();
                          },
                        ),
                        if (run.tlsFiles.containsKey(entry.key))
                          BusyApiActionRow(
                            title: '${entry.value} · ${l.requestTlsReset}',
                            enabled: !run.busy,
                            onTap: () {
                              run.tlsFiles.remove(entry.key);
                              run.refresh();
                            },
                          ),
                      ],
                    ],
                  ),
                  if (run.securityAlternative != null &&
                      run.environment == null &&
                      _oauthSchemes(run).isNotEmpty)
                    BusyApiStatusBox(message: l.oauthConfigurationRequired),
                  if (run.securityAlternative != null)
                    for (final oauth in _oauthSchemes(run))
                      Wrap(
                        spacing: BusyApiSpacing.sm,
                        children: [
                          if (oauth.$2)
                            BusyApiPushButton.standard(
                              onPressed: run.busy || run.environment == null
                                  ? null
                                  : () => _performRequestAction(
                                      context,
                                      run,
                                      () => run.authorizeOAuth(
                                        oauth.$1,
                                        browser: true,
                                      ),
                                    ),
                              child: Text(l.oauthAuthorize(oauth.$1)),
                            ),
                          if (oauth.$3)
                            BusyApiPushButton.standard(
                              onPressed: run.busy || run.environment == null
                                  ? null
                                  : () => _performRequestAction(
                                      context,
                                      run,
                                      () => run.authorizeOAuth(
                                        oauth.$1,
                                        browser: false,
                                      ),
                                    ),
                              child: Text(l.oauthClientToken(oauth.$1)),
                            ),
                        ],
                      ),
                  if ((plan.result['parameters'] as List).isNotEmpty) ...[
                    const SizedBox(height: BusyApiSpacing.sm),
                    SectionLabel(l.requestParameters),
                    for (final parameter
                        in (plan.result['parameters'] as List).whereType<Map>())
                      _ParameterRow(run: run, parameter: parameter),
                  ],
                  const SizedBox(height: BusyApiSpacing.sm),
                  BusyApiGroupedList(
                    title: l.requestHeaders,
                    description: l.requestHeaderProvenance,
                    children: [
                      for (final name
                          in plan
                                  .configuration
                                  .environments[run.environment]
                                  ?.headers
                                  .keys ??
                              const <String>[])
                        BusyApiActionRow(
                          title: name,
                          subtitle: l.requestHeaderEnvironmentOrigin,
                        ),
                      for (final parameter
                          in (plan.result['parameters'] as List)
                              .whereType<Map>()
                              .where((p) => p['in'] == 'header'))
                        BusyApiActionRow(
                          title: parameter['name'] as String,
                          subtitle: l.requestHeaderDeclaredOrigin,
                        ),
                      for (
                        var index = 0;
                        index < run.customHeaders.length;
                        index++
                      ) ...[
                        BusyApiSwitchRow(
                          title:
                              '${l.requestHeaders} ${index + 1} · ${l.requestHeaderCustomOrigin}',
                          value: run.customHeaders[index].enabled,
                          enabled: !run.busy,
                          onChanged: (included) {
                            final row = run.customHeaders[index];
                            run.customHeaders[index] = RequestHeaderValue(
                              row.name,
                              row.value,
                              enabled: included,
                            );
                            run.refresh();
                          },
                        ),
                        RequestDraftEntry(
                          run: run,
                          label: l.requestHeaderName,
                          value: run.customHeaders[index].name,
                          enabled: !run.busy,
                          onChanged: (name) {
                            final row = run.customHeaders[index];
                            run.customHeaders[index] = RequestHeaderValue(
                              name,
                              row.value,
                              enabled: row.enabled,
                            );
                          },
                        ),
                        RequestDraftEntry(
                          run: run,
                          label: l.requestHeaderValue,
                          value: run.customHeaders[index].value,
                          enabled: !run.busy,
                          onChanged: (value) {
                            final row = run.customHeaders[index];
                            run.customHeaders[index] = RequestHeaderValue(
                              row.name,
                              value,
                              enabled: row.enabled,
                            );
                          },
                        ),
                        BusyApiActionRow(
                          title: l.requestRemove,
                          enabled: !run.busy && !run.hasComposingInput,
                          onTap: () {
                            run.customHeaders.removeAt(index);
                            run.refresh();
                          },
                        ),
                      ],
                      RequestDraftEntry(
                        run: run,
                        label: l.requestHeaderName,
                        value: run.headerName,
                        enabled: !run.busy,
                        onChanged: (value) => run.headerName = value,
                      ),
                      RequestDraftEntry(
                        run: run,
                        label: l.requestHeaderValue,
                        value: run.headerValue,
                        enabled: !run.busy,
                        onChanged: (value) => run.headerValue = value,
                      ),
                      BusyApiActionRow(
                        title: l.requestAddHeader,
                        enabled: !run.busy && !run.hasComposingInput,
                        onTap: () {
                          run.customHeaders.add(
                            RequestHeaderValue(run.headerName, run.headerValue),
                          );
                          run.headerName = run.headerValue = '';
                          run.refresh();
                        },
                      ),
                      BusyApiStatusBox(message: l.requestHeadersGenerated),
                    ],
                  ),
                  if (plan.ignoredRequestBody case final ignored?)
                    BusyApiStatusBox(
                      message: l.requestBodyIgnored(ignored.method),
                    ),
                  if (plan.result['requestBody'] is Map ||
                      run.bodyEnabled ||
                      run.bodyMediaType != null)
                    _BodyEditor(run: run),
                  const SizedBox(height: BusyApiSpacing.sm),
                  Wrap(
                    spacing: BusyApiSpacing.sm,
                    children: [
                      BusyApiPushButton.suggested(
                        child: Text(l.requestSend),
                        onPressed: run.canSend ? run.send : null,
                      ),
                      if (run.busy)
                        BusyApiPushButton.standard(
                          onPressed: run.cancel,
                          child: Text(l.cancel),
                        ),
                      if (run.outdated && !run.busy)
                        BusyApiPushButton.standard(
                          onPressed: run.hasComposingInput
                              ? null
                              : run.reconcileDraft,
                          child: Text(l.requestReconcile),
                        ),
                      BusyApiPushButton.standard(
                        onPressed: run.busy || run.hasComposingInput
                            ? null
                            : run.discardDraft,
                        child: Text(l.requestDiscardDraft),
                      ),
                      if (result != null)
                        BusyApiPushButton.standard(
                          onPressed: () => _performRequestAction(
                            context,
                            run,
                            () => export(context),
                          ),
                          child: Text(
                            result.response.receiptComplete
                                ? l.responseOriginalExport
                                : l.responsePartialExport,
                          ),
                        ),
                      if (result != null &&
                          result.bodyPermitted &&
                          result.response.exampleEligible &&
                          result.response.decodedLength <= 1024 * 1024)
                        BusyApiPushButton.standard(
                          onPressed: () => _performRequestAction(
                            context,
                            run,
                            () => saveExample(context),
                          ),
                          child: Text(l.saveResponseExample),
                        ),
                    ],
                  ),
                  if (BusyApiCommandRegistryScope.maybeOf(context)
                          ?.configureShortcut !=
                      null)
                    BusyApiComboRow<String>(
                      title: l.requestSend,
                      selected: BusyApiCommandRegistryScope.maybeOf(
                        context,
                      )!['request-send']!.shortcut!.label,
                      values: {
                        BusyApiCommandRegistryScope.maybeOf(
                          context,
                        )!['request-send']!.shortcut!.label,
                        'Ctrl+Enter',
                        'Ctrl+Shift+Enter',
                        'Alt+Enter',
                      }.toList(),
                      labelFor: (v) => v,
                      enabled: !run.busy && !run.hasComposingInput,
                      onSelected: (value) => _performRequestAction(
                        context,
                        run,
                        () =>
                            BusyApiCommandRegistryScope.maybeOf(context)!
                                .configureShortcut!(
                              'request-send',
                              BusyApiKeyBinding(
                                LogicalKeyboardKey.enter,
                                control: value.startsWith('Ctrl'),
                                shift: value.contains('Shift'),
                                alt: value.startsWith('Alt'),
                              ),
                            ),
                      ),
                    ),
                  BusyApiDisclosure(
                    title: Text(l.requestTimeouts),
                    children: [
                      BusyApiStatusBox(message: l.requestTimeoutHelp),
                      for (final entry
                          in <
                            (
                              RequestTimeoutKind,
                              String,
                              Duration,
                              void Function(Duration),
                            )
                          >[
                            (
                              RequestTimeoutKind.connect,
                              l.requestConnectSeconds,
                              run.connectTimeout,
                              (d) => run.connectTimeout = d,
                            ),
                            (
                              RequestTimeoutKind.overall,
                              l.requestOverallSeconds,
                              run.overallTimeout,
                              (d) => run.overallTimeout = d,
                            ),
                            (
                              RequestTimeoutKind.inactivity,
                              l.requestInactivitySeconds,
                              run.inactivityTimeout,
                              (d) => run.inactivityTimeout = d,
                            ),
                          ])
                        RequestDraftEntry(
                          run: run,
                          label: entry.$2,
                          value:
                              run.timeoutInputs[entry.$1] ??
                              '${entry.$3.inMilliseconds / 1000}',
                          enabled: !run.busy,
                          onChanged: (text) {
                            run.timeoutInputs[entry.$1] = text;
                            final seconds = double.tryParse(text);
                            entry.$4(
                              seconds != null &&
                                      seconds.isFinite &&
                                      seconds > 0 &&
                                      seconds <= 600
                                  ? Duration(
                                      milliseconds: (seconds * 1000).round(),
                                    )
                                  : Duration.zero,
                            );
                          },
                        ),
                      BusyApiActionRow(
                        title: l.requestResetTimeouts,
                        enabled: !run.busy && !run.hasComposingInput,
                        onTap: () {
                          run.timeoutInputs.clear();
                          run.connectTimeout = run.inactivityTimeout =
                              const Duration(seconds: 15);
                          run.overallTimeout = const Duration(seconds: 60);
                          run.refresh();
                        },
                      ),
                    ],
                  ),
                  BusyApiDisclosure(
                    title: Text(l.requestCapabilities),
                    children: [SelectableText(l.requestCapabilitiesHelp)],
                  ),
                  if (run.history.isNotEmpty)
                    BusyApiDisclosure(
                      title: Text(l.requestHistory),
                      children: [
                        for (final record in run.history.reversed)
                          BusyApiActionRow(
                            title:
                                '${record.recordedAt.toLocal()} · ${record.method} ${record.operationPath}',
                            subtitle:
                                '${record.environment ?? l.requestDefaultEnvironment} · HTTP ${record.status} · ${record.elapsedMilliseconds} ms · ${record.responseBytes} B · ${record.receiptComplete ? l.responseReceiptComplete : l.responseReceiptPartial} · ${record.conformanceComplete
                                    ? record.conforming
                                          ? l.responseConforming
                                          : l.responseNonconforming
                                    : l.responseCoverageIncomplete}',
                          ),
                      ],
                    ),
                  if (run.history.isNotEmpty)
                    Wrap(
                      spacing: BusyApiSpacing.sm,
                      children: [
                        Text(l.requestHistoryCount(run.history.length)),
                        BusyApiPushButton.standard(
                          onPressed: () => _performRequestAction(
                            context,
                            run,
                            () => exportHistory(context),
                          ),
                          child: Text(l.requestHistoryExport),
                        ),
                        BusyApiPushButton.standard(
                          onPressed: run.clearHistory,
                          child: Text(l.requestHistoryClear),
                        ),
                      ],
                    ),
                ],
              ),
      );
    },
  );

  static Widget _choice<T>({
    required String label,
    required T value,
    required List<T> values,
    required String Function(T) text,
    String Function(T)? unavailableText,
    required ValueChanged<T?>? onChanged,
  }) => BusyApiComboRow<({T value})>(
    title: label,
    // A nullable authored choice must stay distinct from menu dismissal.
    selected: (value: value),
    values: [
      if (!values.contains(value)) (value: value),
      for (final option in values) (value: option),
    ],
    labelFor: (option) => values.contains(option.value)
        ? text(option.value)
        : (unavailableText ?? text)(option.value),
    enabledFor: (option) => values.contains(option.value),
    enabled: onChanged != null,
    onSelected: (option) => onChanged?.call(option.value),
  );

  static bool _isTokenReference(RequestRunController run, String reference) {
    final schemes = run
        .plan!
        .configuration
        .environments[run.environment]
        ?.authentication['schemes'];
    return schemes is Map &&
        schemes.values.whereType<Map>().any(
          (scheme) =>
              scheme['tokenRef'] == reference ||
              scheme['accessTokenRef'] == reference,
        );
  }

  static String _secretRole(
    RequestRunController run,
    String reference,
    BuildContext context,
  ) {
    final l = context.l10n,
        selected = run.plan!.configuration.environments[run.environment];
    if (selected?.tls['clientKeyPasswordRef'] == reference) {
      return '${l.secretTlsPassword} · ${run.environment}';
    }
    final configured = selected?.authentication['schemes'];
    if (configured is Map) {
      for (final scheme in configured.entries) {
        if (scheme.value is! Map) continue;
        for (final entry in (scheme.value as Map).entries) {
          if (entry.value == reference) {
            final role = switch (entry.key) {
              'secretRef' => l.secretApiKey,
              'passwordRef' => l.secretBasicPassword,
              'clientSecretRef' => l.secretOAuthClient,
              'accessTokenRef' => l.secretOAuthToken,
              _ => l.secretBearer,
            };
            return '$role · ${scheme.key} · ${run.environment}';
          }
        }
      }
    }
    return l.authentication;
  }

  static Map<String, Set<CredentialValuePolicy>> _secretPolicies(
    RequestRunController run,
  ) {
    final plan = run.plan!, alternative = run.securityAlternative;
    if (run.environment == null) return const {};
    final effectiveTls = ContractRequestBuilder.effectiveTls(
      plan.configuration.environments[run.environment],
      run.tlsFiles,
    );
    final tlsPassword = effectiveTls['clientKeyFile'] == null
        ? null
        : effectiveTls['clientKeyPasswordRef'];
    if (alternative != null &&
        (alternative < 0 ||
            alternative >=
                (plan.result['security']['requirements'] as List).length)) {
      return tlsPassword is String
          ? {
              tlsPassword: {CredentialValuePolicy.opaque},
            }
          : const {};
    }
    final environment = plan.configuration.environments[run.environment];
    final configured = environment?.authentication['schemes'];
    final requirement = alternative == null
        ? const {'schemes': <String>[]}
        : (plan.result['security']['requirements'] as List)[alternative] as Map;
    final output = <String, Set<CredentialValuePolicy>>{};
    if (configured is Map) {
      for (final name in (requirement['schemes'] as List).whereType<String>()) {
        final scheme = configured[name];
        if (scheme is! Map) continue;
        for (final entry in scheme.entries) {
          if (entry.key == 'clientSecretRef' &&
              scheme['clientAuthentication'] == 'none') {
            continue;
          }
          if (entry.key.toString().toLowerCase().endsWith('ref') &&
              entry.value is String) {
            output
                .putIfAbsent(entry.value as String, () => {})
                .add(
                  CredentialValuePolicy.forReferenceField(entry.key.toString()),
                );
          }
        }
      }
    }
    if (tlsPassword is String) {
      output
          .putIfAbsent(tlsPassword, () => {})
          .add(CredentialValuePolicy.opaque);
    }
    return output;
  }

  static List<(String, bool, bool)> _oauthSchemes(RequestRunController run) {
    final plan = run.plan!, alternative = run.securityAlternative;
    if (alternative == null || run.environment == null) return const [];
    if (alternative < 0 ||
        alternative >=
            (plan.result['security']['requirements'] as List).length) {
      return const [];
    }
    final requirement =
        (plan.result['security']['requirements'] as List)[alternative] as Map;
    final declarations = plan.result['security']['schemes'] as Map;
    return [
      for (final name in (requirement['schemes'] as List).whereType<String>())
        if (declarations[name] is Map && declarations[name]['type'] == 'oauth2')
          (
            name,
            declarations[name]['flows'] is Map &&
                declarations[name]['flows']['authorizationCode'] is Map,
            declarations[name]['flows'] is Map &&
                declarations[name]['flows']['clientCredentials'] is Map,
          ),
    ];
  }
}

class _ParameterRow extends StatelessWidget {
  const _ParameterRow({required this.run, required this.parameter});
  final RequestRunController run;
  final Map parameter;
  @override
  Widget build(BuildContext context) {
    final key = OperationRequestDraft.parameterKey(
      parameter['in'] as String,
      parameter['name'] as String,
    );
    final l = context.l10n;
    return BusyApiGroupedList(
      description: parameter['description'] as String?,
      children: [
        BusyApiSwitchRow(
          title: l.requestIncludeParameter,
          subtitle:
              '${parameter['in']} · ${parameter['type'] ?? (parameter['content'] as List?)?.firstOrNull?['mediaType'] ?? l.requestStructuredValue} · ${parameter['required'] == true ? l.required : ''}',
          value:
              run.values.containsKey(key) && !run.omittedValues.contains(key),
          enabled: !run.busy && !run.hasComposingInput,
          onChanged: (included) {
            if (included) {
              run.values.putIfAbsent(key, () => '');
              run.omittedValues.remove(key);
            } else {
              run.omittedValues.add(key);
            }
            run.refresh();
          },
        ),
        RequestDraftEntry(
          run: run,
          key: ValueKey('${run.plan!.identity}/$key'),
          value: run.values[key] ?? '',
          label:
              '${parameter['name']} · ${parameter['in']}${parameter['required'] == true ? ' · ${l.required}' : ''}',
          enabled: !run.busy && !run.omittedValues.contains(key),
          onChanged: (value) {
            run.values[key] = value;
            run.exampleRepresentations.remove(key);
          },
        ),
        BusyApiSwitchRow(
          title: l.requestStructuredValue,
          value: run.structuredValues.contains(key),
          enabled: !run.busy,
          onChanged: (value) {
            run.exampleRepresentations.remove(key);
            if (value) {
              run.structuredValues.add(key);
            } else {
              run.structuredValues.remove(key);
            }
            run.refresh();
          },
        ),
        for (final example in <Map>[
          if (parameter['examples'] is List)
            ...(parameter['examples'] as List).whereType<Map>()
          else if (parameter['example'] is Map)
            parameter['example'] as Map,
          if (parameter['content'] is List)
            for (final media in (parameter['content'] as List).whereType<Map>())
              if (media['examples'] is List)
                ...(media['examples'] as List).whereType<Map>()
              else if (media['example'] is Map)
                media['example'] as Map,
        ])
          BusyApiActionRow(
            title:
                '${l.examples} · ${example['name'] ?? parameter['name']} · ${example['representation']}',
            enabled: !run.busy && !run.hasComposingInput,
            onTap: run.busy || run.hasComposingInput
                ? null
                : () => run.useExample({...parameter, 'example': example}),
          ),
      ],
    );
  }
}

class _BodyEditor extends StatelessWidget {
  const _BodyEditor({required this.run});
  final RequestRunController run;
  @override
  Widget build(BuildContext context) {
    final body = run.plan!.result['requestBody'];
    final content = body is Map && body['content'] is List
        ? (body['content'] as List).whereType<Map>().toList()
        : const <Map>[];
    final mediaType = run.bodyMediaType;
    final unavailable = mediaType != null && !run.hasDeclaredBodyMediaType;
    final selectedMedia = mediaType?.split(';').first.trim().toLowerCase();
    final form = selectedMedia == 'application/x-www-form-urlencoded';
    final multipart = selectedMedia == 'multipart/form-data';
    final l = context.l10n;
    return BusyApiGroupedList(
      title: l.requestBodyMedia,
      children: [
        BusyApiSwitchRow(
          title: l.requestIncludeBody,
          subtitle: l.requestBodyPresence,
          value: run.bodyEnabled,
          enabled: !run.busy && !run.hasComposingInput,
          onChanged: (value) {
            run.bodyEnabled = value;
            run.refresh();
          },
        ),
        BusyApiComboRow<String?>(
          title: l.requestBodyMedia,
          values: {
            mediaType,
            ...content.map((m) => m['mediaType'] as String),
          }.toList(),
          selected: mediaType,
          labelFor: (value) => value == null
              ? l.requestBodyMediaChoose
              : unavailable && value == mediaType
              ? l.requestBodyMediaUnavailable(value)
              : value,
          errorText: run.bodyMediaNeedsSelection
              ? l.requestBodyMediaChoose
              : null,
          enabled: !run.busy && !run.hasComposingInput,
          enabledFor: (value) => !(unavailable && value == mediaType),
          onSelected: (value) {
            if (unavailable && value == mediaType) return;
            run.selectBodyMedia(value);
          },
        ),
        if (run.bodyEnabled) ...[
          if (run.bodyStructured ||
              selectedMedia == 'application/json' ||
              selectedMedia?.endsWith('+json') == true)
            BusyApiActionRow(
              title: l.requestFormatJson,
              enabled: !run.busy && !run.hasComposingInput,
              onTap: () => _performRequestAction(context, run, () async {
                final captured = run.plan, text = run.bodyText;
                final formatted = await captured!.inspectJson(text);
                if (identical(captured, run.plan) &&
                    run.bodyText == text &&
                    !run.hasComposingInput) {
                  run.bodyText = formatted['pretty'] as String;
                  run.refresh();
                }
              }),
            ),
          BusyApiActionRow(
            title: l.requestBodySource,
            subtitle: run.bodyStructured
                ? l.requestStructuredValue
                : switch (run.bodyKind) {
                    RequestBodyKind.none => l.requestBodyMediaChoose,
                    RequestBodyKind.raw => l.requestUseText,
                    RequestBodyKind.form => l.requestLiteralFields,
                    RequestBodyKind.multipart => l.requestPartEncoding,
                    RequestBodyKind.binaryFile => l.requestUseBinary,
                  },
          ),
          if ((form || multipart) && run.bodyKind != RequestBodyKind.raw)
            BusyApiSwitchRow(
              title: l.requestStructuredValue,
              value: run.bodyStructured,
              enabled: !run.busy && !run.hasComposingInput,
              onChanged: (value) {
                run.bodyStructured = value;
                run.refresh();
              },
            ),
          if (run.bodyKind == RequestBodyKind.binaryFile)
            BusyApiActionRow(
              title: l.requestUseText,
              enabled: !run.busy && !run.hasComposingInput,
              onTap: run.clearBodyFiles,
            ),
          if (run.bodyKind != RequestBodyKind.binaryFile)
            RequestDraftEntry(
              run: run,
              key: ValueKey('${run.plan!.identity}/${run.bodyMediaType}'),
              value: run.bodyText,
              multiline: true,
              enabled: !run.busy,
              label: run.bodyStructured
                  ? l.requestStructuredValue
                  : (form || multipart) && run.bodyKind != RequestBodyKind.raw
                  ? l.requestLiteralFields
                  : l.requestExactBody,
              onChanged: (value) => run.bodyText = value,
            ),
          if ((form || multipart) && run.bodyKind != RequestBodyKind.raw)
            BusyApiDisclosure(
              title: Text(l.requestPartEncoding),
              children: [
                BusyApiStatusBox(message: l.requestPartEncodingHelp),
                RequestPartMediaEditor(run: run),
              ],
            ),
          if (!form) ...[
            if (multipart)
              RequestDraftEntry(
                run: run,
                label: l.requestMultipartName,
                value: run.bodyFilePart,
                enabled: !run.busy,
                onChanged: (value) => run.bodyFilePart = value,
              ),
            BusyApiActionRow(
              title: multipart ? l.requestAddBinary : l.requestUseBinary,
              enabled: !run.busy && !run.hasComposingInput,
              leading: const Icon(BusyApiGlyphs.documentOpen),
              onTap: run.busy
                  ? null
                  : () => _performRequestAction(context, run, () async {
                      final captured = run.plan,
                          epoch = run._epoch,
                          revision = run._draftRevision,
                          environment = run.environment;
                      final selected = await openFile();
                      if (selected != null &&
                          !run._disposed &&
                          identical(captured, run.plan) &&
                          epoch == run._epoch &&
                          revision == run._draftRevision &&
                          environment == run.environment) {
                        run.addBodyFile(selected);
                      }
                    }),
            ),
            for (final file in run.bodyFiles)
              BusyApiActionRow(
                title: file.name,
                subtitle: file.filename ?? file.path,
                trailing: BusyApiCompactIconButton(
                  tooltip: l.requestRemove,
                  icon: BusyApiGlyphs.delete,
                  onPressed: run.busy || run.hasComposingInput
                      ? null
                      : () {
                          run.bodyFiles.remove(file);
                          if (run.bodyFiles.isEmpty) {
                            run.bodyKind = RequestRunController._kindForMedia(
                              run.bodyMediaType,
                            );
                          }
                          run.refresh();
                        },
                ),
              ),
            if (run.bodyFiles.isNotEmpty)
              BusyApiActionRow(
                title: l.requestClearFiles,
                enabled: !run.busy,
                onTap: run.busy ? null : run.clearBodyFiles,
              ),
          ],
        ],
        for (final media in content)
          for (final example
              in (media['examples'] as List? ??
                      [if (media['example'] is Map) media['example']])
                  .whereType<Map>())
            BusyApiActionRow(
              title:
                  '${l.examples} · ${media['mediaType']} · ${example['name'] ?? example['representation']}',
              enabled: !run.busy && !run.hasComposingInput,
              onTap: run.busy || run.hasComposingInput
                  ? null
                  : () => run.useBodyExample({...media, 'example': example}),
            ),
      ],
    );
  }
}

/// Native entry binding for controller-owned request drafts. An explicit
/// example can update its text; ordinary rebuilds retain selection and IME.
class RequestDraftEntry extends StatefulWidget {
  const RequestDraftEntry({
    super.key,
    required this.run,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.multiline = false,
  });
  final RequestRunController run;
  final String label, value;
  final ValueChanged<String> onChanged;
  final bool enabled;
  final bool multiline;
  @override
  State<RequestDraftEntry> createState() => _RequestDraftEntryState();
}

class _RequestDraftEntryState extends State<RequestDraftEntry> {
  late final controller = TextEditingController(text: widget.value);
  late String lastText = widget.value;
  bool composing = false, expandedComposing = false, syncing = false;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
  }

  void _changed() {
    if (syncing) return;
    _updateComposition();
    if (controller.text != lastText) {
      lastText = controller.text;
      widget.onChanged(lastText);
      widget.run.refresh();
    }
  }

  void _compositionChanged(bool value) {
    expandedComposing = value;
    _updateComposition();
  }

  void _updateComposition() {
    final range = controller.value.composing;
    final next = expandedComposing || range.isValid && !range.isCollapsed;
    if (next != composing) {
      composing = next;
      if (next) {
        widget.run._composingInputs.add(this);
      } else {
        widget.run._composingInputs.remove(this);
      }
      widget.run.refresh(draftChanged: false);
    }
  }

  @override
  void didUpdateWidget(RequestDraftEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != controller.text && !composing) {
      syncing = true;
      lastText = widget.value;
      final selection = controller.selection;
      controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection(
          baseOffset: selection.baseOffset.clamp(0, widget.value.length),
          extentOffset: selection.extentOffset.clamp(0, widget.value.length),
        ),
      );
      syncing = false;
    }
  }

  @override
  void dispose() {
    if (widget.run._composingInputs.remove(this)) {
      final run = widget.run;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => run.refresh(draftChanged: false),
      );
    }
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.multiline
      ? FormValueEditor(
          label: widget.label,
          controller: controller,
          enabled: widget.enabled,
          multiline: true,
          json: false,
          onCompositionChanged: _compositionChanged,
        )
      : BusyApiGroupedTextEntry(
          label: widget.label,
          controller: controller,
          enabled: widget.enabled,
        );
}

class RequestSecretInput extends StatefulWidget {
  const RequestSecretInput({
    super.key,
    required this.run,
    required this.reference,
    this.role,
    this.tokenCredential = false,
    this.valuePolicies = const [CredentialValuePolicy.opaque],
  });
  final bool tokenCredential;
  final List<CredentialValuePolicy> valuePolicies;
  final RequestRunController run;
  final String reference;
  final String? role;
  @override
  State<RequestSecretInput> createState() => _SecretInputRowState();
}

class _SecretInputRowState extends State<RequestSecretInput> {
  final controller = TextEditingController();
  bool busy = false;
  String? availabilityFailure;
  int _submission = 0, _revision = 0;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    widget.run.secrets
        .checkAvailability(widget.reference)
        .then(
          (_) {
            if (mounted) setState(() {});
          },
          onError: (Object error) {
            if (mounted) {
              setState(
                () => availabilityFailure = error is SecretStoreFailure
                    ? error.message
                    : 'Credential availability could not be checked.',
              );
            }
          },
        );
  }

  void _changed() {
    _revision++;
    if (controller.value.composing.isValid) {
      widget.run._composingInputs.add(this);
    } else {
      widget.run._composingInputs.remove(this);
    }
    if (controller.text.isEmpty) {
      widget.run._pendingSecretInputs.remove(this);
    } else {
      widget.run._pendingSecretInputs[this] = (
        widget.run.plan,
        widget.run.environment,
      );
    }
    widget.run._notify();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(RequestSecretInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.run, widget.run) ||
        oldWidget.reference != widget.reference) {
      _submission++;
      busy = false;
      controller.clear();
    }
  }

  @override
  void dispose() {
    widget.run._pendingSecretInputs.remove(this);
    widget.run._composingInputs.remove(this);
    _submission++;
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  Future<void> save(SecretPersistence persistence) async {
    if (busy || widget.run.busy || controller.value.composing.isValid) return;
    final run = widget.run, reference = widget.reference;
    final owner = run.owner, plan = run.plan, environment = run.environment;
    final epoch = run._epoch, revision = _revision, submission = ++_submission;
    final value = controller.text;
    final policies = List<CredentialValuePolicy>.unmodifiable(
      widget.valuePolicies,
    );
    setState(() => busy = true);
    try {
      if (policies.isEmpty ||
          !policies.every((policy) => policy.accepts(value))) {
        throw const SecretStoreFailure(
          'secret.value',
          'The credential does not satisfy the selected authentication policy',
        );
      }
      await run.writeSecret(
        reference,
        value,
        persistence,
        allowEmpty: policies.every((policy) => policy.allowsEmpty),
      );
      if (mounted &&
          submission == _submission &&
          revision == _revision &&
          identical(widget.run, run) &&
          widget.reference == reference &&
          identical(run.owner, owner) &&
          identical(run.plan, plan) &&
          run.environment == environment &&
          run._epoch == epoch) {
        controller.clear();
      }
    } on SecretStoreFailure catch (error) {
      if (mounted && submission == _submission) {
        BusyApiToastOverlay.show(
          context,
          message: error.code == 'secret.value'
              ? context.l10n.secretInvalid
              : error.message,
        );
      }
    } finally {
      if (mounted && submission == _submission) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.run.secrets.status(widget.reference);
    final metadata = widget.run.secrets.metadata(widget.reference);
    final validInput =
        widget.valuePolicies.isNotEmpty &&
        widget.valuePolicies.every((policy) => policy.accepts(controller.text));
    return BusyApiGroupedList(
      title: widget.role ?? context.l10n.authentication,
      description: widget.reference,
      children: [
        if (availabilityFailure != null)
          BusyApiStatusBox(
            message: availabilityFailure!,
            kind: BusyApiStatusKind.error,
          ),
        BusyApiStatusBox(
          message: switch (widget.run.secrets.availability(widget.reference)) {
            SecretAvailability.unknown => context.l10n.secretStatusUnknown,
            SecretAvailability.loading => context.l10n.checking,
            SecretAvailability.persistent =>
              context.l10n.secretStatusPersistent,
            SecretAvailability.session => context.l10n.secretStatusSession,
            SecretAvailability.missing => context.l10n.secretStatusMissing,
            SecretAvailability.locked => context.l10n.secretStatusLocked,
            SecretAvailability.unavailable => context.l10n.secretUnavailable,
          },
        ),
        if (metadata != null)
          BusyApiActionRow(
            title: metadata.expired
                ? context.l10n.secretExpired
                : metadata.expiresAt?.toLocal().toString() ??
                      context.l10n.secretExpiryUnknown,
            subtitle:
                '${context.l10n.requestGrantedScopes}: ${metadata.scopes.join(' ')}',
          ),
        if (metadata == null && widget.tokenCredential)
          BusyApiActionRow(
            title: context.l10n.secretExpiryUnknown,
            subtitle: context.l10n.requestGrantedScopesUnknown,
          ),
        if (status == SecretPersistence.sessionOnly)
          BusyApiActionRow(
            title: context.l10n.secretClearOverride,
            enabled: !busy,
            onTap: () async {
              await widget.run.secrets.clearOverride(widget.reference);
              if (mounted) setState(() {});
            },
          ),
        BusyApiActionRow(
          title: context.l10n.secretDeletePersistent,
          enabled: !busy,
          onTap: () => _performRequestAction(context, widget.run, () async {
            await widget.run.secrets.deletePersistent(widget.reference);
            if (mounted) setState(() {});
          }),
        ),
        if (controller.text.isNotEmpty)
          BusyApiStatusBox(
            message: validInput
                ? context.l10n.secretPending
                : context.l10n.secretInvalid,
            kind: validInput
                ? BusyApiStatusKind.information
                : BusyApiStatusKind.error,
          ),
        BusyApiGroupedTextEntry(
          controller: controller,
          label: context.l10n.secretValue,
          enabled: !widget.run.busy,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
        ),
        BusyApiActionRow(
          title: context.l10n.secretSession,
          enabled:
              !busy &&
              !widget.run.busy &&
              validInput &&
              !controller.value.composing.isValid,
          subtitle: status == SecretPersistence.sessionOnly
              ? context.l10n.secretStatusSession
              : null,
          onTap:
              busy ||
                  widget.run.busy ||
                  !validInput ||
                  controller.value.composing.isValid
              ? null
              : () => save(SecretPersistence.sessionOnly),
        ),
        BusyApiActionRow(
          title: context.l10n.secretPersistent,
          enabled:
              !busy &&
              !widget.run.busy &&
              validInput &&
              !controller.value.composing.isValid,
          subtitle: status == SecretPersistence.persistent
              ? context.l10n.secretStatusPersistent
              : null,
          onTap:
              busy ||
                  widget.run.busy ||
                  !validInput ||
                  controller.value.composing.isValid
              ? null
              : () => save(SecretPersistence.persistent),
        ),
      ],
    );
  }
}

class _ResponseInspector extends StatefulWidget {
  const _ResponseInspector({
    super.key,
    required this.result,
    required this.previous,
    required this.run,
  });
  final ContractRequestResult result;
  final RequestRunController run;
  final bool previous;
  @override
  State<_ResponseInspector> createState() => _ResponseInspectorState();
}

class _ResponseInspectorState extends State<_ResponseInspector> {
  final query = TextEditingController();
  final headerQuery = TextEditingController();
  String view = 'body', text = '', pretty = '';
  String? actionFailure;
  List<Map> entries = const [];
  bool binary = false, invalidText = false, formatted = false, folded = false;
  int page = 0, headerPage = 0;
  static const pageSize = 16384, headerPageSize = 25;
  @override
  void initState() {
    super.initState();
    query.addListener(_searchChanged);
    headerQuery.addListener(_headerSearchChanged);
    final response = widget.result.response;
    if (!widget.result.bodyPermitted) return;
    final contentType = response.headers
        .where((h) => h.$1.toLowerCase() == 'content-type')
        .map((h) => h.$2)
        .firstOrNull;
    try {
      final media = contentType == null ? null : ContentType.parse(contentType);
      final type = media?.mimeType ?? '';
      binary = !isInspectableTextMedia(contentType);
      final charset = media?.charset?.toLowerCase() ?? 'utf-8';
      if (!binary) {
        if (charset == 'utf-8' || charset == 'utf8') {
          final bytes = response.displayBytes;
          var end = bytes.length;
          // A preview boundary can divide the final Unicode scalar. This does
          // not turn a complete, valid response into malformed text.
          while (true) {
            try {
              text = utf8.decode(bytes.sublist(0, end));
              break;
            } on FormatException {
              if ((response.decodedLength > bytes.length ||
                      !response.receiptComplete) &&
                  bytes.length - end < 3) {
                end--;
                continue;
              }
              rethrow;
            }
          }
        } else if (charset == 'iso-8859-1' || charset == 'latin1') {
          text = latin1.decode(response.displayBytes);
        } else if (charset == 'us-ascii') {
          text = ascii.decode(response.displayBytes);
        } else {
          invalidText = true;
        }
      }
      if (binary) {
        text = response.displayBytes
            .take(1024)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
      }
      if (!binary &&
          !invalidText &&
          response.exampleEligible &&
          response.decodedLength == response.displayBytes.length &&
          (type == 'application/json' || type.endsWith('+json'))) {
        widget.result.request.plan
            .inspectJson(text)
            .then(
              (value) {
                if (!mounted) return;
                setState(() {
                  pretty = value['pretty'] as String;
                  entries = value['entriesComplete'] == true
                      ? (value['entries'] as List).cast<Map>()
                      : const [];
                });
              },
              onError: (Object _) {
                /* Raw content and validation remain available. */
              },
            );
      }
    } on Object {
      invalidText = true;
    }
  }

  Future<void> exportResponse({bool decoded = false}) async {
    final response = widget.result.response;
    try {
      final target = await getSaveLocation(
        suggestedName: decoded
            ? 'busyapi-decoded-response.bin'
            : 'busyapi-response.bin',
      );
      if (target == null ||
          !mounted ||
          !identical(response, widget.result.response)) {
        return;
      }
      await response.export(target.path, decoded: decoded);
      if (mounted) setState(() => actionFailure = null);
    } on CoreFailure catch (error) {
      if (mounted) {
        setState(() => actionFailure = '${error.message} (${error.code})');
      }
    } on AtomicFileAlreadyExistsException {
      if (mounted) {
        setState(() => actionFailure = context.l10n.responseExportExists);
      }
    } on Object {
      if (mounted) {
        setState(() => actionFailure = context.l10n.responseExportFailed);
      }
    }
  }

  void _searchChanged() {
    setState(() => page = 0);
  }

  void _headerSearchChanged() {
    setState(() => headerPage = 0);
  }

  @override
  void dispose() {
    query.dispose();
    headerQuery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, result = widget.result, response = result.response;
    final shown = formatted && pretty.isNotEmpty ? pretty : text;
    final needle = query.text.toLowerCase();
    final found = needle.isEmpty ? 0 : shown.toLowerCase().indexOf(needle);
    final filteredEntries = entries
        .where(
          (entry) => '${entry['name']} ${entry['text']}'.toLowerCase().contains(
            needle,
          ),
        )
        .toList();
    final origin = found < 0 ? 0 : found;
    final lastPage = folded
        ? (filteredEntries.length - 1).clamp(0, entries.length) ~/ 25
        : (shown.length - origin - 1).clamp(0, shown.length) ~/ pageSize;
    final currentPage = page.clamp(0, lastPage);
    final start = _scalarBoundary(shown, origin + currentPage * pageSize);
    final end = _scalarBoundary(shown, origin + (currentPage + 1) * pageSize);
    final headerNeedle = headerQuery.text.toLowerCase();
    final headers = response.headers
        .where((h) => '${h.$1}: ${h.$2}'.toLowerCase().contains(headerNeedle))
        .toList();
    final visibleHeaders = headers
        .skip(headerPage * headerPageSize)
        .take(headerPageSize);
    return BusyApiGroupedList(
      title: l.responses,
      children: [
        if (widget.previous) BusyApiStatusBox(message: l.requestPreviousResult),
        BusyApiActionRow(
          title: result.request.displayUri,
          titleWidget: SelectableText(result.request.displayUri),
        ),
        BusyApiActionRow(
          title: 'HTTP ${response.status} ${response.reason}',
          titleWidget: SelectableText(
            'HTTP ${response.status} ${response.reason}',
          ),
          subtitle:
              '${result.request.method} ${result.request.displayUri}\n${l.responseTiming(response.elapsed.inMilliseconds, response.bodyLength)} · ${l.requestReceiptBytes}: ${response.receivedLength} / ${response.bodyLength} · ${l.requestDecodedBytes}: ${response.decodedLength}',
          subtitleWidget: SelectableText(
            '${result.request.method} ${result.request.displayUri}\n${l.responseTiming(response.elapsed.inMilliseconds, response.bodyLength)} · ${l.requestReceiptBytes}: ${response.receivedLength} / ${response.bodyLength} · ${l.requestDecodedBytes}: ${response.decodedLength}',
          ),
        ),
        BusyApiStatusBox(
          message:
              '${response.receiptComplete ? l.responseReceiptComplete : l.responseReceiptPartial}${response.incompleteReason == null ? '' : ' · ${response.incompleteReason}'}\n${l.responseDecoding}: ${response.decodingComplete ? l.checkComplete : response.decodingReason}',
          kind: response.receiptComplete && response.decodingComplete
              ? BusyApiStatusKind.information
              : BusyApiStatusKind.warning,
        ),
        BusyApiStatusBox(
          message: result.conforming
              ? l.responseConforming
              : !result.outgoing.complete || !result.received.complete
              ? l.responseCoverageIncomplete
              : l.responseNonconforming,
          kind: result.conforming
              ? BusyApiStatusKind.success
              : BusyApiStatusKind.warning,
        ),
        for (final redirect in response.redirects)
          BusyApiActionRow(
            title: redirect,
            titleWidget: SelectableText(redirect),
          ),
        BusyApiComboRow<String>(
          title: l.responses,
          selected: view,
          values: const ['body', 'headers', 'validation'],
          labelFor: (value) => value == 'body'
              ? l.responseBody
              : value == 'headers'
              ? '${l.requestHeaders} (${response.headers.length})'
              : l.responseValidation,
          onSelected: (value) => setState(() => view = value),
        ),
        if (actionFailure != null)
          Semantics(liveRegion: true, child: SelectableText(actionFailure!)),
        BusyApiActionRow(
          title: response.receiptComplete
              ? l.responseOriginalExport
              : l.responsePartialExport,
          onTap: () => exportResponse(),
        ),
        if (response.decodingComplete)
          BusyApiActionRow(
            title: response.receiptComplete
                ? l.responseDecodedExport
                : l.responsePartialDecodedExport,
            onTap: () => exportResponse(decoded: true),
          ),
        if (view == 'body') ...[
          if (binary) BusyApiStatusBox(message: l.responseBinary),
          if (invalidText)
            BusyApiStatusBox(
              message: l.responseInvalidCharset,
              kind: BusyApiStatusKind.warning,
            ),
          BusyApiGroupedTextEntry(label: l.responseSearch, controller: query),
          BusyApiStatusBox(
            message:
                '${l.responseSearchScope}${(folded ? filteredEntries.isEmpty : found < 0) ? ' · ${l.responseNoMatch}' : ''}',
          ),
          Wrap(
            spacing: BusyApiSpacing.sm,
            children: [
              BusyApiPushButton.standard(
                onPressed: () => Clipboard.setData(ClipboardData(text: shown)),
                child: Text(l.responseCopyPreview),
              ),
              if (pretty.isNotEmpty)
                BusyApiPushButton.standard(
                  onPressed: () => setState(() {
                    formatted = !formatted;
                    folded = false;
                    page = 0;
                  }),
                  child: Text(formatted ? l.responseRaw : l.responsePretty),
                ),
              if (pretty.isNotEmpty && entries.isNotEmpty)
                BusyApiPushButton.standard(
                  onPressed: () => setState(() {
                    folded = !folded;
                    page = 0;
                  }),
                  child: Text(folded ? l.responseUnfold : l.responseFold),
                ),
            ],
          ),
          if (folded) ...[
            for (final entry in filteredEntries.skip(currentPage * 25).take(25))
              BusyApiDisclosure(
                title: Text(entry['name'] as String),
                children: [
                  SelectableText(_inspectionText(entry['text'], pageSize)),
                ],
              ),
          ] else
            BusyApiRawSourceView(source: shown.substring(start, end)),
          Wrap(
            children: [
              BusyApiPushButton.standard(
                onPressed: currentPage == 0
                    ? null
                    : () => setState(() => page = currentPage - 1),
                child: Text(l.responsePrevious),
              ),
              Text(
                folded
                    ? '${filteredEntries.isEmpty ? 0 : currentPage * 25 + 1} / ${filteredEntries.length}'
                    : '$start–$end / ${shown.length}',
              ),
              BusyApiPushButton.standard(
                onPressed: currentPage >= lastPage
                    ? null
                    : () => setState(() => page = currentPage + 1),
                child: Text(l.responseNext),
              ),
            ],
          ),
          if (response.decodedLength > response.displayBytes.length)
            BusyApiStatusBox(message: l.responseDisplayBound),
        ],
        if (view == 'headers') ...[
          BusyApiGroupedTextEntry(
            label: l.responseHeadersSearch,
            controller: headerQuery,
          ),
          BusyApiActionRow(
            title: '${headers.length} / ${response.headers.length}',
            subtitle: l.requestHeaders,
          ),
          BusyApiActionRow(
            title: l.responseCopyHeaders,
            onTap: () => Clipboard.setData(
              ClipboardData(
                text: headers.map((h) => '${h.$1}: ${h.$2}').join('\r\n'),
              ),
            ),
          ),
          for (final header in visibleHeaders)
            BusyApiActionRow(
              title: header.$1,
              subtitle: header.$2,
              titleWidget: SelectableText(header.$1),
              subtitleWidget: SelectableText(header.$2),
            ),
          Wrap(
            children: [
              BusyApiPushButton.standard(
                onPressed: headerPage == 0
                    ? null
                    : () => setState(() => headerPage--),
                child: Text(l.responsePrevious),
              ),
              Text('${headerPage * headerPageSize} / ${headers.length}'),
              BusyApiPushButton.standard(
                onPressed: (headerPage + 1) * headerPageSize >= headers.length
                    ? null
                    : () => setState(() => headerPage++),
                child: Text(l.responseNext),
              ),
            ],
          ),
        ],
        if (view == 'validation')
          for (final group in [
            (l.responseOutgoing, result.outgoing),
            (l.responseReceived, result.received),
          ]) ...[
            SectionLabel(group.$1),
            BusyApiStatusBox(
              message:
                  '${group.$2.complete ? l.checkComplete : l.incomplete} · ${!group.$2.complete
                      ? l.responseCoverageIncomplete
                      : group.$2.valid
                      ? l.responseConforming
                      : l.responseNonconforming}',
            ),
            SelectableText(
              group.$2.coverage.entries
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
            ),
            for (final finding in group.$2.findings)
              _ValidationFinding(
                finding: finding,
                plan: result.request.plan,
                run: widget.run,
              ),
          ],
      ],
    );
  }
}

// Page boundaries are UTF-16 offsets, adjusted to keep each Unicode scalar intact.
int _scalarBoundary(String text, int offset) {
  final end = offset.clamp(0, text.length);
  if (end > 0 &&
      end < text.length &&
      text.codeUnitAt(end) >= 0xdc00 &&
      text.codeUnitAt(end) <= 0xdfff &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff) {
    return end - 1;
  }
  return end;
}

String _inspectionText(Object? value, [int maximum = 4096]) {
  final text = value?.toString() ?? '';
  return text.length <= maximum
      ? text
      : '${text.substring(0, _scalarBoundary(text, maximum))}…';
}

class _ValidationFinding extends StatelessWidget {
  const _ValidationFinding({
    required this.finding,
    required this.plan,
    required this.run,
  });
  final Map<String, Object?> finding;
  final OperationRequestPlan plan;
  final RequestRunController run;
  @override
  Widget build(BuildContext context) {
    final schema = finding['schema'];
    final resource = schema is Map ? schema['resource'] : null;
    final pointer = schema is Map ? schema['pointer'] : null;
    final range = schema is Map ? schema['range'] : null;
    bool canNavigate() =>
        !plan.outdated &&
        !plan.closed &&
        identical(run.owner, run.workspace.project) &&
        plan.snapshot.root == run.workspace.root &&
        resource is String &&
        pointer is String &&
        range is List &&
        range.length == 2 &&
        range.every((v) => v is int && v >= 0) &&
        range[0] <= range[1] &&
        plan.snapshot.resources.any(
          (source) =>
              source['id'] == resource &&
              source['text'] is String &&
              range[1] <= (source['text'] as String).length,
        );
    final detail = [
      _inspectionText(finding['message']),
      if (finding['subject'] != null || finding['location'] != null)
        '${_inspectionText(finding['subject'], 1024)} · ${_inspectionText(finding['location'])}',
      if (finding.containsKey('pointer'))
        '${context.l10n.validationValuePath}: ${_inspectionText(finding['pointer'])}',
      if (finding['keyword'] != null)
        '${context.l10n.validationKeyword}: ${_inspectionText(finding['keyword'])}',
      if (schema is Map)
        '${context.l10n.validationSchema}: ${_inspectionText(resource)}#${_inspectionText(pointer)}',
    ].join('\n');
    return BusyApiActionRow(
      title: '${finding['severity']} · ${finding['code']}',
      titleWidget: SelectableText(
        _inspectionText('${finding['severity']} · ${finding['code']}'),
      ),
      subtitle: detail,
      subtitleWidget: SelectableText(detail),
      onTap: !canNavigate()
          ? null
          : () => _performRequestAction(context, run, () async {
              if (!canNavigate()) return;
              run.workspace.setMode('Source');
              await run.workspace.selectObject({
                'root': plan.snapshot.root,
                'resource': resource,
                'pointer': pointer,
                'range': range,
              });
            }),
    );
  }
}

class _SetupEntry extends StatefulWidget {
  const _SetupEntry({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onComposition,
    this.multiline = false,
  });
  final String label, value;
  final ValueChanged<String> onChanged;
  final ValueChanged<bool> onComposition;
  final bool multiline;
  @override
  State<_SetupEntry> createState() => _SetupEntryState();
}

class _SetupEntryState extends State<_SetupEntry> {
  late final controller = TextEditingController(text: widget.value);
  bool composing = false;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
  }

  void _changed() {
    widget.onChanged(controller.text);
    final active = controller.value.composing.isValid;
    if (active != composing) {
      composing = active;
      widget.onComposition(active);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.multiline
      ? FormValueEditor(
          label: widget.label,
          controller: controller,
          enabled: true,
          multiline: true,
          json: false,
          onCompositionChanged: widget.onComposition,
        )
      : BusyApiGroupedTextEntry(label: widget.label, controller: controller);
}
