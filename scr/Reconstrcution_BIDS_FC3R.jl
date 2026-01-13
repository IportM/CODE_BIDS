#!/usr/bin/env julia

#############################
# FC3R Reconstruction Pipeline
#############################

using CSV
using DataFrames
using Dates
using JSON
using Glob
using Statistics

using NIfTI
using MRIFiles
using LsqFit
using Metrics

using SEQ_BRUKER_a_MP2RAGE_CS_360
using PyCall

import Base.Filesystem: mkpath, isfile, touch

# ---------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------

"""
Global configuration for the FC3R reconstruction pipeline.

Adjust these paths for your environment. For publication / sharing, the
idea is that users only have to edit this section.
"""
const FC3R_CONFIG = Dict(
    # Root raw data directories (Bruker directories grouped by S01/S02/S03)
    :input_dirs => [
        "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/DATA/S01",
        "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/DATA/S02",
        "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/DATA/S03",
    ],

    # Project root (used to build BIDS root, scripts paths, etc.)
    :project_root => dirname(@__DIR__),

    # Python executable to use for most neuroimaging scripts
    :python_bin => "/workspace_QMRI/USERS_CODE/mpetit/AntsPyEnv/bin/python3",

    # Brkraw executable
    :brkraw_bin => "brkraw",

    # Output location for derived Brain_extracted maps (T1/T2/UNIT1/T2*)
    :brain_extracted_root =>
        "/workspace_QMRI/PROJECTS_DATA/2024_RECH_FC3R/CODE_BIDS/BIDS/derivatives/Brain_extracted",
)

# Convenience helpers
bids_root() = joinpath(FC3R_CONFIG[:project_root], "BIDS")
rare_library_tsv_path() = joinpath(pwd(), "rare_library.tsv")
# python_dir() = joinpath(FC3R_CONFIG[:project_root], "python")
# bash_dir() = joinpath(FC3R_CONFIG[:project_root], "scr")
scripts_root() = joinpath(FC3R_CONFIG[:project_root], "scr")

# Ex: step = "01_BIDS", "02_reco", ...
step_path(step::AbstractString, file::AbstractString) = joinpath(scripts_root(), step, file)


# =====================================================================
# PART 1 – Raw Bruker → TSV metadata (sessions, methods, etc.)
# =====================================================================

"""
    extract_method_information(filepath::String) -> (date::String, id::String, method::String)

Parse a Bruker `method` file and extract:
- acquisition date
- animal ID (e.g. "M01")
- acquisition method name
"""
function extract_method_information(filepath::String)
    date, id_value, method = "", "", ""

    open(filepath, "r") do file
        for line in eachline(file)
            # Date at the top: $$ yyyy-mm-dd ...
            if occursin(r"^\$\$ \d{4}-\d{2}-\d{2}", line) && isempty(date)
                date_match = match(r"\d{4}-\d{2}-\d{2}", line)
                date = date_match === nothing ? "" : date_match.match
            end

            # Animal ID: "Mxx"
            if occursin(r"M\d+", line) && isempty(id_value)
                id_match = match(r"M(\d+)", line)
                id_value = id_match === nothing ? "" : id_match.captures[1]
            end

            # Method name: ##$Method=<Bruker:SEQ_NAME> or <User:SEQ_NAME>
            if occursin(r"##\$Method=<", line) && isempty(method)
                method_match = match(r"##\$Method=<(?:Bruker:|User:)([^>]+)>", line)
                method = method_match === nothing ? "" : method_match.captures[1]
            end

            if !isempty(date) && !isempty(id_value) && !isempty(method)
                break
            end
        end
    end

    return date, id_value, isempty(method) ? "Not found" : method
end

