// Exact upstream test cases, not assertions inferred from a validator result.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const fixtures = new URL('../../../fixtures/json_schema_2020_12/', import.meta.url);
const digests = {
    "LICENSE": "837402bd25fad9b704265801ca3f92566a98157c1f9a7acd6f446299ba1c305a",
    "boolean_schema.json": "9c8828d325b88a0c632fca22405d5481548b49fb0f9f5536ee401e4d66aa8582",
    "dynamicRef.json": "dd763124c3d1432977b9c276bf682fa746f82a69b1d9bbc1d79fbdb2a3dda5e4",
    "if-then-else.json": "c7bf0da8432427d9da38b11ccccd84473137893d4a93109e63751118402fef09",
    "ref.json": "ae53f3f57c220879729225eb416cecac909f06b5adaf15f799b4f3e7c0612998",
    "unevaluatedProperties.json": "dbd5b401b09de49215f33ed7b30f4b9cd4a27e439624ad2a6aeb3a3879cac1dd",
    "remotes/tree.json": "e2fa53954b78121c6533e98ef7ca83689c9b990c5ca1c01f65e2cc7e7f426664",
    "remotes/extendible-dynamic-ref.json": "876cfd13df8730880db32f8d1b4b95c850ec170929247787118b448347dd1ed4",
    "remotes/detached-dynamicref.json": "179fa0d52df07a3c0c0509ec9a66aae3f5bbd8d150b64a8bdfa9e7342ccb6385"
};
for (const [name, expected] of Object.entries(digests)) {
    if (createHash('sha256').update(fs.readFileSync(new URL(name, fixtures))).digest('hex') !== expected)
        throw Error('The pinned upstream oracle bytes changed: ' + name);
}
if (process.argv[2] === '--case') {
    if (process.argv.includes('--exact-numbers')) {
        const {installExactNumericKeywords} = await import('./exact_numbers.mjs');
        // Import the dialect first so its bundled handlers are registered
        // before the documented extension API installs the candidate ones.
        await import('@hyperjump/json-schema/draft-2020-12');
        installExactNumericKeywords();
    }
    const { addUriSchemePlugin, addMediaTypePlugin } = await import('@hyperjump/browser');
    const { buildSchemaDocument } = await import('@hyperjump/json-schema/experimental');
    const { validate, setShouldValidateFormat } = await import('@hyperjump/json-schema/draft-2020-12');
    let input = '';
    for await (const chunk of process.stdin)
        input += chunk;
    const group = JSON.parse(input), uri = 'https://busyapi-oracles.invalid/case';
    const attempts = [];
    const remotes = new Map(['tree.json', 'extendible-dynamic-ref.json', 'detached-dynamicref.json'].map(name => ['http://localhost:1234/draft2020-12/' + name, fs.readFileSync(new URL('remotes/' + name, fixtures), 'utf8')]));
    remotes.set(uri, JSON.stringify(group.schema));
    addMediaTypePlugin('application/vnd.busyapi.conformance+json', { parse: async (response) => buildSchemaDocument(await response.json(), response.url, 'https://json-schema.org/draft/2020-12/schema') });
    for (const scheme of ['http', 'https', 'file'])
        addUriSchemePlugin(scheme, { retrieve: async (reference) => { const identity = new URL(reference); identity.hash = ''; const uri = identity.href; attempts.push(uri); if (!remotes.has(uri))
                throw Error('Resource not supplied'); const response = new Response(remotes.get(uri), { headers: { 'content-type': 'application/vnd.busyapi.conformance+json' } }); Object.defineProperty(response, 'url', { value: uri }); return response; } });
    setShouldValidateFormat(false);
    const results = [];
    try {
        for (const test of group.tests) {
            try {
                const result = await validate(uri, test.data);
                results.push({ test: test.description, expected: test.valid, actual: result.valid, passed: result.valid === test.valid });
            }
            catch (error) {
                results.push({ test: test.description, expected: test.valid, passed: false, error: error.message });
            }
        }
    }
    catch (error) {
        results.push({ passed: false, error: error.message });
    }
    console.log(JSON.stringify({ results, attempts }));
}
else {
    let passed = 0, failed = 0;
    for (const name of ['boolean_schema', 'if-then-else', 'ref', 'dynamicRef', 'unevaluatedProperties']) {
        const groups = JSON.parse(fs.readFileSync(new URL(name + '.json', fixtures), 'utf8'));
        for (const group of groups) {
            const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--case', ...(process.argv.includes('--exact-numbers') ? ['--exact-numbers'] : [])], { input: JSON.stringify(group), encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024 });
            if (child.status !== 0) {
                failed++;
                console.log(JSON.stringify({ fixture: name, case: group.description, status: 'failing', error: child.error?.message ?? child.stderr.slice(0, 700) }));
                continue;
            }
            const result = JSON.parse(child.stdout), failures = result.results.filter(r => !r.passed);
            passed += result.results.length - failures.length;
            failed += failures.length;
            if (failures.length)
                console.log(JSON.stringify({ fixture: name, case: group.description, status: 'failing', failures, attempts: result.attempts }));
        }
        console.log(JSON.stringify({ fixture: name, cumulativePassed: passed, cumulativeFailed: failed }));
    }
    console.log(JSON.stringify({ candidate: '@hyperjump/json-schema', version: '1.18.0', numericAdapter:process.argv.includes('--exact-numbers'), revision: '55719286c33ae0d1823bfb65fea10338a19bc37c', passed, failed }));
    if (failed)
        process.exitCode = 2;
}
