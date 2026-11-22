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

m["qua"] = {
	"tiếng Quapaw",
	3412974,
	"sio-dhe",
	"Latn",
	"Tiếng Quapaw",
	"Quapaw",
}

m["quc"] = {
	"tiếng K'iche'",
	36494,
	"myn",
	"Latn",
	"Tiếng K'iche'",
	"K'iche'",
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
	"tiếng Quinault",
	3414522,
	"sal",
	"Latn",
	"Tiếng Quinault",
	"Quinault",
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
	"tiếng Cuman",
	1199226,
	"trk-kip",
	"Latn, Armn, Arab",
	"Tiếng Cuman",
	"Cuman",
	translit = {Armn = "Armn-translit"},
}

m["qwt"] = {
	"Kwalhioqua-Tlatskanai",
	20641,
	"ath-nor",
	"Latn",
}

m["qxq"] = {
	"tiếng Qashqai",
	13192,
	"trk-ogz",
	"Latn, Arab",
	"Tiếng Qashqai",
	"Qashqai",
}

m["qxs"] = {
	"tiếng Khương Nam",
	56563,
	"sit-qia",
	"Latn",
	"Tiếng Khương Nam",
	"Khương Nam",
}

m["qya"] = {
	"tiếng Quenya",
	56383,
	"art",
	"Latn, Teng",
	"Tiếng Quenya",
	"Quenya",
	type = "appendix-constructed",
}

m["qyp"] = {
	"tiếng Quiripi",
	3414714,
	"alg-eas",
	"Latn",
	"Tiếng Quiripi",
	"Quiripi",
}

return require("Module:languages").finalizeData(m, "language")