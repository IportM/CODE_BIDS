using CSV
using DataFrames
using Dates
using JSON
using SEQ_BRUKER_a_MP2RAGE_CS_360
using NIfTI
using Glob
using MRIFiles
using Statistics
using PyCall
import Base.Filesystem: mkpath, isfile, touch
### Package pour T2* mapping
using LsqFit
using Metrics
###########################

#julia -t auto --project=./Reconstrcution_BIDS_FC3R.jl

# *********************************************************************
# Partie 1 : Extraction d'informations et création du fichier TSV
# *********************************************************************

# Function to extract information from the "method" file
function extract_information(filepath::String)
  date, id_value, method = "", "", ""
  open(filepath, "r") do file
    for line in eachline(file)
      if occursin(r"^\$\$ \d{4}-\d{2}-\d{2}", line) && isempty(date)
        date = match(r"\d{4}-\d{2}-\d{2}", line).match
      end
      if occursin(r"M\d+", line) && isempty(id_value)
        id_match = match(r"M(\d+)", line)
        id_value = id_match !== nothing ? id_match.captures[1] : ""
      end
      if occursin(r"##\$Method=<", line) && isempty(method)
        method_match = match(r"##\$Method=<(?:Bruker:|User:)([^>]+)>", line)
        method = method_match !== nothing ? method_match.captures[1] : ""
      end
      if !isempty(date) && !isempty(id_value) && !isempty(method)
        break
      end
    end
  end
  return date, id_value, isempty(method) ? "Not found" : method
end

function save_rare_library_tsv(rare_library::Dict{String, String}, output_file::String)
  # Créer un DataFrame à partir du dictionnaire
  df = DataFrame(ID_Session=String[], Filepath=String[])
  for (k, v) in pairs(rare_library)
      push!(df, (k, v))
  end

  # Écrire le DataFrame dans un fichier TSV
  CSV.write(output_file, df; delim='\t')
  println("Rare library saved to $output_file")
end

# Fonction pour sauvegarder rare_library dans un fichier TSV
function process_directory(directorypath::String, output_tsv::String; write_file::Bool = true)
  # 1) Extraction des infos dans un DataFrame brut
  results = DataFrame(Filepath = String[], Date = String[], ID = String[], Method = String[])
  for (root, _, files) in walkdir(directorypath)
    for file in files
      if file == "method"
        filepath = joinpath(root, file)
        parent_dir = dirname(filepath)
        if isfile(joinpath(parent_dir, "rawdata.job0"))
          date, id_value, method = extract_information(filepath)
          if !isempty(date) && !isempty(id_value) && !isempty(method)
            push!(results, (parent_dir, date, id_value, method))
          end
        end
      end
    end
  end

  # 2) Nettoyage des Method et filtrage
  results.Method .= replace.(results.Method, r"^a_|_CS_360$" => "")
  results.Method .= replace.(results.Method, r".*RARE.*" => "RARE")
  results = filter(row -> row.Method != "FLASH", results)

  # 3) Conversion de la colonne Date en type Date
  results.Date = Date.(results.Date, "yyyy-mm-dd")

  # 4) Calcul des sessions (tri temporaire par ID puis Date)
  sort!(results, [:ID, :Date])
  results.Session = zeros(Int, nrow(results))
  for id in unique(results.ID)
    subset = results[results.ID .== id, :]
    session = 1
    prev_date = nothing
    for i in 1:nrow(subset)
      idx = findfirst(results.Filepath .== subset[i, :Filepath])
      cur_date = subset[i, :Date]
      if prev_date !== nothing && cur_date > prev_date
        session += 1
      end
      results[idx, :Session] = session
      prev_date = cur_date
    end
  end

  # 5) Extraction du suffixe numérique de Filepath
  results.Suffix = [
    let m = match(r"(\d+)$", fp)
      m !== nothing ? parse(Int, m.captures[1]) : 0
    end for fp in results.Filepath
  ]

  # 6) Tri final par ID, puis Session, puis Suffix
  sort!(results, [:ID, :Session, :Suffix])

  # 7) Nettoyage final
  select!(results, Not(:Suffix))

  # 8) Sauvegarde éventuelle
  if write_file && output_tsv != ""
    CSV.write(output_tsv, results; delim = '\t')
    println("Results written to $output_tsv")
  end
  return results
