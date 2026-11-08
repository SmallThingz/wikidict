local u = mw.ustring.char

-- UTF-8 encoded strings for some commonly used diacritics
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

m["raa"] = {
	"ドゥンマリ語",
	"Q56871",
	"sit-kic",
}

m["rab"] = {
	"チャムリン語",
	"Q3436664",
	"sit-kic",
	otherNames = {"Chamlinge", "Rodong", "Camling"},
	scripts = {"Deva"},
}

m["rac"] = {
	"Rasawa",
	"Q56443",
	"paa-lkp",
	scripts = Latn,
}

m["rad"] = {
	"ラデ語",
	"Q3429088",
	"cmc",
	otherNames = {"Rhade"},
	scripts = Latn,
}

m["raf"] = {
	"西部メオハン語",
	"Q17442461",
	"sit-kie",
}

m["rag"] = {
	"ロゴーリ語",
	"Q6667767",
	"bnt-lok",
	otherNames = {"Logoli", "Ragoli"},
	scripts = Latn,
}

m["rah"] = {
	"ラバー語",
	"Q7278686",
	"tbq-bdg",
	otherNames = {"Maituri", "Rongdani", "Rava"},
	scripts = {"Beng", "Latn"},
}

m["rai"] = {
	"Ramoaaina",
	"Q3418509",
	"poz-ocw",
	otherNames = {"Ramoaina", "Ramuaaina", "Ramuaina", "Duke of York", "Aalawa", "Aalawaa", "Alawa", "Mioko"},
	scripts = Latn,
}

m["raj"] = {
	"ラージャスターン語",
	"Q13196",
	"inc-wes",
	scripts = {"Deva"},
	ancestors = {"inc-ogu"},
}

m["rak"] = {
	"Tulu-Bohuai",
	"Q2908807",
	"poz-aay",
	otherNames = {"Tulu", "Bohuai"},
	scripts = Latn,
}

m["ral"] = {
	"ラルテ語",
	"Q7288392",
	"tbq-kuk",
	scripts = Latn,
}

m["ram"] = {
	"カネラ語",
	"Q2936334",
	"sai-nje",
	otherNames = {"Krahô", "Canela-Krahô"},
	scripts = Latn,
}

m["ran"] = {
	"リアンタナ語",
	"Q7322169",
	"ngf",
	otherNames = {"Kimaam"},
	scripts = Latn,
}

m["rao"] = {
	"ラオ語",
	"Q11732596",
	"paa",
	scripts = Latn,
}

m["rap"] = {
	"ラパヌイ語",
	"Q36746",
	"poz-pep",
	otherNames = {"Rapanui", "Pascuense"},
	scripts = Latn,
}

m["raq"] = {
	"サーム語",
	"Q7395644",
	"sit-kic",
}

m["rar"] = {
	"ラロトンガ語",
	"Q36745",
	"poz-pep",
	otherNames = {"Cook Islands Maori", "Cook Islands Māori"},
	scripts = Latn,
}

m["ras"] = {
	"テガリ語",
	"Q36522",
	"nic-ras",
	otherNames = {"Tingal", "Tagale", "Tegele", "Tekele", "Togole", "Rashad", "Gom", "Kom"},
	scripts = Latn,
}

m["rat"] = {
	"ラザジェルディ語",
	"Q7299461",
	"xme-ttc",
	ancestors = {"xme-ttc-eas"},
}

m["rau"] = {
	"ラウテ語",
	"Q7296262",
	"sit-gma",
	scripts = {"Deva", "Latn"},
}

m["rav"] = {
	"サンパン語",
	"Q3449115",
	"sit-kic",
}

m["raw"] = {
	"ラワン語",
	"Q542564",
	"sit-nng",
	scripts = Latn,
	sort_key = {
		from = {"[áāà]", "[éēè]", "[íīì]", "[óōò]", "[úūù]", "ǿ", GRAVE, MACRON, ACUTE},
		to   = {"a", "e", "i", "o", "u", "ø"}},
}

m["rax"] = {
	"ラン語",
	"Q3913345",
	"alv-mum",
}

