import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final version in ['3.1.2', '3.2.1']) {
    for (final selectorOnly in [false, true]) {
      test(
        'headless code review and one-run execution agree with the core $version selector-only=$selectorOnly',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'busyapi-code-cli ü ',
          );
          addTearDown(() => temp.delete(recursive: true));
          final root = File('${temp.path}/root.json')
            ..writeAsStringSync(
              '{"openapi":"$version","info":{"title":"Review","version":"1"},"paths":{},"tags":[{"name":"one"}]}',
            );
          final policy = File('${temp.path}/.spectral.yaml')
            ..writeAsStringSync(
              selectorOnly
                  ? 'rules:\n  reviewed:\n    given: \$.tags[?(@.name === "one")]\n    then: {field: description, function: truthy}\n'
                  : 'functions: [custom]\nrules:\n  reviewed:\n    given: \$.info.title\n    then: {function: custom}\n',
            );
          Directory('${temp.path}/functions').createSync();
          final function = File('${temp.path}/functions/custom.js')
            ..writeAsStringSync(
              '// not routine output: ghp_a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8\nmodule.exports=async()=>[{message:"reviewed source"}];',
            );
          final bytes = {
            for (final file in [root, policy, function])
              file.path: file.readAsBytesSync(),
          };
          Future<ProcessResult> cli(List<String> options) => Process.run(
            '$testBundle/busyapi',
            ['lint', root.path, ...options, '--json'],
            environment: {'PATH': '', 'LANG': 'C.UTF-8'},
            includeParentEnvironment: false,
          );
          final review = await cli(['--review-code']);
          expect(
            review.exitCode,
            0,
            reason: '${review.stdout}\n${review.stderr}',
          );
          final reviewed = jsonDecode(review.stdout as String);
          expect(reviewed['executed'], false);
          expect(
            reviewed['codeReview']['modules'],
            hasLength(selectorOnly ? 0 : 1),
          );
          expect(review.stdout, isNot(contains('ghp_a1B2')));
          final identity = reviewed['trust']['identity'] as String;
          final wrong = await cli(['--approve-code', '0' * 64]);
          expect(wrong.exitCode, 2);
          expect(
            jsonDecode(wrong.stdout as String)['error']['code'],
            'policy.code.approval.changed',
          );
          final unapproved = await cli([]);
          expect(unapproved.exitCode, 2);
          final executed = await cli(['--approve-code', identity]);
          expect(
            executed.exitCode,
            1,
            reason: '${executed.stdout}\n${executed.stderr}',
          );
          final output = jsonDecode(executed.stdout as String);
          expect(output['complete'], true);
          expect(output['status'], 'invalid');
          final engine = EngineProcess(
            executable: runtimeNode,
            helper: runtimeHelper,
          );
          addTearDown(engine.close);
          final project = await BusyProject.open(root.path, engine);
          addTearDown(project.close);
          final captured = await project.reviewPolicyCode(
            root.uri.toString(),
            saved: true,
          );
          final trust = await project.policyCodeTrust(captured);
          expect(trust['identity'], identity);
          final approved = await project.approvePolicyCode(
            captured,
            expectedIdentity: identity,
          );
          final live = await project.lint(
            root.uri.toString(),
            saved: true,
            codeApproval: approved,
          );
          expect(output['findings'], live['findings']);
          for (final entry in bytes.entries)
            expect(File(entry.key).readAsBytesSync(), entry.value);
          final changed = selectorOnly ? policy : function;
          changed.writeAsStringSync(
            changed.readAsStringSync() +
                (selectorOnly
                    ? '\n# changed identity'
                    : '\n// changed identity'),
          );
          final stale = await cli(['--approve-code', identity]);
          expect(stale.exitCode, 2);
          expect(
            jsonDecode(stale.stdout as String)['error']['code'],
            'policy.code.approval.changed',
          );
          expect(File('${temp.path}/busyapi.yaml').existsSync(), false);
        },
      );
    }
  }
}
