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

m["gaa"] = {
	canonicalName = "ガ語",
	otherNames = "Gã",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["gab"] = {
	canonicalName = "ガブリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gad"] = {
	canonicalName = "ガッダン語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["gae"] = {
	canonicalName = "グアレケナ語",
	otherNames = {"Guarequena"},
	type = "regular",
	scripts = {"Latn"},
	family = "awd",
}

m["gaf"] = {
	canonicalName = "ゲンデ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gag"] = {
	canonicalName = "ガガウズ語",
	type = "regular",
	scripts = {"Latn", "Cyrl"},
	family = "trk",
}

m["gah"] = {
	canonicalName = "アレカノ語",
	otherNames = {"Gahuku"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["gai"] = {
	canonicalName = "Borei",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gaj"] = {
	canonicalName = "ガドスプ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gak"] = {
	canonicalName = "ガムコノラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gal"] = {
	canonicalName = "Galoli",
	otherNames = {"Galolen", "Talur"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gam"] = {
	canonicalName = "Kandawo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gan"] = {
	canonicalName = "贛語",
	type = "regular",
	scripts = {"Hani"},
	family = "zhx",
}

m["gao"] = {
	canonicalName = "ガンツ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gap"] = {
	canonicalName = "ガル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gaq"] = {
	canonicalName = "ガタ語'",
	type = "regular",
	scripts = {"None"},
	family = "mun",
}

m["gar"] = {
	canonicalName = "Galeya",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["gas"] = {
	canonicalName = "アディワシー・ガラシア語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gat"] = {
	canonicalName = "ケナティ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gau"] = {
	canonicalName = "Mudhili Gadaba",
	type = "regular",
	scripts = {"None"},
	family = "dra",
}

m["gaw"] = {
	canonicalName = "Nobonob",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gay"] = {
	canonicalName = "ガヨ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-nws",
}

m["gba"] = {
	canonicalName = "グバヤ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbb"] = {
	canonicalName = "Kaytetye",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-rnd",
}

m["gbd"] = {
	canonicalName = "カラジェリ語",
	otherNames = {"Garadjari", "Karajarri"},
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["gbe"] = {
	canonicalName = "Niksek",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gbf"] = {
	canonicalName = "Gaikundi",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gbg"] = {
	canonicalName = "グバンズィリ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-ubg",
}

m["gbh"] = {
	canonicalName = "Defi Gbe",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbi"] = {
	canonicalName = "ガレラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbj"] = {
	canonicalName = "ボド・ガダバ語",
	type = "regular",
	scripts = {"None"},
	family = "mun",
}

m["gbk"] = {
	canonicalName = "ガディ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbl"] = {
	canonicalName = "ガミット語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbm"] = {
	canonicalName = "ガルワーリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbn"] = {
	canonicalName = "Mo'da",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbo"] = {
	canonicalName = "北部グレボ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbp"] = {
	canonicalName = "グバヤ＝ボサンゴア語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbq"] = {
	canonicalName = "グバヤ＝ボズム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbr"] = {
	canonicalName = "グバギ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbs"] = {
	canonicalName = "Gbesi Gbe",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbu"] = {
	canonicalName = "Gagadu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbv"] = {
	canonicalName = "グバヌ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbw"] = {
	canonicalName = "ガビガビ語",
	otherNames = {"Gabi-Gabi", "Gabi Gabi", "Gubbi-Gubbi", "Gubbi Gubbi"}, -- contrast xby
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["gbx"] = {
	canonicalName = "東部フラ・グベ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gby"] = {
	canonicalName = "Gbari",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gbz"] = {
	canonicalName = "ダリー語（ゾロアスター教）",
	type = "regular",
	scripts = {"None"},
	family = "ira",
}

m["gcc"] = {
	canonicalName = "Mali",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gcd"] = {
	canonicalName = "Ganggalida",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gce"] = {
	canonicalName = "ガリチ語",
	type = "regular",
	scripts = {"None"},
	family = "ath-pco",
}

m["gcf"] = {
	canonicalName = "グアドループ・クレオール語",
	otherNames = {"Antillean Creole French", "Guadeloupean Creole", "Guadeloupean Creole French", "Saint Lucian Creole", "Saint Lucian Creole French"},
	type = "regular",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"fr"},
}

m["gcf-mtq"] = {
	canonicalName = "マルティニーク・クレオール語",
	type = "regular",
	scripts = {"Latn"},
	family = "crp",
}

m["gcl"] = {
	canonicalName = "グレナダ英語クリオール",
	type = "regular",
	scripts = {"None"},
	family = "crp",
}

m["gcn"] = {
	canonicalName = "ガイナ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gcr"] = {
	canonicalName = "ギアナ・クレオール語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gct"] = {
	canonicalName = "コロニアトバル・ドイツ語",
	type = "regular",
	scripts = {"Latn"},
	family = "gmw",
}

m["gda"] = {
	canonicalName = "ガデ・ロハール語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdb"] = {
	canonicalName = "Pottangi Ollar Gadaba",
	type = "regular",
	scripts = {"None"},
	family = "dra",
}

m["gdc"] = {
	canonicalName = "ググ・バドゥン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdd"] = {
	canonicalName = "ゲダゲド語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["gde"] = {
	canonicalName = "グデ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdf"] = {
	canonicalName = "グドゥフ＝ガヴァ語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-cbm",
}

m["gdg"] = {
	canonicalName = "ガアッタン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdh"] = {
	canonicalName = "ガジェラワング語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdi"] = {
	canonicalName = "グンディ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-ubg",
}

m["gdj"] = {
	canonicalName = "Kurtjar",
	otherNames = {"Gurdjar"},
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["gdk"] = {
	canonicalName = "ガダン語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-est",
}

m["gdl"] = {
	canonicalName = "ディラシャ語",
	type = "regular",
	scripts = {"None"},
	family = "cus",
}

m["gdm"] = {
	canonicalName = "ラアル語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["gdn"] = {
	canonicalName = "Umanakaina",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdo"] = {
	canonicalName = "ゴドベリ語",
	otherNames = {"Ghodoberi"},
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-nec",
}

m["gdq"] = {
	canonicalName = "メフリ語",
	otherNames = {"Mahri"},
	type = "regular",
	scripts = {"Arab"},
	family = "sem-sar",
}

m["gdr"] = {
	canonicalName = "Wipi",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gds"] = {
	canonicalName = "ガンドルック手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["gdt"] = {
	canonicalName = "Kungardutyi",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdu"] = {
	canonicalName = "グドゥ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gdx"] = {
	canonicalName = "ゴドワリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gea"] = {
	canonicalName = "ゲルマ語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-wst",
}

m["geb"] = {
	canonicalName = "キレ語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gec"] = {
	canonicalName = "Gboloo Grebo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ged"] = {
	canonicalName = "ガデ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["geg"] = {
	canonicalName = "ゲングレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["geh"] = {
	canonicalName = "フッター派ドイツ語",
	otherNames = {"Hutterite German"},
	type = "regular",
	scripts = {"Latn"},
	family = "gmw",
}

m["gei"] = {
	canonicalName = "ゲベ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-hce",
}

m["gej"] = {
	canonicalName = "ゲン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gek"] = {
	canonicalName = "イウォム語",
	type = "regular",
	scripts = {"Latn"},
	family = "cdc",
}

m["gel"] = {
	canonicalName = "Fakkanci",
	type = "regular",
	scripts = {"None"},
	family = "nic-knj",
}

m["geq"] = {
	canonicalName = "Geme",
	type = "regular",
	scripts = {"None"},
	family = "znd",
}

m["ges"] = {
	canonicalName = "Geser-Gorom",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["gev"] = {
	canonicalName = "ヴィヤ語",
	otherNames = {"Eviya", "Geviya", "Ivéa", "Viya"},
	type = "regular",
	scripts = {"None"},
	family = "bnt",
}

m["gew"] = {
	canonicalName = "ゲラ語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-wst",
}

m["gex"] = {
	canonicalName = "ガッレ語",
	type = "regular",
	scripts = {"None"},
	family = "cus",
}

m["gey"] = {
	canonicalName = "Enya",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gez"] = {
	canonicalName = "ゲエズ語",
	otherNames = {"Ethiopic", "Gi'iz"},
	type = "regular",
	scripts = {"Ethi"},
	family = "sem-eth",
	translit_module = "Ethi-translit",
}

m["gfk"] = {
	canonicalName = "パトパタル語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["gft"] = {
	canonicalName = "ガファット語",
	type = "regular",
	scripts = {"None"},
	family = "sem-eth",
}

m["gga"] = {
	canonicalName = "ガオ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["ggb"] = {
	canonicalName = "グビイ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ggd"] = {
	canonicalName = "グガジ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gge"] = {
	canonicalName = "Guragone",
	type = "regular",
	scripts = {"None"},
	family = "aus-arn",
}

m["ggg"] = {
	canonicalName = "グルグラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ggk"] = {
	canonicalName = "クンカラカン語",
	type = "regular",
	scripts = {"None"},
	family = "aus-arn",
}

m["ggl"] = {
	canonicalName = "ガンラウ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ggn"] = {
	canonicalName = "東部グルン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ggo"] = {
	canonicalName = "南部ゴーンディー語",
	type = "regular",
	scripts = {"None"},
	family = "dra",
}

m["ggt"] = {
	canonicalName = "ギトゥア語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["ggu"] = {
	canonicalName = "Gban",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ggw"] = {
	canonicalName = "ゴゴダラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gha"] = {
	canonicalName = "ガダメス語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghe"] = {
	canonicalName = "南部ガレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghh"] = {
	canonicalName = "北部ガレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghk"] = {
	canonicalName = "ゲコ・カレン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghl"] = {
	canonicalName = "グルファン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghn"] = {
	canonicalName = "ガノンガ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["gho"] = {
	canonicalName = "ゴマラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghr"] = {
	canonicalName = "ゲラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ghs"] = {
	canonicalName = "グフ＝サマネ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ght"] = {
	canonicalName = "クタン・ガレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gia"] = {
	canonicalName = "キチャ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gib"] = {
	canonicalName = "Gibanawa",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gic"] = {
	canonicalName = "Gail",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gid"] = {
	canonicalName = "ギダル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gig"] = {
	canonicalName = "ゴアリア語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gih"] = {
	canonicalName = "Githabul",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gil"] = {
	canonicalName = "キリバス語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-mic",
}

m["gim"] = {
	canonicalName = "ギミ語",
	otherNames = {"Gimi"},
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gin"] = {
	canonicalName = "ヒヌフ語",
	type = "regular",
	scripts = {"None"},
	family = "cau-nec",
}

m["gio"] = {
	canonicalName = "コーラオ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["gip"] = {
	canonicalName = "ギミ語",
	otherNames = {"Gimi"},
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["giq"] = {
	canonicalName = "緑コーラオ語",
	otherNames = {"Hagei", "Hakhi"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["gir"] = {
	canonicalName = "赤コーラオ語",
	otherNames = {"Vandu"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["gis"] = {
	canonicalName = "北ギジガ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["git"] = {
	canonicalName = "ギツカン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["giu"] = {
	canonicalName = "Mulao", -- a variety of Gelao
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["giw"] = {
	canonicalName = "白コーラオ語",
	otherNames = {"Telue", "Doulou", "Tolo"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["gix"] = {
	canonicalName = "ギリマ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-ubg",
}

m["giy"] = {
	canonicalName = "ギユグ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["giz"] = {
	canonicalName = "南ギジガ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gji"] = {
	canonicalName = "ゲジ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gjk"] = {
	canonicalName = "カチ・コーリー語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gjm"] = {
	canonicalName = "グンジュマラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gjn"] = {
	canonicalName = "ゴンジャ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gju"] = {
	canonicalName = "グジャール語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gka"] = {
	canonicalName = "Guya",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["gke"] = {
	canonicalName = "Ndai",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gkm"] = {
	canonicalName = "中世ギリシア語",
	otherNames = {"Medieval Greek"},
	type = "regular",
	scripts = {"polytonic"},
	family = "grk",
}

m["gkn"] = {
	canonicalName = "ゴカナ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["gko"] = {
	canonicalName = "Kok-Nar",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["gkp"] = {
	canonicalName = "ギニア・クペレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["glc"] = {
	canonicalName = "ボン・グラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gld"] = {
	canonicalName = "ナナイ語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "tuw",
}

m["glh"] = {
	canonicalName = "北西パシャイ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gli"] = {
	canonicalName = "Guliguli",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["glj"] = {
	canonicalName = "グラ・イロ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["glk"] = {
	canonicalName = "ギラキ語",
	type = "regular",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["glo"] = {
	canonicalName = "ガランブ語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-wst",
}

m["glr"] = {
	canonicalName = "グラロ＝トゥワボ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["glu"] = {
	canonicalName = "グラ語",
	otherNames = {"Sara Gula"},
	type = "regular",
	scripts = {"None"},
	family = "csu",
}

m["glw"] = {
	canonicalName = "グラブダ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gly"] = {
	canonicalName = "グレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gma"] = {
	canonicalName = "Gambera",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmb"] = {
	canonicalName = "Gula'alaa",
	type = "regular",
	scripts = {"None"},
	family = "poz-sls",
}

m["gmd"] = {
	canonicalName = "Mághdì",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmg"] = {
	canonicalName = "Magɨyi",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["gmh"] = {
	canonicalName = "中高ドイツ語",
	type = "regular",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"goh"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊË]", "[ēêë]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"	, "e"	, "I"   , "i"   , "O"   , "o"   , "U"   , "u"   }} ,
}

m["gml"] = {
	canonicalName = "中世低地ドイツ語",
	type = "regular",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"osx"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["gmm"] = {
	canonicalName = "Gbaya-Mbodomo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmn"] = {
	canonicalName = "Gimnime",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmu"] = {
	canonicalName = "Gumalu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmv"] = {
	canonicalName = "Gamo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmx"] = {
	canonicalName = "Magoma",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gmy"] = {
	canonicalName = "ミケーネ・ギリシャ語",
	type = "regular",
	scripts = {"Linb"},
	family = "grk",
	translit_module = "Linb-translit",
}

m["gna"] = {
	canonicalName = "Kaansa",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnb"] = {
	canonicalName = "Gangte",
	type = "regular",
	scripts = {"None"},
	family = "tbq-kuk",
}

m["gnc"] = {
	canonicalName = "Guanche",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnd"] = {
	canonicalName = "ズルゴ＝ゲムゼク語",
	otherNames = {"Zulgo", "Gemzek", "Mineo"},
	type = "regular",
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["gne"] = {
	canonicalName = "Ganang",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gng"] = {
	canonicalName = "Ngangam",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnh"] = {
	canonicalName = "Lere",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gni"] = {
	canonicalName = "グニヤンディ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-bub",
}

m["gnk"] = {
	canonicalName = "ǁGana",
	otherNames = {"Gana"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnl"] = {
	canonicalName = "Gangulu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnm"] = {
	canonicalName = "Ginuman",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnn"] = {
	canonicalName = "Gumatj",
	type = "regular",
	scripts = {"None"},
	family = "aus-yol",
}

m["gno"] = {
	canonicalName = "北部ゴーンディー語",
	type = "regular",
	scripts = {"None"},
	family = "dra",
}

m["gnq"] = {
	canonicalName = "Gana",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnr"] = {
	canonicalName = "Gureng Gureng",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnt"] = {
	canonicalName = "Guntai",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnu"] = {
	canonicalName = "Gnau",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["gnw"] = {
	canonicalName = "西部ボリビア・グアラニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gnz"] = {
	canonicalName = "Ganzi",
	type = "regular",
	scripts = {"None"},
	family = "nic-ubg",
}

m["goa"] = {
	canonicalName = "グロ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gob"] = {
	canonicalName = "プラジェロ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["goc"] = {
	canonicalName = "Gorakor",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["god"] = {
	canonicalName = "ゴディエ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["goe"] = {
	canonicalName = "Gongduk",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gof"] = {
	canonicalName = "ゴファ語",
	type = "regular",
	scripts = {"Latn", "Ethi"},
	family = "omv",
}

m["gog"] = {
	canonicalName = "ゴゴ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["goh"] = {
	canonicalName = "古高ドイツ語",
	type = "regular",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gem-pro"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊË]", "[ēêë]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"	, "e"	, "I"   , "i"   , "O"   , "o"   , "U"   , "u"   }} ,
}

m["goi"] = {
	canonicalName = "Gobasi",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["goj"] = {
	canonicalName = "ゴウラン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gok"] = {
	canonicalName = "ゴウリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gol"] = {
	canonicalName = "ゴラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gon"] = {
	canonicalName = "ゴーンディー語",
	type = "regular",
	scripts = {"Telu"},
	family = "dra",
}

m["goo"] = {
	canonicalName = "Gone Dau",
	type = "regular",
	scripts = {"None"},
	family = "poz-occ",
}

m["gop"] = {
	canonicalName = "Yeretuar",
	type = "regular",
	scripts = {"None"},
	family = "poz-hce",
}

m["goq"] = {
	canonicalName = "Gorap",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gor"] = {
	canonicalName = "ゴロンタロ語",
	type = "regular",
	scripts = {"Latn"},
	family = "phi",
}

m["got"] = {
	canonicalName = "ゴート語",
	type = "regular",
	scripts = {"Goth"},
	family = "gme",
	ancestors = {"gem-pro"},
	translit_module = "Goth-translit",
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["gou"] = {
	canonicalName = "ガヴァル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gow"] = {
	canonicalName = "ゴロワ語",
	type = "regular",
	scripts = {"None"},
	family = "cus",
}

m["gox"] = {
	canonicalName = "Gobu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["goy"] = {
	canonicalName = "グンド語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["goz"] = {
	canonicalName = "ゴザルハーン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gpa"] = {
	canonicalName = "Gupa-Abawa",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gpn"] = {
	canonicalName = "Taiap",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gqa"] = {
	canonicalName = "ガアンダ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gqi"] = {
	canonicalName = "グエチョン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gqn"] = { -- a variety of 'ter'
	canonicalName = "ワナ語",
	otherNames = {"Guana", "Guaná", "Guana (Brazil)", "Arawakan Guana"},
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["gqr"] = {
	canonicalName = "Gor",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gqu"] = {
	canonicalName = "Qau",
	otherNames = {"Gao", "Aqao", "Qau Gelao"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["gra"] = {
	canonicalName = "ラージプート・ガラシア語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grb"] = {
	canonicalName = "Grebo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grc"] = {
	canonicalName = "古典ギリシア語",
	type = "regular",
	scripts = {"polytonic", "Cprt"},
	family = "grk",
	ancestors = {"grk-pro"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, cpg, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇᾱ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗῑ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧῡ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}},
	entry_name = {
		from = {"[ᾸᾹ]", "[ᾰᾱ]", "[ῘῙ]", "[ῐῑ]", "[ῨῩ]", "[ῠῡ]"},
		to   = {"Α", "α", "Ι", "ι", "Υ", "υ"}} ,
}

m["grd"] = {
	canonicalName = "Guruntum",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grg"] = {
	canonicalName = "マディ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["grh"] = {
	canonicalName = "Gbiri-Niragu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gri"] = {
	canonicalName = "ガリ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-sls",
}

m["grj"] = {
	canonicalName = "南部グレボ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grm"] = {
	canonicalName = "Kota Marudu Talantang",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gro"] = {
	canonicalName = "Groma",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grq"] = {
	canonicalName = "ゴロヴ語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["grr"] = {
	canonicalName = "タズナティト語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grs"] = {
	canonicalName = "グレシ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grt"] = {
	canonicalName = "ガロ語",
	type = "regular",
	scripts = {"Beng"},
	family = "tbq",
}

m["gru"] = {
	canonicalName = "ソッド語",
	otherNames = {"Kistane", "Soddo"},
	type = "regular",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["grv"] = {
	canonicalName = "中部グレボ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grw"] = {
	canonicalName = "Gweda",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["grx"] = {
	canonicalName = "グリアソ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gry"] = {
	canonicalName = "Barclayville Grebo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["grz"] = {
	canonicalName = "Guramalum",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["gse"] = {
	canonicalName = "ガーナ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["gsg"] = {
	canonicalName = "ドイツ手話",
	otherNames = {"Deutsche Gebärdensprache"},
	type = "regular",
	scripts = {"Sgnw"},
	family = "sgn-gsl",
}

m["gsl"] = {
	canonicalName = "Gusilay",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gsm"] = {
	canonicalName = "グアテマラ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["gsn"] = {
	canonicalName = "Gusan",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["gso"] = {
	canonicalName = "Southwest Gbaya",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gsp"] = {
	canonicalName = "Wasembo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gss"] = {
	canonicalName = "ギリシア手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["gsw"] = {
	canonicalName = "アレマン語",
	otherNames = {"Swiss German", "Walser German", "Walserdeutsch", "Walser", "Wallisertiitsch"},
	type = "regular",
	scripts = {"Latn"},
	family = "gmw",
	wikimedia_codes = {"als"},
}

m["gta"] = {
	canonicalName = "Guató",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["gti"] = {
	canonicalName = "Gbati-ri",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gtu"] = {
	canonicalName = "アグ・タルンガル語",
	otherNames = {"Aghu Tharnggala", "Aghu Tharnggalu"},
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["gua"] = {
	canonicalName = "Shiki",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gub"] = {
	canonicalName = "グアハハラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["guc"] = {
	canonicalName = "ワユ語",
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["gud"] = {
	canonicalName = "ヨコブエ・ディダ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gue"] = {
	canonicalName = "グリンジ語",
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["guf"] = {
	canonicalName = "Gupapuyngu",
	type = "regular",
	scripts = {"None"},
	family = "aus-yol",
}

m["gug"] = {
	canonicalName = "パラグアイ・グアラニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["guh"] = {
	canonicalName = "グアイーボ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gui"] = {
	canonicalName = "東部ボリビア・グアラニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["guk"] = {
	canonicalName = "グムズ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gul"] = {
	canonicalName = "ガラ語",
	otherNames = {"Geechee", "Sea Island Creole English"},
	type = "regular",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["gum"] = {
	canonicalName = "グアンビアノ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gun"] = {
	canonicalName = "ンブヤ・グアラニ語",
	type = "regular",
	scripts = {"Latn"},
	family = "tup",
}

m["guo"] = {
	canonicalName = "ゴアヤベーロ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gup"] = {
	canonicalName = "グンウィング語",
	type = "regular",
	scripts = {"None"},
	family = "aus-gun",
}

m["guq"] = {
	canonicalName = "Aché",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gur"] = {
	canonicalName = "ファリファリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gus"] = {
	canonicalName = "ギニア手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["gut"] = {
	canonicalName = "マレク・ハイカ語",
	type = "regular",
	scripts = {"Latn"},
	family = "cba",
}

m["guu"] = {
	canonicalName = "ヤノマモ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["guv"] = {
	canonicalName = "Gey",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["guw"] = {
	canonicalName = "グン語",
	otherNames = {"Gun-Gbe", "Gungbe"},
	type = "regular",
	scripts = {"Latn"},
	family = "alv",
}

m["gux"] = {
	canonicalName = "ゴウルマンチェマ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["guz"] = {
	canonicalName = "グシイ語",
	type = "regular",
	scripts = {"Latn"},
	family = "bnt",
}

m["gva"] = {
	canonicalName = "グアナ語",
	otherNames = {"Guana", "Guaná", "Guana (Paraguay)", "Mascoian Guana"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-mas",
}

m["gvc"] = {
	canonicalName = "グヮナノ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tuc",
}

m["gve"] = {
	canonicalName = "Duwet",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["gvf"] = {
	canonicalName = "Golin",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["gvj"] = {
	canonicalName = "グアハ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvl"] = {
	canonicalName = "Gulay",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvm"] = {
	canonicalName = "グルマナ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvn"] = {
	canonicalName = "クク・ヤランジ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvo"] = {
	canonicalName = "Gavião do Jiparaná",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvp"] = {
	canonicalName = "パラ・ガヴィアン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvr"] = {
	canonicalName = "グルン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gvs"] = {
	canonicalName = "Gumawana",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["gvy"] = {
	canonicalName = "グヤニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwa"] = {
	canonicalName = "ンバト語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwb"] = {
	canonicalName = "グワ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwc"] = {
	canonicalName = "カラーム語",
	type = "regular",
	scripts = {"Arab"},
	family = "iir-dar",
}

m["gwd"] = {
	canonicalName = "ガワダ語",
	type = "regular",
	scripts = {"None"},
	family = "cus",
}

m["gwe"] = {
	canonicalName = "グウェノ語",
	type = "regular",
	scripts = {"Latn"},
	family = "bnt",
}

m["gwf"] = {
	canonicalName = "ゴウロ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwg"] = {
	canonicalName = "Moo",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwi"] = {
	canonicalName = "グウィッチン語",
	otherNames = {"Gwich’in", "Kutchin", "Takudh", "Tukudh", "Loucheux"},
	type = "regular",
	scripts = {"Latn"},
	family = "ath",
}

m["gwj"] = {
	canonicalName = "グイ語",
	otherNames = {"Gǀwi", "Gǀui"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwn"] = {
	canonicalName = "グワンダラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwr"] = {
	canonicalName = "グウェレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwt"] = {
	canonicalName = "ガワル・バティ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwu"] = {
	canonicalName = "グワム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gww"] = {
	canonicalName = "Kwini",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gwx"] = {
	canonicalName = "Gua",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gxx"] = {
	canonicalName = "ウェ南部語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gya"] = {
	canonicalName = "北西グバヤ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyb"] = {
	canonicalName = "ガルス語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyd"] = {
	canonicalName = "カヤルディルド語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gye"] = {
	canonicalName = "ギエム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyf"] = {
	canonicalName = "グンガブラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyg"] = {
	canonicalName = "Gbayi",
	type = "regular",
	scripts = {"None"},
	family = "nic-ubg",
}

m["gyi"] = {
	canonicalName = "バジェリ語",
	otherNames = {"バギエリ語", "Bagiele", "Bagyele", "Bajeli", "Gyele"},
	type = "regular",
	scripts = {"None"},
	family = "bnt",
}

m["gyl"] = {
	canonicalName = "ガイル語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gym"] = {
	canonicalName = "ンガベレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyn"] = {
	canonicalName = "ガイアナ・クリオール語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyr"] = {
	canonicalName = "グアラユ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gyy"] = {
	canonicalName = "グニャ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["gza"] = {
	canonicalName = "ガンザ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["gzi"] = {
	canonicalName = "ガズィ語",
	type = "regular",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["gzn"] = {
	canonicalName = "ガネ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-hce",
}

return m