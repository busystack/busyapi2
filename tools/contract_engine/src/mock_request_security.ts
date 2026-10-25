import {SourceError} from './document';
import {record} from './engine_worker_client';
import {sourceLocation,type SourceLocation,type NativeMockCheck} from './mock_projection';
import {httpCredentialSyntax} from './http_credentials';

type Requirement={names:string[];source:SourceLocation};
type Credential={valid:boolean;complete:boolean;reason:string;challenge?:string};
type Scheme=({kind:'apiKey';location:'header'|'query'|'cookie';name:string}|{kind:'http';http:string}|{kind:'mutualTLS'|'unsupported'})&{definition:SourceLocation};
function protocol(message:string):never {throw new SourceError('mock.validation.protocol',message);}
const present:Credential={valid:true,complete:true,reason:'present'};
const invalid=(reason:string,challenge?:string):Credential=>({valid:false,complete:true,reason,challenge});
const unsupported=(reason:string):Credential=>({valid:false,complete:false,reason});
export const mockSecurityProducer=Object.freeze({name:'busyapi-native-security',version:'1'});

function securityProjection(value:unknown):{requirements:Requirement[];schemes:ReadonlyMap<string,Scheme>} {
    if(!record(value)||!Array.isArray(value.requirements)||value.requirements.length>2048||!record(value.schemes))protocol('The captured security projection is malformed');
    const requirements=value.requirements.map((entry:unknown)=>{
        if(!record(entry)||!Array.isArray(entry.schemes)||entry.schemes.length>2048||!entry.schemes.every(name=>typeof name==='string'))protocol('The captured Security Requirement is malformed');
        const source=sourceLocation(entry.source);if(!source)protocol('The captured Security Requirement omitted its source');
        return {names:entry.schemes,source};
    });
    const schemes=new Map<string,Scheme>();
    for(const requirement of requirements)for(const name of requirement.names)if(!schemes.has(name)){
        const entry=Object.hasOwn(value.schemes,name)?value.schemes[name]:undefined;
        if(!record(entry)||typeof entry.type!=='string')protocol('The captured Security Scheme is malformed');
        const definition=sourceLocation(entry.definition??entry.source);if(!definition)protocol('The captured Security Scheme omitted its definition');
        if(entry.type==='apiKey'){
            if(typeof entry.parameterName!=='string'||entry.in!=='header'&&entry.in!=='query'&&entry.in!=='cookie')protocol('The captured API key location is malformed');
            schemes.set(name,{kind:'apiKey',definition,location:entry.in,name:entry.parameterName});
        }else if(entry.type==='http'){
            if(typeof entry.scheme!=='string')protocol('The captured HTTP authentication scheme is malformed');
            schemes.set(name,{kind:'http',definition,http:entry.scheme});
        }else if(entry.type==='oauth2'||entry.type==='openIdConnect')schemes.set(name,{kind:'http',definition,http:'bearer'});
        else schemes.set(name,{kind:entry.type==='mutualTLS'?'mutualTLS':'unsupported',definition});
    }
    return {requirements,schemes};
}

/** Interpret credential fields only. A contract has no password/token database
 * or issuer trust configuration; this never proves an identity, scope or role.
 * Requirement OR/AND and scheme identities come from the existing graph-owned
 * execution projection (2.0 §6.4.26; 3.0 §4.7.30; 3.1 §4.8.30; 3.2 §4.30). */
