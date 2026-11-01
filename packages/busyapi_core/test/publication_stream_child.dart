import 'dart:io';
import 'dart:typed_data';

import 'package:busyapi_core/busyapi_core.dart';

Future<void> main(List<String> args) async {
  const bytes = [0, 255, 128, 17, 0, 7];
  if (args[0] == 'bytes') {
    await const AtomicFileWriter().writeBytes(args[1], bytes, overwrite: false);
    return;
  }
  final private = await Directory.systemTemp.createTemp(
    'busyapi-sync-response-',
  );
  final source = File('${private.path}/body.bin');
  await source.writeAsBytes(bytes, flush: true);
  final response = ContractHttpResponse(
    runId: 'controlled',
    status: 200,
    reason: 'OK',
    headers: const [],
    bodyFile: source.path,
    bodyLength: bytes.length,
    bodyIdentity: contentIdentity(bytes),
    receiptComplete: true,
    elapsed: Duration.zero,
    firstByte: Duration.zero,
    redirects: const [],
    displayBytes: Uint8List.fromList(bytes),
  );
  try {
    await response.export(args[1]);
  } finally {
    await response.close();
  }
}
