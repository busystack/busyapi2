import {SourceError} from './document';

/** HTTP quoting protects commas. Quotes and escapes remain OAS data; the
 * transport decoder never invents an application-specific unquoting step. */
export function headerValueParts(text:string):string[] {
    const result:string[]=[];
    let quoted=false,escaped=false,start=0;
    for(let index=0;index<text.length;index++){
        const character=text[index];
        if(escaped){escaped=false;continue;}
        if(quoted&&character==='\\'){escaped=true;continue;}
        if(character==='"')quoted=!quoted;
        if(!quoted&&character===','){result.push(text.slice(start,index).trim());start=index+1;}
    }
    if(quoted||escaped)throw new SourceError('header.value.syntax','A header quoted value is unfinished');
    result.push(text.slice(start).trim());return result;
}
