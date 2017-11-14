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

source $_CIOP_APPLICATION_PATH/node_selection/functions.sh  || {
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

    import_interf_list "${serverdir}" "${wkid}" || {
	ciop-log "ERROR" "Failed to import interf selection results"
	procCleanup
	return ${ERRGENERIC}
    }
    
    local interflist=${serverdir}/DAT/list_interf_auto.txt
    
    if [ ! -e "${interflist}" ]; then
	ciop-log "ERROR" "Failed to import interferogram list"
	procCleanup
	return ${ERRGENERIC}
    fi

    while read data;do
	local imgpair=(`echo $data`)
	
	if [ ${#imgpair[@]} -lt 2 ]; then
	    ciop-log "WARNING" "Bad line from file $interflist"
	    continue
	fi
	echo ${imgpair[0]}"@"${imgpair[1]} | ciop-publish -s
	
    done < <(cat "${interflist}")
    
    procCleanup

    return $SUCCESS
}


#set trap
trap trapFunction INT TERM

#run processing
create_lock ${_WF_ID} "node_preinterf" && {
    main || {
	procCleanup
	exit $ERRGENERIC
    }
}


procCleanup

exit $SUCCESS