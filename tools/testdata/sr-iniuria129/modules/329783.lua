local m_lang = require("Module:languages")
local m_langdata = require("Module:languages/data")

local u = require("Module:string utilities").char

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

local m = {}

m["yaa"] = {
	"Yaminahua",
	3026110,
	"sai-pan",
	"Latn",
}

m["yab"] = {
	"Yuhup",
	3573115,
	"sai-nad",
	"Latn",
}

m["yac"] = {
	"Pass Valley Yali",
	12953309,
	"ngf",
	"Latn",
}

m["yad"] = {
	"Yagua",
	3182567,
	nil,
	"Latn",
}

m["yae"] = {
	"Pumé",
	3121835,
	nil,
	"Latn",
}

m["yaf"] = {
	"Yaka",
	35588,
	"bnt-yak",
	"Latn",
}

m["yag"] = {
	"Yámana",
	531826,
	"qfa-iso",
	"Latn",
}

m["yah"] = {
	"Yazghulami",
	34186,
	"ira-shy",
	"Latn, Cyrl",
	translit = "yah-translit",
}

m["yai"] = {
	"Yagnobi",
	34247,
	"ira-sgc",
	"Latn, Cyrl",
	translit = "tg-translit",
}

m["yaj"] = {
	"Banda-Yangere",
	8048561,
	"bad",
}

m["yak"] = {
	"Yakima",
	35976053,
	"nai-shp",
	"Latn",
	ancestors = "nai-spt",
}

m["yal"] = {
	"Yalunka",
	35524,
	"dmn-sya",
}

m["yam"] = {
	"Yamba",
	36904,
	"nic-nka",
	"Latn",
}

m["yan"] = {
	"Mayangna",
	3302929,
	"nai-min",
	"Latn",
}

m["yao"] = {
	"Yao",
	36902,
	"bnt-rvm",
	"Latn",
}

m["yap"] = {
	"Yapese",
	34029,
	"poz-oce",
	"Latn",
}

m["yaq"] = {
	"Yaqui",
	34191,
	"azc-trc",
	"Latn",
}

m["yar"] = {
	"Yabarana",
	3571238,
	"sai-map",
	"Latn",
}

m["yas"] = {
	"Gunu",
	36358,
	"nic-ymb",
	"Latn",
}

m["yat"] = {
	"Yambeta",
	8048020,
	"nic-mbw",
	"Latn",
}

m["yau"] = {
	"Yuwana",
	5876347,
}

m["yav"] = {
	"Yangben",
	12953315,
	"nic-ymb",
	"Latn",
}

m["yaw"] = {
	"Yawalapití",
	3450709,
	"awd",
	"Latn",
}

m["yay"] = {
	"Agwagwune",
	34736,
	"nic-ucn",
	"Latn",
}

m["yaz"] = {
	"Lokaa",
	3914439,
	"nic-uce",
	"Latn",
}

m["yba"] = {
	"Yala",
	3914920,
	"alv-ido",
	"Latn",
}

m["ybb"] = {
	"Yemba",
	36917,
	"bai",
	"Latn",
}

m["ybe"] = {
	"Western Yugur",
	34224,
	"trk-ssb",
	"Latn, Ougr",
	ancestors = "oui",
}

m["ybh"] = {
	"Yakkha",
	56666,
	"sit-kie",
	"Deva",
}

m["ybi"] = {
	"Yamphu",
	56316,
	"sit-kie",
	"Deva",
	translit = "ybi-translit",
} 

m["ybj"] = {
	"Hasha",
	3915338,
	"nic-alu",
}

m["ybk"] = {
	"Bokha",
	nil,
	"tbq-muj",
}

m["ybl"] = {
	"Yukuben",
	3915846,
	"nic-ykb",
}

m["ybm"] = {
	"Yaben",
	8046372,
	"ngf-mad",
}

m["ybn"] = {
	"Yabaâna",
	3450534,
	"awd",
	"Latn",
}

m["ybo"] = {
	"Yabong",
	8046383,
	"ngf-mad",
}

