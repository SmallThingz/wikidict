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

m["caa"] = {
	"Ch'orti'",
	35177,
	"myn",
	"Latn",
}

m["cab"] = {
	"Garifuna",
	35490,
	"awd-taa",
	"Latn",
    ancestors = "crb",
}

m["cac"] = {
	"Chuj",
	35233,
	"myn",
	"Latn",
}

m["cad"] = {
	"Caddo",
	56756,
	"cdd",
	"Latn",
}

m["cae"] = {
	"Laalaa",
	35564,
	"alv-cng",
	"Latn",
}

m["caf"] = {
	"Southern Carrier",
	12953426,
	"ath-nor",
	"Latn",
}

m["cag"] = {
	"Nivaclé",
	3182557,
	"sai-mtc",
	"Latn",
}

m["cah"] = {
	"Cahuarano",
	2933175,
	"sai-zap",
	"Latn",
}

m["caj"] = {
	"Chané",
	56721,
	"awd",
	"Latn",
}

m["cak"] = {
	"Kaqchikel",
	35115,
	"myn",
	"Latn",
}

m["cal"] = {
	"Carolinian",
	28427,
	"poz-mic",
	"Latn",
}

m["cam"] = {
	"Cèmuhî",
	3009690,
	"poz-cln",
	"Latn",
}

m["can"] = {
	"Chambri",
	5069707,
	"paa-lsp",
	"Latn",
}

m["cao"] = {
	"Chácobo",
	2591202,
	"sai-pan",
	"Latn",
}

m["cap"] = {
	"Chipaya",
	35235,
	"sai-ucp",
	"Latn",
}

m["caq"] = {
	"Car Nicobarese",
	35156,
	"aav-nic",
	"Latn",
}

m["car"] = {
	"Kari'na",
	56611,
	"sai-gui",
	"Latn",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. "`" .. "'%-%s"},
	entry_name = {
		remove_diacritics = c.acute,
		from = {"â", "ê", "î", "ô", "û", "ŷ"},
		to = {"à", "è", "ì", "ò", "ù", "ỳ"}
	},
}

m["cas"] = {
	"Tsimané",
	35950,
	"qfa-iso",
	"Latn",
}

m["cav"] = {
	"Cavineña",
	524102,
	"sai-tac",
	"Latn",
}

m["caw"] = {
	"Kallawaya",
	266417,
	"qfa-mix",
	"Latn",
}

m["cax"] = {
	"Chiquitano",
	1844993,
	"qfa-iso",
	"Latn",
}

m["cay"] = {
	"Cayuga",
	32967,
	"iro-nor",
	"Latn",
}

m["caz"] = {
	"Canichana",
	2936374,
	"qfa-iso",
	"Latn",
}

m["cbb"] = {
	"Cabiyarí",
	3450660,
	"awd-nwk",
	"Latn",
}

m["cbc"] = {
	"Carapana",
	924405,
	"sai-tuc",
	"Latn",
}

m["cbd"] = {
	"Carijona",
	3446655,
	"sai-tar",
	"Latn",
}

m["cbg"] = {
	"Chimila",
	2963680,
	"cba",
	"Latn",
}

m["cbi"] = {
	"Chachi",
	2591329,
	"sai-bar",
	"Latn",
}

m["cbj"] = {
	"Ede Cabe",
	33112829,
	"alv-ede",
	"Latn",
}

m["cbk"] = {
	"Chavacano",
	33281,
	"crp",
	"Latn",
    ancestors = "es",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer},
	sort_key = {
		from = {"ch", "ll", "ñ", "r"},
		to = {"c" .. p[1], "l" .. p[1], "n" .. p[1], "r" .. p[1]}
	},
	standardChars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnÑñOoPpQqRrSsTtUuVvWwXxYyZz" .. c.punc,
}

m["cbl"] = {
	"Bualkhaw Chin",
	9229830,
	"tbq-kuk",
	"Latn",
}

m["cbn"] = {
	"Nyah Kur",
	116849,
	"mkh-mnc",
	"Thai",
	ancestors = "omx",
	sort_key = "Thai-sortkey",
}

m["cbo"] = {
	"Izora",
	3915454,
	"nic-jer",
	"Latn",
}

m["cbq"] = {
	"Tsucuba",
	62603062,
	"nic-knj",
	"Latn",
}

m["cbr"] = {
	"Cashibo-Cacataibo",
	5359560,
	"sai-pan",
	"Latn",
}

m["cbs"] = {
	"Cashinahua",
	2591230,
	"sai-pan",
	"Latn",
}

m["cbt"] = {
	"Chayahuita",
	1526525,
	"sai-cah",
	"Latn",
}

m["cbu"] = {
	"Candoshi-Shapra",
	642843,
	"qfa-iso",
	"Latn",
}

m["cbv"] = {
	"Cacua",
	3192052,
	"sai-nad",
	"Latn",
	ancestors = "mbr",
}

m["cbw"] = {
	"Kinabalian",
	6410324,
	"phi",
	"Latn",
}

m["cby"] = {
	"Carabayo",
	3441762,
	"sai-tyu",
	"Latn",
}

m["cca"] = {
	"Cauca",
	5054242,
	"sai-chc",
	"Latn",
}

m["ccc"] = {
	"Chamicuro",
	2155119,
	"awd",
	"Latn",
}

