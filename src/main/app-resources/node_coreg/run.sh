#!/bin/bash

#source the ciop functions
source ${ciop_job_include}

#source internal functions
source $_CIOP_APPLICATION_PATH/lib/util.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/lib/util.sh"
    exit 255
}

source $_CIOP_APPLICATION_PATH/node_coreg/functions.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/node_coreg/functions.sh"
    exit 255
}


export LANGUE=en
export PERL5LIB=/opt/diapason/pldiap/lib
export PATH=$PATH:/opt/diapason/pldiap/bin
export EXE_DIR=/opt/diapason/exe.dir
export DAT_DIR=/opt/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}



#create directory for processing
unset serverdir
export serverdir=`mktemp -d ${TMPDIR}/node_coreg_XXXXXX`  || {
    ciop-log "ERROR" "Unable to create folder in temporary location ${TMPDIR}"
    exit ${ERRPERM}
}

mkdir -p ${serverdir}/CD 
mkdir -p ${serverdir}/DAT
#
import_data_from_previous_nodes "${serverdir}" ${_WF_ID} || {
    ciop-log "ERROR" "Failed to import data from previous nodes"
    procCleanup
    exit ${ERRGENERIC}
}

#import master image
ciop-log "INFO" "Importing Master image ${inputs[0]}"

import_master "${serverdir}" ${_WF_ID} || {
    ciop-log "ERROR" "import_master failed"
    procCleanup
    exit ${ERRGENERIC}
}

#read inputs from stdin
#each line has: master_image_tag@slave_image_tag
while read data
do


[ -n "`echo ${data} | grep "^hdfs"`"  ] && {
    #ciop-log "INFO" ciop-log "INFO" "Discarding input ${data}"
    continue
}
 
inputs=($(echo "$data" | tr "@" "\n") )

ninputs=${#inputs[@]}

[ $ninputs -lt 2 ] && {
    #ciop-log "INFO" "Discarding input ${data}"
    continue
}

if [ "${inputs[0]}" == "${inputs[1]}"  ]; then
    continue
fi

ciop-log "INFO" "data : ${data}"


cordir=$(procdirectory "${serverdir}")

if [ -z "${cordir}" ]; then
    ciop-log "ERROR" "Cannot process image ${inputs[1]}"
    continue
fi


ciop-log "INFO" "Importing Slave image ${inputs[1]}"

slavedir=$(import_safe "${cordir}" "${_WF_ID}" ${inputs[1]})

ciop-log "INFO" "Registering image ${inputs[1]} vs master ${inputs[0]}"

run_coreg_process_tops "${serverdir}" "${cordir}" "${inputs[0]}" "${inputs[1]}" || {
    ciop-log "ERROR" "Coregistration of image ${inputs[1]} failed"
}

#cleanup local processing folder
rm -rf "${cordir}"

done



#remove processing directory
procCleanup

exit ${SUCCESS}
