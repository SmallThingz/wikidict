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

m["maa"] = {
	canonicalName = "San Jerónimo Tecóatl Mazatec",
	scripts = {"Latn"},
	family = "omq-maz",
}

m["mab"] = {
	canonicalName = "Yutanduchi Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mad"] = {
	canonicalName = "Madurese",
	scripts = {"Latn"},
	family = "poz-msa",
}

m["mae"] = {
	canonicalName = "Bo-Rukul",
}

m["maf"] = {
	canonicalName = "Mafa",
}

m["mag"] = {
	canonicalName = "Magahi",
	family = "inc",
	ancestors = {"bh"},
}

m["mai"] = {
	canonicalName = "Maithili",
	scripts = {"Tirh", "Kthi", "Deva"},
	family = "inc",
	ancestors = {"bh"},
}

m["maj"] = {
	canonicalName = "Jalapa De Díaz Mazatec",
	family = "omq-maz",
}

m["mak"] = {
	canonicalName = "Makasar",
	scripts = {"Latn"},
	family = "poz-ssw",
}

m["mam"] = {
	canonicalName = "Mam",
}

m["man"] = {
	canonicalName = "Mandingo",
}

m["maq"] = {
	canonicalName = "Chiquihuitlán Mazatec",
	family = "omq-maz",
}

m["mas"] = {
	canonicalName = "Maasai",
	scripts = {"Latn"},
	family = "sdv",
}

m["mat"] = {
	canonicalName = "Matlatzinca",
	otherNames = {"San Francisco Matlatzinca", "San Francisco Oxtotilpa Matlatzinca"},
	scripts = {"Latn"},
	family = "omq",
}

m["mau"] = {
	canonicalName = "Huautla Mazatec",
	family = "omq-maz",
}

m["mav"] = {
	canonicalName = "Sateré-Mawé",
}

m["maw"] = {
	canonicalName = "Mampruli",
}

m["max"] = {
	canonicalName = "North Moluccan Malay",
}

m["maz"] = {
	canonicalName = "Central Mazahua",
}

m["mba"] = {
	canonicalName = "Higaonon",
	family = "poz-hce",
}

m["mbb"] = {
	canonicalName = "Western Bukidnon Manobo",
}

