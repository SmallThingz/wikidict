local u = mw.ustring.char

-- UTF-8 encoded strings for some commonly used diacritics
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

-- Puncuation to be used for standardChars field
local PUNCTUATION = ' !#$%&*+,-./:;<=>?@^_`|~\'()'

local Deva = {"Deva"}
local Latn = {"Latn"}

local m = {}

m["daa"] = {
	"Dangaléat",
	"Q942591",
	"cdc-est",
	aliases = {"Dangaleat", "Dangla", "Danal", "Dangal"},
	scripts = Latn,
}

m["dac"] = {
	"Dambi",
	"Q12629491",
	"poz-ocw",
	scripts = Latn,
}

m["dad"] = {
	"Marik",
	"Q6763404",
	"poz-ocw",
	scripts = Latn,
}

m["dae"] = {
	"Duupa",
	"Q35263",
	"alv-dur",
	scripts = Latn,
}

m["dag"] = {
	"Dagbani",
	"Q32238",
	"nic-dag",
	scripts = Latn,
}

m["dah"] = {
	"Gwahatike",
	"Q5623246",
	"ngf-fin",
	scripts = Latn,
}

m["dai"] = {
	"Day",
	"Q35163",
	"alv-mbd",
	scripts = Latn,
}

m["daj"] = {
	"Dar Fur Daju",
	"Q56370",
	"sdv",
	scripts = Latn,
}

m["dak"] = {
	"Dakota",
	"Q530384",
	"sio-dkt",
	scripts = Latn,
}

m["dal"] = {
	"Dahalo",
	"Q35143",
	"cus",
	scripts = Latn,
}

m["dam"] = {
	"Damakawa",
	"Q1158134",
	"nic-knn",
	scripts = Latn,
}

m["dao"] = {
	"Daai Chin",
	"Q860029",
	"tbq-kuk",
	scripts = Latn,
}

m["daq"] = {
	"Dandami Maria",
	"Q12952805",
	"dra",
	otherNames = {"Bison-Horn Maria", "Madia", "Madiya", "Maria (India)", "Maria"}, -- the last four are also names of daq's sibling lect, mrr
	ancestors = {"gon"},
}

m["dar"] = {
	"Dargwa",
	"Q32332",
	"cau-drg",
	aliases = {"Dargin"},
	scripts = {"Cyrl"},
	translit_module = "dar-translit",
	override_translit = true,
}

m["das"] = {
	"Daho-Doo",
	"Q3915369",
	"kro-wee",
	scripts = Latn,
}

m["dau"] = {
	"Dar Sila Daju",
	"Q7514020",
	"sdv",
	scripts = Latn,
}

m["dav"] = {
	"Taita",
	"Q2387274",
	"bnt-cht",
	scripts = Latn,
}

m["daw"] = {
	"Davawenyo",
	"Q5228174",
	"phi",
	scripts = Latn,
}

m["dax"] = {
	"Dayi",
	"Q10467281",
	"aus-yol",
	scripts = Latn,
}

m["daz"] = {
	"Dao",
	"Q5221513",
	"ngf",
	scripts = Latn,
}

m["dba"] = {
	"Bangi Me",
	"Q1982696",
	"qfa-iso",
	scripts = Latn,
}

m["dbb"] = {
	"Deno",
	"Q56275",
	"cdc",
	scripts = Latn,
}

m["dbd"] = {
	"Dadiya",
	"Q3914436",
	"alv-wjk",
	scripts = Latn,
}

m["dbe"] = {
	"Dabe",
	"Q5207451",
	"paa-tkw",
	scripts = Latn,
}

m["dbf"] = {
	"Edopi",
	"Q12953516",
	"paa-lkp",
	aliases = {"Elopi"},
	scripts = Latn,
}

m["dbg"] = {
	"Dogul Dom",
	"Q3912880",
	"nic-npd",
	aliases = {"Dogul Dom Dogon"},
	scripts = Latn,
}

m["dbi"] = {
	"Doka",
	"Q3913293",
	"nic-plc",
	scripts = Latn,
}

m["dbj"] = {
	"Ida'an",
	"Q3041552",
	"poz-san",
	scripts = Latn,
}

m["dbl"] = {
	"Dyirbal",
	"Q35465",
	"aus-dyb",
	scripts = Latn,
}

m["dbm"] = {
	"Duguri",
	"Q7194057",
	"nic-jrw",
	scripts = Latn,
}

m["dbn"] = {
	"Duriankere",
	"Q5316627",
	"ngf-sbh",
	scripts = Latn,
}

m["dbo"] = {
	"Dulbu",
	"Q5313310",
	"nic-jrn",
	scripts = Latn,
}

m["dbp"] = {
	"Duwai",
	"Q56301",
	"cdc-wst",
	scripts = Latn,
}

m["dbq"] = {
	"Daba",
	"Q3913342",
	"cdc-cbm",
	scripts = Latn,
}

