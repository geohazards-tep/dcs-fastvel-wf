#!/bin/bash

# Public: import to local storage a .SAFE folder
# published by node_import
#
# Takes a local folder path , the application workflow
# id and an image tag 
# 
# The function will echo the path of the imported .SAFE
#
# $1 - local folder
# $2 - workflow id
# $3 - image tag
#
#
# Returns $SUCCESS or an error code 
#   

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
	return ${ERRMISSING}
    }
    
    local remotesafe=`hadoop dfs -lsr "${remotedir}" | awk '{print $8}' | grep "\.SAFE$"`
    [ -z "${remotesafe}" ] && {
	ciop-log "ERROR" "safe directory not found for image ${imagetag}"
	return ${ERRMISSING}
    }
  
    #import to directory
    hadoop dfs -copyToLocal "${remotesafe}" "${procdir}/CD" || {
	ciop-log "ERROR" "Failed to import ${remotesafe}"
	return ${ERRGENERIC}
    }

    echo "${procdir}/CD/`basename ${remotesafe}`"
    
    return ${SUCCESS}
}

# Public: import to local storage an extracted image
# published by node_import
#
# Takes a local folder path , the application workflow
# id and an image tag 
# 
# The function will copy to the local folder the image
# geosar ,orbit, slc , multilook and doppler files
#
# $1 - local folder
# $2 - workflow id
# $3 - image tag
#
#
# Returns $SUCCESS or an error code
#   

function import_extracted_image()
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
	return ${ERRGENERIC}
    }

    local orbitnum=""
    
    product_tag_get_orbnum "${imagetag}" orbitnum || {
	return ${ERRINVALID}
    }
    
    [ -z "${orbitnum}" ] && {
	ciop-log "ERROR" "cannot infer orbit number from image tag ${imagetag}"
	return ${ERRINVALID}
    }
    
    #import geosar file
    for f in `hadoop dfs -lsr "${remotedir}" | awk '{print $8}' | grep GEOSAR | grep "\.geosar"`; do
	hadoop dfs -copyToLocal "${f}" "${procdir}/DAT/GEOSAR/" || {
	    ciop-log "ERROR" "Failed to import file  ${f} for ${imagetag}"
	    return ${ERRGENERIC}
	}
    done

    #import orbit file
    for f in `hadoop dfs -lsr "${remotedir}" | awk '{print $8}' | grep ORB | grep "\.orb"`; do
	hadoop dfs -copyToLocal "${f}" "${procdir}/ORB/" || {
	    ciop-log "ERROR" "Failed to import file ${f} for ${imagetag}"
	    return ${ERRGENERIC}
	}
    done
    
    #import slc ,ml and doppler file
    for f in `hadoop dfs -lsr "${remotedir}/" | awk '{print $8}' |  grep SLC_CI2 |  grep "\.ci2\|\.rad\|doppler\|.byt"`; do
	hadoop dfs -copyToLocal "${f}" "${procdir}/SLC_CI2/" || {
	    ciop-log "ERROR" "Failed to import file ${f} for ${imagetag}"
	    return ${ERRGENERIC}
	}
    done

    geosarfixpath.pl --geosar="${procdir}/DAT/GEOSAR/${orbitnum}.geosar" --serverdir="${procdir}"

    return ${SUCCESS}
}


# Public: import to local storage data from previous nodes
# required to run the coregistration process
# 
# Takes a local folder path , the application workflow
# id
# 
# The function will copy to the local folder the DEM ,AOI
# 
#
# $1 - local folder
# $2 - workflow id
#
# Returns $SUCCESS or an error code
#   
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
	ciop-log "ERROR" "no DEM folder found in node_selection results"
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

# Public: import master image to local folder
# 
# Takes a local folder path , the application workflow
# id
# 
# The function will copy to the local folder the master image
# 
# $1 - local folder
# $2 - workflow id
#
# Returns $SUCCESS or an error code 
# 
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
    local immodetag=""
    
    product_tag_get_mode "${mastertag}" immodetag || {
	return ${ERRINVALID}
    }
    
    [ -z "${immodetag}" ] && {
	ciop-log "unable to infer acquisition mode from image tag ${immodetag}"
	return ${ERRINVALID}
    }
    
    local status
    if [ "${immodetag}" == "IW" ] ||  [ "${immodetag}" == "EW" ]; then
	local masterdir=$(import_safe "${procdir}" "${runid}" "${mastertag}")
	status=$?
    else
	ciop-log "INFO" "Importing master image ${mastertag}"
	local coregdir=$(procdirectory "${procdir}")
	#rename processing directory
	mv "${coregdir}" "${procdir}/PROCESSING" 
	coregdir="${procdir}/PROCESSING"
	import_extracted_image "${coregdir}" "${runid}" "${mastertag}"
	#copy dem descriptor
	cp ${procdir}/DEM/dem.dat ${coregdir}/DAT/ > /dev/null 2<&1
	status=$?
	run_coreg_stripmap "${procdir}/PROCESSING" "${mastertag}" "${mastertag}"
    fi  
    
    
    if [ $status -ne ${SUCCESS} ]; then
	ciop-log "ERROR" "Failed to import master image (tag ${mastertag})"
	return $status
    fi

    return ${SUCCESS}
}


