import {SourceError} from './document';
import {mediaTypes} from './media_types';
import {mimeParts,mimeSingleton,mimePartDecodingType} from './mime_parts';
import {runtimeMediaBytes} from './runtime_media';
import {declaredPlainTextBytes} from './text_encoding';

export const embeddedMimeTextRevision='1';
type Replacement=Readonly<{start:number;end:number;bytes:Buffer}>;

/** Logical embedded strings use each MIME leaf's declared character set.
 * The framing parser supplies byte spans, so headers, boundaries, transfer
 * representations, preamble and epilogue retain their exact spelling.
 * Captured byte inputs and authored OAS 3.2 serializedValue evaluation bypass
 * this path. Raw request construction retains separate conformance checks.
 * RFC 2045 §§5–6; RFC 2046 §5.1; RFC 7578 §4.4; OAS 3.0 §4.7.19.1. */
export function embeddedMimeTextBytes(text:string,contentType:string):Buffer {
    if(Buffer.byteLength(text)>64*1024*1024)
        throw new SourceError('limit.runtime.mime-text','Embedded MIME text exceeds 64 MiB');
    const original=runtimeMediaBytes(text,false),replacements:Replacement[]=[];
    let parts=0;
    const visit=(bytes:Buffer,type:string,offset:number,depth:number)=>{
        if(depth>8)throw new SourceError('limit.runtime.mime-text.depth','Embedded MIME text exceeds eight nested multipart levels');
        const concrete=mediaTypes(type,false);
        if(concrete.length!==1||concrete[0].type!=='multipart')
            throw new SourceError('runtime.mime-text.type','Embedded MIME text requires one concrete multipart media type');
        const form=concrete[0].subtype==='form-data';
        for(const part of mimeParts(bytes,type)){
            if(++parts>16384)throw new SourceError('limit.runtime.mime-text.parts','Embedded MIME text exceeds 16384 total parts');
            const actual=mimeSingleton(part.headers,'content-type')??(concrete[0].subtype==='digest'?'message/rfc822':'text/plain');
            const selected=mediaTypes(actual,false);
            if(selected.length!==1)throw new SourceError('runtime.mime-text.type','A MIME part requires one concrete media type');
            const transfer=(mimeSingleton(part.headers,'content-transfer-encoding')??'binary').toLowerCase();
            const start=offset+part.bodyRange[0],end=offset+part.bodyRange[1];
            if(selected[0].type==='multipart'){
                if(!['binary','7bit','8bit'].includes(transfer))
                    throw new SourceError('runtime.mime-text.transfer','A multipart entity permits only binary, 7bit or 8bit transfer encoding');
                visit(part.bytes,actual,start,depth+1);continue;
            }
            // Transfer-encoded leaf bodies already contain their wire text.
            // Their decoding and validation remain owned by the MIME evaluator.
            if(['base64','quoted-printable'].includes(transfer))continue;
            if(!['binary','7bit','8bit'].includes(transfer))
                throw new SourceError('runtime.mime-text.transfer.unsupported','This MIME transfer encoding has no text materializer',[0,0],'unsupported');
            if(selected[0].type!=='text'||selected[0].subtype!=='plain')continue;
            const decoding=mediaTypes(mimePartDecodingType(actual,form),false)[0];
            let logical:string;
            try{logical=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(part.bytes);}
            catch(error){if(error instanceof TypeError)throw new SourceError('runtime.media.encoding','Embedded MIME text contains invalid UTF-8');throw error;}
            const encoded=declaredPlainTextBytes(logical,decoding.parameters.get('charset'));
            if(!part.bytes.equals(encoded))replacements.push({start,end,bytes:encoded});
        }
    };
    visit(original,contentType,0,0);
    if(!replacements.length)return original;
    const chunks:Buffer[]=[];let offset=0;
    for(const replacement of replacements){
        chunks.push(original.subarray(offset,replacement.start),replacement.bytes);offset=replacement.end;
    }
    chunks.push(original.subarray(offset));
    return Buffer.concat(chunks);
}