m["dbr"] = {
	"Dabarre",
	"Q3447286",
	"cus",
}

m["dbt"] = {
	"Ben Tey",
	"Q4886561",
	"nic-nwa",
	aliases = {"Ben Tey Dogon"},
	scripts = Latn,
}

m["dbu"] = {
	"Bondum Dom Dogon",
	"Q3912758",
	"nic-npd",
	scripts = Latn,
}

m["dbv"] = {
	"Dungu",
	"Q5315230",
	"nic-kau",
	scripts = Latn,
}

m["dbw"] = {
	"Bankan Tey Dogon",
	"Q4856243",
	"nic-nwa",
	scripts = Latn,
}

m["dby"] = {
	"Dibiyaso",
	"Q5272268",
	"ngf",
	scripts = Latn,
}

m["dcc"] = {
	"Deccani",
	"Q669431",
	"inc",
	aliases = {"Dakhini", "Dakkhani", "Deccan", "Deccany"},
	scripts = {"ur-Arab"},
	ancestors = {"ur"},
}

m["dcr"] = {
	"Negerhollands",
	"Q1815830",
	"crp",
	scripts = Latn,
	ancestors = {"nl"},
}

m["dda"] = {
	"Dadi Dadi",
	nil,
	"aus-pam",
	aliases = {"Dardi Dardi", "Tati Tati", "Dadi-Dadi", "Dardi-Dardi", "Tati-Tati"},
	scripts = Latn,
}

m["ddd"] = {
	"Dongotono",
	"Q56676",
	"sdv",
}

m["dde"] = {
	"Doondo",
	"Q11003401",
	"bnt-kng",
	scripts = Latn,
}

m["ddg"] = {
	"Fataluku",
	"Q35353",
	"qfa-tap",
	scripts = Latn,
}

m["ddi"] = {
	"Diodio",
	"Q3028668",
	"poz-ocw",
	scripts = Latn,
}

m["ddj"] = {
	"Jaru",
	"Q3162806",
	"aus-pam",
	scripts = Latn,
}

m["ddn"] = {
	"Dendi",
	"Q35164",
	"son",
	otherNames = {"Dandawa", "Dendi (West Africa)", "Dendi (Benin)"},
	scripts = Latn,
}

m["ddo"] = {
	"Tsez",
	"Q34033",
	"cau-tsz",
	aliases = {"Tsezi", "Dido"},
	scripts = {"Cyrl"},
}

m["ddr"] = {
	"Dhudhuroa",
	"Q5269842",
	"aus-pam",
	otherNames = {"Yaitmathang"},
	scripts = Latn,
}

m["dds"] = {
	"Donno So Dogon",
	"Q1234776",
	"nic-dge",
	scripts = Latn,
}

m["ddw"] = {
	"Dawera-Daweloor",
	"Q5242304",
	"poz-tim",
	scripts = Latn,
}

m["dec"] = {
	"Dagik",
	"Q35125",
	"alv-tal",
	scripts = Latn,
}

m["ded"] = {
	"Dedua",
	"Q5249850",
	"ngf",
	scripts = Latn,
}

m["dee"] = {
	"Dewoin",
	"Q3914892",
	"kro-wkr",
	scripts = Latn,
}

m["def"] = {
	"Dezfuli",
	"Q4115412",
	"ira-swi",
	aliases = {"Dezhfili", "Dizfuli"},
}

m["deg"] = {
	"Degema",
	"Q35182",
	"alv-dlt",
	scripts = Latn,
}

m["deh"] = {
	"Dehwari",
	"Q5704314",
	"ira-swi",
	ancestors = {"fa"},
}

m["dei"] = {
	"Demisa",
	"Q56380",
	"paa-egb",
	scripts = Latn,
}

m["dek"] = { -- called "unattested alleged language" by Wikipedia
	"Dek",
	"Q5252754",
	scripts = Latn,
}

m["dem"] = {
	"Dem",
	"Q5254989",
	"paa",
	scripts = Latn,
}

m["den"] = {
	"Slavey",
	"Q13272",
	"ath-nor",
	aliases = {"Slave", "Slavé"},
	scripts = Latn,
}

m["dep"] = {
	"Pidgin Delaware",
	nil,
	"crp",
	scripts = Latn,
	ancestors = {"unm"},
}

-- deq is not included, see [[WT:LT]]

m["der"] = {
	"Deori",
	"Q56478",
	"tbq-bdg",
	scripts = {"Beng", "Latn"},
}

m["des"] = {
	"Desano",
	"Q962392",
	"sai-tuc",
	scripts = Latn,
}

m["dev"] = {
	"Domung",
	"Q5291378",
	"ngf-fin",
	scripts = Latn,
}

m["dez"] = {
	"Dengese",
	"Q2909984",
	"bnt-tet",
	scripts = Latn,
}

m["dga"] = {
	"Southern Dagaare",
	"Q35159",
	"nic-mre",
	scripts = Latn,
}

