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

local Latn = {"Latn"}

local m = {}

m["vaa"] = {
	"Vaagri Booli",
	"Q7907798",
}

m["vae"] = {
	"Vale",
	"Q3450194",
	"csu-val",
}

m["vag"] = {
	"Vagla",
	"Q36637",
	"nic-gnw",
}

m["vah"] = {
	"Varhadi-Nagpuri",
	"Q155645",
	"inc",
	ancestors = {"mr"},
}

m["vai"] = {
	"Vai",
	"Q36939",
	"dmn-vak",
	otherNames = {"Gallinas", "Vy"},
	scripts = {"Vaii"},
	translit_module = "Vaii-translit",
}

m["vaj"] = {
	"Sekele",
	"Q56528",
	otherNames = {"Sekela", "Vasekele", "Vasekela", "Vasekela Bushman", "ǃ'OǃKung"},
}

m["val"] = {
	"Vehes",
	"Q7918407",
}

m["vam"] = {
	"Vanimo",
	"Q3327415",
}

m["van"] = {
	"Valman",
	"Q7912479",
	"qfa-tor",
}

m["vao"] = {
	"Vao",
	"Q2160405",
	"poz-vnc",
}

m["vap"] = {
	"Vaiphei",
	"Q56368",
	"tbq-kuk",
}

m["var"] = {
	"Huarijio",
	"Q10974017",
	"azc-trc",
	otherNames = {"Guarijío", "Varihío", "Warihío"},
	scripts = Latn,
}

m["vas"] = {
	"Vasavi",
	"Q765418",
}

m["vau"] = {
	"Vanuma",
	"Q7915259",
	"bnt-nya",
}

m["vav"] = {
	"Varli",
	"Q7915983",
	"inc",
	otherNames = {"Warli"},
	scripts = {"Deva", "Gujr"},
}

m["vay"] = {
	"Vayu",
	"Q7917585",
	"sit-kiw",
}

m["vbb"] = {
	"Southeast Babar",
	"Q12952247",
	"poz-tim",
}

m["vbk"] = {
	"Southwestern Bontoc",
	nil,
	"phi",
	otherNames = {"Southwestern Bontok"},
	scripts = Latn,
}

m["vec"] = {
	"Venetian",
	"Q32724",
	"roa",
	scripts = Latn,
}

m["ved"] = {
	"Veddah",
	"Q2567934",
}

m["vem"] = {
	"Vemgo-Mabas",
	"Q56268",
}

m["veo"] = {
	"Ventureño",
	"Q56712",
	"nai-chu",
	scripts = Latn,
}

m["vep"] = {
	"Вепски",
	"Q32747",
	"fiu-fin",
	scripts = Latn,
}

m["ver"] = {
	"Mom Jango",
	"Q35862",
	"alv-dur",
}

m["vgr"] = {
	"Vaghri",
	"Q7908480",
	"inc-bhi",
	scripts = {"Gujr"},
	translit_module = "gu-translit",
}

m["vgt"] = {
	"Flemish Sign Language",
	"Q2107617",
	"sgn",
}

