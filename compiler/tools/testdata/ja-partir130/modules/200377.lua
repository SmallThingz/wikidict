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

m["naa"] = {
	canonicalName = "Namla",
	family = "paa",
}

m["nab"] = {
	canonicalName = "南部ナンビクワラ語",
	otherNames = {"Nambiquara", "Nambicuara", "Nambikuara", "Southern Nambikuára"},
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["nac"] = {
	canonicalName = "Narak",
	family = "ngf",
}

m["nae"] = {
	canonicalName = "ナカエラ語",
	family = "poz",
}

m["naf"] = {
	canonicalName = "ナバク語",
	family = "ngf",
}

m["nag"] = {
	canonicalName = "ナガ・ピジン語",
	otherNames = {"Nagamese"},
	scripts = {"Latn"},
	family = "crp",
}

m["nah"] = {
	canonicalName = "ナワトル語",
	scripts = {"Latn"},
	family = "azc-nah",
}

m["naj"] = {
	canonicalName = "ナル語",
	family = "alv-sng",
}

m["nak"] = {
	canonicalName = "ナカナイ語",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["nal"] = {
	canonicalName = "ナリク語",
	family = "poz-ocw",
}

m["nam"] = {
	canonicalName = "ガンギテメリ語",
	otherNames = {"Ngan'gi", "Nangikurrunggurr"},
	scripts = {"Latn"},
}

m["nan"] = {
	canonicalName = "閩南語",
	otherNames = {"Hokkien", "Taiwanese", "Amoy", "Xiamenese"},
	scripts = {"Hani", "Latn"},
	family = "zhx",
	wikimedia_codes = {"zh-min-nan"},
	ancestors = {"zhx-min-pro"},
}

m["nao"] = {
	canonicalName = "Naaba",
	otherNames = {"Naapa", "Nawa Sherpa"},
	family = "tbq",
	ancestors = {"xct"},
}

m["nap"] = {
	canonicalName = "ナポリ語",
	scripts = {"Latn"},
	family = "roa",
}

m["naq"] = {
	canonicalName = "コエコエ語",
	otherNames = {"Khoekhoe"},
	scripts = {"Latn"},
	family = "khi",
}

m["nar"] = {
	canonicalName = "Iguta",
	family = "nic-bco",
}

m["nas"] = {
	canonicalName = "ナーシオイ語",
	otherNames = {"Naasioi"},
	scripts = {"Latn"},
	family = "paa",
}

m["nat"] = {
	canonicalName = "Hungworo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["naw"] = {
	canonicalName = "ナウリ語",
	family = "alv-kwa",
}

m["nax"] = {
	canonicalName = "ナクウィ語",
}

m["nay"] = {
	canonicalName = "ンガリニェリ語",
	otherNames = {"Yaraldi"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["naz"] = {
	canonicalName = "コアテペック・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nba"] = {
	canonicalName = "Nyemba",
	family = "nic-bco",
}

m["nbb"] = {
	canonicalName = "ンドエ語",
	family = "nic-bod",
}

m["nbc"] = {
	canonicalName = "チャン・ナガ語",
	family = "tbq",
}

m["nbd"] = {
	canonicalName = "ングビンダ語",
	family = "bnt",
}

m["nbe"] = {
	canonicalName = "コニャク・ナガ語",
}

m["nbg"] = {
	canonicalName = "Nagarchal",
	family = "dra",
	ancestors = {"gon"},
}

m["nbh"] = {
	canonicalName = "ンガモ語",
	family = "cdc",
}

m["nbi"] = {
	canonicalName = "マオ・ナガ語",
}

m["nbj"] = {
	canonicalName = "ンガリンマン語",
}

m["nbk"] = {
	canonicalName = "ナケ語",
}

m["nbm"] = {
	canonicalName = "ングバカ・マボ語",
	family = "nic-ubg",
}

m["nbn"] = {
	canonicalName = "クリ語",
	otherNames = {"Nabi"},
	family = "poz",
}

m["nbo"] = {
	canonicalName = "ンクコリ語",
	family = "nic-bco",
}

m["nbp"] = {
	canonicalName = "ンナム語",
	family = "nic-bod",
}

m["nbq"] = {
	canonicalName = "Nggem",
}

m["nbr"] = {
	canonicalName = "ヌマナ＝ヌンク＝グバントゥ＝ヌンブ語",
}

m["nbs"] = {
	canonicalName = "ナミビア手話",
	family = "sgn",
}

m["nbt"] = {
	canonicalName = "バンガニ語",
}

m["nbu"] = {
	canonicalName = "ロンメイト・ナガ語",
}

m["nbv"] = {
	canonicalName = "ンガマンボ語",
	family = "nic-bod",
}

m["nbw"] = {
	canonicalName = "南部ングバンディ語",
	family = "nic-ubg",
}

m["nby"] = {
	canonicalName = "ニンゲラ語",
}

m["nca"] = {
	canonicalName = "Iyo",
	family = "ngf-fin",
}

m["ncb"] = {
	canonicalName = "中部ニコバル語",
}

m["ncc"] = {
	canonicalName = "ポナム語",
	family = "poz-aay",
}

m["ncd"] = {
	canonicalName = "ナチェリン語",
}

m["nce"] = {
	canonicalName = "ナガトマン語",
	otherNames = {"Yale", "Nagatman"},
}

m["ncf"] = {
	canonicalName = "Notsi",
	family = "poz-ocw",
}

m["ncg"] = {
	canonicalName = "ニスカ語",
}

m["nch"] = {
	canonicalName = "中央ワステカナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nci"] = {
	canonicalName = "古典ナワトル語",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}
	},
}

m["ncj"] = {
	canonicalName = "北部プエブラ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nck"] = {
	canonicalName = "ナカラ語",
	family = "aus-arn",
}

m["ncl"] = {
	canonicalName = "ミチョアカン・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["ncm"] = {
	canonicalName = "Nambo",
}

m["ncn"] = {
	canonicalName = "ナウナ語",
	family = "poz-aay",
}

m["nco"] = {
	canonicalName = "シベ語",
}

m["ncp"] = {
	canonicalName = "ンダクトゥップ語",
	family = "nic-bod",
}

m["ncr"] = {
	canonicalName = "Ncane",
	family = "nic-bod",
}

m["ncs"] = {
	canonicalName = "ニカラグア手話",
	family = "sgn",
}

m["nct"] = {
	canonicalName = "チョーテ・ナガ語",
	otherNames = {"Chothe"},
	family = "tbq-kuk",
}

m["ncu"] = {
	canonicalName = "Chumburung",
}

m["ncx"] = {
	canonicalName = "中央プエブラナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["ncz"] = {
	canonicalName = "ナチェス語",
}

m["nda"] = {
	canonicalName = "ンダサ語",
	family = "bnt",
}

m["ndb"] = {
	canonicalName = "Kenswei Nsei",
	family = "alv",
}

m["ndc"] = {
	canonicalName = "ンダウ語",
}

m["ndd"] = {
	canonicalName = "ンデ＝ンセレ＝ンタ語",
	family = "nic-bod",
}

m["ndf"] = {
	canonicalName = "ナドルヴィア語",
}

m["ndg"] = {
	canonicalName = "ンデンゲレコ語",
}

m["ndh"] = {
	canonicalName = "ンダリ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["ndi"] = {
	canonicalName = "Chamba Leko",
	otherNames = {"Samba Leko", "Samba Leeko"},
	family = "alv",
}

m["ndj"] = {
	canonicalName = "ンダンバ語",
}

m["ndk"] = {
	canonicalName = "ンダカ語",
}

m["ndl"] = {
	canonicalName = "Ndolo",
}

m["ndm"] = {
	canonicalName = "ンダム語",
}

m["ndn"] = {
	canonicalName = "ングンディ語",
}

m["ndp"] = {
	canonicalName = "ンド語",
}

m["ndq"] = {
	canonicalName = "ンドンベ語",
}

m["ndr"] = {
	canonicalName = "Ndoola",
	family = "nic-bod",
}

m["nds"] = {
	canonicalName = "低地ドイツ語",
	otherNames = {"Low Saxon", "Modern Low German"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gml"},
}

m["ndt"] = {
	canonicalName = "ンドゥンガ語",
	family = "nic-ubg",
}

m["ndu"] = {
	canonicalName = "Dugun",
}

m["ndv"] = {
	canonicalName = "ンドゥト語",
	family = "alv-sng",
}

m["ndw"] = {
	canonicalName = "ンドボ語",
}

m["ndx"] = {
	canonicalName = "ンドゥガ語",
}

m["ndy"] = {
	canonicalName = "Lutos",
}

m["ndz"] = {
	canonicalName = "ンドゴ語",
}

m["nea"] = {
	canonicalName = "東部ガダ語",
}

m["neb"] = {
	canonicalName = "トゥラ語",
}

m["nec"] = {
	canonicalName = "ネデバン語",
}

m["ned"] = {
	canonicalName = "Nde-Gbite",
}

m["nee"] = {
	canonicalName = "クマック語",
	otherNames = {"Nêlêmwa-Nixumwak", "Nêlêmwa", "Nixumwak", "Nenema"},
	family = "poz-cln",
}

m["nef"] = {
	canonicalName = "Nefamese",
}

m["neg"] = {
	canonicalName = "ネギダル語",
	family = "tuw",
}

m["neh"] = {
	canonicalName = "Nyenkha",
	otherNames = {"Nyen", "Henka", "Mangsdekha", "Phobjip", "Mangdep", "Mangde", "Hen Kha", "Henkha", "Mandebi-kha", "Nehan", "Phobjikha", "Chutobikha"},
	scripts = {"Tibt", "Latn"},
	family = "sit",
}

m["nei"] = {
	canonicalName = "新ヒッタイト語",
	scripts = {"Xsux"},
	family = "ine-ana",
	ancestors = {"htx"},
}

m["nej"] = {
	canonicalName = "ネコ語",
	family = "ngf-fin",
}

m["nek"] = {
	canonicalName = "ネク語",
	family = "poz-cln",
}

m["nem"] = {
	canonicalName = "ネミ語",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["nen"] = {
	canonicalName = "ネゴネ語",
	family = "poz-occ",
}

m["neo"] = {
	canonicalName = "Ná-Meo",
	family = "hmn",
}

m["neq"] = {
	canonicalName = "北中部ミヘ語",
}

m["ner"] = {
	canonicalName = "ヤハディアン語",
}

m["nes"] = {
	canonicalName = "Bhoti Kinnauri",
}

m["net"] = {
	canonicalName = "ネテ語",
}

m["neu"] = {
	canonicalName = "ネオ語",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["nev"] = {
	canonicalName = "ニャフン語",
}

m["new"] = {
	canonicalName = "ネパール・バサ語",
	scripts = {"Deva"},
	family = "sit",
	ancestors = {"nwx"},
	translit_module = "sa-translit",
}

m["nex"] = {
	canonicalName = "Neme",
}

m["ney"] = {
	canonicalName = "ネヨ語",
}

m["nez"] = {
	canonicalName = "ネズパース語",
	otherNames = {"Nez Percé", "Numipu"},
	scripts = {"Latn"},
	family = "nai-shp",
}

m["nfa"] = {
	canonicalName = "Dhao",
}

m["nfd"] = {
	canonicalName = "Ahwai",
}

m["nfl"] = {
	canonicalName = "エイウォ語",
	otherNames = {"Äiwoo"},
	scripts = {"Latn"},
	family = "poz-oce",
}

m["nfr"] = {
	canonicalName = "Nafaanra",
	family = "alv",
}

m["nfu"] = {
	canonicalName = "ンフムテ語",
	family = "nic-bod",
}

m["nga"] = {
	canonicalName = "ングバカ語",
	family = "alv",
}

m["ngb"] = {
	canonicalName = "北部ヌバンディア語",
	family = "nic-ubg",
}

m["ngc"] = {
	canonicalName = "ンゴンベ語 (コンゴ民主共和国)",
	otherNames = {"Lingombe", "Ngombe (Democratic Republic of the Congo)", "Ngombe"},
	family = "bnt",
}

m["ngd"] = {
	canonicalName = "Bagandou",
	otherNames = {"Ngando (Central African Republic)", "Ngando", "Bangandou"},
	family = "bnt",
}

m["nge"] = {
	canonicalName = "ンゲンバ語",
	family = "nic-bod",
}

m["ngg"] = { -- compare 'aiy'
	canonicalName = "ングバカ・マンザ語",
	family = "alv",
}

m["ngh"] = {
	canonicalName = "Nǀuu",
	otherNames = {"Nǁng"},
	scripts = {"Latn"},
	family = "qfa-tuu",
}

m["ngi"] = {
	canonicalName = "ンギジム語",
}

m["ngj"] = {
	canonicalName = "ンギエ語",
	family = "nic-bod",
}

m["ngk"] = {
	canonicalName = "Ngalkbun",
	family = "aus-gun",
}

m["ngl"] = {
	canonicalName = "ロムウェ語",
}

m["ngm"] = {
	canonicalName = "ヌゲティク島クレオール語",
	otherNames = {"Ngatikese", "Ngatikese Pidgin", "Ngatikese Creole"},
	family = "crp",
}

m["ngn"] = {
	canonicalName = "ングウォ語",
	family = "nic-bod",
}

m["ngo"] = {
	canonicalName = "ンゴニ語",
	family = "bnt",
}

m["ngp"] = {
	canonicalName = "ングル語 (タンザニア)",
	family = "bnt",
}

m["ngq"] = {
	canonicalName = "ングリミ語",
}

m["ngr"] = {
	canonicalName = "Nagu",
	family = "poz-oce",
}

m["ngs"] = {
	canonicalName = "グヴォコ語",
	family = "cdc",
}

m["ngt"] = {
	canonicalName = "ゲ語",
	family = "mkh",
}

m["ngu"] = {
	canonicalName = "ゲレロ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["ngv"] = {
	canonicalName = "ナグミ語",
}

m["ngw"] = {
	canonicalName = "ングワバ語",
}

m["ngx"] = {
	canonicalName = "ングワヒ語",
}

m["ngy"] = {
	canonicalName = "Tibea",
}

m["ngz"] = {
	canonicalName = "ングングウェル語",
}

m["nha"] = {
	canonicalName = "Nhanda",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["nhb"] = {
	canonicalName = "Beng",
}

m["nhc"] = {
	canonicalName = "タバスコ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhd"] = {
	canonicalName = "Chiripá",
}

m["nhe"] = {
	canonicalName = "東部ワステカナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhf"] = {
	canonicalName = "Nhuwala",
	family = "aus-nga",
}

m["nhg"] = {
	canonicalName = "テテルシンゴ・ナワトル語",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhh"] = {
	canonicalName = "Nahari",
	family = "inc",
	ancestors = {"pka"},
}

m["nhi"] = {
	canonicalName = "サカトラン＝アワカトラン＝テペツィントラ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhk"] = {
	canonicalName = "地峡コソレアカケ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhm"] = {
	canonicalName = "モレロス・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhn"] = {
	canonicalName = "中央ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nho"] = {
	canonicalName = "タクウ語",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["nhp"] = {
	canonicalName = "地峡パハパン・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhq"] = {
	canonicalName = "ウアスカレカ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhr"] = {
	canonicalName = "Naro",
}

m["nht"] = {
	canonicalName = "オメテペック・ナワトル語",
}

m["nhu"] = {
	canonicalName = "ヌーン語",
	family = "nic-bod",
}

m["nhv"] = {
	canonicalName = "テマスカルテペック・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhw"] = {
	canonicalName = "西部ワステカナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhx"] = {
	canonicalName = "地峡メカヤパン・ナワトル語",
	scripts = {"Latn"},
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhy"] = {
	canonicalName = "北部オアハカ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nhz"] = {
	canonicalName = "サンタ・マリア・ラ・アルタ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nia"] = {
	canonicalName = "ニアス語",
	scripts = {"Latn"},
	family = "poz-nws",
}

m["nib"] = {
	canonicalName = "Nakame",
	family = "ngf-fin",
}

m["nid"] = {
	canonicalName = "ンガンディ語",
	family = "aus-arn",
}

m["nie"] = {
	canonicalName = "ニエリム語",
}

m["nif"] = {
	canonicalName = "ネク語",
	family = "ngf-fin",
}

m["nig"] = {
	canonicalName = "ンガラカン語",
	family = "aus-gun",
}

m["nih"] = {
	canonicalName = "ニハ語",
	family = "bnt",
}

m["nii"] = {
	canonicalName = "ニラ語",
}

m["nij"] = {
	canonicalName = "ンガジュ語",
	scripts = {"Latn"},
	family = "poz-brw",
}

m["nik"] = {
	canonicalName = "南部ニコバル語",
}

m["nil"] = {
	canonicalName = "Nila",
}

m["nim"] = {
	canonicalName = "ニランバ語",
}

m["nin"] = {
	canonicalName = "Ninzo",
}

m["nio"] = {
	canonicalName = "ガナサン語",
	scripts = {"Cyrl"},
	family = "syd",
}

m["niq"] = {
	canonicalName = "ナンディ語",
}

m["nir"] = {
	canonicalName = "ニンボラン語",
}

m["nis"] = {
	canonicalName = "ニミ語",
	family = "ngf-fin",
}

m["nit"] = {
	canonicalName = "南東部コーラーミー語",
	otherNames = {"Naiki"},
	family = "dra",
}

m["niu"] = {
	canonicalName = "ニウエ語",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["niv"] = {
	canonicalName = "ニヴフ語",
	scripts = {"Cyrl"},
	family = "qfa-iso",
}

m["niw"] = {
	canonicalName = "ニモ語",
	otherNames = {"Nimo"},
}

m["nix"] = {
	canonicalName = "Hema",
}

m["niy"] = {
	canonicalName = "Ngiti",
}

m["niz"] = {
	canonicalName = "ニンギル語",
	family = "qfa-tor",
}

m["nja"] = {
	canonicalName = "ンザニィ語",
}

m["njb"] = {
	canonicalName = "ノクテ・ナガ語",
}

m["njd"] = {
	canonicalName = "ンドンデ・ハンバ語",
}

m["njh"] = {
	canonicalName = "ロタ・ナガ語",
}

m["nji"] = {
	canonicalName = "Gudanji",
}

m["njj"] = {
	canonicalName = "Njen",
	family = "nic-bod",
}

m["njl"] = {
	canonicalName = "ンジャルグルグレ語",
	family = "sdv",
}

m["njm"] = {
	canonicalName = "アンガミ・ナガ語",
}

m["njn"] = {
	canonicalName = "Liangmai Naga",
}

m["njo"] = {
	canonicalName = "アオ・ナガ語",
	otherNames = {"Mongsen Ao", "Ao Naga"},
	scripts = {"Latn"},
	family = "tbq",
}

m["njr"] = {
	canonicalName = "Njerep",
	family = "nic-bod",
}

m["njs"] = {
	canonicalName = "ニサ語",
}

m["njt"] = {
	canonicalName = "アウカ＝トリオ・ピジン語",
}

m["nju"] = {
	canonicalName = "ンガジュンマヤ語",
}

m["njx"] = {
	canonicalName = "Kunyi",
	family = "bnt",
}

m["njy"] = {
	canonicalName = "ンジェム語",
	otherNames = {"Njem", "Njyem"},
	family = "bnt",
}

m["njz"] = {
	canonicalName = "Nyishi",
	otherNames = {"Nishi"},
	family = "sit",
}

m["nka"] = {
	canonicalName = "ンコヤ語",
}

m["nkb"] = {
	canonicalName = "Khoibu Naga",
}

m["nkc"] = {
	canonicalName = "高地ンボ語",
}

m["nkd"] = {
	canonicalName = "コイレン語",
}

m["nke"] = {
	canonicalName = "ドゥケ語",
	family = "poz-ocw",
}

m["nkf"] = {
	canonicalName = "インプイ・ナガ語",
}

m["nkg"] = {
	canonicalName = "ネクギニ語",
	family = "ngf-fin",
}

m["nkh"] = {
	canonicalName = "ケジャ・ナガ語",
}

m["nki"] = {
	canonicalName = "タンガル・ナガ語",
}

m["nkj"] = {
	canonicalName = "ナカイ語",
}

m["nkk"] = {
	canonicalName = "ノクク語",
	family = "poz-vnc",
}

m["nkm"] = {
	canonicalName = "ポタイア語",
}

m["nkn"] = {
	canonicalName = "ンカンガラ語",
}

m["nko"] = {
	canonicalName = "ンコニャ語",
}

m["nkp"] = {
	canonicalName = "ニウアトプタプ語",
	family = "poz-pol",
}

m["nkq"] = {
	canonicalName = "Nkami",
}

m["nkr"] = {
	canonicalName = "ヌクオロ語",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["nks"] = {
	canonicalName = "北アスマット語",
}

m["nkt"] = {
	canonicalName = "ニイカ語",
	otherNames = {"Nyiha", "Kinyika", "Kinyiha", "Nyixa", "Chinyika"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nku"] = {
	canonicalName = "ブナ・クランゴ語",
}

m["nkw"] = {
	canonicalName = "ンクトゥ語",
}

m["nkx"] = {
	canonicalName = "ンコロ語",
}

m["nkz"] = {
	canonicalName = "ンカリ語",
}

m["nla"] = {
	canonicalName = "ンゴンバレ語",
	family = "bai",
}

m["nlc"] = {
	canonicalName = "ナルチャ語",
	otherNames = {"Hmanggona", "Hmonono", "Kimjal"},
	scripts = {"Latn"},
	family = "ngf",
}

m["nle"] = {
	canonicalName = "東ニャラ語",
}

m["nlg"] = {
	canonicalName = "ジェーラ語",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["nli"] = {
	canonicalName = "ナンガラミ語",
	otherNames = {"Nangalami"},
	family = "inc-dar",
}

m["nlj"] = {
	canonicalName = "ニャリ語",
}

m["nlk"] = {
	canonicalName = "ニニア・ヤリ語",
}

m["nll"] = {
	canonicalName = "ニハリ語",
	scripts = {"Deva"},
	family = "qfa-iso",
}

m["nlo"] = {
	canonicalName = "ングル語",
}

m["nlq"] = {
	canonicalName = "ラオ・ナガ語",
}

m["nlu"] = {
	canonicalName = "ンチュンブル語",
}

m["nlv"] = {
	canonicalName = "オリサバ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nlw"] = {
	canonicalName = "ワランガマ語",
}

m["nlx"] = {
	canonicalName = "ナハーリー語",
}

m["nly"] = {
	canonicalName = "ニャマル語",
	family = "aus-nga",
}

m["nlz"] = {
	canonicalName = "ナロゴ語",
	family = "poz-oce",
}

m["nma"] = {
	canonicalName = "マラム・ナガ語",
}

m["nmb"] = {
	canonicalName = "大ナンバ語",
	family = "poz-vnc",
}

m["nmc"] = {
	canonicalName = "ニャム語",
}

m["nmd"] = {
	canonicalName = "ミンドゥウモ語",
	otherNames = {"Mindoumou", "Minduumo", "Ndumu"},
	family = "bnt",
}

m["nme"] = {
	canonicalName = "Mzieme Naga",
}

m["nmf"] = {
	canonicalName = "タンクール語",
	otherNames = {"Tangkhul", "Tangkhul Naga"},
}

m["nmg"] = {
	canonicalName = "クワシィオ語",
	otherNames = {"Kwasio", "Ngoumba", "Ngumba"},
	family = "bnt",
}

m["nmh"] = {
	canonicalName = "モンサン・ナガ語",
}

m["nmi"] = {
	canonicalName = "ニャン語",
}

m["nmj"] = {
	canonicalName = "ンゴンベ語",
	otherNames = {"Bagando-Ngombe", "Ngombe-Kaka", "Ngombe (Central African Republic)", "Ngombe"},
}

m["nmk"] = {
	canonicalName = "ナマクラ語",
	family = "poz-vnc",
}

m["nml"] = {
	canonicalName = "バンデム語",
	family = "nic-bod",
}

m["nmm"] = {
	canonicalName = "マナン語",
}

m["nmn"] = {
	canonicalName = "コン語",
	otherNames = {"Xoo", "Taa"},
	scripts = {"Latn"},
	family = "qfa-tuu",
}

m["nmo"] = {
	canonicalName = "モヨン・ナガ語",
	otherNames = {"Moyon"},
	family = "tbq-kuk",
}

m["nmp"] = {
	canonicalName = "ニマンブル語",
}

m["nmq"] = {
	canonicalName = "ナンビャ語",
}

m["nmr"] = {
	canonicalName = "ニンバリ語",
}

m["nms"] = {
	canonicalName = "レテンボイ語",
	family = "poz-vnc",
}

m["nmt"] = {
	canonicalName = "ナモヌイト語",
	family = "poz-mic",
}

m["nmu"] = {
	canonicalName = "北東マイドゥ語",
	family = "nai-mdu",
}

m["nmv"] = {
	canonicalName = "ンガミニ語",
	family = "aus-kar",
}

m["nmw"] = {
	canonicalName = "ニモア語",
	otherNames = {"Rifao"},
	family = "poz-ocw",
}

m["nmy"] = {
	canonicalName = "ナムイ語",
}

m["nmz"] = {
	canonicalName = "ロッソ語",
}

m["nna"] = {
	canonicalName = "ニャングマタ語",
}

m["nnb"] = {
	canonicalName = "ナンデ語",
}

m["nnc"] = {
	canonicalName = "ナンチェレ語",
}

m["nnd"] = {
	canonicalName = "西アンバエ語",
	family = "poz-vnc",
}

m["nne"] = {
	canonicalName = "ンガンジェラ語",
}

m["nnf"] = {
	canonicalName = "ンガイン語",
	family = "ngf-fin",
}

m["nng"] = {
	canonicalName = "マリン・ナガ語",
}

m["nnh"] = {
	canonicalName = "ンジエムブーン語",
	family = "bai",
}

m["nni"] = {
	canonicalName = "北ヌアウル語",
}

m["nnj"] = {
	canonicalName = "ニャンガトム語",
}

m["nnk"] = {
	canonicalName = "ナンキナ語",
	family = "ngf-fin",
}

m["nnl"] = {
	canonicalName = "北部レングマ・ナガ語",
}

m["nnm"] = {
	canonicalName = "ナミア語",
}

m["nnn"] = {
	canonicalName = "ネテ語",
}

m["nnp"] = {
	canonicalName = "ワンチョ・ナガ語",
}

m["nnq"] = {
	canonicalName = "ンギンド語",
}

m["nnr"] = {
	canonicalName = "ナルンガ語",
}

m["nns"] = {
	canonicalName = "ジャンダ語",
}

m["nnt"] = {
	canonicalName = "ナンティコック語",
	scripts = {"Latn"},
	family = "alg",
}

m["nnu"] = {
	canonicalName = "Dwang",
}

m["nnv"] = {
	canonicalName = "ヌグヌ語",
}

m["nnw"] = {
	canonicalName = "南部ヌニ語",
}

m["nnx"] = {
	canonicalName = "ンゴン語",
}

m["nny"] = {
	canonicalName = "ニャンガ語",
}

m["nnz"] = {
	canonicalName = "Nda'nda'",
	family = "bai",
}

m["noa"] = {
	canonicalName = "ノアナマ語",
}

m["noc"] = {
	canonicalName = "ヌク語",
	family = "ngf-fin",
}

m["nod"] = {
	canonicalName = "北タイ語",
	scripts = {"Lana", "Thai"},
	family = "tai-swe",
	sort_key = {
		Lana = "Lana-sortkey",
		Thai = "Thai-sortkey"
	},
}

m["noe"] = {
	canonicalName = "ニマディー語",
}

m["nof"] = {
	canonicalName = "ノーマン語",
}

m["nog"] = {
	canonicalName = "ノガイ語",
	otherNames = {"Nogay"},
	scripts = {"Cyrl", "Arab", "Latn"},
	family = "trk",
	translit_module = "nog-translit",
}

m["noh"] = {
	canonicalName = "ノム語",
}

m["noi"] = {
	canonicalName = "ノイリ語",
	family = "inc",
}

m["noj"] = {
	canonicalName = "アチオテ語",
}

m["nok"] = {
	canonicalName = "ノックサック語",
}

m["nol"] = {
	canonicalName = "ノムラキ語",
	family = "nai-wtq",
}

m["nom"] = {
	canonicalName = "マナグア語",
	family = "sai-pan",
}

m["non"] = {
	canonicalName = "古ノルド語",
	otherNames = {"Old Icelandic", "Old Norwegian"}, -- note: Old Swedish and Old Danish have their own codes
	scripts = {"Latn"},
	family = "gmq",
}

m["nop"] = {
	canonicalName = "マンガン語",
	family = "ngf-fin",
}

m["noq"] = {
	canonicalName = "ンゴンゴ語",
}

m["nos"] = {
	canonicalName = "東部ニス語",
	family = "tbq-lol",
}

m["not"] = {
	canonicalName = "ノマツィゲンガ語",
	family = "awd",
}

m["nou"] = {
	canonicalName = "エワゲ語",
}

m["nov"] = {
	canonicalName = "ノヴィアル",
	scripts = {"Latn"},
	family = "art",
}

m["now"] = {
	canonicalName = "ニヤンボ語",
}

m["noy"] = {
	canonicalName = "Noy",
}

m["noz"] = {
	canonicalName = "Nayi",
}

m["npa"] = {
	canonicalName = "ナル・プー語",
}

m["npb"] = {
	canonicalName = "ヌプビ語",
	family = "tbq",
}

m["nph"] = {
	canonicalName = "ポム・ナガ語",
	family = "sit",
}

m["npl"] = {
	canonicalName = "南東部プエブラ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["npn"] = {
	canonicalName = "Mondropolon",
	family = "poz-aay",
}

m["npo"] = {
	canonicalName = "ポチュリ・ナガ語",
}

m["nps"] = {
	canonicalName = "ニプサン語",
}

m["npu"] = {
	canonicalName = "プイメイ・ナガこ",
}

m["npy"] = {
	canonicalName = "ナプ語",
}

m["nqg"] = {
	canonicalName = "Ede Nago",
}

m["nqk"] = {
	canonicalName = "Kura Ede Nago",
}

m["nqm"] = {
	canonicalName = "ドム語",
}

m["nqn"] = {
	canonicalName = "Nen",
}

m["nqo"] = {
	canonicalName = "ンコ語",
	scripts = {"Nkoo"},
	family = "dmn",
}

m["nqq"] = {
	canonicalName = "Kyan-Karyaw Naga",
}

m["nra"] = {
	canonicalName = "Ngom",
}

m["nrb"] = {
	canonicalName = "Nara",
}

m["nrc"] = {
	canonicalName = "東部ケルト語",
	scripts = {"Ital"},
	family = "cel",
}

m["nre"] = {
	canonicalName = "南部リングマ・ナガ語",
}

m["nrf"] = {
	canonicalName = "ノルマン語",
	otherNames = {"Cauchois", "Jèrriais", "Jersey French", "Jersey Norman", "Jersey Norman French", "Guernésiais", "Dgèrnésiais", "Guernsey French", "Guernsey Norman French", "Augeron", "Sercquiais", "Auregnais"},
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"frm"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "æ" , "œ" , "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c", "ae", "oe"}} ,
	wikimedia_codes = {"nrm"},
}

m["nrg"] = {
	canonicalName = "ナランゴ語",
	family = "poz-vnc",
}

m["nri"] = {
	canonicalName = "チョークリ・ナガ語",
}

m["nrk"] = {
	canonicalName = "Ngarla",
	scripts = {"Latn"},
	family = "aus-nga",
}

m["nrl"] = {
	canonicalName = "Ngarluma",
	family = "aus-nga",
}

m["nrm"] = {
	canonicalName = "ナロム語",
	family = "poz-swa",
}

m["nrn"] = {
	canonicalName = "ノルン語",
	scripts = {"Latn"},
	family = "gmq",
	ancestors = {"non"},
}

m["nrp"] = {
	canonicalName = "North Picene",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["nrr"] = {
	canonicalName = "Norra",
}

m["nrt"] = {
	canonicalName = "Northern Kalapuya",
}

m["nru"] = {
	canonicalName = "ナルーア語",
	family = "tbq",
}

m["nrx"] = {
	canonicalName = "Ngurmbur",
}

m["nrz"] = {
	canonicalName = "ポカウ語",
	family = "poz-ocw",
}

m["nsa"] = {
	canonicalName = "サンタム・ナガ語",
}

m["nsc"] = {
	canonicalName = "Nshi",
}

m["nsd"] = {
	canonicalName = "南部ニス語",
	family = "tbq-lol",
}

m["nse"] = {
	canonicalName = "ンセンガ語",
}

m["nsg"] = {
	canonicalName = "ンガサ語",
	family = "sdv",
}

m["nsh"] = {
	canonicalName = "Ngoshie",
	family = "nic-bod",
}

m["nsi"] = {
	canonicalName = "ナイジェリア手話",
	family = "sgn",
}

m["nsk"] = {
	canonicalName = "ナスカピ語",
	scripts = {"Cans"},
	family = "alg",
	ancestors = {"cr"},
	translit_module = "nsk-translit",
}

m["nsl"] = {
	canonicalName = "ノルウェー手話",
	family = "sgn",
}

m["nsm"] = {
	canonicalName = "スミ・ナガ語",
}

m["nsn"] = {
	canonicalName = "ネハン語",
	family = "poz-ocw",
}

m["nso"] = {
	canonicalName = "ペディ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nsp"] = {
	canonicalName = "ネパール手話",
	family = "sgn",
}

m["nsq"] = {
	canonicalName = "北部シエラ・ミウォク語",
	family = "nai-utn",
}

m["nsr"] = {
	canonicalName = "沿海州手話",
	family = "sgn",
}

m["nss"] = {
	canonicalName = "ナリ語",
	family = "poz-aay",
}

m["nst"] = {
	canonicalName = "Tangsa",
}

m["nsu"] = {
	canonicalName = "シエラ・ネグラ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nsv"] = {
	canonicalName = "南西部ニス語",
	family = "tbq-lol",
}

m["nsw"] = {
	canonicalName = "ナヴト語",
	family = "poz-vnc",
}

m["nsx"] = {
	canonicalName = "ヌソンゴ語",
}

m["nsy"] = {
	canonicalName = "ナサル語",
}

m["nsz"] = {
	canonicalName = "ニセナン語",
	family = "nai-mdu",
}

m["ntd"] = {
	canonicalName = "北部ティドゥン語",
	otherNames = {"Sesayap Tidong", "Northern Tidung", "Sesayap Tidung"},
}

m["nte"] = {
	canonicalName = "Nathembo",
}

m["ntg"] = {
	canonicalName = "Ngantangarra",
}

m["nti"] = {
	canonicalName = "ナチョロ語",
}

m["ntj"] = {
	canonicalName = "ガーニャチャッラ語",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["ntk"] = {
	canonicalName = "イコマ＝ナタ＝イセニョ語",
}

m["ntm"] = {
	canonicalName = "Nateni",
}

m["nto"] = {
	canonicalName = "ントンバ語",
	otherNames = "Ntomba",
	scripts = {"Latn"},
	family = "bnt",
}

m["ntp"] = {
	canonicalName = "北部テペワン語",
	family = "azc",
}

m["ntr"] = {
	canonicalName = "デロ語",
}

m["nts"] = {
	canonicalName = "ピハオ語",
}

m["ntu"] = {
	canonicalName = "Natügu",
	family = "poz-oce",
}

m["ntw"] = {
	canonicalName = "ノットウェイ語",
	family = "iro",
}

m["ntx"] = {
	canonicalName = "タンクール・ナガ語",
	otherNames = {"Tangkhul Naga", "Burmese Tangkhul", "Somra Tangkhul"},
}

m["nty"] = {
	canonicalName = "Mantsi",
}

m["ntz"] = {
	canonicalName = "Natanzi",
	family = "ira",
}

m["nua"] = {
	canonicalName = "ユアンガ語",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["nuc"] = {
	canonicalName = "ヌキニ語",
}

m["nud"] = {
	canonicalName = "ンガラ語",
}

m["nue"] = {
	canonicalName = "ングンドゥ語",
}

m["nuf"] = {
	canonicalName = "ヌス語",
	scripts = {"Latn"},
	family = "tbq-lol",
}

m["nug"] = {
	canonicalName = "ヌンガリ語",
}

m["nuh"] = {
	canonicalName = "ダンダ語",
	family = "nic-bod",
}

m["nui"] = {
	canonicalName = "Ngumbi",
}

m["nuj"] = {
	canonicalName = "ニョレ語（ウガンダ）",
	otherNames = {"Nyole", "LoNyole", "Lunyole", "Nyuli"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nuk"] = {
	canonicalName = "ヌートカ語",
	otherNames = {"Nuu-chah-nulth", "Nuuchahnulth", "T'aat'aaqsapa"},
	scripts = {"Latn"},
	family = "wak",
}

m["nul"] = {
	canonicalName = "ヌサ・ラウト語",
}

m["num"] = {
	canonicalName = "ニウアフォオウ語",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["nun"] = {
	canonicalName = "アノン語",
	otherNames = {"Nung"}, -- also mistakenly assigned the name "Ayi" by the ISO
	family = "tbq",
}

m["nuo"] = {
	canonicalName = "Nguôn",
	family = "mkh-vie",
}

m["nup"] = {
	canonicalName = "ヌペ語",
	otherNames = {"Nupe", "Nupe-Nupe-Tako"},
	scripts = {"Latn"},
	entry_name = {remove_diacritics = GRAVE .. ACUTE .. CIRC .. MACRON .. CARON},
	family = "alv-von",
}

m["nuq"] = {
	canonicalName = "ヌクマヌ語",
	family = "poz-pol",
}

m["nur"] = {
	canonicalName = "ヌクリア語",
	otherNames = {"Nukuria"},
	family = "poz-pol",
}

m["nus"] = {
	canonicalName = "ヌエル語",
	family = "sdv",
}

m["nut"] = {
	canonicalName = "ヌン語",
	family = "tai",
}

m["nuu"] = {
	canonicalName = "ングブンドゥ語",
}

m["nuv"] = {
	canonicalName = "北部ヌニ語",
}

m["nuw"] = {
	canonicalName = "ングルウ語",
}

m["nux"] = {
	canonicalName = "メヘク語",
}

m["nuy"] = {
	canonicalName = "ヌングブユ語",
	otherNames = {"Wubuy"},
	family = "aus-arn",
}

m["nuz"] = {
	canonicalName = "トラマカサパ・ナワトル語",
	family = "azc-nah",
	ancestors = {"nah"},
}

m["nvh"] = {
	canonicalName = "ナサル語",
	family = "poz-vnc",
}

m["nvm"] = {
	canonicalName = "Namiae",
}

m["nvo"] = {
	canonicalName = "Nyokon",
	family = "nic-bod",
}

m["nwa"] = {
	canonicalName = "ナワティネへナ語",
	scripts = {"Latn"},
	family = "alg",
}

m["nwb"] = {
	canonicalName = "ニアブア語",
}

m["nwc"] = {
	canonicalName = "古典ネワール語",
	family = "sit",
}

m["nwe"] = {
	canonicalName = "ングウェ語",
	family = "bai",
}

m["nwi"] = {
	canonicalName = "南西タンナ語",
}

m["nwm"] = {
	canonicalName = "ニャムサ＝モロ語",
}

m["nwo"] = {
	canonicalName = "Nauo",
	otherNames = {"Nawo"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["nwr"] = {
	canonicalName = "Nawaru",
}

m["nwx"] = {
	canonicalName = "中世ネワール語",
	family = "sit",
	ancestors = {"nwc"},
}

m["nwy"] = {
	canonicalName = "ノットウェイ＝メヘリン語",
	family = "iro",
}

m["nxa"] = {
	canonicalName = "ナウエテ語",
	family = "poz",
}

m["nxd"] = {
	canonicalName = "ンガンド語",
	otherNames = {"Longandu", "Ngando (Democratic Republic of the Congo)", "Ngando"},
	family = "bnt",
}

m["nxe"] = {
	canonicalName = "ナゲ語",
	family = "plf",
}

m["nxg"] = {
	canonicalName = "ガダ語",
	otherNames = {"Ngad'a"},
	scripts = {"Latn"},
	family = "plf",
}

m["nxi"] = {
	canonicalName = "Nindi",
}

m["nxl"] = {
	canonicalName = "南ヌアウル語",
}

m["nxm"] = {
	canonicalName = "ヌミディア語",
}

m["nxn"] = {
	canonicalName = "ンガウン語",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["nxo"] = {
	canonicalName = "Ndambomo",
	scripts = {"Latn"},
	family = "bnt",
}

m["nxq"] = {
	canonicalName = "ナシ語",
	family = "tbq",
}

m["nxr"] = {
	canonicalName = "ニンゲルム語",
}

m["nxu"] = {
	canonicalName = "ナラウ語",
	scripts = {"Latn"},
	family = "ngf",
}

m["nxx"] = {
	canonicalName = "ナフリ語",
	scripts = {"Latn"},
	family = "paa",
}

m["nyb"] = {
	canonicalName = "ニャングボ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nyc"] = {
	canonicalName = "ニャンガ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nyd"] = {
	canonicalName = "ニョレ語（ケニア）",
	otherNames = {"Nyole", "Nyore", "Olunyole", "Lunyole", "Lunyore", "Nyoole", "Olunyore"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nye"] = {
	canonicalName = "ニェンゴ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nyf"] = {
	canonicalName = "ギリヤマ語",
	otherNames = {"Giriama", "Giryama", "Kigiryama"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nyg"] = {
	canonicalName = "ニンドゥ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nyh"] = {
	canonicalName = "ニギナ語",
	scripts = {"Latn"},
	family = "aus-nyu",
}

m["nyi"] = {
	canonicalName = "アマ語",
	scripts = {"Latn"},
	family = "sdv",
}

m["nyj"] = {
	canonicalName = "ニャンガ語",
	otherNames = {"Kinyanga", "Nyanga"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nyk"] = {
	canonicalName = "ニャネカ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nyl"] = {
	canonicalName = "Nyeu",
	family = "mkh",
}

m["nym"] = {
	canonicalName = "ニャムウェジ語",
	otherNames = {"ニャムウェズィ語", "Nyamwezi"},
	family = "bnt",
}

m["nyn"] = {
	canonicalName = "ンコレ語",
	otherNames = {"ニャンコレ語", "Nkole", "Nyankole", "Nyankore"},
	scripts = {"Latn"},
	family = "bnt",
}

m["nyo"] = {
	canonicalName = "ニョロ語",
	family = "bnt",
}

m["nyp"] = {
	canonicalName = "ニャニ語",
}

m["nyq"] = {
	canonicalName = "ナイーニ語",
	family = "ira",
}

m["nyr"] = {
	canonicalName = "ニイハ語",
	otherNames = {"Nyiha"},
}

m["nys"] = {
	canonicalName = "ニュンガ語",
	otherNames = {"Noongar", "Nyuunga"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["nyt"] = {
	canonicalName = "ニャワイギ語",
}

m["nyu"] = {
	canonicalName = "ニュングウェ語",
}

m["nyv"] = {
	canonicalName = "ニュルニュル語",
}

m["nyw"] = {
	canonicalName = "Nyaw",
}

m["nyx"] = {
	canonicalName = "ンガニャイワナ語",
	family = "aus-cww",
}

m["nyy"] = {
	canonicalName = "ニャキュウサ＝ンゴンデ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["nza"] = {
	canonicalName = "ティゴン・ンベンベ語",
}

m["nzb"] = {
	canonicalName = "ンゼビ語",
	otherNames = {"Bandzabi", "Njabi", "Njebi", "Nzebi"},
	family = "bnt",
}

m["nzd"] = {
	canonicalName = "ンザディ語",
	scripts = {"Latn"},
	family = "bnt-bdz",
}

m["nzi"] = {
	canonicalName = "ンゼマ語",
	otherNames = {"Nzema", "Nzima"},
	family = "bnt",
}

m["nzk"] = {
	canonicalName = "ンザカラ語",
	scripts = {"Latn"},
	family = "znd",
}

m["nzm"] = {
	canonicalName = "ツェメ・ナガ語",
}

m["nzs"] = {
	canonicalName = "ニュージーランド手話",
	family = "sgn",
}

m["nzu"] = {
	canonicalName = "Teke-Nzikou",
}

m["nzy"] = {
	canonicalName = "Nzakambay",
}

m["nzz"] = {
	canonicalName = "ナンガ・ダマ・ドゴン語",
	family = "qfa-dgn",
}

return m