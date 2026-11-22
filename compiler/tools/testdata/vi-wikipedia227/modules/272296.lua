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

m["zaa"] = {
	"tiếng Zapotec Sierra de Juárez",
	12953989,
	"omq-zap",
	"Latn",
	"Tiếng Zapotec Sierra de Juárez",
	"Zapotec Sierra de Juárez",
}

m["zab"] = {
	"tiếng Zapotec San Juan Guelavía",
	5614751,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec San Juan Guelavía",
	"Zapotec San Juan Guelavía"
}

m["zac"] = {
	"Ocotlán Zapotec",
	7076643,
	"omq-zap",
	"Latn",
}

m["zad"] = {
	"tiếng Zapotec Cajonos",
	5017997,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Cajonos",
	"Zapotec Cajonos",
}

m["zae"] = {
	"Yareni Zapotec",
	12645368,
	"omq-zap",
	"Latn",
}

m["zaf"] = {
	"Ayoquesco Zapotec",
	4831570,
	"omq-zpc",
	"Latn",
}

m["zag"] = {
	"tiếng Zaghawa",
	37007,
	"ssa-sah",
	"Latn", -- also Beria
	"Tiếng Zaghawa",
	"Zaghawa",
}

m["zah"] = {
	"Zangwal",
	3441387,
	"cdc-wst",
	"Latn",
}

m["zai"] = {
	"tiếng Zapotec Isthmus",
	56728,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Isthmus",
	"Zapotec Isthmus",
}

m["zaj"] = {
	"Zaramo",
	8066599,
	"bnt-ruv",
	"Latn",
}

m["zak"] = {
	"Zanaki",
	8066018,
	"bnt-lok",
	"Latn",
}

m["zal"] = {
	"Zauzou",
	3616358,
	"tbq-nus",
	"Latn, Hani",
	sort_key = {Hani = "Hani-sortkey"},
}

m["zam"] = {
	"Central Mahuatlán Zapoteco",
	13541830,
	"omq-zap",
	"Latn",
}

m["zao"] = {
	"Ozolotepec Zapotec",
	7116610,
	"omq-zap",
	"Latn",
}

m["zap"] = {
	"tiếng Zapotec",
	13214,
	"omq-zap",
	"Latn",
	"Tiếng Zapotec",
	"Zapotec",
}

m["zaq"] = {
	"Aloápam Zapotec",
	4734726,
	"omq-zap",
	"Latn",
}

m["zar"] = {
	"tiếng Zapotec Rincón",
	7334628,
	"omq-zap",
	"Latn",
	"Tiếng Zapotec Rincón",
	"Zapotec Rincón",
}

m["zas"] = {
	"Santo Domingo Albarradas Zapotec",
	4709425,
	"omq-zap",
	"Latn",
}

m["zat"] = {
	"Tabaa Zapotec",
	7672849,
	"omq-zap",
	"Latn",
}

m["zau"] = {
	"tiếng Zangskar",
	771203,
	"sit-lab",
	"Tibt",
	ancestors = "lbj",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
	"Tiếng Zangskar",
	"Zangskar",
}

m["zav"] = {
	"tiếng Zapotec Yatzachi",
	8050301,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Yatzachi",
	"Zapotec Yatzachi",
}

m["zaw"] = {
	"tiếng Zapotec Mitla",
	3053288,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Mitla",
	"Zapotec Mitla",
}

m["zax"] = {
	"Xadani Zapotec",
	8042823,
	"omq-zap",
	"Latn",
}

m["zay"] = {
	"tiếng Zayse-Zergulla",
	673895,
	"omv-eom",
	"Latn, Ethi",
	"Tiếng Zayse-Zergulla",
	"Zayse-Zergulla",
}

m["zaz"] = {
	"Zari",
	3914398,
	"cdc-wst",
	"Latn",
}

m["zbt"] = {
	"Batui",
	16839143,
	"poz-slb",
	"Latn",
}

m["zca"] = {
	"Coatecas Altas Zapotec",
	5138603,
	"omq-zap",
	"Latn",
}

m["zdj"] = {
	"Ngazidja Comorian",
	3114653,
	"bnt-com",
	"Latn",
	sort_key = "bnt-com-sortkey",
}

m["zea"] = {
	"tiếng Zeeland",
	237409,
	"gmw-frk",
	"Latn",
	"Tiếng Zeeland",
	"Zeeland",
	ancestors = "dum",
	sort_key = {
		from = {"^'([aeiouy].*)$"},
		to = {"%1'"}
	}
}

