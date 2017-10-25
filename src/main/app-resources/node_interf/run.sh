#!/bin/bash

#source the ciop functions
source ${ciop_job_include}

#source internal functions
source $_CIOP_APPLICATION_PATH/lib/util.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/lib/util.sh"
    exit 255
}

source $_CIOP_APPLICATION_PATH/node_interf/functions.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/node_interf/functions.sh"
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
export serverdir=$(procdirectory "${TMPDIR}")

if [ ! -e "$serverdir" ]; then
    ciop-log "ERROR" "Unable to create folder in temporary location ${TMPDIR}"
    exit ${ERRPERM}
fi



import_dem_from_node_selection ${serverdir} "${_WF_ID}" || {
	ciop-log "ERROR" "Failed to import DEM"
	procCleanup
	exit ${ERRGENERIC}
    }
    

import_geosar ${serverdir} "${_WF_ID}" || {
	ciop-log "ERROR" "geosar Import Failed"
	procCleanup
	exit ${ERRGENERIC}
}

mastertag=""
for f in `ciop-browseresults -j node_selection -r "${_WF_ID}" | grep MASTER_SELECTION`;do
    mastertag=`hadoop dfs -cat ${f}/SM.txt`
done

[ -z "${mastertag}" ] && {
    ciop-log "ERROR" "Failed to get master image tag"
    procCleanup
    exit ${ERRGENERIC}
}

import_interf_list "${serverdir}" "${_WF_ID}" || {
    echo "ERROR" "Failed to import interf selection results"
    procCleanup
    exit ${ERRGENERIC}
}


    #get aoi string definition
import_aoi_def_from_node_import "${serverdir}" "${mastertag}" "${_WF_ID}" 

export mode=$(get_global_parameter "processing_mode" "${_WF_ID}") || {
	ciop-log "WARNING" "Global parameter \"processing_mode\" not found. Defaulting to \"MTA\""
    }

#read inputs from stdin
#each line has: masterorbit@slave_orbit
while read data
do


[ -n "`echo ${data} | grep "^hdfs"`"  ] && {
    ciop-log "INFO" ciop-log "INFO" "Discarding input ${data}"
    continue
}
 
imgpair=($(echo "$data" | tr "@" "\n") )


import_geo_image "${serverdir}" "${_WF_ID}" ${imgpair[0]} || {
    ciop-log "ERROR" "Failed to import "${imgpair[0]}
    continue
}

import_geo_image "${serverdir}" "${_WF_ID}" ${imgpair[1]} || {
    ciop-log "ERROR" "Failed to import "${imgpair[1]}
    continue
}

ciop-log "INFO" "processing pair"${imgpair[@]}

if [[ "$mode" == "MTA" ]]; then
    generate_interferogram "${serverdir}" "${mastertag}" ${imgpair[0]} ${imgpair[1]}
else
    generate_ortho_interferogram "${serverdir}" "${mastertag}" ${imgpair[0]} ${imgpair[1]}
fi

done

for d in `find ${serverdir}/TEMP -type d -iname "interf_*" -print`; do
    ciop-log "INFO" "interferogram folder $d ->"$$
done

#remove processing directory
procCleanup

exit ${SUCCESS}
