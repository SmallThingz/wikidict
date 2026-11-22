local m_langdata = require("Module:languages/data")

-- Loaded on demand, as it may not be needed (depending on the data).
local function u(...)
	u = require("Module:string utilities").char
	return u(...)
end

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

-- Ideally, we want to move these into [[Module:languages/data]], but because (a) it's necessary to use require on that module, and (b) they're only used in this data module, it's less memory-efficient to do that at the moment. If it becomes possible to use mw.loadData, then these should be moved there.
s["de-Latn-sortkey"] = {
	remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.ringabove,
	from = {"æ", "œ", "ß"},
	to = {"ae", "oe", "ss"}
}

s["de-Latn-standardchars"] = "AaÄäBbCcDdEeFfGgHhIiJjKkLlMmNnOoÖöPpQqRrSsẞßTtUuÜüVvWwXxYyZz"

s["ka-entryname"] = {remove_diacritics = c.circ}

s["no-sortkey"] = {
	remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.dacute .. c.caron .. c.cedilla,
	remove_exceptions = {"å"},
	from = {"æ", "ø", "å"},
	to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
}

s["no-standardchars"] = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvYyÆæØøÅå" .. c.punc

s["tg-entryname"] = {remove_diacritics = c.grave .. c.acute}

s["tk-entryname"] = {remove_diacritics = c.macron}

local m = {}

m["aa"] = {
	"tiếng Afar",
	27811,
	"cus-eas",
	"Latn, Ethi",
	"Tiếng Afar",
	"Afar",
	strip_diacritics = {
		Latn = {remove_diacritics = c.acute},
	},
}

m["ab"] = {
	"tiếng Abkhaz",
	5111,
	"cau-abz",
	"Cyrl, Geor, Latn",
	"Tiếng Abkhaz",
	"Abkhaz",
	translit = {
		Cyrl = "ab-translit",
		-- Chuyển tự Geor đã có ở [[Module:scripts/data]]
	},
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"]
	},
	strip_diacritics = {
		Cyrl = {
			remove_diacritics = c.acute,
			from =  {"^а%-"},
			to = {"а"},
		},
		Latn = s["cau-Latn-stripdiacritics"],
	},
	sort_key = {
		Cyrl = {
			from = {
				"х'ә", -- 3 chars
				"гь", "гә", "ӷь", "ҕь", "ӷә", "ҕә", "дә", "ё", "жь", "жә", "ҙә", "ӡә", "ӡ'", "кь", "кә", "қь", "қә", "ҟь", "ҟә", "ҫә", "тә", "ҭә", "ф'", "хь", "хә", "х'", "ҳә", "ць", "цә", "ц'", "ҵә", "ҵ'", "шь", "шә", "џь", -- 2 chars
				"ӷ", "ҕ", "ҙ", "ӡ", "қ", "ҟ", "ԥ", "ҧ", "ҫ", "ҭ", "ҳ", "ҵ", "ҷ", "ҽ", "ҿ", "ҩ", "џ", "ә", -- 1 char
				"^а",
			},
			to = {
				"х" .. p[4],
				"г" .. p[1], "г" .. p[2], "г" .. p[5], "г" .. p[6], "г" .. p[7], "г" .. p[8], "д" .. p[1], "е" .. p[1], "ж" .. p[1], "ж" .. p[2], "з" .. p[2], "з" .. p[4], "з" .. p[5], "к" .. p[1], "к" .. p[2], "к" .. p[4], "к" .. p[5], "к" .. p[7], "к" .. p[8], "с" .. p[2], "т" .. p[1], "т" .. p[3], "ф" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[3], "х" .. p[6], "ц" .. p[1], "ц" .. p[2], "ц" .. p[3], "ц" .. p[5], "ц" .. p[6], "ш" .. p[1], "ш" .. p[2], "ы" .. p[3],
				"г" .. p[3], "г" .. p[4], "з" .. p[1], "з" .. p[3], "к" .. p[3], "к" .. p[6], "п" .. p[1], "п" .. p[2], "с" .. p[1], "т" .. p[2], "х" .. p[5], "ц" .. p[4], "ч" .. p[1], "ч" .. p[2], "ч" .. p[3], "ы" .. p[1], "ы" .. p[2], "ь" .. p[1],
				"",
			}
		},
	},
}

m["ae"] = {
	"tiếng Avesta",
	29572,
	"ira-cen",
	"Avst, Gujr, Deva",
	"Tiếng Avesta",
	"Avesta",
	translit = {
		Avst = "Avst-translit"
	},
}

m["af"] = {
	"tiếng Afrikaans",
	14196,
	"gmw-frk",
	"Latn, Arab",
	"Tiếng Afrikaans",
	"Afrikaans",
	ancestors = "nl",
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.ringabove .. c.cedilla .. "'",
			from = {"['ʼ]n"},
			to = {"n" .. p[1]}
		}
	},
}

m["ak"] = {
	"tiếng Akan",
	28026,
	"alv-ctn",
	"Latn",
	"Tiếng Akan",
	"Akan",
}

m["am"] = {
	"tiếng Amhara",
	28244,
	"sem-eth",
	"Ethi",
	"Tiếng Amhara",
	"Amhara",
	translit = "Ethi-translit",
}

m["an"] = {
	"tiếng Aragon",
	8765,
	"roa-ibe",
	"Latn",
	"Tiếng Aragon",
	"Aragon",
	ancestors = "roa-oan",
}

m["ar"] = {
	"tiếng Ả Rập",
	13955,
	"sem-arb",
	"Arab, Hebr, Syrc, Brai, Nbat",
	"Tiếng Ả Rập",
	"Ả Rập",
	translit = {
		Arab = "ar-translit"
	},
	strip_diacritics = {
		Arab = "ar-stripdiacritics",
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["as"] = {
	"tiếng Assam",
	29401,
	"inc-eas",
	"as-Beng",
	"Tiếng Assam",
	"Assam",
	ancestors = "inc-mas",
	translit = "as-translit",
}

m["av"] = {
	"tiếng Avar",
	29561,
	"cau-ava",
	"Cyrl, Latn, Arab",
	"Tiếng Avar",
	"Avar",
	ancestors = "oav",
	translit = {
		Cyrl = "cau-nec-translit",
		Arab = "ar-translit",
	},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {"гъ", "гь", "гӏ", "ё", "кк", "къ", "кь", "кӏ", "лъ", "лӏ", "тӏ", "хх", "хъ", "хь", "хӏ", "цӏ", "чӏ"},
			to = {"г" .. p[1], "г" .. p[2], "г" .. p[3], "е" .. p[1], "к" .. p[1], "к" .. p[2], "к" .. p[3], "к" .. p[4], "л" .. p[1], "л" .. p[2], "т" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[3], "х" .. p[4], "ц" .. p[1], "ч" .. p[1]}
		},
	},
}

m["ay"] = {
	"tiếng Aymara",
	4627,
	"sai-aym",
	"Latn",
	"Tiếng Aymara",
	"Aymara",
}

m["az"] = {
	"tiếng Azerbaijan",
	9292,
	"trk-ogz",
	"Latn, Cyrl, fa-Arab",
	"Tiếng Azerbaijan",
	"Azerbaijan",
	ancestors = "trk-oat",
	dotted_dotless_i = true,
	entry_name = {
		Latn = {
			from = {"ʼ"},
			to = {"'"},
		},
		["fa-Arab"] = {
			module = "ar-entryname",
			["from"] = {
				"ۆ",
				"ۇ",
				"وْ",
				"ڲ",
				"ؽ",
			},
			["to"] = {
				"و",
				"و",
				"و",
				"گ",
				"ی",
			},
		},
	},
	display_text = {
		Latn = {
			from = {"'"},
			to = {"ʼ"}
		}
	},
	sort_key = {
		Latn = {
			from = {
				"i", -- Ensure "i" comes after "ı".
				"ç", "ə", "ğ", "x", "ı", "q", "ö", "ş", "ü", "w"
			},
			to = {
				"i" .. p[1],
				"c" .. p[1], "e" .. p[1], "g" .. p[1], "h" .. p[1], "i", "k" .. p[1], "o" .. p[1], "s" .. p[1], "u" .. p[1], "z" .. p[1]
			}
		},
		Cyrl = {
			from = {"ғ", "ә", "ы", "ј", "ҝ", "ө", "ү", "һ", "ҹ"},
			to = {"г" .. p[1], "е" .. p[1], "и" .. p[1], "и" .. p[2], "к" .. p[1], "о" .. p[1], "у" .. p[1], "х" .. p[1], "ч" .. p[1]}
		},
	},
}

m["ba"] = {
	"tiếng Bashkir",
	13389,
	"trk-kbu",
	"Cyrl",
	"Tiếng Bashkir",
	"Bashkir",
	translit = "ba-translit",
	override_translit = true,
	sort_key = {
		from = {"ғ", "ҙ", "ё", "ҡ", "ң", "ө", "ҫ", "ү", "һ", "ә"},
		to = {"г" .. p[1], "д" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "с" .. p[1], "у" .. p[1], "х" .. p[1], "э" .. p[1]}
	},
}

m["be"] = {
	"tiếng Belarus",
	9091,
	"zle",
	"Cyrl, Latn",
	"Tiếng Belarus",
	"Belarus",
	ancestors = "zle-obe",
	translit = {Cyrl = "be-translit"},
	entry_name = {
		remove_diacritics = c.grave .. c.acute,
		remove_exceptions = {"Ć", "ć", "Ń", "ń", "Ś", "ś", "Ź", "ź"},
	},
	sort_key = {
		Cyrl = {
			from = {"ґ", "ё", "і", "ў"},
			to = {"г" .. p[1], "е" .. p[1], "и" .. p[1], "у" .. p[1]}
		},
		Latn = {
			from = {"ć", "č", "dz", "dź", "dž", "ch", "ł", "ń", "ś", "š", "ŭ", "ź", "ž"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "d" .. p[3], "h" .. p[1], "l" .. p[1], "n" .. p[1], "s" .. p[1], "s" .. p[2], "u" .. p[1], "z" .. p[1], "z" .. p[2]}
		},
	},
	standardChars = {
		Cyrl = "АаБбВвГгДдЕеЁёЖжЗзІіЙйКкЛлМмНнОоПпРрСсТтУуЎўФфХхЦцЧчШшЫыЬьЭэЮюЯя",
		Latn = "AaBbCcĆćČčDdEeFfGgHhIiJjKkLlŁłMmNnŃńOoPpRrSsŚśŠšTtUuŬŭVvYyZzŹźŽž",
		(c.punc:gsub("'", "")) -- Exclude apostrophe.
	},
}

m["bg"] = {
	"tiếng Bulgari",
	7918,
	"zls",
	"Cyrl",
	"Tiếng Bulgari",
	"Bulgari",
	ancestors = "cu-bgm",
	translit = "bg-translit",
	strip_diacritics = {
		remove_diacritics = c.grave .. c.acute,
		remove_exceptions = {"%f[^%z%s]ѝ%f[%z%s]"},
	},
	sort_key = {
		remove_diacritics = c.grave .. c.acute,
		remove_exceptions = {"%f[^%z%s]ѝ%f[%z%s]"},
	},
	standard_chars = "АаБбВвГгДдЕеЖжЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЪъЬьЮюЯя" .. c.punc,
}

m["bh"] = {
	"tiếng Bihari",
	135305,
	"inc-eas",
	"Deva",
}

m["bi"] = {
	"tiếng Bislama",
	35452,
	"crp",
	"Latn",
	"Tiếng Bislama",
	"Bislama",
	ancestors = "en",
}

