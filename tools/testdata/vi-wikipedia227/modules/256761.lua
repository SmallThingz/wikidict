local m_langdata = require("Module:languages/data")

-- Loaded on demand, as it may not be needed (depending on the data).
local function u(...)
	u = require("Module:string utilities").char
	return u(...)
end

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

local m = {}

m["uam"] = {
	"Uamué",
	3441418,
}

m["uan"] = {
	"Kuan",
	6441085,
}

m["uar"] = {
	"Tairuma",
	7676386,
	"ngf",
}

m["uba"] = {
	"Ubang",
	3914467,
	"nic-ben",
	"Latn",
}

m["ubi"] = {
	"Ubi",
	56264,
}

m["ubl"] = {
	"tiếng Bikol Buhi'non",
	18664494,
	"phi",
	"Latn",
	"Tiếng Bikol Buhi'non",
	"Bikol Buhi'non",
}

m["ubr"] = {
	"Ubir",
	3547642,
	"poz-ocw",
	"Latn",
}

m["ubu"] = {
	"Umbu-Ungu",
	12953245,
	"ngf",
}

m["uby"] = {
	"tiếng Ubykh",
	36931,
	"cau-nwc",
	"Cyrl, Latn",
	"Tiếng Ubykh",
	"Ubykh",
	translit = "uby-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = "uby-sortkey",
}

m["uda"] = {
	"Uda",
	11011951,
	"nic-lcr",
}

m["ude"] = {
	"tiếng Udihe",
	13235,
	"tuw-udg",
	"Cyrl",
	"Tiếng Udihe",
	"Udihe",
}

m["udg"] = {
	"tiếng Muduga",
	16886762,
	"dra-imd",
	"Mlym",
	"Tiếng Muduga",
	"Muduga",
	translit = "ml-translit",
}

m["udi"] = {
	"tiếng Udi",
	36867,
	"cau-esm",
	"Cyrl, Latn, Armn, Geor",
	"Tiếng Udi",
	"Udi",
	ancestors = "xag",
	translit = {
		Cyrl = "udi-translit",
		Armn = "Armn-translit",
		Geor = "Geor-translit",
	},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
}

m["udj"] = {
	"Ujir",
	14916906,
	"poz-cet",
}

m["udl"] = {
	"Uldeme",
	3515078,
	"cdc-cbm",
}

m["udm"] = {
	"tiếng Udmurt",
	13238,
	"urj-prm",
	"Cyrl",
	"Tiếng Udmurt",
	"Udmurt",
	translit = "udm-translit",
	override_translit = true,
	sort_key = "udm-sortkey",
}

m["udu"] = {
	"tiếng Uduk",
	3182573,
	"ssa-kom",
	"Latn",
	"Tiếng Uduk",
	"Uduk",
}

m["ues"] = {
	"Kioko",
	18343036,
}

m["ufi"] = {
	"Ufim",
	7877531,
	"ngf-fin",
	"Latn",
}

m["uga"] = {
	"tiếng Ugarit",
	36928,
	"sem-nwe",
	"Ugar",
	"Tiếng Ugarit",
	"Ugarit",
	translit = "uga-translit",
}

m["ugb"] = {
	"Kuku-Ugbanh",
	10549854,
}

m["uge"] = {
	"Ughele",
	966303,
	"poz-ocw",
}

m["ugh"] = {
	"tiếng Kubachi",
	2445129,
	"cau-drg",
	"Cyrl",
	"Tiếng Kubachi",
	"Kubachi",
}

m["ugn"] = {
	"Ugandan Sign Language",
	7877677,
	"sgn",
}

m["ugo"] = {
	"tiếng Ugong",
	3448919,
	"tbq-lob",
	"Thai",
	"Tiếng Ugong",
	"Ugong",
	sort_key = "Thai-sortkey",
}

m["ugy"] = {
	"Uruguayan Sign Language",
	7901470,
	"sgn",
}

m["uha"] = {
	"Uhami",
	3913328,
	"alv-nwd",
	"Latn",
}

m["uhn"] = {
	"Damal",
	4748974,
}

m["uis"] = {
	"Uisai",
	7878123,
	"paa-sbo",
}

m["uiv"] = {
	"Iyive",
	11128658,
	"nic-tvc",
	"Latn",
}

m["uji"] = {
	"Tanjijili",
	3914939,
	"nic-pls",
}

m["uka"] = {
	"Kaburi",
	6344482,
}

