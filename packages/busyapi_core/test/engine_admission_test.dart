import 'dart:convert';
import 'dart:io';

import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

// A narrow IPC boundary: held requests only complete after cancellation. The
// helper records receipt, so a queued/cancelled request cannot pass by merely
// returning a plausible result without exercising actual admission.
Future<EngineProcess> heldEngine({Duration? timeout}) async {
  final temp = await Directory.systemTemp.createTemp('busyapi-admission-');
  addTearDown(() => temp.delete(recursive: true));
  final helper = File('${temp.path}/held.cjs');
  await helper.writeAsString(r'''
const hello={protocol:1,engineVersion:'0.1.0',nodeVersion:'24.15.0',range:'half-open',lineBase:1,columnBase:1,bom:'excluded',offsetUnit:'utf16',lineEndings:'raw'};
let bytes=Buffer.alloc(0),held=new Map(),received=[],cancelled=[];
function send(id,value){const data=Buffer.from(JSON.stringify({protocol:1,id,...value})),header=Buffer.alloc(4);header.writeUInt32BE(data.length);process.stdout.write(header);process.stdout.write(data);}
process.stdin.on('data',chunk=>{bytes=Buffer.concat([bytes,chunk]);while(bytes.length>=4&&bytes.length>=bytes.readUInt32BE(0)+4){const n=bytes.readUInt32BE(0),q=JSON.parse(bytes.subarray(4,4+n));bytes=bytes.subarray(4+n);
if(q.method==='hello')send(q.id,{ok:true,result:{...hello,received,cancelled}});
else if(q.method==='cancel'){
 cancelled.push(q.params.id);const job=held.get(q.params.id);held.delete(q.params.id);
 setTimeout(()=>{if(job)send(job.id,{ok:false,error:{code:'cancelled',message:'Cancelled'}});send(q.id,{ok:true,result:{cancelled:q.params.id}});},30);
}else if(q.method==='shutdown'){for(const job of held.values())send(job.id,{ok:false,error:{code:'cancelled',message:'Closed'}});held.clear();send(q.id,{ok:true,result:{stopped:true}});process.stdin.destroy();}
else if(q.params.failure)send(q.id,{ok:false,error:q.params.failure});
else {received.push(q.id);if(q.params.crash)setTimeout(()=>process.exit(7),30);if(q.params.hold)held.set(q.id,q);else send(q.id,{ok:true,result:{snapshot:q.params.snapshot,resources:q.params.resources}});}
}});
''');
  final engine = EngineProcess(
    executable: runtimeNode,
    helper: helper.path,
    timeout: timeout ?? const Duration(seconds: 5),
  );
  addTearDown(engine.close);
  await engine.start();
  return engine;
}

Matcher failure(String code) =>
    isA<CoreFailure>().having((error) => error.code, 'code', code);

