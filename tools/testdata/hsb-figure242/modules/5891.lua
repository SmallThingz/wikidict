local m_langdata = require("Modul:languages/data")

-- Loaded on demand, as it may not be needed (depending on the data).
local function u(...)
	u = require("Modul:string utilities").char
	return u(...)
end

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

-- Ideally, we want to move these into [[Modul:languages/data]], but because (a) it's necessary to use require on that module, and (b) they're only used in this data module, it's less memory-efficient to do that at the moment. If it becomes possible to use mw.loadData, then these should be moved there.
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
	"afaršćina",
	27811,
	"cus-eas",
	"Latn, Ethi",
	entry_name = {
		Latn = {remove_diacritics = c.acute},
	},
}

m["ab"] = {
	"abchazšćina",
	5111,
	"cau-abz",
	"Cyrl, Geor, Latn",
	translit = {
		Cyrl = "ab-translit",
		Geor = "Geor-translit",
	},
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"]
	},
	entry_name = {
		Cyrl = {
			remove_diacritics = c.acute,
			from =  {"^а%-"},
			to = {"а"},
		},
		Latn = s["cau-Latn-entryname"],
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
	"awesćišćina",
	29572,
	"ira-cen",
	"Avst, Gujr",
	translit = {
		Avst = "Avst-translit"
	},
}

m["af"] = {
	"afrikaanšćina",
	14196,
	"gmw-frk",
	"Latn, Arab",
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
	"akanšćina",
	28026,
	"alv-ctn",
	"Latn",
}

m["am"] = {
	"amharšćina",
	28244,
	"sem-eth",
	"Ethi",
	translit = "Ethi-translit",
}

m["an"] = {
	"aragonšćina",
	8765,
	"roa-nar",
	"Latn",
}

m["ar"] = {
	"arabišćina",
	13955,
	"sem-arb",
	"Arab, Hebr, Syrc, Brai",
	translit = {
		Arab = "ar-translit"
	},
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		Arab = "ar-entryname",
		Hebr = "Hebr-common",
	},
	sort_key = {
		Hebr = "Hebr-common",
	},
}

m["as"] = {
	"asamšćina",
	29401,
	"inc-bas",
	"as-Beng",
	ancestors = "inc-mas",
	translit = "as-translit",
}

m["av"] = {
	"awaršćina",
	29561,
	"cau-ava",
	"Cyrl, Latn, Arab",
	ancestors = "oav",
	translit = {
		Cyrl = "cau-nec-translit",
		Arab = "ar-translit",
	},
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"],
	},
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
	"aymaršćina",
	4627,
	"sai-aym",
	"Latn",
}

m["az"] = {
	"azerbajdźanšćina",
	9292,
	"trk-ogz",
	"Latn, Cyrl, fa-Arab",
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
	"baškoršćina",
	13389,
	"trk-kbu",
	"Cyrl",
	translit = "ba-translit",
	override_translit = true,
	sort_key = {
		from = {"ғ", "ҙ", "ё", "ҡ", "ң", "ө", "ҫ", "ү", "һ", "ә"},
		to = {"г" .. p[1], "д" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "с" .. p[1], "у" .. p[1], "х" .. p[1], "э" .. p[1]}
	},
}

m["be"] = {
	"běłorušćina",
	9091,
	"zle",
	"Cyrl, Latn",
	ancestors = "zle-obe",
	translit = {
		Cyrl = "be-translit",
	},
	entry_name = {
		Cyrl = {
			remove_diacritics = c.grave .. c.acute,
		},
		Latn = {
			remove_diacritics = c.grave .. c.acute,
			remove_exceptions = {"Ć", "ć", "Ń", "ń", "Ś", "ś", "Ź", "ź"},
		},
	},
	sort_key = {
		Cyrl = {
			remove_diacritics = c.grave .. c.acute,
			from = {"ґ", "ё", "і", "ў"},
			to = {"г" .. p[1], "е" .. p[1], "и" .. p[1], "у" .. p[1]}
		},
		Latn = {
			remove_diacritics = c.grave .. c.acute,
			remove_exceptions = {"Ć", "ć", "Ń", "ń", "Ś", "ś", "Ź", "ź"},
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
	"bołharšćina",
	7918,
	"zls",
	"Cyrl",
	ancestors = "cu-bgm",
	translit = "bg-translit",
	entry_name = {
		remove_diacritics = c.grave .. c.acute,
		remove_exceptions = {"%f[^%z%s]ѝ%f[%z%s]"},
	},
	sort_key = {
		remove_diacritics = c.grave .. c.acute,
		remove_exceptions = {"%f[^%z%s]ѝ%f[%z%s]"},
	},
	standardChars = "АаБбВвГгДдЕеЖжЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЪъЬьЮюЯя" .. c.punc,
}

m["bh"] = {
	"biharšćina",
	135305,
	"inc-eas",
	"Deva",
}

m["bi"] = {
	"bislamšćina",
	35452,
	"crp",
	"Latn",
	ancestors = "en",
}

m["bm"] = {
	"bambaršćina",
	33243,
	"dmn-emn",
	"Latn, Nkoo",
	sort_key = {
		Latn = {
		from = {"ɛ", "ɲ", "ŋ", "ɔ"},
		to = {"e" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1]}
		},
	},
}

m["bn"] = {
	"bengalšćina",
	9610,
	"inc-bas",
	"Beng, Newa",
	ancestors = "inc-mbn",
	translit = {
		Beng = "bn-translit"
	},
}

m["bo"] = {
	"tibetšćina",
	34271,
	"sit-tib",
	"Tibt", -- sometimes Deva?
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["br"] = {
	"bretonšćina",
	12107,
	"cel-brs",
	"Latn",
	ancestors = "xbm",
	sort_key = {
		from = {"ch", "c['ʼ’]h"},
		to = {"c" .. p[1], "c" .. p[2]}
	},
}

m["bs"] = {
	"bosnišćina",
	9303,
	"zls",
	"Latn, Cyrl, Arab",
	entry_name = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"Ć", "ć"}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"ć"},
			from = {"č", "ć", "dž", "đ", "lj", "nj", "š", "ž"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "l" .. p[1], "n" .. p[1], "s" .. p[1], "z" .. p[1]}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			from = {"ђ", "з́", "ј", "љ", "њ", "с́", "ћ", "џ"},
			to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "с" .. p[1], "т" .. p[1], "ч" .. p[1]}
		},
	},
	standardChars = {
		Latn = "AaBbCcČčĆćDdĐđEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšTtUuVvZzŽž",
		Cyrl = "АаБбВвГгДдЂђЕеЖжЗзИиЈјКкЛлЉљМмНнЊњОоПпРрСсТтЋћУуФфХхЦцЧчЏџШш",
		c.punc
	},
}

m["ca"] = {
	"katalanšćina",
	7026,
	"roa-ocr",
	"Latn",
	ancestors = "roa-oca",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.diaer .. c.cedilla,
		from = {"l·l"},
		to = {"ll"}
	},
	standardChars = "AaÀàBbCcÇçDdEeÉéÈèFfGgHhIiÍíÏïJjLlMmNnOoÓóÒòPpQqRrSsTtUuÚúÜüVvXxYyZz·" .. c.punc,
}

m["ce"] = {
	"čečenšćina",
	33350,
	"cau-vay",
	"Cyrl, Latn, Arab",
	translit = {
		Cyrl = "cau-nec-translit",
		Arab = "ar-translit",
	},
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"]
	},
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
	"čamorošćina",
	33262,
	"poz",
	"Latn",
	sort_key = {
		remove_diacritics = "'",
		from = {"å", "ch", "ñ", "ng"},
		to = {"a" .. p[1], "c" .. p[1], "n" .. p[1], "n" .. p[2]}
	},
}

m["co"] = {
	"korsišćina",
	33111,
	"roa-itd",
	"Latn",
	sort_key = {
		from = {"chj", "ghj", "sc", "sg"},
		to = {"c" .. p[1], "g" .. p[1], "s" .. p[1], "s" .. p[2]}
	},
	standardChars = "AaÀàBbCcDdEeÈèFfGgHhIiÌìÏïJjLlMmNnOoÒòPpQqRrSsTtUuÙùÜüVvZz" .. c.punc,
}

