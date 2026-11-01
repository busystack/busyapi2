import type {SpecificationFamily} from './specification';

/** OAS 3.0 §4.7.10.1 requires consumers to ignore requestBody where HTTP
 * defines no request payload semantics. RFC 7231 §4.3 defines POST/PUT;
 * RFC 5789 §2 defines PATCH. This is consumption, not a source restriction. */
export function ignoresRequestBody(family:SpecificationFamily|string,method:string):boolean {
    return family==='3.0'&&!['POST','PUT','PATCH'].includes(method);
}
