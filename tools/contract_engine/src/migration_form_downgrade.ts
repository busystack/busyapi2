import type {GraphScope,ReferenceGraph} from './reference_graph';
import {escape,type Node} from './document';
import {MigrationSource} from './migration_source';
import type {MigrationIssue} from './migration_schema';

const flatFields:ReadonlySet<string>=new Set(['type','format','description','default','enum','maximum','exclusiveMaximum','minimum','exclusiveMinimum','maxLength','minLength','pattern','multipleOf']);
const arrayFields:ReadonlySet<string>=new Set([...flatFields,'items','minItems','maxItems','uniqueItems']);
const itemFields:ReadonlySet<string>=new Set([...flatFields].filter(name=>name!=='description'));
const primitiveTypes:ReadonlySet<string>=new Set(['string','number','integer','boolean']);

/** OAS 3.0 §4.7.15 and Swagger 2.0 §6.4.9. Flatten only independently
 * described fields; object-wide constraints are not parameter rules. */
export function downgradeFormBody(graph:ReferenceGraph,source:MigrationSource,scope:GraphScope,pointer:string,media:string,issue:MigrationIssue):void {
    const body=source.doc.dataNode(pointer)!;
    const at=pointer+'/content/'+escape(media),schema=source.doc.dataNode(at+'/schema');
    const origin=scope.pointer+'/content/'+escape(media)+'/schema';
    let valid=true;
    const block=(pointer:string,code:string,message:string,reason:'implementation'|'target-representation'='implementation')=>{
        valid=false;issue({resource:scope.resource,pointer},code,message,reason);
    };
    const parent=pointer.slice(0,pointer.lastIndexOf('/'));
    if(source.doc.dataNode(parent)?.kind!=='array'||!parent.endsWith('/parameters')){
        block(scope.pointer,'migration.form.reusable','A reusable form body needs occurrence-specific form parameter bindings');return;
    }
    for(const name of body.children.keys())if(!['content','required'].includes(name))
        block(scope.pointer+'/'+escape(name),'migration.form.body-metadata','This form body metadata needs an explicit target owner');
    const content=source.doc.dataNode(pointer+'/content');
    if(content?.children.size!==1||!schema||schema.kind!=='object'||schema.value.type!=='object'||schema.value.$ref){
        block(scope.pointer,'migration.form.schema','A form downgrade needs one captured object schema with independently described properties');return;
    }
    for(const name of source.doc.node(at).children.keys())if(!['schema','encoding'].includes(name))
        block(scope.pointer+'/content/'+escape(media)+'/'+escape(name),'migration.form.media','This form media field needs a serialization-preserving target mapping');
    for(const name of schema.children.keys())if(!['type','properties','required'].includes(name)&&!(name==='additionalProperties'&&schema.value.additionalProperties===true))
        block(origin+'/'+escape(name),'migration.form.object-constraint','This object-wide form constraint or annotation needs a faithful Swagger representation');
    const properties=source.doc.dataNode(at+'/schema/properties');
    if(properties?.kind!=='object'||!properties.children.size){block(origin,'migration.form.fields','An empty or unconstrained form needs a faithful target body representation');return;}
    const required=new Set<string>(schema.value.required??[]);
    if((body.value.required===true)!==(required.size>0))
        block(body.children.has('required')?scope.pointer+'/required':scope.pointer,'migration.form.presence','Independent Swagger parameters cannot preserve this conditional form-body presence','target-representation');
    if([...required].some(name=>!properties.children.has(name)))
        block(origin+'/required','migration.form.required','Every required form field needs a captured parameter definition');
    const collections=new Map<string,string>();
    const flat=(property:Node,location:string,fields:ReadonlySet<string>)=>{
        if(['byte','binary'].includes(property.value.format))block(location+'/format','migration.form.binary','This binary field needs a media-aware target representation');
        for(const field of property.children.keys())if(!fields.has(field)&&!field.startsWith('x-'))
            block(location+'/'+escape(field),'migration.form.field-keyword','This Schema Object field is not a flat Swagger parameter field');
    };
    for(const [name,property]of properties.children){
        const location=origin+'/properties/'+escape(name),array=property.value?.type==='array';
        if(property.kind!=='object'||!primitiveTypes.has(property.value.type)&&!array){
            block(location,'migration.form.field-type','This form field needs an additional flat Swagger representation');continue;
        }
        flat(property,location,array?arrayFields:flatFields);
        if(array){
            const items=property.children.get('items');
            if(items?.kind!=='object'||!primitiveTypes.has(items.value.type))
                block(location+'/items','migration.form.items','This form array needs concrete primitive Items Object rules');
            else flat(items,location+'/items',itemFields);
        }
        const encoding=source.doc.dataNode(at+'/encoding/'+escape(name)),rule=encoding?.value??{};
        const styled=['style','explode','allowReserved'].some(field=>Object.hasOwn(rule,field));
        const encodingLocation=scope.pointer+'/content/'+escape(media)+'/encoding/'+escape(name);
        if(encoding)for(const field of encoding.children.keys())if(!['style','explode','allowReserved'].includes(field))
            block(encodingLocation+'/'+escape(field),'migration.form.encoding-metadata','This authored encoding field needs an explicit target owner');
        if(rule.allowReserved===true)
            block(encodingLocation+'/allowReserved','migration.form.reserved','Swagger form parameters cannot request reserved expansion','target-representation');
        if(!array&&styled&&(rule.style??'form')!=='form')
            block(encodingLocation,'migration.form.scalar-style','This scalar style has no defined Swagger form serialization','target-representation');
        if(array){
            const style=rule.style??'form',explode=rule.explode??(style==='form');
            // Encoding by name applies the default content type to each item,
            // including OAS 3.2 §4.15.1.1. Primitive items remain repeated fields.
            const collection=styled?(style==='form'?explode?'multi':'csv':!explode&&style==='spaceDelimited'?'ssv':!explode&&style==='pipeDelimited'?'pipes':undefined):'multi';
            if(collection){
                collections.set(name,collection);
                const items=property.children.get('items'),separator=collection==='csv'?',':collection==='ssv'?' ':'|';
                // Swagger flat collections split a decoded value. RFC6570 CSV
                // can escape a separator inside an item before joining it.
                // Require a finite proof when string items can contain it.
                if(collection!=='multi'&&items?.value.type==='string'&&
                    (!Array.isArray(items.value.enum)||items.value.enum.some((item:unknown)=>typeof item!=='string'||item.includes(separator))))
                    block(location+'/items','migration.form.collection-boundary','Separated string items need a finite separator-free enum for a faithful Swagger boundary','target-representation');
            }else block(encoding?encodingLocation:location,'migration.form.array-encoding','This array encoding needs an additional serialization-preserving mapping');
        }
    }
    for(const [name]of source.doc.dataNode(at+'/encoding')?.children??[])if(!properties.children.has(name))
        block(scope.pointer+'/content/'+escape(media)+'/encoding/'+escape(name),'migration.form.encoding-owner','This encoding needs a retained form property owner');
    for(const ref of graph.references)if(ref.targetResource===scope.resource&&ref.targetPointer!==undefined&&(ref.targetPointer===origin||ref.targetPointer.startsWith(origin+'/')))
        block(origin,'migration.form.schema-consumer','A referenced form schema needs a retained Schema Object owner before its fields can become parameters');
    if(!valid)return;
    for(const [name,property]of properties.children){
        const destination=parent+'/'+source.doc.node(parent).children.size;
        source.copy(source,at+'/schema/properties/'+escape(name),destination,true);
        source.set(destination+'/name',name);source.set(destination+'/in','formData');
        if(required.has(name))source.set(destination+'/required',true);
        if(['string','array'].includes(property.value.type))source.set(destination+'/allowEmptyValue',true);
        if(collections.has(name))source.set(destination+'/collectionFormat',collections.get(name)!);
    }
    source.remove(pointer);
}
