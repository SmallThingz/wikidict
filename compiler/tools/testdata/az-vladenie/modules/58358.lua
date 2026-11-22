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

m["pab"] = {
	canonicalName = "Pareci",
	otherNames = {"Parecis", "Parecís", "Paresi", "Paresí"},
	scripts = {"Latn"},
	family = "awd",
}

m["pac"] = {
	canonicalName = "Pacoh",
	family = "mkh",
}

m["pad"] = {
	canonicalName = "Paumarí",
	scripts = {"Latn"},
	family = "auf",
}

m["pae"] = {
	canonicalName = "Pagibete",
	family = "bnt",
}

m["paf"] = {
	canonicalName = "Paranawát",
	family = "tup",
}

m["pag"] = {
	canonicalName = "Pangasinan",
	scripts = {"Latn"},
	family = "phi",
}

m["pah"] = {
	canonicalName = "Tenharim",
}

m["pai"] = {
	canonicalName = "Pe",
}

m["pak"] = {
	canonicalName = "Parakanã",
}

m["pal"] = {
	canonicalName = "Middle Persian",
	otherNames = {"Pahlavi"},
	scripts = {"Phlv", "Phli", "Avst", "Phlp"}, -- Phlv and Phlp not in Unicode yet
	family = "ira",
    ancestors = {"peo"},
}

m["pam"] = {
	canonicalName = "Kapampangan",
	otherNames = {"Pampango"},
	scripts = {"Latn"}, -- also Kulitan, which lacks a code
	family = "phi",
}

m["pao"] = {
	canonicalName = "Northern Paiute",
	otherNames = {"Numu", "Numa", "Paviotso", "Mono-Paviotso", "Mono-Bannock", "Bannock"},
	scripts = {"Latn"},
	family = "azc-num",
}

m["pap"] = {
	canonicalName = "Papiamentu",
	otherNames = {"Papiamento"},
	scripts = {"Latn"},
	family = "crp",
}

m["paq"] = {
	canonicalName = "Parya",
	family = "inc",
	ancestors = {"psu"},
}

m["par"] = {
	canonicalName = "Panamint",
	otherNames = {"Panamint Shoshone", "Timbisha", "Tümpisha", "Koso"},
	scripts = {"Latn"},
	family = "azc-num",
}

m["pas"] = {
	canonicalName = "Papasena",
	family = "paa-lkp",
}

m["pat"] = {
	canonicalName = "Papitalai",
	family = "poz-aay",
}

m["pau"] = {
	canonicalName = "Palauan",
	scripts = {"Latn"},
	family = "poz-sus",
}

m["pav"] = {
	canonicalName = "Wari'",
	scripts = {"Latn"},
	family = "sai-cpc",
}

m["paw"] = {
	canonicalName = "Pawnee",
	scripts = {"Latn"},
	family = "cdd",
}

m["pax"] = {
	canonicalName = "Pankararé",
	otherNames = {"Pancaré", "Pankaré", "Pankarare", "Pancare", "Pankare"},
}

m["pay"] = {
	canonicalName = "Pech",
}

m["paz"] = {
	canonicalName = "Pankararú",
	otherNames = {"Pankararu", "Pankarú", "Pankaru", "Pankarurú", "Pankaruru", "Pancaru", "Pankaroru", "Brancararu"},
}

m["pbb"] = {
	canonicalName = "Páez",
}

m["pbc"] = {
	canonicalName = "Patamona",
	family = "sai-car",
}

m["pbe"] = {
	canonicalName = "Mezontla Popoloca",
}

m["pbf"] = {
	canonicalName = "Coyotepec Popoloca",
}

m["pbg"] = {
	canonicalName = "Paraujano",
	family = "awd",
}

m["pbh"] = {
	canonicalName = "Panare",
	family = "sai-car",
}

m["pbi"] = {
	canonicalName = "Podoko",
	otherNames = {"Parkwa", "Parəkwa"},
}

m["pbl"] = {
	canonicalName = "Mak (Nigeria)",
	otherNames = {"Mak", "Panya", "Zo"}, -- Panya and Zo are dialects
	family = "alv",
}

m["pbn"] = {
	canonicalName = "Kpasam",
}

m["pbo"] = {
	canonicalName = "Papel",
}

m["pbp"] = {
	canonicalName = "Badyara",
}

m["pbr"] = {
	canonicalName = "Pangwa",
}