m["ukg"] = {
	"Ukuriguma",
	7878623,
	"ngf-mad",
}

m["ukh"] = {
	"Ukhwejo",
	36623,
	"bnt-bek",
}

m["uki"] = {
	"tiếng Kui (Ấn Độ)",
	33919,
	"dra-kki",
	"Orya",
	"Tiếng Kui (Ấn Độ)",
	"Kui (Ấn Độ)",
	translit = "kxv-translit",
	entry_name = {
		remove_diacritics = "୕",
		from = {"ଆଆ", "ଇଇ", "ଉଉ", "ଏଏ", "ଓଓ", "ିଇ", "ୁଉ", "େଏ", "ୋଓ"},
		to = {"ଆ", "ଈ", "ଊ", "ଏ", "ଓ", "ୀ", "ୂ", "େ", "ୋ"},
	},
}

m["ukk"] = {
	"tiếng Muak Sa-aak",
	23807993,
	"mkh-pal",
	nil,
	"Tiếng Muak Sa-aak",
	"Muak Sa-aak"
}

m["ukl"] = {
	"Ukrainian Sign Language",
	10322106,
	"sgn",
}

m["ukp"] = {
	"Ukpe-Bayobiri",
	3914470,
	"nic-ben",
	"Latn",
}

m["ukq"] = {
	"Ukwa",
	7878635,
	"nic-ief",
}

m["uks"] = {
	"Kaapor Sign Language",
	3322101,
	"sgn",
}

m["uku"] = {
	"Ukue",
	3913387,
	"alv-nwd",
	"Latn",
}

m["ukw"] = {
	"Ukwuani-Aboh-Ndoni",
	36636,
	"alv",
	"Latn",
}

m["uky"] = {
	"Kuuk Yak",
	6448719,
	"aus-psw",
	"Latn",
}

m["ula"] = {
	"tiếng Fungwa",
	5509187,
	"nic-shi",
	"Latn",
	"Tiếng Fungwa",
	"Fungwa",
}

m["ulb"] = {
	"tiếng Olukumi",
	36722,
	"alv-yor",
	"Latn",
	"Tiếng Olukumi",
	"Olukumi",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.macron}},
	sort_key = {
		from = {"ch", "ẹ", "gb", "gh", "gw", "kp", "kw", "ọ", "ṣ"},
		to = {"c" .. p[1], "e" .. p[1], "g" .. p[1], "g" .. p[2], "g" .. p[3], "k" .. p[1], "k" .. p[2], "o" .. p[1], "s" .. p[1]}
	},
}

m["ulc"] = {
	"tiếng Ulch",
	13239,
	"tuw-nan",
	"Cyrl, Latn",
	"Tiếng Ulch",
	"Ulch",
	entry_name = {
		from = {"['’]"},
		to = {"ʼ"}
	},
	sort_key = "ulc-sortkey",
}

m["ule"] = {
	"Lule",
	12635889,
	nil,
	"Latn",
}

m["ulf"] = {
	"Afra",
	4477735,
	"paa-pau",
}

m["uli"] = {
	"Ulithian",
	36842,
	"poz-mic",
}

m["ulk"] = {
	"tiếng Meriam",
	788174,
	"ngf",
	"Latn",
	"Tiếng Meriam",
	"Meriam",
}

m["ull"] = {
	"tiếng Ullatan",
	8761579,
	"dra-mal",
	"Mlym",
	"Tiếng Ullatan",
	"Ullatan",
	translit = "ml-translit",
}

m["ulm"] = {
	"Ulumanda'",
	3501892,
}

m["uln"] = {
	"Unserdeutsch",
	13244,
	"crp",
	"Latn",
	ancestors = "de",
}

m["ulu"] = {
	"Uma' Lung",
	3548186,
	"poz-swa",
}

m["ulw"] = {
	"Ulwa",
	2405552,
}

m["uma"] = {
	"tiếng Umatilla",
	12953952,
	"nai-shp",
	"Latn",
	"Tiếng Umatilla",
	"Umatilla",
	ancestors = "nai-spt",
}

m["umb"] = {
	"tiếng Umbundu",
	36983,
	"bnt",
	"Latn",
	"Tiếng Umbundu",
	"Umbundu",
}

m["umc"] = {
	"tiếng Marrucini",
	36110,
	"itc-sbl",
	"Latn, Ital",
	"Tiếng Marrucini",
	"Marrucini",
	translit = {Ital = "Ital-translit"},
}

