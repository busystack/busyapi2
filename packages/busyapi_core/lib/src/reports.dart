import 'dart:convert';

import 'atomic_file_writer.dart';
import 'contract_test.dart';
import 'project.dart';
import 'source_line_index.dart';
import 'storage.dart';

/// Converters consume captured result records, never reread a working file or
/// turn an unavailable location / unexecuted operation into invented evidence.
class CiReports {
  static Map<String, Object?> sarif(
    List<Map<String, dynamic>> records, {
    List<AnalysisSnapshot> snapshots = const [],
    Iterable<String> secrets = const [],
  }) {
    final redact = _redactor(secrets);
    final sources = <String, String>{};
    final lineIndexes = <String, SourceLineIndex>{};
    for (final snapshot in snapshots) {
      for (final source in [...snapshot.resources, ...snapshot.configuration]) {
        sources['${snapshot.identity}\u0000${source['id']}'] =
            source['text'] as String;
        sources['${snapshot.sourceIdentity}\u0000${source['id']}'] =
            source['text'] as String;
      }
    }
    final runs = <Map<String, Object?>>[];
    for (final record in records) {
      final findings = (record['findings'] as List? ?? const [])
          .whereType<Map>();
      final groups = <String, List<Map>>{};
      for (final finding in findings) {
        final producer =
            '${finding['producer'] ?? finding['engine'] ?? 'busyapi'}';
        final version =
            '${finding['producerVersion'] ?? finding['engineVersion'] ?? '0.1.0'}';
        groups.putIfAbsent('$producer\u0000$version', () => []).add(finding);
      }
      // An empty or failed run still has an invocation and honest completion.
      if (groups.isEmpty) groups['busyapi\u00000.1.0'] = [];
      for (final group in groups.entries) {
        final producer = group.key.split('\u0000');
        final codes = group.value.map((f) => '${f['code']}').toSet().toList()
          ..sort();
        final complete = record['complete'] == true;
        Map<String, Object?>? location(Map finding) {
          final resource = finding['resource'];
          if (resource is! String || resource.isEmpty) return null;
          if (redact(resource) != resource) return null;
          final uri = Uri.tryParse(resource);
          if (uri == null || uri.userInfo.isNotEmpty || uri.hasQuery)
            return null;
          final range = finding['range'];
          final text =
              sources['${record['contextSnapshot'] ?? record['sourceSnapshot'] ?? record['snapshot']}\u0000$resource'];
          final region = <String, Object?>{};
          if (range is List &&
              range.length == 2 &&
              range[0] is int &&
              range[1] is int &&
              (range[0] as int) >= 0 &&
              (range[1] as int) >= (range[0] as int)) {
            if (text != null && (range[1] as int) <= text.length) {
              final index = lineIndexes.putIfAbsent(
                '${record['contextSnapshot'] ?? record['sourceSnapshot'] ?? record['snapshot']}\u0000$resource',
                () => SourceLineIndex(text),
              );
              final start = index.lineAtOffset(range[0] as int),
                  end = index.lineAtOffset(range[1] as int);
              region.addAll({
                'startLine': start.number,
                'startColumn': range[0] - start.startOffset + 1,
                'endLine': end.number,
                'endColumn': range[1] - end.startOffset + 1,
              });
            } else {
              region.addAll({
                'charOffset': range[0],
                'charLength': range[1] - range[0],
              });
            }
          }
          return {
            'physicalLocation': {
              'artifactLocation': {'uri': redact(resource)},
              if (region.isNotEmpty) 'region': region,
            },
          };
        }

        runs.add({
          'tool': {
            'driver': {
              'name': redact(producer[0]),
              'version': redact(producer[1]),
              'rules': [
                for (final code in codes) {'id': redact(code)},
              ],
            },
          },
          'columnKind': 'utf16CodeUnits',
          'invocations': [
            {
              'executionSuccessful': complete,
              if (!complete)
                'toolExecutionNotifications': [
                  {
                    'level': 'error',
                    'message': {'text': 'Required analysis did not complete.'},
                  },
                ],
            },
          ],
          'properties': {
            'status': record['status'],
            'complete': complete,
            'snapshot': record['snapshot'],
          },
          'results': [
            for (final finding in group.value)
              {
                'ruleId': redact('${finding['code']}'),
                'level': switch (finding['severity']) {
                  'error' => 'error',
                  'warning' => 'warning',
                  _ => 'note',
                },
                'message': {
                  'text': redact('${finding['message'] ?? finding['code']}'),
                },
                if (location(finding) case final located?)
                  'locations': [located],
                if (finding['relatedLocations'] is List)
                  'relatedLocations': [
                    for (final related
                        in (finding['relatedLocations'] as List)
                            .whereType<Map>())
                      if (location(related) case final located?) located,
                  ],
              },
          ],
        });
      }
    }
    return {
      r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
      'version': '2.1.0',
      'runs': runs,
    };
  }

