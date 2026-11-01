import {createHash} from 'node:crypto';
import {posix} from 'node:path';
import {SourceError} from './document';
import {CapturedExampleResources,ExternalExampleError,externalExampleRequests,
    type ExternalExampleResourcePacket} from './external_examples';
import {documentUriBase,resolveUri,type ReferenceGraph} from './reference_graph';
import {MigrationSource,type MigrationLocation} from './migration_source';

type CapturedBytes=ReturnType<CapturedExampleResources['read']>;
type SourceLocation=MigrationLocation&Readonly<{range:[number,number]}>;
type Binding=Readonly<{state:'available';source:SourceLocation;bytes:CapturedBytes}>;
type Capture=Binding|Readonly<{state:'unavailable';source:SourceLocation;code:string;message:string}>;
type Occurrence=Readonly<{source:SourceLocation;destination:MigrationLocation}>;
export type MigrationExampleCopy=Readonly<{
    path:string;id:string;base64:string;identity:string;byteLength:number;
    source:Readonly<{resource:string;identity:string;generation:number}>;
    occurrences:readonly Occurrence[];
}>;
type Relocation=Readonly<{
    sources:ReadonlyMap<string,MigrationSource>;
    outputs:readonly MigrationExampleCopy[];
    resources:readonly ExternalExampleResourcePacket[];
    mappings:ReadonlyMap<string,string>;
}>;
const key=(location:MigrationLocation)=>JSON.stringify([location.resource,location.pointer]);
const digest=(value:string)=>createHash('sha256').update(value).digest('hex');
const parent=(pointer:string)=>pointer.slice(0,pointer.lastIndexOf('/'));
const captureIdentity=(capture:Capture)=>capture.state==='available'?
    JSON.stringify([capture.bytes.id,capture.bytes.identity,capture.bytes.generation]):JSON.stringify([capture.code,capture.message]);

/** OAS Example Objects retain media/schema ownership at their occurrences.
 * Payload bytes stay opaque: acquisition and identity checks belong to the
 * captured resource owner, and interpretation stays in the media evaluator.
 * Migration publishes exact independent copies, never another payload loader. */
export class MigrationExamples {
    private readonly bindings=new Map<string,Capture>();
    constructor(graphs:readonly ReferenceGraph[],packets:readonly ExternalExampleResourcePacket[]=[]) {
        const captured=new CapturedExampleResources(packets);
        for(const graph of graphs)for(const request of externalExampleRequests(graph)) {
            const source={resource:request.resource,pointer:request.pointer,
                range:graph.docs.get(request.resource)!.dataNode(request.pointer)!.range};
            let binding:Capture;
            try {binding={state:'available',source,bytes:captured.read(graph,source.resource,source.pointer)};}
            catch(error) {
                if(!(error instanceof ExternalExampleError))throw error;
                binding={state:'unavailable',source,code:error.code,message:error.message};
            }
            const previous=this.bindings.get(key(source));
            if(previous&&captureIdentity(previous)!==captureIdentity(binding))binding={state:'unavailable',source,
                code:'migration.example.shared-context',message:'This shared external example selects different captured resources; occurrence specialization is required'};
            this.bindings.set(key(source),binding);
        }
    }

