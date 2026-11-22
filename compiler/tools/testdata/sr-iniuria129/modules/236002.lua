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

m["qua"] = {
	"Quapaw",
	"Q3412974",
	"sio",
	otherNames = {"Arkansas"},
	scripts = Latn,
}

m["quc"] = {
	"K'iche'",
	"Q36494",
	"myn",
	scripts = Latn,
}

m["qui"] = {
	"Quileute",
	"Q3414490",
	"chi",
	scripts = Latn,
}

m["qum"] = {
	"Sipakapense",
	"Q36589",
	"myn",
	otherNames = {"Sipacapa", "Sipakapa", "Sipacapense"},
	scripts = Latn,
}

m["qun"] = {
	"Quinault",
	"Q3414522",
	"sal",
	scripts = Latn,
}

m["quq"] = { -- should this continue to be considered separate language?
	"Quinqui",
	"Q5908714",
	scripts = Latn,
}

m["quv"] = {
	"Sacapulteco",
	"Q36412",
	"myn",
	otherNames = {"Sacapultec", "Sacapultek", "Sakapulteko"},
	scripts = Latn,
}

m["qvy"] = {
	"Queyu",
	"Q3414352",
	"sit-qia",
}

m["qwc"] = {
	"Classical Quechua",
	"Q35882",
	"qwe",
	scripts = Latn,
}

m["qwm"] = {
	"Kipchak",
	"Q1075050",
	"trk-kip",
	otherNames = {"Kypchak", "Qypchaq", "Armeno-Kipchak", "Armeno-Qypchaq", "Mamluk-Kipchak", "Cuman", "Kuman", "Polovets"},
	scripts = {"Latn", "Armn", "Arab"},
	translit_module = "translit-redirect",
}

m["qwt"] = {
	"Kwalhioqua-Tlatskanai",
	"Q20641",
	"ath-nor",
	otherNames = {"Kwalhioqua-Clatskanie"},
	scripts = Latn,
}

m["qxs"] = {
	"Southern Qiang",
	"Q56563",
	"tbq",
	scripts = Latn,
}

m["qya"] = {
	"Quenya",
	"Q56383",
	"art",
	type = "appendix-constructed",
	scripts = {"Latn", "Teng"},
}

m["qyp"] = {
	"Quiripi",
	"Q3414714",
	"alg",
	otherNames = {"Unquachog", "Unkechaug", "Quiripi-Unquachog", "Naugatuck", "Wampano", "Quinnipiac"},
	scripts = Latn,
}

return m