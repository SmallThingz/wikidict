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

m["haa"] = {
	"Hän",
	"Q28272",
	"ath-nor",
	otherNames = {"Han", "Dawson", "Moosehide", "Han-Kutchin"},
	scripts = Latn,
}

m["hab"] = {
	"Hanoi Sign Language",
	"Q12632107",
	"sgn",
	scripts = Latn, -- when documented
}

m["hac"] = {
	"Gurani",
	"Q33733",
	"ira-wes",
	otherNames = {"Gorani", "Avromani", "Awroman", "Awromani", "Hawramani", "Hawrami", "Hewrami", "Hourami", "Howrami", "Ourami"},
	scripts = {"ku-Arab"},
}

m["had"] = {
	"Hatam",
	"Q56825",
}

m["haf"] = {
	"Haiphong Sign Language",
	"Q39868240",
	"sgn",
}

m["hag"] = {
	"Hanga",
	"Q35426",
	"nic-gur",
	scripts = Latn,
}

m["hah"] = {
	"Hahon",
	"Q3125730",
	"poz-ocw",
	scripts = Latn,
}

m["hai"] = {
	"Haida",
	"Q33303",
	"qfa-iso",
	scripts = Latn,
}

m["haj"] = {
	"Hajong",
	"Q3350576",
	"qfa-mix",
	scripts = {"Beng", "Latn"},
	ancestors = {"inc-oas", "tbq-pro"},
}

