import { createServer, IncomingMessage, ServerResponse } from 'node:http';
import { isDeepStrictEqual } from 'node:util';
// The pinned component exports a CommonJS default; use that exact public component.
const { default: mock, createInvalidInputResponse }:typeof import('@stoplight/prism-http/dist/mocker') = require('@stoplight/prism-http/dist/mocker');
import {transformOas2Operations} from '@stoplight/http-spec/oas2/operation';
import { transformOas3Operations } from '@stoplight/http-spec/oas3/operation';
import { createLogger } from '@stoplight/prism-core';
import { ContentExample, createInstance, ProblemJsonError } from '@stoplight/prism-http';
import { DiagnosticSeverity, IMediaTypeContent } from '@stoplight/types';
import { findNodeAtLocation, Node, parseTree } from 'jsonc-parser';
import pino from 'pino';
import {specificationDeclaration} from './specification';
import {ignoresRequestBody} from './operation_semantics';

const maximumInput = 64 * 1024 * 1024;
const maximumRequestBody = 10 * 1024 * 1024;
const maximumUpstreamBody = 64 * 1024 * 1024;

interface StartInput {
  version: 1;
  snapshot: string;
  document: string;
  port?: number;
  errors?: boolean;
  upstream?: string;
}

interface ExactExample {
  path: string;
  method: string;
  status: string;
  mediaType: string;
  name?: string;
  raw: string;
  serialized: boolean;
}

function write(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

async function readInput(): Promise<StartInput> {
  const chunks: Buffer[] = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += value.length;
    if (bytes > maximumInput) throw new Error('mock input exceeds 64 MiB');
    chunks.push(value);
  }
  const input = JSON.parse(Buffer.concat(chunks).toString('utf8')) as StartInput;
  if (
    input.version !== 1 ||
    typeof input.snapshot !== 'string' ||
    !/^[0-9a-f]{64}$/.test(input.snapshot) ||
    typeof input.document !== 'string' ||
    (input.port !== undefined &&
      (!Number.isInteger(input.port) || input.port < 0 || input.port > 65535))
  ) {
    throw new Error('invalid immutable mock start input');
  }
  if (input.upstream !== undefined) {
    let upstream: URL;
    try { upstream = new URL(input.upstream); }
    catch { throw new Error('invalid validation proxy target'); }
    if (!['http:', 'https:'].includes(upstream.protocol) || !upstream.hostname ||
      upstream.username || upstream.password || upstream.search || upstream.hash)
      throw new Error('validation proxy target must be an HTTP(S) base URL without credentials, query or fragment');
  }
  return input;
}

function children(node: Node | undefined): Node[] {
  return node?.children ?? [];
}

function propertyName(node: Node): string | undefined {
  return node.type === 'property' && node.children?.[0]?.value !== undefined
    ? String(node.children[0].value)
    : undefined;
}

function exactExamples(text: string, tree: Node): ExactExample[] {
  const output: ExactExample[] = [];
  const paths = findNodeAtLocation(tree, ['paths']);
  for (const pathProperty of children(paths)) {
    const path = propertyName(pathProperty), pathItem = pathProperty.children?.[1];
    if (!path || !pathItem) continue;
    for (const operationProperty of children(pathItem)) {
      const method = propertyName(operationProperty)?.toLowerCase();
      if (!method || !['get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace', 'query'].includes(method)) continue;
      const responses = findNodeAtLocation(operationProperty.children?.[1], ['responses']);
      for (const responseProperty of children(responses)) {
        const status = propertyName(responseProperty), response = responseProperty.children?.[1];
        if (!status || !response) continue;
        if(findNodeAtLocation(tree,['swagger'])?.value==='2.0')for(const property of children(findNodeAtLocation(response,['examples']))) {
          const mediaType=propertyName(property),value=property.children?.[1];
          if(mediaType&&value)output.push({path,method,status,mediaType,raw:text.slice(value.offset,value.offset+value.length),serialized:false});
        }
        const content = findNodeAtLocation(response, ['content']);
        for (const mediaProperty of children(content)) {
          const mediaType = propertyName(mediaProperty), media = mediaProperty.children?.[1];
          if (!mediaType || !media) continue;
          const direct = findNodeAtLocation(media, ['example']);
          if (direct) output.push({ path, method, status, mediaType, raw: text.slice(direct.offset, direct.offset + direct.length), serialized: false });
          const examples = findNodeAtLocation(media, ['examples']);
          for (const exampleProperty of children(examples)) {
            const name = propertyName(exampleProperty), example = exampleProperty.children?.[1];
            if (!name || !example) continue;
            for (const field of ['value', 'dataValue', 'serializedValue']) {
              const value = findNodeAtLocation(example, [field]);
              if (!value) continue;
              output.push({ path, method, status, mediaType, name,
                raw: text.slice(value.offset, value.offset + value.length),
                serialized: field === 'serializedValue' });
              break;
            }
          }
        }
      }
    }
  }
  return output;
}

