#!/bin/bash

DBNAME=svosm

# From https://github.com/Esri/projection-engine-db-doc/ , add ESRI:103240 to PostGIS
psql --echo-all --file=103240.sql ${DBNAME} postgres

# Import shapefiles
echo "Importing Parcel"
shp2pgsql -d -D -s 103240 -I Basemap/Parcel.shp | psql -d ${DBNAME} >/dev/null
echo "Importing BuildingFootprint"
shp2pgsql -d -D -s 103240 -I Basemap2/BuildingFootprint.shp | psql -d ${DBNAME} >/dev/null
echo "Importing CondoParcel"
shp2pgsql -d -D -s 103240 -I Basemap2/CondoParcel.shp | psql -d ${DBNAME} >/dev/null
echo "Importing Site_Address_Points"
shp2pgsql -d -D -s 2227 -k -I Basemap2/Site_Address_Points.shp | psql -d ${DBNAME} >/dev/null
echo "Importing TAZ"
shp2pgsql -d -D -s 103240 -I VTA_TAZ/VTATaz.shp | psql -d ${DBNAME} >/dev/null

# Import OSM
osm2pgsql --database ${DBNAME} --create --prefix osm --slim --hstore --latlong --multi-geometry --bbox "-122.038182903664,37.1409050504209,-121.593273327604,37.4640955052253" norcal-latest.osm.pbf

# Merge addresses to buildings
psql -v "ON_ERROR_STOP=true" --echo-queries --file=merge.sql ${DBNAME}

mkdir out
mkdir out/intersecting
mkdir out/clean
for intersects in false true; do
    if ${intersects}; then
        outdir=intersecting
        intersectsQuery="intersectsExisting"
    else
        outdir=clean
        intersectsQuery="not intersectsExisting"
    fi
    
    ogr2ogr -sql "select 'https://codeforsanjose.github.io/OSM-SouthBay/SJ_Buildings/out/${outdir}/buildings_' || cid || '.osm' as import_url, geom from taggedTaz where ${intersectsQuery}" -t_srs EPSG:4326 out/grouped_${outdir}_buildings_zones.geojson "PG:dbname=${DBNAME} host=localhost"
    
    for cid in {0..199}; do
        output=out/${outdir}/buildings_${cid}.osm

        # Filter export data to each CID
        for layer in "buildingfootprint" "Site_Address_Points" "mergedbuildings" "namedparcels"; do
            psql -v "ON_ERROR_STOP=true" --echo-queries --command="create or replace view \"${layer}_filtered\" as select * from \"${layer}\" where cid=${cid} and ${intersectsQuery};" ${DBNAME}
        done

        # Export to OSM
        python ogr2osm.py "PG:dbname=${DBNAME} host=localhost" -t basemap.py -f --no-memory-copy -o ${output}

        # Add sample region outline
        #sed -i '3i<bounds minlat="37.2440898883458" minlon="-121.875007225253" maxlat="37.25775329679" maxlon="-121.855829662555" />' ${output}
    done
done

