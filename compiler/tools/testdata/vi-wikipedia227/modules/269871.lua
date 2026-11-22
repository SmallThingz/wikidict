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

m["kaa"] = {
	"tiếng Karakalpak",
	33541,
	"trk-kno",
	"Latn, Cyrl, fa-Arab",
	"Tiếng Karakalpak",
	"Karakalpak",
	dotted_dotless_i = true,
	entry_name = {
		from = {"['’]"},
		to = {"ʼ"}
	},
	sort_key = {
		Latn = {
			from = {
				-- Sort the old orthography (using the apostrophe) after the new orthography (using the acute accent).
				"í", "iʼ", "i", -- Ensure "i" comes after "í", "iʼ", "ı".
				"sh", "ch",
				"á", "aʼ", "ǵ", "gʼ", "x", p[4], p[5], "ı", "q", "ń", "nʼ", "ó", "oʼ", "ú", "uʼ", "c"
			},
			to = {
				p[4], p[5], "i" .. p[3],
				"z" .. p[1], "z" .. p[3],
				"a" .. p[1], "a" .. p[2], "g" .. p[1], "g" .. p[2], "h" .. p[1], "i", "i" .. p[1], "i" .. p[2], "k" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "o" .. p[2], "u" .. p[1], "u" .. p[2], "z" .. p[2]
			}
		},
		Cyrl = {
			from = {"ә", "ғ", "ё", "қ", "ң", "ө", "ү", "ў", "ҳ"},
			to = {"а" .. p[1], "г" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1], "у" .. p[2], "х" .. p[1]}
		},
	},
}

m["kab"] = {
	"tiếng Kabyle",
	35853,
	"ber",
	"Latn, Arab, Tfng",
	"Tiếng Kabyle",
	"Kabyle",
}

m["kac"] = {
	"tiếng Kachin",
	33332,
	"sit-jnp",
	"Latn, Mymr",
	"Tiếng Kachin",
	"Kachin",
}

m["kad"] = {
	"Kadara",
	3914011,
	"nic-plc",
	"Latn",
}

m["kae"] = {
	"Ketangalan",
	2779411,
	"map",
}

m["kaf"] = {
	"Katso",
	246122,
	"tbq-kzh",
}

m["kag"] = {
	"Kajaman",
	6348863,
	"poz",
	"Latn",
}

m["kah"] = {
	"Fer",
	5443742,
	"csu-bgr",
	"Latn",
}

m["kai"] = {
	"tiếng Karekare",
	3438770,
	"cdc-wst",
	"Latn",
	"Tiếng Karekare",
	"Karekare",
}

m["kaj"] = {
	"tiếng Jju",
	35401,
	"nic-plc",
	"Latn",
	"Tiếng Jju",
	"Jju",
}

m["kak"] = {
	"tiếng Kalanguya",
	3192220,
	"phi",
	"Latn",
	"Tiếng Kalanguya",
	"Kalanguya"
}

m["kam"] = {
	"Kamba",
	2574767,
	"bnt-kka",
	"Latn",
}

m["kao"] = {
	"Kassonke",
	36905,
	"dmn-wmn",
	"Latn",
}

m["kap"] = {
	"tiếng Bezhta",
	33054,
	"cau-ets",
	"Cyrl",
	"Tiếng Bezhta",
	"Bezhta",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["kaq"] = {
	"tiếng Capanahua",
	2937196,
	"sai-pan",
	"Latn",
	"Tiếng Capanahua",
	"Capanahua",
}

m["kaw"] = {
	"tiếng Java cổ",
	49341,
	"poz",
	"Latn, Java, Kawi",
	"Tiếng Java cổ",
	"Java cổ",
	translit = "jv-translit", --same as jv
}

m["kax"] = {
	"Kao",
	3192799,
	"paa-nha"
}

m["kay"] = {
	"Kamayurá",
	3192336,
	"tup-gua",
	"Latn",
}

m["kba"] = {
	"Kalarko",
	5517764,
	"aus-pam",
	"Latn",
}

m["kbb"] = {
	"Kaxuyana",
	12953626,
	"sai-prk",
	"Latn",
}

m["kbc"] = {
	"Kadiwéu",
	18168288,
	"sai-guc",
	"Latn",
}

m["kbd"] = {
	"tiếng Kabardia",
	33522,
	"cau-cir",
	"Cyrl, Latn, Arab",
	"Tiếng Kabardia",
	"Kabardia",
	translit = {
		Cyrl = "cau-cir-translit",
		Arab = "ar-translit",
	},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {
				"кхъу", "къӏу", -- 4 chars
				"гъу", "джу", "дзу", "жъу", "къу", "кхъ", "къӏ", "кӏу", "кӏь", "лъу", "лӏу", "пӏу", "сӏу", "тӏу", "фӏу", "хъу", "цӏу", "чъу", "чӏу", "шъу", "шӏу", "щӏу", -- 3 chars
				"гу", "гъ", "гь", "дж", "дз", "ё", "жъ", "жь", "ку", "къ", "кь", "кӏ", "лъ", "ль", "лӏ", "пӏ", "сӏ", "тӏ", "фӏ", "ху", "хъ", "хь", "цу", "цӏ", "чу", "чъ", "чӏ", "шъ", "шӏ", "щӏ", "ӏу", "ӏь", -- 2 chars
				"э" -- 1 char
			},
			to = {
				"к" .. p[5], "к" .. p[7],
				"г" .. p[3], "д" .. p[2], "д" .. p[4], "ж" .. p[2], "к" .. p[3], "к" .. p[4], "к" .. p[6], "к" .. p[10], "к" .. p[11], "л" .. p[2], "л" .. p[5], "п" .. p[2], "с" .. p[2], "т" .. p[2], "ф" .. p[2], "х" .. p[3], "ц" .. p[3], "ч" .. p[3], "ч" .. p[5], "ш" .. p[2], "ш" .. p[4], "щ" .. p[2],
				"г" .. p[1], "г" .. p[2], "г" .. p[4], "д" .. p[1], "д" .. p[3], "е" .. p[1], "ж" .. p[1], "ж" .. p[3], "к" .. p[1], "к" .. p[2], "к" .. p[8], "к" .. p[9], "л" .. p[1], "л" .. p[3], "л" .. p[4], "п" .. p[1], "с" .. p[1], "т" .. p[1], "ф" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[4], "ц" .. p[1], "ц" .. p[2], "ч" .. p[1], "ч" .. p[2], "ч" .. p[4], "ш" .. p[1], "ш" .. p[3], "щ" .. p[1], "ӏ" .. p[1], "ӏ" .. p[2],
				"а" .. p[1]
			}
		},
	},
}

m["kbe"] = {
	"Kanju",
	10543322,
	"aus-pam",
	"Latn",
}

