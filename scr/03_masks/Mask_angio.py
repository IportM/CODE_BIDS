#!/usr/bin/env python3
import os
import glob
import ants


# ---------------------------------------------------------------------
# Resolve paths relative to this script (portable)
# ---------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# If this script is located in: <repo>/scr/03_masks/Mask_angio.py
# then repo root is 2 levels up: 03_masks -> scr -> repo
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))

BIDS_DIR = os.path.join(PROJECT_ROOT, "BIDS")
DERIV_DIR = os.path.join(BIDS_DIR, "derivatives")

# Output directory
OUTPUT_DIR = os.path.join(DERIV_DIR, "Brain_extracted", "angio")
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Masks are stored in derivatives/<sub>/<ses>/anat/*_RARE_mask_final.nii.gz
mask_paths = glob.glob(os.path.join(DERIV_DIR, "sub-*", "ses-*", "anat", "*_RARE_mask_final.nii.gz"))

print(f"🔍 {len(mask_paths)} masques trouvés dans: {DERIV_DIR}")

for mask_path in mask_paths:
    try:
        base = os.path.basename(mask_path)
        parts = base.split("_")
        if len(parts) < 2:
            print(f"❗ Nom de masque inattendu (skip): {base}")
            continue

        sub_id = parts[0]  # sub-XX
        ses_id = parts[1]  # ses-YY

        angio_path = os.path.join(BIDS_DIR, sub_id, ses_id, "anat", f"{sub_id}_{ses_id}_angio.nii.gz")
        if not os.path.exists(angio_path):
            print(f"❌ Angio non trouvée : {angio_path}")
            continue

        print(f"✅ Traitement de {sub_id} {ses_id}")

        mask = ants.image_read(mask_path)
        angio = ants.image_read(angio_path)

        # Resample angio into mask space
        angio_resampled = ants.resample_image_to_target(angio, mask, interp_type="linear")

        # Binary mask + apply
        mask_bin = mask > 0.5
        angio_masked = angio_resampled * mask_bin

        output_file = os.path.join(OUTPUT_DIR, f"{sub_id}_{ses_id}_angio_masked.nii.gz")
        angio_masked.to_filename(output_file)

        print(f"💾 Sauvegardé : {output_file}")

    except Exception as e:
        print(f"❗ Erreur pour {mask_path} : {e}")