m["ybx"] = {
	"Yawiyo",
	8050463,
	"paa-spk",
}

m["yby"] = {
	"Yaweyuha",
	3571231,
	"paa-kag",
}

m["ych"] = {
	"Chesu",
	30334841,
	"tbq-nas",
}

m["ycl"] = {
	"Lolopo",
	56441,
	"tbq-llo",
}

m["ycn"] = {
	"Yucuna",
	3438356,
	"awd-nwk",
	"Latn",
}

m["ycp"] = {
	"Chepya",
	46603077,
	"tbq-han",
}

m["ycr"] = {
	"Yilan Creole",
	10955036,
	"crp",
	"Latn",
}

m["yda"] = {
	"Yanda",
	8048318,
	"aus-pam",
}

m["yde"] = {
	"Yangum Dey",
	nil,
	"qfa-tor",
	"Latn",
}

m["ydg"] = {
	"Yidgha",
	34179,
	"ira-mny",
	"Arab",
}

m["ydk"] = {
	"Yoidik",
	8054512,
	"ngf-mad",
}

m["yea"] = {
	"Ravula",
	7296830,
	"dra-mal",
	"Knda, Mlym",
	translit = {
		Knda = "kn-translit",
		Mlym = "ml-translit",
	},
}

m["yec"] = {
	"Yenish",
	1365342,
	"gmw-hgm",
	"Latn",
	ancestors = "gmh",
}

m["yee"] = {
	"Yimas",
	36954,
	"paa-lsp",
}

m["yei"] = {
	"Yeni",
	34213,
	"nic-mmb",
}

m["yej"] = {
	"Yevanic",
	34200,
	"grk",
	"Hebr",
	ancestors = "gkm",
	entry_name = {remove_diacritics = u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7)},
}

m["yen"] = {
	"Yendang",
	nil,
	"alv-mye",
	"Latn",
}

m["yer"] = {
	"Tarok",
	3914953,
	"nic-tar",
	"Latn",
}

m["yes"] = {
	"Yeskwa",
	3914962,
	"nic-plc",
	"Latn",
}

m["yet"] = {
	"Yetfa",
	8053020,
	"paa-pau",
}

m["yeu"] = {
	"Yerukula",
	3535117,
	"dra-tam",
}

m["yev"] = {
	"Yapunda",
	11044384,
	"qfa-tor",
	"Latn",
}

m["yey"] = {
	"Yeyi",
	8053347,
	"bnt",
}

m["ygi"] = {
	"Yiningayi",
	nil,
	"aus-pam",
}

m["ygl"] = {
	"Yangum Gel",
	nil,
	"qfa-tor",
	"Latn",
}

m["ygm"] = {
	"Yagomi",
	20771657,
	"ngf-fin",
	"Latn",
}

m["ygp"] = {
	"Gepo",
	5548692,
	"tbq-nas",
}

m["ygr"] = {
	"Yagaria",
	8046690,
	"paa-kag",
	"Latn",
}

m["ygs"] = {
	"Yolngu Sign Language",
	16211970,
	"sgn",
}

m["ygu"] = {
	"Yugul",
	8060437,
	"aus-arn",
}

m["ygw"] = {
	"Yagwoia",
	8046761,
	"ngf",
	"Latn",
}

m["yha"] = {
	"Baha",
	2879238,
	"qfa-kra",
}

m["yhl"] = {
	"Hlepho Phowa",
	nil,
	"tbq-phw",
}

m["yia"] = {
	"Yinggarda",
	3913777,
	"aus-psw",
	"Latn",
}

m["yif"] = {
	"Ache",
	10949828,
	"tbq-sel",
}

m["yig"] = {
	"Wusa",
	12953334,
	"tbq-nas",
}

m["yii"] = {
	"Yidiny",
	3053283,
	"aus-yid",
	"Latn",
}

m["yij"] = {
	"Yindjibarndi",
	3121073,
	"aus-nga",
	"Latn",
}