  static String junit(
    ContractTestReport report, {
    Iterable<String> secrets = const [],
  }) {
    final redact = _redactor(secrets);
    String escape(String value) =>
        String.fromCharCodes(
              redact(value).runes.map(
                (r) =>
                    r == 9 ||
                        r == 10 ||
                        r == 13 ||
                        r >= 0x20 && r <= 0xd7ff ||
                        r >= 0xe000 && r <= 0xfffd ||
                        r >= 0x10000 && r <= 0x10ffff
                    ? r
                    : 0xfffd,
              ),
            )
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;')
            .replaceAll('"', '&quot;')
            .replaceAll("'", '&apos;');
    String seconds(Duration duration) =>
        (duration.inMicroseconds / 1000000).toStringAsFixed(6);
    final failures = report.cases
        .where(
          (c) =>
              c.complete &&
              !c.passed &&
              !c.operationalFailure &&
              c.status != 'skipped',
        )
        .length;
    final errors = report.cases
        .where(
          (c) => (!c.complete || c.operationalFailure) && c.status != 'skipped',
        )
        .length;
    // A failed selected-run preflight has no executed cases. Emit a run error
    // so JUnit consumers cannot mistake tests=0/errors=0 for a passing run.
    final incompleteRun = !report.complete && errors == 0;
    final skipped = report.cases.where((c) => c.status == 'skipped').length;
    final out = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n');
    out.writeln(
      '<testsuites><testsuite name="BusyAPI contract tests" tests="${report.cases.length + (incompleteRun ? 1 : 0)}" failures="$failures" errors="${errors + (incompleteRun ? 1 : 0)}" skipped="$skipped" time="${seconds(report.cases.fold(Duration.zero, (sum, c) => sum + c.elapsed))}">',
    );
    out.writeln(
      '<properties><property name="snapshot" value="${escape(report.snapshot)}"/><property name="complete" value="${report.complete}"/><property name="untestedOperations" value="${report.untestedOperations.length}"/></properties>',
    );
    if (incompleteRun) {
      out.writeln(
        '<testcase name="Run preparation and completion" classname="busyapi.execution"><error type="incomplete" message="The selected run did not complete">No complete selected-run result is available; inspect the command diagnostics.</error></testcase>',
      );
    }
    for (final c in report.cases) {
      out.write(
        '<testcase name="${escape(c.name)}" classname="${escape(c.operation)}" time="${seconds(c.elapsed)}">',
      );
      final message = c.findings
          .map((f) => '${f['code']}: ${f['message']}')
          .join('\n');
      if (c.status == 'skipped') {
        out.write('<skipped message="Not executed"/>');
      } else if (!c.complete || !c.passed || c.operationalFailure) {
        final tag = c.complete && !c.operationalFailure ? 'failure' : 'error';
        out.write(
          '<$tag type="${escape(c.status)}" message="${escape(c.status)}">${escape(message)}</$tag>',
        );
      }
      out.writeln('</testcase>');
    }
    out.writeln('</testsuite></testsuites>');
    return out.toString();
  }

  /// An explicitly selected report is a no-clobber export, not a source save.
  static Future<void> publish(
    String destination,
    String text, {
    RunCancellation? cancellation,
    Future<void> Function()? beforePublish,
  }) async {
    cancellation?.throwIfCancelled();
    await const AtomicFileWriter().writeBytes(
      destination,
      utf8.encode(text),
      overwrite: false,
      beforePublish: () async {
        await beforePublish?.call();
        cancellation?.throwIfCancelled();
      },
      prepareStaged: (path) => privatePermissions(path, 384),
    );
  }

  static String Function(String) _redactor(Iterable<String> secrets) {
    final values = secrets.where((s) => s.isNotEmpty).toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    return (String input) {
      var result = input;
      for (final value in values) {
        result = result.replaceAll(value, '[redacted]');
      }
      return result.replaceAllMapped(RegExp(r'https?://[^\s<>"\x27]+'), (
        match,
      ) {
        final uri = Uri.tryParse(match[0]!);
        if (uri == null || uri.userInfo.isEmpty && !uri.hasQuery)
          return match[0]!;
        return uri
            .replace(
              userInfo: '',
              query: uri.hasQuery ? '[redacted]' : null,
              fragment: '',
            )
            .toString();
      });
    };
  }
}