"""
    process_bruker_directory(root_dir::String; write_file::Bool=false, output_tsv::String="") -> DataFrame

Walk a tree of Bruker directories, detect `method` files that have a `rawdata.job0`
and build a DataFrame with:

- Filepath: path to the Bruker series
- Date: acquisition date (Date)
- ID: mouse ID (string)
- Method: cleaned method name
- Session: session index (integer, approximate, later refined globally)
"""
function process_bruker_directory(directorypath::String; write_file::Bool = false, output_tsv::String = "")
    results = DataFrame(Filepath = String[], Date = String[], ID = String[], Method = String[])

    for (root, _, files) in walkdir(directorypath)
        for file in files
            if file == "method"
                method_file = joinpath(root, file)
                parent_dir = dirname(method_file)

                # Only keep entries that have a Bruker rawdata job
                if isfile(joinpath(parent_dir, "rawdata.job0"))
                    date, id_value, method = extract_method_information(method_file)
                    if !isempty(date) && !isempty(id_value) && !isempty(method)
                        push!(results, (parent_dir, date, id_value, method))
                    end
                end
            end
        end
    end

    # Clean and normalize Method strings
    results.Method .= replace.(results.Method, r"^a_|_CS_360$" => "")
    results.Method .= replace.(results.Method, r".*RARE.*" => "RARE")
    results = filter(row -> row.Method != "FLASH", results)

    # Convert Date column to Date type
    results.Date = Date.(results.Date, "yyyy-mm-dd")

    # Rough session index (per-ID, increasing with date)
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

    # Suffix used to sort multiple series acquired the same day
    results.Suffix = [
        let m = match(r"(\d+)$", fp)
            m === nothing ? 0 : parse(Int, m.captures[1])
        end for fp in results.Filepath
    ]

    sort!(results, [:ID, :Session, :Suffix])
    select!(results, Not(:Suffix))

    if write_file && !isempty(output_tsv)
        CSV.write(output_tsv, results; delim = '\t')
        println("Raw Bruker metadata written to $output_tsv")
    end

    return results
end

"""
    load_rare_library_tsv(path::String) -> Dict{String,String}

Load a TSV file that maps `sub-XX_ses-YY` → path to the corresponding RARE image.
If the file does not exist, return an empty Dict.
"""
function load_rare_library_tsv(file::String)::Dict{String,String}
    if !isfile(file)
        return Dict{String,String}()
    end
    df = CSV.read(file, DataFrame; delim = '\t')
    return Dict(row.ID_Session => row.Filepath for row in eachrow(df))
end

"""
    save_rare_library_tsv(rare_library, output_file)

Persist the `rare_library` dictionary into a TSV file with columns:
- ID_Session
- Filepath
"""
function save_rare_library_tsv(rare_library::Dict{String, String}, output_file::String)
    df = DataFrame(ID_Session = String[], Filepath = String[])
    for (k, v) in pairs(rare_library)
        push!(df, (k, v))
    end

    CSV.write(output_file, df; delim = '\t')
    println("Rare library saved to $output_file")
end

"""
    build_global_sessions(input_dirs::Vector{String}) -> DataFrame

High-level helper:
- call `process_bruker_directory` on each S0X directory
- normalize ID to two digits
- define sessions across S01/S02/S03 using:
  - DossierNum (1,2,3)
  - unique (DossierNum, Date) per animal
"""
function build_global_sessions(input_dirs::Vector{String})
    all_results = DataFrame()

    for directorypath in input_dirs
        df_partial = process_bruker_directory(directorypath; write_file = false)
        df_partial.ID .= lpad.(parse.(Int, df_partial.ID), 2, '0')
        append!(all_results, df_partial)
    end

    all_results.ID .= lpad.(parse.(Int, all_results.ID), 2, '0')

    # Extract S01/S02/S03 index from the path
    all_results.DossierNum = [
        let m = match(r"/S(\d+)/", fp)
            m === nothing ? 0 : parse(Int, m.captures[1])
        end for fp in all_results.Filepath
    ]

    all_results.Suffix = [
        let m = match(r"(\d+)$", fp)
            m === nothing ? 0 : parse(Int, m.captures[1])
        end for fp in all_results.Filepath
    ]

    sort!(all_results, [:ID, :DossierNum, :Date, :Suffix])
    all_results.Session = zeros(Int, nrow(all_results))

    for id in unique(all_results.ID)
        participant_mask = all_results.ID .== id
        participant_data = all_results[participant_mask, :]

        unique_sessions = unique([(row.DossierNum, row.Date) for row in eachrow(participant_data)])
        sort!(unique_sessions)

        for (dossier_num, date) in unique_sessions
            session_number = if dossier_num == 1
                s01_dates = sort(unique([d for (dn, d) in unique_sessions if dn == 1]))
                findfirst(==(date), s01_dates)
            elseif dossier_num == 2
                s02_dates = sort(unique([d for (dn, d) in unique_sessions if dn == 2]))
                3 + findfirst(==(date), s02_dates) - 1
            elseif dossier_num == 3
                s01_count = length(unique([d for (dn, d) in unique_sessions if dn == 1]))
                s02_count = length(unique([d for (dn, d) in unique_sessions if dn == 2]))
                s03_dates = sort(unique([d for (dn, d) in unique_sessions if dn == 3]))
                s01_count + s02_count + findfirst(==(date), s03_dates)
            else
                1
            end

            mask = (all_results.ID .== id) .&
                   (all_results.DossierNum .== dossier_num) .&
                   (all_results.Date .== date)

            all_results[mask, :Session] .= session_number
        end
    end

    sort!(all_results, [:ID, :Session, :Suffix])
    select!(all_results, Not([:DossierNum, :Suffix]))

    return all_results
