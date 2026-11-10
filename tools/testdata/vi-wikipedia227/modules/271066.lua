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

m["saa"] = {
	"tiếng Saba",
	3914885,
	"cdc-est",
	"Latn",
	"Tiếng Saba",
	"Saba",
}

m["sab"] = {
	"Buglere",
	3368506,
	"cba",
	"Latn",
}

m["sac"] = {
	"tiếng Fox",
	12714767,
	"alg-sfk",
	"Latn",
	"Tiếng Fox",
	"Fox",
}

m["sad"] = {
	"Sandawe",
	34016,
	"qfa-iso",
	"Latn",
}

m["sae"] = {
	"Sabanê",
	3460478,
	"sai-nmk",
	"Latn",
}

m["saf"] = {
	"Safaliba",
	36432,
	"nic-mre",
	"Latn",
}

m["sah"] = {
	"tiếng Yakut",
	34299,
	"trk-nsb",
	"Cyrl",
	"Tiếng Yakut",
	"Yakut",
	translit = "sah-translit",
	override_translit = true,
}

m["saj"] = {
	"Sahu",
	7399757,
	"paa-nha",
	"Latn",
}

m["sak"] = {
	"Sake",
	36425,
	"bnt-kel",
	"Latn",
}

m["sam"] = {
	"Samaritan Aramaic",
	56612,
	"sem-arw",
	"Samr",
	entry_name = {remove_diacritics = u(0x0816) .. "-" .. u(0x082D)},
	translit = "Samr-translit",
}

m["sao"] = {
	"Sause",
	4409155,
	"paa-tkw",
	"Latn",
}

m["saq"] = {
	"Samburu",
	56536,
	"sdv-lma",
}

m["sar"] = {
	"Saraveca",
	3450556,
	"awd",
}

m["sas"] = {
	"tiếng Sasak",
	1294047,
	"poz-mcm",
	"Latn",
	"Tiếng Sasak",
	"Sasak",
}

m["sat"] = {
	"tiếng Santal",
	33965,
	"mun",
	"Olck, Deva, Beng, Orya",
	"Tiếng Santal",
	"Santal",
	translit = "Olck-translit",
	override_translit = true,
}

m["sau"] = {
	"Saleman",
	7404262,
	"poz-cet",
}

m["sav"] = {
	"Saafi-Saafi",
	36308,
	"alv-cng",
	"Arab, Latn",
}

m["saw"] = {
	"Sawi",
	677064,
	"ngf",
	"Latn",
}

m["sax"] = {
	"Sa",
	3460352,
	"poz-vnc",
	"Latn",
}

m["say"] = {
	"Saya",
	3914431,
	"cdc-wst",
	"Latn",
}

m["saz"] = {
	"tiếng Saurashtra",
	13292,
	"inc-wes",
	"Saur, Latn, Taml, Deva",
	"Tiếng Saurashtra",
	"Saurashtra",
	translit = {
		Saur = "saz-translit",
		Taml = "ta-translit",
		},
	ancestors = "inc-ogu",
}

m["sba"] = {
	"tiếng Ngambay",
	2372207,
	"csu-sar",
	"Latn",
	"Tiếng Ngambay",
	"Ngambay",
}

m["sbb"] = {
	"Simbo",
	3484101,
	"poz-ocw",
}

m["sbc"] = {
	"Gele'",
	3194847,
	"poz-oce",
}

m["sbd"] = {
	"tiếng Samo Nam",
	33122730,
	"dmn-sam",
	"Latn",
	"Tiếng Samo Nam",
	"Samo Nam",
}

m["sbe"] = {
	"Saliba (New Guinea)",
	3469737,
	"poz-ocw",
}

m["sbf"] = {
	"tiếng Shabo",
	36342,
	"ssa",
	"Latn",
	"Tiếng Shabo",
	"Shabo",
}

m["sbg"] = {
	"Seget",
	7446237,
}

m["sbh"] = {
	"Sori-Harengan",
	36515,
	"poz-aay",
	"Latn",
}

m["sbi"] = {
	"Seti",
	7456682,
	"qfa-tor",
	"Latn",
}

m["sbj"] = {
	"Surbakhal",
	759995,
}

m["sbk"] = {
	"Safwa",
	4121160,
	"bnt-mby",
	"Latn",
}

m["sbl"] = {
	"tiếng Sambal Botolan",
	4095195,
	"phi",
	"Latn",
	"Tiếng Sambal Botolan",
	"Sambal Botolan",
}

m["sbm"] = {
	"Sagala",
	11732610,
	"bnt-ruv",
	"Latn",
}

m["sbn"] = {
	"Sindhi Bhil",
	25559289,
	"inc-snd",
	"Arab, Deva, Sind, Guru",
	ancestors = "sd",
}

m["sbo"] = {
	"tiếng Sabüm",
	7396535,
	"mkh-asl",
	nil,
	"Tiếng Sabüm",
	"Sabüm",
}

m["sbp"] = {
	"Sangu (Tanzania)",
	7418149,
	"bnt-bki",
	"Latn",
}

m["sbq"] = {
	"Sileibi",
	7514337,
	"ngf-mad",
}

m["sbr"] = {
	"Sembakung Murut",
	7449148,
	"poz-san",
}

m["sbs"] = {
	"Subiya",
	6442073,
	"bnt-bot",
	"Latn",
}

m["sbt"] = {
	"Kimki",
	6410160,
	"paa-pau",
}

m["sbu"] = {
	"Stod Bhoti",
	15622700,
	"sit-las",
}

m["sbv"] = {
	"Sabine",
	nil,
	"itc-sbl",
	"Latn",
}

m["sbw"] = {
	"Simba",
	36430,
	"bnt-tso",
	"Latn",
}

m["sbx"] = {
	"Seberuang",
	12473470,
	"poz-mly",
}

m["sby"] = {
	"Soli",
	7557754,
	"bnt-bot",
	"Latn",
}

m["sbz"] = {
	"Sara Kaba",
	25559318,
	"csu-kab",
	"Latn",
}

m["scb"] = {
	"tiếng Chứt",
	2967709,
	"mkh-vie",
	"Latn",
	"Tiếng Chứt",
	"Chứt",
}

m["sce"] = {
	"tiếng Đông Hương",
	32947,
	"xgn-shr",
	"Arab, Latn",
	"Tiếng Đông Hương",
	"Đông Hương",
}

m["scf"] = {
	"San Miguel Creole French",
	12953094,
	"crp",
	"Latn",
	ancestors = "gcf",
	sort_key = s["roa-oil-sortkey"],
}

m["scg"] = {
	"Sanggau",
	12473466,
	"day",
}

m["sch"] = {
	"Sakachep",
	37054,
	"tbq-kuk",
}

m["sci"] = {
	"Sri Lankan Creole Malay",
	1089151,
	"crp",
	"Latn",
	ancestors = "ms",
}

m["sck"] = {
	"tiếng Sadri",
	765922,
	"inc-bih",
	"Deva, Kthi, Beng, Orya",
	translit = {
		Deva = "hi-translit",
		Kthi = "bho-Kthi-translit",
	},
    "Tiếng Sadri",
    "Sadri",
}

m["scl"] = {
	"tiếng Shina",
	1353320,
	"inc-shn",
	"ur-Arab, Deva",
	"Tiếng Shina",
	"Shina",
}

m["scn"] = {
	"tiếng Sicily",
	33973,
	"roa-itd",
	"Latn",
	"Tiếng Sicily",
	"Sicily",
}

m["sco"] = {
	"tiếng Scots",
	14549,
	"gmw-ang",
	"Latn",
	"Tiếng Scots",
	"Scots",
	ancestors = "sco-smi",
}

