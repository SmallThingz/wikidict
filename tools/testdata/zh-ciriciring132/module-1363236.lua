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
	"下塔納納語",
	28565,
	"ath-nor",
	"Latn",
}

m["tab"] = {
	"塔巴薩蘭語",
	34079,
	"cau-esm",
	"Cyrl, Latn, Arab",
	translit = {
		Cyrl = "tab-translit",
	},
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"]
	},
	strip_diacritics = {
		Cyrl = s["cau-Cyrl-stripdiacritics"],
		Latn = s["cau-Latn-stripdiacritics"],
	},
	sort_key = {
		Cyrl = "tab-sortkey",
	}
}

m["tac"] = {
	"低地塔拉烏馬拉語",
	15616384,
	"azc-trc",
	"Latn",
}

m["tad"] = {
	"陶塞語",
	2356440,
	"paa-wlp",
	"Latn",
}

m["tae"] = {
	"塔里阿納語",
	732726,
	"awd-nwk",
	"Latn",
}

m["taf"] = {
	"塔比拉貝語",
	7684673,
	"tup-gua",
	"Latn",
}

m["tag"] = {
	"塔戈伊語",
	36537,
	"nic-ras",
	"Latn",
}

m["taj"] = {
	"東達芒語",
	12953177,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	-- sit-tam-Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	-- NOTE: Formerly there was no sort_key or translit specified; I assume that's a mistake.
}

m["tak"] = {
	"塔拉語",
	3914494,
	"cdc-wst",
	"Latn",
}

m["tal"] = {
	"塔爾語",
	3440387,
	"cdc-wst",
	"Latn",
}

m["tan"] = {
	"坦加勒語",
	529921,
	"cdc-wst",
	"Latn",
}

m["tao"] = {
	"達悟語",
	715760,
	"phi",
	"Latn",
}

m["tap"] = {
	"塔布瓦語",
	7673650,
	"bnt-sbi",
	"Latn",
}

m["tar"] = {
	"中塔拉烏馬拉語",
	20090009,
	"azc-trc",
	"Latn",
	sort_key = {remove_diacritics = c.acute .. "ꞌ"},
}

