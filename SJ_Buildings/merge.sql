\set BUILDINGS_SRID 103240
\set ADDRESSES_SRID 2227
\set ADDRESS_DISTANCE_THRESHOLD 80
\set CONDO_WITHIN_PROPORTION 0.7
\set PARCEL_WITHIN_PROPORTION 0.9
\set PARTITIONS 200
\set LARGE_PARCEL 400000

-- Sample region
/*delete from BuildingFootprint
	where not geom && ST_SetSRID(ST_MakeBox2D(ST_Point(6161510, 1914285), ST_Point(6167021, 1919180)), :BUILDINGS_SRID);
delete from "Site_Address_Points"
	where not geom && ST_SetSRID(ST_MakeBox2D(ST_Point(6161506, 1914286), ST_Point(6167017, 1919181)), :ADDRESSES_SRID);
\set PARTITIONS 5*/

delete from "Site_Address_Points"
	where "Status"='Unverified'
	or "Status"='Temporary'
	or "Status"='Retired';

-- Find and delete address points that don't have a matching street name in OSM
drop table if exists missingStreets;
create table missingStreets
	as select "CompName", "StreetMast", ST_ConvexHull(ST_Collect(geom))
	from "Site_Address_Points" as addr
	left join osm_line
	on upper(replace(replace("CompName", 'St ', 'Saint '), 'Mt ', 'Mount '))=upper(name)
	where name is null
	group by "StreetMast", "CompName";
delete from "Site_Address_Points"
	using missingStreets
	where "Site_Address_Points"."StreetMast"=missingStreets."StreetMast";

create index if not exists "Site_Address_Points_ParcelID_idx"
	on "Site_Address_Points" ("ParcelID");

alter table Parcel alter column ParcelID type int using cast (ParcelID as int);
create index if not exists Parcel_ParcelID_idx
	on Parcel (ParcelID);

-- Try to detect address "clusters"
alter table "Site_Address_Points" add column clustered boolean default false;
update "Site_Address_Points" as addr1
	set clustered=true
	from "Site_Address_Points" as addr2
	where addr1."ParcelID" = addr2."ParcelID"
	and addr1.gid != addr2.gid
	and ST_DWithin(addr1.geom, addr2.geom, 10.1)
	and (abs(ST_X(addr1.geom) - ST_X(addr2.geom)) <= 0.1
		or abs(ST_Y(addr1.geom) - ST_Y(addr2.geom)) <= 0.1);
-- Add entries for aggregated clustered addresses
alter table "Site_Address_Points" alter column "Add_Number" type text;
alter table "Site_Address_Points" alter column "Unit" type text;
insert into "Site_Address_Points"
	("Place_Type", "Add_Number", "AddNum_Suf", "CompName",
	 "Unit_Type", "Unit", "Inc_Muni", "Post_Code", "CondoParce", "ParcelID", geom)
	select
		"Place_Type",
		array_to_string(array_agg(distinct "Add_Number"), ';'),
		array_to_string(array_agg(distinct "AddNum_Suf"), ';'),
		"CompName",
		"Unit_Type",
		array_to_string(array_agg(distinct "Unit"), ';'),
		"Inc_Muni", "Post_Code",
		"CondoParce", "ParcelID",
		ST_Centroid(ST_Collect(geom))
	from (
		select *,
		ST_ClusterDBSCAN(geom, 10.1, 3) over () as cid
		from "Site_Address_Points"
		where clustered) sq
	group by "Place_Type",
		"CompName",
		"Unit_Type",
		"Inc_Muni", "Post_Code",
		"CondoParce", "ParcelID",
		cid,
		floor(mod(cast (ST_X(geom) as numeric), 10)*2),
		floor(mod(cast (ST_Y(geom) as numeric), 10)*2);
-- Delete old clusters
delete from "Site_Address_Points" where clustered=true;
alter table "Site_Address_Points" drop column clustered;

