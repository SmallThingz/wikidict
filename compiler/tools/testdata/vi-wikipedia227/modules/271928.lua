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

m["pab"] = {
	"tiếng Pareci",
	3504312,
	"awd",
	"Latn",
	"Tiếng Pareci",
	"Pareci",
}

m["pac"] = {
	"tiếng Pa Kô",
	3441136,
	"mkh-kat",
	"Latn",
	"Tiếng Pa Kô",
	"Pa Kô",
}

m["pad"] = {
	"Paumarí",
	389827,
	"auf",
	"Latn",
}

m["pae"] = {
	"Pagibete",
	7124357,
	"bnt-bta",
	"Latn",
}

m["paf"] = {
	"Paranawát",
	12953806,
	"tup-gua",
	"Latn",
}

m["pag"] = {
	"tiếng Pangasinan",
	33879,
	"phi",
	"Latn, Tglg",
	"Tiếng Pangasinan",
	"Pangasinan",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer},
}

m["pah"] = {
	"tiếng Tenharim",
	10266010,
	"tup-gua",
	"Latn",
	"Tiếng Tenharim",
	"Tenharim",
}

m["pai"] = {
	"Pe",
	3914871,
	"nic-tar",
	"Latn",
}

m["pak"] = {
	"Parakanã",
	12953804,
	"tup-gua",
	"Latn",
}

m["pal"] = {
	"tiếng Ba Tư trung đại",
	32063,
	"ira-swi",
	"Latn, Phli, pal-Avst, Mani, Phlp, Phlv", -- Latn for translit; Phlv not in Unicode
	"Tiếng Ba Tư trung đại",
	"Ba Tư trung đại",
	translit = {
		Phli = "Phli-translit",
		["pal-Avst"] = "Avst-translit",
		Mani = "Mani-translit",
	},
	ancestors = "peo",
}

m["pam"] = {
	"tiếng Kapampangan",
	36121,
	"phi",
	"Latn", --also Kulitan, which lacks a code
	"Tiếng Kapampangan",
	"Kapampangan",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}},
	standardChars = {
		Latn = "AaBbDdEeGgHhIiKkLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
	sort_key = {
		Latn = "tl-sortkey"
	},
}


m["pao"] = {
	"tiếng Bắc Paiute",
	3360656,
	"azc-num",
	"Latn",
	"Tiếng Bắc Paiute",
	"Bắc Paiute",
}

m["pap"] = {
	"tiếng Papiamento",
	33856,
	"crp",
	"Latn",
	"Tiếng Papiamento",
	"Papiamento",
	ancestors = "pt",
}

m["paq"] = {
	"tiếng Parya",
	1135134,
	"inc-cen",
	"Cyrl",
	"Tiếng Parya",
	"Parya",
}

m["par"] = {
	"Panamint",
	33926,
	"azc-num",
	"Latn",
}

m["pas"] = {
	"Papasena",
	7132508,
	"paa-lkp",
	"Latn",
}

m["pat"] = {
	"Papitalai",
	6528659,
	"poz-aay",
	"Latn",
}

m["pau"] = {
	"tiếng Palau",
	33776,
	"poz",
	"Latn, Kana",
	"Tiếng Palau",
	"Palau",
	sort_key = {Kana = "Kana-sortkey"},
}

m["pav"] = {
	"Wari'",
	3027909,
	"sai-cpc",
	"Latn",
}

m["paw"] = {
	"tiếng Pawnee",
	56751,
	"cdd",
	"Latn",
	"Tiếng Pawnee",
	"Pawnee",
}

m["pax"] = {
	"Pankararé",
	25559779,
	nil,
	"Latn",
}

m["pay"] = {
	"Pech",
	4898889,
	"cba",
	"Latn",
}

m["paz"] = {
	"Pankararú",
	7131310,
	nil,
	"Latn",
}

m["pbb"] = {
	"Páez",
	33677,
	nil,
	"Latn",
}

m["pbc"] = {
	"Patamona",
	3915921,
	"sai-pem",
	"Latn",
}

m["pbe"] = {
	"Mezontla Popoloca",
	42365630,
	"omq-pop",
	"Latn",
}

m["pbf"] = {
	"Coyotepec Popoloca",
	5180100,
	"omq-pop",
	"Latn",
}

m["pbg"] = {
	"tiếng Paraujano",
	3501747,
	"awd-taa",
	"Latn",
	"Tiếng Paraujano",
	"Paraujano",
}

m["pbh"] = {
	"Panare",
	56610,
	"sai-ven",
	"Latn",
}

m["pbi"] = {
	"Podoko",
	3515096,
	"cdc-cbm",
	"Latn",
}

m["pbl"] = {
	"Mak (Nigeria)",
	3915349,
	"alv-bwj",
	"Latn",
}

m["pbm"] = {
	"Puebla Mazatec",
	nil,
	"omq-maz",
	"Latn",
}

m["pbn"] = {
	"Kpasam",
	3914902,
	"alv-mye",
	"Latn",
}

m["pbo"] = {
	"Papel",
	36314,
	"alv-pap",
	"Latn",
}

m["pbp"] = {
	"Badyara",
	35095,
	"alv-ten",
	"Latn",
}

m["pbr"] = {
	"Pangwa",
	3847550,
	"bnt-bki",
	"Latn",
}

m["pbs"] = {
	"Central Pame",
	3361763,
	"omq",
	"Latn",
}

