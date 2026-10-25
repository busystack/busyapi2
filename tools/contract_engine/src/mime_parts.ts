import {SourceError} from './document';
import {mediaTypes} from './media_types';

export type MimePart={bytes:Buffer;headers:ReadonlyMap<string,string[]>};
const syntax=(message:string):never=>{throw new SourceError('runtime.form.syntax',message);};

export function mimeSingleton(headers:ReadonlyMap<string,string[]>,name:string):string|undefined {
    const values=headers.get(name);
    if(values&&values.length!==1)return syntax('A singleton MIME part header occurs more than once');
    return values?.[0];
}

/** RFC 2046 §4.1.2 defaults generic MIME text to US-ASCII. Form-data
 * retains the separate RFC 7578 charset policy used by the named form codec. */
export function mimePartDecodingType(contentType:string,formData:boolean):string {
    const type=mediaTypes(contentType,false)[0];
    return !formData&&type.type==='text'&&!type.parameters.has('charset')?contentType+'; charset=us-ascii':contentType;
}

/** Bounded RFC 2046 framing, shared by named and ordered multipart bindings.
 * Part octets, order, preamble and epilogue do not pass through serialization.
 * Content-Disposition belongs to the binding, not to generic MIME framing. */
export function mimeParts(bytes:Buffer,contentType:string):MimePart[] {
    const types=mediaTypes(contentType,false),type=types[0];
    if(types.length!==1||type.type!=='multipart')return syntax('A multipart representation needs one multipart Content-Type');
    const boundary=type.parameters.get('boundary');
    if(boundary===undefined||boundary.length<1||boundary.length>70||!/^[0-9A-Za-z'()+_,\-./:=? ]*[0-9A-Za-z'()+_,\-./:=?]$/.test(boundary))return syntax('A multipart boundary must follow RFC 2046');
    const marker=Buffer.from('--'+boundary,'ascii'),line=Buffer.from('\r\n');
    const delimiter=(start:number):{at:number;after:number;closed:boolean}|undefined=>{
        let at=bytes.indexOf(marker,start);
        while(at>=0){
            if(at===0||bytes.subarray(at-2,at).equals(line)){
                let after=at+marker.length,closed=false;
                if(bytes.subarray(after,after+2).equals(Buffer.from('--'))){closed=true;after+=2;}
                while(bytes[after]===32||bytes[after]===9)after++;
                if(bytes.subarray(after,after+2).equals(line))return {at,after:after+2,closed};
                if(closed&&after===bytes.length)return {at,after,closed};
            }
            at=bytes.indexOf(marker,at+marker.length);
        }
    };
    let current=delimiter(0);
    if(!current)return syntax('The multipart body has no initial delimiter');
    const result:MimePart[]=[];
    while(!current.closed){
        const next=delimiter(current.after);
        if(!next)return syntax('The multipart body has no closing delimiter');
        const end=next.at-2;
        if(end<current.after)return syntax('A multipart part is missing its delimiter line break');
        const absent=end===current.after,empty=absent||bytes.subarray(current.after,current.after+2).equals(line);
        const headerEnd=empty?current.after:bytes.indexOf(Buffer.from('\r\n\r\n'),current.after);
        // RFC 2046 §5.1.1 permits omission of the body area, including its
        // separating CRLF, when the part has no body octets.
        let bodyStart=absent?end:headerEnd+(empty?2:4);
        if(!empty&&headerEnd+2===end)bodyStart=end;
        if(headerEnd<current.after||bodyStart>end||headerEnd-current.after>16384)return syntax('Multipart headers are unfinished or exceed 16 KiB');
        const headerBytes=bytes.subarray(current.after,headerEnd);
        if(type.subtype!=='form-data'&&headerBytes.some(byte=>byte>127))return syntax('Generic MIME part headers require ASCII text or encoded words');
        // MIME token names are ASCII; field values retain their UTF-8 text. The
        // strict text conversion also prevents malformed octets becoming names.
        let text:string;
        try{text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(headerBytes);}
        catch(error){if(error instanceof TypeError)return syntax('A multipart header is not UTF-8');throw error;}
        const headers=new Map<string,string[]>(),lines=empty?[]:text.replace(/\r\n[ \t]+/g,' ').split('\r\n');
        if(lines.length>64)throw new SourceError('limit.runtime.form.headers','A multipart part exceeds 64 header fields');
        for(const value of lines){
            const colon=value.indexOf(':'),originalName=value.slice(0,colon),name=originalName.toLowerCase();
            if(colon<1||!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(originalName)||/[\x00-\x08\x0a-\x1f\x7f]/.test(value))return syntax('A multipart header is malformed');
            const values=headers.get(name)??[];values.push(value.slice(colon+1).replace(/^[ \t]+|[ \t]+$/g,''));headers.set(name,values);
        }
        result.push({bytes:bytes.subarray(bodyStart,end),headers});
        if(result.length>2048)throw new SourceError('limit.runtime.form','A multipart body exceeds 2048 parts');
        current=next;
    }
    return result;
}