m["ccd"] = {
	"Cafundó",
	3331506,
	"roa-gap",
	"Latn",
	ancestors = "pt",
}

m["cce"] = {
	"Chopi",
	3437616,
	"bnt-bso",
	"Latn",
}

m["ccg"] = {
	"Chamba Daka",
	33120805,
	"nic-dak",
	"Latn",
}

m["cch"] = {
	"Atsam",
	34794,
	"nic-kne",
	"Latn",
}

m["ccj"] = {
	"Kasanga",
	35542,
	"alv-nyn",
	"Latn",
}

m["ccl"] = {
	"Cutchi-Swahili",
	5196729,
	"crp",
	"Latn",
	ancestors = "sw",
}

m["ccm"] = {
	"Malaccan Creole Malay",
	12636092,
	"crp",
	"Latn",
	ancestors = "ms",
}

m["cco"] = {
	"Comaltepec Chinantec",
	2963735,
	"omq-chi",
	"Latn",
}

m["ccp"] = {
	"Chakma",
	32952,
	"inc-bas",
	"Cakm, Beng, Latn",
	ancestors = "inc-obn",
	translit = {
		Cakm = "Cakm-translit",
		--Beng = "Beng-translit",
	},
}

m["ccr"] = {
	"Cacaopera",
	3438338,
	"nai-min",
	"Latn",
}

m["cda"] = {
	"Choni",
	2964447,
	"sit-tib",
}

m["cde"] = {
	"Chenchu",
	32981,
	"dra-tel",
	"Telu",
}

m["cdf"] = {
	"Chiru",
	5102016,
	"tbq-kuk",
	"Latn, Beng",
}

m["cdh"] = {
	"Chambeali",
	12953424,
	"him",
	"Deva, Takr",
	translit = {
		Deva = "hi-translit"
	},
}

m["cdi"] = {
	"Chodri",
	5103788,
	"inc-bhi",
	"Gujr",
}

m["cdj"] = {
	"Churahi",
	12629039,
	"him",
	"Deva, Takr",
	translit = {
		Deva = "hi-translit"
	},
}

m["cdm"] = {
	"Chepang",
	5091700,
	"sit-gma",
	"Deva",
}

m["cdn"] = {
	"Chaudangsi",
	5088056,
	"sit-alm",
}

m["cdo"] = {
	"Eastern Min",
	36455,
	"zhx-com",
	"Hants",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["cdr"] = {
	"Cinda-Regi-Tiyal",
	35596,
	"nic-kmk",
	"Latn",
}

m["cds"] = {
	"Chadian Sign Language",
	10322099,
	"sgn",
	"Latn", -- when documented
}

m["cdy"] = {
	"Chadong",
	926742,
	"qfa-kms",
}

m["cdz"] = {
	"Koda",
	6425038,
	"mun",
	"Beng",
}

m["cea"] = {
	"Lower Chehalis",
	6693377,
	"sal",
	"Latn",
}

m["ceb"] = {
	"Cebuano",
	33239,
	"phi",
	"Latn, Tglg",
	translit = {
		Tglg = "ceb-translit"
	},
	override_translit = true,
	entry_name = {
			Latn = {
				remove_diacritics = c.grave .. c.acute .. c.circ
		}
	},
	sort_key = {
		Latn = "tl-sortkey",
	},
	standardChars = {
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
}

m["ceg"] = {
	"Chamacoco",
	3436637,
	"sai-zam",
	"Latn",
}

m["cen"] = {
	"Cen",
	12628777,
	"nic-plc",
	"Latn",
	ancestors = "izr",
}

m["cet"] = {
	"Centúúm",
	33608,
	"qfa-iso",
	"Latn",
}

m["cfa"] = {
	"Dijim-Bwilim",
	3438350,
	"alv-wjk",
	"Latn",
}

m["cfd"] = {
	"Cara",
	35048,
	"nic-beo",
	"Latn",
}

m["cfg"] = {
	"Como Karim",
	35304,
	"nic-jkn",
	"Latn",
}

m["cfm"] = {
	"Falam Chin",
	56815,
	"tbq-kuk",
	"Beng, Latn",
}

m["cga"] = {
	"Changriwa",
	5072105,
	"paa-yua",
	"Latn",
}

m["cgc"] = {
	"Kagayanen",
	6346422,
	"mno",
	"Latn",
}

m["cgg"] = {
	"Rukiga",
	3270727,
	"bnt-nyg",
	"Latn",
}

m["cgk"] = {
	"Chocangaca",
	56604,
	"sit-tib",
	"Tibt",
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["chb"] = {
	"Chibcha",
	2356431,
	"cba",
	"Latn",
}

m["chc"] = {
	"Catawba",
	5051602,
	"nai-cat",
	"Latn",
}

m["chd"] = {
	"Highland Oaxaca Chontal",
	2964457,
	"nai-tqn",
	"Latn",
}

m["chf"] = {
	"Tabasco Chontal",
	35175,
	"myn",
	"Latn",
}

m["chg"] = {
	"Chagatai",
	36831,
	"trk-kar",
	"Arab",
	ancestors = "zkh",
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		from = {u(0x0671)},
		to   = {u(0x0627)}
	},
}

m["chh"] = {
	"Chinook",
	6693380,
	"nai-ckn",
	"Latn",
}

m["chj"] = {
	"Ojitlán Chinantec",
	5100110,
	"omq-chi",
	"Latn",
}

m["chk"] = {
	"Chuukese",
	33161,
	"poz-mic",
	"Latn",
}

m["chl"] = {
	"Cahuilla",
	56438,
	"azc-cup",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.macron},
}

-- chm "Mari" is not recognized as a language, but it is a family code

m["chn"] = {
	"Chinook Jargon",
	35173,
	"crp",
	"Latn, Dupl",
	ancestors = "chh, nuk",
}

m["cho"] = {
	"Choctaw",
	32979,
	"nai-mus",
	"Latn",
	sort_key = {remove_diacritics = c.macronbelow .. "-"},
	entry_name = {remove_diacritics = c.acute .. c.dotbelow},
}

m["chp"] = {
	"Chipewyan",
	27692,
	"ath-nor",
	"Latn, Cans",
}

m["chq"] = {
	"Quiotepec Chinantec",
	5758709,
	"omq-chi",
	"Latn",
}

m["chr"] = {
	"Cherokee",
	33388,
	"iro",
	"Cher",
	translit = "Cher-translit",
}

m["cht"] = {
	"Cholón",
	2591243,
	nil,
	"Latn",
}

m["chw"] = {
	"Chuabo",
	5118412,
	"bnt-mak",
	"Latn",
}

m["chx"] = {
	"Chantyal",
	4926344,
	"sit-tam",
	"Deva",
}

m["chy"] = {
	"Cheyenne",
	33265,
	"alg",
	"Latn",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.macron .. c.dotabove .. "-"},
	standardChars = "AaÁáÀàĀāȦȧEeÉéÈèĒēĖėHhKkMmNnOoÓóÒòŌōȮȯPpSsŠšTtVvXx" .. c.punc, --umlaut and circumflex not allowed
}