end

# =====================================================================
# PART 2 – Reconstruction per method (MP2RAGE, MESE, RARE)
# =====================================================================

"""
    reconstruct_MP2RAGE_series(bruker_path, subject_name, session_name, anat_dir, method)

Run MP2RAGE reconstruction using `reconstruction_MP2RAGE` from
SEQ_BRUKER_a_MP2RAGE_CS_360 and write UNIT1 + T1map + magnitude/phase images.
"""
function reconstruct_MP2RAGE_series(bruker_path::String,
                                    subject_name::String,
                                    session_name::String,
                                    anat_dir::String,
                                    current_method::String)

    local_start = time()

    d = reconstruction_MP2RAGE(bruker_path; mean_NR = true, slab_correction = true)

    mp2_file = joinpath(anat_dir, "$(subject_name)_mp2_params.json")
    open(mp2_file, "w") do io
        JSON.print(io, d["params_MP2RAGE"])
    end

    path_suffixes = [
        "_inv-1_part-mag_MP2RAGE",
        "_inv-1_part-phase_MP2RAGE",
        "_inv-1_part-complex_MP2RAGE",
        "_inv-2_part-mag_MP2RAGE",
        "_inv-2_part-phase_MP2RAGE",
        "_inv-2_part-complex_MP2RAGE",
        "_UNIT1",
        "_T1map",
    ]

    data_arrays = [
        abs.(d["im_reco"][:, :, :, :, 1]),
        angle.(d["im_reco"][:, :, :, :, 1]),
        d["im_reco"][:, :, :, :, 1],
        abs.(d["im_reco"][:, :, :, :, 2]),
        angle.(d["im_reco"][:, :, :, :, 2]),
        d["im_reco"][:, :, :, :, 2],
        d["MP2RAGE"],
        d["T1map"],
    ]

    voxel_size = tuple(parse.(Float64, d["params_prot"]["PVM_SpatResol"])...)

    for (suffix, data) in zip(path_suffixes, data_arrays)
        ni = NIVolume(abs.(data), voxel_size = voxel_size)
        out_nii = joinpath(anat_dir, "$(subject_name)_$(session_name)$(suffix).nii.gz")
        niwrite(out_nii, ni)
    end

    python_script = step_path("01_BIDS", "Parser_Bruker_file.py")
    cmd = `$(FC3R_CONFIG[:python_bin]) $python_script $bruker_path $anat_dir --mp2_file $mp2_file --json_name "$(subject_name)_$(session_name)_$(current_method).json"`
    run(cmd)

    isfile(mp2_file) && rm(mp2_file)

    println("🕒 MP2RAGE reconstruction for $subject_name $session_name $current_method: $(time() - local_start) seconds")
end

"""
    reconstruct_MESE_series(bruker_path, subject_name, session_name, anat_dir, method)

Call the external MESE reconstruction Julia project.
"""
function reconstruct_MESE_series(bruker_path::String,
                                subject_name::String,
                                session_name::String,
                                anat_dir::String,
                                current_method::String)

    local_start = time()

    mese_out = joinpath(anat_dir, "$(subject_name)_$(session_name)")
    cmd = `julia -t auto --project=reconstruction_MESE reconstruction_MESE/main_MESE.jl $bruker_path $mese_out`
    run(cmd)

    python_script = step_path("01_BIDS", "Parser_Bruker_file.py")
    cmd2 = `$(FC3R_CONFIG[:python_bin]) $python_script $bruker_path $anat_dir --mode MESE --json_name "$(subject_name)_$(session_name)_$(current_method).json"`
    run(cmd2)

    println("🕒 MESE reconstruction for $subject_name $session_name $current_method: $(time() - local_start) seconds")
end

