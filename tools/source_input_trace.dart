// Development-only passive protocol tracing for the pinned Flutter SDK.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:busyapi_core/busyapi_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:busyapi/src/source/source_editor.dart';

var _sequence = 0;
void inputRecord(String phase, Map<String, Object?> values) {
  if (_sequence >= 10000) return;
  stderr.writeln(
    'BUSYAPI_INPUT ${jsonEncode({'version': 1, 'sequence': ++_sequence, 'wallUs': DateTime.now().microsecondsSinceEpoch, 'phase': phase, ...values})}',
  );
}

Map<String, Object?> editingIdentity(Map value) => {
  'textUnits': (value['text'] as String?)?.length,
  'textIdentity':
      value['text'] is String && (value['text'] as String).length <= 65536
      ? textIdentity(value['text'])
      : null,
  'selection': [value['selectionBase'], value['selectionExtent']],
  'composing': [value['composingBase'], value['composingExtent']],
};

class InputTraceBinding extends WidgetsFlutterBinding {
  @override
  BinaryMessenger createBinaryMessenger() =>
      _InputMessenger(super.createBinaryMessenger());
}

class _InputMessenger extends BinaryMessenger {
  _InputMessenger(this.delegate);
  final BinaryMessenger delegate;
  void record(String direction, String channel, ByteData? data) {
    if (channel != 'flutter/textinput' || data == null) return;
    final call = const JSONMethodCodec().decodeMethodCall(data);
    final arguments = call.arguments;
    final values = <String, Object?>{'method': call.method};
    if (call.method == 'TextInput.setEditingState' && arguments is Map) {
      values.addAll(editingIdentity(arguments));
    } else if (call.method == 'TextInputClient.updateEditingState' &&
        arguments is List &&
        arguments.length > 1 &&
        arguments[1] is Map) {
      values['client'] = arguments[0];
      values.addAll(editingIdentity(arguments[1]));
    } else if (call.method == 'TextInput.setClient' && arguments is List) {
      values['client'] = arguments[0];
    }
    inputRecord(direction, values);
  }

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    record('platform.outbound', channel, message);
    return delegate.send(channel, message);
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {
    delegate.setMessageHandler(
      channel,
      handler == null
          ? null
          : (data) {
              record('platform.inbound', channel, data);
              return handler(data);
            },
    );
  }

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) =>
      // Pinned legacy BinaryMessenger interface; not used by this observer.
      // ignore: deprecated_member_use
      delegate.handlePlatformMessage(channel, data, callback);
}

void installInputTracing() {
  SourceEditorState.debugObservation = (event) {
    final value = event.value, edit = event.edit;
    inputRecord('source.${event.phase}', {
      'resource': event.resource,
      'generation': event.generation,
      'window': [event.start, event.end],
      'coreUnits': event.source.length,
      'coreIdentity': event.source.length <= 65536
          ? textIdentity(event.source)
          : null,
      'coreVisibleIdentity': textIdentity(
        event.pieces
                ?.map((r) => event.source.substring(r.start, r.end))
                .join() ??
            event.source.substring(
              event.start.clamp(0, event.source.length),
              event.end.clamp(0, event.source.length),
            ),
      ),
      'controllerUnits': value.text.length,
      'controllerIdentity': textIdentity(value.text),
      'selection': [value.selection.baseOffset, value.selection.extentOffset],
      'coreSelection': [event.selection.base, event.selection.extent],
      'composing': [value.composing.start, value.composing.end],
      if (edit != null)
        'edit': {
          'generation': edit.generation,
          'range': [edit.start, edit.end],
          'expectedIdentity': textIdentity(edit.expected),
          'replacementIdentity': textIdentity(edit.replacement),
          'replacementUnits': edit.replacement.length,
        },
    });
  };
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // The pinned key-message hook delegates synchronously to the existing focus
    // handler. It observes consumption; it does not translate printable keys.
    // ignore: deprecated_member_use
    final manager = ServicesBinding.instance.keyEventManager;
    // ignore: deprecated_member_use
    final previous = manager.keyMessageHandler;
    // ignore: deprecated_member_use
    manager.keyMessageHandler = (message) {
      final events = [
        for (final event in message.events)
          {
            'type': event.runtimeType.toString(),
            'physical': event.physicalKey.usbHidUsage,
            'logical': event.logicalKey.keyId,
            'repeat': event is KeyRepeatEvent,
          },
      ];
      inputRecord('key.delivery', {'events': events});
      final handled = previous?.call(message) ?? false;
      inputRecord('key.handled', {'handled': handled, 'events': events});
      return handled;
    };
  });
}
