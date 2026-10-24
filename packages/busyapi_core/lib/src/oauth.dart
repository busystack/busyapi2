import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'model.dart';
import 'project.dart';
import 'request.dart';

typedef ExternalBrowserLauncher = Future<void> Function(Uri authorizationUri);

class OAuthToken {
  const OAuthToken({
    required this.accessToken,
    required this.tokenType,
    required this.owner,
    required this.environment,
    this.refreshToken,
    this.expiresAt,
    this.scope = const [],
  });
  final String accessToken, tokenType, owner, environment;
  final String? refreshToken;
  final DateTime? expiresAt;
  final List<String> scope;
  bool get expired =>
      expiresAt != null && !DateTime.now().toUtc().isBefore(expiresAt!);
}

class OAuthClient {
  const OAuthClient({
    this.timeout = const Duration(minutes: 3),
    this.maximumTokenResponseBytes = 1024 * 1024,
    this.tokenExchangeTimeout = const Duration(seconds: 60),
    this.bindCallbackReceiver,
  });
  final Duration timeout, tokenExchangeTimeout;
  final int maximumTokenResponseBytes;
  final Future<HttpServer> Function()? bindCallbackReceiver;

  Future<OAuthToken> authorizationCode(
    OperationRequestPlan plan, {
    required String environment,
    required String scheme,
    required ExternalBrowserLauncher launchBrowser,
    required RunCancellation cancellation,
    List<String> scopes = const [],
    OperationRequestDraft? draft,
    SecretResolver? resolveSecret,
  }) async {
    final selected = _configuration(plan, environment, scheme);
    final declaration = selected.$1, configuration = selected.$2;
    final flows = declaration['flows'];
    final flow = flows is Map ? flows['authorizationCode'] : null;
    if (flow is! Map) {
      throw CoreFailure(
        'oauth.flow',
        'The selected scheme has no authorization-code flow',
      );
    }
    final clientId = _clientId(configuration);
    final authorization = _endpoint(
      flow['authorizationUrl'],
      () => _base(plan, environment, draft),
      'authorization',
    );
    final token = _endpoint(
      flow['tokenUrl'],
      () => _base(plan, environment, draft),
      'token',
    );
    final requestedScopes = _scopes(
      plan,
      draft,
      scheme,
      configuration,
      scopes,
      environment,
    );
    final receiver =
        await (bindCallbackReceiver?.call() ??
            HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false));
    try {
      const callbackPath = '/oauth/callback';
      final redirect = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: receiver.port,
        path: callbackPath,
      );
      final state = _random(32), verifier = _random(64);
      final challenge = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');
      final authorizationUri = authorization.replace(
        queryParameters: {
          ...authorization.queryParameters,
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirect.toString(),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          if (requestedScopes.isNotEmpty) 'scope': requestedScopes.join(' '),
        },
      );
      _current(plan);
      cancellation.throwIfCancelled();
      await launchBrowser(authorizationUri);
      final callback = await _awaitCallback(
        receiver,
        callbackPath,
        state,
        cancellation,
      );
      cancellation.throwIfCancelled();
      return await _exchange(
        plan,
        environment,
        token,
        {
          'grant_type': 'authorization_code',
          'code': callback,
          'redirect_uri': redirect.toString(),
          'client_id': clientId,
          'code_verifier': verifier,
        },
        configuration,
        resolveSecret,
        cancellation,
        defaultAuthentication: 'none',
        requestedScopes: requestedScopes,
      );
    } finally {
      await receiver.close(force: true);
    }
  }

  Future<OAuthToken> clientCredentials(
    OperationRequestPlan plan, {
    required String environment,
    required String scheme,
    required SecretResolver resolveSecret,
    required RunCancellation cancellation,
    List<String> scopes = const [],
    OperationRequestDraft? draft,
  }) async {
    final selected = _configuration(plan, environment, scheme);
    final declaration = selected.$1, configuration = selected.$2;
    final flows = declaration['flows'];
    final flow = flows is Map ? flows['clientCredentials'] : null;
    if (flow is! Map) {
      throw CoreFailure(
        'oauth.flow',
        'The selected scheme has no client-credentials flow',
      );
    }
    final token = _endpoint(
      flow['tokenUrl'],
      () => _base(plan, environment, draft),
      'token',
    );
    final selectedScopes = _scopes(
      plan,
      draft,
      scheme,
      configuration,
      scopes,
      environment,
    );
    return _exchange(
      plan,
      environment,
      token,
      {
        'grant_type': 'client_credentials',
        if (selectedScopes.isNotEmpty) 'scope': selectedScopes.join(' '),
      },
      configuration,
      resolveSecret,
      cancellation,
      defaultAuthentication: 'basic',
      requestedScopes: selectedScopes,
    );
  }

  static List<String> _scopes(
    OperationRequestPlan plan,
    OperationRequestDraft? draft,
    String scheme,
    Map configuration,
    List<String> chosen,
    String environment,
  ) {
    final raw = configuration['scopes'];
    if (raw != null &&
        (raw is! List ||
            raw.any(
              (s) =>
                  s is! String ||
                  s.isEmpty ||
                  RegExp(r'[\x00-\x20\x7f]').hasMatch(s),
            ))) {
      throw CoreFailure(
        'oauth.scopes',
        'Configure a list of individual OAuth scope strings.',
      );
    }
    final requested = chosen.isNotEmpty
        ? List<String>.of(chosen)
        : (raw as List? ?? const []).cast<String>();
    final alternatives = plan.result['security']['requirements'] as List;
    var index = draft?.securityAlternative;
    final configuredAlternative = plan
        .configuration
        .environments[environment]
        ?.authentication['alternative'];
    if (index == null && configuredAlternative is int) {
      index = configuredAlternative;
    }
    if (index == null) {
      final matches = [
        for (var i = 0; i < alternatives.length; i++)
          if ((alternatives[i]['schemes'] as List).contains(scheme)) i,
      ];
      if (matches.length == 1) {
        index = matches.single;
      } else {
        throw CoreFailure(
          'oauth.scopes.selection',
          'Select the operation security alternative before authorization.',
        );
      }
    }
    if (index < 0 ||
        index >= alternatives.length ||
        !(alternatives[index]['schemes'] as List).contains(scheme)) {
      throw CoreFailure(
        'oauth.scopes.selection',
        'Choose a current security alternative that includes this OAuth scheme.',
      );
    }
    final scopes = alternatives[index]['scopes'];
    final required = scopes is Map && scopes[scheme] is List
        ? (scopes[scheme] as List).cast<String>()
        : const <String>[];
    if (!requested.toSet().containsAll(required)) {
      throw CoreFailure(
        'oauth.scopes.required',
        'The configured scope request does not include this operation’s required scopes. Review authentication setup before authorizing.',
      );
    }
    return List.unmodifiable(requested);
  }

  (Map<String, dynamic>, Map<String, dynamic>) _configuration(
    OperationRequestPlan plan,
    String environment,
    String scheme,
  ) {
    _current(plan);
    final selected = plan.configuration.environments[environment];
    if (selected == null) {
      throw CoreFailure('environment.missing', 'OAuth environment is absent');
    }
    final declarations = plan.result['security'];
    final schemes = declarations is Map ? declarations['schemes'] : null;
    final declaration = schemes is Map ? schemes[scheme] : null;
    final configured = selected.authentication['schemes'];
    final configuration = configured is Map ? configured[scheme] : null;
    if (declaration is! Map ||
        declaration['type'] != 'oauth2' ||
        configuration is! Map) {
      throw CoreFailure(
        'oauth.configuration',
        'Configure the selected OAuth scheme in this environment',
      );
    }
    return (
      Map<String, dynamic>.from(declaration),
      Map<String, dynamic>.from(configuration),
    );
  }

  static void _current(OperationRequestPlan plan) {
    plan.ensureCurrentOwner();
    if (plan.outdated) {
      throw CoreFailure(
        'request.draft.stale',
        'Reconcile the changed request before authorization',
      );
    }
  }

  static String _base(
    OperationRequestPlan plan,
    String environment,
    OperationRequestDraft? draft,
  ) {
    if (draft != null && draft.environment != environment) {
      throw CoreFailure(
        'oauth.configuration',
        'OAuth must use the selected request environment',
      );
    }
    return const ContractRequestBuilder()
        .serverBase(
          plan,
          draft ??
              OperationRequestDraft(
                planIdentity: plan.identity,
                environment: environment,
              ),
        )
        .toString();
  }

  static String _clientId(Map<String, dynamic> configuration) {
    final value = configuration['clientId'];
    if (value is! String ||
        value.isEmpty ||
        value.length > 4096 ||
        value.contains('\u0000')) {
      throw CoreFailure('oauth.client', 'OAuth requires a bounded clientId');
    }
    return value;
  }

  static Uri _endpoint(Object? value, String Function() base, String name) {
    if (value is! String || value.isEmpty || value.length > 16384) {
      throw CoreFailure('oauth.endpoint', 'OAuth $name endpoint is absent');
    }
    Uri? endpoint = Uri.tryParse(value);
    if (endpoint != null && !endpoint.isAbsolute) {
      endpoint = Uri.parse(base()).resolveUri(endpoint);
    }
    if (endpoint == null ||
        !endpoint.isAbsolute ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.fragment.isNotEmpty ||
        !(endpoint.scheme == 'https' ||
            endpoint.scheme == 'http' && _loopback(endpoint.host))) {
      throw CoreFailure(
        'oauth.endpoint',
        'OAuth $name endpoint must be HTTPS or controlled loopback HTTP',
      );
    }
    return endpoint;
  }

  Future<String> _awaitCallback(
    HttpServer receiver,
    String path,
    String state,
    RunCancellation cancellation,
  ) async {
    final result = Completer<String>();
    late StreamSubscription<HttpRequest> subscription;
    subscription = receiver.listen((request) async {
      if (request.uri.path != path || request.method != 'GET') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final actualState = request.uri.queryParameters['state'];
      final code = request.uri.queryParameters['code'];
      final error = request.uri.queryParameters['error'];
      if (actualState != state) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('OAuth callback state did not match.');
        await request.response.close();
        return;
      }
      if (error != null ||
          code == null ||
          code.isEmpty ||
          code.length > 16384) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('OAuth authorization was not completed.');
        await request.response.close();
        if (!result.isCompleted) {
          result.completeError(
            CoreFailure('oauth.authorization', 'OAuth authorization failed'),
          );
        }
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!doctype html><meta charset="utf-8"><title>BusyAPI</title><p>Authorization received. Return to BusyAPI.</p>',
      );
      await request.response.close();
      if (!result.isCompleted) result.complete(code);
    });
    try {
      return await Future.any<String>([
        result.future,
        cancellation.whenCancelled.then<String>((_) {
          throw CoreFailure('cancelled', 'OAuth authorization was cancelled');
        }),
      ]).timeout(timeout);
    } on TimeoutException {
      throw CoreFailure('oauth.timeout', 'OAuth authorization timed out');
    } finally {
      await subscription.cancel();
    }
  }

  Future<OAuthToken> _exchange(
    OperationRequestPlan plan,
    String environment,
    Uri endpoint,
    Map<String, String> fields,
    Map<String, dynamic> configuration,
    SecretResolver? resolveSecret,
    RunCancellation cancellation, {
    required String defaultAuthentication,
    List<String> requestedScopes = const [],
  }) async {
    cancellation.throwIfCancelled();
    final clientId = _clientId(configuration);
    final authentication =
        configuration['clientAuthentication'] as String? ??
        defaultAuthentication;
    String? clientSecret;
    final reference = configuration['clientSecretRef'];
    if (reference != null && authentication != 'none') {
      if (reference is! String ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(reference) ||
          resolveSecret == null) {
        throw CoreFailure(
          'secret.reference',
          'OAuth client secret requires a BusyAPI secret reference',
        );
      }
      // The secure backend may own an uncancellable unlock/read. Future.any
      // observes its eventual error while cancellation releases this operation.
      clientSecret = await Future.any<String?>([
        resolveSecret(reference),
        cancellation.whenCancelled.then<String?>((_) {
          cancellation.throwIfCancelled();
          return null;
        }),
      ]);
      cancellation.throwIfCancelled();
      _current(plan);
      if (clientSecret == null) {
        throw CoreFailure(
          'secret.unavailable',
          'The OAuth client secret is unavailable',
        );
      }
    }
    if (authentication == 'none') fields = {...fields, 'client_id': clientId};
    if (authentication == 'body') {
      fields = {
        ...fields,
        'client_id': clientId,
        if (clientSecret != null) 'client_secret': clientSecret,
      };
    } else if (authentication != 'basic' && authentication != 'none') {
      throw CoreFailure(
        'oauth.client-authentication',
        'Choose OAuth client authentication basic, body or none',
      );
    }
    final body = fields.entries
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    _current(plan);
    cancellation.throwIfCancelled();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final stopped = Completer<void>();
    var disposed = false;
    String? stopReason;
    HttpClientRequest? owned;
    void stop(String reason) {
      if (disposed || stopReason != null) return;
      stopReason = reason;
      owned?.abort();
      client.close(force: true);
      stopped.complete();
    }

    final timer = Timer(
      tokenExchangeTimeout,
      () => stop('oauth.exchange.timeout'),
    );
    cancellation.whenCancelled.then((_) => stop('cancelled'));
    Never failure() => throw CoreFailure(
      stopReason ?? 'oauth.exchange.timeout',
      stopReason == 'cancelled' ? 'OAuth token exchange was cancelled.' : 'The token exchange exceeded its overall deadline; no retry was sent.',
    );
    Future<T> wait<T>(Future<T> work) =>
        Future.any<T>([work, stopped.future.then<T>((_) => failure())]);
    try {
      final request = await wait(client.postUrl(endpoint));
      owned = request;
      unawaited(
        request.done.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (authentication == 'basic') {
        final encoded = base64.encode(
          utf8.encode(
            '${Uri.encodeQueryComponent(clientId)}:${Uri.encodeQueryComponent(clientSecret ?? '')}',
          ),
        );
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $encoded');
      }
      request.add(utf8.encode(body));
      await wait(request.flush());
      final response = await wait(
        request.close().timeout(const Duration(seconds: 30)),
      );
      final bytes = <int>[];
      final chunks = StreamIterator<List<int>>(response);
      try {
        while (await wait(
          chunks.moveNext().timeout(const Duration(seconds: 15)),
        )) {
          final chunk = chunks.current;
          if (bytes.length + chunk.length > maximumTokenResponseBytes) {
            throw CoreFailure(
              'limit.oauth.response',
              'OAuth token response exceeds 1 MiB',
            );
          }
          bytes.addAll(chunk);
        }
      } finally {
        await chunks.cancel();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CoreFailure(
          'oauth.token',
          'OAuth token endpoint returned HTTP ${response.statusCode}',
        );
      }
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      } on Object {
        throw CoreFailure(
          'oauth.token',
          'OAuth token response is not bounded UTF-8 JSON',
        );
      }
      if (decoded is! Map ||
          decoded['access_token'] is! String ||
          (decoded['access_token'] as String).isEmpty ||
          (decoded['access_token'] as String).length > 64 * 1024) {
        throw CoreFailure(
          'oauth.token',
          'OAuth token response has no usable access token',
        );
      }
      final tokenType = decoded['token_type'];
      if (tokenType is! String || tokenType.toLowerCase() != 'bearer') {
        throw CoreFailure(
          'oauth.token.type',
          'The token endpoint must return a supported Bearer token_type. This token was not accepted.',
        );
      }
      if (RegExp(r'[\x00-\x20\x7f]')
          .hasMatch(decoded['access_token'] as String)) {
        throw CoreFailure(
          'oauth.token',
          'The token endpoint returned an invalid access token.',
        );
      }
      if (decoded.containsKey('scope') && decoded['scope'] is! String) {
        throw CoreFailure(
          'oauth.token.scope',
          'The token endpoint returned invalid scope metadata.',
        );
      }
      final expires = decoded['expires_in'];
      if (decoded.containsKey('expires_in') &&
          (expires is! num ||
              !expires.isFinite ||
              expires < 0 ||
              expires > 315360000)) {
        throw CoreFailure(
          'oauth.token.expiry',
          'The token endpoint returned invalid expiry metadata.',
        );
      }
      final expiresAt = expires is num && expires.isFinite && expires >= 0
          ? DateTime.now().toUtc().add(
              Duration(seconds: expires.toInt().clamp(0, 315360000)),
            )
          : null;
      _current(plan);
      cancellation.throwIfCancelled();
      return OAuthToken(
        accessToken: decoded['access_token'] as String,
        tokenType: 'Bearer',
        refreshToken: decoded['refresh_token'] is String
            ? decoded['refresh_token'] as String
            : null,
        expiresAt: expiresAt,
        scope: decoded['scope'] is String
            ? (decoded['scope'] as String)
                  .split(RegExp(r'\s+'))
                  .where((value) => value.isNotEmpty)
                  .toList()
            : List.unmodifiable(requestedScopes),
        owner: plan.identity,
        environment: environment,
      );
    } on TimeoutException {
      stop('oauth.exchange.timeout');
      failure();
    } on HandshakeException {
      throw CoreFailure(
        'oauth.tls',
        'The authorization server could not be verified. This client uses system trust for token endpoints; endpoint-specific private CA/mTLS setup is not supported.',
      );
    } on SocketException {
      if (stopReason != null) failure();
      if (cancellation.cancelled) {
        throw CoreFailure('cancelled', 'OAuth token exchange was cancelled');
      }
      throw CoreFailure(
        'oauth.transport',
        'OAuth token endpoint could not be reached',
      );
    } on Object catch (error) {
      if (stopReason != null) failure();
      if (error is CoreFailure) rethrow;
      cancellation.throwIfCancelled();
      throw CoreFailure(
        'oauth.transport',
        'The token exchange connection failed; no retry was sent.',
      );
    } finally {
      disposed = true;
      timer.cancel();
      client.close(force: true);
    }
  }

  static bool _loopback(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1';
  }

  static String _random(int bytes) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }
}