m["mbc"] = {
	canonicalName = "Macushi",
	otherNames = {"Makushi", "Makusi", "Makuxi", "Macusi", "Macussi", "Teweya"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["mbd"] = {
	canonicalName = "Dibabawon Manobo",
}

m["mbe"] = {
	canonicalName = "Molale",
}

m["mbf"] = {
	canonicalName = "Baba Malay",
}

m["mbh"] = {
	canonicalName = "Mangseng",
	family = "poz-ocw",
}

m["mbi"] = {
	canonicalName = "Ilianen Manobo",
}

m["mbj"] = {
	canonicalName = "Nadëb",
}

m["mbk"] = {
	canonicalName = "Malol",
	family = "poz-ocw",
}

m["mbl"] = {
	canonicalName = "Maxakalí",
}

m["mbm"] = {
	canonicalName = "Ombamba",
}

m["mbn"] = {
	canonicalName = "Macaguán",
}

m["mbo"] = { -- is, like 'bqz', 'bsi' and 'bss', a dialect of Manenguba
	canonicalName = "Mbo (Cameroon)",
	otherNames = {"Mbo"},
	family = "bnt",
}

m["mbp"] = {
	canonicalName = "Wiwa",
	otherNames = {"Damana", "Malayo"},
	scripts = {"Latn"},
}

m["mbq"] = {
	canonicalName = "Maisin",
}

m["mbr"] = {
	canonicalName = "Nukak Makú",
}

m["mbs"] = {
	canonicalName = "Sarangani Manobo",
}

m["mbt"] = {
	canonicalName = "Matigsalug Manobo",
}

m["mbu"] = {
	canonicalName = "Mbula-Bwazza",
}

m["mbv"] = {
	canonicalName = "Mbulungish",
	family = "alv-sng",
}

m["mbw"] = {
	canonicalName = "Maring",
}

m["mbx"] = {
	canonicalName = "Sepik Mari",
	otherNames = {"Mari (East Sepik Province)"},
	family = "paa-spk",
}

m["mby"] = {
	canonicalName = "Memoni",
}

m["mbz"] = {
	canonicalName = "Amoltepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mca"] = {
	canonicalName = "Maca",
	scripts = {"Latn"},
	family = "sai-mtc",
}

m["mcb"] = {
	canonicalName = "Machiguenga",
	family = "awd",
}

m["mcc"] = {
	canonicalName = "Bitur",
}

m["mcd"] = {
	canonicalName = "Sharanahua",
	family = "sai-pan",
}

m["mce"] = {
	canonicalName = "Itundujia Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mcf"] = {
	canonicalName = "Matsés",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["mcg"] = {
	canonicalName = "Mapoyo",
	family = "sai-car",
}

m["mch"] = {
	canonicalName = "Maquiritari",
	otherNames = {"Makiritare", "Ye'kwana", "Ye'kuana", "Yekuana", "De'kwana", "So'to", "Maiongong"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["mci"] = {
	canonicalName = "Mese",
}

m["mcj"] = {
	canonicalName = "Mvanip",
	family = "nic-bod",
}

m["mck"] = {
	canonicalName = "Mbunda",
}

m["mcl"] = {
	canonicalName = "Macaguaje",
	family = "sai-tuc",
}

m["mcm"] = {
	canonicalName = "Kristang",
	otherNames = {"Malacca Creole Portuguese", "Malaccan Creole Portuguese"},
	scripts = {"Latn"},
	family = "crp",
}

m["mcn"] = {
	canonicalName = "Masana",
	otherNames = {"Massa", "Masa"},
	family = "cdc-mas",
}

m["mco"] = {
	canonicalName = "Coatlán Mixe",
	scripts = {"Latn"},
	family = "nai-miz",
}

m["mcp"] = {
	canonicalName = "Makaa",
}

m["mcq"] = {
	canonicalName = "Ese",
}

m["mcr"] = {
	canonicalName = "Menya",
}

m["mcs"] = {
	canonicalName = "Mambai",
}

m["mct"] = {
	canonicalName = "Mengisa",
}

m["mcu"] = {
	canonicalName = "Cameroon Mambila",
	family = "nic-bod",
}

m["mcv"] = {
	canonicalName = "Minanibai",
}

m["mcw"] = {
	canonicalName = "Mahwa",
	otherNames = {"Mawa (Chad)", "Mawa"},
	scripts = {"Latn"},
	family = "cdc-est",
}

m["mcx"] = {
	canonicalName = "Mpiemo",
}

m["mcy"] = {
	canonicalName = "South Watut",
	family = "poz-ocw",
}

m["mcz"] = {
	canonicalName = "Mawan",
}

m["mda"] = {
	canonicalName = "Mada (Nigeria)",
	otherNames = {"Mada"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["mdb"] = {
	canonicalName = "Morigi",
}

m["mdc"] = {
	canonicalName = "Male",
}

m["mdd"] = {
	canonicalName = "Mbum",
}

m["mde"] = {
	canonicalName = "Bura Mabang",
	family = "ssa",
}

m["mdf"] = {
	canonicalName = "Moksha",
	otherNames = {"Mordvin"},
	scripts = {"Cyrl"},
	family = "fiu-mdv",
	translit_module = "mdf-translit",
}

m["mdg"] = {
	canonicalName = "Massalat",
}

m["mdh"] = {
	canonicalName = "Maguindanao",
}

m["mdi"] = {
	canonicalName = "Mamvu",
}

m["mdj"] = {
	canonicalName = "Mangbetu",
}

m["mdk"] = {
	canonicalName = "Mangbutu",
}

m["mdl"] = {
	canonicalName = "Maltese Sign Language",
	family = "sgn",
}

m["mdm"] = {
	canonicalName = "Mayogo",
	family = "nic-ubg",
}

m["mdn"] = {
	canonicalName = "Mbati",
}

m["mdp"] = {
	canonicalName = "Mbala",
}

m["mdq"] = {
	canonicalName = "Mbole",
}

m["mdr"] = {
	canonicalName = "Mandar",
	scripts = {"Bugi"},
	family = "poz-ssw",
}

m["mds"] = {
	canonicalName = "Maria",
	otherNames = {"Maria (New Guinea)", "Maria (Papua New Guinea)"},
}

m["mdt"] = {
	canonicalName = "Mbere",
}

m["mdu"] = {
	canonicalName = "Mboko",
}

m["mdv"] = {
	canonicalName = "Santa Lucía Monteverde Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mdw"] = {
	canonicalName = "Mbosi",
}

m["mdx"] = {
	canonicalName = "Dizin",
}

m["mdy"] = {
	canonicalName = "Maale",
}

m["mdz"] = {
	canonicalName = "Suruí Do Pará",
}

m["mea"] = {
	canonicalName = "Menka",
	family = "nic-bod",
}

m["meb"] = {
	canonicalName = "Ikobi-Mena",
}

m["mec"] = {
	canonicalName = "Mara",
	otherNames = {"Leelawarra", "Leelalwarra", "Mala", "Marra"},
}

m["med"] = {
	canonicalName = "Melpa",
}

m["mee"] = {
	canonicalName = "Mengen",
	family = "poz-ocw",
}

m["mef"] = {
	canonicalName = "Megam",
}

m["meg"] = {
	canonicalName = "Mea",
	family = "poz-cln",
}

m["meh"] = {
	canonicalName = "Southwestern Tlaxiaco Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mei"] = {
	canonicalName = "Midob",
	scripts = {"Latn"},
	family = "nub",
}

m["mej"] = {
	canonicalName = "Meyah",
	otherNames = {"Mejah",  "Meax"},
}

m["mek"] = {
	canonicalName = "Mekeo",
	family = "poz-ocw",
}

m["mel"] = {
	canonicalName = "Central Melanau",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["mem"] = {
	canonicalName = "Mangala",
}

m["men"] = {
	canonicalName = "Mende",
	scripts = {"Latn", "Mend"},
	family = "dmn",
}

m["meo"] = {
	canonicalName = "Kedah Malay",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["mep"] = {
	canonicalName = "Miriwung",
}

m["meq"] = {
	canonicalName = "Merey",
}

m["mer"] = {
	canonicalName = "Meru",
	scripts = {"Latn"},
	family = "bnt",
}

m["mes"] = {
	canonicalName = "Masmaje",
}

m["met"] = {
	canonicalName = "Mato",
	otherNames = {"Nenaya", "Nengaya", "Nineia"},
	scripts = {"Latn"},
}

m["meu"] = {
	canonicalName = "Motu",
	otherNames = {"Pure Motu", "True Motu"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["mev"] = {
	canonicalName = "Mano",
}

m["mew"] = {
	canonicalName = "Maaka",
	family = "cdc-wst",
}

m["mey"] = {
	canonicalName = "Hassaniya",
	scripts = {"Arab"},
	family = "sem-arb",
}

m["mez"] = {
	canonicalName = "Menominee",
	scripts = {"Latn"},
	family = "alg",
	sort_key = {
		from = {"·"},
		to   = {""}} ,
}

m["mfa"] = {
	canonicalName = "Pattani Malay",
	scripts = {"Latn", "Thai", "Arab"},
	family = "poz-mly",
}

m["mfb"] = {
	canonicalName = "Bangka",
}

m["mfc"] = {
	canonicalName = "Mba",
	family = "nic-ubg",
}

m["mfd"] = {
	canonicalName = "Mendankwe-Nkwen",
	family = "nic-bod",
}

m["mfe"] = {
	canonicalName = "Mauritian Creole",
	otherNames = {"Mauritian"},
	scripts = {"Latn"},
	family = "crp",
}

m["mff"] = {
	canonicalName = "Naki",
	otherNames = {"Bukwen", "Mashi"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["mfg"] = {
	canonicalName = "Mixifore",
	otherNames = {"Mogofin"},
	family = "dmn",
}

m["mfh"] = {
	canonicalName = "Matal",
}

m["mfi"] = {
	canonicalName = "Wandala",
	otherNames = {"Mandara"},
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["mfj"] = {
	canonicalName = "Mefele",
}

m["mfk"] = {
	canonicalName = "North Mofu",
}

m["mfl"] = {
	canonicalName = "Putai",
}

m["mfm"] = {
	canonicalName = "Marghi South",
}

m["mfn"] = {
	canonicalName = "Cross River Mbembe",
	family = "nic-bco",
}

m["mfo"] = {
	canonicalName = "Mbe",
	family = "nic-bod",
}

m["mfp"] = {
	canonicalName = "Makassar Malay",
}

m["mfq"] = {
	canonicalName = "Moba",
}

m["mfr"] = {
	canonicalName = "Marrithiyel",
}

m["mfs"] = {
	canonicalName = "Mexican Sign Language",
	family = "sgn",
}

m["mft"] = {
	canonicalName = "Mokerang",
	family = "poz-aay",
}

m["mfu"] = {
	canonicalName = "Mbwela",
}

m["mfv"] = {
	canonicalName = "Mandjak",
}

m["mfw"] = {
	canonicalName = "Mulaha",
}

m["mfx"] = {
	canonicalName = "Melo",
}

m["mfy"] = {
	canonicalName = "Mayo",
	scripts = {"Latn"},
	family = "azc-trc",
}

m["mfz"] = {
	canonicalName = "Mabaan",
	family = "sdv",
}

m["mga"] = {
	canonicalName = "Middle Irish",
	scripts = {"Latn"},
	family = "cel-gae",
	ancestors = {"sga"},
	entry_name = {
		from = {"ḟ", "ṡ", "ä", "ë", "ï", "ö", "ü", "·"},
		to   = {"f", "s", "a", "e", "i", "o", "u"}} ,
	sort_key = {
		from = {"á", "é", "æ", "ǽ", "í", "ó", "ú", "^h"},
		to   = {"a", "e", "e", "e", "i", "o", "u"}} ,
}

m["mgb"] = {
	canonicalName = "Mararit",
}

m["mgc"] = {
	canonicalName = "Morokodo",
}

m["mgd"] = {
	canonicalName = "Moru",
}

m["mge"] = {
	canonicalName = "Mango",
}

m["mgf"] = {
	canonicalName = "Maklew",
}

m["mgg"] = {
	canonicalName = "Mpongmpong",
}

m["mgh"] = {
	canonicalName = "Makhuwa-Meetto",
	scripts = {"Latn"},
	family = "bnt",
}

m["mgi"] = {
	canonicalName = "Lijili",
}

m["mgj"] = {
	canonicalName = "Abureni",
	family = "nic-bco",
}

m["mgk"] = {
	canonicalName = "Mawes",
}

m["mgl"] = {
	canonicalName = "Maleu-Kilenge",
}

m["mgm"] = {
	canonicalName = "Mambae",
	family = "plf",
}

m["mgn"] = {
	canonicalName = "Mbangi",
	family = "nic-ubg",
}

m["mgo"] = {
	canonicalName = "Meta'",
	family = "nic-bod",
}

m["mgp"] = {
	canonicalName = "Eastern Magar",
}

m["mgq"] = {
	canonicalName = "Malila",
}

m["mgr"] = {
	canonicalName = "Mambwe-Lungu",
}

m["mgs"] = {
	canonicalName = "Nyasa",
	otherNames = {"Kimanda", "Kinyasa", "Manda"},
}

m["mgt"] = {
	canonicalName = "Mongol",
	family = "paa",
}

m["mgu"] = {
	canonicalName = "Mailu",
}

m["mgv"] = {
	canonicalName = "Matengo",
}

m["mgw"] = {
	canonicalName = "Matumbi",
	otherNames = {"Matuumbi", "Kimatumbi", "Kimatuumbi"},
}

m["mgx"] = {
	canonicalName = "Omati",
}

m["mgy"] = {
	canonicalName = "Mbunga",
}

m["mgz"] = {
	canonicalName = "Mbugwe",
}

m["mha"] = {
	canonicalName = "Manda",
	family = "dra",
}

m["mhb"] = {
	canonicalName = "Mahongwe",
}

m["mhc"] = {
	canonicalName = "Mocho",
}

m["mhd"] = {
	canonicalName = "Mbugu",
	otherNames = {"Ma'a", "Normal Mbugu", "Inner Mbugu"},
	scripts = {"Latn"},
	family = "qfa-mix",
}

m["mhe"] = {
	canonicalName = "Besisi",
}

m["mhf"] = {
	canonicalName = "Mamaa",
	family = "ngf-fin",
}

m["mhg"] = {
	canonicalName = "Margu",
}

m["mhi"] = {
	canonicalName = "Ma'di",
}

m["mhj"] = {
	canonicalName = "Mogholi",
	otherNames = {"Moghol"},
	family = "xgn",
}

m["mhk"] = {
	canonicalName = "Mungaka",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["mhl"] = {
	canonicalName = "Mauwake",
}

m["mhm"] = {
	canonicalName = "Makhuwa-Moniga",
}

m["mhn"] = {
	canonicalName = "Mòcheno",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"bar"},
}

m["mho"] = {
	canonicalName = "Mashi",
	scripts = {"Latn"},
	family = "bnt",
}

m["mhp"] = {
	canonicalName = "Balinese Malay",
}

m["mhq"] = {
	canonicalName = "Mandan",
	family = "sio",
}

m["mhs"] = {
	canonicalName = "Buru (Indonesia)",
	otherNames = {"Buru"},
	family = "poz",
}

m["mht"] = {
	canonicalName = "Mandahuaca",
	otherNames = {"Mandauaca", "Mandawaka", "Mandawaca", "Mandauaka", "Mandauáka"},
	family = "awd",
}

m["mhu"] = {
	canonicalName = "Taraon",
	otherNames = {"Darang", "Digaro-Mishmi", "Digaro Mishmi"},
	scripts = {"Latn"},
}

m["mhw"] = {
	canonicalName = "Mbukushu",
}

m["mhx"] = {
	canonicalName = "Lhaovo",
	otherNames = {"Lhao Vo", "Maru", "Langsu"},
	family = "sit",
}

m["mhy"] = {
	canonicalName = "Ma'anyan",
}

m["mhz"] = {
	canonicalName = "Austronesian Mor",
	otherNames = {"Mor"},
	scripts = {"Latn"},
	family = "poz-hce",
}

m["mia"] = {
	canonicalName = "Miami",
	scripts = {"Latn"},
	family = "alg",
}

m["mib"] = {
	canonicalName = "Atatláhuca Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mic"] = {
	canonicalName = "Mi'kmaq",
	scripts = {"Latn"},
	family = "alg",
}

m["mid"] = {
	canonicalName = "Mandaic",
	scripts = {"Mand"},
	family = "sem-ara",
	ancestors = {"myz"},
}

m["mie"] = {
	canonicalName = "Ocotepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mif"] = {
	canonicalName = "Mofu-Gudur",
	family = "cdc-cbm",
}

m["mig"] = {
	canonicalName = "San Miguel El Grande Mixtec",
	otherNames = {"Chalcatongo Mixtec"},
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mih"] = {
	canonicalName = "Chayuco Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mii"] = {
	canonicalName = "Chigmecatitlán Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mij"] = {
	canonicalName = "Mungbam",
	otherNames = {"Abar", "Missong", "Munken", "Ngun"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["mik"] = {
	canonicalName = "Mikasuki",
	scripts = {"Latn"},
	family = "nai-mus",
}

m["mil"] = {
	canonicalName = "Peñoles Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mim"] = {
	canonicalName = "Alacatlatzala Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["min"] = {
	canonicalName = "Minangkabau",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["mio"] = {
	canonicalName = "Pinotepa Nacional Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mip"] = {
	canonicalName = "Apasco-Apoala Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["miq"] = {
	canonicalName = "Miskito",
	otherNames = {"Miskitu"},
	scripts = {"Latn"},
	family = "nai-min",
	entry_name = {
		from = {"Â", "â", "Î", "î", "Û", "û"},
		to   = {"A", "a", "I", "i", "U", "u"}},
}

m["mir"] = {
	canonicalName = "Isthmus Mixe",
}

m["mit"] = {
	canonicalName = "Southern Puebla Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["miu"] = {
	canonicalName = "Cacaloxtepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["miw"] = {
	canonicalName = "Akoye",
}

m["mix"] = {
	canonicalName = "Mixtepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["miy"] = {
	canonicalName = "Ayutla Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["miz"] = {
	canonicalName = "Coatzospan Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mjb"] = {
	canonicalName = "Makalero",
	otherNames = {"Maklere"},
	scripts = {"Latn"},
}

m["mjc"] = {
	canonicalName = "San Juan Colorado Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mjd"] = {
	canonicalName = "Northwest Maidu",
	family = "nai-mdu",
}

m["mje"] = {
	canonicalName = "Muskum",
}

m["mjg"] = {
	canonicalName = "Monguor",
	scripts = {"Latn"},
	family = "xgn",
}

m["mjh"] = {
	canonicalName = "Nyanza",
	otherNames = {"Kinyasa", "Mwera", "Nyasa"},
}

m["mji"] = {
	canonicalName = "Kim Mun",
	family = "hmx-mie",
}

m["mjj"] = {
	canonicalName = "Mawak",
}

m["mjk"] = {
	canonicalName = "Matukar",
	family = "poz-ocw",
}

m["mjl"] = {
	canonicalName = "Mandeali",
}

m["mjm"] = {
	canonicalName = "Medebur",
	family = "poz-ocw",
}

m["mjn"] = {
	canonicalName = "Mebu",
	otherNames = {"Ma"},
	family = "ngf-fin",
}

m["mjo"] = {
	canonicalName = "Malankuravan",
	family = "dra",
}

m["mjp"] = {
	canonicalName = "Malapandaram",
	family = "dra",
}

m["mjq"] = {
	canonicalName = "Malaryan",
	family = "dra",
}

m["mjr"] = {
	canonicalName = "Malavedan",
	family = "dra",
}

m["mjs"] = {
	canonicalName = "Miship",
	otherNames = {"Chip"},
	scripts = {"Latn"},
	family = "cdc",
}

m["mjt"] = {
	canonicalName = "Sawriya Paharia",
	otherNames = {"Sauria Paharia", "Sawriya", "Sawriya Pahariya", "Sawriya Malto", "Malto", " Malti", "Maltu", "Maler"},
	scripts = {"Beng", "Deva"},
	family = "dra",
}

m["mju"] = {
	canonicalName = "Manna-Dora",
	family = "dra",
	ancestors = {"te"},
}

m["mjv"] = {
	canonicalName = "Mannan",
	family = "dra",
}

m["mjw"] = {
	canonicalName = "Karbi",
	otherNames = {"Arleng", "Mikir"},
	scripts = {"Latn"},
	family = "tbq",
}

m["mjx"] = {
	canonicalName = "Mahali",
	family = "mun",
}

m["mjy"] = {
	canonicalName = "Mahican",
	scripts = {"Latn"},
	family = "alg",
}

m["mjz"] = {
	canonicalName = "Majhi",
	family = "inc",
	ancestors = {"bh"},
}

m["mka"] = {
	canonicalName = "Mbre",
}

m["mkb"] = {
	canonicalName = "Mal Paharia",
}

m["mkc"] = {
	canonicalName = "Siliput",
	family = "qfa-tor",
}

m["mke"] = {
	canonicalName = "Mawchi",
}

m["mkf"] = {
	canonicalName = "Miya",
}

m["mkg"] = {
	canonicalName = "Mak (China)",
	otherNames = {"Mak"},
	family = "qfa-tak",
}

m["mki"] = {
	canonicalName = "Dhatki",
	family = "inc",
	ancestors = {"mwr"},
}

m["mkj"] = {
	canonicalName = "Mokilese",
	family = "poz-mic",
}

m["mkk"] = {
	canonicalName = "Byep",
}

m["mkl"] = {
	canonicalName = "Mokole",
}

m["mkm"] = {
	canonicalName = "Moklen",
}

m["mkn"] = {
	canonicalName = "Kupang Malay",
}

m["mko"] = {
	canonicalName = "Mingang Doso",
}

m["mkp"] = {
	canonicalName = "Moikodi",
}

m["mkq"] = {
	canonicalName = "Bay Miwok",
	family = "nai-you",
}

m["mkr"] = {
	canonicalName = "Malas",
}

m["mks"] = {
	canonicalName = "Silacayoapan Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mkt"] = {
	canonicalName = "Vamale",
	family = "poz-cln",
}

m["mku"] = {
	canonicalName = "Konyanka Maninka",
}

m["mkv"] = {
	canonicalName = "Mafea",
	family = "poz-vnc",
}

m["mkx"] = {
	canonicalName = "Cinamiguin Manobo",
}

m["mky"] = {
	canonicalName = "East Makian",
	family = "poz-hce",
}

m["mkz"] = {
	canonicalName = "Makasae",
}

m["mla"] = {
	canonicalName = "Malo",
	family = "poz-vnc",
}

m["mlb"] = {
	canonicalName = "Mbule",
	family = "nic-bod",
}

m["mlc"] = {
	canonicalName = "Man Cao Lan",
	family = "tai",
}

m["mle"] = {
	canonicalName = "Manambu",
}

m["mlf"] = {
	canonicalName = "Mal",
	otherNames = {"Thin"},
	family = "aav-khm",
}

m["mlh"] = {
	canonicalName = "Mape",
}

m["mli"] = {
	canonicalName = "Malimpung",
}

m["mlj"] = {
	canonicalName = "Miltu",
}

m["mlk"] = {
	canonicalName = "Ilwana",
}

m["mll"] = {
	canonicalName = "Malua Bay",
	family = "poz-vnc",
}

m["mlm"] = {
	canonicalName = "Mulam",
	scripts = {"Hani"},
	family = "qfa-tak",
}

m["mln"] = {
	canonicalName = "Malango",
	family = "poz-sls",
}

m["mlo"] = {
	canonicalName = "Mlomp",
}

m["mlp"] = {
	canonicalName = "Bargam",
}

m["mlq"] = {
	canonicalName = "Western Maninkakan",
}

m["mlr"] = {
	canonicalName = "Vame",
}

m["mls"] = {
	canonicalName = "Masalit",
}

m["mlu"] = {
	canonicalName = "To'abaita",
	otherNames = {"Toqabaqita"},
	scripts = {"Latn"},
	family = "poz-sls",
}

m["mlv"] = {
	canonicalName = "Mwotlap",
	otherNames = {"Motlav", "Volow"}, -- or Volow could be separated as a language
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["mlw"] = {
	canonicalName = "Moloko",
}

m["mlx"] = {
	canonicalName = "Malfaxal",
	family = "poz-vnc",
}

m["mlz"] = {
	canonicalName = "Malaynon",
}

m["mma"] = {
	canonicalName = "Mama",
}

m["mmb"] = {
	canonicalName = "Momina",
}

m["mmc"] = {
	canonicalName = "Michoacán Mazahua",
}

m["mmd"] = {
	canonicalName = "Maonan",
}

m["mme"] = {
	canonicalName = "Mae",
	family = "poz-vnc",
}

m["mmf"] = {
	canonicalName = "Mundat",
}

m["mmg"] = {
	canonicalName = "North Ambrym",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["mmh"] = {
	canonicalName = "Mehináku",
	family = "awd",
}

m["mmi"] = {
	canonicalName = "Musar",
}

m["mmj"] = {
	canonicalName = "Majhwar",
}

m["mmk"] = {
	canonicalName = "Mukha-Dora",
}

m["mml"] = {
	canonicalName = "Man Met",
	family = "aav",
}

m["mmm"] = {
	canonicalName = "Maii",
	family = "poz-vnc",
}

m["mmn"] = {
	canonicalName = "Mamanwa",
}

m["mmo"] = {
	canonicalName = "Mangga Buang",
	family = "poz-ocw",
}

m["mmp"] = {
	canonicalName = "Musan",
}

m["mmq"] = {
	canonicalName = "Musak",
}

m["mmr"] = {
	canonicalName = "Western Xiangxi Miao",
	family = "hmn",
}

m["mmt"] = {
	canonicalName = "Malalamai",
	family = "poz-ocw",
}

m["mmu"] = {
	canonicalName = "Mmaala",
	family = "nic-bod",
}

m["mmv"] = {
	canonicalName = "Miriti",
	family = "sai-tuc",
}

m["mmw"] = {
	canonicalName = "Emae",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["mmx"] = {
	canonicalName = "Madak",
	family = "poz-ocw",
}

m["mmy"] = {
	canonicalName = "Migaama",
}

m["mmz"] = {
	canonicalName = "Mabaale",
}

m["mna"] = {
	canonicalName = "Mbula",
}

m["mnb"] = {
	canonicalName = "Muna",
}

m["mnc"] = {
	canonicalName = "Manchu",
	scripts = {"Mong"},
	family = "tuw",
}

m["mnd"] = {
	canonicalName = "Mondé",
	otherNames = {"Monde", "Salamãi", "Salamai"},
	scripts = {"Mong"},
	family = "tup",
}

m["mne"] = {
	canonicalName = "Naba",
}

m["mnf"] = {
	canonicalName = "Mundani",
	family = "nic-bod",
}

m["mng"] = {
	canonicalName = "Eastern Mnong",
	family = "aav-ban",
}

m["mnh"] = {
	canonicalName = "Mono (Congo)",
	otherNames = {"Mono (Democratic Republic of the Congo)", "Mono"},
	family = "bad",
}

m["mni"] = {
	canonicalName = "Manipuri",
	otherNames = {"Meitei", "Meithei"},
	scripts = {"Beng", "Mtei"},
	family = "tbq",
	ancestors = {"omp"},
}

m["mnj"] = {
	canonicalName = "Munji",
	otherNames = {"Munjani", "Mundzhan", "Mundzhani", "Mundzi"},
	family = "ira",
}

m["mnk"] = {
	canonicalName = "Mandinka",
	otherNames = {"Mandingo"},
	scripts = {"Latn"},
	family = "dmn",
}

m["mnl"] = {
	canonicalName = "Tiale",
	family = "poz-vnc",
}

m["mnm"] = {
	canonicalName = "Mapena",
}

m["mnn"] = {
	canonicalName = "Southern Mnong",
}

m["mnp"] = {
	canonicalName = "Min Bei",
	family = "zhx",
	ancestors = {"zhx-min-pro"},
}

m["mnq"] = {
	canonicalName = "Minriq",
}

m["mnr"] = {
	canonicalName = "Mono (California)",
	otherNames = {"Mono (United States of America)", "Mono", "Western Mono", "Monache", "Monachi", "Owens Valley Paiute", "Eastern Mono"},
	scripts = {"Latn"},
	family = "azc-num",
}

m["mns"] = {
	canonicalName = "Mansi",
	scripts = {"Cyrl"},
	family = "fiu-ugr",
}

m["mnt"] = {
	canonicalName = "Maykulan",
	otherNames = {"Mayi-Kulan", "Wunumara", "Mayi-Yapi", "Mayi-Thakurti"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["mnu"] = {
	canonicalName = "Mer",
}

m["mnv"] = {
	canonicalName = "Rennellese",
	otherNames = {"Rennell-Bellona"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["mnw"] = {
	canonicalName = "Mon",
	scripts = {"Mymr"},
	family = "mkh",
}

m["mnx"] = {
	canonicalName = "Manikion",
	otherNames = {"Mantion", "Sougb", "Sogh"},
}

m["mny"] = {
	canonicalName = "Manyawa",
}

m["mnz"] = {
	canonicalName = "Moni",
}

m["moa"] = {
	canonicalName = "Mwan",
}

m["moc"] = {
	canonicalName = "Mocoví",
	otherNames = {"Mbocobí", "Mokoví", "Moqoyt"},
	family = "sai-guc",
}

m["mod"] = {
	canonicalName = "Mobilian",
	scripts = {"Latn"},
	family = "crp",
}

m["moe"] = {
	canonicalName = "Montagnais",
	scripts = {"Latn"},
	family = "alg",
	ancestors = {"cr"},
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["mog"] = {
	canonicalName = "Mongondow",
	scripts = {"Latn"},
	family = "phi",
}

m["moh"] = {
	canonicalName = "Mohawk",
	scripts = {"Latn"},
	family = "iro",
}

m["moi"] = {
	canonicalName = "Mboi",
}

m["moj"] = {
	canonicalName = "Monzombo",
	family = "nic-ubg",
}

m["mok"] = {
	canonicalName = "Morori",
}

m["mom"] = {
	canonicalName = "Monimbo",
}

m["moo"] = {
	canonicalName = "Monom",
	otherNames = {"Monam", "Bonam"},
	family = "aav-ban",
}

m["mop"] = {
	canonicalName = "Mopan Maya",
	otherNames = {"Mopan", "Mopán Maya", "Mopán"},
	scripts = {"Latn"},
	family = "myn",
}

m["moq"] = {
	canonicalName = "Papuan Mor",
	otherNames = {"Mor"},
	family = "paa",
}

m["mor"] = {
	canonicalName = "Moro",
}

m["mos"] = {
	canonicalName = "Moore",
	otherNames = {"More", "Mossi", "Moshi", "Mõõré", "Mòoré", "Mooré", "Moré", "Möré"},
	family = "nic-gur",
}

m["mot"] = {
	canonicalName = "Barí",
	otherNames = {"Bari", "Baria", "Barira", "Motilón", "Motilon", "Motilone"},
}

m["mou"] = {
	canonicalName = "Mogum",
}

m["mov"] = {
	canonicalName = "Mojave",
	scripts = {"Latn"},
	family = "nai-yuc",
}

m["mow"] = {
	canonicalName = "Moi (Congo)",
	otherNames = {"Moi"},
	scripts = {"Latn"},
	family = "bnt",
}

m["mox"] = {
	canonicalName = "Molima",
	family = "poz-ocw",
}

m["moy"] = {
	canonicalName = "Shekkacho",
}

m["moz"] = {
	canonicalName = "Mukulu",
}

m["mpa"] = {
	canonicalName = "Mpoto",
}

m["mpb"] = {
	canonicalName = "Mullukmulluk",
}

m["mpc"] = {
	canonicalName = "Mangarayi",
}

m["mpd"] = {
	canonicalName = "Machinere",
	family = "awd",
}

m["mpe"] = {
	canonicalName = "Majang",
	family = "sdv",
}

m["mpg"] = {
	canonicalName = "Marba",
}

m["mph"] = {
	canonicalName = "Maung",
	scripts = {"Latn"},
	family = "aus-wdj",
}

m["mpi"] = {
	canonicalName = "Mpade",
}

m["mpj"] = {
	canonicalName = "Martu Wangka",
	otherNames = {"Yulparija", "Yulparitja"},
	scripts = {"Latn"},
}

m["mpk"] = {
	canonicalName = "Mbara (Chad)",
	otherNames = {"Mbara"},
	family = "cdc-cbm",
}

m["mpl"] = {
	canonicalName = "Middle Watut",
	family = "poz-ocw",
}

m["mpm"] = {
	canonicalName = "Yosondúa Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mpn"] = {
	canonicalName = "Mindiri",
	family = "poz-ocw",
}

m["mpo"] = {
	canonicalName = "Miu",
	family = "poz-ocw",
}

m["mpp"] = {
	canonicalName = "Migabac",
}

m["mpq"] = {
	canonicalName = "Matís",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["mpr"] = {
	canonicalName = "Vangunu",
	family = "poz-ocw",
}

m["mps"] = {
	canonicalName = "Dadibi",
	otherNames = {"Daribi", "Karimui"},
	scripts = {"Latn"},
	family = "ngf",
}

m["mpt"] = {
	canonicalName = "Mian",
}

m["mpu"] = {
	canonicalName = "Makuráp",
}

m["mpv"] = {
	canonicalName = "Mungkip",
	family = "ngf-fin",
}

m["mpw"] = {
	canonicalName = "Mapidian",
	family = "awd",
}

m["mpx"] = {
	canonicalName = "Misima-Paneati",
	family = "poz-ocw",
}

m["mpy"] = {
	canonicalName = "Mapia",
	family = "poz-mic",
}

m["mpz"] = {
	canonicalName = "Mpi",
	family = "tbq-lol",
}

m["mqa"] = {
	canonicalName = "Maba",
}

m["mqb"] = {
	canonicalName = "Mbuko",
}

m["mqc"] = {
	canonicalName = "Mangole",
	family = "plf",
}

m["mqe"] = {
	canonicalName = "Matepi",
}

m["mqf"] = {
	canonicalName = "Momuna",
}

m["mqg"] = {
	canonicalName = "Kota Bangun Kutai Malay",
}

m["mqh"] = {
	canonicalName = "Tlazoyaltepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mqi"] = {
	canonicalName = "Mariri",
}

m["mqj"] = {
	canonicalName = "Mamasa",
}

m["mqk"] = {
	canonicalName = "Rajah Kabunsuwan Manobo",
}

m["mql"] = {
	canonicalName = "Mbelime",
}

m["mqm"] = {
	canonicalName = "South Marquesan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["mqn"] = {
	canonicalName = "Moronene",
	scripts = {"Latn"},
	family = "poz-btk",
}

m["mqo"] = {
	canonicalName = "Modole",
}

m["mqp"] = {
	canonicalName = "Manipa",
	family = "plf",
}

m["mqq"] = {
	canonicalName = "Minokok",
}

m["mqr"] = {
	canonicalName = "Mander",
}

m["mqs"] = {
	canonicalName = "West Makian",
}

m["mqt"] = {
	canonicalName = "Mok",
	family = "aav",
}

m["mqu"] = {
	canonicalName = "Mandari",
	family = "sdv",
}

m["mqv"] = {
	canonicalName = "Mosimo",
}

m["mqw"] = {
	canonicalName = "Murupi",
}

m["mqx"] = {
	canonicalName = "Mamuju",
}

m["mqy"] = {
	canonicalName = "Manggarai",
	scripts = {"Latn"},
	family = "plf",
}

m["mqz"] = {
	canonicalName = "Malasanga",
}

m["mra"] = {
	canonicalName = "Mlabri",
	family = "mkh",
}

m["mrb"] = {
	canonicalName = "Marino",
}

m["mrc"] = {
	canonicalName = "Maricopa",
	scripts = {"Latn"},
	family = "nai-yuc",
}

m["mrd"] = {
	canonicalName = "Western Magar",
}

m["mre"] = {
	canonicalName = "Martha's Vineyard Sign Language",
	family = "sgn",
}

m["mrf"] = {
	canonicalName = "Elseng",
}

m["mrg"] = {
	canonicalName = "Mising",
	otherNames = {"Mishing", "Plains Miri", "Takam", "Hill Miri", "Sarak"},
	scripts = {"Latn", "Beng", "Deva"},
	family = "tbq",
	ancestors = {"adi"},
}

m["mrh"] = {
	canonicalName = "Mara Chin",
	otherNames = {"Chin Mara", "Lakher", "Mara", "Maram", "Mira", "Zao"},
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["mrj"] = {
	canonicalName = "Western Mari",
	otherNames = {"Hill Mari", "Mountain Mari", "Highland Mari"},
	scripts = {"Cyrl"},
	family = "urj",
	translit_module = "chm-translit",
}

m["mrk"] = {
	canonicalName = "Hmwaveke",
	family = "poz-cln",
}

m["mrl"] = {
	canonicalName = "Mortlockese",
	family = "poz-mic",
}

m["mrm"] = {
	canonicalName = "Merlav",
	family = "poz-vnc",
}

m["mrn"] = {
	canonicalName = "Cheke Holo",
	family = "poz-ocw",
}

m["mro"] = {
	canonicalName = "Mru",
}

m["mrp"] = {
	canonicalName = "Morouas",
	family = "poz-vnc",
}

m["mrq"] = {
	canonicalName = "North Marquesan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["mrr"] = {
	canonicalName = "Hill Maria",
	otherNames = {"Garhchiroli Maria", "Madia", "Madiya", "Maria (India)", "Maria"}, -- the last four are also names of mrr's sibling lect, daq
	family = "dra",
	ancestors = {"gon"},
}

m["mrs"] = {
	canonicalName = "Maragus",
	family = "poz-vnc",
}

m["mrt"] = {
	canonicalName = "Margi",
	otherNames = {"Marghi Central", "Marghi"},
	scripts = {"Latn"},
	family = "cdc",
}

m["mru"] = {
	canonicalName = "Mono (Cameroon)",
	otherNames = {"Mono"},
	family = "alv-mbm",
}

m["mrv"] = {
	canonicalName = "Mangarevan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["mrw"] = {
	canonicalName = "Maranao",
	family = "phi",
}

m["mrx"] = {
	canonicalName = "Dineor",
}

m["mry"] = {
	canonicalName = "Karaga Mandaya",
}

m["mrz"] = {
	canonicalName = "Marind",
}

m["msb"] = {
	canonicalName = "Masbatenyo",
	otherNames = {"Masbateño", "Masbateno", "Minasbate"},
	scripts = {"Latn"},
	family = "phi",
}

m["msc"] = {
	canonicalName = "Sankaran Maninka",
}

m["msd"] = {
	canonicalName = "Yucatec Maya Sign Language",
	family = "sgn",
}

m["mse"] = {
	canonicalName = "Musey",
}

m["msf"] = {
	canonicalName = "Mekwei",
	otherNames = {"Mekwei (New Guinea)", "Menggwei"},
}

m["msg"] = {
	canonicalName = "Moraid",
}

m["msi"] = {
	canonicalName = "Sabah Malay",
}

m["msj"] = {
	canonicalName = "Ma",
	otherNames = {"Madi"},
	family = "nic-ubg",
}

m["msk"] = {
	canonicalName = "Mansaka",
	scripts = {"Latn"},
	family = "phi",
}

m["msl"] = {
	canonicalName = "Molof",
}

m["msm"] = {
	canonicalName = "Agusan Manobo",
}

m["msn"] = {
	canonicalName = "Vurës",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["mso"] = {
	canonicalName = "Mombum",
}

m["msp"] = {
	canonicalName = "Maritsauá",
}

m["msq"] = {
	canonicalName = "Caac",
	family = "poz-cln",
}

m["msr"] = {
	canonicalName = "Mongolian Sign Language",
	family = "sgn",
}

m["mss"] = {
	canonicalName = "West Masela",
}

m["msu"] = {
	canonicalName = "Musom",
	family = "poz-ocw",
}

m["msv"] = {
	canonicalName = "Maslam",
}

m["msw"] = {
	canonicalName = "Mansoanka",
}

m["msx"] = {
	canonicalName = "Moresada",
}

m["msy"] = {
	canonicalName = "Aruamu",
	family = "paa",
}

m["msz"] = {
	canonicalName = "Momare",
}

m["mta"] = {
	canonicalName = "Cotabato Manobo",
}

m["mtb"] = {
	canonicalName = "Anyin Morofo",
	family = "alv-kwa",
}

m["mtc"] = {
	canonicalName = "Munit",
}

m["mtd"] = {
	canonicalName = "Mualang",
}

m["mte"] = {
	canonicalName = "Alu",
	otherNames = {"Mono", "Mono-Alu"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["mtf"] = {
	canonicalName = "Murik (New Guinea)",
	otherNames = {"Murik (Papua New Guinea)", "Murik", "Sepik Murik"},
	scripts = {"Latn"},
}

m["mtg"] = {
	canonicalName = "Una",
}

m["mth"] = {
	canonicalName = "Munggui",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["mti"] = {
	canonicalName = "Maiwa (New Guinea)",
	otherNames = {"Maiwa (Papua New Guinea)", "Maiwa"},
	scripts = {"Latn"},
	family = "ngf",
}

m["mtj"] = {
	canonicalName = "Moskona",
}

m["mtk"] = {
	canonicalName = "Mbe'",
	family = "nic-bod",
}

m["mtl"] = {
	canonicalName = "Montol",
}

m["mtm"] = {
	canonicalName = "Mator",
	otherNames = {"Taygi", "Karagas", "Mator-Taygi-Karagas"},
	scripts = {"Cyrl"},
	family = "syd",
}

m["mtn"] = {
	canonicalName = "Matagalpa",
}

m["mto"] = {
	canonicalName = "Totontepec Mixe",
}

m["mtp"] = {
	canonicalName = "Wichí Lhamtés Nocten",
	family = "sai-wic",
}

m["mtq"] = {
	canonicalName = "Muong",
	scripts = {"Latn"},
	family = "mkh-vie",
}

m["mts"] = {
	canonicalName = "Yora",
	family = "sai-pan",
}

m["mtt"] = {
	canonicalName = "Mota",
	family = "poz-vnc",
}

m["mtu"] = {
	canonicalName = "Tututepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mtv"] = {
	canonicalName = "Asaro'o",
	family = "ngf-fin",
}

m["mtw"] = {
	canonicalName = "Magahat",
}

m["mtx"] = {
	canonicalName = "Tidaá Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mty"] = {
	canonicalName = "Nabi",
	family = "qfa-tor",
}

m["mua"] = {
	canonicalName = "Mundang",
}

m["mub"] = {
	canonicalName = "Mubi",
}

m["muc"] = {
	canonicalName = "Mbu'",
	family = "nic-bod",
}

m["mud"] = {
	canonicalName = "Mednyj Aleut",
}

m["mue"] = {
	canonicalName = "Media Lengua",
	scripts = {"Latn"},
	family = "crp",
}

m["mug"] = {
	canonicalName = "Musgu",
}

m["muh"] = {
	canonicalName = "Mündü",
	otherNames = {"Mundu"},
	family = "nic-ubg",
}

m["mui"] = {
	canonicalName = "Musi",
}

m["muj"] = {
	canonicalName = "Mabire",
}

m["mul"] = {
	canonicalName = "Dillərarası",
	scripts = {"None", "Latn", "Bopo", "Brai", "Cyrl", "Hani", "Hans", "Hant", "IPAchar", "musical", "Ruminumerals", "Zsym", "Zmth"},
	family = "qfa-not",
}

m["mum"] = {
	canonicalName = "Maiwala",
	family = "poz-ocw",
}

m["muo"] = {
	canonicalName = "Nyong",
}

m["mup"] = {
	canonicalName = "Malvi",
	ancestors = {"raj"},
}

m["muq"] = {
	canonicalName = "Eastern Xiangxi Miao",
	family = "hmn",
}

m["mur"] = {
	canonicalName = "Murle",
	family = "sdv",
}

m["mus"] = {
	canonicalName = "Creek",
	otherNames = {"Muscogee"},
	scripts = {"Latn"},
	family = "nai-mus",
}

m["mut"] = {
	canonicalName = "Western Muria",
	family = "dra",
	ancestors = {"gon"},
}

m["muu"] = {
	canonicalName = "Yaaku",
	family = "cus",
}

m["muv"] = {
	canonicalName = "Muthuvan",
	family = "dra",
}

m["mux"] = {
	canonicalName = "Bo-Ung",
}

m["muy"] = {
	canonicalName = "Muyang",
}

m["muz"] = {
	canonicalName = "Mursi",
	family = "sdv",
}

m["mva"] = {
	canonicalName = "Manam",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["mvb"] = {
	canonicalName = "Mattole",
	family = "ath-pco",
}

m["mvd"] = {
	canonicalName = "Mamboru",
}

m["mvg"] = {
	canonicalName = "Yucuañe Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mvh"] = {
	canonicalName = "Mire",
}

m["mvi"] = {
	canonicalName = "Miyako",
	scripts = {"Kana"},
	family = "jpx-ryu",
}

m["mvk"] = {
	canonicalName = "Mekmek",
}

m["mvl"] = {
	canonicalName = "Mbara (Australia)",
	otherNames = {"Mbara", "Midjamba"},
	family = "aus-pam",
}

m["mvm"] = {
	canonicalName = "Muya",
}

m["mvn"] = {
	canonicalName = "Minaveha",
	family = "poz-ocw",
}

m["mvo"] = {
	canonicalName = "Marovo",
	family = "poz-ocw",
}

m["mvp"] = {
	canonicalName = "Duri",
}

m["mvq"] = {
	canonicalName = "Moere",
}

m["mvr"] = {
	canonicalName = "Marau",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["mvs"] = {
	canonicalName = "Massep",
}

m["mvt"] = {
	canonicalName = "Mpotovoro",
	family = "poz-vnc",
}

m["mvu"] = {
	canonicalName = "Marfa",
}

m["mvv"] = {
	canonicalName = "Tagal Murut",
	scripts = {"Latn"},
	family = "poz-san",
}

m["mvw"] = {
	canonicalName = "Machinga",
}

m["mvx"] = {
	canonicalName = "Meoswar",
	family = "poz-hce",
}

m["mvy"] = {
	canonicalName = "Indus Kohistani",
}

m["mvz"] = {
	canonicalName = "Mesqan",
	family = "sem-eth",
}

m["mwa"] = {
	canonicalName = "Mwatebu",
	family = "poz-ocw",
}

m["mwb"] = {
	canonicalName = "Juwal",
	family = "qfa-tor",
}

m["mwc"] = {
	canonicalName = "Are",
	family = "poz-ocw",
}

m["mwe"] = {
	canonicalName = "Mwera",
	otherNames = {"Chimwera", "Cimwera", "Mwela"},
}

m["mwf"] = {
	canonicalName = "Murrinh-Patha",
	scripts = {"Latn"},
	family = "aus-dal",
}

m["mwg"] = {
	canonicalName = "Aiklep",
	family = "poz-ocw",
}

m["mwh"] = {
	canonicalName = "Mouk-Aria",
	family = "poz-ocw",
}

m["mwi"] = {
	canonicalName = "Labo",
	family = "poz-vnc",
}

m["mwk"] = {
	canonicalName = "Kita Maninkakan",
}

m["mwl"] = {
	canonicalName = "Mirandese",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"roa-ole"},
}

m["mwm"] = {
	canonicalName = "Sar",
}

m["mwn"] = {
	canonicalName = "Nyamwanga",
}

m["mwo"] = {
	canonicalName = "Central Maewo",
}

m["mwp"] = {
	canonicalName = "Kala Lagaw Ya",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["mwq"] = {
	canonicalName = "Mün Chin",
	otherNames = {"Mün", "Müün Chin"},
	family = "tbq-kuk",
}

m["mwr"] = {
	canonicalName = "Marwari",
	otherNames = {"Merwari", "Mewari", "Dhundari", "Shekhawati", "Harauti", "Goaria", "Gurgula"},
	scripts = {"Deva"},
	family = "inc",
}

m["mws"] = {
	canonicalName = "Mwimbi-Muthambi",
}

m["mwt"] = {
	canonicalName = "Moken",
	family = "poz",
}

m["mwu"] = {
	canonicalName = "Mittu",
	family = "csu",
}

m["mwv"] = {
	canonicalName = "Mentawai",
	scripts = {"Latn"},
	family = "poz-nws",
}

m["mww"] = {
	canonicalName = "White Hmong",
	otherNames = {"Hmong Daw", "Hmoob Dawb"},
	scripts = {"Latn", "Hmng"},
	family = "hmn",
}

m["mwx"] = {
	canonicalName = "Mediak",
	family = "sdv",
}

m["mwy"] = {
	canonicalName = "Mosiro",
	family = "sdv",
}

m["mwz"] = {
	canonicalName = "Moingi",
}

m["mxa"] = {
	canonicalName = "Northwest Oaxaca Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mxb"] = {
	canonicalName = "Tezoatlán Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mxc"] = {
	canonicalName = "Manyika",
}

m["mxd"] = {
	canonicalName = "Modang",
}

m["mxe"] = {
	canonicalName = "Mele-Fila",
	family = "poz-pol",
}

m["mxf"] = {
	canonicalName = "Malgbe",
}

m["mxg"] = {
	canonicalName = "Mbangala",
}

m["mxh"] = {
	canonicalName = "Mvuba",
	scripts = {"Latn"},
	family = "csu",
}

m["mxi"] = {
	canonicalName = "Mozarabic",
	scripts = {"Arab", "Hebr", "Latn"},
	family = "roa",
}

m["mxj"] = {
	canonicalName = "Miju",
	otherNames = {"Miju Mishmi", "Miju-Mishmi", "Geman Deng", "Geman", "Kaman", "Midzu"},
	scripts = {"Latn"},
}

m["mxk"] = {
	canonicalName = "Monumbo",
	family = "qfa-tor",
}

m["mxl"] = {
	canonicalName = "Maxi Gbe",
}

m["mxm"] = {
	canonicalName = "Meramera",
	family = "poz-ocw",
}

m["mxn"] = {
	canonicalName = "Moi (Indonesia)",
	otherNames = {"Moi", "Mekwei"},
	family = "paa",
}

m["mxo"] = {
	canonicalName = "Mbowe",
}

m["mxp"] = {
	canonicalName = "Tlahuitoltepec Mixe",
}

m["mxq"] = {
	canonicalName = "Juquila Mixe",
}

m["mxr"] = {
	canonicalName = "Murik (Malaysia)",
	otherNames = {"Murik", "Kayan Murik"},
	scripts = {"Latn"},
}

m["mxs"] = {
	canonicalName = "Huitepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mxt"] = {
	canonicalName = "Jamiltepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mxu"] = {
	canonicalName = "Mada (Cameroon)",
	otherNames = {"Mada"},
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["mxv"] = {
	canonicalName = "Metlatónoc Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mxw"] = {
	canonicalName = "Namo",
}

m["mxx"] = {
	canonicalName = "Mahou",
	otherNames = {"Mawukakan", "Mahu", "Maou", "Mau", "Mawu"},
}

m["mxy"] = {
	canonicalName = "Southeastern Nochixtlán Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mxz"] = {
	canonicalName = "Central Masela",
}

m["myb"] = {
	canonicalName = "Mbay",
}

m["myc"] = {
	canonicalName = "Mayeka",
}

m["myd"] = {
	canonicalName = "Maramba",
}

m["mye"] = {
	canonicalName = "Myene",
}

m["myf"] = {
	canonicalName = "Bambassi",
}

m["myg"] = {
	canonicalName = "Manta",
	family = "nic-bod",
}

m["myh"] = {
	canonicalName = "Makah",
	scripts = {"Latn"},
	family = "wak",
}

m["myj"] = {
	canonicalName = "Mangayat",
}

m["myk"] = {
	canonicalName = "Mamara Senoufo",
}

m["myl"] = {
	canonicalName = "Moma",
}

m["mym"] = {
	canonicalName = "Me'en",
	family = "sdv",
}

m["myo"] = {
	canonicalName = "Anfillo",
}

m["myp"] = {
	canonicalName = "Pirahã",
	scripts = {"Latn"},
	family = "sai-mur",
}

m["myr"] = {
	canonicalName = "Muniche",
}

m["mys"] = {
	canonicalName = "Mesmes",
	family = "sem-eth",
}

m["myu"] = {
	canonicalName = "Mundurukú",
}

m["myv"] = {
	canonicalName = "Erzya",
	otherNames = {"Mordvin"},
	scripts = {"Cyrl"},
	family = "fiu-mdv",
	translit_module = "myv-translit",
}

m["myw"] = {
	canonicalName = "Muyuw",
	family = "poz-ocw",
}

m["myx"] = {
	canonicalName = "Masaba",
	otherNames = {"Masaaba"},
	scripts = {"Latn"},
	family = "bnt",
}

m["myy"] = {
	canonicalName = "Macuna",
	otherNames = {"Buhagana", "Bujagana", "Wahana"},
	family = "sai-tuc",
}

m["myz"] = {
	canonicalName = "Classical Mandaic",
	scripts = {"Mand"},
	family = "sem-ara",
}

m["mza"] = {
	canonicalName = "Santa María Zacatepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["mzb"] = {
	canonicalName = "Tumzabt",
	otherNames = {"Mozabite", "Tumẓabt"},
	family = "ber",
}

m["mzc"] = {
	canonicalName = "Madagascar Sign Language",
	family = "sgn",
}

m["mzd"] = {
	canonicalName = "Malimba",
}

m["mze"] = {
	canonicalName = "Morawa",
}

m["mzg"] = {
	canonicalName = "Monastic Sign Language",
	family = "sgn",
}

m["mzh"] = {
	canonicalName = "Wichí Lhamtés Güisnay",
	family = "sai-wic",
}

m["mzi"] = {
	canonicalName = "Ixcatlán Mazatec",
	family = "omq-maz",
}

m["mzj"] = {
	canonicalName = "Manya",
}

m["mzk"] = {
	canonicalName = "Nigeria Mambila",
	family = "nic-bod",
}

m["mzl"] = {
	canonicalName = "Mazatlán Mixe",
}

m["mzm"] = {
	canonicalName = "Mumuye",
	family = "alv-sav",
}

m["mzn"] = {
	canonicalName = "Mazanderani",
	otherNames = {"Mazandarani", "Tabari"},
	scripts = {"fa-Arab", "mzn-Arab"},
	family = "ira",
}

m["mzo"] = {
	canonicalName = "Matipuhy",
	family = "sai-car",
}

m["mzp"] = {
	canonicalName = "Movima",
}

m["mzq"] = {
	canonicalName = "Mori Atas",
}

m["mzr"] = {
	canonicalName = "Marúbo",
	family = "sai-pan",
}

m["mzs"] = {
	canonicalName = "Macanese",
	scripts = {"Latn"},
	family = "crp",
}

m["mzt"] = {
	canonicalName = "Mintil",
}

m["mzu"] = {
	canonicalName = "Inapang",
	family = "paa",
}

m["mzv"] = {
	canonicalName = "Manza",
}

m["mzw"] = {
	canonicalName = "Deg",
}

m["mzx"] = {
	canonicalName = "Mawayana",
}

m["mzy"] = {
	canonicalName = "Mozambican Sign Language",
	family = "sgn",
}

m["mzz"] = {
	canonicalName = "Maiadomu",
	family = "poz-ocw",
}

return m