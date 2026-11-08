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

m["laa"] = {
	canonicalName = "Lapuyan Subanun",
	family = "phi",
}

m["lab"] = {
	canonicalName = "ミノア語",
}

m["lac"] = {
	canonicalName = "ラカンドン語",
	otherNames = {"Jach t’aan", "Hach t’an"},
	family = "myn",
}

m["lad"] = {
	canonicalName = "ラディーノ語",
	otherNames = {"ユダヤ・スペイン語", "ジュデズモ語"},
	scripts = {"Hebr", "Latn", "Cyrl"},
	family = "roa",
	ancestors = {"osp"},
}

m["lae"] = {
	canonicalName = "Pattani",
}

m["laf"] = {
	canonicalName = "Lafofa",
}

m["lag"] = {
	canonicalName = "Langi",
}

m["lah"] = {
	canonicalName = "ラーンダ語",
	otherNames = {"西パンジャーブ語"},
	scripts = {"pa-Arab"},
	family = "inc",
	ancestors = {"pa"},
}

m["lai"] = {
	canonicalName = "Lambya",
}

m["laj"] = {
	canonicalName = "ランゴ語（ウガンダ）",
	otherNames = {"Lango", "Leb Lango"}, -- the last, though listed in Ethnologue, is not a name but rather the phrase "Lango language"
	scripts = {"Latn"},
	family = "sdv",
}

m["lak"] = {
	canonicalName = "Laka",
	otherNames = {"Laka (Nigeria)"},
	family = "alv",
}

m["lal"] = {
	canonicalName = "Lalia",
}

m["lam"] = {
	canonicalName = "ランバ語",
}

m["lan"] = {
	canonicalName = "Laru",
}

m["lap"] = {
	canonicalName = "Kabba-Laka",
	otherNames = {"Kabba Laka", "Laka (Chad)", "Laka"},
	family = "csu",
}

m["laq"] = {
	canonicalName = "Qabiao",
	otherNames = {"Laqua"},
	family = "qfa-tak",
}

m["lar"] = {
	canonicalName = "Larteh",
	family = "alv-kwa",
}

m["las"] = {
	canonicalName = "Gur Lama",
	otherNames = {"Lama (West Africa)", "Lama (Togo)", "Lama"}, -- contrast 'lay', "Tibeto-Burman Lama"
	family = "nic-gur",
}

m["lau"] = {
	canonicalName = "Laba",
}

m["law"] = {
	canonicalName = "Lauje",
	scripts = {"Latn"},
	family = "poz",
}

m["lax"] = {
	canonicalName = "Tiwa",
	otherNames = {"Lalung"},
	scripts = {"Latn"},
	family = "sit",
}

m["lay"] = {
	canonicalName = "Lama Bai",
	otherNames = {"Lama (Southeast Asia)", "Lama (Burma)", "Lama (Myanmar)", "Lama", "Northern Bai", "Laemae"}, -- the last two names are ambiguous, and also denote another Bai language
	family = "sit",
}

m["laz"] = {
	canonicalName = "Aribwatsa",
	family = "poz-ocw",
}

m["lba"] = {
	canonicalName = "Lui",
	family = "sit",
	ancestors = {"kdv"},
}

