# BusyAPI

BusyAPI is a workspace for authoring, inspecting, validating, and working with OpenAPI contracts. YAML and JSON files remain the canonical source. **Design**, **Source**, and **Reference** work from the same current document buffers; edits are published to disk only when saved.

BusyAPI provides native editing for **Swagger 2.0 and OpenAPI 3.0.x, 3.1.x and 3.2.x**. Documents retain their declared family and are not silently upgraded or converted. See [Tool support](docs/tool-support.md) and the [current verification matrix](docs/implementation/native-openapi-support.md) for workflow qualification and remaining work.

## Features

### Authoring and navigation

- **Design:** Native editors for operations, parameters, request and response bodies, security, servers, schemas, examples, components, callbacks, and webhooks. Large values open in focused editors; edits preserve unaffected source formatting and data.
- **Source:** YAML/JSON editing with syntax highlighting, completion, field help, folding, search, definition and usage navigation, diagnostics, and reviewed quick fixes. Available fixes are specific and limited; they do not invent missing contract content.
- **Reference:** Read-only, source-linked API and schema reference, including effective operation inheritance, definitions, uses, and physical source ownership. Reference does not send requests.
- **Migration:** Review a specification conversion and create a separate copy through the desktop or `busyapi migrate`. Unsupported mappings are reported before publication; see the verification matrix for current coverage.
- **Search:** Document and project text search with reviewed replacement, plus semantic search across configured roots. Searches include unsaved buffers and report incomplete indexes.

### Projects and document integrity

- Open an individual YAML/JSON contract with **Open File…**, or open a folder containing `busyapi.yaml` with **Open Folder…**. Existing contracts can be opened without creating a manifest; a standalone file has its own containing-directory dependency scope.
- Work with multiple named roots and shared resources. Local dependencies stay within approved contexts; additional directories and URI-to-file mappings require explicit configuration or session approval. Remote references are not automatically fetched.
- Stage new files, file moves and deletions, component extraction/inlining/renaming, definition moves, property changes, and operation/path relocation through impact reviews. Related source and reference changes form undoable transactions; filesystem changes are published on Save.
- Remove a root registration independently of deleting its file. Operations that cannot safely preserve references, schema identities, YAML ownership, or retrieval context are refused rather than silently rewritten.
- Preserve unaffected authored source, including comments, quoting, aliases, line endings, and numeric values. Unsaved drafts, external file conflicts, and interrupted publications have explicit recovery paths; recovered content does not overwrite newer disk files automatically.

### Validation and governance

- Validate OpenAPI structure, references and JSON Schema dialects, with source-linked findings in **Problems** and Source.
- Use the built-in policy checks or Spectral rulesets, including the bundled `spectral:oas` preset. Executable custom policy rules require explicit one-run review and an available restricted native execution environment; they are never run merely by opening a project.
- Review static security-design advice separately from contract validity. Validation, governance, example/schema compatibility, and runtime conformance are distinct results; incomplete checks are not reported as clean.
- Export check/lint diagnostics as **SARIF 2.1.0** and selected contract-test results as **JUnit XML** for CI.

### API execution, testing, and Git

- **Try:** Prepare and send requests for a selected operation, including parameters, headers, authentication (API key, Basic, bearer, OAuth 2), request bodies, custom CAs/mTLS, and response inspection. Requests are sent only when explicitly started. Saving a redacted response as an example is a separate reviewed source edit.
- **Contract tests:** Run explicitly selected declarative cases with environments and assertions. Results distinguish executed and untested operations; a subset is not presented as full API coverage.
- **Mock:** Start a local Prism-backed mock, or explicitly start a validation proxy against a configured upstream target. Ordinary mock requests are not forwarded upstream.
- **Git:** Inspect changes and history, stage/unstage, commit, manage branches, and explicitly fetch, pull, or push. Source buffers, disk working tree, and index remain distinct. BusyAPI does not automatically stash, reset, force-push, or execute repository hooks.
- **Semantic diff:** Compare an explicit Git revision or merge base using the bundled `oasdiff` tooling while retaining the source diff and coverage limitations.

