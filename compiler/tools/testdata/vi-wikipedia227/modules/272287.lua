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

m["gaa"] = {
	"tiếng Ga",
	33287,
	"alv-gda",
	"Latn",
	"Tiếng Ga",
	"Ga",
}

m["gab"] = {
	"tiếng Gabri",
	3441237,
	"cdc-est",
	"Latn",
	"Tiếng Gabri",
	"Gabri",
}

m["gac"] = {
	"Mixed Great Andamanese",
	nil,
	"qfa-adn",
	"Latn",
}

m["gad"] = { -- not to be confused with gdk, gdg
	"tiếng Gaddang",
	3438830,
	"phi",
	"Latn",
	"Tiếng Gaddang",
	"Gaddang",
}

m["gae"] = {
	"tiếng Warekena",
	1091095,
	"awd-nwk",
	"Latn",
	"Tiếng Warekena",
	"Warekena",
}

m["gaf"] = {
	"Gende",
	3100425,
	"paa-kag",
	"Latn",
}

m["gag"] = {
	"tiếng Gagauz",
	33457,
	"trk-ogz",
	"Latn, Cyrl",
	"Tiếng Gagauz",
	"Gagauz",
	ancestors = "trk-oat",
	dotted_dotless_i = true,
	sort_key = {
		Latn = {
			from = {
				"i", -- Ensure "i" comes after "ı".
				"ä", "ç", "ê", "ı", "ö", "ş", "ţ", "ü"
			},
			to = {
				"i" .. p[1],
				"a" .. p[1], "c" .. p[1], "e" .. p[1], "i", "o" .. p[1], "s" .. p[1], "t" .. p[1], "u" .. p[1]
			}
		},
	},
}

m["gah"] = {
	"tiếng Alekano",
	3441595,
	"paa-kag",
	"Latn",
	"Tiếng Alekano",
	"Alekano",
}

m["gai"] = {
	"Borei",
	6799756,
	"paa",
	"Latn",
}

m["gaj"] = {
	"Gadsup",
	5516467,
	"paa-kag",
	"Latn",
}

m["gak"] = {
	"Gamkonora",
	5520226,
	"paa-nha",
	"Latn",
}

m["gal"] = {
	"Galoli",
	35322,
	"poz-tim",
	"Latn",
}

m["gam"] = {
	"Kandawo",
	6361369,
	"ngf",
	"Latn",
}

