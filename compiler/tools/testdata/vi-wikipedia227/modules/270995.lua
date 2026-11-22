local m_langdata = require("Module:languages/data")

-- Loaded on demand, as it may not be needed (depending on the data).
local function u(...)
	u = require("Module:string utilities").char
	return u(...)
end

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

local m = {}

m["daa"] = {
	"tiếng Dangaléat",
	942591,
	"cdc-est",
	"Latn",
	"Tiếng Dangaléat",
	"Dangaléat",
}

m["dac"] = {
	"tiếng Dambi",
	12629491,
	"poz-ocw",
	"Latn",
	"Tiếng Dambi",
	"Dambi",
}

m["dad"] = {
	"Marik",
	6763404,
	"poz-ocw",
	"Latn",
}

m["dae"] = {
	"Duupa",
	35263,
	"alv-dur",
	"Latn",
}

m["dag"] = {
	"tiếng Dagbani",
	32238,
	"nic-dag",
	"Latn",
	"Tiếng Dagbani",
	"Dagbani",
}

m["dah"] = {
	"Gwahatike",
	5623246,
	"ngf-fin",
	"Latn",
}

m["dai"] = {
	"Day",
	35163,
	"alv-mbd",
	"Latn",
}

m["daj"] = {
	"Dar Fur Daju",
	56370,
	"sdv-daj",
	"Latn",
}

m["dak"] = {
	"tiếng Dakota",
	530384,
	"sio-dkt",
	"Latn",
	"Tiếng Dakota",
	"Dakota",
}

m["dal"] = {
	"tiếng Dahalo",
	35143,
	"cus",
	"Latn",
	"Tiếng Dahalo",
	"Dahalo",
}

m["dam"] = {
	"Damakawa",
	1158134,
	"nic-knn",
	"Latn",
}

m["dao"] = {
	"Daai Chin",
	860029,
	"tbq-kuk",
	"Latn",
}

m["daq"] = {
	"Dandami Maria",
	12952805,
	"dra-mdy",
}

m["dar"] = {
	"tiếng Dargwa",
	32332,
	"cau-drg",
	"Cyrl, Latn, Arab",
	"Tiếng Dargwa",
	"Dargwa",
	translit = {Cyrl = "dar-translit"},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {
				"къкъ", "хьхь", -- 4 chars
				"гъ", "гь", "гӏ", "ё", "къ", "кь", "кӏ", "пп", "пӏ", "сс", "тт", "тӏ", "хх", "хъ", "хь", "хӏ", "цц", "цӏ", "чч", "чӏ" -- 2 chars
			},
			to = {
				"к" .. p[2], "х" .. p[4],
				"г" .. p[1], "г" .. p[2], "г" .. p[3], "е" .. p[1], "к" .. p[1], "к" .. p[3], "к" .. p[4], "п" .. p[1], "п" .. p[2], "с" .. p[1], "т" .. p[1], "т" .. p[2], "х" .. p[1], "х" .. p[2], "х" .. p[3], "х" .. p[5], "ц" .. p[1], "ц" .. p[2], "ч" .. p[1], "ч" .. p[2]
			}
		},
	},
}

m["das"] = {
	"Daho-Doo",
	3915369,
	"kro-wee",
	"Latn",
}

m["dau"] = {
	"Dar Sila Daju",
	7514020,
	"sdv-daj",
	"Latn",
}

m["dav"] = {
	"Taita",
	2387274,
	"bnt-cht",
	"Latn",
}

m["daw"] = {
	"Davawenyo",
	5228174,
	"phi",
	"Latn",
}

m["dax"] = {
	"Dayi",
	10467281,
	"aus-yol",
	"Latn",
}

m["daz"] = {
	"Dao",
	5221513,
	"ngf",
	"Latn",
}

m["dba"] = {
	"Bangime",
	1982696,
	"qfa-iso",
	"Latn",
}

m["dbb"] = {
	"Deno",
	56275,
	"cdc-wst",
	"Latn",
}

m["dbd"] = {
	"Dadiya",
	3914436,
	"alv-wjk",
	"Latn",
}

m["dbe"] = {
	"Dabe",
	5207451,
	"paa-tkw",
	"Latn",
}

m["dbf"] = {
	"Edopi",
	12953516,
	"paa-lkp",
	"Latn",
}

m["dbg"] = {
	"Dogul Dom",
	3912880,
	"nic-npd",
	"Latn",
}

m["dbi"] = {
	"Doka",
	3913293,
	"nic-plc",
	"Latn",
}

m["dbj"] = {
	"tiếng Ida'an",
	3041552,
	"poz-san",
	"Latn",
	"Tiếng Ida'an",
	"Ida'an",
}

m["dbl"] = {
	"tiếng Dyirbal",
	35465,
	"aus-dyb",
	"Latn",
	"Tiếng Dyirbal",
	"Dyirbal",
}