m["scp"] = {
	"tiếng Yolmo",
	22662107,
	"sit-kyk",
	"Deva",
	"Tiếng Yolmo",
	"Yolmo",
}

m["scq"] = {
	"Sa'och",
	6583617,
	"mkh-pea",
}

m["scs"] = {
	"tiếng Bắc Slavey",
	20628,
	"den",
	"Latn, Cans",
	"Tiếng Bắc Slavey",
	"Bắc Slavey",
}

m["scu"] = {
	"Shumcho",
	22077739,
	"sit-kin",
}

m["scv"] = {
	"Sheni",
	11015820,
	"nic-jer",
	"Latn",
	ancestors = "zir",
}

m["scw"] = {
	"Sha",
	3438816,
	"cdc-wst",
	"Latn",
}

m["scx"] = {
	"tiếng Sicel",
	36667,
	"itc",
	"Polyt",
	"Tiếng Sicel",
	"Sicel",
	translit = "grc-translit",
	display_text = s["Polyt-displaytext"],
	entry_name = s["Polyt-entryname"],
	sort_key = s["Polyt-sortkey"],
}

m["sda"] = {
	"Toraja-Sa'dan",
	36673,
	"poz-ssw",
}

m["sdb"] = {
	"tiếng Shabak",
	3289596,
	"ira-zgr",
	"Arab",
	"Tiếng Shabak",
	"Shabak",
	ancestors = "hac",
}

m["sdc"] = {
	"tiếng Sassari",
	845441,
	"roa-itd",
	"Latn",
}

m["sde"] = {
	"Surubu",
	3913336,
	"nic-kau",
	"Latn",
}

m["sdf"] = {
	"Sarli",
	7424256,
	"ira-zgr",
	ancestors = "hac",
}

m["sdg"] = {
	"tiếng Savi",
	3474654,
	"inc-shn",
	"ur-Arab",
	"Tiếng Savi",
	"Savi",
}

m["sdh"] = {
	"tiếng Xwarin",
	1496597,
	"ku",
	"ku-Arab",
	translit = "sdh-translit",
	strip_diacritics = {remove_diacritics = c.kasra .. c.sukun},
}

m["sdj"] = {
	"Suundi",
	7650407,
	"bnt-kng",
	"Latn",
}

m["sdk"] = {
	"Sos Kundi",
	7563811,
	"paa-spk",
	"Latn",
}

m["sdl"] = {
	"Saudi Arabian Sign Language",
	3504160,
	"sgn",
}

m["sdm"] = {
	"Semandang",
	7449012,
	"day",
}

m["sdn"] = {
	"tiếng Gallura",
	612220,
	"roa-itd",
	"Latn",
	"Tiếng Gallura",
	"Gallura",
	ancestors = "co",
}

m["sdo"] = {
	"Bukar-Sadung Bidayuh",
	2927799,
	"day",
}

m["sdp"] = {
	"Sherdukpen",
	7494785,
	"sit-khb",
}

m["sdr"] = {
	"Oraon Sadri",
	12953860,
	"inc-eas",
	ancestors = "bh",
}

m["sds"] = {
	"tiếng Berber Tunisia",
	5329732,
	"ber",
	"Latn",
	"Tiếng Berber Tunisia",
	"Berber Tunisia",
}

m["sdu"] = {
	"Sarudu",
	7424700,
	"poz-cet",
}

m["sdx"] = {
	"Sibu Melanau",
	18642842,
	"poz-bnn",
}

m["sea"] = {
	"tiếng Semai",
	3135426,
	"mkh-asl",
	"Latn",
	"Tiếng Semai",
	"Semai",
}

-- seb is a duplicate code of spp

m["sec"] = {
	"tiếng Sechelt",
	7442898,
	"sal",
	"Latn",
	"Tiếng Sechelt",
	"Sechelt",
}

m["sed"] = {
	"tiếng Xơ Đăng",
	56448,
	"mkh-nbn",
	"Latn",
	"Tiếng Xơ Đăng",
	"Xơ Đăng",
}

m["see"] = {
	"tiếng Seneca",
	1185133,
	"iro-nor",
	"Latn",
	"Tiếng Seneca",
	"Seneca",
}

m["sef"] = {
	"Cebaara Senoufo",
	10975121,
	"alv-snr",
}

m["seg"] = {
	"Segeju",
	17584599,
	"bnt-mij",
	"Latn",
}

m["seh"] = {
	"tiếng Sena",
	2964008,
	"bnt-sna",
	"Latn",
	"Tiếng Sena",
	"Sena",
}

m["sei"] = {
	"tiếng Seri",
	36583,
	"qfa-iso",
	"Latn",
	"Tiếng Seri",
	"Seri",
}

m["sej"] = {
	"Sene",
	7450252,
}

m["sek"] = {
	"Sekani",
	28562,
	"ath-nor",
	"Latn",
}

m["sel"] = {
	"tiếng Selkup",
	34008,
	"syd",
	"Cyrl",
	"Tiếng Selkup",
	"Selkup",
}

m["sen"] = {
	"Nanerigé Sénoufo",
	36002,
	"alv-sma",
}

m["seo"] = {
	"Suarmin",
	7630513,
	"paa",
}

m["sep"] = {
	"Sìcìté Sénoufo",
	56787,
	"alv-sma",
}

m["seq"] = {
	"Senara Sénoufo",
	35210,
	"alv-snr",
}

m["ser"] = {
	"Serrano",
	3479942,
	"azc-tak",
	"Latn",
}

m["ses"] = {
	"tiếng Senni Koyraboro",
	35655,
	"son",
	"Latn, Arab",
	"Tiếng Senni Koyraboro",
	"Senni Koyraboro",
}

m["set"] = {
	"Sentani",
	3441672,
	"paa-sen",
	"Latn",
}

m["seu"] = {
	"Serui-Laut",
	7455503,
	"poz-hce",
	"Latn",
}

m["sev"] = {
	"tiếng Senoufo Nyarafolo",
	36306,
	"alv-snr",
	"Latn",
	"Tiếng Senoufo Nyarafolo",
	"Senoufo Nyarafolo",
}

m["sew"] = {
	"Sewa Bay",
	7458126,
	"poz-ocw",
}

m["sey"] = {
	"Secoya",
	3477218,
	"sai-tuc",
	"Latn",
}

m["sez"] = {
	"Senthang Chin",
	7451223,
	"tbq-kuk",
}

m["sfb"] = {
	"French Belgian Sign Language",
	3217332,
	"sgn",
}

m["sfe"] = {
	"Eastern Subanun",
	Q63311321,
	"phi",
	"Latn",
}

m["sfm"] = {
	"Small Flowery Miao",
	7542773,
	"hmn",
}

m["sfs"] = {
	"South African Sign Language",
	3322093,
	"sgn",
}

m["sfw"] = {
	"Sehwi",
	36593,
	"alv-ctn",
	"Latn",
}

m["sga"] = {
	"tiếng Ireland cổ",
	35308,
	"cel-gae",
	"Latn",
	"Tiếng Ireland cổ",
	"Ireland cổ",
	entry_name = {remove_diacritics = c.dotabove .. c.diaer .. "·"},
	sort_key = "sga-sortkey",
	standardChars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíLlMmNnOoÓóPpRrSsTtUuÚú0123456789" .. c.punc,
}

m["sgb"] = {
	"Mag-Anchi Ayta",
	4356243,
	"phi",
}

m["sgc"] = {
	"Kipsigis",
	56339,
	"sdv-nma",
}

m["sgd"] = {
	"Surigaonon",
	34140,
	"phi",
	"Latn",
}

