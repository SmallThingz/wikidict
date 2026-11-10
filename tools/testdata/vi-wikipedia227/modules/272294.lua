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

m["waa"] = {
	"Walla Walla",
	12953960,
	"nai-shp",
	"Latn",
	ancestors = "nai-spt",
}

m["wab"] = {
	"Wab",
	11222271,
	"poz-ocw",
	"Latn",
}

m["wac"] = {
	"Wasco-Wishram",
	12645081,
	"nai-ckn",
	"Latn",
}

m["wad"] = {
	"Wandamen",
	2806128,
	"poz-hce",
	"Latn",
}

m["waf"] = {
	"Wakoná",
	7961205,
}

m["wag"] = {
	"Wa'ema",
	12953264,
	"poz-ocw",
	"Latn",
}

m["wah"] = {
	"Watubela",
	7975070,
	"poz-cma",
	"Latn",
}

m["waj"] = {
	"Waffa",
	3565058,
	"paa-kag",
	"Latn",
}

m["wal"] = {
	"tiếng Wolaytta",
	36943,
	"omv-nom",
	"Latn, Ethi",
	"Tiếng Wolaytta",
	"Wolaytta",
}

m["wam"] = {
	"Massachusett",
	56519,
	"alg-eas",
	"Latn",
}

m["wan"] = {
	"Wan",
	3913272,
	"dmn-nbe",
}

m["wao"] = {
	"Wappo",
	56530,
	"nai-ykn",
	"Latn",
}

m["wap"] = {
	"Wapishana",
	3450493,
	"awd",
	"Latn",
}

m["waq"] = {
	"Wageman",
	3436843,
	"aus-gun",
	"Latn",
}

m["war"] = {
	"tiếng Waray",
	34279,
	"phi",
	"Latn",
	"Tiếng Waray",
	"Waray",
	strip_diacritics = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}},
	standard_chars = {
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
	sort_key = {
		Latn = "tl-sortkey",
	},
}

m["was"] = {
	"Washo",
	34198,
}

m["wat"] = {
	"Kaninuwa",
	12952565,
	"poz-ocw",
	"Latn",
}

m["wau"] = {
	"Wauja",
	3450522,
	"awd",
	"Latn",
}

m["wav"] = {
	"Waka",
	3913394,
	"alv-mye",
}

m["waw"] = {
	"tiếng Waiwai",
	56632,
	"sai-prk",
	"Latn",
	"Tiếng Waiwai",
	"Waiwai",
}

m["wax"] = {
	"Watam",
	3566597,
	"paa",
	"Latn",
}

m["way"] = {
	"tiếng Wayana",
	5908753,
	"sai-gui",
	"Latn",
	"Tiếng Wayana",
	"Wayana",
}

m["waz"] = {
	"Wampur",
	7966957,
	"poz-ocw",
	"Latn",
}

m["wba"] = {
	"Warao",
	36946,
	"qfa-iso",
	"Latn",
}

m["wbb"] = {
	"Wabo",
	7958701,
	"poz-hce",
	"Latn",
}

m["wbe"] = {
	"Waritai",
	7969453,
	"paa-lkp",
	"Latn",
}

m["wbf"] = {
	"Wara",
	3914052,
	"alv-wan",
}

m["wbh"] = {
	"Wanda",
	7967153,
	"bnt-mwi",
}

m["wbi"] = {
	"Wanji",
	3376818,
	"bnt-bki",
	"Latn",
}

m["wbj"] = {
	"tiếng Alagwa",
	56621,
	"cus-sou",
	"Latn",
	"Tiếng Alagwa",
	"Alagwa",
}

m["wbk"] = {
	"Waigali",
	34196,
	"nur-sou",
}

m["wbl"] = {
	"tiếng Wakhi",
	34208,
	"xsc-skw",
	"Cyrl, Latn, Arab",
	"Tiếng Wakhi",
	"Wakhi",
	translit = {Cyrl = "tg-translit"},
}