interface CapturedBody { value: unknown; raw?: Buffer }

async function body(request: IncomingMessage): Promise<CapturedBody> {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += bytes.length;
    if (length > maximumRequestBody) throw Object.assign(new Error('request body exceeds 10 MiB'), { status: 413 });
    chunks.push(bytes);
  }
  if (length === 0) return { value: null };
  const bytes = Buffer.concat(chunks), raw = bytes.toString('utf8');
  const media = String(request.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
  return { value: media === 'application/json' || media.endsWith('+json') ? JSON.parse(raw) : raw, raw: bytes };
}

function forwardPreservingBytes(rawRequests: WeakMap<object, Buffer | undefined>,
  rawResponses: WeakMap<object, Buffer>) {
  return ({ data: request, validations }: any, baseUrl: string) => (logger: any) => async () => {
    try {
      if (validations.length) {
        const error = new Error('Request did not conform to the captured contract');
        Object.assign(error, { status: 422 });
        return { _tag: 'Left', left: error };
      }
      const target = new URL(baseUrl), basePath = target.pathname.replace(/\/$/u, '');
      target.pathname = `${basePath}${request.url.path.startsWith('/') ? '' : '/'}${request.url.path}`;
      target.search = '';
      for (const [name, value] of Object.entries(request.url.query ?? {}))
        for (const item of Array.isArray(value) ? value : [value]) target.searchParams.append(name, String(item));
      const method = String(request.method).toUpperCase(), raw = rawRequests.get(request);
      if ((method === 'GET' || method === 'HEAD') && raw?.length) {
        const error = new Error('Validation proxy does not replay a GET/HEAD request body');
        Object.assign(error, { status: 422 });
        return { _tag: 'Left', left: error };
      }
      const headers = new Headers();
      const hop = new Set(['host', 'content-length', 'connection', 'proxy-connection',
        'keep-alive', 'transfer-encoding', 'upgrade', 'te', 'trailer']);
      for (const [name, value] of Object.entries(request.headers ?? {}))
        if (!hop.has(name.toLowerCase()) && name.toLowerCase() !== 'accept-encoding') headers.append(name, String(value));
      headers.set('accept-encoding', 'identity');
      const response = await fetch(target, {
        method,
        headers,
        body: raw?.length ? raw : undefined,
        redirect: 'manual',
      });
      const chunks: Buffer[] = []; let length = 0;
      if (response.body) {
        const reader = response.body.getReader();
        while (true) {
          const next = await reader.read();
          if (next.done) break;
          length += next.value.length;
          if (length > maximumUpstreamBody) {
            await reader.cancel();
            throw new Error('validation proxy upstream body exceeds 64 MiB');
          }
          chunks.push(Buffer.from(next.value));
        }
      }
      const bytes = Buffer.concat(chunks), responseHeaders: Record<string, string | string[]> = {};
      for (const [name, value] of response.headers.entries())
        if (!hop.has(name.toLowerCase()) && !['content-encoding','set-cookie'].includes(name.toLowerCase())) responseHeaders[name] = value;
      const cookies=response.headers.getSetCookie();
      if(cookies.length)responseHeaders['set-cookie']=cookies;
      const media = String(response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
      const applicable=method!=='HEAD'&&response.status>=200&&![204,205,304].includes(response.status);
      let value: unknown = applicable?bytes:undefined;
      if (applicable&&(media === 'application/json' || media.endsWith('+json'))) value = JSON.parse(bytes.toString('utf8'));
      else if (applicable&&media.startsWith('text/')) value = bytes.toString('utf8');
      const output = { statusCode: response.status, headers: responseHeaders, body: value };
      rawResponses.set(output, bytes);
      logger.info(`Validated one explicit upstream response with ${bytes.length} retained bytes`);
      return { _tag: 'Right', right: output };
    } catch (error) {
      return { _tag: 'Left', left: error instanceof Error ? error : new Error(String(error)) };
    }
  };
}

function preference(request: IncomingMessage, url: URL) {
  const prefer = String(request.headers.prefer ?? '');
  const named = (name: string): string | undefined => {
    const match = new RegExp(`(?:^|[,;]\\s*)${name}=([^,;]+)`, 'i').exec(prefer);
    return match?.[1]?.trim().replace(/^"|"$/g, '');
  };
  const codeText = named('code') ?? url.searchParams.get('__code') ?? undefined;
  const dynamicText = named('dynamic') ?? url.searchParams.get('__dynamic') ?? undefined;
  return {
    code: codeText && /^\d{3}$/.test(codeText) ? Number(codeText) : undefined,
    exampleKey: named('example') ?? url.searchParams.get('__example') ?? undefined,
    dynamic: dynamicText === 'true',
  };
}

function exactBody(examples: ExactExample[], method: string, path: string, status: string,
  content: IMediaTypeContent | undefined, projected: ContentExample | undefined): string | undefined {
  if (!content) return undefined;
  const essence = content.mediaType.split(';')[0].trim().toLowerCase();
  if (!(essence === 'application/json' || essence.endsWith('+json'))) return undefined;
  // path is Prism's selected operation template, never the incoming URL.
  // Keep the full selected declaration, including case-sensitive parameters.
  const candidates = examples.filter(example => example.method === method && example.path === path &&
    example.mediaType === content.mediaType && example.status === status);
  if (!projected || !('value' in projected) || projected.value === undefined) return undefined;
  if (!content.examples?.includes(projected)) throw new Error('Selected mock example does not belong to its media declaration');
  const direct = candidates.find(example => example.name === undefined);
  // http-spec prepends a direct or schema default before named examples. A
  // schema default has no captured Media Type example bytes; do not confuse it
  // with a named example that happens to be called "default".
  const isDefault = projected === content.examples?.[0] &&
    (direct !== undefined || content.schema?.examples?.[0] !== undefined);
  const selected = isDefault ? direct : candidates.find(example => example.name === projected.key);
  if (!selected) return undefined;
  return selected.serialized ? JSON.parse(selected.raw) as string : selected.raw;
}

function violation(value: { path?: string[]; severity: number; code?: string | number; message: string }, prefix: string) {
  return { location: [prefix, ...(value.path ?? [])], severity: DiagnosticSeverity[value.severity],
    code: value.code === undefined ? undefined : String(value.code), message: value.message };
}

function send(reply: ServerResponse, status: number, payload: string | Buffer | undefined): void {
  reply.statusCode = status;
  reply.end(payload);
}

async function main(): Promise<void> {
  const input = await readInput();
  const tree = parseTree(input.document);
  if (!tree) throw new Error('mock input is not strict derived JSON');
  const examples = exactExamples(input.document, tree);
  const document = JSON.parse(input.document) as Record<string, unknown>;
  const declaration=specificationDeclaration(document);
  if(declaration.status!=='supported')
    throw new Error('mock input must be a supported OpenAPI document');
  // This qualified in-memory path never asks Prism's path loader to reinterpret
  // a literal Example Object `$ref` property as a filesystem dependency.
  const operations = declaration.specification.family==='2.0'?transformOas2Operations(document):transformOas3Operations(document);
  // http-spec 7.1.0 translates every requestBody, including declarations that
  // OAS 3.0 §4.7.10.1 tells consumers to ignore. Adapt its transport projection
  // through the shared rule; the captured document and examples stay intact.
  // Prism treats a missing body projection as rejecting nonempty input; an
  // optional wildcard without a schema preserves the ignored constraints.
  for(const operation of operations)if(operation.request?.body&&ignoresRequestBody(declaration.specification.family,operation.method.toUpperCase()))
    operation.request.body={...operation.request.body,required:false,contents:[{id:operation.request.body.id+'-ignored-content',mediaType:'*/*'}]};
  if (operations.length === 0) throw new Error('mock input has no operations');
  const logger = createLogger('BusyAPIMock', { level: 'warn', base: undefined },
    pino.destination({ dest: 2, sync: false }));
  const rawRequests = new WeakMap<object, Buffer | undefined>();
  const rawResponses = new WeakMap<object, Buffer>();
  const commonConfig = { checkSecurity: true, validateRequest: true, validateResponse: true,
    mock: { dynamic: false }, upstreamProxy: undefined, errors: input.errors !== false };
  const baseConfig = input.upstream
    ? { ...commonConfig, isProxy: true as const, upstream: new URL(input.upstream) }
    : { ...commonConfig, isProxy: false as const };
  const prism = createInstance(baseConfig, { logger,
    mock: options => logger => {
      const result = mock(options)(logger);
      if(result._tag==='Right' && !options.config.dynamic) {
        const output=result.right, resource=options.resource;
        const responses=resource.responses;
        const declaration=responses.find(response=>response.code===String(output.statusCode))
          ??responses.find(response=>response.code===`${Math.floor(output.statusCode/100)}XX`)
          ??responses.find(response=>response.code==='default');
        const mediaType=Object.entries(output.headers??{}).find(([name])=>name.toLowerCase()==='content-type')?.[1];
        const content=declaration?.contents?.find(content=>content.mediaType===mediaType);
        // Valid requests use the requested key or Prism's transformed-array
        // head, which can differ from CST order for integer example names.
        let projected=options.config.exampleKey
          ?content?.examples?.find(example=>example.key===options.config.exampleKey)
          :content?.examples?.[0];
        if(options.input.validations.some(value=>value.severity===DiagnosticSeverity.Error)) {
          // Invalid requests can suppress the preference. Reuse the pinned
          // negotiator's selected object rather than duplicate its status rules
          // or infer identity from parsed values (which can round identically).
          const [first,...rest]=options.input.validations;
          const selection=createInvalidInputResponse([first,...rest],responses,options.config)(logger.child({}, {level:'silent'}));
          if(selection._tag==='Left')throw new Error('Unable to recover the selected mock error example');
          projected=selection.right.bodyExample;
        }
        const exact=declaration && exactBody(examples,resource.method,resource.path,declaration.code,content,projected);
        if(exact!==undefined) {
          // Preserve lexemes only for the example Prism actually returned.
          // Its validation still sees the same projected value as these bytes.
          if(!isDeepStrictEqual(JSON.parse(exact),output.body))throw new Error('Selected mock example does not match Prism output');
          rawResponses.set(output,Buffer.from(exact,'utf8'));
        }
      }
      return result;
    },
    ...(input.upstream ? { forward: forwardPreservingBytes(rawRequests, rawResponses) as never } : {}) });
  const server = createServer(async (request, reply) => {
    try {
      const url = new URL(request.url ?? '/', 'http://127.0.0.1');
      const preferences = preference(request, url);
      const query: Record<string, string | string[]> = {};
      for (const name of url.searchParams.keys()) {
        const values = url.searchParams.getAll(name);
        query[name] = values.length === 1 ? values[0] : values;
      }
      const headers: Record<string, string> = {};
      for (const [name, value] of Object.entries(request.headers))
        if (value !== undefined) headers[name] = Array.isArray(value) ? value.join(', ') : value;
      const captured = await body(request);
      const prismRequest = { method: (request.method ?? 'GET').toLowerCase() as never,
        url: { path: url.pathname, query }, headers, body: captured.value };
      rawRequests.set(prismRequest, captured.raw);
      const outcome = await prism.request(prismRequest, operations,
      { ...baseConfig, mock: preferences })();
      if (outcome._tag === 'Left') {
        const error = outcome.left as Error & { status?: number; detail?: string;
          additional?: { headers?: Record<string, string> } };
        reply.setHeader('content-type', 'application/problem+json');
        for (const [name, value] of Object.entries(error.additional?.headers ?? {})) reply.setHeader(name, value);
        send(reply, error.status ?? 500, JSON.stringify(ProblemJsonError.toProblemJson(error)));
        return;
      }
      const result = outcome.right;
      const violations = [...result.validations.input.map(value => violation(value, 'request')),
        ...result.validations.output.map(value => violation(value, 'response'))];
      if (violations.length) reply.setHeader('sl-violations', JSON.stringify(violations).slice(0, 8000));
      for (const [name, value] of Object.entries(result.output.headers ?? {})) reply.setHeader(name, value);
      const mediaType = String(reply.getHeader('content-type') ?? '').split(';')[0].trim().toLowerCase() || undefined;
      const payload = rawResponses.get(result.output) ?? (result.output.body === undefined ? undefined :
        mediaType && (mediaType === 'application/json' || mediaType.endsWith('+json'))
          ? JSON.stringify(result.output.body)
          : typeof result.output.body === 'string' ? result.output.body : JSON.stringify(result.output.body));
      process.stderr.write(`${JSON.stringify({ event: 'request', method: request.method,
        path: url.pathname, status: result.output.statusCode, violations: violations.length })}\n`);
      send(reply, result.output.statusCode, payload);
    } catch (error) {
      const status = typeof error === 'object' && error !== null && 'status' in error ? Number(error.status) : 500;
      reply.setHeader('content-type', 'application/problem+json');
      send(reply, status, JSON.stringify({ title: 'Mock request failed', status, detail: String(error) }));
    }
  });
  let closing = false;
  const close = async (signal: string): Promise<void> => {
    if (closing) return;
    closing = true;
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    write({ version: 1, event: 'stopped', signal, snapshot: input.snapshot });
    process.exitCode = 0;
  };
  process.once('SIGINT', () => void close('SIGINT'));
  process.once('SIGTERM', () => void close('SIGTERM'));
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(input.port ?? 0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('mock listener has no TCP address');
  write({ version: 1, event: 'ready', snapshot: input.snapshot, tool: 'Prism',
    toolVersion: '5.15.11', adapter: 'in-memory-http-spec-7.1.0', host: '127.0.0.1',
    port: address.port, operations: operations.length, upstreamForwarding: input.upstream !== undefined });
}

void main().catch(error => {
  const message = String(error);
  write({ version: 1, event: 'failed', error: message });
  process.stderr.write(`BusyAPI mock failed: ${message}\n`);
  process.exitCode = 3;
});
