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
	"tiếng Ch'orti'",
	35177,
	"myn",
	"Latn",
	"Tiếng Ch'orti'",
	"Ch'orti'",
}

m["cab"] = {
	"tiếng Garifuna",
	35490,
	"awd-taa",
	"Latn",
	"Tiếng Garifuna",
	"Garifuna",
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
	"tiếng Laalaa",
	35564,
	"alv-cng",
	"Latn",
	"Tiếng Laalaa",
	"Laalaa",
}

m["caf"] = {
	"tiếng Carrier Nam",
	12953426,
	"ath-nor",
	"Latn, Cans",
	"Tiếng Carrier Nam",
	"Carrier Nam",
}

m["cag"] = {
	"tiếng Nivaclé",
	3182557,
	"sai-mtc",
	"Latn",
	"Tiếng Nivaclé",
	"Nivaclé",
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
	"tiếng Kaqchikel",
	35115,
	"myn",
	"Latn",
	"Tiếng Kaqchikel",
	"Kaqchikel",
}

m["cal"] = {
	"Carolinian",
	28427,
	"poz-mic",
	"Latn",
}

m["cam"] = {
	"Cemuhî",
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
	"tiếng Nicobar Car",
	35156,
	"aav-nic",
	"Latn, Deva",
	"Tiếng Nicobar Car",
	"Nicobar Car",
}

m["car"] = {
	"tiếng Kari'na",
	56611,
	"sai-gui",
	"Latn",
	"Tiếng Kari'na",
	"Kari'na",
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
	"Callawalla",
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
	"tiếng Cayuga",
	32967,
	"iro-nor",
	"Latn",
	"Tiếng Cayuga",
	"Cayuga",
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
	"tiếng Chachi",
	2591329,
	"sai-bar",
	"Latn",
	"Tiếng Chachi",
	"Chachi",
}

m["cbj"] = {
	"Ede Cabe",
	33112829,
	"alv-ede",
	"Latn",
}

m["cbk"] = {
	"tiếng Chavacano",
	33281,
	"crp",
	"Latn",
	"Tiếng Chavacano",
	"Chavacano",
    ancestors = "es",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer}},
	sort_key = {
		Latn = {
			from = {"ch", "ll", "ñ", "r"},
			to = {"c" .. p[1], "l" .. p[1], "n" .. p[1], "r" .. p[1]}
		},
	},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnÑñOoPpQqRrSsTtUuVvWwXxYyZz",
		c.punc
	},
}

m["cbl"] = {
	"Bualkhaw Chin",
	9229830,
	"tbq-kuk",
	"Latn",
}

m["cbn"] = {
	"tiếng Nyah Kur",
	116849,
	"mkh-mnc",
	"Thai",
	"Tiếng Nyah Kur",
	"Nyah Kur",
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
	"Shuba",
	nil,
	"nic-knj",
	"Latn",
	ancestors = "lan",
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
	"tiếng Chamicuro",
	2155119,
	"awd",
	"Latn",
	"Tiếng Chamicuro",
	"Chamicuro",
}

