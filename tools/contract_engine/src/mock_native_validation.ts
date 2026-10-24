import {createGraph,type Resource} from './engine';
import {requestOperation} from './execution';
import {SourceError,limits,type Range} from './document';
import {EngineWorkerClient,record} from './engine_worker_client';
import {mediaTypeChoice,mediaTypes} from './media_types';
import {runtimeMediaKind} from './runtime_media';
import type {OperationOccurrence} from './reference_graph';

export type MockCapture={root:string;snapshot:string;resources:Resource[]};
export type NativeMockCheck={complete:boolean;valid:boolean;findings:Record<string,unknown>[]};
type SchemaLocation={resource:string;pointer:string};
type SourceLocation=SchemaLocation&{range:Range};
type NativeMedia={mediaType:string;schema?:SchemaLocation;itemSchema?:SchemaLocation;form:boolean};
type BodyDeclaration={required:boolean;source:SourceLocation;content:NativeMedia[]};
const schemaLocation=(value:unknown):SchemaLocation|undefined=>record(value)&&typeof value.resource==='string'&&typeof value.pointer==='string'
    ?{resource:value.resource,pointer:value.pointer}:undefined;
function sourceLocation(value:unknown):SourceLocation|undefined {
    const source=schemaLocation(value);
    if(!source||!record(value)||!Array.isArray(value.range)||value.range.length!==2)return;
    const [start,end]=value.range;
    if(typeof start!=='number'||typeof end!=='number'||!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||end<start)return;
    return {...source,range:[start,end]};
}

export function mockCapture(value:unknown):MockCapture {
    if(!record(value)||typeof value.root!=='string'||typeof value.snapshot!=='string'||!/^[a-f0-9]{64}$/.test(value.snapshot)||!Array.isArray(value.resources)||!value.resources.length||value.resources.length>limits.resources)
        throw new SourceError('mock.capture','Expected one bounded captured native resource graph');
    const resources:Resource[]=value.resources.map(resource=>{
        if(!record(resource)||typeof resource.id!=='string'||typeof resource.text!=='string'||typeof resource.identity!=='string'||!/^[a-f0-9]{64}$/.test(resource.identity)||typeof resource.generation!=='number'||!Number.isSafeInteger(resource.generation)||resource.generation<0||
            resource.aliases!==undefined&&(!Array.isArray(resource.aliases)||!resource.aliases.every(alias=>typeof alias==='string')))
            throw new SourceError('mock.capture','A captured native resource is malformed');
        return {...resource,id:resource.id,text:resource.text,identity:resource.identity,generation:resource.generation,
            ...(Array.isArray(resource.aliases)?{aliases:resource.aliases}: {})};
    });
    if(!resources.some(resource=>resource.id===value.root)||new Set(resources.map(resource=>resource.id)).size!==resources.length)
        throw new SourceError('mock.capture','The captured native root is missing or resource identities repeat');
    return {root:value.root,snapshot:value.snapshot,resources};
}

/** Native request checks consume the original immutable graph. Prism receives
 * a derived document for its qualified routing/generation role only. */
export class MockNativeValidation {
    private readonly client=new EngineWorkerClient();
    private readonly context:ReturnType<typeof createGraph>;
    private readonly operations=new Map<string,OperationOccurrence>();
    private readonly plans=new Map<string,BodyDeclaration|undefined>();
    private producer?:{name:string;version:string;configuration:string};

    constructor(private readonly capture:MockCapture) {
        this.context=createGraph(capture);
        for(const operation of this.context.graph.operations())if(operation.role==='operation') {
            const method=operation.customMethod?operation.method:operation.method.toUpperCase(),key=JSON.stringify([operation.path,method]);
            if(this.operations.has(key))throw new SourceError('mock.operation.ambiguous','The captured mock route has multiple operation owners');
            this.operations.set(key,operation);
        }
    }

