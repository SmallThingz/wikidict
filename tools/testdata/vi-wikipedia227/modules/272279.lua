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

m["xaa"] = {
	"tiếng Ả Rập Andalusia",
	1137945,
	"sem-arb",
	"Arab, Latn",
	"Tiếng Ả Rập Andalusia",
	"Ả Rập Andalusia",
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		from = {u(0x0671)},
		to = {u(0x0627)}
	},
}

m["xab"] = {
	"Sambe",
	36265,
	"nic-alu",
	"Latn",
}

m["xac"] = {
	"Kachari",
	3442442,
	"tbq-bdg",
}

m["xad"] = {
	"Adai",
	346744,
}

m["xae"] = {
	"Aequian",
	930579,
	"itc",
}

m["xag"] = {
	"tiếng Aghwan",
	34931,
	"cau-esm",
	"Aghb",
	"Tiếng Aghwan",
	"Aghwan",
	translit = "Aghb-translit",
	override_translit = true,
}

m["xai"] = {
	"Kaimbé",
	6348017,
}

m["xaj"] = {
	"Ararandewára",
	nil,
	"tup-gua",
	"Latn",
}

m["xak"] = {
	"Maku",
	2032882,
	nil,
	"Latn",
}

m["xal"] = {
	"tiếng Kalmyk",
	33634,
	"xgn-cen",
	"Cyrl, xwo-Mong",
	"Tiếng Kalmyk",
	"Kalmyk",
	ancestors = "xwo",
	translit = "xal-translit",
	override_translit = true,
	sort_key = "xal-sortkey",
}

m["xam"] = {
	"ǀXam",
	2086145,
	"khi-tuu",
	"Latn",
}

m["xan"] = {
	"tiếng Xamtanga",
	56527,
	"cus-cen",
	"Ethi",
	"Tiếng Xamtanga",
	"Xamtanga",
}

m["xao"] = {
	"Khao",
	3196077,
	"mkh-pal",
}

m["xap"] = {
	"Apalachee",
	686501,
	"nai-mus",
	"Latn",
}

m["xaq"] = {
	"tiếng Aquitani",
	500522,
	"euq",
	"Latn",
	"Tiếng Aquitani",
	"Aquitani",
}

m["xar"] = {
	"Karami",
	11732281,
}

m["xas"] = {
	"tiếng Kamassia",
	35991,
	translit = "xas-translit",
	"syd",
	"Cyrl",
	"Tiếng Kamassia",
	"Kamassia",
}

m["xat"] = {
	"Katawixi",
	3440512,
	"sai-ktk",
}

m["xau"] = {
	"Kauwera",
	6378983,
	"paa-tkw",
}

m["xav"] = {
	"tiếng Xavante",
	36962,
	"sai-cje",
	"Latn",
	"Tiếng Xavante",
	"Xavante",
}

m["xaw"] = {
	"Kawaiisu",
	56338,
	"azc-num",
	"Latn",
}

m["xay"] = {
	"Kayan Mahakam",
	25337171,
}

m["xbb"] = {
	"Lower Burdekin",
	6693353,
}

m["xbc"] = {
	"tiếng Bactria",
	756651,
	"ira-sbc",
	"Grek, Mani",
	"Tiếng Bactria",
	"Bactria",
	translit = "xbc-translit",
	entry_name = {
		from = {"Þ", "þ"},
		to = {"Ϸ", "ϸ"}
	},
}

m["xbd"] = {
	"Bindal",
	4913975,
}

m["xbe"] = {
	"Bigambal",
	16841801,
	"aus-pam", --unclassified within
}

m["xbg"] = {
	"Bunganditj",
	4997615,
}

m["xbi"] = {
	"Kombio",
	6428259,
	"qfa-tor",
	"Latn",
}

m["xbj"] = {
	"Birrpayi",
	nil,
}

m["xbm"] = {
	"tiếng Breton trung đại",
	787610,
	"cel-brs",
	"Latn",
	"Tiếng Breton trung đại",
	"Breton trung đại",
	ancestors = "obt",
}

m["xbn"] = {
	"Kenaboi",
	6388752,
}

m["xbo"] = {
	"tiếng Bulgar",
	36880,
	"trk-ogr",
	"Arab, Grek",
	"Tiếng Bulgar",
	"Bulgar",
	entry_name = {
		Arab = "ar-entryname",
	}
}

m["xbp"] = {
	"Bibbulman",
	22918391,
}

m["xbr"] = {
	"tiếng Kambera",
	3053279,
	"poz-cet",
	"Latn",
	"Tiếng Kambera",
	"Kambera",
}

m["xbw"] = {
	"Kambiwá",
	9006744,
}

m["xby"] = {
	"Butchulla",
	31752631,
}

m["xcb"] = {
	"tiếng Cumbria",
	35965,
	"cel-brw",
	nil,
	"Tiếng Cumbria",
	"Cumbria",
}

