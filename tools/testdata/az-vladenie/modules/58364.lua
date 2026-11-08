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

m["vaa"] = {
	canonicalName = "Vaagri Booli",
}

m["vae"] = {
	canonicalName = "Vale",
}

m["vaf"] = {
	canonicalName = "Vafsi",
	ancestors = {"ira-azr"},
}

m["vag"] = {
	canonicalName = "Vagla",
}

m["vah"] = {
	canonicalName = "Varhadi-Nagpuri",
}

m["vai"] = {
	canonicalName = "Vai",
	otherNames = {"Gallinas", "Vy"},
	scripts = {"Vaii"},
	family = "dmn",
}

m["vaj"] = {
	canonicalName = "Sekele",
	otherNames = {"Sekela", "Vasekele", "Vasekela", "Vasekela Bushman", "ǃ'OǃKung"},
}

m["val"] = {
	canonicalName = "Vehes",
}

m["vam"] = {
	canonicalName = "Vanimo",
}

m["van"] = {
	canonicalName = "Valman",
	family = "qfa-tor",
}

m["vao"] = {
	canonicalName = "Vao",
	family = "poz-vnc",
}

m["vap"] = {
	canonicalName = "Vaiphei",
	family = "tbq-kuk",
}

m["var"] = {
	canonicalName = "Huarijio",
	otherNames = {"Guarijío", "Varihío", "Warihío"},
	scripts = {"Latn"},
	family = "azc-trc",
}

m["vas"] = {
	canonicalName = "Vasavi",
}

m["vau"] = {
	canonicalName = "Vanuma",
}

m["vav"] = {
	canonicalName = "Varli",
}

m["vay"] = {
	canonicalName = "Vayu",
}

m["vbb"] = {
	canonicalName = "Southeast Babar",
}

m["vbk"] = {
	canonicalName = "Southwestern Bontoc",
	otherNames = {"Southwestern Bontok"},
	scripts = {"Latn"},
}

m["vec"] = {
	canonicalName = "Venetian",
	scripts = {"Latn"},
	family = "roa",
}

m["ved"] = {
	canonicalName = "Veddah",
}

m["vem"] = {
	canonicalName = "Vemgo-Mabas",
}

m["veo"] = {
	canonicalName = "Ventureño",
	scripts = {"Latn"},
	family = "nai-chu",
}

