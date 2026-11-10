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

m["taa"] = {
	"tiếng Hạ Tanana",
	28565,
	"ath-nor",
	"Latn",
	"Tiếng Hạ Tanana",
	"Hạ Tanana",
}

m["tab"] = {
	"tiếng Tabasaran",
	34079,
	"cau-esm",
	"Cyrl, Latn, Arab",
	"Tiếng Tabasaran",
	"Tabasaran",
	translit = "tab-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = "tab-sortkey",
}

m["tac"] = {
	"Lowland Tarahumara",
	15616384,
	"azc-trc",
	"Latn",
}

m["tad"] = {
	"tiếng Tause",
	2356440,
	"paa-wlp",
	"Latn",
}

m["tae"] = {
	"tiếng Tariana",
	732726,
	"awd-nwk",
	"Latn",
	"Tiếng Tariana",
	"Tariana",
}

m["taf"] = {
	"tiếng Tapirapé",
	7684673,
	"tup-gua",
	"Latn",
	"Tiếng Tapirapé",
	"Tapirapé",
}

m["tag"] = {
	"tiếng Tagoi",
	36537,
	"nic-ras",
	"Latn",
	"Tiếng Tagoi",
	"Tagoi",
}

m["taj"] = {
	"tiếng Tamang Đông",
	12953177,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	display_text = {["sit-tam-Tibt"] = s["Tibt-displaytext"]},
	entry_name = {["sit-tam-Tibt"] = s["Tibt-entryname"]},
	"Tiếng Tamang Đông",
	"Tamang Đông",
}

m["tak"] = {
	"tiếng Tala",
	3914494,
	"cdc-wst",
	"Latn",
	"Tiếng Tala",
	"Tala",
}

m["tal"] = {
	"tiếng Tal",
	3440387,
	"cdc-wst",
	"Latn",
	"Tiếng Tal",
	"Tal",
}

m["tan"] = {
	"Tangale",
	529921,
	"cdc-wst",
	"Latn",
}

m["tao"] = {
	"tiếng Yami",
	715760,
	"phi",
	"Latn",
	"Tiếng Yami",
	"Yami",
}

m["tap"] = {
	"tiếng Taabwa",
	7673650,
	"bnt-sbi",
	"Latn",
	"Tiếng Taabwa",
	"Taabwa",
}

m["tar"] = {
	"Central Tarahumara",
	20090009,
	"azc-trc",
	"Latn",
	sort_key = {remove_diacritics = c.acute .. "ꞌ"},
}

m["tas"] = {
	"tiếng Tây Bồi",
	2233794,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
	"Tiếng Tây Bồi",
	"Tây Bồi",
}

m["tau"] = {
	"Upper Tanana",
	28281,
	"ath-nor",
	"Latn",
}

m["tav"] = {
	"tiếng Tatuyo",
	2524007,
	"sai-tuc",
	"Latn",
	"Tiếng Tatuyo",
	"Tatuyo",
}

m["taw"] = {
	"Tai",
	7675861,
	"ngf-mad",
	"Latn",
}

m["tax"] = {
	"tiếng Tamki",
	3449082,
	"cdc-est",
	"Latn",
	"Tiếng Tamki",
	"Tamki",
}

m["tay"] = {
	"tiếng Atayal",
	715766,
	"map-ata",
	"Latn",
	"Tiếng Atayal",
	"Atayal",
}

m["taz"] = {
	"tiếng Tocho",
	36680,
	"alv-tal",
	"Latn",
	"Tiếng Tocho",
	"Tocho",
}

m["tba"] = {
	"Aikanã",
	3409307,
	"qfa-iso",
}

m["tbb"] = {
	"Tapeba",
	12953908,
}

m["tbc"] = {
	"Takia",
	3514336,
	"poz-oce",
}

m["tbd"] = {
	"tiếng Kaki Ae",
	6349417,
	"poz-ocw",
	"Latn",
	"Tiếng Kaki Ae",
	"Kaki Ae",
}

m["tbe"] = {
	"tiếng Tanimbili",
	3515188,
	"poz-oce",
	"Latn",
	"Tiếng Tanimbili",
	"Tanimbili",
}

m["tbf"] = {
	"tiếng Mandara",
	3285424,
	"poz-ocw",
	"Latn",
	"Tiếng Mandara",
	"Mandara"
}

m["tbg"] = {
	"North Tairora",
	20210398,
	"paa-kag",
}

m["tbh"] = {
	"Thurawal",
	3537135,
	"aus-yuk",
}

m["tbi"] = {
	"Gaam",
	35338,
	"sdv-eje",
	"Latn",
}

m["tbj"] = {
	"tiếng Tiang",
	3528020,
	"poz-ocw",
	"Latn",
	"Tiếng Tiang",
	"Tiang",
}

m["tbk"] = {
	"tiếng Tagbanwa Calamian",
	3915487,
	"phi-kal",
	"Latn",
	"Tiếng Tagbanwa Calamian",
	"Tagbanwa Calamian",
}

m["tbl"] = {
	"Tboli",
	7690594,
	"phi",
}

m["tbm"] = {
	"Tagbu",
	7675188,
	"nic-ser",
}

m["tbn"] = {
	"Barro Negro Tunebo",
	12953943,
	"cba",
}

m["tbo"] = {
	"Tawala",
	7689206,
	"poz-ocw",
	"Latn",
}

m["tbp"] = {
	"Taworta",
	7689337,
	"paa-lkp",
	"Latn",
}

m["tbr"] = {
	"Tumtum",
	3407029,
	"qfa-kad",
}

m["tbs"] = {
	"Tanguat",
	7683166,
	"paa",
	"Latn",
}

m["tbt"] = {
	"Kitembo",
	13123561,
	"bnt-shh",
	"Latn",
}

m["tbu"] = {
	"Tubar",
	56730,
	"azc-trc",
	"Latn",
}

m["tbv"] = {
	"Tobo",
	7811712,
	"ngf",
}

m["tbw"] = {
	"Tagbanwa",
	3915475,
	"phi",
	"Latn",
}

m["tbx"] = {
	"Kapin",
	6366665,
	"poz-ocw",
	"Latn",
}

m["tby"] = {
	"Tabaru",
	11732670,
	"paa-nha",
}

m["tbz"] = {
	"tiếng Tammari",
	35186,
	"nic-eov",
	"Latn",
	"Tiếng Tammari",
	"Tammari",
}

m["tca"] = {
	"Ticuna",
	1815205,
	"sai-tyu",
	"Latn",
}

m["tcb"] = {
	"Tanacross",
	28268,
	"ath-nor",
	"Latn",
}

m["tcc"] = {
	"Datooga",
	35327,
	"sdv-nis",
	"Latn",
}

m["tcd"] = {
	"tiếng Tafi",
	36545,
	"alv-ktg",
	"Latn",
	"Tiếng Tafi",
	"Tafi",
}

m["tce"] = {
	"Southern Tutchone",
	31091048,
	"ath-nor",
	"Latn",
}

m["tcf"] = {
	"tiếng Tlapanec Malinaltepec",
	25559732,
	"omq",
	"Latn",
	"Tiếng Tlapanec Malinaltepec",
	"Tlapanec Malinaltepec",
}

m["tcg"] = {
	"Tamagario",
	7680531,
	"ngf",
}

m["tch"] = {
	"Turks and Caicos Creole English",
	7855478,
	"crp",
	"Latn",
	ancestors = "en",
}

