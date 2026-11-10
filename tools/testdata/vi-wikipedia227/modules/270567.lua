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

m["aaa"] = {
	"tiếng Ghotuo",
	35463,
	"alv-yek",
	"Latn",
	"Tiếng Ghotuo",
	"Ghotuo",
}

m["aab"] = {
	"tiếng Alumu-Tesu",
	35034,
	"nic-alu",
	"Latn",
	"Tiếng Alumu-Tesu",
	"Alumu-Tesu",
}

m["aac"] = {
	"tiếng Ari",
	1811224,
	"paa-pag",
	"Latn",
	"Tiếng Ari",
	"Ari",
}

m["aad"] = {
	"tiếng Amal",
	56708,
	"paa-iwm",
	"Latn",
	"Tiếng Amal",
	"Amal",
}

-- "aae" IS TREATED AS "sq", SEE WT:LT

m["aaf"] = {
	"tiếng Aranadan",
	3507928,
	"dra-mal",
	"Mlym",
	"Tiếng Aranadan",
	"Aranadan",
	translit = {Mlym = "ml-translit"},
}

m["aag"] = {
	"tiếng Ambrak",
	4741706,
	"qfa-tor",
	"Latn",
	"Tiếng Ambrak",
	"Ambrak",
}

m["aah"] = {
	"Abu' Arapesh",
	4670715,
	"qfa-tor",
	"Latn",
}

m["aai"] = {
	"Arifama-Miniafia",
	4790560,
	"poz-ocw",
	"Latn",
}

m["aak"] = {
	"tiếng Ankave",
	3446690,
	"ngf",
	"Latn",
	"Tiếng Ankave",
	"Ankave",
}

m["aal"] = {
	"tiếng Afade",
	56434,
	"cdc-cbm",
	"Latn",
	"Tiếng Afade",
	"Afade",
}

m["aan"] = {
	"Anambé",
	3507873,
	"tup-gua",
	"Latn",
}

m["aap"] = {
	"Pará Arára",
	56807,
	"sai-pek",
	"Latn",
}

m["aaq"] = {
	"tiếng Đông Abenaki",
	3515185,
	"alg-abp",
	"Latn",
	"Tiếng Đông Abenaki",
	"Đông Abenaki",
}

m["aas"] = {
	"tiếng Aasax",
	56620,
	"cus-sou",
	"Latn",
	"Tiếng Aasax",
	"Aasax",
}

-- "aat" IS TREATED AS "sq", SEE WT:LT

m["aau"] = {
	"tiếng Abau",
	3073568,
	"paa-spk",
	"Latn",
	"Tiếng Abau",
	"Abau",
}

m["aaw"] = {
	"tiếng Solong",
	7558834,
	"poz-ocw",
	"Latn",
	"Tiếng Solong",
	"Solong",
}

m["aax"] = {
	"Mandobo Atas",
	12636156,
	"ngf",
	"Latn",
}

m["aaz"] = {
	"tiếng Amarasi",
	4740192,
	"poz-tim",
	"Latn",
	"Tiếng Amarasi",
	"Amarasi",
}

m["aba"] = {
	"Abé",
	34833,
	"alv-lag",
	"Latn",
}

m["abb"] = {
	"tiếng Bankon",
	34860,
	"bnt-bsa",
	"Latn",
	"Tiếng Bankon",
	"Bankon",
}

m["abc"] = {
	"Ambala Ayta",
	3448896,
	"phi",
	"Latn",
}

m["abd"] = {
	"Camarines Norte Agta",
	3399682,
	"phi",
	"Latn",
}

m["abe"] = {
	"tiếng Tây Abenaki",
	17502788,
	"alg-abp",
	"Latn",
	"Tiếng Tây Abenaki",
	"Tây Abenaki",
}

m["abf"] = {
	"Abai Sungai",
	4663287,
	"poz-san",
	"Latn",
}

m["abg"] = {
	"tiếng Abaga",
	3507954,
	"paa-kag",
	"Latn",
	"Tiếng Abaga",
	"Abaga",
}

m["abh"] = {
	"tiếng Ả Rập Tajikistan",
	56833,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Tajikistan",
	"Ả Rập Tajikistan",
	entry_name = "ar-entryname",
}

m["abi"] = {
	"tiếng Abidji",
	34781,
	"alv-lag",
	"Latn",
	"Tiếng Abidji",
	"Abidji",
}

m["abj"] = {
	"Aka-Bea",
	2356391,
	"qfa-ads",
	"Latn",
}

m["abl"] = {
	"Abung",
	49215,
	"poz-lgx",
	"Latn",
}

m["abm"] = {
	"tiếng Abanyom",
	7502,
	"nic-eko",
	"Latn",
	"Tiếng Abanyom",
	"Abanyom",
}

m["abn"] = {
	"Abua",
	34835,
	"nic-cde",
	"Latn",
}

m["abo"] = {
	"tiếng Abon",
	35121,
	"nic-tvn",
	"Latn",
	"Tiếng Abon",
	"Abon",
}

m["abp"] = {
	"Abenlen Ayta",
	3436621,
	"phi",
	"Latn",
}

m["abq"] = {
	"tiếng Abaza",
	27567,
	"cau-abz",
	"Cyrl, Latn",
	"Tiếng Abaza",
	"Abaza",
	translit = {Cyrl = "abq-translit"},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {
				"гъв", "гъь", "гӏв", "джв", "джь", "къв", "къь", "кӏв", "кӏь", "хъв", "хӏв", "чӏв", -- 3 chars
				"гв", "гъ", "гь", "гӏ", "дж", "дз", "ё", "жв", "жь", "кв", "къ", "кь", "кӏ", "ль", "лӏ", "пӏ", "тл", "тш", "тӏ", "фӏ", "хв", "хъ", "хь", "хӏ", "цӏ", "чв", "чӏ", "шв", "шӏ" -- 2 chars
			},
			to = {
				"г" .. p[3], "г" .. p[4], "г" .. p[7], "д" .. p[2], "д" .. p[3], "к" .. p[3], "к" .. p[4], "к" .. p[7], "к" .. p[8], "х" .. p[3], "х" .. p[6], "ч" .. p[3],
				"г" .. p[1], "г" .. p[2], "г" .. p[5], "г" .. p[6], "д" .. p[1], "д" .. p[4], "е" .. p[1], "ж" .. p[1], "ж" .. p[2], "к" .. p[1], "к" .. p[2], "к" .. p[5], "к" .. p[6], "л" .. p[1], "л" .. p[2], "п" .. p[1], "т" .. p[1], "т" .. p[2], "т" .. p[3], "ф" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[4], "х" .. p[5], "ц" .. p[1], "ч" .. p[1], "ч" .. p[2], "ш" .. p[1], "ш" .. p[2]
			}
		},
	},
}

m["abr"] = {
	"tiếng Abron",
	34831,
	"alv-ctn",
	"Latn",
	"Tiếng Abron",
	"Abron",
	ancestors = "ak",
}

m["abs"] = {
	"tiếng Mã Lai Ambon",
	3124354,
	"crp",
	"Latn",
	"Tiếng Mã Lai Ambon",
	"Mã Lai Ambon",
	ancestors = "ms",
}

m["abt"] = {
	"tiếng Ambulas",
	3508015,
	"paa-spk",
	"Latn",
	"Tiếng Ambulas",
	"Ambulas",
}

m["abu"] = {
	"tiếng Abure",
	34767,
	"alv-ptn",
	"Latn",
	"Tiếng Abure",
	"Abure",
}

m["abv"] = {
	"Baharna Arabic",
	56576,
	"sem-arb",
	"Arab",
	entry_name = "ar-entryname",
}

m["abw"] = {
	"Pal",
	7126121,
	"ngf-mad",
	"Latn",
}

m["abx"] = {
	"Inabaknon",
	2820163,
	"poz-sbj",
	"Latn",
}

m["aby"] = {
	"Aneme Wake",
	3508107,
	"ngf",
	"Latn",
}

m["abz"] = {
	"tiếng Abui",
	2822110,
	"qfa-tap",
	"Latn",
	"Tiếng Abui",
	"Abui",
}

m["aca"] = {
	"tiếng Achawa",
	2822982,
	"awd",
	"Latn",
    "Tiếng Achawa",
	"Achawa",
}

m["acb"] = {
	"Áncá",
	11130787,
	"nic-mom",
	"Latn",
}

m["acd"] = {
	"Gikyode",
	35256,
	"alv-gng",
	"Latn",
}

m["ace"] = {
	"tiếng Aceh",
	27683,
	"cmc",
	"Latn, ms-Arab",
	"Tiếng Aceh",
	"Aceh",
	standardChars = {
		Latn = "AaBbCcDdEeÉéÈèËëFfGgHhIiJjKkLlMmNnOoÔôÖöPpQqRrSsTtUuVvWwXxYyZz", -- current orthography (not yet add Arab)
		c.punc
	},
}

m["ach"] = {
	"tiếng Acholi",
	34926,
	"sdv-los",
	"Latn",
	"Tiếng Acholi",
	"Acholi",
}

m["aci"] = {
	"Aka-Cari",
	2670418,
	"qfa-adn",
	"Latn",
}

m["ack"] = {
	"Aka-Kora",
	3433680,
	"qfa-adn",
	"Latn",
}

m["acl"] = {
	"Akar-Bale",
	3436825,
	"qfa-ads",
	"Latn",
}

