import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

class _ReviewEngine extends EngineProcess {
  _ReviewEngine() : super(executable: runtimeNode, helper: runtimeHelper);
  Completer<void>? entered, release;
  bool malformed = false;
  bool runtimeFailure = false;
  int executions = 0, runtimeGateRemaining = 0, runtimeGateEntered = 0;
  Completer<void>? runtimeGate;
  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'policyRuntime' && runtimeFailure)
      throw CoreFailure('policy.assets', 'Controlled missing isolated runtime');
    final result = await super.request(method, params, requestId: requestId);
    if (method == 'policyRuntime' && runtimeGateRemaining > 0) {
      final gate = runtimeGate ??= Completer<void>();
      runtimeGateRemaining--;
      if (++runtimeGateEntered == 2) {
        runtimeGate = null;
        runtimeGateEntered = 0;
        gate.complete();
      }
      await gate.future;
    }
    if (method == 'govern' && (params['policy'] as Map?)?['execution'] != null)
      executions++;
    if (method == 'reviewPolicyCode' && (result['requests'] as List).isEmpty) {
      entered?.complete();
      entered = null;
      final gate = release;
      release = null;
      if (gate != null) await gate.future;
      if (malformed)
        return {...result, 'complete': true, 'requests': 'not-work'};
    }
    return result;
  }
}

