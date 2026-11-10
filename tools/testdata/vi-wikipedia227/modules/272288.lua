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

m["haa"] = {
	"Hän",
	28272,
	"ath-nor",
	"Latn",
}

m["hab"] = {
	"Hanoi Sign Language",
	12632107,
	"sgn",
	"Latn", -- when documented
}

m["hac"] = {
	"tiếng Goran",
	33733,
	"ira-zgr",
	"ku-Arab",
	"Tiếng Goran",
	"Goran",
	translit = "ckb-translit",
}

m["had"] = {
	"tiếng Hatam",
	56825,
	"qfa-iso",
	"Latn",
}

m["hae"] = {
	"tiếng Oromo Đông",
	5330355,
	"cus-eas",
	"Latn",
	"Tiếng Oromo Đông",
	"Oromo Đông"
}

m["haf"] = {
	"Haiphong Sign Language",
	39868240,
	"sgn",
}

m["hag"] = {
	"Hanga",
	35426,
	"nic-dag",
	"Latn",
}

m["hah"] = {
	"Hahon",
	3125730,
	"poz-ocw",
	"Latn",
}

m["hai"] = {
	"tiếng Haida",
	33303,
	"qfa-iso",
	"Latn",
	"Tiếng Haida",
	"Haida",
}

m["haj"] = {
	"tiếng Hajong",
	3350576,
	"qfa-mix",
	"as-Beng, Latn",
	"Tiếng Hajong",
	"Hajong",
	ancestors = "inc-oas, tbq-pro",
}

m["hak"] = {
	"tiếng Khách Gia",
	33375,
	"zhx",
	"Hants",
	"Tiếng Khách Gia",
	"Khách Gia",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["hal"] = {
	"tiếng Hà Lăng",
	56307,
	"mkh-nbn",
	"Latn",
	"Tiếng Hà Lăng",
	"Hà Lăng",
}

m["ham"] = {
	"Hewa",
	5748345,
	"paa-spk",
}

m["hao"] = {
	"Hakö",
	3125871,
	"poz-ocw",
	"Latn",
}

m["hap"] = {
	"Hupla",
	5946223,
	"ngf",
}

m["har"] = {
	"tiếng Harari",
	33626,
	"sem-eth",
	"Ethi, Arab",
	"Tiếng Harari",
	"Harari",
	translit = {Ethi = "Ethi-translit"},
}

m["has"] = {
	"tiếng Haisla",
	3107399,
	"wak",
	"Latn",
	"Tiếng Haisla",
	"Haisla",
}

m["hav"] = {
	"Havu",
	5684097,
	"bnt-shh",
	"Latn",
}

m["haw"] = {
	"tiếng Hawaii",
	33569,
	"poz-pep",
	"Latn",
	"Tiếng Hawaii",
	"Hawaii",
	display_text = {
		from = {"‘"},
		to = {"ʻ"}
	},
	sort_key = {remove_diacritics = c.macron},
	standardChars = "AaĀāEeĒēIiĪīOoŌōUuŪūHhKkLlMmNnPpWwʻ" .. c.punc,
}

m["hax"] = {
	"Southern Haida",
	12953543,
	"qfa-iso",
	ancestors = "hai",
}

m["hay"] = {
	"Haya",
	35756,
	"bnt-haj",
}

m["haz"] = {
	"tiếng Hazara",
	33398,
	"ira-swi",
	"Arab",
	"Tiếng Hazara",
	"Hazara",
}

m["hba"] = {
	"Hamba",
	11028905,
	"bnt-tet",
}

m["hbb"] = {
	"Huba",
	56290,
	"cdc-cbm",
}

m["hbn"] = {
	"tiếng Heiban",
	35523,
	"alv-hei",
	"Latn",
	"Tiếng Heiban",
	"Heiban",
}

m["hbu"] = {
	"Habu",
	1567033,
	"poz-cet",
	"Latn",
}

m["hca"] = {
	"Andaman Creole Hindi",
	7599417,
	"crp",
	ancestors = "hi, bn, ta",
}

m["hch"] = {
	"Huichol",
	35575,
	"azc",
	"Latn",
}

m["hdn"] = {
	"Northern Haida",
	20054484,
	"qfa-iso",
	ancestors = "hai",
}

m["hds"] = {
	"Honduras Sign Language",
	3915496,
	"sgn",
	"Latn", -- when documented
}

m["hdy"] = {
	"tiếng Hadiyya",
	56613,
	"cus-hec",
	"Latn, Ethi",
	"Tiếng Hadiyya",
	"Hadiyya",
}

m["hea"] = {
	"Northern Qiandong Miao",
	3138832,
	"hmn",
}

m["hed"] = {
	"Herdé",
	56253,
	"cdc-mas",
}

m["heg"] = {
	"Helong",
	35432,
	"poz-tim",
	"Latn",
}

m["heh"] = {
	"Hehe",
	3129390,
	"bnt-bki",
	"Latn",
}

m["hei"] = {
	"tiếng Heiltsuk",
	5699507,
	"wak",
	"Latn",
	"Tiếng Heiltsuk",
	"Heiltsuk",
}

m["hem"] = {
	"Hemba",
	5711209,
	"bnt-lbn",
}

m["hgm"] = {
	"Haiǁom",
	4494781,
	"khi-khk",
	"Latn",
}

m["hgw"] = {
	"Haigwai",
	5639108,
	"poz-ocw",
	"Latn",
}

m["hhi"] = {
	"Hoia Hoia",
	5877767,
	"ngf",
}

m["hhr"] = {
	"Kerak",
	11010783,
	"alv-jfe",
}

m["hhy"] = {
	"Hoyahoya",
	nil,
	"ngf",
}

m["hia"] = {
	"Lamang",
	35700,
	"cdc-cbm",
	"Latn",
}

m["hib"] = {
	"Hibito",
	3135164,
}

m["hid"] = {
	"Hidatsa",
	3135234,
	"sio-mor",
	"Latn",
}

m["hif"] = {
	"tiếng Hindi Fiji",
	46728,
	"inc-hie",
	"Latn",
	"Tiếng Hindi Fiji",
	"Hindi Fiji",
	ancestors = "awa",
}

m["hig"] = {
	"Kamwe",
	56271,
	"cdc-cbm",
}

m["hih"] = {
	"Pamosu",
	12953011,
	"ngf-mad",
}

m["hii"] = {
	"tiếng Hinduri",
	5766763,
	"him",
	"Deva, Takr",
	"Tiếng Hinduri",
	"Hinduri",
}

m["hij"] = {
	"Hijuk",
	35274,
	"bnt-bsa",
}

m["hik"] = {
	"Seit-Kaitetu",
	7446989,
	"poz-cma",
}

m["hil"] = {
	"tiếng Hiligaynon",
	35978,
	"phi",
	"Latn",
	"Tiếng Hiligaynon",
	"Hiligaynon",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}},
	standardChars = {
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
	sort_key = {
		Latn = "tl-sortkey"
	},
}

