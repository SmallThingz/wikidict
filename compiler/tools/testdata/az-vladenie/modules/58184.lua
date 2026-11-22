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

m["caa"] = {
	canonicalName = "Ch'orti'",
	otherNames = {"Chorti"},
	scripts = {"Latn"},
	family = "myn",
}

m["cab"] = {
	canonicalName = "Garifuna",
	scripts = {"Latn"},
	family = "awd",
}

m["cac"] = {
	canonicalName = "Chuj",
	scripts = {"Latn"},
	family = "myn",
}

m["cad"] = {
	canonicalName = "Caddo",
	scripts = {"Latn"},
	family = "cdd",
}

m["cae"] = {
	canonicalName = "Laalaa",
	scripts = {"Latn"},
	family = "alv-sng",
}

m["caf"] = {
	canonicalName = "Southern Carrier",
	scripts = {"Latn"},
	family = "ath",
}

m["cag"] = {
	canonicalName = "Nivaclé",
	scripts = {"Latn"},
	family = "sai-mtc",
}

m["cah"] = {
	canonicalName = "Cahuarano",
	scripts = {"Latn"},
	family = "sai-zap",
}

m["caj"] = {
	canonicalName = "Chané",
	scripts = {"Latn"},
	family = "awd",
}

m["cak"] = {
	canonicalName = "Cakchiquel",
	otherNames = {"Kaqchikel", "Kakchiquel", "Cachiquel"},
	scripts = {"Latn"},
	family = "myn",
}

m["cal"] = {
	canonicalName = "Carolinian",
	scripts = {"Latn"},
	family = "poz-mic",
}