m["gan"] = {
	"tiếng Cám",
	33475,
	"zhx",
	"Hants",
	"Tiếng Cám",
	"Cám",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["gao"] = {
	"Gants",
	5521529,
	"ngf-mad",
	"Latn",
}

m["gap"] = {
	"Gal",
	5517742,
	"ngf-mad",
	"Latn",
}

m["gaq"] = {
	"tiếng Gata'",
	3501920,
	"mun",
	"Orya",
	"Tiếng Gata'",
	"Gata'",
}

m["gar"] = {
	"Galeya",
	5518509,
	"poz-ocw",
	"Latn",
}

m["gas"] = {
	"tiếng Garasia Adiwasi",
	12953522,
	"inc-bhi",
	"Gujr",
	"Tiếng Garasia Adiwasi",
	"Garasia Adiwasi",
	ancestors = "bhb",
}

m["gat"] = {
	"Kenati",
	4219330,
	"paa-kag",
	"Latn",
}

m["gau"] = {
	"tiếng Kondekor",
	12952433,
	"dra-pgd",
	"Telu",
	"Tiếng Kondekor",
	"Kondekor",
	translit = { Telu = "te-translit" },
}

m["gaw"] = {
	"tiếng Nobonob",
	11732205,
	"paa",
	"Latn",
	"Tiếng Nobonob",
	"Nobonob",
}

m["gax"] = {
	"tiếng Oromo Nam",
	2910610,
	"cus-eas",
	"Latn",
	"Tiếng Oromo Nam",
	"Oromo Nam",
}

m["gay"] = {
	"Gayo",
	33286,
	"poz-nws",
	"Latn",
}

m["gba"] = {
	"Gbaya",
	3099986,
	"alv-gba",
	"Latn",
}

m["gbb"] = {
	"Kaytetye",
	6380709,
	"aus-rnd",
	"Latn",
}

m["gbd"] = {
	"Karadjeri",
	3913837,
	"aus-pam",
	"Latn",
}

m["gbe"] = {
	"Niksek",
	56375,
	"paa",
	"Latn",
}

m["gbf"] = {
	"Gaikundi",
	5517032,
	"paa-spk",
	"Latn",
}

m["gbg"] = {
	"Gbanziri",
	35306,
	"nic-nkg",
	"Latn",
}

m["gbh"] = {
	"Defi Gbe",
	12952446,
	"alv-gbe",
	"Latn",
}

m["gbi"] = {
	"Galela",
	3094570,
	"paa-nha",
	"Latn",
}

m["gbj"] = {
	"tiếng Gadaba Bodo",
	3347070,
	"mun",
	"Orya",
	"Tiếng Gadaba Bodo",
	"Gadaba Bodo",
}

m["gbk"] = {
	"tiếng Gaddi",
	17455500,
	"him",
	"Deva, Takr",
	"Tiếng Gaddi",
	"Gaddi",
	translit = {Deva = "hi-translit"},
}

m["gbl"] = {
	"tiếng Gamit",
	2731717,
	"inc-bhi",
	"Deva, Gujr",
	"Tiếng Gamit",
	"Gamit",
}

m["gbm"] = {
	"tiếng Garhwal",
	33459,
	"inc-pah",
	"Deva",
	"Tiếng Garhwal",
	"Garhwal",
	translit = "hi-translit",
}

m["gbn"] = {
	"Mo'da",
	12755683,
	"csu-bbk",
	"Latn",
}

m["gbo"] = {
	"tiếng Grebo Bắc",
	11157042,
	"kro-grb",
	"Latn",
	"Tiếng Grebo Bắc",
	"Grebo Bắc",
	ancestors = "grb",
}

m["gbp"] = {
	"Gbaya-Bossangoa",
	11011295,
	"alv-gbw",
	"Latn",
}

m["gbq"] = {
	"Gbaya-Bozoum",
	4952879,
	"alv-gbw",
	"Latn",
}

m["gbr"] = {
	"Gbagyi",
	11015105,
	"alv-ngb",
	"Latn",
}

m["gbs"] = {
	"Gbesi Gbe",
	12952448,
	"alv-pph",
	"Latn",
}

m["gbu"] = {
	"Gagadu",
	35677,
	"aus-arn",
	"Latn",
}

m["gbv"] = {
	"Gbanu",
	3914945,
	"alv-gbf",
	"Latn",
}

m["gbw"] = {
	"Gabi",
	5515391,
	"aus-pam",
	"Latn",
}

m["gbx"] = {
	"Eastern Xwla Gbe",
	18379975,
	"alv-pph",
	"Latn",
}

m["gby"] = {
	"Gbari",
	3915451,
	"alv-ngb",
	"Latn",
}

m["gcc"] = {
	"Mali",
	6743338,
	"paa-bng",
	"Latn",
}

m["gcd"] = {
	"Ganggalida",
	3913765,
	"aus-tnk",
	"Latn",
}

m["gce"] = {
	"Galice",
	20711,
	"ath-pco",
	"Latn",
}

m["gcf"] = {
	"tiếng Creole Antilles",
	3006280,
	"crp",
	"Latn",
	"Tiếng Creole Antilles",
	"Creole Antilles",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["gcl"] = {
	"Grenadian Creole English",
	4252500,
	"crp",
	"Latn",
	ancestors = "en",
}

m["gcn"] = {
	"Gaina",
	11732195,
	"ngf",
	"Latn",
}

m["gcr"] = {
	"Guianese Creole",
	1363072,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["gct"] = {
	"Colonia Tovar German",
	1138351,
	"gmw-hgm",
	"Latn",
	ancestors = "gsw",
}

m["gdb"] = {
	"tiếng Ollar",
	33906,
	"dra-pgd",
	"Orya, Telu",
	"Tiếng Ollar",
	"Ollar",
	translit = {
		Telu = "te-translit"
	},
}

m["gdc"] = {
	"Gugu Badhun",
	10510360,
	"aus-pam",
	"Latn",
}

m["gdd"] = {
	"Gedaged",
	35292,
	"poz-ocw",
	"Latn",
}

m["gde"] = {
	"Gude",
	3441230,
	"cdc-cbm",
	"Latn",
}

m["gdf"] = {
	"Guduf-Gava",
	3441350,
	"cdc-cbm",
	"Latn",
}

m["gdg"] = { -- not to be confused with gad, gdk
	"Ga'dang",
	5515189,
	"phi",
}

m["gdh"] = {
	"Gadjerawang",
	3913817,
	"aus-jar",
	"Latn",
}

m["gdi"] = {
	"Gundi",
	11137851,
	"nic-nkb",
	"Latn",
}

m["gdj"] = {
	"Kurtjar",
	5619931,
	"aus-pmn",
	"Latn",
}

m["gdk"] = { -- not to be confused with gad, gdg
	"Gadang",
	56256,
	"cdc-est",
	"Latn",
}

m["gdl"] = {
	"tiếng Dirasha",
	56809,
	"cus-eas",
	"Ethi",
	"Tiếng Dirasha",
	"Dirasha",
}

m["gdm"] = {
	"Laal",
	33436,
	nil,
	"Latn",
}

m["gdn"] = {
	"Umanakaina",
	7881084,
	"ngf",
	"Latn",
}

m["gdo"] = {
	"tiếng Godoberi",
	56515,
	"cau-and",
	"Cyrl",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
	"Tiếng Godoberi",
	"Godoberi",
}

m["gdq"] = {
	"tiếng Mehri",
	13361,
	"sem-sar",
	"Arab, Latn",
	"Tiếng Mehri",
	"Mehri"
}

m["gdr"] = {
	"Wipi",
	8026711,
	"paa",
	"Latn",
}

m["gds"] = {
	"Ghandruk Sign Language",
	15971577,
	"sgn",
}

m["gdt"] = {
	"Kungardutyi",
	6444517,
	"aus-kar",
	"Latn",
}

m["gdu"] = {
	"Gudu",
	3441172,
	"cdc-cbm",
	"Latn",
}

m["gdx"] = {
	"Godwari",
	3540922,
	"inc-wes",
	ancestors = "mwr",
}

m["gea"] = {
	"Geruma",
	3438789,
	"cdc-wst",
	"Latn",
}

m["geb"] = {
	"Kire",
	11129733,
	"paa",
	"Latn",
}

m["gec"] = {
	"Gboloo Grebo",
	11019342,
	"kro-grb",
	"Latn",
	ancestors = "grb",
}

m["ged"] = {
	"Gade",
	3914459,
	"alv-nup",
	"Latn",
}

m["geg"] = {
	"Gengle",
	3438345,
	"alv-mye",
	"Latn",
	ancestors = "kow",
}

m["geh"] = {
	"Hutterisch",
	33385,
	"gmw-hgm",
	"Latn",
	ancestors = "bar",
}

m["gei"] = {
	"Gebe",
	3100032,
	"poz-hce",
	"Latn",
}

m["gej"] = {
	"tiếng Gen",
	33450,
	"alv-gbe",
	"Latn",
	"Tiếng Gen",
	"Gen",
}

m["gek"] = {
	"tiếng Yiwom",
	3441277,
	"cdc-wst",
	"Latn",
	"Tiếng Yiwom",
	"Yiwom",
}

m["gel"] = {
	"Fakkanci",
	36627,
	"nic-knn",
	"Latn",
}

m["geq"] = {
	"Geme",
	3915851,
	"znd",
	"Latn",
}

m["ges"] = {
	"Geser-Gorom",
	5553579,
	"poz-cma",
	"Latn",
}

m["gev"] = {
	"Viya",
	7937974,
	"bnt-tso",
	"Latn",
}

m["gew"] = {
	"Gera",
	3438725,
	"cdc-wst",
	"Latn",
}

m["gex"] = {
	"tiếng Garre",
	56618,
	"cus-som",
	"Latn",
	"Tiếng Garre",
	"Garre",
}

m["gey"] = {
	"Enya",
	5381452,
	"bnt-mbe",
	"Latn",
}

m["gez"] = {
	"tiếng Geʽez",
	35667,
	"sem-eth",
	"Ethi",
	"Tiếng Geʽez",
	"Geʽez",
	translit = "Ethi-translit",
}

m["gfk"] = {
	"Patpatar",
	3368846,
	"poz-ocw",
	"Latn",
}

m["gft"] = {
	"Gafat",
	56910,
	"sem-eth",
	"Ethi, Latn",
}

m["gga"] = {
	"Gao",
	3095228,
	"poz-ocw",
	"Latn",
}

m["ggb"] = {
	"Gbii",
	3914390,
	"kro-wkr",
	"Latn",
}

m["ggd"] = {
	"Gugadj",
	5615186,
	"aus-pmn",
	"Latn",
}

m["gge"] = {
	"Guragone",
	5619801,
	"aus-arn",
	"Latn",
}

m["ggg"] = {
	"Gurgula",
	5620032,
	"inc-wes",
	"Arab",
	ancestors = "mwr",
}

m["ggk"] = {
	"Kungarakany",
	6444516,
	"aus-arn",
	"Latn",
}

m["ggl"] = {
	"Ganglau",
	5521140,
	"ngf-mad",
	"Latn",
}

m["ggn"] = {
	"Eastern Gurung",
	12952472,
	"sit-tam",
	"Gukh, Deva",
}

m["ggt"] = {
	"Gitua",
	3107865,
	"poz-ocw",
	"Latn",
}

m["ggu"] = {
	"Gban",
	3913317,
	"dmn-nbe",
	"Latn",
}

m["ggw"] = {
	"Gogodala",
	3512161,
	"paa-pag",
	"Latn",
}

m["gha"] = {
	"tiếng Ghadames",
	56747,
	"ber",
	"Latn, Tfng", -- and other scripts?
	"Tiếng Ghadames",
	"Ghadames",
	translit = {Tfng = "Tfng-translit"},
}

m["ghc"] = {
	"tiếng Gael cổ điển",
	5128278,
	"cel-gae",
	"Latn, Latg",
	ancestors = "mga",
}

m["ghe"] = {
	"Southern Ghale",
	12952453,
	"sit-tam",
	"Deva",
}

m["ghh"] = {
	"Northern Ghale",
	22662104,
	"sit-tam",
	"Deva",
}

m["ghk"] = {
	"tiếng Karen Geko",
	5530317,
	"kar",
	"Mymr",
	"Tiếng Karen Geko",
	"Karen Geko",
}

m["ghl"] = {
	"Ghulfan",
	16885737,
	"nub-hil",
	"Latn", -- and others?
}

m["ghn"] = {
	"Ghanongga",
	3104772,
	"poz-ocw",
	"Latn",
}

m["gho"] = {
	"tiếng Ghomara",
	35315,
	"ber",
	"Tfng, Latn, Arab",
	"Tiếng Ghomara",
	"Ghomara",
	translit = {Tfng = "Tfng-translit"},
}

m["ghr"] = {
	"Ghera",
	22808992,
	"inc-hiw",
}

m["ghs"] = {
	"Guhu-Samane",
	11732219,
	"ngf",
	"Latn",
}

m["ght"] = {
	"tiếng Kuke",
	6448337,
	"sit-tam",
	"Tibt",
	"Tiếng Kuke",
	"Kuke",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["gia"] = {
	"Kitja",
	1284877,
	"aus-jar",
	"Latn",
}

m["gib"] = {
	"Gibanawa",
	12953530,
	"crp",
	"Latn",
	ancestors = "ha",
}

m["gid"] = {
	"Gidar",
	35265,
	"cdc-cbm",
	"Latn",
}

m["gie"] = {
	"Guébie",
	nil,
	"kro-did",
	"Latn",
}

m["gig"] = {
	"Goaria",
	33269,
	"inc-wes",
	"Arab",
	ancestors = "mwr",
}

m["gih"] = {
	"Githabul",
	nil,
	"aus-pam",
	"Latn",
}

m["gii"] = {
	"tiếng Girirra",
	5564288,
	"cus-som",
	nil,
	"Tiếng Girirra",
	"Girirra",
}

m["gil"] = {
	"tiếng Gilbert",
	30898,
	"poz-mic",
	"Latn",
	"Tiếng Gilbert",
	"Gilbert",
}

m["gim"] = {
	"tiếng Gimi (Goroka)",
	11732209,
	"paa",
	"Latn",
	"Tiếng Gimi (Goroka)",
	"Gimi (Goroka)",
}

m["gin"] = {
	"tiếng Hinukh",
	33283,
	"cau-wts",
	"Cyrl",
	"Tiếng Hinukh",
	"Hinukh",
	translit = "gin-translit",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["gio"] = {
	"Gelao",
	56401,
	"qfa-tak",
}

m["gip"] = {
	"Gimi (Austronesian)",
	12952457,
	"poz-ocw",
}

m["giq"] = {
	"Green Gelao",
	12953525,
	"qfa-gel",
}

m["gir"] = {
	"Red Gelao",
	3100264,
	"qfa-gel",
}

m["gis"] = {
	"North Giziga",
	3515084,
	"cdc-cbm",
}

m["git"] = {
	"tiếng Gitxsan",
	3107862,
	"nai-tsi",
	"Latn",
	"Tiếng Gitxsan",
	"Gitxsan",
}

m["giu"] = {
	"Mulao",
	11092831,
	"qfa-gel",
}

m["giw"] = {
	"tiếng Cờ Lao Trắng",
	8843040,
	"qfa-gel",
	nil,
	"Tiếng Cờ Lao Trắng",
	"Cờ Lao Trắng",
}

m["gix"] = {
	"Gilima",
	10977716,
	"nic-nkm",
	"Latn",
}

m["giy"] = {
	"Giyug",
	5565906,
}

m["giz"] = {
	"South Giziga",
	3502232,
	"cdc-cbm",
}

m["gji"] = {
	"Geji",
	3914890,
	"cdc-wst",
	"Latn",
}

m["gjk"] = {
	"tiếng Koli Kachi",
	12953646,
	"inc-wes",
	"Gujr",
	"Tiếng Koli Kachi",
	"Koli Kachi",
}

m["gjm"] = {
	"Gunditjmara",
	6448731,
	"aus-pam",
}

m["gjn"] = {
	"Gonja",
	35267,
	"alv-gng",
	"Latn",
}

m["gju"] = {
	"tiếng Gujar",
	3241731,
	"inc-wes",
	"ur-Arab, Deva, Takr",
	"Tiếng Gujar",
	"Gujar",
	ancestors = "raj",
	entry_name = {
		["ur-Arab"] = {
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna .. c.smallv,
			from = {"ڵ", "ݩ"},
			to = {"ل", "ن"}
		},
	},
}

m["gka"] = {
	"Guya",
	11732221,
	"ngf-fin",
	"Latn",
}

m["gkd"] = {
	"Magɨ",
	nil,
	"ngf-mad",
	"Latn",
}

m["gke"] = {
	"Ndai",
	6983667,
	"alv-mbm",
}

m["gkn"] = {
	"Gokana",
	3075137,
	"nic-ogo",
	"Latn",
}

m["gko"] = {
	"Kok-Nar",
	6426526,
	"aus-pmn",
	"Latn",
}

m["gkp"] = {
	"tiếng Kpelle Guinea",
	11052867,
	"dmn-msw",
	"Latn, Kpel",
	"Tiếng Kpelle Guinea",
	"Kpelle Guinea",
	ancestors = "kpe",
}

m["glb"] = {
	"tiếng Belnəng",
	48813291,
	"cdc-wst",
	nil,
	"Tiếng Belnəng",
	"Belnəng",
}

m["glc"] = {
	"Bon Gula",
	289816,
	"alv-bua",
}

m["gld"] = {
	"tiếng Nanai",
	13303,
	"tuw-nan",
	"Cyrl",
	"Tiếng Nanai",
	"Nanai",
	translit = "gld-translit",
	entry_name = {remove_diacritics = c.macron},
	sort_key = {
		from = {"ё", "ӈ"},
		to = {"е" .. p[1], "н" .. p[1]}
	},
}

m["glh"] = {
	"Northwest Pashayi",
	23713532,
	"inc-pas",
	"fa-Arab",
}

m["glj"] = {
	"Kulaal",
	33360,
	"alv-bua",
}

m["glk"] = {
	"tiếng Gilak",
	33657,
	"ira-csp",
	"fa-Arab",
	"Tiếng Gilak",
	"Gilak",
}

m["glo"] = {
	"Galambu",
	2598797,
	"cdc-wst",
	"Latn",
}

m["glr"] = {
	"Glaro-Twabo",
	3915313,
	"kro-wee",
}

m["glu"] = {
	"Gula",
	5617176,
	"csu-bgr",
}

m["glw"] = {
	"Glavda",
	3441285,
	"cdc-cbm",
	"Latn",
}

m["gly"] = {
	"Gule",
	3120736,
	"ssa-kom",
}

m["gma"] = {
	"Gambera",
	10502327,
	"aus-wor",
}

m["gmb"] = {
	"Gula'alaa",
	3120733,
	"poz-sls",
	"Latn",
}

m["gmd"] = {
	"Mághdì",
	3914475,
	"alv-bwj",
}

m["gmg"] = {
	"Magiyi",
	16926155,
	"ngf-mad",
	"Latn",
}

m["gmh"] = {
	"tiếng Đức cao địa trung đại",
	837985,
	"gmw-hgm",
	"Latn",
	"Tiếng Đức cao địa trung đại",
	"Đức cao địa trung đại",
	entry_name = {
		remove_diacritics = c.circ .. c.macron,
		from = {"Ë", "ë", "[ƷȤ]", "[ʒȥ]"},
		to = {"E", "e", "Z", "z"}
	},
}

m["gml"] = {
	"tiếng Hạ Đức trung đại",
	505674,
	"gmw-lgm",
	"Latn",
	"Tiếng Hạ Đức trung đại",
	"Hạ Đức trung đại",
	entry_name = {remove_diacritics = c.circ .. c.macron .. c.diaer},
}

m["gmm"] = {
	"Gbaya-Mbodomo",
	6799713,
	"alv-gbf",
	"Latn",
}

m["gmn"] = {
	"Gimnime",
	11016905,
	"alv-dur",
}

m["gmu"] = {
	"Gumalu",
	5618027,
	"ngf-mad",
}

m["gmv"] = {
	"tiếng Gamo",
	16116386,
	"omv-nom",
	"Latn, Ethi",
	"Tiếng Gamo",
	"Gamo",
}

m["gmx"] = {
	"Magoma",
	16939552,
	"bnt-bki",
}

m["gmy"] = {
	"tiếng Hy Lạp Mycenae",
	668366,
	"grk",
	"Linb",
	"Tiếng Hy Lạp Mycenae",
	"Hy Lạp Mycenae",
	translit = "Linb-translit",
	override_translit = true,
}

m["gmz"] = {
	"Mgbo",
	6826835,
	"alv-igb",
	ancestors = "izi",
}

m["gna"] = {
	"Kaansa",
	56802,
	"nic-gur",
}

m["gnb"] = {
	"Gangte",
	12952442,
	"tbq-kuk",
}

m["gnc"] = {
	"tiếng Guanche",
	35762,
	"ber",
	"Latn",
	"Tiếng Guanche",
	"Guanche",
}

m["gnd"] = {
	"Zulgo-Gemzek",
	56800,
	"cdc-cbm",
	"Latn",
}

m["gne"] = {
	"Ganang",
	nil,
	"nic-plc",
	ancestors = "izr",
}

m["gng"] = {
	"Ngangam",
	35888,
	"nic-grm",
}

m["gnh"] = {
	"Lere",
	3915319,
	"nic-jer",
}

m["gni"] = {
	"tiếng Gooniyandi",
	2669219,
	"aus-bub",
	"Latn",
	"Tiếng Gooniyandi",
	"Gooniyandi",
}

m["gnj"] = {
	"Ngen",
	nil,
	"dmn-nbe",
	"Latn",
}

m["gnk"] = {
	"ǁGana",
	1975199,
	"khi-kal",
}

m["gnl"] = {
	"Gangulu",
	4916329,
	"aus-pam",
}

m["gnm"] = {
	"Ginuman",
	11732210,
	"ngf",
}

m["gnn"] = {
	"Gumatj",
	10510745,
	"aus-yol",
	"Latn",
}

m["gnq"] = {
	"Gana",
	5520523,
	"poz-san",
}

m["gnr"] = {
	"Gureng Gureng",
	5619998,
	"aus-pam",
}

m["gnt"] = {
	"Guntai",
	12952475,
	"paa",
}

m["gnu"] = {
	"Gnau",
	3915810,
	"qfa-tor",
}

m["gnw"] = {
	"Western Bolivian Guaraní",
	3775037,
	"tup-gua",
	"Latn",
	ancestors = "gn",
}

m["gnz"] = {
	"Ganzi",
	11137942,
	"nic-nkb",
	"Latn",
}

m["goa"] = {
	"Guro",
	35251,
	"dmn-mda",
	"Latn",
}

m["gob"] = {
	"Playero",
	3027923,
	"sai-guh",
}

m["goc"] = {
	"Gorakor",
	12952463,
	"poz-ocw",
	"Latn",
}

m["god"] = {
	"Godié",
	3914412,
	"kro-bet",
}

m["goe"] = {
	"Gongduk",
	2669221,
	"sit",
}

m["gof"] = {
	"tiếng Gofa",
	12631584,
	"omv-nom",
	"Latn, Ethi",
	"Tiếng Gofa",
	"Gofa",
}

m["gog"] = {
	"Gogo",
	3272630,
	"bnt-ruv",
	"Latn",
}

m["goh"] = {
	"tiếng Đức cao địa cổ",
	35218,
	"gmw-hgm",
	"Latn, Runr",
	"Tiếng Đức cao địa cổ",
	"Đức cao địa cổ",
	entry_name = {
		remove_diacritics = c.circ .. c.macron .. c.diaer,
		from = {"[ƷȤ]", "[ʒȥ]"},
		to = {"Z", "z"}
	},
	translit = {
		Runr = "Runr-translit",
	},
}

m["goi"] = {
	"Gobasi",
	5575414,
	"ngf",
	"Latn",
}

m["goj"] = {
	"Gowlan",
	12953532,
	"inc-sou",
}

-- gok is a spurious language, see [[w:Spurious languages]]

m["gol"] = {
	"Gola",
	35482,
	"alv",
}

m["gon"] = {
	"tiếng Gondi Adilabad",
	1775361,
	"dra-gon",
	"Telu, Gonm, Gong",
	"Tiếng Gondi Adilabad",
	"Gondi Adilabad",
	translit = {
		Telu = "te-translit",
		Gong = "gon-Gong-translit",
		Gonm = "gon-Gonm-translit",
	},
}

m["goo"] = {
	"tiếng Gone Dau",
	3110470,
	"poz-occ",
	"Latn",
	"Tiếng Gone Dau",
	"Gone Dau",
}

m["gop"] = {
	"Yeretuar",
	8052565,
	"poz-hce",
	"Latn",
}

m["goq"] = {
	"Gorap",
	3110816,
	"crp",
	ancestors = "ms",
}

m["gor"] = {
	"tiếng Gorontalo",
	2501174,
	"phi",
	"Latn",
	"Tiếng Gorontalo",
	"Gorontalo",
}

m["got"] = {
	"tiếng Goth",
	35722,
	"gme",
	"Goth, Runr, Latn",
	"Tiếng Goth",
	"Goth",
	translit = {Goth = "Goth-translit"},
	link_tr = true,
	entry_name = {Latn = {remove_diacritics = c.macron}},
}

m["gou"] = {
	"Gavar",
	3441180,
	"cdc-cbm",
}

m["gov"] = {
	"Goo",
	16927208,
	"dmn",
	"Latn",
}

m["gow"] = {
	"tiếng Gorowa",
	3437626,
	"cus-sou",
	"Latn",
	"Tiếng Gorowa",
	"Gorowa",
}

m["gox"] = {
	"Gobu",
	7194986,
	"bad-cnt",
}

m["goy"] = {
	"Goundo",
	317636,
	"alv-kim",
}

m["goz"] = {
	"Gozarkhani",
	5590235,
	"xme-ttc",
	ancestors = "xme-ttc-eas",
}

m["gpa"] = {
	"Gupa-Abawa",
	3915352,
	"alv-ngb",
}

m["gpn"] = {
	"Taiap",
	56237,
	"paa",
}

m["gqa"] = {
	"Ga'anda",
	56245,
	"cdc-cbm",
	"Latn",
}

m["gqi"] = {
	"Guiqiong",
	3120647,
	"sit-qia",
}

m["gqn"] = { -- a variety of 'ter'
	"Kinikinao",
	nil,
	"awd",
}

m["gqr"] = {
	"Gor",
	759992,
	"csu-sar",
}

m["gqu"] = {
	"Qau",
	17284874,
	"qfa-gel",
}

m["gra"] = {
	"tiếng Garasia Rajput",
	21041529,
	"inc-bhi",
	"Deva, Gujr",
	ancestors = "bhb",
	"Tiếng Garasia Rajput",
	"Garasia Rajput",
}

m["grb"] = {
	"Grebo",
	35257,
	"kro-grb",
	"Latn",
}

m["grc"] = {
	"tiếng Hy Lạp cổ",
	35497,
	"grk",
	"Polyt, Cprt",
	"Tiếng Hy Lạp cổ",
	"Hy Lạp cổ",
	translit = {
		Polyt = "grc-translit",
		Cprt = "Cprt-translit",
	},
	override_translit = true,
	entry_name = {
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Polyt = s["Grek-sortkey"],
	},
	standardChars = {
		Polyt = "ΑΆἈἉἊἋἌἍἎἏᾈᾉᾊᾋᾌᾍᾎᾏᾸᾹᾺᾼΒΓΔΕΈἘἙἚἛἜἝῈΖΗΉἨἩἪἫἬἭἮἯᾘᾙᾚᾛᾜᾝᾞᾟῊῌΘΙΊΪἸἹἺἻἼἽἾἿῘῙῚΚΛΜΝΞΟΌὈὉὊὋὌὍΠΡῬΣΤΥΎΫὙὛὝὟῨῩῪΦΧΨΩΏὨὩὪὫὬὭὮὯᾨᾩᾪᾫᾬᾭᾮᾯῸῺῼαάἀἁἂἃἄἅἆἇὰᾀᾁᾂᾃᾄᾅᾆᾇᾰᾱᾲᾳᾴᾶᾷβγδεέἐἑἒἓἔἕὲζηήἠἡἢἣἤἥἦἧὴᾐᾑᾒᾓᾔᾕᾖᾗῂῃῄῆῇθιίϊΐἰἱἲἳἴἵἶἷὶῐῑῒῖῗκλμνξοόὀὁὂὃὄὅὸπρῤῥςστυύϋΰὐὑὒὓὔὕὖὗὺῠῡῢῦῧφχψωώὠὡὢὣὤὥὦὧὼᾠᾡᾢᾣᾤᾥᾦᾧῲῳῴῶῷ·ͺ΄΅᾽᾿῀῁῍῎῏῝῞῟῭`´῾",
		Cprt = "𐠀𐠁𐠂𐠃𐠄𐠅𐠈𐠊𐠋𐠌𐠍𐠎𐠏𐠐𐠑𐠒𐠓𐠔𐠕𐠖𐠗𐠘𐠙𐠚𐠛𐠜𐠝𐠞𐠟𐠠𐠡𐠢𐠣𐠤𐠥𐠦𐠧𐠨𐠩𐠪𐠫𐠬𐠭𐠮𐠯𐠰𐠱𐠲𐠳𐠴𐠵𐠷𐠸𐠼𐠿",
		c.punc
	},
}

m["grd"] = {
	"Guruntum",
	3441272,
	"cdc-wst",
	"Latn",
}

m["grg"] = {
	"Madi",
	6727664,
	"ngf-fin",
	"Latn",
}

m["grh"] = {
	"tiếng Gbiri-Niragu",
	3913936,
	"nic-kau",
	"Latn",
	"Tiếng Gbiri-Niragu",
	"Gbiri-Niragu",
}

m["gri"] = {
	"Ghari",
	3104782,
	"poz-sls",
	"Latn",
}

m["grj"] = {
	"Southern Grebo",
	3914444,
	"kro-grb",
	"Latn",
	ancestors = "grb",
}

m["grm"] = {
	"Kota Marudu Talantang",
	6433808,
	"poz-san",
	"Latn",
}

m["gro"] = {
	"Groma",
	56551,
	"sit-tib",
}

m["grq"] = {
	"Gorovu",
	56355,
	"paa",
	"Latn",
}

m["grr"] = {
	"tiếng Taznatit",
	27926110,
	"ber",
	"Arab, Tfng",
	"Tiếng Taznatit",
	"Taznatit",
	translit = {Tfng = "Tfng-translit"},
}

m["grs"] = {
	"Gresi",
	5607612,
	"paa-nim",
	"Latn",
}

m["grt"] = {
	"tiếng Garo",
	36137,
	"tbq-bdg",
	"Latn, Beng, Brai",
	"Tiếng Garo",
	"Garo",
}

m["gru"] = {
	"tiếng Kistane",
	13273,
	"sem-eth",
	"Latn, Ethi",
	"Tiếng Kistane",
	"Kistane",
}

m["grv"] = {
	"Central Grebo",
	18385114,
	"kro-grb",
	"Latn",
	ancestors = "grb",
}

m["grw"] = {
	"Gweda",
	5623387,
	"poz-ocw",
	"Latn",
}

m["grx"] = {
	"Guriaso",
	12631954,
	"paa-kwm",
	"Latn",
}

m["gry"] = {
	"Barclayville Grebo",
	11157342,
	"kro-grb",
	"Latn",
	ancestors = "grb",
}

m["grz"] = {
	"Guramalum",
	3120935,
	"poz-ocw",
	"Latn",
}

m["gse"] = {
	"Ghanaian Sign Language",
	35289,
	"sgn",
	"Latn", -- when documented
}

m["gsg"] = {
	"German Sign Language",
	33282,
	"sgn-gsl",
	"Sgnw",
}

m["gsl"] = {
	"Gusilay",
	35439,
	"alv-jol",
	"Latn",
}

m["gsm"] = {
	"Guatemalan Sign Language",
	2886781,
	"sgn",
	"Latn", -- when documented
}

m["gsn"] = {
	"Gusan",
	11732224,
	"ngf-fin",
	"Latn",
}

m["gso"] = {
	"Southwest Gbaya",
	4919322,
	"alv-gbs",
	"Latn",
}

m["gsp"] = {
	"Wasembo",
	7971402,
	"ngf-mad",
	"Latn",
}

m["gss"] = {
	"Greek Sign Language",
	3565084,
	"sgn",
}

m["gsw"] = {
	"tiếng Đức Alemanni",
	131339,
	"gmw-hgm",
	"Latn",
	"Tiếng Đức Alemanni",
	"Đức Alemanni",
	wikimedia_codes = "als",
	ancestors = "gmh",
}

m["gta"] = {
	"Guató",
	3027940,
	"qfa-iso",
	"Latn",
}

m["gtu"] = {
	"Aghu Tharrnggala",
	16825981,
	"aus-pmn",
	"Latn",
}

m["gua"] = {
	"Shiki",
	3913946,
	"nic-jrn",
	"Latn",
}

m["gub"] = {
	"tiếng Guajajára",
	7699720,
	"tup-gua",
	"Latn",
	"Tiếng Guajajára",
	"Guajajára",
}

m["guc"] = {
	"tiếng Wayuu",
	891085,
	"awd-taa",
	"Latn",
	"Tiếng Wayuu",
	"Wayuu",
}

m["gud"] = {
	"Yocoboué Dida",
	21074781,
	"kro-did",
	"Latn",
}

m["gue"] = {
	"Gurindji",
	10511016,
	"aus-pam",
	"Latn",
}

m["guf"] = {
	"Gupapuyngu",
	10511004,
	"aus-yol",
	"Latn",
}

m["gug"] = {
	"tiếng Guarani Paraguay",
	17478066,
	"tup-gua",
	"Latn",
	"Tiếng Guarani Paraguay",
	"Guarani Paraguay",
	ancestors = "gn",
}

m["guh"] = {
	"Guahibo",
	2669193,
	"sai-guh",
	"Latn",
}

m["gui"] = {
	"Eastern Bolivian Guaraní",
	2963912,
	"tup-gua",
	"Latn",
	ancestors = "gn",
}

m["guk"] = {
	"tiếng Gumuz",
	2396970,
	"ssa",
	"Latn, Ethi",
	"Tiếng Gumuz",
	"Gumuz",
}

m["gul"] = {
	"Gullah",
	33395,
	"crp",
	"Latn",
	ancestors = "en",
}

m["gum"] = {
	"Guambiano",
	2744745,
	"sai-bar",
	"Latn",
}

m["gun"] = {
	"tiếng Guarani Mbya",
	3915584,
	"gn",
	"Latn",
	"Tiếng Guarani Mbya",
	"Guarani Mbya",
}

m["guo"] = {
	"Guayabero",
	2980375,
	"sai-guh",
	"Latn",
}

m["gup"] = {
	"Gunwinggu",
	1406574,
	"aus-gun",
	"Latn",
}

m["guq"] = {
	"Aché",
	383701,
	"tup",
	"Latn",
}

m["gur"] = {
	"tiếng Gurenne",
	35331,
	"nic-mre",
	"Latn",
	"Tiếng Gurenne",
	"Gurenne",
}

m["gus"] = {
	"Guinean Sign Language",
	15983937,
	"sgn",
	"Latn", -- when documented
}

m["gut"] = {
	"Maléku Jaíka",
	3915782,
	"cba",
	"Latn",
}

m["guu"] = {
	"Yanomamö",
	8048928,
	"sai-ynm",
	"Latn",
}

m["guv"] = {
	"Gey",
	nil,
	"alv-sav",
	"Latn",
}

m["guw"] = {
	"tiếng Gun",
	3111668,
	"alv-gbe",
	"Latn",
	"Tiếng Gun",
	"Gun",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.macron},
}

m["gux"] = {
	"tiếng Gulimancema",
	35474,
	"nic-grm",
	"Latn",
	"Tiếng Gulimancema",
	"Gulimancema"
}

m["guz"] = {
	"Gusii",
	33603,
	"bnt-lok",
	"Latn",
}

m["gva"] = {
	"Kaskihá",
	3033534,
	"sai-mas",
	"Latn",
}

m["gvc"] = {
	"Guanano",
	3566001,
	"sai-tuc",
	"Latn",
}

m["gve"] = {
	"Duwet",
	5317647,
	"poz-ocw",
	"Latn",
}

m["gvf"] = {
	"Golin",
	3110291,
	"ngf",
	"Latn",
}

m["gvj"] = {
	"tiếng Guajá",
	3915506,
	"tup",
	"Latn",
	"Tiếng Guajá",
	"Guajá",
}

m["gvl"] = {
	"tiếng Gulay",
	641737,
	"csu-sar",
	"Latn",
	"Tiếng Gulay",
	"Gulay",
}

m["gvm"] = {
	"Gurmana",
	3913363,
	"nic-shi",
	"Latn",
}

m["gvn"] = {
	"Kuku-Yalanji",
	5621973,
	"aus-pam",
	"Latn",
}

m["gvo"] = {
	"Gavião do Jiparaná",
	5528335,
	"tup",
	"Latn",
}

m["gvp"] = {
	"Pará Gavião",
	3365443,
	"sai-nje",
	"Latn",
}

m["gvr"] = {
	"Western Gurung",
	2392342,
	"sit-tam",
	"Gukh, Deva",
}

m["gvs"] = {
	"Gumawana",
	5618041,
	"poz-ocw",
	"Latn",
}

m["gvy"] = {
	"Guyani",
	10511230,
	"aus-pam",
	"Latn",
}

m["gwa"] = {
	"Mbato",
	3914941,
	"alv-ptn",
	"Latn",
}

m["gwb"] = {
	"Gwa",
	5623219,
	"nic-jrn",
	"Latn",
}

m["gwc"] = {
	"tiếng Kalam",
	1675961,
	"inc-koh",
	"Arab",
	"Tiếng Kalam",
	"Kalam",
}

m["gwd"] = {
	"tiếng Gawwada",
	3032135,
	"cus-eas",
	"Latn, Ethi",
	"Tiếng Gawwada",
	"Gawwada",
}

m["gwe"] = {
	"Gweno",
	3358211,
	"bnt-chg",
	"Latn",
}

m["gwf"] = {
	"Gowro",
	3812403,
	"inc-koh",
}

m["gwg"] = {
	"Moo",
	6907057,
	"alv-bwj",
	"Latn",
}

m["gwi"] = {
	"tiếng Gwichʼin",
	21057,
	"ath-nor",
	"Latn",
	"Tiếng Gwichʼin",
	"Gwichʼin",
}

m["gwj"] = {
	"Gcwi",
	12631978,
	"khi-kal",
	"Latn",
}

m["gwm"] = {
	"Awngthim",
	4830109,
	"aus-pmn",
	"Latn",
}

m["gwn"] = {
	"Gwandara",
	56521,
	"cdc-wst",
	"Latn",
}

m["gwr"] = {
	"Gwere",
	5623559,
	"bnt-nyg",
	"Latn",
}

m["gwt"] = {
	"tiếng Gawar-Bati",
	33894,
	"inc-kun",
	"Arab",
	"Tiếng Gawar-Bati",
	"Gawar-Bati",
}

m["gwu"] = {
	"Guwamu",
	10511225,
	"aus-pam",
	"Latn",
}

m["gww"] = {
	"Kwini",
	10551249,
	"aus-wor",
	"Latn",
}

m["gwx"] = {
	"Gua",
	35422,
	"alv-gng",
	"Latn",
}

m["gxx"] = {
	"Wè Southern",
	19921582,
	"kro-wee",
	"Latn",
}

m["gya"] = {
	"tiếng Tây Bắc Gbaya",
	36594,
	"alv-gbw",
	"Latn",
	"Tiếng Tây Bắc Gbaya",
	"Tây Bắc Gbaya",
}

m["gyb"] = {
	"Garus",
	5524492,
	"ngf-mad",
	"Latn",
}

m["gyd"] = {
	"Kayardild",
	3913770,
	"aus-tnk",
	"Latn",
}

m["gye"] = {
	"Gyem",
	5624046,
	"nic-jer",
	"Latn",
}

m["gyf"] = {
	"Gungabula",
	10510783,
	"aus-pam",
	"Latn",
}

m["gyg"] = {
	"Gbayi",
	11137618,
	"nic-ngd",
	"Latn",
}

m["gyi"] = {
	"Gyele",
	35434,
	"bnt-mnj",
	"Latn",
}

m["gyl"] = {
	"tiếng Gayil",
	5528771,
	"omv-aro",
	"Latn, Ethi",
	"Tiếng Gayil",
	"Gayil",
}

m["gym"] = {
	"Ngäbere",
	3915581,
	"cba",
	"Latn",
}

m["gyn"] = {
	"Guyanese Creole English",
	3305477,
	"crp",
	"Latn",
	ancestors = "en",
}

m["gyo"] = {
	"Gyalsumdo",
	53575940,
	"sit-kyk",
}

m["gyr"] = {
	"tiếng Guarayu",
	3118779,
	"tup",
	"Latn",
	"Tiếng Guarayu",
	"Guarayu",
}

m["gyy"] = {
	"tiếng Gunya",
	10511001,
	"aus-pam",
	"Latn",
}

m["gza"] = {
	"tiếng Ganza",
	5521556,
	"omv-mao",
	"Latn",
	"Tiếng Ganza",
	"Ganza",
}

m["gzn"] = {
	"Gane",
	3095108,
	"poz-hce",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")