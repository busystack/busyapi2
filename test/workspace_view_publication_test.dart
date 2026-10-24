import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

class _ObservedViews extends WorkspaceController {
  _ObservedViews(super.engine, super.locations, {super.viewStateWriter});
  Completer<void>? nextCapture;
  @override
  Future<void> persistView() {
    final result = super.persistView();
    nextCapture?.complete();
    nextCapture = null;
    return result;
  }
}

void main() {
  for (final failure in [false, true]) {
    test(
      'private view writes freeze and coalesce captures, join shutdown and allow retry failure=$failure',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-view-write-',
        );
        final file = File('${temp.path}/api.yaml');
        const source =
            '\ufeffopenapi: 3.2.1\r\ninfo: {title: "Views 雪😀", version: "1"}\npaths: {}';
        await file.writeAsString(source);
        final engine = EngineProcess(
              executable: runtimeNode,
              helper: runtimeHelper,
            ),
            entered = Completer<void>(),
            release = Completer<void>(),
            captures = <Map>[];
        var active = 0, maximum = 0, held = false;
        final c = _ObservedViews(
          engine,
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
          viewStateWriter: (path, data) async {
            active++;
            if (active > maximum) maximum = active;
            try {
              captures.add(data as Map);
              if (held && !entered.isCompleted) {
                entered.complete();
                await release.future;
                if (failure) throw StateError('injected-view-write');
              }
              await writePrivateJson(path, data);
            } finally {
              active--;
            }
          },
        );
        try {
          await c.initialize();
          await c.open(file.path);
          // Join any opening capture before installing the held boundary.
          await c.persistView();
          captures.clear();
          held = true;
          c.layoutState = {
            'stage': 'first',
            'nested': {'value': 1},
          };
          final first = c.persistView();
          final checkedFirst = failure
              ? expectLater(first, throwsStateError)
              : first;
          await entered.future;
          final location = c.project!.location;
          (c.layoutState['nested'] as Map)['value'] = 2;
          final joined = <Future<void>>[checkedFirst];
          for (var i = 0; i < 100; i++) {
            c.layoutState = {'stage': 'latest', 'value': i};
            final pending = c.persistView();
            joined.add(
              failure ? expectLater(pending, throwsStateError) : pending,
            );
          }
          expect(captures, hasLength(1));
          expect(
            captures.single['projects'][location]['layout'],
            {
              'stage': 'first',
              'nested': {'value': 1},
            },
            reason: 'Later nested mutations cannot change an in-flight capture',
          );
          var closed = false;
          final shutdownCapture = Completer<void>();
          c.nextCapture = shutdownCapture;
          final shutdown = c.shutdown().then((_) => closed = true);
          final checkedShutdown = failure
              ? expectLater(shutdown, throwsStateError)
              : shutdown;
          await shutdownCapture.future;
          expect(closed, false);
          expect(maximum, 1);
          release.complete();
          await Future.wait([...joined, checkedShutdown]);
          expect(maximum, 1);
          if (failure) {
            expect(closed, false);
            expect(c.disposed, false);
            expect(captures, hasLength(1));
            await c.shutdown();
          } else {
            expect(closed, true);
          }
          expect(
            captures.length,
            2,
            reason: 'One immutable write plus one coalesced latest capture',
          );
          final saved = jsonDecode(
            await File('${temp.path}/state/views.json').readAsString(),
          ) as Map;
          expect(saved['projects'][location]['layout'], {
            'stage': 'latest',
            'value': 99,
          });
          expect(await file.readAsBytes(), utf8.encode(source));
        } finally {
          if (!release.isCompleted) release.complete();
          await c.shutdown();
          c.dispose();
          await engine.close();
          await temp.delete(recursive: true);
        }
      },
    );
  }
}
