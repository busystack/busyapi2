# Migrate a specification

Migration is an explicit action that creates a separate copy. Opening, editing,
validating, saving, bundling and documenting supported Swagger 2.0 and OpenAPI
3.0, 3.1 or 3.2 files preserve their specification family.

In the desktop application, open **BusyAPI → Migrate specification…**, choose the
target specification, and select **Review migration**. Choose a new output folder
and review the affected resources and before/after changes. Resolve any listed
decisions, then prepare a fresh review. **Create migrated copy** becomes available
when the captured graph has a complete conversion. Closing the review leaves
the destination unchanged. Changing an input requires a new review.

If source validation fails or cannot complete, the review shows the captured
findings with links to their Source locations. Changing a captured input retires
those links; repair the source and prepare a fresh review. No migrated copy is
created while required source analysis remains invalid or incomplete.

The desktop review includes current unsaved buffers. The independent CLI reads
saved files. First request a review:

```sh
busyapi migrate api.yaml --target 3.0.4 --output ../converted --json
```

Inspect the reported changes and `reviewIdentity`. Publish that exact review by
repeating the command with its identity:

```sh
busyapi migrate api.yaml --target 3.0.4 --output ../converted --json --apply REVIEW_ID
```

The identity binds the inputs, target, decisions, destination and migration
implementation revision. Changed inputs or an occupied destination prevent
publication. Original files and desktop working buffers remain intact.

External-example migration includes available, fully evaluated payloads
as unchanged byte copies under `examples/`. Review lists the source, destination
and byte count; JSON review also includes content identities and occurrence
provenance. Local URI mappings retain access after moving the output folder.
Publication rechecks the captured bytes, including unsaved buffers, along with
the documents. Missing, denied or unsupported interpretation still blocks the
conversion. See the [support matrix](implementation/native-openapi-support.md) for coverage and verification status.

Upgrades follow **2.0 → 3.0 → 3.1 → 3.2**, including composed upgrades. Downgrades
check whether the actual declarations can be represented in the selected target.
A target choice does not guarantee that every source construct can be converted.
Missing dependencies, unsupported mappings and unresolved decisions produce
located findings and no publishable output. Target validation and request
invariants supplement the structural mappings.

OpenAPI 3.0 server-variable defaults are sent even when they fall outside the
recommended enum. Explicit migration to 3.1 or 3.2 adds such a default to the
target enum, preserving the existing choices and their order. An empty 3.0 enum
becomes the default-only enum. The review shows these targeted changes. URI and
Terms-of-Service destination proofs include the default; incompatible reference
forms or ambiguous shared syntax receive located blockers, with no publication.

Captured resources can themselves be complete OpenAPI descriptions, including
entries from different supported families. The review lists each entry's original
and target version. Their operations, servers, media and shared definitions keep
separate entry contexts, and BusyAPI coordinates connected entries before
validating the target graph. Check every affected document in the review. Shared
resources with incompatible interpretations produce source-located blockers.

Directional upgrades create named request and response schema variants when
Swagger request exclusions or OpenAPI 3.0 required-property rules differ from
the target. Captured consumers receive the appropriate variant; neutral
definitions, examples and defaults retain their own associations. References,
recursion and shared Header reference chains use the same canonical graph and
CST ownership. Generated variants live in separate standard YAML/JSON schema
resources; they do not add implicit discriminator component names. The review
includes each new file with an empty before view, its captured entry owner and
all binding changes. Explicit mappings and captured implicit model names select
the corresponding directional schema. External choices without a determinable
wire name require an explicit source mapping.
When conversion to 3.2 makes a discriminating property optional, the review
requires an explicit fallback decision. Choices identify eligible `oneOf`/`anyOf`
alternatives or `allOf` descendants and their original source locations. The
containing discriminator schema is not a fallback choice. A proposed object
without the discriminating property must validate against both the alternative
and the whole parent before that target is offered. Choosing a target does not
replace parent assertions or change `oneOf` exclusivity. Circular, incompatible
or unproved choices do not authorize publication. Earlier undefined behavior is
not silently assigned a default. Independently interpreted literal and incompatible entry contexts still need additional ownership
mappings. Downgrades that would introduce stronger request exclusions remain
blocked until a faithful mapping is available. See the support matrix for
verification status.

OpenAPI 3.0 requires a required discriminator property. An invalid optional
property must be corrected in the source before migration. A valid required
property stays required on upgrade and needs no fallback decision. Optional
3.1 discriminators use the explicit 3.2 review described above.

Swagger downgrade removes inactive `writeOnly: false` and `deprecated: false`
schema annotations without changing their effective behavior. A false value
also referenced as a schema keeps a separate standard definition. Active
annotations still need a faithful target mapping.

When a modern boolean `additionalProperties` field is also referenced as a
standalone schema, downgrade keeps the field's value and creates an equivalent
standard schema definition for the references. Review shows that definition and
the changed bindings. Other literal consumers retain their values.