m["ray"] = {
	"Rapa",
	"Q36417",
	"poz-pep",
}

m["raz"] = {
	"Rahambuu",
	"Q3417555",
	"poz-btk",
}

m["rbb"] = {
	"ルーマイ・パラウン語",
	"Q12953797",
	"mkh-pal",
}

m["rbk"] = {
	"北部ボントク語",
	nil,
	"phi",
	otherNames = {"Northern Bontok"},
}

m["rbl"] = {
	"Miraya Bikol",
	"Q18664557",
	"phi",
}

m["rcf"] = {
	"レユニオン・クレオール語",
	"Q13198",
	"crp",
	scripts = Latn,
	ancestors = {"fr"},
}

m["rdb"] = {
	"ルードバル語",
	"Q12953072",
	"xme",
	ancestors = {"xme-mid"},
}

m["rea"] = {
	"レラウ語",
	"Q7314883",
	"ngf-mad",
}

m["reb"] = {
	"レムボング語",
	"Q7311570",
	"poz-cet",
}

m["ree"] = {
	"ルジャン・カヤン語",
	"Q3423957",
	"poz",
	otherNames = {"Lisum", "Ma'aging", "Long Badan", "Uma Daro", "Long Kehobo", "Uma Poh", "Uma Juman", "Long Murun", "Long Geng", "Lemena"},
}

m["reg"] = {
	"カラ語",
	"Q6367567",
	"bnt-haj",
}

m["rei"] = {
	"レリ語",
	"Q7310982",
}

m["rej"] = {
	"レジャン語",
	"Q3056339",
	"poz-sus",
	otherNames = {"Rejangese"},
	scripts = {"Rjng"},
}

m["rel"] = {
	"レンディーレ語",
	"Q3447297",
	"cus",
}

m["rem"] = {
	"レモ語",
	"Q3501825",
	"sai-pan",
	scripts = Latn,
}

m["ren"] = {
	"レガオ語",
	"Q6583692",
	"mkh",
}

m["rer"] = {
	"Rer Bare",
	"Q12953857",
}

m["res"] = {
	"レシェ語",
	"Q36258",
	"nic-knj",
}

m["ret"] = {
	"Retta",
	"Q7317113",
	"ngf",
	otherNames = {"Reta"},
}

m["rey"] = {
	"レイェサノ語",
	"Q3111857",
	"sai-tac",
	scripts = Latn,
}

m["rga"] = {
	"ロリア語",
	"Q7366825",
	"poz-vnc",
}

m["rge"] = {
	"Romani Greek",
	"Q3915435",
	otherNames = {"Romano-Greek", "Hellenoromani"},
}

m["rgk"] = {
	"ランカス語",
	"Q7292645",
	"sit-alm",
}

m["rgn"] = {
	"ロマーニャ語",
	"Q1641543",
	"roa-git",
	otherNames = {"Romagnolo"},
	scripts = Latn,
	wikimedia_codes = {"eml"},
}

m["rgr"] = {
	"レシガロ語",
	"Q3450504",
	"awd",
	scripts = Latn,
}

m["rgs"] = {
	"南部ログライ語",
	"Q12953069",
}

m["rgu"] = {
	"Ringgou",
	"Q7334886",
	"poz-tim",
}

m["rhg"] = {
	"ロヒンギャ語",
	"Q3241177",
	"inc-eas",
	scripts = {"Arab", "Rohg", "Mymr", "Latn", "Beng"},
	ancestors = {"inc-mgd"},
	translit_module = "translit-redirect",
}

m["rhp"] = {
	"ヤハン語",
	"Q8046792",
	"qfa-tor",
}

m["ria"] = {
	"リアン語(インド)",
	"Q12953063",
	"tbq-bdg",
	otherNames = {"Riang"},
}

m["rif"] = {
	"リーフ語",
	"Q34174",
	"ber",
	otherNames = {"Rifain"},
	scripts = {"Tfng", "Arab", "Latn"},
}

m["ril"] = {
	"リアン語(ミャンマー)",
	"Q2741615",
	"mkh-pal",
}