m["bm"] = {
	"tiếng Bambara",
	33243,
	"dmn-emn",
	"Latn",
	"Tiếng Bambara",
	"Bambara",
	sort_key = {
		from = {"ɛ", "ɲ", "ŋ", "ɔ"},
		to = {"e" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1]}
	},
}

m["bn"] = {
	"tiếng Bengal",
	9610,
	"inc-bas",
	"Beng, Newa",
	"Tiếng Bengal",
	"Bengal",
	ancestors = "inc-mbn,pra-mag",
	translit = {Beng = "bn-translit"},
}

m["bo"] = {
	"tiếng Tây Tạng",
	34271,
	"sit-tib",
	"Tibt", -- sometimes Deva?
	"Tiếng Tây Tạng",
	"Tây Tạng",
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["br"] = {
	"tiếng Breton",
	12107,
	"cel-brs",
	"Latn",
	"Tiếng Breton",
	"Breton",
	ancestors = "xbm",
	sort_key = {
		from = {"ch", "c['ʼ’]h"},
		to = {"c" .. p[1], "c" .. p[2]}
	},
}

m["ca"] = {
	"tiếng Catalan",
	7026,
	"roa-ocr",
	"Latn",
    "Tiếng Catalan",
    "Catalan",
	ancestors = "roa-oca",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.diaer .. c.cedilla,
		from = {"l·l"},
		to = {"ll"}
	},
	standardChars = "AaÀàBbCcÇçDdEeÉéÈèFfGgHhIiÍíÏïJjLlMmNnOoÓóÒòPpQqRrSsTtUuÚúÜüVvXxYyZz·" .. c.punc,
}

m["ce"] = {
	"tiếng Chechen",
	33350,
	"cau-vay",
	"Cyrl, Latn, Arab",
	"Tiếng Chechen",
	"Chechen",
	translit = {
		Cyrl = "cau-nec-translit",
		Arab = "ar-translit",
	},
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {"аь", "гӏ", "ё", "кх", "къ", "кӏ", "оь", "пӏ", "тӏ", "уь", "хь", "хӏ", "цӏ", "чӏ", "юь", "яь"},
			to = {"а" .. p[1], "г" .. p[1], "е" .. p[1], "к" .. p[1], "к" .. p[2], "к" .. p[3], "о" .. p[1], "п" .. p[1], "т" .. p[1], "у" .. p[1], "х" .. p[1], "х" .. p[2], "ц" .. p[1], "ч" .. p[1], "ю" .. p[1], "я" .. p[1]}
		},
	},
}

m["ch"] = {
	"tiếng Chamorro",
	33262,
	"poz",
	"Latn",
	"Tiếng Chamorro",
	"Chamorro",
	sort_key = {
		remove_diacritics = "'",
		from = {"å", "ch", "ñ", "ng"},
		to = {"a" .. p[1], "c" .. p[1], "n" .. p[1], "n" .. p[2]}
	},
}

m["co"] = {
	"tiếng Corse",
	33111,
	"roa-itd",
	"Latn",
	"Tiếng Corse",
	"Corse",
	sort_key = {
		from = {"chj", "ghj", "sc", "sg"},
		to = {"c" .. p[1], "g" .. p[1], "s" .. p[1], "s" .. p[2]}
	},
	standardChars = "AaÀàBbCcDdEeÈèFfGgHhIiÌìÏïJjLlMmNnOoÒòPpQqRrSsTtUuÙùÜüVvZz" .. c.punc,
}

m["cr"] = {
	"tiếng Cree",
	33390,
	"alg",
	"Cans, Latn",
	"Tiếng Cree",
	"Cree",
	translit = {Cans = "cr-translit"},
}

m["cs"] = {
	"tiếng Séc",
	9056,
	"zlw",
	"Latn",
	"Tiếng Séc",
	"Séc",
	ancestors = "cs-ear",
	sort_key = {
		from = {"á", "č", "ď", "é", "ě", "ch", "í", "ň", "ó", "ř", "š", "ť", "ú", "ů", "ý", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "d" .. p[1], "e" .. p[1], "e" .. p[2], "h" .. p[1], "i" .. p[1], "n" .. p[1], "o" .. p[1], "r" .. p[1], "s" .. p[1], "t" .. p[1], "u" .. p[1], "u" .. p[2], "y" .. p[1], "z" .. p[1]}
	},
	standardChars = "AaÁáBbCcČčDdĎďEeÉéĚěFfGgHhIiÍíJjKkLlMmNnŇňOoÓóPpRrŘřSsŠšTtŤťUuÚúŮůVvYyÝýZzŽž" .. c.punc,
}

m["cu"] = {
	"tiếng Slav Giáo hội cổ",
	35499,
	"zls",
	"Cyrs, Glag",
	"Tiếng Slav Giáo hội cổ",
	"Slav Giáo hội cổ",
	translit = {Cyrs = "Cyrs-translit", Glag = "Glag-translit"},
	entry_name = {Cyrs = s["Cyrs-entryname"]},
	sort_key = {Cyrs = s["Cyrs-sortkey"]},
}

m["cv"] = {
	"tiếng Chuvash",
	33348,
	"trk-ogr",
	"Cyrl",
	"Tiếng Chuvash",
	"Chuvash",
	ancestors = "cv-mid",
	translit = "cv-translit",
	override_translit = true,
	sort_key = {
		from = {"ӑ", "ё", "ӗ", "ҫ", "ӳ"},
		to = {"а" .. p[1], "е" .. p[1], "е" .. p[2], "с" .. p[1], "у" .. p[1]}
	},
}

m["cy"] = {
	"tiếng Wales",
	9309,
	"cel-brw",
	"Latn",
	"Tiếng Wales",
	"Wales",
	ancestors = "wlm",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. "'",
		from = {"ch", "dd", "ff", "ng", "ll", "ph", "rh", "th"},
		to = {"c" .. p[1], "d" .. p[1], "f" .. p[1], "g" .. p[1], "l" .. p[1], "p" .. p[1], "r" .. p[1], "t" .. p[1]}
	},
	standardChars = "ÂâAaBbCcDdEeÊêFfGgHhIiÎîLlMmNnOoÔôPpRrSsTtUuÛûWwŴŵYyŶŷ" .. c.punc,
}

m["da"] = {
	"tiếng Đan Mạch",
	9035,
	"gmq-eas",
	"Latn",
	"Tiếng Đan Mạch",
	"Đan Mạch",
	ancestors = "gmq-oda",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.dacute .. c.caron .. c.cedilla,
		remove_exceptions = {"å"},
		from = {"æ", "ø", "å"},
		to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
	},
	standardChars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvYyÆæØøÅå" .. c.punc,
}

m["de"] = {
	"tiếng Đức",
	188,
	"gmw-hgm",
	"Latn, Latf",
	"Tiếng Đức",
	"Đức",
	ancestors = "gmh",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.ringabove,
		from = {"æ", "œ", "ß"},
		to = {"ae", "oe", "ss"}
	},
	standardChars = "AaÄäBbCcDdEeFfGgHhIiJjKkLlMmNnOoÖöPpQqRrSsẞßTtUuÜüVvWwXxYyZz" .. c.punc,
}

m["dv"] = {
	"tiếng Dhivehi",
	32656,
	"inc-ins",
	"Thaa, Diak",
	"Tiếng Dhivehi",
	"Dhivehi",
	translit = {
		Thaa = "dv-translit",
		Diak = "Diak-translit",
	},
	override_translit = true,
}

m["dz"] = {
	"tiếng Dzongkha",
	33081,
	"sit-tib",
	"Tibt",
	"Tiếng Dzongkha",
	"Dzongkha",
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["ee"] = {
	"tiếng Ewe",
	30005,
	"alv-gbe",
	"Latn",
	"Tiếng Ewe",
	"Ewe",
	sort_key = {
		remove_diacritics = c.tilde,
		from = {"ɖ", "dz", "ɛ", "ƒ", "gb", "ɣ", "kp", "ny", "ŋ", "ɔ", "ts", "ʋ"},
		to = {"d" .. p[1], "d" .. p[2], "e" .. p[1], "f" .. p[1], "g" .. p[1], "g" .. p[2], "k" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "t" .. p[1], "v" .. p[1]}
	},
}

m["el"] = {
	"tiếng Hy Lạp",
	9129,
	"grk",
	"Grek, Polyt, Brai",
	"Tiếng Hy Lạp",
	"Hy Lạp",
	ancestors = "el-kth",
	translit = {
		Grek = "el-translit",
		Polyt = "grc-translit",
	},
	override_translit = true,
	entry_name = {
		Grek = {remove_diacritics = c.caron .. c.diaerbelow .. c.brevebelow},
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Grek = s["Grek-sortkey"],
		Polyt = s["Grek-sortkey"],
	},
	standardChars = {
		Grek = "΅·ͺ΄ΑαΆάΒβΓγΔδΕεέΈΖζΗηΉήΘθΙιΊίΪϊΐΚκΛλΜμΝνΞξΟοΌόΠπΡρΣσςΤτΥυΎύΫϋΰΦφΧχΨψΩωΏώ",
		Brai = c.braille,
		c.punc
	},
}

m["en"] = {
	"tiếng Anh",
	1860,
	"gmw-ang",
	"Latn, Brai, Shaw, Dsrt", -- entries in Shaw or Dsrt might require prior discussion
	"Tiếng Anh",
	"Anh",
	wikimedia_codes = "en, simple",
	ancestors = "en-ear",
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.diaer .. c.ringabove .. c.caron .. c.cedilla .. "'%-%s",
			from = {"æ", "œ"},
			to = {"ae", "oe"}
		},
	},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["eo"] = {
    "tiếng Quốc tế ngữ",
	143,
	"art",
	"Latn",
    "Tiếng Quốc tế ngữ",
    "Quốc tế ngữ",
	sort_key = {
		remove_diacritics = c.grave .. c.acute,
		from = {"ĉ", "ĝ", "ĥ", "ĵ", "ŝ", "ŭ"},
		to = {"c" .. p[1], "g" .. p[1], "h" .. p[1], "j" .. p[1], "s" .. p[1], "u" .. p[1]}
	},
	standardChars = "AaBbCcĈĉDdEeFfGgĜĝHhĤĥIiJjĴĵKkLlMmNnOoPpRrSsŜŝTtUuŬŭVvZz" .. c.punc,
}

