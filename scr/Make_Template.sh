#!/bin/bash

# === CHECK ARGUMENTS ===
if [ $# -lt 1 ]; then
  echo "Usage: $0 <modalite>"
  echo "Exemple: $0 Angio"
  exit 1
fi

MODALITY="$1"

# === CONFIGURATION ===
INPUT_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/${MODALITY}/To_Template"

# pattern de recherche : sensible à la modalité
PATTERN="*${MODALITY}*.nii.gz"

# === LOOP OVER SUBJECTS ===
for subj_dir in "$INPUT_DIR"/S*/; do
  subj=$(basename "$subj_dir")
  echo "🔎 Sujet trouvé : $subj"

  # créer le dossier template du sujet
  OUTPUT_DIR="${subj_dir}/template"
  mkdir -p "$OUTPUT_DIR"

  # récupérer les fichiers correspondant à ce sujet
  map_files=()
  while IFS= read -r -d '' file; do
    map_files+=("$file")
  done < <(find "$subj_dir" -name "$PATTERN" -print0)

  # check
  if [[ ${#map_files[@]} -eq 0 ]]; then
    echo "⚠️ Aucun fichier trouvé pour $subj ($PATTERN)"
    continue
  fi

  # moyenne
  echo "🧠 Moyenne de ${#map_files[@]} fichiers pour $subj ($MODALITY)..."
  OUTPUT_FILE="${OUTPUT_DIR}/${subj}_${MODALITY}_avg.nii.gz"
  AverageImages 3 "$OUTPUT_FILE" 0 "${map_files[@]}"
  echo "✅ Fichier généré : $OUTPUT_FILE"
done
