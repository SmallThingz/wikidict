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

m["gaa"] = { -- test
	canonicalName = "Ga",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["gab"] = {
	canonicalName = "Gabri",
}

m["gad"] = {
	canonicalName = "Gaddang",
	family = "phi",
}

m["gae"] = {
	canonicalName = "Warekena",
	otherNames = {"Guarequena", "Arekena"},
	scripts = {"Latn"},
	family = "awd",
}

m["gaf"] = {
	canonicalName = "Gende",
}

m["gag"] = {
	canonicalName = "Gagauz",
	scripts = {"Latn", "Cyrl"},
	family = "trk-ogz",
}

m["gah"] = {
	canonicalName = "Alekano",
	otherNames = {"Gahuku"},
	scripts = {"Latn"},
}

m["gai"] = {
	canonicalName = "Borei",
	family = "paa",
}

m["gaj"] = {
	canonicalName = "Gadsup",
}

m["gak"] = {
	canonicalName = "Gamkonora",
}

m["gal"] = {
	canonicalName = "Galoli",
	otherNames = {"Galolen", "Talur"},
}

m["gam"] = {
	canonicalName = "Kandawo",
}

m["gan"] = {
	canonicalName = "Gan",
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"ltc"},
}

m["gao"] = {
	canonicalName = "Gants",
}

m["gap"] = {
	canonicalName = "Gal",
}

m["gaq"] = {
	canonicalName = "Gata'",
	family = "mun",
}

m["gar"] = {
	canonicalName = "Galeya",
	family = "poz-ocw",
}

m["gas"] = {
	canonicalName = "Adiwasi Garasia",
	family = "inc",
}

m["gat"] = {
	canonicalName = "Kenati",
}

m["gau"] = {
	canonicalName = "Kondekor",
	otherNames = {"Gadaba", "San Gadaba", "Gadba", "Sano", "Kondekar", "Kondkor", "Konḍekor Gadaba", "Mudhili Gadaba"},
	family = "dra",
}

m["gaw"] = {
	canonicalName = "Nobonob",
	family = "paa",
}

m["gay"] = {
	canonicalName = "Gayo",
	scripts = {"Latn"},
	family = "poz-nws",
}

m["gba"] = {
	canonicalName = "Gbaya",
}

m["gbb"] = {
	canonicalName = "Kaytetye",
	scripts = {"Latn"},
	family = "aus-rnd",
}

m["gbd"] = {
	canonicalName = "Karadjeri",
	otherNames = {"Garadjari", "Karajarri"},
	family = "aus-pam",
}

m["gbe"] = {
	canonicalName = "Niksek",
	family = "paa",
}

m["gbf"] = {
	canonicalName = "Gaikundi",
	family = "paa",
}

m["gbg"] = {
	canonicalName = "Gbanziri",
	otherNames = {"Banziri", "Gbandere", "Gbanzili"},
	family = "nic-ubg",
}

m["gbh"] = {
	canonicalName = "Defi Gbe",
}

m["gbi"] = {
	canonicalName = "Galela",
}

m["gbj"] = {
	canonicalName = "Bodo Gadaba",
	otherNames = {"Gutob"},
	family = "mun",
}

m["gbk"] = {
	canonicalName = "Gaddi",
}

m["gbl"] = {
	canonicalName = "Gamit",
	family = "inc",
}

m["gbm"] = {
	canonicalName = "Garhwali",
	family = "inc",
}

m["gbn"] = {
	canonicalName = "Mo'da",
}

m["gbo"] = {
	canonicalName = "Northern Grebo",
}

m["gbp"] = {
	canonicalName = "Gbaya-Bossangoa",
}

m["gbq"] = {
	canonicalName = "Gbaya-Bozoum",
}

m["gbr"] = {
	canonicalName = "Gbagyi",
}

m["gbs"] = {
	canonicalName = "Gbesi Gbe",
}

m["gbu"] = {
	canonicalName = "Gagadu",
}

m["gbv"] = {
	canonicalName = "Gbanu",
}