"""
    reconstruct_RARE_series(bruker_path, subject_name, session_name, anat_dir, method, rare_library)

Call Brkraw converter for RARE, populate rare_library, and write JSON sidecar.
"""
function reconstruct_RARE_series(bruker_path::String,
                                subject_name::String,
                                session_name::String,
                                anat_dir::String,
                                current_method::String,
                                rare_library::Dict{String,String})

    local_start = time()

    brkraw_dir = dirname(bruker_path)
    s_value = lpad(parse(Int, basename(bruker_path)), 3, '0')

    python_script = step_path("02_reco", "Brkraw_RARE.py")  # as in original code (relative, no joinpath)
    cmd = `$(FC3R_CONFIG[:python_bin]) $python_script $brkraw_dir $s_value $anat_dir "$(subject_name)_$(session_name)_$(current_method).nii.gz"`
    run(cmd)

    rare_output_path = joinpath(anat_dir, "$(subject_name)_$(session_name)_$(current_method).nii.gz")

    id_key = "$(subject_name)_$(session_name)"
    rare_library[id_key] = rare_output_path

    parser_script = step_path("01_BIDS", "Parser_Bruker_file.py")
    cmd2 = `$(FC3R_CONFIG[:python_bin]) $parser_script $bruker_path $anat_dir --mode RARE --json_name "$(subject_name)_$(session_name)_$(current_method).json"`
    run(cmd2)

    save_rare_library_tsv(rare_library, rare_library_tsv_path())

    println("🕒 RARE reconstruction for $subject_name $session_name $current_method: $(time() - local_start) seconds")
end

"""
    reconstruct_all_sequences(df::DataFrame, rare_library::Dict{String,String})

Loop over all rows of `df` and run the proper reconstruction pipeline depending
on `Method`.
"""
function reconstruct_all_sequences(df::DataFrame, rare_library::Dict{String,String})
    bids = bids_root()

    for i in eachindex(df.Method)
        subject_name = "sub-" * string(df[i, :ID])
        session_name = "ses-" * string(df[i, :Session])
        session_dir = joinpath(bids, subject_name, session_name)

        anat_dir = joinpath(session_dir, "anat")
        mkpath(anat_dir)

        current_method = df[i, :Method]

        println("Processing Bruker series: ", df[i, :Filepath])

        # Avoid re-running reconstruction if JSON for this method already exists
        json_in_anat = glob("*_$(current_method).json", anat_dir)
        json_in_session = glob("*_$(current_method).json", session_dir)
        if !isempty(json_in_anat) || !isempty(json_in_session)
            println("Reconstruction already done for $(current_method) – skipping.")
            continue
        end

        if occursin(r"MP2RAGE", current_method)
            reconstruct_MP2RAGE_series(df[i, :Filepath], subject_name, session_name, anat_dir, current_method)

        elseif occursin(r"MESE", current_method)
            reconstruct_MESE_series(df[i, :Filepath], subject_name, session_name, anat_dir, current_method)

        elseif occursin(r"RARE", current_method)
            reconstruct_RARE_series(df[i, :Filepath], subject_name, session_name, anat_dir, current_method, rare_library)
        end
    end
end

# =====================================================================
# PART 3 – Orientation check and MRtrix pipeline
# =====================================================================

"""
    get_mrinfo_output(file::String) -> String

Run `mrinfo -quiet` and return its output, or an empty string if it fails.
"""
function get_mrinfo_output(file::String)::String
    cmd = `mrinfo -quiet $file`
    try
        return read(cmd, String)
    catch e
        println("Error while running mrinfo on $file: $e")
        return ""
    end
end

"""
    check_dimensions(info::String) -> Bool

Parse the "Dimensions:" line from mrinfo output and check that
the first three dimensions are exactly 144 x 192 x 144.
"""
function check_dimensions(info::String)::Bool
    pattern = r"Dimensions:\s+([\d\sx]+)"
    m = match(pattern, info)
    if m === nothing
        println("No dimension information found in mrinfo output.")
        return false
    end

    dims_str = m.captures[1]
    dims = [strip(s) for s in split(dims_str, 'x')]
    if length(dims) < 3
        println("Incomplete dimensions: $dims")
        return false
    end

    d1, d2, d3 = dims[1:3]
    return d1 == "144" && d2 == "192" && d3 == "144"
end

