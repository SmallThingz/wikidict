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

m["oaa"] = {
	"tiếng Orok",
	33928,
	"tuw-nan",
	"Cyrl, Latn",
	"Tiếng Orok",
	"Orok",
}

m["oac"] = {
	"tiếng Oroch",
	33650,
	"tuw-udg",
	"Latn, Cyrl",
	"Tiếng Oroch",
	"Oroch",
}

m["oav"] = {
	"Old Avar",
	nil,
	"cau-ava",
	"Geor",
}

m["obi"] = {
	"Obispeño",
	1288385,
	"nai-chu",
	"Latn",
}

m["obk"] = {
	"Southern Bontoc",
	nil,
	"phi",
	"Latn",
}

m["obl"] = {
	"Oblo",
	36309,
}

m["obm"] = {
	"Moabite",
	36385,
	"sem-can",
	"Phnx",
	translit = "Phnx-translit",
}

m["obo"] = {
	"Obo Manobo",
	12953699,
	"mno",
	"Latn",
}

m["obr"] = {
	"tiếng Miến Điện cổ",
	17006600,
	"tbq-brm",
	"Mymr, Latn", --and also Pallava
	"Tiếng Miến Điện cổ",
	"Miến Điện cổ",
}

m["obt"] = {
	"tiếng Breton cổ",
	3558112,
	"cel-brs",
	"Latn",
	"Tiếng Breton cổ",
	"Breton cổ",
}

m["obu"] = {
	"Obulom",
	3813403,
	"nic-cde",
	"Latn",
}

m["oca"] = {
	"tiếng Ocaina",
	3182577,
	"sai-wit",
	"Latn",
	"Tiếng Ocaina",
	"Ocaina",
}