m["gbw"] = {
	canonicalName = "Gabi",
	otherNames = {"Gabi-Gabi", "Gabi Gabi", "Gubbi-Gubbi", "Gubbi Gubbi"}, -- contrast xby
	scripts = {"Latn"},
	family = "aus-pam",
}

m["gbx"] = {
	canonicalName = "Eastern Xwla Gbe",
}

m["gby"] = {
	canonicalName = "Gbari",
}

m["gbz"] = {
	canonicalName = "Zoroastrian Dari",
	otherNames = {"Behdināni", "Gabri", "Gavrŭni", "Gabrōni"},
	scripts = {"Latn"},
	family = "ira",
}

m["gcc"] = {
	canonicalName = "Mali",
}

m["gcd"] = {
	canonicalName = "Ganggalida",
}

m["gce"] = {
	canonicalName = "Galice",
	family = "ath-pco",
}

m["gcf"] = {
	canonicalName = "Antillean Creole",
	otherNames = {"Antillean Creole French", "Guadeloupean Creole", "Guadeloupean Creole French", "Saint Lucian Creole", "Saint Lucian Creole French"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"fr"},
}

m["gcl"] = {
	canonicalName = "Grenadian Creole English",
	family = "crp",
}

m["gcn"] = {
	canonicalName = "Gaina",
}

m["gcr"] = {
	canonicalName = "Guianese Creole",
}

