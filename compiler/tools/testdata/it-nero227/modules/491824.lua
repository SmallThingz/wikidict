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
local OGONEK    = u(0x0328)

-- Puncuation to be used for standardChars field
local PUNCTUATION = ' \!\#\$\%\&\*\+\,\-\.\/\:\;\<\=\>\?\@\^\_\`\|\~\'\(\)'

local m = {}

m["aa"] = {
	canonicalName = "Afar",
	otherNames = {"Qafar"},
	scripts = {"Latn"},
	family = "cus",
}

m["ab"] = {
	canonicalName = "Abkhaz",
	otherNames = {"Abkhazian", "Abxazo"},
	scripts = {"Cyrl", "Geor", "Latn"},
	family = "cau-abz",
	translit_module = "ab-translit",
	override_translit = true,
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["ae"] = {
	canonicalName = "Avestan",
	otherNames = {"Zend", "Old Bactrian"},
	scripts = {"Avst", "Gujr"},
	family = "ira-eas",
	translit_module = "Avst-translit",
}

m["af"] = {
	canonicalName = "Afrikaans",
	scripts = {"Latn", "Arab"},
	family = "gmw",
	ancestors = {"nl"},
	sort_key = {
		from = {"[äáâà]", "[ëéêè]", "[ïíîì]", "[öóôò]", "[üúûù]", "[ÿýŷỳ]", "^-", "'"},
		to   = {"a"	 , "e"	, "i"	, "o"	, "u"  , "y" }} ,
}

m["ak"] = {
	canonicalName = "Akan",
	otherNames = {"Twi-Fante", "Twi", "Fante", "Fanti", "Asante", "Akuapem"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["am"] = {
	canonicalName = "Amharic",
	scripts = {"Ethi"},
	family = "sem-eth",
	translit_module = "Ethi-translit",
}

m["an"] = {
	canonicalName = "Aragonese",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"roa-oan"},
}

m["ar"] = {
	canonicalName = "Arabic",
	otherNames = {"Modern Standard Arabic", "Standard Arabic", "Literary Arabic", "Classical Arabic"},
	scripts = {"Arab", "Brai"},
	family = "sem-arb",
	-- alif waṣl to alif, remove diacritics
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
	translit_module = "ar-translit",
}

m["as"] = {
	canonicalName = "Assamese",
	scripts = {"Beng"},
	family = "inc",
	ancestors = {"pka"},
}

m["av"] = {
	canonicalName = "Avar",
	otherNames = {"Avaric"},
	scripts = {"Cyrl"},
	family = "cau-nec",
	ancestors = {"oav"},
	translit_module = "av-translit",
	override_translit = true,
}

m["ay"] = {
	canonicalName = "Aymara",
	otherNames = {"Southern Aymara", "Central Aymara"},
	scripts = {"Latn"},
	family = "sai-aym",
}

m["az"] = {
	canonicalName = "Azeri",
	otherNames = {"Azerbaijani", "Azari", "Azeri Turkic", "Azerbaijani Turkic", "North Azerbaijani", "South Azerbaijani", "Afshar", "Afshari", "Afshar Azerbaijani", "Afchar", "Qashqa'i", "Qashqai", "Kashkay", "Sonqor"},
	scripts = {"Latn", "Cyrl", "fa-Arab"},
	family = "trk-ogz",
}

m["ba"] = {
	canonicalName = "Bashkir",
	scripts = {"Cyrl"},
	family = "trk-kip",
	translit_module = "ba-translit",
	override_translit = true,
}

m["be"] = {
	canonicalName = "Belarusian",
	otherNames = {"Belorussian", "Belarusan", "Bielorussian", "Byelorussian", "Belarussian", "White Russian"},
	scripts = {"Cyrl"},
	family = "zle",
	translit_module = "be-translit",
	sort_key = {
		from = {"Ё", "ё"},
		to   = {"Е" , "е"}},
	entry_name = {
		from = {"Ѐ", "ѐ", GRAVE, ACUTE},
		to   = {"Е", "е"}},
}

m["bg"] = {
	canonicalName = "Bulgarian",
	scripts = {"Cyrl"},
	family = "zls",
	translit_module = "bg-translit",
	entry_name = {
		from = {"Ѐ", "ѐ", "Ѝ", "ѝ", GRAVE, ACUTE},
		to   = {"Е", "е", "И", "и"}},
}

m["bh"] = {
	canonicalName = "Bihari",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"pka"},
}

m["bi"] = {
	canonicalName = "Bislama",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["bm"] = {
	canonicalName = "Bambara",
	otherNames = {"Bamanankan"},
	scripts = {"Latn"},
	family = "dmn",
}

m["bn"] = {
	canonicalName = "Bengali",
	otherNames = {"Bangla"},
	scripts = {"Beng"},
	family = "inc",
	ancestors = {"pka"},
	translit_module = "bn-translit",
}

m["bo"] = {
	canonicalName = "Tibetan",
	otherNames = {"Ü", "Dbus", "Lhasa", "Lhasa Tibetan", "Amdo Tibetan", "Amdo", "Panang", "Khams", "Khams Tibetan", "Khamba", "Tseku", "Dolpo", "Humla", "Limi", "Lhomi", "Shing Saapa", "Mugom", "Mugu", "Nubri", "Walungge", "Gola", "Thudam", "Lowa", "Loke", "Mustang", "Tichurong"},
	scripts = {"Tibt"},
	family = "tbq",
	ancestors = {"xct"},
	translit_module = "bo-translit",
	override_translit = true,
}

m["br"] = {
	canonicalName = "Breton",
	scripts = {"Latn"},
	family = "cel-bry",
	ancestors = {"xbm"},
}

m["ca"] = {
	canonicalName = "Catalan",
	otherNames = {"Valencian"},
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"roa-oca"},
	sort_key = {
		from = {"à", "[èé]", "[íï]", "[òó]", "[úü]", "ç", "l·l"},
		to   = {"a", "e"   , "i"   , "o"   , "u"   , "c", "ll" }} ,
}

m["ce"] = {
	canonicalName = "Chechen",
	scripts = {"Cyrl"},
	family = "cau-nkh",
	translit_module = "ce-translit",
	override_translit = true,
	entry_name = {
		from = {MACRON},
		to   = {}},
}

m["ch"] = {
	canonicalName = "Chamorro",
	otherNames = {"Chamoru"},
	scripts = {"Latn"},
	family = "poz-sus",
}

m["co"] = {
	canonicalName = "Corsican",
	otherNames = {"Corsu"},
	scripts = {"Latn"},
	family = "roa",
}

m["cr"] = {
	canonicalName = "Cree",
	scripts = {"Cans", "Latn"},
	family = "alg",
	translit_module = "cr-translit",
}

m["cs"] = {
	canonicalName = "Czech",
	scripts = {"Latn"},
	family = "zlw",
	ancestors = {"zlw-ocs"},
	sort_key = {
		from = {"á", "é", "í", "ó", "[úů]", "ý"},
		to   = {"a", "e", "i", "o", "u"   , "y"}} ,
}

m["cu"] = {
	canonicalName = "Old Church Slavonic",
	otherNames = {"Old Church Slavic"},
	scripts = {"Cyrs", "Glag"},
	family = "zls",
	translit_module = "Cyrs-Glag-translit",
	entry_name = {
		from = {u(0x0484)}, -- kamora
		to   = {}},
	sort_key = {
		from = {"оу", "є"},
		to   = {"у" , "е"}} ,
}

m["cv"] = {
	canonicalName = "Chuvash",
	scripts = {"Cyrl"},
	family = "trk-ogr",
	translit_module = "cv-translit",
	override_translit = true,
}

m["cy"] = {
	canonicalName = "Welsh",
	scripts = {"Latn"},
	family = "cel-bry",
	ancestors = {"wlm"},
	sort_key = {
		from = {"[âáàä]", "[êéèë]", "[îíìï]", "[ôóòö]", "[ûúùü]", "[ŵẃẁẅ]", "[ŷýỳÿ]", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "w"	 , "y"	 }} ,
}

m["da"] = {
	canonicalName = "Danish",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"gmq-oda"},
}

