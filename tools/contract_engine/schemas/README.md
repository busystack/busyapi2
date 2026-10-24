# Published OpenAPI schema artifacts

Unmodified OpenAPI JSON from the OpenAPI Initiative specification registry:

- [2.0 schema, 2017-08-27](https://spec.openapis.org/oas/2.0/schema/2017-08-27),
  SHA-256 `b36871c8016292c5e66dd3b203e69aeff98bfef97e0b3c67c1909036095586a5`.
  Its restricted Draft 4 subset and native Parameter/Items/Header schemas are
  evaluated independently of the 3.x dialects. `draft04.json` is a deterministic
  serialization of the Draft 4 meta-schema distributed by pinned Hyperjump
  1.18.0 (`draft-04`, `experimental.getSchema`/`toSchema`, includeDialect: always,
  JSON indentation 2 plus final newline). SHA-256
  `3b017031ec8988e3059d8345c0d304d4f88e60c84953d6e6721b88c8e2bbf566`.
  Original identity: <http://json-schema.org/draft-04/schema>. Retain the MIT
  validator notices and JSON-SCHEMA-LICENSE dataset attribution.


- [3.0 schema, 2024-10-18](https://spec.openapis.org/oas/3.0/schema/2024-10-18),
  SHA-256 `2385f5bbb8c37878daae73baeabe7f34b2f022a4a8c049329ee61f71796f039c`.
  The structural adapter binds this trusted Draft 4 artifact to the existing
  Ajv structural stage. Source Schema Objects use the pinned evaluator's
  separate OAS 3.0 dialect, supplemented by normative rules and exact bounds;
  authored documents are never converted into modern JSON Schema.
- [3.1 schema, 2025-09-15](https://github.com/OAI/spec.openapis.org/blob/main/oas/3.1/schema/2025-09-15)
- [3.2 schema, 2025-09-17](https://github.com/OAI/spec.openapis.org/blob/main/oas/3.2/schema/2025-09-17)
- [3.1 dialect](https://spec.openapis.org/oas/3.1/dialect/2024-11-10) and [vocabulary meta-schema](https://spec.openapis.org/oas/3.1/meta/2024-11-10), 2024-11-10
- [3.2 dialect](https://spec.openapis.org/oas/3.2/dialect/2025-09-17) and [vocabulary meta-schema](https://spec.openapis.org/oas/3.2/meta/2025-09-17), 2025-09-17

Copyright OpenAPI Initiative contributors, Apache-2.0. See the repository LICENSE and the runtime-binding explanation in `docs/architecture.md`. These informational schemas are structural checks, not a substitute for the normative specifications.

The dated dialect/vocabulary artifacts are also used by the production schema-evaluation stage. Explicit meta-evaluation and exact-CST instance evaluation are distinct from the retained Ajv structural binding. See `docs/architecture.md` for completeness, format-annotation and supplied-example boundaries.

The evaluator also embeds JSON Schema 2020-12 meta-schema data distributed with the pinned validator packages. The specification source at the `draft-bhutton-json-schema-01` publication revision [`add836e705c9a07434c467b6b90946ba45258a73`](https://github.com/json-schema-org/json-schema-spec/tree/add836e705c9a07434c467b6b90946ba45258a73) offers its source under AFL or BSD. BusyAPI retains the BSD alternative from the upstream [license](https://github.com/json-schema-org/json-schema-spec/blob/main/LICENSE) in `JSON-SCHEMA-LICENSE`, installed alongside the package notices. This is additional dataset attribution, not a replacement for the original MIT package notices or the separately retained test-suite license.