m["gct"] = {
	canonicalName = "Colonia Tovar German",
	otherNames = {"Alemán Coloniero"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gsw"},
}

m["gdb"] = {
	canonicalName = "Ollari",
	otherNames = {"Pottangi Ollar Gadaba", "Ollar Gadaba", "Ollaro", "Hallari", "Allar", "Hollar Gadbas"},
	family = "dra",
}

m["gdc"] = {
	canonicalName = "Gugu Badhun",
}

m["gdd"] = {
	canonicalName = "Gedaged",
	family = "poz-ocw",
}

m["gde"] = {
	canonicalName = "Gude",
}

m["gdf"] = {
	canonicalName = "Guduf-Gava",
	family = "cdc-cbm",
}

m["gdg"] = {
	canonicalName = "Ga'dang",
}

m["gdh"] = {
	canonicalName = "Gadjerawang",
}

m["gdi"] = {
	canonicalName = "Gundi",
	family = "nic-ubg",
}

m["gdj"] = {
	canonicalName = "Kurtjar",
	otherNames = {"Gurdjar", "Kunggara"},
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["gdk"] = {
	canonicalName = "Gadang",
	family = "cdc-est",
}

m["gdl"] = {
	canonicalName = "Dirasha",
	family = "cus",
}

m["gdm"] = {
	canonicalName = "Laal",
	scripts = {"Latn"},
}

m["gdn"] = {
	canonicalName = "Umanakaina",
}

m["gdo"] = {
	canonicalName = "Godoberi",
	otherNames = {"Ghodoberi"},
	scripts = {"Cyrl"},
	family = "cau-ava",
}

m["gdq"] = {
	canonicalName = "Mehri",
	otherNames = {"Mahri"},
	scripts = {"Arab"},
	family = "sem-sar",
}

m["gdr"] = {
	canonicalName = "Wipi",
}

m["gds"] = {
	canonicalName = "Ghandruk Sign Language",
	family = "sgn",
}

m["gdt"] = {
	canonicalName = "Kungardutyi",
}

m["gdu"] = {
	canonicalName = "Gudu",
}

m["gdx"] = {
	canonicalName = "Godwari",
}

m["gea"] = {
	canonicalName = "Geruma",
	family = "cdc-wst",
}

m["geb"] = {
	canonicalName = "Kire",
	family = "paa",
}

m["gec"] = {
	canonicalName = "Gboloo Grebo",
}

m["ged"] = {
	canonicalName = "Gade",
}

m["geg"] = {
	canonicalName = "Gengle",
}

m["geh"] = {
	canonicalName = "Hutterisch",
	otherNames = {"Hutterite German", "Tirolean"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"bar"},
}

m["gei"] = {
	canonicalName = "Gebe",
	family = "poz-hce",
}

m["gej"] = {
	canonicalName = "Gen",
}

m["gek"] = {
	canonicalName = "Gerka",
	otherNames = {"Yiwom"},
	scripts = {"Latn"},
	family = "cdc",
}

m["gel"] = {
	canonicalName = "Fakkanci",
	otherNames = {"Kag-Fer-Jiir-Koor-Ror-Us-Zuksun", "ut-Ma'in", "Fakai", "Kag", "Puku", "Fakanchi", "Et-Kag", "Jiir", "Gelanchi", "Et-Jiir", "Kur", "Kere", "Kar", "Keri-Ni", "Kelli-Ni", "Kelanchi", "Kelinci", "Zuksun", "Zussun", "Et-Zuksun", "Ror", "Et-Maror", "Tudanchi", "Er-Gwar", "Fer", "Fere", "Et-Fer", "Wipsi-Ni", "Kukum", "Us", "Et-Us", "Koor", "Kulu"},
	family = "nic-knj",
}

m["geq"] = {
	canonicalName = "Geme",
	family = "znd",
}

m["ges"] = {
	canonicalName = "Geser-Gorom",
	family = "plf",
}

m["gev"] = {
	canonicalName = "Viya",
	otherNames = {"Eviya"},
}

m["gew"] = {
	canonicalName = "Gera",
	family = "cdc-wst",
}

m["gex"] = {
	canonicalName = "Garre",
	family = "cus",
}

m["gey"] = {
	canonicalName = "Enya",
}

m["gez"] = {
	canonicalName = "Ge'ez",
	otherNames = {"Ethiopic", "Gi'iz"},
	scripts = {"Ethi"},
	family = "sem-eth",
	translit_module = "Ethi-translit",
}

m["gfk"] = {
	canonicalName = "Patpatar",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["gft"] = {
	canonicalName = "Gafat",
	family = "sem-eth",
}

m["gga"] = {
	canonicalName = "Gao",
	family = "poz-ocw",
}

m["ggb"] = {
	canonicalName = "Gbii",
}

m["ggd"] = {
	canonicalName = "Gugadj",
}

m["gge"] = {
	canonicalName = "Guragone",
	family = "aus-arn",
}

m["ggg"] = {
	canonicalName = "Gurgula",
	scripts = {"Arab"},
	family = "inc",
	ancestors = {"mwr"},
}

m["ggk"] = {
	canonicalName = "Kungarakany",
	family = "aus-arn",
}

m["ggl"] = {
	canonicalName = "Ganglau",
}

m["ggn"] = {
	canonicalName = "Eastern Gurung",
}

m["ggt"] = {
	canonicalName = "Gitua",
	family = "poz-ocw",
}

m["ggu"] = {
	canonicalName = "Gban",
}

m["ggw"] = {
	canonicalName = "Gogodala",
}

m["gha"] = {
	canonicalName = "Ghadames",
	otherNames = {"Ghadamès"},
	family = "ber",
}

m["ghe"] = {
	canonicalName = "Southern Ghale",
}

m["ghh"] = {
	canonicalName = "Northern Ghale",
}

m["ghk"] = {
	canonicalName = "Geko Karen",
}

m["ghl"] = {
	canonicalName = "Ghulfan",
}

m["ghn"] = {
	canonicalName = "Ghanongga",
	family = "poz-ocw",
}

m["gho"] = {
	canonicalName = "Ghomara",
}

m["ghr"] = {
	canonicalName = "Ghera",
}

m["ghs"] = {
	canonicalName = "Guhu-Samane",
}

m["ght"] = {
	canonicalName = "Kutang Ghale",
}

m["gia"] = {
	canonicalName = "Kitja",
}

m["gib"] = {
	canonicalName = "Gibanawa",
}

m["gic"] = {
	canonicalName = "Gail",
}

m["gid"] = {
	canonicalName = "Gidar",
}

m["gig"] = {
	canonicalName = "Goaria",
	scripts = {"Arab"},
	family = "inc",
	ancestors = {"mwr"},
}

m["gih"] = {
	canonicalName = "Githabul",
}

m["gil"] = {
	canonicalName = "Gilbertese",
	otherNames = {"Kiribati", "Kiribatese"},
	scripts = {"Latn"},
	family = "poz-mic",
}

m["gim"] = {
	canonicalName = "Papuan Gimi",
	otherNames = {"Gimi"},
	family = "paa",
}

m["gin"] = {
	canonicalName = "Hinukh",
	otherNames = {"Hinuq", "Hinux", "Ginukh", "Ginux"},
	family = "cau-tsz",
}

m["gio"] = {
	canonicalName = "Gelao",
	family = "qfa-tak",
}

m["gip"] = {
	canonicalName = "Austronesian Gimi",
	otherNames = {"Gimi"},
	family = "poz-ocw",
}

m["giq"] = {
	canonicalName = "Green Gelao",
	otherNames = {"Hagei", "Hakhi"},
	family = "qfa-tak",
}

m["gir"] = {
	canonicalName = "Red Gelao",
	otherNames = {"Vandu"},
	family = "qfa-tak",
}

m["gis"] = {
	canonicalName = "North Giziga",
}

m["git"] = {
	canonicalName = "Gitxsan",
}

m["giu"] = {
	canonicalName = "Mulao", -- a variety of Gelao
	family = "qfa-tak",
}

m["giw"] = {
	canonicalName = "White Gelao",
	otherNames = {"Telue", "Doulou", "Tolo"},
	family = "qfa-tak",
}

m["gix"] = {
	canonicalName = "Gilima",
	family = "nic-ubg",
}

m["giy"] = {
	canonicalName = "Giyug",
}

m["giz"] = {
	canonicalName = "South Giziga",
}

m["gji"] = {
	canonicalName = "Geji",
}

m["gjk"] = {
	canonicalName = "Kachi Koli",
}

m["gjm"] = {
	canonicalName = "Gunditjmara",
}

m["gjn"] = {
	canonicalName = "Gonja",
}

m["gju"] = {
	canonicalName = "Gojri",
	family = "inc",
	ancestors = {"raj"},
}

m["gka"] = {
	canonicalName = "Guya",
	family = "ngf-fin",
}

m["gke"] = {
	canonicalName = "Ndai",
}

m["gkn"] = {
	canonicalName = "Gokana",
	family = "nic-bco",
}

m["gko"] = {
	canonicalName = "Kok-Nar",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["gkp"] = {
	canonicalName = "Guinea Kpelle",
}

m["glc"] = {
	canonicalName = "Bon Gula",
}

m["gld"] = {
	canonicalName = "Nanai",
	scripts = {"Cyrl"},
	family = "tuw",
}

m["glh"] = {
	canonicalName = "Northwest Pashayi",
	family = "inc-dar",
}

m["gli"] = {
	canonicalName = "Guliguli",
	family = "poz-ocw",
}

m["glj"] = {
	canonicalName = "Kulaal",
}

m["glk"] = {
	canonicalName = "Gilaki",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["glo"] = {
	canonicalName = "Galambu",
	family = "cdc-wst",
}

m["glr"] = {
	canonicalName = "Glaro-Twabo",
}

m["glu"] = {
	canonicalName = "Gula",
	otherNames = {"Sara Gula"},
	family = "csu",
}

m["glw"] = {
	canonicalName = "Glavda",
}

m["gly"] = {
	canonicalName = "Gule",
}

m["gma"] = {
	canonicalName = "Gambera",
}

m["gmb"] = {
	canonicalName = "Gula'alaa",
	family = "poz-sls",
}

m["gmd"] = {
	canonicalName = "Mághdì",
}

m["gmg"] = {
	canonicalName = "Magɨyi",
	family = "paa",
}

m["gmh"] = {
	canonicalName = "Middle High German",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"goh"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊË]", "[ēêë]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"	   , "e"    , "I"   , "i"   , "O"   , "o"   , "U"   , "u"   },
	},
}

m["gml"] = {
	canonicalName = "Middle Low German",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"osx"},
	entry_name = {
		from = {"[ĀÂÄǞ]", "[āâäǟ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔÖȪ]", "[ōôöȫ]", "[ŪÛÜǕ]", "[ūûüǖ]", "[̂]"},
		to   = {"A"     , "a"     , "E"   , "e"   , "I"   , "i"   , "O"     , "o"     , "U"     , "u"     , ""  },
	},
}

m["gmm"] = {
	canonicalName = "Gbaya-Mbodomo",
}

m["gmn"] = {
	canonicalName = "Gimnime",
}

m["gmu"] = {
	canonicalName = "Gumalu",
}

m["gmv"] = {
	canonicalName = "Gamo",
}

m["gmx"] = {
	canonicalName = "Magoma",
}

m["gmy"] = {
	canonicalName = "Mycenaean Greek",
	scripts = {"Linb"},
	family = "grk",
	translit_module = "Linb-translit",
}

m["gmz"] = {
	canonicalName = "Mgbo",
	otherNames = {"Mgbolizhia"},
	family = "alv-von",
}

m["gna"] = {
	canonicalName = "Kaansa",
}

m["gnb"] = {
	canonicalName = "Gangte",
	family = "tbq-kuk",
}

m["gnc"] = {
	canonicalName = "Guanche",
	family = "ber",
}

m["gnd"] = {
	canonicalName = "Zulgo-Gemzek",
	otherNames = {"Zulgo", "Gemzek", "Mineo"},
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["gne"] = {
	canonicalName = "Ganang",
}

m["gng"] = {
	canonicalName = "Ngangam",
}

m["gnh"] = {
	canonicalName = "Lere",
}

m["gni"] = {
	canonicalName = "Gooniyandi",
	scripts = {"Latn"},
	family = "aus-bub",
}

m["gnk"] = {
	canonicalName = "ǁGana",
	otherNames = {"Gana"},
}

m["gnl"] = {
	canonicalName = "Gangulu",
}

m["gnm"] = {
	canonicalName = "Ginuman",
}

m["gnn"] = {
	canonicalName = "Gumatj",
	family = "aus-yol",
}

m["gnq"] = {
	canonicalName = "Gana",
}

m["gnr"] = {
	canonicalName = "Gureng Gureng",
}

m["gnt"] = {
	canonicalName = "Guntai",
}

m["gnu"] = {
	canonicalName = "Gnau",
	family = "qfa-tor",
}

m["gnw"] = {
	canonicalName = "Western Bolivian Guaraní",
}

m["gnz"] = {
	canonicalName = "Ganzi",
	family = "nic-ubg",
}

m["goa"] = {
	canonicalName = "Guro",
}

m["gob"] = {
	canonicalName = "Playero",
}

m["goc"] = {
	canonicalName = "Gorakor",
	family = "poz-ocw",
}

m["god"] = {
	canonicalName = "Godié",
}

m["goe"] = {
	canonicalName = "Gongduk",
}

m["gof"] = {
	canonicalName = "Gofa",
	scripts = {"Latn", "Ethi"},
	family = "omv",
}

m["gog"] = {
	canonicalName = "Gogo",
}

m["goh"] = {
	canonicalName = "Qədim yuxarı alman",
	scripts = {"Latn"},
	family = "gmw",
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊË]", "[ēêë]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]", "ʒ"},
		to   = {"A"   , "a"   , "E"	,    "e"	, "I"   , "i"   , "O"   , "o"   , "U"   , "u"   , "z" }} ,
}

