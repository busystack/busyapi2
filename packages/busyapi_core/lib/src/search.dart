import 'dart:async';
import 'dart:isolate';

import 'model.dart';
import 'project.dart';

class SearchOptions {
  const SearchOptions(
    this.query, {
    this.regex = false,
    this.caseSensitive = false,
  });
  final String query;
  final bool regex, caseSensitive;
}

class SearchMatch {
  const SearchMatch(
    this.resource,
    this.generation,
    this.start,
    this.end,
    this.expected,
    this.line,
  );
  final String resource, expected;
  final int generation, start, end, line;
}

/// Captured full-document results. Replacing matches always verifies the entire
/// search input, including resources which did not contain a match.
class SearchSnapshot {
  SearchSnapshot(
    this.options,
    List<Map<String, Object?>> resources,
    List<SearchMatch> matches, {
    this.timings,
  }) : resources = List.unmodifiable(
         resources.map((r) => Map<String, Object?>.unmodifiable(r)),
       ),
       matches = List.unmodifiable(matches);
  final SearchOptions options;
  final List<Map<String, Object?>> resources;
  final List<SearchMatch> matches;
  final SearchTimings? timings;
  late final _texts = {
    for (final resource in resources)
      resource['id'] as String: resource['text'] as String,
  };

  /// Context is taken from the reviewed snapshot, never a later buffer. Large
  /// matches/replacements are sliced on demand rather than laid out in full.
  SearchChangePreview preview(SearchMatch match, String replacement) {
    final text = _texts[match.resource]!;
    var start = (match.start - 240).clamp(0, text.length);
    var end = (match.end + 240).clamp(0, text.length);
    start = _scalarBoundary(text, start);
    end = _scalarBoundary(text, end);
    final lineStart = text.indexOf('\n', start);
    if (start > 0 && lineStart >= 0 && lineStart < match.start) {
      start = lineStart + 1;
    }
    final lineEnd = text.lastIndexOf('\n', end > 0 ? end - 1 : 0);
    if (end < text.length && lineEnd >= match.end) end = lineEnd;
    return SearchChangePreview(
      text.substring(start, match.start),
      match.expected,
      replacement,
      text.substring(match.end, end),
    );
  }

  bool current(BufferStore store) => resources.every((r) {
    final b = store.buffers[r['id']];
    return b != null &&
        b.generation == r['generation'] &&
        b.sourceIdentity == r['identity'];
  });

  List<TextEdit> replacement(BufferStore store, String value) {
    if (!current(store))
      throw CoreFailure(
        'search.stale',
        'Source changed after this search; run the search again',
      );
    return List.unmodifiable(
      matches.map(
        (m) => TextEdit(
          buffer: m.resource,
          generation: m.generation,
          start: m.start,
          end: m.end,
          expected: m.expected,
          replacement: value,
        ),
      ),
    );
  }

  void replace(BufferStore store, String value) =>
      store.apply(replacement(store, value), label: 'Replace in project');
}

class SearchTimings {
  const SearchTimings(
    this.collectionMicros,
    this.workerMicros,
    this.resultMicros,
  );
  final int collectionMicros, workerMicros, resultMicros;
}

/// Before/after strings without copying an arbitrarily large replacement for
/// every occurrence. Page boundaries never bisect a UTF-16 surrogate pair.
class SearchChangePreview {
  const SearchChangePreview(this.prefix, this.before, this.after, this.suffix);
  final String prefix, before, after, suffix;
  int length(bool replaced) =>
      prefix.length + (replaced ? after : before).length + suffix.length;
  static const pageSize = 1024;
  int pages(bool replaced) =>
      ((length(replaced) + pageSize - 1) ~/ pageSize).clamp(1, 1 << 30);
  String page(bool replaced, int index) {
    final segments = [prefix, replaced ? after : before, suffix];
    final start = index * pageSize, end = start + pageSize;
    var offset = 0;
    final result = StringBuffer();
    for (final segment in segments) {
      final a = (start - offset).clamp(0, segment.length);
      final b = (end - offset).clamp(0, segment.length);
      result.write(
        segment.substring(
          _scalarBoundary(segment, a),
          _scalarBoundary(segment, b),
        ),
      );
      offset += segment.length;
    }
    return result.toString();
  }
}

int _scalarBoundary(String text, int offset) =>
    offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff &&
        text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff
    ? offset - 1
    : offset;

/// Each regex runs in a cancellable isolate. A timeout kills its computation;
/// a timeout of the receiving Future alone would leave a blocked worker alive.
class ProjectSearch {
  ProjectSearch(
    this.project, {
    this.timeout = const Duration(seconds: 2),
    this.onResourceRefreshed,
  });
  final BusyProject project;
  final Duration timeout;
  final void Function(String resource)? onResourceRefreshed;
  Isolate? _worker;
  Completer<SearchSnapshot>? _completion;
  int _epoch = 0;

  void cancel() {
    _epoch++;
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    final pending = _completion;
    _completion = null;
    if (pending != null && !pending.isCompleted)
      pending.completeError(
        CoreFailure('search.cancelled', 'Search cancelled'),
      );
  }

