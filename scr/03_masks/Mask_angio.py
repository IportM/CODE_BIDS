import ants
import os
import glob


# ✅ Dossier contenant tous les masques
mask_dir = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives"

# ✅ Dossier contenant toutes les angio (dans l’arborescence BIDS)
angio_dir = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS"

# ✅ Répertoire de sortie
output_dir = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/angio"
os.makedirs(output_dir, exist_ok=True)

# 🔍 Lister tous les masques dans l’arborescence derivatives
mask_paths = glob.glob(os.path.join(mask_dir, "sub-*", "ses-*", "anat", "*_RARE_mask_final.nii.gz"))

print(f"🔍 {len(mask_paths)} masques trouvés.")

for mask_path in mask_paths:
    try:
        # Extraire sub-XX et ses-XX depuis le nom
        basename = os.path.basename(mask_path)
        parts = basename.split('_')
        sub_id = parts[0]  # sub-XX
        ses_id = parts[1]  # ses-XX

        # Construire chemin vers image angio correspondante
        angio_path = os.path.join(angio_dir, sub_id, ses_id, "anat", f"{sub_id}_{ses_id}_angio.nii.gz")

        if not os.path.exists(angio_path):
            print(f"❌ Angio non trouvée : {angio_path}")
            continue

        print(f"✅ Traitement de {sub_id} {ses_id}")

        # Lire les images
        mask = ants.image_read(mask_path)
        angio = ants.image_read(angio_path)

        # Resample de l’image angio dans l’espace du masque
        angio_resampled = ants.resample_image_to_target(angio, mask, interp_type='linear')

        # Appliquer le masque binaire
        mask_bin = mask > 0.5
        angio_masked = angio_resampled * mask_bin

        # Sauvegarde
        output_file = os.path.join(output_dir, f"{sub_id}_{ses_id}_angio_masked.nii.gz")
        angio_masked.to_filename(output_file)

        print(f"💾 Sauvegardé : {output_file}")

    except Exception as e:
        print(f"❗ Erreur pour {mask_path} : {e}")