m["hio"] = {
	"Tshwa",
	963636,
	"khi-kal",
}

m["hir"] = {
	"Himarimã",
	5765127,
}

m["hit"] = {
	"tiếng Hitti",
	35668,
	"ine-ana",
	"Xsux",
	"Tiếng Hitti",
	"Hitti",
}

m["hiw"] = {
	"tiếng Hiw",
	3138713,
	"poz-vnc",
	"Latn",
	"Tiếng Hiw",
	"Hiw",
}

m["hix"] = {
	"Hixkaryana",
	56522,
	"sai-prk",
	"Latn",
}

m["hji"] = {
	"Haji",
	5639933,
	"poz-mly",
}

m["hka"] = {
	"Kahe",
	3892562,
	"bnt-chg",
	"Latn",
}

m["hke"] = {
	"Hunde",
	3065432,
	"bnt-shh",
	"Latn",
}

m["hkh"] = {
	"Pogali",
	105198619,
	"inc-kas",
}

m["hkk"] = {
	"Hunjara-Kaina Ke",
	nil,
	"ngf",
}

m["hkn"] = {
	"Mel-Khaonh",
	nil,
	"mkh-ban",
}

m["hks"] = {
	"Hong Kong Sign Language",
	17038844,
	"sgn",
}

m["hla"] = {
	"Halia",
	3125959,
	"poz-ocw",
	"Latn",
}

m["hlb"] = {
	"tiếng Halba",
	3695692,
	"inc-eas",
	"Deva, Orya",
	"Tiếng Halba",
	"Halba",
	translit = "hi-translit",
}

m["hld"] = {
	"Halang Doan",
	3914632,
	"mkh-ban",
}

m["hle"] = {
	"Hlersu",
	5873537,
	"tbq-llo",
}

