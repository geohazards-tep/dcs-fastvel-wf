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
	    return ${ERRGENERIC}
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
		return ${ERRGENERIC}
	    }
	done
    done
    
    local interflistfile=${procdir}/DAT/list_interf_auto.txt
    [ ! -f "${interflistfile}" ] && {
	ciop-log "ERROR" "Failed to import interferogram list file"
	return ${ERRGENERIC}
    }

    local smselectionfile=${procdir}/DAT/SM_selection_auto.txt
    
    [ ! -f "${smselectionfile}" ] && {
	ciop-log "ERROR" "Failed to import SM selection file"
	return ${ERRGENERIC}
    }
    
    
    return ${SUCCESS}

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
	return ${ERRGENERIC}
    }
    local status=0
    for f in `hadoop dfs -lsr ${remotedemdir} | awk '{print $8}' | grep -i dem.tif`; do
	hadoop dfs -copyToLocal ${f} ${procdir}/DAT/ 
	status=$?
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Failed to import ${f}"
	    return ${ERRGENERIC}
}
	#check imported geotiff dem
	local demtif=${procdir}/DAT/dem.tif
	
	[ ! -f "${demtif}" ] && {
	    ciop-log "ERROR" "Missing DEM file"
	    return ${ERRGENERIC}
	}

	#convert to DIAP format
	tifdemimport.pl --intif="${demtif}" --outdir="${procdir}/DAT" > "${procdir}/DAT/demimport.log" 2<&1
	importst=$?
    
    if [ $importst -ne 0 ] || [ ! -e "${procdir}/DAT/dem.dat" ]; then
	ciop-log "ERROR"  "DEM conversion failed"
	#procCleanup
	return ${ERRGENERIC}
    fi
	
    done

    #import AOI
    local aoidir=${procdir}/AOI
    mkdir -p "${aoidir}"
    local remoteaoidir=`ciop-browseresults -j node_selection -r ${wkid} | grep AOI`
    
    if [ -n "${remoteaoidir}" ]; then
	for file in `hadoop dfs -lsr ${remoteaoidir} | awk '{print $8}'`; do
	    hadoop dfs -copyToLocal ${file} ${procdir}/AOI
	    status=$?
	    if [ $status -ne 0 ]; then
		ciop-log "ERROR" "Failed to import ${file}"
	    fi
	done
    fi

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


# Public: perform the interferogram generation
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
    local mlrad=`ls -tra  ${procdir}/DIF_INT/pha_cut*.rad | head -1`
    if [ -z "${mlrad}" ]; then
	mlrad=`ls -tra  ${procdir}/DIF_INT/pha_*.rad | grep ml${mlaz}${mlran} | head -1`
    fi
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
	mkdir -p "${procdir}/output_fastvel" || {
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
	#local pointreflon=`ciop-getparam ref_point_lon`
	#local pointreflat=`ciop-getparam ref_point_lat`
	local pointreflon=$(get_global_parameter  "ref_point_lon" "${_WF_ID}")
	local pointreflat=$(get_global_parameter  "ref_point_lat" "${_WF_ID}")
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

	#de-activate steps that are still w.i.p
	sed -i -e  's@\(DO_DIFF_INT_SELECTION[[:space:]]*\)\([^\n]*\)@\10@g'  ${templateprocessedfile}
	sed -i -e  's@\(DO_QC_DIFF_INTS[[:space:]]*\)\([^\n]*\)@\10@g'  ${templateprocessedfile}
	sed -i -e  's@\(DO_ORBITAL_ERRORS_COMP[[:space:]]*\)\([^\n]*\)@\10@g'  ${templateprocessedfile}
	sed -i -e  's@\(DO_ROUGH_APS_MITIGATION[[:space:]]*\)\([^\n]*\)@\10@g'  ${templateprocessedfile}
	sed -i -e  's@\(DO_PSI_LINEAR_POST_PROC[[:space:]]*\)\([^\n]*\)@\10@g'  ${templateprocessedfile}


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

	local ntifs=`ls ${pubdir}/*.tif | wc -l`
	
	if [ $ntifs -eq 0 ]; then
	    ciop-log "ERROR" "Geotiff results for mta not found"
	    return ${ERRGENERIC}
	fi

	for result in `ls -1 $pubdir/*.tif`; do
	    create_pngs_from_tif "${result}"
	    ciop-publish -m ${result}
  	done

	for result in `ls -1 $pubdir/*.legend.png`; do
	    ciop-publish -m ${result}
  	done

	for png in `find ${pubdir} -maxdepth 1  -name "*.png" -print -o -name "*.pngw" -print`; do
	    ciop-publish -m "${png}"
	done

	#publish csv
	local ncsv=`ls ${pubdir}/*.csv | wc -l`
	
	if [ $ncsv -eq 0 ]; then
	    ciop-log "ERROR" "csv results for mta not found"
	    return ${ERRGENERIC}
	fi

  	for csv in `ls -1 $pubdir/*.csv`; do
	    ciop-publish -m ${csv}
  	done

  	return ${SUCCESS}
}


