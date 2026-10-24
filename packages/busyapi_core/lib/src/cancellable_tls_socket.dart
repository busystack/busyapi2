import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A TLS connection whose TCP owner remains available throughout the handshake.
/// Dart 3.13.4's SecureSocket.startConnect cancellation only owns the initial
/// TCP attempt. Retain that same RawSocket for abort; TLS trust and protocol
/// handling stay with RawSecureSocket and the caller's SecurityContext.
Future<ConnectionTask<Socket>> connectCancellableTls(
  String host,
  int port, {
  SecurityContext? context,
}) async {
  final task = await RawSocket.startConnect(host, port);
  RawSocket? tcp;
  Socket? connected;
  var cancelled = false;
  final socket = task.socket.then<Socket>((raw) async {
    tcp = raw;
    if (cancelled) {
      await raw.close();
      throw const SocketException('Connection attempt cancelled');
    }
    try {
      final secure = await RawSecureSocket.secure(
        raw,
        host: host,
        context: context,
      );
      if (cancelled) {
        await raw.close();
        await secure.close();
        throw const SocketException('Connection attempt cancelled');
      }
      return connected = _CancellableTlsSocket(raw, secure);
    } on Object {
      await raw.close();
      rethrow;
    }
  });
  return ConnectionTask.fromSocket(socket, () {
    cancelled = true;
    task.cancel();
    final owner = tcp;
    if (owner != null) unawaited(owner.close());
    connected?.destroy();
  });
}

final class _CancellableTlsSocket extends Stream<Uint8List>
    implements SecureSocket {
  _CancellableTlsSocket(this.tcp, this.secure) {
    secure.readEventsEnabled = false;
    secure.writeEventsEnabled = false;
    incoming = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        if (!destroyed) secure.readEventsEnabled = true;
      },
      onPause: () {
        if (!destroyed) secure.readEventsEnabled = false;
      },
      onResume: () {
        if (!destroyed) secure.readEventsEnabled = true;
      },
      onCancel: () {
        if (!destroyed) secure.shutdown(SocketDirection.receive);
      },
    );
    output = IOSink(_TlsOutput(this));
    events = secure.listen(event, onError: failed, onDone: ended);
  }

  final RawSocket tcp;
  final RawSecureSocket secure;
  late final StreamController<Uint8List> incoming;
  late final IOSink output;
  late final StreamSubscription<RawSocketEvent> events;
  Completer<void>? writable;
  bool destroyed = false;

  void event(RawSocketEvent value) {
    if (value == RawSocketEvent.read) {
      if (!incoming.isClosed && incoming.hasListener && !incoming.isPaused) {
        final bytes = secure.read();
        if (bytes != null) incoming.add(bytes);
      }
    } else if (value == RawSocketEvent.write) {
      secure.writeEventsEnabled = false;
      final ready = writable;
      writable = null;
      ready?.complete();
    } else if (value == RawSocketEvent.readClosed) {
      if (!incoming.isClosed) unawaited(incoming.close());
    } else if (value == RawSocketEvent.closed) {
      ended();
    }
  }

  void failed(Object error, StackTrace stack) {
    if (!incoming.isClosed) incoming.addError(error, stack);
    final ready = writable;
    writable = null;
    ready?.completeError(error, stack);
    destroy();
  }

  void ended() {
    destroyed = true;
    final ready = writable;
    writable = null;
    ready?.completeError(const SocketException('TLS connection closed'));
    if (!incoming.isClosed) unawaited(incoming.close());
  }

  Future<void> send(List<int> bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      if (destroyed) throw const SocketException('TLS connection closed');
      final count = secure.write(bytes, offset, bytes.length - offset);
      offset += count;
      if (offset == bytes.length) return;
      final ready = writable = Completer<void>();
      secure.writeEventsEnabled = true;
      await ready.future;
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    unawaited(tcp.close());
    final ready = writable;
    writable = null;
    ready?.completeError(const SocketException('TLS connection destroyed'));
  }

  @override
  void add(List<int> data) => output.add(data);
  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      output.addStream(stream);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      output.addError(error, stackTrace);
  @override
  Encoding get encoding => output.encoding;
  @override
  set encoding(Encoding value) => output.encoding = value;
  @override
  void write(Object? object) => output.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      output.writeAll(objects, separator);
  @override
  void writeln([Object? object = '']) => output.writeln(object);
  @override
  void writeCharCode(int charCode) => output.writeCharCode(charCode);
  @override
  Future<dynamic> flush() => output.flush();
  @override
  Future<dynamic> close() => output.close();
  @override
  Future<dynamic> get done => output.done;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      secure.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => secure.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => secure.setRawOption(option);
  @override
  InternetAddress get address => secure.address;
  @override
  InternetAddress get remoteAddress => secure.remoteAddress;
  @override
  int get port => secure.port;
  @override
  int get remotePort => secure.remotePort;
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

final class _TlsOutput implements StreamConsumer<List<int>> {
  _TlsOutput(this.owner);
  final _CancellableTlsSocket owner;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) {
      await owner.send(bytes);
    }
  }

  @override
  Future<Socket> close() async {
    if (!owner.destroyed) owner.secure.shutdown(SocketDirection.send);
    return owner;
  }
}