m["dgb"] = {
	"Bunoge",
	"Q4985178",
	"nic-dgw",
	aliases = {"Bunoge Dogon"},
	scripts = Latn,
}

m["dgc"] = {
	"Casiguran Dumagat Agta",
	"Q5313599",
	"phi",
	scripts = Latn,
}

m["dgd"] = {
	"Dagaari Dioula",
	"Q11153465",
	"nic-mre",
	scripts = Latn,
}

m["dge"] = {
	"Degenan",
	"Q5251770",
	"ngf-fin",
	scripts = Latn,
}

m["dgg"] = {
	"Doga",
	"Q3033726",
	"poz-ocw",
	scripts = Latn,
}

m["dgh"] = {
	"Dghwede",
	"Q56293",
	"cdc-cbm",
	scripts = Latn,
}

m["dgi"] = {
	"Northern Dagara",
	"Q11004218",
	"nic-mre",
	scripts = Latn,
}

m["dgk"] = {
	"Dagba",
	"Q12952357",
	"csu-sar",
	scripts = Latn,
}

m["dgn"] = {
	"Dagoman",
	"Q10465931",
	"aus-yng",
	scripts = Latn,
}

m["dgo"] = {
	"Hindi Dogri",
	nil,
	"him",
	ancestors = {"doi"},
	scripts = {"Deva", "Arab", "Takr"},
}

m["dgr"] = {
	"Dogrib",
	"Q20979",
	"ath-nor",
	aliases = {"Tłicho", "Tlinchon"},
	scripts = Latn,
}

m["dgs"] = {
	"Dogoso",
	"Q35343",
	"nic-gur",
}

m["dgt"] = {
	"Ntra'ngith",
	"Q6983809",
	"aus-pam",
	aliases = {"Ndra'ngith"},
	scripts = Latn,
}

-- dgu is not a language; see [[w:Dhekaru]]

m["dgw"] = {
	"Daungwurrung",
	"Q5228050",
	"aus-pam",
	aliases = {"Taungurong", "Dhagung-wurrung", "Thagungwurrung"},
	scripts = Latn,
}

m["dgx"] = {
	"Doghoro",
	"Q12952392",
	"ngf",
	scripts = Latn,
}

m["dgz"] = {
	"Daga",
	"Q5208442",
	"ngf",
	scripts = Latn,
}

m["dhg"] = {
	"Dhangu",
	"Q5268960",
	"aus-yol",
	scripts = Latn,
}

m["dhi"] = {
	"Dhimal",
	"Q35229",
	"sit-dhi",
	scripts = Deva,
}

m["dhl"] = {
	"Dhalandji",
	"Q5268787",
	"aus-psw",
	scripts = Latn,
}

m["dhm"] = {
	"Zemba",
	"Q3502283",
	"bnt-swb",
	ancestors = {"hz"},
	otherNames = {"Dhimba", "Dimba", "Oludhimba", "Oluthimba", "Otjidhimba", "Simba", "Tjimba"},
	scripts = Latn,
}

m["dhn"] = {
	"Dhanki",
	"Q5268992",
	"inc-bhi",
}

m["dho"] = {
	"Dhodia",
	"Q5269658",
	"inc-bhi",
	scripts = Deva,
}

m["dhr"] = {
	"Tharrgari",
	"Q10470289",
	"aus-psw",
	aliases = {"Dhargari"},
	scripts = Latn,
}

m["dhs"] = {
	"Dhaiso",
	"Q11001788",
	"bnt-kka",
	scripts = Latn,
}

m["dhu"] = {
	"Dhurga",
	"Q1285318",
	"aus-yuk",
	scripts = Latn,
}

m["dhv"] = {
	"Drehu",
	"Q3039319",
	"poz-occ",
	scripts = Latn,
}

m["dhw"] = {
	"Danuwar",
	"Q3522797",
	"inc",
	otherNames = {"Danwar", "Dhanwar", "Rai"},
	scripts = Deva,
}

m["dhx"] = {
	"Dhungaloo",
	"Q16960599",
	"aus-pam",
	scripts = Latn,
}

m["dia"] = {
	"Dia",
	"Q3446591",
	"qfa-tor",
	scripts = Latn,
}

m["dib"] = {
	"South Central Dinka",
	"Q35154",
	"sdv",
	ancestors = {"din"},
	scripts = Latn,
}

m["dic"] = {
	"Lakota Dida",
	"Q11001730",
	"kro-did",
	scripts = Latn,
}

m["did"] = {
	"Didinga",
	"Q56365",
	"sdv",
	scripts = Latn,
}

m["dif"] = {
	"Dieri",
	"Q25559563",
	"aus-kar",
	otherNames = {"Diyari", "Dirari"},
	scripts = Latn,
}

m["dig"] = {
	"Digo",
	"Q3362072",
	"bnt-mij",
	otherNames = {"Chidigo"},
	scripts = Latn,
}