m["dbm"] = {
	"Duguri",
	7194057,
	"nic-jrw",
	"Latn",
}

m["dbn"] = {
	"Duriankere",
	5316627,
	"ngf-sbh",
	"Latn",
}

m["dbo"] = {
	"Dulbu",
	5313310,
	"nic-jrn",
	"Latn",
}

m["dbp"] = {
	"Duwai",
	56301,
	"cdc-wst",
	"Latn",
}

m["dbq"] = {
	"Daba",
	3913342,
	"cdc-cbm",
	"Latn",
}

m["dbr"] = {
	"tiếng Dabarre",
	3447286,
	"cus-som",
	nil,
	"Tiếng Dabarre",
	"Dabarre",
}

m["dbt"] = {
	"Ben Tey",
	4886561,
	"nic-nwa",
	"Latn",
}

m["dbu"] = {
	"Bondum Dom Dogon",
	3912758,
	"nic-npd",
	"Latn",
}

m["dbv"] = {
	"Dungu",
	5315230,
	"nic-kau",
	"Latn",
}

m["dbw"] = {
	"Bankan Tey Dogon",
	4856243,
	"nic-nwa",
	"Latn",
}

m["dby"] = {
	"Dibiyaso",
	5272268,
	"ngf",
	"Latn",
}

m["dcc"] = {
	"Deccani",
	669431,
	"inc-hnd",
	"ur-Arab",
	ancestors = "ur",
}

m["dcr"] = {
	"tiếng Negerhollands",
	1815830,
	"crp",
	"Latn",
	"Tiếng Negerhollands",
	"Negerhollands",
	ancestors = "nl",
}

m["dda"] = {
	"Dadi Dadi",
	nil,
	"aus-pam",
	"Latn",
}

m["ddd"] = {
	"Dongotono",
	56676,
	"sdv-lma",
}

m["dde"] = {
	"Doondo",
	11003401,
	"bnt-kng",
	"Latn",
}

m["ddg"] = {
	"tiếng Fataluku",
	35353,
	"qfa-tap",
	"Latn",
}

m["ddi"] = {
	"Diodio",
	3028668,
	"poz-ocw",
	"Latn",
}

m["ddj"] = {
	"Jaru",
	3162806,
	"aus-pam",
	"Latn",
}

m["ddn"] = {
	"Dendi",
	35164,
	"son",
	"Latn",
}