m["tas"] = {
	"Tây Bồi",
	2233794,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["tau"] = {
	"Upper Tanana",
	28281,
	"ath-nor",
	"Latn",
}

m["tav"] = {
	"塔圖約語",
	2524007,
	"sai-tuc",
	"Latn",
}

m["taw"] = {
	"Tai",
	7675861,
	"ngf-kak",
	"Latn",
}

m["tax"] = {
	"坦基語",
	3449082,
	"cdc-est",
	"Latn",
}

m["tay"] = {
	"泰雅語",
	715766,
	"map-ata",
	"Latn",
}

m["taz"] = {
	"托喬語",
	36680,
	"alv-tal",
	"Latn",
}

m["tba"] = {
	"艾嘎嫩語",
	3409307,
	"qfa-iso",
	"Latn",
}

-- Tapeba [tbb] is spurious

m["tbc"] = {
	"塔基亞語",
	3514336,
	"poz-oce",
	"Latn",
}

m["tbd"] = {
	"Kaki Ae",
	6349417,
	"qfa-iso", -- isolate in Glottolog and Pawley and Hammarström (2018); tentatively in Eleman family by Ross (2005)
			   -- (and Usher?), but they don't address counterarguments of Clifton 1997 
	"Latn",
}

m["tbe"] = {
	"Tanimbili",
	3515188,
	"poz-tem",
	"Latn",
}

m["tbf"] = {
	"Mandara",
	3285424,
	"poz-ocw",
	"Latn",
}

m["tbg"] = {
	"北泰羅拉語",
	20210398,
	"ngf-tai",
	"Latn",
}

m["tbh"] = {
	"Thurawal",
	3537135,
	"aus-yuk",
	"Latn",
}

m["tbi"] = {
	"加姆語",
	35338,
	"sdv-eje",
	"Latn",
}

m["tbj"] = {
	"蒂昂語",
	3528020,
	"poz-ocw",
	"Latn",
}

m["tbk"] = {
	"卡拉米-塔格巴努瓦語",
	3915487,
	"phi-kal",
	"Tagb, Latn",
}

m["tbl"] = {
	"特波里語",
	7690594,
	"phi",
	"Latn",
}

m["tbm"] = {
	"塔格布語",
	7675188,
	"nic-ser",
}

m["tbn"] = {
	"巴羅內格羅烏瓦語",
	12953943,
	"cba",
}

m["tbo"] = {
	"塔瓦拉語",
	7689206,
	"poz-ocw",
	"Latn",
}

m["tbp"] = {
	"Taworta",
	7689337,
	"paa-elp",
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
	"paa-ata",
	"Latn",
}

m["tbt"] = {
	"滕博語",
	13123561,
	"bnt-shh",
	"Latn",
}

m["tbu"] = {
	"圖巴爾語",
	56730,
	"azc-trc",
	"Latn",
}

m["tbv"] = {
	-- considered a dialect of Kulungtfu-Yuanggeng-Tobo [kgf] by Glottolog
	"Tobo",
	7811712,
	"ngf-kto",
	"Latn",
}

m["tbw"] = {
	"塔格巴努瓦語",
	3915475,
	"phi",
	"Latn",
}

m["tbx"] = {
	"卡平語",
	6366665,
	"poz-ocw",
	"Latn",
}

m["tby"] = {
	"塔巴魯語",
	11732670,
	"paa-gto",
	"Latn",
}

m["tbz"] = {
	"Ditammari",
	35186,
	"nic-eov",
	"Latn",
}

m["tca"] = {
	"齊古納語",
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
	"Tafi",
	36545,
	"alv-ktg",
}

m["tce"] = {
	"南塔穹語",
	31091048,
	"ath-nor",
	"Latn",
}

m["tcf"] = {
	"馬利納爾特佩克特拉帕克語",
	25559732,
	"omq",
	"Latn",
}

m["tcg"] = {
	"Tamagario",
	7680531,
	"paa-kay",
	"Latn",
}

m["tch"] = {
	"特克斯和凱科斯群島克里奧爾英語",
	7855478,
	"crp",
	"Latn",
	ancestors = "en",
}

m["tci"] = {
	"Wára",
	20825638,
	"paa-wko",
	"Latn",
}

m["tck"] = {
	"Tchitchege",
	36595,
	"bnt-tek",
}

m["tcl"] = {
	"答曼語 (緬甸)",
	15616518,
	"sit-jnp",
	"Latn",
}

m["tcm"] = {
	"Tanahmerah",
	3514927,
	"qfa-dis", -- Papuan; isolate per Glottolog and Palmer (2018), considered an independent branch of TNG by Usher
			   -- (2020); seems based only on some pronoun correspondences
	"Latn",
}

m["tco"] = {
	"Taungyo",
	12953186,
	"tbq-brm",
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
	"paa-clp",
	"Latn",
}

m["tcs"] = {
	"托雷斯海峽克里奧爾語",
	36648,
	"crp",
	"Latn",
	ancestors = "en",
}

m["tct"] = {
	"佯僙語",
	3442330,
	"qfa-kms",
}

m["tcu"] = {
	"東南塔拉烏馬拉語",
	36807,
	"azc-trc",
	"Latn",
}

m["tcw"] = {
	"特克帕特蘭托托納克語",
	7692795,
	"nai-ttn",
	"Latn",
}

m["tcx"] = {
	"托達語",
	34042,
	"dra-tkt",
	"Taml",
	--translit = {Taml = "Taml-translit"},
}

m["tcy"] = {
	"圖陸語",
	34251,
	"dra-tlk",
	"Tutg, Mlym, Knda", -- Mlym is nearer than Knda but both lack ɛ/ɛː.
	translit = {
		Tutg = "tcy-Tutg-translit",
	},
	-- Knda translit in [[Module:scripts/data]]
	-- Mlym translit in [[Module:scripts/data]]
}

m["tcz"] = {
	"Thado Chin",
	6583558,
	"tbq-kuk",
}

m["tda"] = {
	"Tagdal",
	36570,
	"son",
}

m["tdb"] = {
	"Panchpargania",
	21946879,
	"inc-sad",
	"Deva, as-Beng, Orya, Chis",
}

m["tdc"] = {
	"Emberá-Tadó",
	3052041,
	"sai-chc",
	"Latn",
}

m["tdd"] = {
	"傣納語",
	36556,
	"tai-swe",
	"Tale",
	translit = "Tale-translit",
	strip_diacritics = {remove_diacritics = c.ZWNJ .. c.ZWJ},
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
	"西達芒語",
	12953178,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	-- sit-tam-Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	-- NOTE: Formerly there was no sort_key or translit specified; I assume that's a mistake.
}

m["tdh"] = {
	"圖隆語",
	56553,
	"sit-kiw",
}

m["tdi"] = {
	"多馬迪諾語",
	7818197,
	"poz-btk",
	"Latn",
}

m["tdj"] = {
	"塔基歐語",
	7676870,
	"poz",
	"Latn",
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
	5559094,
}

m["tdn"] = {
	"通達諾語",
	3531514,
	"phi",
	"Latn",
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
	"祖查語",
	7812881,
	"mkh",
}

m["tds"] = {
	"多泰語",
	5302331,
	"paa-clp",
	"Latn",
}

m["tdt"] = {
	"帝力德頓語",
	12643484,
	"poz-tim",
	"Latn",
}

m["tdv"] = {
	"圖爾克瓦姆語",
	3438367,
	"nic-alu",
	"Latn",
}

m["tdy"] = {
	"塔迪亞萬語",
	7674700,
	"phi",
	"Latn",
}

m["tea"] = {
	"特米亞爾語",
	3914693,
	"mkh-asl",
	"Latn",
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
	"韋韋特拉特佩瓦語",
	56455,
	"nai-ttn",
	"Latn",
}

m["tef"] = {
	"Teressa",
	3518362,
	"aav-nic",
}

m["teg"] = {
	"北部特克語",
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
	"托里切利語",
	3450788,
	"paa-kom",
	"Latn",
}

m["tek"] = {
	"Ibali Teke",
	2802914,
	"bnt-tek",
}

m["tem"] = {
	"提姆語",
	36613,
	"alv-mel",
	"Latn",
}

m["ten"] = {
	"Tama (Colombia)",
	3832969,
	"sai-tuc",
	"Latn",
}

m["teo"] = {
	"特索語",
	29474,
	"sdv-ttu",
	"Latn",
}

m["tep"] = {
	"特佩卡諾語",
	3915525,
	"azc-pim",
	"Latn",
}

m["teq"] = {
	"Temein",
	7698064,
	"sdv",
}

m["ter"] = {
	"泰雷諾語",
	3314742,
	"awd",
	"Latn",
}

m["tes"] = {
	"騰格爾語",
	12473479,
	"poz",
	"Latn, Java",
}

m["tet"] = {
	"德頓語",
	34125,
	"poz-tim",
	"Latn",
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
	"Latn",
}

m["tew"] = {
	"特瓦語",
	56492,
	"nai-kta",
	"Latn",
}

m["tex"] = {
	"滕內語",
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
	"特特瑟雷特語",
	7706841,
	"ber",
	"Latn",
}

m["tfi"] = {
	"Tofin Gbe",
	3530330,
	"alv-pph",
}

m["tfn"] = {
	"代那安那語",
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
	"特里貝語",
	36533,
	"cba",
	"Latn",
}

m["tft"] = {
	"特爾納特語",
	3518492,
	"paa-tti",
	"Latn, Arab",
}

m["tga"] = {
	"Sagalla",
	12953082,
	"bnt-cht",
}

m["tgb"] = {
	"托比隆語",
	12953913,
	"poz-san",
	"Latn",
}

m["tgc"] = {
	"Tigak",
	3528276,
	"poz-ocw",
	"Latn",
}

m["tgd"] = {
	"Ciwogai",
	3438799,
	"cdc-wst",
	"Latn",
}

m["tge"] = {
	"東廓爾喀達芒語",
	12953175,
	"sit-tam",
	"sit-tam-Tibt, Deva",
	-- sit-tam-Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	-- NOTE: Formerly there was no sort_key or translit specified; I assume that's a mistake.
}

m["tgf"] = {
	"查利語",
	3695197,
	"sit-ebo",
	"Tibt, Latn",
	override_translit = true,
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["tgh"] = {
	"多巴哥克里奧爾英語",
	7811541,
	"crp",
	ancestors = "en",
}

m["tgi"] = {
	"拉溫亞語",
	3219937,
	"poz-ocw",
}

m["tgn"] = {
	"坦達加農語",
	63311769,
	"phi",
	"Latn",
}

m["tgo"] = {
	"塔古拉語",
	7675351,
	"poz-ocw",
}

m["tgp"] = {
	"Tangoa",
	2410276,
	"poz-vnn",
	"Latn",
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
	"poz-vnn",
	"Latn",
}

m["tgt"] = {
	"中塔格巴努瓦語",
	3915515,
	"phi",
	"Tagb",
}

m["tgu"] = {
	"Tanggu",
	7682930,
	"paa-ata",
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
	"塔吉什語",
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
	"傣包語",
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
	"奇特旺塔魯語",
	22083804,
	"inc-tha",
	"Deva",
}

m["thf"] = {
	"Thangmi",
	7710314,
	"sit-new",
	"Deva",
}

m["thh"] = {
	"北塔拉烏馬拉語",
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
	"薩拉卡語",
	15407179,
	"bnt-kka",
}

m["thl"] = {
	"Dangaura Tharu",
	22083815,
	"inc-tha",
	"Deva",
}

m["thm"] = {
	"他文語",
	34780,
	"mkh-vie",
	"Thai", --Laoo is feasible but no evidence yet.
	sort_key = "Thai-sortkey",
}

m["thn"] = {
	"Thachanadan",
	7708880,
	"dra-mal",
}

m["thp"] = {
	"湯普森語",
	1755054,
	"sal",
	"Latn, Dupl",
}

m["thq"] = {
	"珂奇拉塔魯語",
	22083826,
	"inc-tha",
}

m["thr"] = {
	"拉納塔魯語",
	12953920,
	"inc-tha",
	"Deva",
}

m["ths"] = {
	"塔卡利語",
	7709348,
	"sit-tam",
}

m["tht"] = {
	"塔爾坦語",
	30125,
	"ath-nor",
	"Latn",
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
	"ngf-mok",
	"Latn",
}

m["tig"] = {
	"提格雷語",
	34129,
	"sem-eth",
	"Ethi",
	translit = "Ethi-translit",
}

m["tih"] = {
	"蒂穆貢穆魯特語",
	7807680,
	"poz-san",
	"Latn",
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
	"Latn",
}

m["tim"] = {
	"Timbe",
	7804599,
	"ngf-kab",
	"Latn",
}

m["tin"] = {
	"廷迪語",
	36860,
	"cau-and",
	"Cyrl",
	display_text = s["cau-Cyrl-displaytext"],
	strip_diacritics = s["cau-Cyrl-stripdiacritics"],
}

m["tio"] = {
	"特奧普語",
	3518239,
	"poz-ocw",
	"Latn",
}

m["tip"] = {
	"特里穆里斯語",
	7842270,
	"paa-kwe",
	"Latn",
}

m["tiq"] = {
	"Tiéfo",
	3914874,
	"alv-sav",
}

m["tis"] = {
	"馬薩迪伊特伊特內格語",
	18748769,
	"phi",
}

m["tit"] = {
	"Tinigua",
	3029805,
	"sai-tin",
	"Latn",
}

m["tiu"] = {
	"阿達森語",
	11214797,
	"phi",
	"Latn",
}

m["tiv"] = {
	"泰雷諾語",
	34131,
	"nic-tvc",
	"Latn",
}

m["tiw"] = {
	"提維語",
	1656014,
	"qfa-iso",
	"Latn",
}

m["tix"] = {
	"Southern Tiwa",
	7570552,
	"nai-kta",
	"Latn",
}

m["tiy"] = {
	"蒂魯賴語",
	7809425,
	"phi",
	"Latn",
}

m["tiz"] = {
	"紅金傣語",
	3915716,
	"tai-swe",
}

m["tja"] = {
	"塔朱松語",
	3915326,
	"kro-wkr",
}

m["tjg"] = {
	"通瓊語",
	3542117,
	"poz",
	"Latn",
}

m["tji"] = {
	"北部土家語",
	12953229,
	"sit-tja",
	"Latn",
}

m["tjl"] = {
	"傣來語",
	7675773,
	"tai-swe",
	"Mymr",
}

m["tjm"] = {
	"Timucua",
	638300,
	"qfa-iso",
	"Latn",
}

m["tjn"] = {
	"Tonjon",
	3913372,
	"dmn-jje",
}

m["tjs"] = {
	"南部土家語",
	12633994,
	"sit-tja",
	"Latn",
}

m["tju"] = {
	"Tjurruru",
	3913834,
	"aus-nga",
	"Latn",
}

m["tjw"] = {
	"查普伍龍語",
	5285187,
	"aus-pam",
	"Latn",
}

m["tka"] = {
	"特魯卡語",
	7847648,
}

m["tkb"] = {
	"Buksa",
	20983638,
	"inc-eas",
	"Deva",
}

m["tkd"] = {
	"土庫德德語",
	36863,
	"poz-tim",
	"Latn",
}

m["tke"] = {
	"塔夸內語",
	11030092,
	"bnt-mak",
	"Latn",
	ancestors = "vmw",
}

m["tkf"] = {
	"Tukumanféd",
	42330115,
	"tup-gua",
	"Latn",
}

m["tkl"] = {
	"托克勞語",
	34097,
	"poz-pnp",
	"Latn",
}

m["tkm"] = {
	"Takelma",
	56710,
}

m["tkn"] = {
	"德之島語",
	3530484,
	"jpx-nry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	strip_diacritics = s["jpx-stripdiacritics"],
	sort_key = s["jpx-sortkey"],
}

m["tkp"] = {
	"蒂科皮亞語",
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
	"查庫爾語",
	36853,
	"cau-wsm",
	"Cyrl, Latn, Arab",
	translit = "tkr-translit",
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"]
	},
	strip_diacritics = {
		Cyrl = s["cau-Cyrl-stripdiacritics"],
		Latn = s["cau-Latn-stripdiacritics"],
	},
}

m["tks"] = {
	"Ramandi",
	25261947,
	"xme-ttc",
	"Arab",
	ancestors = "xme-ttc-sou",
}

m["tkt"] = {
	"卡塔里亞塔魯語",
	22083822,
	"inc-tha",
}

m["tku"] = {
	"上內卡克薩托托納克語",
	56343,
	"nai-ttn",
	"Latn",
}

m["tkv"] = {
	"穆爾帕諾語",
	16939373,
	"poz-ocw",
	"Latn",
}

m["tkw"] = {
	"泰努語",
	3516731,
	"poz-tem",
	"Latn",
}

m["tkx"] = {
	"唐科語",
	7682993,
	"ngf-tna",
	"Latn",
}

m["tkz"] = {
	"謝古語",
	7678544,
	"mkh",
}

m["tla"] = {
	"西南特佩瓦語",
	3518245,
	"azc-pim",
	"Latn",
}

m["tlb"] = {
	"托貝洛語",
	1142333,
	"paa-gto",
	"Latn",
}

m["tlc"] = {
	"耶庫阿特拉托托納克語",
	56460,
	"nai-ttn",
	"Latn",
}

m["tld"] = {
	"達勞德語",
	7678964,
	"phi",
	"Latn",
}

m["tlf"] = {
	"特萊福爾語",
	7696150,
	"ngf-mok",
	"Latn",
}

m["tlg"] = {
	"Tofanma",
	4461493,
	"paa-nto",
	"Latn",
}

m["tlh"] = {
	"克林貢語",
	10134,
	"art",
	"Latn",
	type = "appendix-constructed",
}

m["tli"] = {
	"特林吉特語",
	27792,
	"xnd",
	"Latn, Cyrl",
}

m["tlj"] = {
	"Talinga-Bwisi",
	7679530,
	"bnt-haj",
}

m["tlk"] = {
	"達祿基語",
	3514563,
	"poz-btk",
}

m["tll"] = {
	"特特拉語",
	2613465,
	"bnt-tet",
}

m["tlm"] = {
	"托洛馬科語",
	3130514,
	"poz-vnn",
	"Latn",
}

m["tln"] = {
	"大龍駱語'",
	7680293,
	"poz-ssw",
}

m["tlo"] = {
	"塔洛迪語",
	36525,
	"alv-tal",
}

m["tlp"] = {
	"菲洛梅納-馬塔-科阿維特蘭托托納克語",
	5449202,
	"nai-ttn",
	"Latn",
}

m["tlq"] = {
	"蒙雷語",
	7675784,
	"mkh-pal",
}

m["tlr"] = {
	"塔利塞語",
	3514510,
	"poz-sls",
	"Latn",
}

m["tls"] = {
	"塔姆博塔洛語",
	7681065,
	"poz-vnn",
	"Latn",
}

m["tlt"] = {
	"特盧蒂語",
	12953194,
	"poz-cma",
}

m["tlu"] = {
	"Tulehu",
	7852006,
	"poz-cma",
}

m["tlv"] = {
	"塔利亞布語",
	3514498,
	"poz-cma",
	"Latn",
}

m["tlx"] = {
	"克赫赫克語",
	3196124,
	"poz-aay",
}

m["tly"] = {
	"塔利什語",
	34318,
	"xme-ttc",
	"Latn, Cyrl, Arab",
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
	"Latn",
}

m["tmc"] = {
	"Tumak",
	3121045,
	"cdc-est",
}

m["tmd"] = {
	"Haruai",
	12632146,
	"paa-pia",
	"Latn",
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
	"圖阿雷格語",
	34065,
	"ber",
	"Latn, Tfng, Arab",
	strip_diacritics = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ},
	},
}