m["xcc"] = {
	"tiếng Camuni",
	489011,
	nil,
	"Ital",
	"Tiếng Camuni",
	"Camuni",
	translit = "Ital-translit",
}

m["xce"] = {
	"tiếng Celtiberi",
	37012,
	"cel-his",
	"Latn",
	"Tiếng Celtiberi",
	"Celtiberi",
}

m["xch"] = {
	"Chemakum",
	56397,
	"chi",
	"Latn",
}

m["xcl"] = {
	"tiếng Armenia cổ",
	181074,
	"hyx",
	"Armn",
	"Tiếng Armenia cổ",
	"Armenia cổ",
	translit = "Armn-translit",
	override_translit = true,
	entry_name = {
		remove_diacritics = "՞՜՛՟",
		from = {"եւ"},
		to = {"և"}
	},
}

m["xcm"] = {
	"Comecrudo",
	609808,
	"nai-pak",
}

m["xcn"] = {
	"Cotoname",
	56889,
	"nai-pak",
}

m["xco"] = {
	"tiếng Khwarezm",
	33138,
	"ira-sbc",
	"Arab, Armi, Chrs, Phlv, Sogd",
	"Tiếng Khwarezm",
	"Khwarezm",
	translit = {Chrs = "Chrs-translit"},
}

m["xcr"] = {
	"Carian",
	35929,
	"ine-luw",
	"Cari",
}

m["xct"] = {
	"tiếng Tây Tạng cổ điển",
	5128314,
	"sit-tib",
	"Tibt, Hani, Marc, Mong, mnc-Mong, xwo-Mong, Phag, Tang, Zanb",
	"Tiếng Tây Tạng cổ điển",
	"Tây Tạng cổ điển",
	translit = {
		Tibt = "Tibt-translit",
		Mong = "Mong-translit",
		["mnc-Mong"] = "mnc-translit",
		["xwo-Mong"] = "xwo-translit",
		Tang = "txg-translit",
	},
	override_translit = true,
	display_text = {
		Tibt = s["Tibt-displaytext"],
		Mong = s["Mong-displaytext"],
	},
	entry_name = {
		Tibt = s["Tibt-entryname"],
		Mong = s["Mong-entryname"],
	},
	sort_key = {
		Tibt = "Tibt-sortkey",
		Hani = "Hani-sortkey",
	},
}

m["xcu"] = {
	"Curonian",
	35857,
	"bat",
	"Latn",
}

m["xcv"] = {
	"tiếng Chuvan",
	3516641,
	"qfa-yuk",
	"Cyrl",
	"Tiếng Chuvan",
	"Chuvan",
	translit = "xcv-translit"
}

m["xcw"] = {
	"Coahuilteco",
	2008062,
	"nai-pak",
}

m["xcy"] = {
	"Cayuse",
	2472016,
}

m["xda"] = {
	"Darkinjung",
	5223660,
	"aus-yuk",
	"Latn",
}

m["xdc"] = {
	"tiếng Dacia",
	682547,
	"ine",
	"Latn, Polyt",
	"Tiếng Dacia",
	"Dacia",
	translit = {Polyt = "grc-translit"},
	entry_name = {
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Polyt = s["Grek-sortkey"],
	},
}

m["xdk"] = {
	"tiếng Dharug",
	1166814,
	"aus-yuk",
	"Latn",
	"Tiếng Dharug",
	"Dharug",
}

m["xdm"] = {
	"Edomite",
	2363529,
	"sem-can",
	"Phnx",
	translit = "Phnx-translit",
}

m["xdq"] = {
	"tiếng Kaitag",
	1990659,
	"cau-drg",
	"Cyrl",
	"Tiếng Kaitag",
	"Kaitag",
	translit = {Cyrl = "dar-translit"},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
}

m["xdy"] = {
	"Malayic Dayak",
	3514892,
}

m["xeb"] = {
	"tiếng Ebla",
	35345,
	"sem-eas",
	"Xsux",
	"Tiếng Ebla",
	"Ebla",
}

m["xed"] = {
	"Hdi",
	56246,
	"cdc-cbm",
	"Latn",
}

m["xeg"] = {
	"ǁXegwi",
	3509732,
	"khi-tuu",
	"Latn",
}

m["xel"] = {
	"Kelo",
	6386412,
	"sdv-eje",
}

m["xem"] = {
	"Kembayan",
	6386874,
}

m["xep"] = {
	"Epi-Olmec",
	nil,
}

m["xer"] = {
	"Xerénte",
	3073436,
	"sai-cje",
	"Latn",
}

m["xes"] = {
	"Kesawai",
	6394907,
	"ngf-mad",
	"Latn",
}

m["xet"] = {
	"Xetá",
	2980404,
	"tup-gua",
	"Latn",
}

m["xeu"] = {
	"Keoru-Ahia",
	11732313,
	"ngf",
}

