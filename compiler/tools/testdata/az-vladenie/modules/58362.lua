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

m["taa"] = {
	canonicalName = "Lower Tanana",
	family = "ath",
}

m["tab"] = {
	canonicalName = "Tabasaran",
	otherNames = {"Tabassaran"},
	scripts = {"Cyrl"},
	family = "cau-lzg",
	translit_module = "tab-translit",
}

m["tac"] = {
	canonicalName = "Lowland Tarahumara",
	family = "azc-trc",
}

m["tad"] = {
	canonicalName = "Tause",
}

m["tae"] = {
	canonicalName = "Tariana",
	family = "awd",
}

m["taf"] = {
	canonicalName = "Tapirapé",
}

m["tag"] = {
	canonicalName = "Tagoi",
}

m["taj"] = {
	canonicalName = "Eastern Tamang",
}

m["tak"] = {
	canonicalName = "Tala",
}

m["tal"] = {
	canonicalName = "Tal",
}

m["tan"] = {
	canonicalName = "Tangale",
}

m["tao"] = {
	canonicalName = "Yami",
	otherNames = {"Tao"},
	scripts = {"Latn"},
	family = "phi",
}

m["tap"] = {
	canonicalName = "Taabwa",
}

m["taq"] = {
	canonicalName = "Tamasheq",
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
	ancestors = {"tmh"},
}

m["tar"] = {
	canonicalName = "Central Tarahumara",
	scripts = {"Latn"},
	family = "azc-trc",
}

m["tas"] = {
	canonicalName = "Tay Boi",
}

m["tau"] = {
	canonicalName = "Upper Tanana",
	family = "ath",
}

m["tav"] = {
	canonicalName = "Tatuyo",
	family = "sai-tuc",
}

m["taw"] = {
	canonicalName = "Tai",
}

m["tax"] = {
	canonicalName = "Tamki",
}

m["tay"] = {
	canonicalName = "Atayal",
	scripts = {"Latn"},
	family = "map",
}

m["taz"] = {
	canonicalName = "Tocho",
}

m["tba"] = {
	canonicalName = "Aikanã",
	family = "qfa-iso",
}

m["tbb"] = {
	canonicalName = "Tapeba",
}

m["tbc"] = {
	canonicalName = "Takia",
}

m["tbd"] = {
	canonicalName = "Kaki Ae",
	family = "poz-ocw",
}

m["tbe"] = {
	canonicalName = "Tanimbili",
	family = "poz-oce",
}

m["tbf"] = {
	canonicalName = "Mandara",
	family = "poz-ocw",
}

m["tbg"] = {
	canonicalName = "North Tairora",
}

m["tbh"] = {
	canonicalName = "Thurawal",
}

m["tbi"] = {
	canonicalName = "Gaam",
	family = "sdv",
}

m["tbj"] = {
	canonicalName = "Tiang",
	family = "poz-ocw",
}

m["tbk"] = {
	canonicalName = "Calamian Tagbanwa",
}

m["tbl"] = {
	canonicalName = "Tboli",
	family = "phi",
}

m["tbm"] = {
	canonicalName = "Tagbu",
}

m["tbn"] = {
	canonicalName = "Barro Negro Tunebo",
}

m["tbo"] = {
	canonicalName = "Tawala",
	family = "poz-ocw",
}

m["tbp"] = {
	canonicalName = "Taworta",
	otherNames = {"Diebroud", "Dabra"},
	family = "paa-lkp",
}

m["tbr"] = {
	canonicalName = "Tumtum",
	family = "qfa-kad",
}

m["tbs"] = {
	canonicalName = "Tanguat",
	family = "paa",
}

m["tbt"] = {
	canonicalName = "Kitembo",
	otherNames = {"Tembo"},
	family = "bnt",
}

m["tbu"] = {
	canonicalName = "Tubar",
	otherNames = {"Tubare"},
	family = "azc-trc",
}

m["tbv"] = {
	canonicalName = "Tobo",
}

m["tbw"] = {
	canonicalName = "Tagbanwa",
}

m["tbx"] = {
	canonicalName = "Kapin",
}

m["tby"] = {
	canonicalName = "Tabaru",
}

m["tbz"] = {
	canonicalName = "Ditammari",
}

m["tca"] = {
	canonicalName = "Ticuna",
	otherNames = {"Tikuna"},
	scripts = {"Latn"},
	family = "sai-tyu",
}

m["tcb"] = {
	canonicalName = "Tanacross",
	family = "ath",
}

m["tcc"] = {
	canonicalName = "Datooga",
	scripts = {"Latn"},
	family = "sdv",
}

m["tcd"] = {
	canonicalName = "Tafi",
}

m["tce"] = {
	canonicalName = "Southern Tutchone",
	family = "ath",
}

m["tcf"] = {
	canonicalName = "Malinaltepec Tlapanec",
}

m["tcg"] = {
	canonicalName = "Tamagario",
}

m["tch"] = {
	canonicalName = "Turks And Caicos Creole English",
}

m["tci"] = {
	canonicalName = "Wára",
}

m["tck"] = {
	canonicalName = "Tchitchege",
}

m["tcl"] = {
	canonicalName = "Taman (Burma)",
	otherNames = {"Taman", "Taman (Myanmar)"},
	scripts = {"Latn"},
	family = "sit",
}

m["tcm"] = {
	canonicalName = "Tanahmerah",
}

m["tco"] = {
	canonicalName = "Taungyo",
}

m["tcp"] = {
	canonicalName = "Tawr Chin",
	otherNames = {"Tawr"},
	family = "tbq-kuk",
}

m["tcq"] = {
	canonicalName = "Kaiy",
}

