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

m["ebg"] = {
	"Ebughu",
	"Q35294",
	"nic-lcr",
	scripts = Latn,
}

m["ebk"] = {
	"東部ボントク語",
	nil,
	"phi",
	aliases = {"Eastern Bontok"},
	scripts = Latn,
}

m["ebr"] = {
	"エブリエ語",
	"Q36644",
	"alv-ptn",
	scripts = Latn,
}

m["ebu"] = {
	"エンブ語",
	"Q35318",
	"bnt-kka",
	scripts = Latn,
}

m["ecr"] = {
	"Eteocretan",
	"Q35461",
	scripts = {"Grek"},
}

m["ecs"] = {
	"Ecuadorian Sign Language",
	"Q3436769",
	"sgn",
	scripts = Latn, -- when documented
}

m["ecy"] = {
	"Eteocypriot",
	"Q35309",
	scripts = {"Cprt"},
}

m["eee"] = {
	"E",
	"Q35386",
	"qfa-mix",
	aliases = {"Kjang E"},
	scripts = {"Hani", "Latn"},
}

m["efa"] = {
	"Efai",
	"Q3813297",
	"nic-ief",
	scripts = Latn,
}

m["efe"] = {
	"Efe",
	"Q56354",
	"csu-mle",
	scripts = Latn,
}

m["efi"] = {
	"エフィク語",
	otherNames = {"エフィック語", "Efik"},
	"Q35377",
	"nic-ief",
	scripts = Latn,
}

m["ega"] = {
	"エガ語",
	"Q3914927",
	"alv",
	scripts = Latn,
}

m["egl"] = {
	"エミリア語",
	"Q1057898",
	"roa-git",
	aliases = {"Emiliano"},
	scripts = Latn,
	wikimedia_codes = {"eml"},
}

m["ego"] = {
	"Eggon",
	"Q35300",
	"nic-pls",
	scripts = Latn,
}

m["egy"] = {
	"古代エジプト語",
	"Q50868",
	"egx",
	aliases = {"Ancient Egyptian"},
	scripts = {"Latinx", "Egyp", "Egyd"},
}

m["ehu"] = {
	"Ehueun",
	"Q3441392",
	"alv-nwd",
	scripts = Latn,
}

m["eip"] = {
	"Eipomek",
	"Q5349839",
	"ngf",
	scripts = Latn,
}

m["eit"] = {
	"Eitiep",
	"Q5350030",
	"qfa-tor",
	scripts = Latn,
}

m["eiv"] = {
	"Askopan",
	"Q56324",
	"paa-nbo",
	aliases = {"Eivo"},
	scripts = Latn,
}

m["eja"] = {
	"Ejamat",
	"Q6269820",
	"alv-jfe",
	scripts = Latn,
}

m["eka"] = {
	"エカジュク語",
	"Q35250",
	"nic-eko",
	scripts = Latn,
}

m["eke"] = {
	"Ekit",
	"Q3509628",
	"nic-ief",
	scripts = Latn,
}

m["ekg"] = {
	"エカリ語",
	"Q5350305",
	"ngf",
	scripts = Latn,
}

m["eki"] = {
	"エキ語",
	"Q5350418",
	"nic-ief",
	scripts = Latn,
}

m["ekl"] = {
	"コール語",
	"Q6426945",
	"mun",
	-- FIXME, this should probably be called "Kol (Bangladesh)" as the
	-- canonical name, Kolhe is hardly used.
	aliases = {"Kol", "Kol (Bangladesh)"},
	scripts = Latn,
}

m["ekm"] = {
	"Elip",
	"Q12952414",
	"nic-ymb",
	scripts = Latn,
}

m["eko"] = {
	"Koti",
	"Q29930",
	"bnt-mak",
	scripts = Latn,
}

m["ekp"] = {
	"エクペイェ語",
	"Q35254",
	"alv-igb",
	scripts = Latn,
}

m["ekr"] = {
	"Yace",
	"Q36901",
	"alv-ido",
	scripts = Latn,
}

m["eky"] = {
	"東部カヤ語",
	"Q25559417",
	"kar",
	scripts = {"Kali"},
}

m["ele"] = {
	"エレピ語",
	"Q5359444",
	"qfa-tor",
	scripts = Latn,
}

m["elh"] = {
	"エル・フゲイラト語",
	"Q5351410",
	"nub-hil",
	scripts = Latn,
}

m["eli"] = {
	"Nding",
	"Q36176",
	"alv-tal",
	scripts = Latn,
}

