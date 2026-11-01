// Development qualification of Redocly's supported visitor/resolver API.
// Not a production adapter. All resources are immutable approved inputs.
import {createHash} from 'node:crypto';
import {BaseResolver, Source, bundleFromString, createConfig} from '@redocly/openapi-core';

export async function probeBundle(root, resources) {
  const supplied = new Map(resources);
  const authoredRoot = JSON.parse(supplied.get(root));
  for (const [group, entries] of Object.entries(authoredRoot.components ?? {})) {
    if (!group.startsWith('x-') && Object.keys(entries).some(name => !/^[A-Za-z0-9._-]+$/.test(name))) {
      throw Error('Invalid authored component name');
    }
  }
  class SnapshotResolver extends BaseResolver {
    resolveExternalRef(base, ref) {
      const uri = new URL(ref, base ?? root); uri.hash = ''; return uri.href;
    }
    async loadExternalRef(uri) {
      if (!supplied.has(uri)) throw Error(`Resource not supplied: ${uri}`);
      return new Source(uri, supplied.get(uri), 'application/json');
    }
  }
  const refs = [];
  const mappings = [];
  const plugin = {id: 'busyapi-provenance', typeExtension: {oas3(types) {
    // The supported type extension marks extension/unknown payloads as data.
    // No authored key/value is removed, renamed or replaced.
    return Object.fromEntries(Object.entries(types).map(([name, type]) => {
      if (!type.extensionsPrefix) return [name, type];
      const previous = type.additionalProperties;
      return [name, {...type, extensionsPrefix: undefined, additionalProperties: (value, key) =>
        key.startsWith(type.extensionsPrefix) ? {resolvable: false} :
          (typeof previous === 'function' ? previous(value, key) : previous) ?? {resolvable: false}}];
    }));
  }}, decorators: {oas3: {'busyapi-provenance/capture': () => ({
    ref: {leave(node, context, resolved) {
      refs.push({node, occurrence: context.location.absolutePointer,
        target: resolved.location?.absolutePointer, targetNode: resolved.node});
    }},
    DiscriminatorMapping: {enter(node, context) {
      for (const [key, value] of Object.entries(node)) {
        const target = context.resolve({$ref: value});
        if (target.location) mappings.push({node, key, target: target.location.absolutePointer, targetNode: target.node});
      }
    }},
  })}}};
  const resolver = new SnapshotResolver({doNotResolveExamples: true});
  const config = await createConfig({resolve: {doNotResolveExamples: true},
    decorators: {'busyapi-provenance/capture': 'on'}}, {plugins: [plugin], externalRefResolver: resolver});
  const result = await bundleFromString({source: supplied.get(root), absoluteRef: root, config, externalRefResolver: resolver});
  if (result.problems.some(p => p.severity === 'error')) throw Error(JSON.stringify(result.problems.filter(p=>p.severity==='error').map(p=>({message:p.message,locations:p.location.map(l=>({resource:l.source.absoluteRef,pointer:l.pointer}))}))));
  const document = result.bundle.parsed, plans = [], provenance = [];
  const validName = /^[A-Za-z0-9._-]+$/;
  for (const [group, entries] of Object.entries(document.components ?? {})) {
    if (group.startsWith('x-')) continue;
    for (const [name, value] of Object.entries(entries)) {
      const consumers = refs.filter(ref => ref.targetNode === value && ref.node.$ref === `#/components/${group}/${name}`);
      if (validName.test(name)) {
        for (const ref of consumers) provenance.push({source: ref.target, derived: `/components/${group}/${name}`});
        continue;
      }
      // Object identity supplied by the selected visitor is essential here:
      // never infer a target by decoding the broken derived reference/name.
      const targets = new Set(consumers.map(ref => ref.target));
      if (targets.size !== 1 || targets.has(undefined)) throw Error(`Unproved derived component identity: ${group}/${name}`);
      const target = [...targets][0];
      const renamed = `busyapi_${createHash('sha256').update(target).digest('hex')}`;
      if (Object.hasOwn(entries, renamed)) throw Error('Derived component collision');
      plans.push({entries, name, renamed, consumers, target, group});
    }
  }
  for (const plan of plans) {
    plan.entries[plan.renamed] = plan.entries[plan.name]; delete plan.entries[plan.name];
    for (const ref of plan.consumers) {
      if (!ref.node.$ref?.startsWith(`#/components/${plan.group}/`)) throw Error('Unproved derived reference repair');
      ref.node.$ref = `#/components/${plan.group}/${plan.renamed}`;
      provenance.push({source: plan.target, derived: `/components/${plan.group}/${plan.renamed}`});
    }
    for (const mapping of mappings.filter(m => m.target === plan.target && m.targetNode === plan.entries[plan.renamed])) {
      if (mapping.node[mapping.key] !== `#/components/${plan.group}/${plan.name}`) throw Error('Unproved discriminator mapping repair');
      mapping.node[mapping.key] = `#/components/${plan.group}/${plan.renamed}`;
    }
  }
  return {document, provenance};
}
