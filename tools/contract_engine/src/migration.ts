import {createHash} from 'node:crypto';
import {analyse,createGraph,Resource} from './engine';
import {SourceDocument,SourceError,escape} from './document';
import {specificationDeclaration,nativeFamilies,modernFamily} from './specification';
import {MigrationSource,MigrationLocation,migrationValueIdentity} from './migration_source';
import {migrateSchemas,MigrationProblem,MigrationIssue} from './migration_schema';
import {upgradeSwagger} from './migration_swagger';
import {downgradeSwagger} from './migration_downgrade';
import {evaluateSchemas} from './schema_evaluation';
import {referenceValue} from './reference_choices';
import {coldGraph} from './reference_selection';
import {documentUriBase,resolveUri,pointerFragment as fragment} from './reference_graph';
import {documentUriOccurrences} from './authoring';
import {serverTemplate} from './derived_bundle';
import {hasRelativeMarkdownLinks} from './markdown_links';
import {migrationRequestSignatures} from './migration_invariants';
import {migrateEncodings} from './migration_encoding';
import {checkRequestBodyTarget,migrateOperationBodies} from './migration_operation';
import {checkSecurityRequirementTarget} from './migration_security';

const digest=(value:string)=>createHash('sha256').update(value).digest('hex');
const migrationProducerVersion='5';
const key=(resource:string,pointer:string)=>JSON.stringify([resource,pointer]);
const patch:Record<string,string>={'2.0':'2.0','3.0':'3.0.4','3.1':'3.1.2','3.2':'3.2.1'};
export type MigrationInput=Readonly<{root:string;snapshot:string;resources:Resource[];targetVersion:string;destination:string;decisions?:Readonly<Record<string,string>>}>;
export type MigrationDisposition='faithfully-convertible'|'requires-decision'|'blocked';

/** Explicit, bounded graph transformation over captured CST planning copies.
 * Opening/checking/exporting never invokes this operation. Every successful
 * stage and the relocated output receive their own native validation. */
