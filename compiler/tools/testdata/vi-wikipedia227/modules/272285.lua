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

m["ebg"] = {
	"tiếng Ebughu",
	35294,
	"nic-lcr",
	"Latn",
	"Tiếng Ebughu",
	"Ebughu",
}

m["ebk"] = {
	"tiếng Đông Bontoc",
	nil,
	"phi",
	"Latn",
	"Tiếng Đông Bontoc",
	"Đông Bontoc",
}

m["ebr"] = {
	"tiếng Ebrié",
	36644,
	"alv-ptn",
	"Latn",
	"Tiếng Ebrié",
	"Ebrié",
}

m["ebu"] = {
	"tiếng Embu",
	35318,
	"bnt-kka",
	"Latn",
	"Tiếng Embu",
	"Embu",
}

m["ecr"] = {
	"tiếng Eteocrete",
	35461,
	nil,
	"Grek",
	"Tiếng Eteocrete",
	"Eteocrete",
	sort_key = s["Grek-sortkey"],
}

m["ecs"] = {
	"Ecuadorian Sign Language",
	3436769,
	"sgn",
	"Latn", -- when documented
}

m["ecy"] = {
	"Eteocypriot",
	35309,
	nil,
	"Cprt",
}

m["eee"] = {
	"tiếng Ai",
	35386,
	"qfa-mix",
	"Hani, Latn",
	sort_key = {Hani = "Hani-sortkey"},
	"Tiếng Ai",
	"Ai",
}

m["efa"] = {
	"tiếng Efai",
	3813297,
	"nic-ief",
	"Latn",
	"Tiếng Efai",
	"Efai",
}

m["efe"] = {
	"tiếng Efe",
	56354,
	"csu-mle",
	"Latn",
	"Tiếng Efe",
	"Efe",
}

m["efi"] = {
	"tiếng Efik",
	35377,
	"nic-ief",
	"Latn",
	"Tiếng Efik",
	"Efik",
}

m["ega"] = {
	"tiếng Ega",
	3914927,
	"alv",
	"Latn",
	"Tiếng Ega",
	"Ega",
}

m["egl"] = {
	"tiếng Emilia",
	1057898,
	"roa-git",
	"Latn",
	"Tiếng Emilia",
	"Emilia",
	wikimedia_codes = "eml",
}

m["ego"] = {
	"tiếng Eggon",
	35300,
	"nic-pls",
	"Latn",
	"Tiếng Eggon",
	"Eggon",
}

m["egy"] = {
	"tiếng Ai Cập",
	50868,
	"egx",
	"Latn, Egyp, Egyh",
	"Tiếng Ai Cập",
	"Ai Cập",
	sort_key = {
		remove_diacritics = "'%-%s",
		from = {"ꜣ", "j", "y", "ꜥ", "w", "b", "p", "f", "m", "n", "r", "ḥ", "ḫ", "ẖ", "h", "z", "š", "s", "q", "k", "g", "ṯ", "t", "ḏ", "d", "%."},
		to = {p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11], p[13], p[14], p[15], p[12], p[16], p[18], p[17], p[19], p[20], p[21], p[23], p[22], p[25], p[24], p[26]}
	},

}

m["ehu"] = {
	"tiếng Ehueun",
	3441392,
	"alv-nwd",
	"Latn",
	"Tiếng Ehueun",
	"Ehueun",
}

m["eip"] = {
	"tiếng Eipomek",
	5349839,
	"ngf",
	"Latn",
	"Tiếng Eipomek",
	"Eipomek",
}

m["eit"] = {
	"tiếng Eitiep",
	5350030,
	"qfa-tor",
	"Latn",
	"Tiếng Eitiep",
	"Eitiep",
}

m["eiv"] = {
	"tiếng Askopan",
	56324,
	"paa-nbo",
	"Latn",
	"Tiếng Askopan",
	"Askopan",
}

m["eja"] = {
	"Ejamat",
	6269820,
	"alv-jfe",
	"Latn",
	"Tiếng Ejamat",
	"Ejamat",
}

m["eka"] = {
	"Ekajuk",
	35250,
	"nic-eko",
	"Latn",
}