m["wbm"] = {
	"Wa",
	12644869,
	"mkh-pal",
}

m["wbp"] = {
	"Warlpiri",
	1639998,
	"aus-pam",
	"Latn",
}

m["wbq"] = {
	"tiếng Waddar",
	6708569,
	"dra-tel",
	"Deva, Telu, Knda",
	"Tiếng Waddar",
	"Waddar",
	translit = { Telu = "te-translit" }
}

m["wbr"] = {
	"Wagdi",
	7959490,
	"inc-bhi",
}

m["wbt"] = {
	"Wanman",
	7967989,
}

m["wbv"] = {
	"Wajarri",
	3913856,
	"aus-psw",
	"Latn",
}

m["wbw"] = {
	"Woi",
	8029092,
	"poz-hce",
	"Latn",
}

m["wca"] = {
	"Yanomámi",
	7960056,
}

m["wci"] = {
	"tiếng Gbe Waci",
	36987,
	"alv-gbe",
	"Latn",
	"Tiếng Gbe Waci",
	"Gbe Waci",
}

m["wdd"] = {
	"Wandji",
	36976,
	"bnt-nze",
}

m["wdg"] = {
	"Wadaginam",
	7958930,
}

m["wdj"] = {
	"Wadjiginy",
	7959489,
}

m["wdt"] = {
	"Wendat",
	3567223,
	"iro-nor",
	"Latn",
	ancestors = "iro-ohu",
}

m["wdu"] = {
	"Wadjigu",
	10719025,
}

m["wdy"] = {
	"Wadjabangayi",
	nil,
}

m["wea"] = {
	"tiếng Wewaw",
	15895870,
	"kar",
	"Mymr",
	"Tiếng Wewaw",
	"Wewaw",
	translit = "ksw-translit",
}

m["wec"] = {
	"Wè Western",
	11159067,
	"kro-wee",
}

m["wed"] = {
	"Wedau",
	12953294,
	"poz-ocw",
	"Latn",
}

m["weh"] = {
	"Weh",
	7979690,
	"nic-rnw",
}

m["wei"] = {
	"Kiunum",
	7983230,
}

m["wem"] = {
	"Weme Gbe",
	18379970,
	"alv-gbe",
}

m["weo"] = {
	"Wemale",
	7982165,
	"poz-cma",
}

m["wer"] = {
	"Weri",
	11732752,
	"paa",
}

m["wes"] = {
	"Cameroon Pidgin",
	35541,
	"crp",
	"Latn",
	ancestors = "en",
}

m["wet"] = {
	"Perai",
	12953035,
	"poz-tim",
}

m["weu"] = {
	"Welaung",
	7980503,
	"tbq-kuk",
}

m["wew"] = {
	"Weyewa",
	4314526,
	"poz-cet",
	"Latn",
}

m["wfg"] = {
	"Yafi",
	8074520,
	"paa-pau",
}

m["wga"] = {
	"Wagaya",
	7959487,
	"aus-pam",
}

m["wgb"] = {
	"Wagawaga",
	7959485,
}

m["wgg"] = {
	"Wangganguru",
	7967859,
	"aus-kar",
	"Latn",
}

m["wgi"] = {
	"tiếng Wahgi",
	3565122,
	nil,
	"Latn",
	"Tiếng Wahgi",
	"Wahgi",
	
}

m["wgo"] = {
	"Waigeo",
	7959937,
	"poz-hce",
}

m["wgu"] = {
	"Wirangu",
	2092286,
	"aus-pam",
	"Latn",
}

m["wgy"] = {
	"Warrgamay",
	3915942,
	"aus-pam",
	"Latn",
}

m["wha"] = {
	"Manusela",
	3287127,
	"poz-cma",
}

m["whg"] = {
	"North Wahgi",
	12953273,
	"ngf",
}

m["whk"] = {
	"Wahau Kenyah",
	7959737,
	"poz-swa",
}

