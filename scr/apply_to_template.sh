#!/bin/bash

# === CHECK ARGUMENTS ===
if [ $# -lt 1 ]; then
  echo "Usage: $0 <modalite>"
  echo "Exemple: $0 Angio"
  exit 1
fi

MODALITY="$1"

# Dossier d'entrée : cas particulier pour T2starmap
if [ "$MODALITY" == "T2starmap" ]; then
  DATA_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/T2starmap/aligned/seuil"
else
  DATA_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/${MODALITY}/aligned"
fi

# Dossier racine de sortie
OUTPUT_BASE="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/${MODALITY}/To_Template"

# === LOOP THROUGH ALL FILES (only top-level, no subfolders) ===
for map_file in "$DATA_DIR"/*.nii.gz; do
  # Skip files in subfolders (safety check)
  if [[ "$(dirname "$map_file")" != "$DATA_DIR" ]]; then
    continue
  fi

  map_name=$(basename "$map_file")

  # Extract subject and session from filename
  if [[ "$map_name" =~ ^(sub-[0-9]+)_ses-([0-9]+)_(.+)\.nii\.gz$ ]]; then
    sub="${BASH_REMATCH[1]}"
    ses_num="${BASH_REMATCH[2]}"
    ses="ses-${ses_num}"
    map_suffix="${BASH_REMATCH[3]}"
  else
    echo "❌ Filename doesn't match expected pattern: $map_name"
    continue
  fi

  # Choisir le groupe en fonction de la session
  if [[ "$ses_num" == "1" || "$ses_num" == "2" ]]; then
    group="S01"
  elif [[ "$ses_num" == "3" || "$ses_num" == "4" ]]; then
    group="S02"
  elif [[ "$ses_num" == "5" || "$ses_num" == "6" ]]; then
    group="S03"
  else
    echo "⚠️  Session inconnue ($ses_num) pour $map_name. Skipping."
    continue
  fi

  # === CONFIGURATION dépendante du groupe ===
  TEMPLATE="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/${group}/template/0.1/template/RARE_template_template0.nii.gz"
  TRANSFORM_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/RARE/${group}/template/0.1/template"

  # Créer le bon dossier de sortie
  OUTPUT_DIR="${OUTPUT_BASE}/${group}"
  mkdir -p "$OUTPUT_DIR"

  echo "➤ Processing $sub $ses ($map_suffix) → $group"

  # Dynamically find the transform files
  warp=$(find "$TRANSFORM_DIR" -maxdepth 1 -name "*${sub}_${ses}*_RARE*1Warp.nii.gz" | head -n 1)
  affine=$(find "$TRANSFORM_DIR" -maxdepth 1 -name "*${sub}_${ses}*_RARE*0GenericAffine.mat" | head -n 1)

  if [[ ! -f "$warp" || ! -f "$affine" ]]; then
    echo "⚠️  Missing transform for $sub $ses in $group. Skipping."
    continue
  fi

  echo "  ✅ Found transform:"
  echo "     Warp:    $warp"
  echo "     Affine:  $affine"

  # Output path
  output_file="${OUTPUT_DIR}/${sub}_${ses}_${map_suffix}_in_template.nii.gz"

  # Apply transform
  antsApplyTransforms -d 3 \
    -i "$map_file" \
    -o "$output_file" \
    -r "$TEMPLATE" \
    -t "$warp" \
    -t "$affine" \
    --interpolation NearestNeighbor

  echo "✅ Saved to $output_file"
done
