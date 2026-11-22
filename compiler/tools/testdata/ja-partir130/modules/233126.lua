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

m["jaa"] = {
	canonicalName = "ヤママディ語",
	otherNames = {"Jamamadi", "Madi", "Jarawara", "Jarauára", "Jaruára", "Jarauara", "Jaruara"},
	scripts = {"Latn"},
	family = "auf",
}

m["jab"] = {
	canonicalName = "ヒャム語",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["jac"] = {
	canonicalName = "ハカルテク語",
	otherNames = {"ハカルテック語", "ポプティ語", "Jacalteco", "Jacaltec", "Jakalteko", "Popti'", "Popti", "Eastern Jacalteco", "Western Jacalteco"},
	scripts = {"Latn"},
	family = "myn",
}

m["jad"] = {
	canonicalName = "Jahanka",
	scripts = {"Latn"},
	family = "dmn",
}

m["jae"] = {
	canonicalName = "ヤベム語",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["jaf"] = {
	canonicalName = "ジャラ語",
	scripts = {"Latn"},
	family = "cdc",
}

m["jah"] = {
	canonicalName = "ジャ・フット語",
	family = "aav",
}

m["jaj"] = {
	canonicalName = "ザザオ語",
	scripts = {"Latn"},
	family = "poz-ocw",
}

-- "jak" IS TREATED AS "ms", SEE WT:LT

m["jal"] = {
	canonicalName = "Yalahatan",
	otherNames = {"Horuru", "Atamanu"},
	scripts = {"Latn"},
	family = "plf",
}

m["jam"] = {
	canonicalName = "ジャマイカ・クレオール語",
	otherNames = {"Jamaican", "Jamaican Patois", "Patois", "Patwa"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["jao"] = {
	canonicalName = "ヤニュワ語",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["jaq"] = {
	canonicalName = "ヤカイ語",
	scripts = {"Latn"},
	family = "ngf",
}

m["jas"] = {
	canonicalName = "ニューカレドニア・ジャワ語",
	scripts = {"Latn"},
	family = "poz-sus",
}

m["jat"] = {
	canonicalName = "ジャカティー語",
	family = "inc",
	ancestors = {"lah"},
}

m["jau"] = {
	canonicalName = "Yaur",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["jax"] = {
	canonicalName = "ジャンビ・マレー語",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["jay"] = {
	canonicalName = "Yan-nhangu",
	scripts = {"Latn"},
	family = "aus-yol",
}

m["jaz"] = {
	canonicalName = "Jawe",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["jbe"] = {
	canonicalName = "ユダヤ＝ベルベル語",
	scripts = {"Hebr"},
	family = "ber",
}

m["jbj"] = {
	canonicalName = "アランダイ語",
	scripts = {"Latn"},
	family = "ngf",
}

m["jbk"] = {
	canonicalName = "Barikewa",
	otherNames = {"Omati", "Mini"},
	scripts = {"Latn"},
	family = "ngf",
}

m["jbn"] = {
	canonicalName = "ナフサ語",
	otherNames = {"Nefusi", "Nafusa", "Nafusi"},
	family = "ber",
}

m["jbo"] = {
	canonicalName = "ロジバン",
	scripts = {"Latn"},
	family = "art",
}

m["jbr"] = {
	canonicalName = "Jofotek-Bromnya",
}

m["jbt"] = {
	canonicalName = "ハブティ語",
	otherNames = {"Djeoromitxí", "Yabutí", "Djeoromitxi", "Jabuti", "Yabuti"},
	scripts = {"Latn"},
	family = "sai-mje",
}

m["jbu"] = {
	canonicalName = "ジュクン・タクム語",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["jcs"] = {
	canonicalName = "ジャマイカ手話",
	family = "sgn",
}

m["jct"] = {
	canonicalName = "クリムチャク語",
	scripts = {"Latn", "Cyrl"},
	family = "trk",
}

m["jda"] = {
	canonicalName = "ジャド語",
}

m["jdg"] = {
	canonicalName = "Jadgali",
}

m["jdt"] = {
	canonicalName = "ユダヤ・タート語",
	otherNames = {"Juhuri", "Juvuri", "Juwuri"},
	scripts = {"Latn", "Cyrl", "Hebr"},
	family = "ira-wes",
	ancestors = {"fa"},
	translit_module = "jdt-translit",
}

m["jeb"] = {
	canonicalName = "ヘベロ語",
}

m["jee"] = {
	canonicalName = "ジェルン語",
}

m["jeg"] = {
	canonicalName = "Jeng",
	otherNames = {"Cheng"},
	scripts = {"Latn"},
	family = "aav-ban",
}

m["jeh"] = {
	canonicalName = "ジェー語",
	otherNames = {"Yaeh"},
	scripts = {"Latn"},
	family = "aav-ban",
}

m["jei"] = {
	canonicalName = "イェイ語",
}

m["jek"] = {
	canonicalName = "Jeri Kuo",
	scripts = {"Latn"},
	family = "dmn",
}

m["jel"] = {
	canonicalName = "イェルメク語",
}

m["jen"] = {
	canonicalName = "Dza",
}

m["jer"] = {
	canonicalName = "ジェレ語",
}

m["jet"] = {
	canonicalName = "マネム語",
}

m["jeu"] = {
	canonicalName = "Jonkor Bourmataguil",
}

m["jgb"] = {
	canonicalName = "ングベエ語",
}

-- "jge" IS TREATED AS "ka", SEE WT:LT

m["jgo"] = {
	canonicalName = "ンゴンバ語",
	scripts = {"Latn"},
	family = "bai",
}

m["jhi"] = {
	canonicalName = "ジャハイ語",
}

m["jhs"] = {
	canonicalName = "ジャンコット手話",
	family = "sgn",
}

m["jia"] = {
	canonicalName = "Jina",
}

m["jib"] = {
	canonicalName = "ジブ語",
}

m["jic"] = {
	canonicalName = "トル語",
	otherNames = {"Tolupan", "Torupan", "Eastern Jicaque"},
	scripts = {"Latn"},
	family = "hok",
}

m["jid"] = {
	canonicalName = "Bu",
	scripts = {"Latn"},
	family = "alv",
}

m["jie"] = {
	canonicalName = "Jilbe",
}

m["jig"] = {
	canonicalName = "ジンギリ語",
}

m["jih"] = {
	canonicalName = "Shangzhai",
}

m["jii"] = {
	canonicalName = "Jiiddu",
	family = "cus",
}

m["jil"] = {
	canonicalName = "ジリム語",
}

m["jim"] = {
	canonicalName = "ジミ語",
	otherNames = {"Jimi", "Jimi (Cameroon)"},
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["jio"] = {
	canonicalName = "チャマオ語",
}

m["jiq"] = {
	canonicalName = "Guanyinqiao",
}

m["jit"] = {
	canonicalName = "ジタ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["jiu"] = {
	canonicalName = "ヤウレ・ジーヌオ語",
	family = "tbq-lol",
}

m["jiv"] = {
	canonicalName = "シュアル語",
	scripts = {"Latn"},
	family = "sai-jiv",
}

m["jiy"] = {
	canonicalName = "Buyuan Jinuo",
	family = "tbq-lol",
}

m["jje"] = {
	canonicalName = "済州語",
	otherNames = {"Cheju", "Jejueo"},
	scripts = {"Kore"},
	family = "qfa-kor",
	translit_module = "jje-translit",
}

m["jka"] = {
	canonicalName = "Kaera",
}

m["jko"] = {
	canonicalName = "クボ語",
}

m["jkr"] = {
	canonicalName = "コロ語 (インド)",
	otherNames = {"Koro"},
}

m["jku"] = {
	canonicalName = "Labir",
}

m["jle"] = {
	canonicalName = "Ngile",
}

m["jls"] = {
	canonicalName = "ジャマイカ手話",
	family = "sgn",
}

m["jma"] = {
	canonicalName = "Dima",
}

m["jmb"] = {
	canonicalName = "Zumbun",
}

m["jmc"] = {
	canonicalName = "マチャメ語",
}

m["jmd"] = {
	canonicalName = "ヤムデナ語",
	scripts = {"Latn"},
	family = "plf",
}

m["jmi"] = {
	canonicalName = "ジミ語",
	otherNames = {"Jimi (Nigeria)"},
	scripts = {"Latn"},
	family = "cdc-wst",
}

m["jml"] = {
	canonicalName = "ジュムリー語",
}

m["jmn"] = {
	canonicalName = "Makuri Naga",
}

m["jmr"] = {
	canonicalName = "カマラ語",
}

-- "jms" IS TREATED AS "mff", SEE WT:LT

m["jmw"] = {
	canonicalName = "Mouwase",
	otherNames = {"Omati", "Mini"},
	scripts = {"Latn"},
	family = "ngf",
}

m["jmx"] = {
	canonicalName = "西部フストラワカ・ミステク語",
	scripts = {"Latn"},
	family = "omq-mix",
}

m["jna"] = {
	canonicalName = "Jangshung",
}

m["jnd"] = {
	canonicalName = "Jandavra",
}

m["jng"] = {
	canonicalName = "ヤンマン語",
}

m["jni"] = {
	canonicalName = "ジャンジ語",
}

m["jnj"] = {
	canonicalName = "イエムサ語",
	otherNames = {"Yem", "Yemma", "Janjero", "Janjerinya", "Janjor", "Yangaro", "Zinjero"},
	family = "omv",
}

m["jnl"] = {
	canonicalName = "Rawat",
}

m["jns"] = {
	canonicalName = "ジャウンサーリー語",
}

m["job"] = {
	canonicalName = "Joba",
}

m["jod"] = {
	canonicalName = "Wojenaka",
}

m["jor"] = {
	canonicalName = "ホラ語",
	otherNames = {"Hora"},
	scripts = {"Latn"},
	family = "tup-gua",
}

m["jos"] = {
	canonicalName = "ヨルダン手話",
	scripts = {"Sgnw"},
	family = "sgn",
}

m["jow"] = {
	canonicalName = "Jowulu",
	scripts = {"Latn"},
	family = "dmn",
}

-- "jpa" IS NOT USED, SEE WT:LT

m["jpr"] = {
	canonicalName = "ユダヤ＝ペルシア語",
	otherNames = {"Jidi", "Dzhidi", "Djudi"},
	scripts = {"Hebr"},
	family = "ira-wes",
	ancestors = {"fa"},
}

m["jqr"] = {
	canonicalName = "ハカル語",
	scripts = {"Latn"},
	family = "sai-aym",
}

m["jra"] = {
	canonicalName = "ジャライ語",
	scripts = {"Latn"},
	family = "cmc",
}

m["jrb"] = {
	canonicalName = "ユダヤ＝アラビア語",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["jrr"] = {
	canonicalName = "ジル語",
}

m["jrt"] = {
	canonicalName = "ジョルト語",
}

m["jru"] = {
	canonicalName = "ハプレリア語",
	scripts = {"Latn"},
	family = "sai-car",
}

m["jsl"] = {
	canonicalName = "日本手話",
	family = "sgn-jsl",
}

m["jua"] = {
	canonicalName = "ジュマ語",
	scripts = {"Latn"},
	family = "tup-gua",
}

m["jub"] = {
	canonicalName = "Wannu",
}

m["juc"] = {
	canonicalName = "女真語",
	scripts = {"Jurc"},
	family = "tuw",
}

m["jud"] = {
	canonicalName = "Worodougou",
}

m["juh"] = {
	canonicalName = "Hone",
	otherNames = {"Hõne", "Pindiga", "Gwana"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["juk"] = {
	canonicalName = "ワパン語",
}

m["jul"] = {
	canonicalName = "ジレル語",
}

m["jum"] = {
	canonicalName = "ジュムジュム語",
	family = "sdv",
}

m["jun"] = {
	canonicalName = "ジュアング語",
	scripts = {"Orya"},
	family = "mun",
}

m["juo"] = {
	canonicalName = "Jiba",
}

m["jup"] = {
	canonicalName = "フプ語",
	scripts = {"Latn"},
}

m["jur"] = {
	canonicalName = "ジュルナ語",
	otherNames = {"Iuruna", "Jaruna", "Yudya", "Yurúna"},
	scripts = {"Latn"},
	family = "tup",
}

m["jus"] = {
	canonicalName = "ジュムラ手話",
	family = "sgn",
}

m["jut"] = {
	canonicalName = "ジュート語",
	otherNames = {"Jutlandic"},
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"da"},
}

m["juu"] = {
	canonicalName = "ジュ語",
}

m["juw"] = {
	canonicalName = "Wãpha",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["juy"] = {
	canonicalName = "Juray",
	family = "mun",
}

m["jvd"] = {
	canonicalName = "ジャヴィンド語",
}

m["jvn"] = {
	canonicalName = "カリブ・ジャワ語",
	scripts = {"Latn"},
	family = "poz-sus",
}

m["jwi"] = {
	canonicalName = "Jwira-Pepesa",
	scripts = {"Latn"},
	family = "alv-kwa",
}

-- "jya" IS TREATED AS "sit-sit", "sit-jap", "sit-tsh", "sit-zbu", SEE WT:LT

m["jye"] = {
	canonicalName = "ユダヤ＝イエメン・アラビア語",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["jyy"] = {
	canonicalName = "Jaya",
	scripts = {"Latn"},
	family = "csu",
}

return m