#!/bin/bash


# Public: import coregistered images results from node_coreg
#
# Takes a local folder and the workflow id as arguments
# 
# The function will copy to the local folder for each image
# the geosar ,orb,coregistered ci2 files
#
# $1 - local processing folder path
# $2 - workflow id
#
#
# Returns 0 on success and 1 on error
#   

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

# Public: import interferogram list
#
# Takes a local folder and the workflow id as arguments
# 
# The function will copy to the local folder the results
# of the interferogram selection from the MASTER_SELECTION
# folder from node_import
#
# $1 - local processing folder path
# $2 - workflow id
#
#
# Returns 0 on success and 1 on error
#   

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

# Public: DEM from node_selection results
#
# Takes a local folder and the workflow id as arguments
# 
# The function will copy to the local folder the DEM
#
# $1 - local processing folder path
# $2 - workflow id
#
#
# Returns 0 on success and 1 on error
#   

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


# Public: check the inputs for the interferogram generation
#
# Takes a local folder and the interferogram list
# 
#
# $1 - local processing folder path
# $2 - path to interferogram list
#
# Returns 0 on success and 1 on error
#   
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


# Public: check the inputs for the interferogram generation
#
# Takes a local folder and the interferogram list
# 
#
# $1 - local processing folder path
# $2 - path to interferogram list
#
# Returns $SUCCESS on success and an error code otherwise
#
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
    #multilook factors for interferograms used in orbit correction
    local ocmlaz
    local ocmlran
    
    read_multilook_factors_orbit_correction ${smtag} "${PROPERTIES_FILE}" ocmlaz ocmlran  || {
	ciop-log "ERROR" "Failed to determine orbit correction multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}
    }

    #SM geosar
    local smgeo=${procdir}/DAT/GEOSAR/${smorb}.geosar_ext
    
    #set lat/long corner
    setlatlongeosar.pl --geosar=${smgeo} --tmpdir=${procdir}/TEMP > /dev/null 2<&1

    #alt_ambig
    local altambigfile="${procdir}/DAT/AMBIG.DAT"
    ls ${procdir}/ORB/*.orb | alt_ambig.pl --geosar=${smgeo}  -o "${altambigfile}"   > /dev/null 2<&1
    
    ##################################################
    #cp ${smgeo} ${procdir}/DIF_INT/
    ##################################################
    
    #aoi
    local aoifile="${procdir}/DAT/aoi.txt"
    local aoidef=`grep "[0-9]" ${aoifile} | head -1`
    local roi=""
    local roiopt=""
    
    if [ -e "${aoifile}" ] && [ -n "$aoidef" ] ; then
	roi=$(geosar_get_aoi_coords2 "${smgeo}" "${aoidef}" "${procdir}/DAT/dem.dat"  "${procdir}/log/" )
	local roist=$?
	ciop-log "INFO" "geosar_get_aoi_coords status ${roist}"
    else
	ciop-log "INFO" "Missing file ${aoifile}"
	ciop-log "INFO" "aoi defn ${aoidef}"
    fi

    ciop-log "INFO" "aoi roi defn : ${roi}"
    [ -n "${roi}" ] && {
    	roiopt="--roi=${roi}"
    }
    
    #iterate over list interf
    while read data;do
	declare -a interflist
	interflist=(`echo $data`)
	
	[ ${#interflist[@]} -lt 2 ] && {
	    ciop-log "ERROR" "Invalid line ${data} from ${listinterf}"
	    continue
	}
	
	#TO-DO read ML and under from properties
	local mastergeo=${procdir}/DAT/GEOSAR/${interflist[0]}.geosar_ext
	local slavegeo=${procdir}/DAT/GEOSAR/${interflist[1]}.geosar_ext
	local masterci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[0]}_${smorb}.ci2
	local slaveci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[1]}_${smorb}.ci2
	
	interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${mlaz} --mlran=${mlran} --aziunder=${azunder} --ranunder=${rnunder} --demdesc=${procdir}/DAT/dem.dat --coh --bort --inc --ran --dir=${procdir}/DIF_INT --outdir=${procdir}/DIF_INT/ --tmpdir=${procdir}/TEMP "${roiopt}"  > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}.log 2<&1
	local status=$?
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Generation of interferogram ${interflist[0]} - ${interflist[1]} Failed"
	    return ${ERRMISSING}
	}
	
	interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${ocmlaz} --mlran=${ocmlran} --aziunder=${azunder} --ranunder=${rnunder} --demdesc=${procdir}/DAT/dem.dat --coh  --dir=${procdir}/DIF_INT --outdir=${procdir}/DIF_INT/ --tmpdir=${procdir}/TEMP --nobort --noinc --noran   > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_ml${ocmlaz}${ocmlran}.log 2<&1

	[ -n "${roi}" ] && {
	    ln -s ${procdir}/DIF_INT/pha_cut_${interflist[0]}_${interflist[1]}_ml${mlaz}${mlran}.pha ${procdir}/DIF_INT/pha_${interflist[0]}_${interflist[1]}_ml${mlaz}${mlran}.pha
	    ln -s ${procdir}/DIF_INT/pha_cut_${interflist[0]}_${interflist[1]}_ml${mlaz}${mlran}.rad ${procdir}/DIF_INT/pha_${interflist[0]}_${interflist[1]}_ml${mlaz}${mlran}.rad
	    
	} 

	ciop-log "INFO" "Generation of interferogram ${interflist[0]} - ${interflist[1]} successful"

	
    done < <(cat ${listinterf} | awk '{print $1" "$2}')

    #fvel config generation
    local numsar=`ls ${procdir}/ORB/*.orb | wc -l`
    local numint=`cat ${listinterf} | wc -l`
    local mlrad=`ls ${procdir}/DIF_INT/pha*.rad | head -1`
    local fvelconf=${procdir}/DAT/fastvel.conf
    
    genfvelconf.pl --geosar=${smgeo} --altambig=${altambigfile} --mlradfile=${mlrad} --mlaz=${mlaz} --mlran=${mlran} --numsar=${numsar} --numint=${numint}  "${roiopt}"   1> ${fvelconf} 2> ${procdir}/log/genfvel.err
    local genfvelst=$?
    
    if [ ${genfvelst} -ne 0 ]; then
	ciop-log "ERROR" "genfvelconf failure"
	local msg=`cat ${procdir}/log/genfvel.err`
	ciop-log "DEBUG" "${msg}"
	return ${ERRGENERIC}
    fi
    
    #run carto_sar
    #set some fields in the geosar
    sed -i -e 's@\(AZIMUTH DOPPLER VALUE\)\([[:space:]]*\)\([^\n]*\)@\1\20.0@g' "${smgeo}"
    sed -i -e 's@\(DEM TYPE\)\([[:space:]]*\)\([^\n]*\)@\1\2TRUE@g' "${smgeo}"
    

    ciop-log "INFO" "Running carto_sar"
    cartosar.pl --geosar=${smgeo} --tag="precise_${smorb}" --dir=${procdir}/GEOCODE/ --demdesc=${procdir}/DAT/dem.dat  > ${procdir}/log/cartosar.log 2<&1
    local cartost=$?
    ciop-log "INFO" "carto_sar status : $?"

    #remove the coregistered images
    rm -f ${serverdir}/GEO_CI2_EXT_LIN/geo* > /dev/null 2<&1
    #remove symbolic links if any
    find ${serverdir}/DIF_INT/ -type l -exec rm '{}' \; > /dev/null 2<&1

    return ${SUCCESS}
}

# Public: import aoi to local folder
#
# Takes a local folder ,the master image tag,
# and workflow id as arguments
# 
# $1 - local processing folder path
# $2 - master image tag
# $3 - workflow id
#
# Returns $SUCCESS on success and an error code otherwise
#
function import_aoi_def_from_node_import()
{
     if [ $# -lt 3 ]; then
	 ciop-log "ERROR" "Usage:$FUNCTION localdir smtag run_id"
	 return ${ERRMISSING}
     fi

     local procdir="$1"
     local smtag="$2"
     local wkid="$3"

     local remotesmdir=`ciop-browseresults -j node_import -r "${wkid}" | grep ${smtag}`
     
     if [ -z "${remotesmdir}" ]; then
	 ciop-log "ERROR" "Failed to locate folder for image tag ${smtag}"
	 return ${ERRMISSING}
     fi

     local remoteaoifile=`hadoop dfs -lsr ${remotesmdir} | awk '{print $8}' | grep -i aoi.txt`
     
     if [ -z "${remoteaoifile}" ]; then
	 ciop-log "ERROR" "No aoi definition file in remote folder ${remotesmdir}"
	 return ${ERRMISSING}
     fi

     local localaoifile=${procdir}/DAT/aoi.txt
     hadoop dfs -cat "${remoteaoifile}" > "${localaoifile}" || {
	 ciop-log "ERROR" "Failed to import file ${remoteaoifile}"
	 return ${ERRMISSING}
     }
     
     
     return ${SUCCESS}
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

# Public: generate config file to launch fast vel algorithm
# 
# $1 - local processing folder path
#
# Returns $SUCCESS on success and an error code otherwise
function generate_fast_vel_conf()
{
	local procdir="$1"
	local templatefile="/opt/fastvel/src/CONF_FILE/conf_file_platform.txt"
	local templateprocessedfile="${procdir}/conf_fastvel_processed.txt"
	local fastvelconf="${procdir}/DAT/fastvel.conf"
	if [ ! -f "${fastvelconf}" ]; then
		ciop-log "ERROR" "no fast vel configuration file found"
		return ${ERRMISSING}
	fi
	aux_file="${procdir}/conf_fastvel_processed_aux.txt"
	cp $templatefile $aux_file
	SM=0

	#parse template file with the fastvel.conf values
	while read line; do
		array_line=(${line// / })
		if [[ "${array_line[0]}" == "SM" ]]; then
			SM=${array_line[1]}
		fi
		sed -e "s#{${array_line[0]}}#${array_line[1]}#g" \
		< $aux_file > $templateprocessedfile
		cp $templateprocessedfile $aux_file
	done < $fastvelconf

	#create output directory for fast vel algorithm
	mkdir -p {procdir}/output_fastvel || {
		ciop-log "ERROR" "Error creating directory in ${procdir}"
		procCleanup 
		return ${ERRPERM}
    }


	#get values needed from INSAR_PROCESSING folder
	local outputdir="${procdir}/output_fastvel"
	local nameslcfile="${procdir}/DAT/name_slc_auto.txt"

	if [ ! -f "${nameslcfile}" ]; then
		ciop-log "ERROR" "no slc file found"
		return ${ERRMISSING}
	fi

	local nameinterffile="${procdir}/DAT/list_interf_auto.txt"

	if [ ! -f "${nameinterffile}" ]; then
		ciop-log "ERROR" "no name of interferogram list found"
		return ${ERRMISSING}
	fi

	local origphadir="${procdir}/DIF_INT"
	local phadir="${procdir}/DIF_INT"
	local cohdir="${procdir}/DIF_INT"
	local demfile="${procdir}/DAT/dem.tif"

	if [ ! -f "${demfile}" ]; then
		ciop-log "ERROR" "no DEM file found"
		return ${ERRMISSING}
	fi

	local cartopreciselat="${procdir}/GEOCODE/carto_precise_${SM}_lat.r8"

	if [ ! -f "${cartopreciselat}" ]; then
		ciop-log "ERROR" "Can not found carto precise lat of SM"
		return ${ERRMISSING}
	fi
	local cartopreciselon="${procdir}/GEOCODE/carto_precise_${SM}_lon.r8"

	if [ ! -f "${cartopreciselon}" ]; then
		ciop-log "ERROR" "Can not found carto precise lon of SM"
		return ${ERRMISSING}
	fi

	#get values needed from UI
	local coherencethreshold=`ciop-getparam Coh_Threshold`
	local pointreflon=`ciop-getparam ref_point_lon`
	local pointreflat=`ciop-getparam ref_point_lat`
	local aps_correlation=`ciop-getparam aps_smoothing`

	#parse variables on the template processed file
	sed -e "s#{OUTPUT_DIR}#$outputdir#g" \
      -e "s#{NAME_SLC}#$nameslcfile#g"  \
      -e "s#{NAME_INTERF_FILE}#$nameinterffile#g"  \
      -e "s#{ORIG_PHA_DIR}#$origphadir#g"  \
      -e "s#{PHA_DIR}#$phadir#g"  \
      -e "s#{COH_DIR}#$cohdir#g"  \
      -e "s#{DEM_FILE}#$demfile#g"  \
      -e "s#{CARTO_PRECISE_LAT}#$cartopreciselat#g"  \
      -e "s#{CARTO_PRECISE_LON}#$cartopreciselon#g"  \
      -e "s#{COHERENCE_THRESHOLD}#$coherencethreshold#g"  \
      -e "s#{POINT_REF_LON}#$pointreflon#g"  \
      -e "s#{POINT_REF_LAT}#$pointreflat#g"  \
      -e "s#{APS_CORRELATION}#$aps_correlation#g"  \
      < $aux_file > $templateprocessedfile

    return ${SUCCESS}
}

# Public: execute fast vel algorithm
#
# Returns $SUCCESS on success and an error code otherwise
function execute_fast_vel()
{
	local TMPDIR="$1"
	local procdir="$2"
	#launch xvfb as fast vel needs a display
    local display=$(xvfblaunch "${TMPDIR}")
    [ -z "${display}" ] && {
		ciop-log "ERRROR" "cannot launch Xvfb"
		return 1
    }
    export DISPLAY=:${display}.0
    #fast vel
    local fastvelsav="/opt/fastvel/bin/fastvel.sav"

    #backup and set the SHELL environment variable to bash
    local SHELLBACK=${SHELL}
    export SHELL=${BASH}
    [ -z "${SHELL}" ] &&  {
	export SHELL=/bin/bash
    }

    fastvelconffile="${procdir}/conf_fastvel_processed.txt"

    if [ ! -f "${fastvelconffile}" ]; then
		ciop-log "ERROR" "no fast vel configuration for algorithm file found"
		return ${ERRMISSING}
	fi

    idl -rt=$fastvelsav -args "$fastvelconffile"

    #reset the SHELL variable to its original value
    export SHELL=${SHELLBACK}
    
    #cleanup Xvfb stuff
    unset DISPLAY
    local xvfbpid=`head -1 ${TMPDIR}/xvfblock_${display}`
    kill ${xvfbpid} > /dev/null 2<&1
    rm "${TMPDIR}/xvfblock_${display}" 
    return ${SUCCESS}

}

# Public: publish final results of MTA
#
# Returns $SUCCESS on success and an error code otherwise
function publish_final_results_mta () {
	local pubdir="$1"
	if [ ! -d "$pubdir" ]; then
  		ciop-log "ERROR" "Final results folder for mta not found"
		return ${ERRMISSING}
	fi
	for result in `ls -1 $pubdir/*rgb.tif`; do
		ciop-publish -m ${result}
  	done
  	return ${SUCCESS}
}