void main() {
  late Directory temp;
  late File root, helper, main, policy;
  late _ReviewEngine engine;
  late BusyProject project;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('busyapi-code-review 雪 ');
    root = File('${temp.path}/root.yaml')
      ..writeAsStringSync(
        'openapi: 3.2.1\ninfo: {title: Review, version: "1"}\npaths: {}\n',
      );
    policy = File('${temp.path}/.spectral.yaml')
      ..writeAsStringSync('# retained 😀\r\nfunctions: [custom]\r\nrules: {}');
    Directory('${temp.path}/functions').createSync();
    main = File('${temp.path}/functions/custom.js')
      ..writeAsStringSync(
        "const helper=require('./helper.cjs');module.exports=value=>helper(value);\n",
      );
    helper = File('${temp.path}/functions/helper.cjs')
      ..writeAsStringSync("// exact 😀\r\nmodule.exports=()=>[];\n");
    engine = _ReviewEngine();
    project = await BusyProject.open(root.path, engine);
  });
  tearDown(() async {
    project.close();
    await engine.close();
    await temp.delete(recursive: true);
  });
  test('unrelated API mappings do not become code scopes or exhaust the code review bound', () async {
    final manifest = File('${temp.path}/busyapi.yaml')
      ..writeAsStringSync(
        'version: 1\nroots: [{name: Main, path: root.yaml}]\nresourceMappings:\n' +
            List.generate(
              80,
              (index) =>
                  '  "https://api$index.invalid/contract": mapped$index.json\n',
            ).join(),
      );
    final before = manifest.readAsBytesSync();
    final review = await project.reviewPolicyCode(root.uri.toString());
    expect(review.complete, true, reason: jsonEncode(review.result));
    expect(review.result['scopes'], [
      Uri.directory('${temp.path}/').toString(),
    ]);
    expect(manifest.readAsBytesSync(), before);
  });
  test('source-only acquisition preserves every file and exposes inspectable transitive identities', () async {
    final before = {
      for (final file in [root, helper, main, policy])
        file.path: file.readAsBytesSync(),
    };
    final review = await project.reviewPolicyCode(root.uri.toString());
    expect(review.complete, true, reason: jsonEncode(review.result));
    expect(review.result['modules'], hasLength(2));
    expect(review.result['bindings'], hasLength(1));
    expect(
      review.resources
          .where((r) => r['id'] == helper.uri.toString())
          .single['text'],
      helper.readAsStringSync(),
    );
    expect(review.unsaved, false);
    expect(() => review.result['complete'] = false, throwsUnsupportedError);
    await project.verifyPolicyCodeReview(review);
    for (final entry in before.entries)
      expect(File(entry.key).readAsBytesSync(), entry.value);
    // A review is not execution approval. Ordinary lint must still fail closed.
    final result = await project.lint(root.uri.toString());
    expect(result['categories']['policy']['complete'], false);
    expect(lintExitCode(result), 2);
  });
  test('explicit exact-identity approval executes once through the real isolated process', () async {
    policy.writeAsStringSync(
      'functions: [custom]\nrules:\n  approved:\n    given: \$.info.title\n    then: {function: custom}\n',
    );
    helper.writeAsStringSync(
      'module.exports=async()=>[{message:"reviewed finding"}];',
    );
    final review = await project.reviewPolicyCode(root.uri.toString());
    final trust = await project.policyCodeTrust(review);
    await expectLater(
      project.approvePolicyCode(review, expectedIdentity: '0' * 64),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'policy.code.approval.changed',
        ),
      ),
    );
    final approval = await project.approvePolicyCode(
      review,
      expectedIdentity: trust['identity'] as String,
    );
    final result = await project.lint(
      root.uri.toString(),
      codeApproval: approval,
    );
    expect(result['complete'], true, reason: jsonEncode(result));
    expect(
      (result['findings'] as List).where(
        (v) => v['code'] == 'policy.rule.approved',
      ),
      hasLength(1),
    );
    expect(
      result['categories']['policy']['coverage'],
      contains('reviewed-isolated-code'),
    );
    await expectLater(
      project.lint(root.uri.toString(), codeApproval: approval),
      throwsA(
        isA<CoreFailure>().having(
          (e) => e.code,
          'code',
          'policy.code.approval.changed',
        ),
      ),
    );
    final unapproved = await project.lint(root.uri.toString());
    expect(unapproved['categories']['policy']['complete'], false);
    expect(
      helper.readAsStringSync(),
      'module.exports=async()=>[{message:"reviewed finding"}];',
    );
  });
  test('a declarative executable selector has a reviewable source identity without inventing code modules', () async {
    policy.writeAsStringSync(
      'rules:\n  reviewed:\n    given: \$.tags[?(@.name === "one")]\n    then: {field: description, function: truthy}\n',
    );
    root.writeAsStringSync(
      'openapi: 3.2.1\ninfo: {title: Review, version: "1"}\npaths: {}\ntags: [{name: one}, {name: two}]\n',
    );
    final before = policy.readAsBytesSync();
    final review = await project.reviewPolicyCode(root.uri.toString());
    expect(review.complete, true, reason: jsonEncode(review.result));
    expect(review.result['declarations'], isEmpty);
    expect(review.result['modules'], isEmpty);
    expect(
      review.resources.any((source) => source['id'] == policy.uri.toString()),
      true,
    );
    final trust = await project.policyCodeTrust(review);
    final approval = await project.approvePolicyCode(
      review,
      expectedIdentity: trust['identity'] as String,
    );
    final result = await project.lint(
      root.uri.toString(),
      codeApproval: approval,
    );
    expect(result['complete'], true, reason: jsonEncode(result));
    final findings = (result['findings'] as List).where(
      (value) => value['code'] == 'policy.rule.reviewed',
    );
    expect(findings.map((value) => value['pointer']), ['/tags/0']);
    final unapproved = await project.lint(root.uri.toString());
    expect(unapproved['categories']['policy']['complete'], false);
    expect(policy.readAsBytesSync(), before);
  });
  test(
    'changed transitive code invalidates explicit approval before execution',
    () async {
      final review = await project.reviewPolicyCode(root.uri.toString());
      final trust = await project.policyCodeTrust(review);
      final approval = await project.approvePolicyCode(
        review,
        expectedIdentity: trust['identity'] as String,
      );
      helper.writeAsStringSync(
        'module.exports=()=>[{message:"concurrent code"}];',
      );
      await expectLater(
        project.lint(root.uri.toString(), codeApproval: approval),
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'policy.stale'),
        ),
      );
      final changed = await project.reviewPolicyCode(root.uri.toString());
      expect(changed.identity, isNot(review.identity));
    },
  );
  test('concurrent lint cannot spend the same one-run approval twice across awaited checks', () async {
    final review = await project.reviewPolicyCode(root.uri.toString());
    final trust = await project.policyCodeTrust(review);
    final approval = await project.approvePolicyCode(
      review,
      expectedIdentity: trust['identity'] as String,
    );
    await project.check(root.uri.toString());
    engine.runtimeGateRemaining = 4;
    final results = await Future.wait([
      for (var index = 0; index < 2; index++)
        project
            .lint(root.uri.toString(), codeApproval: approval)
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);
    expect(engine.executions, 1);
    expect(
      results.whereType<Map>().where((value) => value['complete'] == true),
      hasLength(1),
    );
    expect(
      results.any(
        (value) =>
            value is CoreFailure &&
                value.code == 'policy.code.approval.changed' ||
            value is Map && value['complete'] == false,
      ),
      true,
    );
  });
  test('monitoring tracks unopened transitive code and negative package lookup observations', () async {
    final review = await project.reviewPolicyCode(root.uri.toString());
    final trust = await project.policyCodeTrust(review);
    final approval = await project.approvePolicyCode(
      review,
      expectedIdentity: trust['identity'] as String,
    );
    final result = await project.lint(
      root.uri.toString(),
      codeApproval: approval,
    );
    expect(result['categories']['policy']['complete'], true);
    helper.writeAsStringSync(
      'module.exports=()=>[{message:"changed helper"}];',
    );
    final sourceChange = await project.refreshResources();
    expect(sourceChange.resources, contains(helper.uri.toString()));
    expect(sourceChange.roots, contains(root.uri.toString()));
    final package = File('${temp.path}/functions/package.json')
      ..writeAsStringSync('{"type":"commonjs"}');
    final packageChange = await project.refreshResources();
    expect(packageChange.resources, contains(package.uri.toString()));
    expect(packageChange.roots, contains(root.uri.toString()));
    final unchanged = await project.refreshResources();
    expect(unchanged.resources, isEmpty);
  });
  test('missing isolated assets do not create approval or silently fall back to a worker', () async {
    final review = await project.reviewPolicyCode(root.uri.toString());
    engine.runtimeFailure = true;
    await expectLater(
      project.policyCodeTrust(review),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'policy.assets'),
      ),
    );
    await expectLater(
      project.approvePolicyCode(review, expectedIdentity: '0' * 64),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'policy.assets'),
      ),
    );
    final unapproved = await project.lint(root.uri.toString());
    expect(unapproved['categories']['policy']['complete'], false);
  });
  test('working overlays and saved code have distinct trust identities without publishing either', () async {
    final disk = helper.readAsBytesSync(),
        buffer = await project.buffer(helper.uri.toString());
    project.store.replace(buffer.id, '// working 😀\nmodule.exports=()=>[];');
    final working = await project.reviewPolicyCode(root.uri.toString());
    final saved = await project.reviewPolicyCode(
      root.uri.toString(),
      saved: true,
    );
    expect(working.complete, true);
    expect(saved.complete, true);
    expect(working.identity, isNot(saved.identity));
    expect(working.unsaved, true);
    expect(saved.unsaved, false);
    expect(helper.readAsBytesSync(), disk);
    final again = await project.reviewPolicyCode(root.uri.toString());
    expect(again.identity, working.identity);
    project.store.replace(buffer.id, buffer.text + '\n// advanced generation');
    await expectLater(
      project.verifyPolicyCodeReview(working),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'policy.stale')),
    );
    await project.verifyPolicyCodeReview(saved);
  });
  test(
    'changed transitive source after collection rejects the whole review',
    () async {
      final entered = engine.entered = Completer<void>(),
          release = engine.release = Completer<void>();
      final pending = project.reviewPolicyCode(root.uri.toString());
      await entered.future;
      helper.writeAsStringSync('// concurrent source\nmodule.exports=()=>[];');
      release.complete();
      await expectLater(
        pending,
        throwsA(
          isA<CoreFailure>().having((e) => e.code, 'code', 'policy.stale'),
        ),
      );
      expect(helper.readAsStringSync(), startsWith('// concurrent source'));
    },
  );
  test('a newly created higher-priority package declaration invalidates an earlier review', () async {
    final review = await project.reviewPolicyCode(root.uri.toString());
    File('${temp.path}/functions/package.json')
        .writeAsStringSync('{"type":"module"}');
    await expectLater(
      project.verifyPolicyCodeReview(review),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'policy.stale')),
    );
    final next = await project.reviewPolicyCode(root.uri.toString());
    expect(next.identity, isNot(review.identity));
  });
  test(
    'unavailable and symlink code never turns into an approved empty closure',
    () async {
      helper.deleteSync();
      final missing = await project.reviewPolicyCode(root.uri.toString());
      expect(missing.complete, false);
      Link(helper.path).createSync(root.path);
      final symlink = await project.reviewPolicyCode(root.uri.toString());
      expect(symlink.complete, false);
      expect(
        (symlink.result['issues'] as List).any(
          (v) => v['code'] == 'policy.code.resource.denied',
        ),
        true,
      );
    },
  );
  test('logical mappings retain the original code import base and not the physical sibling', () async {
    final code = File('${temp.path}/remote.cjs')
      ..writeAsStringSync(
        "const helper=require('./helper.cjs');module.exports=value=>helper(value);\n",
      );
    policy.writeAsStringSync(
      'extends: ["https://policy.invalid/rules/main.cjs"]\nrules: {}\n',
    );
    await project.approveResource(
      'https://policy.invalid/rules/main.cjs',
      code.uri.toString(),
    );
    await project.approveResource(
      'https://policy.invalid/rules/helper.cjs',
      helper.uri.toString(),
    );
    // Node package lookup metadata needs explicit mappings too; a mapping is
    // never permission to silently retrieve a remote package declaration.
    final denied = await project.reviewPolicyCode(root.uri.toString());
    expect(denied.complete, false);
    expect((denied.result['issues'] as List).isNotEmpty, true);
    expect(code.readAsStringSync(), contains("require('./helper.cjs')"));
  });
  test('cancellation, project closure and malformed work cannot produce an approvable result', () async {
    await expectLater(
      project.reviewPolicyCode(root.uri.toString(), cancelled: () => true),
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    engine.malformed = true;
    await expectLater(
      project.reviewPolicyCode(root.uri.toString()),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'policy.protocol'),
      ),
    );
    engine.malformed = false;
    final review = await project.reviewPolicyCode(root.uri.toString());
    project.close();
    await expectLater(
      project.verifyPolicyCodeReview(review),
      throwsA(
        isA<CoreFailure>().having((e) => e.code, 'code', 'access.closed'),
      ),
    );
  });
}