m["chz"] = {
	"Ozumacín Chinantec",
	5100111,
	"omq-chi",
	"Latn",
}

m["cia"] = {
	"Cia-Cia",
	35284,
	"poz-mun",
	"Hang, Latn, Arab",
}

m["cib"] = {
	"Ci Gbe",
	12952445,
	"alv-gbe",
	"Latn",
}

m["cic"] = {
	"Chickasaw",
	33192,
	"nai-mus",
	"Latn",
}

m["cid"] = {
	"Chimariko",
	1294251,
	"qfa-iso",
	"Latn",
}

m["cie"] = {
	"Cineni",
	56243,
	"cdc-cbm",
	"Latn",
}

m["cih"] = {
	"Chinali",
	11855245,
	"inc",
	"Deva",
	ancestors = "sa",
}

m["cik"] = {
	"Chitkuli Kinnauri",
	15615982,
	"sit-kin",
}

m["cim"] = {
	"Cimbrian",
	37053,
	"gmw-hgm",
	"Latn",
	ancestors = "bar",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.ringabove .. c.caron},
}

m["cin"] = {
	"Cinta Larga",
	5121095,
	"tup",
	"Latn",
}

m["cip"] = {
	"Chiapanec",
	3364475,
	"omq",
	"Latn",
}

m["cir"] = {
	"Tîrî",
	7862281,
	"poz-cln",
	"Latn",
}

m["ciy"] = {
	"Chaima",
	12628867,
	"sai-ven",
	"Latn",
}

m["cja"] = {
	"Western Cham",
	12645578,
	"cmc",
	"Latn, Arab, Khmr", -- Western Cham script is not yet available. Also, Arabic script is missing some glyphs.
}

m["cje"] = {
	"Chru",
	2967321,
	"cmc",
	"Latn",
}

m["cjh"] = {
	"Upper Chehalis",
	2962074,
	"sal",
	"Latn",
}

m["cji"] = {
	"Chamalal",
	56567,
	"cau-and",
	"Cyrl",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = s["cau-Cyrl-displaytext"],
	entry_name = s["cau-Cyrl-entryname"],
}

m["cjk"] = {
	"Chokwe",
	2422065,
	"bnt-clu",
	"Latn",
}

m["cjm"] = {
	"Eastern Cham",
	2948019,
	"cmc",
	"Latn, Cham",
}

m["cjn"] = {
	"Chenapian",
	5091044,
	"paa-spk",
	"Latn",
}

m["cjo"] = {
	"Ashéninka Pajonal",
	3450481,
	"awd",
	"Latn",
}

m["cjp"] = {
	"Cabécar",
	27878,
	"cba",
	"Latn",
}

m["cjs"] = {
	"Shor",
	34139,
	"trk-ssb",
	"Cyrl",
}

m["cjv"] = {
	"Chuave",
	5115226,
	"ngf",
	"Latn",
}