m["goi"] = {
	canonicalName = "Gobasi",
	otherNames = {"Gobosi", "Gebusi", "Bibo"},
	scripts = {"Latn"},
}

m["goj"] = {
	canonicalName = "Gowlan",
}

m["gok"] = {
	canonicalName = "Gowli",
}

m["gol"] = {
	canonicalName = "Gola",
}

m["gon"] = {
	canonicalName = "Gondi",
	otherNames = {"Southern Gondi", "Northern Gondi", "Aheri Gondi", "Adilabad Gondi", "Dorla Gondi", "Koya Gondi", "Maria Gondi", "Muria Gondi", "Raj Gondi"},
	scripts = {"Telu"},
	family = "dra",
}

m["goo"] = {
	canonicalName = "Gone Dau",
	family = "poz-occ",
}

m["gop"] = {
	canonicalName = "Yeretuar",
	family = "poz-hce",
}

m["goq"] = {
	canonicalName = "Gorap",
}

m["gor"] = {
	canonicalName = "Gorontalo",
	scripts = {"Latn"},
	family = "phi",
}

m["got"] = {
	canonicalName = "Gothic",
	scripts = {"Goth", "Runr"},
	family = "gme",
	translit_module = "Goth-translit",
	link_tr = true,
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["gou"] = {
	canonicalName = "Gavar",
}

m["gow"] = {
	canonicalName = "Gorowa",
	family = "cus",
}

m["gox"] = {
	canonicalName = "Gobu",
}

m["goy"] = {
	canonicalName = "Goundo",
}

m["goz"] = {
	canonicalName = "Gozarkhani",
	ancestors = {"ira-azr"},
}

m["gpa"] = {
	canonicalName = "Gupa-Abawa",
}

m["gpn"] = {
	canonicalName = "Taiap",
}

m["gqa"] = {
	canonicalName = "Ga'anda",
}

m["gqi"] = {
	canonicalName = "Guiqiong",
	otherNames = {"Guìqióng", "Guichong"},
	family = "sit",
}

m["gqn"] = { -- a variety of 'ter'
	canonicalName = "Kinikinao",
	otherNames = {"Guana", "Guaná", "Guana (Brazil)", "Arawakan Guana"},
	family = "awd",
}

m["gqr"] = {
	canonicalName = "Gor",
}

m["gqu"] = {
	canonicalName = "Qau",
	otherNames = {"Gao", "Aqao", "Qau Gelao"},
	family = "qfa-tak",
}

m["gra"] = {
	canonicalName = "Rajput Garasia",
	family = "inc",
}

m["grb"] = {
	canonicalName = "Grebo",
}

m["grc"] = {
	canonicalName = "Ancient Greek",
	scripts = {"polytonic", "Cprt"},
	family = "grk",
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, cpg, pnt; compare ine-pae
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇᾱᾍ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗῑ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧῡ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧᾨ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}},
	entry_name = {
		from = {"[ᾸᾹ]", "[ᾰᾱ]", "[ῘῙ]", "[ῐῑ]", "[ῨῩ]", "[ῠῡ]", "µ"},
		to   = {"Α", "α", "Ι", "ι", "Υ", "υ", "μ"}} ,
}

