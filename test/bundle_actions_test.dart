import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:busyapi/src/workspace/bundle_actions.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final choice in <BundleFormat?>[null, ...BundleFormat.values]) {
    testWidgets(
      'bundle format is explicit, defaults to single-file and awaits route exit $choice',
      (tester) async {
        Future<BundleFormat?>? result;
        const channel = MethodChannel(nativeMenuChannelName);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'show') return null;
          final entries = (call.arguments as Map)['entries'] as List;
          expect(entries.map((e) => e['label']), [
            'Single-file OpenAPI JSON',
            'Original resource package · offline loader',
          ]);
          return choice == BundleFormat.resourcePackage ? 1 : 0;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildBusyApiTheme(
              brightness: choice == null ? Brightness.light : Brightness.dark,
              accentColor: Colors.blue,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => result = chooseBundleFormat(context),
                  child: const Text('Choose'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
        final combo = tester.widget<BusyApiComboRow<BundleFormat>>(
          find.byType(BusyApiComboRow<BundleFormat>),
        );
        expect(combo.selected, BundleFormat.singleFile);
        if (choice != null) {
          await tester.tap(find.text('Single-file OpenAPI JSON'));
          await tester.pumpAndSettle();
          if (choice == BundleFormat.resourcePackage) {
            expect(
              find.textContaining('may disclose private source paths'),
              findsOneWidget,
            );
          }
        }
        await tester.tap(
          find.widgetWithText(
            BusyApiDialogButton,
            choice == null ? 'Cancel' : 'Choose output folder',
          ),
        );
        await tester.pumpAndSettle();
        expect(await result, choice);
        expect(find.byType(BusyApiDialogShell), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