m["sge"] = {
	"Segai",
	7446180,
}

m["sgg"] = {
	"Swiss-German Sign Language",
	35150,
	"sgn",
}

m["sgh"] = {
	"tiếng Shughnan",
	34053,
	"ira-shy",
	"Latn, Cyrl, Arab",
	"Tiếng Shughnan",
	"Shughnan",
	ancestors = "ira-shr-pro",
	translit = "sgh-translit",
	override_translit = true,
}

m["sgi"] = {
	"Suga",
	36475,
	"nic-mmb",
	"Latn",
}

m["sgk"] = {
	"Sangkong",
	2945610,
	"tbq-bis",
}

m["sgm"] = {
	"Singa",
	7522797,
	"bnt-lok",
	"Latn",
}

m["sgp"] = {
	"Singpho",
	7524158,
	"sit-jnp",
}

m["sgr"] = {
	"tiếng Sangisar",
	3394363,
	"ira-kms",
	"Arab",
	"Tiếng Sangisar",
	"Sangisar",
}

m["sgs"] = {
	"tiếng Samogitia",
	213434,
	"bat-eas",
	"Latn",
	"Tiếng Samogitia",
	"Samogitia",
	wikimedia_codes = "bat-smg",
	ancestors = "olt",
	display_text = "lt-common",
	strip_diacritics = "lt-common",
	sort_key = "lt-common",
}

m["sgt"] = {
	"tiếng Brokpa",
	56603,
	"sit-tib",
	"Tibt",
	"Tiếng Brokpa",
	"Brokpa",
	override_translit = true,
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["sgu"] = {
	"Salas",
	7403694,
	"poz-cma",
}

m["sgw"] = {
	"tiếng Sebat Bet Gurage",
	2707343,
	"sem-eth",
	"Ethi",
	"Tiếng Sebat Bet Gurage",
	"Sebat Bet Gurage",
}

m["sgx"] = {
	"Sierra Leone Sign Language",
	7511448,
	"sgn",
}

m["sgy"] = {
	"Sanglechi",
	3472220,
	"ira-sgi",
}

m["sgz"] = {
	"Sursurunga",
	36511,
	"poz-ocw",
	"Latn",
}

m["sha"] = {
	"Shall-Zwall",
	3915355,
	"nic-beo",
}

m["shb"] = {
	"Ninam",
	3436586,
}

m["shc"] = {
	"Sonde",
	7560881,
	"bnt-pen",
	"Latn",
}

m["shd"] = {
	"tiếng Kundal Shahi",
	6444265,
	"inc-shn",
	"Arab",
	"Tiếng Kundal Shahi",
	"Kundal Shahi",
}

m["she"] = {
	"Sheko",
	3183355,
	"omv-diz",
}

m["shg"] = {
	"Shua",
	3501092,
	"khi-kal",
	"Latn",
}

m["shh"] = {
	"Shoshone",
	33811,
	"azc-num",
	"Latn",
}

m["shi"] = {
	"tiếng Tashelhit",
	34152,
	"ber",
	"Latn, Arab, Tfng, Hebr",
	"Tiếng Tashelhit",
	"Tashelhit",
	translit = "Tfng-translit",
	-- put Judeo-Berber (Hebrew-script Tashelhit) under the category header
	-- U+FB21 HEBREW LETTER WIDE ALEF so that it sorts after Tifinagh script titles
	sort_key = {
		from = {"^%f[" .. u(0x5D0) .. "-" .. u(0x5EA) .. "]"},
		to   = {u(0xFB21)},
	},
	ancestors = "shi-med",
}

m["shj"] = {
	"Shatt",
	56344,
	"sdv-daj",
}

m["shk"] = {
	"Shilluk",
	36486,
	"sdv-lon",
	"Latn",
}

m["shl"] = {
	"Shendu",
	22074616,
	"tbq-kuk",
}

m["shm"] = {
	"Shahrudi",
	7462280,
	"xme-ttc",
	ancestors = "xme-ttc-cen",
}

m["shn"] = {
	"tiếng Shan",
	56482,
	"tai-swe",
	"Mymr",
	"Tiếng Shan",
	"Shan",
	translit = "shn-translit",
	sort_key = {
		from = {"[ၢႃ]", "ဵ", "ႅ", "ႇ", "ႈ", "း", "ႉ", "ႊ"},
		to   = {"ာ", "ေ", "ႄ", "႒", "႓", "႔", "႕", "႖"}
	},
}

m["sho"] = {
	"Shanga",
	3913931,
	"dmn-bbu",
	"Latn",
}

m["shp"] = {
	"Shipibo-Conibo",
	2671988,
	"sai-pan",
	"Latn",
}

m["shq"] = {
	"Sala",
	10961665,
	"bnt-bot",
	"Latn",
}

m["shr"] = {
	"Shi",
	3481999,
	"bnt-shh",
	"Latn",
}

m["shs"] = {
	"tiếng Shuswap",
	3482685,
	"sal",
	"Latn",
	"Tiếng Shuswap",
	"Shuswap",
}

m["sht"] = {
	"Shasta",
	56396,
	"nai-shs",
	"Latn",
}

m["shu"] = {
	"tiếng Ả Rập Tchad",
	56497,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Tchad",
	"Ả Rập Tchad",
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		from = {u(0x0671)},
		to   = {u(0x0627)}
	},
}

m["shv"] = {
	"Shehri",
	33445,
	"sem-sar",
	"Arab, Latn",
}

m["shw"] = {
	"Shwai",
	36527,
	"alv-hei",
}

m["shx"] = {
	"She",
	2605689,
	"hmn",
}

m["shy"] = {
	"tiếng Tachawit",
	33274,
	"ber",
	"Tfng, Arab, Latn",
	"Tiếng Tachawit",
	"Tachawit",
	translit = "Tfng-translit",
}

m["shz"] = {
	"Syenara Senoufo",
	36316,
	"alv-snr",
}

m["sia"] = {
	"tiếng Sami Akkala",
	35241,
	"smi",
	"Cyrl, Latn",
	"Tiếng Sami Akkala",
	"Sami Akkala",
	translit = "sia-translit",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = "'ˈ"},
}

m["sib"] = {
	"Sebop",
	7442799,
	"poz-swa",
	"Latn",
}

m["sid"] = {
	"tiếng Sidamo",
	33786,
	"cus-hec",
	"Latn, Ethi",
	"Tiếng Sidamo",
	"Sidamo",
}

m["sie"] = {
	"Simaa",
	7517329,
	"bnt-kav",
	"Latn",
}

m["sif"] = {
	"Siamou",
	36252,
}

m["sig"] = {
	"Paasaal",
	36426,
	"nic-sis",
	"Latn",
}

m["sih"] = {
	"Zire",
	8072753,
	"poz-cln",
}

m["sii"] = {
	"tiếng Shompen",
	1039346,
	"aav",
	"Latn",
	"Tiếng Shompen",
	"Shompen"
}

m["sij"] = {
	"Numbami",
	3346277,
	"poz-ocw",
}

m["sik"] = {
	"Sikiana",
	3443734,
	"sai-prk",
	"Latn",
}

m["sil"] = {
	"Tumulung Sisaala",
	25383006,
	"nic-sis",
	"Latn",
}

m["sim"] = {
	"Seim",
	7446815,
	"paa-spk",
}

