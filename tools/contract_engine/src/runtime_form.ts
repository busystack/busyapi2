import {SourceDocument,SourceError,escape,type Range} from './document';
import type {GraphTarget,ReferenceGraph} from './reference_graph';
import {FormSemantics,formLiteralType,namedFileShapeSelection,type FormShape} from './form_semantics';
import {ParameterSemantics} from './parameter_semantics';
import {mediaTypeChoice,mediaTypes} from './media_types';
import {decodeRuntimeMedia,runtimeMediaBytes,runtimeMediaKind,type RuntimeMediaData,type TextSerialization} from './runtime_media';
import {MultipartEncoding} from './multipart_encoding';
import {decodeMultipartTransfer,multipartTextSerialization} from './multipart_transfer';
import {embeddedMimeTextBytes} from './embedded_mime_text';
import {mimeParts,mimePartDecodingType,mimeSingleton as singleton} from './mime_parts';
import {decodeRuntimeMultipart} from './runtime_multipart';
import {mimeHeaders} from './mime_headers';
import {MultipartFileShapes,type MultipartFileShape} from './multipart_file_shapes';
import type {BinaryLocations} from './runtime_binary';

export type RuntimeFormTarget={resource:string;pointer:string;occurrence?:string;fileShapes?:Readonly<Record<string,MultipartFileShape>>};
type Location={resource:string;pointer:string};
export type FormIssue={code:string;message:string;pointer:string;severity:'error'|'warning';source:{resource:string;pointer:string;range:Range}};
export type FormCheck={document:SourceDocument;schema?:Location;prefix:string;file?:boolean;binary?:BinaryLocations};
export type RuntimeFormData=RuntimeMediaData&{checks:FormCheck[];issues:FormIssue[]};
type Part={name:string;bytes:Buffer;encoded?:Buffer;headers:ReadonlyMap<string,string[]>};
const object=(value:unknown):value is Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const maximumParts=2048;

const syntax=(message:string):never=>{throw new SourceError('runtime.form.syntax',message);};
const utf8=(bytes:Buffer):string=>{
    try{return new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);}
    catch(error){if(error instanceof TypeError)return syntax('A form name or value is not UTF-8');throw error;}
};
function unquote(value:Buffer):Buffer {
    const output:number[]=[];
    for(let index=0;index<value.length;index++){
        const byte=value[index];
        if(byte===43)output.push(32);
        else if(byte===37){
            const hex=value.subarray(index+1,index+3).toString('latin1');
            if(hex.length!==2||!/^[0-9a-f]{2}$/i.test(hex))return syntax('A form value has an unfinished percent-encoded octet');
            output.push(Number.parseInt(hex,16));index+=2;
        }else output.push(byte);
    }
    return Buffer.from(output);
}
/** Finite RFC 7578/2046 framing. Buffers retain file octets, repeated fields and
 * order. The decoder has no filesystem, acquisition or request capabilities. */
function parts(bytes:Buffer,contentType:string,allowGenericNamed:boolean):Part[] {
    const [type]=mediaTypes(contentType,false);
    if(type.type==='application'&&type.subtype==='x-www-form-urlencoded'){
        const result:Part[]=[];
        let start=0;
        for(let index=0;index<=bytes.length;index++)if(index===bytes.length||bytes[index]===38){
            const pair=bytes.subarray(start,index);start=index+1;if(!pair.length)continue;
            const equal=pair.indexOf(61),name=equal<0?pair:pair.subarray(0,equal),encoded=equal<0?Buffer.alloc(0):pair.subarray(equal+1);
            result.push({name:utf8(unquote(name)),bytes:unquote(encoded),encoded,headers:new Map()});
            if(result.length>maximumParts)throw new SourceError('limit.runtime.form','A form exceeds 2048 fields');
        }
        return result;
    }
    if(type.type!=='multipart'||type.subtype!=='form-data'&&!allowGenericNamed)throw new SourceError('runtime.form.unsupported','This form representation requires another MIME binding',[0,0],'unsupported');
    return mimeParts(bytes,contentType).map(part=>{
        const disposition=singleton(part.headers,'content-disposition');
        if(disposition===undefined){
            if(type.subtype!=='form-data')throw new SourceError('runtime.form.unnamed.unsupported','An older-family generic multipart part needs an explicit form-data name for the native property mapping',[0,0],'unsupported');
            return syntax('A named multipart part needs Content-Disposition');
        }
        const parsed=mediaTypes('x/'+disposition,false);
        if(parsed.length!==1||parsed[0].subtype!=='form-data'||!parsed[0].parameters.has('name')){
            if(type.subtype!=='form-data')throw new SourceError('runtime.form.unnamed.unsupported','This generic multipart disposition has no native property/name correlation',[0,0],'unsupported');
            return syntax('A multipart form-data part needs a name');
        }
        return {...part,name:parsed[0].parameters.get('name')!};
    });
}