m["tmi"] = {
	"圖圖巴語",
	7857052,
	"poz-vnn",
	"Latn",
}

m["tmj"] = {
	"薩馬羅克納語",
	7408865,
	"paa-saa",
	"Latn",
}

m["tml"] = {
	"Tamnim Citak",
	12643315,
	"ngf-asm",
	"Latn",
}

m["tmm"] = {
	"傣奈語",
	7675842,
	"tai-swe",
}

m["tmn"] = {
	"答曼語 (印尼)",
	7680671,
	"poz",
	"Latn",
}

m["tmo"] = {
	"特莫克語",
	7698205,
	"mkh-asl",
}

m["tmq"] = {
	"通萊奧語",
	7852641,
	"poz-ocw",
}

m["tms"] = {
	"蒂馬語",
	36684,
	"nic-ktl",
}

m["tmt"] = {
	"塔斯馬特語",
	7687571,
	"poz-vnn",
	"Latn",
}

m["tmu"] = {
	"雅烏語",
	56867,
	"paa-lpl",
	"Latn",
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
	"塔馬納庫語",
	3441435,
	"sai-ven",
	"Latn",
}

m["tna"] = {
	"塔卡納語",
	3182551,
	"sai-tac",
	"Latn",
}

m["tnb"] = {
	"西烏瓦語",
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
	"安古斯圖拉烏瓦語",
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
	"ngf-kau",
	"Latn",
}

