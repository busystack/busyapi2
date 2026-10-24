import 'package:busyapi_core/busyapi_core.dart';
import 'package:test/test.dart';

void main() {
  test('one safe CommonMark tree preserves prose, Unicode, code and list structure', () async {
    final parsed = await ReferenceMarkdownJob(
      '# Heading 雪\n\nA **strong** and *emphasized* value &amp; `code`.\n\n> Quoted\n\n3. third\n4. fourth\n\n```json\n{"n":9007199254740993}\n```',
    ).result;
    expect(parsed.formatted, true);
    final html = parsed.toHtml();
    expect(html, contains('<h1>Heading 雪</h1>'));
    expect(html, contains('<strong>strong</strong>'));
    expect(html, contains('<em>emphasized</em>'));
    expect(html, contains('value &amp; <code>code</code>'));
    expect(html, contains('<blockquote>'));
    expect(html, contains('<ol start="3">'));
    expect(html, contains('9007199254740993'));
    expect(html, contains('<pre><code>'));
  });
  test('HTML, images and malicious links cannot become executable or remote resources', () async {
    const source =
        '<script>fetch("https://must-not-load.invalid")</script>\n\n<img src="file:///private" onerror="bad()">\n\n![Visible alt](https://must-not-load.invalid/image.png)\n\n[bad](javascript:alert%281%29) [safe](https://docs.example/guide?q=1&x=2)';
    final parsed = await ReferenceMarkdownJob(source).result;
    final html = parsed.toHtml();
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('<img')));
    expect(RegExp(r'<[a-z][^>]*\ssrc=').hasMatch(html), false);
    expect(html, contains('&lt;img src="file:///private"'));
    expect(html, isNot(contains('href="javascript')));
    expect(html, contains('&lt;script&gt;'));
    expect(html, contains('Visible alt'));
    expect(html, isNot(contains('image.png')));
    expect(html, contains('href="https://docs.example/guide?q=1&amp;x=2"'));
    expect(html, contains('rel="noopener noreferrer"'));
  });
  test('relative links use the original base and never grant file or credential access', () async {
    final base = Uri.parse('https://docs.example/original/schema.yaml');
    expect(
      referenceLink('../guide?q=1', base: base).toString(),
      'https://docs.example/guide?q=1',
    );
    expect(referenceLink('#section', base: base).toString(), '#section');
    expect(
      referenceLink('./other', base: Uri.file('/private/api.yaml')),
      isNull,
    );
    for (final value in [
      'file:///private',
      'data:text/html,unsafe',
      'javascript:bad()',
      'https://user:password@docs.example/',
      'https://docs.example/\nunsafe',
      r'https:\docs.example\path',
      'ws://docs.example/',
    ]) {
      expect(referenceLink(value, base: base), isNull, reason: value);
    }
    final parsed = await ReferenceMarkdownJob(
      '[guide](../guide)',
      base: base,
    ).result;
    expect(parsed.toHtml(), contains('href="https://docs.example/guide"'));
  });
  test('long descriptions remain complete plain text rather than truncated Markdown success', () async {
    final source = '雪😀9007199254740993\n' * 5000;
    final parsed = await ReferenceMarkdownJob(source).result;
    expect(parsed.formatted, false);
    expect(parsed.blocks.single.text, source);
    expect(parsed.toHtml(), '<pre>$source</pre>');
  });
  test('cancellation, a real parsing deadline and structural limits do not return a clean tree', () async {
    final cancelled = ReferenceMarkdownJob('unchanged');
    cancelled.cancel();
    await expectLater(
      cancelled.result,
      throwsA(
        isA<CoreFailure>().having((error) => error.code, 'code', 'cancelled'),
      ),
    );
    final timed = ReferenceMarkdownJob(
      '[unfinished](' * 4000,
      timeout: Duration.zero,
    );
    await expectLater(
      timed.result,
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'documentation.markdown.timeout',
        ),
      ),
    );
    final excessive = ReferenceMarkdownJob('- entry\n' * 5000);
    await expectLater(
      excessive.result,
      throwsA(
        isA<CoreFailure>().having(
          (error) => error.code,
          'code',
          'documentation.markdown.failed',
        ),
      ),
    );
    // A cancelled/failed parser has no shared mutable state for the next job.
    expect(
      (await ReferenceMarkdownJob('**Current**').result).toHtml(),
      contains('<strong>Current</strong>'),
    );
  });
  test('parser admission, waiting bytes, cancellation and actual exits are bounded', () async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (ReferenceMarkdownJob.admission != (0, 0) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(ReferenceMarkdownJob.admission, (0, 0));
    final jobs = [
      for (var index = 0; index < 132; index++)
        ReferenceMarkdownJob('**entry $index**'),
    ];
    expect(ReferenceMarkdownJob.admission, (2, 128));
    final results = jobs.map((job) async {
      try {
        await job.result;
        return 'complete';
      } on CoreFailure catch (error) {
        return error.code;
      }
    }).toList();
    for (final job in jobs) job.cancel();
    final codes = await Future.wait(results);
    expect(
      codes.where((code) => code == 'documentation.markdown.busy'),
      hasLength(2),
    );
    expect(codes.where((code) => code == 'cancelled'), hasLength(130));
    final cleanup = DateTime.now().add(const Duration(seconds: 2));
    while (ReferenceMarkdownJob.admission != (0, 0) &&
        DateTime.now().isBefore(cleanup)) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(ReferenceMarkdownJob.admission, (0, 0));
    final large = [
      for (var index = 0; index < 40; index++)
        ReferenceMarkdownJob('x' * 65536),
    ];
    expect(ReferenceMarkdownJob.admission.$1, 2);
    expect(ReferenceMarkdownJob.admission.$2, lessThanOrEqualTo(16));
    final completions = large
        .map((job) => job.result.then<void>((_) {}, onError: (Object _) {}))
        .toList();
    for (final job in large) job.cancel();
    await Future.wait(completions);
  });
  test('export revalidates constructed trees rather than trusting arbitrary tags or targets', () {
    final tree = ReferenceMarkdown([
      ReferenceMarkup(
        'script',
        children: [ReferenceMarkup('text', text: '<unsafe>')],
      ),
      ReferenceMarkup(
        'a',
        target: Uri.parse('javascript:unsafe'),
        children: [ReferenceMarkup('text', text: 'Visible')],
      ),
    ], formatted: true);
    expect(tree.toHtml(), '&lt;unsafe&gt;\nVisible');
  });
}
