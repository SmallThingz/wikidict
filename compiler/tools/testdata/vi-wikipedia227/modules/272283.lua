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

m["baa"] = {
	"tiếng Babatana",
	2877785,
	"poz-ocw",
	"Latn",
	"Tiếng Babatana",
	"Babatana",
}

m["bab"] = {
	"tiếng Bainouk-Gunyuño",
	35508,
	"alv-bny",
	"Latn",
	"Tiếng Bainouk-Gunyuño",
	"Bainouk-Gunyuño",
}

m["bac"] = {
	"tiếng Badui",
	3449885,
	"poz-msa",
	"Latn",
	"Tiếng Badui",
	"Badui",
}

m["bae"] = {
	"tiếng Baré",
	3504087,
	"awd",
	"Latn",
	"Tiếng Baré",
	"Baré",
}

m["baf"] = {
	"tiếng Nubaca",
	36270,
	"nic-ymb",
	"Latn",
	"Tiếng Nabaca",
	"Nubaca",
}

m["bag"] = {
	"tiếng Tuki",
	36621,
	"nic-mba",
	"Latn",
	"Tiếng Tuki",
	"Tuki",
}

m["bah"] = {
	"Bahamian Creole",
	2669229,
	"crp",
	"Latn",
	ancestors = "en",
}

m["baj"] = {
	"tiếng Barakai",
	3502030,
	"poz-cet",
	"Latn",
	"Tiếng Barakai",
	"Barakai"
}

m["bal"] = {
	"tiếng Baloch",
	33049,
	"ira-nwi",
	"fa-Arab, Cyrl",
	"Tiếng Baloch",
	"Baloch",
}

m["ban"] = {
	"tiếng Bali",
	33070,
	"poz-mcm",
	"Latn, Bali",
	"Tiếng Bali",
	"Bali",
}

m["bao"] = {
	"tiếng Waimaha",
	2883738,
	"sai-tuc",
	"Latn",
	"Tiếng Waimaha",
	"Waimaha",
}

m["bap"] = {
	"tiếng Bantawa",
	56500,
	"sit-kic",
	"Krai, Deva",
	"Tiếng Bantawa",
	"Bantawa",
}

m["bar"] = {
	"tiếng Bayern",
	29540,
	"gmw-hgm",
	"Latn",
	"Tiếng Bayern",
	"Bayern",
	ancestors = "gmh",
}

m["bas"] = {
	"tiếng Basaa",
	33093,
	"bnt-bsa",
	"Latn",
	"Tiếng Basaa",
	"Basaa",
}

m["bau"] = {
	"tiếng Badanchi",
	11001650,
	"nic-jrw",
	"Latn",
	"Tiếng Badanchi",
	"Badanchi",
}

m["bav"] = {
	"tiếng Babungo",
	34885,
	"nic-rnn",
	"Latn",
	"Tiếng Babungo",
	"Babungo"
}

m["baw"] = {
	"Bambili-Bambui",
	34880,
	"nic-nge",
	"Latn",
}

m["bax"] = {
	"tiếng Bamum",
	35280,
	"nic-nun",
	"Latn, Bamu",
	"Tiếng Bamum",
	"Bamum",
}

m["bay"] = {
	"tiếng Batuley",
	8828787,
	"poz",
	"Latn",
	"Tiếng Batuley",
	"Batuley",
}

m["bba"] = {
	"tiếng Baatonum",
	34889,
	"alv-sav",
	"Latn",
	"Tiếng Baatonum",
	"Baatonum",
}

m["bbb"] = {
	"tiếng Barai",
	4858206,
	"ngf",
	"Latn",
	"Tiếng Barai",
	"Barai",
}

m["bbc"] = {
	"Toba Batak",
	33017,
	"btk",
	"Latn, Batk",
}

m["bbd"] = {
	"Bau",
	4873415,
	"ngf-mad",
	"Latn",
}

m["bbe"] = {
	"Bangba",
	34895,
	"nic-nke",
	"Latn",
}

m["bbf"] = {
	"Baibai",
	56902,
	"paa",
	"Latn",
}

m["bbg"] = {
	"Barama",
	34884,
	"bnt-sir",
	"Latn",
}

m["bbh"] = {
	"tiếng Bố Cam",
	3033554,
	"mkh-pkn",
	"Latn",
	"Tiếng Bố Cam",
	"Bố Cam",
}

m["bbi"] = {
	"tiếng Barombi",
	34985,
	"bnt-bsa",
	"Latn",
	"Tiếng Barombi",
	"Barombi",
}

m["bbj"] = {
	"tiếng Ghomala'",
	35271,
	"bai",
	"Latn",
	"Tiếng Ghomala'",
	"Ghomala'",
}

m["bbk"] = {
	"Babanki",
	34790,
	"nic-rnc",
	"Latn",
}

m["bbl"] = {
	"tiếng Bats",
	33259,
	"cau-nkh",
	"Geor",
	"Tiếng Bats",
	"Bats",
	translit = "Geor-translit",
	override_translit = true,
	entry_name = {
		remove_diacritics = c.tilde .. c.macron .. c.breve,
		from = {"<sup>ნ</sup>"},
		to = {"ნ"}
	},
}

m["bbm"] = { -- name includes prefix
	"Babango",
	34819,
	"bnt-bta",
	"Latn",
}

m["bbn"] = {
	"tiếng Uneapa",
	7884126,
	"poz-ocw",
	"Latn",
	"Tiếng Uneapa",
	"Uneapa",
}

m["bbo"] = {
	"tiếng Konabéré",
	35371,
	"dmn-snb",
	"Latn",
	"Tiếng Konabéré",
	"Konabéré",
}

m["bbp"] = {
	"West Central Banda",
	7984377,
	"bad",
	"Latn",
}

m["bbq"] = {
	"Bamali",
	34901,
	"nic-nun",
	"Latn",
}

m["bbr"] = {
	"Girawa",
	5564185,
	"ngf-mad",
	"Latn",
}

m["bbs"] = {
	"Bakpinka",
	3515061,
	"nic-ucr",
	"Latn",
}

m["bbt"] = {
	"Mburku",
	3441324,
	"cdc-wst",
	"Latn",
}

m["bbu"] = {
	"Bakulung",
	35580,
	"nic-jrn",
	"Latn",
}

m["bbv"] = {
	"Karnai",
	6372803,
	"poz-ocw",
	"Latn",
}

m["bbw"] = {
	"Baba",
	34822,
	"nic-nun",
	"Latn",
}

m["bbx"] = { -- cf bvb
	"Bubia",
	34953,
	"nic-bds",
	"Latn",
	ancestors = "bvb",
}

m["bby"] = {
	"Befang",
	34960,
	"nic-bds",
	"Latn",
}

m["bca"] = {
	"tiếng Bạch Trung",
	12628803,
	"sit-bai",
	"Hani, Latn",
	"Tiếng Bạch Trung",
	"Bạch Trung",
	sort_key = {Hani = "Hani-sortkey"},
}

m["bcb"] = {
	"Bainouk-Samik",
	36390,
	"alv-bny",
	"Latn",
}

m["bcd"] = {
	"North Babar",
	7054041,
	"poz-tim",
	"Latn",
}

m["bce"] = {
	"Bamenyam",
	34968,
	"nic-nun",
	"Latn",
}

m["bcf"] = {
	"Bamu",
	3503788,
	"paa-kiw",
	"Latn",
}

m["bcg"] = {
	"Baga Pokur",
	31172660,
	"alv-nal",
	"Latn",
}

m["bch"] = {
	"Bariai",
	2884502,
	"poz-ocw",
	"Latn",
}

m["bci"] = {
	"tiếng Baoule",
	35107,
	"alv-ctn",
	"Latn",
	"Tiếng Baoule",
	"Baoule",
}

m["bcj"] = {
	"Bardi",
	3913852,
	"aus-nyu",
	"Latn",
}

m["bck"] = {
	"Bunaba",
	580923,
	"aus-bub",
	"Latn",
}

m["bcl"] = {
	"tiếng Trung Bikol",
	33284,
	"phi",
	"Latn, Tglg",
	"Tiếng Trung Bikol",
	"Trung Bikol",
	translit = {
		Tglg = "bcl-translit",
	},
	override_translit = true,
	entry_name = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.circ,
		}
	},
    sort_key = {
		Latn = "tl-sortkey",
	},
	standardChars = { 
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy" .. c.punc,
	},
}

m["bcm"] = {
	"Banoni",
	2882857,
	"poz-ocw",
	"Latn",
}

m["bcn"] = {
	"Bibaali",
	34892,
	"alv-mye",
	"Latn",
}

m["bco"] = {
	"Kaluli",
	6354586,
	"ngf",
	"Latn",
}

m["bcp"] = {
	"Bali",
	3515074,
	"bnt-kbi",
	"Latn",
}

m["bcq"] = {
	"tiếng Bench",
	35108,
	"omv",
	"Latn, Ethi",
	"Tiếng Bench",
	"Bench",
}

m["bcr"] = {
	"Babine-Witsuwit'en",
	27864,
	"ath-nor",
	"Latn",
}

m["bcs"] = {
	"Kohumono",
	35590,
	"nic-ucn",
	"Latn",
}

m["bct"] = {
	"Bendi",
	8836662,
	"csu-mle",
	"Latn",
}

m["bcu"] = {
	"Biliau",
	2874658,
	"poz-ocw",
	"Latn",
}

m["bcv"] = {
	"Shoo-Minda-Nye",
	36548,
	"nic-jkn",
	"Latn",
}

m["bcw"] = {
	"tiếng Bana",
	56272,
	"cdc-cbm",
	"Latn",
	"Tiếng Bana",
	"Bana",
}

m["bcy"] = {
	"tiếng Bacama",
	56274,
	"cdc-cbm",
	"Latn",
	"Tiếng Bacama",
	"Bacama",
}

m["bcz"] = {
	"Bainouk-Gunyaamolo",
	35506,
	"alv-bny",
	"Latn",
}

m["bda"] = {
	"Bayot",
	35019,
	"alv-jol",
	"Latn",
}

