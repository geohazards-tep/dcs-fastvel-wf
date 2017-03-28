#!/bin/bash


function import_safe()
{
    if [ $# -lt 3 ]; then
       return ${ERRMISSING}
    fi
    
    local procdir="${1}"
    local runid="${2}"
    local imagetag="$3"

    local remotedir=`ciop-browseresults -r "${runid}" -j node_import | grep ${imagetag}`
    [ -z "${remotedir}" ] && {
	ciop-log "ERROR" "image directory ${imagetag} not found in remote"
	return 1
    }
    
    local remotesafe=`hadoop dfs -lsr "${remotedir}" | awk '{print $8}' | grep "\.SAFE$"`
    [ -z "${remotesafe}" ] && {
	ciop-log "ERROR" "safe directory not found for image ${imagetag}"
	return 1
    }
    echo ${remotesafe}
    #import to directory
    hadoop dfs -copyToLocal "${remotesafe}" "${procdir}/CD" || {
	ciop-log "ERROR" "Failed to import ${remotesafe}"
	return 1
    }

    echo "${procdir}/CD/`basename ${remotesafe}`"
    
    return ${SUCCESS}
}


function import_data_from_previous_nodes()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local runid="$2"
    
    #import DEM
    remotedemdir=`ciop-browseresults -r ${runid}  -j node_selection | grep DEM`
    [ -z "${remotedemdir}" ] && {
	ciop-log "ERROR" "node DEM folder found in node_selection results"
	#procCleanup
	return ${ERRGENERIC}
    } 
    
    hadoop dfs -copyToLocal "${remotedemdir}" "${procdir}" || {
	ciop-log "ERROR" "Failed to import folder ${remotedemdir}"
	#procCleanup
	return ${ERRGENERIC}
    }
    
    demtif=`ls ${procdir}/DEM/*.tif | head -1`
    [ -z "${demtif}" ] && {
	ciop-log "ERROR" "No dem geotiff found"
	#procCleanup
	return ${ERRGENERIC}
    }
    
    #create DEM descriptor
    tifdemimport.pl --intif="${demtif}" --outdir="${procdir}/DEM" > "${procdir}/DEM/demimport.log" 2<&1
    importst=$?
    
    if [ $importst -ne 0 ] || [ ! -e "${procdir}/DEM/dem.dat" ]; then
	ciop-log "ERROR" "DEM conversion failed"
	#procCleanup
	return ${ERRGENERIC}
    fi
    
    #import AOI
    export AOISHP=""
    remoteaoidir=`ciop-browseresults -r ${runid}  -j node_selection | grep AOI`
    [ -n "${remoteaoidir}" ] && {
	hadoop dfs -copyToLocal "${remoteaoidir}" "${procdir}" || {
	    ciop-log "ERROR" "Failed to import folder ${remoteaoidir}"
	    #procCleanup
	    return ${ERRGENERIC}
	}
	AOISHP="`ls ${procdir}/AOI/*.shp |head -1`"
	[ -n "${AOISHP}" ] && {
	    ciop-log "INFO" "Using AOI file ${AOISHP}"
	}
    }
    
    local stageoutfile=`ciop-browseresults -r ${runid}  -j node_selection | grep stageout.txt | head -1`
    [ -n "stageoutfile" ] && {
	hadoop dfs -cat ${stageoutfile} > ${procdir}/DAT/stageout.txt 
	chmod 775 ${procdir}/DAT/stageout.txt
    }

   return $SUCCESS 
}

