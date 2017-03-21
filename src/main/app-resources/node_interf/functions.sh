#!/bin/bash


function import_coreg_results()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "Usage: $FUNCTION localdir run_id"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local runid="$2"

    for x in `ciop-browseresults -j node_coreg -r ${runid}`;do
	for d in `hadoop dfs -lsr ${x} | awk '{print $8}' | grep "DAT/GEOSAR/\|GEO_CI2_EXT_LIN/\|ORB/"`;do
	    local exten=${d##*.}
	#echo "${d} - ${exten}"
	local status=0
	case "${exten}" in
	    orb)hadoop dfs -copyToLocal ${d} ${procdir}/ORB/
		status=$?
		;;
	    *geosar*)hadoop dfs -copyToLocal ${d} ${procdir}/DAT/GEOSAR/
		status=$?
		;;
	    ci2)hadoop dfs -copyToLocal ${d} ${procdir}/GEO_CI2_EXT_LIN/
		status=$?
		;;
	    rad)hadoop dfs -copyToLocal ${d} ${procdir}/GEO_CI2_EXT_LIN/
		status=$?
		;;
	esac
	
	
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Failed to import file ${d}"
	    return 1
	}
	ciop-log "INFO" "Imported ${d}"
	done
	
    done

    find ${procdir} -name "*.geosar*"  -exec geosarfixpath.pl --geosar='{}' --serverdir=${procdir} \; > /dev/null 2<&1
    
    return 0
}

function import_interf_list()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "Usage: $FUNCTION localdir run_id"
	return ${ERRMISSING}
    fi
    local procdir="$1"
    local wkid="$2"
    
    for d in `ciop-browseresults -j node_selection -r ${wkid}  | grep MASTER_SELECTION`;do
 	for file in  `hadoop dfs -lsr ${d} | awk '{print $8}' | grep "name_slc\|list_interf\|SM_selection"`;do
	    hadoop dfs -copyToLocal ${file} ${procdir}/DAT/
	    status=$?
	    
	    [ $status -ne 0 ] && {
		ciop-log "ERROR" "Failed to import file ${file} (hadoop status $status)"
		ls -l ${procdir}/DAT/`basename ${file}`
		return 1
	    }
	done
    done
    
    local interflistfile=${procdir}/DAT/list_interf_auto.txt
    [ ! -f "${interflistfile}" ] && {
	ciop-log "ERROR" "Failed to import interferogram list file"
	return 1
    }

    local smselectionfile=${procdir}/DAT/SM_selection_auto.txt
    
    [ ! -f "${smselectionfile}" ] && {
	ciop-log "ERROR" "Failed to import SM selection file"
	return 1
    }
    
    
    return 0

}

function import_dem_from_node_selection()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "Usage: $FUNCTION localdir run_id"
	return ${ERRMISSING}
    fi
    local procdir="$1"
    local wkid="$2"
    
    local remotedemdir=`ciop-browseresults -j node_selection -r ${wkid} | grep DEM`
    
    [ -z "${remotedemdir}" ] && {
	echo "Missing remote DEM directory"
	return 1
    }
    local status=0
    for f in `hadoop dfs -lsr ${remotedemdir} | awk '{print $8}' | grep -i dem.tif`; do
	hadoop dfs -copyToLocal ${f} ${procdir}/DAT/ 
	status=$?
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Failed to import ${f}"
	    return 1
}
	#check imported geotiff dem
	local demtif=${procdir}/DAT/dem.tif
	
	[ ! -f "${demtif}" ] && {
	    ciop-log "ERROR" "Missing DEM file"
	    return 1
	}

	#convert to DIAP format
	tifdemimport.pl --intif="${demtif}" --outdir="${procdir}/DAT" > "${procdir}/DAT/demimport.log" 2<&1
	importst=$?
    
    if [ $importst -ne 0 ] || [ ! -e "${procdir}/DAT/dem.dat" ]; then
	ciop-log "ERROR"  "DEM conversion failed"
	#procCleanup
	return 1
    fi
	
    done
 
    return ${SUCCESS}
}

