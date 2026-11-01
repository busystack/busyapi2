import type {ReferenceGraph} from './reference_graph';
import type {SerializedExampleEvaluation} from './serialized_examples';
import {capturedRuntimeMedia} from './runtime_media_owner';

type Location={resource:string;pointer:string};
export type LiteralPolicyCheck={complete:boolean;schema:Location;incompatible:Location[]};
export const policyExampleKey=(location:Location)=>JSON.stringify([location.resource,location.pointer]);

/** Legacy value/example fields are selected by the pinned OAS example rules.
 * Their non-JSON strings need the same native media proof as execution, rather
 * than a second JSON-string schema check. Explicit serializedValue/externalValue
 * remain outside these data-oriented selectors. */
export function policyLiteralExamples(graph:ReferenceGraph,evaluations:readonly SerializedExampleEvaluation[]) {
 const capture=capturedRuntimeMedia(graph),checks=new Map<string,LiteralPolicyCheck>();
 for(const proof of evaluations){
  if(!proof.media||!['value','example','swagger-response'].includes(proof.field))continue;
  const schema=capture(proof.media).schema;if(!schema)continue;
  const key=policyExampleKey(schema);
  let check=checks.get(key);if(!check){check={complete:true,schema,incompatible:[]};checks.set(key,check);}
  check.complete=check.complete&&proof.complete;
  if(proof.complete&&!proof.valid)check.incompatible.push({resource:proof.resource,pointer:proof.pointer});
 }
 return checks;
}