m["es"] = {
	"tiếng Tây Ban Nha",
	1321,
	"roa-cas",
	"Latn, Brai",
	"Tiếng Tây Ban Nha",
	"Tây Ban Nha",
	ancestors = "osp",
	sort_key = {
		Latn = {
			remove_diacritics = c.acute .. c.diaer .. c.cedilla,
			from = {"ñ"},
			to = {"n" .. p[1]}
		},
	},
	standardChars = {
		Latn = "AaÁáBbCcDdEeÉéFfGgHhIiÍíJjLlMmNnÑñOoÓóPpQqRrSsTtUuÚúÜüVvXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["et"] = {
	"tiếng Estonia",
	9072,
	"urj-fin",
	"Latn",
	sort_key = {
		from = {
			"š", "ž", "õ", "ä", "ö", "ü", -- 2 chars
			"z" -- 1 char
		},
		to = {
			"s" .. p[1], "s" .. p[3], "w" .. p[1], "w" .. p[2], "w" .. p[3], "w" .. p[4],
			"s" .. p[2]
		}
	},
	standard_chars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvÕõÄäÖöÜü" .. c.punc,
}

m["eu"] = {
	"tiếng Basque",
	8752,
	"euq",
	"Latn",
	sort_key = {
		from = {"ç", "ñ"},
		to = {"c" .. p[1], "n" .. p[1]}
	},
	standard_chars = "AaBbDdEeFfGgHhIiJjKkLlMmNnÑñOoPpRrSsTtUuXxZz" .. c.punc,
}

m["fa"] = {
	"tiếng Ba Tư",
	9168,
	"ira-swi",
	"Arab, Hebr",
	ancestors = "fa-cls",
	strip_diacritics = {
		Arab = {
			-- character "ۂ" code U+06C2 to "ه" and "هٔ" (U+0647 + U+0654) to "ه"; hamzatu l-waṣli to a regular alif
			from = {"هٔ", "ٱ"}, -- character "ۂ" code U+06C2 to "ه"; hamzatu l-waṣli to a regular alif
			to = {"ه", "ا"},
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		},
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["ff"] = {
	"tiếng Fula",
	33454,
	"alv-fwo",
	"Latn, Adlm",
	"Tiếng Fula",
	"Fula",
}

m["fi"] = {
	"tiếng Phần Lan",
	1412,
	"urj-fin",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"’"}
	},
	strip_diacritics = { -- used to indicate gemination of the next consonant
		remove_diacritics = "ˣ",
		from = {"’"},
		to = {"'"},
	},
	sort_key = { -- [[Appendix:Finnish alphabet#Collation]] + "aͤ" and "oͤ" as historical variants of "ä" and "ö".
		remove_diacritics = "'’:" .. c.diacritics,
		remove_exceptions = {
			"a[" .. c.ringabove .. c.diaer .. c.small_e .. "]", -- åäaͤ
			"o[" .. c.diaer .. c.tilde .. c.dacute .. c.small_e .. "]", -- öõőoͤ
			"u[" .. c.diaer .. c.dacute .. "]" -- üű
		},
		from = {"æ", "[ðđ]", "ł", "ŋ", "œ", "ß", "þ", "u[" .. c.diaer .. c.dacute .. "]", "å", "aͤ", "o[" .. c.tilde .. c.dacute .. c.small_e .. "]", "ø", "(.)['%-]"},
		to = {"ae", "d", "l", "n", "oe", "ss", "th", "y", "z" .. p[1], "ä", "ö", "ö", "%1"}
	},
	standard_chars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvYyÄäÖö" .. c.punc,
}

m["fj"] = {
	"tiếng Fiji",
	33295,
	"poz-pcc",
	"Latn",
	"Tiếng Fiji",
	"Fiji",
}

m["fo"] = {
	"tiếng Faroe",
	25258,
	"gmq-ins",
	"Latn",
	"Tiếng Faroe",
	"Faroe",
	sort_key = {
		from = {"á", "ð", "í", "ó", "ú", "ý", "æ", "ø"},
		to = {"a" .. p[1], "d" .. p[1], "i" .. p[1], "o" .. p[1], "u" .. p[1], "y" .. p[1], "z" .. p[1], "z" .. p[2]}
	},
	standardChars = "AaÁáBbDdÐðEeFfGgHhIiÍíJjKkLlMmNnOoÓóPpRrSsTtUuÚúVvYyÝýÆæØø" .. c.punc,
}

m["fr"] = {
	"tiếng Pháp",
	150,
	"roa-oil",
	"Latn, Brai",
	"Tiếng Pháp",
	"Pháp",
	display_text = {
		from = {"'"},
		to = {"’"}
	},
	entry_name = {
		from = {"’"},
		to = {"'"},
	},
	ancestors = "frm",
	sort_key = {Latn = s["roa-oil-sortkey"]},
	standardChars = {
		Latn = "AaÀàÂâBbCcÇçDdEeÉéÈèÊêËëFfGgHhIiÎîÏïJjLlMmNnOoÔôŒœPpQqRrSsTtUuÙùÛûÜüVvXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["fy"] = {
	"tiếng Tây Frisia",
	27175,
	"gmw-fri",
	"Latn",
	"Tiếng Tây Frisia",
	"Tây Frisia",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer,
		from = {"y"},
		to = {"i"}
	},
	standardChars = "AaâäàÆæBbCcDdEeéêëèFfGgHhIiïìYyỳJjKkLlMmNnOoôöòPpRrSsTtUuúûüùVvWwZz" .. c.punc,
}

m["ga"] = {
	"tiếng Ireland",
	9142,
	"cel-gae",
	"Latn, Latg",
    "Tiếng Ireland",
    "Ireland",
	ancestors = "mga",
	sort_key = {
		remove_diacritics = c.acute,
		from = {"ḃ", "ċ", "ḋ", "ḟ", "ġ", "ṁ", "ṗ", "ṡ", "ṫ"},
		to = {"bh", "ch", "dh", "fh", "gh", "mh", "ph", "sh", "th"}
	},
	standardChars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíLlMmNnOoÓóPpRrSsTtUuÚúVv" .. c.punc,
}

m["gd"] = {
	"tiếng Gael Scotland",
	9314,
	"cel-gae",
	"Latn, Latg",
	"Tiếng Gael Scotland",
	"Gael Scotland",
	ancestors = "mga",
	sort_key = {remove_diacritics = c.grave .. c.acute},
	standardChars = "AaÀàBbCcDdEeÈèFfGgHhIiÌìLlMmNnOoÒòPpRrSsTtUuÙù" .. c.punc,
}

m["gl"] = {
	"tiếng Galicia",
	9307,
	"roa-ibe",
	"Latn",
	"Tiếng Galicia",
	"Galicia",
	ancestors = "roa-opt",
	sort_key = {
		remove_diacritics = c.acute,
		from = {"ñ"},
		to = {"n" .. p[1]}
	},
	standardChars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíÏïLlMmNnÑñOoÓóPpQqRrSsTtUuÚúÜüVvXxZz" .. c.punc,
}

m["gn"] = {
	"tiếng Guaraní",
	35876,
	"tup-gua",
	"Latn",
	"Tiếng Guaraní",
	"Guaraní",
}

m["gu"] = {
	"tiếng Gujarat",
	5137,
	"inc-wes",
	"Arab, Gujr",
	"Tiếng Gujarat",
	"Gujarat",
	ancestors = "inc-mgu,pra-sau",
	translit = {
		Gujr = "gu-translit",
	},
	entry_name = {
		remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.kasra .. c.shadda .. c.sukun .. "઼"
	},
}

m["gv"] = {
	"tiếng Man",
	12175,
	"cel-gae",
	"Latn",
	"Tiếng Man",
	"Man",
	ancestors = "mga",
	sort_key = {remove_diacritics = c.cedilla .. "-"},
	standardChars = "AaBbCcÇçDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwYy" .. c.punc,
}

m["ha"] = {
	"tiếng Hausa",
	56475,
	"cdc-wst",
	"Latn, Arab",
	"Tiếng Hausa",
	"Hausa",
	entry_name = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron}},
	sort_key = {
		Latn = {
			from = {"ɓ", "b'", "ɗ", "d'", "ƙ", "k'", "sh", "ƴ", "'y"},
			to = {"b" .. p[1], "b" .. p[2], "d" .. p[1], "d" .. p[2], "k" .. p[1], "k" .. p[2], "s" .. p[1], "y" .. p[1], "y" .. p[2]}
		},
	},
}

m["he"] = {
	"tiếng Do Thái",
	9288,
	"sem-can",
	"Hebr, Phnx, Brai",
	"Tiếng Do Thái",
	"Do Thái",
	ancestors = "he-med",
	entry_name = {Hebr = {remove_diacritics = u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. c.CGJ}},
}

m["hi"] = {
	"tiếng Hindi",
	1568,
	"inc-hnd",
	"Deva, Kthi, Newa",
	"Tiếng Hindi",
	"Hindi",
	ancestors = "inc-apa,pra-sau,inc-ohi",
	translit = {Deva = "hi-translit"},
	standardChars = {
		Deva = "अआइईउऊएऐओऔकखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसहत्रज्ञक्षक़ख़ग़ज़झ़ड़ढ़फ़काखागाघाङाचाछाजाझाञाटाठाडाढाणाताथादाधानापाफाबाभामायारालावाशाषासाहात्राज्ञाक्षाक़ाख़ाग़ाज़ाझ़ाड़ाढ़ाफ़ाकिखिगिघिङिचिछिजिझिञिटिठिडिढिणितिथिदिधिनिपिफिबिभिमियिरिलिविशिषिसिहित्रिज्ञिक्षिक़िख़िग़िज़िझ़िड़िढ़िफ़िकीखीगीघीङीचीछीजीझीञीटीठीडीढीणीतीथीदीधीनीपीफीबीभीमीयीरीलीवीशीषीसीहीत्रीज्ञीक्षीक़ीख़ीग़ीज़ीझ़ीड़ीढ़ीफ़ीकुखुगुघुङुचुछुजुझुञुटुठुडुढुणुतुथुदुधुनुपुफुबुभुमुयुरुलुवुशुषुसुहुत्रुज्ञुक्षुक़ुख़ुग़ुज़ुझ़ुड़ुढ़ुफ़ुकूखूगूघूङूचूछूजूझूञूटूठूडूढूणूतूथूदूधूनूपूफूबूभूमूयूरूलूवूशूषूसूहूत्रूज्ञूक्षूक़ूख़ूग़ूज़ूझ़ूड़ूढ़ूफ़ूकेखेगेघेङेचेछेजेझेञेटेठेडेढेणेतेथेदेधेनेपेफेबेभेमेयेरेलेवेशेषेसेहेत्रेज्ञेक्षेक़ेख़ेग़ेज़ेझ़ेड़ेढ़ेफ़ेकैखैगैघैङैचैछैजैझैञैटैठैडैढैणैतैथैदैधैनैपैफैबैभैमैयैरैलैवैशैषैसैहैत्रैज्ञैक्षैक़ैख़ैग़ैज़ैझ़ैड़ैढ़ैफ़ैकोखोगोघोङोचोछोजोझोञोटोठोडोढोणोतोथोदोधोनोपोफोबोभोमोयोरोलोवोशोषोसोहोत्रोज्ञोक्षोक़ोख़ोग़ोज़ोझ़ोड़ोढ़ोफ़ोकौखौगौघौङौचौछौजौझौञौटौठौडौढौणौतौथौदौधौनौपौफौबौभौमौयौरौलौवौशौषौसौहौत्रौज्ञौक्षौक़ौख़ौग़ौज़ौझ़ौड़ौढ़ौफ़ौक्ख्ग्घ्ङ्च्छ्ज्झ्ञ्ट्ठ्ड्ढ्ण्त्थ्द्ध्न्प्फ्ब्भ्म्य्र्ल्व्श्ष्स्ह्त्र्ज्ञ्क्ष्क़्ख़्ग़्ज़्झ़्ड़्ढ़्फ़्।॥०१२३४५६७८९॰",
		c.punc
	},
}

m["ho"] = {
	"tiếng Hiri Motu",
	33617,
	"crp",
	"Latn",
	ancestors = "meu",
}

m["ht"] = {
	"tiếng Creole Haiti",
	33491,
	"crp",
	"Latn",
	"Tiếng Creole Haiti",
	ancestors = "ht-sdm",
	sort_key = {
		from = {
			"oun", -- 3 chars
			"an", "ch", "è", "en", "ng", "ò", "on", "ou", "ui" -- 2 chars
		},
		to = {
			"o" .. p[4],
			"a" .. p[1], "c" .. p[1], "e" .. p[1], "e" .. p[2], "n" .. p[1], "o" .. p[1], "o" .. p[2], "o" .. p[3], "u" .. p[1]
		}
	},
}

m["hu"] = {
	"tiếng Hungary",
	9067,
	"urj-ugr",
	"Latn, Hung",
	"Tiếng Hungary",
	"Hungary",
	ancestors = "ohu",
	sort_key = {
		Latn = {
			from = {
				"dzs", -- 3 chars
				"á", "cs", "dz", "é", "gy", "í", "ly", "ny", "ó", "ö", "ő", "sz", "ty", "ú", "ü", "ű", "zs", -- 2 chars
			},
			to = {
				"d" .. p[2],
				"a" .. p[1], "c" .. p[1], "d" .. p[1], "e" .. p[1], "g" .. p[1], "i" .. p[1], "l" .. p[1], "n" .. p[1], "o" .. p[1], "o" .. p[2], "o" .. p[3], "s" .. p[1], "t" .. p[1], "u" .. p[1], "u" .. p[2], "u" .. p[3], "z" .. p[1],
			}
		},
	},
	standardChars = {
		Latn = "AaÁáBbCcDdEeÉéFfGgHhIiÍíJjKkLlMmNnOoÓóÖöŐőPpQqRrSsTtUuÚúÜüŰűVvWwXxYyZz",
		c.punc
	},
}

m["hy"] = {
	"tiếng Armenia",
	8785,
	"hyx",
	"Armn, Brai",
	"Tiếng Armenia",
	"Armenia",
	ancestors = "axm",
	translit = {Armn = "Armn-translit"},
	override_translit = true,
	entry_name = {
		Armn = {
			remove_diacritics = "՛՜՞՟",
			from = {"եւ", "<sup>յ</sup>", "<sup>ի</sup>", "<sup>է</sup>", "յ̵"},
			to = {"և", "յ", "ի", "է", "ֈ"}
		},
	},
	sort_key = {
		Armn = {
			from = {
				"ու", "եւ", -- 2 chars
				"և" -- 1 char
			},
			to = {
				"ւ", "եվ",
				"եվ"
			}
		},
	},
}

m["hz"] = {
	"tiếng Herero",
	33315,
	"bnt-swb",
	"Latn",
	"Tiếng Herero",
	"Herero",
}

m["ia"] = {
	"tiếng Bổ trợ Quốc tế",
	35934,
	"art",
	"Latn",
	"Tiếng Bổ trợ Quốc tế",
	"Bổ trợ Quốc tế",
}

m["id"] = {
	"tiếng Indonesia",
	9240,
	"poz-mly",
	"Latn",
	"Tiếng Indonesia",
	"Indonesia",
	ancestors = "ms",
	standardChars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz" .. c.punc,
}

m["ie"] = {
	"tiếng Interlingue",
	35850,
	"art",
	"Latn",
	type = "appendix-constructed",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ},
}

