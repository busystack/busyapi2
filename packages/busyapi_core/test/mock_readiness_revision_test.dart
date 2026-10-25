import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  for (final mutation in [
    'schema-version',
    'response-version',
    'response-configuration',
    'parameter-version',
    'parameter-configuration',
    'security-version',
  ]) {
    test('native mock readiness rejects $mutation before returning a running session', () async {
      final temp = await Directory.systemTemp.createTemp(
        'busyapi-mock-readiness-',
      );
      addTearDown(() => temp.delete(recursive: true));
      const original =
          'openapi: 3.0.4\ninfo: {title: Revision, version: "1"}\npaths: {/data: {post: {responses: {204: {description: Empty}}}}}\n';
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString(original);
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      final project = await BusyProject.open(file.path, engine);
      addTearDown(project.close);
      final plan = await project.prepareMock(file.uri.toString());
      addTearDown(plan.close);
      final schema = <String, String>{
        'name': 'hyperjump+busyapi-exact',
        'version': '1.18.0+15',
        'configuration': 'fixture-runtime',
      };
      final response = <String, String>{
        'name': 'busyapi-native-response',
        'version': '3',
        'configuration': 'response-wire-v3:fixture-runtime',
      };
      final parameter = <String, String>{
        'name': 'busyapi-native-parameters',
        'version': '3',
        'configuration': 'parameter-wire-v3:fixture-runtime',
      };
      final security = <String, String>{
        'name': 'busyapi-native-security',
        'version': '1',
        'configuration': 'security-wire-v1:fixture-runtime',
      };
      switch (mutation) {
        case 'schema-version':
          schema['version'] = 'obsolete';
        case 'response-version':
          response['version'] = '2';
        case 'response-configuration':
          response['configuration'] = 'obsolete';
        case 'parameter-version':
          parameter['version'] = '2';
        case 'parameter-configuration':
          parameter['configuration'] = 'obsolete';
        case 'security-version':
          security['version'] = 'obsolete';
      }
      final ready = {
        'version': 1,
        'event': 'ready',
        'snapshot': plan.snapshot.identity,
        'tool': 'Prism',
        'toolVersion': '5.15.11',
        'host': '127.0.0.1',
        'port': 1,
        'operations': 1,
        'nativeValidation': schema,
        'nativeResponseValidation': response,
        'nativeParameterValidation': parameter,
        'nativeSecurityValidation': security,
        'upstreamForwarding': false,
      };
      final helper = File('${temp.path}/controlled-runtime.cjs');
      await helper.writeAsString(
        'process.stdin.resume();process.stdin.on("end",()=>{process.stdout.write(JSON.stringify(${jsonEncode(ready)})+"\\n");setInterval(()=>{},1000);});\n',
      );
      try {
        final run = await plan.start(
          nodeExecutable: runtimeNode,
          helper: helper.path,
        );
        await run.stop();
        fail('An unrelated native evaluation revision was accepted');
      } on CoreFailure catch (error) {
        expect(error.code, 'mock.readiness');
      }
      expect(await file.readAsString(), original);
    });
  }
}
