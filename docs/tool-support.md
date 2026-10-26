# Tool support

Native Swagger 2.0 and OpenAPI 3.0 authoring use their own Schema Object semantics,
field metadata, reference rules and exact instance evaluation. Creation accepts
the published patches in every approved family; normal workflows retain the declaration. Native Reference and native HTML export
use the same captured graph. Swagger/Redoc, Prism, generation and comparison
qualification remain separate. The evolving [family/workflow matrix](implementation/native-openapi-support.md)
records actual coverage and outstanding native and packaged checks.

References retain the declared family of each complete OpenAPI document. A
`$ref` substitution crossing between Swagger 2.0 or OpenAPI 3.0 and another declared family
reports `reference.family.unsupported`; dependent evaluation and bundling remain
incomplete. BusyAPI uses this explicit policy for unspecified cross-family legacy
interpretation. The source and target remain available for editing. Modern
cross-document references retain their owning dialects and feature sets.
Unversioned fragments use the captured referring context and can be shared among
different roots without retaining the previous root's schema rules.
Typed reference choices and Source completions use this same context check.
An `operationRef` link identifies its target operation and keeps its separate
reference rules.

Security Requirement arrays contain OAuth/OpenID scopes or, in OpenAPI 3.1 and
3.2, role names for other security schemes. Swagger 2.0 and OpenAPI 3.0 require
empty arrays for non-OAuth schemes. Native editing and selection retain authored
roles; 3.1 uses named bindings, while 3.2 also permits URI bindings. A migration
to an older family reports a source-located blocker when it cannot preserve role
requirements. Role names are not exchanged in-band and do not verify a caller's
identity. See [OAS 3.1.2 §4.8.30](https://spec.openapis.org/oas/v3.1.2.html#security-requirement-object).

Swagger UI **5.33.2** with client **3.38.2** has adapters for all four families.
Redoc CE **3.0.1** supports native 3.0/3.1/3.2 display input but internally
converts Swagger 2.0 even with `skipBundle`. BusyAPI therefore rejects Redoc
for 2.0; choose native Reference, native HTML or Swagger UI. Renderer
compatibility remains separate from native authoring support and current
acceptance status in the [support matrix](implementation/native-openapi-support.md).

`tools/test_openapi_application.py` defines native documentation workflows for
the preset dialog and output review, including unsaved Design/Source buffers,
cancellation, destination races, declared versions, exact numbers and source
provenance. These checks are separate from external-renderer and distribution
acceptance.

OpenAPI 3.0 request-body declarations remain editable and inspectable on every
method. Its consumption rule ignores them for GET, HEAD, DELETE, OPTIONS and
TRACE; they neither force an outgoing body nor constrain an explicitly entered
body. HTTP rules independently forbid sending content with TRACE. Request and
native Reference show the family distinction, including offline HTML.
POST, PUT and PATCH retain their declared body semantics. Swagger 2.0 and modern
OpenAPI retain their own body rules. See [OAS 3.0 §4.7.10.1](https://spec.openapis.org/oas/v3.0.4.html#operation-object).
The pinned mock adapter consumes this same rule without changing the captured
document. Mock startup rejects a stale capture, cancels owned derivation work and
rechecks ownership before returning a listener. Switching project roots retires
both prepared and in-flight native mock captures. A running immutable capture
retains its original rules and reports that it is outdated after source changes.
Mock request-body assertions use the packaged native evaluator against that
original resource capture, including schema direction, null values, false/zero
and exact numbers. Prism retains routing and response generation. Unsupported
body evaluation returns HTTP 501 with `complete: false`; it cannot become a clean
validation result when proxy errors are disabled. Native findings retain source
coordinates, and diagnostic headers preserve Unicode as valid bounded JSON.
`mock --json` identifies the native validator separately from Prism. Named
URL-encoded and multipart bodies use the same native decoder as request/response
checks. Mock response assertions now use the same captured native evaluator for
status, selected media, body data and supported header representations. Response
checks preserve exact numeric tokens and 3.2 Set-Cookie field lines. The response
owner is reported separately as `nativeResponseValidation` in `mock --json`.
`busyapi-response-validation-complete: false` and located `sl-violations` identify
incomplete response checks while retaining forwarded bytes. Malformed applicable
JSON retains the existing HTTP 500 proxy policy.

Direct requests, saved contract cases and mocks share the engine's response-header
codec. Core submits the actual separate field lines with their captured source
occurrence; header references and schema dialects retain their original owners.
OpenAPI 3.2 content-based `Set-Cookie` values use LF between complete field lines,
preserving commas within each cookie. Supported boolean schemas retain their
assertions. Simple-style scalar and collection compositions are checked against
the whole original schema using bounded wire interpretations. Decimal values
retain their exact text; booleans and null use their literal JSON spellings.
A completely checked valid interpretation proves conformance. If no valid
interpretation is proved and enumeration or evaluation is incomplete, the check
remains incomplete. Nested collection forms without defined serialization also
remain incomplete. This conversion policy follows the implementation-defined
guidance in [OpenAPI 3.2 §4.24.4.2](https://spec.openapis.org/oas/v3.2.1.html#non-json-data)
and Appendix B; it does not change the authored schema or response bytes.

For OpenAPI 3.0/3.1 non-exploded form cookies, one array item is encoded without
a structural comma. Empty optional arrays/objects emit no cookie; required empty
collections produce a located preparation refusal. A form representation needing
a structural comma is refused because Cookie syntax excludes that character;
encoding the delimiter would change its meaning. Mock decoding splits delimiters
before decoding data, preserving `%2C` inside one item and decoding percent
sequences once. OpenAPI 3.2's prohibition on explicit `explode: false` remains.
This policy follows [3.0 Appendix D](https://spec.openapis.org/oas/v3.0.4.html#appendix-d-serializing-headers-and-cookies),
[3.1 Appendix C.2](https://spec.openapis.org/oas/v3.1.2.html#delimiters-in-parameter-values),
[RFC 6570 §2.3](https://www.rfc-editor.org/rfc/rfc6570#section-2.3) and
[RFC 6265 §4.2.1](https://www.rfc-editor.org/rfc/rfc6265#section-4.2.1).

Mock security declarations use the captured native operation and graph-resolved
schemes, reported separately as `nativeSecurityValidation` in `mock --json`.
Alternatives use OR; schemes within one requirement use AND. An anonymous
alternative or empty operation override permits unrelated Authorization fields.
API key names retain their case in query/cookie fields and ignore case in headers.
Empty values retain presence; duplicate credential fields refuse an arbitrary
choice. Cookie keys require complete RFC6265 names and framing, without treating
an ampersand inside another cookie's value as a separate credential.

Basic, Bearer/OAuth/OpenID and Digest checks cover credential wire syntax. Basic
uses canonical Base64, rejects ASCII controls and permits colons in passwords;
HTTP authentication scheme names ignore case. These checks do not prove password
validity, token issuer trust, role/scope grants or nonce authenticity. Unsupported
mechanisms or unavailable mutual-TLS peer proofs return HTTP 501 with
`complete: false`, including when proxy forwarding errors are disabled. Generated
mocks retain their 401 invalid-credential policy. A validation proxy can forward
known-invalid input when forwarding errors are explicitly disabled, retaining
native findings and original response bytes. BusyAPI owns its diagnostic response
fields, including `busyapi-request-security-complete`; upstream values cannot
forge them. Security findings retain the captured source snapshot and ranges.

Mock operations also use the canonical inventory and effective Path Item fields.
Chained shared Path Items retain inherited parameters and exact operation examples;
3.2 QUERY uses the actual QUERY method and native body/security rules. Ordinary
additional operations retain their declared method case, shared owners, native
schema/security checks and exact examples. CLI readiness identifies
`nativeOperationRouting` separately, and Core rejects a stale routing policy.
Captures containing additional methods use one request per connection with a
16 KiB method-token bound and five-second initial-token deadline; ordinary
captures keep connection reuse. CONNECT requires tunnel-capable transport and
receives a source-located startup blocker. Remaining tunnel and nested-generation
work is tracked in the [support matrix](implementation/native-openapi-support.md).

Additional-method validation proxies retain actual method/query/body bytes and
separate received response bytes from the decoded native validation view. Gzip,
zlib-wrapped deflate, Brotli and coding chains have bounded decoding; received
compressed bytes are forwarded intact. Unknown coding and exhausted budgets
remain incomplete; malformed coding is operational. These paths use the pinned
Node HTTP client because Fetch normalizes some case-sensitive methods. No source
document, declared specification version, dependency or runtime lock changes.

The native sample owner proves finite authored whole-value examples, defaults,
enum values and modern const/examples values against the original captured
schema before giving Prism a request-owned example view. Bounded nested object
and array construction uses original graph references, exact property/item
suggestions, primitive/bound seeds and merged allOf properties. Every complete
candidate receives the same original whole-schema proof. Exact JSON body bytes
retain source numeric tokens and literal payload keys. Static media examples
keep priority; dynamic bodies choose proved constrained candidates. Status/media
selection still follows the pinned Prism negotiator. Unspecified Swagger response
media uses a JSON generator default without changing the document. Candidate/work
limits and unsupported evaluation stay incomplete; this policy does not establish
arbitrary constraint generation. CLI readiness exposes `nativeGeneration`
separately (`busyapi-native-schema-samples` version 2), and Core rejects an
incompatible policy identity. Construction and proof cancellation cannot return
a cached success after ownership has ended. The [support record](implementation/native-openapi-support.md)
lists exact-number, nested-property, installed CLI and production Linux coverage.

This adapter was inspected against installed Prism **5.15.11** negotiator/mocker
sources, http-spec **7.1.0** OAS2 response transformation, and the pinned MIT
`@stoplight/json-schema-sampler` **0.3.0** traversal implementation. Its reference
context and dynamic object cloning are not native semantic authorities. These
packages, their locks and the packaged runtime remain unchanged.

Mock parameter assertions also use the original captured schemas, with a separate
`nativeParameterValidation` identity in `mock --json`. Query, path and cookie
names retain case; headers ignore case. Empty values retain presence, decimal
tokens remain exact, and percent-encoded data stays distinct from delimiters.
Native collection/style, cookie and content-based inputs use bounded wire
decoders; undefined nested style models and exhausted decoding work return
HTTP 501 with located findings. Primitive inversion considers literal strings,
JSON decimal tokens, lower-case booleans and literal `null`; the authored schema
proves compatibility. Explicit empty values still undergo schema checks, including
when `allowEmptyValue` is true; Swagger query values additionally require that
permission. This is BusyAPI's documented conversion policy under
[OAS 3.0 Appendix B](https://spec.openapis.org/oas/v3.0.4.html#appendix-b-data-type-conversion),
not a guarantee about another server's ambiguous parameter decoding.
Swagger Parameter, Header and recursive Items Objects retain each layer's
`collectionFormat`. Nested collections use the original schema to prove a bounded
wire interpretation, including identical delimiters at adjacent layers. Response
headers use this same engine decoder in direct execution, saved cases and mocks;
repeated CSV fields may combine, while repeated scalar or non-CSV fields remain
explicitly incomplete. Exact decimal leaves never pass through JavaScript numbers.

Outgoing exploded form cookies support arrays and objects. Fields within one
parameter join with `&`; separate cookie declarations join with `; `. Form names
and values are percent encoded, including Unicode and literal percent data.
OpenAPI 3.2 `cookie` style retains its literal encoding policy. Every grouped
name participates in duplicate and authentication-collision checks. Required
empty collections and undefined nested style data are refused before dispatch
with source locations. Non-exploded form-cookie arrays support one item, and
optional empty collections are omitted. Collections requiring a structural comma
are refused under Cookie syntax, as described above.
Advanced multipart, additional-operation routing and generated-candidate qualification remain tracked in the
[support matrix](implementation/native-openapi-support.md).
For 3.0, `required` properties marked readOnly/writeOnly use the request/response
direction rules. In 3.1/3.2 those keywords remain annotations: native schema
evaluation retains `required` assertions and does not strip fields or add optional
annotation-based assertions. This follows the distinction described in
[3.0 Schema Objects](https://spec.openapis.org/oas/v3.0.4.html#schema-object) and
[3.1 annotation validation](https://spec.openapis.org/oas/v3.1.2.html#validating-readonly-and-writeonly).

Runtime body checks decode captured HTTP bytes through the shared engine before
applying the captured schema. `text/plain` uses its Unicode string value. Native
Swagger and OpenAPI 3.0 use an exact one-octet-per-character view for known
binary media, including schemas without redundant type/format hints, so length counts octets; byte values map to U+0000–U+00FF for
enum and pattern assertions. A modern `format: binary` annotation does not select
this legacy interpretation. In 3.1/3.2, raw binary remains outside JSON Schema's
six JSON types. Use an unconstrained schema or appropriate annotations for raw
octets; `type: string` rejects them. Known binary media and binary multipart
leaves retain byte identity through whole-value, nested and item checks, including
conditionals and equality. JSON string assertions do not apply to these finite
binary values. Unknown representations remain explicitly incomplete. Use **Use
binary file** for a complete body or **Add binary file** for a named part. The
[implementation record](implementation/native-openapi-support.md) distinguishes
binary representation coverage and remaining advanced representations.

Swagger response schemas permit `type: file` only at their root. Native checks
validate the captured file entity's byte framing without treating it as JSON or
claiming a decoder for its internal file format. References retain that response
context; ignored reference siblings cannot turn an ordinary schema into a file.
An absent Swagger response schema declares no response content: zero bytes are
valid, including without Content-Type, and nonempty bodies receive a located
violation. Direct requests, saved cases and native mock proxies use the same
captured response policy. See [Swagger §6.4.12](https://spec.openapis.org/oas/v2.0.html#response-object).

Finite JSONL/NDJSON, JSON text sequences and server-sent events map to ordered
arrays. In 3.2, `schema` checks the complete array and `itemSchema` checks each
item separately, including parameter/header content and saved cases. Numeric
tokens retain their authored precision. Line-oriented parsing accepts a final
record without LF and rejects empty lines and lone CR separators. JSON sequences
ignore consecutive record separators and require trailing whitespace for scalar
records to exclude truncation. SSE applies UTF-8 replacement decoding, joins data
lines, ignores comments/unknown fields, retains valid fields from dispatched
blocks and discards an unfinished final event. Retry values stay exact integers.
The event-object policy includes only fields supplied in each dispatched block;
it does not fabricate absent event/id/retry fields. An explicitly empty event
type becomes `message`, and exactly one leading SSE byte order mark is removed. Bounded work, incomplete
receipt and unimplemented codecs remain incomplete. These finite checks do not
establish incremental evaluation of an unbounded stream.

OpenAPI 3.2 serialized multipart requests and responses can map ordered JSON/text/binary
parts to arrays, including nested multipart, whole-array `schema` and independent
`itemSchema` checks. `prefixEncoding` selects each corresponding position and
`itemEncoding` applies to the remainder; unused encoding entries are ignored.
For 3.0/3.1 named multipart responses, native decoding uses each actual part's
Content-Type, defaulting to text/plain when absent. Request-only Encoding and
its inferred request defaults do not restrict those response headers. The
captured schema still checks every decoded value. Request Encoding restrictions
and 3.2 response Encoding keep their own rules. This response mapping policy
follows [3.0 Media Types](https://spec.openapis.org/oas/v3.0.4.html#media-type-object)
and [RFC 7578 §4.4](https://www.rfc-editor.org/rfc/rfc7578#section-4.4).
Ordered form-data retains one named object per part. Exact numeric text, empty
values, declared part headers and transfer encodings use the captured graph and
the existing native evaluator. Decoding is bounded to eight nested levels and
2,048 total parts. Unsupported media, ambiguous annotations and incomplete
resources produce incomplete checks. Typed positional/nested request generation
and incremental streams remain incomplete; finite decoding does not establish them.

Multipart framing follows [RFC 2046 §5.1.1](https://www.rfc-editor.org/rfc/rfc2046#section-5.1.1):
a body has at least one part, and a complete boundary prefix is reserved at line
starts. A nested boundary cannot begin with its enclosing boundary. A closing
marker before any part is invalid; an explicitly empty field or file remains a
part. Native generation refuses an empty multipart draft before dispatch, with
an actionable error. Caller-supplied raw entities retain their exact bytes and
receive framing findings. Text containing a boundary away from line starts, or
a different boundary, remains payload data. These semantics use evaluator
revision **1.18.0+21**; older readiness captures cannot be reused.

OpenAPI 3.0/3.1 use the same named mapping for generic multipart types when
parts carry `Content-Disposition: form-data` and a name. This is the policy
permitted by [3.0 §4.7.15.3](https://spec.openapis.org/oas/v3.0.4.html#encoding-multipart-media-types)
and [3.1 §4.8.15.3](https://spec.openapis.org/oas/v3.1.2.html#encoding-multipart-media-types).
The engine supplies the binding to native request controls and CLI cases;
generated and raw requests retain the declared family. Generic MIME text without
a charset uses US-ASCII; form-data retains its separate UTF-8 policy. Declared
simple part headers use their original Header Object schemas, references and
exact numeric values. Unnamed older-family parts have no inferred positional
mapping. Content-based or ambiguous MIME headers, additional codecs and advanced
representations still report incomplete checks. See the [support matrix](implementation/native-openapi-support.md) for
representation coverage and verification status.

Form execution uses the captured schema to interpret numeric and boolean fields,
repeated array items and JSON object values. Explicit URL-encoded styles share
the parameter serializer. Multipart style fields are ignored in 3.0 and applied
in 3.1/3.2; content defaults come from the engine's owning-family projection.
Literal custom-media parts retain their bytes and report incomplete schema
evaluation when their typed content cannot be decoded. Literal fields remain
strings when the schema also permits strings. Untyped repeated fields use an
array; content-based arrays use repeated entries. These are explicit input
policies, not guarantees about how a particular server decodes ambiguous forms.

Raw serialized form bodies and form-valued parameter/header content are decoded
under their original captured declaration. Repeated fields retain order; exact
numbers and JSON part values retain their numeric tokens. Declared string fields
remain literal; numeric, boolean and null fields use strict JSON scalar spelling.
Undeclared URL-encoded fields remain strings, so the original schema can evaluate
additional properties. MIME decoding retains original response bytes separately,
checks framing and transfer encodings, and reports unavailable part decoders as
incomplete. MIME base64 ignores nonalphabet transport characters and uses its
significant encoded spelling for an encoded-string schema; other supported
encodings retain their lexical spelling. RFC 7578's ignored extra part headers
produce advisory findings. Positional, nested and ambiguous conditional binding
remain incomplete. OpenAPI 3.0 multipart request content requires a schema;
response content and the modern families retain their own rules.

**Use an exact JSON value** accepts an object for form or multipart data without
passing through literal `name=value` rows. Saved contract cases with object
values use that same headless path, including in the installed CLI. Explicit
JSON scalar kinds and numeric lexemes are retained. Empty collections that emit
no fields are omitted from outgoing presence checks. File input remains explicit;
a string in a saved case is never permission to read a file.

The form-part controls provide explicit Content-Type selection for declared
lists and media ranges. A concrete choice must match a declared range and its
parameters. File overrides allow different types for files under the same field;
picker MIME metadata does not satisfy a required choice. No payload sniffing is
used. Environment drafts retain selections, and preparation checks them against
the captured operation again after contract edits. Literal field rows retain
their interleaving; typed JSON retains property and array order.
Repeated media parameters are structurally accepted but execution refuses their
ambiguous interpretation as unsupported; it does not choose a first/last value.

Object-valued saved cases use `body.partMediaTypes` for shared field choices:

```yaml
body:
  mediaType: multipart/form-data
  value:
    metadata: {id: 9007199254740993}
  partMediaTypes:
    metadata: application/json
```

The field applies to native form data, including URL-encoded content. It never
grants file access or changes a literal whole-body representation.

Named multipart parts apply 3.0 `format: byte` and modern `contentEncoding`
through the shared graph. Encoded string inputs retain their spelling; selected
files contain raw bytes and receive the declared transfer encoding. MIME base64
adds required line folding. The native codecs cover binary/identity, 7bit/8bit,
base64/base64url, base16, base32/base32hex and quoted-printable. Transfer-header
references and constraints are evaluated under the owning family. An explicit
literal example selects its token; otherwise valid declared defaults/enums are
preferred, then implemented tokens starting with binary. A token is never used
without satisfying that header's schema. Undefined implicit/header conflicts
are refused; unavailable codecs and ambiguous conditional annotations report
incomplete serialization. These choices are an input policy, not a server
interoperability guarantee. Typed positional and nested request generation still
requires implementation and is reported as a limitation before sending; complete
serialized bodies use the runtime decoding path described above.

Native 3.0 `format: binary` multipart fields and files use the same octet-string
instance policy as raw binary bodies. Entered text supplies its UTF-8 bytes;
selected files supply their immutable captured bytes. Length, enum and pattern
checks apply before MIME transfer encoding. Mixed field/file arrays retain actual
part order, and adjacent exact numeric values survive reconstruction. Large
conversions run off the UI isolate and remain subject to the instance-size limit.
Schema-format and transfer-header provenance remain separate. Modern format
annotations do not opt into this 3.0 mapping.

Migration checks effective form encodings as well as media names. It removes
ignored 3.0 multipart style fields before they could become active in 3.1.
Swagger multipart arrays with a CSV/space/pipe separator are blocked for a 3.0
target, whose repeated-part encoding cannot preserve those delimiters.
Upgrading a 3.0 document with an ignored request-body declaration requires an
explicit decision to omit that declaration from the migrated copy. Otherwise a
modern target would activate it. The original declaration, examples and source
remain intact in the original files. Migration to 3.0 blocks an active body on a
method whose target declaration would be ignored, including callback operations.
A composed Swagger 2.0 upgrade to 3.1/3.2 retains the originally active body.

Shared Swagger body parameters and responses retain each operation's effective
`consumes`/`produces` through media-specific target wrappers and one source-owned
schema. External fragments, chained references, exact media examples and
extensions remain captured. Local references use the migrated retrieval location
and reopen after relocation without a project manifest. The generated project
also retains file mappings and declared resource identities; its cold-reopen
proof uses the same sorted mapping order as Core. Nested Swagger header delimiter
hierarchies receive precise source-located conversion blockers. See the
[migration guide](migration.md) and native support matrix for qualified directions
and remaining mappings.

Migration preserves untouched YAML anchors and aliases, including exact numeric
payloads and unchanged canonical reference/identity strings. Static locator
retention is proved against the mapped graph and the delivered cold-reopen
identity map. Changes to shared syntax remain source-located blockers, including
patch-only declarations and empty anchored destinations. These cases use migration
producer **3**; Core rejects previous producer responses before publication.

Contract-case JSON reports include `dispatched` and `operationalFailure`. Coverage
counts operation occurrences handed to the HTTP transport; refused preparation
remains untested. The retained `executedOperations` field counts these dispatched
attempts, which can still fail during connection or receipt. Desktop results show
“Request not sent” or “Request dispatched” alongside the case outcome.

## External tools

OpenAPI Generator **7.26.0** runs as the official local JAR with the packaged
Temurin **17.0.20+8** Linux x64 JRE. Artifact digests and the JRE inventory are
locked in `tools/generator/`. Generator choices come from the upstream CLIENT
catalog and options from `config-help --format yamlsample`. Specification
validation stays enabled; generated code and package installation never run
inside BusyAPI.

The pinned generator rejects OpenAPI 3.2 declarations and some 3.1 constructs,
including boolean Components schemas and compound `$defs` references. A failed
or incomplete conversion produces no published output. BusyAPI preserves the
contract rather than disabling upstream validation. See the
[7.26.0 release](https://github.com/OpenAPITools/openapi-generator/releases/tag/v7.26.0)
and [customization documentation](https://openapi-generator.tech/docs/customization/).

Generator conversion coverage uses upstream `debugOperations` metadata;
canonical contracts never round-trip through those objects. Missing path/method
conversion prevents publication, and callback/webhook coverage remains incomplete.
A generator-specific Landlock ABI **3** and libseccomp launcher permits JRE/JAR
reads and private output-stage writes while denying external sockets and other
filesystem access.

`tools/prepare_generator.py --provision` acquires locked inputs explicitly.
Ordinary preparation reuses verified assets offline. Explicit `--jar` and
`--jre-archive` inputs must match the locks. CMake installs the verified runtime
and notices in each build mode; package and Snap checks verify its inventory.

`BUSYAPI_DISTRIBUTION=snap tools/build_linux.sh` keeps normal CMake and common installed-asset checks but omits standalone system-library copying. A previously assembled standalone inventory is refused in platform mode. The recipe's GNOME extension supplies libhandy and the complete WebKitGTK 4.1 platform, while core24 supplies libseccomp; only WebKit's missing development headers are added to the build packages. The ordinary Snap prime step verifies the exact generated GNOME/GPU launcher scripts and installs their original GPL-3.0 licence, templates/Makefiles and generation notice. `tools.test_snap_extension_notices` covers original/generated correspondence, repeatability, collisions, changed inputs and linked paths. The explicit `snap/hooks/configure` terminal endpoint is the same `#!/bin/true` placeholder that Snapcraft supplies for extension-only hooks; it does not replace or bypass GNOME's font-cache command chain. Prime checks require its staged executable, and `python3 -m tools.check_snap_package --prime UNPACKED_IMAGE --packaged` additionally requires the actual `meta/hooks/configure` handoff, namespaced GUI command and packaged icon. Regression tests exercise post-cache exec and missing/non-executable/linked/unexpected endpoints and desktop assets. These build checks do not substitute for actual strict-confined execution.

Prepared-prime `snapcraft pack PRIME` does not run the source project's asset-mediation lifecycle. In addition to upstream hook provisioning, use Snapcraft **9.1.4**'s unchanged [`DesktopFile` mediation](https://github.com/canonical/snapcraft/blob/9.1.4/snapcraft/parts/desktop_file.py) for the installed standalone desktop source, rather than copying it directly into `meta/gui`. The standalone source deliberately retains `Exec=busyapi-desktop %F`; the Snap entry must contain `Exec=busyapi.busyapi-desktop %F` and a `${SNAP}`-relative packaged icon. This follows the [built Snap desktop-entry contract](https://snapcraft.io/docs/reference/development/yaml-schemas/the-snap-format/#desktop-files). A file can pass `desktop-file-validate` yet lose an invalid Exec during snapd's installation sanitization and become unlaunchable. Verify the actual unpacked metadata and later the exported system-menu entry, not just the standalone desktop file or successful direct CLI launch. Do not patch the system's exported desktop file or use a user-local override to hide a package defect.

Snap launcher materials are pinned to Snapcraft **9.1.4** in
`tools/snap_extensions.lock.json`. Original and generated bytes are checked
before packaging. `BUSYAPI_SNAP_EXTENSIONS` selects an explicit original
extension directory when the builder uses a different location.

Native isolation profile **2** is tested through the Node/kernel boundary.
`tools/test_policy_isolation.py --capability-aware` checks unavailable-capability
refusal before running positive syscall, process-lifetime and governance cases.
An unsupported environment returns **2** rather than recording skipped checks as
passes. The procfs inspection inode is pinned across exec with a validated
`O_PATH` descriptor, consumed and closed before project code executes.

`tools/test_policy_kernel.py` accepts an explicit kernel image and digest, a
pinned Node executable and a new work directory for networkless KVM tests.
It requires QEMU/KVM, static BusyBox and cpio as development inputs; they are
not application runtime dependencies. Guest results do not establish native
application or strict-Snap acceptance.

The Snapcraft **9.1.4** `gnome` extension supplies the GNOME 46 GTK3/WebKitGTK
**4.1** platform and helper-process layout; core24 supplies libseccomp **2.5.5**.
The recipe adds WebKit development headers at build time rather than privately
copying a partial WebKit runtime. Strict-confinement acceptance remains separate
from successful package assembly.

Response exports stream through that existing private-staging/no-clobber file writer, as do sanitized history bytes. Staged data uses `RandomAccessFile.flush` before atomic publication; `IOSink.flush` alone does not establish OS-level durability. `BUSYAPI_DART=/path/to/pinned/dart python3 -m unittest tools.test_publication_sync` observes actual staged-file `fsync` before `renameat2` through byte publication and the response-export API. Its `strace` prerequisite is build/test-only (declared in Linux CI), never an application asset. Partial-stream, collision, cancellation and displaced-file preservation remain separate production-boundary regressions.

## Documentation adapters

The optional native documentation module is installed by CMake in Debug, Profile
and Release and loaded through a versioned local function table. Missing runtime
support leaves ordinary authoring available. It requires a complete GTK3-compatible
WebKitGTK **4.1** runtime, including helper processes; packaging rejects a partial
private WebKit/JavaScriptCore copy.

Redoc CE **3.0.1** and Swagger UI **5.33.2** with client **3.38.2** have separate
build-input locks. Explicit `tools/build_documentation_assets.sh` preparation
produces offline assets and notices. CMake installs compiled assets rather than
npm trees, browser harnesses or CLI probes. Native read-only windows and the
`redoc`/`swagger` export presets use the same captured graph and safe publication.

`swagger_content.mjs` uses supported component hooks and exact Reference values
for schema constraints, inherited parameters and additional operations. Its
browser-module build uses upstream React/React DOM **18.3.1**. Exact imported and
embedded code/notice inventories are checked by `swagger_licenses.mjs`.

The Redoc adapter uses the **3.0.1** `prepareApiDocs`, `skipBundle`, `Redoc`,
`items` and `markdownAdapter` APIs. A private display projection preserves authored
values and source locations without changing canonical schemas. Standalone
branding loading, request actions and generated examples are excluded from the
read-only view; descriptions cannot select executable components.

The canonical graph retains each containing OpenAPI document's family and
schema-dialect default independently of the entry-description namespace used
for implicit names. Unversioned fragments inherit their captured occurrence
context. Bundling refuses version-changing object substitutions.

Server/tag relationship checks use source-owned version contexts, template
grammar, enum/default membership, exact tag names and entry namespaces.
`busyapi:recommended` reports advisory unmapped or unused Server variables
separately from specification errors.

New-file component extraction composes the existing CST/graph proofs and creates no OpenAPI wrapper. Swagger 2.0 parameters/responses use a named unversioned fragment and direct usage-site reference; the global definitions maps do not permit forwarding Reference Objects. Definition moves repair their captured consumers and remove the old binding. Other supported families retain their legal aliases. Native metadata, Source choices and graph traversal use the same source-position rule. Worker cases cover selected-version reusable families, referenced fragment sources, multi-root closure, boolean/recursive schemas, exact examples, legal named bindings and ambiguous-root refusal. Core tests cover a single coupled virtual transaction, full undo/redo, byte-exact save/reopen, unsaved shared fragments, stale inputs, occupied destinations and malformed creation replies. Real SIGKILL tests stop before publication and in both fragment/root receipt gaps, preserve newer versions of either member and recover without speculative writes. Native-style widget controls cover sequential capture, recovered filename drafts, complete review/cancel, retired callbacks, resource selection, folds and reading state. These do not substitute for the complete actual GTK refactoring scenario or native input/performance qualification.

Server-template bundling retains absolute templates (including variable ports), scheme-relative authorities and relative-path substitutions without pre-normalizing away variable-dependent dot segments. Finite enums can prove that an initial variable has one URL-reference form; literal braces inside enum values are data, not recursively substituted templates. Independent before/after URL expectations exercise both families. An unrestricted initial variable or an enum mixing reference forms can make one relocated template unable to retain its original retrieval context; this returns explicit `bundle.server.template-context`, not a guessed default or an altered declaration. Native Reference HTML remains independent and can document that original contract without bundling it.

The `native-reference` preset uses shared Reference projection and
`busyapi build-docs`. It documents the original captured contract independently
of derived single-file bundling. Source-linked actions belong to the native
workspace; standalone HTML retains portable source provenance.

Native descriptions and headless HTML use Dart `markdown` **7.3.1**
(BSD-3-Clause) for display-only CommonMark parsing. It has no resolver, network
service or executable project extensions. HTML and images cannot initiate resource
loads. Required source, license and character-table notices are installed through
the Dart notice target; see [third-party distribution](third-party.md).

## Validation and governance tools

Production governance uses Spectral core **1.24.0**, functions **1.11.0**,
formats **1.9.0** and rulesets **1.23.0**. The programmatic adapter receives
canonical values, graph-only resolution and original source maps. It does not
use the development CLI's resolver. Opening or inspecting a contract executes
no project policy code.

Executable policy functions, rulesets and filters require captured-code review
and the restricted native process. Computed dependencies, unsupported module
formats and unprovable exact numeric reads remain incomplete. Missing approval,
unavailable isolation, cancellation and worker failure cannot become a clean
policy result.

Pinned `truthy`/`falsy` checks use exact zero/nonzero values from source lexemes
when JavaScript numbers would underflow. Exact numeric admission also covers
`length` bounds and custom function reads. Unsupported precision produces an
incomplete result rather than rounded comparisons.

The derived bundler uses the canonical graph and exact CST reader. It preserves
literal data separately from semantic schema occurrences, nested `$id` resources,
static/dynamic references and exact numbers. Recursive references are retained.
Unproved placement or dialect boundaries produce an explicit refusal; the
original resource-package format remains a separate output choice.

This is a documented interpretation of explicitly requested target contexts. [JSON Schema 2020-12 Core §9.4.2](https://json-schema.org/draft/2020-12/json-schema-core#section-9.4.2) leaves references into known non-schema data/unknown structures undefined; a `$ref` merely present in examples/extensions is still only data. BusyAPI does not claim that other processors must accept that interpretation. The selected graph/evaluator and derived artifact must agree on it, preserving the ordinary data occurrence. Compound-resource identities and dialect boundaries follow [Core §9.3](https://json-schema.org/draft/2020-12/json-schema-core#section-9.3); these interpretation fixtures are not substituted for standard positive/negative schema conformance cases.

Resource packages retain exact original resource bytes, URI mappings, provenance
and the independent AOT loader. The loader accepts only the package's approved
resource set after relocation and rejects changed content rather than retrieving
the original project. Package output uses the same reviewed directory-publication
boundary as other derived outputs.

Hyperjump JSON Schema **1.18.0** and Browser **1.6.0** provide modern evaluation
through pinned exported experimental APIs and dated meta-schemas. Exact numeric
handlers retain CST lexemes. Unsupported dialects, vocabularies and work bounds
are explicit incomplete results. The selected upstream fixtures are described in
[their fixture README](../fixtures/json_schema_2020_12/README.md); they do not
represent the complete JSON Schema suite.

Production parsing and structural checking use `yaml` **2.9.0**,
`jsonc-parser` **3.3.1** and Ajv **8.20.0** with Node **24.15.0**. The committed
package lock owns dependency identities. Structural validation is supplemented
by family-specific normative checks and does not imply complete conformance.

Static security advice is advisory and separate from governance and runtime
authorization. Token-shape hints follow
[GitHub token families](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/about-authentication-to-github)
and [AWS key identifiers](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetAccessKeyInfo.html).
A matching prefix does not prove that a credential is valid or leaked.

## Development probes

`tools/probes/run.py` and the [renderer/schema probes](../tools/probes/m2/README.md)
compare locked upstream candidates against controlled fixtures. They are
separate from production adapters and are never invoked by opening a project.
Their dependency locks, provisioning and outputs do not become runtime assets.

Redocly CLI **2.62.1/2.64.0** and Ref Parser **16.0.5** probes expose unsupported
bundling behavior for literal payload references, external values, exact numbers
or nested resource bases. They are not production bundlers. BusyAPI's canonical
graph and CST own derived output; candidate success on a minimal fixture does
not establish compatibility.

## Execution tools

Production mocks use Prism core/http **5.15.11**, `@stoplight/http-spec`
**7.1.0** and Node **24.15.0** through a fixed packaged entry point. The adapter
supplies captured operations through Prism's public APIs and preserves authored
example bytes through a CST overlay. Ordinary mock mode binds loopback and never
forwards upstream. Validation proxying is a separate explicit action. Complete
stateful behavior and exhaustive dynamic-reference support are not claimed.

oasdiff **1.33.0** is a checksum-verified Linux amd64 executable. It receives
separately coherent captured revisions and classifies compatibility while retaining
source review. Dynamic references and reusable Component Path Items remain
unclassified where the pinned tool cannot prove coverage. An empty result with
incomplete loading is not compatibility proof.

Dart **3.13.4** normalizes HTTP method capitalization internally. BusyAPI's dedicated connection adapter preserves OAS 3.2 additional-operation tokens on the wire, including lowercase/mixed-case methods, without changing URI, header or body bytes. It retains native TLS trust, hostname and client-certificate checks and owns cancellation during the handshake. Exact HTTP method identity remains case-sensitive.

Request credential rules are shared by desktop and CLI. Basic credentials use
UTF-8 as entered, preserve password colons, and reject ASCII control characters
before Base64 encoding. Bearer, OAuth and manual OpenID tokens must fit the
[RFC 6750 field grammar](https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1).
An explicitly supplied empty Basic password or API key retains its value; a
missing credential remains unavailable. Other credential kinds apply their own
rules. Invalid values fail before network dispatch, and previews acquire no
credentials.

The native editor permits explicit empty submission only for the selected
consumer rules. Default secret-store writes still require a nonempty value;
allowed empty values remain distinct from missing entries through session
storage and the persistent bridge. Scoped UUID keys, the 64 KiB UTF-8 limit,
NUL/scalar checks, stale-write ownership and private credential handling remain
enforced. Empty values do not become text-replacement patterns when diagnostics
are redacted, preserving source links.

HTTP TRACE refuses nonempty content, authorization, cookies and configured HTTP credentials before connecting; it does not silently remove them. Preview and Send retain the entered draft for correction. Mutual TLS remains available because it adds no HTTP credential field. A custom lowercase `trace` remains a different method. These rules follow [RFC 9110 §§9.1,9.3.8](https://www.rfc-editor.org/rfc/rfc9110.html); they apply in the shared desktop/CLI request path. See the [support matrix](implementation/native-openapi-support.md) for coverage and verification status.

OpenAPI 3.x Security Scheme references use the canonical graph's security context,
including chained external definitions and their physical source locations.
OpenID Connect schemes retain `openIdConnectUrl` in captured authentication
identity. Reviewed setup can configure an explicit OAuth bearer access token
through `accessTokenRef`; the shared request path sends it in the Authorization
header, following [RFC 6750 §2.1](https://www.rfc-editor.org/rfc/rfc6750.html#section-2.1).
The CLI accepts the same credential through `--secrets-stdin`. A changed provider
declaration requires selection against the new capture while retaining entered
drafts. Provider metadata retrieval and sign-in remain separately unqualified;
ordinary opening, preparation and manual-token execution make no discovery request.

In Design, select a requirement's scope or role list and use **Change security
binding…** to review a different scheme. The existing list is retained; choices
exclude schemes that cannot represent it. Named bindings work in every supported
family. OpenAPI 3.2 also offers **Add security scheme by URI…** on alternative and
combined requirement lists, using already approved resources. Source key completion
offers the same proved names and applicable URIs. Lists carry OAuth/OpenID scopes;
other schemes require empty lists before 3.2, which can carry roles. An intentional binding change
requires its own authentication configuration and does not copy credentials or
environment settings. Definition rename remains a separate action.

Swagger 2.0 reusable schema, parameter, response and security-scheme names follow
its native named-map rules, including Unicode and empty names. **Use an empty
name** makes empty-name creation explicit in Design; navigation and native
documentation label it visibly. OpenAPI 3.x Components retain their restricted
name syntax. Rename and extraction repair captured references through the graph.
An extraction's semantic name and separately reviewed filename are independent;
names containing path characters receive an editable safe filename suggestion.

In OpenAPI 3.1 and 3.2, authored `$defs` members offer **Rename schema
definition**. Their names follow JSON member rules, including empty names and
Unicode, independently of Components names. The review repairs captured schema
references while retaining resource identities, anchors and literal example
data. Cancel, Undo/Redo, recovered forms and coupled multi-file save use the
existing transaction owner. Unsupported dialects and ambiguous alias ownership
produce a located refusal. Shared schema resources retain their enclosing
`$id` and dialect context even when an operation first references a descendant.

Operation responses offer **Rename response status…** with reviewed reference
repairs, Undo/Redo and the document family's status rules. Swagger 2.0 accepts
`default` or codes 100–599; OpenAPI 3.x also accepts uppercase ranges such as
`2XX`. Invalid numeric codes produce source-located findings. Reusable response
names and status-looking keys inside example payloads keep their own rules.

Security-scheme rename and file moves use captured graph bindings to repair
requirement names and 3.2 URI keys. Reviewed changes include exact aliases of
configured environment credential references; old bindings remain available for
other consumers. Different settings at the destination binding block the plan.
A new alias that would also configure an unchanged binding is refused; resolve
the environment settings explicitly or choose another spelling before retrying.
No credentials are read during refactoring. Required source/configuration repairs
save and recover together when either file is selected; unrelated working files
retain their independent save scope. Publication retains per-file receipts and
external-change checks, including a published peer of an outstanding repair.
This does not make multi-file filesystem replacement globally atomic. See the
[support matrix](implementation/native-openapi-support.md) for qualification
and outstanding URI copy/inline and migration coverage.

Desktop persistence uses libsecret **0.21.4** through a BusyAPI-owned native channel and schema. The strict Snap exposes `password-manager-service` but does not assume it is connected; locked, missing, declined, and disconnected paths remain visible session-only operation with no file fallback. `network` and `network-bind` are limited to deliberate request/mock/OAuth/Git execution. Document navigation and messages retain the independent WebKit resource/network denials described above.

Swagger 2.0 native-family implementation and qualification are tracked with
OpenAPI 3.0 in [the support matrix](implementation/native-openapi-support.md).
Creation accepts `--openapi 2.0` and writes `swagger: "2.0"`; ordinary open,
edit, check, bundle and native documentation do not convert the document.
External renderer/generator/comparator qualification remains separate.

`busyapi migrate INPUT --target VERSION --output NEW_DIRECTORY --review --json`
returns the captured review and its identity without publishing. After review,
repeat with `--apply REVIEW_SHA256`; the source, target and destination must
still match. Listed decisions use `--decision ID=CHOICE`. A stale review or
any unresolved blocker prevents publication. The desktop exposes the same
operation as **Migrate specification…**. Conversion coverage is deliberately
reported separately from native editing support in the implementation matrix.