export async function planMigration(input:MigrationInput) {
    const targetDeclaration=specificationDeclaration(input.targetVersion==='2.0'?{swagger:input.targetVersion}:{openapi:input.targetVersion});
    if(targetDeclaration.status!=='supported')throw new SourceError('migration.target','Select an approved target specification version');
    const target=targetDeclaration.specification;
    const initial=createGraph(input),original=initial.docs,from=initial.graph.specifications.get(input.root)!;
    if(typeof input.destination!=='string'||!input.destination.endsWith('/')||!['file:','https:'].includes(new URL(input.destination).protocol))throw new SourceError('migration.destination','Choose an independent absolute output directory identity');
    if(input.resources.length>256)throw new SourceError('limit.migration.resources','Migration is bounded to 256 captured resources');
    const decisions=input.decisions??{};
    if(!decisions||typeof decisions!=='object'||Array.isArray(decisions)||Object.keys(decisions).length>2048)throw new SourceError('migration.decisions','Expected bounded explicit migration decisions');
    let resources:Resource[]=input.resources.map((resource:Resource)=>({...resource}));
    const decisionRevision=digest(JSON.stringify([migrationProducerVersion,input.snapshot,input.targetVersion,input.resources.map((resource:Resource)=>[resource.id,resource.generation,resource.text,resource.aliases]).sort((a:any,b:any)=>String(a[0]).localeCompare(String(b[0])))]));
    const decisionChoices=new Map<string,string[]>();
    const problems:MigrationProblem[]=[],accepted=new Set<string>(),stages:{from:string;to:string}[]=[],presentationChanges:{resource:string;pointer:string}[]=[];
    const ignoredBodyOmissions:MigrationLocation[]=[];
    const relocatedResources=new Map<string,string>();
    let origins=new Map<string,MigrationLocation[]>();
    for(const doc of original.values())for(const pointer of doc.nodes.keys())origins.set(key(doc.id,pointer),[{resource:doc.id,pointer}]);
    const sourceLocation=(resource:string,pointer:string)=>{
        resource=relocatedResources.get(resource)??resource;
        let at=pointer;
        while(true){
            for(const [origin,locations]of origins)if(locations.some(location=>location.resource===resource&&location.pointer===at)){
                const [id,source]=JSON.parse(origin) as [string,string],node=original.get(id)?.dataNode(source);
                return {resource:id,pointer:source,range:node?.range??original.get(id)!.root.range};
            }
            if(!at)break;at=at.slice(0,at.lastIndexOf('/'));
        }
        return {resource:input.root,pointer:'',range:original.get(input.root)!.root.range};
    };
    const issue:MigrationIssue=(location,code,message,reason,choices)=>{
        const source=sourceLocation(location.resource,location.pointer),id=digest(key(source.resource,source.pointer)+code+decisionRevision).slice(0,24);
        if(reason==='decision'&&choices)decisionChoices.set(id,choices);
        if(reason==='decision'&&choices?.includes(decisions[id])){accepted.add(id);return true;}
        if(!problems.some(problem=>problem.id===id))problems.push({...source,id,code,message,reason,...(choices?{choices}:{})});
        return false;
    };
    const refused=(error:unknown,location:MigrationLocation)=>{
        if(!(error instanceof SourceError))throw error;
        issue(error.source??location,error.code,error.message,'implementation');
    };
    const validate=async(values:Resource[],root:string)=>{
        const capture={...input,resources:values,root},analysis=analyse(capture),schemas=await evaluateSchemas(capture);
        if(!analysis.complete||!schemas.complete)issue({resource:root,pointer:''},'migration.validation.incomplete','Native validation did not complete; no migration can be published','source-incomplete');
        for(const finding of [...analysis.findings,...schemas.findings])if(finding.severity==='error')issue(finding,'migration.validation.'+finding.code,finding.message,'implementation');
        return {analysis,schemas};
    };
    await validate(resources,input.root);
    if(!problems.length)checkRequestBodyTarget(initial,resources,target.family,issue);
    if(!problems.length)checkSecurityRequirementTarget(initial.graph,target.family,issue);
    const order=[...nativeFamilies],start=order.indexOf(from.family),finish=order.indexOf(target.family);
    const route=start<=finish?order.slice(start,finish+1):target.family==='2.0'?[from.family,target.family]:order.slice(finish,start+1).reverse();
    if(initial.graph.specifications.size>1)issue({resource:input.root,pointer:''},'migration.multiple-roots','A graph containing multiple declared API roots needs a coordinated root-specific migration plan','implementation');
    for(let index=0;index<route.length-1&&!problems.length;index++){
        const before=route[index],after=route[index+1],context=createGraph({...input,resources}),{graph}=context;
        const sources=new Map([...context.docs].map(([id,doc])=>[id,new MigrationSource(doc)]));
        try {
            ignoredBodyOmissions.push(...migrateOperationBodies(graph,sources,before,after,from.family,issue));
            for(const scope of graph.scopes.values()){
                const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value,source=sources.get(scope.resource)!;
                if(source.current(scope.pointer)===undefined)continue;
                if(graph.referenceObject(value,scope)&&scope.kind!=='path-item'){
                    const siblings=Object.keys(value).filter(name=>name!=='$ref');
                    if(siblings.length&&modernFamily(after)&&!modernFamily(before)&&issue(scope,'migration.reference.ignored-siblings','The target would activate ignored Reference Object siblings; explicitly discard those preserved values or revise the source','decision',['discard-ignored-siblings']))for(const name of siblings)source.remove(scope.pointer+'/'+escape(name));
                    if(siblings.length&&!modernFamily(after)&&modernFamily(before)&&scope.kind!=='schema')issue(scope,'migration.reference.annotations','The target cannot retain these Reference Object annotation overrides','target-representation');
                }
                if(before==='3.0'&&modernFamily(after)&&scope.kind==='schema'&&(value?.readOnly===true||value?.writeOnly===true))issue(scope,'migration.schema.direction','The 3.0 access annotations need a direction-specific required-property mapping in modern JSON Schema','implementation');
                if(before==='3.0'&&modernFamily(after)&&scope.kind==='schema'&&['binary','byte'].includes(value?.format))issue({...scope,pointer:scope.pointer+'/format'},'migration.schema.binary','Binary schemas need a media-aware modern content mapping','implementation');
                if(before==='3.2'&&after!=='3.2'){
                    const newer:Record<string,string[]>={root:['$self'], 'path-item':['query','additionalOperations'],media:['itemSchema','prefixEncoding','itemEncoding'],encoding:['prefixEncoding','itemEncoding'],tag:['summary','kind','parent'],xml:['nodeType'],discriminator:['defaultMapping']};
                    for(const name of newer[scope.kind]??[])if(Object.hasOwn(value??{},name))issue({...scope,pointer:scope.pointer+'/'+escape(name)},'migration.feature.newer','This 3.2 construct has no implemented faithful mapping to the selected older family','implementation');
                }
                if(before==='3.1'&&after==='3.0'&&scope.kind==='root'){
                    for(const name of ['webhooks'])if(Object.hasOwn(value??{},name))issue({...scope,pointer:'/'+name},'migration.root.newer','This root construct needs an explicit faithful 3.0 mapping','implementation');
                }
            }
            if(problems.length)break;
            migrateSchemas(graph,sources,before,after,issue);
            migrateEncodings(graph,sources,before,after,issue);
            const referenceTargets=before==='2.0'?upgradeSwagger(graph,sources,issue):undefined;
            if(after==='2.0')downgradeSwagger(graph,sources,issue);
            if(problems.length)break;
            for(const [id,specification]of graph.specifications){
                const source=sources.get(id)!;
                if(!modernFamily(after))source.remove('/jsonSchemaDialect');
                if(after!=='2.0')source.set('/openapi',index===route.length-2?target.declaredVersion:patch[after]);
                if(before==='3.1'&&after==='3.2'&&!source.doc.nodes.has('/jsonSchemaDialect'))source.set('/jsonSchemaDialect',specification.schemaDialect);
            }
            // Repair only established contract references at their mapped CST
            // occurrences. Example and extension payloads are never searched.
            const retainedGraph=createGraph({...input,resources:resources.map(resource=>({...resource,text:sources.get(resource.id)!.doc.text}))}).graph;
            const retainedReferences=new Set(retainedGraph.references.filter(reference=>reference.resolution==='resolved').map(reference=>
                JSON.stringify([reference.resource,reference.pointer,reference.keyword,reference.value,reference.targetResource,reference.targetPointer])));
            for(const reference of graph.references){
                if(!['$ref','operationRef'].includes(reference.keyword)||reference.resolution!=='resolved')continue;
                const destinations=[...sources].flatMap(([id,source])=>[...(id===reference.targetResource?source.origins.get(reference.targetPointer!):source.foreignOrigins.get(reference.targetResource+'#'+reference.targetPointer!))??[]].map(pointer=>({resource:id,pointer})));
                const destination=referenceTargets?.get(reference.resource+'#'+reference.pointer)??(destinations.length===1?destinations[0]:undefined);
                for(const [id,source]of sources){
                    const locations=id===reference.resource?source.origins.get(reference.pointer+'/'+escape(reference.keyword)):source.foreignOrigins.get(reference.resource+'#'+reference.pointer+'/'+escape(reference.keyword));
                    for(const pointer of locations??[]){
                        if(destination===undefined){issue(reference,'migration.reference.target','An established target has no surviving mapped source owner','implementation');continue;}
                        // An unchanged locator with the same proved target
                        // needs no physical edit, including shared YAML text.
                        const owner=pointer.slice(0,pointer.lastIndexOf('/'));
                        if(source.doc.dataNode(pointer)?.value===reference.value&&retainedReferences.has(JSON.stringify([id,owner,reference.keyword,reference.value,destination.resource,destination.pointer])))continue;
                        source.set(pointer,destination.resource+fragment(destination.pointer));
                    }
                }
            }
            if(problems.length)break;
            const next=new Map<string,MigrationLocation[]>();
            for(const [origin,locations]of origins){
                const mapped:MigrationLocation[]=[];
                for(const location of locations)for(const [id,source]of sources){
                    const values=id===location.resource?source.origins.get(location.pointer):source.foreignOrigins.get(location.resource+'#'+location.pointer);
                    for(const pointer of values??[])mapped.push({resource:id,pointer});
                }
                next.set(origin,mapped);
            }
            origins=next;
            for(const [resource,source]of sources)for(const pointer of source.presentationChanges)presentationChanges.push({resource,pointer});
            resources=resources.map(resource=>({...resource,text:sources.get(resource.id)!.doc.text}));
            stages.push({from:before,to:after});await validate(resources,input.root);
        }catch(error){
            refused(error,{resource:input.root,pointer:''});
        }
    }
    const status=():MigrationDisposition=>problems.some(problem=>problem.reason!=='decision')?'blocked':problems.length?'requires-decision':'faithfully-convertible';
    const common=()=>{
        for(const [id,choice]of Object.entries(decisions)) {
            if(!decisionChoices.has(id))throw new SourceError('migration.decisions.stale','A supplied decision does not belong to this captured migration graph and target');
            if(!decisionChoices.get(id)!.includes(String(choice)))throw new SourceError('migration.decisions.choice','Choose a listed migration decision');
        }
        return ({version:1,snapshot:input.snapshot,producer:'busyapi-native-migration',producerVersion:migrationProducerVersion,from,target,stages,status:status(),complete:!problems.length,problems,acceptedDecisions:[...accepted],presentationChanges,
        affectedResources:resources.map(resource=>({resource:resource.id,generation:resource.generation,identity:resource.identity})),coverage:{source:'captured-native-graph',target:'native-structure-and-schema-evaluation',externalConsumers:'Only captured resources and their established connections are known'}});
    };
    if(problems.length)return {...common(),changes:[],outputs:[]};
    if(start===finish)try{
        const source=new MigrationSource(createGraph({...input,resources}).docs.get(input.root)!);
        source.set(target.declaration==='swagger'?'/swagger':'/openapi',target.declaredVersion);
        resources=resources.map(resource=>resource.id===input.root?{...resource,text:source.doc.text}:resource);
    }catch(error){refused(error,{resource:input.root,pointer:''});}
    if(problems.length)return {...common(),changes:[],outputs:[]};
    const context=createGraph({...input,resources}),sources=new Map([...context.docs].map(([id,doc])=>[id,new MigrationSource(doc)]));
    try {
        for(const scope of context.graph.scopes.values()){
            const source=sources.get(scope.resource)!,value=context.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
            if(scope.kind==='schema'&&typeof value?.$id==='string')source.set(scope.pointer+'/$id',scope.base);
            if(scope.kind==='root'&&scope.family==='3.2'&&typeof value?.$self==='string')source.set('/$self',scope.base);
            if(typeof value?.description==='string'&&hasRelativeMarkdownLinks(value.description))issue({...scope,pointer:scope.pointer+'/description'},'migration.description.relative-links','Relative documentation links need a source-context-preserving relocation','implementation');
            if(scope.kind==='server'&&typeof value?.url==='string')source.set(scope.pointer+'/url',serverTemplate(value.url,documentUriBase(context.graph,scope),value.variables));
        }
        for(const occurrence of documentUriOccurrences(context.graph))if(occurrence.scope.kind!=='server')sources.get(occurrence.scope.resource)!.set(occurrence.pointer,resolveUri(occurrence.value,documentUriBase(context.graph,occurrence.scope)).href);
        for(const reference of context.graph.references)if(['$ref','$dynamicRef','operationRef'].includes(reference.keyword)&&reference.resolution==='resolved')sources.get(reference.resource)!.set(reference.pointer+'/'+escape(reference.keyword),resolveUri(reference.value,reference.base).href);
    }catch(error){refused(error,{resource:input.root,pointer:''});}
    if(problems.length)return {...common(),changes:[],outputs:[]};
    const paths=new Map(resources.map(resource=>[resource.id,(resource.id===input.root?'openapi':'resources/'+digest(resource.id).slice(0,24))+'.'+sources.get(resource.id)!.doc.format]));
    const identifiers=new Map([...paths].map(([id,path])=>[id,new URL(path,input.destination).href]));
    for(const [source,destination]of identifiers)relocatedResources.set(destination,source);
    if([...identifiers.values()].some(id=>context.graph.identities.has(id)))throw new SourceError('migration.destination','The output would replace a captured source identity');
    // Ordinary copied documents use their new retrieval location. Explicit
    // $id/$self identities and approved aliases remain available separately;
    // an optional project mapping must not be needed for a local self-reference.
    const outputResources=resources.map(resource=>({...resource,id:identifiers.get(resource.id)!,text:sources.get(resource.id)!.doc.text,aliases:[identifiers.get(resource.id)!,resource.id,...resource.aliases??[]],generation:0}));
    const outputRoot=identifiers.get(input.root)!;
    const relocated=createGraph({...input,root:outputRoot,resources:outputResources});
    const mappings=new Map([...paths].map(([id,path])=>[identifiers.get(id)!,path]));
    for(const scope of relocated.graph.scopes.values())if(scope.pointer===''){
        const value=relocated.docs.get(scope.resource)!.root.value;
        const declared=scope.kind==='schema'&&typeof value?.$id==='string'||scope.kind==='root'&&scope.family==='3.2'&&typeof value?.$self==='string';
        const path=[...paths].find(([id])=>identifiers.get(id)===scope.resource)?.[1];
        if(declared&&path)mappings.set(scope.base,path);
    }
    if(mappings.size>256)issue({resource:input.root,pointer:''},'limit.migration.mappings','The migrated identity map exceeds the configured 256 URI mappings','source-incomplete');
    if(problems.length)return {...common(),changes:[],outputs:[]};
    const coldResources=()=>outputResources.map(resource=>({...resource,aliases:[...mappings].filter(([,path])=>new URL(path,input.destination).href===resource.id).map(([uri])=>uri).sort()}));
    // Prove retained static spellings without transient source-file aliases.
    // The final cold proof below still checks every repaired connection.
    const portable=coldGraph(outputRoot,coldResources());
    const portableReferences=new Set(portable.references.filter(reference=>reference.resolution==='resolved'&&reference.keyword!=='$dynamicRef').map(reference=>
        JSON.stringify([reference.resource,reference.pointer,reference.keyword,reference.value,reference.targetResource,reference.targetPointer])));
    for(const reference of relocated.graph.references){
        if(!['$ref','$dynamicRef','operationRef'].includes(reference.keyword)||reference.resolution!=='resolved')continue;
        if(portableReferences.has(JSON.stringify([reference.resource,reference.pointer,reference.keyword,reference.value,reference.targetResource,reference.targetPointer])))continue;
        const scope=relocated.graph.scope(reference.resource,reference.pointer),destination=relocated.graph.scopes.get(reference.targetResource!+'#'+reference.targetPointer!);
        const value=destination&&referenceValue(relocated.graph,scope,destination,reference.keyword);
        const location={resource:reference.resource,pointer:reference.pointer+'/'+escape(reference.keyword)};
        if(value===undefined){issue(location,'migration.reference.relocation','A captured reference has no proved portable target spelling','implementation');continue;}
        if(value===reference.value)continue;
        const source=outputResources.find(resource=>resource.id===reference.resource)!;
        try{const doc=new SourceDocument(source.text,source.id);source.text=doc.set(location.pointer,value);}
        catch(error){refused(error,location);}
    }
    if(problems.length)return {...common(),changes:[],outputs:[]};
    await validate(outputResources,outputRoot);
    const finalContext=createGraph({...input,root:outputRoot,resources:outputResources});
    const operationKeys=(graph:typeof initial.graph)=>graph.operations().map(operation=>JSON.stringify([operation.role,operation.method,operation.customMethod===true,operation.path])).sort();
    if(JSON.stringify(operationKeys(initial.graph))!==JSON.stringify(operationKeys(finalContext.graph)))issue({resource:input.root,pointer:''},'migration.invariant.operations','The migrated graph changed an operation method, path, role or occurrence count','implementation');
    try {
        if(JSON.stringify(migrationRequestSignatures(initial.graph,input.resources))!==JSON.stringify(migrationRequestSignatures(finalContext.graph,outputResources)))issue({resource:input.root,pointer:''},'migration.invariant.request','The migrated graph changed effective URL, serialization, authentication, request media or response declarations','implementation');
    }catch(error){
        if(!(error instanceof SourceError))throw error;
        issue({resource:input.root,pointer:''},error.code,'Request invariants could not be established for this migration','implementation');
    }
    const exactPayloads=new Set<string>();
    for(const scope of initial.graph.scopes.values()){
        const doc=original.get(scope.resource)!,node=doc.dataNode(scope.pointer)!;
        for(const name of Object.keys(node.value??{}))if(name.startsWith('x-'))exactPayloads.add(key(scope.resource,scope.pointer+'/'+escape(name)));
        const fields=scope.kind==='example'?['value','dataValue','serializedValue']:scope.kind==='schema'?['example','default','enum']:['media','parameter','header'].includes(scope.kind)?['example']:[];
        for(const name of fields)if(node.children.has(name))exactPayloads.add(key(scope.resource,scope.pointer+'/'+name));
        if(scope.family==='2.0'&&scope.kind==='response')for(const name of doc.dataNode(scope.pointer+'/examples')?.children.keys()??[])exactPayloads.add(key(scope.resource,scope.pointer+'/examples/'+escape(name)));
    }
    for(const origin of exactPayloads){
        const [resource,pointer]=JSON.parse(origin) as [string,string],expected=migrationValueIdentity(original.get(resource)!,pointer),locations=origins.get(origin)??[];
        // Only an explicit, graph-bound omission decision can remove values
        // inside an ignored declaration. Originals remain independent inputs.
        if(ignoredBodyOmissions.some(location=>location.resource===resource&&(pointer===location.pointer||pointer.startsWith(location.pointer+'/'))))continue;
        if(!locations.length)issue({resource,pointer},'migration.invariant.payload','An authored payload or extension lost its captured source owner','implementation');
        for(const location of locations){
            const node=finalContext.docs.get(identifiers.get(location.resource)!)?.dataNode(location.pointer);
            if(!node||migrationValueIdentity(finalContext.docs.get(identifiers.get(location.resource)!)!,location.pointer)!==expected)issue({resource,pointer},'migration.invariant.payload','An authored payload, default, enum or extension changed its exact value','implementation');
        }
    }
    if(problems.length)return {...common(),changes:[],outputs:[]};
    // Cold reopen proves that relative files and explicit identity mappings are
    // sufficient; no original-source disk access is a migration dependency.
    // Core sorts approved mappings before choosing a retrieval identity. Prove
    // the delivered manifest with that same ordering, not transient old aliases.
    const reopened=coldGraph(outputRoot,coldResources());
    if(reopened.issues.length)issue({resource:input.root,pointer:''},'migration.reference.cold-reopen','The copied files and root identity mappings cannot reopen every captured dependency; a nested-resource relocation needs an additional mapping','implementation');
    if(problems.length)return {...common(),changes:[],outputs:[]};
    const manifest={version:1,roots:[{name:'migrated',path:paths.get(input.root)}],resourceMappings:Object.fromEntries(mappings)};
    const outputs=outputResources.map(resource=>({path:[...paths].find(([id])=>identifiers.get(id)===resource.id)![1],id:resource.id,text:resource.text,hasBom:input.resources.find((source:Resource)=>identifiers.get(source.id)===resource.id)?.hasBom===true,identity:digest(resource.text)}));
    const changes=resources.map(resource=>({resource:resource.id,destination:identifiers.get(resource.id),before:original.get(resource.id)!.text,after:outputResources.find(output=>output.id===identifiers.get(resource.id))!.text}));
    for(const decision of Object.keys(decisions))if(!accepted.has(decision))throw new SourceError('migration.decisions.stale','A supplied decision does not belong to this captured migration plan');
    return {...common(),entry:paths.get(input.root),outputRoot,outputs,changes,manifest,identity:digest(JSON.stringify([migrationProducerVersion,input.snapshot,target,outputs,manifest,decisions])),validation:{complete:true,family:target.family},invariants:{operations:'preserved-method-and-path',requests:'effective-url-serialization-security-and-media',references:'canonical-target-relocation',examples:'exact-cst-values'}};
}