### Import and output

- **Import Project…:** Acquire a reviewed copy from a file, directory, HTTP(S) contract, or Git repository. **Open** edits the original in place; **Import** creates a new destination. Imported contract bytes and relative resource identities are preserved where possible. Additional network resources require approval and unresolved dependencies remain visible; imported repositories do not run hooks or submodules.
- **Bundle API…:** Produce either a derived single-file OpenAPI JSON bundle or an **original resource package** with the original documents, URI mapping, provenance, and a Linux amd64 headless loader. Outputs do not replace canonical source files.
- **Build documentation…:** Generate offline `native-reference`, Swagger UI, or Redoc documentation. Native Reference is built into the workspace; supplementary Swagger/Redoc windows need a complete GTK3/WebKitGTK 4.1 runtime. Headless exports and native Reference do not need to open WebKit. Renderer-specific compatibility limitations are documented separately.
- **Generate Client…:** Use the packaged OpenAPI Generator 7.26.0 and private Java runtime to produce a reviewed client output. Generation never edits the API contract or executes generated code. Some OpenAPI 3.2 and complex 3.1 constructs are not supported by the upstream generator; incompatible runs fail without publishing partial output.

Generated outputs are published to new destinations by default. Replacing an existing BusyAPI-owned output requires an explicit review of its unchanged ownership receipt; hand-modified or unrelated directories are not silently overwritten.

## Project configuration

A project manifest, `busyapi.yaml`, identifies its OpenAPI roots and optional project settings. A minimal multi-resource example is:

```yaml
version: 1
roots:
  - name: public
    path: openapi.yaml
resourceMappings:
  "https://schemas.example/model": cached/model.yaml
```

`resourceMappings` associates a reference URI with an approved local file; it does not download the URI or grant access outside approved directories. Omit it when no mapping is needed. Projects can also configure environments, authentication references, TLS files, declarative tests, mocking, and policy rulesets. Secrets are stored using the scoped desktop Secret Service bridge or supplied explicitly for a headless test; plaintext secret values do not belong in the manifest.

The GUI works with current unsaved buffers. CLI commands operate on saved inputs. This distinction also applies to bundle, documentation, tests, and other operations that capture a source snapshot. The desktop stores persistent authentication values through its Secret Service bridge; headless tests can receive explicitly provided secret references over standard input without writing the values to configuration.

## Command-line interface

The Linux bundle includes `busyapi-desktop` and the independent compiled `busyapi` CLI. These examples show the main commands; use `busyapi --help` and each command's help for available options.

```sh
# Create a project and check its saved contracts.
busyapi init ./my-api --title 'My API' --api-version 1.0.0 --openapi 3.2.1 --format yaml
busyapi check ./my-api --json
busyapi lint ./my-api --ruleset spectral:oas --json

# Work with project resources and publish derived outputs.
busyapi import ./incoming/openapi.yaml --kind file --output ./imported-api --json
busyapi bundle ./my-api --output ./derived-api --json
busyapi bundle ./my-api --format resource-package --output ./portable-resources --json
busyapi build-docs ./my-api --output './offline docs' --preset native-reference --json

# API tooling and version comparison.
busyapi diff ./my-api --base HEAD~1 --fail-on breaking --json
busyapi generate --list-generators --json
busyapi generate ./my-api --root openapi.yaml --generator typescript-fetch --output ./client --json
busyapi mock ./my-api --port 0 --json
busyapi test ./my-api --case smoke --environment local --json

# Reports for continuous integration.
busyapi check ./my-api --sarif check.sarif --json
busyapi test ./my-api --case smoke --environment local --junit tests.xml --json
```

Other supported options include `--root` for an explicitly selected root, `--map-resource` and `--allow-directory` for approved reference contexts, `--format resource-package` for multi-file output, and `--proxy` for explicitly enabled mock proxying. URL and Git imports are also available. The [GitHub Actions](examples/ci/github-actions.yml) and [GitLab CI](examples/ci/gitlab-ci.yml) examples demonstrate CI use.

For `check` and `lint`, exit codes have these meanings:

