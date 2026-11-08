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

m["yaa"] = {
	"ヤミナワ語",
	"Q3026110",
	"sai-pan",
	otherNames = {"Yaminawa"},
	scripts = Latn,
}

m["yab"] = {
	"ユフプ語",
	"Q3573115",
	"sai-nad",
	scripts = Latn,
}

m["yac"] = {
	"Pass Valley Yali",
	"Q12953309",
	"ngf",
	scripts = Latn,
}

m["yad"] = {
	"ヤグア語",
	"Q3182567",
	scripts = Latn,
}

m["yae"] = {
	"Pumé",
	"Q3121835",
	otherNames = {"Yaruro", "Yaruru", "Yuapín", "Pume"},
	scripts = Latn,
}

m["yaf"] = {
	"ヤカ語",
	"Q35588",
	"bnt-yak",
	otherNames = {"Yaka (Democratic Republic of the Congo)", "Kiyaka"}, -- cf. 'axk', 'iyx'
	scripts = Latn,
}

m["yag"] = {
	"ヤマナ語",
	"Q531826",
	"qfa-iso",
	otherNames = {"Yagán", "Yahgan", "Yaghan"},
	scripts = Latn,
}

m["yah"] = {
	"ヤズグレム語",
	otherNames = {"Yazgulyam"},
	"Q34186",
	"ira-shy",
	scripts = {"Latn", "Cyrl"},
	ancestors = {"ira-shy-pro"},
}

m["yai"] = {
	"ヤグノビ語",
	"Q34247",
	"ira-sgc",
	aliases = {"Yaghnobi", "Yaghnabi", "Yagnabi"},
	scripts = {"Latn", "Cyrl"},
	translit_module = "tg-translit",
}

m["yaj"] = {
	"バンダ＝ヤンゲレ語",
	"Q8048561",
	"bad",
}

m["yak"] = {
	"ヤキマ語",
	"Q35976053",
	"nai-shp",
	ancestors = {"nai-spt"},
	scripts = Latn,
}

m["yal"] = {
	"ヤルンカ語",
	"Q35524",
	"dmn-sya",
	otherNames = {"Jallonka", "Jalonke"},
}

m["yam"] = {
	"Yamba",
	"Q36904",
	"nic-nka",
	scripts = Latn,
}

m["yan"] = {
	"マヤングナ語",
	"Q3302929",
	"nai-min",
	scripts = Latn,
}

m["yao"] = {
	"ヤオ語 (バントゥー)",
	"Q36902",
	"bnt-rvm",
	otherNames = {"Yao (Africa)"},
	scripts = Latn,
}

m["yap"] = {
	"ヤップ語",
	"Q34029",
	"poz-oce",
	scripts = Latn,
}

m["yaq"] = {
	"ヤキ語",
	"Q34191",
	"azc-trc",
	otherNames = {"Hiaki", "Yoeme"},
	scripts = Latn,
}

m["yar"] = {
	"ヤバラナ語",
	"Q3571238",
	"sai-car",
	scripts = Latn,
}

m["yas"] = {
	"ヌグヌ語",
	"Q36358",
	"nic-ymb",
	otherNames = {"Nugunu"},
	scripts = Latn,
}

m["yat"] = {
	"ヤンベタ語",
	"Q8048020",
	"nic-mbw",
	scripts = Latn,
}

m["yau"] = {
	"Yuwana",
	"Q5876347",
}

m["yav"] = {
	"Yangben",
	"Q12953315",
	"nic-ymb",
	scripts = Latn,
}

m["yaw"] = {
	"ヤワラピティ語",
	"Q3450709",
	"awd",
	scripts = Latn,
}

m["yay"] = {
	"アグワグネ語",
	"Q34736",
	"nic-ucn",
	scripts = Latn,
}

m["yaz"] = {
	"Lokaa",
	"Q3914439",
	"nic-uce",
	scripts = Latn,
}

m["yba"] = {
	"ヤラ語",
	"Q3914920",
	"alv-ido",
	scripts = Latn,
}

m["ybb"] = {
	"イエンバ語",
	"Q36917",
	"bai",
	scripts = Latn,
}

m["ybe"] = {
	"西部ユグル語",
	"Q34224",
	"trk-sib",
	ancestors = {"oui"},
}

