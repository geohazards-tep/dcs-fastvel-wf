#!/bin/bash

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
    
    #launch xvfb as interf_selection needs a display
    local display=$(xvfblaunch "${TMPDIR}")
    
    [ -z "${display}" ] && {
	ciop-log "ERRROR" "cannot launch Xvfb"
	return 1
    }
    export DISPLAY=:${display}.0

    #interf_selection
    local isprog="/opt/interf_selection/interf_selection_auto.sav"
    #echo "$PATH" > /tmp/envpath.txt
    #env > /tmp/env.log 2<&1
    
    #backup and set the SHELL environment variable to bash
    local SHELLBACK=${SHELL}
    export SHELL=${BASH}
    [ -z "${SHELL}" ] &&  {
	export SHELL=/bin/bash
    }    
    cd ${serverdir}/ORB
    
    #run alt ambig
    find ${serverdir}/ -iname "*.orb" -print | alt_ambig.pl --geosar=`ls ${serverdir}/DAT/GEOSAR/*.geosar | head -1` > /tmp/log/alt_ambig.log 2<&1
    chmod 777 /tmp/*.log 2>/dev/null
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
    find ${serverdir} -type f -print > /tmp/issfiles.txt
    chmod -R 777 /tmp/issfiles.txt
    cp ${serverdir}/log/interf_selection.log /tmp
    chmod 777 /tmp/interf_selection.log
    cp ${serverdir}/TEMP/interf_selection.log /tmp/interf_selection2.log
    chmod 777 /tmp/interf_selection2.log
    local orbitsm=`grep -m 1 "[0-9]" ${serverdir}/TEMP/SM_selection_auto.txt`
    
    [ -z "${orbitsm}" ] && {
	ciop-log "ERROR" "Failed to determine Master aquisition"
	return 1
    } 

    local geosarsm="${serverdir}/DAT/GEOSAR/${orbitsm}.geosar"
    
    [ ! -e "${geosarsm}" ] && {
	ciop-log "ERROR" "Missing Master aquistion geosar"
	return 1
    }
    
    local smtag=$(geosartag "${geosarsm}")
    
    echo ${smtag} > "${serverdir}/TEMP/SM.txt"
    
    return ${isstatus}
}


function merge_datasetlist()
{
    if [ $# -lt 2 ]; then
	return 1
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
	return 1
    }
    
    
    

    return 0
}



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
	hadoop dfs -rm ${remotegeosar}
	hadoop dfs -put ${updatedgeosar} ${remotedir}/DAT/GEOSAR/
    else
	local msg=`cat ${procdir}/log/precise_sm.log`
	ciop-log "DEBUG" "${msg}"
    fi

    ciop-log "INFO" "Precise sm status ${precstatus}"
    return ${SUCCESS}
}
