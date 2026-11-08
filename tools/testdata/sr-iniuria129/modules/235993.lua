local u = mw.ustring.char

-- UTF-8 encoded strings for some commonly used diacritics
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

local Latn = {"Latn"}

local m = {}

m["oaa"] = {
	"Orok",
	"Q33928",
	"tuw",
	scripts = Latn,
}

m["oac"] = {
	"Oroch",
	"Q33650",
	"tuw",
	scripts = {"Latn", "Cyrl"},
}

m["oav"] = {
	"Old Avar",
	nil,
	"cau-ava",
	scripts = {"Geor"},
}

m["obi"] = {
	"Obispeño",
	"Q1288385",
	"nai-chu",
	scripts = Latn,
}

m["obk"] = {
	"Southern Bontoc",
	nil,
	"phi",
	otherNames = {"Southern Bontok"},
	scripts = Latn,
}

m["obl"] = {
	"Oblo",
	"Q36309",
}

m["obm"] = {
	"Моавски",
	"Q36385",
	"sem-can",
	scripts = {"Phnx"},
	translit_module = "Phnx-translit",
}

m["obo"] = {
	"Obo Manobo",
	"Q12953699",
	"mno",
	otherNames = {"Obo"},
	scripts = Latn,
}

m["obr"] = {
	"Old Burmese",
	"Q17006600",
	"tbq-brm",
	scripts = {"Mymr"},
}

m["obt"] = {
	"Old Breton",
	"Q3558112",
	"cel-bry",
	scripts = Latn,
}

m["obu"] = {
	"Obulom",
	"Q3813403",
	"nic-cde",
	scripts = Latn,
}

m["oca"] = {
	"Ocaina",
	"Q3182577",
	"sai-wit",
	scripts = Latn,
}

m["och"] = {
	"Old Chinese",
	"Q35137",
	"zhx",
	scripts = {"Hani"},
}

m["oco"] = {
	"Old Cornish",
	"Q48304520",
	"cel-bry",
	scripts = Latn,
}

m["ocu"] = {
	"Tlahuica",
	"Q10751739",
	"omq",
	otherNames = {"Ocuiltec", "Atzingo Matlatzinca"},
	scripts = Latn,
}

m["oda"] = {
	"Odut",
	"Q3915388",
	"nic-uce",
	ancestors = {"mfn"},
	scripts = Latn,
}

m["odk"] = {
	"Od",
	"Q7077191",
	"inc",
	scripts = {"Arab"},
}

