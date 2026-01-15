#!/bin/bash
# source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate

# Où se trouve ce script (chemin absolu)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Project root = 2 niveaux au-dessus (car scr/XX/)
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Dossiers “standards” produits par ton pipeline
BIDS_DIR="${BIDS_DIR:-$PROJECT_ROOT/BIDS}"
DERIV_DIR="${DERIV_DIR:-$BIDS_DIR/derivatives}"
BRAIN_EXTRACTED_DIR="${BRAIN_EXTRACTED_DIR:-$DERIV_DIR/Brain_extracted}"

# Dossier contenant les images
INPUT_DIR="$BRAIN_EXTRACTED_DIR/T2starmap/alignedSyN_Allen"   # <-- change ce chemin si nécessaire
OUTPUT_DIR="$BRAIN_EXTRACTED_DIR/T2starmap/alignedSyN_Allen/seuil"

# Crée le dossier de sortie s'il n'existe pas
mkdir -p "$OUTPUT_DIR"

# Paramètres de troncature
LOW=0
HIGH=80
  
# Boucle sur chaque fichier .nii ou .nii.gz
for file in "$INPUT_DIR"/*_aligned_*.nii*; do
  # Extraire le nom de base du fichier
  filename=$(basename "$file")
  
  # Définir le chemin de sortie
  output_file="$OUTPUT_DIR/$filename"

  # Appliquer TruncateImageIntensity
  echo "Traitement de $filename ..."
  ImageMath 3 "$output_file" TruncateImageIntensity "$file" $LOW $HIGH 1
done

echo "Terminé. Images enregistrées dans : $OUTPUT_DIR"
# deactivate