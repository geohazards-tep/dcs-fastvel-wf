#!/bin/bash


# define the exit codes                                                                                                             
SUCCESS=0
ERRGENERIC=1
ERRPERM=2
ERRSTGIN=3
ERRINVALID=4
ERRSTARTDATE=5
ERRSTOPDATE=6
ERRMISSING=255


# Public: Create a processing folder structure
#
# Takes a folder path as argument where it creates 
# the folder usual folder structure used in DIAPASON  
# 
# The function will echo the path of the created folder
#
# $1 - location where to create the processing folder
#
# Examples
#
#   serverdir=$(procdirectory "/tmp")
#
# Returns $SUCCESS if the folder was created or an error code otherwise
#   

function procdirectory()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi

    rootdir="$1"

    directory=`mktemp -d ${rootdir}/DIAPASON_XXXXXX` || {
	return ${ERRPERM}
    }

    mkdir -p ${directory}/{DAT/GEOSAR,RAW_C5B,SLC_CI2,ORB,TEMP,log,QC,GRID,DIF_INT,CD,GEO_CI2,GEO_CI2_EXT_LIN,VOR,GRID_LIN,GEOCODE} || {
	return ${ERRPERM}
    }
    
    echo "${directory}"
    
    return ${SUCCESS}
}


# Public: Clean temporary processing folder
#
# Checks for the for a folder defined as value 
# of the serverdir variable and deletes the folder
# when it exists
#
# Function takes no argument
#
# Examples
#
#   procCleanup 
#
# Returns the exit code of the last command executed 

function procCleanup()
{
    if [ -n "${serverdir}"  ] && [ -d "$serverdir" ]; then
        ciop-log "INFO : Cleaning up processing directory ${serverdir}"
        rm -rf "${serverdir}"
    fi

}

# Public: Clean node intermediate results
#
# Takes as argument the workflow id and node name
# and deletes the contents that were published to that node
#
#  $1 - workflow id 
#  $2 - node name
#
# Examples
#
#   node_cleanup ${WF_ID} node_name
#
# Returns the exit code of the last command executed 

function node_cleanup()
{
    if [  $# -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    local wkfid="$1"
    local nodelist="$2"
    for node in $nodelist ; do
	for d in `ciop-browseresults -r "${wkfid}" -j ${node}`; do
	    hadoop dfs -rmr $d > /dev/null 2<&1
	done
    done
}

# Public: parse a sentinel-1 product name string
#
# Takes a string argument and splits it using "_" as separator
# The input string should be the name of a Sentinel-1 .SAFE folder
# The function will echo an array with the split string
#
# $1 - string
#
# Examples
#
# masterinfo=($(product_name_parse "${master}"))
#
# Returns the exit code of the last command executed.

function product_name_parse()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    product=`basename "$1"`
    info=(`echo ${product%.*} | sed 's@_@ @g'`)
    echo "${info[@]}"

if [ ${#info[@]} -lt 3 ]; then
    ciop-log "ERROR" "Bad Filename : ${product}"
    return ${ERRGENERIC}
    fi
}

# Public: Check if a sentinel-1 product is supported
# by the processor.
#
# The input string should be the name of a Sentinel-1 .SAFE folder
# The function will detect the acquisition mode and processing level
# (Raw or SLC) and return the status accordingly
#
# $1 - string
#
# Examples
#
# product_check "${master}"
#
# Returns $SUCCESS if the product is SLC and TOPS (IW or EW) 

function product_check()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    product=`basename "$1"`
    
    if [ -z "${product}" ]; then
	return ${ERRMISSING}
    fi
    
    #file name should be of the form S1A_(IW|EW)_SLC__1SDH_20150512T022514_20150512T022624_005882_007938_BA47.SAFE
    arr=($(product_name_parse "${product}"))
    
    if [ ${#arr[@]} -lt 3 ]; then
	echo "invalid file name ${product} "${arr[@]}
	return ${ERRINVALID}
    fi
    
    #topsar modes supported
    mode=${arr[1]}
    
    modeok=0
    case $mode in
	IW)modeok=1;;
	EW)modeok=1;;
	*)modeok=0;
esac
    
    if [ $modeok -le 0 ]; then
	ciop-log "ERROR" "invalid or unsupported mode ${mode}"
	return ${ERRINVALID}
    fi

#SLC supported , RAW data unsupported
level=${arr[2]}

if [ "$level" != "SLC" ]; then
    ciop-log "ERROR" "invalid or unsupported processing level $level"
    return ${ERRINVALID}
fi

return ${SUCCESS}
}


# Public: Download an image from the catalog
#
# Takes as argument the image reference in the catalog and 
# the folder where the image should be downloaded
#
# $1 - Image url
# $2 - download folder
#
# Examples
#
#   master=$( get_data ${masterref} ${datadir}/download/master )
#
# Returns 0 on success and non-zero on error

get_data() {                                                                                                                                                     
  local ref=$1                                                                                                                                                   
  local target=$2                                                                                                                                                
  local local_file                                                                                                                                               
  local enclosure                                                                                                                                                
  local res                                                                                                                                                      
                                                                                                                                                                 
  [ "${ref:0:4}" == "file" ] || [ "${ref:0:1}" == "/" ] && enclosure=${ref}                                                                                      
                                                                                                                                                                 
  [ -z "$enclosure" ] && enclosure=$( opensearch-client  -f atom  "${ref}" enclosure )                                                                                     
  res=$?                                                                                                                                                         
  enclosure=$( echo ${enclosure} | tail -1 )                                                                                                                     
  [ $res -eq 0 ] && [ -z "${enclosure}" ] && return ${ERRSTGIN}                                                                                               
  [ $res -ne 0 ] && enclosure=${ref}                                                                                                                             
                                                                                                                                                                 
  local_file="$( echo ${enclosure} | ciop-copy -f -U -O ${target} - 2> /dev/null )"                                                                              
  res=$?                                                                                                                                                         
  [ ${res} -ne 0 ] && return ${res}                                                                                                                              
  echo ${local_file}                                                                                                                                             
}               

# Public: Determine matching burst numbers
# for 2 s1 images
#
# Takes as argument 2 geosar files 3 variable names
# for starting burst , ending burst and burst list
# and an optional shapefile as parameters 
# 
# 
#
# $1 - geosar file of the master image
# $2 - geosar file of the slave image
# $3 - variable name for storing output starting burst number
# $4 - variable name for storing output ending burst number
# $5 - variable name for storing output burst list
# $6 - optional shapefile 
#
# Example
#
#   matching_bursts  "${orbitmaster}.geosar" "${orbitslave}.geosar" BURSTSTART BURSTEND SLAVEBURSTLIST "${aoidef}"
#
# The function will return 0 on success and non-zero
# otherwise
#   