m["acm"] = {
	"tiếng Ả Rập Iraq",
	56232,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Iraq",
	"Ả Rập Iraq",
	entry_name = "ar-entryname",
}

m["acn"] = {
	"tiếng A Xương",
	56582,
	"tbq-brm",
	"Latn",
	"Tiếng A Xương",
	"A Xương",
}

m["acp"] = {
	"tiếng Đông Acipa",
	5329945,
	"nic-kmk",
	"Latn",
	"Tiếng Đông Acipa",
	"Đông Acipa",
}

m["acr"] = {
	"tiếng Achi",
	34774,
	"myn",
	"Latn",
	"Tiếng Achi",
	"Achi",
}

m["acs"] = {
	"Acroá",
	2829146,
	"sai-cje",
	"Latn",
}

m["acu"] = {
	"tiếng Achuar",
	2823170,
	"sai-jiv",
	"Latn",
	"Tiếng Achuar",
	"Achuar",
}

m["acv"] = {
	"tiếng Achumawi",
	56661,
	"nai-pal",
	"Latn",
	"Tiếng Achumawi",
	"Achumawi",
}

m["acw"] = {
	"tiếng Ả Rập Hijazi",
	56608,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Hijazi",
	"Ả Rập Hijazi",
	entry_name = "ar-entryname",
}

m["acx"] = {
	"tiếng Ả Rập Oman",
	56630,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Oman",
	"Ả Rập Oman",
	entry_name = "ar-entryname",
}

m["acy"] = {
	"tiếng Ả Rập Síp",
	56416,
	"sem-arb",
	"Latn, Grek",
	"Tiếng Ả Rập Síp",
	"Ả Rập Síp",
	ancestors = "acm",
	standardChars = {
		Latn = "AaBbCcDdΔδEeFfGgĠġĊċIiJjKkLlMmNnOoPpΘθRrSsTtUuVvWwXxYyZzŞş",
		c.punc
	},
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.breve},
}

m["acz"] = {
	"tiếng Acheron",
	34769,
	"alv-tal",
	"Latn",
	"Tiếng Acheron",
	"Acheron",
}

m["ada"] = {
	"tiếng Adangme",
	35141,
	"alv-gda",
	"Latn",
	"Tiếng Adangme",
	"Adangme",
}

m["adb"] = { -- rename or remove, see RFM
	"Adabe",
	36872,
	nil,
	"Latn",
}

m["add"] = {
	"Dzodinka",
	35266,
	"nic-nka",
	"Latn",
}

m["ade"] = {
	"Adele",
	27740,
	"alv-ntg",
	"Latn",
}

m["adf"] = {
	"Dhofari Arabic",
	56565,
	"sem-arb",
	"Arab",
	entry_name = "ar-entryname",
}

m["adg"] = {
	"Andegerebinha",
	3508123,
	"aus-pam",
	"Latn",
}

m["adh"] = {
	"Adhola",
	1971400,
	"sdv-los",
	"Latn",
}

m["adi"] = {
	"tiếng Adi",
	56440,
	"sit-tan",
	"Latn",
	"Tiếng Adi",
	"Adi",
}

m["adj"] = {
	"tiếng Adjukru",
	34738,
	"alv-lag",
	"Latn",
}

m["adl"] = {
	"tiếng Galo",
	2857892,
	"sit-tan",
	"Latn",
	"Tiếng Galo",
	"Galo",
}

m["adn"] = {
	"Adang",
	3398276,
	"qfa-tap",
	"Latn",
}

m["ado"] = {
	"Abu",
	56659,
	"paa-ram",
	"Latn",
}

m["adp"] = {
	"Adap",
	3512402,
	"sit-tib",
	"Tibt",
	ancestors = "dz",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
	wikipedia_article = "Dzongkha",		-- Considered a dialect of Dzongkha
}

m["adq"] = {
	"Adangbe",
	34730,
	"alv-gda",
	"Latn",
	ancestors = "ada",
}

m["adr"] = {
	"Adonara",
	4684505,
	"poz-cet",
	"Latn",
}

m["ads"] = {
	"Adamorobe Sign Language",
	27709,
	"sgn",
	"Latn", -- when documented
}

m["adt"] = {
	"tiếng Adnyamathanha",
	2225391,
	"aus-psw",
	"Latn",
	"Tiếng Adnyamathanha",
	"Adnyamathanha",
}

m["adu"] = {
	"Aduge",
	34734,
	"alv-nwd",
	"Latn",
	ancestors = "opa",
	wikipedia_article = "Okpamheri language",
}

m["adw"] = {
	"Amondawa",
	12626847,
	"tup-gua",
	"Latn",
}

m["ady"] = {
	"tiếng Adygea",
	27776,
	"cau-cir",
	"Cyrl, Latn, Arab",
	"Tiếng Adygea",
	"Adygea",
	translit = {
		Cyrl = "cau-cir-translit",
		Arab = "ar-translit",
	},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {
				"кхъу", "къӏу", -- 4 chars
				"гъу", "джу", "дзу", "жъу", "къу", "кхъ", "къӏ", "кӏу", "кӏь", "лъу", "лӏу", "пӏу", "сӏу", "тӏу", "фӏу", "хъу", "цӏу", "чъу", "чӏу", "шъу", "шӏу", "щӏу", -- 3 chars
				"гу", "гъ", "гь", "дж", "дз", "ё", "жъ", "жь", "ку", "къ", "кь", "кӏ", "лъ", "ль", "лӏ", "пӏ", "сӏ", "тӏ", "фӏ", "ху", "хъ", "хь", "цу", "цӏ", "чу", "чъ", "чӏ", "шъ", "шӏ", "щӏ", "ӏу", "ӏь" -- 2 chars
			},
			to = {
				"к" .. p[5], "к" .. p[7],
				"г" .. p[3], "д" .. p[2], "д" .. p[4], "ж" .. p[2], "к" .. p[3], "к" .. p[4], "к" .. p[6], "к" .. p[10], "к" .. p[11], "л" .. p[2], "л" .. p[5], "п" .. p[2], "с" .. p[2], "т" .. p[2], "ф" .. p[2], "х" .. p[3], "ц" .. p[3], "ч" .. p[3], "ч" .. p[5], "ш" .. p[2], "ш" .. p[4], "щ" .. p[2],
				"г" .. p[1], "г" .. p[2], "г" .. p[4], "д" .. p[1], "д" .. p[3], "е" .. p[1], "ж" .. p[1], "ж" .. p[3], "к" .. p[1], "к" .. p[2], "к" .. p[8], "к" .. p[9], "л" .. p[1], "л" .. p[3], "л" .. p[4], "п" .. p[1], "с" .. p[1], "т" .. p[1], "ф" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[4], "ц" .. p[1], "ц" .. p[2], "ч" .. p[1], "ч" .. p[2], "ч" .. p[4], "ш" .. p[1], "ш" .. p[3], "щ" .. p[1], "ӏ" .. p[1], "ӏ" .. p[2]
			}
		},
	},
}

m["adz"] = {
	"tiếng Adzera",
	nil,
	"poz-ocw",
	"Latn",
	"Tiếng Adzera",
	"Adzera",
}

m["aea"] = {
	"Areba",
	3509129,
	"aus-pam",
	"Latn",
}

m["aeb"] = {
	"tiếng Ả Rập Tunisia",
	56240,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Tunisia",
	"Ả Rập Tunisia",
	entry_name = "ar-entryname",
}

m["aed"] = {
	"Argentine Sign Language",
	3322073,
	"sgn",
	"Latn", -- when documented
}

m["aee"] = {
	"Northeast Pashayi",
	12642198,
	"inc-pas",
	"fa-Arab, Latn",
}

m["aek"] = {
	"Haeke",
	5638166,
	"poz-cln",
	"Latn",
}

m["ael"] = {
	"Ambele",
	34818,
	"nic-grf",
	"Latn",
}

m["aem"] = {
	"tiếng Arem",
	3507920,
	"mkh-vie",
	"Latn",
	"Tiếng Arem",
	"Arem",
}

m["aen"] = {
	"Armenian Sign Language",
	3446604,
	"sgn",
}

m["aeq"] = {
	"tiếng Aer",
	3246741,
	"inc-wes",
	"Arab",
	"Tiếng Aer",
	"Aer",
}

m["aer"] = {
	"tiếng Arrernte Đông",
	10728232,
	"aus-pam",
	"Latn",
	"Tiếng Arrernte Đông",
	"Arrernte Đông",
}

m["aes"] = {
	"tiếng Alsea",
	2395641,
	nil,
	"Latn",
	"Tiếng Alsea",
	"Alsea",
}

m["aeu"] = {
	"Akeu",
	4700657,
	"tbq-sil",
	"Latn",
}

m["aew"] = {
	"Ambakich",
	56642,
	"paa-ram",
	"Latn",
}

m["aey"] = {
	"Amele",
	3508025,
	"ngf-mad",
	"Latn",
}

m["aez"] = {
	"Aeka",
	16110528,
	"ngf",
	"Latn",
	wikipedia_article = "Orokaiva language", -- subvariety?
}

m["afb"] = {
	"tiếng Ả Rập vùng Vịnh",
	56385,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập vùng Vịnh",
	"Ả Rập vùng Vịnh",
	entry_name = "ar-entryname",
}

