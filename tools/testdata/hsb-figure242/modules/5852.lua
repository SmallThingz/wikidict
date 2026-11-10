local m_scripts = require("Module:scripts")

local table = table
local insert = table.insert
local u = require("Module:string/char")

local export = {}

-- UTF-8 encoded strings for some commonly-used diacritics.
local c = {
	prime			= u(0x02B9),
	grave			= u(0x0300),
	acute			= u(0x0301),
	circ			= u(0x0302),
	tilde			= u(0x0303),
	macron			= u(0x0304),
	overline		= u(0x0305),
	breve			= u(0x0306),
	dotabove		= u(0x0307),
	diaer			= u(0x0308),
	ringabove		= u(0x030A),
	dacute			= u(0x030B),
	caron			= u(0x030C),
	lineabove		= u(0x030D),
	dgrave			= u(0x030F),
	invbreve		= u(0x0311),
	commaabove		= u(0x0313),
	revcommaabove	= u(0x0314),
	dotbelow		= u(0x0323),
	diaerbelow		= u(0x0324),
	ringbelow		= u(0x0325),
	cedilla			= u(0x0327),
	ogonek			= u(0x0328),
	brevebelow		= u(0x032E),
	macronbelow		= u(0x0331),
	perispomeni		= u(0x0342),
	ypogegrammeni	= u(0x0345),
	CGJ				= u(0x034F), -- combining grapheme joiner
	zigzag			= u(0x035B),
	dbrevebelow		= u(0x035C),
	dmacron			= u(0x035E),
	dtilde			= u(0x0360),
	dinvbreve		= u(0x0361),
	small_a			= u(0x0363),
	small_e			= u(0x0364),
	small_i			= u(0x0365),
	small_o			= u(0x0366),
	small_u			= u(0x0367),
	keraia			= u(0x0374),
	lowerkeraia		= u(0x0375),
	tonos			= u(0x0384),
	palatalization	= u(0x0484),
	dasiapneumata	= u(0x0485),
	psilipneumata	= u(0x0486),
	kashida			= u(0x0640),
	fathatan		= u(0x064B),
	dammatan		= u(0x064C),
	kasratan		= u(0x064D),
	fatha			= u(0x064E),
	damma			= u(0x064F),
	kasra			= u(0x0650),
	shadda			= u(0x0651),
	sukun			= u(0x0652),
	hamzaabove		= u(0x0654),
	nunghunna		= u(0x0658),
	zwarakay		= u(0x0659),
	smallv			= u(0x065A),
	superalef		= u(0x0670),
	udatta			= u(0x0951),
	anudatta		= u(0x0952),
	dottedgrave		= u(0x1DC0),
	dottedacute		= u(0x1DC1),
	coronis			= u(0x1FBD),
	psili			= u(0x1FBF),
	dasia			= u(0x1FEF),
	ZWNJ			= u(0x200C), -- zero width non-joiner
	ZWJ				= u(0x200D), -- zero width joiner
	RSQuo			= u(0x2019), -- right single quote
	kavyka			= u(0xA67C),
	VS01			= u(0xFE00), -- variation selector 1
	-- Punctuation for the standardChars field.
	-- Note: characters are literal (i.e. no magic characters).
	punc			= " ',-‐‑‒–—…∅",
	-- Range covering all diacritics.
	diacritics		= u(0x300) .. "-" .. u(0x34E) ..
						u(0x350) .. "-" .. u(0x36F) ..
						u(0x1AB0) .. "-" .. u(0x1ACE) ..
						u(0x1DC0) .. "-" .. u(0x1DFF) ..
						u(0x20D0) .. "-" .. u(0x20F0) ..
						u(0xFE20) .. "-" .. u(0xFE2F),
}
-- Braille characters for the standardChars field.
local braille = {}
for i = 0x2800, 0x28FF do
	insert(braille, u(i))
end
c.braille = table.concat(braille)
export.chars = c

-- PUA characters, generally used in sortkeys.
-- Note: if the limit needs to be increased, do so in powers of 2 (due to the way memory is allocated for tables).
local p = {}
for i = 1, 32 do
	p[i] = u(0xF000+i-1)
