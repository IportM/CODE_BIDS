#!/usr/bin/env bash

source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate
set -euo pipefail

# ← ← ← À modifier ici avec vos chemins bruts → → →
BRAIN_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted"

REF_IMG_SES_1_2="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/sub-01_ses-1_RARE_brain_extracted.nii.gz"
REF_IMG_SES_3_4="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/sub-01_ses-3_RARE_brain_extracted.nii.gz"
REF_IMG_SES_5_6="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/sub-01_ses-5_RARE_brain_extracted.nii.gz"

TRANSFORM_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/matrice_transformsSyN"
# ← ← ← fin des chemins à configurer → → →

[[ -d "$BRAIN_DIR" ]]     || { echo "ERROR: BRAIN_DIR introuvable"; exit 1; }
[[ -d "$TRANSFORM_DIR" ]] || { echo "ERROR: TRANSFORM_DIR introuvable"; exit 1; }

echo "=== Début alignement (toutes modalités vers RARE alignée aux refs) ==="

find "$BRAIN_DIR" \
  -type d -name aligned -prune -o \
  -type f \( -iname '*_masked.nii' -o -iname '*_masked.nii.gz' \) -print \
| while read -r IMG; do

  # On ne traite pas ce qui est déjà dans /aligned
  if [[ "$(basename "$(dirname "$IMG")")" == "aligned" ]]; then
    continue
  fi

  IMG_BASE=$(basename "$IMG" | sed -e 's/\.nii\.gz$//' -e 's/\.nii$//')
  SUBSES=$(echo "$IMG_BASE" | cut -d_ -f1-2)     # ex: sub-02_ses-1
  RARE_BASE="${SUBSES}_RARE_brain_extracted"     # nom de la RARE
  ACQ=$(basename "$(dirname "$IMG")")           # ex: T1map, T2starmap, QSM, ...

  # Cherche la RARE correspondante
  RARE_FILE=$(find "$BRAIN_DIR/RARE" -type f -iname "${RARE_BASE}.*nii*" | head -n1 || true)
  if [[ -z "$RARE_FILE" ]]; then
    echo "! Pas de RARE pour $SUBSES, skip."
    continue
  fi

  # Numéro de session
  SES_NUM=$(echo "$SUBSES" | grep -oP 'ses-\K[0-9]+')

  # Sélection de la ref (même logique que le script antsRegistrationSyN.sh)
  if [[ "$SES_NUM" -eq 1 || "$SES_NUM" -eq 2 ]]; then
    REF_IMG="$REF_IMG_SES_1_2"
  elif [[ "$SES_NUM" -eq 3 || "$SES_NUM" -eq 4 ]]; then
    REF_IMG="$REF_IMG_SES_3_4"
  elif [[ "$SES_NUM" -eq 5 || "$SES_NUM" -eq 6 ]]; then
    REF_IMG="$REF_IMG_SES_5_6"
  else
    echo "! Session inconnue ($SES_NUM), skip."
    continue
  fi

  REF_BASENAME=$(basename "$REF_IMG")
  REF_ID=$(echo "$REF_BASENAME" | sed -E 's/\.nii(\.gz)?$//' | cut -d_ -f1-3)

  # ⚠️ NOUVEAU : fichiers de transform produits par antsRegistrationSyN.sh
  AFFINE_MAT="${TRANSFORM_DIR}/${RARE_BASE}_to_${REF_ID}_0GenericAffine.mat"
  WARP_FIELD="${TRANSFORM_DIR}/${RARE_BASE}_to_${REF_ID}_1Warp.nii.gz"  # présent seulement si -t s

  if [[ ! -f "$AFFINE_MAT" && ! -f "$WARP_FIELD" ]]; then
    echo "! Aucune transform trouvée (ni affine ni warp) pour $SUBSES, skip."
    continue
  fi

  # Prépare la liste des -t dans le bon ordre (warp puis affine si warp existe)
  TRANSFORMS=()
  if [[ -f "$WARP_FIELD" ]]; then
    TRANSFORMS=(-t "$WARP_FIELD" -t "$AFFINE_MAT")
  else
    TRANSFORMS=(-t "$AFFINE_MAT")
  fi

  OUT_DIR="$(dirname "$IMG")/alignedSyN"
  mkdir -p "$OUT_DIR"

  # Nom de sortie
  OUT_FILE="${OUT_DIR}/${IMG_BASE}_aligned_to_${REF_ID}.nii.gz"

  # Skip si déjà fait
  if [[ -f "$OUT_FILE" ]]; then
    echo "⏩ $IMG_BASE déjà alignée, skip."
    continue
  fi

  echo "→ Aligning $IMG_BASE vers $REF_ID  (ref = $REF_IMG)"

  if [[ "$ACQ" == "T2starmap" || "$ACQ" == "QSM" ]]; then
    hdr_img="${OUT_DIR}/${IMG_BASE}_hdr.nii.gz"
    echo "  → Copie des entêtes de $RARE_FILE vers $IMG dans $hdr_img"

    CopyImageHeaderInformation "$RARE_FILE" "$IMG" "$hdr_img" 1 1 1

    antsApplyTransforms \
      -d 3 \
      -i "$hdr_img" \
      -r "$REF_IMG" \
      -o "$OUT_FILE" \
      -n Linear \
      --float 1 \
      "${TRANSFORMS[@]}"

    rm -f "$hdr_img"
    echo "  ✓ (T2starmap/QSM) $OUT_FILE"
  else
    antsApplyTransforms \
      -d 3 \
      -i "$IMG" \
      -r "$REF_IMG" \
      -o "$OUT_FILE" \
      -n BSpline[3] \
      --float 1 \
      "${TRANSFORMS[@]}"

    echo "  ✓ $OUT_FILE"
  fi
done

echo "=== Alignement terminé ==="
deactivate
