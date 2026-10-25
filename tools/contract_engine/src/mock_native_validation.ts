import {createGraph,type Resource} from './engine';
import {requestOperation} from './execution';
import {SourceError,limits} from './document';
import {EngineWorkerClient,record} from './engine_worker_client';
import {mediaTypes} from './media_types';
import {runtimeMediaKind} from './runtime_media';
import type {RuntimeFormTarget} from './runtime_form';
import type {OperationOccurrence} from './reference_graph';
import {nativeMedia,selectNativeMedia,schemaLocation,sourceLocation,type SchemaLocation,type SourceLocation,type NativeMedia,type NativeRuntimeInstance,type NativeMockCheck,type NativeRuntimeCheck,type NativeRuntimeEvaluation} from './mock_projection';
import {mockResponseProducer,validateMockResponse} from './mock_response_validation';
import {mockParameterProducer,validateMockParameters} from './mock_request_parameters';
import {schemaProducer} from './schema_evaluation';
import {mockSecurityProducer,validateMockSecurity} from './mock_request_security';
import {MockOperationProjection,mockWireMethod,mockMethodProducer} from './mock_operations';
import {maximumMockMethodBytes} from './mock_method_transport';
import {MockSchemaSamples,mockSampleProducer} from './mock_schema_samples';
export type {NativeMockCheck} from './mock_projection';

