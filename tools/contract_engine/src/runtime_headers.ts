import {SourceError,escape,segments} from './document';
import {record} from './engine_worker_client';
import {headerShapes,type HeaderShape} from './header_serialization';
import {isNativeFamily} from './specification';
import {runtimeMediaKind} from './runtime_media';
import {nativeMedia,schemaLocation,type NativeRuntimeInstance} from './mock_projection';
import {headerValueParts} from './header_values';
import {supportedSchemaDialect,type ReferenceGraph,type GraphTarget} from './reference_graph';
import {annotationOnlySchema} from './schema_boundaries';

export type RuntimeHeaderTarget={resource:string;pointer:string;name:string;values:string[]};

/** Raw field lines refer to the original response-header occurrence. A caller
 * cannot supply a family, schema, style or replacement resolved declaration. */
export function capturedRuntimeHeaders(graph:ReferenceGraph) {
    const edges=new Map(graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge]));
    const shapeFor=headerShapes(graph),projections=new Map<string,Record<string,unknown>>();
    const follow=(target:GraphTarget)=>{
        let {resource,pointer}=target;const seen=new Set<string>();
        for(let depth=0;depth<128;depth++){
            const key=JSON.stringify([resource,pointer]);
            if(seen.has(key))unsupported('A captured header declaration contains a reference cycle');
            seen.add(key);
            const node=graph.docs.get(resource)?.dataNode(pointer);
            if(!node||!record(node.value))throw new SourceError('runtime.instance','The captured header declaration is unavailable');
            if(typeof node.value.$ref!=='string')return {resource,pointer,node};
            const edge=edges.get(JSON.stringify([resource,pointer,'$ref']));
            if(edge?.kind!==target.kind||edge.resolution!=='resolved')unsupported('A captured header declaration has an unresolved reference');
            resource=edge.targetResource!;pointer=edge.targetPointer!;
        }
        unsupported('The captured header reference chain exceeds 128 declarations');
    };
    const schema=(resource:string,pointer:string)=>{
        const node=graph.docs.get(resource)?.dataNode(pointer);
        if(!node)return;
        return {resource,pointer,unconstrained:supportedSchemaDialect(graph.scope(resource,pointer))&&annotationOnlySchema(node.value)};
    };
    return (target:RuntimeHeaderTarget):NativeRuntimeInstance|undefined=>{
        const owner=graph.scopes.get(target.resource+'#'+target.pointer),parts=segments(target.pointer);
        const parent=target.pointer.slice(0,target.pointer.lastIndexOf('/headers/'));
        if(owner?.kind!=='header'||parts.at(-1)!==target.name||graph.scopes.get(target.resource+'#'+parent)?.kind!=='response')
            throw new SourceError('runtime.instance','Header wire evaluation requires its original response-header occurrence and field name');
        const identity=JSON.stringify([target.resource,target.pointer]);
        let projection=projections.get(identity);
        if(!projection){
            const header=follow({resource:target.resource,pointer:target.pointer,kind:'header'}),value=header.node.value;
            const content:Record<string,unknown>[]=[],media=header.node.children.get('content');
            if(media){
                if(media.kind!=='object')throw new SourceError('runtime.instance','The captured Header content is not a map');
                for(const [name]of media.children){
                    if(name.startsWith('x-'))continue;
                    if(content.length>=2048)unsupported('The captured header has more than 2048 media declarations');
                    const selected=follow({resource:header.resource,pointer:header.pointer+'/content/'+escape(name),kind:'media'});
                    const family=graph.scope(selected.resource,selected.pointer).family;
                    content.push({mediaType:name,definition:{resource:selected.resource,pointer:selected.pointer},schema:schema(selected.resource,selected.pointer+'/schema'),
                        ...(family==='3.2'&&selected.node.children.has('itemSchema')?{itemSchema:{resource:selected.resource,pointer:selected.pointer+'/itemSchema'}}:{})});
                }
            }
            projection={name:target.name,family:owner.family,style:value.style??'simple',explode:value.explode===true,content,
                schema:schema(header.resource,owner.family==='2.0'?header.pointer:header.pointer+'/schema')};
            projections.set(identity,projection);
        }
        return decodeRuntimeHeader(shapeFor,projection,target.values);
    };
}

const decimal=/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/;
const unsupported=(message:string):never=>{throw new SourceError('runtime.response.header.unchecked',message,[0,0],'unsupported');};
const malformed=(message:string):never=>{throw new SourceError('runtime.response.header.serialization',message);};

export function nativeHeaderParts(text:string):string[] {
    try{return headerValueParts(text);}
    catch(error){if(error instanceof SourceError)return malformed(error.message);throw error;}
}

