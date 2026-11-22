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

m["yaa"] = {
	"亞米納瓦語",
	3026110,
	"sai-pan",
	"Latn",
}

m["yab"] = {
	"尤胡普語",
	3573115,
	"sai-nad",
	"Latn",
}

m["yac"] = {
	"帕斯谷亞利語",
	12953309,
	"ngf-yal",
	"Latn",
}

m["yad"] = {
	"亞古阿語",
	3182567,
	"sai-pey",
	"Latn",
}

m["yae"] = {
	"Pumé",
	3121835,
	"qfa-dis", -- isolate per Glottolog; possibly in an Esmeralda-Yaruro family with Esmeralda
	"Latn",
}

m["yaf"] = {
	"亞卡語",
	35588,
	"bnt-yak",
	"Latn",
}

m["yag"] = {
	"雅加語",
	531826,
	"qfa-iso",
	"Latn",
}

m["yah"] = {
	"雅茲古拉米語",
	34186,
	"ira-shy",
	"Latn, Cyrl",
	translit = "yah-translit",
}

m["yai"] = {
	"雅格諾比語",
	34247,
	"ira-sgc",
	"Latn, Cyrl",
	translit = "tg-translit",
}

m["yaj"] = {
	"班達-揚蓋雷語",
	8048561,
	"bad",
}

m["yak"] = {
	"亞基馬語",
	35976053,
	"nai-shp",
	"Latn",
	ancestors = "nai-spt",
}

m["yal"] = {
	"亞倫卡語",
	35524,
	"dmn-sya",
	"Latn",
}

m["yam"] = {
	"亞姆巴語",
	36904,
	"nic-nka",
	"Latn",
}

m["yan"] = {
	"馬揚納語",
	3302929,
	"nai-min",
	"Latn",
}

m["yao"] = {
	"堯語",
	36902,
	"bnt-rvm",
	"Latn",
}

m["yap"] = {
	"雅浦語",
	34029,
	"poz-oce",
	"Latn",
}

m["yaq"] = {
	"亞基語",
	34191,
	"azc-trc",
	"Latn",
}

m["yar"] = {
	"亞巴拉納語",
	3571238,
	"sai-map",
	"Latn",
}

m["yas"] = {
	"古努語",
	36358,
	"nic-ymb",
	"Latn",
}

m["yat"] = {
	"揚貝塔語",
	8048020,
	"nic-mbw",
	"Latn",
}

m["yau"] = {
	"Yuwana",
	5876347,
}

m["yav"] = {
	"洋卞語",
	12953315,
	"nic-ymb",
	"Latn",
}

m["yaw"] = {
	"亞瓦拉比其語",
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
	"洛卡語",
	3914439,
	"nic-uce",
	"Latn",
}

m["yba"] = {
	"亞拉語",
	3914920,
	"alv-ido",
	"Latn",
}

m["ybb"] = {
	"耶姆巴語",
	36917,
	"bai",
	"Latn",
}

m["ybe"] = {
	"西部裕固語",
	34224,
	"trk-ssb",
	"Latn, Ougr",
	ancestors = "oui",
}

m["ybh"] = {
	"雅卡語",
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
	"Latn",
}

m["ybk"] = {
	"黑木吉語",
	63340714,
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
	"ngf-num",
	"Latn",
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
	"ngf-yag",
	"Latn",
}

m["ybx"] = {
	"Yawiyo",
	8050463,
	"paa-wal",
	"Latn",
}

m["yby"] = {
	"Yaweyuha",
	3571231,
	"ngf-gor",
	"Latn",
}

m["ych"] = {
	"車蘇語",
	30334841,
	"tbq-nas",
}

m["ycl"] = {
	"倮倮潑語",
	56441,
	"tbq-llo",
	"Latn",
}

m["ycn"] = {
	"尤庫納語",
	3438356,
	"awd-nwk",
	"Latn",
}

m["ycp"] = {
	"切皮亞語",
	46603077,
	"tbq-han",
}

m["ycr"] = {
	"寒溪語",
	10955036,
	"crp",
	"Latn",
}

m["yda"] = {
	"揚達語",
	8048318,
	"aus-pam",
	"Latn",
}

m["yde"] = {
	"Yangum Dey",
	63340998,
	"paa-pal",
	"Latn",
}

m["ydg"] = {
	"伊特格哈語",
	34179,
	"ira-mny",
	"Arab",
}

m["ydk"] = {
	"約依迪克語",
	8054512,
	"ngf-han",
	"Latn",
}

