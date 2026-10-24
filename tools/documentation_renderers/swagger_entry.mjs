// Build entry for the exact upstream Swagger Client already matching 5.33.2.
// Swagger UI's own plugin omits its client's 3.2 strategy. Supply the supported
// strategy explicitly; never run generic JSON-reference traversal on examples.
import openapi31 from 'swagger-client/es/resolver/strategies/openapi-3-1-apidom/index.js';
import openapi32 from 'swagger-client/es/resolver/strategies/openapi-3-2-apidom/index.js';
import {readOnlySwaggerConfiguration} from './swagger_adapter.mjs';
import {graphAddressedDisplay} from './graph_display.mjs';

const strict=strategy=>Object.freeze({...strategy,
  resolve:options=>strategy.resolve({...options,mode:'strict'}),
});
const strategies=Object.freeze([strict(openapi32),strict(openapi31)]);
export function configuration(text,projection,displayUri,options) {
  const presentation=graphAddressedDisplay(text,projection,displayUri);
  return readOnlySwaggerConfiguration(presentation,{...options,resolveStrategies:strategies});
}