m["pbv"] = {
	"tiếng Pnar",
	3501850,
	"aav-pkl",
	"Latn",
	"Tiếng Pnar",
	"Pnar",
}

m["pby"] = {
	"Pyu",
	2567925,
	"paa-asa",
	"Latn",
}

m["pca"] = {
	"Santa Inés Ahuatempan Popoloca",
	42365276,
	"omq-pop",
	"Latn",
}

m["pcb"] = {
	"tiếng Pear",
	6583669,
	"mkh-pea",
	"Khmr",
	"Tiếng Pear",
	"Pear"
}

m["pcc"] = {
	"tiếng Bố Y",
	35100,
	"tai-nor",
	"Latn, Hani",
	"Tiếng Bố Y",
	"Bố Y",
	sort_key = {Hani = "Hani-sortkey"},
}

m["pcd"] = {
	"tiếng Picard",
	34024,
	"roa-oil",
	"Latn",
	"Tiếng Picard",
	"Picard",
	sort_key = s["roa-oil-sortkey"],
}

m["pce"] = {
	"tiếng Palaung Ruching",
	12953798,
	"mkh-pal",
	"Mymr",
	"Tiếng Palaung Ruching",
	"Palaung Ruching",
}

m["pcf"] = {
	"tiếng Paliyan",
	7127643,
	"dra-tam",
	"Mlym",
	"Tiếng Paliyan",
	"Paliyan",
	translit = {Mlym = "ml-translit"},
}

m["pcg"] = {
	"tiếng Paniya",
	7131211,
	"dra-mal",
	"Mlym, Knda",
	"Tiếng Paniya",
	"Paniya",
	translit = {
		Mlym = "ml-translit",
		Knda = "kn-translit",
	},
}

m["pch"] = {
	"Pardhan",
	7133207,
	"dra-gon",
}

m["pci"] = {
	"tiếng Duruwa",
	56753,
	"dra-pgd",
	"Deva, Orya",
	"Tiếng Duruwa",
	"Duruwa",
}

m["pcj"] = {
	"tiếng Parenga",
	3111396,
	"mun",
	"Orya",
	"Tiếng Parenga",
	"Parenga",
}

m["pck"] = {
	"tiếng Paite",
	12952337,
	"tbq-kuk",
	nil,
	"Tiếng Paite",
	"Paite",
}

m["pcl"] = {
	"Pardhi",
	7136554,
	"inc-bhi",
}

m["pcm"] = {
	"Nigerian Pidgin",
	33655,
	"crp",
	"Latn",
	ancestors = "en",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.caron .. c.macronbelow},
	sort_key = {
		remove_diacritics = c.tilde,
		from = {"ẹ", "gb", "kp", "ọ", "sh", "zh"},
		to = {"e" .. p[1], "g" .. p[1], "k" .. p[1], "o" .. p[1], "s" .. p[1], "z" .. p[1]}
	},
}

m["pcn"] = {
	"Piti",
	3913375,
	"nic-kne",
	"Latn",
}

m["pcp"] = {
	"Pacahuara",
	2591165,
	"sai-pan",
	"Latn",
}

m["pcw"] = {
	"Pyapun",
	3438807,
	nil,
	"Latn",
}

m["pda"] = {
	"Anam",
	3501930,
	"ngf-mad",
	"Latn",
}

m["pdc"] = {
	"tiếng Đức Pennsylvania",
	22711,
	"gmw-hgm",
	"Latn",
	"Tiếng Đức Pennsylvania",
	"Đức Pennsylvania",
	ancestors = "gmw-rfr",
}

m["pdi"] = {
	"Pa Di",
	3359940,
	nil,
	"Latn",
}

m["pdn"] = {
	"Fedan",
	7206699,
	"poz-ocw",
	"Latn",
}

m["pdo"] = {
	"Padoe",
	3360370,
	"poz-btk",
	"Latn",
}

m["pdt"] = {
	"tiếng Hạ Đức Mennonite",
	1751432,
	"gmw-lgm",
	"Latn",
	"Tiếng Hạ Đức Mennonite",
	"Hạ Đức Mennonite",
	ancestors = "nds-de",
}

m["pdu"] = {
	"tiếng Kayan",
	7123283,
	"kar",
	"Latn, Mymr",
	"Tiếng Kayan",
	"Kayan",
}

m["pea"] = {
	"tiếng Indonesia Peranakan",
	653415,
	nil,
	"Latn",
	"Tiếng Indonesia Peranakan",
	"Indonesia Peranakan",
}

m["peb"] = {
	"Eastern Pomo",
	3396032,
	"nai-pom",
	"Latn",
}

m["ped"] = {
	"Mala (New Guinea)",
	11732569,
	"ngf-mad",
	"Latn",
}

m["pee"] = {
	"Taje",
	12953902,
	nil,
	"Latn",
}

m["pef"] = {
	"Northeastern Pomo",
	3396018,
	"nai-pom",
	"Latn",
}

m["peg"] = {
	"tiếng Pengo",
	56758,
	"dra-kki",
	"Orya",
	translit = "kxv-translit",
	"Tiếng Pengo",
	"Pengo",
}

m["peh"] = {
	"tiếng Bảo An",
	32983,
	"xgn-shr",
	"Latn",
	"Tiếng Bảo An",
	"Bảo An",
}

m["pei"] = {
	"Chichimeca-Jonaz",
	3915427,
	"omq-otp",
	"Latn",
}

m["pej"] = {
	"Northern Pomo",
	3396021,
	"nai-pom",
	"Latn",
}