-- "dih" IS SPLIT INTO nai-ipa, nai-kum, nai-tip, SEE WT:LT

m["dii"] = {
	"Dimbong",
	"Q35196",
	"bnt-baf",
	scripts = Latn,
}

m["dij"] = {
	"Dai",
	"Q5209056",
	"poz-tim",
}

m["dik"] = {
	"Southwestern Dinka",
	"Q36540",
	"sdv",
	ancestors = {"din"},
	scripts = Latn,
}

m["dil"] = {
	"Dilling",
	"Q35152",
	"nub-hil",
	scripts = Latn,
}

m["dim"] = {
	"Dime",
	"Q35311",
	"omv",
}

m["din"] = {
	"Dinka",
	"Q56466",
	"sdv",
	scripts = Latn,
}

m["dio"] = {
	"Dibo",
	"Q3914891",
	"alv-ngb",
	scripts = Latn,
}

m["dip"] = {
	"Northeastern Dinka",
	"Q36246",
	"sdv",
	ancestors = {"din"},
	scripts = Latn,
}

m["dir"] = {
	"Dirim",
	"Q11130804",
	"nic-dak",
	scripts = Latn,
}

m["dis"] = {
	"Dimasa",
	"Q56664",
	"tbq-bdg",
	scripts = {"Latn", "Beng"},
}

m["diu"] = {
	"Gciriku",
	"Q3780954",
	"bnt-kav",
	otherNames = {"Rumanyo", "Dirico", "Dciriku", "Diriku", "Rugciriku"},
	scripts = Latn,
}

m["diw"] = {
	"Northwestern Dinka",
	"Q36249",
	"sdv",
	ancestors = {"din"},
	scripts = Latn,
}

m["dix"] = {
	"Dixon Reef",
	"Q5284967",
	"poz-vnc",
	scripts = Latn,
}

m["diy"] = {
	"Diuwe",
	"Q5283765",
	"ngf",
}

m["diz"] = {
	"Ding",
	"Q35202",
	"bnt-bdz",
	scripts = Latn,
}

m["dja"] = {
	"Djadjawurrung",
	"Q5285190",
	"aus-pam",
	aliases = {"Dja dja wurrung"},
	scripts = Latn,
}

m["djb"] = {
	"Djinba",
	"Q5285351",
	"aus-yol",
	scripts = Latn,
}

m["djc"] = {
	"Dar Daju Daju",
	"Q5209890",
	"sdv",
	scripts = Latn,
}

m["djd"] = {
	"Jaminjung",
	"Q6147825",
	"aus-mir",
	aliases = {"Djamindjung"},
	scripts = Latn,
}

m["dje"] = {
	"Zarma",
	"Q36990",
	"son",
	scripts = {"Latn", "Arab", "Brai"},
}

m["djf"] = {
	"Djangun",
	"Q10474818",
	"aus-pmn",
	scripts = Latn,
}

m["dji"] = {
	"Djinang",
	"Q5285350",
	"aus-yol",
	scripts = Latn,
}

m["djj"] = {
	"Ndjébbana",
	"Q5285274",
	"aus-arn",
	aliases = {"Djeebbana"},
	scripts = Latn,
}

m["djk"] = {
	"Aukan",
	"Q2659044",
	"crp",
	otherNames = {"Ndyuka"},
	scripts = {"Latn", "Afak"},
	ancestors = {"en"},
}

m["djl"] = {
	"Djiwarli",
	nil,
	"aus-psw",
	scripts = Latn,
}

m["djm"] = {
	"Jamsay",
	"Q3913290",
	"nic-pld",
	aliases = {"Jamsay Dogon", "Jamsai"},
	scripts = Latn,
}

m["djn"] = {
	"Djauan",
	"Q13553748",
	"aus-gun",
	scripts = Latn,
}

m["djo"] = {
	"Jangkang",
	"Q12952388",
	"day",
}

m["djr"] = {
	"Djambarrpuyngu",
	"Q3915679",
	"aus-yol",
	scripts = Latn,
}

m["dju"] = {
	"Kapriman",
	"Q6367199",
	"paa-spk",
	scripts = Latn,
}

m["djw"] = {
	"Djawi",
	"Q3913844",
	"aus-nyu",
	ancestors = {"bcj"},
	scripts = Latn,
}

m["dka"] = {
	"Dakpa",
	"Q3695189",
	"sit-ebo",
	otherNames = {"Dakpakha", "Takpa", "Tawang Monpa"},
	scripts = {"Tibt"},
}

m["dkk"] = {
	"Dakka",
	"Q5209962",
	"poz-ssw",
}

m["dkr"] = {
	"Kuijau",
	"Q13580777",
	"poz-bnn",
}

m["dks"] = {
	"Southeastern Dinka",
	"Q36538",
	"sdv",
	ancestors = {"din"},
	scripts = Latn,
}

