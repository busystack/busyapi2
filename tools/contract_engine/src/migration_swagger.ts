import {pointerFragment,type ReferenceGraph,type GraphScope} from './reference_graph';
import {escape} from './document';
import {MigrationSource} from './migration_source';
import {documentUriValidity} from './document_uris';
import type {MigrationIssue} from './migration_schema';
import {ParameterSemantics} from './parameter_semantics';
import {swaggerMedia,swaggerServers} from './swagger_operation';
import {swaggerMediaMigration} from './migration_swagger_media';

const schemaFields=['type','format','items','default','maximum','exclusiveMaximum','minimum','exclusiveMinimum','maxLength','minLength','pattern','maxItems','minItems','uniqueItems','enum','multipleOf'];

/** Structural mappings use native graph occurrences and effective parameters,
 * including inherited body/form parameters. No guessed traversal of payloads. */
export function upgradeSwagger(graph:ReferenceGraph,sources:Map<string,MigrationSource>,issue:MigrationIssue,contexts:readonly ReferenceGraph[]=[graph]) {
    // Swagger Info text becomes a URL in 3.0 (§4.7.2). A URI-looking
    // string does not itself establish the author's intent to activate a link.
    for(const scope of graph.scopes.values())if(scope.kind==='info'&&scope.family==='2.0'){
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.termsOfService;
        if(typeof value!=='string')continue;
        const location={...scope,pointer:scope.pointer+'/termsOfService'},validity=documentUriValidity(value);
        if(validity!=='valid')issue(location,'migration.info.terms-uri',validity==='unsupported'
            ?'The Terms of Service text uses URI syntax that cannot be evaluated; migration cannot establish a target URL'
            :'Swagger Terms of Service text is not a URI reference; provide an intentional target URL before migration',validity==='unsupported'?'implementation':'target-representation');
        else issue(location,'migration.info.terms-uri-activation','Swagger Terms of Service is text; confirm that this exact value is intended to become a URL','decision',['interpret-terms-as-uri']);
    }
    // Reserve authored schema names before adding shared media schema owners.
    for(const [resource,specification]of graph.specifications)if(specification.family==='2.0'){
        const source=sources.get(resource)!;
        if(source.doc.nodes.has('/definitions'))source.move('/definitions','/components/schemas');
    }
    const parameters=new ParameterSemantics(graph),media=swaggerMediaMigration(graph,sources,issue,contexts);
    const path=(scope:GraphScope)=>sources.get(scope.resource)!.current(scope.pointer);
    const style=(scope:Pick<GraphScope,'resource'|'pointer'>,value:any)=>{
        const format=value.collectionFormat??'csv';
        if(value.type!=='array')return;
        if(value.items?.type==='array'){
            issue({...scope,pointer:scope.pointer+'/items'},'migration.parameter.nested-collection','RFC6570 parameter styles do not define nested Swagger collection serialization','target-representation');return;
        }
        if(format==='tsv'||['path','header'].includes(value.in)&&format!=='csv'){
            issue({...scope,pointer:scope.pointer+'/collectionFormat'},'migration.parameter.collection','This Swagger collection encoding has no equivalent OpenAPI 3.0 parameter style','target-representation');return;
        }
        return {style:format==='ssv'?'spaceDelimited':format==='pipes'?'pipeDelimited':['query','formData'].includes(value.in)?'form':'simple',explode:format==='multi'};
    };
    const flatSchema=(source:MigrationSource,pointer:string,value:any)=>{
        source.ensure(pointer+'/schema');
        for(const name of schemaFields)if(source.doc.nodes.has(pointer+'/'+name))source.move(pointer+'/'+name,pointer+'/schema/'+name);
    };
    for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='parameter'){
        const source=sources.get(scope.resource)!,pointer=path(scope);if(pointer===undefined)continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
        if(typeof value?.$ref==='string')continue;
        if(!['body','formData'].includes(value.in)){
            const serialization=style(scope,value);flatSchema(source,pointer,value);
            if(source.doc.nodes.has(pointer+'/collectionFormat'))source.remove(pointer+'/collectionFormat');
            if(serialization)for(const [field,item]of Object.entries(serialization))source.set(pointer+'/'+field,item);
        }
    }
    const represented=new Map<string,string>();
    for(const context of contexts)for(const operation of context.operations()){
        const graph=context;
        if(graph.scope(operation.source.resource,operation.source.pointer).family!=='2.0')continue;
        const identity=operation.source.resource+'#'+operation.source.pointer;
        const signature=JSON.stringify([swaggerMedia(graph,operation.source.resource,operation.source.pointer,'consumes'),swaggerMedia(graph,operation.source.resource,operation.source.pointer,'produces')]);
        if(represented.has(identity)){
            if(represented.get(identity)!==signature)issue(operation.source,'migration.operation.multiple-contexts','This shared Swagger operation has different inherited media in captured descriptions; it needs distinct target operation owners','implementation');
            continue;
        }
        represented.set(identity,signature);
        const source=sources.get(operation.source.resource)!,pointer=source.current(operation.source.pointer);if(pointer===undefined)continue;
        const effective=parameters.operation(operation.source.resource,operation.source.pointer,operation.pathItem),consumes=swaggerMedia(graph,operation.source.resource,operation.source.pointer,'consumes');
        const body=effective.visible.find(parameter=>parameter.location==='body'),form=effective.visible.filter(parameter=>parameter.location==='formData');
        if(body?.definition){
            const target=media.body(body.definition,consumes);
            if(target){
                source.set(pointer+'/requestBody',{$ref:target.resource+pointerFragment(target.pointer)});
            }
        }else if(form.length){
            source.set(pointer+'/requestBody',{required:form.some(parameter=>graph.docs.get(parameter.definition!.resource)!.dataNode(parameter.definition!.pointer)!.value.required===true),content:{}});
            for(const media of consumes){
                const at=pointer+'/requestBody/content/'+escape(media);
                if(!['application/x-www-form-urlencoded','multipart/form-data'].includes(media))issue(operation.source,'migration.form.media','Native formData requires a concrete form media representation for migration','source-incomplete');
                source.set(at,{schema:{type:'object',properties:{}}});const required:string[]=[];
                for(const parameter of form){
                    const definition=parameter.definition!,owner=sources.get(definition.resource)!,from=owner.current(definition.pointer);if(from===undefined)continue;
                    const value=graph.docs.get(definition.resource)!.dataNode(definition.pointer)!.value,target=at+'/schema/properties/'+escape(parameter.name!);
                    source.set(target,{});
                    for(const field of [...schemaFields,'description'])if(owner.doc.nodes.has(from+'/'+field))source.copy(owner,from+'/'+field,target+'/'+field);
                    for(const field of Object.keys(value).filter(name=>name.startsWith('x-')))source.copy(owner,from+'/'+escape(field),target+'/'+escape(field));
                    if(value.type==='file'){source.set(target+'/type','string');source.set(target+'/format','binary');}
                    if(value.required===true)required.push(parameter.name!);
                    if(value.allowEmptyValue===true)issue({...definition,pointer:definition.pointer+'/allowEmptyValue'},'migration.form.empty','This form empty-value rule needs an explicit equivalent encoding policy','implementation');
                    if(value.type==='array'){
                        if(value.items?.type==='array')issue({...definition,pointer:definition.pointer+'/items'},'migration.form.nested-collection','This nested Swagger form collection cannot retain its delimiter hierarchy in OpenAPI 3.0','target-representation');
                        const format=value.collectionFormat??'csv';
                        if(media==='multipart/form-data'){
                            if(format!=='multi')issue({...definition,pointer:definition.pointer+'/collectionFormat'},'migration.form.collection','OpenAPI 3.0 multipart arrays use repeated parts and cannot preserve this Swagger collection separator','target-representation');
                        }else if(format==='tsv')issue({...definition,pointer:definition.pointer+'/collectionFormat'},'migration.form.collection','OpenAPI 3.0 has no tabDelimited form encoding','target-representation');
                        else source.set(at+'/encoding/'+escape(parameter.name!),style(definition,value));
                    }
                }
                if(required.length)source.set(at+'/schema/required',required);
            }
        }
        const declared=graph.docs.get(operation.source.resource)!.dataNode(operation.source.pointer)!;
        for(const field of ['schemes','consumes','produces'])if(declared.children.has(field))source.remove(pointer+'/'+field);
        if(declared.children.has('schemes')){
            const servers=swaggerServers(graph,operation.source.resource,operation.source.pointer,()=>({resource:graph.root,pointer:'',generation:0,range:[0,0]}));
            source.set(pointer+'/servers',servers.map(({url})=>({url})));
        }
    }
    media.unusedBodies();
    // Remove body/form declarations from Parameters arrays only after effective
    // inheritance has been captured for every physical operation occurrence.
    for(const scope of [...graph.scopes.values()].filter(scope=>scope.family==='2.0'&&scope.kind==='parameter-array')){
        const source=sources.get(scope.resource)!,pointer=path(scope);if(pointer===undefined)continue;
        const original=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!;
        for(const index of [...original.children.keys()].reverse()){
            const occurrence=parameters.occurrence({resource:scope.resource,pointer:scope.pointer+'/'+index,kind:'parameter'});
            if(['body','formData'].includes(occurrence.location??'')){
                const current=source.current(scope.pointer+'/'+index);if(current!==undefined&&current.startsWith(pointer+'/'))source.remove(current);
            }
        }
    }
    for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='header'){
        const source=sources.get(scope.resource)!,pointer=path(scope);if(pointer===undefined)continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
        if(value.items?.type==='array')issue({...scope,pointer:scope.pointer+'/items'},'migration.header.nested-collection','OpenAPI 3.0 Header Objects cannot retain a nested Swagger delimiter hierarchy','target-representation');
        if(value.collectionFormat&&value.collectionFormat!=='csv')issue({...scope,pointer:scope.pointer+'/collectionFormat'},'migration.header.collection','OpenAPI 3.0 Header Objects cannot express this Swagger collection separator','target-representation');
        flatSchema(source,pointer,value);source.remove(pointer+'/collectionFormat');
    }
    for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='security'){
        const source=sources.get(scope.resource)!,pointer=path(scope);if(pointer===undefined)continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
        if(value.type==='basic'){source.set(pointer+'/type','http');source.set(pointer+'/scheme','basic');}
        if(value.type==='oauth2'){
            const flow=({implicit:'implicit',password:'password',application:'clientCredentials',accessCode:'authorizationCode'} as Record<string,string>)[value.flow];
            for(const name of ['authorizationUrl','tokenUrl','scopes'])if(source.doc.nodes.has(pointer+'/'+name))source.move(pointer+'/'+name,pointer+'/flows/'+flow+'/'+name);
            source.remove(pointer+'/flow');
        }
    }
    for(const [resource,specification]of graph.specifications)if(specification.family==='2.0'){
        const source=sources.get(resource)!;
        for(const name of source.doc.dataNode('/parameters')?.children.keys()??[]){
            const node=source.doc.node('/parameters/'+escape(name));if(node.value?.in==='formData')source.remove(node.pointer);
        }
        for(const [from,to]of [['parameters','parameters'],['responses','responses'],['securityDefinitions','securitySchemes']])if(source.doc.nodes.has('/'+from))source.move('/'+from,'/components/'+to);
        const servers=swaggerServers(graph,resource,'',()=>({resource,pointer:'',generation:0,range:[0,0]}),resource);
        source.set('/servers',servers.map(({url})=>({url})));
        for(const name of ['swagger','host','basePath','schemes','consumes','produces'])source.remove('/'+name);
        source.set('/openapi','3.0.4');
    }
    return media.responses();
}
