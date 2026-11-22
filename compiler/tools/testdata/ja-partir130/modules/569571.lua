local export = {}

-- We can't use mw.loadData() on [[モジュール:languages/chars]] because [[モジュール:languages/data]] itself is sometimes loaded
-- using mw.loadData(), and calling mw.loadData() on [[モジュール:languages/chars]] will insert metatables into the
-- character tables, which the second mw.loadData() will choke on.
local m_chars = require("モジュール:languages/chars")

local u = require("モジュール:string/char")
local c = m_chars.chars
export.chars = c
local p = m_chars.puaChars
export.puaChars = p
local cs = m_chars.chars_substitutions
export.chars_substitutions = cs

-- FIXME! Many of the script-specific values below can be moved to [[モジュール:scripts/data]] to serve as script-wide
-- fallback values instead of specifying them for each language using the script.
local s = {}
-- These values are placed here to make it possible to synchronise a group of languages without the need for a dedicated function module.

-- cau
do
	local cau_remove_diacritics = c.grave .. c.acute .. c.macron
	
	local cau_from = {"[IlΙІӀᴴ]"}
	
	local cau_to = {{
		["l"] = "ӏ",
		["Ι"] = "ӏ",
		["І"] = "ӏ",
		["Ӏ"] = "ӏ",
		["ᴴ"] = "ᵸ",
	}}

	s["cau-Cyrl-displaytext"] = {
		from = cau_from,
		to = cau_to,
	}

	s["cau-Cyrl-stripdiacritics"] = {
		remove_diacritics = cau_remove_diacritics,
		from = cau_from,
		to = cau_to,
	}

	s["cau-Latn-stripdiacritics"] = {remove_diacritics = cau_remove_diacritics}
end

s["itc-Latn-displaytext"] = {
	from = {c.caron},
	to = {c.breve},
}

s["itc-Latn-stripdiacritics"] = {remove_diacritics = c.macron .. c.breve .. c.diaer .. c.caron .. c.dinvbreve}

s["itc-Latn-sortkey"] = {
	remove_diacritics = c.circ .. c.tilde .. c.macron .. c.breve .. c.diaer .. c.caron .. c.zigzag .. c.dmacron .. c.dtilde .. c.dinvbreve .. c.small_a .. c.small_e .. c.small_i .. c.small_o .. c.small_u, -- Chiefly medieval abbreviations.
	from = {"ᵃ", "æ", "[đꝱꟈ]", "ᵉ", "ⁱ", "ꝁ", "[ƚꝉꝲ]", "ꝳ", "ꝴ", "[ꝋᵒ]", "œ", "[ꝑꝓꝕ]", "[ꝗꝙ]", "[ꝛꝵꝶꝝ]", "[ꟊˢ]", "[ꝷᵗ]", "ᵘ", "ꝟ", "⁊"},
	to = {"a", "ae", "d", "e", "i", "k", "l", "m", "n", "o", "oe", "p", "q", "r", "s", "t", "u", "v", "&"}
}

s["Jpan-standardchars"] = -- exclude ぢづヂヅ
	"ぁあぃいぅうぇえぉおかがきぎくぐけげこごさざしじすずせぜそぞただちっつてでとどなにぬねのはばぱひびぴふぶぷへべぺほぼぽまみむめもゃやゅゆょよらりるれろん" ..
	"ァアィイゥウェエォオカガキギクグケゲコゴサザシジスズセゼソゾタダチッツテデトドナニヌネノハバパヒビピフブプヘベペホボポマミムメモャヤュユョヨラリルレロン"

local jpx_displaytext = {
	from = {"～", "＝"},
	to = {"〜", "゠"}
}

s["jpx-displaytext"] = {
	Jpan = jpx_displaytext,
	Hani = jpx_displaytext,
	Hrkt = jpx_displaytext,
	Hira = jpx_displaytext,
	Kana = jpx_displaytext
	-- not Latn or Brai
}

s["jpx-stripdiacritics"] = s["jpx-displaytext"]

s["jpx-sortkey"] = {
	Jpan = "Jpan-sortkey",
	Hani = "Hani-sortkey",
	Hrkt = "Hira-sortkey", -- sort general kana by normalizing to Hira
	Hira = "Hira-sortkey",
	Kana = "Kana-sortkey",
	Latn = {remove_diacritics = c.tilde .. c.macron .. c.diaer}
}

s["jpx-translit"] = {
	Hrkt = "Hrkt-translit",
	Hira = "Hrkt-translit",
	Kana = "Hrkt-translit"
}

s["roa-oil-sortkey"] = {
	remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.ringabove .. c.cedilla .. "'",
	from = {"æ", "œ", "·"},
	to = {"ae", "oe", " "}
}

