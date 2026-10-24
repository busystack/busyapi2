import {createHash} from 'node:crypto';
import {SourceDocument, segments, escape} from './document';
import {ReferenceGraph} from './reference_graph';

export const securityProducer = {name:'busyapi-security-design', version:'1'};
const patterns: [string,RegExp][] = [
    ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/],
    ['aws', /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
    ['github', /\bgh[pousr]_[A-Za-z0-9]{36,255}\b/],
    ['github', /\bgithub_pat_[A-Za-z0-9_]{20,255}\b/],
    ['github', /^(?:Bearer[ \t]+)?ghs_[A-Za-z0-9]{1,32}_eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}$/],
    ['jwt', /^(?:Bearer[ \t]+)?eyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}$/],
];
const sensitiveName = /^(?:password|passwd|secret|client[-_]?secret|api[-_]?key|(?:aws[-_]?)?secret[-_]?access[-_]?key|token|bearer[-_]?token|access[-_]?token|refresh[-_]?token|authorization)$/i;
const illustrative = /(?:example|placeholder|changeme|replace[-_ ]?me|not[-_ ]?(?:a[-_ ]?)?(?:real|secret)|your[-_ ]|^<[^>]+>$|^\{[^}]+\}$)/i;
const credentialQuery = /[?&](?:access[_-]?token|token|secret|password|client[_-]?secret|api[_-]?key|signature|x-amz-(?:signature|credential|security-token))=/i;
function credentialKind(value: string, name = ''): string | undefined {
    for (const [kind, pattern] of patterns) {
        const match=pattern.exec(value);
        if(match && !illustrative.test(match[0]))return kind;
    }
    if (illustrative.test(value)) return;
    if (sensitiveName.test(name) && value.length >= 20 && value.length <= 4096 &&
        /[A-Za-z]/.test(value) && /[0-9]/.test(value) && new Set(value).size >= 10) return 'opaque';
}

// Routine diagnostics never need the complete suspicious value. Exact original
// ranges still navigate to the source; canonical buffers are never redacted.
export function safeFinding(message: string, pointer: string) {
    let masked = false;
    for (const [,pattern] of patterns) {
        const match = pattern.exec(message);
        if (!match) continue;
        masked = true;
        if (message.includes('-----BEGIN ')) message = message.slice(0, match.index) + '[masked]';
        else message = message.replace(new RegExp(pattern.source,'g'), '[masked]');
    }
    message=message.replace(/[A-Za-z0-9_.-]+/g,word=>{
        if((word.startsWith('eyJ')||word.startsWith('ghs_'))&&credentialKind(word)) {masked=true;return '[masked]';}
        return word;
    });
    if(credentialQuery.test(message)) {masked=true;message='Diagnostic text containing a credential-bearing URI query is masked. Inspect the original source.';}
    const credentials=/([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+@/gi;
    if(credentials.test(message)) {masked=true;message=message.replace(credentials,'$1[masked]@');}
    const parts = segments(pointer), safe: string[] = [];
    for (const part of parts) {
        if (credentialKind(part) || credentials.test(part) || credentialQuery.test(part)) {masked = true;break;}
        credentials.lastIndex=0;
        safe.push(part);
    }
    message=message.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u202a-\u202e\u2066-\u2069]/gu,char=>'\\u'+char.charCodeAt(0).toString(16).padStart(4,'0'));
    return {message: message.length > 2048 ? message.slice(0,2048)+'…' : message,
        pointer: safe.length ? '/' + safe.map(part=>part.replaceAll('~','~0').replaceAll('/','~1')).join('/') : '',
        ...(safe.length !== parts.length ? {pointerRedacted:true} : {}),
        ...(masked ? {masked:true} : {})};
}

/** Explainable static advice, not authentication execution or a security proof.
 * Only immutable approved documents are inspected. A likely token can still
 * be illustrative; public operations and Basic declarations are not errors.
 */