-- Project OSM data to local coordinates
-- (losing accuracy is okay because it's only for conflation)
alter table osm_polygon add column if not exists geom_buildings geometry(multipolygon, :BUILDINGS_SRID);
update osm_polygon set geom_buildings = ST_MakeValid(ST_Transform(ST_Multi(way), :BUILDINGS_SRID));
create index if not exists "osm_polygon_geom_buildings_idx" on osm_polygon using GIST(geom_buildings);

alter table osm_point add column if not exists geom_addr geometry(point, :ADDRESSES_SRID);
update osm_point set geom_addr = ST_Transform(way, :ADDRESSES_SRID);
create index if not exists "osm_point_geom_addr_idx" on osm_point using GIST(geom_addr);

alter table osm_polygon add column if not exists geom_addr geometry(multipolygon, :ADDRESSES_SRID);
update osm_polygon set geom_addr = ST_MakeValid(ST_Transform(ST_Multi(way), :ADDRESSES_SRID));
create index if not exists "osm_polygon_geom_addr_idx" on osm_polygon using GIST(geom_addr);

-- Find data that already exist in OSM, to split for later conflation
alter table BuildingFootprint add column intersectsExisting boolean default false;
update BuildingFootprint as bldg
	set intersectsExisting = true
	from osm_polygon
	where ((osm_polygon.building is not null
	and osm_polygon.building != 'no')
	or osm_polygon.tags?'demolished:building')
	and ST_Intersects(bldg.geom, osm_polygon.geom_buildings);

alter table "Site_Address_Points" add column intersectsExisting boolean default false;
update "Site_Address_Points" as addr
	set intersectsExisting = true
	from osm_point
	where osm_point.highway is null
	and ST_DWithin(addr.geom, osm_point.geom_addr, :ADDRESS_DISTANCE_THRESHOLD);
update "Site_Address_Points" as addr
	set intersectsExisting = true
	from osm_polygon
	where osm_polygon.landuse is null
	and osm_polygon.natural is null
	and ST_DWithin(addr.geom, osm_polygon.geom_addr, :ADDRESS_DISTANCE_THRESHOLD);

-- Useful to have around
alter table "Site_Address_Points" add column if not exists geom_buildings geometry(point, :BUILDINGS_SRID);
update "Site_Address_Points" set geom_buildings = ST_Transform(geom, :BUILDINGS_SRID);
create index if not exists "Site_Address_Points_geom_buildings_idx" on "Site_Address_Points" using GIST(geom_buildings);

-- For each condo area where there is only one address, find all buildings in the condo area
drop table if exists mergedBuildings;
create table mergedBuildings as
with uniqParcel as (
	select "CondoParce"
	from "Site_Address_Points"
	group by "CondoParce"
	having count(*) = 1)
select (row_number() over (partition by CondoParce order by ST_Distance("Site_Address_Points".geom_buildings, BuildingFootprint.geom))) as rn,
	BuildingFootprint.*,
	"Site_Address_Points".gid as addr_gid, "Place_Type",
	"Add_Number", "AddNum_Suf",
	"CompName",
	"Unit_Type", "Unit",
	"Inc_Muni", "Post_Code"
	from BuildingFootprint
	inner join CondoParcel
	on ST_Intersects(BuildingFootprint.geom, CondoParcel.geom)
	and ST_Area(ST_Intersection(BuildingFootprint.geom, CondoParcel.geom)) > :CONDO_WITHIN_PROPORTION*ST_Area(BuildingFootprint.geom)
	inner join uniqParcel
	on CondoParcel.IntID=uniqParcel."CondoParce"
	inner join "Site_Address_Points"
	on uniqParcel."CondoParce"="Site_Address_Points"."CondoParce";
-- Merge the address with the building closest to the address
delete from mergedBuildings where rn != 1;

-- Delete merged buildings from the other tables
delete from BuildingFootprint
	using mergedBuildings
	where BuildingFootprint.gid = mergedBuildings.gid;
delete from "Site_Address_Points"
	using mergedBuildings
	where "Site_Address_Points".gid = mergedBuildings.addr_gid;

-- For each parcel where there is only one address, find all buildings on the parcel
with uniqParcel as (
	select "ParcelID"
	from "Site_Address_Points"
	where "Unit" is null
	or "Unit" like '%;%'
	or "Unit_Type" = 'Building'
	or "Unit_Type" = 'Space'
	or "Unit_Type" is null
	group by "ParcelID"
	having count(*) = 1)
insert into mergedBuildings
select (row_number() over (partition by ParcelID order by ST_Distance("Site_Address_Points".geom_buildings, BuildingFootprint.geom))) as rn,
	BuildingFootprint.*,
	"Site_Address_Points".gid as addr_gid, "Place_Type",
	"Add_Number", "AddNum_Suf",
	"CompName",
	"Unit_Type", "Unit",
	"Inc_Muni", "Post_Code"
	from BuildingFootprint
	inner join Parcel
	on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
	and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > :PARCEL_WITHIN_PROPORTION*ST_Area(BuildingFootprint.geom)
	inner join uniqParcel
	on Parcel.ParcelID=uniqParcel."ParcelID"
	inner join "Site_Address_Points"
	on uniqParcel."ParcelID"="Site_Address_Points"."ParcelID"
	where ("Unit" is null
		or "Unit" like '%;%'
		or "Unit_Type" = 'Building'
		or "Unit_Type" = 'Space'
		or "Unit_Type" is null)
	and ST_Area(Parcel.geom) < :LARGE_PARCEL
	and ("Place_Type" is null or "Place_Type" != 'Educational')
	and ("Place_Type" is null or "Place_Type" != 'Hospital');
-- Merge the address with the building closest to the address
delete from mergedBuildings where rn != 1;

-- Delete merged buildings from the other tables
delete from BuildingFootprint
	using mergedBuildings
	where BuildingFootprint.gid = mergedBuildings.gid;
delete from "Site_Address_Points"
	using mergedBuildings
	where "Site_Address_Points".gid = mergedBuildings.addr_gid;

with siteParcelsWithMatchingBuildings as (
	-- Find sites with more buildings than addresses (i.e., a development/settlement)
	with siteParcels as (
		with parcelAddrs as (
			select ParcelID, count(*) as addrCount
			from Parcel
			inner join "Site_Address_Points"
			on Parcel.ParcelID="Site_Address_Points"."ParcelID"
			group by ParcelID),
		parcelBuildings as (
			select ParcelID, count(*) as buildingCount
			from Parcel
			inner join BuildingFootprint
			on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
			and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > :PARCEL_WITHIN_PROPORTION*ST_Area(BuildingFootprint.geom)
			group by ParcelID)
		select parcelAddrs.ParcelID
			from parcelAddrs
			inner join parcelBuildings
			on parcelAddrs.ParcelID=parcelBuildings.ParcelID
			where buildingCount > addrCount)
	select "Site_Address_Points"."ParcelID" from
		-- Find addresses that intersect any building in the parcel
		(select bool_or(ST_Within("Site_Address_Points".geom_buildings, BuildingFootprint.geom)) as intersects, "Site_Address_Points".gid
			from siteParcels
			inner join "Site_Address_Points"
			on ParcelID="ParcelID"
			inner join Parcel
			on siteParcels.ParcelID=Parcel.ParcelID
			inner join BuildingFootprint
			on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
			and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > :PARCEL_WITHIN_PROPORTION*ST_Area(BuildingFootprint.geom)
			group by "Site_Address_Points".gid, "Site_Address_Points"."FullAddres"
		) as addrsOnBuildings
		-- Find parcels where *all* addresses intersect a building
		inner join "Site_Address_Points"
		on addrsOnBuildings.gid="Site_Address_Points".gid
		group by "Site_Address_Points"."ParcelID"
		having bool_and(intersects))
-- Merge addresses to buildings
insert into mergedBuildings
select (count(*) over (partition by BuildingFootprint.gid)) as rn,
	BuildingFootprint.*,
	"Site_Address_Points".gid as addr_gid, "Place_Type",
	"Add_Number", "AddNum_Suf",
	"CompName",
	"Unit_Type", "Unit",
	"Inc_Muni", "Post_Code"
	from BuildingFootprint
	inner join Parcel
	on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
	inner join siteParcelsWithMatchingBuildings
	on Parcel.ParcelID=siteParcelsWithMatchingBuildings."ParcelID"
	inner join "Site_Address_Points"
	on siteParcelsWithMatchingBuildings."ParcelID"="Site_Address_Points"."ParcelID"
	and ST_Within("Site_Address_Points".geom_buildings, BuildingFootprint.geom);
-- Limit to buildings with only one intersecting address
delete from mergedBuildings where rn != 1;
delete from BuildingFootprint
	using mergedBuildings
	where BuildingFootprint.gid = mergedBuildings.gid;
delete from "Site_Address_Points"
	using mergedBuildings
	where "Site_Address_Points".gid = mergedBuildings.addr_gid;

-- Find parcels with a single name
drop table if exists namedParcels;
create table namedParcels as
with sites as (
	select "ParcelID", min("Addtl_Loc") as "Addtl_Loc"
		from "Site_Address_Points"
		where "Addtl_Loc" is not null
		group by "ParcelID"
		having count(distinct "Addtl_Loc")=1)
select "Addtl_Loc", cast (ST_Multi(ST_SimplifyPreserveTopology(Parcel.geom, 2)) as geometry(MultiPolygon, :BUILDINGS_SRID)) as geom,
	false as intersectsExisting,
	gid
	from sites
	join Parcel
	on Parcel.ParcelID=sites."ParcelID";
update namedParcels as p
	set intersectsExisting = true
	from osm_polygon
	where osm_polygon.landuse is not null
	and ST_Intersects(p.geom, osm_polygon.geom_buildings);

-- Develop cluster centers
drop table if exists clusterCenters;
create table clusterCenters as
	select cid, intersectsExisting, ST_Centroid(ST_Collect(geom)) as geom
		from (
			-- Generate clusters
			select ST_ClusterKMeans(geom, :PARTITIONS) over (partition by intersectsExisting) as cid,
				intersectsExisting, geom
				from (
					select geom_buildings as geom, intersectsExisting
						from "Site_Address_Points"
					union select geom, intersectsExisting
						from BuildingFootprint
					union select geom, intersectsExisting
						from mergedBuildings
				) as u
		) as c
		group by cid, intersectsExisting;

-- Find nearest cluster to each TAZ
drop table if exists taggedTaz;
create table taggedTaz as
	select cid, intersectsExisting, ST_Union(geom) as geom
		from (
			select (row_number() over (partition by VTATaz.gid, intersectsExisting order by ST_Distance(VTATaz.geom, clusterCenters.geom))) as rn,
				cid, intersectsExisting, VTATaz.geom
				from VTATaz
				join clusterCenters
				on ST_DWithin(VTATaz.geom, clusterCenters.geom, 444826) -- size of largest TAZ
		) as rankedTaz
		where rn=1
		group by cid, intersectsExisting;

-- Schema for all data that will be grouped before export
drop table if exists exportData;
create table exportData (
	gid integer,
	intersectsExisting boolean,
	cid integer,
	geom geometry(MultiPolygon, :BUILDINGS_SRID)
);
alter table BuildingFootprint add column cid integer;
alter table BuildingFootprint inherit exportData;

alter table mergedBuildings add column cid integer;
alter table mergedBuildings inherit exportData;

alter table namedParcels add column cid integer;
alter table namedParcels inherit exportData;

-- Assign cluster to each data point
update exportData as t
	set cid = taggedThing.cid
	from (
		select (row_number() over (partition by exportData.gid order by ST_Distance(exportData.geom, taggedTaz.geom))) as rn,
		taggedTaz.cid, exportData.gid
		from exportData
		join taggedTaz
		on ST_Intersects(exportData.geom, taggedTaz.geom)
		and exportData.intersectsExisting = taggedTaz.intersectsExisting
	) as taggedThing
	where t.gid = taggedThing.gid and rn = 1;

-- Addresses are a different geometry type on a different spatial reference, so need to be done separately
alter table "Site_Address_Points" add column cid integer;
update "Site_Address_Points" as a
	set cid = taggedAddr.cid
	from (
		select (row_number() over (partition by "Site_Address_Points".gid order by ST_Distance("Site_Address_Points".geom_buildings, taggedTaz.geom))) as rn,
		taggedTaz.cid, "Site_Address_Points".gid
		from "Site_Address_Points"
		join taggedTaz
		on ST_Intersects("Site_Address_Points".geom_buildings, taggedTaz.geom)
		and "Site_Address_Points".intersectsExisting = taggedTaz.intersectsExisting
	) as taggedAddr
	where a.gid = taggedAddr.gid and rn = 1;

