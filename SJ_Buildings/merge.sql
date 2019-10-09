delete from "Site_Address_Points"
	where "Status"='Unverified'
	or "Status"='Temporary'
	or "Status"='Retired';

create index if not exists "Site_Address_Points_ParcelID_idx"
on "Site_Address_Points" ("ParcelID");

-- Try to detect address "clusters"
alter table "Site_Address_Points" add column clustered boolean default false;
update "Site_Address_Points" as addr1
	set clustered=true
	from "Site_Address_Points" as addr2
	where addr1."ParcelID" = addr2."ParcelID"
	and addr1.gid != addr2.gid
	and ST_DWithin(addr1.geom, addr2.geom, 10.1)
	and (ST_X(addr1.geom) = ST_X(addr2.geom)
		or ST_Y(addr1.geom) = ST_Y(addr2.geom));
-- Add entries for aggregated clustered addresses
alter table "Site_Address_Points" alter column "Add_Number" type text;
alter table "Site_Address_Points" alter column "Unit" type text;
insert into "Site_Address_Points"
	("Place_Type", "Add_Number", "CompName",
	 "Unit_Type", "Unit", "Inc_Muni", "Post_Code", "CondoParce", "ParcelID", geom)
	select
		"Place_Type",
		array_to_string(array_agg(distinct "Add_Number"), ';'),
		"CompName",
		"Unit_Type",
		array_to_string(array_agg(distinct "Unit"), ';'),
		"Inc_Muni", "Post_Code",
		"CondoParce", "ParcelID",
		ST_Centroid(ST_Collect(geom))
	from "Site_Address_Points"
	where clustered=true
	group by "Place_Type",
		"CompName",
		"Unit_Type",
		"Inc_Muni", "Post_Code",
		"CondoParce", "ParcelID";
-- Delete old clusters
delete from "Site_Address_Points" where clustered=true;
alter table "Site_Address_Points" drop column clustered;

-- Project OSM data to local coordinates
-- (losing accuracy is okay because it's only for conflation)
alter table osm_polygon add column loc_geom geometry(multipolygon, 103240);
update osm_polygon set loc_geom = ST_MakeValid(ST_Transform(ST_Multi(way), 103240));
create index if not exists on osm_polygon using GIST(loc_geom);

alter table osm_point add column loc_geom geometry(point, 103240);
update osm_point set loc_geom = ST_MakeValid(ST_Transform(way, 103240));
create index if not exists on osm_point using GIST(loc_geom);

-- Find data that already exist in OSM, to split for later conflation
alter table BuildingFootprint add column intersectsExisting boolean default false;
update BuildingFootprint as bldg
	set intersectsExisting = true
	from osm_polygon
	where osm_polygon.building is not null
	and osm_polygon.building != 'no'
	and ST_Intersects(bldg.geom, osm_polygon.loc_geom);

alter table "Site_Address_Points" add column intersectsExisting boolean default false;
update "Site_Address_Points" as addr
	set intersectsExisting = true
	from osm_point
	where osm_point.highway is null
	and ST_DWithin(addr.geom, osm_point.loc_geom, 80);
update "Site_Address_Points" as addr
	set intersectsExisting = true
	from osm_polygon
	where osm_polygon.landuse is null
	and osm_polygon.natural is null
	and ST_DWithin(addr.geom, osm_polygon.loc_geom, 80);

-- For each parcel where there is only one address, find all buildings on the parcel
drop table if exists mergedBuildings;
create table mergedBuildings as
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
select (row_number() over (partition by ParcelID order by ST_Distance("Site_Address_Points".geom, BuildingFootprint.geom))) as rn,
BuildingFootprint.*,
"Site_Address_Points".gid as addr_gid,
ParcelID, "Place_Type",
"Add_Number",
"CompName",
"Unit_Type", "Unit",
"Inc_Muni",
"Post_Code"
from BuildingFootprint
inner join Parcel
on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
inner join uniqParcel
on cast (Parcel.ParcelID as int)=uniqParcel."ParcelID"
inner join "Site_Address_Points"
on uniqParcel."ParcelID"="Site_Address_Points"."ParcelID"
and ("Unit" is null
	or "Unit" like '%;%'
	or "Unit_Type" = 'Building'
	or "Unit_Type" = 'Space'
	or "Unit_Type" is null);
-- Merge the address with the building closest to the address
delete from mergedBuildings where rn != 1;

-- Delete merged buildings from the other tables
delete from BuildingFootprint
	using mergedBuildings
	where BuildingFootprint.gid = mergedBuildings.gid;
delete from "Site_Address_Points"
	using mergedBuildings
	where "Site_Address_Points".gid = mergedBuildings.addr_gid;