  /// [resource] scopes the existing captured search to the active document.
  /// Collection, cancellation, limits and replacement checks stay identical.
  Future<SearchSnapshot> run(SearchOptions options, {String? resource}) async {
    cancel();
    final epoch = _epoch;
    if (options.query.isEmpty || options.query.length > 4096) {
      throw CoreFailure(
        'search.query',
        'Enter a search expression of 1–4096 characters',
      );
    }
    final resources = <Map<String, Object?>>[];
    final collection = Stopwatch()..start();
    var bytes = 0;
    final ids = resource != null
        ? [resource]
        : (<String>{
                ...project.files.map((path) => Uri.file(path).toString()),
                ...project.store.buffers.keys,
              }
              .where(
                (id) => RegExp(
                  r'\.(json|ya?ml)$',
                  caseSensitive: false,
                ).hasMatch(Uri.parse(id).path),
              )
              .toList()
            ..sort());
    for (final id in ids) {
      if (epoch != _epoch)
        throw CoreFailure('search.cancelled', 'Search cancelled');
      final buffer = await project.buffer(id);
      final generation = buffer.generation, conflict = buffer.externalConflict;
      if (!buffer.dirty && !buffer.externalConflict) {
        await project.refreshDisk(buffer);
        if (buffer.generation != generation ||
            buffer.externalConflict != conflict) {
          onResourceRefreshed?.call(id);
        }
      }
      final captured = await buffer.snapshotAsync();
      bytes += (captured['text'] as String).length * 2;
      if (bytes > 32 * 1024 * 1024)
        throw CoreFailure(
          'limit.search',
          'Search input exceeds 32 MiB; choose a narrower project',
        );
      resources.add(captured);
    }
    if (epoch != _epoch)
      throw CoreFailure('search.cancelled', 'Search cancelled');
    collection.stop();
    final workerTime = Stopwatch()..start();
    final reply = ReceivePort(), errors = ReceivePort();
    final completion = Completer<SearchSnapshot>();
    // Install an error observer before any worker can complete.
    completion.future.ignore();
    _completion = completion;
    void fail(String code, String message) {
      if (!completion.isCompleted)
        completion.completeError(CoreFailure(code, message));
    }

    final resultSubscription = reply.listen((dynamic result) {
      if (completion.isCompleted) return;
      if (result == null) {
        fail('search.worker', 'Search worker stopped without a result');
        return;
      }
      final message = result as Map;
      if (message['error'] is String) {
        fail(message['error'] as String, message['message'] as String);
        return;
      }
      workerTime.stop();
      final resultTime = Stopwatch()..start();
      final matches = (message['matches'] as List)
          .map(
            (dynamic m) => SearchMatch(
              m[0] as String,
              m[1] as int,
              m[2] as int,
              m[3] as int,
              m[4] as String,
              m[5] as int,
            ),
          )
          .toList();
      final snapshot = SearchSnapshot(
        options,
        List.unmodifiable(resources),
        List.unmodifiable(matches),
        timings: SearchTimings(
          collection.elapsedMicroseconds,
          workerTime.elapsedMicroseconds,
          resultTime.elapsedMicroseconds,
        ),
      );
      if (!snapshot.current(project.store)) {
        fail('search.stale', 'Source changed while the search was running');
      } else {
        completion.complete(snapshot);
      }
    });
    final errorSubscription = errors.listen(
      (_) => fail('search.worker', 'Search worker failed'),
    );
    Timer? timer;
    try {
      final worker = await Isolate.spawn(
        _search,
        [
          reply.sendPort,
          options.query,
          options.regex,
          options.caseSensitive,
          resources,
        ],
        onError: errors.sendPort,
        onExit: reply.sendPort,
        errorsAreFatal: true,
      );
      if (epoch != _epoch) {
        worker.kill(priority: Isolate.immediate);
        fail('search.cancelled', 'Search cancelled');
      } else {
        _worker = worker;
        timer = Timer(timeout, () {
          worker.kill(priority: Isolate.immediate);
          fail(
            'search.timeout',
            'Search exceeded its time limit; refine the expression',
          );
        });
      }
      return await completion.future;
    } finally {
      timer?.cancel();
      if (identical(_completion, completion)) {
        _worker?.kill(priority: Isolate.immediate);
        _worker = null;
        _completion = null;
      }
      await resultSubscription.cancel();
      await errorSubscription.cancel();
      reply.close();
      errors.close();
    }
  }
}

void _search(List<Object?> input) {
  final port = input[0] as SendPort;
  try {
    final expression = RegExp(
      input[2] == true ? input[1] as String : RegExp.escape(input[1] as String),
      caseSensitive: input[3] as bool,
      unicode: true,
      multiLine: true,
    );
    final matches = <List<Object?>>[];
    for (final r in (input[4] as List).cast<Map<String, Object?>>()) {
      final text = r['text'] as String;
      var line = 1, previous = 0;
      for (final match in expression.allMatches(text)) {
        if (matches.length >= 20000) {
          port.send({
            'error': 'limit.search.matches',
            'message': 'Search exceeds 20000 matches; refine the expression',
          });
          return;
        }
        for (var i = previous; i < match.start; i++) {
          if (text.codeUnitAt(i) == 10 ||
              text.codeUnitAt(i) == 13 &&
                  (i + 1 == text.length || text.codeUnitAt(i + 1) != 10))
            line++;
        }
        previous = match.start;
        matches.add([
          r['id'],
          r['generation'],
          match.start,
          match.end,
          match.group(0)!,
          line,
        ]);
      }
    }
    Isolate.exit(port, {'matches': matches});
  } on FormatException {
    port.send({
      'error': 'search.pattern',
      'message': 'Invalid regular expression',
    });
  } on Object {
    port.send({'error': 'search.worker', 'message': 'Search worker failed'});
  }
}
