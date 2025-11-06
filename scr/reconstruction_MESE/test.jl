path_bruker = "/home/mpetit/Dev/CODE_Mat/Data/2024_RECH_FC3R/20241002_100040_SM_FC3R_dev_03_SM_FC3R_dev_03_1_1/11"
@info "path_bruker = $(ARGS[1])"
@info "path_out = $(ARGS[2])"

using Subspace_MESE
using Subspace_MESE.MRIFiles
using Subspace_MESE.MRIReco
using Subspace_MESE.MRICoilSensitivities
using Subspace_MESE.LinearAlgebra
using Subspace_MESE.FFTW
using NIfTI

# ## Define paths
#to the raw dataset :

# path_raw = "/home/mpetit/Dev/CODE_Mat/Data/2024_RECH_FC3R/20241002_100040_SM_FC3R_dev_03_SM_FC3R_dev_03_1_1/11"
@info Threads.nthreads()

slice_to_show = 55
# ## Load and convert the bruker dataset into an AcquisitionData object
b = BrukerFile(path_bruker)

raw = RawAcquisitionData_MESE(b)
acq = AcquisitionData(raw,OffsetBruker = true);

# ## Estimate the coil sensitivity map with espirit
ncalib = parse.(Int,b["CenterMaskSize"])
ncalib > 24 ? ncalib = 24 : nothing

coilsens = espirit(acq,eigThresh_2 = 0,(6,6,6),ncalib);

# ## Direct reconstruction of undersampled acquisition

params = Dict{Symbol,Any}()
params[:reconSize] = acq.encodingSize
params[:reco] = "direct"

im_u = reconstruction(acq, params);
im_u_sos = mergeChannels(im_u)

heatmap(im_u_sos[:,:,55,15,1,1],colormap=:grays)

ni = NIVolume(im_u_sos[:,:,:,:,1])
# niwrite(joinpath(path_out, "_MESE_out.nii.gz"), ni)

# Extraire le nom "sub-03_ses-1" depuis path_out
subject_session_name = basename(path_out)

# Reconstruire le chemin pour écrire dans "anat/" avec le bon nom de fichier
output_file = joinpath(dirname(path_out), "$(subject_session_name)_MESE_out.nii.gz")

# Écriture du fichier
# niwrite(output_file, ni)


# ##  Subspace generation with the EPG simulation
B1_vec = 0.8:0.01:1.0
T2_vec = 1.0:1.0:2000.0
T1_vec = 1000.0
TE = parse(Float64,b["PVM_EchoTime"])
TR = parse(Float64,b["PVM_RepetitionTime"])
dummy=3
ETL = parse(Int,b["PVM_NEchoImages"])
NUM_BASIS = 6
basis_epg,_= MESE_basis_EPG(NUM_BASIS,TE,ETL,T2_vec,B1_vec,T1_vec;TR=TR,dummy=dummy)


# ## Subspace reconstruction with EPG dictionary
params = Dict{Symbol,Any}()
params[:reconSize] = acq.encodingSize
params[:reco] = "multiCoilMultiEchoSubspace"

params[:regularization] = "L1"
params[:sparseTrafo] = "Wavelet" #sparse trafo
params[:λ] = Float32(0.03)
params[:solver] = "fista"
params[:iterations] = 60
#params[:iterationsInner] = 5
params[:senseMaps] = coilsens
params[:normalizeReg] = true
params[:basis] = basis_epg

α_epg = reconstruction(acq, params)
im_TE_julia = abs.(applySubspace(α_epg, params[:basis]));



# ## Fitting of the data to obtain T₂ maps

TE_vec = Float32.(LinRange(TE,TE*ETL,ETL))
T2_map = Subspace_MESE.T2Fit_exp_noise(abs.(im_TE_julia[:,:,:,:,1,1]),TE_vec;removePoint=true,L=4)

# heatmap(T2_map[:,:,120,2],colorrange=(0,100))
ni = NIVolume(im_TE_julia[:,:,:,:,1,1],voxel_size=(acq.fov./acq.encodingSize))
niT2 = NIVolume(T2_map[:,:,:,2],voxel_size=(acq.fov./acq.encodingSize))
# niwrite(joinpath(path_out, "_T2_map.nii.gz"), ni)
# niwrite(joinpath(path_out,"reco_W=$(params[:λ]).nii"),ni)
# Extraire le nom "sub-03_ses-1" depuis path_out
subject_session_name = basename(path_out)

# Reconstruire le chemin pour écrire dans "anat/" avec le bon nom de fichier
output_file = joinpath(dirname(path_out), "$(subject_session_name)_MESE.nii.gz")
output_T2map = joinpath(dirname(path_out), "$(subject_session_name)_T2map.nii.gz")

# Écriture du fichier
niwrite(output_file, ni)
niwrite(output_T2map,niT2)
# write nifti + BIDS

pulse90 = parse(Float64,split(b["ExcPulse1"],", ")[3])
pulse180 = parse(Float64,split(b["RefPulse1"],", ")[3])