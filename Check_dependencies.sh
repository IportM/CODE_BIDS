#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Check_dependencies.sh
# Usage:
#   bash Check_dependencies.sh
#   bash Check_dependencies.sh --python /path/to/python --julia /path/to/julia --julia-project /path/to/scr
# ------------------------------------------------------------

# -------- helpers --------
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*"; }
info() { echo "ℹ️  $*"; }

need_cmd() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then ok "Command found: $c"
  else fail "Command missing: $c"; MISSING_ANY=1
  fi
}

need_path_cmd() {
  local label="$1"
  local p="$2"
  if [[ -n "$p" && -x "$p" ]]; then ok "Command found: $p"
  else fail "Command missing: $label ($p)"; MISSING_ANY=1
  fi
}

need_file() {
  local f="$1"
  if [[ -f "$f" ]]; then ok "File found: $f"
  else fail "File missing: $f"; MISSING_ANY=1
  fi
}

# -------- args --------
PYTHON_BIN="python3"
JULIA_BIN="julia"
JULIA_PROJECT_DIR=""
PROJECT_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python)        PYTHON_BIN="$2"; shift 2;;
    --julia)         JULIA_BIN="$2"; shift 2;;
    --julia-project) JULIA_PROJECT_DIR="$2"; shift 2;;
    -h|--help)
      cat <<EOF
Usage:
  bash Check_dependencies.sh [--python PATH] [--julia PATH] [--julia-project PATH]

Defaults:
  --python python3
  --julia  julia
  --julia-project <auto: PROJECT_ROOT/scr>
EOF
      exit 0
      ;;
    *) fail "Unknown option: $1"; exit 2;;
  esac
done

# -------- detect project root --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# If script is in repo root, root = SCRIPT_DIR
# If script is in scr/, root = parent
if [[ -d "$SCRIPT_DIR/scr" ]]; then
  PROJECT_ROOT="$SCRIPT_DIR"