m["cr"] = {
	"krišćina",
	33390,
	"alg",
	"Latn, Cans",
	translit = {
		Cans = "cr-translit"
	},
}

m["cs"] = {
	"čěšćina",
	9056,
	"zlw",
	"Latn",
	ancestors = "cs-ear",
	sort_key = {
		from = {"á", "č", "ď", "é", "ě", "ch", "í", "ň", "ó", "ř", "š", "ť", "ú", "ů", "ý", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "d" .. p[1], "e" .. p[1], "e" .. p[2], "h" .. p[1], "i" .. p[1], "n" .. p[1], "o" .. p[1], "r" .. p[1], "s" .. p[1], "t" .. p[1], "u" .. p[1], "u" .. p[2], "y" .. p[1], "z" .. p[1]}
	},
	standardChars = "AaÁáBbCcČčDdĎďEeÉéĚěFfGgHhIiÍíJjKkLlMmNnŇňOoÓóPpRrŘřSsŠšTtŤťUuÚúŮůVvYyÝýZzŽž" .. c.punc,
}

m["cu"] = {
	"starocyrkwinosłowjanšćina",
	35499,
	"zls",
	"Cyrs, Glag",
	translit = {
		Cyrs = "Cyrs-translit",
		Glag = "Glag-translit"
	},
	entry_name = {
		Cyrs = s["Cyrs-entryname"]
	},
	sort_key = {
		Cyrs = s["Cyrs-sortkey"]
	},
}

m["cv"] = {
	"čuwašćina",
	33348,
	"trk-ogr",
	"Cyrl",
	ancestors = "cv-mid",
	translit = "cv-translit",
	override_translit = true,
	sort_key = {
		from = {"ӑ", "ё", "ӗ", "ҫ", "ӳ"},
		to = {"а" .. p[1], "е" .. p[1], "е" .. p[2], "с" .. p[1], "у" .. p[1]}
	},
}

m["cy"] = {
	"kimrišćina",
	9309,
	"cel-brw",
	"Latn",
	ancestors = "wlm",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. "'",
		from = {"ch", "dd", "ff", "ng", "ll", "ph", "rh", "th"},
		to = {"c" .. p[1], "d" .. p[1], "f" .. p[1], "g" .. p[1], "l" .. p[1], "p" .. p[1], "r" .. p[1], "t" .. p[1]}
	},
	standardChars = "ÂâAaBbCcDdEeÊêFfGgHhIiÎîLlMmNnOoÔôPpRrSsTtUuÛûWwŴŵYyŶŷ" .. c.punc,
}

m["da"] = {
	"danšćina",
	9035,
	"gmq-eas",
	"Latn",
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
	"němčina",
	188,
	"gmw-hgm",
	"Latn, Latf, Brai",
	ancestors = "gmh",
	sort_key = {
		Latn = s["de-Latn-sortkey"],
		Latf = s["de-Latn-sortkey"],
	},
	standardChars = {
		Latn = s["de-Latn-standardchars"],
		Latf = s["de-Latn-standardchars"],
		Brai = c.braille,
		c.punc
	}
}

m["dv"] = {
	"maledivšćina",
	32656,
	"inc-ins",
	"Thaa, Diak",
	translit = {
		Thaa = "dv-translit",
		Diak = "Diak-translit",
	},
	override_translit = true,
}