m["ybh"] = {
	"ヤッカ語",
	"Q56666",
	"sit-kie",
	scripts = {"Deva"},
}

m["ybi"] = {
	"ヤンプ語",
    "Q56316",
    "sit-kie",
    scripts = {"Deva"},
    translit_module = "ybi-translit",
} 

m["ybj"] = {
	"Hasha",
	"Q3915338",
	"nic-alu",
}

m["ybk"] = {
	"Bokha",
	nil,
	"tbq-lol",
}

m["ybl"] = {
	"ユクベン語",
	"Q3915846",
	"nic-ykb",
}

m["ybm"] = {
	"ヤベン語",
	"Q8046372",
	"ngf-mad",
}

m["ybn"] = {
	"ヤバーナ語",
	"Q3450534",
	"awd",
	scripts = Latn,
}

m["ybo"] = {
	"ヤボン語",
	"Q8046383",
	"ngf-mad",
}

m["ybx"] = {
	"Yawiyo",
	"Q8050463",
	"paa-spk",
}

m["yby"] = {
	"ヤウェユハ語",
	"Q3571231",
	"paa-kag",
}

m["ych"] = {
	"Chesu",
	nil,
	"tbq-lol",
}

m["ycl"] = {
	"ロロポ語",
	"Q56441",
	"tbq-lol",
}

m["ycn"] = {
	"ユクナ語",
	"Q3438356",
	"awd-nwk",
	otherNames = {"Yukuna", "Yacuna", "Yakuna", "Jucuna", "Jukuna"},
	scripts = Latn,
}

m["ycp"] = {
	"Chepya",
	"Q46603077",
	"tbq-lol",
}

m["ycr"] = {
	"宜蘭クレオール",
	10955036,
	"crp",
	"Latn",
}

m["yda"] = {
	"Yanda",
	"Q8048318",
	"aus-pam",
}

m["yde"] = {
	"Yangum Dey",
	nil,
	"qfa-tor",
	scripts = Latn,
}

m["ydg"] = {
	"イドガ語",
	"Q34179",
	"ira-mny",
	scripts = {"Arab"},
	ancestors = {"ira-mny-pro"},
}

m["ydk"] = {
	"ヨイディク語",
	"Q8054512",
	"ngf-mad",
}

m["yea"] = {
	"Ravula",
	"Q7296830",
	"dra",
}

m["yec"] = {
	"イェニシェ語",
	"Q1365342",
	"gmw",
	scripts = Latn,
	ancestors = {"gmh"},
}

m["yee"] = {
	"イマス語",
	"Q36954",
	"paa-lsp",
}

m["yei"] = {
	"Yeni",
	"Q34213",
	"nic-mmb",
}

m["yej"] = {
	"イェヴァン語",
	"Q34200",
	"grk",
	scripts = {"Hebr"},
	ancestors = {"grc"},
	entry_name = {
		from = {"[" .. u(0x0591) .. "-" .. u(0x05BD) .. u(0x05BF) .. "-" .. u(0x05C5) .. u(0x05C7) .. "]"},
		to   = {}} ,
}

m["yen"] = {
	"Yendang",
	nil,
	"alv-mye",
	otherNames = {"Yotti"},
	scripts = Latn,
}

m["yer"] = {
	"タロック語",
	"Q3914953",
	"nic-tar",
	otherNames = {"Yergum", "Yergam"},
	scripts = Latn,
}

m["yes"] = {
	"Yeskwa",
	"Q3914962",
	"nic-plc",
	otherNames = {"Nyankpa"},
	scripts = Latn,
}

m["yet"] = {
	"Yetfa",
	"Q8053020",
	"paa-pau",
}

m["yeu"] = {
	"イェルクラ語",
	"Q3535117",
	"dra",
}

m["yev"] = {
	"ヤプンダ語",
	"Q11044384",
	"qfa-tor",
	scripts = Latn,
}

m["yey"] = {
	"イェイ語",
	"Q8053347",
	"bnt",
}

m["ygi"] = {
	"Yiningayi",
	nil,
	"aus-pam",
}

m["ygl"] = {
	"Yangum Gel",
	nil,
	"qfa-tor",
	scripts = Latn,
}

