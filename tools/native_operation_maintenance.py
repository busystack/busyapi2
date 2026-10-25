"""Production operation editing and Source navigation on captured fixtures."""
import time
from pathlib import Path

from test_openapi_application import (
    complete_problems, design_values, field_matches, focus_control, keys, mode,
    text_keys, tree, wait_tree,
)


def maintain_operation(native, process, file, fragment, baseline, version):
    native.perform({'kind': 'click', 'scale': 1, 'point': [140, 421], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: field_matches(nodes, 'Summary', value='Inspect items', editable=True),
        'Native operation Summary did not expose its captured value')
    focus_control(native, process.pid, 'Summary')
    summary = 'maintained ' + version
    keys(native, ['Control_L+a'] + text_keys(summary) + ['Tab'])
    wait_tree(native, process.pid,
        lambda nodes: field_matches(nodes, 'Summary', value=summary),
        'Native operation Summary did not retain real input')
    mode(native, process.pid, 'source')
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and summary in (node['text'] or '') for node in nodes),
        'Source did not expose the native operation change')
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and node['focused'] for node in nodes),
        'Operation Source did not own history input')
    keys(native, ['Control_L+z'])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and 'Inspect items' in (node['text'] or '') for node in nodes),
        'One native Undo did not restore the operation Summary')
    keys(native, ['Control_L+Shift_L+z'])
    nodes = wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and node['focused'] and summary in (node['text'] or '') for node in nodes),
        'One native Redo did not restore the operation change')
    value = next(node['text'] for node in nodes if node['editable'] and node['focused'])
    offset = value.index('./model.') + 3
    line = value[:offset].count('\n')
    end = value.find('\n', offset)
    suffix = value[offset:end if end >= 0 else len(value)].rstrip('\r')
    for chord in ['Control_L+Home'] + ['Down'] * line + ['End'] + ['Left'] * len(suffix):
        keys(native, [chord])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and node['focused'] and node['caret'] == offset for node in nodes),
        'Source reference did not retain the exact captured caret')
    keys(native, ['Control_L+b'])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and node['text'] == baseline[str(fragment)].decode('utf-8-sig') for node in nodes),
        'Source definition did not expose the exact captured shared resource')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    mode(native, process.pid, 'design')
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes),
        'Native overview did not retain the original contract after cross-file navigation')
    expected = baseline[str(file)].replace(b'Inspect items', summary.encode(), 1)
    assert expected != baseline[str(file)]
    keys(native, ['Control_L+s'])
    deadline = time.monotonic() + 30
    while file.read_bytes() != expected:
        native.ready()
        if time.monotonic() > deadline:
            raise RuntimeError('Native operation save changed more than its captured Summary')
        time.sleep(0.1)
    keys(native, ['Control_L+s'])
    assert file.read_bytes() == expected
    assert fragment.read_bytes() == baseline[str(fragment)]
    return {str(file): expected}, {'summaryEdited': True, 'oneOperationUndoRedo': True,
                                   'definitionNavigation': True, 'sharedSourceBytesMatched': True,
                                   'exactSave': True}
