import {segments,escape,SourceError} from './document';
import {mediaTypes} from './media_types';
import {FormSemantics,formContentType} from './form_semantics';
import {runtimeMediaKind} from './runtime_media';
import {runtimeBinaryMedia} from './runtime_binary';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import type {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {modernFamily} from './specification';

type Use=Readonly<{kind:'body'|'part'|'data';mediaType?:string;source:GraphScope;schema:GraphScope;path:readonly Step[]}>;
type Step=Readonly<{property:string}>|'item'|'nested';
type Visit=Readonly<{scope:GraphScope;path:readonly Step[]}>;
const identity=(scope:Pick<GraphScope,'resource'|'pointer'>)=>JSON.stringify([scope.resource,scope.pointer]);

/** Occurrence context comes from the canonical graph, not the schema's file
 * name or its reusable component name. A reference preserves the instance path;
 * properties/items change it. No resource acquisition occurs in this proof. */
class BinaryUses {
    private readonly incoming=new Map<string,GraphScope[]>();
    private readonly forms:FormSemantics;
    constructor(private readonly graph:ReferenceGraph){
        this.forms=new FormSemantics(graph);
        for(const edge of graph.references){
            if(edge.kind!=='schema'||edge.connection||edge.keyword!=='$ref'||edge.resolution!=='resolved')continue;
            const scope=graph.scopeAs(edge.resource,edge.pointer,'schema');
            if(!scope)continue;
            const key=identity({resource:edge.targetResource!,pointer:edge.targetPointer!});
            const scopes=this.incoming.get(key)??[];
            scopes.push(scope);this.incoming.set(key,scopes);
        }
    }
    rawCompatible(use:Use,family:string):boolean {
        const seen=new Set<string>();
        const visit=(scope:GraphScope,path:readonly Step[],depth=0):boolean=>{
            if(depth>=128)throw new SourceError('limit.migration.binary','Raw-schema assertion inspection exceeds 128 reference/applicator levels');
            const key=JSON.stringify([scope.resource,scope.pointer,path]);
            if(seen.has(key))return true;
            if(seen.size>=2048)throw new SourceError('limit.migration.binary','Raw-schema assertion inspection exceeds 2048 occurrences');
            seen.add(key);
            const value=this.graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
            if(value===true)return true;
            if(value===false)return true;
            if(value===null||typeof value!=='object'||Array.isArray(value))return false;
            const child=(pointer:string,steps=path)=>{
                const at=this.graph.scopeAs(scope.resource,pointer,'schema');
                return at!==undefined&&visit(at,steps,depth+1);
            };
            if(typeof value.$ref==='string'){
                const edge=this.graph.referenceAs(scope.resource,scope.pointer,'$ref','schema');
                const target=edge?.resolution==='resolved'&&this.graph.scopeAs(edge.targetResource!,edge.targetPointer!,'schema');
                return !!target&&visit(target,path,depth+1);
            }
            if(path.length){
                // Container enums compare literal JSON data, whose embedded
                // octet strings are not modern raw leaves. They need a separate
                // whole-instance mapping rather than a leaf annotation edit.
                if(Object.hasOwn(value,'enum')||Object.hasOwn(value,'const'))return false;
            }else{
                const allowed=Object.keys(value).every(name=>annotation(name)||['type','format','allOf','anyOf','oneOf','not'].includes(name));
                if(!allowed)return false;
                if(Object.hasOwn(value,'type')&&!(scope.family===family&&value.type==='string'&&value.format==='binary'))return false;
            }
            for(const keyword of ['allOf','anyOf','oneOf'])if(Array.isArray(value[keyword]))
                for(let index=0;index<value[keyword].length;index++)if(!child(scope.pointer+'/'+keyword+'/'+index))return false;
            if(Object.hasOwn(value,'not')&&!child(scope.pointer+'/not'))return false;
            if(path.length){
                const [step,...rest]=path;
                if(typeof step==='object'&&Object.hasOwn(value.properties??{},step.property))
                    return child(scope.pointer+'/properties/'+escape(step.property),rest);
                if(step==='item'&&Object.hasOwn(value,'items'))return child(scope.pointer+'/items',rest);
                if(step==='nested')return false;
            }
            return true;
        };
        return visit(use.schema,use.path);
    }
    inspect(scope:GraphScope):readonly Use[]{
        const pending:Visit[]=[{scope,path:[]}],seen=new Set<string>(),uses:Use[]=[];
        while(pending.length){
            const current=pending.pop()!,at=current.scope,{resource,pointer}=at,path=current.path;
            const key=JSON.stringify([resource,pointer,path]);
            if(seen.has(key))continue;
            if(seen.size>=2048)throw new SourceError('limit.migration.binary','Binary representation inspection exceeds 2048 captured occurrences');
            seen.add(key);
            for(const incoming of this.incoming.get(identity(at))??[])pending.push({scope:incoming,path});
            const tokens=segments(pointer),last=tokens.at(-1),parent=pointer.slice(0,pointer.lastIndexOf('/'));
            const owner=this.graph.scopes.get(resource+'#'+parent);
            if(last==='schema'&&owner?.kind==='media'){
                const mediaType=segments(owner.pointer).at(-1)!;
                const essence=mediaType.split(';')[0].trim().toLowerCase();
                const part=path[0];
                if(essence.startsWith('multipart/')||essence==='application/x-www-form-urlencoded'){
                    if(part&&typeof part==='object'&&path.slice(1).every(step=>step==='item')){
                        const value=this.graph.docs.get(resource)!.dataNode(owner.pointer)!.value;
                        let shape=this.forms.shape(resource,pointer).properties?.[part.property];
                        if(shape?.types?.includes('array'))shape=shape.items;
                        const rule=value.encoding?.[part.property];
                        // Styled encodings use their RFC6570 text representation.
                        const styled=essence==='application/x-www-form-urlencoded'&&
                            ['style','explode','allowReserved'].some(name=>Object.hasOwn(rule??{},name));
                        const contentType=styled?'text/plain':rule?.contentType??shape?.defaultContentType??formContentType({},at.family);
                        uses.push({kind:'part',mediaType:contentType,source:owner,schema:at,path});
                    }else uses.push({kind:'data',source:owner,schema:at,path});
                }else uses.push({kind:path.length?'data':'body',mediaType,source:owner,schema:at,path});
                continue;
            }
            if(last==='schema'&&owner&&['parameter','header'].includes(owner.kind)){
                uses.push({kind:'data',source:owner,schema:at,path});continue;
            }
            let ancestor:GraphScope|undefined,next=path;
            const container=tokens.at(-2);
            if(container==='properties'){
                const above=parent.slice(0,parent.lastIndexOf('/'));
                ancestor=this.graph.scopeAs(resource,above,'schema');
                next=[{property:last!},...path];
            }else if(['allOf','anyOf','oneOf'].includes(container??''))
                ancestor=this.graph.scopeAs(resource,parent.slice(0,parent.lastIndexOf('/')),'schema');
            else if(['items','additionalProperties','not'].includes(last??'')){
                ancestor=this.graph.scopeAs(resource,parent,'schema');
                if(last==='items')next=['item',...path];
                else if(last==='additionalProperties')next=['nested',...path];
            }
            if(ancestor){
                // Once more than one nested property is crossed, the value is
                // ordinary data rather than the MIME part itself. Collapse only
                // that classification state; recursive references remain bounded.
                if(next.length>8||next.filter(step=>typeof step==='object').length>1)next=['nested'];
                pending.push({scope:ancestor,path:next});
            }
        }
        return uses;
    }
}

function representation(use:Use):'raw'|'data'|'unknown' {
    if(use.kind==='data')return 'data';
    if(use.mediaType===undefined)return 'unknown';
    const kinds=mediaTypes(use.mediaType).map(type=>{
        if(type.type==='*'||type.subtype==='*')return 'unknown';
        return runtimeMediaKind(type.text)!=='opaque'?'data':runtimeBinaryMedia(type.text)?'raw':'unknown';
    });
    return kinds.every(kind=>kind==='raw')?'raw':kinds.every(kind=>kind==='data')?'data':'unknown';
}
const raw=(use:Use)=>representation(use)==='raw';
const annotation=(name:string)=>name.startsWith('x-')||['title','description','externalDocs','xml','deprecated','readOnly','writeOnly'].includes(name);

/** OAS 3.0.4 §4.4.2 / 3.1.2 §§4.4.2–4.4.2.1. Encoded strings retain
 * their type and base64 spelling. Raw leaves are outside JSON types in modern
 * OAS; only proved raw occurrences can lose the legacy octet-string type.
 * Assertions with no established raw-instance mapping remain located blockers. */
export function migrateBinarySchemas(graph:ReferenceGraph,sources:Map<string,MigrationSource>,from:string,to:string,issue:MigrationIssue):void {
    if(!(from==='3.0'&&modernFamily(to)||modernFamily(from)&&to==='3.0'))return;
    const uses=new BinaryUses(graph);
    for(const scope of graph.scopesFor('schema')){
        if(scope.family!==from)continue;
        const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
        if(value===null||typeof value!=='object'||Array.isArray(value)||typeof value.$ref==='string')continue;
        const source=sources.get(scope.resource)!,pointer=source.current(scope.pointer);
        if(pointer===undefined)continue;
        const field=(name:string)=>({...scope,pointer:scope.pointer+'/'+escape(name)});
        const fail=(name:string,message:string)=>issue(field(name),'migration.schema.binary-context',message,'implementation');
        if(from==='3.0'&&['binary','byte'].includes(value.format)){
            const contexts=uses.inspect(scope);
            if(value.format==='byte'){
                if(contexts.some(use=>representation(use)==='unknown'||use.kind==='body'&&raw(use))){
                    fail('format','A whole encoded binary body needs its media-aware encoded-string interpretation before conversion');continue;
                }
                // A decoded content media type cannot be inferred from a JSON
                // container's media type. Do not invent contentMediaType here.
                source.remove(pointer+'/format');source.set(pointer+'/contentEncoding','base64');
                continue;
            }
            if(contexts.some(use=>representation(use)==='unknown')){
                fail('format','The captured binary media choices do not yet have a complete raw or data-model representation mapping');continue;
            }
            const rawContexts=contexts.filter(raw);
            if(!rawContexts.length){
                if(!contexts.length)fail('format','The raw binary schema has no captured media occurrence from which to establish its representation');
                // In a known JSON/text occurrence, the schema still constrains
                // strings. The legacy format stays an annotation in modern OAS.
                continue;
            }
            if(rawContexts.length!==contexts.length){
                fail('format','This schema has both raw binary and data-model consumers; those occurrences need separate schema ownership');continue;
            }
            if(!contexts.every(use=>uses.rawCompatible(use,from))){
                fail('format','Applicable container or composition assertions need a complete raw-instance mapping before this binary leaf can be changed');continue;
            }
            const assertions=Object.keys(value).filter(name=>!['type','format','allOf','anyOf','oneOf','not'].includes(name)&&!annotation(name));
            if(value.type!=='string'||assertions.length){
                fail(assertions[0]??'type','The raw binary leaf needs a faithful mapping for each applicable legacy assertion before its octet-string type can be removed');continue;
            }
            source.remove(pointer+'/type');source.remove(pointer+'/format');
            continue;
        }
        if(from==='3.0')continue;
        const encoded=value.contentEncoding==='base64';
        if(Object.hasOwn(value,'contentEncoding')&&!encoded)continue;
        if(!encoded&&!Object.hasOwn(value,'contentMediaType'))continue;
        const contexts=uses.inspect(scope);
        if(encoded){
            if(typeof value.format==='string'&&value.format!=='byte'){
                fail('format','The existing format annotation needs an independent target owner before activating format: byte');continue;
            }
            if(contexts.some(use=>representation(use)==='unknown'||use.kind==='body'&&raw(use))){
                fail('contentEncoding','A whole encoded binary body needs its captured string/media representation before lowering');continue;
            }
            source.remove(pointer+'/contentEncoding');source.set(pointer+'/format','byte');
        }
        if(Object.hasOwn(value,'contentMediaType')){
            // OAS requires ignoring a redundant/contradicting contentMediaType
            // at a concrete Media Type/Encoding occurrence. A nested JSON value
            // has no such binding; dropping its annotation is not equivalent.
            if(!contexts.length||contexts.some(use=>use.kind==='data'||use.mediaType===undefined)){
                fail('contentMediaType','The decoded content media type has no proved concrete media binding at every occurrence');continue;
            }
            if(!encoded){
                if(!contexts.every(raw)||Object.hasOwn(value,'type')){
                    fail('contentMediaType','This unencoded content schema needs a proved raw media leaf without a conflicting JSON type');continue;
                }
                const assertions=Object.keys(value).filter(name=>name!=='contentMediaType'&&!annotation(name));
                if(assertions.length){fail(assertions[0],'This raw content leaf has assertions needing an explicit older-family instance mapping');continue;}
                source.set(pointer+'/type','string');source.set(pointer+'/format','binary');
            }
            source.remove(pointer+'/contentMediaType');
        }
    }
}
