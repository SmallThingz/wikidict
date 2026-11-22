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

m["jaa"] = {
	canonicalName = "Jamamadí",
	otherNames = {"Jamamadi", "Madi", "Jarawara", "Jarauára", "Jaruára", "Jarauara", "Jaruara"},
	family = "auf",
}

m["jab"] = {
	canonicalName = "Hyam",
	family = "alv",
}

m["jac"] = {
	canonicalName = "Jakaltek",
	otherNames = {"Jacalteco", "Jacaltec", "Jakalteko", "Popti'", "Popti", "Eastern Jacalteco", "Western Jacalteco"},
	scripts = {"Latn"},
	family = "myn",
}

m["jad"] = {
	canonicalName = "Jahanka",
	family = "dmn",
}

m["jae"] = {
	canonicalName = "Jabem",
	family = "poz-ocw",
}

m["jaf"] = {
	canonicalName = "Jara",
	family = "cdc",
}

m["jah"] = {
	canonicalName = "Jah Hut",
	family = "aav",
}

m["jaj"] = {
	canonicalName = "Zazao",
	family = "poz-ocw",
}

m["jal"] = {
	canonicalName = "Yalahatan",
	otherNames = {"Horuru", "Atamanu"},
	scripts = {"Latn"},
	family = "plf",
}