m["ddo"] = {
	"tiếng Tsez",
	34033,
	"cau-wts",
	"Cyrl",
	"Tiếng Tsez",
	"Tsez",
	translit = "ddo-translit",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["ddr"] = {
	"Dhudhuroa",
	5269842,
	"aus-pam",
	"Latn",
}

m["dds"] = {
	"Donno So Dogon",
	1234776,
	"nic-dge",
	"Latn",
}

m["ddw"] = {
	"Dawera-Daweloor",
	5242304,
	"poz-tim",
	"Latn",
}

m["dec"] = {
	"Dagik",
	35125,
	"alv-tal",
	"Latn",
}

m["ded"] = {
	"Dedua",
	5249850,
	"ngf",
	"Latn",
}

m["dee"] = {
	"Dewoin",
	3914892,
	"kro-wkr",
	"Latn",
}

m["def"] = {
	"Dezfuli",
	4115412,
	"ira-swi",
}

m["deg"] = {
	"tiếng Degema",
	35182,
	"alv-dlt",
	"Latn",
	"Tiếng Degema",
	"Degema",
}

m["deh"] = {
	"Dehwari",
	5704314,
	"ira-swi",
	ancestors = "fa",
}

m["dei"] = {
	"Demisa",
	56380,
	"paa-egb",
	"Latn",
}

m["dek"] = { -- called "unattested alleged language" by Wikipedia
	"Dek",
	5252754,
	nil,
	"Latn",
}

m["dem"] = {
	"Dem",
	5254989,
	"paa",
	"Latn",
}

m["dep"] = {
	"Pidgin Delaware",
	nil,
	"crp",
	"Latn",
	ancestors = "unm",
}

-- deq is not included, see [[WT:LT]]

m["der"] = {
	"tiếng Deori",
	56478,
	"tbq-bdg",
	"Beng, Latn",
	"Tiếng Deori",
	"Deori",
}

m["des"] = {
	"Desano",
	962392,
	"sai-tuc",
	"Latn",
}

m["dev"] = {
	"Domung",
	5291378,
	"ngf-fin",
	"Latn",
}

m["dez"] = {
	"Dengese",
	2909984,
	"bnt-tet",
	"Latn",
}

m["dga"] = {
	"Southern Dagaare",
	35159,
	"nic-mre",
	"Latn",
}

m["dgb"] = {
	"Bunoge",
	4985178,
	"nic-dgw",
	"Latn",
}

m["dgc"] = {
	"Casiguran Dumagat Agta",
	5313599,
	"phi",
	"Latn",
}

m["dgd"] = {
	"Dagaari Dioula",
	11153465,
	"nic-mre",
	"Latn",
}

m["dge"] = {
	"Degenan",
	5251770,
	"ngf-fin",
	"Latn",
}

m["dgg"] = {
	"Doga",
	3033726,
	"poz-ocw",
	"Latn",
}

m["dgh"] = {
	"Dghwede",
	56293,
	"cdc-cbm",
	"Latn",
}

m["dgi"] = {
	"tiếng Dagara Bắc",
	11004218,
	"nic-mre",
	"Latn",
	"Tiếng Dagara Bắc",
	"Dagara Bắc",
}

m["dgk"] = {
	"tiếng Dagba",
	12952357,
	"csu-sar",
	"Latn",
	"Tiếng Dagba",
	"Dagba",
}

m["dgn"] = {
	"Dagoman",
	10465931,
	"aus-yng",
	"Latn",
}

m["dgo"] = {
	"tiếng Dogri Hindi",
	nil,
	"him",
	"Deva, Arab, Takr",
	"Tiếng Dogri Hindi",
	"Dogri Hindi",
	ancestors = "doi",
}

m["dgr"] = {
	"tiếng Dogrib",
	20979,
	"ath-nor",
	"Latn",
	"Tiếng Dogrib",
	"Dogrib",
}

m["dgs"] = {
	"Dogoso",
	35343,
	"nic-gur",
}

m["dgt"] = {
	"Ntra'ngith",
	6983809,
	"aus-pam",
	"Latn",
}

-- dgu is not a language; see [[w:Dhekaru]]

m["dgw"] = {
	"Daungwurrung",
	5228050,
	"aus-pam",
	"Latn",
}

m["dgx"] = {
	"Doghoro",
	12952392,
	"ngf",
	"Latn",
}

m["dgz"] = {
	"tiếng Daga",
	5208442,
	"ngf-dag",
	"Latn",
}

m["dhg"] = {
	"tiếng Dhangu",
	5268960,
	"aus-yol",
	"Latn",
	"Tiếng Dhangu",
	"Dhangu",
}

m["dhd"] = {
	"tiếng Dhundhar",
	633359,
	"raj",
	"Deva",
	"Tiếng Dhundhar",
	"Dhundhar",
	translit = "hi-translit",
}

m["dhi"] = {
	"tiếng Dhimal",
	35229,
	"sit-dhi",
	"Deva",
	"Tiếng Dhimal",
	"Dhimal",
}

m["dhl"] = {
	"Dhalandji",
	5268787,
	"aus-psw",
	"Latn",
}

m["dhm"] = {
	"Zemba",
	3502283,
	"bnt-swb",
	"Latn",
	ancestors = "hz",
}

m["dhn"] = {
	"tiếng Dhanka",
	5268992,
	"inc-bhi",
	"Deva, Gujr",
	"Tiếng Dhanka",
	"Dhanka",
}

m["dho"] = {
	"tiếng Dhodia",
	5269658,
	"inc-bhi",
	"Deva, Gujr",
	"Tiếng Dhodia",
	"Dhodia",
}

m["dhr"] = {
	"Tharrgari",
	10470289,
	"aus-psw",
	"Latn",
}

m["dhs"] = {
	"Dhaiso",
	11001788,
	"bnt-kka",
	"Latn",
}

m["dhu"] = {
	"Dhurga",
	1285318,
	"aus-yuk",
	"Latn",
}

m["dhv"] = {
	"Drehu",
	3039319,
	"poz-cln",
	"Latn",
}

m["dhw"] = {
	"tiếng Danuwar",
	3522797,
	"inc-bhi",
	"Deva",
	"Tiếng Danuwar",
	"Danuwar",
}

m["dhx"] = {
	"Dhungaloo",
	16960599,
	"aus-pam",
	"Latn",
}

m["dia"] = {
	"Dia",
	3446591,
	"qfa-tor",
	"Latn",
}

m["dib"] = {
	"South Central Dinka",
	35154,
	"sdv-dnu",
	"Latn",
	ancestors = "din",
}

m["dic"] = {
	"Lakota Dida",
	11001730,
	"kro-did",
	"Latn",
}

m["did"] = {
	"Didinga",
	56365,
	"sdv",
	"Latn",
}

m["dif"] = {
	"tiếng Dieri",
	25559563,
	"aus-kar",
	"Latn",
	"Tiếng Dieri",
	"Dieri",
}

m["dig"] = {
	"Digo",
	3362072,
	"bnt-mij",
	"Latn",
}

-- "dih" IS SPLIT INTO nai-ipa, nai-kum, nai-tip, SEE WT:LT

m["dii"] = {
	"Dimbong",
	35196,
	"bnt-baf",
	"Latn",
}

m["dij"] = {
	"Dai",
	5209056,
	"poz-tim",
}

m["dik"] = {
	"Southwestern Dinka",
	36540,
	"sdv-dnu",
	"Latn",
	ancestors = "din",
}

m["dil"] = {
	"Dilling",
	35152,
	"nub-hil",
	"Latn",
}

m["dim"] = {
	"tiếng Dime",
	35311,
	"omv-aro",
	"Ethi",
	"Tiếng Dime",
	"Dime",
	translit = "Ethi-translit",
}

m["din"] = {
	"tiếng Dinka",
	56466,
	"sdv-dnu",
	"Latn",
	"Tiếng Dinka",
	"Dinka",
}

m["dio"] = {
	"Dibo",
	3914891,
	"alv-ngb",
	"Latn",
}

m["dip"] = {
	"Northeastern Dinka",
	36246,
	"sdv-dnu",
	"Latn",
	ancestors = "din",
}

m["dir"] = {
	"Dirim",
	11130804,
	"nic-dak",
	"Latn",
}

m["dis"] = {
	"tiếng Dimasa",
	56664,
	"tbq-bdg",
	"Latn, Beng",
	"Tiếng Dimasa",
	"Dimasa",
}

m["diu"] = {
	"Gciriku",
	3780954,
	"bnt-kav",
	"Latn",
}

m["diw"] = {
	"Northwestern Dinka",
	36249,
	"sdv-dnu",
	"Latn",
	ancestors = "din",
}

m["dix"] = {
	"Dixon Reef",
	5284967,
	"poz-vnc",
	"Latn",
}

m["diy"] = {
	"Diuwe",
	5283765,
	"ngf",
}

m["diz"] = {
	"Ding",
	35202,
	"bnt-bdz",
	"Latn",
}

m["dja"] = {
	"Djadjawurrung",
	5285190,
	"aus-pam",
	"Latn",
}

m["djb"] = {
	"Djinba",
	5285351,
	"aus-yol",
	"Latn",
}

m["djc"] = {
	"tiếng Dar Daju Daju",
	5209890,
	"sdv-daj",
	"Latn",
	"Tiếng Dar Daju Daju",
	"Dar Daju Daju",
}

m["djd"] = {
	"Jaminjung",
	6147825,
	"aus-mir",
	"Latn",
}

m["dje"] = {
	"tiếng Zarma",
	36990,
	"son",
	"Latn, Arab, Brai",
	"Tiếng Zarma",
	"Zarma",
}

m["djf"] = {
	"Djangun",
	10474818,
	"aus-pmn",
	"Latn",
}

m["dji"] = {
	"tiếng Djinang",
	5285350,
	"aus-yol",
	"Latn",
	"Tiếng Djinang",
	"Djinang",
}

m["djj"] = {
	"Ndjébbana",
	5285274,
	"aus-arn",
	"Latn",
}

m["djk"] = {
	"tiếng Aukan",
	2659044,
	"crp",
	"Latn, Afak",
	ancestors = "en",
	"Tiếng Aukan",
	"Aukan",
}

m["djl"] = {
	"Djiwarli",
	nil,
	"aus-psw",
	"Latn",
}

m["djm"] = {
	"Jamsay",
	3913290,
	"nic-pld",
	"Latn",
}

m["djn"] = {
	"Djauan",
	13553748,
	"aus-gun",
	"Latn",
}

m["djo"] = {
	"Jangkang",
	12952388,
	"day",
}

m["djr"] = {
	"Djambarrpuyngu",
	3915679,
	"aus-yol",
	"Latn",
}

m["dju"] = {
	"Kapriman",
	6367199,
	"paa-spk",
	"Latn",
}

m["djw"] = {
	"Djawi",
	3913844,
	"aus-nyu",
	"Latn",
	ancestors = "bcj",
}

m["dka"] = {
	"tiếng Dakpa",
	3695189,
	"sit-ebo",
	"Tibt",
	"Tiếng Dakpa",
	"Dakpa",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["dkk"] = {
	"Dakka",
	5209962,
	"poz-ssw",
}

m["dkr"] = {
	"Kuijau",
	13580777,
	"poz-bnn",
}

m["dks"] = {
	"Southeastern Dinka",
	36538,
	"sdv-dnu",
	"Latn",
	ancestors = "din",
}

m["dkx"] = {
	"Mazagway",
	6798209,
	"cdc-cbm",
	"Latn",
}

m["dlg"] = {
	"tiếng Dolgan",
	32878,
	"trk-nsb",
	"Cyrl",
	"Tiếng Dolgan",
	"Dolgan",
	translit = {Cyrl = "dlg-translit"},
	sort_key = {
		from = {"ё", "һ", "ӈ", "ө", "ү"},
		to = {"е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1]}
	},
}

m["dlk"] = {
	"tiếng Dahalik",
	32260,
	"sem-eth",
	"Ethi",
	"Tiếng Dahalik",
	"Dahalik",
	translit = "Ethi-translit",
}

m["dlm"] = {
	"tiếng Dalmatia",
	35527,
	"roa-itd",
	"Latn",
	"Tiếng Dalmatia",
	"Dalmatia",
}

m["dln"] = {
	"Darlong",
	5224029,
	"tbq-kuk",
	"Latn",
}

m["dma"] = {
	"Duma",
	35319,
	"bnt-nze",
	"Latn",
}

m["dmb"] = {
	"Mombo Dogon",
	6897074,
	"nic-dgw",
	"Latn",
}

m["dmc"] = {
	"Gavak",
	5277406,
	"ngf-mad",
	"Latn",
}

m["dmd"] = {
	"Madhi Madhi",
	6727353,
	"aus-pam",
	"Latn",
}

m["dme"] = {
	"Dugwor",
	56313,
	"cdc-cbm",
	"Latn",
}

m["dmf"] = {
	"Medefaidrin",
	1519764,
	"art",
	"Medf",
	type = "appendix-constructed",
}

m["dmg"] = {
	"tiếng Thượng Kinabatangan",
	16109975,
	"poz-san",
	"Latn",
	"Tiếng Thượng Kinabatangan",
	"Thượng Kinabatangan",
}

m["dmk"] = {
	"tiếng Domaaki",
	32900,
	"inc-wes",
}

m["dml"] = {
	"tiếng Damel",
	32288,
	"inc-kun",
	"Arab",
	"Tiếng Damel",
	"Damel",
}

m["dmm"] = {
	"Dama (Nigeria)",
	5211865,
	"alv-mbm",
	"Latn",
}

m["dmo"] = {
	"Kemezung",
	35562,
	"nic-bbe",
	"Latn",
}

m["dmr"] = {
	"East Damar",
	5328200,
	"poz-cet",
	"Latn",
}

m["dms"] = {
	"Dampelas",
	5212928,
	"poz-tot",
	"Latn",
}

m["dmu"] = {
	"Dubu",
	7692059,
	"paa-pau",
	"Latn",
}

m["dmv"] = {
	"Dumpas",
	12953512,
	"poz-san",
	"Latn",
}

m["dmw"] = {
	"tiếng Mudburra",
	6931573,
	"aus-pam",
	"Latn",
	"Tiếng Mudburra",
	"Mudburra",
}

m["dmx"] = {
	"Dema",
	3553423,
	"bnt-sho",
	"Latn",
}

m["dmy"] = {
	"Demta",
	14466283,
	"paa-sen",
	"Latn",
}

m["dna"] = {
	"Upper Grand Valley Dani",
	12952361,
	"ngf",
	"Latn",
}

m["dnd"] = {
	"Daonda",
	5221528,
	"paa-brd",
	"Latn",
}

m["dne"] = {
	"Ndendeule",
	6983725,
	"bnt-mbi",
	"Latn",
}

m["dng"] = {
	"tiếng Đông Can",
	33050,
	"zhx-man",
	"Cyrl, Hants, Arab",
	"Tiếng Đông Can",
	"Đông Can",
	generate_forms = "zh-generateforms",
	translit = {Cyrl = "dng-translit"},
	sort_key = {
		Cyrl = {
			from = {"ё", "ә", "җ", "ң", "ў", "ү"},
			to = {"е" .. p[1], "е" .. p[2], "ж" .. p[1], "н" .. p[1], "у" .. p[1], "у" .. p[2]}
		},
		Hani = "Hani-sortkey",
	},
}

m["dni"] = {
	"Lower Grand Valley Dani",
	12635807,
	"ngf",
	"Latn",
}

m["dnj"] = {
	"tiếng Dan",
	1158971,
	"dmn-mda",
	"Latn",
	"Tiếng Dan",
	"Dan",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.macron .. c.dgrave .. c.dacute .. c.circ .. c.diaer}}
}

m["dnk"] = {
	"Dengka",
	5256954,
	"poz-tim",
	"Latn",
}

m["dnn"] = {
	"tiếng Dzuun",
	10973260,
	"dmn-smg",
	nil,
	"Tiếng Dzuun",
	"Dzuun",
}

m["dno"] = {
	"Ndrulo",
	60785094,
	"csu-lnd",
}

m["dnr"] = {
	"Danaru",
	5214932,
	"ngf-mad",
	"Latn",
}

m["dnt"] = {
	"Mid Grand Valley Dani",
	12952359,
	"ngf",
	"Latn",
}

m["dnu"] = {
	"tiếng Danau",
	5013745,
	"mkh-pal",
	"Mymr",
	"Tiếng Danau",
	"Danau",
}

m["dnv"] = {
	"tiếng Danu",
	5221251,
	"tbq-brm",
	"Mymr",
	"Tiếng Danu",
	"Danu",
	ancestors = "obr",
}

m["dnw"] = {
	"Western Dani",
	7987774,
	"ngf",
	"Latn",
}

m["dny"] = {
	"Dení",
	56562,
	"auf",
	"Latn",
}

m["doa"] = {
	"Dom",
	5289770,
	"ngf",
	"Latn",
}

m["dob"] = {
	"Dobu",
	952133,
	"poz-ocw",
	"Latn",
}

m["doc"] = {
	"Northern Kam",
	17195499,
	"qfa-tak",
	"Latn",
}

m["doe"] = {
	"Doe",
	5288055,
	"bnt-ruv",
	"Latn",
}

m["dof"] = {
	"Domu",
	5291375,
	"ngf",
	"Latn",
}

m["doh"] = {
	"Dong",
	3438405,
	"nic-dak",
	"Latn",
}

m["doi"] = {
	"tiếng Dogri",
	32730,
	"him",
	"Deva, Takr, fa-Arab, Dogr",
	"Tiếng Dogri",
	"Dogri",
	translit = {
		Deva = "hi-translit",
		Dogr = "Dogr-translit",
	},
}

m["dok"] = {
	"Dondo",
	5295571,
	"poz-tot",
	"Latn",
}

m["dol"] = {
	"Doso",
	4167202,
	"paa",
	"Latn",
}

m["don"] = {
	"Doura",
	7829037,
	"poz-ocw",
	"Latn",
}

m["doo"] = {
	"Dongo",
	35303,
	"nic-mbc",
	"Latn",
}

m["dop"] = {
	"tiếng Lukpa",
	3258739,
	"nic-gne",
	"Latn",
	"Tiếng Lukpa",
	"Lukpa",
}

m["doq"] = {
	"Dominican Sign Language",
	5290820,
	"sgn",
	"Latn", -- when documented
}

m["dor"] = {
	"Dori'o",
	3037084,
	"poz-sls",
	"Latn",
}

m["dos"] = {
	"Dogosé",
	3913314,
	"nic-gur",
	"Latn",
}

m["dot"] = {
	"Dass",
	3441293,
	"cdc-wst",
	"Latn",
}

m["dov"] = {
	"Toka-Leya",
	11001779,
	"bnt-bot",
	"Latn",
	ancestors = "toi",
}

m["dow"] = {
	"Doyayo",
	35299,
	"alv-dur",
	"Latn",
}

m["dox"] = {
	"tiếng Bussa",
	35123,
	"cus-eas",
	"Latn, Ethi",
	"Tiếng Bussa",
	"Bussa",
}

m["doy"] = {
	"Dompo",
	35270,
	"alv-gng",
	"Latn",
}

m["doz"] = {
	"Dorze",
	56336,
	"omv-nom",
	"Latn",
}

m["dpp"] = {
	"Papar",
	7132487,
	"poz-san",
	"Latn",
}

m["drb"] = {
	"Dair",
	12952360,
	"nub-hil",
	"Latn",
}

m["drc"] = {
	"Minderico",
	6863806,
	"roa-ibe",
	"Latn",
	ancestors = "pt",
}

m["drd"] = {
	"Darmiya",
	5224058,
	"sit-alm",
}

m["dre"] = {
	"tiếng Dolpo",
	12629969,
	"sit-tib",
	"Tibt",
	"Tiếng Dolpo",
	"Dolpo",
	translit = { Tibt = "Tibt-translit" },
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["drg"] = {
	"tiếng Rungus",
	6897407,
	"poz-san",
	"Latn",
	"Tiếng Rungus",
	"Rungus",
}

m["dri"] = {
	"Lela",
	3914004,
	"nic-knn",
	"Latn",
}

m["drl"] = {
	"tiếng Baagandji",
	5223941,
	"aus-pam",
	"Latn",
	"Tiếng Baagandji",
	"Baagandji",
}

m["drn"] = {
	"West Damar",
	3450459,
	"poz-tim",
	"Latn",
}

m["dro"] = {
	"Daro-Matu Melanau",
	5224156,
	"poz-bnn",
	"Latn",
}

m["drq"] = {
	"Dura",
	3449842,
	"sit-gma",
}

m["drs"] = {
	"tiếng Gedeo",
	56622,
	"cus-hec",
	"Ethi",
	"Tiếng Gedeo",
	"Gedeo",
}

m["dru"] = {
	"tiếng Rukai",
	49232,
	"map",
	"Latn",
	"Tiếng Rukai",
	"Rukai",
	ancestors = "dru-pro",
}

m["dry"] = {
	"Darai",
	46995026,
	"inc-bhi",
	"Deva",
}

m["dsb"] = {
	"tiếng Hạ Sorb",
	13286,
	"wen",
	"Latn",
	"Tiếng Hạ Sorb",
	"Hạ Sorb",
	sort_key = s["wen-sortkey"],
	standardChars = "AaBbCcČčĆćDdEeĚěFfGgHhIiJjKkŁłLlMmNnŃńOoÓóPpRrŔŕSsŠšŚśTtUuWwYyZzŽžŹź" .. c.punc,
}

m["dse"] = {
	"Dutch Sign Language",
	2201099,
	"sgn",
	"Latn", -- when documented
}

m["dsh"] = {
	"tiếng Daasanach",
	56637,
	"cus-eas",
	"Latn",
	"Tiếng Daasanach",
	"Daasanach",
}

m["dsi"] = {
	"Disa",
	3914455,
	"csu-bgr",
	"Latn",
}

m["dsl"] = {
	"Danish Sign Language",
	2605298,
	"sgn",
	"Latn", -- when documented
}

m["dsn"] = {
	"Dusner",
	5316948,
	"poz-hce",
	"Latn",
}

m["dso"] = {
	"tiếng Desiya",
	12629755,
	"inc-eas",
	"Orya",
	"Tiếng Desiya",
	"Desiya",
	ancestors = "or",
}

m["dsq"] = {
	"Tadaksahak",
	36568,
	"son",
	"Arab, Latn",
}

m["dta"] = {
	"tiếng Daur",
	32430,
	"xgn",
	"Latn, Hani, Cyrl, Mong",
	"Tiếng Daur",
	"Daur",
	ancestors = "xng",
	translit = {Mong = "Mong-translit"},
	display_text = {Mong = s["Mong-displaytext"]},
	entry_name = {Mong = s["Mong-entryname"]},
	sort_key = {Hani = "Hani-sortkey"},
}

m["dtb"] = {
	"Labuk-Kinabatangan Kadazan",
	5330240,
	"poz-san",
	"Latn",
}

m["dtd"] = {
	"tiếng Ditidaht",
	13728042,
	"wak",
	"Latn",
	"Tiếng Ditidaht",
	"Ditidaht",
}

m["dth"] = { -- contrast 'rrt'
	"Adithinngithigh",
	4683034,
	"aus-pmn",
	"Latn",
}

m["dti"] = {
	"Ana Tinga Dogon",
	4750346,
	"qfa-dgn",
	"Latn",
}

m["dtk"] = {
	"Tene Kan Dogon",
	11018863,
	"nic-pld",
	"Latn",
}

m["dtm"] = {
	"Tomo Kan Dogon",
	11137719,
	"nic-pld",
	"Latn",
}

m["dto"] = {
	"Tommo So",
	47012992,
	"nic-dge",
	"Latn",
}

m["dtp"] = {
	"tiếng Trung Dusun",
	5317225,
	"poz-san",
	"Latn",
	"Tiếng Trung Dusun",
	"Trung Dusun",
}

m["dtr"] = {
	"Lotud",
	6685078,
	"poz-san",
	"Latn",
}

m["dts"] = {
	"Toro So Dogon",
	11003311,
	"nic-dge",
	"Latn",
}

m["dtt"] = {
	"Toro Tegu Dogon",
	3913924,
	"nic-pld",
	"Latn",
}

m["dtu"] = {
	"Tebul Ure Dogon",
	7692089,
	"qfa-dgn",
	"Latn",
}

m["dty"] = {
	"tiếng Doteli",
	18415595,
	"inc-pah",
	"Deva",
	"Tiếng Doteli",
	"Doteli",
	translit = "ne-translit",
}

m["dua"] = {
	"Duala",
	33013,
	"bnt-saw",
	"Latn",
}

m["dub"] = {
	"tiếng Dubla",
	5310792,
	"inc-bhi",
	"Gujr",
	"Tiếng Dubla",
	"Dubla",
}

m["duc"] = {
	"Duna",
	5314039,
	"paa",
	"Latn",
}

m["due"] = {
	"Umiray Dumaget Agta",
	7881585,
	"phi",
	"Latn",
}

m["duf"] = {
	"Dumbea",
	6983819,
	"poz-cln",
	"Latn",
}

m["dug"] = {
	"Chiduruma",
	35614,
	"bnt-mij",
	"Latn",
}

m["duh"] = {
	"tiếng Bhil Dungra",
	12953513,
	"inc-bhi",
	"Deva, Gujr",
	"Tiếng Bhil Dungra",
	"Bhil Dungra",
}

m["dui"] = {
	"Dumun",
	5314004,
	"ngf-mad",
	"Latn",
}

m["duk"] = {
	"Uyajitaya",
	7904085,
	"ngf-mad",
	"Latn",
}

m["dul"] = {
	"Alabat Island Agta",
	3399709,
	"phi",
	"Latn",
}

m["dum"] = {
	"tiếng Hà Lan trung đại",
	178806,
	"gmw-frk",
	"Latn",
	"Tiếng Hà Lan trung đại",
	"Hà Lan trung đại",
	entry_name = {remove_diacritics = c.circ .. c.macron .. c.diaer},
}

m["dun"] = {
	"Dusun Deyah",
	2784033,
	"poz-bre",
	"Latn",
}

m["duo"] = {
	"tiếng Agta Dupaningan",
	5315912,
	"phi",
	"Latn",
	"Tiếng Agta Dupaningan",
	"Agta Dupaningan",
}

m["dup"] = {
	"Duano",
	3040468,
	"poz-mly",
	"Latn",
}

m["duq"] = {
	"Dusun Malang",
	3041711,
	"poz-bre",
	"Latn",
}

m["dur"] = {
	"tiếng Dii",
	nil,
	"alv-dur",
	"Latn",
	"Tiếng Dii",
	"Dii",
}

m["dus"] = {
	"tiếng Dumi",
	56315,
	"sit-kiw",
	"Deva",
	"Tiếng Dumi",
	"Dumi",
}

m["duu"] = {
	"tiếng Độc Long",
	56406,
	"sit-nng",
	nil,
	"Tiếng Độc Long",
	"Độc Long",
}

m["duv"] = {
	"Duvle",
	56364,
	"paa-lkp",
	"Latn",
}

m["duw"] = {
	"tiếng Dusun Witu",
	2381310,
	"poz-bre",
	"Latn",
	"Tiếng Dusun Witu",
	"Dusun Witu",
}

m["dux"] = {
	"tiếng Duun",
	3914880,
	"dmn-smg",
	"Latn",
	"Tiếng Duun",
	"Duun",
}

m["duy"] = {
	"Dicamay Agta",
	5272321,
	"phi",
	"Latn",
}

m["duz"] = {
	"Duli",
	5313405,
	"alv-ada",
	"Latn",
}

m["dva"] = {
	"Duau",
	5310448,
	"poz-ocw",
	"Latn",
}

m["dwa"] = {
	"Diri",
	56286,
	"cdc-wst",
	"Latn",
}

m["dwk"] = {
	"tiếng Kui Dawik",
	111360885,
	"dra-kki",
	"Orya",
	"Tiếng Kui Dawik",
	"Kui Dawik",
	translit = "kxv-translit",
	entry_name = {
		remove_diacritics = "୕",
		from = {"ଆଆ", "ଇଇ", "ଉଉ", "ଏଏ", "ଓଓ", "ିଇ", "ୁଉ", "େଏ", "ୋଓ"},
		to = {"ଆ", "ଈ", "ଊ", "ଏ", "ଓ", "ୀ", "ୂ", "େ", "ୋ"},
	},
}

m["dwr"] = {
	"tiếng Dawro",
	12629647,
	"omv-nom",
	"Ethi, Latn",
	"Tiếng Dawro",
	"Dawro",
}

m["dwu"] = {
	"Dhuwal",
	nil,
	"aus-yol",
	"Latn",
}

m["dww"] = {
	"Dawawa",
	5242286,
	"poz-ocw",
	"Latn",
}

m["dwy"] = {
	"Dhuwaya",
	nil,
	"aus-yol",
	"Latn",
}

m["dwz"] = {
	"Dewas Rai",
	62663667,
	"inc-bhi",
}

m["dya"] = {
	"Dyan",
	35340,
	"nic-gur",
	"Latn",
}

m["dyb"] = {
	"Dyaberdyaber",
	5285185,
	"aus-nyu",
	"Latn",
}

m["dyd"] = {
	"Dyugun",
	3913785,
	"aus-nyu",
	"Latn",
}

m["dyg"] = {
	"Villa Viciosa Agta",
	12626611,
	"phi",
	"Latn",
}

m["dyi"] = {
	"Djimini",
	35336,
	"alv-tdj",
	"Latn",
}

m["dym"] = {
	"Yanda Dogon",
	8048316,
	"qfa-dgn",
	"Latn",
}

m["dyn"] = {
	"Dyangadi",
	3913820,
	"aus-cww",
	"Latn",
}

m["dyo"] = {
	"Jola-Fonyi",
	3507832,
	"alv-jol",
	"Latn",
}

m["dyu"] = {
	"tiếng Dyula",
	32706,
	"dmn-man",
	"Latn",
	"Tiếng Dyula",
	"Dyula",
}

m["dyy"] = {
	"Dyaabugay",
	2591320,
	"aus-pmn",
	"Latn",
}

m["dza"] = {
	"Tunzu",
	3915845,
	"nic-jer",
	"Latn",
}

m["dzg"] = {
	"Dazaga",
	35244,
	"ssa-sah",
	"Latn",
}

m["dzl"] = {
	"tiếng Dzala",
	56607,
	"sit-ebo",
	"Tibt",
	"Tiếng Dzala",
	"Dzala",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["dzn"] = {
	"Dzando",
	5319622,
	"bnt-bun",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")