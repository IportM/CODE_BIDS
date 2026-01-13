import json
import re
import datetime
import os
import argparse
from collections import OrderedDict

def find_file(parent_folder, filename):
    for root, dirs, files in os.walk(parent_folder):
        if filename in files:
            return os.path.join(root, filename)
    return None

def parse_bruker_file(file_path):
    metadata = {}
    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if not line or line.startswith("$$") or line.startswith("##END="):
            i += 1
            continue
        if line.startswith("##$"):
            parts = line.split("=", 1)
            if len(parts) < 2:
                i += 1
                continue
            key = parts[0][3:].strip()
            value_str = parts[1].strip()
            if value_str.startswith("(") and value_str.endswith(")"):
                inner = value_str[1:-1].strip()
                if i + 1 < len(lines):
                    next_line = lines[i+1].strip()
                    if next_line and not next_line.startswith("##") and not next_line.startswith("$$"):
                        multi_line_value = []
                        j = i + 1
                        while j < len(lines):
                            nl = lines[j].strip()
                            if not nl or nl.startswith("##") or nl.startswith("$$"):
                                break
                            multi_line_value.append(nl)
                            j += 1
                        combined_value = " ".join(multi_line_value).strip()
                        if combined_value.startswith("<") and combined_value.endswith(">"):
                            combined_value = combined_value[1:-1].strip()
                        tokens = combined_value.split()
                        # Prise en compte des notations scientifiques
                        if tokens and all(re.match(r"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$", token) for token in tokens):
                            nums = [float(token) for token in tokens]
                            value = nums if len(nums) > 1 else nums[0]
                        else:
                            value = combined_value
                        i = j
                    else:
                        tokens = inner.split(",")
                        if tokens and all(re.match(r"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$", t.strip()) for t in tokens):
                            nums = [float(t.strip()) for t in tokens]
                            value = nums if len(nums) > 1 else nums[0]
                        else:
                            value = inner
                        i += 1
                else:
                    tokens = inner.split(",")
                    if tokens and all(re.match(r"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$", t.strip()) for t in tokens):
                        nums = [float(t.strip()) for t in tokens]
                        value = nums if len(nums) > 1 else nums[0]
                    else:
                        value = inner
                    i += 1
            else:
                if value_str.startswith("<") and value_str.endswith(">"):
                    value = value_str[1:-1].strip()
                else:
                    tokens = value_str.split()
                    if tokens and all(re.match(r"^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$", token) for token in tokens):
                        nums = [float(token) for token in tokens]
                        value = nums if len(nums) > 1 else nums[0]
                    else:
                        value = value_str.strip()
                i += 1
            metadata[key] = value
        else:
            i += 1
    return metadata

def convert_to_bids(visu_metadata, method_metadata):
    bids = {}
    mapping_visu = {
        "VisuAcqRepetitionTime": "RepetitionTime",
        "VisuAcqInversionTime": "InversionTime",
        "VisuAcqEchoTrainLength": "EchoTrainLength",
        "VisuAcqFlipAngle": "FlipAngle",
        "VisuAcqImagingFrequency": "ImagingFrequency",
        "VisuAcqImagedNucleus": "ImagedNucleus",
        "VisuMagneticFieldStrength": "MagneticFieldStrength",
        "VisuSubjectWeight": "Weight",
        "VisuSubjectPosition": "PatientPosition",
        "VisuAcquisitionProtocol": "ProtocolName",
        "VisuAcqPixelBandwidth": "PixelBandwidth",
        "VisuAcqSequenceName": "SequenceName",
        "VisuAcqEchoSequenceType": "SequenceType",
        "VisuCoilReceiveName": "ReceiveCoilName",
        "VisuCoilTransmitName": "TransmitCoilName",
    }
    mapping_method = {
        "Method": "ProtocolName",
        "PVM_StudyInstrumentPosition": "PatientPosition",
        "PVM_EchoTime": "EchoTime",
        "PVM_RepetitionTime": "RepetitionTime",
        "PVM_SliceThick": "SliceThickness",
        "PVM_Fov": "FieldOfView",
        "PVM_FrqWork": "ImagingFrequency",
        "PVM_Nucleus1": "ImagedNucleus",
        "PVM_SelIrInvTime": "InversionTime",
        "MP2_RecoveryTime": "MP2_RecoveryTime",
        "MP2_EchoTrainLength": "MP2_EchoTrainLength",
        "EffectiveTI": "EffectiveTI",
        "PVM_ScanTime": "ScanTime",
    }
    for key, bids_key in mapping_method.items():
        if key in method_metadata:
            bids[bids_key] = method_metadata[key]
    for key, bids_key in mapping_visu.items():
        if bids_key not in bids and key in visu_metadata:
            bids[bids_key] = visu_metadata[key]
    bids.setdefault("Manufacturer", "Bruker BioSpin MRI GmbH")
    bids.setdefault("ManufacturersModelName", visu_metadata.get("VisuManufacturer", "Unknown"))
    bids.setdefault("InstitutionName", visu_metadata.get("VisuInstitution", "Unknown"))
    bids.setdefault("ScanningSequence", "GradientEcho" if str(bids.get("SequenceType", "")).lower() == "gradientecho" else "Unknown")
    for key in ["ProtocolName", "SequenceName"]:
        if key in bids and isinstance(bids[key], str):
            bids[key] = bids[key].replace("User:", "").strip()
    if "FieldOfView" in bids and isinstance(bids["FieldOfView"], str):
        try:
            bids["FieldOfView"] = [float(x) for x in bids["FieldOfView"].split()]
        except Exception:
            pass
    return bids

