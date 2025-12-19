#!/usr/bin/env bash

# ================================================================
#  install.sh – Setup FC3R pipeline environment
#  - Crée un environnement virtuel Python
#  - Installe les dépendances Python (antspyx, brkraw, etc.)
#  - Instancie l'environnement Julia du projet
#  - Vérifie la présence des binaires ANTs
# ================================================================
set -euo pipefail

# --------- Localisation du projet ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "➡ Project root: ${PROJECT_ROOT}"

# --------- Configuration Python (venv) ----------
PY_ENV_DIR="${PROJECT_ROOT}/.venv_fc3r"

echo "➡ Setting up Python virtual environment in: ${PY_ENV_DIR}"

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 not found in PATH. Please install Python 3 first."
    exit 1
fi

# Crée l'environnement virtuel s'il n'existe pas déjà
if [[ ! -d "${PY_ENV_DIR}" ]]; then
    python3 -m venv "${PY_ENV_DIR}"
    echo "✅ Created virtual environment."
else
    echo "ℹ️ Virtual environment already exists, reusing it."
fi

# Active le venv
# shellcheck source=/dev/null
source "${PY_ENV_DIR}/bin/activate"

echo "➡ Upgrading pip and installing Python dependencies..."
pip install --upgrade pip
pip install -r "${PROJECT_ROOT}/requirements.txt"

echo "➡ Checking that key Python packages are importable (ants / brkraw)..."
python - << 'EOF'
import importlib

missing = []

for pkg, modname in [("antspyx", "ants"), ("brkraw", "brkraw"), ("nibabel", "nibabel"), ("numpy", "numpy")]:
    try:
        importlib.import_module(modname)
    except Exception as e:
        missing.append((pkg, str(e)))

if missing:
    print("❌ Some Python packages failed to import:")
    for pkg, err in missing:
        print(f"   - {pkg}: {err}")
    raise SystemExit(1)
else:
    print("✅ antspyx, brkraw, nibabel, numpy successfully imported.")
EOF

echo "✅ Python environment ready."
echo "   To use it later, run:  source .venv_fc3r/bin/activate"

# --------- Configuration Julia ----------
echo ""
echo "➡ Setting up Julia environment from Project.toml..."

if command -v julia >/dev/null 2>&1; then
    julia --project="${PROJECT_ROOT}" -e 'using Pkg; Pkg.instantiate()'
    echo "✅ Julia environment instantiated."
else
    echo "⚠️ julia not found in PATH."
    echo "   Please install Julia (1.11.x) and re-run:"
    echo "     julia --project=. -e \"using Pkg; Pkg.instantiate()\""
fi

# --------- ANTs / outils externes ----------
echo ""
echo "➡ Checking for ANTs binaries (antsRegistration, antsApplyTransforms)..."

HAS_ANTS=1
for BIN in antsRegistration antsApplyTransforms antsMultivariateTemplateConstruction2.sh; do
    if ! command -v "${BIN}" >/dev/null 2>&1; then
        echo "⚠️ ${BIN} not found in PATH."
        HAS_ANTS=0
    fi
done

if [[ "${HAS_ANTS}" -eq 1 ]]; then
    echo "✅ ANTs binaries seem to be available in PATH."
else
    cat << 'EOF'

❗ ANTs binaries are not fully available.
You still need to install ANTs (the C++ toolkit) so that commands like
"antsRegistration" and "antsApplyTransforms" are in your PATH.

If you use conda/mamba, a typical installation is:

  mamba create -n fc3r-ants -c conda-forge ants
  mamba activate fc3r-ants

Then make sure that this environment is active when running the shell scripts
(Align_Allen.sh, Make_Template.sh, etc.), or add the ANTs bin directory to PATH.

EOF
fi

echo ""
echo "✅ Base installation done."
