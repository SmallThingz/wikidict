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

m["ebg"] = {
	canonicalName = "Ebughu",
}

m["ebk"] = {
	canonicalName = "Eastern Bontoc",
	otherNames = {"Eastern Bontok"},
}

m["ebo"] = {
	canonicalName = "Teke-Ebo",
}

m["ebr"] = {
	canonicalName = "Ebrié",
}

m["ebu"] = {
	canonicalName = "Embu",
}

m["ecr"] = {
	canonicalName = "Eteocretan",
	scripts = {"Grek"},
}

m["ecs"] = {
	canonicalName = "Ecuadorian Sign Language",
	family = "sgn",
}

m["ecy"] = {
	canonicalName = "Eteocypriot",
	scripts = {"Cprt"},
}

m["eee"] = {
	canonicalName = "E",
	otherNames = {"Kjang E"},
	family = "qfa-mix",
}

m["efa"] = {
	canonicalName = "Efai",
}

m["efe"] = {
	canonicalName = "Efe",
}

m["efi"] = {
	canonicalName = "Efik",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ega"] = {
	canonicalName = "Ega",
}

m["egl"] = {
	canonicalName = "Emilian",
	otherNames = {"Emiliano"},
	scripts = {"Latn"},
	family = "roa",
	wikimedia_codes = {"eml"},
}

m["ego"] = {
	canonicalName = "Eggon",
}

m["egy"] = {
	canonicalName = "Egyptian",
	otherNames = {"Ancient Egyptian"},
	scripts = {"Latn", "Egyp", "Egyd"},
	family = "egx",
}

