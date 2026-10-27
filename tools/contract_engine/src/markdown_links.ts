import {Parser} from 'commonmark';
import {SourceError} from './document';

/** Inspect rendered destinations, including full, collapsed and shortcut
 * reference links and images. Code spans/blocks and unused definitions do not
 * establish links. This parser never retrieves their destinations. */
function* relativeDestinations(source:string):Generator<string> {
 if(source.length>1024*1024)
  throw new SourceError('limit.refactor.markdown','Documentation link inspection exceeds its bounded size');
 const walker=new Parser().parse(source).walker();
 let event:any,work=0;
 while((event=walker.next())) {
  if(++work>400000)throw new SourceError('limit.refactor.markdown','Documentation link inspection exceeds its bounded node count');
  const node=event.node;
  if(event.entering&&(node.type==='link'||node.type==='image')&&
   !/^(?:[a-zA-Z][a-zA-Z0-9+.-]*:|#)/.test(node.destination))yield node.destination;
 }
}

export function hasRelativeMarkdownLinks(source:string):boolean {
 for(const _ of relativeDestinations(source))return true;
 return false;
}

export function relativeMarkdownDestinations(source:string):readonly string[] {
 return [...relativeDestinations(source)];
}
