#!/bin/bash

#source the ciop functions
source ${ciop_job_include}

#source internal functions
source $_CIOP_APPLICATION_PATH/lib/util.sh  || {
    ciop-log "ERROR" "Failed to source $_CIOP_APPLICATION_PATH/lib/util.sh"
    exit 255
}


#properties
export PROPERTIES_FILE=$_CIOP_APPLICATION_PATH/properties/properties.xml


#read global parameters
mode=`ciop-getparam processing_mode`
aoi=`ciop-getparam aoi`
declare -a aoiarr
aoiarr=($(echo "$aoi" | sed 's@,@ @g'))
ref_lon=`ciop-getparam ref_point_lon`
ref_lat=`ciop-getparam ref_point_lat`


dir=$(mktemp -d "${TMPDIR}/glob_param_XXXXXX")

if [ ! -e "${dir}" ]; then
    ciop-log "ERROR" "Cannot create directory in ${TMPDIR}"
    echo ""
    exit $ERRPERM
fi

#create AOI shapefile
aoi2shp "${aoi}" "${dir}" "AOI"
aoishapefile=${dir}/AOI.shp
if [ ! -e "${aoishapefile}" ]; then
    ciop-log "ERROR" "Cannot create aoi shapefile"
    echo ""
    rm -rf "${dir}"
    exit $ERRGENERIC
fi


#create a file with parameters that should be available to 
#all nodes
glob_param_file=${dir}/global_parameters.txt

echo "processing_mode=${mode}" >> ${glob_param_file}
echo "aoi=${aoi}" >> ${glob_param_file}
echo "ref_point_lat=${ref_lat}" >> ${glob_param_file}
echo "ref_point_lon=${ref_lon}" >> ${glob_param_file}

ciop-publish -a "${glob_param_file}" || {
    	ciop-log "ERROR" "Failed to publish global parameters file"
	echo ""
	rm -rf "${dir}"
	exit ${ERRGENERIC}
}

#check ref point is inside aoi
ref_check ${aoishapefile} ${ref_lon} ${ref_lat} || {
    ciop-log "ERROR" "Reference point is not within area of interest"
    echo ""
    rm -rf ${dir}
    exit ${ERRINVALID}
}

#delete temporary folder
cd 
rm -rf "${dir}"

#count the number of inputs
input_count=0;

while read dataref
do
    wkt=($(opensearch-client -f atom "$dataref" wkt ))
    if [ -n "$wkt" ]; then
	check_polygon_aoi_intersection wkt[@] aoiarr[@] || {
	    ciop-log "ERROR" "Image $dataref does not cross with aoi $aoi"
	    continue
}
    fi
    let "input_count += 1"
    #input is passed as-is to next node
    echo $dataref | ciop-publish -s
done

#check on the minumum number of images when running in MTA mode
number_of_images_check ${input_count} "${PROPERTIES_FILE}"  ${mode} || {
    exit ${ERRGENERIC}
}

if [ $input_count -lt 2 ]; then
    ciop-log "ERROR" "At least 2 valid images required"
    exit ${ERRGENERIC}
fi

exit $SUCCESS
