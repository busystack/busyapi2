#!/usr/bin/env bash
# Run the existing widget suites in the SDK test engine without a control socket.
# This is an additional headless test path, not native desktop acceptance.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter_bin="${BUSYAPI_FLUTTER:-$(command -v flutter)}"
flutter_path="$(command -v "$flutter_bin")"
sdk="$(dirname "$(dirname "$(readlink -f "$flutter_path")")")"
run_dir="$(mktemp -d /tmp/busyapi-widget-tests.XXXXXX)"
trap 'rm -rf "$run_dir"' EXIT
python3 - "$run_dir" "$@" <<'PY'
import pathlib,sys,json
root=pathlib.Path.cwd(); out=pathlib.Path(sys.argv[1]); files=[pathlib.Path(f) for f in sys.argv[2:]] or sorted(pathlib.Path('test').glob('*_test.dart'))
for file in files:
    if not file.resolve().is_relative_to(root/'test') or not file.is_file(): raise SystemExit('Choose existing widget suites under test/')
imports='\n'.join('import '+json.dumps(file.resolve().as_uri())+f' as suite{i};' for i,file in enumerate(files))
registrations='\n'.join('group('+json.dumps(file.name)+f', suite{i}.main);' for i,file in enumerate(files))
source='''import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/operating_system.dart';
import 'package:test_core/src/runner/engine.dart';
import 'package:test_core/src/runner/environment.dart';
import 'package:test_core/src/runner/runner_suite.dart';
import 'package:test_core/src/runner/suite.dart';
'''+imports+'''
Future<void> main() async {
  var checked = false;
  assert(() { checked = true; return true; }());
  if (!checked) throw StateError('Widget tests require assertions');
  print('Assertions enabled; SDK Flutter test engine');
  TestWidgetsFlutterBinding.ensureInitialized();
  final declarer = Declarer();
  declarer.declare(() {'''+registrations+'''});
  final engine = Engine(concurrency: 1);
  engine.onTestStarted.listen((live) {
    print('START ${live.test.name}');
    live.onError.listen((e) => print('FAIL ${live.test.name}: ${e.error}\\n${e.stackTrace}'));
    live.onComplete.then((_) => print('END ${live.test.name}: ${live.state}'));
  });
  final declared = declarer.build();
  final name = Platform.environment['BUSYAPI_TEST_NAME'];
  final selected = name == null ? declared : declared.filter((test) => test.name.contains(name));
  if (selected == null || selected.testCount == 0) throw StateError('No tests match BUSYAPI_TEST_NAME');
  if (name != null) print('Focused test selection: $name');
  engine.suiteSink.add(RunnerSuite(const PluginEnvironment(), SuiteConfiguration.empty,
    selected, SuitePlatform(Runtime.vm, os: OperatingSystem.linux)));
  engine.suiteSink.close();
  final success = await engine.run();
  print('RESULT passed=${engine.passed.length} failed=${engine.failed.length} skipped=${engine.skipped.length}');
  await engine.close();
  exit(success == true ? 0 : 1);
}
'''
(out/'runner.dart').write_text(source)
PY
"$sdk/bin/cache/dart-sdk/bin/dartaotruntime" "$sdk/bin/cache/artifacts/engine/linux-x64/frontend_server_aot.dart.snapshot" \
  --sdk-root "$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk" --target=flutter --track-widget-creation \
  --packages .dart_tool/package_config.json --output-dill "$run_dir/tests.dill" --enable-asserts "$run_dir/runner.dart" > "$run_dir/compiler.log" 2>&1 || { cat "$run_dir/compiler.log" >&2; exit 1; }
if rg -q 'Error:' "$run_dir/compiler.log"; then cat "$run_dir/compiler.log" >&2; exit 1; fi
FLUTTER_TEST=true "$sdk/bin/cache/artifacts/engine/linux-x64/flutter_tester" \
  --disable-vm-service --enable-checked-mode --verify-entry-points \
  --enable-software-rendering --skia-deterministic-rendering --non-interactive \
  --use-test-fonts --disable-asset-fonts --packages=.dart_tool/package_config.json \
  --flutter-assets-dir=build/unit_test_assets "$run_dir/tests.dill"