m["dz"] = {
	"Dzongkha",
	33081,
	"sit-tib",
	"Tibt",
	ancestors = "xct",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["ee"] = {
	"Ewe",
	30005,
	"alv-gbe",
	"Latn",
	sort_key = {
		remove_diacritics = c.tilde,
		from = {"ɖ", "dz", "ɛ", "ƒ", "gb", "ɣ", "kp", "ny", "ŋ", "ɔ", "ts", "ʋ"},
		to = {"d" .. p[1], "d" .. p[2], "e" .. p[1], "f" .. p[1], "g" .. p[1], "g" .. p[2], "k" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "t" .. p[1], "v" .. p[1]}
	},
}

m["el"] = {
	"grjekšćina",
	9129,
	"grk",
	"Grek, Polyt, Brai",
	ancestors = "el-kth",
	translit = {
		Grek = "el-translit",
		Polyt = "grc-translit",
	},
	override_translit = true,
	display_text = {
		Grek = s["Grek-displaytext"],
		Polyt = s["Polyt-displaytext"],
	},
	entry_name = {
		Grek = s["Grek-entryname"],
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Grek = s["Grek-sortkey"],
		Polyt = s["Polyt-sortkey"],
	},
	standardChars = {
		Grek = "΅·ͺ΄ΑαΆάΒβΓγΔδΕεέΈΖζΗηΉήΘθΙιΊίΪϊΐΚκΛλΜμΝνΞξΟοΌόΠπΡρΣσςΤτΥυΎύΫϋΰΦφΧχΨψΩωΏώ",
		Brai = c.braille,
		c.punc
	},
}

m["en"] = {
	"jendźelšćina",
	1860,
	"gmw-ang",
	"Latn, Brai, Shaw, Dsrt", -- entries in Shaw or Dsrt might require prior discussion
	wikimedia_codes = "en, simple",
	ancestors = "en-ear",
	sort_key = {
		Latn = {
			-- Many of these are needed for sorting language names.
			remove_diacritics = "'\"%-%.,%s·ʻʼ" .. c.diacritics,
			-- These are found in entry names.
			from = {"[ɒæ🅱¢©ᴄðđəǝɜɡħʜıɨłŋɲøɔœꝑꝓꝕßʋ]"},
			to = {{
				["ɒ"] = "a", ["æ"] = "ae", ["🅱"] = "b", ["¢"] = "c", ["©"] = "c",
				["ᴄ"] = "c", ["ð"] = "d", ["đ"] = "d", ["ə"] = "e", ["ǝ"] = "e",
				["ɜ"] = "e", ["ɡ"] = "g", ["ħ"] = "h", ["ʜ"] = "h", ["ı"] = "i",
				["ɨ"] = "i", ["ł"] = "l", ["ŋ"] = "n", ["ɲ"] = "n", ["ø"] = "o",
				["ɔ"] = "o", ["œ"] = "oe", ["ꝑ"] = "p", ["ꝓ"] = "p", ["ꝕ"] = "p",
				["ß"] = "ss", ["ʋ"] = "v",
			}},
		},
	},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["eo"] = {
	"esperanto",
	143,
	"art",
	"Latn",
	sort_key = {
		remove_diacritics = c.grave .. c.acute,
		from = {"ĉ", "ĝ", "ĥ", "ĵ", "ŝ", "ŭ"},
		to = {"c" .. p[1], "g" .. p[1], "h" .. p[1], "j" .. p[1], "s" .. p[1], "u" .. p[1]}
	},
	standardChars = "AaBbCcĈĉDdEeFfGgĜĝHhĤĥIiJjĴĵKkLlMmNnOoPpRrSsŜŝTtUuŬŭVvZz" .. c.punc,
}

m["es"] = {
	"španišćina",
	1321,
	"roa-cas",
	"Latn, Brai",
	ancestors = "es-ear",
	sort_key = {
		Latn = {
			remove_exceptions = {"ñ"},
			remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.diaer .. c.cedilla,
			from = {"ª", "æ", "ñ", "º", "œ"},
			to = {"a", "ae", "n" .. p[1], "o", "oe"}
		},
	},
	standardChars = {
		Latn = "AaÁáBbCcDdEeÉéFfGgHhIiÍíJjLlMmNnÑñOoÓóPpQqRrSsTtUuÚúÜüVvXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["et"] = {
	"estišćina",
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
	standardChars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvÕõÄäÖöÜü" .. c.punc,
}

m["eu"] = {
	"baskišćina",
	8752,
	"euq",
	"Latn",
	sort_key = {
		from = {"ç", "ñ"},
		to = {"c" .. p[1], "n" .. p[1]}
	},
	standardChars = "AaBbDdEeFfGgHhIiJjKkLlMmNnÑñOoPpRrSsTtUuXxZz" .. c.punc,
}

m["fa"] = {
	"persišćina",
	9168,
	"ira-swi",
	"fa-Arab, Hebr",
	ancestors = "fa-cls",
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		["fa-Arab"] = {
			-- character "ۂ" code U+06C2 to "ه" and "هٔ"‎ (U+0647 + U+0654) to "ه"; hamzatu l-waṣli to a regular alif
			from = {"هٔ", "ٱ"}, -- character "ۂ" code U+06C2 to "ه"; hamzatu l-waṣli to a regular alif
			to = {"ه", "ا"},
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
		},
		Hebr = "Hebr-common",
	},
	sort_key = {
		Hebr = "Hebr-common",
	},
}

m["ff"] = {
	"fulašćina",
	33454,
	"alv-fwo",
	"Latn, Adlm",
}

m["fi"] = {
	"finšćina",
	1412,
	"urj-fin",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"’"}
	},
	entry_name = { -- used to indicate gemination of the next consonant
		remove_diacritics = "ˣ",
		from = {"’"},
		to = {"'"},
	},
	sort_key = { -- [[Appendix:Finnish alphabet#Collation]] + "aͤ" and "oͤ" as historical variants of "ä" and "ö".
		remove_diacritics = "':" .. c.diacritics,
		remove_exceptions = {
			"a[" .. c.ringabove .. c.diaer .. c.small_e .. "]", -- åäaͤ
			"o[" .. c.diaer .. c.tilde .. c.dacute .. c.small_e .. "]", -- öõőoͤ
			"u[" .. c.diaer .. c.dacute .. "]" -- üű
		},
		from = {"æ", "[ðđ]", "ł", "ŋ", "œ", "ß", "þ", "u[" .. c.diaer .. c.dacute .. "]", "å", "aͤ", "o[" .. c.tilde .. c.dacute .. c.small_e .. "]", "ø", "(.)['%-]"},
		to = {"ae", "d", "l", "n", "oe", "ss", "th", "y", "z" .. p[1], "ä", "ö", "ö", "%1"}
	},
	standardChars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvYyÄäÖö" .. c.punc,
}

m["fj"] = {
	"fidźišćina",
	33295,
	"poz-pcc",
	"Latn",
}

m["fo"] = {
	"ferejšćina",
	25258,
	"gmq-ins",
	"Latn",
	sort_key = {
		from = {"á", "ð", "í", "ó", "ú", "ý", "æ", "ø"},
		to = {"a" .. p[1], "d" .. p[1], "i" .. p[1], "o" .. p[1], "u" .. p[1], "y" .. p[1], "z" .. p[1], "z" .. p[2]}
	},
	standardChars = "AaÁáBbDdÐðEeFfGgHhIiÍíJjKkLlMmNnOoÓóPpRrSsTtUuÚúVvYyÝýÆæØø" .. c.punc,
}

m["fr"] = {
	"francošćina",
	150,
	"roa-oil",
	"Latn, Brai",
	display_text = {
		Latn = {
			from = {"'"},
			to = {"’"}
		},
	},
	entry_name = {
		Latn = {
			from = {"’"},
			to = {"'"},
		},
	},
	ancestors = "frm",
	sort_key = {
		Latn = s["roa-oil-sortkey"]
	},
	standardChars = {
		Latn = "AaÀàÂâBbCcÇçDdEeÉéÈèÊêËëFfGgHhIiÎîÏïJjLlMmNnOoÔôŒœPpQqRrSsTtUuÙùÛûÜüVvXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["fy"] = {
	"frizišćina",
	27175,
	"gmw-fri",
	"Latn",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer,
		from = {"y"},
		to = {"i"}
	},
	standardChars = "AaâäàÆæBbCcDdEeéêëèFfGgHhIiïìYyỳJjKkLlMmNnOoôöòPpRrSsTtUuúûüùVvWwZz" .. c.punc,
}

m["ga"] = {
	"irišćina",
	9142,
	"cel-gae",
	"Latn, Latg",
	ancestors = "mga",
	sort_key = {
		remove_diacritics = c.acute,
		from = {"ḃ", "ċ", "ḋ", "ḟ", "ġ", "ṁ", "ṗ", "ṡ", "ṫ"},
		to = {"bh", "ch", "dh", "fh", "gh", "mh", "ph", "sh", "th"}
	},
	standardChars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíLlMmNnOoÓóPpRrSsTtUuÚúVv" .. c.punc,
}

m["gd"] = {
	"šotiska gaelšćina",
	9314,
	"cel-gae",
	"Latn, Latg",
	ancestors = "mga",
	sort_key = {remove_diacritics = c.grave .. c.acute},
	standardChars = "AaÀàBbCcDdEeÈèFfGgHhIiÌìLlMmNnOoÒòPpRrSsTtUuÙù" .. c.punc,
}

m["gl"] = {
	"galicišćina",
	9307,
	"roa-gap",
	"Latn",
	sort_key = {
		remove_diacritics = c.acute,
		from = {"ñ"},
		to = {"n" .. p[1]}
	},
	standardChars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíÏïLlMmNnÑñOoÓóPpQqRrSsTtUuÚúÜüVvXxZz" .. c.punc,
}

m["gn"] = {
	"guaranšćina",
	35876,
	"tup-gua",
	"Latn",
}

m["gu"] = {
	"gudžaratšćina",
	5137,
	"inc-wes",
	"Arab, Gujr",
	ancestors = "inc-mgu",
	translit = {
		Gujr = "gu-translit",
	},
	entry_name = {
		Arab = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.kasra .. c.shadda .. c.sukun},
		Gujr = {remove_diacritics = "઼"},
	},
}

m["gv"] = {
	"mankšćina",
	12175,
	"cel-gae",
	"Latn",
	ancestors = "mga",
	sort_key = {remove_diacritics = c.cedilla .. "-"},
	standardChars = "AaBbCcÇçDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwYy" .. c.punc,
}

m["ha"] = {
	"hawsašćina",
	56475,
	"cdc-wst",
	"Latn, Arab",
	entry_name = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron}
	},
	sort_key = {
		Latn = {
			from = {"ɓ", "b'", "ɗ", "d'", "ƙ", "k'", "sh", "ƴ", "'y"},
			to = {"b" .. p[1], "b" .. p[2], "d" .. p[1], "d" .. p[2], "k" .. p[1], "k" .. p[2], "s" .. p[1], "y" .. p[1], "y" .. p[2]}
		},
	},
}

m["he"] = {
	"hebrejšćina",
	9288,
	"sem-can",
	"Hebr, Phnx, Brai, Samr",
	ancestors = "he-med",
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		Hebr = "Hebr-common",
		Samr = s["Samr-entryname"],
	},
	sort_key = {
		Hebr = "Hebr-common",
		Samr = s["Samr-sortkey"],
	},
}