end

function load_rare_library_tsv(file::String)::Dict{String,String}
  if !isfile(file)
      return Dict{String,String}()
  end
  df = CSV.read(file, DataFrame; delim='\t')
  return Dict(row.ID_Session => row.Filepath for row in eachrow(df))
end

# Liste des dossiers à traiter
input_dirs = [
"/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/DATA/S01",
"/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/DATA/S02",
"/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/DATA/S03"
]

# On initialise un DataFrame vide
all_results = DataFrame()

# Appel process_directory
for directorypath in input_dirs
    df_partial = process_directory(directorypath, ""; write_file=false)
    # Normalisation des IDs à 2 chiffres
    df_partial.ID .= lpad.(parse.(Int, df_partial.ID), 2, '0')
    append!(all_results, df_partial)
end

# Normalise aussi les IDs globalement (sécurité)
all_results.ID .= lpad.(parse.(Int, all_results.ID), 2, '0')

# Trie les données
sort!(all_results, [:ID, :Date])

# ===== NOUVEAU CODE POUR LE CALCUL DES SESSIONS =====
# Extraire le numéro de dossier (S01, S02, S03) depuis le chemin
all_results.DossierNum = [
    let m = match(r"/S(\d+)/", fp)
        m !== nothing ? parse(Int, m.captures[1]) : 0
    end for fp in all_results.Filepath
]

# Extraire le suffixe numérique final (pour le tri intra-session)
all_results.Suffix = [
    let m = match(r"(\d+)$", fp)
        m !== nothing ? parse(Int, m.captures[1]) : 0
    end for fp in all_results.Filepath
]

# Tri global : ID, puis numéro de dossier, puis date, puis suffixe
sort!(all_results, [:ID, :DossierNum, :Date, :Suffix])

# Calcul des sessions par participant
all_results.Session = zeros(Int, nrow(all_results))

for id in unique(all_results.ID)
    participant_mask = all_results.ID .== id
    participant_data = all_results[participant_mask, :]
    
    # Identifier les combinaisons uniques (DossierNum, Date) pour ce participant
    unique_sessions = unique([(row.DossierNum, row.Date) for row in eachrow(participant_data)])
    sort!(unique_sessions)  # Tri par dossier puis par date
    
    # Attribution des sessions basée sur le numéro de dossier
    for (dossier_num, date) in unique_sessions
        session_number = if dossier_num == 1
            # Compter combien de dates distinctes dans S01 jusqu'à cette date
            s01_dates = sort(unique([d for (dn, d) in unique_sessions if dn == 1]))
            findfirst(==(date), s01_dates)
        elseif dossier_num == 2
            # S02 commence à 3, puis incrémente
            s02_dates = sort(unique([d for (dn, d) in unique_sessions if dn == 2]))
            3 + findfirst(==(date), s02_dates) - 1
        elseif dossier_num == 3
            # S03 commence après la dernière session de S02
            s01_count = length(unique([d for (dn, d) in unique_sessions if dn == 1]))
            s02_count = length(unique([d for (dn, d) in unique_sessions if dn == 2]))
            s03_dates = sort(unique([d for (dn, d) in unique_sessions if dn == 3]))
            s01_count + s02_count + findfirst(==(date), s03_dates)
        else
            1  # fallback
        end
        
        # Appliquer cette session à tous les enregistrements correspondants
        mask = (all_results.ID .== id) .& 
               (all_results.DossierNum .== dossier_num) .& 
               (all_results.Date .== date)
        all_results[mask, :Session] .= session_number
    end
end

# Tri final et nettoyage
sort!(all_results, [:ID, :Session, :Suffix])
select!(all_results, Not([:DossierNum, :Suffix]))
# ===== FIN DU NOUVEAU CODE =====

# Écriture fichier (code original conservé)
output_tsv = joinpath(dirname(@__DIR__), "scr", "results.tsv")
mkpath(dirname(output_tsv))
CSV.write(output_tsv, all_results; delim = '\t')
println("Results written to $output_tsv")



# Create the BIDS directory
bids_root = joinpath(dirname(@__DIR__), "BIDS")
mkpath(bids_root)

