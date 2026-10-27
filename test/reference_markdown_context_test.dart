import 'dart:convert';
import 'dart:io';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/reference/owned_reference_markdown.dart';
import 'package:busyapi/src/reference/reference_object.dart';
import 'package:busyapi/src/reference/reference_view.dart';
import 'package:busyapi/src/workspace/workspace_controller.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../packages/busyapi_core/test/test_support.dart';

Future<void> ready(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), true);
}

void main() {
  for (final version in ['2.0', '3.0.4', '3.1.2', '3.2.1']) {
    for (final format in ['yaml', 'json']) {
      testWidgets(
        '$version $format Reference copies links from the captured logical URI and schema identity',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final temp = Directory.systemTemp.createTempSync(
            'busyapi-markdown-native-',
          );
          final source = File('${temp.path}/api.$format');
          final modern = version.startsWith('3.1') || version.startsWith('3.2');
          final value = <String, Object?>{
            version == '2.0' ? 'swagger' : 'openapi': version,
            if (version.startsWith('3.2'))
              r'$self': 'https://identity.example.invalid/root/api.$format',
            'info': {
              'title': 'Links 雪',
              'version': '1',
              'description': '[Guide](guide?zero=0&empty=)',
            },
            'paths': {},
            version == '2.0' ? 'definitions' : 'components': version == '2.0'
                ? {
                    'Value': {
                      'type': 'string',
                      'description': '[Schema](guide)',
                    },
                  }
                : {
                    'schemas': {
                      'Value': {
                        if (modern)
                          r'$id': 'https://schema.example.invalid/models/',
                        'type': 'string',
                        'description': '[Schema](guide)',
                      },
                    },
                  },
          };
          final original =
              '${format == 'yaml' ? '# Keep 雪\r\n' : ''}${jsonEncode(value)}\r\n';
          source.writeAsStringSync(original);
          File('${temp.path}/busyapi.yaml').writeAsStringSync(
            jsonEncode({
              'version': 1,
              'roots': [
                {'name': 'api', 'path': 'api.$format'},
              ],
              'resourceMappings': {
                'https://retrieval.example.invalid/original/api.$format':
                    'api.$format',
              },
            }),
          );
          final c = WorkspaceController(
            EngineProcess(executable: runtimeNode, helper: runtimeHelper),
            StateLocations(
              config: '${temp.path}/config',
              state: '${temp.path}/state',
              cache: '${temp.path}/cache',
            ),
          );
          final copied = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copied.add((call.arguments as Map)['text'] as String);
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          Widget screen({bool schema = false}) => MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListenableBuilder(
                listenable: c,
                builder: (_, _) => schema
                    ? ReferenceObjectView(
                        controller: c,
                        target: {
                          'root': c.root,
                          'resource': source.uri.toString(),
                          'pointer': version == '2.0'
                              ? '/definitions/Value'
                              : '/components/schemas/Value',
                        },
                        reveal: (_) {},
                        open: (_) {},
                      )
                    : ReferenceView(controller: c, reveal: (_) {}),
              ),
            ),
          );
          Future<void> copy(String label) async {
            final inspect = find.widgetWithText(
              BusyApiActionRow,
              'Inspect documentation links (1)',
            );
            await ready(tester, () => inspect.evaluate().length == 1);
            final action = find.widgetWithText(
              BusyApiActionRow,
              'Copy link: $label',
            );
            if (action.evaluate().isEmpty) {
              await tester.ensureVisible(inspect);
              await tester.tap(inspect);
              await tester.pump();
            }
            await tester.ensureVisible(action);
            await tester.tap(action);
            await tester.pump();
          }

          try {
            await tester.runAsync(() async {
              await c.initialize();
              await c.open(temp.path);
              await c.analyse();
            });
            await tester.pumpWidget(screen());
            await copy('Guide');
            final base = version.startsWith('3.2')
                ? 'https://identity.example.invalid/root/'
                : 'https://retrieval.example.invalid/original/';
            expect(copied.last, '${base}guide?zero=0&empty=');
            await tester.pumpWidget(const SizedBox());
            await tester.pumpWidget(screen(schema: true));
            await copy('Schema');
            expect(
              copied.last,
              '${modern ? 'https://schema.example.invalid/models/' : base}guide',
            );
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() async {
              final buffer = await c.project!.buffer(source.uri.toString());
              c.project!.store.replace(
                buffer.id,
                buffer.text.replaceFirst(
                  modern
                      ? 'https://schema.example.invalid/models/'
                      : '[Schema](guide)',
                  modern
                      ? 'https://changed.example.invalid/new/'
                      : '[Schema](next)',
                ),
              );
              await c.analyse();
            });
            await tester.pumpWidget(screen(schema: true));
            await copy('Schema');
            expect(
              copied.last,
              modern
                  ? 'https://changed.example.invalid/new/guide'
                  : '${base}next',
            );
            expect(find.byType(OwnedReferenceMarkdownText), findsWidgets);
            expect(source.readAsStringSync(), original);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() async {
              await c.shutdown();
              c.dispose();
              await temp.delete(recursive: true);
            });
          }
        },
      );
    }
  }
}
