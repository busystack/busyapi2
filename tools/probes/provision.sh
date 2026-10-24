#!/usr/bin/env bash
# Explicit development-time provisioning. Never called by the application.
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f package-lock.json ]]; then npm install --package-lock-only --ignore-scripts; fi
npm ci --ignore-scripts --no-audit --no-fund
npx --no-install playwright install chromium
mkdir -p bin
# Maven Central does not publish a SHA-256 sidecar for this release. Verify the
# exact GitHub release asset against its publisher-provided SHA-256 digest.
curl -fSL https://github.com/OpenAPITools/openapi-generator/releases/download/v7.26.0/openapi-generator-cli-7.26.0.jar -o bin/openapi-generator-7.26.0.jar
python3 - <<'PY'
import pathlib,hashlib
p=pathlib.Path('bin/openapi-generator-7.26.0.jar')
assert hashlib.sha256(p.read_bytes()).hexdigest()=='5ccb60c4678901715376c6114afba60c28d0844fe506bd1e02891cbc363ab9ff'
PY
curl -fSL https://github.com/oasdiff/oasdiff/releases/download/v1.33.0/oasdiff_1.33.0_linux_amd64.tar.gz -o bin/oasdiff.tar.gz
curl -fSL https://github.com/oasdiff/oasdiff/releases/download/v1.33.0/checksums.txt -o bin/checksums.txt
python3 verify_oasdiff.py bin/oasdiff.tar.gz bin/checksums.txt
tar -xzf bin/oasdiff.tar.gz -C bin oasdiff
