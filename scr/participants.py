#!/usr/bin/env python3
import os
import re
import sys
import csv
from datetime import datetime

def extract_info(filepath):
    """Extrait ID patient, sexe, date naissance et date d'acquisition depuis un fichier 'subject'."""
    with open(filepath, 'r') as f:
        text = f.read()

    # ID du patient (type: M01, M14, etc.)
    id_match = re.search(r"##\$SUBJECT_id=.*\n<([^>]+)>", text)
    raw_patient_id = id_match.group(1).strip() if id_match else None
    patient_id = None
    if raw_patient_id:
        match = re.search(r"M(\d+)", raw_patient_id)
        if match:
            # Forçage à 2 chiffres
            patient_id = f"sub-{int(match.group(1)):02d}"

    # Sexe
    gender_match = re.search(r"##\$SUBJECT_gender=([A-Z]+)", text)
    gender = gender_match.group(1).strip() if gender_match else None

    # Date de naissance (format : "13 Mar 2025")
    birth_match = re.search(r"##\$SUBJECT_dbirth=.*\n<([^>]+)>", text)
    birth_date = None
    if birth_match:
        try:
            birth_date = datetime.strptime(birth_match.group(1).strip(), "%d %b %Y")
        except ValueError:
            pass

    # Date d'acquisition (première date au format YYYY-MM-DD après "$$")
    file_date_match = re.search(r"\$\$\s+(\d{4}-\d{2}-\d{2})", text)
    acquisition_date = None
    if file_date_match:
        try:
            acquisition_date = datetime.strptime(file_date_match.group(1), "%Y-%m-%d")
        except ValueError:
            pass

    return patient_id, gender, birth_date, acquisition_date

def process_directories(list_of_dirs):
    """Parcourt plusieurs répertoires, extrait les infos de chaque patient (subject), conserve la session la plus ancienne."""
    participants = {}
    for root_dir in list_of_dirs:
        for dirpath, _, files in os.walk(root_dir):
            for filename in files:
                if filename == "subject":
                    filepath = os.path.join(dirpath, filename)
                    patient_id, gender, birth_date, acquisition_date = extract_info(filepath)
                    if not patient_id or not acquisition_date:
                        continue
                    if patient_id in participants:
                        if acquisition_date < participants[patient_id]['acquisition_date']:
                            participants[patient_id] = {
                                "participant_id": patient_id,
                                "gender": gender,
                                "birth_date": birth_date,
                                "acquisition_date": acquisition_date
                            }
                    else:
                        participants[patient_id] = {
                            "participant_id": patient_id,
                            "gender": gender,
                            "birth_date": birth_date,
                            "acquisition_date": acquisition_date
                        }

    # Normalisation forcée des IDs entre sub-01 et sub-99
    normalized = {}
    for k, v in participants.items():
        num = int(k.split('-')[1])
        new_id = f"sub-{num:02d}"
        v["participant_id"] = new_id
        normalized[new_id] = v

    return list(normalized.values())

def write_tsv(results, output_tsv):
    """Écrit le TSV BIDS : ID, genre, âge (en jours) à la 1ère acquisition."""
    fieldnames = ["participant_id", "gender", "age"]
    results.sort(key=lambda x: int(x['participant_id'].split('-')[1]))
    with open(output_tsv, 'w', newline='') as tsvfile:
        writer = csv.DictWriter(tsvfile, fieldnames=fieldnames, delimiter='\t')
        writer.writeheader()
        for row in results:
            age = None
            if row['birth_date'] and row['acquisition_date']:
                age = (row['acquisition_date'] - row['birth_date']).days
            writer.writerow({
                "participant_id": row['participant_id'],
                "gender": row['gender'],
                "age": age
            })

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python participants.py <dossier1> [<dossier2> ...] <output_tsv>")
        sys.exit(1)

    *input_dirs, output_tsv = sys.argv[1:]
    results = process_directories(input_dirs)
    write_tsv(results, output_tsv)
    print(f"✔ Résultats écrits dans : {output_tsv}")
