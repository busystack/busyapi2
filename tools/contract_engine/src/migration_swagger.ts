import {createHash} from 'node:crypto';
import type {ReferenceGraph,GraphScope} from './reference_graph';
import {escape} from './document';
import {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {ParameterSemantics} from './parameter_semantics';
import {swaggerMedia,swaggerServers} from './swagger_operation';

const schemaFields=['type','format','items','default','maximum','exclusiveMaximum','minimum','exclusiveMinimum','maxLength','minLength','pattern','maxItems','minItems','uniqueItems','enum','multipleOf'];

/** Structural mappings use native graph occurrences and effective parameters,
 * including inherited body/form parameters. No guessed traversal of payloads. */
export function upgradeSwagger(graph:ReferenceGraph,sources:Map<string,MigrationSource>,issue:MigrationIssue):void {
    const entry=sources.get(graph.root)!,parameters=new ParameterSemantics(graph),bodies=new Map<string,{resource:string;pointer:string}>();
    const path=(scope:GraphScope)=>sources.get(scope.resource)!.current(scope.pointer);
    const id=(resource:string,pointer:string)=>createHash('sha256').update(resource+'#'+pointer).digest('hex').slice(0,24);
    const unique=(group:string,scope:GraphScope)=>{
        const root=entry.doc,stem='_migrated_'+id(scope.resource,scope.pointer);let name=stem,index=0;
        while(root.nodes.has('/components/'+group+'/'+name)||group==='schemas'&&root.nodes.has('/definitions/'+name))name=stem+'_'+(++index);
        return '/components/'+group+'/'+name;
    };
    const style=(scope:GraphScope,value:any)=>{
        const format=value.collectionFormat??'csv';
        if(value.type!=='array')return;
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
        if(value.in==='body'){
            const destination=unique('requestBodies',scope);
            if(source!==entry){issue(scope,'migration.body.external-owner','A body parameter in an external fragment needs a resource-preserving request-body mapping','implementation');continue;}
            source.move(pointer,destination);
            source.remove(destination+'/name');source.remove(destination+'/in');
            bodies.set(scope.resource+'#'+scope.pointer,{resource:entry.doc.id,pointer:destination});
        }else if(value.in!=='formData'){
            const serialization=style(scope,value);flatSchema(source,pointer,value);
            if(source.doc.nodes.has(pointer+'/collectionFormat'))source.remove(pointer+'/collectionFormat');
            if(serialization)for(const [field,item]of Object.entries(serialization))source.set(pointer+'/'+field,item);
        }
    }
    for(const operation of graph.operations()){
        if(graph.scope(operation.source.resource,operation.source.pointer).family!=='2.0')continue;
        const source=sources.get(operation.source.resource)!,pointer=source.current(operation.source.pointer);if(pointer===undefined)continue;
        const effective=parameters.operation(operation.source.resource,operation.source.pointer,operation.pathItem),consumes=swaggerMedia(graph,operation.source.resource,operation.source.pointer,'consumes');
        const body=effective.visible.find(parameter=>parameter.location==='body'),form=effective.visible.filter(parameter=>parameter.location==='formData');
        if(body?.definition){
            const target=bodies.get(body.definition.resource+'#'+body.definition.pointer);
            if(target){
                const declaration=sources.get(target.resource)!;
                for(const media of consumes){
                    const at=target.pointer+'/content/'+escape(media)+'/schema';
                    if(!declaration.doc.nodes.has(at)){
                        const schema=declaration.doc.nodes.get(target.pointer+'/schema');
                        if(schema)declaration.copy(declaration,schema.pointer,at);
                        else issue(body.definition,'migration.body.media-context','A shared body parameter is used with different consumes declarations and needs a specialized request-body copy','implementation');
                    }
                }
                if(declaration.doc.nodes.has(target.pointer+'/schema'))declaration.remove(target.pointer+'/schema');
                source.set(pointer+'/requestBody',{$ref:target.resource+'#'+target.pointer});
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
                        if(!['csv','multi'].includes(value.collectionFormat??'csv'))issue({...definition,pointer:definition.pointer+'/collectionFormat'},'migration.form.collection','This formData collection encoding needs a faithful target Encoding Object mapping','implementation');
                        else source.set(at+'/encoding/'+escape(parameter.name!),{style:'form',explode:value.collectionFormat==='multi'});
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
    for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='response'){
        const source=sources.get(scope.resource)!,pointer=path(scope);if(pointer===undefined)continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;if(typeof value?.$ref==='string')continue;
        const consumers=graph.operations().filter(operation=>scope.resource===operation.source.resource&&scope.pointer.startsWith(operation.source.pointer+'/responses/'));
        const indirect=graph.references.filter(reference=>reference.kind==='response'&&reference.resolution==='resolved'&&reference.targetResource===scope.resource&&reference.targetPointer===scope.pointer);
        for(const reference of indirect)for(const operation of graph.operationContexts(reference.resource,reference.pointer.slice(0,reference.pointer.lastIndexOf('/responses/')))){
            if(JSON.stringify(swaggerMedia(graph,operation.source.resource,operation.source.pointer,'produces'))!==JSON.stringify(graph.docs.get(graph.root)!.root.value.produces??['*/*']))issue(scope,'migration.response.media-context','A shared response used with a different produces override needs a media-specialized target copy','implementation');
        }
        const media=consumers.length?swaggerMedia(graph,consumers[0].source.resource,consumers[0].source.pointer,'produces'):graph.docs.get(graph.root)!.root.value.produces??['*/*'];
        const names=[...new Set<string>([...media,...Object.keys(value.examples??{})])];
        for(const name of names){
            const at=pointer+'/content/'+escape(name);source.ensure(at);
            if(source.doc.nodes.has(pointer+'/schema'))source.copy(source,pointer+'/schema',at+'/schema');
            if(source.doc.nodes.has(pointer+'/examples/'+escape(name)))source.move(pointer+'/examples/'+escape(name),at+'/example');
        }
        if(source.doc.nodes.has(pointer+'/schema')){
            const destination=names[0];
            for(const values of source.origins.values())for(const at of [...values])if(at===pointer+'/schema'||at.startsWith(pointer+'/schema/')){values.delete(at);values.add(pointer+'/content/'+escape(destination)+'/schema'+at.slice((pointer+'/schema').length));}
            source.remove(pointer+'/schema',false);
        }
        source.remove(pointer+'/examples');
    }
    for(const scope of graph.scopes.values())if(scope.family==='2.0'&&scope.kind==='header'){
        const source=sources.get(scope.resource)!,pointer=path(scope);if(pointer===undefined)continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
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
        for(const [from,to]of [['definitions','schemas'],['parameters','parameters'],['responses','responses'],['securityDefinitions','securitySchemes']])if(source.doc.nodes.has('/'+from))source.move('/'+from,'/components/'+to);
        const servers=swaggerServers(graph,graph.root,'',()=>({resource:graph.root,pointer:'',generation:0,range:[0,0]}));
        source.set('/servers',servers.map(({url})=>({url})));
        for(const name of ['swagger','host','basePath','schemes','consumes','produces'])source.remove('/'+name);
        source.set('/openapi','3.0.4');
    }
}
