DBNAME=svosm

# From https://github.com/Esri/projection-engine-db-doc/ , add ESRI:103240 to PostGIS
psql --echo-all --file=103240.sql ${DBNAME} postgres

# Import shapefiles
shp2pgsql -d -D -s 103240 -I Basemap/Parcel.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -D -s 103240 -I Basemap2/BuildingFootprint.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -D -s 103240 -I Basemap2/CondoParcel.shp | psql -d ${DBNAME} >/dev/null
shp2pgsql -d -D -s 103240 -k -I Basemap2/Site_Address_Points.shp | psql -d ${DBNAME} >/dev/null

# Import OSM
osm2pgsql --database ${DBNAME} --create --prefix osm --slim --hstore --latlong --multi-geometry --bbox "-122.034749578245,37.1439079487581,-121.594450627833,37.4601683238918" norcal-latest.osm.pbf

# Merge addresses to buildings
psql --echo-queries --file=merge.sql ${DBNAME}

# Export to OSM
python ogr2osm.py "PG:dbname=${DBNAME} host=localhost" -t basemap.py -f --no-memory-copy -o buildings.osm

# Add sample region outline
#sed -i '3i<bounds minlat="37.2440898883458" minlon="-121.875007225253" maxlat="37.25775329679" maxlon="-121.855829662555" />' buildings.osm

