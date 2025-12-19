#!/usr/bin/env python3
import nibabel as nib
import numpy as np
import glob
import os
import sys

# if len(sys.argv) != 3:
#     print(f"Usage : {sys.argv[0]} <input_dir> <output_dir>")
#     print("  <input_dir>  : dossier contenant les images déjà alignées sur Allen")
#     print("  <output_dir> : dossier où sauver les templates (mean/median)")
#     sys.exit(1)

INPUT_DIR = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/angio/alignedSyN_Allen"
OUTPUT_DIR = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/angio/Template_in_Allen"

if not os.path.isdir(INPUT_DIR):
    raise SystemExit(f"❌ Dossier d'entrée introuvable : {INPUT_DIR}")

os.makedirs(OUTPUT_DIR, exist_ok=True)

print(f"📂 Dossier d'entrée : {INPUT_DIR}")
print(f"📂 Dossier de sortie : {OUTPUT_DIR}")

# On cherche des fichiers type sub-XX_ses-YY_*.nii(.gz) alignés sur Allen
files = sorted(
    glob.glob(os.path.join(INPUT_DIR, "sub-*_ses-*.nii.gz"))
    + glob.glob(os.path.join(INPUT_DIR, "sub-*_ses-*.nii"))
)

print(f"→ {len(files)} fichiers trouvés")
if len(files) == 0:
    raise SystemExit("❌ Aucun fichier trouvé, vérifie le chemin et le pattern.")

data_list = []
ref_img = None

for f in files:
    print(f"  - load {os.path.basename(f)}")
    img = nib.load(f)
    if ref_img is None:
        ref_img = img
    data = img.get_fdata(dtype=np.float32)
    data_list.append(data)

stack = np.stack(data_list, axis=-1)   # (X, Y, Z, Nsubjects)

print("→ Calcul de la moyenne...")
mean_data = stack.mean(axis=-1)

print("→ Calcul de la médiane...")
median_data = np.median(stack, axis=-1)

# Sauvegarde en template moyen
mean_img = nib.Nifti1Image(mean_data, ref_img.affine, ref_img.header)
mean_path = os.path.join(OUTPUT_DIR, "group_template_mean_in_Allen.nii.gz")
mean_img.to_filename(mean_path)
print(f"✅ Template mean sauvegardé : {mean_path}")

# Sauvegarde en template médian
median_img = nib.Nifti1Image(median_data, ref_img.affine, ref_img.header)
median_path = os.path.join(OUTPUT_DIR, "group_template_median_in_Allen.nii.gz")
median_img.to_filename(median_path)
print(f"✅ Template median sauvegardé : {median_path}")

print("🎉 Terminé.")