m["rim"] = {
	"ニャトゥル語",
	"Q7193418",
	"bnt-tkm",
	scripts = Latn,
}

m["rin"] = {
	"ヌング語",
	"Q3913350",
	"nic-nin",
	scripts = Latn,
}

m["rir"] = {
	"リブン語",
	"Q7322443",
	"day",
	scripts = Latn,
}

m["rit"] = {
	"Ritarungo",
	"Q7336730",
	"aus-yol",
	otherNames = {"Ritharrŋu", "Ritharngu"},
	scripts = Latn,
}

m["riu"] = {
	"リウン語",
	"Q7336938",
	"poz-cet",
	scripts = Latn,
}

m["rjg"] = {
	"Rajong",
	"Q7286370",
	"poz-cet",
	scripts = Latn,
}

m["rji"] = {
	"ラジ語",
	"Q7286138",
	"sit-gma",
}

m["rjs"] = {
	"ラズボンシ語",
	"Q12640969",
	"inc-eas",
	scripts = {"Deva", "as-Beng"},
	ancestors = {"inc-mgd"},
}

m["rka"] = {
	"Kraol",
	"Q3199593",
	"mkh-ban",
	scripts = {"Khmr"}, -- also Latn?
}

m["rkb"] = {
	"リクバクツァ語",
	"Q2585357",
	"sai-mje",
	otherNames = {"Erikbatsa", "Aripaktsa", "Erikpatsa"},
	scripts = Latn,
}

m["rkh"] = {
	"ラカハガ・マニヒキ語",
	"Q3119695",
	"poz-pep",
	scripts = Latn,
}

m["rki"] = {
	"ラカイン語",
	"Q3450749",
	"tbq-brm",
	otherNames = {"Arakanese", "Ramree", "Yangbye", "Thandwe", "Chaungtha"},
	scripts = {"Mymr"},
	ancestors = {"obr"},
}

m["rkm"] = {
	"Marka",
	"Q36030",
	"dmn-wmn",
	scripts = Latn,
}

m["rkt"] = {
	"ランプリ語",
	"Q3241618",
	"inc-eas",
	otherNames = {"Rangpuri"},
	scripts = {"as-Beng"},
	ancestors = {"inc-ork"},
	translit_module = "as-translit",
}

m["rkw"] = {
	"Arakwal",
	"Q34295800",
	"aus-pam",
	scripts = Latn,
}

m["rma"] = {
	"ラマ語",
	"Q3444486",
	"cba",
}

m["rmb"] = {
	"レンバルンガ語",
	"Q7311553",
	"aus-gun",
	scripts = Latn,
}

m["rmc"] = {
	"カルパティア・ロマーニー語",
	"Q5045611",
	"inc-rom",
}

m["rmd"] = {
	"Traveller Danish",
	"Q12640779",
	"inc-rom",
}

m["rme"] = {
	"アングロ・ロマ語",
	"Q541279",
	"crp",
	scripts = Latn,
	ancestors = {"en", "rom"},
}

m["rmf"] = {
	"カロ・フィンランド・ロマ語",
	"Q2093214",
	"inc-rom",
}

m["rmg"] = {
	"Traveller Norwegian",
	"Q3177352",
	"inc-rom",
}

m["rmh"] = {
	"Murkim",
	"Q4308074",
	"paa-pau",
}

m["rmi"] = {
	"ロマヴレン語",
	"Q2495696",
	"qfa-mix",
	ancestors = {"psu", "hy"},
	scripts = {"Latn", "Armn"},
	translit_module = "translit-redirect",
	override_translit = true,
}

m["rmk"] = {
	"ロムクン語",
	"Q7363236",
	"paa",
	scripts = Latn,
}

m["rml"] = {
	"バルト・ロマーニー語",
	"Q513736",
	"inc-rom",
}

m["rmm"] = {
	"Roma",
	"Q4414831",
}

m["rmn"] = {
	"バルカン・ロマーニー語",
	"Q1256701",
	"inc-rom",
}

