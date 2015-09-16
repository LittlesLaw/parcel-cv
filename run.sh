#!/usr/bin/env bash

# Avaliable Counties in Georgia
# Seminole ✓      Clinch
# Thomas   ✓      Ware
# Brooks   ✓      Pierce ✓
# Lowndes
# Echols

# Not avaliable
# Decatur
# Grady
# 

if [ -z $1 ]; then
    echo "./run <County>"
    exit 1
else
    COUNTY=$1
fi

URL="http://qpublic9.qpublic.net/cgi-bin/mapserv60"

OLDIFS=$IFS

echo "ok - Setting up build environment"
mkdir -p /tmp/${COUNTY}_parcels/
rm /tmp/${COUNTY}_parcels/* &>/dev/null

if [ ! -f /tmp/${COUNTY}_bounds ]; then
    echo "ok - tiling county polygon"
    while IFS='' read -r line || [[ -n $line ]]; do
        TOPRIGHT=$(echo $line   | jq -r -c '.geometry | .coordinates | .[] | .[]' | sed '2!d')
        BOTTOMLEFT=$(echo $line | jq -r -c '.geometry | .coordinates | .[] | .[]' | sed '4!d')
        echo "[$TOPRIGHT, $BOTTOMLEFT]" >> /tmp/${COUNTY}_bounds
    done <<< "$( $(dirname $0)/util/cover.js "$(grep "\"13\"" util/county.geojson | grep "$COUNTY" | sed 's/,$//' | jq '.geometry')" | jq -r -c '.features | .[]')"
else
    echo "ok - using cached tile polygons"
fi

echo "ok - Beginning Download ($(wc -l /tmp/${COUNTY}_bounds | grep -Eo "[0-9]+") tiles)"
cat /tmp/${COUNTY}_bounds | parallel --gnu "$(dirname $0)/util/getImage.sh \"{}\" \"$URL\" \"{#}\" \"$COUNTY\" \"$(wc -l /tmp/${COUNTY}_bounds | grep -Eo "[0-9]+")\""

echo "ok - merging parcels"
gdal_merge.py -init 255 -o /tmp/${COUNTY}_parcel_out.tif /tmp/${COUNTY}_parcels/*.tif

echo "ok - standarize image"
convert /tmp/${COUNTY}_parcel_out.tif \
    \( -alpha remove \) \
    \( -fill black -opaque white \) \
    TIFF64:/tmp/${COUNTY}_parcel_clean.tif

echo "ok - set projection"
./util/gdalcopyproj.py /tmp/${COUNTY}_parcel_out.tif /tmp/${COUNTY}_parcel_clean.tif

echo "ok - gdal_polygonize"
gdal_polygonize.py -nomask /tmp/${COUNTY}_parcel_clean.tif -f "ESRI Shapefile" /tmp/${COUNTY}_parcel_tile.shp

echo "ok - reproject to 4326"
# Polygonize will be as 54004 even though it is actually 3857
ogr2ogr /tmp/${COUNTY}_parcel_out.geojson /tmp/${COUNTY}_parcel_tile.shp -s_srs EPSG:3857 -t_srs EPSG:4326 -f "GeoJSON"

echo "ok - filter by black"
echo '{ "type": "FeatureCollection", "features": [' > /tmp/${COUNTY}_parcel_pts.geojson.tmp
grep "DN\": 0" /tmp/${COUNTY}_parcel_out.geojson >> /tmp/${COUNTY}_parcel_pts.geojson.tmp
sed -i '$s/,$//' /tmp/${COUNTY}_parcel_pts.geojson.tmp
echo ']}' >> /tmp/${COUNTY}_parcel_pts.geojson.tmp

echo "ok - poly => pt"
./node_modules/turf-cli/turf-point-on-surface.js /tmp/${COUNTY}_parcel_pts.geojson.tmp > /tmp/${COUNTY}_parcel_pts.geojson

echo "LNG,LAT,STR,DISTRICT,REGION" > ${COUNTY}_out.csv
PROG_TOT=$(wc -l /tmp/${COUNTY}_parcel_pts.geojson | grep -Po '\d+')

jq -r -c '.features | .[] | .geometry | .coordinates' /tmp/${COUNTY}_parcel_pts.geojson > /tmp/${COUNTY}_coords
cat /tmp/${COUNTY}_coords | parallel --gnu "$(dirname $0)/util/getAddress.sh \"{}\" \"{#}\" \"$PROG_TOT\" \"$COUNTY\""
