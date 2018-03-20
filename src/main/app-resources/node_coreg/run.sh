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

source $_CIOP_APPLICATION_PATH/node_selection/functions.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/node_coreg/functions.sh"
    exit 255
}

#properties
export PROPERTIES_FILE=$_CIOP_APPLICATION_PATH/properties/properties.xml


export LANGUE=en
export PERL5LIB=/opt/diapason/pldiap/lib
export PATH=$PATH:/opt/diapason/pldiap/bin
export EXE_DIR=/opt/diapason/exe.dir
export DAT_DIR=/opt/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}

#set trap
trap trapFunction INT TERM

#create directory for processing
unset serverdir
export serverdir=`mktemp -d ${TMPDIR}/node_coreg_XXXXXX`  || {
    ciop-log "ERROR" "Unable to create folder in temporary location ${TMPDIR}"
    exit ${ERRPERM}
}

mkdir -p ${serverdir}/CD 
mkdir -p ${serverdir}/DAT
mkdir -p ${serverdir}/TEMP
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
    ciop-log "INFO" "publish SM IMAGE"
    export_image_coreg_results "${serverdir}/PROCESSING" "${inputs[0]}"
    #send something on stdin to next node
    echo "${inputs[0]}" | ciop-publish -s
    continue
fi

ciop-log "INFO" "data : ${data}"


cordir=$(procdirectory "${serverdir}")

if [ -z "${cordir}" ]; then
    ciop-log "ERROR" "Cannot process image ${inputs[1]}"
    continue
fi


ciop-log "INFO" "Registering image ${inputs[1]} vs master ${inputs[0]}"

run_coreg_process "${serverdir}" "${cordir}" "${inputs[0]}" "${inputs[1]}" "${_WF_ID}"

#cleanup local processing folder
rm -rf "${cordir}"

#cleanup data from import node
cleanup_import_data ${inputs[1]} "${_WF_ID}"

done

#clean master image from import node
cleanup_import_data ${inputs[0]} "${_WF_ID}"

#send something on stdin to next node
#create_lock "${_WF_ID}" "node_coreg" && {
#    echo "${inputs[0]}" | ciop-publish -s
#}
#remove processing directory
procCleanup

exit ${SUCCESS}
