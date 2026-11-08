local u = mw.ustring.char

-- UTF-8 encoded strings for some commonly-used diacritics
local GRAVE     = u(0x0300)
local ACUTE     = u(0x0301)
local CIRC      = u(0x0302)
local TILDE     = u(0x0303)
local MACRON    = u(0x0304)
local BREVE     = u(0x0306)
local DOTABOVE  = u(0x0307)
local DIAER     = u(0x0308)
local CARON     = u(0x030C)
local DGRAVE    = u(0x030F)
local INVBREVE  = u(0x0311)
local DOTBELOW  = u(0x0323)
local RINGBELOW = u(0x0325)
local CEDILLA   = u(0x0327)

local m = {}

m["zaa"] = {
	canonicalName = "Sierra de Juárez Zapotec",
	family = "omq-zap",
}

m["zab"] = {
	canonicalName = "San Juan Guelavía Zapotec",
	family = "omq-zap",
}

m["zac"] = {
	canonicalName = "Ocotlán Zapotec",
	family = "omq-zap",
}

m["zad"] = {
	canonicalName = "Cajonos Zapotec",
	family = "omq-zap",
}

m["zae"] = {
	canonicalName = "Yareni Zapotec",
	family = "omq-zap",
}

m["zaf"] = {
	canonicalName = "Ayoquesco Zapotec",
	family = "omq-zap",
}

m["zag"] = {
	canonicalName = "Zaghawa",
	otherNames = {"Zakhawa", "Beria"},
	family = "ssa",
}

m["zah"] = {
	canonicalName = "Zangwal",
	family = "cdc",
}

m["zai"] = {
	canonicalName = "Isthmus Zapotec",
	scripts = {"Latn"},
	family = "omq-zap",
}

m["zaj"] = {
	canonicalName = "Zaramo",
	scripts = {"Latn"},
	family = "bnt",
}

m["zak"] = {
	canonicalName = "Zanaki",
	family = "bnt",
}

m["zal"] = {
	canonicalName = "Zauzou",
	family = "tbq-lol",
}

m["zam"] = {
	canonicalName = "Central Mahuatlán Zapoteco",
	family = "omq-zap",
}

m["zao"] = {
	canonicalName = "Ozolotepec Zapotec",
	family = "omq-zap",
}

m["zap"] = {
	canonicalName = "Zapotec",
	family = "omq-zap",
}

m["zaq"] = {
	canonicalName = "Aloápam Zapotec",
	family = "omq-zap",
}

m["zar"] = {
	canonicalName = "Rincón Zapotec",
	family = "omq-zap",
}

m["zas"] = {
	canonicalName = "Santo Domingo Albarradas Zapotec",
	family = "omq-zap",
}

m["zat"] = {
	canonicalName = "Tabaa Zapotec",
	family = "omq-zap",
}

m["zau"] = {
	canonicalName = "Zangskari",
	otherNames = {"Zanskari"},
	family = "tbq",
	ancestors = {"xct"},
}

m["zav"] = {
	canonicalName = "Yatzachi Zapotec",
	scripts = {"Latn"},
	family = "omq-zap",
}

m["zaw"] = {
	canonicalName = "Mitla Zapotec",
	family = "omq-zap",
}

m["zax"] = {
	canonicalName = "Xadani Zapotec",
	family = "omq-zap",
}

m["zay"] = {
	canonicalName = "Zayse-Zergulla",
	family = "omv",
}

m["zaz"] = {
	canonicalName = "Zari",
	family = "cdc",
}

m["zbt"] = {
	canonicalName = "Batui",
	family = "poz-slb",
}

m["zca"] = {
	canonicalName = "Coatecas Altas Zapotec",
	family = "omq-zap",
}

m["zch"] = {
	canonicalName = "Central Hongshuihe Zhuang",
	family = "tai",
}

m["zdj"] = {
	canonicalName = "Ngazidja Comorian",
	otherNames = {"Ngazidja", "Shingazidja"},
	family = "bnt",
}

m["zea"] = {
	canonicalName = "Zealandic",
	family = "gmw",
	ancestors = {"dum"},
}

m["zeg"] = {
	canonicalName = "Zenag",
	family = "poz-ocw",
}

m["zeh"] = {
	canonicalName = "Eastern Hongshuihe Zhuang",
	family = "tai",
}

m["zen"] = {
	canonicalName = "Zenaga",
	scripts = {"Latn"},
	family = "ber",
}

m["zga"] = {
	canonicalName = "Kinga",
	family = "bnt",
}

m["zgb"] = {
	canonicalName = "Guibei Zhuang",
	family = "tai",
}

m["zgh"] = {
	canonicalName = "Standard Moroccan Tamazight",
	scripts = {"Tfng"},
	family = "ber",
}

