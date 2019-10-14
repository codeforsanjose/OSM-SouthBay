-- Sample region
/*delete from BuildingFootprint
	where not geom && ST_SetSRID(ST_MakeBox2D(ST_Point(6161510, 1914285), ST_Point(6167021, 1919180)), 103240);
delete from "Site_Address_Points"
	where not geom && ST_SetSRID(ST_MakeBox2D(ST_Point(6161510, 1914285), ST_Point(6167021, 1919180)), 103240);*/

delete from "Site_Address_Points"
	where "Status"='Unverified'
	or "Status"='Temporary'
	or "Status"='Retired';

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
	and (ST_X(addr1.geom) = ST_X(addr2.geom)
		or ST_Y(addr1.geom) = ST_Y(addr2.geom));
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

-- For each condo area where there is only one address, find all buildings in the condo area
drop table if exists mergedBuildings;
create table mergedBuildings as
with uniqParcel as (
	select "CondoParce"
	from "Site_Address_Points"
	group by "CondoParce"
	having count(*) = 1)
select (row_number() over (partition by CondoParce order by ST_Distance("Site_Address_Points".geom, BuildingFootprint.geom))) as rn,
	BuildingFootprint.*,
	"Site_Address_Points".gid as addr_gid, "Place_Type",
	"Add_Number", "AddNum_Suf",
	"CompName",
	"Unit_Type", "Unit",
	"Inc_Muni", "Post_Code"
	from BuildingFootprint
	inner join CondoParcel
	on ST_Intersects(BuildingFootprint.geom, CondoParcel.geom)
	and ST_Area(ST_Intersection(BuildingFootprint.geom, CondoParcel.geom)) > 0.7*ST_Area(BuildingFootprint.geom)
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
select (row_number() over (partition by ParcelID order by ST_Distance("Site_Address_Points".geom, BuildingFootprint.geom))) as rn,
	BuildingFootprint.*,
	"Site_Address_Points".gid as addr_gid, "Place_Type",
	"Add_Number", "AddNum_Suf",
	"CompName",
	"Unit_Type", "Unit",
	"Inc_Muni", "Post_Code"
	from BuildingFootprint
	inner join Parcel
	on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
	and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
	inner join uniqParcel
	on Parcel.ParcelID=uniqParcel."ParcelID"
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
			and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
			group by ParcelID)
		select parcelAddrs.ParcelID
			from parcelAddrs
			inner join parcelBuildings
			on parcelAddrs.ParcelID=parcelBuildings.ParcelID
			where buildingCount > addrCount)
	select "Site_Address_Points"."ParcelID" from
		-- Find addresses that intersect any building in the parcel
		(select bool_or(ST_Within("Site_Address_Points".geom, BuildingFootprint.geom)) as intersects, "Site_Address_Points".gid
			from siteParcels
			inner join "Site_Address_Points"
			on ParcelID="ParcelID"
			inner join Parcel
			on siteParcels.ParcelID=Parcel.ParcelID
			inner join BuildingFootprint
			on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
			and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
			group by "Site_Address_Points".gid, "Site_Address_Points"."FullAddres") as addrsOnBuildings
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
	and ST_Within("Site_Address_Points".geom, BuildingFootprint.geom);
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
select "Addtl_Loc", ST_SimplifyPreserveTopology(ST_Force2D(Parcel.geom), 2) as geom, false as intersectsExisting
	from sites
	join Parcel
	on Parcel.ParcelID=sites."ParcelID";
update namedParcels as p
	set intersectsExisting = true
	from osm_polygon
	where osm_polygon.landuse is not null
	and ST_Intersects(p.geom, osm_polygon.loc_geom);