m["xfa"] = {
	"tiếng Falisci",
	35669,
	"itc",
	"Ital, Latn",
	translit = {Ital = "Ital-translit"},
	entry_name = {remove_diacritics = c.macron .. c.breve .. c.diaer},
	"Tiếng Falisci",
	"Falisci",
}

m["xga"] = {
	"tiếng Galati",
	27403,
	"cel-con",
	"Latn, Grek",
	"Tiếng Galati",
	"Galati",
	ancestors = "cel-gau",
}

m["xgb"] = {
	"Gbin",
	16934745,
	"dmn-mse",
	"Latn",
}

m["xgd"] = {
	"Gudang",
	5614528,
}

m["xgf"] = {
	"Gabrielino-Fernandeño",
	56387,
	"azc-tak",
	"Latn",
}

m["xgg"] = {
	"Goreng",
	nil,
}

m["xgi"] = {
	"Garingbal",
	nil,
}

m["xgl"] = {
	"Galindian",
	1190494,
	"bat",
	"Latn",
}

m["xgm"] = {
	"Darumbal",
	16954400,
}

m["xgr"] = {
	"Garza",
	3098656,
	"nai-pak",
}

m["xgu"] = {
	"Unggumi",
	62000004,
	"aus-wor",
	"Latn",
}

m["xgw"] = {
	"Guwa",
	5621992,
}

m["xha"] = {
	"Harami",
	41506724,
	nil,
	"Sarb",
	translit = "Sarb-translit",
}

m["xhc"] = {
	"Hunnic",
	35959,
}

m["xhd"] = {
	"Hadrami",
	1032453,
	"sem-osa",
	"Sarb",
	translit = "Sarb-translit",
}

m["xhe"] = {
	"Khetrani",
	2614111,
	"inc-pan",
	ancestors = "lah",
}

m["xhm"] = {
	"tiếng Khmer trung đại",
	25226861,
	"mkh-kmr",
	"Latn, Khmr", --and also Pallava
	"Tiếng Khmer trung đại",
	"Khmer trung đại",
	ancestors = "okz",
}

m["xhr"] = {
	"tiếng Hernici",
	5908773,
	"itc-sbl",
	"Ital",
	"Tiếng Hernici",
	"Hernici",
	translit = "Ital-translit",
}

m["xht"] = {
	"tiếng Hatti",
	31107,
	"qfa-iso",
	"Xsux",
	"Tiếng Hatti",
	"Hatti",
}

m["xhu"] = {
	"tiếng Hurri",
	35740,
	"qfa-hur",
	"Xsux, Ugar",
	"Tiếng Hurri",
	"Hurri",
}

m["xhv"] = {
	"tiếng Khùa",
	22970290,
	"mkh-kat",
	"Latn",
	"Tiếng Khùa",
	"Khùa"
}

m["xib"] = {
	"Iberian",
	855215,
	"qfa-iso",
	"Latn, Ibrn",
}

m["xii"] = {
	"Xiri",
	36876,
}

m["xin"] = {
	"Xinca",
	1546494,
	"nai-xin",
	"Latn",
}

m["xil"] = {
	"Illyrian",
	35976,
	"ine",
	type = "reconstructed",
}

m["xir"] = {
	"Xiriâna",
	2028772,
	"awd",
	"Latn",
}

m["xis"] = {
	"tiếng Kisan",
	63339998,
	"dra-kml",
	"Orya",
	ancestors = "kru",
	"Tiếng Kisan",
	"Kisan",
}

m["xiv"] = {
	"Indus Valley Language",
	3428279,
	nil,
	"Inds",
}

m["xiy"] = {
	"Xipaya",
	13226,
	"tup",
}

m["xjb"] = {
	"Minjungbal",
	nil,
	"aus-pam",
	"Latn",
}

m["xka"] = {
	"tiếng Kalkot",
	3877551,
	"inc-shn",
	"ur-Arab",
	"Tiếng Kalkot",
	"Kalkot",
}

m["xkb"] = {
	"Manigri-Kambolé Ede Nago",
	36042,
	"alv-ede",
}

m["xkc"] = {
	"Khoini",
	6401919,
	"xme-ttc",
	ancestors = "xme-ttc-wes",
}

m["xkd"] = {
	"Mendalam Kayan",
	12952597,
}

m["xke"] = {
	"Kereho",
	6437086,
	"poz",
	"Latn",
}

