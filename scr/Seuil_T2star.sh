#!/bin/bash
source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate
# Dossier contenant les images
INPUT_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/T2starmap/alignedSyN_Allen"   # <-- change ce chemin si nécessaire
OUTPUT_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/T2starmap/alignedSyN_Allen/seuil"

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
deactivate