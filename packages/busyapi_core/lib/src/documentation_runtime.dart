import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'engine_process.dart';
import 'model.dart';

const _redocAdapter = {
  'producer': 'busyapi-redoc-read-only',
  'version': '7',
  'package': 'redoc',
  'packageVersion': '3.0.1',
};
const _swaggerAdapter = {
  'producer': 'busyapi-swagger-read-only',
  'version': '6',
  'package': 'swagger-ui',
  'packageVersion': '5.33.2',
  'clientPackage': 'swagger-client',
  'clientPackageVersion': '3.38.2',
};
const _redocFiles = [
  'THIRD_PARTY_NOTICES.txt',
  'bootstrap.js',
  'redoc.js',
  'third-party.json',
];
const _swaggerFiles = [
  'THIRD_PARTY_NOTICES.txt',
  'bootstrap.js',
  'swagger-ui-es-bundle-core.js.LICENSE.txt',
  'swagger.css',
  'swagger.js',
  'third-party.json',
];
const _runtimeFiles = {
  'redoc': ['redoc.js', 'bootstrap.js'],
  'swagger': ['swagger.js', 'swagger.css', 'bootstrap.js'],
};

// Headless English output defaults. Native presentation supplies generated ARB
// translations; a parity test keeps these equal to the English ARB labels.
const defaultDocumentationLabels = <String, String>{
  'title': 'Reference',
  'loading': 'Loading the captured API reference…',
  'failure': 'The documentation window did not complete (renderer-failed). Your source workspace is unchanged.',
  'source': 'Reveal in Source',
  'sourceOwner': 'View original owner',
  'schemas': 'Schemas',
  'previousPage': 'Previous',
  'nextPage': 'Next',
  'page': 'Page {page} of {pages}',
  'definition': 'Read definition',
  'dynamicReference': 'Possible dynamic targets',
  'inherited': 'Inherited',
  'webhooks': 'Webhooks',
};

class DocumentationAssetsFailure extends CoreFailure {
  DocumentationAssetsFailure(this.component, {this.preset = 'redoc'})
    : super(
        'documentation.assets',
        'The local documentation component "$preset/$component" is missing or '
            'mismatched. Prepare the locked documentation assets and rebuild the '
            'complete Linux bundle. Source files have not been changed.',
      );
  final String component;
  final String preset;
}

Future<Map<String, Object>> _loadDocumentationRuntime(
  String directory,
  String preset,
) async {
  final adapter = preset == 'redoc' ? _redocAdapter : _swaggerAdapter;
  final assetFiles = preset == 'redoc' ? _redocFiles : _swaggerFiles;
  final notices = [
    'THIRD_PARTY_NOTICES.txt',
    'third-party.json',
    if (preset == 'swagger') 'swagger-ui-es-bundle-core.js.LICENSE.txt',
  ];
  var component = 'assets.json';
  Never invalid() =>
      throw DocumentationAssetsFailure(component, preset: preset);
  Future<Uint8List> read(String name, int limit) async {
    component = name;
    final file = File(p.join(directory, name));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > limit) {
      invalid();
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > limit) invalid();
    return bytes;
  }

  try {
    if (await FileSystemEntity.type(directory, followLinks: false) !=
        FileSystemEntityType.directory) {
      invalid();
    }
    final manifest = jsonDecode(utf8.decode(await read('assets.json', 65536)));
    if (manifest is! Map ||
        manifest['version'] != 1 ||
        manifest['producer'] != 'busyapi-documentation-assets' ||
        manifest['producerVersion'] != '1' ||
        manifest['preset'] != preset ||
        jsonEncode(manifest['adapter']) != jsonEncode(adapter) ||
        manifest['files'] is! Map ||
        jsonEncode((manifest['files'] as Map).keys.toList()) !=
            jsonEncode(assetFiles) ||
        jsonEncode(manifest['runtimeResources']) !=
            jsonEncode(_runtimeFiles[preset]) ||
        jsonEncode(manifest['notices']) != jsonEncode(notices) ||
        manifest['identity'] !=
            textIdentity(
              jsonEncode({
                'adapter': manifest['adapter'],
                'files': manifest['files'],
              }),
            )) {
      invalid();
    }
    final files = <String, Uint8List>{};
    for (final name in assetFiles) {
      final bytes = await read(name, 16 * 1024 * 1024);
      if (contentIdentity(bytes) != manifest['files'][name]) invalid();
      files[name] = bytes;
    }
    final inventory = jsonDecode(utf8.decode(files['third-party.json']!));
    if (inventory is! Map ||
        inventory['version'] != 1 ||
        inventory['producer'] != 'busyapi-documentation-notices' ||
        inventory['preset'] != preset ||
        inventory['packages'] is! List ||
        (inventory['packages'] as List).length !=
            (preset == 'redoc' ? 52 : 118) ||
        !(inventory['packages'] as List).any(
          (record) =>
              record is Map &&
              record['name'] ==
                  (preset == 'redoc'
                      ? '@redocly/redoc-opentelemetry'
                      : 'swagger-ui') &&
              record['version'] == (preset == 'redoc' ? '0.5.1' : '5.33.2') &&
              record['license'] == (preset == 'redoc' ? 'MIT' : 'Apache-2.0'),
        )) {
      invalid();
    }
    return {'identity': manifest['identity'] as String, 'files': files};
  } on CoreFailure {
    rethrow;
  } on Object {
    invalid();
  }
}