m["hlt"] = {
	"Nga La",
	12952942,
	"tbq-kuk",
}

m["hma"] = {
	"Southern Mashan Hmong",
	12953560,
	"hmn",
	"Latn",
}

m["hmb"] = {
	"tiếng Senni Humburi",
	35486,
	"son",
	"Latn, Arab",
	"Tiếng Senni Humburi",
	"Senni Humburi",
	
}

m["hmc"] = {
	"Central Huishui Hmong",
	12953558,
	"hmn",
}

m["hmd"] = {
	"tiếng A-Hmao",
	1108934,
	"hmn",
	"Latn, Plrd",
	"Tiếng A-Hmao",
	"A-Hmao",
}

m["hme"] = {
	"Eastern Huishui Hmong",
	12953559,
	"hmn",
}

m["hmf"] = {
	"tiếng Mông",
	22911602,
	"hmn",
	nil,
	"Tiếng Mông",
	"Mông",
}

m["hmg"] = {
	"Southwestern Guiyang Hmong",
	27478542,
	"hmn",
}

m["hmh"] = {
	"Southwestern Huishui Hmong",
	12953565,
	"hmn",
}

m["hmi"] = {
	"Northern Huishui Hmong",
	27434946,
	"hmn",
}

m["hmj"] = {
	"Ge",
	11251864,
	"hmn",
}

m["hmk"] = {
	"Maek",
	8050724,
	"qfa-kor",
}

m["hml"] = {
	"Luopohe Hmong",
	14468943,
	"hmn",
}

m["hmm"] = {
	"Central Mashan Hmong",
	12953561,
	"hmn",
}

m["hmp"] = {
	"Northern Mashan Hmong",
	12953564,
	"hmn",
}

m["hmq"] = {
	"Eastern Qiandong Miao",
	27431369,
	"hmn",
}

m["hmr"] = {
	"Hmar",
	2992841,
	"tbq-kuk",
	ancestors = "lus",
}

m["hms"] = {
	"Southern Qiandong Miao",
	12953562,
	"hmn",
}

m["hmt"] = {
	"Hamtai",
	5646436,
	"ngf",
}

m["hmu"] = {
	"Hamap",
	12952484,
	"qfa-tap",
}

m["hmv"] = {
	"Hmong Dô",
	22911598,
	"hmn",
}

m["hmw"] = {
	"Western Mashan Hmong",
	12953563,
	"hmn",
}

m["hmy"] = {
	"Southern Guiyang Hmong",
	12953553,
	"hmn",
}

m["hmz"] = {
	"Hmong Shua",
	25559603,
	"hmn",
}

m["hna"] = {
	"Mina",
	56532,
	"cdc-cbm",
}

m["hnd"] = {
	"Southern Hindko",
	382273,
	"inc-pan",
	ancestors = "lah",
}

m["hne"] = {
	"tiếng Chhattisgarh",
	33158,
	"inc-hie",
	"Deva, Orya",
	"Tiếng Chhattisgarh",
	"Chhattisgarh",
	translit = {Deva = "hi-translit"}
}

m["hnh"] = {
	"ǁAni",
	3832982,
	"khi-kal",
	"Latn",
}

m["hni"] = {
	"tiếng Hà Nhì",
	56516,
	"tbq-han",
	"Latn",
	"Tiếng Hà Nhì",
	"Hà Nhì",
}

m["hnj"] = {
	"Green Hmong",
	3138831,
	"hmn",
	"Latn, Hmng, Hmnp",
}

m["hnn"] = {
	"tiếng Hanunoo",
	35435,
	"phi",
	"Hano, Latn",
	"Tiếng Hanunoo",
	"Hanunoo",
}

m["hno"] = {
	"tiếng Hindko Bắc",
	6346358,
	"inc-pan",
	"Arab",
	"Tiếng Hindko Bắc",
	"Hindko Bắc",
	ancestors = "lah",
}

m["hns"] = {
	"tiếng Hindustan Caribe",
	1843468,
	"inc", -- "crp"?
	nil,
	"Tiếng Hindustan Caribe",
	"Hindustan Caribe",
	ancestors = "bho, awa",
}

m["hnu"] = {
	"tiếng Pọng",
	12632753,
	"mkh-vie",
	nil,
	"Tiếng Pọng",
	"Pọng",
}

