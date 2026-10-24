import 'dart:io';

import 'package:busyapi_core/src/atomic_file_writer.dart';
import 'package:busyapi_core/src/publication_staging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('file staging is exclusive, private and visible without changing source bytes', () async {
    final root = await Directory.systemTemp.createTemp(
      'busyapi-private-stage-',
    );
    addTearDown(() => root.delete(recursive: true));
    final target = File(p.join(root.path, 'api.yaml'));
    const bytes = [239, 187, 191, 35, 32, 13, 10, 49, 46, 48, 48];
    late String observed;
    await const AtomicFileWriter().writeBytes(
      target.path,
      bytes,
      overwrite: false,
      prepareStaged: (path) async {
        final directory = File(path).parent;
        observed = await directory.resolveSymbolicLinks();
        expect(p.basename(observed), startsWith(fileStagingPrefix));
        expect(p.basename(observed).startsWith('.'), false);
        expect((await Directory(observed).stat()).mode & 511, 448);
        expect(await File(path).readAsBytes(), bytes);
        expect(await target.exists(), false);
      },
    );
    expect(await target.readAsBytes(), bytes);
    expect(await Directory(observed).exists(), false);
  });
  test('only the existing and current staging families are classified, never granted authority', () {
    for (final prefix in [fileArchivePrefix, '.$fileArchivePrefix']) {
      expect(isFileArchiveDirectoryName('${prefix}OWNED'), true);
      expect(isOutputStagingDirectoryName('${prefix}OWNED'), false);
    }
    for (final prefix in [outputStagingPrefix, '.$outputStagingPrefix']) {
      expect(isOutputStagingDirectoryName('${prefix}OWNED'), true);
      expect(isFileArchiveDirectoryName('${prefix}OWNED'), false);
    }
    for (final name in [
      'source',
      'foreign',
      '.busyapi-file-move',
      'busyapi-output',
    ]) {
      expect(isFileArchiveDirectoryName(name), false);
      expect(isOutputStagingDirectoryName(name), false);
    }
  });
}