/// Immutable installed presentation assets. This is not a project resource
/// resolver, parser or package manager; missing assets never trigger downloads.
class DocumentationRuntime {
  DocumentationRuntime._(
    this.identity,
    this.preset,
    Map<String, Uint8List> files,
  ) : files = Map.unmodifiable({
        for (final entry in files.entries)
          entry.key: entry.value.asUnmodifiableView(),
      });

  static Future<DocumentationRuntime> forEngine(
    EngineProcess engine, {
    String preset = 'redoc',
  }) => loadInstalled(
    p.join(
      p.dirname(p.dirname(p.dirname(engine.helper))),
      'share',
      'busyapi',
      'documentation',
      preset,
    ),
    preset: preset,
  );

  /// Explicit installation root also supports deterministic packaging tests.
  /// This path is selected by the application owner, never contract content.
  static Future<DocumentationRuntime> loadInstalled(
    String directory, {
    String preset = 'redoc',
  }) async {
    if (!['redoc', 'swagger'].contains(preset))
      throw CoreFailure(
        'documentation.preset',
        'The requested documentation preset is not installed',
      );
    final data = await Isolate.run(
      () => _loadDocumentationRuntime(directory, preset),
    );
    return DocumentationRuntime._(
      data['identity'] as String,
      preset,
      (data['files'] as Map).cast<String, Uint8List>(),
    );
  }

  final String identity;
  final String preset;
  final Map<String, Uint8List> files;
  Map<String, String> get adapter =>
      Map.unmodifiable(preset == 'redoc' ? _redocAdapter : _swaggerAdapter);

  /// Classic local scripts and an inert escaped JSON block allow direct
  /// file:// opening. No server, fetch, browser module loader or Node is used.
  Future<Map<String, Uint8List>> page(
    Map<String, Object?> presentation, {
    required Map<String, String> labels,
    bool native = false,
  }) async {
    final captured = Map<String, Object?>.of(presentation),
        translated = Map<String, String>.of(labels);
    final selectedPreset = preset;
    final html = await Isolate.run(() {
      const escape = HtmlEscape();
      if (captured['version'] != 1 ||
          captured['text'] is! String ||
          captured['projection'] is! Map ||
          captured['snapshot'] is! String ||
          native && captured['contextSnapshot'] is! String ||
          captured['sourceActions'] is! List ||
          translated.values.any((value) => value.length > 4096) ||
          ![
            'title',
            'loading',
            'failure',
            'schemas',
            'source',
            'sourceOwner',
            'previousPage',
            'nextPage',
            'page',
            'definition',
            'dynamicReference',
            'inherited',
            'webhooks',
          ].every((key) => translated[key]?.isNotEmpty == true)) {
        throw CoreFailure(
          'documentation.presentation',
          'The captured documentation page is malformed',
        );
      }
      // Redoc CE 3.0.1's Q9/T9 preparation path always converts Swagger to
      // 3.x, including with skipBundle. Native support must preserve 2.0;
      // reject this external renderer before it can change display semantics.
      if (selectedPreset == 'redoc' &&
          (captured['projection'] as Map)['family'] == '2.0') {
        throw CoreFailure(
          'documentation.renderer.version',
          'Redoc CE 3.0.1 converts Swagger 2.0 internally. Choose native Reference '
              'or Swagger UI to preserve this specification.',
        );
      }
      final payload = jsonEncode({
        'version': 1,
        'preset': selectedPreset,
        'snapshot': native ? captured['contextSnapshot'] : captured['snapshot'],
        'text': captured['text'],
        'projection': captured['projection'],
        'sourceActions': native ? captured['sourceActions'] : <Object>[],
        'labels': translated,
      }).replaceAll('<', r'\u003c');
      final markup =
          '<!doctype html><html><head><meta charset="utf-8">'
          '<meta name="referrer" content="no-referrer">'
          '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'self\'; style-src \'self\' \'unsafe-inline\'; img-src data:; font-src data:; connect-src \'none\'; base-uri \'none\'; form-action \'none\'; object-src \'none\'; frame-src \'none\'; worker-src \'none\'">'
          '<title>${escape.convert(translated['title']!)}</title>'
          '${selectedPreset == 'swagger' ? '<link rel="stylesheet" href="swagger.css">' : ''}'
          '<script defer src="$selectedPreset.js"></script><script defer src="bootstrap.js"></script>'
          '<script id="busyapi-snapshot" type="application/json">$payload</script>'
          '</head><body><p id="busyapi-status" role="status" data-failure="${escape.convert(translated['failure']!)}">${escape.convert(translated['loading']!)}</p>'
          '<div id="reference"></div></body></html>';
      final bytes = utf8.encode(markup);
      // A 1-MiB contract's located graph/source table can exceed 16 MiB.
      // Only this inert generated entry gets the larger budget; installed
      // assets retain their independent 16-MiB checks at every host boundary.
      if (bytes.length > 32 * 1024 * 1024) {
        throw CoreFailure(
          'limit.documentation.output',
          'The captured documentation page exceeds its bounded resource limit',
        );
      }
      return bytes;
    });
    return Map.unmodifiable({
      'index.html': html.asUnmodifiableView(),
      for (final name in native ? _runtimeFiles[preset]! : files.keys)
        name: files[name]!,
    });
  }
}
