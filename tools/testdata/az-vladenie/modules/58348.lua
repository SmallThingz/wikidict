local u = mw.ustring.char

-- UTF-8 encoded strings for some commonly-used diacritics
local GRAVE     = u(0x0300)
local ACUTE     = u(0x0301)
local CIRC      = u(0x0302)
local TILDE     = u(0x0303)
local MACRON    = u(0x0304)
local BREVE     = u(0x0306)
local DOTABOVE  = u(0x0307)
local DIAER     = u(0x0308)
local CARON     = u(0x030C)
local DGRAVE    = u(0x030F)
local INVBREVE  = u(0x0311)
local DOTBELOW  = u(0x0323)
local RINGBELOW = u(0x0325)
local CEDILLA   = u(0x0327)

local m = {}

m["daa"] = {
	canonicalName = "Dangaléat",
	otherNames = {"Dangaleat", "Dangla", "Danal", "Dangal"},
	family = "cdc",
}

m["dac"] = {
	canonicalName = "Dambi",
	family = "poz-ocw",
}

m["dad"] = {
	canonicalName = "Marik",
	family = "poz-ocw",
}

m["dae"] = {
	canonicalName = "Duupa",
}

m["dag"] = {
	canonicalName = "Dagbani",
}

m["dah"] = {
	canonicalName = "Gwahatike",
	family = "ngf-fin",
}

m["dai"] = {
	canonicalName = "Day",
}

m["daj"] = {
	canonicalName = "Dar Fur Daju",
	family = "sdv",
}

m["dak"] = {
	canonicalName = "Dakota",
	scripts = {"Latn"},
	family = "sio",
}

m["dal"] = {
	canonicalName = "Dahalo",
	family = "cus",
}

m["dam"] = {
	canonicalName = "Damakawa",
}

m["dao"] = {
	canonicalName = "Daai Chin",
	family = "tbq-kuk",
}

m["daq"] = {
	canonicalName = "Dandami Maria",
	otherNames = {"Bison-Horn Maria", "Madia", "Madiya", "Maria (India)", "Maria"}, -- the last four are also names of daq's sibling lect, mrr
	family = "dra",
	ancestors = {"gon"},
}

m["dar"] = {
	canonicalName = "Dargwa",
	otherNames = {"Dargin"},
	scripts = {"Cyrl"},
	family = "cau-drg",
	translit_module = "dar-translit",
}

m["das"] = {
	canonicalName = "Daho-Doo",
}

m["dau"] = {
	canonicalName = "Dar Sila Daju",
	family = "sdv",
}

m["dav"] = {
	canonicalName = "Taita",
}

m["daw"] = {
	canonicalName = "Davawenyo",
}

m["dax"] = {
	canonicalName = "Dayi",
	family = "aus-yol",
}

m["daz"] = {
	canonicalName = "Dao",
}

m["dba"] = {
	canonicalName = "Bangi Me",
}

m["dbb"] = {
	canonicalName = "Deno",
	family = "cdc",
}

m["dbd"] = {
	canonicalName = "Dadiya",
}

m["dbe"] = {
	canonicalName = "Dabe",
}

m["dbf"] = {
	canonicalName = "Edopi",
	otherNames = {"Elopi"},
	family = "paa-lkp",
}

m["dbg"] = {
	canonicalName = "Dogul Dom",
	otherNames = {"Dogul Dom Dogon"},
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dbi"] = {
	canonicalName = "Doka",
}

m["dbj"] = {
	canonicalName = "Ida'an",
	scripts = {"Latn"},
	family = "poz-san",
}

m["dbl"] = {
	canonicalName = "Dyirbal",
	scripts = {"Latn"},
	family = "aus-dyb",
}

m["dbm"] = {
	canonicalName = "Duguri",
}

m["dbn"] = {
	canonicalName = "Duriankere",
}

m["dbo"] = {
	canonicalName = "Dulbu",
}

m["dbp"] = {
	canonicalName = "Duwai",
}

m["dbq"] = {
	canonicalName = "Daba",
}

m["dbr"] = {
	canonicalName = "Dabarre",
	family = "cus",
}

m["dbt"] = {
	canonicalName = "Ben Tey",
	otherNames = {"Ben Tey Dogon"},
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dbu"] = {
	canonicalName = "Bondum Dom Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dbv"] = {
	canonicalName = "Dungu",
}

m["dbw"] = {
	canonicalName = "Bankan Tey Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dby"] = {
	canonicalName = "Dibiyaso",
}