m["tni"] = {
	"坦迪阿語",
	7682454,
	"poz-hce",
	"Latn",
}

m["tnk"] = {
	"Kwamera",
	3200806,
	"poz-vns",
	"Latn",
}

m["tnl"] = {
	"Lenakel",
	3229429,
	"poz-vns",
	"Latn",
}

m["tnm"] = {
	"塔布拉語",
	7673105,
	"paa-sen",
	"Latn",
}

m["tnn"] = {
	"北坦納語",
	957945,
	"poz-vns",
	"Latn",
}

m["tno"] = {
	"Toromono",
	510544,
	"sai-tac",
	"Latn",
}

m["tnp"] = {
	"白沙語",
	3063761,
	"poz-vns",
	"Latn",
}

m["tnq"] = {
	"泰諾語",
	5232952,
	"awd-taa",
	"Latn",
}

m["tnr"] = {
	"Bedik",
	35096,
	"alv-ten",
	"Latn",
}

m["tns"] = {
	"特尼斯語",
	7699870,
	"poz-stm",
	"Latn",
}

m["tnt"] = {
	"通騰博安語",
	3531666,
	"phi",
	"Latn",
}

m["tnu"] = {
	"岱康語",
	6362363,
	"tai",
}

m["tnv"] = {
	"坦昌雅語",
	7682361,
	"inc-bas",
	"Cakm",
	ancestors = "inc-obn",
}

