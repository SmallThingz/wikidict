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
	"Buhi'non Bikol",
	18664494,
	"phi",
	"Latn",
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
	"Ubykh",
	36931,
	"cau-nwc",
	"Cyrl, Latn",
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
	"Udihe",
	13235,
	"tuw-udg",
	"Cyrl",
}

m["udg"] = {
	"Muduga",
	16886762,
	"dra-imd",
	"Mlym",
	translit = "ml-translit",
}

m["udi"] = {
	"Udi",
	36867,
	"cau-esm",
	"Cyrl, Latn, Armn, Geor",
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
	"Udmurt",
	13238,
	"urj-prm",
	"Cyrl",
	translit = "udm-translit",
	override_translit = true,
	sort_key = "udm-sortkey",
}

m["udu"] = {
	"Uduk",
	3182573,
	"ssa-kom",
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
	"Ugaritic",
	36928,
	"sem-nwe",
	"Ugar",
	translit = {
		Ugar = "uga-translit",
	}
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

m["ugn"] = {
	"Ugandan Sign Language",
	7877677,
	"sgn",
}

m["ugo"] = {
	"Gong",
	3448919,
	"tbq-lob",
	"Thai",
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

m["ukk"] = {
	"Muak Sa-aak",
	23807993,
	"mkh-pal",
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
	"Fungwa",
	5509187,
	"nic-shi",
}

m["ulb"] = {
	"Olukumi",
	36722,
	"alv-yor",
	"Latn",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.macron}},
	sort_key = {
		from = {"ch", "ẹ", "gb", "gh", "gw", "kp", "kw", "ọ", "ṣ"},
		to = {"c" .. p[1], "e" .. p[1], "g" .. p[1], "g" .. p[2], "g" .. p[3], "k" .. p[1], "k" .. p[2], "o" .. p[1], "s" .. p[1]}
	},
}

m["ulc"] = {
	"Ulch",
	13239,
	"tuw-nan",
	"Cyrl, Latn",
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
	"Meriam",
	788174,
	"ngf",
	"Latn",
}

m["ull"] = {
	"Ullatan",
	8761579,
	"dra-mal",
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
	"Umatilla",
	12953952,
	"nai-shp",
	"Latn",
	ancestors = "nai-spt",
}

m["umb"] = {
	"Umbundu",
	36983,
	"bnt",
	"Latn",
}

m["umc"] = {
	"Marrucinian",
	36110,
	"itc-sbl",
	"Ital, Latn",
	translit = {
		Ital = "Ital-translit",
	},
	display_text = {
		Latn = s["itc-Latn-displaytext"]
	},
	entry_name = {
		Latn = s["itc-Latn-entryname"]
	},
	sort_key = {
		Latn = s["itc-Latn-sortkey"]
	},
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
	"Munsee",
	56547,
	"del",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.breve},
}

m["una"] = {
	"North Watut",
	15887898,
	"poz-ocw",
	"Latn",
}

m["und"] = {
	"Undetermined",
	22282914,
	"qfa-not",
	"All",
}

m["une"] = {
	"Uneme",
	3913357,
	"alv-yek",
	"Latn",
}

m["ung"] = {
	"Ngarinyin",
	1284885,
	"aus-wor",
	"Latn",
}

m["unk"] = {
	"Enawené-Nawé",
	3307184,
	"awd",
	"Latn",
}

m["unm"] = {
	"Unami",
	3549180,
	"del",
	"Latn",
	--[===[Don't strip diacritics from entry names, per [[WT:Grease pit/2020/May]].
	entry_name = {remove_diacritics = c.grave .. c.diaer},]===]
}

m["unn"] = {
	"Kurnai",
	61676882,
	"aus-pam",
	"Latn",
}

m["unr"] = {
	"Mundari",
	3327828,
	"mun",
	"Nagm, Deva, Onao", -- Onao is used by Bhumij, which may be a separate language; remove if it gets split out
	translit = "hi-translit", -- for now
}

m["unu"] = {
	"Unubahe",
	7897776,
}

m["unx"] = {
	"Munda",
	36264959,
	"mun",
	"Latn",
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
	"Northeast Malakula",
	13249,
	"poz-vnc",
	"Latn",
}

m["ura"] = {
	"Urarina",
	1579560,
}

m["urb"] = {
	"Urubú-Kaapor",
	13893353,
	"tup-gua",
	"Latn",
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
	"Urak Lawoi'",
	7899573,
	"poz-mly",
	"Thai",
	sort_key = "Thai-sortkey",
}

m["url"] = {
	"Urali",
	7899602,
	"dra-kod",
	"Knda",
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
	"Ura (Papua New Guinea)",
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
	"Löyöp",
	3272124,
	"poz-vnn",
	"Latn",
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
	"Ushojo",
	3540446,
	"inc-shn",
	"ur-Arab",
}

m["usi"] = {
	"Usui",
	12644231,
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
	63313662,
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
	"Ute",
	13260,
	"azc-num",
	"Latn",
}

m["uth"] = {
	"Hun",
	63313668,
	"nic-knn",
	"Latn",
}

m["utp"] = {
	"Aba",
	2841465,
	"poz-tem",
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
	"Urum",
	13257,
	"trk-kcu",
	"Cyrl",
}

m["uun"] = {
	"Kulon-Pazeh",
	36435,
	"map",
	"Latn",
}

m["uur"] = {
	"Ura (Vanuatu)",
	7899531,
	"poz-vns",
	"Latn",
}

m["uuu"] = {
	"U",
	953082,
	"mkh-pal",
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

return require("Module:languages").finalizeData(m, "language")