m["grd"] = {
	canonicalName = "Guruntum",
}

m["grg"] = {
	canonicalName = "Madi",
	family = "ngf-fin",
}

m["grh"] = {
	canonicalName = "Gbiri-Niragu",
}

m["gri"] = {
	canonicalName = "Ghari",
	family = "poz-sls",
}

m["grj"] = {
	canonicalName = "Southern Grebo",
}

m["grm"] = {
	canonicalName = "Kota Marudu Talantang",
}

m["gro"] = {
	canonicalName = "Groma",
}

m["grq"] = {
	canonicalName = "Gorovu",
	family = "paa",
}

m["grr"] = {
	canonicalName = "Taznatit",
	family = "ber",
}

m["grs"] = {
	canonicalName = "Gresi",
}

m["grt"] = {
	canonicalName = "Garo",
}

m["gru"] = {
	canonicalName = "Kistane",
	otherNames = {"Soddo", "Aymälläl"},
	scripts = {"Latn"},
	family = "sem-eth",
}

m["grv"] = {
	canonicalName = "Central Grebo",
}

m["grw"] = {
	canonicalName = "Gweda",
	family = "poz-ocw",
}

m["grx"] = {
	canonicalName = "Guriaso",
}

m["gry"] = {
	canonicalName = "Barclayville Grebo",
}