m["pbs"] = {
	canonicalName = "Central Pame",
}

m["pbv"] = {
	canonicalName = "Pnar",
	family = "aav",
}

m["pby"] = {
	canonicalName = "Pyu",
	otherNames = {"Papuan Pyu", "Pyu (New Guinea)", "Pyu (Papua New Guinea)"}, -- distinguish from 'pyx'
}

m["pca"] = {
	canonicalName = "Santa Inés Ahuatempan Popoloca",
}

m["pcb"] = {
	canonicalName = "Pear",
}

m["pcc"] = {
	canonicalName = "Yay",
	otherNames = {"Bouyei"},
	scripts = {"Latn", "Hani"},
	family = "tai",
}

m["pcd"] = {
	canonicalName = "Picard",
	otherNames = {"Chti", "Ch'ti"},
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"fro"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["pce"] = {
	canonicalName = "Ruching Palaung",
	family = "aav",
}

m["pcf"] = {
	canonicalName = "Paliyan",
	family = "dra",
}

m["pcg"] = {
	canonicalName = "Paniya",
	family = "dra",
}

m["pch"] = {
	canonicalName = "Pardhan",
	family = "dra",
	ancestors = {"gon"},
}

m["pci"] = {
	canonicalName = "Duruwa",
	scripts = {"Deva", "Orya"},
	family = "dra",
}

m["pcj"] = {
	canonicalName = "Parenga",
	family = "mun",
}

m["pck"] = {
	canonicalName = "Paite Chin",
	otherNames = {"Paite"},
	family = "tbq-kuk",
}

m["pcl"] = {
	canonicalName = "Pardhi",
}

m["pcm"] = {
	canonicalName = "Nigerian Pidgin",
	scripts = {"Latn"},
	family = "crp",
}

m["pcn"] = {
	canonicalName = "Piti",
}

m["pcp"] = {
	canonicalName = "Pacahuara",
	family = "sai-pan",
}

m["pcw"] = {
	canonicalName = "Pyapun",
}

m["pda"] = {
	canonicalName = "Anam",
}

m["pdc"] = {
	canonicalName = "Pennsylvania German",
	otherNames = {"Pennsylvania Dutch"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmw-rfr"},
}

m["pdi"] = {
	canonicalName = "Pa Di",
}

m["pdn"] = {
	canonicalName = "Fedan",
	family = "poz-ocw",
}

m["pdo"] = {
	canonicalName = "Padoe",
	scripts = {"Latn"},
	family = "poz-btk",
}

m["pdt"] = {
	canonicalName = "Plautdietsch",
	otherNames = {"Mennonite Low German", "Russian Mennonite Low German", "Chortitza", "Molotschna", "Chortica", "Molotcha"},
	scripts = {"Latn"},
	family = "gmw",
    ancestors = {"nds-de"},
}

m["pdu"] = {
	canonicalName = "Kayan",
}

m["pea"] = {
	canonicalName = "Peranakan Indonesian",
}

m["peb"] = {
	canonicalName = "Eastern Pomo",
	family = "nai-pom",
}

m["ped"] = {
	canonicalName = "Mala (New Guinea)",
	otherNames = {"Mala (Papua New Guinea)", "Mala"},
	family = "ngf",
}

m["pee"] = {
	canonicalName = "Taje",
}

m["pef"] = {
	canonicalName = "Northeastern Pomo",
	family = "nai-pom",
}

m["peg"] = {
	canonicalName = "Pengo",
	scripts = {"Orya"},
	family = "dra",
}

m["peh"] = {
	canonicalName = "Bonan",
	family = "xgn",
}

m["pei"] = {
	canonicalName = "Chichimeca-Jonaz",
}

m["pej"] = {
	canonicalName = "Northern Pomo",
	family = "nai-pom",
}

m["pek"] = {
	canonicalName = "Penchal",
	family = "poz-aay",
}

m["pel"] = {
	canonicalName = "Pekal",
}

m["pem"] = {
	canonicalName = "Phende",
}

m["peo"] = {
	canonicalName = "Old Persian",
	scripts = {"Xpeo"},
	family = "ira",
}

m["pep"] = {
	canonicalName = "Kunja",
}

m["peq"] = {
	canonicalName = "Southern Pomo",
	family = "nai-pom",
}

m["pev"] = {
	canonicalName = "Pémono",
	family = "sai-car",
}

m["pex"] = {
	canonicalName = "Petats",
	family = "poz-ocw",
}

m["pey"] = {
	canonicalName = "Petjo",
}

m["pez"] = {
	canonicalName = "Eastern Penan",
	family = "poz-swa",
}

m["pfa"] = {
	canonicalName = "Pááfang",
	family = "poz-mic",
}

m["pfe"] = {
	canonicalName = "Peere",
	otherNames = {"Kutin"},
	scripts = {"Latn"},
	family = "alv",
}

m["pga"] = {
	canonicalName = "Juba Arabic",
	scripts = {"Arab"},
	family = "crp",
	ancestors = {"apd"},
}

m["pgd"] = {
	canonicalName = "Gandhari",
	otherNames = {"Gāndhārī", "Gāndhārī Prakrit"},
	scripts = {"Deva", "Khar"},
	family = "inc",
}

m["pgg"] = {
	canonicalName = "Pangwali",
}

m["pgi"] = {
	canonicalName = "Pagi",
}

m["pgk"] = {
	canonicalName = "Rerep",
	family = "poz-vnc",
}

m["pgl"] = {
	canonicalName = "Primitive Irish",
	scripts = {"Ogam"},
	family = "cel-gae",
	translit_module = "pgl-translit",
}

m["pgn"] = {
	canonicalName = "Paelignian",
	scripts = {"Latn"},
	family = "itc",
}

m["pgs"] = {
	canonicalName = "Pangseng",
}

m["pgu"] = {
	canonicalName = "Pagu",
}

m["pgz"] = {
	canonicalName = "Papua New Guinean Sign Language",
	otherNames = {"Papua New Guinea Sign Language", "Melanesian Sign Language", "PNGSL"},
	family = "sgn",
}

m["pha"] = {
	canonicalName = "Pa-Hng",
	family = "hmn",
}

m["phd"] = {
	canonicalName = "Phudagi",
}

m["phg"] = {
	canonicalName = "Phuong",
	family = "mkh",
}

m["phh"] = {
	canonicalName = "Phukha",
	family = "tbq-lol",
}

m["phk"] = {
	canonicalName = "Phake",
}

m["phl"] = {
	canonicalName = "Phalura",
}

m["phm"] = {
	canonicalName = "Phimbi",
}

m["phn"] = {
	canonicalName = "Phoenician",
	scripts = {"Phnx"},
	family = "sem-can",
}

m["pho"] = {
	canonicalName = "Phunoi",
	family = "tbq-lol",
}

m["phq"] = {
	canonicalName = "Phana'",
	family = "tbq-lol",
}

m["phr"] = {
	canonicalName = "Pahari-Potwari",
	otherNames = {"Pothohari", "Pothwari"},
	scripts = {"fa-Arab", "Latn"},
	family = "inc",
	ancestors = {"lah"},
}

m["pht"] = {
	canonicalName = "Phu Thai",
}

m["phu"] = {
	canonicalName = "Phuan",
}

m["phv"] = {
	canonicalName = "Pahlavani",
}

m["phw"] = {
	canonicalName = "Phangduwali",
}

m["pia"] = {
	canonicalName = "Pima Bajo",
	family = "azc",
}

m["pib"] = {
	canonicalName = "Yine",
	otherNames = {"Piro", "Pirro", "Pira", "Chontaquiro", "Contaquiro", "Simirinche", "Simiranch"},
	scripts = {"Latn"},
	family = "awd",
}

m["pic"] = {
	canonicalName = "Pinji",
}

m["pid"] = {
	canonicalName = "Piaroa",
}

m["pie"] = {
	canonicalName = "Piro",
	family = "nai-kta",
}

m["pif"] = {
	canonicalName = "Pingelapese",
	family = "poz-mic",
}

m["pig"] = {
	canonicalName = "Pisabo",
	family = "sai-pan",
}

m["pih"] = {
	canonicalName = "Pitcairn-Norfolk",
	otherNames = {"Pitkern-Norfuk", "Pitcairn", "Pitkern", "Norfolk", "Norfuk"},
	scripts = {"Latn"},
	family = "crp",
}

m["pii"] = {
	canonicalName = "Pini",
}

m["pij"] = {
	canonicalName = "Pijao",
}

m["pil"] = {
	canonicalName = "Yom",
}

m["pim"] = {
	canonicalName = "Powhatan",
	scripts = {"Latn"},
	family = "alg",
}

m["pin"] = {
	canonicalName = "Piame",
}

m["pio"] = {
	canonicalName = "Piapoco",
	family = "awd",
}

m["pip"] = {
	canonicalName = "Pero",
}

m["pir"] = {
	canonicalName = "Piratapuyo",
	family = "sai-tuc",
}

m["pis"] = {
	canonicalName = "Pijin",
	otherNames = {"Kanaka", "Neo-Solomonic", "Solomons Pidgin"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["pit"] = {
	canonicalName = "Pitta-Pitta",
	otherNames = {"Pitta Pitta"},
	scripts = {"Latn"},
	family = "aus-kar",
}

m["piu"] = {
	canonicalName = "Pintupi-Luritja",
}

m["piv"] = {
	canonicalName = "Pileni",
	otherNames = {"Vaeakau-Taumako"},
	family = "poz-pol",
	scripts = {"Latn"},
}

m["piw"] = {
	canonicalName = "Pimbwe",
}

m["pix"] = {
	canonicalName = "Piu",
}

m["piy"] = {
	canonicalName = "Piya-Kwonci",
}

m["piz"] = {
	canonicalName = "Pije",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["pjt"] = {
	canonicalName = "Pitjantjatjara",
	scripts = {"pjt-Latn"},
	family = "aus-pam",
}

m["pka"] = {
	canonicalName = "Ardhamagadhi Prakrit",
	otherNames = {"Magadhi Prakrit"},
	family = "inc",
}

m["pkb"] = {
	canonicalName = "Kipfokomo",
}

m["pkc"] = {
	canonicalName = "Baekje",
	scripts = {"Hani"},
}

m["pkg"] = {
	canonicalName = "Pak-Tong",
}

m["pkh"] = {
	canonicalName = "Pankhu",
	otherNames = {"Pankho", "Pangkhua", "Pangkho", "Pangkhu", "Panko"},
	family = "tbq-kuk",
}

m["pkn"] = {
	canonicalName = "Pakanha",
}

m["pko"] = {
	canonicalName = "Pökoot",
	family = "sdv",
}

m["pkp"] = {
	canonicalName = "Pukapukan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["pkr"] = {
	canonicalName = "Attapady Kurumba",
	family = "dra",
}

m["pks"] = {
	canonicalName = "Pakistan Sign Language",
	otherNames = {"Pakistani Sign Language"},
	family = "sgn",
}

m["pkt"] = {
	canonicalName = "Maleng",
	family = "mkh-vie",
}

m["pku"] = {
	canonicalName = "Paku",
}

m["pla"] = {
	canonicalName = "Miani",
}

m["plb"] = {
	canonicalName = "Polonombauk",
	family = "poz-vnc",
}

m["plc"] = {
	canonicalName = "Central Palawano",
	family = "phi",
}

m["ple"] = {
	canonicalName = "Palu'e",
	scripts = {"Latn"},
	family = "plf",
}

m["plg"] = {
	canonicalName = "Pilagá",
	otherNames = {"Pilacá"},
	scripts = {"Latn"},
	family = "sai-guc",
}

m["plh"] = {
	canonicalName = "Paulohi",
}

m["plj"] = {
	canonicalName = "Polci",
}

m["plk"] = {
	canonicalName = "Kohistani Shina",
}

m["pll"] = {
	canonicalName = "Shwe Palaung",
	family = "aav",
}

m["pln"] = {
	canonicalName = "Palenquero",
	scripts = {"Latn"},
	family = "crp",
}

m["plo"] = {
	canonicalName = "Oluta Popoluca",
}

m["plp"] = {
	canonicalName = "Palpa",
	family = "inc",
}

m["plq"] = {
	canonicalName = "Palaic",
	scripts = {"Xsux"},
	family = "ine-ana",
}

m["plr"] = {
	canonicalName = "Palaka Senoufo",
}

m["pls"] = {
	canonicalName = "San Marcos Tlalcoyalco Popoloca",
}

m["plu"] = {
	canonicalName = "Palikur",
	otherNames = {"Palikúr"},
	scripts = {"Latn"},
	family = "awd",
}

m["plv"] = {
	canonicalName = "Southwest Palawano",
	family = "phi",
}

m["plw"] = {
	canonicalName = "Brooke's Point Palawano",
	family = "phi",
}

m["ply"] = {
	canonicalName = "Bolyu",
	family = "mkh",
}

m["plz"] = {
	canonicalName = "Paluan",
	scripts = {"Latn"},
}

m["pma"] = {
	canonicalName = "Paama",
	family = "poz-vnc",
}

m["pmb"] = {
	canonicalName = "Pambia",
	family = "znd",
}

m["pmd"] = {
	canonicalName = "Pallanganmiddang",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["pme"] = {
	canonicalName = "Pwaamei",
	family = "poz-cln",
}

m["pmf"] = {
	canonicalName = "Pamona",
	otherNames = {"Bare'e"},
	scripts = {"Latn"},
}

m["pmh"] = {
	canonicalName = "Maharastri Prakrit",
	otherNames = {"Maharashtri Prakrit", "Maharastri", "Maharashtri"},
	family = "inc",
	translit_module = "Brah-translit",
}

m["pmi"] = {
	canonicalName = "Northern Pumi",
	otherNames = {"Northern Prinmi", "Northern Pimi"},
	family = "sit-qia",
}

m["pmj"] = {
	canonicalName = "Southern Pumi",
	otherNames = {"Southern Prinmi", "Southern Pimi"},
	family = "sit-qia",
}

m["pmk"] = {
	canonicalName = "Pamlico",
	scripts = {"Latn"},
}

m["pml"] = {
	canonicalName = "Sabir",
	otherNames = {"Mediterranean Lingua Franca", "Lingua Franca"},
	scripts = {"Latn"},
	family = "crp",
}

m["pmm"] = {
	canonicalName = "Pol",
	otherNames = {"Pol Pomo", "Pomo"},
	scripts = {"Latn"},
	family = "bnt",
}

m["pmn"] = {
	canonicalName = "Pam",
}

m["pmo"] = {
	canonicalName = "Pom",
	family = "poz-hce",
}

m["pmq"] = {
	canonicalName = "Northern Pame",
}

m["pmr"] = {
	canonicalName = "Paynamar",
}

m["pms"] = {
	canonicalName = "Piedmontese",
	scripts = {"Latn"},
	family = "roa",
}

m["pmt"] = {
	canonicalName = "Tuamotuan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["pmu"] = {
	canonicalName = "Mirpur Panjabi",
}

m["pmw"] = {
	canonicalName = "Plains Miwok",
	family = "nai-you",
}

m["pmx"] = {
	canonicalName = "Poumei Naga",
}

m["pmy"] = {
	canonicalName = "Papuan Malay",
}

m["pmz"] = {
	canonicalName = "Southern Pame",
}

m["pna"] = {
	canonicalName = "Punan Bah-Biau",
}

m["pnb"] = {
	canonicalName = "Western Panjabi",
	scripts = {"pa-Arab"},
	family = "inc",
}

m["pnc"] = {
	canonicalName = "Pannei",
}

m["pne"] = {
	canonicalName = "Western Penan",
	family = "poz-swa",
}

m["png"] = {
	canonicalName = "Pongu",
}

m["pnh"] = {
	canonicalName = "Penrhyn",
	otherNames = {"Tongareva", "Tongarewa"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["pni"] = {
	canonicalName = "Aoheng",
}

m["pnj"] = {
	canonicalName = "Pinjarup",
}

m["pnk"] = {
	canonicalName = "Paunaca",
	otherNames = {"Pauna", "Paunaka"},
	scripts = {"Latn"},
	family = "awd",
}

m["pnl"] = {
	canonicalName = "Paleni",
	family = "alv",
}

m["pnm"] = {
	canonicalName = "Punan Batu",
}

m["pnn"] = {
	canonicalName = "Pinai-Hagahai",
}

m["pno"] = {
	canonicalName = "Panobo",
	family = "sai-pan",
}

m["pnp"] = {
	canonicalName = "Pancana",
}

m["pnq"] = {
	canonicalName = "Pana (West Africa)",
	otherNames = {"Pana (Burkina Faso)", "Pana"},
}

m["pnr"] = {
	canonicalName = "Panim",
}

m["pns"] = {
	canonicalName = "Ponosakan",
}

m["pnt"] = {
	canonicalName = "Pontic Greek",
	otherNames = {"Pontic"},
	scripts = {"polytonic", "Latn", "Cyrl"},
	family = "grk",
	ancestors = {"grc"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, grc, cpg
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
}

m["pnu"] = {
	canonicalName = "Jiongnai Bunu",
	otherNames = {"Kiong Nai"},
	family = "hmn",
}

m["pnv"] = {
	canonicalName = "Pinigura",
	family = "aus-psw",
}

m["pnw"] = {
	canonicalName = "Panyjima",
	scripts = {"Latn"},
	family = "aus-nga",
}

m["pnx"] = {
	canonicalName = "Phong-Kniang",
	family = "mkh",
}

m["pny"] = {
	canonicalName = "Pinyin",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["pnz"] = {
	canonicalName = "Pana (Central Africa)",
	otherNames = {"Pana (Central African Republic)", "Pana"},
}

m["poc"] = {
	canonicalName = "Poqomam",
}

m["poe"] = {
	canonicalName = "San Juan Atzingo Popoloca",
}

m["pof"] = {
	canonicalName = "Poke",
}

m["pog"] = {
	canonicalName = "Potiguára",
}

m["poh"] = {
	canonicalName = "Poqomchi'",
}

m["poi"] = {
	canonicalName = "Highland Popoluca",
	family = "nai-miz",
}

m["pok"] = {
	canonicalName = "Pokangá",
	family = "sai-tuc",
}

m["pom"] = {
	canonicalName = "Southeastern Pomo",
	family = "nai-pom",
}

m["pon"] = {
	canonicalName = "Pohnpeian",
	scripts = {"Latn"},
	family = "poz-mic",
}

m["poo"] = {
	canonicalName = "Central Pomo",
	family = "nai-pom",
}

m["pop"] = {
	canonicalName = "Pwapwa",
	family = "poz-cln",
}

m["poq"] = {
	canonicalName = "Texistepec Popoluca",
}

m["pos"] = {
	canonicalName = "Sayula Popoluca",
	scripts = {"Latn"},
	family = "nai-miz",
}

m["pot"] = {
	canonicalName = "Potawatomi",
	otherNames = {"Pottawatomie"},
	scripts = {"Latn"},
	family = "alg",
}

m["pov"] = {
	canonicalName = "Guinea-Bissau Creole",
	otherNames = {"Upper Guinea Creole", "Upper Guinea Crioulo", "Kriol", "Crioulo", "Kriolu", "Kriyol", "Kiriol"},
	scripts = {"Latn"},
	family = "crp",
}

m["pow"] = {
	canonicalName = "San Felipe Otlaltepec Popoloca",
}

m["pox"] = {
	canonicalName = "Polabian",
	scripts = {"Latn"},
	family = "zlw",
}

m["poy"] = {
	canonicalName = "Pogolo",
}

m["ppa"] = {
	canonicalName = "Pao",
}

m["ppe"] = {
	canonicalName = "Papi",
}

m["ppi"] = {
	canonicalName = "Paipai",
	otherNames = {"Akwa'ala"},
	family = "nai-yuc",
}

m["ppk"] = {
	canonicalName = "Uma",
	scripts = {"Latn"},
	family = "poz-kal",
}

m["ppl"] = {
	canonicalName = "Pipil", 
	otherNames = {"Nahuat", "Náhuat", "Nawat", "Náwat"},
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}
	},
}

m["ppm"] = {
	canonicalName = "Papuma",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["ppn"] = {
	canonicalName = "Papapana",
	family = "poz-ocw",
}

m["ppo"] = {
	canonicalName = "Folopa",
	otherNames = {"Podopa", "Polopa", "Podoba", "Foraba", "Tebera", "Boro", "Suri", "Sopese"},
	scripts = {"Latn"},
}

m["ppp"] = {
	canonicalName = "Pelende",
}

m["ppq"] = {
	canonicalName = "Pei",
}

m["pps"] = {
	canonicalName = "San Luís Temalacayuca Popoloca",
}

m["ppt"] = {
	canonicalName = "Pa",
	otherNames = {"Pari", "Pare", "Akium-Pare"},
	scripts = {"Latn"},
}

m["ppu"] = {
	canonicalName = "Papora",
	otherNames = {"Hoanya", "Papola", "Paporan", "Bupuran", "Vupuran", "Hinapavosa"},
	scripts = {"Latn"},
	family = "map",
}

m["pqa"] = {
	canonicalName = "Pa'a",
}

m["pqm"] = {
	canonicalName = "Malecite-Passamaquoddy",
	otherNames = {"Malecite", "Maliseet", "Passamaquoddy"},
	scripts = {"Latn"},
	family = "alg",
}

m["prb"] = {
	canonicalName = "Lua'",
	otherNames = {"Pray"},
	family = "mkh",
}

m["prc"] = {
	canonicalName = "Parachi",
	family = "ira",
}

m["pre"] = {
	canonicalName = "Principense",
	scripts = {"Latn"},
	family = "crp",
}

m["prf"] = {
	canonicalName = "Paranan",
}

m["prg"] = {
	canonicalName = "Old Prussian",
	otherNames = {"Prussian"},
	scripts = {"Latn"},
	family = "bat",
}

m["prh"] = {
	canonicalName = "Porohanon",
}

m["pri"] = {
	canonicalName = "Paicî",
	family = "poz-cln",
}

m["prk"] = {
	canonicalName = "Parauk",
	family = "aav",
}

m["prl"] = {
	canonicalName = "Peruvian Sign Language",
	family = "sgn",
}

m["prm"] = {
	canonicalName = "Kibiri",
}

m["prn"] = {
	canonicalName = "Prasuni",
	family = "iir-nur",
}

m["pro"] = {
	canonicalName = "Old Provençal",
	otherNames = {"Old Occitan"},
	scripts = {"Latn"},
	family = "roa",
	sort_key = {
		from = {"ç"},
		to   = {"c"}} ,
}

m["prq"] = {
	canonicalName = "Ashéninka Perené",
	family = "awd",
}

m["prr"] = {
	canonicalName = "Puri",
}

m["prt"] = {
	canonicalName = "Phai",
	otherNames = {"Prai", "Pray", "Phray"},
	family = "mkh",
}

m["pru"] = {
	canonicalName = "Puragi",
}

m["prw"] = {
	canonicalName = "Parawen",
}

m["prx"] = {
	canonicalName = "Purik",
}

m["prz"] = {
	canonicalName = "Providencia Sign Language",
	otherNames = {"Providence Island Sign Language"},
	family = "sgn",
}

m["psa"] = {
	canonicalName = "Asue Awyu",
	otherNames = {"Pisa"},
}

m["psc"] = {
	canonicalName = "Persian Sign Language",
	family = "sgn",
}

m["psd"] = {
	canonicalName = "Plains Indian Sign Language",
	family = "sgn",
}

m["pse"] = {
	canonicalName = "Central Malay",
	family = "poz-mly",
}

m["psg"] = {
	canonicalName = "Penang Sign Language",
	family = "sgn",
}

m["psh"] = {
	canonicalName = "Southwest Pashayi",
	family = "inc-dar",
}

m["psi"] = {
	canonicalName = "Southeast Pashayi",
	family = "inc-dar",
}

m["psl"] = {
	canonicalName = "Puerto Rican Sign Language",
	family = "sgn-fsl",
}

m["psm"] = {
	canonicalName = "Pauserna",
	family = "tup",
}

m["psn"] = {
	canonicalName = "Panasuan",
	family = "poz",
}

m["pso"] = {
	canonicalName = "Polish Sign Language",
	family = "sgn-gsl",
}

m["psp"] = {
	canonicalName = "Philippine Sign Language",
	family = "sgn-fsl",
}

m["psq"] = {
	canonicalName = "Pasi",
}

m["psr"] = {
	canonicalName = "Portuguese Sign Language",
	family = "sgn", -- this is the in Swedish SL fam, whenever that gets a code
}

m["pss"] = {
	canonicalName = "Kaulong",
	family = "poz-ocw",
}

m["psu"] = {
	canonicalName = "Sauraseni Prakrit",
	otherNames = {"Sauraseni", "Shauraseni"},
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"sa"},
	translit_module = "Brah-translit",
}

m["psw"] = {
	canonicalName = "Port Sandwich",
	family = "poz-vnc",
}

m["psy"] = {
	canonicalName = "Piscataway",
}

m["pta"] = {
	canonicalName = "Pai Tavytera",
}

m["pth"] = {
	canonicalName = "Pataxó Hã-Ha-Hãe",
}

m["pti"] = {
	canonicalName = "Pintiini",
}

m["ptn"] = {
	canonicalName = "Patani",
	family = "poz-hce",
}

m["pto"] = {
	canonicalName = "Zo'é",
}

m["ptp"] = {
	canonicalName = "Patep",
	family = "poz-ocw",
}

m["ptq"] = {
	canonicalName = "Pattapu",
	family = "dra",
}

m["ptr"] = {
	canonicalName = "Piamatsina",
	family = "poz-vnc",
}

m["ptt"] = {
	canonicalName = "Enrekang",
}

m["ptu"] = {
	canonicalName = "Bambam",
}

m["ptv"] = {
	canonicalName = "Port Vato",
}

m["ptw"] = {
	canonicalName = "Pentlatch",
}

m["pty"] = {
	canonicalName = "Pathiya",
	family = "dra",
}

m["pua"] = {
	canonicalName = "Purepecha",
	otherNames = {"Tarascan", "Tarasco", "P'urhepecha", "Purépecha", "P'urhépecha", "Phorhépecha", "Phorhé", "Porhé"},
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["pub"] = {
	canonicalName = "Purum",
	otherNames = {"Purum Naga"},
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["puc"] = {
	canonicalName = "Punan Merap",
}

m["pud"] = {
	canonicalName = "Punan Aput",
}

m["pue"] = {
	canonicalName = "Puelche",
}

m["puf"] = {
	canonicalName = "Punan Merah",
}

m["pug"] = {
	canonicalName = "Phuie",
}

m["pui"] = {
	canonicalName = "Puinave",
	otherNames = {"Puinabe", "Wãnsöhöt", "Guipunave", "Güipunave", "Waipunavi", "Guaipunabi"},
}

m["puj"] = {
	canonicalName = "Punan Tubu",
	family = "poz-swa",
}

m["puk"] = {
	canonicalName = "Pu Ko",
}

m["pum"] = {
	canonicalName = "Puma",
}

m["puo"] = {
	canonicalName = "Puoc",
	family = "mkh",
}

m["pup"] = {
	canonicalName = "Pulabu",
}

m["puq"] = {
	canonicalName = "Puquina",
}

m["pur"] = {
	canonicalName = "Puruborá",
}

m["put"] = {
	canonicalName = "Putoh",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["puu"] = {
	canonicalName = "Punu",
	scripts = {"Latn"},
	family = "bnt",
}

m["puw"] = {
	canonicalName = "Puluwat",
	otherNames = {"Puluwatese"},
	family = "poz-mic",
}

m["pux"] = {
	canonicalName = "Puare",
}

m["puy"] = {
	canonicalName = "Purisimeño",
	family = "nai-chu",
}

m["pwa"] = {
	canonicalName = "Pawaia",
	scripts = {"Latn"},
}

m["pwb"] = {
	canonicalName = "Panawa",
	family = "nic-bco",
}

m["pwg"] = {
	canonicalName = "Gapapaiwa",
	family = "poz-ocw",
}

m["pwi"] = {
	canonicalName = "Patwin",
	otherNames = {"River Patwin", "Valley Patwin", "Hill Patwin", "Southern Patwin"},
	scripts = {"Latn"},
	family = "nai-wtq",
}

m["pwm"] = {
	canonicalName = "Molbog",
	family = "poz",
}

m["pwn"] = {
	canonicalName = "Paiwan",
	scripts = {"Latn"},
	family = "map",
}

m["pwo"] = {
	canonicalName = "Western Pwo",
	otherNames = {"Delta Pwo", "Pwo Western Karen"},
	family = "tbq",
}

m["pwr"] = {
	canonicalName = "Powari",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"psu"},
}

m["pww"] = {
	canonicalName = "Northern Pwo",
	otherNames = {"Phlong", "Pwo Northern Karen"},
	family = "tbq",
}

m["pxm"] = {
	canonicalName = "Quetzaltepec Mixe",
}

m["pye"] = {
	canonicalName = "Pye Krumen",
}

m["pym"] = {
	canonicalName = "Fyam",
	otherNames = {"Fyem", "Pyem"},
	scripts = {"Latn"},
}

m["pyn"] = {
	canonicalName = "Poyanáwa",
	otherNames = {"Poyanawa"},
	family = "sai-pan",
}

m["pys"] = {
	canonicalName = "Paraguayan Sign Language",
	family = "sgn",
}

m["pyu"] = {
	canonicalName = "Puyuma",
	scripts = {"Latn"},
	family = "map",
}

m["pyx"] = {
	canonicalName = "Tircul",
	otherNames = {"Pyu"},
	family = "tbq",
}

m["pyy"] = {
	canonicalName = "Pyen",
	otherNames = {"Hpyin", "Phen"},
	family = "tbq-lol",
}

m["pzn"] = {
	canonicalName = "Para Naga",
}

return m