m["sip"] = {
	"tiếng Sikkim",
	35285,
	"sit-tib",
	"Tibt",
	"Tiếng Sikkim",
	"Sikkim",
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["siq"] = {
	"Sonia",
	7561770,
}

m["sir"] = {
	"Siri",
	3438729,
	"cdc-wst",
	"Latn",
}

m["sis"] = {
	"Siuslaw",
	2315424,
}

m["siu"] = {
	"Sinagen",
	7521655,
	"qfa-tor",
	"Latn",
}

m["siv"] = {
	"Sumariup",
	7636966,
	"paa-spk",
	"Latn",
}

m["siw"] = {
	"Siwai",
	7532519,
	"paa-sbo",
}

m["six"] = {
	"Sumau",
	7637021,
	"ngf-mad",
	"Latn",
}

m["siy"] = {
	"Sivandi",
	13269,
	"xme",
	ancestors = "xme-mid",
}

m["siz"] = {
	"tiếng Siwi",
	36814,
	"ber",
	"Tfng, Arab, Latn",
	"Tiếng Siwi",
	"Siwi",
}

m["sja"] = {
	"Epena",
	3055682,
	"sai-chc",
}

m["sjb"] = {
	"Sajau Basap",
	4684353,
	"poz-bnn",
}

m["sjd"] = {
	"tiếng Sami Kildin",
	33656,
	"smi",
	"Cyrl",
	"Tiếng Sami Kildin",
	"Sami Kildin",
	translit = "sjd-translit",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = "'ˈ"},
}

m["sje"] = {
	"Pite Sami",
	56314,
	"smi",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = c.macron .. "'ˈ"},
	sort_key = "sje-sortkey",
}

m["sjg"] = {
	"Assangori",
	3502255,
	"sdv-tmn",
}

m["sjk"] = {
	"Kemi Sami",
	35871,
	"smi",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = "'ˈ"},
}

m["sjl"] = {
	"Miji",
	6845470,
	"sit-hrs",
}

m["sjm"] = {
	"Mapun",
	3287253,
	"poz-sbj",
}

m["sjn"] = {
	"Sindarin",
	56437,
	"art",
	"Latn, Teng",
	type = "appendix-constructed",
}

m["sjo"] = {
	"tiếng Tích Bá",
	13223,
	"tuw-jrc",
	"sjo-Mong, Cyrl",
	"Tiếng Tích Bá",
	"Tích Bá",
	ancestors = "mnc",
}

m["sjp"] = {
	"tiếng Surjapur",
	7645351,
	"inc-krn",
	"Deva, as-Beng, Kthi",
	"Tiếng Surjapur",
	"Surjapur",
}

m["sjr"] = {
	"Siar-Lak",
	3482907,
	"poz-ocw",
}

m["sjs"] = {
	"tiếng Senhaja de Srair",
	56744,
	"ber",
	"Latn, Tfng, Arab",
	"Tiếng Senhaja de Srair",
	"Senhaja de Srair",
	strip_diacritics = {
		Arab = "ar-stripdiacritics",
	},
	translit = {
		Tfng = "Tfng-translit",
	}
}

m["sjt"] = {
	"tiếng Sami Ter",
	36656,
	"smi",
	"Latn, Cyrl",
	"Tiếng Sami Ter",
	"Sami Ter",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = "'ˈ"},
}

m["sju"] = {
	"tiếng Sami Ume",
	56415,
	"smi",
	"Latn",
	"Tiếng Sami Ume",
	"Sami Ume",
	entry_name = {remove_diacritics = c.macron .. "'ˈ"},
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	sort_key = "sju-sortkey",
}

m["sjw"] = {
	"Shawnee",
	2669206,
	"alg",
	"Latn",
}

m["ska"] = {
	"Skagit",
	25559652,
	"sal",
	"Latn",
}

m["skb"] = {
	"tiếng Saek",
	36437,
	"tai-nor",
	"Thai",
	"Tiếng Saek",
	"Saek",
	sort_key = "Thai-sortkey",
}

m["skc"] = {
	"Ma Manda",
	6720783,
	"ngf-fin",
}

m["skd"] = {
	"Southern Sierra Miwok",
	3492334,
	"nai-utn",
	"Latn",
}

m["ske"] = {
	"Ske",
	7534244,
	"poz-vnc",
	"Latn",
}

m["skf"] = {
	"Mekéns",
	3304806,
	"tup",
	"Latn",
}

m["skh"] = {
	"Sikule",
	3121081,
	"poz-nws",
}

m["ski"] = {
	"Sika",
	33960,
	"poz-cet",
	"Latn",
}

m["skj"] = { -- compare 'ths'
	"Seke",
	30226846,
	"sit-tam",
}

m["skk"] = {
	"Sok",
	12953887,
	"mkh-ban",
}

m["skm"] = {
	"Sakam",
	6448517,
	"ngf-fin",
}

m["skn"] = {
	"Kolibugan Subanon",
	18755617,
	"phi",
	"Latn",
}

m["sko"] = {
	"Seko Tengah",
	15613270,
	"poz",
}

m["skp"] = {
	"Sekapan",
	7447132,
	"poz-bnn",
}

m["skq"] = {
	"Sininkere",
	3914896,
	"dmn-man",
	"Latn",
}

m["skr"] = {
	"tiếng Saraiki",
	33902,
	"inc-pan",
	"pa-Arab, Mult, Deva",
	"Tiếng Saraiki",
	"Saraiki",
	ancestors = "lah",
	entry_name = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun},
	translit = {
		["pa-Arab"] = "pa-Arab-translit",
		Mult = "Mult-translit",
	},
}

m["sks"] = {
	"tiếng Maia",
	12952760,
	"ngf-kau",
	"Latn",
}

m["skt"] = {
	"Sakata",
	36691,
	"bnt-bnm",
	"Latn",
}

m["sku"] = {
	"Sakao",
	3298421,
	"poz-vnc",
	"Latn",
}

m["skv"] = {
	"Skou",
	3915200,
	"paa-msk",
	"Latn",
}

m["skw"] = {
	"tiếng Skepi",
	2522153,
	"crp",
	"Latn",
	"Tiếng Skepi",
	"Skepi",
	ancestors = "nl",
}

m["skx"] = {
	"Seko Padang",
	15613282,
	"poz-ssw",
}

m["sky"] = {
	"Sikaiana",
	7439242,
	"poz-pnp",
	"Latn",
}

m["skz"] = {
	"Sekar",
	7447136,
	"poz-cet",
}

m["slc"] = {
	"Saliba (Colombia)",
	3441097,
}

m["sld"] = {
	"tiếng Sissala",
	11020264,
	"nic-sis",
	"Latn",
	"Tiếng Sissala",
	"Sissala",
}

m["sle"] = {
	"tiếng Sholaga",
	7500203,
	"dra-kan",
	"Knda",
	"Tiếng Sholaga",
	"Sholaga",
	translit = "kn-translit"
}

m["slf"] = {
	"Swiss-Italian Sign Language",
	12953479,
	"sgn",
}

m["slg"] = {
	"Selungai Murut",
	7448844,
	"poz-san",
}

m["slh"] = {
	"Southern Puget Sound Salish",
	12642471,
	"sal",
	"Latn",
}

-- "sli" "Silesian German" IS SUBSUMED INTO "gmw-ecg" "East Central German"

m["slj"] = {
	"Salumá",
	7406296,
	"sai-prk",
	"Latn",
}

m["sll"] = {
	"Salt-Yui",
	7405785,
}

m["slm"] = {
	"Pangutaran Sama",
	3362086,
	"poz-sbj",
}

m["sln"] = {
	"Salinan",
	1568938,
}

m["slp"] = {
	"Lamaholot",
	6480777,
	"poz-cet",
	"Latn",
}

m["slq"] = {
	"Salchuq",
	56752,
	"trk",
}

