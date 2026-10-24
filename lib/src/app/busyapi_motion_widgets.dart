// Adapted from BusyMark, Copyright 2026 BusyStack (Apache-2.0).
// Modified for BusyAPI namespaces and contract authoring.
import 'package:flutter/widgets.dart';

import 'busyapi_design.dart';

/// A semantic view change fades the single live editor surface into place.
/// The editing tree, keys, controllers and input remain owned by the caller.
class BusyApiSemanticFade extends StatefulWidget {
  const BusyApiSemanticFade({
    super.key,
    required this.transitionKey,
    required this.child,
  });
  final Object transitionKey;
  final Widget child;
  @override
  State<BusyApiSemanticFade> createState() => _BusyApiSemanticFadeState();
}

class _BusyApiSemanticFadeState extends State<BusyApiSemanticFade>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    value: 1,
    animationBehavior: AnimationBehavior.preserve,
  );
  bool _disabled = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disabled = MediaQuery.disableAnimationsOf(context);
    if (_disabled) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant BusyApiSemanticFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.transitionKey == oldWidget.transitionKey) return;
    if (_disabled) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.duration = BusyApiMotion.crossfade;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _controller.drive(
      CurveTween(curve: BusyApiMotion.presentationCurve),
    ),
    child: widget.child,
  );
}

/// Crossfades a fixed set of live pages without reconstructing destinations.
class BusyApiRetainedCrossfade extends StatefulWidget {
  const BusyApiRetainedCrossfade({
    super.key,
    required this.index,
    required this.children,
    this.duration = BusyApiMotion.crossfade,
  }) : assert(children.length > 0),
       assert(index >= 0 && index < children.length);

  final int index;
  final List<Widget> children;
  final Duration duration;

  @override
  State<BusyApiRetainedCrossfade> createState() =>
      _BusyApiRetainedCrossfadeState();
}

/// A semantic destination host: data rebuilds update the active destination,
/// while every previously visited destination keeps its live element state.
/// Only a changed [transitionKey] starts a crossfade.
class BusyApiKeyedCrossfade extends StatefulWidget {
  const BusyApiKeyedCrossfade({
    super.key,
    required this.transitionKey,
    required this.child,
    this.duration = BusyApiMotion.crossfade,
  });

  final Object transitionKey;
  final Widget child;
  final Duration duration;

  @override
  State<BusyApiKeyedCrossfade> createState() => _BusyApiKeyedCrossfadeState();
}

class _BusyApiKeyedCrossfadeState extends State<BusyApiKeyedCrossfade> {
  late final List<Object> _keys;
  late final List<GlobalKey> _destinationKeys;
  late final List<Widget> _destinations;
  var _index = 0;

  @override
  void initState() {
    super.initState();
    final key = GlobalKey(
      debugLabel: 'busyapi-destination-${widget.transitionKey}',
    );
    _keys = [widget.transitionKey];
    _destinationKeys = [key];
    _destinations = [KeyedSubtree(key: key, child: widget.child)];
  }

  @override
  void didUpdateWidget(covariant BusyApiKeyedCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    final destination = _keys.indexOf(widget.transitionKey);
    if (destination < 0) {
      _keys.add(widget.transitionKey);
      final key = GlobalKey(
        debugLabel: 'busyapi-destination-${widget.transitionKey}',
      );
      _destinationKeys.add(key);
      _destinations.add(KeyedSubtree(key: key, child: widget.child));
      _index = _keys.length - 1;
    } else {
      _index = destination;
      _destinations[destination] = KeyedSubtree(
        key: _destinationKeys[destination],
        child: widget.child,
      );
    }
  }

  @override
  Widget build(BuildContext context) => BusyApiRetainedCrossfade(
    index: _index,
    duration: widget.duration,
    // Widgets are immutable. Do not let an older retained host observe later
    // in-place destination-list edits during element reconciliation.
    children: List<Widget>.of(_destinations, growable: false),
  );
}

class _BusyApiRetainedCrossfadeState extends State<BusyApiRetainedCrossfade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
    value: 1,
  );
  late int _current = widget.index;
  int? _outgoing;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_handleStatus);
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _outgoing != null && mounted) {
      setState(() => _outgoing = null);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (disabled != _disableAnimations) {
      _disableAnimations = disabled;
      if (disabled) {
        _controller.stop();
        _outgoing = null;
        _controller.value = 1;
      }
    }
  }

  @override
  void didUpdateWidget(covariant BusyApiRetainedCrossfade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _current) return;
    if (widget.index == _outgoing && _controller.isAnimating) {
      // A -> B -> A reverses from the presentation currently on screen.
      // Swapping the roles and complementing progress preserves both page
      // opacities instead of replaying a complete transition from an endpoint.
      final previousCurrent = _current;
      _current = widget.index;
      _outgoing = previousCurrent;
      _controller.value = 1 - _controller.value;
    } else {
      _outgoing = _current;
      _current = widget.index;
      _controller.value = 0;
    }
    if (_disableAnimations || widget.duration == Duration.zero) {
      _finish();
      return;
    }
    final distance = 1 - _controller.value;
    if (distance == 0) {
      _finish();
      return;
    }
    _controller.animateTo(
      1,
      duration: widget.duration * distance,
      curve: BusyApiMotion.presentationCurve,
    );
  }

  void _finish() {
    if (!mounted) return;
    _outgoing = null;
    _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_handleStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Stack(
        fit: StackFit.loose,
        children: [
          for (var index = 0; index < widget.children.length; index++)
            _RetainedPage(
              key: ValueKey(('busyapi-retained-page', index)),
              active: index == _current,
              outgoing: index == _outgoing,
              opacity: index == _current
                  ? _controller.value
                  : index == _outgoing
                  ? 1 - _controller.value
                  : 0,
              child: widget.children[index],
            ),
        ],
      ),
    );
  }
}

class _RetainedPage extends StatelessWidget {
  const _RetainedPage({
    super.key,
    required this.active,
    required this.outgoing,
    required this.opacity,
    required this.child,
  });

  final bool active;
  final bool outgoing;
  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Offstage(
      offstage: !active && !outgoing,
      child: IgnorePointer(
        ignoring: !active,
        child: ExcludeFocus(
          excluding: !active,
          child: ExcludeSemantics(
            excluding: !active,
            child: TickerMode(
              enabled: active,
              child: Opacity(opacity: opacity, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