python_script = "participants.py"


output_tsv = joinpath(bids_root, "participants.tsv")

command = `python3 $python_script $(input_dirs...) $output_tsv`
run(command)

rare_library_tsv_path = joinpath(pwd(), "rare_library.tsv")
const rare_library = load_rare_library_tsv(rare_library_tsv_path)

global_start = time()  # Start global timer

# *********************************************************************
# Partie 2 : Reconstruction selon les méthodes
# *********************************************************************
df = all_results
for i in eachindex(df.Method)
  subject_name = "sub-" * string(df[i, :ID])
  session_name = "ses-" * string(df[i, :Session])
  session_dir = joinpath(bids_root, subject_name, session_name)
  
  anat_dir = joinpath(session_dir, "anat")
  mkpath(anat_dir)
  
  current_method = df[i, :Method]
  json_patterns = [
    joinpath(anat_dir, "*_$(current_method).json"),  # Search in anat_dir
    joinpath(session_dir, "*_$(current_method).json")  # Search in parent directory
  ]

  println("Processing: ", df[i, :Filepath])

  # Check if a matching JSON file exists
  matching_files = vcat(glob("*_$(current_method).json", anat_dir), glob("*_$(current_method).json", session_dir))
  if !isempty(matching_files)
    println("Reconstruction already done for $(current_method) of patient $(subject_name) in session $(session_name).")
    continue
  end
  
  if occursin(r"MP2RAGE", current_method)
    local_start = time()  # Start timer for current reconstruction
    d = reconstruction_MP2RAGE(df[i, :Filepath]; mean_NR=true,slab_correction=true)

    # res = reconstruction_MP2RAGE("7", slab_correction=true)
    # subject_name = "reco_with_slab_correction"
    # dir_path = "" # directory path where the files will be create
    # write_bids_MP2RAGE(res,subject_name,dir_path)


    # Save the MP2RAGE parameters dictionary to a JSON file
    mp2_file = joinpath(anat_dir, "$(subject_name)_mp2_params.json")
    open(mp2_file, "w") do io
      JSON.print(io, d["params_MP2RAGE"])
    end

    path_type = [
      "_inv-1_part-mag_MP2RAGE",
      "_inv-1_part-phase_MP2RAGE",
      "_inv-1_part-complex_MP2RAGE",
      "_inv-2_part-mag_MP2RAGE",
      "_inv-2_part-phase_MP2RAGE",
      "_inv-2_part-complex_MP2RAGE",
      "_UNIT1",
      "_T1map"
    ]
    data_ = [
      abs.(d["im_reco"][:,:,:,:,1]),
      angle.(d["im_reco"][:,:,:,:,1]),
      d["im_reco"][:,:,:,:,1],
      abs.(d["im_reco"][:,:,:,:,2]),
      angle.(d["im_reco"][:,:,:,:,2]),
      d["im_reco"][:,:,:,:,2],
      d["MP2RAGE"],
      d["T1map"]
    ]
    voxel_size = tuple(parse.(Float64, d["params_prot"]["PVM_SpatResol"])...)  # in mm
    for (name, data) in zip(path_type, data_)
      ni = NIVolume(abs.(data), voxel_size=voxel_size)
      niwrite(joinpath(anat_dir, subject_name * "_" * session_name * name * ".nii.gz"), ni)
    end

    python_script = "Parser_Bruker_file.py"
    command = `python3 $python_script $(df[i, :Filepath]) $anat_dir --mp2_file $mp2_file --json_name "$(subject_name)_$(session_name)_$(current_method).json"`
    run(command)

    if isfile(mp2_file)
      rm(mp2_file)
    end

    local_elapsed = time() - local_start  # Reconstruction time for current subject/session/method
    println("🕒 Reconstruction time for $(subject_name) $(session_name) $(current_method): $(local_elapsed) seconds")
  
  elseif occursin(r"MESE", current_method)
    local_start = time()  # Start timer for current reconstruction
    mese_out = joinpath(anat_dir, "$(subject_name)_$(session_name)")
    run(`julia -t auto --project=reconstruction_MESE reconstruction_MESE/main_MESE.jl $(df[i, :Filepath]) $mese_out`)
    
    python_script = "Parser_Bruker_file.py"
    command = `python3 $python_script $(df[i, :Filepath]) $anat_dir --mode MESE --json_name "$(subject_name)_$(session_name)_$(current_method).json"`
    run(command)
    
    local_elapsed = time() - local_start  # Reconstruction time for current subject/session/method
    println("🕒 Reconstruction time for $(subject_name) $(session_name) $(current_method): $(local_elapsed) seconds")
  
  elseif occursin(r"RARE", current_method)
    local_start = time()  # Start timer for current reconstruction
    brkraw_dir = dirname(df[i, :Filepath])
    s_value = basename(df[i, :Filepath])
    s_value = lpad(parse(Int, basename(df[i, :Filepath])), 3, '0')
    
    python_script = "Brkraw_RARE.py"
    command = `python3 $python_script $brkraw_dir $s_value $anat_dir "$(subject_name)_$(session_name)_$(current_method).nii.gz"`
    run(command)
    
    rare_output_path = joinpath(anat_dir, "$(subject_name)_$(session_name)_$(current_method).nii.gz")
    
    # Ajout de l'entrée dans le dictionnaire rare_library
    id_key = "$(subject_name)_$(session_name)"  # ex: sub-01_ses-01
    rare_library[id_key] = rare_output_path

    python_script = "Parser_Bruker_file.py"
    command = `python3 $python_script $(df[i, :Filepath]) $anat_dir --mode RARE --json_name "$(subject_name)_$(session_name)_$(current_method).json"`
    run(command)
        
    output_tsv_file = joinpath(pwd(), "rare_library.tsv")
    save_rare_library_tsv(rare_library, output_tsv_file)

    local_elapsed = time() - local_start  # Reconstruction time for current subject/session/method
    println("🕒 Reconstruction time for $(subject_name) $(session_name) $(current_method): $(local_elapsed) seconds")
  end
