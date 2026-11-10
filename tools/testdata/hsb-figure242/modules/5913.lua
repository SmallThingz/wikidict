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

m["vaa"] = {
	"Vaagri Booli",
	7907798,
	"inc",
	"Taml",
}

m["vae"] = {
	"Vale",
	3450194,
	"csu-val",
}

m["vag"] = {
	"Vagla",
	36637,
	"nic-gnw",
}

m["vah"] = {
	"Varhadi",
	155645,
	"inc-sou",
	"Deva, Modi",
	ancestors = "omr",
	translit = {
		Deva = "mr-translit",
		Modi = "mr-Modi-translit",
	},
}

m["vai"] = {
	"Vai",
	36939,
	"dmn-vak",
	"Vaii",
	translit = "Vaii-translit",
}

m["vaj"] = {
	"Sekele",
	56528,
}

m["val"] = {
	"Vehes",
	7918407,
}

m["vam"] = {
	"Vanimo",
	3327415,
	"paa-msk",
}

m["van"] = {
	"Valman",
	7912479,
	"qfa-tor",
}

m["vao"] = {
	"Vao",
	2160405,
	"poz-vnc",
	"Latn",
}

m["vap"] = {
	"Vaiphei",
	56368,
	"tbq-kuk",
}

m["var"] = {
	"Huarijio",
	10974017,
	"azc-trc",
	"Latn",
}

m["vas"] = {
	"Vasavi",
	765418,
}

m["vau"] = {
	"Vanuma",
	7915259,
	"bnt-nya",
}

m["vav"] = {
	"Varli",
	7915983,
	"inc-sou",
	"Deva, Gujr",
}

m["vay"] = {
	"Vayu",
	7917585,
	"sit-kiw",
}

m["vbb"] = {
	"Southeast Babar",
	12952247,
	"poz-tim",
}

m["vbk"] = {
	"Southwestern Bontoc",
	63313677,
	"phi",
	"Latn",
}

m["vec"] = {
	"Venetan",
	32724,
	"roa",
	"Latn, Armn",
	translit = {Armn = "Armn-translit"},
}

m["ved"] = {
	"Veddah",
	2567934,
	"crp",
	"Sinh"
}

m["vem"] = {
	"Vemgo-Mabas",
	56268,
}

m["veo"] = {
	"Ventureño",
	56712,
	"nai-chu",
	"Latn",
}

m["vep"] = {
	"Veps",
	32747,
	"urj-fin",
	"Latn",
	sort_key = {
		from = {
			"č", "š", "ž", "ü", "ä", "ö", -- 2 chars
			"z", "'" -- 1 char
		},
		to = {
			"c" .. p[1], "s" .. p[1], "s" .. p[3], "y" .. p[1], "y" .. p[2], "y" .. p[3],
			"s" .. p[2], "y" .. p[4],
		}
	},
}

m["ver"] = {
	"Mom Jango",
	35862,
	"alv-dur",
}

m["vgr"] = {
	"Vaghri",
	7908480,
	"inc-bhi",
	"Gujr",
	translit = "gu-translit",
}

m["vgt"] = {
	"Flemish Sign Language",
	2107617,
	"sgn",
}

m["vic"] = {
	"Virgin Islands Creole",
	7933935,
	"crp",
	"Latn",
	ancestors = "en",
}

m["vid"] = {
	"Vidunda",
	7928151,
	"bnt-ruv",
}

m["vif"] = {
	"Vili",
	3558409,
	"bnt-kng",
	"Latn",
}

m["vig"] = {
	"Viemo",
	36912,
	"alv-sav",
}

m["vil"] = {
	"Vilela",
	3409297,
}

m["vis"] = {
	"Vishavan",
	14916908,
	"dra-mal",
}

m["vit"] = {
	"Viti",
	11011055,
	"nic-grf",
}

m["viv"] = {
	"Iduna",
	5989839,
	"poz-ocw",
}

m["vjk"] = {
	"Bajjika",
	3636001,
	"inc-bih",
	"Deva, Kthi",
}

m["vka"] = {
	"Kariyarra",
	13586632,
	"aus-nga",
	"Latn",
}

m["vki"] = {
	"Ija-Zuba",
	11011389,
	"nic-pls",
	ancestors = "uji",
}

m["vkj"] = {
	"Kujarge",
	33448,
}

m["vkk"] = {
	"Kaur",
	6378867,
}

m["vkl"] = {
	"Kulisusu",
	3200326,
	"poz-btk",
}

m["vkm"] = {
	"Kamakan",
	3192316,
	"sai-mje",
	"Latn",
}

m["vko"] = {
	"Kodeoha",
	3198209,
}

m["vkp"] = {
	"Korlai Creole Portuguese",
	3915520,
	"crp",
 	"Latn",
	ancestors = "idb",
}

m["vkt"] = {
	"Tenggarong Kutai Malay",
	12683226,
}

m["vku"] = {
	"Kurrama",
	3915684,
	"aus-nga",
	"Latn",
}

m["vlp"] = {
	"Valpei",
	7912582,
	"poz-vnn",
	"Latn",
}

