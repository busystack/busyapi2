import {SourceError,escape} from './document';
import {children} from './contexts';
import {supportedSchemaDialect,type GraphTarget,type ReferenceGraph} from './reference_graph';
import {projectSchemaReference} from './schema_reference_projection';
import {modernFamily} from './specification';

export const schemaExamplesRevision='2';
type SchemaExampleApplicator=Readonly<
 {keyword:'allOf'|'anyOf'|'oneOf'|'dependentSchemas';selector:string}|
 {keyword:'if'|'then'|'else'}
>;
export type SchemaExampleContext=Readonly<GraphTarget&SchemaExampleApplicator>;
export type SchemaExampleSource=Readonly<GraphTarget&{
 field:'example'|'examples';name:string;context:readonly SchemaExampleContext[];
}>;
export type SchemaExampleIssue=Readonly<GraphTarget&{code:string;message:string}>;
export type SchemaExampleSelection=Readonly<{
 values:readonly SchemaExampleSource[];complete:boolean;issues:readonly SchemaExampleIssue[];
}>;

/** Authored candidate values, not evaluated annotations or synthesized data.
 * In-place applicators describe the same instance. Their authored candidates
 * do not claim branch applicability or evaluated annotation collection.
 * Child-instance and negated-schema samples are not whole-instance choices.
 * Request conformance still checks the selected value against the whole schema.
 * OAS 3.0 §4.7.24; OAS 3.2 §4.19.2; JSON Schema Validation §9.5. */
export function schemaExampleCandidates(graph:ReferenceGraph,target:GraphTarget):SchemaExampleSelection {
 const values:SchemaExampleSource[]=[],issues:SchemaExampleIssue[]=[],seen=new Set<string>();
 let visits=0,metadataBytes=0,exhausted=false;
 const issue=(at:GraphTarget,code:string,message:string)=>issues.push({...at,code,message});
 const label=(step:SchemaExampleApplicator)=>'selector' in step
  ?step.keyword+'['+(step.keyword==='dependentSchemas'?JSON.stringify(step.selector):step.selector)+']':step.keyword;
 const visit=(at:GraphTarget,depth:number,context:readonly SchemaExampleContext[])=>{
  const identity=JSON.stringify([at.resource,at.pointer]);
  if(exhausted)return;
  if(seen.has(identity))return;
  seen.add(identity);
  if(depth>=128||++visits>2048){exhausted=true;issue(at,'limit.request.schema-examples','Schema example discovery exceeded its bounded traversal');return;}
  const doc=graph.docs.get(at.resource),node=doc?.dataNode(at.pointer),scope=graph.scopeAs(at.resource,at.pointer,'schema');
  if(!node){issue(at,'request.schema-examples.source','The schema example source is unavailable');return;}
  if(!scope){issue(at,'request.schema-examples.context','The captured graph has no Schema Object at this location');return;}
  if(!supportedSchemaDialect(scope)){issue(at,'request.schema-examples.dialect','Schema examples cannot be interpreted under this unsupported dialect');return;}
  if(node.kind!=='object')return;
  const modern=modernFamily(scope.family),reference=graph.referenceAs(at.resource,at.pointer,'$ref','schema');
  const contextBytes=Buffer.byteLength(JSON.stringify(context));
  const add=(pointer:string,field:'example'|'examples',name:string)=>{
   if(exhausted)return;
   if(values.length>=2048)throw new SourceError('limit.request.schema-examples','Request schema example choices exceed 2048',node.range);
   name=[...context.map(label),name].join(' · ');
   const bytes=contextBytes+Buffer.byteLength(name);
   if(metadataBytes+bytes>512*1024){exhausted=true;issue({...at,pointer},'limit.request.schema-examples','Schema example provenance exceeded its bounded output');return;}
   metadataBytes+=bytes;
   values.push({resource:at.resource,pointer:doc!.dataNode(pointer)!.pointer,kind:'schema-example',field,
    name,context});
  };
  // Legacy Schema/Reference Objects ignore siblings. Modern $ref is an
  // applicator; its sibling annotations remain independently authored choices.
  if(modern||!reference){
   const examples=doc!.dataNode(at.pointer+'/examples');
   if(modern&&examples?.kind==='array')for(const index of examples.children.keys())
    add(at.pointer+'/examples/'+index,'examples','examples['+index+']');
   if(node.children.has('example'))add(at.pointer+'/example','example','example');
  }
  if(exhausted)return;
  for(const keyword of modern?['$ref','$dynamicRef']:['$ref']){
   const edge=keyword==='$ref'?reference:graph.referenceAs(at.resource,at.pointer,keyword,'schema');
   if(!edge)continue;
   const projected=projectSchemaReference(edge);
   if(projected.state==='fixed')visit(projected.target,depth+1,context);
   else issue({...at,pointer:at.pointer+'/'+keyword},'request.schema-examples.reference',
    projected.state==='dynamic'?'Schema examples depend on a runtime dynamic binding':'Schema examples depend on an unresolved reference');
   if(exhausted)return;
  }
  if(!modern&&reference)return;
  const kinds=new Map(children(node.value,'schema',scope.family).map(([name,,kind])=>[name,kind]));
  const descend=(pointer:string,applicator:SchemaExampleApplicator)=>{
   const source=doc!.dataNode(pointer);
   if(!source){issue({...at,pointer},'request.schema-examples.source','The schema example branch source is unavailable');return;}
   visit({...at,pointer},depth+1,[...context,{...applicator,resource:at.resource,pointer:source.pointer,kind:'schema'}]);
  };
  for(const keyword of ['allOf','anyOf','oneOf'] as const){
   const array=doc!.dataNode(at.pointer+'/'+keyword);
   if(kinds.get(keyword)==='schema-array'&&array?.kind==='array')for(const index of array.children.keys()){
    descend(at.pointer+'/'+keyword+'/'+index,{keyword,selector:index});
    if(exhausted)return;
   }
  }
  const predicate=doc!.dataNode(at.pointer+'/if');
  // Core §10.2.2: then/else have no effect without a local if. If itself
  // contributes annotations; a boolean predicate has one reachable branch.
  if(kinds.get('if')==='schema'&&predicate){
   descend(at.pointer+'/if',{keyword:'if'});
   if(exhausted)return;
   for(const keyword of ['then','else'] as const){
    if(typeof predicate.value==='boolean'&&predicate.value!==(keyword==='then'))continue;
    if(kinds.get(keyword)==='schema')descend(at.pointer+'/'+keyword,{keyword});
    if(exhausted)return;
   }
  }
  const dependent=doc!.dataNode(at.pointer+'/dependentSchemas');
  if(kinds.get('dependentSchemas')==='schema-map'&&dependent?.kind==='object')for(const name of dependent.children.keys()){
   descend(at.pointer+'/dependentSchemas/'+escape(name),{keyword:'dependentSchemas',selector:name});
   if(exhausted)return;
  }
 };
 visit(target,0,[]);
 return {values,complete:issues.length===0,issues};
}