m["tci"] = {
	"Wára",
	20825638,
	"paa-yam",
}

m["tck"] = {
	"Tchitchege",
	36595,
	"bnt-tek",
}

m["tcl"] = {
	"Taman (Myanmar)",
	15616518,
	"sit-jnp",
	"Latn",
}

m["tcm"] = {
	"Tanahmerah",
	3514927,
	"ngf",
}

m["tco"] = {
	"tiếng Taungyo",
	12953186,
	"tbq-brm",
	"Mymr",
	"Tiếng Taungyo",
	"Taungyo",
	ancestors = "obr",
}

m["tcp"] = {
	"Tawr Chin",
	7689338,
	"tbq-kuk",
}

m["tcq"] = {
	"Kaiy",
	6348709,
	"paa-lkp",
}

m["tcs"] = {
	"Torres Strait Creole",
	36648,
	"crp",
	"Latn",
	ancestors = "en",
}

m["tct"] = {
	"T'en",
	3442330,
	"qfa-kms",
}

m["tcu"] = {
	"Southeastern Tarahumara",
	36807,
	"azc-trc",
	"Latn",
}

m["tcw"] = {
	"Tecpatlán Totonac",
	7692795,
	"nai-ttn",
	"Latn",
}

m["tcx"] = {
	"tiếng Toda",
	34042,
	"dra-tkt",
	"Taml",
	"Tiếng Toda",
	"Toda",
}

m["tcy"] = {
	"tiếng Tulu",
	34251,
	"dra-tlk",
	"Tutg, Mlym, Knda", -- Tigalari is not available. Mlym is nearer than Knda but both lack ɛ/ɛː.
	"Tiếng Tulu",
	"Tulu",
	translit = {
		Mlym = "ml-translit",
		Knda = "kn-translit",
	},
}

m["tcz"] = {
	"Thado Chin",
	6583558,
	"tbq-kuk",
}

m["tda"] = {
	"tiếng Tagdal",
	36570,
	"son",
	"Latn, Tfng",
	"Tiếng Tagdal",
	"Tagdal",
	translit = {Tfng = "Tfng-translit"},
}

m["tdb"] = {
	"tiếng Panchpargania",
	21946879,
	"inc-eas",
	"Deva, as-Beng, Orya, Chis",
	"Tiếng Panchpargania",
	"Panchpargania",
	ancestors = "bh",
}

m["tdc"] = {
	"tiếng Emberá-Tadó",
	3052041,
	"sai-chc",
	"Latn",
	"Tiếng Emberá-Tadó",
	"Emberá-Tadó",
}

m["tdd"] = {
	 "tiếng Thái Na",
	36556,
	"tai-swe",
	"Tale",
	"Tiếng Thái Na",
	"Thái Na",
	translit = "Tale-translit",
	entry_name = {remove_diacritics = c.ZWNJ .. c.ZWJ},
}

m["tde"] = {
	"Tiranige Diga Dogon",
	5313387,
	"nic-dgw",
}

m["tdf"] = {
	"Talieng",
	37525108,
	"mkh-ban",
}

m["tdg"] = {
	"tiếng Tamang Tây",
	12953178,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	display_text = {["sit-tam-Tibt"] = s["Tibt-displaytext"]},
	entry_name = {["sit-tam-Tibt"] = s["Tibt-entryname"]},
	"Tiếng Tamang Tây",
	"Tamang Tây",
}

m["tdh"] = {
	"Thulung",
	56553,
	"sit-kiw",
}

m["tdi"] = {
	"Tomadino",
	7818197,
	"poz-btk",
	"Latn",
}

m["tdj"] = {
	"Tajio",
	7676870,
	"poz",
}

m["tdk"] = {
	"Tambas",
	3440392,
	"cdc-wst",
}

m["tdl"] = {
	"Sur",
	3914453,
	"nic-tar",
}

m["tdm"] = {
	"Taruma",
	nil,
}

m["tdn"] = {
	"Tondano",
	3531514,
	"phi",
}

m["tdo"] = {
	"Teme",
	3913994,
	"alv-mye",
}

m["tdq"] = {
	"Tita",
	3914899,
	"nic-bco",
}

m["tdr"] = {
	"tiếng Tơ Đrá",
	7812881,
	"mkh-nbn",
	"Latn",
	"Tiếng Tơ Đrá",
	"Tơ Đrá"
}

m["tds"] = {
	"Doutai",
	5302331,
	"paa-lkp",
}

m["tdt"] = {
	"Tetun Dili",
	12643484,
	"crp",
	"Latn",
	ancestors = "tet",
}

m["tdu"] = {
	"Tempasuk Dusun",
	3529155,
	"poz-san",
}

m["tdv"] = {
	"Toro",
	3438367,
	"nic-alu",
}

m["tdy"] = {
	"tiếng Tadyawan",
	7674700,
	"phi",
	"Latn",
	"Tiếng Tadyawan",
	"Tadyawan"
}

m["tea"] = {
	"tiếng Temiar",
	3914693,
	"mkh-asl",
	"Latn",
	"Tiếng Temiar",
	"Temiar",
}

m["teb"] = {
	"Tetete",
	7706087,
	"sai-tuc",
	"Latn",
}

m["tec"] = {
	"Terik",
	3518379,
	"sdv-nma",
}

m["ted"] = {
	"Tepo Krumen",
	11152243,
	"kro-grb",
}

m["tee"] = {
	"Huehuetla Tepehua",
	56455,
	"nai-ttn",
}

m["tef"] = {
	"tiếng Teressa",
	3518362,
	"aav-nic",
	"Deva, Latn",
	"Tiếng Teressa",
	"Teressa",
}

m["teg"] = {
	"Teke-Tege",
	36478,
	"bnt-tek",
}

m["teh"] = {
	"Tehuelche",
	33930,
	"sai-cho",
	"Latn",
}

m["tei"] = {
	"Torricelli",
	3450788,
	"qfa-tor",
}

m["tek"] = {
	"Ibali Teke",
	2802914,
	"bnt-tek",
}

m["tem"] = {
	"tiếng Temne",
	36613,
	"alv-mel",
	"Latn",
	"Tiếng Temne",
	"Temne",
}

m["ten"] = {
	"Tama (Colombia)",
	3832969,
	"sai-tuc",
	"Latn",
}

m["teo"] = {
	"Ateso",
	29474,
	"sdv-ttu",
	"Latn",
}

m["tep"] = {
	"Tepecano",
	3915525,
	"azc",
	"Latn",
}

m["teq"] = {
	"Temein",
	7698064,
	"sdv",
}

m["ter"] = {
	"Tereno",
	3314742,
	"awd",
	"Latn",
}

m["tes"] = {
	"tiếng Tengger",
	12473479,
	"poz",
	"Latn",
	"Tiếng Tengger",
	"Tengger",
}

m["tet"] = {
	"tiếng Tetum",
	34125,
	"poz-tim",
	"Latn",
	"Tiếng Tetum",
	"Tetum",
}

m["teu"] = {
	"Soo",
	3437607,
	"ssa-klk",
}

m["tev"] = {
	"Teor",
	12953198,
	"poz-cma",
}

m["tew"] = {
	"Tewa",
	56492,
	"nai-kta",
	"Latn",
}

m["tex"] = {
	"Tennet",
	56346,
	"sdv",
}

m["tey"] = {
	"Tulishi",
	12911106,
	"qfa-kad",
	"Latn",
}