m["eke"] = {
	"Ekit",
	3509628,
	"nic-ief",
	"Latn",
}

m["ekg"] = {
	"Ekari",
	5350305,
	"ngf",
	"Latn",
}

m["eki"] = {
	"Eki",
	5350418,
	"nic-ief",
	"Latn",
}

m["ekl"] = {
	"tiếng Kolhe",
	6426945,
	"mun",
	"Beng, Latn",
	"Tiếng Kolhe",
	"Kolhe",
}

m["ekm"] = {
	"Elip",
	12952414,
	"nic-ymb",
	"Latn",
}

m["eko"] = {
	"Koti",
	29930,
	"bnt-mak",
	"Latn",
}

m["ekp"] = {
	"Ekpeye",
	35254,
	"alv-igb",
	"Latn",
}

m["ekr"] = {
	"Yace",
	36901,
	"alv-ido",
	"Latn",
}

m["eky"] = {
	"tiếng Đông Kayah",
	25559417,
	"kar",
	"Kali, Thai",
	"Tiếng Đông Kayah",
	"Đông Kayah",
}

m["ele"] = {
	"Elepi",
	5359444,
	"qfa-tor",
	"Latn",
}

m["elh"] = {
	"El Hugeirat",
	5351410,
	"nub-hil",
	"Latn",
}

m["eli"] = {
	"Nding",
	36176,
	"alv-tal",
	"Latn",
}

m["elk"] = {
	"Elkei",
	5364210,
	"qfa-tor",
	"Latn",
}

m["elm"] = {
	"Eleme",
	3914427,
	"nic-ogo",
	"Latn",
}

m["elo"] = {
	"tiếng El Molo",
	56719,
	"cus-eas",
	"Latn",
	"Tiếng El Molo",
	"El Molo",
}

m["elu"] = {
	"Elu",
	3364594,
	"poz-aay",
	"Latn",
}

m["elx"] = {
	"tiếng Elam",
	35470,
	"qfa-iso",
	"Xsux",
	"Tiếng Elam",
	"Elam",
}

m["ema"] = {
	"Emai",
	35428,
	"alv-eeo",
	"Latn",
}

m["emb"] = {
	"Embaloh",
	5369424,
	"poz",
	"Latn",
}

m["eme"] = {
	"Emerillon",
	3588942,
	"tup-gua",
	"Latn",
}

m["emg"] = {
	"Eastern Meohang",
	12952840,
	"sit-kie",
	"Deva",
}

m["emi"] = {
	"Mussau-Emira",
	6943093,
	"poz-ocw",
	"Latn",
}

m["emk"] = {
	"tiếng Maninkakan Đông",
	11002130,
	"dmn-mnk",
	"Latn, Arab, Nkoo",
}

m["emm"] = {
	"Mamulique",
	3285082,
	"nai-pak",
	"Latn",
}

m["emn"] = {
	"Eman",
	5368975,
	"nic-tvc",
	"Latn",
}

m["emp"] = {
	"tiếng Bắc Emberá",
	2391297,
	"sai-chc",
	"Latn",
	"Tiếng Bắc Emberá",
	"Bắc Emberá",
}

m["ems"] = {
	"tiếng Alutiiq",
	27992,
	"ypk",
	"Latn",
	"Tiếng Alutiiq",
	"Alutiiq",
}

m["emu"] = {
	"Eastern Muria",
	12952883,
	"dra-mur",
}

m["emw"] = {
	"Emplawas",
	5374265,
	"poz-tim",
	"Latn",
}

m["emx"] = {
	"Erromintxela",
	1122188,
	"qfa-mix",
	"Latn",
	ancestors = "eu, rom",
}

m["emy"] = {
	"Epigraphic Mayan",
	301355,
	"myn",
	"Latn, Maya",
}

m["ena"] = {
	"Apali",
	3504201,
	"ngf-mad",
	"Latn",
}

m["enb"] = {
	"Markweeta",
	56874,
	"sdv-nma",
	"Latn",
}

m["enc"] = {
	"tiếng Nùng Vẻn",
	3504110,
	"qfa-buy",
	"Latn",
	"Tiếng Nùng Vẻn",
	"Nùng Vẻn"
}

