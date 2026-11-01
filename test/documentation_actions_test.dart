import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:busyapi/src/workspace/documentation_actions.dart';
import 'package:busyapi/src/platform/native_menu_service.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('headless and generated English documentation labels produce identical saved outputs', () async {
    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(documentationLabels(l), defaultDocumentationLabels);
  });
  testWidgets(
    'documentation preset capture cancels without creating output or mutating state',
    (tester) async {
      Future<String?>? result;
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
                onPressed: () => result = chooseDocumentationPreset(context),
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      final combo = tester.widget<BusyApiComboRow<String>>(
        find.byType(BusyApiComboRow<String>),
      );
      expect(combo.selected, 'native-reference');
      expect(combo.values, ['native-reference', 'redoc', 'swagger']);
      await tester.tap(find.widgetWithText(BusyApiDialogButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(find.byType(BusyApiDialogShell), findsNothing);
    },
  );
  for (final label in [
    'Redoc Community Edition · offline HTML',
    'Swagger UI · offline HTML',
  ]) {
    testWidgets('$label selection returns only after the capture route exits', (
      tester,
    ) async {
      Future<String?>? result;
      List<Map>? choices;
      const channel = MethodChannel(nativeMenuChannelName);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'show') return null;
        choices = (call.arguments as Map)['entries'].cast<Map>();
        return choices!.indexWhere((entry) => entry['label'] == label);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildBusyApiTheme(
            brightness: Brightness.dark,
            accentColor: Colors.blue,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => result = chooseDocumentationPreset(context),
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Native Reference · offline HTML'));
      await tester.pumpAndSettle();
      expect(choices!.map((entry) => entry['label']), [
        'Native Reference · offline HTML',
        'Redoc Community Edition · offline HTML',
        'Swagger UI · offline HTML',
      ]);
      expect(find.text(label), findsOneWidget);
      await tester.tap(
        find.widgetWithText(BusyApiDialogButton, 'Choose output folder'),
      );
      await tester.pumpAndSettle();
      expect(await result, label.startsWith('Redoc') ? 'redoc' : 'swagger');
      expect(find.byType(BusyApiDialogShell), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