m["grz"] = {
	canonicalName = "Guramalum",
	family = "poz-ocw",
}

m["gse"] = {
	canonicalName = "Ghanaian Sign Language",
	family = "sgn",
}

m["gsg"] = {
	canonicalName = "German Sign Language",
	otherNames = {"Deutsche Gebärdensprache"},
	scripts = {"Sgnw"},
	family = "sgn-gsl",
}

m["gsl"] = {
	canonicalName = "Gusilay",
}

m["gsm"] = {
	canonicalName = "Guatemalan Sign Language",
	family = "sgn",
}

m["gsn"] = {
	canonicalName = "Gusan",
	family = "ngf-fin",
}

m["gso"] = {
	canonicalName = "Southwest Gbaya",
}

m["gsp"] = {
	canonicalName = "Wasembo",
}

m["gss"] = {
	canonicalName = "Greek Sign Language",
	family = "sgn",
}

m["gsw"] = {
	canonicalName = "Alemannic German",
	otherNames = {"Swiss German", "Walser German", "Walserdeutsch", "Walser", "Wallisertiitsch"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmh"},
	wikimedia_codes = {"als"},
}

m["gta"] = {
	canonicalName = "Guató",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["gti"] = {
	canonicalName = "Gbati-ri",
}

m["gtu"] = {
	canonicalName = "Aghu Tharrnggala",
	otherNames = {"Aghu Tharnggala", "Aghu Tharnggalu"},
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["gua"] = {
	canonicalName = "Shiki",
}

m["gub"] = {
	canonicalName = "Guajajára",
}

m["guc"] = {
	canonicalName = "Wayuu",
	otherNames = {"Guajiro", "Goajiro", "Uagiro"},
	family = "awd",
}

m["gud"] = {
	canonicalName = "Yocoboué Dida",
}

m["gue"] = {
	canonicalName = "Gurindji",
	family = "aus-pam",
}

m["guf"] = {
	canonicalName = "Gupapuyngu",
	family = "aus-yol",
}

m["gug"] = {
	canonicalName = "Paraguayan Guaraní",
}

m["guh"] = {
	canonicalName = "Guahibo",
}

m["gui"] = {
	canonicalName = "Eastern Bolivian Guaraní",
}

m["guk"] = {
	canonicalName = "Gumuz",
}

m["gul"] = {
	canonicalName = "Gullah",
	otherNames = {"Geechee", "Sea Island Creole English"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["gum"] = {
	canonicalName = "Guambiano",
}

m["gun"] = {
	canonicalName = "Mbyá Guaraní",
	scripts = {"Latn"},
	family = "tup",
}

m["guo"] = {
	canonicalName = "Guayabero",
}

m["gup"] = {
	canonicalName = "Gunwinggu",
	family = "aus-gun",
}

m["guq"] = {
	canonicalName = "Aché",
}

m["gur"] = {
	canonicalName = "Farefare",
	otherNames = {"Frafra", "Gurene", "Gurenɛ", "Gurenne", "Gudenne", "Gudeni", "Zuadeni", "Nankani", "Naani", "Nankanse", "Ninkare", "Booni"},
}

m["gus"] = {
	canonicalName = "Guinean Sign Language",
	family = "sgn",
}

m["gut"] = {
	canonicalName = "Maléku Jaíka",
	scripts = {"Latn"},
	family = "cba",
}

m["guu"] = {
	canonicalName = "Yanomamö",
}

m["guv"] = {
	canonicalName = "Gey",
}

m["guw"] = {
	canonicalName = "Gun",
	otherNames = {"Gun-Gbe", "Gungbe"},
	scripts = {"Latn"},
	family = "alv",
}

m["gux"] = {
	canonicalName = "Gourmanchéma",
}

m["guz"] = {
	canonicalName = "Gusii",
	scripts = {"Latn"},
	family = "bnt",
}

m["gva"] = {
	canonicalName = "Kaskihá",
	otherNames = {"Guana", "Guaná", "Guana (Paraguay)", "Mascoian Guana"},
	family = "sai-mas",
}

m["gvc"] = {
	canonicalName = "Guanano",
	scripts = {"Latn"},
	family = "sai-tuc",
}

m["gve"] = {
	canonicalName = "Duwet",
	family = "poz-ocw",
}

m["gvf"] = {
	canonicalName = "Golin",
	scripts = {"Latn"},
	family = "ngf",
}

m["gvj"] = {
	canonicalName = "Guajá",
}

m["gvl"] = {
	canonicalName = "Gulay",
}

m["gvm"] = {
	canonicalName = "Gurmana",
}

m["gvn"] = {
	canonicalName = "Kuku-Yalanji",
}

m["gvo"] = {
	canonicalName = "Gavião do Jiparaná",
}

m["gvp"] = {
	canonicalName = "Pará Gavião",
}

m["gvr"] = {
	canonicalName = "Western Gurung",
}

m["gvs"] = {
	canonicalName = "Gumawana",
	family = "poz-ocw",
}

m["gvy"] = {
	canonicalName = "Guyani",
}

m["gwa"] = {
	canonicalName = "Mbato",
}

m["gwb"] = {
	canonicalName = "Gwa",
}

m["gwc"] = {
	canonicalName = "Kalami",
	scripts = {"Arab"},
	family = "inc-dar",
}

m["gwd"] = {
	canonicalName = "Gawwada",
	family = "cus",
}

m["gwe"] = {
	canonicalName = "Gweno",
	scripts = {"Latn"},
	family = "bnt",
}

m["gwf"] = {
	canonicalName = "Gowro",
}

m["gwg"] = {
	canonicalName = "Moo",
}

m["gwi"] = {
	canonicalName = "Gwich'in",
	otherNames = {"Gwich’in", "Kutchin", "Takudh", "Tukudh", "Loucheux"},
	scripts = {"Latn"},
	family = "ath",
}

m["gwj"] = {
	canonicalName = "Gcwi",
	otherNames = {"Gǀwi", "Gǀui"},
}

m["gwm"] = {
	canonicalName = "Awngthim",
}

m["gwn"] = {
	canonicalName = "Gwandara",
}

m["gwr"] = {
	canonicalName = "Gwere",
}

m["gwt"] = {
	canonicalName = "Gawar-Bati",
}

m["gwu"] = {
	canonicalName = "Guwamu",
}

m["gww"] = {
	canonicalName = "Kwini",
}

m["gwx"] = {
	canonicalName = "Gua",
}

m["gxx"] = {
	canonicalName = "Wè Southern",
}

m["gya"] = {
	canonicalName = "Northwest Gbaya",
}

m["gyb"] = {
	canonicalName = "Garus",
}

m["gyd"] = {
	canonicalName = "Kayardild",
}

m["gye"] = {
	canonicalName = "Gyem",
}

m["gyf"] = {
	canonicalName = "Gungabula",
}

m["gyg"] = {
	canonicalName = "Gbayi",
	family = "nic-ubg",
}

m["gyi"] = {
	canonicalName = "Gyele",
}

m["gyl"] = {
	canonicalName = "Gayil",
}

m["gym"] = {
	canonicalName = "Ngäbere",
}

m["gyn"] = {
	canonicalName = "Guyanese Creole English",
}

m["gyr"] = {
	canonicalName = "Guarayu",
}

m["gyy"] = {
	canonicalName = "Gunya",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["gza"] = {
	canonicalName = "Ganza",
}

m["gzi"] = {
	canonicalName = "Gazi",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["gzn"] = {
	canonicalName = "Gane",
	family = "poz-hce",
}

return m