end

# À ce stade, le dictionnaire rare_library est rempli.
# Définir le chemin du fichier TSV pour enregistrer rare_library


# *********************************************************************
# Partie 3 : Vérification de l'orientation et création d'une version modifiée
#           dans un dossier séparé (sans modifier les originaux)
# *********************************************************************

# Fonctions de vérification de l'orientation via mrinfo

"""
    get_mrinfo_output(file::String)::String

Exécute `mrinfo -quiet` sur le fichier donné et retourne la sortie.
"""
function get_mrinfo_output(file::String)::String
    cmd = `mrinfo -quiet $file`
    try
        return read(cmd, String)
    catch e
        println("Erreur lors de l'exécution de mrinfo pour $file : $e")
        return ""
    end
end

"""
    check_dimensions(info::String)::Bool

Extrait la ligne "Dimensions:" de la sortie de mrinfo et vérifie que les trois premières valeurs
correspondent à "144", "192" et "144". Retourne true si l’orientation est conforme, false sinon.
"""
function check_dimensions(info::String)::Bool
    pattern = r"Dimensions:\s+([\d\sx]+)"
    m = match(pattern, info)
    if m === nothing
        println("Aucune information de dimensions trouvée dans mrinfo.")
        return false
    end
    dims_str = m.captures[1]          # par exemple "192 x 144 x 144 x 1"
    dims = split(dims_str, 'x')
    dims = [strip(s) for s in dims]
    if length(dims) < 3
        println("Données de dimensions incomplètes : $dims")
        return false
    end
    # Vérifier que l’ordre est 144 x 192 x 144
    d1, d2, d3 = dims[1:3]
    return d1 == "144" && d2 == "192" && d3 == "144"
end

