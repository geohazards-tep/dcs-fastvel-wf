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

source $_CIOP_APPLICATION_PATH/node_selection/functions.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/node_selection/functions.sh"
    exit 255
}


export LANGUE=en
export PERL5LIB=/opt/diapason/pldiap/lib
export PATH=$PATH:/opt/diapason/pldiap/bin
export EXE_DIR=/opt/diapason/exe.dir
export DAT_DIR=/opt/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}

#IDL License
export LM_LICENSE_FILE=1700@idl.terradue.com

#read parameters
export btempmax=`ciop-getparam btemp_max`
export bperpmax=`ciop-getparam bperp_max`
export dopdiffmax=`ciop-getparam dopdiff_max`
export dopimgmax=`ciop-getparam dopimg_max`

#main
function main()
{
    #run id
    local wkid=${_WF_ID}
    
    [ -z "$wkid" ] && {
	ciop-log "ERROR" "Empty _WF_ID"
	echo ""
	return $ERRGENERIC
    }

    
    #create processing directory
    unset serverdir
    export serverdir=$(procdirectory "${TMPDIR}")
    
    [ ! -e "${serverdir}" ] && {
	ciop-log "ERROR" "Cannot create directory in ${TMPDIR}"
	echo ""
	return $ERRPERM
    }
    
    filter_imported_data "${serverdir}" "${wkid}"

    merge_datasetlist "${serverdir}" "${wkid}" || {
	ciop-log "ERROR" "Importing dataset list failed"
 	procCleanup
	echo ""
	return $ERRGENERIC
    }

    local datasetlist="${serverdir}/DAT/dataset.txt"
    
    for imagetag in `cat ${datasetlist} | sed 's/@/ /g' | awk '{print $1}'`;do
	import_data_selection "${serverdir}" "${wkid}" "${imagetag}"
	local importstatus=$?
	
	[ $importstatus -ne 0 ] && {
	    ciop-log "ERROR" "Failed to import ${imagetag}"
	    procCleanup
	    echo ""
	    return ${ERRGENERIC}
	}
	
    done

    #run Super-Master and interferogram selection
    run_selection "${serverdir}" || {
	ciop-log "ERROR" "Error running interf_selection"
	procCleanup
	echo ""
	return ${ERRGENERIC}
    }

        #number of images check
    local nameslc=${serverdir}/TEMP/name_slc_auto.txt
    if [ -e "${nameslc}" ]; then 
	local number_of_images=`cat ${nameslc} | wc -l`
	local mode=$(get_global_parameter  "processing_mode" "${wkid}")
	
    
	number_of_images_check ${number_of_images} "${PROPERTIES_FILE}"  ${mode} || {
	    procCleanup
	
	    echo ""
	    exit ${ERRGENERIC}
	}
	
    fi
    
    #publish results of interf_selection
    local pubdir="${serverdir}/MASTER_SELECTION"
    ln -s "${serverdir}/TEMP" "${pubdir}"

    ciop-publish -a -r "${pubdir}"
    local pubstatus=$?
    
    if [ "$pubstatus" != "0" ]; then
	ciop-log "ERROR" "publishing failure : status $pubstatus"
	procCleanup 
	echo ""
	return ${ERRGENERIC}
    fi

    #look for AOI
    local aoifile="${serverdir}/DAT/aoi.txt"
    local aoidef=`head -1 ${aoifile}`
    
    if [ -e "${aoifile}" ] && [ -n "${aoidef}" ]; then
	local aoidir="${serverdir}/AOI"
	mkdir -p "${aoidir}"
	aoi2shp "${aoidef}" "${aoidir}" "AOI"
	local aoist=$?
	
	if [ $aoist -ne ${SUCCESS} ]; then
	    ciop-log "ERROR" "Creation of AOI shapefile failed"
	    procCleanup 
	    return ${ERRGENERIC}
	fi
	
	#publish AOI folder
	ciop-publish -a -r "${aoidir}" || {
	    ciop-log "ERROR" "Failed to publish AOI folder"
	    procCleanup
	    echo ""
	    return ${ERRGENERIC}
	}
    fi

    #DEM download
    #attempt to download the DEM from the master image reference
    local smfile=${serverdir}/TEMP/SM.txt
    local smtag=`head -1 ${smfile}`
    
    [ -z "${smtag}" ] && {
	ciop-log "ERROR" "Missing Master image tag"
	procCleanup 
	echo ""
	return ${ERRGENERIC}
    }
    
    local smdir=`ciop-browseresults -r "${wkid}" -j node_import | grep ${smtag}`
    [ -z "${smdir}" ] && {
	ciop-log "ERROR" "Unable to find Master image import directory"
	procCleanup 
	echo ""
	return ${ERRGENERIC}
    }


    local tempodir=`mktemp -d ${serverdir}/TEMP/SMDAT_XXXXX`
    if [ -z "${tempodir}" ]; then
	ciop-log "ERROR" "Unable to create temporary folder"
	procCleanup 
	echo ""
	return ${ERRGENERIC}
    fi

    ciop-copy "hdfs://${smdir}/DATASET/dataset.txt" -q -O "${tempodir}" || {
	ciop-log "ERROR" "Unable to copy SM dataset.txt file"
	procCleanup 
	echo ""
	return ${ERRGENERIC}
    }

    #`cat ${datasetlist} | sed 's/@/ /g' | awk '{print $1}'`
    local smref=`cat ${tempodir}/dataset.txt | sed 's/@/ /g' | awk '{print $2}'`
    
    [ -z "${smref}" ] && {
	ciop-log "ERROR" "Empty Master image ref"
	procCleanup
	echo ""
	return ${ERRGENERIC}
    } 

    ciop-log "INFO" "Attempting to download DEM from master image reference ${smref}"
    local demdir=${serverdir}/DEM
    mkdir -p "${demdir}"
    
    download_dem_from_ref "${smref}" "${demdir}"
    local demst=$?
    
    if [ "${demst}" != "0" ]; then	
	ciop-log "INFO" "DEM download from ref failed"
	ciop-log "INFO" "Attempting to download DEM from product annotations"
	download_dem_from_anotation "${serverdir}" "${demdir}"
	demst=$?
    fi
    
    #TO-DO call get_DEM

    if [ "${demst}" != "0" ]; then
	ciop-log "ERROR" "Unable to retrieve DEM"
	procCleanup
	echo ""
	return ${ERRGENERIC}
    fi
    
    #publish DEM
    ciop-publish -a -r "${demdir}" || {
	ciop-log "ERROR" "Failed to publish DEM"
	procCleanup
	echo ""
	return ${ERRGENERIC}
    }

    #perform precise_sm
    compute_precise_sm "${serverdir}" "${smtag}" "${wkid}" || {
	ciop-log "ERROR" "Failed to compute Precise T0/NR for Master Image"
	procCleanup
	echo ""
	return ${ERRGENERIC}
    }

    #data passed to the next node
    local stageout="${serverdir}/DAT/stageout.txt"
    echo "" > "${stageout}"
    for imagetag in `cat ${datasetlist} | sed 's/@/ /g' | awk '{print $1}'`;do
	#if [ "${imagetag}" == "${smtag}" ]; then
	#    continue
	#fi
	if [ "${imagetag}" != "${smtag}" ]; then
	    #continue
	    echo "${smtag}@${imagetag}" >> ${stageout}
	fi
	
        echo "${smtag}@${imagetag}" | ciop-publish -s
    done
    
    ciop-publish -a "${stageout}" || {
	ciop-log "ERROR" "Failed to publish stageout data"
	procCleanup
	echo ""
	return ${ERRGENERIC}
    }
    

    procCleanup
    echo ${smtag}
    return ${SUCCESS}
}

#set trap
trap trapFunction INT TERM

#lock file
lock="${TMPDIR}/${_WF_ID}.lock"

set -o noclobber

echo "" > "${lock}" && {
    ciop-log "INFO" "Running node_selection"
    export sm=$(main) || {
	
	exit ${ERRGENERIC}
    }
    
    [ -z "$sm" ] && {
	exit ${ERRGENERIC}
    }
    
}
    
    

exit ${SUCCESS}

