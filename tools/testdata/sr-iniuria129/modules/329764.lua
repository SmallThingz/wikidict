local m_lang = require("Module:languages")
local m_langdata = require("Module:languages/data")

local u = require("Module:string utilities").char

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

local m = {}

m["qua"] = {
	"Quapaw",
	3412974,
	"sio-dhe",
	"Latn",
}

m["quc"] = {
	"K'iche'",
	36494,
	"myn",
	"Latn",
}

m["qui"] = {
	"Quileute",
	3414490,
	"chi",
	"Latn",
}

m["qum"] = {
	"Sipakapense",
	36589,
	"myn",
	"Latn",
}

m["qun"] = {
	"Quinault",
	3414522,
	"sal",
	"Latn",
}

m["quq"] = { -- should this continue to be considered separate language?
	"Quinqui",
	5908714,
	nil,
	"Latn",
}

m["quv"] = {
	"Sacapulteco",
	36412,
	"myn",
	"Latn",
}

m["qvy"] = {
	"Queyu",
	3414352,
	"sit-qia",
}

m["qwc"] = {
	"Classical Quechua",
	35882,
	"qwe",
	"Latn",
}

m["qwm"] = {
	"Kipchak",
	1199226,
	"trk-kip",
	"Latn, Armn, Arab",
	translit = {Armn = "Armn-translit"},
}

m["qwt"] = {
	"Kwalhioqua-Tlatskanai",
	20641,
	"ath-nor",
	"Latn",
}

m["qxs"] = {
	"Southern Qiang",
	56563,
	"sit-qia",
	"Latn",
}

m["qya"] = {
	"Quenya",
	56383,
	"art",
	"Latn, Teng",
	type = "appendix-constructed",
}

m["qyp"] = {
	"Quiripi",
	3414714,
	"alg-eas",
	"Latn",
}

return m_lang.finalizeLanguageData(m_lang.addDefaultTypes(m, true))