m["kbg"] = {
	"tiếng Khamba",
	12952626,
	"sit-tib",
	"Tibt",
	"Tiếng Khamba",
	"Khamba",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["kbh"] = {
	"Camsá",
	2842667,
	"qfa-iso",
	"Latn",
}

m["kbi"] = {
	"Kaptiau",
	6367294,
	"poz-oce",
	"Latn",
}

m["kbj"] = {
	"Kari",
	6370438,
	"bnt-boa",
	"Latn",
}

m["kbk"] = {
	"Grass Koiari",
	12952642,
	"ngf",
	"Latn",
}

m["kbm"] = {
	"Iwal",
	3156391,
	"poz-ocw",
	"Latn",
}

m["kbn"] = {
	"Kare (Africa)",
	35554,
	"alv-mbm",
	"Latn",
}

m["kbo"] = {
	"tiếng Keliko",
	11275553,
	"csu-mma",
	"Latn",
	"Tiếng Keliko",
	"Keliko",
}

m["kbp"] = {
	"tiếng Kabiye",
	35475,
	"nic-gne",
	"Latn",
	"Tiếng Kabiye",
	"Kabiye",
}

m["kbq"] = {
	"Kamano",
	11732272,
	"paa-kag",
	"Latn",
}

m["kbr"] = {
	"tiếng Kafa",
	35481,
	"omv-gon",
	"Ethi, Latn",
	"Tiếng Kafa",
	"Kafa",
}

m["kbs"] = {
	"Kande",
	35556,
	"bnt-tso",
	"Latn",
}

m["kbt"] = {
	"Gabadi",
	3291159,
	"poz-ocw",
	"Latn",
}

m["kbu"] = {
	"Kabutra",
	10966761,
	"inc-wes",
	ancestors = "raj",
}

m["kbv"] = {
	"Kamberataro",
	5261289,
	"paa",
	"Latn",
}

m["kbw"] = {
	"Kaiep",
	6347632,
	"poz-ocw",
	"Latn",
}

m["kbx"] = {
	"Ap Ma",
	56298,
	"paa-ram",
}

m["kbz"] = {
	"Duhwa",
	56295,
	"cdc-wst",
	"Latn",
}

m["kca"] = {
	"tiếng Khanty",
	33563,
	"urj-ugr",
	"Cyrl",
	"Tiếng Khanty",
	"Khanty",
	translit = "kca-translit",
	override_translit = true,
}

m["kcb"] = {
	"Kawacha",
	11732302,
	"ngf",
}

m["kcc"] = {
	"Lubila",
	3914381,
	"nic-uce",
	"Latn",
}

m["kcd"] = {
	"Ngkâlmpw Kanum",
	12952566,
	"paa-yam",
}

m["kce"] = {
	"Kaivi",
	6348685,
	"nic-kau",
}

m["kcf"] = {
	"Ukaan",
	36651,
	"nic-bco",
}

m["kcg"] = {
	"tiếng Tyap",
	3912765,
	"nic-plc",
	"Latn",
	"Tiếng Tyap",
	"Tyap",
}

m["kch"] = {
	"Vono",
	3913920,
	"nic-kau",
}

m["kci"] = {
	"Kamantan",
	3914019,
	"nic-plc",
}

m["kcj"] = {
	"Kobiana",
	35609,
	"alv-nyn",
}

m["kck"] = {
	"Kalanga",
	33672,
	"bnt-sho",
	"Latn",
}

m["kcl"] = {
	"Kala",
	6349982,
	"poz-ocw",
	"Latn",
}

m["kcm"] = {
	"Tar Gula",
	277963,
	"csu-bba",
}

m["kcn"] = {
	"tiếng Nubi",
	36388,
	"crp",
	"Latn, Arab",
	"Tiếng Nubi",
	"Nubi",
	ancestors = "apd",
	entry_name = {remove_diacritics = c.acute},
}

m["kco"] = {
	"Kinalakna",
	11732320,
	"ngf",
}

m["kcp"] = {
	"Kanga",
	6362384,
	"qfa-kad",
	"Latn",
}

m["kcq"] = {
	"Kamo",
	3914879,
	"alv-wjk",
}

m["kcr"] = {
	"Katla",
	35688,
	"nic-ktl",
}

m["kcs"] = {
	"Koenoem",
	3438755,
	"cdc-wst",
}

m["kct"] = {
	"Kaian",
	6347538,
	"paa-ram",
}

m["kcu"] = {
	"Kikami",
	3915212,
	"bnt-ruv",
	"Latn",
}

m["kcv"] = {
	"Kete",
	3195598,
	"bnt-lub",
}

m["kcw"] = {
	"Kabwari",
	6344539,
	"bnt-glb",
}

m["kcx"] = {
	"tiếng Kachama-Ganjule",
	12634070,
	"omv-eom",
	"Latn",
	"Tiếng Kachama-Ganjule",
	"Kachama-Ganjule",
}

m["kcy"] = {
	"Korandje",
	33427,
	"son",
}

m["kcz"] = {
	"Konongo",
	11732345,
	"bnt-tkm",
	"Latn",
}

m["kda"] = {
	"Worimi",
	3914062,
	"aus-pam",
	"Latn",
}

m["kdc"] = {
	"Kutu",
	6448634,
	"bnt-ruv",
}

m["kdd"] = {
	"Yankunytjatjara",
	34207,
	"aus-pam",
	"Latn",
}

m["kde"] = {
	"Makonde",
	35172,
	"bnt-rvm",
	"Latn",
}

m["kdf"] = {
	"Mamusi",
	6746036,
	"poz-ocw",
	"Latn",
}

m["kdg"] = {
	"Seba",
	7442316,
	"bnt-sbi",
	"Latn",
}

m["kdh"] = {
	"tiếng Tem",
	36531,
	"nic-gne",
	"Latn, Arab",
	"Tiếng Tem",
	"Tem",
}

m["kdi"] = {
	"Kumam",
	6443410,
	"sdv-los",
}

m["kdj"] = {
	"Karamojong",
	56326,
	"sdv-ttu",
	"Latn",
}

m["kdk"] = {
	"Numee",
	3346774,
	"poz-cln",
}

m["kdl"] = {
	"Tsikimba",
	3914404,
	"nic-kam",
}

m["kdm"] = {
	"Kagoma",
	3914420,
	"nic-plc",
}

m["kdn"] = {
	"Kunda",
	4121130,
	"bnt-sna",
}

m["kdp"] = {
	"Kaningdon-Nindem",
	3914956,
	"nic-nin",
}

m["kdq"] = {
	"tiếng Koch",
	56431,
	"tbq-bdg",
	"as-Beng, Latn",
	"Tiếng Koch",
	"Koch",
}

m["kdr"] = {
	"tiếng Karaim",
	33725,
	"trk-kcu",
	"Cyrl, Latn, Hebr",
	"Tiếng Karaim",
	"Karaim",
	translit = "kdr-translit",
}

m["kdt"] = {
	"tiếng Kuy",
	56310,
	"mkh-kat",
	"Thai, Khmr, Laoo",
	"Tiếng Kuy",
	"Kuy",
}

m["kdu"] = {
	"Kadaru",
	35441,
	"nub-hil",
	"Latn",
}

m["kdv"] = {
	"Kado",
	7402721,
	"sit-luu",
}

m["kdw"] = {
	"Koneraw",
	11732341,
	"ngf",
}

m["kdx"] = {
	"Kam",
	36753,
	"alv-wjk",
}

m["kdy"] = {
	"Keder",
	6383641,
	"paa-tkw",
}

m["kdz"] = {
	"Kwaja",
	11128866,
	"nic-nka",
	"Latn",
}

m["kea"] = {
	"tiếng Kabuverdianu",
	35963,
	"crp",
	"Latn",
	"Tiếng Kabuverdianu",
	"Kabuverdianu",
	ancestors = "pt",
}

m["keb"] = {
	"Kélé",
	35559,
	"bnt-kel",
}

m["kec"] = {
	"Keiga",
	3409311,
	"qfa-kad",
	"Latn",
}

m["ked"] = {
	"Kerewe",
	6393846,
	"bnt-haj",
}

m["kee"] = {
	"Eastern Keres",
	15649021,
	"nai-ker",
	"Latn",
}

m["kef"] = {
	"Kpessi",
	35748,
	"alv-gbe",
}

m["keg"] = {
	"Tese",
	16887296,
	"sdv",
}

m["keh"] = {
	"Keak",
	6382110,
	"paa-spk",
}

m["kei"] = {
	"Kei",
	2410352,
}

m["kej"] = {
	"tiếng Kadar",
	6345179,
	"dra-mal",
	"Mlym",
	"Tiếng Kadar",
	"Kadar",
	translit = "ml-translit",
}

m["kek"] = {
	"Q'eqchi",
	35536,
	"myn",
	"Latn",
}

m["kel"] = {
	"Kela-Yela",
	6385426,
	"bnt-mon",
	"Latn",
}

m["kem"] = {
	"Kemak",
	35549,
	"poz-tim",
}

m["ken"] = {
	"tiếng Kenyang",
	35650,
	"nic-mam",
	"Latn",
	"Tiếng Kenyang",
	"Kenyang",
}

m["keo"] = {
	"Kakwa",
	3033547,
	"sdv-bri",
}

m["kep"] = {
	"tiếng Kaikadi",
	6347757,
	"dra-tam",
	"Taml",
	"Tiếng Kaikadi",
	"Kaikadi",
	translit = "ta-translit",
}

m["keq"] = {
	"Kamar",
	14916877,
	"inc-eas",
}

m["ker"] = {
	"Kera",
	56251,
	"cdc-est",
	"Latn",
}

m["kes"] = {
	"Kugbo",
	3813394,
	"nic-cde",
	"Latn",
}

m["ket"] = {
	"tiếng Ket",
	33485,
	"qfa-yno",
	"Cyrl",
	"Tiếng Ket",
	"Ket",
	entry_name = {
		from = {"['’]"},
		to = {"ʼ"}
	},
	sort_key = {
		from = {"ӷ", "ё", "ӄ", "ӈ", "ө", "ә", "ʼ"},
		to = {"г" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "ъ" .. p[1], "ь" .. p[1]}
	},
}

m["keu"] = {
	"Akebu",
	35026,
	"alv-ktg",
}

m["kev"] = {
	"tiếng Kanikkaran",
	6363201,
	"dra-mal",
	"Mlym, Taml",
	"Tiếng Kanikkaran",
	"Kanikkaran",
	translit = {
		Mlym = "ml-translit",
		Taml = "ta-translit"
	}
}

m["kew"] = {
	"Kewa",
	12952619,
	"paa-eng",
	"Latn",
}

m["kex"] = {
	"tiếng Kukna",
	5031131,
	"inc-eas",
	"Gujr, Deva",
	"Tiếng Kukna",
	"Kukna",
	ancestors = "bh",
}

m["key"] = {
	"tiếng Kupia",
	6445354,
	"inc-eas",
	"Telu, Orya",
	"Tiếng Kupia",
	"Kupia",
	translit = { Telu = "te-translit" }
}

m["kez"] = {
	"Kukele",
	3915391,
	"nic-ucn",
	"Latn",
}

m["kfa"] = {
	"tiếng Kodava",
	33531,
	"dra-kod",
	"Knda, Mlym",
	"Tiếng Kodava",
	"Kodava",
	translit = {
		Knda = "kn-translit",
		Mlym = "ml-translit"
	},
}

m["kfb"] = {
	"tiếng Kolami",
	33479,
	"dra-knk",
	"Deva, Telu,",
	"Tiếng Kolami",
    "Kolami",
	translit = {
		Telu = "te-translit",
	},
}

m["kfc"] = {
	"tiếng Konda-Dora",
	35679,
	"dra-kki",
	"Orya, Telu",
	"Tiếng Konda-Dora",
	"Konda-Dora",
	translit = {
		Orya = "gon-Orya-translit",
		Telu = "te-translit",
	},
}

m["kfd"] = {
	"tiếng Koraga Korra",
	12952655,
	"dra-kor",
	"Knda",
	"Tiếng Koraga Korra",
	"Koraga Korra",
	translit = "kn-translit",
}

m["kfe"] = {
	"tiếng Kota (Ấn Độ)",
	33483,
	"dra-tkt",
	"Taml",
	"Tiếng Kota (Ấn Độ)",
	"Kota (Ấn Độ)",
	translit = "ta-translit",
}

m["kff"] = {
	"tiếng Koya",
	33471,
	"dra-gon",
	"Orya, Telu, Deva",
	"Tiếng Koya",
	"Koya",
}

m["kfg"] = {
	"tiếng Kudiya",
	12952667,
	"dra-tlk",
	"Knda, Mlym",
	"Tiếng Kudiya",
	"Kudiya",
	translit = {
		Knda = "kn-translit",
		Mlym = "ml-translit",
	}
}

m["kfh"] = {
	"tiếng Kurichiya",
	12952676,
	"dra-mal",
	"Mlym",
	"Tiếng Kurichiya",
	"Kurichiya",
	translit = "ml-translit",
}

m["kfi"] = {
	"tiếng Kurumba Kannada",
	56589,
	"dra-sdo",
	"Taml, Knda",
	"Tiếng Kurumba Kannada",
	"Kurumba Kannada",
	translit = {
		Knda = "kn-translit",
		Taml = "ta-translit",
	}
}

m["kfj"] = {
	"Kemiehua",
	27144776,
	"mkh-pal",
}

m["kfk"] = {
	"tiếng Kinnaur",
	2383208,
	"sit-kin",
	"Takr, Deva, Latn",
	"Tiếng Kinnaur",
	"Kinnaur",
}

m["kfl"] = {
	"Kung",
	6444510,
	"nic-rnc",
	"Latn",
}

m["kfn"] = {
	"Kuk",
	6442398,
	"nic-rnc",
	"Latn",
}

m["kfo"] = {
	"Koro (West Africa)",
	11160588,
	"dmn-mnk",
	"Latn, Nkoo",
}

m["kfp"] = {
	"tiếng Korwa",
	6432786,
	"mun",
	"Latn",
	"Tiếng Korwa",
	"Korwa",
}

m["kfq"] = {
	"tiếng Korku",
	33715,
	"mun",
	"Deva",
	"Tiếng Korku",
	"Korku",
}

m["kfr"] = {
	"tiếng Kutch",
	56487,
	"inc-snd",
	"Gujr, sd-Arab, Sind, Khoj",
	"Tiếng Kutch",
	"Kutch",
	translit = {
		Gujr = "gu-translit",
		Sind = "Sind-translit",
	},
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		from = {u(0x0671)},
		to = {u(0x0627)}
	},
}

