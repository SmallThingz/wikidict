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

m["haa"] = {
	canonicalName = "Han",
	otherNames = {"Hän"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["hab"] = {
	canonicalName = "Hanoi Sign Language",
	family = "sgn",
}

m["hac"] = {
	canonicalName = "Gurani",
	otherNames = {"Gorani", "Avromani", "Awroman", "Awromani", "Hawramani", "Hawrami", "Hewrami", "Hourami", "Howrami", "Ourami"},
	scripts = {"Arab"},
	family = "ira",
}

m["had"] = {
	canonicalName = "Hatam",
}

m["haf"] = {
	canonicalName = "Haiphong Sign Language",
	family = "sgn",
}

m["hag"] = {
	canonicalName = "Hanga",
	family = "nic-gur",
}

m["hah"] = {
	canonicalName = "Hahon",
	family = "poz-ocw",
}

m["hai"] = {
	canonicalName = "Haida",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["haj"] = {
	canonicalName = "Hajong",
	scripts = {"Beng", "Latn"},
	family = "qfa-mix", -- WP says: it was 'tbq' but due to mixing it is now basically 'inc'
	ancestors = {"pka", "tbq-pro"},
}

m["hak"] = {
	canonicalName = "Hakka",
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"ltc"},
}

m["hal"] = {
	canonicalName = "Halang",
	family = "mkh",
}

m["ham"] = {
	canonicalName = "Hewa",
}

m["hao"] = {
	canonicalName = "Hakö",
	family = "poz-ocw",
}

m["hap"] = {
	canonicalName = "Hupla",
}

m["har"] = {
	canonicalName = "Harari",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["has"] = {
	canonicalName = "Haisla",
	family = "wak",
}

m["hav"] = {
	canonicalName = "Havu",
	family = "bnt",
}

m["haw"] = {
	canonicalName = "Hawaiian",
	scripts = {"Latn"},
	family = "poz-pol",
	sort_key = {
		from = {"ā", "ē", "ī", "ō", "ū" },
		to   = {"a", "e", "i", "o", "u" }} ,
}

m["hax"] = {
	canonicalName = "Southern Haida",
}

m["hay"] = {
	canonicalName = "Haya",
}

m["haz"] = {
	canonicalName = "Hazaragi",
}

m["hba"] = {
	canonicalName = "Hamba",
}

m["hbb"] = {
	canonicalName = "Huba",
	otherNames = {"Kilba"},
}

m["hbn"] = {
	canonicalName = "Heiban",
}

m["hbu"] = {
	canonicalName = "Habu",
	family = "plf",
}

m["hca"] = {
	canonicalName = "Andaman Creole Hindi",
}

m["hch"] = {
	canonicalName = "Huichol",
	scripts = {"Latn"},
	family = "azc",
}

m["hdn"] = {
	canonicalName = "Northern Haida",
}

m["hds"] = {
	canonicalName = "Honduras Sign Language",
	otherNames = {"Honduran Sign Language"},
	family = "sgn",
}

m["hdy"] = {
	canonicalName = "Hadiyya",
	family = "cus",
}

m["hea"] = {
	canonicalName = "Northern Qiandong Miao",
	otherNames = {"Black Miao"},
	family = "hmn",
}

m["hed"] = {
	canonicalName = "Herdé",
}

m["heg"] = {
	canonicalName = "Helong",
	family = "plf",
}

m["heh"] = {
	canonicalName = "Hehe",
}

m["hei"] = {
	canonicalName = "Heiltsuk",
	family = "wak",
}

m["hem"] = {
	canonicalName = "Hemba",
}

m["hgm"] = {
	canonicalName = "Haiǁom",
	family = "khi",
}

m["hgw"] = {
	canonicalName = "Haigwai",
	family = "poz-ocw",
}

m["hhi"] = {
	canonicalName = "Hoia Hoia",
}

m["hhr"] = {
	canonicalName = "Kerak",
}

m["hhy"] = {
	canonicalName = "Hoyahoya",
}

m["hia"] = {
	canonicalName = "Lamang",
}

m["hib"] = {
	canonicalName = "Hibito",
}

m["hid"] = {
	canonicalName = "Hidatsa",
	family = "sio",
}

m["hif"] = {
	canonicalName = "Fiji Hindi",
	scripts = {"Latn"},
	family = "inc",
	ancestors = {"awa"},
}

m["hig"] = {
	canonicalName = "Kamwe",
	otherNames = {"Higgi", "Higi"},
}

m["hih"] = {
	canonicalName = "Pamosu",
}

m["hii"] = {
	canonicalName = "Hinduri",
}

m["hij"] = {
	canonicalName = "Hijuk",
}

m["hik"] = {
	canonicalName = "Seit-Kaitetu",
}

m["hil"] = {
	canonicalName = "Hiligaynon",
	scripts = {"Latn"},
	family = "phi",
	entry_name = {
		from = {"Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", MACRON},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["hio"] = {
	canonicalName = "Tshwa",
	otherNames = {"Tsoa", "Kua", "Cua", "Hiechware", "Cirecire", "Cire-cire", "Cire-Cire", "Cire Cire"},
}

m["hir"] = {
	canonicalName = "Himarimã",
}

m["hit"] = {
	canonicalName = "Hittite",
	scripts = {"Xsux"},
	family = "ine-ana",
	ancestors = {"oht"},
}

m["hiw"] = {
	canonicalName = "Hiw",
	family = "poz-vnc",
}

m["hix"] = {
	canonicalName = "Hixkaryana",
	otherNames = {"Hixkaryána"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["hji"] = {
	canonicalName = "Haji",
}

m["hka"] = {
	canonicalName = "Kahe",
	family = "bnt",
}

m["hke"] = {
	canonicalName = "Hunde",
	family = "bnt",
}

m["hkk"] = {
	canonicalName = "Hunjara-Kaina Ke",
}

m["hks"] = {
	canonicalName = "Hong Kong Sign Language",
	family = "sgn",
}

m["hla"] = {
	canonicalName = "Halia",
	family = "poz-ocw",
}

m["hlb"] = {
	canonicalName = "Halbi",
	scripts = {"Deva", "Orya"},
	family = "inc",
	ancestors = {"pka"},
}

m["hld"] = {
	canonicalName = "Halang Doan",
}

m["hle"] = {
	canonicalName = "Hlersu",
	otherNames = {"Sansu"},
	family = "tbq-lol",
}

m["hlt"] = {
	canonicalName = "Nga La",
	otherNames = {"Matu Chin", "Matu"},
	family = "tbq-kuk",
}

m["hma"] = {
	canonicalName = "Southern Mashan Hmong",
	otherNames = {"Southern Mashan Miao"},
	family = "hmn",
}

m["hmb"] = {
	canonicalName = "Humburi Senni Songhay",
}

m["hmc"] = {
	canonicalName = "Central Huishui Hmong",
	otherNames = {"Central Huishui Miao"},
	family = "hmn",
}

m["hmd"] = {
	canonicalName = "A-Hmao",
	otherNames = {"A Hmao", "Big Flowery Miao", "Large Flowery Miao"},
	scripts = {"Latn", "Plrd"},
	family = "hmn",
}

m["hme"] = {
	canonicalName = "Eastern Huishui Hmong",
	otherNames = {"Eastern Huishui Miao"},
	family = "hmn",
}

m["hmf"] = {
	canonicalName = "Hmong Don",
	family = "hmn",
}

m["hmg"] = {
	canonicalName = "Southwestern Guiyang Hmong",
	family = "hmn",
}

m["hmh"] = {
	canonicalName = "Southwestern Huishui Hmong",
	otherNames = {"Southwestern Huishui Miao"},
	family = "hmn",
}

m["hmi"] = {
	canonicalName = "Northern Huishui Hmong",
	otherNames = {"Northern Huishui Miao"},
	family = "hmn",
}

m["hmj"] = {
	canonicalName = "Ge",
	otherNames = {"Gedou Miao"},
	family = "hmn",
}

m["hmk"] = {
	canonicalName = "Maek",
}

m["hml"] = {
	canonicalName = "Luopohe Hmong",
	family = "hmn",
}

m["hmm"] = {
	canonicalName = "Central Mashan Hmong",
	otherNames = {"Central Mashan Miao"},
	family = "hmn",
}

m["hmp"] = {
	canonicalName = "Northern Mashan Hmong",
	otherNames = {"Northern Mashan Miao"},
	family = "hmn",
}

m["hmq"] = {
	canonicalName = "Eastern Qiandong Miao",
	otherNames = {"Black Miao"},
	family = "hmn",
}

m["hmr"] = {
	canonicalName = "Hmar",
	family = "tbq-kuk",
	ancestors = {"lus"},
}

m["hms"] = {
	canonicalName = "Southern Qiandong Miao",
	otherNames = {"Black Miao"},
	family = "hmn",
}

m["hmt"] = {
	canonicalName = "Hamtai",
	otherNames = {"Kapau"},
}

m["hmu"] = {
	canonicalName = "Hamap",
}

m["hmv"] = {
	canonicalName = "Hmong Dô",
	otherNames = {"Hmong Do"},
	family = "hmn",
}

m["hmw"] = {
	canonicalName = "Western Mashan Hmong",
	otherNames = {"Western Mashan Miao"},
	family = "hmn",
}

m["hmy"] = {
	canonicalName = "Southern Guiyang Hmong",
	family = "hmn",
}

m["hmz"] = {
	canonicalName = "Hmong Shua",
	otherNames = {"Hmong Sua"},
	family = "hmn",
}

m["hna"] = {
	canonicalName = "Mina",
	otherNames = {"Mina (Cameroon)", "Hina", "Besleri"},
	family = "cdc",
}

m["hnd"] = {
	canonicalName = "Southern Hindko",
	family = "inc",
	ancestors = {"lah"},
}

m["hne"] = {
	canonicalName = "Chhattisgarhi",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"psu"},
}

m["hnh"] = {
	canonicalName = "ǁAni",
}

m["hni"] = {
	canonicalName = "Hani",
	family = "tbq-lol",
}

m["hnj"] = {
	canonicalName = "Green Hmong",
	otherNames = {"Hmong Njua", "Hmong Leng", "Mong Leng", "Green Miao", "Blue Hmong"},
	scripts = {"Latn", "Hmng"},
	family = "hmn",
}

m["hnn"] = {
	canonicalName = "Hanunoo",
	scripts = {"Hano"},
	family = "phi",
}

m["hno"] = {
	canonicalName = "Northern Hindko",
	otherNames = {"Kagani", "Hazara Hindko", "Hindki of Hazara"},
	scripts = {"Arab"},
	family = "inc",
	ancestors = {"lah"},
}

m["hns"] = {
	canonicalName = "Caribbean Hindustani",
	family = "inc",
	ancestors = {"bh"},
}

m["hnu"] = {
	canonicalName = "Hung",
	family = "mkh-vie",
}

m["hoa"] = {
	canonicalName = "Hoava",
	family = "poz-ocw",
}

m["hob"] = {
	canonicalName = "Austronesian Mari",
	otherNames = {"Mari (Madang Province)", "Hop"},
	family = "poz-ocw",
}

m["hoc"] = {
	canonicalName = "Ho",
	scripts = {"Wara", "Orya", "Deva", "Latn"},
	family = "mun",
}

m["hod"] = {
	canonicalName = "Holma",
	family = "cdc",
}

m["hoe"] = {
	canonicalName = "Horom",
	family = "nic-bco",
}

m["hoh"] = {
	canonicalName = "Hobyót",
	family = "sem-sar",
}

m["hoi"] = {
	canonicalName = "Holikachuk",
	scripts = {"Latn"},
	family = "ath-nor",
}

m["hoj"] = {
	canonicalName = "Hadothi",
	otherNames = {"Harauti"},
	family = "inc",
	ancestors = {"mwr"},
}

m["hol"] = {
	canonicalName = "Holu",
	family = "bnt",
}

m["hom"] = {
	canonicalName = "Homa",
	family = "bnt",
}

m["hoo"] = {
	canonicalName = "Holoholo",
	family = "bnt",
}

m["hop"] = {
	canonicalName = "Hopi",
	otherNames = {"Moqui"},
	scripts = {"Latn"},
	family = "azc",
}

m["hor"] = {
	canonicalName = "Horo",
	family = "csu",
}

m["hos"] = {
	canonicalName = "Ho Chi Minh City Sign Language",
	family = "sgn",
}

m["hot"] = {
	canonicalName = "Hote",
	family = "poz-ocw",
}

m["hov"] = {
	canonicalName = "Hovongan",
	family = "poz",
}

m["how"] = {
	canonicalName = "Honi",
	otherNames = {"Haoni", "Baihong", "Hao-Bai", "Ho"},
	family = "tbq-lol",
}

m["hoy"] = {
	canonicalName = "Holiya",
	family = "dra",
}

m["hoz"] = {
	canonicalName = "Hozo",
	family = "omv",
}

m["hpo"] = {
	canonicalName = "Hpon",
	family = "tbq",
}

m["hps"] = {
	canonicalName = "Hawai'i Pidgin Sign Language",
	otherNames = {"Hawaiian Sign Language", "Hula", "Hawaii Sign Language"},
	family = "sgn",
}

m["hra"] = {
	canonicalName = "Hrangkhol",
	family = "tbq-kuk",
}

m["hrc"] = {
	canonicalName = "Niwer Mil",
	otherNames = {"Tangga"}, -- the dialect of the Tangga macrolanguage spoken on Tangga island
	family = "poz-oce",
}

m["hre"] = {
	canonicalName = "Hre",
	otherNames = {"Hrê"},
	family = "aav-nbn",
}

m["hrk"] = {
	canonicalName = "Haruku",
	family = "plf",
}

m["hrm"] = {
	canonicalName = "Horned Miao",
	family = "hmn",
}

m["hro"] = {
	canonicalName = "Haroi",
	scripts = {"Latn"},
	family = "cmc",
}

m["hrp"] = {
	canonicalName = "Nhirrpi",
}

m["hrt"] = {
	canonicalName = "Hértevin",
}

m["hru"] = {
	canonicalName = "Hruso",
}

m["hrw"] = {
	canonicalName = "Warwar Feni",
	otherNames = {"Feni"},
	scripts = {"Latn"},
	family = "poz-oce",
}

m["hrx"] = {
	canonicalName = "Hunsrik",
	otherNames = {"Riograndenser Hunsrückisch"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmw-cfr"},
}

m["hrz"] = {
	canonicalName = "Harzani",
	otherNames = {"Harzandi"},
	family = "ira",
	ancestors = {"ira-azr"},
}

m["hsb"] = {
	canonicalName = "Upper Sorbian",
	otherNames = {"Upper Lusatian", "Upper Wendish"},
	scripts = {"Latn"},
	family = "wen",
}

m["hsh"] = {
	canonicalName = "Hungarian Sign Language",
	family = "sgn",
}

m["hsl"] = {
	canonicalName = "Hausa Sign Language",
	family = "sgn",
}

m["hsn"] = {
	canonicalName = "Xiang",
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"ltc"},
}

m["hss"] = {
	canonicalName = "Harsusi",
	family = "sem-sar",
}

m["hti"] = {
	canonicalName = "Hoti",
	family = "plf",
}

m["hto"] = {
	canonicalName = "Minica Huitoto",
}

m["hts"] = {
	canonicalName = "Hadza",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["htu"] = {
	canonicalName = "Hitu",
	family = "plf",
}

m["htx"] = {
	canonicalName = "Middle Hittite",
	scripts = {"Xsux"},
	family = "ine-ana",
	ancestors = {"hit"},
}

m["hub"] = {
	canonicalName = "Huambisa",
	otherNames = {"Huambiza", "Wambisa"},
}

m["huc"] = {
	canonicalName = "ǂHoan",
	otherNames = {"ǂ’Amkoe", "ǂHȍã", "ǂHȍȁn"},
}

m["hud"] = {
	canonicalName = "Huaulu",
}

m["huf"] = {
	canonicalName = "Humene",
}

m["hug"] = {
	canonicalName = "Huachipaeri",
}

m["huh"] = {
	canonicalName = "Huilliche",
}

m["hui"] = {
	canonicalName = "Huli",
}

m["huj"] = {
	canonicalName = "Northern Guiyang Hmong",
	family = "hmn",
}

m["huk"] = {
	canonicalName = "Hulung",
}

m["hul"] = {
	canonicalName = "Hula",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["hum"] = {
	canonicalName = "Hungana",
}

m["huo"] = {
	canonicalName = "Hu",
	family = "aav",
}

m["hup"] = {
	canonicalName = "Hupa",
	family = "ath-pco",
}

m["huq"] = {
	canonicalName = "Tsat",
	otherNames = {"Hainan Cham", "Hui", "Huihui", "Sanya Hui", "Utsat", "Utset"},
	family = "cmc",
}

m["hur"] = {
	canonicalName = "Halkomelem",
	scripts = {"Latn"},
	family = "sal",
}

m["hus"] = {
	canonicalName = "Wastek",
	otherNames = {"Huastek", "Huasteka", "Huasteque", "Huaxteca", "Huaxteco", "Huaxteque", "Huastecan"},
	scripts = {"Latn"},
	family = "myn",
}

m["huu"] = {
	canonicalName = "Murui Huitoto",
}

m["huv"] = {
	canonicalName = "Huave",
	otherNames = {"San Mateo del Mar Huave", "San Dionisio del Mar Huave", "Santa María del Mar Huave", "San Francisco del Mar Huave"},
	scripts = {"Latn"},
}

m["huw"] = {
	canonicalName = "Hukumina",
	otherNames = {"Palumata"},
	family = "plf",
}

m["hux"] = {
	canonicalName = "Nüpode Huitoto",
}

m["huy"] = {
	canonicalName = "Hulaulá",
}

m["huz"] = {
	canonicalName = "Hunzib",
	scripts = {"Cyrl"},
	family = "cau-tsz",
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["hvc"] = {
	canonicalName = "Haitian Vodoun Culture Language",
	otherNames = {"Langaj", "Langay"},
	scripts = {"Latn"},
	family = "crp",
}

m["hvk"] = {
	canonicalName = "Haveke",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["hvn"] = {
	canonicalName = "Sabu",
	otherNames = {"Savu"},
	scripts = {"Latn"},
	family = "plf",
}

m["hwa"] = {
	canonicalName = "Wané",
}

m["hwo"] = {
	canonicalName = "Hwana",
}

m["hya"] = {
	canonicalName = "Hya",
}

return m