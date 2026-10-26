import type {SourceDocument} from './document';
import {mediaTypes} from './media_types';

/** Decoder-owned binary leaves are outside JSON Schema's six JSON types
 * (Core 2020-12 §4.2.3; OAS 3.2 §4.24.4.3). JSON null is only CST storage;
 * the evaluator must receive this provenance with every whole/item instance. */
export type BinaryLocations=ReadonlyMap<string,Buffer>;
export type BinaryDocuments=ReadonlyMap<SourceDocument,BinaryLocations>;

export function runtimeBinaryMedia(contentType:string):boolean {
 const [{type,subtype}]=mediaTypes(contentType,false);
 if(subtype.endsWith('+json')||subtype.endsWith('+xml'))return false;
 return ['image','audio','video','font'].includes(type)||type==='application'&&
  ['octet-stream','pdf','zip','gzip','wasm'].includes(subtype);
}

export function prefixBinary(target:Map<string,Buffer>,prefix:string,source:BinaryLocations):void {
 for(const [pointer,bytes]of source)target.set(prefix+pointer,bytes);
}
