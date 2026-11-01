import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'model.dart';
import 'cancellable_tls_socket.dart';

/// Preserve OAS 3.2 additionalOperations tokens (RFC 9110 §9.1) through the
/// pinned HttpClient, which uppercases its method argument. HTTP framing,
/// uploads, response parsing and cancellation remain owned by HttpClient.
final class ExactHttpMethod {
  factory ExactHttpMethod(String method) {
    if (!RegExp(r"^[-!#$%&'*+.^_`|~0-9A-Za-z]+$").hasMatch(method)) {
      throw CoreFailure(
        'request.method',
        'The request method must be an HTTP token',
      );
    }
    return ExactHttpMethod._(ascii.encode('$method '));
  }
  ExactHttpMethod._(this._replacement);

  static const wireMethod = 'BUSYAPI';
  final Uint8List _replacement;

  Future<ConnectionTask<Socket>> connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    SecurityContext? context,
  }) async {
    if (!uri.isScheme('http') && !uri.isScheme('https')) {
      throw CoreFailure('request.scheme', 'Use an HTTP or HTTPS API server');
    }
    if (proxyHost != null || proxyPort != null) {
      throw CoreFailure(
        'request.method.proxy',
        'The selected proxy cannot preserve this method through the native connection adapter',
      );
    }
    final port = uri.port == 0 ? (uri.isScheme('https') ? 443 : 80) : uri.port;
    final task = uri.isScheme('https')
        ? await connectCancellableTls(uri.host, port, context: context)
        : await Socket.startConnect(uri.host, port);
    var cancelled = false;
    Socket? connected;
    final future = task.socket.then<Socket>((socket) {
      if (cancelled) {
        socket.destroy();
        throw const SocketException('Connection attempt cancelled');
      }
      final prefix = _MethodPrefix(_replacement);
      return connected = socket is SecureSocket
          ? _ExactSecureSocket(socket, prefix)
          : _ExactSocket(socket, prefix);
    });
    return ConnectionTask.fromSocket(future, () {
      cancelled = true;
      task.cancel();
      connected?.destroy();
    });
  }
}

final class _MethodPrefix {
  _MethodPrefix(this.replacement);
  static final List<int> expected = List.unmodifiable(
    ascii.encode('${ExactHttpMethod.wireMethod} '),
  );
  final Uint8List replacement;
  int matched = 0;
  bool get incomplete => matched > 0 && matched < expected.length;

  List<int> rewrite(List<int> bytes) {
    if (matched == expected.length || bytes.isEmpty) return bytes;
    var offset = 0;
    while (offset < bytes.length && matched < expected.length) {
      if ((bytes[offset++] & 255) != expected[matched++]) {
        throw CoreFailure(
          'request.method.framing',
          'The native HTTP request prefix did not match its captured method adapter',
        );
      }
    }
    if (matched < expected.length) return const [];
    // Only this connection's first token is replaced. No search, decoding or
    // replacement touches the target URI, header values, framing or body bytes.
    return Uint8List(replacement.length + bytes.length - offset)
      ..setRange(0, replacement.length, replacement)
      ..setRange(
        replacement.length,
        replacement.length + bytes.length - offset,
        bytes,
        offset,
      );
  }
}

class _ExactSocket extends StreamView<Uint8List> implements Socket {
  _ExactSocket(this.socket, this.prefix) : super(socket);
  final Socket socket;
  final _MethodPrefix prefix;

  @override
  void add(List<int> data) {
    final bytes = prefix.rewrite(data);
    if (bytes.isNotEmpty) socket.add(bytes);
  }

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      socket.addStream(stream.map(prefix.rewrite));
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      socket.addError(error, stackTrace);
  @override
  Encoding get encoding => socket.encoding;
  @override
  set encoding(Encoding value) => socket.encoding = value;
  @override
  void write(Object? object) => add(encoding.encode(object.toString()));
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    final values = objects.iterator;
    if (!values.moveNext()) return;
    write(values.current);
    while (values.moveNext()) {
      write(separator);
      write(values.current);
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  Future<dynamic> flush() => socket.flush();
  @override
  Future<dynamic> close() {
    if (prefix.incomplete) {
      socket.destroy();
      return Future<dynamic>.error(
        CoreFailure(
          'request.method.framing',
          'The native request ended before its method token was complete',
        ),
      );
    }
    return socket.close();
  }

  @override
  Future<dynamic> get done => socket.done;
  @override
  void destroy() => socket.destroy();
  @override
  bool setOption(SocketOption option, bool enabled) =>
      socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => socket.setRawOption(option);
  @override
  InternetAddress get address => socket.address;
  @override
  InternetAddress get remoteAddress => socket.remoteAddress;
  @override
  int get port => socket.port;
  @override
  int get remotePort => socket.remotePort;
}

final class _ExactSecureSocket extends _ExactSocket implements SecureSocket {
  _ExactSecureSocket(this.secure, _MethodPrefix prefix) : super(secure, prefix);
  final SecureSocket secure;
  @override
  X509Certificate? get peerCertificate => secure.peerCertificate;
  @override
  String? get selectedProtocol => secure.selectedProtocol;
  @override
  @Deprecated('Matches the deprecated SecureSocket interface')
  void renegotiate({
    bool useSessionCache = true,
    bool requestClientCertificate = false,
    bool requireClientCertificate = false,
  }) => secure.renegotiate(
    useSessionCache: useSessionCache,
    requestClientCertificate: requestClientCertificate,
    requireClientCertificate: requireClientCertificate,
  );
}