m["hoa"] = {
	"tiếng Hoava",
	3138887,
	"poz-ocw",
	"Latn",
	"Tiếng Hoava",
	"Hoava"
}

m["hob"] = {
	"Austronesian Mari",
	6760941,
	"poz-ocw",
	"Latn",
}

m["hoc"] = {
	"tiếng Ho",
	33270,
	"mun",
	"Wara, Orya, Deva, Latn, Beng",
	"Tiếng Ho",
	"Ho",
}

m["hod"] = {
	"Holma",
	56331,
	"cdc-cbm",
	"Latn",
}

m["hoe"] = {
	"Horom",
	3914008,
	"nic-ple",
	"Latn",
}

m["hoh"] = {
	"Hobyót",
	33299,
	"sem-sar",
	"Arab, Latn",
}

m["hoi"] = {
	"Holikachuk",
	28508,
	"ath-nor",
	"Latn",
}

m["hoj"] = {
	"Hadothi",
	33227,
	"inc-wes",
	ancestors = "mwr",
}

m["hol"] = {
	"Holu",
	4121133,
	"bnt-pen",
	"Latn",
}

m["hom"] = {
	"Homa",
	3449953,
	"bnt-boa",
	"Latn",
}

m["hoo"] = {
	"Holoholo",
	3139484,
	"bnt-tkm",
	"Latn",
}

m["hop"] = {
	"tiếng Hopi",
	56421,
	"azc",
	"Latn",
	"Tiếng Hopi",
	"Hopi",
}

m["hor"] = {
	"Horo",
	641748,
	"csu-sar",
}

m["hos"] = {
	"Ho Chi Minh City Sign Language",
	16111971,
	"sgn",
	"Latn", -- when documented
}

m["hot"] = {
	"Hote",
	12632404,
	"poz-ocw",
	"Latn",
}

m["hov"] = {
	"Hovongan",
	5917269,
	"poz",
}

m["how"] = {
	"Honi",
	56842,
	"tbq-han",
}

m["hoy"] = {
	"tiếng Holiya",
	5880707,
	"dra-kan",
	"Deva, Knda",
	"Tiếng Holiya",
	"Holiya",
	translit = { Knda = "kn-translit", }
}

m["hoz"] = {
	"tiếng Hozo",
	5923010,
	"omv-mao",
	nil,
	"Tiếng Hozo",
	"Hozo",
}

m["hpo"] = {
	"tiếng Hpon",
	5923277,
	"tbq-brm",
	nil,
	"Tiếng Hpon",
	"Hpon",
}

m["hps"] = {
	"Hawai'i Pidgin Sign Language",
	33358,
	"sgn",
	"Latn", -- when documented
}

m["hra"] = {
	"Hrangkhol",
	5923435,
	"tbq-kuk",
}

m["hrc"] = {
	"Niwer Mil",
	nil,
	"poz-oce",
	"Latn",
}

m["hre"] = {
	"tiếng Hrê",
	3915794,
	"mkh-nbn",
	"Latn",
	"Tiếng Hrê",
	"Hrê",
}

m["hrk"] = {
	"Haruku",
	5675762,
	"poz-cma",
}

m["hrm"] = {
	"Horned Miao",
	nil,
	"hmn",
}

m["hro"] = {
	"tiếng H'roi",
	3127568,
	"cmc",
	"Latn",
	"Tiếng H'roi",
	"H'roi",
}

m["hrp"] = {
	"Nhirrpi",
	32571318,
	"aus-kar",
}

m["hrt"] = {
	"Hértevin",
	33290,
	"sem-nna",
	"Latn",
}

m["hru"] = {
	"Hruso",
	5923933,
	"sit-hrs",
}

m["hrw"] = {
	"Warwar Feni",
	nil,
	"poz-oce",
	"Latn",
}

m["hrx"] = {
	"tiếng Hunsrik",
	304049,
	"gmw-hgm",
	"Latn",
	"Tiếng Hunsrik",
	"Hunsrik",
	ancestors = "gmw-cfr",
}

m["hrz"] = {
	"Harzani",
	56464,
	"xme-ttc",
	ancestors = "xme-ttc-nor",
}

m["hsb"] = {
	"tiếng Thượng Sorb",
	13248,
	"wen",
	"Latn",
	"Tiếng Thượng Sorb",
	"Thượng Sorb",
	sort_key = s["wen-sortkey"],
}

m["hsh"] = {
	"Hungarian Sign Language",
	13636869,
	"sgn",
	"Latn", -- when documented
}

