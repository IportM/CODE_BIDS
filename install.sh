#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# FC3R install.sh (no sudo)
# - installs micromamba locally
# - creates a local env with python + ANTs + MRtrix3 + Julia
# - pip installs requirements.txt
# - julia --project=./src instantiate + precompile (+ PyCall build)
# - runs check_deps.sh at the end
# ------------------------------------------------------------

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOOLS_DIR="$PROJECT_ROOT/tools"
MAMBA_DIR="$TOOLS_DIR/micromamba"
MAMBA_BIN="$MAMBA_DIR/micromamba"
MAMBA_ROOT="$MAMBA_DIR/root"          # micromamba root prefix
ENV_DIR="$PROJECT_ROOT/.env_fc3r"     # conda env path (local)

SRC_JULIA_ENV="$PROJECT_ROOT/src"     # <-- your Project.toml + Manifest.toml live here

# You can override these if you want
PY_VER="${PY_VER:-3.11}"
# If you want to pin julia version from conda-forge, set JULIA_PIN like "julia=1.10.*"
JULIA_PIN="${JULIA_PIN:-julia}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing command: $1"; exit 1; }; }

echo "== FC3R install =="
echo "Project root: $PROJECT_ROOT"

need_cmd curl
need_cmd tar

mkdir -p "$TOOLS_DIR"

# -------------------------
# 1) Install micromamba
# -------------------------
if [[ ! -x "$MAMBA_BIN" ]]; then
  echo "== Installing micromamba locally =="
  mkdir -p "$MAMBA_DIR"
  tmpdir="$(mktemp -d)"
  # micromamba API returns a tar archive containing bin/micromamba
  curl -Ls "https://micro.mamba.pm/api/micromamba/linux-64/latest" \
    | tar -xj -C "$tmpdir" bin/micromamba
  mv "$tmpdir/bin/micromamba" "$MAMBA_BIN"
  chmod +x "$MAMBA_BIN"
  rm -rf "$tmpdir"
else
  echo "== micromamba already present =="
fi

export MAMBA_ROOT_PREFIX="$MAMBA_ROOT"
eval "$("$MAMBA_BIN" shell hook -s bash)"

# -------------------------
# 2) Create env (Python + ANTs + MRtrix3 + Julia)
# -------------------------
if [[ ! -d "$ENV_DIR" ]]; then
  echo "== Creating environment: $ENV_DIR =="
    "$MAMBA_BIN" create -y -p "$ENV_DIR" \
    -c conda-forge -c MRtrix3 \
    "python=${PY_VER}" pip \
    ants \
    "MRtrix3::mrtrix3" libstdcxx-ng \
    julia \
    numpy scipy nibabel
else
  echo "== Environment already exists: $ENV_DIR =="
fi

micromamba activate "$ENV_DIR"

ENV_PY="$ENV_DIR/bin/python"
ENV_JULIA="$ENV_DIR/bin/julia"
ENV_PIP="$ENV_DIR/bin/pip"

echo "== Using python: $("$ENV_PY" -V 2>&1) =="
echo "== Using julia: $("$ENV_JULIA" -v 2>&1 | head -n 1) =="

# Try to install brkraw if available (optional)
set +e
"$MAMBA_BIN" install -y -p "$ENV_DIR" -c conda-forge brkraw >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  echo "✅ brkraw installed (conda-forge)"
else
  echo "⚠️ brkraw not installed via conda-forge (ok). You'll install it manually if needed."
fi
set -e

# -------------------------
# 3) Python deps from requirements.txt
# -------------------------
if [[ ! -f "$PROJECT_ROOT/requirements.txt" ]]; then
  echo "❌ Missing requirements.txt at repo root."
  exit 1
fi

echo "== Installing Python deps (requirements.txt) =="
"$ENV_PIP" install --upgrade pip wheel setuptools
"$ENV_PIP" install -r "$PROJECT_ROOT/requirements.txt"

# -------------------------
# 4) Julia deps (Project/Manifest in ./src)
# -------------------------
if [[ ! -f "$SRC_JULIA_ENV/Project.toml" ]]; then
  echo "❌ Missing src/Project.toml (expected at $SRC_JULIA_ENV/Project.toml)"
  exit 1
fi

echo "== Instantiating Julia environment in ./src =="
# Ensure PyCall uses the env python
export PYTHON="$ENV_PY"

"$ENV_JULIA" --project="$SRC_JULIA_ENV" -e '
using Pkg;
# Force PyCall to use the same python as the env
ENV["PYTHON"] = get(ENV, "PYTHON", "python3");
Pkg.instantiate();
# Rebuild PyCall (safe even if not used)
try
  Pkg.build("PyCall")
catch
end
Pkg.precompile();
'

# Optional: if your custom Julia package is in the repo, develop it (only if present)
if [[ -d "$PROJECT_ROOT/SEQ_BRUKER_a_MP2RAGE_CS_360" ]]; then
  echo "== Developing local Julia package: SEQ_BRUKER_a_MP2RAGE_CS_360 =="
  "$ENV_JULIA" --project="$SRC_JULIA_ENV" -e "using Pkg; Pkg.develop(path=\"$PROJECT_ROOT/SEQ_BRUKER_a_MP2RAGE_CS_360\"); Pkg.precompile();"
fi

# Optional: MESE project
if [[ -d "$PROJECT_ROOT/reconstruction_MESE" ]]; then
  if [[ -f "$PROJECT_ROOT/reconstruction_MESE/Project.toml" ]]; then
    echo "== Instantiating reconstruction_MESE =="
    "$ENV_JULIA" --project="$PROJECT_ROOT/reconstruction_MESE" -e "using Pkg; Pkg.instantiate(); Pkg.precompile();"
  else
    echo "⚠️ reconstruction_MESE exists but no Project.toml found (skipping instantiate)"
  fi
fi

# -------------------------
# 5) Run check_deps.sh
# -------------------------
if [[ ! -f "$PROJECT_ROOT/check_deps.sh" ]]; then
  echo "⚠️ check_deps.sh not found (skipping checks)"
  exit 0
fi

echo "== Running check_deps.sh =="
chmod +x "$PROJECT_ROOT/check_deps.sh" || true

# If your check_deps supports CLI args (like the version we discussed), use them.
if grep -q -- "--julia-project" "$PROJECT_ROOT/check_deps.sh" 2>/dev/null; then
  bash "$PROJECT_ROOT/check_deps.sh" \
    --python "$ENV_PY" \
    --julia "$ENV_JULIA" \
    --julia-project "$SRC_JULIA_ENV"
else
  # Otherwise, run it as-is (it should rely on PATH / default julia)
  bash "$PROJECT_ROOT/check_deps.sh"
fi

echo "✅ Install completed successfully."
echo
echo "To use the environment later:"
echo "  eval \"\$($MAMBA_BIN shell hook -s bash)\""
echo "  micromamba activate \"$ENV_DIR\""
echo "  julia --project=./src ./src/Reconstrcution_BIDS_FC3R.jl"