end
export.puaChars = p

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

	s["cau-Cyrl-entryname"] = {
		remove_diacritics = cau_remove_diacritics,
		from = cau_from,
		to = cau_to,
	}

	s["cau-Latn-entryname"] = {remove_diacritics = cau_remove_diacritics}
end

-- Cyrs
do
	local Cyrs_remove_diacritics = c.grave .. c.acute .. c.dotabove .. c.diaer .. c.invbreve .. c.palatalization .. c.dasiapneumata .. c.psilipneumata .. c.dottedgrave .. c.dottedacute .. c.kavyka
	

	s["Cyrs-entryname"] = {remove_diacritics = Cyrs_remove_diacritics}

	s["Cyrs-sortkey"] = {
		remove_diacritics = Cyrs_remove_diacritics,
		from = {
			"ї", "оу", -- 2 chars
			"[ґꙣєѕꙃꙅꙁіꙇђꙉѻꙩꙫꙭꙮꚙꚛꙋѡѿꙍѽꙑѣꙗѥꙕѧꙙѩꙝꙛѫѭѯѱѳѵҁ]"
		},
		to = {
			"и" .. p[1], "у", {
				["ґ"] = "г" .. p[1], ["ꙣ"] = "д" .. p[1], ["є"] = "е", ["ѕ"] = "ж" .. p[1], ["ꙃ"] = "ж" .. p[1],
				["ꙅ"] = "ж" .. p[1], ["ꙁ"] = "з", ["і"] = "и" .. p[1], ["ꙇ"] = "и" .. p[1], ["ђ"] = "и" .. p[2],
				["ꙉ"] = "и" .. p[2], ["ѻ"] = "о", ["ꙩ"] = "о", ["ꙫ"] = "о", ["ꙭ"] = "о",
				["ꙮ"] = "о", ["ꚙ"] = "о", ["ꚛ"] = "о", ["ꙋ"] = "у", ["ѡ"] = "х" .. p[1],
				["ѿ"] = "х" .. p[1], ["ꙍ"] = "х" .. p[1], ["ѽ"] = "х" .. p[1], ["ꙑ"] = "ы", ["ѣ"] = "ь" .. p[1],
				["ꙗ"] = "ь" .. p[2], ["ѥ"] = "ь" .. p[3], ["ꙕ"] = "ю", ["ѧ"] = "я", ["ꙙ"] = "я",
				["ѩ"] = "я" .. p[1], ["ꙝ"] = "я" .. p[1], ["ꙛ"] = "я" .. p[2], ["ѫ"] = "я" .. p[3], ["ѭ"] = "я" .. p[4],
				["ѯ"] = "я" .. p[5], ["ѱ"] = "я" .. p[6], ["ѳ"] = "я" .. p[7], ["ѵ"] = "я" .. p[8], ["ҁ"] = "я" .. p[9],
			}
		},
	}
end

s["Grek-displaytext"] = {
	from = {"Þ", "þ", "['ʼ" .. c.RSQuo .. c.prime .. c.keraia .. c.coronis .. c.psili .. "]"}, -- Not tonos, used as the numeral sign in entries.
	to = {"Ϸ", "ϸ", c.RSQuo}
}

s["Grek-entryname"] = {
	remove_diacritics = c.caron .. c.diaerbelow .. c.brevebelow,
	from = s["Grek-displaytext"].from,
	to = {"Ϸ", "ϸ", "'"}
}

s["Grek-sortkey"] = {
	remove_diacritics = "'ʼ;·`¨´῀" .. c.grave .. c.acute .. c.diaer .. c.caron .. c.commaabove .. c.revcommaabove .. c.macron .. c.breve .. c.diaerbelow .. c.brevebelow .. c.perispomeni .. c.ypogegrammeni .. c.RSQuo .. c.prime .. c.keraia .. c.lowerkeraia .. c.tonos .. c.coronis .. c.psili .. c.dasia,
	from = {"ϝ", "ͷ", "ϛ", "ͱ", "ͺ", "ϳ", "ϻ", "[ϟϙ]", "[ςϲ]", "ͳ"},
	to = {"ε" .. p[1], "ε" .. p[2], "ε" .. p[3], "ζ" .. p[1], "ι", "ι" .. p[1], "π" .. p[1], "π" .. p[2], "σ", "ϡ"}
}