m["kfs"] = {
	"tiếng Bilaspur",
	12953397,
	"him",
	"Deva, Takr",
	translit = {
		Deva = "hi-translit",
	},
	"Tiếng Bilaspur",
	"Bilaspur",
}

m["kft"] = {
	"Kanjari",
	12953610,
	"inc-pan",
	ancestors = "pa",
}

m["kfu"] = {
	"Katkari",
	6377671,
	"inc-sou",
}

m["kfv"] = {
	"Kurmukar",
	6446193,
	"inc-eas",
}

m["kfw"] = {
	"Kharam Naga",
	12952906,
	"tbq-kuk",
}

m["kfx"] = {
	"tiếng Kullu",
	6443148,
	"him",
	"Deva, Takr",
	"Tiếng Kullu",
	"Kullu",
	translit = {Deva = "hi-translit"},
}

m["kfy"] = {
	"tiếng Kumaon",
	33529,
	"inc-pah",
	"Deva, Shrd, Takr",
	"Tiếng Kumaon",
	"Kumaon",
}

m["kfz"] = {
	"Koromfé",
	35701,
	"nic-gur",
	"Latn",
}

m["kga"] = {
	"Koyaga",
	11155632,
	"dmn-mnk",
}

m["kgb"] = {
	"Kawe",
	12952750,
	"poz-hce",
}

m["kgd"] = {
	"Kataang",
	12953622,
	"mkh",
}

m["kge"] = {
	"Komering",
	49224,
	"poz-lgx",
}

m["kgf"] = {
	"Kube",
	11732359,
	"ngf",
}

m["kgg"] = {
	"Kusunda",
	33630,
	"qfa-iso",
	"Latn",
}

m["kgi"] = {
	"Selangor Sign Language",
	33731,
	"sgn",
}

m["kgj"] = {
	"tiếng Kham Gamale",
	22236996,
	"sit-kha",
	"Deva",
	"Tiếng Kham Gamale",
	"Kham Gamale"
}

m["kgk"] = {
	"Kaiwá",
	3111883,
	"tup-gua",
	"Latn",
}

m["kgl"] = {
	"Kunggari",
	10550184,
	"aus-pam",
}

m["kgm"] = {
	"Karipúna",
	6371069,
}

m["kgn"] = {
	"Karingani",
	6371041,
	"xme-ttc",
	ancestors = "xme-ttc-nor",
}

m["kgo"] = {
	"Krongo",
	6438927,
	"qfa-kad",
	"Latn",
}

m["kgp"] = {
	"tiếng Kaingang",
	2665734,
	"sai-sje",
	"Latn",
	"Tiếng Kaingang",
	"Kaingang",
}

m["kgq"] = {
	"Kamoro",
	6359001,
	"ngf",
}

m["kgr"] = {
	"Abun",
	56657,
	"paa",
}

m["kgs"] = {
	"Kumbainggar",
	3915412,
	"aus-pam",
}

m["kgt"] = {
	"Somyev",
	3913354,
	"nic-mmb",
	"Latn",
}

m["kgu"] = {
	"Kobol",
	11732325,
	"ngf-mad",
}

m["kgv"] = {
	"Karas",
	6368621,
	"ngf",
}

m["kgw"] = {
	"Karon Dori",
	56817,
}

m["kgx"] = {
	"Kamaru",
	12953604,
	"poz",
}

m["kgy"] = {
	"Kyerung",
	12952691,
	"sit-kyk",
}

m["kha"] = {
	"tiếng Khasi",
	33584,
	"aav-pkl",
	"Latn, as-Beng",
	"Tiếng Khasi",
	"Khasi",
}

m["khb"] = {
	"tiếng Lự",
	36948,
	"tai-swe",
	"Talu, Lana",
	"Tiếng Lự",
	"Lự",
	translit = {Talu = "Talu-translit"},
	entry_name = {remove_diacritics = c.ZWNJ},
	sort_key = {
		Talu = "Talu-sortkey",
		Lana = "Lana-sortkey",
	},
}

m["khc"] = {
	"tiếng Tukang Besi Bắc",
	18611555,
	"poz-mun",
	"Latn",
	"Tiếng Tukang Besi Bắc",
	"Tukang Besi Bắc"
}

m["khd"] = {
	"Bädi Kanum",
	20888004,
	"paa-yam",
}

m["khe"] = {
	"Korowai",
	6432598,
	"ngf",
}

m["khf"] = {
	"tiếng Khuen",
	27144893,
	"mkh-khm",
	"Thai",
	"Tiếng Khuen",
	"Khuen",
}