    async prepare(output:{id:string;identity:string}):Promise<string> {
        const checked=await this.client.request('evaluateSchemas',this.capture);
        if(checked.snapshot!==this.capture.snapshot||typeof checked.complete!=='boolean'||!Array.isArray(checked.findings)||checked.findings.some(finding=>!record(finding)))
            throw new SourceError('mock.validation.protocol','Native validation returned an unrelated captured graph');
        if(!checked.complete||checked.findings.some(finding=>finding.severity==='error')){
            const finding=checked.findings.find(finding=>finding.severity==='error')??checked.findings[0];
            const target=schemaLocation(finding),node=target&&this.context.docs.get(target.resource)?.dataNode(target.pointer),range=node?.range??[0,0];
            throw new SourceError(checked.complete?'mock.validation.invalid':'mock.validation.unsupported',
                'Native validation could not qualify the captured mock graph'+(record(finding)?': '+finding.code:''),range,!checked.complete?'unsupported':undefined,target&&node?{...target,range:node.range}:undefined);
        }
        if(typeof checked.producer!=='string'||typeof checked.producerVersion!=='string'||typeof checked.configuration!=='string')throw new SourceError('mock.validation.protocol','The native validator omitted its producer identity');
        this.producer={name:checked.producer,version:checked.producerVersion,configuration:checked.configuration};
        const result=await this.client.request('deriveBundle',{...this.capture,outputId:output.id});
        if(result.snapshot!==this.capture.snapshot||result.complete!==true||!record(result.output)||result.output.id!==output.id||result.output.identity!==output.identity||typeof result.output.text!=='string')
            throw new SourceError('mock.capture.changed','The child derived document differs from the reviewed captured graph');
        return result.output.text;
    }

    get identity(){return this.producer;}

    private declaration(value:unknown):BodyDeclaration|undefined {
        if(value===undefined)return;
        if(!record(value)||typeof value.required!=='boolean'||!Array.isArray(value.content))throw new SourceError('mock.validation.protocol','The native body projection is malformed');
        const source=sourceLocation(value.source);if(!source)throw new SourceError('mock.validation.protocol','The native body projection omitted its source');
        const content=value.content.map((media:unknown):NativeMedia=>{
            if(!record(media)||typeof media.mediaType!=='string')throw new SourceError('mock.validation.protocol','The native media projection is malformed');
            const schema=schemaLocation(media.schema),itemSchema=schemaLocation(media.itemSchema);
            if(media.schema!==undefined&&!schema||media.itemSchema!==undefined&&!itemSchema)
                throw new SourceError('mock.validation.protocol','The native media projection omitted a schema identity');
            return {mediaType:media.mediaType,schema:record(media.schema)&&media.schema.unconstrained===true?undefined:schema,itemSchema,form:media.form!==undefined||media.swaggerForm!==undefined};
        });
        return {required:value.required,source,content};
    }

    qualify(operations:readonly {path:string;method:string}[]):void {
        const covered=new Set(operations.map(operation=>JSON.stringify([operation.path,operation.method.toUpperCase()])));
        for(const [key,operation]of this.operations)if(operation.customMethod||!covered.has(key)) {
            const source=operation.source,node=this.context.docs.get(source.resource)!.dataNode(source.pointer)!;
            throw new SourceError('mock.operation.unsupported','The pinned mock router cannot represent this operation',node.range,'unsupported',{...source,range:node.range});
        }
    }

