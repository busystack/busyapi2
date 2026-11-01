import 'dart:async';

import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/client_generation.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Metadata extends GeneratorRuntime {
  Completer<List<GeneratorOption>>? held;
  String? requested;
  @override
  Future<List<ClientGenerator>> clients({bool Function()? cancelled}) async =>
      const [ClientGenerator('rust', 'stable'), ClientGenerator('lua', 'beta')];
  @override
  Future<List<GeneratorOption>> options(
    String generator, {
    bool Function()? cancelled,
  }) async {
    requested = generator;
    return held == null
        ? const [
            GeneratorOption(
              'packageName',
              'Upstream package name documentation',
              'default',
            ),
            GeneratorOption(
              'useFeature',
              'Upstream boolean documentation',
              true,
            ),
          ]
        : await held!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => <String, Object?>{},
          );
    }
  });
  tearDown(() {
    for (final name in ['yaru_window', 'yaru_window/events']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });
  for (final retire in [false, true]) {
    testWidgets(
      retire ? 'closing the generator chooser retires pending option metadata' : 'native generation chooses a catalog client and documented options without language enums',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final metadata = _Metadata();
        ClientGenerationSelection? selection;
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: Brightness.light,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selection = await showClientGeneration(
                      context,
                      runtime: metadata,
                    );
                  },
                  child: const Text('Generate'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Generate'));
        await tester.pumpAndSettle();
        if (retire) metadata.held = Completer<List<GeneratorOption>>();
        tester
            .widget<BusyApiComboRow<String>>(
              find.byType(BusyApiComboRow<String>),
            )
            .onSelected('lua');
        await tester.pump();
        expect(metadata.requested, 'lua');
        if (retire) {
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          metadata.held!.complete(const [
            GeneratorOption('old', 'retired metadata', null),
          ]);
          await tester.pumpAndSettle();
          expect(selection, isNull);
          expect(find.text('old'), findsNothing);
        } else {
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextFormField).at(0),
            'chosen_package',
          );
          await tester.enterText(find.byType(TextFormField).at(1), 'false');
          await tester.tap(find.text('Official option documentation').first);
          await tester.pumpAndSettle();
          expect(
            find.text('Upstream package name documentation'),
            findsOneWidget,
          );
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Choose output folder'));
          await tester.pumpAndSettle();
          expect(selection?.generator, 'lua');
          expect(selection?.options, {
            'packageName': 'chosen_package',
            'useFeature': false,
          });
          expect(selection?.templates, isNull);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
