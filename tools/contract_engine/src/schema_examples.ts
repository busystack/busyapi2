import {SourceError} from './document';
import {supportedSchemaDialect,type GraphTarget,type ReferenceGraph} from './reference_graph';
import {projectSchemaReference} from './schema_reference_projection';
import {modernFamily} from './specification';

export const schemaExamplesRevision='1';
export type SchemaExampleSource=Readonly<GraphTarget&{field:'example'|'examples';name:string}>;
export type SchemaExampleIssue=Readonly<GraphTarget&{code:string;message:string}>;
export type SchemaExampleSelection=Readonly<{
 values:readonly SchemaExampleSource[];complete:boolean;issues:readonly SchemaExampleIssue[];
}>;

/** Authored candidate values, not evaluated annotations or synthesized data.
 * AllOf and fixed schema references describe the same instance; property,
 * item and conditional branch examples do not describe the containing value.
 * Request conformance still checks the selected value against the whole schema.
 * OAS 3.0 §4.7.24; OAS 3.2 §4.19.2; JSON Schema Validation §9.5. */
export function schemaExampleCandidates(graph:ReferenceGraph,target:GraphTarget):SchemaExampleSelection {
 const values:SchemaExampleSource[]=[],issues:SchemaExampleIssue[]=[],seen=new Set<string>();
 let visits=0,exhausted=false;
 const issue=(at:GraphTarget,code:string,message:string)=>issues.push({...at,code,message});
 const visit=(at:GraphTarget,depth:number)=>{
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
  const add=(pointer:string,field:'example'|'examples',name:string)=>{
   if(values.length>=2048)throw new SourceError('limit.request.schema-examples','Request schema example choices exceed 2048',node.range);
   values.push({resource:at.resource,pointer:doc!.dataNode(pointer)!.pointer,kind:'schema-example',field,name});
  };
  // Legacy Schema/Reference Objects ignore siblings. Modern $ref is an
  // applicator; its sibling annotations remain independently authored choices.
  if(modern||!reference){
   const examples=doc!.dataNode(at.pointer+'/examples');
   if(modern&&examples?.kind==='array')for(const index of examples.children.keys())
    add(at.pointer+'/examples/'+index,'examples','examples['+index+']');
   if(node.children.has('example'))add(at.pointer+'/example','example','example');
  }
  for(const keyword of modern?['$ref','$dynamicRef']:['$ref']){
   const edge=keyword==='$ref'?reference:graph.referenceAs(at.resource,at.pointer,keyword,'schema');
   if(!edge)continue;
   const projected=projectSchemaReference(edge);
   if(projected.state==='fixed')visit(projected.target,depth+1);
   else issue({...at,pointer:at.pointer+'/'+keyword},'request.schema-examples.reference',
    projected.state==='dynamic'?'Schema examples depend on a runtime dynamic binding':'Schema examples depend on an unresolved reference');
   if(exhausted)return;
  }
  if(!modern&&reference)return;
  const allOf=doc!.dataNode(at.pointer+'/allOf');
  if(allOf?.kind==='array')for(const index of allOf.children.keys()){
   visit({...at,pointer:at.pointer+'/allOf/'+index},depth+1);
   if(exhausted)return;
  }
  for(const keyword of modern?['anyOf','oneOf','if','then','else','dependentSchemas']:scope.family==='3.0'?['anyOf','oneOf']:[])
   if(node.children.has(keyword))issue({...at,pointer:at.pointer+'/'+keyword},'request.schema-examples.conditional',
    'Conditional schema example discovery requires applicability evaluation; these choices cover unconditional declarations only');
 };
 visit(target,0);
 return {values,complete:issues.length===0,issues};
}