m["pek"] = {
	"Penchal",
	3374631,
	"poz-aay",
	"Latn",
}

m["pel"] = {
	"Pekal",
	3241781,
	nil,
	"Latn",
}

m["pem"] = {
	"Phende",
	7162372,
	"bnt-pen",
	"Latn",
}

m["peo"] = {
	"tiếng Ba Tư cổ",
	35225,
	"ira-swi",
	"Xpeo, Latn",
	"Tiếng Ba Tư cổ",
	"Ba Tư cổ",
	translit = "peo-translit",
}

m["pep"] = {
	"Kunja",
	6444807,
	nil,
	"Latn",
}

m["peq"] = {
	"Southern Pomo",
	3396023,
	"nai-pom",
	"Latn",
}

-- "pes" IS TREATED AS "fa" (or as etymology-only), SEE WT:LT

m["pev"] = {
	"Pémono",
	3439012,
	"sai-map",
	"Latn",
}

m["pex"] = {
	"Petats",
	3376353,
	"poz-ocw",
	"Latn",
}

m["pey"] = {
	"tiếng Petjo",
	940486,
	nil,
	"Latn",
	"Tiếng Petjo",
	"Petjo",
}


m["pez"] = {
	"Eastern Penan",
	18638342,
	"poz-swa",
	"Latn",
}

m["pfa"] = {
	"Pááfang",
	3063517,
	"poz-mic",
	"Latn",
}

m["pfe"] = {
	"Peere",
	36377,
	"alv-dur",
	"Latn",
}

m["pga"] = {
	"tiếng Ả Rập Juba",
	1262143,
	"crp",
	"Latn",
	"Tiếng Ả Rập Juba",
	"Ả Rập Juba",
	ancestors = "apd",
}

m["pgd"] = {
	"tiếng Càn-đà-la",
	nil,
	"inc-mid",
	"Deva, Khar",
	"Tiếng Càn-đà-la",
	"Càn-đà-la",
	ancestors = "inc-ash",
	translit = "Khar-translit",
}

m["pgg"] = {
	"tiếng Pangwala",
	13600429,
	"him",
	"Deva, Takr",
	"Tiếng Pangwala",
	"Pangwala",
	translit = "hi-translit",
}

m["pgi"] = {
	"Pagi",
	7124354,
	"paa-brd",
	"Latn",
}

m["pgk"] = {
	"Rerep",
	586907,
	"poz-vnc",
	"Latn",
}

m["pgl"] = {
	"tiếng Ireland nguyên thủy",
	3320030,
	"cel-gae",
	"Ogam, Latn",
	translit = "pgl-translit",
}

m["pgn"] = {
	"tiếng Paeligni",
	65455883,
	"itc-sbl",
	"Latn, Ital",
	"Tiếng Paeligni",
	"Paeligni",
	translit = {Ital = "Ital-translit"},
}

m["pgs"] = {
	"Pangseng",
	3914027,
	"alv-mum",
	"Latn",
}

m["pgu"] = {
	"tiếng Pagu",
	7124462,
	"paa-nha",
	"Latn",
	"Tiếng Pagu",
	"Pagu",
}

m["pgz"] = {
	"Papua New Guinean Sign Language",
	25044405,
	"sgn",
}

m["pha"] = {
	"tiếng Pà Thẻn",
	2625410,
	"hmn",
	"Latn",
	"Tiếng Pà Thẻn",
	"Pà Thẻn"
}

m["phd"] = {
	"Phudagi",
	7188289,
}

m["phg"] = {
	"tiếng Cơ Tu Phương",
	7188376,
	"mkh-kat",
	"Latn",
	"Tiếng Cơ Tu Phương",
	"Cơ Tu Phương",
}

m["phh"] = {
	"Phukha",
	7188298,
	"tbq-phw",
}

m["phk"] = {
	"tiếng Phake",
	7675798,
	"tai-swe",
	"Mymr",
	"Tiếng Phake",
	"Phake",
	translit = "aio-phk-translit",
	entry_name = {remove_diacritics = c.VS01},
}

m["phl"] = {
	"tiếng Phalura",
	2449549,
	"inc-shn",
	"Latn, ur-Arab",
	"Tiếng Phalura",
	"Phalura",
}

m["phm"] = {
	"Phimbi",
	11007144,
	"bnt-sna",
	"Latn",
}

m["phn"] = {
	"tiếng Phoenicia",
	36734,
	"sem-can",
	"Phnx",
	"Tiếng Phoenicia",
	"Phoenicia",
	translit = "Phnx-translit",
}

m["pho"] = {
	"tiếng Phunoi",
	7188361,
	"tbq-bis",
	"Laoo",
	"Tiếng Phunoi",
	"Phunoi",
}

m["phq"] = {
	"Phana'",
	7180427,
	"tbq-sil",
}

m["phr"] = {
	"tiếng Pothohar",
	33739,
	"inc-pan",
	"pa-Arab, Guru",
	"Tiếng Pothohar",
	"Pothohar",
	ancestors = "lah",
	translit = {
		Guru = "Guru-translit",
		["pa-Arab"] = "pa-Arab-translit",
	},
	entry_name = {
		["pa-Arab"] = {
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna,
			from = {"ݨ", "ࣇ"},
			to = {"ن", "ل"}
		},
	}
}

m["pht"] = {
	"tiếng Phu Thái",
	3626597,
	"tai-swe",
	"Thai",
	"Tiếng Phu Thái",
	"Phu Thái",
}

