import {SourceError,type Range} from './document';
import {relocateMarkdownLinks} from './markdown_relocation';

/** Maintenance uses the same source-span/AST proof as migration. Preserve a
 * source-located refactoring failure rather than exposing another operation's
 * diagnostic namespace or claiming an incomplete mapping succeeded. */
export function relocateRefactoringMarkdown(value:string,from:string,to:string,source:{resource:string;pointer:string;range:Range}):string {
    try{return relocateMarkdownLinks(value,from,to);}
    catch(error){
        if(!(error instanceof SourceError))throw error;
        throw new SourceError(error.code.startsWith('limit.')?'limit.refactor.markdown':'refactor.markdown.mapping',error.message,source.range,'unsupported',source);
    }
}