/** Contextual inversion of the canonical form projection, not a schema merger.
 * Scalar text is literal for strings and strict JSON for declared numeric,
 * boolean and null types. Content-based JSON keeps its CST numeric lexemes. */
export function decodeRuntimeForm(text:string,id:string,contentType:string,base64:boolean,target:RuntimeFormTarget,subject:string,graph:ReferenceGraph,textSerialization?:TextSerialization):RuntimeFormData {
    if(!base64&&textSerialization==='embedded'&&mediaTypes(contentType,false)[0].type==='multipart'){
        text=embeddedMimeTextBytes(text,contentType).toString('base64');base64=true;
    }
    const unicode=textSerialization==='unicode'?'unicode':undefined;
    const owner=graph.docs.get(target.resource),node=owner?.dataNode(target.pointer),scope=graph.scopes.get(target.resource+'#'+target.pointer);
    const failure=(code:string,message:string,at:Location=target,unsupported=true):never=>{
        const source=graph.docs.get(at.resource)?.dataNode(at.pointer),range:Range=source?.range??[0,0];
        throw new SourceError(code,message,range,unsupported?'unsupported':undefined,{...at,range});
    };
    if(!owner||!node||!scope)failure('runtime.form.owner','The captured form owner is unavailable');
    if(Object.keys(target.fileShapes??{}).length&&(!namedFileShapeSelection(scope.family,contentType,false)||subject!=='request-body'))
        failure('runtime.form.file-shape','File value shapes require a captured named multipart request');
    // MIME field lines already have their ASCII/UTF-8 framing proof. A
    // Header.content model does not replace the part body's serialization.
    const decodeHeaderForm=(text:string,id:string,type:string,target:RuntimeFormTarget)=>decodeRuntimeForm(text,id,type,false,target,subject,graph);
    if(scope.family==='3.2'&&scope.kind==='media'&&mediaTypes(contentType,false)[0].type==='multipart'){
        const decoded=decodeRuntimeMultipart(text,id,contentType,base64,target,graph,decodeHeaderForm,unicode);
        if(decoded)return decoded;
    }
    const input=parts(runtimeMediaBytes(text,base64),contentType,scope.kind==='media'&&(scope.family==='3.0'||scope.family==='3.1')),multipart=mediaTypes(contentType,false)[0].type==='multipart';
    const forms=new FormSemantics(graph),transfers=new MultipartEncoding(graph);
    const genericHeaders=mimeHeaders(graph,id+'/headers',transfers,decodeHeaderForm);
    const checks:FormCheck[]=[],issues:FormIssue[]=[],members=new Map<string,string>(),claimed=new Map<Part,string>(),notes=new Set<string>();
    const binary=new Map<string,Buffer>();
    const document=(raw:string,suffix:string)=>{
        const result=new SourceDocument(raw,id+'/'+suffix,true,'json');
        if(result.issues.length)throw result.issues[0];return result;
    };
    const claim=(part:Part,name:string)=>{
        const previous=claimed.get(part);
        if(previous!==undefined&&previous!==name)failure('runtime.form.ambiguous','Two form declarations claim the same wire field');
        claimed.set(part,name);
    };
    const issue=(code:string,message:string,name:string,at:Location,severity:'error'|'warning'='error')=>{
        if(severity==='warning'){const key=JSON.stringify([code,name,at.resource,at.pointer]);if(notes.has(key))return;notes.add(key);}
        const source=graph.docs.get(at.resource)?.dataNode(at.pointer),range:Range=source?.range??[0,0];
        issues.push({code,message,pointer:'/'+escape(name),severity,source:{...at,range}});
    };
    const scalar=(value:string,type?:string)=>type===undefined||type==='string'?JSON.stringify(value):document(value,'scalar').dataJson('');
    const bytesText=(bytes:Buffer,mediaType:string,serialization:TextSerialization|undefined):string=>{
        const decoded=decodeRuntimeMedia(bytes.toString('base64'),id+'/text',mediaType,true,'unsupported',serialization);
        if(decoded.kind!=='text')return failure('runtime.form.media.unsupported','This field requires a text decoder');
        const value=decoded.document.root.value;
        if(typeof value!=='string')throw new SourceError('runtime.form.protocol','A text decoder returned another data kind');
        return value;
    };
    const payload=(part:Part)=>{
        const encoding=singleton(part.headers,'content-transfer-encoding')??'binary',decoded=decodeMultipartTransfer(part.bytes,encoding);
        return {...decoded,serialization:multipartTextSerialization(part.bytes,encoding,decoded,unicode!==undefined)};
    };
    if(scope.family==='2.0'&&scope.kind==='operation'){
        const occurrences=graph.operations().filter(operation=>operation.source.resource===target.resource&&operation.source.pointer===target.pointer&&(target.occurrence===undefined||operation.occurrence===target.occurrence));
        if(occurrences.length!==1)failure('runtime.form.owner','Choose one captured operation occurrence for these form parameters');
        const parameters=new ParameterSemantics(graph).operation(target.resource,target.pointer,occurrences[0].pathItem);
        if(!parameters.complete||!parameters.valid)failure('runtime.form.owner','The effective Swagger form parameters are incomplete');
        const flat=(value:Record<string,unknown>,literal:string):string=>{
            if(value.type!=='array')return scalar(literal,typeof value.type==='string'?value.type:undefined);
            if(!object(value.items))return failure('runtime.form.items','An array parameter has no captured Items Object');
            const items=value.items;
            const collection=value.collectionFormat??'csv',separator=collection==='ssv'?' ':collection==='tsv'?'\t':collection==='pipes'?'|':',';
            if(collection==='multi')return failure('runtime.form.collection.unsupported','Nested multi collections have no defined wire boundary');
            return '['+literal.split(separator).map(item=>flat(items,item)).join(',')+']';
        };
        for(const parameter of parameters.visible.filter(parameter=>parameter.location==='formData')){
            if(parameter.state!=='resolved'||!parameter.definition||parameter.name===undefined)failure('runtime.form.owner','A form parameter has no captured definition');
            const definition=parameter.definition,value=graph.docs.get(definition.resource)!.dataNode(definition.pointer)!.value;
            if(!object(value))throw new SourceError('runtime.form.protocol','A form parameter is not an object');
            const name=parameter.name,values=input.filter(part=>part.name===name);values.forEach(part=>claim(part,name));
            if(!values.length){if(value.required===true)issue('runtime.request.form.required','A required form parameter is absent',name,definition);continue;}
            if(value.type==='file'){
                if(!multipart)failure('runtime.form.file.unsupported','File parameters require a multipart representation',definition);
                if(values.length!==1)return syntax('A file parameter occurs more than once');
                const value=payload(values[0]);
                if(value.serialization)decodeRuntimeMedia(value.bytes.toString('base64'),id+'/file',mimePartDecodingType(singleton(values[0].headers,'content-type')??'application/octet-stream',true),true,'unsupported',value.serialization);
                checks.push({document:document('null','file/'+checks.length),prefix:'/'+escape(name),file:true});continue;
            }
            if(value.allowEmptyValue!==true&&values.some(part=>part.bytes.length===0))issue('runtime.request.form.empty','This parameter does not allow an empty wire value',name,definition);
            const tokens=values.map(part=>{
                const value=payload(part);return bytesText(value.bytes,mimePartDecodingType(singleton(part.headers,'content-type')??'text/plain; charset=utf-8',mediaTypes(contentType,false)[0].subtype==='form-data'),value.serialization);
            });
            const items=value.items;
            const raw=value.type==='array'&&value.collectionFormat==='multi'&&object(items)?'['+tokens.map(token=>flat(items,token)).join(',')+']':tokens.length===1?flat(value,tokens[0]):failure('runtime.form.scalar','A scalar or separated collection occurs more than once',definition,false);
            members.set(name,raw);checks.push({document:document(raw,'parameter/'+checks.length),schema:definition,prefix:'/'+escape(name)});
        }
    }else{
        const media=scope.kind==='media',body=scope.family==='2.0'&&(scope.kind==='parameter'&&node.value?.in==='body'||scope.kind==='response');
        if(!media&&!body)failure('runtime.form.owner','This source does not own a form media description');
        if(subject==='request-body'&&(node.value?.prefixEncoding!==undefined||node.value?.itemEncoding!==undefined))
            failure('runtime.form.positional.unsupported','This media description requires positional multipart decoding');
        const schema:GraphTarget={resource:target.resource,pointer:target.pointer+'/schema',kind:'schema'},shape=forms.shape(schema.resource,schema.pointer),properties=shape.properties??{};
        const selectedShapes=target.fileShapes??{},fileShapes=new MultipartFileShapes(graph);
        for(const [name,selected]of Object.entries(selectedShapes)){
            if(subject!=='request-body'||!namedFileShapeSelection(scope.family,contentType,false)||!fileShapes.choices(schema,name).includes(selected))
                failure('runtime.form.file-shape','The file shape is not owned by this captured request media',schema);
        }
        const encodingApplies=subject==='request-body'||scope.family==='3.2';
        const encoding=media&&encodingApplies&&object(node.value?.encoding)?node.value.encoding:{};
        const styled=(rule:Record<string,unknown>)=>(!multipart||scope.family!=='3.0')&&['style','explode','allowReserved'].some(key=>Object.hasOwn(rule,key));
        for(const name of Object.keys(selectedShapes))if(styled(encoding[name]??{}))
            failure('runtime.form.file-shape','File shape choices require the captured MIME content binding',schema);
        const partHeaders=(part:Part,rule:Record<string,unknown>,name:string)=>{
            if(!multipart||!object(rule.headers))return;
            if(mediaTypes(contentType,false)[0].subtype!=='form-data'){
                const decoded=genericHeaders(part.headers,rule.headers,{...target,pointer:target.pointer+'/encoding/'+escape(name),kind:'encoding'},'/'+escape(name),false);
                checks.push(...decoded.checks);issues.push(...decoded.issues);return;
            }
            const seen=new Set<string>();
            for(const key of Object.keys(rule.headers)){
                const lower=key.toLowerCase();if(lower==='content-type')continue;
                const declared={resource:target.resource,pointer:target.pointer+'/encoding/'+escape(name)+'/headers/'+escape(key),kind:'header'};
                if(seen.has(lower))failure('runtime.form.headers','MIME header declarations repeat without regard to case',declared,false);seen.add(lower);
                if(!['content-disposition','content-transfer-encoding'].includes(lower)){
                    issue('runtime.form.header.ignored','RFC 7578 requires consumers to ignore this additional part header',name,declared,'warning');continue;
                }
                const definition=transfers.follow(declared,'header'),header=graph.docs.get(definition.resource)!.dataNode(definition.pointer)!.value,actual=singleton(part.headers,lower);
                if(actual===undefined){if(header.required===true)issue('runtime.request.form.header.required','A required part header is absent',name,definition);continue;}
                if(header.content!==undefined){
                    const decoded=genericHeaders(part.headers,{[key]:rule.headers[key]},{...target,pointer:target.pointer+'/encoding/'+escape(name),kind:'encoding'},'/'+escape(name),true);
                    checks.push(...decoded.checks);issues.push(...decoded.issues);continue;
                }
                if(Object.hasOwn(header,'schema'))checks.push({document:document(JSON.stringify(actual),'header/'+checks.length),schema:{...definition,pointer:definition.pointer+'/schema'},prefix:'/'+escape(name)+'/headers/'+escape(key)});
            }
        };
        const literal=(part:Part,field:FormShape,rule:Record<string,unknown>,name:string,array:boolean,pointer:string):string=>{
            if(rule.encoding!==undefined||rule.prefixEncoding!==undefined||rule.itemEncoding!==undefined)
                failure('runtime.form.nested.unsupported','This field requires nested multipart decoding',{resource:target.resource,pointer:target.pointer+'/encoding/'+escape(name)});
            const undeclared=!Object.hasOwn(properties,name)&&!Object.hasOwn(encoding,name);
            // 3.0/3.1 Encoding belongs to requests. A response's actual MIME
            // field line selects its decoder; an inferred request default is
            // not a response media restriction (3.0 §4.7.14.1 / RFC 7578 §4.4).
            const type=formLiteralType(field),declared=multipart&&!encodingApplies?singleton(part.headers,'content-type')??'text/plain':typeof rule.contentType==='string'?rule.contentType:
                multipart&&Object.hasOwn(selectedShapes,name)?transfers.fileContentType(schema,name,selectedShapes[name]):
                undeclared&&multipart?singleton(part.headers,'content-type')??'text/plain':field.defaultContentType??(undeclared||scope.family==='3.0'?'text/plain':'application/octet-stream');
            const concrete=multipart?singleton(part.headers,'content-type')??'text/plain':mediaTypeChoice(declared);
            if(multipart)mediaTypeChoice(declared,concrete);
            const decodingType=mimePartDecodingType(concrete,!multipart||mediaTypes(contentType,false)[0].subtype==='form-data');
            const transfer=multipart&&graph.scopes.has(schema.resource+'#'+schema.pointer)?transfers.schemaEncoding(schema,name,array,type!==undefined&&type!=='string'?'other':undefined,Object.hasOwn(selectedShapes,name)):{schemaEncoded:false};
            partHeaders(part,rule,name);
            const actual=singleton(part.headers,'content-transfer-encoding'),expected=transfer.encoding;
            if(actual!==undefined&&expected!==undefined&&actual.toLowerCase()!==expected.toLowerCase())
                failure('runtime.form.transfer.undefined','The part header conflicts with its schema transfer encoding',transfer.source??schema);
            const transferEncoding=actual??expected??'binary',decoded=decodeMultipartTransfer(part.bytes,transferEncoding),bytes=decoded.bytes;
            const serialization=multipartTextSerialization(part.bytes,transferEncoding,decoded,unicode!==undefined);
            if(transfer.schemaEncoded){
                if(serialization||runtimeMediaKind(concrete)!=='opaque')decodeRuntimeMedia(bytes.toString('base64'),id+'/encoded-media',decodingType,true,'unsupported',serialization);
                return JSON.stringify(decoded.encoded??bytesText(bytes,'text/plain; charset=utf-8',serialization));
            }
            if(transfer.instanceEncoding==='octets'){
                if(serialization)decodeRuntimeMedia(bytes.toString('base64'),id+'/octet-media',decodingType,true,'octets',serialization);
                return JSON.stringify(bytes.toString('latin1'));
            }
            const essence=mediaTypes(concrete,false)[0],json=essence.subtype==='json'||essence.subtype.endsWith('+json');
            if(json)return decodeRuntimeMedia(bytes.toString('base64'),id+'/json',concrete,true,'unsupported',serialization).document.dataJson('');
            if(essence.type==='text'&&essence.subtype==='plain')return scalar(bytesText(bytes,decodingType,serialization),type);
            if(scope.family==='3.0')return decodeRuntimeMedia(bytes.toString('base64'),id+'/octets',concrete,true,'legacy-octets',serialization).document.dataJson('');
            if(scope.family==='3.1'||scope.family==='3.2'){
                const value=decodeRuntimeMedia(bytes.toString('base64'),id+'/binary',concrete,true,'binary',serialization);
                const leaf=value.binaryInstances?.get(value.document)?.get('');
                if(leaf!==undefined){binary.set(pointer,leaf);return value.document.dataJson('');}
            }
            return failure('runtime.form.media.unsupported','This field has no native media decoder',schema);
        };
        const names=new Set([...Object.keys(properties),...Object.keys(encoding),...input.map(part=>part.name)]);
        for(const name of names){
            const field=properties[name]??{},rule=object(encoding[name])?encoding[name]:{},type=formLiteralType(field);
            const named=input.filter(part=>part.name===name);
            if((Object.hasOwn(properties,name)||Object.hasOwn(encoding,name))&&named.some(part=>claimed.has(part)&&claimed.get(part)!==name))
                failure('runtime.form.ambiguous','Two form declarations claim the same wire field',schema);
            const values=named.filter(part=>!claimed.has(part));
            if(styled(rule)){
                const style=typeof rule.style==='string'?rule.style:'form',explode=typeof rule.explode==='boolean'?rule.explode:style==='form';
                const separator=style==='spaceDelimited'?' ':style==='pipeDelimited'?'|':style==='tabDelimited'?'\t':',';
                const read=(part:Part)=>{
                    const value=payload(part);return bytesText(value.bytes,multipart?mimePartDecodingType(singleton(part.headers,'content-type')??'text/plain',mediaTypes(contentType,false)[0].subtype==='form-data'):'text/plain; charset=utf-8',value.serialization);
                };
                for(const part of values)partHeaders(part,rule,name);
                const split=(part:Part)=>part.encoded&&separator===','?part.encoded.toString('latin1').split(',').map(token=>utf8(unquote(Buffer.from(token,'latin1')))):read(part).split(separator);
                if(type==='object'){
                    const keys=field.properties??{},entries:[string,string][]=[];
                    if(style==='deepObject'||style==='form'&&explode){
                        if(style==='deepObject'&&!explode)failure('runtime.form.style.unsupported','deepObject without explode has no defined interpretation',schema);
                        for(const part of input){
                            const key=style==='deepObject'&&part.name.startsWith(name+'[')&&part.name.endsWith(']')?part.name.slice(name.length+1,-1):style==='form'&&Object.hasOwn(keys,part.name)?part.name:undefined;
                            if(key===undefined)continue;claim(part,name);entries.push([key,scalar(read(part),formLiteralType(keys[key]??{}))]);
                        }
                    }else if(values.length){
                        if(values.length!==1)return syntax('A separated object occurs more than once');
                        claim(values[0],name);const tokens=split(values[0]);
                        if(tokens.length%2)return syntax('A separated form object needs paired keys and values');
                        for(let index=0;index<tokens.length;index+=2)entries.push([tokens[index],scalar(tokens[index+1],formLiteralType(keys[tokens[index]]??{}))]);
                    }
                    if(entries.length){if(new Set(entries.map(([key])=>key)).size!==entries.length)return syntax('A form object property occurs more than once');members.set(name,'{'+entries.map(([key,value])=>JSON.stringify(key)+':'+value).join(',')+'}');}
                }else if(values.length){
                    values.forEach(part=>claim(part,name));
                    if(type==='array'){
                        const items=field.items??{},itemType=formLiteralType(items);
                        const tokens=explode?values.map(read):values.length===1?split(values[0]):failure('runtime.form.style','A separated array occurs more than once',schema,false);
                        members.set(name,'['+tokens.map(token=>scalar(token,itemType)).join(',')+']');
                    }else{if(values.length!==1)return syntax('A scalar form property occurs more than once');members.set(name,scalar(read(values[0]),type));}
                }
                continue;
            }
            if(!values.length)continue;
            values.forEach(part=>claim(part,name));
            const selected=selectedShapes[name],array=selected!==undefined?selected==='array':type==='array'||values.length>1;
            if(!array&&values.length>1||selected===undefined&&values.length>1&&type!==undefined&&type!=='array'&&scope.family!=='3.2')return syntax('A non-array form property occurs more than once');
            const item=array?field.items??{}:field,raw=values.map((part,index)=>literal(part,item,rule,name,array,'/'+escape(name)+(array?'/'+index:'')));
            members.set(name,array?'['+raw.join(',')+']':raw[0]);
        }
    }
    if(unicode&&multipart&&input.some(part=>!claimed.has(part)))failure('runtime.media.unicode.unsupported','An uninterpreted MIME field has no established Unicode serialization');
    const result=document('{'+[...members].map(([name,value])=>JSON.stringify(name)+':'+value).join(',')+'}','body');
    return {document:result,...(binary.size?{binaryInstances:new Map<SourceDocument,BinaryLocations>([[result,binary]])}:{}),kind:multipart?'multipart-form':'form-urlencoded',checks,issues};
}