m["ig"] = {
	"tiếng Igbo",
	33578,
	"alv-igb",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.macron},
	sort_key = {
		from = {"gb", "gh", "gw", "ị", "kp", "kw", "ṅ", "nw", "ny", "ọ", "sh", "ụ"},
		to = {"g" .. p[1], "g" .. p[2], "g" .. p[3], "i" .. p[1], "k" .. p[1], "k" .. p[2], "n" .. p[1], "n" .. p[2], "n" .. p[3], "o" .. p[1], "s" .. p[1], "u" .. p[1]}
	},
}

m["ii"] = {
	"tiếng Lô Lô",
	34235,
	"tbq-nlo",
	"Yiii",
	"Tiếng Lô Lô",
	"Lô Lô",
	translit = "ii-translit",
}

m["ik"] = {
	"tiếng Inupiaq",
	27183,
	"esx-inu",
	"Latn",
	"Tiếng Inupiaq",
	"Inupiaq",
	sort_key = {
		from = {
			"ch", "ġ", "dj", "ḷ", "ł̣", "ñ", "ng", "r̂", "sr", "zr", -- 2 chars
			"ł", "ŋ", "ʼ" -- 1 char
		},
		to = {
			"c" .. p[1], "g" .. p[1], "h" .. p[1], "l" .. p[1], "l" .. p[3], "n" .. p[1], "n" .. p[2], "r" .. p[1], "s" .. p[1], "z" .. p[1],
			"l" .. p[2], "n" .. p[2], "z" .. p[2]
		}
	},
}

m["io"] = {
	"tiếng Ido",
	35224,
	"art",
	"Latn",
	"Tiếng Ido",
	"Ido",
}

m["is"] = {
	"tiếng Iceland",
	294,
	"gmq-ins",
	"Latn",
	"Tiếng Iceland",
	"Iceland",
	sort_key = {
		from = {"á", "ð", "é", "í", "ó", "ú", "ý", "þ", "æ", "ö"},
		to = {"a" .. p[1], "d" .. p[1], "e" .. p[1], "i" .. p[1], "o" .. p[1], "u" .. p[1], "y" .. p[1], "z" .. p[1], "z" .. p[2], "z" .. p[3]}
	},
	standardChars = "AaÁáBbDdÐðEeÉéFfGgHhIiÍíJjKkLlMmNnOoÓóPpRrSsTtUuÚúVvXxYyÝýÞþÆæÖö" .. c.punc,
}

m["it"] = {
	"tiếng Ý",
	652,
	"roa-itd",
	"Latn",
	"Tiếng Ý",
	"Ý",
	ancestors = "roa-oit",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.ringabove},
	standardChars = "AaÀàBbCcDdEeÈèÉéFfGgHhIiÌìLlMmNnOoÒòPpQqRrSsTtUuÙùVvZz" .. c.punc,
}

m["iu"] = {
	"tiếng Inuktitut",
	29921,
	"esx-inu",
	"Cans, Latn",
	"Tiếng Inuktitut",
	"Inuktitut",
	translit = {Cans = "cr-translit"},
	override_translit = true,
}

m["ja"] = {
	"tiếng Nhật",
	5287,
	"jpx",
	"Jpan, Latn, Brai",
	"Tiếng Nhật",
	"Nhật",
	ancestors = "ja-ear",
	translit = s["jpx-translit"],
	link_tr = true,
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["jv"] = {
	"tiếng Java",
	33549,
	"poz",
	"Latn, Java",
	"Tiếng Java",
	"Java",
	ancestors = "kaw",
	translit = {Java = "jv-translit"},
	link_tr = true,
	entry_name = {remove_diacritics = c.circ}, -- Modern jv don't use ê
	sort_key = {
		Latn = {
			from = {"å", "dh", "é", "è", "ng", "ny", "th"},
			to = {"a" .. p[1], "d" .. p[1], "e" .. p[1], "e" .. p[2], "n" .. p[1], "n" .. p[2], "t" .. p[1]}
		},
	},
}

m["ka"] = {
	"tiếng Gruzia",
	8108,
	"ccs-gzn",
	"Geor, Geok, Hebr", -- Hebr is used to write Judeo-Georgian
	"Tiếng Gruzia",
	"Gruzia",
	ancestors = "ka-mid",
	translit = {
		Geor = "Geor-translit",
		Geok = "Geok-translit",
	},
	override_translit = true,
	entry_name = {remove_diacritics = c.circ},
}

m["kg"] = {
	"tiếng Kongo",
	33702,
	"bnt-kng",
	"Latn",
}

m["ki"] = {
	"tiếng Gikuyu",
	33587,
	"bnt-kka",
	"Latn",
	"Tiếng Gikuyu",
	"Gikuyu",
}

m["kj"] = {
	"tiếng Kwanyama",
	1405077,
	"bnt-ova",
	"Latn",
	"Tiếng Kwanyama",
	"Kwanyama",
}

m["kk"] = {
	"tiếng Kazakh",
	9252,
	"trk-kno",
	"Cyrl, Latn, kk-Arab",
	"Tiếng Kazakh",
	"Kazakh",
	translit = "kk-translit",
--	override_translit = true,
	sort_key = {
		Cyrl = {
			from = {"ә", "ғ", "ё", "қ", "ң", "ө", "ұ", "ү", "һ", "і"},
			to = {"а" .. p[1], "г" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1], "у" .. p[2], "х" .. p[1], "ы" .. p[1]}
		},
	},
	standard_chars = {
		Cyrl = "АаӘәБбВвГгҒғДдЕеЁёЖжЗзИиЙйКкҚқЛлМмНнҢңОоӨөПпРрСсТтУуҰұҮүФфХхҺһЦцЧчШшЩщЪъЫыІіЬьЭэЮюЯя",
		c.punc
	},
}

m["kl"] = {
	"tiếng Greenland",
	25355,
	"esx-inu",
	"Latn",
	"Tiếng Greenland",
	"Greenland",
	sort_key = {
		from = {"æ", "ø", "å"},
		to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
	}
}

m["km"] = {
	"tiếng Khmer",
	9205,
	"mkh-kmr",
	"Khmr",
	"Tiếng Khmer",
	"Khmer",
	ancestors = "xhm",
	translit = "km-translit",
}

m["kn"] = {
	"tiếng Kannada",
	33673,
	"dra-kan",
	"Knda, Tutg",
	"Tiếng Kannada",
	"Kannada",
	ancestors = "dra-mkn",
	translit = "kn-translit",
}

m["ko"] = {
	"tiếng Triều Tiên",
	9176,
	"qfa-kor",
	"Kore, Brai",
	"Tiếng Triều Tiên",
	"Triều Tiên",
	ancestors = "ko-ear",
	translit = {Kore = "ko-translit"},
	entry_name = {Kore = s["Kore-entryname"]},
}

m["kr"] = {
	"tiếng Kanuri",
	36094,
	"ssa-sah",
	"Latn, Arab",
	"Tiếng Kanuri",
	"Kanuri",
	-- the sortkey and strip_diacritics are only for standard Kanuri; when dialectal entries get added, someone will have to work out how the dialects should be represented orthographically
	strip_diacritics = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.breve}
	},
	sort_key = {
		Latn = {
			from = {"ǝ", "ny", "ɍ", "sh"},
			to = {"e" .. p[1], "n" .. p[1], "r" .. p[1], "s" .. p[1]}
		},
	},
}
	
m["ks"] = {
	"tiếng Kashmir",
	33552,
	"inc-kas",
	"ks-Arab, Deva, Shrd, Latn",
	"Tiếng Kashmir",
	"Kashmir",
	translit = {
		["ks-Arab"] = "ks-Arab-translit",
		Deva = "ks-Deva-translit",
		Shrd = "Shrd-translit",
	},
}

-- "kv" IS TREATED AS "koi", "kpv", SEE WT:LT

m["kw"] = {
	"tiếng Cornwall",
	25289,
	"cel-brs",
	"Latn",
	"Tiếng Cornwall",
	"Cornwall",
	ancestors = "cnx",
	sort_key = {
		from = {"ch"},
		to = {"c" .. p[1]}
	},
}

m["ky"] = {
	"tiếng Kyrgyz",
	9255,
	"trk-kkp",
	"Cyrl, Latn, Arab",
	"Tiếng Kyrgyz",
	"Kyrgyz",
	translit = {Cyrl = "ky-translit"},
	override_translit = true,
	sort_key = {
		Cyrl = {
			from = {"ё", "ң", "ө", "ү"},
			to = {"е" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1]}
		},
	},
}