m["slr"] = {
	"tiếng Salar",
	33963,
	"trk-ogz",
	"Arab, Latn",
	"Tiếng Salar",
	"Salar",
}

m["sls"] = {
	"Singapore Sign Language",
	7512563,
	"sgn",
}

m["slt"] = {
	"Sila",
	7514021,
	"tbq-sil",
}

m["slu"] = {
	"Selaru",
	7447500,
	"poz-cet",
}

m["slw"] = {
	"Sialum",
	7506694,
	"ngf",
}

m["slx"] = {
	"Salampasu",
	7403607,
	"bnt-lun",
	"Latn",
}

m["sly"] = {
	"Selayar",
	7447520,
	"poz-ssw",
}

m["slz"] = {
	"Ma'ya",
	2291492,
	"poz-hce",
}

m["sma"] = {
	"tiếng Nam Sami",
	13293,
	"smi",
	"Latn",
	"Tiếng Nam Sami",
	"Nam Sami",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = "'ˈ"},
	sort_key = "sma-sortkey",
}

m["smb"] = {
	"Simbari",
	7517427,
	"ngf",
}

m["smc"] = {
	"Som",
	7559081,
	"ngf-fin",
	"Latn",
}

m["smd"] = {
	"Sama",
	6407456,
	"bnt-kmb",
	"Latn",
}

m["smf"] = {
	"Auwe",
	3502072,
	"paa-brd",
	ancestors = "dnd",
}

m["smg"] = {
	"Simbali",
	56692,
	"paa-bng",
}

m["smh"] = {
	"tiếng Thát Mai",
	7409269,
	"tbq-axi",
	nil,
	"Tiếng Thát Mai",
	"Thát Mai",
}

m["smj"] = {
	"Lule Sami",
	56322,
	"smi",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = c.macron .. "'ˈ"},
	sort_key = "smj-sortkey",
}

m["smk"] = {
	"tiếng Bolinao",
	2669235,
	"phi",
	"Latn, Tglg",
}

m["sml"] = {
	"tiếng Sama Trung",
	3470593,
	"poz-sbj",
	"Latn",
	"Tiếng Sama Trung",
	"Sama Trung",
}

m["smm"] = {
	"Musasa",
	6940122,
	"inc-eas",
	ancestors = "bh",
}

m["smn"] = {
	"tiếng Sami Inari",
	33462,
	"smi",
	"Latn",
	"Tiếng Sami Inari",
	"Sami Inari",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = c.dotbelow .. "'ˈ"},
	sort_key = "smn-sortkey",
}

m["smp"] = {
	"Samaritan Hebrew",
	56502,
	"sem-can",
	"Samr",
	entry_name = {remove_diacritics = u(0x0816) .. "-" .. u(0x082D)},
}

m["smq"] = {
	"tiếng Samo",
	7409884,
	"ngf-est",
	"Latn",
	"Tiếng Samo",
	"Samo",
}

m["smr"] = {
	"Simeulue",
	2992833,
	"poz-nws",
	"Latn",
}

m["sms"] = {
	"tiếng Sami Skolt",
	13271,
	"smi",
	"Latn",
	"Tiếng Sami Skolt",
	"Sami Skolt",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = c.dotbelow .. "'ˈ"},
	sort_key = "sms-sortkey",
}

m["smt"] = {
	"Simte",
	7521268,
	"tbq-kuk",
}

m["smu"] = {
	"Somray",
	6583612,
	"mkh-pea",
}

m["smv"] = {
	"Samvedi",
	6345632,
	"inc-sou",
}

m["smw"] = {
	"tiếng Sumbawa",
	3182585,
	"poz-bss",
	"Latn",
}

m["smx"] = {
	"Samba",
	11120157,
	"bnt-pen",
	"Latn",
}

m["smy"] = {
	"Semnani",
	14531212,
	"xme",
}

m["smz"] = {
	"Simeku",
	7517534,
	"paa-sbo",
}

m["snb"] = {
	"Sebuyau",
	7442836,
	"poz-mly",
}

m["snc"] = {
	"tiếng Sinaugoro",
	4170719,
	"poz-ocw",
	"Latn",
	"Tiếng Sinaugoro",
	"Sinaugoro",
}

m["sne"] = {
	"tiếng Bidayuh Bau",
	2891938,
	"day",
	"Latn",
	"Tiếng Bidayuh Bau",
	"Bidayuh Bau",
}

m["snf"] = {
	"tiếng Noon",
	36304,
	"alv-cng",
	"Latn",
	"Tiếng Noon",
	"Noon",
}

m["sng"] = {
	"Sanga (Congo)",
	3438316,
	"bnt-lub",
	"Latn",
}

m["sni"] = {
	"Sensi",
	7451029,
	"sai-pan",
	"Latn",
}

m["snj"] = {
	"Riverain Sango",
	25559751,
	"crp",
	"Latn",
	ancestors = "ngb",
}

m["snk"] = {
	"tiếng Soninke",
	36660,
	"dmn-snb",
	"Latn, Arab",
	"Tiếng Soninke",
	"Soninke",
}

m["snl"] = {
	"Sangil",
	3472206,
	"phi",
}

m["snm"] = {
	"Southern Ma'di",
	15637273,
	"csu-mma",
}

m["snn"] = {
	"Siona",
	3485116,
	"sai-tuc",
	"Latn",
}

m["sno"] = {
	"Snohomish",
	25559662,
	"sal",
	"Latn",
}

m["snp"] = {
	"Siane",
	7506812,
	"paa-kag",
	"Latn",
}

m["snq"] = {
	"Sangu (Gabon)",
	36609,
	"bnt-sir",
	"Latn",
}

m["snr"] = {
	"Sihan",
	7513400,
	"ngf-mad",
}

m["sns"] = {
	"Nahavaq",
	2160435,
	"poz-vnc",
}

m["snu"] = {
	"Senggi",
	7929052,
	"paa-brd"
}

m["snv"] = {
	"Sa'ban",
	3474891,
	"poz-swa",
	"Latn",
}

m["snw"] = {
	"Selee",
	36272,
	"alv-ntg",
	"Latn",
}

m["snx"] = {
	"Sam",
	7408387,
}

m["sny"] = {
	"Saniyo-Hiyewe",
	7418302,
	"paa-spk",
	"Latn",
}

m["snz"] = {
	"Kou",
	7525035, -- also 4803639
	"ngf-mad",
	"Latn",
}

m["soa"] = {
	"tiếng Thái Tống",
	7709159,
	"tai-swe",
	"Tavt, Thai",
	"Tiếng Thái Tống",
	"Thái Tống",
	--translit = "Tavt-translit",
 	sort_key = {
		from = {"([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])", "([เแโใไ])([ก-ฮ])"},
		to   = {"%2%1", "%2%1"}
	},
}

m["sob"] = {
	"Sobei",
	3121035,
	"poz-ocw",
}

m["soc"] = {
	"Soko",
	7555138,
	"bnt-ske",
	"Latn",
}

m["sod"] = {
	"Songoora",
	7561296,
	"bnt-lgb",
	"Latn",
}

m["soe"] = {
	"Songomeno",
	5713543,
	"bnt-bsh",
	"Latn",
}

m["sog"] = {
	"tiếng Sogdia",
	205979,
	"ira-sgc",
	"Sogd, Mani, Syrc, Sogo",
	"Tiếng Sogdia",
	"Sogdia",
	translit = {
		Sogd = "Sogd-translit",
		Mani = "Mani-translit",
		Sogo = "Sogo-translit",
	},
}

m["soh"] = {
	"Aka (Sudan)",
	3450949,
	"sdv-eje",
	"Latn",
}

m["soi"] = {
	"Sonha",
	12953890,
	"inc-eas",
}

