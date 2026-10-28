import {SourceError} from './document';
import {record} from './engine_worker_client';
import {FormSemantics,type FormShape} from './form_semantics';
import type {ReferenceGraph} from './reference_graph';
import {runtimeMediaKind,runtimeFormMedia} from './runtime_media';
import {nativeHeaderParts} from './runtime_headers';
import {swaggerWireShape,swaggerWireValues,type SwaggerWireShape} from './swagger_wire';
import {nativeMedia,schemaLocation,sourceLocation,type NativeMockCheck,type NativeRuntimeCheck,type NativeRuntimeInstance,type SourceLocation} from './mock_projection';

type Pair=readonly [string,string];
type Parameter={name:string;in:string;style:string;explode:boolean;required:boolean;allowEmptyValue:boolean;family:string;source:SourceLocation;schema?:{resource:string;pointer:string};content:ReturnType<typeof nativeMedia>;shape:FormShape;swagger?:SwaggerWireShape};
type Candidates={present:boolean;texts:string[]};
export type ParameterOmission={source:SourceLocation;location:string;collections:readonly string[]};
type Evaluate=(instances:NativeRuntimeInstance[])=>Promise<NativeRuntimeCheck>;
const maximumCandidates=256,maximumInstances=2048;
const decimal=/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/;
const unsupported=(message:string):never=>{throw new SourceError('runtime.request.parameter.unchecked',message,[0,0],'unsupported');};
const malformed=(message:string):never=>{throw new SourceError('runtime.request.parameter.serialization',message);};
export const mockParameterProducer=Object.freeze({name:'busyapi-native-parameters',version:'3'});

function decode(value:string,form=false):string {
    try{return decodeURIComponent(form?value.replace(/\+/g,' '):value);}
    catch{return malformed('A parameter contains malformed percent-encoding or UTF-8');}
}
function pairs(text:string,delimiter:string,encoded:boolean,form=false):Pair[] {
    if(text==='')return [];
    const parts=text.split(delimiter);
    if(parts.length>maximumInstances)unsupported('The parameter representation exceeds 2048 fields');
    return parts.map(part=>{
        const equals=part.indexOf('='),name=equals<0?part:part.slice(0,equals),value=equals<0?'':part.slice(equals+1);
        return [encoded?decode(name,form):name,encoded?decode(value,form):value];
    });
}

/** OAS 3.0 Appendix B leaves primitive conversion implementation-defined.
 * Invert BusyAPI's string, exact JSON decimal, lower-case boolean and literal
 * null conversions. The canonical evaluator, never a machine-number cast,
 * proves which interpretations satisfy the original captured schema. */
function scalars(text:string,shape?:FormShape):string[] {
    const allowed=(type:string)=>!shape?.types||shape.types.includes(type);
    return [...(allowed('string')?[JSON.stringify(text)]:[]),...(decimal.test(text)&&(allowed('integer')||allowed('number'))?[text]:[]),
        ...((text==='true'||text==='false')&&allowed('boolean')||text==='null'?[text]:[])];
}
function product(fields:readonly string[][]):string[][] {
    let result:string[][]=[[]];
    for(const field of fields){
        if(result.length*field.length>maximumCandidates)unsupported('Parameter inversion exceeds 256 possible data values');
        result=result.flatMap(prefix=>field.map(value=>[...prefix,value]));
    }
    return result;
}
function labelPartitions(parts:readonly string[]):string[][] {
    if(parts.length>9)unsupported('Label inversion exceeds 256 possible delimiter boundaries');
    let result:string[][]=[[]];
    for(const part of parts){
        result=result.flatMap(prefix=>prefix.length?[[...prefix,part],[...prefix.slice(0,-1),prefix.at(-1)+'.'+part]]:[[part]]);
    }
    return result;
}
function primitive(shape?:FormShape):void {
    if(shape?.types?.length&&shape.types.every(type=>type==='array'||type==='object'))
        unsupported('Nested array or object parameter values have no defined scalar style representation');
}
function arrays(parts:readonly string[],shape?:FormShape):string[] {
    primitive(shape?.items);
    return [...(parts.length===1&&parts[0]===''?['[]']:[]),...product(parts.map(part=>scalars(part,shape?.items))).map(values=>'['+values.join(',')+']')];
}
function objects(fields:readonly Pair[],shape?:FormShape):string[] {
    if(new Set(fields.map(([name])=>name)).size!==fields.length)unsupported('An object parameter repeats a property name');
    return product(fields.map(([name,value])=>{
        const property=Object.hasOwn(shape?.properties??{},name)?shape!.properties![name]:undefined;
        primitive(property);return scalars(value,property);
    })).map(values=>'{'+fields.map(([name],index)=>JSON.stringify(name)+':'+values[index]).join(',')+'}');
}
function pathValues(template:string,path:string):Map<string,string> {
    const expressions=[...template.matchAll(/\{([^{}]+)\}/gu)];
    let pattern='^',position=0;
    for(const expression of expressions){
        if(position===expression.index&&position>0)unsupported('Adjacent path expressions have no unambiguous wire boundary');
        pattern+=template.slice(position,expression.index).replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'([^/]*?)';
        position=expression.index!+expression[0].length;
    }
    pattern+=template.slice(position).replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'$';
    const match=new RegExp(pattern,'u').exec(path);
    if(!match)malformed('The actual path does not match the captured template');
    const result=new Map<string,string>();
    expressions.forEach((expression,index)=>{
        const previous=result.get(expression[1]);
        if(previous!==undefined&&previous!==match![index+1])malformed('Repeated path expressions have different values');
        result.set(expression[1],match![index+1]);
    });
    return result;
}