m["de"] = {
	canonicalName = "German",
	otherNames = {"High German", "New High German", "Deutsch"}, -- the last name is indeed also used in English
	scripts = {"Latn", "Latf"},
	family = "gmw",
	ancestors = {"gmh"},
	sort_key = {
		from = {"[äàáâå]", "[ëèéê]", "[ïìíî]", "[öòóô]", "[üùúû]", "ß" },
		to   = {"a"	  , "e"	 , "i"	 , "o"	 , "u"	 , "ss"}} ,
}

m["dv"] = {
	canonicalName = "Dhivehi",
	otherNames = {"Divehi", "Mahal", "Mahl", "Maldivian"},
	scripts = {"Thaa"},
	family = "inc",
	ancestors = {"pmh"},
	translit_module = "dv-translit",
	override_translit = true,
}

m["dz"] = {
	canonicalName = "Dzongkha",
	scripts = {"Tibt"},
	family = "tbq",
	ancestors = {"xct"},
	translit_module = "bo-translit",
	override_translit = true,
}

m["ee"] = {
	canonicalName = "Ewe",
	scripts = {"Latn"},
	family = "alv-von",
}

m["el"] = {
	canonicalName = "Greek",
	otherNames = {"Modern Greek", "Neo-Hellenic"},
	scripts = {"Grek", "Brai"},
	family = "grk",
	ancestors = {"grc"},
	translit_module = "el-translit",
	override_translit = true,
	sort_key = {  -- Keep this synchronized with grc, cpg, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
}

m["en"] = {
	canonicalName = "English",
	otherNames = {"Modern English", "New English", "Hawaiian Creole English", "Hawai'ian Creole English", "Hawaiian Creole", "Hawai'ian Creole", "Polari", "Yinglish"}, -- all but the first three are names and alt names of subsumed dialects which once had ISO codes
	scripts = {"Latn", "Brai", "Shaw", "Dsrt"}, -- last two are rare but probably attested; entries in them might require community approval, but it's good for the script codes not to be orphans
	family = "gmw",
	ancestors = {"enm"},
	sort_key = {
		from = {"[äàáâåā]", "[ëèéêē]", "[ïìíîī]", "[öòóôō]", "[üùúûū]", "æ" , "œ" , "[çč]", "ñ", "'"},
		to   = {"a"       , "e"      , "i"      , "o"      , "u"      , "ae", "oe", "c"   , "n"}},
	wikimedia_codes = {"en", "simple"},
	standardChars = "A-Za-z0-9" .. PUNCTUATION .. u(0x2800) .. "-" .. u(0x28FF)
}

m["eo"] = {
	canonicalName = "Esperanto",
	scripts = {"Latn"},
	family = "art",
	sort_key = {
		from = {"[áà]", "[éè]", "[íì]", "[óò]", "[úù]", "[ĉ]", "[ĝ]", "[ĥ]", "[ĵ]", "[ŝ]", "[ŭ]"},
		to   = {"a"	   , "e"  , "i"  , "o"  , "u", "cĉ", "gĉ", "hĉ", "jĉ", "sĉ", "uĉ"}} ,
}

m["es"] = {
	canonicalName = "Spanish",
	otherNames = {"Castilian", "Amazonian Spanish", "Amazonic Spanish", "Loreto-Ucayali Spanish"},
	scripts = {"Latn", "Brai"},
	family = "roa",
	ancestors = {"osp"},
	sort_key = {
		from = {"á", "é", "í", "ó", "[úü]", "ç", "ñ"},
		to   = {"a", "e", "i", "o", "u"   , "c", "n"}},
	standardChars = "A-VXYZa-vxyz0-9ÁáÉéÍíÓóÚúÑñ¿¡" .. PUNCTUATION
}

m["et"] = {
	canonicalName = "Estonian",
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["eu"] = {
	canonicalName = "Basque",
	otherNames = {"Euskara"},
	scripts = {"Latn"},
	family = "euq",
}

m["fa"] = {
	canonicalName = "Persian",
	otherNames = {"Farsi", "New Persian", "Modern Persian", "Western Persian", "Iranian Persian", "Eastern Persian", "Dari", "Aimaq", "Aimak", "Aymaq", "Eimak"},
	scripts = {"fa-Arab"},
	family = "ira-wes",
	ancestors = {"pal"},
	entry_name = {
		from = {u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652)},
		to   = {}} ,
}

m["ff"] = {
	canonicalName = "Fula",
	otherNames = {"Adamawa Fulfulde", "Bagirmi Fulfulde", "Borgu Fulfulde", "Central-Eastern Niger Fulfulde", "Fulani", "Fulfulde", "Maasina Fulfulde", "Nigerian Fulfulde", "Pular", "Pulaar", "Western Niger Fulfulde"}, -- Maasina, etc are dialects, subsumed into this code
	scripts = {"Latn"},
	family = "alv-sng",
}

m["fi"] = {
	canonicalName = "Finnish",
	otherNames = {"Suomi", "Botnian"},
	scripts = {"Latn"},
	family = "fiu-fin",
	entry_name = {
		from = {"ˣ"},  -- Used to indicate gemination of the next consonant
		to   = {}},
	sort_key = {
		from = {"[áàâã]", "[éèêẽ]", "[íìîĩ]", "[óòôõ]", "[úùûũ]", "[ýỳŷüű]", "[øõő]", "æ" , "œ" , "[čç]", "š", "ž", "ß" , "[':]"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 ,  "y"	 , "ö"	, "ae", "oe", "c"   , "s", "z", "ss"}} ,
}

m["fj"] = {
	canonicalName = "Fijian",
	scripts = {"Latn"},
	family = "poz-occ",
}

m["fo"] = {
	canonicalName = "Faroese",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"non"},
}

