#!/usr/bin/env bash

# source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate
set -euo pipefail

# ─────────────────────────────────────────────
# 📂 Chemins à adapter si besoin
# ─────────────────────────────────────────────
# Où se trouve ce script (chemin absolu)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project root = 2 niveaux au-dessus (car scr/XX/)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Dossiers “standards” produits par ton pipeline
BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

BRAIN_DIR="$BRAIN_EXTRACTED_DIR"

# 🔹 Même template Allen que dans ton script RARE→Allen
ALLEN_TEMPLATE="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/Allen/LR/100_AMBA_ref.nii.gz"

# 🔹 Dossier où antsRegistrationSyN.sh a mis les transforms RARE→Allen
TRANSFORM_DIR="$BRAIN_EXTRACTED_DIR/RARE/matrice_transformsSyN_Allen"

# ─────────────────────────────────────────────

[[ -d "$BRAIN_DIR" ]]     || { echo "ERROR: BRAIN_DIR introuvable"; exit 1; }
[[ -d "$TRANSFORM_DIR" ]] || { echo "ERROR: TRANSFORM_DIR introuvable"; exit 1; }
[[ -f "$ALLEN_TEMPLATE" ]] || { echo "ERROR: ALLEN_TEMPLATE introuvable"; exit 1; }

ALLEN_ID=$(basename "$ALLEN_TEMPLATE" | sed -E 's/\.nii(\.gz)?$//')

echo "=== Début alignement (toutes modalités vers template Allen) ==="
echo "→ Template Allen : $ALLEN_TEMPLATE (ID = $ALLEN_ID)"

# On évite de redescendre dans les dossiers déjà alignés
find "$BRAIN_DIR" \
  -type d \( -name aligned -o -name alignedSyN -o -name alignedSyN_Allen \) -prune -o \
  -type f \( -iname '*_masked.nii' -o -iname '*_masked.nii.gz' \) -print \
| while read -r IMG; do

  # On ne traite pas ce qui est déjà dans /aligned*/ (sécurité en plus du -prune)
  PARENT_DIR_BASENAME=$(basename "$(dirname "$IMG")")
  if [[ "$PARENT_DIR_BASENAME" == aligned* ]]; then
    continue
  fi

  IMG_BASE=$(basename "$IMG" | sed -e 's/\.nii\.gz$//' -e 's/\.nii$//')
  SUBSES=$(echo "$IMG_BASE" | cut -d_ -f1-2)     # ex: sub-02_ses-1
  RARE_BASE="${SUBSES}_RARE_brain_extracted"     # nom de la RARE
  ACQ=$(basename "$(dirname "$IMG")")           # ex: T1map, T2starmap, QSM, ...

  # Cherche la RARE correspondante (dans le dossier RARE)
  RARE_FILE=$(find "$BRAIN_DIR/RARE" -type f -iname "${RARE_BASE}.*nii*" | head -n1 || true)
  if [[ -z "$RARE_FILE" ]]; then
    echo "! Pas de RARE pour $SUBSES, skip."
    continue
  fi

  # ⚠️ Transforms RARE → Allen (produites par ton script RARE→Allen)
  AFFINE_MAT="${TRANSFORM_DIR}/${RARE_BASE}_to_${ALLEN_ID}_0GenericAffine.mat"
  WARP_FIELD="${TRANSFORM_DIR}/${RARE_BASE}_to_${ALLEN_ID}_1Warp.nii.gz"  # présent seulement si -t s

  if [[ ! -f "$AFFINE_MAT" && ! -f "$WARP_FIELD" ]]; then
    echo "! Aucune transform trouvée (ni affine ni warp) pour $SUBSES, skip."
    continue
  fi

  # Liste des -t dans le bon ordre (warp puis affine si warp existe)
  TRANSFORMS=()
  if [[ -f "$WARP_FIELD" ]]; then
    TRANSFORMS=(-t "$WARP_FIELD" -t "$AFFINE_MAT")
  else
    TRANSFORMS=(-t "$AFFINE_MAT")
  fi

  # Dossier de sortie : on choisit alignedSyN_Allen pour être cohérent
  OUT_DIR="$(dirname "$IMG")/alignedSyN_Allen"
  mkdir -p "$OUT_DIR"

  # Nom de sortie
  OUT_FILE="${OUT_DIR}/${IMG_BASE}_aligned_to_${ALLEN_ID}.nii.gz"

  # Skip si déjà fait
  if [[ -f "$OUT_FILE" ]]; then
    echo "⏩ $IMG_BASE déjà alignée vers Allen, skip."
    continue
  fi

  echo "→ Aligning $IMG_BASE vers Allen (ref = $ALLEN_TEMPLATE)"

  # Cas particuliers T2starmap / QSM : copie d'entête depuis la RARE avant transform
  if [[ "$ACQ" == "T2starmap" || "$ACQ" == "QSM" ]]; then
    hdr_img="${OUT_DIR}/${IMG_BASE}_hdr.nii.gz"
    echo "  → Copie des entêtes de $RARE_FILE vers $IMG dans $hdr_img"

    CopyImageHeaderInformation "$RARE_FILE" "$IMG" "$hdr_img" 1 1 1

    antsApplyTransforms \
      -d 3 \
      -i "$hdr_img" \
      -r "$ALLEN_TEMPLATE" \
      -o "$OUT_FILE" \
      -n BSpline[3] \
      --float 1 \
      "${TRANSFORMS[@]}"

    rm -f "$hdr_img"
    echo "  ✓ (T2starmap/QSM) $OUT_FILE"
  else
    antsApplyTransforms \
      -d 3 \
      -i "$IMG" \
      -r "$ALLEN_TEMPLATE" \
      -o "$OUT_FILE" \
      -n BSpline[3] \
      --float 1 \
      "${TRANSFORMS[@]}"

    echo "  ✓ $OUT_FILE"
  fi
done

echo "=== Alignement terminé (toutes modalités en espace Allen) ==="
# deactivate
