// Development-only entry point. Observes the normal application; never packaged.
import 'source_input_trace.dart';
import 'source_input_prediction.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:busyapi/main.dart' as application;
import 'package:busyapi/src/app/busyapi_app.dart';
import 'package:busyapi/src/source/source_editor.dart';
import 'package:busyapi_core/busyapi_core.dart';

class _Input {
  _Input(
    this.delivery,
    this.resource,
    this.generation,
    this.expected,
    this.prediction,
  );
  final int delivery, generation;
  final String resource;
  String expected;
  final SourceInputPrediction prediction;
  int? accepted, acceptedGeneration;
}

Future<void> main(List<String> args) async {
  final traceInput = Platform.environment['BUSYAPI_TRACE_INPUT'] == '1';
  if (traceInput) {
    InputTraceBinding();
    installInputTracing();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  if (Platform.environment['BUSYAPI_TRACE_WIDGETS'] == '1') {
    debugProfileBuildsEnabled = true;
    debugProfileLayoutsEnabled = true;
    debugProfilePaintsEnabled = true;
  }
  final pending = <_Input>[];
  final prepared = <int, Map<String, Object?>>{};
  WorkspaceScreen? screen;
  var records = 0;

  // Read the actual rendered source subtree. Keep window text only in bounded
  // memory, never in output. Matching RenderEditable.text ties a frame to its
  // accepted content, rather than assigning every key to the next arbitrary frame.
  (SourceEditor?, EditableTextState?) source() {
    SourceEditor? editor;
    EditableTextState? editable;
    void findEditable(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        if (state.widget.focusNode.hasFocus) editable = state;
      } else {
        element.visitChildren(findEditable);
      }
    }

    void visit(Element element) {
      if (element.widget is SourceEditor) {
        editor = element.widget as SourceEditor;
        element.visitChildren(findEditable);
      } else {
        element.visitChildren(visit);
      }
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return (editor, editable);
  }

  final previousObservation = SourceEditorState.debugObservation;
  SourceEditorState.debugObservation = (event) {
    previousObservation?.call(event);
    if (event.edit == null ||
        (event.phase != 'editing.complete' &&
            event.phase != 'replacement.complete'))
      return;
    final candidates = pending
        .where((p) => p.resource == event.resource && p.accepted == null)
        .toList();
    // A hardware prediction only establishes attribution for an unambiguous
    // update against that same source generation. Native/IME batches are not
    // declared accepted just because the buffer's generation advanced.
    if (candidates.length == 1 &&
        candidates.single.generation == event.edit!.generation &&
        candidates.single.prediction.accepted(event.edit) &&
        candidates.single.prediction.project(
              event.pieces ?? [SourceRange(event.start, event.end)],
            ) ==
            event.value.text &&
        event.generation > candidates.single.generation) {
      candidates.single.expected = candidates.single.prediction.project(
        event.pieces ?? [SourceRange(event.start, event.end)],
      );
      candidates.single.accepted = DateTime.now().microsecondsSinceEpoch;
      candidates.single.acceptedGeneration = event.generation;
    } else if (candidates.isNotEmpty) {
      inputRecord('frame.unattributed-acceptance', {
        'resource': event.resource,
        'generation': event.generation,
        'editGeneration': event.edit!.generation,
        'pendingDeliveriesWallUs': [
          for (final input in candidates) input.delivery,
        ],
      });
    }
  };

  void observePrepared(Duration _) {
    if (pending.isEmpty || records >= 10000) return;
    final (editor, editable) = source();
    if (editor == null || editable == null) return;
    final rendered = editable.renderEditable.text?.toPlainText();
    final matching = pending
        .where(
          (p) =>
              p.resource == editor.buffer.id &&
              p.acceptedGeneration == editor.buffer.generation &&
              p.expected == rendered,
        )
        .toList();
    if (matching.isEmpty) return;
    final newest = matching.last;
    final coalesced = pending
        .where(
          (p) =>
              p.resource == newest.resource &&
              p.accepted != null &&
              p.delivery <= newest.delivery,
        )
        .toList();
    final frame = PlatformDispatcher.instance.frameData.frameNumber;
    prepared[frame] = {
      'version': 3,
      'frame': frame,
      'unmatchedEarlierInputs': pending
          .where(
            (p) =>
                p.resource == newest.resource &&
                p.accepted == null &&
                p.delivery <= newest.delivery,
          )
          .length,
      'inputWallUs': newest.delivery,
      'acceptedWallUs': newest.accepted,
      'generation': newest.acceptedGeneration,
      'coalescedInputs': coalesced.length,
      'coalescedDeliveriesWallUs': [for (final p in coalesced) p.delivery],
      'preparedWallUs': DateTime.now().microsecondsSinceEpoch,
    };
    pending.removeWhere(coalesced.contains);
    while (prepared.length > 100) {
      prepared.remove(prepared.keys.first);
    }
  }

  HardwareKeyboard.instance.addHandler((event) {
    final delivery = DateTime.now().microsecondsSinceEpoch;
    if (records >= 10000 ||
        event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.keyX &&
            event.logicalKey != LogicalKeyboardKey.backspace)) {
      return false;
    }
    final (editor, editable) = source();
    if (editor == null || editable == null) return false;
    if (pending.length >= 100) {
      inputRecord('frame.input-overflow', {
        'resource': editor.buffer.id,
        'deliveryWallUs': delivery,
      });
      return false;
    }
    final value = editable.widget.controller.value;
    if (!value.selection.isValid || !value.composing.isCollapsed) return false;
    var start = value.selection.start, end = value.selection.end;
    final full = editor.buffer.text, selected = editor.buffer.selection;
    var physicalStart = selected.base < selected.extent
        ? selected.base
        : selected.extent;
    final physicalEnd = selected.base > selected.extent
        ? selected.base
        : selected.extent;
    String replacement = 'x';
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      replacement = '';
      if (physicalStart == physicalEnd && physicalStart > 0) {
        physicalStart =
            CharacterBoundary(full)
                .getLeadingTextBoundaryAt(physicalStart - 1) ??
            0;
      }
      if (start == end && start > 0) {
        start--;
        if (start > 0 &&
            value.text.codeUnitAt(start) >= 0xdc00 &&
            value.text.codeUnitAt(start) <= 0xdfff) {
          start--;
        }
      }
    }
    pending.add(
      _Input(
        delivery,
        editor.buffer.id,
        editor.buffer.generation,
        value.text.replaceRange(start, end, replacement),
        SourceInputPrediction(
          full,
          TextEdit(
            buffer: editor.buffer.id,
            generation: editor.buffer.generation,
            start: physicalStart,
            end: physicalEnd,
            expected: full.substring(physicalStart, physicalEnd),
            replacement: replacement,
          ),
        ),
      ),
    );
    return false;
  });
  SchedulerBinding.instance.addTimingsCallback((frames) {
    for (final frame in frames) {
      final response = prepared.remove(frame.frameNumber);
      if (response == null) continue;
      records++;
      stderr.writeln(
        'BUSYAPI_FRAME ${jsonEncode({...response, 'rasterFinishWallUs': frame.timestampInMicroseconds(FramePhase.rasterFinishWallTime), 'buildUs': frame.buildDuration.inMicroseconds, 'rasterUs': frame.rasterDuration.inMicroseconds, 'vsyncStartWallUs': frame.timestampInMicroseconds(FramePhase.rasterFinishWallTime) - frame.timestampInMicroseconds(FramePhase.rasterFinish) + frame.timestampInMicroseconds(FramePhase.vsyncStart), 'buildStartWallUs': frame.timestampInMicroseconds(FramePhase.rasterFinishWallTime) - frame.timestampInMicroseconds(FramePhase.rasterFinish) + frame.timestampInMicroseconds(FramePhase.buildStart), 'buildFinishWallUs': frame.timestampInMicroseconds(FramePhase.rasterFinishWallTime) - frame.timestampInMicroseconds(FramePhase.rasterFinish) + frame.timestampInMicroseconds(FramePhase.buildFinish), 'rasterStartWallUs': frame.timestampInMicroseconds(FramePhase.rasterFinishWallTime) - frame.timestampInMicroseconds(FramePhase.rasterFinish) + frame.timestampInMicroseconds(FramePhase.rasterStart)})}',
      );
    }
  });
  WidgetsBinding.instance.addPersistentFrameCallback((_) {
    WidgetsBinding.instance.addPostFrameCallback(observePrepared);
  });
  await application.main(args);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    void visit(Element element) {
      final widget = element.widget;
      if (widget is WorkspaceScreen && screen == null) {
        screen = widget;
        final view = View.of(element);
        stderr.writeln(
          'BUSYAPI_VIEW ${jsonEncode({'version': 2, 'pid': pid, 'deviceScale': view.devicePixelRatio, 'physicalWidth': view.physicalSize.width, 'physicalHeight': view.physicalSize.height, 'textScaleAt14': MediaQuery.textScalerOf(element).scale(14) / 14, 'brightness': Theme.of(element).brightness.name, 'mode': kProfileMode
              ? 'profile'
              : kReleaseMode
              ? 'release'
              : 'debug', 'dart': Platform.version})}',
        );
        final controller = widget.controller;
        String? previous;
        controller.addListener(() {
          if (controller.disposed || records >= 10000) return;
          final accepted = DateTime.now().microsecondsSinceEpoch;
          if (controller.checking) return;
          final snapshot = controller.analysis?['snapshot'] as String?;
          final timings = controller.project?.lastTimings;
          if (snapshot == null || snapshot == previous || timings == null) {
            return;
          }
          previous = snapshot;
          stderr.writeln(
            'BUSYAPI_ANALYSIS ${jsonEncode({'version': 2, 'completedWallUs': accepted, 'timings': timings})}',
          );
        });
      } else {
        element.visitChildren(visit);
      }
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  });
}
