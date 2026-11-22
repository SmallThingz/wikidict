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

m["jaa"] = {
	"tiếng Jamamadí",
	3053275,
	"auf",
	"Latn",
	"Tiếng Jamamadí",
	"Jamamadí",
}

m["jab"] = {
	"tiếng Hyam",
	35403,
	"nic-plc",
	"Latn",
	"Tiếng Hyam",
	"Hyam",
}

m["jac"] = {
	"tiếng Jacaltec",
	33393,
	"myn",
	"Latn",
	"Tiếng Jacaltec",
	"Jacaltec",
}

m["jad"] = {
	"Jahanka",
	3913992,
	"dmn-wmn",
	"Latn",
}

m["jae"] = {
	"Jabem",
	3571232,
	"poz-ocw",
	"Latn",
}

m["jaf"] = {
	"Jara",
	56289,
	"cdc",
	"Latn",
}

m["jah"] = {
	"tiếng Jah Hut",
	2742661,
	"mkh-asl",
	"Latn",
	"Tiếng Jah Hut",
	"Jah Hut"
}

m["jaj"] = {
	"Zazao",
	3574969,
	"poz-ocw",
	"Latn",
}

-- "jak" IS TREATED AS "ms", SEE WT:LT

m["jal"] = {
	"Yalahatan",
	8047298,
	"poz-cma",
	"Latn",
}

m["jam"] = {
	"tiếng Creole Jamaica",
	35939,
	"crp",
	"Latn",
	"Tiếng Creole Jamaica",
	"Creole Jamaica",
	ancestors = "en",
}

m["jan"] = {
	"Janday",
	6150919,
	"aus-pam",
	"Latn",
}

m["jao"] = {
	"tiếng Yanyuwa",
	34241,
	"aus-pam",
	"Latn",
	"Tiếng Yanyuwa",
	"Yanyuwa",
}

m["jaq"] = {
	"Yaqay",
	8049134,
	"ngf",
	"Latn",
}

m["jas"] = {
	"New Caledonian Javanese",
	12953527,
	"poz-sus",
	"Latn",
	ancestors = "jv",
}

m["jat"] = {
	"Jakati",
	4159744,
	"inc-pan",
	ancestors = "lah",
}

m["jau"] = {
	"Yaur",
	8050346,
	"poz-hce",
	"Latn",
}

m["jax"] = {
	"Jambi Malay",
	3915769,
	"poz-mly",
	"Latn",
}

m["jay"] = {
	"Yan-nhangu",
	10723405,
	"aus-yol",
	"Latn",
}

m["jaz"] = {
	"Jawe",
	3163200,
	"poz-cln",
	"Latn",
}

m["jbe"] = {
	"tiếng Berber-Do Thái",
	35854,
	nil,
	"Hebr",
	"Tiếng Berber-Do Thái",
	"Berber-Do Thái",
}

m["jbj"] = {
	"Arandai",
	4784070,
	"ngf",
	"Latn",
}

m["jbk"] = {
	"tiếng Barikewa",
	nil,
	"ngf",
	"Latn",
	"Tiếng Barikewa",
	"Barikewa",
}

m["jbn"] = {
	"tiếng Nefusa",
	36151,
	"ber",
	"Arab",
	"Tiếng Nefusa",
	"Nefusa",
}

m["jbo"] = {
	"tiếng Lojban",
	36350,
	"art",
	"Latn",
	"Tiếng Lojban",
	"Lojban",
	type = "appendix-constructed",
}

m["jbr"] = {
	"Jofotek-Bromnya",
	16886849,
	"paa-tkw",
}

m["jbt"] = {
	"Jabutí",
	2060023,
	"sai-mje",
	"Latn",
}

m["jbu"] = {
	"tiếng Jukun Takum",
	35447,
	"nic-jkn",
	"Latn",
	"Tiếng Jukun Takum",
	"Jukun Takum",
}

m["jbw"] = {
	"Yawijibaya",
	31722921,
	"aus-wor",
	"Latn",
}

m["jcs"] = {
	"Jamaican Country Sign Language",
	6127418,
	"sgn",
	"Latn", -- when documented
}

