import {SourceDocument,SourceError} from './document';
import {mediaTypes} from './media_types';
import {runtimeBinaryMedia,type BinaryDocuments} from './runtime_binary';

export type RuntimeMediaKind='json'|'text'|'json-lines'|'json-sequence'|'event-stream'|'opaque';
export type RuntimeMediaData={document:SourceDocument;items?:SourceDocument[];binaryInstances?:BinaryDocuments;kind:RuntimeMediaKind|'binary'|'file'|'octets'|'form-urlencoded'|'multipart-form'|'multipart-sequence'};
export type RuntimeMediaDescription=
 {dataModelStatus:'classified'|'opaque';dataModel:RuntimeMediaKind}|
 {dataModelStatus:'invalid'|'unsupported';dataModelIssue:{code:string;message:string}};

/** Multipart data needs its captured Media Type/Encoding owner in addition to
 * byte framing. The form decoder chooses the binding from that graph scope. */
export function runtimeFormMedia(contentType:string):boolean {
 const essence=contentType.split(';')[0].trim().toLowerCase();
 return essence==='application/x-www-form-urlencoded'||essence.startsWith('multipart/');
}

/** Inspect every authored choice without letting one malformed declaration
 * hide valid later choices. Invalid/unsupported metadata has no invented data
 * model. Actual byte decoding retains its separate, strict failure boundary. */
export function runtimeMediaDescription(contentType:string):RuntimeMediaDescription {
 try{
  const dataModel=runtimeMediaKind(contentType,true);
  return {dataModelStatus:dataModel==='opaque'?'opaque':'classified',dataModel};
 }catch(error){
  if(!(error instanceof SourceError)||!['encoding.content-type','runtime.media.type','request.form.media-parameters.unsupported','limit.media.type','limit.encoding.content-types'].includes(error.code))throw error;
  return {dataModelStatus:error.kind==='unsupported'||error.code.startsWith('limit.')?'unsupported':'invalid',dataModelIssue:{code:error.code,message:error.message}};
 }
}

export function runtimeMediaBytes(text:string,base64:boolean):Buffer {
 if(!base64){
  const bytes=Buffer.from(text,'utf8');
  if(bytes.toString('utf8')!==text)throw new SourceError('runtime.media.encoding','The wire text contains an unpaired Unicode surrogate');
  return bytes;
 }
 if(text.length%4!==0)throw new SourceError('runtime.instance','Runtime byte input requires canonical base64');
 const bytes=Buffer.from(text,'base64');
 if(bytes.toString('base64')!==text)throw new SourceError('runtime.instance','Runtime byte input requires canonical base64');
 return bytes;
}

/** Media framing is separate from Schema Object evaluation. In particular,
 * sequence records retain their CST numeric lexemes when assembled as an array
 * (OAS 3.2 §4.14.3); this never passes execution data through JSON.parse. */
export function runtimeMediaKind(contentType:string,ranges=false):RuntimeMediaKind {
 const type=mediaTypes(contentType,ranges);
 if(type.length!==1)throw new SourceError('runtime.media.type','Runtime content requires one concrete media type');
 const {type:primary,subtype}=type[0];
 if(primary==='application'&&subtype==='json'||subtype.endsWith('+json'))return 'json';
 if(primary==='text'&&subtype==='plain')return 'text';
 if(primary==='application'&&['jsonl','x-ndjson'].includes(subtype))return 'json-lines';
 if(primary==='application'&&(subtype==='json-seq'||subtype.endsWith('+json-seq')))return 'json-sequence';
 if(primary==='text'&&subtype==='event-stream')return 'event-stream';
 return 'opaque';
}

