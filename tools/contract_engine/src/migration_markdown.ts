import {richTextField} from './authoring';
import {segments,SourceError} from './document';
import {relativeMarkdownDestinations} from './markdown_links';
import type {MigrationLocation} from './migration_source';
import type {MigrationIssue} from './migration_schema';
import {documentUriBase,resolveUri,type GraphScope,type ReferenceGraph} from './reference_graph';

type CapturedMarkdown={original:MigrationLocation;owner:MigrationLocation;value:string;base:string;destinations:readonly string[]};
const key=(location:MigrationLocation)=>JSON.stringify([location.resource,location.pointer]);
const description=(graph:ReferenceGraph,scope:GraphScope)=>{
    const doc=graph.docs.get(scope.resource)!,value=doc.dataNode(scope.pointer)?.value;
    return typeof value?.description==='string'&&richTextField(scope.kind,scope.family,value,'description',segments(scope.pointer).at(-1)??'',graph.allowsReference(scope))
        ?doc.dataNode(scope.pointer+'/description'):undefined;
};

/** Capture before structural conversion: removing an $id or hoisting a body
 * can change a description's context before final file relocation. Physical
 * scalar origins and logical owners are both needed for shared YAML nodes. */
export function captureMigrationMarkdown(graph:ReferenceGraph,issue:MigrationIssue):readonly CapturedMarkdown[] {
    const captured:CapturedMarkdown[]=[];
    for(const scope of graph.scopes.values()){
        const field=description(graph,scope);if(!field)continue;
        const original={resource:scope.resource,pointer:field.pointer};
        try{
            const destinations=relativeMarkdownDestinations(field.value);
            if(destinations.length)captured.push({original,owner:{resource:scope.resource,pointer:scope.pointer},value:field.value,base:documentUriBase(graph,scope),destinations});
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            issue({...original,original},error.code,error.message,'source-incomplete');
        }
    }
    return captured;
}

export function proveMigrationMarkdown(captured:readonly CapturedMarkdown[],target:ReferenceGraph,mapped:(original:MigrationLocation)=>readonly MigrationLocation[],issue:MigrationIssue):void {
    const owners=new Map<string,GraphScope[]>();
    for(const scope of target.scopes.values()){
        const field=description(target,scope);if(!field)continue;
        const id=key({resource:scope.resource,pointer:field.pointer}),values=owners.get(id)??[];
        values.push(scope);owners.set(id,values);
    }
    for(const source of captured){
        const ownerLocations=mapped(source.owner);
        // Explicitly removed declarations have no surviving rendered context.
        for(const location of mapped(source.original)){
            const field=target.docs.get(location.resource)?.dataNode(location.pointer);
            const candidates=field?owners.get(key({resource:location.resource,pointer:field.pointer}))??[]:[];
            const selected=ownerLocations.length?candidates.filter(scope=>ownerLocations.some(owner=>owner.resource===scope.resource&&owner.pointer===scope.pointer)):candidates;
            const finding={...location,original:source.original};
            if(!selected.length||field?.value!==source.value){
                issue(finding,'migration.description.context','The original documentation text has no proved surviving rendered context','implementation');continue;
            }
            for(const scope of selected){
                const base=documentUriBase(target,scope);
                if(base===source.base)continue;
                let unchanged:boolean;
                try{
                    unchanged=source.destinations.every(destination=>resolveUri(destination,source.base).href===resolveUri(destination,base).href);
                }catch(error){
                    if(!(error instanceof Error))throw error;
                    issue(finding,'migration.description.uri','A documentation link URI could not be resolved in its captured source and destination contexts','source-incomplete');continue;
                }
                if(!unchanged)issue(finding,'migration.description.relative-links','Relative documentation links need a source-context-preserving relocation','implementation');
            }
        }
    }
}