m["la"] = {
	"tiếng Latinh",
	397,
	"itc",
	"Latn, Ital",
	"Tiếng Latinh",
	"Latinh",
	ancestors = "itc-ola",
	entry_name = {Latn = {remove_diacritics = c.macron .. c.breve .. c.diaer .. c.dinvbreve}},
	sort_key = {
		Latn = {
			from = {"æ", "œ"},
			to = {"ae", "oe"}
		},
	},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiLlMmNnOoPpQqRrSsTtUuVvXxZz",
		c.punc
	},
}

m["lb"] = {
	"tiếng Luxembourg",
	9051,
	"gmw-hgm",
	"Latn",
	"Tiếng Luxembourg",
	"Luxembourg",
	ancestors = "gmw-cfr",
	sort_key = {
		from = {"ä", "ë", "é"},
		to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
	},
}

m["lg"] = {
	"tiếng Luganda",
	33368,
	"bnt-nyg",
	"Latn",
	"Tiếng Luganda",
	"Luganda",
	entry_name = {remove_diacritics = c.acute .. c.circ},
	sort_key = {
		from = {"ŋ"},
		to = {"n" .. p[1]}
	},
}

m["li"] = {
	"tiếng Limburg",
	102172,
	"gmw-frk",
	"Latn",
	"Tiếng Limburg",
	"Limburg",
	ancestors = "dum",
}

m["ln"] = {
	"tiếng Lingala",
	36217,
	"bnt-bmo",
	"Latn",
	"Tiếng Lingala",
	"Lingala",
	sort_key = {
		remove_diacritics = c.acute .. c.circ .. c.caron,
		from = {"ɛ", "gb", "mb", "mp", "nd", "ng", "nk", "ns", "nt", "ny", "nz", "ɔ"},
		to = {"e" .. p[1], "g" .. p[1], "m" .. p[1], "m" .. p[2], "n" .. p[1], "n" .. p[2], "n" .. p[3], "n" .. p[4], "n" .. p[5], "n" .. p[6], "n" .. p[7], "o" .. p[1]}
	},
}

m["lo"] = {
	"tiếng Lào",
	9211,
	"tai-swe",
	"Laoo",
	"Tiếng Lào",
	"Lào",
	translit = "lo-translit",
	sort_key = "Laoo-sortkey",
	standardChars = "0-9ກຂຄງຈຊຍດຕຖທນບປຜຝພຟມຢຣລວສຫອຮຯ-ໝ" .. c.punc,
}

m["lt"] = {
	"tiếng Litva",
	9083,
	"bat-eas",
	"Latn",
	"Tiếng Litva",
	"Litva",
	ancestors = "olt",
	display_text = "lt-common",
	strip_diacritics = "lt-common",
	sort_key = "lt-common",
	standard_chars = "AaĄąBbCcČčDdEeĘęĖėFfGgHhIiĮįYyJjKkLlMmNnOoPpRrSsŠšTtUuŲųŪūVvZzŽž" .. c.punc,
}

m["lu"] = {
	"tiếng Luba-Katanga",
	36157,
	"bnt-lub",
	"Latn",
}

m["lv"] = {
	"tiếng Latvia",
	9078,
	"bat-eas",
	"Latn",
	"Tiếng Latvia",
	"Latvia",
	strip_diacritics = {
		-- This attempts to convert vowels with tone marks to vowels either with or without macrons. Specifically, there should be no macrons if the vowel is part of a diphthong (including resonant diphthongs such pìrksts -> pirksts not #pīrksts). What we do is first convert the vowel + tone mark to a vowel + tilde in a decomposed fashion, then remove the tilde in diphthongs, then convert the remaining vowel + tilde sequences to macroned vowels, then delete any other tilde. We leave already-macroned vowels alone: Both e.g. ar and ār occur before consonants. FIXME: This still might not be sufficient.
		from = {"([Ee])" .. c.cedilla, "[" .. c.grave .. c.circ .. c.tilde .."]", "([aAeEiIoOuU])" .. c.tilde .."?([lrnmuiLRNMUI])" .. c.tilde .. "?([^aAeEiIoOuU])", "([aAeEiIoOuU])" .. c.tilde .."?([lrnmuiLRNMUI])" .. c.tilde .."?$", "([iI])" .. c.tilde .. "?([eE])" .. c.tilde .. "?", "([aAeEiIuU])" .. c.tilde, c.tilde},
		to = {"%1", c.tilde, "%1%2%3", "%1%2", "%1%2", "%1" .. c.macron}
	},
	sort_key = {
		from = {"ā", "č", "ē", "ģ", "ī", "ķ", "ļ", "ņ", "š", "ū", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "e" .. p[1], "g" .. p[1], "i" .. p[1], "k" .. p[1], "l" .. p[1], "n" .. p[1], "s" .. p[1], "u" .. p[1], "z" .. p[1]}
	},
	standard_chars = "AaĀāBbCcČčDdEeĒēFfGgĢģHhIiĪīJjKkĶķLlĻļMmNnŅņOoPpRrSsŠšTtUuŪūVvZzŽž" .. c.punc,
}

m["mg"] = {
	"tiếng Malagasy",
	7930,
	"poz-bre",
	"Latn, Arab",
	"Tiếng Malagasy",
	"Malagasy",
}

m["mh"] = {
	"tiếng Marshall",
	36280,
	"poz-mic",
	"Latn",
	"Tiếng Marshall",
	"Marshall",
	sort_key = {
		from = {"ā", "ļ", "m̧", "ņ", "n̄", "o̧", "ō", "ū"},
		to = {"a" .. p[1], "l" .. p[1], "m" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "o" .. p[2], "u" .. p[1]}
	},
}

m["mi"] = {
	"tiếng Maori",
	36451,
	"poz-pep",
	"Latn",
	"Tiếng Maori",
	"Maori",
	sort_key = {
		remove_diacritics = c.macron,
		from = {"ng", "wh"},
		to = {"z" .. p[1], "z" .. p[2]}
	},
}

m["mk"] = {
	"tiếng Macedonia",
	9296,
	"zls",
	"Cyrl",
	ancestors = "cu",
	translit = "mk-translit",
	entry_name = {
		remove_diacritics = c.acute,
		remove_exceptions = {"Ѓ", "ѓ", "Ќ", "ќ"}
	},
	sort_key = {
		remove_diacritics = c.grave,
		from = {"ѓ", "ѕ", "ј", "љ", "њ", "ќ", "џ"},
		to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "т" .. p[1], "ч" .. p[1]}
	},
	standardChars = "АаБбВвГгДдЃѓЕеЖжЗзЅѕИиЈјКкЛлЉљМмНнЊњОоПпРрСсТтЌќУуФфХхЦцЧчЏџШш" .. c.punc,
}

m["ml"] = {
	"tiếng Malayalam",
	36236,
	"dra",
	"Mlym",
	"Tiếng Malayalam",
	"Malayalam",
	translit = "ml-translit",
	override_translit = true,
}

m["mn"] = {
	"tiếng Mông Cổ",
	9246,
	"xgn-cen",
	"Cyrl, Mong, Latn, Brai",
	"Tiếng Mông Cổ",
	"Mông Cổ",
	ancestors = "cmg",
	translit = {
		Cyrl = "mn-translit",
		Mong = "Mong-translit",
	},
	override_translit = true,
	display_text = {Mong = s["Mong-displaytext"]},
	entry_name = {
		Cyrl = {remove_diacritics = c.grave .. c.acute},
		Mong = s["Mong-entryname"],
	},
	sort_key = {
		Cyrl = {
			remove_diacritics = c.grave,
			from = {"ё", "ө", "ү"},
			to = {"е" .. p[1], "о" .. p[1], "у" .. p[1]}
		},
	},
	standardChars = {
		Cyrl = "АаБбВвГгДдЕеЁёЖжЗзИиЙйЛлМмНнОоӨөРрСсТтУуҮүХхЦцЧчШшЫыЬьЭэЮюЯя—",
		Brai = c.braille,
		c.punc
	},
}

-- "mo" IS TREATED AS "ro", SEE WT:LT

m["mr"] = {
	"tiếng Marathi",
	1571,
	"inc-sou",
	"Deva, Modi",
	"Tiếng Marathi",
	"Marathi",
	ancestors = "omr",
	translit = {
		Deva = "mr-translit",
		Modi = "mr-Modi-translit",
	},
	entry_name = {
		Deva = {
			from = {"च़", "ज़", "झ़"},
			to = {"च", "ज", "झ"}
		},
	},
}

m["ms"] = {
	"tiếng Mã Lai",
	9237,
	"poz-mly",
	"Latn, ms-Arab",
	"Tiếng Mã Lai",
	"Mã Lai",
	ancestors = "ms-cla",
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		c.punc
	},
}

m["mt"] = {
	"tiếng Malta",
	9166,
	"sem-arb",
	"Latn",
	"Tiếng Malta",
	"Malta",
	display_text = {
		from = {"'"},
		to = {"’"}
	},
	entry_name = {
		from = {"’"},
		to = {"'"},
	},
	ancestors = "sqr",
	sort_key = {
		from = {
			"ċ", "ġ", "ż", -- Convert into PUA so that decomposed form does not get caught by the next step.
			"([cgz])", -- Ensure "c" comes after "ċ", "g" comes after "ġ" and "z" comes after "ż".
			"g" .. p[1] .. "ħ", -- "għ" after initial conversion of "g".
			p[3], p[4], "ħ", "ie", p[5] -- Convert "ċ", "ġ", "ħ", "ie", "ż" into final output.
		},
		to = {
			p[3], p[4], p[5],
			"%1" .. p[1],
			"g" .. p[2],
			"c", "g", "h" .. p[1], "i" .. p[1], "z"
		}
	},
}

m["my"] = {
	"tiếng Miến Điện",
	9228,
	"tbq-brm",
	"Mymr",
	"Tiếng Miến Điện",
	"Miến Điện",
	ancestors = "obr",
	translit = "my-translit",
	override_translit = true,
	sort_key = {
		from = {"ျ", "ြ", "ွ", "ှ", "ဿ"},
		to = {"္ယ", "္ရ", "္ဝ", "္ဟ", "သ္သ"}
	},
}

m["na"] = {
	"tiếng Nauru",
	13307,
	"poz-mic",
	"Latn",
	"Tiếng Nauru",
	"Nauru",
}

m["nb"] = {
	"tiếng Na Uy (Bokmål)",
	25167,
	"gmq",
	"Latn",
	"Tiếng Na Uy (Bokmål)",
	"Na Uy (Bokmål)",
	wikimedia_codes = "no",
	ancestors = "gmq-mno, da",  -- da as an (but not the) ancestor of nb was agreed on - do not change without discussion
	sort_key = s["no-sortkey"],
	standardChars = s["no-standardchars"],
}