m["afd"] = {
	"Andai",
	4753480,
	"paa-arf",
	"Latn",
}

m["afe"] = {
	"Putukwam",
	3914930,
	"nic-ben",
	"Latn",
}

m["afg"] = {
	"Afghan Sign Language",
	4689093,
	"sgn",
}

m["afh"] = {
	"Afrihili",
	384707,
	"art",
	"Latn",
	type = "appendix-constructed",
}

m["afi"] = {
	"Akrukay",
	57003,
	"paa-ram",
	"Latn",
}

m["afk"] = {
	"Nanubae",
	6964416,
	"paa-arf",
	"Latn",
}

m["afn"] = {
	"Defaka",
	35174,
	"nic",
	"Latn",
}

m["afo"] = {
	"Eloyi",
	3914066,
	"nic-plt",
	"Latn",
}

m["afp"] = {
	"Tapei",
	16887371,
	"paa-arf",
	"Latn",
}

m["afs"] = {
	"Afro-Seminole Creole",
	27867,
	"crp",
	"Latn",
	ancestors = "en",
}

m["aft"] = {
	"Afitti",
	3400829,
	"sdv-nyi",
	"Latn",
}

m["afu"] = {
	"Awutu",
	34847,
	"alv-gng",
	"Latn",
}

m["afz"] = {
	"Obokuitai",
	7075258,
	"paa-lkp",
	"Latn",
}

m["aga"] = {
	"Aguano",
	3331203,
	nil,
	"Latn",
}

m["agb"] = {
	"Legbo",
	35584,
	"nic-uce",
	"Latn",
}

m["agc"] = {
	"tiếng Agatu",
	34732,
	"alv-ido",
	"Latn",
	"Tiếng Agatu",
	"Agatu",
}

m["agd"] = {
	"Agarabi",
	3399642,
	"paa-kag",
	"Latn",
}

m["age"] = {
	"Angal",
	10951553,
	"paa-eng",
	"Latn",
}

m["agf"] = {
	"Arguni",
	12473346,
	"poz-cet",
	"Latn",
}

m["agg"] = {
	"Angor",
	3508100,
	"paa",
	"Latn",
}

m["agh"] = {
	"Ngelima",
	7022266,
	"bnt-bta",
	"Latn",
}

m["agi"] = {
	"Agariya",
	663586,
	"mun",
	"Deva",
}

m["agj"] = {
	"tiếng Argobba",
	29292,
	"sem-eth",
	"Ethi",
	"Tiếng Argobba",
	"Argobba",
}

m["agk"] = {
	"Isarog Agta",
	6078982,
	"phi",
	"Latn",
}

m["agl"] = {
	"Fembe",
	372927,
	"ngf",
	"Latn",
}

m["agm"] = {
	"tiếng Angaataha",
	3508001,
	"ngf-ang",
	"Latn",
}

m["agn"] = {
	"Agutaynen",
	3399717,
	"phi-kal",
	"Latn",
}

m["ago"] = {
	"Tainae",
	7676186,
	"ngf",
	"Latn",
}

m["agq"] = {
	"tiếng Aghem",
	34737,
	"nic-rnw",
	"Latn",
	"Tiếng Aghem",
	"Aghem",
}

m["agr"] = {
	"Aguaruna",
	1526530,
	"sai-jiv",
	"Latn",
	"Tiếng Aguaruna",
	"Aguaruna",
}

m["ags"] = {
	"tiếng Esimbi",
	35260,
	"nic-bds",
	"Latn",
    "Tiếng Esimbi",
    "Esimbi",
}

m["agt"] = {
	"Central Cagayan Agta",
	5017296,
	"phi",
	"Latn",
}

m["agu"] = {
	"tiếng Aguacateca",
	35091,
	"myn",
	"Latn",
	"Tiếng Aguacateca",
	"Aguacateca",
}

m["agv"] = {
	"Remontado Agta",
	3508085,
	"phi",
	"Latn",
}

m["agw"] = {
	"Kahua",
	3191906,
	"poz-sls",
	"Latn",
}

m["agx"] = {
	"tiếng Aghul",
	36498,
	"cau-esm",
	"Cyrl",
	"Tiếng Aghul",
	"Aghul",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
	sort_key = {
		from = {"аь", "гъ", "гь", "гӏ", "дж", "ё", "къ", "кь", "кӏ", "оь", "пӏ", "тӏ", "уь", "хъ", "хь", "хӏ", "цӏ", "чӏ"},
		to = {"а" .. p[1], "г" .. p[1], "г" .. p[2], "г" .. p[3], "д" .. p[1], "е" .. p[1], "к" .. p[1], "к" .. p[2], "к" .. p[3], "о" .. p[1], "п" .. p[1], "т" .. p[1], "у" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[3], "ц" .. p[1], "ч" .. p[1]}
	},
}

m["agy"] = {
	"Southern Alta",
	7569611,
	"phi",
	"Latn",
}

m["agz"] = {
	"Mount Iriga Agta",
	6921432,
	"phi",
	"Latn",
}

m["aha"] = {
	"Ahanta",
	34729,
	"alv-ctn",
	"Latn",
}

m["ahb"] = {
	"Axamb",
	2874710,
	"poz-vnc",
	"Latn",
}

m["ahg"] = {
	"tiếng Qimant",
	35663,
	"cus-cen",
	"Latn",
	"Tiếng Qimant",
	"Qimant",
}

m["ahh"] = {
	"Aghu",
	3436645,
	"ngf",
	"Latn",
}

m["ahi"] = {
	"Tiagbamrin Aizi",
	3400073,
	"kro-aiz",
	"Latn",
}

m["ahk"] = {
	"tiếng Akha",
	56643,
	"tbq-han",
	"Latn, Mymr, Thai",
	"Tiếng Akha",
	"Akha",
	sort_key = {
		Thai = {
			from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
			to = {"", "", "%2%1"}
		},
	},
}

m["ahl"] = {
	"Igo",
	35412,
	"alv-ktg",
	"Latn",
}

m["ahm"] = {
	"Mobumrin Aizi",
	35967,
	"kro-aiz",
	"Latn",
}

m["ahn"] = {
	"Àhàn",
	34723,
	"alv-aah",
	"Latn",
}

m["aho"] = {
	"tiếng Ahom",
	34778,
	"tai-swe",
	"Ahom",
	"Tiếng Ahom",
	"Ahom",
	translit = "Ahom-translit",
}

m["ahp"] = {
	"Aproumu Aizi",
	34810,
	"alv-kwa",
	"Latn",
}

m["ahr"] = {
	"tiếng Ahiran",
	15549890,
	"inc-wes",
	"Deva",
	"Tiếng Ahiran",
	"Ahiran",
	translit = "mr-translit",
}

m["ahs"] = {
	"Ashe",
	34823,
	"nic-plc",
	"Latn",
}

m["aht"] = {
	"tiếng Ahtna",
	21058,
	"ath-nor",
	"Latn",
	"Tiếng Ahtna",
	"Ahtna",
}

m["aia"] = {
	"Arosi",
	2863483,
	"poz-sls",
	"Latn",
}

m["aib"] = {
	"tiếng Äynu",
	27927,
	"qfa-mix",
	"Arab, Latn",
	"Tiếng Äynu",
	"Äynu",
	ancestors = "ug, fa"
}

m["aic"] = {
	"Ainbai",
	3332149,
	"paa-brd",
	"Latn",
}

m["aid"] = {
	"Alngith",
	3279409,
	"aus-pmn",
	"Latn",
}

m["aie"] = {
	"Amara",
	2841180,
	"poz-ocw",
	"Latn",
}

m["aif"] = {
	"Agi",
	3331491,
	"qfa-tor",
	"Latn",
}

m["aig"] = {
	"Antigua and Barbuda Creole English",
	3244184,
	"crp",
	"Latn",
	ancestors = "en",
}

m["aih"] = {
	"Ai-Cham",
	2827749,
	"qfa-kms",
	"Latn, Hani",
	sort_key = {Hani = "Hani-sortkey"},
}

m["aii"] = {
	"tiếng Tân Aram Assyria",
	29440,
	"sem-nna",
	"Syrc, Cyrl",
	"Tiếng Tân Aram Assyria",
	"Tân Aram Assyria",
	translit = {Syrc = "aii-translit"},
	entry_name = "Syrc-entryname",
}

m["aij"] = {
	"tiếng Lishanid Noshan",
	3436467,
	"sem-nna",
	"Hebr",
	"Tiếng Lishanid Noshan",
	"Lishanid Noshan",
}

m["aik"] = {
	"Ake",
	34808,
	"nic-pls",
	"Latn",
}

m["ail"] = {
	"Aimele",
	3327418,
	"ngf",
	"Latn",
}

m["aim"] = {
	"tiếng Aimol",
	4697175,
	"tbq-kuk",
	"Latn, Beng",
	"Tiếng Aimol",
	"Aimol",
}

m["ain"] = {
	"tiếng Ainu",
	27969,
	"qfa-ain",
	"Kana, Latn, Cyrl",
	"Tiếng Ainu",
	"Ainu",
	sort_key = {Kana = "Kana-sortkey"},
}

m["aio"] = {
	"tiếng Aiton",
	3399725,
	"tai-swe",
	"Mymr",
	"Tiếng Aiton",
	"Aiton",
	translit = "aio-phk-translit",
	entry_name = {remove_diacritics = c.VS01},
}