m["khg"] = {
	"tiếng Tây Tạng Kham",
	56601,
	"sit-tib",
	"Tibt",
	"Tiếng Tây Tạng Kham",
	"Tây Tạng Kham",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["khh"] = {
	"Kehu",
	10994953,
}

m["khj"] = {
	"Kuturmi",
	3914490,
	"nic-plc",
	"Latn",
}

m["khl"] = {
	"Lusi",
	3267788,
	"poz-ocw",
	"Latn",
}

m["khn"] = {
	"Khandeshi",
	33726,
	"inc-sou",
}

m["kho"] = {
	"tiếng Khotan",
	6583551,
	"xsc-sak",
	"Brah, Khar",
	"Tiếng Khotan",
	"Khotan",
	translit = "Brah-translit",
}

m["khp"] = {
	"Kapauri",
	3502575,
	"paa-tkw",
}

m["khq"] = {
	"Koyra Chiini",
	33600,
	"son",
}

m["khr"] = {
	"tiếng Kharia",
	3915562,
	"mun",
	"Deva, Orya, Latn",
	"Tiếng Kharia",
	"Kharia",
	translit = {Deva = "hi-translit"},
}

m["khs"] = {
	"Kasua",
	6374863,
	"ngf",
}

m["kht"] = {
	"tiếng Khamti",
	3915502,
	"tai-swe",
	"Mymr",
	"Tiếng Khamti",
	"Khamti",
	entry_name = {remove_diacritics = c.VS01},
}

m["khu"] = {
	"Nkhumbi",
	11019169,
	"bnt-swb",
}

m["khv"] = {
	"tiếng Khvarshi",
	56425,
	"cau-wts",
	"Cyrl",
	translit = "khv-translit",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
	"Tiếng Khvarshi",
	"Khvarshi",
}

m["khw"] = {
	"tiếng Khowar",
	938216,
	"inc-chi",
	"Arab",
	"Tiếng Khowar",
	"Khowar",
}

m["khx"] = {
	"Kanu",
	12952571,
	"bnt-lgb",
}

m["khy"] = {
	"Ekele",
	6385549,
	"bnt-ske",
	"Latn",
}

m["khz"] = {
	"Keapara",
	12952603,
	"poz-ocw",
	"Latn",
}

m["kia"] = {
	"tiếng Kim",
	35685,
	"alv-kim",
	"Latn",
	"Tiếng Kim",
	"Kim",
}

m["kib"] = {
	"tiếng Koalib",
	35859,
	"alv-hei",
	"Latn",
	"Tiếng Koalib",
	"Koalib",
}

m["kic"] = {
	"tiếng Kickapoo",
	20162127,
	"alg-sfk",
	"Latn",
	"Tiếng Kickapoo",
	"Kickapoo",
}

m["kid"] = {
	"Koshin",
	35632,
	"nic-beb",
	"Latn",
}

m["kie"] = {
	"Kibet",
	56893,
}

m["kif"] = {
	"tiếng Kham Parbate Đông",
	12953022,
	"sit-kha",
	"Deva",
	"Tiếng Kham Parbate Đông",
	"Kham Parbate Đông",
}

m["kig"] = {
	"Kimaama",
	11732321,
	"ngf",
}

m["kih"] = {
	"Kilmeri",
	6408020,
	"paa-brd",
}

m["kii"] = {
	"Kitsai",
	56627,
	"cdd",
	"Latn",
}

m["kij"] = {
	"Kilivila",
	3196601,
	"poz-ocw",
	"Latn",
}

m["kil"] = {
	"Kariya",
	3438708,
	"cdc-wst",
}

m["kim"] = {
	"tiếng Tofa",
	36848,
	"trk-ssb",
	"Cyrl",
	"Tiếng Tofa",
	"Tofa",
	translit = {Cyrl = "kim-translit"},
}

m["kio"] = {
	"tiếng Kiowa",
	56631,
	"nai-kta",
	"Latn",
	"Tiếng Kiowa",
	"Kiowa",
}

m["kip"] = {
	"tiếng Kham Sheshi",
	12952622,
	"sit-kha",
	"Deva",
	"Tiếng Kham Sheshi",
	"Kham Sheshi",
}

m["kiq"] = {
	"Kosadle",
	6432994,
}

m["kis"] = {
	"Kis",
	6416362,
	"poz-ocw",
	"Latn",
}

m["kit"] = {
	"Agob",
	3332143,
}

m["kiv"] = {
	"Kimbu",
	10997740,
	"bnt-tkm",
}

m["kiw"] = {
	"Northeast Kiwai",
	11732324,
	"paa-kiw",
}

m["kix"] = {
	"tiếng Khiamniungan",
	6401546,
	"sit-kch",
	"Latn",
	"Tiếng Khiamniungan",
	"Khiamniungan",
}

m["kiy"] = {
	"Kirikiri",
	6415159,
	"paa-lkp",
}

m["kiz"] = {
	"Kisi",
	3912772,
	"bnt-bki",
}

m["kja"] = {
	"Mlap",
	6885683,
	"paa-nim",
}

m["kjb"] = {
	"Q'anjob'al",
	35551,
	"myn",
	"Latn",
}

m["kjc"] = {
	"Coastal Konjo",
	3198689,
	"poz",
}

m["kjd"] = {
	"Southern Kiwai",
	11732322,
	"paa-kiw",
}

m["kje"] = {
	"Kisar",
	3197441,
	"poz",
}

m["kjg"] = {
	"tiếng Khơ Mú",
	33335,
	"mkh-khm",
	"Laoo",
	"Tiếng Khơ Mú",
	"Khơ Mú",
	sort_key = "Laoo-sortkey",
}

m["kjh"] = {
	"tiếng Khakas",
	33575,
	"trk-ssb",
	"Cyrl",
	"Tiếng Khakas",
	"Khakas",
	translit = "kjh-translit",
	override_translit = true,
}

m["kji"] = {
	"Zabana",
	379130,
	"poz-ocw",
	"Latn",
}

m["kjj"] = {
	"tiếng Khinalug",
	35278,
	"cau-nec",
	"Cyrl, Latn",
	"Tiếng Khinalug",
	"Khinalug",
	translit = "kjj-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
}

m["kjk"] = {
	"Highland Konjo",
	3198688,
	"poz",
}

m["kjl"] = {
	"tiếng Kham Parbate Tây",
	22237017,
	"sit-kha",
	"Deva",
	"Tiếng Kham Parbate Tây",
	"Kham Parbate Tây",
}

m["kjm"] = {
	"tiếng Kháng",
	6403501,
	"mkh-pal",
	nil,
	"Tiếng Kháng",
	"Kháng",
}

m["kjn"] = {
	"Kunjen",
	3200468,
	"aus-pmn",
	"Latn",
}

m["kjo"] = {
	"tiếng Kinnaur Harija",
	5657463,
	"him",
	"Deva, Takr",
	"Tiếng Kinnaur Harija",
	"Kinnaur Harija",
}

m["kjp"] = {
	"tiếng Pwo Đông",
	5330390,
	"kar",
	"Mymr, Leke, Thai",
	"Tiếng Pwo Đông",
	"Pwo Đông",
}

m["kjq"] = {
	"Western Keres",
	12645568,
	"nai-ker",
	"Latn",
}

m["kjr"] = {
	"Kurudu",
	12952678,
	"poz-hce",
	"Latn",
}

m["kjs"] = {
	"East Kewa",
	20050949,
	"paa-eng",
}

m["kjt"] = {
	"tiếng Pwo Phrae",
	7187991,
	"kar",
	"Thai",
	"Tiếng Pwo Phrae",
	"Pwo Phrae",
}

m["kju"] = {
	"tiếng Kashaya",
	3193689,
	"nai-pom",
	"Latn",
	"Tiếng Kashaya",
	"Kashaya",
}

m["kjx"] = {
	"Ramopa",
	56830,
	"paa-nbo",
}

m["kjy"] = {
	"Erave",
	12952416,
	"paa-eng",
}

m["kjz"] = {
	"tiếng Bumthang",
	2786408,
	"sit-ebo",
	"Tibt",
	"Tiếng Bumthang",
	"Bumthang",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["kka"] = {
	"Kakanda",
	3915342,
	"alv-ngb",
}

m["kkb"] = {
	"Kwerisa",
	56881,
	"paa-lkp",
}

m["kkc"] = {
	"Odoodee",
	12952987,
}

m["kkd"] = {
	"Kinuku",
	6414422,
	"nic-kau",
}

m["kke"] = {
	"Kakabe",
	3913966,
	"dmn-mok",
	"Latn",
}

m["kkf"] = {
	"Kalaktang Monpa",
	63257089,
	"sit-tsk",
	"Tibt, Latn, Deva",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["kkg"] = {
	"Mabaka Valley Kalinga",
	18753304,
	"phi",
}

m["kkh"] = {
	"tiếng Khün",
	3545044,
	"tai-swe",
	"Lana, Thai",
	"Tiếng Khün",
	"Khün",
	sort_key = {
		Lana = "Lana-sortkey",
		Thai = "Thai-sortkey"
	},
}

m["kki"] = {
	"Kagulu",
	12952537,
	"bnt-ruv",
	"Latn",
}

m["kkj"] = {
	"Kako",
	35755,
	"bnt-kak",
}

m["kkk"] = {
	"Kokota",
	3198399,
	"poz-ocw",
	"Latn",
}

m["kkl"] = {
	"Kosarek Yale",
	6432995,
	"ngf",
}

m["kkm"] = {
	"Kiong",
	6414512,
	"nic-ucr",
	"Latn",
}

m["kkn"] = {
	"Kon Keu",
	6428686,
	"mkh-pal",
}

m["kko"] = {
	"Karko",
	35529,
	"nub-hil",
}

m["kkp"] = {
	"Koko-Bera",
	6426699,
	"aus-pmn",
	"Latn",
}

m["kkq"] = {
	"Kaiku",
	6347840,
	"bnt-kbi",
	"Latn",
}

m["kkr"] = {
	"Kir-Balar",
	3440527,
	"cdc-wst",
	"Latn",
}

m["kks"] = {
	"Kirfi",
	56242,
	"cdc-wst",
	"Latn",
}

m["kkt"] = {
	"Koi",
	6426194,
	"sit-kiw",
}

m["kku"] = {
	"Tumi",
	3913934,
	"nic-kau",
}

m["kkv"] = {
	"tiếng Kangean",
	2071325,
	"poz-msa",
	"Latn",
	"Tiếng Kangean",
	"Kangean"
}

m["kkw"] = {
	"Teke-Kukuya",
	36560,
	"bnt-tek",
}

m["kkx"] = {
	"Kohin",
	6425997,
	"poz-brw",
}

m["kky"] = {
	"tiếng Guugu Yimidhirr",
	56543,
	"aus-pam",
	"Latn",
	"Tiếng Guugu Yimidhirr",
	"Guugu Yimidhirr",
}

m["kkz"] = {
	"Kaska",
	20823,
	"ath-nor",
	"Latn",
}

m["kla"] = {
	"Klamath-Modoc",
	2669248,
	"nai-plp",
	"Latn",
}

m["klb"] = {
	"Kiliwa",
	3182593,
	"nai-yuc",
	"Latn",
}

m["klc"] = {
	"Kolbila",
	6427122,
	"alv-lek",
}

m["kld"] = {
	"tiếng Gamilaraay",
	3111818,
	"aus-cww",
	"Latn",
	"Tiếng Gamilaraay",
	"Gamilaraay",
}

m["kle"] = {
	"Kulung",
	6443304,
	"sit-kic",
}

m["klf"] = {
	"Kendeje",
	56895,
}

m["klg"] = {
	"Tagakaulu Kalagan",
	18756514,
	"phi",
}

m["klh"] = {
	"Weliki",
	7981017,
	"ngf-fin",
	"Latn",
}

m["kli"] = {
	"Kalumpang",
	13561407,
	"poz",
}

m["klj"] = {
	"tiếng Khalaj",
	33455,
	"trk",
	"fa-Arab, Latn",
	"Tiếng Khalaj",
	"Khalaj",
	ancestors = "klj-arg",
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun,
	}
}

m["klk"] = {
	"Kono (Nigeria)",
	6429589,
	"nic-kau",
	"Latn",
}

m["kll"] = {
	"Kagan Kalagan",
	18748913,
	"phi",
}

m["klm"] = {
	"Kolom",
	6844970,
	"ngf-mad",
	"Latn",
}

m["kln"] = {
	"Kalenjin",
	637228,
	"sdv-nma",
	"Latn",
}

m["klo"] = {
	"Kapya",
	6367410,
	"nic-ykb",
}

m["klp"] = {
	"Kamasa",
	6356107,
	"ngf",
}

m["klq"] = {
	"Rumu",
	7379420,
	"ngf",
}

m["klr"] = {
	"tiếng Khaling",
	56381,
	"sit-kiw",
	"Deva",
	"Tiếng Khaling",
	"Khaling",
}

m["kls"] = {
	"tiếng Kalash",
	33416,
	"inc-chi",
	"Latn, ks-Arab",
	"Tiếng Kalash",
	"Kalash",
}

m["klt"] = {
	"Nukna",
	7068874,
	"ngf-fin",
	"Latn",
}

m["klu"] = {
	"Klao",
	3914866,
	"kro-wkr",
}

m["klv"] = {
	"tiếng Maskelynes",
	3297282,
	"poz-vnc",
	"Latn",
	"Tiếng Maskelynes",
	"Maskelynes",
}

m["klw"] = {
	"tiếng Lindu",
	18390055,
	"poz-kal",
	"Latn",
	"Tiếng Lindu",
	"Lindu"
}

m["klx"] = {
	"Koluwawa",
	6427954,
	"poz-ocw",
	"Latn",
}

m["kly"] = {
	"tiếng Kalao",
	6350643,
	"poz",
	"Latn",
	"Tiếng Kalao",
	"Kalao"
}

m["klz"] = {
	"Kabola",
	11732258,
	"qfa-tap",
}

m["kma"] = {
	"Konni",
	35680,
	"nic-buk",
}

m["kmb"] = {
	"tiếng Kimbundu",
	35891,
	"bnt-kmb",
	"Latn",
	"Tiếng Kimbundu",
	"Kimbundu",
}

m["kmc"] = {
	"tiếng Nam Động",
	35379,
	"qfa-kms",
	"Latn",
	"Tiếng Nam Động",
	"Nam Động",
}

m["kmd"] = {
	"Madukayang Kalinga",
	18753305,
	"phi",
}

m["kme"] = {
	"Bakole",
	35068,
	"bnt-kpw",
}

m["kmf"] = {
	"Kare (New Guinea)",
	11732286,
	"ngf-mad",
	"Latn",
}

m["kmg"] = {
	"tiếng Kâte",
	3201059,
	"ngf",
	nil,
	"Tiếng Kâte",
	"Kâte",
}

m["kmh"] = {
	"Kalam",
	12952550,
	"ngf-mad",
}

m["kmi"] = {
	"Kami",
	3915372,
	"alv-ngb",
	"Latn",
}

m["kmj"] = {
	"tiếng Paharia Kumarbhag",
	3130374,
	"dra-mlo",
	"Beng, Deva",
	"Tiếng Paharia Kumarbhag",
	"Paharia Kumarbhag",
}

m["kmk"] = {
	"tiếng Kalinga Limos",
	18753303,
	"phi",
	"Latn",
	"Tiếng Kalinga Limos",
	"Kalinga Limos",
}

m["kml"] = {
	"Tanudan Kalinga",
	18753307,
	"phi",
	"Latn",
}

m["kmm"] = {
	"Kom (India)",
	12952647,
	"tbq-kuk",
}

m["kmn"] = {
	"Awtuw",
	3504217,
	"paa-spk",
}

m["kmo"] = {
	"Kwoma",
	11732376,
	"paa-spk",
}

m["kmp"] = {
	"Gimme",
	11152236,
	"alv-dur",
}

m["kmq"] = {
	"Kwama",
	2591184,
	"ssa-kom",
}

m["kmr"] = {
	"tiếng Kurmanji",
	36163,
	"ku",
	"Latn, Cyrl, Armn, ku-Arab, Yezi",
	"Tiếng Kurmanji",
	"Kurmanji",
	translit = {
		Cyrl = "kmr-translit",
		Armn = "Armn-translit",
		["ku-Arab"] = "ckb-translit",
	},
	entry_name = {
		remove_diacritics = "'’",
		from = {"r̄", "R̄", "ẍ", "Ẍ"},
		to = {"rr", "Rr", "x", "X"}
	},
	wikimedia_codes = "ku",
}

m["kms"] = {
	"Kamasau",
	6356117,
	"qfa-tor",
	"Latn",
}

m["kmt"] = {
	"Kemtuik",
	6387179,
	"paa-nim",
}

m["kmu"] = {
	"Kanite",
	12952567,
	"paa-kag",
}

m["kmv"] = {
	"Karipúna Creole French",
	2523999,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["kmw"] = {
	"Kumu",
	6428450,
	"bnt-kbi",
	"Latn",
}

m["kmx"] = {
	"Waboda",
	7958705,
	"paa-kiw",
}

m["kmy"] = {
	"Koma",
	35634,
	"alv-dur",
}

m["kmz"] = {
	"tiếng Turk Khorasan",
	35373,
	"trk-ogz",
	"Latn, Cyrl, fa-Arab",
	"Tiếng Turk Khorasan",
	"Turk Khorasan",
	ancestors = "trk-oat",
}

m["kna"] = {
	"Kanakuru",
	56811,
	"cdc-wst",
	"Latn",
}

m["knb"] = {
	"Lubuagan Kalinga",
	12953602,
	"phi",
}

m["knd"] = {
	"Konda",
	11732340,
	"ngf-sbh",
	"Latn",
}

m["kne"] = {
	"tiếng Kankanaey",
	18753329,
	"phi",
	"Latn",
	"Tiếng Kankanaey",
	"Kankanaey",
}

m["knf"] = {
	"tiếng Mankanya",
	35789,
	"alv-pap",
	"Latn",
	"Tiếng Mankanya",
	"Mankanya",
}

m["kni"] = {
	"Kanufi",
	3913297,
	"nic-nin",
	"Latn",
}

m["knj"] = {
	"Akatek",
	34923,
	"myn",
	"Latn",
}

m["knk"] = {
	"Kuranko",
	3198896,
	"dmn-mok",
	"Latn",
}

m["knl"] = {
	"Keninjal",
	6389309,
	"poz-mly",
}

m["knm"] = { -- two unrelated lects have this name; this is the Katukinian one
	"Kanamari",
	3438373,
	"sai-ktk",
	"Latn",
}

m["kno"] = {
	"Kono (Sierra Leone)",
	35675,
	"dmn-vak",
}

m["knp"] = {
	"tiếng Kwanja",
	35641,
	"nic-mmb",
	"Latn",
	"Tiếng Kwanja",
	"Kwanja",
}

m["knq"] = {
	"tiếng Kintaq",
	6414335,
	"mkh-asl",
	"Latn",
	"Tiếng Kintaq",
	"Kintaq"
}

m["knr"] = {
	"Kaningra",
	6363253,
	"paa-spk",
}

m["kns"] = {
	"tiếng Kensiu",
	6391529,
	"mkh-asl",
	"Thai",
	"Tiếng Kensiu",
	"Kensiu",
}

m["knt"] = {
	"Katukina",
	3194265,
	"sai-pan",
	"Latn",
}

m["knu"] = { -- a dialect of 'kpe'
	"Kono (Guinea)",
	3198703,
	"dmn-msw",
	"Latn, Kpel",
	ancestors = "kpe",
}

m["knv"] = {
	"Tabo",
	7959888,
	"aav",
}

m["knx"] = {
	"Kendayan",
	6388963,
	"poz-mly",
	"Latn",
}

m["kny"] = {
	"Kanyok",
	11110766,
	"bnt-lub",
}

m["knz"] = {
	"Kalamsé",
	3914000,
	"nic-gnn",
}

m["koa"] = {
	"Konomala",
	3198732,
	"poz-ocw",
	"Latn",
}

m["koc"] = {
	"Kpati",
	3913279,
	"nic-nge",
	"Latn",
}

m["kod"] = {
	"Kodi",
	4577633,
}

m["koe"] = {
	"Kacipo-Balesi",
	5364424,
	"sdv",
}

m["kof"] = {
	"Kubi",
	3438718,
	"cdc-wst",
	"Latn",
}

m["kog"] = {
	"Cogui",
	3198286,
	"cba",
}

m["koh"] = {
	"Koyo",
	35649,
	"bnt-mbo",
	"Latn",
}

m["koi"] = {
	"tiếng Komi-Permyak",
	56318,
	"urj-prm",
	"Cyrl",
	"Tiếng Komi-Permyak",
	"Komi-Permyak",
	translit = "kv-translit",
	entry_name = {remove_diacritics = c.acute},
	override_translit = true,
}

m["kok"] = {
	"tiếng Konkan",
	34239,
	"inc-sou",
	"Deva, Knda, Mlym, fa-Arab, Latn",
	"Tiếng Konkan",
	"Konkan",
	translit = {
		Deva = "mr-translit",
		Knda = "kn-translit",
		Mlym = "ml-translit",
	},
	entry_name = {
		from = {"च़", "ज़", "झ़", "ಚ಼", "ಜ಼", "ಝ಼"},
		to = {"च", "ज", "झ", "ಚ", "ಜ", "ಝ"}
	} ,
}

m["kol"] = {
	"Kol (New Guinea)",
	4227542,
}

m["koo"] = {
	"Konzo",
	2361829,
	"bnt-glb",
}

m["kop"] = {
	"Waube",
	11732373,
	"ngf-mad",
}

m["koq"] = {
	"Kota (Gabon)",
	35607,
	"bnt-kel",
	"Latn",
}

m["kos"] = {
	"tiếng Kosrae",
	33464,
	"poz-mic",
	"Latn",
	"Tiếng Kosrae",
	"Kosrae",
}

m["kot"] = {
	"Lagwan",
	3502264,
	"cdc-cbm",
	"Latn",
}

m["kou"] = {
	"Koke",
	797249,
	"alv-bua",
}

m["kov"] = {
	"Kudu-Camo",
	3915850,
	"nic-jer",
}

m["kow"] = {
	"Kugama",
	3913307,
	"alv-mye",
}

m["koy"] = {
	"Koyukon",
	28304,
	"ath-nor",
	"Latn",
}

m["koz"] = {
	"Korak",
	6431365,
	"ngf-mad",
}

m["kpa"] = {
	"Kutto",
	3437656,
	"cdc-wst",
}

m["kpb"] = {
	"tiếng Kurumba Mullu",
	19573111,
	"dra-mal",
	"Mlym",
	"Tiếng Kurumba Mullu",
	"Kurumba Mullu",
	translit = "ml-translit",
}

m["kpc"] = {
	"Curripaco",
	2882543,
	"awd-nwk",
	"Latn",
}

m["kpd"] = {
	"Koba",
	6424249,
	"poz",
}

m["kpe"] = {
	"Kpelle",
	35673,
	"dmn-msw",
	"Latn, Kpel",
}

m["kpf"] = {
	"Komba",
	6428239,
	"ngf",
}

m["kpg"] = {
	"tiếng Kapingamarangi",
	35771,
	"poz-pnp",
	"Latn",
	"Tiếng Kapingamarangi",
	"Kapingamarangi",
}

m["kph"] = {
	"Kplang",
	35628,
	"alv-gng",
}

m["kpi"] = {
	"Kofei",
	6425665,
	"paa-egb",
	"Latn",
}

m["kpj"] = {
	"tiếng Karajá",
	10322066,
	"sai-mje",
	"Latn",
	"Tiếng Karajá",
	"Karajá",
}

m["kpk"] = {
	"Kpan",
	3915380,
	"nic-jkn",
	"Latn",
}

m["kpl"] = {
	"Kpala",
	11154769,
	"nic-nkk",
	"Latn",
}

m["kpm"] = {
	"tiếng K'Ho",
	3511919,
	"mkh-ban",
	"Latn",
	"Tiếng K'Ho",
	"K'Ho",
}

m["kpn"] = {
	"Kepkiriwát",
	3195366,
	"tup",
	"Latn",
}

m["kpo"] = {
	"tiếng Ikposo",
	35029,
	"alv-ktg",
	"Latn",
	"Tiếng Ikposo",
	"Ikposo",
}

m["kpp"] = {
	"Paku Karen",
	nil,
}

m["kpq"] = {
	"Korupun-Sela",
	6432769,
	"ngf",
}

m["kpr"] = {
	"Korafe-Yegha",
	11732347,
	"ngf",
}

m["kps"] = {
	"Tehit",
	7694851,
}

m["kpt"] = {
	"tiếng Karata",
	56636,
	"cau-and",
	"Cyrl",
	"Tiếng Karata",
	"Karata",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["kpu"] = {
	"Kafoa",
	6346151,
	"qfa-tap",
}

m["kpv"] = {
	"tiếng Komi-Zyrian",
	34114,
	"urj-prm",
	"Cyrl",
	"Tiếng Komi-Zyrian",
	"Komi-Zyrian",
	translit = "kv-translit",
	override_translit = true,
	wikimedia_codes = "kv",
}

m["kpw"] = {
	"tiếng Kobon",
	11732326,
	"ngf-mad",
	"Latn",
	"Tiếng Kobon",
	"Kobon",
}

m["kpx"] = {
	"Mountain Koiari",
	6925030,
	"ngf",
}

m["kpy"] = {
	"tiếng Koryak",
	36199,
	"qfa-ckn",
	"Cyrl",
	"Tiếng Koryak",
	"Koryak",
	entry_name = {
		from = {"['’]"},
		to = {"ʼ"}
	},
	sort_key = {
		from = {"вʼ", "гʼ", "ё", "ӄ", "ӈ"},
		to = {"в" .. p[1], "г" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1]}
	},
	translit = "kpy-translit",
}

m["kpz"] = {
	"Kupsabiny",
	56445,
	"sdv-kln",
}

m["kqa"] = {
	"Mum",
	6935252,
	"ngf-mad",
}

m["kqb"] = {
	"Kovai",
	6434822,
	"ngf",
}

m["kqc"] = {
	"Doromu-Koki",
	5298175,
	"ngf",
}

m["kqd"] = {
	"tiếng Surat Koy Sanjaq",
	33463,
	"sem-nna",
	"Syrc",
	"Tiếng Surat Koy Sanjaq",
	"Surat Koy Sanjaq",
}

m["kqe"] = {
	"Kalagan",
	18748906,
	"phi",
}

m["kqf"] = {
	"tiếng Kakabai",
	6349119,
	"poz-ocw",
	"Latn",
	"Tiếng Kakabai",
	"Kakabai",
}

m["kqg"] = {
	"Khe",
	3914015,
	"nic-gur",
}

m["kqh"] = {
	"Kisankasa",
	6416409,
	"sdv",
}

m["kqi"] = {
	"Koitabu",
	6426363,
	"ngf",
}

m["kqj"] = {
	"Koromira",
	6432520,
	"paa-sbo",
}

m["kqk"] = {
	"Kotafon Gbe",
	12952447,
	"alv-pph",
}

m["kql"] = {
	"Kyenele",
	11732453,
	"paa-yua",
}

m["kqm"] = {
	"Khisa",
	3913955,
	"nic-gur",
}

m["kqn"] = {
	"Kaonde",
	33601,
	"bnt-lub",
	"Latn",
}

m["kqo"] = {
	"tiếng Konobo",
	3915374,
	"kro-wee",
	"Latn",
	"Tiếng Konobo",
	"Konobo",
}

m["kqp"] = {
	"Kimré",
	3441210,
	"cdc-est",
}

m["kqq"] = {
	"Krenak",
	6436747,
	"sai-cer",
}

m["kqr"] = {
	"Kimaragang",
	3196845,
	"poz-san",
	"Latn",
}

m["kqs"] = {
	"Northern Kissi",
	19921576,
	"alv-kis",
}

m["kqt"] = {
	"Klias River Kadazan",
	12953594,
	"poz-san",
}

m["kqu"] = {
	"Seroa",
	33127766,
	"khi-tuu",
}

m["kqv"] = {
	"Okolod",
	7082487,
	"poz-san",
}

m["kqw"] = {
	"Kandas",
	3192590,
	"poz-ocw",
	"Latn",
}

m["kqx"] = {
	"Mser",
	3502347,
	"cdc-cbm",
}

m["kqy"] = {
	"tiếng Koore",
	6430753,
	"omv-eom",
	"Ethi, Latn",
	"Tiếng Koore",
	"Koore",
}

m["kqz"] = {
	"Korana",
	2756709,
	"khi-khk",
	"Latn",
}

m["kra"] = {
	"Kumhali",
	13580783,
	"inc-eas",
	ancestors = "bh",
}

m["krb"] = {
	"Karkin",
	3193345,
	"nai-you",
	"Latn",
}

m["krc"] = {
	"tiếng Karachay-Balkar",
	33714,
	"trk-kcu",
	"Cyrl",
	"Tiếng Karachay-Balkar",
	"Karachay-Balkar",
	translit = "krc-translit",
	sort_key = {
		from = {"гъ", "дж", "ё", "къ", "нг"},
		to = {"г" .. p[1], "д" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1]}
	},
}

m["krd"] = {
	"Kairui-Midiki",
	12953277,
	"poz-tim",
}

m["kre"] = {
	"Panará",
	3361895,
	"sai-cer",
}

m["krf"] = {
	"Koro (Vanuatu)",
	3198995,
	"poz-oce",
	"Latn",
}

m["krh"] = {
	"Kurama",
	35593,
	"nic-kau",
}

m["kri"] = {
	"tiếng Krio",
	35744,
	"crp",
	"Latn",
	"Tiếng Krio",
	"Krio",
	ancestors = "en",
}

m["krj"] = {
	"tiếng Kinaray-a",
	33720,
	"phi",
	"Latn",
	"Tiếng Kinaray-a",
	"Kinaray-a",
}

m["krk"] = {
	"tiếng Kerek",
	332792,
	"qfa-ckn",
	"Cyrl",
	"Tiếng Kerek",
	"Kerek",
}

m["krl"] = {
	"tiếng Karelia",
	33557,
	"urj-fin",
	"Latn, Cyrl",
	"Tiếng Karelia",
	"Karelia",
	sort_key = {
		from = {
			"č", "š", "ž", "ü", "ä", "ö", -- 2 chars
			"z", "'" -- 1 char
		},
		to = {
			"c" .. p[1], "s" .. p[1], "s" .. p[3], "y" .. p[1], "y" .. p[2], "y" .. p[3],
			"s" .. p[2], "y" .. p[4],
		}
	},
}

m["krm"] = {
	"Krim",
	35713,
	"alv",
}

m["krn"] = {
	"Sapo",
	3915386,
	"kro-wee",
}

m["krp"] = {
	"Korop",
	35626,
	"nic-ucr",
	"Latn",
}

m["krr"] = {
	"tiếng Krung",
	12953650,
	"mkh-ban",
	"Khmr",
	"Tiếng Krung",
	"Krung"
}

m["krs"] = {
	"tiếng Kresh",
	56674,
	"csu-bkr",
	"Latn",
	"Tiếng Kresh",
	"Kresh",
}

m["kru"] = {
	"tiếng Kurukh",
	33492,
	"dra-kml",
	"Deva, Tols, Beng",
	"Tiếng Kurukh",
	"Kurukh",
	translit = {
		Deva = "hi-translit",
	},
}

m["krv"] = {
	"tiếng Kavet",
	12953649,
	"mkh-ban",
	"Khmr",
	"Tiếng Kavet",
	"Kavet"
}

m["krw"] = {
	"tiếng Krahn",
	10975611,
	"kro-wee",
	"Latn",
	"Tiếng Krahn",
	"Krahn",
}

m["krx"] = {
	"Karon",
	35704,
	"alv-jol",
}

m["kry"] = {
	"tiếng Kryts",
	35861,
	"cau-ssm",
	"Latn, Cyrl",
	"Tiếng Kryts",
	"Kryts",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Latn = s["cau-Latn-entryname"],
		Cyrl = s["cau-Cyrl-entryname"],
	},
}

m["krz"] = {
	"Sota Kanum",
	12952568,
	"paa-yam",
}

m["ksa"] = {
	"Shuwa-Zamani",
	3913929,
	"nic-kau",
}

m["ksb"] = {
	"Shambala",
	3788739,
	"bnt-seu",
	"Latn",
}

m["ksc"] = {
	"Southern Kalinga",
	18753301,
	"phi",
}

m["ksd"] = {
	"Tolai",
	35870,
	"poz-ocw",
	"Latn",
}

m["kse"] = {
	"Kuni",
	6444619,
	"poz-ocw",
	"Latn",
}

m["ksf"] = {
	"Bafia",
	34930,
	"bnt-baf",
}

m["ksg"] = {
	"Kusaghe",
	3200638,
	"poz-ocw",
	"Latn",
}

m["ksi"] = {
	"Krisa",
	841704,
	"paa-msk",
	"Latn",
}

m["ksj"] = {
	"Uare",
	6450052,
	"ngf",
}

m["ksk"] = {
	"Kansa",
	3192772,
	"sio-dhe",
}

m["ksl"] = {
	"Kumalu",
	17584381,
	"poz-ocw",
	"Latn",
}

m["ksm"] = {
	"Kumba",
	3913972,
	"alv-mye",
}

m["ksn"] = {
	"Kasiguranin",
	6374525,
	"phi",
}

m["kso"] = {
	"Kofa",
	56278,
	"cdc-cbm",
}

m["ksp"] = {
	"Kaba",
	3915316,
	"csu-sar",
}

m["ksq"] = {
	"Kwaami",
	3440525,
	"cdc-wst",
}

m["ksr"] = {
	"Borong",
	4946263,
	"ngf",
}

m["kss"] = {
	"tiếng Kissi Nam",
	11028974,
	"alv-kis",
	"Latn",
	"Tiếng Kissi Nam",
	"Kissi Nam",
}

m["kst"] = {
	"Winyé",
	3913360,
	"nic-gnw",
}

m["ksu"] = {
	"tiếng Khamyang",
	6583541,
	"tai-swe",
	"Mymr",
	"Tiếng Khamyang",
	"Khamyang",
}

m["ksv"] = {
	"Kusu",
	6448199,
	"bnt-tet",
}

m["ksw"] = {
	"tiếng Karen S'gaw",
	56410,
	"kar",
	"Mymr",
	"Tiếng Karen S'gaw",
	"Karen S'gaw",
	translit = "ksw-translit",
}

m["ksx"] = {
	"Kedang",
	6382520,
	"poz",
	"Latn",
}

m["ksy"] = {
	"Kharia Thar",
	6400661,
	"inc-eas",
}

m["ksz"] = {
	"Kodaku",
	21179986,
	"mun",
}

m["kta"] = {
	"tiếng Ca Tua",
	6378404,
	"mkh-nbn",
	"Latn",
	"Tiếng Ca Tua",
	"Ca Tua",
}

m["ktb"] = {
	"tiếng Kambaata",
	35664,
	"cus-hec",
	"Ethi, Latn",
	"Tiếng Kambaata",
	"Kambaata",
}

m["ktc"] = {
	"Kholok",
	3440464,
	"cdc-wst",
}

m["ktd"] = {
	"Kokata",
	10547021,
	"aus-pam",
}

m["ktf"] = {
	"Kwami",
	12952687,
	"bnt-lgb",
}

m["ktg"] = {
	"Kalkatungu",
	3914057,
	"aus-pam",
	"Latn",
}

m["kth"] = {
	"Karanga",
	713643,
}

m["kti"] = {
	"North Muyu",
	20857698,
	"ngf",
	"Latn",
}

m["ktj"] = {
	"Plapo Krumen",
	10975356,
	"kro-grb",
}

m["ktk"] = {
	"Kaniet",
	3399050,
	"poz-aay",
	"Latn",
}

m["ktl"] = {
	"Koroshi",
	3775265,
	"ira-nwi",
	ancestors = "bal",
}

m["ktm"] = {
	"Kurti",
	3200615,
	"poz-aay",
	"Latn",
}

m["ktn"] = {
	"tiếng Karitiâna",
	3112184,
	"tup",
	"Latn",
	"Tiếng Karitiâna",
	"Karitiâna",
}

m["kto"] = {
	"Kuot",
	56537,
}

m["ktp"] = {
	"Kaduo",
	769809,
	"tbq-bka",
}

m["ktq"] = {
	"Katabaga",
	3193895,
}

m["ktr"] = {
	"Kota Marudu Tinagas",
	18642280,
}

m["kts"] = {
	"South Muyu",
	42308820,
	"ngf",
	"Latn",
}

m["ktt"] = {
	"Ketum",
	12952616,
	"ngf",
}

m["ktu"] = {
	"tiếng Kituba",
	35746,
	"crp",
	"Latn",
	"Tiếng Kituba",
	"Kituba",
	ancestors = "kg",
}

m["ktv"] = {
	"tiếng Cơ Tu",
	22808951,
	"mkh-kat",
	"Latn",
	"Tiếng Cơ Tu",
	"Cơ Tu",
}

m["ktw"] = {
	"Kato",
	20831,
	"ath-pco",
	"Latn",
}

m["ktx"] = {
	"Kaxararí",
	6380124,
	"sai-pan",
	"Latn",
}

m["kty"] = {
	"Kango",
	6362818,
	"bnt-bta",
	"Latn",
}

m["ktz"] = {
	"tiếng Juǀ'hoan",
	1192295,
	"khi-kxa",
	"Latn",
	"Tiếng Juǀ'hoan",
	"Juǀ'hoan",
}

m["kub"] = {
	"tiếng Kutep",
	35645,
	"nic-jkn",
	"Latn",
	"Tiếng Kutep",
	"Kutep",
}

m["kuc"] = {
	"Kwinsu",
	6450460,
	"paa-tkw",
}

m["kud"] = {
	"tiếng Auhelawa",
	5166,
	"poz-ocw",
	"Latn",
	"Tiếng Auhelawa",
	"Auhelawa",
}

m["kue"] = {
	"Kuman",
	137525,
	"ngf",
	"Latn",
}

m["kuf"] = {
	"tiếng Cơ Tu Tây",
	6378400,
	"mkh-kat",
	"Laoo, Tale",
	"Tiếng Cơ Tu Tây",
	"Cơ Tu Tây",
}

m["kug"] = {
	"Kupa",
	3915336,
	"alv-ngb",
}

m["kuh"] = {
	"tiếng Kushi",
	3438747,
	"cdc-wst",
	"Latn",
	"Tiếng Kushi",
	"Kushi",
}

m["kui"] = {
	"Kuikúro",
	3915522,
	"sai-kui",
	"Latn",
}

m["kuj"] = {
	"Kuria",
	6445968,
	"bnt-lok",
	"Latn",
}

m["kuk"] = {
	"Kepo'",
	6393217,
	"poz",
}

m["kul"] = {
	"Kulere",
	3440506,
	"cdc-wst",
}

m["kum"] = {
	"tiếng Kumyk",
	36209,
	"trk-kcu",
	"Cyrl",
	"Tiếng Kumyk",
	"Kumyk",
	translit = "kum-translit",
	sort_key = {
		from = {"гъ", "гь", "ё", "къ", "нг", "оь", "уь"},
		to = {"г" .. p[1], "г" .. p[2], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1]}
	},
}