m["lbb"] = {
	canonicalName = "Label",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["lbc"] = {
	canonicalName = "ラキャ語",
}

m["lbe"] = {
	canonicalName = "ラク語",
	scripts = {"Cyrl"},
	family = "cau-nec",
	translit_module = "lbe-translit",
	override_translit = true,
}

m["lbf"] = {
	canonicalName = "ティナン語",
}

m["lbg"] = {
	canonicalName = "Laopang",
	family = "tbq-lol",
}

m["lbi"] = {
	canonicalName = "La'bi",
}

m["lbj"] = {
	canonicalName = "ラダック語",
	otherNames = {"Bhoti"},
	translit_module = "bo-translit",
}

m["lbk"] = {
	canonicalName = "中央ボントク語",
	otherNames = {"Central Bontok", "Igorot Bontoc", "Igorot Bontok", "Bontok Igorot", "Bontoc", "Bontok", "Finallig"},
	scripts = {"Latn"},
	family = "phi",
}

m["lbl"] = {
	canonicalName = "Libon Bikol",
}

m["lbm"] = {
	canonicalName = "Lodhi",
	family = "mun",
}

m["lbn"] = {
	canonicalName = "ラメート語",
}

m["lbo"] = {
	canonicalName = "ラヴェン語",
}

m["lbq"] = {
	canonicalName = "ワンパル語",
	family = "poz-ocw",
}

m["lbr"] = {
	canonicalName = "Northern Lorung",
	otherNames = {"Northern Lohorung"},
}

m["lbs"] = {
	canonicalName = "リビア手話",
	family = "sgn",
}

m["lbt"] = {
	canonicalName = "ラチ語",
}

m["lbu"] = {
	canonicalName = "ラブ語",
	family = "poz-ocw",
}

m["lbv"] = {
	canonicalName = "Lavatbura-Lamusong",
	family = "poz-ocw",
}

m["lbw"] = {
	canonicalName = "トラキ語",
	scripts = {"Latn"},
	family = "poz-btk",
}

m["lbx"] = {
	canonicalName = "ラワガン語",
}

m["lby"] = {
	canonicalName = "Lamu-Lamu",
}

m["lbz"] = {
	canonicalName = "ラディル語",
	otherNames = {"Leerdil", "Leertil", "Damin", "Demiin"},
}

m["lcc"] = {
	canonicalName = "Legenyem",
	family = "poz-hce",
}

m["lcd"] = {
	canonicalName = "ロラ語",
	family = "plf",
}

m["lce"] = {
	canonicalName = "Loncong",
}

m["lcf"] = {
	canonicalName = "ルブ語",
}

m["lch"] = {
	canonicalName = "ルチャジ語",
}

m["lcl"] = {
	canonicalName = "リセラ語",
	family = "plf",
}

m["lcm"] = {
	canonicalName = "Tungag",
	family = "poz-ocw",
}

m["lcp"] = {
	canonicalName = "西部ラワ語",
	scripts = {"Thai", "Latn"},
	family = "aav",
}

m["lcq"] = {
	canonicalName = "ルフ語",
	otherNames = {"Piru"},
	family = "plf",
}

m["lcs"] = {
	canonicalName = "リサバタ＝ヌニアリ語",
}

m["lda"] = {
	canonicalName = "Kla",
	family = "dmn",
}

m["ldb"] = {
	canonicalName = "Idun",
}

m["ldd"] = {
	canonicalName = "ルリ語",
}

m["ldg"] = {
	canonicalName = "レニマ語",
	family = "nic-bco",
}

m["ldh"] = {
	canonicalName = "Lamja-Dengsa-Tola",
}

m["ldi"] = {
	canonicalName = "ラーリ語",
	otherNames = {"Laadi", "Laari"},
	family = "bnt",
}

m["ldj"] = {
	canonicalName = "Lemoro",
}

m["ldk"] = {
	canonicalName = "Leelau",
}

m["ldl"] = {
	canonicalName = "Kaan",
}

m["ldm"] = {
	canonicalName = "ランドゥマ語",
}

m["ldn"] = {
	canonicalName = "ラーダン",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["ldo"] = {
	canonicalName = "ロー語",
}

m["ldp"] = {
	canonicalName = "Tso",
}

m["ldq"] = {
	canonicalName = "Lufu",
	family = "alv",
}

m["lea"] = {
	canonicalName = "Lega-Shabunda",
	otherNames = {"Lega-Malinga", "Lega Malinga", "Lega Shabunda", "Shabunda Lega", "Upper Lega", "Lower Lega", "Forest Lega", "Western Lega", "Southern Lega", "Liga", "Kiliga", "Lega", "Kilega", "KiLega", "Kanu", "Kikanu", "Gala", "Kigala", "Yoma", "Kiyoma", "Sede", "Kisede", "Gonzabale", "Beya", "Beia", "Nyamunsange", "KiNyamunsange", "Banagabo", "Kabango", "Bene"},
}

m["leb"] = {
	canonicalName = "ララ＝ビサ語",
}

m["lec"] = {
	canonicalName = "レコ語",
	family = "qfa-iso",
}

m["led"] = {
	canonicalName = "レンドゥ語",
	scripts = {"Latn"},
	family = "csu",
}

m["lee"] = {
	canonicalName = "リエレ語",
}

m["lef"] = {
	canonicalName = "レレミ語",
}

m["leh"] = {
	canonicalName = "レンジェ語",
}

m["lei"] = {
	canonicalName = "レミオ語",
}

m["lej"] = {
	canonicalName = "レンゴラ語",
	otherNames = "Lengola",
}

m["lek"] = {
	canonicalName = "Leipon",
	family = "poz-aay",
}

m["lel"] = {
	canonicalName = "レレ語",
	otherNames = {"Lele (Congo)", "Lele (Democratic Republic of the Congo)", "Lele", "Usilele"},
	family = "bnt",
}

m["lem"] = {
	canonicalName = "Nomaande",
	family = "nic-bod",
}

m["len"] = {
	canonicalName = "レンカ語",
	otherNames = {"Lenca", "Lencan"},
	scripts = {"Latn"},
	family = "nai-len",
}

m["leo"] = {
	canonicalName = "レティ語 (カメルーン)",
	otherNames = {"Leti"}, -- Ethnologue says this secret language has never had native speakers or been written
	family = "nic-bco",
}

m["lep"] = {
	canonicalName = "レプチャ語",
	scripts = {"Lepc"},
	family = "tbq",
	translit_module = "lep-translit"
}

m["leq"] = {
	canonicalName = "レンベナ語",
}

m["ler"] = {
	canonicalName = "Lenkau",
	family = "poz-aay",
}

m["les"] = {
	canonicalName = "レセ語",
}

m["let"] = {
	canonicalName = "Lesing-Gelimi",
	family = "poz-ocw",
}

m["leu"] = {
	canonicalName = "カラ語（パプアニューギニア）",
	otherNames = {"Kara (Papua New Guinea)", "Kara", "Lemakot"},
	family = "poz-ocw",
}

m["lev"] = {
	canonicalName = "ラムマ語",
}

m["lew"] = { -- this code was basically assigned as a catch-all for things that aren't brs, kzf or unz
	canonicalName = "レド・カイリ語",
	otherNames = {"Rai", "Tara", "Ta'a", "Taa", "Central Kaili", "East Kaili", "Ledo", "Edo", "Ado", "Doi", "Ija", "Tawaili", "Palu", "Parigi", "Sigi"},
	scripts = {"Latn"},
	family = "poz-kal",
}

m["lex"] = {
	canonicalName = "ルアン語",
}

m["ley"] = {
	canonicalName = "Lemolang",
}

m["lez"] = {
	canonicalName = "レズギ語",
	otherNames = {"Lezgian", "Lezgin"},
	scripts = {"Cyrl"},
	family = "cau-lzg",
	translit_module = "lez-translit",
	override_translit = true,
}

m["lfa"] = {
	canonicalName = "Lefa",
}

m["lfn"] = {
	canonicalName = "リングア・フランカ・ノバ",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["lga"] = {
	canonicalName = "ルンガ語",
	family = "poz-ocw",
}

m["lgb"] = {
	canonicalName = "ラグ語",
	family = "poz-ocw",
}

m["lgg"] = {
	canonicalName = "ルグバラ語",
	family = "csu-mma",
}

m["lgh"] = {
	canonicalName = "Laghuu",
	otherNames = {"Xá Phó", "Phù Lá Lão"},
	family = "tbq-lol",
}

m["lgi"] = {
	canonicalName = "Lengilu",
	family = "poz-swa",
}

m["lgk"] = {
	canonicalName = "リンガラク語",
	family = "poz-vnc",
}

m["lgl"] = {
	canonicalName = "ワラ語",
	family = "poz-sls",
}

m["lgm"] = {
	canonicalName = "Lega-Mwenga",
	otherNames = {"Lega-Ntara", "Lega Ntara", "Lega Mwenga", "Mwenga Lega", "Lower Lega", "Upper Lega", "Eastern Lega", "Northern Lega", "Isile", "Ishile", "Kisile", "Mwenda-Liga"},
	family = "bnt",
}

m["lgn"] = {
	canonicalName = "オプーオ語",
	otherNames = {"Opo", "Opuo", "Opo-Shita", "Shita", "Shiita", "Cita", "Ciita", "Ansita", "Kina", "Kwina", "T'apo"},
}

m["lgq"] = {
	canonicalName = "ログバ語",
	otherNames = {"Ikpana"},
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["lgr"] = {
	canonicalName = "レンゴ語",
	family = "poz-sls",
}

m["lgt"] = {
	canonicalName = "パヒ語",
}

m["lgu"] = {
	canonicalName = "ロング語",
	family = "poz-sls",
}

m["lgz"] = {
	canonicalName = "Ligenza",
}

m["lha"] = {
	canonicalName = "ラハ語（ベトナム）",
	otherNames = {"Laha", "La Ha"},
	family = "qfa-tak",
}

m["lhh"] = {
	canonicalName = "ラハ語（インドネシア）",
	otherNames = {"Laha", "Central Ambon"},
	family = "poz",
}

m["lhi"] = {
	canonicalName = "ラフ・シー語",
	family = "tbq-lol",
}

m["lhl"] = {
	canonicalName = "ラホール・ロハール語",
}

m["lhn"] = {
	canonicalName = "ラハナン語",
}

m["lhp"] = {
	canonicalName = "ロクプ語",
	family = "sit",
}

m["lhs"] = {
	canonicalName = "ムラハソー語",
}

m["lht"] = {
	canonicalName = "ロー・トガ語",
	family = "poz-vnc",
}

m["lhu"] = {
	canonicalName = "ラフ語",
	family = "tbq-lol",
}

m["lia"] = {
	canonicalName = "中西部リンバ語",
}

m["lib"] = {
	canonicalName = "リクム語",
	family = "poz-aay",
}

m["lic"] = {
	canonicalName = "黎語",
	otherNames = {"Bouhin", "Heitu", "Ha Em", "Zhongsha", "Lauhut", "Baoding", "Tongzha", "tongshi", "Zandui", "Baoting", "Nadou", "Dongfang", "Changjiang", "Moyjaw", "Xifang", "Baisha", "Yuanmen"}, -- some of these may need to be split off as languages
}

m["lid"] = {
	canonicalName = "Nyindrou",
	family = "poz-aay",
}

m["lie"] = {
	canonicalName = "リキラ語",
}

m["lif"] = {
	canonicalName = "リンブー語",
	scripts = {"Limb"},
	family = "tbq",
}

m["lig"] = {
	canonicalName = "リグビ語",
}

m["lih"] = {
	canonicalName = "リヒル語",
	family = "poz-ocw",
}

m["lii"] = {
	canonicalName = "リンキム語",
}

m["lij"] = {
	canonicalName = "リグリア語",
	scripts = {"Latn"},
	family = "roa",
}

m["lik"] = {
	canonicalName = "Lika",
}

m["lil"] = {
	canonicalName = "リルエット語",
}

m["lio"] = {
	canonicalName = "Liki",
	family = "poz-ocw",
}

m["lip"] = {
	canonicalName = "Sekpele",
}

m["liq"] = {
	canonicalName = "リビド語",
	family = "cus",
}

m["lir"] = {
	canonicalName = "リベリア英語",
}

m["lis"] = {
	canonicalName = "リス語",
	scripts = {"Lisu"},
	family = "tbq-lol",
}

m["liu"] = {
	canonicalName = "Logorik",
	family = "sdv",
}

m["liv"] = {
	canonicalName = "リヴォニア語",
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["liw"] = {
	canonicalName = "Col",
}

m["lix"] = {
	canonicalName = "Liabuku",
}

m["liy"] = {
	canonicalName = "バンダ＝バンバリ語",
}

m["liz"] = {
	canonicalName = "リビンザ語",
}

m["lja"] = {
	canonicalName = "Golpa",
	family = "aus-yol",
}

m["lje"] = {
	canonicalName = "ランピ語",
	family = "poz",
}

m["lji"] = {
	canonicalName = "Laiyolo",
}

m["ljl"] = {
	canonicalName = "リオ語",
}

m["ljp"] = {
	canonicalName = "ランプン語",
	scripts = {"Latn"},
	family = "poz-lgx",
}

m["ljw"] = {
	canonicalName = "Yirandali",
}

m["ljx"] = {
	canonicalName = "Yuru",
}

m["lka"] = {
	canonicalName = "Lakalei",
	family = "plf",
}

m["lkb"] = {
	canonicalName = "カブラス語",
}

m["lkc"] = {
	canonicalName = "Kucong",
	family = "tbq-lol",
}

m["lkd"] = {
	canonicalName = "ラコンデ語",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["lke"] = {
	canonicalName = "ケニィ語",
}

m["lkh"] = {
	canonicalName = "ラカ語",
}

m["lki"] = {
	canonicalName = "ラーク語",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["lkj"] = {
	canonicalName = "Remun",
}

m["lkl"] = {
	canonicalName = "ラエコ・リブアト語",
	family = "qfa-tor",
}

m["lkm"] = {
	canonicalName = "Kalaamaya",
}

m["lkn"] = {
	canonicalName = "ラコン語",
	family = "poz-vnc",
}

m["lko"] = {
	canonicalName = "ハヨ語",
}

m["lkr"] = {
	canonicalName = "Päri",
	family = "sdv",
}

m["lks"] = {
	canonicalName = "キサ語",
}

m["lkt"] = {
	canonicalName = "ラコタ語",
	otherNames = {"Lakhota"},
	scripts = {"Latn"},
	family = "sio",
}

m["lku"] = {
	canonicalName = "Kungkari",
}

m["lky"] = {
	canonicalName = "ロコヤ語",
	family = "sdv",
}

m["lla"] = {
	canonicalName = "ララ＝ロバ語",
}

m["llb"] = {
	canonicalName = "ロロ語",
}

m["llc"] = {
	canonicalName = "レレ語（ギニア）",
	otherNames = {"Lele"},
	family = "dmn",
}

m["lld"] = {
	canonicalName = "ラディン語",
	scripts = {"Latn"},
	family = "roa",
}

m["lle"] = {
	canonicalName = "レレ語（パプアニューギニア）",
	otherNames = {"Lele (Papua New Guinea)", "Lele", "Lele Hai"},
	family = "poz-oce",
}

m["llf"] = {
	canonicalName = "ハーミット語",
	family = "poz-aay",
}

m["llg"] = {
	canonicalName = "Lole",
	family = "plf",
}

m["llh"] = {
	canonicalName = "ラム語",
	family = "tbq-lol",
}

m["lli"] = {
	canonicalName = "ラリ語",
	otherNames = {"Laali", "Teke-Laali", "Lali"},
	family = "bnt",
}

m["llj"] = {
	canonicalName = "Ladji-Ladji",
	otherNames = {"Ledji-Ledji"},
	family = "aus-pam",
}

m["llk"] = {
	canonicalName = "Lelak",
	family = "poz-swa",
}

m["lll"] = {
	canonicalName = "リラウ語",
	family = "qfa-tor",
}

m["llm"] = {
	canonicalName = "Lasalimu",
}

m["lln"] = {
	canonicalName = "レレ語（チャド）",
	otherNames = {"Lele"},
	family = "cdc-est",
}

m["llo"] = {
	canonicalName = "クロール語",
	family = "mkh",
}

m["llp"] = {
	canonicalName = "北エファテ語",
	otherNames = {"Efate", "Vate", "Vaté", "Nguna"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["llq"] = {
	canonicalName = "ロラク語",
}

m["lls"] = {
	canonicalName = "リトアニア手話",
	family = "sgn",
}

m["llu"] = {
	canonicalName = "ラウ語",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["llx"] = {
	canonicalName = "Lauan",
	family = "poz-occ",
}

m["lma"] = {
	canonicalName = "東リンバ語",
}

m["lmb"] = {
	canonicalName = "Merei",
	family = "poz-vnc",
}

m["lmc"] = {
	canonicalName = "リミルンガン語",
}

m["lmd"] = {
	canonicalName = "ルムン語",
}

m["lme"] = {
	canonicalName = "ペヴェ語",
}

m["lmf"] = {
	canonicalName = "南レンバタ語",
}

m["lmg"] = {
	canonicalName = "ラモガイ語",
	family = "poz-ocw",
}

m["lmh"] = {
	canonicalName = "ランビチョン語",
}

m["lmi"] = {
	canonicalName = "ロムビ語",
}

m["lmj"] = {
	canonicalName = "西レンバタ語",
}

m["lmk"] = {
	canonicalName = "Lamkang",
	family = "tbq-kuk",
}

m["lml"] = {
	canonicalName = "ラガ語",
	otherNames = {"Hano", "Bwatvenua", "Lamalanga", "Vunmarama", "Loltong"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["lmn"] = {
	canonicalName = "ランバディ語",
	otherNames = {"Banjari", "Goar-boali"},
	family = "inc",
}

m["lmo"] = {
	canonicalName = "ロンバルド語",
	scripts = {"Latn"},
	family = "roa",
}

m["lmp"] = {
	canonicalName = "リンブム語",
	family = "nic-bod",
}

m["lmq"] = {
	canonicalName = "Lamatuka",
}

m["lmr"] = {
	canonicalName = "ラマレラ語",
}

m["lmu"] = {
	canonicalName = "Lamenu",
	family = "poz-vnc",
}

m["lmv"] = {
	canonicalName = "Lomaiviti",
	family = "poz-occ",
}

m["lmw"] = {
	canonicalName = "湖畔ミウォク語",
	family = "nai-you",
}

m["lmx"] = {
	canonicalName = "Laimbue",
}

m["lmy"] = {
	canonicalName = "ランボヤ語",
}

m["lmz"] = {
	canonicalName = "ラムビー語",
	scripts = {"Latn"},
}

m["lna"] = {
	canonicalName = "Langbashe",
}

m["lnb"] = {
	canonicalName = "Mbalanhu",
}

m["lnd"] = {
	canonicalName = "ルンダイェ語",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["lnh"] = {
	canonicalName = "ラノー語",
}

m["lni"] = {
	canonicalName = "Daantanai'",
}

m["lnj"] = {
	canonicalName = "Linngithigh",
	otherNames = {"Linngithig", "Leningitij"},
}

m["lnl"] = {
	canonicalName = "中南部バンダ語",
}

m["lnm"] = {
	canonicalName = "ランガム語",
	family = "paa",
}

m["lnn"] = {
	canonicalName = "ロレディアカルカル語",
	family = "poz-vnc",
}

m["lno"] = {
	canonicalName = "ランゴ語（スーダン）",
	otherNames = {"Lango", "Lango (South Sudan)", "Langgo"},
	family = "sdv",
}

m["lns"] = {
	canonicalName = "ラムンソ語'",
}

m["lnu"] = {
	canonicalName = "ロングダ語",
	scripts = {"Latn"},
	family = "nic",
}

m["lnw"] = {
	canonicalName = "Lanima",
	family = "aus-pam",
}

m["lnz"] = {
	canonicalName = "Lonzo",
	family = "nic-bco",
}

m["loa"] = {
	canonicalName = "ロロダ語",
	family = "paa",
}

m["lob"] = {
	canonicalName = "ロビ語",
}

m["loc"] = {
	canonicalName = "イヌンハン語",
}

m["lod"] = {
	canonicalName = "べラワン語",
	otherNames = {"Central Berawan", "East Berawan", "West Berawan", "Long Terawan", "Batu Belah", "Long Teru", "Long Jegan", "Long Pata"},
	scripts = {"Latn"},
	family = "poz-swa",
}

m["loe"] = {
	canonicalName = "サルアン語",
}

m["lof"] = {
	canonicalName = "ロゴル語",
}

m["log"] = {
	canonicalName = "ロゴ語",
}

m["loh"] = {
	canonicalName = "ナリム語",
	family = "sdv",
}

m["loi"] = {
	canonicalName = "ロマ語（コートジボワール）",
	otherNames = {"Loma"},
	family = "nic",
}

m["loj"] = {
	canonicalName = "ロウ語",
	scripts = {"Latn"},
	family = "poz-aay",
}

m["lok"] = {
	canonicalName = "ロコ語",
}

m["lol"] = {
	canonicalName = "モンゴ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["lom"] = {
	canonicalName = "ロマ語（リベリア）",
	otherNames = {"Loma"},
	family = "dmn",
}

m["lon"] = {
	canonicalName = "ラマウィ・ロムエ語",
}

m["loo"] = {
	canonicalName = "ロンボ語 (コンゴ民主共和国)",
	otherNames = {"Lombo", "Turumbu"},
	family = "bnt",
}

m["lop"] = {
	canonicalName = "ロパ語",
}

m["loq"] = {
	canonicalName = "ロバラ語",
}

m["lor"] = {
	canonicalName = "テーン語",
}

m["los"] = {
	canonicalName = "ロニウ語",
	family = "poz-aay",
}

m["lot"] = {
	canonicalName = "Lotuko",
	family = "sdv",
}

m["lou"] = {
	canonicalName = "ルイジアナ・クレオール語",
	otherNames = {"Louisiana Creole", "Kréyol"},
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"fr"},
}

m["lov"] = {
	canonicalName = "Lopi",
}

m["low"] = {
	canonicalName = "ロブ語",
}

m["lox"] = {
	canonicalName = "ロウン語",
	family = "plf",
}

m["loz"] = {
	canonicalName = "ロジ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["lpa"] = {
	canonicalName = "Lelepa",
	family = "poz-vnc",
}

m["lpe"] = {
	canonicalName = "Lepki",
}

m["lpn"] = {
	canonicalName = "Long Phuri Naga",
}

m["lpo"] = {
	canonicalName = "Lipo",
	otherNames = {"Eastern Lisu"},
	scripts = {"Plrd"},
	family = "tbq-lol",
}

m["lpx"] = {
	canonicalName = "ロピット語",
	family = "sdv",
}

m["lra"] = {
	canonicalName = "Rara Bakati'",
}

m["lrc"] = {
	canonicalName = "北部ルーリー語",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["lre"] = {
	canonicalName = "ローレンシア語",
	otherNames = {"St. Lawrence Iroquoian"},
	scripts = {"Latn"},
	family = "iro",
}

m["lrg"] = {
	canonicalName = "ララギア語",
}

m["lri"] = {
	canonicalName = "マラチ語",
}

m["lrk"] = {
	canonicalName = "ロアルキ語",
	otherNames = {"Gade Lohar"},
}

m["lrl"] = {
	canonicalName = "ラーリ語",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["lrm"] = {
	canonicalName = "マラマ語",
}

m["lrn"] = {
	canonicalName = "Lorang",
}

m["lro"] = {
	canonicalName = "ラロ語",
}

m["lrr"] = {
	canonicalName = "南部ヤンプ語",
	otherNames = {"Yamphe", "Southern Yamphe", "Yamphu", "Southern Yamphu"},
}

m["lrt"] = {
	canonicalName = "ララントゥカ・マライ語",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["lrv"] = {
	canonicalName = "ラレヴァト語",
	family = "poz-vnc",
}

m["lrz"] = {
	canonicalName = "Lemerig",
	family = "poz-vnc",
}

m["lsa"] = {
	canonicalName = "ラスゲルディー語",
	family = "ira",
}

m["lsd"] = {
	canonicalName = "デニ語",
	otherNames = {"Betanure Jewish Neo-Aramaic"},
	scripts = {"Hebr"},
	family = "sem-ara",
}

m["lse"] = {
	canonicalName = "ルセンゴ語",
}

m["lsg"] = {
	canonicalName = "リヨン手話",
	family = "sgn",
}

m["lsh"] = {
	canonicalName = "Lish",
}

m["lsi"] = {
	canonicalName = "ラシ語", -- Chashan is either a dialect or needs a code
	otherNames = {"Lacid", "Lachik", "Leqi"},
	family = "tbq-brm",
}

m["lsl"] = {
	canonicalName = "ラトヴィア手話",
	family = "sgn",
}

m["lsm"] = {
	canonicalName = "サアミア語",
}

m["lso"] = {
	canonicalName = "ラオス手話",
	otherNames = {"Laotian Sign Language"},
	family = "sgn",
}

m["lsp"] = {
	canonicalName = "パナマ手話",
	family = "sgn",
}

m["lsr"] = {
	canonicalName = "アルオップ語",
	otherNames = {"Srenge", "Sreengge","Lawu"},
	family = "qfa-tor",
}

m["lss"] = {
	canonicalName = "ラーシー語",
	scripts = {"Arab"},
	family = "inc",
	ancestors = {"sd"},
}

m["lst"] = {
	canonicalName = "トリニダード・トバゴ手話",
	family = "sgn",
}

m["lsy"] = {
	canonicalName = "モーリシャス手話",
	family = "sgn",
}

m["ltc"] = {
	canonicalName = "中古漢語",
	otherNames = {"Late Middle Chinese", "Early Middle Chinese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"och"},
}

m["ltg"] = {
	canonicalName = "ラトガリア語",
	scripts = {"Latn"},
	family = "bat",
}

m["lti"] = {
	canonicalName = "レティ語 (インドネシア)",
	otherNames = {"Leti"},
	scripts = {"Latn"},
	family = "plf",
}

m["ltn"] = {
	canonicalName = "ラトゥンデ語",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["lto"] = {
	canonicalName = "ツォツォ語",
}

m["lts"] = {
	canonicalName = "タチョニ語",
}

m["ltu"] = {
	canonicalName = "Latu",
}

m["lua"] = {
	canonicalName = "ルバ＝ルルア語",
	scripts = {"Latn"},
	family = "bnt",
}

m["luc"] = {
	canonicalName = "アリンガ語",
}

m["lud"] = {
	canonicalName = "リュード語",
	otherNames = {"Ludic", "Lude"},
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["lue"] = {
	canonicalName = "ルヴァレ語",
}

m["luf"] = {
	canonicalName = "ラウア語",
}

m["lui"] = {
	canonicalName = "ルイセーニョ語",
	otherNames = {"Luiseno", "Juaneño", "Juaneno"},
	scripts = {"Latn"},
	family = "azc-cup",
	entry_name = {
		from = {"̂", ACUTE},
		to   = {}
	},
}

m["luj"] = {
	canonicalName = "ルナ語",
}

m["luk"] = {
	canonicalName = "Lunanakha",
}

m["lul"] = {
	canonicalName = "Olu'bo",
}

m["lum"] = {
	canonicalName = "ルインビ語",
}

m["lun"] = {
	canonicalName = "ルンダ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["luo"] = {
	canonicalName = "ルオ語",
	otherNames = {"Dholuo"},
	scripts = {"Latn"},
	family = "sdv",
}

m["lup"] = {
	canonicalName = "ルンブ語",
	family = "bnt",
}

m["luq"] = {
	canonicalName = "ルチュミ語",
}

m["lur"] = {
	canonicalName = "ラウラ語",
}

m["lus"] = {
	canonicalName = "ルシャイ語",
	otherNames = {"ミゾ語"},
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["lut"] = {
	canonicalName = "ルシュツィード語",
	scripts = {"Latn"},
	family = "sal",
}

m["luu"] = {
	canonicalName = "ルンバ＝ヤッカ語",
}

m["luv"] = {
	canonicalName = "ルワティ語",
}

m["luy"] = {
	canonicalName = "ルヒヤ語",
	scripts = {"Latn"},
	family = "bnt",
}

m["luz"] = {
	canonicalName = "南部ルーリー語",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["lva"] = {
	canonicalName = "Maku'a",
}

m["lvk"] = {
	canonicalName = "ラヴカレヴェ語",
	scripts = {"Latn"},
	family = "paa",
}

m["lvu"] = {
	canonicalName = "レブカ語",
}

m["lwa"] = {
	canonicalName = "Lwalu",
}

m["lwe"] = {
	canonicalName = "Lewo Eleng",
}

m["lwg"] = {
	canonicalName = "ワンガ語",
}

m["lwh"] = {
	canonicalName = "白ラチ語",
}

m["lwl"] = {
	canonicalName = "東部ラワ語",
	scripts = {"Thai", "Latn"},
	family = "aav",
}

m["lwm"] = {
	canonicalName = "Laomian",
	family = "tbq-lol",
}

m["lwo"] = {
	canonicalName = "ルウォ語",
	otherNames = {"Jur", "Giur"},
	scripts = {"Latn"},
	family = "sdv",
}

m["lwt"] = {
	canonicalName = "レウォトビ語",
}

m["lwu"] = {
	canonicalName = "Lawu",
}

m["lww"] = {
	canonicalName = "レウォ語",
	family = "poz-vnc",
}

m["lya"] = {
	canonicalName = "ラヤカ語",
}

m["lyg"] = {
	canonicalName = "リンガム語",
	family = "aav",
}

m["lyn"] = {
	canonicalName = "ルヤナ語",
}

m["lzh"] = {
	canonicalName = "文語中国語",
	scripts = {"Hani"},
	family = "zhx",
	wikimedia_codes = {"zh-classical"},
}

m["lzl"] = {
	canonicalName = "Litzlitz",
	family = "poz-vnc",
}

m["lzn"] = {
	canonicalName = "Leinong Naga",
}

m["lzz"] = {
	canonicalName = "ラズ語",
	scripts = {"Geor", "Latn"},
	family = "ccs-zan",
	translit_module = "Geor-translit",
	override_translit = true,
	entry_name = {
		from = {"̂", GRAVE, ACUTE},
		to   = {}},
}

return m