m["nd"] = {
	"tiếng Bắc Ndebele",
	35613,
	"bnt-ngu",
	"Latn",
	"Tiếng Bắc Ndebele",
	"Bắc Ndebele",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["ne"] = {
	"tiếng Nepal",
	33823,
	"inc-pah",
	"Deva, Newa",
	"Tiếng Nepal",
	"Nepal",
	translit = {Deva = "ne-translit"},
}

m["ng"] = {
	"tiếng Ndonga",
	33900,
	"bnt-ova",
	"Latn",
	"Tiếng Ndonga",
	"Ndonga",
}

m["nl"] = {
	"tiếng Hà Lan",
	7411,
	"gmw-frk",
	"Latn, Brai",
	"Tiếng Hà Lan",
	"Hà Lan",
	ancestors = "dum",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.ringabove .. c.cedilla .. "'"},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["nn"] = {
	"tiếng Na Uy (Nynorsk)",
	25164,
	"gmq-wes",
	"Latn",
	"Tiếng Na Uy (Nynorsk)",
	"Na Uy (Nynorsk)",
	ancestors = "gmq-mno",
	entry_name = {
		remove_diacritics = c.grave .. c.acute,
	},
	sort_key = s["no-sortkey"],
	standardChars = s["no-standardchars"],
}

m["no"] = {
	"tiếng Na Uy",
	9043,
	"gmq-wes",
	"Latn",
	"Tiếng Na Uy",
	"Na Uy",
	ancestors = "gmq-mno",
	sort_key = s["no-sortkey"],
	standardChars = s["no-standardchars"],
}

m["nr"] = {
	"tiếng Nam Ndebele",
	36785,
	"bnt-ngu",
	"Latn",
	"Tiếng Nam Ndebele",
	"Nam Ndebele",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["nv"] = {
	"tiếng Navajo",
	13310,
	"apa",
	"Latn",
	"Tiếng Navajo",
	"Navajo",
	sort_key = {
		remove_diacritics = c.acute .. c.ogonek,
		from = {
			"chʼ", "tłʼ", "tsʼ", -- 3 chars
			"ch", "dl", "dz", "gh", "hw", "kʼ", "kw", "sh", "tł", "ts", "zh", -- 2 chars
			"ł", "ʼ" -- 1 char
		},
		to = {
			"c" .. p[2], "t" .. p[2], "t" .. p[4],
			"c" .. p[1], "d" .. p[1], "d" .. p[2], "g" .. p[1], "h" .. p[1], "k" .. p[1], "k" .. p[2], "s" .. p[1], "t" .. p[1], "t" .. p[3], "z" .. p[1],
			"l" .. p[1], "z" .. p[2]
		}
	},
}

m["ny"] = {
	"tiếng Chichewa",
	33273,
	"bnt-nys",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.circ},
	sort_key = {
		from = {"ng'"},
		to = {"ng"}
	},
}

m["oc"] = {
	"tiếng Occitan",
	14185,
	"roa-ocr",
	"Latn, Hebr",
	"Tiếng Occitan",
	"Occitan",
	ancestors = "pro",
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.diaer .. c.cedilla,
			from = {"([lns])·h"},
			to = {"%1h"}
		},
	},
}

m["oj"] = {
	"tiếng Ojibwe",
	33875,
	"alg",
	"Cans, Latn",
	"Tiếng Ojibwe",
	"Ojibwe",
	sort_key = {
		Latn = {
			from = {"aa", "ʼ", "ii", "oo", "sh", "zh"},
			to = {"a" .. p[1], "h" .. p[1], "i" .. p[1], "o" .. p[1], "s" .. p[1], "z" .. p[1]}
		},
	},
}

m["om"] = {
	"tiếng Oromo",
	33864,
	"cus-eas",
	"Latn, Ethi",
	"Tiếng Oromo",
	"Oromo",
}

m["or"] = {
	"tiếng Oriya",
	33810,
	"inc-eas",
	"Orya",
	"Tiếng Oriya",
	"Oriya",
	ancestors = "inc-mor",
	translit = "or-translit",
}

m["os"] = {
	"tiếng Ossetia",
	33968,
	"xsc",
	"Cyrl, Geor, Latn",
	"Tiếng Ossetia",
	"Ossetia",
	ancestors = "oos",
	translit = {
		Cyrl = "os-translit",
		Geor = "Geor-translit",
	},
	override_translit = true,
	display_text = {
		Cyrl = {
			from = {"æ"},
			to = {"ӕ"}
		},
		Latn = {
			from = {"ӕ"},
			to = {"æ"}
		},
	},
	entry_name = {
		Cyrl = {
			remove_diacritics = c.grave .. c.acute,
			from = {"æ"},
			to = {"ӕ"}
		},
		Latn = {
			from = {"ӕ"},
			to = {"æ"}
		},
	},
	sort_key = {
		Cyrl = {
			from = {"ӕ", "гъ", "дж", "дз", "ё", "къ", "пъ", "тъ", "хъ", "цъ", "чъ"},
			to = {"а" .. p[1], "г" .. p[1], "д" .. p[1], "д" .. p[2], "е" .. p[1], "к" .. p[1], "п" .. p[1], "т" .. p[1], "х" .. p[1], "ц" .. p[1], "ч" .. p[1]}
		},
	},
}

m["pa"] = {
	"tiếng Punjab",
	58635,
	"inc-pan",
	"Guru, pa-Arab",
	"Tiếng Punjab",
	"Punjab",
	ancestors = "pra",
	translit = {
		Guru = "Guru-translit",
		["pa-Arab"] = "pa-Arab-translit",
	},
	entry_name = {
		["pa-Arab"] = {
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna,
			from = {"ݨ", "ࣇ"},
			to = {"ن", "ل"}
		},
	},
}

m["pi"] = {
	"tiếng Pali",
	36727,
	"inc",
	"Latn, Brah, Deva, Beng, Sinh, Mymr, Thai, Lana, Laoo, Khmr, Cakm",
	"Tiếng Pali",
	"Pali",
	ancestors = "sa",
	translit = {
		Brah = "Brah-translit",
		Deva = "sa-translit",
		Beng = "pi-translit",
		Sinh = "si-translit",
		Mymr = "pi-translit",
		Thai = "pi-translit",
		Lana = "pi-translit",
		Laoo = "pi-translit",
		Khmr = "pi-translit",
		Cakm = "Cakm-translit",
	},
	entry_name = {
		Thai = {
			from = {"ึ", u(0xF700), u(0xF70F)}, -- FIXME: Not clear what's going on with the PUA characters here.
			to = {"ิํ", "ฐ", "ญ"}
		},
		remove_diacritics = c.VS01
	},
	sort_key = { -- FIXME: This needs to be converted into the current standardized format.
		from = {"ā", "ī", "ū", "ḍ", "ḷ", "m[" .. c.dotabove .. c.dotbelow .. "]", "ṅ", "ñ", "ṇ", "ṭ", "([เโ])([ก-ฮ])", "([ເໂ])([ກ-ຮ])", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ", u(0xFE00), u(0x200D)},
		to = {"a~", "i~", "u~", "d~", "l~", "m~", "n~", "n~~", "n~~~", "t~", "%2%1", "%2%1", "ᩈ᩠ᩈ", "᩠ᩁ", "᩠ᩃ", "ᨦ᩠", "%1᩠ᨮ", "%1᩠ᨻ", "ᩣ"}
	},
}

m["pl"] = {
	"tiếng Ba Lan",
	809,
	"zlw-lch",
	"Latn",
	"Tiếng Ba Lan",
	"Ba Lan",
	ancestors = "zlw-mpl",
	sort_key = {
		from = {"ą", "ć", "ę", "ł", "ń", "ó", "ś", "ź", "ż"},
		to = {"a" .. p[1], "c" .. p[1], "e" .. p[1], "l" .. p[1], "n" .. p[1], "o" .. p[1], "s" .. p[1], "z" .. p[1], "z" .. p[2]}
	},
	standardChars = "AaĄąBbCcĆćDdEeĘęFfGgHhIiJjKkLlŁłMmNnŃńOoÓóPpRrSsŚśTtUuWwYyZzŹźŻż" .. c.punc,
}

m["ps"] = {
	"tiếng Pashtun",
	58680,
	"ira-pat",
	"ps-Arab",
	"Tiếng Pashtun",
	"Pashtun",
	entry_name = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef},
}

m["pt"] = {
	"tiếng Bồ Đào Nha",
	5146,
	"roa-ibe",
	"Latn, Brai",
	"Tiếng Bồ Đào Nha",
	"Bồ Đào Nha",
	ancestors = "roa-opt",
	sort_key = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.cedilla}},
	standardChars = {
		Latn = "AaÁáÂâÃãBbCcÇçDdEeÉéÊêFfGgHhIiÍíJjLlMmNnOoÓóÔôÕõPpQqRrSsTtUuÚúVvXxZz",
		Brai = c.braille,
		c.punc
	},
}

m["qu"] = {
	"tiếng Quechua",
	5218,
	"qwe",
	"Latn",
	"Tiếng Quechua",
	"Quechua",
}

m["rm"] = {
	"tiếng Romansh",
	13199,
	"roa-rhe",
	"Latn",
	"Tiếng Romansh",
	"Romansh",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.small_e},
}

m["ro"] = {
	"tiếng Rumani",
	7913,
	"roa-eas",
	"Latn, Cyrl",
	"Tiếng Rumani",
	"Rumani",
	translit = {Cyrl = "ro-translit"},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute,
			from = {"ă", "â", "î", "ș", "ț"},
			to = {"a" .. p[1], "a" .. p[2], "i" .. p[1], "s" .. p[1], "t" .. p[1]}
		},
		Cyrl = {
			from = {"ӂ"},
			to = {"ж" .. p[1]}
		},
	},
	standardChars = {
		Latn = "AaĂăÂâBbCcDdEeFfGgHhIiÎîJjLlMmNnOoPpRrSsȘșTtȚțUuVvXxZz",
		Cyrl = "АаБбВвГгДдЕеЖжӁӂЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЫыЬьЭэЮюЯя",
		c.punc
	},
}

m["ru"] = {
	"tiếng Nga",
	7737,
	"zle",
	"Cyrl, Brai",
	"Tiếng Nga",
	"Nga",
	ancestors = "zle-mru",
	translit = {
		Cyrl = "ru-translit"
	},
	display_text = {
		Cyrl = {
			from = {"'"},
			to = {"’"}
		},
	},
	strip_diacritics = {
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.diaer,
			remove_exceptions = {"Ё", "ё", "Ѣ̈", "ѣ̈", "Я̈", "я̈"},
			from = {"’"},
			to = {"'"},
		},
	},
	sort_key = {
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.diaer,
			from = {
				"і", "ѣ", "ѳ", "ѵ"
			},
			to = {
				"и" .. p[1], "ь" .. p[1], "я" .. p[2], "я" .. p[3]
			}
		},
	},
	standard_chars = {
		Cyrl = "АаБбВвГгДдЕеЁёЖжЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЪъЫыЬьЭэЮюЯя—",
		Brai = c.braille,
		(c.punc:gsub("'", "")) -- Exclude apostrophe.
	},
}

m["rw"] = {
	"Rwanda-Rundi",
	3217514,
	"bnt-glb",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.circ .. c.macron .. c.caron},
}