m["fr"] = {
	canonicalName = "French",
	otherNames = {"Modern French"},
	scripts = {"Latn", "Brai"},
	family = "roa",
	ancestors = {"frm"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "æ" , "œ" , "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c", "ae", "oe"}},
	standardChars = "A-Za-z0-9ÀÂÇÉÈÊËÎÏÔŒÛÙÜàâçéèêëîïôœûùü«»" .. PUNCTUATION
}

m["fy"] = {
	canonicalName = "West Frisian",
	otherNames = {"Western Frisian", "Frisian"},
	scripts = {"Latn"},
	family = "gmw-fri",
	ancestors = {"ofs"},
}

m["ga"] = {
	canonicalName = "Irish",
	otherNames = {"Irish Gaelic"},
	scripts = {"Latn"},
	family = "cel-gae",
	ancestors = {"mga"},
	sort_key = {
		from = {"á", "é", "í", "ó", "ú", "ý", "ḃ" , "ċ" , "ḋ" , "ḟ" , "ġ" , "ṁ" , "ṗ" , "ṡ" , "ṫ" },
		to   = {"a", "e", "i", "o", "u", "y", "bh", "ch", "dh", "fh", "gh", "mh", "ph", "sh", "th"}} ,
}

m["gd"] = {
	canonicalName = "Scottish Gaelic",
	otherNames = {"Gàidhlig", "Highland Gaelic", "Scots Gaelic", "Scottish"},
	scripts = {"Latn"},
	family = "cel-gae",
	ancestors = {"mga"},
	sort_key = {
		from = {"[áà]", "[éè]", "[íì]", "[óò]", "[úù]", "[ýỳ]"},
		to   = {"a"   , "e"   , "i"   , "o"   , "u"   , "y"   }} ,
}

m["gl"] = {
	canonicalName = "Galician",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"roa-opt"},
	sort_key = {
		from = {"á", "é", "í", "ó", "ú"},
		to   = {"a", "e", "i", "o", "u"}} ,
}

m["gn"] = {
	canonicalName = "Guaraní",
	scripts = {"Latn"},
	family = "tup-gua",
}

m["gu"] = {
	canonicalName = "Gujarati",
	scripts = {"Gujr"},
	family = "inc",
	ancestors = {"inc-ogu"},
	translit_module = "gu-translit",
}

m["gv"] = {
	canonicalName = "Manx",
	otherNames = {"Manx Gaelic"},
	scripts = {"Latn"},
	family = "cel-gae",
	ancestors = {"mga"},
	sort_key = {
		from = {"ç", "-"},
		to   = {"c"}} ,
}

m["ha"] = {
	canonicalName = "Hausa",
	scripts = {"Latn", "Arab"},
	family = "cdc-wst",
}

m["he"] = {
	canonicalName = "Hebrew",
	otherNames = {"Ivrit"},
	scripts = {"Hebr", "Phnx", "Brai"},
	family = "sem-can",
	entry_name = {
		from = {"[" .. u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. "]"},
		to   = {}} ,
}

m["hi"] = {
	canonicalName = "Hindi",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"inc-ohi"},
	translit_module = "hi-translit",
}

m["ho"] = {
	canonicalName = "Hiri Motu",
	otherNames = {"Pidgin Motu", "Police Motu"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"meu"},
}

m["ht"] = {
	canonicalName = "Haitian Creole",
	otherNames = {"Creole", "Haitian", "Kreyòl"},
	scripts = {"Latn"},
	family = "crp",
}

m["hu"] = {
	canonicalName = "Hungarian",
	otherNames = {"Magyar"},
	scripts = {"Latn"},
	family = "urj-ugr",
	ancestors = {"ohu"},
	sort_key = {
		from = {"á", "é", "í", "ó", "ú", "ő", "ű"},
		to   = {"a", "e", "i", "o", "u", "ö", "ü"}} ,
}

m["hy"] = {
	canonicalName = "Armenian",
	otherNames = {"Modern Armenian", "Eastern Armenian", "Western Armenian"},
	scripts = {"Armn", "Brai"},
	family = "hyx",
	ancestors = {"axm"},
	translit_module = "Armn-translit",
	override_translit = true,
	sort_key = {
		from = {"ու", "և", "եւ"},
		to   = {"ւ", "եվ", "եվ"}},
	entry_name = {
		from = {"՞", "՜", "՛", "՟", "և", "<sup>յ</sup>", "<sup>ի</sup>"},
		to   = {"", "", "", "", "եւ", "յ", "ի"}} ,
}

m["hz"] = {
	canonicalName = "Herero",
	scripts = {"Latn"},
	family = "bnt",
}

m["ia"] = {
	canonicalName = "Interlingua",
	scripts = {"Latn"},
	family = "art",
}

m["id"] = {
	canonicalName = "Indonesian",
	scripts = {"Latn"},
	family = "poz-mly",
	ancestors = {"ms"},
}

m["ie"] = {
	canonicalName = "Interlingue",
	otherNames = {"Occidental"},
	scripts = {"Latn"},
	family = "art",
}

m["ig"] = {
	canonicalName = "Igbo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ii"] = {
	canonicalName = "Sichuan Yi",
	otherNames = {"Nuosu", "Nosu", "Northern Yi", "Liangshan Yi"},
	scripts = {"Yiii"},
	family = "tbq-lol",
}

m["ik"] = {
	canonicalName = "Inupiak",
	otherNames = {"Inupiaq", "Iñupiaq", "Inupiatun"},
	scripts = {"Latn"},
	family = "esx-inu",
}

m["io"] = {
	canonicalName = "Ido",
	scripts = {"Latn"},
	family = "art",
}

m["is"] = {
	canonicalName = "Icelandic",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"non"},
}

m["it"] = {
	canonicalName = "Italian",
	scripts = {"Latn"},
	family = "roa",
	sort_key = {
		from = {"[àáâäå]", "[èéêë]", "[ìíîï]", "[òóôö]", "[ùúûü]"},
		to   = {"a"	  , "e"	 , "i"	 , "o"	 , "u"	 }} ,
}

m["iu"] = {
	canonicalName = "Inuktitut",
	otherNames = {"Eastern Canadian Inuktitut", "Eastern Canadian Inuit", "Western Canadian Inuktitut", "Western Canadian Inuit", "Western Canadian Inuktun", "Inuinnaq", "Inuinnaqtun", "Inuvialuk", "Inuvialuktun", "Nunavimmiutit", "Nunatsiavummiut", "Aivilimmiut", "Natsilingmiut", "Kivallirmiut", "Siglit", "Siglitun"},
	scripts = {"Cans", "Latn"},
	family = "esx-inu",
	translit_module = "iu-translit",
	override_translit = true,
}