m["hi"] = {
	"hindišćina",
	1568,
	"inc-hnd",
	"Deva, Kthi, Newa",
	translit = {
		Deva = "hi-translit"
	},
	standardChars = {
		Deva = "अआइईउऊएऐओऔकखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसहत्रज्ञक्षक़ख़ग़ज़झ़ड़ढ़फ़काखागाघाङाचाछाजाझाञाटाठाडाढाणाताथादाधानापाफाबाभामायारालावाशाषासाहात्राज्ञाक्षाक़ाख़ाग़ाज़ाझ़ाड़ाढ़ाफ़ाकिखिगिघिङिचिछिजिझिञिटिठिडिढिणितिथिदिधिनिपिफिबिभिमियिरिलिविशिषिसिहित्रिज्ञिक्षिक़िख़िग़िज़िझ़िड़िढ़िफ़िकीखीगीघीङीचीछीजीझीञीटीठीडीढीणीतीथीदीधीनीपीफीबीभीमीयीरीलीवीशीषीसीहीत्रीज्ञीक्षीक़ीख़ीग़ीज़ीझ़ीड़ीढ़ीफ़ीकुखुगुघुङुचुछुजुझुञुटुठुडुढुणुतुथुदुधुनुपुफुबुभुमुयुरुलुवुशुषुसुहुत्रुज्ञुक्षुक़ुख़ुग़ुज़ुझ़ुड़ुढ़ुफ़ुकूखूगूघूङूचूछूजूझूञूटूठूडूढूणूतूथूदूधूनूपूफूबूभूमूयूरूलूवूशूषूसूहूत्रूज्ञूक्षूक़ूख़ूग़ूज़ूझ़ूड़ूढ़ूफ़ूकेखेगेघेङेचेछेजेझेञेटेठेडेढेणेतेथेदेधेनेपेफेबेभेमेयेरेलेवेशेषेसेहेत्रेज्ञेक्षेक़ेख़ेग़ेज़ेझ़ेड़ेढ़ेफ़ेकैखैगैघैङैचैछैजैझैञैटैठैडैढैणैतैथैदैधैनैपैफैबैभैमैयैरैलैवैशैषैसैहैत्रैज्ञैक्षैक़ैख़ैग़ैज़ैझ़ैड़ैढ़ैफ़ैकोखोगोघोङोचोछोजोझोञोटोठोडोढोणोतोथोदोधोनोपोफोबोभोमोयोरोलोवोशोषोसोहोत्रोज्ञोक्षोक़ोख़ोग़ोज़ोझ़ोड़ोढ़ोफ़ोकौखौगौघौङौचौछौजौझौञौटौठौडौढौणौतौथौदौधौनौपौफौबौभौमौयौरौलौवौशौषौसौहौत्रौज्ञौक्षौक़ौख़ौग़ौज़ौझ़ौड़ौढ़ौफ़ौक्ख्ग्घ्ङ्च्छ्ज्झ्ञ्ट्ठ्ड्ढ्ण्त्थ्द्ध्न्प्फ्ब्भ्म्य्र्ल्व्श्ष्स्ह्त्र्ज्ञ्क्ष्क़्ख़्ग़्ज़्झ़्ड़्ढ़्फ़्।॥०१२३४५६७८९॰",
		c.punc
	},
}

m["ho"] = {
	"hiri motu",
	33617,
	"crp",
	"Latn",
	ancestors = "meu",
}

m["hr"] = {
	"chorwatšćina",
	6654,
	"zls",
	"Latn,",
	entry_name = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"Ć", "ć"}
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"ć"},
			from = {"č", "ć", "dž", "đ", "lj", "nj", "š", "ž"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "l" .. p[1], "n" .. p[1], "s" .. p[1], "z" .. p[1],}
		},
	},
	standardChars = {
		Latn = "AaBbCcČčĆćDdĐđEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšTtUuVvZzŽž",
		c.punc
	},
}

m["ht"] = {
	"haitišćina",
	33491,
	"crp",
	"Latn",
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
	"madźaršćina",
	9067,
	"urj-ugr",
	"Latn, Hung",
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
	"armenšćina",
	8785,
	"hyx",
	"Armn, Brai",
	ancestors = "axm",
	translit = {
		Armn = "Armn-translit"
	},
	override_translit = true,
	entry_name = {
		Armn = {
			remove_diacritics = "՛՜՞՟",
			from = {"եւ", "<sup>յ</sup>", "<sup>ի</sup>", "<sup>է</sup>", "յ̵", "ՙ", "՚"},
			to = {"և", "յ", "ի", "է", "ֈ", "ʻ", "’"}
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
	"herero",
	33315,
	"bnt-swb",
	"Latn",
}

m["ia"] = {
	"interlingua",
	35934,
	"art",
	"Latn",
}

m["id"] = {
	"indonešćina",
	9240,
	"poz-mly",
	"Latn",
	ancestors = "ms",
	standardChars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz" .. c.punc,
}

m["ie"] = {
	"interlingue",
	35850,
	"art",
	"Latn",
	type = "appendix-constructed",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ},
}

m["ig"] = {
	"igbo",
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
	"sečuanska jišćina",
	34235,
	"tbq-nlo",
	"Yiii",
	translit = "ii-translit",
}

m["ik"] = {
	"inupiak",
	27183,
	"esx-inu",
	"Latn",
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
	"ido",
	35224,
	"art",
	"Latn",
}

m["is"] = {
	"islandšćina",
	294,
	"gmq-ins",
	"Latn",
	sort_key = {
		from = {"á", "ð", "é", "í", "ó", "ú", "ý", "þ", "æ", "ö"},
		to = {"a" .. p[1], "d" .. p[1], "e" .. p[1], "i" .. p[1], "o" .. p[1], "u" .. p[1], "y" .. p[1], "z" .. p[1], "z" .. p[2], "z" .. p[3]}
	},
	standardChars = "AaÁáBbDdÐðEeÉéFfGgHhIiÍíJjKkLlMmNnOoÓóPpRrSsTtUuÚúVvXxYyÝýÞþÆæÖö" .. c.punc,
}

m["it"] = {
	"italšćina",
	652,
	"roa-itd",
	"Latn",
	ancestors = "roa-oit",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.ringabove},
	standardChars = "AaÀàBbCcDdEeÈèÉéFfGgHhIiÌìLlMmNnOoÒòPpQqRrSsTtUuÙùVvZz" .. c.punc,
}

m["iu"] = {
	"inuktitušćina",
	29921,
	"esx-inu",
	"Cans, Latn",
	translit = {
		Cans = "cr-translit"
	},
	override_translit = true,
}

m["ja"] = {
	"japanšćina",
	5287,
	"jpx",
	"Jpan, Latn, Brai",
	ancestors = "ja-ear",
	translit = s["jpx-translit"],
	link_tr = true,
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["jv"] = {
	"jawanšćina",
	33549,
	"poz",
	"Latn, Java",
	ancestors = "kaw",
	translit = {
		Java = "jv-translit"
	},
	link_tr = true,
	entry_name = {
		Latn = {remove_diacritics = c.circ} -- Modern jv don't use ê
	},
	sort_key = {
		Latn = {
			from = {"å", "dh", "é", "è", "ng", "ny", "th"},
			to = {"a" .. p[1], "d" .. p[1], "e" .. p[1], "e" .. p[2], "n" .. p[1], "n" .. p[2], "t" .. p[1]}
		},
	},
}

m["ka"] = {
	"georgšćina",
	8108,
	"ccs-gzn",
	"Geor, Geok, Hebr", -- Hebr is used to write Judeo-Georgian
	ancestors = "ka-mid",
	translit = {
		Geor = "Geor-translit",
		Geok = "Geok-translit",
	},
	override_translit = true,
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		Geor = s["ka-entryname"],
		Geok = s["ka-entryname"],
		Hebr = "Hebr-common",
	},
	sort_key = {
		Hebr = "Hebr-common",
	}
}

m["kg"] = {
	"kongošćina",
	33702,
	"bnt-kng",
	"Latn",
}

m["ki"] = {
	"kikujušćina",
	33587,
	"bnt-kka",
	"Latn",
}

m["kj"] = {
	"kuanjamšćina",
	1405077,
	"bnt-ova",
	"Latn",
}

m["kk"] = {
	"kazachšćina",
	9252,
	"trk-kno",
	"Cyrl, Latn, kk-Arab",
	translit = {
		Cyrl = {
			from = {
				"Ё", "ё", "Й", "й", "Нг", "нг", "Ӯ", "ӯ", -- 2 chars; are "Ӯ" and "ӯ" actually used?
				"А", "а", "Ә", "ә", "Б", "б", "В", "в", "Г", "г", "Ғ", "ғ", "Д", "д", "Е", "е", "Ж", "ж", "З", "з", "И", "и", "К", "к", "Қ", "қ", "Л", "л", "М", "м", "Н", "н", "Ң", "ң", "О", "о", "Ө", "ө", "П", "п", "Р", "р", "С", "с", "Т", "т", "У", "у", "Ұ", "ұ", "Ү", "ү", "Ф", "ф", "Х", "х", "Һ", "һ", "Ц", "ц", "Ч", "ч", "Ш", "ш", "Щ", "щ", "Ъ", "ъ", "Ы", "ы", "І", "і", "Ь", "ь", "Э", "э", "Ю", "ю", "Я", "я", -- 1 char
			},
			to = {
				"E", "e", "İ", "i", "Ñ", "ñ", "U", "u",
				"A", "a", "Ä", "ä", "B", "b", "V", "v", "G", "g", "Ğ", "ğ", "D", "d", "E", "e", "J", "j", "Z", "z", "İ", "i", "K", "k", "Q", "q", "L", "l", "M", "m", "N", "n", "Ñ", "ñ", "O", "o", "Ö", "ö", "P", "p", "R", "r", "S", "s", "T", "t", "U", "u", "Ū", "ū", "Ü", "ü", "F", "f", "X", "x", "H", "h", "S", "s", "Ç", "ç", "Ş", "ş", "Ş", "ş", "", "", "Y", "y", "I", "ı", "", "", "É", "é", "Ü", "ü", "Ä", "ä",
			}
		}
	},
--	override_translit = true,
	sort_key = {
		Cyrl = {
			from = {"ә", "ғ", "ё", "қ", "ң", "ө", "ұ", "ү", "һ", "і"},
			to = {"а" .. p[1], "г" .. p[1], "е" .. p[1], "к" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1], "у" .. p[2], "х" .. p[1], "ы" .. p[1]}
		},
	},
	standardChars = {
		Cyrl = "АаӘәБбВвГгҒғДдЕеЁёЖжЗзИиЙйКкҚқЛлМмНнҢңОоӨөПпРрСсТтУуҰұҮүФфХхҺһЦцЧчШшЩщЪъЫыІіЬьЭэЮюЯя",
		c.punc
	},
}

