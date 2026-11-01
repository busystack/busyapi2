# Native OpenAPI support

**In progress. Complete native acceptance has not passed.**

BusyAPI targets native Swagger 2.0 and OpenAPI 3.0.x, 3.1.x and 3.2.x.
Standard YAML/JSON remain authoritative. Supported declarations are preserved;
opening, editing, saving, validating and rendering do not migrate documents.

## Authorities

Normative specification text takes precedence over informational schemas:

- [Swagger 2.0](https://spec.openapis.org/oas/v2.0.html)
- [OpenAPI 3.0.4](https://spec.openapis.org/oas/v3.0.4.html)
- [OpenAPI 3.1.2](https://spec.openapis.org/oas/v3.1.2.html)
- [OpenAPI 3.2.1](https://spec.openapis.org/oas/v3.2.1.html)
- [JSON Schema Core](https://json-schema.org/draft/2020-12/json-schema-core)
  and [Validation](https://json-schema.org/draft/2020-12/json-schema-validation)
- [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986),
  [RFC 6901](https://www.rfc-editor.org/rfc/rfc6901),
  [RFC 2045](https://www.rfc-editor.org/rfc/rfc2045),
  [RFC 2046](https://www.rfc-editor.org/rfc/rfc2046) and
  [RFC 7578](https://www.rfc-editor.org/rfc/rfc7578)
- [YAML 1.2.2 anchors and aliases](https://yaml.org/spec/1.2.2/#3222-anchors-and-aliases)

## Implementation and verification status

The shared contract engine and canonical graph own semantics. Core owns approved
resource acquisition, immutable captures and safe publication. Desktop and CLI
consume those shared results. Source-preserving transactions remain authoritative.
Current changes require complete engine, Core, native and packaged verification;
source inspection or a successful build is not runtime acceptance.

| Area | Owner | Implementation status | Current verification |
| --- | --- | --- | --- |
| Family declarations, dialects and capabilities | Engine specification and graph | Implemented; detailed remaining semantics below | Complete current qualification pending |
| Native creation, Design, Source and Reference | Engine authoring/projection, Core, native presentation | Implemented subsets in all four families; required gaps remain | Complete current qualification pending |
| Restricted schemas and modern schema resources | Engine schema owners and exact evaluator | Family-specific rules implemented; unsupported dialects remain explicit | Complete current qualification pending |
| Embedded multipart text examples | Shared MIME/text owners, Core request preparation | Authored Unicode, explicit bytes, transfer encodings and part charsets have distinct paths | Implemented but unverified |
| Available external media examples | Captured byte resources and shared media evaluation | Exact approved bytes retain media/schema/source ownership | Implemented but unverified |
| Portable external-example migration | Migration examples, Core publication and shared review | Exact byte copies, native locator repairs and delivered-resource proofs | Implemented but unverified |
| Scoped binary/byte migration | Migration binary owner | Established raw, text/JSON and base64 contexts mapped; mixed/constrained contexts remain | Implemented but unverified |
| Modern required-property lowering | Migration required-presence owner | Scoped modern-to-3.0 presence assertions retain constraints | Implemented but unverified |
| Inactive annotation downgrades | Schema migration and canonical ownership | False writeOnly/deprecated annotations lower to Swagger defaults; independently referenced boolean schemas retain collision-safe owners | Implemented but unverified; active directional annotations remain incomplete |
| Shared boolean-schema downgrades | Schema migration, captured references and CST provenance | Boolean additionalProperties fields retain their values; independently referenced schema roles receive standard definitions with repaired references | Implemented but unverified |
| Directional schema upgrades | Migration direction, canonical graph and CST owners | Swagger request exclusions, 3.0 required-list roles, separate schema resources, nested-target repairs and shared Header reference variants; affected YAML aliases receive separate planning-copy owners | Implemented but unverified; independently interpreted literal and cross-entry ownership remain incomplete |
| YAML migration ownership | Existing source CST and migration provenance | Captured property/alias tokens split affected logical uses, retain exact data and comments, and preserve other consumers before conversion | Implemented but unverified; ordinary editing guards remain unchanged |
| Directional discriminator bindings | Shared named-model table, canonical connections and migration | Implicit/explicit model targets retained without adding component names; 3.2 fallback choices bind eligible composition alternatives and exact instance witnesses | Implemented but unverified; incompatible entry namespaces and indeterminate external names remain blocked |
| Native 3.2 discriminator fallbacks | Canonical composition selector, authoring diagnostics and reference choices | Existing fallback targets checked against adjacent alternatives/allOf descendants; Design selection and Source completion share captured targets | Implemented but unverified |
| Numeric mock witnesses | Shared exact decimal candidate construction and native response proof | YAML/JSON bounds, strict bounds, integer rounding and composed decimal lattices produce bounded suggestions; generated responses require valid native proof | Implemented but unverified; other bounded witness and CONNECT work remains incomplete |
| Swagger discriminator migration | Shared named-model owner and migration specialization | Compatible captured namespaces mapped; shared ownership cases remain | Implemented but unverified |
| Document identity downgrade | Migration URI owner, canonical graph and CST | `$self` lowering captures document URI fields, nested schema identities and reference bases; API URL context remains separate | Implemented but unverified; independent schema/literal ownership remains incomplete |
| Changed-base Markdown | Shared destination-span proof, migration and maintenance owners | Rendered occurrences mapped without rewriting code or prose; migration separates affected YAML alias uses while preserving other exact data | Implemented but unverified; independently interpreted literal/contract occurrences still need separate ownership |
| TypeScript compiler gate | Existing pinned engine build and CI paths | Repeatable compiler check wired before bundling | Implemented but unverified |
| MIME result and Markdown parser typing | Engine execution and Markdown relocation | Literal revision ownership and explicit unknown-value narrowing | Implemented but unverified |
| Migration preflight producer admission | Native fixture preflight, engine and Core | Current revision admitted; regression checks all three production consumers | Implemented but unverified |
| Upstream Flutter/Dart build inputs | SDK verification, CMake, CI and distribution checks | Standard SDK installation; independent official archive identities pinned; version-2 receipts require authenticated member identities | Metadata matched to official publications; selected binary provenance and runtime qualification remain blocked pending independent member evidence |
| Native and packaged acceptance | Existing qualification suites | Required acceptance remains incomplete | Not passed |

## Required functionality still open

- Remaining independently interpreted literal and cross-entry directional ownership;
  request/response specialization in faithful downgrade mappings.
- Shared schema/literal ownership and incompatible entry contexts, including
  discriminator specialization and independently interpreted Markdown uses.
- Mixed or constrained binary contexts, opaque content, file unions and reusable
  media lacking sufficient occurrence context.
- Remaining typed/dynamic, nested and positional multipart, parameter/header
  representations and incremental streams.
- CONNECT behavior and remaining bounded response-witness generation.
- Remaining URI-preserving inline, copy and relocation mappings and named-schema
  maintenance positions.
- Remaining OpenAPI 3.2 identity, operation, parameter, media, tag, security and
  discriminator rules; independent schema/literal identity ownership is incomplete.

A missing implementation is not an unrepresentable conversion. Migration must
retain source-located blockers until a faithful mapping is implemented. It must
preserve originals, reject stale reviews, expose decisions and validate delivered
outputs under the target family's rules. Valid output alone does not establish
behavioral equivalence.

Regression coverage includes production entry points, YAML/JSON, published
patches, exact bytes and numbers, invalid inputs, unavailable resources,
cancellation, stale captures, source preservation and publication failures.
Current full-suite, native and packaged acceptance remains incomplete.
Directional regressions are in `test_migration_direction.cjs` and
`test_migration_access.cjs` through `planMigration` and native schema evaluation.
Core access and derived-resource regressions cover captured ownership,
publication, cancellation, stale inputs and package/CLI reopen; the widget review
regression uses the existing controls and localized fallback selection. These additions have not been executed.
Their authorities are Swagger 2.0 §6.4.18, OpenAPI 3.0.4 §§4.7.24–4.7.25 and
the OpenAPI 3.2.1 Discriminator Object.

Document-identity regressions use `test_migration_identity.cjs` through native
planning, structural analysis and schema evaluation. They cover both 3.2 patches,
YAML/JSON, direct and composed downgrades, nested resource IDs, dynamic anchors,
cross-document references, moved files, exact values and missing resources.
The external-example regression retains exact byte and defining-base checks;
Core identity tests add unsaved inputs, cancellation, stale reviews and standalone
reopen. These additions have not been executed. The URI authority is
[OpenAPI 3.2.1 §§4.1.1–4.1.2 and 4.5.2](https://spec.openapis.org/oas/v3.2.1.html#relative-references-in-api-description-uris),
together with RFC 3986 and JSON Schema Core resource and reference rules.

Fallback selection uses the shared `discriminator_alternatives.ts` graph
projection and `schema_sample_candidates.ts` suggestion construction. The native
schema evaluator proves each candidate against the alternative and complete
parent. Missing discriminator decisions remain pending specification metadata;
this partial instance proof is not a complete validation result. Other
incomplete evaluation blocks selection, and publication still requires full
target validation. Core validates choice labels and captured source ranges; the
existing native review uses localized labels. The normative authority is the
[3.2.1 Discriminator Object](https://spec.openapis.org/oas/v3.2.1.html#discriminator-object).
`test_migration_discriminator_defaults.cjs`, Core fallback-decision tests and the
existing widget review cover target identity, accepted/rejected payloads, exact
numbers, stale choices, cancellation and malformed review metadata. These changes
and regressions are implemented but unverified. The discriminator producer
regression now checks `discriminator-models-v2` and production mock rejection of
obsolete `swagger-discriminator-models-v1` proofs; those tests have not run.

Fallback migration fixtures distinguish the families' discriminator rules.
The optional-property 3.0.4 cases remain negative validation/publication tests;
valid 3.0.4 upgrades keep the property required and add no fallback decision.
Positive optional fallback reviews use 3.1.2, whose absent-property selection
behavior is undefined until the user chooses the 3.2 fallback. Engine and Core
cases cover YAML/JSON and oneOf/anyOf/allOf, selected target identity and behavior,
unchanged originals, stale decisions and publication refusal. Production 3.0
validation is unchanged. These corrected and added regressions have not run.

Native `defaultMapping` checks distinguish ineligible targets from unavailable
inheritance context. Metadata errors do not change JSON Schema instance
validation. The existing Design reference picker and Source completions use the
same composition selector, with per-root checks before a reviewed edit.
`test_discriminator_alternatives.cjs` and Core selection regressions cover
aliases, reference siblings, external/escaped targets, dynamic contexts,
unsupported dialects, exact source preservation, Undo/Redo, cancellation, stale
captures and cold reopen. These regressions have not run. Three older valid
controls used unrelated fallback schemas; they now use listed alternatives or
actual allOf descendants, as required by the normative Discriminator Object.

Shared Markdown migration retains logical description provenance through YAML
aliases. `migration_shared_text.ts` prepares localized replacements only in the
migration copy, insulates alias consumers before changing a definition, and
compares the entire exact data projection against the requested string changes.
Alias expansions and presentation changes appear in the existing review.
Ordinary editing retains its shared-node guards. A single occurrence interpreted
as both literal data and rendered contract text remains an ownership gap.
`test_migration_shared_text.cjs`, existing Markdown identity/location regressions
and Core publication tests cover scalar/collection/key anchors, repeated names,
virtual descendants, different bases, exact numbers, literal payloads, unsaved
source, cancellation, stale reviews and cold reopen. The old shared-Markdown
refusal controls now require successful mapping plus unchanged literal values.
These changes and tests are implemented but unverified. Migration producer 39
is admitted consistently by engine, Core and native preflight; the permanent
cross-component consistency regression remains active.

Migration YAML ownership is handled by `migration_yaml_ownership.ts` through
`MigrationSource`, including schema copies, required-presence lowering, ignored
body omissions, document identities, declarations and reference relocation.
It removes only captured anchor-property tokens and expands only affected
alias-value tokens, then proves the entire exact data projection unchanged
before the intended conversion. Bindings follow actual captured node identities,
including reused names and key anchors. Logical alias provenance survives schema
hoisting and multi-file copies. Other literal consumers and untouched aliases
retain their values; restructuring is visible in the existing review.

Source capture uses the same public Parser/Composer as the pinned yaml 2.9.0
`parseDocument` implementation, retaining property tokens during its single
parse. The exact dependency source is `yaml/dist/public-api.js` and the
[2.9.0 public API](https://github.com/eemeli/yaml/blob/v2.9.0/src/public-api.ts);
the existing MIT dependency attribution is unchanged. No third-party source or
dependency version changed. `test_yaml_source_ownership.cjs` compares captured
parsing with that pinned API, including invalid documents and ordinary shared
edit refusals. `test_migration_alias_specialization.cjs` and the existing YAML,
direction, required-presence, identity, ignored-body and server regressions cover
source-preserving alias separation, exact numbers, literal consumers, recursive
references, composed upgrades and faithful downgrade cases. Core tests cover
unsaved models, cancellation, stale reviews, publication and reopen. Previously
blocked representable alias cases now require successful conversion plus actual
behavior and unchanged-data assertions. These changes have not been executed.

Swagger downgrade removes only inactive false `writeOnly` and `deprecated`
Schema Object annotations, preserving effective defaults and accepted request/
response values. Active annotations retain their existing blockers. A modern
false annotation referenced independently as a schema is moved to a standard
definition using the shared restricted boolean-schema mapping; source provenance,
references and namespace collisions remain explicit. The authorities are OpenAPI
3.0.4 §4.7.24.2 and JSON Schema Validation 2020-12 §§9.3–9.4.
`test_migration_inactive_annotations.cjs` covers every published 3.0–3.2 patch,
YAML/JSON, request/response evaluations, exact numbers and empty values, aliased
literal consumers, independent false schemas, naming collisions and active-rule
refusals. Core regressions cover unsaved captures, cancellation, stale publication
and native Swagger reopen. These source changes and regressions have not run.

Boolean `additionalProperties` fields retain their values during modern-to-3.0
and modern-to-Swagger downgrades. Captured independent schema references receive
separate standard definitions with equivalent object assertions. The unchanged
field remains owned by its containing object, while schema-reference provenance
selects the generated definition. Names are deterministic and collision-safe;
normal named schemas called `additionalProperties` use ordinary schema rules.
The authorities are OpenAPI 3.0.4 §4.7.24.1, Swagger 2.0 §6.4.18 and JSON Schema
Core 2020-12 §4.3.2. `test_migration_boolean_owners.cjs` covers all published
3.1/3.2 patches, YAML/JSON, both boolean values, standalone and cross-file
consumers, chained references, accepted/rejected request/response instances,
exact numbers, aliases, literal values, collisions and missing resources.
Core regressions cover unsaved external captures, cancellation, stale reviews,
publication and cold reopen. These changes and tests have not run. Remaining
independent literal/contract ownership gaps are separate from this mapping.

Numeric witness construction reads canonical numeric values in both YAML and
JSON rather than requiring JSON's CST node kind. It uses the existing exact
decimal owner for bound comparison and bounded integer-lattice arithmetic for
multiple constraints. Suggestions never authorize a response: native evaluation
proves the whole original schema. Generated output for a valid mock request is
withheld when its final response proof is invalid or incomplete; validation
proxies retain their response-byte and error policies. The sample producer is
revision 3, admitted consistently by Core and the existing readiness tests.
`test_mock_numeric_candidates.cjs` and Core/packaged CLI regressions cover exact
wire bytes, strict bounds in each family, fractions, composed constraints,
overflow/underflow, external schemas, impossible numeric cases, captured unsaved
buffers, cancellation and stale plans. These changes have not been executed.

Flutter 3.47.5/Dart 3.13.4 and the existing framework/engine revisions are
unchanged. `tools/flutter_sdk.lock.json` pins the
[official Linux release catalog](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json)
and the SDK, Linux debug/profile/release engine and Dart archive identities from
their published attestation subjects. The
[3.47.5 SDK attestation](https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz.intoto.jsonl)
agrees with the catalog's archive SHA-256. This establishes expected archive
identities, not the authenticity of a selected local binary or cryptographic
verification of attestation signatures. The verifier requires an independently
established member pin or reads the original ZIP only after its complete hash
matches that pin. Installed checks reject self-hash-only receipts and forged
library/receipt pairs. No SDK acquisition or replacement occurs in this path.
`tools/test_flutter_sdk.py` adds owned-fixture regressions for absent/modified
archives, forged receipts and existing-SDK verification. Those tests and actual
binary comparison have not run; native and packaged acceptance remain open.