m["whu"] = {
	"Wahau Kayan",
	12473397,
}

m["wib"] = {
	"Southern Toussian",
	11158982,
	"alv-sav",
}

m["wic"] = {
	"Wichita",
	56513,
	"cdd",
	"Latn",
}

m["wie"] = {
	"Wik-Epa",
	10720035,
	"aus-pmn",
}

m["wif"] = {
	"Wik-Keyangan",
	10720037,
	"aus-pmn",
}

m["wig"] = {
	"Wik-Ngathana",
	3915695,
	"aus-pmn",
}

m["wih"] = {
	"Wik-Me'anha",
	10720039,
	"aus-pmn",
}

m["wii"] = {
	"Minidien",
	6865237,
	"qfa-tor",
	"Latn",
}

m["wij"] = {
	"Wik-Iiyanh",
	10720036,
	"aus-pmn",
}

m["wik"] = {
	"Wikalkan",
	7999800,
	"aus-pmn",
}

m["wil"] = {
	"Wilawila",
	10720050,
	"aus-wor",
}

m["wim"] = {
	"Wik-Mungkan",
	2092246,
	"aus-pmn",
	"Latn",
}

m["win"] = {
	"tiếng Hocak",
	1957108,
	"sio-msv",
	"Latn",
	"Tiếng Hocak",
	"Hocak",
}

m["wir"] = {
	"Wiraféd",
	12953970,
	"tup-gua",
	"Latn",
}

m["wiu"] = {
	"Wiru",
	8027044,
	"paa",
}

m["wiv"] = {
	"Muduapa",
	3121040,
	"poz-ocw",
	"Latn",
}

m["wiy"] = {
	"tiếng Wiyot",
	36937,
	"aql",
	"Latn",
	"Tiếng Wiyot",
	"Wiyot",
}

m["wja"] = {
	"Waja",
	3914415,
	"alv-wjk",
}

m["wji"] = {
	"tiếng Warji",
	3440381,
	"cdc-wst",
	nil,
	"Tiếng Warji",
	"Warji",
}

m["wka"] = {
	"tiếng Kw'adza",
	3807652,
	"cus-sou",
	nil,
	"Tiếng Kw'adza",
	"Kw'adza",
}

m["wkb"] = {
	"Kumbaran",
	16878146,
	"dra-sdo",
}

m["wkd"] = {
	"Mo",
	7960881,
	"poz-ocw",
	"Latn",
}

m["wkl"] = {
	"tiếng Kalanad",
	6350515,
	"dra-mal",
	"Mlym",
	"Tiếng Kalanad",
	"Kalanad",
	translit = "ml-translit",
}

m["wku"] = {
	"tiếng Kunduvadi",
	6444383,
	"dra-mal",
	"Mlym",
	"Tiếng Kunduvadi",
	"Kunduvadi",
	translit = "ml-translit",
}

m["wkw"] = {
	"Wakawaka",
	10719110,
	"aus-pam",
}

m["wky"] = {
	"Wangkayutyuru",
	33060533,
	"aus-kar",
}

m["wla"] = {
	"Walio",
	7961958,
}

m["wlc"] = {
	"Mwali Comorian",
	3319155,
	"bnt-com",
	"Latn",
	sort_key = "bnt-com-sortkey",
}

m["wle"] = {
	"tiếng Wolane",
	12645275,
	"sem-eth",
	"Latn, Ethi",
	"Tiếng Wolane",
	"Wolane",
}

m["wlg"] = {
	"Kunbarlang",
	5618523,
	"aus-gun",
	"Latn",
}

m["wli"] = {
	"Waioli",
	7960241,
	"paa-nha"
}

m["wlk"] = {
	"Wailaki",
	20832,
	"ath-pco",
	"Latn",
}

m["wll"] = {
	"Wali (Sudan)",
	30597440,
	"nub-hil",
}

