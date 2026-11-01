# Renderer and schema probes

These development probes compare exact upstream releases against controlled
fixtures. They are separate from the production adapters described in
[Tool support](../../../docs/tool-support.md), and none runs when opening a project.
Dependency and browser preparation is explicit; probe assets are not distributed
with BusyAPI.

Use Node **24.15.0** and the committed lock (`npm ci --ignore-scripts`). Browser
probes use Playwright **1.58.2**. Scripts retain failures and distinguish minimal
fixture coverage from rich or adversarial cases.

| Entry point | Purpose and pinned inputs |
| --- | --- |
| `bundle.cjs` | Redocly CLI **2.64.0**; Components names, escaped pointers and literal example data |
| `bundle_alternatives.mjs` | Ref Parser **16.0.5** and Hyperjump **1.18.0**; captured resolution, nested identities and exact output |
| `render.mjs` | Swagger UI **5.33.2** and Redoc CE **3.0.1**; required operation/schema/example content and denied resource attempts |
| `schema.mjs`, `typed_schema.mjs` | Hyperjump JSON Schema **1.18.0** / Browser **1.6.0**; schema scope, recursion, dynamic references and literal data boundaries |
| `oas_semantics.mjs` | Dated official OAS dialect/vocabulary artifacts and instance diagnostics |
| `numeric_semantics.mjs` | Exact CST numeric lexemes, bounded rational comparisons and equality |
| `conformance.mjs` | Selected unchanged [upstream 2020-12 fixtures](../../../fixtures/json_schema_2020_12/README.md), including `--exact-numbers` |
| `rule_isolation.py` | Development-only Bubblewrap **0.13.1** boundary comparison with pinned Node and libseccomp **2.5.5** |

The bundler probes expose failures involving illegal Components names, incorrect
pointers, example locators, numeric precision and nested `$id` bases. They are not
BusyAPI's production bundler. Renderer assertions require actual schema content
as well as blocked unwanted requests; an empty or incomplete view cannot pass.
Schema probes use supplied-only URI loaders and explicit dialect boundaries.
Selected generic-schema tests do not establish OpenAPI conformance.

Bubblewrap is an experimental development dependency, not BusyAPI's production
policy boundary. It requires explicit original input artifacts and a compatible
namespace environment; unavailable isolation is a failed or incomplete result.
Its [0.13.1 release](https://github.com/containers/bubblewrap/releases/tag/v0.13.1)
and [license](https://github.com/containers/bubblewrap/blob/v0.13.1/LICENSE) identify
LGPL-2.1-or-later terms. Native probe components require their own redistribution
review before inclusion in any deliverable.

Upstream references: [Swagger UI 5.33.2 selectors](https://github.com/swagger-api/swagger-ui/blob/v5.33.2/src/core/plugins/spec/selectors.js),
[Redoc CE 3.0.1](https://github.com/Redocly/redoc/releases/tag/redoc%403.0.1).
Spectral CLI, Swagger UI and Playwright retain Apache-2.0 terms; Redocly CLI,
Redoc CE, Ref Parser and Hyperjump retain MIT terms. Exact transitive identities,
integrity and upstream notices remain in the committed locks and input inventories.
