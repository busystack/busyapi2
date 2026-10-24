// Bounded list/editor region composed from BusyMark's dialog and list metrics.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'busyapi_design.dart';

class BusyApiReviewViewport extends StatelessWidget {
  const BusyApiReviewViewport({
    super.key,
    required this.child,
    this.shrinkWrap = false,
  });
  final Widget child;
  final bool shrinkWrap;
  @override
  Widget build(BuildContext context) {
    final height = math.min(
      BusyApiSizes.problemsListHeight,
      MediaQuery.sizeOf(context).height *
          BusyApiSizes.modalMaxHeightFraction /
          2,
    );
    return shrinkWrap
        ? ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: child,
          )
        : SizedBox(height: height, child: child);
  }
}
