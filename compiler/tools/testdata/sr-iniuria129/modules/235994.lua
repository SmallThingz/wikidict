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

m["uam"] = {
	"Uamué",
	"Q3441418",
}

m["uan"] = {
	"Kuan",
	"Q6441085",
}

m["uar"] = {
	"Tairuma",
	"Q7676386",
	"ngf",
}

m["uba"] = {
	"Ubang",
	"Q3914467",
	"nic-ben",
	scripts = Latn,
}

m["ubi"] = {
	"Ubi",
	"Q56264",
}

m["ubl"] = {
	"Buhi'non Bikol",
	"Q18664494",
	"phi",
}

m["ubr"] = {
	"Ubir",
	"Q3547642",
	"poz-ocw",
	scripts = Latn,
}

m["ubu"] = {
	"Umbu-Ungu",
	"Q12953245",
	"ngf",
}

m["uby"] = {
	"Ubykh",
	"Q36931",
	"cau-nwc",
	scripts = {"Latn", "Cyrl"},
}

m["uda"] = {
	"Uda",
	"Q11011951",
	"nic-lcr",
}

m["ude"] = {
	"Udihe",
	"Q13235",
	"tuw",
	otherNames = {"Udege", "Udekhe", "Udeghe"},
	scripts = {"Cyrl"},
}

m["udg"] = {
	"Muduga",
	"Q16886762",
	"dra",
}

m["udi"] = {
	"Udi",
	"Q36867",
	"cau-nec",
	scripts = {"Cyrl", "Latn", "Armn", "Geor"},
	ancestors = {"xag"},
	translit_module = "translit-redirect",
	override_translit = true,
}

m["udj"] = {
	"Ujir",
	"Q14916906",
}

m["udl"] = {
	"Uldeme",
	"Q3515078",
	"cdc-cbm",
}

m["udm"] = {
	"Udmurt",
	"Q13238",
	"urj-prm",
	scripts = {"Cyrl"},
	translit_module = "udm-translit",
	override_translit = true,
}

m["udu"] = {
	"Uduk",
	"Q3182573",
}

m["ues"] = {
	"Kioko",
	"Q18343036",
}

m["ufi"] = {
	"Ufim",
	"Q7877531",
	"ngf-fin",
	scripts = Latn,
}

m["uga"] = {
	"Ugaritic",
	"Q36928",
	"sem-nwe",
	scripts = {"Ugar"},
	translit_module = "uga-translit",
}

m["ugb"] = {
	"Kuku-Ugbanh",
	"Q10549854",
}

m["uge"] = {
	"Ughele",
	"Q966303",
	"poz-ocw",
}

m["ugn"] = {
	"Ugandan Sign Language",
	"Q7877677",
	"sgn",
}

