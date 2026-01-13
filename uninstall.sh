#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# FC3R uninstall.sh
# - removes local micromamba + local env created by install.sh
# - optional: remove locally installed julia (tools/julia*)
# - does NOT touch ~/.julia by default
# ------------------------------------------------------------

# Detect project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$SCRIPT_DIR")" == "scr" ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
else
  PROJECT_ROOT="$SCRIPT_DIR"
fi

ENV_DIR="${ENV_DIR:-$PROJECT_ROOT/.env_fc3r}"
TOOLS_DIR="${TOOLS_DIR:-$PROJECT_ROOT/tools}"
MAMBA_DIR="${MAMBA_DIR:-$TOOLS_DIR/micromamba}"
MAMBA_BIN="${MAMBA_BIN:-$MAMBA_DIR/micromamba}"

REMOVE_JULIA=0
REMOVE_JULIA_CACHE=0
ASSUME_YES=0

usage() {
  cat <<EOF
Usage:
  bash uninstall.sh [--yes] [--with-julia] [--with-julia-cache]

What it removes by default:
  - $ENV_DIR
  - $MAMBA_DIR

Optional:
  --with-julia        Also remove $TOOLS_DIR/julia and $TOOLS_DIR/julia-*
  --with-julia-cache  Also remove ~/.julia/compiled and ~/.julia/logs (safe cache cleanup)
  --yes               Do not ask for confirmation
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-julia)       REMOVE_JULIA=1; shift;;
    --with-julia-cache) REMOVE_JULIA_CACHE=1; shift;;
    --yes)              ASSUME_YES=1; shift;;
    -h|--help)          usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 2;;
  esac
done

echo "== FC3R uninstall =="
echo "Project root: $PROJECT_ROOT"
echo

targets=()
[[ -d "$ENV_DIR" ]] && targets+=("$ENV_DIR")
[[ -d "$MAMBA_DIR" ]] && targets+=("$MAMBA_DIR")

if (( REMOVE_JULIA == 1 )); then
  [[ -e "$TOOLS_DIR/julia" ]] && targets+=("$TOOLS_DIR/julia")
  if [[ -d "$TOOLS_DIR" ]]; then
    # Add all julia-* folders inside tools/
    while IFS= read -r -d '' p; do
      targets+=("$p")
    done < <(find "$TOOLS_DIR" -maxdepth 1 -type d -name "julia-*" -print0 2>/dev/null || true)
  fi
fi

# If nothing to remove, exit
if (( ${#targets[@]} == 0 )) && (( REMOVE_JULIA_CACHE == 0 )); then
  echo "Nothing to remove. (No env/tools found)"
  exit 0
fi

echo "This will remove:"
for t in "${targets[@]}"; do
  echo "  - $t"
done
if (( REMOVE_JULIA_CACHE == 1 )); then
  echo "  - ~/.julia/compiled"
  echo "  - ~/.julia/logs"
fi

echo
if (( ASSUME_YES == 0 )); then
  read -r -p "Proceed? [y/N] " ans
  case "${ans,,}" in
    y|yes) ;;
    *) echo "Aborted."; exit 0;;
  esac
fi

# Best-effort micromamba deactivate (avoid failing under nounset)
if [[ -x "$MAMBA_BIN" ]]; then
  export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$MAMBA_DIR/root}"

  set +e
  set +u
  export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-}"

  eval "$("$MAMBA_BIN" shell hook -s bash)" >/dev/null 2>&1 || true
  micromamba deactivate >/dev/null 2>&1 || true

  set -u
  set -e
fi

# Remove targets
for t in "${targets[@]}"; do
  if [[ -e "$t" ]]; then
    echo "Removing: $t"
    rm -rf "$t"
  fi
done

# Optional Julia cache cleanup
if (( REMOVE_JULIA_CACHE == 1 )); then
  echo "Removing Julia cache (compiled/logs)..."
  rm -rf "$HOME/.julia/compiled" "$HOME/.julia/logs" 2>/dev/null || true
fi

echo
echo "✅ Uninstall completed."
