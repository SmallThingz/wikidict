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
	"Orok",
	33928,
	"tuw-nan",
	"Cyrl, Latn",
	translit = "oaa-translit",
}

m["oac"] = {
	"Oroch",
	33650,
	"tuw-udg",
	"Latn, Cyrl",
}

m["oav"] = {
	"Old Avar",
	65455879,
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
	63308144,
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
	"Old Burmese",
	17006600,
	"tbq-brm",
	"Mymr, Latn", --and also Pallava
}

m["obt"] = {
	"Old Breton",
	3558112,
	"cel-brs",
	"Latn",
}

m["obu"] = {
	"Obulom",
	3813403,
	"nic-cde",
	"Latn",
}

m["oca"] = {
	"Ocaina",
	3182577,
	"sai-wit",
	"Latn",
}

m["och"] = {
	"Old Chinese",
	35137,
	"zhx",
	"Hant",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["oco"] = {
	"Old Cornish",
	48304520,
	"cel-brs",
	"Latn",
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
	"Old Dutch",
	443089,
	"gmw-frk",
	"Latn, Runr",
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
	"Old Frisian",
	35133,
	"gmw-fri",
	"Latn",
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
	"Old Georgian",
	34834,
	"ccs-gzn",
	"Geor, Geok",
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
	"Ogbronuagum",
	3914485,
	"nic-cde",
	"Latn",
}

m["ohu"] = {
	"Old Hungarian",
	65455880,
	"urj-ugr",
	"Latn",
}

m["oia"] = {
	"Oirata",
	56738,
	"ngf",
	"Latn",
}

m["oin"] = {
	"Inebu One",
	12953782,
	"qfa-tor",
}

m["ojb"] = {
	"Northwestern Ojibwa",
	7060356,
	"alg",
	"Latn",
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
	"Eastern Ojibwa",
	5330342,
	"alg",
	"Latn",
	ancestors = "oj",
}

m["ojp"] = {
	"Old Japanese",
	5736700,
	"jpx",
	"Jpan",
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["ojs"] = {
	"Severn Ojibwa",
	56494,
	"alg",
	"Latn",
	ancestors = "oj",
}

m["ojv"] = {
	"Ontong Java",
	7095071,
	"poz-pnp",
	"Latn",
}

m["ojw"] = {
	"Western Ojibwa",
	3474222,
	"alg",
	"Latn",
	ancestors = "oj",
}

m["oka"] = {
	"Okanagan",
	2984602,
	"sal",
	"Latn",
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
	55254102,
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
	"Middle Korean",
	715339,
	"qfa-kor",
	"Kore",
	ancestors = "oko",
	translit = "okm-translit",
	entry_name = s["Kore-entryname"],
	sort_key = "okm-sortkey",
}

m["okn"] = {
	"Okinoerabu",
	3350036,
	"jpx-nry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["oko"] = {
	"Old Korean",
	715364,
	"qfa-kor",
	"Kore",
	entry_name = s["Kore-entryname"],
}

m["okr"] = {
	"Kirike",
	11006763,
	"ijo",
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
	"Old Khmer",
	9205,
	"mkh-kmr",
	"Latn, Khmr", --and also Khom, Pallava
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
	"Livvi",
	36584,
	"urj-fin",
	"Latn",
}

m["olr"] = {
	"Olrat",
	3351562,
	"poz-vnn",
	"Latn",
}

m["olt"] = {
	"Old Lithuanian",
	17417801,
	"bat-eas",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.tilde},
}

m["olu"] = {
	"Kuvale",
	6448765,
	"bnt-swb",
	"Latn",
}

m["oma"] = {
	"Omaha-Ponca",
	2917968,
	"sio-dhe",
	"Latn",
}

m["omb"] = {
	"Omba",
	2841471,
	"poz-vnn",
	"Latn",
}

m["omc"] = {
	"Mochica",
	1951641,
	"qfa-iso",
	"Latn",
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
	"Omok",
	4334657,
	"qfa-yuk",
	"Cyrl",
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
	105953310,
	"sit",
	"Mtei",
	translit = "Mtei-translit",
}

m["omr"] = {
	"Old Marathi",
	65455881,
	"inc-sou",
	"Deva, Modi",
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
	"Old Mon",
	111364697,
	"mkh-mnc",
	"Mymr, Latn", --and also Pallava
}

m["ona"] = {
	"Selk'nam",
	2721227,
	"sai-cho",
	"Latn",
}

m["onb"] = {
	"Lingao",
	7093790,
	"qfa-onb",
	"Latn",
}

m["one"] = {
	"Oneida",
	857858,
	"iro-nor",
	"Latn",
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
	"sit-khm",
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
	"Old Nubian",
	2268,
	"nub",
	"Copt",
	translit = "Copt-translit",
	sort_key = "Copt-sortkey",
}

m["onx"] = {
	"Pidgin Onin",
	12953788,
	"crp",
	"Latn",
	ancestors = "oni",
}

m["ood"] = {
	"O'odham",
	2393095,
	"azc",
	"Latn",
}

m["oog"] = {
	"Ong",
	12953787,
	"mkh-kat",
}

m["oon"] = {
	"Önge",
	2475551,
	"qfa-ong",
	"Latn",
}

m["oor"] = {
	"Oorlams",
	2484337,
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
	"Oroqen",
	1367309,
	"tuw-ewe",
	"Latn",
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
	"Adivasi Odia",
	12953791,
	"inc-eas",
	"Orya",
	ancestors = "or",
}

m["oru"] = {
	"Ormuri",
	33740,
	"ira-orp",
	"fa-Arab",
}

m["orv"] = {
	"Old East Slavic",
	35228,
	"zle",
	"Cyrs",
	translit = {Cyrs = "Cyrs-translit"},
	entry_name = s["Cyrs-entryname"],
	sort_key = s["Cyrs-sortkey"],
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
	"Ormu",
	7103494,
	"poz-ocw",
	"Latn",
}

m["osa"] = {
	"Osage",
	2600085,
	"sio-dhe",
	"Latn, Osge",
}

m["osc"] = {
	"Oscan",
	36653,
	"itc-sbl",
	"Ital, Latn, Polyt",
	translit = {
		Ital = "Ital-translit",
		Polyt = "grc-translit",
	},
	display_text = {
		Latn = s["itc-Latn-displaytext"],
		Polyt = s["Polyt-displaytext"],
	},
	entry_name = {
		Latn = s["itc-Latn-entryname"],
		Polyt = s["Polyt-entryname"]
	},
	sort_key = {
		Latn = s["itc-Latn-sortkey"],
		Polyt = s["Polyt-sortkey"]
	},
}

m["osi"] = {
	"Osing",
	2701322,
	"poz",
	"Latn",
}

m["osn"] = {
	"Old Sundanese",
	56197074,
	"poz-msa",
	"Latn, Sund, Kawi",
}

m["oso"] = {
	"Ososo",
	3913398,
	"alv-yek",
	"Latn",
}

m["osp"] = {
	"Old Spanish",
	1088025,
	"roa-cas",
	"Latn",
}

m["ost"] = {
	"Osatu",
	36243,
	"nic-grs",
	"Latn",
}

m["osu"] = {
	"Southern One",
	12953785,
	"qfa-tor",
	"Latn",
}

m["osx"] = {
	"Old Saxon",
	35219,
	"gmw-lgm",
	"Latn",
	entry_name = {remove_diacritics = c.circ .. c.macron},
}

m["ota"] = {
	"Ottoman Turkish",
	36730,
	"trk-ogz",
	"ota-Arab, Armn",
	ancestors = "trk-oat",
	entry_name = {
		["ota-Arab"] = {
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
			from = {"گ", "ڭ", "ۀ"},
			to = {"ك", "ك", "ه"}
		},
		Armn = {
			from = {"՚"},
			to = {"’"}
		},
	},
	translit = {Armn = "ota-Armn-translit"},
	standardChars = {
		["ota-Arab"] = "آاأبپتثجچحخدذرزژسشصضطظعغفقكلمنوؤهیئةءـ‌",
		c.punc
	},
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
	"Mezquital Otomi",
	23755711,
	"oto-otm",
	"Latn",
}

m["oti"] = {
	"Oti",
	3357881,
}

m["otk"] = {
	"Old Turkic",
	34988,
	"trk-sib",
	"Orkh",
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
	"Querétaro Otomi",
	23755688,
	"oto-otm",
	"Latn",
}

m["otr"] = {
	"Otoro",
	36328,
	"alv-hei",
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
	"Otuke",
	7110049,
	"sai-mje",
	"Latn",
}

m["otw"] = {
	"Ottawa",
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
	"Old Tamil",
	20987452,
	"dra-tam",
	"Brah",
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
	"Old Uyghur",
	428299,
	"trk-ssb",
	"Ougr, Latn, Hani, Phag, Brah, Mani, Syrc, Orkh, Sogd, Arab, mnc-Mong, Sogo, Tibt",
	ancestors = "otk",
	translit = {
		Ougr = "Ougr-translit",
		Orkh = "Orkh-translit",
		Brah = "Brah-translit",
		Mani = "Mani-translit",
	},
	sort_key = {
		Hani = "Hani-sortkey",
		Tibt = "Tibt-sortkey",
	},
}

m["oum"] = {
	"Ouma",
	7110494,
	"poz-ocw",
	"Latn",
}

m["ovd"] = {
	"Elfdalian",
	254950,
	"gmq-eas",
	"Latn",
}

m["owi"] = {
	"Owiniga",
	56454,
	"qfa-mal",
	"Latn",
}

m["owl"] = {
	"Old Welsh",
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
	"Oyda",
	7116251,
	"omv-nom",
}

m["oym"] = {
	"Wayampi",
	7975842,
	"tup-gua",
	"Latn",
}

m["oyy"] = {
	"Oya'oya",
	7116243,
	"poz-ocw",
	"Latn",
}

m["ozm"] = {
	"Koonzime",
	35566,
	"bnt-ndb",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")