function data(parameter:Parameter,values:readonly string[],raw:boolean,fields:readonly Pair[],reserved:ReadonlySet<string>):Candidates {
    const {in:location,name,style,explode,shape}=parameter;
    if(location==='cookie'&&style==='form'&&!explode&&raw&&values.some(value=>value.includes(',')))
        malformed('A non-exploded form cookie has a comma excluded by RFC6265 cookie-octet syntax');
    if(parameter.swagger)return values.length?{present:true,texts:swaggerWireValues(values,parameter.swagger,{...(raw?{decode:(text:string)=>decode(text,location==='query'),plus:location==='query'}:{}),...(location==='header'?{commas:nativeHeaderParts}:{})})}:{present:false,texts:[]};
    const types=shape.types,possible=(type:string)=>!types||types.includes(type),texts:string[]=[];
    const convert=(text:string)=>raw?decode(text,location==='query'):text;
    const add=(values:readonly string[])=>{texts.push(...values);if(texts.length>maximumCandidates)unsupported('Parameter inversion exceeds 256 possible data values');};
    let parts:string[]|undefined,object:Pair[]|undefined,present=values.length>0;
    if(style==='deepObject'){
        object=fields.filter(([key])=>key.startsWith(name+'[')).map(([key,value])=>{
            const member=key.slice(name.length+1,-1);
            if(!key.endsWith(']')||/[\[\]]/u.test(member))unsupported('Nested deepObject arrays and objects have no defined OpenAPI serialization');
            return [member,value];
        });
        present=object.length>0;
    }else if((location==='query'||location==='cookie')&&explode&&possible('object')&&(style==='form'||style==='cookie')){
        object=fields.filter(([key])=>Object.hasOwn(shape.properties??{},key)||!reserved.has(key));
        present=present||object.length>0;
    }
    // RFC 6570 §2.3 / OAS 3.2 Appendix C.4.3 omit empty collections.
    // Retain finite inverse witnesses for authored examples. An actual absent
    // HTTP parameter still has no instance and does not apply its schema.
    if(!present)return {present:false,texts:
        location==='query'&&style==='deepObject'&&possible('object')?['{}']:
        (location==='query'||location==='cookie')&&explode&&(style==='form'||location==='cookie'&&parameter.family==='3.2'&&style==='cookie')?
            [...(possible('array')?['[]']:[]),...(possible('object')?['{}']:[])]:[]};
    if(style==='deepObject')return {present:true,texts:objects(object!,shape)};
    if(location==='path'&&style==='matrix'){
        if(values.length!==1||!values[0].startsWith(';'))malformed('A matrix path parameter must start with a semicolon');
        const matrix=pairs(values[0].slice(1),';',false),named=matrix.filter(([key])=>decode(key)===name).map(([,value])=>value);
        if(explode){
            if(possible('object'))add(objects(matrix.map(([key,value])=>[decode(key),decode(value)]),shape));
            if(possible('array')&&named.length===matrix.length)add(arrays(named.map(convert),shape));
        }else if(named.length===1&&matrix.length===1)parts=named[0].split(',');
        if(named.length===1)add(scalars(convert(named[0]),shape));
        if(!explode&&parts&&possible('array'))add(arrays(parts.map(convert),shape));
    }else{
        if(values.length===1){
            let value=values[0];
            if(location==='path'&&style==='label'){
                if(!value.startsWith('.'))malformed('A label path parameter must start with a period');
                value=value.slice(1);
            }
            add(scalars(convert(value),shape));
            const delimiter=style==='spaceDelimited'?' ':style==='pipeDelimited'?'|':style==='label'&&explode?'.':',';
            const separator=raw&&location==='query'&&delimiter===' '?/(?:%20|\+| )/iu:
                raw&&location==='query'&&delimiter==='|'?/(?:%7c|\|)/iu:delimiter;
            if(separator!==undefined)parts=location==='header'&&delimiter===','?nativeHeaderParts(value):value.split(separator);
        }
        if(possible('array')){
            if((location==='query'||location==='cookie')&&explode&&(style==='form'||style==='cookie'))add(arrays(values.map(convert),shape));
            else if(parts){
                for(const layout of style==='label'&&explode?labelPartitions(parts):[parts])add(arrays(layout.map(convert),shape));
            }
        }
    }
    if(possible('object')){
        if(object)add(objects(object,shape));
        else if(parts){
            for(const layout of style==='label'&&explode?labelPartitions(parts):[parts]){
                let entries:Pair[]=[];
                if(explode&&layout.every(part=>part.includes('=')))entries=layout.map(part=>{const equals=part.indexOf('=');return [convert(part.slice(0,equals)),convert(part.slice(equals+1))];});
                else if(!explode&&layout.length%2===0)for(let index=0;index<layout.length;index+=2)entries.push([convert(layout[index]),convert(layout[index+1])]);
                if(entries.length||layout.length===1&&layout[0]==='')add(objects(entries,shape));
            }
        }
    }
    if(!texts.length)malformed('The parameter does not have a supported representation for its declared style');
    return {present:true,texts:[...new Set(texts)]};
}