m["umd"] = {
	"Umbindhamu",
	7881346,
	"aus-pmn",
}

m["umg"] = {
	"Umbuygamu",
	3915677,
	"aus-pmn",
}

m["umi"] = {
	"Ukit",
	7878321,
}

m["umm"] = {
	"Umon",
	3915448,
	"nic-ucn",
	"Latn",
}

m["umn"] = {
	"Makyan Naga",
	6740516,
	"sit-kch",
}

m["umo"] = {
	"Umotína",
	7881740,
	"sai-mje",
}

m["ump"] = {
	"Umpila",
	12953954,
	"aus-pmn",
	"Latn",
}

m["umr"] = {
	"Umbugarla",
	2980392,
}

m["ums"] = {
	"Pendau",
	7162371,
	"poz-tot",
}

m["umu"] = {
	"tiếng Munsee",
	56547,
	"del",
	"Latn",
	"Tiếng Munsee",
	"Munsee",
	entry_name = {remove_diacritics = c.acute .. c.breve},
}

m["una"] = {
	"North Watut",
	15887898,
	"poz-ocw",
	"Latn",
}

m["und"] = {
	"không xác định ngôn ngữ",
	nil,
	"qfa-not",
	"All",
	"Không xác định ngôn ngữ",
	"không xác định ngôn ngữ",
}

m["une"] = {
	"Uneme",
	3913357,
	"alv-yek",
	"Latn",
}

m["ung"] = {
	"tiếng Ngarinyin",
	1284885,
	"aus-wor",
	"Latn",
}

m["uni"] = {
	"tiếng Uni",
	65043886,
	"paa-pio",
	"Latn",
}

m["unk"] = {
	"Enawené-Nawé",
	3307184,
	"awd",
	"Latn",
}

m["unm"] = {
	"tiếng Unami",
	3549180,
	"del",
	"Latn",
	"Tiếng Unami",
	"Unami",
	--[===[Don't strip diacritics from entry names, per [[WT:Grease pit/2020/May]].
	entry_name = {remove_diacritics = c.grave .. c.diaer},]===]
}

m["unn"] = {
	"Kurnai",
	nil,
	"aus-pam",
	"Latn",
}

m["unr"] = {
	"tiếng Mundari",
	3327828,
	"mun",
	"Nagm, Deva, Beng, Orya, Latn",
	"Tiếng Mundari",
	"Mundari",
	translit = {Deva = "hi-translit"}, -- for now
}

m["unu"] = {
	"Unubahe",
	7897776,
}

m["unx"] = {
	"tiếng Munda",
	36264959,
	"mun",
	"Latn, Deva, Beng, Orya",
	"Tiếng Munda",
	"Munda",
	translit = {Deva = "hi-translit"},
}

m["unz"] = {
	"Unde Kaili",
	12953596,
	"poz-kal",
	"Latn",
}

m["uok"] = {
	"Uokha",
	3441216,
	"alv-edo",
	"Latn",
}

m["uon"] = {
	"Kulon",
	11182000,
	"map",
	"Latn",
}

m["upi"] = {
	"Umeda",
	7881465,
	"paa-brd",
}

m["upv"] = {
	"tiếng Uripiv-Wala-Rano-Atchin",
	13249,
	"poz-vnc",
	"Latn",
	"Tiếng Uripiv-Wala-Rano-Atchin",
	"Uripiv-Wala-Rano-Atchin",
}

m["ura"] = {
	"Urarina",
	1579560,
}

m["urb"] = {
	"tiếng Urubú-Kaapor",
	13893353,
	"tup-gua",
	"Latn",
	"Tiếng Urubú-Kaapor",
	"Urubú-Kaapor",
}

m["urc"] = {
	"Urningangg",
	10710522,
}

m["ure"] = {
	"Uru",
	2992892,
}

m["urf"] = {
	"Uradhi",
	3915680,
	"aus-pam",
	"Latn",
}

m["urg"] = {
	"Urigina",
	7900603,
	"ngf",
	"Latn",
}

m["urh"] = {
	"Urhobo",
	36663,
	"alv-swd",
	"Latn",
}

m["uri"] = {
	"Urim",
	7900609,
	"qfa-tor",
	"Latn",
}

m["urk"] = {
	"tiếng Urak Lawoi'",
	7899573,
	"poz-mly",
	"Thai",
	"Tiếng Urak Lawoi'",
	"Urak Lawoi'",
	sort_key = "Thai-sortkey",
}

