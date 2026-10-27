import {documentUriValidity} from './document_uris';
import {documentUriBase,resolveUri,type GraphScope,type ReferenceGraph} from './reference_graph';
import type {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';

/** Terms links change from Server-relative URLs in 3.0 (§4.6) to document
 * URIs in 3.1 (§4.6). Capture their meaning before changing family. Distinct
 * Server choices cannot be collapsed to one arbitrary default URI. */
export function migrateTerms(graph:ReferenceGraph,sources:Map<string,MigrationSource>,families:readonly string[],captured:Map<string,string>,issue:MigrationIssue):void {
    for(const scope of graph.scopes.values()){
        if(scope.kind!=='info'||scope.family==='2.0'||!families.includes(scope.family))continue;
        const value=graph.docs.get(scope.resource)!.dataNode(scope.pointer)?.value?.termsOfService;
        if(typeof value!=='string'||/^[A-Za-z][A-Za-z0-9+.-]*:/u.test(value))continue;
        const location={...scope,pointer:scope.pointer+'/termsOfService'},targets=new Set<string>();
        let incomplete=false,work=0;
        if(scope.family==='3.0'){
            const doc=graph.docs.get(scope.resource)!,servers=doc.root.value?.servers;
            const choices=Array.isArray(servers)&&servers.length?servers:[{url:'/'}];
            for(const [index,server]of choices.entries()){
                const urls=serverChoices(server,{...scope,pointer:'/servers/'+index+'/url'},issue);
                if(!urls){incomplete=true;continue;}
                for(const url of urls){
                    if(++work>1024){issue(location,'limit.migration.terms-bases','Terms of Service resolution exceeds 1024 captured Server choices','implementation');incomplete=true;break;}
                    const base=resolveUri(url,graph.retrievals.get(scope.resource)!).href;
                    targets.add(resolveUri(value,base).href);
                }
                if(work>1024)break;
            }
        }else targets.add(resolveUri(value,documentUriBase(graph,scope)).href);
        if(incomplete)continue;
        if(targets.size!==1){
            issue(location,'migration.info.terms-bases',targets.size?'The source Terms of Service URL has different destinations for its Server choices; one target URI cannot retain them all':'The source Terms of Service URL has no proved Server base','target-representation');continue;
        }
        const uri=[...targets][0],key=JSON.stringify([scope.resource,location.pointer]),prior=captured.get(key);
        if(prior!==undefined&&prior!==uri){issue(location,'migration.info.terms-contexts','This shared Terms of Service field has different destinations in captured descriptions','implementation');continue;}
        captured.set(key,uri);sources.get(scope.resource)!.set(location.pointer,uri);
    }
}

/** Finite declared Server choices are exhaustive. An unrestricted variable
 * is not replaced by its default to claim a faithful conversion. */
function serverChoices(server:unknown,location:GraphScope,issue:MigrationIssue):readonly string[]|undefined {
    if(server===null||typeof server!=='object'||!('url' in server)||typeof server.url!=='string'){
        issue(location,'migration.info.terms-server','The Terms of Service Server URL is unavailable','source-incomplete');return;
    }
    const url=server.url,names=[...new Set([...url.matchAll(/\{([^{}]+)\}/gu)].map(match=>match[1]))];
    const variables='variables' in server&&server.variables!==null&&typeof server.variables==='object'?server.variables:undefined;
    let choices:ReadonlyMap<string,string>[]=[new Map()];
    for(const name of names){
        const variable=variables&&Object.hasOwn(variables,name)?Reflect.get(variables,name):undefined;
        const values=variable!==null&&typeof variable==='object'&&'enum' in variable?variable.enum:undefined;
        if(Array.isArray(values)&&choices.length*values.length>256){issue(location,'limit.migration.terms-servers','Terms of Service resolution exceeds 256 declared Server variable combinations','implementation');return;}
        if(!Array.isArray(values)||!values.length||values.some(value=>typeof value!=='string')){
            issue(location,'migration.info.terms-server-variable','A Terms of Service Server variable has no exhaustive declared enum; its default does not prove one destination','implementation');return;
        }
        choices=choices.flatMap(choice=>values.map(value=>new Map([...choice,[name,value]])));
    }
    const urls=choices.map(choice=>url.replace(/\{([^{}]+)\}/gu,(_match,name)=>choice.get(name)!));
    for(const url of urls){
        const validity=documentUriValidity(url);
        if(validity!=='valid'){
            issue(location,'migration.info.terms-server-uri','The Terms of Service Server URL cannot be resolved with the captured URI evaluator',validity==='unsupported'?'implementation':'source-incomplete');return;
        }
    }
    return urls;
}