export type MockCapture={root:string;snapshot:string;resources:Resource[]};
type BodyDeclaration={required:boolean;source:SourceLocation;content:NativeMedia[]};

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
    private readonly plans=new Map<string,{operation:OperationOccurrence;description:ReturnType<typeof requestOperation>;body:BodyDeclaration|undefined}>();
    private producer?:{name:string;version:string;configuration:string};
    private operationProjection?:MockOperationProjection;
    private readonly samples:MockSchemaSamples;

    constructor(private readonly capture:MockCapture) {
        this.context=createGraph(capture);
        this.samples=new MockSchemaSamples(this.context.graph,(instances,signal)=>this.evaluateInstances(instances,signal),capture.snapshot);
        for(const operation of this.context.graph.operations())if(operation.role==='operation') {
            const key=JSON.stringify([operation.path,mockWireMethod(operation)]);
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
        if(checked.producer!==schemaProducer.name||checked.producerVersion!==schemaProducer.version||checked.configuration!==schemaProducer.configuration)
            throw new SourceError('mock.validation.revision','The native evaluator revision differs from the captured mock implementation');
        this.producer={name:checked.producer,version:checked.producerVersion,configuration:checked.configuration};
        const result=await this.client.request('deriveBundle',{...this.capture,outputId:output.id});
        if(result.snapshot!==this.capture.snapshot||result.complete!==true||!record(result.output)||result.output.id!==output.id||result.output.identity!==output.identity||typeof result.output.text!=='string')
            throw new SourceError('mock.capture.changed','The child derived document differs from the reviewed captured graph');
        this.operationProjection=new MockOperationProjection(this.context.graph,output.id,result.provenance);
        return result.output.text;
    }

    get identity(){return this.producer;}
    get responseIdentity(){return this.producer&&{...mockResponseProducer,configuration:'response-wire-v3:'+this.producer.configuration};}
    get parameterIdentity(){return this.producer&&{...mockParameterProducer,configuration:'parameter-wire-v3:'+this.producer.configuration};}
    get securityIdentity(){return this.producer&&{...mockSecurityProducer,configuration:'security-wire-v1:'+this.producer.configuration};}
    get generationIdentity(){return this.producer&&{...mockSampleProducer,configuration:'captured-schema-candidates-v2:'+this.producer.configuration};}
    get methodIdentity(){return this.producer&&{...mockMethodProducer,configuration:'method-wire-v1:'+this.producer.configuration};}

    projectedOperations(document:Record<string,unknown>) {
        if(!this.operationProjection)throw new SourceError('mock.validation.protocol','The captured operation projection was not prepared');
        return this.operationProjection.document(document);
    }

    private declaration(value:unknown,operation:OperationOccurrence):BodyDeclaration|undefined {
        if(value===undefined)return;
        if(!record(value)||typeof value.required!=='boolean'||!Array.isArray(value.content))throw new SourceError('mock.validation.protocol','The native body projection is malformed');
        const source=sourceLocation(value.source);if(!source)throw new SourceError('mock.validation.protocol','The native body projection omitted its source');
        const content=nativeMedia(value.content,operation.occurrence);
        return {required:value.required,source,content};
    }

    private plan(path:string,method:string) {
        const key=JSON.stringify([path,method]);
        const cached=this.plans.get(key);if(cached)return cached;
        const operation=this.operations.get(key);
        if(!operation)throw new SourceError('mock.operation.owner','The selected mock route has no captured native owner');
        const description=requestOperation({...this.capture,resource:operation.source.resource,pointer:operation.source.pointer,occurrence:operation.occurrence},this.context);
        const plan={operation,description,body:this.declaration(description.requestBody,operation)};
        if(this.plans.size>=128)this.plans.clear();
        this.plans.set(key,plan);return plan;
    }

    qualify(operations:readonly {path:string;method:string}[]):void {
        const covered=new Set(operations.map(operation=>JSON.stringify([operation.path,operation.method])));
        for(const [key,operation]of this.operations)if(!covered.has(key)||mockWireMethod(operation).length>maximumMockMethodBytes||operation.customMethod&&operation.method==='CONNECT') {
            const source=operation.source,node=this.context.docs.get(source.resource)!.dataNode(source.pointer)!;
            const limit=mockWireMethod(operation).length>maximumMockMethodBytes;
            const tunnel=operation.customMethod&&operation.method==='CONNECT';
            throw new SourceError(tunnel?'mock.method.tunnel':limit?'mock.method.limit':'mock.operation.unsupported',
                tunnel?'CONNECT requires a tunnel-capable transport; this mock returns ordinary HTTP responses':
                limit?'The declared method exceeds the mock HTTP parser\'s 16 KiB method budget':'The derived mock routes omit this captured operation',
                node.range,'unsupported',{...source,range:node.range});
        }
    }

    async body(path:string,method:string,bytes:Buffer,contentType:string|undefined,present:boolean,signal:AbortSignal):Promise<NativeMockCheck> {
        const {operation,body:declaration}=this.plan(path,method);
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
        const media=selectNativeMedia(declaration.content,actual);
        if(!media)return invalid('runtime.request.content-type','The request Content-Type does not match the captured operation');
        const {schema,itemSchema}=media;
        const form=['application/x-www-form-urlencoded','multipart/form-data'].includes(parsed[0].type+'/'+parsed[0].subtype)?media.formOwner:undefined;
        if(!schema&&!itemSchema&&!form&&runtimeMediaKind(actual)==='opaque')return {complete:true,valid:true,findings:[]};
        return this.evaluate(bytes,actual,signal,schema,itemSchema,form);
    }

    isAdditional(path:string,method:string):boolean {
        return this.plan(path,method).operation.customMethod===true;
    }

    async response(path:string,method:string,status:number,headers:unknown,bytes:Buffer,signal:AbortSignal):Promise<NativeMockCheck> {
        const {description}=this.plan(path,method);
        return validateMockResponse(this.context.graph,description,description.operation.method,status,headers,bytes,instances=>this.evaluateInstances(instances,signal));
    }

    generatedResponse(path:string,method:string,status:string,actual:string,dynamic:boolean,signal:AbortSignal):Promise<string|undefined> {
        return this.samples.response(this.plan(path,method).description,status,actual,dynamic,signal);
    }

    generationFailure(path:string,method:string,code:string,message:string):SourceError {
        const source=this.operationSource(path,method);
        return new SourceError(code,message,source.range,'unsupported',source);
    }

    operationSource(path:string,method:string):SourceLocation {
        const {operation}=this.plan(path,method),source=operation.source;
        const range=this.context.docs.get(source.resource)!.dataNode(source.pointer)!.range;
        return {resource:source.resource,pointer:source.pointer,range};
    }

    async parameters(template:string,method:string,path:string,query:string,headers:Readonly<Record<string,string>>,signal:AbortSignal):Promise<NativeMockCheck> {
        const {description}=this.plan(template,method);
        return validateMockParameters(this.context.graph,description,template,path,query,headers,instances=>this.evaluateInstances(instances,signal));
    }

    security(template:string,method:string,query:string,rawHeaders:readonly string[],signal:AbortSignal):NativeMockCheck {
        const {description}=this.plan(template,method);
        const checked=validateMockSecurity(description.security,query,rawHeaders,signal);
        return {...checked,findings:checked.findings.map(finding=>({...finding,
            producer:mockSecurityProducer.name,producerVersion:mockSecurityProducer.version,
            source:record(finding.source)?{...finding.source,snapshot:this.capture.snapshot}:finding.source,
            ...(record(finding.definition)?{definition:{...finding.definition,snapshot:this.capture.snapshot}}:{}),
        }))};
    }

    private async evaluate(bytes:Buffer,actual:string,signal:AbortSignal,schema?:SchemaLocation,itemSchema?:SchemaLocation,form?:RuntimeFormTarget):Promise<NativeMockCheck> {
        return this.evaluateInstances([{
            subject:'request-body',location:actual,text:bytes.toString('base64'),mediaType:actual,mediaBase64:true,
            ...(schema?{schema}:{}),...(itemSchema?{itemSchema}:{}),...(form?{form}:{})}],signal);
    }

    private async evaluateInstances(runtimeInstances:NativeRuntimeInstance[],signal:AbortSignal):Promise<NativeRuntimeCheck> {
        const result=await this.client.request('evaluateSchemas',{...this.capture,runtimeInstances},signal);
        if(result.snapshot!==this.capture.snapshot||result.producer!==this.producer?.name||result.producerVersion!==this.producer?.version||result.configuration!==this.producer?.configuration||typeof result.complete!=='boolean'||!Array.isArray(result.runtimeEvaluations)||!Array.isArray(result.runtimeFindings))
            throw new SourceError('mock.validation.protocol','Native validation returned an unrelated runtime result');
        const evaluations:NativeRuntimeEvaluation[]=[],findings:Record<string,unknown>[]=[];
        for(const value of result.runtimeFindings){if(!record(value)||typeof value.code!=='string'||typeof value.message!=='string')throw new SourceError('mock.validation.protocol','Native validation returned a malformed finding');findings.push(value);}
        for(const value of result.runtimeEvaluations){
            if(!record(value)||typeof value.complete!=='boolean'||typeof value.valid!=='boolean'||typeof value.subject!=='string'||typeof value.location!=='string')throw new SourceError('mock.validation.protocol','Native validation returned a malformed evaluation');
            if(value.chosen!==undefined&&(typeof value.chosen!=='number'||!Number.isSafeInteger(value.chosen)||value.chosen<0||value.chosen>255))
                throw new SourceError('mock.validation.protocol','Native validation returned an invalid selected-candidate index');
            evaluations.push({subject:value.subject,location:value.location,complete:value.complete,valid:value.valid,
                ...(typeof value.chosen==='number'?{chosen:value.chosen}:{})});
        }
        const complete=result.complete&&evaluations.length>0&&evaluations.every(value=>value.complete===true);
        return {complete,valid:complete&&evaluations.every(value=>value.valid===true),findings,evaluations};
    }

    close(){return this.client.close();}
}