"""
    apply_mrtrix_pipeline(file::String, final_folder::String)::String

Applique la commande MRtrix suivante pour créer une version modifiée de l'image :
    mrconvert --axes 1,0,2 <input> <output>
Le fichier final est sauvegardé dans le dossier final_folder sans modifier l'original.
"""
function apply_mrtrix_pipeline(file::String, final_folder::String, rare_path::String)::String

  # Définir les chemins
  base = basename(file)
  backup_file = file * ".bak"
  tmp_file = joinpath(final_folder, "tmp_" * base)

  # Sauvegarder le fichier original
  cp(file, backup_file; force=true)

  # Copier vers un fichier temporaire dans le dossier final
  cp(file, tmp_file; force=true)

  try
      # Appliquer les transformations sur le fichier temporaire
      run(`mrconvert --axes 1,0,2 $tmp_file $tmp_file -force`)
      run(`mrtransform --flip 1 $tmp_file $tmp_file -force`)
      run(`mrconvert --strides 1,2,3 $tmp_file $tmp_file -force`)
      run(`mrtransform $tmp_file --replace $rare_path $tmp_file -force`)

      # Remplacer le fichier original avec le fichier modifié
      mv(tmp_file, file; force=true)

      # Supprimer le fichier de sauvegarde
      rm(backup_file; force=true)

      println("Fichier modifié avec succès : $file")
      return file

  catch e
      # En cas d'erreur : restauration du fichier original
      println("Erreur lors de la transformation de $file : $e")
      println("Restauration du fichier original...")
      mv(backup_file, file; force=true)

      # Nettoyer le fichier temporaire s’il existe
      isfile(tmp_file) && rm(tmp_file; force=true)

      return file
  end
end


"""
fix_bids_nifti_modified(bids_dir::String, final_folder::String)

Parcourt le dossier BIDS et, pour chaque image NIfTI dont l’orientation est incorrecte,
applique la transformation via MRtrix et stocke le fichier modifié dans final_folder.
"""
function fix_bids_nifti_modified(bids_dir::String, final_folder::String, rare_library::Dict{String, String})
  println("Vérification des fichiers NIfTI dans le dossier BIDS : $bids_dir")

  for (root, _, files) in walkdir(bids_dir)
    if "derivatives" in splitpath(root)
      continue
    end
      for file in files
          if endswith(file, ".nii") || endswith(file, ".nii.gz")
              file_path = joinpath(root, file)
              println("🔍 Vérification de l'image : $file_path")

              info = get_mrinfo_output(file_path)
              if !check_dimensions(info)
                  println("🔧 Orientation incorrecte pour $file_path, application de la transformation...")

                  # Extraction de l'ID à partir du nom de fichier
                  m = match(r"(sub-[^_]+)_(ses-[^_]+)", file)
                  if m !== nothing
                      id = "$(m.captures[1])_$(m.captures[2])"

                      if haskey(rare_library, id)
                          rare_path = rare_library[id]
                          modified_file = apply_mrtrix_pipeline(file_path, final_folder, rare_path)
                          println("✅ Fichier final modifié créé : $modified_file")
                      else
                          println("❌ Aucun fichier RARE trouvé pour l'ID : $id — transformation ignorée.")
                      end
                  else
                      println("❌ Nom de fichier incompatible pour extraction ID : $file")
                  end
              else
                  println("✔️ Orientation correcte pour $file_path")
              end
          end
      end
  end
end

begin
  local_start = time()  # Start timer for current reconstruction
  # Lancement du script de brain extraction (si nécessaire)
  python_script = "brain_extraction.py"
  command = `/workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/python3 $python_script -r $bids_root`
  run(command)
  local_elapsed = time() - local_start
end

# Création d'un dossier pour les fichiers modifiés (sans altérer l'original)
final_modified_folder = joinpath(pwd(), "modified")
mkpath(final_modified_folder)

local_start = time()  # Start timer for current reconstruction
fix_bids_nifti_modified(bids_root, final_modified_folder, rare_library)
local_elapsed = time() - local_start

if isdir(final_modified_folder)
  rm(final_modified_folder; recursive=true, force=true)
  println("Le dossier temporaire 'modified' a été supprimé.")
end




# Cherche toutes les images T1map, T2map, UNIT1 dans les sous-dossiers anat/
patterns = ["*T1map.nii.gz", "*T2map.nii.gz", "*UNIT1.nii.gz"]
anat_paths = String[]

# Parcourt tous les sous-dossiers `sub-*` et `ses-*`
for sub in filter(isdir, glob("sub-*", bids_root))
    for ses in filter(isdir, glob("ses-*", sub))
        anat_dir = joinpath(ses, "anat")
        if isdir(anat_dir)
            for pattern in patterns
                found = glob(pattern, anat_dir)
                append!(anat_paths, found)
            end
        end
    end
