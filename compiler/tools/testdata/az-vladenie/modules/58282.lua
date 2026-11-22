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

m["naa"] = {
	canonicalName = "Namla",
	family = "paa",
}

m["nab"] = {
	canonicalName = "Nambikwara",
	otherNames = {"Nambiquara", "Nambicuara", "Nambikuara", "Southern Nambikuára"},
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["nac"] = {
	canonicalName = "Narak",
	family = "ngf",
}

m["nae"] = {
	canonicalName = "Naka'ela",
	family = "poz",
}

m["naf"] = {
	canonicalName = "Nabak",
	family = "ngf",
}

m["nag"] = {
	canonicalName = "Naga Pidgin",
	otherNames = {"Nagamese"},
	scripts = {"Latn"},
	family = "crp",
}

m["nah"] = {
	canonicalName = "Nahuatl",
	scripts = {"Latn"},
	family = "azc-nah",
}

m["naj"] = {
	canonicalName = "Nalu",
	family = "alv-sng",
}

m["nak"] = {
	canonicalName = "Nakanai",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["nal"] = {
	canonicalName = "Nalik",
	family = "poz-ocw",
}

m["nam"] = {
	canonicalName = "Ngan'gityemerri",
	otherNames = {"Ngan'gi", "Nangikurrunggurr"},
	scripts = {"Latn"},
}

m["nan"] = {
	canonicalName = "Min Nan",
	otherNames = {"Hokkien", "Taiwanese", "Amoy", "Xiamenese"},
	scripts = {"Hani", "Latn"},
	family = "zhx",
	wikimedia_codes = {"zh-min-nan"},
	ancestors = {"zhx-min-pro"},
}

m["nao"] = {
	canonicalName = "Naaba",
	otherNames = {"Naapa", "Nawa Sherpa"},
	family = "tbq",
	ancestors = {"xct"},
}

m["nap"] = {
	canonicalName = "Neapolitan",
	scripts = {"Latn"},
	family = "roa",
}

m["naq"] = {
	canonicalName = "Nama",
	otherNames = {"Khoekhoe"},
	scripts = {"Latn"},
	family = "khi",
}

m["nar"] = {
	canonicalName = "Iguta",
	family = "nic-bco",
}

m["nas"] = {
	canonicalName = "Nasioi",
	otherNames = {"Naasioi"},
	scripts = {"Latn"},
	family = "paa",
}

m["nat"] = {
	canonicalName = "Hungworo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["naw"] = {
	canonicalName = "Nawuri",
	family = "alv-kwa",
}

m["nax"] = {
	canonicalName = "Nakwi",
}

m["nay"] = {
	canonicalName = "Ngarrindjeri",
	otherNames = {"Yaraldi"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["naz"] = {
	canonicalName = "Coatepec Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nba"] = {
	canonicalName = "Nyemba",
	family = "nic-bco",
}

m["nbb"] = {
	canonicalName = "Ndoe",
	family = "nic-bod",
}

m["nbc"] = {
	canonicalName = "Chang",
	family = "tbq",
}

m["nbd"] = {
	canonicalName = "Ngbinda",
	family = "bnt",
}

m["nbe"] = {
	canonicalName = "Konyak Naga",
}

m["nbg"] = {
	canonicalName = "Nagarchal",
	family = "dra",
	ancestors = {"gon"},
}

m["nbh"] = {
	canonicalName = "Ngamo",
	family = "cdc",
}

m["nbi"] = {
	canonicalName = "Mao Naga",
}

m["nbj"] = {
	canonicalName = "Ngarinman",
}

m["nbk"] = {
	canonicalName = "Nake",
}

m["nbm"] = {
	canonicalName = "Ngbaka Ma'bo",
	family = "nic-ubg",
}

m["nbn"] = {
	canonicalName = "Kuri",
	otherNames = {"Nabi"},
	family = "poz",
}

m["nbo"] = {
	canonicalName = "Nkukoli",
	family = "nic-bco",
}

m["nbp"] = {
	canonicalName = "Nnam",
	family = "nic-bod",
}

m["nbq"] = {
	canonicalName = "Nggem",
}

m["nbr"] = {
	canonicalName = "Numana-Nunku-Gbantu-Numbu",
}

m["nbs"] = {
	canonicalName = "Namibian Sign Language",
	family = "sgn",
}

m["nbt"] = {
	canonicalName = "Na",
}

m["nbu"] = {
	canonicalName = "Rongmei Naga",
}

m["nbv"] = {
	canonicalName = "Ngamambo",
	family = "nic-bod",
}

m["nbw"] = {
	canonicalName = "Southern Ngbandi",
	family = "nic-ubg",
}

m["nby"] = {
	canonicalName = "Ningera",
}

m["nca"] = {
	canonicalName = "Iyo",
	family = "ngf-fin",
}

m["ncb"] = {
	canonicalName = "Central Nicobarese",
}

m["ncc"] = {
	canonicalName = "Ponam",
	family = "poz-aay",
}

m["ncd"] = {
	canonicalName = "Nachering",
}

m["nce"] = {
	canonicalName = "Yale",
}

m["ncf"] = {
	canonicalName = "Notsi",
	family = "poz-ocw",
}

m["ncg"] = {
	canonicalName = "Nisga'a",
}

m["nch"] = {
	canonicalName = "Central Huasteca Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nci"] = {
	canonicalName = "Klassik Nauatl",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}
	},
}

m["ncj"] = {
	canonicalName = "Northern Puebla Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nck"] = {
	canonicalName = "Nakara",
	family = "aus-arn",
}

m["ncl"] = {
	canonicalName = "Michoacán Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["ncm"] = {
	canonicalName = "Nambo",
}

m["ncn"] = {
	canonicalName = "Nauna",
	family = "poz-aay",
}

m["nco"] = {
	canonicalName = "Sibe",
}

m["ncp"] = {
	canonicalName = "Ndaktup",
	family = "nic-bod",
}

m["ncr"] = {
	canonicalName = "Ncane",
	family = "nic-bod",
}

m["ncs"] = {
	canonicalName = "Nicaraguan Sign Language",
	family = "sgn",
}

m["nct"] = {
	canonicalName = "Chothe Naga",
	otherNames = {"Chothe"},
	family = "tbq-kuk",
}

m["ncu"] = {
	canonicalName = "Chumburung",
}

m["ncx"] = {
	canonicalName = "Central Puebla Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["ncz"] = {
	canonicalName = "Natchez",
}

m["nda"] = {
	canonicalName = "Ndasa",
}

m["ndb"] = {
	canonicalName = "Kenswei Nsei",
	family = "alv",
}

m["ndc"] = {
	canonicalName = "Ndau",
}

m["ndd"] = {
	canonicalName = "Nde-Nsele-Nta",
	family = "nic-bod",
}

m["ndf"] = {
	canonicalName = "Nadruvian",
}

m["ndg"] = {
	canonicalName = "Ndengereko",
}

m["ndh"] = {
	canonicalName = "Ndali",
	scripts = {"Latn"},
	family = "bnt",
}

m["ndi"] = {
	canonicalName = "Chamba Leko",
	otherNames = {"Samba Leko", "Samba Leeko"},
	family = "alv",
}

m["ndj"] = {
	canonicalName = "Ndamba",
}

m["ndk"] = {
	canonicalName = "Ndaka",
}

m["ndl"] = {
	canonicalName = "Ndolo",
}

m["ndm"] = {
	canonicalName = "Ndam",
}

m["ndn"] = {
	canonicalName = "Ngundi",
}

m["ndp"] = {
	canonicalName = "Ndo",
}

m["ndq"] = {
	canonicalName = "Ndombe",
}

m["ndr"] = {
	canonicalName = "Ndoola",
	family = "nic-bod",
}

m["nds"] = {
	canonicalName = "Low German",
	otherNames = {"Low Saxon", "Modern Low German"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gml"},
}

m["ndt"] = {
	canonicalName = "Ndunga",
	family = "nic-ubg",
}

m["ndu"] = {
	canonicalName = "Dugun",
}

m["ndv"] = {
	canonicalName = "Ndut",
	family = "alv-sng",
}

m["ndw"] = {
	canonicalName = "Ndobo",
}

m["ndx"] = {
	canonicalName = "Nduga",
}

m["ndy"] = {
	canonicalName = "Lutos",
}

m["ndz"] = {
	canonicalName = "Ndogo",
}

m["nea"] = {
	canonicalName = "Eastern Ngad'a",
}

m["neb"] = {
	canonicalName = "Toura",
}

m["nec"] = {
	canonicalName = "Nedebang",
}

m["ned"] = {
	canonicalName = "Nde-Gbite",
}

m["nee"] = {
	canonicalName = "Kumak",
	otherNames = {"Nêlêmwa-Nixumwak", "Nêlêmwa", "Nixumwak", "Nenema"},
	family = "poz-cln",
}

m["nef"] = {
	canonicalName = "Nefamese",
}

m["neg"] = {
	canonicalName = "Negidal",
	family = "tuw",
}

m["neh"] = {
	canonicalName = "Nyenkha",
	otherNames = {"Nyen", "Henka", "Mangsdekha", "Phobjip", "Mangdep", "Mangde", "Hen Kha", "Henkha", "Mandebi-kha", "Nehan", "Phobjikha", "Chutobikha"},
	scripts = {"Tibt", "Latn"},
	family = "sit",
}

m["nei"] = {
	canonicalName = "Neo-Hittite",
	scripts = {"Xsux"},
	family = "ine-ana",
	ancestors = {"htx"},
}

m["nej"] = {
	canonicalName = "Neko",
	family = "ngf-fin",
}

m["nek"] = {
	canonicalName = "Neku",
	family = "poz-cln",
}

m["nem"] = {
	canonicalName = "Nemi",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["nen"] = {
	canonicalName = "Nengone",
	family = "poz-occ",
}

m["neo"] = {
	canonicalName = "Ná-Meo",
	family = "hmn",
}

m["neq"] = {
	canonicalName = "North Central Mixe",
}

m["ner"] = {
	canonicalName = "Yahadian",
}

m["nes"] = {
	canonicalName = "Bhoti Kinnauri",
}

m["net"] = {
	canonicalName = "Nete",
}

m["neu"] = {
	canonicalName = "Neo",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["nev"] = {
	canonicalName = "Nyaheun",
}

m["new"] = {
	canonicalName = "Newari",
	scripts = {"Deva"},
	family = "sit",
	ancestors = {"nwx"},
	translit_module = "sa-translit",
}

m["nex"] = {
	canonicalName = "Neme",
}

m["ney"] = {
	canonicalName = "Neyo",
}

m["nez"] = {
	canonicalName = "Nez Perce",
	otherNames = {"Nez Percé", "Numipu"},
	scripts = {"Latn"},
	family = "nai-shp",
}

m["nfa"] = {
	canonicalName = "Dhao",
}

m["nfd"] = {
	canonicalName = "Ahwai",
}

m["nfl"] = {
	canonicalName = "Aiwoo",
	otherNames = {"Äiwoo"},
	scripts = {"Latn"},
	family = "poz-oce",
}

m["nfr"] = {
	canonicalName = "Nafaanra",
	family = "alv",
}

m["nfu"] = {
	canonicalName = "Mfumte",
	family = "nic-bod",
}

m["nga"] = {
	canonicalName = "Ngbaka",
	family = "alv",
}

m["ngb"] = {
	canonicalName = "Northern Ngbandi",
	family = "nic-ubg",
}

m["ngc"] = {
	canonicalName = "Lingombe",
	otherNames = {"Ngombe (Democratic Republic of the Congo)", "Ngombe"},
	family = "bnt",
}

m["ngd"] = {
	canonicalName = "Bagandou",
	otherNames = {"Ngando (Central African Republic)", "Ngando", "Bangandou"},
	family = "bnt",
}

m["nge"] = {
	canonicalName = "Ngemba",
	family = "nic-bod",
}

m["ngg"] = { -- compare 'aiy'
	canonicalName = "Ngbaka Manza",
	family = "alv",
}

m["ngh"] = {
	canonicalName = "Nǀuu",
	otherNames = {"Nǁng"},
	scripts = {"Latn"},
	family = "qfa-tuu",
}

m["ngi"] = {
	canonicalName = "Ngizim",
}

m["ngj"] = {
	canonicalName = "Ngie",
	family = "nic-bod",
}

m["ngk"] = {
	canonicalName = "Ngalkbun",
	family = "aus-gun",
}

m["ngl"] = {
	canonicalName = "Lomwe",
}

m["ngm"] = {
	canonicalName = "Ngatik Men's Creole",
	otherNames = {"Ngatikese", "Ngatikese Pidgin", "Ngatikese Creole"},
	family = "crp",
}

m["ngn"] = {
	canonicalName = "Ngwo",
	family = "nic-bod",
}

m["ngo"] = {
	canonicalName = "Ngoni",
	family = "bnt",
}

m["ngp"] = {
	canonicalName = "Ngulu",
}

m["ngq"] = {
	canonicalName = "Ngoreme",
}

m["ngr"] = {
	canonicalName = "Nagu",
	family = "poz-oce",
}

m["ngs"] = {
	canonicalName = "Gvoko",
	family = "cdc",
}

m["ngt"] = {
	canonicalName = "Ngeq",
	family = "mkh",
}

m["ngu"] = {
	canonicalName = "Guerrero Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["ngv"] = {
	canonicalName = "Nagumi",
}

m["ngw"] = {
	canonicalName = "Ngwaba",
}

m["ngx"] = {
	canonicalName = "Nggwahyi",
}

m["ngy"] = {
	canonicalName = "Tibea",
}

m["ngz"] = {
	canonicalName = "Ngungwel",
}

m["nha"] = {
	canonicalName = "Nhanda",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["nhb"] = {
	canonicalName = "Beng",
}

m["nhc"] = {
	canonicalName = "Tabasco Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhd"] = {
	canonicalName = "Chiripá",
}

m["nhe"] = {
	canonicalName = "Eastern Huasteca Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhf"] = {
	canonicalName = "Nhuwala",
	family = "aus-nga",
}

m["nhg"] = {
	canonicalName = "Tetelcingo Nahuatl",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhh"] = {
	canonicalName = "Nahari",
	family = "inc",
	ancestors = {"pka"},
}

m["nhi"] = {
	canonicalName = "Zacatlán-Ahuacatlán-Tepetzintla Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhk"] = {
	canonicalName = "Isthmus-Cosoleacaque Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhm"] = {
	canonicalName = "Morelos Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhn"] = {
	canonicalName = "Central Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nho"] = {
	canonicalName = "Takuu",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["nhp"] = {
	canonicalName = "Isthmus-Pajapan Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhq"] = {
	canonicalName = "Huaxcaleca Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhr"] = {
	canonicalName = "Naro",
}

m["nht"] = {
	canonicalName = "Ometepec Nahuatl",
}

m["nhu"] = {
	canonicalName = "Noone",
	family = "nic-bod",
}

m["nhv"] = {
	canonicalName = "Temascaltepec Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhw"] = {
	canonicalName = "Western Huasteca Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhx"] = {
	canonicalName = "Isthmus-Mecayapan Nahuatl",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhy"] = {
	canonicalName = "Northern Oaxaca Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhz"] = {
	canonicalName = "Santa María La Alta Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nia"] = {
	canonicalName = "Nias",
	scripts = {"Latn"},
	family = "poz-nws",
}

m["nib"] = {
	canonicalName = "Nakame",
	family = "ngf-fin",
}

m["nid"] = {
	canonicalName = "Ngandi",
	family = "aus-arn",
}

m["nie"] = {
	canonicalName = "Niellim",
}

m["nif"] = {
	canonicalName = "Nek",
	family = "ngf-fin",
}

m["nig"] = {
	canonicalName = "Ngalakan",
	family = "aus-gun",
}

m["nih"] = {
	canonicalName = "Nyiha",
}

m["nii"] = {
	canonicalName = "Nii",
}

m["nij"] = {
	canonicalName = "Ngaju",
	scripts = {"Latn"},
	family = "poz-brw",
}

m["nik"] = {
	canonicalName = "Southern Nicobarese",
}

m["nil"] = {
	canonicalName = "Nila",
}

m["nim"] = {
	canonicalName = "Nilamba",
}

m["nin"] = {
	canonicalName = "Ninzo",
}

m["nio"] = {
	canonicalName = "Nganasan",
	scripts = {"Cyrl"},
	family = "syd",
}

m["niq"] = {
	canonicalName = "Nandi",
}

m["nir"] = {
	canonicalName = "Nimboran",
}

m["nis"] = {
	canonicalName = "Nimi",
	family = "ngf-fin",
}

m["nit"] = {
	canonicalName = "Southeastern Kolami",
	otherNames = {"Naiki"},
	family = "dra",
}

m["niu"] = {
	canonicalName = "Niuean",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["niv"] = {
	canonicalName = "Nivkh",
	scripts = {"Cyrl"},
	family = "qfa-iso",
}

m["niw"] = {
	canonicalName = "Nimo",
}

m["nix"] = {
	canonicalName = "Hema",
}

m["niy"] = {
	canonicalName = "Ngiti",
}

m["niz"] = {
	canonicalName = "Ningil",
	family = "qfa-tor",
}

m["nja"] = {
	canonicalName = "Nzanyi",
}

m["njb"] = {
	canonicalName = "Nocte Naga",
}

m["njd"] = {
	canonicalName = "Ndonde Hamba",
}

m["njh"] = {
	canonicalName = "Lotha Naga",
}

m["nji"] = {
	canonicalName = "Gudanji",
}

m["njj"] = {
	canonicalName = "Njen",
	family = "nic-bod",
}

m["njl"] = {
	canonicalName = "Njalgulgule",
	family = "sdv",
}

m["njm"] = {
	canonicalName = "Angami",
}

m["njn"] = {
	canonicalName = "Liangmai Naga",
}

m["njo"] = {
	canonicalName = "Ao",
	otherNames = {"Mongsen Ao", "Ao Naga"},
	scripts = {"Latn"},
	family = "tbq",
}

m["njr"] = {
	canonicalName = "Njerep",
	family = "nic-bod",
}

m["njs"] = {
	canonicalName = "Nisa",
}

m["njt"] = {
	canonicalName = "Ndyuka-Trio Pidgin",
}

m["nju"] = {
	canonicalName = "Ngadjunmaya",
}

m["njx"] = {
	canonicalName = "Kunyi",
	family = "bnt",
}

m["njy"] = {
	canonicalName = "Njyem",
}

m["njz"] = {
	canonicalName = "Nyishi",
	otherNames = {"Nishi"},
	family = "sit",
}

m["nka"] = {
	canonicalName = "Nkoya",
}

m["nkb"] = {
	canonicalName = "Khoibu Naga",
}

m["nkc"] = {
	canonicalName = "Nkongho",
}

m["nkd"] = {
	canonicalName = "Koireng",
}

m["nke"] = {
	canonicalName = "Duke",
	family = "poz-ocw",
}

m["nkf"] = {
	canonicalName = "Inpui Naga",
}

m["nkg"] = {
	canonicalName = "Nekgini",
	family = "ngf-fin",
}

m["nkh"] = {
	canonicalName = "Khezha Naga",
}

m["nki"] = {
	canonicalName = "Thangal Naga",
}

m["nkj"] = {
	canonicalName = "Nakai",
}

m["nkk"] = {
	canonicalName = "Nokuku",
	family = "poz-vnc",
}

m["nkm"] = {
	canonicalName = "Namat",
}

m["nkn"] = {
	canonicalName = "Nkangala",
}

m["nko"] = {
	canonicalName = "Nkonya",
}

m["nkp"] = {
	canonicalName = "Niuatoputapu",
	family = "poz-pol",
}

m["nkq"] = {
	canonicalName = "Nkami",
}

m["nkr"] = {
	canonicalName = "Nukuoro",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["nks"] = {
	canonicalName = "North Asmat",
}

m["nkt"] = {
	canonicalName = "Nyika",
	otherNames = {"Nyiha", "Kinyika", "Kinyiha", "Nyixa", "Chinyika"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nku"] = {
	canonicalName = "Bouna Kulango",
}

m["nkw"] = {
	canonicalName = "Nkutu",
}

m["nkx"] = {
	canonicalName = "Nkoroo",
}

m["nkz"] = {
	canonicalName = "Nkari",
}

m["nla"] = {
	canonicalName = "Ngombale",
	family = "bai",
}

m["nlc"] = {
	canonicalName = "Nalca",
	otherNames = {"Hmanggona", "Hmonono", "Kimjal"},
	scripts = {"Latn"},
	family = "ngf",
}

m["nle"] = {
	canonicalName = "East Nyala",
}

m["nlg"] = {
	canonicalName = "Gela",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["nli"] = {
	canonicalName = "Grangali",
	otherNames = {"Nangalami"},
	family = "inc-dar",
}

m["nlj"] = {
	canonicalName = "Nyali",
}

m["nlk"] = {
	canonicalName = "Ninia Yali",
}

m["nll"] = {
	canonicalName = "Nihali",
	scripts = {"Deva"},
	family = "qfa-iso",
}

m["nlo"] = {
	canonicalName = "Ngul",
}

m["nlq"] = {
	canonicalName = "Lao Naga",
}

m["nlu"] = {
	canonicalName = "Nchumbulu",
}

m["nlv"] = {
	canonicalName = "Orizaba Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nlw"] = {
	canonicalName = "Walangama",
}

m["nlx"] = {
	canonicalName = "Nahali",
}

m["nly"] = {
	canonicalName = "Nyamal",
	family = "aus-nga",
}

m["nlz"] = {
	canonicalName = "Nalögo",
	family = "poz-oce",
}

m["nma"] = {
	canonicalName = "Maram Naga",
}

m["nmb"] = {
	canonicalName = "Big Nambas",
	family = "poz-vnc",
}

m["nmc"] = {
	canonicalName = "Ngam",
}

m["nmd"] = {
	canonicalName = "Ndumu",
}

m["nme"] = {
	canonicalName = "Mzieme Naga",
}

m["nmf"] = {
	canonicalName = "Tangkhul Naga",
	otherNames = {"Tangkhul"},
}

m["nmg"] = {
	canonicalName = "Kwasio",
}

m["nmh"] = {
	canonicalName = "Monsang Naga",
}

m["nmi"] = {
	canonicalName = "Nyam",
}

m["nmj"] = {
	canonicalName = "Bangando-Ngombe",
	otherNames = {"Bagando-Ngombe", "Ngombe-Kaka", "Ngombe (Central African Republic)", "Ngombe"},
}

m["nmk"] = {
	canonicalName = "Namakura",
	family = "poz-vnc",
}

m["nml"] = {
	canonicalName = "Ndemli",
	family = "nic-bod",
}

m["nmm"] = {
	canonicalName = "Manangba",
}

m["nmn"] = {
	canonicalName = "ǃXóõ",
	otherNames = {"Xoo", "Taa"},
	scripts = {"Latn"},
	family = "qfa-tuu",
}

m["nmo"] = {
	canonicalName = "Moyon Naga",
	otherNames = {"Moyon"},
	family = "tbq-kuk",
}

m["nmp"] = {
	canonicalName = "Nimanbur",
}

m["nmq"] = {
	canonicalName = "Nambya",
}

m["nmr"] = {
	canonicalName = "Nimbari",
}

m["nms"] = {
	canonicalName = "Letemboi",
	family = "poz-vnc",
}

m["nmt"] = {
	canonicalName = "Namonuito",
	family = "poz-mic",
}

m["nmu"] = {
	canonicalName = "Northeast Maidu",
	family = "nai-mdu",
}

m["nmv"] = {
	canonicalName = "Ngamini",
	family = "aus-kar",
}

m["nmw"] = {
	canonicalName = "Nimoa",
	otherNames = {"Rifao"},
	family = "poz-ocw",
}

m["nmy"] = {
	canonicalName = "Namuyi",
}

m["nmz"] = {
	canonicalName = "Nawdm",
}

m["nna"] = {
	canonicalName = "Nyangumarta",
}

m["nnb"] = {
	canonicalName = "Nande",
}

m["nnc"] = {
	canonicalName = "Nancere",
}

m["nnd"] = {
	canonicalName = "West Ambae",
	family = "poz-vnc",
}

m["nne"] = {
	canonicalName = "Ngandyera",
}

m["nnf"] = {
	canonicalName = "Ngaing",
	family = "ngf-fin",
}

m["nng"] = {
	canonicalName = "Maring Naga",
}

m["nnh"] = {
	canonicalName = "Ngiemboon",
	family = "bai",
}

m["nni"] = {
	canonicalName = "North Nuaulu",
}

m["nnj"] = {
	canonicalName = "Nyangatom",
}

m["nnk"] = {
	canonicalName = "Nankina",
	family = "ngf-fin",
}

m["nnl"] = {
	canonicalName = "Northern Rengma Naga",
}

m["nnm"] = {
	canonicalName = "Namia",
}

m["nnn"] = {
	canonicalName = "Ngete",
}

m["nnp"] = {
	canonicalName = "Wancho",
}

m["nnq"] = {
	canonicalName = "Ngindo",
}

m["nnr"] = {
	canonicalName = "Narungga",
}

m["nns"] = {
	canonicalName = "Ningye",
}

m["nnt"] = {
	canonicalName = "Nanticoke",
	scripts = {"Latn"},
	family = "alg",
}

m["nnu"] = {
	canonicalName = "Dwang",
}

m["nnv"] = {
	canonicalName = "Nukunu",
}

m["nnw"] = {
	canonicalName = "Southern Nuni",
}

m["nnx"] = {
	canonicalName = "Ngong",
}

m["nny"] = {
	canonicalName = "Nyangga",
}

m["nnz"] = {
	canonicalName = "Nda'nda'",
	family = "bai",
}

m["noa"] = {
	canonicalName = "Woun Meu",
}

m["noc"] = {
	canonicalName = "Nuk",
	family = "ngf-fin",
}

m["nod"] = {
	canonicalName = "Northern Thai",
	scripts = {"Lana", "Thai"},
	family = "tai-swe",
}

m["noe"] = {
	canonicalName = "Nimadi",
}

m["nof"] = {
	canonicalName = "Nomane",
}

m["nog"] = {
	canonicalName = "Nogai",
	otherNames = {"Nogay"},
	scripts = {"Cyrl", "Arab", "Latn"},
	family = "trk",
	translit_module = "nog-translit",
}

m["noh"] = {
	canonicalName = "Nomu",
}

m["noi"] = {
	canonicalName = "Noiri",
	family = "inc",
}

m["noj"] = {
	canonicalName = "Nonuya",
}

m["nok"] = {
	canonicalName = "Nooksack",
}

m["nol"] = {
	canonicalName = "Nomlaki",
	family = "nai-wtq",
}

m["nom"] = {
	canonicalName = "Nocamán",
	family = "sai-pan",
}

m["non"] = {
	canonicalName = "Old Norse",
	otherNames = {"Old Icelandic", "Old Norwegian"}, -- note: Old Swedish and Old Danish have their own codes
	scripts = {"Latn"},
	family = "gmq",
}

m["nop"] = {
	canonicalName = "Numanggang",
	family = "ngf-fin",
}

m["noq"] = {
	canonicalName = "Ngongo",
}

m["nos"] = {
	canonicalName = "Eastern Nisu",
	family = "tbq-lol",
}

m["not"] = {
	canonicalName = "Nomatsiguenga",
	family = "awd",
}

m["nou"] = {
	canonicalName = "Ewage-Notu",
}

m["nov"] = {
	canonicalName = "Novial",
	scripts = {"Latn"},
	family = "art",
}

m["now"] = {
	canonicalName = "Nyambo",
}

m["noy"] = {
	canonicalName = "Noy",
}

m["noz"] = {
	canonicalName = "Nayi",
}

m["npa"] = {
	canonicalName = "Nar Phu",
}

m["npb"] = {
	canonicalName = "Nupbikha",
	family = "tbq",
}

m["nph"] = {
	canonicalName = "Phom",
	family = "sit",
}

m["npl"] = {
	canonicalName = "Southeastern Puebla Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["npn"] = {
	canonicalName = "Mondropolon",
	family = "poz-aay",
}

m["npo"] = {
	canonicalName = "Pochuri Naga",
}

m["nps"] = {
	canonicalName = "Nipsan",
}

m["npu"] = {
	canonicalName = "Puimei Naga",
}

m["npy"] = {
	canonicalName = "Napu",
}

m["nqg"] = {
	canonicalName = "Ede Nago",
}

m["nqk"] = {
	canonicalName = "Kura Ede Nago",
}

m["nqm"] = {
	canonicalName = "Ndom",
}

m["nqn"] = {
	canonicalName = "Nen",
}

m["nqo"] = {
	canonicalName = "N'Ko",
	scripts = {"Nkoo"},
	family = "dmn",
}

m["nqq"] = {
	canonicalName = "Kyan-Karyaw Naga",
}

m["nra"] = {
	canonicalName = "Ngom",
}

m["nrb"] = {
	canonicalName = "Nara",
}

m["nrc"] = {
	canonicalName = "Noric",
	scripts = {"Ital"},
	family = "cel",
}

m["nre"] = {
	canonicalName = "Southern Rengma Naga",
}

m["nrf"] = {
	canonicalName = "Norman",
	otherNames = {"Cauchois", "Jèrriais", "Jersey French", "Jersey Norman", "Jersey Norman French", "Guernésiais", "Dgèrnésiais", "Guernsey French", "Guernsey Norman French", "Augeron", "Sercquiais", "Auregnais"},
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"frm"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "æ" , "œ" , "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c", "ae", "oe"}} ,
	wikimedia_codes = {"nrm"},
}

m["nrg"] = {
	canonicalName = "Narango",
	family = "poz-vnc",
}

m["nri"] = {
	canonicalName = "Chokri Naga",
}

m["nrk"] = {
	canonicalName = "Ngarla",
	scripts = {"Latn"},
	family = "aus-nga",
}

m["nrl"] = {
	canonicalName = "Ngarluma",
	family = "aus-nga",
}

m["nrm"] = {
	canonicalName = "Narom",
	family = "poz-swa",
}

m["nrn"] = {
	canonicalName = "Norn",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"non"},
}

m["nrp"] = {
	canonicalName = "North Picene",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["nrr"] = {
	canonicalName = "Norra",
}

m["nrt"] = {
	canonicalName = "Northern Kalapuya",
}

m["nru"] = {
	canonicalName = "Narua",
	family = "tbq",
}

m["nrx"] = {
	canonicalName = "Ngurmbur",
}

m["nrz"] = {
	canonicalName = "Lala",
	family = "poz-ocw",
}

m["nsa"] = {
	canonicalName = "Sangtam Naga",
}

m["nsc"] = {
	canonicalName = "Nshi",
}

m["nsd"] = {
	canonicalName = "Southern Nisu",
	family = "tbq-lol",
}

m["nse"] = {
	canonicalName = "Nsenga",
}

m["nsg"] = {
	canonicalName = "Ngasa",
	family = "sdv",
}

m["nsh"] = {
	canonicalName = "Ngoshie",
	family = "nic-bod",
}

m["nsi"] = {
	canonicalName = "Nigerian Sign Language",
	family = "sgn",
}

m["nsk"] = {
	canonicalName = "Naskapi",
	scripts = {"Cans"},
	family = "alg",
	ancestors = {"cr"},
	translit_module = "nsk-translit",
}

m["nsl"] = {
	canonicalName = "Norwegian Sign Language",
	family = "sgn",
}

m["nsm"] = {
	canonicalName = "Sema",
}

m["nsn"] = {
	canonicalName = "Nehan",
	family = "poz-ocw",
}

m["nso"] = {
	canonicalName = "Northern Sotho",
	scripts = {"Latn"},
	family = "bnt",
}

m["nsp"] = {
	canonicalName = "Nepalese Sign Language",
	family = "sgn",
}

m["nsq"] = {
	canonicalName = "Northern Sierra Miwok",
	family = "nai-utn",
}

m["nsr"] = {
	canonicalName = "Maritime Sign Language",
	family = "sgn",
}

m["nss"] = {
	canonicalName = "Nali",
	family = "poz-aay",
}

m["nst"] = {
	canonicalName = "Tangsa",
}

m["nsu"] = {
	canonicalName = "Sierra Negra Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nsv"] = {
	canonicalName = "Southwestern Nisu",
	family = "tbq-lol",
}

m["nsw"] = {
	canonicalName = "Navut",
	family = "poz-vnc",
}

m["nsx"] = {
	canonicalName = "Nsongo",
}

m["nsy"] = {
	canonicalName = "Nasal",
}

m["nsz"] = {
	canonicalName = "Nisenan",
	family = "nai-mdu",
}

m["ntd"] = {
	canonicalName = "Northern Tidong",
	otherNames = {"Sesayap Tidong", "Northern Tidung", "Sesayap Tidung"},
}

m["nte"] = {
	canonicalName = "Nathembo",
}

m["ntg"] = {
	canonicalName = "Ngantangarra",
}

m["nti"] = {
	canonicalName = "Natioro",
}

m["ntj"] = {
	canonicalName = "Ngaanyatjarra",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["ntk"] = {
	canonicalName = "Ikoma",
}

m["ntm"] = {
	canonicalName = "Nateni",
}

m["nto"] = {
	canonicalName = "Ntomba",
	scripts = {"Latn"},
	family = "bnt",
}

m["ntp"] = {
	canonicalName = "Northern Tepehuan",
	family = "azc",
}

m["ntr"] = {
	canonicalName = "Delo",
}

m["nts"] = {
	canonicalName = "Natagaimas",
}

m["ntu"] = {
	canonicalName = "Natügu",
	family = "poz-oce",
}

m["ntw"] = {
	canonicalName = "Nottoway",
	family = "iro",
}

m["ntx"] = {
	canonicalName = "Somra",
	otherNames = {"Tangkhul Naga", "Burmese Tangkhul", "Somra Tangkhul"},
}

m["nty"] = {
	canonicalName = "Mantsi",
}

m["ntz"] = {
	canonicalName = "Natanzi",
	family = "ira",
}

m["nua"] = {
	canonicalName = "Yuaga",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["nuc"] = {
	canonicalName = "Nukuini",
}

m["nud"] = {
	canonicalName = "Ngala",
}

m["nue"] = {
	canonicalName = "Ngundu",
}

m["nuf"] = {
	canonicalName = "Nusu",
	family = "tbq-lol",
}

m["nug"] = {
	canonicalName = "Nungali",
}

m["nuh"] = {
	canonicalName = "Ndunda",
	family = "nic-bod",
}

m["nui"] = {
	canonicalName = "Ngumbi",
}

m["nuj"] = {
	canonicalName = "Nyole",
}

m["nuk"] = {
	canonicalName = "Nootka",
	otherNames = {"Nuu-chah-nulth", "Nuuchahnulth", "T'aat'aaqsapa"},
	scripts = {"Latn"},
	family = "wak",
}

m["nul"] = {
	canonicalName = "Nusa Laut",
}

m["num"] = {
	canonicalName = "Niuafo'ou",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["nun"] = {
	canonicalName = "Anong",
	otherNames = {"Nung"}, -- also mistakenly assigned the name "Ayi" by the ISO
	family = "tbq",
}

m["nuo"] = {
	canonicalName = "Nguôn",
	family = "mkh-vie",
}

m["nup"] = {
	canonicalName = "Nupe",
	otherNames = {"Nupe-Nupe-Tako"},
	scripts = {"Latn"},
	family = "alv-von",
}

m["nuq"] = {
	canonicalName = "Nukumanu",
	family = "poz-pol",
}

m["nur"] = {
	canonicalName = "Nuguria",
	otherNames = {"Nukuria"},
	family = "poz-pol",
}

m["nus"] = {
	canonicalName = "Nuer",
	family = "sdv",
}

m["nut"] = {
	canonicalName = "Nung",
	family = "tai",
}

m["nuu"] = {
	canonicalName = "Ngbundu",
}

m["nuv"] = {
	canonicalName = "Northern Nuni",
}

m["nuw"] = {
	canonicalName = "Nguluwan",
}

m["nux"] = {
	canonicalName = "Mehek",
}

m["nuy"] = {
	canonicalName = "Nunggubuyu",
	otherNames = {"Wubuy"},
	family = "aus-arn",
}

m["nuz"] = {
	canonicalName = "Tlamacazapa Nahuatl",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nvh"] = {
	canonicalName = "Nasarian",
	family = "poz-vnc",
}

m["nvm"] = {
	canonicalName = "Namiae",
}

m["nvo"] = {
	canonicalName = "Nyokon",
	family = "nic-bod",
}

m["nwa"] = {
	canonicalName = "Nawathinehena",
	scripts = {"Latn"},
	family = "alg",
}

m["nwb"] = {
	canonicalName = "Nyabwa",
}

m["nwc"] = {
	canonicalName = "Classical Newari",
	family = "sit",
}

m["nwe"] = {
	canonicalName = "Ngwe",
	family = "bai",
}

m["nwi"] = {
	canonicalName = "Southwest Tanna",
}

m["nwm"] = {
	canonicalName = "Nyamusa-Molo",
}

m["nwo"] = {
	canonicalName = "Nauo",
	otherNames = {"Nawo"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["nwr"] = {
	canonicalName = "Nawaru",
}

m["nwx"] = {
	canonicalName = "Middle Newar",
	family = "sit",
	ancestors = {"nwc"},
}

m["nwy"] = {
	canonicalName = "Nottoway-Meherrin",
	family = "iro",
}

m["nxa"] = {
	canonicalName = "Nauete",
	family = "poz",
}

m["nxd"] = {
	canonicalName = "Longandu",
	otherNames = {"Ngando (Democratic Republic of the Congo)", "Ngando"},
	family = "bnt",
}

m["nxe"] = {
	canonicalName = "Nage",
	family = "plf",
}

m["nxg"] = {
	canonicalName = "Ngadha",
	otherNames = {"Ngad'a"},
	scripts = {"Latn"},
	family = "plf",
}

m["nxi"] = {
	canonicalName = "Nindi",
}

m["nxl"] = {
	canonicalName = "South Nuaulu",
}

m["nxm"] = {
	canonicalName = "Numidian",
}

m["nxn"] = {
	canonicalName = "Ngawun",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["nxo"] = {
	canonicalName = "Ndambomo",
	scripts = {"Latn"},
	family = "bnt",
}

m["nxq"] = {
	canonicalName = "Naxi",
	family = "tbq",
}

m["nxr"] = {
	canonicalName = "Ninggerum",
}

m["nxu"] = {
	canonicalName = "Narau",
}

m["nxx"] = {
	canonicalName = "Nafri",
}

m["nyb"] = {
	canonicalName = "Nyangbo",
}

m["nyc"] = {
	canonicalName = "Nyanga-li",
}

m["nyd"] = {
	canonicalName = "Nyore",
}

m["nye"] = {
	canonicalName = "Nyengo",
}

m["nyf"] = {
	canonicalName = "Giryama",
}

m["nyg"] = {
	canonicalName = "Nyindu",
}

m["nyh"] = {
	canonicalName = "Nyigina",
}

m["nyi"] = {
	canonicalName = "Nyimang",
}

m["nyj"] = {
	canonicalName = "Nyanga",
}

m["nyk"] = {
	canonicalName = "Nyaneka",
}

m["nyl"] = {
	canonicalName = "Nyeu",
	family = "mkh",
}

m["nym"] = {
	canonicalName = "Nyamwezi",
}

m["nyn"] = {
	canonicalName = "Nyankole",
	scripts = {"Latn"},
	family = "bnt",
}

m["nyo"] = {
	canonicalName = "Nyoro",
}

m["nyp"] = {
	canonicalName = "Nyang'i",
}

m["nyq"] = {
	canonicalName = "Nayini",
	family = "ira",
}

m["nyr"] = {
	canonicalName = "Shinyiha",
	otherNames = {"Nyiha"},
}

m["nys"] = {
	canonicalName = "Nyunga",
	otherNames = {"Noongar", "Nyuunga"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["nyt"] = {
	canonicalName = "Nyawaygi",
}

m["nyu"] = {
	canonicalName = "Nyungwe",
}

m["nyv"] = {
	canonicalName = "Nyulnyul",
}

m["nyw"] = {
	canonicalName = "Nyaw",
}

m["nyx"] = {
	canonicalName = "Nganyaywana",
	family = "aus-cww",
}

m["nyy"] = {
	canonicalName = "Nyakyusa", "Kinyakyusa", "Nyakyusa-Ngonde",
	scripts = {"Latn"},
	family = "bnt",
}

m["nza"] = {
	canonicalName = "Tigon Mbembe",
}

m["nzb"] = {
	canonicalName = "Njebi",
}

m["nzi"] = {
	canonicalName = "Nzima",
}

m["nzk"] = {
	canonicalName = "Nzakara",
	scripts = {"Latn"},
	family = "znd",
}

m["nzm"] = {
	canonicalName = "Zeme Naga",
}

m["nzs"] = {
	canonicalName = "New Zealand Sign Language",
	family = "sgn",
}

m["nzu"] = {
	canonicalName = "Teke-Nzikou",
}

m["nzy"] = {
	canonicalName = "Nzakambay",
}

m["nzz"] = {
	canonicalName = "Nanga Dama Dogon",
	family = "qfa-dgn",
}

return m