m["dkx"] = {
	"Mazagway",
	"Q6798209",
	"cdc-cbm",
	scripts = Latn,
}

m["dlg"] = {
	"Dolgan",
	"Q32878",
	"trk-sib",
	scripts = {"Cyrl"},
}

m["dlk"] = {
	"Dahalik",
	"Q32260",
	"sem-eth",
}

m["dlm"] = {
	"Далматински",
	"Q35527",
	"roa-itd",
	aliases = {"Dalmatic"},
	scripts = Latn,
}

m["dln"] = {
	"Darlong",
	"Q5224029",
	"tbq-kuk",
	scripts = Latn,
}

m["dma"] = {
	"Duma",
	"Q35319",
	"bnt-nze",
	scripts = Latn,
}

m["dmb"] = {
	"Mombo Dogon",
	"Q6897074",
	"nic-dgw",
	scripts = Latn,
}

m["dmc"] = {
	"Gavak",
	"Q5277406",
	"ngf-mad",
	otherNames = {"Bosiken", "Boskien", "Dimir", "Dimer"}, -- last two are erroneous per Boyd
	scripts = Latn,
}

m["dmd"] = {
	"Madhi Madhi",
	"Q6727353",
	"aus-pam",
	aliases = {"Madhi-Madhi", "Madi Madi", "Madi-Madi", "Muthimuthi"},
	scripts = Latn,
}

m["dme"] = {
	"Dugwor",
	"Q56313",
	"cdc-cbm",
	scripts = Latn,
}

m["dmg"] = {
	"Upper Kinabatangan",
	"Q16109975",
	"poz-san",
	scripts = Latn,
}

m["dmk"] = {
	"Domaaki",
	"Q32900",
	"inc-dar",
}

m["dml"] = {
	"Dameli",
	"Q32288",
	"inc-dar",
}

m["dmm"] = {
	"Dama",
	"Q5211865",
	"alv-mbm",
	scripts = Latn,
}

m["dmo"] = {
	"Kemezung",
	"Q35562",
	"nic-bbe",
	scripts = Latn,
}

m["dmr"] = {
	"East Damar",
	"Q5328200",
	"poz-cet",
	scripts = Latn,
}

m["dms"] = {
	"Dampelas",
	"Q5212928",
	"poz-tot",
	scripts = Latn,
}

m["dmu"] = {
	"Dubu",
	"Q7692059",
	"paa-pau",
	scripts = Latn,
}

m["dmv"] = {
	"Dumpas",
	"Q12953512",
	"poz-san",
	scripts = Latn,
}

m["dmw"] = {
	"Mudburra",
	"Q6931573",
	"aus-pam",
	aliases = {"Mudbura"},
	scripts = Latn,
}

m["dmx"] = {
	"Dema",
	"Q3553423",
	"bnt-sho",
	scripts = Latn,
}

m["dmy"] = {
	"Demta",
	"Q14466283",
	"paa-sen",
	scripts = Latn,
}

m["dna"] = {
	"Upper Grand Valley Dani",
	"Q12952361",
	"ngf",
	scripts = Latn,
}

m["dnd"] = {
	"Daonda",
	"Q5221528",
	"paa-brd",
	scripts = Latn,
}

m["dne"] = {
	"Ndendeule",
	"Q6983725",
	"bnt-mbi",
	scripts = Latn,
}

m["dng"] = {
	"Дунган",
	"Q33050",
	"zhx",
	scripts = {"Cyrl", "Hani", "Arab"},
	ancestors = {"cmn"},
	translit_module = "dng-translit",
}

m["dni"] = {
	"Lower Grand Valley Dani",
	"Q12635807",
	"ngf",
	scripts = Latn,
}

m["dnj"] = {
	"Dan",
	"Q1158971",
	"dmn-mda",
	scripts = Latn,
}

m["dnk"] = {
	"Dengka",
	"Q5256954",
	"poz-tim",
	scripts = Latn,
}

m["dnn"] = {
	"Dzuun",
	"Q10973260",
	"dmn-smg",
	otherNames = {"Dzùùn", "Dzuungoo", "Dzùùngoo"},
}

m["dnr"] = {
	"Danaru",
	"Q5214932",
	"ngf-mad",
	scripts = Latn,
}

m["dnt"] = {
	"Mid Grand Valley Dani",
	"Q12952359",
	"ngf",
	scripts = Latn,
}

m["dnu"] = {
	"Danau",
	"Q5013745",
	"mkh-pal",
}

m["dnv"] = {
	"Danu",
	"Q5221251",
	"tbq-brm",
	ancestors = {"obr"},
}

m["dnw"] = {
	"Western Dani",
	"Q7987774",
	"ngf",
	scripts = Latn,
}

m["dny"] = {
	"Dení",
	"Q56562",
	"auf",
	scripts = Latn,
}

m["doa"] = {
	"Dom",
	"Q5289770",
	"ngf",
	scripts = Latn,
}