m["kun"] = {
	"Kunama",
	36041,
}

m["kuo"] = {
	"Kumukio",
	11732362,
	"ngf",
}

m["kup"] = {
	"Kunimaipa",
	6444696,
}

m["kuq"] = {
	"Karipuna",
	6371071,
	"tup-gua",
	"Latn",
}

m["kus"] = {
	"tiếng Kusaal",
	35708,
	"nic-dag",
	"Latn",
}

m["kut"] = {
	"tiếng Ktunaxa",
	33434,
	"qfa-iso",
	"Latn",
	"Tiếng Ktunaxa",
	"Ktunaxa",
}

m["kuu"] = {
	"Upper Kuskokwim",
	28062,
	"ath-nor",
}

m["kuv"] = {
	"Kur",
	12635082,
	"poz-cma",
	"Latn",
}

m["kuw"] = {
	"Kpagua",
	11137573,
	"bad-cnt",
}

m["kux"] = {
	"Kukatja",
	10549839,
	"aus-pam",
}

m["kuy"] = {
	"Kuuku-Ya'u",
	10550697,
	"aus-pmn",
}

m["kuz"] = {
	"Kunza",
	2669181,
	"qfa-iso",
}

m["kva"] = {
	"tiếng Bagvalal",
	56638,
	"cau-and",
	"Cyrl",
	"Tiếng Bagvalal",
	"Bagvalal",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["kvb"] = {
	"Kubu",
	6441341,
	"poz-mly",
}

m["kvc"] = {
	"Kove",
	3199402,
	"poz-ocw",
	"Latn",
}

m["kvd"] = {
	"Kui (Indonesia)",
	6442230,
	"ngf",
}

m["kve"] = {
	"Kalabakan",
	6350003,
	"poz-san",
}

m["kvf"] = {
	"Kabalai",
	3440427,
	"cdc-est",
}

m["kvg"] = {
	"Kuni-Boazi",
	2907551,
	"ngf",
}

m["kvh"] = {
	"tiếng Komodo",
	3198565,
	"poz-cet",
	"Latn",
	"Tiếng Komodo",
	"Komodo",
}

m["kvi"] = {
	"Kwang",
	3440398,
	"cdc-est",
	"Latn",
}

m["kvj"] = {
	"Psikye",
	56304,
	"cdc-cbm",
}

m["kvk"] = {
	"Korean Sign Language",
	3073428,
	"sgn-jsl",
}

m["kvl"] = {
	"Brek Karen",
	12952577,
	"kar",
}

m["kvm"] = {
	"Kendem",
	35751,
	"nic-mam",
	"Latn",
}

m["kvn"] = {
	"Border Kuna",
	31777873,
	"cba",
}

m["kvo"] = {
	"Dobel",
	5286559,
	"poz",
}

m["kvp"] = {
	"Kompane",
	18343041,
	"poz",
}

m["kvq"] = {
	"tiếng Karen Geba",
	12952581,
	"kar",
	"Mymr",
	"Tiếng Karen Geba",
	"Karen Geba",
}

m["kvr"] = {
	"Kerinci",
	3195442,
	"poz-mly",
}

m["kvt"] = {
	"tiếng Lahta",
	12952582,
	"kar",
	"Mymr",
	"Tiếng Lahta",
	"Lahta",
}

m["kvu"] = {
	"Yinbaw Karen",
	14426328,
	"kar",
}

m["kvv"] = {
	"Kola",
	6426967,
	"poz",
}

m["kvw"] = {
	"Wersing",
	7983599,
	"qfa-tap",
}

m["kvx"] = {
	"tiếng Koli Parkar",
	3244176,
	"inc-wes",
	"fa-Arab",
	"Tiếng Koli Parkar",
	"Koli Parkar",
}

m["kvy"] = {
	"Yintale Karen",
	14426329,
	"kar",
}

m["kvz"] = {
	"Tsakwambo",
	7849438,
	"ngf",
}

m["kwa"] = {
	"Dâw",
	3042278,
	"sai-nad",
}

m["kwb"] = {
	"Baa",
	34842,
	"alv-ada",
}

m["kwc"] = {
	"Likwala",
	35597,
	"bnt-mbo",
}

m["kwd"] = {
	"Kwaio",
	3200796,
	"poz-sls",
	"Latn",
}

m["kwe"] = {
	"Kwerba",
	6450328,
	"paa-tkw",
}

m["kwf"] = {
	"Kwara'ae",
	3200829,
	"poz-oce",
}

m["kwg"] = {
	"tiếng Sara Kaba Deme",
	3915384,
	"csu-kab",
	"Latn",
	"Tiếng Sara Kaba Deme",
	"Sara Kaba Deme",
}

m["kwh"] = {
	"Kowiai",
	6435028,
	"poz",
}

m["kwi"] = {
	"Awa-Cuaiquer",
	2603103,
	"sai-bar",
	"Latn",
}

m["kwj"] = {
	"Kwanga",
	3438383,
	"paa-spk",
}

m["kwk"] = {
	"tiếng Kwak'wala",
	2640628,
	"wak",
	"Latn",
	"Tiếng Kwak'wala",
	"Kwak'wala",
}

m["kwl"] = {
	"Kofyar",
	3441382,
	"cdc-wst",
	"Latn",
}

m["kwm"] = {
	"Kwambi",
	3487165,
	"bnt-ova",
}

m["kwn"] = {
	"Kwangali",
	36334,
	"bnt-kav",
	"Latn",
}

m["kwo"] = {
	"Kwomtari",
	3508116,
}

m["kwp"] = {
	"Kodia",
	3914867,
	"kro-ekr",
}

m["kwq"] = {
	"Kwak",
	11014183,
	"nic-nka",
	ancestors = "yam",
}

m["kwr"] = {
	"Kwer",
	12635137,
	"ngf-okk",
}

m["kws"] = {
	"Kwese",
	3200846,
	"bnt-pen",
}

m["kwt"] = {
	"Kwesten",
	6450354,
	"paa-tkw",
}

m["kwu"] = {
	"Kwakum",
	35624,
	"bnt-kak",
}

m["kwv"] = {
	"Sara Kaba Náà",
	3915361,
	"csu-kab",
}

m["kww"] = {
	"tiếng Kwinti",
	721182,
	"crp",
	"Latn",
	"Tiếng Kwinti",
	"Kwinti",
	ancestors = "en"
}

m["kwx"] = {
	"Khirwar",
	12976968,
	"dra",
}

m["kwz"] = {
	"Kwadi",
	2364661,
	"khi-kkw",
	"Latn",
}

m["kxa"] = {
	"Kairiru",
	3398785,
	"poz-ocw",
	"Latn",
}

m["kxb"] = {
	"Krobu",
	35586,
	"alv-ptn",
	"Latn",
}

m["kxc"] = {
	"tiếng Konso",
	56624,
	"cus-eas",
	"Ethi, Latn",
	"Tiếng Konso",
	"Konso",
}

m["kxd"] = {
	"tiếng Mã Lai Brunei",
	3182878,
	"poz-mly",
	"Latn, ms-Arab",
	"Tiếng Mã Lai Brunei",
	"Mã Lai Brunei",
}

m["kxe"] = {
	"Kakihum",
	3914433,
	"nic-kam",
	ancestors = "tvd",
}

m["kxf"] = {
	"tiếng Manumanaw",
	12952592,
	"kar",
	"Mymr, Latn",
	"Tiếng Manumanaw",
	"Manumanaw",
}

m["kxh"] = {
	"tiếng Karo",
	3447116,
	"omv-aro",
	"Ethi",
	"Tiếng Karo",
	"Karo",
}

m["kxi"] = {
	"Keningau Murut",
	6389308,
	"poz-san",
	"Latn",
}

m["kxj"] = {
	"Kulfa",
	713654,
	"csu-kab",
}

m["kxk"] = {
	"tiếng Karen Zayein",
	14352960,
	"kar",
	"Mymr",
	"Tiếng Karen Zayein",
	"Karen Zayein",
}

m["kxl"] = {
	"Nepali Kurux",
	3200624,
	"dra-kml",
	"Deva",
	ancestors = "kru",
}

m["kxm"] = {
	"tiếng Khmer Surin",
	3502234,
	"mkh-kmr",
	"Thai, Khmr",
	"Tiếng Khmer Surin",
	"Khmer Surin",
	ancestors = "xhm",
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to = {"", "", "%2%1"}
	},
}

