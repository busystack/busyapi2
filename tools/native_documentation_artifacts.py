"""Inspect synthetic native documentation exports independently of the renderer."""
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
from urllib.parse import unquote


class Document(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.references = []
        self.text = []
        self.scripts = 0
        self.loads = []
        self.skip = 0
        self.definition = None
        self.definition_text = []
        self.term = None
        self.pairs = []

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if 'id' in attributes:
            assert attributes['id'] not in self.ids, 'Duplicate output anchor'
            self.ids.add(attributes['id'])
        if tag == 'a' and attributes.get('href', '').startswith('#'):
            self.references.append(unquote(attributes['href'][1:]))
        if tag == 'script':
            self.scripts += 1
        if 'src' in attributes or tag == 'link':
            self.loads.append(attributes)
        if tag in ['style', 'script']:
            self.skip += 1
        if tag in ['dt', 'dd']:
            self.definition = tag
            self.definition_text = []

    def handle_endtag(self, tag):
        if tag in ['style', 'script']:
            self.skip -= 1
        if tag == self.definition:
            value = ''.join(self.definition_text)
            if tag == 'dt':
                self.term = value
            else:
                self.pairs.append((self.term, value))
            self.definition = None

    def handle_data(self, value):
        if not self.skip:
            self.text.append(value)
        if self.definition:
            self.definition_text.append(value)


def verify_documentation(directory, sources, version, title):
    metadata = json.loads((directory / 'provenance.json').read_text())
    receipt = json.loads((directory / 'busyapi-output.json').read_text())
    assert receipt['owner'] == 'io.busystack.busyapi'
    assert metadata == receipt['metadata']
    assert metadata['operation'] == 'build-docs'
    assert metadata['producer'] == 'busyapi-native-reference'
    assert metadata['preset'] == 'native-reference'
    assert metadata['unsaved'] is True and metadata['input'] == 'working-copy'
    assert metadata['rangeEncoding'] == 'utf16-half-open-without-bom'
    assert {source['resource'] for source in metadata['sources']} == set(sources)
    for source in metadata['sources']:
        raw = sources[source['resource']]
        assert hashlib.sha256(raw).hexdigest() == source['identity']
        assert source['hasBom'] == raw.startswith(b'\xef\xbb\xbf')
    document = Document()
    document.feed((directory / 'index.html').read_text())
    document.close()
    assert document.scripts == 0 and not document.loads, 'Native HTML loads external code/assets'
    assert all(anchor in document.ids for anchor in document.references)
    text = ''.join(document.text)
    family = '2.0' if version == '2.0' else '.'.join(version.split('.')[:2])
    assert 'OpenAPI ' + family in text and 'GET /items' in text
    assert title in text and 'api-version2' in text
    assert '9007199254740993.00' in text
    assert 'Production ' + version not in text
    declaration = 'swagger' if version == '2.0' else 'openapi'
    assert (declaration, version) in document.pairs

    def source_text(source):
        encoded = sources[source['resource']].decode('utf-8-sig').encode('utf-16-le')
        start, end = source['range']
        assert type(start) is int and type(end) is int
        assert 0 <= start <= end <= len(encoded) // 2
        return encoded[start * 2:end * 2].decode('utf-16-le')

    located = 0
    for entry in metadata['provenance']:
        assert entry['derived']['resource'] == 'index.html'
        assert entry['derived']['anchor'] in document.ids
        for source in [entry['source'], *[field['source'] for field in entry.get('fields', [])]]:
            source_text(source)
            located += 1
        if entry['kind'] == 'info':
            field = next(field['source'] for field in entry['fields'] if field['name'] == 'title')
            assert title in source_text(field)
        if entry['kind'] == 'root' and entry['source']['resource'] == metadata['root']:
            field = next(field['source'] for field in entry['fields'] if field['name'] == declaration)
            assert version in source_text(field)
    for name, expected in receipt['files'].items():
        relative = Path(name)
        assert not relative.is_absolute() and '..' not in relative.parts
        file = directory / relative
        assert file.is_file() and not file.is_symlink()
        assert all(not parent.is_symlink() for parent in file.parents if parent != directory.parent)
        assert hashlib.sha256(file.read_bytes()).hexdigest() == expected
    return {'sourceIdentities': True, 'locatedRanges': located,
            'localAnchors': len(document.references), 'offlineHtml': True}