m["elk"] = {
	"エルケイ語",
	"Q5364210",
	"qfa-tor",
	scripts = Latn,
}

m["elm"] = {
	"エレメ語",
	"Q3914427",
	"nic-ogo",
	scripts = Latn,
}

m["elo"] = {
	"エル・モロ語",
	"Q56719",
	"cus",
	scripts = Latn,
}

m["elu"] = {
	"Elu",
	"Q3364594",
	"poz-aay",
	scripts = Latn,
}

m["elx"] = {
	"エラム語",
	"Q35470",
	"qfa-iso",
	scripts = {"Xsux"},
}

m["ema"] = {
	"エマイ＝イウレハ＝オラ語",
	"Q35428",
	"alv-eeo",
	-- FIXME, Emai is properly one of the dialects of Aoma
	otherNames = {"Aoma", "Ora", "Emai-Iuleha-Ora"},
	scripts = Latn,
}

m["emb"] = {
	"ウンバロー語",
	"Q5369424",
	"poz",
	otherNames = {"Palin", "Pari", "Sangau", "Sanggau"},
	aliases = {"Maloh", "Malo", "Matoh", "Mbaloh", "Memaloh"},
	varieties = {"Kalis"},
	scripts = Latn,
}

m["eme"] = {
	"エメリヨン語",
	"Q3588942",
	"tup-gua",
	otherNames = {"Emerilon", "Emerion", "Mereo", "Melejo", "Mereyo", "Teco"},
	scripts = Latn,
}

m["emg"] = {
	"東部メオハン語",
	"Q12952840",
	"sit-kie",
	scripts = {"Deva"},
}

m["emi"] = {
	"ムッサウ語",
	"Q6943093",
	"poz-ocw",
	scripts = Latn,
}

m["emk"] = {
	"東部マニンカ語",
	"Q11002130",
	"dmn-mnk",
	scripts = {"Latn", "Arab", "Nkoo"},
}

m["emm"] = {
	"マムリケ語",
	"Q3285082",
	"nai-pak",
	scripts = Latn,
}

m["emn"] = {
	"Eman",
	"Q5368975",
	"nic-tvc",
	scripts = Latn,
}

m["emp"] = {
	"北部エンベラ語",
	"Q2391297",
	"sai-chc",
	scripts = Latn,
}

m["ems"] = {
	"アルティイク語",
	"Q27992",
	"ypk",
	otherNames = {"Alutiiq"},
	scripts = Latn,
}

m["emu"] = {
	"東部ムリア語",
	"Q12952883",
	"dra",
	ancestors = {"gon"},
}

m["emw"] = {
	"エンプラワス語",
	"Q5374265",
	"poz-tim",
	scripts = Latn,
}

m["emx"] = {
	"エロミンチェラ語",
	"Q1122188",
	"qfa-mix",
	ancestors = {"eu", "rom"},
	scripts = Latn,
}

m["emy"] = {
	"碑文マヤ語",
	"Q301355",
	"myn",
	otherNames = {"Classic Ch'olti'an", "Ch'olti'"},
	scripts = {"Maya"},
}

m["ena"] = {
	"Apali",
	"Q3504201",
	"ngf-mad",
	scripts = Latn,
}

m["enb"] = {
	"マラクェット語",
	"Q56874",
	"sdv-nma",
	scripts = Latn,
}

m["enc"] = {
	"儂環語",
	"Q3504110",
	"qfa-buy",
	scripts = Latn,
}

m["end"] = {
	"エンデ語",
	"Q2067656",
	"poz-cet",
	scripts = Latn,
}

m["enf"] = {
	"森林エネツ語",
	"Q30249597",
	"syd",
	scripts = Latn,
}

m["enh"] = {
	"ツンドラ・エネツ語",
	"Q25559411",
	"syd",
	scripts = Latn,
}

m["enl"] = {
	"Enlhet",
	"Q15462671",
	"sai-mas",
	otherNames = {"Lengua"},
	scripts = Latn,
}

m["enm"] = {
	"中英語",
	"Q36395",
	"gmw",
	aliases = {"Medieval English", "Mediaeval English"},
	scripts = Latn,
	ancestors = {"ang"},
	entry_name = {
		from = {"[ĀÁ]", "[āá]", "[ǢǼ]", "[ǣǽ]", "Ċ", "ċ", "[ĒÉĖ]", "[ēéė]", "Ġ", "ġ", "[ĪÍ]", "[īí]", "[ŌÓ]", "[ōó]", "[ŪÚ]", "[ūú]", "[ȲÝ]", "[ȳý]", MACRON, ACUTE, DOTABOVE},
		to   = {"A", "a", "Æ", "æ", "C", "c", "E", "e", "G", "g", "I", "i", "O", "o", "U", "u", "Y", "y"}},
}