m["cam"] = {
	canonicalName = "Cemuhî",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["can"] = {
	canonicalName = "Chambri",
	scripts = {"Latn"},
	family = "paa-lsp",
}

m["cao"] = {
	canonicalName = "Chácobo",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["cap"] = {
	canonicalName = "Chipaya",
	scripts = {"Latn"},
	family = "sai-ucp",
}

m["caq"] = {
	canonicalName = "Car Nicobarese",
	scripts = {"Latn"},
	family = "aav",
}

m["car"] = {
	canonicalName = "Galibi Carib",
	otherNames = {"Carib", "Caribe", "Cariña", "Galibi", "Galibí", "Kalihna", "Kali'na", "Kalinya", "Maraworno", "Marworno"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["cas"] = {
	canonicalName = "Tsimané",
	otherNames = {"Chimané", "Mosetén"},
	scripts = {"Latn"},
}

m["cav"] = {
	canonicalName = "Cavineña",
	otherNames = {"Cavinena"},
	scripts = {"Latn"},
	family = "sai-tac",
}

m["caw"] = {
	canonicalName = "Callawalla",
	scripts = {"Latn"},
	family = "qfa-mix",
}

m["cax"] = {
	canonicalName = "Chiquitano",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["cay"] = {
	canonicalName = "Cayuga",
	scripts = {"Latn"},
	family = "iro",
}

m["caz"] = {
	canonicalName = "Canichana",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["cbb"] = {
	canonicalName = "Cabiyarí",
	scripts = {"Latn"},
	family = "awd",
}

m["cbc"] = {
	canonicalName = "Carapana",
	scripts = {"Latn"},
	family = "sai-tuc",
}

m["cbd"] = {
	canonicalName = "Carijona",
	otherNames = {"Carihona", "Karijona", "Karihona", "Jianacoto", "Jianácoto", "Hianakoto", "Hianacoto", "Hianákoto", "Guaque", "Omagua", "Umaua", "Umawa"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["cbg"] = {
	canonicalName = "Chimila",
	scripts = {"Latn"},
	family = "cba",
}

m["cbi"] = {
	canonicalName = "Chachi",
	otherNames = {"Cha'palaa", "Chapalaa", "Cha'palaachi", "Chapalaachi", "Cayapa"},
	scripts = {"Latn"},
	family = "sai-bar",
}

m["cbj"] = {
	canonicalName = "Ede Cabe",
	scripts = {"Latn"},
	family = "alv-von",
}

m["cbk"] = {
	canonicalName = "Chavacano",
	otherNames = {"Zamboanga Chavacano"},
	scripts = {"Latn"},
	family = "crp",
}

m["cbl"] = {
	canonicalName = "Bualkhaw Chin",
	otherNames = {"Bualkhaw"},
	family = "tbq-kuk",
}

m["cbn"] = {
	canonicalName = "Nyah Kur",
	otherNames = {"Nyahkur"},
	scripts = {"Latn"},
	family = "aav",
}

m["cbo"] = {
	canonicalName = "Izora",
	scripts = {"Latn"},
	family = "nic-knj",
}

m["cbq"] = {
	canonicalName = "Shuba", -- also Tsucuba, Cuba per Ethnologue but these aren't attested
}

m["cbr"] = {
	canonicalName = "Cashibo-Cacataibo",
	otherNames = {"Cashibo", "Cacataibo"},
	scripts = {"Latn"},
	family = "sai-pan",
}

m["cbs"] = {
	canonicalName = "Cashinahua",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["cbt"] = {
	canonicalName = "Chayahuita",
	scripts = {"Latn"},
}

m["cbu"] = {
	canonicalName = "Candoshi-Shapra",
}

m["cbv"] = {
	canonicalName = "Cacua",
}

m["cbw"] = {
	canonicalName = "Kinabalian",
}

m["cby"] = {
	canonicalName = "Carabayo",
	otherNames = {"Caraballo", "Yuri", "Aroje", "Yacumo", "Maku", "Macu", "Macusa"},
	scripts = {"Latn"},
	family = "sai-tyu",
}

m["cca"] = {
	canonicalName = "Cauca",
}

m["ccc"] = {
	canonicalName = "Chamicuro",
	scripts = {"Latn"},
	family = "awd",
}

m["ccd"] = {
	canonicalName = "Cafundo Creole",
}

m["cce"] = {
	canonicalName = "Chopi",
}

m["ccg"] = {
	canonicalName = "Chamba Daka",
	otherNames = {"Samba Daka", "Nakanyare"},
	family = "nic-bco",
}

m["cch"] = {
	canonicalName = "Atsam",
}

m["ccj"] = {
	canonicalName = "Kasanga",
}

m["ccl"] = {
	canonicalName = "Cutchi-Swahili",
}

m["ccm"] = {
	canonicalName = "Malaccan Creole Malay",
}

m["cco"] = {
	canonicalName = "Comaltepec Chinantec",
}

m["ccp"] = {
	canonicalName = "Chakma",
	scripts = {"Cakm"},
	family = "inc",
	ancestors = {"pka"},
}

m["ccr"] = {
	canonicalName = "Cacaopera",
}

m["cda"] = {
	canonicalName = "Choni",
}

m["cde"] = {
	canonicalName = "Chenchu",
	family = "dra",
	ancestors = {"te"},
}

m["cdf"] = {
	canonicalName = "Chiru",
	family = "tbq-kuk",
}

m["cdg"] = {
	canonicalName = "Chamari",
}

m["cdh"] = {
	canonicalName = "Chambeali",
}

m["cdi"] = {
	canonicalName = "Chodri",
}

m["cdj"] = {
	canonicalName = "Churahi",
}

m["cdm"] = {
	canonicalName = "Chepang",
}

m["cdn"] = {
	canonicalName = "Chaudangsi",
	family = "sit",
}

m["cdo"] = {
	canonicalName = "Min Dong",
	otherNames = {"Min Dong Chinese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"zhx-min-pro"},
}

m["cdr"] = {
	canonicalName = "Cinda-Regi-Tiyal",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["cds"] = {
	canonicalName = "Chadian Sign Language",
	family = "sgn",
}

m["cdy"] = {
	canonicalName = "Chadong",
}

m["cdz"] = {
	canonicalName = "Koda",
	family = "mun",
}

m["cea"] = {
	canonicalName = "Lower Chehalis",
	family = "sal",
}

m["ceb"] = {
	canonicalName = "Cebuano",
	scripts = {"Latn"},
	family = "phi",
}

m["ceg"] = {
	canonicalName = "Chamacoco",
}

m["cen"] = {
	canonicalName = "Cen",
}

m["cet"] = {
	canonicalName = "Centúúm",
}

m["cfa"] = {
	canonicalName = "Dijim-Bwilim",
}

m["cfd"] = {
	canonicalName = "Cara",
}

m["cfg"] = {
	canonicalName = "Como Karim",
}

m["cfm"] = {
	canonicalName = "Falam Chin",
	otherNames = {"Falam"},
	family = "tbq-kuk",
}

m["cga"] = {
	canonicalName = "Changriwa",
}

m["cgc"] = {
	canonicalName = "Kagayanen",
}

m["cgg"] = {
	canonicalName = "Rukiga",
	scripts = {"Latn"},
	family = "bnt",
}

m["cgk"] = {
	canonicalName = "Chocangacakha",
}

m["chb"] = {
	canonicalName = "Chibcha",
}

m["chc"] = {
	canonicalName = "Catawba",
	scripts = {"Latn"},
	family = "nai-cat",
}

m["chd"] = {
	canonicalName = "Highland Oaxaca Chontal", -- distinguish clo, nai-teq
	otherNames = {"Oaxaca Chontal", "Oaxacan Chontal", "Chontal", "Tequistlatec", "Mountain Tequistlateco", "Highland Chontal", "Mountain Chontal"},
	scripts = {"Latn"},
	family = "nai-tqn",
}

m["chf"] = {
	canonicalName = "Tabasco Chontal",
}

m["chg"] = {
	canonicalName = "Chagatai",
	scripts = {"Arab"},
	family = "trk",
}

m["chh"] = {
	canonicalName = "Chinook",
	scripts = {"Latn"},
	family = "nai-ckn",
}

m["chj"] = {
	canonicalName = "Ojitlán Chinantec",
}

m["chk"] = {
	canonicalName = "Chuukese",
	scripts = {"Latn"},
	family = "poz-mic",
}

m["chl"] = {
	canonicalName = "Cahuilla",
	scripts = {"Latn"},
	family = "azc-cup",
	entry_name = {
		from = {"Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", MACRON},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["chm"] = {
	canonicalName = "Eastern Mari",
	otherNames = {"Meadow Mari", "Lowland Mari", "Midland Mari", "Standard Mari", "Upo Mari", "Mari", "Mari (Russia)"},	
	scripts = {"Cyrl"},
	family = "urj",
	translit_module = "chm-translit",
	wikimedia_codes = {"mhr"},
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["chn"] = {
	canonicalName = "Chinook Jargon",
	scripts = {"Latn", "Dupl"},
	family = "crp",
}

m["cho"] = {
	canonicalName = "Choctaw",
	scripts = {"Latn"},
	family = "nai-mus",
}

m["chp"] = {
	canonicalName = "Chipewyan",
	otherNames = {"Dëne Sųłiné", "Dënesųłiné", "Dëne", "Dene Suline", "Denesuline", "Dene"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["chq"] = {
	canonicalName = "Quiotepec Chinantec",
}

m["chr"] = {
	canonicalName = "Cherokee",
	scripts = {"Cher"},
	family = "iro",
	translit_module = "Cher-translit",
}

m["cht"] = {
	canonicalName = "Cholón",
}

m["chw"] = {
	canonicalName = "Chuwabu",
}

m["chx"] = {
	canonicalName = "Chantyal",
}

m["chy"] = {
	canonicalName = "Cheyenne",
	scripts = {"Latn"},
	family = "alg",
}

m["chz"] = {
	canonicalName = "Ozumacín Chinantec",
}

m["cia"] = {
	canonicalName = "Cia-Cia",
	scripts = {"Hang", "Latn"},
	family = "poz-mun",
}

m["cib"] = {
	canonicalName = "Ci Gbe",
}

m["cic"] = {
	canonicalName = "Chickasaw",
	scripts = {"Latn"},
	family = "nai-mus",
}

m["cid"] = {
	canonicalName = "Chimariko",
	family = "qfa-iso",
}

m["cie"] = {
	canonicalName = "Cineni",
}

m["cih"] = {
	canonicalName = "Chinali",
}

m["cik"] = {
	canonicalName = "Chitkuli Kinnauri",
}

m["cim"] = {
	canonicalName = "Cimbrian",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"bar"},
}

m["cin"] = {
	canonicalName = "Cinta Larga",
}

m["cip"] = {
	canonicalName = "Chiapanec",
}

m["cir"] = {
	canonicalName = "Tiri",
	otherNames = {"Tîrî", "Ciri", "Tinrin", "Méa", "Haméa"},
	family = "poz-cln",
}

m["ciy"] = {
	canonicalName = "Chaima",
}

m["cja"] = {
	canonicalName = "Western Cham",
	scripts = {"Arab"},
	family = "poz-msa",
}

m["cje"] = {
	canonicalName = "Chru",
	scripts = {"Latn"},
	family = "poz-msa",
}

m["cjh"] = {
	canonicalName = "Upper Chehalis",
}

m["cji"] = {
	canonicalName = "Chamalal",
	scripts = {"Cyrl"},
	family = "cau-ava",
}

m["cjk"] = {
	canonicalName = "Chokwe",
	scripts = {"Latn"},
	family = "bnt",
}

m["cjm"] = {
	canonicalName = "Eastern Cham",
	scripts = {"Cham"},
	family = "cmc",
}

m["cjn"] = {
	canonicalName = "Chenapian",
}

m["cjo"] = {
	canonicalName = "Ashéninka Pajonal",
	family = "awd",
}

m["cjp"] = {
	canonicalName = "Cabécar",
}

m["cjs"] = {
	canonicalName = "Shor",
	scripts = {"Cyrl"},
	family = "trk",
}

m["cjv"] = {
	canonicalName = "Chuave",
}

m["cjy"] = {
	canonicalName = "Jin",
	otherNames = {"Jinyu", "Jinhua", "Jinese", "Shanxinese", "Jin Chinese", "Jinyu Chinese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"ltc"},
}

m["ckb"] = {
	canonicalName = "Central Kurdish",
	otherNames = {"Sorani"},
	scripts = {"ku-Arab"},
	family = "ira",
	ancestors = {"ku"},
}

m["ckh"] = {
	canonicalName = "Chak",
	family = "sit",
	ancestors = {"kdv"},
}

m["ckl"] = {
	canonicalName = "Cibak",
	otherNames = {"Chibuk", "Chibok", "Chibbak", "Chibbuk", "Kyibaku", "Kibbaku", "Kibaku"},
	family = "cdc",
}

m["ckn"] = {
	canonicalName = "Kaang Chin",
	otherNames = {"Kaang"},
	family = "tbq-kuk",
}

m["cko"] = {
	canonicalName = "Anufo",
}

m["ckq"] = {
	canonicalName = "Kajakse",
}

m["ckr"] = {
	canonicalName = "Kairak",
}

m["cks"] = {
	canonicalName = "Tayo",
}

m["ckt"] = {
	canonicalName = "Chukchi",
	scripts = {"Cyrl"},
	family = "qfa-cka",
}

m["cku"] = {
	canonicalName = "Koasati",
	scripts = {"Latn"},
	family = "nai-mus",
}

m["ckv"] = {
	canonicalName = "Kavalan",
	otherNames = {"Kebalan"},
	scripts = {"Latn"},
	family = "map",
}

m["ckx"] = {
	canonicalName = "Caka",
	family = "nic-bod",
}

m["cky"] = {
	canonicalName = "Cakfem-Mushere",
}

m["ckz"] = {
	canonicalName = "Cakchiquel-Quiché Mixed Language",
	otherNames = {"Cauque Mayan"},
	family = "myn",
}

m["cla"] = {
	canonicalName = "Ron",
	otherNames = {"Bokkos", "Daffo-Butura", "Shagawu"},
	scripts = {"Latn"},
	family = "cdc",
}

m["clc"] = {
	canonicalName = "Chilcotin",
}

m["cld"] = {
	canonicalName = "Chaldean Neo-Aramaic",
	family = "sem-ara",
}

m["cle"] = {
	canonicalName = "Lealao Chinantec",
}

m["clh"] = {
	canonicalName = "Chilisso",
}

m["cli"] = {
	canonicalName = "Chakali",
}

m["clj"] = {
	canonicalName = "Laitu Chin",
	otherNames = {"Laitu"},
	family = "tbq-kuk",
}

m["clk"] = {
	canonicalName = "Idu",
	otherNames = {"Idu-Mishmi", "Idu Mishmi"},
}

m["cll"] = {
	canonicalName = "Chala",
}

m["clm"] = {
	canonicalName = "Klallam",
	otherNames = {"Clallam", "S'Klallam"},
}

m["clo"] = {
	canonicalName = "Lowland Oaxaca Chontal", -- distinguish chd, nai-teq
	otherNames = {"Oaxaca Chontal", "Oaxacan Chontal", "Chontal", "Huamelultec", "Huamelula Chontal", "Coastal Chontal"},
	scripts = {"Latn"},
	family = "nai-tqn",
}

m["clt"] = {
	canonicalName = "Lautu Chin",
	otherNames = {"Lautu"},
	family = "tbq-kuk",
}

m["clu"] = {
	canonicalName = "Caluyanun",
}

m["clw"] = {
	canonicalName = "Chulym",
	otherNames = {"Chulim", "Chulym-Turkic", "Küerik", "Chulym Tatar", "Melets Tatar"},
	family = "trk",
}

m["cly"] = {
	canonicalName = "Eastern Highland Chatino",
}

m["cma"] = {
	canonicalName = "Maa",
}

m["cme"] = {
	canonicalName = "Cerma",
}

m["cmg"] = {
	canonicalName = "Classical Mongolian",
	scripts = {"Mong"},
	family = "xgn",
	ancestors = {"xng"},
	translit_module = "mn-translit",
}

m["cmi"] = {
	canonicalName = "Emberá-Chamí",
}

m["cml"] = {
	canonicalName = "Campalagian",
}

m["cmm"] = {
	canonicalName = "Michigamea",
	family = "sio",
}

m["cmn"] = {
	canonicalName = "Mandarin",
	otherNames = {"Mandarin Chinese", "Putonghua", "Guoyu", "Huayu", "Guanhua", "Beifanghua", "Standard Chinese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"ltc"},
	wikimedia_codes = {"zh"},
}

m["cmo"] = {
	canonicalName = "Central Mnong",
}

m["cmr"] = {
	canonicalName = "Mro Chin",
	otherNames = {"Mro-Khimi Chin", "Mro", "Mro-Khimi"},
	family = "tbq-kuk",
}

m["cms"] = {
	canonicalName = "Messapic",
	otherNames = {"Messapian"},
	family = "ine",
}

m["cmt"] = {
	canonicalName = "Camtho",
}

m["cna"] = {
	canonicalName = "Changthang",
}

m["cnb"] = {
	canonicalName = "Chinbon Chin",
	otherNames = {"Chinbon"},
	family = "tbq-kuk",
}

m["cnc"] = {
	canonicalName = "Côông",
	family = "tbq-lol",
}

m["cng"] = {
	canonicalName = "Northern Qiang",
}

m["cnh"] = {
	canonicalName = "Lai",
	otherNames = {"Haka Chin", "Haka"},
	family = "tbq-kuk",
}

m["cni"] = {
	canonicalName = "Asháninka",
	otherNames = {"Ashaninka"},
	scripts = {"Latn"},
	family = "awd",
}

m["cnk"] = {
	canonicalName = "Khumi Chin",
	otherNames = {"Khumi", "Khami", "Nisay", "Nise", "Eastern Khumi", "Eastern Khumi Chin"},
	family = "tbq-kuk",
}

m["cnl"] = {
	canonicalName = "Lalana Chinantec",
}

m["cno"] = {
	canonicalName = "Con",
	family = "aav",
}

m["cns"] = {
	canonicalName = "Central Asmat",
}

m["cnt"] = {
	canonicalName = "Tepetotutla Chinantec",
}

m["cnu"] = {
	canonicalName = "Chenoua",
	otherNames = {"Shenwa"},
	family = "ber",
}

m["cnw"] = {
	canonicalName = "Ngawn Chin",
	otherNames = {"Ngawn"},
	family = "tbq-kuk",
}

m["cnx"] = {
	canonicalName = "Middle Cornish",
	family = "cel-bry",
	ancestors = {"oco"},
}

m["coa"] = {
	canonicalName = "Cocos Islands Malay",
}

m["cob"] = {
	canonicalName = "Chicomuceltec",
}

m["coc"] = {
	canonicalName = "Cocopa",
	scripts = {"Latn"},
	family = "nai-yuc",
}

m["cod"] = {
	canonicalName = "Cocama",
	otherNames = {"Kokama", "Kokáma", "Cocama-Cocamilla", "Kukama-Kukamiria", "Cocamilla", "Kokamíya", "Cocaima"},
}

m["coe"] = {
	canonicalName = "Koreguaje",
	family = "sai-tuc",
}

m["cof"] = {
	canonicalName = "Tsafiki",
	otherNames = {"Colorado", "Tsáchila"},
	scripts = {"Latn"},
	family = "sai-bar",
}

m["cog"] = {
	canonicalName = "Chong",
	scripts = {"Thai", "Khmr"},
	family = "aav",
}

m["coh"] = {
	canonicalName = "Chichonyi-Chidzihana-Chikauma",
}

m["coj"] = {
	canonicalName = "Cochimi",
	family = "nai-yuc",
}

m["cok"] = {
	canonicalName = "Santa Teresa Cora",
	scripts = {"Latn"},
	family = "azc",
}

m["col"] = {
	canonicalName = "Columbia-Wenatchi",
	otherNames = {"Columbia-Wenatchee", "Columbia-Moses", "Nxaamxcin", "Wenatchi", "Wenatchee"},
	scripts = {"Latn"},
	family = "sal",
}

m["com"] = {
	canonicalName = "Comanche",
	scripts = {"Latn"},
	family = "azc-num",
}

m["con"] = {
	canonicalName = "Cofán",
	otherNames = {"Cofan", "Kofan", "Kofane", "A'ingae", "Maku", "Macu"},
	family = "qfa-iso",
}

m["coo"] = {
	canonicalName = "Comox",
	scripts = {"Latn"},
	family = "sal",
}

m["cop"] = {
	canonicalName = "Coptic",
	otherNames = {"Akhmimic", "Assiutic", "Bashmuric", "Bohairic", "Faiyumic", "Fayyumic", "Lycopolitan", "Memphitic", "Mesokemic", "Oxyrhynchite", "Sahidic", "Subakhmimic", "Thebaic"}, -- Akhmimic etc are names of dialects which are currently, pending any suggestion that we should do otherwise, subsumed into this code
	scripts = {"Copt"},
	family = "egx",
	translit_module = "Copt-translit",
}

m["coq"] = {
	canonicalName = "Coquille",
	family = "ath-pco",
}

m["cot"] = {
	canonicalName = "Caquinte",
	family = "awd",
}

m["cou"] = {
	canonicalName = "Wamey",
}

m["cov"] = {
	canonicalName = "Cao Miao",
	family = "qfa-tak",
}

m["cow"] = {
	canonicalName = "Cowlitz",
	scripts = {"Latn"},
	family = "sal",
}

m["cox"] = {
	canonicalName = "Nanti",
	family = "awd",
}

m["coy"] = {
	canonicalName = "Coyaima",
	family = "sai-car",
}

m["coz"] = {
	canonicalName = "Chochotec",
}

m["cpa"] = {
	canonicalName = "Palantla Chinantec",
}

m["cpb"] = {
	canonicalName = "Ucayali-Yurúa Ashéninka",
	family = "awd",
}

m["cpc"] = {
	canonicalName = "Ajyíninka Apurucayali",
	family = "awd",
}

m["cpg"] = {
	canonicalName = "Cappadocian Greek",
	otherNames = {"Cappadocian"},
	scripts = {"polytonic"},
	family = "grk",
	ancestors = {"grc"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, grc, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
}

m["cpi"] = {
	canonicalName = "Chinese Pidgin English",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["cpn"] = {
	canonicalName = "Cherepon",
}

m["cpo"] = {
	canonicalName = "Kpee",
	otherNames = {"Kpeego", "Kpeen", "Numu"},
}

m["cps"] = {
	canonicalName = "Capiznon",
}

m["cpu"] = {
	canonicalName = "Pichis Ashéninka",
	family = "awd",
}

m["cpx"] = {
	canonicalName = "Pu Xian",
	otherNames = {"Pu Xian Chinese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"zhx-min-pro"},
}

m["cpy"] = {
	canonicalName = "South Ucayali Ashéninka",
	family = "awd",
}

m["cqd"] = {
	canonicalName = "Chuanqiandian Cluster Miao",
	scripts = {"Latn", "Plrd"},
	family = "hmn",
}

m["cra"] = {
	canonicalName = "Chara",
}

m["crb"] = {
	canonicalName = "Island Carib",
	family = "awd",
}

m["crc"] = {
	canonicalName = "Lonwolwol",
}

m["crd"] = {
	canonicalName = "Coeur d'Alene",
}

m["crf"] = {
	canonicalName = "Caramanta",
}

m["crg"] = {
	canonicalName = "Michif",
	scripts = {"Latn"},
	family = "qfa-mix",
}

m["crh"] = {
	canonicalName = "Crimean Tatar",
	scripts = {"Latn", "Cyrl"},
	family = "trk",
}

m["cri"] = {
	canonicalName = "Sãotomense",
	otherNames = {"Forro", "São Tomense"},
	scripts = {"Latn"},
}

m["crj"] = {
	canonicalName = "Southern East Cree",
	scripts = {"Cans"},
	family = "alg",
	ancestors = {"cr"},
}

m["crk"] = {
	canonicalName = "Plains Cree",
	scripts = {"Cans", "Latn"},
	family = "alg",
	ancestors = {"cr"},
}

m["crl"] = {
	canonicalName = "Northern East Cree",
	scripts = {"Cans"},
	family = "alg",
	ancestors = {"cr"},
}

m["crm"] = {
	canonicalName = "Moose Cree",
	scripts = {"Cans"},
	family = "alg",
	ancestors = {"cr"},
}

m["crn"] = {
	canonicalName = "Cora",
	scripts = {"Latn"},
	family = "azc",
}

m["cro"] = {
	canonicalName = "Crow",
	family = "sio",
}

m["crq"] = {
	canonicalName = "Iyo'wujwa Chorote",
	family = "sai-mtc",
}

m["crr"] = {
	canonicalName = "Carolina Algonquian",
	scripts = {"Latn"},
	family = "alg",
}

m["crs"] = {
	canonicalName = "Seychellois Creole",
}

m["crt"] = {
	canonicalName = "Iyojwa'ja Chorote",
	family = "sai-mtc",
}

m["crv"] = {
	canonicalName = "Chaura",
	otherNames = {"Tutet"},
	family = "aav",
}

m["crw"] = {
	canonicalName = "Chrau",
}

m["crx"] = {
	canonicalName = "Carrier",
}

m["cry"] = {
	canonicalName = "Cori",
}

m["crz"] = {
	canonicalName = "Cruzeño",
	family = "nai-chu",
}

m["csa"] = {
	canonicalName = "Chiltepec Chinantec",
}

m["csb"] = {
	canonicalName = "Kashubian",
	scripts = {"Latn"},
	family = "zlw",
	ancestors = {"zlw-pom"},
}

m["csc"] = {
	canonicalName = "Catalan Sign Language",
	family = "sgn",
}

m["csd"] = {
	canonicalName = "Chiangmai Sign Language",
	family = "sgn",
}

m["cse"] = {
	canonicalName = "Czech Sign Language",
	family = "sgn",
}

m["csf"] = {
	canonicalName = "Cuban Sign Language",
	family = "sgn",
}

m["csg"] = {
	canonicalName = "Chilean Sign Language",
	family = "sgn",
}

m["csh"] = {
	canonicalName = "Asho Chin",
	otherNames = {"Asho"},
	family = "tbq-kuk",
}

m["csi"] = {
	canonicalName = "Coast Miwok",
	family = "nai-you",
}

m["csj"] = {
	canonicalName = "Songlai Chin",
	otherNames = {"Songlai"},
	family = "tbq-kuk",
}

m["csk"] = {
	canonicalName = "Jola-Kasa",
}

m["csl"] = {
	canonicalName = "Chinese Sign Language",
	family = "sgn",
}

m["csm"] = {
	canonicalName = "Central Sierra Miwok",
	scripts = {"Latn"},
	family = "nai-you",
}

m["csn"] = {
	canonicalName = "Colombian Sign Language",
	family = "sgn",
}

m["cso"] = {
	canonicalName = "Sochiapam Chinantec",
}

m["csq"] = {
	canonicalName = "Croatian Sign Language",
	family = "sgn",
}

m["csr"] = {
	canonicalName = "Costa Rican Sign Language",
	family = "sgn",
}

m["css"] = {
	canonicalName = "Southern Ohlone",
	scripts = {"Latn"},
	family = "nai-you",
}

m["cst"] = {
	canonicalName = "Northern Ohlone",
	scripts = {"Latn"},
	family = "nai-you",
}

m["csv"] = {
	canonicalName = "Sumtu Chin",
	otherNames = {"Sumtu"},
	family = "tbq-kuk",
}

m["csw"] = {
	canonicalName = "Swampy Cree",
	family = "alg",
	ancestors = {"cr"},
}

m["csy"] = {
	canonicalName = "Siyin Chin",
	otherNames = {"Siyin"},
	family = "tbq-kuk",
}

m["csz"] = {
	canonicalName = "Coos",
	otherNames = {"Hanis", "Hanis Coos"},
	scripts = {"Latn"},
}

m["cta"] = {
	canonicalName = "Tataltepec Chatino",
}

m["ctc"] = {
	canonicalName = "Chetco-Tolowa",
	otherNames = {"Chetco", "Siletz Dee-ni", "Deeni", "Tututni", "Siletz"},
	scripts = {"Latn"},
}

m["ctd"] = {
	canonicalName = "Tedim Chin",
	otherNames = {"Tedim", "Tiddim", "Sukte"},
	family = "tbq-kuk",
}

m["cte"] = {
	canonicalName = "Tepinapa Chinantec",
}

m["ctg"] = {
	canonicalName = "Chittagonian",
	scripts = {"Beng"},
	family = "inc",
	ancestors = {"pka"},
}

m["cth"] = {
	canonicalName = "Thaiphum Chin",
	otherNames = {"Thaiphum"},
	family = "tbq-kuk",
}

m["ctl"] = {
	canonicalName = "Tlacoatzintepec Chinantec",
}

m["ctm"] = {
	canonicalName = "Chitimacha",
}

m["ctn"] = {
	canonicalName = "Chhintange",
}

m["cto"] = {
	canonicalName = "Emberá-Catío",
}

m["ctp"] = {
	canonicalName = "Western Highland Chatino",
}

m["cts"] = {
	canonicalName = "Northern Catanduanes Bicolano",
}

m["ctt"] = {
	canonicalName = "Wayanad Chetti",
	otherNames = {"Chetti"},
	family = "dra",
}

m["ctu"] = {
	canonicalName = "Chol",
	scripts = {"Latn"},
	family = "myn",
}

m["ctz"] = {
	canonicalName = "Zacatepec Chatino",
}

m["cua"] = {
	canonicalName = "Cua",
}

m["cub"] = {
	canonicalName = "Cubeo",
	otherNames = {"Cuveo", "Kubéo", "Kubeo", "Kubéu", "Kubeu", "Cobewa", "Cobéua", "Cobeua", "Kubéwa", "Kubewa", "Kobéua", "Kobeua", "Kobewa", "Pamiwa"},
	family = "sai-tuc",
}

m["cuc"] = {
	canonicalName = "Usila Chinantec",
}

m["cug"] = {
	canonicalName = "Cung",
	family = "nic-bod",
}

m["cuh"] = {
	canonicalName = "Chuka",
}

m["cui"] = {
	canonicalName = "Cuiba",
	scripts = {"Latn"},
	family = "sai-guh",
}

m["cuj"] = {
	canonicalName = "Mashco Piro",
	family = "awd",
}

m["cuk"] = {
	canonicalName = "Kuna",
	scripts = {"Latn"},
	family = "cba",
}

m["cul"] = {
	canonicalName = "Culina",
	otherNames = {"Kulina", "Kulína", "Kulyna", "Curina", "Corina", "Korina", "Culina-Madijá", "Madijá", "Madija", "Madiha", "Madihá"},
	scripts = {"Latn"},
	family = "auf",
}

m["cuo"] = {
	canonicalName = "Cumanagoto",
	otherNames = {"Cumanogota", "Cumana", "Cumaná", "Kumana", "Kumaná"},
	scripts = {"Latn"},
	family = "sai-cpc",
}

m["cup"] = {
	canonicalName = "Cupeño",
	scripts = {"Latn"},
	family = "azc-cup",
}

m["cuq"] = {
	canonicalName = "Cun",
}

m["cur"] = {
	canonicalName = "Chhulung",
}

m["cut"] = {
	canonicalName = "Teutila Cuicatec",
}

m["cuu"] = {
	canonicalName = "Tai Ya",
}

m["cuv"] = {
	canonicalName = "Cuvok",
}

m["cuw"] = {
	canonicalName = "Chukwa",
}

m["cux"] = {
	canonicalName = "Tepeuxila Cuicatec",
}

m["cvg"] = {
	canonicalName = "Chug",
}

m["cvn"] = {
	canonicalName = "Valle Nacional Chinantec",
}

m["cwa"] = {
	canonicalName = "Kabwa",
}

m["cwb"] = {
	canonicalName = "Maindo",
}

m["cwd"] = {
	canonicalName = "Woods Cree",
	family = "alg",
	ancestors = {"cr"},
}

m["cwe"] = {
	canonicalName = "Kwere",
}

m["cwg"] = {
	canonicalName = "Chewong",
	otherNames = {"Cheq Wong", "Cheq-Wong", "Ceq Wong"},
}

m["cwt"] = {
	canonicalName = "Kuwaataay",
}

m["cya"] = {
	canonicalName = "Nopala Chatino",
}

m["cyb"] = {
	canonicalName = "Cayubaba",
	family = "qfa-iso",
}

m["cyo"] = {
	canonicalName = "Cuyunon",
}

m["czh"] = {
	canonicalName = "Huizhou",
	otherNames = {"Huizhou Chinese"},
	ancestors = {"ltc"},
}

m["czk"] = {
	canonicalName = "Knaanic",
	scripts = {"Hebr"},
	ancestors = {"zlw-ocs"},
	family = "zlw",
}

m["czn"] = {
	canonicalName = "Zenzontepec Chatino",
}

m["czo"] = {
	canonicalName = "Min Zhong",
	otherNames = {"Min Zhong Chinese"},
	family = "zhx",
	ancestors = {"zhx-min-pro"},
}

m["czt"] = {
	canonicalName = "Zotung Chin",
	otherNames = {"Zotung"},
	family = "tbq-kuk",
}

return m