/** Reconstruct header data for the canonical evaluator. Decimal tokens never
 * become JavaScript numbers. This transport codec does not evaluate schemas.
 * Header Objects use simple style; Swagger Header/Items use collectionFormat.
 * OAS 3.2 §4.21.3 keeps each Set-Cookie line separate, including its commas. */
export function decodeRuntimeHeader(shapeFor:ReturnType<typeof headerShapes>,declaration:unknown,values:readonly string[]):NativeRuntimeInstance|undefined {
    if(!record(declaration)||typeof declaration.name!=='string'||typeof declaration.family!=='string'||!isNativeFamily(declaration.family))
        throw new SourceError('mock.validation.protocol','The native header projection is malformed');
    const name=declaration.name,family=declaration.family,cookie=name.toLowerCase()==='set-cookie';
    const content=nativeMedia(declaration.content);
    if(content.length){
        if(content.length!==1)unsupported('A header has more than one content representation');
        if(values.length!==1&&(!cookie||family!=='3.2'))unsupported('A content-based header has multiple wire values');
        const media=content[0];
        if(!media.schema&&!media.itemSchema&&runtimeMediaKind(media.mediaType)==='opaque')return;
        return {subject:'response-header',location:name,text:values.join('\n'),mediaType:media.mediaType,schema:media.schema,itemSchema:media.itemSchema,
            ...(['application/x-www-form-urlencoded','multipart/form-data'].includes(media.mediaType.split(';')[0].trim().toLowerCase())&&media.formOwner?{form:media.formOwner}:{})};
    }
    const schema=schemaLocation(declaration.schema);
    if(!schema||record(declaration.schema)&&declaration.schema.unconstrained===true)return;
    if(family==='2.0'){
        return {subject:'response-header',location:name,text:values.join(','),schema,swaggerHeader:{...schema,name,values:[...values]}};
    }
    const shape=shapeFor({...schema,kind:'schema'});
    if(!shape||declaration.style!=='simple')unsupported('The declared header has no unambiguous simple representation');
    // A supported false schema rejects every instance. Its proof needs no
    // invented primitive/collection inversion of the raw field representation.
    if(shape.type==='never')return {subject:'response-header',location:name,text:JSON.stringify(values),schema};
    if(cookie&&family!=='3.2'&&(values.length>1||shape.type==='array'||shape.type==='object'))
        unsupported('This Set-Cookie representation requires the OpenAPI 3.2 multiline rules');
    const scalar=(text:string,shape:HeaderShape|undefined):string=>{
        if(shape?.type==='string')return JSON.stringify(text);
        if(shape?.type==='integer'||shape?.type==='number')return decimal.test(text.trim())?text.trim():malformed('A numeric header value is not a JSON decimal');
        if(shape?.type==='boolean')return text.trim()==='true'||text.trim()==='false'?text.trim():malformed('A boolean header value must be true or false');
        return unsupported('A nested or unknown header value has no unambiguous scalar representation');
    };
    let text:string;
    if(shape.type!=='array'&&shape.type!=='object'){
        if(values.length!==1)unsupported('A scalar header occurs more than once');
        text=scalar(values[0],shape);
    }else{
        const parts=cookie?[...values]:nativeHeaderParts(values.join(','));
        if(shape.type==='array'){
            if(cookie)unsupported('Set-Cookie values are separate cookie fields rather than comma-separated array items');
            if(parts.length===1&&parts[0]==='')unsupported('An empty array and one empty item share this wire representation');
            text='['+parts.map(part=>scalar(part,shape.items)).join(',')+']';
        }else{
            const fields=new Map<string,string>();
            const add=(key:string,value:string)=>{
                if(fields.has(key))unsupported('A header object repeats a member');
                fields.set(key,scalar(value,shape.properties&&Object.hasOwn(shape.properties,key)?shape.properties[key]:shape.additionalProperties));
            };
            if(declaration.explode===true){
                for(const part of parts){const equals=part.indexOf('=');if(equals<0)malformed('A header object member has no equals delimiter');add(part.slice(0,equals),part.slice(equals+1));}
            }else{
                if(cookie)unsupported('A Set-Cookie object requires exploded key/value fields');
                if(parts.length%2!==0)malformed('A header object has an unmatched name/value');
                for(let index=0;index<parts.length;index+=2)add(parts[index],parts[index+1]);
            }
            text='{'+[...fields].map(([key,value])=>JSON.stringify(key)+':'+value).join(',')+'}';
        }
    }
    return {subject:'response-header',location:name,text,schema};
}
