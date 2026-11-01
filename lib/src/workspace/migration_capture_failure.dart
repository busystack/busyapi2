part of 'migration_review.dart';

typedef _CaptureResource = ({int generation, String identity});
typedef _CaptureFinding = ({
  String message,
  String severity,
  String resource,
  String pointer,
  SourceRange range,
});

/// Presentation of the failed capture, never a new validation or edit plan.
class _CaptureFailure {
  _CaptureFailure(Map<String, dynamic> analysis, String root) {
    final capturedResources = analysis['resources'];
    if (capturedResources is List) {
      for (final value in capturedResources) {
        if (value case {
          'id': String id,
          'generation': int generation,
          'identity': String identity,
        }) {
          resources[id] = (generation: generation, identity: identity);
        }
      }
    }
    final capturedFindings = analysis['findings'];
    if (capturedFindings is List) {
      for (final value in capturedFindings) {
        if (value
            case {
              'root': String findingRoot,
              'resource': String resource,
              'pointer': String pointer,
              'message': String message,
              'severity': String severity,
              'range': [int start, int end],
            }
            when findingRoot == root && start >= 0 && end >= start) {
          findings.add((
            message: message,
            severity: severity,
            resource: resource,
            pointer: pointer,
            range: SourceRange(start, end),
          ));
        }
      }
    }
  }
  final resources = <String, _CaptureResource>{};
  final findings = <_CaptureFinding>[];

  bool current(BufferStore store) =>
      resources.isNotEmpty &&
      resources.entries.every((entry) {
        if (store.isVirtuallyAbsent(entry.key)) return false;
        final buffer = store.buffers[entry.key];
        return buffer == null ||
            buffer.generation == entry.value.generation &&
                buffer.sourceIdentity == entry.value.identity;
      });
}

List<Widget> _captureFailureRows(
  BuildContext context,
  _CaptureFailure capturedFailure, {
  required bool current,
  required bool busy,
  required int page,
  required ValueChanged<int> onPageChanged,
  required ValueChanged<_CaptureFinding> onReveal,
}) {
  final l = context.l10n;
  return [
    if (!current)
      BusyApiStatusBox(
        message: l.outputOutdated,
        kind: BusyApiStatusKind.warning,
      ),
    if (capturedFailure.findings.length > 50)
      BusyApiReviewPages(
        page: page,
        pages: (capturedFailure.findings.length / 50).ceil(),
        onChanged: onPageChanged,
      ),
    for (final finding in capturedFailure.findings.skip(page * 50).take(50))
      BusyApiActionRow(
        title: finding.message,
        leading: Text(l.governanceSeverity(finding.severity)),
        subtitle: '${finding.resource} ${finding.pointer}',
        onTap:
            !busy &&
                current &&
                capturedFailure.resources.containsKey(finding.resource)
            ? () => onReveal(finding)
            : null,
      ),
  ];
}