m["sok"] = {
	"Sokoro",
	3441303,
	"cdc-est",
	"Latn",
}

m["sol"] = {
	"Solos",
	3489591,
	"poz-ocw",
}

m["soo"] = {
	"Nsong",
	12953148,
	"bnt-bdz",
	"Latn",
}

m["sop"] = {
	"Songe",
	3130911,
	"bnt-lbn",
	"Latn",
}

m["soq"] = {
	"Kanasi",
	11732656,
}

m["sor"] = {
	"Somrai",
	3123566,
	"cdc-est",
	"Latn",
}

m["sos"] = {
	"Seenku",
	36274,
	"dmn-smg",
}

m["sou"] = {
	"tiếng Nam Thái",
	56508,
	"tai-swe",
	"Thai",
	"Tiếng Nam Thái",
	"Nam Thái",
	sort_key = "Thai-sortkey",
}

m["sov"] = {
	"tiếng Sonsorol",
	13281,
	"poz-mic",
	"Latn",
	"Tiếng Sonsorol",
	"Sonsorol",
}

m["sow"] = {
	"Sowanda",
	7571845,
	"paa-brd"
}

m["sox"] = {
	"Swo",
	36604,
	"bnt-mka",
	"Latn",
}

m["soy"] = {
	"Miyobe",
	35913,
	"alv-sav",
	"Latn",
}

m["soz"] = {
	"Temi",
	13278,
	"bnt-kka",
	"Latn",
}

m["spb"] = {
	"Sepa (Indonesia)",
	18603687,
	"poz-cma",
	"Latn",
}

m["spc"] = {
	"Sapé",
	2888158,
	nil,
	"Latn",
}

m["spd"] = {
	"Saep",
	7398312,
	"ngf-mad",
}

m["spe"] = {
	"Sepa (New Guinea)",
	7451725,
	"poz-ocw",
	"Latn",
}

m["spg"] = {
	"Sian",
	7506806,
	"poz-bnn",
}

m["spi"] = {
	"Saponi",
	3915418,
	"paa",
}

m["spk"] = {
	"Sengo",
	7450584,
	"paa-spk",
	"Latn",
}

m["spl"] = {
	"Selepet",
	7447917,
	"ngf",
}

m["spm"] = {
	"Sepen",
	4701931,
	"paa",
	"Latn",
}

m["spn"] = {
	"Sanapaná",
	3033556,
	"sai-mas",
	"Latn",
}

m["spo"] = {
	"Spokane",
	3493704,
	"sal",
}

m["spp"] = {
	"Supyire",
	56284,
	"alv-sma",
	"Latn",
}

m["spr"] = {
	"Saparua",
	7420921,
	"poz-cma",
}

m["sps"] = {
	"tiếng Saposa",
	3473187,
	"poz-ocw",
	nil,
	"Tiếng Saposa",
	"Saposa",
}

m["spt"] = {
	"Spiti Bhoti",
	22080879,
	"sit-las",
}

m["spu"] = {
	"Sapuan",
	7421168,
	"mkh-ban",
}

m["spv"] = {
	"tiếng Sambalpur",
	6433240,
	"inc-eas",
	"Orya",
	"Tiếng Sambalpur",
	"Sambalpur",
	translit = "or-translit",
	ancestors = "or",
}

m["spx"] = {
	"tiếng Piceni Nam",
	36688,
	"itc-sbl",
	"Ital, Latn",
	"Tiếng Piceni Nam",
	"Piceni Nam",
	translit = "Ital-translit",
}

m["spy"] = {
	"Sabaot",
	7395896,
	"sdv-kln",
}

m["sqa"] = {
	"Shama-Sambuga",
	3914392,
	"nic-kmk",
	"Latn",
}

m["sqh"] = {
	"Shau",
	3913925,
	"nic-jer",
	"Latn",
}

m["sqk"] = {
	"Albanian Sign Language",
	4709168,
	"sgn",
}

m["sqm"] = {
	"Suma",
	11008431,
	"alv-gbw",
}

m["sqn"] = {
	"Susquehannock",
	3505736,
	"iro-nor",
}

m["sqo"] = {
	"Sorkhei",
	3491964,
	"ira-kms",
}

m["sqq"] = {
	"Sou",
	16979751,
	"mkh-ban",
}

m["sqr"] = {
	"Siculo-Arabic",
	1069489,
	"sem-arb",
}

m["sqs"] = {
	"Sri Lankan Sign Language",
	3915466,
	"sgn",
}

m["sqt"] = {
	"tiếng Socotra",
	13283,
	"sem-sar",
	"Arab, Latn",
	"Tiếng Socotra",
	"Socotra",
}

m["squ"] = {
	"tiếng Squamish",
	2484579,
	"sal",
	"Latn",
	"Tiếng Squamish",
	"Squamish",
}

m["sra"] = {
	"Saruga",
	7424699,
	"ngf-mad",
	"Latn",
}

m["srb"] = {
	"tiếng Sora",
	13284,
	"mun",
	"Sora, Orya, Telu",
	"Tiếng Sora",
	"Sora",
}

m["sre"] = {
	"Sara",
	33957,
	"day",
}

m["srf"] = {
	"Nafi",
	6958174,
	"poz-ocw",
}

m["srg"] = {
	"Sulod",
	7636489,
	"phi",
}

m["srh"] = {
	"tiếng Sarikol",
	33873,
	"ira-shr",
	"Latn, Arab, Cyrl",
	"Tiếng Sarikol",
	"Sarikol",
}

m["sri"] = {
	"Siriano",
	3485264,
	"sai-tuc",
	"Latn",
}

m["srk"] = {
	"Serudung Murut",
	7455497,
	"poz-san",
}

m["srl"] = {
	"Isirawa",
	4203802,
	"paa-tkw",
}

m["srm"] = {
	"tiếng Saramacca",
	33779,
	"crp",
	"Latn",
	"Tiếng Saramacca",
	"Saramacca",
	ancestors = "en, pt",
}

m["srn"] = {
	"tiếng Sranan Tongo",
	33989,
	"crp",
	"Latn",
	"Tiếng Sranan Tongo",
	"Sranan Tongo",
}

m["srq"] = {
	"Sirionó",
	3027953,
	"tup-gua",
	"Latn",
}

m["srr"] = {
	"tiếng Serer",
	36284,
	"alv-fwo",
	"Latn, Arab",
	"Tiếng Serer",
	"Serer",
}

m["srs"] = {
	"tiếng Tsuut'ina",
	20825,
	"ath-nor",
	"Latn",
	"Tiếng Tsuut'ina",
	"Tsuut'ina",
}

m["srt"] = {
	"Sauri",
	7427547,
	"paa-egb",
}

m["sru"] = {
	"Suruí",
	7646993,
	"tup",
	"Latn",
}

m["srv"] = {
	"Waray Sorsogon",
	18755610,
	"phi",
}

m["srw"] = {
	"Serua",
	14916905,
	"poz-cet",
}

m["srx"] = {
	"tiếng Sirmaur",
	7530505,
	"him",
	"Deva",
	"Tiếng Sirmaur",
	"Sirmaur",
}

m["sry"] = {
	"Sera",
	7452602,
	"poz-ocw",
	"Latn",
}

m["srz"] = {
	"Shahmirzadi",
	12953126,
	"ira-msh",
	"fa-Arab",
}

m["ssb"] = {
	"Southern Sama",
	3470594,
	"poz-sbj",
	"Latn",
}

m["ssc"] = {
	"Suba-Simbiti",
	7630687,
	"bnt-lok",
	"Latn",
}

