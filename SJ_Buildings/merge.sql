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
alter table "Site_Address_Points" alter column "CompName" type text;
alter table "Site_Address_Points" alter column "Unit_Type" type text;
alter table "Site_Address_Points" alter column "Unit" type text;
alter table "Site_Address_Points" alter column "Post_Code" type text;
alter table "Site_Address_Points" alter column "Place_Type" type text;
alter table "Site_Address_Points" alter column "Source" type text;
insert into "Site_Address_Points"
	("Add_Number", "CompName", "Unit_Type", "Unit", "Inc_Muni",
	 "Post_Code", "Place_Type", "Source", "ParcelID", geom)
	select
		array_to_string(array_agg(distinct "Add_Number"), ';'),
		array_to_string(array_agg(distinct "CompName"), ';'),
		array_to_string(array_agg(distinct "Unit_Type"), ';'),
		array_to_string(array_agg(distinct "Unit"), ';'),
		array_to_string(array_agg(distinct "Inc_Muni"), ';'),
		array_to_string(array_agg(distinct "Post_Code"), ';'),
		array_to_string(array_agg(distinct "Place_Type"), ';'),
		array_to_string(array_agg(distinct "Source"), ';'),
		"ParcelID",
		ST_Centroid(ST_Union(geom))
	from "Site_Address_Points"
	where clustered=true
	group by "ParcelID";
-- Delete old clusters
delete from "Site_Address_Points" where clustered=true;
alter table "Site_Address_Points" drop column clustered;

-- Find parcels with only one address
select "Add_Number", "CompName", "Unit_Type", "Unit", "Inc_Muni", "Post_Code",
	"FullAddres", "Place_Type", "Source", "Notes",
	parcel.geom, parcel.parcelid
	from parcel
	inner join (select "ParcelID"
		from "Site_Address_Points"
		group by "ParcelID"
		having count(*) = 1)
	as uniqParcel
	on cast (parcel.parcelid as int)=uniqParcel."ParcelID"
	inner join "Site_Address_Points"
	on "Site_Address_Points"."ParcelID"=uniqParcel."ParcelID"
	where "Site_Address_Points"."Unit_Type" is null or "Site_Address_Points"."Unit_Type"!='Apartment';

