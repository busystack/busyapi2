"""Production Source completion in an owned, captured Swagger response fragment."""
import time
from pathlib import Path

from test_openapi_application import (
    complete_problems, contains, design_values, keys, mode, tree, wait_tree,
)


def source_caret(native, pid, text, offset):
    assert 0 <= offset <= len(text) and len(text) < 1024
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, pid, lambda nodes: any(node['editable'] and node['focused'] and node['text'] == text for node in nodes), 'The expected complete Source buffer did not own input')
    prefix = text[:offset]
    line, column = prefix.count('\n'), len(prefix.rsplit('\n', 1)[-1])
    keys(native, ['Control_L+Home'] + ['Down'] * line + ['Home'] + ['Right'] * column)
    expected = len(prefix.encode('utf-16-le')) // 2
    wait_tree(native, pid, lambda nodes: any(node['editable'] and node['focused'] and node['text'] == text and node['caret'] == expected for node in nodes), 'Source caret did not reach its captured field')


def complete_file_type(native, process, file, fragment, baseline, version):
    original = baseline[str(fragment)].decode('utf-8-sig')
    root = baseline[str(file)].decode('utf-8-sig')
    bom = b'\xef\xbb\xbf' if baseline[str(fragment)].startswith(b'\xef\xbb\xbf') else b''
    assert original.count('string') == 1
    reference = './model.' + fragment.suffix[1:] + '#/File'
    assert root.count(reference) == 1
    mode(native, process.pid, 'source')
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['text'] == root for node in nodes), 'Source did not expose the captured root')
    source_caret(native, process.pid, root, root.index(reference) + 3)
    keys(native, ['Control_L+b'])
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['text'] == original for node in nodes), 'Native definition navigation did not open the response fragment')
    source_caret(native, process.pid, original, original.index('string') + 2)
    keys(native, ['Control_L+space'])
    wait_tree(native, process.pid, lambda nodes: contains(nodes, '7 suggestions'), 'The native Source popup omitted legal response choices')
    # Native keyboard traversal also proves the lazily rendered final row is
    # reachable without changing the source caret or moving desktop focus.
    keys(native, ['Down'] * 6)
    wait_tree(native, process.pid, lambda nodes: any(node['name'].split('\n')[0] == 'file' for node in nodes), 'The native completion list did not reveal its file row')
    keys(native, ['Return'])
    changed = original.replace('string', 'file', 1)
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['text'] == changed for node in nodes) and complete_problems(nodes), 'The captured file completion was not accepted as valid Swagger')
    assert all(Path(name).read_bytes() == raw for name, raw in baseline.items())
    keys(native, ['Control_L+z'])
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['text'] == original for node in nodes), 'One native Undo did not restore the exact fragment')
    keys(native, ['Control_L+Shift_L+z'])
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['text'] == changed for node in nodes), 'One native Redo did not restore the file choice')
    keys(native, ['Control_L+s'])
    changed_bytes = bom + changed.encode()
    expected = {**baseline, str(fragment): changed_bytes}
    deadline = time.monotonic() + 30
    while any(Path(name).read_bytes() != raw for name, raw in expected.items()):
        native.ready()
        if time.monotonic() > deadline:
            raise RuntimeError('Native Source save did not preserve the localized completion')
        time.sleep(0.1)
    keys(native, ['Control_L+s'])
    assert all(Path(name).read_bytes() == raw for name, raw in expected.items())
    mode(native, process.pid, 'design')
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: design_values(nodes, 'edited ' + version, 'api-version2') and complete_problems(nodes), 'The file completion changed document or API version ownership')
    return {str(fragment): changed_bytes}, {
        'complete': True, 'definitionNavigation': True, 'keyboardCompletion': True,
        'oneOperationUndoRedo': True, 'exactMultiFileSave': True,
        'rootUnchanged': True, 'declaration': '2.0',
    }
