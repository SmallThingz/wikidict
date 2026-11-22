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

m["uam"] = {
	canonicalName = "Uamué",
}

m["uan"] = {
	canonicalName = "Kuan",
}

m["uar"] = {
	canonicalName = "Tairuma",
}

m["uba"] = {
	canonicalName = "Ubang",
	family = "nic-bco",
}

m["ubi"] = {
	canonicalName = "Ubi",
}

m["ubl"] = {
	canonicalName = "Buhi'non Bikol",
}

m["ubr"] = {
	canonicalName = "Ubir",
	family = "poz-ocw",
}

m["ubu"] = {
	canonicalName = "Umbu-Ungu",
}

m["uby"] = {
	canonicalName = "Ubykh",
	scripts = {"Latn", "Cyrl"},
	family = "cau-nwc",
}

m["uda"] = {
	canonicalName = "Uda",
}

m["ude"] = {
	canonicalName = "Udihe",
	otherNames = {"Udege", "Udekhe", "Udeghe"},
	scripts = {"Cyrl"},
	family = "tuw",
}

m["udg"] = {
	canonicalName = "Muduga",
	family = "dra",
}

m["udi"] = {
	canonicalName = "Udi",
	scripts = {"Cyrl", "Latn", "Armn", "Geor"},
	family = "cau-nec",
	ancestors = {"xag"},
	translit_module = "udi-translit"
}

m["udj"] = {
	canonicalName = "Ujir",
}

m["udl"] = {
	canonicalName = "Uldeme",
}

m["udm"] = {
	canonicalName = "Udmurt",
	scripts = {"Cyrl"},
	family = "fiu-prm",
	translit_module = "udm-translit"
}

m["udu"] = {
	canonicalName = "Uduk",
}

m["ues"] = {
	canonicalName = "Kioko",
}

m["ufi"] = {
	canonicalName = "Ufim",
	family = "ngf-fin",
}

m["uga"] = {
	canonicalName = "Ugaritic",
	scripts = {"Ugar"},
	family = "sem-nwe",
	translit_module = "uga-translit",
}

m["ugb"] = {
	canonicalName = "Kuku-Ugbanh",
}

m["uge"] = {
	canonicalName = "Ughele",
	family = "poz-ocw",
}

m["ugn"] = {
	canonicalName = "Ugandan Sign Language",
	family = "sgn",
}

m["ugo"] = {
	canonicalName = "Ugong",
}

m["ugy"] = {
	canonicalName = "Uruguayan Sign Language",
	family = "sgn",
}

