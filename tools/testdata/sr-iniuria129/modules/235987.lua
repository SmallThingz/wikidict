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

local Latn = {"Latn"}

local m = {}

m["pab"] = {
	"Pareci",
	"Q3504312",
	"awd",
	otherNames = {"Parecis", "Parecís", "Paresi", "Paresí"},
	scripts = Latn,
}

m["pac"] = {
	"Pacoh",
	"Q3441136",
	"mkh-kat",
}

m["pad"] = {
	"Paumarí",
	"Q389827",
	"auf",
	scripts = Latn,
}

m["pae"] = {
	"Pagibete",
	"Q7124357",
	"bnt",
	scripts = Latn,
}

m["paf"] = {
	"Paranawát",
	"Q12953806",
	"tup-gua",
	scripts = Latn,
}

m["pag"] = {
	"Pangasinan",
	"Q33879",
	"phi",
	scripts = Latn,
}

m["pah"] = {
	"Tenharim",
	"Q10266010",
	"tup-gua",
	otherNames = {"Parintintín"},
	scripts = Latn,
}

m["pai"] = {
	"Pe",
	"Q3914871",
}

m["pak"] = {
	"Parakanã",
	"Q12953804",
	"tup-gua",
	otherNames = {"Awaeté"},
	scripts = Latn,
}

m["pal"] = {
	"Middle Persian",
	"Q32063",
	"ira-wes",
	otherNames = {"Pahlavi", "Manichaean Middle Persian"},
	scripts = {"Latn", "Phli", "Avst", "Mani", "Phlv", "Phlp"}, -- Latn for translit; Phlv, Phlp not in Unicode
	translit_module = "translit-redirect",
    ancestors = {"peo"},
}

m["pam"] = {
	"Kapampangan",
	"Q36121",
	"phi",
	otherNames = {"Pampango"},
	scripts = Latn, -- also Kulitan, which lacks a code
}

m["pao"] = {
	"Northern Paiute",
	"Q3360656",
	"azc-num",
	otherNames = {"Numu", "Numa", "Paviotso", "Mono-Paviotso", "Mono-Bannock", "Bannock"},
	scripts = Latn,
}

m["pap"] = {
	"Papiamentu",
	"Q33856",
	"crp",
	otherNames = {"Papiamento"},
	scripts = Latn,
}

m["paq"] = {
	"Parya",
	"Q1135134",
	"inc",
	ancestors = {"psu"},
}

m["par"] = {
	"Panamint",
	"Q33926",
	"azc-num",
	otherNames = {"Panamint Shoshone", "Timbisha", "Tümpisha", "Koso"},
	scripts = Latn,
}

m["pas"] = {
	"Papasena",
	"Q7132508",
	"paa-lkp",
	scripts = Latn,
}

m["pat"] = {
	"Papitalai",
	"Q6528659",
	"poz-aay",
	scripts = Latn,
}

m["pau"] = {
	"Palauan",
	"Q33776",
	"poz-sus",
	scripts = Latn,
}

m["pav"] = {
	"Wari'",
	"Q3027909",
	"sai-cpc",
	scripts = Latn,
}

m["paw"] = {
	"Pawnee",
	"Q56751",
	"cdd",
	scripts = Latn,
}

m["pax"] = {
	"Pankararé",
	"Q25559779",
	otherNames = {"Pancaré", "Pankaré", "Pankarare", "Pancare", "Pankare"},
}

m["pay"] = {
	"Pech",
	"Q4898889",
	"cba",
}

m["paz"] = {
	"Pankararú",
	"Q7131310",
	otherNames = {"Pankararu", "Pankarú", "Pankaru", "Pankarurú", "Pankaruru", "Pancaru", "Pankaroru", "Brancararu"},
}

m["pbb"] = {
	"Páez",
	"Q33677",
	scripts = Latn,
}

m["pbc"] = {
	"Patamona",
	"Q3915921",
	"sai-car",
	scripts = Latn,
}

m["pbe"] = {
	"Mezontla Popoloca",
	"Q42365630",
	"omq-pop",
	scripts = Latn,
}

m["pbf"] = {
	"Coyotepec Popoloca",
	"Q5180100",
	"omq-pop",
	scripts = Latn,
}

m["pbg"] = {
	"Paraujano",
	"Q3501747",
	"awd",
	scripts = Latn,
}

m["pbh"] = {
	"Panare",
	"Q56610",
	"sai-car",
	scripts = Latn,
}

m["pbi"] = {
	"Podoko",
	"Q3515096",
	otherNames = {"Parkwa", "Parəkwa"},
	scripts = Latn,
}

m["pbl"] = {
	"Mak (Nigeria)",
	"Q3915349",
	"alv",
	otherNames = {"Mak", "Panya", "Zo"}, -- Panya and Zo are dialects
	scripts = Latn,
}

m["pbm"] = {
	"Puebla Mazatec",
	nil,
	"omq-maz",
	otherNames = {"Mazateco de Puebla y del Noroeste"},
	scripts = Latn,
}

m["pbn"] = {
	"Kpasam",
	"Q3914902",
}

m["pbo"] = {
	"Papel",
	"Q36314",
}

m["pbp"] = {
	"Badyara",
	"Q35095",
}

