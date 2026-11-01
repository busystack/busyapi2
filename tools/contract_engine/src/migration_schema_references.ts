import {escape} from './document';
import type {GraphReference,GraphScope,ReferenceGraph} from './reference_graph';
import type {MigrationIssue} from './migration_schema';
import type {MigrationSource} from './migration_source';

/** JSON Schema Core 8.2.3.2 gives a $dynamicRef with no dynamic-anchor
 * starting point exactly the assertions of $ref. Older OAS Reference Objects
 * ignore siblings, so retain the applicator in its own allOf branch. */
export class MigrationSchemaReferences {
    private readonly references=new Map<string,GraphReference>();
    constructor(graph:ReferenceGraph){
        for(const reference of graph.references)if(reference.kind==='schema'&&reference.keyword==='$dynamicRef'&&!reference.connection)
            this.references.set(JSON.stringify([reference.resource,reference.pointer]),reference);
    }
    lower(scope:GraphScope,source:MigrationSource,pointer:string,issue:MigrationIssue):void {
        if(!source.doc.nodes.has(pointer+'/$dynamicRef'))return;
        const location={...scope,pointer:scope.pointer+'/'+escape('$dynamicRef')};
        const reference=this.references.get(JSON.stringify([scope.resource,scope.pointer]));
        if(!reference||reference.resolution!=='resolved'){
            issue(location,'migration.schema.dynamic-reference','The captured schema reference must resolve before conversion to an older family','source-incomplete');return;
        }
        if(reference.dynamic){
            issue(location,'migration.schema.dynamic-reference','This reference starts at a dynamic anchor; a faithful older-family dynamic-scope mapping is not implemented','implementation');return;
        }
        const allOf=pointer+'/allOf';
        if(!source.doc.nodes.has(allOf))source.set(allOf,[]);
        const branch=allOf+'/'+source.doc.node(allOf).children.size;
        source.set(branch,{});
        source.move(pointer+'/$dynamicRef',branch+'/$ref');
    }
}