function matching_bursts
{
    if [ $# -lt 5 ]; then
	echo "$FUNCNAME geosar1 geosar2 varstart varstop varlist" 1>&2
	return 1
    fi

    local geosarm="$1"
    local geosars="$2"

    if [ -z "${EXE_DIR}"  ] || [ ! -e "${EXE_DIR}/matching_burst" ]; then
	return 2
    fi
    
    local first=""
    local last=""
    local list=()
    
      #master bursts to test
    local starting=0
    local ending=50
    
    #in case use set an aoi
    local aoi=""
    if [ $# -ge 6 ]; then
	aoi="$6"
   
	if [ "`type -t s1_bursts_aoi`"  = "function" ] && [ -n "${aoi}" ]; then
	    #echo "running s1_swaths_aoi"
	    s1_bursts_aoi "${geosarm}" "${aoi}" bursts
	    status=$?
	    #echo "s1_burst_aoi status $status"
	    if [ $status -eq 0 ]; then
		local burstlist=(`echo "$bursts"`)
		if [ ${#burstlist[@]} -eq 2 ]; then
		    starting=${burstlist[0]}
		    ending=${burstlist[1]}
		fi
	    else 	
		#subswath does not intersect with the specified aoi
		return 3
	    fi
	    
	fi
	
    fi

    for x in `seq "${starting}" "${ending}"`; do
	bursts=`${EXE_DIR}/matching_burst "${geosarm}" "${geosars}" "${x}" 2>/dev/null | grep -i slave | sed 's@\([^=]*\)\(=\)\(.*\)@\3@g' `
	status=$?

	if [ $status -ne 0 ] || [ -z "${bursts}" ]; then
	        continue
		fi
	
	if [ $bursts -lt  0 ]; then
	        continue
		fi
	
	if [ -z "${first}" ]; then
	        first=$x
		fi
	
	last=$x
	
	list=( ${list[@]} $bursts ) 
	
    done
    
    if [ -z "${first}" ] || [ -z "${last}" ]; then
	return 3
    fi
 
    nbursts=`echo "${last} - ${first} +1" | bc -l`
    nlistbursts=${#list[@]}
    
    if [ $nlistbursts -ne ${nbursts} ]; then
	return 4
    fi
    
     eval "$3=\"${first}\""
     eval "$4=\"${last}\""
     eval "$5=\"${list[@]}\""

    return 0
}



function get_POEORB() {
  local S1_ref=$1
  local aux_dest=$2

  [ -z "${aux_dest}" ] && aux_dest="." 

  local startdate
  local enddate
  
  startdate="$( opensearch-client "${S1_ref}" startdate)" 
  enddate="$( opensearch-client "${S1_ref}" enddate)" 
  
  [ -z "${startdate}"  ] && {
      return ${ERRSTARTDATE}
  }

  [ -z "${enddate}"  ] && {
      return ${ERRSTOPDATE}
  }
  echo "start : ${startdate}"
  echo "end : ${enddate}"
  

  aux_list=$( opensearch-client  "http://data.terradue.com/gs/catalogue/aux/gtfeature/search?q=AUX_POEORB&start=${startdate}&stop=${enddate}" enclosure )

  [ -z "${aux_list}" ] && return 1

  echo ${aux_list} | ciop-copy -o ${aux_dest} -

}


# Public: dem download from geosar file information
#
# Takes a folder path as argument , looks 
# for geosar files inside the folder and 
# determines the minimum latitude and longitude
# of the area ,downloads the dem and creates
# the descriptor and raster
# 
#
# $1 - input processing folder
#
# Examples
#
#   get_DEM ${serverdir}
#
# Returns $SUCCESS if the dem was downloaded 
# and properly imported.
# 
#   
# 
function get_DEM()
{
    if [ $# -lt 1 ]; then
	return ${ERRMISSING}
    fi
    
    #check for required programs 
    if [ -z "`type -p curl`" ] ; then
	ciop-log "ERROR : System missing curl utility" return
	${ERRMISSING} 
    fi
	
    if [ -z "`type -p gdalinfo`" ] ; then
	ciop-log "ERROR : System missing gdalinfo utility" return
	${ERRMISSING} 
    fi


    procdir="$1"
    
    
    latitudes=(`grep -h LATI ${procdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | grep [0-9] | sort -n |  sed -n '1p;$p' | sed 's@[[:space:]]@@g' | tr '\n' ' ' `)
    longitudes=(`grep -h LONGI ${procdir}/DAT/GEOSAR/*.geosar | cut -b 40-1024 | grep [0-9] | sort -n | sed -n '1p;$p' | sed 's@[[:space:]]@@g' | tr '\n' ' ' `)
    
    if [ ${#latitudes[@]} -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    
    if [ ${#longitudes[@]} -lt 2 ]; then
	return ${ERRGENERIC}
    fi
    
    url="http://dedibox.altamira-information.com/demdownload?lat="${latitudes[0]}"&lat="${latitudes[1]}"&lon="${longitudes[0]}"&lon="${longitudes[1]}
    
    ciop-log "INFO : Downloading DEM from ${url}"
    
    demtif=${procdir}/DAT/dem.tif
    
    downloadcmd="curl -o \"${demtif}\" \"${url}\" "

    eval "${downloadcmd}" > "${procdir}"/log/demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR : Unable to download DEM data"
	return ${ERRGENERIC}
    fi
    
    #check it is a tiff
    gdalinfo "${demtif}" > /dev/null 2<&1 || {
	ciop-log "ERROR : No DEM data over selected area"
	return ${ERRGENERIC}
    }
    
    
return ${SUCCESS}

}


# Public: get the bursts corssing an area of 
# interest for a s1 subswath
#
# Takes a geosar file as input , an aoi defined
# by a shapefile path, or with the aoi coordinates,
# and a variable name used to store the bursts from
# the image crossing the aoi.
#
# $1 - geosar file of an s1 image subswath
# $2 - aoi , either shapefile path or coordinates string
# $3 - variable name storing output burst list 
#
# Examples
#
#   s1_bursts_aoi ${geosarfile} ${aoishapefile} burstlist
#
# Returns 0 on success and non-zero otherwise
#   

function s1_bursts_aoi()
{
	if [ $# -lt 3 ]; then
		return 1
	fi
	
	local geosar=$1
	local aoi=$2
	
	if [ -z "${EXE_DIR}" ]; then
		return 1
	fi	
	
	if [ ! -e "${EXE_DIR}/swath_aoi_intersect" ]; then
		echo "missing binary ${EXE_DIR}/swath_aoi_intersect"
		return 1
	fi
	
	local bursts_=$(${EXE_DIR}/swath_aoi_intersect "${geosar}" "$aoi" | grep BURST | sed 's@[^0-9]@@g')
	
	if [ -z "${bursts_}" ]; then
		return 1
	fi
	
	#record output burst list
	eval  "$3=\"${bursts_}\""
	
	return 0
}


function create_interf_properties()
{
    if [ $# -lt 4 ]; then
	echo "$FUNCNAME : usage:$FUNCNAME file description serverdir geosar"
	return 1
    fi

    local inputfile=$1
    local fbase=`basename ${inputfile}`
    local description=$2
    local serverdir=$3
    local geosarm=$4
    local geosars=""
    if [ $# -ge 5 ]; then
    geosars=$5
    fi
    
    local datestart=$(geosar_time "${geosarm}")
    
    local dateend=""
    if [ -n "$geosars" ]; then
	dateend=$(geosar_time "${geosars}")
    fi

    local propfile="${inputfile}.properties"
    echo "title = DIAPASON InSAR Sentinel-1 TOPSAR(IW,EW) - ${description} - ${datestart} ${dateend}" > "${propfile}"
    echo "Description = ${description}" >> "${propfile}"
    local sensor=`grep -h "SENSOR NAME" "${geosarm}" | cut -b 40-1024 | awk '{print $1}'`
    echo "Sensor\ Name = ${sensor}" >> "${propfile}"
    local masterid=`head -1 ${serverdir}/masterid.txt`
    if [ -n "${masterid}" ]; then
	echo "Master\ SLC\ Product = ${masterid}" >> "${propfile}"
    fi 
    local slaveid=`head -1 ${serverdir}/slaveid.txt`
    if [ -n "${slaveid}" ]; then
	echo "Slave\ SLC\ Product = ${slaveid}" >> "${propfile}"
    fi 

    #look for 2jd utility to convert julian dates
    if [ -n "`type -p j2d`"  ] && [ -n "${geosars}" ]; then
	local jul1=`grep -h JULIAN "${geosarm}" | cut -b 40-1024 | sed 's@[^0-9]@@g'`
	local jul2=`grep -h JULIAN "${geosars}" | cut -b 40-1024 | sed 's@[^0-9]@@g'`
	if [ -n "${jul1}"  ] && [ -n "${jul2}" ]; then 
	
	    local dates=""
	    for jul in `echo -e "${jul1}\n${jul2}" | sort -n`; do
		local julday=`echo "2433283+${jul}" | bc -l`
		local dt=`j2d ${julday} | awk '{print $1}'`
		
		dates="${dates} ${dt}"
	    done
	   
	fi
	echo "Observation\ Dates = $dates" >> "${propfile}"
	
	local timeseparation=`echo "$jul1 - $jul2" | bc -l`
	if [ $timeseparation -lt 0 ]; then
	    timeseparation=`echo "$timeseparation*-1" | bc -l`
	fi
	
	if [ -n "$timeseparation" ]; then
	    echo "Time\ Separation\ \(days\) = ${timeseparation}" >> "${propfile}"
	fi
    fi

    local altambig="${serverdir}/DAT/AMBIG.dat"
    if [ -e "${altambig}" ] ; then
	local info=($(grep -E "^[0-9]+" "${altambig}" | head -1))
	if [  ${#info[@]} -ge 6 ]; then
	    #write incidence angle
	    echo "Incidence\ angle\ \(degrees\) = "${info[2]} >> "${propfile}"
	    #write baseline
	    local bas=`echo ${info[4]} | awk '{ if($1>=0) {print $1} else { print $1*-1} }'`
	    echo "Baseline\ \(meters\) = ${bas}" >> "${propfile}"
	else
	    ciop-log "INFO" "Invalid format for AMBIG.DAT file "
	fi
    else
	ciop-log "INFO" "Missing AMBIG.DAT file in ${serverdir}/DAT"
    fi 
    
    local satpass=`grep -h "SATELLITE PASS" "${geosarm}"  | cut -b 40-1024 | awk '{print $1}'`
    
    if [ -n "${satpass}" ]; then
	echo "Orbit\ Direction = ${satpass}" >> "${propfile}"
    fi

    local publishdate=`date +'%B %d %Y' `
    echo "Processing\ Date  = ${publishdate}" >> "${propfile}"
    
    local logfile=`ls ${serverdir}/ortho_amp.log`
    if [ -e "${logfile}" ]; then
	local resolution=`grep "du mnt" "${logfile}" | cut -b 15-1024 | sed 's@[^0-9\.]@\n@g' | grep [0-9] | sort -n | tail -1`
	if [ -n "${resolution}" ]; then
	    echo "Resolution\ \(meters\) = ${resolution}" >> "${propfile}"
	fi
    fi
    
    local wktfile="${serverdir}/wkt.txt"
    
    if [ -e "${wktfile}" ]; then
	local wkt=`head -1 "${wktfile}"`
	echo "geometry = ${wkt}" >> "${propfile}"
    fi
}

# Public: Download dem from an image catalogue reference
#
# Takes an image reference and a processing folder as
# input. The coordinates of the DEM are inferred from the
# image reference. The dem is the downloaded and imported
# in the processing folder
#
# $1 - image reference
# $2 - processing folder where the dem is saved
#
# Examples
#
#   download_dem_from_ref ${imgref} ${demdir}
#
# Returns $SUCCESS if the dem was downloaded
# and extracted properly
#   

function download_dem_from_ref()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:ref directory "
	return ${ERRMISSING}
    fi

    local ref="$1"
    local outputdir="$2"

    #look for the extent of the scene
    local wkt=($(opensearch-client -f atom "$ref" wkt | sed 's@[a-zA-Z()]@@g' | sed 's@,@ @g'))
    
    if [ -z  "${wkt}" ]; then
	ciop-log "ERROR " "Missing wkt info for ref $ref"
	return ${ERRMISSING}
    fi

    
    local lon
    local lat

    lon=(`echo "${wkt[@]}" | sed 's@ @\n@g' | sed -n '1~2p' | sort -n | sed -n '1p;$p' | sed 's@\n@ @g'`)
    lat=(`echo "${wkt[@]}" | sed 's@ @\n@g' | sed -n '2~2p' | sort -n | sed -n '1p;$p' | sed 's@\n@ @g'`)

    if [ ${#lon[@]} -ne 2 ] || [ ${#lat[@]} -ne 2 ]; then
	ciop-log "ERROR" "Bad format for wkt description"
	return ${ERRINVALID}
    fi

    
    
    local demurl="http://dedibox.altamira-information.com/demdownload?lat="${lat[0]}"&lat="${lat[1]}"&lon="${lon[0]}"&lon="${lon[1]}
    
    ciop-log "INFO " "Downloading DEM from ${demurl}"
    
    
    local demtif=${outputdir}/dem.tif
    
    local downloadcmd="curl -o \"${demtif}\" \"${demurl}\" "
    
    eval "${downloadcmd}" > "${outputdir}"//demdownload.log 2<&1

    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR" "Unable to download DEM data"
	return ${ERRGENERIC}
    fi

    #check it is a tiff
    gdalinfo "${demtif}" > /dev/null 2<&1 || {
	ciop-log "ERROR" "No DEM data over selected area"
	return ${ERRGENERIC}
    }

    return ${SUCCESS}
}



# Public: Create a shapefile from an aoi coordinate
# string definition
#
# Takes as argument bounding box string of the form:
# "minlon,minlat,maxlon,maxlat" , the output folder
# where the shapefile shall be created ,and the tag
# used to name the shapefile
# 
# $1 - area bounding box string
# $2 - output folder where the shapefile is created
# $3 - tag name of the shapefile
#
# The function will echo the path of the created shapefile
# 
#  Examples
#
#   shape=$(aoi2shp "${latlonbox}" "${outdir}" "aoi")
#
# Returns $SUCCESS if the folder was created or an error code otherwise
#   

function aoi2shp()
{
    if [ $# -lt 3 ]; then
	ciop-log "ERROR" "Usage:$FUNCTION minlon,minlat,maxlon,maxlat directory tag"
	return ${ERRMISSING}
    fi

    local aoi="$1"

    local directory="$2"

    local tag="$3"

    if [ ! -d "`readlink -f $directory`" ]; then
	ciop-log "ERROR" "$FUNCTION:$directory is not a directory"
	return ${ERRINVALID}
    fi

    #check for aoi validity
    local aoiarr=(`echo ${aoi} | sed 's@,@ @g' `)

    local nvalues=${#aoiarr[@]}

    if [ $nvalues -lt 4 ]; then
	ciop-log "ERROR" "$FUNCTION:Invalid aoi :$aoi"
	ciop-log "ERROR" "$FUNCTION:Should be of the form: minlon,minlat,maxlon,maxlat"
	return ${ERRINVALID}
    fi

    #use a variable for each
    local maxlon=${aoiarr[2]}
    local maxlat=${aoiarr[3]}
    local minlon=${aoiarr[0]}
    local minlat=${aoiarr[1]}

    #check for shapelib utilities
    if [ -z "`type -p shpcreate`" ]; then
	ciop-log "ERROR" "Missing shpcreate utility"
	return ${ERRMISSING}
    fi

    if [ -z "`type -p shpadd`" ]; then
	ciop-log "ERROR" "Missing shpadd utility"
	return ${ERRMISSING}
    fi

    #enter the output shapefile directory
    cd "${directory}" || {
	ciop-log "ERROR" "$FUNCTION:No permissions to access ${directory}"
	cd -
	return ${ERRPERM}
}
    

    #create empty shapefile
    shpcreate "${tag}" polygon
    local statuscreat=$?

    if [ ${statuscreat}  -ne 0 ]; then
	cd -
	ciop-log "ERROR" "$FUNCTION:Shapefile creation failed"
	return ${ERRGENERIC}
    fi 

    shpadd "${tag}" "${minlon}" "${minlat}" "${maxlon}" "${minlat}" "${maxlon}" "${maxlat}"  "${minlon}" "${maxlat}" "${minlon}" "${minlat}"
    
    local statusadd=$?

    if [ ${statusadd} -ne 0 ]; then
	ciop-log "ERROR" "$FUNCTION:Failed to add polygon to shapefile"
	return ${ERRGENERIC}
    fi
    
  local shp=${directory}/${tag}.shp

  if [ ! -e "${shp}" ]; then
      cd -
      ciop-log "ERROR" "$FUNCTION:Failed to create shapefile"
      return ${ERRGENERIC}
  fi

  echo "${shp}"

  return ${SUCCESS}

 }



# Public: Check the intersection between 2 products
#
# Takes 2 image catalogue references and checks whether 
# the 2 images intersect
#
# $1 - image catalogue reference
# $2 - image catalogue reference
#
# Examples
#
#   product_intersect $ref1 $ref2
#
# Returns 0 if the images intersect or if 
# the coordinates of the images cannot be inferred
# from the reference.
# A non-zero output is returned when the images
# do not intersect
#   

function product_intersect()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:ref1 ref2"
	return 255
    fi

    local ref1="$1"
    local ref2="$2"
    
        #look for the extent of the scene
    local wkt1=($(opensearch-client -f atom "$ref1" wkt ))
    local wkt2=($(opensearch-client -f atom "$ref2" wkt ))

    n1=${#wkt1[@]}
    n2=${#wkt2[@]}

    #if wkt info is missing for at least
    # 1 product , cannot check intersection
    # assume it is ok
    if [ $n1 -eq 0 ] || [ $n2 -eq 0 ]; then
	 ciop-log "INFO" "Missing wkt info"
	return 0
    fi

    polygon_intersect wkt1[@]} wkt2[@]}
    
    status=$?

    return $status
}

# Public: Check whether two polygons intersect
#
# Takes 2 polygon geometry definitions and checks
# for the intersection between the 2
#
# $1 - polygon geometry definition
# $2 - polygon geometry definition
#
# Examples
#
#  polygon_intersect wkt1[@]} wkt2[@]
#
# Returns 0 if the polygons intersect 
# non-zero otherwise
#   

function polygon_intersect()
{
    if [ $# -lt 2 ]; then
	ciop-log "ERROR" "$FUNCNAME:poly1 poly2"
	return 255
    fi

    declare -a wkt1=("${!1}")
    declare -a wkt2=("${!2}")
    
    
    /usr/bin/python - <<END
import sys
try:
  from osgeo import ogr
except ImportError:
  sys.exit(0)

wkt1="${wkt1[@]}"
wkt2="${wkt2[@]}"

status=0
  
try:
# Create spatial reference
  out_srs = ogr.osr.SpatialReference()
  out_srs.ImportFromEPSG(4326)

  poly1 = ogr.CreateGeometryFromWkt(wkt1)
  poly1.AssignSpatialReference(out_srs)
  poly2 = ogr.CreateGeometryFromWkt(wkt2)
  poly2.AssignSpatialReference(out_srs)

  intersection=poly2.Intersection(poly1)

  if intersection.IsEmpty():
     status=1
except Exception,e:
  sys.exit(0)

sys.exit( status )

END
local status=$?

if [ $status -ne 0 ]; then
    return 1
fi

}

# get suitable minimum and maximum image
# values for histogram stretching
# arguments:
# input image
# variable used to store minimum value
# variable used to store maximum value
# return 0 if successful , non-zero otherwise
function image_equalize_range()
{
    if [ $# -lt 1 ]; then
	return 255
    fi 

    #check gdalinfo is available
    if [ -z "`type -p gdalinfo`" ]; then
	return 1
    fi

    local image="$1"

    
    declare -A Stats
    
    #load the statistics information from gdalinfo into an associative array
    while read data ; do
	string=$(echo ${data} | awk '{print "Stats[\""$1"\"]=\""$2"\""}')
	eval "$string"
    done < <(gdalinfo -hist "${image}"   | grep STATISTICS | sed 's@STATISTICS_@@g;s@=@ @g')

    #check that we have mean and standard deviation
    local mean=${Stats["MEAN"]}
    local stddev=${Stats["STDDEV"]}
    local datamin=${Stats["MINIMUM"]}

    if [ -z "$mean"   ] || [ -z "${stddev}" ] || [ -z "${datamin}" ]; then
	return 1
    fi 
    
   
    local min=`echo $mean - 3*${stddev} | bc -l`
    local max=`echo $mean + 3*${stddev} | bc -l`
    
    local below_zero=`echo "$min < $datamin" | bc -l`
    
    [ ${below_zero} -gt 0 ] && {
	min=$datamin
    }
    
    if [ $# -ge 2 ]; then
	eval "$2=${min}"
    fi

    if [ $# -ge 3 ]; then
	eval "$3=${max}"
    fi

   
    return 0
}

# Public: Get a string representation of 
# the acquisition time field of a geosar
# file
#
# Takes the path of a geosar file as input
#
# The function will echo the result
#
# $1 - path to a geosar file
#
# Examples
#
#   time=$(geosar_time ${geosar})
#
# Returns 0 on success and non-zero otherwise
#   

function geosar_time()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    local geosar="$1"
   
    local date=$(/usr/bin/perl <<EOF
use POSIX;
use strict;
use esaTime;
use geosar;

my \$geosar=geosar->new(FILE=>'$geosar');
my \$time=\$geosar->startTime();
print \$time->xgr;
EOF
)

    [ -z "$date" ] && {
	return $ERRMISSING
    }

    echo $date
    return 0
}

# Public: get a wkt string with the extent of 
# a geotiff file
#
# Takes a geotiff file as input
# The function will echo the polygon wkt definition
#
# $1 - geotiff file
#
# Examples
#
#   wkt=$(tiff2wkt ${geotiff})
#
# Returns 0 on success and non-zero othwerise
#   
function tiff2wkt(){
    
    if [ $# -lt 1 ]; then
	echo "Usage $0 geotiff"
	return $ERRMISSING
    fi
    
    tiff="$1"
    
    declare -a upper_left
    upper_left=(`gdalinfo $tiff | grep "Upper Left" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    
    declare -a lower_left
    lower_left=(`gdalinfo $tiff | grep "Lower Left" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)

    declare -a lower_right
    lower_right=(`gdalinfo $tiff | grep "Lower Right" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    
    declare -a upper_right
    upper_right=(`gdalinfo $tiff | grep "Upper Right" | sed 's@[,)(]@ @g' | awk '{print $3" "$4}'`)
    
    echo "POLYGON((${upper_left[0]} ${upper_left[1]} , ${lower_left[0]} ${lower_left[1]},  ${lower_right[0]} ${lower_right[1]} , ${upper_right[0]} ${upper_right[1]}, ${upper_left[0]} ${upper_left[1]}))"
   
    return 0
}

# Public: Extract a zipped .SAFE S1 product file
#
# Takes a zipped .SAFE folder and a folder for 
# extraction. The function will extract the annotation
# and measurement files from the zipped input
# 
# The function will echo the unzipped folder
#
# $1 - input zip file containing a .SAFE archive
#
# Examples
#
#   safe=$( extract_safe ${zip} ${datadir} )
#
# Returns 0 on success and non-zero otherwise
#   
function extract_safe() {
  safe_archive=${1}
  optional=${2}
  safe=$( unzip -l ${safe_archive} | grep "SAFE" | grep -v zip | head -n 1 | awk '{ print $4 }' | xargs -I {} basename {} )

  [ -n "${optional}" ] && safe=${optional}/${safe}
  mkdir -p ${safe}
  
  local annotlist=""
  local measurlist=""
  local manifest=""
  
  if [ -n "${pol}" ]; then
      annotlist=$( unzip -l "${safe_archive}" | grep annotation | grep .xml | grep -v calibration | awk '{ print $4 }' | grep -i "\-${pol}\-")
      measurlist=$( unzip -l "${safe_archive}" | grep measurement | grep .tiff | awk '{ print $4 }'  | grep -i "\-${pol}\-")
  else
      annotlist=$( unzip -l "${safe_archive}" | grep annotation | grep .xml | grep -v calibration | awk '{ print $4 }' )
      measurlist=$( unzip -l "${safe_archive}" | grep measurement | grep .tiff | awk '{ print $4 }' )
  fi
  
  manifest=$(unzip -l "${safe_archive}"  | grep manifest | awk '{print $4}')

  #check for empty measurement and annotation lists
  if [ -z "${measurlist}" ]; then
      ciop-log "ERROR" "file ${safe_archive} contains no measurement files"
      return ${ERRINVALID}
  fi
  
  if [ -z "${annotlist}" ]; then
      ciop-log "ERROR" "file ${safe_archive} contains no annotation files"
      return ${ERRINVALID}
  fi
  
  if [ -n "${manifest}" ]; then
      for manifestfile in ${manifest} ; do
	  unzip -o -j ${safe_archive} "${manifestfile}" -d "${safe}/"
      done
  fi



  for annotation in $annotlist
  do
     unzip -o -j ${safe_archive} "${annotation}" -d "${safe}/annotation" 1>&2
     res=$?
     ciop-log "INFO" "unzip ${annotation} : status $res"
     [ "${res}" != "0" ] && return ${res}
  done
  ciop-log "INFO" "Unzipped $( ls -l ${safe}/annotation )"
  for measurement in $measurlist
  do
    unzip -o -j ${safe_archive} "${measurement}" -d "${safe}/measurement" 1>&2
    res=$?
    ciop-log "INFO" "unzip ${measurement} : status $res"
    [ "${res}" != "0" ] && return ${res}    
  done
  
  if [ -n "`type -p gdalinfo`" ]; then
      #check the tiff files with gdalinfo
      local tif
      for tif in `find ${safe} -name *.tiff -print -o -name "*.tif" -print`; do
	  gdalinfo "${tif}" > /dev/null 2<&1
	  res=$?
	  [ "${res}" != "0" ] && {
	      ciop-log "INFO" "tiff file ${tif} is invalid . gdalinfo status $res"
	  }
      done
  fi

  echo ${safe}
  
}


########################################################################################
# Public: Get an image tag from a geosar file
#
# Takes the path of a geosar file as input
#
# The function will echo tag associated to the 
# geosar file
#
# $1 - path to a geosar file
#
# Examples
#
#   tag=$(geosartag ${geosar})
#
# Returns 0 on success and non-zero otherwise
#   

function geosartag()
{
    if [ $# -lt 1 ]; then
	return $ERRMISSING
    fi
    local geosar="$1"
    
    local tag=$(/usr/bin/perl <<EOF
use POSIX;
use strict;
use esaTime;
use geosar;

my \$geosar=geosar->new(FILE=>'$geosar');
print \$geosar->tag();
EOF
)
echo "$tag"
return 0
}


function ext2dop()
{
    if [ $# -lt 4 ]; then
	echo "Usage : $FUNCTION product extdir mlaz mlran pol"
	return 255
    fi

    local product="$1"
    local serverdir="$2"
    local mlaz=$3
    local mlran=$4
    local pol=$5
    local tag=`basename ${product}` 
    local ext=${product##*.}
    local statusext=$?
    
    #make sure properties file is  set
    if [ -z "${PROPERTIES_FILE}" ]; then
	ciop-log "ERROR" "PROPERTIES_FILE unset"
 	return ${ERRMISSING}
    fi

    #product extraction
    if [ "${ext}" == "SAFE" ]; then
	extract_any.pl --in="${product}" --serverdir="${serverdir}" --pol="${pol}" --tmpdir="${serverdir}/TEMP" > "${serverdir}/log/extraction_${tag}.log" 2<&1
	statusext=$?
    else
	handle_tars.pl --in="${product}" --serverdir="${serverdir}" --pol="${pol}" --tmpdir="${serverdir}/TEMP" > "${serverdir}/log/extraction_${tag}.log" 2<&1
	statusext=$?
    
    fi
    
    if [ $statusext -ne 0 ]; then
	cp ${serverdir}/log/*.log /tmp
	chmod 775 /tmp/*.log
	return ${ERRGENERIC}
    fi
    
    #count extracted geosar
    local cntgeosar=`ls ${serverdir}/DAT/GEOSAR/*.geosar | wc -l`
    
    [ "${cntgeosar}" -eq 0 ] && {
	cp ${serverdir}/log/*.log /tmp
	chmod 775 /tmp/*.log
	return ${ERRGENERIC}
    }
    local geosar=`ls ${serverdir}/DAT/GEOSAR/*.geosar | head -1`
    tag=$(geosartag "${geosar}")
    
    [ -z "$tag" ] && {
	return ${ERRGENERIC}
    }
    
    local mlazi
    local mlrang
    local interpx
    read_multilook_factors "${tag}" "${PROPERTIES_FILE}" mlazi mlrang interpx || {
	ciop-log "ERROR" "Failed to determine multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}
    }
    
    if [ -z "${mlazi}" ] || [ -z "${mlrang}" ] ; then
	ciop-log "ERROR" "Failed to determine multilook parameters from properties file ${PROPERTIES_FILE}"
	return ${ERRGENERIC}	
    fi

    echo "${tag}" > ${serverdir}/DAT/datatag.txt 2<&1
    mv ${serverdir}/log/extraction*.log "${serverdir}/log/${tag}_extraction.log"
    #precise orbits
    preciseorb "${geosar}" "${serverdir}"
    
    #check for raw images
    local gstatus=`grep -ih "STATUS" "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    
    if [ "$gstatus" == "RAW" ]; then
	#run focusing
	prisme.pl --geosar="$geosar" --mlaz=${mlazi} --mlran=${mlrang}  --mltype=byt --tmpdir="${serverdir}/TEMP" --outdir="${serverdir}/SLC_CI2/"  --tmpdir="${serverdir}/TEMP" --rate > "${serverdir}/log/${tag}_prisme.log" 2<&1
	local prismestatus=$?
	if [ $prismestatus -ne 0 ]; then
	    #print message
	    cp ${serverdir}/log/*.log /tmp
	    chmod 777 /tmp/*.log
	    return ${ERRGENERIC}
	fi
	#delete raw data
	rm -f "${serverdir}"/RAW_C5B/*
    fi
    

    #ML & doppler
    ls -tra ${serverdir}/DAT/GEOSAR/*.geosar | head -1 | ml_all.pl --mlaz=${mlazi} --mlran=${mlrang} --dir="${serverdir}/SLC_CI2"  --tmpdir="${serverdir}/TEMP" > "${serverdir}/log/${tag}_ml.log" 2<&1
    
    local statusml=$?
    
    if [ $statusml -ne 0 ]; then
	cp ${serverdir}/log/*.log /tmp
	chmod 775 /tmp/*.log
	return ${ERRGENERIC}
    fi

    #
    setlatlongeosar.pl --geosar="${geosar}" --tmpdir="${serverdir}/TEMP"   > "${serverdir}/log/${tag}_corner_latlon.log" 2<&1

    return 0
}

# Public: Download the precise orbit for an image
#
# Takes a geosar file path as argument as well as 
# a processing folder for storing the orbit file.
# the folder should have a "/ORB" sub-directory
#
# $1 - input geosar file
# $2 - a processing folder
#
# Examples
#
#   preciseorb ${geosar} ${procdir}
#
# Returns 0 on success and non-zero otherwise
#   

function preciseorb()
{
    if [ $# -lt 2 ]; then
	echo "Usage : $FUNCTION geosar serverdir"
	return 255
    fi
    
    local geosar="$1"
    local serverdir="$2"
    local tag=$(geosartag "${geosar}")
    local sensor=`grep -i "SENSOR NAME" "${geosar}" | cut -b '40-1024' | sed 's@[[:space:]]@@g'`
    local orbit=`grep -ih "ORBIT NUMBER" "${geosar}" | cut -b 40-1024 | sed 's@[[:space:]]@@g'`
    local storb=""
    
    case "$sensor" in
	ERS*) diaporb.pl --geosar="${geosar}" --type=delft --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" > "${serverdir}/log/${tag}_precise_orbits.log" 2<&1 ;;
	ENVISAT*)
	    diaporb.pl --geosar="${geosar}" --type=doris --mode=1 --dir="${serverdir}/VOR" --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/${tag}_precise_orbits.log" 2<&1
	    storb=$?
	    if [ $storb -ne 0 ]; then
		diaporb.pl --geosar="${geosar}" --type=doris   --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/${tag}_precise_orbits.log" 2<&1
		storb=$?
	    fi
            
            if [ $storb -ne 0 ]; then
                diaporb.pl --geosar="${geosar}" --type=delft   --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/${tag}_precise_orbits.log" 2<&1
            fi
            ;;
        S1*) diaporb.pl --geosar="${geosar}" --type=s1prc  --dir="${serverdir}/VOR" --mode=1 --outdir="${serverdir}/ORB" --exedir="${EXE_DIR}" >> "${serverdir}/log/${tag}_precise_orbits.log" 2<&1
	    storb=$?
	    ;;
	*)$storb=0;; #nothing to do with other sensors
    esac

    return $storb
}

# Public: Download dem from s1 image annotations
#
# Takes a folder containing s1 annotations ,
# and an output folder where the dem should be stored
# The function will look for s1 xml annotation files
# and infer the area extents. The dem is the downloaded 
# and imported
#
# $1 - input folder
# $2 - output folder where to save the imported dem
#
# Examples
#
#   download_dem_from_anotation ${indir} ${demdir}
#
# Returns $SUCCESS if the dem was downloaded
# and extracted properly
#   

function download_dem_from_anotation()
{
    if [ $# -lt 2 ]; then
	return 255
    fi
    
    local inputdir="$1"
    local outputdir="$2"
            #check for required programs 
    if [ -z "`type -p curl`" ] ; then
	ciop-log "ERROR"  "System missing curl utility" 
	return ${ERRMISSING} 
    fi
    
    if [ -z "`type -p gdalinfo`" ] ; then
	ciop-log "ERROR"  "System missing gdalinfo utility" 
	return ${ERRMISSING} 
    fi


    declare -a aoi
    #look from xml files
    aoi=($(find "${inputdir}/" -name "*.xml" -print | s1extent.pl  | sed 's@,@ @g'))
    
    local status=$?
    
    if [ $status -ne 0 ]; then
	ciop-log "ERROR" "Failed to determine product enclosing aoi"
	return ${ERRINVALID}
    fi

    if [ ${#aoi[@]} -lt 4 ]; then
	ciop-log "ERROR" "Invalid product enclosing coordinates ${aoi[@]}"
	return ${ERRINVALID}
    fi
    
    url="http://dedibox.altamira-information.com/demdownload?lat="${aoi[1]}"&lat="${aoi[3]}"&lon="${aoi[0]}"&lon="${aoi[2]}
    
    #echo "${url}"
    ciop-log "INFO : Downloading DEM from ${url}"
    
    local demtif="${outputdir}/dem.tif"

    downloadcmd="curl -o \"${demtif}\" \"${url}\" "
    
    eval "${downloadcmd}" > "${outputdir}"/demdownload.log 2<&1
    
    #check downloaded file
    if [ ! -e "${demtif}" ]; then
	ciop-log "ERROR : Unable to download DEM data"
	return ${ERRGENERIC}
    fi
    
    #check it is a tiff
    gdalinfo "${demtif}" > /dev/null 2<&1 || {
	ciop-log "ERROR : No DEM data over selected area"
	return ${ERRGENERIC}
    }
    
    
    return ${SUCCESS}
}

# Public: Get the polarization information
# from an image tag
#
# Takes a string holding an image tag and 
# a variable to store the polarization information
#
# $1 - image tag string
# $2 - output variable name
#
# Examples
#
#   product_tag_get_pol $tag pol
#
# Returns $SUCCESS on success ,and error code otherwise
#   

function product_tag_get_pol()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi

    local tag="$1"
    
    local poltag=`echo ${tag} | sed 's@_@ @g' | awk '{print $NF}' | grep -i "^[VH][VH]$"`
    
    [ -z "${poltag}" ] && {
	ciop-log "ERROR"  "Invalid product tag ${tag}"
	return ${ERRINVALID}
    }
    
    eval "$2=\"${poltag}\""
     
    return ${SUCCESS}
}

# Public: Get the sensor information
# from an image tag
#
# Takes a string holding an image tag and 
# a variable to store the sensor information
#
# $1 - image tag string
# $2 - output variable name
#
# Examples
#
#   product_tag_get_sensor $tag sensor
#
# Returns $SUCCESS on success ,and error code otherwise
#   

function product_tag_get_sensor()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi

    local tag="$1"
    
    local sensortag=`echo ${tag} | sed 's@_@ @g' | awk '{print $4}'`
    
    [ -z "${sensortag}" ] && {
	ciop-log "ERROR"  "Invalid product tag ${sensortag}"
	return ${ERRINVALID}
    }
    
    eval "$2=\"${sensortag}\""
     
    return ${SUCCESS}
}

# Public: Get the acquisition mode information
# from an image tag
#
# Takes a string holding an image tag and 
# a variable to store the acquisition mode information
#
# $1 - image tag string
# $2 - output variable name
#
# Examples
#
#   product_tag_get_mode "${tag}" mode
#
# Returns $SUCCESS on success ,and error code otherwise
#   
function product_tag_get_mode()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi

    local tag="$1"
    
    local modetag=`echo ${tag} | sed 's@_@ @g' | awk '{print $6}'`
    
    [ -z "${modetag}" ] && {
	ciop-log "ERROR"  "Invalid product tag ${modetag}"
	return ${ERRINVALID}
    }
    
    eval "$2=\"${modetag}\""
     
    return ${SUCCESS}
}

# Public: Read the geometric undersampling parameters
#
# Takes a geosar file , the properties file as arguments
# and 2 variables for storing the geometric undersampling 
# parameters
# 
#
# $1 - geosar file
# $2 - properties file
# $3 - variable name for output azimuth undersampling factor
# $4 - variable name for output range undersampling factor
#
# Examples
#
#   read_geom_undersampling $geosar ${properties} aziunder ranunder
#
# Returns $SUCCESS on success or an error code otherwise
#   

function read_geom_undersampling()
{
    if [ $# -lt 4 ]; then
	echo "Usage: geosar properties AZIUNDER RANUNDER"
	return ${ERRMISSING}
    fi

    local geosar="$1"
    local properties="$2"
    
    [ -z "`type -p xmlstarlet`" ] && {
	ciop-log "ERROR" "Missing xmlstarlet utility"
	return ${ERRMISSING}
    }

    local ranunder=`cat ${properties} | xmlstarlet sel -t -v "//properties/geomRnUnderSampling"`
    [ -z "${ranunder}" ] && {
	ciop-log "ERROR" "Unable to read geomRnUnderSampling from ${properties}"
	return ${ERRMISSNIG}
    }

    local aziunder=`cat ${properties} | xmlstarlet sel -t -v "//properties/geomAzUnderSampling"`
    
    [ -z "${aziunder}" ] && {
	ciop-log "ERROR" "Unable to read geomAzUnderSampling from ${properties}"
	return ${ERRMISSNIG}
    }

    eval "$3=\"${ranunder}\""
    eval "$4=\"${aziunder}\""
    
    
    return ${SUCCESS}
}

# Public: Read the multilook factors
#
# Takes a geosar file , the properties file as arguments
# and variables for storing the azimuth and range multilook 
# factors ,as well as the range interpolation factor
# 
#
# $1 - geosar file
# $2 - properties file
# $3 - variable name for output azimuth multilook factor
# $4 - variable name for output range multilook factor
# $5 - variable name for range oversampling factor
#
# Examples
#
#   read_multilook factors $geosar ${properties} mlazi mlran interpx
#
# Returns $SUCCESS on success or an error code otherwise
#   

function read_multilook_factors()
{
    if [ $# -lt 5 ]; then
	echo "Usage: prodtag properties MLAZ MLRAN INTERPX"
	return ${ERRMISSING}
    fi

    local prodtag="$1"
    local properties="$2"
    
    [ -z "`type -p xmlstarlet`" ] && {
	ciop-log "ERROR" "Missing xmlstarlet utility"
	return ${ERRMISSING}
    }
    
    local sensor
    product_tag_get_sensor "${prodtag}" sensor
    sensor=`echo "${sensor}" |  sed 's@[[:space:]]@@g' | sed 's@S1[AB]@S1@g;s@ERS[12]@ERS@g'`
    
    local mode
    product_tag_get_mode "${prodtag}" mode
    
    if [ -z "${sensor}" ] || [ -z "${mode}" ]; then
	ciop-log "ERROR" "Failed to parse product tag ${prodtag}"
 	return ${ERRINVALID}
    fi

    local mlaz_
    local mlran_
    local interpx_

    case "${sensor}" in
	S1*)
	    if [ "$mode" != "IW" ] && [ "${mode}" != "EW" ]; then
		mode="SM"
	    fi
	    mlaz_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode[@name='${mode}']/azimuthMultilookFactor"`
	    mlran_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode[@name='${mode}']/rangeMultilookFactor"`
	    interpx_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode[@name='${mode}']/rangeOverSamplingFactor"`
 	    ;;
	*)
	    mlaz_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode/azimuthMultilookFactor"`
	    mlran_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode/rangeMultilookFactor"`
	    interpx_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode/rangeOverSamplingFactor"`
	    ;;
    esac
    
    

    #echo "--> $mlran_ ${mlaz_} ${interpx_}"
    
    if [ -z "${mlran_}" ] || [ -z "${mlaz_}" ]; then
	ciop-log "ERROR" "Failed to read multilook factors from properties file ${properties}"
	return ${ERRINVALID}
    fi
    
    [ -z "${interpx_}" ] && {
	interpx_=1
    }

    eval "$3=\"${mlaz_}\""
    eval "$4=\"${mlran_}\""
    eval "$5=\"${interpx_}\""
    
     

    return ${SUCCESS}
}

# Public: Get the orbit number information
# from an image tag
#
# Takes a string holding an image tag and 
# a variable to store the orbit number information
#
# $1 - image tag string
# $2 - output variable name
#
# Examples
#
#   product_tag_get_orbnum $tag orbnum
#
# Returns $SUCCESS on success ,and error code otherwise
#   
function product_tag_get_orbnum()
{
    if [ $# -lt 2 ]; then
	return ${ERRMISSING}
    fi

    local tag="$1"
    
    local orbnum_=`echo ${tag} | sed 's@_@ @g' | awk '{print $3}'`
    
    [ -z "${orbnum_}" ] && {
	ciop-log "ERROR"  "Invalid product tag ${tag}"
	return ${ERRINVALID}
    }
    
    eval "$2=\"${orbnum_}\""
     
    return ${SUCCESS}
}



# Public: copy a folder to hdfs
#
# Takes as inputs a remote hdfs path ,
# a local path ,and a string for the 
# target folder name
#
# The function tries to create the remote path
# if the destination folder already exists the 
# data is not copied. 
#
# $1 - remote hdfs location
# $2 - local folder
# $3 - name for the remote folder to create
#
# Examples
#
#   export_folder "${hdfsroot}/node_coreg/data" ${pubsmtemp} ${tagsm}
#
# Returns $SUCCESS if the remote folder was properly exported or 
# if it was created previously by another process
#   
function export_folder()
{
    if [ $# -lt 3 ]; then
	ciop-log "INFO" "Usage:$FUNCTION remotedir localdir tag"
	return ${ERRMISSING}
    fi

    local remoteroot="$1"
    local localdir="$2"
    local tag="$3"

    local remotedir="${remoteroot}/${tag}"

    hadoop dfs -mkdir "${remotedir}"  > /dev/null 2<&1 || {
	#if mkdir fails 
	#check whether the folder was created by another folder
	hadoop dfs -test -d "${remotedir}" > /dev/null 2<&1
	local tststatus=$?
	[ $tststatus -ne 0 ] && {
	    #folder does not exist in hdfs
	    #and we couldn't create it
	    return ${ERRGENERIC}
	}
	#folder was created by another process
	#no need for this process to create it
	return ${SUCCESS}
    }
    #this process created the folder
    for x in `ls ${localdir}/`; do
        hadoop dfs -put ${localdir}/${x} "${remotedir}"
	local cpstatus=$?
	[ ${cpstatus} -ne 0 ] && {
	    #failed to copy a content of local directory to hdfs
	    #remove the created folder and return an error
	    hadoop dfs -rmr "${remotedir}" >/dev/null 2<&1
	    return ${ERRGENERIC}
	} 
    done
    #echo "published folder ${locadir}"
    
    return ${SUCCESS}
}




# Public: Computing the area of slc scene within aoi
#
# The aoi specified as minlon,minlat,maxlon,maxlat
#
# $1 - input geosar file
# $2 - input aoi coordinates
# $3 - input dem descriptor
# $4 - output folder to store slc extraction coordinates file
#
# Examples
#
#  roi=$(geosar_get_aoi_coords2 "${smgeo}" "${aoidef}" "${procdir}/DAT/dem.dat"  "${procdir}/log/")
#
# Returns $SUCCESS on success or an error code otherwise
#   

function geosar_get_aoi_coords2()
{
    if [ $# -lt 4 ]; then
	ciop-log "ERROR" "$FUNCTION :  missing argument"
	return ${ERRMISSING}
    fi


    local geosar="$1"
    local aoi="$2"
    local dem="$3"

    local tmpdir_="$4"
       
    #aoi is of the form
    #minlon,minlat,maxlon,maxlat
    aoi=(`echo "$aoi" | sed 's@,@ @g'`)
    
    if [ ${#aoi[@]} -lt 4 ]; then
	ciop-log "ERROR" "Bad aoi definition ${aoi}"
	return ${ERRINVALID}
    fi
    
    local coordsfile=${tmpdir_}/aoi2sarcoords.txt

    aoi2coords.pl --geosar="${geosar}" --demdesc="${dem}" --minlon=${aoi[0]} --minlat=${aoi[1]} --maxlon=${aoi[2]} --maxlat=${aoi[3]} --outfile="${coordsfile}" > ${tmpdir_}/aoi2coords.log 2<&1
    
    if [ ! -e "${coordsfile}" ]; then
	ciop-log "INFO" "$FUNCTION aoi2coords fail"
	return ${ERRGENERIC}
    fi
    
    local coords=`head -1 ${coordsfile}`

    if [ -z "${coords}" ]; then
	ciop-log "INFO" "$FUNCTION empty aoi2coords result"
	return ${ERRGENERIC}
    fi
    
    echo $coords
    
    return ${SUCCESS}   
}

# Public: Trap function for temporary processing directory cleanups
#
# This function calls procCleanup and exits
#
# The function takes no argument
#
# Example
# trap trapFunction INT TERM
#   
#

function trapFunction()
{
    procCleanup
    exit
}


# Public: Read the multilook factors suitable
# for orbit correction
#
# Takes a geosar file , the properties file as arguments
# and variables for storing the azimuth and range multilook 
# factors 
# 
#
# $1 - geosar file
# $2 - properties file
# $3 - variable name for output azimuth multilook factor
# $4 - variable name for output range multilook factor
#
# Examples
#
#   read_multilook_factors_orbit_correcion $geosar ${properties} mlazi mlran 
#
# Returns $SUCCESS on success or an error code otherwise
#   

function read_multilook_factors_orbit_correction()
{
    if [ $# -lt 4 ]; then
	echo "Usage: prodtag properties MLAZ MLRAN "
	return ${ERRMISSING}
    fi

    local prodtag="$1"
    local properties="$2"
    
    [ -z "`type -p xmlstarlet`" ] && {
	ciop-log "ERROR" "Missing xmlstarlet utility"
	return ${ERRMISSING}
    }
    
    local sensor
    product_tag_get_sensor "${prodtag}" sensor
    sensor=`echo "${sensor}" |  sed 's@[[:space:]]@@g' | sed 's@S1[AB]@S1@g;s@ERS[12]@ERS@g'`
    
    local mode
    product_tag_get_mode "${prodtag}" mode
    
    if [ -z "${sensor}" ] || [ -z "${mode}" ]; then
	ciop-log "ERROR" "Failed to parse product tag ${prodtag}"
 	return ${ERRINVALID}
    fi

    local mlaz_
    local mlran_

    case "${sensor}" in
	S1*)
	    if [ "$mode" != "IW" ] && [ "${mode}" != "EW" ]; then
		mode="SM"
	    fi
	    mlaz_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode[@name='${mode}']/orbitCorrectionAzimuthMultilookFactor"`
	    mlran_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode[@name='${mode}']/orbitCorrectionRangeMultilookFactor"`
 	    ;;
	*)
	    mlaz_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode/orbitCorrectionAzimuthMultilookFactor"`
	    mlran_=`cat ${properties} | xmlstarlet sel -t -v "//sensor[starts-with(@name,'${sensor}')]/acquisitionMode/orbitCorrectionRangeMultilookFactor"`
	    ;;
    esac
    
    

    #echo "--> $mlran_ ${mlaz_} ${interpx_}"
    
    if [ -z "${mlran_}" ] || [ -z "${mlaz_}" ]; then
	ciop-log "ERROR" "Failed to read multilook factors from properties file ${properties}"
	return ${ERRINVALID}
    fi
    

    eval "$3=\"${mlaz_}\""
    eval "$4=\"${mlran_}\""
     

    return ${SUCCESS}
}


# Public: Create a png and a pngw file from a 
# geotiff file
#
# Takes a geotiff file  as input
# 
#
# $1 - geotiff file
#
# Examples
#
#   create_pngs_from_tif $geotiff 
#
# Returns $SUCCESS on success or an error code otherwise
#   
function create_pngs_from_tif () {
    
  if [ $# -lt 1 ]; then
      return ${ERRMISSING}
  fi
  local tif="$1"
  png=${tif%.*}.png

  gdal_translate -oT Byte -of PNG -co worldfile=yes -a_nodata 0 "${tif}" "${png}" > /dev/null 2<&1

  wld=${png%.*}.wld
  pngw=${png%.*}.pngw
  [ -e "${wld}" ] && mv "${wld}"  "${pngw}"

  return ${SUCCESS}
}