m["zeg"] = {
	"Zenag",
	12953345,
	"poz-ocw",
	"Latn",
}

m["zen"] = {
	"tiếng Zenaga",
	37005,
	"ber",
	"Latn, Tfng",
	"Tiếng Zenaga",
	"Zenaga",
	translit = {Tfng = "Tfng-translit"},
}

m["zga"] = {
	"Kinga",
	11005332,
	"bnt-bki",
	"Latn",
}

m["zgh"] = {
	"tiếng Tamazight Maroc chuẩn",
	7598268,
	"ber",
	"Tfng",
	"Tiếng Tamazight Maroc chuẩn",
	"Tamazight Maroc chuẩn",
	translit = "Tfng-translit",
}

m["zgr"] = {
	"tiếng Magori",
	3277370,
	"poz-ocw",
	"Latn",
	"Tiếng Magori",
	"Magori",
}

m["zhb"] = {
	"tiếng Trát Bá",
	56334,
	"sit-qia",
	"Latn",
	"Tiếng Trát Bá",
	"Trát Bá",
}

m["zhi"] = {
	"Zhire",
	3914910,
	"nic-plc",
	"Latn",
}

m["zhn"] = {
	"tiếng Tráng Nông",
	7049385,
	"tai-cen",
	"Latn",
	"Tiếng Tráng Nông",
	"Tráng Nông",
	sort_key = {remove_diacritics = "%p"},
}

m["zhw"] = {
	"Zhoa",
	8070885,
	"nic-rnw",
	"Latn",
}

m["zia"] = {
	"Zia",
	3038636,
	"ngf",
	"Latn",
}

m["zib"] = {
	"Zimbabwe Sign Language",
	8072097,
	"sgn",
}

m["zik"] = {
	"Zimakani",
	56740,
	"ngf",
	"Latn",
}

m["zil"] = {
	"Zialo",
	36991,
	"dmn-msw",
	"Latn",
}

m["zim"] = {
	"Mesme",
	56282,
	"cdc-mas",
	"Latn",
}

m["zin"] = {
	"Zinza",
	8072460,
	"bnt-haj",
	"Latn",
}

m["zir"] = {
	"Ziriya",
	3913943,
	"nic-jer",
	"Latn",
}

m["ziw"] = {
	"Zigula",
	37010,
	"bnt-seu",
	"Latn",
}

m["ziz"] = {
	"Zizilivakan",
	56300,
	"cdc-cbm",
	"Latn",
}

m["zka"] = {
	"Kaimbulawa",
	6348011,
	"poz-mun",
	"Latn",
}

m["zkb"] = {
	"tiếng Koibal",
	949259,
	"syd",
	"Latn, Cyrl",
	"Tiếng Koibal",
	"Koibal",
}

m["zkd"] = {
	"tiếng Kadu",
	54324451,
	"sit-luu",
	"Latn, Mymr", -- and also unencoded Kadu script
	"Tiếng Kadu",
	"Kadu",
}

m["zkg"] = {
	"tiếng Cao Câu Ly",
	706327,
	"qfa-kor",
	"Hani",
	"Tiếng Cao Câu Ly",
	"Cao Câu Ly",
	sort_key = "Hani-sortkey",
}

m["zkh"] = {
	"tiếng Turk Khorezm",
	25502,
	"trk-kar",
	"Arab",
	"Tiếng Turk Khorezm",
	"Turk Khorezm",
	ancestors = "xqa",
}

m["zkk"] = {
	"Karankawa",
	3192947,
	nil,
	"Latn",
}

m["zkn"] = {
	"tiếng Kanan",
	54548740,
	"sit-luu",
	"Mymr",
	"Tiếng Kanan",
	"Kanan",
}

m["zko"] = {
	"tiếng Kott",
	34163,
	"qfa-yso",
	"Latn",
	"Tiếng Kott",
	"Kott",
}

m["zkp"] = {
	"São Paulo Kaingáng",
	7665661,
	"sai-jee",
	"Latn",
}

m["zkr"] = {
	"Zakhring",
	56996,
	"sit-mdz",
	"Latn, Hani",
	sort_key = {Hani = "Hani-sortkey"},
}

m["zkt"] = {
	"tiếng Khiết Đan",
	1064482,
	"qfa-xgx",
	"Kitl, Kits, Hani",
	"Tiếng Khiết Đan",
	"Khiết Đan",
	translit = {Kits = "zkt-translit"},
	sort_key = {Hani = "Hani-sortkey"},
}

