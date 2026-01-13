#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# FC3R - Dependency checker (no install, only checks + hints)
# ------------------------------------------------------------

# Colors (safe fallback)
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

ok()    { echo "${GREEN}✅ $*${NC}"; }
warn()  { echo "${YELLOW}⚠️  $*${NC}"; }
fail()  { echo "${RED}❌ $*${NC}"; }
info()  { echo "${BLUE}ℹ️  $*${NC}"; }

# Defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3}"
JULIA_BIN="${JULIA_BIN:-julia}"

# If you have a dedicated Julia env, you can pass it:
JULIA_PROJECT="${JULIA_PROJECT:-}"  # ex: "$PROJECT_ROOT/julia_env" or "" to use default

# Collect missing items
missing_cmds=()
missing_py=()
missing_jl=()
missing_files=()

# Auto-detect Julia project
if [[ -z "${JULIA_PROJECT:-}" ]]; then
  if [[ -f "$PROJECT_ROOT/scr/Project.toml" ]]; then
    JULIA_PROJECT="$PROJECT_ROOT/scr"
  elif [[ -f "$PROJECT_ROOT/Project.toml" ]]; then
    JULIA_PROJECT="$PROJECT_ROOT"
  else
    JULIA_PROJECT=""  # fallback: default Julia env
  fi
fi

usage() {
  cat <<EOF
Usage:
  bash check_deps.sh [--project-root PATH] [--python PATH] [--julia PATH] [--julia-project PATH]

Examples:
  bash check_deps.sh
  bash check_deps.sh --python /path/to/python3 --julia /path/to/julia
  bash check_deps.sh --julia-project ./julia_env

This script DOES NOT install anything. It only checks and prints hints.
EOF
}

# Arg parse
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$(cd "$2" && pwd)"; shift 2;;
    --python)       PYTHON_BIN="$2"; shift 2;;
    --julia)        JULIA_BIN="$2"; shift 2;;
    --julia-project) JULIA_PROJECT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) fail "Unknown arg: $1"; usage; exit 2;;
  esac
done

info "Project root: $PROJECT_ROOT"
info "Python:       $PYTHON_BIN"
info "Julia:        $JULIA_BIN"
[[ -n "$JULIA_PROJECT" ]] && info "Julia project: $JULIA_PROJECT"

# Helpers
have_cmd() { command -v "$1" >/dev/null 2>&1; }
check_cmd() {
  local c="$1"
  if have_cmd "$c"; then ok "Command found: $c"; else fail "Missing command: $c"; missing_cmds+=("$c"); fi
}

check_file() {
  local f="$1"
  if [[ -e "$f" ]]; then ok "File found: $f"; else fail "Missing file: $f"; missing_files+=("$f"); fi
}

run_py_import() {
  local mod="$1"
  if "$PYTHON_BIN" -c "import $mod" >/dev/null 2>&1; then ok "Python import OK: $mod"
  else fail "Python import FAIL: $mod"; missing_py+=("$mod"); fi
}

run_julia_imports() {
  local label="$1"
  local code="$2"
  local cmd=("$JULIA_BIN")
  [[ -n "$JULIA_PROJECT" ]] && cmd+=("--project=$JULIA_PROJECT")
  cmd+=("-e" "$code")

  if "${cmd[@]}" >/dev/null 2>&1; then ok "Julia imports OK: $label"
  else fail "Julia imports FAIL: $label"; missing_jl+=("$label"); fi
}

echo
info "== 1) Check pipeline scripts exist (scr/01..05) =="
# Adjust names if you renamed folders slightly
check_file "$PROJECT_ROOT/scr/01_BIDS/participants.py"
check_file "$PROJECT_ROOT/scr/01_BIDS/Parser_Bruker_file.py"

check_file "$PROJECT_ROOT/scr/02_reco/Brkraw_RARE.py"
check_file "$PROJECT_ROOT/scr/02_reco/angio.sh"

check_file "$PROJECT_ROOT/scr/03_masks/brain_extraction.py"
check_file "$PROJECT_ROOT/scr/03_masks/mask_aaply.py"
check_file "$PROJECT_ROOT/scr/03_masks/Mask_angio.py"

check_file "$PROJECT_ROOT/scr/04_align/Find_Matrice_SyN.sh"
check_file "$PROJECT_ROOT/scr/04_align/Align_SyN.sh"
check_file "$PROJECT_ROOT/scr/04_align/Seuil_T2star.sh"

check_file "$PROJECT_ROOT/scr/05_templates/Template_v2.sh"
check_file "$PROJECT_ROOT/scr/05_templates/apply_to_template.sh"
check_file "$PROJECT_ROOT/scr/05_templates/Make_Template.sh"

echo
info "== 2) Check core system commands =="
# Shell basics
check_cmd bash
check_cmd awk
check_cmd sed
check_cmd grep
check_cmd find
check_cmd sort
check_cmd head
check_cmd tr
check_cmd cut
check_cmd bc