m["zgm"] = {
	canonicalName = "Minz Zhuang",
	family = "tai",
}

m["zgn"] = {
	canonicalName = "Guibian Zhuang",
	family = "tai",
}

m["zgr"] = {
	canonicalName = "Magori",
	family = "poz-ocw",
}

m["zhb"] = {
	canonicalName = "Zhaba",
	family = "sit",
}

m["zhd"] = {
	canonicalName = "Dai Zhuang",
	family = "tai",
}

m["zhi"] = {
	canonicalName = "Zhire",
	otherNames = {"Shang"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["zhn"] = {
	canonicalName = "Nong Zhuang",
	family = "tai",
}

m["zhw"] = {
	canonicalName = "Zhoa",
	family = "nic-grf",
}

m["zia"] = {
	canonicalName = "Zia",
	family = "ngf",
}

m["zib"] = {
	canonicalName = "Zimbabwe Sign Language",
	family = "sgn",
}

m["zik"] = {
	canonicalName = "Zimakani",
	family = "ngf",
}

m["zil"] = {
	canonicalName = "Zialo",
	family = "dmn"} 
m["zim"] = {
	canonicalName = "Mesme",
	family = "cdc",
}

m["zin"] = {
	canonicalName = "Zinza",
	family = "bnt",
}

m["zir"] = {
	canonicalName = "Ziriya",
	family = "nic-knj",
}

m["ziw"] = {
	canonicalName = "Zigula",
	family = "bnt",
}

m["ziz"] = {
	canonicalName = "Zizilivakan",
	family = "cdc",
}

m["zka"] = {
	canonicalName = "Kaimbulawa",
	family = "poz-mun",
}

m["zkb"] = {
	canonicalName = "Koibal",
	family = "syd",
}

m["zkg"] = {
	canonicalName = "Goguryeo",
	scripts = {"Hani"},
}

m["zkh"] = {
	canonicalName = "Khorezmian Turkic",
	otherNames = {"Khorezmian", "Khorezmian-Turkic"},
	scripts = {"Arab"},
	family = "trk",
}

m["zkk"] = {
	canonicalName = "Karankawa",
}

m["zko"] = {
	canonicalName = "Kott",
	scripts = {"Latn"},
	family = "qfa-yen",
}

m["zkp"] = {
	canonicalName = "São Paulo Kaingáng",
	family = "sai-jee",
}

m["zkr"] = {
	canonicalName = "Zakhring",
	family = "sit",
}

m["zkt"] = {
	canonicalName = "Khitan",
	family = "xgn",
}

m["zku"] = {
	canonicalName = "Kaurna",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["zkv"] = {
	canonicalName = "Krevinian",
	family = "fiu-fin",
	ancestors = {"vot"},
}

m["zkz"] = {
	canonicalName = "Khazar",
	scripts = {"Orkh"},
	family = "trk",
}

m["zlj"] = {
	canonicalName = "Liujiang Zhuang",
	family = "tai",
}

m["zln"] = {
	canonicalName = "Lianshan Zhuang",
	family = "tai",
}

m["zlq"] = {
	canonicalName = "Liuqian Zhuang",
	family = "tai",
}

m["zma"] = {
	canonicalName = "Australian Manda",
	family = "aus-dal",
}

m["zmb"] = {
	canonicalName = "Zimba",
	scripts = {"Latn"},
	family = "bnt",
}

m["zmc"] = {
	canonicalName = "Margany",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["zmd"] = {
	canonicalName = "Maridan",
	family = "aus-dal",
}

m["zme"] = {
	canonicalName = "Mangerr",
}

m["zmf"] = {
	canonicalName = "Mfinu",
	family = "bnt",
}

m["zmg"] = {
	canonicalName = "Marti Ke",
	scripts = {"Latn"},
	family = "aus-dal",
}

m["zmh"] = {
	canonicalName = "Makolkol",
}

m["zmi"] = {
	canonicalName = "Negeri Sembilan Malay",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["zmj"] = {
	canonicalName = "Maridjabin",
	family = "aus-dal",
}

m["zmk"] = {
	canonicalName = "Mandandanyi",
	family = "aus-pam",
}

m["zml"] = {
	canonicalName = "Madngele",
	family = "aus-dal",
}

m["zmm"] = {
	canonicalName = "Marimanindji",
	family = "aus-dal",
}

m["zmn"] = {
	canonicalName = "Mbangwe",
	family = "bnt",
}

m["zmo"] = {
	canonicalName = "Molo",
	family = "sdv",
}

m["zmp"] = {
	canonicalName = "Mpuono",
	family = "bnt",
}

m["zmq"] = {
	canonicalName = "Mituku",
	family = "bnt",
}

m["zmr"] = {
	canonicalName = "Maranungku",
	otherNames = {"Maranunggu", "Marranunggu", "Marranungku", "Maranunga", "Marranungga", "Maranunggo"},
	family = "aus-dal",
}

m["zms"] = {
	canonicalName = "Mbesa",
	family = "bnt",
}

m["zmt"] = {
	canonicalName = "Maringarr",
	family = "aus-dal",
}

m["zmu"] = {
	canonicalName = "Muruwari",
	family = "aus-pam",
}

m["zmv"] = {
	canonicalName = "Mbariman-Gudhinma",
	family = "aus-pmn",
}

m["zmw"] = {
	canonicalName = "Mbo (Congo)",
	otherNames = {"Mbo (Democratic Republic of the Congo)", "Mbo"},
	family = "bnt",
}

m["zmx"] = {
	canonicalName = "Bomitaba",
	family = "bnt",
}

m["zmy"] = {
	canonicalName = "Mariyedi",
	family = "aus-dal",
}

m["zmz"] = {
	canonicalName = "Mbandja",
	family = "bad",
}

m["zna"] = {
	canonicalName = "Zan Gula",
	family = "alv-sav",
}

m["zne"] = {
	canonicalName = "Zande",
	scripts = {"Latn"},
	family = "znd",
}

m["zng"] = {
	canonicalName = "Mang",
	family = "mkh",
}

m["znk"] = {
	canonicalName = "Manangkari",
	otherNames = {"Naragani"},
	family = "aus-wdj",
}

m["zns"] = {
	canonicalName = "Mangas",
	family = "cdc",
}

m["zoc"] = {
	canonicalName = "Copainalá Zoque",
	family = "nai-miz",
}

m["zoh"] = {
	canonicalName = "Chimalapa Zoque",
	family = "nai-miz",
}

m["zom"] = {
	canonicalName = "Zou",
	otherNames = {"Zo", "Yo", "Yos"},
	family = "tbq-kuk",
}

m["zoo"] = {
	canonicalName = "Asunción Mixtepec Zapotec",
	family = "omq-zap",
}

m["zoq"] = {
	canonicalName = "Tabasco Zoque",
	family = "nai-miz",
}

m["zor"] = {
	canonicalName = "Rayón Zoque",
	family = "nai-miz",
}

m["zos"] = {
	canonicalName = "Francisco León Zoque",
	family = "nai-miz",
}

m["zpa"] = {
	canonicalName = "Lachiguiri Zapotec",
	family = "omq-zap",
}

m["zpb"] = {
	canonicalName = "Yautepec Zapotec",
	family = "omq-zap",
}

m["zpc"] = {
	canonicalName = "Choapan Zapotec",
	otherNames = {"Choapan Zapoteco"},
	family = "omq-zap",
}

m["zpd"] = {
	canonicalName = "Southeastern Ixtlán Zapotec",
	family = "omq-zap",
}

m["zpe"] = {
	canonicalName = "Petapa Zapotec",
	family = "omq-zap",
}

m["zpf"] = {
	canonicalName = "San Pedro Quiatoni Zapotec",
	family = "omq-zap",
}

m["zpg"] = {
	canonicalName = "Guevea de Humboldt Zapotec",
	family = "omq-zap",
}

m["zph"] = {
	canonicalName = "Totomachapan Zapotec",
	family = "omq-zap",
}

m["zpi"] = {
	canonicalName = "Santa María Quiegolani Zapotec",
	family = "omq-zap",
}

m["zpj"] = {
	canonicalName = "Quiavicuzas Zapotec",
	family = "omq-zap",
}

m["zpk"] = {
	canonicalName = "Tlacolulita Zapotec",
	family = "omq-zap",
}

m["zpl"] = {
	canonicalName = "Lachixío Zapotec",
	family = "omq-zap",
}

m["zpm"] = {
	canonicalName = "Mixtepec Zapotec",
	family = "omq-zap",
}

m["zpn"] = {
	canonicalName = "Santa Inés Yatzechi Zapotec",
	family = "omq-zap",
}

m["zpo"] = {
	canonicalName = "Amatlán Zapotec",
	family = "omq-zap",
}

m["zpp"] = {
	canonicalName = "El Alto Zapotec",
	otherNames = {"El Alto Zapoteco"},
	family = "omq-zap",
}

m["zpq"] = {
	canonicalName = "Zoogocho Zapotec",
	scripts = {"Latn"},
	family = "omq-zap",
}

m["zpr"] = {
	canonicalName = "Santiago Xanica Zapotec",
	family = "omq-zap",
}

m["zps"] = {
	canonicalName = "Coatlán Zapotec",
	family = "omq-zap",
}

m["zpt"] = {
	canonicalName = "San Vicente Coatlán Zapotec",
	family = "omq-zap",
}

m["zpu"] = {
	canonicalName = "Yalálag Zapotec",
	family = "omq-zap",
}

m["zpv"] = {
	canonicalName = "Chichicapan Zapotec",
	family = "omq-zap",
}

m["zpw"] = {
	canonicalName = "Zaniza Zapotec",
	family = "omq-zap",
}

m["zpx"] = {
	canonicalName = "San Baltazar Loxicha Zapotec",
	family = "omq-zap",
}

m["zpy"] = {
	canonicalName = "Mazaltepec Zapotec",
	family = "omq-zap",
}

m["zpz"] = {
	canonicalName = "Texmelucan Zapotec",
	family = "omq-zap",
}

m["zqe"] = {
	canonicalName = "Qiubei Zhuang",
	family = "tai",
}

m["zra"] = {
	canonicalName = "Kaya",
	otherNames = {"Kara"},
}

m["zrg"] = {
	canonicalName = "Mirgan",
	otherNames = {"Panika"},
	family = "inc",
	ancestors = {"pka"},
}

m["zrn"] = {
	canonicalName = "Zirenkel",
	family = "cdc",
}

m["zro"] = {
	canonicalName = "Záparo",
	scripts = {"Latn"},
	family = "sai-zap",
}

m["zrs"] = {
	canonicalName = "Mairasi",
	family = "paa-mai",
}

m["zsa"] = {
	canonicalName = "Sarasira",
	family = "poz-ocw",
}

m["zsk"] = {
	canonicalName = "Kaskean",
	otherNames = {"Kaskian"},
}

m["zsl"] = {
	canonicalName = "Zambian Sign Language",
	family = "sgn",
}

m["zsr"] = {
	canonicalName = "Southern Rincon Zapotec",
	family = "omq-zap",
}

m["zsu"] = {
	canonicalName = "Sukurum",
	family = "poz-ocw",
}

m["zte"] = {
	canonicalName = "Elotepec Zapotec",
	family = "omq-zap",
}

m["ztg"] = {
	canonicalName = "Xanaguía Zapotec",
	family = "omq-zap",
}

m["ztl"] = {
	canonicalName = "Lapaguía-Guivini Zapotec",
	family = "omq-zap",
}

m["ztm"] = {
	canonicalName = "San Agustín Mixtepec Zapotec",
	family = "omq-zap",
}

m["ztn"] = {
	canonicalName = "Santa Catarina Albarradas Zapotec",
	family = "omq-zap",
}

m["ztp"] = {
	canonicalName = "Loxicha Zapotec",
	family = "omq-zap",
}

m["ztq"] = {
	canonicalName = "Quioquitani-Quierí Zapotec",
	family = "omq-zap",
}

m["zts"] = {
	canonicalName = "Tilquiapan Zapotec",
	family = "omq-zap",
}

m["ztt"] = {
	canonicalName = "Tejalapan Zapotec",
	family = "omq-zap",
}

m["ztu"] = {
	canonicalName = "San Pablo Güilá Zapotec",
	family = "omq-zap",
}

m["ztx"] = {
	canonicalName = "Zaachila Zapotec",
	otherNames = {"Zaachila Zapoteco"},
	family = "omq-zap",
}

m["zty"] = {
	canonicalName = "Yatee Zapotec",
	family = "omq-zap",
}

m["zua"] = {
	canonicalName = "Zeem",
	family = "cdc",
}

m["zuh"] = {
	canonicalName = "Tokano",
	family = "ngf",
}

m["zum"] = {
	canonicalName = "Kumzari",
	family = "ira",
}

m["zun"] = {
	canonicalName = "Zuni",
	otherNames = {"Zuñi", "Shiwi'ma"},
	scripts = {"Latn"},
}

m["zuy"] = {
	canonicalName = "Zumaya",
	family = "cdc",
}

m["zwa"] = {
	canonicalName = "Zay",
	family = "sem-eth",
}

m["zyb"] = {
	canonicalName = "Yongbei Zhuang",
	family = "tai",
}

m["zyg"] = {
	canonicalName = "Yang Zhuang",
	family = "tai",
}

m["zyj"] = {
	canonicalName = "Youjiang Zhuang",
	family = "tai",
}

m["zyn"] = {
	canonicalName = "Yongnan Zhuang",
	family = "tai",
}

m["zyp"] = {
	canonicalName = "Zyphe",
	otherNames = {"Zyphe Chin", "Zophei", "Zoptei", "Vawngtu"},
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["zza"] = {
	canonicalName = "Zazaki",
	scripts = {"Latn"},
	family = "ira",
	wikimedia_codes = {"diq"},
}

m["zzj"] = {
	canonicalName = "Zuojiang Zhuang",
	family = "tai",
}

return m