m["enn"] = {
	"Engenni",
	"Q3915365",
	"alv-dlt",
	scripts = Latn,
}

m["eno"] = {
	"エンガノ語",
	otherNames = "Enggano",
	"Q2669164",
	"poz",
	scripts = Latn,
}

m["enq"] = {
	"エンガ語",
	"Q1143040",
	"paa-eng",
	scripts = Latn,
}

m["enr"] = {
	"エムム語",
	"Q5370369",
	"paa-pau",
}

m["enu"] = {
	"Enu",
	"Q5380858",
	"tbq-lol",
}

m["env"] = {
	"Enwan",
	"Q3438334",
	"alv-yek",
	scripts = Latn,
}

m["enw"] = {
	"Enwang",
	"Q11134434",
	"nic-lcr",
	aliases = {"Enwan"},
	scripts = Latn,
}

m["enx"] = {
	"Enxet",
	"Q15462609",
	"sai-mas",
	otherNames = {"Lengua"},
	scripts = Latn,
}

m["eot"] = {
	"Eotile",
	"Q3915347",
	"alv-ptn",
	otherNames = {"Beti"},
	scripts = Latn,
}

m["epi"] = {
	"Epie",
	"Q35291",
	"alv-dlt",
	scripts = Latn,
}

m["era"] = {
	"エラヴァラン語",
	"Q5385061",
	"dra",
}

m["erg"] = {
	"シエ語",
	"Q426254",
	"poz-occ",
	scripts = Latn,
}

m["erh"] = {
	"エルワ語",
	"Q3441244",
	"alv-swd",
	scripts = Latn,
}

m["eri"] = {
	"Ogea",
	"Q7079984",
	"ngf-mad",
	otherNames = {"Erima"},
	scripts = Latn,
}

m["erk"] = {
	"南部エファテ語",
	"Q3449070",
	"poz-vnc",
	otherNames = {"Efate", "Vate", "Vaté"},
	scripts = Latn,
}

m["ero"] = {
	"Horpa",
	"Q56854",
	"sit-rgy",
	otherNames = {"Ergong", "Danba", "Stau", "rTau", "Rtau", "Daofuhua", "Bawang", "Bopa", "Dawu", "Geshitsa", "Geshiza", "Geshizahua", "Hor", "Huo'er", "Hórsók", "Nyagrong-Minyag", "Pawang", "Rgu", "Western rGyalrong", "Western Gyarong", "Western Jiarong", "Xinlong-Muya"},
}

m["err"] = {
	"エレエ語",
	"Q10488401",
	"qfa-iso",
	scripts = Latn,
}

m["ers"] = {
	"アルス語",
	"Q12952417",
	"sit-qia",
	otherNames = {"Duoxu", "Erhsu"},
	scripts = Latn, -- also Ersu Shaba
}

m["ert"] = {
	"エリタイ語",
	"Q56376",
	"paa-lkp",
	scripts = Latn,
}

m["erw"] = {
	"エロクヮナス語",
	"Q5395296",
	"poz-hce",
	scripts = Latn,
}

m["ese"] = {
	"エセエハ語",
	"Q2980381",
	"sai-tac",
	otherNames = {"Tiatinagua"},
	scripts = Latn,
}

m["esh"] = {
	"エシュテハールド語",
	"Q12952418",
	"xme-ttc",
	scripts = {"fa-Arab", "Latn"},
	ancestors = {"xme-ttc-sou"},
}

m["esi"] = {
	"北アラスカ・イヌピアツン語",
	nil,
	"esx-inu",
	scripts = Latn,
}

m["esk"] = {
	"北西アラスカ・イヌピアツン語",
	"Q25559714",
	"esx-inu",
	scripts = Latn,
}

m["esl"] = {
	"エジプト手話",
	"Q5348443",
	"sgn",
}

m["esm"] = {
	"Esuma",
	"Q16927555",
	"alv-kwa",
	scripts = Latn,
}

m["esn"] = {
	"サルバドル手話",
	"Q7406492",
	"sgn",
	scripts = Latn, -- when documented
}

