import {SourceError} from './document';

export type PlainTextCharset='utf-8'|'us-ascii'|'iso-8859-1';

/** RFC 6657 §4 retains US-ASCII for an actual bare text/plain entity.
 * Unicode examples have OAS 3.2 §4.19.2.3's narrower eligibility rule. */
export function plainTextCharset(charset:string|undefined,unicodeSerialization=false):PlainTextCharset {
 const value=charset??'us-ascii';
 if(value==='utf-8'||value==='utf8')return 'utf-8';
 if(value==='us-ascii')return value;
 if(!unicodeSerialization&&(value==='iso-8859-1'||value==='latin1'))return 'iso-8859-1';
 throw new SourceError(unicodeSerialization?'runtime.media.unicode.unsupported':'runtime.media.unsupported',
  unicodeSerialization?'This charset does not establish a Unicode serialized example; use an external serialized resource.':'The declared charset has no native text decoder',[0,0],'unsupported');
}

export function validatePlainText(text:string,charset:string|undefined,unicodeSerialization=false):void {
 const encoding=plainTextCharset(charset,unicodeSerialization),maximum=encoding==='us-ascii'?127:encoding==='iso-8859-1'?255:undefined;
 if(maximum!==undefined)for(const character of text)if(character.codePointAt(0)!>maximum)
  throw new SourceError('runtime.media.charset','The text cannot be represented by its declared charset');
 const bytes=Buffer.from(text,'utf8');
 if(bytes.toString('utf8')!==text)throw new SourceError('runtime.media.encoding','The text contains an unpaired Unicode surrogate');
}

/** Honor an existing text declaration without rewriting its charset. */
export function declaredPlainTextBytes(text:string,charset:string|undefined):Buffer {
 const encoding=plainTextCharset(charset);
 validatePlainText(text,charset);
 return Buffer.from(text,encoding==='iso-8859-1'?'latin1':encoding==='us-ascii'?'ascii':'utf8');
}

/** Generated standalone text may make its Unicode intent explicit. Captured
 * bytes and forwarded bodies never enter this encoding path. */
export function encodePlainText(text:string,contentType:string,charset:string|undefined):{bytes:Buffer;contentType:string} {
 const selected=charset===undefined&&/[^\x00-\x7f]/.test(text)?'utf-8':charset;
 const bytes=declaredPlainTextBytes(text,selected);
 return {bytes,contentType:charset===undefined&&selected==='utf-8'?contentType+'; charset=utf-8':contentType};
}