export function securityDesign(input: any, docs: Map<string,SourceDocument>, graph: ReferenceGraph, operations: any[]) {
    const findings: any[] = [];
    const findingsLimit = 200, textLimit = 32*1024*1024, nodeLimit = 800000;
    let textCost=0, nodeCost=0, complete=docs.size===input.resources.length, limited=false;
    const add=(doc:SourceDocument,pointer:string,code:string,message:string,severity='warning',range?:[number,number]) => {
        if(findings.length>=findingsLimit) {limited=true;complete=false;return;}
        const location=doc.nodes.get(pointer);
        const safe=safeFinding(message,pointer);
        findings.push({version:1,category:'security',code,severity,...safe,resource:doc.id,root:input.root,
            range:range??location?.range??[0,0],snapshot:input.snapshot,producer:securityProducer.name,producerVersion:securityProducer.version,
            confidence:'advisory',masked:safe.masked===true||code.includes('credential'),id:createHash('sha256').update(JSON.stringify([doc.id,safe.pointer,code,range??location?.range])).digest('hex')});
    };
    outer:for(const doc of docs.values()) {
        if(doc.issues.length) complete=false;
        for(const node of doc.nodes.values()) {
            if(++nodeCost>nodeLimit) {limited=true;complete=false;break outer;}
            if(node.keyRange) {
                const name=segments(node.pointer).at(-1)??'';
                textCost+=name.length;
                if(textCost>textLimit) {limited=true;complete=false;break outer;}
                const kind=credentialKind(name);
                if(kind) add(doc,node.pointer,'security.credential-like.'+kind,
                    kind==='aws' ? 'An AWS-style access key identifier appears here. An identifier alone is not a secret or proof of exposure; review accompanying material. The value is masked.' :
                    'A credential-like value appears here. It may be illustrative; inspect the source to decide. The value is masked.',kind==='aws'?'information':'warning',node.keyRange);
            }
            const value=node.value;
            if(typeof value!=='string') continue;
            if(node.shared && doc.text.slice(...node.range).trimStart().startsWith('*')) continue;
            textCost+=value.length;
            if(textCost>textLimit) {limited=true;complete=false;break outer;}
            const name=segments(node.pointer).at(-1)??'';
            const kind=credentialKind(value,name);
            if(kind) add(doc,node.pointer,'security.credential-like.'+kind,
                kind==='aws' ? 'An AWS-style access key identifier appears here. An identifier alone is not a secret or proof of exposure; review accompanying material. The value is masked.' :
                'A credential-like value appears here. It may be illustrative; inspect the source to decide. The value is masked.',kind==='aws'?'information':'warning');
            // URI credentials are a distinct signal, including reference and
            // server configuration. Nothing is requested or authenticated.
            if(/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
                if(value.length>65536) {limited=true;complete=false;continue;}
                try {
                    const uri=new URL(value);
                    if((uri.username||uri.password) && !illustrative.test(uri.username+uri.password)) add(doc,node.pointer,'security.uri.credentials',
                        'This authored URI contains user information. It may expose credentials when used elsewhere. Inspect the source; no URI value is included in this finding.');
                    let queryCredential=false,queryCount=0;
                    for(const [name,value] of uri.searchParams) {
                        if(++queryCount>2048) {limited=true;complete=false;break;}
                        if(credentialKind(value,name)) {queryCredential=true;break;}
                    }
                    if(queryCredential) add(doc,node.pointer,'security.uri.credential-like-query',
                        'This authored URI contains a credential-like query value. It may be illustrative; inspect the source. The URI and value are masked.');
                }catch {/* URI validity belongs to its specification context. */}
            }
            if(limited) break outer;
        }
    }
    const root=docs.get(input.root)!;
    const mixed=operations.some(op=>Array.isArray(op.value?.security) && op.value.security.some((requirement:any)=>requirement&&typeof requirement==='object'&&Object.keys(requirement).length));
    if(mixed && !Object.hasOwn(root.root.value??{},'security')) for(const operation of operations) {
        if(operation.value && typeof operation.value==='object' && !Object.hasOwn(operation.value,'security')) add(docs.get(operation.resource)!,operation.pointer,'security.declaration.implicit-public',
            'Other operations declare security, while this operation has no root or local requirement. It may be intentionally public; confirm that the absence is deliberate.','information');
    }
    for(const reference of graph.references) {
        // An invalid pointer in an available document is a located validity
        // finding, not omitted dependency content. Unavailable/unsupported or
        // ambiguous acquisition contexts remain explicitly incomplete.
        if(['unavailable','unsupported','ambiguous'].includes(reference.resolution)) complete=false;
        try {
            const uri=new URL(reference.value,reference.base);
            if(/^(?:ftp|http):\/\//i.test(reference.value) && !/^(?:localhost|127(?:\.\d+){3}|\[::1\]|[^.]+\.(?:test|example))$/i.test(uri.hostname) && !uri.hostname.endsWith('.invalid')) {
                const doc=docs.get(reference.resource)!,pointer=reference.pointer+'/'+escape(reference.keyword);
                add(doc,pointer,'security.resource.unencrypted',
                    'This dependency identity uses an unencrypted transport scheme. It may be an offline-mapped identity; review the approved resource mapping rather than assuming a network request occurred.','information');
            }
        }catch {/* The graph reports malformed identities separately. */}
    }
    if(limited) findings.push({version:1,category:'security',code:'security.limit',severity:'warning',resource:root.id,root:input.root,pointer:'',range:root.root.range,
        message:'Static security-design inspection reached its bounded work or finding limit. The category is incomplete; shown findings are not exhaustive.',snapshot:input.snapshot,producer:securityProducer.name,producerVersion:securityProducer.version});
    return {version:1,complete,producer:securityProducer.name,producerVersion:securityProducer.version, snapshot:input.snapshot,configuration:'busyapi-security-design:1:default',
        coverage:'bounded-static-credential-and-declaration-advice-not-runtime-security',findings};
}