m["eso"] = {
	"エクスプレソ",
	"Q3196221",
	"sgn",
	scripts = Latn, -- when documented
}

m["esq"] = {
	"エセレン語",
	"Q1294243",
	"qfa-iso",
	scripts = Latn,
}

m["ess"] = {
	"中央シベリア・ユピック語",
	"Q27993",
	"ypk",
	otherNames = {"Central Siberian Yup'ik", "St. Lawrence Yupik", "St. Lawrence Yup'ik", "St. Lawrence Eskimo", "Siberian Yupik", "Siberian Yup'ik", "Siberian Yupik Eskimo", "Siberian Yup'ik Eskimo", "St. Lawrence Island Eskimo", "St. Lawrence Island Yupik", "St. Lawrence Island Yup'ik"},
	scripts = {"Cyrl"},
}

m["esu"] = {
	"ユピック語",
	"Q21117",
	"ypk",
	scripts = Latn,
}

m["esy"] = {
	"Eskayan",
	"Q867086",
	"art",
	scripts = Latn, -- also its own native script
}

m["etb"] = {
	"Etebi",
	"Q11002851",
	"nic-ief",
	scripts = Latn,
}

m["etc"] = {
	"エシュマン語",
	"Q5402493",
	"alg-eas",
	scripts = Latn,
}

m["eth"] = {
	"エチオピア手話",
	"Q3501903",
	"sgn",
}

m["etn"] = {
	"エトン語（バヌアツ）",
	"Q3059362",
	"poz-oce",
	aliases = {"Eton"},
	scripts = Latn,
}

m["eto"] = {
	"エトン語（カメルーン）",
	"Q35317",
	"bnt-btb",
	aliases = {"Eton"},
	scripts = Latn,
}

m["etr"] = {
	"Edolo",
	"Q5340184",
	"ngf",
	scripts = Latn,
}

m["ets"] = {
	"イェケエ語",
	"Q3915848",
	"alv-yek",
	otherNames = {"Afenmai", "Afemai", "Etsako"},
	scripts = Latn,
}

m["ett"] = {
	"エトルリア語",
	"Q35726",
	"qfa-tyn",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["etu"] = {
	"エジャガム語",
	otherNames = {"エコイ語", "Ejagham", "Ekoi"},
	"Q35296",
	"nic-eko",
	scripts = Latn,
}

m["etx"] = {
	"Eten",
	"Q3915392",
	"nic-beo",
	scripts = Latn,
}

m["etz"] = {
	"セミミ語",
	"Q10950308",
	"paa-mai",
	scripts = Latn,
}

m["eve"] = {
	"エヴェン語",
	"Q29960",
	"tuw",
	scripts = {"Cyrl", "Latn"},
	entry_name = {
	from = {"[Ӣ]", "[ӣ]", "[Ӯ]", "[ӯ]", MACRON, DOTBELOW, DOTABOVE},
	to   = { "И",   "и",   "У",   "у" }},
	translit_module = "eve-translit",
}

m["evh"] = {
	"Uvbie",
	"Q3441344",
	"alv-swd",
	scripts = Latn,
}

m["evn"] = {
	"エヴェンキ語",
	"Q30004",
	"tuw",
	scripts = {"Cyrl"},
	entry_name = {
		from = {"[Ӣ]", "[ӣ]", "[Ӯ]", "[ӯ]", MACRON, DOTBELOW, DOTABOVE},
		to   = { "И",   "и",   "У",   "у" }},
	translit_module = "evn-translit",
}

m["ewo"] = {
	"エウォンド語",
	"Q35459",
	"bnt-btb",
	otherNames = {"Ewondo", "Jaunde", "Kolo", "Yaounde", "Yaunde"},
	scripts = Latn,
}

m["ext"] = {
	"エストレマドゥーラ語",
	"Q30007",
	"roa-ibe",
	scripts = Latn,
}

m["eya"] = {
	"Eyak",
	"Q27480",
	"xnd",
	scripts = Latn,
}

m["eyo"] = {
	"Keiyo",
	"Q56856",
	"sdv-nma",
	scripts = Latn,
}

m["eza"] = {
	"Ezaa",
	"Q11921436",
	"alv-igb",
	ancestors = {"izi"},
	aliases = {"Ezza", "Eza"},
	scripts = Latn,
}

m["eze"] = {
	"Uzekwe",
	"Q3502244",
	"nic-ucn",
	scripts = Latn,
}

return m