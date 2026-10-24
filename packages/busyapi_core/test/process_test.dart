import 'test_support.dart';

import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test('code review uses actual awaited source-only IPC without running project JavaScript', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-code-review-');
    addTearDown(() => temp.delete(recursive: true));
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final marker = File('${temp.path}/must-not-exist');
    final text =
        'import fs from "node:fs";\n'
        'fs.writeFileSync(${jsonEncode(marker.path)}, "MUST NOT EXECUTE");\n'
        'export default async value => (await import("./helper.mjs")).check(value);';
    final result = await engine.request('inspectPolicyCode', {
      'resource': Uri.file('${temp.path}/function.mjs').toString(),
      'text': text,
      'format': 'module',
    });
    expect(result['version'], 1);
    expect(result['complete'], true);
    expect(
      (result['dependencies'] as List).map((value) => value['specifier']),
      ['node:fs', './helper.mjs'],
    );
    expect(await marker.exists(), false);
    final computed = await engine.request('inspectPolicyCode', {
      'resource': Uri.file('${temp.path}/computed.mjs').toString(),
      'text': 'export default value => import(value);',
      'format': 'module',
    });
    expect(computed['complete'], false);
    expect(
      (computed['issues'] as List).single['code'],
      'policy.code.dependency.computed',
    );
    expect(await marker.exists(), false);
  });
  test('four simultaneous snapshots share the bounded two-worker dispatcher without rejecting ordinary views', () async {
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    await engine.start();
    final root = 'file:///project/queued.yaml';
    final text =
        '# ${'bounded comment ' * 10000}\nopenapi: 3.2.1\ninfo: {title: Queue, version: "1"}\npaths: {}\n';
    final replies = await Future.wait([
      for (var i = 0; i < 4; i++)
        engine.request('analyse', {
          'root': root,
          'snapshot': 'snapshot-$i',
          'resources': [
            {
              'id': root,
              'text': text,
              'generation': i,
              'identity': 'source-$i',
            },
          ],
        }, requestId: 'view-$i'),
    ]);
    for (var i = 0; i < 4; i++) {
      expect(replies[i]['snapshot'], 'snapshot-$i');
      expect(replies[i]['status'], 'complete');
    }
  });
  test('cancellation has reserved control capacity when all four data slots are occupied', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-control-capacity-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final helper = File('${temp.path}/held.cjs');
    await helper.writeAsString(r'''
const hello={protocol:1,engineVersion:'0.1.0',nodeVersion:'24.15.0',range:'half-open',lineBase:1,columnBase:1,bom:'excluded',offsetUnit:'utf16',lineEndings:'raw'};
let bytes=Buffer.alloc(0),held=[];
function send(id,value){const data=Buffer.from(JSON.stringify({protocol:1,id,...value})),header=Buffer.alloc(4);header.writeUInt32BE(data.length);process.stdout.write(header);process.stdout.write(data);}
process.stdin.on('data',chunk=>{bytes=Buffer.concat([bytes,chunk]);while(bytes.length>=4&&bytes.length>=bytes.readUInt32BE(0)+4){const n=bytes.readUInt32BE(0),q=JSON.parse(bytes.subarray(4,4+n));bytes=bytes.subarray(4+n);
if(q.method==='hello')send(q.id,{ok:true,result:hello});
else if(q.method==='hold')held.push(q);
else if(q.method==='cancel'){for(const job of held.splice(0))send(job.id,job.id===q.params.id?{ok:false,error:{code:'cancelled',message:'Cancelled'}}:{ok:true,result:{snapshot:job.params.snapshot}});send(q.id,{ok:true,result:{cancelled:q.params.id}});}
else if(q.method==='shutdown'){send(q.id,{ok:true,result:{stopped:true}});process.stdin.destroy();}
}});
''');
    final engine = EngineProcess(executable: runtimeNode, helper: helper.path);
    addTearDown(engine.close);
    await engine.start();
    final futures = [
      for (var i = 0; i < 4; i++)
        engine.request('hold', {
          'snapshot': 'held-$i',
        }, requestId: i == 0 ? '2' : 'held-$i'),
    ];
    final cancelled = expectLater(
      futures[0],
      throwsA(isA<CoreFailure>().having((e) => e.code, 'code', 'cancelled')),
    );
    final retained = Future.wait(futures.skip(1));
    await Future<void>.delayed(Duration.zero);
    // Auto-generated control ids must not steal the explicitly owned "2".
    await engine.cancel('2');
    await cancelled;
    expect((await retained).map((r) => r['snapshot']), [
      'held-1',
      'held-2',
      'held-3',
    ]);
    await engine.cancel('4');
    expect((await engine.request('hello', const {}))['protocol'], 1);
  });
  for (final absent in ['runtime', 'helper', 'both']) {
    test(
      'bundled engine identifies missing $absent and supports opening-only retry',
      () async {
        final temp = Directory.systemTemp.createTempSync('busyapi-assets-');
        addTearDown(() => temp.deleteSync(recursive: true));
        final assets = Directory(
          '${temp.path}/relocated bundle/libexec/busyapi',
        )..createSync(recursive: true);
        final engine = EngineProcess.bundled(
          applicationExecutable:
              '${temp.path}/relocated bundle/busyapi-desktop',
        );
        addTearDown(engine.close);
        final runtime = File('${assets.path}/node');
        final helper = File('${assets.path}/engine.cjs');
        if (absent == 'helper') {
          await copyExecutableFixture(runtimeNode, runtime.path);
        }
        if (absent == 'runtime') File(runtimeHelper).copySync(helper.path);
        await expectLater(
          engine.start(),
          throwsA(
            isA<CoreFailure>()
                .having((e) => e.code, 'code', 'engine.assets')
                .having(
                  (e) => e.message,
                  'missing identities',
                  allOf([
                    if (absent != 'helper')
                      contains('Node 24.15.0 runtime: ${runtime.path}'),
                    if (absent != 'runtime')
                      contains('contract helper: ${helper.path}'),
                    if (absent == 'helper')
                      isNot(contains('runtime: ${runtime.path}')),
                    if (absent == 'runtime')
                      isNot(contains('helper: ${helper.path}')),
                  ]),
                ),
          ),
        );
        if (!runtime.existsSync()) {
          await copyExecutableFixture(runtimeNode, runtime.path);
        }
        File(runtimeHelper).copySync(helper.path);
        await engine.start();
        final projectPath = '${temp.path}/existing';
        await Initializer.create(
          destination: projectPath,
          title: 'test',
          apiVersion: '1.0.0',
          openapi: '3.1.2',
          format: 'yaml',
        );
        final contract = File('$projectPath/openapi.yaml');
        final manifest = File('$projectPath/busyapi.yaml');
        final original = contract.readAsBytesSync();
        final configuration = manifest.readAsBytesSync();
        final project = await BusyProject.open(projectPath, engine);
        addTearDown(project.close);
        final result = await project.check(project.roots.single.id);
        expect(result['status'], 'complete');
        expect(result['operations'], isEmpty);
        expect(contract.readAsBytesSync(), original);
        expect(manifest.readAsBytesSync(), configuration);
      },
    );
  }

  test('real worker transfers large Unicode results and remains reusable after errors', () async {
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final description = '😀 retained data\r\n' * 30000;
    Map<String, Object?> input(String snapshot, String title, String body) => {
      'root': 'file:///tmp/transfer.json',
      'snapshot': snapshot,
      'resources': [
        {
          'id': 'file:///tmp/transfer.json',
          'text': jsonEncode({
            'openapi': '3.2.1',
            'info': {'title': title, 'version': '1', 'description': body},
            'paths': {},
          }),
          'generation': 1,
          'identity': snapshot,
        },
      ],
    };
    final large = await engine.request(
      'analyse',
      input('large', '😀', description),
    );
    expect(large['snapshot'], 'large');
    expect(large['status'], 'complete');
    expect(large['info']['value']['description'], description);
    await expectLater(
      engine.request('unknown-method', input('error', 'Error', '')),
      throwsA(isA<CoreFailure>()),
    );
    for (var i = 0; i < 3; i++) {
      final small = await engine.request(
        'analyse',
        input('small-$i', 'Small$i', ''),
      );
      expect(small['snapshot'], 'small-$i');
      expect(small['info']['value']['title'], 'Small$i');
      expect(small['info']['value']['description'], '');
    }
  });
  test('large framed replies split headers and preserve out-of-order request ownership', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-framed-worker-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final helper = File('${temp.path}/frames.cjs');
    await helper.writeAsString(r'''
const hello = {protocol:1,engineVersion:'0.1.0',nodeVersion:'24.15.0',
 range:'half-open',lineBase:1,columnBase:1,bom:'excluded',offsetUnit:'utf16',lineEndings:'raw'};
let bytes=Buffer.alloc(0), held=[], output=Promise.resolve();
function reply(id,result) {
 const data=Buffer.from(JSON.stringify({protocol:1,id,ok:true,result}));
 const head=Buffer.alloc(4);head.writeUInt32BE(data.length);
 const frame=Buffer.concat([head,data]);
 output=output.then(async()=>{
  for(let offset=0;offset<frame.length;){
   const count=offset===0?1:offset===1?2:65536;
   const chunk=frame.subarray(offset,Math.min(frame.length,offset+count));offset+=chunk.length;
   await new Promise(resolve=>process.stdout.write(chunk,resolve));
  }
 });return output;
}
process.stdin.on('data',data=>{
 bytes=Buffer.concat([bytes,data]);
 while(bytes.length>=4 && bytes.length>=bytes.readUInt32BE(0)+4){
  const length=bytes.readUInt32BE(0), q=JSON.parse(bytes.subarray(4,4+length));
  bytes=bytes.subarray(4+length);
  if(q.method==='hello')reply(q.id,hello);
  else if(q.method==='pair'){
   held.push(q);if(held.length===2){for(const v of held.reverse())reply(v.id,{text:v.params.resources[0].text});held=[];}
  }else if(q.method==='shutdown')reply(q.id,{}).then(()=>process.exit(0));
 }
});
''');
    final engine = EngineProcess(executable: runtimeNode, helper: helper.path);
    addTearDown(engine.close);
    await engine.start();
    final texts = ['😀\r\nA' * 100000, 'B\n' * 200000];
    final replies = await Future.wait([
      for (var i = 0; i < texts.length; i++)
        engine.request('pair', {
          'resources': [
            {'text': texts[i]},
          ],
        }, requestId: 'pair-$i'),
    ]);
    expect(replies[0]['text'], texts[0]);
    expect(replies[1]['text'], texts[1]);
    expect((await engine.request('hello', {}))['protocol'], 1);
  });
  test('SIGKILL grouped publication reconciles an unrecorded receipt without overwriting external work', () async {
    final temp = await Directory.systemTemp.createTemp('busyapi-group-kill-');
    addTearDown(() => temp.delete(recursive: true));
    final destination = '${temp.path}/api';
    await Initializer.create(
      destination: destination,
      title: 'original',
      apiVersion: '1',
    );
    final part = File('$destination/part.yaml')
      ..writeAsStringSync('part original\n');
    final process = await Process.start('$testBundle/publication-child', [
      destination,
      '${temp.path}/state',
    ]);
    addTearDown(() async {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    });
    final stderrText = process.stderr.transform(utf8.decoder).join();
    expect(
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10)),
      'first-published',
    );
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    expect(await stderrText, isEmpty);
    part.writeAsStringSync('new external\n');
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    addTearDown(engine.close);
    final project = await BusyProject.open(destination, engine);
    addTearDown(project.close);
    final publications = PublicationStore('${temp.path}/state');
    final record = (await publications.inspect(project)).single;
    expect(record['published'], isEmpty);
    expect(record['outcomes'][0]['outcome'], 'published');
    expect(record['outcomes'][1]['outcome'], 'conflict');
    final before = File('$destination/openapi.yaml').readAsBytesSync();
    await publications.recover(
      project,
      Map<String, dynamic>.from(record['outcomes'][1] as Map),
    );
    final recovered = project.store.get(part.uri.toString());
    expect(recovered.text, 'part draft\n');
    expect(recovered.externalConflict, true);
    expect(part.readAsStringSync(), 'new external\n');
    expect(File('$destination/openapi.yaml').readAsBytesSync(), before);
  });
  test(
    'SIGKILL recovery restores into buffer while newer disk survives',
    () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-crash-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/api.yaml');
      await file.writeAsString('info: {title: original}\n');
      final process = await Process.start('$testBundle/recovery-child', [
        file.path,
        '${temp.path}/state',
      ]);
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      });
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await file.writeAsString('info: {title: newer}\n');
      final store = RecoveryStore('${temp.path}/state');
      final records = await store.available();
      expect(records.length, 1);
      final form = FormSession.restore(
        records.single['form'] as Map<String, dynamic>,
      );
      expect(form.values['example'], '{invalid unfinished example');
      expect(form.target.buffer, records.single['id']);
      final buffer = DocumentBuffer.decode(file.path, await file.readAsBytes());
      await store.adopt(records.single, buffer, form: form);
      expect(buffer.text, contains('draft'));
      expect(buffer.externalConflict, true);
      expect(await file.readAsString(), contains('newer'));
    },
  );
  test(
    'IPC malformed and truncated frames never complete successfully',
    () async {
      final temp = await Directory.systemTemp.createTemp('busyapi-ipc-');
      addTearDown(() => temp.delete(recursive: true));
      for (final script in [
        "process.stdout.write(Buffer.from([0,0,0,5,123]));process.exit(0)",
        "process.stdout.write(Buffer.from([255,255,255,255]));setTimeout(()=>{},10000)",
      ]) {
        final f = File('${temp.path}/broken.cjs');
        await f.writeAsString(script);
        final engine = EngineProcess(
          executable: runtimeNode,
          helper: f.path,
          timeout: const Duration(seconds: 2),
        );
        await expectLater(engine.start(), throwsA(isA<CoreFailure>()));
        await engine.close();
      }
    },
  );
  test(
    'worker cancellation is acknowledged and another request can run',
    () async {
      final engine = EngineProcess(
        executable: runtimeNode,
        helper: runtimeHelper,
      );
      addTearDown(engine.close);
      await engine.start();
      final text =
          'info: {title: A}\n' +
          List.filled(
            30000,
            '# a sufficiently large trusted cancellation fixture\n',
          ).join();
      final request = engine.request('analyse', {
        'root': 'file:///a.yaml',
        'snapshot': 'cancel-test',
        'resources': [
          {
            'id': 'file:///a.yaml',
            'text': text,
            'generation': 1,
            'identity': 'x',
          },
        ],
      }, requestId: 'cancel-job');
      final rejected = expectLater(request, throwsA(isA<CoreFailure>()));
      await engine.cancel('cancel-job');
      await rejected;
      expect((await engine.request('hello', {}))['protocol'], 1);
    },
  );
}
