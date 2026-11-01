import {tokenizer} from 'acorn';

const reserved=new Set(['__proto__','constructor','prototype']);

/** Conservative capability admission, not a JSONPath parser or evaluator.
 * Spectral owns query/alias interpretation. Only literal navigation tokens may
 * reach its ordinary worker; every other project expression needs the reviewed
 * native process. Acorn decodes escapes, unlike a raw-word blacklist. Keep the
 * raw metacharacter check too: JSONPath Plus normalizes quoted scripts before
 * interpretation. Unfamiliar/invalid syntax is never permission to execute it.
 */
export function policyExpressionNeedsIsolation(expression:string,field=false):boolean {
    // The pinned public then.field API treats non-$ fields as lodash paths or
    // @key, not expressions. Do not apply JSONPath rules to literal media keys.
    if(field&&!expression.startsWith('$'))return false;
    if(expression.length>4096||/[?();`]/.test(expression))return true;
    const source=expression.replace(/^#[A-Za-z0-9_-]+/,'$');
    let comment=false,first=true,tokens=0;
    try {
        for(const token of tokenizer(source,{ecmaVersion:2024,onComment:()=>{comment=true;}})) {
            if(++tokens>4096)return true;
            // Acorn's documented token values are present at runtime; the
            // selected release's Token declaration omits this property.
            const label=token.type.label,value=(token as typeof token&{value?:string|number}).value;
            if(first) {
                first=false;
                if(label!=='name'||value!=='$')return true;
            } else if(label==='name'||label==='string'||token.type.keyword) {
                if(reserved.has(String(value))||/[?();`]/.test(String(value)))return true;
            } else if(label==='num') {
                if(typeof value!=='number'||!Number.isSafeInteger(value)||value<0)return true;
            } else if(label==='+/-') {
                // JSONPath's unquoted property tokens include hyphens (for
                // example $.x-token); evaluation still requires the excluded
                // script/filter delimiters, not a bare minus token.
                if(value!=='-')return true;
            } else if(!['.','*','[',']',',',':'].includes(label))return true;
        }
        return first||comment;
    }catch{return true;}
}
