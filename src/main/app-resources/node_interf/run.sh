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
    
    ciop-log  "INFO"  "Data ready for interf generation"
    generate_interferograms "${serverdir}" "${mastertag}" || {
	ciop-log "ERROR" "Error generating interferograms"
	return ${ERRGENERIC}
    }

    #cleanup data

    ######################
    # 
    ######################
    cp -r ${serverdir}/DIF_INT /tmp
    chmod -R 777 /tmp/DIF_INT

    return ${SUCCESS}
}

#run processing
main


procCleanup

