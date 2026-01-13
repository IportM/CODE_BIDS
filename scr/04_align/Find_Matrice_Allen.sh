#!/usr/bin/env bash
source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate
set -euo pipefail

# ─────────────────────────────────────────────
# 📂 Dossiers / fichiers d'entrée
# ─────────────────────────────────────────────
# Où se trouve ce script (chemin absolu)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project root = 2 niveaux au-dessus (car scr/XX/)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Dossiers “standards” produits par ton pipeline
BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

# Dossier contenant les cerveaux RARE des souris
DATA_DIR="$BRAIN_EXTRACTED_DIR/RARE"

# 🔹 Template Allen (EN ESPACE / RÉSOLUTION COMPATIBLE AVEC TES RARE)
# → À ADAPTER avec ton vrai chemin !
ALLEN_TEMPLATE="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/Allen/LR/100_AMBA_ref.nii.gz"

if [[ ! -f "${ALLEN_TEMPLATE}" ]]; then
  echo "❌ Template Allen introuvable : ${ALLEN_TEMPLATE}"
  exit 1
fi

# Type de transform antsRegistrationSyN.sh :
#   a = Rigid + Affine
#   s = SyN complet (non-linéaire)
TRANSFORM_TYPE="a"

# ─────────────────────────────────────────────
# 📂 Dossiers de sortie
# ─────────────────────────────────────────────

REG_DIR="${DATA_DIR}/matrice_transformsSyN_Allen"
FINAL_DIR="${DATA_DIR}/alignedSyN_Allen"
mkdir -p "${REG_DIR}" "${FINAL_DIR}"

# ID lisible pour le template Allen (pour le nommage des sorties)
ALLEN_ID=$(basename "${ALLEN_TEMPLATE}" | sed -E 's/\.nii(\.gz)?$//')

# ─────────────────────────────────────────────
# 🔁 Boucle sur toutes les images souris
# ─────────────────────────────────────────────

for IMG in "${DATA_DIR}"/*.nii*; do
  BASE=$(basename "${IMG}" | sed -E 's/\.nii(\.gz)?$//')

  # Si jamais le template Allen se trouve dans ce dossier, on le skippe
  if [[ "${IMG}" == "${ALLEN_TEMPLATE}" ]]; then
    echo "⏩ ${BASE} est le template Allen, skip."
    continue
  fi

  # Nom de la sortie finale dans FINAL_DIR
  OUTPUT_FINAL="${FINAL_DIR}/${BASE}_to_${ALLEN_ID}_Warped.nii.gz"

  # Skip si déjà alignée
  if [[ -f "${OUTPUT_FINAL}" ]]; then
    echo "⏩ ${BASE} déjà alignée sur Allen, skip."
    continue
  fi

  echo "=== Traitement de ${BASE} → template : ${ALLEN_ID} ==="
  echo "→ antsRegistrationSyN.sh (type: ${TRANSFORM_TYPE})..."

  # Préfixe des outputs antsRegistrationSyN.sh (dans REG_DIR)
  OUT_PREFIX="${REG_DIR}/${BASE}_to_${ALLEN_ID}_"

  antsRegistrationSyN.sh \
    -d 3 \
    -f "${ALLEN_TEMPLATE}" \
    -m "${IMG}" \
    -o "${OUT_PREFIX}" \
    -t "${TRANSFORM_TYPE}" \
    -n 8

  # antsRegistrationSyN.sh produit :
  #   ${OUT_PREFIX}Warped.nii.gz        = moving -> fixed (donc souris -> Allen)
  #   ${OUT_PREFIX}InverseWarped.nii.gz = Allen -> souris
  #   ${OUT_PREFIX}0GenericAffine.mat   = affine (et éventuel warp si -t s)

  SRC_WARPED="${OUT_PREFIX}Warped.nii.gz"

  if [[ -f "${SRC_WARPED}" ]]; then
    cp "${SRC_WARPED}" "${OUTPUT_FINAL}"
    echo "  ✓ Image alignée : ${OUTPUT_FINAL}"
    echo "  → Transfos conservées dans ${REG_DIR} (matrices + champs éventuels)"
  else
    echo "❌ Fichier warpé introuvable : ${SRC_WARPED}"
  fi

done

echo "✅ Terminé : toutes les souris sont alignées sur le template Allen (${ALLEN_ID})."
deactivate
