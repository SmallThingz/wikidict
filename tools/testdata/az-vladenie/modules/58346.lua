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

m["aaa"] = {
	canonicalName = "Ghotuo",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["aab"] = {
	canonicalName = "Alumu-Tesu",
	otherNames = {"Alumu", "Tesu"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["aac"] = {
	canonicalName = "Ari",
	scripts = {"Latn"},
	family = "ngf",
}

m["aad"] = {
	canonicalName = "Amal",
	scripts = {"Latn"},
	family = "paa-iwm",
}

m["aae"] = {
	canonicalName = "Arbëreshë Albanian",
	scripts = {"Latn"},
	family = "sqj",
}

m["aaf"] = {
	canonicalName = "Aranadan",
	otherNames = {"Eranadan"},
	scripts = {"Mlym"},
	family = "dra",
}

m["aag"] = {
	canonicalName = "Ambrak",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aah"] = {
	canonicalName = "Abu' Arapesh",
	otherNames = {"Abu'", "Ua"},
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aai"] = {
	canonicalName = "Arifama-Miniafia",
	otherNames = {"Arifama", "Miniafia"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aak"] = {
	canonicalName = "Ankave",
	otherNames = {"Angave"},
	scripts = {"Latn"},
	family = "ngf",
}

m["aal"] = {
	canonicalName = "Afade",
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["aan"] = {
	canonicalName = "Anambé",
	otherNames = {"Anambe"},
	scripts = {"Latn"},
	family = "tup",
}

m["aao"] = {
	canonicalName = "Algerian Saharan Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aap"] = {
	canonicalName = "Pará Arára",
	otherNames = {"Arára"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["aaq"] = {
	canonicalName = "Penobscot",
	otherNames = {"Eastern Abenaki", "Eastern Abnaki"},
	scripts = {"Latn"},
	family = "alg",
}

m["aas"] = {
	canonicalName = "Aasax",
	otherNames = {"Aasáx", "Asa", "Aramanik", "Laramanik"},
	scripts = {"Latn"},
	family = "sdv",
}

m["aat"] = {
	canonicalName = "Arvanitika Albanian",
	scripts = {"Latn", "Grek"},
	family = "sqj",
}

m["aau"] = {
	canonicalName = "Abau",
	scripts = {"Latn"},
	family = "paa",
}

m["aaw"] = {
	canonicalName = "Solong",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aax"] = {
	canonicalName = "Mandobo Atas",
	scripts = {"Latn"},
	family = "ngf",
}

m["aaz"] = {
	canonicalName = "Amarasi",
	scripts = {"Latn"},
	family = "plf",
}

m["aba"] = {
	canonicalName = "Abé",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["abb"] = {
	canonicalName = "Bankon",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["abc"] = {
	canonicalName = "Ambala Ayta",
	scripts = {"Latn"},
	family = "phi",
}

m["abd"] = {
	canonicalName = "Camarines Norte Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["abe"] = {
	canonicalName = "Abenaki",
	otherNames = {"Western Abenaki", "Abnaki", "Western Abnaki"},
	scripts = {"Latn"},
	family = "alg",
}

m["abf"] = {
	canonicalName = "Abai Sungai",
	scripts = {"Latn"},
	family = "poz",
}

m["abg"] = {
	canonicalName = "Abaga",
	scripts = {"Latn"},
	family = "ngf",
}

m["abh"] = {
	canonicalName = "Tajiki Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
}

m["abi"] = {
	canonicalName = "Abidji",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["abj"] = {
	canonicalName = "Aka-Bea",
	otherNames = {"Bea", "Aka-Bea-da", "Akabeada", "Aka-Bia", "Bia", "Aka-Bia-da", "Akabiada", "Bojingiji"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["abl"] = {
	canonicalName = "Abung",
	otherNames = {"Pepadun", "Lampung Nyo"},
	scripts = {"Latn"},
	family = "poz",
}

m["abm"] = {
	canonicalName = "Abanyom",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["abn"] = {
	canonicalName = "Abua",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["abo"] = {
	canonicalName = "Abon",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["abp"] = {
	canonicalName = "Abenlen Ayta",
	scripts = {"Latn"},
	family = "phi",
}

m["abq"] = {
	canonicalName = "Abazin",
	scripts = {"Cyrl"},
	family = "cau-abz",
	translit_module = "abq-translit",
}

m["abr"] = {
	canonicalName = "Abron",
	otherNames = {"Brong"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["abs"] = {
	canonicalName = "Ambonese Malay",
	scripts = {"Latn"},
	family = "crp",
}

m["abt"] = {
	canonicalName = "Ambulas",
	scripts = {"Latn"},
	family = "paa",
}

m["abu"] = {
	canonicalName = "Abure",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["abv"] = {
	canonicalName = "Baharna Arabic",
	otherNames = {"Bahrani Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["abw"] = {
	canonicalName = "Pal",
	scripts = {"Latn"},
	family = "ngf",
}

m["abx"] = {
	canonicalName = "Inabaknon",
	scripts = {"Latn"},
	family = "poz-sbj",
}

m["aby"] = {
	canonicalName = "Aneme Wake",
	scripts = {"Latn"},
	family = "ngf",
}

m["abz"] = {
	canonicalName = "Abui",
	scripts = {"Latn"},
	family = "ngf",
}

m["aca"] = {
	canonicalName = "Achagua",
	otherNames = {"Achawa", "Ajagua"},
	scripts = {"Latn"},
	family = "awd",
}

m["acb"] = {
	canonicalName = "Áncá",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["acd"] = {
	canonicalName = "Gikyode",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["ace"] = {
	canonicalName = "Acehnese",
	otherNames = {"Achinese", "Atjehnese"},
	scripts = {"Latn", "Arab"},
	family = "poz-msa",
}

m["ach"] = {
	canonicalName = "Acholi",
	otherNames = {"Acoli", "Shuli", "Acooli"},
	scripts = {"Latn"},
	family = "sdv",
}

m["aci"] = {
	canonicalName = "Aka-Cari",
	otherNames = {"Cari", "Aka-Kari", "Kari", "Chariar"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["ack"] = {
	canonicalName = "Aka-Kora",
	otherNames = {"Kora"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["acl"] = {
	canonicalName = "Akar-Bale",
	otherNames = {"Bale", "Bele", "Akar-Bele", "Balawa", "Balwa", "Bojingiji"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["acm"] = {
	canonicalName = "Iraqi Arabic",
	otherNames = {"Mesopotamian Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acn"] = {
	canonicalName = "Achang",
	otherNames = {"Xiandao", "Ngochang", "Ngachang"},
	scripts = {"Latn"},
	family = "tbq",
}

m["acp"] = {
	canonicalName = "Eastern Acipa",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["acq"] = {
	canonicalName = "Ta'izzi-Adeni Arabic",
	otherNames = {"Southern Yemeni Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acr"] = {
	canonicalName = "Achi",
	otherNames = {"Achí", "Achi Maya", "Cubulco Achi", "Cubulco Achí", "Cubulco Achi'"},
	scripts = {"Latn"},
	family = "myn",
}

m["acs"] = {
	canonicalName = "Acroá",
	otherNames = {"Akroá", "Coroá", "Acroa"},
	scripts = {"Latn"},
	family = "sai-jee",
}

m["acu"] = {
	canonicalName = "Achuar",
	otherNames = {"Achuar-Shiwiar"},
	scripts = {"Latn"},
	family = "sai-jiv",
}

m["acv"] = {
	canonicalName = "Achumawi",
	scripts = {"Latn"},
	family = "nai-pal",
}

m["acw"] = {
	canonicalName = "Hijazi Arabic",
	otherNames = {"Hejazi Arabic", "West Arabian Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acx"] = {
	canonicalName = "Omani Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acy"] = {
	canonicalName = "Cypriot Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	ancestors = {"acm"},
}

m["acz"] = {
	canonicalName = "Acheron",
	otherNames = {"Asheron"},
	scripts = {"Latn"},
	family = "nic",
}

m["ada"] = {
	canonicalName = "Adangme",
	otherNames = {"Dangme"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adb"] = {
	canonicalName = "Adabe",
	scripts = {"Latn"},
	family = "ngf",
}

m["add"] = {
	canonicalName = "Dzodinka",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["ade"] = {
	canonicalName = "Adele",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adf"] = {
	canonicalName = "Dhofari Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["adg"] = {
	canonicalName = "Andegerebinha",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["adh"] = {
	canonicalName = "Adhola",
	scripts = {"Latn"},
	family = "sdv",
}

m["adi"] = {
	canonicalName = "Adi",
	scripts = {"Latn"},
	family = "tbq",
}

m["adj"] = {
	canonicalName = "Adioukrou",
	otherNames = {"Adjukru", "Adyoukrou", "Adyukru", "Ajukru"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adl"] = {
	canonicalName = "Galo",
	otherNames = {"Gallong"},
	scripts = {"Latn"},
	family = "tbq",
}

m["adn"] = {
	canonicalName = "Adang",
	scripts = {"Latn"},
	family = "ngf",
}

m["ado"] = {
	canonicalName = "Abu",
	scripts = {"Latn"},
	family = "paa",
}

m["adp"] = {
	canonicalName = "Adap",
	scripts = {"Tibt"},
	family = "tbq",
	ancestors = {"dz"},
}

m["adq"] = {
	canonicalName = "Adangbe",
	otherNames = {"Agotime"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adr"] = {
	canonicalName = "Adonara",
	scripts = {"Latn"},
	family = "plf",
}

m["ads"] = {
	canonicalName = "Adamorobe Sign Language",
	family = "sgn",
}

m["adt"] = {
	canonicalName = "Adnyamathanha",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["adu"] = {
	canonicalName = "Aduge",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["adw"] = {
	canonicalName = "Amondawa",
	otherNames = {"Amundava"},
	scripts = {"Latn"},
	family = "tup",
}

m["ady"] = {
	canonicalName = "Adyghe",
	otherNames = {"West Circassian"},
	scripts = {"Cyrl"},
	family = "cau-cir",
	translit_module = "ady-translit",
}

m["adz"] = {
	canonicalName = "Adzera",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aea"] = {
	canonicalName = "Areba",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["aeb"] = {
	canonicalName = "Tunisian Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aec"] = {
	canonicalName = "Saidi Arabic",
	otherNames = {"Sa'idi Arabic", "Upper Egyptian Arabic", "Upper Egypt Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aed"] = {
	canonicalName = "Argentine Sign Language",
	family = "sgn",
}

m["aee"] = {
	canonicalName = "Northeast Pashayi",
	family = "inc-dar",
}

m["aek"] = {
	canonicalName = "Haeke",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["ael"] = {
	canonicalName = "Ambele",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["aem"] = {
	canonicalName = "Arem",
	scripts = {"Latn"},
	family = "aav",
}

m["aen"] = {
	canonicalName = "Armenian Sign Language",
	family = "sgn",
}

m["aeq"] = {
	canonicalName = "Aer",
	family = "inc",
	ancestors = {"psu"},
}

m["aer"] = {
	canonicalName = "Eastern Arrernte",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["aes"] = {
	canonicalName = "Alsea",
	otherNames = {"Yaquina", "Yakwina", "Alseya", "Yakona"}, -- names of the two dialects that make up the language
	scripts = {"Latn"},
}

m["aeu"] = {
	canonicalName = "Akeu",
	otherNames = {"Chepya"},
	family = "tbq-lol",
}

m["aew"] = {
	canonicalName = "Ambakich",
	otherNames = {"Aion", "Porapora"},
	scripts = {"Latn"},
	family = "paa",
}

m["aey"] = {
	canonicalName = "Amele",
	scripts = {"Latn"},
	family = "ngf",
}

m["aez"] = {
	canonicalName = "Aeka",
	scripts = {"Latn"},
	family = "ngf",
}

m["afb"] = {
	canonicalName = "Gulf Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["afd"] = {
	canonicalName = "Andai",
	scripts = {"Latn"},
	family = "paa",
}

m["afe"] = {
	canonicalName = "Putukwam",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["afg"] = {
	canonicalName = "Afghan Sign Language",
	family = "sgn",
}

m["afh"] = {
	canonicalName = "Afrihili",
	type = "appendix-constructed",
	family = "art",
}

m["afi"] = {
	canonicalName = "Akrukay",
	scripts = {"Latn"},
	family = "paa",
}

m["afk"] = {
	canonicalName = "Nanubae",
	scripts = {"Latn"},
	family = "paa",
}

m["afn"] = {
	canonicalName = "Defaka",
	scripts = {"Latn"},
	family = "nic",
}

m["afo"] = {
	canonicalName = "Eloyi",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["afp"] = {
	canonicalName = "Tapei",
	scripts = {"Latn"},
	family = "paa",
}

m["afs"] = {
	canonicalName = "Afro-Seminole Creole",
	scripts = {"Latn"},
	family = "crp",
}

m["aft"] = {
	canonicalName = "Afitti",
	scripts = {"Latn"},
	family = "sdv",
}

m["afu"] = {
	canonicalName = "Awutu",
	otherNames = {"Efutu"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["afz"] = {
	canonicalName = "Obokuitai",
	scripts = {"Latn"},
	family = "paa",
}

m["aga"] = {
	canonicalName = "Aguano",
	scripts = {"Latn"},
}

m["agb"] = {
	canonicalName = "Legbo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["agc"] = {
	canonicalName = "Agatu",
	scripts = {"Latn"},
	family = "alv",
}

m["agd"] = {
	canonicalName = "Agarabi",
	scripts = {"Latn"},
	family = "paa-kag",
}

m["age"] = {
	canonicalName = "Angal",
	scripts = {"Latn"},
	family = "ngf",
}

m["agf"] = {
	canonicalName = "Arguni",
	scripts = {"Latn"},
	family = "plf",
}

m["agg"] = {
	canonicalName = "Angor",
	scripts = {"Latn"},
	family = "ngf",
}

m["agh"] = {
	canonicalName = "Ngelima",
	scripts = {"Latn"},
	family = "bnt",
}

m["agi"] = { -- spurious?
	canonicalName = "Agariya",
	family = "mun",
}

m["agj"] = {
	canonicalName = "Argobba",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["agk"] = {
	canonicalName = "Isarog Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["agl"] = {
	canonicalName = "Fembe",
	otherNames = {"Agala"},
	scripts = {"Latn"},
	family = "ngf",
}

m["agm"] = {
	canonicalName = "Angaataha",
	scripts = {"Latn"},
	family = "ngf",
}

m["agn"] = {
	canonicalName = "Agutaynen",
	scripts = {"Latn"},
	family = "phi",
}

m["ago"] = {
	canonicalName = "Tainae",
	scripts = {"Latn"},
	family = "ngf",
}

m["agq"] = {
	canonicalName = "Aghem",
	scripts = {"Latn"},
	family = "alv",
}

m["agr"] = {
	canonicalName = "Aguaruna",
	scripts = {"Latn"},
	family = "sai-jiv",
}

m["ags"] = {
	canonicalName = "Esimbi",
	otherNames = {"Isimbi"},
	scripts = {"Latn"},
	family = "nic-bod",
}

m["agt"] = {
	canonicalName = "Central Cagayan Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["agu"] = {
	canonicalName = "Aguacateco",
	otherNames = {"Awakatek", "Aguacatec"},
	scripts = {"Latn"},
	family = "myn",
}

m["agv"] = {
	canonicalName = "Remontado Agta",
	otherNames = {"Remontado Dumagat", "Sinauna", "Hatang Kayey"},
	scripts = {"Latn"},
	family = "phi",
}

m["agw"] = {
	canonicalName = "Kahua",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["agx"] = {
	canonicalName = "Aghul",
	otherNames = {"Agul"},
	scripts = {"Cyrl"},
	family = "cau-lzg",
}

m["agy"] = {
	canonicalName = "Southern Alta",
	scripts = {"Latn"},
	family = "phi",
}

m["agz"] = {
	canonicalName = "Mt. Iriga Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["aha"] = {
	canonicalName = "Ahanta",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["ahb"] = {
	canonicalName = "Axamb",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["ahg"] = {
	canonicalName = "Qimant",
	scripts = {"Latn"},
	family = "cus",
}

m["ahh"] = {
	canonicalName = "Aghu",
	scripts = {"Latn"},
	family = "ngf",
}

m["ahi"] = {
	canonicalName = "Tiagbamrin Aizi",
	scripts = {"Latn"},
	family = "kro",
}

m["ahk"] = {
	canonicalName = "Akha",
	family = "tbq-lol",
}

m["ahl"] = {
	canonicalName = "Igo",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["ahm"] = {
	canonicalName = "Mobumrin Aizi",
	scripts = {"Latn"},
	family = "kro",
}

m["ahn"] = {
	canonicalName = "Àhàn",
	otherNames = {"Ahan", "Ahaan"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["aho"] = {
	canonicalName = "Ahom",
	family = "tai",
}

m["ahp"] = {
	canonicalName = "Aproumu Aizi",
	scripts = {"Latn"},
	family = "kro",
}

m["ahr"] = {
	canonicalName = "Ahirani",
	family = "inc",
	ancestors = {"khn"},
}

m["ahs"] = {
	canonicalName = "Ashe",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["aht"] = {
	canonicalName = "Ahtna",
	scripts = {"Latn"},
	family = "ath-nor",
}

m["aia"] = {
	canonicalName = "Arosi",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["aib"] = {
	canonicalName = "Aynu",
	otherNames = {"Ainu", "Ainu (China)"},
	family = "trk",
}

m["aic"] = {
	canonicalName = "Ainbai",
	scripts = {"Latn"},
	family = "paa",
}

m["aid"] = {
	canonicalName = "Alngith",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["aie"] = {
	canonicalName = "Amara",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aif"] = {
	canonicalName = "Agi",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aig"] = {
	canonicalName = "Antigua and Barbuda Creole English",
	scripts = {"Latn"},
	family = "crp",
}

m["aih"] = {
	canonicalName = "Ai-Cham",
	family = "qfa-tak",
}

m["aii"] = {
	canonicalName = "Assyrian Neo-Aramaic",
	scripts = {"Syrc"},
	family = "sem-ara",
}

m["aij"] = {
	canonicalName = "Lishanid Noshan",
	family = "sem-ara",
}

m["aik"] = {
	canonicalName = "Ake",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ail"] = {
	canonicalName = "Aimele",
	scripts = {"Latn"},
	family = "ngf",
}

m["aim"] = {
	canonicalName = "Aimol",
	family = "tbq-kuk",
}

m["ain"] = {
	canonicalName = "Ainu",
	otherNames = {"Ainu (Japan)"},
	scripts = {"Kana", "Latn", "Cyrl"},
	family = "qfa-iso",
}

m["aio"] = {
	canonicalName = "Aiton",
	family = "tai-swe",
}

m["aip"] = {
	canonicalName = "Burumakok",
	scripts = {"Latn"},
	family = "ngf",
}

m["air"] = {
	canonicalName = "Airoran",
	scripts = {"Latn"},
	family = "paa",
}

m["ais"] = {
	canonicalName = "Nataoran Amis",
	scripts = {"Latn"},
	family = "map",
}

m["ait"] = {
	canonicalName = "Arikem",
	scripts = {"Latn"},
	family = "tup",
}

m["aiw"] = {
	canonicalName = "Aari",
	scripts = {"Latn"},
	family = "omv",
}

m["aix"] = {
	canonicalName = "Aighon",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aiy"] = {
	canonicalName = "Ali",
	scripts = {"Latn"},
	family = "alv",
}

m["aja"] = {
	canonicalName = "Aja",
	otherNames = {"Adja", "Aja (Sudan)"},
	family = "csu",
}

m["ajg"] = {
	canonicalName = "Adja",
	otherNames = {"Aja", "Aja (Benin)"},
	family = "alv-kwa",
}

m["aji"] = {
	canonicalName = "Ajië",
	otherNames = {"Houailou"},
	scripts = {"Latn"},
	family = "poz-cln",
}

m["ajn"] = {
	canonicalName = "Andajin", -- sometimes considered a dialect of 'ung'
	scripts = {"Latn"},
}

m["ajp"] = {
	canonicalName = "South Levantine Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ajt"] = {
	canonicalName = "Judeo-Tunisian Arabic",
	scripts = {"Hebr"},
	family = "sem-arb",
	ancestors = {"aeb"},
}

m["aju"] = {
	canonicalName = "Judeo-Moroccan Arabic",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["ajw"] = {
	canonicalName = "Ajawa",
	family = "cdc-wst",
}

m["ajz"] = {
	canonicalName = "Amri Karbi",
	family = "tbq",
}

m["akb"] = {
	canonicalName = "Angkola Batak",
	otherNames = {"Batak Angkola"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["akc"] = {
	canonicalName = "Mpur",
	scripts = {"Latn"},
	family = "paa",
}

m["akd"] = {
	canonicalName = "Ukpet-Ehom",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ake"] = {
	canonicalName = "Akawaio",
	otherNames = {"Acauayo", "Acaguayo", "Akawai", "Acawai", "Accawai"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["akf"] = {
	canonicalName = "Akpa",
	scripts = {"Latn"},
	family = "alv",
}

m["akg"] = {
	canonicalName = "Anakalangu",
	scripts = {"Latn"},
	family = "plf",
}

m["akh"] = {
	canonicalName = "Angal Heneng",
	scripts = {"Latn"},
	family = "ngf",
}

m["aki"] = {
	canonicalName = "Aiome",
	scripts = {"Latn"},
	family = "paa",
}

m["akj"] = {
	canonicalName = "Jeru",
	otherNames = {"Aka-Jeru"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["akk"] = {
	canonicalName = "Akkadian",
	scripts = {"Xsux"},
	family = "sem-eas",
}

m["akl"] = {
	canonicalName = "Aklanon",
	otherNames = {"Aklan", "Akeanon"},
	scripts = {"Latn"},
	family = "phi",
}

m["akm"] = {
	canonicalName = "Aka-Bo",
	otherNames = {"Ba", "Bo"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["ako"] = {
	canonicalName = "Akurio",
	scripts = {"Latn"},
	family = "sai-car",
}

m["akp"] = {
	canonicalName = "Siwu",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["akq"] = {
	canonicalName = "Ak",
	scripts = {"Latn"},
	family = "paa",
}

m["akr"] = {
	canonicalName = "Araki",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["aks"] = {
	canonicalName = "Akaselem",
	scripts = {"Latn"},
	family = "nic-gur",
}

m["akt"] = {
	canonicalName = "Akolet",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aku"] = {
	canonicalName = "Akum",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["akv"] = {
	canonicalName = "Akhvakh",
	scripts = {"Cyrl"},
	family = "cau-ava",
}

m["akw"] = {
	canonicalName = "Akwa",
	scripts = {"Latn"},
	family = "bnt",
}

m["akx"] = {
	canonicalName = "Aka-Kede",
	otherNames = {"Kede"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["aky"] = {
	canonicalName = "Aka-Kol",
	otherNames = {"Kol", "Kawl", "Aka-Kawl", "Bojingiji"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["akz"] = {
	canonicalName = "Alabama",
	scripts = {"Latn"},
	family = "nai-mus",
}

m["ala"] = {
	canonicalName = "Alago",
	scripts = {"Latn"},
	family = "alv",
}

m["alc"] = {
	canonicalName = "Kawésqar",
	otherNames = {"Qawasqar", "Alacaluf"},
	scripts = {"Latn"},
	family = "aqa",
}

m["ald"] = {
	canonicalName = "Alladian",
	otherNames = {"Alladyan", "Allagian", "Alaguian"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["ale"] = {
	canonicalName = "Aleut",
	otherNames = {"Aleutian"},
	scripts = {"Latn"},
	family = "esx",
}

m["alf"] = {
	canonicalName = "Alege",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["alh"] = {
	canonicalName = "Alawa",
	scripts = {"Latn"},
}

m["ali"] = {
	canonicalName = "Amaimon",
	scripts = {"Latn"},
	family = "ngf",
}

m["alj"] = {
	canonicalName = "Alangan",
	scripts = {"Latn"},
	family = "phi",
}

m["alk"] = {
	canonicalName = "Alak",
	family = "mkh",
}

m["all"] = {
	canonicalName = "Allar",
	otherNames = {"Chatan"},
	family = "dra",
}

m["alm"] = {
	canonicalName = "Amblong",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["aln"] = {
	canonicalName = "Gheg Albanian",
	scripts = {"Latn"},
	family = "sqj",
}

m["alo"] = {
	canonicalName = "Larike-Wakasihu",
	scripts = {"Latn"},
	family = "plf",
}

m["alp"] = {
	canonicalName = "Alune",
	scripts = {"Latn"},
	family = "plf",
}

m["alq"] = {
	canonicalName = "Algonquin",
	scripts = {"Latn"},
	family = "alg",
}

m["alr"] = {
	canonicalName = "Alutor",
	scripts = {"Cyrl"},
	family = "qfa-cka",
}

m["alt"] = {
	canonicalName = "Southern Altai",
	otherNames = {"Southern Altay", "Altai", "Altay"},
	scripts = {"Cyrl"},
	translit_module = "Altai-translit",
	family = "trk",
}

m["alu"] = {
	canonicalName = "'Are'are",
	otherNames = {"Areare"},
	scripts = {"Latn"},
	family = "poz-sls",
}

m["alw"] = {
	canonicalName = "Alaba",
	otherNames = {"Alaba-K'abeena", "Alaaba", "K'abeena"},
	scripts = {"Latn"},
	family = "cus",
}

m["alx"] = {
	canonicalName = "Amol",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aly"] = {
	canonicalName = "Alyawarr",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["alz"] = {
	canonicalName = "Alur",
	scripts = {"Latn"},
	family = "sdv",
}

m["ama"] = {
	canonicalName = "Amanayé",
	scripts = {"Latn"},
	family = "tup",
}

m["amb"] = {
	canonicalName = "Ambo",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["amc"] = {
	canonicalName = "Amahuaca",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["ame"] = {
	canonicalName = "Yanesha'",
	otherNames = {"Amuesha"},
	scripts = {"Latn"},
	family = "awd",
}

m["amf"] = {
	canonicalName = "Hamer-Banna",
	scripts = {"Latn"},
	family = "omv",
}

m["amg"] = {
	canonicalName = "Amurdag",
	otherNames = {"Amarag"},
	scripts = {"Latn"},
	family = "aus-wdj",
}

m["ami"] = {
	canonicalName = "Amis",
	scripts = {"Latn"},
	family = "map",
}

m["amj"] = {
	canonicalName = "Amdang",
	otherNames = {"Biltine", "Mimi"},
	scripts = {"Latn"},
	family = "ssa-fur",
}

m["amk"] = {
	canonicalName = "Ambai",
	otherNames = {"Wadapi-Laut"},
	scripts = {"Latn"},
	family = "poz-hce",
}

m["aml"] = {
	canonicalName = "War-Jaintia",
	scripts = {"Latn"},
	family = "aav",
}

m["amm"] = {
	canonicalName = "Ama",
	otherNames = {"Ama (New Guinea)", "Ama (Papua New Guinea)"},
	scripts = {"Latn"},
	family = "qfa-mal",
}

m["amn"] = {
	canonicalName = "Amanab",
	scripts = {"Latn"},
	family = "ngf",
}

m["amo"] = {
	canonicalName = "Amo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["amp"] = {
	canonicalName = "Alamblak",
	scripts = {"Latn"},
	family = "paa",
}

m["amq"] = {
	canonicalName = "Amahai",
	scripts = {"Latn"},
	family = "plf",
}

m["amr"] = {
	canonicalName = "Amarakaeri",
}

m["ams"] = {
	canonicalName = "Southern Amami-Oshima",
	family = "jpx-ryu",
}

m["amt"] = {
	canonicalName = "Amto",
	scripts = {"Latn"},
	family = "paa",
}

m["amu"] = {
	canonicalName = "Guerrero Amuzgo",
	otherNames = {"Amuzgo", "Xochistlahuaca Amuzgo", "Northern Amuzgo", "Southern Amuzgo"},
	scripts = {"Latn"},
	family = "omq",
}

m["amv"] = {
	canonicalName = "Ambelau",
	scripts = {"Latn"},
	family = "poz",
}

m["amw"] = {
	canonicalName = "Western Neo-Aramaic",
	family = "sem-ara",
}

m["amx"] = {
	canonicalName = "Anmatyerre",
	otherNames = {"Namfau"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["amy"] = {
	canonicalName = "Ami",
	otherNames = {"Ame", "Amijangal"},
}

m["amz"] = {
	canonicalName = "Atampaya",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["ana"] = {
	canonicalName = "Andaqui",
}

m["anb"] = {
	canonicalName = "Andoa",
	scripts = {"Latn"},
	family = "sai-zap",
}

m["anc"] = {
	canonicalName = "Angas",
	family = "cdc-wst",
}

m["and"] = {
	canonicalName = "Ansus",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["ane"] = {
	canonicalName = "Xârâcùù",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["anf"] = {
	canonicalName = "Animere",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["ang"] = {
	canonicalName = "Old English",
	otherNames = {"Anglo-Saxon"},
	scripts = {"Latinx"},
	family = "gmw",
	entry_name = {
		from = {"Ā", "ā", "Ǣ", "ǣ", "Ċ", "ċ", "Ē", "ē", "Ġ", "ġ", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ", "Á", "á", "Ǽ", "ǽ", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", "Ý", "ý"},
		to   = {"A", "a", "Æ", "æ", "C", "c", "E", "e", "G", "g", "I", "i", "O", "o", "U", "u", "Y", "y", "A", "a", "Æ", "æ", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}} ,
}

m["anh"] = {
	canonicalName = "Nend",
	scripts = {"Latn"},
	family = "ngf",
}

m["ani"] = {
	canonicalName = "Andi",
	scripts = {"Cyrl"},
	family = "cau-ava",
}

m["anj"] = {
	canonicalName = "Anor",
	scripts = {"Latn"},
	family = "paa",
}

m["ank"] = {
	canonicalName = "Goemai",
	family = "cdc-wst",
}

m["anl"] = {
	canonicalName = "Anu",
	otherNames = {"Khaungtso", "Anu-Hkongso Chin"}, -- the last name is the one used by the ISO, an unattested blend of the names of the lect's two dialects and half of the name of the place where it is spoken
	family = "tbq",
}

m["anm"] = {
	canonicalName = "Anal",
	otherNames = {"Namfau"}, -- the latter is a placename, not properly a language name, though it is encountered as one
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["ann"] = {
	canonicalName = "Obolo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ano"] = {
	canonicalName = "Andoque",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["anp"] = {
	canonicalName = "Angika",
	family = "inc",
	ancestors = {"bh"},
}

m["anq"] = {
	canonicalName = "Jarawa",
	otherNames = {"Jarawa (India)"},
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["anr"] = {
	canonicalName = "Andh",
	family = "inc",
}

m["ans"] = {
	canonicalName = "Anserma",
}

m["ant"] = {
	canonicalName = "Antakarinya",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["anu"] = {
	canonicalName = "Anuak",
	scripts = {"Latn"},
	family = "sdv",
}

m["anv"] = {
	canonicalName = "Denya",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["anw"] = {
	canonicalName = "Anaang",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["anx"] = {
	canonicalName = "Andra-Hus",
	scripts = {"Latn"},
	family = "poz-aay",
}

m["any"] = {
	canonicalName = "Anyi",
	otherNames = {"Anyin"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["anz"] = {
	canonicalName = "Anem",
}

m["aoa"] = {
	canonicalName = "Angolar",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"pt"},
}

m["aob"] = {
	canonicalName = "Abom",
	scripts = {"Latn"},
	family = "ngf",
}

m["aoc"] = {
	canonicalName = "Pemon",
	otherNames = {"Arekuna", "Arecuna"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["aod"] = {
	canonicalName = "Andarum",
	scripts = {"Latn"},
	family = "paa",
}

m["aoe"] = {
	canonicalName = "Angal Enen",
	scripts = {"Latn"},
	family = "ngf",
}

m["aof"] = {
	canonicalName = "Bragat",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aog"] = {
	canonicalName = "Angoram",
}

m["aoh"] = {
	canonicalName = "Arma",
}

m["aoi"] = {
	canonicalName = "Anindilyakwa",
	otherNames = {"Enindhilyagwa"},
	scripts = {"Latn"},
	family = "aus-arn",
}

m["aoj"] = {
	canonicalName = "Mufian",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aok"] = {
	canonicalName = "Arhö",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["aol"] = {
	canonicalName = "Alor",
	otherNames = {"Alorese"},
	family = "poz",
}

m["aom"] = {
	canonicalName = "Ömie",
	scripts = {"Latn"},
	family = "ngf",
}

m["aon"] = {
	canonicalName = "Bumbita Arapesh",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["aor"] = {
	canonicalName = "Aore",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["aos"] = {
	canonicalName = "Taikat",
	scripts = {"Latn"},
	family = "paa",
}

m["aot"] = {
	canonicalName = "Atong (India)",
	otherNames = {"Atong", "A'tong"},
	family = "tbq",
}

m["aou"] = {
	canonicalName = "A'ou",
	otherNames = {"Ayo", "A'ou Gelao"},
	family = "qfa-tak",
}

m["aox"] = {
	canonicalName = "Atorada",
	family = "awd",
}

m["aoz"] = {
	canonicalName = "Uab Meto",
	scripts = {"Latn"},
	family = "plf",
}

m["apb"] = {
	canonicalName = "Sa'a",
	otherNames = {"South Malaita", "Apae'aa"},
	family = "poz-sls",
}

m["apc"] = {
	canonicalName = "North Levantine Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["apd"] = {
	canonicalName = "Sudanese Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ape"] = {
	canonicalName = "Bukiyip",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["apf"] = {
	canonicalName = "Pahanan Agta",
	scripts = {"Latn"},
	family = "phi",
}

m["apg"] = {
	canonicalName = "Ampanang",
	scripts = {"Latn"},
	family = "poz",
}

m["aph"] = {
	canonicalName = "Athpare",
	otherNames = {"Athpariya"},
	family = "tbq",
}

m["api"] = {
	canonicalName = "Apiaká",
}

m["apj"] = {
	canonicalName = "Jicarilla",
	otherNames = {"Jicarilla Apache"},
	scripts = {"Latn"},
	family = "apa",
}

m["apk"] = {
	canonicalName = "Plains Apache",
	otherNames = {"Kiowa Apache"},
	scripts = {"Latn"},
	family = "apa",
}

m["apl"] = {
	canonicalName = "Lipan",
	otherNames = {"Lipan Apache"},
	scripts = {"Latn"},
	family = "apa",
}

m["apm"] = {
	canonicalName = "Chiricahua",
	otherNames = {"Mescalero", "Mescalero-Chiricahua Apache"}, -- two dialects combined by Ethnologue
	scripts = {"Latn"},
	family = "apa",
}

m["apn"] = {
	canonicalName = "Apinayé",
	otherNames = {"Apinajé", "Apinagé", "Apinaye", "Apinaje", "Apinage"},
	scripts = {"Latn"},
	family = "sai-mje",
}

m["apo"] = {
	canonicalName = "Ambul",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["app"] = {
	canonicalName = "Apma",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["apq"] = {
	canonicalName = "A-Pucikwar",
	otherNames = {"Pucikwar", "Puchikwar", "Aka-Pucikwar", "Pujjukar", "Bójigiáb", "Bojigiab", "Bojigyab"}, -- last three may apply also to other languages
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["apr"] = {
	canonicalName = "Arop-Lokep",
}

m["aps"] = {
	canonicalName = "Arop-Sissano",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["apt"] = {
	canonicalName = "Apatani",
	family = "tbq",
}

m["apu"] = {
	canonicalName = "Apurinã",
	scripts = {"Latn"},
	family = "awd",
}

m["apv"] = {
	canonicalName = "Alapmunte",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["apw"] = {
	canonicalName = "Western Apache",
	scripts = {"Latn"},
	family = "apa",
}

m["apx"] = {
	canonicalName = "Aputai",
}

m["apy"] = {
	canonicalName = "Apalaí",
	otherNames = {"Apalai"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["apz"] = {
	canonicalName = "Safeyoka",
}

m["aqc"] = {
	canonicalName = "Archi",
	scripts = {"Cyrl"},
	family = "cau-lzg",
}

m["aqd"] = {
	canonicalName = "Ampari Dogon",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["aqg"] = {
	canonicalName = "Arigidi",
}

m["aqm"] = {
	canonicalName = "Atohwaim",
}

m["aqn"] = {
	canonicalName = "Northern Alta",
}

m["aqp"] = {
	canonicalName = "Atakapa",
	otherNames = {"Akokisa", "Orcoquiza", "Eastern Atakapa", "Western Atakapa"},
	scripts = {"Latn"},
}

m["aqr"] = {
	canonicalName = "Arhâ",
	family = "poz-cln",
}

m["aqt"] = {
	canonicalName = "Angaité",
}

m["aqz"] = {
	canonicalName = "Akuntsu",
	family = "tup",
}

m["arc"] = {
	canonicalName = "Aramaic",
	otherNames = {"Imperial Aramaic", "Official Aramaic", "Biblical Aramaic"},
	scripts = {"Hebr", "Armi", "Syrc", "Palm", "Nbat", "Phnx", "Mand", "Samr"},
	family = "sem-ara",
	entry_name = {
		from = {"[" .. u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. "]", "[" .. u(0x0304) .. u(0x0308) .. u(0x0331) .. u(0x0730) .. "-" .. u(0x0748) .. "]" },
		to   = {}} ,
}

m["ard"] = {
	canonicalName = "Arabana",
	family = "aus-kar",
}

m["are"] = {
	canonicalName = "Western Arrernte",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["arh"] = {
	canonicalName = "Arhuaco",
	otherNames = {"Ika"},
	scripts = {"Latn"},
}

m["ari"] = {
	canonicalName = "Arikara",
	family = "cdd",
}

m["arj"] = {
	canonicalName = "Arapaso",
}

m["ark"] = {
	canonicalName = "Arikapú",
}

m["arl"] = {
	canonicalName = "Arabela",
	scripts = {"Latn"},
	family = "sai-zap",
}

m["arn"] = {
	canonicalName = "Mapudungun",
	scripts = {"Latn"},
	family = "sai-ara",
	otherNames = {"Mapuche", "Mapudungün", "Mapuzugün", "Mapudungu", "Araucanian"}
}

m["aro"] = {
	canonicalName = "Araona",
	scripts = {"Latn"},
	family = "sai-tac",
}

m["arp"] = {
	canonicalName = "Arapaho",
	scripts = {"Latn"},
	family = "alg",
}

m["arq"] = {
	canonicalName = "Algerian Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["arr"] = {
	canonicalName = "Arara-Karo",
	otherNames = {"Karo", "Karo (Brazil)"},
}

m["ars"] = {
	canonicalName = "Najdi Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aru"] = {
	canonicalName = "Arua",
	otherNames = {"Aruá", "Arawa", "Arawá"}, -- extinct, spoken in northern Brazil, cf. 'arx'
	scripts = {"Latn"},
	family = "auf",
}

m["arv"] = {
	canonicalName = "Arbore",
	scripts = {"Latn"},
	family = "cus",
}

m["arw"] = {
	canonicalName = "Arawak",
	scripts = {"Latn"},
	family = "awd",
}

m["arx"] = {
	canonicalName = "Aruá",
	otherNames = {"Arua", "Aruashi", "Aruáshi", "Aruachi"}, -- moribund, spoken in central Brazil, cf. 'aru'
	family = "tup",
}

m["ary"] = {
	canonicalName = "Moroccan Arabic",
	scripts = {"Arab", "Latn"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["arz"] = {
	canonicalName = "Egyptian Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["asa"] = {
	canonicalName = "Pare",
	otherNames = {"Asu", "Asu (Tanzania)", "Chasu", "Kipare", "Southern Pare", "South Pare"},
	scripts = {"Latn"},
	family = "bnt",
}

m["asb"] = {
	canonicalName = "Assiniboine",
	family = "sio",
}

m["asc"] = {
	canonicalName = "Casuarina Coast Asmat",
}

m["asd"] = {
	canonicalName = "Asas",
}

m["ase"] = {
	canonicalName = "American Sign Language",
	otherNames = {"Ameslan", "ASL"},
	scripts = {"Sgnw"},
	family = "sgn",
}

m["asf"] = {
	canonicalName = "Auslan",
	otherNames = {"Australian Sign Language"},
}

m["asg"] = {
	canonicalName = "Cishingini",
}

m["ash"] = {
	canonicalName = "Abishira",
	otherNames = {"Tequiraca", "Tekiráka", "Abishira", "Avishiri", "Auishiri", "Agouisiri", "Avirxiri", "Abiquira", "Abigira", "Aiwa", "Aewa"},
	family = "qfa-iso",
}

m["asi"] = {
	canonicalName = "Buruwai",
}

m["asj"] = {
	canonicalName = "Nsari",
	otherNames = {"Sari", "Saari"},
	family = "nic-bod",
}

m["ask"] = {
	canonicalName = "Ashkun",
	family = "iir-nur",
}

m["asl"] = {
	canonicalName = "Asilulu",
	scripts = {"Latn"},
	family = "plf",
}

m["asn"] = {
	canonicalName = "Xingú Asuriní",
}

m["aso"] = {
	canonicalName = "Dano",
	family = "ngf",
}

m["asp"] = {
	canonicalName = "Algerian Sign Language",
	family = "sgn",
}

m["asq"] = {
	canonicalName = "Austrian Sign Language",
	family = "sgn",
}

m["asr"] = {
	canonicalName = "Asuri",
	family = "mun",
}

m["ass"] = {
	canonicalName = "Ipulo",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["ast"] = {
	canonicalName = "Asturian",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"roa-ole"},
}

m["asu"] = {
	canonicalName = "Tocantins Asurini",
}

m["asv"] = {
	canonicalName = "Asoa",
}

m["asw"] = {
	canonicalName = "Australian Aboriginal Sign Language",
	otherNames = {"Australian Aborigines Sign Language"},
	family = "sgn",
}

m["asx"] = {
	canonicalName = "Muratayak",
	family = "ngf-fin",
}

m["asy"] = {
	canonicalName = "Yaosakor Asmat",
}

m["asz"] = {
	canonicalName = "As",
	family = "poz-hce",
}

m["ata"] = {
	canonicalName = "Pele-Ata",
}

m["atb"] = {
	canonicalName = "Zaiwa",
}

m["atc"] = {
	canonicalName = "Atsahuaca",
	family = "sai-pan",
}

m["atd"] = {
	canonicalName = "Ata Manobo",
	family = "phi",
}

m["ate"] = {
	canonicalName = "Atemble",
}

m["atg"] = {
	canonicalName = "Okpela",
	otherNames = {"Ivbie North", "Arhe", "Ivbie North-Okpela-Arhe"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ati"] = {
	canonicalName = "Attié",
}

m["atj"] = {
	canonicalName = "Atikamekw",
	scripts = {"Latn"},
	family = "alg",
	ancestors = {"cr"},
}

m["atk"] = {
	canonicalName = "Ati",
}

m["atl"] = {
	canonicalName = "Mt. Iraya Agta",
	family = "phi",
}

m["atm"] = {
	canonicalName = "Ata",
}

m["atn"] = {
	canonicalName = "Ashtiani",
	family = "ira",
}

m["ato"] = {
	canonicalName = "Atong (Cameroon)",
	otherNames = {"Atoŋ", "Atong"},
	family = "nic-bod",
}

m["atp"] = {
	canonicalName = "Pudtol Atta",
	family = "phi",
}

m["atq"] = {
	canonicalName = "Aralle-Tabulahan",
}

m["atr"] = {
	canonicalName = "Waimiri-Atroari",
	family = "sai-car",
}

m["ats"] = {
	canonicalName = "Gros Ventre",
	otherNames = {"Atsina"},
	scripts = {"Latn"},
	family = "alg",
}

m["att"] = {
	canonicalName = "Pamplona Atta",
	family = "phi",
}

m["atu"] = {
	canonicalName = "Reel",
}

m["atv"] = {
	canonicalName = "Northern Altai",
	otherNames = {"Northern Altay", "Altai", "Altay"},
	scripts = {"Cyrl"},
	translit_module = "Altai-translit",
	family = "trk",
}

m["atw"] = {
	canonicalName = "Atsugewi",
	otherNames = {"Atsugé"},
	scripts = {"Latn"},
	family = "nai-pal",
}

m["atx"] = {
	canonicalName = "Arutani",
	scripts = {"Latn"},
}

m["aty"] = {
	canonicalName = "Aneityum",
	family = "poz-oce",
}

m["atz"] = {
	canonicalName = "Arta",
}

m["aua"] = {
	canonicalName = "Asumboa",
	family = "poz-oce",
}

m["aub"] = {
	canonicalName = "Alugu",
	family = "tbq-lol",
}

m["auc"] = {
	canonicalName = "Huaorani",
	otherNames = {"Waorani", "Sabela", "Wao", "Huao", "Aushiri", "Ssabela", "Wao Terero", "Auka", "Auca"},
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["aud"] = {
	canonicalName = "Anuta",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["aug"] = {
	canonicalName = "Aguna",
}

m["auh"] = {
	canonicalName = "Aushi",
}

m["aui"] = {
	canonicalName = "Anuki",
	family = "poz-ocw",
}

m["auj"] = {
	canonicalName = "Augila",
	otherNames = {"Awjilah", "Awjila"},
	family = "ber",
}

m["auk"] = {
	canonicalName = "Heyo",
	family = "qfa-tor",
}

m["aul"] = {
	canonicalName = "Aulua",
	family = "poz-vnc",
}

m["aum"] = {
	canonicalName = "Asu",
	otherNames = {"Abewa", "Asu (Nigeria)"},
	scripts = {"Latn"},
}

m["aun"] = {
	canonicalName = "Molmo One",
	family = "qfa-tor",
}

m["auo"] = {
	canonicalName = "Auyokawa",
}

m["aup"] = {
	canonicalName = "Makayam",
}

m["auq"] = {
	canonicalName = "Anus",
	otherNames = {"A", "Korur", "Korurnus"}, -- no name seems to be attested; lect may be the same as 'pdn'
	family = "poz-ocw",
}

m["aur"] = {
	canonicalName = "Aruek",
	family = "qfa-tor",
}

m["aut"] = {
	canonicalName = "Austral",
	family = "poz-pol",
}

m["auu"] = {
	canonicalName = "Auye",
}

m["auw"] = {
	canonicalName = "Awyi",
}

m["aux"] = {
	canonicalName = "Aurá",
}

m["auy"] = {
	canonicalName = "Auyana",
}

m["auz"] = {
	canonicalName = "Uzbeki Arabic",
	otherNames = {"Uzbek Arabic"},
	family = "sem-arb",
}

m["avb"] = {
	canonicalName = "Avau",
	family = "poz-ocw",
}

m["avd"] = {
	canonicalName = "Alviri-Vidari",
	otherNames = {"Alviri", "Vidari"},
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"ira-azr"},
}

m["avi"] = {
	canonicalName = "Avikam",
	family = "alv-kwa",
}

m["avk"] = {
	canonicalName = "Kotava",
	type = "appendix-constructed",
	family = "art",
}

m["avl"] = {
	canonicalName = "Eastern Egyptian Bedawi Arabic",
	otherNames = {"Bedawi Arabic", "Levantine Bedawi Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["avm"] = {
	canonicalName = "Angkamuthi", -- sometimes considered a dialect of 'urf'
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["avn"] = {
	canonicalName = "Avatime",
	family = "alv-kwa",
}

m["avo"] = {
	canonicalName = "Agavotaguerra",
	family = "awd",
}

m["avs"] = {
	canonicalName = "Aushiri",
	family = "sai-zap",
}

m["avt"] = {
	canonicalName = "Au",
	family = "qfa-tor",
}

m["avu"] = {
	canonicalName = "Avokaya",
}

m["avv"] = {
	canonicalName = "Avá-Canoeiro",
	otherNames = {"Avá", "Canoe"},
	family = "tup",
}

m["awa"] = {
	canonicalName = "Awadhi",
	scripts = {"Deva", "Kthi", "fa-Arab"},
	family = "inc",
	ancestors = {"psu"},
}

m["awb"] = {
	canonicalName = "Awa (New Guinea)",
	otherNames = {"Awa", "Awa (Papua New Guinea)"},
}

m["awc"] = {
	canonicalName = "Cicipu",
	family = "nic-bco",
}

m["awe"] = {
	canonicalName = "Awetí",
	family = "tup",
}

m["awg"] = {
	canonicalName = "Anguthimri",
	otherNames = {"Alngith", "Leningitij", "Mpakwithi"},
	family = "aus-pam",
}

m["awh"] = {
	canonicalName = "Awbono",
}

m["awi"] = {
	canonicalName = "Aekyom",
	otherNames = {"Awin"},
}

m["awk"] = {
	canonicalName = "Awabakal",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["awm"] = {
	canonicalName = "Arawum",
	family = "ngf",
}

m["awn"] = {
	canonicalName = "Awngi",
	family = "cus",
}

m["awo"] = {
	canonicalName = "Awak",
	family = "alv",
}

m["awr"] = {
	canonicalName = "Awera",
	family = "paa-lkp",
}

m["aws"] = {
	canonicalName = "South Awyu",
	family = "ngf",
}

m["awt"] = {
	canonicalName = "Araweté",
	family = "tup",
}

m["awu"] = {
	canonicalName = "Central Awyu",
}

m["awv"] = {
	canonicalName = "Jair Awyu",
}

m["aww"] = {
	canonicalName = "Awun",
}

m["awx"] = {
	canonicalName = "Awara",
	family = "ngf-fin",
}

m["awy"] = {
	canonicalName = "Edera Awyu",
	family = "ngf",
}

m["axb"] = {
	canonicalName = "Abipon",
	otherNames = {"Abipón", "Callaga", "Kalyaga"},
	family = "sai-guc",
}

m["axe"] = {
	canonicalName = "Ayerrerenge", -- a variety of Arrernte
	family = "aus-pam",
}

m["axg"] = {
	canonicalName = "Mato Grosso Arára",
}

m["axk"] = {
	canonicalName = "Aka (Central Africa)",
	otherNames = {"Yaka", "Yaka (Central African Republic)", "Aka", "Beka"}, -- distinguish from 'iyx' and 'yaf'
	scripts = {"Latn"},
	family = "bnt",
}

m["axl"] = {
	canonicalName = "Lower Southern Aranda",
}

m["axm"] = {
	canonicalName = "Middle Armenian",
	scripts = {"Armn"},
	family = "hyx",
	ancestors = {"xcl"},
	translit_module = "Armn-translit",
	entry_name = {
		from = {"՞", "՜", "՛", "՟", "և"},
		to   = {"", "", "", "", "եւ"}} ,
}

m["axx"] = {
	canonicalName = "Xaragure",
	otherNames = {"Xârâgurè"},
	family = "poz-cln",
}

m["aya"] = {
	canonicalName = "Awar",
	family = "paa",
}

m["ayb"] = {
	canonicalName = "Ayizo Gbe",
}

m["ayd"] = {
	canonicalName = "Ayabadhu",
}

m["aye"] = {
	canonicalName = "Ayere",
	scripts = {"Latn"},
	family = "alv-von",
}

m["ayg"] = {
	canonicalName = "Nyanga (Togo)",
	otherNames = {"Nyanga", "Ginyanga"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["ayh"] = {
	canonicalName = "Hadrami Arabic",
	otherNames = {"Hadhrami Arabic"},
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayi"] = {
	canonicalName = "Leyigha",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ayk"] = {
	canonicalName = "Akuku",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ayl"] = {
	canonicalName = "Libyan Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayn"] = {
	canonicalName = "Sanaani Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayo"] = {
	canonicalName = "Ayoreo",
	otherNames = {"Morotoco", "Moro", "Ayoweo", "Ayoré", "Pyeta Yovai"},
	scripts = {"Latn"},
	family = "sai-zam",
}

m["ayp"] = {
	canonicalName = "North Mesopotamian Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	ancestors = {"acm"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayq"] = {
	canonicalName = "Ayi",
	otherNames = {"Ayi (New Guinea)", "Ayi (Papua New Guinea)"},
	scripts = {"Latn"},
	family = "paa-spk",
}

m["ays"] = {
	canonicalName = "Sorsogon Ayta",
	scripts = {"Latn"},
	family = "phi",
}

m["ayt"] = {
	canonicalName = "Bataan Ayta",
	otherNames = {"Magbukun Ayta", "Mariveleño"},
	scripts = {"Latn"},
	family = "phi",
}

m["ayu"] = {
	canonicalName = "Ayu",
	scripts = {"Latn"},
	family = "alv",
}

m["ayy"] = {
	canonicalName = "Tayabas Ayta",
	scripts = {"Latn"},
	family = "phi",
}

m["ayz"] = {
	canonicalName = "Maybrat",
	otherNames = {"Mai Brat", "Ajamaru", "Ayamaru"},
	scripts = {"Latn"},
}

m["aza"] = {
	canonicalName = "Azha",
	scripts = {"Latn"},
	family = "tbq-lol",
}

m["azd"] = {
	canonicalName = "Eastern Durango Nahuatl",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["azg"] = {
	canonicalName = "San Pedro Amuzgos Amuzgo",
	otherNames = {"Upper Eastern Amuzgo", "Oaxaca Amuzgo"},
	scripts = {"Latn"},
	family = "omq",
}

m["azm"] = {
	canonicalName = "Ipalapa Amuzgo",
	otherNames = {"Lower Eastern Amuzgo"},
	scripts = {"Latn"},
	family = "omq",
}

m["azn"] = {
	canonicalName = "Western Durango Nahuatl",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["azo"] = {
	canonicalName = "Awing",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["azt"] = {
	canonicalName = "Faire Atta",
	scripts = {"Latn"},
	family = "phi",
}

m["azz"] = {
	canonicalName = "Highland Puebla Nahuatl",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

return m