m["yik"] = {
	"Dongshanba Lalo",
	12953333,
	"tbq-lal",
}

m["yil"] = {
	"Yindjilandji",
	10723541,
	"aus-pam",
	"Latn",
}

m["yim"] = {
	"Yimchungru Naga",
	56348,
	"sit-aao",
	"Latn",
}

m["yin"] = {
	"Yinchia",
	12953981,
	"mkh-pal",
}

m["yip"] = {
	"Pholo",
	7187103,
	"tbq-nso",
}

m["yiq"] = {
	"Micha",
	6827993,
	"tbq-llo",
	"Latn",
}

m["yir"] = {
	"North Awyu",
	12642164,
	"ngf",
}

m["yis"] = {
	"Yis",
	8053831,
	"qfa-tor",
	"Latn",
}

m["yit"] = {
	"Eastern Lalu",
	12953328,
	"tbq-lal",
}

m["yiu"] = {
	"Lope",
	11163308,
	"tbq-nlo",
}

m["yiv"] = {
	"Northern Nisu",
	25559454,
	"tbq-nis",
}

m["yix"] = {
	"Axi",
	4830439,
	"tbq-axi",
}

m["yiy"] = {
	"Yir-Yoront",
	8053819,
	"aus-pmn",
	"Latn",
}

m["yiz"] = {
	"Azhe",
	4832535,
	"tbq-axi",
}

m["yka"] = {
	"Yakan",
	3571351,
	"poz-sbj",
}

m["ykg"] = {
	"Northern Yukaghir",
	56319,
	"qfa-yuk",
	"Cyrl",
	translit = "ykg-translit",
}

m["ykh"] = {
	"Khamnigan Mongol",
	3196052,
	"xgn-cen",
	"Mong, Latn, Cyrl",
	translit = {Mong = "Mong-translit"},
	display_text = {Mong = s["Mong-displaytext"]},
	entry_name = {Mong = s["Mong-entryname"]},
}

m["yki"] = {
	"Yoke",
	3832977,
}

m["ykk"] = {
	"Yakaikeke",
	8047041,
	"poz-oce",
}

m["ykl"] = {
	"Khlula",
	6401849,
	"tbq-phw",
}

m["ykm"] = {
	"Kap",
	8047048,
	"poz-ocw",
	"Latn",
}

m["ykn"] = {
	"Kua-nsi",
	6440952,
	"tbq-tal",
}

m["yko"] = {
	"Yasa",
	36899,
	"bnt-yko",
	"Latn",
}

m["ykr"] = {
	"Yekora",
	11732781,
	"ngf",
}

m["ykt"] = {
	"Kathu",
	6377155,
	"sit-mnz",
}

m["yku"] = {
	"Kuamasi",
	6441074,
	"tbq-tal",
}

m["yky"] = {
	"Yakoma",
	3571364,
	"nic-ngd",
}

m["yla"] = {
	"Yaul",
	8050336,
	"paa",
	"Latn",
}

m["ylb"] = {
	"Yaleba",
	37710600,
	"poz-oce",
}

m["yle"] = {
	"Yele",
	36942,
}

m["ylg"] = {
	"Yelogu",
	8052024,
	"paa-spk",
}

m["yli"] = {
	"Angguruk Yali",
	3514481,
	"ngf",
}

m["yll"] = {
	"Yil",
	3501797,
	"qfa-tor",
	"Latn",
}

m["ylm"] = {
	"Limi",
	12953327,
	"tbq-lso",
}

m["yln"] = {
	"Langnian Buyang",
	2929025,
	"qfa-buy",
}

m["ylo"] = {
	"Naruo",
	6961032,
	"tbq-tal",
}

m["ylr"] = {
	"Yalarnnga",
	3915686,
	"aus-pam",
	"Latn",
}

m["ylu"] = {
	"Aribwaung",
	11044246,
	"poz-ocw",
	"Latn",
}

m["yly"] = {
	"Nyelâyu",
	303154,
	"poz-cln",
	"Latn",
}