m["tez"] = {
	"tiếng Tetserret",
	7706841,
	"ber",
	"Latn, Tfng",
	"Tiếng Tetserret",
	"Tetserret",
	translit = {Tfng = "Tfng-translit"},
}

m["tfi"] = {
	"Tofin Gbe",
	3530330,
	"alv-pph",
}

m["tfn"] = {
	"tiếng Dena'ina",
	27785,
	"ath-nor",
	"Latn",
}

m["tfo"] = {
	"Tefaro",
	7694618,
	"paa-egb",
	"Latn",
}

m["tfr"] = {
	"tiếng Teribe",
	36533,
	"cba",
	"Latn",
	"Tiếng Teribe",
	"Teribe",
}

m["tft"] = {
	"tiếng Ternate",
	3518492,
	"paa-nha",
	"Latn, Arab",
	"Tiếng Ternate",
	"Ternate",
}

m["tga"] = {
	"Sagalla",
	12953082,
	"bnt-cht",
}

m["tgb"] = {
	"Tobilung",
	12953913,
	"poz-san",
}

m["tgc"] = {
	"Tigak",
	3528276,
	"poz-ocw",
}

m["tgd"] = {
	"Ciwogai",
	3438799,
	"cdc-wst",
}

m["tge"] = {
	"tiếng Tamang Gorkha Đông",
	12953175,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	display_text = {["sit-tam-Tibt"] = s["Tibt-displaytext"]},
	entry_name = {["sit-tam-Tibt"] = s["Tibt-entryname"]},
	"Tiếng Tamang Gorkha Đông",
	"Tamang Gorkha Đông",
}