m["ccd"] = {
	"Cafundó",
	3331506,
	"roa-ibe",
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
	"tiếng Chakma",
	32952,
	"inc-eas",
	"Cakm, Beng, Latn",
	"Tiếng Chakma",
	"Chakma",
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
	"tiếng Trác Ni",
	2964447,
	"sit-tib",
	"Tibt",
	"Tiếng Trác Ni",
	"Trác Ni",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["cde"] = {
	"tiếng Chenchu",
	32981,
	"dra-tel",
	"Telu",
	"Tiếng Chenchu",
	"Chenchu",
	translit = "te-translit",
}

m["cdf"] = {
	"tiếng Chiru",
	5102016,
	"tbq-kuk",
	"Latn, Beng",
	"Tiếng Chiru",
	"Chiru",
}

m["cdh"] = {
	"tiếng Chamba",
	12953424,
	"him",
	"Deva, Takr",
	"Tiếng Chamba",
	"Chamba",
	translit = {Deva = "hi-translit"},
}

m["cdi"] = {
	"tiếng Chodri",
	5103788,
	"inc-bhi",
	"Gujr",
	"Tiếng Chodri",
	"Chodri",
}

m["cdj"] = {
	"tiếng Churah",
	12629039,
	"him",
	"Deva, Takr",
	"Tiếng Churah",
	"Churah",
	translit = {Deva = "hi-translit"},
}

m["cdm"] = {
	"tiếng Chepang",
	5091700,
	"sit-gma",
	"Deva",
	"Tiếng Chepang",
	"Chepang",
}

m["cdn"] = {
	"Chaudangsi",
	5088056,
	"sit-alm",
}

m["cdo"] = {
	"tiếng Mân Đông",
	36455,
	"zhx-com",
	"Hants",
	"Tiếng Mân Đông",
	"Mân Đông",
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
	"tiếng Trà Động",
	926742,
	"qfa-kms",
}

m["cdz"] = {
	"tiếng Koda",
	6425038,
	"mun",
	"Beng",
	"Tiếng Koda",
	"Koda",
}

m["cea"] = {
	"Lower Chehalis",
	6693377,
	"sal",
	"Latn",
}

m["ceb"] = {
	"tiếng Cebu",
	33239,
	"phi",
	"Latn, Tglg",
	"Tiếng Cebu",
	"Cebu",
	translit = {
		Tglg = "ceb-translit"
	},
	override_translit = true,
	entry_name = {
			Latn = {
				remove_diacritics = c.grave .. c.acute .. c.circ
		}
	},
	standardChars = {
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
	sort_key = {Latn = "tl-sortkey"},
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

m["cey"] = {
	"tiếng Chin Ekai",
	62603115,
	"tbq-kuk",
	"Mymr",
	"Tiếng Chin Ekai",
	"Chin Ekai",
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
	"tiếng Chin Falam",
	56815,
	"tbq-kuk",
	"Beng, Latn",
	"Tiếng Chin Falam",
	"Chin Falam",
}

m["cga"] = {
	"Changriwa",
	5072105,
	"paa-yua",
	"Latn",
}

m["cgc"] = {
	"tiếng Kagayanen",
	6346422,
	"mno",
	"Latn",
	"Tiếng Kagayanen",
	"Kagayanen",
}

m["cgg"] = {
	"Rukiga",
	3270727,
	"bnt-nyg",
	"Latn",
}

m["cgk"] = {
	"tiếng Chocangacakha",
	56604,
	"sit-tib",
	"Tibt",
	"Tiếng Chocangacakha",
	"Chocangacakha",
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["chb"] = {
	"tiếng Chibcha",
	2356431,
	"cba",
	nil,
	"Tiếng Chibcha",
	"Chibcha",
}

m["chc"] = {
	"tiếng Catawba",
	5051602,
	"nai-cat",
	"Latn",
	"Tiếng Catawba",
	"Catawba",
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
	"tiếng Chagatai",
	36831,
	"trk-kar",
	"Arab",
	"Tiếng Chagatai",
	"Chagatai",
	ancestors = "zkh",
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		from = {u(0x0671)},
		to   = {u(0x0627)}
	},
}

m["chh"] = {
	"tiếng Chinook",
	6693380,
	"nai-ckn",
	"Latn",
	"Tiếng Chinook",
	"Chinook",
}

m["chj"] = {
	"tiếng Chinantec Ojitlán",
	5100110,
	"omq-chi",
	"Latn",
	"Tiếng Chinantec Ojitlán",
	"Chinantec Ojitlán",
}

m["chk"] = {
	"tiếng Chuuk",
	33161,
	"poz-mic",
	"Latn",
	"Tiếng Chuuk",
	"Chuuk",
}

m["chl"] = {
	"tiếng Cahuilla",
	56438,
	"azc-cup",
	"Latn",
	"Tiếng Cahuilla",
	"Cahuilla",
	entry_name = {remove_diacritics = c.acute .. c.macron},
}

-- chm "Mari" is not recognized as a language, but it is a family code

m["chn"] = {
	"biệt ngữ Chinook",
	35173,
	"crp",
	"Latn, Dupl",
	"Biệt ngữ Chinook",
	"biệt ngữ Chinook",
	ancestors = "chh, nuk",
}

m["cho"] = {
	"tiếng Choctaw",
	32979,
	"nai-mus",
	"Latn",
	"Tiếng Choctaw",
	"Choctaw",
	sort_key = {remove_diacritics = c.macronbelow .. "-"},
	entry_name = {remove_diacritics = c.acute .. c.dotbelow},
}

m["chp"] = {
	"tiếng Denesuline",
	27692,
	"ath-nor",
	"Latn, Cans",
	"Tiếng Denesuline",
	"Denesuline",
}

m["chq"] = {
	"Quiotepec Chinantec",
	5758709,
	"omq-chi",
	"Latn",
}

m["chr"] = {
	"tiếng Cherokee",
	33388,
	"iro",
	"Cher",
	"Tiếng Cherokee",
	"Cherokee",
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
	"tiếng Chantyal",
	4926344,
	"sit-tam",
	"Deva",
	"Tiếng Chantyal",
	"Chantyal",
}

m["chy"] = {
	"tiếng Cheyenne",
	33265,
	"alg",
	"Latn",
	"Tiếng Cheyenne",
	"Cheyenne",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.macron .. c.dotabove .. "-"},
	standardChars = "AaÁáÀàĀāȦȧEeÉéÈèĒēĖėHhKkMmNnOoÓóÒòŌōȮȯPpSsŠšTtVvXx" .. c.punc, --umlaut and circumflex not allowed
}

m["chz"] = {
	"tiếng Chinantec Ozumacín",
	5100111,
	"omq-chi",
	"Latn",
	"Tiếng Chinantec Ozumacín",
	"Chinantec Ozumacín",
	entry_name = {remove_diacritics = "ˈˊˉꜗꜘꜙꜚ˜ˋ"},
}

m["cia"] = {
	"tiếng Cia-Cia",
	35284,
	"poz-mun",
	"Hang, Latn, Arab",
	"Tiếng Cia-Cia",
	"Cia-Cia"
}

m["cib"] = {
	"Ci Gbe",
	12952445,
	"alv-gbe",
	"Latn",
}

m["cic"] = {
	"tiếng Chickasaw",
	33192,
	"nai-mus",
	"Latn",
	"Tiếng Chickasaw",
	"Chickasaw",
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
	"tiếng Chinal",
	11855245,
	"inc",
	"Deva, Takr",
	"Tiếng Chinal",
	"Chinal",
	ancestors = "sa",
}

m["cik"] = {
	"Chitkuli Kinnauri",
	15615982,
	"sit-kin",
}

m["cim"] = {
	"tiếng Cimbri",
	37053,
	"gmw-hgm",
	"Latn",
	"Tiếng Cimbri",
	"Cimbri",
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
	"Tiri",
	7862281,
	"poz-cln",
	"Latn",
}

m["ciy"] = {
	"tiếng Chaima",
	12628867,
	"sai-ven",
	"Latn",
	"Tiếng Chaima",
	"Chaima",
}

m["cja"] = {
	"tiếng Chăm Tây",
	12645578,
	"cmc",
	"Latn, Arab, Khmr", -- Western Cham script is not yet available. Also, Arabic script is missing some glyphs.
	"Tiếng Chăm Tây",
	"Chăm Tây",
}

m["cje"] = {
	"tiếng Chu Ru",
	2967321,
	"cmc",
	"Latn",
	"Tiếng Chu Ru",
	"Chu Ru",
}

m["cjh"] = {
	"Upper Chehalis",
	2962074,
	"sal",
	"Latn",
}

m["cji"] = {
	"tiếng Chamalal",
	56567,
	"cau-and",
	"Cyrl",
	"Tiếng Chamalal",
	"Chamalal",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["cjk"] = {
	"Chokwe",
	2422065,
	"bnt-clu",
	"Latn",
}

m["cjm"] = {
	"tiếng Chăm Đông",
	2948019,
	"cmc",
	"Latn, Cham",
	"Tiếng Chăm Đông",
	"Chăm Đông",
}

m["cjn"] = {
	"Chenapian",
	5091044,
	"paa-spk",
	"Latn",
}

m["cjo"] = {
	"tiếng Ashéninka Pajonal",
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
	"tiếng Shor",
	34139,
	"trk-ssb",
	"Cyrl",
	"Tiếng Shor",
	"Shor",
	translit = "cjs-translit",
}

m["cjv"] = {
	"Chuave",
	5115226,
	"ngf",
	"Latn",
}

m["cjy"] = {
	"tiếng Tấn",
	56479,
	"zhx",
	"Hants",
	"Tiếng Tấn",
	"Tấn",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["ckb"] = {
	"tiếng Soran",
	36811,
	"ku",
	"ku-Arab",
	"Tiếng Soran",
	"Soran",
	translit = "ckb-translit",
	entry_name = {remove_diacritics = c.kasra .. c.sukun},
}

m["ckh"] = {
	"tiếng Chak",
	12628870,
	"sit-luu",
	"Latn, Mymr",
	"Tiếng Chak",
	"Chak",
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
	"tiếng Chukot",
	33170,
	"qfa-ckn",
	"Cyrl",
	"Tiếng Chukot",
	"Chukot",
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
	"tiếng Kavalan",
	716627,
	"map",
	"Latn",
	"Tiếng Kavalan",
	"Kavalan",
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
	"Cakchiquel-Quiché Mixed Language",
	5054550,
	"myn",
	"Latn",
}

m["cla"] = {
	"Ron",
	3440432,
	"cdc-wst",
	"Latn",
}

m["clc"] = {
	"tiếng Chilcotin",
	28535,
	"ath-nor",
	"Latn",
	"Tiếng Chilcotin",
	"Chilcotin",
}

m["cld"] = {
	"tiếng Tân Aram Chaldea",
	33236,
	"sem-are",
	"Syrc",
	"Tiếng Tân Aram Chaldea",
	"Tân Aram Chaldea",
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
	"tiếng Idu",
	56412,
	"sit-gsi",
	"Tibt, Deva, Latn",
	"Tiếng Idu",
	"Idu",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"], Latn = {remove_diacritics = c.grave .. c.acute .. c.macron}},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["cll"] = {
	"Chala",
	35190,
	"nic-gne",
	"Latn",
}

m["clm"] = {
	"tiếng Klallam",
	33404,
	"sal",
	"Latn",
	"Tiếng Klallam",
	"Klallam",
}

m["clo"] = {
	"Lowland Oaxaca Chontal",
	2964450,
	"nai-tqn",
	"Latn",
}

m["clt"] = {
	"tiếng Lutuv",
	6502107,
	"tbq-kuk",
	"Latn",
	"Tiếng Lutuv",
	"Lutuv",
}

m["clu"] = {
	"Caluyanun",
	32964,
	"phi",
	"Latn",
}

m["clw"] = {
	"tiếng Chulym",
	33125,
	"trk-ssb",
	"Latn, Cyrl",
	"Tiếng Chulym",
	"Chulym",
}

m["cly"] = {
	"Eastern Highland Chatino",
	12642078,
	"omq-cha",
	"Latn",
}

m["cma"] = {
	"tiếng Mạ",
	12953680,
	"mkh-ban",
	"Latn",
	"Tiếng Mạ",
	"Mạ",
}

m["cme"] = {
	"Cerma",
	35074,
	"nic-gur",
	"Latn",
}

m["cmg"] = {
	"tiếng Mông Cổ cổ điển",
	5128303,
	"xgn-cen",
	"Mong, Soyo, Zanb",
	"Tiếng Mông Cổ cổ điển",
	"Mông Cổ cổ điển",
	translit = {Mong = "Mong-translit"},
	display_text = {Mong = s["Mong-displaytext"]},
	entry_name = {Mong = s["Mong-entryname"]},
}

m["cmi"] = {
	"tiếng Emberá-Chamí",
	3052042,
	"sai-chc",
	"Latn",
	"Tiếng Emberá-Chamí",
	"Emberá-Chamí",
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
	"tiếng Quan Thoại",
	9192,
	"zhx-man",
	"Hants, Latn, Bopo",
	"Tiếng Quan Thoại",
	"Quan Thoại",
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
	"tiếng M'Nông Trung",
	33369881,
	"mkh-ban",
	"Latn, Khmr",
	"Tiếng M'Nông Trung",
	"M'Nông Trung",
}

m["cmr"] = {
	"Mro Chin",
	16889978,
	"tbq-kuk",
}

m["cms"] = {
	"tiếng Messapio",
	36383,
	"ine",
	"Latn, Ital, Grek",
	"Tiếng Messapio",
	"Messapio",
	translit = {Ital = "Ital-translit"},
}

m["cmt"] = {
	"Camtho",
	10441336,
	"crp",
	"Latn",
	ancestors = "fly, zu"
}

m["cna"] = {
	"tiếng Khương Đường",
	12952322,
	"sit-lab",
	"Tibt",
	"Tiếng Khương Đường",
	"Khương Đường",
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
	"tiếng Cống",
	5202780,
	"tbq-bis",
	"Latn",
	"Tiếng Cống",
	"Cống",
}

m["cng"] = {
	"tiếng Khương Bắc",
	56559,
	"sit-qia",
	"Latn",
	"Tiếng Khương Bắc",
	"Khương Bắc",
}

m["cnh"] = {
	"tiếng Chin Hakha",
	3250286,
	"tbq-kuk",
	"Latn, Mymr",
	"Tiếng Chin Hakha",
	"Chin Hakha",
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
	"tiếng Chenoua",
	33276,
	"ber",
	"Latn, Tfng",
	"Tiếng Chenoua",
	"Chenoua",
	translit = {Tfng = "Tfng-translit"},
}

m["cnw"] = {
	"Ngawn Chin",
	6583675,
	"tbq-kuk",
}

m["cnx"] = {
	"tiếng Cornwall trung đại",
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
	"tiếng Cocama",
	33317,
	"tup",
	"Latn",
	"Tiếng Cocama",
	"Cocama",
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
	"tiếng Chong",
	3914630,
	"mkh-pea",
	"Thai, Khmr",
	"Tiếng Chong",
	"Chong",
	sort_key = {Thai = "Thai-sortkey"},
}

m["coh"] = {
	"Chichonyi-Chidzihana-Chikauma",
	12629011,
	"bnt-mij",
	"Latn",
}

m["coj"] = {
	"tiếng Cochimi",
	3915551,
	"nai-yuc",
	"Latn",
	"Tiếng Cochimi",
	"Cochimi",
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
	"tiếng Comanche",
	32972,
	"azc-num",
	"Latn",
	"Tiếng Comanche",
	"Comanche",
}

m["con"] = {
	"tiếng Cofán",
	2669254,
	"qfa-iso",
	"Latn",
	"Tiếng Cofán",
	"Cofán",
}

m["coo"] = {
	"tiếng Comox",
	13583746,
	"sal",
	"Latn",
	"Tiếng Comox",
	"Comox",
}

m["cop"] = {
	"tiếng Copt",
	36155,
	"egx",
	"Copt",
	"Tiếng Copt",
	"Copt",
	translit = "Copt-translit",
	ancestors = "egx-dem",
	entry_name = {remove_diacritics = c.grave .. c.macron .. c.overline .. c.diaer .. "ˋ"},
	sort_key = "cop-sortkey",
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
	"tiếng Wamey",
	36935,
	"alv-ten",
	"Latn",
	"Tiếng Wamey",
	"Wamey",
}

m["cov"] = {
	"Cao Miao",
	2936935,
	"qfa-tak",
}

m["cow"] = {
	"tiếng Cowlitz",
	3001877,
	"sal",
	"Latn",
	"Tiếng Cowlitz",
	"Cowlitz",
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
	"tiếng Hy Lạp Cappadocia",
	853414,
	"grk",
	"Grek, fa-Arab",
	"Tiếng Hy Lạp Cappadocia",
	"Hy Lạp Cappadocia",
	ancestors = "gkm",
	translit = {Grek = "el-translit"},
	entry_name = {Grek = {remove_diacritics = c.caron .. c.diaerbelow .. c.brevebelow}},
	sort_key = {Grek = s["Grek-sortkey"]},
}

m["cpi"] = {
	"Chinese Pidgin English",
	3435078,
	"crp",
	"Latn, Hant",
	ancestors = "en",
	sort_key = {Hant = "Hani-sortkey"},
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
	"tiếng Phổ Hiền",
	56583,
	"zhx-com",
	"Hants",
	"Tiếng Phổ Hiền",
	"Phổ Hiền",
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
	3307894,
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
	"poz-oce",
	"Latn",
}

m["crd"] = {
	"tiếng Coeur d'Alene",
	32915,
	"sal",
	"Latn",
	"Tiếng Coeur d'Alene",
	"Coeur d'Alene",
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
	"tiếng Tatar Crưm",
	33357,
	"trk-kcu",
	"Latn, Cyrl, Arab",
	"Tiếng Tatar Crưm",
	"Tatar Crưm",
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
	"tiếng Cree Đông Nam",
	12953464,
	"alg",
	"Latn, Cans",
	"Tiếng Cree Đông Nam",
	"Cree Đông Nam",
	ancestors = "cr",
	translit = "cr-translit",
}

m["crk"] = {
	"tiếng Cree đồng bằng",
	56699,
	"alg",
	"Cans, Latn",
	"Tiếng Cree đồng bằng",
	"Cree đồng bằng",
	ancestors = "cr",
}

m["crl"] = {
	"tiếng Cree Đông Bắc",
	12642195,
	"alg",
	"Cans",
	"Tiếng Cree Đông Bắc",
	"Cree Đông Bắc",
	ancestors = "cr",
	translit = "cr-translit",
}

m["crm"] = {
	"tiếng Cree Moose",
	3446671,
	"alg",
	"Cans",
	"Tiếng Cree Moose",
	"Cree Moose",
	ancestors = "cr",
	translit = "cr-translit",
}

m["crn"] = {
	"Cora",
	12953454,
	"azc",
	"Latn",
}

m["cro"] = {
	"tiếng Crow",
	1207611,
	"sio-mor",
	"Latn",
	"Tiếng Crow",
	"Crow",
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
	"tiếng Chaura",
	2605680,
	"aav-nic",
	nil,
	"Tiếng Chaura",
	"Chaura",
}

m["crw"] = {
	"tiếng Chơ Ro",
	5105629,
	"mkh-ban",
	"Latn",
	"Tiếng Chơ Ro",
	"Chơ Ro",
}

m["crx"] = {
	"tiếng Carrier",
	12953431,
	"ath-nor",
	"Latn, Cans",
	"Tiếng Carrier",
	"Carrier",
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
	"tiếng Kaszëb",
	33690,
	"zlw-pom",
	"Latn",
	"Tiếng Kaszëb",
	"Kaszëb",
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
	"tiếng Chin Asho",
	12627282,
	"tbq-kuk",
	"Latn, Mymr",
	"Tiếng Chin Asho",
	"Chin Asho",
}

m["csi"] = {
	"Coast Miwok",
	2981109,
	"nai-you",
	"Latn",
}

m["csj"] = {
	"tiếng Chin Songlai",
	7561280,
	"tbq-kuk",
	"Mymr",
	"Tiếng Chin Songlai",
	"Chin Songlai",
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
	"tiếng Cree đầm lầy",
	56696,
	"alg",
	"Latn, Cans",
	"Tiếng Cree đầm lầy",
	"Cree đầm lầy",
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
	"tiếng Chin Tedim",
	56357,
	"tbq-kuk",
	"Latn, Pauc",
	"Tiếng Chin Tedim",
	"Chin Tedim",
}

m["cte"] = {
	"tiếng Chinantec Tepinapa",
	12953443,
	"omq-chi",
	"Latn",
	"Tiếng Chinantec Tepinapa",
	"Chinantec Tepinapa",
}

m["ctg"] = {
	"tiếng Chittagong",
	33173,
	"inc-eas",
	"Beng",
	"Tiếng Chittagong",
	"Chittagong",
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
	"tiếng Chatino cao nguyên Tây",
	32861734,
	"omq-cha",
	"Latn",
	"Tiếng Chatino cao nguyên Tây",
	"Chatino cao nguyên Tây",
	entry_name = {remove_diacritics = "¹²³⁴⁵"},
	sort_key = {remove_diacritics = c.acute},
}

m["cts"] = {
	"tiếng Bắc Catanduanes Bikol",
	7130477,
	"phi",
	"Latn",
	"Tiếng Bắc Catanduanes Bikol",
	"Bắc Catanduanes Bikol",
}

m["ctt"] = {
	"tiếng Chetti Wayanad",
	7975850,
	"dra-mal",
	"Taml",
	"Tiếng Chetti Wayanad",
	"Chetti Wayanad",
	translit = "ta-translit",
}

m["ctu"] = {
	"tiếng Chol",
	35179,
	"myn",
	"Latn",
	"Tiếng Chol",
	"Chol",
}

m["cty"] = {
	"tiếng Chetti Moundadan",
	105288428,
	"dra-kan",
	"Taml",
	"Tiếng Chetti Moundadan",
	"Chetti Moundadan",
	translit = "ta-translit",
}

m["ctz"] = {
	"tiếng Zacatepec Chatino",
	8063754,
	"omq-cha",
	"Latn",
	"Tiếng Zacatepec Chatino",
	"Zacatepec Chatino"
}

m["cua"] = {
	"tiếng Co",
	3441115,
	"mkh-ban",
	"Latn",
	"Tiếng Co",
	"Co",
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
	"tiếng Kuna",
	12953659,
	"cba",
	"Latn",
	"Tiếng Kuna",
	"Kuna",
}

m["cul"] = {
	"Culina",
	2475442,
	"auf",
	"Latn",
}

m["cuo"] = {
	"tiếng Cumanagoto",
	5193784,
	"sai-cpc",
	"Latn",
	"Tiếng Cumanagoto",
	"Cumanagoto",
}

m["cup"] = {
	"tiếng Cupeño",
	143130,
	"azc-cup",
	"Latn",
	"Tiếng Cupeño",
	"Cupeño",
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
	"sit-khb",
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
	"tiếng Cree rừng",
	56305,
	"alg",
	"Latn, Cans",
	"Tiếng Cree rừng",
	"Cree rừng",
	ancestors = "cr",
	translit = "cr-translit",
}

m["cwe"] = {
	"Kwere",
	779632,
	"bnt-ruv",
	"Latn",
}

m["cwg"] = {
	"tiếng Chewong",
	646718,
	"mkh-asl",
	"Latn",
	"Tiếng Chewong",
	"Chewong"
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
	"tiếng Cuyunon",
	33153,
	"phi",
	"Latn",
	"Tiếng Cuyunon",
	"Cuyunon",
}

m["czh"] = {
	"tiếng Huy",
	56546,
	"zhx",
	"Hants", -- ?
	"Tiếng Huy",
	"Huy",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["czk"] = {
	"tiếng Knaan",
	56384,
	"zlw",
	"Hebr",
	"Tiếng Knaan",
	"Knaan",
	ancestors = "zlw-ocs",
	entry_name = {Hebr = {remove_diacritics = u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. c.CGJ}},
}

m["czn"] = {
	"Zenzontepec Chatino",
	603106,
	"omq-cha",
	"Latn",
}

m["czo"] = {
	"tiếng Mân Trung",
	56435,
	"zhx-inm",
	"Hants",
	"Tiếng Mân Trung",
	"Mân Trung",
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