m["ymb"] = {
	"Yambes",
	8048022,
	"qfa-tor",
	"Latn",
}

m["ymc"] = {
	"Southern Muji",
	nil,
	"tbq-muj",
}

m["ymd"] = {
	"Muda",
	6931494,
	"tbq-han",
}

m["yme"] = {
	"Yameo",
	3121032,
}

m["ymg"] = {
	"Yamongeri",
	11008893,
	"bnt-mon",
	"Latn",
	ancestors = "lol",
}

m["ymh"] = {
	"Mili",
	12953329,
	"tbq-lso",
}

m["ymi"] = {
	"Moji",
	6895060,
	"tbq-muj",
}

m["ymk"] = {
	"Makwe",
	6740513,
	"bnt-swh",
}

m["yml"] = {
	"Iamalele",
	8047849,
	"poz-ocw",
	"Latn",
}

m["ymm"] = {
	"Maay",
	36221,
	"cus-som",
	"Latn",
}

m["ymn"] = {
	"Sunum",
	8048083,
	"poz-ocw",
	"Latn",
}

m["ymo"] = {
	"Yangum Mon",
	nil,
	"qfa-tor",
	"Latn",
}

m["ymp"] = {
	"Yamap",
	8047913,
	"poz-ocw",
	"Latn",
}

m["ymq"] = {
	"Qila Muji",
	nil,
	"tbq-muj",
}

m["ymr"] = {
	"Malasar",
	16889525,
	"dra-tam",
}

m["yms"] = {
	"Mysian",
	2577228,
	"ine",
}

m["ymx"] = {
	"Northern Muji",
	nil,
	"tbq-muj",
}

m["ymz"] = {
	"Muzi",
	6944445,
	"tbq-muj",
}

m["yna"] = {
	"Aluo",
	4737539,
	"tbq-nas",
}

m["ynd"] = {
	"Yandruwandha",
	8048335,
	"aus-kar",
	"Latn",
}

m["yne"] = {
	"Lang'e",
	6485577,
	"tbq-tal",
}

m["yng"] = {
	"Yango",
	13123599,
	"nic-nkk",
	"Latn",
}

m["ynk"] = {
	"Naukanski",
	27963,
	"ypk",
	"Cyrl, Latn",
}

m["ynl"] = {
	"Yangulam",
	8048663,
	"ngf-mad",
}

m["ynn"] = {
	"Yana",
	56419,
	"qfa-iso",
}

m["yno"] = {
	"Yong",
	8054978,
	"tai-swe",
	"Lana, Thai",
	sort_key = {
		Lana = "Lana-sortkey",
		Thai = "Thai-sortkey"
	},
}

m["yns"] = {
	"Yansi",
	36953,
	"bnt-yak",
}

m["ynu"] = {
	"Yahuna",
	8050347,
	"sai-tuc",
}

m["yob"] = {
	"Yoba",
	8054220,
	"poz-ocw",
	"Latn",
}

m["yog"] = {
	"Yogad",
	8054343,
	"phi",
}

m["yoi"] = {
	"Yonaguni",
	34243,
	"jpx-sry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["yol"] = {
	"Yola",
	56395,
	"gmw-ian",
	"Latn",
}

m["yom"] = {
	"Yombe",
	10961975,
	"bnt-kng",
	"Latn",
}

m["yon"] = {
	"Yongkom",
	8055002,
	"ngf-okk",
}

m["yox"] = {
	"Yoron",
	2424943,
	"jpx-nry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["yoy"] = {
	"Yoy",
	3503717,
	"tai",
}

m["ypa"] = {
	"Phala",
	36211907,
	"tbq-drp",
}

m["ypb"] = {
	"Labo Phowa",
	nil,
	"tbq-phw",
}

m["ypg"] = {
	"Phola",
	nil,
	"tbq-drp",
}

m["yph"] = {
	"Phupha",
	7188378,
	"tbq-urp",
}

m["ypm"] = {
	"Phuma",
	nil,
	"tbq-muj",
}