m["och"] = {
	"tiếng Hán thượng cổ",
	35137,
	"zhx",
	"Hant",
	"Tiếng Hán thượng cổ",
	"Hán thượng cổ",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["ocm"] = {
	"tiếng Chăm cổ",
	105197086,
	"cmc",
	"Latn, Brah",
	"Tiếng Chăm cổ",
	"Chăm cổ",
}

m["oco"] = {
	"tiếng Cornwall cổ",
	48304520,
	"cel-brs",
	"Latn",
	"Tiếng Cornwall cổ",
	"Cornwall cổ",
}

m["ocu"] = {
	"Tlahuica",
	10751739,
	"omq",
	"Latn",
}

m["oda"] = {
	"Odut",
	3915388,
	"nic-uce",
	"Latn",
	ancestors = "mfn",
}

m["odk"] = {
	"Od",
	7077191,
	"inc-wes",
	"Arab",
}

m["odt"] = {
	"tiếng Hà Lan cổ",
	443089,
	"gmw-frk",
	"Latn, Runr",
	"Tiếng Hà Lan cổ",
	"Hà Lan cổ",
	ancestors = "frk",
	entry_name = {remove_diacritics = c.circ .. c.macron},
}

m["odu"] = {
	"Odual",
	3813392,
	"nic-cde",
	"Latn",
}

m["ofo"] = {
	"Ofo",
	3349758,
	"sio-ohv",
}

m["ofs"] = {
	"tiếng Frisia cổ",
	35133,
	"gmw-fri",
	"Latn",
	"Tiếng Frisia cổ",
	"Frisia cổ",
	entry_name = {remove_diacritics = c.circ .. c.macron},
	sort_key = {
		from = {"æ", "ð", "þ"},
		to = {"ae", "t" .. p[1], "t" .. p[2]}
	},
}

m["ofu"] = {
	"Efutop",
	35297,
	"nic-eko",
	"Latn",
}

m["ogb"] = {
	"Ogbia",
	3813400,
	"nic-cde",
	"Latn",
}

m["ogc"] = {
	"Ogbah",
	36291,
	"alv-igb",
	"Latn",
}

m["oge"] = {
	"tiếng Gruzia cổ",
	34834,
	"ccs-gzn",
	"Geor, Geok",
	"Tiếng Gruzia cổ",
	"Gruzia cổ",
	translit = {
		Geor = "Geor-translit",
		Geok = "Geok-translit",
	},
	override_translit = true,
	entry_name = {remove_diacritics = c.circ},
}

m["ogg"] = {
	"Ogbogolo",
	3813405,
	"nic-cde",
	"Latn",
}

m["ogo"] = {
	"Khana",
	3914409,
	"nic-ogo",
	"Latn",
}

m["ogu"] = {
	"tiếng Ogbronuagum",
	3914485,
	"nic-cde",
	"Latn",
	"Tiếng Ogbronuagum",
	"Ogbronuagum",
}

m["ohu"] = {
	"Old Hungarian",
	nil,
	"urj-ugr",
	"Latn",
}

m["oia"] = {
	"tiếng Oirata",
	56738,
	"paa-eti",
	"Latn",
}

m["oin"] = {
	"Inebu One",
	12953782,
	"qfa-tor",
}

m["ojb"] = {
	"tiếng Ojibwe Tây Bắc",
	7060356,
	"alg",
	"Latn, Cans",
	"Tiếng Ojibwe Tây Bắc",
	"Ojibwe Tây Bắc",
	ancestors = "oj",
}

m["ojc"] = {
	"Central Ojibwa",
	5061548,
	"alg",
	"Latn",
	ancestors = "oj",
}

m["ojg"] = {
	"tiếng Ojibwe Đông",
	5330342,
	"alg",
	"Latn, Cans",
	"Tiếng Ojibwe Đông",
	"Ojibwe Đông",
	ancestors = "oj",
}

m["ojp"] = {
	"tiếng Nhật cổ",
	5736700,
	"jpx",
	"Jpan",
	"Tiếng Nhật cổ",
	"Nhật cổ",
	sort_key = s["Jpan-sortkey"],
}

m["ojs"] = {
	"tiếng Ojibwe Severn",
	56494,
	"alg",
	"Latn, Cans",
	"Tiếng Ojibwe Severn",
	"Ojibwe Severn",
	ancestors = "oj",
}

m["ojv"] = {
	"Ontong Java",
	7095071,
	"poz-pnp",
	"Latn",
}

m["ojw"] = {
	"tiếng Ojibwe Tây",
	3474222,
	"alg",
	"Latn, Cans",
	"Tiếng Ojibwe Tây",
	"Ojibwe Tây",
	ancestors = "oj",
}

m["oka"] = {
	"tiếng Okanagan",
	2984602,
	"sal",
	"Latn",
	"Tiếng Okanagan",
	"Okanagan",
}

m["okb"] = {
	"Okobo",
	3813398,
	"nic-lcr",
	"Latn",
}

m["okd"] = {
	"Okodia",
	36300,
	"ijo",
}

m["oke"] = {
	"Okpe (Southwestern Edo)",
	268924,
	"alv-swd",
	"Latn",
}

m["okg"] = {
	"Kok-Paponk",
	nil,
	"aus-pmn",
	"Latn",
}

m["okh"] = {
	"Koresh-e Rostam",
	6432160,
	"xme-ttc",
	ancestors = "xme-ttc-cen",
}

m["oki"] = {
	"Okiek",
	56367,
	"sdv-kln",
	"Latn",
}

m["okj"] = {
	"Oko-Juwoi",
	3436832,
	"qfa-adc",
}

m["okk"] = {
	"Kwamtim One",
	19830649,
	"qfa-tor",
	"Latn",
}

m["okl"] = {
	"Old Kentish Sign Language",
	7084319,
	"sgn",
}

m["okm"] = {
	"tiếng Triều Tiên trung đại",
	715339,
	"qfa-kor",
	"Kore",
	"Tiếng Triều Tiên trung đại",
	"Triều Tiên trung đại",
	ancestors = "oko",
	translit = "okm-translit",
	entry_name = s["Kore-entryname"],
}

m["okn"] = {
	"tiếng Okinoerabu",
	3350036,
	"jpx-nry",
	"Jpan",
	"Tiếng Okinoerabu",
	"Okinoerabu",
	translit = s["Jpan-translit"],
	sort_key = s["Jpan-sortkey"],
}

m["oko"] = {
	"tiếng Triều Tiên cổ",
	715364,
	"qfa-kor",
	"Kore",
	"Tiếng Triều Tiên cổ",
	"Triều Tiên cổ",
	entry_name = s["Kore-entryname"],
}

m["okr"] = {
	"tiếng Kirike",
	11006763,
	"ijo",
	"Latn",
	"Tiếng Kirike",
	"Kirike",
}

m["oks"] = {
	"Oko-Eni-Osayen",
	36302,
	"alv-von",
	"Latn",
}

m["oku"] = {
	"Oku",
	36289,
	"nic-rnc",
	"Latn",
}

m["okv"] = {
	"Orokaiva",
	7103752,
	"ngf",
	"Latn",
}

m["okx"] = {
	"Okpe (Northwestern Edo)",
	7082547,
	"alv-nwd",
	"Latn",
}

m["okz"] = {
	"tiếng Khmer cổ",
	9205,
	"mkh-kmr",
	"Latn, Khmr", --and also Pallava
	"Tiếng Khmer cổ",
	"Khmer cổ",
}

m["old"] = {
	"Mochi",
	12952852,
	"bnt-chg",
	"Latn",
}

m["ole"] = {
	"Olekha",
	3695204,
	"sit-bdi",
	"Tibt, Latn",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["olm"] = {
	"Oloma",
	3441166,
	"alv-nwd",
	"Latn",
}

m["olo"] = {
	"tiếng Livvi",
	36584,
	"urj-fin",
	"Latn",
	"Tiếng Livvi",
	"Livvi",
}

m["olr"] = {
	"Olrat",
	3351562,
	"poz-vnc",
}

m["olt"] = {
	"tiếng Litva cổ",
	17417801,
	"bat-eas",
	"Latn",
	"Tiếng Litva cổ",
	"Litva cổ",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.tilde},
}

m["olu"] = {
	"Kuvale",
	6448765,
	"bnt-swb",
	"Latn",
}

m["oma"] = {
	"tiếng Omaha-Ponca",
	2917968,
	"sio-dhe",
	"Latn",
	"Tiếng Omaha-Ponca",
	"Omaha-Ponca",
}

m["omb"] = {
	"Omba",
	2841471,
	"poz-vnc",
	"Latn",
}

m["omc"] = {
	"Mochica",
	1951641,
}

m["omg"] = {
	"Omagua",
	33663,
	"tup-gua",
	"Latn",
}

m["omi"] = {
	"Omi",
	56795,
	"csu-mma",
}

m["omk"] = {
	"tiếng Omok",
	4334657,
	"qfa-yuk",
	"Cyrl",
	"Tiếng Omok",
	"Omok",
	translit = "omk-translit",
}

m["oml"] = {
	"Ombo",
	7089928,
	"bnt-tet",
	"Latn",
}

m["omn"] = {
	"Minoan",
	1669994,
	nil,
	"Lina",
}

m["omo"] = {
	"Utarmbung",
	7902577,
	"ngf",
	"Latn",
}

m["omp"] = {
	"Old Manipuri",
	nil,
	"sit",
	"Mtei",
	translit = "Mtei-translit",
}

m["omr"] = {
	"tiếng Marathi cổ",
	65455881,
	"inc-sou",
	"Deva, Modi",
	"Tiếng Marathi cổ",
	"Marathi cổ",
	translit = {
		Deva = "sa-translit",
		Modi = "Modi-translit",
	},
}

m["omt"] = {
	"Omotik",
	36313,
	"sdv-nis",
}

m["omu"] = {
	"Omurano",
	1957612,
}

m["omw"] = {
	"South Tairora",
	20210553,
	"paa-kag",
	"Latn",
}

m["omx"] = {
	"tiếng Môn cổ",
	111364697,
	"mkh-mnc",
	"Mymr, Latn", --and also Pallava
	"Tiếng Môn cổ",
	"Môn cổ",
}

m["omy"] = {
	"tiếng Mã Lai cổ",
	31775823,
	"poz",
	"Kawi", --and also Pallava
	"Tiếng Mã Lai cổ",
	"Mã Lai cổ",
}

m["ona"] = {
	"Selk'nam",
	2721227,
	"sai-cho",
	"Latn",
}

m["onb"] = {
	"tiếng Lâm Cao",
	7093790,
	"qfa-onb",
	"Latn",
	"Tiếng Lâm Cao",
	"Lâm Cao",
}

m["one"] = {
	"tiếng Oneida",
	857858,
	"iro-nor",
	"Latn",
	"Tiếng Oneida",
	"Oneida",
}

m["ong"] = {
	"Olo",
	592162,
	"qfa-tor",
	"Latn",
}

m["oni"] = {
	"Onin",
	7093910,
	"poz-cet",
	"Latn",
}

m["onj"] = {
	"Onjob",
	7093968,
	"ngf",
	"Latn",
}

m["onk"] = {
	"Kabore One",
	12953783,
	"qfa-tor",
	"Latn",
}

m["onn"] = {
	"Onobasulu",
	7094437,
	"ngf",
	"Latn",
}

m["ono"] = {
	"Onondaga",
	1077450,
	"iro-nor",
	"Latn",
	ancestors = "iro-oon",
}

m["onp"] = {
	"Sartang",
	7424639,
	"sit-khb",
}

m["onr"] = {
	"Northern One",
	19830648,
	"qfa-tor",
	"Latn",
}

m["ons"] = {
	"Ono",
	11732548,
	"ngf",
	"Latn",
}

m["ont"] = {
	"Ontenu",
	3352827,
}

m["onu"] = {
	"Unua",
	3552042,
	"poz-vnc",
	"Latn",
}

m["onw"] = {
	"tiếng Nubia cổ",
	2268,
	"nub",
	"Copt",
	"Tiếng Nubia cổ",
	"Nubia cổ",
	translit = "Copt-translit",
	sort_key = "cop-sortkey",
}

m["onx"] = {
	"Pidgin Onin",
	12953788,
	"crp",
	"Latn",
	ancestors = "oni",
}

m["ood"] = {
	"tiếng O'odham",
	2393095,
	"azc-pim",
	"Latn",
	"Tiếng O'odham",
	"O'odham",
}

m["oog"] = {
	"Ong",
	12953787,
	"mkh-kat",
}

m["oon"] = {
	"tiếng Önge",
	2475551,
	"qfa-ong",
	"Latn",
	"Tiếng Önge",
	"Önge",
}

m["oor"] = {
	"Oorlams",
	2484337,
}

m["oos"] = {
	"tiếng Ossetia cổ",
	65455882,
	"xsc",
	"Polyt, Latn",
	"Tiếng Ossetia cổ",
	"Ossetia cổ",
	ancestors = "os-pro",
	translit = {Polyt = "grc-translit"},
	entry_name = {
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Polyt = s["Grek-sortkey"],
	},
}

m["opa"] = {
	"Okpamheri",
	3913331,
	"alv-nwd",
	"Latn",
}

m["opk"] = {
	"Kopkaka",
	6431129,
	"ngf-okk",
	"Latn",
}

m["opm"] = {
	"Oksapmin",
	1068097,
	"ngf",
	"Latn",
}

m["opo"] = {
	"Opao",
	7095585,
	"ngf",
	"Latn",
}

m["opt"] = {
	"Opata",
	2304583,
	"azc-trc",
	"Latn",
}

m["opy"] = {
	"Ofayé",
	3446691,
	"sai-mje",
	"Latn",
}

m["ora"] = {
	"Oroha",
	36298,
	"poz-sls",
}

m["orc"] = {
	"tiếng Orma",
	2919128,
	"cus-eas",
	"Latn",
	"Tiếng Orma",
	"Orma",
}

m["ore"] = {
	"Orejón",
	3355834,
	"sai-tuc",
	"Latn",
}

m["org"] = {
	"Oring",
	3915308,
	"nic-ucn",
	"Latn",
}

m["orh"] = {
	"tiếng Oroqen",
	1367309,
	"tuw-ewe",
	"Latn",
	"Tiếng Oroqen",
	"Oroqen",
}

m["oro"] = {
	"Orokolo",
	7103758,
	"ngf",
	"Latn",
}

m["orr"] = {
	"Oruma",
	36299,
	"ijo",
	"Latn",
}

m["ort"] = {
	"tiếng Oriya Adiwasi",
	12953791,
	"inc-eas",
	"Orya",
	"Tiếng Oriya Adiwasi",
	"Oriya Adiwasi",
	ancestors = "or",
}

m["oru"] = {
	"tiếng Ormur",
	33740,
	"ira-orp",
	"fa-Arab",
	"Tiếng Ormur",
	"Ormur",
}

m["orv"] = {
	"tiếng Slav Đông cổ",
	35228,
	"zle",
	"Cyrs",
	"Tiếng Slav Đông cổ",
	"Slav Đông cổ",
	translit = {Cyrs = "Cyrs-translit"},
	entry_name = s["Cyrs-entryname"],
	sort_key = { from = {"Ꙑ", "ꙑ"} ,  to =  { "ы" .. p[1], "ы" .. p[1],} },
}

m["orw"] = {
	"Oro Win",
	3450423,
	"sai-cpc",
	"Latn",
}

m["orx"] = {
	"Oro",
	3813396,
	"nic-lcr",
	"Latn",
}

m["orz"] = {
	"tiếng Ormu",
	7103494,
	"poz-ocw",
	"Latn",
	"Tiếng Ormu",
	"Ormu"
}

m["osa"] = {
	"tiếng Osage",
	2600085,
	"sio-dhe",
	"Latn, Osge",
	"Tiếng Osage",
	"Osage",
}

m["osc"] = {
	"tiếng Osci",
	36653,
	"itc-sbl",
	"Ital, Latn, Polyt",
	"Tiếng Osci",
	"Osci",
	translit = {
		Ital = "Ital-translit",
		Polyt = "grc-translit",
	},
	entry_name = {
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Polyt = s["Grek-sortkey"],
	},
}

m["osi"] = {
	"tiếng Osing",
	2701322,
	"poz-sus",
	"Latn",
	"Tiếng Osing",
	"Osing",
}

m["osn"] = {
	"tiếng Sunda cổ",
	56197074,
	"poz-msa",
	"Latn, Sund, Kawi",
	"Tiếng Sunda cổ",
	"Sunda cổ",
}

m["oso"] = {
	"Ososo",
	3913398,
	"alv-yek",
	"Latn",
}

m["osp"] = {
	"tiếng Tây Ban Nha cổ",
	1088025,
	"roa-ibe",
	"Latn",
	"Tiếng Tây Ban Nha cổ",
	"Tây Ban Nha cổ",
}

m["ost"] = {
	"tiếng Osatu",
	36243,
	"nic-grs",
	"Latn",
	"Tiếng Osatu",
	"Osatu",
}

m["osu"] = {
	"Southern One",
	12953785,
	"qfa-tor",
	"Latn",
}

m["osx"] = {
	"tiếng Saxon cổ",
	35219,
	"gmw-lgm",
	"Latn",
	"Tiếng Saxon cổ",
	"Saxon cổ",
	entry_name = {remove_diacritics = c.circ .. c.macron},
}

m["ota"] = {
	"tiếng Thổ Nhĩ Kỳ Ottoman",
	36730,
	"trk-ogz",
	"ota-Arab, Armn",
	"Tiếng Thổ Nhĩ Kỳ Ottoman",
	"Thổ Nhĩ Kỳ Ottoman",
	ancestors = "trk-oat",
	entry_name = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef},
	translit = {Armn = "ota-Armn-translit"},
}

