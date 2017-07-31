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
    
    #create directory for processing
    unset serverdir
    export serverdir=$(procdirectory "${TMPDIR}")
    
    [ ! -e "${serverdir}" ] && {
	ciop-log "ERROR" "Cannot create directory in ${TMPDIR}"
	return $ERRPERM
    }
    
    
    import_coreg_results ${serverdir} "${wkid}" || {
	ciop-log "ERROR" "Failed to import node_coreg results"
	procCleanup
	return ${ERRGENERIC}
    }
    
    import_interf_list "${serverdir}" "${wkid}" || {
	ciop-log "ERROR" "Failed to import interf selection results"
	procCleanup
	return ${ERRGENERIC}
    }
    
    import_dem_from_node_selection ${serverdir} "${wkid}" || {
	ciop-log "ERROR" "Failed to import DEM"
	procCleanup
	return ${ERRGENERIC}
    }
    
    check_data "${serverdir}"  "${serverdir}/DAT/list_interf_auto.txt" || {
	ciop-log "ERROR" "Missing input data"
	procCleanup
	return ${ERRGENERIC}
    }
    
    #get the master image tag
    local mastertag=""
    for f in `ciop-browseresults -j node_selection -r ${wkid} | grep MASTER_SELECTION`;do
	mastertag=`hadoop dfs -cat ${f}/SM.txt`
    done

    [ -z "${mastertag}" ] && {
	ciop-log "ERROR" "Failed to get master image tag"
	procCleanup
	return ${ERRGENERIC}
    }

    #get aoi string definition
    import_aoi_def_from_node_import "${serverdir}" "${mastertag}" "${wkid}"

    ciop-log  "INFO"  "Data ready for interf generation"
    

    local mode=`ciop-getparam processing_mode`

    if [[ "$mode" == "IFG" ]]; then
	generate_ortho_interferograms "${serverdir}" "${mastertag}" || {
	ciop-log "ERROR" "Error generating interferograms"
	return ${ERRGENERIC}
    }
    else
	generate_interferograms "${serverdir}" "${mastertag}" || {
	ciop-log "ERROR" "Error generating interferograms"
	return ${ERRGENERIC}
    }

    fi

    
    
    #cleanup node_coreg node
    node_cleanup "${wkid}" "node_coreg"


    #rename processing folder
    local pubdir=${TMPDIR}/INSAR_PROCESSING

    mv "${serverdir}" "${pubdir}"
    serverdir="${pubdir}"
    
       #publish data
    ciop-publish -a -r "${pubdir}" || {
	ciop-log "ERROR" "Failed to publish folder ${pubdir}"
	return ${ERRGENERIC}
    }

    #prepare fastvel config
    #fastvelconf=$(generate_fast_vel_conf)


    if [[ "$mode" == "MTA" ]]; then
        generate_fast_vel_conf "${pubdir}"
        execute_fast_vel "${TMPDIR}" "${pubdir}"
        publish_final_results_mta "${pubdir}/output_fastvel/Final_Results"
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