m["uha"] = {
	canonicalName = "Uhami",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["uhn"] = {
	canonicalName = "Damal",
}

m["uis"] = {
	canonicalName = "Uisai",
}

m["uiv"] = {
	canonicalName = "Iyive",
	family = "nic-bod",
}

m["uji"] = {
	canonicalName = "Tanjijili",
}

m["uka"] = {
	canonicalName = "Kaburi",
}

m["ukg"] = {
	canonicalName = "Ukuriguma",
}

m["ukh"] = {
	canonicalName = "Ukhwejo",
}

m["ukl"] = {
	canonicalName = "Ukrainian Sign Language",
	family = "sgn",
}

m["ukp"] = {
	canonicalName = "Ukpe-Bayobiri",
	family = "nic-bco",
}

m["ukq"] = {
	canonicalName = "Ukwa",
}

m["uks"] = {
	canonicalName = "Kaapor Sign Language",
	family = "sgn",
}

m["uku"] = {
	canonicalName = "Ukue",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ukw"] = {
	canonicalName = "Ukwuani-Aboh-Ndoni",
	family = "alv",
}

m["uky"] = {
	canonicalName = "Kuuk Yak",
	family = "aus-psw",
}

m["ula"] = {
	canonicalName = "Fungwa",
	otherNames = {"Ula", "Ura"},
	family = "nic-bco",
}

m["ulb"] = {
	canonicalName = "Ulukwumi",
}

m["ulc"] = {
	canonicalName = "Ulch",
	family = "tuw",
}

m["ule"] = {
	canonicalName = "Lule",
	scripts = {"Latn"},
}

m["ulf"] = {
	canonicalName = "Afra",
}

m["uli"] = {
	canonicalName = "Ulithian",
	family = "poz-mic",
}

m["ulk"] = {
	canonicalName = "Meriam",
	scripts = {"Latn"},
	family = "ngf",
}

m["ull"] = {
	canonicalName = "Ullatan",
	family = "dra",
}

m["ulm"] = {
	canonicalName = "Ulumanda'",
}

m["uln"] = {
	canonicalName = "Unserdeutsch",
	otherNames = {"Rabaul Creole German"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"de"},
}

m["ulu"] = {
	canonicalName = "Uma' Lung",
	family = "poz-swa",
}

m["ulw"] = {
	canonicalName = "Ulwa",
}

m["uma"] = {
	canonicalName = "Umatilla",
	family = "nai-shp",
}

m["umb"] = {
	canonicalName = "Umbundu",
	otherNames = {"South Mbundu"},
	scripts = {"Latn"},
	family = "bnt",
}

m["umc"] = {
	canonicalName = "Marrucinian",
	scripts = {"Latn", "Ital"},
	family = "itc",
}

m["umd"] = {
	canonicalName = "Umbindhamu",
}

m["umg"] = {
	canonicalName = "Umbuygamu",
}

m["umi"] = {
	canonicalName = "Ukit",
}

m["umm"] = {
	canonicalName = "Umon",
	family = "nic-bco",
}

m["umn"] = {
	canonicalName = "Makyan Naga",
}

m["umo"] = {
	canonicalName = "Umotína",
}

m["ump"] = {
	canonicalName = "Umpila",
}

m["umr"] = {
	canonicalName = "Umbugarla",
}

m["ums"] = {
	canonicalName = "Pendau",
}

m["umu"] = {
	canonicalName = "Munsee",
	scripts = {"Latn"},
	family = "del",
}

m["una"] = {
	canonicalName = "North Watut",
	family = "poz-ocw",
}

m["und"] = {
	canonicalName = "Undetermined",
	scripts = {"Zyyy"},
	family = "qfa-not",
}

m["une"] = {
	canonicalName = "Uneme",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ung"] = {
	canonicalName = "Ngarinyin",
	otherNames = {"Ungarinjin"},
}

m["unk"] = {
	canonicalName = "Enawené-Nawé",
	family = "awd",
}

m["unm"] = {
	canonicalName = "Unami",
	scripts = {"Latn"},
	family = "del",
	entry_name = {
		from = {"À", "Ä", "È", "Ë", "Ì", "Ò", "Ù", "à", "ä", "è", "ë", "ì", "ò", "ù"},
		to   = {"A", "A", "E", "E", "I", "O", "U", "a", "a", "e", "e", "i", "o", "u"}} ,
}

m["unn"] = {
	canonicalName = "Kurnai",
	otherNames = {"Gunai", "Gaanay", "Ganai", "Gunnai'", "Kurnay", "Bidhawal", "Birrdhawal", "Muk-thang", "Nulit", "Thangquai"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["unr"] = {
	canonicalName = "Mundari",
	family = "mun",
}

m["unu"] = {
	canonicalName = "Unubahe",
}

m["unx"] = {
	canonicalName = "Munda",
	family = "mun",
}

m["unz"] = {
	canonicalName = "Unde Kaili",
	otherNames = {"Banava", "Ndepuu", "West Kaili", "Lole", "Ganti"},
	scripts = {"Latn"},
	family = "poz-kal",
}

m["uok"] = {
	canonicalName = "Uokha",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["upi"] = {
	canonicalName = "Umeda",
}

m["upv"] = {
	canonicalName = "Uripiv-Wala-Rano-Atchin",
	family = "poz-vnc",
}

m["ura"] = {
	canonicalName = "Urarina",
}

m["urb"] = {
	canonicalName = "Urubú-Kaapor",
	scripts = {"Latn"},
	family = "tup",
}

m["urc"] = {
	canonicalName = "Urningangg",
}

m["ure"] = {
	canonicalName = "Uru",
}

m["urf"] = {
	canonicalName = "Uradhi",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["urg"] = {
	canonicalName = "Urigina",
	family = "ngf",
}

m["urh"] = {
	canonicalName = "Urhobo",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["uri"] = {
	canonicalName = "Urim",
	family = "qfa-tor",
}

m["urk"] = {
	canonicalName = "Urak Lawoi'",
}

m["url"] = {
	canonicalName = "Urali",
	scripts = {"Knda"},
	family = "dra",
}

m["urm"] = {
	canonicalName = "Urapmin",
}

m["urn"] = {
	canonicalName = "Uruangnirin",
	scripts = {"Latn"},
	family = "plf",
}

m["uro"] = {
	canonicalName = "Ura (New Guinea)",
	otherNames = {"Ura (Papua New Guinea)"},
	family = "paa",
}

m["urp"] = {
	canonicalName = "Uru-Pa-In",
}

m["urr"] = {
	canonicalName = "Lehalurup",
}

m["urt"] = {
	canonicalName = "Urat",
	family = "qfa-tor",
}

m["uru"] = {
	canonicalName = "Urumi",
}

m["urv"] = {
	canonicalName = "Uruava",
	family = "poz-ocw",
}

m["urw"] = {
	canonicalName = "Sop",
}

m["urx"] = {
	canonicalName = "Urimo",
	family = "qfa-tor",
}

m["ury"] = {
	canonicalName = "Orya",
}

m["urz"] = {
	canonicalName = "Uru-Eu-Wau-Wau",
}

m["usa"] = {
	canonicalName = "Usarufa",
}

m["ush"] = {
	canonicalName = "Ushojo",
}

m["usi"] = {
	canonicalName = "Usui",
}

m["usk"] = {
	canonicalName = "Usaghade",
}

m["usp"] = {
	canonicalName = "Uspanteco",
}

m["usu"] = {
	canonicalName = "Uya",
}

m["uta"] = {
	canonicalName = "Otank",
	family = "nic-bod",
}

m["ute"] = {
	canonicalName = "Ute",
	otherNames = {"Southern Paiute", "Colorado River Numic", "Chemehuevi"},
	scripts = {"Latn"},
	family = "azc-num",
}

m["utp"] = {
	canonicalName = "Aba",
	otherNames = {"Amba", "Nebao", "Nembao"},
	scripts = {"Latn"},
	family = "poz-oce",
}

m["utr"] = {
	canonicalName = "Etulo",
	scripts = {"Latn"},
	family = "alv",
}

m["utu"] = {
	canonicalName = "Utu",
}

m["uum"] = {
	canonicalName = "Urum",
	scripts = {"Cyrl"},
	family = "trk",
}

m["uun"] = {
	canonicalName = "Kulon-Pazeh",
	otherNames = {"Pazeh", "Pazih", "Kulun", "Kulon"},
	scripts = {"Latn"},
	family = "map",
}

m["uur"] = {
	canonicalName = "Ura (Vanuatu)",
	family = "poz-oce",
}

m["uuu"] = {
	canonicalName = "U",
	otherNames = {"P'uman"},
	family = "aav",
}

m["uve"] = {
	canonicalName = "West Uvean",
	otherNames = {"Uvean", "Faga Ouvéa", "Fagauvea"},
	family = "poz-pol",
}

m["uvh"] = {
	canonicalName = "Uri",
	family = "ngf-fin",
}

m["uvl"] = {
	canonicalName = "Lote",
	family = "poz-ocw",
}

m["uwa"] = {
	canonicalName = "Kuku-Uwanh",
}

m["uya"] = {
	canonicalName = "Doko-Uyanga",
	family = "nic-bco",
}

return m