m["wlm"] = {
	"tiếng Wales trung đại",
	2487263,
	"cel-brw",
	"Latn",
	"Tiếng Wales trung đại",
	"Wales trung đại",
	ancestors = "owl",
	entry_name = {
		from = {"Ð", "ð"},
		to = {"D", "d"}
	},
	sort_key = "wlm-sortkey",
}

m["wlo"] = {
	"tiếng Wolio",
	1185114,
	"poz-wot",
	"Latn, Arab",
	"Tiếng Wolio",
	"Wolio"
}

m["wlr"] = {
	"Wailapa",
	7960062,
	"poz-vnc",
	"Latn",
}

m["wls"] = {
	"tiếng Wallis",
	36979,
	"poz-pnp",
	"Latn",
	"Tiếng Wallis",
	"Wallis",
}

m["wlu"] = {
	"Wuliwuli",
	8039208,
}

m["wlv"] = {
	"Wichí Lhamtés Vejoz",
	13526867,
	"sai-wic",
	"Latn",
}

m["wlw"] = {
	"Walak",
	7961258,
}

m["wlx"] = {
	"Wali (Ghana)",
	36895,
	"nic-mre",
	"Latn",
}

m["wly"] = {
	"Waling",
	7961957,
	"sit-kic",
	ancestors = "bap",
}

m["wmb"] = {
	"Wambaya",
	2083197,
	"aus-mir",
}

m["wmc"] = {
	"Wamas",
	7966909,
	"ngf-mad",
}

m["wmd"] = {
	"Mamaindé",
	3284890,
	"sai-nmk",
	"Latn",
}

m["wme"] = {
	"tiếng Wambule",
	56785,
	"sit-kiw",
	"Latn",
	"Tiếng Wambule",
	"Wambule",
}

m["wmh"] = {
	"Waima'a",
	7960132,
	"poz-tim",
	"Latn",
}

m["wmi"] = {
	"Wamin",
	7966934,
}

m["wmm"] = {
	"Maiwa (Indonesia)",
	6737226,
	"poz",
	"Latn",
}

m["wmn"] = {
	"Waamwang",
	7958575,
	"poz-cln",
	"Latn",
}

m["wmo"] = {
	"Wam",
	8030620,
	"qfa-tor",
	"Latn",
}

m["wms"] = {
	"Wambon",
	7966922,
	"ngf",
	"Latn",
}

m["wmt"] = {
	"Walmajarri",
	2232696,
	"aus-pam",
	"Latn",
}

m["wmw"] = {
	"Mwani",
	3042206,
	"bnt-swh",
	"Latn",
}

m["wmx"] = {
	"Womo",
	8031646,
	"paa-msk",
	"Latn",
}

m["wnb"] = {
	"Wanambre",
	7967057,
	"ngf",
	"Latn",
}

m["wnc"] = {
	"Wantoat",
	7968184,
	"ngf-fin",
	"Latn",
}

m["wnd"] = {
	"Wandarang",
	3913767,
	"aus-arn",
	"Latn",
}

m["wne"] = {
	"tiếng Waneci",
	7967334,
	"ira-pat",
	"ps-Arab",
	"Tiếng Waneci",
	"Waneci",
}

m["wng"] = {
	"Wanggom",
	11732736,
	"ngf",
	"Latn",
}

m["wni"] = {
	"Ndzwani Comorian",
	2850262,
	"bnt-com",
	"Latn",
	sort_key = "bnt-com-sortkey",
}

m["wnk"] = {
	"Wanukaka",
	2370136,
	"poz",
	"Latn",
}

m["wnm"] = {
	"Wanggamala",
	7967860,
	"aus-kar",
	"Latn",
}

m["wno"] = {
	"Wano",
	3566166,
	"ngf",
	"Latn",
}

m["wnp"] = {
	"Wanap",
	7967060,
	"qfa-tor",
	"Latn",
}

m["wnu"] = {
	"Usan",
	7901709,
	"ngf",
	"Latn",
}

m["wnw"] = {
	"Wintu",
	56754,
	"nai-wtq",
	"Latn",
}