m["hsl"] = {
	"Hausa Sign Language",
	3915462,
	"sgn",
	"Latn", -- when documented
}

m["hsn"] = {
	"tiếng Tương",
	13220,
	"zhx",
	"Hants",
	"Tiếng Tương",
	"Tương",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["hss"] = {
	"tiếng Harsusi",
	33423,
	"sem-sar",
	"Arab, Latn",
	"Tiếng Harsusi",
	"Harsusi",
}

m["hti"] = {
	"Hoti",
	5912372,
	"poz-cma",
	"Latn",
}

m["hto"] = {
	"Minica Huitoto",
	948514,
	"sai-wit",
	"Latn",
}

m["hts"] = {
	"Hadza",
	33411,
	"qfa-iso",
	"Latn",
}

m["htu"] = {
	"Hitu",
	5872700,
	"poz-cma",
	"Latn",
}

m["hub"] = {
	"Huambisa",
	1526037,
	"sai-jiv",
	"Latn",
}

m["huc"] = {
	"ǂHoan",
	2053913,
	"khi-kxa",
	"Latn",
}

m["hud"] = {
	"Huaulu",
	12952504,
	"poz-cma",
	"Latn",
}

m["huf"] = {
	"Humene",
	11732231,
	"ngf",
	"Latn",
}

m["hug"] = {
	"Huachipaeri",
	3446617,
	"sai-har",
	"Latn",
}

m["huh"] = {
	"Huilliche",
	35531,
	"sai-ara",
	"Latn",
}

m["hui"] = {
	"tiếng Huli",
	3125121,
	"ngf-khu",
	"Latn",
}

m["huj"] = {
	"Northern Guiyang Hmong",
	12953554,
	"hmn",
}

m["huk"] = {
	"Hulung",
	12952505,
	"poz-cet",
}

m["hul"] = {
	"Hula",
	6382179,
	"poz-ocw",
	"Latn",
}

m["hum"] = {
	"Hungana",
	10975396,
	"bnt-yak",
}

m["huo"] = {
	"tiếng Hu",
	3141783,
	"mkh-pal",
	nil,
	"Tiếng Hu",
	"Hu"
}

m["hup"] = {
	"tiếng Hupa",
	28058,
	"ath-pco",
	"Latn",
	"Tiếng Hupa",
	"Hupa",
}

m["huq"] = {
	"tiếng Tsat",
	34133,
	"cmc",
	nil,
	"Tiếng Tsat",
	"Tsat",
}

m["hur"] = {
	"tiếng Halkomelem",
	35388,
	"sal",
	"Latn",
	"Tiếng Halkomelem",
	"Halkomelem",
}

m["hus"] = {
	"tiếng Wastek",
	35573,
	"myn",
	"Latn",
	"Tiếng Wastek",
	"Wastek",
}

m["huu"] = {
	"Murui Huitoto",
	2640935,
	"sai-wit",
	"Latn",
}

m["huv"] = {
	"Huave",
	12954031,
	"qfa-iso",
	"Latn",
}

m["huw"] = {
	"Hukumina",
	3142988,
	"poz-cma",
	"Latn",
}

m["hux"] = {
	"Nüpode Huitoto",
	56333,
	"sai-wit",
	"Latn",
}

m["huy"] = {
	"tiếng Hulaulá",
	33426,
	"sem-nna",
	"Hebr",
	"Tiếng Hulaulá",
	"Hulaulá",
}

m["huz"] = {
	"tiếng Hunzib",
	56564,
	"cau-ets",
	"Cyrl",
	"Tiếng Hunzib",
	"Hunzib",
	translit = "huz-translit",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["hvc"] = {
	"Haitian Vodoun Culture Language",
	3504239,
	"crp",
	"Latn",
}

m["hvk"] = {
	"Haveke",
	5683513,
	"poz-cln",
	"Latn",
}

m["hvn"] = {
	"Sabu",
	3128792,
	"poz-cet",
	"Latn",
}

m["hwa"] = {
	"Wané",
	3914887,
	"kro-ekr",
	"Latn",
}

m["hwc"] = {
	"Hawaiian Creole",
	35602,
	"crp",
	"Latn",
}

m["hwo"] = {
	"Hwana",
	56498,
	"cdc-cbm",
	"Latn",
}

m["hya"] = {
	"Hya",
	56798,
	"cdc-cbm",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")