m["xkf"] = {
	"tiếng Khengkha",
	3695207,
	"sit-ebo",
	"Tibt",
	"Tiếng Khengkha",
	"Khengkha",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["xkg"] = {
	"Kagoro",
	11159524,
	"dmn-wmn",
}

m["xki"] = {
	"Kenyan Sign Language",
	6392859,
	"sgn",
}

m["xkj"] = {
	"Kajali",
	14916876,
	"xme-ttc",
	ancestors = "xme-ttc-cen",
}

m["xkk"] = {
	"Kaco'",
	6344767,
	"mkh",
}

m["xkl"] = {
	"tiếng Bakung",
	6736761,
	"poz-swa",
	"Latn",
	"Tiếng Bakung",
	"Bakung",
}

m["xkn"] = {
	"Kayan River Kayan",
	12473395,
	"poz",
}

m["xko"] = {
	"Kiorr",
	6414519,
	"mkh-pal",
}

m["xkp"] = {
	"Kabatei",
	34165,
	"xme-ttc",
	ancestors = "xme-ttc-cen",
}

m["xkq"] = {
	"Koroni",
	3199000,
	"poz-btk",
}

m["xkr"] = {
	"Xakriabá",
	3073441,
	"sai-cje",
	"Latn",
}

m["xks"] = {
	"tiếng Kumbewaha",
	6443722,
	"poz-mun",
	"Latn",
	"Tiếng Kumbewaha",
	"Kumbewaha"
}

m["xkt"] = {
	"Kantosi",
	35651,
	"nic-dag",
}

m["xku"] = {
	"Kaamba",
	11042324,
	"bnt-kng",
}

m["xkv"] = {
	"Kgalagadi",
	2088743,
	"bnt-sts",
	"Latn",
}

m["xkw"] = {
	"Kembra",
	12953627,
	"paa-pau",
}

m["xkx"] = {
	"Karore",
	6373260,
	"poz-ocw",
}

m["xky"] = {
	"Uma' Lasan",
	nil,
	"poz-swa",
}

m["xkz"] = {
	"tiếng Kurtokha",
	3695193,
	"sit-ebo",
	"Tibt, Latn",
	"Tiếng Kurtokha",
	"Kurtokha",
	translit = {Tibt = "Tibt-translit"},
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["xla"] = {
	"tiếng Kamula",
	10957277,
	"ngf",
	"Latn",
	"Tiếng Kamula",
	"Kamula",
}

m["xlb"] = {
	"Loup B",
	13108281,
	"alg-eas",
	"Latn",
}

m["xlc"] = {
	"tiếng Lycia",
	35969,
	"ine-luw",
	"Lyci",
	"Tiếng Lycia",
	"Lycia",
	translit = "Lyci-translit",
}

m["xld"] = {
	"tiếng Lydia",
	36095,
	"ine-ana",
	"Lydi",
	"Tiếng Lydia",
	"Lydia",
	translit = "Lydi-translit",
}

m["xle"] = {
	"tiếng Lemnos",
	36203,
	"qfa-tyn",
	"Ital",
	translit = "Ital-translit",
	"Tiếng Lemnos",
	"Lemnos",
}

m["xlg"] = {
	"Ancient Ligurian",
	36104,
	"ine",
}

m["xli"] = {
	"Liburnian",
	35835,
	"ine",
}

--xln is etymology-only

m["xlo"] = {
	"Loup A",
	27921265,
	"alg-eas",
	"Latn",
}

m["xlp"] = {
	"tiếng Leponti",
	35993,
	"cel-con",
	"Ital",
	"Tiếng Leponti",
	"Leponti",
	translit = "Ital-translit",
}

m["xls"] = {
	"Lusitanian",
	35960,
	"ine",
	"Latn",
}

m["xlu"] = {
	"tiếng Luwi",
	12634577,
	"ine-luw",
	"Xsux, Hluw",
	"Tiếng Luwi",
	"Luwi",
}

m["xly"] = {
	"tiếng Elymi",
	35329,
	nil,
	"Grek",
	"Tiếng Elymi",
	"Elymi",
}

m["xmb"] = {
	"Mbonga",
	36064,
	"nic-jrn",
	"Latn",
}

m["xmc"] = {
	"Makhuwa-Marrevone",
	11127231,
	"bnt-mak",
	ancestors = "vmw",
}

m["xmd"] = {
	"Mbudum",
	6799790,
	"cdc-cbm",
	"Latn",
}

m["xmf"] = {
	"tiếng Mingrelia",
	13359,
	"ccs-zan",
	"Geor",
	"Tiếng Mingrelia",
	"Mingrelia",
	translit = "Geor-translit",
	override_translit = true,
}

m["xmg"] = {
	"Mengaka",
	36017,
	"bai",
	"Latn",
}

m["xmh"] = {
	"Kugu-Muminh",
	10549849,
	"aus-pmn",
	"Latn",
}

m["xmj"] = {
	"Majera",
	6737666,
	"cdc-cbm",
	"Latn",
}

m["xmk"] = {
	"tiếng Macedoni cổ đại",
	35974,
	"grk",
	"Polyt",
	"Tiếng Macedoni cổ đại",
	"Macedoni cổ đại",
	translit = "grc-translit",
	entry_name = s["Polyt-entryname"],
	sort_key = s["Grek-sortkey"],
}

m["xml"] = {
	"Malaysian Sign Language",
	33420,
	"sgn",
}

m["xmm"] = {
	"Manado Malay",
	1068112,
}

m["xmo"] = {
	"Morerebi",
	12953749,
	"tup",
	"Latn",
}

m["xmp"] = {
	"Kuku-Mu'inh",
	10549852,
	nil,
	"Latn",
}

m["xmq"] = {
	"Kuku-Mangk",
	10549851,
	"aus-pam",
	"Latn",
}

m["xmr"] = {
	"Meroitic",
	13366,
	"afa",
	"Mero, Merc, Latn", -- we have entries in Latn
	translit = "xmr-translit",
}

m["xms"] = {
	"Moroccan Sign Language",
	6913107,
	"sgn",
}

m["xmt"] = {
	"Matbat",
	6786187,
	"poz-hce",
}

m["xmu"] = {
	"Kamu",
	6359779,
}

m["xmx"] = {
	"Maden",
	12952756,
	"poz-hce",
}

m["xmy"] = {
	"Mayaguduna",
	3436736,
}

m["xmz"] = {
	"Mori Bawah",
	3324069,
	"poz-btk",
	"Latn",
}

m["xna"] = {
	"Ancient North Arabian",
	1472213,
	"sem-cen",
	"Narb",
	translit = "Narb-translit",
}

m["xnb"] = {
	"tiếng Kanakanavu",
	172244,
	"map-tsu",
	"Latn",
	"Tiếng Kanakanavu",
	"Kanakanavu",
}

m["xng"] = {
	"tiếng Mông Cổ trung đại",
	2582455,
	"xgn",
	"Mong, Phag, Hani, Arab, Armn",
	"Tiếng Mông Cổ trung đại",
	"Mông Cổ trung đại",
	translit = {Mong = "Mong-translit"},
	display_text = {Mong = s["Mong-displaytext"]},
	entry_name = {Mong = s["Mong-entryname"]},
	sort_key = {Hani = "Hani-sortkey"},
}

m["xnh"] = {
	"Kuanhua",
	6441084,
	"mkh-pal",
}

m["xni"] = {
	"Ngarigu",
	7022072,
	"aus-yuk",
}

m["xnk"] = {
	"Nganakarti",
	33087049,
}

m["xnn"] = {
	"Northern Kankanay", -- use this for now; correction must be "Northern Kankanaey"
	12953609,
	"phi",
}

-- "xno" IS TREATED AS "fro", SEE WT:LT

m["xnr"] = {
	"tiếng Kangra",
	2331560,
	"him",
	"Deva, Takr, fa-Arab",
	"Tiếng Kangra",
	"Kangra",
	ancestors = "doi",
	translit = {Deva = "hi-translit"},
}

m["xns"] = {
	"Kanashi",
	6360672,
	"sit-whm",
}

m["xnt"] = {
	"Narragansett",
	3336118,
	"alg-eas",
	"Latn, Hebr",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron},
}

m["xnu"] = {
	"Nukunul",
	7068904,
}

m["xny"] = {
	"Nyiyaparli",
	16919427,
	"aus-nga",
	"Latn",
}

m["xoc"] = {
	"O'chi'chi'",
	3813833,
	"nic-cde",
	"Latn",
}

m["xod"] = {
	"Kokoda",
	6426734,
	"ngf-sbh",
}

m["xog"] = {
	"Soga",
	33784,
	"bnt-nyg",
	"Latn",
}

m["xoi"] = {
	"Kominimung",
	6428352,
	"paa",
	"Latn",
}

m["xok"] = {
	"Xokleng",
	3027930,
	"sai-sje",
}

m["xom"] = {
	"tiếng Komo",
	56681,
	"ssa-kom",
	"Latn, Ethi",
	"Tiếng Komo",
	"Komo",
}

m["xon"] = {
	"Konkomba",
	35674,
	"nic-grm",
	"Latn",
}

m["xoo"] = { -- contrast kzw, sai-kat, sai-xoc
	"Xukurú",
	9096758,
}

m["xop"] = {
	"Kopar",
	11732346,
}

m["xor"] = {
	"Korubo",
	3199022,
}

m["xow"] = {
	"Kowaki",
	6434920,
	"ngf-mad",
}

m["xpa"] = {
	"Pirriya",
	16978087,
}

m["xpb"] = {
	"Pyemmairre",
	7262964,
	nil,
	"Latn",
}

m["xpc"] = {
	"tiếng Pecheneg",
	877881,
	"trk",
	nil,
	"Tiếng Pecheneg",
	"Pecheneg",
}

m["xpd"] = {
	"Paredarerme",
	7136678,
	nil,
	"Latn",
}

m["xpe"] = {
	"tiếng Kpelle Liberia",
	20527226,
	"dmn-msw",
	"Latn, Kpel",
	"Tiếng Kpelle Liberia",
	"Kpelle Liberia",
	ancestors = "kpe",
}

m["xpf"] = {
	"Southeast Tasmanian",
	7068421,
	nil,
	"Latn",
}

m["xpg"] = {
	"tiếng Phrygia",
	36751,
	"ine-grp",
	"Polyt, Latn",
	"Tiếng Phrygia",
	"Phrygia",
}

m["xph"] = {
	"Tyerrernotepanner",
	7859815,
	nil,
	"Latn",
}

m["xpi"] = {
	"Pictish",
	856383,
	"cel-brw",
	"Ogam, Latn",
}

m["xpj"] = {
	"Mpalitjanh",
	6928192,
	"aus-pam",
}

m["xpk"] = {
	"Kulina",
	6443027,
	"sai-pan",
}

m["xpl"] = {
	"Port Sorell",
	7230944,
	nil,
	"Latn",
}

m["xpm"] = {
	"tiếng Pumpokol",
	2991985,
	"qfa-yso",
	"Latn",
	"Tiếng Pumpokol",
	"Pumpokol",
}

m["xpn"] = {
	"Kapinawá",
	6366667,
}

m["xpo"] = {
	"Pochutec",
	2427341,
	"azc-nah",
	"Latn",
}

m["xpp"] = {
	"Puyo-Paekche",
	nil,
}

m["xpq"] = {
	"tiếng Mohegan-Pequot",
	3319130,
	"alg-eas",
	"Latn",
	"Tiếng Mohegan-Pequot",
	"Mohegan-Pequot",
}

m["xpr"] = {
	"tiếng Parthia",
	25953,
	"ira-mpr",
	"Prti, Mani, Phlv",
	"Tiếng Parthia",
	"Parthia",
	translit = {
		Prti = "Prti-translit",
		Mani = "Mani-translit",
	},
}

m["xps"] = {
	"Pisidian",
	36580,
	"ine-luw",
}

m["xpu"] = {
	"tiếng Punic",
	535958,
	"sem-can",
	"Phnx, Latn, Grek",
	"Tiếng Punic",
	"Punic",
	ancestors = "phn",
	translit = {Phnx = "Phnx-translit"},
}

m["xpv"] = {
	"Tommeginne",
	7819095,
	nil,
	"Latn",
}

m["xpw"] = {
	"Peerapper",
	7160431,
	nil,
	"Latn",
}

m["xpx"] = {
	"Toogee",
	7824008,
	nil,
	"Latn",
}

m["xpy"] = {
	"Buyeo",
	5003359,
	"qfa-kor",
	"Hani",
	sort_key = "Hani-sortkey",
}

m["xpz"] = {
	"Bruny Island",
	4979601,
	"qfa-unc",
	"Latn",
}

m["xqa"] = {
	"tiếng Karakhanid",
	4494885,
	"trk-kar",
	"Arab, Ougr",
	"Tiếng Karakhanid",
	"Karakhanid",
	strip_diacritics = "ar-stripdiacritics",
}

m["xqt"] = {
	"Qatabanian",
	384101,
	"sem-osa",
	"Sarb",
	translit = "Sarb-translit",
}

m["xra"] = {
	"Krahô",
	3199549,
	"sai-nje",
	"Latn",
}

m["xrb"] = {
	"Eastern Karaboro",
	35716,
	"alv-krb",
	"Latn",
}

m["xrd"] = {
	"Gundungurra",
	60611652,
	nil,
	"Latn",
}

m["xre"] = {
	"Kreye",
	3199686,
	"sai-nje",
}

m["xrg"] = {
	"Minang",
	22893424,
	"aus-pam",
	"Latn",
}

m["xri"] = {
	"Krikati-Timbira",
	3199710,
	"sai-nje",
	"Latn",
}

m["xrm"] = {
	"Armazic",
	7599646,
	"sem-ara",
	"Armi",
}

m["xrn"] = {
	"tiếng Arin",
	34088,
	"qfa-yso",
	"Latn",
	"Tiếng Arin",
	"Arin",
}

m["xrq"] = {
	"Karranga",
	6373349,
	nil,
	"Latn",
}

m["xrr"] = {
	"tiếng Raetia",
	36689,
	"qfa-tyn",
	"Ital",
	"Tiếng Raetia",
	"Raetia",
	translit = "Ital-translit",
}

m["xrt"] = {
	"Aranama-Tamique",
	2859505,
}

m["xru"] = {
	"Marriammu",
	10577724,
	"aus-dal",
	"Latn",
}

m["xrw"] = {
	"Karawa",
	6368857,
	"paa-sep",
	"Latn",
}

m["xsa"] = {
	"tiếng Saba",
	1070391,
	"sem-osa",
	"Sarb",
	"Tiếng Saba",
	"Saba",
	translit = "Sarb-translit",
}

m["xsb"] = {
	"tiếng Sambali",
	2592378,
	"phi",
	"Latn",
	"Tiếng Sambali",
	"Sambali",
}

m["xsd"] = {
	"Sidetic",
	36659,
	"ine-luw",
	"Sidt",
}

m["xse"] = {
	"Sempan",
	3504358,
}

m["xsh"] = {
	"Shamang",
	3914876,
	"nic-plc",
}

m["xsi"] = {
	"Sio",
	3485100,
	"poz-ocw",
}

m["xsj"] = {
	"Subi",
	7631298,
	"bnt-haj",
}

m["xsl"] = {
	"tiếng Nam Slavey",
	28552,
	"den",
	"Latn, Cans",
	"Tiếng Nam Slavey",
	"Nam Slavey",
}

m["xsm"] = {
	"Kasem",
	35552,
	"nic-gnn",
}

m["xsn"] = {
	"Sanga (Nigeria)",
	3915334,
	"nic-jer",
	"Latn",
}

m["xso"] = {
	"Solano",
	2474492,
	nil,
	"Latn",
}

m["xsp"] = {
	"Silopi",
	7515533,
	"ngf-mad",
}

m["xsq"] = {
	"Makhuwa-Saka",
	11008159,
	"bnt-mak",
	ancestors = "vmw",
}

m["xsr"] = {
	"tiếng Sherpa",
	36612,
	"sit-tib",
	"Tibt, Deva",
	"Tiếng Sherpa",
	"Sherpa",
	ancestors = "xct",
	translit = {
		Tibt = "Tibt-translit",
		Deva = "xsr-Deva-translit",
	},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["xss"] = {
	"tiếng Assan",
	34089,
	"qfa-yso",
	"Latn",
	"Tiếng Assan",
	"Assan",
}

m["xsu"] = {
	"Sanumá",
	251728,
	"sai-ynm",
}

m["xsv"] = {
	"Sudovian",
	35603,
	"bat-wes",
	"Latn",
}

m["xsy"] = {
	"tiếng Saisiyat",
	716695,
	"map",
	"Latn",
	"Tiếng Saisiyat",
	"Saisiyat",
}

m["xta"] = {
	"tiếng Mixtec Alcozauca",
	25559587,
	"omq-mxt",
	"Latn",
	"Tiếng Mixtec Alcozauca",
	"Mixtec Alcozauca",
}

m["xtb"] = {
	"Chazumba Mixtec",
	12182838,
	"omq-mxt",
	"Latn",
}

m["xtc"] = {
	"Kadugli",
	3407136,
	"qfa-kad",
	"Latn",
}

m["xtd"] = {
	"Diuxi-Tilantongo Mixtec",
	7802048,
	"omq-mxt",
	"Latn",
}

m["xte"] = {
	"Ketengban",
	10990152,
}

m["xth"] = {
	"Yitha Yitha",
	nil,
}

m["xti"] = {
	"Sinicahua Mixtec",
	12953733,
	"omq-mxt",
	"Latn",
}

m["xtj"] = {
	"San Juan Teita Mixtec",
	32093049,
	"omq-mxt",
	"Latn",
}

m["xtl"] = {
	"Tijaltepec Mixtec",
	12953738,
	"omq-mxt",
	"Latn",
}

m["xtm"] = {
	"Magdalena Peñasco Mixtec",
	7179700,
	"omq-mxt",
	"Latn",
}

m["xtn"] = {
	"Northern Tlaxiaco Mixtec",
	25559585,
	"omq-mxt",
	"Latn",
}

m["xto"] = {
	"tiếng Tochari A",
	2827041,
	"ine-toc",
	"Latn",
	"Tiếng Tochari A",
	"Tochari A",
	wikipedia_article = "Ngữ tộc Tochari", -- wikidata id has no associated article
}

m["xtp"] = {
	"San Miguel Piedras Mixtec",
	7414970,
	"omq-mxt",
	"Latn",
}

m["xtq"] = {
	"tiếng Tumshuq",
	nil,
	"xsc-sak",
	"Brah, Khar",
	"Tiếng Tumshuq",
	"Tumshuq",
	translit = "Brah-translit",
}

m["xtr"] = {
	"Early Tripuri",
	nil,
}

m["xts"] = {
	"Sindihui Mixtec",
	13583581,
	"omq-mxt",
	"Latn",
}

m["xtt"] = {
	"Tacahua Mixtec",
	7673668,
	"omq-mxt",
	"Latn",
}

m["xtu"] = {
	"Cuyamecalco Mixtec",
	12953726,
	"omq-mxt",
	"Latn",
}

m["xtv"] = {
	"Thawa",
	7711494,
}

m["xtw"] = {
	"Tawandê",
	nil,
	"sai-nmk",
	"Latn",
}

m["xty"] = {
	"Yoloxochitl Mixtec",
	8054817,
	"omq-mxt",
	"Latn",
}

m["xua"] = {
	"tiếng Kurumba Alu",
	12952679,
	"dra-kan",
	"Knda",
	"Tiếng Kurumba Alu",
	"Kurumba Alu",
	translit = {Knda = "kn-translit"},
}

m["xub"] = {
	"tiếng Kurumba Betta",
	16841033,
	"dra-kan",
	"Knda, Mlym, Taml",
	"Tiếng Kurumba Betta",
	"Kurumba Betta",
	translit = {
		Knda = "kn-translit",
		Mlym = "ml-translit",
		Taml = "ta-translit",
	},
}

m["xud"] = {
	"Umiida",
	61999874,
	"aus-wor",
	"Latn",
}

m["xug"] = {
	"tiếng Kunigami",
	56558,
	"jpx-nry",
	"Jpan",
	"Tiếng Kunigami",
	"Kunigami",
	translit = s["Jpan-translit"],
	sort_key = s["Jpan-sortkey"],
}

m["xuj"] = {
	"tiếng Kurumba Jennu",
	21282543,
	"dra-kan",
	"Knda, Taml",
	"Tiếng Kurumba Jennu",
	"Kurumba Jennu",
	translit = {
		Knda = "kn-translit",
		Taml = "ta-translit"
	},
}

m["xul"] = {
	"Ngunawal",
	7022712,
	"aus-yuk",
	"Latn",
}

m["xum"] = {
	"tiếng Umbria",
	36957,
	"itc-sbl",
	"Ital, Latn",
	"Tiếng Umbria",
	"Umbria",
	translit = "Ital-translit",
}

m["xun"] = {
	"Unggaranggu",
	61999823,
	"aus-wor",
	"Latn",
}

m["xuo"] = {
	"tiếng Kuo",
	6445233,
	"alv-mbm",
	"Latn",
	"Tiếng Kuo",
	"Kuo",
}

m["xup"] = {
	"Upper Umpqua",
	20607,
	"ath-pco",
	"Latn",
}

m["xur"] = {
	"tiếng Urartu",
	36934,
	"qfa-hur",
	"Xsux",
	"Tiếng Urartu",
	"Urartu",
}

m["xut"] = {
	"Kuthant",
	6448417,
}

m["xuu"] = {
	"Khwe",
	28305,
	"khi-kal",
	"Latn",
}

m["xve"] = {
	"tiếng Veneti",
	36871,
	"ine",
	"Ital",
	"Tiếng Veneti",
	"Veneti",
	translit = "Ital-translit",
}

-- m["xvi"] = { "Kamviri", 1193495, "nur-nor", Arab } moved to etym-only code

m["xvn"] = {
	"Vandalic",
	36835,
	"gme",
	"Latn",
}

m["xvo"] = {
	"tiếng Volsci",
	622110,
	"itc-sbl",
	"Latn",
	"Tiếng Volsci",
	"Volsci",
}

m["xvs"] = {
	"Vestinian",
	2576407,
	"itc",
	"Latn",
}

m["xwa"] = {
	"Kwaza",
	3200839,
}

m["xwc"] = {
	"Woccon",
	3569569,
	"nai-cat",
	"Latn",
}

m["xwd"] = {
	"Wadi Wadi",
	7959249,
}

m["xwe"] = {
	"Xwela Gbe",
	36887,
	"alv-pph",
}

m["xwg"] = {
	"Kwegu",
	56723,
	"sdv",
}

m["xwj"] = {
	"Wajuk",
	33110188,
}

m["xwk"] = {
	"Wangkumara",
	7967891,
	"aus-pam",
	"Latn",
}

m["xwl"] = {
	"Western Xwla Gbe",
	36924,
	"alv-pph",
	"Latn",
}

m["xwo"] = {
	"tiếng Oirat",
	56959,
	"xgn-cen",
	"xwo-Mong",
	"Tiếng Oirat",
	"Oirat",
	translit = "xwo-translit",
}

m["xwr"] = {
	"Kwerba Mamberamo",
	6450325,
	"paa-tkw",
}

m["xww"] = {
	"tiếng Wemba-Wemba",
	18472819,
	"aus-pam",
	"Latn",
	"Tiếng Wemba-Wemba",
	"Wemba-Wemba",
}

m["xxb"] = {
	"Boro",
	16844787,
	nil,
	"Latn",
}

m["xxk"] = {
	"Ke'o",
	3195346,
}

m["xxm"] = {
	"Minkin",
	6867836,
}

m["xxr"] = {
	"Koropó",
	6432560,
}

m["xxt"] = {
	"Tambora",
	36711,
	"paa",
	"Latn",
}

m["xya"] = {
	"Yaygir",
	8050525,
	"aus-pam",
}

m["xyb"] = {
	"Yandjibara",
	nil,
	nil,
	"Latn",
}

m["xyl"] = {
	"Yalakalore",
	12645352,
	"sai-nmk",
	"Latn",
}

m["xyt"] = {
	"Mayi-Thakurti",
	47004719,
	"aus-pam",
	"Latn",
}

m["xyy"] = {
	"Yorta Yorta",
	8055849,
	"aus-pam",
	"Latn",
}

m["xzh"] = {
	"Zhang-Zhung",
	3437292,
	"sit-alm",
	"Marc, Tibt",
	translit = {Tibt = "Tibt-translit"},
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["xzm"] = {
	"Zemgalian",
	47631,
	"bat-eas",
}

m["xzp"] = {
	"Ancient Zapotec",
	nil,
}

return require("Module:languages").finalizeData(m, "language")