m["cjy"] = {
	"Jin",
	56479,
	"zhx",
	"Hants",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["ckb"] = {
	"Central Kurdish",
	36811,
	"ku",
	"ku-Arab",
	translit = "ckb-translit",
	entry_name = {remove_diacritics = c.kasra .. c.sukun},
}

m["ckh"] = {
	"Chak",
	12628870,
	"sit-luu",
	"Latn",
	ancestors = "kdv",
}

m["ckl"] = {
	"Cibak",
	56279,
	"cdc-cbm",
	"Latn",
}

m["ckn"] = {
	"Kaang Chin",
	6343432,
	"tbq-kuk",
	"Latn",
}

m["cko"] = {
	"Anufo",
	34845,
	"alv-ctn",
	"Latn",
}

m["ckq"] = {
	"Kajakse",
	3440422,
	"cdc-est",
	"Latn",
}

m["ckr"] = {
	"Kairak",
	3503002,
	"paa-bng",
	"Latn",
}

m["cks"] = {
	"Tayo",
	1133089,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["ckt"] = {
	"Chukchi",
	33170,
	"qfa-ckn",
	"Cyrl",
	entry_name = {
		from = {"['’]"},
		to = {"ʼ"}
	},
	sort_key = {
		from = {"ё", "ӄ", "ԓ", "ӈ"},
		to = {"е" .. p[1], "к" .. p[1], "л" .. p[1], "н" .. p[1]}
	},
}

m["cku"] = {
	"Koasati",
	35162,
	"nai-mus",
	"Latn",
}

m["ckv"] = {
	"Kavalan",
	716627,
	"map",
	"Latn",
}

m["ckx"] = {
	"Caka",
	5018037,
	"nic-tvc",
	"Latn",
}

m["cky"] = {
	"Cakfem-Mushere",
	3441199,
	"cdc-wst",
	"Latn",
}

m["ckz"] = {
	"Kaqchikel-K'iche' Mixed Language",
	5054550,
	"qfa-mix",
	"Latn",
	ancestors = "cak, quc"
}

m["cla"] = {
	"Ron",
	3440432,
	"cdc-wst",
	"Latn",
}

m["clc"] = {
	"Chilcotin",
	28535,
	"ath-nor",
	"Latn",
}

m["cld"] = {
	"Chaldean Neo-Aramaic",
	33236,
	"sem-are",
	"Syrc",
	entry_name = "Syrc-entryname",
}

m["cle"] = {
	"Lealao Chinantec",
	6509365,
	"omq-chi",
	"Latn",
}

m["clh"] = {
	"Chilisso",
	3250629,
	"inc-koh",
	"ur-Arab",
}

m["cli"] = {
	"Chakali",
	35206,
	"nic-gnw",
	"Latn",
}

m["clj"] = {
	"Laitu Chin",
	6474196,
	"tbq-kuk",
}

m["clk"] = {
	"Idu",
	56412,
	"sit-gsi",
	"Tibt, Deva",
	translit = {
		Tibt = "Tibt-translit"
	},
	override_translit = true,
	display_text = {
		Tibt = s["Tibt-displaytext"]
	},
	entry_name = {
		Tibt = s["Tibt-entryname"]
	},
	sort_key = {
		Tibt = "Tibt-sortkey"
	},
}

m["cll"] = {
	"Chala",
	35190,
	"nic-gne",
	"Latn",
}

m["clm"] = {
	"Klallam",
	33404,
	"sal",
	"Latn",
}

m["clo"] = {
	"Lowland Oaxaca Chontal",
	2964450,
	"nai-tqn",
	"Latn",
}

m["clt"] = {
	"Lutuv",
	6502107,
	"tbq-kuk",
	"Latn",
}

m["clu"] = {
	"Caluyanun",
	32964,
	"phi",
	"Latn",
}

m["clw"] = {
	"Chulym",
	33125,
	"trk-ssb",
	"Latn, Cyrl",
}

m["cly"] = {
	"Eastern Highland Chatino",
	12642078,
	"omq-cha",
	"Latn",
}

m["cma"] = {
	"Mạ",
	12953680,
	"mkh-ban",
	"Latn",
}

m["cme"] = {
	"Cerma",
	35074,
	"nic-gur",
	"Latn",
}

m["cmg"] = {
	"Classical Mongolian",
	5128303,
	"xgn-cen",
	"Mong, Soyo, Zanb",
	translit = {
		Mong = "Mong-translit"
	},
	display_text = {
		Mong = s["Mong-displaytext"]
	},
	entry_name = {
		Mong = s["Mong-entryname"]
	},
}

m["cmi"] = {
	"Emberá-Chamí",
	3052042,
	"sai-chc",
	"Latn",
}

m["cml"] = {
	"Campalagian",
	5027893,
	"poz-ssw",
	"Latn",
}

m["cmm"] = {
	"Michigamea",
	12636809,
	"sio-msv",
	"Latn",
}

m["cmn"] = {
	"Mandarin",
	9192,
	"zhx-man",
	"Hants, Latn, Bopo, Brai",
	wikimedia_codes = "zh",
	generate_forms = "zh-generateforms",
	translit = {
		Hani = "zh-translit",
		Bopo = "zh-translit",
	},
	sort_key = {
		Hani = "Hani-sortkey",
		Latn = {
			from = {
				-- Sort terms with tone numbers immediately after equivalent terms with diacritics.
				"[aeiouv][" .. c.circ .. c.diaer .. "]?[nr]?g?[0-5]",
				-- Add temporary breaks between syllables.
				"([aeiouvmn][" .. c.circ .. c.diaer .. "]?[" .. c.macron .. c.acute .. c.caron .. c.grave .. "]?n?ŋ?g?r?)([bpmfdtnlgkhjqxzcsywrv']h?[aeiouvmn ])", p[1] .. "([ngr])$", p[1] .. "([ngr][%s%-'" .. p[1] .. "])",
				-- Substitute diacritics for syllable-final tone numbers, and add tone 0 where necessary.
				c.macron, c.acute, c.caron, c.grave, "([1-4])([^%s%p" .. p[1] .. "]+)", "([^0-5])%f[%z%s%p" .. p[1] .. "]",
				-- Substitute "v" shorthand for "ü" for a temporary placeholder, so that the (very rare) "v" initial is not affected by the later shorthand substitutions.
				"([^ " .. p[1] .. "])v",
				-- Remove temporary breaks.
				p[1],
				-- Substitute shorthands for full forms, and sort them immediately after equivalent terms.
				"%S*[csz]" .. c.circ .. "%S*", "%S*[ŋ" .. p[2] .. "]%S*", "ĉ", "ŝ", "ŋ", p[2], "ẑ",
				-- "ê" comes after "e", "ü" comes after "u" and apostrophes are removed (as their function is replaced by tone numbers).
				"[" .. c.circ .. c.diaer .. "]", "'",
				-- Sort numbered tone 5 after tone 0.
				"5!"
			},
			to = {
				"%0!",
				"%1" .. p[1] .. "%2", "%1", "%1",
				"1", "2", "3", "4", "%2%1", "%10",
				"%1" .. p[2],
				"",
				"%0\"", "%0\"", "ch", "sh", "ng", "ü", "zh",
				p[1], "",
				"0!!"
			}
		},
	},
}

m["cmo"] = {
	"Central Mnong",
	33369881,
	"mkh-ban",
}

m["cmr"] = {
	"Mro Chin",
	16889978,
	"tbq-kuk",
}

m["cms"] = {
	"Messapic",
	36383,
	"ine",
	"Ital, Latn, Polyt",
	translit = {
		Ital = "Ital-translit",
		Polyt = "grc-translit",
	},
	display_text = {
		Polyt = s["Polyt-displaytext"]
	},
	entry_name = {
		Polyt = s["Polyt-entryname"]
	},
	sort_key = {
		Polyt = s["Polyt-sortkey"]
	},
}

m["cmt"] = {
	"Camtho",
	10441336,
	"crp",
	"Latn",
	ancestors = "fly, zu"
}

m["cna"] = {
	"Changthang",
	12952322,
	"sit-lab",
	"Tibt",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["cnb"] = {
	"Chinbon Chin",
	12952327,
	"tbq-kuk",
}

m["cnc"] = {
	"Cốông",
	5202780,
	"tbq-bis",
	"Latn",
}

m["cng"] = {
	"Northern Qiang",
	56559,
	"sit-qia",
}

m["cnh"] = {
	"Lai",
	3250286,
	"tbq-kuk",
}

m["cni"] = {
	"Asháninka",
	3437230,
	"awd",
	"Latn",
}

m["cnk"] = {
	"Khumi Chin",
	56308,
	"tbq-kuk",
}

m["cnl"] = {
	"Lalana Chinantec",
	12953437,
	"omq-chi",
	"Latn",
}

m["cno"] = {
	"Con",
	3440883,
	"mkh-pal",
}

m["cnp"] = {
	"Northern Pinghua",
	84302463,
	"zhx-pin",
	"Hants",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["cnr"] = {
	"Montenegrin",
	8821,
	"zls",
	"Latn, Cyrl",
	entry_name = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"Ć", "ć", "Ś", "ś", "Ź", "ź"}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"З́", "з́", "С́", "с́"}
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"ć", "ś", "ź"},
			from = {"č", "ć", "dž", "đ", "lj", "nj", "š", "ś", "ž", "ź"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "l" .. p[1], "n" .. p[1], "s" .. p[1], "s" .. p[2], "z" .. p[1], "z" .. p[2]}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"з́", "с́"},
			from = {"ђ", "з́", "ј", "љ", "њ", "с́", "ћ", "џ"},
			to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "с" .. p[1], "т" .. p[1], "ч" .. p[1]}
		},
	},
	standardChars = {
		Latn = "AaBbCcČčĆćDdĐđEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšŚśTtUuVvZzŽžŹź",
		Cyrl = "АаБбВвГгДдЂђЕеЖжЗзЗ́з́ИиЈјКкЛлЉљМмНнЊњОоПпРрСсС́с́ТтЋћУуФфХхЦцЧчЏџШш",
		c.punc
	},
}

