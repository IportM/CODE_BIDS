# -*- coding: utf-8 -*-
#!/usr/bin/env python3
import os
import argparse
import ants
import antspynet

import ants
import antspynet
import os

def process_file(input_path, output_path, Brain_PATH):
    """
    Pipeline amélioré :
    - Double correction N4 (2 passes consécutives)
    - Extraction probabiliste du cerveau (antspynet)
    - Seuillage adaptatif (Otsu)
    - Morphologie : érosion + plus grande composante + dilatation + FillHoles
    """
    base_name = os.path.basename(input_path)
    if base_name.endswith('.nii.gz'):
        base_name = base_name[:-7]
    elif base_name.endswith('.nii'):
        base_name = base_name[:-4]
    
    print(f"Lecture de l'image : {input_path}")
    image = ants.image_read(input_path)

    # Dossier des étapes
    output_dir = os.path.dirname(output_path)
    step_dir = os.path.join(output_dir, "step")
    os.makedirs(step_dir, exist_ok=True)
    step_counter = 1

    # 0. Sauvegarde de l'image brute
    ants.image_write(image, os.path.join(step_dir, f"{base_name}_step{step_counter}_input.nii.gz"))
    step_counter += 1

    # 1. Correction N4 (première passe)
    print("Correction du champ de biais N4ITK (1ère passe)...")
    image = ants.n4_bias_field_correction(
        image,
        shrink_factor=4,
        convergence={'iters':[20,20,10], 'tol':1e-6}
    )
    ants.image_write(image, os.path.join(step_dir, f"{base_name}_step{step_counter}_n4_pass1.nii.gz"))
    step_counter += 1

    # 2. Correction N4 (deuxième passe, directement après la première)
    print("Correction du champ de biais N4ITK (2ème passe)...")
    image = ants.n4_bias_field_correction(
        image,
        shrink_factor=2,
        convergence={'iters':[30,20,10], 'tol':1e-6}
    )
    ants.image_write(image, os.path.join(step_dir, f"{base_name}_step{step_counter}_n4_pass2.nii.gz"))
    step_counter += 1

    # 3. Extraction cerveau (probabilité)
    print("Extraction du cerveau (antspynet)...")
    proba_image = antspynet.mouse_brain_extraction(image)
    ants.image_write(proba_image, os.path.join(step_dir, f"{base_name}_step{step_counter}_proba.nii.gz"))
    step_counter += 1

    # 4. Seuillage adaptatif (Otsu)
    print("Seuillage adaptatif (méthode Otsu)...")
    mask = ants.threshold_image(proba_image, "Otsu", 1, 0)
    ants.image_write(mask, os.path.join(step_dir, f"{base_name}_step{step_counter}_otsu.nii.gz"))
    step_counter += 1

    # 5. Morphologie : érosion
    print("Érosion appliquée...")
    mask_eroded = ants.iMath(mask, "ME", 6)  # rayon 3 voxels
    ants.image_write(mask_eroded, os.path.join(step_dir, f"{base_name}_step{step_counter}_eroded.nii.gz"))
    step_counter += 1

    # 6. Plus grande composante
    print("Extraction de la plus grande composante...")
    mask_component = ants.iMath(mask_eroded, "GetLargestComponent", 10000)
    ants.image_write(mask_component, os.path.join(step_dir, f"{base_name}_step{step_counter}_largest_component.nii.gz"))
    step_counter += 1

    # 7. Dilatation
    print("Dilatation appliquée...")
    mask_dilated = ants.iMath(mask_component, "MD", 6)
    ants.image_write(mask_dilated, os.path.join(step_dir, f"{base_name}_step{step_counter}_dilated.nii.gz"))
    step_counter += 1

    # 8. FillHoles
    print("Remplissage des trous...")
    mask_filled = ants.iMath(mask_dilated, "FillHoles", 0.3)
    ants.image_write(mask_filled, os.path.join(step_dir, f"{base_name}_step{step_counter}_fillholes.nii.gz"))
    step_counter += 1

    # 9. Application du mask final
    print("Application du mask final...")
    brain_image = ants.multiply_images(image, mask_filled)
    ants.image_write(brain_image, os.path.join(Brain_PATH, f"{base_name}_brain_extracted.nii.gz"))

    # Sauvegarde du mask final
    final_output_path = os.path.join(output_dir, f"{base_name}_mask_final.nii.gz")
    ants.image_write(mask_filled, final_output_path)
    print(f"Résultat final sauvegardé : {final_output_path}")

    return final_output_path




def main():
    parser = argparse.ArgumentParser(
        description="Parcours de l'arborescence pour appliquer l'extraction cérébrale et le post-traitement sur les fichiers RARE.nii.gz."
    )
    parser.add_argument("-r", "--root", required=True,
                        help="Chemin racine de l'arborescence à parcourir")
    args = parser.parse_args()

    root_dir = os.path.abspath(args.root)
    
    # Création du dossier 'derivates' à la racine spécifiée
    derivates_dir = os.path.join(root_dir, "derivatives")
    os.makedirs(derivates_dir, exist_ok=True)

    # Dossier centralisé pour les extractions (dans derivatives)
    brain_root = os.path.join(derivates_dir, "Brain_extracted", "RARE")
    os.makedirs(brain_root, exist_ok=True)

    # Liste des souris à exclure (à compléter manuellement)
    exclude_subjects = ["sub-07_ses-3"]

    # Parcours récursif de l'arborescence en excluant 'derivatives'
    for dirpath, dirnames, filenames in os.walk(root_dir):
    # Supprime 'derivatives' de la liste des dossiers à visiter
        dirnames[:] = [d for d in dirnames if d != "derivatives"]
        for filename in filenames:
            if "RARE.nii.gz" in filename:
                input_file = os.path.join(dirpath, filename)
                
                 # Vérifie si l'un des identifiants exclus est présent dans le chemin complet
                if any(excl in input_file for excl in exclude_subjects):
                    print(f"⚠️  Fichier ignoré (exclu par la liste) : {input_file}")
                    continue

                # Conserver la structure relative pour le dossier derivates
                rel_path = os.path.relpath(dirpath, root_dir)
                output_dir = os.path.join(derivates_dir, rel_path)
                os.makedirs(output_dir, exist_ok=True)
                
                # Base name sans extension .nii.gz
                base_name = filename.replace(".nii.gz", "")
            
                # Vérification de l'existence du masque final
                mask_final_path = os.path.join(output_dir, f"{base_name}_mask_final.nii.gz")
                if os.path.exists(mask_final_path):
                    print(f"Le mask existe déjà pour {base_name}, passage au fichier suivant.")
                    continue  # Passer au fichier suivant
            
                # Nom du fichier de sortie (ex: RARE_brain_extracted.nii.gz)
                output_file = os.path.join(output_dir, f"{os.path.splitext(filename)[0]}_brain_extracted.nii.gz")
                
                print(f"Traitement du fichier : {input_file}")
                try:
                    process_file(input_file, output_file,brain_root)
                except Exception as e:
                    print(f"Erreur lors du traitement de {input_file} : {e}")

if __name__ == "__main__":
    main()