m["ygm"] = {
	"ヤゴミ語",
	"Q20771657",
	"ngf-fin",
	scripts = Latn,
}

m["ygp"] = {
	"Gepo",
	"Q5548692",
	"tbq-lol",
}

m["ygr"] = {
	"ヤガリア語",
	"Q8046690",
	"paa-kag",
	otherNames = {"Hua"},
	scripts = Latn,
}

m["ygs"] = {
	"Yolngu Sign Language",
	"Q16211970",
	"sgn",
}

m["ygu"] = {
	"Yugul",
	"Q8060437",
	"aus-arn",
}

m["ygw"] = {
	"ヤグウォイア語",
	"Q8046761",
	"ngf",
	scripts = Latn,
}

m["yha"] = {
	"巴哈布央語",
	"Q2879238",
	"qfa-kra",
	otherNames = {"Baha Buyang", "Paha"},
}

m["yhd"] = {
	"ユダヤ＝イラク・アラビア語",
	"Q56599",
	"sem-arb",
	scripts = {"Hebr"},
	ancestors = {"jrb"},
}

m["yhl"] = {
	"Hlepho Phowa",
	nil,
	"tbq-lol",
}

m["yia"] = {
	"インガダ語",
	"Q3913777",
	"aus-psw",
	scripts = Latn,
}

m["yif"] = {
	"阿車語",
	"Q10949828",
	"tbq-lol",
	otherNames = {"Azhe"},
}

m["yig"] = {
	"Wusa Nasu",
	"Q12953334",
	"tbq-lol",
}

m["yii"] = {
	"イディン語",
	"Q3053283",
	"aus-yid",
	scripts = Latn,
}

m["yij"] = {
	"インジバルンディ語",
	"Q3121073",
	"aus-nga",
	scripts = Latn,
}

m["yik"] = {
	"Dongshanba Lalo",
	"Q12953333",
	"tbq-lal",
}

m["yil"] = {
	"インジランジ語",
	"Q10723541",
	"aus-pam",
	scripts = Latn,
}

m["yim"] = {
	"イムチュングリ・ナガ語",
	"Q56348",
	"sit-aao",
	scripts = Latn,
}

m["yin"] = {
	"Yinchia",
	"Q12953981",
	"mkh-pal",
}

m["yip"] = {
	"Pholo",
	"Q7187103",
	"tbq-lol",
}

m["yiq"] = {
	"Miqie",
	"Q6827993",
	"tbq-lol",
	otherNames = {"Micha"},
}

m["yir"] = {
	"北アウユ語",
	"Q12642164",
	"ngf",
}

m["yis"] = {
	"イス語",
	"Q8053831",
	"qfa-tor",
	scripts = Latn,
}

m["yit"] = {
	"Eastern Lalu",
	"Q12953328",
	"tbq-lal",
}

m["yiu"] = {
	"アウ語",
	"Q11163308",
	"tbq-lol",
	otherNames = {"Lope"},
}

m["yiv"] = {
	"Northern Nisu",
	"Q25559454",
	"tbq-lol",
}

m["yix"] = {
	"アシ彝語",
	"Q4830439",
	"tbq-lol",
}

m["yiy"] = {
	"イル・ヨロント語",
	"Q8053819",
	"aus-pmn",
	otherNames = {"Yir Yoront", "Yirr-Yoront", "Yirr-Yorront", "Yirrk-Mel", "Yirrk-Thangalkl", "Yir Thangedl", "Yirr-Thangell"},
	scripts = Latn,
}

m["yiz"] = {
	"Azhe",
	"Q4832535",
	"tbq-lol",
}

m["yka"] = {
	"ヤカン語",
	"Q3571351",
	"poz-sbj",
}

m["ykg"] = {
	"北部ユカギール語",
	"Q56319",
	"qfa-yuk",
	otherNames = {"Tundra Yukaghir"},
	scripts = {"Cyrl"},
	translit_module = "ykg-translit",
}

m["yki"] = {
	"Yoke",
	"Q3832977",
}

m["ykk"] = {
	"Yakaikeke",
	"Q8047041",
	"poz-oce",
}

m["ykl"] = {
	"Khlula",
	"Q6401849",
	"tbq-lol",
}