m["cns"] = {
	"Central Asmat",
	11732048,
	"ngf",
	"Latn",
}

m["cnt"] = {
	"Tepetotutla Chinantec",
	5100113,
	"omq-chi",
	"Latn",
}

m["cnu"] = {
	"Chenoua",
	33276,
	"ber",
}

m["cnw"] = {
	"Ngawn Chin",
	6583675,
	"tbq-kuk",
}

m["cnx"] = {
	"Middle Cornish",
	12642603,
	"cel-brs",
	"Latn",
	ancestors = "oco",
}

m["coa"] = {
	"Cocos Islands Malay",
	3441699,
	"crp",
	"Latn",
	ancestors = "ms",
}

m["cob"] = {
	"Chicomuceltec",
	3307204,
	"myn",
	"Latn",
}

m["coc"] = {
	"Cocopa",
	33044,
	"nai-yuc",
	"Latn",
}

m["cod"] = {
	"Cocama",
	33317,
	"tup",
	"Latn",
}

m["coe"] = {
	"Koreguaje",
	3198924,
	"sai-tuc",
	"Latn",
}

m["cof"] = {
	"Tsafiki",
	2567055,
	"sai-bar",
	"Latn",
}

m["cog"] = {
	"Chong",
	3914630,
	"mkh-pea",
	"Thai, Khmr",
	sort_key = {
		Thai = "Thai-sortkey"
	},
}