# Public: perform interferogram generation
# and publish them in ortho geometry
#
# Takes a local folder and the interferogram list
# 
#
# $1 - local processing folder path
# $2 - path to interferogram list
#
# Returns $SUCCESS on success and an error code otherwise
#
function generate_ortho_interferograms()
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
	
    #multilook factors for interferograms used in orbit correction
    local ocmlaz
    local ocmlran
    
    read_multilook_factors_orbit_correction ${smtag} "${PROPERTIES_FILE}" ocmlaz ocmlran  || {
	ciop-log "ERROR" "Failed to determine orbit correction multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}
    }

    #SM geosar
    local smgeo=${procdir}/DAT/GEOSAR/${smorb}.geosar_ext
    #set some fields in the geosar
    sed -i -e 's@\(AZIMUTH DOPPLER VALUE\)\([[:space:]]*\)\([^\n]*\)@\1\20.0@g' "${smgeo}"
    sed -i -e 's@\(DEM TYPE\)\([[:space:]]*\)\([^\n]*\)@\1\2TRUE@g' "${smgeo}"
    
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
    local topleftyopt=""
    local topleftxopt=""

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
	declare -a roiarr
	roiarr=(`echo "${roi}" | sed 's@,@\n@g' | cut -f2 -d "="`)
	topleftxopt="--topleftx="${roiarr[2]}
	topleftyopt="--toplefty="${roiarr[0]}
    }
    
    local aoishape="${procdir}/AOI/AOI.shp"

    if [ ! -e "${aoishape}" ]; then
	aoishape=""
    fi

    local ortho_dem=$(get_dem_for_ortho "${procdir}/DAT/dem.tif" "${procdir}" ${_WF_ID} "${aoishape}")
    
 
    if [ -z "${ortho_dem}" ]; then
	ortho_dem="${procdir}/DAT/dem.dat"
    fi

    #psfilt factor
    local psfiltx=`ciop-getparam psfiltx`
    #unwrap option
    local unwrap=`ciop-getparam unwrap`

    #iterate over list interf
    while read data;do
	declare -a interflist
	interflist=(`echo $data`)
	
	[ ${#interflist[@]} -lt 2 ] && {
	    ciop-log "ERROR" "Invalid line ${data} from ${listinterf}"
	    continue
	}
	
	#create folder for this interferogram
	interfdir=`mktemp -d ${procdir}/DIF_INT_XXXXX`
	
	if [ -z "${interfdir}" ]; then
	    continue
	fi

	#TO-DO read ML and under from properties
	local mastergeo=${procdir}/DAT/GEOSAR/${interflist[0]}.geosar_ext
	local slavegeo=${procdir}/DAT/GEOSAR/${interflist[1]}.geosar_ext
	local masterci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[0]}_${smorb}.ci2
	local slaveci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[1]}_${smorb}.ci2
	demdesc="${procdir}/DAT/dem.dat"
	master=${interflist[0]}
	slave=${interflist[1]}

	interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=1 --mlran=1  --winazi=${mlaz} --winran=${mlran}  --demdesc=${procdir}/DAT/dem.dat --coh --amp --dir="${interfdir}" --outdir="${interfdir}" --tmpdir=${procdir}/TEMP  --orthodir="${interfdir}" --nobort --noran --noinc --psfilt --psfiltx=${psfiltx} ${roiopt}  > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}.log 2<&1
	local status=$?
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Generation of interferogram ${interflist[0]} - ${interflist[1]} Failed"
	    continue
	}
	
	find ${procdir}/ORB -iname "*${interflist[0]}*.orb" -print -o -iname "*${interflist[1]}*.orb" -print | alt_ambig.pl --geosar=${smgeo}  -o ${interfdir}/AMBIG.DAT > /dev/null 2<&1

	#ortho of the phase
	ortho.pl --geosar=${smgeo} --in="${interfdir}/psfilt_pha_${master}_${slave}_ml11.rad" --demdesc="${ortho_dem}" --cplx  --tag="${master}_${slave}_ml11" --odir="${interfdir}" --tmpdir=${procdir}/TEMP ${topleftxopt} ${topleftyopt}    #>> "${procdir}"/log/pha_ortho_${master}_${slave}.log 2<&1
	#ortho of the coherence
	ortho.pl --geosar=${smgeo} --in="${interfdir}/coh_${master}_${slave}_ml11.rad" --demdesc="${ortho_dem}" --tag="coh_${master}_${slave}_ml11" --odir="${interfdir}" --tmpdir=${procdir}/TEMP ${topleftxopt} ${topleftyopt}  #>> "${procdir}"/log/coh_ortho_${master}_${slave}.log 2<&1
	#ortho of the amplitude
	ortho.pl --geosar=${smgeo} --in="${interfdir}/amp_${master}_${slave}_ml11.rad" --demdesc="${ortho_dem}" --tag="amp_${master}_${slave}_ml11" --odir="${interfdir}" --tmpdir=${procdir}/TEMP ${topleftxopt} ${topleftyopt}  >> "${procdir}"/log/amp_ortho_${master}_${slave}.log 2<&1

	#create geotiff
	ortho2geotiff.pl --ortho="${interfdir}/pha_${master}_${slave}_ml11_ortho.pha"  --mask --alpha="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --colortbl=BLUE-RED  --demdesc="${ortho_dem}" --outfile="${interfdir}/pha_${master}_${slave}_ortho_rgb.tiff"  --tmpdir=${procdir}/TEMP  >> ${procdir}/log/pha_ortho_${master}_${slave}.log 2<&1
	ortho2geotiff.pl --ortho="${interfdir}/pha_${master}_${slave}_ml11_ortho.pha"  --mask --alpha="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --colortbl=BLACK-WHITE  --demdesc="${ortho_dem}" --outfile="${interfdir}/pha_${master}_${slave}_ortho.tiff"  --tmpdir=${procdir}/TEMP  >> ${procdir}/log/pha_ortho_${master}_${slave}.log 2<&1
	ortho2geotiff.pl --ortho="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --demdesc="${ortho_dem}"  --colortbl=BLACK-WHITE --mask   --outfile="${interfdir}/amp_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/amp_ortho_${master}_${slave}.log 2<&1
	ortho2geotiff.pl --ortho="${interfdir}/coh_${master}_${slave}_ml11_ortho.rad" --demdesc="${ortho_dem}" --outfile="${interfdir}/coh_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/coh_ortho_${master}_${slave}.log 2<&1
	ln -s ${procdir}/log/amp_ortho_${master}_${slave}.log ${interfdir}/ortho_amp.log
	if [ ! -e "${interfdir}/pha_${master}_${slave}_ml11_ortho.pha" ]; then
	    ciop-log "ERROR" "Failed to generate ortho interferogram"
	    msg=`cat "${procdir}"/log/pha_ortho_${master}_${slave}.log`
	    ciop-log "INFO" "${msg}"
	fi
	
	#unwrap
	local unwmlaz=` echo "${mlaz}*2" | bc -l`
	local unwmlran=` echo "${mlran}*2" | bc -l`
	if [[ "$unwrap" == "true" ]]; then
	    interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${unwmlaz} --mlran=${unwmlran}    --demdesc=${procdir}/DAT/dem.dat --coh --amp --dir="${interfdir}" --outdir="${interfdir}" --tmpdir=${procdir}/TEMP  --orthodir="${interfdir}" --bort --noran --noinc --psfilt --psfiltx=${psfiltx} ${roiopt}   > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_unw.log 2<&1
	    
	    local inunw="${interfdir}"/psfilt_pha_${master}_${slave}_ml${unwmlaz}${unwmlran}.pha
	    local incoh="${interfdir}"/coh_${master}_${slave}_ml${unwmlaz}${unwmlran}.byt
	    local outunw="${interfdir}"/unw_${master}_${slave}_ml${unwmlaz}${unwmlran}.byt
	    
	    local templatefile="/opt/diapason/gep.dir/snaphu_template.txt"
	    local pathbackup=$PATH
	    export PATH=$PATH:"/opt/diapason/gep.dir/"
	    
	    runwrap.pl --geosar=${smgeo}  --phase="${inunw}" --coh="${incoh}"  --template="${templatefile}" --mlaz=${unwmlaz} --mlran=${unwmlran} --outfile=${outunw} --tmpdir=${procdir}/TEMP   >> ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_unw.log 2<&1
	    
	    #cat ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_unw.log
	
	    if [ -e "${outunw}" ]; then
		ortho.pl --real --geosar=${smgeo} --in="${outunw}" --demdesc="${ortho_dem}" --tag="unw_${master}_${slave}" --mlaz=${unwmlaz} --mlran=${unwmlran}  --odir="${interfdir}" --tmpdir=${procdir}/TEMP ${topleftxopt} ${topleftyopt}  >> "${procdir}"/log/unw_ortho_${master}_${slave}.log 2<&1
		
		local orthounw="${interfdir}/unw_${master}_${slave}_ortho.r4"
		
		if [ ! -e "${orthounw}" ]; then
		    cat "${procdir}"/log/unw_ortho_${master}_${slave}.log
		fi

		if [ ! -e "${orthounw}" ]; then
		    cat "${procdir}"/log/unw_ortho_${master}_${slave}.log
		fi
		
		ortho2geotiff.pl --ortho="${orthounw}" --demdesc="${ortho_dem}" --outfile="${interfdir}/unw_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/unw_ortho_${master}_${slave}.log 2<&1
		
		

	    fi

	    export PATH="${pathbackup}"
	fi

	
	#create_pngs_from_tif "${result}"
	for f in `find ${interfdir} -name "*.tiff"`; do 
	    create_pngs_from_tif "${f}"
	done

	rm "${interfdir}/amp_${master}_${slave}_ortho.tiff"

	ortho2geotiff.pl --ortho="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --demdesc="${ortho_dem}"  --outfile="${interfdir}/amp_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/amp_ortho_${master}_${slave}.log 2<&1
	
	wkt=$(tiff2wkt "${interfdir}/coh_${master}_${slave}_ortho.tiff")
	echo ${wkt} > ${interfdir}/wkt.txt

	create_interf_properties "${interfdir}/coh_${master}_${slave}_ortho.tiff" "Interferometric Coherence" "${interfdir}" "${mastergeo}" "${slavegeo}"
	create_interf_properties "${interfdir}/coh_${master}_${slave}_ortho.png" "Interferometric Coherence - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"
	create_interf_properties "${interfdir}/amp_${master}_${slave}_ortho.tiff" "Interferometric Amplitude" "${interfdir}" "${mastergeo}" "${slavegeo}"
	create_interf_properties "${interfdir}/amp_${master}_${slave}_ortho.png" "Interferometric Amplitude - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"
	create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho.tiff" "Interferometric Phase" "${interfdir}" "${mastergeo}" "${slavegeo}"
	#create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho.png" "Interferometric Phase - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"
	#create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho_rgb.tiff" "Interferometric Phase" "${interfdir}" "${mastergeo}" "${slavegeo}"
	create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho_rgb.png" "Interferometric Phase - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"	
	
	rm "${interfdir}/pha_${master}_${slave}_ortho.png"
	rm "${interfdir}/pha_${master}_${slave}_ortho_rgb.tiff"

	#
	if [[ "$unwrap" == "true" ]]; then
	    #"
	    create_interf_properties "${interfdir}/unw_${master}_${slave}_ortho.tiff" "Unwrapped Phase" "${interfdir}" "${mastergeo}" "${slavegeo}"
	    rm -f "${interfdir}/unw_${master}_${slave}_ortho.png"
	fi

	 for f in `find "${interfdir}" -iname "*.png" -print -o -iname "*.properties" -print -o -iname "*.tiff" -print`;do
	    ciop-publish -m "$f"
	done

	ciop-log "INFO" "Generation of interferogram ${interflist[0]} - ${interflist[1]} successful"
	rm -rf "${interfdir}" > /dev/null 2<&1
	
    done < <(cat ${listinterf} | awk '{print $1" "$2}')

    

    

    return ${SUCCESS}
}

