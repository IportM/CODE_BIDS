import ants
import os
import argparse

EXCLUSION_LIST = [
    "sub-07_ses-3",
]

def main():
    parser = argparse.ArgumentParser(
        description="Appliquer un masque sur une image avec ANTs en utilisant des chemins passés en arguments."
    )
    parser.add_argument(
        "--mask",
        required=True,
        help="Chemin complet vers l'image mask (ex: sub-01_ses-1_RARE_mask_final.nii.gz)."
    )
    parser.add_argument(
        "--acq",
        required=True,
        help="Chemin complet vers l'image d'acquisition (ex: mod_sub-01_ses-1_T1map.nii.gz)."
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Chemin complet où sauvegarder l'image masquée (ex: sub-01_ses-1_T1map_masked.nii.gz)."
    )
    
    args = parser.parse_args()
    
    # 🛑 Vérification exclusion
    filename = os.path.basename(args.acq)  # nom du fichier acquisition
    if any(exclusion in filename for exclusion in EXCLUSION_LIST):
        print(f"⚠️ Sujet exclu ({filename}), aucun traitement effectué.")
        return
    
    # Vérifie si le fichier de sortie existe déjà
    if os.path.exists(args.output):
        print(f"L'image masquée existe déjà : {args.output} — aucune opération effectuée.")
        return
    
    # Lecture du mask et de l'image d'acquisition via ANTs
    mask_img = ants.image_read(args.mask)
    acq_img = ants.image_read(args.acq)
    
    # Application du mask par multiplication voxel par voxel
    masked_img = acq_img * mask_img
    
    # Création du répertoire de sortie s'il n'existe pas
    output_dir = os.path.dirname(args.output)
    os.makedirs(output_dir, exist_ok=True)
    
    # Sauvegarde de l'image masquée
    ants.image_write(masked_img, args.output)
    
    print(f"Mask appliqué avec succès : {args.output}")

if __name__ == "__main__":
    main()
