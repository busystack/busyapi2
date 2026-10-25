import {SourceError,escape,segments} from './document';
import {record} from './engine_worker_client';
import {headerShapes} from './header_serialization';
import {isNativeFamily} from './specification';
import {runtimeMediaKind,runtimeFormMedia} from './runtime_media';
import {nativeMedia,schemaLocation,type NativeRuntimeInstance} from './mock_projection';
import {headerValueParts} from './header_values';
import {supportedSchemaDialect,type ReferenceGraph,type GraphTarget} from './reference_graph';
import {annotationOnlySchema} from './schema_boundaries';
import {headerWireValues} from './header_wire_values';

export type RuntimeHeaderTarget={resource:string;pointer:string;name:string;values:string[]};
type DecodedHeader={instance:NativeRuntimeInstance;complete:boolean};

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
    return (target:RuntimeHeaderTarget):DecodedHeader|undefined=>{
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
function decodeRuntimeHeader(shapeFor:ReturnType<typeof headerShapes>,declaration:unknown,values:readonly string[]):DecodedHeader|undefined {
    if(!record(declaration)||typeof declaration.name!=='string'||typeof declaration.family!=='string'||!isNativeFamily(declaration.family))
        throw new SourceError('mock.validation.protocol','The native header projection is malformed');
    const name=declaration.name,family=declaration.family,cookie=name.toLowerCase()==='set-cookie';
    const content=nativeMedia(declaration.content);
    if(content.length){
        if(content.length!==1)unsupported('A header has more than one content representation');
        if(values.length!==1&&(!cookie||family!=='3.2'))unsupported('A content-based header has multiple wire values');
        const media=content[0];
        if(!media.schema&&!media.itemSchema&&runtimeMediaKind(media.mediaType)==='opaque')return;
        return {complete:true,instance:{subject:'response-header',location:name,text:values.join('\n'),mediaType:media.mediaType,schema:media.schema,itemSchema:media.itemSchema,
            ...(runtimeFormMedia(media.mediaType)&&media.formOwner?{form:media.formOwner}:{})}};
    }
    const schema=schemaLocation(declaration.schema);
    if(!schema||record(declaration.schema)&&declaration.schema.unconstrained===true)return;
    if(family==='2.0'){
        return {complete:true,instance:{subject:'response-header',location:name,text:values.join(','),schema,swaggerHeader:{...schema,name,values:[...values]}}};
    }
    const shape=shapeFor({...schema,kind:'schema'});
    if(!shape||declaration.style!=='simple')unsupported('The declared header has no unambiguous simple representation');
    const decoded=headerWireValues(shape,values,{cookie,multiline:family==='3.2',explode:declaration.explode===true});
    return {complete:decoded.complete,instance:{subject:'response-header',location:name,text:decoded.texts[0],schema,
        ...(decoded.texts.length>1?{alternatives:decoded.texts.slice(1)}:{})}};
}
