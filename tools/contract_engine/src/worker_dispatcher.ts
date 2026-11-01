export type DispatchRequest = {id:string;method:string;params:any};
export interface DispatchWorker {
 readonly disposable?:boolean;
 failureFor?(error:unknown):{code:string;message:string};
 once(event:string,listener:(...args:any[])=>void):any;
 removeAllListeners(event?:string):any;
 terminate():Promise<number>;
 postMessage(value:any):void;
}

/** Two execution slots plus two bounded waiting requests. Control messages do
 * not compete for execution slots. A retiring worker still owns its slot until
 * termination completes; cancellation acknowledgement means actual completion.
 * The worker's awaited response, never submission, completes a data request. */
export class WorkerDispatcher {
 private jobs=new Map<string,DispatchWorker>();
 private queued:DispatchRequest[]=[];
 private workers=new Set<DispatchWorker>();
 private idle:DispatchWorker[]=[];
 private background=new Set<DispatchWorker>();
 private retiring=new Map<DispatchWorker,Promise<void>>();
 private stopping=new Map<string,Promise<void>>();
 private closing=false;
 private terminationFailed=false;
 private kinds=new Map<DispatchWorker,string>();
 private closed?:Promise<void>;
 constructor(private create:(request:DispatchRequest)=>DispatchWorker,private write:(payload:Uint8Array)=>void,
  private failure:(id:string,code:string,message:string)=>void,private maxFrame:number,
  private kind:(request:DispatchRequest)=>string=()=> 'standard'){}
 private priority(method:string) {
  return ['analyse','propose','assistSource'].includes(method)?0:['evaluateSchemas','govern','inspectPolicyCode','resolvePolicyCode','reviewPolicyCode','referenceDocument','referenceDisplay','deriveBundle','describeResourcePackage','planExtract','planExtractToFile','planInline','planMoveDefinition','planOperationMove','planFileMove','planFileDeletion','planRootRemoval','sourceFolds'].includes(method)?3:
   ['inspect','readDataValue','schemaTree','referenceChoices','referencePage','semanticSearch'].includes(method)?2:1;
 }
 submit(request:DispatchRequest) {
  if(this.closing) {this.failure(request.id,'worker.closed','The contract dispatcher has closed');return;}
  if(this.jobs.has(request.id)||this.stopping.has(request.id)||this.queued.some(q=>q.id===request.id)||this.jobs.size+this.retiring.size+this.queued.length>=4) {
   this.failure(request.id,'queue.full','The bounded engine queue is full or the request identity is already in use');return;
  }
  this.queued.push(request);this.drain();
 }
 private drain() {
  if(this.closing)return;
  // Stable sort retains arrival order at each priority. Source feedback and
  // foreground transactions precede queued derived views/full evaluation.
  this.queued.sort((a,b)=>this.priority(a.method)-this.priority(b.method));
  while(this.jobs.size+this.retiring.size<2&&this.queued.length) {
   const request=this.queued[0];
   const kind=this.kind(request);
   const background=this.priority(request.method)===3;
   // A cancelled full evaluation is terminated, not cooperatively interrupted.
   // Keep the foreground CST cache out of that worker's lifetime. Only one
   // background job runs at once; the other slot remains usable by Source,
   // forms and navigation. Two foreground requests may still run concurrently.
   if(background&&[...this.jobs.values(),...this.retiring.keys()].some(worker=>this.background.has(worker)))break;
   let worker:DispatchWorker;
   let preferred=-1;
   for(let i=this.idle.length-1;i>=0;i--)if(this.kinds.get(this.idle[i])===kind&&this.background.has(this.idle[i])===background) {preferred=i;break;}
   try {
    if(preferred>=0)worker=this.idle.splice(preferred,1)[0];
    else if(this.workers.size<2) {worker=this.create(request);this.kinds.set(worker,kind);}
    else {
     const foreground=[...this.workers].filter(worker=>!this.background.has(worker)).length;
     let reusable=-1;
     for(let index=this.idle.length-1;index>=0;index--)if(this.kinds.get(this.idle[index])===kind&&(!background||foreground>1)) {reusable=index;break;}
     if(reusable>=0)worker=this.idle.splice(reusable,1)[0];
     else {
      // An isolated process cannot be sent to a cached Node Worker (or vice
      // versa). Retire a compatible ownership slot before changing its kind;
      // preserve the sole foreground CST cache for a background transition.
      let incompatible=-1;
      for(let index=this.idle.length-1;index>=0;index--)if(!background||this.background.has(this.idle[index])||foreground>1) {incompatible=index;break;}
      if(incompatible>=0)void this.retire(this.idle.splice(incompatible,1)[0]).then(()=>this.drain(),()=>{});
      break;
     }
    }
   }
   catch {this.queued.shift();this.failure(request.id,'worker.start','Cannot start the contract worker');continue;}
   this.queued.shift();
   if(background)this.background.add(worker);else this.background.delete(worker);
   this.detach(worker);this.workers.add(worker);this.jobs.set(request.id,worker);
   const bad=(code:string,message:string)=>{
    if(this.jobs.get(request.id)!==worker)return;
    this.jobs.delete(request.id);this.detach(worker);
    this.failure(request.id,code,message);
    const retired=this.retire(worker).finally(()=>{this.stopping.delete(request.id);this.drain();});
    this.stopping.set(request.id,retired);void retired.catch(()=>{});
   };
   worker.once('message',(payload:any)=>{
    if(this.jobs.get(request.id)!==worker)return;
    if(!(payload instanceof Uint8Array)||payload.byteLength<2||payload.byteLength>this.maxFrame) {
     bad('worker.protocol','Analysis worker returned an invalid frame');return;
    }
    this.jobs.delete(request.id);this.detach(worker);this.write(payload);
    if(worker.disposable)void this.retire(worker).then(()=>this.drain(),()=>{});
    else {this.makeIdle(worker);this.drain();}
   });
   worker.once('error',(error:unknown)=>{
    let failure:{code:string;message:string}|undefined;
    try {failure=worker.failureFor?.(error);}catch{}
    if(failure&&/^policy\.process\.[a-z-]+$/.test(failure.code)&&failure.message.length<=256)bad(failure.code,failure.message);
    else bad('worker.crash','Analysis worker failed');
   });
   worker.once('exit',()=>bad('worker.exit','Analysis worker stopped before returning a result'));
   try {worker.postMessage(request);}
   catch {bad('worker.input','Cannot send the captured snapshot to the contract worker');}
  }
 }
 private detach(worker:DispatchWorker) {
  for(const event of ['message','error','exit'])worker.removeAllListeners(event);
 }
 private makeIdle(worker:DispatchWorker) {
  this.idle.push(worker);
  const failed=()=>{
   const index=this.idle.indexOf(worker);if(index<0)return;
   this.idle.splice(index,1);void this.retire(worker).then(()=>this.drain(),()=>{});
  };
  worker.once('error',failed);worker.once('exit',failed);
 }
 private retire(worker:DispatchWorker):Promise<void> {
  const existing=this.retiring.get(worker);if(existing)return existing;
  this.detach(worker);
  // The owned job has already failed or is being cancelled. Drain a late
  // Worker error during termination without crashing the parent control loop.
  worker.once('error',()=>{});
  const promise=Promise.resolve().then(()=>worker.terminate()).then(()=>{}).catch(error=>{
   this.closing=true;this.terminationFailed=true;
   for(const request of this.queued.splice(0))this.failure(request.id,'worker.stop','Worker termination failed; queued work was not executed');
   throw error;
  }).finally(()=>{this.detach(worker);this.workers.delete(worker);this.background.delete(worker);this.kinds.delete(worker);this.retiring.delete(worker);});
  this.retiring.set(worker,promise);return promise;
 }
 stop(id:string):Promise<void> {
  const existing=this.stopping.get(id);if(existing)return existing;
  const index=this.queued.findIndex(q=>q.id===id);
  if(index>=0) {this.queued.splice(index,1);this.failure(id,'cancelled','Queued request cancelled');return Promise.resolve();}
  const worker=this.jobs.get(id);if(!worker)return Promise.resolve();
  this.jobs.delete(id);this.detach(worker);
  const promise=this.retire(worker).then(()=>{
   this.failure(id,'cancelled','Request cancelled');
  }).finally(()=>{this.stopping.delete(id);this.drain();});
  this.stopping.set(id,promise);return promise;
 }
 close():Promise<void> {
  if(this.closed)return this.closed;
  this.closing=true;
  for(const request of this.queued.splice(0))this.failure(request.id,'cancelled','Contract engine closed before dispatch');
  const stops=[...this.stopping.values(),...[...this.jobs.keys()].map(id=>this.stop(id)),...this.idle.splice(0).map(worker=>this.retire(worker)),...this.retiring.values()];
  this.closed=Promise.all(stops).then(()=>{if(this.terminationFailed||this.workers.size)throw Error('A contract worker could not be terminated');});return this.closed;
 }
}
