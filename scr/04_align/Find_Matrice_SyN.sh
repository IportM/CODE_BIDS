#!/usr/bin/env bash
source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate
set -euo pipefail

# Où se trouve ce script (chemin absolu)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project root = 2 niveaux au-dessus (car scr/XX/)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Dossiers “standards” produits par ton pipeline
BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

# Dossier contenant les images à enregistrer
DATA_DIR="$BRAIN_EXTRACTED_DIR/RARE"

# Références par groupe de sessions
REF_IMG_SES_1_2="${DATA_DIR}/sub-01_ses-1_RARE_brain_extracted.nii.gz"
REF_IMG_SES_3_4="${DATA_DIR}/sub-01_ses-3_RARE_brain_extracted.nii.gz"
REF_IMG_SES_5_6="${DATA_DIR}/sub-01_ses-5_RARE_brain_extracted.nii.gz"

# Type de transform antsRegistrationSyN.sh :
#   a = Rigid + Affine (proche de ton script d'origine)
#   s = SyN complet (non-linéaire)
TRANSFORM_TYPE="a"

# Dossiers de sortie
REG_DIR="${DATA_DIR}/matrice_transformsSyN"
FINAL_DIR="${DATA_DIR}/alignedSyN"
mkdir -p "${REG_DIR}" "${FINAL_DIR}"

# Boucle sur toutes les images
for IMG in "${DATA_DIR}"/*.nii*; do
  BASE=$(basename "${IMG}" | sed -E 's/\.nii(\.gz)?$//')
  SES_NUM=$(echo "$BASE" | grep -oP 'ses-\K[0-9]+')

  # Sélection dynamique de la référence
  if [[ "$SES_NUM" -eq 1 || "$SES_NUM" -eq 2 ]]; then
    REF_IMG="$REF_IMG_SES_1_2"
  elif [[ "$SES_NUM" -eq 3 || "$SES_NUM" -eq 4 ]]; then
    REF_IMG="$REF_IMG_SES_3_4"
  elif [[ "$SES_NUM" -eq 5 || "$SES_NUM" -eq 6 ]]; then
    REF_IMG="$REF_IMG_SES_5_6"
  else
    echo "❌ Session inconnue dans $BASE, skip."
    continue
  fi

  # Vérif de l'existence de la ref
  if [[ ! -f "$REF_IMG" ]]; then
    echo "❌ Référence absente : $REF_IMG"
    continue
  fi

  # ID de la ref sous forme sub-XX_ses-Y_Method
  REF_ID=$(basename "$REF_IMG" | sed -E 's/\.nii(\.gz)?$//' | cut -d_ -f1-3)

  # Nom de la sortie finale (dans FINAL_DIR, comme avant)
  OUTPUT_FINAL="${FINAL_DIR}/${BASE}_to_${REF_ID}_Warped.nii.gz"

  # Skip si l'image est la référence
  if [[ "${IMG}" == "${REF_IMG}" ]]; then
    echo "⏩ ${BASE} est une référence ($REF_ID), skip."
    continue
  fi

  # Skip si déjà alignée
  if [[ -f "${OUTPUT_FINAL}" ]]; then
    echo "⏩ ${BASE} déjà alignée, skip."
    continue
  fi

  echo "=== Traitement de ${BASE} → référence : ${REF_ID} ==="
  echo "→ antsRegistrationSyN.sh (type: ${TRANSFORM_TYPE})..."

  # Préfixe des outputs antsRegistrationSyN.sh (dans REG_DIR)
  OUT_PREFIX="${REG_DIR}/${BASE}_to_${REF_ID}_"

  antsRegistrationSyN.sh \
    -d 3 \
    -f "${REF_IMG}" \
    -m "${IMG}" \
    -o "${OUT_PREFIX}" \
    -t "${TRANSFORM_TYPE}" \
    -n 8

  # antsRegistrationSyN.sh produit :
  #   ${OUT_PREFIX}Warped.nii.gz           = moving -> fixed
  #   ${OUT_PREFIX}InverseWarped.nii.gz    = fixed -> moving
  #   ${OUT_PREFIX}0GenericAffine.mat      = affine (et éventuellement Warp si -t s)
  #
  # On recopie/renomme la Warped dans FINAL_DIR pour garder la même organisation
  SRC_WARPED="${OUT_PREFIX}Warped.nii.gz"

  if [[ -f "${SRC_WARPED}" ]]; then
    cp "${SRC_WARPED}" "${OUTPUT_FINAL}"
    echo "  ✓ Image alignée : ${OUTPUT_FINAL}"
    echo "  → Transfos conservées dans ${REG_DIR} (matrices + champs éventuels)"
  else
    echo "❌ Fichier warpé introuvable : ${SRC_WARPED}"
  fi

done

echo "✅ Terminé : alignements faits, matrices/champs conservés dans ${REG_DIR}."
deactivate
