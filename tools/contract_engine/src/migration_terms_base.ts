import {parseUriReference} from '@hyperjump/uri';
import {serverTemplate} from './derived_bundle';
import {SourceError} from './document';
import {resolveUri} from './reference_graph';
import {resolveServerUrl,serverUrlValidity} from './server_semantics';

/** OAS 3.0 §4.6 / RFC 3986 §5.2.2: a reference replaces some base
 * components. Variables confined to those discarded components cannot change
 * its destination. This proves a constant prefix, never a sampled/default URL.
 * Undefined leaves the exhaustive-choice/limitation path in charge. */
export function independentTermsDestination(server:unknown,terms:string,retrieval:string):string|undefined {
    if(server===null||typeof server!=='object'||!('url' in server)||typeof server.url!=='string'||!server.url.includes('{'))return;
    const variables='variables' in server?server.variables:undefined;
    let absolute:string;
    try{absolute=serverTemplate(server.url,retrieval,variables);}
    catch(error){
        if(!(error instanceof SourceError)||!['bundle.server.template-context','limit.bundle.server.templates'].includes(error.code))throw error;
        return;
    }
    const variable=absolute.indexOf('{');
    if(variable<0)return;
    const prefix=absolute.slice(0,variable),reference=parseUriReference(terms);
    if(reference.authority!==undefined){
        const scheme=/^[A-Za-z][A-Za-z0-9+.-]*:/u.exec(prefix)?.[0];
        if(scheme)return resolveUri(scheme+terms,retrieval).href;
        return;
    }
    if(reference.path.startsWith('/')){
        // A literal delimiter ends the authority before the first variable.
        // Parsing a placeholder authority would invent a host or port.
        const authority=/^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^/?#]*[/?#]/u.exec(prefix);
        if(!authority)return;
        let base=authority[0].slice(0,-1)+'/';
        if(base.toLowerCase().startsWith('file:')){
            // The canonical URL representation retains a file drive under an
            // absolute-path reference. A later variable can introduce one
            // unless the literal prefix already pins a protected drive root.
            if(serverUrlValidity(prefix,retrieval)!=='valid')return;
            const fixed=resolveServerUrl(prefix,retrieval);
            if(!/^\/[A-Za-z]:\//u.test(fixed.pathname))return;
            base=fixed.href;
        }
        return serverUrlValidity(base,retrieval)==='valid'?resolveUri(terms,resolveServerUrl(base,retrieval).href).href:undefined;
    }
    const fragment=prefix.indexOf('#'),query=prefix.indexOf('?');
    // A nonempty reference path or an explicit query replaces the base query.
    // An absent query differs from an explicitly empty query.
    const discarded=reference.path!==''||reference.query!==undefined
        ?[query,fragment].filter(index=>index>=0):fragment>=0?[fragment]:[];
    if(!discarded.length)return;
    const base=prefix.slice(0,Math.min(...discarded));
    return serverUrlValidity(base,retrieval)==='valid'?resolveUri(terms,resolveServerUrl(base,retrieval).href).href:undefined;
}
