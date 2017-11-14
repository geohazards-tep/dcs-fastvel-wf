#!/bin/bash

# Public: Import image files published
# from node_import that are needed
# for interf selection
#
# The function takes as arguments the local 
# folder where the files should be imported,
# the workflow id , and the tag of the image
#
# $1 - local folder for data import
# $2 - workflow id
# $3 - image tag
#
# Examples
#
#   import_data_selection "${serverdir}" "${wkid}" "${imagetag}"
#
# Returns 0 on success and 1 on error
#   

function import_data_selection()
{
    if [ $# -lt 3 ]; then
	return 1
    fi
    local localdir="$1"
    local runid="$2"
    local imagetag="$3"
    
    local remotedir=`ciop-browseresults -r "${runid}" -j node_import | grep ${imagetag}`
    [ -z "${remotedir}" ] && {
	ciop-log "ERROR" "image directory ${imagetag} not found in remote"
	return 1
    }
    
    #import remote files to local
    for file in `hadoop dfs -lsr "${remotedir}" | grep "\.geosar" | awk '{print $8}'`; do

	hadoop dfs -copyToLocal "${file}" "${localdir}/DAT/GEOSAR" || {
	    ciop-log "ERROR" "Failed to import ${file}"
	    return 1
}
	
    done

    for file in `hadoop dfs -lsr "${remotedir}" | grep "\.orb" | awk '{print $8}'`; do	
	hadoop dfs -copyToLocal "${file}" "${localdir}/ORB" || {
	    ciop-log "ERROR" "Failed to import ${file}"
	    return 1
	}
    done
    
    for file in `hadoop dfs -lsr "${remotedir}" | grep "doppler_" | awk '{print $8}'`; do
	
	hadoop dfs -copyToLocal "${file}" "${localdir}/SLC_CI2" || {
	    ciop-log "ERROR" "Failed to import ${file}"
	    return 1
	}
    done

    for file in `hadoop dfs -lsr "${remotedir}" | grep "xml" | awk '{print $8}'`; do
	
	hadoop dfs -copyToLocal "${file}" "${localdir}/SLC_CI2" || {
	    ciop-log "ERROR" "Failed to import ${file}"
	    return 1
	}
    done
    
    for file in `hadoop dfs -lsr "${remotedir}" | grep "aoi.txt" | awk '{print $8}'`; do
	
	hadoop dfs -cat "${file}" >  "${localdir}/DAT/aoi.txt" || {
	    ciop-log "ERROR" "Failed to import ${file}"
	    return 1
	}
    done


    for g in `find ${localdir} -name "*.geosar" -print`; do
	geosarfixpath.pl --geosar="$g" --serverdir="${localdir}"
    done

    


    return 0
}

# Public: Run interferogram selection
# The function takes as arguments the local 
# folder where the relevant image files 
# have been imported with import_data_selection
#
# $1 - local processing folder
#
# Examples
#
#       run_selection "${serverdir}" 
#
# Returns 0 on success and non-zero on error
#   
function run_selection()
{
    if [ $# -lt 1 ]; then
	return 255
    fi
    
    local serverdir="$1"
    
    #check on the input 
    if [ ! -e "${serverdir}/DAT" ]; then
	return 255
    fi

    #variables from interf_selection
    export RADARTOOLS_DIR=/opt/diapason
    export SERVER_DIR="${serverdir}"
    
    #set orb_list.dat
    grep -ih "ORBIT NUMBER"  ${serverdir}/DAT/GEOSAR/*.geosar  | cut -b 40-1024 | sed 's@[[:space:]]@@g' > "${serverdir}/DAT/orb_list.dat"
    
    #check for empty orb_list.dat
    local cnt=`cat ${serverdir}/DAT/orb_list.dat | wc -l`
    
    if [ $cnt -le 1 ]; then
	ciop-log "ERROR" "too few images ($cnt) for interf selection"
	return 1
    fi
    
    #set mission
    local mission=`grep -ih "SENSOR NAME" ${serverdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | sed 's@[[:space:]]@@g' | sort --unique | head -1`
    
    case $mission in
	ENVISAT)export MISSION="ENVISAT";;
	ERS*)export MISSION="ERS";;
	S1*)export MISSION="SENTINEL-1";;
	*) unset MISSION;;
    esac

    [ -z "${MISSION}" ] && {
	ciop-log "ERROR" "Unsupported mission ${mission}"
	return 1
    }
    
    #set parameters inputs from the user if any
    if [ -n "${btempmax}" ]; then
	export BTEMP_MAX_IN="${btempmax}"
	ciop-log "INFO" "Maximum perpendicular baseline : ${BTEMP_MAX_IN}"
    fi

    if [ -n "${bperpmax}" ]; then
	export BPERP_MAX_IN="${bperpmax}"
	ciop-log "INFO" "Maximum temporal baseline : ${BPERP_MAX_IN}"
    fi 

    if [ -n "${dopdiffmax}" ]; then
	export DOPDIFF_MAX_IN="${dopdiffmax}"
	ciop-log "INFO" "Maximum doppler difference : ${DOPDIFF_MAX_IN}"
    fi
    
    if [ -n "${dopimgmax}" ]; then
	export DOPIMAGE_MAX_IN="${dopimgmax}"
	ciop-log "INFO" "Maximum doppler centoid : ${DOPIMAGE_MAX_IN}"
    fi

    #launch xvfb as interf_selection needs a display
    local display=$(xvfblaunch "${TMPDIR}")
    
    [ -z "${display}" ] && {
	ciop-log "ERRROR" "cannot launch Xvfb"
	return 1
    }
    export DISPLAY=:${display}.0

    #interf_selection
    local isprog="/opt/interf_selection/interf_selection_auto.sav"
    
    #backup and set the SHELL environment variable to bash
    local SHELLBACK=${SHELL}
    export SHELL=${BASH}
    [ -z "${SHELL}" ] &&  {
	export SHELL=/bin/bash
    }    
    cd ${serverdir}/ORB
    
    #run alt ambig
    find ${serverdir}/ -iname "*.orb" -print | alt_ambig.pl --geosar=`ls ${serverdir}/DAT/GEOSAR/*.geosar | head -1` > ${serverdir}/log/alt_ambig.log 2<&1
    
    timeout 300s idl -rt=${isprog} > ${serverdir}/log/interf_selection.log 2<&1
    local isstatus=$?
    
    cd -
    #reset the SHELL variable to its original value
    export SHELL=${SHELLBACK}
    
    
    #cleanup Xvfb stuff
    unset DISPLAY
    local xvfbpid=`head -1 ${TMPDIR}/xvfblock_${display}`
    kill ${xvfbpid} > /dev/null 2<&1
    rm "${TMPDIR}/xvfblock_${display}" 

    ciop-log "DEBUG" "interf selection status : $isstatus"
   
    local orbitsm=`grep -m 1 "[0-9]" ${serverdir}/TEMP/SM_selection_auto.txt`
    
    [ -z "${orbitsm}" ] && {
	ciop-log "ERROR" "Failed to determine Master aquisition"
	local msg=`cat ${serverdir}/log/interf_selection.log`
	ciop-log "ERROR" "$msg"
	return 1
    } 

    local geosarsm="${serverdir}/DAT/GEOSAR/${orbitsm}.geosar"
    
    [ ! -e "${geosarsm}" ] && {
	ciop-log "ERROR" "Missing Master aquistion geosar"
	local msg=`cat ${serverdir}/log/interf_selection.log`
	ciop-log "ERROR" "$msg"
	return 1
    }
    
    local smtag=$(geosartag "${geosarsm}")
    
    echo ${smtag} > "${serverdir}/TEMP/SM.txt"
    
    #
    local dop_filtered=${serverdir}/TEMP/dop_filtered.txt
    local list_interf=${serverdir}/TEMP/list_interf_auto.txt
    local name_slc=${serverdir}/TEMP/name_slc_auto.txt
    
    if [ -e "${list_interf}" ] && [ -e "${name_slc}" ]; then
	dopmax_remove.pl --nameslc="${name_slc}" --serverdir=${serverdir} --interflist=${list_interf} --tmpdir=${serverdir}/TEMP --dopmax=${DOPIMAGE_MAX_IN}
	
	local count_interf=`grep [0-9] ${list_interf} | wc -l`
	if [ ${count_interf} -eq 0 ]; then
	    ciop-log "ERROR" "Image doppler filtering results in no interferograms "
	    return $ERRGENERIC
	fi
    fi

    return ${isstatus}
}

# Public: create a file merging the contents 
# of each image folder's dataset file
#
# Takes the local processing folder
# and the workflow id
#
# $1 - local processing folder
# $2 - workflow id
#
# Examples
#
#   merge_datasetlist "${serverdir}" "${wkid}"
#
# Returns $SUCCESS on success or an error code otherwise
#   

function merge_datasetlist()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi
    
    local serverdir="$1"
    local runid="$2"
    
    local mergeddataset="${serverdir}/DAT/dataset.txt"
    #iterate over all directories from node_import
    for dir in `ciop-browseresults -r "${runid}" -j node_import`; do
	for dataset in `hadoop dfs -lsr ${dir} | grep dataset.txt | awk '{print $8}'`;do
	    #echo "Dataset ${dataset}"
	    local data=`hadoop dfs -cat ${dataset}`
	    ciop-log "DEBUG" "data->${data}"
	    hadoop dfs -cat ${dataset} >> ${mergeddataset}
	done
    done
    
    local cnt=`cat ${mergeddataset} | wc -l`
    
    [ $cnt -eq 0 ] && {
	ciop-log "ERROR" "Empty merged dataset file"
	return ${ERRINVALID}
    }
    
    
    

    return ${SUCCESS}
}

# Public: search and remove images inconsistent
# with the rest of the data set
#
# Takes the local processing folder
# and the workflow id
#
# $1 - local processing folder
# $2 - workflow id
#
# Examples
#
#   filter_imported_data "${serverdir}" "${wkid}"
#
# Returns status of last command
#   

function filter_imported_data()
{
    if [ $# -lt 2 ]; then
	return 1
    fi
    
    local serverdir="$1"
    local runid="$2"
    
    local tagstodiscard="${serverdir}/TEMP/discardedlist.dat"
    ciop-browseresults -r "${runid}" -j node_import | xargs -L 1 basename | check_taglist.pl --outfile="${tagstodiscard}"
    
    if  [ -e "${tagstodiscard}" ]; then
	for tag in `cat ${tagstodiscard}`; do
	    for tagdir in `ciop-browseresults -r "${runid}" -j node_import | grep ${tag}` ;do
		ciop-log "INFO" "Discarding image with tag ${tag}"
		hadoop dfs -rmr "${tagdir}" > /dev/null 2<&1
	    done
	done
    fi

}

# Public: Create a virtual x server with Xvfb
#
# The function takes as argument a folder 
# to be used for temporary files.
# A suitable display is determined 
# and used with Xfvb
# 
# The function will echo the display number
# 
# Examples
#
#   local display=$(xvfblaunch "${TMPDIR}")
#
# Returns $SUCCESS if the folder was created or an error code otherwise
#   
function xvfblaunch()
{
    if [ $# -lt 1 ]; then
	echo ""
	return ${ERRMISSING}
    fi

    local tempdir="$1"
    
    for x in `seq 1 1000`; do 
	local lockfile="${tempdir}/xvfblock_${x}"
	if ( set -o noclobber ; echo $$ >  "${lockfile}") 2>/dev/null; then
	    
	    set +o noclobber;
	    #check for already running X server
	    if [ -f "/tmp/.X${x}-lock" ]; then
		continue
	    fi
	    #launch xvfb
	    Xvfb :${x} -screen 0 1280x1024x16 & > /dev/null 2<&1
	    local xvfbstatus="$?"
	    [ "$xvfbstatus" != "0" ] && {
		rm "${lockfile}"
		continue
	    } 
	    local xvfbpid=$!
	    echo ${xvfbpid} > "${lockfile}"
	    echo "${x}"
	    return ${SUCCESS}
	fi
    done
    
    return ${ERRGENERIC}    
}

# Public: Run precise sm on selected master image
#
#
# $1 - local processing directory
# $2 - tag for the super-master image
# $3 - workflow id
#
# Examples
#
#   compute_precise_sm "${serverdir}" "${smtag}" "${wkid}"
#
# Returns $SUCCESS if the folder was created or an error code otherwise
#   

function compute_precise_sm()
{
    if [ $# -lt 3 ]; then
	ciop-log "ERROR" "usage:$FUNCTION procdir smtag runid"
	return ${ERRMISSING}
    fi
    
    local procdir="$1"
    local smtag="$2"
    local wkid="$3"
    
    local immode=""
    local orbsm=""

    product_tag_get_mode "${smtag}" immode || {
	return ${ERRINVALID}
    }

    product_tag_get_orbnum "${smtag}" orbsm || {
	return ${ERRINVALID}
    }

    if [ "${immode}" == "IW" ] ||  [  "${immode}" == "EW" ]; then
	return ${SUCCESS}
    fi
    
    #import DEM
    local demtif=$(ls ${procdir}/DEM/*.tif | head -1)
    
    if [ -z "${demtif}" ]; then
	ciop-log "ERROR" "No DEM found in ${procdir}/DEM/"
	return ${ERRMISSING}
    fi
    
    #create DEM descriptor
    tifdemimport.pl --intif="${demtif}" --outdir="${procdir}/DAT/" > "${procdir}/DEM/demimport.log" 2<&1
    importst=$?
    
    if [ $importst -ne 0 ] || [ ! -e "${procdir}/DAT/dem.dat" ]; then
	ciop-log "ERROR" "DEM conversion failed"
	#procCleanup
	return ${ERRGENERIC}
    fi


    local remotedir=`ciop-browseresults -r "${wkid}" -j node_import | grep ${smtag}`
    [ -z "${remotedir}" ] && {
	ciop-log "ERROR" "image directory ${smtag} not found in remote"
	return ${ERRMISSING}
    }
    #import multilook 
    for file in `hadoop dfs -lsr "${remotedir}" | awk '{print $8}' | grep "SLC_CI2" | grep ml | grep "\.rad\|\.byt" `; do
	
	hadoop dfs -copyToLocal "${file}" "${procdir}/SLC_CI2" || {
	    ciop-log "ERROR" "Failed to import ${file}"
	    return ${ERRGENERIC}
	}
    done
    
    geosarfixpath.pl --geosar=${procdir}/DAT/GEOSAR/${orbsm}.geosar --serverdir=${procdir}

    ciop-log "INFO" "Running precise SM "
    precise_sm.pl --sm=${procdir}/DAT/GEOSAR/${orbsm}.geosar --demdesc=${procdir}/DAT/dem.dat --recor --serverdir=${procdir} --tmpdir=${procdir}/TEMP/ > ${procdir}/log/precise_sm.log 2<&1
    local precstatus=$?
    
    if [ $precstatus -eq 0 ]; then
	#update geosar file in node import
	local remotegeosar="${remotedir}/DAT/GEOSAR/${orbsm}.geosar"
	local updatedgeosar="${procdir}/DAT/GEOSAR/${orbsm}.geosar"
	hadoop dfs -rm ${remotegeosar} > /dev/null 2<&1
	hadoop dfs -put ${updatedgeosar} ${remotedir}/DAT/GEOSAR/
    else
	local msg=`cat ${procdir}/log/precise_sm.log`
	ciop-log "DEBUG" "${msg}"
    fi

    ciop-log "INFO" "Precise sm status ${precstatus}"
    return ${SUCCESS}
}


# Public: create a lock directory
# in hdfs folder for node_selection
# (default) 
# output
#
# $1 - workflow id
# $2 - node name (if unset , then "node_selection" is used)
# Examples
#
#   create_lock ${_WF_ID}
#
# Returns $SUCCESS if the folder was created or an error code otherwise
#   
function create_lock()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    local node_="node_selection"
    if [ $# -ge 2 ]; then
	node_="$2"
    fi

    local wkid=$1
    
    local hdfsroot=`ciop-browseresults -r ${wkid} | sed 's@/node_@ @g' | awk '{print $1}' | sort --unique`
    
    if [ -z "$hdfsroot" ]; then
	return $ERRINVALID
    fi
    
    local lockdir="${hdfsroot}/${node_}/lock"
    
    hadoop dfs -mkdir ${lockdir} > /dev/null 2<&1 || {
	return ${ERRGENERIC}
    }
    
    ciop-log "INFO" "created ${lockdir} `date`"

    return $SUCCESS
}