m["aip"] = {
	"Burumakok",
	5000984,
	"ngf-okk",
	"Latn",
}

m["air"] = {
	"Airoran",
	3321131,
	"paa-tkw",
	"Latn",
}

m["ait"] = {
	"Arikem",
	3446679,
	"tup",
	"Latn",
}

m["aiw"] = {
	"tiếng Aari",
	7495,
	"omv-aro",
	"Latn, Ethi",
	"Tiếng Aari",
	"Aari",
}

m["aix"] = {
	"Aighon",
	3504287,
	"poz-ocw",
	"Latn",
}

m["aiy"] = {
	"Ali",
	34814,
	"alv-gbf",
	"Latn",
}

m["aja"] = {
	"Aja",
	3237491,
	"csu-bkr",
	"Latn",
}

m["ajg"] = {
	"tiếng Adja",
	35035,
	"alv-gbe",
	"Latn",
	"Tiếng Adja",
	"Adja",
}

m["aji"] = {
	"tiếng Ajië",
	2828867,
	"poz-cln",
	"Latn",
	"Tiếng Ajië",
	"Ajië",
}

m["ajn"] = {
	"Andajin",
	16111302,
	"aus-wor",
	"Latn",
}

m["ajp"] = {
	"tiếng Ả Rập Nam Levant",
	nil,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Nam Levant",
	"Ả Rập Nam Levant",
	entry_name = "ar-entryname",
}

m["ajw"] = {
	"Ajawa",
	56645,
	"cdc-wst",
	"Latn",
}

m["ajz"] = {
	"Amri Karbi",
	3508092,
	"tbq-kuk",
	"Latn",
	ancestors = "mjw",
}

m["akb"] = {
	"Angkola Batak",
	2640686,
	"btk",
	"Latn, Batk",
}

m["akc"] = {
	"Mpur",
	3327139,
	"paa-wpa",
	"Latn",
}

m["akd"] = {
	"Ukpet-Ehom",
	36618,
	"nic-ucr",
	"Latn",
}

m["ake"] = {
	"tiếng Akawaio",
	28059,
	"sai-pem",
	"Latn",
	"Tiếng Akawaio",
	"Akawaio",
}

m["akf"] = {
	"Akpa",
	34801,
	"alv-ido",
	"Latn",
}

m["akg"] = {
	"Anakalangu",
	4750964,
	"poz-cet",
	"Latn",
}

m["akh"] = {
	"Angal Heneng",
	10950354,
	"paa-eng",
	"Latn",
}

m["aki"] = {
	"Aiome",
	56735,
	"paa",
	"Latn",
}

m["akj"] = {
	"tiếng Aka-Jeru",
	2919121,
	"qfa-adn",
	"Latn, Deva",
	"Tiếng Aka-Jeru",
	"Aka-Jeru",
}

m["akk"] = {
	"tiếng Akkad",
	35518,
	"sem-eas",
	"Xsux, Latn",
	"Tiếng Akkad",
	"Akkad",
}

m["akl"] = {
	"tiếng Aklanon",
	8773,
	"phi",
	"Latn",
	"Tiếng Aklanon",
	"Aklanon",
	ancestors = "poz-pro,phi-pro",
}

m["akm"] = {
	"tiếng Aka-Bo",
	35361,
	"qfa-adn",
	"Latn",
	"Tiếng Aka-Bo",
	"Aka-Bo",
}

m["ako"] = {
	"Akurio",
	56650,
	"sai-tar",
	"Latn",
}

m["akp"] = {
	"tiếng Siwu",
	36470,
	"alv-ntg",
	"Latn",
	"Tiếng Siwu",
	"Siwu",
}

m["akq"] = {
	"Ak",
	56654,
	"paa",
	"Latn",
}

m["akr"] = {
	"tiếng Araki",
	2699882,
	"poz-vnc",
	"Latn",
	"Tiếng Araki",
	"Araki",
}

m["aks"] = {
	"tiếng Akaselem",
	34817,
	"nic-grm",
	"Latn",
	"Tiếng Akaselem",
	"Akaselem",
}

m["akt"] = {
	"Akolet",
	3330162,
	"poz-ocw",
	"Latn",
}

m["aku"] = {
	"Akum",
	34799,
	"nic-ykb",
	"Latn",
}

m["akv"] = {
	"tiếng Akhvakh",
	56423,
	"cau-and",
	"Cyrl",
	"Tiếng Akhvakh",
	"Akhvakh",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["akw"] = {
	"Akwa",
	34802,
	"bnt-mbo",
	"Latn",
}

m["akx"] = {
	"tiếng Aka-Kede",
	3436816,
	"qfa-adc",
	"Latn",
	"Tiếng Aka-Kede",
	"Aka-Kede",
}

m["aky"] = {
	"Aka-Kol",
	3436784,
	"qfa-adc",
	"Latn",
}

m["akz"] = {
	"tiếng Alabama",
	1815020,
	"nai-mus",
	"Latn",
	"Tiếng Alabama",
	"Alabama",
}

m["ala"] = {
	"Alago",
	34813,
	"alv-ido",
	"Latn",
}

m["alc"] = {
	"tiếng Kawésqar",
	56544,
	"aqa",
	"Latn",
	"Tiếng Kawésqar",
	"Kawésqar",
}

m["ald"] = {
	"Alladian",
	34837,
	"alv-lag",
	"Latn",
}

m["ale"] = {
	"tiếng Aleut",
	27210,
	"esx",
	"Latn, Cyrl",
	"Tiếng Aleut",
	"Aleut",
}

m["alf"] = {
	"Alege",
	34815,
	"nic-ben",
	"Latn",
}

m["alh"] = {
	"tiếng Alawa",
	2147917,
	"aus-gun",
	"Latn",
	"Tiếng Alawa",
	"Alawa",
}

m["ali"] = {
	"tiếng Amaimon",
	3327427,
	"ngf-mad",
	"Latn",
	"Tiếng Amaimon",
	"Amaimon",
}

m["alj"] = {
	"tiếng Alangan",
	3327423,
	"phi",
	"Latn",
	"Tiếng Alangan",
	"Alangan",
}

m["alk"] = {
	"tiếng Alak",
	2714690,
	"mkh",
	"Latn, Laoo",
	"Tiếng Alak",
	"Alak"
}

m["all"] = {
	"tiếng Allar",
	3393634,
	"dra-mal",
	"Mlym",
	"Tiếng Allar",
	"Allar",
	translit = "ml-translit"
}

-- "aln" IS TREATED AS "sq", SEE WT:LT

m["alm"] = {
	"Amblong",
	11022615,
	"poz-vnc",
	"Latn",
}

m["alo"] = {
	"Larike-Wakasihu",
	3217929,
	"poz-cma",
	"Latn",
}

m["alp"] = {
	"tiếng Alune",
	3327367,
	"poz-cet",
	"Latn",
}

m["alq"] = {
	"tiếng Algonquin",
	28092,
	"alg",
	"Latn",
	"Tiếng Algonquin",
	"Algonquin",
	ancestors = "oj",
}

m["alr"] = {
	"tiếng Alutor",
	28213,
	"qfa-ckn",
	"Cyrl",
	"Tiếng Alutor",
	"Alutor",
	entry_name = {
		from = {"['’]"},
		to = {"ʼ"}
	},
	sort_key = {
		from = {"вʼ", "гʼ", "ғ", "ә", "ё", "ӄ", "ӈ"},
		to = {"в" .. p[1], "г" .. p[1], "г" .. p[2], "е" .. p[1], "е" .. p[2], "к" .. p[1], "н" .. p[1]}
	},
}

m["alt"] = {
	"tiếng Nam Altai",
	1991779,
	"trk-kkp",
	"Cyrl",
	"Tiếng Nam Altai",
	"Nam Altai",
	translit = "Altai-translit",
	sort_key = {
		from = {"ј", "ё", "ҥ", "ӧ", "ӱ"},
		to = {"д" .. p[1], "е" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1]}
	},
}

m["alu"] = {
	"tiếng 'Are'are",
	5160,
	"poz-sls",
	"Latn",
	"Tiếng 'Are'are",
	"'Are'are",
}

m["alw"] = {
	"tiếng Alaba-K’abeena",
	56652,
	"cus-hec",
	"Latn, Ethi",
	"Tiếng Alaba-K’abeena",
	"Alaba-K’abeena",
}

m["alx"] = {
	"Amol",
	3504260,
	"qfa-tor",
	"Latn",
}

m["aly"] = {
	"Alyawarr",
	3327389,
	"aus-pam",
	"Latn",
}

m["alz"] = {
	"Alur",
	56507,
	"sdv-los",
	"Latn",
}

m["ama"] = {
	"Amanayé",
	3508053,
	"tup-gua",
	"Latn",
}

m["amb"] = {
	"Ambo",
	3450142,
	"nic-tvn",
	"Latn",
}

m["amc"] = {
	"tiếng Amahuaca",
	2669150,
	"sai-pan",
	"Latn",	
    "Tiếng Amahuaca",
    "Amahuaca",

}

m["ame"] = {
	"tiếng Yanesha'",
	3088540,
	"awd",
	"Latn",
	"Tiếng Yanesha'",
	"Yanesha'",
}

m["amf"] = {
	"tiếng Hamer-Banna",
	35764,
	"omv-aro",
	"Latn, Ethi",
	"Tiếng Hamer-Banna",
	"Hamer-Banna",
}

