import {SourceDocument,SourceError,escape} from './document';
import type {GraphTarget,ReferenceGraph} from './reference_graph';
import {FormSemantics,formLiteralType,type FormShape} from './form_semantics';
import {MultipartEncoding,type MultipartSchemaStep,type MultipartTransfer} from './multipart_encoding';
import {mediaTypes,mediaTypeChoice} from './media_types';
import {mimeParts,mimeSingleton,type MimePart} from './mime_parts';
import {decodeMultipartTransfer} from './multipart_transfer';
import {decodeRuntimeMedia,runtimeMediaBytes,runtimeMediaKind} from './runtime_media';
import {headerShapes} from './header_serialization';
import {headerWireValues} from './header_wire_values';
import type {FormCheck,FormIssue,RuntimeFormData,RuntimeFormTarget} from './runtime_form';

type ObjectValue=Record<string,unknown>;
type Hint={schema:GraphTarget;shape:FormShape;path:MultipartSchemaStep[]};
const object=(value:unknown):value is ObjectValue=>value!==null&&typeof value==='object'&&!Array.isArray(value);

/** OAS 3.2 §§4.14.3/4.14.5/4.15.2: wire positions and nested encodings
 * project into exact CST instances. The original captured schemas, including
 * itemSchema, remain the only authority for their constraints. */
