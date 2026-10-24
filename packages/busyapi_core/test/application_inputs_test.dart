import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../tool/application_inputs.dart';

class _Build {
  _Build(this.temporary, this.mode) {
    repository = Directory('${temporary.path}/source 雪')..createSync();
    receipt = Directory(
      '${repository.path}/.dart_tool/flutter_build/${'a' * 32}',
    )..createSync(recursive: true);
    final cache = Directory('${temporary.path}/cache')..createSync();
    packages = {
      'busyapi': repository,
      'busyapi_core': Directory('${repository.path}/packages/busyapi_core'),
      'flutter': Directory('${temporary.path}/sdk/packages/flutter'),
      'sample': Directory('${cache.path}/sample'),
      'native_only': Directory('${cache.path}/native_only'),
    };
    inputs = [
      '${repository.path}/lib/main.dart',
      '${packages['sample']!.path}/lib/sample.dart',
      '${packages['busyapi_core']!.path}/lib/core.dart',
      '${temporary.path}/sdk/packages/flutter_tools/lib/compiler.dart',
    ];
    for (final path in inputs) File(path).parent.createSync(recursive: true);
    for (final path in inputs)
      File(path).writeAsStringSync('// original input\n');
    File('${receipt.path}/app.dill').writeAsStringSync('compiled kernel $mode');
    if (mode != 'Debug')
      File('${receipt.path}/app.so').writeAsStringSync('compiled ELF $mode');
    artifact = File(
      '${repository.path}/build/${mode == 'Debug' ? 'kernel_blob.bin' : 'libapp.so'}',
    );
    artifact.parent.createSync(recursive: true);
    File('${receipt.path}/${mode == 'Debug' ? 'app.dill' : 'app.so'}')
        .copySync(artifact.path);
    stamp = File('${receipt.path}/kernel_snapshot_program.stamp');
    writeStamp();
    if (mode != 'Debug') {
      File('${receipt.path}/aot_elf_${mode.toLowerCase()}.stamp')
          .writeAsStringSync(
            jsonEncode({
              'inputs': ['${receipt.path}/app.dill'],
              'outputs': ['${receipt.path}/app.so'],
            }),
          );
    }
    plugin = File('${repository.path}/.flutter-plugins-dependencies');
    plugin.writeAsStringSync(
      jsonEncode({
        'plugins': {
          'linux': [
            {
              'name': 'native_only',
              'path': packages['native_only']!.path,
              'native_build': true,
            },
          ],
        },
      }),
    );
  }
  final Directory temporary;
  final String mode;
  late Directory repository, receipt;
  late Map<String, Directory> packages;
  late List<String> inputs;
  late File artifact, stamp, plugin;
  void writeStamp() => stamp.writeAsStringSync(
    jsonEncode({
      'inputs': inputs,
      'outputs': ['${receipt.path}/app.dill'],
    }),
  );
  Future<ApplicationInputs> collect({String? entry}) => applicationInputs(
    repository: repository,
    packages: packages,
    artifact: artifact.path,
    mode: mode,
    entry: entry ?? 'lib/main.dart',
  );
}

void main() {
  for (final mode in ['Debug', 'Profile', 'Release']) {
    test(
      'actual $mode output selects its source receipt and Linux native-only packages',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'busyapi-build-inputs-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final build = _Build(temp, mode), result = await build.collect();
        expect(
          result.artifactIdentity,
          sha256.convert(await build.artifact.readAsBytes()).toString(),
        );
        expect(result.mode, mode);
        expect(result.productionEntry, true);
        expect(result.packages, {
          'sample': ['lib/sample.dart'],
          'native_only': [],
        });
        expect(result.nativePlugins, {'native_only'});
        final ide = await build.collect(
          entry: '${build.repository.path}/lib/../lib/main.dart',
        );
        expect(ide.entry, 'lib/main.dart');
        expect(ide.productionEntry, true);
        expect(
          () => result.packages['sample']!.add('not captured'),
          throwsUnsupportedError,
        );
        expect(() => result.nativePlugins.clear(), throwsUnsupportedError);
        if (mode != 'Debug') {
          File('${build.receipt.path}/aot_elf_${mode.toLowerCase()}.stamp')
              .writeAsStringSync(
                jsonEncode({
                  'inputs': [],
                  'outputs': ['${build.receipt.path}/app.so'],
                }),
              );
          await expectLater(build.collect(), throwsStateError);
        }
      },
    );
  }
  test('unknown, changed, empty or differently selected outputs cannot yield a successful inventory', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-build-inputs-denied-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final build = _Build(temp, 'Debug'),
        original = await build.artifact.readAsBytes();
    await expectLater(
      build.collect(entry: '../outside.dart'),
      throwsArgumentError,
    );
    await expectLater(
      build.collect(entry: 'tools/other.dart'),
      throwsStateError,
    );
    await build.artifact.writeAsString('a different source build');
    await expectLater(build.collect(), throwsStateError);
    await build.artifact.writeAsBytes([]);
    await expectLater(build.collect(), throwsStateError);
    await build.artifact.writeAsBytes(original);
    build.inputs.add('${temp.path}/not-a-configured-package/input.dart');
    build.writeStamp();
    await expectLater(build.collect(), throwsStateError);
  });
  test('duplicate physical ownership, mismatched native plugins and symlink receipts are not first-match successes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-build-inputs-ownership-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final build = _Build(temp, 'Debug');
    build.packages['alias'] = Directory('${build.packages['sample']!.path}/');
    await expectLater(build.collect(), throwsStateError);
    build.packages.remove('alias');
    final plugin = await build.plugin.readAsString();
    await build.plugin.writeAsString(
      jsonEncode({
        'plugins': {
          'linux': [
            {
              'name': 'native_only',
              'path': '${temp.path}/another-owner',
              'native_build': true,
            },
          ],
        },
      }),
    );
    await expectLater(build.collect(), throwsStateError);
    await build.plugin.writeAsString(plugin);
    final content = await build.stamp.readAsBytes();
    await build.stamp.delete();
    final other = File('${temp.path}/linked-receipt')
      ..writeAsBytesSync(content);
    await Link(build.stamp.path).create(other.path);
    await expectLater(build.collect(), throwsStateError);
  });
  test('development entry provenance stays distinct and conflicting matching receipts remain ambiguous', () async {
    final temp = await Directory.systemTemp.createTemp(
      'busyapi-build-inputs-development-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final build = _Build(temp, 'Debug');
    build.inputs[0] = '${build.repository.path}/tools/native_test.dart';
    build.writeStamp();
    final result = await build.collect(entry: 'tools/native_test.dart');
    expect(result.productionEntry, false);
    final other = Directory(
      '${build.repository.path}/.dart_tool/flutter_build/${'b' * 32}',
    )..createSync();
    File('${build.receipt.path}/app.dill').copySync('${other.path}/app.dill');
    File('${other.path}/kernel_snapshot_program.stamp').writeAsStringSync(
      jsonEncode({
        'inputs': [
          ...build.inputs,
          '${build.packages['sample']!.path}/lib/another.dart',
        ],
        'outputs': ['${other.path}/app.dill'],
      }),
    );
    await expectLater(
      build.collect(entry: 'tools/native_test.dart'),
      throwsStateError,
    );
  });
}
