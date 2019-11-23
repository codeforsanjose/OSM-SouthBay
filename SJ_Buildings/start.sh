#!/bin/bash
# Before running, download VTA TAZ data from Google Drive here:
# https://drive.google.com/file/d/0B098fXDVjQOhVHBFS0kwcDNGRlU/view
# and place into a folder named "data"
# (might need to rename VTATaz.dbf)

DBNAME=svosm
OGR2OSM=../../ogr2osm/ogr2osm.py

# Add ESRI:103240 to PostGIS
# from https://github.com/Esri/projection-engine-db-doc/
psql --echo-all --file="103240.sql" "${DBNAME}" postgres


echo "Importing TAZ"
shp2pgsql -d -D -s 103240 -I "data/VTATaz" | psql -d "${DBNAME}" >/dev/null


curl "https://www.sanjoseca.gov/DocumentCenter/View/17141" --output "Basemap.zip"
unzip "Basemap.zip" "Parcel.*" -d "data"

echo "Importing Parcel"
shp2pgsql -d -D -s 103240 -t 2D -I "data/Parcel" | psql -d "${DBNAME}" >/dev/null


curl "http://www.sanjoseca.gov/DocumentCenter/View/44895" --output "Basemap_2.zip"
unzip "Basemap_2.zip" "BuildingFootprint.*" "CondoParcel.*" "Site_Address_Points.*" \
    -d "data"

echo "Importing BuildingFootprint"
shp2pgsql -d -D -s 103240 -I "data/BuildingFootprint" \
    | psql -d "${DBNAME}" >/dev/null

echo "Importing CondoParcel"
shp2pgsql -d -D -s 103240 -I "data/CondoParcel" | psql -d "${DBNAME}" >/dev/null

echo "Importing Site_Address_Points"
shp2pgsql -d -D -s 2227 -k -I "data/Site_Address_Points" \
    | psql -d "${DBNAME}" >/dev/null


# Download and import existing OSM data
curl "https://download.geofabrik.de/north-america/us/california/norcal-latest.osm.pbf" \
    --output "data/norcal-latest.osm.pbf"
osm2pgsql --database "${DBNAME} "--create \
    --prefix osm \
    --slim --hstore \
    --latlong --multi-geometry \
    --bbox "-122.038182903664,37.1409050504209,-121.593273327604,37.4640955052253" \
    "data/norcal-latest.osm.pbf"


# Merge addresses to buildings
psql -v "ON_ERROR_STOP=true" --echo-queries --file="merge.sql" "${DBNAME}"

# Split into tasks
mkdir "out"
mkdir "out/intersecting"
mkdir "out/clean"
for intersects in false true; do
    if ${intersects}; then
        outdir="intersecting"
        intersectsQuery="intersectsExisting"
    else
        outdir="clean"
        intersectsQuery="not intersectsExisting"
    fi
    
    ogr2ogr -sql "select 'https://codeforsanjose.github.io/OSM-SouthBay/SJ_Buildings/out/${outdir}/buildings_' || cid || '.osm' as import_url, geom from taggedTaz where ${intersectsQuery}" \
        -t_srs EPSG:4326 \
        "out/grouped_${outdir}_buildings_zones.geojson" \
        "PG:dbname=${DBNAME} host=localhost"
    
    for cid in {0..199}; do
        output="out/${outdir}/buildings_${cid}.osm"

        # Filter export data to each CID
        for layer in "buildingfootprint" "Site_Address_Points" "mergedbuildings" "namedparcels"; do
            psql -v "ON_ERROR_STOP=true" --echo-queries --command="create or replace view \"${layer}_filtered\" as select * from \"${layer}\" where cid=${cid} and ${intersectsQuery};" "${DBNAME}"
        done

        # Export to OSM
        python "${OGR2OSM}" "PG:dbname=${DBNAME} host=localhost" -t "basemap.py" -f --no-memory-copy -o "${output}"

        # Add sample region outline
        #sed -i '3i<bounds minlat="37.2440898883458" minlon="-121.875007225253" maxlat="37.25775329679" maxlon="-121.855829662555" />' "${output}"
    done
done