end

# Affiche les chemins trouvés
println("Fichiers trouvés :")
foreach(println, anat_paths)

for acq_path in anat_paths
  local_start = time()  
  # Extraire les infos depuis le chemin
  parts = splitpath(acq_path)
  subject = parts[end-3]
  session = parts[end-2]
  filename = basename(acq_path)

  # Détection du type d'image selon le nom du fichier
  modality_folder = ""
  if occursin("T1map", filename)
      modality_folder = "T1map"
  elseif occursin("T2map", filename)
      modality_folder = "T2map"
  elseif occursin("UNIT1", filename)
      modality_folder = "UNIT1"
  else
      modality_folder = "autres"
  end

  # Construction du mask path (celui-ci reste inchangé)
  mask_path = joinpath(bids_root, "derivatives", subject, session, "anat", "$(subject)_$(session)_RARE_mask_final.nii.gz")

  # Création d’un nom de fichier masqué 
  # Ici, on récupère le dernier champ séparé par "_" qui devrait correspondre au type (T1map, T2map, etc.)
  suffix = replace(filename, r"\.nii\.gz" => "")
  modality_detected = split(suffix, "_")[end]
  output_filename = "$(subject)_$(session)_$(modality_detected)_masked.nii.gz"

  # Construction du nouveau chemin de sortie 
  # On place le résultat dans un dossier regroupant les templates selon leur modalité
  output_path = joinpath(bids_root, "derivatives", "Brain_extracted", modality_folder, output_filename)
  
  # Crée le dossier de sortie s'il n'existe pas
  mkpath(dirname(output_path))
  
  if isfile(output_path)
    println("⏩ Déjà traité : $output_filename, on saute.")
    continue
  end


  # Commande Python à exécuter pour appliquer le masque
  python_script = "mask_aaply.py"
  command = `/workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/python3 $python_script --mask $mask_path --acq $acq_path --output $output_path`
  println("🧠 Traitement : $filename, sauvegarde dans le dossier $modality_folder")
  run(command)
  local_elapsed = time() - local_start
  println("🕒 Temps application mask $(local_elapsed) seconds")
end

function T2_star_FC3R(MGE_path,mask)
    file = BrukerFile(MGE_path)
    reco = recoData(file)
    
    reco = reco[:,end:-1:1,:,:]

    x = length(reco[:,1,1,1])
    y = length(reco[1,:,1,1])
    z = length(reco[1,1,:,1])
    n_echo = length(reco[1,1,1,:])
  
    T2_star_map = Array{Float64}(undef, x, y, z);
    R_map = Array{Float64}(undef, x, y, z);
    model(t, p) = sqrt.((p[1] * exp.(-t / p[2])) .^ 2 .+ 2 * 4 * p[3]^2)
    x_abs = parse.(Float64,file["EffectiveTE"])

    corner1_noise = reco[1:3,86:106,1:3,1]
    corner2_noise = reco[1:3,86:106,end-2:end,1]
    corner3_noise = reco[end-2:end,86:106,1:3,1]
    corner4_noise = reco[end-2:end,86:106,end-2:end,1]

    sum_noise = vcat(reshape(corner1_noise, 3*21*3), reshape(corner2_noise, 3*21*3), reshape(corner3_noise, 3*21*3), reshape(corner4_noise, 3*21*3))
    noise = std(sum_noise)

    for i in 1:x
        for j in 1:y
            for k in 1:z
                if (mask[i,j,k] == 1)
                    p0 = [maximum(abs.(reco[i,j,k,1:n_echo])), 30, noise]
                    try 
                        fit = LsqFit.curve_fit(model, Float32.(x_abs), abs.(reco[i,j,k,1:n_echo]), p0)
                    catch
                        T2_star_map[i,j,k] = 0
                        R_map[i,j,k] = 0
                     
                    else
    
                        fit = LsqFit.curve_fit(model, Float32.(x_abs), abs.(reco[i,j,k,1:n_echo]), p0)
    
                        a = fit.param[1]
                        b = fit.param[2]
                        c = fit.param[3]
    
                        line = sqrt.((a * exp.(-x_abs / b)) .^ 2 .+ 2 * 4 * c^2)
                        if (r2_score(line, abs.(reco[i,j,k,1:n_echo]))) < 0
                            T2_star_map[i,j,k] = 0
                            R_map[i,j,k] = r2_score(line, reco[i,j,k,1:n_echo])
                        else
                            T2_star_map[i,j,k] = fit.param[2]
                            R_map[i,j,k] = r2_score(line, reco[i,j,k,1:n_echo])
                        end
    
    
                    end
                else
                    T2_star_map[i,j,k] = 0
                    R_map[i,j,k] = 0
                end
            end
        end
    end

    # ni = NIVolume(T2_star_map)
    # niwrite(joinpath("T2*map.nii.gz"), ni)

    # ni = NIVolume(R_map)
    # niwrite(joinpath("Rmap.nii.gz"), ni)

    return T2_star_map, R_map
