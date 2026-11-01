import {SourceError} from './document';
import {headerValueParts} from './header_values';

export type HttpCredentialScheme='basic'|'bearer'|'digest';
type Syntax='valid'|'invalid'|'unsupported';
const token=/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
type Parameter={value:string;quoted:boolean};

function basic(value:string):boolean {
    // RFC 7617 §2: only the first colon separates the username/password.
    // Strict canonical Base64 avoids Node's permissive invalid-byte decoder.
    if(!value.length||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value))return false;
    const bytes=Buffer.from(value,'base64');
    return bytes.toString('base64')===value&&bytes.includes(58)&&!bytes.some(byte=>byte<32||byte===127);
}

function parameters(value:string):Map<string,Parameter>|undefined {
    let fields:string[];
    try{fields=headerValueParts(value);}catch(error){if(error instanceof SourceError)return;throw error;}
    const result=new Map<string,Parameter>();
    for(const field of fields){
        if(!field)continue; // HTTP list syntax permits empty list members.
        const at=field.indexOf('='),name=field.slice(0,at).trim().toLowerCase(),raw=field.slice(at+1).trim();
        if(at<1||!token.test(name)||result.has(name))return;
        const quoted=raw.startsWith('"');let decoded='';
        if(quoted){
            if(raw.length<2||!raw.endsWith('"'))return;
            for(let index=1;index<raw.length-1;index++){
                let character=raw[index];
                if(character==='\\'){if(++index>=raw.length-1)return;character=raw[index];}
                else if(character==='"')return;
                if(character!=='\t'&&(character.charCodeAt(0)<32||character.charCodeAt(0)===127))return;
                decoded+=character;
            }
        }else {if(!token.test(raw))return;decoded=raw;}
        result.set(name,{value:decoded,quoted});
    }
    return result;
}

function digest(value:string):Syntax {
    const fields=parameters(value);if(!fields)return 'invalid';
    const username=fields.get('username'),extended=fields.get('username*');
    if(Boolean(username)===Boolean(extended))return 'invalid';
    if(username&&!username.quoted||extended&&extended.quoted)return 'invalid';
    if(extended){
        if(!/^UTF-8'[A-Za-z0-9-]*'(?:[A-Za-z0-9!#$&+.^_`|~-]|%[0-9a-f]{2})*$/i.test(extended.value))return 'unsupported';
        try{decodeURIComponent(extended.value.slice(extended.value.indexOf("'",6)+1));}
        catch(error){if(error instanceof URIError)return 'invalid';throw error;}
    }
    // RFC 7616 §3.4 distinguishes quoted values from token directives.
    for(const name of ['realm','nonce','uri','response'])if(fields.get(name)?.quoted!==true)return 'invalid';
    const algorithm=fields.get('algorithm');if(algorithm?.quoted)return 'invalid';
    const selected=(algorithm?.value??'MD5').toUpperCase(),base=selected.replace(/-SESS$/,'');
    if(!['MD5','SHA-256','SHA-512-256'].includes(base))return 'unsupported';
    const response=fields.get('response')!.value;
    if(!new RegExp('^[0-9a-f]{'+(base==='MD5'?32:64)+'}$','i').test(response))return 'invalid';
    const qop=fields.get('qop'),nc=fields.get('nc'),cnonce=fields.get('cnonce');
    if(qop){
        if(qop.quoted||!['auth','auth-int'].includes(qop.value)||nc?.quoted!==false||!/^[0-9a-f]{8}$/i.test(nc.value)||cnonce?.quoted!==true)return 'invalid';
    }else if(nc||cnonce&&!selected.endsWith('-SESS'))return 'invalid';
    if(selected.endsWith('-SESS')&&cnonce?.quoted!==true)return 'invalid';
    if(fields.has('userhash')&&(fields.get('userhash')!.quoted||!['true','false'].includes(fields.get('userhash')!.value)))return 'invalid';
    return 'valid';
}

/** Wire grammar only, without password, issuer, nonce or certificate trust. */
export function httpCredentialSyntax(scheme:HttpCredentialScheme,value:string):Syntax {
    return scheme==='basic'?(basic(value)?'valid':'invalid'):scheme==='bearer'?(/^[A-Za-z0-9._~+/-]+=*$/.test(value)?'valid':'invalid'):digest(value);
}
