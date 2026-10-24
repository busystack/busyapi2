import {parse} from 'acorn';
import {isBuiltin} from 'node:module';
import {createHash} from 'node:crypto';
import {SourceError} from './document';
import {compileFunction} from 'node:vm';

/** Source-only input to explicit code review, not an executor or JS resolver.
 * Acorn supplies actual syntax/UTF-16 ranges; no regex imports, evaluation,
 * filesystem/module lookup, package installation or project-code loading.
 * These literal dependencies are candidates, not a claim to have statically
 * proved all possible JavaScript loads. Execution must enforce the reviewed
 * immutable closure and record denied loads even if project code catches them.
 */
export function inspectPolicyCode(input:any) {
    if(typeof input?.resource!=='string'||input.resource.length>16384||
        typeof input.text!=='string'||input.text.length>256*1024||
        !['module','commonjs','detect'].includes(input.format))
        throw new SourceError('policy.code.input','Choose a bounded captured code resource and its module format');
    let format=input.format;
    if(format==='detect') {
        // V8 compiles the actual CommonJS wrapper parameters without invoking
        // it. This includes lexical wrapper-name conflicts and top-level await,
        // not a heuristic based on import-looking text. No project code runs.
        try {
            compileFunction(input.text.replace(/^#![^\r\n]*/,value=>' '.repeat(value.length)),
                ['exports','require','module','__filename','__dirname']);
            format='commonjs';
        } catch(error) {
            if(!(error instanceof SyntaxError))throw new SourceError('limit.policy.code.compile','Code syntax detection did not complete');
            format='module';
        }
    }
    const identity=createHash('sha256').update(input.text).digest('hex');
    let ast:any;
    try {ast=parse(input.text,{ecmaVersion:2025,sourceType:format,allowHashBang:true});}
    catch(error:any) {
        // Acorn 8.19.0's stack guard deliberately rethrows stack exhaustion as
        // a located SyntaxError with this fixed prefix. It is a resource limit,
        // not proof that the user's JavaScript is syntactically invalid.
        if(error instanceof RangeError||error instanceof SyntaxError&&error.message.startsWith('Not enough stack space to parse input ('))
            throw new SourceError('limit.policy.code.nesting','Code syntax review exceeds its nesting bound');
        // Parser exception text can contain source values. Only its bounded
        // numeric location crosses IPC; display source by explicit navigation.
        const start=Number.isSafeInteger(error?.pos)?Math.min(Math.max(0,error.pos),input.text.length):0;
        return {version:1,resource:input.resource,identity,format,
            parser:{name:'acorn',version:'8.19.0',ecmaVersion:2025},complete:false,
            dependencies:[],issues:[{code:'policy.code.syntax',range:[start,Math.min(start+1,input.text.length)]}]};
    }
    const dependencies:any[]=[],issues:any[]=[],pending=[ast];
    let nodes=0;
    const literal=(node:any,kind:string,rangeNode:any)=>{
        if(dependencies.length+issues.length>=1024)
            throw new SourceError('limit.policy.code.dependencies','Code dependency review exceeds its declaration bound');
        if(node?.type!=='Literal'||typeof node.value!=='string'||!node.value.length||node.value.length>4096||/[\u0000-\u001f]/u.test(node.value)) {
            issues.push({code:'policy.code.dependency.computed',range:[rangeNode.start,rangeNode.end],kind});return;
        }
        dependencies.push({specifier:node.value,range:[node.start,node.end],kind,builtin:isBuiltin(node.value)});
    };
    while(pending.length) {
        const node=pending.pop();
        if(++nodes>100000)throw new SourceError('limit.policy.code.nodes','Code dependency review exceeds its syntax-node bound');
        if(['ImportDeclaration','ExportNamedDeclaration','ExportAllDeclaration'].includes(node.type)&&node.source)
            literal(node.source,node.type==='ImportDeclaration'?'import':'export',node);
        else if(node.type==='ImportExpression')literal(node.source,'import',node);
        else if(node.type==='CallExpression') {
            const callee=node.callee;
            const require=callee?.type==='Identifier'&&callee.name==='require';
            const resolve=callee?.type==='MemberExpression'&&!callee.computed&&callee.object?.type==='Identifier'&&callee.object.name==='require'&&callee.property?.name==='resolve';
            if(require||resolve)literal(node.arguments.length===1?node.arguments[0]:undefined,resolve?'require.resolve':'require',node);
        }
        for(const value of Object.values(node)) {
            if(Array.isArray(value)) {
                for(let index=value.length-1;index>=0;index--)if(value[index]&&typeof value[index].type==='string')pending.push(value[index]);
            } else if(value&&typeof value==='object'&&typeof (value as any).type==='string')pending.push(value);
        }
    }
    return {version:1,resource:input.resource,identity,format,
        parser:{name:'acorn',version:'8.19.0',ecmaVersion:2025},complete:issues.length===0,dependencies,issues};
}