m["kl"] = {
	"grenlandšćina",
	25355,
	"esx-inu",
	"Latn",
	sort_key = {
		from = {"æ", "ø", "å"},
		to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
	}
}

m["km"] = {
	"khmeršćina",
	9205,
	"mkh-kmr",
	"Khmr",
	ancestors = "xhm",
	translit = "km-translit",
}

m["kn"] = {
	"kanadišćina",
	33673,
	"dra-kan",
	"Knda, Tutg",
	ancestors = "dra-mkn",
	translit = {
		Knda = "kn-translit",
	},
}

m["ko"] = {
	"korejšćina",
	9176,
	"qfa-kor",
	"Kore, Brai",
	ancestors = "ko-ear",
	translit = {
		Kore = "ko-translit",
	},
	entry_name = {
		Kore = s["Kore-entryname"],
	},
}

m["kr"] = {
	"kanurišćina",
	36094,
	"ssa-sah",
	"Latn, Arab",
	-- the sortkey and entry_name are only for standard Kanuri; when dialectal entries get added, someone will have to work out how the dialects should be represented orthographically
	entry_name = {
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
	"kašmiršćina",
	33552,
	"inc-kas",
	"ks-Arab, Deva, Shrd, Latn",
	translit = {
		["ks-Arab"] = "ks-Arab-translit",
		Deva = "ks-Deva-translit",
		Shrd = "Shrd-translit",
	},
}

-- "kv" IS TREATED AS "koi", "kpv", SEE WT:LT

m["kw"] = {
	"kornšćina",
	25289,
	"cel-brs",
	"Latn",
	ancestors = "cnx",
	sort_key = {
		from = {"ch"},
		to = {"c" .. p[1]}
	},
}

m["ky"] = {
	"kirghišćina",
	9255,
	"trk-kkp",
	"Cyrl, Latn, Arab",
	translit = {
		Cyrl = "ky-translit"
	},
	override_translit = true,
	sort_key = {
		Cyrl = {
			from = {"ё", "ң", "ө", "ү"},
			to = {"е" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1]}
		},
	},
}

m["la"] = {
	"łaćonšćina",
	397,
	"itc-laf",
	"Latn",
	ancestors = "itc-ola",
	display_text = {
		Latn = s["itc-Latn-displaytext"]
	},
	entry_name = {
		Latn = s["itc-Latn-entryname"]
	},
	sort_key = {
		Latn = s["itc-Latn-sortkey"]
	},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiLlMmNnOoPpQqRrSsTtUuVvXx",
		c.punc
	},
}

m["lb"] = {
	"luksemburgšćina",
	9051,
	"gmw-hgm",
	"Latn, Brai",
	ancestors = "gmw-cfr",
	sort_key = {
		Latn = {
			from = {"ä", "ë", "é"},
			to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
		},
	},
}

m["lg"] = {
	"gandašćina",
	33368,
	"bnt-nyg",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.circ},
	sort_key = {
		from = {"ŋ"},
		to = {"n" .. p[1]}
	},
}

m["li"] = {
	"limburgšćina",
	102172,
	"gmw-frk",
	"Latn",
	ancestors = "dum",
}

m["ln"] = {
	"lingala",
	36217,
	"bnt-bmo",
	"Latn",
	sort_key = {
		remove_diacritics = c.acute .. c.circ .. c.caron,
		from = {"ɛ", "gb", "mb", "mp", "nd", "ng", "nk", "ns", "nt", "ny", "nz", "ɔ"},
		to = {"e" .. p[1], "g" .. p[1], "m" .. p[1], "m" .. p[2], "n" .. p[1], "n" .. p[2], "n" .. p[3], "n" .. p[4], "n" .. p[5], "n" .. p[6], "n" .. p[7], "o" .. p[1]}
	},
}

m["lo"] = {
	"laošćina",
	9211,
	"tai-swe",
	"Laoo",
	translit = "lo-translit",
	sort_key = "Laoo-sortkey",
	standardChars = "0-9ກຂຄງຈຊຍດຕຖທນບປຜຝພຟມຢຣລວສຫອຮຯ-ໝ" .. c.punc,
}

m["lt"] = {
	"litawšćina",
	9083,
	"bat-eas",
	"Latn",
	ancestors = "olt",
	display_text = {
		from = {"([ij]" .. c.ogonek .. "?)" .. c.dotabove, "([ij]" .. c.ogonek .. "?)([" .. c.grave .. c.acute .. c.tilde .. "])"},
		to = {"%1", "%1" .. c.dotabove .. "%2"}
	},
	entry_name = {
		remove_diacritics = c.grave .. c.acute .. c.tilde,
		from = {"([ij]" .. c.ogonek .. "?)" .. c.dotabove},
		to = {"%1"},
	},
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.tilde,
		from = {
			"([ij]" .. c.ogonek .. "?)" .. c.dotabove,
			"ą", "č", "ę", "ė", "į", "y", "š", "ų", "ū", "ž"
		},
		to = {
			"%1",
			"a" .. p[1], "c" .. p[1], "e" .. p[1], "e" .. p[2], "i" .. p[1], "i" .. p[2], "s" .. p[1], "u" .. p[1], "u" .. p[2], "z" .. p[1]
		}
	},
	standardChars = "AaĄąBbCcČčDdEeĘęĖėFfGgHhIiĮįYyJjKkLlMmNnOoPpRrSsŠšTtUuŲųŪūVvZzŽž" .. c.punc,
}

m["lu"] = {
	"luba-katanga",
	36157,
	"bnt-lub",
	"Latn",
}

