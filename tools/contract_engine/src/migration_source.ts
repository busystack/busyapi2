import {SourceDocument,SourceError,escape,segments,RawJsonValue} from './document';

export type MigrationLocation={resource:string;pointer:string};
const inside=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');
export function migrationValueIdentity(doc:SourceDocument,pointer:string):string {
    const node=doc.dataNode(pointer)!;
    if(node.kind==='object')return '{'+[...node.children].map(([name,child])=>JSON.stringify(name)+':'+migrationValueIdentity(doc,child.pointer)).join(',')+'}';
    if(node.kind==='array')return '['+[...node.children.values()].map(child=>migrationValueIdentity(doc,child.pointer)).join(',')+']';
    return typeof node.value==='number'?doc.dataJson(pointer).trim():JSON.stringify(node.value);
}

/** Mutable planning copies of the existing CST, never live source buffers.
 * Original coordinates remain attached to every surviving/moved occurrence. */
export class MigrationSource {
    doc:SourceDocument;
    readonly origins=new Map<string,Set<string>>();
    readonly foreignOrigins=new Map<string,Set<string>>();
    readonly presentationChanges:string[]=[];
    constructor(readonly original:SourceDocument) {
        this.doc=new SourceDocument(original.text,original.id);
        for(const pointer of original.nodes.keys())this.origins.set(pointer,new Set([pointer]));
    }
    current(pointer:string):string|undefined{return this.origins.get(pointer)?.values().next().value;}
    *originSets():Generator<Set<string>>{yield* this.origins.values();yield* this.foreignOrigins.values();}
    private blockParent(pointer:string):boolean {
        let at=pointer;
        while(at){at=at.slice(0,at.lastIndexOf('/'));if(this.doc.nodes.get(at)?.flow)return false;}
        return true;
    }
    private update(text:string){this.doc=new SourceDocument(text,this.original.id);if(this.doc.issues.length)throw new SourceError('migration.syntax','The planned CST change is ambiguous');}
    ensure(pointer:string):void {
        if(this.doc.nodes.has(pointer))return;
        const parts=segments(pointer);parts.pop();const parent=parts.length?'/'+parts.map(escape).join('/'):'';
        this.ensure(parent);
        const owner=this.doc.node(parent);
        if(this.doc.format==='yaml'&&owner.flow&&!owner.children.size&&this.blockParent(parent)){
            const inline=this.doc.text.slice(this.doc.lineStart(owner.range[0]),owner.range[0]).trim()!=='';
            this.update(this.doc.replace(...owner.range,(inline?this.doc.newline+' '.repeat(this.doc.indent(owner.range[0])+2):'')+JSON.stringify(segments(pointer).at(-1)!)+': {}'));
        }
        else this.update(this.doc.set(pointer,{}));
    }
    set(pointer:string,value:unknown):void {
        const parts=segments(pointer);parts.pop();this.ensure(parts.length?'/'+parts.map(escape).join('/'):'');
        this.update(this.doc.set(pointer,value));
    }
    exact(pointer:string,text:string):void{this.set(pointer,new RawJsonValue(text));}
    remove(pointer:string,retire=true):void {
        if(!this.doc.nodes.has(pointer))return;
        const authored=this.doc.node(pointer),keyAt=authored.keyRange?.[0];
        let comment:string|undefined,commentAt:number|undefined;
        if(this.doc.format==='yaml'&&keyAt!==undefined){
            const start=this.doc.lineStart(keyAt),prefix=this.doc.text.slice(start,keyAt);
            const line=(at:number)=>this.doc.text.slice(at).split(/\r\n|\r|\n/,1)[0];
            if(/^ *$/.test(prefix)){
                const keyComment=/^:[ \t]*(#[^\r\n]*)/.exec(line(authored.keyRange![1]));
                const valueComment=/^[ \t]*(#[^\r\n]*)/.exec(line(authored.range[1]));
                const comments=[...new Set([keyComment?.[1],valueComment?.[1]].filter((value):value is string=>value!==undefined))];
                if(comments.length){comment=comments.map(value=>prefix+value+this.doc.newline).join('');commentAt=start;}
            }
        }
        const parts=segments(pointer),name=parts.pop()!,parent=parts.length?'/'+parts.map(escape).join('/'):'',array=this.doc.node(parent).kind==='array';
        let removed=this.doc.remove(pointer);
        if(comment!==undefined&&commentAt!==undefined)removed=removed.slice(0,commentAt)+comment+removed.slice(commentAt);
        this.update(removed);
        for(const values of this.originSets())for(const at of [...values]){
            if(inside(at,pointer)){if(retire)values.delete(at);continue;}
            if(array&&inside(at,parent)&&at!==parent){const tail=at.slice(parent.length+1).split('/'),index=Number(tail[0]);if(index>Number(name)){values.delete(at);values.add(parent+'/'+(index-1)+(tail.length>1?'/'+tail.slice(1).join('/'):''));}}
        }
    }
    rename(pointer:string,name:string):string {
        const node=this.doc.node(pointer),parts=segments(pointer);parts.pop();
        const to=(parts.length?'/'+parts.map(escape).join('/'):'')+'/'+escape(name);
        if(this.doc.nodes.has(to))throw new SourceError('migration.collision','A mapped field already exists at '+to,node.range);
        if(node.shared||node.keyShared||!node.keyRange)throw new SourceError('migration.shared','This key has shared or ambiguous ownership',node.range);
        this.update(this.doc.replace(...node.keyRange,this.doc.emit(name,undefined,true)));
        for(const values of this.originSets())for(const at of [...values])if(inside(at,pointer)){values.delete(at);values.add(to+at.slice(pointer.length));}
        return to;
    }
    copy(source:MigrationSource,from:string,to:string):void {
        const before=source.doc,node=before.node(from);before.assertSafe(from);
        const copied=[...[...source.origins].map(([origin,values])=>({origin:source.original.id+'#'+origin,values})),...[...source.foreignOrigins].map(([origin,values])=>({origin,values}))]
            .flatMap(({origin,values})=>[...values].filter(at=>inside(at,from)).map(at=>({origin,pointer:to+at.slice(from.length)})));
        const parts=segments(to),name=parts.pop()!,parent=parts.length?'/'+parts.map(escape).join('/'):'',expected=before.dataJson(from),identity=migrationValueIdentity(before,from);
        this.ensure(parent);
        if(this.doc.nodes.has(to))throw new SourceError('migration.collision','A migration destination already exists at '+to);
        const owner=this.doc.node(parent),block=before.format==='yaml'&&!node.flow&&(node.kind==='object'||node.kind==='array');
        // Collection ranges begin at their first value token. Comments between
        // the entry key and that token still belong to the copied occurrence.
        const leading=before.format==='yaml'?before.comments(from,true).filter(range=>range[1]<=node.range[0]).map(range=>before.text.slice(...range)):[];
        if(this.doc.format==='yaml'&&(!owner.flow||owner.children.size===0)&&this.blockParent(parent)&&block){
            const raw=before.text.slice(...node.range),indent=before.indent(node.range[0]);
            const local=(leading.length?leading.join(this.doc.newline)+this.doc.newline:'')+raw.replace(/(?:\r\n|\r|\n)([ \t]*)/g,(_match,space)=>this.doc.newline+space.slice(Math.min(indent,space.length)));
            const inline=this.doc.text.slice(this.doc.lineStart(owner.range[0]),owner.range[0]).trim()!=='';
            const depth=this.doc.indent(owner.range[0]),entryIndent=depth+(owner.flow&&inline?2:0);
            if(owner.flow&&owner.children.size===0){
                const text=JSON.stringify(name)+':'+this.doc.newline+' '.repeat(entryIndent+2)+local.replaceAll(this.doc.newline,this.doc.newline+' '.repeat(entryIndent+2));
                this.update(this.doc.replace(...owner.range,(inline?this.doc.newline+' '.repeat(entryIndent):'')+text));
            }else{
                this.set(to,null);const slot=this.doc.node(to),depth=this.doc.indent(slot.range[0]);
                this.update(this.doc.replace(...slot.range,this.doc.newline+' '.repeat(depth+2)+local.replaceAll(this.doc.newline,this.doc.newline+' '.repeat(depth+2))));
            }
        }else if(before.format===this.doc.format&&!block){
            this.set(to,null);const slot=this.doc.node(to),raw=before.text.slice(...node.range);
            const indent=before.indent(node.range[0]),depth=this.doc.indent(slot.range[0]);
            const adjusted=(leading.length?leading.join(this.doc.newline+' '.repeat(depth+2))+this.doc.newline+' '.repeat(depth+2):'')+raw.replace(/(?:\r\n|\r|\n)([ \t]*)/g,(_match,space)=>this.doc.newline+' '.repeat(depth)+space.slice(Math.min(indent,space.length)));
            this.update(this.doc.replace(...slot.range,adjusted));
        }else{
            this.exact(to,expected);this.presentationChanges.push(to);
        }
        if(migrationValueIdentity(this.doc,to)!==identity)throw new SourceError('migration.fidelity','The mapped value changed its exact source meaning at '+to);
        for(const {origin,pointer}of copied){
            const own=origin.startsWith(this.original.id+'#'),map=own?this.origins:this.foreignOrigins,key=own?origin.slice(this.original.id.length+1):origin;
            const values=map.get(key)??new Set<string>();values.add(pointer);map.set(key,values);
        }
    }
    move(from:string,to:string):void {
        if(from===to)return;
        this.copy(this,from,to);
        for(const values of this.originSets())for(const at of [...values])if(inside(at,from)){values.delete(at);values.add(to+at.slice(from.length));}
        this.remove(from,false);
    }
}
