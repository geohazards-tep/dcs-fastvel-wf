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

export LANGUE=en
export PERL5LIB=/opt/diapason/pldiap/lib
export PATH=$PATH:/opt/diapason/pldiap/bin
export EXE_DIR=/opt/diapason/exe.dir
export DAT_DIR=/opt/diapason/dat.dir
export exedir=${EXE_DIR}
export datdir=${DAT_DIR}

#set trap
trap trapFunction INT TERM


#read parameters
#read polarization to process
export pol=`ciop-getparam pol`
if [ -z "${pol}" ]; then
    export pol="VV"
fi 

#main
function main()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    
    local inref="$1"
    local status=""
    #TO-DO check intersection of product with the AOI

    #create processing directory
    unset serverdir
    export serverdir=$(procdirectory "${TMPDIR}")
    
    [ ! -e "${serverdir}" ] && {
	ciop-log "ERROR" "Cannot create directory in ${TMPDIR}"
	return $ERRPERM
    }

    local aoidef=$(get_global_parameter "aoi" "${_WF_ID}")
    if [ -n "${aoidef}" ]; then
	echo "${aoidef}" > ${serverdir}/DAT/aoi.txt
	download_dem_from_aoi "${aoidef}" "${serverdir}/DAT"
    fi

    aoi2shp "${aoidef}" ${serverdir}/TEMP "AOI"
    local aoishape="${serverdir}/TEMP/AOI.shp"
    if [ ! -e "${aoishape}" ]; then
	ciop-log "ERROR" "Failed to create shapefile from aoi definition ${aoidef}"
	procCleanup
	return ${ERRGENERIC}
    fi

    ciop-log "INFO" "Downloading ${inref}"
    
    local image=$( get_data "${inref}" ${serverdir}/CD/)
    status=$?
    
    if [ "${status}" != "0" ] || [ -z "${image}" ]; then
	ciop-log "ERROR" "Failed to download ${inref}"
	procCleanup
	return ${ERRSTGIN}
    fi
    
    if [ "`find ${serverdir}/CD -type f -print | wc -l`" == "0"  ]; then
	ciop-log "ERROR" "Failed to download ${inref}"
	procCleanup
	return ${ERRSTGIN}
    fi

    ciop-log "INFO" "Downloaded ${image}"
    

    #look for S1 
    for z in `find ${serverdir}/CD/ -iname "*S1*.zip" -print`;do
	ciop-log "INFO" "Unzipping file $z"
       
	extract_safe "${z}" ${serverdir}/CD/
	local extstatus=$?
	if [ $extstatus -ne 0 ]; then
	    ciop-log "ERROR" "Error unzipping file $z"
	    procCleanup
	    return ${ERRGENERIC}
	fi
	#zip file extracted 
	#zip file may be removed
	rm "$z"
	
	local cov_check="/opt/diapason/exe.dir/s1_aoi_coverage"
	
	if [ -e "${cov_check}" ]; then

	#check aoi coverage for s1 iw mode
	    local headers=$(find ${serverdir}/CD -name "*[ie]*.xml" -print | grep -v calibr | grep -i "${pol}")
	    if [ ${#headers[@]} -gt 0 ];then
		local opt=""
		for h in ${headers[@]}; do
		    opt="${opt} -h ${h}"
		done
		
		
		${cov_check} ${opt} -a "${aoishape}" -p 100 
		local cov_status=$?
		if [ ${cov_status} -ne 0 ]; then
		    ciop-log "ERROR" "Insufficient coverage for image in file "$(basename ${z})
		    procCleanup
		    return ${ERRGENERIC}
		fi
	    fi
	    
	fi
    done
    
    

    #ingest product
    for prod in `find "${serverdir}/CD" -type d -iname "*.SAFE" -print -o -iname "*.tar" -print -o -iname "*.tgz" -print -o -iname "*.zip" -print -o -iname "*.N1" -print -o -iname "*.E[12]" -print -o -iname "*.gz" -print`; do
	ciop-log "INFO" "Ingesting product $prod"
	#TO-DO ml parm fom config , pol from param
	ext2dop "${prod}" "${serverdir}" 2 8 "${pol}"
        status=$?
	[ $status -ne 0 ] && {
	    ciop-log "INFO" "Ingestion of product $prod failed"
	    procCleanup
	    return $ERRGENERIC
	}
	rm -f ${serverdir}/DAT/dem* > /dev/null 2<&1
	ciop-log "INFO" "Ingested product $prod"
    done
    
    #look for datatag.txt file
    local prodtag=`head -1 ${serverdir}/DAT/datatag.txt`
    
    [ -z "${prodtag}" ] && {
	ciop-log "ERROR" "Missing extracted product tag for $inref"
	procCleanup
	return $ERRGENERIC
    } 
    
    local acqmode=""
    
    product_tag_get_mode "${prodtag}" acqmode
    
    if [ "${acqmode}" == "IW" ] || [ "${acqmode}" == "EW" ]; then 
	find ${serverdir}/SLC_CI2 -iname "*SLC*.ci2" -print -o -iname "*SLC*.rad" -print | xargs rm
    fi

    #write product ref in DATASET/dataset.txt
    mkdir -p ${serverdir}/DATASET || {
	ciop-log "ERROR" "Error creating directory in ${serverdir}"
	procCleanup 
	return ${ERRPERM}
    }
    
    echo "$inref" > ${serverdir}/DATASET/prodref.txt
    echo "${prodtag}@${inref}" > ${serverdir}/DATASET/dataset.txt

    #write processing aoi if any
    local aoi=$(get_global_parameter  "aoi" "${_WF_ID}")
    
    [ -n "${aoi}" ] && {
	echo "${aoi}" > ${serverdir}/DAT/aoi.txt
    }

    #publishing data
    #rename the directory to publish using the image tag
    local tmpdir_=`mktemp -d ${TMPDIR}/pub_XXXXXX` || {
	ciop-log "ERROR" "Error creating directory in ${TMPDIR}"
	procCleanup
	return ${ERRPERM}
    }
    local pubdir="${tmpdir_}/${prodtag}"
    ln -s "${serverdir}" "${pubdir}"
    
    #check whether the product tag 
    #is already present in hdfs
    local alreadypublished=`ciop-browseresults -r ${_WF_ID} -j node_import | grep ${prodtag}`
    if [ -n "${alreadypublished}" ]; then
	ciop-log "INFO" "Product with tag ${prodtag} was previously published"
	rm -rf ${tmpdir_}
	procCleanup
	return ${ERRGENERIC}
    fi

    ciop-publish -a  -r "${pubdir}"
    local pubstatus=$?
    
    rm -rf ${tmpdir_}
    
    if [ "$pubstatus" != "0" ]; then
	ciop-log "ERROR" "publishing failure : status $pubstatus"
	procCleanup 
	return ${ERRGENERIC}
    fi
    

    procCleanup 
    
    cd "${TMPDIR}"


    echo "${prodtag}"  | ciop-publish -s  || {
	ciop-log "ERROR" "Failed to publish string ${prodtag}"
	return ${ERRGENERIC}
    }


    return $SUCCESS
}

#loop through image list
while read dataref
do
    set -x
    cd "${TMPDIR}"
    main ${dataref} || {
	ciop-log "ERROR" "Failed to import data from ${dataref}"
    }
    ciop-log "INFO" "End of import for ${dataref}"
    set +x
done  
