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

-- Punctuation to be used for standardChars field
local PUNCTUATION = ' !#$%&*+,-./:;<=>?@^_`|~\'()'

local Latn = {"Latn"}

local m = {}

m["saa"] = {
	"サバ語",
	"Q3914885",
	"cdc-est",
	scripts = Latn,
}

m["sab"] = {
	"ブグレレ語",
	"Q3368506",
	"cba",
	otherNames = {"Bugle", "Murire", "Muoy", "Sabanero", "Bokotá", "Bogota"},
	scripts = Latn,
}

m["sac"] = {
	"メスクワキ語",
	"Q12714767",
	"alg-sfk",
	otherNames = {"Sac", "Sauk", "Kickapoo", "Mesquakie", "Meskwaki"},
	scripts = Latn,
}

m["sad"] = {
	"サンダウェ語",
	"Q34016",
	"qfa-iso",
	scripts = Latn,
}

m["sae"] = {
	"サバネ語",
	"Q3460478",
	"sai-nmk",
	scripts = Latn,
}

m["saf"] = {
	"Safaliba",
	"Q36432",
	"nic-mre",
	scripts = Latn,
}

m["sah"] = {
	"サハ語（ヤクート語）",
	"Q34299",
	"trk-sib",
	otherNames = {"Sakha"},
	scripts = {"Cyrl"},
	translit_module = "sah-translit",
	override_translit = true,
}

m["saj"] = {
	"サフ語",
	"Q7399757",
	"paa",
	scripts = Latn,
}

m["sak"] = {
	"Sake",
	"Q36425",
	"bnt-kel",
	otherNames = {"Shake"},
	scripts = Latn,
}

m["sam"] = {
	"サマリア・アラム語",
	"Q56612",
	"sem-arw",
	otherNames = {"Samaritan"},
	scripts = {"Samr"},
	entry_name = {
		from = {"[" .. u(0x0816) .. "-" .. u(0x082D) .. "]"},
		to = {}
	},
	translit_module = "Samr-translit",
}

m["sao"] = {
	"サウセ語",
	"Q4409155",
	"paa-tkw",
	scripts = Latn,
}

m["saq"] = {
	"サンブル語",
	"Q56536",
	"sdv-lma",
}

m["sar"] = {
	"サラベカ語",
	"Q3450556",
	"awd",
	otherNames = {"Sarabeca", "Saraveka", "Sarave"},
}

m["sas"] = {
	"ササク語",
	"Q1294047",
	"poz-mcm",
	scripts = Latn,
}

m["sat"] = {
	"サンタル語",
	"Q33965",
	"mun",
	scripts = {"Olck"},
	translit_module = "Olck-translit",
	override_translit = true,
}

m["sau"] = {
	"Saleman",
	"Q7404262",
	"poz-cet",
}

m["sav"] = {
	"Saafi-Saafi",
	"Q36308",
	"alv-cng",
	scripts = {"Arab", "Latn"},
}

m["saw"] = {
	"Sawi",
	"Q677064",
	"ngf",
	scripts = Latn,
}

m["sax"] = {
	"サア語",
	"Q3460352",
	"poz-vnc",
	otherNames = {"Saa"},
	scripts = Latn,
}

m["say"] = {
	"Saya",
	"Q3914431",
	"cdc-wst",
	scripts = Latn,
}

m["saz"] = {
	"サウラーシュトラ語",
	"Q13292",
	"inc-wes",
	scripts = {"Saur", "Latn", "Taml", "Deva"},
	translit_module = "saz-translit",
	ancestors = {"inc-ogu"},
}

m["sba"] = {
	"ンガムバイ語",
	"Q2372207",
	"csu-sar",
}

m["sbb"] = {
	"シンボ語",
	"Q3484101",
	"poz-ocw",
}

m["sbc"] = {
	"ケレ語'",
	"Q3194847",
	"poz-oce",
	otherNames = {"Kele (New Guinea)", "Kele (Papua New Guinea)", "Kele"},
}

m["sbd"] = {
	"南部サモ語",
	"Q33122730",
	"dmn-sam",
	scripts = Latn,
}

m["sbe"] = {
	"Saliba (New Guinea)",
	"Q3469737",
	"poz-ocw",
	otherNames = {"Saliba"},
}

m["sbf"] = {
	"シャボ語",
	"Q36342",
	"ssa",
	otherNames = {"Mikeyir", "Mekeyir", "Mekeyer"},
	scripts = Latn,
}

m["sbg"] = {
	"セゲト語",
	"Q7446237",
}

m["sbh"] = {
	"Sori-Harengan",
	"Q36515",
	"poz-aay",
	otherNames = {"Sori", "Harengan"},
	scripts = Latn,
}

m["sbi"] = {
	"セティ語",
	"Q7456682",
	"qfa-tor",
	scripts = Latn,
}

m["sbj"] = {
	"Surbakhal",
	"Q759995",
}

m["sbk"] = {
	"サフワ語",
	"Q4121160",
	"bnt-mby",
	scripts = Latn,
}

m["sbl"] = {
	"ボトラン・サンバル語",
	"Q4095195",
	"phi",
}

m["sbm"] = {
	"サガラ語",
	"Q11732610",
	"bnt-ruv",
	scripts = Latn,
}

m["sbn"] = {
	"Sindhi Bhil",
	"Q25559289",
	"inc-nwe",
	scripts = {"Arab", "Deva", "Sind", "Guru"},
	ancestors = {"sd"},
}

m["sbo"] = {
	"サブム語",
	"Q7396535",
	"mkh-asl",
}

m["sbp"] = {
	"サング語(タンザニア)",
	"Q7418149",
	"bnt-bki",
	scripts = Latn,
}

m["sbq"] = {
	"シレイビ語",
	"Q7514337",
	"ngf-mad",
}

m["sbr"] = {
	"スンバクン・ムルト語",
	"Q7449148",
	"poz-san",
}

m["sbs"] = {
	"スビヤ語",
	"Q6442073",
	"bnt-bot",
	scripts = Latn,
}

m["sbt"] = {
	"Kimki",
	"Q6410160",
	"paa-pau",
}

m["sbu"] = {
	"Stod Bhoti",
	"Q15622700",
	"sit-las",
}

m["sbv"] = {
	"サビヌム語",
	nil,
	"itc",
	scripts = Latn,
}

m["sbw"] = {
	"Simba",
	"Q36430",
	"bnt-tso",
	scripts = Latn,
}

m["sbx"] = {
	"Seberuang",
	"Q12473470",
	"poz-mly",
}

m["sby"] = {
	"ソリ語",
	"Q7557754",
	"bnt-bot",
	scripts = Latn,
}

m["sbz"] = {
	"サラ・カバ語",
	"Q25559318",
	"csu-kab",
	scripts = Latn,
}

m["scb"] = {
	"チュット語",
	"Q2967709",
	"mkh-vie",
}

m["sce"] = {
	"ドンシャン語",
	"Q32947",
	"xgn",
	otherNames = {"Santa"},
	scripts = {"Arab", "Latn"},
}

m["scf"] = {
	"サン・ミゲル・クレオール語",
	"Q12953094",
	"crp",
	ancestors = {"gcf"},
}

m["scg"] = {
	"サンガウ語",
	"Q12473466",
	"day",
}

m["sch"] = {
	"Sakachep",
	"Q37054",
	"tbq-kuk",
	otherNames = {"Khelma"},
}

