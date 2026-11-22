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

m["oaa"] = {
	canonicalName = "Orok",
	family = "tuw",
}

m["oac"] = {
	canonicalName = "Oroch",
	family = "tuw",
}

m["oav"] = {
	canonicalName = "Old Avar",
	scripts = {"Geor"},
	family = "cau-ava",
}

m["obi"] = {
	canonicalName = "Obispeño",
	family = "nai-chu",
}

m["obk"] = {
	canonicalName = "Southern Bontoc",
	otherNames = {"Southern Bontok"},
	family = "phi",
}

m["obl"] = {
	canonicalName = "Oblo",
}

m["obm"] = {
	canonicalName = "Moabite",
	scripts = {"Phnx"},
	family = "sem-can",
}

m["obo"] = {
	canonicalName = "Obo Manobo",
	otherNames = {"Obo"},
	family = "mno",
}

m["obr"] = {
	canonicalName = "Old Burmese",
	scripts = {"Mymr"},
	family = "tbq",
}

m["obt"] = {
	canonicalName = "Old Breton",
	scripts = {"Latn"},
	family = "cel-bry",
}

m["obu"] = {
	canonicalName = "Obulom",
	family = "nic-bco",
}

m["oca"] = {
	canonicalName = "Ocaina",
}

m["och"] = {
	canonicalName = "Old Chinese",
	scripts = {"Hani"},
	family = "zhx",
}

m["oco"] = {
	canonicalName = "Old Cornish",
	family = "cel-bry",
}

m["ocu"] = {
	canonicalName = "Tlahuica",
	otherNames = {"Ocuiltec", "Atzingo Matlatzinca"},
	scripts = {"Latn"},
	family = "omq",
}

m["oda"] = {
	canonicalName = "Odut",
	family = "nic-bco",
}

m["odk"] = {
	canonicalName = "Od",
	scripts = {"Arab"},
	family = "inc",
}

