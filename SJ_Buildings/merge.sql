delete from "Site_Address_Points"
	where "Status"='Unverified'
	or "Status"='Temporary'
	or "Status"='Retired';

-- likely stacked
delete from "Site_Address_Points"
	where "Unit_Type"='Basement'
	or "Unit_Type"='Upper';

-- Try to detect address "clusters"
delete from "Site_Address_Points" as addr1
	using "Site_Address_Points" as addr2
	where addr1."ParcelID" = addr2."ParcelID"
	and addr1.gid != addr2.gid
	--and not (addr1.geom = addr2.geom)
	and ST_DWithin(addr1.geom, addr2.geom, 11)
	and (abs(ST_X(addr1.geom) - ST_X(addr2.geom)) < 0.1
		or abs(ST_Y(addr1.geom) - ST_Y(addr2.geom)) < 0.1);

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
