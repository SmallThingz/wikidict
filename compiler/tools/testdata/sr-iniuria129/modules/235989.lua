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

-- Use these in "scripts" to save a little memory.
local Arab = {"Arab"}
local Cyrl = {"Cyrl"}
local Deva = {"Deva"}
local Latn = {"Latn"}

local m = {}

m["aaa"] = {
	"Ghotuo",
	"Q35463",
	"alv-yek",
	aliases = {"Otuo"},
	scripts = Latn,
}

m["aab"] = {
	"Alumu-Tesu",
	"Q35034",
	"nic-alu",
	otherNames = {"Alumu", "Tesu"},
	scripts = Latn,
}

m["aac"] = {
	"Ari",
	"Q1811224",
	"paa-pag",
	scripts = Latn,
}

m["aad"] = {
	"Amal",
	"Q56708",
	"paa-iwm",
	otherNames = {"Alai"},
	scripts = Latn,
}

-- "aae" IS TREATED AS "sq", SEE WT:LT

m["aaf"] = {
	"Aranadan",
	"Q3507928",
	"dra",
	aliases = {"Eranadan"},
	scripts = {"Mlym"},
}

m["aag"] = {
	"Ambrak",
	"Q4741706",
	"qfa-tor",
	scripts = Latn,
}

m["aah"] = {
	"Abu' Arapesh",
	"Q4670715",
	"qfa-tor",
	otherNames = {"Abu'", "Ua"},
	scripts = Latn,
}

m["aai"] = {
	"Arifama-Miniafia",
	"Q4790560",
	"poz-ocw",
	otherNames = {"Arifama", "Miniafia"},
	scripts = Latn,
}

m["aak"] = {
	"Ankave",
	"Q3446690",
	"ngf",
	aliases = {"Angave"},
	scripts = Latn,
}

m["aal"] = {
	"Afade",
	"Q56434",
	"cdc-cbm",
	scripts = Latn,
}

m["aan"] = {
	"Anambé",
	"Q3507873",
	"tup-gua",
	aliases = {"Anambe"},
	scripts = Latn,
}

m["aao"] = {
	"Algerian Saharan Arabic",
	"Q56725",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aap"] = {
	"Pará Arára",
	"Q56807",
	"sai-car",
	otherNames = {"Arára"},
	scripts = Latn,
}

m["aaq"] = {
	"Penobscot",
	"Q3515185",
	"alg-abp",
	otherNames = {"Eastern Abenaki", "Eastern Abnaki"},
	scripts = Latn,
}

m["aas"] = {
	"Aasax",
	"Q56620",
	"cus",
	otherNames = {"Aasáx", "Asa", "Aramanik", "Laramanik"},
	scripts = Latn,
}

-- "aat" IS TREATED AS "sq", SEE WT:LT

m["aau"] = {
	"Abau",
	"Q3073568",
	"paa-spk",
	scripts = Latn,
}

m["aaw"] = {
	"Solong",
	"Q7558834",
	"poz-ocw",
	otherNames = {"Arove", "Arawe"},
	scripts = Latn,
}

m["aax"] = {
	"Mandobo Atas",
	"Q12636156",
	"ngf",
	scripts = Latn,
}

m["aaz"] = {
	"Amarasi",
	"Q4740192",
	"poz-tim",
	scripts = Latn,
}

m["aba"] = {
	"Abé",
	"Q34833",
	"alv-lag",
	scripts = Latn,
}

m["abb"] = {
	"Bankon",
	"Q34860",
	"bnt-bsa",
	otherNames = {"Abo", "Bo", "Abaw", "Miang", "Mandouka"},
	scripts = Latn,
}

m["abc"] = {
	"Ambala Ayta",
	"Q3448896",
	"phi",
	scripts = Latn,
}

m["abd"] = {
	"Camarines Norte Agta",
	"Q3399682",
	"phi",
	otherNames = {"Manide"},
	scripts = Latn,
}

m["abe"] = {
	"Abenaki",
	"Q17502788",
	"alg-abp",
	otherNames = {"Western Abenaki", "Abnaki", "Western Abnaki"},
	scripts = Latn,
}

m["abf"] = {
	"Abai Sungai",
	"Q4663287",
	"poz-san",
	scripts = Latn,
}

m["abg"] = {
	"Abaga",
	"Q3507954",
	"paa-kag",
	scripts = Latn,
}

m["abh"] = {
	"Tajiki Arabic",
	"Q56833",
	"sem-arb",
	scripts = Arab,
}

m["abi"] = {
	"Abidji",
	"Q34781",
	"alv-lag",
	scripts = Latn,
}

m["abj"] = {
	"Aka-Bea",
	"Q2356391",
	"qfa-ads",
	otherNames = {"Bea", "Aka-Bea-da", "Akabeada", "Aka-Bia", "Bia", "Aka-Bia-da", "Akabiada", "Bojingiji"},
	scripts = Latn,
}

m["abl"] = {
	"Abung",
	"Q49215",
	"poz-lgx",
	otherNames = {"Pepadun", "Lampung Nyo"},
	scripts = Latn,
}

m["abm"] = {
	"Abanyom",
	"Q7502",
	"nic-eko",
	scripts = Latn,
}

m["abn"] = {
	"Abua",
	"Q34835",
	"nic-cde",
	scripts = Latn,
}

m["abo"] = {
	"Abon",
	"Q35121",
	"nic-tvn",
	aliases = {"Abɔ̃"},
	scripts = Latn,
}

m["abp"] = {
	"Abenlen Ayta",
	"Q3436621",
	"phi",
	scripts = Latn,
}

m["abq"] = {
	"Abaza",
	"Q27567",
	"cau-abz",
	scripts = Cyrl,
	translit_module = "abq-translit",
	override_translit = true,
}

m["abr"] = {
	"Abron",
	"Q34831",
	"alv-ctn",
	ancestors = {"ak"},
	otherNames = {"Brong"},
	scripts = Latn,
}

m["abs"] = {
	"Ambonese Malay",
	"Q3124354",
	"crp",
	ancestors = {"ms"},
	scripts = Latn,
}

m["abt"] = {
	"Ambulas",
	"Q3508015",
	"paa-spk",
	scripts = Latn,
}

m["abu"] = {
	"Abure",
	"Q34767",
	"alv-ptn",
	scripts = Latn,
}

