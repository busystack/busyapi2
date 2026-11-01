import {escape,SourceDocument,SourceError} from './document';
import {record} from './engine_worker_client';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {SchemaSampleCandidates,type SchemaSample,type SchemaSampleLocation,type SchemaSampleSource} from './schema_sample_candidates';
import {evaluateSchemas,schemaProducer} from './schema_evaluation';
import type {MigrationInput} from './migration';

export type DiscriminatorFallbackCandidate=Readonly<{
    parent:GraphScope;
    alternative:GraphScope;
    samples:readonly string[];
    limited:boolean;
}>;
const key=(location:SchemaSampleLocation)=>JSON.stringify([location.resource,location.pointer]);

/** Suggestions do not establish conformance. The shared exact evaluator must
 * accept an object without the discriminating property under both the chosen
 * alternative and the whole parent, including oneOf exclusivity. */
export class MigrationDiscriminatorSamples {
    private readonly candidates:SchemaSampleCandidates;
    private readonly suggestionsByScope=new Map<string,ReturnType<SchemaSampleCandidates['candidates']>>();
    private constructionBytes=0;
    constructor(private readonly graph:ReferenceGraph){this.candidates=new SchemaSampleCandidates(graph);}

    private suggestions(location:SchemaSampleLocation):{samples:SchemaSample[];limit?:SchemaSampleSource} {
        const doc=this.graph.docs.get(location.resource)!,node=doc.dataNode(location.pointer)!;
        const source={...location,range:node.range},samples:SchemaSample[]=[];
        let bytes=0,limit:SchemaSampleSource|undefined;
        const add=(pointer:string)=>{
            const value=doc.dataNode(pointer);if(!value)return;
            const raw=doc.dataJson(pointer);
            if(samples.length>=64||(bytes+=Buffer.byteLength(raw))>1024*1024){limit??={resource:doc.id,pointer,range:value.range};return;}
            samples.push({raw,source:{resource:doc.id,pointer,range:value.range}});
        };
        for(const name of ['const','example','default'])add(location.pointer+'/'+name);
        for(const name of ['enum','examples']){
            const list=doc.dataNode(location.pointer+'/'+name);
            if(list?.kind==='array')for(const index of list.children.keys())add(list.pointer+'/'+index);
        }
        // An unconstrained Schema Object or boolean schema still needs a
        // proposed object. It receives exactly the same subsequent proof.
        if(!samples.length)samples.push({raw:'{}',source});
        return {samples,...(limit?{limit}:{})};
    }
    private proposals(scope:GraphScope):ReturnType<SchemaSampleCandidates['candidates']> {
        const id=key(scope),known=this.suggestionsByScope.get(id);if(known)return known;
        const result=this.candidates.candidates(scope,location=>this.suggestions(location));
        this.constructionBytes+=result.samples.reduce((bytes,sample)=>bytes+Buffer.byteLength(sample.raw),0);
        if(this.constructionBytes>32*1024*1024)
            throw new SourceError('limit.migration.discriminator.samples','Fallback suggestion construction exceeds 32 MiB');
        this.suggestionsByScope.set(id,result);
        return result;
    }
    suggest(parent:GraphScope,alternative:GraphScope,name:string):DiscriminatorFallbackCandidate {
        const own=this.proposals(alternative),whole=this.proposals(parent);
        const samples=new Set<string>();let limited=own.limit!==undefined||whole.limit!==undefined,bytes=0;
        const object=(raw:string)=>{
            const doc=new SourceDocument(raw,'urn:busyapi:migration-discriminator.json',false,'json');
            if(doc.root.kind!=='object')return;
            return new SourceDocument(doc.root.children.has(name)?doc.remove('/'+escape(name)):doc.text,doc.id,false,'json');
        };
        const add=(raw:string)=>{
            if(samples.has(raw))return;
            if(samples.size>=128||(bytes+=Buffer.byteLength(raw))>2*1024*1024){limited=true;return;}
            samples.add(raw);
        };
        const ownObjects=own.samples.map(sample=>object(sample.raw)).filter((doc):doc is SourceDocument=>doc!==undefined);
        const wholeObjects=whole.samples.map(sample=>object(sample.raw)).filter((doc):doc is SourceDocument=>doc!==undefined);
        for(const doc of [...ownObjects,...wholeObjects])add(doc.dataJson(''));
        // Merge suggestions as exact JSON fragments, never through IEEE-754
        // objects. Parent-only required fields can sit outside the union.
        for(const left of ownObjects.slice(0,32))for(const right of wholeObjects.slice(0,16)){
            if(samples.size>=128){limited=true;break;}
            const fields=[...left.root.children].map(([property,value])=>JSON.stringify(property)+':'+left.dataJson(value.pointer));
            for(const [property,value]of right.root.children)if(!left.root.children.has(property))
                fields.push(JSON.stringify(property)+':'+right.dataJson(value.pointer));
            add('{'+fields.join(',')+'}');
        }
        return {parent,alternative,samples:[...samples],limited};
    }
}