s["wen-sortkey"] = {
	from = {"ch", "[lłßꞩẜ]", "dz[" .. c.caron .. c.acute .. "]", "[bcefmnoprswz][" .. c.caron .. c.acute .. c.dotabove .. "]"},
	to = {
		"h" .. p[1],
		{
			["l"] = "l" .. p[1], ["ł"] = "l", ["ß"] = "s", ["ꞩ"] = "š", ["ẜ"] = "š",
		},
		{
			["dz" .. c.caron] = "d" .. p[1], ["dz" .. c.acute] = "d" .. p[2]
		},
		{
			["b" .. c.acute] = "b" .. p[1],
			["c" .. c.caron] = "c" .. p[1], ["c" .. c.acute] = "c" .. p[2],
			["e" .. c.caron] = "e" .. p[1], ["e" .. c.dotabove] = "e" .. p[1],
			["f" .. c.acute] = "f" .. p[1],
			["m" .. c.acute] = "m" .. p[1],
			["n" .. c.acute] = "n" .. p[1],
			["o" .. c.acute] = "o" .. p[1],
			["p" .. c.acute] = "p" .. p[1],
			["r" .. c.caron] = "r" .. p[1], ["r" .. c.acute] = "r" .. p[2],
			["s" .. c.caron] = "s" .. p[1], ["s" .. c.acute] = "s" .. p[2],
			["w" .. c.acute] = "w" .. p[1],
			["z" .. c.caron] = "z" .. p[1], ["z" .. c.acute] = "z" .. p[2],
		}
	}
}

-- Myanmar dotted form : https://www.unicode.org/Public/UNIDATA/StandardizedVariants.txt
s["aio-displaytext"] = {
	from = {"([ကဂငတထပမယလဝဢေၵၸၺႀꩠꩡꩢꩣꩤꩥꩦꩫꩬꩯꩺ])"},
	to = {"%1" .. c.VS01}
}
s["aio-stripdiacritics"] = {
	remove_diacritics = c.VS01,
}

s["phk-displaytext"] = s["aio-displaytext"]
s["phk-stripdiacritics"] = s["aio-stripdiacritics"]

s["kht-displaytext"] = s["aio-displaytext"]
s["kht-stripdiacritics"] = s["aio-stripdiacritics"]

export.shared = s

--[==[ var:
Short-term solution to override the standard substitution process, by forcing the module to substitute the entire
text in one pass, if "cont" is given. This results in any PUA characters that are used as stand-ins for formatting being
handled by the language-specific substitution process, which is usually undesirable. If the value is "none" then the
formatting tags do not get turned into PUA characters in the first place. This override is provided for languages which
use formatting between strings of text which might need to interact with each other (e.g. Korean 값이 transliterates as "gaps-i", but [[값]] has the formatting '''값'''[[-이]]. The normal process would split the text at the second '''.)
]==]
export.substitution = {
	["gmy"] = "none",
	["ja"] = "cont",
	["jje"] = "cont",
	["ko"] = "cont",
	["ko-ear"] = "cont",
	["ru"] = "cont",
	["th-new"] = "cont",
	["sa"] = "cont",
	["zkt"] = "cont",
}

--[==[ var:
Code aliases. The left side is the alias and the right side is the canonical code. NOTE: These are gradually
being deprecated, so should not be added to on a permanent basis. Temporary additions are permitted under reasonable
circumstances (e.g. to facilitate changing a language's code). When an alias is no longer used, it should be removed.
Aliases in this table are tracked at [[Wiktionary:Tracking/languages/LANG]]; see e.g.
[[Special:WhatLinksHere/Wiktionary:Tracking/languages/VL.]] for the `VL.` alias.
]==]
export.aliases = {
	["EL."] = "la-ecc",
	["LL."] = "la-lat",
	["ML."] = "la-med",
	["NL."] = "la-new",
	["VL."] = "la-vul",
	["nds-DE"] = "nds-de",
	["nds-NL"] = "nds-nl",
	["roa-oan"] = "roa-ona",
	["sa-cls"] = "cls",
	["sa-ved"] = "vsn",
}

--[==[ var:
Codes which are tracked. Note that all aliases listed above are also tracked, so should not be duplicated here.
Tracking uses the same mechanism described above in the comment above `export.aliases`.
]==]
export.track = {
	-- Codes duplicated between full and etymology-only languages.
	["lzh-lit"] = true,
	["lzh"] = true,
	-- Languages actively being converted to families.
	["bh"] = true, -- inc-bih
	["nan"] = true, -- zhx-nan
}

return export