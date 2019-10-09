def filterLayer(layer):
    if layer is None:
        print("filterLayer: empty")
        return None
    
    print(layer.GetName())
    
    if layer.GetName() in ["buildingfootprint", "Site_Address_Points", "mergedbuildings", ""]:
        return layer

def mergeToRanges(ls):
    if len(ls) < 2:
        return ls
    i = 0
    while i < len(ls)-1 and \
        ((ls[i].isdigit() and ls[i+1].isdigit() and \
          int(ls[i])+1 == int(ls[i+1])) or \
         (len(ls[i]) == 1 and len(ls[i+1]) == 1 and \
          ord(ls[i])+1 == ord(ls[i+1]))):
        i += 1
    if i < 2:
        return ls[0:i+1]+mergeToRanges(ls[i+1:])
    else:
        return [ls[0]+'-'+ls[i]]+mergeToRanges(ls[i+1:])

SURVEY_FEET_TO_METER = 1200.0/3937.0

def filterTags(attrs):
    if attrs is None:
        print("filterTags: empty")
        return None
    
    tags = {}

    if "bldgelev" in attrs:
        # BuildingFootprint
        tags["building"] = "yes"
        # Always appear, has equivalent
        tags["height"] = "%.02f"%round(float(attrs["bldgheight"])*SURVEY_FEET_TO_METER, 2)
        tags["ele"] = "%.02f"%round(float(attrs["bldgelev"])*SURVEY_FEET_TO_METER, 2)
        
        # Always appear, no equivalent: FACILITYID
        # Sometimes appear, no equivalent: LASTUPDATE
        # Empty: LENGTH, SHAPE_AREA
    
    if "Inc_Muni" in attrs:
        # Site_Address_Points
        # Always appear, has equivalent
        tags["addr:city"] = attrs["Inc_Muni"]

        # Sometimes appear, has equivalent
        addr = attrs["Add_Number"]
        if addr:
            addr = addr.split(';')
            addr = ';'.join(mergeToRanges(addr))
            tags["addr:housenumber"] = addr
        
        street = attrs["CompName"]
        if street:
            if street.startswith("St "): street = "Saint"+street[2:]
            elif street.startswith("Mt "): street = "Mount"+street[2:]
            elif street.startswith("East St "): street = "East Saint"+street[7:]
            elif street.startswith("West St "): street = "West Saint"+street[7:]
            tags["addr:street"] = street
        
        units = attrs["Unit"]
        if units:
            units = units.split(';')
            units = ';'.join(mergeToRanges(units))
            tags["addr:unit"] = units
        
        zipcode = attrs["Post_Code"]
        if zipcode: tags["addr:postcode"] = zipcode

        pt = attrs["Place_Type"]
        #if pt == "Business":
            #tags["office"] = "yes"
        if pt == "Educational":
            tags["amenity"] = "school"
        elif pt == "Faith Based Organiz":
            tags["amenity"] = "place_of_worship"
        elif pt == "Government":
            tags["office"] = "government"
        elif pt == "Group Quarters":
            # salvation army
            tags["amenity"] = "social_facility"
        elif pt == "Hospital":
            tags["amenity"] = "hospital"
        elif pt == "Hotel":
            tags["tourism"] = "hotel"
        elif pt == "Recreational":
            tags["club"] = "sport"
        elif pt == "Restaurant":
            tags["amenity"] = "restaurant"
        elif pt == "Retail":
            tags["shop"] = "yes"

        # Always appear, no equivalent: Site_NGUID, ESN, Status, Juris_Auth, LastUpdate, LastEditor
        # Sometimes appear, no equivalent: RCL_NGUID, StreetMast, ParcelID, CondoParce, UnitID, RSN, PSAP_ID, AddNum_Suf, Unit_Type, Building, FullUnit, Addtl_Loc, LSt_Name, LSt_Type, Uninc_Comm, Effective
        # Always the same: Client_ID, County, State, Country, Placement, Post_Comm
        # Not used here: FullMailin, Lat, Long, GlobalID, FullAddres
        # Street name parts, could be used in a relation: St_PreDirA, St_PreTyp, StreetName, St_PosTyp, St_PosTypC, St_PosTypU, St_PosDir, Feanme, FullName
        # Empty: Site_NGU00, AddNum_Pre, St_PreMod, St_PreDir, St_PreSep, St_PosMod, Floor, Room, Seat, Post_Code4, APN, LStPostDir, AddCode, AddDataURI, Nbrhd_Comm, MSAGComm, LandmkName, Mile_Post, Elev, Expire
    
    if "Place_Type" in attrs and "bldgelev" in attrs:
        # other Place_Type are Common Area (multi-use), Miscellaneous
        tags["building"] = {"Business": "commercial",
                            "Educational": "school",
                            "Faith Based Organiz": "religious",
                            "Government": "government",
                            "Hospital": "hospital",
                            "Hotel": "hotel",
                            "Mobile Home": "static_caravan",
                            "Multi Family": "residential",
                            "Restaurant": "retail",
                            "Retail": "retail",
                            "Single Family": "house"}.get(attrs["Place_Type"], "yes")
    
    return tags

