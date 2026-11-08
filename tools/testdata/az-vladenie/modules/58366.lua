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

m["xaa"] = {
	canonicalName = "Andalusian Arabic",
	otherNames = {"Andalusi Arabic", "Moorish Arabic", "Spanish Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["xab"] = {
	canonicalName = "Sambe",
	family = "nic-bco",
}

m["xac"] = {
	canonicalName = "Kachari",
	family = "tbq",
}

m["xad"] = {
	canonicalName = "Adai",
}

m["xae"] = {
	canonicalName = "Aequian",
	family = "itc",
}

m["xag"] = {
	canonicalName = "Aghwan",
	otherNames = {"Caucasian Albanian", "Old Udi"},
	scripts = {"Aghb"},
	family = "cau-lzg",
}

m["xai"] = {
	canonicalName = "Kaimbé",
}

m["xaj"] = {
	canonicalName = "Ararandewára",
}

m["xak"] = {
	canonicalName = "Maku",
	otherNames = {"Mako", "Máku", "Mácu", "Macú", "Macu", "Máko", "Maku-Auari"},
	scripts = {"Latn"},
}

m["xal"] = {
	canonicalName = "Kalmyk",
	otherNames = {"Oirat", "Modern Oirat"},
	scripts = {"Cyrl"},
	family = "xgn",
	ancestors = {"xwo"},
	translit_module = "xal-translit",
}

m["xam"] = {
	canonicalName = "ǀXam",
	otherNames = {"ǀKham"},
	scripts = {"Latn"},
	family = "qfa-tuu",
}

m["xan"] = {
	canonicalName = "Xamtanga",
	family = "cus",
}

m["xao"] = {
	canonicalName = "Khao",
	family = "mkh",
}

m["xap"] = {
	canonicalName = "Apalachee",
	family = "nai-mus",
}

m["xaq"] = {
	canonicalName = "Aquitanian",
	scripts = {"Latn"},
	family = "euq",
}

m["xar"] = {
	canonicalName = "Karami",
}

m["xas"] = {
	canonicalName = "Kamassian",
	scripts = {"Cyrl"},
	family = "syd",
}

m["xat"] = {
	canonicalName = "Katawixi",
}

m["xau"] = {
	canonicalName = "Kauwera",
}

m["xav"] = {
	canonicalName = "Xavante",
	scripts = {"Latn"},
	family = "sai-jee",
}

m["xaw"] = {
	canonicalName = "Kawaiisu",
	scripts = {"Latn"},
	family = "azc-num",
}

m["xay"] = {
	canonicalName = "Kayan Mahakam",
}

m["xbb"] = {
	canonicalName = "Lower Burdekin",
}

m["xbc"] = {
	canonicalName = "Bactrian",
	otherNames = {"Greco-Bactrian", "Kushan", "Kushano-Bactrian"},
	scripts = {"Grek", "Mani"},
	family = "ira",
	entry_name = {
		from = {"Þ", "þ"},
		to   = {"Ϸ", "ϸ"}},
	translit_module = "xbc-translit",
}

m["xbd"] = {
	canonicalName = "Bindal",
}

m["xbe"] = {
	canonicalName = "Bigambal",
}

m["xbg"] = {
	canonicalName = "Bunganditj",
}

m["xbi"] = {
	canonicalName = "Kombio",
	family = "qfa-tor",
}

m["xbj"] = {
	canonicalName = "Birrpayi",
}

m["xbm"] = {
	canonicalName = "Middle Breton",
	scripts = {"Latn"},
	family = "cel-bry",
	ancestors = {"obt"},
}

m["xbn"] = {
	canonicalName = "Kenaboi",
}

m["xbo"] = {
	canonicalName = "Bulgar",
	otherNames = {"Bolğar", "Bulghar", "Bolghar", "Bolgarian", "Bolgar"},
	scripts = {"Grek"},
	family = "trk-ogr",
}

m["xbp"] = {
	canonicalName = "Bibbulman",
}

m["xbr"] = {
	canonicalName = "Kambera",
	otherNames = {"East Sumbanese", "Sumbanese"},
	scripts = {"Latn"},
	family = "plf",
}

m["xbw"] = {
	canonicalName = "Kambiwá",
}

m["xby"] = {
	canonicalName = "Butchulla",
	otherNames = {"Badjala"}, -- contrast gbw
}

m["xcb"] = {
	canonicalName = "Cumbric",
	family = "cel-bry",
}

m["xcc"] = {
	canonicalName = "Camunic",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["xce"] = {
	canonicalName = "Celtiberian",
	family = "cel",
}

m["xch"] = {
	canonicalName = "Chemakum",
	family = "chi",
}

m["xcl"] = {
	canonicalName = "Old Armenian",
	otherNames = {"Classical Armenian", "Liturgical Armenian", "Grabar"},
	scripts = {"Armn"},
	family = "hyx",
	translit_module = "Armn-translit",
	entry_name = {
		from = {"՞", "՜", "՛", "՟", "և"},
		to   = {"", "", "", "", "եւ"}} ,
}

m["xcm"] = {
	canonicalName = "Comecrudo",
}

m["xcn"] = {
	canonicalName = "Cotoname",
}

m["xco"] = {
	canonicalName = "Chorasmian",
	otherNames = {"Khwarezmian"},
	scripts = {"fa-Arab"}, -- Khwarezmian script not in Unicode yet
	family = "ira",
}

m["xcr"] = {
	canonicalName = "Carian",
	scripts = {"Cari"},
	family = "ine-ana",
}

m["xct"] = {
	canonicalName = "Classical Tibetan",
	family = "sit",
	ancestors = {"otb"},
}

m["xcu"] = {
	canonicalName = "Curonian",
	family = "bat",
}

m["xcv"] = {
	canonicalName = "Chuvantsy",
}

m["xcw"] = {
	canonicalName = "Coahuilteco",
}

m["xcy"] = {
	canonicalName = "Cayuse",
}

m["xda"] = {
	canonicalName = "Darkinjung",
	scripts = {"Latn"},
	family = "aus-yuk",
}

m["xdc"] = {
	canonicalName = "Dacian",
	scripts = {"Latn"},
	family = "ine",
}

m["xdk"] = {
	canonicalName = "Dharug",
	otherNames = {"Darug", "Dharruk", "Dharuk", "Eora", "Iora", "Iyora", "Sydney"},
	scripts = {"Latn"},
	family = "aus-yuk",
}

m["xdm"] = {
	canonicalName = "Edomite",
	scripts = {"Phnx"},
	family = "sem-can",
}

m["xdy"] = {
	canonicalName = "Malayic Dayak",
}

m["xeb"] = {
	canonicalName = "Eblaite",
	scripts = {"Xsux"},
	family = "sem-eas",
}

m["xed"] = {
	canonicalName = "Hdi",
}

m["xeg"] = {
	canonicalName = "ǁXegwi",
	scripts = {"Latn"},
	family = "qfa-tuu",
}

m["xel"] = {
	canonicalName = "Kelo",
	family = "sdv",
}

m["xem"] = {
	canonicalName = "Kembayan",
}

m["xep"] = {
	canonicalName = "Epi-Olmec",
}

m["xer"] = {
	canonicalName = "Xerénte",
	otherNames = {"Xerente", "Cherente", "Sherenté"},
	scripts = {"Latn"},
	family = "sai-mje",
}

m["xes"] = {
	canonicalName = "Kesawai",
}

m["xet"] = {
	canonicalName = "Xetá",
}

m["xeu"] = {
	canonicalName = "Keoru-Ahia",
}

m["xfa"] = {
	canonicalName = "Faliscan",
	scripts = {"Ital", "Latn"},
	family = "itc",
	translit_module = "Ital-translit",
	entry_name = {
		from = {"[ĀĂ]", "[āă]", "[ĒĔ]", "[ēĕë]", "[ĪĬÏ]", "[īĭï]", "[ŌŎ]", "[ōŏ]", "[ŪŬÜ]", "[ūŭü]", "Ȳ", "ȳ", MACRON, BREVE, DIAER},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}},
}

m["xga"] = {
	canonicalName = "Galatian",
	scripts = {"Latn", "Grek"},
	family = "cel",
}

m["xgb"] = {
	canonicalName = "Gbin",
	family = "dmn",
}

m["xgd"] = {
	canonicalName = "Gudang",
}

m["xgf"] = {
	canonicalName = "Gabrielino-Fernandeño",
	otherNames = {"Tongva", "Gabrielino", "Gabrieleño", "Fernandeño"},
	scripts = {"Latn"},
	family = "azc-tak",
}

m["xgg"] = {
	canonicalName = "Goreng",
}

m["xgi"] = {
	canonicalName = "Garingbal",
}

m["xgl"] = {
	canonicalName = "Galindan",
	family = "bat",
}

m["xgm"] = {
	canonicalName = "Darumbal",
	otherNames = {"Darambal", "Dharumbal", "Dharambal", "Guwinmal", "Kuinmabara", "Karunbara", "Rakiwara", "Wapabara"},
}

m["xgr"] = {
	canonicalName = "Garza",
}

m["xgu"] = {
	canonicalName = "Unggumi",
	scripts = {"Latn"},
}

m["xgw"] = {
	canonicalName = "Guwa",
}

m["xha"] = {
	canonicalName = "Harami",
}

m["xhc"] = {
	canonicalName = "Hunnic",
	otherNames = {"Hunnish"},
}

m["xhd"] = {
	canonicalName = "Hadrami",
}

m["xhe"] = {
	canonicalName = "Khetrani",
	otherNames = {"Khetranki"},
	family = "inc"
}

m["xhr"] = {
	canonicalName = "Hernican",
	scripts = {"Ital"},
	family = "itc",
}

m["xht"] = {
	canonicalName = "Hattic",
	scripts = {"Xsux"},
	family = "qfa-iso",
}

m["xhu"] = {
	canonicalName = "Hurrian",
	scripts = {"Xsux", "Ugar"},
	family = "qfa-hur",
}

m["xhv"] = {
	canonicalName = "Khua",
	family = "mkh",
}

m["xib"] = {
	canonicalName = "Iberian",
	scripts = {"Latn", "Ibrn"},
	family = "qfa-iso",
}

m["xii"] = {
	canonicalName = "Xiri",
}

m["xil"] = {
	canonicalName = "Illyrian",
	family = "ine",
}

m["xin"] = {
	canonicalName = "Xinca",
	family = "nai-xin",
}

m["xir"] = {
	canonicalName = "Xiriâna",
	family = "awd",
}

m["xis"] = {
	canonicalName = "Kisan", -- a dialect of 'kru', said to be over 70 percent intelligible with it; cf 'kxl'
}

m["xiv"] = {
	canonicalName = "Indus Valley Language",
	scripts = {"Inds"},
}

m["xiy"] = {
	canonicalName = "Xipaya",
}

m["xjb"] = {
	canonicalName = "Minjungbal",
	family = "aus-pam",
}

m["xka"] = {
	canonicalName = "Kalkoti",
}

m["xkb"] = {
	canonicalName = "Manigri-Kambolé Ede Nago",
}

m["xkc"] = {
	canonicalName = "Kho'ini",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["xkd"] = {
	canonicalName = "Mendalam Kayan",
}

m["xke"] = {
	canonicalName = "Kereho",
	otherNames = {"Krio Dayak", "Krio", "Seputan"},
	scripts = {"Latn"},
	family = "poz",
}

m["xkf"] = {
	canonicalName = "Khengkha",
	otherNames = {"Kheng"},
	family = "sit",
}

m["xkg"] = {
	canonicalName = "Kagoro",
}

m["xki"] = {
	canonicalName = "Kenyan Sign Language",
	family = "sgn",
}

m["xkj"] = {
	canonicalName = "Kajali",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["xkk"] = {
	canonicalName = "Kaco'",
	otherNames = {"Lamam"}, -- Lamam is a Kaco' clan name, formerly encoded by the ISO as 'lmm'
	family = "mkh",
}

m["xkl"] = {
	canonicalName = "Bakung",
	otherNames = {"Mainstream Kenyah", "Kenyah"},
	scripts = {"Latn"},
	family = "poz-swa",
}

m["xkn"] = {
	canonicalName = "Kayan River Kayan",
}

m["xko"] = {
	canonicalName = "Kiorr",
	family = "aav",
}

m["xkp"] = {
	canonicalName = "Kabatei",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["xkq"] = {
	canonicalName = "Koroni",
}

m["xkr"] = {
	canonicalName = "Xakriabá",
	otherNames = {"Chacriabá", "Chacriaba", "Chakriaba", "Xakriaba", "Xacriabá", "Xacriaba", "Chikriaba", "Xikriabá", "Xikriaba", "Shacriaba", "Xicriabá", "Xicriaba", "Chicriabá", "Chicriaba"},
	scripts = {"Latn"},
	family = "sai-jee",
}

m["xks"] = {
	canonicalName = "Kumbewaha",
}

m["xkt"] = {
	canonicalName = "Kantosi",
}

m["xku"] = {
	canonicalName = "Kaamba",
}

m["xkv"] = {
	canonicalName = "Kgalagadi",
}

m["xkw"] = {
	canonicalName = "Kembra",
}

m["xkx"] = {
	canonicalName = "Karore",
	family = "poz-ocw",
}

m["xky"] = {
	canonicalName = "Uma' Lasan",
	family = "poz-swa",
}

m["xkz"] = {
	canonicalName = "Kurtop",
	otherNames = {"Kurtöp", "Kurtopkha", "Kurtokha"},
	scripts = {"Tibt", "Latn"},
	family = "tbq",
}

m["xla"] = {
	canonicalName = "Kamula",
}

m["xlb"] = {
	canonicalName = "Loup B",
	family = "alg",
}

m["xlc"] = {
	canonicalName = "Lycian",
	scripts = {"Lyci"},
	family = "ine-ana",
	translit_module = "Lyci-translit",
}

m["xld"] = {
	canonicalName = "Lydian",
	scripts = {"Lydi"},
	family = "ine-ana",
	translit_module = "Lydi-translit",
}

m["xle"] = {
	canonicalName = "Lemnian",
	scripts = {"Ital"},
	family = "qfa-tyn",
	translit_module = "Ital-translit",
}

m["xlg"] = {
	canonicalName = "Ancient Ligurian",
}

m["xli"] = {
	canonicalName = "Liburnian",
	family = "ine",
}

m["xln"] = {
	canonicalName = "Alanic",
	family = "ira",
}

m["xlo"] = {
	canonicalName = "Loup A",
	family = "alg",
}

m["xlp"] = {
	canonicalName = "Lepontic",
	scripts = {"Ital"},
	family = "cel",
	translit_module = "Ital-translit",
}

m["xls"] = {
	canonicalName = "Lusitanian",
	scripts = {"Latn"},
	family = "ine",
}

m["xlu"] = {
	canonicalName = "Luwian",
	otherNames = {"Cuneiform Luwian", "Hieroglyphic Luwian"},
	scripts = {"Xsux", "Hluw"},
	family = "ine-ana",
}

m["xly"] = {
	canonicalName = "Elymian",
}

m["xma"] = {
	canonicalName = "Mushungulu",
}

m["xmb"] = {
	canonicalName = "Mbonga",
}

m["xmc"] = {
	canonicalName = "Makhuwa-Marrevone",
}

m["xmd"] = {
	canonicalName = "Mbudum",
}

m["xme"] = {
	canonicalName = "Median",
	scripts = {"Zyyy"},
	family = "ira",
}

m["xmf"] = {
	canonicalName = "Mingrelian",
	otherNames = {"Megrelian", "Mingrel", "Megrel"},
	scripts = {"Geor"},
	family = "ccs-gzn",
	translit_module = "Geor-translit",
}

m["xmg"] = {
	canonicalName = "Mengaka",
	family = "bai",
}

m["xmh"] = {
	canonicalName = "Kugu-Muminh",
	otherNames = {"Kuku-Muminh"},
	family = "aus-pmn",
}

m["xmj"] = {
	canonicalName = "Majera",
	family = "cdc",
}

m["xmk"] = {
	canonicalName = "Ancient Macedonian",
	scripts = {"polytonic"},
	family = "grk",
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, cpg, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇᾱ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗῑ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧῡ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}},
	entry_name = {
		from = {"[ᾸᾹ]", "[ᾰᾱ]", "[ῘῙ]", "[ῐῑ]", "[ῨῩ]", "[ῠῡ]"},
		to   = {"Α", "α", "Ι", "ι", "Υ", "υ"}} ,
}

m["xml"] = {
	canonicalName = "Malaysian Sign Language",
	family = "sgn",
}

m["xmm"] = {
	canonicalName = "Manado Malay",
}

m["xmn"] = {
	canonicalName = "Manichaean Middle Persian",
	scripts = {"Mani"},
	family = "ira",
	ancestors = {"peo"},
	translit_module = "Mani-translit",
}

m["xmo"] = {
	canonicalName = "Morerebi",
}

m["xmp"] = {
	canonicalName = "Kuku-Mu'inh",
}

m["xmq"] = {
	canonicalName = "Kuku-Mangk",
	family = "aus-pam",
}

m["xmr"] = {
	canonicalName = "Meroitic",
	scripts = {"Mero", "Merc"},
	family = "afa",
}

m["xms"] = {
	canonicalName = "Moroccan Sign Language",
	family = "sgn",
}

m["xmt"] = {
	canonicalName = "Matbat",
	family = "poz-hce",
}

m["xmu"] = {
	canonicalName = "Kamu",
}

m["xmx"] = {
	canonicalName = "Maden",
	family = "poz-hce",
}

m["xmy"] = {
	canonicalName = "Mayaguduna",
}

m["xmz"] = {
	canonicalName = "Mori Bawah",
	scripts = {"Latn"},
	family = "poz-btk",
}

m["xna"] = {
	canonicalName = "Ancient North Arabian",
}

m["xnb"] = {
	canonicalName = "Kanakanabu",
	otherNames = {"Kanakanavu"},
	scripts = {"Latn"},
	family = "map",
}

m["xng"] = {
	canonicalName = "Middle Mongolian",
	scripts = {"Mong", "Arab", "Phag"},
	family = "xgn",
	translit_module = "mn-translit",
}

m["xnh"] = {
	canonicalName = "Kuanhua",
	family = "mkh",
}

m["xni"] = {
	canonicalName = "Ngarigu",
}

m["xnk"] = {
	canonicalName = "Nganakarti",
}

m["xnn"] = {
	canonicalName = "Northern Kankanay",
}

m["xnr"] = {
	canonicalName = "Kangri",
	scripts = {"Deva", "Takr", "fa-Arab"},
	family = "inc",
}

m["xns"] = {
	canonicalName = "Kanashi",
}

m["xnt"] = {
	canonicalName = "Narragansett",
	scripts = {"Latn"},
	family = "alg",
}

m["xnu"] = {
	canonicalName = "Nukunul",
}

m["xny"] = {
	canonicalName = "Nyiyaparli",
	otherNames = {"Nyiyabali", "Njijabali", "Nijadali"},
	scripts = {"Latn"},
	family = "aus-nga",
}

m["xoc"] = {
	canonicalName = "O'chi'chi'",
	family = "nic-bco",
}

m["xod"] = {
	canonicalName = "Kokoda",
}

m["xog"] = {
	canonicalName = "Soga",
	otherNames = {"Lusoga"},
	scripts = {"Latn"},
	family = "bnt",
}

m["xoi"] = {
	canonicalName = "Kominimung",
	family = "paa",
}

m["xok"] = {
	canonicalName = "Xokleng",
}

m["xom"] = {
	canonicalName = "Komo",
	otherNames = {"Komo (Sudan)", "Madiin"},
}

m["xon"] = {
	canonicalName = "Konkomba",
}

m["xoo"] = { -- contrast kzw, sai-kat, sai-xoc
	canonicalName = "Xukurú",
	otherNames = {"Xukuru", "Xucurú", "Xucuru", "Shukurú", "Shukuru", "Shucurú", "Shucuru", "Kirirí", "Kiriri", "Kirirí-Xokó"},
}

m["xop"] = {
	canonicalName = "Kopar",
}

m["xor"] = {
	canonicalName = "Korubo",
}

m["xow"] = {
	canonicalName = "Kowaki",
}

m["xpa"] = {
	canonicalName = "Pirriya",
}

m["xpc"] = {
	canonicalName = "Pecheneg",
	family = "trk",
}

m["xpe"] = {
	canonicalName = "Liberia Kpelle",
}

m["xpg"] = {
	canonicalName = "Phrygian",
	scripts = {"Grek"},
	family = "ine",
}

m["xpi"] = {
	canonicalName = "Pictish",
	scripts = {"Ogam", "Latn"},
}

m["xpj"] = {
	canonicalName = "Mpalitjanh",
	otherNames = {"Luthigh"},
	family = "aus-pam",
}

m["xpk"] = {
	canonicalName = "Kulina",
	otherNames = {"Kulina Pano"},
	family = "sai-pan",
}

m["xpm"] = {
	canonicalName = "Pumpokol",
	scripts = {"Latn"},
	family = "qfa-yen",
}

m["xpn"] = {
	canonicalName = "Kapinawá",
}

m["xpo"] = {
	canonicalName = "Pochutec",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["xpp"] = {
	canonicalName = "Puyo-Paekche",
}

m["xpq"] = {
	canonicalName = "Mohegan-Pequot",
	scripts = {"Latn"},
	family = "alg",
}

m["xpr"] = {
	canonicalName = "Parthian",
	scripts = {"Prti", "Mani", "Phlv"},
	family = "ira",
}

m["xps"] = {
	canonicalName = "Pisidian",
	family = "ine-ana",
}

m["xpu"] = {
	canonicalName = "Punic",
	scripts = {"Phnx"},
	family = "sem-can",
	ancestors = {"phn"},
}

m["xpy"] = {
	canonicalName = "Buyeo",
	scripts = {"Hani"},
}

m["xqa"] = {
	canonicalName = "Karakhanid",
	family = "trk",
}

m["xqt"] = {
	canonicalName = "Qatabanian",
}

m["xra"] = {
	canonicalName = "Krahô",
}

m["xrb"] = {
	canonicalName = "Eastern Karaboro",
}

m["xrd"] = {
	canonicalName = "Gundungurra",
}

m["xre"] = {
	canonicalName = "Kreye",
}

m["xrg"] = {
	canonicalName = "Minang",
}

m["xri"] = {
	canonicalName = "Krikati-Timbira",
}

m["xrm"] = {
	canonicalName = "Armazic",
}

m["xrn"] = {
	canonicalName = "Arin",
	scripts = {"Latn"},
	family = "qfa-yen",
}

m["xrq"] = {
	canonicalName = "Karranga",
	otherNames = {"Karrangpurru"},
	scripts = {"Latn"},
}

m["xrr"] = {
	canonicalName = "Raetic",
	otherNames = {"Rhaetic", "Rhaetian"},
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["xrt"] = {
	canonicalName = "Aranama-Tamique",
}

m["xru"] = {
	canonicalName = "Marriammu",
}

m["xrw"] = {
	canonicalName = "Karawa",
}

m["xsa"] = {
	canonicalName = "Sabaean",
}

m["xsb"] = {
	canonicalName = "Sambali",
	otherNames = {"Sambal", "Tina Sambal", "Tina"},
	scripts = {"Latn"},
}

m["xsc"] = {
	canonicalName = "Scythian",
	family = "ira",
}

m["xsd"] = {
	canonicalName = "Sidetic",
	family = "ine-ana",
}

m["xse"] = {
	canonicalName = "Sempan",
}

m["xsh"] = {
	canonicalName = "Shamang",
}

m["xsi"] = {
	canonicalName = "Sio",
}

m["xsl"] = {
	canonicalName = "South Slavey",
	scripts = {"Latn"},
	family = "ath-nor",
}

m["xsm"] = {
	canonicalName = "Kasem",
}

m["xsn"] = {
	canonicalName = "Sanga (Nigeria)",
	otherNames = {"Sanga"},
	scripts = {"Latn"},
	family = "nic-knj",
}

m["xso"] = {
	canonicalName = "Solano",
	scripts = {"Latn"},
}

m["xsp"] = {
	canonicalName = "Silopi",
}

m["xsq"] = {
	canonicalName = "Makhuwa-Saka",
}

m["xsr"] = {
	canonicalName = "Sherpa",
	scripts = {"Tibt"},
	family = "tbq",
	ancestors = {"xct"},
}

m["xss"] = {
	canonicalName = "Assan",
	scripts = {"Latn"},
	family = "qfa-yen",
}

m["xsu"] = {
	canonicalName = "Sanumá",
}

m["xsv"] = {
	canonicalName = "Sudovian",
	otherNames = {"Jatvingian"},
	scripts = {"Latn"},
	family = "bat",
}

m["xsy"] = {
	canonicalName = "Saisiyat",
	scripts = {"Latn"},
	family = "map",
}

m["xta"] = {
	canonicalName = "Alcozauca Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["xtb"] = {
	canonicalName = "Chazumba Mixtec",
	family = "omq-mix",
}

m["xtc"] = {
	canonicalName = "Kadugli",
	otherNames = {"Katcha-Kadugli-Miri"},
	scripts = {"Latn"},
	family = "qfa-kad",
}

m["xtd"] = {
	canonicalName = "Diuxi-Tilantongo Mixtec",
	family = "omq-mix",
}

m["xte"] = {
	canonicalName = "Ketengban",
}

m["xth"] = {
	canonicalName = "Yitha Yitha",
}

m["xti"] = {
	canonicalName = "Sinicahua Mixtec",
	family = "omq-mix",
}

m["xtj"] = {
	canonicalName = "San Juan Teita Mixtec",
	family = "omq-mix",
}

m["xtl"] = {
	canonicalName = "Tijaltepec Mixtec",
	family = "omq-mix",
}

m["xtm"] = {
	canonicalName = "Magdalena Peñasco Mixtec",
	family = "omq-mix",
}

m["xtn"] = {
	canonicalName = "Northern Tlaxiaco Mixtec",
	family = "omq-mix",
}

m["xto"] = {
	canonicalName = "Tocharian A",
	otherNames = {"East Tocharian", "Agnean"},
	family = "ine-toc",
}

m["xtp"] = {
	canonicalName = "San Miguel Piedras Mixtec",
	family = "omq-mix",
}

m["xtq"] = {
	canonicalName = "Tumshuqese",
}

m["xtr"] = {
	canonicalName = "Early Tripuri",
}

m["xts"] = {
	canonicalName = "Sindihui Mixtec",
	family = "omq-mix",
}

m["xtt"] = {
	canonicalName = "Tacahua Mixtec",
	family = "omq-mix",
}

m["xtu"] = {
	canonicalName = "Cuyamecalco Mixtec",
	family = "omq-mix",
}

m["xtv"] = {
	canonicalName = "Thawa",
}

m["xtw"] = {
	canonicalName = "Tawandê",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["xty"] = {
	canonicalName = "Yoloxochitl Mixtec",
	family = "omq-mix",
}

m["xtz"] = {
	canonicalName = "Tasmanian",
	scripts = {"Latn"},
}

m["xua"] = {
	canonicalName = "Alu Kurumba",
	family = "dra",
}

m["xub"] = {
	canonicalName = "Betta Kurumba",
	scripts = {"Knda", "Mlym", "Taml"},
	family = "dra",
}

m["xud"] = {
	canonicalName = "Umiida",
	scripts = {"Latn"},
}

m["xug"] = {
	canonicalName = "Kunigami",
	family = "jpx-ryu",
}

m["xuj"] = {
	canonicalName = "Jennu Kurumba",
	family = "dra",
}

m["xul"] = {
	canonicalName = "Ngunawal",
	scripts = {"Latn"},
	family = "aus-yuk",
}

m["xum"] = {
	canonicalName = "Umbrian",
	scripts = {"Ital", "Latn"},
	family = "itc",
	translit_module = "Ital-translit",
}

m["xun"] = {
	canonicalName = "Unggaranggu",
	scripts = {"Latn"},
}

m["xuo"] = {
	canonicalName = "Kuo",
}

m["xup"] = {
	canonicalName = "Upper Umpqua",
	family = "ath-pco",
}

m["xur"] = {
	canonicalName = "Urartian",
	otherNames = {"Urartean"},
	scripts = {"Xsux"},
	family = "qfa-hur",
}

m["xut"] = {
	canonicalName = "Kuthant",
}

m["xuu"] = {
	canonicalName = "Kxoe",
	otherNames = {"Khwe"},
	scripts = {"Latn"},
	family = "khi",
}

m["xve"] = {
	canonicalName = "Venetic",
	scripts = {"Ital"},
	family = "ine",
	translit_module = "Ital-translit",
}

m["xvi"] = {
	canonicalName = "Kamviri",
	scripts = {"Arab"},
	family = "iir-nur",
}

m["xvn"] = {
	canonicalName = "Vandalic",
	scripts = {"Latn"},
	family = "gme",
}

m["xvo"] = {
	canonicalName = "Volscian",
	scripts = {"Latn"},
	family = "itc",
}

m["xvs"] = {
	canonicalName = "Vestinian",
	scripts = {"Latn"},
	family = "itc",
}

m["xwa"] = {
	canonicalName = "Kwaza",
}

m["xwc"] = {
	canonicalName = "Woccon",
	scripts = {"Latn"},
	family = "nai-cat",
}

m["xwd"] = {
	canonicalName = "Wadi Wadi",
}

m["xwe"] = {
	canonicalName = "Xwela Gbe",
}

m["xwg"] = {
	canonicalName = "Kwegu",
	family = "sdv",
}

m["xwj"] = {
	canonicalName = "Wajuk",
}

m["xwk"] = {
	canonicalName = "Wangkumara",
	otherNames = {"Wanggumara", "Karenggapa", "Punthamara"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["xwl"] = {
	canonicalName = "Western Xwla Gbe",
}

m["xwo"] = {
	canonicalName = "Written Oirat",
	family = "xgn",
}

m["xwr"] = {
	canonicalName = "Kwerba Mamberamo",
}

m["xww"] = {
	canonicalName = "Wemba-Wemba",
	otherNames = {"Wemba Wemba", "Wamba-Wamba", "Wamba Wamba", "Wembawemba", "Baraba-Baraba", "Barababaraba", "Nari-Nari", "Wergaia", "Wotjobaluk"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["xxb"] = {
	canonicalName = "Boro",
	otherNames = {"Boro (Ghana)"},
}

m["xxk"] = {
	canonicalName = "Ke'o",
}

m["xxm"] = {
	canonicalName = "Minkin",
}

m["xxr"] = {
	canonicalName = "Koropó",
}

m["xxt"] = {
	canonicalName = "Tambora",
	scripts = {"Latn"},
}

m["xya"] = {
	canonicalName = "Yaygir",
}

m["xyb"] = {
	canonicalName = "Yandjibara",
}

m["xyl"] = {
	canonicalName = "Yalakalore",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["xyy"] = {
	canonicalName = "Yorta Yorta",
	otherNames = {"Yotayota", "Yortayorta", "Bangerang", "Kailtheban", "Wollithiga", "Jotijota", "Joti-Jota", "Jodajoda"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["xzh"] = {
	canonicalName = "Zhang-Zhung",
}

m["xzm"] = {
	canonicalName = "Zemgalian",
	otherNames = {"Semigallian", "Semigalian"},
	family = "bat",
}

m["xzp"] = {
	canonicalName = "Ancient Zapotec",
}

return m