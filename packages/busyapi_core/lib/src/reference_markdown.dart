import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:markdown/markdown.dart' as markdown;

import 'model.dart';

/// A display-only tree. No HTML, image/resource loader, executable extensions,
/// document edits or OpenAPI resolution are delegated to the Markdown parser.
class ReferenceMarkup {
  ReferenceMarkup(
    this.kind, {
    this.text = '',
    this.target,
    this.start,
    List<ReferenceMarkup> children = const [],
  }) : children = List.unmodifiable(children);
  final String kind, text;
  final Uri? target;
  final int? start;
  final List<ReferenceMarkup> children;

  String get plainText => kind == 'text' || kind == 'image'
      ? text
      : kind == 'br'
      ? '\n'
      : children
            .map((child) => child.plainText)
            .join(
              const {'ul', 'ol', 'li', 'blockquote'}.contains(kind) ? '\n' : '',
            );
}

class ReferenceMarkdown {
  ReferenceMarkdown(List<ReferenceMarkup> blocks, {required this.formatted})
    : blocks = List.unmodifiable(blocks);
  final List<ReferenceMarkup> blocks;
  final bool formatted;

  /// Synchronous parsing for an already isolated, cancellable export worker.
  /// Native presentation uses ReferenceMarkdownJob, never this on its UI thread.
  static ReferenceMarkdown parseInWorker(String source, {Uri? base}) {
    if (source.length > 65536) {
      return ReferenceMarkdown([
        ReferenceMarkup('text', text: source),
      ], formatted: false);
    }
    final parsed = markdown.Document(encodeHtml: false).parse(source);
    var count = 0;
    ReferenceMarkup convert(markdown.Node node, int depth) {
      if (++count > 8192 || depth > 32) {
        throw CoreFailure(
          'documentation.markdown.limit',
          'Description structure exceeds its bounded presentation limit',
        );
      }
      if (node is! markdown.Element)
        return ReferenceMarkup('text', text: node.textContent);
      if (node.tag == 'img')
        return ReferenceMarkup('image', text: node.attributes['alt'] ?? '');
      return ReferenceMarkup(
        node.tag,
        children: (node.children ?? const <markdown.Node>[])
            .map((child) => convert(child, depth + 1))
            .toList(),
        target: node.tag == 'a'
            ? referenceLink(node.attributes['href'] ?? '', base: base)
            : null,
        start: node.tag == 'ol'
            ? int.tryParse(node.attributes['start'] ?? '')
            : null,
      );
    }

    return ReferenceMarkdown(
      parsed.map((node) => convert(node, 0)).toList(),
      formatted: true,
    );
  }

  /// HTML export and native presentation consume this same safe tree. Raw HTML
  /// is text; images have alt text only. No authored attribute is emitted.
  String toHtml() {
    const tags = {
      'p',
      'strong',
      'em',
      'code',
      'pre',
      'blockquote',
      'ul',
      'ol',
      'li',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
    };
    const escape = HtmlEscape(HtmlEscapeMode.element);
    const attribute = HtmlEscape(HtmlEscapeMode.attribute);
    String render(ReferenceMarkup node) {
      if (node.kind == 'text') return escape.convert(node.text);
      if (node.kind == 'image')
        return '<span>${escape.convert(node.text)}</span>';
      if (node.kind == 'br') return '<br>';
      if (node.kind == 'hr') return '<hr>';
      final content = node.children.map(render).join();
      if (node.kind == 'a' && node.target != null) {
        final target = node.target!;
        // Check again: consumers may construct their own tree values.
        final approved = referenceLink(target.toString());
        if (approved != null)
          return '<a href="${attribute.convert(approved.toString())}" rel="noopener noreferrer">$content</a>';
      }
      if (!tags.contains(node.kind)) return content;
      final start =
          node.kind == 'ol' &&
              node.start != null &&
              node.start! >= 0 &&
              node.start! <= 999999999
          ? ' start="${node.start}"'
          : '';
      return '<${node.kind}$start>$content</${node.kind}>';
    }

    final content = blocks.map(render).join('\n');
    return formatted ? content : '<pre>$content</pre>';
  }
}

/// Decode the canonical captured rendering context. Missing or malformed
/// metadata leaves relative destinations inactive. Only an explicit true marker
/// selects the captured resource URI; mapped and schema identities retain their
/// distinct URI. Missing metadata never falls back to physical coordinates.
Uri? referenceMarkdownBase(Map source) {
  final context = source['markdownBase'];
  final value = context == true ? source['resource'] : context;
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  return uri != null && uri.hasScheme ? uri : null;
}