m["tcs"] = {
	canonicalName = "Torres Strait Creole",
	otherNames = {"Big Thap", "Blaikman", "Brokan", "Broken", "Broken English", "Cape York Creole", "Lockhart Creole", "Papuan Pidgin English", "Torres Strait Brokan", "Torres Strait Broken", "Torres Strait Pidgin", "Yumplatok"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["tct"] = {
	canonicalName = "T'en",
}

m["tcu"] = {
	canonicalName = "Southeastern Tarahumara",
	family = "azc-trc",
}

m["tcw"] = {
	canonicalName = "Tecpatlán Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tcx"] = {
	canonicalName = "Toda",
	family = "dra",
}

m["tcy"] = {
	canonicalName = "Tulu",
	scripts = {"Knda"},
	family = "dra",
}

m["tcz"] = {
	canonicalName = "Thado Chin",
	otherNames = {"Thado"},
	family = "tbq-kuk",
}

m["tda"] = {
	canonicalName = "Tagdal",
}

m["tdb"] = {
	canonicalName = "Panchpargania",
}

m["tdc"] = {
	canonicalName = "Emberá-Tadó",
}

m["tdd"] = {
	canonicalName = "Tai Nüa",
	scripts = {"Tale"},
	family = "tai-swe",
}

m["tde"] = {
	canonicalName = "Tiranige Diga Dogon",
	family = "qfa-dgn",
}

m["tdf"] = {
	canonicalName = "Talieng",
	otherNames = {"Taliang", "Tariang", "Kasseng"},
}

m["tdg"] = {
	canonicalName = "Western Tamang",
}

m["tdh"] = {
	canonicalName = "Thulung",
}

m["tdi"] = {
	canonicalName = "Tomadino",
	scripts = {"Latn"},
	family = "poz-btk",
}

m["tdj"] = {
	canonicalName = "Tajio",
}

m["tdk"] = {
	canonicalName = "Tambas",
}

m["tdl"] = {
	canonicalName = "Sur",
	otherNames = {"Tapshin"},
}

m["tdm"] = {
	canonicalName = "Taruma",
	otherNames = {"Taruamá"},
}

m["tdn"] = {
	canonicalName = "Tondano",
}

m["tdo"] = {
	canonicalName = "Teme",
}

m["tdq"] = {
	canonicalName = "Tita",
}

m["tdr"] = {
	canonicalName = "Todrah",
	family = "mkh",
}

m["tds"] = {
	canonicalName = "Doutai",
	otherNames = {"Taori"},
	family = "paa-lkp",
}

m["tdt"] = {
	canonicalName = "Tetun Dili",
	otherNames = {"Tetum Dili", "Tetun Prasa", "Tétum Praça", "Tetun-Dili", "Tetun-Prasa"},
	scripts = {"Latn"},
	family = "crp",
}

m["tdu"] = {
	canonicalName = "Tempasuk Dusun",
}

m["tdv"] = {
	canonicalName = "Toro",
}

m["tdy"] = {
	canonicalName = "Tadyawan",
}

m["tea"] = {
	canonicalName = "Temiar",
}

m["teb"] = {
	canonicalName = "Tetete",
	family = "sai-tuc",
}

m["tec"] = {
	canonicalName = "Terik",
	family = "sdv",
}

m["ted"] = {
	canonicalName = "Tepo Krumen",
}

m["tee"] = {
	canonicalName = "Huehuetla Tepehua",
}

m["tef"] = {
	canonicalName = "Teressa",
}

m["teg"] = {
	canonicalName = "Teke-Tege",
}

m["teh"] = {
	canonicalName = "Tehuelche",
	otherNames = {"Patagón", "Chon", "Chon Patagón", "Chon Patagon", "Aoniken", "Aonikenk", "Inaquen", "Aonek'o 'ajen"},
}

m["tei"] = {
	canonicalName = "Torricelli",
	family = "qfa-tor",
}

m["tek"] = {
	canonicalName = "Ibali Teke",
}

m["tem"] = {
	canonicalName = "Timne",
}

m["ten"] = {
	canonicalName = "Tama (Colombia)",
	otherNames = {"Tama"},
	family = "sai-tuc",
}

m["teo"] = {
	canonicalName = "Ateso",
	scripts = {"Latn"},
	family = "sdv",
}

m["tep"] = {
	canonicalName = "Tepecano",
	family = "azc",
}

m["teq"] = {
	canonicalName = "Temein",
	family = "sdv",
}

m["ter"] = {
	canonicalName = "Tereno",
	family = "awd",
}

m["tes"] = {
	canonicalName = "Tengger",
}

m["tet"] = {
	canonicalName = "Tetum",
	otherNames = {"Tetun"},
	scripts = {"Latn"},
	family = "plf",
}

m["teu"] = {
	canonicalName = "Soo",
}

m["tev"] = {
	canonicalName = "Teor",
	family = "plf",
}

m["tew"] = {
	canonicalName = "Tewa",
	otherNames = {"Tano", "Santa Clara Tewa", "San Ildefonso Tewa", "Tesuque Tewa", "Nambe Tewa", "Ohkay Owingeh", "Pojoaque"},
	scripts = {"Latn"},
	family = "nai-kta",
}

m["tex"] = {
	canonicalName = "Tennet",
	family = "sdv",
}

m["tey"] = {
	canonicalName = "Tulishi",
	scripts = {"Latn"},
	family = "qfa-kad",
}

m["tfi"] = {
	canonicalName = "Tofin Gbe",
}

m["tfn"] = {
	canonicalName = "Dena'ina",
	otherNames = {"Tanaina"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["tfo"] = {
	canonicalName = "Tefaro",
}

m["tfr"] = {
	canonicalName = "Teribe",
}

m["tft"] = {
	canonicalName = "Ternate",
}

m["tga"] = {
	canonicalName = "Sagalla",
}

m["tgb"] = {
	canonicalName = "Tobilung",
}

m["tgc"] = {
	canonicalName = "Tigak",
	family = "poz-ocw",
}

m["tgd"] = {
	canonicalName = "Ciwogai",
}

m["tge"] = {
	canonicalName = "Eastern Gorkha Tamang",
}

m["tgf"] = {
	canonicalName = "Chali",
	otherNames = {"Chalikha", "Chalipkha", "Tshali", "Tshalingpa"},
	family = "sit",
}

m["tgg"] = {
	canonicalName = "Tangga",
	family = "poz-ocw",
}

m["tgh"] = {
	canonicalName = "Tobagonian Creole English",
}

m["tgi"] = {
	canonicalName = "Lawunuia",
	family = "poz-ocw",
}

m["tgn"] = {
	canonicalName = "Tandaganon",
}

m["tgo"] = {
	canonicalName = "Sudest",
	family = "poz-ocw",
}

m["tgp"] = {
	canonicalName = "Tangoa",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["tgq"] = {
	canonicalName = "Tring",
	family = "poz-swa",
}

m["tgr"] = {
	canonicalName = "Tareng",
	family = "mkh",
}

m["tgs"] = {
	canonicalName = "Nume",
	family = "poz-vnc",
}

m["tgt"] = {
	canonicalName = "Central Tagbanwa",
	scripts = {"Tagb"},
	family = "phi",
}

m["tgu"] = {
	canonicalName = "Tanggu",
	family = "paa",
}

m["tgv"] = {
	canonicalName = "Tingui-Boto",
}

m["tgw"] = {
	canonicalName = "Tagwana Senoufo",
}

m["tgx"] = {
	canonicalName = "Tagish",
	family = "ath",
}

m["tgy"] = {
	canonicalName = "Togoyo",
}

m["thc"] = {
	canonicalName = "Tai Hang Tong",
}

m["thd"] = {
	canonicalName = "Kuuk Thaayorre",
	otherNames = {"Thaayorre", "Thayore"},
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["the"] = {
	canonicalName = "Chitwania Tharu",
}

m["thf"] = {
	canonicalName = "Thangmi",
}

m["thh"] = {
	canonicalName = "Northern Tarahumara",
	family = "azc-trc",
}

m["thi"] = {
	canonicalName = "Tai Long",
}

m["thk"] = {
	canonicalName = "Tharaka",
}

m["thl"] = {
	canonicalName = "Dangaura Tharu",
}

m["thm"] = {
	canonicalName = "Aheu",
	family = "mkh-vie",
}

m["thn"] = {
	canonicalName = "Thachanadan",
	family = "dra",
}

m["thp"] = {
	canonicalName = "Thompson",
}

m["thq"] = {
	canonicalName = "Kochila Tharu",
}

m["thr"] = {
	canonicalName = "Rana Tharu",
}

m["ths"] = {
	canonicalName = "Thakali",
}

m["tht"] = {
	canonicalName = "Tahltan",
	family = "ath",
}

m["thu"] = {
	canonicalName = "Thuri",
	family = "sdv",
}

m["thv"] = {
	canonicalName = "Tahaggart Tamahaq",
	otherNames = {"Tamahaq", "Tahaggart", "Ahaggar"},
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
	ancestors = {"tmh"},
}

m["thy"] = {
	canonicalName = "Tha",
}

m["thz"] = {
	canonicalName = "Tayart Tamajeq",
	otherNames = {"Air Tamajeq"},
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
}

m["tia"] = {
	canonicalName = "Tidikelt Tamazight",
	otherNames = {"Tidikelt"},
	family = "ber",
}

m["tic"] = {
	canonicalName = "Tira",
}

m["tif"] = {
	canonicalName = "Tifal",
}

m["tig"] = {
	canonicalName = "Tigre",
	scripts = {"Ethi"},
	family = "sem-eth",
	translit_module = "Ethi-translit",
}

m["tih"] = {
	canonicalName = "Timugon Murut",
}

m["tii"] = {
	canonicalName = "Tiene",
}

m["tij"] = {
	canonicalName = "Tilung",
}

m["tik"] = {
	canonicalName = "Tikar",
	family = "nic-bod",
}

m["til"] = {
	canonicalName = "Tillamook",
}

m["tim"] = {
	canonicalName = "Timbe",
}

m["tin"] = {
	canonicalName = "Tindi",
	family = "cau-ava",
}

m["tio"] = {
	canonicalName = "Teop",
	family = "poz-ocw",
}

m["tip"] = {
	canonicalName = "Trimuris",
}

m["tiq"] = {
	canonicalName = "Tiéfo",
}

m["tis"] = {
	canonicalName = "Masadiit Itneg",
}

m["tit"] = {
	canonicalName = "Tinigua",
}

m["tiu"] = {
	canonicalName = "Adasen",
}

m["tiv"] = {
	canonicalName = "Tivi",
	otherNames = {"Tiv"},
	scripts = {"Latn"},
	family = "nic-bod",
}

m["tiw"] = {
	canonicalName = "Tiwi",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["tix"] = {
	canonicalName = "Southern Tiwa",
	otherNames = {"Isleta", "Isleta Tiwa", "Isleta Pueblo", "Sandia", "Sandia Tiwa", "Sandia Pueblo"},
	scripts = {"Latn"},
	family = "nai-kta",
}

m["tiy"] = {
	canonicalName = "Tiruray",
	scripts = {"Latn"},
	family = "phi",
}

m["tiz"] = {
	canonicalName = "Tai Hongjin",
}

m["tja"] = {
	canonicalName = "Tajuasohn",
}

m["tjg"] = {
	canonicalName = "Tunjung",
	family = "poz",
}

m["tji"] = {
	canonicalName = "Northern Tujia",
}

m["tjm"] = {
	canonicalName = "Timucua",
}

m["tjn"] = {
	canonicalName = "Tonjon",
}

m["tjo"] = {
	canonicalName = "Temacine Tamazight",
	family = "ber",
}

m["tjs"] = {
	canonicalName = "Southern Tujia",
	scripts = {"Latn"},
	family = "tbq",
}

m["tju"] = {
	canonicalName = "Tjurruru",
	family = "aus-nga",
}

m["tjw"] = {
	canonicalName = "Chaap Wuurong",
	otherNames = {"Djabwurrung", "Djab Wurrung", "Tjapwurrung"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["tka"] = {
	canonicalName = "Truká",
}

m["tkb"] = {
	canonicalName = "Buksa",
}

m["tkd"] = {
	canonicalName = "Tukudede",
	scripts = {"Latn"},
	family = "plf",
}

m["tke"] = {
	canonicalName = "Takwane",
}

m["tkf"] = {
	canonicalName = "Tukumanféd",
}

m["tkl"] = {
	canonicalName = "Tokelauan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["tkm"] = {
	canonicalName = "Takelma",
}

m["tkn"] = {
	canonicalName = "Toku-No-Shima",
	family = "jpx-ryu",
}

m["tkp"] = {
	canonicalName = "Tikopia",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["tkq"] = {
	canonicalName = "Tee",
	family = "nic-bco",
}

m["tkr"] = {
	canonicalName = "Tsakhur",
	otherNames = {"Caxur", "Tsaxur"},
	scripts = {"Cyrl"},
	family = "cau-lzg",
}

m["tks"] = {
	canonicalName = "Takestani",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["tkt"] = {
	canonicalName = "Kathoriya Tharu",
}

m["tku"] = {
	canonicalName = "Upper Necaxa Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tkv"] = {
	canonicalName = "Mur Pano",
	otherNames = {"Pano"},
}

m["tkw"] = {
	canonicalName = "Teanu",
	scripts = {"Latn"},
	family = "poz-oce",
}

m["tkx"] = {
	canonicalName = "Tangko",
}

m["tkz"] = {
	canonicalName = "Takua",
	family = "mkh",
}

m["tla"] = {
	canonicalName = "Southwestern Tepehuan",
	scripts = {"Latn"},
	family = "azc",
}

m["tlb"] = {
	canonicalName = "Tobelo",
}

m["tlc"] = {
	canonicalName = "Misantla Totonac",
	otherNames = {"Yecuatla Totonac"},
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tld"] = {
	canonicalName = "Talaud",
}

m["tlf"] = {
	canonicalName = "Telefol",
}

m["tlg"] = {
	canonicalName = "Tofanma",
}

m["tlh"] = {
	canonicalName = "Klingon",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["tli"] = {
	canonicalName = "Tlingit",
	scripts = {"Latn", "Cyrl"},
	family = "xnd",
}

m["tlj"] = {
	canonicalName = "Talinga-Bwisi",
}

m["tlk"] = {
	canonicalName = "Taloki",
}

m["tll"] = {
	canonicalName = "Tetela",
}

m["tlm"] = {
	canonicalName = "Tolomako",
	family = "poz-vnc",
}

m["tln"] = {
	canonicalName = "Talondo'",
}

m["tlo"] = {
	canonicalName = "Talodi",
}

m["tlp"] = {
	canonicalName = "Filomena Mata-Coahuitlán Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tlq"] = {
	canonicalName = "Tai Loi",
	family = "aav",
}

m["tlr"] = {
	canonicalName = "Talise",
	family = "poz-sls",
}

m["tls"] = {
	canonicalName = "Tambotalo",
	family = "poz-vnc",
}

m["tlt"] = {
	canonicalName = "Teluti",
	otherNames = {"Sou Nama"},
}

m["tlu"] = {
	canonicalName = "Tulehu",
	family = "plf",
}

m["tlv"] = {
	canonicalName = "Taliabu",
	otherNames = {"Taliabu", "Soboyo"},
	scripts = {"Latn"},
	family = "plf",
}

m["tlx"] = {
	canonicalName = "Khehek",
	family = "poz-aay",
}

m["tly"] = {
	canonicalName = "Talysh",
	otherNames = {"Talyshi", "Talishi", "Taleshi", "Tolashi", "Asalemi", "Anbarani"},
	scripts = {"Latn", "Cyrl", "fa-Arab"},
	family = "ira",
	ancestors = {"ira-azr"},
}

m["tma"] = {
	canonicalName = "Tama (Chad)",
	otherNames = {"Tama"},
	family = "sdv",
}

m["tmb"] = {
	canonicalName = "Avava",
	family = "poz-vnc",
}

m["tmc"] = {
	canonicalName = "Tumak",
}

m["tmd"] = {
	canonicalName = "Haruai",
}

m["tme"] = {
	canonicalName = "Tremembé",
}

m["tmf"] = {
	canonicalName = "Toba-Maskoy",
}

m["tmg"] = {
	canonicalName = "Ternateño",
}

m["tmh"] = {
	canonicalName = "Tuareg",
	otherNames = {"Tamashek", "Tamahaq", "Tamajaq", "Tamasheq"},
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
}

m["tmi"] = {
	canonicalName = "Tutuba",
	family = "poz-vnc",
}

m["tmj"] = {
	canonicalName = "Samarokena",
}

m["tmk"] = {
	canonicalName = "Northwestern Tamang",
}

m["tml"] = {
	canonicalName = "Tamnim Citak",
}

m["tmm"] = {
	canonicalName = "Tai Thanh",
}

m["tmn"] = {
	canonicalName = "Taman (Indonesia)",
	otherNames = {"Taman"},
	scripts = {"Latn"},
	family = "poz",
}

m["tmo"] = {
	canonicalName = "Temoq",
}

m["tmp"] = {
	canonicalName = "Tai Mène",
}

m["tmq"] = {
	canonicalName = "Tumleo",
	family = "poz-ocw",
}

m["tms"] = {
	canonicalName = "Tima",
}

m["tmt"] = {
	canonicalName = "Tasmate",
	family = "poz-vnc",
}

m["tmu"] = {
	canonicalName = "Iau",
	otherNames = {"Turu"},
	family = "paa-lkp",
}

m["tmv"] = {
	canonicalName = "Motembo",
	otherNames = {"Tembo"},
	family = "bnt",
}

m["tmy"] = {
	canonicalName = "Tami",
}

m["tmz"] = {
	canonicalName = "Tamanaku",
	family = "sai-car",
}

m["tna"] = {
	canonicalName = "Tacana",
	scripts = {"Latn"},
	family = "sai-tac",
}

m["tnb"] = {
	canonicalName = "Western Tunebo",
}

m["tnc"] = {
	canonicalName = "Tanimuca-Retuarã",
	family = "sai-tuc",
}

m["tnd"] = {
	canonicalName = "Angosturas Tunebo",
}

m["tne"] = {
	canonicalName = "Tinoc Kallahan",
}

m["tng"] = {
	canonicalName = "Tobanga",
}

m["tnh"] = {
	canonicalName = "Maiani",
}

m["tni"] = {
	canonicalName = "Tandia",
	family = "poz-hce",
}

m["tnk"] = {
	canonicalName = "Kwamera",
}

m["tnl"] = {
	canonicalName = "Lenakel",
}

m["tnm"] = {
	canonicalName = "Tabla",
}

m["tnn"] = {
	canonicalName = "North Tanna",
}

m["tno"] = {
	canonicalName = "Toromono",
	family = "sai-tac",
}

m["tnp"] = {
	canonicalName = "Whitesands",
}

m["tnq"] = {
	canonicalName = "Taino",
	otherNames = {"Taíno"},
	scripts = {"Latn"},
	family = "awd",
}

m["tnr"] = {
	canonicalName = "Bedik",
}

m["tns"] = {
	canonicalName = "Tenis",
	family = "poz-ocw",
}

m["tnt"] = {
	canonicalName = "Tontemboan",
	scripts = {"Latn"},
	family = "phi",
}

m["tnu"] = {
	canonicalName = "Tay Khang",
}

m["tnv"] = {
	canonicalName = "Tangchangya",
	scripts = {"Cakm"},
	family = "inc",
	ancestors = {"pka"},
}

m["tnw"] = {
	canonicalName = "Tonsawang",
}

m["tnx"] = {
	canonicalName = "Tanema",
	family = "poz-oce",
}

m["tny"] = {
	canonicalName = "Tongwe",
}

m["tnz"] = {
	canonicalName = "Ten'edn",
	otherNames = {"Tonga"},
	scripts = {"Latn"},
	family = "aav",
}

m["tob"] = {
	canonicalName = "Toba",
	otherNames = {"Chaco Sur", "Namqom", "Qom", "Toba Qom"},
	scripts = {"Latn"},
	family = "sai-guc",
}

m["toc"] = {
	canonicalName = "Coyutla Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tod"] = {
	canonicalName = "Toma",
}

m["tof"] = {
	canonicalName = "Gizrra",
}

m["tog"] = {
	canonicalName = "Tonga (Malawi)",
	otherNames = {"Kitonga", "Chitonga", "Siska", "Sisya", "Tonga", "Western Nyasa"},
	scripts = {"Latn"},
	family = "bnt",
}

m["toh"] = {
	canonicalName = "Tonga (Mozambique)",
	otherNames = {"Gitonga", "Tonga"},
}

m["toi"] = {
	canonicalName = "Tonga (Zambia)",
	otherNames = {"Tonga", "Chitonga", "Plateau Tonga", "Zambezi"},
}

m["toj"] = {
	canonicalName = "Tojolabal",
}

m["tol"] = {
	canonicalName = "Tolowa",
	otherNames = {"Smith River", "Smith River Tolowa"},
	scripts = {"Latn"},
	family = "ath",
}

m["tom"] = {
	canonicalName = "Tombulu",
}

m["too"] = {
	canonicalName = "Xicotepec De Juárez Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["top"] = {
	canonicalName = "Papantla Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["toq"] = {
	canonicalName = "Toposa",
}

m["tor"] = {
	canonicalName = "Togbo-Vara Banda",
}

m["tos"] = {
	canonicalName = "Highland Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tou"] = {
	canonicalName = "Tho",
	family = "mkh-vie",
}

m["tov"] = {
	canonicalName = "Upper Taromi",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["tow"] = {
	canonicalName = "Jemez",
	otherNames = {"Towa"},
	scripts = {"Latn"},
	family = "nai-kta",
}

m["tox"] = {
	canonicalName = "Tobian",
	family = "poz-mic",
}

m["toy"] = {
	canonicalName = "Topoiyo",
}

m["toz"] = {
	canonicalName = "To",
}

m["tpa"] = {
	canonicalName = "Taupota",
	family = "poz-ocw",
}

m["tpc"] = {
	canonicalName = "Azoyú Me'phaa",
}

m["tpe"] = {
	canonicalName = "Tippera",
}

m["tpf"] = {
	canonicalName = "Tarpia",
	family = "poz-ocw",
}

m["tpg"] = {
	canonicalName = "Kula",
}

m["tpi"] = {
	canonicalName = "Tok Pisin",
	otherNames = {"Melanesian Pidgin English", "Neo-Melanesian", "New Guinea Pidgin"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["tpj"] = {
	canonicalName = "Tapieté",
}

m["tpk"] = {
	canonicalName = "Tupinikin",
}

m["tpl"] = {
	canonicalName = "Tlacoapa Me'phaa",
}

m["tpm"] = {
	canonicalName = "Tampulma",
}

m["tpn"] = {
	canonicalName = "Tupinambá",
	scripts = {"Latn"},
	family = "tup",
}

m["tpo"] = {
	canonicalName = "Tai Pao",
}

m["tpp"] = {
	canonicalName = "Pisaflores Tepehua",
}

m["tpq"] = {
	canonicalName = "Tukpa",
}

m["tpr"] = {
	canonicalName = "Tuparí",
}

m["tpt"] = {
	canonicalName = "Tlachichilco Tepehua",
}

m["tpu"] = {
	canonicalName = "Tampuan",
}

m["tpv"] = {
	canonicalName = "Tanapag",
	family = "poz-mic",
}

m["tpw"] = {
	canonicalName = "Old Tupi",
	scripts = {"Latn"},
	family = "tup",
}

m["tpx"] = {
	canonicalName = "Acatepec Me'phaa",
}

m["tpy"] = {
	canonicalName = "Trumai",
}

m["tpz"] = {
	canonicalName = "Tinputz",
	family = "poz-ocw",
}

m["tqb"] = {
	canonicalName = "Tembé",
}

m["tql"] = {
	canonicalName = "Lehali",
}

m["tqm"] = {
	canonicalName = "Turumsa",
}

m["tqn"] = {
	canonicalName = "Tenino",
	family = "nai-shp",
}

m["tqo"] = {
	canonicalName = "Toaripi",
}

m["tqp"] = {
	canonicalName = "Tomoip",
	family = "poz-ocw",
}

m["tqq"] = {
	canonicalName = "Tunni",
	family = "cus",
}

m["tqr"] = {
	canonicalName = "Torona",
}

m["tqt"] = {
	canonicalName = "Western Totonac",
	scripts = {"Latn"},
	family = "nai-ttn",
}

m["tqu"] = {
	canonicalName = "Touo",
}

m["tqw"] = {
	canonicalName = "Tonkawa",
}

m["tra"] = {
	canonicalName = "Tirahi",
}

m["trb"] = {
	canonicalName = "Terebu",
	family = "poz-ocw",
}

m["trc"] = {
	canonicalName = "Copala Triqui",
	family = "omq-tri",
}

m["trd"] = {
	canonicalName = "Turi",
	family = "mun",
}

m["tre"] = {
	canonicalName = "East Tarangan",
}

m["trf"] = {
	canonicalName = "Trinidadian Creole English",
}

m["trg"] = {
	canonicalName = "Lishán Didán",
}

m["trh"] = {
	canonicalName = "Turaka",
}

m["tri"] = {
	canonicalName = "Trió",
	family = "sai-car",
}

m["trj"] = {
	canonicalName = "Toram",
}

m["trl"] = {
	canonicalName = "Traveller Scottish",
}

m["trm"] = {
	canonicalName = "Tregami",
	family = "iir-nur",
}

m["trn"] = {
	canonicalName = "Trinitario",
	otherNames = {"Trinitario Moxos", "Moxo", "Moxos", "Mojo", "Moxa"},
	family = "awd",
}

m["tro"] = {
	canonicalName = "Tarao",
	otherNames = {"Tarao Naga", "Taraotrong", "Tarau"},
	scripts = {"Latn"},
	family = "tbq",
}

m["trp"] = {
	canonicalName = "Kokborok",
	family = "tbq",
}

m["trq"] = {
	canonicalName = "San Martín Itunyoso Triqui",
	family = "omq-tri",
}

m["trr"] = {
	canonicalName = "Taushiro",
}

m["trs"] = {
	canonicalName = "Chicahuaxtla Triqui",
	family = "omq-tri",
}

m["trt"] = {
	canonicalName = "Tunggare",
}

m["tru"] = {
	canonicalName = "Turoyo",
	scripts = {"Syrc", "Latn"},
	family = "sem-ara",
}

m["trv"] = {
	canonicalName = "Taroko",
	otherNames = {"Seediq"},
	scripts = {"Latn"},
	family = "map",
}

m["trw"] = {
	canonicalName = "Torwali",
	scripts = {"ur-Arab"},
	family = "inc-dar",
}

m["trx"] = {
	canonicalName = "Tringgus",
	otherNames = {"Tringus", "Tringgus-Sembaan Bidayuh"},
	family = "day",
}

m["try"] = {
	canonicalName = "Turung",
}

m["trz"] = {
	canonicalName = "Torá",
}

m["tsa"] = {
	canonicalName = "Tsaangi",
}

m["tsb"] = {
	canonicalName = "Tsamai",
	family = "cus",
}

m["tsc"] = {
	canonicalName = "Tswa",
}

m["tsd"] = {
	canonicalName = "Tsakonian",
	family = "grk",
	ancestors = {"grc"},
}

m["tse"] = {
	canonicalName = "Tunisian Sign Language",
	family = "sgn",
}

m["tsf"] = {
	canonicalName = "Southwestern Tamang",
}

m["tsg"] = {
	canonicalName = "Tausug",
	scripts = {"Latn"},
	family = "phi",
}

m["tsh"] = {
	canonicalName = "Tsuvan",
}

m["tsi"] = {
	canonicalName = "Tsimshian",
}

m["tsj"] = {
	canonicalName = "Tshangla",
	otherNames = {"Sharchop"},
	scripts = {"Latn", "Deva", "Tibt"},
	family = "sit",
}

m["tsl"] = {
	canonicalName = "Ts'ün-Lao",
}

m["tsm"] = {
	canonicalName = "Turkish Sign Language",
	family = "sgn",
}

m["tsp"] = {
	canonicalName = "Northern Toussian",
}

m["tsq"] = {
	canonicalName = "Thai Sign Language",
	family = "sgn",
}

m["tsr"] = {
	canonicalName = "Akei",
	family = "poz-vnc",
}

m["tss"] = {
	canonicalName = "Taiwan Sign Language",
	family = "sgn-jsl",
}

m["tsu"] = {
	canonicalName = "Tsou",
	scripts = {"Latn"},
	family = "map",
}

m["tsv"] = {
	canonicalName = "Tsogo",
}

m["tsw"] = {
	canonicalName = "Tsishingini",
}

m["tsx"] = {
	canonicalName = "Mubami",
}

m["tsy"] = {
	canonicalName = "Tebul Sign Language",
	family = "sgn",
}

m["tta"] = {
	canonicalName = "Tutelo",
	family = "sio",
}

m["ttb"] = {
	canonicalName = "Gaa",
}

m["ttc"] = {
	canonicalName = "Tektiteko",
}

m["ttd"] = {
	canonicalName = "Tauade",
}

m["tte"] = {
	canonicalName = "Bwanabwana",
	otherNames = {"Tubetube"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["ttf"] = {
	canonicalName = "Tuotomb",
	family = "nic-bod",
}

m["ttg"] = {
	canonicalName = "Tutong",
	family = "poz-swa",
}

m["tth"] = {
	canonicalName = "Upper Ta'oih",
	family = "mkh",
}

m["tti"] = {
	canonicalName = "Tobati",
	family = "poz-ocw",
}

m["ttj"] = {
	canonicalName = "Tooro",
}

m["ttk"] = {
	canonicalName = "Totoro",
}

m["ttl"] = {
	canonicalName = "Totela",
}

m["ttm"] = {
	canonicalName = "Northern Tutchone",
	family = "ath",
}

m["ttn"] = {
	canonicalName = "Towei",
}

m["tto"] = {
	canonicalName = "Lower Ta'oih",
	family = "mkh",
}

m["ttp"] = {
	canonicalName = "Tombelala",
}

m["ttq"] = {
	canonicalName = "Tawallammat Tamajaq",
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
	ancestors = {"tmh"},
}

m["ttr"] = {
	canonicalName = "Tera",
}

m["tts"] = {
	canonicalName = "Isan",
	otherNames = {"Isanese", "Isaan", "Issan"},
	scripts = {"Thai"},
	family = "tai-swe",
}

m["ttt"] = {
	canonicalName = "Tat",
	otherNames = {"Caucasian Tat", "Muslim Tat", "Armeno-Tat"},
	scripts = {"Cyrl", "Latn", "Armn", "fa-Arab"},
	family = "ira",
	ancestors = {"fa"},
	wikipedia_article = "Tat language (Caucasus)",
}

m["ttu"] = {
	canonicalName = "Torau",
	family = "poz-ocw",
}

m["ttv"] = {
	canonicalName = "Titan",
	family = "poz-aay",
}

m["ttw"] = {
	canonicalName = "Long Wat",
	otherNames = {"Tutoh"},
	family = "poz-swa",
}

m["tty"] = {
	canonicalName = "Sikaritai",
}

m["ttz"] = {
	canonicalName = "Tsum",
}

m["tua"] = {
	canonicalName = "Wiarumus",
	family = "qfa-tor",
}

m["tub"] = {
	canonicalName = "Tübatulabal",
	family = "azc",
}

m["tuc"] = {
	canonicalName = "Mutu",
	family = "poz-ocw",
}

m["tud"] = {
	canonicalName = "Tuxá",
}

m["tue"] = {
	canonicalName = "Tuyuca",
	family = "sai-tuc",
}

m["tuf"] = {
	canonicalName = "Central Tunebo",
}

m["tug"] = {
	canonicalName = "Tunia",
}

m["tuh"] = {
	canonicalName = "Taulil",
}

m["tui"] = {
	canonicalName = "Tupuri",
	family = "alv",
}

m["tuj"] = {
	canonicalName = "Tugutil",
}

m["tul"] = {
	canonicalName = "Tula",
}

m["tum"] = {
	canonicalName = "Tumbuka",
	scripts = {"Latn"},
	family = "bnt",
}

m["tun"] = {
	canonicalName = "Tunica",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["tuo"] = {
	canonicalName = "Tucano",
	family = "sai-tuc",
}

m["tuq"] = {
	canonicalName = "Tedaga",
	otherNames = {"Teda"},
	family = "ssa-sah",
}

m["tus"] = {
	canonicalName = "Tuscarora",
	scripts = {"Latinx"},
	family = "iro",
}

m["tuu"] = {
	canonicalName = "Tututni",
	family = "ath-pco",
}

m["tuv"] = {
	canonicalName = "Turkana",
	family = "sdv",
}

m["tux"] = {
	canonicalName = "Tuxináwa",
	family = "sai-pan",
}

m["tuy"] = {
	canonicalName = "Tugen",
	family = "sdv",
}

m["tuz"] = {
	canonicalName = "Turka",
	family = "nic-gur",
}

m["tva"] = {
	canonicalName = "Vaghua",
	family = "poz-ocw",
}

m["tvd"] = {
	canonicalName = "Tsuvadi",
}

m["tve"] = {
	canonicalName = "Te'un",
	family = "plf",
}

m["tvk"] = {
	canonicalName = "Southeast Ambrym",
	family = "poz-vnc",
}

m["tvl"] = {
	canonicalName = "Tuvaluan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["tvm"] = {
	canonicalName = "Tela-Masbuar",
}

m["tvn"] = {
	canonicalName = "Tavoyan",
}

m["tvo"] = {
	canonicalName = "Tidore",
}

m["tvs"] = {
	canonicalName = "Taveta",
}

m["tvt"] = {
	canonicalName = "Tutsa Naga",
}

m["tvu"] = {
	canonicalName = "Tunen",
	otherNames = {"Tunen-Aling'a"},
	family = "nic-bod",
}

m["tvw"] = {
	canonicalName = "Sedoa",
}

m["tvy"] = {
	canonicalName = "Timor Pidgin",
}

m["twa"] = {
	canonicalName = "Twana",
}

m["twb"] = {
	canonicalName = "Western Tawbuid",
}

m["twc"] = {
	canonicalName = "Teshenawa",
}

m["twe"] = {
	canonicalName = "Teiwa",
	otherNames = {"Tewa"},
	scripts = {"Latn"},
	family = "ngf",
}

m["twf"] = {
	canonicalName = "Taos",
	otherNames = {"Northern Tiwa"},
	scripts = {"Latn"},
	family = "nai-kta",
}

m["twg"] = {
	canonicalName = "Tereweng",
}

m["twh"] = {
	canonicalName = "Tai Dón",
}

m["twl"] = {
	canonicalName = "Tawara",
}

m["twm"] = {
	canonicalName = "Tawang Monpa",
}

m["twn"] = {
	canonicalName = "Twendi",
}

m["two"] = {
	canonicalName = "Tswapong",
}

m["twp"] = {
	canonicalName = "Ere",
	family = "poz-aay",
}

m["twq"] = {
	canonicalName = "Tasawaq",
}

m["twr"] = {
	canonicalName = "Southwestern Tarahumara",
	family = "azc-trc",
}

m["twt"] = {
	canonicalName = "Turiwára",
}

m["twu"] = {
	canonicalName = "Termanu",
	family = "plf",
}

m["tww"] = {
	canonicalName = "Tuwari",
}

m["twx"] = {
	canonicalName = "Tewe",
}

m["twy"] = {
	canonicalName = "Tawoyan",
	otherNames = {"Taboyan"},
}

m["txa"] = {
	canonicalName = "Tombonuo",
}

m["txb"] = {
	canonicalName = "Tocharian B",
	otherNames = {"West Tocharian", "Kuchean"},
	family = "ine-toc",
}

m["txc"] = {
	canonicalName = "Tsetsaut",
	family = "ath",
}

m["txe"] = {
	canonicalName = "Totoli",
	scripts = {"Latn"},
	family = "poz-tot",
}

m["txg"] = {
	canonicalName = "Tangut",
	scripts = {"Tang"},
	family = "sit-qia",
}

m["txj"] = {
	canonicalName = "Tarjumo",
	scripts = {"Latn", "Arab"},
	family = "ssa-sah",
}

m["txh"] = {
	canonicalName = "Thracian",
	scripts = {"Grek"},
	family = "ine",
}

m["txi"] = {
	canonicalName = "Ikpeng",
	family = "sai-car",
}

m["txm"] = {
	canonicalName = "Tomini",
}

m["txn"] = {
	canonicalName = "West Tarangan",
}

m["txo"] = {
	canonicalName = "Toto",
}

m["txq"] = {
	canonicalName = "Tii",
	family = "plf",
}

m["txr"] = {
	canonicalName = "Tartessian",
}

m["txs"] = {
	canonicalName = "Tonsea",
}

m["txt"] = {
	canonicalName = "Citak",
}

m["txu"] = {
	canonicalName = "Kayapó",
}

m["txx"] = {
	canonicalName = "Tatana",
}

m["tya"] = {
	canonicalName = "Tauya",
}

m["tye"] = {
	canonicalName = "Kyenga",
}

m["tyh"] = {
	canonicalName = "O'du",
	family = "mkh",
}

m["tyi"] = {
	canonicalName = "Teke-Tsaayi",
}

m["tyj"] = {
	canonicalName = "Tai Do",
}

m["tyl"] = {
	canonicalName = "Thu Lao",
}

m["tyn"] = {
	canonicalName = "Kombai",
}

m["typ"] = {
	canonicalName = "Thaypan",
}

m["tyr"] = {
	canonicalName = "Tai Daeng",
}

m["tys"] = {
	canonicalName = "Tày Sa Pa",
}

m["tyt"] = {
	canonicalName = "Tày Tac",
}

m["tyu"] = {
	canonicalName = "Kua",
}

m["tyv"] = {
	canonicalName = "Tuvan",
	otherNames = {"Tyvan"},
	scripts = {"Cyrl"},
	family = "trk",
	translit_module = "tyv-translit",
}

m["tyx"] = {
	canonicalName = "Teke-Tyee",
}

m["tyz"] = {
	canonicalName = "Tày",
}

m["tza"] = {
	canonicalName = "Tanzanian Sign Language",
	family = "sgn",
}

m["tzh"] = {
	canonicalName = "Tzeltal",
}

m["tzj"] = {
	canonicalName = "Tz'utujil",
	otherNames = {"Tzutujil"},
	scripts = {"Latn"},
	family = "myn",
}

m["tzl"] = {
	canonicalName = "Talossan",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
	sort_key = {
		from = {"[àáâäå]", "ç", "ð",   "[ëèéê]", "[ìíîï]", "ñ", "[öòóô]", "ß", "[üùúû]", "þ"},
		to   = {"a",       "c", "d", "e",      "i",      "n", "o",      "s",  "u", "z"}} ,  -- the copyright sign is used to guarantee that ð and þ will always be sorted after all other words with respectively d and z
}

m["tzm"] = {
	canonicalName = "Central Atlas Tamazight",
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
	translit_module = "ber-translit",
}

m["tzn"] = {
	canonicalName = "Tugun",
}

m["tzo"] = {
	canonicalName = "Tzotzil",
	scripts = {"Latn"},
	family = "myn",
}

m["tzx"] = {
	canonicalName = "Tabriak",
	otherNames = {"Karawari"},
	scripts = {"Latn"},
}

return m