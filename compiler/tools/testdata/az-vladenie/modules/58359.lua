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

m["qot"] = {
	canonicalName = "Sahaptin",
	otherNames = {"Shahaptin"},
	scripts = {"Latn"},
	family = "nai-shp",
}

m["qua"] = {
	canonicalName = "Quapaw",
	otherNames = {"Arkansas"},
	family = "sio",
}

m["quc"] = {
	canonicalName = "K'iche'",
	scripts = {"Latn"},
	family = "myn",
}

m["qui"] = {
	canonicalName = "Quileute",
	family = "chi",
}

m["qum"] = {
	canonicalName = "Sipacapense",
	family = "myn",
}

m["qun"] = {
	canonicalName = "Quinault",
	family = "sal",
}

m["quq"] = {
	canonicalName = "Quinqui",
}

m["quv"] = {
	canonicalName = "Sacapulteco",
	family = "myn",
}

m["qvy"] = {
	canonicalName = "Queyu",
	family = "sit",
}

m["qwc"] = {
	canonicalName = "Classical Quechua",
	scripts = {"Latn"},
	family = "qwe",
}

m["qwm"] = {
	canonicalName = "Kipchak",
	otherNames = {"Kypchak", "Qypchaq", "Armeno-Kipchak", "Armeno-Qypchaq", "Mamluk-Kipchak", "Cuman", "Kuman", "Polovets"},
	scripts = {"Latn", "Armn", "Arab"},
	family = "trk-kip",
	translit_module = "qwm-translit",
}

m["qwt"] = {
	canonicalName = "Kwalhioqua-Tlatskanai",
	family = "ath",
}

m["qxs"] = {
	canonicalName = "Southern Qiang",
	scripts = {"Latn"},
	family = "tbq",
}

m["qya"] = {
	canonicalName = "Quenya",
	type = "appendix-constructed",
	scripts = {"Latn", "Teng"},
	family = "art",
}

m["qyp"] = {
	canonicalName = "Quiripi",
	otherNames = {"Unquachog", "Unkechaug", "Quiripi-Unquachog", "Naugatuck", "Wampano", "Quinnipiac"},
	scripts = {"Latn"},
	family = "alg",
}

return m