m["phu"] = {
	"tiếng Phuan",
	3915665,
	nil,
	"Thai",
	"Tiếng Phuan",
	"Phuan",
}

m["phv"] = {
	"Pahlavani",
	7124567,
}

m["phw"] = {
	"Phangduwali",
	12953036,
	"sit-kie",
	ancestors = "ybh",
}

m["pia"] = {
	"Pima Bajo",
	3388544,
	"azc",
	"Latn",
}

m["pib"] = {
	"Yine",
	3135432,
	"awd",
	"Latn",
}

m["pic"] = {
	"Pinji",
	36296,
	"bnt-tso",
	"Latn",
}

m["pid"] = {
	"Piaroa",
	3382207,
	nil,
	"Latn",
}

m["pie"] = {
	"Piro",
	7198055,
	"nai-kta",
	"Latn",
}

m["pif"] = {
	"Pingelapese",
	36421,
	"poz-mic",
	"Latn",
}

m["pig"] = {
	"Pisabo",
	966883,
	"sai-pan",
	"Latn",
}

m["pih"] = {
	"Pitcairn-Norfolk",
	36554,
	"crp",
	"Latn",
	ancestors = "en",
}

m["pii"] = {
	"Pini",
	10631925,
}

m["pij"] = {
	"Pijao",
	7193519,
}

m["pil"] = {
	"tiếng Yom",
	36893,
	"nic-yon",
	"Latn",
	"Tiếng Yom",
	"Yom",
}

m["pim"] = {
	"Powhatan",
	2270532,
	"alg-eas",
	"Latn",
}

m["pin"] = {
	"Piame",
	7190042,
}

m["pio"] = {
	"Piapoco",
	3382208,
	"awd-nwk",
	"Latn",
}

m["pip"] = {
	"Pero",
	2411063,
	"cdc-wst",
}

m["pir"] = {
	"Piratapuyo",
	3389119,
	"sai-tuc",
	"Latn",
}

m["pis"] = {
	"Pijin",
	36699,
	"crp",
	"Latn",
	ancestors = "en",
}

m["pit"] = {
	"Pitta-Pitta",
	6433116,
	"aus-kar",
	"Latn",
}

m["piu"] = {
	"Pintupi-Luritja",
	2591175,
	"aus-pam",
}

m["piv"] = {
	"Pileni",
	2976736,
	"poz-pnp",
	"Latn",
}

m["piw"] = {
	"Pimbwe",
	3894132,
	"bnt-mwi",
}

m["pix"] = {
	"Piu",
	7199578,
}

m["piy"] = {
	"Piya-Kwonci",
	3440492,
}

m["piz"] = {
	"Pije",
	3388339,
	"poz-cln",
	"Latn",
}

m["pjt"] = {
	"tiếng Pitjantjatjara",
	2982063,
	"aus-pam",
	"pjt-Latn",
	"Tiếng Pitjantjatjara",
	"Pitjantjatjara",
}

m["pkb"] = {
	"Kipfokomo",
	7208693,
	"bnt-sab",
	"Latn",
}

m["pkc"] = {
	"tiếng Bách Tế",
	4841264,
	"qfa-kor",
	"Hani, Kana",
	"Tiếng Bách Tế",
	"Bách Tế",
	sort_key = {
		Hani = "Hani-sortkey",
		Kana = "Kana-sortkey"
	},
}

m["pkg"] = {
	"Pak-Tong",
	3360711,
}

m["pkh"] = {
	"Pankhu",
	7130962,
	"tbq-kuk",
}

m["pkn"] = {
	"Pakanha",
	954916,
	"aus-pmn",
}

m["pko"] = {
	"Pökoot",
	36323,
	"sdv-kln",
}

m["pkp"] = {
	"Pukapukan",
	36447,
	"poz-pnp",
	"Latn",
}

m["pkr"] = {
	"tiếng Kurumba Attapady",
	16835180,
	"dra-imd",
	"Mlym",
	"Tiếng Kurumba Attapady",
	"Kurumba Attapady",
	translit = "ml-translit",
}

m["pks"] = {
	"Pakistan Sign Language",
	22964057,
	"sgn",
}

m["pkt"] = {
	"tiếng Mã Liềng",
	6583562,
	"mkh-vie",
	nil,
	"Tiếng Mã Liềng",
	"Mã Liềng",
}

m["pku"] = {
	"tiếng Paku",
	2932604,
	"poz-bre",
	"Latn",
	"Tiếng Paku",
	"Paku"
}

m["pla"] = {
	"Miani",
	12952844,
	nil,
	"Latn",
}

m["plb"] = {
	"Polonombauk",
	7225957,
	"poz-vnc",
	"Latn",
}

m["plc"] = {
	"Central Palawano",
	12953795,
	"phi",
	"Latn",
}

m["ple"] = {
	"Palu'e",
	2196866,
	"poz-cet",
	"Latn",
}

m["plg"] = {
	"tiếng Pilagá",
	2748259,
	"sai-guc",
	"Latn",
	"Tiếng Pilagá",
	"Pilagá",
}

m["plh"] = {
	"Paulohi",
	7155331,
	"poz-cma",
}

m["plj"] = {
	"tiếng Polci",
	3914383,
	"Ngôn ngữ không xếp loại",
	"Latn",
	"Tiếng Polci",
	"Polci",
}

m["plk"] = {
	"tiếng Shina Kohistan",
	12953882,
	"inc-shn",
	"ur-Arab",
	"Tiếng Shina Kohistan",
	"Shina Kohistan",
}