m["kxn"] = {
	"Kanowit",
	6364300,
	"poz-bnn",
	"Latn",
}

m["kxo"] = {
	"Kanoé",
	4356223,
	"qfa-iso",
}

m["kxp"] = {
	"tiếng Koli Wadiyara",
	12953645,
	"inc-wes",
	"Gujr",
	"Tiếng Koli Wadiyara",
	"Koli Wadiyara",
}

m["kxq"] = {
	"Smärky Kanum",
	12952569,
	"paa-yam",
}

m["kxr"] = {
	"Koro (New Guinea)",
	3198994,
	"poz-oce",
	"Latn",
}

m["kxs"] = {
	"tiếng Khang Gia",
	3182570,
	"xgn-shr",
	"Latn",
	"Tiếng Khang Gia",
	"Khang Gia",
}

m["kxt"] = {
	"Koiwat",
	6426388,
	"paa-spk",
}

m["kxv"] = {
	"tiếng Kuvi",
	3200721,
	"dra-kki",
	"Orya, Telu",
	"Tiếng Kuvi",
	"Kuvi",
	translit = { Orya = "kxv-translit" },
	entry_name = {
		remove_diacritics = "୕",
		from = {"ଆଆ", "ଇଇ", "ଉଉ", "ଏଏ", "ଓଓ", "([କ-ହ])ଆ", "ିଇ", "ୁଉ", "େଏ", "ୋଓ"},
		to = {"ଆ", "ଈ", "ଊ", "ଏ", "ଓ", "%1ା", "ୀ", "ୂ", "େ", "ୋ"},
	},
}

