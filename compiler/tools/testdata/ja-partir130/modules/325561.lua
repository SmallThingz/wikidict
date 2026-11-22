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
	"クアポー語",
	"Q3412974",
	"sio-dhe",
	otherNames = {"Arkansas"},
	scripts = Latn,
}

m["quc"] = {
	"キチェ語",
	"Q36494",
	"myn",
	scripts = Latn,
}

m["qui"] = {
	"キリュート語",
	"Q3414490",
	"chi",
	scripts = Latn,
}

m["qum"] = {
	"シパカペンセ語",
	"Q36589",
	"myn",
	otherNames = {"Sipacapa", "Sipakapa", "Sipacapense"},
	scripts = Latn,
}

m["qun"] = {
	"キノールト語",
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
	"サカプルテク語",
	"Q36412",
	"myn",
	otherNames = {"Sacapultec", "Sacapultek", "Sakapulteko"},
	scripts = Latn,
}

m["qvy"] = {
	"チュユ語",
	"Q3414352",
	"sit-qia",
}

m["qwc"] = {
	"古典ケチュア語",
	"Q35882",
	"qwe",
	scripts = Latn,
}

m["qwm"] = {
	"クマン語 (チュルク)",
	"Q1199226",
	"trk-kip",
	otherNames = {"Kypchak", "Qypchaq", "Armeno-Kipchak", "Armeno-Qypchaq", "Mamluk-Kipchak", "Cuman", "Kuman", "Polovets"},
	scripts = {"Latn", "Armn", "Arab"},
	translit_module = "translit-redirect",
}

m["qwt"] = {
	"クワリオオクア＝トラッカナイ語",
	"Q20641",
	"ath-nor",
	otherNames = {"Kwalhioqua-Clatskanie"},
	scripts = Latn,
}

m["qxs"] = {
	"南部チャン語",
	"Q56563",
	"sit-qia",
	scripts = Latn,
}

m["qya"] = {
	"クウェンヤ",
	"Q56383",
	"art",
	type = "appendix-constructed",
	scripts = {"Latn", "Teng"},
}

m["qyp"] = {
	"クィリピ語",
	"Q3414714",
	"alg-eas",
	otherNames = {"Unquachog", "Unkechaug", "Quiripi-Unquachog", "Naugatuck", "Wampano", "Quinnipiac"},
	scripts = Latn,
}

return m