m["rmo"] = {
	"シンティ・ロマーニー語",
	"Q1793299",
	"qfa-mix",
	otherNames = {"Sinti Romani", "Sinti-Manouche", "Sinti"},
	scripts = Latn,
	ancestors = {"rom"},
}

m["rmp"] = {
	"レンピ語",
	"Q7312214",
	"ngf-mad",
}

m["rmq"] = {
	"カロ語",
	"Q35466",
	"qfa-mix",
	scripts = Latn,
	ancestors = {"rom", "la"},
}

m["rms"] = {
	"ルーマニア手話",
	"Q7362575",
	"sgn",
}

m["rmt"] = {
	"ドマーリー語",
	"Q35394",
	"inc-cen",
	ancestors = {"psu"},
}

m["rmu"] = {
	"Tavringer Romani",
	"Q27808413",
	"inc-rom",
}

m["rmv"] = {
	"ロマノヴァ",
	"Q1298715",
	"art",
	type = "appendix-constructed",
}

m["rmw"] = {
	"ウェールズ・ロマ語",
	"Q2097387",
	"inc-rom",
	otherNames = {"Welsh Romany", "Kååle"},
}

m["rmx"] = {
	"ロマム語",
	"Q22694600",
	"mkh",
}

m["rmy"] = {
	"ヴラックス・ロマーニー語",
	"Q2669199",
	"inc-rom",
}

m["rmz"] = {
	"マルマ語",
	"Q21403256",
	"tbq-brm",
	ancestors = {"obr"},
	scripts = {"Mymr"},
}

m["rnd"] = {
	"ルウンダ語",
	"Q7383564",
	"bnt-lun",
	aliases = {"Ruund", "Northern Lunda", "Uruund"},
}

m["rng"] = {
	"ロンガ語",
	"Q2520717",
	"bnt-tsr",
	otherNames = {"Xironga"},
	scripts = Latn,
}

m["rnl"] = {
	"Ranglong",
	"Q7292878",
}

m["rnn"] = {
	"Roon",
	"Q7366335",
	"poz-hce",
}

m["rnp"] = {
	"Rongpo",
	"Q7365672",
	"sit-whm",
}

m["rnw"] = {
	"ルングワ語",
	"Q7379873",
	"bnt-mwi",
	scripts = Latn,
}

m["rob"] = {
	"タエ語",
	"Q12473476",
	"poz-ssw",
	scripts = Latn,
}

m["roc"] = {
	"Cacgia Roglai",
	"Q2932485",
}

m["rod"] = {
	"ロゴ語",
	"Q3914894",
	"nic-kmk",
}

m["roe"] = {
	"Ronji",
	"Q3441763",
	"poz-ocw",
}

m["rof"] = {
	"ロンボ語 (タンザニア)",
	otherNames = "Rombo",
	"Q33330",
	"bnt-chg",
	scripts = Latn,
}

m["rog"] = {
	"北部ログライ語",
	"Q3439680",
	"cmc",
	scripts = Latn,
}

m["rol"] = {
	"ロンブロマノン語",
	"Q13202",
	"phi",
}

m["rom"] = {
	"ロマ語",
	"Q13201",
	"inc-rom",
	otherNames = {"Gypsy"},
	scripts = {"Latn", "Cyrl"},
	ancestors = {"psu"},
}

m["roo"] = {
	"ロトカス語",
	"Q13203",
	"paa-nbo",
	scripts = Latn,
}

m["rop"] = {
	"オーストラリア・クリオル語",
	"Q35671",
	"crp",
	otherNames = {"Australian Kriol"},
	scripts = Latn,
	ancestors = {"en"},
}

m["ror"] = {
	"Rongga",
	"Q12473464",
}

m["rou"] = {
	"ルンガ語",
	"Q56793",
}

m["row"] = {
	"Dela-Oenale",
	"Q5253046",
	"poz-tim",
}

m["rpn"] = {
	"レパンビティプ語",
	"Q7313900",
	"poz-vnc",
}

m["rpt"] = {
	"ラプティン語",
	"Q7294362",
	"ngf-mad",
}

m["rri"] = {
	"リリオ語",
	"Q2404190",
	"poz-ocw",
}

