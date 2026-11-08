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

m["xaa"] = {
	"アル・アンダルス＝アラビア語",
	"Q1137945",
	"sem-arb",
	otherNames = {"Andalusi Arabic", "Moorish Arabic", "Spanish Arabic"},
	scripts = {"Arab", "Latn"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["xab"] = {
	"Sambe",
	"Q36265",
	"nic-alu",
	scripts = Latn,
}

m["xac"] = {
	"カチャリ語",
	"Q3442442",
	"tbq-bdg",
}

m["xad"] = {
	"アダイ語",
	"Q346744",
}

m["xae"] = {
	"アエクウィ語",
	"Q930579",
	"itc",
}

m["xag"] = {
	"Aghwan",
	"Q34931",
	"cau-lzg",
	otherNames = {"Caucasian Albanian", "Old Udi"},
	scripts = {"Aghb"},
	translit_module = "Aghb-translit",
	override_translit = true,
}

m["xai"] = {
	"Kaimbé",
	"Q6348017",
}

m["xaj"] = {
	"Ararandewára",
	nil,
	"tup-gua",
	scripts = Latn,
}

m["xak"] = {
	"Maku",
	"Q2032882",
	otherNames = {"Mako", "Máku", "Mácu", "Macú", "Macu", "Máko", "Maku-Auari"},
	scripts = Latn,
}

m["xal"] = {
	"カルムイク語",
	"Q33634",
	"xgn",
	otherNames = {"Oirat", "Modern Oirat"},
	scripts = {"Cyrl"},
	ancestors = {"xwo"},
	translit_module = "xal-translit",
	override_translit = true,
}

m["xam"] = {
	"ハム語",
	"Q2086145",
	"khi-tuu",
	otherNames = {"ǀKham"},
	scripts = Latn,
}

m["xan"] = {
	"ハンタンガ語",
	"Q56527",
	"cus",
}

m["xao"] = {
	"カーオ語",
	"Q3196077",
	"mkh-pal",
}

m["xap"] = {
	"アパラチー語",
	"Q686501",
	"nai-mus",
	scripts = Latn,
}

m["xaq"] = {
	"アクィーターニア語",
	"Q500522",
	"euq",
	scripts = Latn,
}

m["xar"] = {
	"カラミ語",
	"Q11732281",
}

m["xas"] = {
	"カマス語",
	"Q35991",
	"syd",
	scripts = {"Cyrl"},
}

m["xat"] = {
	"カタウィシ語",
	"Q3440512",
	"sai-ktk",
}

m["xau"] = {
	"Kauwera",
	"Q6378983",
	"paa-tkw",
}

m["xav"] = {
	"シャヴァンテ語",
	"Q36962",
	"sai-cje",
	scripts = Latn,
}

m["xaw"] = {
	"カワイイス語",
	"Q56338",
	"azc-num",
	scripts = Latn,
}

m["xay"] = {
	"カヤン・マハカム語",
	"Q25337171",
}

m["xbb"] = {
	"低地バーデキン語",
	"Q6693353",
}

m["xbc"] = {
	"バクトリア語",
	"Q756651",
	"ira-sbc",
	otherNames = {"Greco-Bactrian", "Kushan", "Kushano-Bactrian"},
	scripts = {"Grek", "Mani"},
	entry_name = {
		from = {"Þ", "þ"},
		to   = {"Ϸ", "ϸ"}},
	translit_module = "xbc-translit",
}

m["xbd"] = {
	"Bindal",
	"Q4913975",
}

m["xbe"] = {
	"Bigambal",
	"Q16841801",
	"aus-pam", --unclassified within
}

m["xbg"] = {
	"Bunganditj",
	"Q4997615",
}

m["xbi"] = {
	"コンビオ語",
	"Q6428259",
	"qfa-tor",
	scripts = Latn,
}

m["xbj"] = {
	"Birrpayi",
	nil,
}

m["xbm"] = {
	"中期ブルトン語",
	"Q787610",
	"cel-bry",
	scripts = Latn,
	ancestors = {"obt"},
}

m["xbn"] = {
	"Kenaboi",
	"Q6388752",
}

m["xbo"] = {
	"ブルガール語",
	"Q36880",
	"trk-ogr",
	otherNames = {"Bolğar", "Bulghar", "Bolghar", "Bolgarian", "Bolgar"},
	scripts = {"Grek"},
}

m["xbp"] = {
	"ビバルマン語",
	"Q22918391",
}

m["xbr"] = {
	"カンベラ語",
	"Q3053279",
	"poz-cet",
	otherNames = {"East Sumbanese", "Sumbanese"},
	scripts = Latn,
}

m["xbw"] = {
	"カンビワ語",
	"Q9006744",
}

m["xby"] = {
	"Butchulla",
	"Q31752631",
	otherNames = {"Badjala"}, -- contrast gbw
}

m["xcb"] = {
	"カンブリア語",
	"Q35965",
	"cel-bry",
}

m["xcc"] = {
	"Camunic",
	"Q489011",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["xce"] = {
	"ケルティベリア語",
	"Q37012",
	"cel",
	scripts = Latn,
}

m["xch"] = {
	"チェマクム語",
	"Q56397",
	"chi",
	scripts = Latn,
}

m["xcl"] = {
	"古典アルメニア語",
	"Q181074",
	"hyx",
	otherNames = {"Classical Armenian", "Liturgical Armenian", "Grabar"},
	scripts = {"Armn"},
	translit_module = "Armn-translit",
	override_translit = true,
	entry_name = {
		from = {"՞", "՜", "՛", "՟", "և"},
		to   = {"", "", "", "", "եւ"}} ,
}

m["xcm"] = {
	"コメクルド語",
	"Q609808",
	"nai-pak",
}

m["xcn"] = {
	"コトナメ語",
	"Q56889",
	"nai-pak",
}

m["xco"] = {
	"ホラズム語",
	"Q33138",
	"ira-sbc",
	otherNames = {"Chorasmian","Khwarazmian","Khorezmian"},
	scripts = {"Arab","Armi","Chrs","Phlv","Sogd"},
	translit_module = "Chrs-translit",
}

m["xcr"] = {
	"カリア語",
	"Q35929",
	"ine-ana",
	scripts = {"Cari"},
}

m["xct"] = {
	"古典チベット語",
	"Q5128314",
	"sit-tib",
}

m["xcu"] = {
	"クロニア語",
	"Q35857",
	"bat",
	scripts = Latn,
}

m["xcv"] = {
	"Chuvantsy",
	"Q3516641",
	"qfa-yuk",
	otherNames = {"Chuvan", "Chuvansky"},
	scripts = Cyrl,
}

m["xcw"] = {
	"コアウィルテコ語",
	"Q2008062",
	"nai-pak",
}

m["xcy"] = {
	"カイユース語",
	"Q2472016",
}

m["xda"] = {
	"ダルキニュング語",
	"Q5223660",
	"aus-yuk",
	scripts = Latn,
}

m["xdc"] = {
	"ダキア語",
	"Q682547",
	"ine",
	scripts = Latn,
}

m["xdk"] = {
	"ダルク語",
	"Q1166814",
	"aus-yuk",
	otherNames = {"Darug", "Dharruk", "Dharuk", "Eora", "Iora", "Iyora", "Sydney"},
	scripts = Latn,
}

m["xdm"] = {
	"エドム語",
	"Q2363529",
	"sem-can",
	scripts = {"Phnx"},
	translit_module = "Phnx-translit",
}

m["xdy"] = {
	"マレー・ダヤク語",
	"Q3514892",
}

m["xeb"] = {
	"エブラ語",
	"Q35345",
	"sem-eas",
	scripts = {"Xsux"},
}

m["xed"] = {
	"フディ語",
	"Q56246",
	"cdc-cbm",
	scripts = Latn,
}

m["xeg"] = {
	"ヘグイ語",
	"Q3509732",
	"khi-tuu",
	scripts = Latn,
}

m["xel"] = {
	"ケロ語",
	"Q6386412",
	"sdv-eje",
}

m["xem"] = {
	"クンバヤン語",
	"Q6386874",
}

m["xep"] = {
	"エピ・オルメカ語",
	nil,
}

m["xer"] = {
	"シェレンテ語",
	"Q3073436",
	"sai-cje",
	otherNames = {"Koromu", "Cherente", "Sherenté"},
	scripts = Latn,
}

m["xes"] = {
	"ケサワイ語",
	"Q6394907",
	"ngf-mad",
	otherNames = {"Koromu"},
	scripts = Latn,
}

m["xet"] = {
	"シェタ語",
	"Q2980404",
	"tup-gua",
	scripts = Latn,
}

m["xeu"] = {
	"Keoru-Ahia",
	"Q11732313",
	"ngf",
}

m["xfa"] = {
	"ファリスク語",
	"Q35669",
	"itc",
	scripts = {"Ital", "Latn"},
	translit_module = "Ital-translit",
	entry_name = {
		from = {"[ĀĂ]", "[āă]", "[ĒĔ]", "[ēĕë]", "[ĪĬÏ]", "[īĭï]", "[ŌŎ]", "[ōŏ]", "[ŪŬÜ]", "[ūŭü]", "Ȳ", "ȳ", MACRON, BREVE, DIAER},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y"}},
}

m["xga"] = {
	"ガラティア語",
	"Q27403",
	"cel",
	ancestors = {"cel-gau"},
	scripts = {"Latn", "Grek"},
}

m["xgb"] = {
	"Gbin",
	"Q16934745",
	"dmn-mse",
	scripts = Latn,
}

m["xgd"] = {
	"Gudang",
	"Q5614528",
}

m["xgf"] = {
	"ガブリエリーノ語",
	"Q56387",
	"azc-tak",
	otherNames = {"Tongva", "Gabrielino", "Gabrieleño", "Fernandeño"},
	scripts = Latn,
}

m["xgg"] = {
	"Goreng",
	nil,
}

m["xgi"] = {
	"Garingbal",
	nil,
}

m["xgl"] = {
	"ガリンディア語",
	"Q1190494",
	"bat",
	scripts = Latn,
}

m["xgm"] = {
	"Darumbal",
	"Q16954400",
	otherNames = {"Darambal", "Dharumbal", "Dharambal", "Guwinmal", "Kuinmabara", "Karunbara", "Rakiwara", "Wapabara"},
}

m["xgr"] = {
	"ガルサ語",
	"Q3098656",
	"nai-pak",
}

m["xgu"] = {
	"Unggumi",
	"Q62000004",
	"aus-wor",
	scripts = Latn,
}

m["xgw"] = {
	"Guwa",
	"Q5621992",
}

m["xha"] = {
	"ハラム語",
	"Q41506724",
	scripts = {"Sarb"},
	translit_module = "Sarb-translit",
}

m["xhc"] = {
	"フン語",
	"Q35959",
	otherNames = {"Hunnish"},
}

m["xhd"] = {
	"ハドラミ語",
	"Q1032453",
	scripts = {"Sarb"},
	translit_module = "Sarb-translit",
}

m["xhe"] = {
	"ケトラーニー語",
	"Q2614111",
	"inc-pan",
	otherNames = {"Khetranki"},
	ancestors = {"lah"},
}

m["xhm"] = {
	"中期クメール語",
	25226861,
	"mkh-kmr",
	"Latn, Khmr", --and also Khom
	ancestors = "okz",
}

m["xhr"] = {
	"ヘルニクム語",
	"Q5908773",
	"itc",
	scripts = {"Ital"},
}

m["xht"] = {
	"ハッティ語",
	"Q31107",
	"qfa-iso",
	scripts = {"Xsux"},
}

m["xhu"] = {
	"フルリ語",
	"Q35740",
	"qfa-hur",
	scripts = {"Xsux", "Ugar"},
}

m["xhv"] = {
	"クア語",
	"Q22970290",
	"mkh-kat",
}

m["xib"] = {
	"イベリア語",
	"Q855215",
	"qfa-iso",
	scripts = {"Latn", "Ibrn"},
}

m["xii"] = {
	"ヒリ語",
	"Q36876",
}

m["xin"] = {
	"シンカ語",
	"Q1546494",
	"nai-xin",
	scripts = Latn,
}

m["xil"] = {
	"イリュリア語",
	"Q35976",
	"ine",
	type = "reconstructed",
}

m["xir"] = {
	"シリアナ語",
	"Q2028772",
	"awd",
	scripts = Latn,
}

m["xis"] = {
	"Kisan",
	nil,
}

m["xiv"] = {
	"Indus Valley Language",
	"Q3428279",
	scripts = {"Inds"},
}

m["xiy"] = {
	"シパヤ語",
	"Q13226",
	"tup",
	otherNames = {"Shipaja", "Xipaia"},
}

m["xjb"] = {
	"Minjungbal",
	nil,
	"aus-pam",
	scripts = Latn,
}

m["xka"] = {
	"カルコティ語",
	"Q3877551",
}

m["xkb"] = {
	"Manigri-Kambolé Ede Nago",
	"Q36042",
	"alv-ede",
}

m["xkc"] = {
	"ホイニ語",
	otherNames = {"Xoini, Kho'ini"},
	"Q6401919",
	"xme-ttc",
	ancestors = {"xme-ttc-wes"},
}

m["xkd"] = {
	"ムンダラム・カヤン語",
	"Q12952597",
}

m["xke"] = {
	"Kereho",
	"Q6437086",
	"poz",
	otherNames = {"Krio Dayak", "Krio", "Keriu", "Seputan"},
	scripts = Latn,
}

m["xkf"] = {
	"ケンカ語",
	"Q3695207",
	"sit-ebo",
	otherNames = {"Kheng"},
}

m["xkg"] = {
	"カゴロ語",
	"Q11159524",
	"dmn-wmn",
}

m["xki"] = {
	"ケニア手話",
	"Q6392859",
	"sgn",
}

m["xkj"] = {
	"カジャリ語",
	"Q14916876",
	"xme-ttc",
	ancestors = {"xme-ttc-cen"},
}

m["xkk"] = {
	"Kaco'",
	"Q6344767",
	"mkh",
	otherNames = {"Lamam"}, -- Lamam is a Kaco' clan name, formerly encoded by the ISO as 'lmm'
}

m["xkl"] = {
	"バクン語",
	"Q6736761",
	"poz-swa",
	otherNames = {"Mainstream Kenyah", "Kenyah"},
	scripts = Latn,
}

m["xkn"] = {
	"カヤン川カヤン語",
	"Q12473395",
	"poz",
}

m["xko"] = {
	"キオル語",
	"Q6414519",
	"mkh-pal",
}

m["xkp"] = {
	"カバテイ語",
	"Q34165",
	"xme-ttc",
	ancestors = {"xme-ttc-cen"},
}

m["xkq"] = {
	"Koroni",
	"Q3199000",
	"poz-btk",
}

m["xkr"] = {
	"シャクリアバ語",
	"Q3073441",
	"sai-cje",
	otherNames = {"Chacriabá", "Chacriaba", "Chakriaba", "Xakriaba", "Xacriabá", "Xacriaba", "Chikriaba", "Xikriabá", "Xikriaba", "Shacriaba", "Xicriabá", "Xicriaba", "Chicriabá", "Chicriaba"},
	scripts = Latn,
}

m["xks"] = {
	"Kumbewaha",
	"Q6443722",
}

m["xkt"] = {
	"カントシ語",
	"Q35651",
	"nic-dag",
}

m["xku"] = {
	"Kaamba",
	"Q11042324",
	"bnt-kng",
}

m["xkv"] = {
	"Kgalagadi",
	"Q2088743",
	"bnt-sts",
	scripts = Latn,
}

m["xkw"] = {
	"Kembra",
	"Q12953627",
	"paa-pau",
}

m["xkx"] = {
	"Karore",
	"Q6373260",
	"poz-ocw",
}

m["xky"] = {
	"Uma' Lasan",
	nil,
	"poz-swa",
}

m["xkz"] = {
	"クルテプ語",
	"Q3695193",
	"sit-ebo",
	otherNames = {"Kurtöp", "Kurtopkha", "Kurtokha"},
	scripts = {"Tibt", "Latn"},
    translit_module = "Tibt-translit",
}

m["xla"] = {
	"カムラ語",
	"Q10957277",
	"ngf",
}

m["xlb"] = {
	"ループ語B",
	"Q13108281",
	"alg-eas",
	scripts = Latn,
}

m["xlc"] = {
	"リュキア語",
	"Q35969",
	"ine-ana",
	scripts = {"Lyci"},
	translit_module = "Lyci-translit",
}

m["xld"] = {
	"リュディア語",
	"Q36095",
	"ine-ana",
	scripts = {"Lydi"},
	translit_module = "Lydi-translit",
}

m["xle"] = {
	"リムノス語",
	"Q36203",
	"qfa-tyn",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["xlg"] = {
	"Ancient Ligurian",
	"Q36104",
	"ine",
}

m["xli"] = {
	"リブルニア語",
	"Q35835",
	"ine",
}

--xln is etymology-only

m["xlo"] = {
	"ループ語A",
	"Q27921265",
	"alg-eas",
	scripts = Latn,
}

m["xlp"] = {
	"レポント語",
	"Q35993",
	"cel",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["xls"] = {
	"ルシタニア語",
	"Q35960",
	"ine",
	scripts = Latn,
}

m["xlu"] = {
	"ルウィ語",
	"Q12634577",
	"ine-ana",
	otherNames = {"Cuneiform Luwian", "Hieroglyphic Luwian"},
	scripts = {"Xsux", "Hluw"},
}

m["xly"] = {
	"エリミ語",
	"Q35329",
	scripts = {"Grek"},
}

m["xmb"] = {
	"Mbonga",
	"Q36064",
	"nic-jrn",
	otherNames = {"Mboa"},
	scripts = Latn,
}

m["xmc"] = {
	"Makhuwa-Marrevone",
	"Q11127231",
	"bnt-mak",
	ancestors = {"vmw"},
}

m["xmd"] = {
	"ムブドゥム語",
	"Q6799790",
	"cdc-cbm",
	scripts = Latn,
}

m["xmf"] = {
	"メグレル語",
	"Q13359",
	"ccs-zan",
	otherNames = {"Megrelian", "Mingrel", "Megrel"},
	scripts = {"Geor"},
	translit_module = "Geor-translit",
	override_translit = true,
}

m["xmg"] = {
	"メンガカ語",
	"Q36017",
	"bai",
	scripts = Latn,
}

m["xmh"] = {
	"クク＝ムミン語",
	"Q10549849",
	"aus-pmn",
	otherNames = {"Kuku-Muminh", "Wik-Muminh", "Kugu-Nganhcara", "Wik-Nganhcara", "Wikngenchera"},
	scripts = Latn,
}

m["xmj"] = {
	"マジェラ語",
	"Q6737666",
	"cdc",
	scripts = Latn,
}

m["xmk"] = {
	"古マケドニア語",
	"Q35974",
	"grk",
	scripts = {"polytonic"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, cpg, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇᾱ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗῑ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧῡ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}},
	entry_name = {
		from = {"[ᾸᾹ]", "[ᾰᾱ]", "[ῘῙ]", "[ῐῑ]", "[ῨῩ]", "[ῠῡ]"},
		to   = {"Α", "α", "Ι", "ι", "Υ", "υ"}} ,
}

m["xml"] = {
	"マレーシア手話",
	"Q33420",
	"sgn",
}

m["xmm"] = {
	"マナド・マライ語",
	"Q1068112",
}

m["xmo"] = {
	"モレレビ語",
	"Q12953749",
	"tup",
	scripts = Latn,
}

m["xmp"] = {
	"クク＝ムイン語",
	"Q10549852",
	scripts = Latn,
}

m["xmq"] = {
	"クク＝マンク語",
	"Q10549851",
	"aus-pam",
	scripts = Latn,
}

m["xmr"] = {
	"メロエ語",
	"Q13366",
	"afa",
	otherNames = {"Kushite"},
	scripts = {"Mero", "Merc", "Latn"}, -- we have entries in Latn
	translit_module = "xmr-translit",
}

m["xms"] = {
	"モロッコ手話",
	"Q6913107",
	"sgn",
}

m["xmt"] = {
	"マトバト語",
	"Q6786187",
	"poz-hce",
}

m["xmu"] = {
	"カム語",
	"Q6359779",
}

m["xmx"] = {
	"マデン語",
	"Q12952756",
	"poz-hce",
}

m["xmy"] = {
	"マヤグドゥナ語",
	"Q3436736",
}

m["xmz"] = {
	"Mori Bawah",
	"Q3324069",
	"poz-btk",
	scripts = Latn,
}

m["xna"] = {
	"古代北アラビア語",
	"Q1472213",
	"sem",
	scripts = {"Narb"}
}

m["xnb"] = {
	"カナカナブ語",
	"Q172244",
	"map",
	otherNames = {"Kanakanavu"},
	scripts = Latn,
}

m["xng"] = {
	"中世モンゴル語",
	"Q2582455",
	"xgn",
	scripts = {"Mong", "Arab", "Phag"},
	translit_module = "mn-translit",
}

m["xnh"] = {
	"Kuanhua",
	"Q6441084",
	"mkh-pal",
}

m["xni"] = {
	"Ngarigu",
	"Q7022072",
}

m["xnk"] = {
	"Nganakarti",
	"Q33087049",
}

m["xnn"] = {
	"北部カンカナイ語",
	"Q12953609",
	"phi",
}

m["xno"] = {
	"アングロ・ノルマン語",
	"Q35214",
	"ine",
}

m["xnr"] = {
	"カーングリー語",
	"Q2331560",
	"him",
	scripts = {"Deva", "Takr", "fa-Arab"},
	ancestors = {"doi"},
	translit_module = "hi-translit",
}

m["xns"] = {
	"カナシュ語",
	"Q6360672",
	"sit-whm",
}

m["xnt"] = {
	"ナラガンセット語",
	"Q3336118",
	"alg-eas",
	scripts = Latn,
}

m["xnu"] = {
	"Nukunul",
	"Q7068904",
}

m["xny"] = {
	"Nyiyaparli",
	"Q16919427",
	"aus-nga",
	otherNames = {"Nyiyabali", "Njijabali", "Nijadali"},
	scripts = Latn,
}

m["xoc"] = {
	"O'chi'chi'",
	"Q3813833",
	"nic-cde",
	scripts = Latn,
}

m["xod"] = {
	"Kokoda",
	"Q6426734",
	"ngf-sbh",
}

m["xog"] = {
	"Soga",
	"Q33784",
	"bnt-nyg",
	otherNames = {"Lusoga"},
	scripts = Latn,
}

m["xoi"] = {
	"Kominimung",
	"Q6428352",
	"paa",
	scripts = Latn,
}

m["xok"] = {
	"Xokleng",
	"Q3027930",
	"sai-sje",
}

m["xom"] = {
	"Komo",
	"Q56681",
	"ssa-kom",
	otherNames = {"Komo (Sudan)", "Madiin"},
}

m["xon"] = {
	"Konkomba",
	"Q35674",
	"nic-grm",
	scripts = Latn,
}

m["xoo"] = { -- contrast kzw, sai-kat, sai-xoc
	"Xukurú",
	"Q9096758",
	otherNames = {"Xukuru", "Xucurú", "Xucuru", "Shukurú", "Shukuru", "Shucurú", "Shucuru", "Kirirí", "Kiriri", "Kirirí-Xokó"},
}

m["xop"] = {
	"Kopar",
	"Q11732346",
}

m["xor"] = {
	"Korubo",
	"Q3199022",
}

m["xow"] = {
	"Kowaki",
	"Q6434920",
	"ngf-mad",
}

m["xpa"] = {
	"Pirriya",
	"Q16978087",
}

m["xpb"] = {
	"Pyemmairre",
	"Q7262964",
	otherNames = {"Northeastern Tasmanian", "North East Tasmanian", "Plangermaireener", "Plangamerina", "Cape Portland", "Ben Lomond", "Pipers River"},
	scripts = Latn,
}

m["xpc"] = {
	"ペチェネグ語",
	"Q877881",
	"trk",
}

m["xpd"] = {
	"Paredarerme",
	"Q7136678",
	otherNames = {"Oyster Bay", "Oyster Bay Tasmanian", "Paritarami", "Big River", "Big River Tasmanian", "Lairmairrener", "Lemerina"},
	scripts = Latn,
}

m["xpe"] = {
	"リベリア・クペレ語",
	"Q20527226",
	"dmn-msw",
	ancestors = {"kpe"},
}

m["xpf"] = {
	"Southeast Tasmanian",
	"Q7068421",
	otherNames = {"Mainland Southeast Tasmanian", "Nuenonne", "Nyunoni"},
	scripts = Latn,
}

m["xpg"] = {
	"フリュギア語",
	"Q36751",
	"ine",
	scripts = {"Grek"},
	translit_module = "grc-translit",
}

m["xph"] = {
	"Tyerrernotepanner",
	"Q7859815",
	otherNames = {"North Midland Tasmanian", "North Midlands Tasmanian", "Cheranotipana"},
	scripts = Latn,
}

m["xpi"] = {
	"ピクト語",
	"Q856383",
	"cel",
	scripts = {"Ogam", "Latn"},
}

m["xpj"] = {
	"Mpalitjanh",
	"Q6928192",
	"aus-pam",
	otherNames = {"Luthigh"},
}

m["xpk"] = {
	"Kulina",
	"Q6443027",
	"sai-pan",
	otherNames = {"Kulina Pano"},
}

m["xpl"] = {
	"Port Sorell",
	"Q7230944",
	aliases = {"Port Sorell Tasmanian"},
	scripts = Latn,
}

m["xpm"] = {
	"プンポコル語",
	"Q2991985",
	"qfa-yen",
	scripts = Latn,
}

m["xpn"] = {
	"Kapinawá",
	"Q6366667",
}

m["xpo"] = {
	"ポチュテコ語",
	"Q2427341",
	"azc-nah",
	scripts = Latn,
}

m["xpp"] = {
	"Puyo-Paekche",
	nil,
}

m["xpq"] = {
	"モヘガン・ペクウォート語",
	"Q3319130",
	"alg-eas",
	scripts = Latn,
}

m["xpr"] = {
	"パルティア語",
	"Q25953",
	"ira-mpr",
	scripts = {"Prti", "Mani", "Phlv"},
	translit_module = "translit-redirect",
}

m["xps"] = {
	"ピシディア語",
	"Q36580",
	"ine-ana",
}

m["xpu"] = {
	"ポエニ語",
	"Q535958",
	"sem-can",
	scripts = {"Phnx", "Latn", "Grek"},
	ancestors = {"phn"},
	translit_module = "translit-redirect",
}

m["xpv"] = {
	"Tommeginne",
	"Q7819095",
	otherNames = {"Tommeeginnee", "Northern Tasmanian"},
	scripts = Latn,
}

m["xpw"] = {
	"Peerapper",
	"Q7160431",
	otherNames = {"Pirapa", "Northwestern Tasmanian"},
	scripts = Latn,
}

m["xpx"] = {
	"Toogee",
	"Q7824008",
	otherNames = {"Southwestern Tasmanian"},
	scripts = Latn,
}

m["xpy"] = {
	"扶余語",
	"Q5003359",
	"qfa-kor",
	scripts = {"Hani"},
}

m["xpz"] = {
	"Bruny Island",
	"Q4979601",
	otherNames = {"Bruny Island Tasmanian", "Nuenonne", "Nyunoni"},
	scripts = Latn,
}

m["xqa"] = {
	"カラハン語",
	nil,
	"trk-kar",
	scripts = {"Arab"},
}

m["xqt"] = {
	"カタバーン語",
	"Q384101",
	"sem-osa",
	scripts = {"Sarb"},
	translit_module = "Sarb-translit",
}

m["xra"] = {
	"クラオ語",
	"Q3199549",
	"sai-nje",
}

m["xrb"] = {
	"東部カラボロ語",
	"Q35716",
	"alv-krb",
}

m["xrd"] = {
	"Gundungurra",
	nil,
}

m["xre"] = {
	"Kreye",
	"Q3199686",
	"sai-nje",
}

m["xrg"] = {
	"Minang",
	"Q22893424",
}

m["xri"] = {
	"クリカティ＝ティンビラ語",
	"Q3199710",
}

m["xrm"] = {
	"Armazic",
	"Q7599646",
}

m["xrn"] = {
	"アリン語",
	"Q34088",
	"qfa-yen",
	scripts = Latn,
}

m["xrq"] = {
	"Karranga",
	"Q6373349",
	otherNames = {"Karrangpurru"},
	scripts = Latn,
}

m["xrr"] = {
	"ラエト語",
	"Q36689",
	otherNames = {"Rhaetic", "Rhaetian"},
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

m["xrt"] = {
	"アラナマ＝タミケ語",
	"Q2859505",
}

m["xru"] = {
	"Marriammu",
	"Q10577724",
	"aus-dal",
}

m["xrw"] = {
	"カラワ語",
	"Q6368857",
	"paa-spk",
}

m["xsa"] = {
	"サバ語",
	"Q1070391",
	"sem-osa",
	scripts = {"Sarb"},
	translit_module = "Sarb-translit",
}

m["xsb"] = {
	"サンバル語",
	"Q2592378",
	"phi",
	otherNames = {"Sambal", "Tina Sambal", "Tina"},
	scripts = Latn,
}

m["xsd"] = {
	"シーデ語",
	"Q36659",
	"ine-ana",
}

m["xse"] = {
	"センパン語",
	"Q3504358",
}

m["xsh"] = {
	"Shamang",
	"Q3914876",
	"nic-plc",
}

m["xsi"] = {
	"シオ語",
	"Q3485100",
	"poz-ocw",
}

m["xsj"] = {
	"スビ語",
	"Q7631298",
	"bnt-haj",
}

m["xsl"] = {
	"南スレーヴィ語",
	"Q28552",
	"ath-nor",
	scripts = Latn,
}

m["xsm"] = {
	"カセム語",
	"Q35552",
	"nic-gnn",
	otherNames = {"Kassena"},
}

m["xsn"] = {
	"サンガ語 (ナイジェリア)",
	"Q3915334",
	"nic-jer",
	otherNames = {"Sanga"},
	scripts = Latn,
}

m["xso"] = {
	"Solano",
	"Q2474492",
	scripts = Latn,
}

m["xsp"] = {
	"シロピ語",
	"Q7515533",
	"ngf-mad",
}

m["xsq"] = {
	"Makhuwa-Saka",
	"Q11008159",
	"bnt-mak",
	ancestors = {"vmw"},
}

m["xsr"] = {
	"シェルパ語",
	"Q36612",
	"sit-tib",
	scripts = {"Tibt"},
	ancestors = {"xct"},
}

m["xss"] = {
	"アッサン語",
	"Q34089",
	"qfa-yen",
	scripts = Latn,
}

m["xsu"] = {
	"サヌマ語",
	"Q251728",
	"sai-ynm",
}

m["xsv"] = {
	"スドヴィア語",
	"Q35603",
	"bat",
	otherNames = {"Jatvingian"},
	scripts = Latn,
}

m["xsy"] = {
	"サイシヤット語",
	"Q716695",
	"map",
	scripts = Latn,
}

m["xta"] = {
	"アルコサウカ・ミステク語",
	"Q25559587",
	"omq-mxt",
	scripts = Latn,
}

m["xtb"] = {
	"チャスンバ・ミステク語",
	"Q12182838",
	"omq-mxt",
	scripts = Latn,
}

m["xtc"] = {
	"カチャ＝カドゥグリ＝ミリ語",
	"Q3407136",
	"qfa-kad",
	otherNames = {"Katcha-Kadugli-Miri"},
	scripts = Latn,
}

m["xtd"] = {
	"ディウクシ＝ティラントンゴ・ミステク語",
	"Q7802048",
	"omq-mxt",
	scripts = Latn,
}

m["xte"] = {
	"ケテンバン語",
	"Q10990152",
}

m["xth"] = {
	"イータ・イータ語",
	nil,
}

m["xti"] = {
	"シニカウア・ミステク語",
	"Q12953733",
	"omq-mxt",
	scripts = Latn,
}

m["xtj"] = {
	"サン・ファン・テイタ・ミステク語",
	"Q32093049",
	"omq-mxt",
	scripts = Latn,
}

m["xtl"] = {
	"ティハルテペク・ミステク語",
	"Q12953738",
	"omq-mxt",
	scripts = Latn,
}

m["xtm"] = {
	"ペニャスコ・ミステク語",
	"Q7179700",
	"omq-mxt",
	scripts = Latn,
}

m["xtn"] = {
	"北部トラヒアコ・ミステク語",
	"Q25559585",
	"omq-mxt",
	scripts = Latn,
}

m["xto"] = {
	"トカラ語A",
	"Q2827041",
	"ine-toc",
	otherNames = {"East Tocharian", "Agnean"},
	scripts = Latn,
	wikipedia_article = "Tocharian languages", -- wikidata id has no associated article
}

m["xtp"] = {
	"サン・ミゲル・ピエドラス・ミステク語",
	"Q7414970",
	"omq-mxt",
	scripts = Latn,
}

m["xtq"] = {
	"トムシュク語",
	nil,
	"xsc-sak",
	scripts = {"Brah", "Khar"},
	translit_module = "Brah-translit",
}

m["xtr"] = {
	"Early Tripuri",
	nil,
}

m["xts"] = {
	"シンディウイ・ミステク語",
	"Q13583581",
	"omq-mxt",
	scripts = Latn,
}

m["xtt"] = {
	"タカウア・ミステク語",
	"Q7673668",
	"omq-mxt",
	scripts = Latn,
}

m["xtu"] = {
	"クヤメカルコ・ミステク語",
	"Q12953726",
	"omq-mxt",
	scripts = Latn,
}

m["xtv"] = {
	"Thawa",
	"Q7711494",
}

m["xtw"] = {
	"タワンデ語",
	nil,
	"sai-nmk",
	scripts = Latn,
}

m["xty"] = {
	"ヨロクソチトル・ミステク語",
	"Q8054817",
	"omq-mxt",
	scripts = Latn,
}

m["xtz"] = {
	"タスマニア語",
	"Q530739",
	scripts = Latn,
}

m["xua"] = {
	"Alu Kurumba",
	"Q12952679",
	"dra",
}

m["xub"] = {
	"Betta Kurumba",
	"Q16841033",
	"dra",
	scripts = {"Knda", "Mlym", "Taml"},
}

m["xud"] = {
	"Umiida",
	"Q61999874",
	"aus-wor",
	scripts = Latn,
}

m["xug"] = {
	"国頭語",
	"Q56558",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["xuj"] = {
	"Jennu Kurumba",
	"Q21282543",
	"dra",
}

m["xul"] = {
	"Ngunawal",
	"Q7022712",
	"aus-yuk",
	scripts = Latn,
}

m["xum"] = {
	"ウンブリア語",
	"Q36957",
	"itc",
	scripts = {"Ital", "Latn"},
	translit_module = "Ital-translit",
}

m["xun"] = {
	"Unggaranggu",
	"Q61999823",
	"aus-wor",
	scripts = Latn,
}

m["xuo"] = {
	"Kuo",
	"Q6445233",
	"alv-mbm",
}

m["xup"] = {
	"アッパー・アンプクア語",
	"Q20607",
	"ath-pco",
	scripts = Latn,
}

m["xur"] = {
	"ウラルトゥ語",
	"Q36934",
	"qfa-hur",
	otherNames = {"Urartean"},
	scripts = {"Xsux"},
}

m["xut"] = {
	"クタントゥ語",
	"Q6448417",
}

m["xuu"] = {
	"コエ語",
	"Q28305",
	"khi-kal",
	otherNames = {"Kxoe"},
	scripts = Latn,
}

m["xve"] = {
	"ウェネティ語",
	"Q36871",
	"ine",
	scripts = {"Ital"},
	translit_module = "Ital-translit",
}

-- m["xvi"] = { "Kamviri", "Q1193495", "nur-nor", scripts = {"Arab"} } moved to etym-only code

m["xvn"] = {
	"ヴァンダル語",
	"Q36835",
	"gme",
	scripts = Latn,
}

m["xvo"] = {
	"ウォルスキ語",
	"Q622110",
	"itc",
	scripts = Latn,
}

m["xvs"] = {
	"ヴェスティニア語",
	"Q2576407",
	"itc",
	scripts = Latn,
}

m["xwa"] = {
	"クワサ語",
	"Q3200839",
}

m["xwc"] = {
	"ウォコン語",
	"Q3569569",
	"nai-cat",
	scripts = Latn,
}

m["xwd"] = {
	"Wadi Wadi",
	"Q7959249",
}

m["xwe"] = {
	"フェラ・グベ語",
	"Q36887",
	"alv-pph",
}

m["xwg"] = {
	"クエグ語",
	"Q56723",
	"sdv",
}

m["xwj"] = {
	"Wajuk",
	"Q33110188",
}

m["xwk"] = {
	"Wangkumara",
	"Q7967891",
	"aus-pam",
	otherNames = {"Wanggumara", "Karenggapa", "Punthamara"},
	scripts = Latn,
}

m["xwl"] = {
	"西部フラ・グベ語",
	"Q36924",
	"alv-pph",
	scripts = Latn,
}

m["xwo"] = {
	"オイラート文語",
	"Q56959",
	"xgn",
	translit_module = "xwo-translit",
	scripts = {"Mong"},
}

m["xwr"] = {
	"クェルバ・マンベラモ語",
	"Q6450325",
	"paa-tkw",
}

m["xww"] = {
	"ウェンバ・ウェンバ語",
	"Q18472819",
	"aus-pam",
	otherNames = {"Wemba Wemba", "Wamba-Wamba", "Wamba Wamba", "Wembawemba", "Baraba-Baraba", "Barababaraba", "Nari-Nari", "Wergaia", "Wotjobaluk"},
	scripts = Latn,
}

m["xxb"] = {
	"ボロ語",
	"Q16844787",
	otherNames = {"Boro (Ghana)"},
	scripts = Latn,
}

m["xxk"] = {
	"ケオ語",
	"Q3195346",
}

m["xxm"] = {
	"Minkin",
	"Q6867836",
}

m["xxr"] = {
	"コロポ語",
	"Q6432560",
}

m["xxt"] = {
	"タンボラ語",
	"Q36711",
	"paa",
	scripts = Latn,
}

m["xya"] = {
	"Yaygir",
	"Q8050525",
	"aus-pam",
}

m["xyb"] = {
	"Yandjibara",
	nil,
	scripts = Latn,
}

m["xyl"] = {
	"Yalakalore",
	"Q12645352",
	"sai-nmk",
	scripts = Latn,
}

m["xyt"] = {
	"Mayi-Thakurti",
	"Q47004719",
	"aus-pam",
	scripts = Latn,
}

m["xyy"] = {
	"Yorta Yorta",
	"Q8055849",
	"aus-pam",
	otherNames = {"Yotayota", "Yortayorta", "Bangerang", "Kailtheban", "Wollithiga", "Jotijota", "Joti-Jota", "Jodajoda"},
	scripts = Latn,
}

m["xzh"] = {
	"シャン＝シュン語",
	"Q3437292",
	"sit-alm",
	scripts = {"xzh-Tibt", "Marc"},
}

m["xzm"] = {
	"セミガリア語",
	"Q47631",
	"bat",
	otherNames = {"Semigallian", "Semigalian"},
}

m["xzp"] = {
	"古サポテク語",
	nil,
}

return m