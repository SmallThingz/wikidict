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

m["faa"] = {
	"法蘇語",
	3446687,
	"qfa-dis", -- Papuan; isolate or in the proposed Kutubuan family
	"Latn",
}

m["fab"] = {
	"安諾本語",
	34992,
	"crp",
	"Latn",
	ancestors = "pt",
}

m["fad"] = {
	"瓦吉語",
	7959569,
	"ngf-han",
	"Latn",
}

m["faf"] = {
	"Fagani",
	3063759,
	"poz-sls",
	"Latn",
}

m["fag"] = {
	"菲農甘語",
	3450761,
	"ngf-era",
	"Latn",
}

m["fah"] = {
	"Baissa Fali",
	3446632,
	"nic-bco",
	"Latn",
}

m["fai"] = {
	"Faiwol",
	3501773,
	"ngf-mok",
	"Latn",
}

m["faj"] = {
	"Faita",
	976953,
	"ngf-eso",
	"Latn",
}

m["fak"] = {
	"Fang (Beboid)",
	5433811,
	"nic-beb",
	"Latn",
}

m["fal"] = {
	"South Fali",
	15637351,
	"alv-fli",
	"Latn",
}

m["fam"] = {
	"Fam",
	35290,
	"nic-mmb",
	"Latn",
}

m["fan"] = {
	"芳語",
	33484,
	"bnt-btb",
	"Latn",
}

m["fap"] = {
	"Palor",
	36318,
	"alv-cng",
	"Latn",
}

m["far"] = {
	"Fataleka",
	3067168,
	"poz-sls",
	"Latn",
}

-- "fat" is treated as "ak", see [[WT:LT]]

m["fau"] = {
	"法尤語",
	5439113,
	"paa-wlp",
	"Latn",
}

m["fax"] = {
	"法拉語",
	300402,
	"roa-gap",
	"Latn",
}

m["fay"] = {
	"西南法爾斯語",
	5228140,
	"ira-swi",
	"Arab",
}

m["faz"] = {
	"西北法爾斯語",
	7060307,
	"ira-swi",
}

m["fbl"] = {
	"西阿爾拜比科爾語",
	18603801,
	"phi",
	"Latn",
}

m["fcs"] = {
	"魁北克手語",
	13193,
	"sgn",
	"Latn", -- when documented
}

m["fer"] = {
	"Feroge",
	35287,
	"nic-ser",
	"Latn",
}

m["ffi"] = {
	"Foia Foia",
	8564176,
	"paa-wig",
	"Latn",
}

-- "ffm" is treated as "ff", see [[WT:LT]]

m["fgr"] = {
	"Fongoro",
	3437645,
	"csu",
	"Latn",
}

m["fia"] = {
	"努比因語",
	36503,
	"nub",
	"Latn, Arab, Copt",
	ancestors = "onw",
	translit = {
		Copt = "Copt-translit",
	},
	sort_key = {
		Copt = "Copt-sortkey",
	},
}

m["fie"] = {
	"Fyer",
	56273,
	"cdc-wst",
	"Latn",
}

m["fif"] = {
	"Faifi",
	85760309,
	"sem-cen", -- conservatively putting undifferentiated sem-cen, there's debate over if it's OSA or Arabic
	"Arab", -- or IPA/Latn; mostly it is unwritten
--	ancestors = "sem-srb", if one accepts the view that like Razihi it is sem-osa
}

-- "fil" is treated as "tl", see [[WT:LT]]

m["fip"] = {
	"菲帕語",
	667747,
	"bnt-mwi",
	"Latn",
}

m["fir"] = {
	"Firan",
	3915847,
	"nic-plc",
	"Latn",
}

m["fit"] = {
	"梅安語",
	13357,
	"urj-fin",
	"Latn",
	ancestors = "fi",
}

m["fiw"] = {
	"Fiwaga",
	5456292,
	"ngf-eku",
	"Latn",
}

m["fkk"] = {
	"基里亞-孔澤爾語",
	6416310,
	"cdc-cbm",
	"Latn",
}

m["fkv"] = {
	"克文語",
	165795,
	"urj-fin",
	"Latn",
	ancestors = "fi",
}

m["fla"] = {
	"蒙大拿薩利希語",
	3111983,
	"sal",
	"Latn",
}

m["flh"] = {
	"福奧語",
	5463819,
	"paa-elp",
	"Latn",
}

m["fli"] = {
	"Fali",
	56244,
	"cdc-cbm",
	"Latn",
}

m["fll"] = {
	"North Fali",
	12952419,
	"alv-fli",
	"Latn",
}

m["fln"] = {
	"費蓮達島語",
	3915702,
	"aus-pmn",
	"Latn",
}

m["flr"] = {
	"富利盧語",
	7166821,
	"bnt-shh",
	"Latn",
}