def merge_acqp_data(bids, acqp_metadata):
    duplicate_map = {
        "ACQ_protocol_name": "ProtocolName",
        "ACQ_flip_angle": "FlipAngle",
        "ACQ_fov": "FieldOfView",
        "ACQ_inversion_time": "InversionTime",
        "ACQ_echo_time": "EchoTime",
        "ACQ_recov_time": "RecovTime"
    }
    for acqp_key, canonical in duplicate_map.items():
        if acqp_key in acqp_metadata and canonical not in bids:
            bids[canonical] = acqp_metadata[acqp_key]
    mapping_acqp = {
        "ACQ_operator": "operator",
        "ACQ_station": "station",
        "ACQ_sw_version": "sw_version",
        "ACQ_slice_angle": "slice_angle",
        "ACQ_slice_orient": "slice_orient",
        "ACQ_read_offset": "read_offset",
        "ACQ_phase1_offset": "phase1_offset",
        "ACQ_phase2_offset": "phase2_offset",
        "ACQ_slice_sepn": "slice_sepn",
        "ACQ_slice_offset": "slice_offset",
        "ACQ_time_points": "time_points"
    }
    for acqp_key, new_key in mapping_acqp.items():
        if acqp_key in acqp_metadata and new_key not in bids:
            bids[new_key] = acqp_metadata[acqp_key]
    additional_acqp = {
        "ACQ_abs_time": "AcquisitionTime",
        "ACQ_scan_type": "SeriesDescription"
    }
    for acqp_key, new_key in additional_acqp.items():
        if acqp_key in acqp_metadata and new_key not in bids:
            val = acqp_metadata[acqp_key]
            if new_key == "AcquisitionTime":
                if isinstance(val, list) and len(val) > 0:
                    try:
                        ts = float(str(val[0]).replace(",", "."))
                        dt = datetime.datetime.utcfromtimestamp(ts).isoformat() + "Z"
                        bids[new_key] = dt
                    except Exception:
                        bids[new_key] = val
                elif isinstance(val, str):
                    parts = [p.strip() for p in val.split(",") if p.strip()]
                    if parts:
                        try:
                            ts = float(parts[0].replace(",", "."))
                            dt = datetime.datetime.utcfromtimestamp(ts).isoformat() + "Z"
                            bids[new_key] = dt
                        except Exception:
                            bids[new_key] = val
                    else:
                        bids[new_key] = val
                else:
                    bids[new_key] = val
            else:
                bids[new_key] = val
    return bids

def merge_reco_data(bids, reco_metadata):
    mapping_reco = {
        "RECO_time": "ReconstructionTime",
        "RECO_size": "ReconstructionImageDimensions",
        "RECO_image_type": "ReconstructionImageType"
    }
    for key, new_key in mapping_reco.items():
        if key in reco_metadata and new_key not in bids:
            val = reco_metadata[key]
            if new_key == "ReconstructionTime" and isinstance(val, str):
                bids[new_key] = val.replace(",", ".")
            else:
                bids[new_key] = val
    return bids