m["wny"] = {
	"Wanyi",
	7968201,
	"aus-gar",
	"Latn",
}

m["woa"] = {
	"Tyaraity",
	10706951,
}

m["wob"] = {
	"tiếng Wobé",
	3915363,
	"kro-wee",
	nil,
	"Tiếng Wobé",
	"Wobé",
}

m["woc"] = {
	"Wogeo",
	8029061,
	"poz-ocw",
	"Latn",
}

m["wod"] = {
	"Wolani",
	8029704,
	"ngf",
	"Latn",
}

m["woe"] = {
	"Woleaian",
	34037,
	"poz-mic",
	"Latn, Wole",
}

m["wog"] = {
	"Wogamusin",
	56991,
	"paa-spk",
	"Latn",
}

m["woi"] = {
	"Kamang",
	8029096,
	"ngf",
	"Latn",
}

m["wok"] = {
	"Longto",
	35795,
	"alv-dur",
	"Latn",
}

m["wom"] = {
	"Perema",
	3913378,
	"alv-lek",
	"Latn",
}

m["won"] = {
	"Wongo",
	8032058,
	"bnt-bsh",
	"Latn",
}

m["woo"] = {
	"Manombai",
	6751253,
	"poz",
	"Latn",
}

m["wor"] = {
	"Woria",
	8034514,
	"paa-egb",
	"Latn",
}

m["wos"] = {
	"Hanga Hundi",
	6450232,
	"paa-spk",
	"Latn",
}

m["wow"] = {
	"tiếng Wawonii",
	3566780,
	"poz-btk",
	"Latn",
	"Tiếng Wawonii",
	"Wawonii",
}

m["wpc"] = {
	"Wirö",
	12953684,
	nil,
	"Latn",
}

m["wra"] = {
	"Warapu",
	56739,
	"paa-msk",
	"Latn",
}

m["wrb"] = {
	"Warluwara",
	3913761,
	"aus-pam",
	"Latn",
}

m["wrg"] = {
	"Warungu",
	7970854,
	"aus-pam",
	"Latn",
}

m["wrh"] = {
	"tiếng Wiradjuri",
	3913840,
	"aus-cww",
	"Latn",
	"Tiếng Wiradjuri",
	"Wiradjuri",
}

m["wri"] = {
	"Wariyangga",
	10719289,
	"aus-psw",
	"Latn",
}

m["wrk"] = {
	"Garawa",
	2524022,
	"aus-gar",
	"Latn",
}

m["wrl"] = {
	"Warlmanpa",
	3913823,
	"aus-pam",
}

m["wrm"] = {
	"Warumungu",
	1764544,
	"aus-pam",
	"Latn",
}

m["wrn"] = {
	"Warnang",
	36971,
	"alv-hei",
}

m["wro"] = {
	"Worora",
	3504106,
	"aus-wor",
}

m["wrp"] = {
	"Waropen",
	7969851,
	"poz-hce",
	"Latn",
}

m["wrr"] = {
	"tiếng Wardaman",
	3913842,
	"aus-yng",
	"Latn",
	"Tiếng Wardaman",
	"Wardaman"
}

m["wrs"] = {
	"Waris",
	3502610,
	"paa-brd",
}

m["wru"] = {
	"Waru",
	3566463,
}

m["wrv"] = {
	"Waruna",
	7971078,
}

m["wrw"] = {
	"Gugu Warra",
	5615286,
}

m["wrx"] = {
	"Wae Rana",
	7959375,
}

m["wrz"] = {
	"Warray",
	7969971,
	"aus-gun",
}

m["wsa"] = {
	"Warembori",
	56459,
}

m["wsi"] = {
	"Wusi",
	8039349,
	"poz-vnc",
	"Latn",
}

m["wsk"] = {
	"Waskia",
	7972683,
	"ngf-mad",
	"Latn",
}

m["wsr"] = {
	"Owenia",
	7114727,
}