    async body(path:string,method:string,bytes:Buffer,contentType:string|undefined,present:boolean,signal:AbortSignal):Promise<NativeMockCheck> {
        const key=JSON.stringify([path,method.toUpperCase()]),operation=this.operations.get(key);
        if(!operation)throw new SourceError('mock.operation.owner','The selected mock route has no captured native owner');
        if(!this.plans.has(key)){
            const plan=requestOperation({...this.capture,resource:operation.source.resource,pointer:operation.source.pointer,occurrence:operation.occurrence},this.context);
            if(this.plans.size>=128)this.plans.clear();
            this.plans.set(key,this.declaration(plan.requestBody));
        }
        const declaration=this.plans.get(key);
        const source=declaration?.source??{resource:operation.source.resource,pointer:operation.source.pointer,range:this.context.docs.get(operation.source.resource)!.dataNode(operation.source.pointer)!.range};
        const invalid=(code:string,message:string):NativeMockCheck=>({complete:true,valid:false,findings:[{code,message,pointer:'',severity:'error',subject:'request-body',source}]});
        if(!present)return declaration?.required?invalid('runtime.request.body.required','The captured operation requires a request body'):{complete:true,valid:true,findings:[]};
        const actual=contentType??'application/octet-stream';
        let parsed:ReturnType<typeof mediaTypes>;
        try{parsed=mediaTypes(actual,false);}
        catch(error){
            if(!(error instanceof SourceError))throw error;
            return error.kind==='unsupported'?{complete:false,valid:false,findings:[{code:'runtime.request.body.unchecked',kind:'unsupported',severity:'warning',subject:'request-body',pointer:'',source,message:error.message}]}:
                invalid('runtime.request.content-type','The request Content-Type is malformed');
        }
        if(parsed.length!==1)return invalid('runtime.request.content-type','The request must provide one concrete Content-Type');
        // An ignored/absent declaration imposes no schema assertions. Known
        // HTTP media framing still applies, as for schema-free outgoing JSON.
        if(!declaration)return runtimeMediaKind(actual)==='opaque'?{complete:true,valid:true,findings:[]}:
            this.evaluate(bytes,actual,signal);
        const matches=declaration.content.filter(media=>{
            try{mediaTypeChoice(media.mediaType,actual);return true;}
            catch(error){if(error instanceof SourceError&&error.code==='request.form.content-type')return false;throw error;}
        }).map(media=>{
            const types=mediaTypes(media.mediaType);
            if(types.length!==1)throw new SourceError('mock.content-type','A content map key must contain one media type or range');
            const type=types[0];return {media,rank:(type.type==='*'?0:2)+(type.subtype==='*'?0:1),parameters:type.parameters.size};
        }).sort((a,b)=>b.rank-a.rank||b.parameters-a.parameters);
        if(!matches.length)return invalid('runtime.request.content-type','The request Content-Type does not match the captured operation');
        if(matches.length>1&&matches[0].rank===matches[1].rank&&matches[0].parameters===matches[1].parameters)
            throw new SourceError('mock.content-type.ambiguous','Equally specific content declarations need an explicit interpretation',[0,0],'unsupported');
        const media=matches[0].media;
        const {schema,itemSchema}=media;
        if(!schema&&!itemSchema&&!media.form&&runtimeMediaKind(actual)==='opaque')return {complete:true,valid:true,findings:[]};
        return this.evaluate(bytes,actual,signal,schema,itemSchema);
    }

    private async evaluate(bytes:Buffer,actual:string,signal:AbortSignal,schema?:SchemaLocation,itemSchema?:SchemaLocation):Promise<NativeMockCheck> {
        const result=await this.client.request('evaluateSchemas',{...this.capture,runtimeInstances:[{
            subject:'request-body',location:actual,text:bytes.toString('base64'),mediaType:actual,mediaBase64:true,
            ...(schema?{schema}:{}),...(itemSchema?{itemSchema}:{})}]},signal);
        if(result.snapshot!==this.capture.snapshot||typeof result.complete!=='boolean'||!Array.isArray(result.runtimeEvaluations)||!Array.isArray(result.runtimeFindings))
            throw new SourceError('mock.validation.protocol','Native validation returned an unrelated runtime result');
        const evaluations=result.runtimeEvaluations,findings:Record<string,unknown>[]=[];
        for(const value of result.runtimeFindings){if(!record(value)||typeof value.code!=='string'||typeof value.message!=='string')throw new SourceError('mock.validation.protocol','Native validation returned a malformed finding');findings.push(value);}
        for(const value of evaluations)if(!record(value)||typeof value.complete!=='boolean'||typeof value.valid!=='boolean')throw new SourceError('mock.validation.protocol','Native validation returned a malformed evaluation');
        const complete=result.complete&&evaluations.length>0&&evaluations.every(value=>value.complete===true);
        return {complete,valid:complete&&evaluations.every(value=>value.valid===true),findings};
    }

    close(){return this.client.close();}
}