def adapt_for_MESE(bids):
    bids["ScanningSequence"] = "SpinEcho"
    bids["SequenceType"] = "SpinEcho"
    for key in ["MP2_RecoveryTime", "MP2_EchoTrainLength", "EffectiveTI"]:
        bids.pop(key, None)
    if "NECHOES" in bids:
        bids["NumberOfEchoes"] = bids["NECHOES"]
        bids.pop("NECHOES", None)
    return bids

def adapt_for_RARE(bids):
    # Forcer la séquence à "RARE" (ou "TurboSpinEcho")
    bids["ScanningSequence"] = "RARE"   # Vous pouvez remplacer par "TurboSpinEcho" si cela correspond mieux
    bids["SequenceType"] = "RARE"
    
    # Le temps d'inversion n'est généralement pas utilisé dans une séquence RARE
    bids.pop("InversionTime", None)
    return bids

def reorder_keys(bids_dict):
    logical_order = [
        "Manufacturer",
        "ManufacturersModelName",
        "InstitutionName",
        "PatientPosition",
        "ProtocolName",
        "SeriesDescription",
        "AcquisitionTime",
        "ReconstructionTime",
        "ReconstructionImageDimensions",
        "ReconstructionImageType",
        "ScanningSequence",
        "SequenceName",
        "SequenceType",
        "RepetitionTime",
        "EchoTime",
        "InversionTime",
        "FlipAngle",
        "SliceThickness",
        "FieldOfView",
        "ImagingFrequency",
        "ImagedNucleus",
        "EchoTrainLength",
        "ScanTime",
        "PixelBandwidth",
        "MagneticFieldStrength",
        "Weight",
        "ReceiveCoilName",
        "TransmitCoilName",
        "operator",
        "station",
        "sw_version",
        "slice_angle",
        "slice_orient",
        "read_offset",
        "phase1_offset",
        "phase2_offset",
        "slice_sepn",
        "slice_thick",
        "slice_offset",
        "time_points",
        "RecovTime"
    ]
    ordered = OrderedDict()
    for key in logical_order:
        if key in bids_dict:
            ordered[key] = bids_dict[key]
    for key, value in bids_dict.items():
        if key not in ordered:
            ordered[key] = value
    return ordered

def MP2RAGE(bids, p_MP2, inversion_time):
    bids["InversionTime"] = inversion_time  # On met soit TI1, soit TI2
    bids["RepetitionTimeExcitation"] = p_MP2["TR"]
    bids["RepetitionTimePreparation"] = p_MP2["MP2RAGE_TR"]
    bids["NumberShots"] = p_MP2["ETL"]
    bids["FlipAngle"] = p_MP2["α₁"] if inversion_time == p_MP2["TI₁"] else p_MP2["α₂"]
    return bids

def save_json(data, output_file):
    # Ajout du champ "units" avec la valeur "arbitary" si non présent
    data.setdefault("Units", "arbitrary")
    ordered_data = reorder_keys(data)
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(ordered_data, f, indent=4, ensure_ascii=False)

def adapt_for_T2star(bids_dict):
    """Adapte le dictionnaire BIDS pour une carte T2* (multi-echo GRE)"""
    bids_dict["ScanningSequence"] = "GRADIENT_ECHO"
    bids_dict["SequenceType"]     = "GRE"
    # Nombre d'échos issu de NECHOES si présent
    if "NECHOES" in bids_dict:
        bids_dict["NumberOfEchoes"] = bids_dict.pop("NECHOES")
    return bids_dict

