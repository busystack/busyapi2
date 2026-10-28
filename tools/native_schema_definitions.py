"""Production Design maintenance over owned synthetic schema definitions."""
import time
from pathlib import Path

from test_openapi_application import (
    activate_control, complete_problems, contains, design_values, field_matches,
    focus_control, keys, mode, text_keys, tree, wait_tree,
)


def maintain_definitions(native, process, file, fragment, baseline, version, keyword='$defs'):
    before_pointer = '/Envelope/' + keyword + '/Old'
    after_pointer = '/Envelope/' + keyword + '/Renamed'
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 455], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Envelope') and contains(nodes, 'Use') and contains(nodes, 'Add entry'),
        'Native schemas collection did not expose its captured definitions')
    activate_control(native, process.pid, 'Use')
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Edit Definition') and contains(nodes, '/components/schemas/Use'),
        'Schema reference did not retain its native occurrence')
    activate_control(native, process.pid, 'Edit Definition')
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, 'Rename schema definition') and contains(nodes, before_pointer),
        'Native definition navigation did not expose the captured schema-definition binding')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    for accept in [False, True]:
        activate_control(native, process.pid, 'Rename schema definition')
        wait_tree(native, process.pid,
            lambda nodes: field_matches(nodes, 'Name', value='Old', editable=True),
            'Native definition rename did not retain the captured name')
        focus_control(native, process.pid, 'Name')
        keys(native, ['Control_L+a'] + text_keys('Renamed'))
        wait_tree(native, process.pid,
            lambda nodes: field_matches(nodes, 'Name', value='Renamed', focused=True),
            'Native definition name did not retain real input')
        activate_control(native, process.pid, 'Apply')
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Review refactoring'),
                  'Native definition change bypassed review')
        assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
        activate_control(native, process.pid, 'Apply' if accept else 'Cancel')
        wait_tree(native, process.pid, lambda nodes: not contains(nodes, 'Review refactoring'),
                  'Native definition review did not finish')
        if not accept:
            wait_tree(native, process.pid,
                lambda nodes: contains(nodes, before_pointer) and contains(nodes, 'Rename schema definition'),
                'Cancelled native review changed the selected binding')
    wait_tree(native, process.pid,
        lambda nodes: contains(nodes, after_pointer) and complete_problems(nodes),
        'Reviewed definition did not retain its renamed native scope')
    old_token = b"'Old': false" if fragment.suffix == '.yaml' else b'"Old": false'
    new_token = old_token.replace(b'Old', b'Renamed')
    changed = {
        str(file): baseline[str(file)].replace(before_pointer.encode(), after_pointer.encode(), 1),
        str(fragment): baseline[str(fragment)].replace(old_token, new_token, 1),
    }
    assert changed[str(file)] != baseline[str(file)]
    assert changed[str(fragment)] != baseline[str(fragment)]
    mode(native, process.pid, 'source')
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and new_token.decode() in (node['text'] or '') for node in nodes),
        'Source did not expose the renamed shared definition')
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and node['focused'] for node in nodes),
        'Definition Source did not own history input')
    keys(native, ['Control_L+z'])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and old_token.decode() in (node['text'] or '') for node in nodes),
        'One native Undo did not restore the shared definition')
    keys(native, ['Control_L+Shift_L+z'])
    wait_tree(native, process.pid,
        lambda nodes: any(node['editable'] and new_token.decode() in (node['text'] or '') for node in nodes),
        'One native Redo did not restore the renamed definition')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    keys(native, ['Control_L+s'])
    deadline = time.monotonic() + 30
    while any(Path(name).read_bytes() != raw for name, raw in changed.items()):
        native.ready()
        if time.monotonic() > deadline:
            raise RuntimeError('Native definition save did not preserve the exact reviewed source changes')
        time.sleep(0.1)
    keys(native, ['Control_L+s'])
    assert all(Path(name).read_bytes() == raw for name, raw in changed.items())
    mode(native, process.pid, 'design')
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid,
        lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes),
        'Native overview did not retain the original family after schema maintenance')
    return changed, {'definitionContainer': keyword, 'reviewCancelled': True, 'reviewApplied': True, 'definitionNavigation': True,
                     'oneOperationUndoRedo': True, 'exactMultiFileSave': True}