m["dcc"] = {
	canonicalName = "Deccan",
	otherNames = {"Dakhini", "Dakkhani", "Deccani"},
	scripts = {"ur-Arab"},
	family = "inc",
	ancestors = {"psu"},
}

m["dcr"] = {
	canonicalName = "Negerhollands",
	scripts = {"Latn"},
	family = "crp",
}

m["dda"] = {
	canonicalName = "Dadi Dadi",
	otherNames = {"Dardi Dardi", "Tati Tati", "Dadi-Dadi", "Dardi-Dardi", "Tati-Tati"},
	family = "aus-pam",
}

m["ddd"] = {
	canonicalName = "Dongotono",
	family = "sdv",
}

m["dde"] = {
	canonicalName = "Doondo",
}

m["ddg"] = {
	canonicalName = "Fataluku",
}

m["ddi"] = {
	canonicalName = "Diodio",
	family = "poz-ocw",
}

m["ddj"] = {
	canonicalName = "Jaru",
}

m["ddn"] = {
	canonicalName = "Dendi",
	otherNames = {"Dandawa", "Dendi (West Africa)", "Dendi (Benin)"},
	scripts = {"Latn"},
	family = "son",
}

m["ddo"] = {
	canonicalName = "Tsez",
	otherNames = {"Tsezi", "Dido"},
	scripts = {"Cyrl"},
	family = "cau-tsz",
}

