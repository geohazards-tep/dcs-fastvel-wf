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

source $_CIOP_APPLICATION_PATH/node_fastvel/functions.sh  || {
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


#main
function main()
{
    local wkid=${_WF_ID}

    #
    local publish_intermediate_flag=`ciop-getparam publish_intermediate`

    if [[ "${publish_intermediate_flag}" != "true"  ]]; then
        #cleanup node_coreg node
	node_cleanup "${wkid}" "node_coreg"
    fi

    local mode=$(get_global_parameter "processing_mode" "${wkid}") || {
	ciop-log "WARNING" "Global parameter \"processing_mode\" not found. Defaulting to \"MTA\""
    }
    
    if [[ "$mode" == "IFG" ]]; then
	return ${SUCCESS}
    fi

    
    #create directory for processing
    unset serverdir
    export serverdir=$(procdirectory "${TMPDIR}")
    
    [ ! -e "${serverdir}" ] && {
	ciop-log "ERROR" "Cannot create directory in ${TMPDIR}"
	return $ERRPERM
    }
    
    import_dem_from_node_selection ${serverdir} "${wkid}" || {
	ciop-log "ERROR" "Failed to import DEM"
	procCleanup
	return ${ERRGENERIC}
    }
    
    import_interfs ${serverdir} "${wkid}" || {
	ciop-log "ERROR" "Failed to import DEM"
	procCleanup
	return ${ERRGENERIC}
    }
    
    
    import_interf_list "${serverdir}" "${wkid}" || {
	ciop-log "ERROR" "Failed to import interf selection results"
	procCleanup
	return ${ERRGENERIC}
    }
    
    
    #get the master image tag
    local mastertag=`cat ${serverdir}/DAT/SM.txt`
 #   for f in `ciop-browseresults -j node_selection -r ${wkid} | grep MASTER_SELECTION`;do
#	mastertag=`hadoop dfs -cat ${f}/SM.txt`
    #done

    [ -z "${mastertag}" ] && {
	ciop-log "ERROR" "Failed to get master image tag"
	procCleanup
	return ${ERRGENERIC}
    }

    #get aoi string definition
    import_aoi_def_from_node_import "${serverdir}" "${mastertag}" "${wkid}"

    ciop-log "INFO" "Generating Prep Fastvel"

    fastvel_pre "${serverdir}" "${mastertag}"  || {
    ciop-log "ERROR" "Failed to prep fastvel"
    procCleanup
    return ${ERRGENERIC}
}


    #rename processing folder
    local pubdir=${TMPDIR}/INSAR_PROCESSING

    mv "${serverdir}" "${pubdir}"
    serverdir="${pubdir}"

    
    if [[ "${publish_intermediate_flag}" != "true"  ]]; then
	node_cleanup "${wkid}" "node_interf"
    fi

    #prepare fastvel config
    #fastvelconf=$(generate_fast_vel_conf)


    if [[ "$mode" == "MTA" ]]; then
        generate_fast_vel_conf "${pubdir}"
        execute_fast_vel "${TMPDIR}" "${pubdir}"
        fvelconf="${pubdir}/DAT/fastvel.conf"

        orbitdir=$(get_conf_parameter "${fvelconf}" "SATELLITE_PASS")
        incid=$(get_conf_parameter "${fvelconf}" "INCIDENCE_ANGLE")
        sensor=$(get_conf_parameter "${fvelconf}" "SENSOR_NAME")

        velfile=$(ls -1 ${pubdir}/output_fastvel/Final_Results/*Vel.tif)
        velrgbfile=$(ls -1 ${pubdir}/output_fastvel/Final_Results/*Vel.rgb.tif)


        create_fastvel_properties "${velfile}" "Velocity map (cm/year)" "${orbitdir}" "${incid}" "${sensor}"
        create_fastvel_properties "${velrgbfile}" "Velocity map (cm/year)" "${orbitdir}" "${incid}" "${sensor}"

        erhfile=$(ls -1 ${pubdir}/output_fastvel/Final_Results/*Erh.tif)
        erhrgbfile=$(ls -1 ${pubdir}/output_fastvel/Final_Results/*Erh.tif)

        create_fastvel_properties "${erhfile}" "Topography map (meters)" "${orbitdir}" "${incid}" "${sensor}"
        create_fastvel_properties "${erhrgbfile}" "Topography map (meters)" "${orbitdir}" "${incid}" "${sensor}"

        publish_final_results_mta "${pubdir}/output_fastvel/Final_Results"
	local fvel_status=$?
	if [ ${fvel_status} -ne 0 ]; then
	    ciop-log "ERROR" "fastvel execution failed"
	    ciop-publish -r "${pubdir}/output_fastvel"
	    return ${fvel_status}
	fi
    fi
 
    return ${SUCCESS}
}

#set trap
trap trapFunction INT TERM

#run processing
main || {
    procCleanup
    exit $ERRGENERIC
}


procCleanup

