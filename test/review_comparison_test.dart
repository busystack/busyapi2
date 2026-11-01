import 'package:busyapi/l10n/generated/app_localizations.dart';
import 'package:busyapi/src/app/app_theme.dart';
import 'package:busyapi/src/comparison/review_comparison.dart';
import 'package:busyapi/src/comparison/source_comparison.dart';
import 'package:busyapi/src/comparison/source_comparison_pagination.dart';
import 'package:busyapi/src/comparison/source_comparison_view.dart';
import 'package:busyapi/src/workspace/project_search.dart';
import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SourceComparison compare(String before, String after) => compareSource(
  SourceComparisonInput(
    id: 'before',
    version: 0,
    label: 'Before',
    source: before,
  ),
  SourceComparisonInput(id: 'after', version: 0, label: 'After', source: after),
  maximumLcsCells: 2000,
);

void main() {
  final lines = List.generate(600, (i) => 'unchanged line $i 😀\n');
  for (final insertion in [true, false]) {
    for (final at in [0, 50, 100]) {
      test(
        '${insertion ? 'insertion' : 'deletion'} at line $at is aligned before paging',
        () {
          final base = lines.join();
          final changed = [...lines]..insert(at, 'the only change\n');
          final before = insertion ? base : changed.join();
          final after = insertion ? changed.join() : base;
          final comparison = compare(before, after);
          expect(comparison.simplified, false);
          expect(comparison.changes, hasLength(1));
          final presentation = SourceComparisonPages(
            comparison,
            pageSize: SearchChangePreview.pageSize,
          );
          final chunks = [
            for (var page = 0; page < presentation.pages; page++)
              ...presentation.page(page),
          ];
          expect(
            chunks
                .where((c) => c.kind == SourceComparisonChunkKind.removed)
                .map((c) => c.text)
                .join(),
            insertion ? '' : 'the only change\n',
          );
          expect(
            chunks
                .where((c) => c.kind == SourceComparisonChunkKind.added)
                .map((c) => c.text)
                .join(),
            insertion ? 'the only change\n' : '',
          );
          expect(
            chunks
                .where((c) => c.kind != SourceComparisonChunkKind.added)
                .map((c) => c.text)
                .join(),
            before,
          );
          expect(
            chunks
                .where((c) => c.kind != SourceComparisonChunkKind.removed)
                .map((c) => c.text)
                .join(),
            after,
          );
          for (var page = 0; page < presentation.pages; page++) {
            expect(
              presentation.page(page).fold<int>(0, (sum, c) => sum + c.length),
              lessThanOrEqualTo(SearchChangePreview.pageSize + 1),
            );
            for (final chunk in presentation.page(page)) {
              expect(chunk.text.runes.contains(0xfffd), false);
              expect(
                chunk.text.codeUnitAt(0),
                isNot(inInclusiveRange(0xdc00, 0xdfff)),
              );
              expect(
                chunk.text.codeUnitAt(chunk.length - 1),
                isNot(inInclusiveRange(0xd800, 0xdbff)),
              );
            }
          }
        },
      );
    }
  }

  test('a change spanning several page boundaries retains complete before and after inputs', () {
    final removed = '${'removed 😀 ' * 400}\n';
    final added = '${'added 雪 ' * 600}\n';
    final before = '${lines.take(50).join()}$removed${lines.skip(50).join()}';
    final after = before.replaceFirst(removed, added);
    final result = SourceComparisonPages(
      compare(before, after),
      pageSize: SearchChangePreview.pageSize,
    );
    final chunks = [for (var i = 0; i < result.pages; i++) ...result.page(i)];
    expect(
      chunks
          .where((c) => c.kind == SourceComparisonChunkKind.removed)
          .map((c) => c.text)
          .join(),
      removed,
    );
    expect(
      chunks
          .where((c) => c.kind == SourceComparisonChunkKind.added)
          .map((c) => c.text)
          .join(),
      added,
    );
    expect(
      chunks
          .where((c) => c.kind != SourceComparisonChunkKind.added)
          .map((c) => c.text)
          .join(),
      before,
    );
    expect(
      chunks
          .where((c) => c.kind != SourceComparisonChunkKind.removed)
          .map((c) => c.text)
          .join(),
      after,
    );
  });

  testWidgets(
    'expanded replacement review pages the aligned result and resets for a new capture',
    (tester) async {
      Future<void> show(SearchChangePreview preview) => tester.pumpWidget(
        MaterialApp(
          theme: buildBusyApiTheme(
            brightness: Brightness.light,
            accentColor: Colors.blue,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: BusyApiReviewComparison(preview: preview)),
        ),
      );
      final prefix = lines.take(50).join(), suffix = lines.skip(50).join();
      await show(SearchChangePreview(prefix, '', 'inserted\n', suffix));
      final initial = tester
          .widget<SourceComparisonView>(find.byType(SourceComparisonView))
          .comparison;
      expect(initial.changes.single.oldText, '');
      expect(initial.changes.single.currentText, 'inserted\n');
      final pages = tester
          .widget<BusyApiReviewPages>(find.byType(BusyApiReviewPages))
          .pages;
      for (var i = 0; i < pages; i++) {
        tester
            .widget<BusyApiReviewPages>(find.byType(BusyApiReviewPages))
            .onChanged(i);
        await tester.pump();
        final view = tester.widget<SourceComparisonView>(
          find.byType(SourceComparisonView),
        );
        expect(view.comparison, same(initial));
        expect(
          view.chunks.fold<int>(0, (sum, c) => sum + c.length),
          lessThanOrEqualTo(SearchChangePreview.pageSize + 1),
        );
        expect(
          view.chunks.where((c) => c.kind == SourceComparisonChunkKind.removed),
          isEmpty,
        );
      }
      await show(const SearchChangePreview('', 'removed\n', '', 'retained\n'));
      expect(find.byType(BusyApiReviewPages), findsNothing);
      final next = tester.widget<SourceComparisonView>(
        find.byType(SourceComparisonView),
      );
      expect(next.comparison.changes.single.oldText, 'removed\n');
      expect(next.chunks.map((c) => c.text).join(), 'removed\nretained\n');
      expect(tester.takeException(), isNull);
    },
  );
}