m["ypn"] = {
	"Ani Phowa",
	33590104,
	"tbq-phw",
}

m["ypo"] = {
	"Alo Phola",
	33522157,
	"tbq-drp",
}

m["ypp"] = {
	"Phupa",
	48565467,
	"tbq-urp",
}

m["ypz"] = {
	"Phuza",
	48565339,
	"tbq-urp",
}

m["yra"] = {
	"Yerakai",
	8052531,
}

m["yrb"] = {
	"Yareba",
	3571876,
	"ngf",
}

m["yre"] = {
	"Yaouré",
	3913951,
	"dmn-mda",
}

m["yri"] = {
	"Yarí",
	8049616,
}

m["yrk"] = {
	"Tundra Nenets",
	36452,
	"syd",
	"Cyrl",
	entry_name = {
		from = {"ӑ", "а̄", "э̇", "ӣ", "ы̄", "ӯ", "ю̄", "я̆", "я̄"},
		to = {"а", "а", "э", "и", "ы", "у", "ю", "я", "я"},
	},
	translit = "yrk-translit",
}

m["yrl"] = {
	"Nheengatu",
	34333,
	"tup-gua",
	ancestors = "tpw",
}

m["yrn"] = {
	"Yerong",
	3572191,
	"qfa-buy",
}

m["yro"] = {
	"Ỹaroamë",
	24190396,
	"sai-ynm",
	"Latn",
}

m["yrw"] = {
	"Yarawata",
	8049237,
	"ngf-mad",
}

m["yry"] = {
	"Yarluyandi",
	33061540,
	"aus-kar",
}

m["ysc"] = {
	"Jassic",
	2479368,
	"xsc",
	"Latn",
	ancestors = "oos",
}

m["ysd"] = {
	"Samatao",
	7408902,
	"tbq-kzh",
}

m["ysg"] = {
	"Sonaga",
	7560736,
	"tbq-tal",
}

m["ysl"] = {
	"Yugoslavian Sign Language",
	8060373,
	"sgn",
}

m["ysn"] = {
	"Sani",
	1055287,
	"tbq-axi",
	"Latn", -- Not Yiii, which is the Nuosu syllabary, and does not cover classical Yi scripts.
}

m["yso"] = {
	"Nisi",
	12953326,
	"tbq-sel",
}

m["ysp"] = {
	"Southern Lolopo",
	12633989,
	"tbq-llo",
}

m["ysr"] = {
	"Sirenik",
	28156,
	"ypk",
	"Cyrl",
	translit = "ysr-translit",
	entry_name = {remove_diacritics = c.acute .. c.macron},
}

m["yss"] = {
	"Yessan-Mayo",
	8052927,
	"paa-spk",
	"Latn",
}

m["ysy"] = {
	"Sanie",
	7418287,
	"tbq-kzh",
}

m["yta"] = {
	"Talu",
	16999095,
	"tbq-tal",
}

m["ytl"] = {
	"Toloza",
	7786695,
	"tbq-lso",
}

m["ytp"] = {
	"Thopho",
	7796015,
	"tbq-muj",
}

m["ytw"] = {
	"Yout Wam",
	nil,
	"ngf-fin",
	"Latn",
}

m["yty"] = {
	"Yatay",
	nil,
	"aus-pmn",
}

m["yua"] = {
	"Yucatec Maya",
	13354,
	"myn",
	"Latn",
}

m["yub"] = {
	"Yugambal",
	3446663,
}

m["yuc"] = {
	"Yuchi",
	34204,
	"qfa-iso",
}

m["yue"] = {
	"Кантонски",
	9186,
	"zhx-yue",
	"Hants, Latn",
	wikimedia_codes = "yue, zh-yue",
	generate_forms = "zh-generateforms",
	translit = {Hani = "zh-translit"},
	sort_key = {Hani = "Hani-sortkey"},
}

m["yuf"] = {
	"Havasupai-Walapai-Yavapai",
	3565286,
	"nai-yuc",
	"Latn",
}