m["tnw"] = {
	"通沙旺語",
	3531660,
	"phi",
	"Latn",
}

m["tnx"] = {
	"塔內馬語",
	2106984,
	"poz-tem",
	"Latn",
}

m["tny"] = {
	"Tongwe",
	7821200,
	"bnt",
}

m["tnz"] = {
	"Ten'edn",
	3073453,
	"mkh-asl",
	"Latn",
}

m["tob"] = {
	"托巴語",
	3113756,
	"sai-guc",
	"Latn",
}

m["toc"] = {
	"科尤特拉托托納克語",
	15615591,
	"nai-ttn",
	"Latn",
}

m["tod"] = {
	"Toma",
	11055484,
	"dmn-msw",
	"Latn, Loma"
}

m["tof"] = {
	"Gizrra",
	5565941,
	"paa-etf",
	"Latn",
}

m["tog"] = {
	"通加語 (馬拉維)",
	3847648,
	"bnt-nys",
	"Latn",
}

m["toh"] = {
	"通加語 (莫桑比克)",
	7820988,
	"bnt-bso",
}

m["toi"] = {
	"通加語 (贊比亞)",
	34101,
	"bnt-bot",
	"Latn",
}

m["toj"] = {
	"托霍拉瓦爾語",
	36762,
	"myn",
	"Latn",
}

m["tok"] = {
	"道本語",
	36846,
	"art",
	"Latn",
	type = "appendix-constructed",
}

m["tol"] = {
	"Tolowa",
	20827,
	"ath-pco",
	"Latn",
}

m["tom"] = {
	"通布魯語",
	3531199,
	"phi",
	"Latn",
}

m["too"] = {
	"西科特佩克-德華雷斯托托納克語",
	8044353,
	"nai-ttn",
	"Latn",
}

m["top"] = {
	"帕潘特拉托托納克語",
	56329,
	"nai-ttn",
	"Latn",
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
	"高地托托納克語",
	13154149,
	"nai-ttn",
	"Latn",
}

m["tou"] = {
	"土語",
	22694631,
	"mkh-vie",
	"Latn",
}

m["tov"] = {
	"Upper Taromi",
	12953183,
	"xme-ttc",
	ancestors = "xme-ttc-cen",
}

m["tow"] = {
	"Jemez",
	3912876,
	"nai-kta",
	"Latn",
}

m["tox"] = {
	"托比語",
	34022,
	"poz-mic",
}

m["toy"] = {
	"多波伊尤語",
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
	"阿索尤梅帕語",
	25559730,
	"omq",
	"Latn",
}

m["tpe"] = {
	"Tippera",
	16115423,
	"tbq-bdg",
}

m["tpf"] = {
	"Tarpia",
	12953185,
	"poz-ocw",
	"Latn",
}

m["tpg"] = {
	"Kula",
	6442714,
	"paa-alp",
	"Latn",
}

m["tpi"] = {
	"托克皮辛語",
	34159,
	"crp",
	"Latn",
	ancestors = "en",
}

m["tpj"] = {
	"塔皮埃特語",
	3121063,
	"gn",
	"Latn",
}

m["tpk"] = {
	"都比尼欽語",
	33924,
	"tup-gua",
}

m["tpl"] = {
	"特拉科阿帕梅帕語",
	16115511,
	"omq",
}

m["tpm"] = {
	"Tampulma",
	36590,
	"nic-gnw",
}

m["tpn"] = {
	"圖皮南巴語",
	31528147,
	"tup-gua",
	"Latn",
}

m["tpo"] = {
	"行彤傣語",
	7675795,
	"tai-nor",
}

m["tpp"] = {
	"比薩佛洛勒斯特佩瓦語",
	56349,
	"nai-ttn",
}

m["tpq"] = {
	"獨巴語",
	12953230,
	"sit-las",
}

m["tpr"] = {
	"圖帕里語",
	3542217,
	"tup",
	"Latn",
}

m["tpt"] = {
	"特拉奇奇爾科特佩瓦語",
	56330,
	"nai-ttn",
}

m["tpu"] = {
	"坦普溫語",
	3514882,
	"mkh-ban",
	"Khmr",
}

m["tpv"] = {
	"塔納帕格語",
	3397371,
	"poz-mic",
}

m["tpw"] = {
	"古圖皮語",
	56944,
	"tup-gua",
	"Latn",
}

m["tpx"] = {
	"阿卡特佩克-梅帕語",
	31157882,
	"omq",
	"Latn",
}

m["tpy"] = {
	"特魯邁語",
	12294279,
	"qfa-iso",
}

m["tpz"] = {
	"Tinputz",
	3529205,
	"poz-ocw",
}

m["tqb"] = {
	"坦貝語",
	10322157,
	"tup-gua",
	"Latn",
}

m["tql"] = {
	"萊哈利語",
	3229119,
	"poz-vnn",
	"Latn",
}

