#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

BIDS_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS"   # <-- à adapter

# Liste: "SUB SES MOD"
ITEMS=(
  "01 3 T2map"
  "02 3 T2map"
  "03 3 T2map"
  "04 4 T2map"
  "05 1 T2map"
  "06 3 T2map"
  "07 3 T2map"
  "08 4 T2map"
  "14 3 T2map"
  "15 3 T2map"
)

for it in "${ITEMS[@]}"; do
  read -r SUB SES MOD <<< "$it"

  SUB_ID="sub-${SUB}"
  SES_ID="ses-${SES}"
  ANAT_DIR="${BIDS_DIR}/${SUB_ID}/${SES_ID}/anat"

  IN_FILE="${ANAT_DIR}/${SUB_ID}_${SES_ID}_${MOD}.nii.gz"
  TMP_FILE="${ANAT_DIR}/.${SUB_ID}_${SES_ID}_${MOD}_tmp.nii.gz"

  if [[ ! -f "$IN_FILE" ]]; then
    echo "[WARN] Introuvable: $IN_FILE" >&2
    continue
  fi

  echo "[INFO] Overwrite: $IN_FILE"

  # flip puis strides, écrit dans tmp
  mrtransform "$IN_FILE" -flip 1 - \
    | mrconvert - -strides 1,2,3 "$TMP_FILE" -force

  # remplace l'original (atomique sur même filesystem)
#   mv -f "$TMP_FILE" "$IN_FILE"
done

echo "[DONE] Terminé."