"""
    apply_mrtrix_pipeline(file, final_folder, rare_path) -> String

Apply a MRtrix-based correction pipeline:

1. mrconvert --axes 1,0,2
2. mrtransform --flip 1
3. mrconvert --strides 1,2,3
4. mrtransform --replace <rare_path>

The original file is backed up as <file>.bak and restored if something fails.
"""
function apply_mrtrix_pipeline(file::String, final_folder::String, rare_path::String)::String
    base = basename(file)
    backup_file = file * ".bak"
    tmp_file = joinpath(final_folder, "tmp_" * base)

    cp(file, backup_file; force = true)
    cp(file, tmp_file; force = true)

    try
        run(`mrconvert --axes 1,0,2 $tmp_file $tmp_file -force`)
        run(`mrtransform --flip 1 $tmp_file $tmp_file -force`)
        run(`mrconvert --strides 1,2,3 $tmp_file $tmp_file -force`)
        run(`mrtransform $tmp_file --replace $rare_path $tmp_file -force`)

        mv(tmp_file, file; force = true)
        rm(backup_file; force = true)

        println("Successfully reoriented: $file")
        return file

    catch e
        println("Error while transforming $file: $e")
        println("Restoring original file...")
        mv(backup_file, file; force = true)
        isfile(tmp_file) && rm(tmp_file; force = true)
        return file
    end
end

"""
    fix_bids_nifti_modified(bids_dir, final_folder, rare_library)

Walk through the BIDS directory and, for each NIfTI file:
- run `mrinfo`
- if dimensions are not 144 x 192 x 144, try to find a RARE reference
  from `rare_library` and apply the MRtrix pipeline.
"""
function fix_bids_nifti_modified(bids_dir::String,
                                 final_folder::String,
                                 rare_library::Dict{String, String})

    println("Checking NIfTI orientation in BIDS: $bids_dir")

    for (root, _, files) in walkdir(bids_dir)
        if "derivatives" in splitpath(root)
            continue
        end

        for file in files
            if endswith(file, ".nii") || endswith(file, ".nii.gz")
                file_path = joinpath(root, file)
                println("🔍 Checking image: $file_path")

                info = get_mrinfo_output(file_path)
                if !check_dimensions(info)
                    println("🔧 Incorrect orientation, applying MRtrix pipeline...")

                    m = match(r"(sub-[^_]+)_(ses-[^_]+)", file)
                    if m !== nothing
                        id = "$(m.captures[1])_$(m.captures[2])"
                        if haskey(rare_library, id)
                            rare_path = rare_library[id]
                            modified_file = apply_mrtrix_pipeline(file_path, final_folder, rare_path)
                            println("✅ Modified file: $modified_file")
                        else
                            println("❌ No RARE reference found for ID: $id – skipping transform.")
                        end
                    else
                        println("❌ File name does not match sub-XX_ses-YY pattern: $file")
                    end
                else
                    println("✔️ Orientation OK for $file_path")
                end
            end
        end
    end
end

# =====================================================================
# PART 4 – Mask application for T1map / T2map / UNIT1
# =====================================================================

"""
    apply_masks_to_quantitative_maps()

Search for all T1map, T2map and UNIT1 NIfTI files in BIDS `anat/` folders,
and apply the corresponding RARE mask to create masked maps in
`derivatives/Brain_extracted/<modality>/`.
"""
function apply_masks_to_quantitative_maps()
    bids = bids_root()
    patterns = ["*T1map.nii.gz", "*T2map.nii.gz", "*UNIT1.nii.gz"]
    anat_paths = String[]

    for sub in filter(isdir, glob("sub-*", bids))
        for ses in filter(isdir, glob("ses-*", sub))
            anat_dir = joinpath(ses, "anat")
            if isdir(anat_dir)
                for pattern in patterns
                    append!(anat_paths, glob(pattern, anat_dir))
                end
            end
        end
    end

    println("Found $(length(anat_paths)) quantitative maps to mask.")

    for acq_path in anat_paths
        local_start = time()

        parts = splitpath(acq_path)
        subject = parts[end - 3]
        session = parts[end - 2]
        filename = basename(acq_path)

        modality_folder =
            if occursin("T1map", filename)
                "T1map"
            elseif occursin("T2map", filename)
                "T2map"
            elseif occursin("UNIT1", filename)
                "UNIT1"
            else
                "autres"
            end

        mask_path = joinpath(
            bids, "derivatives",
            subject, session,
            "anat",
            "$(subject)_$(session)_RARE_mask_final.nii.gz",
        )

        # Build output file name as in your original code
        suffix = replace(filename, r"\.nii\.gz" => "")
        modality_detected = split(suffix, "_")[end]
        output_filename = "$(subject)_$(session)_$(modality_detected)_masked.nii.gz"

        output_path = joinpath(bids, "derivatives", "Brain_extracted", modality_folder, output_filename)
        mkpath(dirname(output_path))

        if isfile(output_path)
            println("⏩ Already masked: $output_filename, skipping.")
            continue
        end

        # ORIGINAL BEHAVIOR: use script "mask_aaply.py" and hard-coded python bin
        python_script = step_path("03_masks", "mask_aaply.py")
        command = `$(FC3R_CONFIG[:python_bin]) $python_script --mask $mask_path --acq $acq_path --output $output_path`
        println("🧠 Applying mask to: $filename → $modality_folder")
        run(command)
        println("🕒 Mask application time: $(time() - local_start) seconds")
    end