m["pbr"] = {
	"Pangwa",
	"Q3847550",
	"bnt",
	scripts = Latn,
}

m["pbs"] = {
	"Central Pame",
	"Q3361763",
	"omq",
	scripts = Latn,
}

m["pbv"] = {
	"Pnar",
	"Q3501850",
	"aav",
}

m["pby"] = {
	"Pyu",
	"Q2567925",
	otherNames = {"Papuan Pyu", "Pyu (New Guinea)", "Pyu (Papua New Guinea)"}, -- distinguish from 'pyx'
}

m["pca"] = {
	"Santa Inés Ahuatempan Popoloca",
	"Q42365276",
	"omq-pop",
	scripts = Latn,
}

m["pcb"] = {
	"Pear",
	"Q6583669",
}

m["pcc"] = {
	"Bouyei",
	"Q35100",
	"tai-nor",
	otherNames = {"Buyi", "Buyei", "Puyi", "Giay", "Yay"},
	scripts = {"Latn", "Hani"},
}

m["pcd"] = {
	"Picard",
	"Q34024",
	"roa-oil",
	otherNames = {"Chti", "Ch'ti", "Rouchi", "Rouchy"},
	scripts = Latn,
	ancestors = {"fro"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["pce"] = {
	"Ruching Palaung",
	"Q12953798",
	"aav",
}

m["pcf"] = {
	"Paliyan",
	"Q7127643",
	"dra",
}

m["pcg"] = {
	"Paniya",
	"Q7131211",
	"dra",
}

m["pch"] = {
	"Pardhan",
	"Q7133207",
	"dra",
	ancestors = {"gon"},
}

m["pci"] = {
	"Duruwa",
	"Q56753",
	"dra",
	scripts = {"Deva", "Orya"},
}

m["pcj"] = {
	"Parenga",
	"Q3111396",
	"mun",
}

m["pck"] = {
	"Paite",
	"Q12952337",
	"tbq-kuk",
	otherNames = {"Paite Chin"},
}

m["pcl"] = {
	"Pardhi",
	"Q7136554",
}

m["pcm"] = {
	"Nigerian Pidgin",
	"Q33655",
	"crp",
	scripts = Latn,
}

m["pcn"] = {
	"Piti",
	"Q3913375",
}

m["pcp"] = {
	"Pacahuara",
	"Q2591165",
	"sai-pan",
	scripts = Latn,
}

m["pcw"] = {
	"Pyapun",
	"Q3438807",
}

m["pda"] = {
	"Anam",
	"Q3501930",
}

m["pdc"] = {
	"Pennsylvania German",
	"Q22711",
	"gmw",
	otherNames = {"Pennsylvania Dutch"},
	scripts = Latn,
	ancestors = {"gmw-rfr"},
}

m["pdi"] = {
	"Pa Di",
	"Q3359940",
}

m["pdn"] = {
	"Fedan",
	"Q7206699",
	"poz-ocw",
	scripts = Latn,
}

m["pdo"] = {
	"Padoe",
	"Q3360370",
	"poz-btk",
	scripts = Latn,
}

m["pdt"] = {
	"Plautdietsch",
	"Q1751432",
	"gmw",
	otherNames = {"Mennonite Low German", "Russian Mennonite Low German", "Chortitza", "Molotschna", "Chortica", "Molotcha"},
	scripts = Latn,
    ancestors = {"nds-de"},
}

m["pdu"] = {
	"Kayan",
	"Q7123283",
}

m["pea"] = {
	"Peranakan Indonesian",
	"Q653415",
	scripts = Latn,
}

m["peb"] = {
	"Eastern Pomo",
	"Q3396032",
	"nai-pom",
	scripts = Latn,
}

m["ped"] = {
	"Mala (New Guinea)",
	"Q11732569",
	"ngf-mad",
	otherNames = {"Mala (Papua New Guinea)", "Mala"},
	scripts = Latn,
}

m["pee"] = {
	"Taje",
	"Q12953902",
}

m["pef"] = {
	"Northeastern Pomo",
	"Q3396018",
	"nai-pom",
	scripts = Latn,
}

m["peg"] = {
	"Pengo",
	"Q56758",
	"dra",
	scripts = {"Orya"},
}

m["peh"] = {
	"Bonan",
	"Q32983",
	"xgn",
}

m["pei"] = {
	"Chichimeca-Jonaz",
	"Q3915427",
	scripts = Latn,
}

m["pej"] = {
	"Northern Pomo",
	"Q3396021",
	"nai-pom",
	scripts = Latn,
}

m["pek"] = {
	"Penchal",
	"Q3374631",
	"poz-aay",
	scripts = Latn,
}

m["pel"] = {
	"Pekal",
	"Q3241781",
}

m["pem"] = {
	"Phende",
	"Q7162372",
}

m["peo"] = {
	"Old Persian",
	"Q35225",
	"ira-wes",
	scripts = {"Xpeo"},
	translit_module = "peo-translit",
}

m["pep"] = {
	"Kunja",
	"Q6444807",
}

m["peq"] = {
	"Southern Pomo",
	"Q3396023",
	"nai-pom",
	scripts = Latn,
}

-- "pes" IS TREATED AS "fa" (or as etymology-only), SEE WT:LT

m["pev"] = {
	"Pémono",
	"Q3439012",
	"sai-car",
	scripts = Latn,
}

m["pex"] = {
	"Petats",
	"Q3376353",
	"poz-ocw",
	scripts = Latn,
}

m["pey"] = {
	"Petjo",
	"Q940486",
}

m["pez"] = {
	"Eastern Penan",
	"Q18638342",
	"poz-swa",
	scripts = Latn,
}

m["pfa"] = {
	"Pááfang",
	"Q3063517",
	"poz-mic",
	scripts = Latn,
}

m["pfe"] = {
	"Peere",
	"Q36377",
	"alv",
	otherNames = {"Kutin"},
	scripts = Latn,
}

m["pga"] = {
	"Juba Arabic",
	"Q1262143",
	"crp",
	scripts = Latn,
	ancestors = {"apd"},
}

m["pgd"] = {
	"Gandhari",
	nil,
	"inc",
	otherNames = {"Gāndhārī", "Gāndhārī Prakrit"},
	scripts = {"Deva", "Khar"},
	ancestors = {"inc-ash"},
	translit_module = "Khar-translit",
}

m["pgg"] = {
	"Pangwali",
	"Q13600429",
}

m["pgi"] = {
	"Pagi",
	"Q7124354",
}

m["pgk"] = {
	"Rerep",
	"Q586907",
	"poz-vnc",
	scripts = Latn,
}

m["pgl"] = {
	"Primitive Irish",
	"Q3320030",
	"cel-gae",
	scripts = {"Ogam"},
	translit_module = "pgl-translit",
}

m["pgn"] = {
	"Paelignian",
	nil,
	"itc",
	scripts = Latn,
}

m["pgs"] = {
	"Pangseng",
	"Q3914027",
	"nic-gur",
}

m["pgu"] = {
	"Pagu",
	"Q7124462",
}

m["pgz"] = {
	"Papua New Guinean Sign Language",
	"Q25044405",
	"sgn",
	otherNames = {"Papua New Guinea Sign Language", "Melanesian Sign Language", "PNGSL"},
}

m["pha"] = {
	"Pa-Hng",
	"Q2625410",
	"hmn",
}

m["phd"] = {
	"Phudagi",
	"Q7188289",
}

m["phg"] = {
	"Phuong",
	"Q7188376",
	"mkh-kat",
}

m["phh"] = {
	"Phukha",
	"Q7188298",
	"tbq-lol",
}

m["phk"] = {
	"Phake",
	"Q7675798",
	"tai-swe",
}

m["phl"] = {
	"Phalura",
	"Q2449549",
	"inc-dar",
}

m["phm"] = {
	"Phimbi",
	"Q11007144",
}

m["phn"] = {
	"Phoenician",
	"Q36734",
	"sem-can",
	scripts = {"Phnx"},
	translit_module = "Phnx-translit",
}

m["pho"] = {
	"Phunoi",
	"Q7188361",
	"tbq-lol",
}

m["phq"] = {
	"Phana'",
	"Q7180427",
	"tbq-lol",
}

m["phr"] = {
	"Pahari-Potwari",
	"Q33739",
	"inc",
	otherNames = {"Pothohari", "Pothwari"},
	scripts = {"fa-Arab", "Latn"},
	ancestors = {"lah"},
}

m["pht"] = {
	"Phu Thai",
	"Q3626597",
	"tai-swe",
}

m["phu"] = {
	"Phuan",
	"Q3915665",
}

m["phv"] = {
	"Pahlavani",
	"Q7124567",
}

m["phw"] = {
	"Phangduwali",
	"Q12953036",
}

m["pia"] = {
	"Pima Bajo",
	"Q3388544",
	"azc",
	scripts = Latn,
}

m["pib"] = {
	"Yine",
	"Q3135432",
	"awd",
	otherNames = {"Piro", "Pirro", "Pira", "Chontaquiro", "Contaquiro", "Simirinche", "Simiranch"},
	scripts = Latn,
}

m["pic"] = {
	"Pinji",
	"Q36296",
}

m["pid"] = {
	"Piaroa",
	"Q3382207",
	scripts = Latn,
}

m["pie"] = {
	"Piro",
	"Q7198055",
	"nai-kta",
	scripts = Latn,
}

m["pif"] = {
	"Pingelapese",
	"Q36421",
	"poz-mic",
	scripts = Latn,
}

m["pig"] = {
	"Pisabo",
	"Q966883",
	"sai-pan",
	scripts = Latn,
}

m["pih"] = {
	"Pitcairn-Norfolk",
	"Q36554",
	"crp",
	otherNames = {"Pitkern-Norfuk", "Pitcairn", "Pitkern", "Norfolk", "Norfuk"},
	scripts = Latn,
}

m["pii"] = {
	"Pini",
	"Q10631925",
}

m["pij"] = {
	"Pijao",
	"Q7193519",
}

m["pil"] = {
	"Yom",
	"Q36893",
}

m["pim"] = {
	"Powhatan",
	"Q2270532",
	"alg",
	scripts = Latn,
}

m["pin"] = {
	"Piame",
	"Q7190042",
}

m["pio"] = {
	"Piapoco",
	"Q3382208",
	"awd-nwk",
	scripts = Latn,
}

m["pip"] = {
	"Pero",
	"Q2411063",
}

m["pir"] = {
	"Piratapuyo",
	"Q3389119",
	"sai-tuc",
	scripts = Latn,
}

m["pis"] = {
	"Pijin",
	"Q36699",
	"crp",
	otherNames = {"Kanaka", "Neo-Solomonic", "Solomons Pidgin"},
	scripts = Latn,
	ancestors = {"en"},
}

m["pit"] = {
	"Pitta-Pitta",
	"Q6433116",
	"aus-kar",
	otherNames = {"Pitta Pitta"},
	scripts = Latn,
}

m["piu"] = {
	"Pintupi-Luritja",
	"Q2591175",
}

m["piv"] = {
	"Pileni",
	"Q2976736",
	"poz-pnp",
	otherNames = {"Vaeakau-Taumako"},
	scripts = Latn,
}

m["piw"] = {
	"Pimbwe",
	"Q3894132",
	"bnt",
}

m["pix"] = {
	"Piu",
	"Q7199578",
}

m["piy"] = {
	"Piya-Kwonci",
	"Q3440492",
}

m["piz"] = {
	"Pije",
	"Q3388339",
	"poz-cln",
	scripts = Latn,
}

m["pjt"] = {
	"Pitjantjatjara",
	"Q2982063",
	"aus-pam",
	scripts = {"pjt-Latn"},
}

m["pka"] = {
	"Ardhamagadhi Prakrit",
	"Q2652214",
	"inc",
	scripts = {"Brah", "Deva"},
	translit_module = "Brah-translit",
	ancestors = {"inc-ash"},
}

m["pkb"] = {
	"Kipfokomo",
	"Q7208693",
	scripts = Latn,
}

m["pkc"] = {
	"Baekje",
	"Q4841264",
	scripts = {"Hani"},
}

m["pkg"] = {
	"Pak-Tong",
	"Q3360711",
}

m["pkh"] = {
	"Pankhu",
	"Q7130962",
	"tbq-kuk",
	otherNames = {"Pankho", "Pangkhua", "Pangkho", "Pangkhu", "Panko"},
}

m["pkn"] = {
	"Pakanha",
	"Q954916",
	"aus-pmn",
}

m["pko"] = {
	"Pökoot",
	"Q36323",
	"sdv",
}

m["pkp"] = {
	"Pukapukan",
	"Q36447",
	"poz-pnp",
	scripts = Latn,
}

m["pkr"] = {
	"Attapady Kurumba",
	"Q16835180",
	"dra",
}

m["pks"] = {
	"Pakistan Sign Language",
	"Q22964057",
	"sgn",
	otherNames = {"Pakistani Sign Language"},
}

m["pkt"] = {
	"Maleng",
	"Q6583562",
	"mkh-vie",
}

m["pku"] = {
	"Paku",
	"Q2932604",
}

m["pla"] = {
	"Miani",
	"Q12952844",
	scripts = Latn,
}

m["plb"] = {
	"Polonombauk",
	"Q7225957",
	"poz-vnc",
	scripts = Latn,
}

m["plc"] = {
	"Central Palawano",
	"Q12953795",
	"phi",
	scripts = Latn,
}

m["ple"] = {
	"Palu'e",
	"Q2196866",
	"poz-cet",
	scripts = Latn,
}

m["plg"] = {
	"Pilagá",
	"Q2748259",
	"sai-guc",
	otherNames = {"Pilacá"},
	scripts = Latn,
}

m["plh"] = {
	"Paulohi",
	"Q7155331",
	"poz",
}

m["plj"] = {
	"Polci",
	"Q3914383",
}

m["plk"] = {
	"Kohistani Shina",
	"Q12953882",
}

m["pll"] = {
	"Shwe Palaung",
	"Q27941664",
	"aav",
}

m["pln"] = {
	"Palenquero",
	"Q36665",
	"crp",
	scripts = Latn,
}

m["plo"] = {
	"Oluta Popoluca",
	"Q5908687",
	scripts = Latn,
}

m["plp"] = {
	"Palpa",
	"Q3832956",
	"inc-pah",
	ancestors = {"ne"},
}

m["plq"] = {
	"Palaic",
	"Q36582",
	"ine-ana",
	scripts = {"Xsux"},
}

m["plr"] = {
	"Palaka Senoufo",
	"Q36346",
	scripts = Latn,
}

m["pls"] = {
	"San Marcos Tlalcoyalco Popoloca",
	"Q12641692",
	"omq-pop",
	scripts = Latn,
}

m["plu"] = {
	"Palikur",
	"Q3073448",
	"awd",
	otherNames = {"Palikúr"},
	scripts = Latn,
}

m["plv"] = {
	"Southwest Palawano",
	"Q15614922",
	"phi",
	scripts = Latn,
}

m["plw"] = {
	"Brooke's Point Palawano",
	"Q12953796",
	"phi",
	scripts = Latn,
}

m["ply"] = {
	"Bolyu",
	"Q3361723",
	"mkh",
	scripts = Latn,
}

m["plz"] = {
	"Paluan",
	"Q7128795",
	scripts = Latn,
}

m["pma"] = {
	"Paama",
	"Q3130286",
	"poz-vnc",
	scripts = Latn,
}

m["pmb"] = {
	"Pambia",
	"Q36267",
	"znd",
	scripts = Latn,
}

m["pmd"] = {
	"Pallanganmiddang",
	"Q7127734",
	"aus-pam",
	scripts = Latn,
}

m["pme"] = {
	"Pwaamei",
	"Q3411152",
	"poz-cln",
	scripts = Latn,
}

m["pmf"] = {
	"Pamona",
	"Q3513320",
	otherNames = {"Bare'e"},
	scripts = Latn,
}

m["pmh"] = {
	"Maharastri Prakrit",
	"Q2586773",
	"inc",
	otherNames = {"Maharashtri Prakrit", "Maharastri", "Maharashtri"},
	scripts = {"Brah", "Deva"},
	ancestors = {"inc-ash"},
	translit_module = "Brah-translit",
}

m["pmi"] = {
	"Northern Pumi",
	"Q3403245",
	"sit-qia",
	otherNames = {"Northern Prinmi", "Northern Pimi"},
}

m["pmj"] = {
	"Southern Pumi",
	"Q3403246",
	"sit-qia",
	otherNames = {"Southern Prinmi", "Southern Pimi"},
}

m["pmk"] = {
	"Pamlico",
	nil,
	scripts = Latn,
}

m["pml"] = {
	"Sabir",
	"Q636479",
	"crp",
	otherNames = {"Mediterranean Lingua Franca", "Lingua Franca"},
	scripts = Latn,
}

m["pmm"] = {
	"Pol",
	"Q36408",
	"bnt",
	otherNames = {"Pol Pomo", "Pomo"},
	scripts = Latn,
}

m["pmn"] = {
	"Pam",
	"Q7129017",
}

m["pmo"] = {
	"Pom",
	"Q7227178",
	"poz-hce",
	scripts = Latn,
}

m["pmq"] = {
	"Northern Pame",
	"Q3361762",
	"omq",
	scripts = Latn,
}

m["pmr"] = {
	"Paynamar",
	"Q3450824",
}

m["pms"] = {
	"Piedmontese",
	"Q15085",
	"roa",
	scripts = Latn,
}

m["pmt"] = {
	"Tuamotuan",
	"Q36763",
	"poz-pep",
	scripts = Latn,
}

m["pmu"] = {
	"Mirpur Panjabi",
	"Q6874480",
}

m["pmw"] = {
	"Plains Miwok",
	"Q3391031",
	"nai-you",
	scripts = Latn,
}

m["pmx"] = {
	"Poumei Naga",
	"Q12952910",
}

m["pmy"] = {
	"Papuan Malay",
	"Q12473446",
	scripts = Latn,
}

m["pmz"] = {
	"Southern Pame",
	"Q3361765",
	"omq",
	scripts = Latn,
}

m["pna"] = {
	"Punan Bah-Biau",
	"Q4842201",
}

m["pnb"] = {
	"Western Panjabi",
	"Q58635",
	"inc",
	scripts = {"pa-Arab"},
	ancestors = {"pa"},
}

m["pnc"] = {
	"Pannei",
	"Q7131391",
}

m["pne"] = {
	"Western Penan",
	"Q12953808",
	"poz-swa",
	scripts = Latn,
}

m["png"] = {
	"Pongu",
	"Q36282",
}

m["pnh"] = {
	"Penrhyn",
	"Q3130301",
	"poz-pep",
	otherNames = {"Tongareva", "Tongarewa"},
	scripts = Latn,
}

m["pni"] = {
	"Aoheng",
	"Q4778608",
	"poz",
}

m["pnj"] = {
	"Pinjarup",
	"Q33103591",
}

m["pnk"] = {
	"Paunaca",
	"Q2064378",
	"awd",
	otherNames = {"Pauna", "Paunaka"},
	scripts = Latn,
}

m["pnl"] = {
	"Paleni",
	"Q7127118",
	"alv",
	scripts = Latn,
}

m["pnm"] = {
	"Punan Batu",
	"Q7259892",
}

m["pnn"] = {
	"Pinai-Hagahai",
	"Q5638511",
}

m["pno"] = {
	"Panobo",
	"Q3141869",
	"sai-pan",
	scripts = Latn,
}

m["pnp"] = {
	"Pancana",
	"Q7130204",
}

m["pnq"] = {
	"Pana (West Africa)",
	"Q7129739",
	otherNames = {"Pana (Burkina Faso)", "Pana"},
	scripts = Latn,
}

m["pnr"] = {
	"Panim",
	"Q11732562",
	"ngf-mad",
}

m["pns"] = {
	"Ponosakan",
	"Q7227956",
	"phi",
}

m["pnt"] = {
	"Pontic Greek",
	"Q36748",
	"grk",
	otherNames = {"Pontic"},
	scripts = {"Grek", "Latn", "Cyrl"},
	ancestors = {"grc"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, grc, cpg
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
}

m["pnu"] = {
	"Jiongnai Bunu",
	"Q56325",
	"hmn",
	otherNames = {"Kiong Nai"},
}

m["pnv"] = {
	"Pinigura",
	"Q10631927",
	"aus-psw",
	scripts = Latn,
}

m["pnw"] = {
	"Panyjima",
	"Q3913830",
	"aus-nga",
	scripts = Latn,
}

m["pnx"] = {
	"Phong-Kniang",
	"Q3914627",
	"mkh",
}

m["pny"] = {
	"Pinyin",
	"Q36250",
	"nic-grf",
	scripts = Latn,
}

m["pnz"] = {
	"Pana (Central Africa)",
	"Q36241",
	"alv",
	otherNames = {"Pana (Central African Republic)", "Pana"},
	scripts = Latn,
}

m["poc"] = {
	"Poqomam",
	"Q36416",
	scripts = Latn,
}

m["poe"] = {
	"San Juan Atzingo Popoloca",
	"Q12953819",
	"omq-pop",
	scripts = Latn,
}

m["pof"] = {
	"Poke",
	"Q7208577",
}

m["pog"] = {
	"Potiguára",
	"Q56722",
	"tup-gua",
	scripts = Latn,
}

m["poh"] = {
	"Poqomchi'",
	"Q36414",
	scripts = Latn,
}

m["poi"] = {
	"Highland Popoluca",
	"Q7511556",
	"nai-miz",
	scripts = Latn,
}

m["pok"] = {
	"Pokangá",
	"Q25559704",
	"sai-tuc",
	scripts = Latn,
}

m["pom"] = {
	"Southeastern Pomo",
	"Q3396025",
	"nai-pom",
	scripts = Latn,
}

m["pon"] = {
	"Pohnpeian",
	"Q28422",
	"poz-mic",
	scripts = Latn,
}

m["poo"] = {
	"Central Pomo",
	"Q3396020",
	"nai-pom",
	scripts = Latn,
}

m["pop"] = {
	"Pwapwa",
	"Q3411153",
	"poz-cln",
	scripts = Latn,
}

m["poq"] = {
	"Texistepec Popoluca",
	"Q5908707",
	scripts = Latn,
}

m["pos"] = {
	"Sayula Popoluca",
	"Q5908722",
	"nai-miz",
	scripts = Latn,
}

m["pot"] = {
	"Potawatomi",
	"Q56749",
	"alg",
	otherNames = {"Pottawatomie"},
	scripts = Latn,
}

m["pov"] = {
	"Guinea-Bissau Creole",
	"Q33339",
	"crp",
	otherNames = {"Upper Guinea Creole", "Upper Guinea Crioulo", "Kriol", "Crioulo", "Kriolu", "Kriyol", "Kiriol"},
	scripts = Latn,
}

m["pow"] = {
	"San Felipe Otlaltepec Popoloca",
	"Q25559598",
	"omq-pop",
	scripts = Latn,
}

m["pox"] = {
	"Polabian",
	"Q36741",
	"zlw",
	scripts = Latn,
}

m["poy"] = {
	"Pogolo",
	"Q2429648",
}

m["ppa"] = {
	"Pao",
	"Q7132069",
}

m["ppe"] = {
	"Papi",
	"Q7132809",
}

m["ppi"] = {
	"Paipai",
	"Q56726",
	"nai-yuc",
	otherNames = {"Akwa'ala"},
	scripts = Latn,
}

m["ppk"] = {
	"Uma",
	"Q7881036",
	"poz-kal",
	scripts = Latn,
}

m["ppl"] = {
	"Pipil",
	"Q1186896",
	"azc-nah",
	otherNames = {"Nahuat", "Náhuat", "Nawat", "Náwat"},
	scripts = Latn,
	ancestors = {"nah"},
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}
	},
}

m["ppm"] = {
	"Papuma",
	"Q7133239",
	"poz-hce",
	scripts = Latn,
}

m["ppn"] = {
	"Papapana",
	"Q3362757",
	"poz-ocw",
	scripts = Latn,
}

m["ppo"] = {
	"Folopa",
	"Q5464843",
	otherNames = {"Podopa", "Polopa", "Podoba", "Foraba", "Tebera", "Boro", "Suri", "Sopese"},
	scripts = Latn,
}

m["ppp"] = {
	"Pelende",
	"Q11029738",
}

m["ppq"] = {
	"Pei",
	"Q7160903",
}

m["pps"] = {
	"San Luís Temalacayuca Popoloca",
	"Q25559602",
	"omq-pop",
	scripts = Latn,
}

m["ppt"] = {
	"Pa",
	"Q3504757",
	"ngf",
	otherNames = {"Pari", "Pare", "Akium-Pare"},
	scripts = Latn,
}

m["ppu"] = {
	"Papora",
	"Q2094884",
	"map",
	otherNames = {"Hoanya", "Papola", "Paporan", "Bupuran", "Vupuran", "Hinapavosa"},
	scripts = Latn,
}

m["pqa"] = {
	"Pa'a",
	"Q3441315",
	"cdc-wst",
}

m["pqm"] = {
	"Malecite-Passamaquoddy",
	"Q3183144",
	"alg",
	otherNames = {"Malecite", "Maliseet", "Passamaquoddy"},
	scripts = Latn,
}

m["prc"] = {
	"Parachi",
	"Q2640637",
	"ira-eas",
}

-- "prd" IS NOT INCLUDED, SEE WT:LT

m["pre"] = {
	"Principense",
	"Q36520",
	"crp",
	scripts = Latn,
}

m["prf"] = {
	"Paranan",
	"Q7135433",
	"phi",
}

m["prg"] = {
	"Old Prussian",
	"Q35501",
	"bat",
	otherNames = {"Prussian"},
	scripts = Latn,
}

m["prh"] = {
	"Porohanon",
	"Q6583710",
	"phi",
}

m["pri"] = {
	"Paicî",
	"Q732131",
	"poz-cln",
	scripts = Latn,
}

m["prk"] = {
	"Parauk",
	"Q3363719",
	"aav",
}

m["prl"] = {
	"Peruvian Sign Language",
	"Q3915508",
	"sgn",
}

m["prm"] = {
	"Kibiri",
	"Q56745",
}

m["prn"] = {
	"Prasuni",
	"Q32689",
	"iir-nur",
}

m["pro"] = {
	"Old Occitan",
	"Q2779185",
	"roa",
	otherNames = {"Old Provençal", "Old Provencal"},
	scripts = Latn,
	sort_key = {
		from = {"ç"},
		to   = {"c"}} ,
}

-- "prp" IS NOT INCLUDED, SEE WT:LT

m["prq"] = {
	"Ashéninka Perené",
	"Q3450601",
	"awd",
	scripts = Latn,
}

m["prr"] = {
	"Puri",
	"Q7261687",
}

-- "prs" IS TREATED AS "fa" (or as etymology-only), SEE WT:LT

m["prt"] = {
	"Phai",
	"Q7180184",
	"mkh",
	otherNames = {"Prai", "Pray", "Phray"},
}

m["pru"] = {
	"Puragi",
	"Q7260800",
	"ngf-sbh",
}

m["prw"] = {
	"Parawen",
	"Q7136291",
}

m["prx"] = {
	"Purik",
	"Q567905",
}

m["prz"] = {
	"Providencia Sign Language",
	"Q3322084",
	"sgn",
	otherNames = {"Providence Island Sign Language"},
}

m["psa"] = {
	"Asue Awyu",
	"Q11266334",
	otherNames = {"Pisa"},
}

m["psc"] = {
	"Persian Sign Language",
	"Q7170221",
	"sgn",
}

m["psd"] = {
	"Plains Indian Sign Language",
	"Q2380124",
	"sgn",
}

m["pse"] = {
	"Central Malay",
	"Q3367751",
	"poz-mly",
}

m["psg"] = {
	"Penang Sign Language",
	"Q4924925",
	"sgn",
}

m["psh"] = {
	"Southwest Pashayi",
	"Q16112270",
	"inc-dar",
}

m["psi"] = {
	"Southeast Pashayi",
	"Q23713536",
	"inc-dar",
	otherNames = {"Southeastern Pashayi","Southeastern Pashai", "Southeast Pashai"},
	scripts = {"Arab"},
}

m["psl"] = {
	"Puerto Rican Sign Language",
	"Q7258608",
	"sgn-fsl",
}

m["psm"] = {
	"Pauserna",
	"Q2912846",
	"tup-gua",
	otherNames = {"Guarasugwé"},
	scripts = Latn,
}

m["psn"] = {
	"Panasuan",
	"Q7130113",
	"poz",
}

m["pso"] = {
	"Polish Sign Language",
	"Q3915194",
	"sgn-gsl",
}

m["psp"] = {
	"Philippine Sign Language",
	"Q3551357",
	"sgn-fsl",
}

m["psq"] = {
	"Pasi",
	"Q7142091",
}

m["psr"] = {
	"Portuguese Sign Language",
	"Q3915472",
	"sgn",
}

m["pss"] = {
	"Kaulong",
	"Q3194294",
	"poz-ocw",
}

m["psu"] = {
	"Sauraseni Prakrit",
	"Q2452885",
	"inc",
	otherNames = {"Sauraseni", "Shauraseni"},
	scripts = {"Deva", "Brah"},
	translit_module = "Brah-translit",
	ancestors = {"inc-ash"},
}

m["psw"] = {
	"Port Sandwich",
	"Q3398324",
	"poz-vnc",
	scripts = Latn,
}

m["psy"] = {
	"Piscataway",
	"Q3504233",
}

m["pta"] = {
	"Pai Tavytera",
	"Q7124619",
	"tup-gua",
	scripts = Latn,
}

m["pth"] = {
	"Pataxó Hã-Ha-Hãe",
	"Q7144304",
}

m["pti"] = {
	"Pintiini",
	"Q10632026",
	"aus-pam",
}

m["ptn"] = {
	"Patani",
	"Q7144242",
	"poz-hce",
	scripts = Latn,
}

m["pto"] = {
	"Zo'é",
	"Q8073148",
	"tup-gua",
	otherNames = {"Jo'é"},
	scripts = Latn,
}

m["ptp"] = {
	"Patep",
	"Q3368679",
	"poz-ocw",
	scripts = Latn,
}

m["ptq"] = {
	"Pattapu",
	nil,
	"dra",
}

m["ptr"] = {
	"Piamatsina",
	"Q7190040",
	"poz-vnc",
	scripts = Latn,
}

m["ptt"] = {
	"Enrekang",
	"Q12953520",
}

m["ptu"] = {
	"Bambam",
	"Q4853321",
	"poz-ssw",
}

m["ptv"] = {
	"Port Vato",
	"Q3398323",
	scripts = Latn,
}

m["ptw"] = {
	"Pentlatch",
	"Q2069475",
}

m["pty"] = {
	"Pathiya",
	"Q7144790",
	"dra",
}

m["pua"] = {
	"Purepecha",
	"Q16114351",
	"qfa-iso",
	otherNames = {"Tarascan", "Tarasco", "P'urhepecha", "Purépecha", "P'urhépecha", "Phorhépecha", "Phorhé", "Porhé"},
	scripts = Latn,
}

m["pub"] = {
	"Purum",
	"Q6400562",
	"tbq-kuk",
	otherNames = {"Purum Naga"},
	scripts = Latn,
}

m["puc"] = {
	"Punan Merap",
	"Q7259895",
}

m["pud"] = {
	"Punan Aput",
	"Q4782333",
}

m["pue"] = {
	"Puelche",
	"Q33660",
}

m["puf"] = {
	"Punan Merah",
	"Q7259894",
}

m["pug"] = {
	"Phuie",
	"Q36375",
}

m["pui"] = {
	"Puinave",
	"Q3027918",
	otherNames = {"Puinabe", "Wãnsöhöt", "Guipunave", "Güipunave", "Waipunavi", "Guaipunabi"},
}

m["puj"] = {
	"Punan Tubu",
	"Q7259896",
	"poz-swa",
}

m["pum"] = {
	"Puma",
	"Q33736",
}

m["puo"] = {
	"Puoc",
	"Q6440803",
	"mkh",
}

m["pup"] = {
	"Pulabu",
	"Q7259163",
	"ngf-mad",
}

m["puq"] = {
	"Puquina",
	"Q1207739",
}

m["pur"] = {
	"Puruborá",
	"Q7261619",
	"tup",
	otherNames = {"Aurã", "Cujubim", "Burubora", "Kuyubi", "Migueleno", "Miguelenho", "Pumbora", "Puroborá", "Puruba"},
}

m["put"] = {
	"Putoh",
	"Q12953832",
	"poz-swa",
	scripts = Latn,
}

m["puu"] = {
	"Punu",
	"Q36401",
	"bnt",
	scripts = Latn,
}

m["puw"] = {
	"Puluwat",
	"Q36397",
	"poz-mic",
	otherNames = {"Puluwatese"},
	scripts = Latn,
}

m["pux"] = {
	"Puare",
	"Q3507983",
}

m["puy"] = {
	"Purisimeño",
	"Q2967638",
	"nai-chu",
	scripts = Latn,
}

m["pwa"] = {
	"Pawaia",
	"Q7156099",
	scripts = Latn,
}

m["pwb"] = {
	"Panawa",
	"Q47385077",
	"nic-bco",
	scripts = Latn,
}

m["pwg"] = {
	"Gapapaiwa",
	"Q3095245",
	"poz-ocw",
	scripts = Latn,
}

m["pwi"] = {
	"Patwin",
	"Q3370188",
	"nai-wtq",
	otherNames = {"River Patwin", "Valley Patwin", "Hill Patwin", "Southern Patwin"},
	scripts = Latn,
}

m["pwm"] = {
	"Molbog",
	"Q6895718",
	"poz-san",
	scripts = Latn,
}

m["pwn"] = {
	"Paiwan",
	"Q715755",
	"map",
	scripts = Latn,
}

m["pwo"] = {
	"Western Pwo",
	"Q7988202",
	"kar",
	otherNames = {"Delta Pwo", "Pwo Western Karen"},
	scripts = {"Mymr"},
}

m["pwr"] = {
	"Powari",
	"Q12640277",
	"inc",
	scripts = {"Deva"},
	ancestors = {"psu"},
}

m["pww"] = {
	"Northern Pwo",
	"Q7058885",
	"kar",
	otherNames = {"Phlong", "Pwo Northern Karen"},
	scripts = {"Thai"},
}

m["pxm"] = {
	"Quetzaltepec Mixe",
	"Q6842374",
	"nai-miz",
	scripts = Latn,
}

m["pye"] = {
	"Pye Krumen",
	"Q11157382",
}

m["pym"] = {
	"Fyam",
	"Q3914025",
	"nic-bco",
	otherNames = {"Fyem", "Pyem"},
	scripts = Latn,
}

m["pyn"] = {
	"Poyanáwa",
	"Q3401023",
	"sai-pan",
	otherNames = {"Poyanawa"},
}

m["pys"] = {
	"Paraguayan Sign Language",
	"Q7134698",
	"sgn",
}

m["pyu"] = {
	"Puyuma",
	"Q716690",
	"map",
	scripts = Latn,
}

m["pyx"] = {
	"Tircul",
	"Q36259",
	"tbq",
	otherNames = {"Pyu"},
}

m["pyy"] = {
	"Pyen",
	"Q7262966",
	"tbq-lol",
	otherNames = {"Hpyin", "Phen"},
}

m["pzn"] = {
	"Para Naga",
	"Q7133667",
}

return m