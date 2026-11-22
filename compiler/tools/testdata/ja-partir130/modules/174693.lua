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

m["aaa"] = {
	canonicalName = "ゴトゥオ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["aab"] = {
	canonicalName = "Alumu-Tesu",
	otherNames = {"Alumu", "Tesu"},
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["aac"] = {
	canonicalName = "アリ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aad"] = {
	canonicalName = "アマル語",
	type = "regular",
	scripts = {"None"},
	family = "paa-iwm",
}

m["aae"] = {
	canonicalName = "アルバレシュ・アルバニア語",
	type = "regular",
	scripts = {"Latn"},
	family = "sqj",
	ancestors = {"sqj-pro"},
}

m["aaf"] = {
	canonicalName = "アラナダン語",
	otherNames = {"Eranadan"},
	type = "regular",
	scripts = {"None"},
	family = "dra",
}

m["aag"] = {
	canonicalName = "Ambrak",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aah"] = {
	canonicalName = "Abu' Arapesh",
	otherNames = {"Abu'", "Ua"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aai"] = {
	canonicalName = "Arifama-Miniafia",
	otherNames = {"Arifama", "Miniafia"},
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["aak"] = {
	canonicalName = "アンカベ語",
	otherNames = {"Angave"},
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["aal"] = {
	canonicalName = "アファデ語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-cbm",
}

m["aan"] = {
	canonicalName = "アナンベ語",
	otherNames = {"Anambe"},
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["aao"] = {
	canonicalName = "アルジェリア・サハラ・アラビア語",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aap"] = {
	canonicalName = "パラ・アララ語",
	otherNames = {"Arára"},
	type = "regular",
	scripts = {"Latn"},
	family = "sai-car",
}

m["aaq"] = {
	canonicalName = "アベナキ語ペノブスコット方言",
	otherNames = {"Eastern Abenaki", "Eastern Abnaki"},
	type = "regular",
	scripts = {"Latn"},
	family = "alg",
}

m["aas"] = {
	canonicalName = "アーサックス語",
	otherNames = {"Aasáx", "Asa", "Aramanik", "Laramanik"},
	type = "regular",
	scripts = {"None"},
	family = "sdv",
}

m["aat"] = {
	canonicalName = "アルヴァニティカ・アルバニア語",
	type = "regular",
	scripts = {"None"},
	family = "sqj",
}

m["aau"] = {
	canonicalName = "アバウ語",
	type = "regular",
	scripts = {"Latn"},
	family = "paa",
}

m["aaw"] = {
	canonicalName = "Solong",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["aax"] = {
	canonicalName = "Mandobo Atas",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aaz"] = {
	canonicalName = "アマラシ語",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["aba"] = {
	canonicalName = "アベイ語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["abb"] = {
	canonicalName = "バンコン語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["abc"] = {
	canonicalName = "Ambala Ayta",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["abd"] = {
	canonicalName = "Camarines Norte Agta",
	type = "regular",
	scripts = {"Latn"},
	family = "phi",
}

m["abe"] = {
	canonicalName = "アベナキ語",
	otherNames = {"Western Abenaki", "Abnaki", "Western Abnaki"},
	type = "regular",
	scripts = {"Latn"},
	family = "alg",
}

m["abf"] = {
	canonicalName = "アパイ・スガイ語",
	type = "regular",
	scripts = {"None"},
	family = "poz",
}

m["abg"] = {
	canonicalName = "アバガ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["abh"] = {
	canonicalName = "アラビア語タジク方言",
	type = "regular",
	scripts = {"None"},
	family = "sem-arb",
}

m["abi"] = {
	canonicalName = "アビジ語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["abj"] = {
	canonicalName = "アカ・ベア語",
	otherNames = {"Bea"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["abl"] = {
	canonicalName = "ランプン・ニョ語",
	otherNames = {"Pepadun", "Lampung Nyo"},
	type = "regular",
	scripts = {"None"},
	family = "poz",
}

m["abm"] = {
	canonicalName = "アバニョム語",
	type = "regular",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["abn"] = {
	canonicalName = "アブア語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["abo"] = {
	canonicalName = "アボン語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["abp"] = {
	canonicalName = "Abenlen Ayta",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["abq"] = {
	canonicalName = "アバザ語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-abz",
	translit_module = "abq-translit",
	ancestors = {"cau-abz-pro"},
}

m["abr"] = {
	canonicalName = "アブロン語",
	otherNames = {"Brong"},
	type = "regular",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["abs"] = {
	canonicalName = "アンボン語",
	type = "regular",
	scripts = {"None"},
	family = "crp",
}

m["abt"] = {
	canonicalName = "Ambulas",
	type = "regular",
	scripts = {"Latn"},
	family = "paa",
}

m["abu"] = {
	canonicalName = "アブレ語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["abv"] = {
        canonicalName = "アラビア語バハルナ方言",
        otherNames = {"Bahrani Arabic"},
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["abw"] = {
	canonicalName = "パル語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["abx"] = {
	canonicalName = "イナバクノン語",
	type = "regular",
	scripts = {"None"},
	family = "poz-sbj",
}

m["aby"] = {
	canonicalName = "アビア語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["abz"] = {
	canonicalName = "アブイ語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["aca"] = {
	canonicalName = "アチャグア語",
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["acb"] = {
	canonicalName = "Áncá",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["acd"] = {
	canonicalName = "Gikyode",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["ace"] = {
	canonicalName = "アチェ語",
	otherNames = {"Achinese", "Atjehnese"},
	type = "regular",
	scripts = {"Latn", "Arab"},
	family = "poz-msa",
}

m["ach"] = {
	canonicalName = "アチョリ語",
	otherNames = {"Acoli", "Shuli", "Acooli"},
	type = "regular",
	scripts = {"Latn"},
	family = "sdv",
}

m["aci"] = {
	canonicalName = "アカ＝チャリ語",
	otherNames = {"Cari", "Aka-Kari", "Kari", "Chariar"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["ack"] = {
	canonicalName = "アカ＝コラ語",
	otherNames = {"Kora"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["acl"] = {
	canonicalName = "アカル＝バレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["acm"] = {
	canonicalName = "アラビア語イラク方言",
	otherNames = {"Mesopotamian Arabic"},
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acn"] = {
	canonicalName = "アチャン語",
	otherNames = {"Xiandao"},
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["acp"] = {
	canonicalName = "東部アシパ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["acq"] = {
        canonicalName = "アラビア語タイズィ＝アデン方言",
        otherNames = {"Southern Yemeni Arabic"},
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["acr"] = {
	canonicalName = "アチ語",
	otherNames = {"Achí", "Achi Maya", "Cubulco Achi", "Cubulco Achí", "Cubulco Achi'"},
	type = "regular",
	scripts = {"None"},
	family = "myn",
}

m["acs"] = {
	canonicalName = "Acroá",
	type = "regular",
	scripts = {"None"},
	family = "sai-jee",
}

m["acu"] = {
	canonicalName = "アチュアル＝シウィアル語",
	otherNames = {"Achuar-Shiwiar"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-jiv",
}

m["acv"] = {
	canonicalName = "アチュマウィ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-pal",
}

m["acw"] = {
        canonicalName = "アラビア語ヒジャーズ方言",
        otherNames = {"Hejazi Arabic", "West Arabian Arabic"},
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["acx"] = {
	canonicalName = "アラビア語オマーン方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["acy"] = {
	canonicalName = "アラビア語キプロス方言",
	type = "regular",
	scripts = {"None"},
	family = "sem-arb",
}

m["acz"] = {
	canonicalName = "アチェロン語",
	otherNames = {"Asheron"},
	type = "regular",
	scripts = {"None"},
	family = "nic",
}

m["ada"] = {
	canonicalName = "アダングメ語",
	otherNames = {"Dangme"},
	type = "regular",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adb"] = {
	canonicalName = "Adabe",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["add"] = {
	canonicalName = "ゾディンカ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["ade"] = {
	canonicalName = "アデレ語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adf"] = {
	canonicalName = "アラビア語ゾファール方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["adg"] = {
	canonicalName = "アンデゲレビナ語",
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["adh"] = {
	canonicalName = "アドラ語",
	type = "regular",
	scripts = {"None"},
	family = "sdv",
}

m["adi"] = {
	canonicalName = "Adi",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["adj"] = {
	canonicalName = "アジュクル語",
	otherNames = {"Adioukrou", "Adjukru", "Adyoukrou", "Adyukru", "Ajukru"},
	type = "regular",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["adl"] = {
	canonicalName = "Galo",
	otherNames = {"Gallong"},
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["adn"] = {
	canonicalName = "アダン語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["ado"] = {
	canonicalName = "Abu",
	type = "regular",
	scripts = {"Latn"},
	family = "paa",
}

m["adp"] = {
	canonicalName = "アダップ語",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["adq"] = {
	canonicalName = "アダングバ語",
	otherNames = {"Agotime"},
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["adr"] = {
	canonicalName = "Adonara",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["ads"] = {
	canonicalName = "アダモロベ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["adt"] = {
	canonicalName = "アドニャマタンハ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["adu"] = {
	canonicalName = "Aduge",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["adw"] = {
	canonicalName = "Amundava",
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["adx"] = {
	canonicalName = "アムド・チベット語",
	otherNames = {"Amdo", "Panang"},
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["ady"] = {
	canonicalName = "アディゲ語",
	otherNames = {"West Circassian"},
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-cir",
	ancestors = {"cau-cir-pro"},
	translit_module = "ady-translit",
}

m["adz"] = {
	canonicalName = "アゼラ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["aea"] = {
	canonicalName = "アレバ語",
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["aeb"] = {
	canonicalName = "アラビア語チュニジア方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["aec"] = {
        canonicalName = "アラビア語サイード方言",
        otherNames = {"Sa'idi Arabic", "Upper Egyptian Arabic", "Upper Egypt Arabic"},
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["aed"] = {
	canonicalName = "アルゼンチン手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["aee"] = {
	canonicalName = "北東パシャイ語",
	type = "regular",
	scripts = {"None"},
	family = "iir-dar",
}

m["aek"] = {
	canonicalName = "ハエケ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["ael"] = {
	canonicalName = "Ambele",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["aem"] = {
	canonicalName = "アレム語",
	type = "regular",
	scripts = {"None"},
	family = "aav",
}

m["aen"] = {
	canonicalName = "アルメニア手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["aeq"] = {
	canonicalName = "アエル語",
	type = "regular",
	scripts = {"None"},
	family = "inc",
}

m["aer"] = {
	canonicalName = "東部アレルンテ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["aes"] = {
	canonicalName = "アルシー語",
	otherNames = {"Yaquina", "Yakwina", "Alseya", "Yakona"}, -- names of the two dialects that make up the language
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aeu"] = {
	canonicalName = "Akeu",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["aew"] = {
	canonicalName = "Ambakich",
	otherNames = {"Aion", "Porapora"},
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["aey"] = {
	canonicalName = "アメレ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aez"] = {
	canonicalName = "アエカ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["afb"] = {
	canonicalName = "アラビア語湾岸方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["afd"] = {
	canonicalName = "Andai",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["afe"] = {
	canonicalName = "Putukwam",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["afg"] = {
	canonicalName = "アフガニスタン手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["afh"] = {
	canonicalName = "アフリヒリ語",
	type = "appendix-constructed",
	scripts = {"None"},
	family = "art",
}

m["afi"] = {
	canonicalName = "アクルカイ語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["afk"] = {
	canonicalName = "Nanubae",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["afn"] = {
	canonicalName = "デファカ語",
	type = "regular",
	scripts = {"None"},
	family = "nic",
}

m["afo"] = {
	canonicalName = "エロイ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["afp"] = {
	canonicalName = "Tapei",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["afs"] = {
	canonicalName = "アフロ・セミノール語",
	type = "regular",
	scripts = {"None"},
	family = "crp",
}

m["aft"] = {
	canonicalName = "アフィティ語",
	type = "regular",
	scripts = {"None"},
	family = "sdv",
}

m["afu"] = {
	canonicalName = "アウトゥ語",
	otherNames = {"Efutu"},
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["afz"] = {
	canonicalName = "Obokuitai",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["aga"] = {
	canonicalName = "アグアノ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["agb"] = {
	canonicalName = "レグボ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["agc"] = {
	canonicalName = "アガトゥ語",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["agd"] = {
	canonicalName = "アガラビ語",
	type = "regular",
	scripts = {"None"},
	family = "paa-kag",
}

m["age"] = {
	canonicalName = "アンガル語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["agf"] = {
	canonicalName = "アルグゥニ語",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["agg"] = {
	canonicalName = "アンゴル語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["agh"] = {
	canonicalName = "Ngelima",
	type = "regular",
	scripts = {"None"},
	family = "bnt",
}

m["agi"] = {
	canonicalName = "アガリヤ語",
	type = "regular",
	scripts = {"None"},
	family = "mun",
}

m["agj"] = {
	canonicalName = "アルゴバ語",
	type = "regular",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["agk"] = {
	canonicalName = "イサログ・アグタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["agl"] = {
	canonicalName = "Fembe",
	otherNames = {"Agala"},
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["agm"] = {
	canonicalName = "Angaataha",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["agn"] = {
	canonicalName = "アグタイネン語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["ago"] = {
	canonicalName = "Tainae",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["agq"] = {
	canonicalName = "アゲム語",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["agr"] = {
	canonicalName = "アグアルナ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-jiv",
}

m["ags"] = {
	canonicalName = "エスィンビ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["agt"] = {
	canonicalName = "中央カガヤン・アグタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["agu"] = {
	canonicalName = "アワカテク語",
	otherNames = {"Awakatek", "Aguacatec"},
	type = "regular",
	scripts = {"Latn"},
	family = "myn",
}

m["agv"] = {
	canonicalName = "Remontado Agta",
	otherNames = {"Remontado Dumagat", "Sinauna", "Hatang Kayey"},
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["agw"] = {
	canonicalName = "カフア語",
	type = "regular",
	scripts = {"None"},
	family = "poz-sls",
}

m["agx"] = {
	canonicalName = "アグール語",
	otherNames = {"Agul"},
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-nec",
}

m["agy"] = {
	canonicalName = "南部アルタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["agz"] = {
	canonicalName = "イリガ山アグタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["aha"] = {
	canonicalName = "アハンタ語",
	otherNames = "Ahanta",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["ahb"] = {
	canonicalName = "アハンブ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-vnc",
}

m["ahg"] = {
	canonicalName = "キマント語",
	type = "regular",
	scripts = {"None"},
	family = "cus",
}

m["ahh"] = {
	canonicalName = "アグフ語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["ahi"] = {
	canonicalName = "Tiagbamrin Aizi",
	type = "regular",
	scripts = {"None"},
	family = "kro",
}

m["ahk"] = {
	canonicalName = "アカ語",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["ahl"] = {
	canonicalName = "Igo",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["ahm"] = {
	canonicalName = "Mobumrin Aizi",
	type = "regular",
	scripts = {"None"},
	family = "kro",
}

m["ahn"] = {
	canonicalName = "アハン語",
	otherNames = {"Ahan", "Ahaan"},
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["aho"] = {
	canonicalName = "アホム語",
	type = "regular",
	scripts = {"Ahom"},
	family = "tai",
	translit_module = "Ahom-translit",
}

m["ahp"] = {
	canonicalName = "Aproumu Aizi",
	type = "regular",
	scripts = {"None"},
	family = "kro",
}

m["ahr"] = {
	canonicalName = "アヒラーニー語",
	type = "regular",
	scripts = {"None"},
	family = "inc",
}

m["ahs"] = {
	canonicalName = "アシェ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["aht"] = {
	canonicalName = "アトナ語",
	type = "regular",
	scripts = {"None"},
	family = "ath-nor",
}

m["aia"] = {
	canonicalName = "アロシ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["aib"] = {
	canonicalName = "エイヌ語",
	type = "regular",
	scripts = {"None"},
	family = "trk",
}

m["aic"] = {
	canonicalName = "Ainbai",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["aid"] = {
	canonicalName = "アルンギトゥ語",
	type = "regular",
	scripts = {"None"},
	family = "aus-pmn",
}

m["aie"] = {
	canonicalName = "アマラ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["aif"] = {
	canonicalName = "アギ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aig"] = {
	canonicalName = "アンティグア・バーブーダ・クレオール語",
	type = "regular",
	scripts = {"None"},
	family = "crp",
}

m["aih"] = {
	canonicalName = "錦語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["aii"] = {
	canonicalName = "アッシリア現代アラム語",
	type = "regular",
	scripts = {"Syrc"},
	family = "sem-ara",
}

m["aij"] = {
	canonicalName = "ノシャン語",
	type = "regular",
	scripts = {"None"},
	family = "sem-ara",
}

m["aik"] = {
	canonicalName = "アケ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ail"] = {
	canonicalName = "Aimele",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aim"] = {
	canonicalName = "アイモル語",
	type = "regular",
	scripts = {"None"},
	family = "tbq-kuk",
}

m["ain"] = {
	canonicalName = "アイヌ語",
	type = "regular",
	scripts = {"Kana", "Latn", "Cyrl"},
	family = "qfa-iso",
}

m["aio"] = {
	canonicalName = "タイ・アイトン語",
	type = "regular",
	scripts = {"None"},
	family = "tai-swe",
}

m["aip"] = {
	canonicalName = "Burumakok",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aiq"] = {
	canonicalName = "アイマク語",
	type = "regular",
	scripts = {"None"},
	family = "ira",
}

m["air"] = {
	canonicalName = "アイロラン語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["ais"] = {
	canonicalName = "ナタウラン・アミ語",
	type = "regular",
	scripts = {"None"},
	family = "map",
}

m["ait"] = {
	canonicalName = "アリケム語",
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["aiw"] = {
	canonicalName = "アリ語",
	type = "regular",
	scripts = {"Latn"},
	family = "omv",
}

m["aix"] = {
	canonicalName = "Aighon",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["aiy"] = {
	canonicalName = "アリ語",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["aja"] = {
	canonicalName = "アジャ語（南スーダン）",
	otherNames = {"Adja", "Aja (Sudan)"},
	type = "regular",
	scripts = {"None"},
	family = "csu",
}

m["ajg"] = {
	canonicalName = "アジャ語（ベナン）",
	otherNames = {"Aja", "Aja (Benin)"},
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["aji"] = {
	canonicalName = "アジエ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["ajn"] = {
	canonicalName = "Andajin", -- sometimes considered a dialect of 'ung'
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["ajp"] = {
	canonicalName = "アラビア語南レバント方言",
	otherNames = {"South Levantine Arabic"},
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ajt"] = {
	canonicalName = "アラビア語ユダヤ＝チュニジア方言",
	type = "regular",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["aju"] = {
	canonicalName = "アラビア語ユダヤ＝モロッコ方言",
	type = "regular",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["ajw"] = {
	canonicalName = "アジャワ語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-wst",
}

m["ajz"] = {
	canonicalName = "Amri Karbi",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["akb"] = {
	canonicalName = "バタク・アンコーラ語",
	otherNames = {"Batak Angkola"},
	type = "regular",
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["akc"] = {
	canonicalName = "Mpur",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["akd"] = {
	canonicalName = "Ukpet-Ehom",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ake"] = {
	canonicalName = "アカワイオ語",
	type = "regular",
	scripts = {"Latn"},
	family = "sai-car",
}

m["akf"] = {
	canonicalName = "アクパ語",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["akg"] = {
	canonicalName = "アナカラング語",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["akh"] = {
	canonicalName = "Angal Heneng",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aki"] = {
	canonicalName = "アイオメ語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["akj"] = {
	canonicalName = "アカ＝ジェル語",
	otherNames = {"Aka-Jeru"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["akk"] = {
	canonicalName = "アッカド語",
	type = "regular",
	scripts = {"Xsux"},
	family = "sem-eas",
}

m["akl"] = {
	canonicalName = "アクラノン語",
	otherNames = {"Aklan", "Akeanon"},
	type = "regular",
	scripts = {"Latn"},
	family = "phi",
}

m["akm"] = {
	canonicalName = "アカ＝ボ語",
	otherNames = {"Ba", "Bo"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["ako"] = {
	canonicalName = "アクリオ語",
	type = "regular",
	scripts = {"None"},
	family = "sai-car",
}

m["akp"] = {
	canonicalName = "Siwu",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["akq"] = {
	canonicalName = "アク語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["akr"] = {
	canonicalName = "アラキ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["aks"] = {
	canonicalName = "Akaselem",
	type = "regular",
	scripts = {"None"},
	family = "nic-gur",
}

m["akt"] = {
	canonicalName = "Akolet",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["aku"] = {
	canonicalName = "アクム語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["akv"] = {
	canonicalName = "アフバフ語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-nec",
}

m["akw"] = {
	canonicalName = "アクワ語",
	otherNames = {"Akwa"}, 
	type = "regular",
	scripts = {"None"},
	family = "bnt",
}

m["akx"] = {
	canonicalName = "アカ＝ケデ語",
	otherNames = {"Kede"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["aky"] = {
	canonicalName = "アカ＝コル語",
	otherNames = {"Kol"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["akz"] = {
	canonicalName = "アラバマ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-mus",
}

m["ala"] = {
	canonicalName = "アラゴ語",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["alc"] = {
	canonicalName = "カワスカル語",
	otherNames = {"Qawasqar"},
	type = "regular",
	scripts = {"Latn"},
	family = "aqa",
}

m["ald"] = {
	canonicalName = "アラジャン語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["ale"] = {
	canonicalName = "アレウト語",
	type = "regular",
	scripts = {"Latn"},
	family = "esx",
}

m["alf"] = {
	canonicalName = "アレゲ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["alh"] = {
	canonicalName = "アラワ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ali"] = {
	canonicalName = "アマイモン語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["alj"] = {
	canonicalName = "アランガン語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["alk"] = {
	canonicalName = "アラック語",
	type = "regular",
	scripts = {"None"},
	family = "mkh",
}

m["all"] = {
	canonicalName = "Allar",
	type = "regular",
	scripts = {"None"},
	family = "dra",
}

m["alm"] = {
	canonicalName = "アンブロン語",
	type = "regular",
	scripts = {"None"},
	family = "poz-vnc",
}

m["aln"] = {
	canonicalName = "ゲグ・アルバニア語",
	type = "regular",
	scripts = {"Latn"},
	family = "sqj",
}

m["alo"] = {
	canonicalName = "Larike-Wakasihu",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["alp"] = {
	canonicalName = "アルネ語",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["alq"] = {
	canonicalName = "アルゴンキン語",
	type = "regular",
	scripts = {"Latn"},
	family = "alg",
}

m["alr"] = {
	canonicalName = "アリュートル語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "qfa-cka",
}

m["alt"] = {
	canonicalName = "南アルタイ語",
	otherNames = {"Southern Altay", "Altai", "Altay"},
	type = "regular",
	scripts = {"Cyrl"},
	family = "trk",
	translit_module = "Altai-translit",
}

m["alu"] = {
	canonicalName = "アレアレ語",
	otherNames = {"Areare"},
	type = "regular",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["alw"] = {
	canonicalName = "アラバ＝ケベンナ語",
	otherNames = {"Alaba-K'abeena", "Alaaba", "K'abeena"},
	type = "regular",
	scripts = {"Latn"},
	family = "cus",
}

m["alx"] = {
	canonicalName = "Amol",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aly"] = {
	canonicalName = "アリャワル語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["alz"] = {
	canonicalName = "アルル語",
	type = "regular",
	scripts = {"None"},
	family = "sdv",
}

m["ama"] = {
	canonicalName = "アマナイェ語",
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["amb"] = {
	canonicalName = "アンボ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["amc"] = {
	canonicalName = "アマワカ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-pan",
}

m["ame"] = {
	canonicalName = "ヤネシャ語'",
	otherNames = {"Amuesha"},
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["amf"] = {
	canonicalName = "ハメル＝バンナ語",
	type = "regular",
	scripts = {"Latn"},
	family = "omv",
}

m["amg"] = {
	canonicalName = "Amurdag",
	otherNames = {"Amarag"},
	type = "regular",
	scripts = {"Latn"},
	family = "aus-wdj",
}

m["ami"] = {
	canonicalName = "アミ語",
	type = "regular",
	scripts = {"Latn"},
	family = "map",
}

m["amj"] = {
	canonicalName = "Amdang",
	type = "regular",
	scripts = {"None"},
	family = "ssa-fur",
}

m["amk"] = {
	canonicalName = "アンバイ語",
	otherNames = {"Wadapi-Laut"},
	type = "regular",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["aml"] = {
	canonicalName = "ワール＝ジャインティア語",
	type = "regular",
	scripts = {"None"},
	family = "aav",
}

m["amm"] = {
	canonicalName = "アマ語",
	otherNames = {"Ama (New Guinea)", "Ama (Papua New Guinea)"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-mal",
}

m["amn"] = {
	canonicalName = "アマナブ語",
	type = "regular",
	scripts = {"Latn"},
	family = "ngf",
}

m["amo"] = {
	canonicalName = "アモ語",
	type = "regular",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["amp"] = {
	canonicalName = "アランブラク語",
	type = "regular",
	scripts = {"Latn"},
	family = "paa",
}

m["amq"] = {
	canonicalName = "アマハイ語",
	type = "regular",
	scripts = {"None"},
	family = "plf",
}

m["amr"] = {
	canonicalName = "アマラカエリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ams"] = {
	canonicalName = "南奄美大島語",
	type = "regular",
	scripts = {"None"},
	family = "jpx",
}

m["amt"] = {
	canonicalName = "アムト語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["amu"] = {
	canonicalName = "アムスコ語",
	otherNames = {"Guerrero Amuzgo"}, -- WP suggests this is only one dialect of Amzugo, which could make it misleading to call it plain Amzugo
	type = "regular",
	scripts = {"Latn"},
	family = "omq",
}

m["amv"] = {
	canonicalName = "アンベラウ語",
	type = "regular",
	scripts = {"None"},
	family = "poz",
}

m["amw"] = {
	canonicalName = "現代西アラム語",
	type = "regular",
	scripts = {"None"},
	family = "sem-ara",
}

m["amx"] = {
	canonicalName = "アンマチャラ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["amy"] = {
	canonicalName = "アミ語 (オーストラリア)",
	otherNames = {"Ame", "Amijangal"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["amz"] = {
	canonicalName = "アタンパヤ語",
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["ana"] = {
	canonicalName = "アンダキ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["anb"] = {
	canonicalName = "アンドア語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-zap",
}

m["anc"] = {
	canonicalName = "アンガス語",
	type = "regular",
	scripts = {"None"},
	family = "cdc-wst",
}

m["and"] = {
	canonicalName = "アンスス語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["ane"] = {
	canonicalName = "ハランチュー語",
	type = "regular",
	scripts = {"None"},
	family = "poz-cln",
}

m["anf"] = {
	canonicalName = "アニメレ語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["ang"] = {
	canonicalName = "古英語",
	otherNames = {"アングロ・サクソン語"},
	type = "regular",
	scripts = {"Latinx"},
	family = "gmw",
	ancestors = {"gem-pro"},
	entry_name = {
		from = {"Ā", "ā", "Ǣ", "ǣ", "Ċ", "ċ", "Ē", "ē", "Ġ", "ġ", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ", "Á", "á", "Ǽ", "ǽ", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", "Ý", "ý"},
		to   = {"A", "a", "Æ", "æ", "C", "c", "E", "e", "G", "g", "I", "i", "O", "o", "U", "u", "Y", "y", "A", "a", "Æ", "æ", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}} ,
}

m["anh"] = {
	canonicalName = "ネンド語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["ani"] = {
	canonicalName = "アンディ語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-nec",
}

m["anj"] = {
	canonicalName = "アノル語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["ank"] = {
	canonicalName = "ゴエマイ語",
	otherNames = {"アンクェー語"},
	type = "regular",
	scripts = {"None"},
	family = "cdc-wst",
}

m["anl"] = {
	canonicalName = "Anu",
	otherNames = {"Khaungtso", "Anu-Hkongso Chin"}, -- the last name is the one used by the ISO, an unattested blend of the names of the lect's two dialects and half of the name of the place where it is spoken
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["anm"] = {
	canonicalName = "アナル語",
	otherNames = {"Namfau"}, -- the latter is a placename, not properly a language name, though it is encountered as one
	type = "regular",
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["ann"] = {
	canonicalName = "オボロ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ano"] = {
	canonicalName = "アンドケ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["anp"] = {
	canonicalName = "アンギカ語",
	type = "regular",
	scripts = {"None"},
	family = "inc",
}

m["anq"] = {
	canonicalName = "ジャラワ語",
	otherNames = {"Jarawa (India)"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-adm",
}

m["anr"] = {
	canonicalName = "アンダ語",
	type = "regular",
	scripts = {"None"},
	family = "inc",
}

m["ans"] = {
	canonicalName = "アンセルマ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ant"] = {
	canonicalName = "Antakarinya",
	type = "regular",
	scripts = {"None"},
	family = "aus-psw",
}

m["anu"] = {
	canonicalName = "アヌアク語",
	type = "regular",
	scripts = {"None"},
	family = "sdv",
}

m["anv"] = {
	canonicalName = "Denya",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["anw"] = {
	canonicalName = "アナン語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["anx"] = {
	canonicalName = "Andra-Hus",
	type = "regular",
	scripts = {"None"},
	family = "poz-aay",
}

m["any"] = {
	canonicalName = "アニ語",
	otherNames = {"Anyi", "Anyin"},
	type = "regular",
	scripts = {"Latn"},
	family = "alv-kwa",
}

m["anz"] = {
	canonicalName = "アネム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aoa"] = {
	canonicalName = "アンゴラ語",
	type = "regular",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"pt"},
}

m["aob"] = {
	canonicalName = "Abom",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aoc"] = {
	canonicalName = "ペモン語",
	otherNames = {"Arekuna"},
	type = "regular",
	scripts = {"Latn"},
	family = "sai-car",
}

m["aod"] = {
	canonicalName = "アンダルム語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["aoe"] = {
	canonicalName = "Angal Enen",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aof"] = {
	canonicalName = "ブラガット語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aog"] = {
	canonicalName = "アンゴラム語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aoh"] = {
	canonicalName = "アルマ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aoi"] = {
	canonicalName = "アニンデリャクワ語",
	otherNames = {"Enindhilyagwa"},
	type = "regular",
	scripts = {"Latn"},
	family = "aus-arn",
}

m["aoj"] = {
	canonicalName = "Mufian",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aok"] = {
	canonicalName = "アロ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-cln",
}

m["aol"] = {
	canonicalName = "アロル語",
	otherNames = {"Alorese"},
	type = "regular",
	scripts = {"None"},
	family = "poz",
}

m["aom"] = {
	canonicalName = "オミエ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["aon"] = {
	canonicalName = "ブンビタ・アラペシュ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aor"] = {
	canonicalName = "アオレ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-vnc",
}

m["aos"] = {
	canonicalName = "タイカト語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["aot"] = {
	canonicalName = "アトン語（インド）",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["aou"] = {
	canonicalName = "阿欧語",
	otherNames = {"Ayo", "A'ou Gelao"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-tak",
}

m["aox"] = {
	canonicalName = "アトラダ語",
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["aoz"] = {
	canonicalName = "ウアブ・メト語",
	type = "regular",
	scripts = {"Latn"},
	family = "plf",
}

m["apb"] = {
	canonicalName = "サア語",
	otherNames = {"South Malaita", "Apae'aa"},
	type = "regular",
	scripts = {"None"},
	family = "poz-sls",
}

m["apc"] = {
	canonicalName = "アラビア語北レバント方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["apd"] = {
	canonicalName = "アラビア語スーダン方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ape"] = {
	canonicalName = "ブキイプ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["apf"] = {
	canonicalName = "Pahanan Agta",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["apg"] = {
	canonicalName = "アンパナン語",
	type = "regular",
	scripts = {"None"},
	family = "poz",
}

m["aph"] = {
	canonicalName = "アトパリヤ語",
	otherNames = {"Athpariya"},
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["api"] = {
	canonicalName = "アピアカ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["apj"] = {
	canonicalName = "ジカリラ・アパッチ語",
	otherNames = {"Jicarilla Apache"},
	type = "regular",
	scripts = {"Latn"},
	family = "apa",
}

m["apk"] = {
	canonicalName = "カイオワ・アパッチ語",
	otherNames = {"Kiowa Apache"},
	type = "regular",
	scripts = {"Latn"},
	family = "apa",
}

m["apl"] = {
	canonicalName = "リパン・アパッチ語",
	otherNames = {"Lipan Apache"},
	type = "regular",
	scripts = {"Latn"},
	family = "apa",
}

m["apm"] = {
	canonicalName = "チリカフア語",
	otherNames = {"Mescalero", "Mescalero-Chiricahua Apache"}, -- two dialects combined by Ethnologue
	type = "regular",
	scripts = {"Latn"},
	family = "apa",
}

m["apn"] = {
	canonicalName = "アピナイェ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["apo"] = {
	canonicalName = "Ambul",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["app"] = {
	canonicalName = "アプマ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["apq"] = {
	canonicalName = "ア＝プチクワル語",
	otherNames = {"Pucikwar"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-adm",
}

m["apr"] = {
	canonicalName = "アロップ＝ロケップ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aps"] = {
	canonicalName = "アロップ＝シッサノ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["apt"] = {
	canonicalName = "アパタニ語",
	type = "regular",
	scripts = {"None"},
	family = "tbq",
}

m["apu"] = {
	canonicalName = "アプリニャ語",
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["apv"] = {
	canonicalName = "アラプムンテ語",
	type = "regular",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["apw"] = {
	canonicalName = "西アパッチ語",
	type = "regular",
	scripts = {"Latn"},
	family = "apa",
}

m["apx"] = {
	canonicalName = "Aputai",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["apy"] = {
	canonicalName = "アパライ語",
	otherNames = {"Apalai"},
	type = "regular",
	scripts = {"Latn"},
	family = "sai-car",
}

m["apz"] = {
	canonicalName = "サフェヨカ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aqc"] = {
	canonicalName = "アルチ語",
	type = "regular",
	scripts = {"Cyrl"},
	family = "cau-nec",
}

m["aqd"] = {
	canonicalName = "Ampari Dogon",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-dgn",
}

m["aqg"] = {
	canonicalName = "アリギディ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aqm"] = {
	canonicalName = "Atohwaim",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aqn"] = {
	canonicalName = "北部アルタ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aqp"] = {
	canonicalName = "アタカパ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aqr"] = {
	canonicalName = "アラ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-cln",
}

m["aqt"] = {
	canonicalName = "アンガイテ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aqz"] = {
	canonicalName = "アクンツ語",
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["arc"] = {
	canonicalName = "アラム語",
	type = "regular",
	scripts = {"Hebr", "Armi", "Syrc", "Palm", "Nbat"},
	family = "sem-ara",
	entry_name = {
		from = {"[" .. u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. "]", "[" .. u(0x0308) .. u(0x0730) .. "-" .. u(0x0748) .. "]" },
		to   = {}} ,
}

m["ard"] = {
	canonicalName = "アラバナ語",
	type = "regular",
	scripts = {"None"},
	family = "aus-kar",
}

m["are"] = {
	canonicalName = "上アレンテ語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["arh"] = {
	canonicalName = "アルワコ語",
	otherNames = {"Ika"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["ari"] = {
	canonicalName = "アリカラ語",
	type = "regular",
	scripts = {"None"},
	family = "cdd",
}

m["arj"] = {
	canonicalName = "アラパソ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ark"] = {
	canonicalName = "アリカプ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["arl"] = {
	canonicalName = "アラベラ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-zap",
}

m["arn"] = {
	canonicalName = "マプチェ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-ara",
}

m["aro"] = {
	canonicalName = "アラオナ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-tac",
}

m["arp"] = {
	canonicalName = "アラパホー語",
	type = "regular",
	scripts = {"Latn"},
	family = "alg",
}

m["arq"] = {
	canonicalName = "アラビア語アルジェリア方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["arr"] = {
	canonicalName = "Arara-Karo",
	otherNames = {"Karo", "Karo (Brazil)"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ars"] = {
        canonicalName = "アラビア語ナジディ方言",
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["aru"] = {
	canonicalName = "Arua",
	otherNames = {"Aruá", "Arawa", "Arawá"}, -- extinct, spoken in northern Brazil, cf. 'arx'
	type = "regular",
	scripts = {"Latn"},
	family = "auf",
}

m["arv"] = {
	canonicalName = "アルボレ語",
	type = "regular",
	scripts = {"Latn"},
	family = "cus",
}

m["arw"] = {
	canonicalName = "アラワク語",
	type = "regular",
	scripts = {"Latn"},
	family = "awd",
}

m["arx"] = {
	canonicalName = "アルア語",
	otherNames = {"Arua", "Aruashi", "Aruáshi", "Aruachi"}, -- moribund, spoken in central Brazil, cf. 'aru'
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["ary"] = {
	canonicalName = "アラビア語モロッコ方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["arz"] = {
	canonicalName = "アラビア語エジプト方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["asa"] = {
	canonicalName = "アス語",
	otherNames = {"Asu", "Asu (Tanzania)", "Chasu"},
	type = "regular",
	scripts = {"Latn"},
	family = "bnt",
}

m["asb"] = {
	canonicalName = "アシニボイン語",
	type = "regular",
	scripts = {"None"},
	family = "sio",
}

m["asc"] = {
	canonicalName = "木麻黄海岸アスマット語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asd"] = {
	canonicalName = "アサス語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ase"] = {
	canonicalName = "アメリカ手話",
	otherNames = {"Ameslan", "ASL"},
	type = "regular",
	scripts = {"Sgnw"},
	family = "sgn",
}

m["asf"] = {
	canonicalName = "オーストラリア手話",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asg"] = {
	canonicalName = "Cishingini",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ash"] = {
	canonicalName = "アビシラ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-iso",
}

m["asi"] = {
	canonicalName = "Buruwai",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asj"] = {
	canonicalName = "Nsari",
	otherNames = {"Sari", "Saari"},
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["ask"] = {
	canonicalName = "アシュク語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asl"] = {
	canonicalName = "アシルル語",
	type = "regular",
	scripts = {"Latn"},
	family = "plf",
}

m["asn"] = {
	canonicalName = "シングー・アスリニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aso"] = {
	canonicalName = "Dano",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["asp"] = {
	canonicalName = "アルジェリア手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["asq"] = {
	canonicalName = "オーストリア手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["asr"] = {
	canonicalName = "アスル語",
	type = "regular",
	scripts = {"None"},
	family = "mun",
}

m["ass"] = {
	canonicalName = "Ipulo",
	type = "regular",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["ast"] = {
	canonicalName = "アストゥリアス語",
	type = "regular",
	scripts = {"Latn"},
	family = "roa",
}

m["asu"] = {
	canonicalName = "トカンティンス・アスリニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asv"] = {
	canonicalName = "Asoa",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asw"] = {
	canonicalName = "オーストラリアアボリジニ手話",
	type = "regular",
	scripts = {"None"},
	family = "sgn",
}

m["asx"] = {
	canonicalName = "Muratayak",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["asy"] = {
	canonicalName = "Yaosakor Asmat",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["asz"] = {
	canonicalName = "アス語",
	type = "regular",
	scripts = {"None"},
	family = "poz-hce",
}

m["ata"] = {
	canonicalName = "ペレアタ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atb"] = {
	canonicalName = "ツァイワ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atc"] = {
	canonicalName = "アツァワカ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-pan",
}

m["atd"] = {
	canonicalName = "アタ・マノボ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["ate"] = {
	canonicalName = "Atemble",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atg"] = {
	canonicalName = "Okpela",
	otherNames = {"Ivbie North", "Arhe", "Ivbie North-Okpela-Arhe"},
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ati"] = {
	canonicalName = "アチェ語 (コートジボワール)",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atj"] = {
	canonicalName = "アティカメク語",
	type = "regular",
	scripts = {"Latn"},
	family = "alg",
}

m["atk"] = {
	canonicalName = "アティ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atl"] = {
	canonicalName = "イラヤ山アグタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["atm"] = {
	canonicalName = "アタ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atn"] = {
	canonicalName = "アーシュティアーニ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ato"] = {
	canonicalName = "アトン語",
	otherNames = {"A'tong"},
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["atp"] = {
	canonicalName = "プッドトル・アッタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["atq"] = {
	canonicalName = "アラッレ＝タブラハン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atr"] = {
	canonicalName = "ワイミリ＝アトロアリ語",
	type = "regular",
	scripts = {"None"},
	family = "sai-car",
}

m["ats"] = {
	canonicalName = "グロー・ヴァントル語",
	otherNames = {"Atsina"},
	type = "regular",
	scripts = {"Latn"},
	family = "alg",
}

m["att"] = {
	canonicalName = "パンプローナ・アッタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["atu"] = {
	canonicalName = "Reel",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["atv"] = {
	canonicalName = "北アルタイ語",
	otherNames = {"Northern Altay", "Altai", "Altay"},
	type = "regular",
	scripts = {"Cyrl"},
	family = "trk",
}

m["atw"] = {
	canonicalName = "アツゲウィ語",
	otherNames = {"Atsugé"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-pal",
}

m["atx"] = {
	canonicalName = "アルタニ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["aty"] = {
	canonicalName = "アネイチュム語",
	otherNames = {"アネジョム語"},
	type = "regular",
	scripts = {"None"},
	family = "poz-oce",
}

m["atz"] = {
	canonicalName = "アルタ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aua"] = {
	canonicalName = "アスンボア語",
	type = "regular",
	scripts = {"None"},
	family = "poz-oce",
}

m["aub"] = {
	canonicalName = "Alugu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["auc"] = {
	canonicalName = "ワオラニ語",
	otherNames = {"Waorani", "Sabela", "Wao", "Huao", "Aushiri", "Ssabela", "Wao Terero", "Auka", "Auca"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["aud"] = {
	canonicalName = "アヌタ語",
	type = "regular",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["aue"] = {
	canonicalName = "ǂKxʼauǁʼein",
	otherNames = {"ǁAuǁei", "Auen", "Kaukau", "Koko", "Kung-Gobabis", "‡Kx'auǁ'ei", "ǂKx'auǁ'ein", "ǁX'auǁ'e"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aug"] = {
	canonicalName = "アグナ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["auh"] = {
	canonicalName = "アウシ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aui"] = {
	canonicalName = "アヌキ語",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["auj"] = {
	canonicalName = "アウジラ語",
	otherNames = {"Awjilah", "Awjila"},
	type = "regular",
	scripts = {"None"},
	family = "ber",
}

m["auk"] = {
	canonicalName = "ヘヨ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aul"] = {
	canonicalName = "アウルア語",
	type = "regular",
	scripts = {"None"},
	family = "poz-vnc",
}

m["aum"] = {
	canonicalName = "アス語",
	otherNames = {"Abewa", "Asu (Nigeria)"},
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["aun"] = {
	canonicalName = "Molmo One",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["auo"] = {
	canonicalName = "アウヨカワ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aup"] = {
	canonicalName = "Makayam",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["auq"] = {
	canonicalName = "アヌス語",
	otherNames = {"A", "Korur", "Korurnus"}, -- no name seems to be attested; lect may be the same as 'pdn'
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["aur"] = {
	canonicalName = "アルエク語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["aut"] = {
	canonicalName = "オーストラル語",
	type = "regular",
	scripts = {"None"},
	family = "poz-pol",
}

m["auu"] = {
	canonicalName = "Auye",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["auw"] = {
	canonicalName = "アウイ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aux"] = {
	canonicalName = "Aurá",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["auy"] = {
	canonicalName = "Auyana",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["auz"] = {
	canonicalName = "アラビア語ウズベク方言",
	otherNames = {"Uzbek Arabic"},
	type = "regular",
	scripts = {"None"},
	family = "sem-arb",
}

m["avb"] = {
	canonicalName = "Avau",
	type = "regular",
	scripts = {"None"},
	family = "poz-ocw",
}

m["avd"] = {
	canonicalName = "アルヴィーリ・ヴィダーリ語",
	otherNames = {"Alviri", "Vidari"},
	type = "regular",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["avi"] = {
	canonicalName = "アヴィカム語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["avk"] = {
	canonicalName = "コタヴァ",
	type = "regular",
	scripts = {"None"},
	family = "art",
}

m["avl"] = {
        canonicalName = "アラビア語東部エジプト・ベダウィ方言",
        otherNames = {"Bedawi Arabic", "Levantine Bedawi Arabic"},
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["avm"] = {
	canonicalName = "Angkamuthi", -- sometimes considered a dialect of 'urf'
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["avn"] = {
	canonicalName = "アヴァティメ語",
	type = "regular",
	scripts = {"None"},
	family = "alv-kwa",
}

m["avo"] = {
	canonicalName = "Agavotaguerra",
	type = "regular",
	scripts = {"None"},
	family = "awd",
}

m["avs"] = {
	canonicalName = "アウシリ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-zap",
}

m["avt"] = {
	canonicalName = "アウ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-tor",
}

m["avu"] = {
	canonicalName = "アヴカヤ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["avv"] = {
	canonicalName = "アバ・カノエイロ語",
	otherNames = {"Avá", "Canoe"},
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["awa"] = {
	canonicalName = "アワディー語",
	type = "regular",
	scripts = {"Deva", "Kthi", "fa-Arab"},
	family = "inc",
}

m["awb"] = {
	canonicalName = "アワ語（パプアニューギニア）",
	otherNames = {"Awa", "Awa (Papua New Guinea)"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["awc"] = {
	canonicalName = "Cicipu",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["awe"] = {
	canonicalName = "アウェティ語",
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["awg"] = {
	canonicalName = "Anguthimri",
	otherNames = {"Alngith", "Leningitij", "Mpakwithi"},
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["awh"] = {
	canonicalName = "アウボノ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["awi"] = {
	canonicalName = "Aekyom",
	otherNames = {"Awin"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["awk"] = {
	canonicalName = "アワバカル語",
	type = "regular",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["awm"] = {
	canonicalName = "アラウム語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["awn"] = {
	canonicalName = "アウンギ語",
	type = "regular",
	scripts = {"None"},
	family = "cus",
}

m["awo"] = {
	canonicalName = "アワック語",
	type = "regular",
	scripts = {"None"},
	family = "alv",
}

m["awr"] = {
	canonicalName = "アウェラ語",
	type = "regular",
	scripts = {"None"},
	family = "paa-lkp",
}

m["aws"] = {
	canonicalName = "南アウユ語",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["awt"] = {
	canonicalName = "アラウェテ語",
	type = "regular",
	scripts = {"None"},
	family = "tup",
}

m["awu"] = {
	canonicalName = "中央アウユ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["awv"] = {
	canonicalName = "Jair Awyu",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aww"] = {
	canonicalName = "アウン語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["awx"] = {
	canonicalName = "Awara",
	type = "regular",
	scripts = {"None"},
	family = "ngf-fin",
}

m["awy"] = {
	canonicalName = "Edera Awyu",
	type = "regular",
	scripts = {"None"},
	family = "ngf",
}

m["axb"] = {
	canonicalName = "アビポン語",
	otherNames = {"Abipón", "Callaga", "Kalyaga"},
	type = "regular",
	scripts = {"None"},
	family = "sai-gua",
}

m["axe"] = {
	canonicalName = "Ayerrerenge", -- a variety of Arrernte
	type = "regular",
	scripts = {"None"},
	family = "aus-pam",
}

m["axg"] = {
	canonicalName = "マト・グロッソ・アララ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["axk"] = {
	canonicalName = "アカ語 (中央アフリカ)",
	otherNames = {"Yaka", "Yaka (Central African Republic)", "Aka", "Beka", "Babinga"}, -- distinguish from 'iyx' and 'yaf'
	type = "regular",
	scripts = {"Latn"},
	family = "bnt",
}

m["axl"] = {
	canonicalName = "Lower Southern Aranda",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["axm"] = {
	canonicalName = "中世アルメニア語",
	type = "regular",
	scripts = {"Armn"},
	family = "hyx",
	ancestors = {"xcl"},
	translit_module = "Armn-translit",
	entry_name = {
		from = {"՞", "՜", "՛", "՟", "և"},
		to   = {"", "", "", "", "եւ"}} ,
}

m["axx"] = {
	canonicalName = "Xaragure",
	otherNames = {"Xârâgurè"},
	type = "regular",
	scripts = {"None"},
	family = "poz-cln",
}

m["aya"] = {
	canonicalName = "アワル語",
	type = "regular",
	scripts = {"None"},
	family = "paa",
}

m["ayb"] = {
	canonicalName = "アイゾ・グベ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ayd"] = {
	canonicalName = "アヤバドゥ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aye"] = {
	canonicalName = "アイェレ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ayg"] = {
	canonicalName = "Ginyanga",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ayh"] = {
        canonicalName = "アラビア語ハドラミー方言",
        otherNames = {"Hadhrami Arabic"},
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["ayi"] = {
	canonicalName = "レイガ語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bco",
}

m["ayk"] = {
	canonicalName = "アクク語",
	type = "regular",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ayl"] = {
	canonicalName = "アラビア語リビア方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayn"] = {
        canonicalName = "アラビア語北イエメン方言",
        type = "regular",
        scripts = {"Arab"},
        family = "sem-arb",
        entry_name = {
                from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
                to   = {u(0x0627)}},
}

m["ayo"] = {
	canonicalName = "アヨレオ語",
	type = "regular",
	scripts = {"Latn"},
	family = "qfa-und",
}

m["ayp"] = {
	canonicalName = "アラビア語北メソポタミア方言",
	type = "regular",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ayq"] = {
	canonicalName = "Ayi",
	otherNames = {"Ayi (New Guinea)", "Ayi (Papua New Guinea)"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ays"] = {
	canonicalName = "ソルソゴン・アイタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["ayt"] = {
	canonicalName = "Bataan Ayta",
	otherNames = {"Magbukun Ayta", "Mariveleño"},
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["ayu"] = {
	canonicalName = "アユ語",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["ayy"] = {
	canonicalName = "タヤバス・アイタ語",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["ayz"] = {
	canonicalName = "マイブラット語",
	otherNames = {"アヤマル語", "Maybrat", "Mai Brat", "Ajamaru", "Ayamaru"},
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["aza"] = {
	canonicalName = "Azha",
	type = "regular",
	scripts = {"None"},
	family = "qfa-und",
}

m["azd"] = {
	canonicalName = "東部ドゥランゴ・ナワトル語",
	type = "regular",
	scripts = {"None"},
	family = "azc-nah",
}

m["azg"] = {
	canonicalName = "サン・ペドロ・アムスゴス・アムスゴ語",
	type = "regular",
	scripts = {"None"},
	family = "omq",
}

m["azm"] = {
	canonicalName = "イパラパ・アムスゴ語",
	type = "regular",
	scripts = {"None"},
	family = "omq",
}

m["azn"] = {
	canonicalName = "西部ドゥランゴ・ナワトル語",
	type = "regular",
	scripts = {"None"},
	family = "azc-nah",
}

m["azo"] = {
	canonicalName = "アウィン語",
	type = "regular",
	scripts = {"None"},
	family = "nic-bod",
}

m["azt"] = {
	canonicalName = "Faire Atta",
	type = "regular",
	scripts = {"None"},
	family = "phi",
}

m["azz"] = {
	canonicalName = "高地プエブラ・ナワトル語",
	type = "regular",
	scripts = {"None"},
	family = "azc-nah",
}

return m