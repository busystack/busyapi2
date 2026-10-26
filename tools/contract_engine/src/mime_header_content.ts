import {SourceError,escape} from './document';
import type {GraphTarget,ReferenceGraph} from './reference_graph';
import {FormSemantics} from './form_semantics';
import {runtimeFormMedia,decodeRuntimeMedia} from './runtime_media';
import {capturedRuntimeMedia} from './runtime_media_owner';
import type {MultipartEncoding} from './multipart_encoding';
import type {FormCheck,FormIssue,RuntimeFormData,RuntimeFormTarget} from './runtime_form';

export type MimeHeaderFormDecoder=(text:string,id:string,contentType:string,target:RuntimeFormTarget)=>RuntimeFormData;

export function capturedMimeHeaderContent(graph:ReferenceGraph,transfers:MultipartEncoding) {
    const capture=capturedRuntimeMedia(graph);
    return (header:GraphTarget)=>{
        const content=graph.docs.get(header.resource)?.dataNode(header.pointer+'/content');
        if(content?.kind!=='object')transfers.failure('runtime.form.header.content','A MIME Header content declaration must be a map',header);
        const entries=[...content.children].filter(([name])=>!name.startsWith('x-'));
        if(entries.length!==1)transfers.failure('runtime.form.header.content','A MIME Header content declaration requires exactly one media type',header);
        const [type]=entries[0],target=transfers.follow({...header,pointer:header.pointer+'/content/'+escape(type),kind:'media'},'media');
        return {type,captured:capture(target)};
    };
}

/** Header.content keeps the original Media Type/Schema Objects. The same
 * framing codecs and evaluator handle it; header text is never JSON.parsed.
 * OAS 3.0 §4.7.21 / 3.1 §4.8.21 / 3.2 Header Object. */
export function mimeHeaderContent(graph:ReferenceGraph,id:string,transfers:MultipartEncoding,decodeForm:MimeHeaderFormDecoder) {
    const capture=capturedMimeHeaderContent(graph,transfers);
    const forms=new FormSemantics(graph,new Map(graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge])));
    let serial=0;
    return (header:GraphTarget,values:readonly string[],prefix:string):{checks:FormCheck[];issues:FormIssue[]}=>{
        const {type,captured}=capture(header),source=captured.source;
        if(values.length!==1)transfers.failure('runtime.form.header.unsupported','A content-based MIME header has multiple wire values',header);
        const schema=captured.schema,shape=schema&&captured.family==='3.0'?forms.shape(schema.resource,schema.pointer):undefined;
        const octets=shape?.types?.includes('string')===true&&shape.format==='binary';
        let decoded:ReturnType<typeof decodeRuntimeMedia>|RuntimeFormData;
        let form:RuntimeFormData|undefined;
        try{
            if(runtimeFormMedia(type)){
                form=decodeForm(values[0],id+'/'+serial++,type,source);decoded=form;
            }else decoded=decodeRuntimeMedia(values[0],id+'/'+serial++,type,false,octets?'octets':captured.family==='3.0'?'legacy-octets':'binary');
        }catch(error){
            if(!(error instanceof SourceError))throw error;
            throw new SourceError(error.code,error.message,error.range,error.kind,error.source??source);
        }
        const checks:FormCheck[]=[],issues:FormIssue[]=[];
        const append=(document:typeof decoded.document,schema:FormCheck['schema'],at:string)=>{
            const binary=decoded.binaryInstances?.get(document);
            checks.push({document,schema,prefix:at,...(binary?{binary}:{})});
        };
        append(decoded.document,schema,prefix);
        if(captured.itemSchema){
            if(!decoded.items)throw new SourceError('runtime.form.header.items.unsupported','MIME Header itemSchema requires a sequential media representation',source.range,'unsupported',source);
            decoded.items.forEach((document,index)=>append(document,captured.itemSchema,prefix+'/'+index));
        }
        if(form){
            for(const check of form.checks)checks.push({...check,prefix:prefix+check.prefix});
            for(const issue of form.issues)issues.push({...issue,pointer:prefix+issue.pointer});
        }
        return {checks,issues};
    };
}