m["vic"] = {
	"Virgin Islands Creole",
	"Q7933935",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["vid"] = {
	"Vidunda",
	"Q7928151",
	"bnt-ruv",
}

m["vif"] = {
	"Vili",
	"Q3558409",
	"bnt-kng",
}

m["vig"] = {
	"Viemo",
	"Q36912",
	"alv-sav",
}

m["vil"] = {
	"Vilela",
	"Q3409297",
}

m["vis"] = {
	"Vishavan",
	"Q14916908",
	"dra",
}

m["vit"] = {
	"Viti",
	"Q11011055",
	"nic-grf",
}

m["viv"] = {
	"Iduna",
	"Q5989839",
	"poz-ocw",
}

m["vka"] = {
	"Kariyarra",
	"Q13586632",
	"aus-nga",
	scripts = Latn,
}

m["vki"] = {
	"Ija-Zuba",
	"Q11011389",
	"nic-pls",
	ancestors = {"uji"},
}

m["vkj"] = {
	"Kujarge",
	"Q33448",
}

m["vkk"] = {
	"Kaur",
	"Q6378867",
}

m["vkl"] = {
	"Kulisusu",
	"Q3200326",
	"poz-btk",
}

m["vkm"] = {
	"Kamakan",
	"Q3192316",
	"sai-mje",
	otherNames = {"Kamakã", "Ezeshio", "Kotoxó", "Kotoxo", "Mongoyó", "Mangaló"},
	scripts = Latn,
}

m["vko"] = {
	"Kodeoha",
	"Q3198209",
}

m["vkp"] = {
	"Korlai Creole Portuguese",
	"Q3915520",
	"crp",
 	scripts = Latn,
	ancestors = {"idb"},
}

m["vkt"] = {
	"Tenggarong Kutai Malay",
	"Q12683226",
}

m["vku"] = {
	"Kurrama",
	"Q3915684",
	"aus-nga",
	scripts = Latn,
}

m["vlp"] = {
	"Valpei",
	"Q7912582",
	"poz-vnc",
}

m["vls"] = {
	"West Flemish",
	"Q100103",
	"gmw",
	scripts = Latn,
	ancestors = {"dum"},
}

m["vma"] = {
	"Martuthunira",
	"Q975399",
	"aus-nga",
	scripts = Latn,
}

m["vmb"] = {
	"Mbabaram",
	"Q3303475",
	"aus-pam",
	scripts = Latn,
}

m["vmc"] = {
	"Juxtlahuaca Mixtec",
	"Q25559582",
	"omq-mix",
	scripts = Latn,
}

m["vmd"] = {
	"Mudu Koraga",
	"Q12952656",
	"dra",
	scripts = {"Knda"},
}

m["vme"] = {
	"East Masela",
	"Q18487451",
	"poz-tim",
}

m["vmf"] = {
	"East Franconian",
	"Q497345",
	"gmw",
	otherNames = {"Ansbachisch", "Eastern Franconian", "Hohenlohisch", "Main Franconian", "Mainfränkisch", "Nürnbergisch", "Oberfränkisch", "Upper Franconian", "Vogtländisch"},
	scripts = Latn,
	ancestors = {"gmh"},
	sort_key = {
		from = {"[äàáâå]", "[ëèéê]", "[ïìíî]", "[öòóô]", "[üùúû]", "ß" },
		to   = {"a"	  , "e"	 , "i"	 , "o"	 , "u"	 , "ss"}} ,
}

m["vmg"] = {
	"Minigir",
	"Q17053237",
	"poz-ocw",
	otherNames = {"Lungalunga"},
	scripts = Latn,
}

m["vmh"] = {
	"Maraghei",
	"Q36220",
	"xme-ttc",
	ancestors = {"xme-ttc-eas"},
}

m["vmi"] = {
	"Miwa",
	"Q10586712",
	"aus-wor",
}

m["vmj"] = {
	"Ixtayutla Mixtec",
	"Q6101163",
	"omq-mix",
	scripts = Latn,
}

m["vmk"] = {
	"Makhuwa-Shirima",
	"Q2963909",
	"bnt-mak",
	ancestors = {"vmw"},
	scripts = Latn,
}

m["vml"] = {
	"Malgana",
	"Q6743201",
	"aus-psw",
	scripts = Latn,
}

m["vmm"] = {
	"Mitlatongo Mixtec",
	"Q6881813",
	"omq-mix",
	scripts = Latn,
}

m["vmp"] = {
	"Soyaltepec Mazatec",
	"Q7572000",
	scripts = Latn,
}

m["vmq"] = {
	"Soyaltepec Mixtec",
	"Q7572001",
	"omq-mix",
	scripts = Latn,
}

m["vmr"] = {
	"Marenje",
	"Q11128833",
	ancestors = {"vmw"},
	"bnt-mak",
}

-- vms "Moskela" is extinct and unattested; see Wikipedia

m["vmu"] = {
	"Muluridyi",
	"Q10590149",
}

m["vmv"] = {
	"Valley Maidu",
	"Q5096458",
	"nai-mdu",
	scripts = Latn,
}

m["vmw"] = {
	"Makhuwa",
	"Q33882",
	"bnt-mak",
	scripts = Latn,
}

m["vmx"] = {
	"Tamazola Mixtec",
	"Q12953734",
	"omq-mix",
	scripts = Latn,
}

m["vmy"] = {
	"Ayautla Mazatec",
	"Q14916912",
	scripts = Latn,
}

m["vmz"] = {
	"Mazatlán Mazatec",
	"Q12953706",
	"omq-maz",
	scripts = Latn,
}

m["vnk"] = {
	"Lovono",
	"Q3211090",
	"poz-oce",
}

m["vnm"] = {
	"Neve'ei",
	"Q2157431",
	"poz-vnc",
}

m["vnp"] = {
	"Vunapu",
	"Q7943647",
	"poz-vnc",
}

m["vor"] = {
	"Voro",
	"Q3914407",
	"alv-yun",
}

m["vot"] = {
	"Votic",
	"Q32858",
	"fiu-fin",
	scripts = Latn,
}

m["vra"] = {
	"Vera'a",
	"Q3555689",
	scripts = Latn,
}

m["vro"] = {
	"Võro",
	"Q32762",
	"fiu-fin",
	scripts = Latn,
	wikimedia_codes = {"fiu-vro"},
}

m["vrs"] = {
	"Varisi",
	"Q3554807",
	"poz-ocw",
}

m["vrt"] = {
	"Banam Bay",
	"Q2928522",
	"poz-vnc",
}

m["vsi"] = {
	"Moldova Sign Language",
	"Q12953478",
	"sgn",
}

m["vsl"] = {
	"Venezuelan Sign Language",
	"Q3322064",
	"sgn",
}

m["vsv"] = {
	"Valencian Sign Language",
	"Q32663",
	"sgn",
}

m["vto"] = {
	"Vitou",
	"Q7937210",
	"paa-tkw",
}

m["vum"] = {
	"Vumbu",
	"Q36629",
	"bnt-sir",
}

m["vun"] = {
	"Vunjo",
	"Q12953261",
	"bnt-chg",
	otherNames = {"KiVunjo", "Wunjo", "Chaga", "KiVunjo Chaga", "Central Kilimanjaro", "Central Chaga"},
	scripts = Latn,
}

m["vut"] = {
	"Vute",
	"Q36897",
	"nic-mmb",
	scripts = Latn,
}

m["vwa"] = {
	"Awa (China)",
	"Q2874642",
	"mkh-pal",
	otherNames = {"Awa", "Ava", "Va"}, -- last two are confusingly also names of sibling dialect 'wbm'
}

return m