m["zku"] = {
	"tiếng Kaurna",
	6378899,
	"aus-psw",
	"Latn",
	"Tiếng Kaurna",
	"Kaurna",
}

m["zkv"] = {
	"Krevinian",
	6436902,
	"urj-fin",
	"Latn",
	ancestors = "vot",
}

m["zkz"] = {
	"tiếng Khazar",
	1067986,
	"trk",
	"Orkh",
	"Tiếng Khazar",
	"Khazar",
}

m["zma"] = {
	"Manda (Australia)",
	18650060,
	"aus-dal",
	"Latn",
}

m["zmb"] = {
	"Zimba",
	8071960,
	"bnt-lgb",
	"Latn",
}

m["zmc"] = {
	"Margany",
	10577017,
	"aus-pam",
	"Latn",
}

m["zmd"] = {
	"Maridan",
	10577273,
	"aus-dal",
	"Latn",
}

m["zme"] = {
	"Mangerr",
	10576387,
	nil,
	"Latn",
}

m["zmf"] = {
	"Mfinu",
	35915,
	"bnt-tek",
	"Latn",
}

m["zmg"] = {
	"Marti Ke",
	10577823,
	"aus-dal",
	"Latn",
}

m["zmh"] = {
	"Makolkol",
	12636052,
	"paa-bng",
	"Latn",
}

m["zmi"] = {
	"Negeri Sembilan Malay",
	3915909,
	"poz-mly",
	"Latn",
}

m["zmj"] = {
	"Maridjabin",
	10577274,
	"aus-dal",
	"Latn",
}

m["zmk"] = {
	"Mandandanyi",
	10576338,
	"aus-pam",
	"Latn",
}

m["zml"] = {
	"Madngele",
	10575155,
	"aus-dal",
	"Latn",
}

m["zmm"] = {
	"Marimanindji",
	10577424,
	"aus-dal",
	"Latn",
}

m["zmn"] = {
	"Mbangwe",
	35928,
	"bnt-kel",
	"Latn",
}

m["zmo"] = {
	"Molo",
	15974357,
	"sdv-eje",
	"Latn",
}

m["zmp"] = {
	"Mbuun",
	106249400,
	"bnt",
	"Latn",
}

m["zmq"] = {
	"Mituku",
	6883590,
	"bnt-mbe",
	"Latn",
}

m["zmr"] = {
	"Maranungku",
	6772792,
	"aus-dal",
	"Latn",
}

m["zms"] = {
	"Mbesa",
	6799676,
	"bnt-ske",
	"Latn",
}

m["zmt"] = {
	"Maringarr",
	10577443,
	"aus-dal",
	"Latn",
}

m["zmu"] = {
	"Muruwari",
	3915442,
	"aus-pam",
	"Latn",
}

m["zmv"] = {
	"Mbariman-Gudhinma",
	3915672,
	"aus-pmn",
	"Latn",
}

m["zmw"] = {
	"Mbo (Congo)",
	6799710,
	"bnt-nya",
	"Latn",
}

m["zmx"] = {
	"Bomitaba",
	35063,
	"bnt-ngn",
	"Latn",
}

m["zmy"] = {
	"Mariyedi",
	10577501,
	"aus-dal",
	"Latn",
}

m["zmz"] = {
	"Mbandja",
	3915310,
	"bad",
	"Latn",
}

m["zna"] = {
	"Zan Gula",
	863726,
	"alv-bua",
	"Latn",
}

m["zne"] = {
	"Zande",
	35015,
	"znd",
	"Latn",
}

m["zng"] = {
	"tiếng Mảng",
	720192,
	"mkh-mng",
	nil,
	"Tiếng Mảng",
	"Mảng",
}

m["znk"] = {
	"Manangkari",
	6746906,
	"aus-wdj",
	"Latn",
}

m["zns"] = {
	"tiếng Mangas",
	3438780,
	"cdc-wst",
	"Latn",
	"Tiếng Mangas",
	"Mangas",
}

m["zoc"] = {
	"Copainalá Zoque",
	12954017,
	"nai-miz",
	"Latn",
}

m["zoh"] = {
	"Chimalapa Zoque",
	5099289,
	"nai-miz",
	"Latn",
}

