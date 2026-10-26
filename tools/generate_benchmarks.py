"""Construct trusted representative projects in a temporary output directory."""
import argparse
import json
from pathlib import Path


def document(specification, title, paths):
    declaration = {'swagger': '2.0'} if specification == '2.0' else {'openapi': specification}
    return {**declaration, 'info': {'title': title, 'version': '1'},
            **({'produces': ['application/json']} if specification == '2.0' else {}),
            'paths': paths}


def operation(index, swagger):
    schema = {'type': 'object', 'properties': {'name': {'type': 'string'}}}
    example = {'name': 'fixture'}
    response = ({'description': 'OK', 'schema': schema,
                 'examples': {'application/json': example}} if swagger else
                {'description': 'OK', 'content': {'application/json': {
                    'schema': schema, 'example': example}}})
    return {'get': {'summary': f'Get representative item {index}',
                    'description': 'Representative text ' * 10,
                    'responses': {'200': response}}}


def authored_yaml(specification, mib, operations):
    swagger = specification == '2.0'
    declaration = 'swagger: "2.0"' if swagger else f'openapi: "{specification}"'
    lines = ['# Representative authored YAML', declaration,
             f'info: {{title: "{mib} MiB YAML", version: "1"}}']
    if swagger:
        lines.append('produces: [application/json]')
    lines.append('paths:')
    for path, item in operations.items():
        lines += [f'  {json.dumps(path)}:', '    get:',
                  '      summary: ' + json.dumps(item['get']['summary']),
                  '      description: ' + json.dumps(item['get']['description']),
                  '      responses:', '        "200":', '          description: "OK"']
        if swagger:
            lines += ['          schema: {type: object, properties: {name: {type: string}}}',
                      '          examples:', '            application/json: {name: "fixture"}']
        else:
            lines += ['          content:', '            application/json:',
                      '              schema: {type: object, properties: {name: {type: string}}}',
                      '              example: {name: "fixture"}']
    text = '\n'.join(lines) + '\n'
    if len(text.encode()) < mib * 1024 * 1024:
        text += '# ' + ('x' * (mib * 1024 * 1024 - len(text.encode()))) + '\n'
    return text


def generate(out, specification, recursive=False):
    out.mkdir(parents=True, exist_ok=True)
    swagger = specification == '2.0'
    for mib in (1, 5):
        operations = {}
        value = document(specification, f'{mib} MiB typing fixture', operations)
        index = 0
        while True:
            for _ in range(100):
                operations[f'/items/{index}'] = operation(index, swagger)
                index += 1
            text = json.dumps(value, indent=2) + '\n'
            if len(text.encode()) >= mib * 1024 * 1024:
                break
        (out / f'{mib}mb.json').write_text(text)
        (out / f'{mib}mb.yaml').write_text(authored_yaml(specification, mib, operations))
        longline = document(specification, 'Minified fixture', {})
        longline['info']['description'] = 'x' * (mib * 1024 * 1024)
        (out / f'{mib}mb-minified.json').write_text(
            json.dumps(longline, separators=(',', ':')) + '\n')
    project = out / 'graph'
    project.mkdir(exist_ok=True)
    schemas = {}
    for index in range(500):
        name = f'Schema{index}'
        schemas[name] = {'$ref': f'{name}.json'}
        properties = {'name': {'type': 'string'}}
        if recursive:
            following = index // 10 * 10 + (index + 1) % 10
            properties['next'] = {'$ref': f'Schema{following}.json'}
        (project / f'{name}.json').write_text(json.dumps({
            'type': 'object', 'properties': properties}) + '\n')
    paths = {}
    if recursive:
        sample = operation(0, swagger)
        response = sample['get']['responses']['200']
        if swagger:
            response['schema'] = {'$ref': 'Schema0.json'}
        else:
            response['content']['application/json']['schema'] = {'$ref': 'Schema0.json'}
        paths['/items'] = sample
    graph = document(specification, 'Recursive fixture' if recursive else '500 local files', paths)
    if swagger:
        graph['definitions'] = schemas
    else:
        graph['components'] = {'schemas': schemas}
    (project / 'openapi.json').write_text(json.dumps(graph, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--specification', choices=['2.0', '3.0.4', '3.1.2', '3.2.1'],
                        default='3.2.1', help='Representative native specification for every fixture')
    parser.add_argument('--recursive', action='store_true',
                        help='Make the 500-file graph contain 50 ten-resource cycles')
    args = parser.parse_args()
    generate(args.output, args.specification, args.recursive)
    print(args.output)