m["ddr"] = {
	canonicalName = "Dhudhuroa",
	otherNames = {"Yaitmathang"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["dds"] = {
	canonicalName = "Donno So Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["ddw"] = {
	canonicalName = "Dawera-Daweloor",
}

m["dec"] = {
	canonicalName = "Dagik",
}

m["ded"] = {
	canonicalName = "Dedua",
}

m["dee"] = {
	canonicalName = "Dewoin",
}

m["def"] = {
	canonicalName = "Dezfuli",
	family = "ira",
}

m["deg"] = {
	canonicalName = "Degema",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["deh"] = {
	canonicalName = "Dehwari",
}

m["dei"] = {
	canonicalName = "Demisa",
}

m["dek"] = {
	canonicalName = "Dek",
}

m["dem"] = {
	canonicalName = "Dem",
}

m["den"] = {
	canonicalName = "Slavey",
	otherNames = {"Slave", "Slavé"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["dep"] = {
	canonicalName = "Pidgin Delaware",
	scripts = {"Latn"},
	family = "crp",
}

m["der"] = {
	canonicalName = "Deori",
}

m["des"] = {
	canonicalName = "Desano",
	family = "sai-tuc",
}

m["dev"] = {
	canonicalName = "Domung",
	family = "ngf-fin",
}

m["dez"] = {
	canonicalName = "Dengese",
}

m["dga"] = {
	canonicalName = "Southern Dagaare",
	scripts = {"Latn"},
	family = "nic-gur",
}

m["dgb"] = {
	canonicalName = "Bunoge",
	otherNames = {"Bunoge Dogon"},
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dgc"] = {
	canonicalName = "Casiguran Dumagat Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["dgd"] = {
	canonicalName = "Dagaari Dioula",
	scripts = {"Latn"},
	family = "nic-gur",
}

m["dge"] = {
	canonicalName = "Degenan",
	family = "ngf-fin",
}

m["dgg"] = {
	canonicalName = "Doga",
	family = "poz-ocw",
}

m["dgh"] = {
	canonicalName = "Dghwede",
}

m["dgi"] = {
	canonicalName = "Northern Dagara",
	scripts = {"Latn"},
	family = "nic-gur",
}

m["dgk"] = {
	canonicalName = "Dagba",
}

m["dgn"] = {
	canonicalName = "Dagoman",
}

m["dgo"] = {
	canonicalName = "Hindi Dogri",
}

m["dgr"] = {
	canonicalName = "Dogrib",
	otherNames = {"Tłicho", "Tlinchon"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["dgs"] = {
	canonicalName = "Dogoso",
}

m["dgt"] = {
	canonicalName = "Ntra'ngith",
	otherNames = {"Ndra'ngith"},
	family = "aus-pam",
}

m["dgu"] = {
	canonicalName = "Degaru",
}

m["dgw"] = {
	canonicalName = "Daungwurrung",
	otherNames = {"Taungurong", "Dhagung-wurrung", "Thagungwurrung"},
	family = "aus-pam",
}

m["dgx"] = {
	canonicalName = "Doghoro",
}

m["dgz"] = {
	canonicalName = "Daga",
}

m["dhg"] = {
	canonicalName = "Dhangu",
	family = "aus-yol",
}

m["dhi"] = {
	canonicalName = "Dhimal",
}

m["dhl"] = {
	canonicalName = "Dhalandji",
	family = "aus-psw",
}

m["dhm"] = {
	canonicalName = "Zemba",
}

m["dhn"] = {
	canonicalName = "Dhanki",
}

m["dho"] = {
	canonicalName = "Dhodia",
}

m["dhr"] = {
	canonicalName = "Tharrgari",
	otherNames = {"Dhargari"},
	scripts = {"Latn"},
	family = "aus-psw",
}

m["dhs"] = {
	canonicalName = "Dhaiso",
}

m["dhu"] = {
	canonicalName = "Dhurga",
}

m["dhv"] = {
	canonicalName = "Drehu",
	family = "poz-occ",
}

m["dhw"] = {
	canonicalName = "Danuwar",
	otherNames = {"Danwar", "Dhanwar", "Rai"},
	scripts = {"Deva"},
	family = "inc",
}

m["dhx"] = {
	canonicalName = "Dhungaloo",
}

m["dia"] = {
	canonicalName = "Dia",
	family = "qfa-tor",
}

m["dib"] = {
	canonicalName = "South Central Dinka",
	family = "sdv",
}

m["dic"] = {
	canonicalName = "Lakota Dida",
}

m["did"] = {
	canonicalName = "Didinga",
	family = "sdv",
}

m["dif"] = {
	canonicalName = "Dieri",
	otherNames = {"Diyari", "Dirari"},
	scripts = {"Latn"},
	family = "aus-kar",
}

m["dig"] = {
	canonicalName = "Digo",
	otherNames = {"Chidigo"},
	scripts = {"Latn"},
	family = "bnt",
}

m["dih"] = {
	canonicalName = "Kumiai",
	otherNames = {"Kumeyaay", "Diegueño"},
	scripts = {"Latn"},
	family = "nai-yuc",
}

m["dii"] = {
	canonicalName = "Dimbong",
}

m["dij"] = {
	canonicalName = "Dai",
}

m["dik"] = {
	canonicalName = "Southwestern Dinka",
	family = "sdv",
}

m["dil"] = {
	canonicalName = "Dilling",
	scripts = {"Latn"},
	family = "nub",
}

m["dim"] = {
	canonicalName = "Dime",
}

m["din"] = {
	canonicalName = "Dinka",
	scripts = {"Latn"},
	family = "sdv",
}

m["dio"] = {
	canonicalName = "Dibo",
}

m["dip"] = {
	canonicalName = "Northeastern Dinka",
	family = "sdv",
}

m["dir"] = {
	canonicalName = "Dirim",
}

m["dis"] = {
	canonicalName = "Dimasa",
	scripts = {"Latn", "Beng"},
	family = "sit",
}

m["diu"] = {
	canonicalName = "Gciriku",
	otherNames = {"Rumanyo", "Dirico", "Dciriku", "Diriku", "Rugciriku"},
}

m["diw"] = {
	canonicalName = "Northwestern Dinka",
	family = "sdv",
}

m["dix"] = {
	canonicalName = "Dixon Reef",
	family = "poz-vnc",
}

m["diy"] = {
	canonicalName = "Diuwe",
}

m["diz"] = {
	canonicalName = "Ding",
}

m["dja"] = {
	canonicalName = "Djadjawurrung",
	otherNames = {"Dja dja wurrung"},
	family = "aus-pam",
}

m["djb"] = {
	canonicalName = "Djinba",
	family = "aus-yol",
}

m["djc"] = {
	canonicalName = "Dar Daju Daju",
	family = "sdv",
}

m["djd"] = {
	canonicalName = "Djamindjung",
}

m["dje"] = {
	canonicalName = "Zarma",
}

m["djf"] = {
	canonicalName = "Djangun",
}

m["dji"] = {
	canonicalName = "Djinang",
}

m["djj"] = {
	canonicalName = "Djeebbana",
	family = "aus-arn",
}

m["djk"] = {
	canonicalName = "Aukan",
	otherNames = {"Ndyuka"},
	scripts = {"Latn", "Afak"},
	family = "crp",
}

m["djl"] = {
	canonicalName = "Djiwarli",
	family = "aus-psw",
}

m["djm"] = {
	canonicalName = "Jamsay",
	otherNames = {"Jamsay Dogon", "Jamsai"},
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["djn"] = {
	canonicalName = "Djauan",
	family = "aus-gun",
}

m["djo"] = {
	canonicalName = "Jangkang",
}

m["djr"] = {
	canonicalName = "Djambarrpuyngu",
	family = "aus-yol",
}

m["dju"] = {
	canonicalName = "Kapriman",
}

m["djw"] = {
	canonicalName = "Djawi",
}

m["dka"] = {
	canonicalName = "Dakpa",
	otherNames = {"Dakpakha", "Takpa", "Tawang Monpa"},
	scripts = {"Tibt"},
	family = "tbq",
}

m["dkk"] = {
	canonicalName = "Dakka",
}

m["dkr"] = {
	canonicalName = "Kuijau",
}

m["dks"] = {
	canonicalName = "Southeastern Dinka",
}

m["dkx"] = {
	canonicalName = "Mazagway",
}

m["dlg"] = {
	canonicalName = "Dolgan",
	scripts = {"Cyrl"},
	family = "trk",
}

m["dlk"] = {
	canonicalName = "Dahalik",
}

m["dlm"] = {
	canonicalName = "Dalmatian",
	otherNames = {"Dalmatic"},
	scripts = {"Latn"},
	family = "roa",
}

m["dln"] = {
	canonicalName = "Darlong",
}

m["dma"] = {
	canonicalName = "Duma",
}

m["dmb"] = {
	canonicalName = "Mombo Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dmc"] = {
	canonicalName = "Dimir",
}

m["dmd"] = {
	canonicalName = "Madhi Madhi",
	otherNames = {"Madhi-Madhi", "Madi Madi", "Madi-Madi", "Muthimuthi"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["dme"] = {
	canonicalName = "Dugwor",
}

m["dmg"] = {
	canonicalName = "Upper Kinabatangan",
}

m["dmk"] = {
	canonicalName = "Domaaki",
}

m["dml"] = {
	canonicalName = "Dameli",
}

m["dmm"] = {
	canonicalName = "Dama",
}

m["dmo"] = {
	canonicalName = "Kemezung",
	family = "nic-bod",
}

m["dmr"] = {
	canonicalName = "East Damar",
	family = "plf",
}

m["dms"] = {
	canonicalName = "Dampelas",
}

m["dmu"] = {
	canonicalName = "Dubu",
}

m["dmv"] = {
	canonicalName = "Dumpas",
}

m["dmw"] = {
	canonicalName = "Mudburra",
	otherNames = {"Mudbura"},
	scripts = {"Latn"},
}

m["dmx"] = {
	canonicalName = "Dema",
}

m["dmy"] = {
	canonicalName = "Demta",
}

m["dna"] = {
	canonicalName = "Upper Grand Valley Dani",
}

m["dnd"] = {
	canonicalName = "Daonda",
}

m["dne"] = {
	canonicalName = "Ndendeule",
}

m["dng"] = {
	canonicalName = "Dungan",
	scripts = {"Cyrl"},
	family = "zhx",
	ancestors = {"cmn"},
}

m["dni"] = {
	canonicalName = "Lower Grand Valley Dani",
}

m["dnj"] = {
	canonicalName = "Dan",
	family = "dmn",
}

m["dnk"] = {
	canonicalName = "Dengka",
	family = "plf",
}

m["dnn"] = {
	canonicalName = "Dzuun",
	otherNames = {"Dzùùn", "Dzuungoo", "Dzùùngoo"},
}

m["dnr"] = {
	canonicalName = "Danaru",
}

m["dnt"] = {
	canonicalName = "Mid Grand Valley Dani",
}

m["dnu"] = {
	canonicalName = "Danau",
	family = "aav",
}

m["dnv"] = {
	canonicalName = "Danu",
	family = "tbq",
}

m["dnw"] = {
	canonicalName = "Western Dani",
}

m["dny"] = {
	canonicalName = "Dení",
	family = "auf",
}

m["doa"] = {
	canonicalName = "Dom",
}

m["dob"] = {
	canonicalName = "Dobu",
	family = "poz-ocw",
}

m["doe"] = {
	canonicalName = "Doe",
}

m["dof"] = {
	canonicalName = "Domu",
}

m["doh"] = {
	canonicalName = "Dong",
}

m["doi"] = {
	canonicalName = "Dogri",
	scripts = {"Deva", "Takr", "fa-Arab"},
	family = "inc",
}

m["dok"] = {
	canonicalName = "Dondo",
}

m["dol"] = {
	canonicalName = "Doso",
}

m["don"] = {
	canonicalName = "Doura",
	family = "poz-ocw",
}

m["doo"] = {
	canonicalName = "Dongo",
	family = "nic-ubg",
}

m["dop"] = {
	canonicalName = "Lukpa",
}

m["doq"] = {
	canonicalName = "Dominican Sign Language",
	family = "sgn",
}

m["dor"] = {
	canonicalName = "Dori'o",
	family = "poz-sls",
}

m["dos"] = {
	canonicalName = "Dogosé",
}

m["dot"] = {
	canonicalName = "Dass",
}

m["dov"] = {
	canonicalName = "Dombe",
}

m["dow"] = {
	canonicalName = "Doyayo",
}

m["dox"] = {
	canonicalName = "Bussa",
	family = "cus",
}

m["doy"] = {
	canonicalName = "Dompo",
}

m["doz"] = {
	canonicalName = "Dorze",
	scripts = {"Latn"},
	family = "omv",
}

m["dpp"] = {
	canonicalName = "Papar",
}

m["drb"] = {
	canonicalName = "Dair",
}

m["drc"] = {
	canonicalName = "Minderico",
	family = "roa",
	ancestors = {"pt"},
}

m["drd"] = {
	canonicalName = "Darmiya",
	family = "sit",
}

m["drg"] = {
	canonicalName = "Rungus",
}

m["dri"] = {
	canonicalName = "Lela",
	otherNames = {"C'lela", "C'Lela", "Chilela"},
	scripts = {"Latn"},
	family = "nic-knj",
}

m["drl"] = {
	canonicalName = "Baagandji",
	otherNames = {"Darling", "Bandjigali"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["drn"] = {
	canonicalName = "West Damar",
	family = "plf",
}

m["dro"] = {
	canonicalName = "Daro-Matu Melanau",
}

m["drq"] = {
	canonicalName = "Dura",
}

m["drr"] = {
	canonicalName = "Dororo",
	family = "poz-ocw",
}

m["drs"] = {
	canonicalName = "Gedeo",
	family = "cus",
}

m["dru"] = {
	canonicalName = "Rukai",
	scripts = {"Latn"},
	family = "map",
}

m["dry"] = {
	canonicalName = "Darai",
}

m["dsb"] = {
	canonicalName = "Lower Sorbian",
	otherNames = {"Lower Lusatian", "Lower Wendish"},
	scripts = {"Latn"},
	family = "wen",
	sort_key = {
		from = {"b́", "ḿ", "ó", "ṕ", "ẃ"},
		to   = {"bj", "mj", "o", "pj", "wj"}} ,
}

m["dse"] = {
	canonicalName = "Dutch Sign Language",
	family = "sgn",
}

m["dsh"] = {
	canonicalName = "Daasanach",
	family = "cus",
}

m["dsi"] = {
	canonicalName = "Disa",
}

m["dsl"] = {
	canonicalName = "Danish Sign Language",
	family = "sgn",
}

m["dsn"] = {
	canonicalName = "Dusner",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["dso"] = {
	canonicalName = "Desiya",
	scripts = {"Orya"},
	family = "inc",
	ancestors = {"or"},
}

m["dsq"] = {
	canonicalName = "Tadaksahak",
}

m["dta"] = {
	canonicalName = "Daur",
	family = "xgn",
}

m["dtb"] = {
	canonicalName = "Labuk-Kinabatangan Kadazan",
}

m["dtd"] = {
	canonicalName = "Ditidaht",
	otherNames = {"Diitidaht"},
	scripts = {"Latn"},
	family = "wak",
}

m["dth"] = { -- contrast 'rrt'
	canonicalName = "Adithinngithigh",
}

m["dti"] = {
	canonicalName = "Ana Tinga Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dtk"] = {
	canonicalName = "Tene Kan Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dtm"] = {
	canonicalName = "Tomo Kan Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dto"] = {
	canonicalName = "Tommo So",
	otherNames = {"Tommo So Dogon"},
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dtp"] = {
	canonicalName = "Central Dusun",
	scripts = {"Latn"},
	family = "poz-san",
}

m["dtr"] = {
	canonicalName = "Lotud",
}

m["dts"] = {
	canonicalName = "Toro So Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dtt"] = {
	canonicalName = "Toro Tegu Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dtu"] = {
	canonicalName = "Tebul Ure Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dty"] = {
	canonicalName = "Doteli",
	otherNames = {"Dotyali"},
	scripts = {"Deva"},
	family = "inc",
}

m["dua"] = {
	canonicalName = "Duala",
	scripts = {"Latn"},
	family = "bnt",
}

m["dub"] = {
	canonicalName = "Dubli",
}

m["duc"] = {
	canonicalName = "Duna",
}

m["dud"] = {
	canonicalName = "Duka",
	otherNames = {"Saare", "Hun-Saare"},
	family = "nic-bco",
}

m["due"] = {
	canonicalName = "Umiray Dumaget Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["duf"] = {
	canonicalName = "Dumbea",
	family = "poz-cln",
}

m["dug"] = {
	canonicalName = "Chiduruma",
}

m["duh"] = {
	canonicalName = "Dungra Bhil",
	scripts = {"Deva", "Gujr"},
	family = "inc",
}

m["dui"] = {
	canonicalName = "Dumun",
}

m["duk"] = {
	canonicalName = "Uyajitaya",
}

m["dul"] = {
	canonicalName = "Alabat Island Agta",
	family = "phi",
}

m["dum"] = {
	canonicalName = "Middle Dutch",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"odt"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["dun"] = {
	canonicalName = "Dusun Deyah",
}

m["duo"] = {
	canonicalName = "Dupaninan Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["dup"] = {
	canonicalName = "Duano",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["duq"] = {
	canonicalName = "Dusun Malang",
}

m["dur"] = {
	canonicalName = "Dii",
}

m["dus"] = {
	canonicalName = "Dumi",
}

m["duu"] = {
	canonicalName = "Drung",
}

m["duv"] = {
	canonicalName = "Duvle",
	family = "paa-lkp",
}

m["duw"] = {
	canonicalName = "Dusun Witu",
}

m["dux"] = {
	canonicalName = "Duun",
	otherNames = {"Duungooma"},
}

m["duy"] = {
	canonicalName = "Dicamay Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["duz"] = {
	canonicalName = "Duli",
	otherNames = {"Duli-Gey", "Duli-Gewe"},
}

m["dva"] = {
	canonicalName = "Duau",
	family = "poz-ocw",
}

m["dwa"] = {
	canonicalName = "Diri",
}

m["dwr"] = {
	canonicalName = "Dawro",
}

m["dwu"] = {
	canonicalName = "Dhuwal",
	otherNames = {"Gumatj", "Dual", "Duala", "Datiwuy", "Wulamba", "Liyagawumirr", "Marrangu", "Djampbarrpuyŋu", "Gupapuyngu", "Dhay'yi", "Dayi", "Dhalwangu"},
	scripts = {"Latn"},
	family = "aus-yol",
}

m["dww"] = {
	canonicalName = "Dawawa",
	family = "poz-ocw",
}

m["dwy"] = {
	canonicalName = "Dhuwaya",
	scripts = {"Latn"},
	family = "aus-yol",
}

m["dya"] = {
	canonicalName = "Dyan",
}

m["dyb"] = {
	canonicalName = "Dyaberdyaber",
}

m["dyd"] = {
	canonicalName = "Dyugun",
}

m["dyg"] = {
	canonicalName = "Villa Viciosa Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["dyi"] = {
	canonicalName = "Djimini",
	otherNames = {"Djimini Senoufo", "Jimini", "Jinmini"},
}

m["dym"] = {
	canonicalName = "Yanda Dogon",
	otherNames = {"Yanda", "Yanda Dom", "Yanda Dom Dogon"},
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["dyn"] = {
	canonicalName = "Dyangadi",
	family = "aus-cww",
}

m["dyo"] = {
	canonicalName = "Jola-Fonyi",
	otherNames = {"Diola-Fogny", "Jola", "Joola", "Diola"},
}

m["dyu"] = {
	canonicalName = "Dyula",
}

m["dyy"] = {
	canonicalName = "Dyaabugay",
}

m["dza"] = {
	canonicalName = "Tunzu",
	otherNames = {"Duguza"},
	family = "nic-knj",
}

m["dzg"] = {
	canonicalName = "Dazaga",
	otherNames = {"Daza", "Dasaga"},
	family = "ssa-sah",
}

m["dzl"] = {
	canonicalName = "Dzala",
	otherNames = {"Dzalakha", "Dzalamat", "Yangtsebikha"},
	scripts = {"Tibt"},
	family = "tbq",
}

m["dzn"] = {
	canonicalName = "Dzando",
}

return m