m["amg"] = {
	"tiếng Amurdag",
	3360016,
	"aus-wdj",
	"Latn",
	"Tiếng Amurdag",
	"Amurdag",
}

m["ami"] = {
	"tiếng Amis",
	35132,
	"map",
	"Latn",
	"Tiếng Amis",
	"Amis",
}

m["amj"] = {
	"tiếng Amdang",
	28335,
	"ssa-fur",
	"Latn",
	"Tiếng Amdang",
	"Amdang",
}

m["amk"] = {
	"tiếng Ambai",
	1875885,
	"poz-hce",
	"Latn",
	"Tiếng Ambai",
	"Ambai",
}

m["aml"] = {
	"tiếng War-Jaintia",
	56321,
	"aav-khs",
	"Latn",
	"Tiếng War-Jaintia",
	"War-Jaintia",
}

m["amm"] = {
	"tiếng Ama",
	3446626,
	"qfa-mal",
	"Latn",
	"Tiếng Ama",
	"Ama",
}

m["amn"] = {
	"tiếng Amanab",
	3327399,
	"paa-brd",
	"Latn",
	"Tiếng Amanab",
	"Amanab",
}

m["amo"] = {
	"Amo",
	34826,
	"nic-kne",
	"Latn",
}

m["amp"] = {
	"tiếng Alamblak",
	56688,
	"paa",
	"Latn",
	"Tiếng Alamblak",
	"Alamblak",
}

m["amq"] = {
	"Amahai",
	3327384,
	"poz-cma",
	"Latn",
}

m["amr"] = {
	"Amarakaeri",
	35128,
	"sai-har",
	"Latn",
}

