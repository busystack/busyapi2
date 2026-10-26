import {SourceError} from './document';
import {mediaTypeChoice} from './media_types';
import {selectNativeMedia,type NativeMedia} from './mock_projection';

/** An authored request choice identifies an entry before transport normalizes
 * MIME spelling or adds its boundary. Wire-only matching retains its tie refusal. */
export function selectRequestMedia<T extends Pick<NativeMedia,'mediaType'>>(content:readonly T[],selected:string):T|undefined {
    if(typeof selected!=='string')throw new SourceError('request.form.content-type','Select a captured request media declaration');
    const exact=content.filter(media=>media.mediaType===selected);
    if(exact.length>1)throw new SourceError('request.form.content-type','The captured request media declaration is not unique',[0,0],'unsupported');
    if(exact.length===1){
        mediaTypeChoice(exact[0].mediaType,selected);
        return exact[0];
    }
    return selectNativeMedia(content,selected);
}
