import {SourceError} from './document';

type MediaType={text:string;type:string;subtype:string;parameters:ReadonlyMap<string,string>};
const token=/^[!#$%&'*+.^_`|~0-9A-Za-z-]+/;

/** OAS Encoding.contentType uses a list of media ranges, not HTTP Accept
 * quality weights. Commas inside quoted parameters do not separate choices. */
export function mediaTypes(text:string,ranges=true):MediaType[] {
    if(typeof text!=='string'||text.length>16384||/[\x00-\x08\x0a-\x1f\x7f]/.test(text))
        throw new SourceError('encoding.content-type','Expected bounded media types without control characters');
    let at=0;
    const space=()=>{while(/[ \t]/.test(text[at]??'')&&at<text.length)at++;};
    const word=()=>{const match=token.exec(text.slice(at));if(!match)throw new SourceError('encoding.content-type','Expected a media type token');at+=match[0].length;return match[0];};
    const result:MediaType[]=[];
    while(at<text.length){
        space();const start=at,type=word().toLowerCase();
        if(text[at++]!=='/')throw new SourceError('encoding.content-type','A media type requires type/subtype');
        const subtype=word().toLowerCase(),parameters=new Map<string,string>();
        if((!ranges&&(type==='*'||subtype==='*'))||type==='*'&&subtype!=='*')
            throw new SourceError('encoding.content-type','Choose a concrete media type or a type/* media range');
        space();
        while(text[at]===';'){
            at++;space();
            // RFC9110 §5.6.6 permits empty parameter slots.
            if(at===text.length||text[at]===';'||text[at]===',')continue;
            const name=word().toLowerCase();space();
            if(text[at++]!=='=')throw new SourceError('encoding.content-type','Media type parameters require a value');
            space();let value='';
            if(text[at]==='"'){
                at++;let closed=false;
                while(at<text.length){const character=text[at++];if(character==='"'){closed=true;break;}if(character==='\\'){if(at===text.length)break;value+=text[at++];}else value+=character;}
                if(!closed)throw new SourceError('encoding.content-type','A quoted media type parameter is unfinished');
            }else value=word();
            // The generic grammar permits repetition; its meaning depends on
            // the media type definition. Do not invent first/last-wins matching.
            if(parameters.has(name))throw new SourceError('request.form.media-parameters.unsupported','Repeated media type parameters need a media-specific interpretation before this form can be sent',[0,0],'unsupported');
            parameters.set(name,name==='charset'?value.toLowerCase():value);space();
        }
        result.push({text:text.slice(start,at).trim(),type,subtype,parameters});
        if(result.length>2048)throw new SourceError('limit.encoding.content-types','Media type choices exceed 2048');
        if(at===text.length)break;
        if(text[at++]!==','||!text.slice(at).trim())throw new SourceError('encoding.content-type','Expected another comma-separated media type');
    }
    if(!result.length)throw new SourceError('encoding.content-type','At least one media type is required');
    return result;
}

export function mediaTypeChoice(declared:string,selected?:string):string {
    const allowed=mediaTypes(declared);
    if(selected===undefined){
        if(allowed.length===1&&allowed[0].type!=='*'&&allowed[0].subtype!=='*')return allowed[0].text;
        throw new SourceError('request.form.content-type','Choose one concrete declared part Content-Type before sending');
    }
    const choices=mediaTypes(selected,false);
    if(choices.length!==1)throw new SourceError('request.form.content-type','Select exactly one concrete part Content-Type');
    const choice=choices[0];
    if(!allowed.some(range=>(range.type==='*'||range.type===choice.type)&&(range.subtype==='*'||range.subtype===choice.subtype)&&
        [...range.parameters].every(([name,value])=>choice.parameters.get(name)===value)))
        throw new SourceError('request.form.content-type','The selected part Content-Type is outside the declared media types');
    return choice.text;
}

export function mediaTypeOptions(declared:string){
    const allowed=mediaTypes(declared),allowsCustom=allowed.some(value=>value.type==='*'||value.subtype==='*');
    return {contentTypes:allowed.map(value=>value.text),concreteTypes:allowed.filter(value=>value.type!=='*'&&value.subtype!=='*').map(value=>value.text),allowsCustom,requiresChoice:allowed.length!==1||allowsCustom};
}
