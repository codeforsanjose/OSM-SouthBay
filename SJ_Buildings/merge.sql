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
alter table "Site_Address_Points" alter column "Unit_Type" type text;
alter table "Site_Address_Points" alter column "Unit" type text;
alter table "Site_Address_Points" alter column "Post_Code" type text;
alter table "Site_Address_Points" alter column "Place_Type" type text;
insert into "Site_Address_Points"
	("Add_Number", "Unit_Type", "Unit", "Inc_Muni", "Post_Code", "Place_Type",
	 "CompName", "CondoParce", "ParcelID", geom)
	select
		array_to_string(array_agg(distinct "Add_Number"), ';'),
		array_to_string(array_agg(distinct "Unit_Type"), ';'),
		array_to_string(array_agg(distinct "Unit"), ';'),
		array_to_string(array_agg(distinct "Inc_Muni"), ';'),
		array_to_string(array_agg(distinct "Post_Code"), ';'),
		array_to_string(array_agg(distinct "Place_Type"), ';'),
		"CompName",
		"CondoParce",
		"ParcelID",
		ST_Centroid(ST_Union(geom))
	from "Site_Address_Points"
	where clustered=true
	group by "CompName", "CondoParce", "ParcelID";
-- Delete old clusters
delete from "Site_Address_Points" where clustered=true;
alter table "Site_Address_Points" drop column clustered;


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

with addrParcels as (
	-- Find parcels with only one address
	select "Add_Number", "CompName", "Unit_Type", "Unit", "Inc_Muni", "Post_Code",
		"FullAddres", "Place_Type",
		parcel.geom, parcel.ParcelID
		from Parcel
		inner join (select "ParcelID"
			from "Site_Address_Points"
			group by "ParcelID"
			having count(*) = 1)
		as uniqParcel
		on cast (parcel.ParcelID as int)=uniqParcel."ParcelID"
		inner join "Site_Address_Points"
		on "Site_Address_Points"."ParcelID"=uniqParcel."ParcelID"
		where "Site_Address_Points"."Unit_Type" is null or "Site_Address_Points"."Unit_Type"!='Apartment'
	)
	-- Assign address to main building on parcel
	select BuildingFootprint.*, addrParcels.ParcelID,
		addrParcels."Add_Number", addrParcels."CompName",
		addrParcels."Unit_Type", addrParcels."Unit", addrParcels."Inc_Muni",
		addrParcels."Post_Code", addrParcels."FullAddres", addrParcels."Place_Type"
	into table mergedBuildings
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

