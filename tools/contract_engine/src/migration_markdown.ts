import {richTextField} from './authoring';
import {segments,SourceDocument,SourceError} from './document';
import {relativeMarkdownDestinations} from './markdown_links';
import {relocateMarkdownLinks} from './markdown_relocation';
import type {MigrationLocation} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {documentUriBase,type GraphScope,type ReferenceGraph} from './reference_graph';

type CapturedMarkdown=Readonly<{
    original:MigrationLocation;
    owner:MigrationLocation;
    value:string;
    base:string;
    literal:boolean;
}>;
type Mapped=(original:MigrationLocation)=>readonly MigrationLocation[];
type Target=Readonly<{source:CapturedMarkdown;location:MigrationLocation;scope:GraphScope;value:string}>;
const key=(location:MigrationLocation)=>JSON.stringify([location.resource,location.pointer]);
function description(graph:ReferenceGraph,scope:GraphScope) {
    const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
    return typeof value?.description==='string'&&richTextField(scope.kind,scope.family,value,'description',segments(scope.pointer).at(-1)??'',graph.allowsReference(scope))
        ?doc.dataNode(scope.pointer+'/description'):undefined;
}

/** Capture rendered context before conversion changes identities or hoists an
 * object. Physical scalar provenance does not replace a logical URI base. */
export function captureMigrationMarkdown(graph:ReferenceGraph,issue:MigrationIssue):readonly CapturedMarkdown[] {
    const captured:CapturedMarkdown[]=[];
    for(const scope of graph.scopes.values()){
        const field=description(graph,scope);if(!field)continue;
        const original={resource:scope.resource,pointer:field.pointer};
        try{
            if(relativeMarkdownDestinations(field.value).length)captured.push({
                original,owner:{resource:scope.resource,pointer:scope.pointer},value:field.value,
                base:documentUriBase(graph,scope),
                literal:graph.literalContainer(scope.resource,scope.pointer+'/description')!==undefined,
            });
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue({...original,original},error.code,error.message,'source-incomplete');
        }
    }
    return captured;
}

function targets(captured:readonly CapturedMarkdown[],graph:ReferenceGraph,mapped:Mapped,issue:MigrationIssue):Target[] {
    const owners=new Map<string,GraphScope[]>(),result:Target[]=[];
    for(const scope of graph.scopes.values()){
        const field=description(graph,scope);if(!field)continue;
        const identity=key({resource:scope.resource,pointer:field.pointer}),values=owners.get(identity)??[];
        values.push(scope);owners.set(identity,values);
    }
    for(const source of captured){
        const ownerLocations=mapped(source.owner);
        for(const location of mapped(source.original)){
            const field=graph.docs.get(location.resource)?.dataNode(location.pointer);
            const candidates=field?owners.get(key({resource:location.resource,pointer:field.pointer}))??[]:[];
            const selected=ownerLocations.length?candidates.filter(scope=>ownerLocations.some(owner=>owner.resource===scope.resource&&owner.pointer===scope.pointer)):candidates;
            if(!selected.length||typeof field?.value!=='string'){
                issue({...location,original:source.original},'migration.description.context','The original documentation has no proved surviving rendered context','implementation');
                continue;
            }
            for(const scope of selected)result.push({source,location:{resource:location.resource,pointer:field.pointer},scope,value:field.value});
        }
    }
    return result;
}

/** Produce planning-copy CST edits, then prove the same rendered tree and
 * destinations. Shared/literal owners need specialization rather than an
 * annotation edit that would change another occurrence's data value. */
export function rewriteMigrationMarkdown(captured:readonly CapturedMarkdown[],graph:ReferenceGraph,mapped:Mapped,issue:MigrationIssue,
    changed:(location:MigrationLocation)=>void):ReadonlyMap<string,SourceDocument> {
    const desired=new Map<string,{target:Target;value:string}>(),documents=new Map<string,SourceDocument>();
    for(const target of targets(captured,graph,mapped,issue)){
        const {source,location,scope}=target,finding={...location,original:source.original};
        if(target.value!==source.value){
            issue(finding,'migration.description.context','The documentation text changed before its URI mapping could be established','implementation');
            continue;
        }
        try{
            const value=relocateMarkdownLinks(source.value,source.base,documentUriBase(graph,scope));
            if(value!==source.value&&(source.literal||graph.literalContainer(location.resource,location.pointer)!==undefined)){
                issue(finding,'migration.description.literal-context','This rendered description is also literal data; its occurrences need separate context ownership','implementation');
                continue;
            }
            const previous=desired.get(key(location));
            if(previous&&previous.value!==value){
                issue(finding,'migration.description.shared-context','One shared Markdown scalar needs different destination spellings for its surviving contexts','implementation');
                continue;
            }
            desired.set(key(location),{target,value});
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue(finding,error.code,error.message,error.code.startsWith('limit.')?'source-incomplete':'implementation');
        }
    }
    for(const {target,value}of desired.values()){
        if(value===target.value)continue;
        const {location,source}=target;
        try{
            const doc=documents.get(location.resource)??graph.docs.get(location.resource)!;
            doc.assertSafe(location.pointer);doc.assertUnshared(location.pointer);
            const text=doc.set(location.pointer,value);
            documents.set(location.resource,new SourceDocument(text,location.resource));
            changed(location);
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue({...location,original:source.original},error.code,error.message,'implementation');
        }
    }
    return documents;
}

export function proveMigrationMarkdown(captured:readonly CapturedMarkdown[],graph:ReferenceGraph,mapped:Mapped,issue:MigrationIssue):void {
    for(const {source,location,scope,value}of targets(captured,graph,mapped,issue)){
        try{
            if(value!==relocateMarkdownLinks(source.value,source.base,documentUriBase(graph,scope)))
                issue({...location,original:source.original},'migration.description.relative-links','The migrated Markdown has no complete source-context-preserving destination proof','implementation');
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue({...location,original:source.original},error.code,error.message,error.code.startsWith('limit.')?'source-incomplete':'implementation');
        }
    }
}
