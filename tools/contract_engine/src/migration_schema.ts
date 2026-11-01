import {schemaDefinitionKeywords} from './schema_definitions';
import type {GraphScope,ReferenceGraph} from './reference_graph';
import {MigrationSource,type MigrationLocation} from './migration_source';
import {modernFamily} from './specification';
import {escape} from './document';
import {compare,decimal} from './exact_numbers';
import {createHash} from 'node:crypto';
import {MigrationSchemaReferences} from './migration_schema_references';
import {SchemaPropertyRequirements} from './schema_property_requirements';
import {migrateDependentRequired,migrateDependentSchemas} from './migration_schema_dependencies';

export type MigrationChoice=Readonly<{value:string;label:string;target:MigrationLocation&{range:readonly number[]}}>;
export type MigrationProblem={resource:string;pointer:string;range:number[];code:string;message:string;reason:'target-representation'|'implementation'|'source-incomplete'|'decision';choices?:string[];choiceDetails?:readonly MigrationChoice[];id?:string};
export type MigrationIssueLocation=MigrationLocation&{original?:MigrationLocation;decisionKey?:string};
export type MigrationIssue=(scope:MigrationIssueLocation,code:string,message:string,reason:MigrationProblem['reason'],choices?:string[],choiceDetails?:readonly MigrationChoice[])=>boolean;
export type MigrationChoose=(scope:MigrationIssueLocation,code:string,message:string,choices:readonly MigrationChoice[])=>string|undefined;

/** Normative schema mappings. No schema is evaluated under another family's
 * dialect to make a migration pass. These edits affect planning copies only. */