m["ams"] = {
	"tiếng Nam Amami Ōshima",
	2840986,
	"jpx-nry",
	"Jpan",
	"Tiếng Nam Amami Ōshima",
	"Nam Amami Ōshima",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["amt"] = {
	"Amto",
	56517,
	"paa-asa",
	"Latn",
}

m["amu"] = {
	"tiếng Amuzgo",
	3501942,
	"omq",
	"Latn",
	"Tiếng Amuzgo",
	"Amuzgo",
}

m["amv"] = {
	"Ambelau",
	2669214,
	"poz-cma",
	"Latn",
}

m["amw"] = {
	"tiếng Tân Aram Tây",
	34226,
	"sem-arw",
	"Armi, Syrc, Latn",
	"Tiếng Tân Aram Tây",
	"Tân Aram Tây",
	entry_name = {Syrc = "Syrc-entryname"},
}

m["amx"] = {
	"Anmatyerre",
	10412317,
	"aus-pam",
	"Latn",
}

m["amy"] = {
	"Ami",
	12626835,
	"aus-dal",
	"Latn",
}

m["amz"] = {
	"Atampaya",
	3446651,
	"aus-pam",
	"Latn",
}

m["ana"] = {
	"Andaqui",
	2846078,
	nil,
	"Latn",
}

m["anb"] = {
	"Andoa",
	2846171,
	"sai-zap",
	"Latn",
}

m["anc"] = {
	"tiếng Ngas",
	35999,
	"cdc-wst",
	"Latn",
	"Tiếng Ngas",
	"Ngas",
}

m["and"] = {
	"Ansus",
	3513300,
	"poz-hce",
	"Latn",
}

m["ane"] = {
	"tiếng Xârâcùù",
	3571097,
	"poz-cln",
	"Latn",
	"Tiếng Xârâcùù",
	"Xârâcùù",
}

m["anf"] = {
	"Animere",
	34783,
	"alv-ktg",
	"Latn",
}

m["ang"] = {
	"tiếng Anh cổ",
	42365,
	"gmw-ang",
	"Latn, Runr",
	"Tiếng Anh cổ",
	"Anh cổ",
	translit = {Runr = "Runr-translit"},
	entry_name = {
		Latn = {
			remove_diacritics = c.acute .. c.macron .. c.dotabove,
			from = {"Ƿ", "ƿ"},
			to = {"W", "w"}
		},
	},
	sort_key = {
		Latn = {
			from = {"æ", "ð", "þ", "ƿ"},
			to = {"ae", "t" .. p[1], "t" .. p[2], "w" .. p[1]}
		},
	},
}

m["anh"] = {
	"Nend",
	6991554,
	"ngf-mad",
	"Latn",
}

m["ani"] = {
	"tiếng Andi",
	34849,
	"cau-and",
	"Cyrl",
	"Tiếng Andi",
	"Andi",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
}

m["anj"] = {
	"Anor",
	56458,
	"paa",
	"Latn",
}

m["ank"] = {
	"Goemai",
	35272,
	"cdc-wst",
	"Latn",
}

m["anl"] = {
	"Anu",
	4777679,
	"sit-mru",
	"Latn",
}

m["anm"] = {
	"tiếng Anal",
	56235,
	"tbq-kuk",
	"Latn",
	"Tiếng Anal",
	"Anal",
}

m["ann"] = {
	"Obolo",
	36614,
	"nic-lcr",
	"Latn",
}

m["ano"] = {
	"Andoque",
	2669225,
	"qfa-iso",
	"Latn",
}

m["anp"] = {
	"tiếng Angika",
	28378,
	"inc-bih",
	"Deva, Kthi",
	"Tiếng Angika",
	"Angika",
	translit = {
		Deva = "hi-translit",
		Kthi = "bho-Kthi-translit",
	},
	ancestors = "bh",
}

m["anq"] = {
	"tiếng Jarawa",
	2475526,
	"qfa-ong",
	"Latn, Deva",
	"Tiếng Jarawa",
	"Jarawa",
}

m["anr"] = {
	"Andh",
	4754314,
	"inc-sou",
	"Deva",
}

m["ans"] = {
	"Anserma",
	3446613,
	"sai-chc",
	"Latn",
}

m["ant"] = {
	"Antakarinya",
	921304,
	"aus-psw",
	"Latn",
}

m["anu"] = {
	"tiếng Anuak",
	56677,
	"sdv-lon",
	"Latn, Ethi",
	"Tiếng Anuak",
	"Anuak",
}

m["anv"] = {
	"Denya",
	35187,
	"nic-mam",
	"Latn",
}

m["anw"] = {
	"tiếng Anaang",
	2845320,
	"nic-ief",
	"Latn",
	"Tiếng Anaang",
	"Anaang",
}

m["anx"] = {
	"Andra-Hus",
	2846195,
	"poz-aay",
	"Latn",
}

m["any"] = {
	"tiếng Anyi",
	28395,
	"alv-ctn",
	"Latn",
	"Tiếng Anyi",
	"Anyi",
}

m["anz"] = {
	"Anem",
	56512,
	"paa",
	"Latn",
}

m["aoa"] = {
	"tiếng Angola",
	34994,
	"crp",
	"Latn",
	"Tiếng Angola",
	"Angola",
	ancestors = "pt",
}

m["aob"] = {
	"Abom",
	3446647,
	"ngf",
	"Latn",
}

m["aoc"] = {
	"tiếng Pemon",
	10729616,
	"sai-pem",
	"Latn",
	"Tiếng Pemon",
	"Pemon",
}

m["aod"] = {
	"Andarum",
	3507888,
	"paa",
	"Latn",
}

m["aoe"] = {
	"Angal Enen",
	10951638,
	"paa-eng",
	"Latn",
}

m["aof"] = {
	"Bragat",
	3507977,
	"qfa-tor",
	"Latn",
}

m["aog"] = {
	"Angoram",
	56366, -- cf 6754745 for merged dialect
	"paa-lsp",
	"Latn",
}

m["aoi"] = {
	"Anindilyakwa",
	2714654,
	"aus-arn",
	"Latn",
}

m["aoj"] = {
	"Mufian",
	3507881,
	"qfa-tor",
	"Latn",
}

m["aok"] = {
	"Arhö",
	4790086,
	"poz-cln",
	"Latn",
}

m["aol"] = {
	"Alor",
	3332062,
	"poz",
	"Latn",
}

m["aom"] = {
	"Ömie",
	8078975,
	"ngf",
	"Latn",
}

m["aon"] = {
	"Bumbita Arapesh",
	3508044,
	"qfa-tor",
	"Latn",
}

m["aor"] = {
	"Aore",
	12627129,
	"poz-vnc",
	"Latn",
}

m["aos"] = {
	"Taikat",
	7676018,
	"paa-brd",
	"Latn",
}

m["aot"] = {
	"tiếng Atong (Ấn Độ)",
	5646,
	"tbq-bdg",
	"Latn, Beng",
	"Tiếng Atong (Ấn Độ)",
	"Atong (Ấn Độ)",
}

m["aou"] = {
	"tiếng A'ou",
	16109994,
	"qfa-gel",
	"Latn", -- also Hani?
	"Tiếng A'ou",
	"A'ou",
}

m["aox"] = {
	"Atorada",
	3507932,
	"awd",
	"Latn",
}

m["aoz"] = {
	"Uab Meto",
	3441962,
	"poz-tim",
	"Latn",
}

m["apb"] = {
	"Sa'a",
	36294,
	"poz-sls",
	"Latn",
}

m["apc"] = {
	"tiếng Ả Rập Bắc Levant",
	22809485,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Bắc Levant",
	"Ả Rập Bắc Levant",
	entry_name = "ar-entryname",
}

m["apd"] = {
	"tiếng Ả Rập Sudan",
	56573,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Sudan",
	"Ả Rập Sudan",
	entry_name = "ar-entryname",
}

m["ape"] = {
	"tiếng Bukiyip",
	3507895,
	"paa-ara",
	"Latn",
}

m["apf"] = {
	"Pahanan Agta",
	7135432,
	"phi",
	"Latn",
}

m["apg"] = {
	"Ampanang",
	4748035,
	"poz",
	"Latn",
}

m["aph"] = {
	"tiếng Athpariya",
	3449126,
	"sit-kie",
	"Deva, Latn",
	"Tiếng Athpariya",
	"Athpariya",
}

m["api"] = {
	"Apiaká",
	3507941,
	"tup-gua",
	"Latn",
}

m["apj"] = {
	"tiếng Jicarilla",
	28277,
	"apa",
	"Latn",
	"Tiếng Jicarilla",
	"Jicarilla",
}

m["apk"] = {
	"tiếng Apache đồng bằng",
	27861,
	"apa",
	"Latn",
	"Tiếng Apache đồng bằng",
	"Apache đồng bằng"
}

m["apl"] = {
	"tiếng Lipan",
	28269,
	"apa",
	"Latn",
	"Tiếng Lipan",
	"Lipan",
}

m["apm"] = {
	"tiếng Chiricahua",
	13368,
	"apa",
	"Latn",
	"Tiếng Chiricahua",
	"Chiricahua",
}

m["apn"] = {
	"tiếng Apinayé",
	2858311,
	"sai-nje",
	"Latn",
	"Tiếng Apinayé",
	"Apinayé",
}

m["apo"] = {
	"Ambul",
	12627135,
	"poz-ocw",
	"Latn",
}

m["app"] = {
	"Apma",
	2669188,
	"poz-vnc",
	"Latn",
}

m["apq"] = {
	"tiếng Pucikwar",
	28466,
	"qfa-adc",
	"Latn",
	"Tiếng Pucikwar",
	"Pucikwar",
}

m["apr"] = {
	"Arop-Lokep",
	2863482,
	"poz-ocw",
	"Latn",
}

m["aps"] = {
	"Arop-Sissano",
	12627242,
	"poz-ocw",
	"Latn",
}

m["apt"] = {
	"tiếng Apatani",
	56306,
	"sit-tan",
	"Latn",
	"Tiếng Apatani",
	"Apatani",
}

m["apu"] = {
	"Apurinã",
	2859081,
	"awd",
	"Latn",
}

m["apv"] = {
	"Alapmunte",
	16110782,
	"sai-nmk",
	"Latn",
}

m["apw"] = {
	"tiếng Apache Tây",
	28060,
	"apa",
	"Latn",
	"Tiếng Apache Tây",
	"Apache Tây",
}

m["apx"] = {
	"tiếng Aputai",
	12473343,
	"poz-tim",
	"Latn",
	"Tiếng Aputai",
	"Aputai",
}

m["apy"] = {
	"tiếng Aparaí",
	2736980,
	"sai-gui",
	"Latn",
	"Tiếng Aparaí",
	"Aparaí",
}

m["apz"] = {
	"Safeyoka",
	7398693,
	"ngf",
	"Latn",
}

m["aqc"] = {
	"tiếng Archi",
	34915,
	"cau-lzg",
	"Cyrl",
	"Tiếng Archi",
	"Archi",
	translit = "cau-nec-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {Cyrl = s["cau-Cyrl-entryname"]},
	sort_key = {
		from = {
			"ккъӏв", "ххьӏв", -- 5 chars
			"гъӏв", "ёоӏ", "ккъӏ", "ккъв", "къӏв", "ллъв", "ххьӏ", "хъӏв", "хьӏв", "ццӏв", "ччӏв", -- 4 chars
			"ааӏ", "гӏв", "гъӏ", "гъв", "гьв", "ееӏ", "ёӏ", "ёо", "ииӏ", "кӏв", "ккв", "ккъ", "къӏ", "къв", "кьв", "лӏв", "ллъ", "лъв", "льв", "ооӏ", "пӏв", "ппв", "ссв", "тӏв", "ттв", "ууӏ", "хӏв", "ххв", "хъӏ", "хъв", "хьӏ", "цӏв", "ццӏ", "ццв", "чӏв", "ччӏ", "ээӏ", "юуӏ", "яаӏ", -- 3 chars
			"аӏ", "аа", "гӏ", "гв", "гъ", "гь", "дв", "еӏ", "ее", "ё", "жв", "зв", "иӏ", "ии", "кӏ", "кв", "кк", "къ", "кь", "лӏ", "лв", "лъ", "ль", "оӏ", "оо", "пӏ", "пв", "пп", "св", "сс", "тӏ", "тв", "тт", "уӏ", "уу", "фв", "хӏ", "хв", "хх", "хъ", "цӏ", "цв", "цц", "чӏ", "чв", "шв", "щв", "эӏ", "ээ", "юӏ", "юу", "яӏ", "яа" -- 2 chars
		},
		to = {
			"к" .. p[8], "х" .. p[7],
			"г" .. p[6], "е" .. p[7], "к" .. p[7], "к" .. p[9], "к" .. p[12], "л" .. p[5], "х" .. p[6], "х" .. p[10], "х" .. p[13], "ц" .. p[6], "ч" .. p[5],
			"а" .. p[3], "г" .. p[2], "г" .. p[5], "г" .. p[7], "г" .. p[9], "е" .. p[3], "е" .. p[5], "е" .. p[6], "и" .. p[3], "к" .. p[2], "к" .. p[5], "к" .. p[6], "к" .. p[11], "к" .. p[13], "к" .. p[15], "л" .. p[2], "л" .. p[4], "л" .. p[7], "л" .. p[9], "о" .. p[3], "п" .. p[2], "п" .. p[5], "с" .. p[3], "т" .. p[2], "т" .. p[5], "у" .. p[3], "х" .. p[2], "х" .. p[5], "х" .. p[9], "х" .. p[11], "х" .. p[12], "ц" .. p[2], "ц" .. p[5], "ц" .. p[7], "ч" .. p[2], "ч" .. p[4], "э" .. p[3], "ю" .. p[3], "я" .. p[3],
			"а" .. p[1], "а" .. p[2], "г" .. p[1], "г" .. p[3], "г" .. p[4], "г" .. p[8], "д" .. p[1], "е" .. p[1], "е" .. p[2], "е" .. p[4], "ж" .. p[1], "з" .. p[1], "и" .. p[1], "и" .. p[2], "к" .. p[1], "к" .. p[3], "к" .. p[4], "к" .. p[10], "к" .. p[14], "л" .. p[1], "л" .. p[3], "л" .. p[6], "л" .. p[8], "о" .. p[1], "о" .. p[2], "п" .. p[1], "п" .. p[3], "п" .. p[4], "с" .. p[1], "с" .. p[2], "т" .. p[1], "т" .. p[3], "т" .. p[4], "у" .. p[1], "у" .. p[2], "ф" .. p[1], "х" .. p[1], "х" .. p[3], "х" .. p[4], "х" .. p[8], "ц" .. p[1], "ц" .. p[3], "ц" .. p[4], "ч" .. p[1], "ч" .. p[3], "ш" .. p[1], "щ" .. p[1], "э" .. p[1], "э" .. p[2], "ю" .. p[1], "ю" .. p[2], "я" .. p[1], "я" .. p[2]
		}
	},
}

m["aqd"] = {
	"Ampari Dogon",
	4748057,
	"nic-dgw",
	"Latn",
}

m["aqg"] = {
	"Arigidi",
	34829,
	"alv-von",
	"Latn",
}

m["aqm"] = {
	"Atohwaim",
	11732297,
	"ngf",
	"Latn",
}

m["aqn"] = {
	"Northern Alta",
	7058116,
	"phi",
	"Latn",
}

m["aqp"] = {
	"Atakapa",
	10975683,
	"qfa-iso",
	"Latn",
}

m["aqr"] = {
	"Arhâ",
	4790085,
	"poz-cln",
	"Latn",
}

m["aqt"] = {
	"Angaité",
	15736037,
	"sai-mas",
	"Latn",
}

m["aqz"] = {
	"tiếng Akuntsu",
	4701960,
	"tup",
	"Latn",
	"Tiếng Akuntsu",
	"Akuntsu",
}

m["arc"] = {
	"tiếng Aram",
	28602,
	"sem-ara",
	"Hebr, Armi, Syrc, Palm, Nbat, Phnx, Mand, Samr, Hatr, Elym",
	"Tiếng Aram",
	"Aram",
	translit = {
		Armi = "Armi-translit",
		Palm = "Palm-translit",
	},
	entry_name = {
		Hebr = {remove_diacritics = u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7)},
		Syrc = {remove_diacritics = u(0x0730) .. "-" .. u(0x0748)},
		remove_diacritics = c.macron .. c.diaer .. c.macronbelow}, -- Which script(s)?
}

m["ard"] = {
	"Arabana",
	3507959,
	"aus-kar",
	"Latn",
}

m["are"] = {
	"Western Arrernte",
	12645549,
	"aus-pam",
	"Latn",
}

m["arh"] = {
	"tiếng Arhuaco",
	2640621,
	"cba",
	"Latn",
	"Tiếng Arhuaco",
	"Arhuaco",
}

