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

Upgrades follow **2.0 → 3.0 → 3.1 → 3.2**, including composed upgrades. Downgrades
check whether the actual declarations can be represented in the selected target.
A target choice does not guarantee that every source construct can be converted.
Missing dependencies, unsupported mappings and unresolved decisions produce
located findings and no publishable output. Target validation and request
invariants supplement the structural mappings.

Captured resources can themselves be complete OpenAPI descriptions, including
entries from different supported families. The review lists each entry's original
and target version. Their operations, servers, media and shared definitions keep
separate entry contexts, and BusyAPI coordinates connected entries before
validating the target graph. Check every affected document in the review. Shared
resources with incompatible interpretations produce source-located blockers.

Optional `readOnly` and `writeOnly` properties can cross the 3.0/modern schema
boundary when captured uses preserve their evaluation. Conversions that change
required-property behavior or introduce Swagger's stronger request exclusion are
blocked until a faithful mapping is available. The review identifies the source
annotation; migration does not silently change which payloads are accepted.

Swagger 2.0 permits free-text `info.termsOfService`; 3.x requires a URI.
Prose that cannot form a URI produces a located blocker. A URI-shaped value
requires the explicit `interpret-terms-as-uri` decision before it becomes a link.
Normal Swagger editing, bundling and relocation preserve the original text.

A 3.0 request-body declaration that consumers must ignore needs an explicit
omission decision before conversion to Swagger, 3.1 or 3.2. The reviewed copy
omits that declaration; original documents stay intact. Active request bodies
are preserved. Methods absent from the target family, such as TRACE in Swagger,
produce a source-located blocker.

Descriptions keep their original text when the captured link and image
destinations remain unchanged across conversion and relocation. This includes
root-relative, network-path and normalized parent paths where their resolved
addresses are identical. A changed or unresolvable destination produces a
source-located blocker. Removing a schema identity is included in that check.

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
copied resources and reviewed identity mappings prove the same target. A change
that would edit, copy or replace shared YAML syntax needs an ownership-preserving
mapping; otherwise the review identifies the original field and blocks publication.
This also applies to shared version declarations and anchored empty destinations.

See the [native support matrix](implementation/native-openapi-support.md) for
verified workflows and remaining conversion limitations.