export function migrateSchemas(graph:ReferenceGraph,sources:Map<string,MigrationSource>,from:string,to:string,issue:MigrationIssue):void {
    const references=new MigrationSchemaReferences(graph),requirements=new SchemaPropertyRequirements(graph);
    const scopes=[...graph.scopes.values()].filter(scope=>scope.kind==='schema'&&scope.family===from).sort((a,b)=>b.pointer.length-a.pointer.length);
    for(const scope of scopes){
        const source=sources.get(scope.resource)!,pointer=source.current(scope.pointer);if(pointer===undefined)continue;
        const original=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!,value=original.value;
        if(typeof value==='boolean'){
            if(scope.pointer.endsWith('/additionalProperties')){
                if(!modernFamily(to)&&graph.references.some(reference=>reference.targetResource===scope.resource&&reference.targetPointer===scope.pointer))issue(scope,'migration.schema.boolean-dual-owner','A boolean additionalProperties value also used as a standalone schema needs a separate target representation','implementation');
                continue;
            }
            if(!modernFamily(to))source.set(pointer,value?{}:to==='2.0'?{allOf:[{type:'string'},{type:'integer'}]}:{not:{}});
            continue;
        }
        if(!value||typeof value!=='object'||Array.isArray(value))continue;
        const field=(name:string)=>({...scope,pointer:scope.pointer+'/'+escape(name)});
        const typeComposition=(types:string[])=>{
            const branches=types.map(type=>type==='null'?{type:'string',nullable:true,enum:[null]}:{type});
            source.remove(pointer+'/type');
            if(source.doc.nodes.has(pointer+'/anyOf')){
                if(!source.doc.nodes.has(pointer+'/allOf'))source.set(pointer+'/allOf',[]);
                const index=source.doc.node(pointer+'/allOf').children.size;source.set(pointer+'/allOf/'+index,{});source.move(pointer+'/anyOf',pointer+'/allOf/'+index+'/anyOf');
            }
            source.set(pointer+'/anyOf',branches);
        };
        if(!modernFamily(to)&&Object.hasOwn(value,'$schema'))source.remove(pointer+'/$schema');
        if(!modernFamily(to)&&Array.isArray(value.required)&&value.required.length===0)source.remove(pointer+'/required');
        if(modernFamily(from)&&!modernFamily(to)){
            // Static resource/anchor addresses have already been resolved by
            // the captured graph. Reference repair below maps their physical
            // owners before the target is evaluated without modern identities.
            for(const name of ['$id','$anchor'])source.remove(pointer+'/'+name);
            for(const keyword of schemaDefinitionKeywords)if(source.doc.nodes.has(pointer+'/'+keyword)){
                const entry=sources.get(graph.root)!;
                for(const name of [...source.doc.node(pointer+'/'+keyword).children.keys()]){
                    const at=pointer+'/'+keyword+'/'+escape(name),stem='_migrated_'+createHash('sha256').update(scope.resource+'#'+scope.pointer+'/'+keyword+'/'+escape(name)).digest('hex').slice(0,24);
                    let destination='/components/schemas/'+stem,index=0;
                    while(entry.doc.nodes.has(destination))destination='/components/schemas/'+stem+'_'+(++index);
                    if(entry===source)source.move(at,destination);
                    else {entry.copy(source,at,destination);source.remove(at);}
                }
                source.remove(pointer+'/'+keyword);
            }
        }
        if(modernFamily(from)&&!modernFamily(to)){
            references.lower(scope,source,pointer,issue);
            migrateDependentRequired(graph,scope,source,pointer,to,requirements,issue);
            migrateDependentSchemas(graph,scope,source,pointer,to,requirements,issue);
        }
        if(!modernFamily(to))for(const name of ['$dynamicAnchor','patternProperties','if','then','else','contains','minContains','maxContains','unevaluatedItems','unevaluatedProperties','propertyNames','contentSchema','contentEncoding','contentMediaType'])
            if(Object.hasOwn(value,name)&&source.doc.nodes.has(pointer+'/'+name))issue(field(name),'migration.schema.keyword','This schema keyword or resource identity has no implemented faithful mapping to '+to,'implementation');
        if(!modernFamily(to)&&Array.isArray(value.prefixItems)){
            if(to==='2.0'){
                if(Object.hasOwn(value,'items')&&typeof value.items!=='boolean')issue(field('items'),'migration.schema.tuple-tail','A constrained tuple tail needs a faithful Swagger representation','implementation');
                else {
                    source.remove(pointer+'/items');
                    source.rename(pointer+'/prefixItems','items');
                    if(value.items===false){
                        const maximum=String(value.prefixItems.length),existing=source.doc.dataNode(pointer+'/maxItems');
                        if(!existing||compare(decimal(source.doc.dataJson(existing.pointer)),decimal(maximum))>0)source.exact(pointer+'/maxItems',maximum);
                    }
                }
            }else issue(field('prefixItems'),'migration.schema.tuple','OpenAPI 3.0 has no positional tuple Schema Object keyword','target-representation');
        }
        if(to==='2.0')for(const name of ['oneOf','anyOf','not','writeOnly','deprecated'])if(Object.hasOwn(value,name))issue(field(name),'migration.schema.keyword','This Schema Object field requires an explicit faithful Swagger mapping','implementation');
        if(from==='3.0'&&modernFamily(to)){
            if(value.nullable===true&&typeof value.type==='string')source.set(pointer+'/type',[value.type,'null']);
            if(Object.hasOwn(value,'nullable'))source.remove(pointer+'/nullable');
            for(const [exclusive,bound]of [['exclusiveMinimum','minimum'],['exclusiveMaximum','maximum']]){
                if(value[exclusive]===true)source.exact(pointer+'/'+exclusive,source.doc.dataJson(pointer+'/'+bound));
                else if(Object.hasOwn(value,exclusive))source.remove(pointer+'/'+exclusive);
            }
        }
        if(modernFamily(from)&&!modernFamily(to)){
            if(Object.hasOwn(value,'nullable')&&issue(field('nullable'),'migration.schema.annotation-activation','The target would activate the nonstandard nullable annotation; explicitly discard it or revise the source','decision',['discard-unrecognized-schema-keyword']))source.remove(pointer+'/nullable');
            for(const [exclusive,bound]of [['exclusiveMinimum','minimum'],['exclusiveMaximum','maximum']])if(typeof value[exclusive]==='number'){
                if(Object.hasOwn(value,bound)){
                    const comparison=compare(decimal(source.doc.dataJson(pointer+'/'+exclusive)),decimal(source.doc.dataJson(pointer+'/'+bound)));
                    const strict=exclusive==='exclusiveMinimum'?comparison>=0:comparison<=0;
                    if(strict)source.exact(pointer+'/'+bound,source.doc.dataJson(pointer+'/'+exclusive));
                    source.set(pointer+'/'+exclusive,strict);continue;
                }
                source.exact(pointer+'/'+bound,source.doc.dataJson(pointer+'/'+exclusive));source.set(pointer+'/'+exclusive,true);
            }
            if(Array.isArray(value.type)&&to==='3.0'){
                const types=value.type.filter((type:string)=>type!=='null');
                if(types.length===1&&value.type.includes('null')){source.set(pointer+'/type',types[0]);source.set(pointer+'/nullable',true);}
                else typeComposition(value.type);
            }
            if(value.type==='null'&&to==='3.0')typeComposition(['null']);
            if(Object.hasOwn(value,'const')){
                if(Object.hasOwn(value,'enum')){
                    if(!source.doc.nodes.has(pointer+'/allOf'))source.set(pointer+'/allOf',[]);
                    const branch=pointer+'/allOf/'+source.doc.node(pointer+'/allOf').children.size;
                    source.set(branch,{});source.move(pointer+'/const',branch+'/enum');source.exact(branch+'/enum','['+graph.docs.get(scope.resource)!.dataJson(scope.pointer+'/const')+']');
                }
                else source.rename(pointer+'/const','enum'),source.exact(pointer+'/enum','['+graph.docs.get(scope.resource)!.dataJson(scope.pointer+'/const')+']');
            }
            if(typeof value.$ref==='string'&&Object.keys(value).length>1){
                source.ensure(pointer+'/allOf');
                // Existing allOf must remain an array; otherwise source is invalid.
                const existing=source.doc.dataNode(pointer+'/allOf');
                if(existing?.kind==='object'&&existing.children.size===0)source.set(pointer+'/allOf',[]);
                const index=source.doc.node(pointer+'/allOf').children.size;
                source.set(pointer+'/allOf/'+index,{});source.move(pointer+'/$ref',pointer+'/allOf/'+index+'/$ref');
            }
        }
        if(from==='2.0'&&to==='3.0'){
            if(Array.isArray(value.items)){
                if(value.items.length===0)source.set(pointer+'/items',{});
                else issue(field('items'),'migration.schema.tuple','OpenAPI 3.0 cannot express Swagger positional tuple schemas','target-representation');
            }
            if(Array.isArray(value.type)||value.type==='null')typeComposition(Array.isArray(value.type)?value.type:['null']);
            if(value.type==='array'&&!Object.hasOwn(value,'items'))source.set(pointer+'/items',{});
            if(value.type==='file'){source.set(pointer+'/type','string');source.set(pointer+'/format','binary');}
        }
        if(from==='3.0'&&to==='2.0'){
            if(value.nullable===true&&typeof value.type==='string')source.set(pointer+'/type',[value.type,'null']);
            if(Object.hasOwn(value,'nullable'))source.remove(pointer+'/nullable');
        }
    }
}
