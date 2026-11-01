"""Reviewed saved-upload file maintenance in the production Linux application."""
import hashlib
import time
from pathlib import Path

from native_saved_file_media import SavedFileMediaFixture


class CaseFileMaintenanceFixture(SavedFileMediaFixture):
    def prepare(self, directory):
        self.payloads = [b'[0]', b'[1]']
        self.uploads = [directory / 'one.json', directory / 'two.json']
        for file, raw in zip(self.uploads, self.payloads):
            file.write_bytes(raw)


def maintain_case_file(native, process, file, baseline, fixture):
    from test_openapi_application import (
        activate_control, complete_problems, contains, design_values, field_matches,
        focus_control, keys, mode, text_keys, tree, wait_tree,
    )

    source = fixture.uploads[0]
    destination = source.with_name('moved-case.json')
    manifest = source.parent / 'busyapi.yaml'
    original = baseline[str(manifest)]
    expected = original.replace(b'"path":"one.json"', b'"path":"moved-case.json"')
    assert expected != original and original.count(b'"path":"one.json"') == 2

    def sidebar(files):
        # The project-view icon and the global sidebar toggle share a tooltip.
        # NativeInput proves this fixed client viewport before the local click.
        native.perform({'kind': 'click', 'scale': 1, 'point': [275, 77], 'viewport': [1280, 720]})
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'API') and contains(nodes, 'Files'), 'Sidebar menu did not expose native views')
        keys(native, ['Home'] + (['Down'] if files else []) + ['Return'])
        wait_tree(native, process.pid,
                  lambda nodes: contains(nodes, source.name if files else 'Overview'),
                  'The selected native sidebar did not appear')

    def file_menu(name, delete=False):
        nodes = wait_tree(native, process.pid, lambda nodes: contains(nodes, name), 'The captured upload row is unavailable')
        known = {Path(path).name for path in baseline} | {path.name for path in fixture.uploads} | {source.name, destination.name}
        rows = [node['name'].split('\n')[0] for node in nodes
                if node['role'] == 'panel' and node['name'].endswith('\n.')
                and node['name'].split('\n')[0] in known]
        assert len(rows) == len(set(rows)) and rows.count(name) == 1, rows
        # Files uses sorted paths. AT-SPI child enumeration can retain insertion
        # order after a rename, so enumerate the current set and apply that
        # fixture ordering. The dialog must prove the exact source before Apply.
        rows.sort()
        native.perform({'kind': 'click', 'scale': 1, 'point': [275, 151 + 56 * rows.index(name)], 'viewport': [1280, 720]})
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Move file…') and contains(nodes, 'Delete file…'), 'File action menu did not open for the captured upload')
        keys(native, ['Home'] + (['Down'] if delete else []) + ['Return'])
        print('Opened captured file action:', name, 'delete' if delete else 'move', flush=True)

    def protect(name):
        file_menu(name, delete=True)
        nodes = wait_tree(native, process.pid,
            lambda nodes: contains(nodes, 'Review file deletion') and contains(nodes, 'A saved contract case uploads this file.'),
            'Saved upload deletion did not identify its source-located consumer')
        assert contains(nodes, name + '#'), 'Deletion review selected another file'
        apply = [node for node in nodes if node['name'] == 'Apply']
        assert len(apply) == 1 and not apply[0]['enabled'], apply
        assert any(node['name'] == 'Cancel' and node['enabled'] for node in nodes)
        activate_control(native, process.pid, 'Cancel')
        wait_tree(native, process.pid, lambda nodes: not contains(nodes, 'Review file deletion'), 'Cancelled upload deletion left a review open')
        assert all(Path(path).read_bytes() == value for path, value in baseline.items())
        print('Protected saved upload deletion:', name, flush=True)

    sidebar(True)
    protect(source.name)
    for accept in [False, True]:
        file_menu(source.name)
        wait_tree(native, process.pid, lambda nodes: field_matches(nodes, 'Destination path', value=source.name, editable=True), 'Native file destination did not open')
        focus_control(native, process.pid, 'Destination path')
        keys(native, ['Control_L+a'] + text_keys(destination.name))
        activate_control(native, process.pid, 'Apply')
        wait_tree(native, process.pid, lambda nodes: contains(nodes, 'Review file move'), 'Upload movement bypassed reviewed changes')
        assert all(Path(path).read_bytes() == value for path, value in baseline.items())
        assert source.read_bytes() == fixture.payloads[0] and not destination.exists()
        activate_control(native, process.pid, 'Apply' if accept else 'Cancel')
        wait_tree(native, process.pid, lambda nodes: not contains(nodes, 'Review file move'), 'Native upload move review did not finish')
    wait_tree(native, process.pid, lambda nodes: contains(nodes, destination.name), 'Reviewed file move did not update Files')
    focus_control(native, process.pid, destination.name)
    keys(native, ['Return'])
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['text'] == '[0]' for node in nodes), 'Moved opaque upload bytes did not remain available in Source')
    native.perform({'kind': 'click', 'scale': 1, 'point': [650, 110], 'viewport': [1280, 720]})
    wait_tree(native, process.pid, lambda nodes: any(node['editable'] and node['focused'] for node in nodes), 'Source did not acquire file history input')
    keys(native, ['Control_L+z'])
    wait_tree(native, process.pid, lambda nodes: contains(nodes, source.name) and not contains(nodes, destination.name), 'One Undo did not restore the upload filename')
    keys(native, ['Control_L+Shift_L+z'])
    wait_tree(native, process.pid, lambda nodes: contains(nodes, destination.name), 'One Redo did not restore the reviewed upload move')
    assert manifest.read_bytes() == original and source.read_bytes() == fixture.payloads[0]
    keys(native, ['Control_L+s'])
    deadline = time.monotonic() + 30
    while source.exists() or not destination.exists() or manifest.read_bytes() != expected:
        native.ready()
        if time.monotonic() > deadline:
            raise RuntimeError('Saving the move did not publish the upload and exact configuration repairs together')
        time.sleep(0.1)
    assert destination.read_bytes() == fixture.payloads[0]
    fixture.uploads[0] = destination
    baseline[str(manifest)] = expected
    protect(destination.name)
    sidebar(False)
    native.perform({'kind': 'click', 'scale': 1, 'point': [110, 215], 'viewport': [1280, 720]})
    mode(native, process.pid, 'design')
    wait_tree(native, process.pid,
        lambda nodes: design_values(nodes, 'edited ' + fixture.version, 'api-version2') and complete_problems(nodes),
        'File maintenance changed the API root or its source ownership')
    return {'complete': True, 'reviewCancelled': True, 'reviewApplied': True,
            'oneOperationUndoRedo': True, 'deletionBlockedBeforeAndAfter': True,
            'configurationExact': True, 'payloadSha256': hashlib.sha256(fixture.payloads[0]).hexdigest()}