m["tgf"] = {
	"Chali",
	3695197,
	"sit-ebo",
	"Tibt, Latn",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["tgh"] = {
	"Tobagonian Creole English",
	7811541,
	"crp",
	ancestors = "en",
}

m["tgi"] = {
	"Lawunuia",
	3219937,
	"poz-ocw",
}

m["tgn"] = {
	"Tandaganon",
	nil,
	"phi",
}

m["tgo"] = {
	"Sudest",
	7675351,
	"poz-ocw",
}

m["tgp"] = {
	"tiếng Tangoa",
	2410276,
	"poz-vnc",
	"Latn",
	"Tiếng Tangoa",
	"Tangoa",
}

m["tgq"] = {
	"Tring",
	7842360,
	"poz-swa",
}

m["tgr"] = {
	"Tareng",
	25559541,
	"mkh",
}

m["tgs"] = {
	"Nume",
	3346290,
	"poz-vnc",
}

m["tgt"] = {
	"Central Tagbanwa",
	3915515,
	"phi",
	"Tagb",
}

m["tgu"] = {
	"Tanggu",
	7682930,
	"paa",
	"Latn",
}

m["tgv"] = {
	"Tingui-Boto",
	7808195,
	"sai-mje",
	"Latn",
}

m["tgw"] = {
	"Tagwana Senoufo",
	36514,
	"alv-tdj",
}

m["tgx"] = {
	"Tagish",
	28064,
	"ath-nor",
	"Latn",
}

m["tgy"] = {
	"Togoyo",
	36825,
	"nic-ser",
}

m["thc"] = {
	"Tai Hang Tong",
	7675753,
	"tai-nor",
}

m["thd"] = {
	"Kuuk Thaayorre",
	6448718,
	"aus-pmn",
	"Latn",
}

m["the"] = {
	"Chitwania Tharu",
	22083804,
	"inc-eas",
}

m["thf"] = {
	"Thangmi",
	7710314,
	"sit-new",
}

m["thh"] = {
	"Northern Tarahumara",
	15616395,
	"azc-trc",
	"Latn",
}

m["thi"] = {
	"Tai Long",
	25559562,
	"tai-swe",
}

m["thk"] = {
	"Tharaka",
	15407179,
	"bnt-kka",
}

m["thl"] = {
	"Dangaura Tharu",
	22083815,
	"inc-eas",
}

m["thm"] = {
	"tiếng Thavưng",
	34780,
	"mkh-vie",
	"Thai", --Laoo is feasible but no evidence yet.
	"Tiếng Thavưng",
	"Thavưng",
	sort_key = "Thai-sortkey",
}

m["thn"] = {
	"tiếng Thachanad",
	7708880,
	"dra-mal",
	"Mlym",
	"Tiếng Thachanad",
	"Thachanad",
	translit ="ml-translit",
}

m["thp"] = {
	"tiếng Thompson",
	1755054,
	"sal",
	"Latn",
	"Tiếng Thompson",
	"Thompson",
}

m["thq"] = {
	"Kochila Tharu",
	22083826,
	"inc-eas",
}

m["thr"] = {
	"Rana Tharu",
	12953920,
	"inc-eas",
}

m["ths"] = {
	"Thakali",
	7709348,
	"sit-tam",
}

m["tht"] = {
	"tiếng Tahltan",
	30125,
	"ath-nor",
	"Latn",
	"Tiếng Tahltan",
	"Tahltan",
}

m["thu"] = {
	"Thuri",
	7799291,
	"sdv-lon",
}

m["thy"] = {
	"Tha",
	3915849,
	"alv-bwj",
}

m["tic"] = {
	"Tira",
	36677,
	"alv-hei",
}

m["tif"] = {
	"Tifal",
	11732691,
	"ngf-okk",
}

m["tig"] = {
	"tiếng Tigre",
	34129,
	"sem-eth",
	"Ethi, Arab",
	"Tiếng Tigre",
	"Tigre",
	translit = {Ethi = "Ethi-translit"},
}

m["tih"] = {
	"Timugon Murut",
	7807680,
	"poz-san",
}

m["tii"] = {
	"Tiene",
	36469,
	"bnt-tek",
}

m["tij"] = {
	"Tilung",
	7803037,
	"sit-kiw",
}

m["tik"] = {
	"Tikar",
	36483,
	"nic-bdn",
	"Latn",
}

m["til"] = {
	"Tillamook",
	2109432,
	"sal",
}

m["tim"] = {
	"Timbe",
	7804599,
	"ngf",
}

m["tin"] = {
	"tiếng Tindi",
	36860,
	"cau-and",
	"Cyrl",
	"Tiếng Tindi",
	"Tindi",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["tio"] = {
	"Teop",
	3518239,
	"poz-ocw",
}

m["tip"] = {
	"Trimuris",
	7842270,
	"paa-tkw",
}

m["tiq"] = {
	"Tiéfo",
	3914874,
	"alv-sav",
}

m["tis"] = {
	"Masadiit Itneg",
	18748769,
	"phi",
}

m["tit"] = {
	"Tinigua",
	3029805,
}

m["tiu"] = {
	"Adasen",
	11214797,
	"phi",
}

m["tiv"] = {
	"Tiv",
	34131,
	"nic-tvc",
	"Latn",
}

m["tiw"] = {
	"tiếng Tiwi",
	1656014,
	"qfa-iso",
	"Latn",
	"Tiếng Tiwi",
	"Tiwi",
}

m["tix"] = {
	"Southern Tiwa",
	7570552,
	"nai-kta",
	"Latn",
}

m["tiy"] = {
	"tiếng Tiruray",
	7809425,
	"phi",
	"Latn",
	"Tiếng Tiruray",
	"Tiruray",
}

m["tiz"] = {
	"Tai Hongjin",
	3915716,
	"tai-swe",
}

m["tja"] = {
	"Tajuasohn",
	3915326,
	"kro-wkr",
}

m["tjg"] = {
	"Tunjung",
	3542117,
	"poz",
}

m["tji"] = {
	"tiếng Thổ Gia Bắc",
	12953229,
	"sit-tja",
	"Latn",
	"Tiếng Thổ Gia Bắc",
	"Thổ Gia Bắc",
}

m["tjl"] = {
	"tiếng Thái Lai",
	7675773,
	"tai-swe",
	"Mymr",
	"Tiếng Thái Lai",
	"Thái Lai",
}

m["tjm"] = {
	"Timucua",
	638300,
	"qfa-iso",
}

m["tjn"] = {
	"Tonjon",
	3913372,
	"dmn-jje",
}

m["tjs"] = {
	"tiếng Thổ Gia Nam",
	12633994,
	"sit-tja",
	"Latn",
	"Tiếng Thổ Gia Nam",
	"Thổ Gia Nam",
}

m["tju"] = {
	"Tjurruru",
	3913834,
	"aus-nga",
	"Latn",
}

m["tjw"] = {
	"Chaap Wuurong",
	5285187,
	"aus-pam",
	"Latn",
}

m["tka"] = {
	"Truká",
	7847648,
}

m["tkb"] = {
	"Buksa",
	20983638,
	"inc-eas",
}

m["tkd"] = {
	"Tukudede",
	36863,
	"poz-tim",
	"Latn",
}

m["tke"] = {
	"Takwane",
	11030092,
	"bnt-mak",
	ancestors = "vmw",
}

m["tkf"] = {
	"Tukumanféd",
	42330115,
	"tup-gua",
	"Latn",
}

m["tkl"] = {
	"tiếng Tokelau",
	34097,
	"poz-pnp",
	"Latn",
	"Tiếng Tokelau",
	"Tokelau",
}

m["tkm"] = {
	"Takelma",
	56710,
}

m["tkn"] = {
	"tiếng Tokunoshima",
	3530484,
	"jpx-nry",
	"Jpan",
	"Tiếng Tokunoshima",
	"Tokunoshima",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["tkp"] = {
	"Tikopia",
	36682,
	"poz-pnp",
	"Latn",
}

m["tkq"] = {
	"Tee",
	3075144,
	"nic-ogo",
	"Latn",
}

m["tkr"] = {
	"tiếng Tsakhur",
	36853,
	"cau-wsm",
	"Cyrl, Latn, Arab",
	"Tiếng Tsakhur",
	"Tsakhur",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
}

m["tks"] = {
	"Ramandi",
	25261947,
	"xme-ttc",
	ancestors = "xme-ttc-sou",
}

m["tkt"] = {
	"Kathoriya Tharu",
	22083822,
	"inc-eas",
}

m["tku"] = {
	"Upper Necaxa Totonac",
	56343,
	"nai-ttn",
	"Latn",
}

m["tkv"] = {
	"Mur Pano",
	nil,
	"poz-ocw",
	"Latn",
}

m["tkw"] = {
	"Teanu",
	3516731,
	"poz-oce",
	"Latn",
}

m["tkx"] = {
	"Tangko",
	7682993,
	"ngf-okk",
}

m["tkz"] = {
	"Takua",
	7678544,
	"mkh",
}

m["tla"] = {
	"Southwestern Tepehuan",
	3518245,
	"azc",
	"Latn",
}

m["tlb"] = {
	"Tobelo",
	1142333,
	"paa-nha",
}

m["tlc"] = {
	"Misantla Totonac",
	56460,
	"nai-ttn",
	"Latn",
}

m["tld"] = {
	"Talaud",
	7678964,
	"phi",
}

m["tlf"] = {
	"Telefol",
	7696150,
	"ngf-okk",
}

m["tlg"] = {
	"Tofanma",
	4461493,
	"paa-pau",
}

m["tlh"] = {
	"tiếng Klingon",
	10134,
	"art",
	"Latn",
	"Tiếng Klingon",
	"Klingon",
	type = "appendix-constructed",
}

m["tli"] = {
	"tiếng Tlingit",
	27792,
	"xnd",
	"Latn, Cyrl",
	"Tiếng Tlingit",
	"Tlingit",
}

m["tlj"] = {
	"Talinga-Bwisi",
	7679530,
	"bnt-haj",
}

m["tlk"] = {
	"Taloki",
	3514563,
	"poz-btk",
}

m["tll"] = {
	"Tetela",
	2613465,
	"bnt-tet",
}

m["tlm"] = {
	"Tolomako",
	3130514,
	"poz-vnc",
}

m["tln"] = {
	"Talondo'",
	7680293,
	"poz-ssw",
}

m["tlo"] = {
	"Talodi",
	36525,
	"alv-tal",
}

m["tlp"] = {
	"Filomena Mata-Coahuitlán Totonac",
	5449202,
	"nai-ttn",
	"Latn",
}

m["tlq"] = {
	"tiếng Tai Loi",
	7675784,
	"mkh-pal",
	nil,
	"Tiếng Tai Loi",
	"Tai Loi"
}

m["tlr"] = {
	"Talise",
	3514510,
	"poz-sls",
}

m["tls"] = {
	"Tambotalo",
	7681065,
	"poz-vnc",
}

m["tlt"] = {
	"Teluti",
	12953194,
	"poz-cma",
}

m["tlu"] = {
	"Tulehu",
	7852006,
	"poz-cma",
}

m["tlv"] = {
	"Taliabu",
	3514498,
	"poz-cma",
	"Latn",
}

m["tlx"] = {
	"Khehek",
	3196124,
	"poz-aay",
}

m["tly"] = {
	"tiếng Talysh",
	34318,
	"xme-ttc",
	"Latn, Cyrl, fa-Arab",
	"Tiếng Talysh",
	"Talysh",
}

m["tma"] = {
	"Tama (Chad)",
	57001,
	"sdv-tmn",
}

m["tmb"] = {
	"Avava",
	2157461,
	"poz-vnc",
}

m["tmc"] = {
	"Tumak",
	3121045,
	"cdc-est",
}

m["tmd"] = {
	"Haruai",
	12632146,
	"ngf-mad",
}

m["tme"] = {
	"Tremembé",
	5246937,
}

m["tmf"] = {
	"Toba-Maskoy",
	3033544,
	"sai-mas",
	"Latn",
}

m["tmg"] = {
	"Ternateño",
	7232597,
}

m["tmh"] = {
	"tiếng Tuareg",
	34065,
	"ber",
	"Latn, Tfng, Arab",
	"Tiếng Tuareg",
	"Tuareg",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ},
}

m["tmi"] = {
	"Tutuba",
	7857052,
	"poz-vnc",
}

m["tmj"] = {
	"Samarokena",
	7408865,
	"paa-tkw",
}

m["tmk"] = {
	"Northwestern Tamang",
	15616509,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	display_text = {["sit-tam-Tibt"] = s["Tibt-displaytext"]},
	entry_name = {["sit-tam-Tibt"] = s["Tibt-entryname"]},
}

m["tml"] = {
	"Tamnim Citak",
	12643315,
	"ngf",
}

m["tmm"] = {
	"Tai Thanh",
	7675842,
	"tai-swe",
}

m["tmn"] = {
	"Taman (Indonesia)",
	7680671,
	"poz",
	"Latn",
}

m["tmo"] = {
	"tiếng Temoq",
	7698205,
	"mkh-asl",
	"Latn",
	"Tiếng Temoq",
	"Temoq"
}

m["tmq"] = {
	"Tumleo",
	7852641,
	"poz-ocw",
}

m["tms"] = {
	"Tima",
	36684,
	"nic-ktl",
}

m["tmt"] = {
	"Tasmate",
	7687571,
	"poz-vnc",
}

m["tmu"] = {
	"Iau",
	56867,
	"paa-lkp",
}

m["tmv"] = {
	"Motembo",
	11013108,
	"bnt-bun",
}

m["tmy"] = {
	"Tami",
	3514812,
	"poz-oce",
}

m["tmz"] = {
	"Tamanaku",
	3441435,
	"sai-ven",
	"Latn",
}

m["tna"] = {
	"Tacana",
	3182551,
	"sai-tac",
	"Latn",
}

m["tnb"] = {
	"Western Tunebo",
	3181238,
	"cba",
}

m["tnc"] = {
	"Tanimuca-Retuarã",
	36535,
	"sai-tuc",
	"Latn",
}

m["tnd"] = {
	"Angosturas Tunebo",
	25559604,
	"cba",
}

m["tne"] = {
	"Tinoc Kallahan",
	3192219,
}

m["tng"] = {
	"Tobanga",
	3440501,
	"cdc-est",
}

m["tnh"] = {
	"Maiani",
	6735243,
	"ngf-mad",
	"Latn",
}

m["tni"] = {
	"Tandia",
	7682454,
	"poz-hce",
	"Latn",
}

m["tnk"] = {
	"Kwamera",
	3200806,
	"poz-oce",
}

m["tnl"] = {
	"Lenakel",
	3229429,
	"poz-oce",
}

m["tnm"] = {
	"Tabla",
	7673105,
	"paa-sen",
}

m["tnn"] = {
	"North Tanna",
	957945,
	"poz-oce",
}

m["tno"] = {
	"Toromono",
	510544,
	"sai-tac",
	"Latn",
}

m["tnp"] = {
	"Whitesands",
	3063761,
	"poz-oce",
}

m["tnq"] = {
	"tiếng Taíno",
	5232952,
	"awd-taa",
	"Latn",
	"Tiếng Taíno",
	"Taíno",
}

m["tnr"] = {
	"Bedik",
	35096,
	"alv-ten",
}

m["tns"] = {
	"Tenis",
	7699870,
	"poz-ocw",
}

m["tnt"] = {
	"Tontemboan",
	3531666,
	"phi",
	"Latn",
}

m["tnu"] = {
	"Tay Khang",
	6362363,
	"tai",
}

m["tnv"] = {
	"tiếng Tanchangya",
	7682361,
	"inc-eas",
	"Cakm, Beng",
	"Tiếng Tanchangya",
	"Tanchangya",
	ancestors = "inc-obn",
}

m["tnw"] = {
	"Tonsawang",
	3531660,
	"phi",
}

m["tnx"] = {
	"Tanema",
	2106984,
	"poz-oce",
}

m["tny"] = {
	"Tongwe",
	7821200,
	"bnt",
}

m["tnz"] = {
	"tiếng Ten'edn",
	3073453,
	"mkh-asl",
	"Latn",
	"Tiếng Ten'edn",
	"Ten'edn",
}

m["tob"] = {
	"Toba",
	3113756,
	"sai-guc",
	"Latn",
}

m["toc"] = {
	"Coyutla Totonac",
	15615591,
	"nai-ttn",
	"Latn",
}

m["tod"] = {
	"tiếng Toma",
	11055484,
	"dmn-msw",
	"Latn, Loma",
	"Tiếng Toma",
	"Toma",
}

m["tof"] = {
	"Gizrra",
	5565941,
}

m["tog"] = {
	"Tonga (Malawi)",
	3847648,
	"bnt-nys",
	"Latn",
}

m["toh"] = {
	"Tonga (Mozambique)",
	7820988,
	"bnt-bso",
}

m["toi"] = {
	"Tonga (Zambia)",
	34101,
	"bnt-bot",
}

m["toj"] = {
	"Tojolabal",
	36762,
	"myn",
}

m["tok"] = {
	"tiếng Toki Pona",
	36846,
	"art",
	"Latn",
	"Tiếng Toki Pona",
	"Toki Pona",
	type = "appendix-constructed",
}

m["tol"] = {
	"Tolowa",
	20827,
	"ath-pco",
	"Latn",
}

m["tom"] = {
	"Tombulu",
	3531199,
	"phi",
}

m["too"] = {
	"Xicotepec de Juárez Totonac",
	8044353,
	"nai-ttn",
	"Latn",
}

m["top"] = {
	"tiếng Totonac Papantla",
	56329,
	"nai-ttn",
	"Latn",
	"Tiếng Totonac Papantla",
	"Totonac Papantla",
}

m["toq"] = {
	"Toposa",
	3033588,
	"sdv-ttu",
}

m["tor"] = {
	"Togbo-Vara Banda",
	11002922,
	"bad-cnt",
}

m["tos"] = {
	"tiếng Totonac cao nguyên",
	13154149,
	"nai-ttn",
	"Latn",
	"Tiếng Totonac cao nguyên",
	"Totonac cao nguyên",
}

m["tou"] = {
	"tiếng Thổ",
	22694631,
	"mkh-vie",
	nil,
	"Tiếng Thổ",
	"Thổ",
}

m["tov"] = {
	"Upper Taromi",
	12953183,
	"xme-ttc",
	ancestors = "xme-ttc-cen",
}

m["tow"] = {
	"tiếng Jemez",
	3912876,
	"nai-kta",
	"Latn",
	"Tiếng Jemez",
	"Jemez",
}

m["tox"] = {
	"tiếng Tobi",
	34022,
	"poz-mic",
	nil,
	"Tiếng Tobi",
	"Tobi",
}

m["toy"] = {
	"Topoiyo",
	7824977,
	"poz-kal",
}

m["toz"] = {
	"To",
	7811216,
	"alv-mbm",
}

m["tpa"] = {
	"Taupota",
	7688832,
	"poz-ocw",
}

m["tpc"] = {
	"tiếng Me'phaa Azoyú",
	25559730,
	"omq",
	"Latn",
}

m["tpe"] = {
	"tiếng Tippera",
	16115423,
	"tbq-bdg",
	"Latn, Beng",
	"Tiếng Tippera",
	"Tippera",
}

m["tpf"] = {
	"Tarpia",
	12953185,
	"poz-ocw",
}

m["tpg"] = {
	"Kula",
	6442714,
	"qfa-tap",
}

m["tpi"] = {
	"tiếng Tok Pisin",
	34159,
	"crp",
	"Latn",
	"Tiếng Tok Pisin",
	"Tok Pisin",
	ancestors = "en",
}

m["tpj"] = {
	"Tapieté",
	3121063,
}

m["tpk"] = {
	"Tupinikin",
	33924,
	"tup-gua",
}

m["tpl"] = {
	"tiếng Me'phaa Tlacoapa",
	16115511,
	"omq",
}

m["tpm"] = {
	"Tampulma",
	36590,
	"nic-gnw",
}

m["tpn"] = {
	"tiếng Tupi",
	31528147,
	"tup-gua",
	"Latn",
	"Tiếng Tupi",
	"Tupi",
}

m["tpo"] = {
	"tiếng Thái Hàng Tổng",
	7675795,
	"tai-nor",
	"Latn",
	"Tiếng Thái Hàng Tổng",
	"Thái Hàng Tổng"
}

m["tpp"] = {
	"Pisaflores Tepehua",
	56349,
	"nai-ttn",
}

m["tpq"] = {
	"Tukpa",
	12953230,
	"sit-las",
}

m["tpr"] = {
	"Tuparí",
	3542217,
	"tup",
	"Latn",
}

m["tpt"] = {
	"tiếng Tepehua Tlachichilco",
	56330,
	"nai-ttn",
	nil,
	"Tiếng Tepehua Tlachichilco",
	"Tepehua Tlachichilco",
}

m["tpu"] = {
	"tiếng Tampuan",
	3514882,
	"mkh-ban",
	"Khmr",
	"Tiếng Tampuan",
	"Tampuan",
}

m["tpv"] = {
	"Tanapag",
	3397371,
	"poz-mic",
}

m["tpw"] = {
	"tiếng Tupi cổ",
	56944,
	"tup-gua",
	"Latn",
	"Tiếng Tupi cổ",
	"Tupi cổ",
}

m["tpx"] = {
	"tiếng Me'phaa Acatepec",
	31157882,
	"omq",
	"Latn",
}

m["tpy"] = {
	"Trumai",
	12294279,
	"qfa-iso",
}

m["tpz"] = {
	"Tinputz",
	3529205,
	"poz-ocw",
}

m["tqb"] = {
	"Tembé",
	10322157,
	"tup-gua",
	"Latn",
}

m["tql"] = {
	"Lehali",
	3229119,
	"poz-oce",
}

m["tqm"] = {
	"Turumsa",
	7856508,
	"paa",
}

m["tqn"] = {
	"Tenino",
	15699255,
	"nai-shp",
	"Latn",
	ancestors = "nai-spt",
}

m["tqo"] = {
	"Toaripi",
	7811403,
	"ngf",
}

m["tqp"] = {
	"Tomoip",
	3531388,
	"poz-ocw",
}

m["tqq"] = {
	"tiếng Tunni",
	3514343,
	"cus-som",
	nil,
	"Tiếng Tunni",
	"Tunni",
}

m["tqr"] = {
	"Torona",
	36679,
	"alv-tal",
}

m["tqt"] = {
	"Western Totonac",
	7116691,
	"nai-ttn",
	"Latn",
}

m["tqu"] = {
	"Touo",
	56750,
}

m["tqw"] = {
	"tiếng Tonkawa",
	2454881,
	"qfa-iso",
	"Latn",
	"Tiếng Tonkawa",
	"Tonkawa",
}

m["tra"] = {
	"Tirahi",
	3812406,
	"inc-koh",
}

m["trb"] = {
	"Terebu",
	7701797,
	"poz-ocw",
}

m["trc"] = {
	"tiếng Triqui Copala",
	12953935,
	"omq-tri",
	"Latn",
}

m["trd"] = {
	"Turi",
	7854914,
	"mun",
}

m["tre"] = {
	"East Tarangan",
	18609750,
	"poz",
}

m["trf"] = {
	"Trinidadian Creole English",
	7842493,
	"crp",
	ancestors = "en",
}

m["trg"] = {
	"Lishán Didán",
	56473,
	"sem-nna",
}

m["trh"] = {
	"Turaka",
	12953237,
	"ngf",
}

m["tri"] = {
	"tiếng Trió",
	56885,
	"sai-tar",
	"Latn",
	"Tiếng Trió",
	"Trió",
}

m["trj"] = {
	"Toram",
	3441225,
	"cdc-est",
}

m["trl"] = {
	"Traveller Scottish",
	3915671,
	"crp",
	"Latn",
	ancestors = "sco, rom",
}

m["trm"] = {
	"Tregami",
	34081,
	"nur-sou",
}

m["trn"] = {
	"Trinitario",
	3539279,
	"awd",
}

m["tro"] = {
	"Tarao",
	3515603,
	"tbq-kuk",
	"Latn",
}

m["trp"] = {
	"tiếng Kok Borok",
	35947,
	"tbq-bdg",
	"Beng, Latn",
	"Tiếng Kok Borok",
	"Kok Borok",
}

m["trq"] = {
	"tiếng Triqui San Martín Itunyoso",
	12953934,
	"omq-tri",
	"Latn",
	"Tiếng Triqui San Martín Itunyoso",
	"Triqui San Martín Itunyoso",
}

m["trr"] = {
	"Taushiro",
	1957508,
}

m["trs"] = {
	"tiếng Triqui Chicahuaxtla",
	3539587,
	"omq-tri",
	"Latn",
	"Tiếng Triqui Chicahuaxtla",
	"Triqui Chicahuaxtla",
}

m["trt"] = {
	"Tunggare",
	615071,
	"paa-egb",
	"Latn",
}

m["tru"] = {
	"tiếng Turoyo",
	34040,
	"sem-cna",
	"Syrc, Latn",
	"Tiếng Turoyo",
	"Turoyo",
	entry_name = "Syrc-entryname",
	translit = "tru-translit",
}

m["trv"] = {
	"tiếng Truku",
	716686,
	"map-ata",
	"Latn",
	"Tiếng Truku",
	"Truku",
}

m["trw"] = {
	"tiếng Torwali",
	2665246,
	"inc-koh",
	"ur-Arab",
	"Tiếng Torwali",
	"Torwali",
}

m["trx"] = {
	"Tringgus",
	7842365,
	"day",
}

m["try"] = {
	"Turung",
	7856514,
	"tai-swe",
	"as-Beng",
}

m["trz"] = {
	"Torá",
	7827518,
	"sai-cpc",
}

m["tsa"] = {
	"Tsaangi",
	36675,
	"bnt-nze",
}

m["tsb"] = {
	"tiếng Tsamai",
	2371358,
	"cus-eas",
	"Latn",
	"Tiếng Tsamai",
	"Tsamai",
}

m["tsc"] = {
	"Tswa",
	2085051,
	"bnt-tsr",
}

m["tsd"] = {
	"tiếng Tsakonia",
	220607,
	"grk",
	"Grek",
	"Tiếng Tsakonia",
	"Tsakonia",
	ancestors = "grc-dor",
	translit = "el-translit",
	entry_name = {remove_diacritics = c.caron .. c.diaerbelow .. c.brevebelow},
	sort_key = s["Grek-sortkey"],
}


m["tse"] = {
	"Tunisian Sign Language",
	7853191,
	"sgn",
}

m["tsf"] = {
	"Southwestern Tamang",
	12953176,
	"sit-tam",
}

m["tsg"] = {
	"tiếng Tausug",
	34142,
	"phi",
	"Latn, Arab",
	"Tiếng Tausug",
	"Tausug",
}

m["tsh"] = {
	"Tsuvan",
	3502326,
	"cdc-cbm",
}

m["tsi"] = {
	"tiếng Tsimshian",
	20085721,
	"nai-tsi",
	"Latn",
	"Tiếng Tsimshian",
	"Tsimshian",
}

m["tsj"] = {
	"tiếng Tshangla",
	36840,
	"sit-tsk",
	"Tibt, Latn, Deva",
	"Tiếng Tshangla",
	"Tshangla",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["tsl"] = {
	"Ts'ün-Lao",
	3446675,
	"tai",
}

m["tsm"] = {
	"Turkish Sign Language",
	36885,
	"sgn",
}

m["tsp"] = {
	"Northern Toussian",
	11155635,
	"alv-sav",
}

m["tsq"] = {
	"Thai Sign Language",
	7709156,
	"sgn",
	"Sgnw",
}

m["tsr"] = {
	"Akei",
	2828964,
	"poz-vnc",
}

m["tss"] = {
	"Taiwan Sign Language",
	34019,
	"sgn-jsl",
}

m["tsu"] = {
	"tiếng Tsou",
	716681,
	"map-tsu",
	"Latn",
	"Tiếng Tsou",
	"Tsou",
}

m["tsv"] = {
	"Tsogo",
	36674,
	"bnt-tso",
}

m["tsw"] = {
	"Tsishingini",
	13123571,
	"nic-kam",
}

m["tsx"] = {
	"Mubami",
	6930815,
	"ngf",
}

m["tsy"] = {
	"Tebul Sign Language",
	7692090,
	"sgn",
}

m["tta"] = {
	"Tutelo",
	2311602,
	"sio-ohv",
}

m["ttb"] = {
	"Gaa",
	3438361,
	"nic-dak",
}

m["ttc"] = {
	"Tektiteko",
	36686,
	"myn",
}

m["ttd"] = {
	"Tauade",
	7688634,
}

m["tte"] = {
	"Bwanabwana",
	5003667,
	"poz-ocw",
	"Latn",
}

m["ttf"] = {
	"Tuotomb",
	7853459,
	"nic-mbw",
	"Latn",
}

m["ttg"] = {
	"Tutong",
	3507990,
	"poz-swa",
	"Latn",
}

m["tth"] = {
	"tiếng Tà Ôi Thượng",
	3512660,
	"mkh-kat",
	"Latn",
	"Tiếng Tà Ôi Thượng",
	"Tà Ôi Thượng"
}

m["tti"] = {
	"Tobati",
	7811556,
	"poz-ocw",
	"Latn",
}

m["ttj"] = {
	"tiếng Tooro",
	7824218,
	"bnt-nyg",
	"Latn",
	"Tiếng Tooro",
	"Tooro",
}

m["ttk"] = {
	"Totoro",
	3532756,
	"sai-bar",
	"Latn",
}

m["ttl"] = {
	"Totela",
	10962316,
	"bnt-bot",
	"Latn",
}

m["ttm"] = {
	"Northern Tutchone",
	20822,
	"ath-nor",
	"Latn",
}

m["ttn"] = {
	"Towei",
	7829606,
	"paa-pau",
}

m["tto"] = {
	"Lower Ta'oih",
	25559539,
	"mkh-kat",
}

m["ttp"] = {
	"Tombelala",
	6799663,
	"poz-kal",
}

m["ttr"] = {
	"Tera",
	56267,
	"cdc-cbm",
}

m["tts"] = {
	"tiếng Isan",
	33417,
	"tai-swe",
	"Thai",
	"Tiếng Isan",
	"Isan",
	sort_key = "Thai-sortkey",
}

m["ttt"] = {
	"tiếng Tat",
	56489,
	"ira-swi",
	"Cyrl, Latn, Armn, fa-Arab",
	"Tiếng Tat",
	"Tat",
	ancestors = "fa",
}

m["ttu"] = {
	"Torau",
	3532208,
	"poz-ocw",
}

m["ttv"] = {
	"Titan",
	3445811,
	"poz-aay",
}

m["ttw"] = {
	"Long Wat",
	7856961,
	"poz-swa",
}

m["tty"] = {
	"Sikaritai",
	7513600,
	"paa-lkp",
}

m["ttz"] = {
	"Tsum",
	12953223,
	"sit-kyk",
}

m["tua"] = {
	"Wiarumus",
	7998045,
	"qfa-tor",
	"Latn",
}

m["tub"] = {
	"Tübatulabal",
	56704,
	"azc",
	"Latn",
}

m["tuc"] = {
	"Mutu",
	3331003,
	"poz-ocw",
	"Latn",
}

m["tud"] = {
	"Tuxá",
	7857217,
}

m["tue"] = {
	"Tuyuca",
	2520538,
	"sai-tuc",
	"Latn",
}

m["tuf"] = {
	"Central Tunebo",
	12953942,
	"cba",
}

m["tug"] = {
	"Tunia",
	863721,
	"alv-bua",
}

m["tuh"] = {
	"Taulil",
	3516141,
	"paa-bng",
}

m["tui"] = {
	"Tupuri",
	36646,
	"alv-mbm",
	"Latn",
}

m["tuj"] = {
	"Tugutil",
	12953228,
	"paa-nha"
}

m["tul"] = {
	"Tula",
	3914907,
	"alv-wjk",
}

m["tum"] = {
	"tiếng Tumbuka",
	34138,
	"bnt-nys",
	"Latn",
	"Tiếng Tumbuka",
	"Tumbuka",
}

m["tun"] = {
	"tiếng Tunica",
	56619,
	"qfa-iso",
	"Latn",
	"Tiếng Tunica",
	"Tunica",
}

m["tuo"] = {
	"Tucano",
	3541834,
	"sai-tuc",
	"Latn",
}

m["tuq"] = {
	"Tedaga",
	36639,
	"ssa-sah",
}

m["tus"] = {
	"Tuscarora",
	36944,
	"iro-nor",
	"Latn",
}

m["tuu"] = {
	"Tututni",
	20627,
	"ath-pco",
	"Latn",
}

m["tuv"] = {
	"Turkana",
	36958,
	"sdv-ttu",
	"Latn",
}

m["tux"] = {
	"Tuxináwa",
	7857204,
	"sai-pan",
	"Latn",
}

m["tuy"] = {
	"Tugen",
	3541935,
	"sdv-nma",
}

m["tuz"] = {
	"Turka",
	36643,
	"nic-gur",
	"Latn",
}

m["tva"] = {
	"Vaghua",
	3553248,
	"poz-ocw",
	"Latn",
}

m["tvd"] = {
	"Tsuvadi",
	3914936,
	"nic-kam",
}

m["tve"] = {
	"Te'un",
	7690709,
	"poz-cet",
	"Latn",
}

m["tvk"] = {
	"Southeast Ambrym",
	252411,
	"poz-vnc",
	"Latn",
}

m["tvl"] = {
	"tiếng Tuvalu",
	34055,
	"poz-pnp",
	"Latn",
	"Tiếng Tuvalu",
	"Tuvalu",
}

m["tvm"] = {
	"Tela-Masbuar",
	7695666,
	"poz-tim",
}

m["tvn"] = {
	"tiếng Tavoy",
	7689158,
	"tbq-brm",
	"Mymr",
	"Tiếng Tavoy",
	"Tavoy",
	ancestors = "obr",
}

m["tvo"] = {
	"Tidore",
	3528199,
	"paa-nha",
	"Latn, Arab",
}

m["tvs"] = {
	"Taveta",
	15632387,
	"bnt-par",
}

m["tvt"] = {
	"Tutsa Naga",
	7856987,
	"sit-tno",
}

m["tvu"] = {
	"Tunen",
	36632,
	"nic-mbw",
}

m["tvw"] = {
	"Sedoa",
	7445362,
	"poz-kal",
}

m["tvx"] = {
	"tiếng Taivoan",
	1975271,
	"map",
	"Latn",
	"Tiếng Taivoan",
	"Taivoan",
}

m["tvy"] = {
	"Timor Pidgin",
	4904029,
	"crp",
	ancestors = "pt",
}

m["twa"] = {
	"Twana",
	7857412,
	"sal",
}

m["twb"] = {
	"Western Tawbuid",
	12953912,
	"phi",
}

m["twc"] = {
	"Teshenawa",
	3436597,
	"phi",
}

m["twe"] = {
	"Teiwa",
	3519302,
	"ngf",
	"Latn",
}

m["twf"] = {
	"tiếng Taos",
	7684320,
	"nai-kta",
	"Latn",
	"Tiếng Taos",
	"Taos",
}

m["twg"] = {
	"Tereweng",
	12953200,
	"qfa-tap",
}

m["twh"] = {
	"tiếng Thái Trắng",
	7675751,
	"tai-swe",
	"Tavt",
	"Tiếng Thái Trắng",
	"Thái Trắng",
	--translit = "Tavt-translit",
	sort_key = {
		from = {"[꪿ꫀ꫁ꫂ]", "([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])"},
		to = {"", "%2%1"}
	},
}

m["twm"] = {
	"Tawang Monpa",
	36586,
	"sit-ebo",
	"Tibt",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["twn"] = {
	"Twendi",
	7857682,
	"nic-mmb",
}

m["two"] = {
	"Tswapong",
	3446241,
	"bnt-sts",
}

m["twp"] = {
	"Ere",
	3056045,
	"poz-aay",
	"Latn",
}

m["twq"] = {
	"tiếng Tasawaq",
	36564,
	"son",
	"Latn",
	"Tiếng Tasawaq",
	"Tasawaq",
}

m["twr"] = {
	"Southwestern Tarahumara",
	12953909,
	"azc-trc",
	"Latn",
}

m["twt"] = {
	"Turiwára",
	3542307,
	"tup-gua",
	"Latn",
}

m["twu"] = {
	"Termanu",
	7702572,
	"poz-tim",
}

m["tww"] = {
	"Tuwari",
	7857159,
	"paa-spk",
}

m["twy"] = {
	"Tawoyan",
	3513542,
	"poz-bre",
}

m["txa"] = {
	"Tombonuo",
	7818692,
	"poz-san",
}

m["txb"] = {
	"tiếng Tochari B",
	3199353,
	"ine-toc",
	"Latn",
	"Tiếng Tochari B",
	"Tochari B",
	wikipedia_article = "Tocharian languages", -- wikidata id has no associated article
	standardChars = "AaÄäĀāCcEeIiKkLlMmṂṃNnṄṅÑñOoPpRrSsŚśṢṣTtUuWwYy" .. c.punc,
}

m["txc"] = {
	"Tsetsaut",
	20829,
	"ath-nor",
	"Latn",
}

m["txe"] = {
	"Totoli",
	7828387,
	"poz-tot",
	"Latn",
}

m["txg"] = {
	"tiếng Tangut",
	2727930,
	"sit-qia",
	"Tang",
	"Tiếng Tangut",
	"Tangut",
	translit = "txg-translit",
}

m["txj"] = {
	"Tarjumo",
	nil,
	"ssa-sah",
	"Latn, Arab",
}

m["txh"] = {
	"tiếng Thracia",
	36793,
	"ine",
	"Latn, Grek",
	"Tiếng Thracia",
	"Thracia",
	translit = "el-translit",
}

m["txi"] = {
	"Ikpeng",
	9344891,
	"sai-pek",
	"Latn",
}

m["txm"] = {
	"Tomini",
	7818911,
	"poz",
}

m["txn"] = {
	"West Tarangan",
	3515594,
	"poz",
}

m["txo"] = {
	"tiếng Toto",
	36709,
	"sit-dhi",
	"Beng, Toto",
	"Tiếng Toto",
	"Toto",
}

m["txq"] = {
	"Tii",
	7801784,
	"poz-tim",
}

m["txr"] = {
	"Tartessian",
	36795,
}

m["txs"] = {
	"Tonsea",
	3531659,
	"phi",
}

m["txt"] = {
	"Citak",
	3447279,
	"ngf",
}

m["txu"] = {
	"tiếng Kayapó",
	3101212,
	"sai-nje",
	"Latn",
	"Tiếng Kayapó",
	"Kayapó",
}

m["txx"] = {
	"Tatana",
	18643518,
	"poz-san",
}

m["tya"] = {
	"Tauya",
	7688978,
	"ngf-mad",
}

m["tye"] = {
	"Kyenga",
	3913304,
	"dmn-bbu",
	"Latn",
}

m["tyh"] = {
	"tiếng Ơ Đu",
	3347428,
	"mkh-khm",
	nil,
	"Tiếng Ơ Đu",
	"Ơ Đu",
}

m["tyi"] = {
	"Teke-Tsaayi",
	33123613,
	"bnt-nze",
}

m["tyj"] = {
	"tiếng Tay Dọ",
	7675746,
	"tai-nor",
	"Thai, Latn, Tayo", -- Vietnamese alphabet
	"Tiếng Tay Dọ",
	"Tay Dọ",
}

m["tyl"] = {
	"Thu Lao",
	12953921,
	"tai-cen",
}

m["tyn"] = {
	"Kombai",
	6428241,
	"ngf",
}

m["typ"] = {
	"Kuku-Thaypan",
	3915693,
	"aus-pmn",
	"Latn",
}

m["tyr"] = {
	"tiếng Thái Đỏ",
	3915207,
	"tai-swe",
	"Tavt",
	"Tiếng Thái Đỏ",
	"Thái Đỏ",
}

m["tys"] = {
	"tiếng Tày Sa Pa",
	3446668,
	"tai-sap",
	"Latn",
	"Tiếng Tày Sa Pa",
	"Tày Sa Pa",
}

m["tyt"] = {
	"Tày Tac",
	7862029,
	"tai-swe",
}

m["tyu"] = {
	"Kua",
	3832933,
	"khi-kal",
}

m["tyv"] = {
	"tiếng Tuva",
	34119,
	"trk-ssb",
	"Cyrl",
	"Tiếng Tuva",
	"Tuva",
	translit = "tyv-translit",
	override_translit = true,
	sort_key = "tyv-sortkey",
}

m["tyx"] = {
	"Teke-Tyee",
	36634,
	"bnt-nze",
}

m["tyz"] = {
	"tiếng Tày", -- This does not mean its umbrella "Tai" languages.
	2511476,
	"tai-tay",
	"Latn, Hani",
	"Tiếng Tày",
	"Tày",
	sort_key = {Hani = "Hani-sortkey"},
}

m["tza"] = {
	"Tanzanian Sign Language",
	7684177,
	"sgn",
}

m["tzh"] = {
	"Tzeltal",
	36808,
	"myn",
	"Latn",
}

m["tzj"] = {
	"Tz'utujil",
	36941,
	"myn",
	"Latn",
}

m["tzl"] = {
	"tiếng Talossa",
	1063911,
	"art",
	"Latn",
	"Tiếng Talossa",
	"Talossa",
	type = "appendix-constructed",
	sort_key = "tzl-sortkey",
}

m["tzm"] = {
	"tiếng Tamazight Trung Atlas",
	49741,
	"ber",
	"Tfng, Arab, Latn",
	"Tiếng Tamazight Trung Atlas",
	"Tamazight Trung Atlas",
	translit = "Tfng-translit",
}

m["tzn"] = {
	"Tugun",
	12953225,
	"poz-tim",
}

m["tzo"] = {
	"tiếng Tzotzil",
	36809,
	"myn",
	"Latn",
	"Tiếng Tzotzil",
	"Tzotzil",
}

m["tzx"] = {
	"Tabriak",
	56872,
	"paa-lsp",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")