import { Worker, isMainThread, parentPort } from 'node:worker_threads';
import { analyse, propose, discover, inspect, readDataValue, protocol, engineVersion } from './engine';
import { planRename, planPropertyRename, planResponseRename } from './refactoring';
import { planDelete } from './refactoring_delete';
import {planExtract,planExtractToFile,planInline,planMoveDefinition,planOperationMove} from './refactoring_copy';
import {planFileMove,planFileDeletion,planRootRemoval} from './refactoring_file';
import {normalizeResourceUris} from './reference_graph';
import { assistSource, sourceFolds, semanticSearch } from './source_assistance';
import { suggestSchema, planSchemaSuggestion } from './schema_suggestion';
import { referencePage, referenceDocument } from './reference_projection';
import { evaluateSchemas, standardResource } from './schema_evaluation';
import { deriveBundle } from './derived_bundle';
import { referenceDisplayPacket } from './reference_display';
import {describeResourcePackage} from './resource_package';
import { schemaTree } from './schema_tree';
import { referenceChoices } from './reference_choices';
import { planReference } from './reference_selection';
import { WorkerDispatcher } from './worker_dispatcher';
import {planDiagnosticFix} from './diagnostic_fixes';
import {planResponseExample,requestOperation,requestParameterValues,executionCaseValues,inspectExecutionJson,planExecutionEnvironment,semanticDiffCoverage} from './execution';
import {discoverPolicy} from './governance_configuration';
import {inspectPolicyCode} from './policy_code';
import {PolicyProcessWorker} from './policy_process_worker';
import {join} from 'node:path';
import {policyRuntime} from './policy_runtime';
const MAX = 64 * 1024 * 1024;
const encode = (message: any) => {
    // TextEncoder owns this ArrayBuffer; pooled Buffer allocations cannot safely
    // be transferred. Serialize once in the worker, keeping the control loop free.
    const payload = new TextEncoder().encode(JSON.stringify({ protocol, ...message }));
    if (payload.byteLength > MAX)
        throw Object.assign(Error('Response exceeds the bounded IPC frame size'), { code: 'limit.response' });
    return payload;
};
if (!isMainThread) {
    parentPort!.on('message', async (request: any) => {
        const reply = (message: any) => {
            const payload = encode({ id: request.id, snapshot: request.params?.snapshot, ...message });
            parentPort!.postMessage(payload, [payload.buffer as ArrayBuffer]);
        };
        try {
            const methods: any = { analyse, evaluateSchemas, standardResource, deriveBundle, referenceDisplay:referenceDisplayPacket, referenceDocument, requestOperation, semanticDiffCoverage, planResponseExample, propose, discover, inspect, readDataValue, schemaTree, referenceChoices, planReference, referencePage, planRename, planPropertyRename, planResponseRename, planDelete, planExtract, planInline, planMoveDefinition, planFileMove, planFileDeletion, planDiagnosticFix, assistSource, sourceFolds, semanticSearch, suggestSchema, planSchemaSuggestion,
                discoverPolicy,inspectPolicyCode,policyRuntime,
                resolvePolicyCode:async(params:any)=>(await import('./policy_code_resolution')).resolvePolicyCode(params),
                reviewPolicyCode:async(params:any)=>(await import('./policy_code_review')).reviewPolicyCode(params),
                govern:async(params:any)=>(await import('./governance')).govern(params) };
            methods.normalizeResourceUris = normalizeResourceUris;
            methods.requestParameterValues = requestParameterValues;
            methods.executionCaseValues = executionCaseValues;
            methods.inspectExecutionJson = inspectExecutionJson;
            methods.planExecutionEnvironment = planExecutionEnvironment;
            methods.describeResourcePackage = describeResourcePackage;
            methods.planOperationMove = planOperationMove;
            methods.planExtractToFile = planExtractToFile;
            methods.planRootRemoval = planRootRemoval;
            const method = Object.hasOwn(methods, request.method) ? methods[request.method] : undefined;
            if (!method)
                throw Error('Unknown method');
            const result = await method(request.params);
            reply({ ok: true, result });
        }
        catch (e: any) {
            reply({ ok: false, error: { code: e.code ?? 'engine.failure', message: e.message ?? 'Engine failure', range: e.range } });
        }
    });
}
else {
    let bytes = Buffer.alloc(0);
    const write = (payload: Uint8Array) => { const header = Buffer.alloc(4); header.writeUInt32BE(payload.byteLength); process.stdout.write(header); process.stdout.write(payload); };
    const send = (message: any) => write(encode(message));
    const dispatcher = new WorkerDispatcher(
        request => request.method==='govern'&&request.params?.policy?.execution?
            new PolicyProcessWorker({launcher:join(__dirname,'policy-launcher'),node:process.execPath,helper:join(__dirname,'policy-worker.cjs')}):
            new Worker(__filename, {resourceLimits: {maxOldGenerationSizeMb:512,stackSizeMb:8}}),write,
        (id,code,message)=>send({id,ok:false,error:{code,message}}),MAX,
        request=>request.method==='govern'&&request.params?.policy?.execution?'isolated-policy':'standard');
    const controlFailure=(id:string)=>send({id,ok:false,error:{code:'worker.stop',message:'Cannot complete contract worker termination'}});
    process.stdin.on('data', (data) => {
        bytes = Buffer.concat([bytes, data]);
        if (bytes.length > MAX + 4) {
            process.exitCode = 3;
            process.stdin.destroy();
            return;
        }
        while (bytes.length >= 4) {
            const length = bytes.readUInt32BE();
            if (length > MAX || length < 2) {
                process.exitCode = 3;
                process.stdin.destroy();
                return;
            }
            if (bytes.length < length + 4)
                return;
            let request: any;
            try {
                request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(4, 4 + length)));
            }
            catch {
                process.exitCode = 3;
                process.stdin.destroy();
                return;
            }
            bytes = bytes.subarray(4 + length);
            const { id, method, params } = request;
            if (request.protocol !== protocol || typeof id !== 'string') {
                send({ id, ok: false, error: { code: 'protocol.mismatch', message: 'IPC version or identity mismatch' } });
                continue;
            }
            if (method === 'hello') {
                send({ id, ok: true, result: { protocol, engineVersion, nodeVersion: process.versions.node, offsetUnit: 'utf16', range: 'half-open', lineBase: 1, columnBase: 1, bom: 'excluded', lineEndings: 'raw' } });
                continue;
            }
            if (method === 'cancel') {
                if(typeof params?.id!=='string') {send({id,ok:false,error:{code:'protocol.cancel',message:'Choose a request identity'}});continue;}
                dispatcher.stop(params.id).then(()=>send({ id, ok: true, result: { cancelled: params.id } }),()=>controlFailure(id));
                continue;
            }
            if (method === 'shutdown') {
                dispatcher.close().then(() => { send({ id, ok: true, result: { stopped: true } }); process.stdin.destroy(); },()=>controlFailure(id));
                continue;
            }
            dispatcher.submit({id,method,params});
        }
    });
    process.stdin.on('end', () => {
        if (bytes.length)
            process.exitCode = 3;
        void dispatcher.close().catch(()=>{process.exitCode=3;});
    });
    process.stdin.on('close', () => {
        void dispatcher.close().catch(()=>{process.exitCode=3;});
    });
}
