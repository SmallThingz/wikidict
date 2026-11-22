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

m["raa"] = {
	canonicalName = "Dungmali",
	family = "tbq",
}

m["rab"] = {
	canonicalName = "Camling",
}

m["rac"] = {
	canonicalName = "Rasawa",
}

m["rad"] = {
	canonicalName = "Rade",
	scripts = {"Latn"},
	family = "poz-msa",
}

m["raf"] = {
	canonicalName = "Western Meohang",
}

m["rag"] = {
	canonicalName = "Logooli",
}

m["rah"] = {
	canonicalName = "Rabha",
	family = "sit",
}

m["rai"] = {
	canonicalName = "Ramoaaina",
	otherNames = {"Ramoaina", "Ramuaaina", "Ramuaina", "Duke of York"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["raj"] = {
	canonicalName = "Rajasthani",
	scripts = {"Deva"},
	family = "inc",
}

m["rak"] = {
	canonicalName = "Tulu-Bohuai",
	family = "poz-aay",
}

m["ral"] = {
	canonicalName = "Ralte",
	family = "tbq-kuk",
}

m["ram"] = {
	canonicalName = "Canela",
}

m["ran"] = {
	canonicalName = "Riantana",
}

m["rao"] = {
	canonicalName = "Rao",
	family = "paa",
}

m["rap"] = {
	canonicalName = "Rapa Nui",
	otherNames = {"Rapanui", "Pascuense"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["raq"] = {
	canonicalName = "Saam",
}

m["rar"] = {
	canonicalName = "Rarotongan",
	otherNames = {"Cook Islands Maori", "Cook Islands Māori"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["ras"] = {
	canonicalName = "Tegali",
	otherNames = {"Tingal", "Tagale", "Tegele", "Tekele", "Togole", "Rashad", "Gom", "Kom"},
}

m["rat"] = {
	canonicalName = "Razajerdi",
	ancestors = {"ira-azr"},
}

m["rau"] = {
	canonicalName = "Raute",
}

m["rav"] = {
	canonicalName = "Sampang",
}

m["raw"] = {
	canonicalName = "Rawang",
	family = "sit",
}

m["rax"] = {
	canonicalName = "Rang",
}

m["ray"] = {
	canonicalName = "Rapa",
	family = "poz-pol",
}

m["raz"] = {
	canonicalName = "Rahambuu",
}

m["rbb"] = {
	canonicalName = "Rumai Palaung",
	family = "aav",
}

m["rbk"] = {
	canonicalName = "Northern Bontoc",
	otherNames = {"Northern Bontok"},
}

m["rbl"] = {
	canonicalName = "Miraya Bikol",
}

m["rcf"] = {
	canonicalName = "Réunion Creole French",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"fr"},
}

m["rdb"] = {
	canonicalName = "Rudbari",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["rea"] = {
	canonicalName = "Rerau",
}

m["reb"] = {
	canonicalName = "Rembong",
}

m["ree"] = {
	canonicalName = "Rejang Kayan",
	otherNames = {"Lisum", "Ma'aging", "Long Badan", "Uma Daro", "Long Kehobo", "Uma Poh", "Uma Juman", "Long Murun", "Long Geng", "Lemena"},
	family = "poz",
}

m["reg"] = {
	canonicalName = "Kara (Tanzania)",
}

m["rei"] = {
	canonicalName = "Reli",
}

m["rej"] = {
	canonicalName = "Rejang",
	scripts = {"Rjng"},
	family = "poz-sus",
}

m["rel"] = {
	canonicalName = "Rendille",
	family = "cus",
}

m["rem"] = {
	canonicalName = "Remo",
	family = "sai-pan",
}

m["ren"] = {
	canonicalName = "Rengao",
	family = "mkh",
}

m["rer"] = {
	canonicalName = "Rer Bare",
}

m["res"] = {
	canonicalName = "Reshe",
}

m["ret"] = {
	canonicalName = "Retta",
	otherNames = {"Reta"},
}

m["rey"] = {
	canonicalName = "Reyesano",
	family = "sai-tac",
}

m["rga"] = {
	canonicalName = "Roria",
	family = "poz-vnc",
}

m["rge"] = {
	canonicalName = "Romani Greek",
	otherNames = {"Romano-Greek", "Hellenoromani"},
}

m["rgk"] = {
	canonicalName = "Rangkas",
	family = "tbq",
}

m["rgn"] = {
	canonicalName = "Romagnol",
	otherNames = {"Romagnolo"},
	scripts = {"Latn"},
	family = "roa",
	wikimedia_codes = {"eml"},
}

m["rgr"] = {
	canonicalName = "Resígaro",
	family = "awd",
}

m["rgs"] = {
	canonicalName = "Southern Roglai",
}

m["rgu"] = {
	canonicalName = "Ringgou",
	family = "plf",
}

m["rhg"] = {
	canonicalName = "Rohingya",
	scripts = {"Latn"},
	family = "inc",
	ancestors = {"pka"},
}

m["rhp"] = {
	canonicalName = "Yahang",
	family = "qfa-tor",
}

m["ria"] = {
	canonicalName = "Reang",
	otherNames = {"Riang"},
	family = "tbq",
}

m["rie"] = {
	canonicalName = "Rien",
}

m["rif"] = {
	canonicalName = "Tarifit",
	otherNames = {"Rifain"},
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
}

m["ril"] = {
	canonicalName = "Riang",
	family = "aav",
}

m["rim"] = {
	canonicalName = "Nyaturu",
}

m["rin"] = {
	canonicalName = "Nungu",
}

m["rir"] = {
	canonicalName = "Ribun",
}

m["rit"] = {
	canonicalName = "Ritarungo",
	otherNames = {"Ritharrŋu", "Ritharngu"},
	scripts = {"Latn"},
	family = "aus-yol",
}

m["riu"] = {
	canonicalName = "Riung",
}

m["rjg"] = {
	canonicalName = "Rajong",
}

m["rji"] = {
	canonicalName = "Raji",
}

m["rjs"] = {
	canonicalName = "Rajbanshi",
	family = "inc",
	ancestors = {"pka"},
}

m["rka"] = {
	canonicalName = "Kraol",
}

m["rkb"] = {
	canonicalName = "Rikbaktsa",
	otherNames = {"Erikbatsa", "Aripaktsa", "Erikpatsa"},
	scripts = {"Latn"},
	family = "sai-mje",
}

m["rkh"] = {
	canonicalName = "Rakahanga-Manihiki",
	family = "poz-pol",
}

m["rki"] = {
	canonicalName = "Rakhine",
	otherNames = {"Arakanese", "Ramree", "Yangbye", "Thandwe", "Chaungtha"},
	ancestors = {"obr"},
	family = "tbq-brm",
}

m["rkm"] = {
	canonicalName = "Marka",
}

m["rkt"] = {
	canonicalName = "Kamta",
	otherNames = {"Rangpuri"},
	family = "inc",
	ancestors = {"pka"},
}

m["rkw"] = {
	canonicalName = "Arakwal",
}

m["rma"] = {
	canonicalName = "Rama",
}

m["rmb"] = {
	canonicalName = "Rembarunga",
	family = "aus-gun",
}

m["rmc"] = {
	canonicalName = "Carpathian Romani",
	family = "inc-rom",
}

m["rmd"] = {
	canonicalName = "Traveller Danish",
	family = "inc-rom",
}

m["rme"] = {
	canonicalName = "Angloromani",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en", "rom"},
}

m["rmf"] = {
	canonicalName = "Kalo Finnish Romani",
	family = "inc-rom",
}

m["rmg"] = {
	canonicalName = "Traveller Norwegian",
	family = "inc-rom",
}

m["rmh"] = {
	canonicalName = "Murkim",
}

m["rmi"] = {
	canonicalName = "Lomavren",
	family = "qfa-mix",
	ancestors = {"psu", "hy"},
}

m["rmk"] = {
	canonicalName = "Romkun",
	family = "paa",
}

m["rml"] = {
	canonicalName = "Baltic Romani",
	family = "inc-rom",
}

m["rmm"] = {
	canonicalName = "Roma",
}

m["rmn"] = {
	canonicalName = "Balkan Romani",
	family = "inc-rom",
}

m["rmo"] = {
	canonicalName = "Sinte Romani",
	otherNames = {"Sinti Romani", "Sinti-Manouche", "Sinti"},
	scripts = {"Latn"},
	family = "qfa-mix",
	ancestors = {"rom"},
}

m["rmp"] = {
	canonicalName = "Rempi",
}

m["rmq"] = {
	canonicalName = "Caló",
	scripts = {"Latn"},
	family = "qfa-mix",
	ancestors = {"rom", "la"},
}

m["rms"] = {
	canonicalName = "Romanian Sign Language",
	family = "sgn",
}

m["rmt"] = {
	canonicalName = "Domari",
	family = "inc",
	ancestors = {"psu"},
}

m["rmu"] = {
	canonicalName = "Tavringer Romani",
	family = "inc-rom",
}

m["rmv"] = {
	canonicalName = "Romanova",
	type = "appendix-constructed",
	family = "art",
}

m["rmw"] = {
	canonicalName = "Welsh Romani",
	otherNames = {"Welsh Romany", "Kååle"},
	family = "inc-rom",
}

m["rmx"] = {
	canonicalName = "Romam",
	family = "mkh",
}

m["rmy"] = {
	canonicalName = "Vlax Romani",
	family = "inc-rom",
}

m["rmz"] = {
	canonicalName = "Marma",
	ancestors = {"obr"},
	family = "tbq-brm",
}

m["rnd"] = {
	canonicalName = "Ruund",
}

m["rng"] = {
	canonicalName = "Ronga",
	otherNames = {"Xironga"},
	scripts = {"Latn"},
	family = "bnt"
}

m["rnl"] = {
	canonicalName = "Ranglong",
}

m["rnn"] = {
	canonicalName = "Roon",
	family = "poz-hce",
}

m["rnp"] = {
	canonicalName = "Rongpo",
}

m["rnw"] = {
	canonicalName = "Rungwa",
}

m["rob"] = {
	canonicalName = "Tae'",
	scripts = {"Latn"},
	family = "poz-ssw",
}

m["roc"] = {
	canonicalName = "Cacgia Roglai",
}

m["rod"] = {
	canonicalName = "Rogo",
}

m["roe"] = {
	canonicalName = "Ronji",
}

m["rof"] = {
	canonicalName = "Rombo",
	scripts = {"Latn"},
	family = "bnt",
}

m["rog"] = {
	canonicalName = "Northern Roglai",
	scripts = {"Latn"},
	family = "cmc",
}

m["rol"] = {
	canonicalName = "Romblomanon",
}

m["rom"] = {
	canonicalName = "Romani",
	otherNames = {"Gypsy"},
	scripts = {"Latn", "Cyrl"},
	family = "inc-rom",
	ancestors = {"psu"},
}

m["roo"] = {
	canonicalName = "Rotokas",
	scripts = {"Latn"},
	family = "paa",
}

m["rop"] = {
	canonicalName = "Kriol",
	otherNames = {"Australian Kriol"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["ror"] = {
	canonicalName = "Rongga",
}

m["rou"] = {
	canonicalName = "Runga",
}

m["row"] = {
	canonicalName = "Dela-Oenale",
	family = "plf",
}

m["rpn"] = {
	canonicalName = "Repanbitip",
	family = "poz-vnc",
}

m["rpt"] = {
	canonicalName = "Rapting",
}

m["rri"] = {
	canonicalName = "Ririo",
	family = "poz-ocw",
}

m["rro"] = {
	canonicalName = "Roro",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["rrt"] = {
	canonicalName = "Arritinngithigh",
	scripts = {"Latn"},
}

m["rsb"] = {
	canonicalName = "Romano-Serbian",
}

m["rsi"] = {
	canonicalName = "Rennellese Sign Language",
	family = "sgn",
}

m["rsl"] = {
	canonicalName = "Russian Sign Language",
	family = "sgn",
}

m["rsm"] = {
	canonicalName = "Miriwoong Sign Language",
	family = "sgn",
}

m["rtc"] = {
	canonicalName = "Rungtu",
	otherNames = {"Rungtu Chin", "Thaungtha"},
	family = "tbq-kuk",
}

m["rth"] = {
	canonicalName = "Ratahan",
	scripts = {"Latn"},
	family = "phi",
}

m["rtm"] = {
	canonicalName = "Rotuman",
	scripts = {"Latn"},
	family = "poz-occ",
}

m["rtw"] = {
	canonicalName = "Rathawi",
}

m["rub"] = {
	canonicalName = "Gungu",
}

m["ruc"] = {
	canonicalName = "Ruuli",
}

m["rue"] = {
	canonicalName = "Rusyn",
	scripts = {"Cyrl"},
	family = "zle",
	translit_module = "rue-translit",
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["ruf"] = {
	canonicalName = "Luguru",
}

m["rug"] = {
	canonicalName = "Roviana",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["ruh"] = {
	canonicalName = "Ruga",
}

m["rui"] = {
	canonicalName = "Rufiji",
}

m["ruk"] = {
	canonicalName = "Che",
}

m["ruo"] = {
	canonicalName = "Istro-Romanian",
	scripts = {"Latn"},
	family = "roa",
}

m["rup"] = {
	canonicalName = "Aromanian",
	scripts = {"Latn"},
	family = "roa",
	wikimedia_codes = {"roa-rup"},
}

m["ruq"] = {
	canonicalName = "Megleno-Romanian",
	scripts = {"Latn"},
	family = "roa",
}

m["rut"] = {
	canonicalName = "Rutul",
	scripts = {"Cyrl"},
	family = "cau-lzg",
}

m["ruu"] = {
	canonicalName = "Lanas Lobu",
}

m["ruy"] = {
	canonicalName = "Mala (Nigeria)",
	otherNames = {"Mala"},
	family = "nic-bco",
}

m["ruz"] = {
	canonicalName = "Ruma",
}

m["rwa"] = {
	canonicalName = "Rawo",
}

m["rwk"] = {
	canonicalName = "Rwa",
}

m["rwm"] = {
	canonicalName = "Amba",
	scripts = {"Latn"},
	family = "bnt",
}

m["rwo"] = {
	canonicalName = "Rawa",
	family = "ngf-fin",
}

m["rxd"] = {
	canonicalName = "Ngardi",
}

m["rxw"] = {
	canonicalName = "Karuwali",
}

m["ryn"] = {
	canonicalName = "Northern Amami-Oshima",
	family = "jpx-ryu",
}

m["rys"] = {
	canonicalName = "Yaeyama",
	scripts = {"Kana"},
	family = "jpx-ryu",
}

m["ryu"] = {
	canonicalName = "Okinawan",
	scripts = {"Jpan"},
	family = "jpx-ryu",
}

m["rzh"] = {
	canonicalName = "Razihi",
	otherNames = {"Rāziḥī", "Jabal Razih"},
	scripts = {"Arab"},
	family = "sem-osa",
	ancestors = {"sem-srb"},
}

return m