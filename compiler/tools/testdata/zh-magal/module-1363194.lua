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

s["ka-stripdiacritics"] = {remove_diacritics = c.circ}

s["no-sortkey"] = {
	remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.dacute .. c.caron .. c.cedilla,
	remove_exceptions = {"å"},
	from = {"æ", "ø", "å"},
	to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
}

s["no-standardchars"] = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvYyÆæØøÅå" .. c.punc

s["sa-Deva-stripdiacritics"] = { -- Don't use remove_diacritics for accent marks, as १ and ३ should also be removed if (and only if) they carry any.
	from = {"ॐ", "[१३]?[" .. c.anudatta .. c.udatta .. c.dsvarita .. c.tsvarita .. "]+"},
	to = {"ओँ"},
}

s["tg-stripdiacritics"] = {remove_diacritics = c.grave .. c.acute}

s["tk-stripdiacritics"] = {remove_diacritics = c.macron}

local m = {}

m["aa"] = {
	"阿法爾語",
	27811,
	"cus-eas",
	"Latn, Ethi",
	strip_diacritics = {
		Latn = {remove_diacritics = c.acute},
	},
}

m["ab"] = {
	"阿布哈茲語",
	5111,
	"cau-abz",
	"Cyrl, Geor, Latn",
	translit = {
		Cyrl = "ab-translit",
		-- Geor translit in [[Module:scripts/data]]
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
	"阿維斯陀語",
	29572,
	"ira-cen",
	"Avst, Gujr, Deva",
	translit = {
		Avst = "Avst-translit"
	},
}

m["af"] = {
	"南非語",
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
	"阿坎語",
	28026,
	"alv-ctn",
	"Latn",
}

m["am"] = {
	"阿姆哈拉語",
	28244,
	"sem-eth",
	"Ethi",
	translit = "Ethi-translit",
}

m["an"] = {
	"阿拉貢語",
	8765,
	"roa-nar",
	"Latn",
}

m["ar"] = {
	"阿拉伯語",
	13955,
	"sem-arb",
	"Arab, Hebr, Syrc, Brai, Nbat",
	translit = {
		Arab = "ar-translit"
	},
	strip_diacritics = {
		Arab = "ar-stripdiacritics",
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["as"] = {
	"阿薩姆語",
	29401,
	"inc-bas",
	"as-Beng",
	ancestors = "inc-mas",
	translit = "as-translit",
}

m["av"] = {
	"阿瓦爾語",
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
	strip_diacritics = {
		Cyrl = s["cau-Cyrl-stripdiacritics"],
		Latn = s["cau-Latn-stripdiacritics"],
	},
	sort_key = {
		Cyrl = {
			from = {"гъ", "гь", "гӏ", "ё", "кк", "къ", "кь", "кӏ", "лъ", "лӏ", "тӏ", "хх", "хъ", "хь", "хӏ", "цӏ", "чӏ"},
			to = {"г" .. p[1], "г" .. p[2], "г" .. p[3], "е" .. p[1], "к" .. p[1], "к" .. p[2], "к" .. p[3], "к" .. p[4], "л" .. p[1], "л" .. p[2], "т" .. p[1], "х" .. p[1], "х" .. p[2], "х" .. p[3], "х" .. p[4], "ц" .. p[1], "ч" .. p[1]}
		},
	},
}

m["ay"] = {
	"艾馬拉語",
	4627,
	"sai-aym",
	"Latn",
}

m["az"] = {
	"阿塞拜疆語",
	9292,
	"trk-ogz",
	"Latn, Cyrl, Arab",
	ancestors = "trk-oat",
	dotted_dotless_i = true,
	strip_diacritics = {
		Latn = {
			from = {"ʼ"},
			to = {"'"},
		},
		Arab = {
			module = "ar-stripdiacritics",
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
	"巴什基爾語",
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
	"白俄羅斯語",
	9091,
	"zle",
	"Cyrl, Latn",
	ancestors = "zle-mbe",
	translit = {
		Cyrl = "be-translit",
	},
	strip_diacritics = {
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
			remove_exceptions = {"ć", "ń", "ś", "ź"},
			from = {"ć", "č", "dz", "dź", "dž", "ch", "ł", "ń", "ś", "š", "ŭ", "ź", "ž"},
			to = {"c" .. p[1], "c" .. p[2], "d" .. p[1], "d" .. p[2], "d" .. p[3], "h" .. p[1], "l" .. p[1], "n" .. p[1], "s" .. p[1], "s" .. p[2], "u" .. p[1], "z" .. p[1], "z" .. p[2]}
		},
	},
	standard_chars = {
		Cyrl = "АаБбВвГгДдЕеЁёЖжЗзІіЙйКкЛлМмНнОоПпРрСсТтУуЎўФфХхЦцЧчШшЫыЬьЭэЮюЯя",
		Latn = "AaBbCcĆćČčDdEeFfGgHhIiJjKkLlŁłMmNnŃńOoPpRrSsŚśŠšTtUuŬŭVvYyZzŹźŽž",
		(c.punc:gsub("'", "")) -- Exclude apostrophe.
	},
}

m["bg"] = {
	"保加利亞語",
	7918,
	"zls",
	"Cyrl",
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
	"比哈爾語",
	135305,
	"inc-eas",
	"Deva",
}

m["bi"] = {
	"比斯拉馬語",
	35452,
	"crp",
	"Latn",
	ancestors = "en",
}

m["bm"] = {
	"班巴拉語",
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
	"孟加拉語",
	9610,
	"inc-bas",
	"Beng, Newa",
	ancestors = "inc-mbn",
	translit = {
		Beng = "bn-translit"
	},
}

m["bo"] = {
	"藏語",
	34271,
	"sit-tib",
	"Tibt", -- sometimes Deva?
	ancestors = "xct",
	override_translit = true,
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["br"] = {
	"布列塔尼語",
	12107,
	"cel-brs",
	"Latn",
	ancestors = "xbm",
	sort_key = {
		from = {"ch", "c['ʼ’]h"},
		to = {"c" .. p[1], "c" .. p[2]}
	},
}

m["ca"] = {
	"加泰羅尼亞語",
	7026,
	"roa-ocr",
	"Latn",
	ancestors = "roa-oca",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.diaer .. c.cedilla .. "·"},
	standard_chars = "AaÀàBbCcÇçDdEeÉéÈèFfGgHhIiÍíÏïJjLlMmNnOoÓóÒòPpQqRrSsTtUuÚúÜüVvXxYyZz·" .. c.punc,
}

m["ce"] = {
	"車臣語",
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
	strip_diacritics = {
		Cyrl = s["cau-Cyrl-stripdiacritics"],
		Latn = s["cau-Latn-stripdiacritics"],
	},
	sort_key = {
		Cyrl = {
			from = {"аь", "гӏ", "ё", "кх", "къ", "кӏ", "оь", "пӏ", "тӏ", "уь", "хь", "хӏ", "цӏ", "чӏ", "юь", "яь"},
			to = {"а" .. p[1], "г" .. p[1], "е" .. p[1], "к" .. p[1], "к" .. p[2], "к" .. p[3], "о" .. p[1], "п" .. p[1], "т" .. p[1], "у" .. p[1], "х" .. p[1], "х" .. p[2], "ц" .. p[1], "ч" .. p[1], "ю" .. p[1], "я" .. p[1]}
		},
	},
}

m["ch"] = {
	"查莫羅語",
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
	"科西嘉語",
	33111,
	"roa-itr",
	"Latn",
	sort_key = {
		from = {"chj", "ghj", "sc", "sg"},
		to = {"c" .. p[1], "g" .. p[1], "s" .. p[1], "s" .. p[2]}
	},
	standard_chars = "AaÀàBbCcDdEeÈèFfGgHhIiÌìÏïJjLlMmNnOoÒòPpQqRrSsTtUuÙùÜüVvZz" .. c.punc,
}

m["cr"] = {
	"克里語",
	33390,
	"alg",
	"Latn, Cans",
	translit = {
		Cans = "cr-translit"
	},
}

m["cs"] = {
	"捷克語",
	9056,
	"zlw",
	"Latn",
	ancestors = "cs-ear",
	sort_key = {
		from = {"á", "č", "ď", "é", "ě", "ch", "í", "ň", "ó", "ř", "š", "ť", "ú", "ů", "ý", "ž"},
		to = {"a" .. p[1], "c" .. p[1], "d" .. p[1], "e" .. p[1], "e" .. p[2], "h" .. p[1], "i" .. p[1], "n" .. p[1], "o" .. p[1], "r" .. p[1], "s" .. p[1], "t" .. p[1], "u" .. p[1], "u" .. p[2], "y" .. p[1], "z" .. p[1]}
	},
	standard_chars = "AaÁáBbCcČčDdĎďEeÉéĚěFfGgHhIiÍíJjKkLlMmNnŇňOoÓóPpRrŘřSsŠšTtŤťUuÚúŮůVvYyÝýZzŽž" .. c.punc,
}

m["cu"] = {
	"古教會斯拉夫語",
	35499,
	"zls",
	"Cyrs, Glag, Zname",
	translit = {
		Cyrs = "Cyrs-translit",
		Glag = "Glag-translit"
	},
	-- Cyrs strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["cv"] = {
	"楚瓦什語",
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
	"威爾士語",
	9309,
	"cel-brw",
	"Latn",
	ancestors = "wlm",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. "'",
		from = {"ch", "dd", "ff", "ng", "ll", "ph", "rh", "th"},
		to = {"c" .. p[1], "d" .. p[1], "f" .. p[1], "g" .. p[1], "l" .. p[1], "p" .. p[1], "r" .. p[1], "t" .. p[1]}
	},
	standard_chars = "ÂâAaBbCcDdEeÊêFfGgHhIiÎîLlMmNnOoÔôPpRrSsTtUuÛûWwŴŵYyŶŷ" .. c.punc,
}

m["da"] = {
	"丹麥語",
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
	standard_chars = "AaBbDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvYyÆæØøÅå" .. c.punc,
}

m["de"] = {
	"德語",
	188,
	"gmw-hgm",
	"Latn, Latf, Brai",
	ancestors = "de-ear",
	sort_key = {
		Latn = s["de-Latn-sortkey"],
		Latf = s["de-Latn-sortkey"],
	},
	standard_chars = {
		Latn = s["de-Latn-standardchars"],
		Latf = s["de-Latn-standardchars"],
		Brai = c.braille,
		c.punc
	}
}

m["dv"] = {
	"迪維希語",
	32656,
	"inc-ins",
	"Thaa, Diak",
	translit = {
		Thaa = "dv-translit",
		Diak = "Diak-translit",
	},
    ancestors = "dv-old",
	override_translit = true,
}

m["dz"] = {
	"宗喀語",
	33081,
	"sit-tib",
	"Tibt",
	ancestors = "xct",
	override_translit = true,
	-- Tibt translit, display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["ee"] = {
	"埃維語",
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
	"希臘語",
	9129,
	"grk",
	"Grek, Polyt, Brai",
	ancestors = "el-kth",
	translit = "el-translit",
	override_translit = true,
	-- Grek and Polyt display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	standard_chars = {
		Grek = "΅·ͺ΄ΑαΆάΒβΓγΔδΕεέΈΖζΗηΉήΘθΙιΊίΪϊΐΚκΛλΜμΝνΞξΟοΌόΠπΡρΣσςΤτΥυΎύΫϋΰΦφΧχΨψΩωΏώ",
		Brai = c.braille,
		c.punc
	},
}

m["en"] = {
	"英語",
	1860,
	"gmw-ang",
	"Latn, Brai, Shaw, Dsrt", -- entries in Shaw or Dsrt might require prior discussion
	wikimedia_codes = "en, simple",
	ancestors = "en-ear",
	sort_key = {
		Latn = {
			-- Many of these are needed for sorting language names.
			remove_diacritics = "'\"%-%.,%s·ʻʼ" .. c.diacritics,
			-- These are found in pagenames.
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
	standard_chars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["eo"] = {
	"世界語",
	143,
	"art",
	"Latn",
	sort_key = {
		remove_diacritics = c.grave .. c.acute,
		from = {"ĉ", "ĝ", "ĥ", "ĵ", "ŝ", "ŭ"},
		to = {"c" .. p[1], "g" .. p[1], "h" .. p[1], "j" .. p[1], "s" .. p[1], "u" .. p[1]}
	},
	standard_chars = "AaBbCcĈĉDdEeFfGgĜĝHhĤĥIiJjĴĵKkLlMmNnOoPpRrSsŜŝTtUuŬŭVvZz" .. c.punc,
}

m["es"] = {
	"西班牙語",
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
	standard_chars = {
		Latn = "AaÁáBbCcDdEeÉéFfGgHhIiÍíJjLlMmNnÑñOoÓóPpQqRrSsTtUuÚúÜüVvXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["et"] = {
	"愛沙尼亞語",
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
	"巴斯克語",
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
	"波斯語",
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
	"富拉語",
	33454,
	"alv-fwo",
	"Latn, Adlm",
}

m["fi"] = {
	"芬蘭語",
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
	"斐濟語",
	33295,
	"poz-pcc",
	"Latn",
}

m["fo"] = {
	"法羅語",
	25258,
	"gmq-ins",
	"Latn",
	sort_key = {
		from = {"á", "ð", "í", "ó", "ú", "ý", "æ", "ø"},
		to = {"a" .. p[1], "d" .. p[1], "i" .. p[1], "o" .. p[1], "u" .. p[1], "y" .. p[1], "z" .. p[1], "z" .. p[2]}
	},
	standard_chars = "AaÁáBbDdÐðEeFfGgHhIiÍíJjKkLlMmNnOoÓóPpRrSsTtUuÚúVvYyÝýÆæØø" .. c.punc,
}

m["fr"] = {
	"法語",
	150,
	"roa-oil",
	"Latn, Brai",
	ancestors = "frm",
	sort_key = {
		Latn = s["roa-oil-sortkey"]
	},
	standard_chars = {
		Latn = "AaÀàÂâBbCcÇçDdEeÉéÈèÊêËëFfGgHhIiÎîÏïJjLlMmNnOoÔôŒœPpQqRrSsTtUuÙùÛûÜüVvXxYyZz",
		Brai = c.braille,
		c.punc
	},
}

m["fy"] = {
	"西弗里斯蘭語",
	27175,
	"gmw-fri",
	"Latn",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer,
		from = {"y"},
		to = {"i"}
	},
	standard_chars = "AaâäàÆæBbCcDdEeéêëèFfGgHhIiïìYyỳJjKkLlMmNnOoôöòPpRrSsTtUuúûüùVvWwZz" .. c.punc,
}

m["ga"] = {
	"愛爾蘭語",
	9142,
	"cel-gae",
	"Latn, Latg",
	ancestors = "mga",
	sort_key = {
		remove_diacritics = c.acute,
		from = {"ḃ", "ċ", "ḋ", "ḟ", "ġ", "ṁ", "ṗ", "ṡ", "ṫ"},
		to = {"bh", "ch", "dh", "fh", "gh", "mh", "ph", "sh", "th"}
	},
	standard_chars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíLlMmNnOoÓóPpRrSsTtUuÚúVv" .. c.punc,
}

m["gd"] = {
	"蘇格蘭蓋爾語",
	9314,
	"cel-gae",
	"Latn, Latg",
	ancestors = "mga",
	sort_key = {remove_diacritics = c.grave .. c.acute},
	standard_chars = "AaÀàBbCcDdEeÈèFfGgHhIiÌìLlMmNnOoÒòPpRrSsTtUuÙù" .. c.punc,
}

m["gl"] = {
	"加利西亞語",
	9307,
	"roa-gap",
	"Latn",
	sort_key = {
		remove_diacritics = c.acute,
		from = {"ñ"},
		to = {"n" .. p[1]}
	},
	standard_chars = "AaÁáBbCcDdEeÉéFfGgHhIiÍíÏïLlMmNnÑñOoÓóPpQqRrSsTtUuÚúÜüVvXxZz" .. c.punc,
}

m["gu"] = {
	"古吉拉特語",
	5137,
	"inc-wes",
	"Arab, Gujr",
	ancestors = "inc-mgu",
	translit = {
		Gujr = "gu-translit",
	},
	strip_diacritics = {
		Arab = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.kasra .. c.shadda .. c.sukun},
		Gujr = {remove_diacritics = "઼"},
	},
}

m["gv"] = {
	"曼島語",
	12175,
	"cel-gae",
	"Latn",
	ancestors = "mga",
	sort_key = {remove_diacritics = c.cedilla .. "-"},
	standard_chars = "AaBbCcÇçDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwYy" .. c.punc,
}

m["ha"] = {
	"豪薩語",
	56475,
	"cdc-wst",
	"Latn, Arab",
	strip_diacritics = {
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
	"希伯來語",
	9288,
	"sem-can",
	"Hebr, Phnx, Brai, Samr",
	ancestors = "he-med",
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	-- Samr strip_diacritics, sort_key in [[Module:scripts/data]]
	-- Phnx translit in [[Module:scripts/data]] (NOTE: not present before, presumably an accidental omission)
}

m["hi"] = {
	"印地語",
	1568,
	"inc-hnd",
	"Deva, Kthi, Newa",
	translit = {
		Deva = "hi-translit"
	},
	standard_chars = {
		Deva = "अआइईउऊएऐओऔकखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसहत्रज्ञक्षक़ख़ग़ज़झ़ड़ढ़फ़काखागाघाङाचाछाजाझाञाटाठाडाढाणाताथादाधानापाफाबाभामायारालावाशाषासाहात्राज्ञाक्षाक़ाख़ाग़ाज़ाझ़ाड़ाढ़ाफ़ाकिखिगिघिङिचिछिजिझिञिटिठिडिढिणितिथिदिधिनिपिफिबिभिमियिरिलिविशिषिसिहित्रिज्ञिक्षिक़िख़िग़िज़िझ़िड़िढ़िफ़िकीखीगीघीङीचीछीजीझीञीटीठीडीढीणीतीथीदीधीनीपीफीबीभीमीयीरीलीवीशीषीसीहीत्रीज्ञीक्षीक़ीख़ीग़ीज़ीझ़ीड़ीढ़ीफ़ीकुखुगुघुङुचुछुजुझुञुटुठुडुढुणुतुथुदुधुनुपुफुबुभुमुयुरुलुवुशुषुसुहुत्रुज्ञुक्षुक़ुख़ुग़ुज़ुझ़ुड़ुढ़ुफ़ुकूखूगूघूङूचूछूजूझूञूटूठूडूढूणूतूथूदूधूनूपूफूबूभूमूयूरूलूवूशूषूसूहूत्रूज्ञूक्षूक़ूख़ूग़ूज़ूझ़ूड़ूढ़ूफ़ूकेखेगेघेङेचेछेजेझेञेटेठेडेढेणेतेथेदेधेनेपेफेबेभेमेयेरेलेवेशेषेसेहेत्रेज्ञेक्षेक़ेख़ेग़ेज़ेझ़ेड़ेढ़ेफ़ेकैखैगैघैङैचैछैजैझैञैटैठैडैढैणैतैथैदैधैनैपैफैबैभैमैयैरैलैवैशैषैसैहैत्रैज्ञैक्षैक़ैख़ैग़ैज़ैझ़ैड़ैढ़ैफ़ैकोखोगोघोङोचोछोजोझोञोटोठोडोढोणोतोथोदोधोनोपोफोबोभोमोयोरोलोवोशोषोसोहोत्रोज्ञोक्षोक़ोख़ोग़ोज़ोझ़ोड़ोढ़ोफ़ोकौखौगौघौङौचौछौजौझौञौटौठौडौढौणौतौथौदौधौनौपौफौबौभौमौयौरौलौवौशौषौसौहौत्रौज्ञौक्षौक़ौख़ौग़ौज़ौझ़ौड़ौढ़ौफ़ौक्ख्ग्घ्ङ्च्छ्ज्झ्ञ्ट्ठ्ड्ढ्ण्त्थ्द्ध्न्प्फ्ब्भ्म्य्र्ल्व्श्ष्स्ह्त्र्ज्ञ्क्ष्क़्ख़्ग़्ज़्झ़्ड़्ढ़्फ़्।॥०१२३४५६७८९॰",
		c.punc
	},
}

m["ho"] = {
	"希里摩圖語",
	33617,
	"crp",
	"Latn",
	ancestors = "meu",
}

m["ht"] = {
	"海地克里奧爾語",
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
	"匈牙利語",
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
	standard_chars = {
		Latn = "AaÁáBbCcDdEeÉéFfGgHhIiÍíJjKkLlMmNnOoÓóÖöŐőPpQqRrSsTtUuÚúÜüŰűVvWwXxYyZz",
		c.punc
	},
}

m["hy"] = {
	"亞美尼亞語",
	8785,
	"hyx",
	"Armn, Brai",
	ancestors = "axm",
	-- Armn translit in [[Module:scripts/data]]
	override_translit = true,
	strip_diacritics = {
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
	"赫雷羅語",
	33315,
	"bnt-swb",
	"Latn",
}

m["ia"] = {
	"因特語",
	35934,
	"art",
	"Latn",
}

m["id"] = {
	"印尼語",
	9240,
	"poz-mly",
	"Latn",
	ancestors = "ms",
	standard_chars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz" .. c.punc,
}

m["ie"] = {
	"西方國際語",
	35850,
	"art",
	"Latn",
	type = "appendix-constructed",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ},
}

m["ig"] = {
	"伊博語",
	33578,
	"alv-igb",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.macron},
	sort_key = {
		from = {"gb", "gh", "gw", "ị", "kp", "kw", "ṅ", "nw", "ny", "ọ", "sh", "ụ"},
		to = {"g" .. p[1], "g" .. p[2], "g" .. p[3], "i" .. p[1], "k" .. p[1], "k" .. p[2], "n" .. p[1], "n" .. p[2], "n" .. p[3], "o" .. p[1], "s" .. p[1], "u" .. p[1]}
	},
}

m["ii"] = {
	"彝語",
	34235,
	"tbq-nlo",
	"Yiii",
	translit = "ii-translit",
}

m["ik"] = {
	"伊努皮克語",
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
	"伊多語",
	35224,
	"art",
	"Latn",
}

m["is"] = {
	"冰島語",
	294,
	"gmq-ins",
	"Latn",
	sort_key = {
		from = {"á", "ð", "é", "í", "ó", "ú", "ý", "þ", "æ", "ö"},
		to = {"a" .. p[1], "d" .. p[1], "e" .. p[1], "i" .. p[1], "o" .. p[1], "u" .. p[1], "y" .. p[1], "z" .. p[1], "z" .. p[2], "z" .. p[3]}
	},
	standard_chars = "AaÁáBbDdÐðEeÉéFfGgHhIiÍíJjKkLlMmNnOoÓóPpRrSsTtUuÚúVvXxYyÝýÞþÆæÖö" .. c.punc,
}

m["it"] = {
	"意大利語",
	652,
	"roa-itr",
	"Latn",
	ancestors = "roa-oit",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.ringabove},
	standard_chars = "AaÀàBbCcDdEeÈèÉéFfGgHhIiÌìLlMmNnOoÒòPpQqRrSsTtUuÙùVvZz" .. c.punc,
}

m["iu"] = {
	"因紐特語",
	29921,
	"esx-inu",
	"Cans, Latn",
	translit = {
		Cans = "cr-translit"
	},
	override_translit = true,
}

m["ja"] = {
	"日語",
	5287,
	"jpx",
	"Jpan, Latn, Brai",
	ancestors = "ja-ear",
	translit = s["jpx-translit"],
	link_tr = true,
	display_text = s["jpx-displaytext"],
	strip_diacritics = s["jpx-stripdiacritics"],
	sort_key = s["jpx-sortkey"],
}

m["jv"] = {
	"爪哇語",
	33549,
	"poz",
	"Latn, Java, Arab",
	ancestors = "kaw",
	translit = {
		Java = "jv-translit"
	},
	link_tr = true,
	strip_diacritics = {
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
	"格魯吉亞語",
	8108,
	"ccs-gzn",
	"Geor, Geok, Hebr", -- Hebr is used to write Judeo-Georgian
	ancestors = "ka-mid",
	-- Geor, Geok translit in [[Module:scripts/data]]
	override_translit = true,
	strip_diacritics = {
		Geor = s["ka-stripdiacritics"],
		Geok = s["ka-stripdiacritics"],
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["kg"] = {
	"剛果語",
	33702,
	"bnt-kng",
	"Latn",
}

m["ki"] = {
	"基庫尤語",
	33587,
	"bnt-kka",
	"Latn",
}

m["kj"] = {
	"寬亞瑪語",
	1405077,
	"bnt-ova",
	"Latn",
}

m["kk"] = {
	"哈薩克語",
	9252,
	"trk-kno",
	"Cyrl, Latn, Arab",
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
	"格陵蘭語",
	25355,
	"esx-inu",
	"Latn",
	sort_key = {
		from = {"æ", "ø", "å"},
		to = {"z" .. p[1], "z" .. p[2], "z" .. p[3]}
	}
}

m["km"] = {
	"高棉語",
	9205,
	"mkh-kmr",
	"Khmr",
	ancestors = "xhm",
	translit = "km-translit", --This might yield unwanted result unless its entry has {{km-IPA}}.
}

m["kn"] = {
	"卡納達語",
	33673,
	"dra-kan",
	"Knda, Tutg",
	ancestors = "dra-mkn",
	-- Knda translit in [[Module:scripts/data]]
}

m["ko"] = {
	"朝鮮語",
	9176,
	"qfa-kor",
	"Kore, Brai",
	ancestors = "ko-ear",
	translit = {
		Kore = "ko-translit",
	},
	-- Kore strip_diacritics in [[Module:scripts/data]]
}

m["kr"] = {
	"卡努里語",
	36094,
	"ssa-sah",
	"Latn, Arab",
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
	"克什米爾語",
	33552,
	"inc-kas",
	"Aran, Deva, Shrd, Latn",
	translit = {
		Aran = "ks-Aran-translit",
		Deva = "ks-Deva-translit",
		-- Shrd translit in [[Module:scripts/data]]
	},
}

-- "kv" is treated as "koi", "kpv", see [[WT:LT]]

m["kw"] = {
	"康沃爾語",
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
	"吉爾吉斯語",
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
	"拉丁語",
	397,
	"itc-laf",
	"Latn, Ital",
	ancestors = "itc-ola",
	-- Ital translit in [[Module:scripts/data]] (NOTE: formerly not present, probably an accidental omission)
	display_text = {
		Latn = s["itc-Latn-displaytext"]
	},
	strip_diacritics = {
		Latn = s["itc-Latn-stripdiacritics"]
	},
	sort_key = {
		Latn = s["itc-Latn-sortkey"]
	},
	standard_chars = {
		Latn = "AaBbCcDdEeFfGgHhIiLlMmNnOoPpQqRrSsTtUuVvXx",
		c.punc
	},
}

m["lb"] = {
	"盧森堡語",
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
	"盧干達語",
	33368,
	"bnt-nyg",
	"Latn",
	strip_diacritics = {remove_diacritics = c.acute .. c.circ},
	sort_key = {
		from = {"ŋ"},
		to = {"n" .. p[1]}
	},
}

m["li"] = {
	"林堡語",
	102172,
	"gmw-frk",
	"Latn",
	ancestors = "dum",
}

m["ln"] = {
	"林加拉語",
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
	"老撾語",
	9211,
	"tai-swe",
	"Laoo", -- also Tai Noi/Lao Buhan script
	translit = "lo-translit",
	sort_key = "Laoo-sortkey",
	standard_chars = "0-9ກຂຄງຈຊຍດຕຖທນບປຜຝພຟມຢຣລວສຫອຮຯ-ໝ" .. c.punc,
}

m["lt"] = {
	"立陶宛語",
	9083,
	"bat-eas",
	"Latn",
	ancestors = "olt",
	display_text = "lt-common",
	strip_diacritics = "lt-common",
	sort_key = "lt-common",
	standard_chars = "AaĄąBbCcČčDdEeĘęĖėFfGgHhIiĮįYyJjKkLlMmNnOoPpRrSsŠšTtUuŲųŪūVvZzŽž" .. c.punc,
}

m["lu"] = {
	"盧巴卡丹加語",
	36157,
	"bnt-lub",
	"Latn",
}

m["lv"] = {
	"拉脫維亞語",
	9078,
	"bat-eas",
	"Latn",
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
	"馬拉加斯語",
	7930,
	"poz-bre",
	"Latn, Arab",
}

m["mh"] = {
	"馬紹爾語",
	36280,
	"poz-mic",
	"Latn",
	sort_key = {
		from = {"ā", "ļ", "m̧", "ņ", "n̄", "o̧", "ō", "ū"},
		to = {"a" .. p[1], "l" .. p[1], "m" .. p[1], "n" .. p[1], "n" .. p[2], "o" .. p[1], "o" .. p[2], "u" .. p[1]}
	},
}

m["mi"] = {
	"毛利語",
	36451,
	"poz-pep",
	"Latn",
	sort_key = {
		remove_diacritics = c.macron,
		from = {"ng", "wh"},
		to = {"n" .. p[1], "w" .. p[1]}
	},
}

m["mk"] = {
	"馬其頓語",
	9296,
	"zls",
	"Cyrl, Polyt",
	ancestors = "cu",
	translit = {
		Cyrl = "mk-translit",
		-- FIXME: formerly no translit specified for Polyt; unclear if the default [[Module:grc-translit]] is
		-- acceptable, so we disable it for now
		Polyt = false,
	},
	strip_diacritics = {
		Cyrl = {
			remove_diacritics = c.acute,
			remove_exceptions = {"Ѓ", "ѓ", "Ќ", "ќ"}
		},
	},
	sort_key = {
		Cyrl = {
			remove_diacritics = c.grave,
			remove_exceptions = {"ѓ", "ќ"},
			from = {"ѓ", "ѕ", "ј", "љ", "њ", "ќ", "џ"},
			to = {"д" .. p[1], "з" .. p[1], "и" .. p[1], "л" .. p[1], "н" .. p[1], "т" .. p[1], "ч" .. p[1]}
		},
	},
	-- Polyt display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	standard_chars = {
		Cyrl = "АаБбВвГгДдЃѓЕеЖжЗзЅѕИиЈјКкЛлЉљМмНнЊњОоПпРрСсТтЌќУуФфХхЦцЧчЏџШш",
		c.punc
	},
}

m["ml"] = {
	"馬拉雅拉姆語",
	36236,
	"dra-mal",
	"Mlym",
	override_translit = true,
	-- Mlym translit in [[Module:scripts/data]]
}

m["mn"] = {
	"蒙古語",
	9246,
	"xgn-cen",
	"Cyrl, Mong, Latn, Brai",
	ancestors = "cmg",
	translit = {
		Cyrl = "mn-translit",
		-- Mong translit in [[Module:scripts/data]]
	},
	override_translit = true,
	-- Mong display_text and strip_diacritics in [[Module:scripts/data]]
	strip_diacritics = {
		Cyrl = {remove_diacritics = c.grave .. c.acute},
	},
	sort_key = {
		Cyrl = {
			remove_diacritics = c.grave,
			from = {"ё", "ө", "ү"},
			to = {"е" .. p[1], "о" .. p[1], "у" .. p[1]}
		},
	},
	standard_chars = {
		Cyrl = "АаБбВвГгДдЕеЁёЖжЗзИиЙйЛлМмНнОоӨөРрСсТтУуҮүХхЦцЧчШшЫыЬьЭэЮюЯя—",
		Brai = c.braille,
		c.punc
	},
}

-- "mo" is treated as "ro", see [[WT:LT]]

m["mr"] = {
	"馬拉地語",
	1571,
	"inc-sou",
	"Deva, Modi",
	ancestors = "omr",
	translit = {
		Deva = "mr-translit",
		Modi = "mr-Modi-translit",
	},
	strip_diacritics = {
		Deva = {
			from = {"च़", "ज़", "झ़"},
			to = {"च", "ज", "झ"}
		},
	},
}

m["ms"] = {
	"馬來語",
	9237,
	"poz-mly",
	"Latn, Arab",
	ancestors = "ms-cla",
	standard_chars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz",
		c.punc
	},
}

m["mt"] = {
	"馬爾他語",
	9166,
	"sem-arb",
	"Latn",
	display_text = {
		from = {"'"},
		to = {"’"}
	},
	strip_diacritics = {
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
	"緬甸語",
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
	"瑙魯語",
	13307,
	"poz-mic",
	"Latn",
}

m["nb"] = {
	"書面挪威語",
	25167,
	"gmq",
	"Latn",
	wikimedia_codes = "no",
	ancestors = "gmq-mno, da",  -- da as an (but not the) ancestor of nb was agreed on - do not change without discussion
	sort_key = s["no-sortkey"],
	standard_chars = s["no-standardchars"],
}

m["nd"] = {
	"北恩德貝勒語",
	35613,
	"bnt-ngu",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["ne"] = {
	"尼泊爾語",
	33823,
	"inc-pae",
	"Deva, Newa",
	translit = {
		Deva = "ne-translit"
	},
}

m["ng"] = {
	"恩東加語",
	33900,
	"bnt-ova",
	"Latn",
}

m["nl"] = {
	"荷蘭語",
	7411,
	"gmw-frk",
	"Latn, Brai",
	ancestors = "dum",
	sort_key = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.ringabove .. c.cedilla .. "'"},
	},
	standard_chars = {
		Latn = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZzÄäËëÏïÖöÜü",
		Brai = c.braille,
		c.punc
	},
}

m["nn"] = {
	"新挪威語",
	25164,
	"gmq-wes",
	"Latn",
	ancestors = "gmq-mno",
	strip_diacritics = {
		remove_diacritics = c.grave .. c.acute,
	},
	sort_key = s["no-sortkey"],
	standard_chars = s["no-standardchars"],
}

m["no"] = {
	"挪威語",
	9043,
	"gmq-wes",
	"Latn",
	ancestors = "gmq-mno",
	sort_key = s["no-sortkey"],
	standard_chars = s["no-standardchars"],
}

m["nr"] = {
	"南恩德貝勒語",
	36785,
	"bnt-ngu",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["nv"] = {
	"納瓦霍語",
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
	"齊切瓦語",
	33273,
	"bnt-nys",
	"Latn",
	strip_diacritics = {remove_diacritics = c.acute .. c.circ},
	sort_key = {
		from = {"ng'"},
		to = {"ng"}
	},
}

m["oc"] = {
	"奧克語",
	14185,
	"roa-ocr",
	"Latn, Hebr",
	ancestors = "pro",
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute .. c.diaer .. c.cedilla,
			from = {"([lns])·h"},
			to = {"%1h"}
		},
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["oj"] = {
	"奧吉布瓦語",
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
	"奧羅莫語",
	33864,
	"cus-eas",
	"Latn, Ethi",
}

m["or"] = {
	"奧利亞語",
	33810,
	"inc-eas",
	"Orya",
	ancestors = "inc-mor",
	translit = "or-translit",
}

m["os"] = {
	"奧塞梯語",
	33968,
	"xsc-sar",
	"Cyrl, Geor, Latn",
	ancestors = "oos",
	translit = {
		Cyrl = "os-translit",
		-- Geor translit in [[Module:scripts/data]]
	},
	override_translit = true,
	display_text = {
		Cyrl = {
			from = {"æ", "Æ"},
			to = {"ӕ", "Ӕ"}
		},
		Latn = {
			from = {"ӕ", "Ӕ"},
			to = {"æ", "Æ"}
		},
	},
	strip_diacritics = {
		Cyrl = {
			remove_diacritics = c.grave .. c.acute,
			from = {"æ", "Æ"},
			to = {"ӕ", "Ӕ"}
		},
		Latn = {
			from = {"ӕ", "Ӕ"},
			to = {"æ", "Æ"}
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
	"旁遮普語",
	58635,
	"inc-pan",
	"Guru, Aran",
	translit = {
		Guru = "Guru-translit",
		Aran = "pa-Aran-translit",
	},
	strip_diacritics = {
		Aran = {
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna,
			from = {"ݨ", "ࣇ"},
			to = {"ن", "ل"}
		},
	},
}

m["pi"] = {
	"巴利語",
	36727,
	"inc-mid",
	"Latn, Brah, Deva, Beng, Sinh, Mymr, Thai, Lana, Laoo, Khmr, Cakm", --and also Khom
	ancestors = "sa",
	translit = {
		-- Brah translit in [[Module:scripts/data]]
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
	strip_diacritics = {
		Thai = {
			from = {"ึ", u(0xF700), u(0xF70F)}, -- FIXME: Not clear what's going on with the PUA characters here.
			to = {"ิํ", "ฐ", "ญ"}
		},
		Mymr = {
			remove_diacritics = c.VS01,
		},
	},
	sort_key = { -- FIXME: This needs to be converted into the current standardized format.
		from = {"ā", "ī", "ū", "ḍ", "ḷ", "m[" .. c.dotabove .. c.dotbelow .. "]", "ṅ", "ñ", "ṇ", "ṭ", "ॐ", "([เโ])([ก-ฮ])", "([ເໂ])([ກ-ຮ])", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ", u(0xFE00), u(0x200D)},
		to = {"a~", "i~", "u~", "d~", "l~", "m~", "n~", "n~~", "n~~~", "t~", "ओँ", "%2%1", "%2%1", "ᩈ᩠ᩈ", "᩠ᩁ", "᩠ᩃ", "ᨦ᩠", "%1᩠ᨮ", "%1᩠ᨻ", "ᩣ"}
	},
}

m["pl"] = {
	"波蘭語",
	809,
	"zlw-lch",
	"Latn",
	ancestors = "zlw-mpl",
	sort_key = {
		from = {"ą", "ć", "ę", "ł", "ń", "ó", "ś", "ź", "ż"},
		to = {"a" .. p[1], "c" .. p[1], "e" .. p[1], "l" .. p[1], "n" .. p[1], "o" .. p[1], "s" .. p[1], "z" .. p[1], "z" .. p[2]}
	},
	standard_chars = "AaĄąBbCcĆćDdEeĘęFfGgHhIiJjKkLlŁłMmNnŃńOoÓóPpRrSsŚśTtUuWwYyZzŹźŻż" .. c.punc,
}

m["ps"] = {
	"普什圖語",
	58680,
	"ira-pat",
	"Arab",
	strip_diacritics = {remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.zwarakay .. c.superalef},
}

m["pt"] = {
	"葡萄牙語",
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
	standard_chars = {
		Latn = "AaÁáÂâÃãBbCcÇçDdEeÉéÊêFfGgHhIiÍíJjLlMmNnOoÓóÔôÕõPpQqRrSsTtUuÚúVvXxZz",
		Brai = c.braille,
		c.punc
	},
}

m["qu"] = {
	"克丘亞語",
	5218,
	"qwe",
	"Latn",
}

m["rm"] = {
	"羅曼什語",
	13199,
	"roa-rhe",
	ancestors = "rm-old",
	"Latn",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.diaer .. c.small_e},
}

m["ro"] = {
	"羅馬尼亞語",
	7913,
	"roa-eas",
	"Latn, Cyrl, Cyrs",
	translit = {
		Cyrl = "ro-translit"
	},
	display_text = {
		Latn = {
			from = {"'", "ţ", "Ţ"},
			to = {"’", "ț", "Ț"}
		},
	},
	strip_diacritics = {
		Latn = {
			from = {"’", "ţ", "Ţ"},
			to = {"'", "ț", "Ț"}
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.grave .. c.acute,
			from = {"ă", "â", "î", "ș", "[țţ]"},
			to = {"a" .. p[1], "a" .. p[2], "i" .. p[1], "s" .. p[1], "t" .. p[1]}
		},
		Cyrl = {
			from = {"ӂ"},
			to = {"ж" .. p[1]}
		},
	},
	-- Cyrs strip_diacritics, sort_key in [[Module:scripts/data]]; presumably not present
	standard_chars = {
		Latn = "AaĂăÂâBbCcDdEeFfGgHhIiÎîJjLlMmNnOoPpRrSsȘșTtȚțUuVvXxZz",
		Cyrl = "АаБбВвГгДдЕеЖжӁӂЗзИиЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЫыЬьЭэЮюЯя",
		c.punc
	},
}

m["ru"] = {
	"俄語",
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
	"盧旺達語",
	3217514,
	"bnt-glb",
	"Latn",
	strip_diacritics = {remove_diacritics = c.acute .. c.circ .. c.macron .. c.caron},
}

m["sa"] = {
	"梵語",
	11059,
	"inc",
	"as-Beng, Bali, Beng, Bhks, Brah, Mymr, xwo-Mong, Deva, Gujr, Guru, Gran, Hani, Java, Kthi, Knda, Kawi, Khar, Khmr, Laoo, Mlym, mnc-Mong, Marc, Modi, Mong, Nand, Newa, Orya, Phag, Ranj, Saur, Shrd, Sidd, Sinh, Soyo, Lana, Takr, Taml, Tang, Telu, Thai, Tibt, Tutg, Tirh, Zanb", --and also Khom; script codes sorted by canonical name rather than code for [[MOD:sa-convert]]
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
	"撒丁語",
	33976,
	"roa-sou",
	"Latn",
	ancestors = "sc-old",
}

m["sd"] = {
	"信德語",
	33997,
	"inc-snd",
	"Arab, Deva, Sind, Khoj",
	translit = {
		Sind = "Sind-translit",
		Arab = "sd-Arab-translit"
	},
	strip_diacritics = {
		Arab = {
			remove_diacritics = c.kashida .. c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.superalef,
			from = {"ٱ"},
			to = {"ا"}
		},
	},
}

m["se"] = {
	"北薩米語",
	33947,
	"smi",
	"Latn",
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
	"桑戈語",
	33954,
	"crp",
	"Latn",
	ancestors = "ngb",
}

m["sh"] = {
	"塞爾維亞-克羅地亞語",
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
	"僧加羅語",
	13267,
	"inc-ins",
	"Sinh",
	translit = "si-translit",
	override_translit = true,
}

m["sk"] = {
	"斯洛伐克語",
	9058,
	"zlw",
	"Latn",
	ancestors = "zlw-osk",
	sort_key = {remove_diacritics = c.acute .. c.circ .. c.diaer .. c.caron},
	standard_chars = "AaÁáÄäBbCcČčDdĎďEeÉéFfGgHhIiÍíJjKkLlĹĺĽľMmNnŇňOoÓóÔôPpRrŔŕSsŠšTtŤťUuÚúVvYyÝýZzŽž" .. c.punc,
}

m["sl"] = {
	"斯洛文尼亞語",
	9063,
	"zls",
	"Latn",
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
	"薩摩亞語",
	34011,
	"poz-pnp",
	"Latn",
}

m["sn"] = {
	"修納語",
	34004,
	"bnt-sho",
	"Latn",
	strip_diacritics = {remove_diacritics = c.acute},
}

m["so"] = {
	"索馬里語",
	13275,
	"cus-som",
	"Latn, Arab, Osma",
	strip_diacritics = {
		Latn = {remove_diacritics = c.grave .. c.acute .. c.circ}
	},
}

m["sq"] = {
	"阿爾巴尼亞語",
	8748,
	"sqj",
	"Latn, Grek, Arab, Elba, Todr, Vith",
	translit = {
		Elba = "Elba-translit",
		Vith = "Vith-translit",
	},
	-- Grek display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	strip_diacritics = {
		Latn = {
			remove_diacritics = c.acute .. c.circ .. c.macron,
			from = {'^[ie] (%w)', '^të (%w)'}, to = {'%1', '%1'},
		},
	},
	sort_key = {
		Latn = {
			remove_diacritics = c.acute .. c.circ .. c.macron .. c.tilde .. c.breve .. c.caron,
			from = {'^[ie] (%w)', '^të (%w)', 'ç', 'dh', 'ë', 'gj', 'll', 'nj', 'rr', 'sh', 'th', 'xh', 'zh'},
			to = {'%1', '%1', 'c'..p[1], 'd'..p[1], 'e'..p[1], 'g'..p[1], 'l'..p[1], 'n'..p[1], 'r'..p[1], 's'..p[1], 't'..p[1], 'x'..p[1], 'z'..p[1]},
		}
		-- TODO: Grek if the default sort key is unsuitable
	},
	standard_chars = {
		Latn = "AaBbCcÇçDdEeËëFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvXxYyZz",
		c.punc
	},
}

m["ss"] = {
	"史瓦濟語",
	34014,
	"bnt-ngu",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["st"] = {
	"塞索托語",
	34340,
	"bnt-sts",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["su"] = {
	"巽他語",
	34002,
	"poz-msa",
	"Latn, Sund, Arab",
	ancestors = "osn",
	translit = {
		Sund = "Sund-translit"
	},
}

m["sv"] = {
	"瑞典語",
	9027,
	"gmq-eas",
	"Latn",
	ancestors = "gmq-osw-lat",
	sort_key = {
		remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.macron .. c.dacute .. c.caron .. c.cedilla .. "':",
		remove_exceptions = {"å"},
		from = {"ø", "æ", "œ", "ß", "ꜩ", "å", "aͤ", "oͤ"},
		to = {"ö", "ae", "oe", "ss", "tz", "z" .. p[1], "ä", "ö"}
	},
	standard_chars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpRrSsTtUuVvXxYyÅåÄäÖö" .. c.punc,
}

m["sw"] = {
	"斯瓦希里語",
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
	"泰米爾語",
	5885,
	"dra-tam",
	"Taml",
	ancestors = "ta-mid",
	translit = "ta-translit",
	override_translit = true,
}

m["te"] = {
	"泰盧固語",
	8097,
	"dra-tel",
	"Telu",
	translit = "te-translit",
	override_translit = true,
}

m["tg"] = {
	"塔吉克語",
	9260,
	"ira-swi",
	"Cyrl, Arab, Latn",
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
	"泰語",
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
	"提格里尼亞語",
	34124,
	"sem-eth",
	"Ethi",
	translit = "Ethi-translit",
}

m["tk"] = {
	"土庫曼語",
	9267,
	"trk-ogz",
	"Latn, Cyrl, Arab",
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
	ancestors = "trk-eog",
}

m["tl"] = {
	"他加祿語",
	34057,
	"phi",
	"Latn, Tglg",
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
	"茨瓦納語",
	34137,
	"bnt-sts",
	"Latn",
}

m["to"] = {
	"湯加語",
	34094,
	"poz-ton",
	"Latn",
	strip_diacritics = {remove_diacritics = c.acute},
	sort_key = {remove_diacritics = c.macron},
}

m["tr"] = {
	"土耳其語",
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
	standard_chars = "AaÂâBbCcÇçDdEeFfGgĞğHhIıİiÎîJjKkLlMmNnOoÖöPpRrSsŞşTtUuÛûÜüVvYyZz" .. c.punc,
}

m["ts"] = {
	"聰加語",
	34327,
	"bnt-tsr",
	"Latn",
}

m["tt"] = {
	"韃靼語",
	25285,
	"trk-kbu",
	"Cyrl, Latn, Arab",
	translit = {
		Cyrl = "tt-translit",
		Arab = "tt-translit"
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

-- "tw" is treated as "ak", see [[WT:LT]]

m["ty"] = {
	"大溪地語",
	34128,
	"poz-pep",
	"Latn",
}

m["ug"] = {
	"維吾爾語",
	13263,
	"trk-kar",
	"Arab, Latn, Cyrl",
	ancestors = "chg",
	translit = {
		Arab = "ug-translit",
		Cyrl = "ug-translit",
	},
	override_translit = true,
}

m["uk"] = {
	"烏克蘭語",
	8798,
	"zle",
	"Cyrl",
	ancestors = "zle-muk",
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
	"烏爾都語",
	1617,
	"inc-hnd",
	"Aran, Hebr",
	translit = {
		Aran = "ur-translit"
	},
	strip_diacritics = {
		Aran = {
			-- character "ۂ" code U+06C2 to "ه" and "هٔ" (U+0647 + U+0654) to "ه"; hamzatu l-waṣli to a regular alif
			from = {"هٔ", "ۂ", "ٱ"},
			to = {"ہ", "ہ", "ا"},
			remove_diacritics = c.fathatan .. c.dammatan .. c.kasratan .. c.fatha .. c.damma .. c.kasra .. c.shadda .. c.sukun .. c.nunghunna .. c.superalef
		},
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
	standard_chars = {
		Aran = "ایببپتثجچحخدذرزژسشصضطظعغفقکگلࣇڷمنݨوؤہھئٹڈڑآے",
		c.punc,
	},
}

m["uz"] = {
	"烏茲別克語",
	9264,
	"trk-kar",
	"Latn, Cyrl, Arab",
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
		Arab = "ar-stripdiacritics",
	},
}

m["ve"] = {
	"文達語",
	32704,
	"bnt-bso",
	"Latn",
}

m["vi"] = {
	"越南語",
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
	"沃拉普克語",
	36986,
	"art",
	"Latn",
}

m["wa"] = {
	"瓦隆語",
	34219,
	"roa-oil",
	"Latn",
	sort_key = s["roa-oil-sortkey"],
}

m["wo"] = {
	"沃洛夫語",
	34257,
	"alv-fwo",
	"Latn, Arab, Gara",
}

m["xh"] = {
	"科薩語",
	13218,
	"bnt-ngu",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

m["yi"] = {
	"意第緒語",
	8641,
	"gmw-hgm",
	"Hebr, Latn",
	ancestors = "gmh",
	translit = {
		Hebr = "yi-translit",
	},
	-- Hebr display_text, strip_diacritics, sort_key in [[Module:scripts/data]]
}

m["yo"] = {
	"約魯巴語",
	34311,
	"alv-yor",
	"Latn, Arab",
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
	"壯語",
	13216,
	"tai",
	"Latn, Hani",
	sort_key = {
		Latn = "za-sortkey",
		Hani = "Hani-sortkey",
	},
}

m["zh"] = {
	"漢語",
	7850,
	"zhx",
	"Hants, Latn, Bopo, Nshu, Brai",
	ancestors = "ltc",
	generate_alternants = "zh-generatealternants",
	translit = {
		Hani = "zh-translit",
		Bopo = "zh-translit",
	},
	sort_key = {
		Hani = "Hani-sortkey"
	},
}

m["zu"] = {
	"祖魯語",
	10179,
	"bnt-ngu",
	"Latn",
	strip_diacritics = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
}

return require("Module:languages").finalizeData(m, "language")