m["abv"] = {
	"Baharna Arabic",
	"Q56576",
	"sem-arb",
	aliases = {"Bahrani Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["abw"] = {
	"Pal",
	"Q7126121",
	"ngf-mad",
	scripts = Latn,
}

m["abx"] = {
	"Inabaknon",
	"Q2820163",
	"poz-sbj",
	scripts = Latn,
}

m["aby"] = {
	"Aneme Wake",
	"Q3508107",
	"ngf",
	scripts = Latn,
}

m["abz"] = {
	"Abui",
	"Q2822110",
	"qfa-tap",
	scripts = Latn,
}

m["aca"] = {
	"Achagua",
	"Q2822982",
	"awd",
	aliases = {"Achawa", "Ajagua"},
	scripts = Latn,
}

m["acb"] = {
	"Áncá",
	"Q11130787",
	"nic-mom",
	scripts = Latn,
}

m["acd"] = {
	"Gikyode",
	"Q35256",
	"alv-gng",
	scripts = Latn,
}

m["ace"] = {
	"Acehnese",
	"Q27683",
	"cmc",
	aliases = {"Achinese", "Atjehnese"},
	scripts = {"Latn", "Arab"},
}

m["ach"] = {
	"Acholi",
	"Q34926",
	"sdv",
	aliases = {"Acoli", "Shuli", "Acooli"},
	scripts = Latn,
}

m["aci"] = {
	"Aka-Cari",
	"Q2670418",
	"qfa-adn",
	otherNames = {"Cari", "Aka-Kari", "Kari", "Chariar"},
	scripts = Latn,
}

m["ack"] = {
	"Aka-Kora",
	"Q3433680",
	"qfa-adn",
	otherNames = {"Kora"},
	scripts = Latn,
}

m["acl"] = {
	"Akar-Bale",
	"Q3436825",
	"qfa-ads",
	otherNames = {"Bale", "Bele", "Akar-Bele", "Balawa", "Balwa", "Bojingiji"},
	scripts = Latn,
}

m["acm"] = {
	"Iraqi Arabic",
	"Q56232",
	"sem-arb",
	aliases = {"Mesopotamian Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acn"] = {
	"Achang",
	"Q56582",
	"tbq-brm",
	otherNames = {"Xiandao", "Ngochang", "Ngachang"},
	scripts = Latn,
}

m["acp"] = {
	"Eastern Acipa",
	"Q5329945",
	"nic-kmk",
	scripts = Latn,
}

m["acq"] = {
	"Ta'izzi-Adeni Arabic",
	"Q56579",
	"sem-arb",
	otherNames = {"Southern Yemeni Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acr"] = {
	"Achi",
	"Q34774",
	"myn",
	otherNames = {"Achí", "Achi Maya", "Cubulco Achi", "Cubulco Achí", "Cubulco Achi'"},
	scripts = Latn,
}

m["acs"] = {
	"Acroá",
	"Q2829146",
	"sai-jee",
	aliases = {"Akroá", "Coroá", "Acroa"},
	scripts = Latn,
}

m["acu"] = {
	"Achuar",
	"Q2823170",
	"sai-jiv",
	otherNames = {"Achuar-Shiwiar"},
	scripts = Latn,
}

m["acv"] = {
	"Achumawi",
	"Q56661",
	"nai-pal",
	scripts = Latn,
}

m["acw"] = {
	"Hijazi Arabic",
	"Q56608",
	"sem-arb",
	aliases = {"Hejazi Arabic", "West Arabian Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acx"] = {
	"Omani Arabic",
	"Q56630",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acy"] = {
	"Cypriot Arabic",
	"Q56416",
	"sem-arb",
	scripts = Arab,
	ancestors = {"acm"},
}

m["acz"] = {
	"Acheron",
	"Q34769",
	"alv-tal",
	aliases = {"Asheron"},
	scripts = Latn,
}

m["ada"] = {
	"Adangme",
	"Q35141",
	"alv-gda",
	aliases = {"Dangme"},
	scripts = Latn,
}

m["adb"] = { -- rename or remove, see RFM
	"Adabe",
	"Q36872",
	scripts = Latn,
}

m["add"] = {
	"Dzodinka",
	"Q35266",
	"nic-nka",
	otherNames = {"Lidzonka"},
	scripts = Latn,
}

m["ade"] = {
	"Adele",
	"Q27740",
	"alv-ntg",
	scripts = Latn,
}

m["adf"] = {
	"Dhofari Arabic",
	"Q56565",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["adg"] = {
	"Andegerebinha",
	"Q3508123",
	"aus-pam",
	scripts = Latn,
}

m["adh"] = {
	"Adhola",
	"Q1971400",
	"sdv",
	scripts = Latn,
}

m["adi"] = {
	"Adi",
	"Q56440",
	"sit-tan",
	otherNames = {"Abor", "Ashing", "Minyong", "Mising", "Padam", "Panggi", "Pasi", "Shimong", "Ajukru"},
	scripts = Latn,
}

m["adj"] = {
	"Adioukrou",
	"Q34738",
	"alv-lag",
	aliases = {"Adjukru", "Adyoukrou", "Adyukru", "Ajukru"},
	scripts = Latn,
}

m["adl"] = {
	"Galo",
	"Q2857892",
	"sit-tan",
	otherNames = {"Gallong"},
	scripts = Latn,
}

m["adn"] = {
	"Adang",
	"Q3398276",
	"qfa-tap",
	scripts = Latn,
}

m["ado"] = {
	"Abu",
	"Q56659",
	"paa-ram",
	otherNames = {"Adjora"},
	scripts = Latn,
}

m["adp"] = {
	"Adap",
	"Q3512402",
	"sit-tib",
	scripts = {"Tibt"},
	ancestors = {"dz"},
	wikipedia_article = "Dzongkha",		-- Considered a dialect of Dzongkha
}

m["adq"] = {
	"Adangbe",
	"Q34730",
	"alv-gda",
	ancestors = {"ada"},
	otherNames = {"Agotime"},
	scripts = Latn,
}

m["adr"] = {
	"Adonara",
	"Q4684505",
	"poz-cet",
	scripts = Latn,
}

m["ads"] = {
	"Adamorobe Sign Language",
	"Q27709",
	"sgn",
	scripts = Latn, -- when documented
}

m["adt"] = {
	"Adnyamathanha",
	"Q2225391",
	"aus-psw",
	scripts = Latn,
}

m["adu"] = {
	"Aduge",
	"Q34734",
	"alv-nwd",
	ancestors = {"opa"},
	scripts = Latn,
	wikipedia_article = "Okpamheri language",
}

m["adw"] = {
	"Amondawa",
	"Q12626847",
	"tup-gua",
	aliases = {"Amundava"},
	scripts = Latn,
}

m["ady"] = {
	"Adyghe",
	"Q27776",
	"cau-cir",
	otherNames = {"West Circassian"},
	scripts = Cyrl,
	translit_module = "ady-translit",
	override_translit = true,	
}

m["adz"] = {
	"Adzera",
	nil,
	"poz-ocw",
	scripts = Latn,
}

m["aea"] = {
	"Areba",
	"Q3509129",
	"aus-pam",
	scripts = Latn,
}

m["aeb"] = {
	"Tunisian Arabic",
	"Q56240",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aec"] = {
	"Saidi Arabic",
	"Q56592",
	"sem-arb",
	aliases = {"Sa'idi Arabic", "Upper Egyptian Arabic", "Upper Egypt Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aed"] = {
	"Argentine Sign Language",
	"Q3322073",
	"sgn",
	scripts = Latn, -- when documented
}

m["aee"] = {
	"Northeast Pashayi",
	"Q12642198",
	"inc-dar",
	otherNames = {"Northeast Pashai", "Pashai"},
	scripts = Latn,
}

m["aek"] = {
	"Haeke",
	"Q5638166",
	"poz-cln",
	scripts = Latn,
}

m["ael"] = {
	"Ambele",
	"Q34818",
	"nic-grf",
	scripts = Latn,
}

m["aem"] = {
	"Arem",
	"Q3507920",
	"mkh-vie",
	scripts = Latn,
}

m["aen"] = {
	"Armenian Sign Language",
	"Q3446604",
	"sgn",
}

m["aeq"] = {
	"Aer",
	"Q3246741",
	"inc",
	scripts = Arab,
	ancestors = {"psu"},
}

m["aer"] = {
	"Eastern Arrernte",
	"Q10728232",
	"aus-pam",
	scripts = Latn,
}

m["aes"] = {
	"Alsea",
	"Q2395641",
	otherNames = {"Yaquina", "Yakwina", "Alseya", "Yakona"}, -- names of the two dialects that make up the language
	scripts = Latn,
}

m["aeu"] = {
	"Akeu",
	"Q4700657",
	"tbq-lol",
	otherNames = {"Chepya"},
	scripts = Latn,
}

m["aew"] = {
	"Ambakich",
	"Q56642",
	"paa-ram",
	otherNames = {"Aion", "Porapora"},
	scripts = Latn,
}

m["aey"] = {
	"Amele",
	"Q3508025",
	"ngf-mad",
	scripts = Latn,
}

m["aez"] = {
	"Aeka",
	"Q16110528",
	"ngf",
	otherNames = {"Aiga", "Orokaiva"}, -- last is the name of a macrolanguage
	scripts = Latn,
	wikipedia_article = "Orokaiva language", -- subvariety?
} 

m["afb"] = {
	"Gulf Arabic",
	"Q56385",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["afd"] = {
	"Andai",
	"Q4753480",
	"paa-arf",
	scripts = Latn,
}

m["afe"] = {
	"Putukwam",
	"Q3914930",
	"nic-ben",
	scripts = Latn,
}

m["afg"] = {
	"Afghan Sign Language",
	"Q4689093",
	"sgn",
}

m["afh"] = {
	"Afrihili",
	"Q384707",
	"art",
	scripts = Latn,
	type = "appendix-constructed",
}

m["afi"] = {
	"Akrukay",
	"Q57003",
	"paa-ram",
	scripts = Latn,
}

m["afk"] = {
	"Nanubae",
	"Q6964416",
	"paa-arf",
	scripts = Latn,
}

m["afn"] = {
	"Defaka",
	"Q35174",
	"nic",
	scripts = Latn,
}

m["afo"] = {
	"Eloyi",
	"Q3914066",
	"nic-plt",
	scripts = Latn,
}

m["afp"] = {
	"Tapei",
	"Q16887371",
	"paa-arf",
	scripts = Latn,
}

m["afs"] = {
	"Afro-Seminole Creole",
	"Q27867",
	"crp",
	ancestors = {"en"},
	scripts = Latn,
}

m["aft"] = {
	"Afitti",
	"Q3400829",
	"sdv-nyi",
	otherNames = {"Affiti", "Ditti"},
	scripts = Latn,
}

m["afu"] = {
	"Awutu",
	"Q34847",
	"alv-gng",
	aliases = {"Efutu"},
	scripts = Latn,
}

m["afz"] = {
	"Obokuitai",
	"Q7075258",
	"paa-lkp",
	scripts = Latn,
}

m["aga"] = {
	"Aguano",
	"Q3331203",
	scripts = Latn,
}

m["agb"] = {
	"Legbo",
	"Q35584",
	"nic-uce",
	scripts = Latn,
}

m["agc"] = {
	"Agatu",
	"Q34732",
	"alv-ido",
	scripts = Latn,
}

m["agd"] = {
	"Agarabi",
	"Q3399642",
	"paa-kag",
	scripts = Latn,
}

m["age"] = {
	"Angal",
	"Q10951553",
	"paa-eng",
	scripts = Latn,
}

m["agf"] = {
	"Arguni",
	"Q12473346",
	"poz-cet",
	scripts = Latn,
}

m["agg"] = {
	"Angor",
	"Q3508100",
	"paa",
	scripts = Latn,
}

m["agh"] = {
	"Ngelima",
	"Q7022266",
	"bnt-bta",
	scripts = Latn,
}

m["agi"] = {
	"Agariya",
	"Q663586",
	"mun",
	scripts = Deva,
}

m["agj"] = {
	"Argobba",
	"Q29292",
	"sem-eth",
	scripts = {"Ethi"},
}

m["agk"] = {
	"Isarog Agta",
	"Q6078982",
	"phi",
	scripts = Latn,
}

m["agl"] = {
	"Fembe",
	"Q372927",
	"ngf",
	otherNames = {"Agala"},
	scripts = Latn,
}

m["agm"] = {
	"Angaataha",
	"Q3508001",
	"ngf",
	scripts = Latn,
}

m["agn"] = {
	"Agutaynen",
	"Q3399717",
	"phi-kal",
	scripts = Latn,
}

m["ago"] = {
	"Tainae",
	"Q7676186",
	"ngf",
	scripts = Latn,
}

m["agq"] = {
	"Aghem",
	"Q34737",
	"nic-rnw",
	scripts = Latn,
}

m["agr"] = {
	"Aguaruna",
	"Q1526530",
	"sai-jiv",
	scripts = Latn,
}

m["ags"] = {
	"Esimbi",
	"Q35260",
	"nic-bds",
	aliases = {"Isimbi"},
	scripts = Latn,
}

m["agt"] = {
	"Central Cagayan Agta",
	"Q5017296",
	"phi",
	scripts = Latn,
}

m["agu"] = {
	"Aguacateca",
	"Q35091",
	"myn",
	aliases = {"Aguacatec", "Aguacateco", "Awakatek", "Awakateko", "Awakateka"},
	scripts = Latn,
}

m["agv"] = {
	"Remontado Agta",
	"Q3508085",
	"phi",
	otherNames = {"Remontado Dumagat", "Sinauna", "Hatang Kayey"},
	scripts = Latn,
}

m["agw"] = {
	"Kahua",
	"Q3191906",
	"poz-sls",
	scripts = Latn,
}

m["agx"] = {
	"Aghul",
	"Q36498",
	"cau-lzg",
	aliases = {"Agul"},
	scripts = Cyrl,
}

m["agy"] = {
	"Southern Alta",
	"Q7569611",
	"phi",
	scripts = Latn,
}

m["agz"] = {
	"Mount Iriga Agta",
	"Q6921432",
	"phi",
	scripts = Latn,
}

m["aha"] = {
	"Ahanta",
	"Q34729",
	"alv-ctn",
	scripts = Latn,
}

m["ahb"] = {
	"Axamb",
	"Q2874710",
	"poz-vnc",
	scripts = Latn,
}

m["ahg"] = {
	"Qimant",
	"Q35663",
	"cus",
	scripts = Latn,
}

m["ahh"] = {
	"Aghu",
	"Q3436645",
	"ngf",
	scripts = Latn,
}

m["ahi"] = {
	"Tiagbamrin Aizi",
	"Q3400073",
	"kro-aiz",
	scripts = Latn,
}

m["ahk"] = {
	"Akha",
	"Q56643",
	"tbq-lol",
	aliases = {"Aka", "Ako"},
	scripts = {"Latn", "Mymr", "Thai"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["ahl"] = {
	"Igo",
	"Q35412",
	"alv-ktg",
	scripts = Latn,
}

m["ahm"] = {
	"Mobumrin Aizi",
	"Q35967",
	"kro-aiz",
	scripts = Latn,
}

m["ahn"] = {
	"Àhàn",
	"Q34723",
	"alv-aah",
	aliases = {"Ahan", "Ahaan"},
	scripts = Latn,
}

m["aho"] = {
	"Ahom",
	"Q34778",
	"tai-swe",
	scripts = {"Ahom"},
	translit_module = "Ahom-translit",
}

m["ahp"] = {
	"Aproumu Aizi",
	"Q34810",
	"alv-kwa",
	scripts = Latn,
}

m["ahr"] = {
	"Ahirani",
	"Q15549890",
	"inc",
	otherNames = {"Khandeshi", "Khandesi"},
	scripts = Deva,
	ancestors = {"pmh"},
}

m["ahs"] = {
	"Ashe",
	"Q34823",
	"nic-plc",
	scripts = Latn,
}

m["aht"] = {
	"Ahtna",
	"Q21058",
	"ath-nor",
	scripts = Latn,
}

m["aia"] = {
	"Arosi",
	"Q2863483",
	"poz-sls",
	scripts = Latn,
}

m["aib"] = {
	"Aynu",
	"Q27927",
	"trk-kar",
	otherNames = {"Ainu", "Äynu", "Ainu (China)", "Aini", "Eyni", "Ejnu", "Abdal", "Äynú"},
	scripts = {"Arab", "Latn"},
}

m["aic"] = {
	"Ainbai",
	"Q3332149",
	"paa-brd",
	scripts = Latn,
}

m["aid"] = {
	"Alngith",
	"Q3279409",
	"aus-pmn",
	scripts = Latn,
}

m["aie"] = {
	"Amara",
	"Q2841180",
	"poz-ocw",
	scripts = Latn,
}

m["aif"] = {
	"Agi",
	"Q3331491",
	"qfa-tor",
	scripts = Latn,
}

m["aig"] = {
	"Antigua and Barbuda Creole English",
	"Q3244184",
	"crp",
	ancestors = {"en"},
	otherNames = {"Leeward Caribbean Creole English", "Antiguan Creole English", "Kokoy Creole English", "Saint Kitts Creole", "Montserrat Creole", "Anguillan Creole"},
	scripts = Latn,
}

m["aih"] = {
	"Ai-Cham",
	"Q2827749",
	"qfa-kms",
	scripts = {"Latn", "Hani"},
}

m["aii"] = {
	"Assyrian Neo-Aramaic",
	"Q29440",
	"sem-nna",
	scripts = {"Syrc"},
}

m["aij"] = {
	"Lishanid Noshan",
	"Q3436467",
	"sem-nna",
	scripts = {"Hebr"},
}

m["aik"] = {
	"Ake",
	"Q34808",
	"nic-pls",
	scripts = Latn,
}

m["ail"] = {
	"Aimele",
	"Q3327418",
	"ngf",
	scripts = Latn,
}

m["aim"] = {
	"Aimol",
	"Q4697175",
	"tbq-kuk",
	scripts = {"Latn", "Beng"},
}

m["ain"] = {
	"Ainu",
	"Q27969",
	"qfa-iso",
	aliases = {"Ainu (Japan)"},
	scripts = {"Kana", "Latn", "Cyrl"},
}

m["aio"] = {
	"Aiton",
	"Q3399725",
	"tai-swe",
	aliases = {"Tai Aiton", "Aitonia", "Sham Doaniya"},
	scripts = {"Mymr"},
}

m["aip"] = {
	"Burumakok",
	"Q5000984",
	"ngf-okk",
	scripts = Latn,
}

m["air"] = {
	"Airoran",
	"Q3321131",
	"paa-tkw",
	scripts = Latn,
}

m["ait"] = {
	"Arikem",
	"Q3446679",
	"tup",
	scripts = Latn,
}

m["aiw"] = {
	"Aari",
	"Q7495",
	"omv",
	scripts = Latn,
}

m["aix"] = {
	"Aighon",
	"Q3504287",
	"poz-ocw",
	scripts = Latn,
}

m["aiy"] = {
	"Ali",
	"Q34814",
	"alv-gbf",
	scripts = Latn,
}

m["aja"] = {
	"Aja",
	"Q3237491",
	"csu",
	aliases = {"Adja", "Aja (Sudan)"},
	scripts = Latn,
}

m["ajg"] = {
	"Adja",
	"Q35035",
	"alv-gbe",
	aliases = {"Aja", "Aja (Benin)", "Aja (Togo)", "Ajagbe"},
	scripts = Latn,
}

m["aji"] = {
	"Ajië",
	"Q2828867",
	"poz-cln",
	otherNames = {"Houailou"},
	scripts = Latn,
}

m["ajn"] = {
	"Andajin",
	"Q16111302",
	"aus-wor",
	scripts = Latn,
}

m["ajp"] = {
	"South Levantine Arabic",
	nil,
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ajt"] = {
	"Judeo-Tunisian Arabic",
	"Q56597",
	"sem-arb",
	scripts = {"Hebr"},
	ancestors = {"jrb"},
}

m["aju"] = {
	"Judeo-Moroccan Arabic",
	"Q56595",
	"sem-arb",
	scripts = {"Hebr"},
	ancestors = {"jrb"},
}

m["ajw"] = {
	"Ajawa",
	"Q56645",
	"cdc-wst",
	scripts = Latn,
}

m["ajz"] = {
	"Amri Karbi",
	"Q3508092",
	"tbq-kuk",
	scripts = Latn,
	ancestors = {"mjw"},
}

m["akb"] = {
	"Angkola Batak",
	"Q2640686",
	"btk",
	aliases = {"Batak Angkola"},
	scripts = {"Latn", "Batk"},
}

m["akc"] = {
	"Mpur",
	"Q3327139",
	"paa-wpa",
	scripts = Latn,
}

m["akd"] = {
	"Ukpet-Ehom",
	"Q36618",
	"nic-ucr",
	scripts = Latn,
}

m["ake"] = {
	"Akawaio",
	"Q28059",
	"sai-car",
	aliases = {"Acauayo", "Acaguayo", "Akawai", "Acawai", "Accawai"},
	scripts = Latn,
}

m["akf"] = {
	"Akpa",
	"Q34801",
	"alv-ido",
	scripts = Latn,
}

m["akg"] = {
	"Anakalangu",
	"Q4750964",
	"poz-cet",
	scripts = Latn,
}

m["akh"] = {
	"Angal Heneng",
	"Q10950354",
	"paa-eng",
	scripts = Latn,
}

m["aki"] = {
	"Aiome",
	"Q56735",
	"paa",
	aliases = {"Aiom", "Ayom"},
	scripts = Latn,
}

m["akj"] = {
	"Jeru",
	"Q2919121",
	"qfa-adn",
	otherNames = {"Aka-Jeru"},
	scripts = {"Latn", "Deva"},
}

m["akk"] = {
	"Akkadian",
	"Q35518",
	"sem-eas",
	scripts = {"Xsux"},
}

m["akl"] = {
	"Aklanon",
	"Q8773",
	"phi",
	otherNames = {"Aklan", "Akeanon"},
	scripts = Latn,
}

m["akm"] = {
	"Aka-Bo",
	"Q35361",
	"qfa-adn",
	otherNames = {"Ba", "Bo"},
	scripts = Latn,
}

m["ako"] = {
	"Akurio",
	"Q56650",
	"sai-car",
	scripts = Latn,
}

m["akp"] = {
	"Siwu",
	"Q36470",
	"alv-ntg",
	scripts = Latn,
}

m["akq"] = {
	"Ak",
	"Q56654",
	"paa",
	scripts = Latn,
}

m["akr"] = {
	"Araki",
	"Q2699882",
	"poz-vnc",
	scripts = Latn,
}

m["aks"] = {
	"Akaselem",
	"Q34817",
	"nic-grm",
	otherNames = {"Tchamba", "Akasele", "Tsamba"},
	scripts = Latn,
}

m["akt"] = {
	"Akolet",
	"Q3330162",
	"poz-ocw",
	scripts = Latn,
}

m["aku"] = {
	"Akum",
	"Q34799",
	"nic-ykb",
	scripts = Latn,
}

m["akv"] = {
	"Akhvakh",
	"Q56423",
	"cau-ava",
	scripts = Cyrl,
}

m["akw"] = {
	"Akwa",
	"Q34802",
	"bnt-mbo",
	scripts = Latn,
}

m["akx"] = {
	"Aka-Kede",
	"Q3436816",
	"qfa-adc",
	otherNames = {"Kede"},
	scripts = Latn,
}

m["aky"] = {
	"Aka-Kol",
	"Q3436784",
	"qfa-adc",
	otherNames = {"Kol", "Kawl", "Aka-Kawl", "Bojingiji"},
	scripts = Latn,
}

m["akz"] = {
	"Alabama",
	"Q1815020",
	"nai-mus",
	scripts = Latn,
}

m["ala"] = {
	"Alago",
	"Q34813",
	"alv-ido",
	scripts = Latn,
}

m["alc"] = {
	"Kawésqar",
	"Q56544",
	"aqa",
	otherNames = {"Qawasqar", "Alacaluf"},
	scripts = Latn,
}

m["ald"] = {
	"Alladian",
	"Q34837",
	"alv-lag",
	otherNames = {"Alladyan", "Allagian", "Alaguian"},
	scripts = Latn,
}

m["ale"] = {
	"Aleut",
	"Q27210",
	"esx",
	aliases = {"Aleutian"},
	scripts = Latn,
}

m["alf"] = {
	"Alege",
	"Q34815",
	"nic-ben",
	scripts = Latn,
}

m["alh"] = {
	"Alawa",
	"Q2147917",
	"aus-gun",
	scripts = Latn,
}

m["ali"] = {
	"Amaimon",
	"Q3327427",
	"ngf-mad",
	scripts = Latn,
}

m["alj"] = {
	"Alangan",
	"Q3327423",
	"phi",
	scripts = Latn,
}

m["alk"] = {
	"Alak",
	"Q2714690",
	"mkh",
	scripts = Latn,
}

m["all"] = {
	"Allar",
	"Q3393634",
	"dra",
	otherNames = {"Chatan"},
	scripts = {"Mlym"},
}

-- "aln" IS TREATED AS "sq", SEE WT:LT

m["alm"] = {
	"Amblong",
	"Q11022615",
	"poz-vnc",
	scripts = Latn,
}

m["alo"] = {
	"Larike-Wakasihu",
	"Q3217929",
	"poz-cma",
	scripts = Latn,
}

m["alp"] = {
	"Alune",
	"Q3327367",
	"poz-cet",
	scripts = Latn,
}

m["alq"] = {
	"Algonquin",
	"Q28092",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["alr"] = {
	"Alutor",
	"Q28213",
	"qfa-cka",
	scripts = Cyrl,
}

m["alt"] = {
	"Southern Altai",
	"Q1991779",
	"trk-sib",
	aliases = {"Southern Altay", "Altai", "Altay"},
	scripts = Cyrl,
	translit_module = "Altai-translit",
}

m["alu"] = {
	"'Are'are",
	"Q5160",
	"poz-sls",
	aliases = {"Areare"},
	scripts = Latn,
}

m["alw"] = {
	"Alaba",
	"Q56652",
	"cus",
	otherNames = {"Alaba-K'abeena", "Alaaba", "K'abeena"},
	scripts = Latn,
}

m["alx"] = {
	"Amol",
	"Q3504260",
	"qfa-tor",
	scripts = Latn,
}

m["aly"] = {
	"Alyawarr",
	"Q3327389",
	"aus-pam",
	scripts = Latn,
}

m["alz"] = {
	"Alur",
	"Q56507",
	"sdv",
	scripts = Latn,
}

m["ama"] = {
	"Amanayé",
	"Q3508053",
	"tup-gua",
	scripts = Latn,
}

m["amb"] = {
	"Ambo",
	"Q3450142",
	"nic-tvn",
	scripts = Latn,
}

m["amc"] = {
	"Amahuaca",
	"Q2669150",
	"sai-pan",
	scripts = Latn,
}

m["ame"] = {
	"Yanesha'",
	"Q3088540",
	"awd",
	otherNames = {"Amuesha"},
	scripts = Latn,
}

m["amf"] = {
	"Hamer-Banna",
	"Q35764",
	"omv",
	scripts = Latn,
}

m["amg"] = {
	"Amurdag",
	"Q3360016",
	"aus-wdj",
	otherNames = {"Amarag"},
	scripts = Latn,
}

m["ami"] = {
	"Amis",
	"Q35132",
	"map",
	otherNames = {"Nataoran Amis"},
	scripts = Latn,
}

m["amj"] = {
	"Amdang",
	"Q28335",
	"ssa-fur",
	otherNames = {"Biltine", "Mimi"},
	scripts = Latn,
}

m["amk"] = {
	"Ambai",
	"Q1875885",
	"poz-hce",
	otherNames = {"Wadapi-Laut"},
	scripts = Latn,
}

m["aml"] = {
	"War-Jaintia",
	"Q56321",
	"aav",
	scripts = Latn,
}

m["amm"] = {
	"Ama",
	"Q3446626",
	"qfa-mal",
	aliases = {"Ama (New Guinea)", "Ama (Papua New Guinea)"},
	scripts = Latn,
}

m["amn"] = {
	"Amanab",
	"Q3327399",
	"paa-brd",
	scripts = Latn,
}

m["amo"] = {
	"Amo",
	"Q34826",
	"nic-kne",
	otherNames = {"Timap", "Map", "Among", "Amap", "Amon"},
	scripts = Latn,
}

m["amp"] = {
	"Alamblak",
	"Q56688",
	"paa",
	scripts = Latn,
}

m["amq"] = {
	"Amahai",
	"Q3327384",
	"poz-cma",
	scripts = Latn,
}

m["amr"] = {
	"Amarakaeri",
	"Q35128",
	"sai-har",
	scripts = Latn,
}

m["ams"] = {
	"Southern Amami-Oshima",
	"Q2840986",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["amt"] = {
	"Amto",
	"Q56517",
	"paa-asa",
	scripts = Latn,
}

m["amu"] = {
	"Guerrero Amuzgo",
	"Q3501942",
	"omq",
	otherNames = {"Amuzgo", "Xochistlahuaca Amuzgo", "Northern Amuzgo", "Southern Amuzgo"},
	scripts = Latn,
}

m["amv"] = {
	"Ambelau",
	"Q2669214",
	"poz-cma",
	scripts = Latn,
}

m["amw"] = {
	"Western Neo-Aramaic",
	"Q34226",
	"sem-arw",
	scripts = {"Armi", "Syrc", "Latn"},
}

m["amx"] = {
	"Anmatyerre",
	"Q10412317",
	"aus-pam",
	otherNames = {"Namfau"},
	scripts = Latn,
}

m["amy"] = {
	"Ami",
	"Q12626835",
	"aus-dal",
	otherNames = {"Ame", "Amijangal"},
	scripts = Latn,
}

m["amz"] = {
	"Atampaya",
	"Q3446651",
	"aus-pam",
	scripts = Latn,
}

m["ana"] = {
	"Andaqui",
	"Q2846078",
	aliases = {"Andaquí", "Andakí", "Andaki"},
	scripts = Latn,
}

m["anb"] = {
	"Andoa",
	"Q2846171",
	"sai-zap",
	otherNames = {"Shimigae", "Semigae", "Gae", "Gay", "Gaye", "Siaviri", "Katsakáti"},
	scripts = Latn,
}

m["anc"] = {
	"Ngas",
	"Q35999",
	"cdc-wst",
	otherNames = {"Angas", "Angass", "Hill Ngas", "Plain Ngas", "Hill Angas", "Plain Angas", "Karang", "Kerang"},
	scripts = Latn,
}

m["and"] = {
	"Ansus",
	"Q3513300",
	"poz-hce",
	scripts = Latn,
}

m["ane"] = {
	"Xârâcùù",
	"Q3571097",
	"poz-cln",
	scripts = Latn,
}

m["anf"] = {
	"Animere",
	"Q34783",
	"alv-ktg",
	scripts = Latn,
}

m["ang"] = {
	"Стари Енглески",
	"Q42365",
	"gmw",
	aliases = {"Anglo-Saxon"},
	scripts = {"Latinx", "Runr"},
	entry_name = {
		from = {"[ĀÁ]", "[āá]", "[ǢǼ]", "[ǣǽ]", "Ċ", "ċ", "[ĒÉ]", "[ēé]", "Ġ", "ġ", "[ĪÍ]", "[īí]", "[ŌÓ]", "[ōó]", "[ŪÚ]", "[ūú]", "[ȲÝ]", "[ȳý]", MACRON, ACUTE, DOTABOVE},
		to   = {"A", "a", "Æ", "æ", "C", "c", "E", "e", "G", "g", "I", "i", "O", "o", "U", "u", "Y", "y"}},
	sort_key = {
		-- most dictionaries sort æ as if written ae, and þ/ð after t
		-- most dictionaries don't have ƿ at all (normalized to w); for now,
		-- put after w to keep them from cluttering up the w lists
		from = {"[æǣǽ]", "[þð]", "ƿ"},
		to   = {"ae", "t~", "w~"}},
}

m["anh"] = {
	"Nend",
	"Q6991554",
	"ngf-mad",
	otherNames = {"Nent", "Angaua"},
	scripts = Latn,
}

m["ani"] = {
	"Andi",
	"Q34849",
	"cau-ava",
	scripts = Cyrl,
}

m["anj"] = {
	"Anor",
	"Q56458",
	"paa",
	scripts = Latn,
}

m["ank"] = {
	"Goemai",
	"Q35272",
	"cdc-wst",
	scripts = Latn,
}

m["anl"] = {
	"Anu",
	"Q4777679",
	"sit-mru",
	otherNames = {"Khaungtso", "Anu-Hkongso", "Anu-Hkongso Chin"}, -- the last is the ISO's unattested blend of the names of its two dialects and half of the name of the place where it's spoken
	scripts = Latn,
}

m["anm"] = {
	"Anal",
	"Q56235",
	"tbq-kuk",
	otherNames = {"Anaal", "Namfau"}, -- Namfau is actually a placename
	scripts = Latn,
}

m["ann"] = {
	"Obolo",
	"Q36614",
	"nic-lcr",
	scripts = Latn,
}

m["ano"] = {
	"Andoque",
	"Q2669225",
	"qfa-iso",
	scripts = Latn,
}

m["anp"] = {
	"Angika",
	"Q28378",
	"inc",
	scripts = Deva,
	ancestors = {"bh"},
}

m["anq"] = {
	"Jarawa",
	"Q2475526",
	"qfa-ong",
	aliases = {"Jarawa (India)"},
	scripts = Latn,
}

m["anr"] = {
	"Andh",
	"Q4754314",
	"inc",
	scripts = Deva,
}

m["ans"] = {
	"Anserma",
	"Q3446613",
	"sai-chc",
	scripts = Latn,
}

m["ant"] = {
	"Antakarinya",
	"Q921304",
	"aus-psw",
	scripts = Latn,
}

m["anu"] = {
	"Anuak",
	"Q56677",
	"sdv",
	aliases = {"Anyua", "Anywa", "Anyuak"},
	scripts = Latn,
}

m["anv"] = {
	"Denya",
	"Q35187",
	"nic-mam",
	scripts = Latn,
}

m["anw"] = {
	"Anaang",
	"Q2845320",
	"nic-ief",
	otherNames = {"Anang", "Annang", "Western Ibibio"},
	scripts = Latn,
}

m["anx"] = {
	"Andra-Hus",
	"Q2846195",
	"poz-aay",
	scripts = Latn,
}

m["any"] = {
	"Anyi",
	"Q28395",
	"alv-ctn",
	aliases = {"Anyin"},
	scripts = Latn,
}

m["anz"] = {
	"Anem",
	"Q56512",
	"paa",
	aliases = {"Anêm"},
	scripts = Latn,
}

m["aoa"] = {
	"Angolar",
	"Q34994",
	"crp",
	scripts = Latn,
	ancestors = {"pt"},
}

m["aob"] = {
	"Abom",
	"Q3446647",
	"ngf",
	scripts = Latn,
}

m["aoc"] = {
	"Pemon",
	"Q10729616",
	"sai-car",
	otherNames = {"Arekuna", "Arecuna"},
	scripts = Latn,
}

m["aod"] = {
	"Andarum",
	"Q3507888",
	"paa",
	scripts = Latn,
}

m["aoe"] = {
	"Angal Enen",
	"Q10951638",
	"paa-eng",
	scripts = Latn,
}

m["aof"] = {
	"Bragat",
	"Q3507977",
	"qfa-tor",
	scripts = Latn,
}

m["aog"] = {
	"Angoram",
	"Q56366", -- cf "Q6754745" for merged dialect
	"paa-lsp",
	otherNames = {"Pondo", "Kanda", "Maramba"},
	scripts = Latn,
}

m["aoh"] = {
	"Arma", -- spurious? "a possible but unattested extinct language",
	"Q3507971",
	"sai-chc",
	scripts = Latn,
}

m["aoi"] = {
	"Anindilyakwa",
	"Q2714654",
	"aus-arn",
	aliases = {"Enindhilyagwa"},
	scripts = Latn,
}

m["aoj"] = {
	"Mufian",
	"Q3507881",
	"qfa-tor",
	scripts = Latn,
}

m["aok"] = {
	"Arhö",
	"Q4790086",
	"poz-cln",
	scripts = Latn,
}

m["aol"] = {
	"Alor",
	"Q3332062",
	"poz",
	aliases = {"Alorese"},
	scripts = Latn,
}

m["aom"] = {
	"Ömie",
	"Q8078975",
	"ngf",
	scripts = Latn,
}

m["aon"] = {
	"Bumbita Arapesh",
	"Q3508044",
	"qfa-tor",
	scripts = Latn,
}

m["aor"] = {
	"Aore",
	"Q12627129",
	"poz-vnc",
	scripts = Latn,
}

m["aos"] = {
	"Taikat",
	"Q7676018",
	"paa-brd",
	scripts = Latn,
}

m["aot"] = {
	"Atong (India)",
	"Q5646",
	"tbq-bdg",
	aliases = {"Atong", "A'tong"},
	scripts = Latn,
}

m["aou"] = {
	"A'ou",
	"Q16109994",
	"qfa-tak",
	otherNames = {"Ayo", "A'ou Gelao"},
	scripts = Latn, -- also Hani?
	wikipedia_article = "Gelao language",	-- might change, as A'ou is a dialect of Gelao
}

m["aox"] = {
	"Atorada",
	"Q3507932",
	"awd",
	scripts = Latn,
}

m["aoz"] = {
	"Uab Meto",
	"Q3441962",
	"poz-tim",
	scripts = Latn,
}

m["apb"] = {
	"Sa'a",
	"Q36294",
	"poz-sls",
	otherNames = {"South Malaita", "Apae'aa"},
	scripts = Latn,
}

m["apc"] = {
	"North Levantine Arabic",
	"Q22809485",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["apd"] = {
	"Sudanese Arabic",
	"Q56573",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ape"] = {
	"Bukiyip",
	"Q3507895",
	"qfa-tor",
	scripts = Latn,
}

m["apf"] = {
	"Pahanan Agta",
	"Q7135432",
	"phi",
	scripts = Latn,
}

m["apg"] = {
	"Ampanang",
	"Q4748035",
	"poz",
	scripts = Latn,
}

m["aph"] = {
	"Athpare",
	"Q3449126",
	"sit-kie",
	otherNames = {"Athpariya"},
	scripts = {"Deva", "Latn"},
}

m["api"] = {
	"Apiaká",
	"Q3507941",
	"tup-gua",
	aliases = {"Apiacá"},
	scripts = Latn,
}

m["apj"] = {
	"Jicarilla",
	"Q28277",
	"apa",
	aliases = {"Jicarilla Apache"},
	scripts = Latn,
}

m["apk"] = {
	"Plains Apache",
	"Q27861",
	"apa",
	aliases = {"Kiowa Apache"},
	scripts = Latn,
}

m["apl"] = {
	"Lipan",
	"Q28269",
	"apa",
	aliases = {"Lipan Apache"},
	scripts = Latn,
}

m["apm"] = {
	"Chiricahua",
	"Q13368",
	"apa",
	otherNames = {"Mescalero", "Mescalero-Chiricahua Apache"}, -- two dialects combined by Ethnologue
	scripts = Latn,
}

m["apn"] = {
	"Apinayé",
	"Q2858311",
	"sai-mje",
	aliases = {"Apinajé", "Apinagé", "Apinaye", "Apinaje", "Apinage"},
	scripts = Latn,
}

m["apo"] = {
	"Ambul",
	"Q12627135",
	"poz-ocw",
	scripts = Latn,
}

m["app"] = {
	"Apma",
	"Q2669188",
	"poz-vnc",
	scripts = Latn,
}

m["apq"] = {
	"A-Pucikwar",
	"Q28466",
	"qfa-adc",
	otherNames = {"Pucikwar", "Puchikwar", "Aka-Pucikwar", "Pujjukar", "Bójigiáb", "Bojigiab", "Bojigyab"}, -- last three may apply also to other languages
	scripts = Latn,
}

m["apr"] = {
	"Arop-Lokep",
	"Q2863482",
	"poz-ocw",
	scripts = Latn,
}

m["aps"] = {
	"Arop-Sissano",
	"Q12627242",
	"poz-ocw",
	scripts = Latn,
}

m["apt"] = {
	"Apatani",
	"Q56306",
	"sit-tan",
	otherNames = {"Apa Tani", "Tanii"},
	scripts = Latn,
}

m["apu"] = {
	"Apurinã",
	"Q2859081",
	"awd",
	scripts = Latn,
}

m["apv"] = {
	"Alapmunte",
	"Q16110782",
	"sai-nmk",
	scripts = Latn,
}

m["apw"] = {
	"Western Apache",
	"Q28060",
	"apa",
	scripts = Latn,
}

m["apx"] = {
	"Aputai",
	"Q12473343",
	"poz-tim",
	scripts = Latn,
}

m["apy"] = {
	"Apalaí",
	"Q2736980",
	"sai-car",
	aliases = {"Apalai"},
	scripts = Latn,
}

m["apz"] = {
	"Safeyoka",
	"Q7398693",
	"ngf",
	scripts = Latn,
}

m["aqc"] = {
	"Archi",
	"Q34915",
	"cau-lzg",
	scripts = Cyrl,
}

m["aqd"] = {
	"Ampari Dogon",
	"Q4748057",
	"nic-dgw",
	scripts = Latn,
}

m["aqg"] = {
	"Arigidi",
	"Q34829",
	"alv-von",
	scripts = Latn,
}

m["aqm"] = {
	"Atohwaim",
	"Q11732297",
	"ngf",
	scripts = Latn,
}

m["aqn"] = {
	"Northern Alta",
	"Q7058116",
	"phi",
	scripts = Latn,
}

m["aqp"] = {
	"Atakapa",
	"Q10975683",
	"qfa-iso",
	otherNames = {"Akokisa", "Orcoquiza", "Eastern Atakapa", "Western Atakapa"},
	scripts = Latn,
}

m["aqr"] = {
	"Arhâ",
	"Q4790085",
	"poz-cln",
	scripts = Latn,
}

m["aqt"] = {
	"Angaité",
	"Q15736037",
	"sai-mas",
	scripts = Latn,
}

m["aqz"] = {
	"Akuntsu",
	"Q4701960",
	"tup",
	scripts = Latn,
}

m["arc"] = {
	"Арaмејски",
	"Q28602",
	"sem-ara",
	-- varieties are in [[Module:etymology language/data]]
	scripts = {"Hebr", "Armi", "Syrc", "Palm", "Nbat", "Phnx", "Mand", "Samr", "Hatr"},
	translit_module = "translit-redirect",
	entry_name = {
		from = {"[" .. u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. "]", "[" .. u(0x0304) .. u(0x0308) .. u(0x0331) .. u(0x0730) .. "-" .. u(0x0748) .. "]" },
		to   = {}} ,
}

m["ard"] = {
	"Arabana",
	"Q3507959",
	"aus-kar",
	scripts = Latn,
}

m["are"] = {
	"Western Arrernte",
	"Q12645549",
	"aus-pam",
	scripts = Latn,
}

m["arh"] = {
	"Arhuaco",
	"Q2640621",
	"cba",
	otherNames = {"Ika"},
	scripts = Latn,
}

m["ari"] = {
	"Arikara",
	"Q56539",
	"cdd",
	scripts = Latn,
}

m["arj"] = {
	"Arapaso",
	"Q12627166",
	"sai-tuc",
	scripts = Latn,
}

m["ark"] = {
	"Arikapú",
	"Q3446640",
	"sai-mje",
	scripts = Latn,
}

m["arl"] = {
	"Arabela",
	"Q2591221",
	"sai-zap",
	scripts = Latn,
}

m["arn"] = {
	"Mapudungun",
	"Q33730",
	"sai-ara",
	scripts = Latn,
	otherNames = {"Mapuche", "Mapudungün", "Mapuzugün", "Mapudungu", "Araucanian"},
}

m["aro"] = {
	"Araona",
	"Q958414",
	"sai-tac",
	scripts = Latn,
}

m["arp"] = {
	"Arapaho",
	"Q56417",
	"alg-ara",
	scripts = Latn,
}

m["arq"] = {
	"Algerian Arabic",
	"Q56499",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["arr"] = {
	"Arara-Karo",
	"Q35539",
	"tup",
	otherNames = {"Karo", "Karo (Brazil)", "Ramarama", "Itanga", "Itogapuc", "Itogapúk", "Ntogapid", "Ntogapig", "Arára", "Arára de Rondonia", "Arára do Jiparaná", "Uruku", "Urukú"},
	scripts = Latn,
}

m["ars"] = {
	"Najdi Arabic",
	"Q56574",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aru"] = {
	"Arua",
	"Q2746221",
	"auf",
	aliases = {"Aruá", "Arawa", "Arawá"}, -- extinct, northern Brazil, cf. 'arx'
	scripts = Latn,
}

m["arv"] = {
	"Arbore",
	"Q56883",
	"cus",
	scripts = Latn,
}

m["arw"] = {
	"Arawak",
	"Q2655664",
	"awd-taa",
	otherNames = {"Arowak", "Lokono"},
	ancestors = {"awd-taa-pro"},
	scripts = Latn,
}

m["arx"] = {
	"Aruá",
	"Q3507907",
	"tup",
	aliases = {"Arua", "Aruashi", "Aruáshi", "Aruachi"}, -- moribund, central Brazil, cf 'aru'
	scripts = Latn,
}

m["ary"] = {
	"Moroccan Arabic",
	"Q56426",
	"sem-arb",
	scripts = {"Arab", "Latn"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["arz"] = {
	"Egyptian Arabic",
	"Q29919",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["asa"] = {
	"Pare",
	"Q36403",
	"bnt-par",
	otherNames = {"Asu", "Asu (Tanzania)", "Chasu", "Kipare", "Southern Pare", "South Pare"},
	scripts = Latn,
}

m["asb"] = {
	"Assiniboine",
	"Q2591288",
	"sio-dkt",
	scripts = Latn,
}

m["asc"] = {
	"Casuarina Coast Asmat",
	"Q11732046",
	"ngf",
	scripts = Latn,
}

m["ase"] = {
	"Амерички знаковни језик",
	"14759",
	"sgn",
	aliases = {"Ameslan", "ASL"},
	scripts = {"Sgnw"},
}

m["asf"] = {
	"Auslan",
	"Q29525",
	"sgn",
	aliases = {"Australian Sign Language"},
	scripts = Latn, -- when documented
}

m["asg"] = {
	"Cishingini",
	"Q35199",
	"nic-kam",
	aliases = {"Shingini"},
	scripts = Latn,
}

m["ash"] = {
	"Abishira",
	"Q2871740",
	"qfa-iso",
	otherNames = {"Tequiraca", "Tekiráka", "Avishiri", "Auishiri", "Agouisiri", "Avirxiri", "Abiquira", "Abigira", "Aiwa", "Aewa"},
	scripts = Latn,
}

m["asi"] = {
	"Buruwai",
	"Q5001031",
	"ngf",
	scripts = Latn,
}

m["asj"] = {
	"Nsari",
	"Q36418",
	"nic-bbe",
	aliases = {"Sari", "Saari"},
	scripts = Latn,
}

m["ask"] = {
	"Ashkun",
	"Q29379",
	"nur-sou",
	scripts = {"Arab", "Latn"},
}

m["asl"] = {
	"Asilulu",
	"Q12473347",
	"poz-cma",
	scripts = Latn,
}

m["asn"] = {
	"Xingú Asuriní",
	"Q8044571",
	"tup-gua",
	scripts = Latn,
}

m["aso"] = {
	"Dano",
	"Q5220979",
	"paa-kag",
	scripts = {"Latn"},
}

m["asp"] = {
	"Algerian Sign Language",
	"Q3135421",
	"sgn",
}

m["asq"] = {
	"Austrian Sign Language",
	"Q36668",
	"sgn",
	scripts = Latn, -- when documented
}

m["asr"] = {
	"Asuri",
	"Q3504321",
	"mun",
	aliases = {"Asur"},
	scripts = Latn, -- when documented
}

m["ass"] = {
	"Ipulo",
	"Q35408",
	"nic-tvc",
	scripts = Latn,
}

m["ast"] = {
	"Asturian",
	"Q29507",
	"roa-ibe",
	scripts = Latn,
	ancestors = {"roa-ole"},
}

m["asu"] = {
	"Tocantins Asurini",
	"Q32041490",
	"tup-gua",
	otherNames = {"Asurini", "Asuriní", "Asuriní of Tocantins", "Asuriní do Tocantins", "Akwawa", "Akwáwa"},
	scripts = Latn,
}

m["asv"] = {
	"Asoa",
	"Q56296",
	"csu",
	scripts = Latn,
}

m["asw"] = {
	"Australian Aboriginal Sign Language",
	"Q955216",
	"sgn",
	aliases = {"Australian Aborigines Sign Language"},
	scripts = Latn, -- when documented
}

m["asx"] = {
	"Muratayak",
	"Q11732766",
	"ngf-fin",
	scripts = Latn,
}

m["asy"] = {
	"Yaosakor Asmat",
	"Q16113158",
	"ngf",
	scripts = Latn,
}

m["asz"] = {
	"As",
	"Q2866218",
	"poz-hce",
	scripts = Latn,
}

m["ata"] = {
	"Pele-Ata",
	"Q56511",
	"paa",
	otherNames = {"Ata", "Wasi"},
	scripts = Latn,
}

m["atb"] = {
	"Zaiwa",
	"Q56594",
	"tbq-brm",
	scripts = Latn, -- also Hani?
}

m["atc"] = {
	"Atsahuaca",
	"Q4817730",
	"sai-pan",
	scripts = Latn,
}

m["atd"] = {
	"Ata Manobo",
	"Q12627315",
	"mno",
	scripts = Latn,
}

m["ate"] = {
	"Atemble",
	"Q4813055",
	"ngf-mad",
	scripts = Latn,
}

m["atg"] = {
	"Okpela",
	"Q7082551",
	"alv-yek",
	otherNames = {"Ivbie North", "Arhe", "Ivbie North-Okpela-Arhe"},
	scripts = Latn,
}

m["ati"] = {
	"Attié",
	"Q34844",
	"alv-lag",
	scripts = Latn,
}

m["atj"] = {
	"Atikamekw",
	"Q56590",
	"alg",
	scripts = Latn,
	ancestors = {"cr"},
}

m["atk"] = {
	"Ati",
	"Q4815751",
	"phi",
	scripts = Latn,
}

m["atl"] = {
	"Mount Iraya Agta",
	"Q6921430",
	"phi",
	scripts = Latn,
}

m["atm"] = {
	"Ata",
	"Q4812603",
	"phi",
	scripts = Latn,
}

m["ato"] = {
	"Atong (Cameroon)",
	"Q34824",
	"nic-grs",
	aliases = {"Atoŋ", "Atong"},
	scripts = Latn,
}

m["atp"] = {
	"Pudtol Atta",
	"Q12640726",
	"phi",
	scripts = Latn,
}

m["atq"] = {
	"Aralle-Tabulahan",
	"Q4783889",
	"poz-ssw",
	scripts = Latn,
}

m["atr"] = {
	"Waimiri-Atroari",
	"Q56865",
	"sai-car",
	scripts = Latn,
}

m["ats"] = {
	"Gros Ventre",
	"Q56628",
	"alg-ara",
	otherNames = {"Atsina"},
	scripts = Latn,
}

m["att"] = {
	"Pamplona Atta",
	"Q12639245",
	"phi",
	scripts = Latn,
}

m["atu"] = {
	"Reel",
	"Q7306882",
	"sdv",
	scripts = Latn,
}

m["atv"] = {
	"Northern Altai",
	"Q2640863",
	"trk-sib",
	otherNames = {"Northern Altay", "Altai", "Altay"},
	scripts = Cyrl,
	translit_module = "Altai-translit",
}

m["atw"] = {
	"Atsugewi",
	"Q56718",
	"nai-pal",
	aliases = {"Atsugé"},
	scripts = Latn,
}

m["atx"] = {
	"Arutani",
	"Q56609",
	scripts = Latn,
}

m["aty"] = {
	"Aneityum",
	"Q2379113",
	"poz-oce",
	scripts = Latn,
}

m["atz"] = {
	"Arta",
	"Q3508067",
	"phi",
	scripts = Latn,
}

m["aua"] = {
	"Asumboa",
	"Q4811870",
	"poz-oce",
	scripts = Latn,
}

m["aub"] = {
	"Alugu",
	"Q12626798",
	"tbq-lol",
	scripts = Latn, -- also Hani?
}

m["auc"] = {
	"Huaorani",
	"Q758570",
	"qfa-iso",
	otherNames = {"Waorani", "Sabela", "Wao", "Huao", "Aushiri", "Ssabela", "Wao Terero", "Auka", "Auca"},
	scripts = Latn,
}

m["aud"] = {
	"Anuta",
	"Q35326",
	"poz-pnp",
	scripts = Latn,
}

m["aug"] = {
	"Aguna",
	"Q34733",
	"alv-gbe",
	scripts = Latn,
}

m["auh"] = {
	"Aushi",
	"Q2872082",
	"bnt-sbi",
	scripts = Latn,
}

m["aui"] = {
	"Anuki",
	"Q3508132",
	"poz-ocw",
	scripts = Latn,
}

m["auj"] = {
	"Augila",
	"Q56398",
	"ber",
	aliases = {"Awjilah", "Awjila"},
	scripts = {"Latn", "Arab", "Tfng"},
}

m["auk"] = {
	"Heyo",
	"Q3504295",
	"qfa-tor",
	scripts = Latn,
}

m["aul"] = {
	"Aulua",
	"Q427300",
	"poz-vnc",
	scripts = Latn,
}

m["aum"] = {
	"Asu",
	"Q34798",
	"alv-ngb",
	otherNames = {"Abewa", "Asu (Nigeria)"},
	scripts = Latn,
}

m["aun"] = {
	"Molmo One",
	"Q12637224",
	"qfa-tor",
	scripts = Latn,
}

m["auo"] = {
	"Auyokawa",
	"Q56247",
	"cdc-wst",
	scripts = Latn,
}

m["aup"] = {
	"Makayam",
	"Q6738863",
	"ngf",
	otherNames = {"Tirio", "Makaeyam", "Aturu", "Atura", "Adulu"},
	scripts = Latn,
}

m["auq"] = {
	"Anus",
	"Q23855",
	"poz-ocw",
	otherNames = {"A", "Korur", "Korurnus"}, -- no name attested? lect may be same as 'pdn'
	scripts = Latn,
}

m["aur"] = {
	"Aruek",
	"Q3504279",
	"qfa-tor",
	scripts = Latn,
}

m["aut"] = {
	"Austral",
	"Q2669261",
	"poz-pep",
	scripts = Latn,
}

m["auu"] = {
	"Auye",
	"Q4827334",
	"ngf",
	aliases = {"Auwje"},
	scripts = Latn,
}

m["auw"] = {
	"Awyi",
	"Q3513326",
	"paa-brd",
	aliases = {"Awye"},
	scripts = Latn,
}

m["aux"] = {
	"Aurá",
	"Q3507995",
	"tup-gua",
	scripts = Latn,
}

m["auy"] = {
	"Auyana",
	"Q2873211",
	"paa-kag",
	aliases = {"Awiyaana"},
	scripts = Latn,
}

m["auz"] = {
	"Uzbeki Arabic",
	"Q3399507",
	"sem-arb",
	aliases = {"Uzbek Arabic"},
	scripts = Arab,
}

m["avb"] = {
	"Avau",
	"Q12627412",
	"poz-ocw",
	scripts = Latn,
}

m["avd"] = {
	"Alviri-Vidari",
	"Q3327357",
	"xme",
	otherNames = {"Alviri", "Vidari"},
	scripts = {"fa-Arab"},
	ancestors = {"xme-mid"},
}

m["avi"] = {
	"Avikam",
	"Q34840",
	"alv-lag",
	scripts = Latn,
}

m["avk"] = {
	"Kotava",
	"Q1377116",
	"art",
	scripts = Latn,
	type = "appendix-constructed",
}

m["avl"] = {
	"Eastern Egyptian Bedawi Arabic",
	"Q56714",
	"sem-arb",
	otherNames = {"Bedawi Arabic", "Levantine Bedawi Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["avm"] = {
	"Angkamuthi",
	nil,
	"aus-pmn",
	scripts = Latn,
}

m["avn"] = {
	"Avatime",
	"Q34796",
	"alv-ktg",
	scripts = Latn,
}

m["avo"] = {
	"Agavotaguerra",
	"Q3508007",
	"awd",
	scripts = Latn,
}

m["avs"] = {
	"Aushiri",
	"Q3409318",
	"sai-zap",
	scripts = Latn,
}

m["avt"] = {
	"Au",
	"Q3446608",
	"qfa-tor",
	scripts = Latn,
}

m["avu"] = {
	"Avokaya",
	"Q56685",
	"csu",
	scripts = Latn,
}

m["avv"] = {
	"Avá-Canoeiro",
	"Q4829584",
	"tup-gua",
	otherNames = {"Avá", "Canoe"},
	scripts = Latn,
}

m["awa"] = {
	"Awadhi",
	"Q29579",
	"inc",
	scripts = {"Deva", "Kthi", "fa-Arab"},
	ancestors = {"pka"},
	translit_module = "hi-translit",
}

m["awb"] = {
	"Awa (New Guinea)",
	"Q2874650",
	"paa-kag",
	aliases = {"Awa", "Awa (Papua New Guinea)"},
	scripts = Latn,
}

m["awc"] = {
	"Cicipu",
	"Q35193",
	"nic-kam",
	aliases = {"Cipu"},
	scripts = Latn,
}

m["awe"] = {
	"Awetí",
	"Q4830038",
	"tup",
	scripts = Latn,
}

m["awg"] = {
	"Anguthimri",
	"Q4764288",
	"aus-pam",
	otherNames = {"Alngith", "Leningitij", "Mpakwithi"},
	scripts = Latn,
}

m["awh"] = {
	"Awbono",
	"Q3446684",
	"ngf",
	scripts = Latn,
}

m["awi"] = {
	"Aekyom",
	"Q3399691",
	"ngf",
	otherNames = {"Awin"},
	scripts = Latn,
}

m["awk"] = {
	"Awabakal",
	"Q3449138",
	"aus-pam",
	scripts = Latn,
}

m["awm"] = {
	"Arawum",
	"Q4784537",
	"ngf-mad",
	scripts = Latn,
}

m["awn"] = {
	"Awngi",
	"Q34934",
	"cus",
	scripts = {"Ethi"},
}

m["awo"] = {
	"Awak",
	"Q3446643",
	"alv-wjk",
	scripts = Latn,
}

m["awr"] = {
	"Awera",
	"Q56379",
	"paa-lkp",
	scripts = Latn,
}

m["aws"] = {
	"South Awyu",
	"Q12633986",
	"ngf",
	scripts = Latn,
}

m["awt"] = {
	"Araweté",
	"Q4784535",
	"tup-gua",
	scripts = Latn,
}

m["awu"] = {
	"Central Awyu",
	"Q12628801",
	"ngf",
	scripts = Latn,
}

m["awv"] = {
	"Jair Awyu",
	"Q16110177",
	"ngf",
	scripts = Latn,
}

m["aww"] = {
	"Awun",
	"Q56369",
	"paa-spk",
	scripts = Latn,
}

m["awx"] = {
	"Awara",
	"Q2874670",
	"ngf-fin",
	scripts = Latn,
}

m["awy"] = {
	"Edera Awyu",
	"Q12630425",
	"ngf",
	scripts = Latn,
}

m["axb"] = {
	"Abipon",
	"Q11252539",
	"sai-guc",
	otherNames = {"Abipón", "Callaga", "Kalyaga"},
	scripts = Latn,
}

m["axe"] = {
	"Ayerrerenge",
	"Q16112737",
	"aus-pam",
	scripts = Latn,
}

m["axg"] = {
	"Mato Grosso Arára",
	"Q3446660",
	scripts = Latn,
}

m["axk"] = {
	"Aka (Central Africa)",
	"Q11010149",
	"bnt-ngn",
	otherNames = {"Yaka", "Yaka (Central African Republic)", "Aka", "Beka"}, -- cf 'iyx', 'yaf'
	scripts = Latn,
}

m["axl"] = {
	"Lower Southern Aranda",
	"Q6693295",
	"aus-pam",
	otherNames = {"Lower Southern Arrernte", "Southern Arrernte", "Southern Aranda"},
	scripts = Latn,
}

m["axm"] = {
	"Средњи Јерменски",
	"Q4438498",
	"hyx",
	scripts = {"Armn"},
	ancestors = {"xcl"},
	translit_module = "Armn-translit",
	override_translit = true,
	entry_name = {
		from = {"և", "՞", "՜", "՛", "՟"},
		to   = {"եւ"}} ,
}

m["axx"] = {
	"Xaragure",
	"Q8045635",
	"poz-cln",
	aliases = {"Xârâgurè"},
	scripts = Latn,
}

m["aya"] = {
	"Awar",
	"Q56876",
	"paa",
	scripts = Latn,
}

m["ayb"] = {
	"Ayizo",
	"Q34841",
	"alv-pph",
	aliases = {"Ayizo Gbe"},
	scripts = Latn,
}

m["ayd"] = {
	"Ayabadhu",
	"Q3509164",
	"aus-pmn",
	aliases = {"Ayapathu", "Badhu"},
	scripts = Latn,
}

m["aye"] = {
	"Ayere",
	"Q34788",
	"alv-aah",
	scripts = Latn,
}

m["ayg"] = {
	"Nyanga (Togo)",
	"Q35446",
	"alv-gng",
	aliases = {"Nyanga", "Ginyanga"},
	scripts = Latn,
}

m["ayh"] = {
	"Hadrami Arabic",
	"Q3510366",
	"sem-arb",
	aliases = {"Hadhrami Arabic"},
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayi"] = {
	"Leyigha",
	"Q3914492",
	"nic-uce",
	scripts = Latn,
}

m["ayk"] = {
	"Akuku",
	"Q3450179",
	"alv-nwd",
	scripts = Latn,
}

m["ayl"] = {
	"Libyan Arabic",
	"Q56503",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayn"] = {
	"Sanaani Arabic",
	"Q56578",
	"sem-arb",
	scripts = Arab,
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayo"] = {
	"Ayoreo",
	"Q56634",
	"sai-zam",
	otherNames = {"Morotoco", "Moro", "Ayoweo", "Ayoré", "Pyeta Yovai"},
	scripts = Latn,
}

m["ayp"] = {
	"North Mesopotamian Arabic",
	"Q56577",
	"sem-arb",
	scripts = Arab,
	ancestors = {"acm"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayq"] = {
	"Ayi",
	"Q56449",
	"paa-spk",
	aliases = {"Ayi (New Guinea)", "Ayi (Papua New Guinea)"},
	scripts = Latn,
}

m["ays"] = {
	"Sorsogon Ayta",
	"Q7563752",
	"phi",
	scripts = Latn,
}

m["ayt"] = {
	"Bataan Ayta",
	"Q4921648",
	"phi",
	otherNames = {"Magbukun Ayta", "Mariveleño"},
	scripts = Latn,
}

m["ayu"] = {
	"Ayu",
	"Q34786",
	"alv",
	scripts = Latn,
}

m["ayy"] = {
	"Tayabas Ayta",
	"Q7689745",
	"phi",
	scripts = Latn,
}

m["ayz"] = {
	"Maybrat",
	"Q4830892",
	"paa-wpa",
	otherNames = {"Mai Brat", "Ajamaru", "Ayamaru"},
	scripts = Latn,
}

m["aza"] = {
	"Azha",
	"Q4832486",
	"tbq-lol",
	scripts = Latn,
}

m["azd"] = {
	"Eastern Durango Nahuatl",
	"Q16115449",
	"azc-nah",
	scripts = Latn,
}

m["azg"] = {
	"San Pedro Amuzgos Amuzgo",
	"Q35092",
	"omq",
	otherNames = {"Upper Eastern Amuzgo", "Oaxaca Amuzgo"},
	scripts = Latn,
}

m["azm"] = {
	"Ipalapa Amuzgo",
	"Q12633013",
	"omq",
	otherNames = {"Lower Eastern Amuzgo"},
	scripts = Latn,
}

m["azn"] = {
	"Western Durango Nahuatl",
	"Q12645553",
	"azc-nah",
	scripts = Latn,
}

m["azo"] = {
	"Awing",
	"Q34856",
	"nic-nge",
	scripts = Latn,
}

m["azt"] = {
	"Faire Atta",
	"Q12630884",
	"phi",
	scripts = Latn,
}

m["azz"] = {
	"Highland Puebla Nahuatl",
	"Q12953754",
	"azc-nah",
	scripts = Latn,
}

return m