# Public: run coregistration process for s1 iw data
# 
# Takes 2 folders containing respectively the master and
# slave .SAFE folder , as well as the master and slave image
# tags
# 
# The function upon success will copy the registered slave image
# to an hdfs folder named with the slave image tag 
# 
# $1 - master image folder
# $2 - slave image folder
# $3 - master image tag
# $4 - slave image tag
#
# Returns $SUCCESS or an error code 
# 
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

    local aoi="`ls ${dirmaster}/AOI/*.shp | head -1`"
    
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

# Public: delete image data from node_import
# 
# Takes as argument an image tag and a workflow id
# 
# The function upon success will copy the registered slave image
# to an hdfs folder named with the slave image tag 
# 
# $1 - image tag
# $2 - workflow id
#
# Returns $SUCCESS or an error code if the image tag is
# not present in the node_import results folder
# 
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


# Public: run coregistration process for stripmap 
# images
# 
# The function upon success will copy the registered slave image
# to an hdfs folder named with the slave image tag 
# 
# $1 - local folder
# $2 - master image tag
# $3 - slave image tag
#
# Returns $SUCCESS or an error code otherwise
# 
function run_coreg_stripmap()
{
    if [ $# -lt 3  ]; then
	echo "Usage:$FUNCTION procdir orbitsm orbitslave"
	return ${ERRMISSING}
    fi

    if [ -z "${PROPERTIES_FILE}" ] || [ ! -e "${PROPERTIES_FILE}" ]; then
        ciop-log "ERROR" "Undefined PROPERTIES_FILE"
        return ${ERRMISSING}
    fi
    

    local procdir=$1
    
    local tagsm="$2"
    local tagslave="$3"

    local orbsm=""
    local orbslave=""

    product_tag_get_orbnum "${tagsm}" orbsm || {
	return ${ERRINVALID}
    }
    
    product_tag_get_orbnum "${tagslave}" orbslave || {
	return ${ERRINVALID}
    }
    
    
    local mlaz
    local mlran
    local interpx
    #
    read_multilook_factors ${tagsm} "${PROPERTIES_FILE}" mlaz mlran interpx || {
	ciop-log "ERROR" "Failed to determine multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}
    }
    
    if [ -z "${mlaz}" ] || [ -z "${mlran}" ] || [ -z "${interpx}" ]; then
	ciop-log "ERROR" "Failed to determine multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}	
    fi
    
     
    #check for dem descriptor
    local demdesc=${procdir}/DAT/dem.dat
    
    if [ ! -e "${demdesc}" ]; then
	echo "Missing demdescriptor file ${demdesc}"
	return ${ERRMISSING}
    fi 

    local orbitlist=`mktemp ${procdir}/DAT/orblist.txt.XXXXXX`
    
    if [ -z "${orbitlist}" ]; then
	ciop-log "ERROR" "canno create temporary orbit list in ${procdir}/DAT"
	return ${ERRGENERIC}
    fi

    echo "${orbsm}" > ${orbitlist} || {
	echo "cannot create orbit list"
	return ${ERRPERM}
    }
    
    echo "${orbslave}" >> ${orbitlist} || {
	echo "cannot update orbit list"
	return ${ERRPERM}
    }
    
    #run registration process
    local procoutput=${procdir}/log/coreg_${orbslave}.log 
    coreg_all.pl --list=${orbitlist} --serverdir=${procdir} --griddir=${procdir}/GRID --gridlindir=${procdir}/GRID_LIN --grids --demdesc=${demdesc} --sm=${orbsm} --tmpdir=${procdir}/TEMP --nocachedem --nocache --linear --interpx=${interpx} --mlaz=${mlaz} --mlran=${mlran} > ${procoutput} 2<&1
    local status=$?
    
    if [ $status -ne 0 ]; then
	ciop-log "ERROR" "Failed to register orbit ${orbslave}"
	echo "-------------------------------------------------${orbslave}"
	cat ${procdir}/GEO_CI2/${orbslave}_coregistration.log
	echo "-------------------------------------------------${orbslave}"
	cat ${procdir}/GEO_CI2_EXT_LIN/${orbslave}_linear_coregistration.log
	echo "-------------------------------------------------${orbslave}"
	
	return ${ERRGENERIC}
    fi 
    
    
    #publish results
    local pubstatus=""
    if [ "${orbsm}"  == "${orbslave}"  ]; then
	local pubsmtemp=$(procdirectory "${procdir}/TEMP")  || {
	    ciop-log "ERROR" "cannot create local folder ${procdir}/TEMP/${tagsm}"
	    return ${ERRPERM}
	}
	
	ln -s  ${procdir}/DAT/GEOSAR/${orbsm}.geosar ${pubsmtemp}/DAT/GEOSAR/
	ln -s  ${procdir}/DAT/GEOSAR/${orbsm}.geosar_ext ${pubsmtemp}/DAT/GEOSAR/
	ln -s ${procdir}/ORB/${orbsm}.orb ${pubsmtemp}/ORB/
	ln -s ${procdir}/GEO_CI2_EXT_LIN/geo_${orbsm}_${orbsm}.* ${pubsmtemp}/GEO_CI2_EXT_LIN/
	ln -s ${procdir}/SLC_CI2/doppler_${orbsm} ${pubsmtemp}/SLC_CI2/
	ln -s ${procdir}/GEO_CI2/${orbsm}_coregistration.log ${pubsmtemp}/log/
	ln -s ${procdir}/GEO_CI2_EXT_LIN/${orbsm}_linear_coregistration.log ${pubsmtemp}/log/
	

	#publish folder
	
	#get the process's hdfs folder
	local hdfsroot=`ciop-browseresults -r "${_WF_ID}" | sed 's@/node@ /node@g' | awk '{print $1}' | sort --unique`
	export_folder "${hdfsroot}/node_coreg/data" ${pubsmtemp} ${tagsm}
	 
	rm -rf "${pubsmtemp}"
	
    else
	#create directory to publish with registered slave image
	local pubtemp=$(procdirectory "${procdir}/TEMP")  || {
	    ciop-log "ERROR" "cannot create local folder ${procdir}/TEMP/${tagslave}"
	    return ${ERRPERM}
	}
	
	mv ${pubtemp} "${procdir}/TEMP/${tagslave}"
	pubtemp="${procdir}/TEMP/${tagslave}"
	
	#move results to folder to be published
	mv ${procdir}/DAT/GEOSAR/${orbslave}.geosar_ext ${pubtemp}/DAT/GEOSAR 
	mv ${procdir}/DAT/GEOSAR/${orbslave}.geosar ${pubtemp}/DAT/GEOSAR
	mv ${procdir}/ORB/${orbslave}.orb ${pubtemp}/ORB/
	mv ${procdir}/GEO_CI2_EXT_LIN/geo_${orbslave}_${orbsm}.* ${pubtemp}/GEO_CI2_EXT_LIN/
	mv ${procdir}/SLC_CI2/doppler_${orbslave} ${pubtemp}/SLC_CI2/
	mv ${procdir}/GEO_CI2/${orbslave}_coregistration.log ${pubtemp}/log/
	mv ${procdir}/GEO_CI2_EXT_LIN/${orbslave}_linear_coregistration.log ${pubtemp}/log/
	
        #clean data
	rm -f ${procdir}/GEO_CI2/geo_${orbslave}_${orbsm}.*
	
	#publish folder
	ciop-publish -a -r "${pubtemp}" 
	pubstatus=$?
	rm -rf "${pubtemp}"
	
	if [ $pubstatus -ne 0  ]; then
	    ciop-log "ERROR" "Failed to publish registration results for image ${tagslave}"
	    return ${ERRPERM}
	fi

    fi

    return ${SUCCESS}

# Public: run coregistration process  
# 
# $1 - local processing folder
# $2 - local imported slave image folder
# $3 - master image tag
# $4 - slave image tag
# $5 - workflow id
#
# Returns $SUCCESS or an error code otherwise
}

function run_coreg_process()
{
    if [ $# -lt 5 ]; then
	ciop-log "ERROR" "Usage : $FUNCTION serverdir cordir mastertag slavetag wfid"
	return ${ERRMISSING}
    fi

    local serverdir="$1"
    local cordir="$2"
    local mastertag="$3"
    local slavetag="$4"
    local wfid="$5"
    
    local immodetag=""
    
    product_tag_get_mode "${mastertag}" immodetag || {
	return ${ERRINVALID}
    }
    
    [ -z "${immodetag}" ] && {
	ciop-log "unable to infer acquisition mode from image tag ${immodetag}"
	return ${ERRINVALID}
    }

    if [ "${immodetag}" == "IW" ] || [ "${immodetag}" == "EW" ]; then
	ciop-log "INFO" "Importing Slave image ${slavetag}"
	local slavedir=$(import_safe "${cordir}" "${wfid}" "${slavetag}")
	
	run_coreg_process_tops "${serverdir}" "${cordir}" "${mastertag}" "${slavetag}" || {
	    ciop-log "ERROR" "Coregistration of image ${slavetag} failed"
	    return ${ERRGENERIC}
	}
    else
	ciop-log "INFO" "Importing Slave image ${slavetag}"
	import_extracted_image "${serverdir}/PROCESSING" "${wfid}" "${slavetag}"
	
	run_coreg_stripmap "${serverdir}/PROCESSING" "${mastertag}" "${slavetag}" || {
	    ciop-log "ERROR" "Coregistration of image ${slavetag} failed"
	    return ${ERRGENERIC}
	}
	
    fi

    return ${SUCCESS}
}
