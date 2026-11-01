import 'dart:io';

import '../bin/busyapi.dart' as cli;

Future<void> main(List<String> args) => cli.runBusyApi(
  args,
  beforePublish: (path) async {
    if (path.endsWith('busyapi.yaml')) {
      File(path).writeAsStringSync('concurrent manifest\n');
    }
  },
);
