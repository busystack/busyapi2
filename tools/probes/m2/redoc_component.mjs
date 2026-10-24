// Focused qualification of Redoc CE's exported component API, not vendor code.
import React from 'react';
import {createRoot} from 'react-dom/client';
import {HashRouter} from 'react-router';
import {prepareApiDocs, Redoc} from 'redoc';

function descriptionText(source) {
  let nodes = 0, bytes = 0;
  const block = new Set(['paragraph', 'heading', 'list', 'item', 'blockquote', 'fence', 'hardbreak', 'softbreak']);
  function visit(value, depth) {
    if (++nodes > 200000 || depth > 256) throw Error('Description exceeds the presentation bound');
    if (typeof value === 'string') {
      if ((bytes += value.length * 2) > 2 * 1024 * 1024) throw Error('Description exceeds the presentation bound');
      return value;
    }
    if (Array.isArray(value)) return value.map(child => visit(child, depth + 1)).join('');
    if (!value || typeof value !== 'object') return '';
    const content = typeof value.attributes?.content === 'string' ? visit(value.attributes.content, depth + 1) : '';
    return content + visit(value.children ?? [], depth + 1) + (block.has(value.type) ? '\n' : '');
  }
  return visit(source, 0);
}

export async function render(spec, element) {
  const prepared = await prepareApiDocs({
    spec,
    convertedDownload: false,
    options: {
      skipBundle: true,
      disableTelemetry: true,
      sanitize: true,
      hideDownloadButtons: true,
      layout: 'stacked',
    },
  });
  window.busyapiPreparedItems = prepared.items;
  const markdownAdapter = {
    parse: source => source,
    render: source => React.createElement('span', {style: {whiteSpace: 'pre-wrap'}},
      descriptionText(source)),
  };
  const root = createRoot(element);
  root.render(React.createElement(HashRouter, null,
    React.createElement(Redoc, {
      items: prepared.items,
      store: prepared.store,
      basePath: '/',
      options: {...prepared.options, disableTelemetry: true},
      telemetryConfig: {disabled: true},
      markdownAdapter,
    })));
  return () => root.unmount();
}
