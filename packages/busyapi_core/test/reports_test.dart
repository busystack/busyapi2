import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test('SARIF retains producers, UTF-16 ranges, original files and incomplete status', () {
    final snapshot = AnalysisSnapshot(
      root: 'file:///project/api.yaml',
      resources: [
        {
          'id': 'file:///project/雪.yaml',
          'text': 'title: 😀\r\nvalue: 1',
          'identity': 'a',
          'generation': 1,
        },
      ],
    );
    final record = <String, dynamic>{
      'complete': false,
      'status': 'incomplete',
      'snapshot': snapshot.identity,
      'findings': [
        {
          'producer': 'policy',
          'producerVersion': '2',
          'code': 'required',
          'severity': 'warning',
          'message': 'Missing value',
          'resource': 'file:///project/雪.yaml',
          'range': [11, 16],
          'relatedLocations': [
            {
              'resource': 'file:///project/api.yaml',
              'range': [0, 1],
            },
          ],
        },
        {
          'producer': 'busyapi',
          'producerVersion': '0.1.0',
          'code': 'unlocated',
          'severity': 'error',
          'message': 'Unavailable',
        },
      ],
    };
    final result = CiReports.sarif([record], snapshots: [snapshot]);
    final runs = result['runs'] as List;
    expect(runs.length, 2);
    expect(runs[0]['tool']['driver']['name'], 'policy');
    expect(runs[0]['invocations'][0]['executionSuccessful'], false);
    final finding = runs[0]['results'][0];
    expect(
      finding['locations'][0]['physicalLocation']['artifactLocation']['uri'],
      'file:///project/雪.yaml',
    );
    expect(finding['locations'][0]['physicalLocation']['region'], {
      'startLine': 2,
      'startColumn': 1,
      'endLine': 2,
      'endColumn': 6,
    });
    expect(finding['relatedLocations'][0]['physicalLocation']['region'], {
      'charOffset': 0,
      'charLength': 1,
    });
    expect(runs[1]['results'][0].containsKey('locations'), false);
    expect(
      jsonEncode(CiReports.sarif([record], snapshots: [snapshot])),
      jsonEncode(result),
    );
  });

  test('redacted source identity is withheld, never replaced by a fictional location', () {
    final result = CiReports.sarif(
      [
        {
          'complete': true,
          'status': 'complete',
          'findings': [
            {
              'code': 'check',
              'message': 'Review',
              'resource': 'file:///project/synthetic-secret.yaml',
              'range': [0, 1],
            },
          ],
        },
      ],
      secrets: ['synthetic-secret'],
    );
    final finding = (result['runs'] as List).single['results'][0];
    expect(finding.containsKey('locations'), false);
    expect(jsonEncode(result), isNot(contains('synthetic-secret')));
  });
  test('failed empty analysis is not a clean SARIF invocation', () {
    final result = CiReports.sarif([
      {'status': 'operational-failure', 'complete': false, 'findings': []},
    ]);
    expect(
      (result['runs'] as List).single['invocations'][0]['executionSuccessful'],
      false,
    );
  });

  test(
    'JUnit represents actual cases and elapsed time, not untested operations',
    () {
      final cases = [
        for (final status in ['passed', 'failed', 'incomplete', 'skipped'])
          ContractCaseResult(
            name: 'case 雪 <$status>',
            operation: 'GET /things',
            snapshot: 'snapshot',
            status: status,
            complete: status != 'incomplete' && status != 'skipped',
            passed: status == 'passed',
            dispatched: status != 'skipped',
            elapsed: const Duration(milliseconds: 125),
            findings: [
              {
                'code': 'test',
                'message': 'synthetic-secret & <value> https://user:pass@localhost/api?token=bad',
              },
            ],
          ),
      ];
      final report = ContractTestReport(
        snapshot: 'snapshot',
        complete: false,
        passed: false,
        cases: cases,
        executedOperations: ['GET /things'],
        untestedOperations: ['POST /unselected'],
      );
      final xml = CiReports.junit(report, secrets: ['synthetic-secret']);
      expect(
        xml,
        contains(
          'tests="4" failures="1" errors="1" skipped="1" time="0.500000"',
        ),
      );
      expect(RegExp('<testcase ').allMatches(xml).length, 4);
      expect(xml, contains('&amp; &lt;value&gt;'));
      expect(xml, isNot(contains('synthetic-secret')));
      expect(xml, isNot(contains('user:pass')));
      expect(xml, isNot(contains('token=bad')));
      expect(xml, isNot(contains('/unselected')));
      expect(xml, contains('<failure '));
      expect(xml, contains('<error '));
      expect(xml, contains('<skipped '));
    },
  );

  test('report publication refuses existing and raced files and preserves cancellation', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-reports-');
    try {
      final path = '${temp.path}/雪.xml';
      await expectLater(
        CiReports.publish(
          path,
          'new',
          beforePublish: () async {
            await File(path).writeAsString('concurrent bytes');
          },
        ),
        throwsA(isA<AtomicFileAlreadyExistsException>()),
      );
      expect(await File(path).readAsString(), 'concurrent bytes');
      await expectLater(
        CiReports.publish(path, 'new'),
        throwsA(isA<AtomicFileAlreadyExistsException>()),
      );
      final cancel = RunCancellation()..cancel();
      await expectLater(
        CiReports.publish('${temp.path}/cancel', 'new', cancellation: cancel),
        throwsA(isA<CoreFailure>()),
      );
      expect(await File('${temp.path}/cancel').exists(), false);
      await CiReports.publish('${temp.path}/success', '雪');
      expect(await File('${temp.path}/success').readAsString(), '雪');
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
