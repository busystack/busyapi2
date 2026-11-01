import {compare,decimal} from './exact_numbers';
import {SourceDocument,SourceError} from './document';
import {modernFamily} from './specification';
import type {GraphScope} from './reference_graph';
import type {SchemaSample,SchemaSampleSource} from './schema_sample_candidates';

type Decimal=ReturnType<typeof decimal>;
type Context=Readonly<{scope:GraphScope;document:SourceDocument}>;
type Bound=Readonly<{value:Decimal;raw:string;exclusive:boolean;source:SchemaSampleSource}>;
type Step=Readonly<{value:Decimal;source:SchemaSampleSource}>;
type Candidates=Readonly<{samples:readonly SchemaSample[];limit?:SchemaSampleSource}>;

const digits=(value:bigint)=>value.toString().replace('-','').length;
const floor=(numerator:bigint,denominator:bigint)=>{
    const quotient=numerator/denominator;
    return numerator<0n&&numerator%denominator!==0n?quotient-1n:quotient;
};
const ceil=(numerator:bigint,denominator:bigint)=>-floor(-numerator,denominator);

/** Construct exact numeric suggestions on the conjunction's decimal lattice.
 * This does not decide schema validity: the original native evaluator still
 * proves the entire selected value, including composition and other keywords.
 * Large exponent differences or coefficients stay explicitly bounded. */
