import {posix} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {SourceDocument,SourceError,type Range} from './document';

export type CaseFileLocator={pointer:string;path:string;resource:string;range:Range};
const object=(value:unknown):value is Record<string,unknown>=>value!==null&&typeof value==='object'&&!Array.isArray(value);

/** Only explicit saved upload paths are filesystem locators. Body values,
 * extensions and reference-looking payload keys remain ordinary data. */
export function caseFileLocators(doc:SourceDocument):CaseFileLocator[] {
    const fail=(pointer:string,message:string):never=>{
        const range=doc.dataNode(pointer)?.range??[0,0];
        throw new SourceError('test.configuration',message,range,undefined,{resource:doc.id,pointer,range});
    };
    let base:string;
    try{
        const uri=new URL(doc.id);
        if(uri.protocol!=='file:'||uri.host||uri.search||uri.hash)throw new Error();
        base=posix.dirname(fileURLToPath(uri));
    }catch{return fail('','Saved file paths require a captured local project configuration');}
    const tests=doc.root.value?.tests;
    if(tests===undefined||tests===null)return [];
    if(!Array.isArray(tests))return fail('/tests','Configured tests must be a sequence');
    const result:CaseFileLocator[]=[];
    for(const [index,test]of tests.entries()){
        const at='/tests/'+index;
        if(!object(test))return fail(at,'A configured test must be a mapping');
        const body=test.body;
        if(!object(body)||!Object.hasOwn(body,'files'))continue;
        if(!Array.isArray(body.files)||body.files.length>2048)return fail(at+'/body/files','Expected a bounded sequence of saved file inputs');
        for(const [fileIndex,file]of body.files.entries()){
            const pointer=at+'/body/files/'+fileIndex+'/path';
            if(!object(file)||typeof file.path!=='string'||!file.path.length||file.path.includes('\0')||file.path.length>8192||posix.isAbsolute(file.path)||posix.normalize(file.path).split('/').includes('..'))
                return fail(pointer,'A saved file input needs a relative path inside the project');
            if(result.length>=2048)return fail(pointer,'Saved file path inspection exceeds 2048 locators');
            result.push({pointer,path:file.path,resource:pathToFileURL(posix.resolve(base,file.path)).href,range:doc.dataNode(pointer)?.range??[0,0]});
        }
    }
    return result;
}

/** Configuration uploads use physical paths, independently of retained API
 * retrieval aliases. A reviewed move cannot expand their filesystem boundary. */
export function movedCaseFilePath(doc:SourceDocument,locator:CaseFileLocator,destination:string):string {
    const base=posix.dirname(fileURLToPath(doc.id)),relative=posix.relative(base,fileURLToPath(destination));
    if(!relative||posix.isAbsolute(relative)||relative.split('/').includes('..'))
        throw new SourceError('file.move.case-file.boundary','The saved input would leave its project boundary; choose a destination inside the project',locator.range,undefined,{resource:doc.id,pointer:locator.pointer,range:locator.range});
    return (locator.path.startsWith('./')?'./':'')+relative;
}