Downgrading a 3.2 document resolves the URI meaning supplied by `$self` before
removing that field. Document metadata, nested schema identities and captured
references retain their resolved destinations; API server URLs keep their
separate retrieval context. Dynamic reference bindings and delivered resource
connections receive the same cold-reopen proofs as other migrations. The target
uses its own supported identity rules; it does not claim an in-band `$self` field.
Independent schema/literal ownership can still block conversion. Unknown external
consumers are outside the captured graph's guarantees.

Modern `dependentRequired` property dependencies can migrate to OpenAPI 3.0
using equivalent presence conditions. False, zero and null still count as present.
Swagger 2.0 conversion supports redundant dependencies and dependencies whose
trigger is proved required through captured references, composition or other
dependencies; other conditional dependencies produce a located blocker. A dependency map also referenced independently as a schema requires a
separate representation and blocks conversion. Original arrays and comments are
retained where the mapping permits; restructuring appears in the review.

Modern `dependentSchemas` conditions can also migrate to OpenAPI 3.0. The
dependent schema still applies to the whole object only when its named property
is present. Non-object values keep their original behavior. Swagger conversion
currently requires a declared object-only type and a proved required trigger;
other conditions receive a located implementation blocker. References to a moved
dependent schema follow its reviewed destination. Shared YAML ownership and a
dependency map independently interpreted as a schema remain explicit blockers.

A modern `$dynamicRef` that resolves to a pointer or ordinary anchor can be
converted to a static reference in Swagger 2.0 or OpenAPI 3.0. Its assertions
and sibling constraints remain in separate `allOf` branches, and the review
proves the relocated target. References that start at a dynamic anchor still
require a faithful dynamic-scope mapping and block older-family conversion.
Literal reference-looking keys inside example and extension data are preserved.

Swagger server conversion preserves bracketed IPv6 hosts and effective operation
scheme overrides. A malformed host, fixed base path or scheme list blocks
migration before output; source-located findings remain available for correction.
The pinned URI implementation's unsupported IPvFuture host notation remains an
implementation blocker, rather than being converted into an invalid target URL.

Swagger 2.0 permits free-text `info.termsOfService`; 3.x requires a URI.
Prose that cannot form a URI produces a located blocker. A URI-shaped value
requires the explicit `interpret-terms-as-uri` decision before it becomes a link.
Normal Swagger editing, bundling and relocation preserve the original text.

OpenAPI 3.0 resolves relative Terms of Service URLs against its Servers.
Migration captures that destination before switching to another family's URI
rules. Different Server destinations cannot be silently collapsed to one. A fixed
scheme or authority can prove a destination even with open Server variables
when the Terms reference replaces those variable components; a default value
alone does not establish that proof.
Unproved variable dependencies or work limits report a precise limitation; no
partially qualified copy is published.

A 3.0 request-body declaration that consumers must ignore needs an explicit
omission decision before conversion to Swagger, 3.1 or 3.2. The reviewed copy
omits that declaration; original documents stay intact. Active request bodies
are preserved. Methods absent from the target family, such as TRACE in Swagger,
produce a source-located blocker.

Descriptions keep their original text when the captured link and image
destinations remain unchanged across conversion and relocation. This includes
root-relative, network-path and normalized parent paths where their resolved
addresses are identical. When a destination changes, BusyAPI rewrites only the
parsed link/image destination and proves the resulting rendered destination.
Code examples and prose remain untouched. Conflicting literal/rendered ownership still
produces a source-located blocker. Removing a schema identity is included in that
check.

URL-encoded forms with independent scalar fields can be downgraded to Swagger
`formData` parameters. Media type casing and explicit UTF-8 charset parameters
are preserved in the target media declaration. Primitive arrays use their declared encoding, including
the repeated text-field default for named primitive-array properties. Separated string items
need a finite enum that excludes their separator. Joint object constraints,
shared form schema owners and other encodings can still require additional
mappings; the review identifies these blockers before publication.

The output contains standard OpenAPI documents in their original YAML/JSON
formats, a `migration.json` receipt, and an optional `busyapi.yaml` project that
retains captured resource mappings. Open the output folder to use those mappings.
Ordinary local references also reopen directly from the OpenAPI file, including
after copying those documents to another folder without the project manifest.
Complete API documents are published together at the output directory's top
level; fragments can remain under `resources/`. Each API can therefore open
within its normal containing-directory access boundary. The output project
registers all captured complete descriptions; unrelated project roots outside
the captured graph are not migrated.
Comments and organization are retained where the mappings permit; restructuring
is visible in the review. Explicit schema/document identities can still require
their captured mappings.

Untouched YAML anchors and aliases retain their authored spelling and shared
values. An unchanged canonical reference can retain its spelling when the
copied resources and reviewed identity mappings prove the same target. Review
may expand affected aliases so a converted occurrence can change independently
of its other consumers. This includes shared version declarations, schemas,
references and anchored destinations. Other consumers keep their exact values;
original documents stay intact. Conflicting contract/literal interpretations
still receive source-located blockers until their ownership is resolved.

See the [native support matrix](implementation/native-openapi-support.md) for
verified workflows and remaining conversion limitations.

For a 3.x document with an absent or empty root `servers` array, migration
materializes the original effective `/` server in the reviewed copy. This
retains the API origin when the contract moves to another directory or URI;
the original declaration stays unchanged.