/// Only explicit links can navigate. Relative file/resource links remain text
/// until an owner with graph/access capabilities supplies a navigation policy.
/// A fragment is retained as a fragment, never turned into filesystem access.
Uri? referenceLink(String value, {Uri? base}) {
  if (value.length > 4096 || RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value))
    return null;
  try {
    final relative = Uri.parse(value);
    if (!relative.hasScheme &&
        !relative.hasAuthority &&
        relative.path.isEmpty &&
        relative.hasFragment)
      return relative;
    final target = base == null ? relative : base.resolveUri(relative);
    if (!{'https', 'http', 'mailto'}.contains(target.scheme.toLowerCase()) ||
        target.userInfo.isNotEmpty)
      return null;
    if (target.scheme != 'mailto' && target.host.isEmpty) return null;
    return target;
  } on FormatException {
    return null;
  }
}

/// The same cancellable headless job serves native Reference and HTML builds.
/// Parsing has a real isolate/deadline, not a timer racing synchronous work on
/// the UI isolate. Long descriptions retain complete text rather than partial
/// formatted success; native callers keep their existing scalar pagination.
class ReferenceMarkdownJob {
  ReferenceMarkdownJob(
    this.source, {
    this.base,
    Duration timeout = const Duration(seconds: 2),
  }) {
    unawaited(
      _result.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
    _subscription = _port.listen((message) {
      if (message is ReferenceMarkdown) {
        _finish(value: message);
      } else {
        _finish(
          error: CoreFailure(
            'documentation.markdown.failed',
            'Description rendering did not complete',
          ),
        );
      }
    });
    _timer = Timer(
      timeout,
      () => _finish(
        error: CoreFailure(
          'documentation.markdown.timeout',
          'Description rendering exceeded its computation limit',
        ),
      ),
    );
    _exitSubscription = _exits.listen((_) {
      _exited = true;
      if (_finished) _release();
    });
    if (source.length > 65536) {
      _finish(
        value: ReferenceMarkdown([
          ReferenceMarkup('text', text: source),
        ], formatted: false),
      );
    } else if (_active < 2) {
      _start();
    } else if (_waiting.length < 128 &&
        _waitingBytes + _cost <= 2 * 1024 * 1024) {
      _queued = true;
      _waiting.add(this);
      _waitingBytes += _cost;
    } else {
      _finish(
        error: CoreFailure(
          'documentation.markdown.busy',
          'Description rendering has reached its bounded waiting capacity',
        ),
      );
    }
  }
  final String source;
  final Uri? base;
  int get _cost => source.length * 2 + (base?.toString().length ?? 0) * 2;
  static int _active = 0, _waitingBytes = 0;
  static final _waiting = <ReferenceMarkdownJob>[];

  /// Passive admission counts, with no source text or process authority.
  static (int running, int waiting) get admission => (_active, _waiting.length);
  void _start() {
    if (_finished) return;
    _admitted = true;
    _active++;
    Isolate.spawn(
      _parse,
      [_port.sendPort, source, base?.toString()],
      onError: _port.sendPort,
      onExit: _exits.sendPort,
    ).then(
      (worker) {
        if (_finished) {
          worker.kill(priority: Isolate.immediate);
        } else {
          _worker = worker;
        }
      },
      onError: (Object _, StackTrace __) {
        _exited = true;
        _finish(
          error: CoreFailure(
            'documentation.markdown.failed',
            'Description rendering could not start',
          ),
        );
      },
    );
  }

  final _port = ReceivePort();
  final _exits = ReceivePort();
  final _result = Completer<ReferenceMarkdown>();
  late final StreamSubscription<dynamic> _subscription;
  late final StreamSubscription<dynamic> _exitSubscription;
  late final Timer _timer;
  Isolate? _worker;
  bool _finished = false,
      _admitted = false,
      _queued = false,
      _released = false,
      _exited = false;
  Future<ReferenceMarkdown> get result => _result.future;
  void cancel() => _finish(
    error: CoreFailure('cancelled', 'Description rendering was cancelled'),
  );
  void _finish({ReferenceMarkdown? value, Object? error}) {
    if (_finished) return;
    _finished = true;
    _timer.cancel();
    unawaited(_subscription.cancel());
    _port.close();
    if (_queued) {
      _waiting.remove(this);
      _waitingBytes -= _cost;
      _queued = false;
    }
    _worker?.kill(priority: Isolate.immediate);
    if (!_admitted || _exited) _release();
    if (error != null) {
      _result.completeError(error);
    } else {
      _result.complete(value!);
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    unawaited(_exitSubscription.cancel());
    _exits.close();
    if (_admitted) {
      _admitted = false;
      _active--;
    }
    // A cancellation request is not an exit acknowledgement. Capacity is
    // reclaimed here only after actual exit, or a failed spawn, never merely
    // because a UI owner stopped awaiting its result.
    while (_active < 2 && _waiting.isNotEmpty) {
      final next = _waiting.removeAt(0);
      _waitingBytes -= next._cost;
      next._queued = false;
      next._start();
    }
  }

  static void _parse(List<Object?> input) {
    final port = input[0] as SendPort, source = input[1] as String;
    try {
      final base = input[2] == null ? null : Uri.parse(input[2] as String);
      port.send(ReferenceMarkdown.parseInWorker(source, base: base));
    } on Object {
      port.send('description-failed');
    }
  }
}
