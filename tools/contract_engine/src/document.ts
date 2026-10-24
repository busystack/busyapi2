import YAML, { isMap, isSeq, isScalar, isAlias } from 'yaml';
import { parseTree, getNodeValue, printParseErrorCode } from 'jsonc-parser/lib/esm/main.js';
export const limits = { bytes: 16 * 1024 * 1024, depth: 128, aliases: 64, resources: 2048 };
export type Range = [
    number,
    number
];
export type Node = {
    pointer: string;
    range: Range;
    end: number;
    value: any;
    children: Map<string, Node>;
    keyRange?: Range;
    keyShared?: boolean;
    entryStart?: number;
    entryEnd?: number;
    kind: string;
    flow: boolean;
    shared: boolean;
    style?: string;
    alias?: Node;
    key?: boolean;
    tag?: string;
    valuePrefix?: string;
    implicitFlow?: boolean;
};
export class RawJsonValue {
    constructor(public text: string) { }
}
export class SourceError extends Error {
    constructor(public code: string, message: string, public range: Range = [0, 0]) { super(message); }
}
export const escape = (s: string) => s.replaceAll('~', '~0').replaceAll('/', '~1');
export const segments = (p: string) => p === '' ? [] : p.slice(1).split('/').map(s => s.replaceAll('~1', '/').replaceAll('~0', '~'));
export class SourceDocument {
    nodes = new Map<string, Node>();
    issues: SourceError[] = [];
    unsafe: Range[] = [];
    root: Node;
    format: string;
    newline: string;
    private syntaxTokens = new Map<string, any>();
    constructor(public text: string, public id: string, public tolerant = false, syntax?:'json'|'yaml') {
        if (Buffer.byteLength(text) > limits.bytes)
            throw new SourceError('limit.bytes', 'Document exceeds the 16 MiB analysis limit');
        this.format = syntax??(id.toLowerCase().endsWith('.json') ? 'json' : 'yaml');
        this.newline = text.match(/\r\n|\n|\r/)?.[0] ?? '\n';
        let count = 0;
        const remember = (n: Node) => {
            this.nodes.set(n.pointer, n);
            if (++count > 400000)
                throw new SourceError('limit.nodes', 'Document has too many nodes');
            return n;
        };
        if (this.format === 'json') {
            const errors: any[] = [];
            const tree = parseTree(text, errors, { allowTrailingComma: false, disallowComments: true, allowEmptyContent: false });
            for (const e of errors)
                this.issues.push(new SourceError('json.syntax', `Strict JSON: ${printParseErrorCode(e.error)}`, [e.offset, e.offset + e.length]));
            if (!tree || (!tolerant && this.issues.length))
                throw this.issues[0] ?? new SourceError('json.syntax', 'Expected a JSON value');
            const walk = (t: any, p: string, depth: number, semantic: any): Node => {
                if (depth > limits.depth)
                    throw new SourceError('limit.depth', 'Maximum nesting depth exceeded', [t.offset, t.offset + t.length]);
                const n = remember({ pointer: p, range: [t.offset, t.offset + t.length], end: t.offset + t.length, value: semantic, children: new Map(), kind: t.type, flow: true, shared: false });
                if (t.type === 'object')
                    for (const prop of t.children ?? []) {
                        const key = prop.children[0].value;
                        if (n.children.has(key)) {
                            const issue = new SourceError('duplicate.key', `Duplicate mapping key: ${key}`, n.range);
                            if (!tolerant)
                                throw issue;
                            this.issues.push(issue);
                        }
                        if (!prop.children[1])
                            continue;
                        const c = walk(prop.children[1], p + '/' + escape(key), depth + 1, semantic?.[key]);
                        c.keyRange = [prop.children[0].offset, prop.children[0].offset + prop.children[0].length];
                        c.entryStart = prop.offset;
                        c.entryEnd = prop.offset + prop.length;
                        n.children.set(key, c);
                    }
                if (t.type === 'array')
                    for (const [i, c] of (t.children ?? []).entries()) {
                        const v = walk(c, p + '/' + i, depth + 1, semantic?.[i]);
                        v.entryStart = v.range[0];
                        v.entryEnd = v.range[1];
                        n.children.set(String(i), v);
                    }
                return n;
            };
            this.root = walk(tree, '', 0, getNodeValue(tree));
        }
        else {
            const doc = YAML.parseDocument(text, { version: '1.2', schema: 'core', keepSourceTokens: true, uniqueKeys: true, stringKeys: true, prettyErrors: false, strict: true });
            for (const e of [...doc.errors, ...doc.warnings])
                this.issues.push(new SourceError('yaml.' + e.code, e.message, [e.pos[0], e.pos[1]]));
            if (!tolerant && this.issues.length)
                throw this.issues[0];
            let value: any;
            try {
                value = doc.toJS({ maxAliasCount: limits.aliases });
            }
            catch {
                throw new SourceError('yaml.alias', 'Alias expansion exceeds the safe limit');
            }
            const dataAnchors=new Map<string,Node>();
            // A member owns syntax (including an explicit '?'), but not its
            // comma or surrounding comment trivia. Valueless pairs have no
            // value AST range; the key and CST separators still bound them.
            const memberRange = (item: any, key: any, value: any, fallback: Range): Range => {
                if (!item) return fallback;
                const syntax = (parts: any[] = []) => parts.filter(part => !['comma', 'space', 'newline', 'comment'].includes(part.type));
                const start = syntax(item?.start)[0]?.offset ?? item?.key?.offset ?? syntax(item?.sep)[0]?.offset ?? item?.value?.offset ?? fallback[0];
                const ends = [...syntax(item?.start), ...syntax(item?.sep)].map(part => part.offset + part.source.length);
                // Empty AST nodes locate an insertion point, sometimes after
                // separator whitespace. Only physical CST nodes own content.
                const keyEnd = item.key ? key?.range?.[1] ?? start : start;
                const valueEnd = item.value ? value?.range?.[1] ?? start : start;
                return [start, Math.max(start, keyEnd, valueEnd, ...ends)];
            };
            const walk = (t: any, p: string, v: any, depth: number, inherited = false): Node => {
                if (depth > limits.depth)
                    throw new SourceError('limit.depth', 'Maximum nesting depth exceeded', t?.range?.slice(0, 2));
                const n = remember({ pointer: p, range: [t?.range?.[0] ?? 0, t?.range?.[1] ?? 0], end: t?.range?.[2] ?? t?.range?.[1] ?? 0, value: v, children: new Map(), kind: isMap(t) ? 'object' : isSeq(t) ? 'array' : 'scalar', flow: t?.flow ?? false, shared: inherited || !!t?.anchor || isAlias(t), style: t?.type, tag: t?.tag });
                const sourceToken: any = t?.srcToken;
                if(sourceToken)this.syntaxTokens.set(p,sourceToken);
                if (typeof t?.anchor === 'string') dataAnchors.set(t.anchor,n);
                // YAML permits an anchor name to be reused. Capture the
                // preceding CST occurrence now, not the final name binding.
                if (isAlias(t)) n.alias = dataAnchors.get(t.source);
                if (isScalar(t) && t.tag && !['tag:yaml.org,2002:str', 'tag:yaml.org,2002:int', 'tag:yaml.org,2002:float', 'tag:yaml.org,2002:bool', 'tag:yaml.org,2002:null'].includes(t.tag))
                    throw new SourceError('yaml.tag', 'Non-JSON-compatible YAML tag', n.range);
                if (isMap(t)) {
                    // A pair in a flow sequence is a map without authored
                    // braces. Retain its real CST and complete member range.
                    if (n.flow && !sourceToken && t.items.length === 1) {
                        const pair = t.items[0];
                        n.implicitFlow = true;
                        this.syntaxTokens.set(p, pair.srcToken);
                        n.range = memberRange(pair.srcToken, pair.key, pair.value, n.range);
                    }
                    for (const pair of t.items) {
                        if (!isScalar(pair.key))
                            throw new SourceError('yaml.key', 'Only scalar string mapping keys are supported', n.range);
                        const key = String(pair.key.value);
                        if (n.children.has(key))
                            this.unsafe.push(n.range);
                        const pointer = p + '/' + escape(key);
                        // A key anchor precedes its value and can rebind a
                        // previous value anchor. Keep the key's own provenance;
                        // the member value at this pointer is a different node.
                        if (typeof pair.key.anchor === 'string') {
                            const source: Node = { pointer, range: pair.key.range.slice(0, 2) as Range, end: pair.key.range[2], value: key, children: new Map(), kind: 'scalar', flow: false, shared: true, key: true, style: pair.key.type, tag: pair.key.tag };
                            dataAnchors.set(pair.key.anchor, source);
                        }
                        const c = walk(pair.value, pointer, v?.[key], depth + 1, n.shared);
                        c.keyRange = pair.key.range?.slice(0, 2) as Range;
                        c.keyShared = !!pair.key.anchor;
                        if (!pair.value) {
                            const at = n.implicitFlow ? n.range[1] : pair.key.range[1];
                            c.range = [at, at];
                            const tail = pair.srcToken?.sep?.filter((part:any) => part.type !== 'space').at(-1);
                            c.end = Math.max(pair.key.range[2], tail ? tail.offset + tail.source.length : at);
                            const colon = pair.key.range[0] === pair.key.range[1] && !/\s/.test(this.text[at - 1]) ? ' : ' : ': ';
                            c.valuePrefix = n.flow ? colon : this.newline + ' '.repeat(sourceToken.indent) + ': ';
                        }
                        else if (n.implicitFlow && c.range[0] === c.range[1])
                            c.range = [n.range[1], n.range[1]];
                        const span = memberRange(pair.srcToken, pair.key, pair.value, [pair.key.range[0], c.range[1]]);
                        c.entryStart = span[0];
                        c.entryEnd = n.flow ? span[1] : c.end;
                        n.children.set(key, c);
                    }
                }
                if (isSeq(t))
                    for (const [i, c] of t.items.entries()) {
                        const child = walk(c, p + '/' + i, v?.[i], depth + 1, n.shared);
                        const item = sourceToken?.items[i];
                        const span = child.implicitFlow ? child.range : memberRange(item, undefined, c, child.range);
                        child.entryStart = n.flow ? span[0] : child.range[0];
                        child.entryEnd = n.flow ? span[1] : child.end;
                        n.children.set(String(i), child);
                    }
                return n;
            };
            this.root = walk(doc.contents, '', value, 0);
            const finiteNumber=(v:number,pointer:string)=>{
                if(Number.isFinite(v))return true;
                // Infinity in the JS projection can represent a perfectly
                // finite mathematical JSON decimal. Its canonical lexeme,
                // unlike YAML .inf/.nan, is evaluated exactly downstream.
                try{return /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/.test(this.dataJson(pointer));}catch{return false;}
            };
            const compatible = (v: any, d = 0, pointer=''): boolean => d < limits.depth && (v === null || typeof v === 'string' || typeof v === 'boolean' || (typeof v === 'number' && finiteNumber(v,pointer)) || (Array.isArray(v) ? v.every((x,i) => compatible(x, d + 1,pointer+'/'+i)) : typeof v === 'object' && Object.entries(v).every(([key,x]) => compatible(x, d + 1,pointer+'/'+escape(key)))));
            if (!compatible(value))
                throw new SourceError('yaml.value', 'YAML value is not finite JSON-compatible data');
        }
        for (const issue of this.issues) {
            const a = Math.min(text.length, issue.range[0]), b = Math.min(text.length, issue.range[1]);
            const owners = [...this.nodes.values()].filter(n => n.range[0] <= a && n.range[1] >= b).sort((x, y) => (x.range[1] - x.range[0]) - (y.range[1] - y.range[0]));
            this.unsafe.push(owners[0]?.range ?? this.root.range);
        }
    }
    syntaxSafe(pointer: string): boolean {
        const n = this.nodes.get(pointer);
        if (!n)
            return false;
        return !this.unsafe.some(([a, b]) => n.range[0] < b && n.range[1] > a || a === b && n.range[0] <= a && n.range[1] >= a);
    }
    assertSafe(pointer: string) {
        const parts = segments(pointer);
        let at = pointer;
        while (!this.nodes.has(at) && parts.length) {
            parts.pop();
            at = parts.length ? '/' + parts.map(escape).join('/') : '';
        }
        if (!this.syntaxSafe(at))
            throw new SourceError('edit.scope.syntax', 'This source scope has ambiguous syntax; retain its draft and repair Source');
    }
    node(p: string) {
        const n = this.nodes.get(p);
        if (!n)
            throw new SourceError('edit.target', 'The captured source occurrence no longer exists');
        return n;
    }
    /** Replacing a value also removes its descendants' anchor definitions.
     * An anchored member key is outside its own value, but inside an entry
     * removal or a containing value replacement. */
    assertUnshared(pointer:string,includeKey=false) {
        const root=this.node(pointer),pending=[root];
        while(pending.length) {
            const node=pending.pop()!;
            if(node.shared||node.keyShared&&(includeKey||node!==root))
                throw new SourceError('edit.shared','This source edit would change an anchored or aliased occurrence; edit its explicit source definition',node.keyShared?node.keyRange:node.range);
            for(const child of node.children.values())pending.push(child);
        }
    }
    /** Lazily inspect the already parsed YAML CST, never comment-looking data.
     * Used only by explicit source-copy reviews; normal painting/analysis does
     * not traverse these tokens or create a second parser/model. */
    comments(pointer:string,includeEntry=false):Range[] {
        const node=this.node(pointer),ranges=new Map<number,Range>();let work=0;
        const start=includeEntry?node.entryStart??node.range[0]:node.range[0],end=includeEntry?node.end:node.range[1];
        const visit=(token:any)=>{
            if(!token||typeof token!=='object')return;
            if(++work>1000000)throw new SourceError('limit.refactor.comments','The authored comment review exceeds its bounded token budget');
            if(token.type==='comment'&&Number.isInteger(token.offset)&&typeof token.source==='string'){
                const range:Range=[token.offset,token.offset+token.source.length];
                if(range[0]>=start&&range[1]<=end)ranges.set(range[0],range);
                return;
            }
            for(const value of Object.values(token)){
                if(Array.isArray(value)){for(const item of value)visit(item);}
                else if(value&&typeof value==='object')visit(value);
            }
        };
        visit(this.syntaxTokens.get(includeEntry&&pointer?pointer.slice(0,pointer.lastIndexOf('/')):pointer));
        return [...ranges.values()].sort((a,b)=>a[0]-b[0]);
    }
    indent(pos: number) { const start = Math.max(this.text.lastIndexOf('\n', pos - 1), this.text.lastIndexOf('\r', pos - 1)) + 1; const prefix = this.text.slice(start, pos); return /^(?: *- +)+$/.test(prefix) ? prefix.length : prefix.match(/^ */)?.[0].length ?? 0; }
    private valueIndent(n: Node): number {
        // A compact mapping's key can start after sequence markers. Its CST
        // indent, also inherited by nested flow values, owns continuation lines.
        // Implicit nulls have no token, so use their containing collection.
        const token = this.syntaxTokens.get(n.pointer) ?? this.syntaxTokens.get(n.pointer.slice(0, n.pointer.lastIndexOf('/')));
        return Math.max(this.indent(n.range[0]), token?.indent ?? token?.key?.indent ?? 0);
    }
    private flowTrailingComma(n: Node): { offset: number; source: string } | undefined {
        const token = this.syntaxTokens.get(n.pointer);
        if (token?.type !== 'flow-collection') return;
        const tail = token.items.at(-1);
        if (tail?.key || tail?.value || tail?.sep) return;
        if (tail?.start.some((part:any) => !['comma', 'space', 'newline', 'comment'].includes(part.type))) return;
        return tail?.start.find((part:any) => part.type === 'comma');
    }
    lineStart(pos: number) { return Math.max(this.text.lastIndexOf('\n', pos - 1), this.text.lastIndexOf('\r', pos - 1)) + 1; }
    emit(value: any, n?: Node, flow = false): string {
        // A collection replacing a scalar must fit that value's inline slot.
        let emitted = this.emitValue(value, n, flow || n?.kind === 'scalar' && value !== null && typeof value === 'object' || typeof value === 'string' && value.includes('\n') && !n?.style?.startsWith('BLOCK_'));
        if(this.format==='yaml'&&n&&n.range[1]>n.range[0]&&!/[\r\n]$/.test(emitted))emitted+=this.text.slice(...n.range).match(/(?:\r\n|\r|\n)$/)?.[0]??'';
        const token = this.format === 'yaml' && n ? this.syntaxTokens.get(n.pointer) : undefined;
        if (token?.type === 'block-scalar') {
            const header = token.props.find((p:any) => p.type === 'block-scalar-header');
            const comment = token.props.find((p:any) => p.type === 'comment');
            if (header && comment && comment.offset + comment.source.length <= n!.range[1]) {
                // Only header props are comments; '#' in the body is data.
                const note = this.text.slice(header.offset + header.source.length, comment.offset + comment.source.length);
                const at = emitted[0] === '|' || emitted[0] === '>'
                    ? emitted.search(/\r\n|\r|\n/)
                    : emitted.length - (emitted.match(/(?:\r\n|\r|\n)$/)?.[0].length ?? 0);
                emitted = emitted.slice(0, at < 0 ? emitted.length : at) + note + emitted.slice(at < 0 ? emitted.length : at);
            }
        }
        if (this.format !== 'yaml' || !n || n.range[0] !== n.range[1]) return emitted;
        if (n.valuePrefix) return n.valuePrefix + emitted + (this.text[n.range[0]] === '#' ? ' ' : '');
        // Implicit nulls have no token. Their range may immediately follow a
        // colon/dash or precede a comment; neither separator belongs to it.
        const at = n.range[0];
        return (at && !/\s/.test(this.text[at - 1]) ? ' ' : '') + emitted + (this.text[at] === '#' ? ' ' : '');
    }
    private emitValue(value: any, n?: Node, flow = false): string {
        if (value instanceof RawJsonValue)
            return value.text.replace(/\r\n|\n|\r/g, this.newline + (n ? ' '.repeat(this.valueIndent(n) + (this.format === 'yaml' && (n.kind === 'scalar' || n.flow) ? 2 : 0)) : ''));
        if (this.format === 'json' || flow)
            return JSON.stringify(value);
        if (n?.style === 'QUOTE_SINGLE' && typeof value === 'string' && !value.includes('\n'))
            return "'" + value.replaceAll("'", "''") + "'";
        if (n?.style === 'QUOTE_DOUBLE' && typeof value === 'string')
            return JSON.stringify(value);
        if (n?.style?.startsWith('BLOCK_') && typeof value === 'string') {
            const block = this.yamlValue(value, n).replaceAll('\n', this.newline + ' '.repeat(this.valueIndent(n) + 2));
            return block + (/[\r\n]$/.test(this.text.slice(...n.range)) ? this.newline : '');
        }
        const emitted = this.yamlValue(value, n).replaceAll('\n', this.newline);
        if(n && value !== null && typeof value === 'object')return emitted.replaceAll(this.newline, this.newline+' '.repeat(this.valueIndent(n)));
        return typeof value === 'string' && value.includes('\n') ? emitted.replaceAll(this.newline, this.newline + ' '.repeat((n ? this.valueIndent(n) : 0) + 2)) : emitted;
    }
    private yamlValue(value: any, n?: Node): string {
        const doc = new YAML.Document(value);
        if (typeof value === 'string' && n?.style?.startsWith('BLOCK_')) (doc.contents as any).type = n.style;
        const separator = n && /[\r\n]$/.test(this.text.slice(...n.range));
        // Chomping and indentation belong to the replaced source slot. Quote
        // whitespace-sensitive strings, also within newly emitted collections,
        // so adjusting source separators cannot consume their content.
        YAML.visit(doc, { Scalar(_, scalar) {
            if (typeof scalar.value === 'string' &&
                (scalar.type?.startsWith('BLOCK_') || scalar.value.includes('\n')) &&
                (/^\s/u.test(scalar.value) || /\s$/u.test(separator && scalar.value.endsWith('\n') ? scalar.value.slice(0, -1) : scalar.value))) scalar.type = 'QUOTE_DOUBLE';
        } });
        // Remove only the serializer's document separator, never string data.
        return doc.toString({ lineWidth: 0 }).slice(0, -1);
    }
    private assertRange(start: number, end: number) {
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || start > end || end > this.text.length)
            throw new SourceError('edit.range', 'The captured source edit has invalid boundaries');
    }
    replace(start: number, end: number, value: string) {
        this.assertRange(start, end);
        return this.text.slice(0, start) + value + this.text.slice(end);
    }
    set(pointer: string, value: any): string {
        const n = this.nodes.get(pointer);
        if (n) {
            if (n.shared)
                throw new SourceError('edit.shared', 'This occurrence uses an anchor or alias; choose an explicit source target');
            if (!(value instanceof RawJsonValue) && JSON.stringify(n.value) === JSON.stringify(value))
                return this.text;
            this.assertUnshared(pointer);
            const text = this.replace(...n.range, this.emit(value, n, n.flow));
            if (n.tag) {
                const result = new SourceDocument(text, this.id, true);
                result.assertSafe(pointer);
                const expected = value instanceof RawJsonValue ? new SourceDocument(value.text, 'value.json').root.value : value;
                if (JSON.stringify(result.node(pointer).value) !== JSON.stringify(expected))
                    throw new SourceError('edit.tag', 'The authored YAML tag would change the requested value; edit its tag in Source', n.range);
            }
            return text;
        }
        const parts = segments(pointer), key = parts.pop()!, parentPointer = parts.length ? '/' + parts.map(escape).join('/') : '';
        const parent = this.node(parentPointer);
        if (parent.shared)
            throw new SourceError('edit.shared', 'Container is shared through an anchor or alias');
        if (parent.kind !== 'object' && parent.kind !== 'array')
            throw new SourceError('edit.container', 'Target is not a mapping or sequence');
        const entries = [...parent.children.values()];
        const last = entries.at(-1);
        if (parent.flow || this.format === 'json') {
            const at = parent.range[1] - 1;
            // New flow entries have no value node yet; the parent supplies
            // the YAML continuation context for exact multiline JSON.
            const rendered = value instanceof RawJsonValue && this.format === 'yaml' ? this.emitValue(value, parent, true) : this.emit(value, undefined, true);
            const entry = parent.kind === 'object' ? JSON.stringify(key) + ': ' + rendered : rendered;
            if (parent.implicitFlow)
                return this.replace(...parent.range, '{' + this.text.slice(...parent.range) + ', ' + entry + '}');
            const trailing = last && this.flowTrailingComma(parent);
            // Reuse the authored separator and retain its trailing-comma style.
            return this.replace(at, at, (last ? trailing ? ' ' : ', ' : '') + entry + (trailing ? ',' : ''));
        }
        const indent = this.indent(parent.range[0]);
        let emitted = this.emit(value);
        let entry: string;
        if (parent.kind === 'object') {
            if (value !== null && typeof value === 'object')
                entry = this.emit(key) + ':' + this.newline + ' '.repeat(indent + 2) + emitted.replaceAll(this.newline, this.newline + ' '.repeat(indent + 2));
            else
                entry = this.emit(key) + ': ' + emitted.replaceAll(this.newline, this.newline + ' '.repeat(indent));
        }
        else
            entry = '- ' + emitted.replaceAll(this.newline, this.newline + ' '.repeat(indent + 2));
        const at = last?.end ?? parent.range[1];
        const before = this.text.slice(0, at);
        const ends = /[\r\n]$/.test(before);
        const tail = at < this.text.length || /[\r\n]$/.test(this.text);
        return this.replace(at, at, (ends ? '' : this.newline) + ' '.repeat(indent) + entry + (tail ? this.newline : ''));
    }
    /** Locate numeric/data provenance through YAML aliases without creating
     * editable virtual nodes, expanding source, or changing physical ranges.
     * Ordinary node()/set()/remove() retain their shared-ownership guards. */
    dataNode(pointer:string): Node | undefined {
        const seen=new Set<string>();let at=pointer;
        for(let depth=0;depth<=limits.depth;depth++) {
            if(seen.has(at))throw new SourceError('yaml.alias.cycle','Cyclic data aliases are not JSON-compatible');
            seen.add(at);
            const exact=this.nodes.get(at);if(exact&&exact.alias===undefined)return exact;
            let owner=at;
            while(owner&&!this.nodes.has(owner))owner=owner.slice(0,owner.lastIndexOf('/'));
            const alias=this.nodes.get(owner)?.alias;
            if(alias===undefined)return;
            if(alias.key)return at===owner?alias:undefined;
            at=alias.pointer+at.slice(owner.length);
        }
        throw new SourceError('limit.alias.provenance','Alias provenance exceeds the bounded depth');
    }
    /** Eligibility for a read-only semantic occurrence, including the alias
     * token and its actual preceding definition. Never grants edit eligibility
     * to a virtual descendant: syntaxSafe()/node()/set() remain physical. */
    dataSyntaxSafe(pointer:string): boolean {
        const source=this.dataNode(pointer);
        if(!source || !this.syntaxSafe(source.pointer))return false;
        let occurrence=pointer;
        while(occurrence&&!this.nodes.has(occurrence))occurrence=occurrence.slice(0,occurrence.lastIndexOf('/'));
        return this.syntaxSafe(occurrence);
    }
    dataLocation(pointer:string) {
        const source=this.dataNode(pointer);
        if(!source)throw new SourceError('data.provenance','The semantic occurrence has no canonical source provenance');
        let occurrence=pointer;
        while(occurrence&&!this.nodes.has(occurrence))occurrence=occurrence.slice(0,occurrence.lastIndexOf('/'));
        return {range:source.range,...(source.pointer!==pointer?{physicalPointer:source.pointer,occurrenceRange:this.node(occurrence).range}:{})};
    }
    dataJson(pointer: string, project?: (node: Node, occurrence: string) => string | undefined): string {
        const node = this.dataNode(pointer);
        if(!node)throw new SourceError('data.provenance','The data occurrence has no canonical source provenance');
        if (this.format === 'json' && !project)
            return this.text.slice(...node.range);
        const active=new Set<Node>();let count=0,bytes=0;
        const token=(text:string)=>{bytes+=text.length;if(bytes>32*1024*1024)throw new SourceError('limit.data.bytes','The JSON-compatible data projection exceeds its bounded size');return text;};
        const render = (n: Node, occurrence: string): string => {
            if (!n.key) n = this.dataNode(n.pointer)!;
            if(active.has(n))throw new SourceError('yaml.alias.cycle','Cyclic data aliases are not JSON-compatible');
            if(++count>400000)throw new SourceError('limit.data.nodes','The JSON-compatible data projection exceeds its bounded node count');
            // A YAML alias has one physical value but each occurrence has its
            // own semantic context/base. Readers may project that occurrence;
            // this does not add editable virtual nodes or expand source text.
            const replacement=project?.(n, occurrence);
            if(replacement!==undefined)return token(replacement);
            active.add(n);
            try {
            if (n.kind === 'object' && n.children.size)
                return token('{') + [...n.children.entries()].map(([key, child],i) => token((i?',':'')+JSON.stringify(key) + ':') + render(child, occurrence+'/'+escape(key))).join('') + token('}');
            if (n.kind === 'array' && n.children.size)
                return token('[') + [...n.children.values()].map((child,i)=>token(i?',':'')+render(child, occurrence+'/'+i)).join('') + token(']');
            if(this.format==='json')return token(this.text.slice(...n.range));
            if (typeof n.value === 'number') {
                let raw = this.text.slice(...n.range).trim().replaceAll('_', '').replace(/^\+/, '');
                if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:e[+-]?\d+)?$/i.test(raw))
                    return token(raw);
                // YAML Core permits .5, 1., and leading decimal zeroes.
                // Normalize syntax only; Number/String would round large
                // coefficients before the exact instance evaluator sees them.
                const decimal = /^(-?)(\d*)(?:\.(\d*))?([eE][+-]?\d+)?$/.exec(raw);
                if (decimal && (decimal[2] || decimal[3]))
                    return token(decimal[1] + (decimal[2].replace(/^0+(?=\d)/, '') || '0') +
                        (decimal[3] !== undefined ? '.' + (decimal[3] || '0') : '') + (decimal[4] ?? ''));
                if (/^-?(?:0x[\da-f]+|0o[0-7]+|\d+)$/i.test(raw)) {
                    const negative = raw.startsWith('-');
                    if (negative)
                        raw = raw.slice(1);
                    return token((negative ? -BigInt(raw) : BigInt(raw)).toString());
                }
                throw new SourceError('data.number','This YAML number has no JSON-compatible numeric representation');
            }
            const serialized=JSON.stringify(n.value);
            if(serialized===undefined)throw new SourceError('data.value','This value has no JSON-compatible representation');
            return token(serialized);
            } finally {active.delete(n);}
        };
        return render(node, pointer);
    }
    remove(pointer: string): string {
        const n = this.node(pointer);
        this.assertUnshared(pointer,true);
        const parts = segments(pointer);
        parts.pop();
        const parent = this.node(parts.length ? '/' + parts.map(escape).join('/') : '');
        const children = [...parent.children.values()];
        const index = children.indexOf(n);
        if (index < 0) throw new SourceError('edit.target', 'The captured occurrence is not a removable member');
        if (parent.flow || this.format === 'json') {
            let a = n.entryStart ?? n.range[0], b = n.entryEnd ?? n.range[1];
            this.assertRange(a, b);
            if (a === b || a < parent.range[0] || b > parent.range[1])
                throw new SourceError('edit.range', 'The captured member has invalid boundaries');
            if (parent.implicitFlow) return this.replace(a, b, '{}');
            const token = this.syntaxTokens.get(parent.pointer);
            if (this.format === 'yaml' && token?.type === 'flow-collection') {
                const after = token.items[index + 1]?.start.find((part:any) => part.type === 'comma');
                const before = token.items[index]?.start.find((part:any) => part.type === 'comma');
                // Remove one real separator, retaining the intervening source
                // trivia rather than consuming a neighbour's comments.
                if (after) {
                    this.assertRange(b, after.offset);
                    return this.replace(a, after.offset + after.source.length, this.text.slice(b, after.offset));
                }
                if (before) {
                    this.assertRange(before.offset + before.source.length, a);
                    const trivia = token.items[index].start.some((part:any) => part.type === 'comment')
                        ? this.text.slice(before.offset + before.source.length, a) : '';
                    return this.replace(before.offset, b, trivia);
                }
                return this.replace(a, b, '');
            }
            if (children.length > 1) {
                if (index < children.length - 1)
                    b = children[index + 1].entryStart ?? children[index + 1].range[0];
                else
                    a = children[index - 1].entryEnd ?? children[index - 1].range[1];
            }
            return this.replace(a, b, '');
        }
        if (children.length === 1) {
            const a = this.lineStart(n.entryStart ?? n.range[0]);
            const prefix = this.text.slice(a, parent.kind === 'array' ? Math.min(parent.range[0], n.entryStart ?? n.range[0]) : n.entryStart ?? n.range[0]);
            return this.replace(a, n.end, (/\S/.test(prefix) ? prefix : ' '.repeat(this.indent(parent.range[0]))) + (parent.kind === 'array' ? '[]' : '{}') + (/[\r\n]$/.test(this.text.slice(a, n.end)) ? this.newline : ''));
        }
        const a = this.lineStart(n.entryStart ?? n.range[0]);
        const prefix = this.text.slice(a, parent.kind === 'array' ? Math.min(parent.range[0], n.entryStart ?? n.range[0]) : n.entryStart ?? n.range[0]);
        // Compact block mappings can share a line with one or more sequence
        // markers. Keep those markers and the following members' indentation.
        return this.replace(a, n.end, /\S/.test(prefix) ? prefix.trimEnd() + this.newline : '');
    }
}