m["tqm"] = {
	"Turumsa",
	7856508,
	"paa-dtu",
	"Latn",
}

m["tqn"] = {
	"特奈諾語",
	15699255,
	"nai-shp",
	"Latn",
	ancestors = "nai-spt",
}

m["tqo"] = {
	"托里皮語",
	7811403,
	"paa-eel",
	"Latn",
}

m["tqp"] = {
	"托莫伊普語",
	3531388,
	"poz-ocw",
}

m["tqq"] = {
	"突尼語",
	3514343,
	"cus-som",
}

m["tqr"] = {
	"托羅納語",
	36679,
	"alv-tal",
}

m["tqt"] = {
	"西托托納克語",
	7116691,
	"nai-ttn",
	"Latn",
}

m["tqu"] = {
	"Touo",
	56750,
}

m["tqw"] = {
	"通卡瓦語",
	2454881,
	"qfa-iso",
	"Latn",
}

m["tra"] = {
	"提拉希語",
	3812406,
	"inc-koh",
}

m["trb"] = {
	"泰雷布語",
	7701797,
	"poz-ocw",
}

m["trc"] = {
	"科帕拉特里基語",
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
	"東塔蘭甘語",
	18609750,
	"poz",
}

m["trf"] = {
	"特立尼達克里奧爾英語",
	7842493,
	"crp",
	"Latn",
	ancestors = "en",
}

m["trg"] = {
	"李山帝丹語",
	56473,
	"sem-nna",
	"Hebr",
}

m["trh"] = {
	"Turaka",
	12953237,
	"ngf-dag",
	"Latn",
}

m["tri"] = {
	"奇里幼語",
	56885,
	"sai-tar",
	"Latn",
}

m["trj"] = {
	"Toram",
	3441225,
	"cdc-est",
}

m["trl"] = {
	"旅行者蘇格蘭語",
	3915671,
	"qfa-mix",
	"Latn",
	ancestors = "rom, sco",
}

m["trm"] = {
	"特雷甘語",
	34081,
	"nur-sou",
}

m["trn"] = {
	"Trinitario",
	3539279,
	"awd",
}

m["tro"] = {
	"塔勞語",
	3515603,
	"tbq-kuk",
	"Latn",
}

m["trp"] = {
	"博羅克語",
	35947,
	"tbq-bdg",
	"Beng, Latn" -- WP lists 2 more
}

m["trq"] = {
	"聖馬丁伊通約索特里基語",
	12953934,
	"omq-tri",
	"Latn",
}

m["trr"] = {
	"陶希羅語",
	1957508,
	nil,
	"Latn",
}

m["trs"] = {
	"奇卡華特拉特里基語",
	3539587,
	"omq-tri",
	"Latn",
}

m["trt"] = {
	"Tunggare",
	615071,
	"paa-egb",
	"Latn",
}

m["tru"] = {
	"圖羅尤語",
	34040,
	"sem-cna",
	"Syrc, Latn",
	translit = {
		Syrc = "tru-translit",
	},
	strip_diacritics = {
		Syrc = "Syrc-stripdiacritics",
	},
}

m["trv"] = {
	"賽德克語",
	716686,
	"map-ata",
	"Latn",
}

m["trw"] = {
	"托瓦利語",
	2665246,
	"inc-koh",
	"Aran",
}

m["trx"] = {
	"Tringgus",
	7842365,
	"day",
}

m["try"] = {
	"土隆語",
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
	"瑟麥語",
	2371358,
	"cus-eas",
}

m["tsc"] = {
	"Tswa",
	2085051,
	"bnt-tsr",
}

m["tsd"] = {
	"特薩克尼恩語",
	220607,
	"grk",
	"Grek",
	ancestors = "grc-dor",
	translit = "el-translit",
	-- Grek display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}


m["tse"] = {
	"突尼西亞手語",
	7853191,
	"sgn",
}

m["tsg"] = {
	"陶蘇格語",
	34142,
	"phi",
	"Latn, Arab",
}

m["tsh"] = {
	"Tsuvan",
	3502326,
	"cdc-cbm",
	"Latn",
}

m["tsi"] = {
	"茨姆錫安語",
	20085721,
	"nai-tsi",
	"Latn",
}