m["pll"] = {
	"tiếng Palaung Shwe",
	27941664,
	"mkh-pal",
	"Mymr",
	"Tiếng Palaung Shwe",
	"Palaung Shwe",
}

m["pln"] = {
	"tiếng Palenquero",
	36665,
	"crp",
	"Latn",
	"Tiếng Palenquero",
	"Palenquero",
	ancestors = "es",
}

m["plo"] = {
	"Oluta Popoluca",
	5908687,
	"nai-miz",
	"Latn",
}

m["plq"] = {
	"tiếng Pala",
	36582,
	"ine-ana",
	"Xsux",
	"Tiếng Pala",
	"Pala",
}

m["plr"] = {
	"Palaka Senoufo",
	36346,
	"alv-snf",
	"Latn",
}

m["pls"] = {
	"San Marcos Tlalcoyalco Popoloca",
	12641692,
	"omq-pop",
	"Latn",
}

m["plu"] = {
	"Palikur",
	3073448,
	"awd",
	"Latn",
}

m["plv"] = {
	"Southwest Palawano",
	15614922,
	"phi",
	"Latn",
}

m["plw"] = {
	"tiếng Palawano Brooke's Point",
	12953796,
	"phi",
	"Latn",
	"Tiếng Palawano Brooke's Point",
	"Palawano Brooke's Point",
}

m["ply"] = {
	"tiếng Bố Lưu",
	3361723,
	"mkh-pkn",
	"Latn",
	"Tiếng Bố Lưu",
	"Bố Lưu",
}

m["plz"] = {
	"Paluan",
	7128795,
	nil,
	"Latn",
}

m["pma"] = {
	"Paama",
	3130286,
	"poz-vnc",
	"Latn",
}

m["pmb"] = {
	"Pambia",
	36267,
	"znd",
	"Latn",
}

m["pmd"] = {
	"Pallanganmiddang",
	7127734,
	"aus-pam",
	"Latn",
}

m["pme"] = {
	"Pwaamei",
	3411152,
	"poz-cln",
	"Latn",
}

m["pmf"] = {
	"Pamona",
	3513320,
	"poz-kal",
	"Latn",
}

m["pmi"] = {
	"Northern Pumi",
	3403245,
	"sit-qia",
}

m["pmj"] = {
	"Southern Pumi",
	3403246,
	"sit-qia",
}

m["pmk"] = {
	"Pamlico",
	nil,
	"alg-eas",
	"Latn",
}

m["pml"] = {
	"Sabir",
	636479,
	"crp",
	"Latn",
	ancestors = "lij, pro, vec",
}

m["pmm"] = {
	"Pol",
	36408,
	"bnt-kak",
	"Latn",
}

m["pmn"] = {
	"Pam",
	7129017,
	"alv-mbm",
}

m["pmo"] = {
	"Pom",
	7227178,
	"poz-hce",
	"Latn",
}

m["pmq"] = {
	"Northern Pame",
	3361762,
	"omq",
	"Latn",
}

m["pmr"] = {
	"Paynamar",
	3450824,
}

m["pms"] = {
	"tiếng Piemonte",
	15085,
	"roa-git",
	"Latn",
	"Tiếng Piemonte",
	"Piemonte",
}

m["pmt"] = {
	"tiếng Tuamotu",
	36763,
	"poz-pep",
	"Latn",
	"Tiếng Tuamotu",
	"Tuamotu",
}

m["pmu"] = {
	"Mirpur Panjabi",
	6874480,
}

m["pmw"] = {
	"Plains Miwok",
	3391031,
	"nai-you",
	"Latn",
}

m["pmx"] = {
	"Poumei Naga",
	12952910,
	"tbq-anp",
}

m["pmy"] = {
	"Papuan Malay",
	12473446,
	nil,
	"Latn",
}

m["pmz"] = {
	"Southern Pame",
	3361765,
	"omq",
	"Latn",
}

m["pna"] = {
	"Punan Bah-Biau",
	4842201,
}

m["pnb"] = {
	"Western Panjabi",
	58635,
	"inc-pan",
	"pa-Arab",
	ancestors = "pa",
}

m["pnc"] = {
	"Pannei",
	7131391,
}

m["pnd"] = {
	"Mpinda",
	63308194,
	"bnt-kmb",
}

m["pne"] = {
	"Western Penan",
	12953808,
	"poz-swa",
	"Latn",
}

m["png"] = {
	"Pongu",
	36282,
	"nic-shi",
}

m["pnh"] = {
	"Penrhyn",
	3130301,
	"poz-pep",
	"Latn",
}

m["pni"] = {
	"Aoheng",
	4778608,
	"poz",
}

m["pnj"] = {
	"Pinjarup",
	33103591,
}

m["pnk"] = {
	"tiếng Pauna",
	2064378,
	"awd",
	"Latn",
	"Tiếng Pauna",
	"Pauna",
}

m["pnl"] = {
	"Paleni",
	7127118,
	"alv-wan",
	"Latn",
}

m["pnm"] = {
	"Punan Batu",
	7259892,
}

m["pnn"] = {
	"Pinai-Hagahai",
	5638511,
}

m["pno"] = {
	"Panobo",
	3141869,
	"sai-pan",
	"Latn",
}

m["pnp"] = {
	"tiếng Pancana",
	7130204,
	"poz-mun",
	"Latn",
	"Tiếng Pancana",
	"Pancana"
}

