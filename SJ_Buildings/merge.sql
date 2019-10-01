with filteredAddresses as
	(select * from "Site_Address_Points"
	  where ("Status"='Active' or "Status"='Existing') -- skip: Unverified, Temporary, Retired
		and ("Unit_Type" is null or
			 ("Unit_Type"!='Apartment' and "Unit_Type"!='Basement' and "Unit_Type"!='Upper'))) -- likely in the same building
select "Add_Number", "CompName", "Unit_Type", "Unit", "Inc_Muni", "Post_Code",
	"FullAddres", "Place_Type", "Source", "Notes",
	parcel.geom, parcel.parcelid
	from parcel
	inner join (select "ParcelID"
		from filteredAddresses
		group by "ParcelID"
		having count(*) = 1)
	as uniqParcel
	on cast (parcel.parcelid as int)=uniqParcel."ParcelID"
	inner join filteredAddresses
	on filteredAddresses."ParcelID"=uniqParcel."ParcelID";
