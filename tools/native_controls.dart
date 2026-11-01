// Fixture-side coordinates and observations for the existing owned XTest driver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:busyapi/src/app/busyapi_design.dart';
import 'package:flutter/material.dart';

void nativeCheck(bool condition, String code) {
  if (!condition) throw StateError(code);
}

List<Element> nativeElements(bool Function(Widget) matches) {
  final found = <Element>[];
  bool interactive(Element element) {
    var active = true;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Offstage && widget.offstage ||
          widget is IgnorePointer && widget.ignoring) {
        active = false;
      }
      return active;
    });
    return active;
  }

  void visit(Element element) {
    if (matches(element.widget) && interactive(element)) found.add(element);
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<void> nativeWait(bool Function() ready, String code) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    nativeCheck(watch.elapsed < const Duration(seconds: 30), code);
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class NativeControls {
  final _input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  int steps = 0;

  Future<void> send(Map<String, Object> action) async {
    final step = ++steps;
    stdout.writeln(
      'BUSYAPI_FILE_CONTROLS_INPUT ${jsonEncode({'version': 1, 'step': step, ...action})}',
    );
    nativeCheck(
      await _input.moveNext().timeout(const Duration(seconds: 30)) &&
          _input.current == 'ack:$step',
      'native-input-owner',
    );
  }

  Future<void> keys(List<String> chords) =>
      send({'kind': 'keys', 'chords': chords});
  Future<void> close() => _input.cancel();

  Future<void> click(
    bool Function(Widget) matches,
    String code, {
    bool editable = false,
  }) async {
    await nativeWait(
      () => nativeElements(matches).length == 1,
      '$code-mounted',
    );
    var target = nativeElements(matches).single;
    if (editable) {
      final fields = <Element>[];
      void visit(Element element) {
        if (element.widget is EditableText) fields.add(element);
        element.visitChildren(visit);
      }

      target.visitChildren(visit);
      nativeCheck(fields.length == 1, '$code-editable');
      target = fields.single;
    }
    await Scrollable.ensureVisible(
      target,
      alignment: .35,
      duration: Duration.zero,
    );
    await WidgetsBinding.instance.endOfFrame;
    final box = target.findRenderObject();
    nativeCheck(box is RenderBox && box.hasSize, '$code-geometry');
    final render = box! as RenderBox,
        point = render.localToGlobal(render.size.center(Offset.zero));
    await send({
      'kind': 'click',
      'point': [point.dx, point.dy],
      'scale': View.of(target).devicePixelRatio,
      'viewport': [
        View.of(target).physicalSize.width,
        View.of(target).physicalSize.height,
      ],
    });
    if (editable) {
      await nativeWait(
        () =>
            target.mounted &&
            target.widget is EditableText &&
            (target.widget as EditableText).focusNode.hasFocus,
        '$code-focused',
      );
    }
  }

  Future<void> button(String label) => click(
    (widget) => widget is BusyApiDialogButton && widget.label == label,
    'native-button',
  );

  Future<void> combo(String title, String value) async {
    final matches = nativeElements(
      (widget) => widget is BusyApiComboRow<String> && widget.title == title,
    );
    nativeCheck(matches.length == 1, 'native-combo-owner');
    final combo = matches.single.widget as BusyApiComboRow<String>,
        index = combo.values.indexOf(value);
    nativeCheck(index >= 0 && combo.enabled, 'native-combo-value');
    if (combo.selected == value) return;
    await click(
      (widget) => widget is BusyApiComboRow<String> && widget.title == title,
      'native-combo',
    );
    await send({'kind': 'menu-ready'});
    await keys(['Home', for (var i = 0; i < index; i++) 'Down', 'Return']);
    await nativeWait(
      () =>
          nativeElements(
            (widget) =>
                widget is BusyApiComboRow<String> &&
                widget.title == title &&
                widget.selected == value,
          ).length ==
          1,
      'native-combo-selected',
    );
  }

  Future<void> menu(String tooltip, String value) async {
    await nativeWait(
      () =>
          nativeElements(
            (widget) =>
                widget is BusyApiHeaderPopupMenuButton<String> &&
                widget.tooltip == tooltip,
          ).length ==
          1,
      'native-menu-mounted',
    );
    final matches = nativeElements(
      (widget) =>
          widget is BusyApiHeaderPopupMenuButton<String> &&
          widget.tooltip == tooltip,
    );
    nativeCheck(matches.length == 1, 'native-menu-owner');
    final element = matches.single,
        menu = element.widget as BusyApiHeaderPopupMenuButton<String>;
    final entries = (await menu.itemBuilder(element))
        .whereType<BusyApiPopupMenuItem<String>>()
        .where((item) => item.enabled)
        .toList();
    final index = entries.indexWhere((item) => item.menuValue == value);
    nativeCheck(index >= 0, 'native-menu-value');
    await click(
      (widget) =>
          widget is BusyApiHeaderPopupMenuButton<String> &&
          widget.tooltip == tooltip,
      'native-menu',
    );
    await send({'kind': 'menu-ready'});
    await keys(['Home', for (var i = 0; i < index; i++) 'Down', 'Return']);
  }
}