export function decodeRuntimeMultipart(text:string,id:string,contentType:string,base64:boolean,target:RuntimeFormTarget,graph:ReferenceGraph):RuntimeFormData|undefined {
    const owner=graph.docs.get(target.resource)?.dataNode(target.pointer),media=owner?.value;
    if(!object(media))throw new SourceError('runtime.form.owner','The captured multipart Media Type Object is unavailable',owner?.range??[0,0]);
    const forms=new FormSemantics(graph,new Map(graph.references.map(edge=>[JSON.stringify([edge.resource,edge.pointer,edge.keyword]),edge])));
    const transfers=new MultipartEncoding(graph),headerShape=headerShapes(graph),checks:FormCheck[]=[],issues:FormIssue[]=[];
    const location=(pointer:string):GraphTarget=>({resource:target.resource,pointer,kind:'schema'});
    const hints:Hint[]=['schema','itemSchema'].filter(key=>graph.scopes.has(target.resource+'#'+target.pointer+'/'+key))
        .map(key=>({schema:location(target.pointer+'/'+key),shape:forms.shape(target.resource,target.pointer+'/'+key),path:[]}));
    const whole=hints.find(hint=>hint.schema.pointer.endsWith('/schema'));
    const named=mediaTypes(contentType,false)[0].subtype==='form-data'&&whole?.shape.types?.includes('array')!==true&&media.itemSchema===undefined;
    const nested=(rule:unknown)=>object(rule)&&(rule.encoding!==undefined||rule.prefixEncoding!==undefined||rule.itemEncoding!==undefined||typeof rule.contentType==='string'&&mediaTypes(rule.contentType).some(type=>type.type==='multipart'));
    if(named&&media.prefixEncoding===undefined&&media.itemEncoding===undefined&&!Object.values(media.encoding??{}).some(nested))return;
    let work=0,serial=0;
    const parse=(raw:string)=>{
        const doc=new SourceDocument(raw,id+'/'+serial++,true,'json');if(doc.issues.length)throw doc.issues[0];return doc;
    };
    const fail=(code:string,message:string,at:GraphTarget,unsupported=true):never=>transfers.failure(code,message,at,unsupported);
    const issue=(code:string,message:string,prefix:string,at:GraphTarget,severity:'error'|'warning'='error')=>{
        const range=graph.docs.get(at.resource)?.dataNode(at.pointer)?.range??[0,0];
        issues.push({code,message,pointer:prefix,severity,source:{resource:at.resource,pointer:at.pointer,range}});
    };
    const descend=(hint:Hint,step:MultipartSchemaStep):Hint=>({schema:hint.schema,path:[...hint.path,step],
        shape:'property' in step?hint.shape.properties?.[step.property]??{}:step.item===undefined?hint.shape.items??{}:hint.shape.prefixItems?.[step.item]??hint.shape.items??{}});
    const headers=(part:MimePart,rule:ObjectValue,at:GraphTarget,prefix:string,form:boolean)=>{
        if(!object(rule.headers))return;
        const seen=new Set<string>();
        for(const name of Object.keys(rule.headers)){
            const lower=name.toLowerCase(),source={...at,pointer:at.pointer+'/headers/'+escape(name),kind:'header'};
            if(lower==='content-type')continue;
            if(seen.has(lower))fail('runtime.form.headers','MIME header declarations repeat without regard to case',source,false);seen.add(lower);
            if(form&&!['content-disposition','content-transfer-encoding'].includes(lower)){
                issue('runtime.form.header.ignored','RFC 7578 requires consumers to ignore this additional part header',prefix,source,'warning');continue;
            }
            const definition=transfers.follow(source,'header'),value=graph.docs.get(definition.resource)!.dataNode(definition.pointer)!.value,actual=part.headers.get(lower);
            if(!actual){if(value.required===true)issue('runtime.form.header.required','A required part header is absent',prefix,definition);continue;}
            if(value.content!==undefined)fail('runtime.form.header.unsupported','This part header needs a content-based representation',definition);
            if(!Object.hasOwn(value,'schema'))continue;
            const schema={...definition,pointer:definition.pointer+'/schema',kind:'schema'},shape=headerShape(schema);
            if(!shape||value.style!==undefined&&value.style!=='simple')fail('runtime.form.header.unsupported','This part header has no supported simple-style representation',definition);
            const decoded=headerWireValues(shape,actual,{cookie:false,multiline:false,explode:value.explode===true});
            if(!decoded.complete||decoded.texts.length!==1)fail('runtime.form.header.unsupported','This part header requires several possible data interpretations',definition);
            checks.push({document:parse(decoded.texts[0]),schema,prefix:prefix+'/headers/'+escape(name)});
        }
    };
    const decode=(bytes:Buffer,type:string,rule:ObjectValue,at:GraphTarget,values:Hint[],prefix:string,depth:number):{raw:string;items?:SourceDocument[]}=>{
        if(depth>8)fail('limit.runtime.multipart.depth','Nested multipart decoding exceeds eight levels',at);
        const concrete=mediaTypes(type,false)[0],form=concrete.subtype==='form-data';
        const array=!form||values[0]?.shape.types?.includes('array')===true;
        const parts=mimeParts(bytes,type),members=new Map<string,string[]>(),items:SourceDocument[]=[];
        for(const [index,part]of parts.entries()){
            if(++work>2048)fail('limit.runtime.form','Nested multipart decoding exceeds 2048 total parts',at);
            let name:string|undefined;
            if(form){
                const disposition=mimeSingleton(part.headers,'content-disposition');
                if(disposition===undefined)fail('runtime.form.syntax','A multipart form-data part needs Content-Disposition',at,false);
                const parsed=mediaTypes('x/'+disposition,false);
                if(parsed[0].subtype!=='form-data'||!parsed[0].parameters.has('name'))fail('runtime.form.syntax','A multipart form-data part needs a name',at,false);
                name=parsed[0].parameters.get('name')!;
            }
            const prefixRules=Array.isArray(rule.prefixEncoding)?rule.prefixEncoding:[];
            const entry=array?(index<prefixRules.length?prefixRules[index]:rule.itemEncoding):object(rule.encoding)?rule.encoding[name!]:undefined;
            const encoding=object(entry)?entry:{};
            const entryAt={...at,pointer:array?at.pointer+(index<prefixRules.length?'/prefixEncoding/'+index:'/itemEncoding'):at.pointer+'/encoding/'+escape(name!)};
            if(form&&['style','explode','allowReserved'].some(key=>Object.hasOwn(encoding,key)))
                fail('runtime.form.style.unsupported','Nested or ordered form-data requires an explicit content representation for this part',entryAt);
            let itemHints=values.map(hint=>array?descend(hint,{item:index}):descend(hint,{property:name!}));
            if(depth===0&&array){const item=hints.find(hint=>hint.schema.pointer.endsWith('/itemSchema'));if(item)itemHints.push(item);}
            if(form&&array)itemHints=itemHints.map(hint=>descend(hint,{property:name!}));
            if(!array&&itemHints[0]?.shape.types?.includes('array'))itemHints=itemHints.map(hint=>descend(hint,{item:undefined}));
            const field=itemHints.find(hint=>hint.shape.types?.length||hint.shape.contentEncoding!==undefined)?.shape??itemHints[0]?.shape??{};
            const declared=typeof encoding.contentType==='string'?encoding.contentType:field.defaultContentType??'application/octet-stream';
            const actual=mimeSingleton(part.headers,'content-type')??(concrete.subtype==='digest'?'message/rfc822':'text/plain');
            mediaTypeChoice(declared,actual);
            const actualType=mediaTypes(actual,false)[0];
            const decodingType=!form&&actualType.type==='text'&&!actualType.parameters.has('charset')?actual+'; charset=us-ascii':actual;
            const partPrefix=prefix+'/'+(array?index:escape(name!));
            headers(part,encoding,entryAt,partPrefix,form);
            const literalType=formLiteralType(field);
            const implicit=itemHints.map(hint=>transfers.schemaPathEncoding(hint.schema,hint.path,literalType!==undefined&&literalType!=='string'?'other':undefined));
            const encodings=new Set(implicit.flatMap(value=>value.encoding===undefined?[]:[value.encoding.toLowerCase()]));
            if(encodings.size>1)fail('runtime.form.transfer.undefined','Applicable part schemas specify conflicting transfer encodings',entryAt);
            const transfer:MultipartTransfer=implicit.find(value=>value.schemaEncoded||value.instanceEncoding!==undefined)??{schemaEncoded:false};
            const explicit=mimeSingleton(part.headers,'content-transfer-encoding'),expected=transfer.encoding;
            if(explicit!==undefined&&expected!==undefined&&explicit.toLowerCase()!==expected.toLowerCase())fail('runtime.form.transfer.undefined','The part header conflicts with its schema transfer encoding',transfer.source?{...transfer.source,kind:'schema'}:entryAt);
            if(actualType.type==='multipart'&&!['binary','7bit','8bit'].includes((explicit??expected??'binary').toLowerCase()))
                fail('runtime.form.syntax','A multipart entity permits only binary, 7bit or 8bit transfer encoding',entryAt,false);
            const payload=decodeMultipartTransfer(part.bytes,explicit??expected??'binary');
            let raw:string;
            if(transfer.schemaEncoded){
                if(runtimeMediaKind(actual)!=='opaque')decodeRuntimeMedia(payload.bytes.toString('base64'),id+'/encoded-media/'+serial++,decodingType,true);
                raw=JSON.stringify(payload.encoded??decodeRuntimeMedia(payload.bytes.toString('base64'),id+'/encoded/'+serial++,'text/plain; charset=utf-8',true).document.root.value);
            }
            else if(mediaTypes(actual,false)[0].type==='multipart')raw=decode(payload.bytes,actual,encoding,entryAt,itemHints,partPrefix,depth+1).raw;
            else{
                const decoded=decodeRuntimeMedia(payload.bytes.toString('base64'),id+'/part/'+serial++,decodingType,true,transfer.instanceEncoding==='octets');
                const value=decoded.document.dataJson(''),type=formLiteralType(field);
                if(decoded.kind==='text'&&type!==undefined&&type!=='string'){
                    const literal=decoded.document.root.value;
                    if(typeof literal!=='string')throw new SourceError('runtime.form.protocol','A text decoder returned another data kind');
                    raw=parse(literal).dataJson('');
                }else raw=value;
            }
            if(form&&array)raw='{'+JSON.stringify(name)+':'+raw+'}';
            if(array)items.push(parse(raw));else{const entries=members.get(name!)??[];entries.push(raw);members.set(name!,entries);}
        }
        return array?{raw:'['+items.map(doc=>doc.dataJson('')).join(',')+']',items}:
            {raw:'{'+[...members].map(([name,entries])=>JSON.stringify(name)+':'+(entries.length>1||values[0]?.shape.properties?.[name]?.types?.includes('array')?'['+entries.join(',')+']':entries[0])).join(',')+'}'};
    };
    const result=decode(runtimeMediaBytes(text,base64),contentType,media,{resource:target.resource,pointer:target.pointer,kind:'media'},whole?[whole]:[], '',0);
    return {document:parse(result.raw),items:result.items,kind:result.items?'multipart-sequence':'multipart-form',checks,issues};
}