m["ari"] = {
	"Arikara",
	56539,
	"cdd",
	"Latn",
}

m["arj"] = {
	"Arapaso",
	12627166,
	"sai-tuc",
	"Latn",
}

m["ark"] = {
	"Arikapú",
	3446640,
	"sai-mje",
	"Latn",
}

m["arl"] = {
	"Arabela",
	2591221,
	"sai-zap",
	"Latn",
}

m["arn"] = {
	"tiếng Mapuche",
	33730,
	"sai-ara",
	"Latn",
	"Tiếng Mapuche",
	"Mapuche",
}

m["aro"] = {
	"Araona",
	958414,
	"sai-tac",
	"Latn",
}

m["arp"] = {
	"tiếng Arapaho",
	56417,
	"alg-ara",
	"Latn",
	"Tiếng Arapaho",
	"Arapaho",
}

m["arq"] = {
	"tiếng Ả Rập Algérie",
	56499,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Algérie",
	"Ả Rập Algérie",
	entry_name = "ar-entryname",
}

m["arr"] = {
	"Arara-Karo",
	35539,
	"tup",
	"Latn",
}

m["ars"] = {
	"tiếng Ả Rập Najd",
	56574,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Najd",
	"Ả Rập Najd",
	entry_name = "ar-entryname",
}

m["aru"] = {
	"Arua",
	2746221,
	"auf",
	"Latn",
}

m["arv"] = {
	"Arbore",
	56883,
	"cus-eas",
	"Latn",
}

m["arw"] = {
	"tiếng Lokono",
	2655664,
	"awd-taa",
	"Latn",
	"Tiếng Lokono",
	"Lokono",
}

m["arx"] = {
	"Aruá",
	3507907,
	"tup",
	"Latn",
}

m["ary"] = {
	"tiếng Ả Rập Maroc",
	56426,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Maroc",
	"Ả Rập Maroc",
	entry_name = "ar-entryname",
	sort_key = {
		from = {"^%f[" .. u(0x5D0) .. "-" .. u(0x5EA) .. "]"},
		to = {u(0xFB21)},
	},
}

m["arz"] = {
	"tiếng Ả Rập Ai Cập",
	29919,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Ai Cập",
	"Ả Rập Ai Cập",
	entry_name = "ar-entryname",
}

m["asa"] = {
	"Pare",
	36403,
	"bnt-par",
	"Latn",
}

m["asb"] = {
	"tiếng Assiniboine",
	2591288,
	"sio-dkt",
	"Latn",
	"Tiếng Assiniboine",
	"Assiniboine",
}

m["asc"] = {
	"Casuarina Coast Asmat",
	11732046,
	"ngf",
	"Latn",
}

m["ase"] = {
	"ngôn ngữ ký hiệu Mỹ",
	14759,
	"sgn",
	"Sgnw",
	"Ngôn ngữ ký hiệu Mỹ",
	"ngôn ngữ ký hiệu Mỹ",
}

m["asf"] = {
	"Auslan",
	29525,
	"sgn",
	"Latn", -- when documented
}

m["asg"] = {
	"Cishingini",
	35199,
	"nic-kam",
	"Latn",
}

m["ash"] = {
	"Abishira",
	2871740,
	"qfa-iso",
	"Latn",
}

m["asi"] = {
	"Buruwai",
	5001031,
	"ngf",
	"Latn",
}

m["asj"] = {
	"Nsari",
	36418,
	"nic-bbe",
	"Latn",
}

m["ask"] = {
	"tiếng Ashkun",
	29379,
	"nur-sou",
	"Arab, Latn",
	"Tiếng Ashkun",
	"Ashkun",
}

m["asl"] = {
	"Asilulu",
	12473347,
	"poz-cma",
	"Latn",
}

m["asn"] = {
	"Xingú Asuriní",
	8044571,
	"tup-gua",
	"Latn",
}

m["aso"] = {
	"Dano",
	5220979,
	"paa-kag",
	"Latn",
}

m["asp"] = {
	"Algerian Sign Language",
	3135421,
	"sgn",
}

m["asq"] = {
	"Austrian Sign Language",
	36668,
	"sgn",
	"Latn", -- when documented
}

m["asr"] = {
	"tiếng Asur",
	3504321,
	"mun",
	"Deva, Latn",
	"Tiếng Asur",
	"Asur"
}

m["ass"] = {
	"Ipulo",
	35408,
	"nic-tvc",
	"Latn",
}

m["ast"] = {
	"tiếng Asturias",
	29507,
	"roa-ibe",
	"Latn",
	"Tiếng Asturias",
	"Asturias",
	ancestors = "roa-ole",
}

m["asu"] = {
	"Tocantins Asurini",
	32041490,
	"tup-gua",
	"Latn",
}

m["asv"] = {
	"Asoa",
	56296,
	"csu-maa",
	"Latn",
}

m["asw"] = {
	"Australian Aboriginal Sign Language",
	955216,
	"sgn",
	"Latn", -- when documented
}

m["asx"] = {
	"Muratayak",
	11732766,
	"ngf-fin",
	"Latn",
}

m["asy"] = {
	"Yaosakor Asmat",
	16113158,
	"ngf",
	"Latn",
}

m["asz"] = {
	"As",
	2866218,
	"poz-hce",
	"Latn",
}

m["ata"] = {
	"Pele-Ata",
	56511,
	"paa",
	"Latn",
}

m["atb"] = {
	"tiếng Zaiwa",
	56594,
	"tbq-brm",
	"Latn, Lisu", -- also Hani?
	"Tiếng Zaiwa",
	"Zaiwa",
	translit = {Lisu = "Lisu-translit"},
	sort_key = {Lisu = s["Lisu-sortkey"]},
}

m["atc"] = {
	"tiếng Atsahuaca",
	4817730,
	"sai-pan",
	"Latn",
	"Tiếng Atsahuaca",
	"Atsahuaca",
}

m["atd"] = {
	"Ata Manobo",
	12627315,
	"mno",
	"Latn",
}

m["ate"] = {
	"tiếng Atemble",
	4813055,
	"ngf-mad",
	"Latn",
	"Tiếng Atemble",
	"Atemble",
}

m["atg"] = {
	"Okpela",
	7082551,
	"alv-yek",
	"Latn",
}

m["ati"] = {
	"Attié",
	34844,
	"alv-lag",
	"Latn",
}

m["atj"] = {
	"tiếng Atikamekw",
	56590,
	"alg",
	"Latn",
	ancestors = "cr",
	"Tiếng Atikamekw",
	"Atikamekw",
}

m["atk"] = {
	"Ati",
	4815751,
	"phi",
	"Latn",
}

m["atl"] = {
	"Mount Iraya Agta",
	6921430,
	"phi",
	"Latn",
}

m["atm"] = {
	"Ata",
	4812603,
	"phi",
	"Latn",
}

m["ato"] = {
	"Atong (Cameroon)",
	34824,
	"nic-grs",
	"Latn",
}

m["atp"] = {
	"Pudtol Atta",
	12640726,
	"phi",
	"Latn",
}

m["atq"] = {
	"Aralle-Tabulahan",
	4783889,
	"poz-ssw",
	"Latn",
}

m["atr"] = {
	"Waimiri-Atroari",
	56865,
	"sai-car",
	"Latn",
}

m["ats"] = {
	"Gros Ventre",
	56628,
	"alg-ara",
	"Latn",
}

m["att"] = {
	"Pamplona Atta",
	12639245,
	"phi",
	"Latn",
}

m["atu"] = {
	"Reel",
	7306882,
	"sdv-dnu",
	"Latn",
}

m["atv"] = {
	"tiếng Bắc Altai",
	2640863,
	"trk-ssb",
	"Cyrl",
	"Tiếng Bắc Altai",
	"Bắc Altai",
	translit = "Altai-translit",
}

m["atw"] = {
	"Atsugewi",
	56718,
	"nai-pal",
	"Latn",
}

m["atx"] = {
	"Arutani",
	56609,
	nil,
	"Latn",
}

m["aty"] = {
	"Aneityum",
	2379113,
	"poz-oce",
	"Latn",
}

m["atz"] = {
	"Arta",
	3508067,
	"phi",
	"Latn",
}

m["aua"] = {
	"tiếng Asumboa",
	4811870,
	"poz-oce",
	"Latn",
	"Tiếng Asumboa",
	"Asumboa",
}

m["aub"] = {
	"Alugu",
	12626798,
	"tbq-urp",
	"Latn", -- also Hani?
}

m["auc"] = {
	"Huaorani",
	758570,
	"qfa-iso",
	"Latn",
}

m["aud"] = {
	"Anuta",
	35326,
	"poz-pnp",
	"Latn",
}

m["aug"] = {
	"Aguna",
	34733,
	"alv-gbe",
	"Latn",
}

m["auh"] = {
	"Aushi",
	2872082,
	"bnt-sbi",
	"Latn",
}

m["aui"] = {
	"tiếng Anuki",
	3508132,
	"poz-ocw",
	"Latn",
	"Tiếng Anuki",
	"Anuki",
}

m["auj"] = {
	"tiếng Awjila",
	56398,
	"ber",
	"Latn, Arab, Tfng",
	"Tiếng Awjila",
	"Awjila",
}

m["auk"] = {
	"Heyo",
	3504295,
	"qfa-tor",
	"Latn",
}