m["lv"] = {
	"letišćina",
	9078,
	"bat-eas",
	"Latn",
	entry_name = {
		-- This attempts to convert vowels with tone marks to vowels either with or without macrons. Specifically, there should be no macrons if the vowel is part of a diphthong (including resonant diphthongs such pìrksts -> pirksts not #pīrksts). What we do is first convert the vowel + tone mark to a vowel + tilde in a decomposed fashion, then remove the tilde in diphthongs, then convert the remaining vowel + tilde sequences to macroned vowels, then delete any other tilde. We leave already-macroned vowels alone: Both e.g. ar and ār occur before consonants. FIXME: This still might not be sufficient.
		from = {"([Ee])" .. c.cedilla, "[" .. c.grave .. c.circ .. c.tilde .."]", "([aAeEiIoOuU])" .. c.tilde .."?([lrnmuiLRNMUI])" .. c.tilde .. "?([^aAeEiIoOuU])", "([aAeEiIoOuU])" .. c.tilde .."?([lrnmuiLRNMUI])" .. c.tilde .."?$", "([iI])" .. c.tilde .. "?([eE])" .. c.tilde .. "?", "([aAeEiIuU])" .. c.tilde, c.tilde},
		to = {"%1", c.tilde, "%1%2%3", "%1%2", "%1%2", "%1" .. c.macron}
	},
	sort_key = {
		from = {"ā", "č", "ē", "ģ", "ī", "ķ", "ļ", "ņ", "š", "ū", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "e" .. p[1], "g" .. p[1], "i" .. p[1], "k" .. p[1], "l" .. p[1], "n" .. p[1], "s" .. p[1], "u" .. p[1], "z" .. p[1]}
	},
	standardChars = "AaĀāBbCcČčDdEeĒēFfGgĢģHhIiĪīJjKkĶķLlĻļMmNnŅņOoPpRrSsŠšTtUuŪūVvZzŽž" .. c.punc,
}

m["mg"] = {
	"malagasišćina",
	7930,
	"poz-bre",
	"Latn, Arab",
}

m["mh"] = {
	"maršalšćina",
	36280,
	"poz-mic",
	"Latn",
	sort_key = {
		from = {"ā", "ļ", "m̧", "ņ", "n̄", "o̧", "ō", "ū"},
		to = {"a" .. p[1], "l" .. p[1], "m" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "o" .. p[2], "u" .. p[1]}
	},
}

m["mi"] = {
	"maori",
	36451,
	"poz-pep",
	"Latn",
	sort_key = {
		remove_diacritics = c.macron,
		from = {"ng", "wh"},
		to = {"z" .. p[1], "z" .. p[2]}
	},
}

m["mk"] = {
	"makedonšćina",
	9296,
	"zls",
	"Cyrl, Polyt",
	ancestors = "cu",
	translit = {
		Cyrl = "mk-translit"
	},
	display_text = {
		Polyt = s["Polyt-displaytext"]
	},
	entry_name = {
		Cyrl = {
			remove_diacritics = c.acute,
			remove_exceptions = {"Ѓ", "ѓ", "Ќ", "ќ"}
		},
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Cyrl = {
			remove_diacritics = c.grave,
			remove_exceptions = {"ѓ", "ќ"},
			from = {"ѓ", "ѕ", "ј", "љ", "њ", "ќ", "џ"},
			to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "т" .. p[1], "ч" .. p[1]}
		},
		Polyt = s["Polyt-sortkey"],
	},
	standardChars = {
		Cyrl = "АаБбВвГгДдЃѓЕеЖжЗзЅѕИиЈјКкЛлЉљМмНнЊњОоПпРрСсТтЌќУуФфХхЦцЧчЏџШш",
		c.punc
	},
}

m["ml"] = {
	"malajalamšćina",
	36236,
	"dra-mal",
	"Mlym",
	translit = "ml-translit",
	override_translit = true,
}

m["mn"] = {
	"mongolšćina",
	9246,
	"xgn-cen",
	"Cyrl, Mong, Latn, Brai",
	ancestors = "cmg",
	translit = {
		Cyrl = "mn-translit",
		Mong = "Mong-translit",
	},
	override_translit = true,
	display_text = {
		Mong = s["Mong-displaytext"]
	},
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
	"maratišćina",
	1571,
	"inc-sou",
	"Deva, Modi",
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
	"malajišćina",
	9237,
	"poz-mly",
	"Latn, ms-Arab",
	ancestors = "ms-cla",
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		c.punc
	},
}

m["mt"] = {
	"maltašćina",
	9166,
	"sem-arb",
	"Latn",
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
	"burmašćina",
	9228,
	"tbq-brm",
	"Mymr",
	ancestors = "obr",
	translit = "my-translit",
	override_translit = true,
	sort_key = {
		from = {"ျ", "ြ", "ွ", "ှ", "ဿ"},
		to = {"္ယ", "္ရ", "္ဝ", "္ဟ", "သ္သ"}
	},
}

m["na"] = {
	"naurušćina",
	13307,
	"poz-mic",
	"Latn",
}

m["nb"] = {
	"norwegšćina (bokmål)",
	25167,
	"gmq",
	"Latn",
	wikimedia_codes = "no",
	ancestors = "gmq-mno, da",  -- da as an (but not the) ancestor of nb was agreed on - do not change without discussion
	sort_key = s["no-sortkey"],
	standardChars = s["no-standardchars"],
}

m["nd"] = {
	"sewjerna ndebelšćina",
	35613,
	"bnt-ngu",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["ne"] = {
	"nepalšćina",
	33823,
	"inc-pah",
	"Deva, Newa",
	translit = {
		Deva = "ne-translit"
	},
}

m["ng"] = {
	"ndonga",
	33900,
	"bnt-ova",
	"Latn",
}

m["nl"] = {
	"nižozemšćina",
	7411,
	"gmw-frk",
	"Latn, Brai",
	ancestors = "dum",
	sort_key = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.ringabove .. c.cedilla .. "'"},
	},
	standardChars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["nn"] = {
	"norwegšćina (nynorsk)",
	25164,
	"gmq-wes",
	"Latn",
	ancestors = "gmq-mno",
	entry_name = {
		remove_diacritics = c.grave .. c.acute,
	},
	sort_key = s["no-sortkey"],
	standardChars = s["no-standardchars"],
}

m["no"] = {
	"norwegšćina",
	9043,
	"gmq-wes",
	"Latn",
	ancestors = "gmq-mno",
	sort_key = s["no-sortkey"],
	standardChars = s["no-standardchars"],
}

m["nr"] = {
	"južna ndebelšćina",
	36785,
	"bnt-ngu",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["nv"] = {
	"navajo",
	13310,
	"apa",
	"Latn, Brai",
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
	"čičewa",
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
	"okcitanšćina",
	14185,
	"roa-ocr",
	"Latn, Hebr",
	ancestors = "pro",
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		Hebr = "Hebr-common",
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.diaer .. c.cedilla,
			from = {"([lns])·h"},
			to = {"%1h"}
		},
		Hebr = "Hebr-common",
	},
}

m["oj"] = {
	"odžibwa",
	33875,
	"alg",
	"Cans, Latn",
	sort_key = {
		Latn = {
			from = {"aa", "ʼ", "ii", "oo", "sh", "zh"},
			to = {"a" .. p[1], "h" .. p[1], "i" .. p[1], "o" .. p[1], "s" .. p[1], "z" .. p[1]}
		},
	},
}

m["om"] = {
	"oromšćina",
	33864,
	"cus-eas",
	"Latn, Ethi",
}

m["or"] = {
	"odišćina",
	33810,
	"inc-eas",
	"Orya",
	ancestors = "inc-mor",
	translit = "or-translit",
}

m["os"] = {
	"osetšćina",
	33968,
	"xsc-sar",
	"Cyrl, Geor, Latn",
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
	"pundžabšćina",
	58635,
	"inc-pan",
	"Guru, pa-Arab",
	ancestors = "inc-opa",
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
	"pališćina",
	36727,
	"inc-mid",
	"Latn, Brah, Deva, Beng, Sinh, Mymr, Thai, Lana, Laoo, Khmr, Cakm", --and also Khom
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
	"pólšćina",
	809,
	"zlw-lch",
	"Latn",
	ancestors = "zlw-mpl",
	sort_key = {
		from = {"ą", "ć", "ę", "ł", "ń", "ó", "ś", "ź", "ż"},
		to = {"a" .. p[1], "c" .. p[1], "e" .. p[1], "l" .. p[1], "n" .. p[1], "o" .. p[1], "s" .. p[1], "z" .. p[1], "z" .. p[2]}
	},
	standardChars = "AaĄąBbCcĆćDdEeĘęFfGgHhIiJjKkLlŁłMmNnŃńOoÓóPpRrSsŚśTtUuWwYyZzŹźŻż" .. c.punc,
}

m["ps"] = {
	"paštošćina",
	58680,
	"ira-pat",
	"ps-Arab",
	entry_name = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.zwarakay .. c.superalef},
}

m["pt"] = {
	"portugalšćina",
	5146,
	"roa-gap",
	"Latn, Brai",
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.diaer .. c.cedilla,
			from = {"ª", "æ", "º", "œ"},
			to = {"a", "ae", "o", "oe"}
		},
	},
	standardChars = {
		Latn = "AaÁáÂâÃãBbCcÇçDdEeÉéÊêFfGgHhIiÍíJjLlMmNnOoÓóÔôÕõPpQqRrSsTtUuÚúVvXxZz",
		Brai = c.braille,
		c.punc
	},
}

m["qu"] = {
	"kečuasćina",
	5218,
	"qwe",
	"Latn",
}

m["rm"] = {
	"retoromanšćina",
	13199,
	"roa-rhe",
	"Latn",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.small_e},
}

