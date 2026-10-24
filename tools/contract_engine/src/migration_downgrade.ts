import type {ReferenceGraph} from './reference_graph';
import {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {escape} from './document';

/** Evaluate actual target representation. A simple 3.x API can be faithfully
 * represented in Swagger; newer-only constructs receive located blockers. */
export function downgradeSwagger(graph:ReferenceGraph,sources:Map<string,MigrationSource>,issue:MigrationIssue):void {
    for(const scope of graph.scopes.values()){
        const source=sources.get(scope.resource)!,pointer=source.current(scope.pointer);if(pointer===undefined)continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)!.value;
        if(scope.kind==='parameter'||scope.kind==='header'){
            if(typeof value?.$ref==='string')continue;
            if(value.content||scope.kind==='parameter'&&value.in==='cookie')issue(scope,'migration.parameter.representation','This parameter representation has no implemented faithful Swagger mapping','implementation');
            const style=value.style??(['query','cookie'].includes(value.in)?'form':'simple'),explode=value.explode??style==='form';
            const type=value.schema?.type;
            if(type==='object'||Array.isArray(type))issue(scope,'migration.parameter.type','Swagger flat parameters cannot represent this schema type','target-representation');
            if(type==='array'){
                const format=style==='simple'?'csv':style==='form'?explode?'multi':'csv':style==='spaceDelimited'?'ssv':style==='pipeDelimited'?'pipes':undefined;
                if(!format||format==='multi'&&!['query','formData'].includes(value.in))issue(scope,'migration.parameter.style','This style/explode combination cannot be faithfully represented by Swagger collectionFormat','target-representation');
                else source.set(pointer+'/collectionFormat',format);
            }else if(!['simple','form'].includes(style))issue(scope,'migration.parameter.style','This primitive parameter serialization is unavailable in Swagger','target-representation');
            const schema=source.doc.dataNode(pointer+'/schema');
            if(schema?.kind==='object'){
                for(const name of [...schema.children.keys()])source.move(pointer+'/schema/'+escape(name),pointer+'/'+escape(name));
                source.remove(pointer+'/schema');
            }else if(!value.content)issue(scope,'migration.parameter.schema','Swagger requires a concrete flat primitive declaration','implementation');
            for(const name of ['style','explode'])source.remove(pointer+'/'+name);
            for(const name of ['deprecated','allowReserved','example','examples'])if(Object.hasOwn(value,name))issue({...scope,pointer:scope.pointer+'/'+name},'migration.parameter.metadata','This authored parameter field needs an explicit Swagger mapping','implementation');
        }
        if(scope.kind==='request-body'&&typeof value?.$ref!=='string'){
            const content=source.doc.dataNode(pointer+'/content'),media=[...content?.children.keys()??[]];
            if(!media.length){issue(scope,'migration.body.content','A Swagger body needs a schema-bearing representation','implementation');continue;}
            const shapes=media.map(name=>source.doc.dataNode(pointer+'/content/'+escape(name)+'/schema')?source.doc.dataJson(pointer+'/content/'+escape(name)+'/schema'):undefined);
            if(shapes.some(shape=>shape===undefined||shape!==shapes[0])){issue(scope,'migration.body.media-schema','Swagger has one body schema; these media representations need a common faithful schema','target-representation');continue;}
            if(media.some(name=>['multipart/form-data','application/x-www-form-urlencoded'].includes(name))){issue(scope,'migration.body.form','Form bodies need a field-preserving formData parameter mapping','implementation');continue;}
            source.move(pointer+'/content/'+escape(media[0])+'/schema',pointer+'/schema');
            if(media.some(name=>Object.keys(value.content[name]).some(field=>field!=='schema')))issue(scope,'migration.body.media-metadata','Request media annotations/examples need an explicit Swagger representation','implementation');
            source.remove(pointer+'/content');source.set(pointer+'/name','body');source.set(pointer+'/in','body');
        }
        if(scope.kind==='operation'){
            const represented:string[][]=[];
            for(const name of Object.keys(value.responses??{}).filter(name=>!name.startsWith('x-'))){
                let response=value.responses[name];
                if(typeof response?.$ref==='string'){
                    const reference=graph.resolve(response.$ref,graph.scope(scope.resource,scope.pointer+'/responses/'+escape(name)));
                    if(reference.resolution==='resolved')response=graph.docs.get(reference.targetResource!)!.dataNode(reference.targetPointer!)!.value;
                }
                represented.push(Object.keys(response?.content??{}).sort());
            }
            if(represented.some(media=>JSON.stringify(media)!==JSON.stringify(represented[0])))issue(scope,'migration.response.media-context','Different response media sets need a status-specific Swagger representation that its global produces field cannot supply','target-representation');
            else if(represented[0]?.length)source.set(pointer+'/produces',represented[0]);
            const body=source.current(scope.pointer+'/requestBody');
            if(body!==undefined){
                if(!source.doc.nodes.has(pointer+'/parameters'))source.set(pointer+'/parameters',[]);
                const index=source.doc.node(pointer+'/parameters').children.size;
                source.move(body,pointer+'/parameters/'+index);
                let request=value.requestBody;
                if(typeof request?.$ref==='string'){
                    const ref=graph.resolve(request.$ref,graph.scope(scope.resource,scope.pointer+'/requestBody'));
                    if(ref.resolution==='resolved')request=graph.docs.get(ref.targetResource!)!.dataNode(ref.targetPointer!)!.value;
                }
                if(request?.content)source.set(pointer+'/consumes',Object.keys(request.content));
            }
            if(value.callbacks)issue({...scope,pointer:scope.pointer+'/callbacks'},'migration.callbacks','Swagger has no standard Callback Object representation','target-representation');
        }
        if(scope.kind==='response'&&typeof value?.$ref!=='string'){
            const media=Object.keys(value.content??{}),schemas=media.map(name=>graph.docs.get(scope.resource)!.dataNode(scope.pointer+'/content/'+escape(name)+'/schema')?graph.docs.get(scope.resource)!.dataJson(scope.pointer+'/content/'+escape(name)+'/schema'):undefined);
            if(schemas.some(schema=>schema!==schemas[0]))issue(scope,'migration.response.media-schema','Swagger has one response schema; these representations differ','target-representation');
            if(schemas[0]!==undefined)source.move(pointer+'/content/'+escape(media[0])+'/schema',pointer+'/schema');
            for(const name of media){
                const at=pointer+'/content/'+escape(name),value=source.doc.dataNode(at)?.value;
                if(Object.hasOwn(value??{},'example'))source.move(at+'/example',pointer+'/examples/'+escape(name));
                if(value?.examples)issue({...scope,pointer:scope.pointer+'/content/'+escape(name)+'/examples'},'migration.response.named-examples','Swagger permits one payload per media type; select an authored example explicitly','implementation');
            }
            source.remove(pointer+'/content');
            if(value.links)issue({...scope,pointer:scope.pointer+'/links'},'migration.links','Swagger has no standard Link Object representation','target-representation');
        }
        if(scope.kind==='security'){
            if(value.type==='http'&&value.scheme?.toLowerCase()==='basic'){source.set(pointer+'/type','basic');source.remove(pointer+'/scheme');}
            else if(value.type==='oauth2'){
                const flows=Object.keys(value.flows??{});
                if(flows.length!==1){issue(scope,'migration.security.flows','Multiple OAuth flows need a requirement-preserving Swagger scheme split','implementation');continue;}
                const flow=flows[0],name=({implicit:'implicit',password:'password',clientCredentials:'application',authorizationCode:'accessCode'} as Record<string,string>)[flow];
                if(!name){issue(scope,'migration.security.flow','Swagger cannot express this OAuth flow','target-representation');continue;}
                source.set(pointer+'/flow',name);
                for(const field of ['authorizationUrl','tokenUrl','scopes'])if(source.doc.nodes.has(pointer+'/flows/'+flow+'/'+field))source.move(pointer+'/flows/'+flow+'/'+field,pointer+'/'+field);
                if(value.flows[flow].refreshUrl)issue(scope,'migration.security.refresh','A distinct OAuth refresh endpoint is not described by Swagger','target-representation');
                source.remove(pointer+'/flows');
            }else if(value.type!=='apiKey')issue(scope,'migration.security.type','Swagger has no equivalent standard security scheme for this authentication type','target-representation');
            if(value.type==='apiKey'&&!['query','header'].includes(value.in))issue(scope,'migration.security.location','Swagger API keys must be query or header parameters','target-representation');
        }
    }
    for(const [resource]of graph.specifications){
        const source=sources.get(resource)!,servers=source.doc.dataNode('/servers')?.value;
        if(servers!==undefined){
            if(!Array.isArray(servers)||servers.length!==1||servers[0].variables){issue({resource,pointer:'/servers'},'migration.servers','Swagger needs one fixed host/basePath; these Server choices cannot be collapsed faithfully','target-representation');}
            else {
                const url=new URL(servers[0].url,graph.retrievals.get(resource));
                if(!['http:','https:','ws:','wss:'].includes(url.protocol)||!url.host||url.search||url.hash||url.username||url.password)issue({resource,pointer:'/servers/0/url'},'migration.server.url','This Server URL cannot be expressed by Swagger host/basePath/schemes','target-representation');
                else {source.set('/host',url.host);source.set('/basePath',url.pathname);source.set('/schemes',[url.protocol.slice(0,-1)]);source.remove('/servers');}
            }
        }
        for(const [from,to]of [['schemas','definitions'],['parameters','parameters'],['responses','responses'],['securitySchemes','securityDefinitions']])if(source.doc.nodes.has('/components/'+from))source.move('/components/'+from,'/'+to);
        if(source.doc.dataNode('/components/requestBodies')){
            source.ensure('/parameters');
            for(const name of [...source.doc.node('/components/requestBodies').children.keys()])source.move('/components/requestBodies/'+escape(name),'/parameters/'+escape(name));
            source.remove('/components/requestBodies');
        }
        const components=source.doc.dataNode('/components');
        if(components?.children.size)issue({resource,pointer:'/components'},'migration.components','These reusable component families need an additional Swagger representation','implementation');
        else source.remove('/components');
        for(const name of ['webhooks','$self'])if(source.doc.nodes.has('/'+name))issue({resource,pointer:'/'+name},'migration.root.field','This document feature needs a faithful Swagger mapping','implementation');
        source.remove('/openapi');source.set('/swagger','2.0');
    }
}