m["vls"] = {
	"West Flemish",
	100103,
	"gmw-frk",
	"Latn",
	ancestors = "dum",
}

m["vma"] = {
	"Martuthunira",
	975399,
	"aus-nga",
	"Latn",
}

m["vmb"] = {
	"Mbabaram",
	3303475,
	"aus-pam",
	"Latn",
}

m["vmc"] = {
	"Juxtlahuaca Mixtec",
	25559582,
	"omq-mxt",
	"Latn",
}

m["vmd"] = {
	"Mudu Koraga",
	12952656,
	"dra-kor",
	"Knda",
}

m["vme"] = {
	"East Masela",
	18487451,
	"poz-tim",
}

m["vmf"] = {
	"East Franconian",
	497345,
	"gmw-hgm",
	"Latn",
	ancestors = "gmh",
	sort_key = "vmf-sortkey",
}

m["vmg"] = {
	"Minigir",
	17053237,
	"poz-ocw",
	"Latn",
}

m["vmh"] = {
	"Maraghei",
	36220,
	"xme-ttc",
	ancestors = "xme-ttc-eas",
}

m["vmi"] = {
	"Miwa",
	10586712,
	"aus-wor",
}

m["vmj"] = {
	"Ixtayutla Mixtec",
	6101163,
	"omq-mxt",
	"Latn",
}

m["vmk"] = {
	"Makhuwa-Shirima",
	2963909,
	"bnt-mak",
	"Latn",
	ancestors = "vmw",
}

m["vml"] = {
	"Malgana",
	6743201,
	"aus-psw",
	"Latn",
}

m["vmm"] = {
	"Mitlatongo Mixtec",
	6881813,
	"omq-mxt",
	"Latn",
}

m["vmp"] = {
	"Soyaltepec Mazatec",
	7572000,
	nil,
	"Latn",
}

m["vmq"] = {
	"Soyaltepec Mixtec",
	7572001,
	"omq-mxt",
	"Latn",
}

m["vmr"] = {
	"Marenje",
	11128833,
	ancestors = "vmw",
	"bnt-mak",
}

-- vms "Moskela" is extinct and unattested; see Wikipedia

m["vmu"] = {
	"Muluridyi",
	10590149,
}

m["vmv"] = {
	"Valley Maidu",
	5096458,
	"nai-mdu",
	"Latn",
}

m["vmw"] = {
	"Makhuwa",
	33882,
	"bnt-mak",
	"Latn",
}

m["vmx"] = {
	"Tamazola Mixtec",
	12953734,
	"omq-mxt",
	"Latn",
}

m["vmy"] = {
	"Ayautla Mazatec",
	14916912,
	nil,
	"Latn",
}

m["vmz"] = {
	"Mazatlán Mazatec",
	12953706,
	"omq-maz",
	"Latn",
}

m["vnk"] = {
	"Lovono",
	3211090,
	"poz-tem",
	"Latn",
}

m["vnm"] = {
	"Neve'ei",
	2157431,
	"poz-vnc",
	"Latn",
}

m["vnp"] = {
	"Vunapu",
	7943647,
	"poz-vnn",
	"Latn",
}

m["vor"] = {
	"Voro",
	3914407,
	"alv-yun",
}

m["vot"] = {
	"Votic",
	32858,
	"urj-fin",
	"Latn",
	entry_name = {
		from = {"'"},
		to = {"ʹ"}
	},
	sort_key = {
		from = {
			"tš",
			"š", "ž", "õ", "ä", "ö", "ü",
			"z",
			"ʹ"
		},
		to = {
			"t" .. p[1],
			"s" .. p[1], "s" .. p[3], "w" .. p[1], "w" .. p[2], "w" .. p[3], "w" .. p[4],
			"s" .. p[2],
			""
		}
	},
	standardChars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšZzŽžTtUuVvÕõÄäÖöÜüʹ" .. c.punc,
}

m["vra"] = {
	"Vera'a",
	3555689,
	"poz-vnn",
	"Latn",
}

m["vro"] = {
	"Võro",
	32762,
	"urj-fin",
	"Latn",
	wikimedia_codes = "fiu-vro",
}

m["vrs"] = {
	"Varisi",
	3554807,
	"poz-ocw",
}

m["vrt"] = {
	"Burmbar",
	2928522,
	"poz-vnc",
	"Latn",
}

m["vsi"] = {
	"Moldova Sign Language",
	12953478,
	"sgn",
}

m["vsl"] = {
	"Venezuelan Sign Language",
	3322064,
	"sgn",
}

m["vsv"] = {
	"Valencian Sign Language",
	32663,
	"sgn",
}

m["vto"] = {
	"Vitou",
	7937210,
	"paa-tkw",
}

m["vum"] = {
	"Vumbu",
	36629,
	"bnt-sir",
}

m["vun"] = {
	"Vunjo",
	12953261,
	"bnt-chg",
	"Latn",
}

m["vut"] = {
	"Vute",
	36897,
	"nic-mmb",
	"Latn",
}

m["vwa"] = {
	"Awa (China)",
	2874642,
	"mkh-pal",
}

return require("Module:languages").finalizeData(m, "language")