m["tsj"] = {
	"倉洛語",
	36840,
	"sit-tsk",
	"Tibt, Latn, Deva",
	override_translit = true,
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["tsl"] = {
	"卜老語",
	3446675,
	"tai",
}

m["tsm"] = {
	"土耳其手語",
	36885,
	"sgn",
}

m["tsp"] = {
	"北圖斯亞語",
	11155635,
	"alv-sav",
}

m["tsq"] = {
	"泰國手語",
	7709156,
	"sgn-asl",
	"Sgnw",
}

m["tsr"] = {
	"Akei",
	2828964,
	"poz-vnn",
	"Latn",
}

m["tss"] = {
	"臺灣手語",
	34019,
	"sgn-jsl",
}

m["tsu"] = {
	"鄒語",
	716681,
	"map",
	"Latn",
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
	"穆巴米語",
	6930815,
	"paa-wig",
	"Latn",
}

m["tsy"] = {
	"Tebul Sign Language",
	7692090,
	"sgn",
}

m["tta"] = {
	"圖特盧語",
	2311602,
	"sio-ohv",
	"Latn",
}

m["ttb"] = {
	"加阿語",
	3438361,
	"nic-dak",
	"Latn",
}

m["ttc"] = {
	"特克提特克語",
	36686,
	"myn",
	"Latn",
}

m["ttd"] = {
	"Tauade",
	7688634,
	"qfa-dis", -- Papuan; isolate per Glottolog; Glottolog says "A Goilalan family uniting Kunimaipan, Tauade and Fuyug
			   -- is often posited based on the lexicostatistical figures reported in Tom E. Dutton 1975: 631-632" but
			   -- goes on to say the data "is clearly insufficient, as the lexical links so far proposed are few and
			   -- show irregular one-consonant correspondences".
	"Latn",
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
	"都東語",
	3507990,
	"poz-swa",
	"Latn",
}

m["tth"] = {
	"上達渥語",
	3512660,
	"mkh-kat",
}

m["tti"] = {
	"托巴蒂語",
	7811556,
	"poz-ocw",
	"Latn",
}

m["ttj"] = {
	"托羅語",
	7824218,
	"bnt-nyg",
	"Latn",
}

m["ttk"] = {
	"托托羅語",
	3532756,
	"sai-bar",
	"Latn",
}

m["ttl"] = {
	"托特拉語",
	10962316,
	"bnt-bot",
	"Latn",
}

m["ttm"] = {
	"北塔穹語",
	20822,
	"ath-nor",
	"Latn",
}

m["ttn"] = {
	"Towei",
	7829606,
	"paa-wpw",
	"Latn",
}

m["tto"] = {
	"下達渥語",
	25559539,
	"mkh-kat",
}

m["ttp"] = {
	"東貝拉拉語",
	6799663,
	"poz-kal",
}

m["ttr"] = {
	"特拉語",
	56267,
	"cdc-cbm",
}

m["tts"] = {
	"伊桑語",
	33417,
	"tai-swe",
	"Thai", -- also Tai Noi/Lao Buhan script
	sort_key = "Thai-sortkey",
}

m["ttt"] = {
	"塔特語",
	56489,
	"ira-swi",
	"Cyrl, Latn, Armn, Arab",
	-- Armn translit in [[Module:scripts/data]] (NOTE: formerly not present, probably an accidental omission)
	ancestors = "fa",
}

m["ttu"] = {
	"Torau",
	3532208,
	"poz-ocw",
}

m["ttv"] = {
	"馬努斯語",
	3445811,
	"poz-aay",
	"Latn",
}

m["ttw"] = {
	"隆-瓦特語",
	7856961,
	"poz-swa",
}

m["tty"] = {
	"西卡里泰語",
	7513600,
	"paa-clp",
	"Latn",
}

m["ttz"] = {
	"Tsum",
	12953223,
	"sit-kyk",
}

m["tua"] = {
	"威阿如姆斯語",
	7998045,
	"paa-mmu",
	"Latn",
}

m["tub"] = {
	"特巴特勒巴爾語",
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
	"都夏語",
	7857217,
}

m["tue"] = {
	"都尤咖語",
	2520538,
	"sai-tuc",
	"Latn",
}

m["tuf"] = {
	"中烏瓦語",
	12953942,
	"cba",
	"Latn",
}

m["tug"] = {
	"Tunia",
	863721,
	"alv-bua",
}

m["tuh"] = {
	"Taulil",
	3516141,
}

m["tui"] = {
	"圖普里語",
	36646,
	"alv-mbm",
	"Latn",
}

m["tuj"] = {
	"圖古蒂爾語",
	12953228,
	"paa-gto",
	"Latn",
}

m["tul"] = {
	"圖拉語",
	3914907,
	"alv-wjk",
}

m["tum"] = {
	"通布卡語",
	34138,
	"bnt-nys",
	"Latn",
}

m["tun"] = {
	"圖尼卡語",
	56619,
	"qfa-iso",
	"Latn",
}

m["tuo"] = {
	"都卡諾語",
	3541834,
	"sai-tuc",
	"Latn",
}

m["tuq"] = {
	"特達加語",
	36639,
	"ssa-sah",
	"Latn",
}

m["tus"] = {
	"圖斯卡羅拉語",
	36944,
	"iro-nor",
	"Latn",
}

m["tuu"] = {
	"圖圖特尼語",
	20627,
	"ath-pco",
	"Latn",
}

m["tuv"] = {
	"圖爾卡納語",
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
	"圖根語",
	3541935,
	"sdv-nma",
}

m["tuz"] = {
	"圖爾卡語",
	36643,
	"nic-gur",
	"Latn",
}

m["tva"] = {
	"瓦瓜語",
	3553248,
	"poz-ocw",
	"Latn",
}

m["tvd"] = {
	"楚瓦迪語",
	3914936,
	"nic-kam",
}

m["tve"] = {
	"特翁語",
	7690709,
	"poz-cet",
	"Latn",
}

m["tvk"] = {
	"東南安布里姆語",
	252411,
	"poz-vnc",
	"Latn",
}

m["tvl"] = {
	"圖瓦盧語",
	34055,
	"poz-pnp",
	"Latn",
}

m["tvm"] = {
	"Tela-Masbuar",
	7695666,
	"poz-tim",
}

m["tvn"] = {
	"土瓦語",
	7689158,
	"tbq-brm",
	"Mymr",
	ancestors = "obr",
}

m["tvo"] = {
	"蒂多雷語",
	3528199,
	"paa-tti",
	"Latn, Arab",
}

m["tvs"] = {
	"塔韋塔語",
	15632387,
	"bnt-par",
	"Latn",
}

m["tvt"] = {
	"Tutsa Naga",
	7856987,
	"sit-tno",
}

m["tvu"] = {
	"圖嫩語",
	36632,
	"nic-mbw",
}

m["tvw"] = {
	"塞多阿語",
	7445362,
	"poz-kal",
}

m["tvx"] = {
	"大武壠語",
	1975271,
	"map",
	"Latn",
}

m["tvy"] = {
	"帝汶皮欽語",
	4904029,
	"crp",
	ancestors = "pt",
}

m["twa"] = {
	"特瓦納語",
	7857412,
	"sal",
	"Latn",
}

m["twb"] = {
	"西塔烏碧語",
	12953912,
	"phi",
}

m["twc"] = {
	"Teshenawa",
	3436597,
	"cdc-wst",
	"Latn",
}

m["twe"] = {
	"泰瓦語",
	3519302,
	"paa-alp",
	"Latn",
}

m["twf"] = {
	"陶斯語",
	7684320,
	"nai-kta",
	"Latn",
}

m["twg"] = {
	"特雷文語",
	12953200,
	"paa-alp",
	"Latn",
}

m["twh"] = {
	"傣端語",
	7675751,
	"tai-swe",
	"Tavt",
	--translit = "Tavt-translit",
	sort_key = {
		from = {"[꪿ꫀ꫁ꫂ]", "([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])"},
		to = {"", "%2%1"}
	},
}

m["twm"] = {
	"達旺門巴語",
	36586,
	"sit-ebo",
	"Tibt",
	override_translit = true,
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
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
	"艾雷語",
	3056045,
	"poz-aay",
	"Latn",
}

m["twq"] = {
	"北桑海語",
	36564,
	"son",
}

m["twr"] = {
	"西南塔拉烏馬拉語",
	12953909,
	"azc-trc",
	"Latn",
}

m["twt"] = {
	"都里瓦拉語",
	3542307,
	"tup-gua",
	"Latn",
}

m["twu"] = {
	"特爾馬努語",
	7702572,
	"poz-tim",
	"Latn",
}

m["tww"] = {
	"圖瓦里語",
	7857159,
	"paa-wal",
	"Latn",
}

m["twy"] = {
	"塔沃延語",
	3513542,
	"poz-bre",
	"Latn",
}

m["txa"] = {
	"通博諾語",
	7818692,
	"poz-san",
	"Latn",
}

m["txb"] = {
	"吐火羅語B",
	3199353,
	"ine-toc",
	"Latn",
	standard_chars = "AaÄäĀāCcEeIiKkLlMmṂṃNnṄṅÑñOoPpRrSsŚśṢṣTtUuWwYy" .. c.punc,
}

m["txc"] = {
	"Tsetsaut",
	20829,
	"ath-nor",
	"Latn",
}

m["txe"] = {
	"多多利語",
	7828387,
	"poz-tot",
	"Latn",
}

m["txg"] = {
	"西夏語",
	2727930,
	"ero",
	"Tang",
	-- Tang translit in [[Module:scripts/data]]
}

m["txh"] = {
	"色雷斯語",
	36793,
	"ine",
	"Latn, Polyt",
	-- Polyt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["txi"] = {
	"伊崩語",
	9344891,
	"sai-pek",
	"Latn",
}

m["txj"] = {
	"Tarjumo",
	24906088,
	"ssa-sah",
	"Latn, Arab",
}

m["txm"] = {
	"托米尼語",
	7818911,
	"poz",
	"Latn",
}

m["txn"] = {
	"西塔蘭甘語",
	3515594,
	"poz",
	"Latn",
}

m["txo"] = {
	"投投語",
	36709,
	"sit-dhi",
	"Beng, Toto"
}

m["txq"] = {
	"蒂伊語",
	7801784,
	"poz-tim",
}

m["txr"] = {
	"Tartessian",
	36795,
	"qfa-unc", -- extinct, no consensus on classification
}

m["txs"] = {
	"通西亞語",
	3531659,
	"phi",
	"Latn",
}

m["txt"] = {
	"Citak",
	3447279,
	"ngf-asm",
	"Latn",
}

m["txu"] = {
	"卡亞波語",
	3101212,
	"sai-nje",
	"Latn",
}

m["txx"] = {
	"Tatana",
	18643518,
	"poz-san",
	"Latn",
}

m["tya"] = {
	"陶亞語",
	7688978,
	"ngf-rai",
	"Latn",
}

m["tye"] = {
	"Kyenga",
	3913304,
	"dmn-bbu",
	"Latn",
}

m["tyh"] = {
	"O'du",
	3347428,
	"mkh",
}

m["tyi"] = {
	"Teke-Tsaayi",
	33123613,
	"bnt-nze",
}

m["tyj"] = {
	"傣約語",
	7675746,
	"tai-nor", -- Chamberlain (1991), but Pittayaporn (2009) suggests tai-swe
	"Latn, Tayo", -- Vietnam
}

m["tyl"] = {
	"土僚語",
	12953921,
	"tai-cen",
}

m["tyn"] = {
	"Kombai",
	6428241,
	"ngf-nde",
	"Latn",
}

m["typ"] = {
	"Kuku-Thaypan",
	3915693,
	"aus-pmn",
	"Latn",
}

m["tyr"] = {
	"傣亮語",
	3915207,
	"tai-swe",
	"Tavt",
}

m["tys"] = {
	"沙爬語",
	3446668,
	"tai-sap",
	"Latn",
}

m["tyt"] = {
	"德地傣語",
	7862029,
	"tai-swe",
}

m["tyu"] = {
	"Kua",
	3832933,
	"khi-kal",
	"Latn",
}

m["tyv"] = {
	"圖瓦語",
	34119,
	"trk-ssb",
	"Cyrl",
	translit = "tyv-translit",
	override_translit = true,
	sort_key = "tyv-sortkey",
}

m["tyx"] = {
	"泰凱-蒂耶語",
	36634,
	"bnt-nze",
	"Latn",
}

m["tyz"] = {
	"岱依語", -- This does not mean its family "Tai" languages.
	2511476,
	"tai-tay",
	"Latn, Hani",
	sort_key = {
		Hani = "Hani-sortkey"
	},
}

m["tza"] = {
	"坦桑尼亞手語",
	7684177,
	"sgn",
}

m["tzh"] = {
	"策爾塔爾語",
	36808,
	"myn",
	"Latn",
}

m["tzj"] = {
	"楚圖希爾語",
	36941,
	"myn",
	"Latn",
}

m["tzl"] = {
	"塔羅薩語",
	1063911,
	"art",
	"Latn",
	type = "appendix-constructed",
	sort_key = "tzl-sortkey",
}

m["tzm"] = {
	"中阿特拉斯柏柏爾語",
	49741,
	"ber",
	"Tfng, Arab, Latn",
	translit = {
		Tfng = "Tfng-translit",
	},
}

m["tzn"] = {
	"Tugun",
	12953225,
	"poz-tim",
	"Latn",
}

m["tzo"] = {
	"佐齊爾語",
	36809,
	"myn",
	"Latn",
}

m["tzx"] = {
	"塔布里亞克語",
	56872,
	"paa-lse",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")