m["odt"] = {
	"Стари Холандски",
	"Q443089",
	"gmw",
	scripts = Latn,
	ancestors = {"frk"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["odu"] = {
	"Odual",
	"Q3813392",
	"nic-cde",
	scripts = Latn,
}

m["ofo"] = {
	"Ofo",
	"Q3349758",
	"sio-ohv",
}

m["ofs"] = {
	"Old Frisian",
	"Q35133",
	"gmw-fri",
	scripts = Latn,
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["ofu"] = {
	"Efutop",
	"Q35297",
	"nic-eko",
	scripts = Latn,
}

m["ogb"] = {
	"Ogbia",
	"Q3813400",
	"nic-cde",
	scripts = Latn,
}

m["ogc"] = {
	"Ogbah",
	"Q36291",
	"alv-igb",
	scripts = Latn,
}

m["oge"] = {
	"Стари Грузијски",
	"Q34834",
	"ccs-gzn",
	scripts = {"Geor"},
	translit_module = "Geor-translit",
	override_translit = true,
	entry_name = {
		from = {"̂"},
		to   = {""}} ,
}

m["ogg"] = {
	"Ogbogolo",
	"Q3813405",
	"nic-cde",
	scripts = Latn,
}

m["ogo"] = {
	"Khana",
	"Q3914409",
	"nic-ogo",
	scripts = Latn,
}

m["ogu"] = {
	"Ogbronuagum",
	"Q3914485",
	"nic-cde",
	scripts = Latn,
}

m["ohu"] = {
	"Old Hungarian",
	nil,
	"urj-ugr",
	scripts = Latn,
}

m["oia"] = {
	"Oirata",
	"Q56738",
	"ngf",
	scripts = Latn,
}

m["oin"] = {
	"Inebu One",
	"Q12953782",
	"qfa-tor",
}

m["ojb"] = {
	"Northwestern Ojibwa",
	"Q7060356",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojc"] = {
	"Central Ojibwa",
	"Q5061548",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojg"] = {
	"Eastern Ojibwa",
	"Q5330342",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojp"] = {
	"Стари Јапански",
	"Q5736700",
	"jpx",
	scripts = {"Jpan"},
}

m["ojs"] = {
	"Severn Ojibwa",
	"Q56494",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojv"] = {
	"Ontong Java",
	"Q7095071",
	"poz-pnp",
	scripts = Latn,
}

m["ojw"] = {
	"Western Ojibwa",
	"Q3474222",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["oka"] = {
	"Okanagan",
	"Q2984602",
	"sal",
	otherNames = {"Okanagan Salish", "Okanagan-Colville", "Colville-Okanagan"},
	scripts = Latn,
}

m["okb"] = {
	"Okobo",
	"Q3813398",
	"nic-lcr",
	scripts = Latn,
}

m["okd"] = {
	"Okodia",
	"Q36300",
	"ijo",
	otherNames = {"Okordia", "Akita"},
}

m["oke"] = {
	"Okpe (Southwestern Edo)",
	"Q268924",
	"alv-swd",
	otherNames = {"Okpe", "Okpe (Nigeria)", "Southwestern Edo"},
	scripts = Latn,
}

m["okg"] = {
	"Kok-Paponk",
	nil,
	"aus-pmn",
	scripts = Latn,
}

m["okh"] = {
	"Koresh-e Rostam",
	"Q6432160",
	"xme-ttc",
	ancestors = {"xme-ttc-cen"},
}

m["oki"] = {
	"Okiek",
	"Q56367",
	"sdv",
	otherNames = {"Ogiek", "Akiek", "Akie", "Aki", "Mosiro", "Mediak", "Kisankasa"},
	scripts = Latn,
}

m["okj"] = {
	"Oko-Juwoi",
	"Q3436832",
	"qfa-adc",
	otherNames = {"Juwoi", "Juwai", "Junoi"},
}

m["okk"] = {
	"Kwamtim One",
	"Q19830649",
	"qfa-tor",
	scripts = Latn,
}

m["okl"] = {
	"Old Kentish Sign Language",
	"Q7084319",
	"sgn",
}

m["okm"] = {
	"Middle Korean",
	"Q715339",
	"qfa-kor",
	scripts = {"Kore"},
	ancestors = {"oko"},
	entry_name = {
		from = {"[〮〯]"},
		to   = {""}},
}

m["okn"] = {
	"Oki-No-Erabu",
	"Q3350036",
	"jpx-ryu",
	scripts = {"Jpan"},
	otherNames = {"Okino-Erabu", "Okinoerabu"}, -- distinguish Okinawan
}

m["oko"] = {
	"Old Korean",
	"Q715364",
	"qfa-kor",
	scripts = {"Hani"},
}

m["okr"] = {
	"Kirike",
	"Q11006763",
	"ijo",
}

m["oks"] = {
	"Oko-Eni-Osayen",
	"Q36302",
	"alv-von",
	scripts = Latn,
}

m["oku"] = {
	"Oku",
	"Q36289",
	"nic-rnc",
	scripts = Latn,
}

m["okv"] = {
	"Orokaiva",
	"Q7103752",
	"ngf",
	scripts = Latn,
}

m["okx"] = {
	"Okpe (Northwestern Edo)",
	"Q7082547",
	"alv-nwd",
	otherNames = {"Okpe", "Okpe (Nigeria)"},
	scripts = Latn,
}

m["old"] = {
	"Mochi",
	"Q12952852",
	"bnt-chg",
	scripts = Latn,
}

m["ole"] = {
	"Olekha",
	"Q3695204",
	"sit-bdi",
}

m["olm"] = {
	"Oloma",
	"Q3441166",
	"alv-nwd",
	scripts = Latn,
}

m["olo"] = {
	"Livvi",
	"Q36584",
	"fiu-fin",
	otherNames = {"Livvi-Karelian", "Livvikovian", "Olonets", "Southern Olonetsian"},
	scripts = Latn,
}

m["olr"] = {
	"Olrat",
	"Q3351562",
	"poz-vnc",
}

m["olt"] = {
	"Old Lithuanian",
	"Q17417801",
	"bat",
	scripts = Latn,
	entry_name = {
		from = {"[áãà]", "[éẽè]", "[íĩì]", "[ýỹ]", "ñ", "[óõò]", "[úù]", ACUTE, GRAVE, TILDE},
		to   = {"a"    , "e"    , "i", "y"   , "n", "o"	   , "u"   }} ,
}

m["olu"] = {
	"Kuvale",
	"Q6448765",
	"bnt-swb",
	scripts = Latn,
}

m["oma"] = {
	"Omaha-Ponca",
	"Q2917968",
	"sio-dhe",
	otherNames = {"Omaha", "Ponca"},
	scripts = Latn,
}

m["omb"] = {
	"Omba",
	"Q2841471",
	"poz-vnc",
	otherNames = {"East Ambae"},
	scripts = Latn,
}

m["omc"] = {
	"Mochica",
	"Q1951641",
}

m["omg"] = {
	"Omagua",
	"Q33663",
	"tup-gua",
	otherNames = {"Agua", "Cambeba", "Cambeeba", "Kambeba", "Cambela", "Campeba", "Compeva", "Umaua", "Omáua", "Omaua", "Omayali"}, -- last three might actually be names of a different language
	scripts = Latn,
}

m["omi"] = {
	"Omi",
	"Q56795",
	"csu",
}

m["omk"] = {
	"Omok",
	"Q4334657",
	"qfa-yuk",
}

m["oml"] = {
	"Ombo",
	"Q7089928",
	"bnt-tet",
	scripts = Latn,
}

m["omn"] = {
	"Minoan",
	"Q1669994",
	scripts = {"Lina"},
}

m["omo"] = {
	"Utarmbung",
	"Q7902577",
	"ngf",
	scripts = Latn,
}

m["omp"] = {
	"Old Manipuri",
	nil,
	"sit",
}

m["omr"] = {
	"Old Marathi",
	nil,
	"inc",
	scripts = {"Deva", "Modi"},
	ancestors = {"pmh"},
	translit_module = "translit-redirect",
}

m["omt"] = {
	"Omotik",
	"Q36313",
	"sdv",
}

m["omu"] = {
	"Omurano",
	"Q1957612",
}

m["omw"] = {
	"South Tairora",
	"Q20210553",
	"paa-kag",
	scripts = Latn,
}

m["omx"] = {
	"Old Mon",
	nil,
	"mkh",
}

m["ona"] = {
	"Selk'nam",
	"Q2721227",
	otherNames = {"Ona", "Aona", "Selknam", "Shelknam"},
	scripts = Latn,
}

m["onb"] = {
	"Lingao",
	"Q7093790",
	"qfa-tak",
}

m["one"] = {
	"Oneida",
	"Q857858",
	"iro",
	scripts = Latn,
}

m["ong"] = {
	"Olo",
	"Q592162",
	"qfa-tor",
	scripts = Latn,
}

m["oni"] = {
	"Onin",
	"Q7093910",
	"poz-cet",
	scripts = Latn,
}

m["onj"] = {
	"Onjob",
	"Q7093968",
	"ngf",
	scripts = Latn,
}

m["onk"] = {
	"Kabore One",
	"Q12953783",
	"qfa-tor",
	scripts = Latn,
}

m["onn"] = {
	"Onobasulu",
	"Q7094437",
	"ngf",
	scripts = Latn,
}

m["ono"] = {
	"Onondaga",
	"Q1077450",
	"iro",
	scripts = Latn,
}

m["onp"] = {
	"Sartang",
	"Q7424639",
	"sit-khb",
}

m["onr"] = {
	"Northern One",
	"Q19830648",
	"qfa-tor",
	scripts = Latn,
}

m["ons"] = {
	"Ono",
	"Q11732548",
	"ngf",
	scripts = Latn,
}

m["ont"] = {
	"Ontenu",
	"Q3352827",
}

m["onu"] = {
	"Unua",
	"Q3552042",
	"poz-vnc",
	otherNames = {"Onua"},
	scripts = Latn,
}

m["onw"] = {
	"Old Nubian",
	"Q2268",
	"nub",
	scripts = {"Copt"},
}

m["onx"] = {
	"Pidgin Onin",
	"Q12953788",
	"crp",
	scripts = Latn,
	ancestors = {"oni"},
}

m["ood"] = {
	"O'odham",
	"Q2393095",
	"azc",
	otherNames = {"Papago"},
	scripts = Latn,
}

m["oog"] = {
	"Ong",
	"Q12953787",
	"mkh-kat",
}

m["oon"] = {
	"Önge",
	"Q2475551",
	"qfa-ong",
}

m["oor"] = {
	"Oorlams",
	"Q2484337",
}

m["oos"] = {
	"Old Ossetic",
	nil,
	"xsc",
	otherNames = {"Old Ossetian", "Alanic", "Sarmatian"},
	scripts = {"Grek", "Latn"},
	translit_module = "grc-translit",
	ancestors = {"os-pro"},
}

m["opa"] = {
	"Okpamheri",
	"Q3913331",
	"alv-nwd",
	otherNames = {"Opameri", "Ibilo"},
	scripts = Latn,
}

m["opk"] = {
	"Kopkaka",
	"Q6431129",
	"ngf-okk",
	scripts = Latn,
}

m["opm"] = {
	"Oksapmin",
	"Q1068097",
	"ngf",
	scripts = Latn,
}

m["opo"] = {
	"Opao",
	"Q7095585",
	"ngf",
	scripts = Latn,
}

m["opt"] = {
	"Opata",
	"Q2304583",
	"azc-trc",
	otherNames = {"Heve", "Hegue", "Eudeve", "Teguima"},
	scripts = Latn,
}

m["opy"] = {
	"Ofayé",
	"Q3446691",
	"sai-mje",
	scripts = Latn,
}

m["ora"] = {
	"Oroha",
	"Q36298",
	"poz-sls",
}

m["ore"] = {
	"Orejón",
	"Q3355834",
	"sai-tuc",
	scripts = Latn,
}

m["org"] = {
	"Oring",
	"Q3915308",
	"nic-ucn",
	scripts = Latn,
}

m["orh"] = {
	"Oroqen",
	"Q1367309",
	"tuw",
	scripts = Latn,
}

m["oro"] = {
	"Orokolo",
	"Q7103758",
	"ngf",
	scripts = Latn,
}

m["orr"] = {
	"Oruma",
	"Q36299",
	"ijo",
	scripts = Latn,
}

m["ort"] = {
	"Adivasi Oriya",
	"Q12953791",
	"inc",
	scripts = {"Orya"},
	ancestors = {"or"},
}

m["oru"] = {
	"Ormuri",
	"Q33740",
	"ira-orp",
	scripts = {"fa-Arab"},
}

m["orv"] = {
	"Old East Slavic",
	"Q35228",
	"zle",
	otherNames = {"Old Russian"},
	scripts = {"Cyrs"},
	translit_module = "Cyrs-Glag-translit",
	entry_name = {
		from = {u(0x0484)}, -- kamora
		to   = {}},
	sort_key = {
		from = {"оу", "є"},
		to   = {"у" , "е"}} ,
}

m["orw"] = {
	"Oro Win",
	"Q3450423",
	"sai-cpc",
	scripts = Latn,
}

m["orx"] = {
	"Oro",
	"Q3813396",
	"nic-lcr",
	scripts = Latn,
}

m["orz"] = {
	"Ormu",
	"Q7103494",
	"poz-ocw",
	scripts = Latn,
}

m["osa"] = {
	"Osage",
	"Q2600085",
	"sio-dhe",
	scripts = {"Latn", "Osge"},
}

m["osc"] = {
	"Oscan",
	"Q36653",
	"itc",
	scripts = {"Ital", "Latn"},
	translit_module = "Ital-translit",
}

m["osi"] = {
	"Osing",
	"Q2701322",
	"poz-sus",
	scripts = Latn,
}

m["oso"] = {
	"Ososo",
	"Q3913398",
	"alv-yek",
	scripts = Latn,
}

m["osp"] = {
	"Old Spanish",
	"Q1088025",
	"roa-ibe",
	scripts = Latn,
}

m["ost"] = {
	"Osatu",
	"Q36243",
	"nic-grs",
	scripts = Latn,
}

m["osu"] = {
	"Southern One",
	"Q12953785",
	"qfa-tor",
	scripts = Latn,
}

m["osx"] = {
	"Old Saxon",
	"Q35219",
	"gmw",
	otherNames = {"Old Low German"},
	scripts = Latn,
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["ota"] = {
	"Ottoman Turkish",
	"Q36730",
	"trk-ogz",
	otherNames = {"Ottoman"},
	scripts = {"ota-Arab", "Armn"},
	ancestors = {"trk-oat"},
}

m["otd"] = {
	"Ot Danum",
	"Q3033781",
	"poz-brw",
	otherNames = {"Dohoi"},
	scripts = Latn,
}

m["ote"] = {
	"Mezquital Otomi",
	"Q23755711",
	"oto-otm",
	scripts = Latn,
}

m["oti"] = {
	"Oti",
	"Q3357881",
}

m["otk"] = {
	"Old Turkic",
	"Q34988",
	"trk",
	otherNames = {"Orkhon Turkic", "Orkhon"},
	scripts = {"Orkh"},
	translit_module = "Orkh-translit",
}

m["otl"] = {
	"Tilapa Otomi",
	"Q7802050",
	"oto-otm",
	scripts = Latn,
}

m["otm"] = {
	"Eastern Highland Otomi",
	"Q13581718",
	"oto-otm",
	scripts = Latn,
}

m["otn"] = {
	"Tenango Otomi",
	"Q25559589",
	"oto-otm",
	scripts = Latn,
}

m["otq"] = {
	"Querétaro Otomi",
	"Q23755688",
	"oto-otm",
	scripts = Latn,
}

m["otr"] = {
	"Otoro",
	"Q36328",
	"alv-hei",
}

m["ots"] = {
	"Estado de México Otomi",
	"Q7413841",
	"oto-otm",
	scripts = Latn,
}

m["ott"] = {
	"Temoaya Otomi",
	"Q7698191",
	"oto-otm",
	scripts = Latn,
}

m["otu"] = {
	"Otuke",
	"Q7110049",
	"sai-mje",
	scripts = Latn,
}

m["otw"] = {
	"Ottawa",
	"Q133678",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["otx"] = {
	"Texcatepec Otomi",
	"Q25559590",
	"oto-otm",
	scripts = Latn,
}

m["oty"] = {
	"Old Tamil",
	"Q20987452",
	"dra",
	scripts = {"Brah"},
}

m["otz"] = {
	"Ixtenco Otomi",
	"Q6101171",
	"oto-otm",
	scripts = Latn,
}

m["oua"] = {
	"Tagargrent",
	"Q56586",
	"ber",
	otherNames = {"Ouargli", "Wargli", "Teggargrent"},
}

m["oub"] = {
	"Glio-Oubi",
	"Q3914977",
	"kro-grb",
}

m["oue"] = {
	"Oune",
	"Q7110521",
	"paa-sbo",
}

m["oui"] = {
	"Old Uyghur",
	nil,
	"trk-sib",
	otherNames = {"Old Uighur"},
	scripts = {"Latn", "Brah", "Mani", "Syrc"},
}

m["oum"] = {
	"Ouma",
	"Q7110494",
	"poz-ocw",
	scripts = Latn,
}

m["ovd"] = {
	"Elfdalian",
	"Q254950",
	"gmq",
	otherNames = {"Övdalian"},
	scripts = Latn,
	ancestors = {"non"},
}

m["owi"] = {
	"Owiniga",
	"Q56454",
	"qfa-mal",
	scripts = Latn,
}

m["owl"] = {
	"Old Welsh",
	"Q2266723",
	"cel-bry",
	scripts = Latn,
}

m["oyb"] = {
	"Oy",
	"Q13593748",
	"mkh-ban",
	otherNames = {"Oi", "The"}, -- The is a dialect of Oi. No, seriously.
}

m["oyd"] = {
	"Oyda",
	"Q7116251",
	"omv-nom",
}

m["oym"] = {
	"Wayampi",
	"Q7975842",
	"tup-gua",
	otherNames = {"Guayapi", "Oiampi", "Oiampí"},
	scripts = Latn,
}

m["oyy"] = {
	"Oya'oya",
	"Q7116243",
	"poz-ocw",
	scripts = Latn,
}

m["ozm"] = {
	"Koonzime",
	"Q35566",
	"bnt-ndb",
	scripts = Latn,
}

return m