m["sa"] = {
	"tiếng Phạn",
	11059,
	"inc",
	"as-Beng, Bali, Beng, Bhks, Brah, Mymr, xwo-Mong, Deva, Gujr, Guru, Gran, Hani, Java, Kthi, Knda, Kawi, Khar, Khmr, Laoo, Mlym, mnc-Mong, Marc, Modi, Mong, Nand, Newa, Orya, Phag, Ranj, Saur, Shrd, Sidd, Sinh, Soyo, Lana, Takr, Taml, Tang, Telu, Thai, Tibt, Tutg, Tirh, Zanb", --and also Khom; script codes sorted by canonical name rather than code for [[MOD:sa-convert]]
	"Tiếng Phạn",
	"Phạn",
translit = {
		Beng = "sa-Beng-translit",
		["as-Beng"] = "sa-Beng-translit",
		-- Brah translit in [[Module:scripts/data]]
		Deva = "sa-translit",
		Gujr = "sa-Gujr-translit",
		Guru = "sa-Guru-translit",
		Java = "sa-Java-translit",
		Kthi = "sa-Kthi-translit",
		Khmr = "pi-translit",
		Knda = "sa-Knda-translit",
		Lana = "pi-translit",
		Laoo = "pi-translit",
		Mlym = "sa-Mlym-translit",
		Modi = "sa-Modi-translit",
		-- Mong, mnc-Mong, xwo-Mong translit in [[Module:scripts/data]]
		-- NOTE: Formerly used xal-translit for transliterating xwo-Mong but that only handles Cyrillic; it has
		-- code to transliterate xwo-Mong but it's broken so I've replaced it with the default xwo-translit.
		Mymr = "pi-translit",
		Orya = "sa-Orya-translit",
		-- Shrd translit in [[Module:scripts/data]]
		-- Sidd translit in [[Module:scripts/data]]
		Sinh = "si-translit",
		Taml = "sa-Taml-translit",
		Telu = "sa-Telu-translit",
		Thai = "pi-translit",
		-- Tibt translit in [[Module:scripts/data]]
	},
	-- Mong display_text and strip_diacritics in [[Module:scripts/data]]
	-- Tibt display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	strip_diacritics = {
		Deva = s["sa-Deva-stripdiacritics"],
		Mymr = {
			remove_diacritics = c.VS01,
		},
		Thai = {
			from = {"ึ", u(0xF700), u(0xF70F)}, -- FIXME: Not clear what's going on with the PUA characters here.
			to = {"ิํ", "ฐ", "ญ"}
		},
	},
	sort_key = {
		Deva = s["sa-Deva-stripdiacritics"], -- until we have a proper Sanskrit sorting algorithm.
		Lana = { -- Tai Tham
			from = {"ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ"},
			to = {"ᩈ᩠ᩈ", "᩠ᩁ", "᩠ᩃ", "ᨦ᩠", "%1᩠ᨮ", "%1᩠ᨻ", "ᩣ"},
		},
		Laoo = "Laoo-sortkey",
		Latn = {
			from = {"ā", "ī", "ū", "ḍ", "ḷ", "ḹ", "m[" .. c.dotabove .. c.dotbelow .. "]", "ṅ", "ñ", "ṇ", "ṛ", "ṝ", "ś", "ṣ", "ṭ"},
			to = {"a~", "i~", "u~", "d~", "l~", "l~~", "m~", "n~", "n~~", "n~~~", "r~", "r~~", "s~", "s~~", "t~"},
		},
		Mymr = {
			remove_diacritics = c.VS01,
		},
		Thai = "Thai-sortkey",
		-- FIXME: The previous sort key which mixed all scripts removed ZWJ; I don't know which script(s) this was
		-- intended for and there are no other languages which remove it in the sort key AFAIK. If it needs to be
		-- removed, specify the script(s) it needs to be removed under or add handling for the "all" script that applies
		-- regardless of script.
		--all = {
		--	remove_diacritics = c.ZWJ,
		--},
	},
}

m["sc"] = {
	"tiếng Sardegna",
	33976,
	"roa",
	"Latn",
	"Tiếng Sardegna",
	"Sardegna",
}

m["sd"] = {
	"tiếng Sindh",
	33997,
	"inc-snd",
	"sd-Arab, Deva, Sind, Khoj",
	"Tiếng Sindh",
	"Sindh",
	ancestors = "pra",
	translit = {
		Sind = "Sind-translit",
		["sd-Arab"] = "sd-Arab-translit"
	},
	strip_diacritics = {
		["sd-Arab"] = {
			remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
			from = {"ٱ"},
			to = {"ا"}
		},
	},
}

m["se"] = {
	"tiếng Bắc Sami",
	33947,
	"smi",
	"Latn",
	"Tiếng Bắc Sami",
	"Bắc Sami",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	strip_diacritics = {remove_diacritics = c.macron .. c.dotbelow .. "'ˈ"},
	sort_key = {
		from = {"á", "č", "đ", "ŋ", "š", "ŧ", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "d" .. p[1], "n" .. p[1], "s" .. p[1], "t" .. p[1], "z" .. p[1]}
	},
	standard_chars = "AaÁáBbCcČčDdĐđEeFfGgHhIiJjKkLlMmNnŊŋOoPpRrSsŠšTtŦŧUuVvZzŽž" .. c.punc,
}

m["sg"] = {
	"tiếng Sango",
	33954,
	"crp",
	"Latn",
	ancestors = "ngb",
	"Tiếng Sango",
	"Sango",
}

m["sh"] = {
	"tiếng Serbia-Croatia",
	9301,
	"zls",
	"Latn, Cyrl, Glag, Arab",
	ietf_subtag = "hbs", -- ISO 639-3 code, since "sh" is deprecated from ISO 639-1
	wikimedia_codes = "sh, bs, hr, sr",
	strip_diacritics = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"Ć", "ć", "Ś", "ś", "Ź", "ź"}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"З́", "з́", "С́", "с́"}
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"ć", "ś", "ź"},
			from = {"č", "ć", "dž", "đ", "lj", "nj", "š", "ś", "ž", "ź"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "l" .. p[1], "n" .. p[1], "s" .. p[1], "s" .. p[2], "z" .. p[1], "z" .. p[2]}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"з́", "с́"},
			from = {"ђ", "з́", "ј", "љ", "њ", "с́", "ћ", "џ"},
			to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "с" .. p[1], "т" .. p[1], "ч" .. p[1]}
		},
	},
	standard_chars = {
		Latn = "AaBbCcČčĆćDdĐđEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšTtUuVvZzŽž",
		Cyrl = "АаБбВвГгДдЂђЕеЖжЗзИиЈјКкЛлЉљМмНнЊњОоПпРрСсТтЋћУуФфХхЦцЧчЏџШш",
		c.punc
	},
}

m["si"] = {
	"tiếng Sinhala",
	13267,
	"inc-ins",
	"Sinh",
	"Tiếng Sinhala",
	"Sinhala",
	translit = "si-translit",
	override_translit = true,
}

m["sk"] = {
	"tiếng Slovak",
	9058,
	"zlw",
	"Latn",
	"Tiếng Slovak",
	"Slovak",
	ancestors = "zlw-osk,sla-pro",
	sort_key = {remove_diacritics = c.acute .. c.circ .. c.diaer},
	standardChars = "AaÁáÄäBbCcČčDdĎďEeFfGgHhIiÍíJjKkLlĹĺĽľMmNnŇňOoÔôPpRrŔŕSsŠšTtŤťUuÚúVvYyÝýZzŽž" .. c.punc,
}

m["sl"] = {
	"tiếng Slovene",
	9063,
	"zls",
	"Latn",
	"Tiếng Slovene",
	"Slovene",
	strip_diacritics = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.dgrave .. c.invbreve .. c.dotbelow,
		remove_exceptions = {"Ć", "ć", "Ǵ", "ǵ", "Ś", "ś", "Ź", "ź"},
		from = {"Ə", "ə", "Ł", "ł"},
		to = {"E", "e", "L", "l"},
	},
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.dotabove .. c.ringabove .. c.dgrave .. c.invbreve .. c.dotbelow .. c.ringbelow .. c.ogonek,
		remove_exceptions = {"ć", "ǵ", "ś", "ź"},
		from = {"ä", "č", "ć", "đ", "ə", "ë", "ǧ", "ǵ", "ï", "ł", "ö", "š", "ś", "ü", "ž", "ź"},
		to = {"a" .. p[1], "c" .. p[1], "c" .. p[2], "d" .. p[1], "e", "e" .. p[1], "g" .. p[1], "g" .. p[2], "i" .. p[1], "l", "o" .. p[1], "s" .. p[1], "s" .. p[2], "u" .. p[1], "z" .. p[1], "z" .. p[2]},
	},
	standard_chars = "AaBbCcČčDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšTtUuVvZzŽž" .. c.punc,
}

m["sm"] = {
	"tiếng Samoa",
	34011,
	"poz-pnp",
	"Latn",
	"Tiếng Samoa",
	"Samoa",
}

m["sn"] = {
	"tiếng Shona",
	34004,
	"bnt-sho",
	"Latn",
	"Tiếng Shona",
	"Shona",
	strip_diacritics = {remove_diacritics = c.acute},
}

m["so"] = {
	"tiếng Somali",
	13275,
	"cus-som",
	"Latn, Arab, Osma",
    "Tiếng Somali",
    "Somali",
	strip_diacritics = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}
	},
}

m["sq"] = {
	"tiếng Albani",
	8748,
	"sqj",
	"Latn, Grek, ota-Arab, Elba, Todr, Vith",
	"Tiếng Albani",
	"Albani",
	translit = {Elba = "Elba-translit"},
	entry_name = {Latn = {
		remove_diacritics = c.acute,
		from = {'^i (%w)', '^të (%w)'}, to = {'%1', '%1'},
	}},
	sort_key = {Latn = {
		remove_diacritics = c.acute .. c.circ .. c.tilde .. c.breve .. c.caron,
		from = {'ç', 'dh', 'ë', 'gj', 'll', 'nj', 'rr', 'sh', 'th', 'xh', 'zh'},
		to = {'c'..p[1], 'd'..p[1], 'e'..p[1], 'g'..p[1], 'l'..p[1], 'n'..p[1], 'r'..p[1], 's'..p[1], 't'..p[1], 'x'..p[1], 'z'..p[1]},
	}},
	standardChars = "AaBbCcÇçDdEeËëFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvXxYyZz" .. c.punc,
}

m["ss"] = {
	"tiếng Swazi",
	34014,
	"bnt-ngu",
	"Latn",
	"Tiếng Swazi",
	"Swazi",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["st"] = {
	"tiếng Sotho",
	34340,
	"bnt-sts",
	"Latn",
	"Tiếng Sotho",
	"Sotho",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["su"] = {
	"tiếng Sunda",
	34002,
	"poz-msa",
	"Latn, Sund",
	"Tiếng Sunda",
	"Sunda",
	ancestors = "osn",
	translit = {Sund = "su-translit"},
}

m["sv"] = {
	"tiếng Thụy Điển",
	9027,
	"gmq-eas",
	"Latn",
	"Tiếng Thụy Điển",
	"Thụy Điển",
	ancestors = "gmq-osw-lat",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.dacute .. c.caron .. c.cedilla .. "':",
		remove_exceptions = {"å"},
		from = {"ø", "æ", "œ", "ß", "å", "aͤ", "oͤ"},
		to = {"o", "ae", "oe", "ss", "z" .. p[1], "ä", "ö"}
	},
	standardChars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvXxYyÅåÄäÖö" .. c.punc,
}

m["sw"] = {
	"tiếng Swahili",
	7838,
	"bnt-swh",
	"Latn, Arab",
	"Tiếng Swahili",
	"Swahili",
	sort_key = {
		Latn = {
			from = {"ng'"},
			to = {"ng" .. p[1]}
		},
	},
}

m["ta"] = {
	"tiếng Tamil",
	5885,
	"dra-tam",
	"Taml",
	"Tiếng Tamil",
	"Tamil",
	ancestors = "ta-mid",
	translit = "ta-translit",
	override_translit = true,
}

m["te"] = {
	"tiếng Telugu",
	8097,
	"dra-tel",
	"Telu",
	"Tiếng Telugu",
	"Telugu",
	translit = "te-translit",
	override_translit = true,
}

m["tg"] = {
	"tiếng Tajik",
	9260,
	"ira-swi",
	"Cyrl, fa-Arab, Latn",
	"Tiếng Tajik",
	"Tajik",
	ancestors = "fa-cls",
	translit = {
		Cyrl = "tg-translit"
	},
	override_translit = true,
	strip_diacritics = {
		Cyrl = s["tg-stripdiacritics"],
		Latn = s["tg-stripdiacritics"],
	},
	sort_key = {
		Cyrl = {
			from = {"ғ", "ё", "ӣ", "қ", "ӯ", "ҳ", "ҷ"},
			to = {"г" .. p[1], "е" .. p[1], "и" .. p[1], "к" .. p[1], "у" .. p[1], "х" .. p[1], "ч" .. p[1]}
		},
	},
}

m["th"] = {
	"tiếng Thái",
	9217,
	"tai-swe",
	"Thai, Khomt, Brai",
	"Tiếng Thái",
	"Thái",
	translit = {
		Thai = "th-translit"
	},
	sort_key = {
		Thai = "Thai-sortkey"
	},
}

m["ti"] = {
	"tiếng Tigrinya",
	34124,
	"sem-eth",
	"Ethi",
	"Tiếng Tigrinya",
	"Tigrinya",
	translit = "Ethi-translit",
}

m["tk"] = {
	"tiếng Turkmen",
	9267,
	"trk-ogz",
	"Latn, Cyrl, Arab",
	"Tiếng Turkmen",
	"Turkmen",
	strip_diacritics = {
		Latn = s["tk-stripdiacritics"],
		Cyrl = s["tk-stripdiacritics"],
	},
	sort_key = {
		Latn = {
			from = {"ç", "ä", "ž", "ň", "ö", "ş", "ü", "ý"},
			to = {"c" .. p[1], "e" .. p[1], "j" .. p[1], "n" .. p[1], "o" .. p[1], "s" .. p[1], "u" .. p[1], "y" .. p[1]}
		},
		Cyrl = {
			from = {"ё", "җ", "ң", "ө", "ү", "ә"},
			to = {"е" .. p[1], "ж" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1], "э" .. p[1]}
		},
	},
}