m["ykm"] = {
	"ヤクムル語",
	"Q8047048",
	"poz-ocw",
	otherNames = {"Yakamul", "Ali"},
	scripts = Latn,
}

m["ykn"] = {
	"Kua-nsi",
	"Q6440952",
	"tbq-lol",
}

m["yko"] = {
	"ヤサ語",
	"Q36899",
	"bnt-yko",
	scripts = Latn,
}

m["ykr"] = {
	"イェコラ語",
	"Q11732781",
	"ngf",
}

m["ykt"] = {
	"Kathu",
	"Q6377155",
	"sit-mnz",
}

m["yku"] = {
	"Kuamasi",
	"Q6441074",
	"tbq-lol",
}

m["yky"] = {
	"ヤコマ語",
	"Q3571364",
	"nic-ngd",
	otherNames = {"Dendi", "Dendi (Central Africa)"}, -- Dendi is a dialect
}

m["yla"] = {
	"ヤウル語",
	"Q8050336",
	"paa",
	scripts = Latn,
}

m["ylb"] = {
	"Yaleba",
	"Q37710600",
	"poz-oce",
}

m["yle"] = {
	"イェレ語",
	"Q36942",
}

m["ylg"] = {
	"イェログ語",
	"Q8052024",
	"paa-spk",
}

m["yli"] = {
	"Angguruk Yali",
	"Q3514481",
	"ngf",
	otherNames = {"Northern Yali"},
}

m["yll"] = {
	"イル語",
	"Q3501797",
	"qfa-tor",
	scripts = Latn,
}

m["ylm"] = {
	"Limi",
	"Q12953327",
	"tbq-lol",
}

m["yln"] = {
	"郎念布央語",
	"Q2929025",
	"qfa-buy",
}

m["ylo"] = {
	"Naluo Yi",
	"Q6961032",
	"tbq-lol",
}

m["ylr"] = {
	"ヤランガ語",
	"Q3915686",
	"aus-pam",
	scripts = Latn,
}

m["ylu"] = {
	"Aribwaung",
	"Q11044246",
	"poz-ocw",
	otherNames = {"Yalu", "Aribwaungg", "Jaloc"},
	scripts = Latn,
}

m["yly"] = {
	"ヤーラユ語",
	"Q303154",
	"poz-cln",
	scripts = Latn,
}

m["ymb"] = {
	"ヤンベス語",
	"Q8048022",
	"qfa-tor",
	scripts = Latn,
}

m["ymc"] = {
	"Southern Muji",
	nil,
	"tbq-lol",
}

m["ymd"] = {
	"Muda",
	"Q6931494",
	"tbq-lol",
}

m["yme"] = {
	"ヤメオ語",
	"Q3121032",
}

m["ymg"] = {
	"ヤモンゲリ語",
	"Q11008893",
	"bnt-mon",
	ancestors = {"lol"},
	scripts = Latn,
}

m["ymh"] = {
	"Mili",
	"Q12953329",
	"tbq-lol",
}

m["ymi"] = {
	"Moji",
	"Q6895060",
	"tbq-lol",
}

m["ymk"] = {
	"ベナ語",
	"Q6740513",
	"bnt-swh",
}

m["yml"] = {
	"ヤマレレ語",
	"Q8047849",
	"poz-ocw",
	scripts = Latn,
}

m["ymm"] = {
	"マアイ語",
	"Q36221",
	"cus",
	scripts = Latn,
}

m["ymn"] = {
	"Sunum",
	"Q8048083",
	"poz-ocw",
	otherNames = {"Yamna"},
	scripts = Latn,
}

m["ymo"] = {
	"Yangum Mon",
	nil,
	"qfa-tor",
	scripts = Latn,
}

m["ymp"] = {
	"ヤマプ語",
	"Q8047913",
	"poz-ocw",
	scripts = Latn,
}

m["ymq"] = {
	"Qila Muji",
	nil,
	"tbq-lol",
}

m["ymr"] = {
	"マラサル語",
	"Q16889525",
	"dra",
}

m["yms"] = {
	"Mysian",
	"Q2577228",
	"ine",
}

m["ymx"] = {
	"Northern Muji",
	nil,
	"tbq-lol",
}

m["ymz"] = {
	"Muzi",
	"Q6944445",
	"tbq-lol",
}

