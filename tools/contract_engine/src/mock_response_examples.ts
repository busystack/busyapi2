import {SourceError} from './document';
import {capturedMockResponseMedia,sourceLocation} from './mock_projection';

/** OAS 3.0 §4.7.14 / 3.1 §4.8.14: media examples override schema examples.
 * Keep the pinned consumer's ordering among actual named media examples, while
 * excluding its synthesized schema default. The original CST supplies bytes;
 * the existing response validator still checks the resulting representation. */
export function authoredMockResponseExample(plan:unknown,status:string,actual:string,keys:readonly string[],preferred?:string):string|undefined {
    const media=capturedMockResponseMedia(plan,status,actual);
    if(!media)return;
    const examples=media.examples.filter(value=>value.origin!=='schema');
    const direct=examples.find(value=>value.name===undefined);
    const selected=preferred!==undefined
        ?examples.find(value=>value.name===preferred)??(preferred==='default'?direct:undefined)
        :direct??keys.map(key=>examples.find(value=>value.name===key)).find(value=>value!==undefined);
    if(!selected)return;
    if(typeof selected.raw!=='string'||!sourceLocation(selected.source))
        throw new SourceError('mock.validation.protocol','The authored response example omitted its captured value or source');
    return selected.raw;
}