m["ja"] = {
	canonicalName = "Giapponese",
	otherNames = {"Modern Japanese", "Nipponese", "Nihongo"},
	scripts = {"Jpan", "Latn", "Hira", "Brai"},
	family = "jpx",
	ancestors = {"ojp"},
	sort_key = {
		from = {"[ぁァア]", "[ぃィイ]", "[ぅゔゥウヴ]", "[ぇェエ]", "[ぉォオ]", "[がゕカガヵ]", "[ぎキギ]", "[ぐクグㇰ]", "[げゖケゲヶ]", "[ごコゴ]", "[ざサザ]", "[じシジㇱ]", "[ずスズㇲ]", "[ぜセゼ]", "[ぞソゾ]", "[だタダ]", "[ぢチヂ]", "[っづッツヅ]", "[でテデ]", "[どトドㇳ]", "ナ", "ニ", "[ヌㇴ]", "ネ", "ノ", "[ばぱハバパㇵ]", "[びぴヒビピㇶ]", "[ぶぷフブプㇷ]", "[べぺヘベペㇸ]", "[ぼぽホボポㇹ]", "マ", "ミ", "[ムㇺ]", "メ", "モ", "[ゃャヤ]", "[ゅュユ]", "[ょョヨ]", "[ラㇻ]", "[リㇼ]", "[ルㇽ]", "[レㇾ]", "[ロㇿ]", "[ゎヮワヷ]", "[ヰヸ]", "[ヱヹ]", "[ヲヺ]", "ン", "[゙゚゛゜ゝゞ・ヽヾ]", "𛀀"},
		to   = {"あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ", "さ", "し", "す", "せ", "そ", "た", "ち", "つ", "て", "と", "な", "に", "ぬ", "ね", "の", "は", "ひ", "ふ", "へ", "ほ", "ま", "み", "む", "め", "も", "や", "ゆ", "よ", "ら", "り", "る", "れ", "ろ", "わ", "ゐ", "ゑ", "を", "ん", "", "え"}},
}

m["jv"] = {
	canonicalName = "Javanese",
	scripts = {"Latn", "Java"},
	family = "poz-sus",
	translit_module = "jv-translit",
	ancestors = {"kaw"},
	link_tr = true,
}

m["ka"] = {
	canonicalName = "Georgian",
	otherNames = {"Kartvelian", "Judeo-Georgian", "Kivruli", "Gruzinic"},
	scripts = {"Geor", "Geok", "Hebr"}, -- Hebr is used to write Judeo-Georgian
	family = "ccs-gzn",
	ancestors = {"oge"},
	translit_module = "Geor-translit",
	override_translit = true,
	entry_name = {
		from = {"̂"},
		to   = {""}},
}

m["kg"] = {
	canonicalName = "Kongo",
	otherNames = {"Kikongo", "Koongo", "Laari", "San Salvador Kongo", "Yombe"},
	scripts = {"Latn"},
	family = "bnt",
}

m["ki"] = {
	canonicalName = "Kikuyu",
	otherNames = {"Gikuyu", "Gĩkũyũ"},
	scripts = {"Latn"},
	family = "bnt",
}

m["kj"] = {
	canonicalName = "Kwanyama",
	otherNames = {"Kuanyama", "Oshikwanyama"},
	scripts = {"Latn"},
	family = "bnt",
}

m["kk"] = {
	canonicalName = "Kazakh",
	scripts = {"Cyrl", "Latn", "Arab", "kk-Arab"},
	family = "trk-kip",
	translit_module = "kk-translit",
	override_translit = true,
}

m["kl"] = {
	canonicalName = "Greenlandic",
	otherNames = {"Kalaallisut"},
	scripts = {"Latn"},
	family = "esx-inu",
}

m["km"] = {
	canonicalName = "Khmer",
	otherNames = {"Cambodian"},
	scripts = {"Khmr"},
	family = "mkh",
	ancestors = {"mkh-mkm"},
	translit_module = "km-translit",
}

m["kn"] = {
	canonicalName = "Kannada",
	scripts = {"Knda"},
	family = "dra",
	translit_module = "kn-translit",
}

m["ko"] = {
	canonicalName = "Korean",
	otherNames = {"Modern Korean"},
	scripts = {"Kore", "Brai"},
	family = "qfa-kor",
	ancestors = {"okm"},
	translit_module = "ko-translit",
}

m["kr"] = {
	canonicalName = "Kanuri",
	otherNames = {"Kanembu", "Bilma Kanuri", "Central Kanuri", "Manga Kanuri", "Tumari Kanuri"},
	scripts = {"Latn"},
	family = "ssa-sah",
}

m["ks"] = {
	canonicalName = "Kashmiri",
	scripts = {"ks-Arab", "Deva"},
	family = "inc-dar",
}

m["ku"] = {
	canonicalName = "Kurdish",
	scripts = {"Latn", "ku-Arab", "Armn", "Cyrl"},
	family = "ira-wes",
}

m["kw"] = {
	canonicalName = "Cornish",
	scripts = {"Latn"},
	family = "cel-bry",
	ancestors = {"cnx"},
}

m["ky"] = {
	canonicalName = "Kyrgyz",
	otherNames = {"Kirghiz", "Kirgiz"},
	scripts = {"Cyrl", "Latn", "Arab"},
	family = "trk-kip",
	translit_module = "ky-translit",
	override_translit = true,
}

m["la"] = {
	canonicalName = "Latin",
	scripts = {"Latn"},
	family = "itc",
	ancestors = {"itc-ola"},
	entry_name = {
		from = {"[ĀĂ]", "[āă]", "[ĒĔ]", "[ēĕë]", "[ĪĬÏ]", "[īĭï]", "[ŌŎ]", "[ōŏ]", "[ŪŬÜ]", "[ūŭü]", "Ȳ", "ȳ", MACRON, BREVE, DIAER},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}},
}

m["lb"] = {
	canonicalName = "Luxembourgish",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmh"},
}

m["lg"] = {
	canonicalName = "Luganda",
	otherNames = {"Ganda", "Oluganda"},
	scripts = {"Latn"},
	family = "bnt",
	entry_name = {
		from = {"á", "Á", "é", "É", "í", "Í", "ó", "Ó", "ú", "Ú", "ń", "Ń", "ḿ", "Ḿ", "â", "Â", "ê", "Ê", "î", "Î", "ô", "Ô", "û", "Û" },
		to   = {"a", "A", "e", "E", "i", "I", "o", "O", "u", "U", "n", "N", "m", "M", "a", "A", "e", "E", "i", "I", "o", "O", "u", "U",}},
	sort_key = {
		from = {"ŋ"},
		to   = {"n"}} 
}

m["li"] = {
	canonicalName = "Limburgish",
	otherNames = {"Limburgan", "Limburgian", "Limburgic"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"dum"},
}

m["ln"] = {
	canonicalName = "Lingala",
	scripts = {"Latn"},
	family = "bnt",
}

m["lo"] = {
	canonicalName = "Lao",
	otherNames = {"Laotian"},
	scripts = {"Laoo"},
	family = "tai-swe",
	translit_module = "lo-translit",
	sort_key = {
		from = {"ຼ", "ຽ", "ໜ", "ໝ", "([ເແໂໃໄ])([ກ-ຮ])"},
		to   = {"ລ", "ຍ", "ຫນ", "ຫມ", "%2%1"}},
}