m["end"] = {
	"Ende",
	2067656,
	"poz-cet",
	"Latn",
}

m["enf"] = {
	"tiếng Enets rừng",
	30249597,
	"syd",
	"Cyrl",
	"Tiếng Enets rừng",
	"Enets rừng",
}

m["enh"] = {
	"tiếng Enets lãnh nguyên",
	25559411,
	"syd",
	"Cyrl",
	"Tiếng Enets lãnh nguyên",
	"Enets lãnh nguyên",
}

m["enl"] = {
	"Enlhet",
	15462671,
	"sai-mas",
	"Latn",
}

m["enm"] = {
	"tiếng Anh trung đại",
	36395,
	"gmw-ang",
	"Latn",
	"Tiếng Anh trung đại",
	"Anh trung đại",
	entry_name = {remove_diacritics = c.acute .. c.macron .. c.dotabove},
}

m["enn"] = {
	"tiếng Engenni",
	3915365,
	"alv-dlt",
	"Latn",
	"Tiếng Engenni",
	"Engenni",
}

m["eno"] = {
	"Enggano",
	2669164,
	"poz",
	"Latn",
}

m["enq"] = {
	"Enga",
	1143040,
	"paa-eng",
	"Latn",
}

m["enr"] = {
	"Emem",
	5370369,
	"paa-pau",
}

m["enu"] = {
	"Enu",
	5380858,
	"tbq-bka",
}

m["env"] = {
	"Enwan",
	3438334,
	"alv-yek",
	"Latn",
}

m["enw"] = {
	"Enwang",
	11134434,
	"nic-lcr",
	"Latn",
}

m["enx"] = {
	"Enxet",
	15462609,
	"sai-mas",
	"Latn",
}

m["eot"] = {
	"tiếng Eotile",
	3915347,
	"alv-ptn",
	"Latn",
	"Tiếng Eotile",
	"Eotile",
}

m["epi"] = {
	"tiếng Epie",
	35291,
	"alv-dlt",
	"Latn",
	"Tiếng Epie",
	"Epie",
}

m["era"] = {
	"tiếng Eravalla",
	5385061,
	"dra-tam",
	"Taml",
	"Tiếng Eravalla",
	"Eravalla",
	translit = "ta-translit",
}

m["erg"] = {
	"Sie",
	426254,
	"poz-occ",
	"Latn",
}

m["erh"] = {
	"Eruwa",
	3441244,
	"alv-swd",
	"Latn",
}

m["eri"] = {
	"Ogea",
	7079984,
	"ngf-mad",
	"Latn",
}

m["erk"] = {
	"tiếng Efate Nam",
	3449070,
	"poz-vnc",
	"Latn",
	"Tiếng Efate Nam",
	"Efate Nam",
}

m["ero"] = {
	"tiếng Horpa",
	56854,
	"sit-rgy",
	nil,
	"Tiếng Horpa",
	"Horpa",
}

m["err"] = {
	"Erre",
	10488401,
	"qfa-iso",
	"Latn",
}

m["ers"] = {
	"tiếng Nhĩ Tô",
	12952417,
	"sit-qia",
	"Latn", -- also Ersu Shaba
	"Tiếng Nhĩ Tô",
	"Nhĩ Tô",
}

m["ert"] = {
	"Eritai",
	56376,
	"paa-lkp",
	"Latn",
}

m["erw"] = {
	"Erokwanas",
	5395296,
	"poz-hce",
	"Latn",
}

m["ese"] = {
	"Ese Ejja",
	2980381,
	"sai-tac",
	"Latn",
}

m["esh"] = {
	"Eshtehardi",
	12952418,
	"xme-ttc",
	"fa-Arab, Latn",
	ancestors = "xme-ttc-sou",
}