m["rro"] = {
	"ワイマ語",
	"Q34197",
	"poz-ocw",
	scripts = Latn,
}

m["rrt"] = {
	"Arritinngithigh",
	"Q4796002",
	scripts = Latn,
}

m["rsb"] = {
	"Romano-Serbian",
	"Q1268244",
}

m["rsk"] = {
	"パンノニア・ルシン語",
	35660,
	"zlw",
	"Cyrl",
	ancestors = "zlw-osk",
	translit = "rsk-translit",
}

m["rsl"] = {
	"ロシア手話",
	"Q13210",
	"sgn",
}

m["rsm"] = {
	"Miriwoong Sign Language",
	"Q24090240",
	"sgn",
}

m["rtc"] = {
	"Rungtu",
	"Q7379867",
	"tbq-kuk",
	otherNames = {"Rungtu Chin", "Thaungtha"},
}

m["rth"] = {
	"ラタハン語",
	"Q3420026",
	"phi",
	scripts = Latn,
}

m["rtm"] = {
	"ロトゥマ語",
	"Q36754",
	"poz-occ",
	scripts = Latn,
}

m["rtw"] = {
	"ラタウィ語",
	"Q12953854",
	"inc-bhi",
}

m["rub"] = {
	"グング語",
	"Q11165235",
	"bnt-glb",
}

m["ruc"] = {
	"Ruuli",
	"Q7383562",
	"bnt-nyg",
}

m["rue"] = {
	"ルシン語",
	"Q26245",
	"zle",
	scripts = {"Cyrl"},
	ancestors = {"orv"},
	translit_module = "rue-translit",
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["ruf"] = {
	"ルグル語",
	"Q3437661",
	"bnt-ruv",
	scripts = Latn,
}

m["rug"] = {
	"ロヴィアナ語",
	"Q3445546",
	"poz-ocw",
	scripts = Latn,
}

m["ruh"] = {
	"Ruga",
	"Q7378127",
}

m["rui"] = {
	"ルフィジ語",
	"Q7377946",
	"bnt-mbi",
}

m["ruk"] = {
	"チェ語",
	"Q3915445",
	"nic-nin",
}

m["ruo"] = {
	"イストロ・ルーマニア語",
	"Q33622",
	"roa-eas",
	scripts = Latn,
}

m["rup"] = {
	"アルーマニア語",
	"Q29316",
	"roa-eas",
	scripts = Latn,
	wikimedia_codes = {"roa-rup"},
}

m["ruq"] = {
	"メグレノ・ルーマニア語",
	"Q13358",
	"roa-eas",
	scripts = Latn,
}

m["rut"] = {
	"ルトゥル語",
	"Q36757",
	"cau-lzg",
	scripts = {"Cyrl"},
}

m["ruu"] = {
	"Lanas Lobu",
	"Q12953676",
}

m["ruy"] = {
	"マラ語(ナイジェリア)",
	"Q3913381",
	"nic-kau",
	otherNames = {"Mala"},
}

m["ruz"] = {
	"Ruma",
	"Q3913326",
	"nic-kau",
}

m["rwa"] = {
	"ラウォ語",
	"Q3504269",
}

m["rwk"] = {
	"Rwa",
	"Q7985624",
	"bnt-chg",
}

m["rwm"] = {
	"アンバ語",
	"Q788423",
	"bnt-kbi",
	scripts = Latn,
}

m["rwo"] = {
	"ラワ語",
	"Q11732598",
	"ngf-fin",
	scripts = Latn,
}

m["rxd"] = {
	"Ngardi",
	"Q7022063",
}

m["rxw"] = {
	"Karuwali",
	"Q6881575",
}

m["ryn"] = {
	"北奄美大島語",
	"Q2840988",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["rys"] = {
	"八重山語",
	"Q34203",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["ryu"] = {
	"沖縄語",
	"Q34233",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["rzh"] = {
	"ラジフ語",
	"Q16911222",
	"sem-osa",
	otherNames = {"Rāziḥī", "Jabal Razih"},
	scripts = {"Arab"},
	ancestors = {"sem-srb"},
}

return m