m["ro"] = {
	"rumunšćina",
	7913,
	"roa-eas",
	"Latn, Cyrl, Cyrs",
	translit = {
		Cyrl = "ro-translit"
	},
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
	"rušćina",
	7737,
	"zle",
	"Cyrl, Brai",
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
	entry_name = {
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
			remove_exceptions = {"ё", "ѣ̈", "я̈"},
			from = {
				"ё", "ѣ̈", "я̈", -- 2 chars
				"і", "ѣ", "ѳ", "ѵ" -- 1 char
			},
			to = {
				"е" .. p[1], "ь" .. p[2], "я" .. p[1],
				"и" .. p[1], "ь" .. p[1], "я" .. p[2], "я" .. p[3]
			}
		},
	},
	standardChars = {
		Cyrl = "АаБбВвГгДдЕеЁёЖжЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЪъЫыЬьЭэЮюЯя—",
		Brai = c.braille,
		(c.punc:gsub("'", "")) -- Exclude apostrophe.
	},
}

m["rw"] = {
	"kinjarwanda",
	3217514,
	"bnt-glb",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.circ .. c.macron .. c.caron},
}

m["sa"] = {
	"sanskrit",
	11059,
	"inc",
	"as-Beng, Bali, Beng, Bhks, Brah, Mymr, xwo-Mong, Deva, Gujr, Guru, Gran, Hani, Java, Kthi, Knda, Kawi, Khar, Khmr, Laoo, Mlym, mnc-Mong, Marc, Modi, Mong, Nand, Newa, Orya, Phag, Ranj, Saur, Shrd, Sidd, Sinh, Soyo, Lana, Takr, Taml, Tang, Telu, Thai, Tibt, Tutg, Tirh, Zanb", --and also Khom; script codes sorted by canonical name rather than code for [[MOD:sa-convert]]
	translit = {
		Beng = "sa-Beng-translit",
		["as-Beng"] = "sa-Beng-translit",
		Brah = "Brah-translit",
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
		Mong = "Mong-translit",
		["mnc-Mong"] = "mnc-translit",
		["xwo-Mong"] = "xal-translit",
		Mymr = "pi-translit",
		Orya = "sa-Orya-translit",
		Shrd = "Shrd-translit",
		Sidd = "Sidd-translit",
		Sinh = "si-translit",
		Taml = "sa-Taml-translit",
		Telu = "sa-Telu-translit",
		Thai = "pi-translit",
		Tibt = "Tibt-translit",
	},
	display_text = {
		Mong = s["Mong-displaytext"],
		Tibt = s["Tibt-displaytext"],
	},
	entry_name = {
		Mong = s["Mong-entryname"],
		Tibt = s["Tibt-entryname"],
		Thai = {
			from = {"ึ", u(0xF700), u(0xF70F)}, -- FIXME: Not clear what's going on with the PUA characters here.
			to = {"ิํ", "ฐ", "ญ"}
		},
		remove_diacritics = c.VS01 .. c.udatta .. c.anudatta
	},
	sort_key = {
		Tibt = "Tibt-sortkey",
		{ -- FIXME: This needs to be converted into the current standardized format.
			from = {"ā", "ī", "ū", "ḍ", "ḷ", "ḹ", "m[" .. c.dotabove .. c.dotbelow .. "]", "ṅ", "ñ", "ṇ", "ṛ", "ṝ", "ś", "ṣ", "ṭ", "([เโไ])([ก-ฮ])", "([ເໂໄ])([ກ-ຮ])", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ", u(0xFE00), u(0x200D)},
			to = {"a~", "i~", "u~", "d~", "l~", "l~~", "m~", "n~", "n~~", "n~~~", "r~", "r~~", "s~", "s~~", "t~", "%2%1", "%2%1", "ᩈ᩠ᩈ", "᩠ᩁ", "᩠ᩃ", "ᨦ᩠", "%1᩠ᨮ", "%1᩠ᨻ", "ᩣ"},
		},
	},
}

m["sc"] = {
	"sardinšćina",
	33976,
	"roa-sou",
	"Latn",
}

m["sd"] = {
	"sindišćina",
	33997,
	"inc-snd",
	"sd-Arab, Deva, Sind, Khoj",
	translit = {
		Sind = "Sind-translit"
	},
	entry_name = {
		["sd-Arab"] = {
			remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
			from = {"ٱ"},
			to = {"ا"}
		},
	},
}

m["se"] = {
	"sewjerna samišćina",
	33947,
	"smi",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"ˈ"}
	},
	entry_name = {remove_diacritics = c.macron .. c.dotbelow .. "'ˈ"},
	sort_key = {
		from = {"á", "č", "đ", "ŋ", "š", "ŧ", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "d" .. p[1], "n" .. p[1], "s" .. p[1], "t" .. p[1], "z" .. p[1]}
	},
	standardChars = "AaÁáBbCcČčDdĐđEeFfGgHhIiJjKkLlMmNnŊŋOoPpRrSsŠšTtŦŧUuVvZzŽž" .. c.punc,
}

m["sg"] = {
	"sango",
	33954,
	"crp",
	"Latn",
	ancestors = "ngb",
}

m["si"] = {
	"singalešćina",
	13267,
	"inc-ins",
	"Sinh",
	translit = "si-translit",
	override_translit = true,
}

m["sk"] = {
	"słowakšćina",
	9058,
	"zlw",
	"Latn",
	ancestors = "zlw-osk",
	sort_key = {remove_diacritics = c.acute .. c.circ .. c.diaer .. c.caron},
	standardChars = "AaÁáÄäBbCcČčDdĎďEeÉéFfGgHhIiÍíJjKkLlĹĺĽľMmNnŇňOoÓóÔôPpRrŔŕSsŠšTtŤťUuÚúVvYyÝýZzŽž" .. c.punc,
}

m["sl"] = {
	"słowjenšćina",
	9063,
	"zls",
	"Latn",
	entry_name = {
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
	standardChars = "AaBbCcČčDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšTtUuVvZzŽž" .. c.punc,
}

m["sm"] = {
	"samoašćina",
	34011,
	"poz-pnp",
	"Latn",
}

m["sn"] = {
	"šonšćina",
	34004,
	"bnt-sho",
	"Latn",
	entry_name = {remove_diacritics = c.acute},
}

m["so"] = {
	"somalšćina",
	13275,
	"cus-som",
	"Latn, Arab, Osma",
	entry_name = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}
	},
}

m["sr"] = {
	"serbišćina",
	9299,
	"zls",
	"Latn, Cyrl",
	entry_name = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"Ć", "ć"}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			remove_exceptions = {"ć"},
			from = {"č", "ć", "dž", "đ", "lj", "nj", "š", "ž"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "l" .. p[1], "n" .. p[1], "s" .. p[1], "z" .. p[1]}
		},
		Cyrl = {
			remove_diacritics = c.grave .. c.acute .. c.tilde .. c.macron .. c.dgrave .. c.invbreve,
			from = {"ђ", "з́", "ј", "љ", "њ", "с́", "ћ", "џ"},
			to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "с" .. p[1], "т" .. p[1], "ч" .. p[1]}
		},
	},
	standardChars = {
		Latn = "AaBbCcČčĆćDdĐđEeFfGgHhIiJjKkLlMmNnOoPpRrSsŠšTtUuVvZzŽž",
		Cyrl = "АаБбВвГгДдЂђЕеЖжЗзИиЈјКкЛлЉљМмНнЊњОоПпРрСсТтЋћУуФфХхЦцЧчЏџШш",
		c.punc
	},
}

