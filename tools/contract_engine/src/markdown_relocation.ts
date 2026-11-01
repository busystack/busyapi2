import {Parser} from 'commonmark';
import {SourceError} from './document';
import {resolveUri} from './reference_graph';

type Scalar=string|number|boolean|null;
type Span=Readonly<{start:number;end:number}>;
type Event=Readonly<{entering:boolean;type:string;attributes:Readonly<Record<string,Scalar>>;destination?:string;lines?:readonly [number,number]}>;
type Candidate=Span&Readonly<{reference:boolean}>;
type Edit=Candidate&Readonly<{replacement:string}>;
const record=(value:unknown):value is Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const relative=(value:string)=>!/^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#)/.test(value);

class Work {
    private parsed=0;
    private scanned=0;
    parse(source:string):Event[] {
        if(source.length>1024*1024||(this.parsed+=source.length)>16*1024*1024)
            throw new SourceError('limit.migration.markdown','Documentation relocation exceeds its bounded parsing work');
        const root:unknown=new Parser().parse(source);
        if(!record(root)||typeof root.walker!=='function')throw new SourceError('migration.markdown.parser','The pinned CommonMark parser returned no document walker');
        const walker:unknown=root.walker();
        if(!record(walker)||typeof walker.next!=='function')throw new SourceError('migration.markdown.parser','The pinned CommonMark walker is unavailable');
        const events:Event[]=[];
        for(let count=0;;count++){
            if(count>400000)throw new SourceError('limit.migration.markdown','Documentation relocation exceeds its bounded node count');
            const event:unknown=walker.next();
            if(event===null)break;
            if(!record(event)||typeof event.entering!=='boolean'||!record(event.node)||typeof event.node.type!=='string')
                throw new SourceError('migration.markdown.parser','The pinned CommonMark walker returned an invalid event');
            const node=event.node,attributes:Record<string,Scalar>={};
            for(const key of ['literal','title','headingLevel','listType','listStart','listDelimiter','listTight','info','onEnter','onExit']){
                const value=node[key];
                if(value===undefined)continue;
                if(value!==null&&!['string','number','boolean'].includes(typeof value))
                    throw new SourceError('migration.markdown.parser','The pinned CommonMark node has an unknown attribute shape');
                if(value===null||typeof value==='string'||typeof value==='number'||typeof value==='boolean')attributes[key]=value;
            }
            let destination:string|undefined;
            if(node.type==='link'||node.type==='image'){
                if(typeof node.destination!=='string')throw new SourceError('migration.markdown.parser','A CommonMark link omitted its destination');
                destination=node.destination;
            }
            let lines:readonly [number,number]|undefined;
            const position=node.sourcepos;
            if(Array.isArray(position)&&position.length===2&&Array.isArray(position[0])&&Array.isArray(position[1])&&
                Number.isSafeInteger(position[0][0])&&Number.isSafeInteger(position[1][0])&&position[0][0]>0&&position[1][0]>=position[0][0])
                lines=[position[0][0],position[1][0]];
            events.push({entering:event.entering,type:node.type,attributes,destination,lines});
        }
        return events;
    }
    scan(amount=1):void {
        if((this.scanned+=amount)>4*1024*1024)throw new SourceError('limit.migration.markdown','Documentation destination inspection exceeds its bounded work');
    }
}

function resolved(destination:string,base:string):string {
    // Native Reference treats a fragment-only link as local navigation.
    if(destination.startsWith('#'))return destination;
    try{return resolveUri(destination,base).href;}
    catch(error){
        if(!(error instanceof Error))throw error;
        throw new SourceError('migration.description.uri','A documentation link cannot be resolved in its captured URI context');
    }
}
function shape(events:readonly Event[],base:string):string {
    return JSON.stringify(events.map(event=>[event.entering,event.type,event.attributes,
        event.destination===undefined?null:resolved(event.destination,base)]));
}
const destinations=(events:readonly Event[])=>events.flatMap(event=>event.entering&&event.destination!==undefined?[event.destination]:[]);
function apply(source:string,edits:readonly Edit[]):string {
    let result=source;
    for(const edit of [...edits].sort((a,b)=>b.start-a.start))result=result.slice(0,edit.start)+edit.replacement+result.slice(edit.end);
    return result;
}

function codeSpanEnd(source:string,start:number,work:Work):number|undefined {
    let end=start;
    while(source[end]==='`'){work.scan();end++;}
    const size=end-start;
    let at=end;
    while(at<source.length){
        const next=source.indexOf('`',at);
        work.scan((next<0?source.length:next)-at);
        if(next<0)return;
        let close=next;
        while(source[close]==='`'){work.scan();close++;}
        if(close-next===size)return close;
        at=close;
    }
}
function labelEnd(source:string,start:number,work:Work):number|undefined {
    let depth=1;
    for(let at=start+1;at<source.length;at++){
        work.scan();
        if(source[at]==='\\'){at++;continue;}
        if(source[at]==='`'){
            const end=codeSpanEnd(source,at,work);
            if(end!==undefined){at=end-1;continue;}
        }
        if(source[at]==='[')depth++;
        else if(source[at]===']'&&--depth===0)return at;
    }
}
function destinationSpan(source:string,start:number,work:Work):Span|undefined {
    let end=start;
    if(source[start]==='<'){
        for(end=start+1;end<source.length;end++){
            work.scan();
            if(source[end]==='\\'){end++;continue;}
            if(source[end]==='>')return {start,end:end+1};
            if(source[end]==='\n'||source[end]==='\r'||source[end]==='<')return;
        }
        return;
    }
    let depth=0;
    for(;end<source.length;end++){
        work.scan();
        const value=source[end];
        if(value==='\\'){end++;continue;}
        if(/[ \t\r\n]/.test(value))break;
        if(value==='(')depth++;
        else if(value===')'){if(depth===0)break;depth--;}
    }
    return depth===0?{start,end}:undefined;
}
function lineSpans(source:string,events:readonly Event[]):Span[] {
    const starts=[0];
    for(const match of source.matchAll(/\r\n|\r|\n/g))starts.push(match.index+match[0].length);
    return events.flatMap(event=>{
        const lines=event.lines;
        return event.entering&&['code_block','html_block'].includes(event.type)&&lines
            ?[{start:starts[lines[0]-1]??source.length,end:starts[lines[1]]??source.length}]:[];
    }).sort((a,b)=>a.start-b.start);

}