m["fly"] = {
	"Tsotsitaal",
	12643960,
	"crp",
	"Latn",
	ancestors = "af",
}

m["fmp"] = {
	"費費語",
	35276,
	"bai",
	"Latn",
}

m["fmu"] = {
	"遠西穆里亞語",
	42589412,
	"dra-mur",
	"Deva",
}

m["fng"] = {
	"凡那伽羅語",
	35727,
	"crp",
	"Latn",
	ancestors = "zu",
}

m["fni"] = {
	"凡雅語",
	317642,
	"alv-bua",
	"Latn",
}

m["fod"] = {
	"富多語",
	5465566,
	"alv-gng",
	"Latn",
}

m["foi"] = {
	"福伊語",
	5464146,
	"ngf-eku",
	"Latn",
}

m["fom"] = {
	"Foma",
	5464911,
	"bnt-ske",
	"Latn",
	ancestors = "khy",
}

m["fon"] = {
	"豐語",
	33291,
	"alv-gbe",
	"Latn",
}

m["for"] = {
	"法雷語",
	3077126,
	"ngf-fgi",
	"Latn",
}

m["fos"] = {
	"西拉雅語",
	716604,
	"map",
	"Latn",
}

m["fpe"] = {
	"皮欽利斯語",
	35288,
	"crp",
	"Latn",
	ancestors = "en",
}

m["fqs"] = {
	"法斯語",
	56320,
	"paa-fas",
	"Latn",
}

-- "frc" is treated as "fr" (or as etymology-only), see [[WT:LT]]

m["frd"] = {
	"福爾達塔語",
	5468035,
	"poz-cet",
	"Latn",
}

m["frm"] = {
	"中古法語",
	1473289,
	"roa-oil",
	"Latn",
	sort_key = s["roa-oil-sortkey"],
}

m["fro"] = {
	"古法語",
	35222,
	"roa-oil",
	"Latn, Hebr",
	sort_key = {
		Latn = s["roa-oil-sortkey"],
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["frp"] = {
	"法蘭克-普羅旺斯語",
	15087,
	"roa-grh",
	"Latn",
	ancestors = "frp-old",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.cedilla .. "'",
		from = {"æ", "œ"},
		to = {"ae", "oe"}
	},
}

m["frq"] = {
	"Forak",
	5467173,
	"ngf-war",
	"Latn",
}

m["frr"] = {
	"北弗里斯蘭語",
	28224,
	"gmw-fri",
	"Latn",
}

-- "frs" is not used, see [[WT:LT]]

m["frt"] = {
	"福澤納爾語",
	2666835,
	"poz-vnn",
	"Latn",
}

m["fse"] = {
	"芬蘭手語",
	33225,
	"sgn",
	"Latn", -- when documented
}

m["fsl"] = {
	"法國手語",
	33302,
	"sgn-fsl",
	"Latn", -- when documented
}

m["fss"] = {
	"芬蘭-瑞典手語",
	5450448,
	"sgn",
	"Latn", -- when documented
}

-- "fub" is treated as "ff", see [[WT:LT]]

-- "fuc" is treated as "ff", see [[WT:LT]]

m["fud"] = {
	"富圖納語",
	35334,
	"poz-pnp",
	"Latn",
}

-- "fue" is treated as "ff", see [[WT:LT]]

-- "fuf" is treated as "ff", see [[WT:LT]]

-- "fuh" is treated as "ff", see [[WT:LT]]

-- "fui" is treated as "ff", see [[WT:LT]]

m["fuj"] = {
	"科語",
	35693,
	"alv-hei",
	"Latn",
}

m["fum"] = {
	"Fum",
	11011870,
	"nic-nka",
	"Latn",
}

m["fun"] = {
	"福尼歐語",
	774441,
	"qfa-iso",
	"Latn",
}

-- "fuq" is treated as "ff", see [[WT:LT]]

m["fur"] = {
	"弗留利語",
	33441,
	"roa-rhe",
	ancestors = "fur-old",
	"Latn",
}

m["fut"] = {
	"富圖納-阿尼瓦語",
	3064409,
	"poz-pnp",
	"Latn",
}

m["fuu"] = {
	"富魯語",
	3441160,
	"csu-bkr",
	"Latn",
}

-- "fuv" is treated as "ff", see [[WT:LT]]

m["fuy"] = {
	"富尤格語",
	3073472,
	"qfa-dis", -- Papuan; isolate per Glottolog and Usher (2020), only tentatively retained in putative Goilalan family
			   -- within TNG by Ross (2005)
	"Latn",
}

m["fvr"] = {
	"富爾語",
	33364,
	"ssa-fur",
	"Latn",
}

m["fwa"] = {
	"Fwâi",
	3091331,
	"poz-cln",
	"Latn",
}

m["fwe"] = {
	"Fwe",
	5511159,
	"bnt-bot",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")