m["tl"] = {
	"tiếng Tagalog",
	34057,
	"phi",
	"Latn, Tglg",
	"Tiếng Tagalog",
	"Tagalog",
	translit = {
		Tglg = "tl-translit"
	},
	override_translit = true,
	strip_diacritics = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}
	},
	standard_chars = {
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
	sort_key = {
		Latn = "tl-sortkey",
	},
}

m["tn"] = {
	"tiếng Tswana",
	34137,
	"bnt-sts",
	"Latn",
	"Tiếng Tswana",
	"Tswana",
}

m["to"] = {
	"tiếng Tonga",
	34094,
	"poz-pol",
	"Latn",
	"Tiếng Tonga",
	"Tonga",
	strip_diacritics = {remove_diacritics = c.acute},
	sort_key = {remove_diacritics = c.macron},
}

m["tr"] = {
	"tiếng Thổ Nhĩ Kỳ",
	256,
	"trk-ogz",
	"Latn",
	"Tiếng Thổ Nhĩ Kỳ",
	"Thổ Nhĩ Kỳ",
	ancestors = "ota",
	dotted_dotless_i = true,
	sort_key = {
		from = {
			-- Ignore circumflex, but account for capital Î wrongly becoming ı + circ due to dotted dotless I logic.
			"ı" .. c.circ, c.circ,
			"i", -- Ensure "i" comes after "ı".
			"ç", "ğ", "ı", "ö", "ş", "ü"
		},
		to = {
			"i", "",
			"i" .. p[1],
			"c" .. p[1], "g" .. p[1], "i", "o" .. p[1], "s" .. p[1], "u" .. p[1]
		}
	},
	standard_chars = "AaÂâBbCcÇçDdEeFfGgĞğHhIıİiÎîJjKkLlMmNnOoÖöPpRrSsŞşTtUuÛûÜüVvYyZz" .. c.punc,
}

m["ts"] = {
	"tiếng Tsonga",
	34327,
	"bnt-tsr",
	"Latn",
	"Tiếng Tsonga",
	"Tsonga",
}

m["tt"] = {
	"tiếng Tatar",
	25285,
	"trk-kbu",
	"Cyrl, Latn, tt-Arab",
    "Tiếng Tatar",
    "Tatar",
	translit = {
		Cyrl = "tt-translit",
		["tt-Arab"] = "tt-translit"
	},
	--override_translit = true, -- enable override until Module code can detect Russian loans such as [[аэропорт]]
	dotted_dotless_i = true,
	sort_key = {
		Cyrl = {
			from = {"ә", "ў", "ғ", "ё", "җ", "қ", "ң", "ө", "ү", "һ"},
			to = {"а" .. p[1], "в" .. p[1], "г" .. p[1], "е" .. p[1], "ж" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1], "х" .. p[1]}
		},
		Latn = {
			from = {
				"i", -- Ensure "i" comes after "ı".
				"ä", "ə", "ç", "ğ", "ı", "ñ", "ŋ", "ö", "ɵ", "ş", "ü"
			},
			to = {
				"i" .. p[1],
				"a" .. p[1], "a" .. p[2], "c" .. p[1], "g" .. p[1], "i", "n" .. p[1], "n" .. p[2], "o" .. p[1], "o" .. p[2], "s" .. p[1], "u" .. p[1]
			}
		},
	},
}

-- "tw" IS TREATED AS "ak", SEE WT:LT

m["ty"] = {
	"tiếng Tahiti",
	34128,
	"poz-pep",
	"Latn",
	"Tiếng Tahiti",
	"Tahiti",
}

m["ug"] = {
	"tiếng Duy Ngô Nhĩ",
	13263,
	"trk-kar",
	"ug-Arab, Latn, Cyrl",
	"Tiếng Duy Ngô Nhĩ",
	"Duy Ngô Nhĩ",
	ancestors = "chg",
	translit = {
		["ug-Arab"] = "ug-translit",
		Cyrl = "ug-translit",
	},
	override_translit = true,
}

m["uk"] = {
	"tiếng Ukraina",
	8798,
	"zle",
	"Cyrl",
	"Tiếng Ukraina",
	"Ukraina",
	ancestors = "zle-ouk",
	translit = "uk-translit",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute},
	sort_key = {
		remove_diacritics = c.grave .. c.acute,
		from = {
			"ї", -- 2 chars
			"ґ", "є", "і" -- 1 char
		},
		to = {
			"и" .. p[2],
			"г" .. p[1], "е" .. p[1], "и" .. p[1]
		}
	},
	standard_chars = "АаБбВвГгДдЕеЄєЖжЗзИиІіЇїЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЬьЮюЯя" .. c.punc:gsub("'", ""),  -- Exclude apostrophe.
}

m["ur"] = {
	"tiếng Urdu",
	1617,
	"inc-hnd",
	"ur-Arab",
    "Tiếng Urdu",
    "Urdu",
	translit = {["ur-Arab"] = "ur-translit"},
	entry_name = {
		-- character "ۂ" code U+06C2 to "ه" and "هٔ"‎ (U+0647 + U+0654) to "ه"; hamzatu l-waṣli to a regular alif
		from = {"هٔ", "ۂ", "ٱ"},
		to = {"ہ", "ہ", "ا"},
		remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna .. c.superalef
	},
	-- put Judeo-Urdu (Hebrew-script Urdu) under the category header
	-- U+FB21 HEBREW LETTER WIDE ALEF so that it sorts after Arabic script titles
	sort_key = {
		from = {"^%f[" .. u(0x5D0) .. "-" .. u(0x5EA) .. "]"},
		to = {u(0xFB21)},
	},
}

m["uz"] = {
	"tiếng Uzbek",
	9264,
	"trk-kar",
	"Latn, Cyrl, fa-Arab",
	"Tiếng Uzbek",
	"Uzbek",
	ancestors = "chg",
	translit = {
		Cyrl = "uz-translit"
	},
	sort_key = {
		Latn = {
			from = {"oʻ", "gʻ", "sh", "ch", "ng"},
			to = {"z" .. p[1], "z" .. p[2], "z" .. p[3], "z" .. p[4], "z" .. p[5]}
		},
		Cyrl = {
			from = {"ё", "ў", "қ", "ғ", "ҳ"},
			to = {"е" .. p[1], "я" .. p[1], "я" .. p[2], "я" .. p[3], "я" .. p[4]}
		},
	},
	strip_diacritics = {
		["fa-Arab"] = "ar-stripdiacritics",
	},
}

m["ve"] = {
	"tiếng Venda",
	32704,
	"bnt-bso",
	"Latn",
	"Tiếng Venda",
	"Venda",
}

m["vi"] = {
	"tiếng Việt",
	9199,
	"mkh-vie",
	"Latn, Hani",
	"Tiếng Việt",
	"Việt",
	ancestors = "mkh-mvi",
	sort_key = {
		Latn = "vi-sortkey",
		Hani = "Hani-sortkey",
	},
}

m["vo"] = {
	"tiếng Volapük",
	36986,
	"art",
	"Latn",
	"Tiếng Volapük",
	"Volapük",
}

m["wa"] = {
	"tiếng Wallon",
	34219,
	"roa-oil",
	"Latn",
    "Tiếng Wallon",
    "Wallon",
	sort_key = s["roa-oil-sortkey"],
}

m["wo"] = {
	"tiếng Wolof",
	34257,
	"alv-fwo",
	"Latn, Arab, Gara",
	"Tiếng Wolof",
	"Wolof",
}

m["xh"] = {
	"tiếng Xhosa",
	13218,
	"bnt-ngu",
	"Latn",
	"Tiếng Xhosa",
	"Xhosa",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["yi"] = {
	"tiếng Yiddish",
	8641,
	"gmw-hgm",
	"Hebr",
	"Tiếng Yiddish",
	"Yiddish",
	ancestors = "gmh",
	translit = "yi-translit",
	sort_key = {
		from = {"א[ַָ]", "בּ", "ו[ֹּ]", "יִ", "ײַ", "פֿ"},
		to = {"א", "ב", "ו", "י", "יי", "פ"}
	},
}

m["yo"] = {
	"tiếng Yoruba",
	34311,
	"alv-yor",
	"Latn, Arab",
	"Tiếng Yoruba",
	"Yoruba",
	strip_diacritics = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.macron}
	},
	sort_key = {
		Latn = {
			from = {"ẹ", "ɛ", "gb", "ị", "kp", "ọ", "ɔ", "ṣ", "sh", "ụ"},
			to = {"e" .. p[1], "e" .. p[1], "g" .. p[1], "i" .. p[1], "k" .. p[1], "o" .. p[1], "o" .. p[1], "s" .. p[1], "s" .. p[1], "u" .. p[1]}
		},
	},
}

m["za"] = {
	"tiếng Tráng",
	13216,
	"tai",
	"Latn, Hani",
	"Tiếng Tráng",
	"Tráng",
	sort_key = {
		Latn = "za-sortkey",
		Hani = "Hani-sortkey",
	},
}

m["zh"] = {
	"tiếng Trung Quốc",
	7850,
	"zhx",
	"Hants, Latn, Bopo, Nshu, Brai",
	"Tiếng Trung Quốc",
	"Trung Quốc",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = {
		Hani = "zh-translit",
		Bopo = "zh-translit",
	},
	sort_key = {Hani = "Hani-sortkey"},
}

m["zu"] = {
	"tiếng Zulu",
	10179,
	"bnt-ngu",
	"Latn",
	"Tiếng Zulu",
	"Zulu",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

return require("Module:languages").finalizeData(m, "language")