m["yna"] = {
	"Aluo",
	"Q4737539",
	"tbq-lol",
}

m["ynd"] = {
	"ヤンドゥルワンダ語",
	"Q8048335",
	"aus-kar",
	scripts = Latn,
}

m["yne"] = {
	"Lang'e",
	"Q6485577",
	"tbq-lol",
}

m["yng"] = {
	"Yango",
	"Q13123599",
	"nic-nkk",
	scripts = Latn,
}

m["ynk"] = {
	"ナウカン・ユピック語",
	"Q27963",
	"ypk",
	otherNames = {"Naukan Yupik", "Naukanski Yupik", "Naukan"},
	scripts = {"Cyrl", "Latn"},
}

m["ynl"] = {
	"ヤングラム語",
	"Q8048663",
	"ngf-mad",
}

m["ynn"] = {
	"ヤナ語",
	"Q56419",
	"qfa-iso",
}

m["yno"] = {
	"Yong",
	"Q8054978",
	"tai-swe",
}

m["yns"] = {
	"Yansi",
	"Q36953",
	"bnt-yak",
}

m["ynu"] = {
	"ヤウナ語",
	"Q8050347",
	"sai-tuc",
	otherNames = {"Yauna", "Yajuna"},
}

m["yob"] = {
	"ヨバ語",
	"Q8054220",
	"poz-ocw",
	scripts = Latn,
}

m["yog"] = {
	"ヨガド語",
	"Q8054343",
	"phi",
}

