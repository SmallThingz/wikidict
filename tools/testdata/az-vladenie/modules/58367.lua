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

m["yaa"] = {
	canonicalName = "Yaminahua",
	otherNames = {"Yaminawa"},
	family = "sai-pan",
}

m["yab"] = {
	canonicalName = "Yuhup",
}

m["yac"] = {
	canonicalName = "Pass Valley Yali",
}

m["yad"] = {
	canonicalName = "Yagua",
}

m["yae"] = {
	canonicalName = "Pumé",
	otherNames = {"Yaruro", "Yaruru", "Yuapín", "Pume"},
}

m["yaf"] = {
	canonicalName = "Yaka",
	otherNames = {"Yaka (Democratic Republic of the Congo)", "Kiyaka"}, -- distinguish from 'axk' and especially 'iyx'
	family = "bnt",
}

m["yag"] = {
	canonicalName = "Yámana",
	otherNames = {"Yagán", "Yahgan", "Yaghan"},
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["yah"] = {
	canonicalName = "Yazgulyam",
	family = "ira",
}

m["yai"] = {
	canonicalName = "Yagnobi",
	scripts = {"Latn", "Cyrl"},
	family = "ira",
	ancestors = {"sog"},
}

m["yaj"] = {
	canonicalName = "Banda-Yangere",
}

m["yak"] = {
	canonicalName = "Yakima",
	family = "nai-shp",
}

m["yal"] = {
	canonicalName = "Yalunka",
	otherNames = {"Jallonka", "Jalonke"},
}

m["yam"] = {
	canonicalName = "Yamba",
	family = "nic-bod",
}

m["yan"] = {
	canonicalName = "Mayangna",
	scripts = {"Latn"},
	family = "nai-min",
}

m["yao"] = {
	canonicalName = "Yao",
	scripts = {"Latn"},
	family = "bnt",
}

m["yap"] = {
	canonicalName = "Yapese",
	scripts = {"Latn"},
	family = "poz-oce",
}

m["yaq"] = {
	canonicalName = "Yaqui",
	otherNames = {"Hiaki", "Yoeme"},
	scripts = {"Latn"},
	family = "azc-trc",
}

m["yar"] = {
	canonicalName = "Yabarana",
	family = "sai-car",
}

m["yas"] = {
	canonicalName = "Gunu",
	otherNames = {"Nugunu"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["yat"] = {
	canonicalName = "Yambeta",
	family = "nic-bod",
}

m["yau"] = {
	canonicalName = "Yuwana",
}

m["yav"] = {
	canonicalName = "Yangben",
	family = "nic-bod",
}

m["yaw"] = {
	canonicalName = "Yawalapití",
	family = "awd",
}

m["yax"] = {
	canonicalName = "Yauma",
}

m["yay"] = {
	canonicalName = "Agwagwune",
	family = "nic-bco",
}

m["yaz"] = {
	canonicalName = "Lokaa",
	family = "nic-bco",
}

m["yba"] = {
	canonicalName = "Yala",
	family = "alv",
}

m["ybb"] = {
	canonicalName = "Yemba",
	family = "bai",
}

m["ybe"] = {
	canonicalName = "Western Yugur",
	family = "trk",
	ancestors = {"oui"},
}

m["ybh"] = {
	canonicalName = "Yakkha",
	family = "tbq",
}

m["ybi"] = {
	canonicalName = "Yamphu",
	family = "tbq",
}

m["ybj"] = {
	canonicalName = "Hasha",
}

m["ybk"] = {
	canonicalName = "Bokha",
	family = "tbq-lol",
}

m["ybl"] = {
	canonicalName = "Yukuben",
}

m["ybm"] = {
	canonicalName = "Yaben",
}

m["ybn"] = {
	canonicalName = "Yabaâna",
	family = "awd",
}

m["ybo"] = {
	canonicalName = "Yabong",
}

m["ybx"] = {
	canonicalName = "Yawiyo",
}

m["yby"] = {
	canonicalName = "Yaweyuha",
}

m["ych"] = {
	canonicalName = "Chesu",
	family = "tbq-lol",
}

m["ycl"] = {
	canonicalName = "Lolopo",
	family = "tbq-lol",
}

m["ycn"] = {
	canonicalName = "Yucuna",
	otherNames = {"Yukuna", "Yacuna", "Yakuna", "Jucuna", "Jukuna"},
	family = "awd",
}

m["ycp"] = {
	canonicalName = "Chepya",
	family = "tbq-lol",
}

m["yda"] = {
	canonicalName = "Yanda",
}

m["yde"] = {
	canonicalName = "Yangum Dey",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["ydg"] = {
	canonicalName = "Yidgha",
	family = "ira",
}

m["ydk"] = {
	canonicalName = "Yoidik",
}

m["yea"] = {
	canonicalName = "Ravula",
	family = "dra",
}

m["yec"] = {
	canonicalName = "Yeniche",
}

m["yee"] = {
	canonicalName = "Yimas",
}

m["yei"] = {
	canonicalName = "Yeni",
}

m["yej"] = {
	canonicalName = "Yevanic",
	scripts = {"Hebr"},
	family = "grk",
	ancestors = {"grc"},
}

m["yel"] = {
	canonicalName = "Yela",
}

m["yen"] = {
	canonicalName = "Yendang",
	otherNames = {"Yotti"},
	scripts = {"Latn"},
	family = "alv",
}

m["yer"] = {
	canonicalName = "Tarok",
	otherNames = {"Yergum", "Yergam"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["yes"] = {
	canonicalName = "Yeskwa",
	otherNames = {"Nyankpa"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["yet"] = {
	canonicalName = "Yetfa",
}

m["yeu"] = {
	canonicalName = "Yerukula",
	family = "dra",
}

m["yev"] = {
	canonicalName = "Yapunda",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["yey"] = {
	canonicalName = "Yeyi",
}

m["ygi"] = {
	canonicalName = "Yiningayi",
}

m["ygl"] = {
	canonicalName = "Yangum Gel",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["ygm"] = {
	canonicalName = "Yagomi",
	scripts = {"Latn"},
	family = "ngf-fin",
}

m["ygp"] = {
	canonicalName = "Gepo",
	family = "tbq-lol",
}

m["ygr"] = {
	canonicalName = "Yagaria",
	otherNames = {"Hua"},
	scripts = {"Latn"},
	family = "ngf",
}

m["ygs"] = {
	canonicalName = "Yolngu Sign Language",
	family = "sgn",
}

m["ygu"] = {
	canonicalName = "Yugul",
}

m["ygw"] = {
	canonicalName = "Yagwoia",
	scripts = {"Latn"},
}

m["yha"] = {
	canonicalName = "Baha",
	otherNames = {"Baha Buyang", "Paha"},
}

m["yhd"] = {
	canonicalName = "Judeo-Iraqi Arabic",
	scripts = {"Hebr"},
	family = "sem-arb",
	ancestors = {"acm"},
}

m["yhl"] = {
	canonicalName = "Hlepho Phowa",
	family = "tbq-lol",
}

m["yia"] = {
	canonicalName = "Yinggarda",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["yif"] = {
	canonicalName = "Ache",
	otherNames = {"Azhe"},
	family = "tbq-lol",
}

m["yig"] = {
	canonicalName = "Wusa Nasu",
	family = "tbq-lol",
}

m["yii"] = {
	canonicalName = "Yidiny",
	scripts = {"Latn"},
	family = "aus-yid",
}

m["yij"] = {
	canonicalName = "Yindjibarndi",
	scripts = {"Latn"},
	family = "aus-nga",
}

m["yik"] = {
	canonicalName = "Dongshanba Lalo",
	family = "tbq-lol",
}

m["yil"] = {
	canonicalName = "Yindjilandji",
	scripts = {"Latn"},
}

m["yim"] = {
	canonicalName = "Yimchungru Naga",
}

m["yin"] = {
	canonicalName = "Yinchia",
	family = "aav",
}

m["yip"] = {
	canonicalName = "Pholo",
}

m["yiq"] = {
	canonicalName = "Miqie",
	otherNames = {"Micha"},
	family = "tbq-lol",
}

m["yir"] = {
	canonicalName = "North Awyu",
}

m["yis"] = {
	canonicalName = "Yis",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["yit"] = {
	canonicalName = "Eastern Lalu",
	family = "tbq-lol",
}

m["yiu"] = {
	canonicalName = "Awu",
	otherNames = {"Lope"},
	family = "tbq-lol",
}

m["yiv"] = {
	canonicalName = "Northern Nisu",
	family = "tbq-lol",
}

m["yix"] = {
	canonicalName = "Axi Yi",
	family = "tbq-lol",
}

m["yiy"] = {
	canonicalName = "Yir-Yoront",
	otherNames = {"Yir Yoront", "Yirr-Yoront", "Yirr-Yorront", "Yirrk-Mel", "Yirrk-Thangalkl", "Yir Thangedl", "Yirr-Thangell"},
	scripts = {"Latn"},
}

m["yiz"] = {
	canonicalName = "Azhe",
	family = "tbq-lol",
}

m["yka"] = {
	canonicalName = "Yakan",
}

m["ykg"] = {
	canonicalName = "Northern Yukaghir",
	scripts = {"Cyrl"},
	family = "qfa-yuk",
}

m["yki"] = {
	canonicalName = "Yoke",
}

m["ykk"] = {
	canonicalName = "Yakaikeke",
}

m["ykl"] = {
	canonicalName = "Khlula",
	family = "tbq-lol",
}

m["ykm"] = {
	canonicalName = "Kap",
	otherNames = {"Yakamul", "Ali"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["ykn"] = {
	canonicalName = "Kua-nsi",
	family = "tbq-lol",
}

m["yko"] = {
	canonicalName = "Yasa",
	scripts = {"Latn"},
}

m["ykr"] = {
	canonicalName = "Yekora",
}

m["ykt"] = {
	canonicalName = "Kathu",
}

m["yku"] = {
	canonicalName = "Kuamasi",
	family = "tbq-lol",
}

m["yky"] = {
	canonicalName = "Yakoma",
	otherNames = {"Dendi", "Dendi (Central Africa)"}, -- Dendi is a dialect
	family = "nic-ubg",
}

m["yla"] = {
	canonicalName = "Yaul",
	family = "paa",
}

m["ylb"] = {
	canonicalName = "Yaleba",
}

m["yle"] = {
	canonicalName = "Yele",
}

m["ylg"] = {
	canonicalName = "Yelogu",
}

m["yli"] = {
	canonicalName = "Angguruk Yali",
}

m["yll"] = {
	canonicalName = "Yil",
	family = "qfa-tor",
}

m["ylm"] = {
	canonicalName = "Limi",
	family = "tbq-lol",
}

m["yln"] = {
	canonicalName = "Langnian Buyang",
}

m["ylo"] = {
	canonicalName = "Naluo Yi",
	family = "tbq-lol",
}

m["ylr"] = {
	canonicalName = "Yalarnnga",
}

m["ylu"] = {
	canonicalName = "Aribwaung",
	family = "poz-ocw",
}

m["yly"] = {
	canonicalName = "Nyâlayu",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["ymb"] = {
	canonicalName = "Yambes",
	family = "qfa-tor",
}

m["ymc"] = {
	canonicalName = "Southern Muji",
	family = "tbq-lol",
}

m["ymd"] = {
	canonicalName = "Muda",
	family = "tbq-lol",
}

m["yme"] = {
	canonicalName = "Yameo",
}

m["ymg"] = {
	canonicalName = "Yamongeri",
}

m["ymh"] = {
	canonicalName = "Mili",
	family = "tbq-lol",
}

m["ymi"] = {
	canonicalName = "Moji",
	family = "tbq-lol",
}

m["ymk"] = {
	canonicalName = "Makwe",
}

m["yml"] = {
	canonicalName = "Iamalele",
	family = "poz-ocw",
}

m["ymm"] = {
	canonicalName = "Maay",
	scripts = {"Latn"},
	family = "cus",
}

m["ymn"] = {
	canonicalName = "Sunum",
	otherNames = {"Yamna"},
	family = "poz-ocw",
}

m["ymo"] = {
	canonicalName = "Yangum Mon",
	family = "qfa-tor",
}

m["ymp"] = {
	canonicalName = "Yamap",
	family = "poz-ocw",
}

m["ymq"] = {
	canonicalName = "Qila Muji",
	family = "tbq-lol",
}

m["ymr"] = {
	canonicalName = "Malasar",
	family = "dra",
}

m["yms"] = {
	canonicalName = "Mysian",
	family = "ine",
}

m["ymx"] = {
	canonicalName = "Northern Muji",
	family = "tbq-lol",
}

m["ymz"] = {
	canonicalName = "Muzi",
	family = "tbq-lol",
}

m["yna"] = {
	canonicalName = "Aluo",
	family = "tbq-lol",
}

m["ynd"] = {
	canonicalName = "Yandruwandha",
	family = "aus-kar",
}

m["yne"] = {
	canonicalName = "Lang'e",
}

m["yng"] = {
	canonicalName = "Yango",
	family = "nic-ubg",
}

m["ynk"] = {
	canonicalName = "Naukanski",
	otherNames = {"Naukan Yupik", "Naukanski Yupik", "Naukan"},
	scripts = {"Cyrl", "Latn"},
	family = "ypk",
}

m["ynl"] = {
	canonicalName = "Yangulam",
}

m["ynn"] = {
	canonicalName = "Yana",
	family = "qfa-iso",
}

m["yno"] = {
	canonicalName = "Yong",
}

m["yns"] = {
	canonicalName = "Yansi",
}

m["ynu"] = {
	canonicalName = "Yahuna",
	otherNames = {"Yauna", "Yajuna"},
}

m["yob"] = {
	canonicalName = "Yoba",
	family = "poz-ocw",
}

m["yog"] = {
	canonicalName = "Yogad",
}

m["yoi"] = {
	canonicalName = "Yonaguni",
	scripts = {"Kana"},
	family = "jpx-ryu",
}

m["yol"] = {
	canonicalName = "Yola",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"enm"},
}

m["yom"] = {
	canonicalName = "Yombe",
	family = "bnt",
}

m["yon"] = {
	canonicalName = "Yongkom",
}

m["yox"] = {
	canonicalName = "Yoron",
}

m["yoy"] = {
	canonicalName = "Yoy",
}

m["ypa"] = {
	canonicalName = "Phala",
	family = "tbq-lol",
}

m["ypb"] = {
	canonicalName = "Labo Phowa",
	family = "tbq-lol",
}

m["ypg"] = {
	canonicalName = "Phola",
	family = "tbq-lol",
}

m["yph"] = {
	canonicalName = "Phupha",
	family = "tbq-lol",
}

m["ypm"] = {
	canonicalName = "Phuma",
	family = "tbq-lol",
}

m["ypn"] = {
	canonicalName = "Ani Phowa",
	family = "tbq-lol",
}

m["ypo"] = {
	canonicalName = "Alo Phola",
	family = "tbq-lol",
}

m["ypp"] = {
	canonicalName = "Phupa",
	family = "tbq-lol",
}

m["ypz"] = {
	canonicalName = "Phuza",
	family = "tbq-lol",
}

m["yra"] = {
	canonicalName = "Yerakai",
}

m["yrb"] = {
	canonicalName = "Yareba",
}

m["yre"] = {
	canonicalName = "Yaouré",
}

m["yri"] = {
	canonicalName = "Yarí",
}

m["yrk"] = {
	canonicalName = "Tundra Nenets",
	otherNames = {"Nenets", "Yurak"},
	scripts = {"Cyrl"},
	family = "syd",
}

m["yrl"] = {
	canonicalName = "Nhengatu",
	family = "tup",
}

m["yrn"] = {
	canonicalName = "Yerong",
}

m["yro"] = {
	canonicalName = "Yaroamë",
	otherNames = {"Jawari", "Jauari", "Yawari", "Joari", "Yoari"}, -- alt names shared with Ninam
	scripts = {"Latn"},
	family = "sai-ynm",
}

m["yrs"] = {
	canonicalName = "Yarsun",
	family = "poz-ocw",
}

m["yrw"] = {
	canonicalName = "Yarawata",
}

m["yry"] = {
	canonicalName = "Yarluyandi",
}

m["ysc"] = {
	canonicalName = "Yassic",
	otherNames = {"Jassic"},
	scripts = {"Latn"},
	family = "ira",
	ancestors = {"xln"},
}

m["ysd"] = {
	canonicalName = "Samatao",
	otherNames = {"Samu", "Eastern Samadu"},
	family = "tbq-lol",
}

m["ysg"] = {
	canonicalName = "Sonaga",
	family = "tbq-lol",
}

m["ysl"] = {
	canonicalName = "Yugoslavian Sign Language",
	family = "sgn",
}

m["ysn"] = {
	canonicalName = "Sani",
	scripts = {"Yiii"},
	family = "tbq-lol",
}

m["yso"] = {
	canonicalName = "Nisi",
}

m["ysp"] = {
	canonicalName = "Southern Lolopo",
	family = "tbq-lol",
}

m["ysr"] = {
	canonicalName = "Sirenik",
	scripts = {"Cyrl"},
	family = "ypk",
}

m["yss"] = {
	canonicalName = "Yessan-Mayo",
	otherNames = {"Yessan", "Mayo"},
	scripts = {"Latn"},
	family = "paa-spk",
}

m["ysy"] = {
	canonicalName = "Sanie",
	family = "tbq-lol",
}

m["yta"] = {
	canonicalName = "Talu",
	family = "tbq-lol",
}

m["ytl"] = {
	canonicalName = "Tanglang",
	otherNames = {"Tholo"},
	family = "tbq-lol",
}

m["ytp"] = {
	canonicalName = "Thopho",
	family = "tbq-lol",
}

m["ytw"] = {
	canonicalName = "Yout Wam",
	scripts = {"Latn"},
	family = "ngf-fin",
}

m["yty"] = {
	canonicalName = "Yatay",
}

m["yua"] = {
	canonicalName = "Yucatec Maya",
	scripts = {"Latn"},
	family = "myn",
}

m["yub"] = {
	canonicalName = "Yugambal",
}

m["yuc"] = {
	canonicalName = "Yuchi",
}

m["yud"] = {
	canonicalName = "Judeo-Tripolitanian Arabic",
	scripts = {"Hebr"},
	family = "sem-arb",
}

m["yue"] = {
	canonicalName = "Cantonese",
	otherNames = {"Yue", "Yüeh"},
	scripts = {"Hani"},
	family = "zhx",
	wikimedia_codes = {"zh-yue"},
	ancestors = {"ltc"},
}

m["yuf"] = {
	canonicalName = "Havasupai-Walapai-Yavapai",
	scripts = {"Latn"},
	family = "nai-yuc",
}

m["yug"] = {
	canonicalName = "Yug",
	otherNames = {"Yugh"},
}

m["yui"] = {
	canonicalName = "Yurutí",
	scripts = {"Latn"},
	family = "sai-tuc",
}

m["yuj"] = {
	canonicalName = "Karkar-Yuri",
	otherNames = {"Karkar", "Yuri"},
	scripts = {"Latn"},
}

m["yuk"] = {
	canonicalName = "Yuki",
	otherNames = {"Huchnom"},
	scripts = {"Latn"},
}

m["yul"] = {
	canonicalName = "Yulu",
}

m["yum"] = {
	canonicalName = "Yuma",
	otherNames = {"Quechan", "Kwtsaan"},
	scripts = {"Latn"},
	family = "nai-yuc",
}

m["yun"] = {
	canonicalName = "Bena",
	otherNames = {"Binna", "Buna", "Ebina", "Ebuna", "Gbinna", "Lala", "Purra", "Yangeru", "Yongor", "Yungur"},
}

m["yup"] = {
	canonicalName = "Yukpa",
	scripts = {"Latn"},
	family = "sai-car",
}

m["yuq"] = {
	canonicalName = "Yuqui",
	scripts = {"Latn"},
}

m["yur"] = {
	canonicalName = "Yurok",
	scripts = {"Latn"},
	family = "aql",
}

m["yut"] = {
	canonicalName = "Yopno",
	scripts = {"Latn"},
	family = "ngf-fin",
}

m["yuw"] = {
	canonicalName = "Finisterre Yau",
	otherNames = {"Yau"},
	scripts = {"Latn"},
	family = "ngf-fin",
}

m["yux"] = {
	canonicalName = "Southern Yukaghir",
	scripts = {"Cyrl"},
	family = "qfa-yuk",
}

m["yuy"] = {
	canonicalName = "East Yugur",
	otherNames = {"Shera Yugur"},
	family = "xgn",
}

m["yuz"] = {
	canonicalName = "Yuracare",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["yva"] = {
	canonicalName = "Yawa",
	otherNames = {"Yava"},
	scripts = {"Latn"},
}

m["yvt"] = {
	canonicalName = "Yavitero",
	otherNames = {"Yabitero", "Paraene"},
	scripts = {"Latn"},
	family = "awd",
}

m["ywa"] = {
	canonicalName = "Kalou",
	scripts = {"Latn"},
	family = "paa-spk",
}

m["ywg"] = {
	canonicalName = "Yinhawangka",
	scripts = {"Latn"},
	family = "aus-nga",
}

m["ywl"] = {
	canonicalName = "Western Lalu",
	family = "tbq-lol",
}

m["ywn"] = {
	canonicalName = "Yawanawa",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["ywq"] = {
	canonicalName = "Nasu",
	otherNames = {"Wuding-Luquan Yi"},
	scripts = {"Plrd", "Yiii"},
	family = "tbq-lol",
}

m["ywr"] = {
	canonicalName = "Yawuru",
	family = "aus-nyu",
}

m["ywt"] = {
	canonicalName = "Xishanba Lalo",
	family = "tbq-lol",
}

m["ywu"] = {
	canonicalName = "Wumeng Nasu",
	otherNames = {"Wumeng Yi", "Wusa Yi"},
	family = "tbq-lol",
}

m["yww"] = {
	canonicalName = "Yawarawarga",
	scripts = {"Latn"},
	family = "aus-kar",
}

m["yxa"] = {
	canonicalName = "Mayawali",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["yxg"] = {
	canonicalName = "Yagara",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["yxl"] = {
	canonicalName = "Yarli",
	otherNames = {"Yardliyawarra", "Wadikali", "Malyangapa"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["yxm"] = {
	canonicalName = "Yinwum",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["yxu"] = {
	canonicalName = "Yuyu",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["yxy"] = {
	canonicalName = "Yabula Yabula",
	otherNames = {"Yabula-Yabula", "Jabulajabula"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["yyu"] = {
	canonicalName = "Torricelli Yau",
	otherNames = {"Yau"},
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["yyz"] = {
	canonicalName = "Ayizi",
	family = "tbq-lol",
}

m["yzg"] = {
	canonicalName = "E'ma Buyang",
}

m["yzk"] = {
	canonicalName = "Zokhuo",
	family = "tbq-lol",
}

return m