m["kxw"] = {
	"Konai",
	11732339,
}

m["kxx"] = {
	"Likuba",
	35646,
	"bnt-bmo",
}

m["kxy"] = {
	"tiếng Ca Dong",
	6380673,
	"mkh-nbn",
	"Latn",
	"Tiếng Ca Dong",
	"Ca Dong",
}

m["kxz"] = {
	"Kerewo",
	6393847,
	"paa-kiw",
}

m["kya"] = {
	"Kwaya",
	6450276,
	"bnt-haj",
	"Latn",
}

m["kyb"] = {
	"Butbut Kalinga",
	18753300,
	"phi",
}

m["kyc"] = {
	"Kyaka",
	12952690,
	"paa-eng",
}

m["kyd"] = {
	"Karey",
	6370196,
	"poz",
}

m["kye"] = {
	"Krache",
	35658,
	"alv-gng",
}

m["kyf"] = {
	"Kouya",
	35595,
	"kro-bet",
}

m["kyg"] = {
	"Keyagana",
	6398208,
	"paa-kag",
}

m["kyh"] = {
	"Karok",
	1288440,
	"qfa-iso",
	"Latn",
}

m["kyi"] = {
	"Kiput",
	3038653,
	"poz-swa",
	"Latn",
}

m["kyj"] = {
	"tiếng Karao",
	3192950,
	"phi",
	"Latn",
	"Tiếng Karao",
	"Karao",
}