function get_dem_for_ortho()
{
 
    if  [ $# -lt 3 ]; then
	return $ERRMISSING
    fi
    
    
    local indemtif="$1"
    local serverdir="$2"
    local wkid="$3"
    local shapefile=""

    if [ $# -ge 4 ]; then
	shapefile="$4"
    fi

    local dir=${serverdir}/DEM_FOR_ORTHO/

    mkdir -p ${dir} || {
	echo "" 
	return $ERRPERM
    }

    if [ -n "${shapefile}" ] && [ -e "${shapefile}" ] && [ -e "/opt/gdalcrop/bin/gdalcrop" ]; then
	local cropped=${dir}/dem_cropped.tif
	ciop-log "INFO" "Cropping DEM using AOI ${shapefile}"
	/opt/gdalcrop/bin/gdalcrop "${indemtif}" "${shapefile}" "${cropped}" > /dev/null 2<&1
	local statuscrop=$?
	if [ $statuscrop -eq 0 ] || [ -e "${cropped}" ]; then
	    ciop-log "INFO" "DEM was successfully cropped"
	    indemtif=${cropped}
	else
	    ciop-log "WARN" "DEM cropping failed"
	    /opt/gdalcrop/bin/gdalcrop "${indemtif}" "${shapefile}" "${cropped}" 2>&1
	fi
    fi


    local mode=$(get_global_parameter "processing_mode" "${wkid}") || {
	ciop-log "WARNING" "Global parameter \"processing_mode\" not found. Defaulting to \"MTA\""
    }
    
    if [ "$mode" == "IFG" ]; then
	local tifout=${dir}/dem_for_ortho.tif
	
	if [ -z "${PROPERTIES_FILE}" ]; then
	    return $ERRMISSING
	fi
	
	local pixelSpacingX=""
	local pixelSpacingY=""

	read_ortho_pixel_spacing "${PROPERTIES_FILE}" XpixelSpacing YpixelSpacing || {
	    return $ERRMISSING
	}
	gdalwarp -tr ${XpixelSpacing} ${YpixelSpacing}  -ot Int16 -r bilinear ${indemtif} ${tifout} > /dev/null 2<&1
	
	if [ -e "${tifout}" ]; then
	    tifdemimport.pl --intif="${tifout}" --outdir="${dir}" > "${serverdir}/orthodemimport.log" 2<&1
	    if [ -e "${dir}/dem.dat" ]; then
		echo "${dir}/dem.dat"
		return $SUCCESS
	    fi
	else
	    echo ""
	    return $ERRGENRIC
	fi
    else
	echo "${serverdir}/DAT/dem.dat"
	return $SUCCESS
    fi


    return $SUCCESS
    
}


# Public: import geosar and orbital files from node_coreg
#
# Takes a local folder and the workflow id as arguments
# 
# The function will copy to the local folder for each image
# the geosar ,orb
#
# $1 - local processing folder path
# $2 - workflow id
#
#
# Returns 0 on success and 1 on error
#   

function import_geosar()
{
    if [ $# -lt 2 ]; then
        ciop-log "ERROR" "Usage: $FUNCTION localdir run_id"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local runid="$2"

    for x in `ciop-browseresults -j node_coreg -r ${runid}`;do
	for d in `hadoop dfs -lsr ${x} | awk '{print $8}' | grep "DAT/GEOSAR/\|ORB/"`;do
	    local exten=${d##*.}
	local status=0
	case "${exten}" in
	    orb)hadoop dfs -copyToLocal ${d} ${procdir}/ORB/
		status=$?
		;;
	    *geosar*)hadoop dfs -copyToLocal ${d} ${procdir}/DAT/GEOSAR/
		status=$?
		;;
	esac
	
	
	[ $status -ne 0 ] && {
	    ciop-log "ERROR" "Failed to import file ${d}"
	    return ${ERRGENERIC}
	}
	echo "INFO" "Imported ${d}"
	done
	
    done

    find ${procdir} -name "*.geosar*"  -exec geosarfixpath.pl --geosar='{}' --serverdir=${procdir} \; > /dev/null 2<&1
    
    return ${SUCCESS}
}



# Public: import geo ci2 images from node_coreg
#
# Takes a local folder and the workflow id as arguments
# 
# The function will copy to the local folder for each image
# the geosar ,orb
#
# $1 - local processing folder path
# $2 - workflow id
#
#
# Returns 0 on success and 1 on error
#   

function import_geo_image()
{
    if [ $# -lt 3 ]; then
	return 255
    fi

    local serverdir=$1
    local wkid=$2
    local orbnum=$3
    local timeoutsec=10
    local retries=50

    if [ -z "`type -p lockfile`" ]; then
	ciop-log "ERROR" "Missing lockfile utility"
	return ${ERRMISSING}
    fi

    local lockfile="${serverdir}/TEMP/${orbnum}.lock"

    if lockfile -r ${retries} -${timeoutsec} ${lockfile}  ; then
	local geo_count=`find ${serverdir}/GEO_CI2_EXT_LIN/ -iname "geo_${orbnum}_*.*" -print | wc -l`
	if [ $geo_count -eq 0 ]; then
	    for x in `ciop-browseresults -j node_coreg -r ${wkid}`;do
		for d in `hadoop dfs -lsr ${x} | awk '{print $8}' | grep "geo_${orbnum}_*.*"`;do
		    echo "copying $d"
		    hadoop dfs -copyToLocal ${d} ${serverdir}/GEO_CI2_EXT_LIN
		done
	    done
	else
	    echo "geo image ${orbnum} already copied"
	fi
	rm -f ${lockfile}
    else
	echo "Cannot acquire lock file for orb ${orbnum}"
	return ${ERRGENERIC}
    fi

    return ${SUCCESS}
}



# Public: perform the interferogram generation
#
# Takes a local folder and the interferogram list
# 
#
# $1 - local processing folder path
# $2 - master image tag
# $3 - master image orbnum
# $4 - slave image orbnum
#
# Returns $SUCCESS on success and an error code otherwise
#
function generate_interferogram()
{
    if [ $# -lt 3 ]; then
	ciop-log "ERROR" "Missing argument procdir"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local smtag="$2"
    local master=$3
    local slave=$4

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
    
    #aoi
    local aoifile="${procdir}/DAT/aoi.txt"
    local aoidef=`grep "[0-9]" ${aoifile} | head -1`
    local roi=""
    local roiopt=""
    
    if [ -e "${aoifile}" ] && [ -n "$aoidef" ] ; then
	roi=$(geosar_get_aoi_coords2 "${smgeo}" "${aoidef}" "${procdir}/DAT/dem.dat"  "${procdir}/log/" )
	local roist=$?
	echo "INFO" "geosar_get_aoi_coords status ${roist}"
    else
	echo "INFO" "Missing file ${aoifile}"
	echo "INFO" "aoi defn ${aoidef}"
    fi

    echo "INFO" "aoi roi defn : ${roi}"
    [ -n "${roi}" ] && {
    	roiopt="--roi=${roi}"
    }
    
    #iterate over list interf
    declare -a interflist
    interflist=(`echo "$master $slave"`)
    
    
    
	#TO-DO read ML and under from properties
    local mastergeo=${procdir}/DAT/GEOSAR/${interflist[0]}.geosar_ext
    local slavegeo=${procdir}/DAT/GEOSAR/${interflist[1]}.geosar_ext
    local masterci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[0]}_${smorb}.ci2
    local slaveci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[1]}_${smorb}.ci2
 
    #create folder for interfeogram
    interfdir=`mktemp -d ${procdir}/TEMP/interf_${master}_${slave}_XXXXXX`
    if [ -z "$interfdir" ]; then
	echo "cannot create folder in ${procdir}/TEMP"
	return ${ERRPERM}
    fi
   
    cp ${mastergeo} ${interfdir}
    cp ${slavegeo} ${interfdir}
    cp ${procdir}/ORB/${interflist[0]}.orb ${interfdir}
    cp ${procdir}/ORB/${interflist[1]}.orb ${interfdir}
    

    interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${mlaz} --mlran=${mlran} --aziunder=${azunder} --ranunder=${rnunder} --demdesc=${procdir}/DAT/dem.dat --coh --bort --inc --ran --dir=${interfdir} --outdir=${interfdir} --tmpdir=${procdir}/TEMP "${roiopt}"  > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}.log 2<&1
    local status=$?
    [ $status -ne 0 ] && {
	ciop-log "ERROR" "Generation of interferogram ${interflist[0]} - ${interflist[1]} Failed"
	rm -rf "${interfdir}"
	return ${ERRMISSING}
    }
    
    interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${ocmlaz} --mlran=${ocmlran} --aziunder=${azunder} --ranunder=${rnunder} --demdesc=${procdir}/DAT/dem.dat --coh  --dir=${interfdir} --outdir=${interfdir} --tmpdir=${procdir}/TEMP --nobort --noinc --noran   > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_ml${ocmlaz}${ocmlran}.log 2<&1
    
    
    echo "INFO" "Generation of interferogram ${interflist[0]} - ${interflist[1]} successful"
    
    ciop-publish -a -r "${interfdir}" || {
	ciop-log "ERROR" "Failed to publish interferogram folder for pair "${interflist[0]}" " ${interflist[1]}
	rm -rf "${interfdir}"
	return ${ERRGENERIC}
    }
    
    rm -rf "${interfdir}"


    return ${SUCCESS}
}




# Public: perform interferogram generation
# and publish them in ortho geometry
#
# Takes a local folder and the interferogram list
# 
#
# $1 - local processing folder path
# $2 - path to interferogram list
#
# Returns $SUCCESS on success and an error code otherwise
#
function generate_ortho_interferogram()
{
    if [ $# -lt 4 ]; then
	ciop-log "ERROR" "Missing argument procdir"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local smtag="$2"
    local master=$3
    local slave=$4


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
	
    #multilook factors for interferograms used in orbit correction
    local ocmlaz
    local ocmlran
    
    read_multilook_factors_orbit_correction ${smtag} "${PROPERTIES_FILE}" ocmlaz ocmlran  || {
	ciop-log "ERROR" "Failed to determine orbit correction multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}
    }

    #SM geosar
    local smgeo=${procdir}/DAT/GEOSAR/${smorb}.geosar_ext
    #set some fields in the geosar
    sed -i -e 's@\(AZIMUTH DOPPLER VALUE\)\([[:space:]]*\)\([^\n]*\)@\1\20.0@g' "${smgeo}"
    sed -i -e 's@\(DEM TYPE\)\([[:space:]]*\)\([^\n]*\)@\1\2TRUE@g' "${smgeo}"
    
    #set lat/long corner
    setlatlongeosar.pl --geosar=${smgeo} --tmpdir=${procdir}/TEMP > /dev/null 2<&1

    #aoi
    local aoifile="${procdir}/DAT/aoi.txt"
    local aoidef=`grep "[0-9]" ${aoifile} | head -1`
    local roi=""
    local roiopt=""
    local topleftyopt=""
    local topleftxopt=""
    local tag=""

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
	declare -a roiarr
	roiarr=(`echo "${roi}" | sed 's@,@\n@g' | cut -f2 -d "="`)
	topleftxopt="--topleftx="${roiarr[2]}
	topleftyopt="--toplefty="${roiarr[0]}
	tag="_cut"
    }
    
    local aoishape="${procdir}/AOI/AOI.shp"

    if [ ! -e "${aoishape}" ]; then
	aoishape=""
    fi

    local ortho_dem=$(get_dem_for_ortho "${procdir}/DAT/dem.tif" "${procdir}" ${_WF_ID} "${aoishape}")
    
 
    if [ -z "${ortho_dem}" ]; then
	ortho_dem="${procdir}/DAT/dem.dat"
    fi

    #psfilt factor
    local psfiltx=`ciop-getparam psfiltx`
    #unwrap option
    local unwrap=`ciop-getparam unwrap`

    #iterate over list interf
    declare -a interflist
    interflist=(`echo "$master $slave"`)

    
    [ ${#interflist[@]} -lt 2 ] && {
	ciop-log "ERROR" "Invalid line ${data} from ${listinterf}"
	continue
    }
    
	#create folder for this interferogram
    interfdir=`mktemp -d ${procdir}/DIF_INT_XXXXX`
    
    if [ -z "${interfdir}" ]; then
	continue
    fi
    
	#TO-DO read ML and under from properties
    local mastergeo=${procdir}/DAT/GEOSAR/${interflist[0]}.geosar_ext
    local slavegeo=${procdir}/DAT/GEOSAR/${interflist[1]}.geosar_ext
    local masterci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[0]}_${smorb}.ci2
    local slaveci2=${procdir}/GEO_CI2_EXT_LIN/geo_${interflist[1]}_${smorb}.ci2
    demdesc="${procdir}/DAT/dem.dat"
    master=${interflist[0]}
    slave=${interflist[1]}
    
    interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=1 --mlran=1  --winazi=${mlaz} --winran=${mlran}  --demdesc=${procdir}/DAT/dem.dat --coh --amp --dir="${interfdir}" --outdir="${interfdir}" --tmpdir=${procdir}/TEMP  --orthodir="${interfdir}" --nobort --noran --noinc --psfilt --psfiltx=${psfiltx} "${roiopt}"  > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}.log 2<&1
    local status=$?
    [ $status -ne 0 ] && {
	ciop-log "ERROR" "Generation of interferogram ${interflist[0]} - ${interflist[1]} Failed"
	continue
    }
    
    find ${procdir}/ORB -iname "*${interflist[0]}*.orb" -print -o -iname "*${interflist[1]}*.orb" -print | alt_ambig.pl --geosar=${smgeo}  -o ${interfdir}/AMBIG.DAT > /dev/null 2<&1
    
	#ortho of the phase
    ortho.pl --geosar=${smgeo} --in="${interfdir}/psfilt_pha${tag}_${master}_${slave}_ml11.rad" --demdesc="${ortho_dem}" --cplx  --tag="${master}_${slave}_ml11" --odir="${interfdir}" --tmpdir=${procdir}/TEMP "${topleftxopt}" "${topleftyopt}"   >> "${procdir}"/log/pha_ortho_${master}_${slave}.log 2<&1
	#ortho of the coherence
    ortho.pl --geosar=${smgeo} --in="${interfdir}/coh${tag}_${master}_${slave}_ml11.rad" --demdesc="${ortho_dem}" --tag="coh_${master}_${slave}_ml11" --odir="${interfdir}" --tmpdir=${procdir}/TEMP "${topleftxopt}" "${topleftyopt}"  >> "${procdir}"/log/coh_ortho_${master}_${slave}.log 2<&1
	#ortho of the amplitude
    ortho.pl --geosar=${smgeo} --in="${interfdir}/amp${tag}_${master}_${slave}_ml11.rad" --demdesc="${ortho_dem}" --tag="amp_${master}_${slave}_ml11" --odir="${interfdir}" --tmpdir=${procdir}/TEMP "${topleftxopt}" "${topleftyopt}"  >> "${procdir}"/log/amp_ortho_${master}_${slave}.log 2<&1

	#create geotiff
    ortho2geotiff.pl --ortho="${interfdir}/pha_${master}_${slave}_ml11_ortho.pha"  --mask --alpha="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --colortbl=BLUE-RED  --demdesc="${ortho_dem}" --outfile="${interfdir}/pha_${master}_${slave}_ortho_rgb.tiff"  --tmpdir=${procdir}/TEMP  >> ${procdir}/log/pha_ortho_${master}_${slave}.log 2<&1
    ortho2geotiff.pl --ortho="${interfdir}/pha_${master}_${slave}_ml11_ortho.pha"  --mask --alpha="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --colortbl=BLACK-WHITE  --demdesc="${ortho_dem}" --outfile="${interfdir}/pha_${master}_${slave}_ortho.tiff"  --tmpdir=${procdir}/TEMP  >> ${procdir}/log/pha_ortho_${master}_${slave}.log 2<&1
    ortho2geotiff.pl --ortho="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --demdesc="${ortho_dem}"  --colortbl=BLACK-WHITE --mask   --outfile="${interfdir}/amp_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/amp_ortho_${master}_${slave}.log 2<&1
    ortho2geotiff.pl --ortho="${interfdir}/coh_${master}_${slave}_ml11_ortho.rad" --demdesc="${ortho_dem}" --outfile="${interfdir}/coh_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/coh_ortho_${master}_${slave}.log 2<&1
    ln -s ${procdir}/log/amp_ortho_${master}_${slave}.log ${interfdir}/ortho_amp.log
    if [ ! -e "${interfdir}/pha_${master}_${slave}_ml11_ortho.pha" ]; then
	ciop-log "ERROR" "Failed to generate ortho interferogram"
	msg=`cat "${procdir}"/log/pha_ortho_${master}_${slave}.log`
	ciop-log "INFO" "${msg}"
    fi
    
	#unwrap
    local unwmlaz=` echo "${mlaz}*2" | bc -l`
    local unwmlran=` echo "${mlran}*2" | bc -l`
    if [[ "$unwrap" == "true" ]]; then
	interf_sar.pl --prog=interf_sar_SM --sm=${smgeo} --master=${mastergeo} --slave=${slavegeo} --ci2master=${masterci2} --ci2slave=${slaveci2} --mlaz=${unwmlaz} --mlran=${unwmlran}    --demdesc=${procdir}/DAT/dem.dat --coh --amp --dir="${interfdir}" --outdir="${interfdir}" --tmpdir=${procdir}/TEMP  --orthodir="${interfdir}" --bort --noran --noinc --psfilt --psfiltx=${psfiltx} "${roiopt}"   > ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_unw.log 2<&1
	
	local inunw="${interfdir}"/psfilt_pha${tag}_${master}_${slave}_ml${unwmlaz}${unwmlran}.pha
	local incoh="${interfdir}"/coh${tag}_${master}_${slave}_ml${unwmlaz}${unwmlran}.byt
	local outunw="${interfdir}"/unw_${master}_${slave}_ml${unwmlaz}${unwmlran}.byt
	
	local templatefile="/opt/diapason/gep.dir/snaphu_template.txt"
	local pathbackup=$PATH
	export PATH=$PATH:"/opt/diapason/gep.dir/"
	
	runwrap.pl --geosar=${smgeo}  --phase="${inunw}" --coh="${incoh}"  --template="${templatefile}" --mlaz=${unwmlaz} --mlran=${unwmlran} --outfile=${outunw} --tmpdir=${procdir}/TEMP   >> ${procdir}/log/interf_${interflist[0]}_${interflist[1]}_unw.log 2<&1
	
	
	if [ -e "${outunw}" ]; then
	    ortho.pl --real --geosar=${smgeo} --in="${outunw}" --demdesc="${ortho_dem}" --tag="unw_${master}_${slave}" --mlaz=${unwmlaz} --mlran=${unwmlran}  --odir="${interfdir}" --tmpdir=${procdir}/TEMP  "${topleftxopt}" "${topleftyopt}" >> "${procdir}"/log/unw_ortho_${master}_${slave}.log 2<&1
	    
	    local orthounw="${interfdir}/unw_${master}_${slave}_ortho.r4"
	    
	    if [ ! -e "${orthounw}" ]; then
		cat "${procdir}"/log/unw_ortho_${master}_${slave}.log
	    fi
	    
	    if [ ! -e "${orthounw}" ]; then
		cat "${procdir}"/log/unw_ortho_${master}_${slave}.log
	    fi
	    
	    ortho2geotiff.pl --ortho="${orthounw}" --demdesc="${ortho_dem}" --outfile="${interfdir}/unw_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/unw_ortho_${master}_${slave}.log 2<&1
	    
	    
	    
	    fi
	
	export PATH="${pathbackup}"
    fi
    
    
	#create_pngs_from_tif "${result}"
    for f in `find ${interfdir} -name "*.tiff"`; do 
	create_pngs_from_tif "${f}"
    done

    rm "${interfdir}/amp_${master}_${slave}_ortho.tiff"
    
    ortho2geotiff.pl --ortho="${interfdir}/amp_${master}_${slave}_ml11_ortho.r4" --demdesc="${ortho_dem}"  --outfile="${interfdir}/amp_${master}_${slave}_ortho.tiff" --tmpdir=${procdir}/TEMP  >> ${procdir}/log/amp_ortho_${master}_${slave}.log 2<&1
    
    wkt=$(tiff2wkt "${interfdir}/coh_${master}_${slave}_ortho.tiff")
    echo ${wkt} > ${interfdir}/wkt.txt
    
    create_interf_properties "${interfdir}/coh_${master}_${slave}_ortho.tiff" "Interferometric Coherence" "${interfdir}" "${mastergeo}" "${slavegeo}"
    create_interf_properties "${interfdir}/coh_${master}_${slave}_ortho.png" "Interferometric Coherence - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"
    create_interf_properties "${interfdir}/amp_${master}_${slave}_ortho.tiff" "Interferometric Amplitude" "${interfdir}" "${mastergeo}" "${slavegeo}"
    create_interf_properties "${interfdir}/amp_${master}_${slave}_ortho.png" "Interferometric Amplitude - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"
    create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho.tiff" "Interferometric Phase" "${interfdir}" "${mastergeo}" "${slavegeo}"
	#create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho.png" "Interferometric Phase - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"
	#create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho_rgb.tiff" "Interferometric Phase" "${interfdir}" "${mastergeo}" "${slavegeo}"
    create_interf_properties "${interfdir}/pha_${master}_${slave}_ortho_rgb.png" "Interferometric Phase - Preview" "${interfdir}" "${mastergeo}" "${slavegeo}"	
    
    rm "${interfdir}/pha_${master}_${slave}_ortho.png"
    rm "${interfdir}/pha_${master}_${slave}_ortho_rgb.tiff"
    
	#
    if [[ "$unwrap" == "true" ]]; then
	    #"
	create_interf_properties "${interfdir}/unw_${master}_${slave}_ortho.tiff" "Unwrapped Phase" "${interfdir}" "${mastergeo}" "${slavegeo}"
	rm -f "${interfdir}/unw_${master}_${slave}_ortho.png"
    fi
    
    for f in `find "${interfdir}" -iname "*.png" -print -o -iname "*.properties" -print -o -iname "*.tiff" -print`;do
	ciop-publish -m "$f"
    done
    
    ciop-log "INFO" "Generation of interferogram ${interflist[0]} - ${interflist[1]} successful"
    rm -rf "${interfdir}" > /dev/null 2<&1
    
    return ${SUCCESS}
}