export function validateMockSecurity(value:unknown,query:string,rawHeaders:readonly string[],signal:AbortSignal):NativeMockCheck {
    if(signal.aborted)throw new SourceError('cancelled','Mock security validation was cancelled');
    const {requirements,schemes}=securityProjection(value);
    if(!requirements.length||requirements.some(requirement=>!requirement.names.length))return {complete:true,valid:true,findings:[]};
    if(query.length>65536||rawHeaders.length>8192)return {complete:false,valid:false,findings:[{code:'runtime.request.security.limit',kind:'unsupported',severity:'warning',subject:'request-security',pointer:'',source:requirements[0].source,message:'Credential field inspection exceeds its bounded input.'}]};
    const headers=new Map<string,string[]>();
    for(let index=0;index<rawHeaders.length;index+=2){
        const name=rawHeaders[index].toLowerCase();headers.set(name,[...(headers.get(name)??[]),rawHeaders[index+1]]);
    }
    const parameters=new URLSearchParams(query),cookies=new Map<string,string[]>();
    // RFC 6265 §4.2: semicolons separate complete cookie-pairs. Neither name
    // suffixes nor an ampersand inside another cookie's value grant a key.
    for(const line of headers.get('cookie')??[])for(const field of line.split(';')){
        const pair=field.replace(/^[ \t]+/,''),at=pair.indexOf('=');if(at<0)continue;
        const name=pair.slice(0,at),value=pair.slice(at+1);
        cookies.set(name,[...(cookies.get(name)??[]),value]);
    }
    const credential=(scheme:Scheme):Credential=>{
        if(scheme.kind==='apiKey'){
            const values=scheme.location==='header'?headers.get(scheme.name.toLowerCase())??[]:
                scheme.location==='query'?parameters.getAll(scheme.name):cookies.get(scheme.name)??[];
            // OAS imposes no minimum credential length. Presence is distinct
            // from truthiness; repeated credential fields are ambiguous.
            if(values.length!==1)return invalid(values.length?'ambiguous':'missing');
            if(scheme.location==='cookie'&&!/^(?:[\x21\x23-\x2b\x2d-\x3a\x3c-\x5b\x5d-\x7e]*|"[\x21\x23-\x2b\x2d-\x3a\x3c-\x5b\x5d-\x7e]*")$/.test(values[0]))return invalid('credential-syntax');
            return present;
        }
        if(scheme.kind==='mutualTLS')return unsupported('mutual-tls-proof-unavailable');
        const http=scheme.kind==='http'?scheme.http.toLowerCase():undefined;
        if(http!=='basic'&&http!=='bearer'&&http!=='digest')return unsupported('authentication-scheme-unchecked');
        const challenge=http==='basic'?'Basic realm="*"':http==='digest'?'Digest realm="*", nonce="busyapi-local-wire"':'Bearer',values=headers.get('authorization')??[];
        if(values.length!==1)return invalid(values.length?'ambiguous':'missing',challenge);
        // RFC 9110 §§11.1/11.4: case-insensitive scheme and one or more SP.
        const match=/^([^ ]+) +(.+)$/.exec(values[0]);
        if(!match||match[1].toLowerCase()!==http)return invalid('scheme',challenge);
        const checked=httpCredentialSyntax(http,match[2]);
        return checked==='valid'?present:checked==='unsupported'?unsupported('authentication-syntax-unchecked'):invalid('credential-syntax',challenge);
    };
    const findings:Record<string,unknown>[]=[],cache=new Map<string,Credential>();
    let complete=true,work=0,findingsLimited=false;
    for(const requirement of requirements){
        if(signal.aborted)throw new SourceError('cancelled','Mock security validation was cancelled');
        const checks:{name:string;value:Credential}[]=[];
        for(const name of requirement.names){
            if(++work>2048){
                return {complete:false,valid:false,findings:[...findings.slice(0,199),{code:'runtime.request.security.limit',kind:'unsupported',severity:'warning',subject:'request-security',pointer:'',source:requirement.source,message:'Security requirement evaluation exceeds 2048 bounded scheme checks.'}]};
            }
            if(!cache.has(name))cache.set(name,credential(schemes.get(name)!));
            checks.push({name,value:cache.get(name)!});
        }
        if(checks.every(check=>check.value.valid))return {complete:true,valid:true,findings:[]};
        const unchecked=checks.some(check=>!check.value.complete),failed=checks.find(check=>unchecked?!check.value.complete:!check.value.valid)!;
        complete=complete&&!unchecked;
        const challenges=[...new Set(checks.flatMap(check=>check.value.challenge?[check.value.challenge]:[]))];
        if(findings.length<199)findings.push({code:unchecked?'runtime.request.security.unchecked':'runtime.request.security.required',...(unchecked?{kind:'unsupported'}:{}),severity:unchecked?'warning':'error',subject:'request-security',pointer:'',location:failed.name,
            source:requirement.source,definition:schemes.get(failed.name)!.definition,reason:failed.value.reason,...(challenges.length?{tags:challenges}:{}),
            message:unchecked?'This authentication mechanism cannot be checked by the local wire validator.':'The supplied credential fields do not satisfy this Security Requirement.'});
        else findingsLimited=true;
    }
    if(findingsLimited){complete=false;findings.push({code:'runtime.request.security.limit',kind:'unsupported',severity:'warning',subject:'request-security',pointer:'',source:requirements[0].source,message:'Security requirement findings reached their bounded limit.'});}
    return {complete,valid:false,findings};
}
