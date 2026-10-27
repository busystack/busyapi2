import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/migration_review.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi/src/workspace/project_search.dart'
    show BusyApiReviewPages;
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

enum _AfterReview {
  none,
  editRoot,
  editShared,
  deleteShared,
  corruptShared,
  closeDuringRead,
}

typedef _Scenario = ({
  String version,
  String format,
  bool unsupported,
  int count,
  bool shared,
  _AfterReview afterReview,
});
_Scenario _scenario(
  String version,
  String format, {
  bool unsupported = false,
  int count = 1,
  bool shared = false,
  _AfterReview afterReview = _AfterReview.none,
}) => (
  version: version,
  format: format,
  unsupported: unsupported,
  count: count,
  shared: shared,
  afterReview: afterReview,
);

void main() {
  for (final (:version, :format, :unsupported, :count, :shared, :afterReview)
      in [
        for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1'])
          for (final format in ['yaml', 'json'])
            for (final unsupported in [false, if (version != '2.0') true])
              _scenario(version, format, unsupported: unsupported),
        for (final format in ['yaml', 'json'])
          _scenario(
            '3.1.2',
            format,
            unsupported: true,
            afterReview: _AfterReview.editRoot,
          ),
        _scenario('3.1.2', 'yaml', count: 60),
        for (final format in ['yaml', 'json'])
          _scenario('3.1.2', format, unsupported: true, shared: true),
        _scenario(
          '3.1.2',
          'yaml',
          unsupported: true,
          shared: true,
          afterReview: _AfterReview.editRoot,
        ),
        for (final change in [
          _AfterReview.editShared,
          _AfterReview.deleteShared,
          _AfterReview.corruptShared,
          _AfterReview.closeDuringRead,
        ])
          _scenario(
            '3.1.2',
            'yaml',
            unsupported: true,
            shared: true,
            afterReview: change,
          ),
      ]) {
    final stale = afterReview == _AfterReview.editRoot;
    testWidgets(
      'native migration capture $version $format unsupported=$unsupported stale=$stale count=$count shared=$shared after=$afterReview retains source diagnostics and refuses output',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final name in ['yaru_window', 'yaru_window/events']) {
          messenger.setMockMethodCallHandler(
            MethodChannel(name),
            (call) async => call.method == 'state'
                ? {'active': true, 'visible': true, 'closable': true}
                : null,
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
          );
        }
        final temp = Directory.systemTemp.createTempSync(
          'busyapi-migration-capture-',
        );
        final file = File('${temp.path}/api.$format');
        final url = unsupported
            ? 'https://[v1.future]/api'
            : 'https://api.example.invalid/%zz';
        final original =
            '${format == 'yaml' ? '# Keep capture 雪\r\n' : ''}${jsonEncode({
              version == '2.0' ? 'swagger' : 'openapi': version,
              if (version == '2.0') 'host': false,
              'info': {'title': 'Original', 'version': '1'},
              'paths': shared ? {
                      '/items': {
                        'get': {
                          'operationId': 'follow',
                          'responses': {
                            '204': {'description': 'Empty'},
                          },
                        },
                      },
                    } : {},
              if (shared) 'components': {
                  'links': {
                    'Use': {r'$ref': 'shared.$format#/components/links/Next'},
                  },
                },
              if (!shared && version != '2.0') 'servers': [
                  for (var index = 0; index < count; index++) {'url': url},
                ],
              'x-exact': 'EXACT',
            }).replaceFirst('"EXACT"', '9007199254740993.00')}';
        file.writeAsStringSync(original);
        final sharedFile = File('${temp.path}/shared.$format');
        final sharedSource = jsonEncode({
          'openapi': version,
          'info': {'title': 'Shared', 'version': '1'},
          'paths': {},
          'components': {
            'links': {
              'Next': {
                'operationRef': 'api.$format#/paths/~1items/get',
                'server': {'url': url},
              },
            },
          },
        });
        if (shared) sharedFile.writeAsStringSync(sharedSource);
        final findingResource = shared
            ? sharedFile.uri.toString()
            : file.uri.toString();

        final controller = WorkspaceController(
          EngineProcess(executable: runtimeNode, helper: runtimeHelper),
          StateLocations(
            config: '${temp.path}/config',
            state: '${temp.path}/state',
            cache: '${temp.path}/cache',
          ),
        );
        Future<void>? dialog;
        Map<String, dynamic>? revealed;
        Future<void> ready(
          bool Function() condition, {
          String phase = 'migration control',
        }) async {
          await tester.pump();
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 20));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          expect(condition(), true, reason: '$phase ${controller.error}');
        }

        try {
          await tester.runAsync(() async {
            await controller.initialize();
            await controller.open(file.path);
            controller.sourceEdit(
              controller.root!,
              original.replaceFirst('Original', 'Unsaved'),
            );
            await controller.analyse();
          });
          final serverFindings = (controller.analysis!['findings'] as List)
              .cast<Map>()
              .where(
                (f) => version == '2.0'
                    ? f['severity'] == 'error'
                    : (f['code'] as String).startsWith('server.url.'),
              )
              .toList();
          expect(serverFindings, hasLength(count));
          final finding = count > 1
              ? serverFindings.last
              : serverFindings.single;
          final source = controller.buffer!.text,
              generation =
                  (controller.analysis!['resources'] as List)
                          .cast<Map>()
                          .singleWhere(
                            (r) => r['id'] == findingResource,
                          )['generation']
                      as int;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildBusyApiTheme(
                brightness: Brightness.light,
                accentColor: Colors.blue,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => dialog = showMigrationReview(
                      context,
                      controller,
                      reveal: (location) async {
                        revealed = location;
                      },
                    ),
                    child: const Text('Migrate'),
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(() => tester.tap(find.text('Migrate')));
          final review = find.widgetWithText(
            BusyApiDialogButton,
            'Review migration',
          );
          await ready(() => review.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(review));
          final destination = find.widgetWithText(
            BusyApiDialogButton,
            'Review output',
          );
          await ready(() => destination.evaluate().isNotEmpty);
          await tester.runAsync(() => tester.tap(destination));
          await ready(
            () => find
                .widgetWithText(BusyApiActionRow, finding['message'] as String)
                .evaluate()
                .isNotEmpty,
            phase: 'captured source finding',
          );
          if (count > 50) {
            expect(
              find.widgetWithText(
                BusyApiActionRow,
                finding['message'] as String,
              ),
              findsNWidgets(50),
            );
            final pages = tester.widget<BusyApiReviewPages>(
              find.byType(BusyApiReviewPages),
            );
            expect(pages.pages, 2);
            pages.onChanged(1);
            await tester.pump();
            expect(
              find.widgetWithText(
                BusyApiActionRow,
                finding['message'] as String,
              ),
              findsNWidgets(10),
            );
          }
          final pointer = finding['pointer'] as String;
          final row = find.widgetWithText(
            BusyApiActionRow,
            '$findingResource $pointer',
          );
          expect(row, findsOneWidget);
          expect(
            find.descendant(
              of: row,
              matching: find.text(unsupported ? 'Warning' : 'Error'),
            ),
            findsOneWidget,
          );
          final publish = find.widgetWithText(
            BusyApiDialogButton,
            'Create migrated copy',
          );
          expect(tester.widget<BusyApiDialogButton>(publish).onPressed, isNull);
          final action = tester.widget<BusyApiActionRow>(row).onTap;
          expect(action, isNotNull);
          expect(file.readAsStringSync(), original);
          if (shared) expect(sharedFile.readAsStringSync(), sharedSource);
          expect(controller.buffer!.text, source);
          expect(
            Directory('${temp.path}/busyapi-migrated').existsSync(),
            false,
          );
          final close = find.widgetWithText(BusyApiDialogButton, 'Close');
          if (stale) {
            await tester.runAsync(() async {
              controller.sourceEdit(
                controller.root!,
                source.replaceFirst('Unsaved', 'Changed after failure'),
              );
              // No frame intervenes: the old callback must check its inputs.
              action!();
            });
            expect(revealed, isNull);
            await tester.pump();
            expect(tester.widget<BusyApiActionRow>(row).onTap, isNull);
            await tester.runAsync(() => tester.tap(close));
          } else if (afterReview == _AfterReview.closeDuringRead) {
            final closeAction = tester
                .widget<BusyApiDialogButton>(close)
                .onPressed!;
            await tester.runAsync(() async {
              action!();
              closeAction();
            });
            await tester.runAsync(
              () => controller.project!.buffer(findingResource),
            );
          } else if (afterReview != _AfterReview.none) {
            await tester.runAsync(() async {
              switch (afterReview) {
                case _AfterReview.editShared:
                  await sharedFile.writeAsString(
                    sharedSource.replaceFirst('Shared', 'Externally changed'),
                  );
                case _AfterReview.deleteShared:
                  await sharedFile.delete();
                case _AfterReview.corruptShared:
                  await sharedFile.writeAsBytes([255, 254]);
                default:
                  fail('Unexpected fixture source change');
              }
              action!();
            });
            await ready(
              () => close.evaluate().isNotEmpty,
              phase: 'Source read failure',
            );
            expect(revealed, isNull);
            if (afterReview == _AfterReview.editShared) {
              expect(tester.widget<BusyApiActionRow>(row).onTap, isNull);
              expect(
                controller.store!.get(findingResource).text,
                contains('Externally changed'),
              );
            } else {
              expect(
                find.textContaining(
                  afterReview == _AfterReview.deleteShared
                      ? 'access.read:'
                      : 'source.encoding:',
                ),
                findsOneWidget,
              );
            }
            await tester.runAsync(() => tester.tap(close));
          } else {
            await tester.ensureVisible(row);
            await tester.runAsync(() => tester.tap(row));
            await ready(
              () => revealed != null,
              phase: 'Source action completion',
            );
          }
          await tester.pumpAndSettle();
          await tester.runAsync(() => dialog!);
          if (afterReview == _AfterReview.none) {
            expect(revealed, containsPair('resource', findingResource));
            expect(revealed, containsPair('root', controller.root));
            expect(revealed, containsPair('pointer', pointer));
            expect(revealed, containsPair('generation', generation));
            expect(revealed!['range'], finding['range']);
            expect(revealed!['data'], false);
          } else {
            expect(revealed, isNull);
          }
          expect(file.readAsStringSync(), original);
          if (shared) {
            if (afterReview == _AfterReview.deleteShared) {
              expect(sharedFile.existsSync(), false);
            } else if (afterReview == _AfterReview.corruptShared) {
              expect(sharedFile.readAsBytesSync(), [255, 254]);
            } else {
              expect(
                sharedFile.readAsStringSync(),
                afterReview == _AfterReview.editShared
                    ? sharedSource.replaceFirst('Shared', 'Externally changed')
                    : sharedSource,
              );
            }
          }
          expect(
            controller.buffer!.text,
            stale
                ? source.replaceFirst('Unsaved', 'Changed after failure')
                : source,
          );
          expect(controller.buffer!.dirty, true);
          expect(
            Directory('${temp.path}/busyapi-migrated').existsSync(),
            false,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(controller.shutdown);
          controller.dispose();
          await tester.runAsync(controller.engine.close);
          temp.deleteSync(recursive: true);
        }
      },
    );
  }
}