m["vep"] = {
	canonicalName = "Veps",
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["ver"] = {
	canonicalName = "Mom Jango",
}

m["vgr"] = {
	canonicalName = "Vaghri",
}

m["vgt"] = {
	canonicalName = "Flemish Sign Language",
	family = "sgn",
}

m["vic"] = {
	canonicalName = "Virgin Islands Creole",
	scripts = {"Latn"},
}

m["vid"] = {
	canonicalName = "Vidunda",
}

m["vif"] = {
	canonicalName = "Vili",
}

m["vig"] = {
	canonicalName = "Viemo",
}

m["vil"] = {
	canonicalName = "Vilela",
}

m["vis"] = {
	canonicalName = "Vishavan",
	family = "dra",
}

m["vit"] = {
	canonicalName = "Viti",
}

m["viv"] = {
	canonicalName = "Iduna",
	family = "poz-ocw",
}

m["vka"] = {
	canonicalName = "Kariyarra",
	family = "aus-nga",
}

m["vki"] = {
	canonicalName = "Ija-Zuba",
}

m["vkj"] = {
	canonicalName = "Kujarge",
}

m["vkk"] = {
	canonicalName = "Kaur",
}

m["vkl"] = {
	canonicalName = "Kulisusu",
}

m["vkm"] = {
	canonicalName = "Kamakan",
	otherNames = {"Kamakã", "Ezeshio", "Kotoxó", "Kotoxo", "Mongoyó", "Mangaló"},
	scripts = {"Latn"},
	family = "sai-mje",
}

m["vko"] = {
	canonicalName = "Kodeoha",
}

m["vkp"] = {
	canonicalName = "Korlai Creole Portuguese",
	scripts = {"Latn"},
}

m["vkt"] = {
	canonicalName = "Tenggarong Kutai Malay",
}

m["vku"] = {
	canonicalName = "Kurrama",
	family = "aus-nga",
}

m["vlp"] = {
	canonicalName = "Valpei",
	family = "poz-vnc",
}

m["vls"] = {
	canonicalName = "West Flemish",
	scripts = {"Latn"},
	ancestors = {"dum"},
	family = "gmw",
}

m["vma"] = {
	canonicalName = "Martuthunira",
	scripts = {"Latn"},
	family = "aus-nga",
}

m["vmb"] = {
	canonicalName = "Mbabaram",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["vmc"] = {
	canonicalName = "Juxtlahuaca Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["vmd"] = {
	canonicalName = "Mudu Koraga",
	scripts = {"Knda"},
	family = "dra",
}

m["vme"] = {
	canonicalName = "East Masela",
}

m["vmg"] = {
	canonicalName = "Minigir",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["vmh"] = {
	canonicalName = "Maraghei",
	ancestors = {"ira-azr"},
}

m["vmi"] = {
	canonicalName = "Miwa",
}

m["vmj"] = {
	canonicalName = "Ixtayutla Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["vmk"] = {
	canonicalName = "Makhuwa-Shirima",
	scripts = {"Latn"},
	family = "bnt",
}

m["vml"] = {
	canonicalName = "Malgana",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["vmm"] = {
	canonicalName = "Mitlatongo Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["vmp"] = {
	canonicalName = "Soyaltepec Mazatec",
	scripts = {"Latn"},
}

m["vmq"] = {
	canonicalName = "Soyaltepec Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["vmr"] = {
	canonicalName = "Marenje",
}

m["vms"] = {
	canonicalName = "Moksela",
	family = "plf",
}

m["vmu"] = {
	canonicalName = "Muluridyi",
}

m["vmv"] = {
	canonicalName = "Valley Maidu",
	scripts = {"Latn"},
	family = "nai-mdu",
}

m["vmw"] = {
	canonicalName = "Makhuwa",
	scripts = {"Latn"},
	family = "bnt",
}

m["vmx"] = {
	canonicalName = "Tamazola Mixtec",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["vmy"] = {
	canonicalName = "Ayautla Mazatec",
	scripts = {"Latn"},
}

m["vmz"] = {
	canonicalName = "Mazatlán Mazatec",
	scripts = {"Latn"},
}

m["vnk"] = {
	canonicalName = "Lovono",
	family = "poz-oce",
}

m["vnm"] = {
	canonicalName = "Neve'ei",
	family = "poz-vnc",
}

m["vnp"] = {
	canonicalName = "Vunapu",
	family = "poz-vnc",
}

m["vor"] = {
	canonicalName = "Voro",
}

m["vot"] = {
	canonicalName = "Votic",
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["vra"] = {
	canonicalName = "Vera'a",
	scripts = {"Latn"},
}

m["vro"] = {
	canonicalName = "Võro",
	scripts = {"Latn"},
	family = "fiu-fin",
	wikimedia_codes = {"fiu-vro"},
}

m["vrs"] = {
	canonicalName = "Varisi",
	family = "poz-ocw",
}

m["vrt"] = {
	canonicalName = "Banam Bay",
	family = "poz-vnc",
}

m["vsi"] = {
	canonicalName = "Moldova Sign Language",
	family = "sgn",
}

m["vsl"] = {
	canonicalName = "Venezuelan Sign Language",
	family = "sgn",
}

m["vsv"] = {
	canonicalName = "Valencian Sign Language",
	family = "sgn",
}

m["vto"] = {
	canonicalName = "Vitou",
}

m["vum"] = {
	canonicalName = "Vumbu",
}

m["vun"] = {
	canonicalName = "Vunjo",
	otherNames = {"KiVunjo", "Wunjo", "Chaga", "KiVunjo Chaga", "Central Kilimanjaro", "Central Chaga"},
	scripts = {"Latn"},
	family = "bnt",
}

m["vut"] = {
	canonicalName = "Vute",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["vwa"] = {
	canonicalName = "Awa (China)",
	otherNames = {"Awa", "Ava", "Va"}, -- last two are confusingly also names of sibling dialect 'wbm'
}

return m