m["yoi"] = {
	"与那国語",
	"Q34243",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["yol"] = {
	"ヨーラ語",
	"Q56395",
	"gmw",
	scripts = Latn,
	ancestors = {"enm"},
}

m["yom"] = {
	"ヨンベ語",
	"Q10961975",
	"bnt-kng",
	scripts = Latn,
}

m["yon"] = {
	"Yongkom",
	"Q8055002",
	"ngf-okk",
}

m["yox"] = {
	"与論語",
	"Q2424943",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["yoy"] = {
	"ヨイ語",
	"Q3503717",
	"tai",
}

m["ypa"] = {
	"Phala",
	"Q36211907",
	"tbq-lol",
}

m["ypb"] = {
	"Labo Phowa",
	nil,
	"tbq-lol",
}

m["ypg"] = {
	"Phola",
	nil,
	"tbq-lol",
}

m["yph"] = {
	"Phupha",
	"Q7188378",
	"tbq-lol",
}

m["ypm"] = {
	"Phuma",
	nil,
	"tbq-lol",
}

m["ypn"] = {
	"Ani Phowa",
	"Q33590104",
	"tbq-lol",
}

m["ypo"] = {
	"Alo Phola",
	"Q33522157",
	"tbq-lol",
}

m["ypp"] = {
	"Phupa",
	"Q48565467",
	"tbq-lol",
}

m["ypz"] = {
	"Phuza",
	"Q48565339",
	"tbq-lol",
}

m["yra"] = {
	"イェラカイ語",
	"Q8052531",
}

m["yrb"] = {
	"ヤレバ語",
	"Q3571876",
	"ngf",
}

m["yre"] = {
	"ヤウレ語",
	"Q3913951",
	"dmn-mda",
}

m["yri"] = {
	"Yarí",
	"Q8049616",
}

m["yrk"] = {
	"ネネツ語",
	"Q36452",
	"syd",
	otherNames = {"Nenets", "Yurak"},
	scripts = {"Cyrl"},
	entry_name = {
		from = {"Ӑ", "ӑ", "[ӖЀ]", "[ӗѐ]", "[ӢЍ]", "[ӣѝ]", "Ӯ", "ӯ", BREVE, MACRON, GRAVE, ACUTE, DOTABOVE},
		to   = {"А", "а", "Е",    "е",    "И",    "и",    "У", "у"}},
}

m["yrl"] = {
	"ニェエンガトゥ語",
	"Q34333",
	"tup-gua",
	otherNames = {"Nhengatu", "Nyengatú", "Língua Geral", "Geral", "Yeral"},
}

m["yrn"] = {
	"耶容語",
	"Q3572191",
	"qfa-buy",
}

m["yro"] = {
	"Yaroamë",
	"Q24190396",
	"sai-ynm",
	otherNames = {"Jawari", "Jauari", "Yawari", "Joari", "Yoari"}, -- alt names shared with Ninam
	scripts = Latn,
}

m["yrw"] = {
	"ヤラワタ語",
	"Q8049237",
	"ngf-mad",
}

m["yry"] = {
	"Yarluyandi",
	"Q33061540",
	"aus-kar",
}

m["ysc"] = {
	"ヤシック語",
	"Q2479368",
	"xsc",
	otherNames = {"Yassic"},
	scripts = Latn,
	ancestors = {"oos"},
}

m["ysd"] = {
	"Samatao",
	"Q7408902",
	"tbq-lol",
	otherNames = {"Samu", "Eastern Samadu"},
}

m["ysg"] = {
	"Sonaga",
	"Q7560736",
	"tbq-lol",
}

m["ysl"] = {
	"ユーゴスラビア手話",
	"Q8060373",
	"sgn",
}

m["ysn"] = {
	"サニ語",
	"Q1055287",
	"tbq-lol",
	scripts = {"Yiii"},
}

m["yso"] = {
	"Nisi",
	"Q12953326",
	"sit-mnz",
}

m["ysp"] = {
	"Southern Lolopo",
	"Q12633989",
	"tbq-lol",
}

m["ysr"] = {
	"シレニック・ユピック語",
	"Q28156",
	"ypk",
	scripts = {"Cyrl"},
}

m["yss"] = {
	"イェッサン・マヨ語",
	"Q8052927",
	"paa-spk",
	otherNames = {"Yessan", "Mayo"},
	scripts = Latn,
}

m["ysy"] = {
	"サニエ語",
	"Q7418287",
	"tbq-lol",
}

m["yta"] = {
	"Talu",
	"Q16999095",
	"tbq-lol",
}

m["ytl"] = {
	"タンラン語",
	"Q7786695",
	"tbq-lol",
	otherNames = {"Tholo"},
}

m["ytp"] = {
	"Thopho",
	"Q7796015",
	"tbq-lol",
}

m["ytw"] = {
	"Yout Wam",
	nil,
	"ngf-fin",
	scripts = Latn,
}

m["yty"] = {
	"Yatay",
	nil,
	"aus-pmn",
}

m["yua"] = {
	"ユカテコ語",
	"Q13354",
	"myn",
	scripts = Latn,
}

m["yub"] = {
	"ユガンバル語",
	"Q3446663",
}

m["yuc"] = {
	"ユーチ語",
	"Q34204",
	"qfa-iso",
}

m["yud"] = {
	"アラビア語ユダヤ＝トリポリタニア方言",
	"Q56598",
	"sem-arb",
	scripts = {"Hebr"},
	ancestors = {"jrb"},
}

m["yue"] = {
	"広東語",
	"Q9186",
	"zhx",
	otherNames = {"Yue", "Yüeh"},
	scripts = {"Hani", "Latn"},
	wikimedia_codes = {"yue", "zh-yue"},
	ancestors = {"ltc"},
}

m["yuf"] = {
	"ハヴァスパイ＝ワラパイ＝ヤバパイ語",
	"Q3565286",
	"nai-yuc",
	scripts = Latn,
}

m["yug"] = {
	"ユグ語",
	"Q56311",
	"qfa-yen",
	otherNames = {"Yugh"},
}

m["yui"] = {
	"Yurutí",
	"Q3573266",
	"sai-tuc",
	scripts = Latn,
}

m["yuj"] = {
	"Karkar-Yuri",
	"Q2992906",
	"paa-pau",
	otherNames = {"Karkar", "Yuri"},
	scripts = Latn,
}

m["yuk"] = {
	"ユーキ語",
	"Q36993",
	otherNames = {"Huchnom"},
	scripts = Latn,
}

m["yul"] = {
	"ユル語",
	"Q3915595",
	"csu-bba",
}

m["yum"] = {
	"ケチャン語",
	"Q3573199",
	"nai-yuc",
	otherNames = {"Quechan", "Kwtsaan"},
	scripts = Latn,
}

m["yun"] = {
	"ベナ語",
	"Q3913283",
	"alv-yun",
	otherNames = {"Binna", "Buna", "Ebina", "Ebuna", "Gbinna", "Lala", "Purra", "Yangeru", "Yongor", "Yungur"},
}

m["yup"] = {
	"ユクパ語",
	"Q3441447",
	"sai-car",
	scripts = Latn,
}

m["yuq"] = {
	"ユキ語",
	"Q8061440",
	"tup-gua",
	otherNames = {"Yúki"},
	scripts = Latn,
}

m["yur"] = {
	"ユロック語",
	"Q34685",
	"aql",
	scripts = Latn,
}

m["yut"] = {
	"Yopno",
	"Q12953338",
	"ngf-fin",
	scripts = Latn,
}

m["yuw"] = {
	"ヤウ語",
	"Q12953319",
	"ngf-fin",
	otherNames = {"Yau"},
	scripts = Latn,
}

m["yux"] = {
	"コリマ・ユカギール語",
	"Q56545",
	"qfa-yuk",
	otherNames = {"Forest Yukaghir", "Kolyma Yukaghir"},
	scripts = {"Cyrl"},
	translit_module = "yux-translit",
}

m["yuy"] = {
	"東ユグル語",
	"Q29902",
	"xgn",
	otherNames = {"Eastern Yugur", "Shera Yugur"},
}

m["yuz"] = {
	"ユラカレ語",
	"Q2640646",
	"qfa-iso",
	scripts = Latn,
}

m["yva"] = {
	"Yawa",
	"Q3572020",
	"paa",
	otherNames = {"Yava"},
	scripts = Latn,
}

m["yvt"] = {
	"ヤビテーロ語",
	"Q3441427",
	"awd",
	otherNames = {"Yabitero", "Paraene"},
	scripts = Latn,
}

m["ywa"] = {
	"カロウ語",
	"Q6354305",
	"paa-spk",
	scripts = Latn,
}

m["ywg"] = {
	"Yinhawangka",
	"Q8053734",
	"aus-nga",
	scripts = Latn,
}

m["ywl"] = {
	"Western Lalu",
	"Q12953325",
	"tbq-lal",
}

m["ywn"] = {
	"ヤワナワ語",
	"Q10322118",
	"sai-pan",
	scripts = Latn,
}

m["ywq"] = {
	"Nasu",
	"Q25559456",
	"tbq-lol",
	otherNames = {"Wuding-Luquan Yi"},
	scripts = {"Plrd", "Yiii"},
}

m["ywr"] = {
	"ヤウル語",
	"Q8050479",
	"aus-nyu",
	scripts = Latn,
}

m["ywt"] = {
	"Xishanba Lalo",
	"Q12953336",
	"tbq-lal",
}

m["ywu"] = {
	"Wumeng Nasu",
	"Q25559442",
	"tbq-lol",
	otherNames = {"Wumeng Yi", "Wusa Yi"},
}

m["yww"] = {
	"ヤワラワルガ語",
	"Q10723454",
	"aus-kar",
	scripts = Latn,
}

m["yxa"] = {
	"Mayawali",
	"Q33060513",
	"aus-pam",
	scripts = Latn,
}

m["yxg"] = {
	"ヤガラ語",
	nil,
	"aus-pam",
	scripts = Latn,
}

m["yxl"] = {
	"Yarli",
	"Q46264708",
	"aus-pam",
	otherNames = {"Yardliyawarra", "Wadikali", "Malyangapa"},
	scripts = Latn,
}

m["yxm"] = {
	"Yinwum",
	"Q8053763",
	"aus-pam",
	scripts = Latn,
}

m["yxu"] = {
	"Yuyu",
	"Q8062232",
	"aus-pam",
	scripts = Latn,
}

m["yxy"] = {
	"Yabula Yabula",
	"Q8046394",
	"aus-pam",
	otherNames = {"Yabula-Yabula", "Jabulajabula"},
	scripts = Latn,
}

m["yyu"] = {
	"ヤウ語",
	"Q8050328",
	"qfa-tor",
	otherNames = {"Yau"},
	scripts = Latn,
}

m["yyz"] = {
	"Ayizi",
	"Q20527363",
	"tbq-lol",
}

m["yzg"] = {
	"峨馬布央語",
	"Q16115619",
	"qfa-buy",
}

m["yzk"] = {
	"Zokhuo",
	"Q8073523",
	"tbq-lol",
}

return m