    relocate(graph:ReferenceGraph,mapped:(source:MigrationLocation)=>readonly MigrationLocation[],
        destination:string,documentPaths:Iterable<string>):Relocation {
        const expected=new Map<string,Binding>();
        for(const binding of this.bindings.values())for(const location of mapped(binding.source)) {
            // Source validation already guards required interpretation. An
            // explicit reviewed omission can retire an ignored declaration;
            // only surviving locators need byte copies in the target.
            if(binding.state==='unavailable')throw new SourceError(binding.code,binding.message,
                binding.source.range,'unsupported',binding.source);
            const previous=expected.get(key(location));
            if(previous&&previous.bytes.id!==binding.bytes.id)
                throw new SourceError('migration.example.ownership','Different source examples share one target locator',
                    binding.source.range,'unsupported',binding.source);
            expected.set(key(location),binding);
        }
        const sources=new Map<string,MigrationSource>(),mappings=new Map<string,string>();
        const copies=new Map<string,{output:MigrationExampleCopy;aliases:Set<string>;occurrences:Occurrence[]}>();
        const paths=new Set([...documentPaths,'busyapi.yaml','migration.json']);
        const visited=new Set<string>();
        let edits=0,work=0;
        for(const request of externalExampleRequests(graph)) {
            const location={resource:request.resource,pointer:request.pointer},binding=expected.get(key(location));
            if(!binding)throw new SourceError('migration.example.provenance',
                'The target external example has no captured source occurrence',undefined,'unsupported',
                {...location,range:graph.docs.get(location.resource)!.dataNode(location.pointer)!.range});
            visited.add(key(location));
            let copy=copies.get(binding.bytes.id);
            if(!copy) {
                const path='examples/'+digest(binding.bytes.id).slice(0,24)+'.bin',id=new URL(path,destination).href;
                if(paths.has(path)||graph.identities.has(id))throw new SourceError('migration.destination.collision',
                    'An external example copy collides with another output resource',binding.source.range,'unsupported',binding.source);
                paths.add(path);
                const occurrences:Occurrence[]=[];
                const output:MigrationExampleCopy={path,id,base64:binding.bytes.base64,identity:binding.bytes.identity,
                    byteLength:binding.bytes.byteLength,source:{resource:binding.bytes.id,identity:binding.bytes.identity,
                        generation:binding.bytes.generation},occurrences};
                copy={output,occurrences,aliases:new Set()};copies.set(binding.bytes.id,copy);
            }
            const scope=graph.scopes.get(location.resource+'#'+parent(location.pointer))!;
            if(graph.literalContainer(scope.resource,scope.pointer)!==undefined)
                throw new SourceError('migration.example.literal-context',
                    'This example locator also belongs to literal data; separate source ownership is required',binding.source.range,'unsupported',binding.source);
            const physical=new URL(location.resource),target=new URL(copy.output.id);
            if(physical.protocol!==target.protocol||physical.host!==target.host)
                throw new SourceError('migration.example.destination','The copied payload needs a common output retrieval boundary',binding.source.range,'unsupported',binding.source);
            let value=posix.relative(posix.dirname(physical.pathname),target.pathname);
            if(value.split('/')[0].includes(':'))value='./'+value;
            const uri=resolveUri(value,documentUriBase(graph,scope)).href;
            // A retained $self/document identity needs a local mapping. Its
            // relative locator and mapping path survive moving the output
            // directory; transient source aliases are never copied here.
            const previous=mappings.get(uri);
            if(graph.identities.has(uri)||previous!==undefined&&previous!==copy.output.path)
                throw new SourceError('migration.example.identity','A copied example URI conflicts with an existing resource identity',binding.source.range,'unsupported',binding.source);
            // Ordinary retrieval mappings also retain their URI after a move.
            // Include the payload route even when it currently equals its
            // physical URI, so those document bases can still acquire it.
            mappings.set(uri,copy.output.path);copy.aliases.add(uri);
            let source=sources.get(location.resource);
            if(!source){source=new MigrationSource(graph.docs.get(location.resource)!);sources.set(location.resource,source);}
            if(source.doc.dataNode(location.pointer)?.value!==value) {
                if(++edits>4096||(work+=source.doc.text.length*2)>128*1024*1024)
                    throw new SourceError('limit.migration.examples','External example relocation exceeds its bounded CST edit work',binding.source.range,'unsupported',binding.source);
                source.set(location.pointer,value);
            }
            copy.occurrences.push({source:binding.source,destination:location});
        }
        for(const [coordinate,binding]of expected)if(!visited.has(coordinate))
            throw new SourceError('migration.example.context','A surviving external example lost its native Example Object context',binding.source.range,'unsupported',binding.source);
        const ordered=[...copies.values()].sort((a,b)=>a.output.path.localeCompare(b.output.path));
        return {sources,mappings,outputs:ordered.map(copy=>copy.output),resources:ordered.map((copy):ExternalExampleResourcePacket=>({
            version:1,id:copy.output.id,identity:copy.output.identity,generation:0,state:'available',
            aliases:[...copy.aliases].sort(),base64:copy.output.base64,byteLength:copy.output.byteLength}))};
    }
}

/** Prove acquisition using only the delivered byte set and its local mappings.
 * Cold contract resolution alone does not discover opaque external examples. */
export function proveMigrationExamples(graph:ReferenceGraph,outputs:readonly MigrationExampleCopy[],
    packets:readonly ExternalExampleResourcePacket[]):void {
    const captured=new CapturedExampleResources(packets),expected=new Map<string,MigrationExampleCopy>();
    for(const output of outputs)for(const occurrence of output.occurrences)expected.set(key(occurrence.destination),output);
    for(const request of externalExampleRequests(graph)) {
        const location={resource:request.resource,pointer:request.pointer},output=expected.get(key(location));
        let bytes:CapturedBytes;
        try {bytes=captured.read(graph,location.resource,location.pointer);}
        catch(error) {
            if(!(error instanceof ExternalExampleError))throw error;
            const source={...location,range:graph.docs.get(location.resource)!.dataNode(location.pointer)!.range};
            throw new SourceError('migration.example.cold-reopen',error.message,source.range,'unsupported',source);
        }
        if(!output||bytes.id!==output.id||bytes.identity!==output.identity||bytes.base64!==output.base64)
            throw new SourceError('migration.example.cold-reopen','The delivered example locator does not select its exact reviewed bytes',undefined,'unsupported',
                {...location,range:graph.docs.get(location.resource)!.dataNode(location.pointer)!.range});
    }
}
