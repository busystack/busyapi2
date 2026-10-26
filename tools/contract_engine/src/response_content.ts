import type {SpecificationFamily} from './specification';

/** Swagger §6.4.12 uses schema presence; OAS 3.0 §4.7.17,
 * 3.1 §4.8.17 and 3.2 §4.17 describe payloads in content. An absent or
 * empty content map declares no payload, unlike a media entry without schema. */
export function responseAllowsContent(family:SpecificationFamily,response:Record<string,unknown>):boolean {
    if(family==='2.0')return Object.hasOwn(response,'schema');
    const content=response.content;
    return content!==null&&typeof content==='object'&&!Array.isArray(content)&&Object.keys(content).length>0;
}