m["pnq"] = {
	"Pana (West Africa)",
	7129739,
	"nic-gnn",
	"Latn",
}

m["pnr"] = {
	"Panim",
	11732562,
	"ngf-mad",
}

m["pns"] = {
	"tiếng Ponosakan",
	7227956,
	"phi",
	"Latn",
	"Tiếng Ponosakan",
	"Ponosakan",
}

m["pnt"] = {
	"tiếng Hy Lạp Pontos",
	36748,
	"grk",
	"Grek, Latn, Cyrl",
	"Tiếng Hy Lạp Pontos",
	"Hy Lạp Pontos",
	ancestors = "gkm",
	translit = {Grek = "el-translit"},
	entry_name = {remove_diacritics = c.caron .. c.diaerbelow .. c.brevebelow},
	sort_key = s["Grek-sortkey"],
}

m["pnu"] = {
	"Jiongnai Bunu",
	56325,
	"hmn",
}

m["pnv"] = {
	"Pinigura",
	10631927,
	"aus-psw",
	"Latn",
}

m["pnw"] = {
	"Panyjima",
	3913830,
	"aus-nga",
	"Latn",
}

m["pnx"] = {
	"tiếng Phong-Kniang",
	3914627,
	"mkh",
	nil,
	"Tiếng Phong-Kniang",
	"Phong-Kniang",
}

m["pny"] = {
	"tiếng Pinyin",
	36250,
	"nic-nge",
	"Latn",
	"Tiếng Pinyin",
	"Pinyin",
}

m["pnz"] = {
	"Pana (Central Africa)",
	36241,
	"alv-mbm",
	"Latn",
}

m["poc"] = {
	"Poqomam",
	36416,
	"myn",
	"Latn",
}

m["poe"] = {
	"San Juan Atzingo Popoloca",
	12953819,
	"omq-pop",
	"Latn",
}

m["pof"] = {
	"Poke",
	7208577,
	"bnt-ske",
}

m["pog"] = {
	"Potiguára",
	56722,
	"tup-gua",
	"Latn",
}

m["poh"] = {
	"Poqomchi'",
	36414,
	"myn",
	"Latn",
}

m["poi"] = {
	"tiếng Popoluca cao nguyên",
	7511556,
	"nai-miz",
	"Latn",
	"Tiếng Popoluca cao nguyên",
	"Popoluca cao nguyên",
}

m["pok"] = {
	"Pokangá",
	25559704,
	"sai-tuc",
	"Latn",
}

m["pom"] = {
	"Southeastern Pomo",
	3396025,
	"nai-pom",
	"Latn",
}

m["pon"] = {
	"tiếng Pohnpei",
	28422,
	"poz-mic",
	"Latn",
	"Tiếng Pohnpei",
	"Pohnpei",
}

m["poo"] = {
	"Central Pomo",
	3396020,
	"nai-pom",
	"Latn",
}

m["pop"] = {
	"Pwapwa",
	3411153,
	"poz-cln",
	"Latn",
}

m["poq"] = {
	"Texistepec Popoluca",
	5908707,
	"nai-miz",
	"Latn",
}

m["pos"] = {
	"Sayula Popoluca",
	5908722,
	"nai-miz",
	"Latn",
}

m["pot"] = {
	"tiếng Potawatomi",
	56749,
	"alg",
	"Latn",
	"Tiếng Potawatomi",
	"Potawatomi",
}

m["pov"] = {
	"tiếng Creole Guinea-Bissau",
	33339,
	"crp",
	"Latn",
	"Tiếng Creole Guinea-Bissau",
	"Creole Guinea-Bissau",
	ancestors = "pt",
}

m["pow"] = {
	"San Felipe Otlaltepec Popoloca",
	25559598,
	"omq-pop",
	"Latn",
}

m["pox"] = {
	"tiếng Polabia",
	36741,
	"zlw-lch",
	"Latn",
	"Tiếng Polabia",
	"Polabia",
}

m["poy"] = {
	"Pogolo",
	2429648,
	"bnt-kil",
}

m["ppa"] = {
	"Pao",
	7132069,
}

m["ppe"] = {
	"Papi",
	7132809,
}

m["ppi"] = {
	"Paipai",
	56726,
	"nai-yuc",
	"Latn",
}

m["ppk"] = {
	"Uma",
	7881036,
	"poz-kal",
	"Latn",
}

m["ppl"] = {
	"tiếng Pipil",
	1186896,
	"azc-nah",
	"Latn",
	"Tiếng Pipil",
	"Pipil",
	entry_name = {remove_diacritics = c.acute .. c.macron},
}

m["ppm"] = {
	"tiếng Papuma",
	7133239,
	"poz-hce",
	"Latn",
}

m["ppn"] = {
	"Papapana",
	3362757,
	"poz-ocw",
	"Latn",
}

m["ppo"] = {
	"tiếng Folopa",
	5464843,
	"paa",
	"Latn",
	"Tiếng Folopa",
	"Folopa",
}

m["ppq"] = {
	"Pei",
	7160903,
}

m["pps"] = {
	"San Luís Temalacayuca Popoloca",
	25559602,
	"omq-pop",
	"Latn",
}

m["ppt"] = {
	"Pa",
	3504757,
	"ngf",
	"Latn",
}

m["ppu"] = {
	"Papora",
	2094884,
	"map",
	"Latn",
}

m["pqa"] = {
	"Pa'a",
	3441315,
	"cdc-wst",
}

