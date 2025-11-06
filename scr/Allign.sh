#!/usr/bin/env bash
source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate
set -euo pipefail

# Dossier contenant les images à enregistrer
DATA_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE"

# Références par groupe de sessions
REF_IMG_SES_1_2="${DATA_DIR}/sub-01_ses-1_RARE_brain_extracted.nii.gz"
REF_IMG_SES_3_4="${DATA_DIR}/sub-01_ses-3_RARE_brain_extracted.nii.gz"
REF_IMG_SES_5_6="${DATA_DIR}/sub-01_ses-5_RARE_brain_extracted.nii.gz"

# Dossiers de sortie
REG_DIR="${DATA_DIR}/matrice_transforms"
FINAL_DIR="${DATA_DIR}/aligned"
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

  [[ ! -f "$REF_IMG" ]] && { echo "❌ Référence absente : $REF_IMG"; continue; }

  REF_ID=$(basename "$REF_IMG" | sed -E 's/\.nii(\.gz)?$//' | cut -d_ -f1-3)
  OUTPUT_FINAL="${FINAL_DIR}/${BASE}_to_${REF_ID}_Affine_Warped.nii.gz"

  if [[ "${IMG}" == "${REF_IMG}" ]]; then
    echo "⏩ ${BASE} est une référence ($REF_ID), skip."
    continue
  fi
  if [[ -f "${OUTPUT_FINAL}" ]]; then
    echo "⏩ ${BASE} déjà alignée, skip."
    continue
  fi

  echo "=== Traitement de ${BASE} → référence : ${REF_ID} ==="
  echo "→ Rigid registration..."
  antsRegistration \
    -d 3 \
    -r "[${REF_IMG},${IMG},1]" \
    -f 4x2 \
    -s 2x1 \
    -m "MI[${REF_IMG},${IMG},1,32,Regular,0.25]" \
    -t "Rigid[0.1]" \
    -c "[50x25,1e-6,5]" \
    -v 1 \
    -o "[${REG_DIR}/${BASE}_to_${REF_ID}_Rigid_,${REG_DIR}/${BASE}_to_${REF_ID}_Rigid_Warped.nii.gz]"

  echo "→ Affine registration..."
  antsRegistration \
    -d 3 \
    -r "[${REF_IMG},${REG_DIR}/${BASE}_to_${REF_ID}_Rigid_Warped.nii.gz,1]" \
    -f 4x2 \
    -s 2x1 \
    -m "MI[${REF_IMG},${REG_DIR}/${BASE}_to_${REF_ID}_Rigid_Warped.nii.gz,1,32,Regular,0.25]" \
    -t "Affine[0.1]" \
    -c "[1000x500,1e-6,10]" \
    -v 1 \
    -o "[${REG_DIR}/${BASE}_to_${REF_ID}_Affine_,${OUTPUT_FINAL}]"

  echo "→ Alignement terminé pour ${BASE}"
  echo "  ✓ ${OUTPUT_FINAL}"
  echo "  → Matrices dans ${REG_DIR}"
done

echo "Nettoyage : suppression des images rigides warpées intermédiaires…"
shopt -s nullglob
FILES_TO_REMOVE=("${REG_DIR}"/*Rigid_Warped.nii.gz)
if (( ${#FILES_TO_REMOVE[@]} )); then
  rm -v "${FILES_TO_REMOVE[@]}"
else
  echo "Aucun fichier intermédiaire à supprimer."
fi

echo "✅ Terminé : alignements faits, matrices conservées."
deactivate
