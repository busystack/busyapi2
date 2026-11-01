import {SourceError} from './document';
import type {TextSerialization} from './runtime_media';

export type DecodedMultipartTransfer={bytes:Buffer;encoded?:string};
const invalid=():never=>{throw new SourceError('runtime.multipart.encoding','The part does not use its declared MIME transfer encoding');};

/** OAS 3.2 §4.19.2.3: a known ASCII transfer format establishes the wire
 * serialization independently of the decoded media's character set. RFC 2045
 * §§2.7, 6.7–6.8; other parts still need their media's Unicode proof. */
export function multipartTextSerialization(bytes:Buffer,encoding:string,decoded:DecodedMultipartTransfer,requested:boolean):TextSerialization|undefined {
    if(!requested)return;
    if(decoded.encoded!==undefined||encoding.toLowerCase()==='7bit'){
        if(bytes.some(byte=>byte>127))throw new SourceError('runtime.media.unicode.unsupported','This MIME transfer representation contains non-ASCII octets; use an external serialized resource',[0,0],'unsupported');
        return;
    }
    return 'unicode';
}

/** Finite MIME representation decoding (RFC 2045 §§2,6; RFC 4648). The
 * caller retains the original bytes; this value is for instance evaluation. */
export function decodeMultipartTransfer(bytes:Buffer,encoding:string):DecodedMultipartTransfer {
    if(!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(encoding))return invalid();
    const codec=encoding.toLowerCase();
    if(['binary','identity','7bit','8bit'].includes(codec)){
        if(codec==='7bit'||codec==='8bit'){
            let column=0,carriage=false;
            for(const byte of bytes){
                if(byte===0||codec==='7bit'&&byte>127||carriage&&byte!==10||byte===10&&!carriage)return invalid();
                if(byte===13)carriage=true;
                else if(byte===10){column=0;carriage=false;}
                else if(++column>998)return invalid();
            }
            if(carriage)return invalid();
        }
        return {bytes};
    }
    const literal=bytes.toString('latin1');
    if(codec==='base64'||codec==='base64url'){
        // RFC 2045 §6.8 requires MIME decoders to ignore non-alphabet input.
        // RFC 4648 base64url has no corresponding MIME exception.
        const encoded=codec==='base64'?literal.replace(/[^A-Za-z0-9+/=]/g,''):literal;
        if(encoded.length%4!==0||!(codec==='base64'?/^[A-Za-z0-9+/]*={0,2}$/:/^[A-Za-z0-9_-]*={0,2}$/).test(encoded))return invalid();
        const value=Buffer.from(encoded,codec==='base64'?'base64':'base64url');
        const canonical=codec==='base64'?value.toString('base64'):value.toString('base64url').padEnd(Math.ceil(value.length/3)*4,'=');
        if(canonical!==encoded)return invalid();
        // MIME decoding ignores non-alphabet input, but the OAS model's
        // encoded string still retains its supplied spelling. CRLF is the
        // transport line folding added by the native sender; other characters
        // remain available to string assertions (RFC 2045 §6.8).
        return {bytes:value,encoded:codec==='base64'?literal.replace(/\r\n/g,''):encoded};
    }
    if(codec==='base16'){
        if(literal.length%2||!/^[0-9A-Fa-f]*$/.test(literal))return invalid();
        return {bytes:Buffer.from(literal,'hex'),encoded:literal};
    }
    if(codec==='base32'||codec==='base32hex'){
        if(literal.length%8)return invalid();
        const alphabet=codec==='base32'?'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567':'0123456789ABCDEFGHIJKLMNOPQRSTUV';
        const firstPadding=literal.indexOf('='),end=firstPadding<0?literal.length:firstPadding,padding=literal.length-end;
        if(![0,1,3,4,6].includes(padding)||!/^[=]*$/.test(literal.slice(end)))return invalid();
        let bits=0,value=0;const output:number[]=[];
        for(const character of literal.slice(0,end)){
            const digit=alphabet.indexOf(character.toUpperCase());if(digit<0)return invalid();
            value=(value<<5)|digit;bits+=5;
            if(bits>=8){bits-=8;output.push(value>>bits);value&=(1<<bits)-1;}
        }
        const expectedBits:Record<number,number>={0:0,1:3,3:1,4:4,6:2};
        if(value!==0||expectedBits[padding]!==bits)return invalid();
        return {bytes:Buffer.from(output),encoded:literal};
    }
    if(codec==='quoted-printable'){
        const output:number[]=[];let column=0;
        for(let index=0;index<bytes.length;index++){
            const byte=bytes[index];
            if(byte===61){
                if(++column>76)return invalid();
                if(bytes[index+1]===13&&bytes[index+2]===10){index+=2;column=0;continue;}
                const hex=bytes.subarray(index+1,index+3).toString('latin1');
                if(!/^[0-9A-Fa-f]{2}$/.test(hex)||column+2>76)return invalid();
                output.push(Number.parseInt(hex,16));index+=2;column+=2;
            }else if(byte===13){
                if(bytes[index+1]!==10)return invalid();
                output.push(13,10);index++;column=0;
            }else{
                if(++column>76||byte!==9&&byte!==32&&(byte<33||byte>126))return invalid();
                // RFC 2045 §6.7: trailing whitespace is transport padding.
                if(byte===9||byte===32){
                    let after=index+1;while(bytes[after]===9||bytes[after]===32)after++;
                    if(after===bytes.length||bytes[after]===13){column+=after-index-1;if(column>76)return invalid();index=after-1;continue;}
                }
                output.push(byte);
            }
        }
        return {bytes:Buffer.from(output),encoded:literal};
    }
    throw new SourceError('runtime.multipart.encoding.unsupported','The declared MIME transfer encoding has no native decoder',[0,0],'unsupported');
}