m["yea"] = {
	"拉武拉語",
	7296830,
	"dra-mal",
	"Knda, Mlym",
	-- Knda translit in [[Module:scripts/data]]
	-- Mlym translit in [[Module:scripts/data]]
}

m["yec"] = {
	"葉尼什語",
	1365342,
	"gmw-hgm",
	"Latn",
	ancestors = "gmh",
}

m["yee"] = {
	"伊馬斯語",
	36954,
	"paa-lse",
	"Latn",
}

m["yei"] = {
	"耶尼語",
	34213,
	"nic-mmb",
}

m["yej"] = {
	"猶太-希臘語",
	34200,
	"grk",
	"Hebr",
	ancestors = "gkm",
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["yen"] = {
	"延當語",
	3914882,
	"alv-mye",
	"Latn",
}

m["yer"] = {
	"塔羅克語",
	3914953,
	"nic-tar",
	"Latn",
}

m["yes"] = {
	"耶斯夸語",
	3914962,
	"nic-plc",
	"Latn",
}

m["yet"] = {
	"耶特法語",
	8053020,
	"qfa-dis", -- Papuan; Glottolog and Foley treat as an isolate, Ross puts in Sepik, Usher puts in South Pauwasi
	"Latn",
}

m["yeu"] = {
	"耶魯庫拉語",
	3535117,
	"dra-tam",
}

m["yev"] = {
	"雅朋達語",
	11044384,
	"paa-wpa",
	"Latn",
}

m["yey"] = {
	"耶伊語",
	8053347,
	"bnt",
	"Latn",
}

m["ygi"] = {
	"伊寧蓋語",
	63341096,
	"aus-pam",
	"Latn",
}

m["ygl"] = {
	"Yangum Gel",
	63341179,
	"paa-pal",
	"Latn",
}

m["ygm"] = {
	"亞戈米語",
	20771657,
	"ngf-war",
	"Latn",
}

m["ygp"] = {
	"峨頗語",
	5548692,
	"tbq-nas",
}

m["ygr"] = {
	"亞加里阿語",
	8046690,
	"ngf-kya",
	"Latn",
}

m["ygs"] = {
	"雍古手語",
	16211970,
	"sgn",
}

m["ygu"] = {
	"尤古爾語",
	8060437,
	"aus-arn",
	"Latn",
}

m["ygw"] = {
	"Yagwoia",
	8046761,
	"ngf-ang",
	"Latn",
}

m["yha"] = {
	"巴哈語",
	2879238,
	"qfa-kra",
}

m["yhl"] = {
	"圪勒頗普佤語",
	63341181,
	"tbq-phw",
}

m["yia"] = {
	"英加爾達語",
	3913777,
	"aus-psw",
	"Latn",
}

m["yif"] = {
	"阿車語",
	10949828,
	"tbq-sel",
}

m["yig"] = {
	"烏撒納蘇語",
	12953334,
	"tbq-nas",
}

m["yii"] = {
	"依蒂尼語",
	3053283,
	"aus-yid",
	"Latn",
}

m["yij"] = {
	"因吉班迪語",
	3121073,
	"aus-nga",
	"Latn",
}

m["yik"] = {
	"東山壩臘羅語",
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
	"仆拉語",
	7187103,
	"tbq-nso",
}

m["yiq"] = {
	"密察語",
	6827993,
	"tbq-llo",
	"Latn",
}

m["yir"] = {
	"北奧尤語",
	12642164,
	"ngf-awy",
	"Latn",
}

m["yis"] = {
	"乙斯語",
	8053831,
	"paa-wap",
	"Latn",
}

m["yit"] = {
	"東臘魯語",
	12953328,
	"tbq-lal",
}

m["yiu"] = {
	"阿鄔語",
	11163308,
	"tbq-nlo",
}

m["yiv"] = {
	"北尼蘇語",
	25559454,
	"tbq-nis",
}

m["yix"] = {
	"阿細語",
	4830439,
	"tbq-axi",
}

m["yiy"] = {
	"伊爾-約龍特語",
	8053819,
	"aus-pmn",
	"Latn",
}

m["yiz"] = {
	"阿哲語",
	4832535,
	"tbq-axi",
}

m["yka"] = {
	"亞坎語",
	3571351,
	"poz-sbj",
	"Latn",
}

m["ykg"] = {
	"北尤卡吉爾語",
	56319,
	"qfa-yuk",
	"Cyrl",
	translit = "ykg-translit",
}

m["ykh"] = {
	"哈米尼干語",
	3196052,
	"xgn-cen",
	"Mong, Latn, Cyrl",
	-- Mong translit, display_text and strip_diacritics in [[Module:scripts/data]]
}

m["yki"] = {
	"約凱語",
	3832977,
}

m["ykk"] = {
	"Yakaikeke",
	8047041,
	"poz-oce",
}

m["ykl"] = {
	"科魯拉語",
	6401849,
	"tbq-phw",
}

m["ykm"] = {
	"卡普語",
	8047048,
	"poz-ocw",
	"Latn",
}

m["ykn"] = {
	"跨恩斯話",
	6440952,
	"tbq-tal",
}

m["yko"] = {
	"亞薩語",
	36899,
	"bnt-yko",
	"Latn",
}

m["ykr"] = {
	"耶科拉語",
	11732781,
	"ngf-bin",
	"Latn",
}

m["ykt"] = {
	"嘎蘇話",
	6377155,
	"sit-mnz",
}

m["yku"] = {
	"跨瑪斯話",
	6441074,
	"tbq-tal",
}

m["yky"] = {
	"亞科馬語",
	3571364,
	"nic-ngd",
	"Latn",
}

m["yla"] = {
	"烏爾瓦語 (新幾內亞)",
	8050336,
	"paa-wke",
	"Latn",
}

m["ylb"] = {
	"亞萊巴語",
	37710600,
	"poz-oce",
}

m["yle"] = {
	"耶里多涅語",
	36942,
	nil,
	"Latn",
}

m["ylg"] = {
	"耶洛古語",
	8052024,
	"paa-nnd",
	"Latn",
}

m["yli"] = {
	"昂古魯克亞利語",
	3514481,
	"ngf-yal",
	"Latn",
}

m["yll"] = {
	"乙爾語",
	3501797,
	"paa-wap",
	"Latn",
}

m["ylm"] = {
	"留米語",
	12953327,
	"tbq-lso",
}

m["yln"] = {
	"郎念布央語",
	2929025,
	"qfa-buy",
}

m["ylo"] = {
	"納若語",
	6961032,
	"tbq-tal",
}

m["ylr"] = {
	"亞蘭加語",
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
	"Nyâlayu",
	303154,
	"poz-cln",
	"Latn",
}

m["ymb"] = {
	"Yambes",
	8048022,
	"paa-kom",
	"Latn",
}

m["ymc"] = {
	"南木吉語",
	57259564,
	"tbq-muj",
}

m["ymd"] = {
	"木達語",
	6931494,
	"tbq-han",
}

m["yme"] = {
	"Yameo",
	3121032,
	"sai-pey",
}

m["ymg"] = {
	"Yamongeri",
	11008893,
	"bnt-mon",
	"Latn",
	ancestors = "lol",
}

m["ymh"] = {
	"米利語",
	12953329,
	"tbq-lso",
}

m["ymi"] = {
	"墨幾語",
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
	"馬艾語",
	36221,
	"cus-som",
	"Latn",
}

m["ymn"] = {
	"蘇努姆語",
	8048083,
	"poz-ocw",
	"Latn",
}

m["ymo"] = {
	"Yangum Mon",
	50313949,
	"paa-pal",
	"Latn",
}

m["ymp"] = {
	"Yamap",
	8047913,
	"poz-ocw",
	"Latn",
}

m["ymq"] = {
	"期臘木吉語",
	56826369,
	"tbq-muj",
}

m["ymr"] = {
	"馬拉薩爾語",
	16889525,
	"dra-tam",
}

m["yms"] = {
	"密細亞語",
	2577228,
	"ine",
}

m["ymx"] = {
	"北木吉語",
	56751275,
	"tbq-muj",
}

m["ymz"] = {
	"木支語",
	6944445,
	"tbq-muj",
}

m["yna"] = {
	"阿羅語",
	4737539,
	"tbq-nas",
}

m["ynb"] = {
	"Yamben",
	65046092,
	"ngf-mad",
	"Latn",
}

m["ynd"] = {
	"揚德魯萬塔語",
	8048335,
	"aus-kar",
	"Latn",
}

m["yne"] = {
	"崀峨語",
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
	"瑙坎語",
	27963,
	"ypk",
	"Cyrl, Latn",
}

m["ynl"] = {
	"Yangulam",
	8048663,
	"ngf-nur", -- excluded from Nuru by Usher
	"Latn",
}

m["ynn"] = {
	"亞納語",
	56419,
	"qfa-iso",
}

m["yno"] = {
	"傣允語",
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
	"約巴語",
	8054220,
	"poz-ocw",
	"Latn",
}

m["yog"] = {
	"尤加德語",
	8054343,
	"phi",
	"Latn",
}

m["yoi"] = {
	"與那國語",
	34243,
	"jpx-sry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	strip_diacritics = s["jpx-stripdiacritics"],
	sort_key = s["jpx-sortkey"],
}

m["yol"] = {
	"約拉語",
	56395,
	"gmw-ian",
	"Latn",
}

m["yom"] = {
	"榮貝語",
	10961975,
	"bnt-kng",
	"Latn",
}

m["yon"] = {
	"Yongkom",
	8055002,
	"ngf-lok",
	"Latn",
}

m["yox"] = {
	"與論語",
	2424943,
	"jpx-nry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	strip_diacritics = s["jpx-stripdiacritics"],
	sort_key = s["jpx-sortkey"],
}

m["yoy"] = {
	"堯依語",
	3503717,
	"tai",
}

m["ypa"] = {
	"帕拉語",
	36211907,
	"tbq-drp",
}

m["ypb"] = {
	"拉波普佤語",
	63341239,
	"tbq-phw",
}

m["ypg"] = {
	"普拉語",
	7187058,
	"tbq-drp",
}

m["yph"] = {
	"富帕語",
	7188378,
	"tbq-urp",
}

m["ypm"] = {
	"富馬語",
	63341260,
	"tbq-muj",
}

m["ypn"] = {
	"阿尼普佤語",
	33590104,
	"tbq-phw",
}

m["ypo"] = {
	"阿洛普拉語",
	33522157,
	"tbq-drp",
}

m["ypp"] = {
	"富巴語",
	48565467,
	"tbq-urp",
}

m["ypz"] = {
	"富匝語",
	48565339,
	"tbq-urp",
}

m["yra"] = {
	"雅雷凱語",
	8052531,
}

m["yrb"] = {
	"雅雷巴語",
	3571876,
	"ngf-yar",
	"Latn",
}

m["yre"] = {
	"雅烏爾語",
	3913951,
	"dmn-mda",
}

m["yri"] = {
	"亞里語",
	8049616,
}

m["yrl"] = {
	"奈恩加圖語",
	34333,
	"tup-gua",
	"Latn",
	ancestors = "tpw",
}

m["yrn"] = {
	"耶容語",
	3572191,
	"qfa-buy",
}

m["yro"] = {
	"Yaroamë",
	24190396,
	"sai-ynm",
	"Latn",
}

m["yrw"] = {
	"Yarawata",
	8049237,
	"ngf-num",
	"Latn",
}

m["yry"] = {
	"雅爾魯延迪語",
	33061540,
	"aus-kar",
	"Latn",
}

m["ysc"] = {
	"雅西克語",
	2479368,
	"xsc-sar",
	"Latn",
	ancestors = "oos",
}

m["ysd"] = {
	"撒慕語",
	7408902,
	"tbq-kzh",
}

m["ysg"] = {
	"鎖內嘎話",
	7560736,
	"tbq-tal",
}

m["ysl"] = {
	"南斯拉夫手語",
	8060373,
	"sgn",
}

m["ysn"] = {
	"撒尼語",
	1055287,
	"tbq-axi",
	"Latn", -- Not Yiii, which is the Nuosu syllabary, and does not cover classical Yi scripts.
}

m["yso"] = {
	"尼斯語",
	12953326,
	"tbq-sel",
}

m["ysp"] = {
	"南倮倮潑語",
	12633989,
	"tbq-llo",
}

m["ysr"] = {
	"西萊尼克語",
	28156,
	"ypk",
	"Cyrl",
	translit = "ysr-translit",
	strip_diacritics = {remove_diacritics = c.acute .. c.macron},
}

m["yss"] = {
	"Yessan-Mayo",
	8052927,
	"paa-sep",
	"Latn",
}

m["ysy"] = {
	"撒涅語",
	7418287,
	"tbq-kzh",
}

m["yta"] = {
	"他留語",
	16999095,
	"tbq-tal",
}

m["ytl"] = {
	"堂郎語",
	7786695,
	"tbq-lso",
}

m["ytp"] = {
	"脫潑語",
	7796015,
	"tbq-muj",
}

m["ytw"] = {
	"Yout Wam",
	31819036,
	"ngf-yup",
	"Latn",
}

m["yty"] = {
	"亞泰語",
	63341274,
	"aus-pmn",
	"Latn",
}

m["yua"] = {
	"尤卡坦瑪雅語",
	13354,
	"myn",
	"Latn",
}

m["yub"] = {
	"尤甘巴爾語",
	3446663,
}

m["yuc"] = {
	"尤奇語",
	34204,
	"qfa-iso",
	"Latn",
}

m["yue"] = {
	"粵語",
	9186,
	"zhx-yue",
	"Hants, Latn",
	wikimedia_codes = "yue, zh-yue",
	generate_alternants = "zh-generatealternants",
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
	"尤格語",
	56311,
	"qfa-yke",
	"Cyrl",
}

m["yui"] = {
	"Yurutí",
	3573266,
	"sai-tuc",
	"Latn",
}

m["yuj"] = {
	"卡爾卡爾-尤里語",
	2992906,
	"paa-epw",
	"Latn",
}

m["yuk"] = {
	"尤基語",
	36993,
	"nai-ykn",
	"Latn",
}

m["yul"] = {
	"尤盧語",
	3915595,
	"csu-bba",
}

m["yum"] = {
	"尤馬語",
	3573199,
	"nai-yuc",
	"Latn",
}

m["yun"] = {
	"貝納語",
	3913283,
	"alv-yun",
	"Latn",
}

m["yup"] = {
	"尤克帕語",
	3441447,
	"sai-yuk",
	"Latn",
}

m["yuq"] = {
	"尤奇語",
	8061440,
	"tup-gua",
	"Latn",
}

m["yur"] = {
	"尤羅克語",
	34685,
	"aql",
	"Latn",
}

m["yut"] = {
	"尤普納語",
	12953338,
	"ngf-yup",
	"Latn",
}

m["yuw"] = {
	"Finisterre Yau",
	12953319,
	"ngf-ynu",
	"Latn",
}

m["yux"] = {
	"南尤卡吉爾語",
	56545,
	"qfa-yuk",
	"Cyrl",
	translit = "yux-translit",
}

m["yuy"] = {
	"東部裕固語",
	29902,
	"xgn-sou",
	"Latn",
}

m["yuz"] = {
	"尤拉卡雷語",
	2640646,
	"qfa-iso",
	"Latn",
}

m["yva"] = {
	"雅瓦語",
	3572020,
	"paa-ysa",
	"Latn",
}

m["yvt"] = {
	"Yavitero",
	3441427,
	"awd",
	"Latn",
}

m["ywa"] = {
	"卡勞語",
	6354305,
	"paa-sep",
	"Latn",
}

m["ywg"] = {
	"因哈旺卡語",
	8053734,
	"aus-nga",
	"Latn",
}

m["ywl"] = {
	"西臘魯語",
	12953325,
	"tbq-lal",
}

m["ywn"] = {
	"雅瓦那瓦語",
	10322118,
	"sai-pan",
	"Latn",
}

m["ywq"] = {
	"納蘇語",
	25559456,
	"tbq-nas",
	"Plrd", -- Not Yiii, which is the Nuosu syllabary, and does not cover classical Yi scripts.
}

m["ywr"] = {
	"雅烏魯語",
	8050479,
	"aus-nyu",
	"Latn",
}

m["ywt"] = {
	"中臘羅語",
	12953336,
	"tbq-lal",
}

m["ywu"] = {
	"烏蒙語",
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
	"馬亞瓦利語",
	33060513,
	"aus-pam",
	"Latn",
}

m["yxg"] = {
	"亞加拉語",
	16979305,
	"aus-pam",
	"Latn",
}

m["yxl"] = {
	"亞爾利語",
	46264708,
	"aus-pam",
	"Latn",
}

m["yxm"] = {
	"因溫語",
	8053763,
	"aus-pam",
	"Latn",
}

m["yxu"] = {
	"尤尤語",
	8062232,
	"aus-pam",
	"Latn",
}

m["yxy"] = {
	"亞布拉亞布拉語",
	8046394,
	"aus-pam",
	"Latn",
}

m["yyu"] = {
	"托里切利堯語",
	8050328,
	"paa-wap",
	"Latn",
}

m["yyz"] = {
	"阿彝子語",
	20527363,
	"tbq-nas",
}

m["yzg"] = {
	"峨馬布央語",
	16115619,
	"qfa-buy",
}

m["yzk"] = {
	"綽闊語",
	8073523,
	"tbq-phw",
}

return require("Module:languages").finalizeData(m, "language")