Future<void> received(EngineProcess engine, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (true) {
    if (((await engine.request('hello', const {}))['received'] as List)
            .length ==
        count) {
      return;
    }
    if (DateTime.now().isAfter(deadline))
      fail('Helper did not receive $count requests');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('engine errors retain typed unsupported meaning and exact source locations independently of their code', () async {
    final engine = await heldEngine();
    await expectLater(
      engine.request('inspect', {
        'failure': {
          'code': 'request.multipart.encoding',
          'message': 'A serialization limitation',
          'kind': 'unsupported',
          'source': {
            'resource': 'file:///fixture/雪.yaml',
            'pointer': '/encoding/value',
            'range': [2, 7],
          },
        },
      }),
      throwsA(
        isA<CoreFailure>()
            .having((value) => value.code, 'code', 'request.multipart.encoding')
            .having((value) => value.unsupported, 'unsupported', isTrue)
            .having((value) => value.kind, 'kind', CoreFailureKind.unsupported)
            .having(
              (value) => value.source?.resource,
              'resource',
              'file:///fixture/雪.yaml',
            )
            .having((value) => value.source?.range.start, 'start', 2)
            .having((value) => value.source?.range.end, 'end', 7),
      ),
    );
    await expectLater(
      engine.request('inspect', {
        'failure': {
          'code': 'existing.error',
          'message': 'Existing operational failure',
        },
      }),
      throwsA(
        isA<CoreFailure>().having(
          (value) => value.kind,
          'kind',
          CoreFailureKind.operational,
        ),
      ),
    );
  });
  test('existing unsupported error codes retain their meaning without new metadata', () async {
    final engine = await heldEngine();
    await expectLater(
      engine.request('inspect', {
        'failure': {
          'code': 'existing.unsupported',
          'message': 'A prior limitation',
        },
      }),
      throwsA(
        isA<CoreFailure>().having(
          (value) => value.kind,
          'kind',
          CoreFailureKind.unsupported,
        ),
      ),
    );
  });
  test('unknown error kinds and malformed source locations fail the protocol instead of becoming ordinary results', () async {
    for (final extra in [
      {'kind': 'success'},
      {
        'source': {
          'resource': false,
          'pointer': '',
          'range': [0, 1],
        },
      },
      {
        'source': {
          'resource': 'file:///fixture.yaml',
          'pointer': '',
          'range': [-1, 0],
        },
      },
      {
        'source': {
          'resource': 'file:///fixture.yaml',
          'pointer': '',
          'range': [2, 1],
        },
      },
      {
        'source': {
          'resource': 'file:///fixture.yaml',
          'pointer': '',
          'range': [0, false],
        },
      },
    ]) {
      final engine = await heldEngine();
      await expectLater(
        engine.request('inspect', {
          'failure': {
            'code': 'claimed.error',
            'message': 'Malformed metadata',
            ...extra,
          },
        }),
        throwsA(failure('engine.json')),
      );
    }
  });

  test(
    'large documentation display waits behind Source and bounded native pages',
    () async {
      final engine = await heldEngine();
      final held = [
        for (var i = 0; i < 4; i++)
          expectLater(
            engine.request('inspect', {'hold': true}, requestId: 'held-$i'),
            throwsA(failure('cancelled')),
          ),
      ];
      await received(engine, 4);
      final display = engine.request('referenceDisplay', {
        'snapshot': 'display',
      }, requestId: 'display');
      final page = engine.request('referencePage', {
        'snapshot': 'page',
      }, requestId: 'page');
      final source = engine.request('analyse', {
        'snapshot': 'source',
      }, requestId: 'source');
      await Future<void>.delayed(Duration.zero);
      await engine.cancel('held-0');
      expect((await source)['snapshot'], 'source');
      expect((await page)['snapshot'], 'page');
      expect((await display)['snapshot'], 'display');
      expect((await engine.request('hello', const {}))['received'], [
        'held-0',
        'held-1',
        'held-2',
        'held-3',
        'source',
        'page',
        'display',
      ]);
      await Future.wait([for (var i = 1; i < 4; i++) engine.cancel('held-$i')]);
      await Future.wait(held);
    },
  );
  test('bounded foreground waiting captures input, prioritizes work and reserves cancellation capacity', () async {
    final engine = await heldEngine();
    final held = [
      for (var i = 0; i < 4; i++)
        expectLater(
          engine.request('inspect', {'hold': true}, requestId: 'held-$i'),
          throwsA(failure('cancelled')),
        ),
    ];
    await received(engine, 4);
    final resources = [
      {'text': 'captured 雪😀\r\n', 'generation': 7},
    ];
    final view = engine.request('referencePage', {
      'snapshot': 'view',
      'resources': resources,
    }, requestId: 'view');
    final evaluation = engine.request('evaluateSchemas', {
      'snapshot': 'evaluation',
    }, requestId: 'evaluation');
    final proposal = engine.request('propose', {
      'snapshot': 'proposal',
    }, requestId: 'proposal');
    final bundle = engine.request('deriveBundle', {
      'snapshot': 'bundle',
    }, requestId: 'bundle');
    // Let each public request cross its asynchronous start boundary. Mutating
    // caller-owned containers afterwards must not alter the captured request.
    await Future<void>.delayed(Duration.zero);
    resources[0]['text'] = 'retargeted';
    resources.add({'text': 'extra', 'generation': 99});
    expect((await engine.request('hello', const {}))['received'], [
      'held-0',
      'held-1',
      'held-2',
      'held-3',
    ]);
    await expectLater(
      engine.request('inspect', const {}, requestId: 'ninth'),
      throwsA(failure('engine.queue')),
    );
    await expectLater(
      engine.request('inspect', const {}, requestId: 'view'),
      throwsA(failure('engine.identity')),
    );
    final firstCancel = engine.cancel('held-0');
    await firstCancel;
    expect((await proposal)['snapshot'], 'proposal');
    expect((await bundle)['snapshot'], 'bundle');
    expect((await view)['resources'], [
      {'text': 'captured 雪😀\r\n', 'generation': 7},
    ]);
    expect((await evaluation)['snapshot'], 'evaluation');
    expect((await engine.request('hello', const {}))['received'], [
      'held-0',
      'held-1',
      'held-2',
      'held-3',
      'proposal',
      'bundle',
      'view',
      'evaluation',
    ]);
    await Future.wait([for (var i = 1; i < 4; i++) engine.cancel('held-$i')]);
    await Future.wait(held);
  });

  test('cancelling queued ownership never dispatches it and prefix cancellation drains all owners', () async {
    final engine = await heldEngine();
    final held = [
      for (var i = 0; i < 4; i++)
        expectLater(
          engine.request('inspect', {'hold': true}, requestId: 'scope-held-$i'),
          throwsA(failure('cancelled')),
        ),
    ];
    await received(engine, 4);
    final queued = expectLater(
      engine.request('inspect', {'hold': true}, requestId: 'scope-queued'),
      throwsA(failure('cancelled')),
    );
    await Future<void>.delayed(Duration.zero);
    await engine.cancel('scope-queued');
    await queued;
    expect((await engine.request('hello', const {}))['received'], [
      'scope-held-0',
      'scope-held-1',
      'scope-held-2',
      'scope-held-3',
    ]);
    await engine.cancelPrefix('scope-');
    await Future.wait(held);
    final result = await engine.request('hello', const {});
    expect(result['cancelled'], [
      'scope-held-0',
      'scope-held-1',
      'scope-held-2',
      'scope-held-3',
    ]);
  });

  test('prefix cancellation marks queued siblings before releasing running capacity', () async {
    final engine = await heldEngine();
    final requests = [
      for (var i = 0; i < 8; i++)
        expectLater(
          engine.request('inspect', {'hold': true}, requestId: 'siblings-$i'),
          throwsA(failure('cancelled')),
        ),
    ];
    await received(engine, 4);
    await engine.cancelPrefix('siblings-');
    await Future.wait(requests);
    expect((await engine.request('hello', const {}))['received'], [
      'siblings-0',
      'siblings-1',
      'siblings-2',
      'siblings-3',
    ]);
  });

  test('crashed helper fails dispatched and waiting owners instead of returning empty success', () async {
    final engine = await heldEngine();
    final requests = [
      for (var i = 0; i < 8; i++)
        expectLater(
          engine.request('inspect', {
            'hold': true,
            'crash': i == 0,
          }, requestId: 'crash-$i'),
          throwsA(failure('engine.exit')),
        ),
    ];
    await Future.wait(requests);
    expect((await engine.request('hello', const {}))['received'], isEmpty);
  });

  test('closing during launch cannot leave an owned helper running or permit later requests', () async {
    final engine = EngineProcess(
      executable: runtimeNode,
      helper: runtimeHelper,
    );
    final opening = expectLater(
      engine.start(),
      throwsA(failure('engine.closed')),
    );
    await engine.close();
    await opening;
    await expectLater(
      engine.request('hello', const {}),
      throwsA(failure('engine.closed')),
    );
  });

  test(
    'waiting deadlines fail truthfully without dispatch and remain bounded',
    () async {
      final engine = await heldEngine(
        timeout: const Duration(milliseconds: 250),
      );
      final requests = [
        for (var i = 0; i < 8; i++)
          expectLater(
            engine.request('inspect', {'hold': true}, requestId: 'timeout-$i'),
            throwsA(failure('engine.timeout')),
          ),
      ];
      await Future.wait(requests);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect((await engine.request('hello', const {}))['received'], [
        'timeout-0',
        'timeout-1',
        'timeout-2',
        'timeout-3',
      ]);
    },
  );

  test('close fails every waiting request and rejects later reuse without helper restart', () async {
    final engine = await heldEngine();
    final requests = [
      for (var i = 0; i < 8; i++)
        expectLater(
          engine.request('inspect', {'hold': true}, requestId: 'close-$i'),
          throwsA(isA<CoreFailure>()),
        ),
    ];
    await received(engine, 4);
    await engine.close();
    await Future.wait(requests);
    await expectLater(
      engine.request('hello', const {}),
      throwsA(failure('engine.closed')),
    );
  });

  test('non-serializable input fails before dispatch without consuming waiting capacity', () async {
    final engine = await heldEngine();
    await expectLater(
      engine.request('inspect', {'invalid': File('not read')}),
      throwsA(failure('engine.input')),
    );
    expect(
      jsonEncode((await engine.request('hello', const {}))['received']),
      '[]',
    );
    expect(
      (await engine.request('inspect', {'snapshot': 'healthy'}))['snapshot'],
      'healthy',
    );
  });
}