m["dob"] = {
	"Dobu",
	"Q952133",
	"poz-ocw",
	scripts = Latn,
}

m["doc"] = {
	"Northern Kam",
	"Q17195499",
	"qfa-tak",
	otherNames = {"Northern Gam", "Northern Dong"},
	scripts = Latn,
}

m["doe"] = {
	"Doe",
	"Q5288055",
	"bnt-ruv",
	scripts = Latn,
}

m["dof"] = {
	"Domu",
	"Q5291375",
	"ngf",
	scripts = Latn,
}

m["doh"] = {
	"Dong",
	"Q3438405",
	"nic-dak",
	scripts = Latn,
}

m["doi"] = {
	"Dogri",
	"Q32730",
	"him",
	scripts = {"Deva", "Takr", "fa-Arab", "Dogr"},
	translit_module = "hi-translit", -- for now
}

m["dok"] = {
	"Dondo",
	"Q5295571",
	"poz-tot",
	scripts = Latn,
}

m["dol"] = {
	"Doso",
	"Q4167202",
	"paa",
	scripts = Latn,
}

m["don"] = {
	"Doura",
	"Q7829037",
	"poz-ocw",
	scripts = Latn,
}

m["doo"] = {
	"Dongo",
	"Q35303",
	"nic-mbc",
	scripts = Latn,
}

m["dop"] = {
	"Lukpa",
	"Q3258739",
	"nic-gne",
	scripts = Latn,
}

m["doq"] = {
	"Dominican Sign Language",
	"Q5290820",
	"sgn",
	scripts = Latn, -- when documented
}

m["dor"] = {
	"Dori'o",
	"Q3037084",
	"poz-sls",
	scripts = Latn,
}

m["dos"] = {
	"Dogosé",
	"Q3913314",
	"nic-gur",
	scripts = Latn,
}

m["dot"] = {
	"Dass",
	"Q3441293",
	"cdc-wst",
	scripts = Latn,
}

m["dov"] = {
	"Dombe",
	"Q11001779",
	"bnt-bot",
	ancestors = {"toi"},
	scripts = Latn,
}

m["dow"] = {
	"Doyayo",
	"Q35299",
	"alv-dur",
	scripts = Latn,
}

m["dox"] = {
	"Bussa",
	"Q35123",
	"cus",
	scripts = Latn,
}

m["doy"] = {
	"Dompo",
	"Q35270",
	"alv-gng",
	scripts = Latn,
}

m["doz"] = {
	"Dorze",
	"Q56336",
	"omv",
	scripts = Latn,
}

m["dpp"] = {
	"Papar",
	"Q7132487",
	"poz-san",
	scripts = Latn,
}

m["drb"] = {
	"Dair",
	"Q12952360",
	"nub-hil",
	scripts = Latn,
}

m["drc"] = {
	"Minderico",
	"Q6863806",
	"roa-ibe",
	scripts = Latn,
	ancestors = {"pt"},
}

m["drd"] = {
	"Darmiya",
	"Q5224058",
	"sit-alm",
}

m["drg"] = {
	"Rungus",
	"Q6897407",
	"poz-san",
	scripts = Latn,
}

m["dri"] = {
	"Lela",
	"Q3914004",
	"nic-knn",
	otherNames = {"C'lela", "C'Lela", "Chilela"},
	scripts = Latn,
}

m["drl"] = {
	"Baagandji",
	"Q5223941",
	"aus-pam",
	otherNames = {"Darling", "Bandjigali"},
	scripts = Latn,
}

m["drn"] = {
	"West Damar",
	"Q3450459",
	"poz-tim",
	scripts = Latn,
}

m["dro"] = {
	"Daro-Matu Melanau",
	"Q5224156",
	"poz-bnn",
	scripts = Latn,
}

m["drq"] = {
	"Dura",
	"Q3449842",
	"sit-gma",
}

m["drs"] = {
	"Gedeo",
	"Q56622",
	"cus",
	scripts = {"Ethi"},
}

m["dru"] = {
	"Rukai",
	"Q49232",
	"map",
	scripts = Latn,
	ancestors = {"dru-pro"},
}

m["dry"] = {
	"Darai",
	"Q46995026",
	"inc",
	scripts = Deva,
}

m["dsb"] = {
	"Lower Sorbian",
	"Q13286",
	"wen",
	aliases = {"Lower Lusatian", "Lower Wendish"},
	scripts = Latn,
	sort_key = {
		from = {"b́",  "č",  "ć",   "ě",  "ł",  "ḿ",  "ń",  "ó", "ṕ",  "ŕ",  "š",  "ś",   "ẃ",  "[žż]",  "ź"},
		to   = {"bj", "c~", "c~~", "e~", "l*", "mj", "n~", "o", "pj", "r~", "s~", "s~~", "wj", "z~",    "z~~"}} , --ł comes before l in alphabetic order
	standardChars = "A-PR-UWYZa-pr-uwyz0-9ÓóĆćČčĚěŁłŃńŔŕŚśŠšŹźŽž" .. PUNCTUATION,
}