m["aul"] = {
	"Aulua",
	427300,
	"poz-vnc",
	"Latn",
}

m["aum"] = {
	"Asu",
	34798,
	"alv-ngb",
	"Latn",
}

m["aun"] = {
	"Molmo One",
	12637224,
	"qfa-tor",
	"Latn",
}

m["auo"] = {
	"Auyokawa",
	56247,
	"cdc-wst",
	"Latn",
}

m["aup"] = {
	"Makayam",
	6738863,
	"ngf",
	"Latn",
}

m["auq"] = {
	"Anus",
	23855,
	"poz-ocw",
	"Latn",
}

m["aur"] = {
	"Aruek",
	3504279,
	"qfa-tor",
	"Latn",
}

m["aut"] = {
	"Austral",
	2669261,
	"poz-pep",
	"Latn",
}

m["auu"] = {
	"Auye",
	4827334,
	"ngf",
	"Latn",
}

m["auw"] = {
	"Awyi",
	3513326,
	"paa-brd",
	"Latn",
}

m["aux"] = {
	"Aurá",
	3507995,
	"tup-gua",
	"Latn",
}

m["auy"] = {
	"Auyana",
	2873211,
	"paa-kag",
	"Latn",
}

m["auz"] = {
	"tiếng Ả Rập Uzbekistan",
	3399507,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Uzbekistan",
	"Ả Rập Uzbekistan",
	entry_name = "ar-entryname",
}

m["avb"] = {
	"Avau",
	12627412,
	"poz-ocw",
	"Latn",
}

m["avd"] = {
	"Alviri-Vidari",
	3327357,
	"xme",
	"fa-Arab",
	ancestors = "xme-mid",
}

m["avi"] = {
	"Avikam",
	34840,
	"alv-lag",
	"Latn",
}

m["avk"] = {
	"tiếng Kotava",
	1377116,
	"art",
	"Latn",
	"Tiếng Kotava",
	"Kotava",
	type = "appendix-constructed",
}

m["avm"] = {
	"Angkamuthi",
	nil,
	"aus-pmn",
	"Latn",
}

m["avn"] = {
	"tiếng Avatime",
	34796,
	"alv-ktg",
	"Latn",
	"Tiếng Avatime",
	"Avatime",
}

m["avo"] = {
	"Agavotaguerra",
	3508007,
	"awd",
	"Latn",
}

m["avs"] = {
	"Aushiri",
	3409318,
	"sai-zap",
	"Latn",
}

m["avt"] = {
	"Au",
	3446608,
	"qfa-tor",
	"Latn",
}

m["avu"] = {
	"tiếng Avokaya",
	56685,
	"csu-mma",
	"Latn",
	"Tiếng Avokaya",
	"Avokaya",
}

m["avv"] = {
	"Avá-Canoeiro",
	4829584,
	"tup-gua",
	"Latn",
}

m["awa"] = {
	"tiếng Awadh",
	29579,
	"inc-hie",
	"Deva, Kthi, fa-Arab",
	"Tiếng Awadh",
	"Awadh",
	translit = {Deva = "hi-translit"},
}

m["awb"] = {
	"Awa (New Guinea)",
	2874650,
	"paa-kag",
	"Latn",
}

m["awc"] = {
	"Cicipu",
	35193,
	"nic-kam",
	"Latn",
}

m["awe"] = {
	"Awetí",
	4830038,
	"tup",
	"Latn",
}

m["awg"] = {
	"Anguthimri",
	4764288,
	"aus-pam",
	"Latn",
}

m["awh"] = {
	"Awbono",
	3446684,
	"ngf",
	"Latn",
}

m["awi"] = {
	"Aekyom",
	3399691,
	"ngf",
	"Latn",
}

m["awk"] = {
	"Awabakal",
	3449138,
	"aus-pam",
	"Latn",
}

m["awm"] = {
	"Arawum",
	4784537,
	"ngf-mad",
	"Latn",
}

m["awn"] = {
	"tiếng Awngi",
	34934,
	"cus-cen",
	"Ethi",
	"Tiếng Awngi",
	"Awngi",
}

m["awo"] = {
	"Awak",
	3446643,
	"alv-wjk",
	"Latn",
}

m["awr"] = {
	"Awera",
	56379,
	"paa-lkp",
	"Latn",
}

m["aws"] = {
	"South Awyu",
	12633986,
	"ngf",
	"Latn",
}

m["awt"] = {
	"tiếng Araweté",
	4784535,
	"tup-gua",
	"Latn",
	"Tiếng Araweté",
	"Araweté",
}

m["awu"] = {
	"Central Awyu",
	12628801,
	"ngf",
	"Latn",
}

m["awv"] = {
	"Jair Awyu",
	16110177,
	"ngf",
	"Latn",
}

m["aww"] = {
	"Awun",
	56369,
	"paa-spk",
	"Latn",
}

m["awx"] = {
	"Awara",
	2874670,
	"ngf-fin",
	"Latn",
}

m["awy"] = {
	"Edera Awyu",
	12630425,
	"ngf",
	"Latn",
}

m["axb"] = {
	"Abipon",
	11252539,
	"sai-guc",
	"Latn",
}

m["axe"] = {
	"Ayerrerenge",
	16112737,
	"aus-pam",
	"Latn",
}

m["axg"] = {
	"Mato Grosso Arára",
	3446660,
	nil,
	"Latn",
}

m["axk"] = {
	"Aka (Central Africa)",
	11010149,
	"bnt-ngn",
	"Latn",
}

m["axl"] = {
	"Lower Southern Aranda",
	6693295,
	"aus-pam",
	"Latn",
}

m["axm"] = {
	"tiếng Armenia trung đại",
	4438498,
	"hyx",
	"Armn",
	"Tiếng Armenia trung đại",
	"Armenia trung đại",
	ancestors = "xcl",
	-- Chuyển tự Armn đã có sẵn ở [[Mô đun:scripts/data]]
	override_translit = true,
	strip_diacritics = {
		remove_diacritics = "՞՜՛՟",
		from = {"եւ", "ՙ", "՚"},
		to = {"և", "ʻ", "’"}
	}
}

m["axx"] = {
	"Xaragure",
	8045635,
	"poz-cln",
	"Latn",
}

m["aya"] = {
	"Awar",
	56876,
	"paa",
	"Latn",
}

m["ayb"] = {
	"Ayizo",
	34841,
	"alv-pph",
	"Latn",
}

m["ayd"] = {
	"Ayabadhu",
	3509164,
	"aus-pmn",
	"Latn",
}

m["aye"] = {
	"tiếng Ayere",
	34788,
	"alv-aah",
	"Latn",
	"Tiếng Ayere",
	"Ayere",
}

m["ayg"] = {
	"Nyanga (Togo)",
	35446,
	"alv-gng",
	"Latn",
}

m["ayi"] = {
	"Leyigha",
	3914492,
	"nic-uce",
	"Latn",
}

m["ayk"] = {
	"Akuku",
	3450179,
	"alv-nwd",
	"Latn",
}

m["ayl"] = {
	"tiếng Ả Rập Libya",
	56503,
	"sem-arb",
	"Arab",
	entry_name = "ar-entryname",
        "Tiếng Ả Rập Libya",
        "Ả Rập Libya",
}

m["ayn"] = {
	"Yemeni Arabic",
	1686766,
	"sem-arb",
	"Arab",
	entry_name = "ar-entryname",
}

m["ayo"] = {
	"Ayoreo",
	56634,
	"sai-zam",
	"Latn",
}

m["ayp"] = {
	"tiếng Ả Rập Bắc Lưỡng Hà",
	56577,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Bắc Lưỡng Hà",
	"Ả Rập Bắc Lưỡng Hà",
	ancestors = "acm",
	entry_name = "ar-entryname",
}

m["ayq"] = {
	"Ayi",
	56449,
	"paa-spk",
	"Latn",
}

m["ays"] = {
	"Sorsogon Ayta",
	7563752,
	"phi",
	"Latn",
}

m["ayt"] = {
	"Bataan Ayta",
	4921648,
	"phi",
	"Latn",
}

m["ayu"] = {
	"tiếng Ayu",
	34786,
	"alv",
	"Latn",
}

m["ayy"] = {
	"Tayabas Ayta",
	7689745,
	"phi",
	"Latn",
}

m["ayz"] = {
	"Maybrat",
	4830892,
	"paa-wpa",
	"Latn",
}

m["aza"] = {
	"Azha",
	4832486,
	"tbq-axi",
	"Latn",
}

m["azd"] = {
	"Eastern Durango Nahuatl",
	16115449,
	"azc-nah",
	"Latn",
}

m["azg"] = {
	"San Pedro Amuzgos Amuzgo",
	35092,
	"omq",
	"Latn",
}

m["azm"] = {
	"Ipalapa Amuzgo",
	12633013,
	"omq",
	"Latn",
}

m["azn"] = {
	"Western Durango Nahuatl",
	12645553,
	"azc-nah",
	"Latn",
}

m["azo"] = {
	"tiếng Awing",
	34856,
	"nic-nge",
	"Latn",
	"Tiếng Awing",
	"Awing",
}

m["azt"] = {
	"Faire Atta",
	12630884,
	"phi",
	"Latn",
}

m["azz"] = {
	"Highland Puebla Nahuatl",
	12953754,
	"azc-nah",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")