m["zom"] = {
	"tiếng Zou",
	37011,
	"tbq-kuk",
	"Latn",
	"Tiếng Zou",
	"Zou",
	strip_diacritics = {remove_diacritics = c.circ .. c.acute .. c.grave .. c.dacute .. c.dgrave},
}

m["zoo"] = {
	"Asunción Mixtepec Zapotec",
	4811888,
	"omq-zap",
	"Latn",
}

m["zoq"] = {
	"Tabasco Zoque",
	323325,
	"nai-miz",
	"Latn",
}

m["zor"] = {
	"Rayón Zoque",
	12954015,
	"nai-miz",
	"Latn",
}

m["zos"] = {
	"tiếng Zoque Francisco León",
	12954011,
	"nai-miz",
	"Latn",
	"Tiếng Zoque Francisco León",
	"Zoque Francisco León",
}

m["zpa"] = {
	"Lachiguiri Zapotec",
	6468403,
	"omq-zap",
	"Latn",
}

m["zpb"] = {
	"Yautepec Zapotec",
	7413392,
	"omq-zap",
	"Latn",
}

m["zpc"] = {
	"tiếng Zapotec Choapan",
	5103425,
	"omq-zap",
	"Latn",
	"Tiếng Zapotec Choapan",
	"Zapotec Choapan",
}

m["zpd"] = {
	"Southeastern Ixtlán Zapotec",
	8050392,
	"omq-zap",
	"Latn",
}

m["zpe"] = {
	"Petapa Zapotec",
	7171675,
	"omq-zap",
	"Latn",
}

m["zpf"] = {
	"San Pedro Quiatoni Zapotec",
	7271640,
	"omq-zpc",
	"Latn",
}

m["zpg"] = {
	"Guevea de Humboldt Zapotec",
	13459953,
	"omq-zap",
	"Latn",
}

m["zph"] = {
	"Totomachapan Zapotec",
	7828390,
	"omq-zap",
	"Latn",
}

m["zpi"] = {
	"Santa María Quiegolani Zapotec",
	7271823,
	"omq-zpc",
	"Latn",
}

m["zpj"] = {
	"Quiavicuzas Zapotec",
	7271642,
	"omq-zap",
	"Latn",
}

m["zpk"] = {
	"Tlacolulita Zapotec",
	7810685,
	"omq-zpc",
	"Latn",
}

m["zpl"] = {
	"Lachixío Zapotec",
	6468420,
	"omq-zap",
	"Latn",
}

m["zpm"] = {
	"Mixtepec Zapotec",
	7414598,
	"omq-zpc",
	"Latn",
}

m["zpn"] = {
	"Santa Inés Yatzechi Zapotec",
	8050300,
	"omq-zap",
	"Latn",
}

m["zpo"] = {
	"Amatlán Zapotec",
	4740613,
	"omq-zpc",
	"Latn",
}

m["zpp"] = {
	"El Alto Zapotec",
	5350733,
	"omq-zap",
	"Latn",
}

m["zpq"] = {
	"tiếng Zapotec Zoogocho",
	8074100,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Zoogocho",
	"Zapotec Zoogocho",
}

m["zpr"] = {
	"Santiago Xanica Zapotec",
	8042924,
	"omq-zap",
	"Latn",
}

m["zps"] = {
	"Coatlán Zapotec",
	7420514,
	"omq-zap",
	"Latn",
}

m["zpt"] = {
	"San Vicente Coatlán Zapotec",
	13541831,
	"omq-zap",
	"Latn",
}

m["zpu"] = {
	"Yalálag Zapotec",
	8047534,
	"omq-zpc",
	"Latn",
}

m["zpv"] = {
	"Chichicapan Zapotec",
	5096050,
	"omq-zap",
	"Latn",
}

m["zpw"] = {
	"tiếng Zapotec Zaniza",
	8066220,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Zaniza",
	"Zapotec Zaniza",
}

m["zpx"] = {
	"San Baltazar Loxicha Zapotec",
	7413390,
	"omq-zap",
	"Latn",
}

m["zpy"] = {
	"Mazaltepec Zapotec",
	6798223,
	"omq-zap",
	"Latn",
}

m["zpz"] = {
	"Texmelucan Zapotec",
	7708357,
	"omq-zpc",
	"Latn",
}

m["zra"] = {
	"Kaya",
	5528695,
	"qfa-kor",
}

m["zrg"] = {
	"tiếng Mirga",
	6873206,
	"inc-eas",
	"Orya, Telu",
	"Tiếng Mirga",
	"Mirga",
}

