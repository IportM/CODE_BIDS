#!/usr/bin/env bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAMBA_BIN="$PROJECT_ROOT/tools/micromamba/micromamba"
ENV_DIR="$PROJECT_ROOT/.env_fc3r"

# load micromamba
eval "$("$MAMBA_BIN" shell hook -s bash)"

# activate safely even if user has nounset
set +u
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-}"
micromamba activate "$ENV_DIR"
set -u

echo "✅ Environment activated: $ENV_DIR"