m["yug"] = {
	"Yug",
	56311,
	"qfa-yno",
	"Cyrl",
}

m["yui"] = {
	"Yurutí",
	3573266,
	"sai-tuc",
	"Latn",
}

m["yuj"] = {
	"Karkar-Yuri",
	2992906,
	"paa-pau",
	"Latn",
}

m["yuk"] = {
	"Yuki",
	36993,
	"nai-ykn",
	"Latn",
}

m["yul"] = {
	"Yulu",
	3915595,
	"csu-bba",
}

m["yum"] = {
	"Yuma",
	3573199,
	"nai-yuc",
	"Latn",
}

m["yun"] = {
	"Bena",
	3913283,
	"alv-yun",
}

m["yup"] = {
	"Yukpa",
	3441447,
	"sai-yuk",
	"Latn",
}

m["yuq"] = {
	"Yuqui",
	8061440,
	"tup-gua",
	"Latn",
}

m["yur"] = {
	"Yurok",
	34685,
	"aql",
	"Latn",
}

m["yut"] = {
	"Yopno",
	12953338,
	"ngf-fin",
	"Latn",
}

m["yuw"] = {
	"Finisterre Yau",
	12953319,
	"ngf-fin",
	"Latn",
}

m["yux"] = {
	"Southern Yukaghir",
	56545,
	"qfa-yuk",
	"Cyrl",
	translit = "yux-translit",
}

m["yuy"] = {
	"East Yugur",
	29902,
	"xgn-sou",
	"Latn",
}

m["yuz"] = {
	"Yuracare",
	2640646,
	"qfa-iso",
	"Latn",
}

m["yva"] = {
	"Yawa",
	3572020,
	"paa",
	"Latn",
}

m["yvt"] = {
	"Yavitero",
	3441427,
	"awd",
	"Latn",
}

m["ywa"] = {
	"Kalou",
	6354305,
	"paa-spk",
	"Latn",
}

m["ywg"] = {
	"Yinhawangka",
	8053734,
	"aus-nga",
	"Latn",
}

m["ywl"] = {
	"Western Lalu",
	12953325,
	"tbq-lal",
}

m["ywn"] = {
	"Yawanawa",
	10322118,
	"sai-pan",
	"Latn",
}

m["ywq"] = {
	"Nasu",
	25559456,
	"tbq-nas",
	"Plrd", -- Not Yiii, which is the Nuosu syllabary, and does not cover classical Yi scripts.
}

m["ywr"] = {
	"Yawuru",
	8050479,
	"aus-nyu",
	"Latn",
}

m["ywt"] = {
	"Xishanba Lalo",
	12953336,
	"tbq-lal",
}

m["ywu"] = {
	"Wumeng",
	25559442,
	"tbq-nas",
}

m["yww"] = {
	"Yawarawarga",
	10723454,
	"aus-kar",
	"Latn",
}

m["yxa"] = {
	"Mayawali",
	33060513,
	"aus-pam",
	"Latn",
}

m["yxg"] = {
	"Yagara",
	nil,
	"aus-pam",
	"Latn",
}

m["yxl"] = {
	"Yarli",
	46264708,
	"aus-pam",
	"Latn",
}

m["yxm"] = {
	"Yinwum",
	8053763,
	"aus-pam",
	"Latn",
}

m["yxu"] = {
	"Yuyu",
	8062232,
	"aus-pam",
	"Latn",
}

m["yxy"] = {
	"Yabula Yabula",
	8046394,
	"aus-pam",
	"Latn",
}

m["yyu"] = {
	"Torricelli Yau",
	8050328,
	"qfa-tor",
	"Latn",
}

m["yyz"] = {
	"Ayizi",
	20527363,
	"tbq-nas",
}

m["yzg"] = {
	"E'ma Buyang",
	16115619,
	"qfa-buy",
}

m["yzk"] = {
	"Zokhuo",
	8073523,
	"tbq-phw",
}

return m_lang.finalizeLanguageData(m_lang.addDefaultTypes(m, true))