-- "esi" and "esk" moved to etymology-only per [[WT:LT]] and [[Wiktionary:Beer_parlour/2023/August#Issues_regarding_the_Inuit_languages]]

m["esl"] = {
	"Egyptian Sign Language",
	5348443,
	"sgn",
}

m["esm"] = {
	"Esuma",
	16927555,
	"alv-kwa",
	"Latn",
}

m["esn"] = {
	"Salvadoran Sign Language",
	7406492,
	"sgn",
	"Latn", -- when documented
}

m["eso"] = {
	"Estonian Sign Language",
	3196221,
	"sgn",
	"Latn", -- when documented
}

m["esq"] = {
	"Esselen",
	1294243,
	"qfa-iso",
	"Latn",
}

m["ess"] = {
	"tiếng Yupik Trung Siberia",
	27993,
	"ypk",
	"Cyrl",
	"Tiếng Yupik Trung Siberia",
	"Yupik Trung Siberia",
}

m["esu"] = {
	"tiếng Yup'ik",
	21117,
	"ypk",
	"Latn",
	"Tiếng Yup'ik",
	"Yup'ik",
}

m["esy"] = {
	"Eskayan",
	867086,
	"art",
	"Latn", -- also its own native script
}

m["etb"] = {
	"Etebi",
	11002851,
	"nic-ief",
	"Latn",
}

m["etc"] = {
	"Etchemin",
	5402493,
	"alg-eas",
	"Latn",
}

m["eth"] = {
	"Ethiopian Sign Language",
	3501903,
	"sgn",
}

m["etn"] = {
	"Eton (Vanuatu)",
	3059362,
	"poz-oce",
	"Latn",
}

m["eto"] = {
	"Eton (Cameroon)",
	35317,
	"bnt-btb",
	"Latn",
}

m["etr"] = {
	"Edolo",
	5340184,
	"ngf",
	"Latn",
}

m["ets"] = {
	"Yekhee",
	3915848,
	"alv-yek",
	"Latn",
}

m["ett"] = {
	"tiếng Etrusca",
	35726,
	"qfa-tyn",
	"Ital",
	"Tiếng Etrusca",
	"Etrusca",
	translit = "Ital-translit",
}

m["etu"] = {
	"tiếng Ejagham",
	35296,
	"nic-eko",
	"Latn",
	"Tiếng Ejagham",
	"Ejagham",
}

m["etx"] = {
	"Eten",
	3915392,
	"nic-beo",
	"Latn",
}

m["etz"] = {
	"Semimi",
	10950308,
	"paa-mai",
	"Latn",
}

m["eve"] = {
	"tiếng Even",
	29960,
	"tuw-ewe",
	"Cyrl, Latn",
	"Tiếng Even",
	"Even",
	translit = {Cyrl = "eve-translit"},
	entry_name = {remove_diacritics = c.macron .. c.dotabove .. c.dotbelow},
	sort_key = {
		Cyrl = {
			from = {
				"ӫ", -- 2 chars
				"ё", "ӈ", "ө" -- 1 char
			},
			to = {
				"о" .. p[2],
				"е" .. p[1], "н" .. p[1], "о" .. p[1]
			},
		},
	},
}

m["evh"] = {
	"tiếng Uvbie",
	3441344,
	"alv-swd",
	"Latn",
	"Tiếng Uvbie",
	"Uvbie",
}

m["evn"] = {
	"tiếng Evenk",
	30004,
	"tuw-ewe",
	"Cyrl",
	"Tiếng Evenk",
	"Evenk",
	translit = "evn-translit",
	entry_name = {remove_diacritics = c.macron .. c.dotabove .. c.dotbelow},
	sort_key = {
		from = {"ё", "ӈ"},
		to = {"е" .. p[1], "н" .. p[1]}
	},
}

m["ewo"] = {
	"tiếng Ewondo",
	35459,
	"bnt-btb",
	"Latn",
	"Tiếng Ewondo",
	"Ewondo",
}

m["ext"] = {
	"Extremaduran",
	30007,
	"roa-ibe",
	"Latn",
}

m["eya"] = {
	"Eyak",
	27480,
	"xnd",
	"Latn",
}

m["eyo"] = {
	"Keiyo",
	56856,
	"sdv-nma",
	"Latn",
}

m["eza"] = {
	"Ezaa",
	11921436,
	"alv-igb",
	"Latn",
	ancestors = "izi",
}

m["eze"] = {
	"Uzekwe",
	3502244,
	"nic-ucn",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")