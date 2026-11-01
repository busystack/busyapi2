# Native OpenAPI support

Complete native acceptance remains incomplete. Native authoring and maintenance
subsets for Swagger 2.0 and OpenAPI 3.0.x, 3.1.x and 3.2.x use the shared contract
engine, canonical graph and Core. Standard YAML/JSON remain authoritative.

The [feature-branch support matrix](https://github.com/busystack/busyapi/blob/feature/native-openapi-support/docs/implementation/native-openapi-support.md)
identifies newer unverified work and remaining requirements. Those source changes
are not incorporated into this release by this documentation cleanup.

Required work includes shared/directional migrations, advanced representations,
CONNECT and response generation, URI maintenance and detailed 3.2 semantics.
Unsupported or incomplete evaluation must not be reported as validation success.
Missing implementation is not an unrepresentable conversion.

Acceptance requires complete engine/Core suites, packaged CLI and native
application workflows. Prepared regressions are not passes. Private development
records and machine diagnostics are kept outside the repository.

Normative authorities: [OpenAPI](https://spec.openapis.org/oas/),
[JSON Schema](https://json-schema.org/draft/2020-12/json-schema-core),
[RFC 3986](https://www.rfc-editor.org/rfc/rfc3986) and
[RFC 6901](https://www.rfc-editor.org/rfc/rfc6901).
