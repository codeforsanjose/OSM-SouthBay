DBNAME=svosm

# From https://epsg.io/102643 , add ESRI:102643 to PostGIS
psql --echo-all --file=102643.sql ${DBNAME} postgres

# Import shapefiles
shp2pgsql -d -s 102643 -I Basemap/Parcel.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -s 102643 -I Basemap2/BuildingFootprint.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -s 102643 -I Basemap2/CondoParcel.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -s 102643 -k -I Basemap2/Site_Address_Points.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -s 102643 -I Basemap2/TractBoundary.shp | psql -d ${DBNAME} >/dev/null

# Import OSM
osm2pgsql --database ${DBNAME} --create --prefix osm --slim --hstore --latlong --multi-geometry --bbox "-122.030997029163,37.1409001316686,-121.668646071535,37.4620825000623" norcal-latest.osm.pbf

# Merge addresses to buildings
psql --file=merge.sql ${DBNAME}

# Export to OSM
python ogr2osm.py "PG:dbname=${DBNAME} host=localhost" -t basemap.py -f -o buildings.osm