def main():
    parser = argparse.ArgumentParser(description="Parser Bruker avec paramètre optionnel MP2RAGE.")
    parser.add_argument("parent_folder", help="Dossier parent contenant les fichiers Bruker")
    parser.add_argument("output_folder", help="Dossier de sortie pour le fichier JSON")
    parser.add_argument("--mode", default="MP2RAGE", help="Mode de reconstruction (par défaut MP2RAGE)")
    parser.add_argument("--mp2_file", default=None, help="Chemin vers le fichier JSON contenant les paramètres MP2RAGE")
    parser.add_argument("--json_name", default=None, help="Nom souhaité pour le fichier JSON de métadonnées (ex: sub-01_ses-01_MP2RAGE.json)")
    args = parser.parse_args()

    parent_folder = args.parent_folder
    output_folder = args.output_folder
    mode = args.mode.upper()

    # Pour MP2RAGE et MESE, on enregistre un cran avant le dossier donné
    if mode in ["MP2RAGE", "MESE"]:
        output_folder = os.path.dirname(output_folder)

    visu_pars_file = os.path.join(parent_folder, "pdata", "1", "visu_pars")
    method_file = os.path.join(parent_folder, "method")
    acqp_file = os.path.join(parent_folder, "acqp")
    reco_file = os.path.join(parent_folder, "pdata", "1", "reco")

    if not os.path.exists(visu_pars_file):
        visu_pars_file = find_file(parent_folder, "visu_pars")
        if not visu_pars_file:
            print("Fichier 'visu_pars' introuvable.")
            exit(1)
    if not os.path.exists(method_file):
        method_file = find_file(parent_folder, "method")
        if not method_file:
            print("Fichier 'method' introuvable.")
            exit(1)
    if not os.path.exists(acqp_file):
        acqp_file = find_file(parent_folder, "acqp")
        if not acqp_file:
            print("Fichier 'acqp' introuvable.")
            exit(1)
    if not os.path.exists(reco_file):
        reco_file = find_file(parent_folder, "reco")
        if not reco_file:
            print("Fichier 'reco' introuvable.")
            exit(1)

    visu_metadata = parse_bruker_file(visu_pars_file)
    method_metadata = parse_bruker_file(method_file)
    acqp_metadata = parse_bruker_file(acqp_file)
    reco_metadata = parse_bruker_file(reco_file)

    with open(method_file, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            if line.startswith("##$Method="):
                value = line.split("=", 1)[1].strip()
                if value.startswith("<") and value.endswith(">"):
                    method_metadata["Method"] = value[1:-1].strip()
                break

    bids_metadata = convert_to_bids(visu_metadata, method_metadata)
    bids_metadata = merge_acqp_data(bids_metadata, acqp_metadata)
    bids_metadata = merge_reco_data(bids_metadata, reco_metadata)

    if args.mp2_file is not None and mode == "MP2RAGE":
        try:
            with open(args.mp2_file, 'r', encoding='utf-8') as f:
                mp2_data = json.load(f)
            
            # Créer deux fichiers pour TI1 et TI2
            bids_metadata_TI1 = MP2RAGE(bids_metadata.copy(), mp2_data, mp2_data["TI₁"])
            bids_metadata_TI2 = MP2RAGE(bids_metadata.copy(), mp2_data, mp2_data["TI₂"])

            output_json_TI1 = os.path.join(output_folder, args.json_name.replace("MP2RAGE.json", "inv-1_MP2RAGE.json"))
            output_json_TI2 = os.path.join(output_folder, args.json_name.replace("MP2RAGE.json", "inv-2_MP2RAGE.json"))

            save_json(bids_metadata_TI1, output_json_TI1)
            save_json(bids_metadata_TI2, output_json_TI2)

            print(f"✅ Fichiers JSON MP2RAGE créés : \n  - {output_json_TI1}\n  - {output_json_TI2}")
            exit(0)
        except Exception as e:
            print("❌ Erreur lors de la lecture du fichier MP2RAGE:", e)
            exit(1)
    else:
        print("Aucun fichier MP2RAGE fourni ou autre Méthode.")

    if mode == "MESE":
        bids_metadata = adapt_for_MESE(bids_metadata)
    elif mode == "RARE":
        bids_metadata = adapt_for_RARE(bids_metadata)
    if mode == "T2STAR":
        bids_metadata = adapt_for_T2star(bids_metadata)

    # Modification du nom du fichier pour le mode MESE avec ajout de "echo-1"
    if args.json_name is not None:
        if mode == "MESE":
            # Remplacer "MESE.json" par "echo-1_MESE.json" ou ajouter le suffixe avant l'extension
            if args.json_name.endswith("MESE.json"):
                output_json_name = args.json_name.replace("MESE.json", "echo-1_MESE.json")
            else:
                name, ext = os.path.splitext(args.json_name)
                output_json_name = f"{name}_echo-1{ext}"
        else:
            output_json_name = args.json_name
        output_json = os.path.join(output_folder, output_json_name)
    else:
        if mode == "MESE":
            output_json = os.path.join(output_folder, "bids_metadata_echo-1_MESE.json")
        else:
            output_json = os.path.join(output_folder, "bids_metadata.json")

    save_json(bids_metadata, output_json)
    print(f"✅ Le fichier JSON BIDS a été créé : {output_json}")

if __name__ == "__main__":
    main()