m["ssd"] = {
	"Siroi",
	10771067,
	"ngf-mad",
	"Latn",
}

m["sse"] = {
	"Balangingi",
	2880535,
	"poz-sbj",
	"Latn",
}

m["ssf"] = {
	"Thao",
	676492,
	"map",
	"Latn",
}

m["ssg"] = {
	"Seimat",
	3182581,
	"poz-aay",
}

m["ssh"] = {
	"Shihhi Arabic",
	56571,
	"sem-arb",
	"Arab",
	entry_name = {
		remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		from = {u(0x0671)},
		to   = {u(0x0627)}
	},
}

m["ssi"] = {
	"Sansi",
	3309366,
	"inc-nwe",
}

m["ssj"] = {
	"Sausi",
	7427605,
	"ngf-mad",
	"Latn",
}

m["ssk"] = {
	"Sunam",
	11002210,
	"sit-kin",
}

m["ssl"] = {
	"Western Sisaala",
	11154776,
	"nic-sis",
	"Latn",
}

m["ssm"] = {
	"tiếng Semnam",
	7449713,
	"mkh-asl",
	"Latn",
	"Tiếng Semnam",
	"Semnam",
}

m["ssn"] = {
	"tiếng Waata",
	7449713,
	"cus-eas",
	nil,
	"Tiếng Waata",
	"Waata",
}

m["sso"] = {
	"tiếng Sissano",
	7530937,
	"poz-ocw",
	"Latn",
	"Tiếng Sissano",
	"Sissano",
}

m["ssp"] = {
	"Spanish Sign Language",
	3100814,
	"sgn",
}

m["ssq"] = {
	"So'a",
	7572120,
	"poz-cet",
	"Latn",
}

m["ssr"] = {
	"Swiss-French Sign Language",
	12953483,
	"sgn",
}

m["sss"] = {
	"tiếng Sô",
	3082037,
	"mkh-kat",
	"Thai",
	"Tiếng Sô",
	"Sô",
}

m["sst"] = {
	"Sinasina",
	7521813,
	"ngf",
	"Latn",
}

m["ssu"] = {
	"Susuami",
	7649752,
	"ngf",
	"Latn",
}

m["ssv"] = {
	"Shark Bay",
	7489783,
	"poz-vnc",
}

m["ssx"] = {
	"Samberigi",
	7409020,
	"paa-eng",
	"Latn",
}

m["ssy"] = {
	"tiếng Saho",
	36353,
	"cus-eas",
	"Latn, Ethi, Arab",
	"Tiếng Saho",
	"Saho",
}

m["ssz"] = {
	"Sengseng",
	7450601,
	"poz-ocw",
	"Latn",
}

m["stb"] = {
	"Northern Subanen",
	12953892,
	"phi",
	"Latn",
}

m["std"] = {
	"Sentinelese",
	568377,
}

m["ste"] = {
	"Liana-Seti",
	6539924,
	"poz-cma",
}

m["stf"] = {
	"Seta",
	7456326,
	"qfa-tor",
	"Latn",
}

m["stg"] = {
	"Trieng",
	22694648,
	"mkh-ban",
}

m["sth"] = {
	"Shelta",
	36705,
	"crp",
	"Latn",
	ancestors = "en",
}

m["sti"] = {
	"tiếng Xtiêng",
	15771431,
	"mkh-ban",
	"Khmr, Latn",
	"Tiếng Xtiêng",
	"Xtiêng",
}

m["stj"] = {
	"Matya Samo",
	10974879,
	"dmn-sam",
	"Latn",
}

m["stk"] = {
	"Arammba",
	3502094,
	"ngf",
}

m["stm"] = {
	"Setaman",
	7456333,
	"ngf-okk",
	"Latn",
}

m["stn"] = {
	"Owa",
	1324132,
	"poz-sls",
	"Latn",
}

m["sto"] = {
	"Stoney",
	3033570,
	"sio-dkt",
}

m["stp"] = {
	"tiếng Tepehuan Đông Nam",
	12953917,
	"azc",
	"Latn",
	"Tiếng Tepehuan Đông Nam",
	"Tepehuan Đông Nam",
}

m["stq"] = {
	"tiếng Frisia Saterland",
	27154,
	"gmw-fri",
	"Latn",
	"Tiếng Frisia Saterland",
	"Frisia Saterland",
}

m["str"] = {
	"tiếng Saanich",
	36444,
	"sal",
	"Latn",
	"Tiếng Saanich",
	"Saanich",
}

m["sts"] = {
	"Shumashti",
	33777,
	"inc-kun",
}

m["stt"] = {
	"tiếng Xtiêng Bù Đeh",
	12953891,
	"mkh-ban",
	"Latn",
	"Tiếng Xtiêng Bù Đeh",
	"Xtiêng Bù Đeh",
}

m["stu"] = {
	"tiếng Samtao",
	25559550,
	"mkh-pal",
	"Latn, Mymr",
	"Tiếng Samtao",
	"Samtao"
}

m["stv"] = {
	"tiếng Siltʼe",
	nil,
	"sem-eth",
	"Ethi",
	"Tiếng Siltʼe",
	"Siltʼe",
}

m["stw"] = {
	"Satawalese",
	28477,
	"poz-mic",
}

m["sty"] = {
	"tiếng Tatar Siberia",
	4418344,
	"trk-kno",
	"Cyrl",
	"Tiếng Tatar Siberia",
	"Tatar Siberia",
	translit = "sty-translit"
}

m["sua"] = {
	"Sulka",
	7636341,
	"qfa-iso",
}

m["sub"] = {
	"Suku",
	12953160,
	"bnt-yak",
	"Latn",
}

m["suc"] = {
	"Western Subanon",
	16113894,
	"phi",
	"Latn",
}

m["sue"] = {
	"Suena",
	7634386,
	"ngf",
	"Latn",
}

m["sug"] = {
	"Suganga",
	7634706,
	"ngf-okk",
	"Latn",
}

m["sui"] = {
	"Suki",
	2089984,
	"ngf",
	"Latn",
}

m["suk"] = {
	"Sukuma",
	2638144,
	"bnt-tkm",
	"Latn",
}

m["suq"] = {
	"tiếng Suri",
	5364172,
	"sdv",
	"Latn, Ethi",
	"Tiếng Suri",
	"Suri",
}

m["sur"] = {
	"Mwaghavul",
	3440486,
	"cdc-wst",
	"Latn",
}

m["sus"] = {
	"tiếng Susu",
	33990,
	"dmn-sya",
	"Latn, Arab",
	"Tiếng Susu",
	"Susu",
}

m["sut"] = {
	"Subtiaba",
	3915405,
	"omq",
	"Latn",
}

m["suv"] = {
	"tiếng Puroik",
	56408,
	"sit-khb",
	"Latn, Beng",
	"Tiếng Puroik",
	"Puroik",
}

m["suw"] = {
	"Sumbwa",
	7637055,
	"bnt-glb",
	"Latn",
}

m["sux"] = {
	"tiếng Sumer",
	36790,
	"qfa-iso",
	"Xsux, Latn",
	"Tiếng Sumer",
	"Sumer",
}

m["suy"] = {
	"Suyá",
	3505859,
	"sai-nje",
	"Latn",
}

m["suz"] = {
	"Sunwar",
	56549,
	"sit-kiw",
	"Deva, Sunu"
}

m["sva"] = {
	"tiếng Svan",
	34067,
	"ccs",
	"Geor, Cyrl",
	"Tiếng Svan",
	"Svan",
	translit = "sva-translit",
	override_translit = true,
}

m["svb"] = {
	"Ulau-Suain",
	7878769,
	"poz-ocw",
	"Latn",
}