function import_master()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local runid="$2"
    
    #get the master image tag
    local seldir=`ciop-browseresults -r "${runid}" -j node_selection | grep MASTER_SELECTION`
    [ -z "${seldir}" ] && {
	ciop-log "ERROR" "Unable to find MASTER_SELECTION folder"
	return ${ERRMISSING}
    }

    local mastertag=`hadoop dfs -cat ${seldir}/SM.txt`
    
    [ -z "${mastertag}" ] && {
	ciop-log "ERROR" "Unable to read master image tag"
	return ${ERRMISSING}
    } 
    
    #TO-DO check for TOPS or SM
    
    local masterdir=$(import_safe "${procdir}" "${runid}" "${mastertag}")
    
    local status=$?
    
    if [ $status -ne ${SUCCESS} ]; then
	ciop-log "ERROR" "Failed to import master image (tag ${mastertag})"
	return $status
    fi

    return ${SUCCESS}
}

function run_coreg_process_tops()
{
    if [ $# -lt 4 ]; then
	return ${ERRMISSING}
    fi
    local dirmaster=$1
    local dirslave=$2
    local mastertag="$3"
    local slimagetag="$4"

    local pol=""
    
    product_tag_get_pol "${mastertag}" pol || {
	return ${ERRINVALID}
    }

    local orbsm
    product_tag_get_orbnum ${mastertag} orbsm || {
	ciop-log "ERROR" "Unable to infer master image orbit number"
 	return ${ERRINVALID}
    }
    
    
    local safemaster=`find ${dirmaster}/CD/ -type d -name "*.SAFE" -print | head -1`
    [ -z "${safemaster}" ] && {
	ciop-log "ERROR" "Missing SAFE directory for master image"
	return ${ERRMISSING}
    }
    
    local safeslave=`find ${dirslave}/CD/ -type d -name "*.SAFE" -print | head -1`
    
    [ -z "${safeslave}" ] && {
	ciop-log "ERROR" "Missing SAFE directory for slave image"
	return ${ERRMISSING}
    }

    local procdir=`mktemp -d ${dirmaster}/coreg_XXXXXX` || {
	ciop-log "ERROR" "Cannot create folder in ${procdir}"
	return ${ERRPERM}
    }
 
    local dem="${dirmaster}/DEM/dem.dat"
   
    [ ! -e "${dem}" ] && {
	ciop-log "ERROR" "Missing DEM descriptor ${dem}"
	return ${ERRMISSING}
}

    local aoi="`ls ${dirmaster}/AOI/*.shp |head -1`"
    
    [ -z "${aoi}" ] && {
	ciop-log "ERROR" "Missing AOI shapefile "
	return ${ERRMISSING}
}

    #list of image tages
    declare -a imagetags
    local stageoutfile="${dirmaster}/DAT/stageout.txt"
    [ -e "$stageoutfile" ] && {
	imagetags=(`cat $stageoutfile | sed 's/@/ /g' | awk '{print $2}'`)
    }
    ciop-log "INFO" "Image tags count ${#imagetags[@]}"
    ciop-log "INFO" "Image tags ${imagetags[@]}"
    #flag whether to publish the master geo_ci2 image
    #only publish the master image when processing
    #the first slave image (i.e different from master)
    local pubmaster=0
    
    if [ ${#imagetags[@]} -eq 1 ] && [ "${imagetags[0]}" == "${slimagetag}"  ]; then
	pubmaster=1
    fi
    
    if [ ${#imagetags[@]} -gt 1 ] && [ "${imagetags[0]}" == "${mastertag}"  ] && [ "${imagetags[1]}" == "${slimagetag}"  ]   ;then
	pubmaster=1
    fi

    
    #define environment
    export ROOT_DIR="${procdir}"
    #SCRIPTS DIRECTORY
    export SCRIPT_DIR="/opt/diapason/gep.dir/"
    #MASTER IMAGE
    export PRODUCT1="${safemaster}"
    #DEM
    export DEM="${dem}"
    
    #aoi
    export AOI_SHP="${aoi}"

    #MULTILOOK PARAMETERS
    export MLAZ=2
    export MLRAN=8
    
    #SLIDNIG WINDOW FOR ESD
    export ESD_WINAZI=4
    export ESD_WINRAN=16
    
    #POLARIZATION TO PROCESS
    #LEAVE BLANK IF UNKNOWN
    export POL=${pol}
    
    local prodlist="${dirslave}/prodlist.txt"

    echo "${safeslave}" > "${prodlist}"
    
    export PRODUCT_LIST="${prodlist}"
    
    #number of iterations for the ESD process
    export NESDITER=2
    
    export CLEAN_TEMPORARY="YES"
    export MATIC_DIR="${dirslave}"
    
    if [ $pubmaster -gt 0 ]; then
	export EXPORT_SM="YES"
    else
	export EXPORT_SM="NO"
    fi
    #run processing
    ${SCRIPT_DIR}/s1_process.sh > ${dirslave}/log/processing.log 2<&1
    
    local status=$?
    
    ###################################
    cp ${dirslave}/log/processing_${slimagetag}.log /tmp
    chmod 777 ${dirslave}/log/processing_${slimagetag}.log
    cp ${prodlist} /tmp
    chmod 777 /tmp/`basename ${prodlist}`
    ls ${safeslave} > /tmp/safelsave_${slimagetag}.txt
    chmod 777 /tmp/safelsave_${slimagetag}.txt
    #cp -r ${procdir} /tmp
    #chmod -R 777 /tmp/coreg*
###################################
    

    if [ $status -ne 0 ]; then
	return ${ERRGENERIC}
    fi

    #cleanup CD directory
    rm -rf ${dirslave}/CD/* > /dev/null 2<&1

    if [ $pubmaster -gt 0 ]; then
    #move master image
    #create a folder structure for master
	local smdir=$(procdirectory "${dirmaster}") || {
	    ciop-log "ERROR" "Unable to create temporary directory"
	    return ${ERRPERM}
	}
	
	local tmpo=`mktemp -d ${dirmaster}/pubmaster_XXXXXX` || {
	    ciop-log "ERROR" "Unable to create temporary directory"
	    return ${ERRPERM}
	}
	
	mv ${dirslave}/DAT/GEOSAR/${orbsm}.geosar* ${smdir}/DAT/GEOSAR/
	mv ${dirslave}/GEO_CI2_EXT_LIN/geo_${orbsm}_${orbsm}* ${smdir}/GEO_CI2_EXT_LIN
	mv ${dirslave}/ORB/${orbsm}.orb ${smdir}/ORB/
	mv ${dirslave}/SLC_CI2/${orbsm}_* ${smdir}/SLC_CI2/
	
	ln -s ${smdir} ${tmpo}/${mastertag}
	
	ciop-publish -a -r "${tmpo}/${mastertag}" 
	local pubmasterstatus=$?
	
	if [ $pubmasterstatus -eq 0 ]; then
	    ciop-log "INFO" "Published master folder ${mastertag}"
	else
	    ciop-log "INFO" "Master folder ${mastertag} already published"
	fi
	
	rm -rf "${tmpo}" 
	rm -rf "${smdir}"	
    fi

    #publish slave registered image
    ln -s ${dirslave} ${dirmaster}/${slimagetag}
    
    ciop-publish -a -r "${dirmaster}/${slimagetag}" || {
	ciop-log "ERROR" "Failed to publish slave coregistration results"
	return ${ERRGENERIC}
    }
    
    
    return ${SUCCESS}
}

function cleanup_import_data()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi 

    local imtag="$1"
    local wkid="$2"
    
    local remotedir=`ciop-browseresults -r "${wkid}" -j node_import | grep ${imtag}`
    [ -z "${remotedir}" ] && {
	ciop-log "ERROR" "image directory ${imagetag} not found in remote"
	return ${ERRMISSING}
    }

    for data in `hadoop dfs -lsr "${remotedir}" | awk '{print $8}' | grep "\.SAFE$\|\.ci2$"`;do
	hadoop dfs -rmr "${data}" > /dev/null 2<&1
    done


    return ${SUCCESS}
}