import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final json in [false, true]) {
      test(
        'Server authoring validity and configurable advice share source, history and CLI outcomes $version $json',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-relationships-',
          );
          addTearDown(() => temp.delete(recursive: true));
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final file = File('${temp.path}/root.${json ? 'json' : 'yaml'}'),
              rules = File('${temp.path}/.spectral.yaml');
          final text = json
              ? '{"openapi":"$version","info":{"title":"Relationships 🐾","version":"1"},"paths":{},"servers":[{"url":"https://{host}.example.test/{region}","variables":{"region":{"default":"east","enum":["east"]},"unused":{"default":"data"}}}],"x-preserved":{"integer":900719925474099312345,"\$ref":"not a dependency"}}'
              : 'openapi: $version\r\ninfo: {title: "Relationships 🐾", version: "1"}\npaths: {}\nservers:\n  - url: https://{host}.example.test/{region}\n    variables:\n      region: {default: east, enum: [east]}\n      unused: {default: data}\nx-preserved: {integer: 900719925474099312345, \$ref: "not a dependency"} # exact';
          await file.writeAsBytes([239, 187, 191, ...utf8.encode(text)]);
          await rules.writeAsString('extends: busyapi:recommended\n');
          final original = await file.readAsBytes(),
              originalRules = await rules.readAsBytes();
          final project = await BusyProject.open(file.path, engine);
          addTearDown(project.close);
          final b = await project.buffer(file.uri.toString());
          final validity = await project.check(b.id);
          expect(validity['status'], 'complete', reason: jsonEncode(validity));
          final lint = await project.lint(b.id, failSeverity: 'warning');
          expect(lintExitCode(lint), 1);
          final findings = (lint['findings'] as List)
              .where(
                (f) => f['code'] == 'policy.rule.server-variable-declarations',
              )
              .toList();
          expect(findings, hasLength(2));
          expect(
            findings.every(
              (f) => f['resource'] == b.id && f['category'] == 'policy',
            ),
            true,
          );
          final cli = await Process.run('$testBundle/busyapi', [
            'lint',
            file.path,
            '--fail-severity',
            'warning',
            '--json',
          ]);
          expect(cli.exitCode, 1, reason: cli.stderr as String);
          final machine = jsonDecode(cli.stdout as String) as Map;
          expect(
            (machine['findings'] as List)
                .where(
                  (f) =>
                      f['code'] == 'policy.rule.server-variable-declarations',
                )
                .toList(),
            findings,
          );
          expect(machine['sourceSnapshots'], [lint['sourceSnapshot']]);
          expect(
            lintExitCode(await project.lint(b.id, failSeverity: 'error')),
            0,
          );
          project.store.replace(
            b.id,
            b.text.replaceFirst(
              json ? '"default":"east"' : 'default: east',
              json ? '"default":"west"' : 'default: west',
            ),
          );
          final invalid = await project.check(b.id);
          expect(invalid['status'], 'invalid');
          expect(invalid['complete'], true);
          final finding = (invalid['findings'] as List).firstWhere(
            (f) => f['code'] == 'server.variable.default-enum',
          );
          expect(finding['pointer'], '/servers/0/variables/region/default');
          expect(
            b.text.substring(
              finding['range'][0] as int,
              finding['range'][1] as int,
            ),
            contains('west'),
          );
          expect(await file.readAsBytes(), original);
          project.store.undo();
          expect(b.bytes(), original);
          final policy = await project.buffer(rules.uri.toString());
          project.store.replace(
            policy.id,
            '${policy.text}rules: {server-variable-declarations: off}\n',
          );
          expect(
            lintExitCode(await project.lint(b.id, failSeverity: 'warning')),
            0,
          );
          expect(
            lintExitCode(
              await project.lint(b.id, saved: true, failSeverity: 'warning'),
            ),
            1,
          );
          expect(await rules.readAsBytes(), originalRules);
          await project.save(policy);
          final clean = await Process.run('$testBundle/busyapi', [
            'lint',
            file.path,
            '--fail-severity',
            'warning',
            '--json',
          ]);
          expect(clean.exitCode, 0, reason: clean.stderr as String);
          expect(await file.readAsBytes(), original);
        },
      );
    }
  }
}