end

# =====================================================================
# PART 5 – T2* mapping (original behavior)
# =====================================================================

"""
    T2_star_FC3R(MGE_path, mask)

Original T2* fitting function from the FC3R pipeline.

This version keeps the exact behavior of your initial script:
- input `mask` is used directly as `mask[i,j,k] == 1`
- same noise ROI, same model, same logic for R² check.
"""
function T2_star_FC3R(MGE_path, mask)
    file = BrukerFile(MGE_path)
    reco = recoData(file)
    
    reco = reco[:, end:-1:1, :, :]

    x = length(reco[:, 1, 1, 1])
    y = length(reco[1, :, 1, 1])
    z = length(reco[1, 1, :, 1])
    n_echo = length(reco[1, 1, 1, :])
  
    T2_star_map = Array{Float64}(undef, x, y, z)
    R_map       = Array{Float64}(undef, x, y, z)

    model(t, p) = sqrt.((p[1] * exp.(-t / p[2])) .^ 2 .+ 2 * 4 * p[3]^2)
    x_abs = parse.(Float64, file["EffectiveTE"])

    corner1_noise = reco[1:3, 86:106, 1:3, 1]
    corner2_noise = reco[1:3, 86:106, end-2:end, 1]
    corner3_noise = reco[end-2:end, 86:106, 1:3, 1]
    corner4_noise = reco[end-2:end, 86:106, end-2:end, 1]

    sum_noise = vcat(
        reshape(corner1_noise, 3*21*3),
        reshape(corner2_noise, 3*21*3),
        reshape(corner3_noise, 3*21*3),
        reshape(corner4_noise, 3*21*3),
    )
    noise = std(sum_noise)

    for i in 1:x
        for j in 1:y
            for k in 1:z
                if mask[i, j, k] == 1
                    p0 = [maximum(abs.(reco[i, j, k, 1:n_echo])), 30, noise]
                    try 
                        fit = LsqFit.curve_fit(model, Float32.(x_abs), abs.(reco[i, j, k, 1:n_echo]), p0)
                    catch
                        T2_star_map[i, j, k] = 0
                        R_map[i, j, k]       = 0
                    else
                        fit = LsqFit.curve_fit(model, Float32.(x_abs), abs.(reco[i, j, k, 1:n_echo]), p0)

                        a = fit.param[1]
                        b = fit.param[2]
                        c = fit.param[3]

                        line = sqrt.((a * exp.(-x_abs / b)) .^ 2 .+ 2 * 4 * c^2)
                        if r2_score(line, abs.(reco[i, j, k, 1:n_echo])) < 0
                            T2_star_map[i, j, k] = 0
                            R_map[i, j, k]       = r2_score(line, reco[i, j, k, 1:n_echo])
                        else
                            T2_star_map[i, j, k] = fit.param[2]
                            R_map[i, j, k]       = r2_score(line, reco[i, j, k, 1:n_echo])
                        end
                    end
                else
                    T2_star_map[i, j, k] = 0
                    R_map[i, j, k]       = 0
                end
            end
        end
    end

    return T2_star_map, R_map
end

