#!/bin/bash
# source /home/CODE/fsl/bin/activate

INPUT_ANGIO1="$1"
INPUT_ANGIO2="$2"
INPUT_ANGIO3="$3"

mrconvert --strides 1,2,3 INPUT_ANGIO1 INPUT_ANGIO1 -force
mrconvert --strides 1,2,3 INPUT_ANGIO2 INPUT_ANGIO2 -force
mrconvert --strides 1,2,3 INPUT_ANGIO3 INPUT_ANGIO3 -force

#R�cup�rer l'origine x de chacune des images
origine_image_1=$(mrinfo ${INPUT_ANGIO1} -transform | awk 'NR==2 {print $NF}')
origine_image_2=$(mrinfo ${INPUT_ANGIO2} -transform | awk 'NR==2 {print $NF}')
origine_image_3=$(mrinfo ${INPUT_ANGIO3} -transform | awk 'NR==2 {print $NF}')

#Lister les origines z et les attribuer aux fichiers d'entr�e
list=$(printf "%s\t%s\n" "$origine_image_1" "$INPUT_ANGIO1" \
                         "$origine_image_2" "$INPUT_ANGIO2" \
                         "$origine_image_3" "$INPUT_ANGIO3")

sorted_list=$(echo "$list" | sort -g)

#R�organiser les fichiers en fonction de leur acquisition
FIRST_IMAGE=$(echo "$sorted_list" | awk 'NR==1 {print $2}')
SECOND_IMAGE=$(echo "$sorted_list" | awk 'NR==2 {print $2}')
THIRD_IMAGE=$(echo "$sorted_list" | awk 'NR==3 {print $2}')

origine_first_image=$(mrinfo $FIRST_IMAGE -transform | awk 'NR==2 {print $NF}')
dimension_first_image=$(mrinfo $FIRST_IMAGE -spacing | awk '{print $2}')
voxel_first_image=$(mrinfo $FIRST_IMAGE -size | awk '{print $2}')

origine_scd_image=$(mrinfo $SECOND_IMAGE -transform | awk 'NR==2 {print $NF}')
dimension_scd_image=$(mrinfo $SECOND_IMAGE -spacing | awk '{print $2}')
voxel_scd_image=$(mrinfo $SECOND_IMAGE -size | awk '{print $2}')

origine_thrd_image=$(mrinfo $THIRD_IMAGE -transform | awk 'NR==2 {print $NF}')
dimension_thrd_image=$(mrinfo $THIRD_IMAGE -spacing | awk '{print $2}')
voxel_thrd_image=$(mrinfo $THIRD_IMAGE -size | awk '{print $2}')

longueur_first_image=$(echo "$dimension_first_image * $voxel_first_image" | bc)
final_first_image=$(echo "$origine_first_image + $longueur_first_image" | bc)

longueur_scd_image=$(echo "$dimension_scd_image * $voxel_scd_image" | bc)
final_scd_image=$(echo "$origine_scd_image + $longueur_scd_image" | bc)

longueur_thrd_image=$(echo "$dimension_thrd_image * $voxel_thrd_image" | bc)
final_thrd_image=$(echo "$origine_thrd_image + $longueur_thrd_image" | bc)

superposition_1_2=$(echo "$final_first_image - $origine_scd_image" | bc)
largeur_superposition_1_2=$(echo "$superposition_1_2 / $dimension_first_image" | bc)
largeur_first_scd=$(echo "$origine_first_image + $longueur_first_image" | bc)

superposition_2_3=$(echo "$final_scd_image - $origine_thrd_image" | bc)
largeur_superposition_2_3=$(echo "$superposition_2_3 / $dimension_scd_image" | bc)
largeur_scd_thrd=$(echo "$origine_scd_image + $longueur_thrd_image" | bc)

mrgrid $THIRD_IMAGE crop -axis 1 $largeur_superposition_1_2,0 angio1.nii.gz -force
mrgrid $SECOND_IMAGE crop -axis 1 $largeur_superposition_1_2,0 angio2.nii.gz -force
mrcat $FIRST_IMAGE angio2.nii.gz angio1.nii.gz -axis 1 temp.mif
mrconvert temp.mif angio_final.nii.gz
# fslmerge -y angio_final.nii.gz $FIRST_IMAGE angio2.nii.gz angio1.nii.gz