m["sq"] = {
	"albanšćina",
	8748,
	"sqj",
	"Latn, Grek, ota-Arab, Elba, Todr, Vith",
	translit = {
		Elba = "Elba-translit",
	},
	display_text = {
		Grek = s["Grek-displaytext"],
	},
	entry_name = {
		Latn = {
			remove_diacritics = c.acute,
			from = {'^[ie] (%w)', '^të (%w)'}, to = {'%1', '%1'},
		},
		Grek = { -- Diacritic removal from Grek-entryname excluded.
			from = s["Grek-entryname"].from,
			to = s["Grek-entryname"].to,
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.acute .. c.circ .. c.tilde .. c.breve .. c.caron,
			from = {'^[ie] (%w)', '^të (%w)', 'ç', 'dh', 'ë', 'gj', 'll', 'nj', 'rr', 'sh', 'th', 'xh', 'zh'},
			to = {'%1', '%1', 'c'..p[1], 'd'..p[1], 'e'..p[1], 'g'..p[1], 'l'..p[1], 'n'..p[1], 'r'..p[1], 's'..p[1], 't'..p[1], 'x'..p[1], 'z'..p[1]},
		}
		-- TODO: Grek
	},
	standardChars = {
		Latn = "AaBbCcÇçDdEeËëFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvXxYyZz",
		c.punc
	},
}

m["ss"] = {
	"siswatišćina",
	34014,
	"bnt-ngu",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["st"] = {
	"južna sothošćina",
	34340,
	"bnt-sts",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["su"] = {
	"sundašćina",
	34002,
	"poz-msa",
	"Latn, Sund, Arab",
	ancestors = "osn",
	translit = {
		Sund = "su-translit"
	},
}

m["sv"] = {
	"šwedšćina",
	9027,
	"gmq-eas",
	"Latn",
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
	"swahilišćina",
	7838,
	"bnt-swh",
	"Latn, Arab",
	sort_key = {
		Latn = {
			from = {"ng'"},
			to = {"ng" .. p[1]}
		},
	},
}

m["ta"] = {
	"tamilšćina",
	5885,
	"dra-tam",
	"Taml",
	ancestors = "ta-mid",
	translit = "ta-translit",
	override_translit = true,
}

m["te"] = {
	"telugušćina",
	8097,
	"dra-tel",
	"Telu",
	translit = "te-translit",
	override_translit = true,
}

m["tg"] = {
	"tadžikšćina",
	9260,
	"ira-swi",
	"Cyrl, fa-Arab, Latn",
	ancestors = "fa-cls",
	translit = {
		Cyrl = "tg-translit"
	},
	override_translit = true,
	entry_name = {
		Cyrl = s["tg-entryname"],
		Latn = s["tg-entryname"],
	},
	sort_key = {
		Cyrl = {
			from = {"ғ", "ё", "ӣ", "қ", "ӯ", "ҳ", "ҷ"},
			to = {"г" .. p[1], "е" .. p[1], "и" .. p[1], "к" .. p[1], "у" .. p[1], "х" .. p[1], "ч" .. p[1]}
		},
	},
}

m["th"] = {
	"thailandšćina",
	9217,
	"tai-swe",
	"Thai, Khomt, Brai",
	translit = {
		Thai = "th-translit"
	},
	sort_key = {
		Thai = "Thai-sortkey"
	},
}

m["ti"] = {
	"tigrinja",
	34124,
	"sem-eth",
	"Ethi",
	translit = "Ethi-translit",
}

m["tk"] = {
	"turkmenšćina",
	9267,
	"trk-ogz",
	"Latn, Cyrl, Arab",
	entry_name = {
		Latn = s["tk-entryname"],
		Cyrl = s["tk-entryname"],
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
	"tagalogšćina",
	34057,
	"phi",
	"Latn, Tglg",
	translit = {
		Tglg = "tl-translit"
	},
	override_translit = true,
	entry_name = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}
	},
	standardChars = {
		Latn = "AaBbKkDdEeGgHhIiLlMmNnOoPpRrSsTtUuWwYy",
		c.punc
	},
	sort_key = {
		Latn = "tl-sortkey",
	},
}

m["tn"] = {
	"tswana",
	34137,
	"bnt-sts",
	"Latn",
}

m["to"] = {
	"tongašćina",
	34094,
	"poz-ton",
	"Latn",
	entry_name = {remove_diacritics = c.acute},
	sort_key = {remove_diacritics = c.macron},
}

m["tr"] = {
	"turkowšćina",
	256,
	"trk-ogz",
	"Latn",
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
	standardChars = "AaÂâBbCcÇçDdEeFfGgĞğHhIıİiÎîJjKkLlMmNnOoÖöPpRrSsŞşTtUuÛûÜüVvYyZz" .. c.punc,
}

m["ts"] = {
	"tsongašćina",
	34327,
	"bnt-tsr",
	"Latn",
}

m["tt"] = {
	"tataršćina",
	25285,
	"trk-kbu",
	"Cyrl, Latn, tt-Arab",
	translit = {
		Cyrl = "tt-translit"
	},
	override_translit = true,
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
	"tahitišćina",
	34128,
	"poz-pep",
	"Latn",
}

m["ug"] = {
	"ujguršćina",
	13263,
	"trk-kar",
	"ug-Arab, Latn, Cyrl",
	ancestors = "chg",
	translit = {
		["ug-Arab"] = "ug-translit",
		Cyrl = "ug-translit",
	},
	override_translit = true,
}

m["uk"] = {
	"ukrainšćina",
	8798,
	"zle",
	"Cyrl",
	ancestors = "zle-ouk",
	translit = "uk-translit",
	entry_name = {remove_diacritics = c.grave .. c.acute},
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
	standardChars = "АаБбВвГгДдЕеЄєЖжЗзИиІіЇїЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЬьЮюЯя" .. c.punc:gsub("'", ""),  -- Exclude apostrophe.
}

m["ur"] = {
	"urdušćina",
	1617,
	"inc-hnd",
	"ur-Arab, Hebr",
	translit = {
		["ur-Arab"] = "ur-translit"
	},
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		["ur-Arab"] = {
			-- character "ۂ" code U+06C2 to "ه" and "هٔ"‎ (U+0647 + U+0654) to "ه"; hamzatu l-waṣli to a regular alif
			from = {"هٔ", "ۂ", "ٱ"},
			to = {"ہ", "ہ", "ا"},
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna .. c.superalef
		},
		Hebr = "Hebr-common",
	},
	sort_key = {
		Hebr = "Hebr-common",
	},
	standardChars = {
		["ur-Arab"] = "ایببپتثجچحخدذرزژسشصضطظعغفقکگلࣇڷمنݨوؤہھئٹڈڑآے",
		c.punc,
	},
}

m["uz"] = {
	"uzbekšćina",
	9264,
	"trk-kar",
	"Latn, Cyrl, fa-Arab",
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
}

m["ve"] = {
	"vendašćina",
	32704,
	"bnt-bso",
	"Latn",
}

m["vi"] = {
	"vietnamšćina",
	9199,
	"mkh-vie",
	"Latn, Hani",
	ancestors = "mkh-mvi",
	sort_key = {
		Latn = "vi-sortkey",
		Hani = "Hani-sortkey",
	},
}

m["vo"] = {
	"volapyk",
	36986,
	"art",
	"Latn",
}

m["wa"] = {
	"walonšćina",
	34219,
	"roa-oil",
	"Latn",
	sort_key = s["roa-oil-sortkey"],
}

m["wo"] = {
	"wolof",
	34257,
	"alv-fwo",
	"Latn, Arab, Gara",
}

m["xh"] = {
	"xhosa",
	13218,
	"bnt-ngu",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["yi"] = {
	"jiddišćina",
	8641,
	"gmw-hgm",
	"Hebr, Latn",
	ancestors = "gmh",
	translit = {
		Hebr = "yi-translit",
	},
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		Hebr = "Hebr-common",
	},
	sort_key = {
		Hebr = "Hebr-common",
	},
}

m["yo"] = {
	"joruba",
	34311,
	"alv-yor",
	"Latn, Arab",
	entry_name = {
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
	"džuang",
	13216,
	"tai",
	"Latn, Hani",
	sort_key = {
		Latn = "za-sortkey",
		Hani = "Hani-sortkey",
	},
}

m["zh"] = {
	"chinšćina",
	7850,
	"zhx",
	"Hants, Latn, Bopo, Nshu, Brai",
	ancestors = "ltc",
	generate_forms = "zh-generateforms",
	translit = {
		Hani = "zh-translit",
		Bopo = "zh-translit",
	},
	sort_key = {
		Hani = "Hani-sortkey"
	},
}

m["zu"] = {
	"zulušćina",
	10179,
	"bnt-ngu",
	"Latn",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

return require("Modul:languages").finalizeData(m, "language")