m["coh"] = {
	"Chichonyi-Chidzihana-Chikauma",
	12629011,
	"bnt-mij",
	"Latn",
}

m["coj"] = {
	"Cochimi",
	3915551,
	"nai-yuc",
	"Latn",
}

m["cok"] = {
	"Santa Teresa Cora",
	12641754,
	"azc",
	"Latn",
}

m["col"] = {
	"Columbia-Wenatchi",
	3324744,
	"sal",
	"Latn",
}

m["com"] = {
	"Comanche",
	32972,
	"azc-num",
	"Latn",
}

m["con"] = {
	"Cofán",
	2669254,
	"qfa-iso",
	"Latn",
}

m["coo"] = {
	"Comox",
	13583746,
	"sal",
	"Latn",
}

m["cop"] = {
	"Coptic",
	36155,
	"egx",
	"Copt",
	translit = "Copt-translit",
	ancestors = "egx-dem",
	entry_name = {remove_diacritics = c.grave .. c.macron .. c.overline .. c.diaer .. "ˋ"},
	sort_key = "Copt-sortkey",
}

m["coq"] = {
	"Coquille",
	12953452,
	"ath-pco",
	"Latn",
}

m["cot"] = {
	"Caquinte",
	3915557,
	"awd",
	"Latn",
}

m["cou"] = {
	"Wamey",
	36935,
	"alv-ten",
	"Latn",
}

m["cov"] = {
	"Cao Miao",
	2936935,
	"qfa-tak",
}

m["cow"] = {
	"Cowlitz",
	3001877,
	"sal",
	"Latn",
}

m["cox"] = {
	"Nanti",
	15342275,
	"awd",
	"Latn",
}

m["coy"] = {
	"Coyaima",
	56450,
	"sai-car",
	"Latn",
}

m["coz"] = {
	"Chochotec",
	2964262,
	"omq-pop",
	"Latn",
}

m["cpa"] = {
	"Palantla Chinantec",
	5100112,
	"omq-chi",
	"Latn",
}

m["cpb"] = {
	"Ucayali-Yurúa Ashéninka",
	3501858,
	"awd",
	"Latn",
}

m["cpc"] = {
	"Ajyíninka Apurucayali",
	3327405,
	"awd",
	"Latn",
}

m["cpg"] = {
	"Cappadocian Greek",
	853414,
	"grk",
	"Grek, fa-Arab",
	ancestors = "gkm",
	translit = {
		Grek = "el-translit",
	},
	display_text = {
		Grek = s["Grek-displaytext"],
	},
	entry_name = {
		Grek = s["Grek-entryname"],
	},
	sort_key = {
		Grek = s["Grek-sortkey"],
	},
}

m["cpi"] = {
	"Chinese Pidgin English",
	3435078,
	"crp",
	"Latn, Hant",
	ancestors = "en",
	sort_key = {
		Hant = "Hani-sortkey"
	},
}

m["cpn"] = {
	"Cherepon",
	35181,
	"alv-gng",
	"Latn",
}

m["cpo"] = {
	"Kpee",
	6435722,
	"dmn-jje",
}

m["cps"] = {
	"Capiznon",
	2937525,
	"phi",
	"Latn",
}

m["cpu"] = {
	"Pichis Ashéninka",
	7190661,
	"awd",
	"Latn",
}

m["cpx"] = {
	"Puxian Min",
	56583,
	"zhx-com",
	"Hants",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["cpy"] = {
	"South Ucayali Ashéninka",
	3501868,
	"awd",
	"Latn",
}

m["cqd"] = {
	"Chuanqiandian Cluster Miao",
	121627627,
	"hmn",
	"Latn, Plrd",
}

m["cra"] = {
	"Chara",
	5073694,
	"omv",
	"Latn",
}

m["crb"] = {
	"Kalinago",
	3450735,
	"awd-taa",
	"Latn",
}

m["crc"] = {
	"Lonwolwol",
	3259216,
	"poz-vnc",
	"Latn",
}

m["crd"] = {
	"Coeur d'Alene",
	32915,
	"sal",
	"Latn",
}

m["crf"] = {
	"Caramanta",
	3504195,
	"sai-chc",
	"Latn",
}

m["crg"] = {
	"Michif",
	13315,
	"qfa-mix",
	"Latn",
	ancestors = "cr, fr",
}

m["crh"] = {
	"Crimean Tatar",
	33357,
	"trk-kcu",
	"Latn, Cyrl",
	dotted_dotless_i = true,
	sort_key = {
		Latn = {
			from = {
				"[ıi]" .. c.breve, -- Convert ĭ into PUA so that the  decomposed form does not get caught by the next step. Also cover decomposed forms with ı and i, as decomposed Ĭ is converted to ı + ̆ due to the dotted dotless I logic).
				"i", -- Ensure "i" comes after "ı".
				"â", "ç", "ğ", "ı", p[3], "ñ", "ö", "ş", "ü"
			},
			to = {
				p[3],
				"i" .. p[1],
				"a", "c" .. p[1], "g" .. p[1], "i", "i" .. p[2], "n" .. p[1], "o" .. p[1], "s" .. p[1], "u" .. p[1],
			}
		},
		Cyrl = {
			from = {"гъ", "ё", "къ", "нъ", "дж"},
			to = {"г" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "ч" .. p[1]}
		},
	},
}

