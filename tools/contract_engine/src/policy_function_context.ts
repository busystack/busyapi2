/** Supported Spectral public interfaces, not its private parser/resolver state.
 * Full-document and rule-data reads have a separate exactness boundary from a
 * scalar function input. Metadata/path/range access does not expose a rounded
 * contract. A denied read is recorded by the owner even if user code catches it.
 * No contract is cloned, serialized, changed, or turned into another authority.
 */
export function policyFunctionContext(checkDocument:()=>void,checkRuleData:(field:'then'|'extensions')=>void,detectedFormats?:ReadonlySet<any>) {
    const documents=new WeakMap<object,any>(),inventories=new WeakMap<object,any>(),rules=new WeakMap<object,any>();
    const document=(source:any):any=>{
        if(documents.has(source))return documents.get(source);
        const result=Object.freeze({
            source:source.source,
            diagnostics:source.diagnostics,
            formats:detectedFormats?new Set(detectedFormats):source.formats?new Set(source.formats):source.formats,
            get data(){checkDocument();return source.data;},
            getRangeForJsonPath:(...args:any[])=>source.getRangeForJsonPath(...args),
            trapAccess:(value:any)=>source.trapAccess(value),
        });
        documents.set(source,result);return result;
    };
    const inventory=(source:any):any=>{
        if(inventories.has(source))return inventories.get(source);
        const result=Object.freeze({
            graph:source.graph,
            source:source.source,
            formats:detectedFormats?new Set(detectedFormats):source.formats?new Set(source.formats):source.formats,
            document:document(source.document),
            get resolved(){checkDocument();return source.resolved;},
            get unresolved(){checkDocument();return source.unresolved;},
            referencedDocuments:Object.freeze(Object.fromEntries(Object.entries(source.referencedDocuments??{}).map(([key,value])=>[key,document(value)]))),
            findAssociatedItemForPath:(...args:any[])=>{
                const value=source.findAssociatedItemForPath(...args);
                return value?{...value,document:document(value.document)}:value;
            },
        });
        inventories.set(source,result);return result;
    };
    const rule=(source:any)=>{
        if(rules.has(source))return rules.get(source);
        const result=Object.freeze({name:source.name,description:source.description,message:source.message,
            severity:source.severity,resolved:source.resolved,enabled:source.enabled,recommended:source.recommended,
            documentationUrl:source.documentationUrl,given:[...source.given],formats:source.formats,
            get then(){checkRuleData('then');return source.then;},
            get extensions(){checkRuleData('extensions');return source.extensions;},
        });
        rules.set(source,result);return result;
    };
    return (context:any,selectedRule:any=context.rule)=>Object.freeze({path:[...context.path],document:document(context.document),
        documentInventory:inventory(context.documentInventory),rule:rule(selectedRule)});
}
