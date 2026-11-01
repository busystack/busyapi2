import {escape} from './document';
import {FormSemantics} from './form_semantics';
import type {ReferenceGraph} from './reference_graph';
import type {MigrationIssue} from './migration_schema';
import {MigrationSource} from './migration_source';

/** OAS 3.0 §4.7.15 ignores multipart style fields. OAS 3.1 §4.8.15
 * activates them and ignores contentType instead. A declaration-only upgrade
 * would change request bytes even though both documents validate. */
export function migrateEncodings(graph:ReferenceGraph,sources:Map<string,MigrationSource>,from:string,to:string,issue:MigrationIssue):void {
    if(from!=='3.0'&&to!=='3.0')return;
    const forms=new FormSemantics(graph);
    for(const scope of graph.scopes.values())if(scope.kind==='media'&&scope.family===from){
        const content=scope.pointer.lastIndexOf('/content/');
        if(content<0||graph.scope(scope.resource,scope.pointer.slice(0,content)).kind!=='request-body')continue;
        const media=scope.pointer.slice(content+9).replaceAll('~1','/').replaceAll('~0','~').split(';')[0].trim().toLowerCase();
        if(!media.startsWith('multipart/'))continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value;
        if(!value?.encoding||typeof value.encoding!=='object')continue;
        const properties=forms.shape(scope.resource,scope.pointer+'/schema').properties??{};
        const source=sources.get(scope.resource)!;
        for(const [name,rule]of Object.entries(value.encoding)){
            if(!rule||typeof rule!=='object')continue;
            const fields=['style','explode','allowReserved'].filter(field=>Object.hasOwn(rule,field));
            if(!fields.length)continue;
            const pointer=scope.pointer+'/encoding/'+escape(name),at=source.current(pointer);
            if(at===undefined)continue;
            if(from==='3.0'){
                for(const field of fields)source.remove(at+'/'+field);
                continue;
            }
            // Other multipart media ignore these fields in both families.
            if(media!=='multipart/form-data')continue;
            const encoding=rule as Record<string,unknown>,shape=properties[name],types=shape?.types?.filter(type=>type!=='null');
            const type=types?.length===1?types[0]:undefined;
            const style=encoding.style??'form',explode=encoding.explode??(style==='form');
            const repeated=type==='array'&&style==='form'&&explode===true&&shape?.items?.types?.every(type=>['string','integer','number','boolean','null'].includes(type));
            if(type==='object'||type==='array'&&!repeated){
                issue({...scope,pointer},'migration.encoding.multipart','OpenAPI 3.0 ignores multipart style fields and cannot represent this structured part serialization','target-representation');
                continue;
            }
            if(type===undefined){
                issue({...scope,pointer},'migration.encoding.multipart-shape','The multipart field needs an unambiguous captured shape before a faithful content encoding can be planned','implementation');
                continue;
            }
            for(const field of fields)source.remove(at+'/'+field);
            source.set(at+'/contentType','text/plain');
        }
    }
}