m["jam"] = {
	canonicalName = "Jamaican Creole",
	otherNames = {"Jamaican", "Jamaican Patois", "Patois", "Patwa"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["jao"] = {
	canonicalName = "Yanyuwa",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["jaq"] = {
	canonicalName = "Yaqay",
	family = "ngf",
}

m["jas"] = {
	canonicalName = "New Caledonian Javanese",
	family = "poz-sus",
}

m["jat"] = {
	canonicalName = "Jakati",
	family = "inc",
	ancestors = {"lah"},
}

m["jau"] = {
	canonicalName = "Yaur",
	family = "poz-hce",
}

m["jax"] = {
	canonicalName = "Jambi Malay",
	family = "poz-mly",
}

m["jay"] = {
	canonicalName = "Yan-nhangu",
	family = "aus-yol",
}

m["jaz"] = {
	canonicalName = "Jawe",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["jbe"] = {
	canonicalName = "Judeo-Berber",
	scripts = {"Hebr"},
	family = "ber",
}

m["jbj"] = {
	canonicalName = "Arandai",
	family = "ngf",
}

m["jbn"] = {
	canonicalName = "Nefusa",
	otherNames = {"Nefusi", "Nafusa", "Nafusi"},
	family = "ber",
}

m["jbo"] = {
	canonicalName = "Lojban",
	scripts = {"Latn"},
	family = "art",
}

m["jbr"] = {
	canonicalName = "Jofotek-Bromnya",
}

m["jbt"] = {
	canonicalName = "Jabutí",
	otherNames = {"Djeoromitxí", "Yabutí", "Djeoromitxi", "Jabuti", "Yabuti"},
	family = "sai-mje",
}

m["jbu"] = {
	canonicalName = "Jukun Takum",
	family = "nic-bco",
}

m["jcs"] = {
	canonicalName = "Jamaican Country Sign Language",
	family = "sgn",
}

m["jct"] = {
	canonicalName = "Krymchak",
	scripts = {"Latn", "Cyrl"},
	family = "trk",
}

m["jda"] = {
	canonicalName = "Jad",
}

m["jdg"] = {
	canonicalName = "Jadgali",
}

m["jdt"] = {
	canonicalName = "Judeo-Tat",
	otherNames = {"Juhuri", "Juvuri", "Juwuri"},
	scripts = {"Latn", "Cyrl", "Hebr"},
	family = "ira",
	ancestors = {"fa"},
	translit_module = "jdt-translit",
}

m["jeb"] = {
	canonicalName = "Jebero",
}

m["jee"] = {
	canonicalName = "Jerung",
}

m["jeg"] = {
	canonicalName = "Jeng",
	otherNames = {"Cheng"},
	family = "aav-ban",
}

m["jeh"] = {
	canonicalName = "Jeh",
	family = "mkh",
}

m["jei"] = {
	canonicalName = "Yei",
}

m["jek"] = {
	canonicalName = "Jeri Kuo",
}

m["jel"] = {
	canonicalName = "Yelmek",
}

m["jen"] = {
	canonicalName = "Dza",
}

m["jer"] = {
	canonicalName = "Jere",
}

m["jet"] = {
	canonicalName = "Manem",
}

m["jeu"] = {
	canonicalName = "Jonkor Bourmataguil",
}

m["jgb"] = {
	canonicalName = "Ngbee",
}

m["jgo"] = {
	canonicalName = "Ngomba",
	family = "bai",
}

m["jhi"] = {
	canonicalName = "Jehai",
}

m["jhs"] = {
	canonicalName = "Jhankot Sign Language",
	family = "sgn",
}

m["jia"] = {
	canonicalName = "Jina",
}

m["jib"] = {
	canonicalName = "Jibu",
}

m["jic"] = {
	canonicalName = "Tol",
}

m["jid"] = {
	canonicalName = "Bu",
}

m["jie"] = {
	canonicalName = "Jilbe",
}

m["jig"] = {
	canonicalName = "Jingulu",
}

m["jih"] = {
	canonicalName = "Shangzhai",
}

m["jii"] = {
	canonicalName = "Jiiddu",
	family = "cus",
}

m["jil"] = {
	canonicalName = "Jilim",
}

m["jim"] = {
	canonicalName = "Jimjimen",
	otherNames = {"Jimi", "Jimi (Cameroon)"},
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["jio"] = {
	canonicalName = "Jiamao",
}

m["jiq"] = {
	canonicalName = "Guanyinqiao",
}

m["jit"] = {
	canonicalName = "Jita",
}

m["jiu"] = {
	canonicalName = "Youle Jinuo",
	family = "tbq-lol",
}

m["jiv"] = {
	canonicalName = "Shuar",
	scripts = {"Latn"},
	family = "sai-jiv",
}

m["jiy"] = {
	canonicalName = "Buyuan Jinuo",
	family = "tbq-lol",
}

m["jje"] = {
	canonicalName = "Jeju",
	otherNames = {"Cheju", "Jejueo"},
	scripts = {"Kore"},
	family = "qfa-kor",
	translit_module = "ko-translit",
}

m["jka"] = {
	canonicalName = "Kaera",
}

m["jko"] = {
	canonicalName = "Kubo",
}

m["jkr"] = {
	canonicalName = "Koro (India)",
	otherNames = {"Koro"},
}

m["jku"] = {
	canonicalName = "Labir",
}

m["jle"] = {
	canonicalName = "Ngile",
}

m["jls"] = {
	canonicalName = "Jamaican Sign Language",
	family = "sgn",
}

m["jma"] = {
	canonicalName = "Dima",
}

m["jmb"] = {
	canonicalName = "Zumbun",
}

m["jmc"] = {
	canonicalName = "Machame",
}

m["jmd"] = {
	canonicalName = "Yamdena",
	scripts = {"Latn"},
	family = "plf",
}

m["jmi"] = {
	canonicalName = "Jimi",
	otherNames = {"Jimi (Nigeria)"},
	scripts = {"Latn"},
	family = "cdc-wst",
}

m["jml"] = {
	canonicalName = "Jumli",
}

m["jmn"] = {
	canonicalName = "Makuri Naga",
}

m["jmr"] = {
	canonicalName = "Kamara",
}

m["jmx"] = {
	canonicalName = "Western Juxtlahuaca Mixtec",
	family = "omq-mix",
}

m["jna"] = {
	canonicalName = "Jangshung",
}

m["jnd"] = {
	canonicalName = "Jandavra",
}

m["jng"] = {
	canonicalName = "Yangman",
}

m["jni"] = {
	canonicalName = "Janji",
}

m["jnj"] = {
	canonicalName = "Yemsa",
	otherNames = {"Yem", "Yemma", "Janjero", "Janjerinya", "Janjor", "Yangaro", "Zinjero"},
	family = "omv",
}

m["jnl"] = {
	canonicalName = "Rawat",
}

m["jns"] = {
	canonicalName = "Jaunsari",
}

m["job"] = {
	canonicalName = "Joba",
}

m["jod"] = {
	canonicalName = "Wojenaka",
}

m["jor"] = {
	canonicalName = "Jorá",
}

m["jos"] = {
	canonicalName = "Jordanian Sign Language",
	scripts = {"Sgnw"},
	family = "sgn",
}

m["jow"] = {
	canonicalName = "Jowulu",
}

m["jpr"] = {
	canonicalName = "Judeo-Persian",
	otherNames = {"Jidi", "Dzhidi", "Djudi"},
	scripts = {"Hebr"},
	family = "ira",
	ancestors = {"fa"},
}

m["jqr"] = {
	canonicalName = "Jaqaru",
	family = "sai-aym",
}

m["jra"] = {
	canonicalName = "Jarai",
	scripts = {"Latn"},
	family = "poz-msa",
}

m["jrb"] = {
	canonicalName = "Judeo-Arabic",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["jrr"] = {
	canonicalName = "Jiru",
}

m["jrt"] = {
	canonicalName = "Jorto",
}

m["jru"] = {
	canonicalName = "Japrería",
	family = "sai-car",
}

m["jsl"] = {
	canonicalName = "Japanese Sign Language",
	family = "sgn-jsl",
}

m["jua"] = {
	canonicalName = "Júma",
}

m["jub"] = {
	canonicalName = "Wannu",
}

m["juc"] = {
	canonicalName = "Jurchen",
	scripts = {"Jurc"},
	family = "tuw",
}

m["jud"] = {
	canonicalName = "Worodougou",
}

m["juh"] = {
	canonicalName = "Hõne",
}

m["juk"] = {
	canonicalName = "Wapan",
}

m["jul"] = {
	canonicalName = "Jirel",
}

m["jum"] = {
	canonicalName = "Jumjum",
	family = "sdv",
}

m["jun"] = {
	canonicalName = "Juang",
	family = "mun",
}

m["juo"] = {
	canonicalName = "Jiba",
}

m["jup"] = {
	canonicalName = "Hupdë",
}

m["jur"] = {
	canonicalName = "Jurúna",
	family = "tup",
}

m["jus"] = {
	canonicalName = "Jumla Sign Language",
	family = "sgn",
}

m["jut"] = {
	canonicalName = "Jutish",
	otherNames = {"Jutlandic"},
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"da"},
}

m["juu"] = {
	canonicalName = "Ju",
}

m["juw"] = {
	canonicalName = "Wãpha",
	family = "nic-bco",
}

m["juy"] = {
	canonicalName = "Juray",
	family = "mun",
}

m["jvd"] = {
	canonicalName = "Javindo",
}

m["jvn"] = {
	canonicalName = "Caribbean Javanese",
	family = "poz-sus",
}

m["jwi"] = {
	canonicalName = "Jwira-Pepesa",
	family = "alv-kwa",
}

m["jye"] = {
	canonicalName = "Judeo-Yemeni Arabic",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["jyy"] = {
	canonicalName = "Jaya",
}

return m