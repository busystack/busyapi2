# JSON Schema 2020-12 oracles

Unmodified cases from [JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite/tree/55719286c33ae0d1823bfb65fea10338a19bc37c/tests/draft2020-12), revision `55719286c33ae0d1823bfb65fea10338a19bc37c`, retrieved 2026-10-15. The accompanying MIT license applies. The retained files cover static/dynamic references, boolean schemas, conditionals and unevaluated properties. `tests[].valid` is the oracle; an exception or unavailable resource is not an accepted rejection or a skipped success.

The isolated candidate evaluator probe is `node tools/probes/m2/conformance.mjs`. It denies all unsupplied file/network access and reports failures by original case and test. This is not a claim that a candidate has been integrated into BusyAPI's production checks.