end

#T2star
for i in eachindex(df.Method)
  subject_name = "sub-" * string(df[i, :ID])
  session_name = "ses-" * string(df[i, :Session])
  session_dir = joinpath(bids_root, subject_name, session_name)
  
  anat_dir = joinpath(session_dir, "anat")
  mkpath(anat_dir)
  
  current_method = df[i, :Method]

  prefix = "$(subject_name)_$(session_name)_acq-$(current_method)_run-1"
  out_T2 = joinpath(anat_dir, "$(prefix)_T2starmap.nii.gz")
  out_R2 = joinpath(anat_dir, "$(prefix)_R2starmap.nii.gz")

  if isfile(out_T2) && isfile(out_R2)
    println("✅ Reconstruction déjà faite pour $(subject_name), $(session_name), $(current_method), on passe.")
    continue
  end

  json_patterns = [
    joinpath(anat_dir, "*_$(current_method).json"),  # Search in anat_dir
    joinpath(session_dir, "*_$(current_method).json")  # Search in parent directory
  ]

  println("Processing: ", df[i, :Filepath])
  
  if occursin(r"MGE", current_method)
    local_start = time()  
    mask_file = joinpath(
      bids_root, "derivatives",
      subject_name, session_name,
      "anat",
      "$(subject_name)_$(session_name)_RARE_mask_final.nii.gz"
    )

    if isfile(mask_file)
      # Lecture du NIfTI + extraction de la matrice binaire
      mymask_ni = NIfTI.niread(mask_file)  
      # mask    = mask_ni.data            

      # Appel T2* avec la vraie matrice
      T2star, Rmap = T2_star_FC3R(df[i, :Filepath], mymask_ni)

      prefix    = "$(subject_name)_$(session_name)_acq-$(current_method)_run-1"
      out_T2    = joinpath(anat_dir, "$(prefix)_T2starmap.nii.gz")
      out_R2    = joinpath(anat_dir, "$(prefix)_R2starmap.nii.gz")
      
      # 2) dossier de destination unique pour toutes les cartes extraites
      out_brain = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted"
      brain_t2star_dir = joinpath(out_brain, "T2starmap")
      mkpath(brain_t2star_dir)
      
      # 3) écriture dans anat/
      niwrite(out_T2, NIVolume(T2star))
      niwrite(out_R2, NIVolume(Rmap))
      
      # 4) copie directe dans T2starmap (sans structure sub/ses)
      filename_T2_masked = replace(basename(out_T2), r"\.nii\.gz$" => "_masked.nii.gz")
      copy_T2 = joinpath(brain_t2star_dir, filename_T2_masked)
      niwrite(copy_T2, NIVolume(T2star))

      
      python_script = "Parser_Bruker_file.py"
      command = `python3 $python_script $(df[i, :Filepath]) $anat_dir --mode T2STAR --json_name "$(prefix)_T2starmap.json"`
      run(command)

      python_script = "Parser_Bruker_file.py"
      command = `python3 $python_script $(df[i, :Filepath]) $anat_dir --mode T2STAR --json_name "$(prefix)_R2starmap.json"`
      run(command)
      local_elapsed = time() - local_start
      println("🕒 Temps Reconstruction T2star $(local_elapsed) seconds")
    else
      println("⚠️ Impossible de trouver le masque : ", mask_file)
    end
  end
end


