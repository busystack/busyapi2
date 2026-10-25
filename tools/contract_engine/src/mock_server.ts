import { createServer, IncomingMessage, ServerResponse } from 'node:http';
import { isDeepStrictEqual } from 'node:util';
// The pinned component exports a CommonJS default; use that exact public component.
const { default: mock, createInvalidInputResponse }:typeof import('@stoplight/prism-http/dist/mocker') = require('@stoplight/prism-http/dist/mocker');
import {transformOas2Operations} from '@stoplight/http-spec/oas2/operation';
import { transformOas3Operations } from '@stoplight/http-spec/oas3/operation';
import { createLogger } from '@stoplight/prism-core';
import { ContentExample, createInstance, ProblemJsonError } from '@stoplight/prism-http';
import { DiagnosticSeverity, IMediaTypeContent } from '@stoplight/types';
import {validateInput} from '@stoplight/prism-http/dist/validator';
const {default:route}:typeof import('@stoplight/prism-http/dist/router')=require('@stoplight/prism-http/dist/router');
import { findNodeAtLocation, Node, parseTree } from 'jsonc-parser';
import pino from 'pino';
import {specificationDeclaration} from './specification';
import {mockCapture,MockNativeValidation,type MockCapture,type NativeMockCheck} from './mock_native_validation';
import {record} from './engine_worker_client';
import {segments,SourceError} from './document';

const maximumInput = 64 * 1024 * 1024;
const maximumRequestBody = 10 * 1024 * 1024;
const maximumUpstreamBody = 64 * 1024 * 1024;

interface StartInput {
  version: 1;
  snapshot: string;
  capture: MockCapture;
  derived: {id:string;identity:string};
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
  const input:unknown = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Buffer.concat(chunks)));
  if (
    !record(input) ||
    input.version !== 1 ||
    typeof input.snapshot !== 'string' ||
    !/^[0-9a-f]{64}$/.test(input.snapshot) ||
    !record(input.derived) || typeof input.derived.id!=='string' || typeof input.derived.identity!=='string' || !/^[a-f0-9]{64}$/.test(input.derived.identity) ||
    input.errors!==undefined&&typeof input.errors!=='boolean' ||
    input.upstream!==undefined&&typeof input.upstream!=='string' ||
    (input.port !== undefined &&
      (typeof input.port!=='number'||!Number.isInteger(input.port) || input.port < 0 || input.port > 65535))
  ) {
    throw new Error('invalid immutable mock start input');
  }
  const capture=mockCapture(input.capture);
  if(capture.snapshot!==input.snapshot)throw new Error('mock capture and startup snapshot identities differ');
  if (typeof input.upstream==='string') {
    let upstream: URL;
    try { upstream = new URL(input.upstream); }
    catch { throw new Error('invalid validation proxy target'); }
    if (!['http:', 'https:'].includes(upstream.protocol) || !upstream.hostname ||
      upstream.username || upstream.password || upstream.search || upstream.hash)
      throw new Error('validation proxy target must be an HTTP(S) base URL without credentials, query or fragment');
  }
  return {version:1,snapshot:input.snapshot,capture,derived:{id:input.derived.id,identity:input.derived.identity},
    ...(typeof input.port==='number'?{port:input.port}:{}),...(typeof input.errors==='boolean'?{errors:input.errors}:{}),...(typeof input.upstream==='string'?{upstream:input.upstream}:{})};
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
  if (length === 0) return { value: undefined, raw: Buffer.alloc(0) };
  const bytes = Buffer.concat(chunks), raw = bytes.toString('utf8');
  return { value: raw, raw: bytes };
}

