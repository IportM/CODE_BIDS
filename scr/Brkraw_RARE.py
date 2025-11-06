import os
import sys
import subprocess

def run_brkraw(brkraw_dir, s_value, anat_dir, output_filename=None):
    try:
        brkraw_path = "/home/mpetit/.local/bin/brkraw"  # Chemin absolu vers brkraw
        command = f"{brkraw_path} tonii {brkraw_dir} -s {s_value} -o {anat_dir}/"
        subprocess.run(command, shell=True, check=True)
        print(f"Commande exécutée avec succès : {command}")

        # Recherche du fichier généré dans le dossier de sortie
        output_files = [f for f in os.listdir(anat_dir) if "RARE" in f and (f.endswith(".nii") or f.endswith(".nii.gz"))]

        if len(output_files) == 0:
            print("Aucun fichier de sortie trouvé !")
            sys.exit(1)
        
        # S'il y a un fichier généré et qu'on a un nom de fichier cible
        if output_filename:
            old_filepath = os.path.join(anat_dir, output_files[0])
            new_filepath = os.path.join(anat_dir, output_filename)
            os.rename(old_filepath, new_filepath)
            print(f"Fichier renommé : {old_filepath} -> {new_filepath}")

        command =f"mrconvert {new_filepath} -stride 1,2,3 {new_filepath} -force"
        subprocess.run(command, shell=True, check=True)
        print(f"Commande exécutée avec succès : {command}")
    except subprocess.CalledProcessError as e:
        print(f"Erreur lors de l'exécution : {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) not in [4, 5]:
        print("Usage : python brkraw_wrapper.py <brkraw_dir> <s_value> <anat_dir> [<output_filename>]")
        sys.exit(1)

    brkraw_dir = sys.argv[1]
    s_value = sys.argv[2]
    anat_dir = sys.argv[3]
    output_filename = sys.argv[4] if len(sys.argv) == 5 else None

    run_brkraw(brkraw_dir, s_value, anat_dir, output_filename)