m["jct"] = {
	"tiếng Krymchak",
	33723,
	"trk-kcu",
	"Latn, Cyrl",
	"Tiếng Krymchak",
	"Krymchak",
	translit = "jct-translit"
}

m["jda"] = {
	"Jad",
	12633440,
	"sit-las",
}

m["jdg"] = {
	"Jadgali",
	13560607,
	"inc-snd",
}

m["jdt"] = {
	"tiếng Tat-Do Thái",
	56495,
	"ira-swi",
	"Latn, Cyrl, Hebr",
	"Tiếng Tat-Do Thái",
	"Tat-Do Thái",
	ancestors = "fa",
	translit = "jdt-translit",
}

m["jeb"] = {
	"Jebero",
	967031,
	"sai-cah",
}

m["jee"] = {
	"Jerung",
	56372,
	"sit-kiw",
}

m["jeg"] = {
	"Jeng",
	5091274,
	"mkh-ban",
	"Latn",
}

m["jeh"] = {
	"tiếng Giẻ",
	3914636,
	"mkh-nbn",
	"Latn, Laoo",
	"Tiếng Giẻ",
	"Giẻ"
}

m["jei"] = {
	"Yei",
	8051326,
}

m["jek"] = {
	"Jeri Kuo",
	11031936,
	"dmn-jje",
	"Latn",
}

m["jel"] = {
	"Yelmek",
	8052020,
}

m["jen"] = {
	"Dza",
	35558,
	"alv-bwj",
}

m["jer"] = {
	"Jere",
	3915449,
	"nic-jer",
}

m["jet"] = {
	"Manem",
	6748412,
	"paa-brd",
}

m["jeu"] = {
	"Jonkor Bourmataguil",
	56269,
}

m["jgb"] = {
	"Ngbee",
	7022243,
}

m["jge"] = {
	"tiếng Gruzia-Do Thái",
	35737,
	nil,
	"Hebr",
	"Tiếng Gruzia-Do Thái",
	"Gruzia-Do Thái",
}

m["jgk"] = {
	"Gwak",
	17523694,
	"nic-jrw",
}

m["jgo"] = {
	"tiếng Ngomba",
	36287,
	"bai",
	"Latn",
	"Tiếng Ngomba",
	"Ngomba",
}

m["jhi"] = {
	"tiếng Jehai",
	3176748,
	"mkh-asl",
	"Latn",
	"Tiếng Jehai",
	"Jehai"
}

m["jhs"] = {
	"Jhankot Sign Language",
	6190889,
	"sgn",
}

m["jia"] = {
	"Jina",
	56297,
}

m["jib"] = {
	"Jibu",
	3914448,
	"nic-jkn",
	"Latn",
}

m["jic"] = {
	"Tol",
	3178609,
	"nai-jcq",
	"Latn",
}

m["jid"] = {
	"Bu",
	3913321,
	"nic-nin",
	"Latn",
}

m["jie"] = {
	"Jilbe",
	56281,
}

m["jig"] = {
	"Jingulu",
	6202435,
	"aus-mir",
}

m["jih"] = {
	"Shangzhai",
	25559440,
	"sit-rgy",
}

m["jii"] = {
	"tiếng Jiiddu",
	56769,
	"cus-som",
	"Latn",
	"Tiếng Jiiddu",
	"Jiiddu",
}

m["jil"] = {
	"Jilim",
	6192674,
	"ngf-mad",
}

m["jim"] = {
	"Jimjimen",
	56288,
	"cdc-cbm",
	"Latn",
}

m["jio"] = {
	"Jiamao",
	3178570,
	nil,
	"Latn",
}

m["jiq"] = {
	"tiếng Khroskyabs",
	3118757,
	"sit-wgy",
	nil,
	"Tiếng Khroskyabs",
	"Khroskyabs",
}

m["jit"] = {
	"Jita",
	6203228,
	"bnt-haj",
	"Latn",
}

m["jiu"] = {
	"tiếng Cơ Nặc Du Lạc",
	12952530,
	"tbq-jin",
	nil,
	"Tiếng Cơ Nặc Du Lạc",
	"Cơ Nặc Du Lạc",
}

