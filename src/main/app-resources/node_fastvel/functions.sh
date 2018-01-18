#!/bin/bash

# Public: Import interferogram files published
# from node_interf that are needed for fastvel
# 
# The function takes as arguments the local 
# folder where the files should be imported,
# and the workflow id 
#
# $1 - local folder for data import
# $2 - workflow id
#
# Examples
#
#   import_interfs "${serverdir}" "${wkid}"
#
# Returns $SUCCESS on success 
#   
function import_interfs()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "Usage:$FUNCTION locadir run_id"
	return ${ERRMISSING}
    fi

    local procdir="$1"
    local runid="$2"
    
    
    for x in `ciop-browseresults -j node_interf -r ${runid}`;do
	for d in `hadoop dfs -lsr ${x} | awk '{print $8}' `;do
	    local exten=${d##*.}
	#echo "${d} - ${exten}"
	    local status=0
	    case "${exten}" in
		orb) [ ! -e "${procdir}/ORB/`basename $d`" ] && { hadoop dfs -copyToLocal ${d} ${procdir}/ORB/
		    status=$?
}
		    ;;
		*geosar*)[ ! -e "${procdir}/DAT/GEOSAR/`basename $d`" ] && { hadoop dfs -copyToLocal ${d} ${procdir}/DAT/GEOSAR/
		    status=$?
}
		    ;;
		*) hadoop dfs -copyToLocal ${d} ${procdir}/DIF_INT
		    status=$?
		    ;;
	    esac
	    
	    [ $status -ne 0 ] && {
		ciop-log "ERROR" "Failed to import file ${d}"
		return ${ERRGENERIC}
	    }
	    done
	done

    find ${procdir} -name "*.geosar*"  -exec geosarfixpath.pl --geosar='{}' --serverdir=${procdir} \; > /dev/null 2<&1

    return $SUCCESS;
}

# Public: get configuration parameter of file

# The function takes as arguments a file and a tag
# and search the tag on the file and returns the value 
# assigned to that tag. File must be of the form "TAG VALUE"
# example  SATELLITE_PASS  DESCENDING
# $1 - file
# $2 - tag
function get_conf_parameter(){
    local conffile="$1"
    local tag="$2"
    local line=$(grep "${tag}" "$conffile")
    local array=(${line// / })
    echo ${array[1]}
}


# Public: creates the properties files for Vel and Erh products

# The function takes as arguments the input file, the message title, orbit Direction
# incidence angle and sensor name and creates a properties file for the input file.

# $1 - input file
# $2 - message title
# $3 - orbit Direction
# $4 incidence angle
# $5 - snesor name
function create_fastvel_properties() {
    local inputfile="$1"
    local message="$2"
    local orbitdir="$3"
    local incid="$4"
    local sensor="$5"

    local bname=$(basename "$inputfile")
    local propfile="${inputfile}.properties"
    echo "title = FASTVEL-MTA - ${message}" > "${propfile}"
    if [[ "$bname" == *"S1A"* ]]; then
        echo "Sensor name = Sentinel - 1" >> "${propfile}"
    else echo "Sensor name = ${sensor}" >> "${propfile}"
    fi
    echo "Orbit Direction = ${orbitdir}" >> "${propfile}"
    echo "Incidence Angle = ${incid}" >> "${propfile}"
    echo "Orbit Direction = ${orbitdir}" >> "${propfile}"

    local date_proc=$(date +%Y-%m-%d)
    echo "Processing Date = ${date_proc}" >> "${propfile}"
    ciop-publish -m ${propfile}
}

# Public: fastvel pre processing
# 
# The function takes as arguments the local 
# folder where the pre processing should be performed,
# and the master image tag
#
# $1 - local folder for data import
# $2 - master image tag
#
# Examples
#
#    fastvel_pre "${serverdir}" "${mastertag}"
#
# Returns $SUCCESS on success 
#   
function fastvel_pre()
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
    sed -i -e 's@\(AZIMUTH DOPPLER FILE\)\([[:space:]]*\)\([^\n]*\)@\1\2---@g' "${smgeo}"
    

    ciop-log "INFO" "Running carto_sar"
    cartosar.pl --geosar=${smgeo} --tag="precise_${smorb}" --dir=${procdir}/GEOCODE/ --demdesc=${procdir}/DAT/dem.dat  > ${procdir}/log/cartosar.log 2<&1
    local cartost=$?
    ciop-log "INFO" "carto_sar status : $?"


    return ${SUCCESS}
}