m["dse"] = {
	"Dutch Sign Language",
	"Q2201099",
	"sgn",
	scripts = Latn, -- when documented
}

m["dsh"] = {
	"Daasanach",
	"Q56637",
	"cus",
	scripts = Latn,
}

m["dsi"] = {
	"Disa",
	"Q3914455",
	"csu",
	scripts = Latn,
}

m["dsl"] = {
	"Danish Sign Language",
	"Q2605298",
	"sgn",
	scripts = Latn, -- when documented
}

m["dsn"] = {
	"Dusner",
	"Q5316948",
	"poz-hce",
	scripts = Latn,
}

m["dso"] = {
	"Desiya",
	"Q12629755",
	"inc",
	scripts = {"Orya"},
	ancestors = {"or"},
}

m["dsq"] = {
	"Tadaksahak",
	"Q36568",
	"son",
	scripts = {"Arab", "Latn"},
}

m["dta"] = {
	"Daur",
	"Q32430",
	"xgn",
	scripts = {"Latn", "Hani", "Cyrl", "Mong"},
}

m["dtb"] = {
	"Labuk-Kinabatangan Kadazan",
	"Q5330240",
	"poz-san",
	scripts = Latn,
}

m["dtd"] = {
	"Ditidaht",
	"Q13728042",
	"wak",
	aliases = {"Diitidaht"},
	scripts = Latn,
}

m["dth"] = { -- contrast 'rrt'
	"Adithinngithigh",
	"Q4683034",
	"aus-pmn",
	scripts = Latn,
}

m["dti"] = {
	"Ana Tinga Dogon",
	"Q4750346",
	"qfa-dgn",
	scripts = Latn,
}

m["dtk"] = {
	"Tene Kan Dogon",
	"Q11018863",
	"nic-pld",
	scripts = Latn,
}

m["dtm"] = {
	"Tomo Kan Dogon",
	"Q11137719",
	"nic-pld",
	scripts = Latn,
}

m["dto"] = {
	"Tommo So",
	"Q47012992",
	"nic-dge",
	aliases = {"Tommo So Dogon"},
	scripts = Latn,
}

m["dtp"] = {
	"Central Dusun",
	"Q5317225",
	"poz-san",
	otherNames = {"Kadazandusun", "Kadazan-Dusun", "Kadazan Dusun", "Kadazan", "Bunduliwan", "Boros Dusun"},
	scripts = Latn,
}

m["dtr"] = {
	"Lotud",
	"Q6685078",
	"poz-san",
	scripts = Latn,
}

m["dts"] = {
	"Toro So Dogon",
	"Q11003311",
	"nic-dge",
	scripts = Latn,
}

m["dtt"] = {
	"Toro Tegu Dogon",
	"Q3913924",
	"nic-pld",
	scripts = Latn,
}

m["dtu"] = {
	"Tebul Ure Dogon",
	"Q7692089",
	"qfa-dgn",
	scripts = Latn,
}

m["dty"] = {
	"Doteli",
	"Q18415595",
	"inc-pah",
	aliases = {"Dotyali"},
	scripts = Deva,
	translit_module = "ne-translit",
	ancestors = {"ne"},
}

m["dua"] = {
	"Duala",
	"Q33013",
	"bnt-saw",
	scripts = Latn,
}

m["dub"] = {
	"Dubli",
	"Q5310792",
	"inc-bhi",
}

m["duc"] = {
	"Duna",
	"Q5314039",
	"paa",
	scripts = Latn,
}

m["due"] = {
	"Umiray Dumaget Agta",
	"Q7881585",
	"phi",
	scripts = Latn,
}

m["duf"] = {
	"Dumbea",
	"Q6983819",
	"poz-cln",
	scripts = Latn,
}

m["dug"] = {
	"Chiduruma",
	"Q35614",
	"bnt-mij",
	scripts = Latn,
}

m["duh"] = {
	"Dungra Bhil",
	"Q12953513",
	"inc-bhi",
	scripts = {"Deva", "Gujr"},
}

m["dui"] = {
	"Dumun",
	"Q5314004",
	"ngf-mad",
	scripts = Latn,
}

m["duk"] = {
	"Uyajitaya",
	"Q7904085",
	"ngf-mad",
	scripts = Latn,
}

m["dul"] = {
	"Alabat Island Agta",
	"Q3399709",
	"phi",
	scripts = Latn,
}

