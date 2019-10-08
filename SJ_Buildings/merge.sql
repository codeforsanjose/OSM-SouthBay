delete from "Site_Address_Points"
	where "Status"='Unverified'
	or "Status"='Temporary'
	or "Status"='Retired';

-- Try to detect address "clusters"
alter table "Site_Address_Points" add column clustered boolean default false;
update "Site_Address_Points" as addr1
	set clustered=true
	from "Site_Address_Points" as addr2
	where addr1."ParcelID" = addr2."ParcelID"
	and addr1.gid != addr2.gid
	and (abs(ST_X(addr1.geom) - ST_X(addr2.geom)) < 0.1
		or abs(ST_Y(addr1.geom) - ST_Y(addr2.geom)) < 0.1);
-- Add entries for aggregated clustered addresses
alter table "Site_Address_Points" alter column "Add_Number" type text;
alter table "Site_Address_Points" alter column "Unit" type text;
insert into "Site_Address_Points"
	("Place_Type", "Add_Number", "CompName",
	 "Unit_Type", "Unit", "Inc_Muni", "Post_Code" "CondoParce", "ParcelID", geom)
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
create index on osm_polygon using GIST(loc_geom);

alter table osm_point add column loc_geom geometry(point, 103240);
update osm_point set loc_geom = ST_MakeValid(ST_Transform(way, 103240));
create index on osm_point using GIST(loc_geom);

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

alter table BuildingFootprint add column main boolean default false;
-- Find buildings that are the only one on a property
with soloBuildings as
	(select min(BuildingFootprint.gid) as gid
		from BuildingFootprint
		join Parcel
		on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
		and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
		group by ParcelID
		having count(*) = 1)
	update BuildingFootprint as bldg
	set main = true
	from soloBuildings
	where bldg.gid = soloBuildings.gid;

-- Find the largest building on each property
with sizeRankings as (
	select BuildingFootprint.gid as gid,
		ParcelID,
		ST_Area(BuildingFootprint.geom) as area,
		(row_number() over (partition by ParcelID order by ST_Area(BuildingFootprint.geom) desc)) as rn
		from BuildingFootprint
		inner join Parcel
		on ST_Intersects(BuildingFootprint.geom, Parcel.geom)
		and ST_Area(ST_Intersection(BuildingFootprint.geom, Parcel.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
		where not BuildingFootprint.main)
	update BuildingFootprint as bldg
	set main = true
	from sizeRankings as sz1, sizeRankings as sz2
	where bldg.gid = sz1.gid
	and sz1.ParcelID = sz2.ParcelID
	and sz1.rn=1
	and sz2.rn=2
	and sz1.gid != sz2.gid
	and sz1.area > sz2.area*2;

create table mergedBuildings as
	with addrParcels as (
		-- Find parcels with only one address
		select "Place_Type", "Add_Number",
				"CompName",
				"Unit_Type", "Unit", "Inc_Muni", "Post_Code",
				parcel.geom, parcel.ParcelID
			from Parcel
			inner join (select "ParcelID"
				from "Site_Address_Points"
				group by "ParcelID"
				where "Unit" is null
				or "Unit_Type" = 'Building'
				or "Unit_Type" = 'Space'
				or "Unit_Type" is null
				having count(*) = 1)
			as uniqParcel
			on cast (parcel.ParcelID as int)=uniqParcel."ParcelID"
			inner join "Site_Address_Points"
			on "Site_Address_Points"."ParcelID"=uniqParcel."ParcelID"
		)
		-- Assign address to main building on parcel
		select BuildingFootprint.*, addrParcels.ParcelID, addrParcels."Place_Type",
			addrParcels."Add_Number",
			addrParcels."CompName",
			addrParcels."Unit_Type", addrParcels."Unit",
			addrParcels."Inc_Muni",
			addrParcels."Post_Code"
		from BuildingFootprint
		inner join addrParcels
		on ST_Intersects(BuildingFootprint.geom, addrParcels.geom)
		and ST_Area(ST_Intersection(BuildingFootprint.geom, addrParcels.geom)) > 0.9*ST_Area(BuildingFootprint.geom)
		where BuildingFootprint.main;

-- Delete merged buildings from the other tables
delete from BuildingFootprint
	using mergedBuildings
	where BuildingFootprint.gid = mergedBuildings.gid;
delete from "Site_Address_Points"
	using mergedBuildings
	where "Site_Address_Points"."ParcelID" = cast (mergedBuildings.ParcelID as int);