m["ehu"] = {
	canonicalName = "Ehueun",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["eip"] = {
	canonicalName = "Eipomek",
}

m["eit"] = {
	canonicalName = "Eitiep",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["eiv"] = {
	canonicalName = "Askopan",
}

m["eja"] = {
	canonicalName = "Ejamat",
}

m["eka"] = {
	canonicalName = "Ekajuk",
	family = "nic-bod",
}

m["eke"] = {
	canonicalName = "Ekit",
}

m["ekg"] = {
	canonicalName = "Ekari",
	scripts = {"Latn"},
	family = "ngf",
}

m["eki"] = {
	canonicalName = "Eki",
}

m["ekl"] = {
	canonicalName = "Kolhe",
	otherNames = {"Kol", "Kol (Bangladesh)"},
}

m["ekm"] = {
	canonicalName = "Elip",
	family = "nic-bod",
}

m["eko"] = {
	canonicalName = "Koti",
}

m["ekp"] = {
	canonicalName = "Ekpeye",
}

m["ekr"] = {
	canonicalName = "Yace",
}

m["eky"] = {
        canonicalName = "Eastern Kayah",
        scripts = {"Kali"},
        family = "kar",
}

m["ele"] = {
	canonicalName = "Elepi",
	family = "qfa-tor",
}

m["elh"] = {
	canonicalName = "El Hugeirat",
}

m["eli"] = {
	canonicalName = "Nding",
}

m["elk"] = {
	canonicalName = "Elkei",
	family = "qfa-tor",
}

m["elm"] = {
	canonicalName = "Eleme",
	family = "nic-bco",
}

m["elo"] = {
	canonicalName = "El Molo",
	family = "cus",
}

m["elu"] = {
	canonicalName = "Elu",
	family = "poz-aay",
}

m["elx"] = {
	canonicalName = "Elamite",
	scripts = {"Xsux"},
	family = "qfa-iso",
}

m["ema"] = {
	canonicalName = "Emai",
	otherNames = {"Aoma", "Ora", "Emai-Iuleha-Ora"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["emb"] = {
	canonicalName = "Embaloh",
	otherNames = {"Maloh", "Malo", "Matoh", "Mbaloh", "Memaloh", "Palin", "Pari", "Sangau", "Sanggau", "Kalis"},
}

m["eme"] = {
	canonicalName = "Emerillon",
}

m["emg"] = {
	canonicalName = "Eastern Meohang",
}

m["emi"] = {
	canonicalName = "Mussau-Emira",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["emk"] = {
	canonicalName = "Eastern Maninkakan",
}

m["emm"] = {
	canonicalName = "Mamulique",
}

m["emn"] = {
	canonicalName = "Eman",
	family = "nic-bod",
}

m["emp"] = {
	canonicalName = "Northern Emberá",
}

m["ems"] = {
	canonicalName = "Alutiiq",
	scripts = {"Latn"},
	family = "ypk",
}

m["emu"] = {
	canonicalName = "Eastern Muria",
	family = "dra",
	ancestors = {"gon"},
}

m["emw"] = {
	canonicalName = "Emplawas",
}

m["emx"] = {
	canonicalName = "Erromintxela",
}

m["emy"] = {
	canonicalName = "Epigraphic Mayan",
	otherNames = {"Classic Ch'olti'an", "Ch'olti'"},
	scripts = {"Maya"},
	family = "myn",
}

m["ena"] = {
	canonicalName = "Apali",
}

m["enb"] = {
	canonicalName = "Markweeta",
	family = "sdv",
}

m["enc"] = {
	canonicalName = "En",
}

m["end"] = {
	canonicalName = "Ende",
	scripts = {"Latn"},
	family = "plf",
}

m["enf"] = {
	canonicalName = "Forest Enets",
}

m["enh"] = {
	canonicalName = "Tundra Enets",
}

m["enl"] = {
	canonicalName = "Enlhet",
	otherNames = {"Lengua"},
}

m["enm"] = {
	canonicalName = "Middle English",
	otherNames = {"Medieval English", "Mediaeval English"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"ang"},
	entry_name = {
		from = {"Ā", "ā", "Ǣ", "ǣ", "Ċ", "ċ", "Ē", "ē", "Ġ", "ġ", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ", "Á", "á", "Ǽ", "ǽ", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", "Ý", "ý", "Ė"},
		to   = {"A", "a", "Æ", "æ", "C", "c", "E", "e", "G", "g", "I", "i", "O", "o", "U", "u", "Y", "y", "A", "a", "Æ", "æ", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y", "ė"}} ,
}

m["enn"] = {
	canonicalName = "Engenni",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["eno"] = {
	canonicalName = "Enggano",
	family = "poz",
}

m["enq"] = {
	canonicalName = "Enga",
}

m["enr"] = {
	canonicalName = "Emem",
}

m["enu"] = {
	canonicalName = "Enu",
	family = "tbq-lol",
}

m["env"] = {
	canonicalName = "Enwan",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["enw"] = {
	canonicalName = "Enwang",
	otherNames = {"Enwan"},
	family = "nic-bco",
}

m["enx"] = {
	canonicalName = "Enxet",
	otherNames = {"Lengua"},
}

m["eot"] = {
	canonicalName = "Eotile",
	otherNames = {"Beti"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["epi"] = {
	canonicalName = "Epie",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["era"] = {
	canonicalName = "Eravallan",
	family = "dra",
}

m["erg"] = {
	canonicalName = "Sie",
}

m["erh"] = {
	canonicalName = "Eruwa",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["eri"] = {
	canonicalName = "Ogea",
}

m["erk"] = {
	canonicalName = "South Efate",
	otherNames = {"Efate", "Vate", "Vaté"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["ero"] = {
	canonicalName = "Horpa",
}

m["err"] = {
	canonicalName = "Erre",
}

m["ers"] = {
	canonicalName = "Ersu",
	otherNames = {"Duoxu", "Erhsu"},
	scripts = {"Latn"}, -- also Ersu Shaba
	family = "sit-qia",
}

m["ert"] = {
	canonicalName = "Eritai",
}

m["erw"] = {
	canonicalName = "Erokwanas",
	family = "poz-hce",
}

m["ese"] = {
	canonicalName = "Ese Ejja",
	otherNames = {"Tiatinagua"},
	family = "sai-tac",
}

m["esh"] = {
	canonicalName = "Eshtehardi",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"ira-azr"},
}

m["esi"] = {
	canonicalName = "North Alaskan Inupiatun",
	scripts = {"Latn"},
	family = "esx-inu",
}

m["esk"] = {
	canonicalName = "Northwest Alaska Inupiatun",
	family = "esx-inu",
}

m["esl"] = {
	canonicalName = "Egyptian Sign Language",
	family = "sgn",
}

m["esm"] = {
	canonicalName = "Esuma",
}

m["esn"] = {
	canonicalName = "Salvadoran Sign Language",
	family = "sgn",
}

m["eso"] = {
	canonicalName = "Estonian Sign Language",
	family = "sgn",
}

m["esq"] = {
	canonicalName = "Esselen",
}

m["ess"] = {
	canonicalName = "Central Siberian Yupik",
	otherNames = {"Central Siberian Yup'ik", "St. Lawrence Yupik", "St. Lawrence Yup'ik", "St. Lawrence Eskimo", "Siberian Yupik", "Siberian Yup'ik", "Siberian Yupik Eskimo", "Siberian Yup'ik Eskimo", "St. Lawrence Island Eskimo", "St. Lawrence Island Yupik", "St. Lawrence Island Yup'ik"},
	scripts = {"Cyrl"},
	family = "ypk",
}

m["esu"] = {
	canonicalName = "Yup'ik",
	scripts = {"Latn"},
	family = "ypk",
}

m["esy"] = {
	canonicalName = "Eskayan",
	scripts = {"Latn"}, -- also its own native script
	family = "art",
}

m["etb"] = {
	canonicalName = "Etebi",
}

m["etc"] = {
	canonicalName = "Etchemin",
	family = "alg",
}

m["eth"] = {
	canonicalName = "Ethiopian Sign Language",
	family = "sgn",
}

m["etn"] = {
	canonicalName = "Eton (Vanuatu)",
	otherNames = {"Eton"},
	family = "poz-oce",
}

m["eto"] = {
	canonicalName = "Eton (Cameroon)",
	otherNames = {"Eton"},
	scripts = {"Latn"},
	family = "bnt",
}

m["etr"] = {
	canonicalName = "Edolo",
}

m["ets"] = {
	canonicalName = "Yekhee",
	otherNames = {"Afenmai", "Afemai", "Etsako"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ett"] = {
	canonicalName = "Etruscan",
	scripts = {"Ital"},
	family = "qfa-tyn",
	translit_module = "Ital-translit",
}

m["etu"] = {
	canonicalName = "Ejagham",
	family = "nic-bod",
}

m["etx"] = {
	canonicalName = "Eten",
}

m["etz"] = {
	canonicalName = "Semimi",
}

m["eve"] = {
	canonicalName = "Even",
	family = "tuw",
}

m["evh"] = {
	canonicalName = "Uvbie",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["evn"] = {
	canonicalName = "Evenki",
	scripts = {"Cyrl"},
	family = "tuw",
}

m["ewo"] = {
	canonicalName = "Ewondo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ext"] = {
	canonicalName = "Extremaduran",
	scripts = {"Latn"},
	family = "roa",
}

m["eya"] = {
	canonicalName = "Eyak",
	family = "xnd",
}

m["eyo"] = {
	canonicalName = "Keiyo",
	family = "sdv",
}

m["eza"] = {
	canonicalName = "Ezaa",
	otherNames = {"Ezza", "Eza"},
	family = "alv-von",
}

m["eze"] = {
	canonicalName = "Uzekwe",
	family = "nic-bco",
}

return m