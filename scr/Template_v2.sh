#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
source /workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/activate

contrast=$1                    # ex: T1map
session_group=${2:-S01}        # paramètre S01, S02 ou S03 (défaut : S01)
nIter=${3:-4}                  # nombre d'itérations ANTs
nThreads=16                    # nombre de threads
resolutions=("0.5" "0.3" "0.2" "0.1")  # Résolutions successives

# ➤ Définition des sessions à utiliser selon session_group
case "$session_group" in
  S01)
    ses_filter=("ses-1" "ses-2")
    ;;
  S02)
    ses_filter=("ses-3" "ses-4")
    ;;
  S03)
    ses_filter=("ses-5" "ses-6")
    ;;
  *)
    echo "❌ Erreur : session_group doit être S01, S02 ou S03"
    exit 1
    ;;
esac

echo "→ Sessions sélectionnées : ${ses_filter[*]}"

# Répertoires de base
ORIG_IMG_DIR="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/${contrast}/alignedSyN_Allen"
TEMPLATE_BASE="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted/${contrast}/${session_group}/templateSyN_Allen"

# ➤ Vérification si le template final (résolution 0.1) existe déjà
FINAL_TEMPLATE="${TEMPLATE_BASE}/0.1/template/${contrast}_template_template0.nii.gz"
if [[ -f "$FINAL_TEMPLATE" ]]; then
  echo "✅ Le template final existe déjà : $FINAL_TEMPLATE"
  echo "⏩ Le script ne sera pas relancé."
  deactivate
  exit 0
fi

# Création du dossier principal template
mkdir -p "$TEMPLATE_BASE"

# Référence utilisée pour la prochaine étape (vide au départ)
REF_TEMPLATE=""

for res in "${resolutions[@]}"; do
  echo "=== ➤ Résolution ${res}mm ==="
  
  RESAMPLED_DIR="${TEMPLATE_BASE}/${res}/resampled"
  TEMPLATE_OUT="${TEMPLATE_BASE}/${res}/template"
  mkdir -p "$RESAMPLED_DIR" "$TEMPLATE_OUT"

  # ➤ Étape 1 : Resample les images
  inputs=()
  for f in "${ORIG_IMG_DIR}"/sub-*_ses-*_"${contrast}"_brain_extracted*.nii.gz; do
    match=false
    for ses in "${ses_filter[@]}"; do
      if [[ "$f" == *"$ses"* ]]; then
        match=true
        break
      fi
    done
    # si pas de correspondance avec le groupe de sessions, on saute
    if [[ "$match" != true ]]; then
      continue
    fi

    filename=$(basename "$f")
    base="${filename%.nii.gz}"
    resampled_img="${RESAMPLED_DIR}/${base}_res-${res}.nii.gz"

    if [[ ! -f "$resampled_img" ]]; then
      echo "→ Resampling $filename to ${res}mm"
      ResampleImageBySpacing 3 "$f" "$resampled_img" $res $res $res 0
    else
      echo "✓ Déjà présent : $resampled_img"
    fi

    inputs+=("$resampled_img")
  done

  if [ ${#inputs[@]} -eq 0 ]; then
    echo "❌ Aucun fichier resamplé trouvé pour ${session_group} à ${res}mm. Arrêt."
    exit 1
  fi

  # ➤ Étape 2 : Calcul du FOV max après resampling
  test_img="${inputs[0]}"
  dims=($(mrinfo -size "$test_img"))
  spacing=($(mrinfo -spacing "$test_img"))

  fov_x=$(echo "${dims[0]} * ${spacing[0]}" | bc -l)
  fov_y=$(echo "${dims[1]} * ${spacing[1]}" | bc -l)
  fov_z=$(echo "${dims[2]} * ${spacing[2]}" | bc -l)

  FOV_MAX=$(printf "%.2f\n" $(echo "$fov_x $fov_y $fov_z" | tr ' ' '\n' | sort -nr | head -n1))
  echo "→ FOV max estimé : ${FOV_MAX}mm"

  # ➤ Étape 3 : Génération des paramètres dynamiques
  ANTS_GEN_ITER="/workspace_QMRI/USERS_CODE/mpetit/Minc/minc-toolkit-extras/ants_generate_iterations.py"
  GEN_PARAMS=$(python3 "$ANTS_GEN_ITER" --min "$res" --max "$FOV_MAX" --step-size 1 --output modelbuild | tr -d '\\')

  # split proprement les paramètres renvoyés
  readarray -t PARAM_ARRAY <<< "$GEN_PARAMS"
  Q_PARAM=${PARAM_ARRAY[0]:-}
  F_PARAM=${PARAM_ARRAY[1]:-}
  S_PARAM=${PARAM_ARRAY[2]:-}

  echo "→ Paramètres optimisés pour ${res}mm : $Q_PARAM $F_PARAM $S_PARAM"

  # ➤ Étape 4 : Construction du template
  cd "$TEMPLATE_OUT"
  echo "→ ${#inputs[@]} fichiers prêts pour le template à ${res}mm"

  cmd=(
    antsMultivariateTemplateConstruction2.sh
    -d 3
    -o "${contrast}_template_"
    -i "$nIter"
    -g 0.1
    -c 2
    -j "$nThreads"
    -k 1
    -w 1
    -n 0
    -r 1
    -z "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/Allen/LR/100_AMBA_ref.nii.gz"
  )

  # ajouter les paramètres Q/F/S s'ils existent (non vides)
  [[ -n "$Q_PARAM" ]] && cmd+=("$Q_PARAM")
  [[ -n "$F_PARAM" ]] && cmd+=("$F_PARAM")
  [[ -n "$S_PARAM" ]] && cmd+=("$S_PARAM")

  # ➤ Si on a un template de référence précédent, resample et l'ajouter en -z
  if [[ -n "$REF_TEMPLATE" && -f "$REF_TEMPLATE" ]]; then
    REF_RESAMPLED="${TEMPLATE_OUT}/ref_template_res-${res}.nii.gz"
    if [[ ! -f "$REF_RESAMPLED" ]]; then
      echo "→ Resampling du template précédent ($REF_TEMPLATE) en ${res}mm"
      ResampleImageBySpacing 3 "$REF_TEMPLATE" "$REF_RESAMPLED" $res $res $res 0
    fi
    echo "→ Utilisation de $REF_RESAMPLED comme référence (-z)"
    cmd+=(-z "$REF_RESAMPLED")
  fi

  echo "→ Construction du template en ${res}mm..."
  "${cmd[@]}" "${inputs[@]}"

  NEW_TEMPLATE="${TEMPLATE_OUT}/${contrast}_template_template0.nii.gz"
  if [[ ! -f "$NEW_TEMPLATE" ]]; then
    echo "❌ Template non trouvé après la génération. Abandon."
    exit 1
  fi
  ALLEN_REF="/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/Allen/LR/100_AMBA_ref.nii.gz"  # ou ton Allen template 100µm

  # if [[ "$res" == "0.1" ]]; then
  #   echo "→ Rééchantillonnage du template final sur la grille Allen (114x132x80)..."
  #   antsApplyTransforms \
  #     -d 3 \
  #     -i "$NEW_TEMPLATE" \
  #     -r "$ALLEN_REF" \
  #     -n Linear \
  #     -o "${TEMPLATE_OUT}/${contrast}_template_template0_inAllenGrid.nii.gz"
  # fi
  REF_TEMPLATE="$NEW_TEMPLATE"
done

echo "✅ Templates multi-échelles terminés."
deactivate