export function decodeRuntimeMedia(text:string,id:string,contentType?:string,base64=false,opaque:'unsupported'|'octets'|'binary'|'legacy-octets'|'file'='unsupported'):RuntimeMediaData {
 const type=contentType===undefined?undefined:mediaTypes(contentType,false);
 if(type&&type.length!==1)throw new SourceError('runtime.media.type','Runtime content requires one concrete media type');
 const kind=contentType===undefined?'json':runtimeMediaKind(contentType);
 let bytes:Buffer|undefined;
 if(base64)bytes=runtimeMediaBytes(text,true);
 const parse=(value:string,suffix='')=>{
  const doc=new SourceDocument(value,id+suffix,true,'json');
  if(doc.issues.length)throw doc.issues[0];
  return doc;
 };
 if(opaque==='file'){
  if(bytes===undefined)runtimeMediaBytes(text,false);
  return {document:parse('null'),kind:'file'};
 }
 if(kind==='opaque'){
  const binary=contentType!==undefined&&runtimeBinaryMedia(contentType);
  if(opaque==='binary'&&binary){
   const document=parse('null');
   return {document,kind:'binary',binaryInstances:new Map([[document,new Map([['',bytes??runtimeMediaBytes(text,false)]])]])};
  }
  if(opaque!=='octets'&&!(opaque==='legacy-octets'&&binary))throw new SourceError('runtime.media.unsupported','This media type has no native data-model decoder',[0,0],'unsupported');
  // Swagger §6.3 / OAS 3.0 §4.4.2 extend string to arbitrary octets. The one-to-one
  // U+0000–U+00FF view preserves every byte and counts length in octets. It is
  // selected by captured legacy schema semantics or known binary media, never by
  // a modern format annotation or a file extension.
  const value=(bytes??Buffer.from(text,'utf8')).toString('latin1');
  return {document:parse(JSON.stringify(value)),kind:'octets'};
 }
 try{if(bytes){
  const charset=type?.[0].parameters.get('charset')??'utf-8';
  const utf8=charset==='utf-8'||charset==='utf8';
  if(kind==='event-stream')text=new TextDecoder('utf-8',{ignoreBOM:true}).decode(bytes);
  else if(kind!=='text'&&!utf8&&charset!=='us-ascii')throw new SourceError('runtime.media.charset','This media type requires UTF-8');
  else if(utf8)text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(bytes);
  else if(charset==='iso-8859-1'||charset==='latin1')text=bytes.toString('latin1');
  else if(charset==='us-ascii'){
   if(bytes.some(byte=>byte>127))throw new SourceError('runtime.media.charset','The text contains non-ASCII octets');
   text=bytes.toString('ascii');
  }else throw new SourceError('runtime.media.unsupported','The declared charset has no native text decoder',[0,0],'unsupported');
 }}catch(error){
  if(error instanceof TypeError)throw new SourceError('runtime.media.encoding','The bytes do not use the required text encoding');
  throw error;
 }
 if(kind==='json')return {document:parse(text),kind};
 if(kind==='text')return {document:parse(JSON.stringify(text)),kind};
 const items:SourceDocument[]=[];
 const append=(value:string)=>{
  if(items.length>=2048)throw new SourceError('limit.runtime.items','Runtime content exceeds 2048 sequence items');
  items.push(parse(value,'/item/'+items.length));
 };
 if(kind==='json-lines'){
  if(text.startsWith('\ufeff'))throw new SourceError('runtime.media.syntax','JSON Lines cannot begin with a byte order mark');
  const lines=text.split('\n');
  if(lines.at(-1)==='')lines.pop();
  // Finite JSON Lines permits an unterminated final record. Empty lines are
  // rejected for both line-oriented formats rather than silently dropping data.
  for(const line of lines){
   if(line.replace(/\r$/,'').includes('\r'))throw new SourceError('runtime.media.syntax','JSON Lines requires LF or CRLF separators');
   append(line);
  }
 }else if(kind==='json-sequence'){
  if(text!==''&&!text.startsWith('\x1e'))throw new SourceError('runtime.media.syntax','A JSON text sequence requires a record separator');
  for(const record of text.split('\x1e').slice(1)){
   if(record==='')continue; // RFC 7464 §2.1: consecutive RS are not empty items.
   const doc=parse(record,'/item/'+items.length);
   if(['number','boolean','null'].includes(doc.root.kind)&&!/[\x20\t\r\n]$/.test(record))
    throw new SourceError('runtime.media.syntax','A scalar sequence record needs trailing whitespace to prove it is not truncated');
   if(items.length>=2048)throw new SourceError('limit.runtime.items','Runtime content exceeds 2048 sequence items');
   items.push(doc);
  }
 }else{
  // WHATWG HTML §9.2.5–6. Only dispatched data events enter the array;
  // comments/unknown fields and an unfinished final event are not messages.
  const lines=text.replace(/^\ufeff/,'').split(/\r\n|\r|\n/);
  if(lines.at(-1)==='')lines.pop();
  let data:string[]=[],event:string|undefined,eventId:string|undefined,retry:string|undefined;
  for(const line of lines){
   if(line===''){
    if(data.length)append('{"data":'+JSON.stringify(data.join('\n'))+
     (event!==undefined?',"event":'+JSON.stringify(event===''?'message':event):'')+
     (eventId!==undefined?',"id":'+JSON.stringify(eventId):'')+
     (retry!==undefined?',"retry":'+retry:'')+'}');
    data=[];event=undefined;eventId=undefined;retry=undefined;continue;
   }
   if(line.startsWith(':'))continue;
   const colon=line.indexOf(':'),name=colon<0?line:line.slice(0,colon);
   let value=colon<0?'':line.slice(colon+1);if(value.startsWith(' '))value=value.slice(1);
   if(name==='data')data.push(value);
   else if(name==='event')event=value;
   else if(name==='id'&&!value.includes('\0'))eventId=value;
   else if(name==='retry'&&/^[0-9]+$/.test(value))retry=value.replace(/^0+(?=\d)/,'');
  }
 }
 return {document:parse('['+items.map(item=>item.dataJson('')).join(',')+']'),items,kind};
}