m["jiv"] = {
	"Shuar",
	617291,
	"sai-jiv",
	"Latn",
}

m["jiy"] = {
	"Buyuan Jino",
	12952528,
	"tbq-jin",
}

m["jje"] = {
	"tiếng Jeju",
	129648,
	"qfa-kor",
	"Kore",
	"Tiếng Jeju",
	"Jeju",
	ancestors = "okm",
	translit = "jje-translit",
	entry_name = s["Kore-entryname"],
}

m["jjr"] = {
	"Zhár",
	17523697,
	"nic-jrw",
}

m["jka"] = {
	"Kaera",
	16910923,
	"ngf",
	"Latn",
}

m["jkm"] = {
	"tiếng Karen Mobwa",
	63234615,
	"kar",
	"Mymr",
	"Tiếng Karen Mobwa",
	"Karen Mobwa",
	translit = "ksw-translit",
}

m["jko"] = {
	"Kubo",
	12952670,
	"ngf",
}

m["jkp"] = {
	"tiếng Karen Paku",
	25559420,
	"kar",
	"Mymr",
	"Tiếng Karen Paku",
	"Karen Paku",
	translit = "ksw-translit",
}

m["jkr"] = {
	"Koro (India)",
	36162,
	"sit-gsi",
}

m["jku"] = {
	"Labir",
	1990210,
	"nic-jrn",
}

m["jle"] = {
	"Ngile",
	36329,
	"alv-tal",
}

m["jls"] = {
	"Jamaican Sign Language",
	6127433,
	"sgn",
	"Latn", -- when documented
}

m["jma"] = {
	"Dima",
	5277140,
}

m["jmb"] = {
	"tiếng Zumbun",
	56252,
	"cdc-wst",
	"Latn",
	"Tiếng Zumbun",
	"Zumbun",
}

m["jmc"] = {
	"Machame",
	12952751,
	"bnt-chg",
	"Latn",
}

m["jmd"] = {
	"Yamdena",
	8048030,
	"poz-cet",
	"Latn",
}

m["jmi"] = {
	"Jimi",
	3502308,
	"cdc-wst",
	"Latn",
}

m["jml"] = {
	"Jumli",
	6310993,
	"inc-pah",
}

m["jmn"] = {
	"Makuri Naga",
	6740482,
	"sit-aao",
}

m["jmr"] = {
	"Kamara",
	35561,
	"nic-dag",
}

-- "jms" IS TREATED AS "mff", SEE WT:LT

m["jmw"] = {
	"Mouwase",
	nil,
	"ngf",
	"Latn",
}

m["jmx"] = {
	"Western Juxtlahuaca Mixtec",
	12953731,
	"omq-mxt",
	"Latn",
}

m["jna"] = {
	"tiếng Jangshung",
	12633505,
	"sit-kin",
	"Takr",
	"Tiếng Jangshung",
	"Jangshung",
}

m["jnd"] = {
	"Jandavra",
	6150941,
	"inc-wes",
	"Arab",
	ancestors = "gu",
}

m["jng"] = {
	"Yangman",
	10723416,
	"aus-yng",
}

m["jni"] = {
	"Janji",
	3915330,
	"nic-jer",
}

m["jnj"] = {
	"tiếng Yemsa",
	36873,
	"omv",
	"Latn, Ethi",
	"Tiếng Yemsa",
	"Yemsa"
}

m["jnl"] = {
	"Rawat",
	7296948,
	"sit-gma",
}

m["jns"] = {
	"tiếng Jaunsar",
	6164857,
	"him",
	"Deva",
	"Tiếng Jaunsar",
	"Jaunsar",
}

m["job"] = {
	"Joba",
	13123409,
	"bnt-shh",
}

m["jod"] = {
	"Wojenaka",
	11029540,
	"dmn-mnk",
}

m["jor"] = {
	"Jorá",
	5393974,
	"tup-gua",
	"Latn",
}

m["jos"] = {
	"Jordanian Sign Language",
	6534917,
	"sgn",
	"Sgnw",
}