m["svc"] = {
	"Vincentian Creole English",
	3501785,
	"crp",
	"Latn",
	ancestors = "en",
}

m["sve"] = {
	"Serili",
	7454834,
	"poz-tim",
}

m["svk"] = {
	"Slovakian Sign Language",
	7541557,
	"sgn",
}

m["svm"] = {
	"Slavomolisano",
	36254,
	"zls",
	"Latn",
	ancestors = "sh",
}

m["svs"] = {
	"tiếng Savosavo",
	3130296,
	"qfa-dis",
	"Latn",
}

m["svx"] = {
	"Skalvian",
	3486125,
	"bat-wes",
	"Latn",
}

m["swb"] = {
	"tiếng Comoros Maore",
	34075,
	"bnt-com",
	"Latn, Arab",
	"Tiếng Comoros Maore",
	"Comoros Maore",
	sort_key = "bnt-com-sortkey",
}

m["swf"] = {
	"Sere",
	7453056,
	"nic-ser",
	"Latn",
}

m["swg"] = {
	"Swabian",
	327274,
	"gmw-hgm",
	"Latn",
	ancestors = "gsw",
}

m["swi"] = {
	"tiếng Thủy",
	3112388,
	"qfa-kms",
	"Latn, Shui, Hani",
	"Tiếng Thủy",
	"Thủy",
	sort_key = {Hani = "Hani-sortkey"},
}

m["swj"] = {
	"Sira",
	36599,
	"bnt-sir",
	"Latn",
}

m["swl"] = {
	"Swedish Sign Language",
	36558,
	"sgn",
}

m["swm"] = {
	"Samosa",
	7410037,
	"ngf-mad",
	"Latn",
}

m["swn"] = {
	"tiếng Sokna",
	2988323,
	"ber",
	nil,
	"Tiếng Sokna",
	"Sokna",
}

m["swo"] = {
	"Shanenawa",
	nil,
	"sai-pan",
	"Latn",
}

m["swp"] = {
	"Suau",
	3502368,
	"poz-ocw",
}

m["swq"] = {
	"Sharwa",
	56791,
	"cdc-cbm",
	"Latn",
}

m["swr"] = {
	"Saweru",
	3474649,
}

m["sws"] = {
	"Seluwasan",
	7448845,
	"poz-cet",
}

m["swt"] = {
	"Sawila",
	7428639,
}

m["swu"] = {
	"Suwawa",
	7650588,
	"phi",
}

m["sww"] = {
	"Sowa",
	7571843,
	"poz-vnc",
}

m["swx"] = {
	"Suruahá",
	3114402,
	"auf",
}

m["swy"] = {
	"Sarua",
	56261,
	"cdc-est",
	"Latn",
}

m["sxb"] = {
	"Suba",
	33916,
	"bnt-lok",
	"Latn",
}

m["sxc"] = {
	"Sicanian",
	36335,
}

m["sxe"] = {
	"Sighu",
	36431,
	"bnt-kel",
	"Latn",
}

m["sxg"] = {
	"Shixing",
	56337,
	"sit-nax",
	"Latn",
}

m["sxk"] = {
	"Southern Kalapuya",
	3192122,
	"nai-klp",
}

m["sxl"] = {
	"Selonian",
	36491,
	"bat-eas",
	"Latn",
}

m["sxm"] = {
	"Samre",
	6583615,
	"mkh-pea",
}

m["sxn"] = {
	"tiếng Sangir",
	25714758,
	"phi",
	"Latn",
	"Tiếng Sangir",
	"Sangir",
}

m["sxo"] = {
	"Sorothaptic",
	2762254,
}

m["sxr"] = {
	"tiếng Saaroa",
	716599,
	"map-tsu",
	"Latn",
	"Tiếng Saaroa",
	"Saaroa",
}

m["sxs"] = {
	"Sasaru",
	3913384,
	"alv-yek",
	"Latn",
}

-- "sxu" "Upper Saxon" IS SUBSUMED INTO "gmw-ecg" "East Central German"

m["sxw"] = {
	"tiếng Gbe Saxwe",
	7428892,
	"alv-pph",
	nil,
	"Tiếng Gbe Saxwe",
	"Gbe Saxwe",
}

m["sya"] = {
	"Siang",
	3482903,
}

m["syb"] = {
	"Central Subanen",
	12953893,
	"phi",
	"Latn",
}

m["syc"] = {
	"tiếng Syriac cổ điển",
	33538,
	"sem-are",
	"Syrc",
	"Tiếng Syriac cổ điển",
	"Syriac cổ điển",
	entry_name = {remove_diacritics = c.macron .. c.diaer .. c.macronbelow .. u(0x0730) .. "-" .. u(0x0748)},
}

m["syi"] = {
	"Seki",
	36547,
	"bnt-kel",
	"Latn",
}

m["syk"] = {
	"Sukur",
	56292,
	"cdc-cbm",
	"Latn",
}

m["syl"] = {
	"tiếng Sylhet",
	2044560,
	"inc-eas",
	"Sylo, Beng",
	"Tiếng Sylhet",
	"Sylhet",
	ancestors = "inc-obn",
	translit = "syl-translit",
}

m["sym"] = {
	"Maya Samo",
	10950421,
	"dmn-sam",
	"Latn",
}

m["syn"] = {
	"tiếng Senaya",
	33914,
	"sem-nna",
	"Syrc",
	"Tiếng Senaya",
	"Senaya",
}

m["syo"] = {
	"Suoy",
	7641864,
	"mkh-pea",
}

m["sys"] = {
	"Sinyar",
	56840,
	"csu",
	"Latn",
}

m["syw"] = {
	"Kagate",
	12952538,
	"sit-kyk",
	"Deva",
}

m["syx"] = {
	"Osamayi",
	7408415,
	"bnt-kel",
	"Latn",
}

m["syy"] = {
	"Al-Sayyid Bedouin Sign Language",
	2915457,
	"sgn",
}

m["sza"] = {
	"tiếng Semelai",
	3111827,
	"mkh-asl",
	"Latn",
	"Tiếng Semelai",
	"Semelai",
}

m["szb"] = {
	"tiếng Ngalum",
	11732516,
	"ngf-okk",
	"Latn",
	"Tiếng Ngalum",
	"Ngalum",
}

m["szc"] = {
	"tiếng Semaq Beri",
	7449119,
	"mkh-asl",
	"Latn",
	"Tiếng Semaq Beri",
	"Semaq Beri",
}

m["szd"] = {
	"Seru",
	7455488,
	"poz-bnn",
	"Latn",
}

m["sze"] = {
	"tiếng Seze",
	373683,
	"omv-mao",
	"Latn",
	"Tiếng Seze",
	"Seze",
}

m["szg"] = {
	"Sengele",
	7450555,
	"bnt-mon",
	"Latn",
}

m["szl"] = {
	"tiếng Silesia",
	30319,
	"zlw-lch",
	"Latn",
	"Tiếng Silesia",
	"Silesia",
	ancestors = "zlw-opl",
}

m["szn"] = {
	"Sula",
	3503403,
	"poz-cma",
	"Latn",
}

m["szp"] = {
	"Suabo",
	7630429,
	"ngf-sbh",
	"Latn",
}

m["szv"] = {
	"Isubu",
	35431,
	"bnt-saw",
	"Latn",
}

m["szw"] = {
	"Sawai",
	3447258,
	"poz-hce",
	"Latn",
}

m["szy"] = {
	"tiếng Sakizaya",
	718269,
	"map",
	"Latn",
	"Tiếng Sakizaya",
	"Sakizaya",
}

return require("Module:languages").finalizeData(m, "language")