m["cri"] = {
	"Sãotomense",
	36536,
	"crp",
	"Latn",
	ancestors = "pt",
}

m["crj"] = {
	"Southern East Cree",
	12953464,
	"alg",
	"Latn, Cans",
	ancestors = "cr",
	translit = {
		Cans = "cr-translit"
	},
}

m["crk"] = {
	"Plains Cree",
	56699,
	"alg",
	"Latn, Cans",
	ancestors = "cr",
}

m["crl"] = {
	"Northern East Cree",
	12642195,
	"alg",
	"Latn, Cans",
	ancestors = "cr",
	translit = {
		Cans = "cr-translit"
	},
}

m["crm"] = {
	"Moose Cree",
	3446671,
	"alg",
	"Latn, Cans",
	ancestors = "cr",
}

m["crn"] = {
	"Cora",
	12953454,
	"azc",
	"Latn",
}

m["cro"] = {
	"Crow",
	1207611,
	"sio-mor",
	"Latn",
}

m["crq"] = {
	"Iyo'wujwa Chorote",
	3540927,
	"sai-mtc",
	"Latn",
}

m["crr"] = {
	"Carolina Algonquian",
	16113723,
	"alg-eas",
	"Latn",
}

m["crs"] = {
	"Seychellois Creole",
	34015,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["crt"] = {
	"Iyojwa'ja Chorote",
	3504118,
	"sai-mtc",
	"Latn",
}

m["crv"] = {
	"Chaura",
	2605680,
	"aav-nic",
}

m["crw"] = {
	"Chrau",
	5105629,
	"mkh-ban",
	"Latn",
}

m["crx"] = {
	"Carrier",
	12953431,
	"ath-nor",
	"Latn, Cans",
}

m["cry"] = {
	"Cori",
	35204,
	"nic-plc",
	"Latn",
}

m["crz"] = {
	"Cruzeño",
	2967636,
	"nai-chu",
	"Latn",
}

m["csa"] = {
	"Chiltepec Chinantec",
	12953435,
	"omq-chi",
	"Latn",
}

m["csb"] = {
	"Kashubian",
	33690,
	"zlw-pom",
	"Latn",
}

m["csc"] = {
	"Catalan Sign Language",
	35768,
	"sgn",
	"Latn", -- when documented
}

m["csd"] = {
	"Chiangmai Sign Language",
	5095211,
	"sgn",
}

m["cse"] = {
	"Czech Sign Language",
	5201809,
	"sgn",
	"Latn", -- when documented
}

m["csf"] = {
	"Cuban Sign Language",
	5192046,
	"sgn",
	"Latn", -- when documented
}

m["csg"] = {
	"Chilean Sign Language",
	3322112,
	"sgn",
	"Latn", -- when documented
}

m["csh"] = {
	"Asho Chin",
	12627282,
	"tbq-kuk",
}

m["csi"] = {
	"Coast Miwok",
	2981109,
	"nai-you",
	"Latn",
}

m["csj"] = {
	"Songlai Chin",
	7561280,
	"tbq-kuk",
}

m["csk"] = {
	"Jola-Kasa",
	3446622,
	"alv-jol",
	"Latn",
}

m["csl"] = {
	"Chinese Sign Language",
	1094190,
	"sgn",
}

m["csm"] = {
	"Central Sierra Miwok",
	2944443,
	"nai-you",
	"Latn",
}

m["csn"] = {
	"Colombian Sign Language",
	2748229,
	"sgn",
	"Latn", -- when documented
}

m["cso"] = {
	"Sochiapam Chinantec",
	7550388,
	"omq-chi",
	"Latn",
}

m["csp"] = {
	"Southern Pinghua",
	84302019,
	"zhx-pin",
	"Hants",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["csq"] = {
	"Croatian Sign Language",
	3507506,
	"sgn",
}

m["csr"] = {
	"Costa Rican Sign Language",
	5174901,
	"sgn",
	"Latn", -- when documented
}

m["css"] = {
	"Southern Ohlone",
	25559664,
	"nai-you",
	"Latn",
}

m["cst"] = {
	"Northern Ohlone",
	25559666,
	"nai-you",
	"Latn",
}

m["csv"] = {
	"Sumtu Chin",
	7638087,
	"tbq-kuk",
}

m["csw"] = {
	"Swampy Cree",
	56696,
	"alg",
	"Latn, Cans",
	ancestors = "cr",
}

m["csy"] = {
	"Siyin Chin",
	7533375,
	"tbq-kuk",
}

m["csz"] = {
	"Coos",
	3126783,
	"nai-coo",
	"Latn",
}

m["cta"] = {
	"Tataltepec Chatino",
	7687853,
	"omq-cha",
	"Latn",
}

m["ctc"] = {
	"Chetco-Tolowa",
	12628946,
	"ath-pco",
	"Latn",
}

m["ctd"] = {
	"Tedim Chin",
	56357,
	"tbq-kuk",
	"Latn, Pauc",
}

m["cte"] = {
	"Tepinapa Chinantec",
	12953443,
	"omq-chi",
	"Latn",
}

m["ctg"] = {
	"Chittagonian",
	33173,
	"inc-bas",
	"Beng",
	ancestors = "inc-obn",
}

m["cth"] = {
	"Thaiphum Chin",
	16912048,
	"tbq-kuk",
}

m["ctl"] = {
	"Tlacoatzintepec Chinantec",
	12643657,
	"omq-chi",
	"Latn",
}

m["ctm"] = {
	"Chitimacha",
	1294227,
	"qfa-iso",
	"Latn",
}

m["ctn"] = {
	"Chhintange",
	32994,
	"sit-kie",
	"Deva",
}

m["cto"] = {
	"Emberá-Catío",
	3052039,
	"sai-chc",
	"Latn",
}

m["ctp"] = {
	"Western Highland Chatino",
	32861734,
	"omq-cha",
	"Latn",
	entry_name = {remove_diacritics = "¹²³⁴⁵"},
	sort_key = {remove_diacritics = c.acute},
}

m["cts"] = {
	"Northern Catanduanes Bicolano",
	7130477,
	"phi",
	"Latn",
}

m["ctt"] = {
	"Wayanad Chetti",
	7975850,
	"dra-mal",
	"Taml",
}

m["ctu"] = {
	"Chol",
	35179,
	"myn",
	"Latn",
}

m["ctz"] = {
	"Zacatepec Chatino",
	8063754,
	"omq-cha",
	"Latn",
}

m["cua"] = {
	"Cua",
	3441115,
	"mkh-ban",
	"Latn",
}

m["cub"] = {
	"Cubeo",
	3006705,
	"sai-tuc",
	"Latn",
}

m["cuc"] = {
	"Usila Chinantec",
	7901979,
	"omq-chi",
	"Latn",
}

m["cug"] = {
	"Cung",
	35194,
	"nic-bbe",
	"Latn",
}

m["cuh"] = {
	"Chuka",
	12952344,
	"bnt-kka",
	"Latn",
}

m["cui"] = {
	"Cuiba",
	2980421,
	"sai-guh",
	"Latn",
}

m["cuj"] = {
	"Mashco Piro",
	3446596,
	"awd",
	"Latn",
}

m["cuk"] = {
	"Kuna",
	12953659,
	"cba",
	"Latn",
}

m["cul"] = {
	"Culina",
	2475442,
	"auf",
	"Latn",
}

m["cuo"] = {
	"Cumanagoto",
	5193784,
	"sai-cpc",
	"Latn",
}

m["cup"] = {
	"Cupeño",
	143130,
	"azc-cup",
	"Latn",
}

m["cuq"] = {
	"Cun",
	2475478,
	"qfa-lic",
	"Latn",
}

m["cur"] = {
	"Chhulung",
	5116126,
	"sit-kie",
	"Deva",
}

m["cut"] = {
	"Teutila Cuicatec",
	12953453,
	"omq-cui",
	"Latn",
}

m["cuu"] = {
	"Tai Ya",
	3441122,
	"qfa-tak",
	"Latn",
}

m["cuv"] = {
	"Cuvok",
	3515056,
	"cdc-cbm",
	"Latn",
}

m["cuw"] = {
	"Chukwa",
	12629033,
	"sit-kic",
}

m["cux"] = {
	"Tepeuxila Cuicatec",
	20527242,
	"omq-cui",
	"Latn",
}

m["cuy"] = {
	"Cuitlatec",
	2030998,
	"qfa-iso",
	"Latn",
}

m["cvg"] = {
	"Chug",
	47683644,
	"sit-khc",
}

m["cvn"] = {
	"Valle Nacional Chinantec",
	12953442,
	"omq-chi",
	"Latn",
}

m["cwa"] = {
	"Kabwa",
	6344537,
	"bnt-lok",
	"Latn",
}

m["cwb"] = {
	"Maindo",
	11002891,
	"bnt-mak",
	"Latn",
	ancestors = "chw",
}

m["cwd"] = {
	"Woods Cree",
	56305,
	"alg",
	"Latn, Cans",
	ancestors = "cr",
}

m["cwe"] = {
	"Kwere",
	779632,
	"bnt-ruv",
	"Latn",
}

m["cwg"] = {
	"Chewong",
	646718,
	"mkh-asl",
	"Latn",
}

m["cwt"] = {
	"Kuwaataay",
	35699,
	"alv-jol",
	"Latn",
}

m["cya"] = {
	"Nopala Chatino",
	15616302,
	"omq-cha",
	"Latn",
}

m["cyb"] = {
	"Cayubaba",
	3183382,
	"qfa-iso",
	"Latn",
}

m["cyo"] = {
	"Cuyunon",
	33153,
	"phi",
	"Latn",
}

m["czh"] = {
	"Huizhou",
	56546,
	"zhx",
	"Hants", -- ?
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["czk"] = {
	"Knaanic",
	56384,
	"zlw",
	"Hebr",
	ancestors = "zlw-ocs",
	display_text = "Hebr-common",
	entry_name = "Hebr-common",
	sort_key = "Hebr-common",
}

m["czn"] = {
	"Zenzontepec Chatino",
	603106,
	"omq-cha",
	"Latn",
}

m["czo"] = {
	"Central Min",
	56435,
	"zhx-inm",
	"Hants",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["czt"] = {
	"Zotung Chin",
	8074599,
	"tbq-kuk",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")