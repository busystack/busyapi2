import {SourceDocument,SourceError,type Node} from './document';

type Specialization=Readonly<{document:SourceDocument;changed:readonly string[]}>;
const inside=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');

/** Explicit migration copies may split YAML aliases. Normal source editing
 * keeps its existing shared-node guards. Capture every affected alias before
 * changing its definition, preserve other logical data values, and prove the
 * entire exact-value projection after the bounded localized replacements. */
export function specializeMigrationText(doc:SourceDocument,requested:ReadonlyMap<string,string>):Specialization {
    const desired=new Map([...requested].filter(([pointer,value])=>doc.dataNode(pointer)?.value!==value));
    if(!desired.size)return {document:doc,changed:[]};
    const mutations=new Map<string,Node>();
    const fail=(pointer:string,message:string):never=>{
        const range=doc.dataNode(pointer)?.range??doc.root.range;
        throw new SourceError('migration.text.ownership',message,range,'unsupported',{resource:doc.id,pointer,range});
    };
    for(const [pointer]of desired){
        if(typeof doc.dataNode(pointer)?.value!=='string'||!doc.dataSyntaxSafe(pointer))
            fail(pointer,'The documentation specialization has no unambiguous captured string occurrence');
        const node=doc.nodes.get(pointer);
        if(node&&!node.alias){mutations.set(pointer,node);continue;}
        let owner=pointer;
        while(owner&&!doc.nodes.has(owner))owner=owner.slice(0,owner.lastIndexOf('/'));
        const alias=doc.nodes.get(owner);
        if(!alias?.alias)fail(pointer,'The documentation occurrence has no captured alias owner');
        mutations.set(owner,alias);
    }
    const aliases=[...doc.nodes.values()].filter(node=>node.alias);
    let work=0,expanded=0;
    let added=true;
    while(added){
        added=false;
        for(const alias of aliases){
            if(mutations.has(alias.pointer)||alias.alias!.key)continue;
            for(const pointer of mutations.keys()){
                if(++work>2000000)throw new SourceError('limit.migration.text','Shared documentation inspection exceeds its bounded captured-node work');
                if(!inside(pointer,alias.alias!.pointer))continue;
                mutations.set(alias.pointer,alias);added=true;break;
            }
        }
        if(mutations.size>4096)throw new SourceError('limit.migration.text','Shared documentation needs more than 4096 localized replacements');
    }
    const project=(_node:Node,occurrence:string)=>desired.has(occurrence)?JSON.stringify(desired.get(occurrence)):undefined;
    const expected=doc.dataJson('',project);
    const edits=[...mutations.values()].map(node=>{
        doc.assertSafe(node.pointer);
        const replacement=node.alias?doc.dataJson(node.pointer,project):doc.emit(desired.get(node.pointer)!,node,node.flow);
        if((expanded+=Buffer.byteLength(replacement))>8*1024*1024)
            throw new SourceError('limit.migration.text','Shared documentation replacements exceed 8 MiB');
        return {node,replacement};
    }).sort((left,right)=>right.node.range[0]-left.node.range[0]);
    let text=doc.text,previous=doc.text.length;
    for(const {node,replacement}of edits){
        if(node.range[1]>previous)fail(node.pointer,'Documentation specializations have overlapping physical source owners');
        previous=node.range[0];
        text=text.slice(0,node.range[0])+replacement+text.slice(node.range[1]);
    }
    const result=new SourceDocument(text,doc.id);
    if(result.issues.length||result.dataJson('',()=>undefined)!==expected)
        fail(edits[0].node.pointer,'The shared documentation mapping changed another exact data value');
    return {document:result,changed:[...mutations.keys()]};
}