elif [[ "$(basename "$SCRIPT_DIR")" == "scr" ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  # fallback: climb up until we find "scr"
  cur="$SCRIPT_DIR"
  while [[ "$cur" != "/" ]]; do
    if [[ -d "$cur/scr" ]]; then PROJECT_ROOT="$cur"; break; fi
    cur="$(dirname "$cur")"
  done
  PROJECT_ROOT="${PROJECT_ROOT:-$SCRIPT_DIR}"
fi

JULIA_PROJECT_DIR="${JULIA_PROJECT_DIR:-$PROJECT_ROOT/scr}"

MISSING_ANY=0
MISSING_PY=()
MISSING_JL=()

echo
info "Project root: $PROJECT_ROOT"
info "Python:       $PYTHON_BIN"
info "Julia:        $JULIA_BIN"
info "Julia project: $JULIA_PROJECT_DIR"
echo

# ------------------------------------------------------------
# 1) pipeline files
# ------------------------------------------------------------
info "== 1) Check pipeline scripts exist (scr/01..05) =="
need_file "$PROJECT_ROOT/scr/01_BIDS/participants.py"
need_file "$PROJECT_ROOT/scr/01_BIDS/Parser_Bruker_file.py"
need_file "$PROJECT_ROOT/scr/02_reco/Brkraw_RARE.py"
need_file "$PROJECT_ROOT/scr/02_reco/angio.sh"
need_file "$PROJECT_ROOT/scr/03_masks/brain_extraction.py"
need_file "$PROJECT_ROOT/scr/03_masks/mask_aaply.py"
need_file "$PROJECT_ROOT/scr/03_masks/Mask_angio.py"
need_file "$PROJECT_ROOT/scr/04_align/Find_Matrice_SyN.sh"
need_file "$PROJECT_ROOT/scr/04_align/Align_SyN.sh"
need_file "$PROJECT_ROOT/scr/04_align/Seuil_T2star.sh"
need_file "$PROJECT_ROOT/scr/05_templates/Template_v2.sh"
need_file "$PROJECT_ROOT/scr/05_templates/apply_to_template.sh"
need_file "$PROJECT_ROOT/scr/05_templates/Make_Template.sh"
echo

# ------------------------------------------------------------
# 2) core commands
# ------------------------------------------------------------
info "== 2) Check core system commands =="
for c in bash awk sed grep find sort head tr cut bc; do
  need_cmd "$c"
done
# python/julia can be paths
if [[ "$PYTHON_BIN" == */* ]]; then need_path_cmd "python" "$PYTHON_BIN"; else need_cmd "$PYTHON_BIN"; fi
if [[ "$JULIA_BIN" == */* ]]; then need_path_cmd "julia" "$JULIA_BIN"; else need_cmd "$JULIA_BIN"; fi
# tools used by pipeline
for c in brkraw mrinfo mrconvert mrtransform mrgrid mrcat; do
  need_cmd "$c"
done
echo

# ------------------------------------------------------------
# 3) ANTs
# ------------------------------------------------------------
info "== 3) Check ANTs commands =="
for c in antsRegistrationSyN.sh antsApplyTransforms ImageMath AverageImages ResampleImageBySpacing CopyImageHeaderInformation antsMultivariateTemplateConstruction2.sh N4BiasFieldCorrection antsRegistration antsAffineInitializer; do
  need_cmd "$c"
done
echo

# ------------------------------------------------------------
# 4) python runtime + imports
# ------------------------------------------------------------
info "== 4) Check Python runtime + modules =="
if "$PYTHON_BIN" -V >/dev/null 2>&1; then
  ok "Python runs: $("$PYTHON_BIN" -V 2>&1)"
else
  fail "Python does not run: $PYTHON_BIN"
  MISSING_ANY=1
fi

py_check_import() {
  local mod="$1"
  if "$PYTHON_BIN" -c "import $mod" >/dev/null 2>&1; then
    ok "Python import OK: $mod"
  else
    fail "Python import FAIL: $mod"
    MISSING_PY+=("$mod")
    MISSING_ANY=1
  fi
}

# minimal set for your pipeline
py_check_import "numpy"
py_check_import "scipy"
py_check_import "nibabel"
py_check_import "ants"
py_check_import "antspynet"
echo

# Extra diagnostic if ants fails (common GLIBCXX issue)
if [[ " ${MISSING_PY[*]} " == *" ants "* ]]; then
  warn "ANTS Python import failed. This is often due to libstdc++/GLIBCXX mismatch."
  warn "If using conda/micromamba, try activating env and ensuring LD_LIBRARY_PATH includes <env>/lib."
fi

# ------------------------------------------------------------
# 5) julia runtime + packages
# ------------------------------------------------------------
info "== 5) Check Julia runtime + packages =="
if "$JULIA_BIN" -v >/dev/null 2>&1; then
  ok "Julia runs: $("$JULIA_BIN" -v 2>&1 | head -n 1)"
else
  fail "Julia does not run: $JULIA_BIN"
  MISSING_ANY=1
fi

if [[ -d "$JULIA_PROJECT_DIR" && -f "$JULIA_PROJECT_DIR/Project.toml" ]]; then
  ok "Julia project found: $JULIA_PROJECT_DIR/Project.toml"
else
  warn "Julia Project.toml not found in: $JULIA_PROJECT_DIR (Julia package checks may fail)"
fi

jl_try_imports='
using Pkg
# Try loading a few packages you rely on:
pkgs = ["CSV","DataFrames","Dates","JSON","NIfTI","Glob","MR"]
missing = String[]
for p in pkgs
  try
    @eval import $(Symbol(p))
  catch
    push!(missing, p)
  end
end
if !isempty(missing)
  println("MISSING_JULIA_PKGS=" * join(missing, ","))
end
'

set +e
JL_OUT="$("$JULIA_BIN" --project="$JULIA_PROJECT_DIR" -e "$jl_try_imports" 2>&1)"
JL_RC=$?
set -e

if [[ $JL_RC -eq 0 ]]; then
  ok "Julia imports OK: core_pkgs"
else
  warn "Julia import test returned non-zero (may still be ok depending on setup)."
fi

if echo "$JL_OUT" | grep -q "MISSING_JULIA_PKGS="; then
  miss_line="$(echo "$JL_OUT" | grep "MISSING_JULIA_PKGS=" | tail -n1)"
  miss_csv="${miss_line#MISSING_JULIA_PKGS=}"
  IFS=',' read -r -a miss_arr <<< "$miss_csv"
  for p in "${miss_arr[@]}"; do
    fail "Julia import FAIL: $p"
    MISSING_JL+=("$p")
    MISSING_ANY=1
  done
else
  ok "Julia imports OK: core_pkgs"
fi

# Optional: your local package
set +e
"$JULIA_BIN" --project="$JULIA_PROJECT_DIR" -e 'import SEQ_BRUKER_a_MP2RAGE_CS_360' >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 0 ]]; then ok "Julia imports OK: SEQ_BRUKER_a_MP2RAGE_CS_360"
else warn "Julia import WARN: SEQ_BRUKER_a_MP2RAGE_CS_360 (optional/local?)"
fi
echo

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
info "== Summary =="
echo

if [[ ${#MISSING_PY[@]} -gt 0 ]]; then
  fail "Missing Python modules:"
  for m in "${MISSING_PY[@]}"; do echo "  - $m"; done
  echo "Hints:"
  echo "  - In your venv/conda env: pip install antspyx antspynet numpy scipy nibabel"
  echo
fi

if [[ ${#MISSING_JL[@]} -gt 0 ]]; then
  fail "Missing Julia packages:"
  for m in "${MISSING_JL[@]}"; do echo "  - $m"; done
  echo "Hints:"
  echo "  - From repo root: julia --project=./scr -e 'using Pkg; Pkg.instantiate()'"
  echo
fi

if [[ $MISSING_ANY -eq 0 ]]; then
  ok "All checks passed ✅"
  exit 0
else
  warn "Fix missing items, then re-run: bash Check_dependencies.sh"
  exit 1
fi