m["zrn"] = {
	"tiếng Zirenkel",
	3441365,
	"cdc-est",
	"Latn",
	"Tiếng Zirenkel",
	"Zirenkel"
}

m["zro"] = {
	"Záparo",
	10206,
	"sai-zap",
	"Latn",
}

m["zrp"] = {
	"tiếng Zarphat",
	36994,
	nil,
	"Hebr",
	"Tiếng Zarphat",
	"Zarphat",
}

m["zrs"] = {
	"Mairasi",
	3038645,
	"paa-mai",
	"Latn",
}

m["zsa"] = {
	"Sarasira",
	nil,
	"poz-ocw",
}

m["zsk"] = { -- attested?
	"Kaskean",
	6374586,
}

m["zsl"] = {
	"Zambian Sign Language",
	8065713,
	"sgn",
}

m["zsr"] = {
	"tiếng Zapotec Rincón Nam",
	12954000,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Rincón Nam",
	"Zapotec Rincón Nam",
}

m["zsu"] = {
	"Sukurum",
	nil,
	"poz-ocw",
}

m["zte"] = {
	"Elotepec Zapotec",
	5367223,
	"omq-zap",
	"Latn",
}

m["ztg"] = {
	"Xanaguía Zapotec",
	8042887,
	"omq-zpc",
	"Latn",
}

m["ztl"] = {
	"Lapaguía-Guivini Zapotec",
	6488084,
	"omq-zap",
	"Latn",
}

m["ztm"] = {
	"San Agustín Mixtepec Zapotec",
	7413220,
	"omq-zap",
	"Latn",
}

m["ztn"] = {
	"Santa Catarina Albarradas Zapotec",
	7419277,
	"omq-zap",
	"Latn",
}

m["ztp"] = {
	"Loxicha Zapotec",
	6694268,
	"omq-zap",
	"Latn",
}

m["ztq"] = {
	"Quioquitani-Quierí Zapotec",
	3574818,
	"omq-zpc",
	"Latn",
}

m["zts"] = {
	"tiếng Zapotec Tilquiapan",
	7802959,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Tilquiapan",
	"Zapotec Tilquiapan",
}

m["ztt"] = {
	"Tejalapan Zapotec",
	13510225,
	"omq-zap",
	"Latn",
}

m["ztu"] = {
	"San Pablo Güilá Zapotec",
	5626813,
	"omq-zap",
	"Latn",
}

m["ztx"] = {
	"Zaachila Zapotec",
	8063390,
	"omq-zap",
	"Latn",
}

m["zty"] = {
	"tiếng Zapotec Yatee",
	3574815,
	"omq-zpc",
	"Latn",
	"Tiếng Zapotec Yatee",
	"Zapotec Yatee",
}

m["zua"] = {
	"Zeem",
	3450131,
	"cdc-wst",
	"Latn",
}

m["zuh"] = {
	"Tokano",
	7813481,
	"ngf",
	"Latn",
}

m["zum"] = {
	"tiếng Kumzar",
	36158,
	"ira-swi",
	"Arab",
	"Tiếng Kumzar",
	"Kumzar",
	ancestors = "pal",
}

m["zun"] = {
	"Zuni",
	10188,
	"qfa-iso",
	"Latn",
}

m["zuy"] = {
	"Zumaya",
	56626,
	"cdc-mas",
	"Latn",
}

m["zwa"] = {
	"tiếng Zay",
	10195,
	"sem-eth",
	"Ethi",
	"Tiếng Zay",
	"Zay",
}

m["zyg"] = {
	"tiếng Tráng Đức Tĩnh",
	8048537,
	"tai-cen",
	"Latn",
	"Tiếng Tráng Đức Tĩnh",
	"Tráng Đức Tĩnh",
}

m["zyp"] = {
	"Zyphe",
	57004,
	"tbq-kuk",
	"Latn",
}

m["zza"] = {
	"tiếng Zaza",
	10199,
	"ira-zgr",
	"Latn, Arab",
	"Tiếng Zaza",
	"Zaza",
	dotted_dotless_i = true,
	sort_key = "zza-sortkey",
	wikimedia_codes = "diq",
}

m["zzj"] = {
	"tiếng Tráng Tả Giang",
	13848149,
	"tai-cen",
	"Latn",
	"Tiếng Tráng Tả Giang",
	"Tráng Tả Giang",
	sort_key = {remove_diacritics = "%p"},
}

return require("Module:languages").finalizeData(m, "language")