/** The target's missing defaultMapping decisions are pending specification
 * metadata, not failed schema assertions. Account for only those exact findings
 * while proving candidates. All other incompleteness blocks selection, and the
 * final migration still requires full target validation after the decisions. */
export async function proveDiscriminatorFallbacks(input:MigrationInput,graph:ReferenceGraph,
    candidates:readonly DiscriminatorFallbackCandidate[]):Promise<ReadonlySet<DiscriminatorFallbackCandidate>> {
    const pending=new Set(graph.scopesFor('schema').filter(scope=>{
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        return scope.family==='3.2'&&typeof value?.discriminator?.propertyName==='string'&&value.discriminator.defaultMapping===undefined;
    }).map(scope=>key({...scope,pointer:scope.pointer+'/discriminator'})));
    const runtimeInstances:{subject:string;location:string;text:string;schema:SchemaSampleLocation}[]=[];
    const pairs:{candidate:DiscriminatorFallbackCandidate;index:number}[]=[];
    let bytes=0;
    for(const candidate of candidates)for(const text of candidate.samples){
        if(runtimeInstances.length>=4096||(bytes+=Buffer.byteLength(text)*2)>8*1024*1024)
            throw new SourceError('limit.migration.discriminator.samples','Fallback proof exceeds 4096 instance checks or 8 MiB');
        pairs.push({candidate,index:runtimeInstances.length});
        for(const schema of [candidate.alternative,candidate.parent])runtimeInstances.push({
            subject:'response-body',location:'migration-discriminator-'+runtimeInstances.length,text,
            schema:{resource:schema.resource,pointer:schema.pointer},
        });
    }
    const checked=await evaluateSchemas({...input,runtimeInstances});
    const pendingFinding=(finding:unknown)=>record(finding)&&
        typeof finding.code==='string'&&['discriminator.default-mapping.required','discriminator.required.incomplete'].includes(finding.code)&&
        typeof finding.resource==='string'&&typeof finding.pointer==='string'&&pending.has(key({resource:finding.resource,pointer:finding.pointer}));
    if(checked.snapshot!==input.snapshot||checked.producer!==schemaProducer.name||checked.producerVersion!==schemaProducer.version||
        checked.configuration!==schemaProducer.configuration||checked.runtimeEvaluations.length!==runtimeInstances.length)
        throw new SourceError('migration.discriminator.proof','Fallback evaluation returned an unrelated proof');
    const pendingIncomplete=checked.findings.some(finding=>pendingFinding(finding)&&finding.code==='discriminator.required.incomplete');
    if(checked.coverage.schemaAssertions.complete!==true||checked.coverage.schemaAssertions.valid!==true||checked.skipped.length||
        checked.coverage.serializedMediaExamples.complete!==true||!checked.complete&&!pendingIncomplete||
        checked.findings.some(finding=>!pendingFinding(finding)&&
            (finding.severity==='error'||finding.incomplete===true))||
        checked.runtimeEvaluations.some(value=>value.complete!==true))
        throw new SourceError('migration.discriminator.unproven','The captured schemas could not completely prove fallback candidates');
    const proved=new Set<DiscriminatorFallbackCandidate>();
    for(const {candidate,index}of pairs){
        const branch=checked.runtimeEvaluations[index],parent=checked.runtimeEvaluations[index+1];
        if(branch.valid===true&&parent.valid===true)proved.add(candidate);
    }
    return proved;
}