| Code | Meaning |
| --- | --- |
| `0` | Complete and clean |
| `1` | Contract findings or syntax failure |
| `2` | Incomplete or unsupported analysis |
| `3` | Operational or configuration failure |

For `diff`, code `1` means the chosen failure threshold was met; for `test`, it means a selected case failed. These commands retain codes `2` and `3` for incomplete execution and operational errors. Structured machine output goes to stdout and operational diagnostics to stderr.

## Build on Linux

### Requirements

- **Flutter 3.47.5 / Dart 3.13.4**, **Node 24.15.0** (complete matching distribution, including npm), and **Python 3.11+**.
- GTK 3, libhandy, libsecret, and GTK3-compatible **WebKitGTK 4.1**, plus `clang`, `cmake`, `ninja-build`, and `pkg-config`.
- On distributions using Debian-style development packages: `libgtk-3-dev`, `libhandy-1-dev`, `libwebkit2gtk-4.1-dev`, and `libsecret-1-dev`.
- The project's pinned, source-built Flutter Linux engine. Normal desktop builds use verified prepared engine assets; they do not silently fall back to a shared SDK engine.

Set `BUSYAPI_FLUTTER` to the pinned Flutter SDK and `BUSYAPI_NODE` to the verified Node executable from its matching distribution. Dependency and tool preparation is explicit; BusyAPI does not install npm packages or download executable tools at application runtime.

### Prepare the toolchain

Prepare the pinned Flutter engine in a separate, BusyAPI-owned workspace, then stage the matching debug/profile/release engines:

```sh
python3 tools/build_flutter_engine.py --workspace /path/to/busyapi-engine --provision --mode all
python3 tools/prepare_flutter_engine.py --home /path/to/busyapi-engine/flutter/engine/src/out --sdk /path/to/flutter
```

Install locked project dependencies and prepare the contract and documentation assets:

```sh
flutter pub get --enforce-lockfile
tools/build_engine.sh
tools/build_documentation_assets.sh
BUSYAPI_NODE=/path/to/node python3 tools/prepare_contract_assets.py
```

A full-featured build also requires the pinned diff, client-generator, and native governance inputs to be provisioned once or supplied from already verified local assets:

```sh
python3 tools/prepare_m3_tools.py --output build/m3-tools --provision
python3 tools/prepare_generator.py --output build/generator --provision
python3 tools/provision_policy_inputs.py --provision --node-include /path/to/node24/include/node
```

Provisioning uses locked input identities. Normal application builds reuse prepared assets without downloading them. The governance isolation path requires **Landlock ABI 3** and **libseccomp 2.5.5+**; missing required isolation is not treated as a successful policy run. See [Architecture](docs/architecture.md) and [Third-party distribution](docs/third-party.md) for platform and dependency boundaries.

### Build and launch

```sh
BUSYAPI_WIDGET_RUNNER=both tools/build_linux.sh
build/linux/x64/release/bundle/busyapi-desktop
```

The CLI resides in the same release bundle. Run executables from the completed `bundle` directory, not `intermediates_do_not_run`. Once the required stages are prepared, normal `flutter run -d linux`, IDE debugging, and Flutter debug/profile/release builds install the matching assets through CMake.

### Development checks

```sh
tools/build_engine.sh
tools/prepare_test_runtime.sh
(cd packages/busyapi_core && dart test)
flutter analyze
flutter test --no-pub
tools/contract_engine/node_modules/.bin/tsc --project tools/contract_engine/tsconfig.json
python3 -m unittest tools.test_contract_assets tools.test_package_linux
python3 tools/artifact_smoke.py build/linux/x64/release/bundle
```

Native interaction, WebKit integration, strict-Snap packaging, and paint/input performance need separate platform qualification. Headless tests and CLI smoke checks do not establish those results.## Documentation

- [Architecture and security boundaries](docs/architecture.md)
- [Tool support and compatibility](docs/tool-support.md)
- [Third-party distribution inputs and notices](docs/third-party.md)
- [GitHub Actions example](examples/ci/github-actions.yml) · [GitLab CI example](examples/ci/gitlab-ci.yml)