"""
    reconstruct_T2star(df::DataFrame)

Loop on all rows, detect MGE sequences, and compute T2* and R2* maps
into BIDS anat folder and into `Brain_extracted/T2starmap`.
"""
function reconstruct_T2star(df::DataFrame)
    bids = bids_root()
    out_brain = FC3R_CONFIG[:brain_extracted_root]
    brain_t2star_dir = joinpath(out_brain, "T2starmap")
    mkpath(brain_t2star_dir)

    for i in eachindex(df.Method)
        subject_name = "sub-" * string(df[i, :ID])
        session_name = "ses-" * string(df[i, :Session])
        session_dir = joinpath(bids, subject_name, session_name)
        anat_dir = joinpath(session_dir, "anat")
        mkpath(anat_dir)

        current_method = df[i, :Method]
        prefix = "$(subject_name)_$(session_name)_acq-$(current_method)_run-1"
        out_T2 = joinpath(anat_dir, "$(prefix)_T2starmap.nii.gz")
        out_R2 = joinpath(anat_dir, "$(prefix)_R2starmap.nii.gz")

        if isfile(out_T2) && isfile(out_R2)
            println("✅ T2* already reconstructed for $subject_name $session_name $current_method – skipping.")
            continue
        end

        println("Processing: ", df[i, :Filepath])

        if occursin(r"MGE", current_method)
            local_start = time()
            mask_file = joinpath(
                bids, "derivatives",
                subject_name, session_name,
                "anat",
                "$(subject_name)_$(session_name)_RARE_mask_final.nii.gz",
            )

            if isfile(mask_file)
                # EXACT original behavior: pass result of NIfTI.niread directly as `mask`
                mymask_ni = NIfTI.niread(mask_file)
                T2star, Rmap = T2_star_FC3R(df[i, :Filepath], mymask_ni)

                niwrite(out_T2, NIVolume(T2star))
                niwrite(out_R2, NIVolume(Rmap))

                filename_T2_masked = replace(basename(out_T2), r"\.nii\.gz$" => "_masked.nii.gz")
                copy_T2 = joinpath(brain_t2star_dir, filename_T2_masked)
                niwrite(copy_T2, NIVolume(T2star))

                parser_script = step_path("01_BIDS", "Parser_Bruker_file.py")
                run(`$(FC3R_CONFIG[:python_bin]) $parser_script $(df[i, :Filepath]) $anat_dir --mode T2STAR --json_name "$(prefix)_T2starmap.json"`)
                run(`$(FC3R_CONFIG[:python_bin]) $parser_script $(df[i, :Filepath]) $anat_dir --mode T2STAR --json_name "$(prefix)_R2starmap.json"`)

                println("🕒 T2* reconstruction time: $(time() - local_start) seconds")
            else
                println("⚠️ Missing mask file: ", mask_file)
            end
        end
    end
end

# =====================================================================
# PART 6 – Angiography, alignment & templates
# =====================================================================

"""
    reconstruct_angio(df::DataFrame)

Reconstruct angiography images for each subject/session that has exactly
3 FcFLASH acquisitions (method name "fcflash", case-insensitive).
"""
function reconstruct_angio(df::DataFrame)
    bids = bids_root()
    project_root = FC3R_CONFIG[:project_root]
    brkraw_bin = FC3R_CONFIG[:brkraw_bin]
    angio_script = step_path("02_reco", "angio.sh")
    parser_script = step_path("01_BIDS", "Parser_Bruker_file.py")

    for row in eachrow(df)
        local_start = time()
        id = row.ID
        session = row.Session

        # Group all FcFLASH series for this subject/session
        group = filter(r -> r.ID == id && r.Session == session && lowercase(r.Method) == "fcflash", df)
        paths = group.Filepath

        if length(paths) != 3
            if length(paths) > 0
                println("❌ Not exactly 3 FcFLASH files for sub-$id ses-$session (found: $(length(paths)))")
            end
            continue
        end

        subject_name = "sub-" * string(id)
        session_name = "ses-" * string(session)
        anat_dir = joinpath(bids, subject_name, session_name, "anat")
        mkpath(anat_dir)
        final_bids_name = joinpath(anat_dir, "$(subject_name)_$(session_name)_angio.nii.gz")

        if isfile(final_bids_name)
            println("⏩ Angio already reconstructed: $final_bids_name")
            continue
        end

        # Temporary working directory
        temp_dir = joinpath(project_root, "temp_angio", "sub-$(id)_ses-$(session)")
        mkpath(temp_dir)

        # Convert Bruker → NIfTI and then run angio script
        split_paths = split(paths[1], "/")
        basepath = joinpath(split_paths[1:end-1]...)

        nii_files = String[]

        cd(temp_dir) do
            for path in paths
                endpath = split(path, "/")[end]
                filename = "*-$endpath-1-FcFLASH_1-(E$endpath).nii.gz"
                push!(nii_files, filename)

                # Convert current FcFLASH series
                run(`$brkraw_bin tonii /$basepath -s $endpath`)
            end

            # Run angio shell script
            run(`bash $angio_script $(nii_files[1]) $(nii_files[2]) $(nii_files[3])`)
        end

        # Copy final angio NIfTI into BIDS
        final_temp_path = joinpath(temp_dir, "angio_final.nii.gz")
        cp(final_temp_path, final_bids_name; force = true)
        println("✅ Angio copied to BIDS: $final_bids_name")

        # Generate JSON sidecar using first FcFLASH Bruker directory
        run(`$(FC3R_CONFIG[:python_bin]) $parser_script $(paths[1]) $anat_dir --mode T2STAR --json_name "sub-$(id)_ses-$(session)_angio.json"`)

        # Cleanup
        try
            rm(temp_dir; force = true, recursive = true)
            println("🧹 Temporary angio folder removed: $temp_dir")
        catch e
            println("⚠️ Error while removing $temp_dir: $e")
        end

        println("🕒 Angio reconstruction time: $(time() - local_start) seconds")
    end