m["url"] = {
	"tiếng Urali",
	7899602,
	"dra-kod",
	"Knda",
	"Tiếng Urali",
	"Urali",
	translit = {Knda = "kn-translit"},
}

m["urm"] = {
	"Urapmin",
	7899769,
	"ngf-okk",
}

m["urn"] = {
	"Uruangnirin",
	7901389,
	"poz-cet",
	"Latn",
}

m["uro"] = {
	"Ura (New Guinea)",
	3121049,
	"paa-bng",
	"Latn",
}

m["urp"] = {
	"Uru-Pa-In",
	7901376,
	"tup-gua",
	"Latn",
}

m["urr"] = {
	"Lehalurup",
	3272124,
}

m["urt"] = {
	"Urat",
	3502084,
	"qfa-tor",
	"Latn",
}

m["uru"] = {
	"Urumi",
	7901530,
	"tup",
	"Latn",
}

m["urv"] = {
	"Uruava",
	36875,
	"poz-ocw",
	"Latn",
}

m["urw"] = {
	"Sop",
	7562808,
	"ngf-mad",
	"Latn",
}

m["urx"] = {
	"Urimo",
	7900611,
	"qfa-tor",
	"Latn",
}

m["ury"] = {
	"Orya",
	7105295,
	"paa-tkw",
	"Latn",
}

m["urz"] = {
	"Uru-Eu-Wau-Wau",
	10266012,
	"tup-gua",
	"Latn",
}

m["usa"] = {
	"Usarufa",
	7901714,
	"paa-kag",
	"Latn",
}

m["ush"] = {
	"tiếng Ushojo",
	3540446,
	"inc-shn",
	"ur-Arab",
	"Tiếng Ushojo",
	"Ushojo",
}

m["usi"] = {
	"tiếng Usui",
	12644231,
	"tbq-bdg",
	"Beng, Latn",
	"Tiếng Usui",
	"Usui",
}

m["usk"] = {
	"Usaghade",
	3914048,
	"nic-lcr",
	"Latn",
}

m["usp"] = {
	"Uspanteco",
	36728,
	"myn",
	"Latn",
}

m["uss"] = {
	"Saare",
	nil,
	"nic-knn",
	"Latn",
}

m["usu"] = {
	"Uya",
	7904082,
}

m["uta"] = {
	"Otank",
	3913990,
	"nic-tvc",
	"Latn",
}

m["ute"] = {
	"tiếng Ute",
	13260,
	"azc-num",
	"Latn",
	"Tiếng Ute",
	"Ute",
}

m["uth"] = {
	"tiếng Ut-Hun",
	63313668,
	"nic-knn",
	"Latn",
	"Tiếng Ut-Hun",
	"Ut-Hun",
}

m["utp"] = {
	"Aba",
	2841465,
	"poz-oce",
	"Latn",
}

m["utr"] = {
	"Etulo",
	35262,
	"alv-ido",
	"Latn",
}

m["utu"] = {
	"Utu",
	7903469,
	"ngf-mad",
}

m["uum"] = {
	"tiếng Urum",
	13257,
	"trk-kcu",
	"Cyrl",
	translit = "uum-translit",
}

m["uun"] = {
	"tiếng Kulon-Pazeh",
	36435,
	"map",
	"Latn",
	"Tiếng Kulon-Pazeh",
	"Kulon-Pazeh",
}

m["uur"] = {
	"Ura (Vanuatu)",
	7899531,
	"poz-oce",
	"Latn",
}

m["uuu"] = {
	"tiếng U",
	953082,
	"mkh-pal",
	nil,
	"Tiếng U",
	"U",
}

m["uve"] = {
	"West Uvean",
	36837,
	"poz-pnp",
	"Latn",
}

m["uvh"] = {
	"Uri",
	7900540,
	"ngf-fin",
	"Latn",
}

m["uvl"] = {
	"Lote",
	3259972,
	"poz-ocw",
	"Latn",
}

m["uwa"] = {
	"Kuku-Uwanh",
	3915687,
	"aus-pmn",
}

m["uya"] = {
	"Doko-Uyanga",
	7904095,
	"nic-ucr",
	"Latn",
}

m["uzs"] = {
	"tiếng Nam Uzbek",
	"1066787",
	nil,
	"Arab",
	"Tiếng Nam Uzbek",
	"Nam Uzbek",
	ancestors = "trk-pro",
	translit_module = "uzs-translit"
}

return require("Module:languages").finalizeData(m, "language")