# ANGIO
for row in eachrow(df)
  local_start = time()
  id = row.ID
  session = row.Session

  group = filter(r -> r.ID == id && r.Session == session && lowercase(r.Method) == "fcflash", df)
  paths = group.Filepath

  if length(paths) != 3
      println("❌ Pas 3 fichiers FcFLASH pour sub-$id ses-$session (trouvé: $(length(paths)))")
      continue
  end

  subject_name = "sub-" * string(id)
  session_name = "ses-" * string(session)
  anat_dir = joinpath(bids_root, subject_name, session_name, "anat")
  mkpath(anat_dir)
  final_bids_name = joinpath(anat_dir, "$(subject_name)_$(session_name)_angio.nii.gz")

  if isfile(final_bids_name)
    println("⏩ Déjà traité : $final_bids_name")
    continue
  end

  # === [1] Créer dossier temporaire ===
  temp_dir = joinpath("./temp_angio", "sub-$(id)_ses-$(session)")
  mkpath(temp_dir)

  # === [2] Exécution dans dossier temporaire ===
  split_parts = split(paths[1], "/")
  basepath = joinpath(split_parts[1:end-1]...)
  basename = split_parts[end-1]

  nii_files = String[]
  cd(temp_dir) do
      for path in paths
          endpath = split(path, "/")[end]
          filename = "*-$endpath-1-FcFLASH_1-(E$endpath).nii.gz"
          push!(nii_files, filename)

          run(`brkraw tonii /$basepath -s $endpath`)
      end

      # Lancer le traitement angio
      bash_script = "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/scr/angio.sh"
      run(`bash $bash_script $(nii_files[1]) $(nii_files[2]) $(nii_files[3])`)
      local_elapsed = time() - local_start
      println("🕒 Temps Reconstruction ANGIO $(local_elapsed) seconds")
  end

  # === [3] Copie vers BIDS ===
  final_temp_path = joinpath(temp_dir, "angio_final.nii.gz")
  cp(final_temp_path, final_bids_name; force=true)
  println("✅ Copié dans BIDS : $final_bids_name")

  python_script = "Parser_Bruker_file.py"
  command = `python3 $python_script $(paths[1]) $anat_dir --mode T2STAR --json_name "sub-$(id)_ses-$(session)_angio.json"`
  run(command)

  # === [4] Nettoyage ===
  try
      rm(temp_dir; force=true, recursive=true)
      println("🧹 Temporaire supprimé : $temp_dir")
  catch e
      println("⚠️ Erreur lors de la suppression de $temp_dir : $e")
  end

end

local_start = time()
python_script = "Mask_angio.py"
command = `python3 $python_script`
run(command)
local_elapsed = time() - local_start
println("🕒 Temps mask angio $(local_elapsed) seconds")

local_start = time()
# version d'avant double registration
# run(`./Allign.sh`)
# run(`./Find_Matrice.sh`) #chnager l'image dereference dans le script et le chnager dans tous les script qui suit

# nouvelel version avec SyN
run(`./Find_Matrice_SyN.sh`)
run(`./Align_SyN.sh`)
local_elapsed = time() - local_start
println("🕒 Temps Alignement $(local_elapsed) seconds")

run(`./Seuil_T2star.sh`)



local_start = time()
run(`./Template_v2.sh RARE S01 4`)
local_elapsed = time() - local_start
println("🕒 Temps template $(local_elapsed) seconds")

run(`./Template_v2.sh RARE S02 4`)

local_start = time()
run(`./apply_to_template.sh T1map`)
run(`./apply_to_template.sh UNIT1`)
run(`./apply_to_template.sh T2map`)
run(`./apply_to_template.sh angio`)
run(`./apply_to_template.sh T2starmap`)

run(`./Make_Template.sh T1map`)
run(`./Make_Template.sh UNIT1`)
run(`./Make_Template.sh T2map`)
run(`./Make_Template.sh angio`)
run(`./Make_Template.sh T2starmap`)
local_elapsed = time() - local_start
println("🕒 Temps Template $(local_elapsed) seconds")

global_elapsed = time() - global_start  # Total reconstruction time
println("Total reconstruction time: $(global_elapsed) seconds")

run(`./apply_to_template.sh QSM`)
run(`./Make_Template.sh QSM`)