m["pqm"] = {
	"tiếng Malecite-Passamaquoddy",
	3183144,
	"alg-eas",
	"Latn",
	"Tiếng Malecite-Passamaquoddy",
	"Malecite-Passamaquoddy",
}

m["pra"] = {
	"tiếng Prakrit",
	192170,
	"inc-mid",
	"Brah, Deva, Gujr, Knda",
	"Tiếng Prakrit",
	"Prakrit",
	ancestors = "inc-ash",
	translit = {
		-- Brah translit in [[Module:scripts/data]]
		Deva = "pra-Deva-translit",
		Gujr = "sa-Gujr-translit",
		Knda = "pra-Knda-translit",
	},
	strip_diacritics = {
		-- FIXME: separate by script
		from = {"ऎ", "ऒ", u(0x0946), u(0x094A), "य़", "ಯ಼", u(0x11071), u(0x11072), u(0x11073), u(0x11074)},
		to = {"ए", "ओ", u(0x0947), u(0x094B), "य", "ಯ", "𑀏", "𑀑", u(0x11042), u(0x11044)}
	} ,
}

m["prc"] = {
	"tiếng Parachi",
	2640637,
	"ira-orp",
	"Arab",
	"Tiếng Parachi",
	"Parachi",
}

-- "prd" IS NOT INCLUDED, SEE WT:LT

m["pre"] = {
	"Principense",
	36520,
	"crp",
	"Latn",
	ancestors = "pt",
}

m["prf"] = {
	"Paranan",
	7135433,
	"phi",
}

m["prg"] = {
	"tiếng Phổ cổ",
	35501,
	"bat-wes",
	"Latn",
	"Tiếng Phổ cổ",
	"Phổ cổ",
}

m["prh"] = {
	"Porohanon",
	6583710,
	"phi",
}

m["pri"] = {
	"Paicî",
	732131,
	"poz-cln",
	"Latn",
}

m["prk"] = {
	"tiếng Parauk",
	3363719,
	"mkh-pal",
	nil,
	"Tiếng Parauk",
	"Parauk",
}

m["prl"] = {
	"Peruvian Sign Language",
	3915508,
	"sgn",
}

m["prm"] = {
	"Kibiri",
	56745,
	"paa",
}

m["prn"] = {
	"tiếng Prasun",
	32689,
	"nur-nor",
	nil,
	"Tiếng Prasun",
	"Prasun",
}

m["pro"] = {
	"tiếng Occitan cổ",
	2779185,
	"roa-ocr",
	"Latn",
	"Tiếng Occitan cổ",
	"Occitan cổ",
	sort_key = {remove_diacritics = c.cedilla},
}

-- "prp" IS NOT INCLUDED, SEE WT:LT

m["prq"] = {
	"Ashéninka Perené",
	3450601,
	"awd",
	"Latn",
}

m["prr"] = {
	"Puri",
	7261687,
}

-- "prs" IS TREATED AS "fa" (or as etymology-only), SEE WT:LT

m["prt"] = {
	"tiếng Phai",
	7180184,
	"mkh-khm",
	"Thai",
	"Tiếng Phai",
	"Phai",
}

m["pru"] = {
	"Puragi",
	7260800,
	"ngf-sbh",
}

m["prw"] = {
	"Parawen",
	7136291,
	"ngf-mad",
}

m["prx"] = {
	"Purik",
	567905,
	"sit-lab",
}

m["prz"] = {
	"Providencia Sign Language",
	3322084,
	"sgn",
}

m["psa"] = {
	"Asue Awyu",
	11266334,
}

m["psc"] = {
	"Persian Sign Language",
	7170221,
	"sgn",
}

m["psd"] = {
	"Plains Indian Sign Language",
	2380124,
	"sgn",
}

m["pse"] = {
	"Central Malay",
	3367751,
	"poz-mly",
}

m["psg"] = {
	"Penang Sign Language",
	4924925,
	"sgn",
}

m["psh"] = {
	"Southwest Pashayi",
	16112270,
	"inc-pas",
	"fa-Arab",
}

m["psi"] = {
	"Southeast Pashayi",
	23713536,
	"inc-pas",
	"fa-Arab",
}

m["psl"] = {
	"Puerto Rican Sign Language",
	7258608,
	"sgn-fsl",
}

m["psm"] = {
	"Pauserna",
	2912846,
	"tup-gua",
	"Latn",
}

m["psn"] = {
	"Panasuan",
	7130113,
	"poz",
}

m["pso"] = {
	"Polish Sign Language",
	3915194,
	"sgn-gsl",
}

m["psp"] = {
	"Philippine Sign Language",
	3551357,
	"sgn-fsl",
}

m["psq"] = {
	"Pasi",
	7142091,
}

m["psr"] = {
	"Portuguese Sign Language",
	3915472,
	"sgn",
}

m["pss"] = {
	"Kaulong",
	3194294,
	"poz-ocw",
}

m["psu"] = {
	"tiếng Prakrit Saurasen",
	2452885,
	"inc-psu",
	"Brah, Deva",
	"Tiếng Prakrit Saurasen",
	"Prakrit Saurasen",
	translit = "Brah-translit",
	ancestors = "inc-pra",
}

m["psw"] = {
	"Port Sandwich",
	3398324,
	"poz-vnc",
	"Latn",
}

m["psy"] = {
	"Piscataway",
	3504233,
	"alg-eas",
}

m["pta"] = {
	"Pai Tavytera",
	7124619,
	"tup-gua",
	"Latn",
}