s["itc-Latn-displaytext"] = {
	from = {c.caron},
	to = {c.breve},
}

s["itc-Latn-entryname"] = {remove_diacritics = c.macron .. c.breve .. c.diaer .. c.caron .. c.dinvbreve}

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

s["jpx-entryname"] = s["jpx-displaytext"]

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

local HaniChars = m_scripts.getByCode("Hani"):getCharacters()
-- `漢字(한자)`→`漢字`
-- `가-나-다`→`가나다`, `가--나--다`→`가-나-다`
-- `온돌(溫突/溫堗)`→`온돌` ([[ondol]])
s["Kore-entryname"] = {
	remove_diacritics = u(0x302E) .. u(0x302F),
	from = {"([" .. HaniChars .. "])%(.-%)", "^%-", "%-$", "%-(%-?)", "\1", "%([" .. HaniChars .. "/]+%)"},
	to = {"%1", "\1", "\1", "%1", "-"}
}

s["Lisu-sortkey"] = {
	from = {"𑾰"},
	to = {"ꓬ" .. p[1]}
}

s["Mong-displaytext"] = {
	from = {"([ᠨ-ᡂᡸ])ᠶ([ᠨ-ᡂᡸ])", "([ᠠ-ᡂᡸ])ᠸ([^᠋ᠠ-ᠧ])", "([ᠠ-ᡂᡸ])ᠸ$"},
	to = {"%1ᠢ%2", "%1ᠧ%2", "%1ᠧ"}
}

s["Mong-entryname"] = s["Mong-displaytext"]

s["Polyt-displaytext"] = s["Grek-displaytext"]

s["Polyt-entryname"] = {
	remove_diacritics = c.macron .. c.breve .. c.dbrevebelow,
	from = s["Grek-entryname"].from,
	to = s["Grek-entryname"].to
}

s["Polyt-sortkey"] = s["Grek-sortkey"]

-- Samr
do
	s["Samr-entryname"] = {
		remove_diacritics = c.CGJ .. u(0x0816) .. "-" .. u(0x082D),
	}

	s["Samr-sortkey"] = s["Samr-entryname"]
end

s["roa-oil-sortkey"] = {
	remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.ringabove .. c.cedilla .. "'",
	from = {"æ", "œ", "·"},
	to = {"ae", "oe", " "}
}

s["Tibt-displaytext"] = {
	from = {"ༀ", "༌", "།།", "༚༚", "༚༝", "༝༚", "༝༝", "ཷ", "ཹ", "ེེ", "ོོ"},
	to = {"ཨོཾ", "་", "༎", "༛", "༟", "࿎", "༞", "ྲཱྀ", "ླཱྀ", "ཻ", "ཽ"}
}

s["Tibt-entryname"] = s["Tibt-displaytext"]

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

export.shared = s

-- Short-term solution to override the standard substitution process, by forcing the module to substitute the entire text in one pass, if "cont" is given. This results in any PUA characters that are used as stand-ins for formatting being handled by the language-specific substitution process, which is usually undesirable. If the value is "none" then the formatting tags do not get turned into PUA characters in the first place.
-- This override is provided for languages which use formatting between strings of text which might need to interact with each other (e.g. Korean 값이 transliterates as "gaps-i", but [[값]] has the formatting '''값'''[[-이]]. The normal process would split the text at the second '''.)
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

-- Code aliases. The left side is the alias and the right side is the canonical code. NOTE: These are gradually
-- being deprecated, so should not be added to on a permanent basis. Temporary additions are permitted under reasonable
-- circumstances (e.g. to facilitate changing a language's code). When an alias is no longer used, it should be removed.
-- Aliases in this table are tracked at [[Wiktionary:Tracking/languages/LANG]]; see e.g.
-- [[Special:WhatLinksHere/Wiktionary:Tracking/languages/RL.]] for the `RL.` alias.
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

-- Codes which are tracked. Note that all aliases listed above are also tracked, so should not be duplicated here.
-- Tracking uses the same mechanism described above in the comment above `export.aliases`.
export.track = {
	-- Codes duplicated between full and etymology-only languages.
	["lzh-lit"] = true,
	-- Languages actively being converted to families.
	["bh"] = true, -- inc-bih
	["nan"] = true, -- zhx-nan
}

return export