m["otb"] = {
	"Old Tibetan",
	7085214,
	"sit-tib",
	"Tibt",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["otd"] = {
	"Ot Danum",
	3033781,
	"poz-brw",
	"Latn",
}

m["ote"] = {
	"tiếng Otomi Mezquital",
	23755711,
	"oto-otm",
	"Latn",
	"Tiếng Otomi Mezquital",
	"Otomi Mezquital",
}

m["oti"] = {
	"Oti",
	3357881,
}

m["otk"] = {
	"tiếng Turk cổ",
	34988,
	"trk",
	"Orkh",
	"Tiếng Turk cổ",
	"Turk cổ",
	translit = "Orkh-translit",
}

m["otl"] = {
	"Tilapa Otomi",
	7802050,
	"oto-otm",
	"Latn",
}

m["otm"] = {
	"Eastern Highland Otomi",
	13581718,
	"oto-otm",
	"Latn",
}

m["otn"] = {
	"Tenango Otomi",
	25559589,
	"oto-otm",
	"Latn",
}

m["otq"] = {
	"tiếng Otomi Querétaro",
	23755688,
	"oto-otm",
	"Latn",
	"Tiếng Otomi Querétaro",
	"Otomi Querétaro",
}

m["otr"] = {
	"tiếng Otoro",
	36328,
	"alv-hei",
	"Latn",
	"Tiếng Otoro",
	"Otoro",
}

m["ots"] = {
	"Estado de México Otomi",
	7413841,
	"oto-otm",
	"Latn",
}

m["ott"] = {
	"Temoaya Otomi",
	7698191,
	"oto-otm",
	"Latn",
}

m["otu"] = {
	"tiếng Otuke",
	7110049,
	"sai-mje",
	"Latn",
	"Tiếng Otuke",
	"Otuke",
}

m["otw"] = {
	"tiếng Ottawa",
	133678,
	"alg",
	"Latn",
	ancestors = "oj",
}

m["otx"] = {
	"Texcatepec Otomi",
	25559590,
	"oto-otm",
	"Latn",
}

m["oty"] = {
	"tiếng Tamil cổ",
	20987452,
	"dra-tam",
	"Brah",
	"Tiếng Tamil cổ",
	"Tamil cổ",
	translit = "Brah-translit",
}

m["otz"] = {
	"Ixtenco Otomi",
	6101171,
	"oto-otm",
	"Latn",
}

m["oub"] = {
	"Glio-Oubi",
	3914977,
	"kro-grb",
}

m["oue"] = {
	"Oune",
	7110521,
	"paa-sbo",
}

m["oui"] = {
	"tiếng Duy Ngô Nhĩ cổ",
	428299,
	"trk-ssb",
	"Ougr, Latn, Hani, Phag, Brah, Mani, Syrc, Orkh, Sogd, Arab, mnc-Mong, Sogo, Tibt",
	"Tiếng Duy Ngô Nhĩ cổ",
	"Duy Ngô Nhĩ cổ",
	ancestors = "otk",
	translit = {
		Ougr = "Ougr-translit",
		-- Orkh translit in [[Module:scripts/data]]
		-- Mani translit in [[Module:scripts/data]]
		-- mnc-Mong translit in [[Module:scripts/data]] (NOTE: Formerly not present; I assume accidentally left out)
		-- Brah translit in [[Module:scripts/data]]
	},
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	-- NOTE: Formerly there was only a sort_key for Tibetan. I assume the other three were left out accidentally.
	sort_key = {
		Hani = "Hani-sortkey",
	},
}

m["oum"] = {
	"Ouma",
	7110494,
	"poz-ocw",
	"Latn",
}

m["ovd"] = {
	"tiếng Övdal",
	254950,
	"gmq-eas",
	"Latn",
	"Tiếng Övdal",
	"Övdal",
}

m["owi"] = {
	"Owiniga",
	56454,
	"qfa-mal",
	"Latn",
	"Tiếng Owiniga",
	"Owiniga",
}

m["owl"] = {
	"tiếng Wales cổ",
	2266723,
	"cel-brw",
	"Latn",
}

m["oyb"] = {
	"Oy",
	13593748,
	"mkh-ban",
}

m["oyd"] = {
	"tiếng Oyda",
	7116251,
	"omv-nom",
	"Ethi, Latn",
	"Tiếng Oyda",
	"Oyda",
}

m["oym"] = {
	"tiếng Wayampi",
	7975842,
	"tup-gua",
	"Latn",
	"Tiếng Wayampi",
	"Wayampi",
}

m["oyy"] = {
	"Oya'oya",
	7116243,
	"poz-ocw",
	"Latn",
}

m["ozm"] = {
	"tiếng Koonzime",
	35566,
	"bnt-ndb",
	"Latn",
	"Tiếng Koonzime",
	"Koonzime",
}

return require("Module:languages").finalizeData(m, "language")