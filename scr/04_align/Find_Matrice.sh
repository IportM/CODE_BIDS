#!/usr/bin/env bash

# Activation de FSL
# source /home/CODE/fsl/bin/activate  # Remplace par source /etc/fsl/fsl.sh si besoin
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

# ← ← ← À modifier ici avec vos chemins bruts → → →
BRAIN_DIR="$BRAIN_EXTRACTED_DIR"
# REF_IMG="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/sub-01_ses-1_RARE_brain_extracted.nii.gz"
REF_IMG_SES_1_2="$BRAIN_EXTRACTED_DIR/RARE/sub-01_ses-1_RARE_brain_extracted.nii.gz"
REF_IMG_SES_3_4="$BRAIN_EXTRACTED_DIR/RARE/sub-01_ses-3_RARE_brain_extracted.nii.gz"
# REF_IMG_SES_5_6="/path/to/sub-01_ses-5_RARE_brain_extracted.nii.gz"
TRANSFORM_DIR="$BRAIN_EXTRACTED_DIR/RARE/matrice_transforms"
# ← ← ← fin des chemins à configurer → → →

# Vérifications
[[ -d "$BRAIN_DIR" ]]     || { echo "ERROR: BRAIN_DIR introuvable"; exit 1; }
[[ -d "$TRANSFORM_DIR" ]] || { echo "ERROR: TRANSFORM_DIR introuvable"; exit 1; }

# command -v fslhd >/dev/null || { echo "ERROR: fslhd non disponible. FSL est-il activé ?"; exit 1; }

echo "=== Début alignement (traitement y compris RARE, en ignorant uniquement 'aligned') ==="

find "$BRAIN_DIR" \
  -type d -name aligned -prune -o \
  -type f \( -iname '*_masked.nii' -o -iname '*_masked.nii.gz' \) -print \
| while read -r IMG; do

  if [[ "$(basename "$(dirname "$IMG")")" == "aligned" ]]; then
    continue
  fi

  IMG_BASE=$(basename "$IMG" | sed -e 's/\.nii\.gz$//' -e 's/\.nii$//')
  SUBSES=$(echo "$IMG_BASE" | cut -d_ -f1-2)
  RARE_BASE="${SUBSES}_RARE_brain_extracted"
  ACQ=$(basename "$(dirname "$IMG")")

  RARE_FILE=$(find "$BRAIN_DIR/RARE" -type f -iname "${RARE_BASE}.*nii*" | head -n1 || true)
  if [[ -z "$RARE_FILE" ]]; then
    echo "! Pas de RARE pour $SUBSES, skip."
    continue
  fi

  # Identifier le numéro de session
  SES_NUM=$(echo "$SUBSES" | grep -oP 'ses-\K[0-9]+')

  # Sélection de l'image de référence en fonction de la session
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

  MAT_RIGID="${TRANSFORM_DIR}/${RARE_BASE}_to_${REF_ID}_Rigid_0GenericAffine.mat"
  MAT_AFFN="${TRANSFORM_DIR}/${RARE_BASE}_to_${REF_ID}_Affine_0GenericAffine.mat"
  if [[ ! -f "$MAT_RIGID" || ! -f "$MAT_AFFN" ]]; then
    echo "! Matrices manquantes pour $SUBSES, skip."
    continue
  fi

  OUT_DIR="$(dirname "$IMG")/aligned"
  mkdir -p "$OUT_DIR"
  
  # Extraction de l'identifiant court de la référence (ex: sub-01_ses-1_RARE)
  REF_BASENAME=$(basename "$REF_IMG")
  REF_ID=$(echo "$REF_BASENAME" | sed -E 's/\.nii(\.gz)?$//' | cut -d_ -f1-3)

  # Nouveau nom de sortie
  OUT_FILE="${OUT_DIR}/${IMG_BASE}_aligned_to_${REF_ID}.nii.gz"



  # ✅ Vérifie si l'image a déjà été traitée
  if [[ -f "$OUT_FILE" ]]; then
    echo "⏩ $IMG_BASE déjà alignée, skip."
    continue
  fi

  echo "→ Aligning $IMG_BASE"

  if [[ "$ACQ" == "T2starmap" || "$ACQ" == "QSM" ]]; then
    hdr_img="${OUT_DIR}/${IMG_BASE}_hdr.nii.gz"
    echo "  → Copie des entêtes de $RARE_FILE vers $IMG dans $hdr_img"

    CopyImageHeaderInformation "$RARE_FILE" "$IMG" "$hdr_img" 1 1 1

    # echo "  → Extraction des qoffsets de $RARE_FILE"
    # read qoffset_x qoffset_y qoffset_z < <(
    #   fslhd "$RARE_FILE" | awk '
    #     /qoffset_x/ { x=$2 }
    #     /qoffset_y/ { y=$2 }
    #     /qoffset_z/ { z=$2 }
    #     END {
    #       if (x == "" || y == "" || z == "") exit 1;
    #       print x, y, z;
    #     }
    #   '
    # ) || { echo "❌ Erreur : qoffsets manquants dans $RARE_FILE, skip."; continue; }

    # # Ajout des qoffsets
    # fslorient -setsformcode 1 "$hdr_img"
    # fslorient -setqformcode 1 "$hdr_img"
    # fslorient -setqoffset "$qoffset_x" "$qoffset_y" "$qoffset_z" "$hdr_img"

    # echo "  → qoffset appliqués : $qoffset_x $qoffset_y $qoffset_z"
    # fslhd "$hdr_img" | grep 'qoffset_'

    antsApplyTransforms \
      -d 3 \
      -i "$hdr_img" \
      -r "$REF_IMG" \
      -o "$OUT_FILE" \
      -n BSpline[3] \
      --float 1 \
      -t "$MAT_AFFN" \
      -t "$MAT_RIGID"

     rm -f "$hdr_img"
    echo "  ✓ (T2starmap) $OUT_FILE"
  else
    # Traitement standard
    antsApplyTransforms \
      -d 3 \
      -i "$IMG" \
      -r "$REF_IMG" \
      -o "$OUT_FILE" \
      -n BSpline[3] \
      --float 1 \
      -t "$MAT_AFFN" \
      -t "$MAT_RIGID"

    echo "  ✓ $OUT_FILE"
  fi
done

echo "=== Alignement terminé ==="
deactivate