/** Decode wire parameters using graph-owned effective definitions, including
 * inheritance and references. These codecs never resolve or evaluate schemas. */
export async function validateMockParameters(graph:ReferenceGraph,plan:unknown,template:string,path:string,query:string,headers:Readonly<Record<string,string>>,evaluate:Evaluate,parameterShapes?:FormSemantics,onOmission?:(omission:ParameterOmission)=>void):Promise<NativeMockCheck> {
    if(!record(plan)||!Array.isArray(plan.parameters)||plan.parameters.length>maximumInstances)throw new SourceError('mock.validation.protocol','The native parameter projection is malformed');
    const shapes=parameterShapes??new FormSemantics(graph);
    const parameters:Parameter[]=plan.parameters.map(value=>{
        if(!record(value)||typeof value.name!=='string'||typeof value.in!=='string'||typeof value.style!=='string'||typeof value.explode!=='boolean'||typeof value.required!=='boolean'||typeof value.family!=='string')throw new SourceError('mock.validation.protocol','A native parameter is malformed');
        const source=sourceLocation(value.definition)??sourceLocation(value.source),schema=schemaLocation(value.schema);
        if(!source)throw new SourceError('mock.validation.protocol','A native parameter omitted its source');
        return {name:value.name,in:value.in,style:value.style,explode:value.explode,required:value.required,allowEmptyValue:value.allowEmptyValue===true,family:value.family,source,schema,content:nativeMedia(value.content),shape:schema?shapes.shape(schema.resource,schema.pointer):{},...(value.family==='2.0'?{swagger:swaggerWireShape(value)}:{})};
    });
    const findings:Record<string,unknown>[]=[],instances:NativeRuntimeInstance[]=[],sources=new Map<string,SourceLocation>();
    let complete=true,candidates=0,queryFields:Pair[]|undefined,pathFields:Map<string,string>|undefined;
    const issue=(parameter:Parameter,code:string,message:string,incomplete=false)=>{
        if(incomplete)complete=false;
        findings.push({code,message,subject:'request-parameter',location:parameter.in+':'+parameter.name,pointer:'',source:parameter.source,severity:incomplete?'warning':'error',...(incomplete?{kind:'unsupported'}:{})});
    };
    for(const parameter of parameters){
        if(parameter.in==='header'&&parameter.family!=='2.0'&&['accept','content-type','authorization'].includes(parameter.name.toLowerCase()))continue;
        try{
            if(parameter.name.length>3900)unsupported('The parameter name exceeds the bounded runtime attribution size');
            let values:string[]=[],fields:Pair[]=[],raw=false;
            if(parameter.in==='query'||parameter.in==='querystring'){
                queryFields??=pairs(query,'&',false).map(([name,value])=>[decode(name,true),value]);
                fields=queryFields.map(([name,value])=>[name,decode(value,true)]);
                values=parameter.in==='querystring'?(query===''?[]:[query]):queryFields.filter(([name])=>name===parameter.name).map(([,value])=>value);
                raw=true;
            }else if(parameter.in==='path'){
                pathFields??=pathValues(template,path);const value=pathFields.get(parameter.name);values=value===undefined?[]:[value];raw=true;
            }else if(parameter.in==='header'){
                const name=parameter.name.toLowerCase(),value=Object.hasOwn(headers,name)?headers[name]:undefined;values=value===undefined?[]:[value];
            }else if(parameter.in==='cookie'){
                const cookie=parameter.style==='cookie';
                const segments=pairs(headers.cookie??'',';',false).map(([name,value])=>[name.trim(),value] as Pair);
                // Split RFC6570 delimiters before percent-decoding data. In
                // particular %2C inside one item cannot become a list comma.
                const rawFields=cookie?segments:segments.flatMap(([name,value])=>pairs(name+'='+value,'&',false)).map(([name,value])=>[decode(name),value] as Pair);
                fields=cookie?rawFields:rawFields.map(([name,value])=>[name,decode(value)]);
                values=rawFields.filter(([name])=>name===parameter.name).map(([,value])=>value);
                raw=!cookie;
            }else unsupported('The parameter location has no native mock codec');
            if(parameter.family==='2.0'&&parameter.in==='query'&&!parameter.allowEmptyValue&&values.includes(''))malformed('An empty Swagger query value requires allowEmptyValue: true');
            const location=parameter.in+':'+parameter.name,reserved=new Set(parameters.filter(other=>other.in===parameter.in).map(other=>other.name));
            let texts:string[],mediaType:string|undefined;
            if(parameter.content.length){
                if(!values.length){if(parameter.required)issue(parameter,'runtime.request.parameter.required','A required parameter is absent');continue;}
                if(parameter.content.length!==1||values.length!==1)unsupported('A content-based parameter needs one media type and one wire value');
                const media=parameter.content[0];
                if(!media.schema&&!media.itemSchema&&runtimeMediaKind(media.mediaType)==='opaque')continue;
                mediaType=media.mediaType;
                const form=parameter.in==='querystring'&&mediaType.split(';')[0].trim().toLowerCase()==='application/x-www-form-urlencoded';
                texts=[raw&&!form?decode(values[0],parameter.in==='query'):values[0]];
            }else{
                const decoded=data(parameter,values,raw,fields,reserved);
                if(!decoded.present){
                    if(parameter.required)issue(parameter,'runtime.request.parameter.required','A required parameter is absent');
                    else onOmission?.({source:parameter.source,location,collections:decoded.texts});
                    continue;
                }
                texts=decoded.texts;
            }
            if(candidates+texts.length>maximumInstances)unsupported('Native parameter validation exceeds 2048 captured instances');
            candidates+=texts.length;
            const media=parameter.content[0],form=mediaType&&runtimeFormMedia(mediaType)?media?.formOwner:undefined;
            instances.push({subject:'request-parameter',location,text:texts[0],schema:media?.schema??parameter.schema,...(texts.length>1?{alternatives:texts.slice(1)}:{}),...(mediaType?{mediaType,itemSchema:media?.itemSchema}:{}),...(form?{form}:{})});
            sources.set(location,parameter.source);
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue(parameter,error.code==='runtime.response.header.serialization'?'runtime.request.parameter.serialization':error.code,error.message,error.kind==='unsupported'||error.code.startsWith('limit.'));
        }
    }
    if(instances.length){
        const result=await evaluate(instances);
        if(!result.complete)complete=false;
        if(!result.valid&&result.complete&&!result.findings.some(value=>value.severity==='error'))throw new SourceError('mock.validation.protocol','Invalid native parameter evaluation omitted its findings');
        findings.push(...result.findings.map(finding=>({...finding,...(sources.has(String(finding.location))?{source:sources.get(String(finding.location))}:{})})));
        if(!result.complete&&!findings.some(finding=>finding.severity==='warning')){
            const source=sourceLocation(record(plan.operation)?plan.operation.source:undefined);
            findings.push({code:'runtime.request.parameter.unchecked',message:'The bounded native parameter evaluation did not complete',subject:'request-parameter',location:'parameters',pointer:'',...(source?{source}:{}),severity:'warning',kind:'unsupported'});
        }
    }
    return {complete,valid:complete&&!findings.some(finding=>finding.severity==='error'),findings};
}