function forwardPreservingBytes(rawRequests: WeakMap<object, Buffer | undefined>,
  rawResponses: WeakMap<object, Buffer>,signals:WeakMap<object,AbortSignal>) {
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
        signal:signals.get(request),
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
      if (applicable&&(media === 'application/json' || media.endsWith('+json'))) {
        try{value=JSON.parse(bytes.toString('utf8'));}
        catch(error){if(!(error instanceof SyntaxError))throw error;}
      }
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

function violation(value: { path?: string[]; severity: number; code?: string | number; message: string; source?:unknown; nativeSource?:unknown }, prefix: string) {
  return { location: [prefix, ...(value.path ?? [])], severity: DiagnosticSeverity[value.severity],
    code: value.code === undefined ? undefined : String(value.code), message: value.message,...(value.nativeSource!==undefined?{source:value.nativeSource}:value.source!==undefined?{source:value.source}:{}) };
}

function nativeDiagnostics(checked:NativeMockCheck,severity:'error'|'warning'='error',response=false) {
  return checked.findings.filter(finding=>finding.severity===severity).map(finding=>({severity:severity==='error'?DiagnosticSeverity.Error:DiagnosticSeverity.Warning,code:severity==='error'&&!response?422:String(finding.code),message:finding.code+': '+finding.message,
    path:[response&&typeof finding.subject==='string'?finding.subject:'body',...(response&&finding.subject==='response-header'&&typeof finding.location==='string'?[finding.location]:[]),...segments(typeof finding.pointer==='string'?finding.pointer:'')],
    ...(record(finding.source)?{nativeSource:finding.source}:record(finding.schema)?{nativeSource:finding.schema}:{})}));
}

function violationHeader(values:ReturnType<typeof violation>[]):string {
  const ascii=(value:unknown)=>JSON.stringify(value).replace(/[\u007f-\uffff]/g,character=>'\\u'+character.charCodeAt(0).toString(16).padStart(4,'0'));
  const entries:string[]=[];let bytes=2;
  for(const value of values){const encoded=ascii(value);if(bytes+encoded.length+1>7500){entries.push(ascii({severity:'Warning',code:'report.header.limit',message:'Additional diagnostic entries were omitted from this bounded header.'}));break;}entries.push(encoded);bytes+=encoded.length+1;}
  return '['+entries.join(',')+']';
}

function send(reply: ServerResponse, status: number, payload: string | Buffer | undefined): void {
  reply.statusCode = status;
  reply.end(payload);
}

async function main(): Promise<void> {
  const input = await readInput();
  const native=new MockNativeValidation(input.capture);
  let listening=false;
  try {
    const documentText=await native.prepare(input.derived);
    const tree = parseTree(documentText);
    if (!tree) throw new Error('mock input is not strict derived JSON');
    const examples = exactExamples(documentText, tree);
    const document:unknown = JSON.parse(documentText);
    if(!record(document))throw new SourceError('mock.capture','The captured root is not an object');
    const declaration=specificationDeclaration(document);
    if(declaration.status!=='supported')
      throw new Error('mock input must be a supported OpenAPI document');
    // This qualified in-memory path never asks Prism's path loader to reinterpret
    // a literal Example Object `$ref` property as a filesystem dependency.
    const operations = declaration.specification.family==='2.0'?transformOas2Operations(document):transformOas3Operations(document);
    native.qualify(operations);
    if (operations.length === 0) throw new Error('mock input has no operations');
    const logger = createLogger('BusyAPIMock', { level: 'warn', base: undefined },
      pino.destination({ dest: 2, sync: false }));
    const rawRequests = new WeakMap<object, Buffer | undefined>();
    const rawResponses = new WeakMap<object, Buffer>();
    const signals=new WeakMap<object,AbortSignal>();
    const nativeChecks=new WeakMap<object,NativeMockCheck>();
    const commonConfig = { checkSecurity: true, validateRequest: true, validateResponse: false,
      mock: { dynamic: false }, upstreamProxy: undefined, errors: input.errors !== false };
    const baseConfig = input.upstream
      ? { ...commonConfig, isProxy: true as const, upstream: new URL(input.upstream) }
      : { ...commonConfig, isProxy: false as const };
    const prism = createInstance(baseConfig, { logger,
      validateInput: options=>{
        const checked=nativeChecks.get(options.element);
        if(!checked||!checked.complete)throw new Error('Native body validation did not complete before Prism input validation');
        const diagnostics=nativeDiagnostics(checked),[first,...rest]=diagnostics;
        if(!checked.valid&&!first)throw new Error('Native body validation omitted its invalid-input findings');
        // A malformed Content-Type must stay a rejected request; passing it to
        // Prism's MIME parser would turn this known violation into a 500.
        if(first&&checked.findings.some(finding=>finding.code==='runtime.request.content-type'))
          return {_tag:'Left',left:[first,...rest]};
        // Delegate body assertions to the canonical engine. Prism 5.15.11's
        // truthy required-body check and JS numeric conversion cannot own them.
        const body={id:options.resource.id+'-native-body',required:false,contents:[{id:options.resource.id+'-native-content',mediaType:'*/*'}]};
        const result=validateInput({resource:{...options.resource,request:{...options.resource.request,body}},element:options.element});
        if(checked.valid)return result;
        return {_tag:'Left',left:[first,...rest,...(result._tag==='Left'?result.left:[])]};
      },
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
      ...(input.upstream ? { forward: forwardPreservingBytes(rawRequests, rawResponses,signals) as never } : {}) });
    const server = createServer(async (request, reply) => {
      const cancellation=new AbortController();
      request.once('aborted',()=>cancellation.abort());
      reply.once('close',()=>{if(!reply.writableEnded)cancellation.abort();});
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
        signals.set(prismRequest,cancellation.signal);
        const selected=route({resources:operations,input:prismRequest});
        if(selected._tag==='Right'){
          const check=await native.body(selected.right.path,selected.right.method,captured.raw??Buffer.alloc(0),headers['content-type'],(captured.raw?.length??0)>0||headers['content-type']!==undefined,cancellation.signal);
          if(!check.complete){
            if(reply.destroyed)return;
            reply.setHeader('content-type','application/problem+json');
            send(reply,501,JSON.stringify({type:'urn:busyapi:native-validation-incomplete',title:'Native request validation did not complete',status:501,complete:false,findings:check.findings}));
            return;
          }
          nativeChecks.set(prismRequest,check);
          // Callback expressions consume Prism's JSON object projection only
          // after native framing/evaluation. These machine numbers never feed
          // the canonical validator or replace the retained request bytes.
          const essence=headers['content-type']?.split(';')[0].trim().toLowerCase();
          if(captured.raw?.length&&(essence==='application/json'||essence?.endsWith('+json'))&&
              !check.findings.some(finding=>['runtime.body.syntax','runtime.request.content-type'].includes(String(finding.code))))
            prismRequest.body=JSON.parse(captured.raw.toString('utf8'));
        }
        const outcome = await prism.request(prismRequest, operations,
        { ...baseConfig, mock: preferences })();
        if(cancellation.signal.aborted||reply.destroyed)return;
        if (outcome._tag === 'Left') {
          const error = outcome.left as Error & { status?: number; detail?: string;
            additional?: { headers?: Record<string, string> } };
          reply.setHeader('content-type', 'application/problem+json');
          const checked=nativeChecks.get(prismRequest);
          if(checked&&(!checked.valid||checked.findings.some(finding=>finding.severity==='warning')))
            reply.setHeader('sl-violations',violationHeader([...nativeDiagnostics(checked),...nativeDiagnostics(checked,'warning')].map(value=>violation(value,'request'))));
          for (const [name, value] of Object.entries(error.additional?.headers ?? {})) reply.setHeader(name, value);
          send(reply, error.status ?? 500, JSON.stringify(ProblemJsonError.toProblemJson(error)));
          return;
        }
        const result = outcome.right;
        const checked=nativeChecks.get(prismRequest),notes=checked?nativeDiagnostics(checked,'warning').map(value=>violation(value,'request')):[];
        for (const [name, value] of Object.entries(result.output.headers ?? {}))
          if(!['sl-violations','busyapi-response-validation-complete'].includes(name.toLowerCase()))reply.setHeader(name, value);
        const mediaType = String(reply.getHeader('content-type') ?? '').split(';')[0].trim().toLowerCase() || undefined;
        const payload = rawResponses.get(result.output) ?? (result.output.body === undefined ? undefined :
          mediaType && (mediaType === 'application/json' || mediaType.endsWith('+json'))
            ? JSON.stringify(result.output.body)
            : typeof result.output.body === 'string' ? result.output.body : JSON.stringify(result.output.body));
        const responseCheck:NativeMockCheck=selected._tag==='Right'
          ?await native.response(selected.right.path,selected.right.method,result.output.statusCode,result.output.headers??{},Buffer.isBuffer(payload)?payload:Buffer.from(payload??'','utf8'),cancellation.signal)
          :{complete:false,valid:false,findings:[{code:'runtime.response.operation.unchecked',message:'The forwarded response has no captured operation owner',severity:'warning',kind:'unsupported',subject:'response-body',pointer:''}]};
        if(cancellation.signal.aborted||reply.destroyed)return;
        const violations = [...result.validations.input.map(value => violation(value, 'request')),...notes,
          ...nativeDiagnostics(responseCheck,'error',true).map(value=>violation(value,'response')),
          ...nativeDiagnostics(responseCheck,'warning',true).map(value=>violation(value,'response'))];
        reply.setHeader('busyapi-response-validation-complete',String(responseCheck.complete));
        if (violations.length) reply.setHeader('sl-violations', violationHeader(violations));
        // Preserve the established proxy error policy for malformed applicable
        // JSON. Native diagnostics still describe the actual upstream content.
        if(input.upstream&&mediaType&&(mediaType==='application/json'||mediaType.endsWith('+json'))&&
            responseCheck.findings.some(finding=>finding.subject==='response-body'&&finding.code==='runtime.body.syntax')){
          reply.removeHeader('content-length');
          reply.setHeader('content-type','application/problem+json');
          send(reply,500,JSON.stringify({title:'The upstream response is not valid JSON',status:500,
            upstreamStatus:result.output.statusCode,complete:responseCheck.complete,valid:false,
            receivedBytes:Buffer.byteLength(payload??''),findings:responseCheck.findings}));
          return;
        }
        process.stderr.write(`${JSON.stringify({ event: 'request', method: request.method,
          path: url.pathname, status: result.output.statusCode, violations: violations.length,
          nativeResponseValidation:{complete:responseCheck.complete,valid:responseCheck.valid} })}\n`);
        send(reply, result.output.statusCode, payload);
      } catch (error) {
        if(reply.destroyed||reply.writableEnded)return;
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
      await native.close();
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
    listening=true;
    write({ version: 1, event: 'ready', snapshot: input.snapshot, tool: 'Prism',
      toolVersion: '5.15.11', adapter: 'in-memory-http-spec-7.1.0', host: '127.0.0.1',
      port: address.port, operations: operations.length, nativeValidation:native.identity,
      nativeResponseValidation:native.responseIdentity,upstreamForwarding: input.upstream !== undefined });
  } finally {
    if(!listening)await native.close();
  }
}

void main().catch(error => {
  const message = String(error);
  write({ version: 1, event: 'failed', error: message,...(error instanceof SourceError?{failure:{code:error.code,message:error.message,range:error.range,kind:error.kind,source:error.source}}:{}) });
  process.stderr.write(`BusyAPI mock failed: ${message}\n`);
  process.exitCode = 3;
});
