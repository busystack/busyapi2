import {createHash} from 'node:crypto';
import {SourceError} from './document';
import {isNativeFamily} from './specification';
import {documentUriOccurrences,documentUriValidity} from './document_uris';
import {documentUriBase,resolveUri,type ReferenceGraph} from './reference_graph';

export const externalExampleRevision='1';
export type ExternalExampleCondition='invalid'|'unsupported'|'unavailable';
type Problem=Readonly<{code:string;message:string;condition:ExternalExampleCondition}>;
export class ExternalExampleError extends SourceError {
    constructor(readonly condition:ExternalExampleCondition,code:string,message:string) {
        super(code,message,[0,0],'unsupported');
    }
}
export type ExternalExampleRequest=Readonly<{version:1;resource:string;pointer:string;targetResource?:string;problem?:Problem}>;
type Ownership=Readonly<{id:string;identity:string;generation:number;aliases:readonly string[]}>;
export type CapturedExampleResource=Ownership&(
    {state:'available';base64:string;byteLength:number}|{state:'unavailable';problem:Problem});
export type ExternalExampleResourcePacket=CapturedExampleResource&Readonly<{version:1}>;
const record=(value:unknown):value is Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value);
function protocol():never {
    throw new SourceError('example.resource.protocol','Captured external example resources have invalid or ambiguous ownership');
}

/** OAS 3.0 §4.7.19 / 3.1 §4.8.19 / 3.2 §4.19: the Example Object's
 * defining occurrence supplies the base. This is discovery, never acquisition.
 * RFC 3986 §3.5 does not assign JSON Pointer semantics to payload fragments. */
export function externalExampleRequest(graph:ReferenceGraph,resource:string,pointer:string):ExternalExampleRequest {
    const parent=pointer.slice(0,pointer.lastIndexOf('/')),scope=graph.scopes.get(resource+'#'+parent);
    const node=graph.docs.get(resource)?.dataNode(pointer);
    const problem=(code:string,message:string,condition:ExternalExampleCondition='unsupported'):ExternalExampleRequest=>({version:1,resource,pointer,problem:{code,message,condition}});
    if(!scope||scope.kind!=='example'||!isNativeFamily(scope.family)||scope.family==='2.0'||typeof node?.value!=='string')
        return problem('example.external-value.context','This occurrence is not a supported external Example Object value');
    const validity=documentUriValidity(node.value);
    if(validity==='unsupported')return problem('example.external-value.uri.unsupported','The URI host notation has no implemented native resolver');
    if(validity==='invalid')
        return problem('example.external-value.uri','The external example locator is not an evaluable URI reference','invalid');
    try{
        const target=resolveUri(node.value,documentUriBase(graph,scope));
        if(target.username||target.password)return problem('example.external-value.credentials','An external example URI cannot embed credentials','unavailable');
        if(target.hash)return problem('example.external-value.fragment.unsupported','This payload fragment has no implemented representation-specific interpretation');
        target.hash='';
        if(target.protocol==='file:'&&target.search)return problem('example.external-value.query.unsupported','A file example URI with a query has no native acquisition interpretation');
        return {version:1,resource,pointer,targetResource:target.href};
    }catch(error){
        if(!(error instanceof SourceError)&&!(error instanceof TypeError))throw error;
        return problem('example.external-value.uri','The external example URI could not be resolved in its defining context','invalid');
    }
}

export function externalExampleRequests(graph:ReferenceGraph):ExternalExampleRequest[] {
    const requests:ExternalExampleRequest[]=[];
    for(const occurrence of documentUriOccurrences(graph)){
        if(occurrence.scope.kind!=='example'||!isNativeFamily(occurrence.scope.family)||occurrence.scope.family==='2.0'||occurrence.field!=='externalValue')continue;
        if(requests.length>=20000)throw new SourceError('limit.examples.external','External example discovery exceeds 20000 occurrences');
        requests.push(externalExampleRequest(graph,occurrence.scope.resource,occurrence.pointer));
    }
    return requests;
}

/** An immutable captured byte index, distinct from parsed contract documents.
 * Core performs approved IO. Engine consumers verify framing, byte identities
 * and aliases, then use the same media/schema evaluators as received HTTP bytes. */
export class CapturedExampleResources {
    private readonly values=new Map<string,CapturedExampleResource>();
    constructor(raw:unknown=[]) {
        if(!Array.isArray(raw)||raw.length>2048)protocol();
        let total=0;
        for(const value of raw){
            if(!record(value)||value.version!==1||typeof value.id!=='string'||typeof value.identity!=='string'||
                typeof value.generation!=='number'||!Number.isSafeInteger(value.generation)||value.generation<0||
                !Array.isArray(value.aliases)||value.aliases.length>2048||value.aliases.some(alias=>typeof alias!=='string'))protocol();
            const aliases:string[]=[];
            for(const alias of value.aliases){if(typeof alias!=='string')protocol();aliases.push(alias);}
            const id=value.id,identity=value.identity,generation=value.generation;
            let captured:CapturedExampleResource;
            if(value.state==='available'){
                if(typeof value.base64!=='string'||typeof value.byteLength!=='number'||!Number.isSafeInteger(value.byteLength)||value.base64.length>24*1024*1024)protocol();
                const bytes=Buffer.from(value.base64,'base64');
                if(bytes.length>16*1024*1024||bytes.length!==value.byteLength||bytes.toString('base64')!==value.base64||
                    createHash('sha256').update(bytes).digest('hex')!==identity)protocol();
                total+=bytes.length;if(total>32*1024*1024)throw new SourceError('limit.examples.external.bytes','Captured external examples exceed 32 MiB');
                captured=Object.freeze({id,identity,generation,aliases:Object.freeze(aliases),state:'available',base64:value.base64,byteLength:bytes.length});
            }else if(value.state==='unavailable'&&record(value.problem)&&typeof value.problem.code==='string'&&typeof value.problem.message==='string'&&
                (value.problem.condition==='unavailable'||value.problem.condition==='unsupported'||value.problem.condition==='invalid')){
                captured=Object.freeze({id,identity,generation,aliases:Object.freeze(aliases),state:'unavailable',problem:Object.freeze({code:value.problem.code,message:value.problem.message,condition:value.problem.condition})});
            }else protocol();
            for(const name of new Set([id,...aliases])){
                let uri:URL;
                try{uri=new URL(name);}
                catch(error){if(!(error instanceof TypeError))throw error;protocol();}
                if(uri.hash||uri.username||uri.password)protocol();
                if(this.values.has(name))protocol();this.values.set(name,captured);
            }
        }
    }
    read(graph:ReferenceGraph,resource:string,pointer:string):Ownership&Readonly<{base64:string;byteLength:number}> {
        const request=externalExampleRequest(graph,resource,pointer);
        if(request.problem)throw new ExternalExampleError(request.problem.condition,request.problem.code,request.problem.message);
        const captured=this.values.get(request.targetResource!);
        if(!captured)throw new ExternalExampleError('unavailable','example.external-value.unavailable','The external example resource was not captured');
        if(captured.state==='unavailable')throw new ExternalExampleError(captured.problem.condition,captured.problem.code,captured.problem.message);
        return captured;
    }
}
