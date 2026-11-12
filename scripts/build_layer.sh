#!/usr/bin/env bash
# Build the psycopg2 Lambda layer for python3.12 / x86_64 into build/layers/psycopg/python
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/layers/psycopg/python"
rm -rf "$ROOT/build/layers/psycopg" && mkdir -p "$OUT"
pip install --quiet --target "$OUT" --platform manylinux2014_x86_64 --python-version 3.12 \
    --implementation cp --only-binary=:all: psycopg2-binary==2.9.9
echo "layer built: $(du -sh "$ROOT/build/layers/psycopg" | cut -f1)"