# Python/Julia
check_cmd "$PYTHON_BIN" || true  # if PYTHON_BIN is a path, command -v may fail; we'll test below
check_cmd "$JULIA_BIN" || true

# brkraw
check_cmd brkraw

# MRtrix3
check_cmd mrinfo
check_cmd mrconvert
check_cmd mrtransform
check_cmd mrgrid
check_cmd mrcat

echo
info "== 3) Check ANTs commands =="
check_cmd antsRegistrationSyN.sh
check_cmd antsApplyTransforms
check_cmd ImageMath
check_cmd AverageImages
check_cmd ResampleImageBySpacing
check_cmd CopyImageHeaderInformation
check_cmd antsMultivariateTemplateConstruction2.sh

# Optional but often present/used
warn_cmds=(N4BiasFieldCorrection antsRegistration antsAffineInitializer)
for c in "${warn_cmds[@]}"; do
  if have_cmd "$c"; then ok "Command found: $c"; else warn "Optional/Maybe missing: $c"; fi
done

echo
info "== 4) Check Python runtime + modules =="
if "$PYTHON_BIN" -V >/dev/null 2>&1; then
  ok "Python runs: $("$PYTHON_BIN" -V 2>&1)"
else
  fail "Python is not runnable: $PYTHON_BIN"
  missing_cmds+=("$PYTHON_BIN")
fi

# Your scripts rely on 'ants' and 'antspynet'
run_py_import ants
run_py_import antspynet

# Optional (often needed indirectly)
for m in numpy scipy nibabel; do
  if "$PYTHON_BIN" -c "import $m" >/dev/null 2>&1; then
    ok "Python import OK: $m"
  else
    warn "Python import missing (often required): $m"
  fi
done

echo
info "== 5) Check Julia runtime + packages =="
if "$JULIA_BIN" -v >/dev/null 2>&1; then
  ok "Julia runs: $("$JULIA_BIN" -v 2>&1 | head -n 1)"
else
  fail "Julia is not runnable: $JULIA_BIN"
  missing_cmds+=("$JULIA_BIN")
fi

# Core Julia deps
run_julia_imports "core_pkgs" 'using CSV, DataFrames, Dates, JSON, Glob, Statistics; using NIfTI, MRIFiles, LsqFit, Metrics; using PyCall'

# Custom package (may require Pkg.develop)
run_julia_imports "SEQ_BRUKER_a_MP2RAGE_CS_360" 'using SEQ_BRUKER_a_MP2RAGE_CS_360'

# MESE project presence (optional depending on your run)
echo
info "== 6) Check MESE project presence (optional) =="
if [[ -d "$PROJECT_ROOT/reconstruction_MESE" ]]; then
  ok "Found reconstruction_MESE directory"
  [[ -f "$PROJECT_ROOT/reconstruction_MESE/main_MESE.jl" ]] && ok "Found reconstruction_MESE/main_MESE.jl" || warn "Missing reconstruction_MESE/main_MESE.jl"
  [[ -f "$PROJECT_ROOT/reconstruction_MESE/Project.toml" ]] && ok "Found reconstruction_MESE/Project.toml" || warn "Missing reconstruction_MESE/Project.toml"
else
  warn "reconstruction_MESE not found (MESE step will fail if you run it)"
fi

echo
info "== Summary =="
if (( ${#missing_files[@]} == 0 && ${#missing_cmds[@]} == 0 && ${#missing_py[@]} == 0 && ${#missing_jl[@]} == 0 )); then
  ok "All required checks passed."
  exit 0
fi

echo
if (( ${#missing_files[@]} > 0 )); then
  fail "Missing pipeline files:"
  printf '  - %s\n' "${missing_files[@]}"
fi

if (( ${#missing_cmds[@]} > 0 )); then
  fail "Missing system commands/binaries:"
  printf '  - %s\n' "${missing_cmds[@]}"
  echo "Hints:"
  echo "  - Install MRtrix3 (mrinfo/mrconvert/mrtransform/...)"
  echo "  - Install ANTs (antsRegistrationSyN.sh, antsApplyTransforms, ImageMath, ...)"
  echo "  - Install brkraw (or add it to PATH)"
fi

if (( ${#missing_py[@]} > 0 )); then
  fail "Missing Python modules:"
  printf '  - %s\n' "${missing_py[@]}"
  echo "Hints:"
  echo "  - In your Python environment: pip install antspyx antspynet"
fi

if (( ${#missing_jl[@]} > 0 )); then
  fail "Missing Julia packages:"
  printf '  - %s\n' "${missing_jl[@]}"
  echo "Hints:"
  echo "  - In Julia: using Pkg; Pkg.add([\"CSV\",\"DataFrames\",\"JSON\",\"Glob\",\"NIfTI\",\"MRIFiles\",\"LsqFit\",\"Metrics\",\"PyCall\"])"
  echo "  - For custom package: Pkg.develop(path=\"/path/to/SEQ_BRUKER_a_MP2RAGE_CS_360\")"
fi

echo
warn "Fix missing items, then re-run: bash check_deps.sh"
exit 1
