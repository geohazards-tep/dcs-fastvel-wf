#!/bin/bash

#source the ciop functions
source ${ciop_job_include}

#source internal functions
source $_CIOP_APPLICATION_PATH/lib/util.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/lib/util.sh"
    exit 255
}


#properties
export PROPERTIES_FILE=$_CIOP_APPLICATION_PATH/properties/properties.xml


#read global parameters
mode=`ciop-getparam processing_mode`

dir=$(mktemp -d "${TMPDIR}/glob_param_XXXXXX")

if [ ! -e "${dir}" ]; then
    ciop-log "ERROR" "Cannot create directory in ${TMPDIR}"
    echo ""
    exit $ERRPERM
fi

#create a file with parameters that should be available to 
#all nodes
glob_param_file=${dir}/global_parameters.txt

echo "processing_mode=${mode}" >> ${glob_param_file}

ciop-publish -a "${glob_param_file}" || {
    	ciop-log "ERROR" "Failed to publish global parameters file"
	echo ""
	exit ${ERRGENERIC}
}

#count the number of inputs
input_count=0;

while read dataref
do
    let "input_count += 1"
    #input is passed as-is to next node
    echo $dataref | ciop-publish -s
done

#check on the minumum number of images when running in MTA mode
number_of_images_check ${input_count} "${PROPERTIES_FILE}"  ${mode} || {
    exit ${ERRGENERIC}
}

exit $SUCCESS