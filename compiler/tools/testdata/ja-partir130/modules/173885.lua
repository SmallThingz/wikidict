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

m["uam"] = {
	canonicalName = "Uamué",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uan"] = {
	canonicalName = "Kuan",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uar"] = {
	canonicalName = "タイルマ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uba"] = {
	canonicalName = "ウバン語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ubi"] = {
	canonicalName = "ウビ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ubl"] = {
	canonicalName = "Buhi'non Bikol",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ubr"] = {
	canonicalName = "ウビル語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["ubu"] = {
	canonicalName = "ウンブ・ウング語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uby"] = {
	canonicalName = "ウビフ語",
	type = "regular",
	scripts = {"Latn", "Cyrl"},
	family = "cau-nwc",
}

m["uda"] = {
	canonicalName = "Uda",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ude"] = {
	canonicalName = "ウデヘ語",
	otherNames = {"Udege", "Udekhe", "Udeghe"},
	type = "regular",
	scripts = {"Cyrl"},
	family = "tuw",
}

m["udg"] = {
	canonicalName = "Muduga",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["udi"] = {
	canonicalName = "ウディ語",
	type = "regular",
	scripts = {"Cyrl", "Latn", "Armn", "Geor"},
	family = "cau-nec",
	ancestors = {"xag"},
	translit_module = "udi-translit"
}

m["udj"] = {
	canonicalName = "ウジル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["udl"] = {
	canonicalName = "ウズラム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["udm"] = {
	canonicalName = "ウドムルト語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "fiu-prm",
	translit_module = "udm-translit",
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["udu"] = {
	canonicalName = "ウドゥック語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ues"] = {
	canonicalName = "Kioko",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ufi"] = {
	canonicalName = "ウフィム語",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["uga"] = {
	canonicalName = "ウガリット語",
	type = "regular",
	scripts = {"Ugar"},
	family = "sem-nwe",
	translit_module = "uga-translit"
}

m["ugb"] = {
	canonicalName = "クク＝ウグバン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uge"] = {
	canonicalName = "ウゲレ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["ugn"] = {
	canonicalName = "ウガンダ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["ugo"] = {
	canonicalName = "ウゴング語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ugy"] = {
	canonicalName = "ウルグアイ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["uha"] = {
	canonicalName = "ウハミ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["uhn"] = {
	canonicalName = "ダマル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uis"] = {
	canonicalName = "Uisai",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uiv"] = {
	canonicalName = "Iyive",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["uji"] = {
	canonicalName = "Tanjijili",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uka"] = {
	canonicalName = "Kaburi",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ukg"] = {
	canonicalName = "ウクリグマ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ukh"] = {
	canonicalName = "Ukhwejo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ukl"] = {
	canonicalName = "ウクライナ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["ukp"] = {
	canonicalName = "ウクペ・バヨビリ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ukq"] = {
	canonicalName = "ウクワ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uks"] = {
	canonicalName = "ウルブ・カァポル手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["uku"] = {
	canonicalName = "ウクウェ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ukw"] = {
	canonicalName = "Ukwuani-Aboh-Ndoni",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["uky"] = {
	canonicalName = "Kuuk Yak",
	type = "regular",
	scripts = {"None"},
	family = "aus-psw",
}

m["ula"] = {
	canonicalName = "Fungwa",
	otherNames = {"Ula", "Ura"},
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ulb"] = {
	canonicalName = "ウルクミ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ulc"] = {
	canonicalName = "ウリチ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ule"] = {
	canonicalName = "Lule",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["ulf"] = {
	canonicalName = "ウスク語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uli"] = {
	canonicalName = "ウリシアン語",
	type = "regular",
	scripts = {"None"},
	family = "poz-mic",
}

m["ulk"] = {
	canonicalName = "メリアム語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["ull"] = {
	canonicalName = "Ullatan",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ulm"] = {
	canonicalName = "Ulumanda'",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uln"] = {
	canonicalName = "ラバウル・クレオール・ドイツ語",
	otherNames = {"Rabaul Creole German"},
	type = "regular",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"de"},
}

m["ulu"] = {
	canonicalName = "Uma' Lung",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ulw"] = {
	canonicalName = "ウルワ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uma"] = {
	canonicalName = "ユーマティラ語",
	type = "regular",
	scripts = {"None"},
	family = "nai-shp",
}

m["umb"] = {
	canonicalName = "ムブンドゥ語",
	otherNames = {"South Mbundu"},
	type = "regular",
	scripts = {"Latn"},
	family = "bnt",
}

m["umc"] = {
	canonicalName = "マルルキニア語",
	type = "regular",
	scripts = {"Latn"},
	family = "itc",
}

m["umd"] = {
	canonicalName = "ウンビンダム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["umg"] = {
	canonicalName = "ウンブイガム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["umi"] = {
	canonicalName = "Ukit",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["umm"] = {
	canonicalName = "ウモン語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["umn"] = {
	canonicalName = "Makyan Naga",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["umo"] = {
	canonicalName = "ウモティナ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ump"] = {
	canonicalName = "ウンピラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["umr"] = {
	canonicalName = "ウンブガラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ums"] = {
	canonicalName = "Pendau",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["umu"] = {
	canonicalName = "マンシー語",
	type = "regular",
	scripts = {"Latn"},
	family = "del",
}

m["una"] = {
	canonicalName = "北ワトゥット語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["und"] = {
	canonicalName = "Undetermined",
	type = "regular",
	scripts = {"Zyyy"},
	family = "qfa-not",
}

m["une"] = {
	canonicalName = "ウネメ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ung"] = {
	canonicalName = "ンガリニン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["unk"] = {
	canonicalName = "エナウェネ＝ナウェ語",
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["unm"] = {
	canonicalName = "ウナミ語",
	type = "regular",
	scripts = {"Latn"},
	family = "del",
	entry_name = {
		from = {"À", "Ä", "È", "Ë", "Ì", "Ò", "Ù", "à", "ä", "è", "ë", "ì", "ò", "ù"},
		to   = {"A", "A", "E", "E", "I", "O", "U", "a", "a", "e", "e", "i", "o", "u"}} ,
}

m["unn"] = {
	canonicalName = "Kurnai",
	otherNames = {"Gunai", "Gaanay", "Ganai", "Gunnai'", "Kurnay"},
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["unr"] = {
	canonicalName = "ムンダーリー語",
	type = "regular",
	scripts = {"None"},
	family = "mun",
}

m["unu"] = {
	canonicalName = "Unubahe",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["unx"] = {
	canonicalName = "ムンダー語",
	type = "regular",
	scripts = {"None"},
	family = "mun",
}

m["unz"] = {
	canonicalName = "Unde Kaili",
	otherNames = {"Banava", "Ndepuu", "West Kaili", "Lole", "Ganti"},
	type = "regular",
	scripts = {"Latn"},
	family = "poz-kal",
}

m["uok"] = {
	canonicalName = "Uokha",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["upi"] = {
	canonicalName = "ウメダ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["upv"] = {
	canonicalName = "ウリピヴ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-vnc",
}

m["ura"] = {
	canonicalName = "ウラリナ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urb"] = {
	canonicalName = "ウルブ・カァポル語",
	type = "regular",
	scripts = {"Latn"},
	family = "tup",
}

m["urc"] = {
	canonicalName = "ウニンガング語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ure"] = {
	canonicalName = "ウル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urf"] = {
	canonicalName = "ウラディ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["urg"] = {
	canonicalName = "ウリギナ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["urh"] = {
	canonicalName = "ウルホボ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["uri"] = {
	canonicalName = "ウリム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["urk"] = {
	canonicalName = "ウラク・ラウォイッ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["url"] = {
	canonicalName = "Urali",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urm"] = {
	canonicalName = "Urapmin",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urn"] = {
	canonicalName = "ウルアンニリン語",
	type = "regular",
	scripts = {"Latn"},
	family = "plf",
}

m["uro"] = {
	canonicalName = "ウラ語（パプアニューギニア）",
	otherNames = {"Ura (Papua New Guinea)"},
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["urp"] = {
	canonicalName = "Uru-Pa-In",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urr"] = {
	canonicalName = "レハルルプ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urt"] = {
	canonicalName = "ウラト語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["uru"] = {
	canonicalName = "Urumi",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urv"] = {
	canonicalName = "ウルアヴァ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["urw"] = {
	canonicalName = "ソプ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urx"] = {
	canonicalName = "ウリモ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["ury"] = {
	canonicalName = "Orya",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["urz"] = {
	canonicalName = "ウルエウ･ワウワウ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["usa"] = {
	canonicalName = "ウサルファ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ush"] = {
	canonicalName = "ウショジョ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["usi"] = {
	canonicalName = "ウスイ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["usk"] = {
	canonicalName = "Usaghade",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["usp"] = {
	canonicalName = "ウスパンテク語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["usu"] = {
	canonicalName = "ウヤ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uta"] = {
	canonicalName = "オタンク語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["ute"] = {
	canonicalName = "ユート＝南部パイウート語",
	otherNames = {"Southern Paiute", "Colorado River Numic", "Chemehuevi"},
	type = "regular",
	scripts = {"Latn"},
	family = "azc-num",
}

m["utp"] = {
	canonicalName = "Aba",
	otherNames = {"Amba", "Nebao", "Nembao"},
	type = "regular",
	scripts = {"Latn"},
	family = "poz-oce",
}

m["utr"] = {
	canonicalName = "エトゥロ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv",
}

m["utu"] = {
	canonicalName = "ウトゥ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uum"] = {
	canonicalName = "ウルム語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "trk",
}

m["uun"] = {
	canonicalName = "パゼッヘ語",
	otherNames = {"Pazeh", "Pazih", "Kulun", "Kulon"},
	type = "regular",
	scripts = {"Latn"},
	family = "map",
}

m["uur"] = {
	canonicalName = "ウラ語（バヌアツ）",
	type = "regular",
	scripts = {"None"},
	family = "poz-oce",
}

m["uuu"] = {
	canonicalName = "U",
	type = "regular",
	scripts = {"None"},
	family = "aav",
}

m["uve"] = {
	canonicalName = "West Uvean",
	type = "regular",
	scripts = {"None"},
	family = "poz-pol",
}

m["uvh"] = {
	canonicalName = "Uri",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["uvl"] = {
	canonicalName = "ロテ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["uwa"] = {
	canonicalName = "クク＝ウワン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["uya"] = {
	canonicalName = "ドコ＝ウヤンガ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

return m