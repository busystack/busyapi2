import {SourceDocument,escape} from './document';
import type {GraphTarget,ReferenceGraph} from './reference_graph';
import {MultipartEncoding} from './multipart_encoding';
import {headerShapes} from './header_serialization';
import {headerWireValues} from './header_wire_values';
import {mimeHeaderContent,type MimeHeaderFormDecoder} from './mime_header_content';
import type {FormCheck,FormIssue} from './runtime_form';

const object=(value:unknown):value is Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value);

/** Header representations share the graph's existing simple-style codec.
 * RFC 7578's ignored fields apply only to form-data, not generic MIME parts. */
export function mimeHeaders(graph:ReferenceGraph,id:string,transfers:MultipartEncoding,decodeForm:MimeHeaderFormDecoder) {
    const shapeFor=headerShapes(graph);
    const content=mimeHeaderContent(graph,id+'/content',transfers,decodeForm);
    let serial=0,work=0;
    return (actualHeaders:ReadonlyMap<string,string[]>,rules:unknown,at:GraphTarget,prefix:string,formData:boolean):{checks:FormCheck[];issues:FormIssue[]}=>{
        const checks:FormCheck[]=[],issues:FormIssue[]=[];
        if(!object(rules))return {checks,issues};
        const issue=(code:string,message:string,source:GraphTarget,severity:'error'|'warning'='error')=>{
            const range=graph.docs.get(source.resource)?.dataNode(source.pointer)?.range??[0,0];
            issues.push({code,message,pointer:prefix,severity,source:{resource:source.resource,pointer:source.pointer,range}});
        };
        const fail=(code:string,message:string,source:GraphTarget,unsupported=true):never=>transfers.failure(code,message,source,unsupported);
        const seen=new Set<string>();
        for(const name of Object.keys(rules)){
            const lower=name.toLowerCase(),source={...at,pointer:at.pointer+'/headers/'+escape(name),kind:'header'};
            if(++work>2048)fail('limit.runtime.mime.headers','MIME header checks exceed 2048 captured declarations',source);
            if(lower==='content-type')continue;
            if(seen.has(lower))fail('runtime.form.headers','MIME header declarations repeat without regard to case',source,false);seen.add(lower);
            if(formData&&!['content-disposition','content-transfer-encoding'].includes(lower)){
                issue('runtime.form.header.ignored','RFC 7578 requires consumers to ignore this additional part header',source,'warning');continue;
            }
            const definition=transfers.follow(source,'header'),value=graph.docs.get(definition.resource)!.dataNode(definition.pointer)!.value,actual=actualHeaders.get(lower);
            if(!actual){if(value.required===true)issue('runtime.form.header.required','A required part header is absent',definition);continue;}
            if(value.content!==undefined){
                const decoded=content(definition,actual,prefix+'/headers/'+escape(name));
                checks.push(...decoded.checks);issues.push(...decoded.issues);continue;
            }
            if(!Object.hasOwn(value,'schema'))continue;
            const schema={...definition,pointer:definition.pointer+'/schema',kind:'schema'},shape=shapeFor(schema);
            if(!shape||value.style!==undefined&&value.style!=='simple')fail('runtime.form.header.unsupported','This part header has no supported simple-style representation',definition);
            const decoded=headerWireValues(shape,actual,{cookie:false,multiline:false,explode:value.explode===true});
            if(!decoded.complete||decoded.texts.length!==1)fail('runtime.form.header.unsupported','This part header requires several possible data interpretations',definition);
            const document=new SourceDocument(decoded.texts[0],id+'/'+serial++,true,'json');
            if(document.issues.length)throw document.issues[0];
            checks.push({document,schema,prefix:prefix+'/headers/'+escape(name)});
        }
        return {checks,issues};
    };
}