m["jow"] = {
	"Jowulu",
	3914487,
	"dmn-mnw",
	"Latn",
}

-- "jpa" IS NOT USED, SEE WT:LT

m["jpr"] = {
	"tiếng Ba Tư-Do Thái",
	33367,
	"ira-swi",
	"Hebr",
	"Tiếng Ba Tư-Do Thái",
	"Ba Tư-Do Thái",
	ancestors = "fa",
}

m["jqr"] = {
	"tiếng Jaqaru",
	33443,
	"sai-aym",
	"Latn",
	"Tiếng Jaqaru",
	"Jaqaru",
}

m["jra"] = {
	"tiếng Gia Rai",
	33370,
	"cmc",
	"Latn",
	"Tiếng Gia Rai",
	"Gia Rai",
}

m["jrr"] = {
	"Jiru",
	6203123,
	"nic-jkn",
}

m["jru"] = {
	"Japrería",
	3441409,
	"sai-yuk",
	"Latn",
}

m["jsl"] = {
	"Japanese Sign Language",
	35601,
	"sgn-jsl",
}

m["jua"] = {
	"Júma",
	12953587,
	"tup-gua",
	"Latn",
}

m["jub"] = {
	"Wannu",
	3914905,
	"nic-jkn",
}

m["juc"] = {
	"tiếng Nữ Chân",
	56731,
	"tuw-jrc",
	"Jurc, Hani",
	"Tiếng Nữ Chân",
	"Nữ Chân",
}

m["jud"] = {
	"Worodougou",
	11155821,
	"dmn-mnk",
}

m["juh"] = {
	"Hone",
	5964576,
	"nic-jkn",
	"Latn",
}

m["jui"] = {
	"Ngadjuri",
	16897028,
	"aus-pam",
	"Latn",
}

m["juk"] = {
	"Wapan",
	3914914,
	"nic-jkn",
}

m["jul"] = {
	"tiếng Jirel",
	56863,
	"sit-tib",
	"Deva, Tibt",
	"Tiếng Jirel",
	"Jirel",
	translit = { Tibt = "Tibt-translit" },
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["jum"] = {
	"tiếng Jumjum",
	11283696,
	"sdv",
	"Latn, Arab",
	"Tiếng Jumjum",
	"Jumjum",
}

m["jun"] = {
	"tiếng Juang",
	33362,
	"mun",
	"Orya",
	"Tiếng Juang",
	"Juang",
}

m["juo"] = {
	"Jiba",
	6191995,
	"nic-jkn",
}

m["jup"] = {
	"tiếng Hupdë",
	3143384,
	"sai-nad",
	"Latn",
	"Tiếng Hupdë",
	"Hupdë",
}

m["jur"] = {
	"Jurúna",
	4023175,
	"tup",
	"Latn",
}

m["jus"] = {
	"Jumla Sign Language",
	6310991,
	"sgn",
}

m["jut"] = {
	"tiếng Jylland",
	1340322,
	"gmq-eas",
	"Latn",
	"Tiếng Jylland",
	"Jylland",
	ancestors = "da",
}

m["juu"] = {
	"Ju",
	3914897,
}

m["juw"] = {
	"Wãpha",
	3914934,
	"nic-jkn",
	"Latn",
}

m["juy"] = {
	"tiếng Juray",
	6314963,
	"mun",
	"Orya",
	"Tiếng Juray",
	"Juray",
}

m["jvd"] = {
	"tiếng Javindo",
	2719893,
	"crp",
	"Latn",
	"Tiếng Javindo",
	"Javindo",
}

m["jvn"] = {
	"tiếng Java Caribe",
	11732256,
	"poz-sus",
	"Latn",
	"Tiếng Java Caribe",
	"Java Caribe",
	ancestors = "jv",
}

m["jwi"] = {
	"Jwira-Pepesa",
	35467,
	"alv-ctn",
	"Latn",
}

-- "jya" IS TREATED AS "sit-sit", "sit-jap", "sit-tsh", "sit-zbu", SEE WT:LT

m["jyy"] = {
	"Jaya",
	641720,
	"csu-bgr",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")