m["bdb"] = {
	"Basap",
	3504208,
	"poz-bnn",
	"Latn",
}

m["bdc"] = {
	"Emberá-Baudó",
	11173166,
	"sai-chc",
	"Latn",
}

m["bdd"] = {
	"Bunama",
	4997416,
	"poz-ocw",
	"Latn",
}

m["bde"] = {
	"tiếng Bade",
	56239,
	"cdc-wst",
	"Latn",
	"Tiếng Bade",
	"Bade",
}

m["bdf"] = {
	"Biage",
	48037487,
	"ngf",
	"Latn",
}

m["bdg"] = {
	"Bonggi",
	2910053,
	"poz-bnn",
	"Latn",
}

m["bdh"] = {
	"tiếng Tara Baka",
	2880165,
	"csu-bbk",
	"Latn",
	"Tiếng Tara Baka",
	"Tara Baka",
}

m["bdi"] = {
	"Burun",
	35040,
	"sdv-niw",
	"Latn",
}

m["bdj"] = {
	"Bai",
	34894,
	"nic-ser",
	"Latn",
}

m["bdk"] = {
	"tiếng Budukh",
	35397,
	"cau-ssm",
	"Cyrl",
	"Tiếng Budukh",
	"Budukh",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["bdl"] = {
	"Indonesian Bajau",
	2880038,
	"poz",
	"Latn",
}

m["bdm"] = {
	"Buduma",
	56287,
	"cdc-cbm",
	"Latn",
}

m["bdn"] = {
	"Baldemu",
	56280,
	"cdc-cbm",
	"Latn",
}

m["bdo"] = {
	"Morom",
	759770,
	"csu-bgr",
	"Latn",
}

m["bdp"] = {
	"Bende",
	8836490,
	"bnt",
	"Latn",
}

m["bdq"] = {
	"tiếng Ba Na",
	32924,
	"mkh-ban",
	"Latn",
	"Tiếng Ba Na",
	"Ba Na",
}

m["bdr"] = {
	"tiếng Tây Duyên hải Bajau",
	2880037,
	"poz-sbj",
	"Latn",
	"Tiếng Tây Duyên hải Bajau",
	"Tây Duyên hải Bajau",
}

m["bds"] = {
	"tiếng Burunge",
	56617,
	"cus-sou",
	"Latn",
	"Tiếng Burunge",
	"Burunge",
}

m["bdt"] = {
	"Bokoto",
	4938812,
	"alv-gbw",
	"Latn",
}

m["bdu"] = {
	"Oroko",
	36278,
	"bnt-saw",
	"Latn",
}

m["bdv"] = {
	"tiếng Bodo Parja",
	8845881,
	"inc-eas",
	"Orya",
	"Tiếng Bodo Parja",
	"Bodo Parja",
	translit = "or-translit",
}

m["bdw"] = {
	"Baham",
	3513309,
	"paa",
	"Latn",
}

m["bdx"] = {
	"Budong-Budong",
	4985158,
	"poz-ssw",
	"Latn",
}

m["bdy"] = {
	"tiếng Bandjalang",
	2980386,
	"aus-pam",
	"Latn",
	"Tiếng Bandjalang",
	"Bandjalang",
}

m["bdz"] = {
	"Badeshi",
	33028,
	"inc-wes",
	ancestors = "noe",
}

m["bea"] = {
	"tiếng Beaver",
	20826,
	"ath-nor",
	"Latn, Cans",
	"Tiếng Beaver",
	"Beaver",
}

m["beb"] = {
	"Bebele",
	34976,
	"bnt-btb",
	"Latn",
}

m["bec"] = {
	"Iceve-Maci",
	35449,
	"nic-tvc",
	"Latn",
}

m["bed"] = {
	"Bedoanas",
	4879330,
	"poz-hce",
	"Latn",
}

m["bee"] = {
	"Byangsi",
	56904,
	"sit-alm",
	"Deva",
}

m["bef"] = {
	"Benabena",
	2895638,
	"paa-kag",
	"Latn",
}

m["beg"] = {
	"Belait",
	2894198,
	"poz-swa",
	"Latn",
}

m["beh"] = {
	"Biali",
	34961,
	"nic-eov",
	"Latn",
}

m["bei"] = {
	"Bekati'",
	3441683,
	"day",
	"Latn",
}

m["bej"] = {
	"tiếng Beja",
	33025,
	"cus",
	"Arab, Latn",
	"Tiếng Beja",
	"Beja",
}

m["bek"] = {
	"Bebeli",
	4878430,
	"poz-ocw",
	"Latn",
}

m["bem"] = {
	"tiếng Bemba",
	33052,
	"bnt-sbi",
	"Latn",
	"Tiếng Bemba",
	"Bemba",
}

m["beo"] = {
	"Beami",
	3504079,
	"paa",
	"Latn",
}

m["bep"] = {
	"Besoa",
	8840465,
	"poz-kal",
	"Latn",
}

m["beq"] = {
	"Beembe",
	3196320,
	"bnt-kng",
	"Latn",
}

m["bes"] = {
	"Besme",
	289832,
	"alv-kim",
	"Latn",
}

m["bet"] = {
	"Guiberoua Bété",
	11019185,
	"kro-bet",
	"Latn",
}

m["beu"] = {
	"tiếng Blagar",
	4923846,
	"ngf",
	"Latn",
	"Tiếng Blagar",
	"Blagar",
}

m["bev"] = {
	"Daloa Bété",
	11155819,
	"kro-bet",
	"Latn",
}

m["bew"] = {
	"tiếng Betawi",
	33014,
	"crp",
	"Latn",
	"Tiếng Betawi",
	"Betawi",
	ancestors = "ms",
}

m["bex"] = {
	"Jur Modo",
	56682,
	"csu-bbk",
	"Latn",
}

m["bey"] = {
	"Akuwagel",
	3504170,
	"qfa-tor",
	"Latn",
}

m["bez"] = {
	"Kibena",
	2502949,
	"bnt-bki",
	"Latn",
}

m["bfa"] = {
	"tiếng Bari",
	35042,
	"sdv-bri",
	"Latn",
	"Tiếng Bari",
	"Bari",
}

m["bfb"] = {
	"Pauri Bareli",
	7155462,
	"inc-bhi",
	"Deva",
}

m["bfc"] = {
	"Panyi Bai",
	12642165,
	"sit-nba",
	"Hani, Latn",
	sort_key = {Hani = "Hani-sortkey"},
}

m["bfd"] = {
	"Bafut",
	34888,
	"nic-nge",
	"Latn",
}

m["bfe"] = {
	"Betaf",
	4897329,
	"paa-tkw",
	"Latn",
}

m["bff"] = {
	"Bofi",
	34914,
	"alv-gbf",
	"Latn",
}

m["bfg"] = {
	"Busang Kayan",
	9231909,
	"poz",
	"Latn",
}

m["bfh"] = {
	"Blafe",
	12628007,
	"paa",
	"Latn",
}

m["bfi"] = {
	"British Sign Language",
	33000,
	"sgn",
	"Latn", -- when documented
}

m["bfj"] = {
	"Bafanji",
	34890,
	"nic-nun",
	"Latn",
}

m["bfk"] = {
	"Ban Khor Sign Language",
	3441103,
	"sgn",
}

m["bfl"] = {
	"Banda-Ndélé",
	34850,
	"bad-cnt",
	"Latn",
}

m["bfm"] = {
	"Mmen",
	36132,
	"nic-rnc",
	"Latn",
}

m["bfn"] = {
	"Bunak",
	35101,
	"ngf",
	"Latn",
}

m["bfo"] = {
	"Malba Birifor",
	11150710,
	"nic-mre",
	"Latn",
}

m["bfp"] = {
	"Beba",
	35050,
	"nic-nge",
	"Latn",
}

m["bfq"] = {
	"tiếng Badaga",
	33205,
	"dra-kan",
	"Knda, Mlym",
	"Tiếng Badaga",
	"Badaga",
	translit = {
		Knda = "kn-translit",
		Mlym = "ml-translit",
	},
}

m["bfr"] = {
	"Bazigar",
	8829558,
	"inc",
}

m["bfs"] = {
	"tiếng Bạch Nam",
	12952250,
	"sit-bai",
	"Hani, Latn",
	"Tiếng Bạch Nam",
	"Bạch Nam",
	sort_key = {Hani = "Hani-sortkey"},
}

m["bft"] = {
	"tiếng Balti",
	33086,
	"sit-lab",
	"fa-Arab, Deva, Tibt",
	"Tiếng Balti",
	"Balti",
	translit = {
		Tibt = "Tibt-translit",
	},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["bfu"] = {
	"tiếng Gahri",
	5516952,
	"sit-whm",
	"Takr, Tibt, Deva",
	"Tiếng Gahri",
	"Gahri",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["bfw"] = {
	"tiếng Bondo",
	2567942,
	"mun",
	"Orya",
	"Tiếng Bondo",
	"Bondo"
}

m["bfx"] = {
	"tiếng Bantayanon",
	16837866,
	"phi",
	"Latn",
	"Tiếng Bantayanon",
	"Bantayanon",
}

m["bfy"] = {
	"Bagheli",
	2356364,
	"inc-hie",
	"Deva",
	translit = "hi-translit",
}

m["bfz"] = {
	"tiếng Pahari Mahasu",
	6733460,
	"him",
	"Deva, Takr",
	"Tiếng Pahari Mahasu",
	"Pahari Mahasu",
	translit = { Deva = "hi-translit" },
}

m["bga"] = {
	"Gwamhi-Wuri",
	6707102,
	"nic-knn",
	"Latn",
}

m["bgb"] = {
	"Bobongko",
	4935896,
	"poz-slb",
	"Latn",
}

m["bgc"] = {
	"tiếng Haryanvi",
	33410,
	"inc-hiw",
	"Deva",
	"Tiếng Haryanvi",
	"Haryanvi",
	ancestors = "inc-ohi",
	translit = "hi-translit",
}

m["bgd"] = {
	"Rathwi Bareli",
	7295692,
	"inc-bhi",
	"Deva",
}

m["bge"] = {
	"Bauria",
	4873579,
	"inc-bhi",
	"Deva",
}

m["bgf"] = {
	"Bangandu",
	34938,
	"alv-gbs",
	"Latn",
}

m["bgg"] = {
	"Bugun",
	3514220,
	"sit-khb",
	"Latn",
}

m["bgi"] = {
	"Giangan",
	4842057,
	"phi",
	"Latn",
}

m["bgj"] = {
	"tiếng Bangolan",
	34862,
	"nic-nun",
	"Latn",
	"Tiếng Bangolan",
	"Bangolan",
}

m["bgk"] = {
	"tiếng Bit",
	2904868,
	"mkh-pal",
	"Latn", -- also Hani?
	"Tiếng Bit",
	"Bit"
}

m["bgl"] = {
	"Bo",
	8845514,
	"mkh-vie",
}

m["bgo"] = {
	"Baga Koga",
	35695,
	"alv-bag",
	"Latn",
}

m["bgq"] = {
	"Bagri",
	2426319,
	"inc-wes",
	"Deva",
	ancestors = "raj",
}

m["bgr"] = {
	"Bawm Chin",
	56765,
	"tbq-kuk",
	"Latn",
}

m["bgs"] = {
	"Tagabawa",
	7675121,
	"mno",
	"Latn",
}

m["bgt"] = {
	"tiếng Bughotu",
	2927723,
	"poz-sls",
	"Latn",
	"Tiếng Bughotu",
	"Bughotu",
}

m["bgu"] = {
	"Mbongno",
	36141,
	"nic-mmb",
	"Latn",
}

m["bgv"] = {
	"Warkay-Bipim",
	4915439,
	"ngf",
	"Latn",
}

m["bgw"] = {
	"tiếng Bhatri",
	8841054,
	"inc-eas",
	"Deva, Orya",
	"Tiếng Bhatri",
	"Bhatri",
	translit = { Orya = "or-translit" },
}

m["bgx"] = {
	"tiếng Thổ Nhĩ Kỳ Gagauz Balkan",
	2360396,
	"trk-ogz",
	"Latn",
	"Tiếng Thổ Nhĩ Kỳ Gagauz Balkan",
	"Thổ Nhĩ Kỳ Gagauz Balkan",
	ancestors = "trk-oat",
}

m["bgy"] = {
	"Benggoi",
	4887742,
	"poz-cma",
	"Latn",
}

m["bgz"] = {
	"tiếng Banggai",
	3441692,
	"poz-slb",
	"Latn",
	"Tiếng Banggai",
	"Banggai",
}

m["bha"] = {
	"Bharia",
	4901287,
	"inc",
	"Deva",
}

m["bhb"] = {
	"tiếng Bhil",
	33229,
	"inc-bhi",
	"Deva",
	"Tiếng Bhil",
	"Bhil",
}

m["bhc"] = {
	"Biga",
	2902375,
	"poz-hce",
	"Latn",
}

m["bhd"] = {
	"tiếng Bhadrawah",
	4900565,
	"him",
	"Arab, Deva, Takr",
	"Tiếng Bhadrawah",
	"Bhadrawah",
	translit = {Deva = "hi-translit"},
}

m["bhe"] = {
	"Bhaya",
	8841168,
	"inc-wes",
	ancestors = "raj",
}

m["bhf"] = {
	"Odiai",
	56690,
	"paa-kwm",
	"Latn",
}

m["bhg"] = {
	"Binandere",
	3503802,
	"ngf",
	"Latn",
}

m["bhh"] = {
	"tiếng Bukhara",
	56469,
	"ira-swi",
	"Cyrl, Hebr, Latn, fa-Arab",
	"Tiếng Bukhara",
	"Bukhara",
	ancestors = "tg",
}

m["bhi"] = {
	"Bhilali",
	4901729,
	"inc-bhi",
	"Deva",
}

m["bhj"] = {
	"tiếng Bahing",
	56442,
	"sit-kiw",
	"Deva, Latn",
	"Tiếng Bahing",
	"Bahing",
}

m["bhl"] = {
	"Bimin",
	4913743,
	"ngf-okk",
	"Latn",
}

m["bhm"] = {
	"Bathari",
	2586893,
	"sem-sar",
	"Arab, Latn",
}

m["bhn"] = {
	"tiếng Tân Aram Bohtan",
	33230,
	"sem-nna",
	"Syrc",
	"Tiếng Tân Aram Bohtan",
	"Tân Aram Bohtan",
}

m["bho"] = {
	"tiếng Bhojpur",
	33268,
	"inc-eas",
	"Deva, Kthi",
	"Tiếng Bhojpur",
	"Bhojpur",
	ancestors = "bh",
	translit = {
		Deva = "bho-translit",
		Kthi = "bho-Kthi-translit",
	},
}

m["bhp"] = {
	"tiếng Bima",
	2796873,
	"poz-cet",
	"Latn",
	"Tiếng Bima",
	"Bima",
}

m["bhq"] = {
	"tiếng Tukang Besi Nam",
	12643975,
	"poz-mun",
	"Latn",
	"Tiếng Tukang Besi Nam",
	"Tukang Besi Nam"
}

m["bhs"] = {
	"Buwal",
	3515065,
	"cdc-cbm",
	"Latn",
}

m["bht"] = {
	"tiếng Bhattiyat",
	4901452,
	"him",
	"Deva, Takr",
	"Tiếng Bhattiyat",
	"Bhattiyat",
}

m["bhu"] = {
	"tiếng Bhunjia",
	8841766,
	"inc-eas",
	"Deva, Orya",
	"Tiếng Bhunjia",
	"Bhunjia",
}

m["bhv"] = {
	"Bahau",
	3502039,
	"poz",
	"Latn",
}

m["bhw"] = {
	"Biak",
	1961488,
	"poz-hce",
	"Latn",
}

m["bhx"] = { -- spurious?
	"Bhalay",
	8840773,
	"inc",
}

m["bhy"] = {
	"Bhele",
	4901671,
	"bnt-kbi",
	"Latn",
}

m["bhz"] = {
	"Bada",
	4840520,
	"poz-kal",
	"Latn",
}

m["bia"] = {
	"Badimaya",
	3442745,
	"aus-psw",
	"Latn",
}

m["bib"] = {
	"tiếng Bissa",
	32934,
	"dmn-bbu",
	"Latn",
	"Tiếng Bissa",
	"Bissa",
}

m["bic"] = {
	"Bikaru",
	56342,
	"paa-eng",
	"Latn",
}

m["bid"] = {
	"Bidiyo",
	56258,
	"cdc-est",
	"Latn",
}

m["bie"] = {
	"Bepour",
	4890914,
	"ngf-mad",
	"Latn",
}

m["bif"] = {
	"Biafada",
	35099,
	"alv-ten",
	"Latn",
}

m["big"] = {
	"Biangai",
	8842027,
	"paa",
	"Latn",
}

m["bij"] = {
	"Kwanka",
	35598,
	"nic-tar",
	"Latn",
}

m["bil"] = {
	"Bile",
	34987,
	"nic-jrn",
	"Latn",
}

m["bim"] = {
	"Bimoba",
	34971,
	"nic-grm",
	"Latn",
}

m["bin"] = {
	"tiếng Edo",
	35375,
	"alv-eeo",
	"Latn",
	"Tiếng Edo",
	"Edo",
	entry_name = {remove_diacritics = c.acute .. c.grave .. c.macron .. c.dgrave},
	sort_key = {
		from = {"ẹ", "gb", "gh", "kh", "kp", "mw", "nw", "ny", "ọ", "rh", "rr", "vb"},
		to = {"e" .. p[1], "g" .. p[1], "g" .. p[2], "k" .. p[1], "k" .. p[2], "m" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "r" .. p[1], "r" .. p[1], "v" .. p[1]}
	},
}

m["bio"] = {
	"Nai",
	3508074,
	"paa-kwm",
	"Latn",
}

m["bip"] = {
	"Bila",
	2902626,
	"bnt-kbi",
	"Latn",
}

m["biq"] = {
	"Bipi",
	2904312,
	"poz-aay",
	"Latn",
}

m["bir"] = {
	"Bisorio",
	8844749,
	"paa-eng",
	"Latn",
}

m["bit"] = {
	"Berinomo",
	56447,
	"paa-spk",
	"Latn",
}

m["biu"] = {
	"Biete",
	4904687,
	"tbq-kuk",
	"Latn",
}

m["biv"] = {
	"Southern Birifor",
	32859745,
	"nic-mre",
	"Latn",
}

m["biw"] = {
	"Kol (Cameroon)",
	35582,
	"bnt-mka",
	"Latn",
}

m["bix"] = {
	"tiếng Birjia",
	3450686,
	"mun",
	"Deva",
	"Tiếng Birjia",
	"Birjia",
	translit = { Deva = "hi-translit" },
}

m["biy"] = {
	"tiếng Birhor",
	3450469,
	"mun",
	"Deva",
	"Tiếng Birhor",
	"Birhor",
	translit = { Deva = "hi-translit" },
}

m["biz"] = {
	"Baloi",
	3450590,
	"bnt-ngn",
	"Latn",
}

m["bja"] = {
	"Budza",
	3046889,
	"bnt-bun",
	"Latn",
}

m["bjb"] = {
	"Barngarla",
	3439071,
	"aus-pam",
	"Latn",
}

m["bjc"] = {
	"Bariji",
	4690919,
	"ngf",
	"Latn",
}

m["bje"] = {
	"Biao-Jiao Mien",
	3503800,
	"hmx-mie",
	"Hani, Latn",
	sort_key = {Hani = "Hani-sortkey"},
}

m["bjf"] = {
	"tiếng Tân Aram Do Thái Barzani",
	33234,
	"sem-nna",
	"Hebr", -- maybe others
	"Tiếng Tân Aram Do Thái Barzani",
	"Tân Aram Do Thái Barzani",
}

m["bjg"] = {
	"Bidyogo",
	35365,
	"alv-bak",
	"Latn",
}

m["bjh"] = {
	"Bahinemo",
	56361,
	"paa-spk",
	"Latn",
}

m["bji"] = {
	"tiếng Burji",
	34999,
	"cus-hec",
	"Latn, Ethi",
	"Tiếng Burji",
	"Burji",
}

m["bjj"] = {
	"tiếng Kannauj",
	2726867,
	"inc-hiw",
	"Deva",
	"Tiếng Kannauj",
	"Kannauj",
	ancestors = "inc-ohi",
}

m["bjk"] = {
	"Barok",
	2884743,
	"poz-ocw",
	"Latn",
}

m["bjl"] = {
	"Bulu (New Guinea)",
	4997162,
	"poz-ocw",
	"Latn",
}

m["bjm"] = {
	"Bajelani",
	4848866,
	"ira-zgr",
	"Latn, Arab",
	ancestors = "hac",
}

m["bjn"] = {
	"tiếng Banjar",
	33151,
	"poz-mly",
	"Latn, Arab",
	"Tiếng Banjar",
	"Banjar",
}

m["bjo"] = {
	"Mid-Southern Banda",
	42303990,
	"bad-cnt",
	"Latn",
}

m["bjp"] = {
	"Fanamaket",
	nil,
	"poz-oce",
	"Latn",
}

m["bjr"] = {
	"Binumarien",
	538364,
	"paa-kag",
	"Latn",
}

m["bjs"] = {
	"Bajan",
	2524014,
	"crp",
	"Latn",
	ancestors = "en",
}

m["bjt"] = {
	"tiếng Balanta-Ganja",
	19359034,
	"alv-bak",
	"Arab, Latn",
	"Tiếng Balanta-Ganja",
	"Balanta-Ganja",
}

m["bju"] = {
	"Busuu",
	35046,
	"nic-fru",
	"Latn",
}

m["bjv"] = {
	"tiếng Bedjond",
	8829831,
	"csu-sar",
	"Latn",
	"Tiếng Bedjond",
	"Bedjond",
}

m["bjw"] = {
	"Bakwé",
	34899,
	"kro-ekr",
	"Latn",
}

m["bjx"] = {
	"Banao Itneg",
	12627559,
	"phi",
	"Latn",
}

m["bjy"] = {
	"Bayali",
	4874263,
	"aus-pam",
	"Latn",
}

m["bjz"] = {
	"Baruga",
	2886189,
	"ngf",
	"Latn",
}

m["bka"] = {
	"Kyak",
	35653,
	"alv-bwj",
	"Latn",
}

m["bkc"] = {
	"Baka",
	34905,
	"nic-nkb",
	"Latn",
}

m["bkd"] = {
	"tiếng Binukid",
	4914553,
	"mno",
	"Latn",
	"Tiếng Binukid",
	"Binukid",
}

m["bkf"] = {
	"Beeke",
	3441375,
	"bnt-kbi",
	"Latn",
}

m["bkg"] = {
	"Buraka",
	35066,
	"nic-nkg",
	"Latn",
}

m["bkh"] = {
	"Bakoko",
	34866,
	"bnt-bsa",
	"Latn",
}

m["bki"] = {
	"tiếng Baki",
	11024697,
	"poz-vnc",
	"Latn",
	"Tiếng Baki",
	"Baki",
}

m["bkj"] = {
	"Pande",
	36263,
	"bnt-ngn",
	"Latn",
}

m["bkk"] = { -- written in Balti script
	"Brokskat",
	2925988,
	"inc-shn",
}

m["bkl"] = {
	"tiếng Berik",
	378743,
	"paa-tkw",
	"Latn",
	"Tiếng Berik",
	"Berik",
}

m["bkm"] = {
	"tiếng Itaŋikom",
	1656595,
	"nic-rnc",
	"Latn",
	"Tiếng Itaŋikom",
	"Itaŋikom",
}

m["bkn"] = {
	"Bukitan",
	3446774,
	"poz-bnn",
	"Latn",
}

m["bko"] = {
	"Kwa'",
	35567,
	"bai",
	"Latn",
}

m["bkp"] = {
	"Iboko",
	35089,
	"bnt-ngn",
	"Latn",
}

m["bkq"] = {
	"Bakairí",
	56846,
	"sai-pek",
	"Latn",
}

m["bkr"] = {
	"tiếng Bakumpai",
	3436626,
	"poz-brw",
	"Latn",
}

m["bks"] = {
	"Masbate Sorsogon",
	16113356,
	"phi",
	"Latn",
}

m["bkt"] = {
	"tiếng Boloki",
	4144560,
	"bnt-zbi",
	"Latn",
	ancestors = "lse",
}

m["bku"] = {
	"tiếng Buhid",
	1002956,
	"phi",
	"Latn, Buhd",
	"Tiếng Buhid",
	"Buhid",
	translit = {
		Buhd = "bku-translit",
	},
	override_translit = true,
	entry_name = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.circ,
		}
	},
    sort_key = {
		Latn = "tl-sortkey",
	},
	standardChars = { 
		Latn = "AaBbKkDdEeFfGgHhIiLlMmNnOoPpRrSsTtUuWwYy" .. c.punc,
	},
}

m["bkv"] = {
	"Bekwarra",
	34954,
	"nic-ben",
	"Latn",
}

m["bkw"] = {
	"Bekwel",
	34950,
	"bnt-bek",
	"Latn",
}

m["bkx"] = {
	"Baikeno",
	11200640,
	"poz-tim",
	"Latn",
}

m["bky"] = {
	"Bokyi",
	35087,
	"nic-ben",
	"Latn",
}

m["bkz"] = {
	"tiếng Bungku",
	2928207,
	"poz-btk",
	"Latn",
	"Tiếng Bungku",
	"Bungku"
}

m["bla"] = {
	"tiếng Blackfoot",
	33060,
	"alg",
	"Latn, Cans",
	"Tiếng Blackfoot",
	"Blackfoot",
}

m["blb"] = {
	"tiếng Bilua",
	35003,
	"ngf",
	"Latn",
	"Tiếng Bilua",
	"Bilua",
}

m["blc"] = {
	"tiếng Bella Coola",
	977808,
	"sal",
	"Latn",
	"Tiếng Bella Coola",
	"Bella Coola",
}

m["bld"] = {
	"Bolango",
	3450578,
	"phi",
	"Latn",
}

m["ble"] = {
	"tiếng Balanta-Kentohe",
	56789,
	"alv-bak",
	"Latn",
	"Tiếng Balanta-Kentohe",
	"Balanta-Kentohe",
}

m["blf"] = {
	"Buol",
	2928278,
	"phi",
	"Latn",
}

m["blg"] = {
	"Balau",
	4850134,
	"poz-mly",
	"Latn",
}

m["blh"] = {
	"tiếng Kuwaa",
	35579,
	"kro",
	"Latn",
	"Tiếng Kuwaa",
	"Kuwaa",
}

m["bli"] = {
	"Bolia",
	34910,
	"bnt-mon",
	"Latn",
}

m["blj"] = {
	"Bolongan",
	9229310,
	"poz",
	"Latn",
}

m["blk"] = {
	"tiếng Pa'O",
	7121294,
	"kar",
	"Mymr",
	"Tiếng Pa'O",
	"Pa'O",
}

m["bll"] = {
	"Biloxi",
	2903780,
	"sio-ohv",
	"Latn",
}

m["blm"] = {
	"tiếng Beli",
	56821,
	"csu-bbk",
	"Latn",
	"Tiếng Beli",
	"Beli",
}

m["bln"] = {
	"Southern Catanduanes Bicolano",
	7569754,
	"phi",
	"Latn",
}

m["blo"] = {
	"tiếng Anii",
	34838,
	"alv-ntg",
	"Latn",
	"Tiếng Anii",
	"Anii",
}

m["blp"] = {
	"Blablanga",
	2905245,
	"poz-ocw",
	"Latn",
}

m["blq"] = {
	"Baluan-Pam",
	2881675,
	"poz-aay",
	"Latn",
}

m["blr"] = {
	"tiếng Blang",
	4925096,
	"mkh-pal",
	"Latn, Tale, Lana, Thai",
	"Tiếng Blang",
	"Blang",
	sort_key = { -- FIXME: This needs to be converted into the current standardized format.
		from = {"[%pᪧๆ]", "[᩠ᩳ-᩿]", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to = {"", "", "ᩈᩈ", "ᩁ", "ᩃ", "ᨦ", "%1ᨮ", "%1ᨻ", "ᩣ", "", "%2%1"}
	},
}

m["bls"] = {
	"Balaesang",
	4849796,
	"poz",
	"Latn",
}

m["blt"] = {
	"tiếng Thái Đen",
	56407,
	"tai-swe",
	"Tavt, Latn",
	"Tiếng Thái Đen",
	"Thái Đen",
	--translit = "Tavt-translit",
	sort_key = {
		Tavt = {
			from = {"[꪿ꫀ꫁ꫂ]", "([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])"},
			to = {"", "%2%1"}
		},
	},
}

m["blv"] = {
	"Kibala",
	4939959,
	"bnt-kmb",
	"Latn",
}

m["blw"] = {
	"Balangao",
	4850033,
	"phi",
	"Latn",
}

m["blx"] = {
	"Mag-Indi Ayta",
	1931221,
	"phi",
	"Latn",
}

m["bly"] = {
	"Notre",
	11009194,
	"nic-wov",
	"Latn",
}

m["blz"] = {
	"tiếng Balantak",
	4850053,
	"poz-slb",
	"Latn",
	"Tiếng Balantak",
	"Balantak",
}

m["bma"] = {
	"Lame",
	3913997,
	"nic-jrn",
	"Latn",
}

m["bmb"] = {
	"Bembe",
	4885023,
	"bnt-lgb",
	"Latn",
}


m["bmc"] = {
	"Biem",
	4904523,
	"poz-ocw",
	"Latn",
}

m["bmd"] = {
	"Baga Manduri",
	35815,
	"alv-bag",
	"Latn",
}

m["bme"] = {
	"Limassa",
	11004666,
	"nic-nkb",
	"Latn",
}

m["bmf"] = {
	"Bom",
	35088,
	"alv-mel",
	"Latn",
}

m["bmg"] = {
	"Bamwe",
	34867,
	"bnt-bun",
	"Latn",
}

m["bmh"] = {
	"Kein",
	6383764,
	"ngf-mad",
	"Latn",
}

m["bmi"] = {
	"Bagirmi",
	34903,
	"csu-bgr",
	"Latn",
}

m["bmj"] = {
	"Bote-Majhi",
	9229570,
	"inc-eas",
	"Deva",
	ancestors = "bh",
}

m["bmk"] = {
	"Ghayavi",
	5555976,
	"poz-ocw",
	"Latn",
}

m["bml"] = {
	"Bomboli",
	35055,
	"bnt-ngn",
	"Latn",
}

m["bmn"] = {
	"Bina",
	8843664,
	"poz-ocw",
	"Latn",
}

m["bmo"] = {
	"Bambalang",
	34868,
	"nic-nun",
	"Latn",
}

m["bmp"] = {
	"Bulgebi",
	4996380,
	"ngf-fin",
	"Latn",
}

m["bmq"] = {
	"tiếng Bomu",
	35065,
	"nic-bwa",
	"Latn",
	"Tiếng Bomu",
	"Bomu",
}

m["bmr"] = {
	"Muinane",
	3027894,
	"sai-bor",
	"Latn",
}

m["bmt"] = {
	"Biao Mon",
	8842159,
	"hmx-mie",
}

m["bmu"] = {
	"Somba-Siawari",
	5000983,
	"ngf",
	"Latn",
}

m["bmv"] = {
	"tiếng Bum",
	35058,
	"nic-rnc",
	"Latn",
	"Tiếng Bum",
	"Bum",
}

m["bmw"] = {
	"Bomwali",
	34984,
	"bnt-ndb",
	"Latn",
}

m["bmx"] = {
	"Baimak",
	3450546,
	"ngf-mad",
	"Latn",
}

m["bmz"] = {
	"Baramu",
	4858315,
	"ngf",
	"Latn",
}

m["bna"] = {
	"Bonerate",
	4941729,
	"poz-mun",
	"Latn",
}

m["bnb"] = {
	"Bookan",
	4943150,
	"poz-san",
	"Latn",
}

m["bnd"] = {
	"Banda",
	3504147,
	"poz-cma",
	"Latn",
}

m["bne"] = {
	"Bintauna",
	4914533,
	"phi",
	"Latn",
}

m["bnf"] = {
	"Masiwang",
	6783305,
	"poz-cma",
	"Latn",
}

m["bng"] = {
	"Benga",
	34952,
	"bnt-saw",
	"Latn",
}

m["bni"] = {
	"tiếng Bangi",
	34936,
	"bnt-bmo",
	"Latn",
	"Tiếng Bangi",
	"Bangi",
}

m["bnj"] = {
	"Eastern Tawbuid",
	18757427,
	"phi",
	"Latn",
}

m["bnk"] = {
	"Bierebo",
	2902029,
	"poz-vnc",
	"Latn",
}

m["bnl"] = {
	"tiếng Boon",
	56616,
	"cus-eas",
	"Latn",
	"Tiếng Boon",
	"Boon",
}

m["bnm"] = {
	"Batanga",
	34979,
	"bnt-saw",
	"Latn",
}

m["bnn"] = {
	"tiếng Bunun",
	56505,
	"map",
	"Latn",
	"Tiếng Bunun",
	"Bunun",
}

m["bno"] = {
	"tiếng Asi",
	29490,
	"phi",
	"Latn",
	"Tiếng Asi",
	"Asi",
}

m["bnp"] = {
	"tiếng Bola",
	4938876,
	"poz-ocw",
	"Latn",
	"Tiếng Bola",
	"Bola",
}

m["bnq"] = {
	"Bantik",
	2883521,
	"poz",
	"Latn",
}

m["bnr"] = {
	"Butmas-Tur",
	2928942,
	"poz-vnc",
	"Latn",
}

m["bns"] = {
	"Bundeli",
	56399,
	"inc-hiw",
	"Deva",
	ancestors = "inc-ohi",
	translit = "hi-translit",
}

m["bnu"] = {
	"Bentong",
	4890644,
	"poz-ssw",
	"Latn",
}

m["bnv"] = {
	"Beneraf",
	4941733,
	"paa-tkw",
	"Latn",
}

m["bnw"] = {
	"Bisis",
	56356,
	"paa-spk",
	"Latn",
}

m["bnx"] = {
	"Bangubangu",
	3438330,
	"bnt-lbn",
	"Latn",
}

m["bny"] = {
	"Bintulu",
	3450775,
	"poz-swa",
	"Latn",
}

m["bnz"] = {
	"Beezen",
	35083,
	"nic-ykb",
	"Latn",
}

m["boa"] = {
	"tiếng Bora",
	2375468,
	"sai-bor",
	"Latn",
	"Tiếng Bora",
	"Bora",
}

m["bob"] = {
	"tiếng Aweer",
	56526,
	"cus-som",
	"Latn",
	"Tiếng Aweer",
	"Aweer",
}

m["boe"] = {
	"tiếng Mundabli",
	36127,
	"nic-beb",
	"Latn",
	"Tiếng Mundabli",
	"Mundabli",
}

m["bof"] = {
	"Bolon",
	3913301,
	"dmn-emn",
	"Latn",
}

m["bog"] = {
	"Bamako Sign Language",
	4853284,
	"sgn",
}

m["boh"] = {
	"North Boma",
	35080,
	"bnt-bdz",
	"Latn",
}

m["boi"] = {
	"Barbareño",
	56391,
	"nai-chu",
	"Latn",
}

m["boj"] = {
	"Anjam",
	3504136,
	"ngf-mad",
	"Latn",
}

m["bok"] = {
	"Bonjo",
	34942,
	"alv",
	"Latn",
}

m["bol"] = {
	"Bole",
	3436680,
	"cdc-wst",
	"Latn",
}

m["bom"] = {
	"Berom",
	35013,
	"nic-beo",
	"Latn",
}

m["bon"] = {
	"Bine",
	4914077,
	"paa",
	"Latn",
}

m["boo"] = {
	"Tiemacèwè Bozo",
	12643582,
	"dmn-snb",
	"Latn", -- and others?
}

m["bop"] = {
	"Bonkiman",
	4942134,
	"ngf-fin",
	"Latn",
}

m["boq"] = {
	"Bogaya",
	7207578,
	"ngf",
	"Latn",
}

m["bor"] = {
	"tiếng Borôro",
	32986,
	"sai-mje",
	"Latn",
	"Tiếng Borôro",
	"Borôro",
}

m["bot"] = {
	"Bongo",
	2910067,
	"csu-bbk",
	"Latn",
}

m["bou"] = {
	"Bondei",
	4941378,
	"bnt-seu",
	"Latn",
}

m["bov"] = {
	"tiếng Tuwuli",
	36974,
	"alv-ktg",
	"Latn",
	"Tiếng Tuwuli",
	"Tuwuli",
}

m["bow"] = {
	"Rema",
	7311502,
	"paa",
	"Latn",
}

m["box"] = {
	"Buamu",
	35157,
	"nic-bwa",
	"Latn",
}

m["boy"] = {
	"Bodo (Central Africa)",
	4936715,
	"bnt-leb",
	"Latn",
}

m["boz"] = {
	"Tiéyaxo Bozo",
	32860401,
	"dmn-snb",
	"Latn",
}

m["bpa"] = {
	"Dakaka",
	1157729,
	"poz-vnc",
	"Latn",
}

m["bpd"] = {
	"Banda-Banda",
	3450674,
	"bad-cnt",
	"Latn",
}

m["bpg"] = {
	"Bonggo",
	4941860,
	"poz-ocw",
	"Latn",
}

m["bph"] = {
	"tiếng Botlikh",
	56560,
	"cau-and",
	"Cyrl",
	"Tiếng Botlikh",
	"Botlikh",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["bpi"] = {
	"Bagupi",
	3450697,
	"ngf-mad",
	"Latn",
}

m["bpj"] = {
	"Binji",
	4914403,
	"bnt-lbn",
	"Latn",
}

m["bpk"] = {
	"Orowe",
	7103905,
	"poz-cln",
	"Latn",
}

m["bpl"] = {
	"Broome Pearling Lugger Pidgin",
	4975277,
	"crp",
	"Latn",
	ancestors = "ms",
}

m["bpm"] = {
	"Biyom",
	4919327,
	"ngf-mad",
	"Latn",
}

m["bpn"] = {
	"Dzao Min",
	3042189,
	"hmx-mie",
}

m["bpo"] = {
	"Anasi",
	11207813,
	"paa-egb",
	"Latn",
}

m["bpp"] = {
	"Kaure",
	20526532,
	"paa",
	"Latn",
}

m["bpq"] = {
	"Banda Malay",
	12473442,
	"crp",
	"Latn",
	ancestors = "ms",
}

m["bpr"] = {
	"Koronadal Blaan",
	16115430,
	"phi",
	"Latn",
}

m["bps"] = {
	"Sarangani Blaan",
	16117272,
	"phi",
	"Latn",
}

m["bpt"] = {
	"Barrow Point",
	2567916,
	"aus-pmn",
	"Latn",
}

m["bpu"] = {
	"Bongu",
	4941930,
	"ngf-mad",
	"Latn",
}

m["bpv"] = {
	"Bian Marind",
	8841889,
	"ngf",
	"Latn",
}

m["bpx"] = {
	"Palya Bareli",
	7128872,
	"inc-bhi",
	"Deva",
	translit = "hi-translit",
}

m["bpy"] = {
	"tiếng Bishnupriya",
	37059,
	"inc-eas",
	"Beng",
	"Tiếng Bishnupriya",
	"Bishnupriya",
	ancestors = "inc-obn",
}

m["bpz"] = {
	"Bilba",
	8843362,
	"poz-tim",
	"Latn",
}

m["bqa"] = {
	"Tchumbuli",
	11008162,
	"alv-ctn",
	"Latn",
	ancestors = "ak",
}

m["bqb"] = {
	"Bagusa",
	4842178,
	"paa-tkw",
	"Latn",
}

m["bqc"] = {
	"tiếng Boko",
	34983,
	"dmn-bbu",
	"Latn",
	"Tiếng Boko",
	"Boko",
}

m["bqd"] = {
	"Bung",
	3436612,
	"nic-bdn",
	"Latn",
}

m["bqf"] = {
	"Baga Kaloum",
	3502293,
	"alv-bag",
	"Latn",
}

m["bqg"] = {
	"Bago-Kusuntu",
	34878,
	"nic-gne",
}

m["bqh"] = {
	"Baima",
	674990,
	"sit-qia",
}

m["bqi"] = {
	"tiếng Bakhtiari",
	257829,
	"ira-swi",
	"fa-Arab",
	"Tiếng Bakhtiari",
	"Bakhtiari",
	ancestors = "pal",
}

m["bqj"] = {
	"Bandial",
	34872,
	"alv-jol",
	"Latn",
}

m["bqk"] = {
	"Banda-Mbrès",
	3450724,
	"bad-cnt",
	"Latn",
}

m["bql"] = {
	"Bilakura",
	4907504,
	"ngf-mad",
	"Latn",
}

m["bqm"] = {
	"Wumboko",
	37051,
	"bnt-kpw",
	"Latn",
}

m["bqn"] = {
	"Bulgarian Sign Language",
	3438325,
	"sgn",
}

m["bqo"] = {
	"Balo",
	34865,
	"nic-grs",
	"Latn",
}

m["bqp"] = {
	"tiếng Busa",
	35185,
	"dmn-bbu",
	"Latn",
	"Tiếng Busa",
	"Busa",
}

m["bqq"] = {
	"Biritai",
	56382,
	"paa-lkp",
	"Latn",
}

m["bqr"] = {
	"Burusu",
	5001028,
	"poz-san",
	"Latn",
}

m["bqs"] = {
	"Bosngun",
	56838,
	"paa",
	"Latn",
}

m["bqt"] = {
	"Bamukumbit",
	35078,
	"nic-nge",
	"Latn",
}

m["bqu"] = {
	"Boguru",
	3438444,
	"bnt-boa",
	"Latn",
}

m["bqv"] = {
	"Begbere-Ejar",
	7194098,
	"nic-plc",
	"Latn",
}

m["bqw"] = {
	"Buru (Nigeria)",
	1017152,
	"nic-bds",
	"Latn",
}

m["bqx"] = {
	"Baangi",
	3450648,
	"nic-kam",
	"Latn",
}

m["bqy"] = {
	"Bengkala Sign Language",
	3322119,
	"sgn",
}

m["bqz"] = {
	"tiếng Bakaka",
	34855,
	"bnt-mne",
	"Latn",
	"Tiếng Bakaka",
	"Bakaka",
}

m["bra"] = {
	"tiếng Braj",
	35243,
	"inc-hiw",
	"Deva",
	"Tiếng Braj",
	"Braj",
	ancestors = "inc-ohi",
	translit = "hi-translit",
}


m["brb"] = {
	"tiếng Brâu",
	4957737,
	"mkh-ban",
	"Khmr, Latn",
	"Tiếng Brâu",
	"Brâu"
}

m["brc"] = {
	"tiếng Creole Hà Lan Berbice",
	35215,
	"crp",
	"Latn",
	"Tiếng Creole Hà Lan Berbice",
	"Creole Hà Lan Berbice",
	ancestors = "nl",
}

m["brd"] = {
	"Baraamu",
	56804,
	"sit-new",
	"Deva",
}

m["brf"] = {
	"Bera",
	2896850,
	"bnt-kbi",
	"Latn",
}

m["brg"] = {
	"Baure",
	2839722,
	"awd",
	"Latn",
}

m["brh"] = {
	"tiếng Brahui",
	33202,
	"dra-nor",
	"ur-Arab, Latn",
	"Tiếng Brahui",
	"Brahui",
	translit = {["ur-Arab"] = "ur-translit"},
	entry_name = {
		-- character "ۂ" code U+06C2 to "ه" and "هٔ"‎ (U+0647 + U+0654) to "ه"; hamzatu l-waṣli to a regular alif
		from = {"هٔ", "ۂ", "ٱ"},
		to = {"ہ", "ہ", "ا"},
		remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna .. c.superalef
	},
}

m["bri"] = {
	"Mokpwe",
	36428,
	"bnt-kpw",
	"Latn",
}

m["brj"] = {
	"Bieria",
	4904607,
	"poz-vnc",
	"Latn",
}

m["brk"] = {
	"Birgid",
	56823,
	"nub",
	"Latn",
}

m["brl"] = {
	"Birwa",
	3501019,
	"bnt-sts",
	"Latn",
}

m["brm"] = {
	"Barambu",
	34893,
	"znd",
	"Latn",
}

m["brn"] = {
	"Boruca",
	4946773,
	"cba",
	"Latn",
}

m["bro"] = {
	"tiếng Brokkat",
	56605,
	"sit-tib",
	"Tibt, Latn",
	"Tiếng Brokkat",
	"Brokkat",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["brp"] = {
	"Barapasi",
	56995,
	"paa-egb",
	"Latn",
}

m["brq"] = {
	"tiếng Breri",
	4961835,
	"paa",
	"Latn",
	"Tiếng Breri",
	"Breri",
}

m["brr"] = {
	"tiếng Birao",
	2904383,
	"poz-sls",
	"Latn",
	"Tiếng Birao",
	"Birao",
}

m["brs"] = {
	"Baras",
	8827053,
	"poz",
	"Latn",
}

m["brt"] = {
	"Bitare",
	34946,
	"nic-tvn",
	"Latn",
}

m["bru"] = {
	"tiếng Bru",
	16115463,
	"mkh-kat",
	"Latn, Laoo, Thai",
	"Tiếng Bru",
	"Bru",
	sort_key = {
		Laoo = "Laoo-sortkey",
		Thai = "Thai-sortkey",
	},
}

m["brv"] = {
	"tiếng Bru Tây",
	16113806,
	"mkh-kat",
	"Latn, Laoo, Thai",
	"Tiếng Bru Tây",
	"Bru Tây",
	sort_key = {
		Laoo = "Laoo-sortkey",
		Thai = "Thai-sortkey",
	},
}

m["brw"] = {
	"tiếng Bellara",
	4883496,
	"dra-tlk",
	"Knda, Mlym",
	"Tiếng Bellara",
	"Bellara",
	translit = {
		Knda = "kn-translit",
		Mlym = "ml-translit",
	},
}

m["brx"] = {
	"tiếng Bodo (Ấn Độ)",
	33223,
	"tbq-bdg",
	"Deva, Latn, Beng",
	"Tiếng Bodo (Ấn Độ)",
	"Bodo (Ấn Độ)",
	translit = {Deva = "brx-translit"},
}

m["bry"] = {
	"Burui",
	5000976,
	"paa-spk",
	"Latn",
}

m["brz"] = {
	"Bilbil",
	4907473,
	"poz-ocw",
	"Latn",
}

m["bsa"] = {
	"tiếng Abinomn",
	56648,
	"qfa-iso",
	"Latn",
	"Tiếng Abinomn",
	"Abinomn",
}

m["bsb"] = {
	"Brunei Bisaya",
	3450611,
	"poz-san",
	"Latn",
}

m["bsc"] = {
	"tiếng Bassari",
	35098,
	"alv-ten",
	"Latn",
	"Tiếng Bassari",
	"Bassari",
}

m["bse"] = {
	"Wushi",
	36973,
	"nic-rnn",
	"Latn",
}

m["bsf"] = {
	"Bauchi",
	34974,
	"nic-shi",
	"Latn",
}

m["bsg"] = {
	"Bashkardi",
	33030,
	"ira-swi",
	"fa-Arab, Latn",
}

m["bsh"] = {
	"Kamkata-viri",
	2605045,
	"nur-nor",
	"Latn, Arab",
}

m["bsi"] = {
	"Bassossi",
	34940,
	"bnt-mne",
	"Latn",
}

m["bsj"] = {
	"Bangwinji",
	3446631,
	"alv-wjk",
	"Latn",
}

m["bsk"] = {
	"tiếng Burushaski",
	216286,
	"qfa-iso",
	"Arab",
	"Tiếng Burushaski",
	"Burushaski",
}

m["bsl"] = {
	"Basa-Gumna",
	4866150,
	"nic-bas",
	"Latn",
}

m["bsm"] = {
	"Busami",
	5001255,
	"poz-hce",
	"Latn",
}

m["bsn"] = {
	"Barasana",
	2883843,
	"sai-tuc",
	"Latn",
}

m["bso"] = {
	"Buso",
	3441370,
	"cdc-est",
	"Latn",
}

m["bsp"] = {
	"Baga Sitemu",
	36466,
	"alv-bag",
	"Latn",
}

m["bsq"] = {
	"tiếng Bassa",
	34949,
	"kro-wkr",
	"Latn, Bass",
	"Tiếng Bassa",
	"Bassa",
}

m["bsr"] = {
	"Bassa-Kontagora",
	4866152,
	"nic-bas",
	"Latn",
}

m["bss"] = {
	"tiếng Akoose",
	34806,
	"bnt-mne",
	"Latn",
	"Tiếng Akoose",
	"Akoose",
}

m["bst"] = {
	"tiếng Basketo",
	56531,
	"omv-ome",
	"Ethi",
	"Tiếng Basketo",
	"Basketo",
}

m["bsu"] = {
	"Bahonsuai",
	2879298,
	"poz-btk",
	"Latn",
}

m["bsv"] = {
	"Baga Sobané",
	3450433,
	"alv-bag",
	"Latn",
}

m["bsw"] = {
	"tiếng Baiso",
	56615,
	"cus-som",
	"Latn",
	"Tiếng Baiso",
	"Baiso",
}

m["bsx"] = {
	"Yangkam",
	36922,
	"nic-tar",
	"Latn",
}

m["bsy"] = {
	"tiếng Bisaya Sabah",
	12641557,
	"poz-san",
	"Latn",
	"Tiếng Bisaya Sabah",
	"Bisaya Sabah",
}

m["bta"] = {
	"Bata",
	56254,
	"cdc-cbm",
	"Latn",
}

m["btc"] = {
	"Bati (Cameroon)",
	34944,
	"nic-mbw",
	"Latn",
}

m["btd"] = {
	"Dairi Batak",
	2891045,
	"btk",
	"Latn, Batk",
}

m["bte"] = {
	"Gamo-Ningi",
	5520366,
	"nic-jer",
	"Latn",
}

m["btf"] = {
	"tiếng Birgit",
	56302,
	"cdc-est",
	"Latn",
	"Tiếng Birgit",
	"Birgit",
}

m["btg"] = {
	"Gagnoa Bété",
	11005602,
	"kro-bet",
	"Latn",
}

m["bth"] = {
	"tiếng Bidayuh Biatah",
	2900881,
	"day",
	"Latn",
	"Tiếng Bidayuh Biatah",
	"Bidayuh Biatah",
}

m["bti"] = {
	"Burate",
	56900,
	"paa-egb",
	"Latn",
}

m["btj"] = {
	"tiếng Mã Lai Bacan",
	8828608,
	"poz-mly",
	"Latn",
	"Tiếng Mã Lai Bacan",
	"Mã Lai Bacan",
}

m["btm"] = {
	"Mandailing Batak",
	2891049,
	"btk",
	"Latn, Batk",
}

m["btn"] = {
	"tiếng Ratagnon",
	13197,
	"phi",
	"Latn",
	"Tiếng Ratagnon",
	"Ratagnon",
}

m["bto"] = {
	"Iriga Bicolano",
	12633026,
	"phi",
	"Latn",
}

m["btp"] = {
	"Budibud",
	4985086,
	"poz-ocw",
	"Latn",
}

m["btq"] = {
	"tiếng Batek",
	860315,
	"mkh-asl",
	"Latn",
	"Tiếng Batek",
	"Batek"
}

m["btr"] = {
	"Baetora",
	2878874,
	"poz-vnc",
	"Latn",
}

m["bts"] = {
	"tiếng Batak Simalungun",
	2891054,
	"btk",
	"Latn, Batk",
	"Tiếng Batak Simalungun",
	"Batak Simalungun",
}

m["btt"] = {
	"Bete-Bendi",
	4887064,
	"nic-ben",
	"Latn",
}

m["btu"] = {
	"Batu",
	34964,
	"nic-tvn",
	"Latn",
}

m["btv"] = {
	"Bateri",
	3812564,
	"inc-koh",
	"Deva",
}

m["btw"] = {
	"tiếng Butuanon",
	5003156,
	"phi",
	"Latn",
	"Tiếng Butuanon",
	"Butuanon",
}

m["btx"] = {
	"Karo Batak",
	33012,
	"btk",
	"Latn, Batk",
}

m["bty"] = {
	"Bobot",
	3446788,
	"poz-cma",
	"Latn",
}

m["btz"] = {
	"Alas-Kluet Batak",
	2891042,
	"btk",
	"Latn, Batk",
}

m["bua"] = {
	"tiếng Buryat",
	33120,
	"xgn-cen",
	"Cyrl, Mong, Latn",
	"Tiếng Buryat",
	"Buryat",
	wikimedia_codes = "bxr",
	ancestors = "cmg",
	translit = {
		Cyrl = "bua-translit",
		Mong = "Mong-translit",
	},
	override_translit = true,
	display_text = {Mong = s["Mong-displaytext"]},
	entry_name = {
		Cyrl = {remove_diacritics = c.grave .. c.acute},
		Mong = s["Mong-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {"ё", "ө", "ү", "һ"},
			to = {"е" .. p[1], "о" .. p[1], "у" .. p[1], "х" .. p[1]}
		},
	},
}

m["bub"] = {
	"Bua",
	32928,
	"alv-bua",
	"Latn",
}

m["buc"] = {
	"tiếng Bushi",
	32928,
	"poz-bre",
	"Latn, Arab",
	"Tiếng Bushi",
	"Bushi"
}

m["bud"] = {
	"tiếng Ntcham",
	36266,
	"nic-grm",
	"Latn",
	"Tiếng Ntcham",
	"Ntcham",
}

m["bue"] = {
	"Beothuk",
	56234,
	nil,
	"Latn",
}

m["buf"] = {
	"Bushoong",
	3449964,
	"bnt-bsh",
	"Latn",
}

m["bug"] = {
	"tiếng Bugis",
	33190,
	"poz-ssw",
	"Bugi, Latn",
	"Tiếng Bugis",
	"Bugis",
}

m["buh"] = {
	"Younuo Bunu",
	56299,
	"hmn",
	"Latn",
}

m["bui"] = {
	"Bongili",
	35084,
	"bnt-ngn",
	"Latn",
}

m["buj"] = {
	"Basa-Gurmana",
	6432515,
	"nic-bas",
	"Latn",
}

m["buk"] = {
	"Bukawa",
	35043,
	"poz-ocw",
	"Latn",
}

m["bum"] = {
	"Bulu (Cameroon)",
	35028,
	"bnt-btb",
	"Latn",
}

m["bun"] = {
	"Sherbro",
	36339,
	"alv-mel",
	"Latn",
}

m["buo"] = {
	"Terei",
	56831,
	"paa-sbo",
	"Latn",
}

m["bup"] = {
	"Busoa",
	5002001,
	"poz",
	"Latn",
}

m["buq"] = {
	"tiếng Brem",
	4960502,
	"ngf",
	"Latn",
}

m["bus"] = {
	"tiếng Bokobaru",
	9228931,
	"dmn-bbu",
	"Latn",
	"Tiếng Bokobaru",
	"Bokobaru",
}

m["but"] = {
	"Bungain",
	3450623,
	"qfa-tor",
	"Latn",
}

m["buu"] = {
	"tiếng Budu",
	3450207,
	"bnt-nya",
	"Latn",
	"Tiếng Budu",
	"Budu",
}

m["buv"] = {
	"Bun",
	56351,
	"paa-yua",
	"Latn",
}

m["buw"] = {
	"Bubi",
	35017,
	"bnt-tso",
	"Latn",
}

m["bux"] = {
	"tiếng Boghom",
	3440412,
	"cdc-wst",
	"Latn",
	"Tiếng Boghom",
	"Boghom",
}

m["buy"] = {
	"Mmani",
	35061,
	"alv-mel",
	"Latn",
}

m["bva"] = {
	"Barein",
	56285,
	"cdc-est",
	"Latn",
}

m["bvb"] = {
	"tiếng Bube",
	35110,
	"nic-bds",
	"Latn",
	"Tiếng Bube",
	"Bube",
}

m["bvc"] = {
	"Baelelea",
	2878833,
	"poz-sls",
	"Latn",
}

m["bvd"] = {
	"Baeggu",
	2878850,
	"poz-sls",
	"Latn",
}

m["bve"] = {
	"Berau Malay",
	3915770,
	"poz-mly",
	"Latn",
}

m["bvf"] = {
	"Boor",
	56250,
	"cdc-est",
	"Latn",
}

m["bvg"] = {
	"Bonkeng",
	34958,
	"bnt-bbo",
	"Latn",
}

m["bvh"] = {
	"Bure",
	56294,
	"cdc-wst",
	"Latn",
}

m["bvi"] = {
	"Belanda Viri",
	35247,
	"nic-ser",
	"Latn",
}

m["bvj"] = {
	"Baan",
	3515067,
	"nic-ogo",
	"Latn",
}

m["bvk"] = {
	"Bukat",
	4986814,
	"poz-bnn",
	"Latn",
}

m["bvl"] = {
	"Bolivian Sign Language",
	1783590,
	"sgn",
	"Latn", -- when documented
}

m["bvm"] = {
	"Bamunka",
	34882,
	"nic-rnn",
	"Latn",
}

m["bvn"] = {
	"Buna",
	3450516,
	"qfa-tor",
	"Latn",
}

m["bvo"] = {
	"Bolgo",
	35038,
	"alv-bua",
	"Latn",
}

m["bvp"] = {
	"tiếng Bố Mang",
	4997235,
	"mkh-pal",
	nil,
	"Tiếng Bố Mang",
	"Bố Mang"
}

m["bvq"] = {
	"Birri",
	56514,
	"csu-bkr",
	"Latn",
}

m["bvr"] = {
	"Burarra",
	4998124,
	"aus-arn",
	"Latn",
}

m["bvt"] = {
	"Bati (Indonesia)",
	4869253,
	"poz-cma",
	"Latn",
}

m["bvu"] = {
	"Bukit Malay",
	9230148,
	"poz-mly",
	"Latn",
}

m["bvv"] = {
	"Baniva",
	3515198,
	"awd",
	"Latn",
}

m["bvw"] = {
	"Boga",
	56262,
	"cdc-cbm",
	"Latn",
}

m["bvx"] = {
	"Babole",
	35180,
	"bnt-ngn",
	"Latn",
}

m["bvy"] = {
	"Baybayanon",
	16839275,
	"phi",
	"Latn",
}

m["bvz"] = {
	"Bauzi",
	56360,
	"paa-egb",
	"Latn",
}

m["bwa"] = {
	"Bwatoo",
	9232446,
	"poz-cln",
	"Latn",
}

m["bwb"] = {
	"Namosi-Naitasiri-Serua",
	3130290,
	"poz-occ",
	"Latn",
}

m["bwc"] = {
	"Bwile",
	3447440,
	"bnt-sbi",
	"Latn",
}

m["bwd"] = {
	"Bwaidoka",
	2929111,
	"poz-ocw",
	"Latn",
}

m["bwe"] = {
	"tiếng Karen Bwe",
	56994,
	"kar",
	"Mymr",
	"Tiếng Karen Bwe",
	"Karen Bwe",
}

m["bwf"] = {
	"Boselewa",
	4947229,
	"poz-ocw",
	"Latn",
}

m["bwg"] = {
	"Barwe",
	8826802,
	"bnt-sna",
	"Latn",
}

m["bwh"] = {
	"Bishuo",
	34973,
	"nic-fru",
	"Latn",
}

m["bwi"] = {
	"Baniwa",
	3501735,
	"awd-nwk",
	"Latn",
}

m["bwj"] = {
	"tiếng Láá Láá Bwamu",
	11017275,
	"nic-bwa",
	"Latn",
	"Tiếng Láá Láá Bwamu",
	"Láá Láá Bwamu",
}

m["bwk"] = {
	"Bauwaki",
	4873607,
	"ngf",
	"Latn",
}

m["bwl"] = {
	"Bwela",
	5003678,
	"bnt-bun",
	"Latn",
}

m["bwm"] = {
	"Biwat",
	56352,
	"paa-yua",
	"Latn",
}

m["bwn"] = {
	"Wunai Bunu",
	56452,
	"hmn",
}

m["bwo"] = {
	"tiếng Shinasha",
	56260,
	"omv-gon",
	"Latn",
	"Tiếng Shinasha",
	"Shinasha",
}

m["bwp"] = {
	"Mandobo Bawah",
	12636155,
	"ngf",
	"Latn",
}

m["bwq"] = {
	"Southern Bobo",
	11001714,
	"dmn-snb",
	"Latn",
}

m["bwr"] = {
	"Bura",
	56552,
	"cdc-cbm",
	"Latn",
}

m["bws"] = {
	"Bomboma",
	9229429,
	"bnt-bun",
	"Latn",
}

m["bwt"] = {
	"Bafaw",
	34853,
	"bnt-bbo",
	"Latn",
}

m["bwu"] = {
	"Buli (Ghana)",
	35085,
	"nic-buk",
	"Latn",
}

m["bww"] = {
	"Bwa",
	3515058,
	"bnt-bta",
	"Latn",
}

m["bwx"] = {
	"Bu-Nao Bunu",
	56411,
	"hmn",
	"Latn",
}

m["bwy"] = {
	"Cwi Bwamu",
	11150714,
	"nic-bwa",
	"Latn",
}

m["bwz"] = {
	"Bwisi",
	35067,
	"bnt-sir",
	"Latn",
}

m["bxa"] = {
	"Bauro",
	2892068,
	"poz-sls",
	"Latn",
}

m["bxb"] = {
	"Belanda Bor",
	56678,
	"sdv-lon",
	"Latn",
}

m["bxc"] = {
	"Molengue",
	13345,
	"bnt-kel",
	"Latn",
}

m["bxd"] = {
	"tiếng Pela",
	57000,
	"tbq-brm",
	nil,
	"Tiếng Pela",
	"Pela",
}

m["bxe"] = {
	"tiếng Ongota",
	36344,
	"qfa-unc", -- moribund, no academic consensus on classification; might be an isolate
	"Latn",
}

m["bxf"] = {
	"Bilur",
	2903788,
	"poz-ocw",
	"Latn",
}

m["bxg"] = {
	"Bangala",
	34989,
	"bnt-bmo",
	"Latn",
}

m["bxh"] = {
	"Buhutu",
	4986329,
	"poz-ocw",
	"Latn",
}

m["bxi"] = {
	"Pirlatapa",
	10632195,
	"aus-kar",
	"Latn",
}

m["bxj"] = {
	"Bayungu",
	10427485,
	"aus-psw",
	"Latn",
}

m["bxk"] = {
	"Bukusu",
	32930,
	"bnt-msl",
	"Latn",
}

m["bxl"] = {
	"Jalkunan",
	11009787,
	"dmn-jje",
	"Latn",
}

m["bxn"] = {
	"Burduna",
	4998313,
	"aus-psw",
	"Latn",
}

m["bxo"] = {
	"Barikanchi",
	3450802,
	"crp",
	"Latn",
	ancestors = "ha",
}

m["bxp"] = {
	"Bebil",
	34941,
	"bnt-btb",
	"Latn",
}

m["bxq"] = {
	"Beele",
	56238,
	"cdc-wst",
	"Latn",
}

m["bxs"] = {
	"Busam",
	35189,
	"nic-grs",
	"Latn",
}

m["bxv"] = {
	"Berakou",
	56796,
	"csu-bgr",
	"Latn",
}

m["bxw"] = {
	"Banka",
	3438402,
	"dmn-smg",
	"Latn",
}

m["bxz"] = {
	"Binahari",
	4913840,
	"ngf",
	"Latn",
}

m["bya"] = {
	"Palawan Batak",
	3450443,
	"phi",
	"Tagb",
}

m["byb"] = {
	"Bikya",
	33257,
	"nic-fru",
	"Latn",
}

m["byc"] = {
	"Ubaghara",
	36625,
	"nic-ucn",
	"Latn",
}

m["byd"] = {
	"Benyadu'",
	11173588,
	"day",
	"Latn",
}

m["bye"] = {
	"Pouye",
	7235814,
	"paa-spk",
	"Latn",
}

m["byf"] = {
	"Bete",
	32932,
	"nic-ykb",
	"Latn",
}

m["byg"] = {
	"Baygo",
	56836,
	"sdv-daj",
	"Latn",
}

m["byh"] = {
	"Bujhyal",
	56317,
	"sit-gma",
	"Deva",
}

m["byi"] = {
	"tiếng Buyu",
	5003401,
	"bnt-nyb",
	"Latn",
	"Tiếng Buyu",
	"Buyu",
}

m["byj"] = {
	"Binawa",
	4913807,
	"nic-kau",
	"Latn",
}

m["byk"] = {
	"Biao",
	4902547,
	"qfa-tak",
	"Latn", -- also Hani?
}

m["byl"] = {
	"Bayono",
	3503856,
	"ngf",
	"Latn",
}

m["bym"] = {
	"Bidyara",
	8842355,
	"aus-pam",
	"Latn",
}

m["byn"] = {
	"tiếng Bilen",
	56491,
	"cus-cen",
	"Ethi, Latn",
	"Tiếng Bilen",
	"Bilen",
	translit = {Ethi = "Ethi-translit"},
}

m["byo"] = {
	"Biyo",
	56848,
	"tbq-bka",
	"Latn, Hani",
	sort_key = {Hani = "Hani-sortkey"},
}

m["byp"] = {
	"Bumaji",
	4997234,
	"nic-ben",
	"Latn",
}

m["byq"] = {
	"tiếng Basay",
	716647,
	"map",
	"Latn",
	"Tiếng Basay",
	"Basay",
}

m["byr"] = {
	"Baruya",
	3450812,
	"ngf",
	"Latn",
}

m["bys"] = {
	"Burak",
	4998097,
	"alv-bwj",
	"Latn",
}

m["byt"] = {
	"Berti",
	35008,
	"ssa-sah",
	"Latn",
}

m["byv"] = {
	"tiếng Medumba",
	36019,
	"bai",
	"Latn",
	"Tiếng Medumba",
	"Medumba",
}

m["byw"] = {
	"tiếng Belhariya",
	32961,
	"sit-kie",
	"Deva",
	"Tiếng Belhariya",
	"Belhariya",
}

m["byx"] = {
	"Qaqet",
	3503009,
	"paa-bng",
	"Latn",
}

m["byz"] = {
	"Banaro",
	56858,
	"paa",
	"Latn",
}

m["bza"] = {
	"tiếng Bandi",
	34912,
	"dmn-msw",
	"Latn",
	"Tiếng Bandi",
	"Bandi",
}

m["bzb"] = {
	"Andio",
	4754487,
	"poz-slb",
	"Latn",
}

m["bzd"] = {
	"Bribri",
	28400,
	"cba",
	"Latn",
}

m["bze"] = {
	"Jenaama Bozo",
	10950633,
	"dmn-snb",
	"Latn",
}

m["bzf"] = {
	"Boikin",
	56829,
	"paa-spk",
	"Latn",
}

m["bzg"] = {
	"tiếng Babuza",
	716615,
	"map",
	"Latn",
	"Tiếng Babuza",
	"Babuza",
}

m["bzh"] = {
	"tiếng Buang Mapos",
	2927370,
	"poz-ocw",
	"Latn",
	"Tiếng Buang Mapos",
	"Buang Mapos",
}

m["bzi"] = {
	"tiếng Bisu",
	56852,
	"tbq-bis",
	"Latn, Thai",
	"Tiếng Bisu",
	"Bisu",
	sort_key = {Thai = "Thai-sortkey"},
}

m["bzj"] = {
	"Belizean Creole",
	1363055,
	"crp",
	"Latn",
	ancestors = "en",
}

m["bzk"] = {
	"Nicaraguan Creole",
	3504097,
	"crp",
	"Latn",
	ancestors = "en",
}

m["bzl"] = {  -- supposedly also called "Bolano", but I can find no evidence of that
	"Boano (Sulawesi)",
	4931258,
	"poz",
	"Latn",
}

m["bzm"] = {
	"Bolondo",
	35071,
	"bnt-bun",
	"Latn",
}

m["bzn"] = {
	"Boano (Maluku)",
	4931255,
	"poz-cma",
	"Latn",
}

m["bzo"] = {
	"Bozaba",
	4952785,
	"bnt-ngn",
	"Latn",
}

m["bzp"] = {
	"Kemberano",
	12634399,
	"ngf-sbh",
	"Latn",
}

m["bzq"] = {
	"Buli (Indonesia)",
	2927952,
	"poz-hce",
	"Latn",
}

m["bzr"] = {
	"Biri",
	4087011,
	"aus-pam",
	"Latn",
}

m["bzs"] = {
	"Brazilian Sign Language",
	3436689,
	"sgn",
	"Latn",
}

m["bzu"] = {
	"Burmeso",
	56746,
	"paa-wpa",
	"Latn",
}

m["bzv"] = {
	"Bebe",
	34977,
	"nic-bbe",
	"Latn",
}

m["bzw"] = {
	"Basa",
	34898,
	"nic-bas",
	"Latn",
}

m["bzx"] = {
	"Hainyaxo Bozo",
	11159536,
	"dmn-snb",
	"Latn",
}

m["bzy"] = {
	"Obanliku",
	36276,
	"nic-ben",
	"Latn",
}

m["bzz"] = {
	"Evant",
	35259,
	"nic-tvc",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")