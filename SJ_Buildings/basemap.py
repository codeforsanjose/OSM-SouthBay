def filterLayer(layer):
    if layer is None:
        print("filterLayer: empty")
        return None
    
    print(layer.GetName())
    
    #if layer.GetName() in ["buildingfootprint", "Site_Address_Points", "mergedbuildings", "namedparcels"]:
    if layer.GetName() in ["buildingfootprint_filtered", "Site_Address_Points_filtered", "mergedbuildings_filtered", "namedparcels_filtered"]:
        return layer

def mergeToRanges(ls):
    """ Takes a list like ['1', '2', '3', '5', '8', 9'] and returns a list like
    ['1-3', '5', '8', '9'] """
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

# I don't actually know if the building heights are in US standard feet or
# survey feet. But the difference is less than the significant digits for the
# tallest building.
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
            m = max(map(len, addr))
            addr.sort(key=lambda a: a.rjust(m))
            addr = ';'.join(mergeToRanges(addr))
            if attrs["AddNum_Suf"]:
                addr += " " + attrs["AddNum_Suf"]
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
            m = max(map(len, units))
            units.sort(key=lambda a: a.rjust(m))
            units = ';'.join(mergeToRanges(units))
            tags["addr:unit"] = units
        
        zipcode = attrs["Post_Code"]
        if zipcode: tags["addr:postcode"] = zipcode

        pt = attrs["Place_Type"]
        #if pt == "BU":
            #tags["office"] = "yes"
        if pt == "ED":
            tags["amenity"] = "school"
        elif pt == "FB":
            tags["amenity"] = "place_of_worship"
        elif pt == "GO":
            tags["office"] = "government"
        elif pt == "GQ":
            # Salvation army
            tags["amenity"] = "social_facility"
        elif pt == "HS":
            tags["amenity"] = "hospital"
        elif pt == "HT" and not units:
            tags["tourism"] = "hotel"
        elif pt == "RE":
            tags["club"] = "sport"
        elif pt == "RT":
            tags["amenity"] = "restaurant"
        elif pt == "RL":
            tags["shop"] = "yes"
        elif pt == "TR":
            tags["public_transport"] = "platform"

        # Always appear, no equivalent: OBJECTID, Site_NGUID, ESN, Lat, Long, Status, Juris_Auth, LastUpdate, LastEditor, GlobalID
        # FullMailin could be used for addr:full, but it's unneeded.
        # Sometimes appear, no equivalent: RCL_NGUID, StreetMast, ParcelID, CondoParce, UnitID, RSN, PSAP_ID, St_PreDirA, St_PreTyp, StreetName, St_PosTyp, St_PosTypC, St_PosTypU, St_PosDir, Feanme, FullName, Unit_Type, Building, FullUnit, FullAddres, Addtl_Loc, LSt_PreDir, LSt_Name, LSt_Type, Uninc_Comm, Post_Comm, Source, Effective, Notes
        # Always the same: Client_ID, County, State, Country, Placement
        # Always empty: Site_NGU00, AddNum_Pre, St_PreMod, St_PreDir, St_PreSep, St_PosMod, Floor, Room, Seat, Post_Code4, APN, LStPostDir, AddCode, AddDataURI, Nbrhd_Comm, MSAGComm, LandmkName, Mile_Post, Elev, Expire
    
    if "Inc_Muni" in attrs and "bldgelev" in attrs:
        # Merged address/buildings
        # other Place_Type are Common Area (multi-use), Miscellaneous
        tags["building"] = {"BU": "commercial",
                            "ED": "school",
                            "FB": "religious",
                            "GO": "government",
                            "HS": "hospital",
                            "HT": "hotel",
                            "MH": "static_caravan",
                            "Condominium": "residential",
                            "MF": "residential",
                            "RL": "retail",
                            "RT": "retail",
                            "SF": "house"}.get(attrs["Place_Type"], "yes")
    
    if "Addtl_Loc" in attrs and "Inc_Muni" not in attrs:
        # Named parcels
        tags["landuse"] = "residential"
        tags["name"] = attrs["Addtl_Loc"].title()
    
    return tags