end

"""
    run_angio_mask()

Run the Python script that masks the angiography images.
"""
function run_angio_mask()
    local_start = time()
    python_script = step_path("03_masks", "Mask_angio.py")
    run(`$(FC3R_CONFIG[:python_bin]) $python_script`)
    println("🕒 Angio mask time: $(time() - local_start) seconds")
end

"""
    run_alignment_and_templates()

Run the external shell scripts that:
- compute transformations (Find_Matrice_SyN.sh, Align_SyN.sh)
- threshold T2* maps (Seuil_T2star.sh)
- build RARE templates for S01/S02 (Template_v2.sh)
- propagate modalities to the template (apply_to_template.sh)
- build final templates for each modality (Make_Template.sh)
"""
function run_alignment_and_templates()
    local_start = time()

    run(`bash $(step_path("04_align","Find_Matrice_SyN.sh"))`)
    run(`bash $(step_path("04_align","Align_SyN.sh"))`)
    run(`bash $(step_path("04_align","Seuil_T2star.sh"))`)

    run(`bash $(step_path("05_templates","Template_v2.sh")) RARE S01 4`)
    run(`bash $(step_path("05_templates","Template_v2.sh")) RARE S02 4`)

    # Propagate modalities onto the template
    for mod in ["T1map","UNIT1","T2map","angio","T2starmap","QSM"]
        run(`bash $(step_path("05_templates","apply_to_template.sh")) $mod`)
        run(`bash $(step_path("05_templates","Make_Template.sh")) $mod`)
    end
    
    println("🕒 Alignment + template generation time: $(time() - local_start) seconds")
end

# =====================================================================
# Main entry point
# =====================================================================

function main()
    global_start = time()

    # 1) Build global metadata
    df = build_global_sessions(FC3R_CONFIG[:input_dirs])

    # 2) Write results.tsv in scr/
    scr_dir = joinpath(FC3R_CONFIG[:project_root], "scr")
    mkpath(scr_dir)
    results_tsv = joinpath(scr_dir, "results.tsv")
    CSV.write(results_tsv, df; delim = '\t')
    println("Results written to $results_tsv")

    # 3) Create BIDS root and participants.tsv (Python script)
    bids = bids_root()
    mkpath(bids)
    participants_tsv = joinpath(bids, "participants.tsv")
    part_script = step_path("01_BIDS", "participants.py")
    run(`$(FC3R_CONFIG[:python_bin]) $part_script $(FC3R_CONFIG[:input_dirs]...) $participants_tsv`)

    # 4) Load / init RARE library
    rare_lib = load_rare_library_tsv(rare_library_tsv_path())

    # 5) Reconstruction per method (MP2RAGE / MESE / RARE)
    reconstruct_all_sequences(df, rare_lib)

    #5.1 OPTIONAL IF SOME REONCSTRUCTION NOT IN THE SAME ORIENTATION
    run(`./Reorient_if_bug.sh`)

    # 6) Brain extraction (Python)
    brain_extraction_script = step_path("03_masks", "brain_extraction.py")
    run(`$(FC3R_CONFIG[:python_bin]) $brain_extraction_script -r $bids`)

    # 7) Orientation fix
    final_modified_folder = joinpath(pwd(), "modified")
    mkpath(final_modified_folder)
    fix_bids_nifti_modified(bids, final_modified_folder, rare_lib)
    isdir(final_modified_folder) && rm(final_modified_folder; recursive = true, force = true)
    println("Temporary folder 'modified' has been removed.")

    # 8) Apply masks to T1map / T2map / UNIT1
    apply_masks_to_quantitative_maps()

    # 9) T2* reconstruction
    reconstruct_T2star(df)

    # 10) Angio reconstruction + masking
    reconstruct_angio(df)
    run_angio_mask()

    # 11) Alignment + templates (RARE + all modalities incl. QSM)
    run_alignment_and_templates()

    println("Total reconstruction time: $(time() - global_start) seconds")
end


main()