/** These are destination-token candidates, not another Markdown parser.
 * The unchanged pinned parser proves each accepted rewrite preserves its AST
 * and effective targets; code/HTML/text cannot become links through this pass. */
function candidates(source:string,events:readonly Event[],work:Work):Candidate[] {
    const opaque=lineSpans(source,events),covered=new Map<number,number>(),result:Candidate[]=[],seen=new Set<string>();
    let block=0;
    const space=(at:number)=>{while(at<source.length&&/[ \t\r\n]/.test(source[at])){work.scan();at++;}return at;};
    for(let at=0;at<source.length;at++){
        work.scan();
        while(block<opaque.length&&opaque[block].end<=at)block++;
        const hidden=covered.get(at)??(opaque[block]?.start<=at?opaque[block].end:undefined);
        if(hidden!==undefined&&hidden>at){at=hidden-1;continue;}
        if(source[at]==='\\'){at++;continue;}
        if(source[at]==='`'){
            const end=codeSpanEnd(source,at,work);if(end!==undefined){at=end-1;continue;}
        }
        if(source[at]!=='[')continue;
        const close=labelEnd(source,at,work);if(close===undefined)continue;
        let start:number,reference=false;
        if(source[close+1]==='(')start=space(close+2);
        else if(source[close+1]===':'){
            reference=true;
            const line=source.lastIndexOf('\n',at-1)+1;
            // Definitions may be nested in containers; the AST proof below
            // excludes ordinary text that merely resembles a definition.
            if(!/^[ \t>0-9.)+-]*$/.test(source.slice(line,at)))continue;
            start=space(close+2);
        }else continue;
        const span=destinationSpan(source,start,work);if(!span)continue;
        const identity=span.start+':'+span.end;
        if(seen.has(identity))continue;seen.add(identity);
        if(result.length>=4096)throw new SourceError('limit.migration.markdown','Documentation relocation exceeds 4096 destination tokens');
        result.push({...span,reference});covered.set(span.start,span.end);
    }
    return result.sort((a,b)=>a.start-b.start);
}
function normalizedDestination(raw:string,work:Work):string|undefined {
    const nodes=work.parse('[busyapi]('+raw+')');
    const links=nodes.filter(event=>event.entering&&event.type==='link');
    return links.length===1?links[0].destination:undefined;
}

/** Preserve CommonMark 0.31.2 §§4.7, 6.1, 6.3–6.4 and BusyAPI's local-fragment
 * policy. Only URI spans change; source text is never regenerated from an AST.
 * No destination is retrieved. Whole-tree proofs include titles, literal code,
 * text, headings and list structure as well as every rendered link/image URI. */
export function relocateMarkdownLinks(source:string,from:string,to:string):string {
    if(from===to)return source;
    const work=new Work(),before=work.parse(source),original=shape(before,from),changes=new Map<string,string>();
    for(const destination of destinations(before))if(relative(destination)&&resolved(destination,from)!==resolved(destination,to))
        changes.set(destination,resolved(destination,from));
    if(!changes.size)return source;
    const edits:Edit[]=[];
    for(const span of candidates(source,before,work)){
        const destination=normalizedDestination(source.slice(span.start,span.end),work);
        const value=destination===undefined?undefined:changes.get(destination);
        if(value===undefined)continue;
        const edit={...span,replacement:'<'+value.replaceAll('&','&amp;').replaceAll('<','%3C').replaceAll('>','%3E')+'>'};
        if(span.reference&&JSON.stringify(destinations(work.parse(apply(source,[edit]))))===JSON.stringify(destinations(before)))continue;
        edits.push(edit);
    }
    const proposed=apply(source,edits),after=work.parse(proposed);
    if(shape(after,to)===original)return proposed;
    // Ambiguous bracket text can produce harmless lexical candidates. Admit
    // only those that change actual rendered destinations without changing
    // any other original-context meaning, then prove the complete result.
    let accepted=source,current=before;
    for(const edit of [...edits].sort((a,b)=>b.start-a.start)){
        const candidate=apply(accepted,[edit]),parsed=work.parse(candidate);
        if(JSON.stringify(destinations(parsed))!==JSON.stringify(destinations(current))&&shape(parsed,from)===original){
            accepted=candidate;current=parsed;
        }
    }
    if(shape(current,to)!==original)throw new SourceError('migration.description.relative-links','No complete source-preserving destination mapping was proved for this Markdown field');
    return accepted;
}