m["odt"] = {
	canonicalName = "Old Dutch",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"frk"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["odu"] = {
	canonicalName = "Odual",
	family = "nic-bco",
}

m["ofo"] = {
	canonicalName = "Ofo",
	family = "sio",
}

m["ofs"] = {
	canonicalName = "Old Frisian",
	scripts = {"Latn"},
	family = "gmw-fri",
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["ofu"] = {
	canonicalName = "Efutop",
	family = "nic-bod",
}

m["ogb"] = {
	canonicalName = "Ogbia",
	family = "nic-bco",
}

m["ogc"] = {
	canonicalName = "Ogbah",
	family = "nic-bco",
}

m["oge"] = {
	canonicalName = "Old Georgian",
	scripts = {"Geor"},
	family = "ccs-gzn",
	translit_module = "Geor-translit",
	entry_name = {
		from = {"̂"},
		to   = {""}} ,
}

m["ogg"] = {
	canonicalName = "Ogbogolo",
	family = "nic-bco",
}

m["ogo"] = {
	canonicalName = "Khana",
	family = "nic-bco",
}

m["ogu"] = {
	canonicalName = "Ogbronuagum",
	family = "nic-bco",
}

m["oht"] = {
	canonicalName = "Old Hittite",
	scripts = {"Xsux"},
	family = "ine-ana",
}

m["ohu"] = {
	canonicalName = "Old Hungarian",
	scripts = {"Latn"},
	family = "fiu-ugr",
}

m["oia"] = {
	canonicalName = "Oirata",
	family = "ngf",
}

m["oin"] = {
	canonicalName = "Inebu One",
	family = "qfa-tor",
}

m["ojb"] = {
	canonicalName = "Northwestern Ojibwa",
	family = "alg",
}

m["ojc"] = {
	canonicalName = "Central Ojibwa",
	family = "alg",
}

m["ojg"] = {
	canonicalName = "Eastern Ojibwa",
	family = "alg",
}

m["ojp"] = {
	canonicalName = "Old Japanese",
	scripts = {"Jpan"},
	family = "jpx",
}

m["ojs"] = {
	canonicalName = "Severn Ojibwa",
	family = "alg",
}

m["ojv"] = {
	canonicalName = "Ontong Java",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["ojw"] = {
	canonicalName = "Western Ojibwa",
	family = "alg",
}

m["oka"] = {
	canonicalName = "Okanagan",
	otherNames = {"Okanagan Salish", "Okanagan-Colville", "Colville-Okanagan"},
	scripts = {"Latn"},
	family = "sal",
}

m["okb"] = {
	canonicalName = "Okobo",
	family = "nic-bco",
}

m["okd"] = {
	canonicalName = "Okodia",
	otherNames = {"Okordia", "Akita"},
	family = "ijo",
}

m["oke"] = {
	canonicalName = "Okpe (Southwestern Edo)",
	otherNames = {"Okpe", "Okpe (Nigeria)", "Southwestern Edo"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["okg"] = {
	canonicalName = "Kok-Paponk",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["okh"] = {
	canonicalName = "Koresh-e Rostam",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["oki"] = {
	canonicalName = "Okiek",
	family = "sdv",
}

m["okj"] = {
	canonicalName = "Oko-Juwoi",
	otherNames = {"Juwoi", "Juwai", "Junoi"},
	family = "qfa-adm",
}

m["okk"] = {
	canonicalName = "Kwamtim One",
	family = "qfa-tor",
}

m["okl"] = {
	canonicalName = "Old Kentish Sign Language",
	family = "sgn",
}

m["okm"] = {
	canonicalName = "Middle Korean",
	scripts = {"Kore"},
	family = "qfa-kor",
	ancestors = {"oko"},
}

m["okn"] = {
	canonicalName = "Oki-No-Erabu",
	otherNames = {"Okino-Erabu", "Okinoerabu"}, -- distinguish Okinawan
	family = "jpx-ryu",
}

m["oko"] = {
	canonicalName = "Old Korean",
	scripts = {"Hani"},
	family = "qfa-kor",
}

m["okr"] = {
	canonicalName = "Kirike",
	family = "ijo",
}

m["oks"] = {
	canonicalName = "Oko-Eni-Osayen",
	family = "nic-bco",
}

m["oku"] = {
	canonicalName = "Oku",
	family = "nic-grf",
}

m["okv"] = {
	canonicalName = "Orokaiva",
	family = "ngf",
}

m["okx"] = {
	canonicalName = "Okpe (Northwestern Edo)",
	otherNames = {"Okpe", "Okpe (Nigeria)"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["old"] = {
	canonicalName = "Mochi",
	family = "bnt",
}

m["ole"] = {
	canonicalName = "Olekha",
	family = "sit",
}

m["olm"] = {
	canonicalName = "Oloma",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["olo"] = {
	canonicalName = "Livvi",
	otherNames = {"Livvi-Karelian", "Livvikovian", "Olonets", "Southern Olonetsian"},
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["olr"] = {
	canonicalName = "Olrat",
	family = "poz-vnc",
}

m["olt"] = {
	canonicalName = "Old Lithuanian",
	scripts = {"Latn"},
	family = "bat",
	entry_name = {
		from = {"[áãà]", "[éẽè]", "[íĩì]", "[ýỹ]", "ñ", "[óõò]", "[úù]", ACUTE, GRAVE, TILDE},
		to   = {"a"    , "e"    , "i", "y"   , "n", "o"	   , "u"   }} ,
}

m["olu"] = {
	canonicalName = "Kuvale",
	family = "bnt",
}

m["oma"] = {
	canonicalName = "Omaha-Ponca",
	otherNames = {"Omaha", "Ponca"},
	scripts = {"Latn"},
	family = "sio",
}

m["omb"] = {
	canonicalName = "Omba",
	otherNames = {"East Ambae"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["omc"] = {
	canonicalName = "Mochica",
}

m["omg"] = {
	canonicalName = "Omagua",
	otherNames = {"Agua", "Cambeba", "Cambeeba", "Kambeba", "Cambela", "Campeba", "Compeva", "Umaua", "Omáua", "Omaua", "Omayali"}, -- last three might actually be names of a different language
	family = "tup",
}

m["omi"] = {
	canonicalName = "Omi",
	family = "csu",
}

m["omk"] = {
	canonicalName = "Omok",
	family = "qfa-yuk",
}

m["oml"] = {
	canonicalName = "Ombo",
	family = "bnt",
}

m["omn"] = {
	canonicalName = "Minoan",
	scripts = {"Lina"},
}

m["omo"] = {
	canonicalName = "Utarmbung",
	family = "ngf",
}

m["omp"] = {
	canonicalName = "Old Manipuri",
	family = "tbq",
}

m["omr"] = {
	canonicalName = "Old Marathi",
	scripts = {"Deva", "Modi"},
	family = "inc",
	ancestors = {"pmh"},
}

m["omt"] = {
	canonicalName = "Omotik",
	family = "sdv",
}

m["omu"] = {
	canonicalName = "Omurano",
}

m["omw"] = {
	canonicalName = "South Tairora",
	family = "paa-kag",
}

m["omx"] = {
	canonicalName = "Old Mon",
	family = "mkh",
}

m["ona"] = {
	canonicalName = "Selk'nam",
	otherNames = {"Ona", "Aona", "Selknam", "Shelknam"},
	scripts = {"Latn"},
}

m["onb"] = {
	canonicalName = "Lingao",
	family = "qfa-tak",
}

m["one"] = {
	canonicalName = "Oneida",
	scripts = {"Latn"},
	family = "iro",
}

m["ong"] = {
	canonicalName = "Olo",
	family = "qfa-tor",
}

m["oni"] = {
	canonicalName = "Onin",
	scripts = {"Latn"},
	family = "plf",
}

m["onj"] = {
	canonicalName = "Onjob",
	family = "ngf",
}

m["onk"] = {
	canonicalName = "Kabore One",
	family = "qfa-tor",
}

m["onn"] = {
	canonicalName = "Onobasulu",
	family = "ngf",
}

m["ono"] = {
	canonicalName = "Onondaga",
	scripts = {"Latn"},
	family = "iro",
}

m["onp"] = {
	canonicalName = "Sartang",
}

m["onr"] = {
	canonicalName = "Northern One",
	family = "qfa-tor",
}

m["ons"] = {
	canonicalName = "Ono",
	family = "ngf",
}

m["ont"] = {
	canonicalName = "Ontenu",
}

m["onu"] = {
	canonicalName = "Unua",
	family = "poz-vnc",
}

m["onw"] = {
	canonicalName = "Old Nubian",
	scripts = {"Copt"},
	family = "nub",
}

m["onx"] = {
	canonicalName = "Onin Based Pidgin",
}

m["ood"] = {
	canonicalName = "O'odham",
	otherNames = {"Papago"},
	scripts = {"Latn"},
	family = "azc",
}

m["oog"] = {
	canonicalName = "Ong",
	family = "mkh",
}

m["oon"] = {
	canonicalName = "Önge",
}

m["oor"] = {
	canonicalName = "Oorlams",
}

m["oos"] = {
	canonicalName = "Old Ossetic",
	otherNames = {"Old Ossetian"},
	family = "ira",
	ancestors = {"xln"},
}

m["opa"] = {
	canonicalName = "Okpamheri",
	otherNames = {"Opameri", "Ibilo"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["opk"] = {
	canonicalName = "Kopkaka",
	family = "ngf-okk",
}

m["opm"] = {
	canonicalName = "Oksapmin",
	family = "ngf",
}

m["opo"] = {
	canonicalName = "Opao",
	family = "ngf",
}

m["opt"] = {
	canonicalName = "Opata",
	otherNames = {"Heve", "Hegue", "Eudeve", "Teguima"},
	scripts = {"Latn"},
	family = "azc-trc",
}

m["opy"] = {
	canonicalName = "Ofayé",
	family = "sai-mje",
}

m["ora"] = {
	canonicalName = "Oroha",
	family = "poz-sls",
}

m["ore"] = {
	canonicalName = "Orejón",
	family = "sai-tuc",
}

m["org"] = {
	canonicalName = "Oring",
	family = "nic-bco",
}

m["orh"] = {
	canonicalName = "Oroqen",
	family = "tuw",
}

m["oro"] = {
	canonicalName = "Orokolo",
	family = "ngf",
}

m["orr"] = {
	canonicalName = "Oruma",
	family = "ijo",
}

m["ort"] = {
	canonicalName = "Adivasi Oriya",
	scripts = {"Orya"},
	family = "inc",
	ancestors = {"or"},
}

m["oru"] = {
	canonicalName = "Ormuri",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["orv"] = {
	canonicalName = "Old East Slavic",
	otherNames = {"Old Russian"},
	scripts = {"Cyrs"},
	family = "zle",
	translit_module = "Cyrs-Glag-translit",
	entry_name = {
		from = {u(0x0484)}, -- kamora
		to   = {}},
	sort_key = {
		from = {"оу", "є"},
		to   = {"у" , "е"}} ,
}

m["orw"] = {
	canonicalName = "Oro Win",
	family = "sai-cpc",
}

m["orx"] = {
	canonicalName = "Oro",
	family = "nic-bco",
}

m["orz"] = {
	canonicalName = "Ormu",
	family = "poz-ocw",
}

m["osa"] = {
	canonicalName = "Osage",
	scripts = {"Latn"},
	family = "sio",
}

m["osc"] = {
	canonicalName = "Oscan",
	scripts = {"Ital", "Latn"},
	family = "itc",
	translit_module = "Ital-translit",
}

m["osi"] = {
	canonicalName = "Osing",
	family = "poz-sus",
}

m["oso"] = {
	canonicalName = "Ososo",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["osp"] = {
	canonicalName = "Old Spanish",
	scripts = {"Latn"},
	family = "roa",
}

m["ost"] = {
	canonicalName = "Osatu",
	family = "nic-bod",
}

m["osu"] = {
	canonicalName = "Southern One",
	family = "qfa-tor",
}

m["osx"] = {
	canonicalName = "Old Saxon",
	otherNames = {"Old Low German"},
	scripts = {"Latn"},
	family = "gmw",
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["ota"] = {
	canonicalName = "Ottoman Turkish",
	otherNames = {"Ottoman"},
	scripts = {"ota-Arab", "Armn"},
	family = "trk-ogz",
    ancestors = {"trk-oat"},
}

m["otb"] = {
	canonicalName = "Old Tibetan",
	family = "tbq",
}

m["otd"] = {
	canonicalName = "Ot Danum",
	otherNames = {"Dohoi"},
	family = "poz-brw",
}

m["ote"] = {
	canonicalName = "Mezquital Otomi",
	family = "oto",
}

m["oti"] = {
	canonicalName = "Oti",
}

m["otk"] = {
	canonicalName = "Qədim türk dili",
	scripts = {"Orkh"},
	family = "trk",
}

m["otl"] = {
	canonicalName = "Tilapa Otomi",
	family = "oto",
}

m["otm"] = {
	canonicalName = "Eastern Highland Otomi",
	family = "oto",
}

m["otn"] = {
	canonicalName = "Tenango Otomi",
	family = "oto",
}

m["otq"] = {
	canonicalName = "Querétaro Otomi",
	family = "oto",
}

m["otr"] = {
	canonicalName = "Otoro",
}

m["ots"] = {
	canonicalName = "Estado de México Otomi",
	family = "oto",
}

m["ott"] = {
	canonicalName = "Temoaya Otomi",
	family = "oto",
}

m["otu"] = {
	canonicalName = "Otuke",
	family = "sai-mje",
}

m["otw"] = {
	canonicalName = "Ottawa",
	scripts = {"Latn"},
	family = "alg",
}

m["otx"] = {
	canonicalName = "Texcatepec Otomi",
	family = "oto",
}

m["oty"] = {
	canonicalName = "Old Tamil",
	scripts = {"Brah"},
	family = "dra",
}

m["otz"] = {
	canonicalName = "Ixtenco Otomi",
	family = "oto",
}

m["oua"] = {
	canonicalName = "Tagargrent",
	otherNames = {"Ouargli", "Wargli", "Teggargrent"},
	family = "ber",
}

m["oub"] = {
	canonicalName = "Glio-Oubi",
	family = "kro",
}

m["oue"] = {
	canonicalName = "Oune",
}

m["oui"] = {
	canonicalName = "Old Uighur",
	otherNames = {"Old Uyghur"},
	scripts = {"Brah", "Mani", "Syrc"},
	family = "trk",
}

m["oum"] = {
	canonicalName = "Ouma",
	family = "poz-ocw",
}

m["ovd"] = {
	canonicalName = "Elfdalian",
	otherNames = {"Övdalian"},
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"non"},
}

m["owi"] = {
	canonicalName = "Owiniga",
	family = "qfa-mal",
}

m["owl"] = {
	canonicalName = "Old Welsh",
	scripts = {"Latn"},
	family = "cel-bry",
}

m["oyb"] = {
	canonicalName = "Oy",
	otherNames = {"Oi", "The"}, -- The is a dialect of Oi. No, seriously.
	family = "aav-ban",
}

m["oyd"] = {
	canonicalName = "Oyda",
}

m["oym"] = {
	canonicalName = "Wayampi",
	otherNames = {"Guayapi", "Oiampi", "Oiampí"},
	scripts = {"Latn"},
	family = "omv",
}

m["oyy"] = {
	canonicalName = "Oya'oya",
	family = "poz-ocw",
}

m["ozm"] = {
	canonicalName = "Koonzime",
	family = "bnt",
}

return m