import {SourceDocument,SourceError,type Node,type Range} from './document';

type Ownership=Readonly<{document:SourceDocument;changed:readonly string[]}>;
const inside=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');

/** Give an explicit migration edit independent YAML ownership. Only captured
 * anchor-property and alias-value tokens change. Alias bindings use node
 * identity, including reused names and key anchors; no text search resolves
 * them. All other logical values must remain exactly equal before editing. */
export function migrationYamlOwnership(doc:SourceDocument,pointer:string,descendants=true,includeKey=false):Ownership {
    if(doc.format!=='yaml')return {document:doc,changed:[]};
    const anchors=doc.sourceAnchors().filter(anchor=>anchor.node.key
        ?includeKey&&anchor.node.pointer===pointer||descendants&&anchor.node.pointer!==pointer&&inside(anchor.node.pointer,pointer)
        :inside(pointer,anchor.node.pointer)||descendants&&inside(anchor.node.pointer,pointer));
    const definitions=new Set(anchors.map(anchor=>anchor.node));
    const aliases=[...doc.nodes.values()].filter(node=>node.alias&&
        (inside(pointer,node.pointer)||definitions.has(node.alias)));
    if(!anchors.length&&!aliases.length)return {document:doc,changed:[]};
    const fail=(at:string,message:string,range:Range=doc.dataNode(at)?.range??doc.root.range):never=>{
        throw new SourceError('migration.yaml.ownership',message,range,'unsupported',{resource:doc.id,pointer:at,range});
    };
    doc.assertSafe(pointer);
    const edits:{pointer:string;range:Range;replacement:string}[]=[],changed=new Set<string>();
    let bytes=0;
    for(const anchor of anchors){
        if(!anchor.range||doc.text.slice(...anchor.range)!=='&'+anchor.name)
            fail(anchor.node.pointer,'The captured anchor has no unique concrete-syntax property token');
        doc.assertSafe(anchor.node.pointer);
        edits.push({pointer:anchor.node.pointer,range:anchor.range,replacement:''});changed.add(anchor.node.pointer);
    }
    for(const alias of aliases){
        doc.assertSafe(alias.pointer);
        const replacement=doc.dataJson(alias.pointer);
        if((bytes+=Buffer.byteLength(replacement))>8*1024*1024)
            throw new SourceError('limit.migration.yaml','Alias ownership copies exceed 8 MiB',alias.range,'unsupported',{resource:doc.id,pointer:alias.pointer,range:alias.range});
        edits.push({pointer:alias.pointer,range:alias.range,replacement});changed.add(alias.pointer);
    }
    if(edits.length>4096)throw new SourceError('limit.migration.yaml','Alias ownership needs more than 4096 token replacements');
    const expected=doc.dataJson('');
    let text=doc.text,previous=text.length;
    for(const edit of edits.sort((left,right)=>right.range[0]-left.range[0])){
        if(edit.range[1]>previous)fail(edit.pointer,'Anchor and alias ownership changes overlap',edit.range);
        previous=edit.range[0];
        text=text.slice(0,edit.range[0])+edit.replacement+text.slice(edit.range[1]);
    }
    const result=new SourceDocument(text,doc.id);
    if(result.issues.length||result.dataJson('')!==expected)
        fail(pointer,'Separating YAML ownership changed another exact logical data value');
    return {document:result,changed:[...changed]};
}

/** Alias-expanded paths keep their logical source owner through later CST
 * moves and copies. Reading provenance does not make virtual nodes editable. */
export function migrationLogicalPointers(doc:SourceDocument):readonly string[] {
    if(![...doc.nodes.values()].some(node=>node.alias))return [...doc.nodes.keys()];
    const pointers=new Set(doc.nodes.keys());
    doc.dataJson('',(_node:Node,pointer:string)=>{pointers.add(pointer);return undefined;});
    return [...pointers];
}