m["sci"] = {
	"スリランカ・クレオール語",
	"Q1089151",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["sck"] = {
	"サドリ語",
	"Q765922",
	"inc-eas",
	ancestors = {"bh"},
}

m["scl"] = {
	"シナー語",
	"Q1353320",
	"inc-dar",
	otherNames = {"Gilgiti", "Astori", "Chilasi"},
	scripts = {"ur-Arab", "Deva"},
	ancestors = {"inc-dar-pro"},
}

m["scn"] = {
	"シチリア語",
	"Q33973",
	"roa-itd",
	scripts = Latn,
}

m["sco"] = {
	"スコットランド語",
	"Q14549",
	"gmw",
	otherNames = {"Lowland Scots"},
	scripts = Latn,
	ancestors = {"enm"},
}

m["scp"] = {
	"ヨルモ語",
	"Q22662107",
	"sit-kyk",
	otherNames = {"Hyolmo", "Yohlmo", "Helambu Sherpa"},
	scripts = {"Deva"},
}

m["scq"] = {
	"サオチ語",
	"Q6583617",
	"mkh-pea",
	otherNames = {"Chung"},
}

m["scs"] = {
	"北スレーヴィ語",
	"Q20628",
	"ath-nor",
	scripts = Latn,
}

m["scu"] = {
	"Shumcho",
	"Q22077739",
	"sit-kin",
}

m["scv"] = {
	"シェニ語",
	"Q11015820",
	"nic-jer",
	ancestors = {"zir"},
	scripts = Latn,
}

m["scw"] = {
	"シャ語",
	"Q3438816",
	"cdc-wst",
	scripts = Latn,
}

m["scx"] = {
	"シケル語",
	"Q36667",
	"ine",
}

m["sda"] = {
	"トラジャ・サダン語",
	"Q36673",
	"poz-ssw",
}

m["sdb"] = {
	"シャバク語",
	"Q3289596",
	"ira-zgr",
	otherNames = {"Shabaki"},
	ancestors = {"hac"},
}

m["sdc"] = {
	"サッサリ・サルデーニャ語",
	"Q845441",
	"roa-itd",
	scripts = Latn,
}

m["sde"] = {
	"スルブ語",
	"Q3913336",
	"nic-kau",
	scripts = Latn,
}

m["sdf"] = {
	"サルリ語",
	"Q7424256",
	"ira-zgr",
	otherNames = {"Sarliya"},
	ancestors = {"hac"},
}

m["sdg"] = {
	"サヴィ語",
	"Q3474654",
	"inc-dar",
	ancestors = {"inc-dar-pro"},
}

m["sdh"] = {
	"南部クルド語",
	"Q1496597",
	"ku",
	otherNames = {"Kermanshani", "Kermanshahi", "Kermanshahi Kurdish", "Kermanshani Kurdish"},
	scripts = {"ku-Arab", "Latn"},
	translit_module = "sdh-translit",
	link_tr = true,
	entry_name = {
		from = {u(0x0650), u(0x0652)},
		to   = {}} ,
	ancestors = {"ku-pro"},
}

m["sdj"] = {
	"Suundi",
	"Q7650407",
	"bnt-kng",
	scripts = Latn,
}

m["sdk"] = {
	"Sos Kundi",
	"Q7563811",
	"paa-spk",
	scripts = Latn,
}

m["sdl"] = {
	"サウジアラビア手話",
	"Q3504160",
	"sgn",
}

m["sdm"] = {
	"Semandang",
	"Q7449012",
	"day",
}

m["sdn"] = {
	"ガッルーラ・サルデーニャ語",
	"Q612220",
	"roa-itd",
	scripts = Latn,
	ancestors = {"co"},
}

m["sdo"] = {
	"ブカル＝サドン・ビダユ語",
	"Q2927799",
	"day",
}

m["sdp"] = {
	"シェルドゥクペン語",
	"Q7494785",
	"sit-khb",
}

m["sdr"] = {
	"オラオン・サドリ語",
	"Q12953860",
	"inc-eas",
	ancestors = {"bh"},
}

m["sds"] = {
	"セネド語",
	"Q56570",
	"ber",
}

m["sdu"] = {
	"サルドゥ語",
	"Q7424700",
	"poz-cet",
}

m["sdx"] = {
	"Sibu Melanau",
	"Q18642842",
	"poz-bnn",
}

m["sea"] = {
	"セマイ語",
	"Q3135426",
	"mkh-asl",
	scripts = Latn,
}

-- seb is a duplicate code of spp

m["sec"] = {
	"セチェルト語",
	"Q7442898",
	"sal",
	scripts = Latn,
}

m["sed"] = {
	"セダン語",
	"Q56448",
	"mkh-nbn",
}

m["see"] = {
	"セネカ語",
	"Q1185133",
	"iro",
	scripts = Latn,
}

m["sef"] = {
	"Cebaara Senoufo",
	"Q10975121",
	"alv-snr",
}

m["seg"] = {
	"セゲジュ語",
	"Q17584599",
	"bnt-mij",
	scripts = Latn,
}

m["seh"] = {
	"セナ語",
	"Q2964008",
	"bnt-sna",
	varieties = {{"Malawi Sena", "Malawian Sena"}, {"Nuclear Sena", "Mozambican Sena"}}, -- includes [swk] for Malawian Sena, but [bwg] for Barwe is distinct
	scripts = Latn,
}

m["sei"] = {
	"セリ語",
	"Q36583",
	"qfa-iso",
	scripts = Latn,
}

m["sej"] = {
	"セネ語",
	"Q7450252",
}

m["sek"] = {
	"セカニ語",
	"Q28562",
	"ath-nor",
	otherNames = {"Tsek'ene", "Kwadacha", "Kwadacha Sekani", "Kwadacha Tsek'ene"},
	scripts = Latn,
}

m["sel"] = {
	"セリクプ語",
	"Q34008",
	"syd",
	scripts = {"Cyrl"},
}

m["sen"] = {
	"Nanerigé Sénoufo",
	"Q36002",
	"alv-sma",
}

m["seo"] = {
	"Suarmin",
	"Q7630513",
	"paa",
}

m["sep"] = {
	"Sìcìté Sénoufo",
	"Q56787",
	"alv-sma",
}

m["seq"] = {
	"Senara Sénoufo",
	"Q35210",
	"alv-snr",
}

m["ser"] = {
	"セラーノ語",
	"Q3479942",
	"azc-tak",
	otherNames = {"Kitanemuk"},
	scripts = Latn,
}

m["ses"] = {
	"コイラボロ・センニ語",
	"Q35655",
	"son",
	otherNames = {"Koyraboro Senni Songhay", "Koyraboro Senni Songhai", "Koroboro Senni", "Eastern Songhay"},
	scripts = Latn,
}

m["set"] = {
	"センタニ語",
	"Q3441672",
	"paa-sen",
	scripts = Latn,
}

m["seu"] = {
	"セルイ＝ラウト語",
	"Q7455503",
	"poz-hce",
	scripts = Latn,
}

m["sev"] = {
	"ニャロフォロ・セヌフォ語",
	"Q36306",
	"alv-snr",
}

m["sew"] = {
	"Sewa Bay",
	"Q7458126",
	"poz-ocw",
}

m["sey"] = {
	"セコヤ語",
	"Q3477218",
	"sai-tuc",
	scripts = Latn,
}

m["sez"] = {
	"Senthang Chin",
	"Q7451223",
	"tbq-kuk",
	otherNames = {"Senthang"},
}

m["sfb"] = {
	"French Belgian Sign Language",
	"Q3217332",
	"sgn",
}

m["sfm"] = {
	"小花苗語",
	"Q7542773",
	"hmn",
}

m["sfs"] = {
	"南アフリカ手話",
	"Q3322093",
	"sgn",
}

m["sfw"] = {
	"セフウィ語",
	"Q36593",
	"alv-ctn",
	scripts = Latn,
}

m["sga"] = {
	"古アイルランド語",
	"Q35308",
	"cel-gae",
	scripts = Latn,
	ancestors = {"pgl"},
	entry_name = {
		from = {"ḟ", "ṁ", "ṅ", "ṡ", "Ḟ", "Ṁ", "Ṅ", "Ṡ", "ä", "ë", "ï", "ö", "ü", "·"},
		to   = {"f", "m", "n", "s", "F", "M", "N", "S", "a", "e", "i", "o", "u"}} ,
	sort_key = {
		from = {"á", "é", "æ", "ǽ", "í", "ó", "ú", "^h", "-"},
		to   = {"a", "e", "e", "e", "i", "o", "u"}} ,
	standardChars = "A-IL-PR-Ua-il-pr-u0-9ÁáÉéÍíÓóÚú" .. PUNCTUATION,
}

m["sgb"] = {
	"マガンチ・アイタ語",
	"Q4356243",
	"phi",
}

m["sgc"] = {
	"キプシギス語",
	"Q56339",
	"sdv-nma",
}

m["sgd"] = {
	"スリガオノン語",
	"Q34140",
	"phi",
	scripts = Latn,
}

m["sge"] = {
	"セガイ語",
	"Q7446180",
}

m["sgg"] = {
	"Swiss-German Sign Language",
	"Q35150",
	"sgn",
	otherNames = {"Swiss German Sign Language"},
}

m["sgh"] = {
	"シュグニー語",
	"Q34053",
	"ira-shy",
	scripts = {"Latn", "Cyrl"},
	translit_module = "sgh-translit",
	override_translit = true,
	ancestors = {"ira-shr-pro"},
}

m["sgi"] = {
	"スガ語",
	"Q36475",
	"nic-mmb",
	scripts = Latn,
}

m["sgk"] = {
	"サムコン語",
	"Q2945610",
	"tbq-lol",
}

m["sgm"] = {
	"スィンガ語",
	"Q7522797",
	"bnt-lok",
	scripts = Latn,
}

m["sgp"] = {
	"シンフォー語",
	"Q7524158",
	"sit-jnp",
}

m["sgr"] = {
	"サンギーセリー語",
	"Q3394363",
	"ira-kms",
	otherNames = {"Sangsari"},
}

m["sgs"] = {
	"サモギティア語",
	"Q213434",
	"bat",
	scripts = Latn,
	ancestors = {"olt"},
	wikimedia_codes = {"bat-smg"},
}

m["sgt"] = {
	"ドクパケ語",
	"Q56603",
	"sit-tib",
	otherNames = {"Brokpa"},
}

m["sgu"] = {
	"Salas",
	"Q7403694",
	"poz-cma",
}

m["sgw"] = {
	"Sebat Bet Gurage",
	"Q2707343",
	"sem-eth",
	scripts = {"Ethi"},
}

m["sgx"] = {
	"シエラレオネ手話",
	"Q7511448",
	"sgn",
}

m["sgy"] = {
	"サングレーチー語",
	"Q3472220",
	"ira-sgi",
	otherNames = {"Sanglich", "Warduji"},
	ancestors = {"ira-sgi-pro"},
}

m["sgz"] = {
	"Sursurunga",
	"Q36511",
	"poz-ocw",
	scripts = Latn,
}

m["sha"] = {
	"シャル＝ズワル語",
	"Q3915355",
	"nic-beo",
}

m["shb"] = {
	"ニナム語",
	"Q3436586",
}

m["shc"] = {
	"Sonde",
	"Q7560881",
	"bnt-pen",
	scripts = Latn,
}

m["shd"] = {
	"Kundal Shahi",
	"Q6444265",
	"inc-dar",
}

m["she"] = {
	"シェコ語",
	"Q3183355",
	"omv-diz",
}

m["shg"] = {
	"シュア語",
	"Q3501092",
	"khi-kal",
	otherNames = {"Shwa", "Shwakhwe"},
	scripts = Latn,
}

m["shh"] = {
	"ショショニ語",
	"Q33811",
	"azc-num",
	otherNames = {"Shoshoni", "Gosiute", "Goshute", "Eastern Shoshone", "Eastern Shoshoni", "Western Shoshone", "Western Shoshoni", "Northern Shoshone", "Northern Shoshoni"},
	scripts = Latn,
}

m["shi"] = {
	"シルハ語",
	"Q34152",
	"ber",
	otherNames = {"タシュルヒート語", "Chleuh", "Shilha", "Tashlhiyt", "Tashelhit Berber", "Tachelhit Berber", "Tashlhiyt Berber"},
	scripts = {"Tfng", "Arab", "Latn"},
	translit_module = "Tfng-translit",
}

m["shj"] = {
	"シャト語",
	"Q56344",
	"sdv-daj",
}

m["shk"] = {
	"シルク語",
	"Q36486",
	"sdv-lon",
	scripts = Latn,
}

m["shl"] = {
	"Shendu",
	"Q22074616",
	"tbq-kuk",
}

m["shm"] = {
	"シャーフルーディー語",
	"Q7462280",
	"xme-ttc",
	ancestors = {"xme-ttc-cen"},
}

m["shn"] = {
	"シャン語",
	"Q56482",
	"tai-swe",
	otherNames = {"Kwam Tai", "Kam Tai", "Tai Yai"},
	scripts = {"Mymr"},
	translit_module = "shn-translit",
	sort_key = {
		from = {"[ၢႃ]", "ဵ", "ႅ", "ႇ", "ႈ", "း", "ႉ", "ႊ"},
		to   = {"ာ", "ေ", "ႄ", "႒", "႓", "႔", "႕", "႖"}},
}

m["sho"] = {
	"シャンガ語",
	"Q3913931",
	"dmn-bbu",
	scripts = Latn,
}

m["shp"] = {
	"シピーボ＝コミーボ語",
	"Q2671988",
	"sai-pan",
	scripts = Latn,
}

m["shq"] = {
	"サラ語",
	"Q10961665",
	"bnt-bot",
	scripts = Latn,
}

m["shr"] = {
	"シ語",
	"Q3481999",
	"bnt-shh",
	scripts = Latn,
}

m["shs"] = {
	"シュスワプ語",
	"Q3482685",
	"sal",
	scripts = Latn,
}

m["sht"] = {
	"シャスタ語",
	"Q56396",
	"nai-shs",
	scripts = Latn,
}

m["shu"] = {
	"アラビア語チャド方言",
	"Q56497",
	"sem-arb",
	scripts = {"Arab"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["shv"] = {
	"シェフリ語",
	"Q33445",
	"sem-sar",
	aliases = {"Jibbali"},
	scripts = {"Arab", "Latn"},
	ancestors = {"sem-pro"},
}

m["shw"] = {
	"シュワイ語",
	"Q36527",
	"alv-hei",
}

m["shx"] = {
	"シェ語",
	"Q2605689",
	"hmn",
	otherNames = {"Ho Ne", "Ho Nte"},
}

m["shy"] = {
	"タシャウィット語",
	"Q33274",
	"ber",
	otherNames = {"Shawiya Berber", "Chaouïa"},
}

m["shz"] = {
	"シェナラ・セヌフォ語",
	"Q36316",
	"alv-snr",
}

m["sia"] = {
	"アッカラ・サーミ語",
	"Q35241",
	"smi",
	scripts = Latn,
}

m["sib"] = {
	"セボップ語",
	"Q7442799",
	"poz-swa",
	scripts = Latn,
}

m["sid"] = {
	"シダモ語",
	"Q33786",
	"cus",
	aliases = {"Sidaama"},
	scripts = {"Latn", "Ethi"},
}

m["sie"] = {
	"シマー語",
	"Q7517329",
	"bnt-kav",
	scripts = Latn,
}

m["sif"] = {
	"シャム語",
	"Q36252",
}

m["sig"] = {
	"Paasaal",
	"Q36426",
	"nic-sis",
	scripts = Latn,
}

m["sih"] = {
	"Zire",
	"Q8072753",
	"poz-cln",
}

m["sii"] = {
	"ショム・ペン語",
	"Q1039346",
	"aav",
}

m["sij"] = {
	"ヌムバミ語",
	"Q3346277",
	"poz-ocw",
}

m["sik"] = {
	"シキアナ語",
	"Q3443734",
	"sai-car",
	scripts = Latn,
}

m["sil"] = {
	"Tumulung Sisaala",
	"Q25383006",
	"nic-sis",
	scripts = Latn,
}

m["sim"] = {
	"メンデ語",
	"Q7446815",
	"paa-spk",
	otherNames = {"Mende", "Mende (New Guinea)"},
}

m["sip"] = {
	"シッキム語",
	"Q35285",
	"sit-tib",
	aliases = {"Bhutia", "Dranjongke", "Dranjoke", "Denjongka", "Denzongpeke", "Denzongke"},
	scripts = {"Tibt"},
	ancestors = {"xct"},
	translit_module = "bo-translit",
}

m["siq"] = {
	"ソニア語",
	"Q7561770",
}

m["sir"] = {
	"スィリ語",
	"Q3438729",
	"cdc-wst",
	scripts = Latn,
}

m["sis"] = {
	"シウースロー語",
	"Q2315424",
}

m["siu"] = {
	"シナゲン語",
	"Q7521655",
	"qfa-tor",
	scripts = Latn,
}

m["siv"] = {
	"スマリウプ語",
	"Q7636966",
	"paa-spk",
	scripts = Latn,
}

m["siw"] = {
	"シウアイ語",
	"Q7532519",
	"paa-sbo",
}

m["six"] = {
	"スマウ語",
	"Q7637021",
	"ngf-mad",
	otherNames = {"ガリア語", "Sumau", "Garia", "Kari"},
	scripts = Latn,
}

m["siy"] = {
	"シーヴァンド語",
	"Q13269",
	"xme",
	ancestors = {"xme-mid"},
}

m["siz"] = {
	"シウィ語",
	"Q36814",
	"ber",
	scripts = {"Tfng", "Arab", "Latn"},
	otherNames = {"Siwa"},
}

m["sja"] = {
	"エペニャ語",
	"Q3055682",
	"sai-chc",
}

m["sjb"] = {
	"サジャウ・バサプ語",
	"Q4684353",
	"poz-bnn",
}

m["sjd"] = {
	"キルディン・サーミ語",
	"Q33656",
	"smi",
	scripts = {"Cyrl"},
	translit_module = "sjd-translit",
	sort_key = {
		from = {"ӣ", "ӯ", MACRON},
		to   = {"и", "у"} },
}

m["sje"] = {
	"ピーテ・サーミ語",
	"Q56314",
	"smi",
	scripts = Latn,
	entry_name = {
		from = {"ū", "ˈ", MACRON},
		to   = {"u"} },
	sort_key = {
		from = {"á" , "đ" , "ŋ" , "ŧ" },
		to   = {"a²", "d²", "n²", "t²"} },
}

m["sjg"] = {
	"アサンゴリ語",
	"Q3502255",
	"sdv-tmn",
}

m["sjk"] = {
	"ケミ・サーミ語",
	"Q35871",
	"smi",
	scripts = Latn,
}

m["sjl"] = {
	"Miji",
	"Q6845470",
	"sit-hrs",
	otherNames = {"Dmay", "Dhammai", "Sajolang"},
}

m["sjm"] = {
	"マプン語",
	"Q3287253",
	"poz-sbj",
}

m["sjn"] = {
	"シンダール語",
	"Q56437",
	"art",
	type = "appendix-constructed",
	scripts = {"Latn", "Teng"},
}

m["sjo"] = {
	"シベ語",
	"Q13223",
	"tuw",
	otherNames = {"Sibo", "Sibe", "Xibo"},
	scripts = {"Mong"},
}

m["sjp"] = {
	"スルジャプリ語",
	"Q7645351",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["sjr"] = {
	"シアル＝ラク語",
	"Q3482907",
	"poz-ocw",
}

m["sjs"] = {
	"サンハジャ語",
	"Q56744",
	"ber",
}

m["sjt"] = {
	"テル・サーミ語",
	"Q36656",
	"smi",
	scripts = Latn,
}

m["sju"] = {
	"ウーメ・サーミ語",
	"Q56415",
	"smi",
	scripts = Latn,
	entry_name = {
		from = {"ē", "ū", "ǖ", MACRON, "ˈ"},
		to   = {"e", "u", "ü"} },
	sort_key = {
		from = {"á" , "đ" , "ï" , "ŋ" , "ŧ" , "ü" },
		to   = {"a²", "d²", "i²", "n²", "t²", "u²"} },
}

m["sjw"] = {
	"ショーニー語",
	"Q2669206",
	"alg",
	scripts = Latn,
}

m["ska"] = {
	"スカジット語",
	"Q25559652",
	"sal",
	scripts = Latn,
}

m["skb"] = {
	"セック語",
	"Q36437",
	"tai-nor",
	scripts = {"Thai"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎̱̄̂]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["skc"] = {
	"Ma Manda",
	"Q6720783",
	"ngf-fin",
	otherNames = {"Sauk"},
}

m["skd"] = {
	"南部シエラ・ミウォク語",
	"Q3492334",
	"nai-utn",
	scripts = Latn,
}

m["ske"] = {
	"セケ語",
	"Q7534244",
	"poz-vnc",
	otherNames = {"Seke"},
	scripts = Latn,
}

m["skf"] = {
	"Sakirabiá",
	"Q3304806",
	"tup",
	otherNames = {"Mekem", "Amniapé", "Sakïrabiát", "Sakiráp", "Koaratira", "Guaratira", "Kanoé", "Koarategayat", "Guaratégaya", "Guarategaja", "Warategáya"},
	scripts = Latn,
}

m["skh"] = {
	"Sikule",
	"Q3121081",
	"poz-nws",
}

m["ski"] = {
	"シカ語",
	"Q33960",
	"poz-cet",
	otherNames = {"Sikanese"},
	scripts = Latn,
}

m["skj"] = { -- compare 'ths'
	"セケ語",
	"Q30226846",
	"sit-tam",
}

m["skk"] = {
	"Sok",
	"Q12953887",
	"mkh-ban",
}

m["skm"] = {
	"Sakam",
	"Q6448517",
	"ngf-fin",
	otherNames = {"Kutong"},
}

m["skn"] = {
	"コリブガン・スバノン語",
	"Q18755617",
	"phi",
}

m["sko"] = {
	"Seko Tengah",
	"Q15613270",
	"poz",
}

m["skp"] = {
	"セカパン語",
	"Q7447132",
	"poz-bnn",
}

m["skq"] = {
	"Sininkere",
	"Q3914896",
	"dmn-man",
	scripts = Latn,
}

m["skr"] = {
	"サラーイキー語",
	"Q33902",
	"inc-pan",
	otherNames = {"Siraiki", "Seraiki"},
	scripts = {"ur-Arab", "Mult", "Deva"},
	ancestors = {"lah"},
	entry_name = {
		from = {u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652)},
		to   = {}} ,
}

m["sks"] = {
	"マイア語",
	"Q12952760",
	"ngf-mad",
	otherNames = {"Maya", "Banar", "Pila", "Saki", "Suaro", "Turutap", "Yakiba"},
	scripts = Latn,
}

m["skt"] = {
	"サカタ語",
	"Q36691",
	"bnt-bnm",
	otherNames = {"Kisakata", "Lesa", "Odual", "Saka", "Bai", "Kibai", "Bay", "Kibay", "Djia", "Dia", "Dja", "Kidjia", "Wadia", "Tuku", "Ketu", "Batow"},
	scripts = Latn,
}

m["sku"] = {
	"サカオ語",
	"Q3298421",
	"poz-vnc",
	scripts = Latn,
}

m["skv"] = {
	"スコ語",
	"Q3915200",
	"paa-msk",
	otherNames = {"Skou", "Sko"},
	scripts = Latn,
}

m["skw"] = {
	"スキーピ・オランダ語クリオール",
	"Q2522153",
	"crp",
	otherNames = {"Skepi Dutch", "Skepi Dutch Creole", "Essequibo Dutch"},
	ancestors = {"nl"},
}

m["skx"] = {
	"セコ・パダン語",
	"Q15613282",
	"poz-ssw",
}

m["sky"] = {
	"シカイアナ語",
	"Q7439242",
	"poz-pnp",
	otherNames = {"Sikayana"},
	scripts = Latn,
}

m["skz"] = {
	"スカル語",
	"Q7447136",
	"poz-cet",
}

m["slc"] = {
	"サリバ語(コロンビア)",
	"Q3441097",
	otherNames = {"Saliba", "Sáliba", "Saliva", "Sáliva"},
}

m["sld"] = {
	"Sissala",
	"Q11020264",
	"nic-sis",
	scripts = Latn,
}

m["sle"] = {
	"ショラガ語",
	"Q7500203",
	"dra",
	scripts = {"Knda"},
}

m["slf"] = {
	"Swiss-Italian Sign Language",
	"Q12953479",
	"sgn",
	otherNames = {"Swiss Italian Sign Language"},
}

m["slg"] = {
	"セルンガイ・ムルット語",
	"Q7448844",
	"poz-san",
}

m["slh"] = {
	"南部ピュジェット湾セイリッシュ語",
	"Q12642471",
	"sal",
	scripts = Latn,
}

-- "sli" "Silesian German" IS SUBSUMED INTO "gmw-ecg" "East Central German"

m["slj"] = {
	"サルマ語",
	"Q7406296",
	"sai-car",
	scripts = Latn,
}

m["sll"] = {
	"サルト＝ユイ語",
	"Q7405785",
}

m["slm"] = {
	"パングタラン・サマ語",
	"Q3362086",
	"poz-sbj",
}

m["sln"] = {
	"サリナ語",
	"Q1568938",
}

m["slp"] = {
	"ラマホロト語",
	"Q6480777",
	"poz-cet",
	otherNames = {"Solor", "Solorese"},
	scripts = Latn,
}

m["slq"] = {
	"Salchuq",
	"Q56752",
	"trk",
}

m["slr"] = {
	"サラール語",
	"Q33963",
	"trk",
	scripts = {"Arab", "Latn"},
}

m["sls"] = {
	"シンガポール手話",
	"Q7512563",
	"sgn",
}

m["slt"] = {
	"シラ語",
	"Q7514021",
	"tbq-lol",
}

m["slu"] = {
	"セラル語",
	"Q7447500",
	"poz-cet",
}

m["slw"] = {
	"シアルム語",
	"Q7506694",
	"ngf",
}

m["slx"] = {
	"サランパス語",
	"Q7403607",
	"bnt-lun",
	scripts = Latn,
}

m["sly"] = {
	"スラヤール語",
	"Q7447520",
	"poz-ssw",
}

m["slz"] = {
	"Ma'ya",
	"Q2291492",
	"poz-hce",
}

m["sma"] = {
	"南サーミ語",
	"Q13293",
	"smi",
	scripts = Latn,
	sort_key = { -- Standardise on Norwegian orthography for sorting purposes
		from = {"ï" , "ä", "ö"},
		to   = {"i²", "æ", "ø"} },
}

m["smb"] = {
	"シンバリ語",
	"Q7517427",
	"ngf",
}

m["smc"] = {
	"ソム語",
	"Q7559081",
	"ngf-fin",
	scripts = Latn,
}

m["smd"] = {
	"Sama",
	"Q6407456",
	"bnt-kmb",
	scripts = Latn,
}

m["smf"] = {
	"Auwe",
	"Q3502072",
	"paa-brd",
	ancestors = {"dnd"},
}

m["smg"] = {
	"Simbali",
	"Q56692",
	"paa-bng",
}

m["smh"] = {
	"Samei",
	"Q7409269",
	"tbq-lol",
}

m["smj"] = {
	"ルレ・サーミ語",
	"Q56322",
	"smi",
	scripts = Latn,
	entry_name = {
		from = {"ˈ", MACRON},
		to   = {} },
	sort_key = { -- Standardise on Swedish orthography for sorting purposes
		from = {"á" , "ŋ" , "æ" },
		to   = {"a²", "n²", "ä"} },
}

m["smk"] = {
	"ボリナオ語",
	"Q2669235",
	"phi",
	otherNames = {"Binubolinao"},
}

m["sml"] = {
	"中央サマ語",
	"Q3470593",
	"poz-sbj",
}

m["smm"] = {
	"ムササ語",
	"Q6940122",
	"inc-eas",
	ancestors = {"bh"},
}

m["smn"] = {
	"イナリ・サーミ語",
	"Q33462",
	"smi",
	scripts = Latn,
	entry_name = {
		from = {"ḥ", "ḷ", "ṃ", "ṇ", "ṛ", "ṿ", DOTBELOW, "ˈ"},
		to   = {"h", "l", "m", "n", "r", "v"} },
	sort_key = {
		from = {"â" , "č" , "đ" , "ŋ" , "š" , "ž" , "á" },
		to   = {"a˿", "c˿", "d˿", "n˿", "s˿", "z˿", "ä˿"} },
}

m["smp"] = {
	"サマリア語",
	"Q56502",
	"sem-can",
	otherNames = {"Samaritan"},
	scripts = {"Samr"},
	entry_name = {
		from = {"[" .. u(0x0816) .. "-" .. u(0x082D) .. "]"},
		to = {}
	},
}

m["smq"] = {
	"サモ語",
	"Q7409884",
	"ngf",
}

m["smr"] = {
	"シメウル語",
	"Q2992833",
	"poz-nws",
	otherNames = {"Simalur", "Devayan", "Defayan", "Simolol", "Simulul", "Simeuloë"},
	scripts = Latn,
}

m["sms"] = {
	"スコルト・サーミ語",
	"Q13271",
	"smi",
	scripts = Latn,
	entry_name = {
		from = {"ẹ", "ˈ"},
		to   = {"e"} },
	sort_key = {
		from = {"â" , "č" , "đ" , "ǧ" , "ǥ" , "ǩ" , "ŋ" , "õ" , "š" , "ž" },
		to   = {"a²", "c²", "d²", "g²", "g³", "k˿", "n˿", "o˿", "s˿", "z˿"} },
}

m["smt"] = {
	"シムテ語",
	"Q7521268",
	"tbq-kuk",
}

m["smu"] = {
	"Somray",
	"Q6583612",
	"mkh-pea",
}

m["smv"] = {
	"Samvedi",
	"Q6345632",
	"inc-sou",
	ancestors = {"pmh"},
}

m["smw"] = {
	"スンバワ語",
	"Q3182585",
	"poz-mcm",
	scripts = Latn,
}

m["smx"] = {
	"サンバ語",
	"Q11120157",
	"bnt-pen",
	scripts = Latn,
}

m["smy"] = {
	"セムナーニー語",
	"Q14531212",
	"xme",
	ancestors = {"xme-old"},
}

m["smz"] = {
	"Simeku",
	"Q7517534",
	"paa-sbo",
}

m["snb"] = {
	"スブヤウ語",
	"Q7442836",
	"poz-mly",
}

m["snc"] = {
	"シナウゴロ語",
	"Q4170719",
	"poz-ocw",
}

m["sne"] = {
	"バウ・ビダユ語",
	"Q2891938",
	"day",
	scripts = Latn,
}

m["snf"] = {
	"ノーン語",
	"Q36304",
	"alv-cng",
	scripts = Latn,
}

m["sng"] = {
	"サンガ語(コンゴ)",
	"Q3438316",
	"bnt-lub",
	otherNames = {"Sanga", "Luba-Sanga", "Sanga (Democratic Republic of Congo)", "Sanga (Democratic Republic of the Congo)"},
	scripts = Latn,
}

m["sni"] = {
	"Sensi",
	"Q7451029",
	"sai-pan",
	scripts = Latn,
}

m["snj"] = {
	"川岸サンゴ語",
	"Q25559751",
	"crp",
	scripts = Latn,
	ancestors = {"ngb"},
}

m["snk"] = {
	"ソニンケ語",
	"Q36660",
	"dmn-snb",
	scripts = Latn,
}

m["snl"] = {
	"サンギル語",
	"Q3472206",
	"phi",
}

m["snm"] = {
	"南部マディ語",
	"Q15637273",
	"csu-mma",
}

m["snn"] = {
	"シオナ語",
	"Q3485116",
	"sai-tuc",
	scripts = Latn,
}

m["sno"] = {
	"スノホミッシュ語",
	"Q25559662",
	"sal",
	scripts = Latn,
}

m["snp"] = {
	"シアネ語",
	"Q7506812",
	"paa-kag",
	scripts = Latn,
}

m["snq"] = {
	"サング語 (ガボン)",
	"Q36609",
	"bnt-sir",
	otherNames = {"Chango"},
	scripts = Latn,
}

m["snr"] = {
	"シハン語",
	"Q7513400",
	"ngf-mad",
}

m["sns"] = {
	"Nahavaq",
	"Q2160435",
	"poz-vnc",
}

m["snu"] = {
	"センギ語",
	"Q7929052",
	"paa-brd"
}

m["snv"] = {
	"サバン語",
	"Q3474891",
	"poz-swa",
	scripts = Latn,
}

m["snw"] = {
	"Selee",
	"Q36272",
	"alv-ntg",
	scripts = Latn,
}

m["snx"] = {
	"Sam",
	"Q7408387",
}

m["sny"] = {
	"Saniyo-Hiyewe",
	"Q7418302",
	"paa-spk",
	scripts = Latn,
}

m["snz"] = {
	"シンサウル語",
	"Q7525035", -- also "Q4803639"
	"ngf-mad",
	otherNames = {"Kow", "Sinsauru", "Asas"},
	scripts = Latn,
}

m["soa"] = {
	"タイ・ソン語",
	"Q7709159",
	"tai-swe",
	otherNames = {"Lao Song", "Song"},
	scripts = {"Tavt", "Thai"},
	--translit_module = "Tavt-translit",
 	sort_key = {
		from = {"([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])", "([เแโใไ])([ก-ฮ])"},
		to   = {"%2%1", "%2%1"}},
}

m["sob"] = {
	"ソベイ語",
	"Q3121035",
	"poz-ocw",
}

m["soc"] = {
	"Soko",
	"Q7555138",
	"bnt-ske",
	otherNames = {"So"},
	scripts = Latn,
}

m["sod"] = {
	"ソンゴオラ語",
	"Q7561296",
	"bnt-lgb",
	scripts = Latn,
}

m["soe"] = {
	"ソンゴメノ語",
	"Q5713543",
	"bnt-bsh",
	scripts = Latn,
}

m["sog"] = {
	"ソグド語",
	"Q205979",
	"ira-sgc",
	translit_module = "translit-redirect",
	scripts = {"Sogd", "Mani", "Syrc", "Sogo"},
}

m["soh"] = {
	"アカ語(スーダン)",
	"Q3450949",
	"sdv-eje",
	otherNames = {"Aka", "Sillok"},
	scripts = Latn,
}

m["soi"] = {
	"ソンハ語",
	"Q12953890",
	"inc-eas",
	otherNames = {"Sonaha", "Sonahaa", "Sunah", "Sunha"},
	ancestors = {"inc-mgd"},
}

m["sok"] = {
	"ソコロ語",
	"Q3441303",
	"cdc-est",
	scripts = Latn,
}

m["sol"] = {
	"ソロス語",
	"Q3489591",
	"poz-ocw",
}

m["soo"] = {
	"Nsong",
	"Q12953148",
	"bnt-bdz",
	otherNames = {"Songo", "Tsong"},
	scripts = Latn,
}

m["sop"] = {
	"ソンゲ語",
	"Q3130911",
	"bnt-lbn",
	scripts = Latn,
}

m["soq"] = {
	"Kanasi",
	"Q11732656",
}

m["sor"] = {
	"ソムライ語",
	"Q3123566",
	"cdc-est",
	scripts = Latn,
}

m["sos"] = {
	"Seenku",
	"Q36274",
	"dmn-smg",
	otherNames = {"Seeku", "Sembla", "Sambla"},
}

m["sou"] = {
	"南部タイ語",
	"Q56508",
	"tai-swe",
	aliases = {"Dambro", "Pak Tai"},
	scripts = {"Thai"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["sov"] = {
	"ソンソロル語",
	"Q13281",
	"poz-mic",
	scripts = Latn,
}

m["sow"] = {
	"ソワンダ語",
	"Q7571845",
	"paa-brd"
}

m["sox"] = {
	"Swo",
	"Q36604",
	"bnt-mka",
	otherNames = {"So", "Sso", "Shwo", "Fo"},
	scripts = Latn,
}

m["soy"] = {
	"Miyobe",
	"Q35913",
	"alv-sav",
	scripts = Latn,
}

m["soz"] = {
	"Temi",
	"Q13278",
	"bnt-kka",
	scripts = Latn,
}

m["spb"] = {
	"セパ語（インドネシア）",
	"Q18603687",
	"poz-cma",
	otherNames = {"Sepa"},
	scripts = Latn,
}

m["spc"] = {
	"サペ語",
	"Q2888158",
	otherNames = {"Kaliana", "Kariana", "Kaliána", "Sapä́", "Sape"},
	scripts = Latn,
}

m["spd"] = {
	"サエプ語",
	"Q7398312",
	"ngf-mad",
}

m["spe"] = {
	"セパ語（パプアニューギニア）",
	"Q7451725",
	"poz-ocw",
	otherNames = {"Sepa", "Sepa (Papua New Guinea)"},
	scripts = Latn,
}

m["spg"] = {
	"Sian",
	"Q7506806",
	"poz-bnn",
}

m["spi"] = {
	"サポーニ語",
	"Q3915418",
	"paa",
}

m["spk"] = {
	"Sengo",
	"Q7450584",
	"paa-spk",
	scripts = Latn,
}

m["spl"] = {
	"セレペット語",
	"Q7447917",
	"ngf",
}

m["spm"] = {
	"Sepen",
	"Q4701931",
	"paa",
	scripts = Latn,
}

m["spn"] = {
	"サナパナ語",
	"Q3033556",
	"sai-mas",
	scripts = Latn,
}

m["spo"] = {
	"スポケーン語",
	"Q3493704",
	"sal",
	otherNames = {"Montana Salish", "Salish", "Séliš", "Kalispel-Pend d'oreille", "Kalispel"},
}

m["spp"] = {
	"スピレ・セヌフォ語",
	"Q56284",
	"alv-sma",
	otherNames = {"Suppire", "Supyire Senoufo", "Supyire Senufo", "Shempire Senoufo", "Shempire"},
	scripts = Latn,
}

m["spr"] = {
	"サパルア語",
	"Q7420921",
	"poz-cma",
}

m["sps"] = {
	"サポサ語",
	"Q3473187",
	"poz-ocw",
}

m["spt"] = {
	"Spiti Bhoti",
	"Q22080879",
	"sit-las",
}

m["spu"] = {
	"サプアン語",
	"Q7421168",
	"mkh-ban",
}

m["spv"] = {
	"サンバルプーリー語",
	"Q6433240",
	"inc-eas",
	otherNames = {"Kosali", "Koshali"},
	scripts = {"Orya"},
	translit_module = "or-translit",
	ancestors = {"or"},
}

m["spx"] = {
	"南ピケネ語",
	"Q36688",
	"itc",
	otherNames = {"Old Sabellic", "Old Sabellian", "Middle Adriatic", "Central Adriatic"},
	scripts = {"Ital", "Latn"},
	translit_module = "Ital-translit",
}

m["spy"] = {
	"サバオット語",
	"Q7395896",
	"sdv-kln",
}

m["sqa"] = {
	"Shama-Sambuga",
	"Q3914392",
	"nic-kmk",
	scripts = Latn,
}

m["sqh"] = {
	"シャウ語",
	"Q3913925",
	"nic-jer",
	scripts = Latn,
}

m["sqk"] = {
	"アルバニア手話",
	"Q4709168",
	"sgn",
}

m["sqm"] = {
	"スマ語",
	"Q11008431",
	"alv-gbw",
}

m["sqn"] = {
	"サスケハノック語",
	"Q3505736",
	"iro",
}

m["sqo"] = {
	"ソルケイ語",
	"Q3491964",
	"ira-kms",
}

m["sqq"] = {
	"スー語",
	"Q16979751",
	"mkh-ban",
}

m["sqr"] = {
	"アラビア語シークロ方言",
	"Q1069489",
	"sem-arb",
}

m["sqs"] = {
	"スリランカ手話",
	"Q3915466",
	"sgn",
}

m["sqt"] = {
	"ソコトリ語",
	"Q13283",
	"sem-sar",
	aliases = {"Socotri"},
	scripts = {"Arab", "Latn"},
}

m["squ"] = {
	"スクワミッシュ語",
	"Q2484579",
	"sal",
	scripts = Latn,
}

m["sra"] = {
	"サルガ語",
	"Q7424699",
	"ngf-mad",
	scripts = Latn,
}

m["srb"] = {
	"ソーラー語",
	"Q13284",
	"mun",
	scripts = {"Sora"},
}

m["sre"] = {
	"Sara",
	"Q33957",
	"day",
}

m["srf"] = {
	"Nafi",
	"Q6958174",
	"poz-ocw",
}

m["srg"] = {
	"スロッド語",
	"Q7636489",
	"phi",
}

m["srh"] = {
	"サリコーリー語",
	"Q33873",
	"ira-shy",
	scripts = {"Latn", "ug-Arab", "Cyrl"},
	ancestors = {"ira-shr-pro"},
}

m["sri"] = {
	"シリアノ語",
	"Q3485264",
	"sai-tuc",
	scripts = Latn,
}

m["srk"] = {
	"セルドゥン・ムルト語",
	"Q7455497",
	"poz-san",
}

m["srl"] = {
	"イシラワ語",
	"Q4203802",
	"paa-tkw",
}

m["srm"] = {
	"サラマッカン語",
	"Q33779",
	"crp",
	scripts = Latn,
	ancestors = {"en", "pt"},
}

m["srn"] = {
	"スラナン語",
	"Q33989",
	"crp",
	scripts = Latn,
}

m["srq"] = {
	"シリオノ語",
	"Q3027953",
	"tup-gua",
	scripts = Latn,
}

m["srr"] = {
	"セレル語",
	"Q36284",
	"alv-fwo",
	scripts = Latn,
}

m["srs"] = {
	"サーシー語",
	"Q20825",
	"ath-nor",
	otherNames = {"Sarsi", "Tsuu T'ina", "Tsuut'ina", "Tsu T'ina"},
	scripts = Latn,
}

m["srt"] = {
	"Sauri",
	"Q7427547",
	"paa-egb",
}

m["sru"] = {
	"スルイ語",
	"Q7646993",
	"tup",
	otherNames = {"Paíter", "Suruí-Paíter", "Suruí de Rondônia", "Suruí do Jiparaná"},
	scripts = Latn,
}

m["srv"] = {
	"Waray Sorsogon",
	"Q18755610",
	"phi",
}

m["srw"] = {
	"セラ語",
	"Q14916905",
	"poz-cet",
}

m["srx"] = {
	"スルマウリ語",
	"Q7530505",
	"him",
}

m["sry"] = {
	"セラ語",
	"Q7452602",
	"poz-ocw",
	scripts = Latn,
}

m["srz"] = {
	"シャーミルザディ語",
	"Q12953126",
	"ira-msh",
	scripts = {"fa-Arab"},
}

m["ssb"] = {
	"南部サマ語",
	"Q3470594",
	"poz-sbj",
	scripts = Latn,
}

m["ssc"] = {
	"Suba-Simbiti",
	"Q7630687",
	"bnt-lok",
	scripts = Latn,
}

m["ssd"] = {
	"シロイ語",
	"Q10771067",
	"ngf-mad",
	scripts = Latn,
}

m["sse"] = {
	"バランギンギ語",
	"Q2880535",
	"poz-sbj",
	scripts = Latn,
}

m["ssf"] = {
	"サオ語",
	"Q676492",
	"map",
	otherNames = {"Sao"},
	scripts = Latn,
}

m["ssg"] = {
	"セイマト語",
	"Q3182581",
	"poz-aay",
}

m["ssh"] = {
	"アラビア語シフフ方言",
	"Q56571",
	"sem-arb",
	scripts = {"Arab"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ssi"] = {
	"サンシ語",
	"Q3309366",
	"inc-nwe",
	otherNames = {"Bhilki"},
	ancestors = {"psu"},
}

m["ssj"] = {
	"サウシ語",
	"Q7427605",
	"ngf-mad",
	scripts = Latn,
}

m["ssk"] = {
	"Sunam",
	"Q11002210",
	"sit-kin",
}

m["ssl"] = {
	"Western Sisaala",
	"Q11154776",
	"nic-sis",
	scripts = Latn,
}

m["ssm"] = {
	"セムナム語",
	"Q7449713",
	"mkh-asl",
}

m["ssn"] = {
	"ワアタ語",
	"Q3501553",
	"cus",
}

m["sso"] = {
	"シッサノ語",
	"Q7530937",
	"poz-ocw",
	scripts = Latn,
}

m["ssp"] = {
	"スペイン手話",
	"Q3100814",
	"sgn",
}

m["ssq"] = {
	"So'a",
	"Q7572120",
	"poz-cet",
	scripts = Latn,
}

m["ssr"] = {
	"Swiss-French Sign Language",
	"Q12953483",
	"sgn",
	otherNames = {"Swiss French Sign Language"},
}

m["sss"] = {
	"ソー語",
	"Q3082037",
	"mkh-kat",
}

m["sst"] = {
	"シナシナ語",
	"Q7521813",
	"ngf",
	scripts = Latn,
}

m["ssu"] = {
	"Susuami",
	"Q7649752",
	"ngf",
	scripts = Latn,
}

m["ssv"] = {
	"シャーク・ベイ語",
	"Q7489783",
	"poz-vnc",
}

m["ssx"] = {
	"Samberigi",
	"Q7409020",
	"paa-eng",
	scripts = Latn,
}

m["ssy"] = {
	"サホ語",
	"Q36353",
	"cus",
	scripts = {"Latn", "Ethi", "Arab"},
}

m["ssz"] = {
	"Sengseng",
	"Q7450601",
	"poz-ocw",
	scripts = Latn,
}

m["stb"] = {
	"北部スバヌン語",
	"Q12953892",
	"phi",
}

m["std"] = {
	"センチネル語",
	"Q568377",
}

m["ste"] = {
	"Liana-Seti",
	"Q6539924",
	"poz-cma",
}

m["stf"] = {
	"セタ語",
	"Q7456326",
	"qfa-tor",
	scripts = Latn,
}

m["stg"] = {
	"トリエン語",
	"Q22694648",
	"mkh-ban",
}

m["sth"] = {
	"シェルタ語",
	"Q36705",
	"crp",
	otherNames = {"Cant"},
	scripts = Latn,
	ancestors = {"en"},
}

m["sti"] = {
	"ブロ・スティエン語",
	"Q15771431",
	"mkh-ban",
}

m["stj"] = {
	"Matya Samo",
	"Q10974879",
	"dmn-sam",
	scripts = Latn,
}

m["stk"] = {
	"Arammba",
	"Q3502094",
	"ngf",
}

m["stm"] = {
	"セタマン語",
	"Q7456333",
	"ngf-okk",
	scripts = Latn,
}

m["stn"] = {
	"オワ語",
	"Q1324132",
	"poz-sls",
	scripts = Latn,
}

m["sto"] = {
	"ストーニー語",
	"Q3033570",
	"sio-dkt",
}

m["stp"] = {
	"南東テペワン語",
	"Q12953917",
	"azc",
	scripts = Latn,
}

m["stq"] = {
	"ザーターフリジア語",
	"Q27154",
	"gmw-fri",
	otherNames = {"East Frisian", "Eastern Frisian"}, -- Saterland F is a dialect of East F; see [[WT:T:ASTQ]]
	scripts = Latn,
}

m["str"] = {
	"サーニッチ語",
	"Q36444",
	"sal",
	scripts = Latn,
}

m["sts"] = {
	"シュマシュティー語",
	"Q33777",
	"inc-dar",
}

m["stt"] = {
	"ブデー・スティエン語",
	"Q12953891",
	"mkh-ban",
}

m["stu"] = {
	"サムタオ語",
	"Q25559550",
	"mkh-pal",
}

m["stv"] = {
	"スィルティ語",
	nil,
	"sem-eth",
	scripts = {"Ethi"},
}

m["stw"] = {
	"サタワル語",
	"Q28477",
	"poz-mic",
}

m["sty"] = {
	"シベリア・タタール語",
	"Q4418344",
	"trk-kno",
	scripts = {"Cyrl"},
}

m["sua"] = {
	"スルカ語",
	"Q7636341",
	"qfa-iso",
}

m["sub"] = {
	"スク語",
	"Q12953160",
	"bnt-yak",
	scripts = Latn,
}

m["suc"] = {
	"西部スバノン語",
	"Q16113894",
	"phi",
}

m["sue"] = {
	"スエナ語",
	"Q7634386",
	"ngf",
	scripts = Latn,
}

m["sug"] = {
	"Suganga",
	"Q7634706",
	"ngf-okk",
	scripts = Latn,
}

m["sui"] = {
	"スキ語",
	"Q2089984",
	"ngf",
	scripts = Latn,
}

m["suk"] = {
	"スクマ語",
	"Q2638144",
	"bnt-tkm",
	scripts = Latn,
}

m["suq"] = {
	"スリ語",
	"Q5364172",
	"sdv",
}

m["sur"] = {
	"ムワガブル語",
	"Q3440486",
	"cdc-wst",
	otherNames = {"Sura", "Mupun"},
	scripts = Latn,
}

m["sus"] = {
	"スス語",
	"Q33990",
	"dmn-sya",
	scripts = Latn,
}

m["sut"] = {
	"スブティアバ語",
	"Q3915405",
	"omq",
	scripts = Latn,
}

m["suv"] = {
	"Sulung",
	"Q56408",
	"sit-khb",
}

m["suw"] = {
	"スンブワ語",
	"Q7637055",
	"bnt-glb",
	scripts = Latn,
}

m["sux"] = {
	"シュメール語",
	"Q36790",
	"qfa-iso",
	scripts = {"Xsux"},
}

m["suy"] = {
	"スヤ語",
	"Q3505859",
	"sai-nje",
	scripts = Latn,
}

m["suz"] = {
	"スンワル語",
	"Q56549",
	"sit-kiw",
}

m["sva"] = {
	"スヴァン語",
	"Q34067",
	"ccs",
	scripts = {"Geor", "Cyrl"},
	translit_module = "sva-translit",
	override_translit = true,
	entry_name = {
		from = {DIAER, MACRON},
		to   = {}} ,
}

m["svb"] = {
	"ウラウ＝スアイン語",
	"Q7878769",
	"poz-ocw",
	scripts = Latn,
}

m["svc"] = {
	"ヴィンセント英語クリオール",
	"Q3501785",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["sve"] = {
	"Serili",
	"Q7454834",
	"poz-tim",
}

m["svk"] = {
	"スロバキア手話",
	"Q7541557",
	"sgn",
}

m["svm"] = {
	"モリーゼ・クロアチア語",
	"Q36254",
	"zls",
	aliases = {"Slavo-molisano", "Molise Slavic", "Molise Croatian"},
	scripts = Latn,
	ancestors = {"sh"},
}

m["svs"] = {
	"サヴォサヴォ語",
	"Q3130296",
	"paa",
	scripts = Latn,
}

m["svx"] = {
	"スカロヴィア語",
	"Q3486125",
	"bat",
	scripts = Latn,
}

m["swb"] = {
	"コモロ語",
	"Q34075",
	"bnt-com",
	scripts = Latn,
	sort_key = {
		from = {"ɓ", "ɗ"},
		to   = {"bz", "dz"}} ,
}

m["swf"] = {
	"セレ語",
	"Q7453056",
	"nic-ser",
	scripts = Latn,
}

m["swg"] = {
	"シュヴァーベン語",
	"Q327274",
	"gmw",
	scripts = Latn,
	ancestors = {"gsw"},
}

m["swi"] = {
	"水語",
	"Q3112388",
	"qfa-kms",
	otherNames = {"Ai Sui", "Shui", "Sui Li", "Suipo"},
	scripts = {"Latn", "Hani"}, --Shui is not available yet.
}

m["swj"] = {
	"シラ語",
	"Q36599",
	"bnt-sir",
	scripts = Latn,
}

m["swl"] = {
	"スウェーデン手話",
	"Q36558",
	"sgn",
}

m["swm"] = {
	"サモサ語",
	"Q7410037",
	"ngf-mad",
	scripts = Latn,
}

m["swn"] = {
	"ソクナ語",
	"Q2988323",
	"ber",
	otherNames = {"Sawknah", "Fezzan", "Fogaha"},
}

m["swo"] = {
	"Shanenawa",
	nil,
	"sai-pan",
	scripts = Latn,
}

m["swp"] = {
	"スアウ語",
	"Q3502368",
	"poz-ocw",
}

m["swq"] = {
	"シャルワ語",
	"Q56791",
	"cdc-cbm",
	scripts = Latn,
}

m["swr"] = {
	"Saweru",
	"Q3474649",
}

m["sws"] = {
	"Seluwasan",
	"Q7448845",
	"poz-cet",
}

m["swt"] = {
	"サウィラ語",
	"Q7428639",
}

m["swu"] = {
	"スワワ語",
	"Q7650588",
	"phi",
}

m["sww"] = {
	"ソワ語",
	"Q7571843",
	"poz-vnc",
}

m["swx"] = {
	"スルワア語",
	"Q3114402",
	"auf",
	otherNames = {"Zuruahá", "Suruaha", "Suruwaha", "Zuruaha", "Índios do Coxodoá"},
}

m["swy"] = {
	"サルア語",
	"Q56261",
	"cdc-est",
	scripts = Latn,
}

m["sxb"] = {
	"スバ語",
	"Q33916",
	"bnt-lok",
	scripts = Latn,
}

m["sxc"] = {
	"Sicanian",
	"Q36335",
}

m["sxe"] = {
	"Sighu",
	"Q36431",
	"bnt-kel",
	scripts = Latn,
}

m["sxg"] = {
	"シーヒン語",
	"Q56337",
	"sit-nax",
	otherNames = {"Shuhi", "Xumi"},
}

m["sxk"] = {
	"南部カラプヤ語",
	"Q3192122",
	"nai-klp",
}

m["sxl"] = {
	"セロニア語",
	"Q36491",
	"bat",
	otherNames = {"Selian"},
	scripts = Latn,
}

m["sxm"] = {
	"サムレ語",
	"Q6583615",
	"mkh-pea",
}

m["sxn"] = {
	"サンギル語",
	"Q25714758",
	"phi",
	scripts = Latn,
}

m["sxo"] = {
	"Sorothaptic",
	"Q2762254",
}

m["sxr"] = {
	"サアロア語",
	"Q716599",
	"map",
	scripts = Latn,
}

m["sxs"] = {
	"Sasaru",
	"Q3913384",
	"alv-yek",
	scripts = Latn,
}

-- "sxu" "Upper Saxon" IS SUBSUMED INTO "gmw-ecg" "East Central German"

m["sxw"] = {
	"サフェ・グベ語",
	"Q7428892",
	"alv-pph",
}

m["sya"] = {
	"シアン語",
	"Q3482903",
}

m["syb"] = {
	"中部スバヌン語",
	"Q12953893",
	"phi",
	scripts = Latn,
}

m["syc"] = {
	"古典シリア語",
	"Q33538",
	"sem-are",
	scripts = {"Syrc"},
	entry_name = {
		from = {"[" .. u(0x0304) .. u(0x0308) .. u(0x0331) .. u(0x0730) .. "-" .. u(0x0748) .. "]"},
		to   = {},
	},
}

m["syi"] = {
	"セキヤニ語",
	"Q36547",
	"bnt-kel",
	scripts = Latn,
}

m["syk"] = {
	"スクル語",
	"Q56292",
	"cdc-cbm",
	scripts = Latn,
}

m["syl"] = {
	"シレット語",
	"Q2044560",
	"inc-eas",
	scripts = {"Sylo", "Beng"},
	ancestors = {"inc-obn"},
	translit_module = "syl-translit",
}

m["sym"] = {
	"マヤ・サモ語",
	"Q10950421",
	"dmn-sam",
	scripts = Latn,
}

m["syn"] = {
	"セナヤ語",
	"Q33914",
	"sem-nna",
}

m["syo"] = {
	"Suoy",
	"Q7641864",
	"mkh-pea",
}

m["sys"] = {
	"シニャル語",
	"Q56840",
	"csu",
	scripts = Latn,
}

m["syw"] = {
	"カガテ語",
	"Q12952538",
	"sit-kyk",
	scripts = {"Deva"},
}

m["syx"] = {
	"Osamayi",
	"Q7408415",
	"bnt-kel",
	otherNames = {"Shamay", "Samayi", "Samay", "Shamayi"},
	scripts = {"Latn"},
}

m["syy"] = {
	"アル＝サイード・ベドウィン手話",
	"Q2915457",
	"sgn",
}

m["sza"] = {
	"スムライ語",
	"Q3111827",
	"mkh-asl",
}

m["szb"] = {
	"ンガルム語",
	"Q11732516",
	"ngf-okk",
	scripts = Latn,
}

m["szc"] = {
	"スモック・ブリ語",
	"Q7449119",
	"mkh-asl",
}

m["szd"] = {
	"Seru",
	"Q7455488",
	"poz-bnn",
	scripts = Latn,
}

m["sze"] = {
	"セゼ語",
	"Q373683",
	"omv-mao",
	scripts = Latn,
}

m["szg"] = {
	"センゲレ語",
	"Q7450555",
	"bnt-mon",
	scripts = Latn,
}

m["szl"] = {
	"シレジア語",
	"Q30319",
	"zlw-lch",
	otherNames = {"Upper Silesian", "Silesian Polish", "Upper Silesian Polish"},
	scripts = Latn,
}

m["szn"] = {
	"スラ語",
	"Q3503403",
	"poz-cma",
	scripts = Latn,
}

m["szp"] = {
	"スアボ語",
	"Q7630429",
	"ngf-sbh",
	otherNames = {"Inanwatan"},
	scripts = Latn,
}

m["szv"] = {
	"Isubu",
	"Q35431",
	"bnt-saw",
	otherNames = {"Isu", "Isu (Fako Division)", "Isuwu", "Suwu", "Subu"},
	scripts = Latn,
}

m["szw"] = {
	"サワイ語",
	"Q3447258",
	"poz-hce",
	otherNames = {"Weda", "Weda-Sawai", "Kobe", "Faya-Mafa", "Messa-Dote"},
	scripts = Latn,
}

m["szy"] = {
	"サキザヤ語",
	"Q718269",
	"map",
	scripts = Latn,
}

return m