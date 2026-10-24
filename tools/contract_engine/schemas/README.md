# Published OpenAPI schema artifacts

Unmodified JSON from the OpenAPI Initiative specification registry:

- [3.1 schema, 2025-09-15](https://github.com/OAI/spec.openapis.org/blob/main/oas/3.1/schema/2025-09-15)
- [3.2 schema, 2025-09-17](https://github.com/OAI/spec.openapis.org/blob/main/oas/3.2/schema/2025-09-17)
- [3.1 dialect](https://spec.openapis.org/oas/3.1/dialect/2024-11-10) and [vocabulary meta-schema](https://spec.openapis.org/oas/3.1/meta/2024-11-10), 2024-11-10
- [3.2 dialect](https://spec.openapis.org/oas/3.2/dialect/2025-09-17) and [vocabulary meta-schema](https://spec.openapis.org/oas/3.2/meta/2025-09-17), 2025-09-17

Copyright OpenAPI Initiative contributors, Apache-2.0. See the repository LICENSE and the runtime-binding explanation in `docs/architecture.md`. These informational schemas are structural checks, not a substitute for the normative specifications.

The dated dialect/vocabulary artifacts are also used by the production schema-evaluation stage. Explicit meta-evaluation and exact-CST instance evaluation are distinct from the retained Ajv structural binding. See `docs/architecture.md` for completeness, format-annotation and supplied-example boundaries.

The evaluator also embeds JSON Schema 2020-12 meta-schema data distributed with the pinned validator packages. The specification source at the `draft-bhutton-json-schema-01` publication revision [`add836e705c9a07434c467b6b90946ba45258a73`](https://github.com/json-schema-org/json-schema-spec/tree/add836e705c9a07434c467b6b90946ba45258a73) offers its source under AFL or BSD. BusyAPI retains the BSD alternative from the upstream [license](https://github.com/json-schema-org/json-schema-spec/blob/main/LICENSE) in `JSON-SCHEMA-LICENSE`, installed alongside the package notices. This is additional dataset attribution, not a replacement for the original MIT package notices or the separately retained test-suite license.