m["ugo"] = {
	"Gong",
	"Q3448919",
	"tbq-lob",
	otherNames = {"Ugong"},
	scripts = {"Thai"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["ugy"] = {
	"Uruguayan Sign Language",
	"Q7901470",
	"sgn",
}

m["uha"] = {
	"Uhami",
	"Q3913328",
	"alv-nwd",
	scripts = Latn,
}

m["uhn"] = {
	"Damal",
	"Q4748974",
}

m["uis"] = {
	"Uisai",
	"Q7878123",
	"paa-sbo",
}

m["uiv"] = {
	"Iyive",
	"Q11128658",
	"nic-tvc",
	scripts = Latn,
}

m["uji"] = {
	"Tanjijili",
	"Q3914939",
	"nic-pls",
}

m["uka"] = {
	"Kaburi",
	"Q6344482",
}

m["ukg"] = {
	"Ukuriguma",
	"Q7878623",
	"ngf-mad",
}

m["ukh"] = {
	"Ukhwejo",
	"Q36623",
	"bnt-bek",
}

m["ukk"] = {
	"Muak Sa-aak",
	nil,
	"mkh-pal",
	otherNames = {"Muak"},
}

m["ukl"] = {
	"Ukrainian Sign Language",
	"Q10322106",
	"sgn",
}

m["ukp"] = {
	"Ukpe-Bayobiri",
	"Q3914470",
	"nic-ben",
	scripts = Latn,
}

m["ukq"] = {
	"Ukwa",
	"Q7878635",
	"nic-ief",
}

m["uks"] = {
	"Kaapor Sign Language",
	"Q3322101",
	"sgn",
}

m["uku"] = {
	"Ukue",
	"Q3913387",
	"alv-nwd",
	scripts = Latn,
}

m["ukw"] = {
	"Ukwuani-Aboh-Ndoni",
	"Q36636",
	"alv",
	scripts = Latn,
}

m["uky"] = {
	"Kuuk Yak",
	"Q6448719",
	"aus-psw",
	scripts = Latn,
}

m["ula"] = {
	"Fungwa",
	"Q5509187",
	"nic-shi",
	otherNames = {"Ula", "Ura"},
}

m["ulb"] = {
	"Ulukwumi",
	"Q36722",
}

m["ulc"] = {
	"Ulch",
	"Q13239",
	"tuw",
	scripts = {"Cyrl", "Latn"},
}

m["ule"] = {
	"Lule",
	"Q12635889",
	scripts = Latn,
}

m["ulf"] = {
	"Afra",
	"Q4477735",
	"paa-pau",
}

m["uli"] = {
	"Ulithian",
	"Q36842",
	"poz-mic",
}

m["ulk"] = {
	"Meriam",
	"Q788174",
	"ngf",
	scripts = Latn,
}

m["ull"] = {
	"Ullatan",
	"Q8761579",
	"dra",
}

m["ulm"] = {
	"Ulumanda'",
	"Q3501892",
}

m["uln"] = {
	"Unserdeutsch",
	"Q13244",
	"crp",
	otherNames = {"Rabaul Creole German"},
	scripts = Latn,
	ancestors = {"de"},
}

m["ulu"] = {
	"Uma' Lung",
	"Q3548186",
	"poz-swa",
}

m["ulw"] = {
	"Ulwa",
	"Q2405552",
}

m["uma"] = {
	"Umatilla",
	"Q12953952",
	"nai-shp",
	scripts = Latn,
}

m["umb"] = {
	"Umbundu",
	"Q36983",
	"bnt",
	otherNames = {"South Mbundu"},
	scripts = Latn,
}

m["umc"] = {
	"Marrucinian",
	"Q36110",
	"itc",
	scripts = {"Latn", "Ital"},
}

m["umd"] = {
	"Umbindhamu",
	"Q7881346",
	"aus-pmn",
}

m["umg"] = {
	"Umbuygamu",
	"Q3915677",
	"aus-pmn",
}

m["umi"] = {
	"Ukit",
	"Q7878321",
}

m["umm"] = {
	"Umon",
	"Q3915448",
	"nic-ucn",
	scripts = Latn,
}

m["umn"] = {
	"Makyan Naga",
	"Q6740516",
	"sit-kch",
}

m["umo"] = {
	"Umotína",
	"Q7881740",
}

m["ump"] = {
	"Umpila",
	"Q12953954",
}

m["umr"] = {
	"Umbugarla",
	"Q2980392",
}

m["ums"] = {
	"Pendau",
	"Q7162371",
}

m["umu"] = {
	"Munsee",
	"Q56547",
	"del",
	scripts = Latn,
	entry_name = {
		from = {"Á", "Ă", "É", "Í", "Ó", "Ú", "Ŭ", "á", "á", "ă", "é", "í", "ó", "ú", "ŭ"},
		to   = {"A", "A", "E", "I", "O", "U", "U", "a", "á", "a", "e", "i", "o", "u", "u"}} ,
}

m["una"] = {
	"North Watut",
	"Q15887898",
	"poz-ocw",
	scripts = Latn,
}

m["und"] = {
	"Undetermined",
	nil,
	"qfa-not",
	scripts = {"Zyyy"},
}

m["une"] = {
	"Uneme",
	"Q3913357",
	"alv-yek",
	scripts = Latn,
}

m["ung"] = {
	"Ngarinyin",
	"Q1284885",
	"aus-wor",
	otherNames = {"Ungarinjin"},
	scripts = Latn,
}

m["unk"] = {
	"Enawené-Nawé",
	"Q3307184",
	"awd",
	scripts = Latn,
}

m["unm"] = {
	"Unami",
	"Q3549180",
	"del",
	scripts = Latn,
	entry_name = {
		from = {"À", "Ä", "È", "Ë", "Ì", "Ò", "Ù", "à", "ä", "è", "ë", "ì", "ò", "ù"},
		to   = {"A", "A", "E", "E", "I", "O", "U", "a", "a", "e", "e", "i", "o", "u"}} ,
}

m["unn"] = {
	"Kurnai",
	nil,
	"aus-pam",
	otherNames = {"Gunai", "Gaanay", "Ganai", "Gunnai'", "Kurnay", "Bidhawal", "Birrdhawal", "Muk-thang", "Nulit", "Thangquai"},
	scripts = Latn,
}

m["unr"] = {
	"Mundari",
	"Q3327828",
	"mun",
	scripts = {"Deva"},
	translit_module = "hi-translit", -- for now
}

m["unu"] = {
	"Unubahe",
	"Q7897776",
}

m["unx"] = {
	"Munda",
	"Q36264959",
	"mun",
	scripts = Latn,
}

m["unz"] = {
	"Unde Kaili",
	"Q12953596",
	"poz-kal",
	otherNames = {"Banava", "Ndepuu", "West Kaili", "Lole", "Ganti"},
	scripts = Latn,
}

m["uok"] = {
	"Uokha",
	"Q3441216",
	"alv-edo",
	scripts = Latn,
}

m["upi"] = {
	"Umeda",
	"Q7881465",
	"paa-brd",
}

m["upv"] = {
	"Uripiv-Wala-Rano-Atchin",
	"Q13249",
	"poz-vnc",
	scripts = Latn,
}

m["ura"] = {
	"Urarina",
	"Q1579560",
}

m["urb"] = {
	"Urubú-Kaapor",
	"Q13893353",
	"tup-gua",
	otherNames = {"Ka'apor", "Kaaporté"},
	scripts = Latn,
}

m["urc"] = {
	"Urningangg",
	"Q10710522",
}

m["ure"] = {
	"Uru",
	"Q2992892",
}

m["urf"] = {
	"Uradhi",
	"Q3915680",
	"aus-pam",
	scripts = Latn,
}

m["urg"] = {
	"Urigina",
	"Q7900603",
	"ngf",
	scripts = Latn,
}

m["urh"] = {
	"Urhobo",
	"Q36663",
	"alv-swd",
	scripts = Latn,
}

m["uri"] = {
	"Urim",
	"Q7900609",
	"qfa-tor",
	scripts = Latn,
}

m["urk"] = {
	"Urak Lawoi'",
	"Q7899573",
	"poz-mly",
	scripts = {"Thai"},
	otherNames = {"Urak Lawoi", "Orak Lawoi'", "Orak Lawoi", "Lawta", "Chao Tha Le", "Chao Nam", "Lawoi"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["url"] = {
	"Urali",
	"Q7899602",
	"dra",
	scripts = {"Knda"},
}

m["urm"] = {
	"Urapmin",
	"Q7899769",
}

m["urn"] = {
	"Uruangnirin",
	"Q7901389",
	"poz-cet",
	scripts = Latn,
}

m["uro"] = {
	"Ura (New Guinea)",
	"Q3121049",
	"paa-bng",
	otherNames = {"Ura (Papua New Guinea)"},
	scripts = Latn,
}

m["urp"] = {
	"Uru-Pa-In",
	"Q7901376",
	"tup-gua",
	scripts = Latn,
}

m["urr"] = {
	"Lehalurup",
	"Q3272124",
}

m["urt"] = {
	"Urat",
	"Q3502084",
	"qfa-tor",
	scripts = Latn,
}

m["uru"] = {
	"Urumi",
	"Q7901530",
	"tup",
	scripts = Latn,
}

m["urv"] = {
	"Uruava",
	"Q36875",
	"poz-ocw",
	scripts = Latn,
}

m["urw"] = {
	"Sop",
	"Q7562808",
	"ngf-mad",
	otherNames = {"Sob", "Sopu", "Usino", "Usina", "Usion"}, -- Usi- names are not used by speakers
	scripts = Latn,
}

m["urx"] = {
	"Urimo",
	"Q7900611",
	"qfa-tor",
	scripts = Latn,
}

m["ury"] = {
	"Orya",
	"Q7105295",
	"paa-tkw",
	scripts = Latn,
}

m["urz"] = {
	"Uru-Eu-Wau-Wau",
	"Q10266012",
	"tup-gua",
	scripts = Latn,
}

m["usa"] = {
	"Usarufa",
	"Q7901714",
	"paa-kag",
	scripts = Latn,
}

m["ush"] = {
	"Ushojo",
	"Q3540446",
}

m["usi"] = {
	"Usui",
	"Q12644231",
}

m["usk"] = {
	"Usaghade",
	"Q3914048",
	"nic-lcr",
	scripts = Latn,
}

m["usp"] = {
	"Uspanteco",
	"Q36728",
	"myn",
	scripts = Latn,
}

m["uss"] = {
	"Saare",
	nil,
	"nic-knn",
	otherNames = {"us-Saare", "Hun-Saare", "Duka"},
	scripts = Latn,
}

m["usu"] = {
	"Uya",
	"Q7904082",
}

m["uta"] = {
	"Otank",
	"Q3913990",
	"nic-tvc",
	scripts = Latn,
}

m["ute"] = {
	"Ute",
	"Q13260",
	"azc-num",
	otherNames = {"Southern Paiute", "Colorado River Numic", "Chemehuevi"},
	scripts = Latn,
}

m["uth"] = {
	"Hun",
	nil,
	"nic-knn",
	otherNames = {"ut-Hun", "Hun-Saare", "Duka"},
	scripts = Latn,
}

m["utp"] = {
	"Aba",
	"Q2841465",
	"poz-oce",
	otherNames = {"Amba", "Nebao", "Nembao"},
	scripts = Latn,
}

m["utr"] = {
	"Etulo",
	"Q35262",
	"alv-ido",
	scripts = Latn,
}

m["utu"] = {
	"Utu",
	"Q7903469",
	"ngf-mad",
}

m["uum"] = {
	"Urum",
	"Q13257",
	"trk-kcu",
	scripts = {"Cyrl"},
}

m["uun"] = {
	"Kulon-Pazeh",
	"Q36435",
	"map",
	otherNames = {"Pazeh", "Pazih", "Kulun", "Kulon"},
	scripts = Latn,
}

m["uur"] = {
	"Ura (Vanuatu)",
	"Q7899531",
	"poz-oce",
	scripts = Latn,
}

m["uuu"] = {
	"U",
	"Q953082",
	"mkh-pal",
	otherNames = {"P'uman"},
}

m["uve"] = {
	"West Uvean",
	"Q36837",
	"poz-pnp",
	otherNames = {"Uvean", "Faga Ouvéa", "Fagauvea"},
	scripts = Latn,
}

m["uvh"] = {
	"Uri",
	"Q7900540",
	"ngf-fin",
	scripts = Latn,
}

m["uvl"] = {
	"Lote",
	"Q3259972",
	"poz-ocw",
	scripts = Latn,
}

m["uwa"] = {
	"Kuku-Uwanh",
	"Q3915687",
}

m["uya"] = {
	"Doko-Uyanga",
	"Q7904095",
	"nic-ucr",
	scripts = Latn,
}

return m