export function numericSampleCandidates(contexts:readonly Context[]):Candidates {
    let lower:Bound|undefined,upper:Bound|undefined,origin:SchemaSampleSource|undefined;
    let numeric=false,integer=false;
    const steps:Step[]=[];
    const select=(prior:Bound|undefined,next:Bound,minimum:boolean):Bound=>{
        if(!prior)return next;
        const order=compare(next.value,prior.value)*(minimum?1:-1);
        return order>0||order===0&&next.exclusive?next:prior;
    };
    for(const {scope,document}of contexts){
        const node=document.dataNode(scope.pointer),value=node?.value;
        const types=typeof value?.type==='string'?[value.type]:Array.isArray(value?.type)?value.type:[];
        numeric||=types.some(type=>type==='number'||type==='integer');
        integer||=types.includes('integer')&&!types.includes('number');
        const source:SchemaSampleSource={resource:scope.resource,pointer:scope.pointer,range:node?.range??[0,0]};
        origin??=source;
        const read=(keyword:string,exclusive:boolean):Bound|undefined=>{
            const pointer=scope.pointer+'/'+keyword,field=document.dataNode(pointer);
            if(typeof field?.value!=='number')return;
            numeric=true;
            const raw=document.dataJson(pointer);
            return {value:decimal(raw),raw,exclusive,source:{resource:scope.resource,pointer,range:field.range}};
        };
        const minimum=read('minimum',!modernFamily(scope.family)&&value?.exclusiveMinimum===true);
        const maximum=read('maximum',!modernFamily(scope.family)&&value?.exclusiveMaximum===true);
        if(minimum)lower=select(lower,minimum,true);
        if(maximum)upper=select(upper,maximum,false);
        if(modernFamily(scope.family)){
            const minimum=read('exclusiveMinimum',true),maximum=read('exclusiveMaximum',true);
            if(minimum)lower=select(lower,minimum,true);
            if(maximum)upper=select(upper,maximum,false);
        }
        const multiple=read('multipleOf',false);
        if(multiple){
            if(multiple.value.coefficient<=0n)
                throw new SourceError('schema.multipleOf','multipleOf requires a strictly positive schema value',multiple.source.range,'specification',multiple.source);
            steps.push({value:multiple.value,source:multiple.source});
        }
    }
    if(!numeric||!origin)return {samples:[]};
    if(integer)steps.push({value:decimal('1'),source:origin});
    if(lower&&upper){
        const order=compare(lower.value,upper.value);
        if(order>0||order===0&&(lower.exclusive||upper.exclusive))return {samples:[]};
    }
    let work=0;
    const bounded=(value:bigint)=>{
        if(digits(value)>4096)throw new SourceError('limit.schema.sample.numeric','Numeric candidate coefficients exceed 4096 decimal digits');
        return value;
    };
    const scale=(coefficient:bigint,power:bigint)=>{
        if(coefficient===0n)return 0n;
        if(power<0n||power>8192n||BigInt(digits(coefficient))+power>8192n)
            throw new SourceError('limit.schema.sample.numeric','Numeric candidate exponent alignment exceeds its bounded work');
        return coefficient*10n**power;
    };
    const gcd=(left:bigint,right:bigint)=>{
        while(right){
            if(++work>32768)throw new SourceError('limit.schema.sample.numeric','Numeric lattice construction exceeds its bounded work');
            [left,right]=[right,left%right];
        }
        return left;
    };
    const samples:SchemaSample[]=[],seen=new Set<string>();
    const append=(value:Decimal,source:SchemaSampleSource,raw?:string)=>{
        if(lower&&(compare(value,lower.value)<0||lower.exclusive&&compare(value,lower.value)===0)||
            upper&&(compare(value,upper.value)>0||upper.exclusive&&compare(value,upper.value)===0))return;
        raw??=value.coefficient===0n?'0':bounded(value.coefficient).toString()+(value.exponent===0n?'':'e'+value.exponent);
        if(seen.has(raw))return;
        seen.add(raw);samples.push({raw,source});
    };
    append(decimal('0'),origin);
    try{
        let step:Decimal;
        if(steps.length){
            const exponent=steps.reduce((prior,step)=>step.value.exponent<prior?step.value.exponent:prior,steps[0].value.exponent);
            let coefficient=1n;
            for(const item of steps){
                const next=scale(item.value.coefficient,item.value.exponent-exponent);
                coefficient=bounded(coefficient/gcd(coefficient,next)*next);
            }
            step=decimal(coefficient.toString()+'e'+exponent);
        }else{
            const exponents=[lower,upper].filter((bound):bound is Bound=>bound!==undefined).map(bound=>bound.value.exponent);
            const exponent=exponents.length?exponents.reduce((left,right)=>left<right?left:right)-1n:0n;
            step={coefficient:1n,exponent};
        }
        if(!steps.length)for(const bound of [lower,upper])if(bound&&!bound.exclusive)append(bound.value,bound.source,bound.raw);
        const quotient=(bound:Bound)=>{
            if(bound.value.coefficient===0n)return {numerator:0n,denominator:1n};
            const power=bound.value.exponent-step.exponent;
            return power>=0n?{numerator:scale(bound.value.coefficient,power),denominator:step.coefficient}:
                {numerator:bound.value.coefficient,denominator:scale(step.coefficient,-power)};
        };
        const minimum=lower?quotient(lower):undefined,maximum=upper?quotient(upper):undefined;
        const first=minimum?(lower!.exclusive?floor(minimum.numerator,minimum.denominator)+1n:ceil(minimum.numerator,minimum.denominator)):undefined;
        const last=maximum?(upper!.exclusive?ceil(maximum.numerator,maximum.denominator)-1n:floor(maximum.numerator,maximum.denominator)):undefined;
        if(first!==undefined&&last!==undefined&&first>last)return {samples:[]};
        for(const index of [first,last,0n,1n,-1n,first===undefined?undefined:first+1n,last===undefined?undefined:last-1n]){
            if(index===undefined||first!==undefined&&index<first||last!==undefined&&index>last)continue;
            append({coefficient:bounded(index*step.coefficient),exponent:step.exponent},lower?.source??upper?.source??steps[0]?.source??origin);
        }
        return {samples};
    }catch(error){
        if(!(error instanceof SourceError)||!['limit.schema.sample.numeric','limit.schema.numeric'].includes(error.code))throw error;
        return {samples,limit:lower?.source??upper?.source??steps[0]?.source??origin};
    }
}