m["dum"] = {
	"Средњи Холандски",
	"Q178806",
	"gmw",
	scripts = Latn,
	ancestors = {"odt"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊË]", "[ēêë]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["dun"] = {
	"Dusun Deyah",
	"Q2784033",
	"poz-bre",
	scripts = Latn,
}

m["duo"] = {
	"Dupaningan Agta",
	"Q5315912",
	"phi",
	aliases = {"Dupaninan Agta", "Dupaningan", "Dupaninan"},
	scripts = Latn,
}

m["dup"] = {
	"Duano",
	"Q3040468",
	"poz-mly",
	scripts = Latn,
}

m["duq"] = {
	"Dusun Malang",
	"Q3041711",
	"poz-bre",
	scripts = Latn,
}

m["dur"] = {
	"Dii",
	nil,
	"alv-dur",
	scripts = Latn,
}

m["dus"] = {
	"Dumi",
	"Q56315",
	"sit-kiw",
	scripts = Deva,
}

m["duu"] = {
	"Drung",
	"Q56406",
	"sit-nng",
	otherNames = {"Derung", "Dulong", "Trung"},
}

m["duv"] = {
	"Duvle",
	"Q56364",
	"paa-lkp",
	scripts = Latn,
}

m["duw"] = {
	"Dusun Witu",
	"Q2381310",
	"poz-bre",
	scripts = Latn,
}

m["dux"] = {
	"Duun",
	"Q3914880",
	"dmn-smg",
	otherNames = {"Duungooma"},
	scripts = Latn,
}

m["duy"] = {
	"Dicamay Agta",
	"Q5272321",
	"phi",
	scripts = Latn,
}

m["duz"] = {
	"Duli",
	"Q5313405",
	"alv-ada",
	otherNames = {"Duli-Gey", "Duli-Gewe"},
	scripts = Latn,
}

m["dva"] = {
	"Duau",
	"Q5310448",
	"poz-ocw",
	scripts = Latn,
}

m["dwa"] = {
	"Diri",
	"Q56286",
	"cdc-wst",
	scripts = Latn,
}

m["dwr"] = {
	"Dawro",
	"Q12629647",
	"omv",
	scripts = {"Ethi", "Latn"},
}

m["dwu"] = {
	"Dhuwal",
	nil,
	"aus-yol",
	otherNames = {"Gumatj", "Dual", "Duala", "Datiwuy", "Wulamba", "Liyagawumirr", "Marrangu", "Djampbarrpuyŋu", "Gupapuyngu", "Dhay'yi", "Dayi", "Dhalwangu"},
	scripts = Latn,
}

m["dww"] = {
	"Dawawa",
	"Q5242286",
	"poz-ocw",
	scripts = Latn,
}

m["dwy"] = {
	"Dhuwaya",
	nil,
	"aus-yol",
	scripts = Latn,
}

m["dwz"] = {
	"Dewas Rai",
	"Q62663667",
	"inc",
	otherNames = {"Danuwar Rai", "Rai Danuwar"},
}

m["dya"] = {
	"Dyan",
	"Q35340",
	"nic-gur",
	scripts = Latn,
}

m["dyb"] = {
	"Dyaberdyaber",
	"Q5285185",
	"aus-nyu",
	scripts = Latn,
}

m["dyd"] = {
	"Dyugun",
	"Q3913785",
	"aus-nyu",
	scripts = Latn,
}

m["dyg"] = {
	"Villa Viciosa Agta",
	"Q12626611",
	"phi",
	scripts = Latn,
}

m["dyi"] = {
	"Djimini",
	"Q35336",
	"alv-tdj",
	otherNames = {"Djimini Senoufo", "Jimini", "Jinmini"},
	scripts = Latn,
}

m["dym"] = {
	"Yanda Dogon",
	"Q8048316",
	"qfa-dgn",
	otherNames = {"Yanda", "Yanda Dom", "Yanda Dom Dogon"},
	scripts = Latn,
}

m["dyn"] = {
	"Dyangadi",
	"Q3913820",
	"aus-cww",
	scripts = Latn,
}

m["dyo"] = {
	"Jola-Fonyi",
	"Q3507832",
	"alv-jol",
	otherNames = {"Diola-Fogny", "Jola", "Joola", "Diola"},
	scripts = Latn,
}

m["dyu"] = {
	"Dyula",
	"Q32706",
	"dmn-man",
	scripts = Latn,
}

m["dyy"] = {
	"Dyaabugay",
	"Q2591320",
	"aus-pmn",
	aliases = {"Djabugay", "Dyabugay", "Djabugai", "Tjapukai"},
	scripts = Latn,
}

m["dza"] = {
	"Tunzu",
	"Q3915845",
	"nic-jer",
	otherNames = {"Duguza"},
	scripts = Latn,
}

m["dzg"] = {
	"Dazaga",
	"Q35244",
	"ssa-sah",
	otherNames = {"Daza", "Dasaga"},
	scripts = Latn,
}

m["dzl"] = {
	"Dzala",
	"Q56607",
	"sit-ebo",
	otherNames = {"Dzalakha", "Dzalamat", "Yangtsebikha"},
	scripts = {"Tibt"},
}

m["dzn"] = {
	"Dzando",
	"Q5319622",
	"bnt-bun",
	scripts = Latn,
}

return m