m["pth"] = {
	"Pataxó Hã-Ha-Hãe",
	7144304,
}

m["pti"] = {
	"Pintiini",
	10632026,
	"aus-pam",
}

m["ptn"] = {
	"Patani",
	7144242,
	"poz-hce",
	"Latn",
}

m["pto"] = {
	"Zo'é",
	8073148,
	"tup-gua",
	"Latn",
}

m["ptp"] = {
	"Patep",
	3368679,
	"poz-ocw",
	"Latn",
}

m["ptq"] = {
	"Pattapu",
	60785085,
	"dra-tam",
}

m["ptr"] = {
	"Piamatsina",
	7190040,
	"poz-vnc",
	"Latn",
}

m["ptt"] = {
	"Enrekang",
	12953520,
}

m["ptu"] = {
	"Bambam",
	4853321,
	"poz-ssw",
}

m["ptv"] = {
	"Port Vato",
	3398323,
	nil,
	"Latn",
}

m["ptw"] = {
	"Pentlatch",
	2069475,
	"sal",
	"Latn",
}

m["pty"] = {
	"Pathiya",
	7144790,
	"dra-mal",
}

m["pua"] = {
	"Purepecha",
	16114351,
	"qfa-iso",
	"Latn",
	sort_key = {remove_diacritics = c.acute},
}

m["pub"] = {
	"Purum",
	6400562,
	"tbq-kuk",
	"Latn",
}

m["puc"] = {
	"Punan Merap",
	7259895,
}

m["pud"] = {
	"Punan Aput",
	4782333,
}

m["pue"] = {
	"Puelche",
	33660,
}

m["puf"] = {
	"Punan Merah",
	7259894,
}

m["pug"] = {
	"Phuie",
	36375,
	"nic-gnw",
}

m["pui"] = {
	"tiếng Puinave",
	3027918,
	nil,
	"Latn",
	"Tiếng Puinave",
	"Puinave",
}

m["puj"] = {
	"Punan Tubu",
	7259896,
	"poz-swa",
}

m["pum"] = {
	"Puma",
	33736,
	"sit-kic",
}

m["puo"] = {
	"tiếng Xinh Mun",
	6440803,
	"mkh-khm",
	nil,
	"Tiếng Xinh Mun",
	"Xinh Mun"
}

m["pup"] = {
	"Pulabu",
	7259163,
	"ngf-mad",
}

m["puq"] = {
	"Puquina",
	1207739,
}

m["pur"] = {
	"Puruborá",
	7261619,
	"tup",
}

m["put"] = {
	"Putoh",
	12953832,
	"poz-swa",
	"Latn",
}

m["puu"] = {
	"tiếng Punu",
	36401,
	"bnt-sir",
	"Latn",
	"Punu",
	"Tiếng Punu",
}

m["puw"] = {
	"Puluwat",
	36397,
	"poz-mic",
	"Latn",
}

m["pux"] = {
	"Puare",
	3507983,
}

m["puy"] = {
	"Purisimeño",
	2967638,
	"nai-chu",
	"Latn",
}

m["pwa"] = {
	"Pawaia",
	7156099,
	"paa",
	"Latn",
}

m["pwb"] = {
	"Panawa",
	47385077,
	"nic-jer",
	"Latn",
	ancestors = "jer",
}

m["pwg"] = {
	"Gapapaiwa",
	3095245,
	"poz-ocw",
	"Latn",
}

m["pwi"] = {
	"Patwin",
	3370188,
	"nai-wtq",
	"Latn",
}

m["pwm"] = {
	"tiếng Molbog",
	6895718,
	"poz-san",
	"Latn",
	"Tiếng Molbog",
	"Molbog"
}

m["pwn"] = {
	"tiếng Paiwan",
	715755,
	"map",
	"Latn",
	"Tiếng Paiwan",
	"Paiwan",
}

m["pwo"] = {
	"tiếng Pwo Tây",
	7988202,
	"kar",
	"Mymr",
	"Tiếng Pwo Tây",
	"Pwo Tây",
}

m["pwr"] = {
	"Powari",
	12640277,
	"inc-hie",
	"Deva",
}

m["pww"] = {
	"tiếng Pwo Bắc",
	7058885,
	"kar",
	"Thai",
	"Tiếng Pwo Bắc",
	"Pwo Bắc",
}

m["pxm"] = {
	"Quetzaltepec Mixe",
	6842374,
	"nai-miz",
	"Latn",
}

m["pye"] = {
	"Pye Krumen",
	11157382,
	"kro-grb",
}

m["pym"] = {
	"Fyam",
	3914025,
	"nic-ple",
	"Latn",
}

m["pyn"] = {
	"Poyanáwa",
	3401023,
	"sai-pan",
}

m["pys"] = {
	"Paraguayan Sign Language",
	7134698,
	"sgn",
}

m["pyu"] = {
	"tiếng Puyuma",
	716690,
	"map",
	"Latn",
	"Tiếng Puyuma",
	"Puyuma",
}

m["pyx"] = {
	"Tircul",
	36259,
	"sit",
}

m["pyy"] = {
	"Pyen",
	7262966,
	"tbq-bis",
}

m["pzh"] = {
	"tiếng Pazeh",
	36435,
	"map",
	"Latn",
	"Tiếng Pazeh",
	"Pazeh",
}

m["pzn"] = {
	"Para Naga",
	7133667,
	"sit-aao",
}

return require("Module:languages").finalizeData(m, "language")