m["wss"] = {
	"Wasa",
	36914,
	"alv-ctn",
	ancestors = "ak",
}

m["wsu"] = {
	"Wasu",
	7972892,
}

m["wsv"] = {
	"Wotapuri-Katarqalai",
	3877569,
	"inc-koh",
}

m["wtf"] = {
	"Watiwa",
	35316,
	"ngf-mad",
	"Latn",
}

m["wth"] = {
	"Wathaurong",
	7974656,
	"aus-pam",
	"Latn",
}

m["wti"] = {
	"Berta",
	33178,
}

m["wtk"] = {
	"Watakataui",
	7972975,
	"paa-spk",
}

m["wtm"] = {
	"Mewati",
	2605943,
	"inc-wes",
}

m["wtw"] = {
	"tiếng Wotu",
	12473488,
	"poz",
	"Latn",
	"Tiếng Wotu",
	"Wotu"
}

m["wua"] = {
	"Wikngenchera",
	10720045,
	"aus-pmn",
}

m["wub"] = {
	"Wunambal",
	3913805,
	"aus-wor",
}

m["wud"] = {
	"Wudu",
	36972,
	"alv-gbe",
	"Latn",
}

m["wuh"] = {
	"tiếng Ngũ Đồn",
	1012917,
	"crp",
	"Latn",
	"Tiếng Ngũ Đồn",
	"Ngũ Đồn",
	ancestors = "cmn, bo, peh",
}

m["wul"] = {
	"Silimo",
	11732514,
	"ngf",
}

m["wum"] = {
	"Wumbvu",
	36891,
	"bnt-kel",
	"Latn",
}

m["wun"] = {
	"Bungu",
	4997686,
	"bnt-mby",
	"Latn",
}

m["wur"] = {
	"Wurrugu",
	8039305,
	"aus-wdj",
}

m["wut"] = {
	"Wutung",
	56743,
	"paa-msk",
	"Latn",
}

m["wuu"] = {
	"tiếng Ngô",
	34290,
	"zhx",
	"Hants",
	"Tiếng Ngô",
	"Ngô",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["wuv"] = {
	"Wuvulu-Aua",
	3062746,
	"poz-aay",
}

m["wux"] = {
	"Wulna",
	13591670,
}

m["wuy"] = {
	"Wauyai",
	12953295,
	"poz-hce",
}

m["wwa"] = {
	"tiếng Waama",
	7958576,
	"nic-eov",
	"Latn",
	"Tiếng Waama",
	"Waama",
}

m["wwo"] = {
	"Dorig",
	3037047,
	"poz-vnc",
}

m["wwr"] = {
	"Warrwa",
	7970852,
}

m["www"] = {
	"Wawa",
	36889,
	"nic-mmb",
	"Latn",
}

m["wxa"] = {
	"tiếng Ngõa Hương",
	2252191,
	"zhx",
	"Hants",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["wxw"] = {
	"Wardandi",
	nil,
}

m["wya"] = {
	"Wyandot",
	1185119,
	"iro-nor",
	"Latn",
}

m["wyb"] = {
	"tiếng Ngiyambaa",
	3913825,
	"aus-cww",
	"Latn",
	"Tiếng Ngiyambaa",
	"Ngiyambaa",
}

m["wyi"] = {
	"tiếng Woiwurrung",
	8029099,
	"aus-pam",
	"Latn",
	"Tiếng Woiwurrung",
	"Woiwurrung",
}

m["wym"] = {
	"tiếng Wymysorys",
	56485,
	"gmw-hgm",
	"Latn",
	"Tiếng Wymysorys",
	"Wymysorys",
	ancestors = "gmh",
	strip_diacritics = {remove_diacritics = c.dotabove},
}

m["wyr"] = {
	"Wayoró",
	2875044,
	"tup",
}

m["wyy"] = {
	"Western Fijian",
	3062751,
	"poz-occ",
}

return require("Module:languages").finalizeData(m, "language")