m["kyk"] = {
	"tiếng Kamayo",
	3192339,
	"phi",
	"Latn",
	"Tiếng Kamayo",
	"Kamayo"
}

m["kyl"] = {
	"Kalapuya",
	3192120,
	"nai-klp",
}

m["kym"] = {
	"Kpatili",
	3913982,
	"znd",
}

m["kyn"] = {
	"Karolanos",
	6373093,
	"phi",
}

m["kyo"] = {
	"Kelon",
	6386414,
	"ngf",
}

m["kyp"] = {
	"Kang",
	25559558,
	"tai",
}

m["kyq"] = {
	"Kenga",
	35707,
	"csu-bgr",
}

m["kyr"] = {
	"Kuruáya",
	3200633,
	"tup",
	"Latn",
}

m["kys"] = {
	"Baram Kayan",
	2883794,
	"poz",
}

m["kyt"] = {
	"Kayagar",
	6380394,
	"ngf",
}

m["kyu"] = {
	"tiếng Tây Kayah",
	12952596,
	"kar",
	"Kali, Mymr, Latn",
	"Tiếng Tây Kayah",
	"Tây Kayah",
	translit = {Kali = "Kali-translit"},
}

m["kyv"] = {
	"tiếng Kayort",
	6380675,
	"inc-eas",
	"as-Beng",
	"Tiếng Kayort",
	"Kayort",
}

m["kyw"] = {
	"tiếng Kudmal",
	6446173,
	"inc-eas",
	"Deva, as-Beng, Orya, Chis",
	"Tiếng Kudmal",
	"Kudmal",
	ancestors = "bh",
}

m["kyx"] = {
	"Rapoisi",
	7294279,
	"paa-nbo",
}

m["kyy"] = {
	"Kambaira",
	6356254,
	"paa-kag",
}

m["kyz"] = {
	"Kayabí",
	6380372,
	"tup-gua",
	"Latn",
}

m["kza"] = {
	"Western Karaboro",
	36601,
	"alv-krb",
}

m["kzb"] = {
	"Kaibobo",
	6347565,
	"poz-cma",
}

m["kzc"] = {
	"tiếng Kulango Bondoukou",
	11031321,
	"alv-kul",
	"Latn",
	"Tiếng Kulango Bondoukou",
	"Kulango Bondoukou",
}

m["kzd"] = {
	"Kadai",
	7679471,
	"poz-cma",
	"Latn",
}

m["kze"] = {
	"Kosena",
	12952663,
	"ngf",
	"Latn",
}

m["kzf"] = {
	"Da'a Kaili",
	33103997,
	"poz-kal",
	"Latn",
}

m["kzg"] = {
	"tiếng Kikai",
	3196527,
	"jpx-nry",
	"Jpan",
	"Tiếng Kikai",
	"Kikai",
	translit = s["Jpan-translit"],
	sort_key = s["Jpan-sortkey"],
}

m["kzh"] = {
	"tiếng Dongolawi",
	5295991,
	"nub",
	"Latn",
	"Tiếng Dongolawi",
	"Dongolawi",
}

m["kzi"] = {
	"Kelabit",
	6385445,
	"poz-swa",
	"Latn",
}

m["kzj"] = {
	"tiếng Kadazan bờ biển",
	3307195,
	"poz-san",
	"Latn",
	"Tiếng Kadazan bờ biển",
	"Kadazan bờ biển",
}

m["kzk"] = {
	"Kazukuru",
	1089069,
	"poz-ocw",
}

m["kzl"] = {
	"Kayeli",
	4207444,
	"poz-cma",
	"Latn",
}

m["kzm"] = {
	"Kais",
	6348319,
	"paa",
	"Latn",
}

m["kzn"] = {
	"Kokola",
	11128329,
	"bnt-mak",
	"Latn",
	ancestors = "vmw",
}

m["kzo"] = {
	"Kaningi",
	35683,
	"bnt-mbt",
}

m["kzp"] = {
	"Kaidipang",
	6347611,
	"phi",
}

m["kzq"] = {
	"Kaike",
	10951226,
	"sit-tam",
}

m["kzr"] = {
	"tiếng Karang",
	35681,
	"alv-mbm",
	"Latn",
	"Tiếng Karang",
	"Karang",
}

m["kzs"] = {
	"Sugut Dusun",
	12953510,
	"poz-san",
	"Latn",
}

m["kzt"] = {
	"Tambunan Dusun",
	12953514,
	"poz-san",
	"Latn",
}

m["kzu"] = {
	"Kayupulau",
	6380723,
	"poz-ocw",
}

m["kzv"] = {
	"Komyandaret",
	6428671,
	"ngf-okk",
	"Latn",
}

m["kzw"] = { -- contrast xoo, sai-kat, sai-xoc, the last of which the ISO conflated into this code
	"tiếng Kariri",
	12953620,
	"sai-mje",
	"Latn",
	"Tiếng Kariri",
	"Kariri",
}

m["kzx"] = {
	"Kamarian",
	6356040,
	"poz-cma",
	"Latn",
}

m["kzy"] = {
	"Kango-Sua",
	11008360,
	"bnt-kbi",
	"Latn",
	ancestors = "bip",
}

m["kzz"] = {
	"Kalabra",
	6350038,
	"paa",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")