function check_data()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "Usage: $FUNCTION localdir interf_list"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local interflist="$2"

    for orb in `cat ${interflist} | awk '{print $1"\n"$2}' | sort --unique`; do
	#check for geosar_ext
	local geoextfile=${procdir}/DAT/GEOSAR/${orb}.geosar_ext
	
	[ ! -e "${geoextfile}" ] && {
	    ciop-log "ERROR" "Missing file ${geoextfile}"
	    return 1
	}
	
	local orbfile=${procdir}/ORB/${orb}.orb
	
	[ ! -e "${orbfile}" ] && {
	    ciop-log "ERROR" "Missing file ${orbfile}"
	    return 1
	}
	
	local geoci2file=`ls ${procdir}/GEO_CI2_EXT_LIN/geo_${orb}*.ci2 | head -1`
	
	[ ! -e "${geoci2file}" ] && {
	    ciop-log "ERROR" "Missing geo ci2 file for orbit ${orb} "
	    return 1
	}
	
    done


    return 0
}



function generate_interferograms()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "Missing argument procdir"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local smtag="$2"

    if [ -z "${PROPERTIES_FILE}" ] || [ ! -e "${PROPERTIES_FILE}" ]; then
	ciop-log "ERROR" "Undefined PROPERTIES_FILE"
	return ${ERRMISSING}
    fi
    
    #infer super-master orbit
    local smselection="${procdir}/DAT/SM_selection_auto.txt"
    
    [ ! -e "${smselection}" ] && {
	ciop-log "ERROR" "Missing file ${smselection}"
	return ${ERRMISSING}
    }

    local smorb=`grep [0-9] ${smselection} | head -1`
    
    [ -z "${smorb}" ] && {
	ciop-log "ERROR" "Unable to determine super-master orbit number"
	return ${ERRINVALID}
    }

    local listinterf="${procdir}/DAT/list_interf_auto.txt"
    
    [ ! -e "${listinterf}" ] && {
	ciop-log "ERROR" "Missing file ${listinterf}"
	return ${ERRMISSING}
    }

    #read parameters from properties
    local rnunder
    local azunder
    read_geom_undersampling "${procdir}/DAT/GEOSAR/${smorb}.geosar_ext" "${PROPERTIES_FILE}" azunder rnunder || {
	ciop-log "ERROR" "Failed to determine geometric undersampling factors"
	return ${ERRGENERIC}
    }

    local mlaz
    local mlran
    local interpx
    #
    read_multilook_factors ${smtag} "${PROPERTIES_FILE}" mlaz mlran interpx || {
	ciop-log "ERROR" "Failed to determine multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}
    }
    
    if [ -z "${mlaz}" ] || [ -z "${mlran}" ] || [ -z "${interpx}" ]; then
	ciop-log "ERROR" "Failed to determine multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}	
    fi

    mlran=`echo ${mlran}*${interpx} | bc -l`
    

    if [ -z "${azunder}" ] || [ -z "${rnunder}" ]; then
	    ciop-log "ERROR" "Failed to determine geometric undersampling factors"
	    return ${ERRGENERIC}
    fi
	
    echo "INFO read ${azunder} ${rnunder}"

    #iterate over list interf
    while read data;do
	declare -a interflist
	interflist=(`echo $data`)
	
	[ ${#interflist[@]} -lt 2 ] && {
	    ciop-log "ERROR" "Invalid line ${data} from ${listinterf}"
	    continue
	}
	
	#TO-DO read ML and under from properties
	local smgeo=${procdir}/DAT/GEOSAR/${smorb}.geosar_ext
	local mastergeo=${procdir}/DAT/GEOSAR/${interflist[0]}.geosar_ext
	local slavegeo=${procdir}/DAT/GEOSAR/${interflist[1]}.geosar_ext
	local masterci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[0]}_${smorb}.ci2
	local slaveci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[1]}_${smorb}.ci2
	
	interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${mlaz} --mlran=${mlran} --aziunder=${azunder} --ranunder=${rnunder} --demdesc=${procdir}/DAT/dem.dat --coh --bort --inc --ran --dir=${procdir}/DIF_INT --outdir=${procdir}/DIF_INT/ --tmpdir=${procdir}/TEMP   > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}.log 2<&1
	local status=$?
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Generation of interferogram ${interflist[0]} - ${interflist[1]} Failed"
	    return ${ERRMISSING}
	}

	ciop-log "INFO" "Generation of interferogram ${interflist[0]} - ${interflist[1]} successful"

	
    done < <(cat ${listinterf} | awk '{print $1" "$2}')

    #run carto_sar

    
    return ${SUCCESS}
}

