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

m["faa"] = {
	canonicalName = "Fasu",
	otherNames = {"Namumi", "Namome", "Namo Me", "Kaipu", "Kaibu", "Some"},
	scripts = {"Latn"},
}

m["fab"] = {
	canonicalName = "Annobonese",
	otherNames = {"Fa d'Ambu"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"pt"},
}

m["fad"] = {
	canonicalName = "Wagi",
	family = "ngf",
}

m["faf"] = {
	canonicalName = "Fagani",
	family = "poz-sls",
}

m["fag"] = {
	canonicalName = "Finongan",
	family = "ngf-fin",
}

m["fah"] = {
	canonicalName = "Baissa Fali",
}

m["fai"] = {
	canonicalName = "Faiwol",
}

m["faj"] = {
	canonicalName = "Faita",
}

m["fak"] = {
	canonicalName = "Fang (Cameroon)",
	otherNames = {"Fang"},
	scripts = {"Latn"},
	family = "nic-bod",
}

m["fal"] = {
	canonicalName = "South Fali",
}

m["fam"] = {
	canonicalName = "Fam",
	family = "nic-bod",
}

m["fan"] = {
	canonicalName = "Fang (Guinea)",
	otherNames = {"Pahouin", "Fang (Equatorial Guinea)", "Fang"},
	scripts = {"Latn"},
	family = "bnt",
}

m["fap"] = {
	canonicalName = "Palor",
}

m["far"] = {
	canonicalName = "Fataleka",
	family = "poz-sls",
}

m["fau"] = {
	canonicalName = "Fayu",
	family = "paa-lkp",
}

m["fax"] = {
	canonicalName = "Fala",
	scripts = {"Latn"},
	family = "roa",
}

m["fay"] = {
	canonicalName = "Southwestern Fars",
}

m["faz"] = {
	canonicalName = "Northwestern Fars",
	family = "ira",
}

m["fbl"] = {
	canonicalName = "West Albay Bikol",
}

m["fcs"] = {
	canonicalName = "Quebec Sign Language",
	family = "sgn",
}

m["fer"] = {
	canonicalName = "Feroge",
}

m["ffi"] = {
	canonicalName = "Foia Foia",
}

m["fgr"] = {
	canonicalName = "Fongoro",
}

m["fia"] = {
	canonicalName = "Nobiin",
	scripts = {"Latn"},
	family = "nub",
	ancestors = {"onw"},
}

m["fie"] = {
	canonicalName = "Fyer",
}

m["fip"] = {
	canonicalName = "Fipa",
}

m["fir"] = {
	canonicalName = "Firan",
}

m["fit"] = {
	canonicalName = "Meänkieli",
	scripts = {"Latn"},
	family = "fiu-fin",
	ancestors = {"fi"},
}

m["fiw"] = {
	canonicalName = "Fiwaga",
}

m["fkk"] = {
	canonicalName = "Kirya-Konzel",
	otherNames = {"Kirya-Konzəl"},
	scripts = {"Latn"},
	family = "cdc",
}

m["fkv"] = {
	canonicalName = "Kven",
	scripts = {"Latn"},
	family = "fiu-fin",
	ancestors = {"fi"},
}

m["fla"] = {
	canonicalName = "Montana Salish",
	otherNames = {"Flathead", "Salish", "Séliš", "Kalispel–Pend d'oreille", "Kalispel"},
	scripts = {"Latn"},
	family = "sal",
}

m["flh"] = {
	canonicalName = "Foau",
	family = "paa-lkp",
}

m["fli"] = {
	canonicalName = "Fali",
}

m["fll"] = {
	canonicalName = "North Fali",
}

m["fln"] = {
	canonicalName = "Flinders Island",
}

m["flr"] = {
	canonicalName = "Fuliiru",
}

m["fly"] = {
	canonicalName = "Tsotsitaal",
	otherNames = {"Flaaitaal"},
}

m["fmp"] = {
	canonicalName = "Fe'fe'",
	family = "bai",
}

m["fmu"] = {
	canonicalName = "Far Western Muria",
	family = "dra",
	ancestors = {"gon"},
}

m["fng"] = {
	canonicalName = "Fanagalo",
	scripts = {"Latn"},
	family = "crp",
}

m["fni"] = {
	canonicalName = "Fania",
}

m["fod"] = {
	canonicalName = "Foodo",
}

m["foi"] = {
	canonicalName = "Foi",
	scripts = {"Latn"},
}

m["fom"] = {
	canonicalName = "Foma",
	family = "bnt",
}

m["fon"] = {
	canonicalName = "Fon",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["for"] = {
	canonicalName = "Fore",
	scripts = {"Latn"},
	family = "paa-kag",
}

m["fos"] = {
	canonicalName = "Siraya",
	scripts = {"Latn"},
	family = "map",
}

m["fpe"] = {
	canonicalName = "Pichinglis",
	scripts = {"Latn"},
	family = "crp",
}

m["fqs"] = {
	canonicalName = "Fas",
}

m["frd"] = {
	canonicalName = "Fordata",
}

m["frk"] = {
	canonicalName = "Frankish",
	otherNames = {"Old Frankish"},
	scripts = {"Latn", "Runr"}, -- It is attested in Runr, but most of our entries are reconstructed Latn
	family = "gmw",
}

m["frm"] = {
	canonicalName = "Middle French",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"fro"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["fro"] = {
	canonicalName = "Old French",
	otherNames = {"Judeo-French", "Zarphatic"},
	scripts = {"Latn", "Hebr"},
	family = "roa",
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["frp"] = {
	canonicalName = "Franco-Provençal",
	otherNames = {"Arpetan", "Arpitan"},
	scripts = {"Latn"},
	family = "roa",
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["frq"] = {
	canonicalName = "Forak",
	family = "ngf-fin",
}

m["frr"] = {
	canonicalName = "North Frisian",
	scripts = {"Latn"},
	family = "gmw-fri",
}

m["frt"] = {
	canonicalName = "Fortsenal",
	family = "poz-vnc",
}

m["fse"] = {
	canonicalName = "Finnish Sign Language",
	family = "sgn",
}

m["fsl"] = {
	canonicalName = "French Sign Language",
	family = "sgn-fsl",
}

m["fss"] = {
	canonicalName = "Finnish-Swedish Sign Language",
	family = "sgn",
}

m["fud"] = {
	canonicalName = "East Futuna",
	otherNames = {"Futunan", "Futunian", "Futuna"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["fuj"] = {
	canonicalName = "Ko",
}

m["fum"] = {
	canonicalName = "Fum",
	family = "nic-bod",
}

m["fun"] = {
	canonicalName = "Fulniô",
	family = "qfa-iso",
}

m["fur"] = {
	canonicalName = "Friulian",
	scripts = {"Latn"},
	family = "roa",
}

m["fut"] = {
	canonicalName = "Futuna-Aniwa",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["fuu"] = {
	canonicalName = "Furu",
}

m["fuy"] = {
	canonicalName = "Fuyug",
}

m["fvr"] = {
	canonicalName = "Fur",
}

m["fwa"] = {
	canonicalName = "Fwâi",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["fwe"] = {
	canonicalName = "Fwe",
}

return m