m["hak"] = {
	"Хака",
	"Q33375",
	"zhx",
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["hal"] = {
	"Halang",
	"Q56307",
	"mkh",
}

m["ham"] = {
	"Hewa",
	"Q5748345",
}

m["hao"] = {
	"Hakö",
	"Q3125871",
	"poz-ocw",
	scripts = Latn,
}

m["hap"] = {
	"Hupla",
	"Q5946223",
}

m["har"] = {
	"Harari",
	"Q33626",
	"sem-eth",
	scripts = {"Ethi"},
}

m["has"] = {
	"Haisla",
	"Q3107399",
	"wak",
}

m["hav"] = {
	"Havu",
	"Q5684097",
	"bnt",
	scripts = Latn,
}

m["haw"] = {
	"Хавајски",
	"Q33569",
	"poz-pep",
	scripts = Latn,
	sort_key = {
		from = {"ā", "ē", "ī", "ō", "ū" },
		to   = {"a", "e", "i", "o", "u" }} ,
}

m["hax"] = {
	"Southern Haida",
	"Q12953543",
}

m["hay"] = {
	"Haya",
	"Q35756",
}

m["haz"] = {
	"Hazaragi",
	"Q33398",
	"ira-wes",
}

m["hba"] = {
	"Hamba",
	"Q11028905",
}

m["hbb"] = {
	"Huba",
	"Q56290",
	"cdc-cbm",
	otherNames = {"Kilba"},
}

m["hbn"] = {
	"Heiban",
	"Q35523",
}

m["hbu"] = {
	"Habu",
	"Q1567033",
	"poz-cet",
	scripts = Latn,
}

m["hca"] = {
	"Andaman Creole Hindi",
	"Q7599417",
	"crp",
	ancestors = {"hi"},
}

m["hch"] = {
	"Huichol",
	"Q35575",
	"azc",
	scripts = Latn,
}

m["hdn"] = {
	"Northern Haida",
	"Q20054484",
}

m["hds"] = {
	"Honduras Sign Language",
	"Q3915496",
	"sgn",
	otherNames = {"Honduran Sign Language"},
	scripts = Latn, -- when documented
}

m["hdy"] = {
	"Hadiyya",
	"Q56613",
	"cus",
}

m["hea"] = {
	"Northern Qiandong Miao",
	"Q3138832",
	"hmn",
	otherNames = {"Black Miao"},
}

m["hed"] = {
	"Herdé",
	"Q56253",
	"cdc",
}

m["heg"] = {
	"Helong",
	"Q35432",
	"poz-cet",
	scripts = Latn,
}

m["heh"] = {
	"Hehe",
	"Q3129390",
	"bnt",
	scripts = Latn,
}

m["hei"] = {
	"Heiltsuk",
	"Q5699507",
	"wak",
}

m["hem"] = {
	"Hemba",
	"Q5711209",
}

m["hgm"] = {
	"Haiǁom",
	"Q4494781",
	"khi-kho",
	scripts = Latn,
}

m["hgw"] = {
	"Haigwai",
	"Q5639108",
	"poz-ocw",
	scripts = Latn,
}

m["hhi"] = {
	"Hoia Hoia",
	"Q5877767",
}

m["hhr"] = {
	"Kerak",
	"Q11010783",
}

m["hhy"] = {
	"Hoyahoya",
	nil,
	"ngf",
}

m["hia"] = {
	"Lamang",
	"Q35700",
	"cdc-cbm",
	scripts = Latn,
}

m["hib"] = {
	"Hibito",
	"Q3135164",
}

m["hid"] = {
	"Hidatsa",
	"Q3135234",
	"sio",
	scripts = Latn,
}

m["hif"] = {
	"Fiji Hindi",
	"Q46728",
	"inc",
	scripts = Latn,
	ancestors = {"awa"},
}

m["hig"] = {
	"Kamwe",
	"Q56271",
	"cdc-cbm",
	otherNames = {"Higgi", "Higi"},
}

m["hih"] = {
	"Pamosu",
	"Q12953011",
}

m["hii"] = {
	"Hinduri",
	"Q5766763",
}

m["hij"] = {
	"Hijuk",
	"Q35274",
}

m["hik"] = {
	"Seit-Kaitetu",
	"Q7446989",
}

m["hil"] = {
	"Hiligaynon",
	"Q35978",
	"phi",
	scripts = Latn,
	entry_name = {
		from = {"Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", MACRON},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["hio"] = {
	"Tshwa",
	"Q963636",
	"khi-kho",
	otherNames = {"Tsoa", "Kua", "Cua", "Hiechware", "Cirecire", "Cire-cire", "Cire-Cire", "Cire Cire"},
}

m["hir"] = {
	"Himarimã",
	"Q5765127",
}

m["hit"] = {
	"Hittite",
	"Q35668",
	"ine-ana",
	scripts = {"Xsux"},
	ancestors = {"oht"},
}

m["hiw"] = {
	"Hiw",
	"Q3138713",
	"poz-vnc",
	scripts = Latn,
}

m["hix"] = {
	"Hixkaryana",
	"Q56522",
	"sai-car",
	otherNames = {"Hixkaryána"},
	scripts = Latn,
}

m["hji"] = {
	"Haji",
	"Q5639933",
}

m["hka"] = {
	"Kahe",
	"Q3892562",
	"bnt",
	scripts = Latn,
}

m["hke"] = {
	"Hunde",
	"Q3065432",
	"bnt",
	scripts = Latn,
}

m["hkk"] = {
	"Hunjara-Kaina Ke",
	nil,
}

m["hkn"] = {
	"Mel-Khaonh",
	nil,
	"aav-ban",
	otherNames = {"Mel", "Khaonh"},
}

m["hks"] = {
	"Hong Kong Sign Language",
	"Q17038844",
	"sgn",
}

m["hla"] = {
	"Halia",
	"Q3125959",
	"poz-ocw",
	scripts = Latn,
}

m["hlb"] = {
	"Halbi",
	"Q3695692",
	"inc",
	scripts = {"Deva", "Orya"},
	ancestors = {"inc-mgd"},
}

m["hld"] = {
	"Halang Doan",
	"Q3914632",
}

m["hle"] = {
	"Hlersu",
	"Q5873537",
	"tbq-lol",
	otherNames = {"Sansu"},
}

m["hlt"] = {
	"Nga La",
	"Q12952942",
	"tbq-kuk",
	otherNames = {"Matu Chin", "Matu"},
}

m["hma"] = {
	"Southern Mashan Hmong",
	"Q12953560",
	"hmn",
	otherNames = {"Southern Mashan Miao"},
}

m["hmb"] = {
	"Humburi Senni Songhay",
	"Q35486",
}

m["hmc"] = {
	"Central Huishui Hmong",
	"Q12953558",
	"hmn",
	otherNames = {"Central Huishui Miao"},
}

m["hmd"] = {
	"A-Hmao",
	"Q1108934",
	"hmn",
	otherNames = {"A Hmao", "Big Flowery Miao", "Large Flowery Miao"},
	scripts = {"Latn", "Plrd"},
}

m["hme"] = {
	"Eastern Huishui Hmong",
	"Q12953559",
	"hmn",
	otherNames = {"Eastern Huishui Miao"},
}

m["hmf"] = {
	"Hmong Don",
	"Q22911602",
	"hmn",
}

m["hmg"] = {
	"Southwestern Guiyang Hmong",
	"Q27478542",
	"hmn",
}

m["hmh"] = {
	"Southwestern Huishui Hmong",
	"Q12953565",
	"hmn",
	otherNames = {"Southwestern Huishui Miao"},
}

m["hmi"] = {
	"Northern Huishui Hmong",
	"Q27434946",
	"hmn",
	otherNames = {"Northern Huishui Miao"},
}

m["hmj"] = {
	"Ge",
	"Q11251864",
	"hmn",
	otherNames = {"Gedou Miao"},
}

m["hmk"] = {
	"Maek",
	"Q8050724",
}

m["hml"] = {
	"Luopohe Hmong",
	"Q14468943",
	"hmn",
}

m["hmm"] = {
	"Central Mashan Hmong",
	"Q12953561",
	"hmn",
	otherNames = {"Central Mashan Miao"},
}

m["hmp"] = {
	"Northern Mashan Hmong",
	"Q12953564",
	"hmn",
	otherNames = {"Northern Mashan Miao"},
}

m["hmq"] = {
	"Eastern Qiandong Miao",
	"Q27431369",
	"hmn",
	otherNames = {"Black Miao"},
}

m["hmr"] = {
	"Hmar",
	"Q2992841",
	"tbq-kuk",
	ancestors = {"lus"},
}

m["hms"] = {
	"Southern Qiandong Miao",
	"Q12953562",
	"hmn",
	otherNames = {"Black Miao"},
}

m["hmt"] = {
	"Hamtai",
	"Q5646436",
	"ngf",
	otherNames = {"Kapau"},
}

m["hmu"] = {
	"Hamap",
	"Q12952484",
}

m["hmv"] = {
	"Hmong Dô",
	"Q22911598",
	"hmn",
	otherNames = {"Hmong Do"},
}

m["hmw"] = {
	"Western Mashan Hmong",
	"Q12953563",
	"hmn",
	otherNames = {"Western Mashan Miao"},
}

m["hmy"] = {
	"Southern Guiyang Hmong",
	"Q12953553",
	"hmn",
}

m["hmz"] = {
	"Hmong Shua",
	"Q25559603",
	"hmn",
	otherNames = {"Hmong Sua"},
}

m["hna"] = {
	"Mina",
	"Q56532",
	"cdc-cbm",
	otherNames = {"Mina (Cameroon)", "Hina", "Besleri"},
}

m["hnd"] = {
	"Southern Hindko",
	"Q382273",
	"inc",
	ancestors = {"lah"},
}

m["hne"] = {
	"Chhattisgarhi",
	"Q33158",
	"inc",
	scripts = {"Deva"},
	ancestors = {"inc-ohi"},
}

m["hnh"] = {
	"ǁAni",
	"Q3832982",
	"khi-kho",
	scripts = {"Latinx"},
}

m["hni"] = {
	"Hani",
	"Q56516",
	"tbq-lol",
}

m["hnj"] = {
	"Green Hmong",
	"Q3138831",
	"hmn",
	otherNames = {"Hmong Njua", "Hmong Leng", "Mong Leng", "Green Miao", "Blue Hmong"},
	scripts = {"Latn", "Hmng"},
}

m["hnn"] = {
	"Hanunoo",
	"Q35435",
	"phi",
	otherNames = {"Hanuno'o"},
	scripts = {"Hano"},
}

m["hno"] = {
	"Northern Hindko",
	"Q6346358",
	"inc",
	otherNames = {"Kagani", "Hazara Hindko", "Hindki of Hazara"},
	scripts = {"Arab"},
	ancestors = {"lah"},
}

m["hns"] = {
	"Caribbean Hindustani",
	"Q1843468",
	"inc",
	otherNames = {"Caribbean Bhojpuri"},
	ancestors = {"bho"},
}

m["hnu"] = {
	"Hung",
	"Q12632753",
	"mkh-vie",
}

m["hoa"] = {
	"Hoava",
	"Q3138887",
	"poz-ocw",
	scripts = Latn,
}

m["hob"] = {
	"Austronesian Mari",
	"Q6760941",
	"poz-ocw",
	otherNames = {"Mari (Madang Province)", "Hop"},
	scripts = Latn,
}

m["hoc"] = {
	"Ho",
	"Q33270",
	"mun",
	scripts = {"Wara", "Orya", "Deva", "Latn"},
}

m["hod"] = {
	"Holma",
	"Q56331",
	"cdc",
	scripts = Latn,
}

m["hoe"] = {
	"Horom",
	"Q3914008",
	"nic-bco",
	scripts = Latn,
}

m["hoh"] = {
	"Hobyót",
	"Q33299",
	"sem-sar",
}

m["hoi"] = {
	"Holikachuk",
	"Q28508",
	"ath-nor",
	scripts = Latn,
}

m["hoj"] = {
	"Hadothi",
	"Q33227",
	"inc",
	otherNames = {"Harauti"},
	ancestors = {"mwr"},
}

m["hol"] = {
	"Holu",
	"Q4121133",
	"bnt",
	scripts = Latn,
}

m["hom"] = {
	"Homa",
	"Q3449953",
	"bnt",
	scripts = Latn,
}

m["hoo"] = {
	"Holoholo",
	"Q3139484",
	"bnt",
	scripts = Latn,
}

m["hop"] = {
	"Hopi",
	"Q56421",
	"azc",
	otherNames = {"Moqui"},
	scripts = Latn,
}

m["hor"] = {
	"Horo",
	"Q641748",
	"csu-sar",
}

m["hos"] = {
	"Ho Chi Minh City Sign Language",
	"Q16111971",
	"sgn",
	scripts = Latn, -- when documented
}

m["hot"] = {
	"Hote",
	"Q12632404",
	"poz-ocw",
	scripts = Latn,
}

m["hov"] = {
	"Hovongan",
	"Q5917269",
	"poz",
}

m["how"] = {
	"Honi",
	"Q56842",
	"tbq-lol",
	otherNames = {"Haoni", "Baihong", "Hao-Bai", "Ho"},
}

m["hoy"] = {
	"Holiya",
	"Q5880707",
	"dra",
}

m["hoz"] = {
	"Hozo",
	"Q5923010",
	"omv",
}

m["hpo"] = {
	"Hpon",
	"Q5923277",
	"tbq",
}

m["hps"] = {
	"Hawai'i Pidgin Sign Language",
	"Q33358",
	"sgn",
	otherNames = {"Hawaiian Sign Language", "Hula", "Hawaii Sign Language"},
	scripts = Latn, -- when documented
}

m["hra"] = {
	"Hrangkhol",
	"Q5923435",
	"tbq-kuk",
}

m["hrc"] = {
	"Niwer Mil",
	nil,
	"poz-oce",
	otherNames = {"Tangga"}, -- this variety of Tangga macrolanguage is on Tangga island
	scripts = Latn,
}

m["hre"] = {
	"Hre",
	"Q3915794",
	"aav-nbn",
	otherNames = {"Hrê"},
}

m["hrk"] = {
	"Haruku",
	"Q5675762",
	"poz-cet",
}

m["hrm"] = {
	"Horned Miao",
	nil,
	"hmn",
}

m["hro"] = {
	"Haroi",
	"Q3127568",
	"cmc",
	scripts = Latn,
}

m["hrp"] = {
	"Nhirrpi",
	"Q32571318",
}

m["hrt"] = {
	"Hértevin",
	"Q33290",
	"sem-ara",
	scripts = Latn,
}

m["hru"] = {
	"Hruso",
	"Q5923933",
}

m["hrw"] = {
	"Warwar Feni",
	nil,
	"poz-oce",
	otherNames = {"Feni"},
	scripts = Latn,
}

m["hrx"] = {
	"Hunsrik",
	"Q304049",
	"gmw",
	otherNames = {"Riograndenser Hunsrückisch"},
	scripts = Latn,
	ancestors = {"gmw-cfr"},
}

m["hrz"] = {
	"Harzani",
	"Q56464",
	"ira-wes",
	otherNames = {"Harzandi"},
	ancestors = {"ira-azr"},
}

m["hsb"] = {
	"Upper Sorbian",
	"Q13248",
	"wen",
	otherNames = {"Upper Lusatian", "Upper Wendish"},
	scripts = Latn,
	sort_key = {
		from = {"č",  "ć",   "ě",  "ch", "ł",  "ń",  "ó", "ř",  "š",  "ž",  "ź"    },
		to   = {"c~", "c~~", "e~", "h~", "l`", "n~", "o", "r~", "s~", "z~", "z~~" }} , --the digraph ch comes after h; ł comes before l
}

m["hsh"] = {
	"Hungarian Sign Language",
	"Q13636869",
	"sgn",
	scripts = Latn, -- when documented
}

m["hsl"] = {
	"Hausa Sign Language",
	"Q3915462",
	"sgn",
	scripts = Latn, -- when documented
}

m["hsn"] = {
	"Xiang",
	"Q13220",
	"zhx",
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["hss"] = {
	"Harsusi",
	"Q33423",
	"sem-sar",
}

m["hti"] = {
	"Hoti",
	"Q5912372",
	"poz-cet",
	scripts = Latn,
}

m["hto"] = {
	"Minica Huitoto",
	"Q948514",
	"sai-wit",
	otherNames = {"Minica", "Minica Witoto"},
	scripts = Latn,
}

m["hts"] = {
	"Hadza",
	"Q33411",
	"qfa-iso",
	scripts = Latn,
}

m["htu"] = {
	"Hitu",
	"Q5872700",
	"poz-cet",
	scripts = Latn,
}

m["htx"] = {
	"Middle Hittite",
	"Q12642599",
	"ine-ana",
	scripts = {"Xsux"},
	ancestors = {"hit"},
}

m["hub"] = {
	"Huambisa",
	"Q1526037",
	"sai-jiv",
	otherNames = {"Huambiza", "Wambisa"},
	scripts = Latn,
}

m["huc"] = {
	"ǂHoan",
	"Q2053913",
	"khi-kxa",
	otherNames = {"ǂ’Amkoe", "ǂHȍã", "ǂHȍȁn"},
	scripts = {"Latinx"},
}

m["hud"] = {
	"Huaulu",
	"Q12952504",
	scripts = Latn,
}

m["huf"] = {
	"Humene",
	"Q11732231",
	"ngf",
	scripts = Latn,
}

m["hug"] = {
	"Huachipaeri",
	"Q3446617",
	"sai-har",
	scripts = Latn,
}

m["huh"] = {
	"Huilliche",
	"Q35531",
	scripts = Latn,
}

m["hui"] = {
	"Huli",
	"Q3125121",
	"ngf",
	scripts = Latn,
}

m["huj"] = {
	"Northern Guiyang Hmong",
	"Q12953554",
	"hmn",
}

m["huk"] = {
	"Hulung",
	"Q12952505",
}

m["hul"] = {
	"Hula",
	"Q6382179",
	"poz-ocw",
	scripts = Latn,
}

m["hum"] = {
	"Hungana",
	"Q10975396",
}

m["huo"] = {
	"Hu",
	"Q3141783",
	"aav",
}

m["hup"] = {
	"Hupa",
	"Q28058",
	"ath-pco",
	scripts = Latn,
}

m["huq"] = {
	"Tsat",
	"Q34133",
	"cmc",
	otherNames = {"Hainan Cham", "Hui", "Huihui", "Sanya Hui", "Utsat", "Utset"},
}

m["hur"] = {
	"Halkomelem",
	"Q35388",
	"sal",
	scripts = Latn,
}

m["hus"] = {
	"Wastek",
	"Q35573",
	"myn",
	otherNames = {"Huastek", "Huasteka", "Huasteque", "Huaxteca", "Huaxteco", "Huaxteque", "Huastecan"},
	scripts = Latn,
}

m["huu"] = {
	"Murui Huitoto",
	"Q2640935",
	"sai-wit",
	otherNames = {"Murui", "Murui Witoto"},
	scripts = Latn,
}

m["huv"] = {
	"Huave",
	"Q12954031",
	otherNames = {"San Mateo del Mar Huave", "San Dionisio del Mar Huave", "Santa María del Mar Huave", "San Francisco del Mar Huave"},
	scripts = Latn,
}

m["huw"] = {
	"Hukumina",
	"Q3142988",
	"poz-cet",
	otherNames = {"Palumata"},
	scripts = Latn,
}

m["hux"] = {
	"Nüpode Huitoto",
	"Q56333",
	"sai-wit",
	otherNames = {"Nüpode", "Nüpode Witoto"},
	scripts = Latn,
}

m["huy"] = {
	"Hulaulá",
	"Q33426",
	"sem-ara",
}

m["huz"] = {
	"Hunzib",
	"Q56564",
	"cau-tsz",
	scripts = {"Cyrl"},
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["hvc"] = {
	"Haitian Vodoun Culture Language",
	"Q3504239",
	"crp",
	otherNames = {"Langaj", "Langay"},
	scripts = Latn,
}

m["hvk"] = {
	"Haveke",
	"Q5683513",
	"poz-cln",
	scripts = Latn,
}

m["hvn"] = {
	"Sabu",
	"Q3128792",
	"poz-cet",
	otherNames = {"Savu"},
	scripts = Latn,
}

m["hwa"] = {
	"Wané",
	"Q3914887",
	scripts = Latn,
}

m["hwo"] = {
	"Hwana",
	"Q56498",
	scripts = Latn,
}

m["hya"] = {
	"Hya",
	"Q56798",
	scripts = Latn,
}

return m