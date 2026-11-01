import {SourceDocument,SourceError,escape,segments,RawJsonValue} from './document';

export type MigrationLocation={resource:string;pointer:string};
const inside=(pointer:string,parent:string)=>pointer===parent||pointer.startsWith(parent+'/');
function outerCommentRanges(doc:SourceDocument,pointer:string,entryComments:boolean):[number,number][] {
    if(doc.format!=='yaml')return [];
    const node=doc.node(pointer),ranges=doc.comments(pointer,true).filter(range=>range[1]<=node.range[0]||range[0]>=node.range[1]);
    if(entryComments){
        const parent=pointer.slice(0,pointer.lastIndexOf('/')),siblings=[...doc.node(parent).children.values()];
        const index=siblings.findIndex(sibling=>sibling.pointer===pointer),previous=index>0?siblings[index-1].end:doc.node(parent).entryStart??0,start=node.entryStart??node.range[0];
        ranges.push(...doc.comments(parent,true).filter(range=>range[0]>=previous&&range[1]<=start));
    }
    const seen=new Set<string>();
    return ranges.sort((a,b)=>a[0]-b[0]).filter(range=>{const key=range.join(':');if(seen.has(key))return false;seen.add(key);return true;});
}
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
    /** Capture a planning copy and its logical provenance before specialization.
     * The converted CST may use different coordinates from the original source;
     * rebuilding origins from its node names would lose moved/foreign owners. */
    fork():MigrationSource {
        const fork=new MigrationSource(this.original);
        fork.doc=this.doc;
        fork.origins.clear();
        for(const [origin,locations]of this.origins)fork.origins.set(origin,new Set(locations));
        for(const [origin,locations]of this.foreignOrigins)fork.foreignOrigins.set(origin,new Set(locations));
        fork.presentationChanges.push(...this.presentationChanges);
        return fork;
    }
    *originSets():Generator<Set<string>>{yield* this.origins.values();yield* this.foreignOrigins.values();}
    private blockParent(pointer:string):boolean {
        let at=pointer;
        while(at){at=at.slice(0,at.lastIndexOf('/'));if(this.doc.nodes.get(at)?.flow)return false;}
        return true;
    }
    private update(text:string){this.doc=new SourceDocument(text,this.original.id);if(this.doc.issues.length)throw new SourceError('migration.syntax','The planned CST change is ambiguous');}
    /** Report a rejected physical edit through its surviving source owner,
     * including a copied occurrence's original resource. */
    private located<T>(pointer:string,action:()=>T):T {
        try{return action();}catch(error){
            if(error instanceof SourceError&&!error.source){
                let at=[...this.doc.nodes.values()].find(node=>
                    [node.range,node.keyRange].some(range=>range?.[0]===error.range[0]&&range?.[1]===error.range[1]))?.pointer??pointer;
                let location:MigrationLocation|undefined;
                while(true){
                    const own=[...this.origins].find(([,values])=>values.has(at));
                    const foreign=[...this.foreignOrigins].find(([,values])=>values.has(at));
                    if(own){location={resource:this.original.id,pointer:own[0]};break;}
                    if(foreign){const split=foreign[0].indexOf('#');location={resource:foreign[0].slice(0,split),pointer:foreign[0].slice(split+1)};break;}
                    if(!at)break;at=at.slice(0,at.lastIndexOf('/'));
                }
                error.source={...location??{resource:this.original.id,pointer},range:error.range};
            }
            throw error;
        }
    }
    ensure(pointer:string):void {
        if(this.doc.nodes.has(pointer))return;
        const parts=segments(pointer);parts.pop();const parent=parts.length?'/'+parts.map(escape).join('/'):'';
        this.ensure(parent);
        const owner=this.doc.node(parent);
        if(this.doc.format==='yaml'&&owner.flow&&!owner.children.size&&this.blockParent(parent)){
            this.located(parent,()=>this.doc.assertUnshared(parent));
            const inline=this.doc.text.slice(this.doc.lineStart(owner.range[0]),owner.range[0]).trim()!=='';
            this.update(this.doc.replace(...owner.range,(inline?this.doc.newline+' '.repeat(this.doc.indent(owner.range[0])+2):'')+JSON.stringify(segments(pointer).at(-1)!)+': {}'));
        }
        else this.update(this.doc.set(pointer,{}));
    }
    set(pointer:string,value:unknown):void {
        const current=this.doc.nodes.get(pointer);
        // An identical primitive needs no physical edit, even when authored
        // through an alias. Numbers require exact lexemes and are excluded.
        if(current&&(value===null||typeof value==='string'||typeof value==='boolean')&&current.value===value)return;
        const parts=segments(pointer);parts.pop();this.ensure(parts.length?'/'+parts.map(escape).join('/'):'');
        this.located(pointer,()=>this.update(this.doc.set(pointer,value)));
    }
    exact(pointer:string,text:string):void{this.set(pointer,new RawJsonValue(text));}
    remove(pointer:string,retire=true,preserveComments=true,preserveNestedComments=false):void {
        if(!this.doc.nodes.has(pointer))return;
        const authored=this.doc.node(pointer),keyAt=authored.keyRange?.[0];
        const nested=preserveNestedComments&&this.doc.format==='yaml'?this.doc.comments(pointer,true).map(range=>this.doc.text.slice(...range)):[];
        let comment:string|undefined,commentAt:number|undefined;
        if(preserveComments&&this.doc.format==='yaml'&&keyAt!==undefined){
            const start=this.doc.lineStart(keyAt),prefix=this.doc.text.slice(start,keyAt);
            const line=(at:number)=>this.doc.text.slice(at).split(/\r\n|\r|\n/,1)[0];
            if(/^ *$/.test(prefix)){
                const keyComment=/^:[ \t]*(#[^\r\n]*)/.exec(line(authored.keyRange![1]));
                const valueComment=/^[ \t]*(#[^\r\n]*)/.exec(line(authored.range[1]));
                const comments=preserveNestedComments?nested:[...new Set([keyComment?.[1],valueComment?.[1]].filter((value):value is string=>value!==undefined))];
                if(comments.length){comment=comments.map(value=>prefix+value+this.doc.newline).join('');commentAt=start;}
            }else if(nested.length){
                // A flow member cannot own standalone comments after removal.
                // Retain them before its nearest enclosing block entry instead.
                let parent=pointer;
                while(true){
                    parent=parent.slice(0,parent.lastIndexOf('/'));
                    const owner=this.doc.node(parent),at=owner.keyRange?.[0]??owner.range[0],lineStart=this.doc.lineStart(at),space=this.doc.text.slice(lineStart,at);
                    if(/^ *$/.test(space)||!parent){comment=nested.map(value=>space+value+this.doc.newline).join('');commentAt=lineStart;break;}
                }
            }
        }
        const parts=segments(pointer),name=parts.pop()!,parent=parts.length?'/'+parts.map(escape).join('/'):'',array=this.doc.node(parent).kind==='array';
        if(preserveComments&&this.doc.format==='yaml'&&array&&!this.doc.node(parent).flow){
            const comments=this.doc.comments(pointer,true).filter(range=>range[1]<=authored.range[0]);
            if(comments.length){
                const start=this.doc.lineStart(authored.entryStart??authored.range[0]),indent=' '.repeat(this.doc.indent(authored.entryStart??authored.range[0]));
                comment=comments.map(range=>indent+this.doc.text.slice(...range)+this.doc.newline).join('');commentAt=start;
            }
        }
        let removed=this.located(pointer,()=>this.doc.remove(pointer));
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
        if(node.shared||node.keyShared||!node.keyRange)this.located(pointer,()=>{throw new SourceError('migration.shared','This key has shared or ambiguous ownership',node.range);});
        this.update(this.doc.replace(...node.keyRange,this.doc.emit(name,undefined,true)));
        for(const values of this.originSets())for(const at of [...values])if(inside(at,pointer)){values.delete(at);values.add(to+at.slice(pointer.length));}
        return to;
    }
    copy(source:MigrationSource,from:string,to:string,entryComments=false):void {
        const before=source.doc,node=before.node(from);
        source.located(from,()=>{before.assertSafe(from);before.assertUnshared(from,true);});
        const copied=[...[...source.origins].map(([origin,values])=>({origin:source.original.id+'#'+origin,values})),...[...source.foreignOrigins].map(([origin,values])=>({origin,values}))]
            .flatMap(({origin,values})=>[...values].filter(at=>inside(at,from)).map(at=>({origin,pointer:to+at.slice(from.length)})));
        const parts=segments(to),name=parts.pop()!,parent=parts.length?'/'+parts.map(escape).join('/'):'',expected=before.dataJson(from),identity=migrationValueIdentity(before,from);
        this.ensure(parent);
        if(this.doc.nodes.has(to))throw new SourceError('migration.collision','A migration destination already exists at '+to);
        const owner=this.doc.node(parent),block=before.format==='yaml'&&!node.flow&&(node.kind==='object'||node.kind==='array');
        // Collection ranges begin at their first value token. Comments between
        // the entry key and that token still belong to the copied occurrence.
        const leading=outerCommentRanges(before,from,entryComments).map(range=>before.text.slice(...range));
        if(this.doc.format==='yaml'&&(!owner.flow||owner.children.size===0)&&this.blockParent(parent)&&block){
            const raw=before.text.slice(...node.range),indent=before.indent(node.range[0]);
            const local=(leading.length?leading.join(this.doc.newline)+this.doc.newline:'')+raw.replace(/(?:\r\n|\r|\n)([ \t]*)/g,(_match,space)=>this.doc.newline+space.slice(Math.min(indent,space.length)));
            const inline=this.doc.text.slice(this.doc.lineStart(owner.range[0]),owner.range[0]).trim()!=='';
            const depth=this.doc.indent(owner.range[0]),entryIndent=depth+(owner.flow&&inline?2:0);
            if(owner.flow&&owner.children.size===0){
                this.located(parent,()=>this.doc.assertUnshared(parent));
                if(owner.kind==='array'&&name!=='0')
                    throw new SourceError('migration.array.index','An empty sequence can only receive its first element',owner.range);
                const marker=owner.kind==='array'?'-':JSON.stringify(name)+':';
                const text=marker+this.doc.newline+' '.repeat(entryIndent+2)+local.replaceAll(this.doc.newline,this.doc.newline+' '.repeat(entryIndent+2));
                this.update(this.doc.replace(...owner.range,(inline?this.doc.newline+' '.repeat(entryIndent):'')+text));
            }else{
                this.set(to,null);const slot=this.doc.node(to),depth=this.doc.indent(slot.range[0]);
                this.update(this.doc.replace(...slot.range,this.doc.newline+' '.repeat(depth+2)+local.replaceAll(this.doc.newline,this.doc.newline+' '.repeat(depth+2))));
            }
        }else if(before.format===this.doc.format&&!block){
            this.set(to,null);const slot=this.doc.node(to),raw=before.text.slice(...node.range);
            const indent=before.indent(node.range[0]),depth=this.doc.indent(slot.range[0]);
            // A comment copied after a flow delimiter needs leading separation
            // too; placing '#' directly after '[' or ':' changes YAML syntax.
            const prefix=this.doc.newline+' '.repeat(depth+2);
            const adjusted=(leading.length?prefix+leading.join(prefix)+prefix:'')+raw.replace(/(?:\r\n|\r|\n)([ \t]*)/g,(_match,space)=>this.doc.newline+' '.repeat(depth)+space.slice(Math.min(indent,space.length)));
            this.update(this.doc.replace(...slot.range,adjusted));
        }else{
            this.exact(to,expected);this.presentationChanges.push(to);
            if(this.doc.format==='yaml'){
                const comments=[...leading,...before.comments(from,true).filter(range=>range[0]>=node.range[0]&&range[1]<=node.range[1]).map(range=>before.text.slice(...range))];
                if(comments.length){
                    const slot=this.doc.node(to),depth=this.doc.indent(slot.range[0])+2;
                    const prefix=this.doc.newline+' '.repeat(depth);
                    this.update(this.doc.replace(slot.range[0],slot.range[0],prefix+comments.join(prefix)+prefix));
                }
            }
        }
        if(migrationValueIdentity(this.doc,to)!==identity)throw new SourceError('migration.fidelity','The mapped value changed its exact source meaning at '+to);
        for(const {origin,pointer}of copied){
            const own=origin.startsWith(this.original.id+'#'),map=own?this.origins:this.foreignOrigins,key=own?origin.slice(this.original.id.length+1):origin;
            const values=map.get(key)??new Set<string>();values.add(pointer);map.set(key,values);
        }
    }
    move(from:string,to:string,entryComments=false):void {
        if(from===to)return;
        this.copy(this,from,to,entryComments);
        // The copy already owns these parsed comment occurrences. Retiring the
        // old container must not preserve them a second time. Equal comment
        // texts at different ranges remain distinct authored occurrences.
        const comments=outerCommentRanges(this.doc,from,entryComments);
        if(comments.length){
            let text=this.doc.text;
            for(const [start,end]of comments.reverse())text=text.slice(0,start)+text.slice(end);
            this.update(text);
        }
        for(const values of this.originSets())for(const at of [...values])if(inside(at,from)){values.delete(at);values.add(to+at.slice(from.length));}
        this.remove(from,false,false);
    }
}
