// Trusted AB-only ordinary Flutter comparison entry. Never packaged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  var sequence = 0;
  void record(String event, Map<String, Object?> data) => stderr.writeln(
    jsonEncode({
      'seq': ++sequence,
      'wall_us': DateTime.now().microsecondsSinceEpoch,
      'event': event,
      ...data,
    }),
  );
  final controller = TextEditingController(text: 'AB');
  controller.selection = const TextSelection.collapsed(offset: 2);
  controller.addListener(() => record('value', controller.value.toJSON()));
  HardwareKeyboard.instance.addHandler((event) {
    record('hardware', {
      'type': event.runtimeType.toString(),
      'physical': event.physicalKey.usbHidUsage,
      'logical': event.logicalKey.keyId,
      'char': event.character,
    });
    return false;
  });
  runApp(
    MaterialApp(
      home: Scaffold(
        body: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          keyboardType: TextInputType.multiline,
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    stderr.writeln('ORDINARY_READY');
  });
}