m["lt"] = {
	canonicalName = "Lithuanian",
	scripts = {"Latn"},
	family = "bat",
	ancestors = {"olt"},
	entry_name = {
		from = {"[áãà]", "[ÁÃÀ]", "[éẽè]", "[ÉẼÈ]", "[íĩì]", "[ÍĨÌ]", "[ýỹ]", "[ÝỸ]", "ñ", "[óõò]", "[ÓÕÒ]", "[úũù]", "[ÚŨÙ]", ACUTE, GRAVE, TILDE},
		to   = {"a",       "A",     "e",     "E",     "i",     "I",     "y",   "Y",   "n",   "o",    "O",     "u",      "U"}} ,
}

m["lu"] = {
	canonicalName = "Luba-Katanga",
	scripts = {"Latn"},
	family = "bnt",
}

m["lv"] = {
	canonicalName = "Latvian",
	otherNames = {"Lettish", "Lett"},
	scripts = {"Latn"},
	family = "bat",
	entry_name = {
		-- This attempts to convert vowels with tone marks to vowels either with
		-- or without macrons. Specifically, there should be no macrons if the
		-- vowel is part of a diphthong (including resonant diphthongs such
		-- pìrksts -> pirksts not #pīrksts). What we do is first convert the
		-- vowel + tone mark to a vowel + tilde in a decomposed fashion,
		-- then remove the tilde in diphthongs, then convert the remaining
		-- vowel + tilde sequences to macroned vowels, then delete any other
		-- tilde. We leave already-macroned vowels alone: Both e.g. ar and ār
		-- occur before consonants. FIXME: This still might not be sufficient.
		from = {"Ȩ", "ȩ", "[ÂÃÀ]", "[âãà]", "[ÊẼÈ]", "[êẽè]", "[ÎĨÌ]", "[îĩì]", "[ÔÕÒ]", "[ôõò]", "[ÛŨÙ]", "[ûũù]", "[ÑǸ]", "[ñǹ]", "[" .. CIRC .. TILDE ..GRAVE .."]", "([aAeEiIoOuU])" .. TILDE .."?([lrnmuiLRNMUI])" .. TILDE .. "?([^aAeEiIoOuUāĀēĒīĪūŪ])", "([aAeEiIoOuU])" .. TILDE .."?([lrnmuiLRNMUI])" .. TILDE .."?$", "([iI])" .. TILDE .. "?([eE])" .. TILDE .. "?", "A" .. TILDE, "a" .. TILDE, "E" .. TILDE, "e" .. TILDE, "I" .. TILDE, "i" .. TILDE, "U" .. TILDE, "u" .. TILDE, TILDE},
		to   = {"E", "e", "A" .. TILDE, "a" .. TILDE, "E" .. TILDE, "e" .. TILDE, "I" .. TILDE, "i" .. TILDE, "O", "o", "U" .. TILDE, "u" .. TILDE, "N", "n", TILDE, "%1%2%3", "%1%2", "%1%2", "Ā", "ā", "Ē", "ē", "Ī", "ī", "Ū", "ū", ""}},
}

m["mg"] = {
	canonicalName = "Malagasy",
	otherNames = {"Betsimisaraka Malagasy", "Betsimisaraka", "Northern Betsimisaraka Malagasy", "Northern Betsimisaraka", "Southern Betsimisaraka Malagasy", "Southern Betsimisaraka", "Bara Malagasy", "Bara", "Masikoro Malagasy", "Masikoro", "Antankarana", "Antankarana Malagasy", "Plateau Malagasy", "Sakalava", "Tandroy Malagasy", "Tandroy", "Tanosy", "Tanosy Malagasy", "Tesaka", "Tsimihety", "Tsimihety Malagasy", "Bushi", "Shibushi", "Kibushi", "Sakalava"},
	scripts = {"Latn"},
	family = "poz-bre",
}

m["mh"] = {
	canonicalName = "Marshallese",
	scripts = {"Latn"},
	family = "poz-mic",
	sort_key = {
		from = {"ā" , "ļ" , "m̧" , "ņ" , "n̄"  , "o̧" , "ō"  , "ū" },
		to   = {"a~", "l~", "m~", "n~", "n~~", "o~", "o~~", "u~"}} ,
}

m["mi"] = {
	canonicalName = "Maori",
	otherNames = {"Māori"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["mk"] = {
	canonicalName = "Macedonian",
	scripts = {"Cyrl"},
	family = "zls",
	translit_module = "mk-translit",
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["ml"] = {
	canonicalName = "Malayalam",
	scripts = {"Mlym"},
	family = "dra",
	translit_module = "ml-translit",
	override_translit = true,
}

m["mn"] = {
	canonicalName = "Mongolian",
	otherNames = {"Khalkha Mongolian"},
	scripts = {"Cyrl", "Mong"},
	family = "xgn",
	ancestors = {"cmg"},
	translit_module = "mn-translit",
	override_translit = true,
}

m["mr"] = {
	canonicalName = "Marathi",
	scripts = {"Deva", "Modi"},
	family = "inc",
	ancestors = {"omr"},
	translit_module = "hi-translit",
}

m["ms"] = {
	canonicalName = "Malay",
	otherNames = {"Malaysian", "Standard Malay", "Orang Seletar", "Orang Kanaq", "Jakun", "Temuan"},
	scripts = {"Latn", "Arab"},
	family = "poz-mly",
}

m["mt"] = {
	canonicalName = "Maltese",
	scripts = {"Latn"},
	family = "sem-arb",
	ancestors = {"sqr"},
}

m["my"] = {
	canonicalName = "Burmese",
	otherNames = {"Myanmar"},
	scripts = {"Mymr"},
	family = "tbq-brm",
	ancestors = {"obr"},
	translit_module = "my-translit",
	override_translit = true,
}

m["na"] = {
	canonicalName = "Nauruan",
	otherNames = {"Nauru"},
	scripts = {"Latn"},
	family = "poz-mic",
}

m["nb"] = {
	canonicalName = "Norwegian Bokmål",
	otherNames = {"Bokmål"},
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"gmq-mno"},
	wikimedia_codes = {"no"},
}

m["nd"] = {
	canonicalName = "Northern Ndebele",
	otherNames = {"North Ndebele"},
	scripts = {"Latn"},
	family = "bnt-ngu",
	entry_name = {
		from = {"[āàáâǎ]", "[ēèéêě]", "[īìíîǐ]", "[ōòóôǒ]", "[ūùúûǔ]", "ḿ", "[ǹńň]", MACRON, ACUTE, GRAVE, CIRC, CARON},
		to   = {"a"      , "e"      , "i"      , "o"      , "u"      , "m", "n"    }},
}

m["ne"] = {
	canonicalName = "Nepali",
	otherNames = {"Nepalese"},
	scripts = {"Deva"},
	family = "inc",
	translit_module = "ne-translit",
}

m["ng"] = {
	canonicalName = "Ndonga",
	scripts = {"Latn"},
	family = "bnt",
}

m["nl"] = {
	canonicalName = "Dutch",
	otherNames = {"Netherlandic", "Flemish"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"dum"},
	sort_key = {
		from = {"[äáâå]", "[ëéê]", "[ïíî]", "[öóô]", "[üúû]", "ç", "ñ", "^-"},
		to   = {"a"	 , "e"	, "i"	, "o"	, "u"	, "c", "n"}} ,
	standardChars = "A-Za-z0-9" .. PUNCTUATION .. u(0x2800) .. "-" .. u(0x28FF),
}

m["nn"] = {
	canonicalName = "Norwegian Nynorsk",
	otherNames = {"New Norwegian", "Nynorsk"},
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"gmq-mno"},
}

m["no"] = {
	canonicalName = "Norwegian",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"gmq-mno"},
}

m["nr"] = {
	canonicalName = "Southern Ndebele",
	otherNames = {"South Ndebele"},
	scripts = {"Latn"},
	family = "bnt-ngu",
	entry_name = {
		from = {"[āàáâǎ]", "[ēèéêě]", "[īìíîǐ]", "[ōòóôǒ]", "[ūùúûǔ]", "ḿ", "[ǹńň]", MACRON, ACUTE, GRAVE, CIRC, CARON},
		to   = {"a"      , "e"      , "i"      , "o"      , "u"      , "m", "n"    }},
}

m["nv"] = {
	canonicalName = "Navajo",
	otherNames = {"Navaho", "Diné bizaad"},
	scripts = {"nv-Latn"},
	family = "apa",
	sort_key = {
		from = {"[áą]", "[éę]", "[íį]", "[óǫ]", "ń", "^n([djlt])", "ł" , "[ʼ’']", ACUTE},
		to   = {"a"   , "e"   , "i"   , "o"   , "n", "ni%1"	  , "l"}}, -- the copyright sign is used to guarantee that ł will always be sorted after all other words with l
}

m["ny"] = {
	canonicalName = "Chichewa",
	otherNames = {"Chicheŵa", "Chinyanja", "Nyanja", "Chewa", "Cicewa", "Cewa", "Cinyanja"},
	scripts = {"Latn"},
	family = "bnt",
	entry_name = {
		from = {"ŵ", "Ŵ", "á", "Á", "é", "É", "í", "Í", "ó", "Ó", "ú", "Ú", "ń", "Ń", "ḿ", "Ḿ" },
		to   = {"w", "W", "a", "A", "e", "E", "i", "I", "o", "O", "u", "U", "n", "N", "m", "M"}},
	sort_key = {
		from = {"ng'"},
		to   = {"ng"}} 
}

m["oc"] = {
	canonicalName = "Occitan",
	otherNames = {"Provençal", "Auvergnat", "Auvernhat", "Gascon", "Languedocien", "Lengadocian", "Shuadit", "Chouhadite", "Chouhadit", "Chouadite", "Chouadit", "Shuhadit", "Judeo-Provençal", "Judeo-Provencal", "Judeo-Comtadin"},
	scripts = {"Latn", "Hebr"},
	family = "roa",
	ancestors = {"pro"},
	sort_key = {
		from = {"[àá]", "[èé]", "[íï]", "[òó]", "[úü]", "ç", "([lns])·h"},
		to   = {"a"   , "e"   , "i"   , "o"   , "u"   , "c", "%1h"	  }} ,
}

m["oj"] = {
	canonicalName = "Ojibwe",
	otherNames = {"Chippewa", "Ojibway", "Ojibwemowin", "Southwestern Ojibwa"},
	scripts = {"Cans", "Latn"},
	family = "alg",
}

m["om"] = {
	canonicalName = "Oromo",
	otherNames = {"Orma", "Borana-Arsi-Guji Oromo", "West Central Oromo"},
	scripts = {"Latn", "Ethi"},
	family = "cus",
}

m["or"] = {
	canonicalName = "Oriya",
	otherNames = {"Odia", "Oorya"},
	scripts = {"Orya"},
	family = "inc",
	ancestors = {"pka"},
}

m["os"] = {
	canonicalName = "Ossetian",
	otherNames = {"Ossete", "Ossetic", "Digor", "Iron"},
	scripts = {"Cyrl", "Geor", "Latn"},
	family = "ira",
	translit_module = "os-translit",
	override_translit = true,
	ancestors = {"oos"},
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["pa"] = {
	canonicalName = "Punjabi",
	otherNames = {"Panjabi"},
	scripts = {"Guru", "Arab", "Deva"},
	family = "inc",
	translit_module = "pa-translit",
}

m["pi"] = {
	canonicalName = "Pali",
	scripts = {"Latn", "Deva", "Sinh", "Mymr", "Khmr", "Thai"},
	family = "inc",
	ancestors = {"bh"},
	sort_key = {
		from = {"ā", "ī", "ū", "ḍ", "ḷ", "[ṁṃ]", "[ṇñṅ]", "ṭ"},
		to   = {"a", "i", "u", "d", "l", "m"   , "n"	, "t"}} ,
}

m["pl"] = {
	canonicalName = "Polish",
	scripts = {"Latn"},
	family = "zlw",
	ancestors = {"zlw-opl"},
	sort_key = {
		from = {"[Ąą]", "[Ćć]", "[Ęę]", "[Łł]", "[Ńń]", "[Óó]", "[Śś]", "[Żż]", "[Źź]"},
		to   = {
			"a" .. u(0x10FFFF),
			"c" .. u(0x10FFFF),
			"e" .. u(0x10FFFF),
			"l" .. u(0x10FFFF),
			"n" .. u(0x10FFFF),
			"o" .. u(0x10FFFF),
			"s" .. u(0x10FFFF),
			"z" .. u(0x10FFFF),
			"z" .. u(0x10FFFE)}} ,
}

m["ps"] = {
	canonicalName = "Pashto",
	otherNames = {"Pashtun", "Pushto", "Pashtu", "Central Pashto", "Northern Pashto", "Southern Pashto", "Pukhto", "Pakhto", "Pakkhto", "Afghani"},
	scripts = {"ps-Arab"},
	family = "ira-eas",
}

m["pt"] = {
	canonicalName = "Portuguese",
	otherNames = {"Modern Portuguese"},
	scripts = {"Latn", "Brai"},
	family = "roa",
	ancestors = {"roa-opt"},
	sort_key = {
		from = {"[àãáâä]", "[èẽéêë]", "[ìĩíï]", "[òóôõö]", "[üúùũ]", "ç", "ñ"},
		to   = {"a"	  , "e"	  , "i"	 , "o"	  , "u"	 , "c", "n"}} ,
}

m["qu"] = {
	canonicalName = "Quechua",
	scripts = {"Latn"},
	family = "qwe",
}

m["rm"] = {
	canonicalName = "Romansch",
	otherNames = {"Romansh", "Rumantsch", "Romanche"},
	scripts = {"Latn"},
	family = "roa",
}

m["ro"] = {
	canonicalName = "Romanian",
	otherNames = {"Daco-Romanian", "Roumanian", "Rumanian"},
	scripts = {"Latn", "Cyrl"},
	family = "roa",
	sort_key = {
        from = {"ă" , "â"  , "î" , "ș" , "ț" },
        to   = {"a~", "a~~", "i~", "s~", "t~"}},
}

m["ru"] = {
	canonicalName = "Russian",
	scripts = {"Cyrl", "Brai"},
	family = "zle",
	translit_module = "ru-translit",
	sort_key = {
		from = {"ё"},
		to   = {"е" .. mw.ustring.char(0x10FFFF)}},
	entry_name = {
		from = {"Ѐ", "ѐ", "Ѝ", "ѝ", GRAVE, ACUTE},
		to   = {"Е", "е", "И", "и"}},
	standardChars = "ЁІА-яёі0-9—" .. PUNCTUATION,
}

m["rw"] = {
	canonicalName = "Rwanda-Rundi",
	otherNames = {"Rwanda", "Kinyarwanda", "Rundi", "Kirundi", "Ha", "Giha", "Hangaza", "Vinza", "Shubi", "Subi"},
	scripts = {"Latn"},
	family = "bnt",
}

m["sa"] = {
	canonicalName = "Sanskrit",
	scripts = {"Deva", "Beng", "Brah", "Gran", "Gujr", "Guru", "Khar", "Knda", "Mlym", "Mymr", "Orya", "Shrd", "Sinh", "Taml", "Telu", "Thai", "Tibt"},
	family = "inc",
	translit_module = "sa-translit",
}

m["sc"] = {
	canonicalName = "Sardinian",
	otherNames = {"Campidanese", "Campidanese Sardinian", "Logudorese", "Logudorese Sardinian", "Nuorese", "Nuorese Sardinian"},
	scripts = {"Latn"},
	family = "roa",
}

m["sd"] = {
	canonicalName = "Sindhi",
	scripts = {"sd-Arab", "Deva"},
	family = "inc",
}

m["se"] = {
	canonicalName = "Northern Sami",
	otherNames = {"North Sami", "Northern Saami", "North Saami"},
	scripts = {"Latn"},
	family = "smi",
	entry_name = {
		from = {"([đflmnŋrsšŧv])'%1"},
		to   = {"%1%1"} },
}

m["sg"] = {
	canonicalName = "Sango",
	scripts = {"Latn"},
	family = "crp",
}

m["sh"] = {
	canonicalName = "Serbo-Croatian",
	otherNames = {"BCS", "Croato-Serbian", "Serbocroatian", "Bosnian", "Croatian", "Montenegrin", "Serbian"},
	scripts = {"Latn", "Cyrl"},
	family = "zls",
	entry_name = {
		from = {"[ȀÀȂÁĀÃ]", "[ȁàȃáāã]", "[ȄÈȆÉĒẼ]", "[ȅèȇéēẽ]", "[ȈÌȊÍĪĨ]", "[ȉìȋíīĩ]", "[ȌÒȎÓŌÕ]", "[ȍòȏóōõ]", "[ȐȒŔ]", "[ȑȓŕ]", "[ȔÙȖÚŪŨ]", "[ȕùȗúūũ]", "Ѐ", "ѐ", "[ӢЍ]", "[ӣѝ]", "[Ӯ]", "[ӯ]", GRAVE, ACUTE, DGRAVE, INVBREVE, MACRON, TILDE},
		to   = {"A"	  , "a"	  , "E"	  , "e"	  , "I"	  , "i"	  , "O"	  , "o"	  , "R"	, "r"	, "U"	  , "u"	  , "Е", "е", "И"   , "и", "У", "у"   }},
	wikimedia_codes = {"sh", "bs", "hr", "sr"},
}

m["si"] = {
	canonicalName = "Sinhalese",
	otherNames = {"Singhalese", "Sinhala"},
	scripts = {"Sinh"},
	family = "inc",
	ancestors = {"pmh"},
	translit_module = "si-translit",
	override_translit = true,
}

m["sk"] = {
	canonicalName = "Slovak",
	scripts = {"Latn"},
	family = "zlw",
	sort_key = {
		from = {"[áä]", "é", "í", "[óô]", "ú", "ý", "ŕ", "ĺ"},
		to   = {"a"   , "e", "i", "o"   , "u", "y", "r", "l"}} ,
}

m["sl"] = {
	canonicalName = "Slovene",
	otherNames = {"Slovenian"},
	scripts = {"Latn"},
	family = "zls",
	entry_name = {
		from = {"[ÁÀÂȂȀ]", "[áàâȃȁ]", "[ÉÈÊȆȄỆẸ]", "[éèêȇȅệẹə]", "[ÍÌÎȊȈ]", "[íìîȋȉ]", "[ÓÒÔȎȌỘỌ]", "[óòôȏȍộọ]", "[ŔȒȐ]", "[ŕȓȑ]", "[ÚÙÛȖȔ]", "[úùûȗȕ]", "ł", GRAVE, ACUTE, DGRAVE, INVBREVE, CIRC, DOTBELOW},
		to   = {"A"	  , "a"	  , "E"		, "e"		 , "I"	  , "i"	  , "O"		, "o"		, "R"	, "r"	, "U"	  , "u"	  , "l"}} ,
}

m["sm"] = {
	canonicalName = "Samoan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["sn"] = {
	canonicalName = "Shona",
	scripts = {"Latn"},
	family = "bnt",
}

m["so"] = {
	canonicalName = "Somali",
	scripts = {"Latn", "Arab", "Osma"},
	family = "cus",
	entry_name = {
		from = {"[ÁÀÂ]", "[áàâ]", "[ÉÈÊ]", "[éèê]", "[ÍÌÎ]", "[íìî]", "[ÓÒÔ]", "[óòô]", "[ÚÙÛ]", "[úùû]", "[ÝỲ]", "[ýỳ]"},
		to   = {"A"	  , "a"	  , "E"	, "e" , "I"	  , "i"	  , "O"	, "o"	, "U"  , "u", "Y", "y"}} ,
}

m["sq"] = {
	canonicalName = "Albanian",
	scripts = {"Latn", "Elba"},
	family = "sqj",
	sort_key = {
		from = { '[âãä]', '[ÂÃÄ]', '[êẽë]', '[ÊẼË]', 'ĩ', 'Ĩ', 'õ', 'Õ', 'ũ', 'Ũ', 'ỹ', 'Ỹ', 'ç', 'Ç' },
		to   = {     'a',     'A',     'e',     'E', 'i', 'I', 'o', 'O', 'u', 'U', 'y', 'Y', 'c', 'C' } } ,
}

m["ss"] = {
	canonicalName = "Swazi",
	otherNames = {"Swati"},
	scripts = {"Latn"},
	family = "bnt-ngu",
	entry_name = {
		from = {"[āàáâǎ]", "[ēèéêě]", "[īìíîǐ]", "[ōòóôǒ]", "[ūùúûǔ]", "ḿ", "[ǹńň]", MACRON, ACUTE, GRAVE, CIRC, CARON},
		to   = {"a"      , "e"      , "i"      , "o"      , "u"      , "m", "n"    }},
}

m["st"] = {
	canonicalName = "Sotho",
	otherNames = {"Sesotho", "Southern Sesotho", "Southern Sotho"},
	scripts = {"Latn"},
	family = "bnt",
}

m["su"] = {
	canonicalName = "Sundanese",
	scripts = {"Latn", "Sund"},
	family = "poz-msa",
	translit_module = "su-translit",
}

m["sv"] = {
	canonicalName = "Swedish",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"gmq-osw"},
}

m["sw"] = {
	canonicalName = "Swahili",
	otherNames = {"Settler Swahili", "KiSetla", "KiSettla", "Setla", "Settla", "Kitchen Swahili", "Kihindi", "Indian Swahili", "KiShamba", "Kishamba", "Field Swahili", "Kibabu", "Asian Swahili", "Kimanga", "Arab Swahili", "Kitvita", "Army Swahili"},
	scripts = {"Latn", "Arab"},
	family = "bnt",
	sort_key = {
		from = {"ng'", "^-"},
		to   = {"ngz"}} ,
}

m["ta"] = {
	canonicalName = "Tamil",
	scripts = {"Taml"},
	family = "dra",
	ancestors = {"oty"},
	translit_module = "ta-translit",
	override_translit = true,
}

m["te"] = {
	canonicalName = "Telugu",
	scripts = {"Telu"},
	family = "dra",
	translit_module = "te-translit",
	override_translit = true,
}

m["tg"] = {
	canonicalName = "Tajik",
	otherNames = {"Tadjik", "Tadzhik", "Tajiki", "Tajik Persian"},
	scripts = {"Cyrl", "fa-Arab", "Latn"},
	family = "ira-wes",
	ancestors = {"fa"},
	translit_module = "tg-translit",
	override_translit = true,
	sort_key = {
		from = {"Ё", "ё"},
		to   = {"Е" , "е"}} ,
	entry_name = {
		from = {ACUTE},
		to   = {}} ,
}

m["th"] = {
	canonicalName = "Thai",
	scripts = {"Thai", "Brai"},
	family = "tai-swe",
	translit_module = "th-translit",
	sort_key = {
		from = {"%p", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "%2%1"}},
}

m["ti"] = {
	canonicalName = "Tigrinya",
	scripts = {"Ethi"},
	family = "sem-eth",
	translit_module = "Ethi-translit",
}

m["tk"] = {
	canonicalName = "Turkmen",
	scripts = {"Latn", "Cyrl"},
	family = "trk-ogz",
}

m["tl"] = {
	canonicalName = "Tagalog",
	scripts = {"Latn", "Tglg"},
	family = "phi",
}

m["tn"] = {
	canonicalName = "Tswana",
	otherNames = {"Setswana"},
	scripts = {"Latn"},
	family = "bnt",
}

m["to"] = {
	canonicalName = "Tongan",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["tr"] = {
	canonicalName = "Turkish",
	scripts = {"Latn"},
	family = "trk-ogz",
	ancestors = {"ota"},
}

m["ts"] = {
	canonicalName = "Tsonga",
	scripts = {"Latn"},
	family = "bnt",
}

m["tt"] = {
	canonicalName = "Tatar",
	scripts = {"Cyrl", "Latn", "Arab", "tt-Arab"},
	family = "trk-kip",
	translit_module = "tt-translit",
	override_translit = true,
}

m["ty"] = {
	canonicalName = "Tahitian",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["ug"] = {
	canonicalName = "Uyghur",
	otherNames = {"Uigur", "Uighur", "Uygur"},
	scripts = {"ug-Arab", "Latn", "Cyrl"},
	family = "trk",
	ancestors = {"chg"},
	translit_module = "ug-translit",
	override_translit = true,
}

m["uk"] = {
	canonicalName = "Ukrainian",
	scripts = {"Cyrl"},
	family = "zle",
	translit_module = "uk-translit",
	entry_name = {
		from = {"Ѐ", "ѐ", "Ѝ", "ѝ", GRAVE, ACUTE},
		to   = {"Е", "е", "И", "и"}},
} 
m["ur"] = {
	canonicalName = "Urdu",
	scripts = {"ur-Arab"},
	family = "inc",
	ancestors = {"psu"},
	entry_name = {
		from = {u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652)},
		to   = {}} ,
}

m["uz"] = {
	canonicalName = "Uzbek",
	otherNames = {"Northern Uzbek", "Southern Uzbek"},
	scripts = {"Latn", "Cyrl", "fa-Arab"},
	family = "trk",
	ancestors = {"chg"},
}

m["ve"] = {
	canonicalName = "Venda",
	scripts = {"Latn"},
	family = "bnt",
}

m["vi"] = {
	canonicalName = "Vietnamese",
	otherNames = {"Annamese", "Annamite"},
	scripts = {"Latn", "Hani"},
	family = "mkh-vie",
	ancestors = {"mkh-mvi"},
}

m["vo"] = {
	canonicalName = "Volapük",
	scripts = {"Latn"},
	family = "art",
}

m["wa"] = {
	canonicalName = "Walloon",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"fro"},
	sort_key = {
		from = {"[áàâäå]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	  , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["wo"] = {
	canonicalName = "Wolof",
	otherNames = {"Gambian Wolof"}, -- the subsumed dialect 'wof'
	scripts = {"Latn", "Arab"},
	family = "alv-sng",
}

m["xh"] = {
	canonicalName = "Xhosa",
	scripts = {"Latn"},
	family = "bnt-ngu",
	entry_name = {
		from = {"[āàáâǎ]", "[ēèéêě]", "[īìíîǐ]", "[ōòóôǒ]", "[ūùúûǔ]", "ḿ", "[ǹńň]", MACRON, ACUTE, GRAVE, CIRC, CARON},
		to   = {"a"      , "e"      , "i"      , "o"      , "u"      , "m", "n"    }},
}

m["yi"] = {
	canonicalName = "Yiddish",
	scripts = {"Hebr"},
	family = "gmw",
	ancestors = {"gmh"},
	translit_module = "yi-translit",
}

m["yo"] = {
	canonicalName = "Yoruba",
	scripts = {"Latn"},
	family = "alv-von",
}

m["za"] = {
	canonicalName = "Zhuang",
	scripts = {"Latn", "Hani"},
	family = "tai",
}

m["zh"] = {
	canonicalName = "Chinese",
	scripts = {"Hani", "Brai"},
	family = "sit",
	ancestors = {"ltc"},
}

m["zu"] = {
	canonicalName = "Zulu",
	otherNames = {"isiZulu"},
	scripts = {"Latn"},
	family = "bnt-ngu",
	entry_name = {
                from = {"[āàáâǎ]", "[ēèéêě]", "[īìíîǐ]", "[ōòóôǒ]", "[ūùúûǔ]", "ḿ", "[ǹńň]", MACRON, ACUTE, GRAVE, CIRC, CARON},
                to   = {"a"      , "e"      , "i"      , "o"      , "u"      , "m", "n"    }},
}

return m