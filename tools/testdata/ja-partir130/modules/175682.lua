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

m["haa"] = {
	"ハン語",
	"Q28272",
	"ath-nor",
	otherNames = {"Han", "Dawson", "Moosehide", "Han-Kutchin"},
	scripts = Latn,
}

m["hab"] = {
	"ハノイ手話",
	"Q12632107",
	"sgn",
	scripts = Latn, -- when documented
}

m["hac"] = {
	"グラニ語",
	"Q33733",
	"ira-zgr",
	otherNames = {"Gorani", "Avromani", "Awroman", "Awromani", "Hawramani", "Hawrami", "Hewrami", "Hourami", "Howrami", "Ourami"},
	scripts = {"ku-Arab"},
	translit_module = "ckb-translit",
}

m["had"] = {
	"ハタム語",
	"Q56825",
	"paa-wpa",
}

m["haf"] = {
	"ハイフォン手話",
	"Q39868240",
	"sgn",
}

m["hag"] = {
	"ハンガ語",
	"Q35426",
	"nic-dag",
	scripts = Latn,
}

m["hah"] = {
	"ハホン語",
	"Q3125730",
	"poz-ocw",
	scripts = Latn,
}

m["hai"] = {
	"Haida",
	"Q33303",
	"qfa-iso",
	scripts = Latn,
}

m["haj"] = {
	"ハジョン語",
	"Q3350576",
	"qfa-mix",
	scripts = {"as-Beng", "Latn"},
	ancestors = {"inc-oas", "tbq-pro"},
}

m["hak"] = {
	"客家語",
	"Q33375",
	"zhx",
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["hal"] = {
	"ハラン語",
	"Q56307",
	"mkh",
}

m["ham"] = {
	"ヘワ語",
	"Q5748345",
	"paa-spk",
}

m["hao"] = {
	"ハコ語",
	"Q3125871",
	"poz-ocw",
	scripts = Latn,
}

m["hap"] = {
	"Hupla",
	"Q5946223",
	"ngf",
}

m["har"] = {
	"ハラーリ語",
	"Q33626",
	"sem-eth",
	scripts = {"Ethi"},
	translit_module = "Ethi-translit",
}

m["has"] = {
	"ハイスラ語",
	"Q3107399",
	"wak",
}

m["hav"] = {
	"ハブ語",
	"Q5684097",
	"bnt-shh",
	scripts = Latn,
}

m["haw"] = {
	"ハワイ語",
	"Q33569",
	"poz-pep",
	scripts = Latn,
	sort_key = {
		from = {"ā", "ē", "ī", "ō", "ū" },
		to   = {"a", "e", "i", "o", "u" }} ,
}

m["hax"] = {
	"南部ハイダ語",
	"Q12953543",
	"qfa-iso",
	ancestors = {"hai"},
}

m["hay"] = {
	"ハヤ語",
	"Q35756",
	"bnt-haj",
}

m["haz"] = {
	"ハザラギ語",
	"Q33398",
	"ira-swi",
}

m["hba"] = {
	"Hamba",
	"Q11028905",
	"bnt-tet",
}

m["hbb"] = {
	"フバ語",
	"Q56290",
	"cdc-cbm",
	otherNames = {"Kilba"},
}

m["hbn"] = {
	"Heiban",
	"Q35523",
	"alv-hei",
}

m["hbu"] = {
	"Habu",
	"Q1567033",
	"poz-cet",
	scripts = Latn,
}

m["hca"] = {
	"Andaman Creole Hindi",
	"Q7599417",
	"crp",
	ancestors = {"hi", "bn", "ta"},
}

m["hch"] = {
	"ウイチョル語",
	"Q35575",
	"azc",
	scripts = Latn,
}

m["hdn"] = {
	"北部ハイダ語",
	"Q20054484",
	"qfa-iso",
	ancestors = {"hai"},
}

m["hds"] = {
	"ホンジュラス手話",
	"Q3915496",
	"sgn",
	otherNames = {"Honduran Sign Language"},
	scripts = Latn, -- when documented
}

m["hdy"] = {
	"ハディイヤ語",
	"Q56613",
	"cus",
}

m["hea"] = {
	"Northern Qiandong Miao",
	"Q3138832",
	"hmn",
	otherNames = {"Black Miao"},
}

m["hed"] = {
	"ヘルデ語",
	"Q56253",
	"cdc-mas",
}

m["heg"] = {
	"ヘロン語",
	"Q35432",
	"poz-tim",
	scripts = Latn,
}

m["heh"] = {
	"ヘヘ語",
	"Q3129390",
	"bnt-bki",
	scripts = Latn,
}

m["hei"] = {
	"ヘイルツク語",
	"Q5699507",
	"wak",
}

m["hem"] = {
	"ヘンバ語",
	"Q5711209",
	"bnt-lbn",
}

m["hgm"] = {
	"ハイコム語",
	"Q4494781",
	"khi-khk",
	scripts = Latn,
}

m["hgw"] = {
	"Haigwai",
	"Q5639108",
	"poz-ocw",
	scripts = Latn,
}

m["hhi"] = {
	"Hoia Hoia",
	"Q5877767",
	"ngf",
}

m["hhr"] = {
	"Kerak",
	"Q11010783",
	"alv-jfe",
}

m["hhy"] = {
	"Hoyahoya",
	nil,
	"ngf",
}

m["hia"] = {
	"ラマング語",
	"Q35700",
	"cdc-cbm",
	scripts = Latn,
}

m["hib"] = {
	"ヒビト語",
	"Q3135164",
}

m["hid"] = {
	"ヒダツァ語",
	"Q3135234",
	"sio-mor",
	scripts = Latn,
}

m["hif"] = {
	"フィジー・ヒンディー語",
	"Q46728",
	"inc-hie",
	scripts = Latn,
	ancestors = {"awa"},
}

m["hig"] = {
	"カムウェ語",
	"Q56271",
	"cdc-cbm",
	otherNames = {"Higgi", "Higi"},
}

m["hih"] = {
	"Pamosu",
	"Q12953011",
	"ngf-mad",
}

m["hii"] = {
	"ヒンドゥリ語",
	"Q5766763",
	"him",
}

m["hij"] = {
	"Hijuk",
	"Q35274",
	"bnt-bsa",
}

m["hik"] = {
	"Seit-Kaitetu",
	"Q7446989",
	"poz-cma",
}

m["hil"] = {
	"ヒリガイノン語",
	"Q35978",
	"phi",
	scripts = Latn,
	entry_name = {
		from = {"Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", MACRON},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["hio"] = {
	"Tshwa",
	"Q963636",
	"khi-kal",
	otherNames = {"Tsoa", "Kua", "Cua", "Hiechware", "Cirecire", "Cire-cire", "Cire-Cire", "Cire Cire"},
}

m["hir"] = {
	"Himarimã",
	"Q5765127",
}

m["hit"] = {
	"ヒッタイト語",
	"Q35668",
	"ine-ana",
	aliases = {"Hettite", "Kanesite", "Kaneshite", "Kanesian", "Kaneshian", "Nesian", "Neshian", "Nesite", "Nessite", "Neshite"},
	scripts = {"Xsux"},
}

m["hiw"] = {
	"ヒウ語",
	"Q3138713",
	"poz-vnc",
	scripts = Latn,
}

m["hix"] = {
	"イシュカリャナ語",
	"Q56522",
	"sai-car",
	otherNames = {"Hixkaryána"},
	scripts = Latn,
}

m["hji"] = {
	"Haji",
	"Q5639933",
	"poz-mly",
}

m["hka"] = {
	"カヘ語",
	"Q3892562",
	"bnt-chg",
	scripts = Latn,
}

m["hke"] = {
	"フンデ語",
	otherNames = "Hunde",
	"Q3065432",
	"bnt-shh",
	scripts = Latn,
}

m["hkk"] = {
	"Hunjara-Kaina Ke",
	nil,
	"ngf",
}

m["hkn"] = {
	"Mel-Khaonh",
	nil,
	"mkh-ban",
	otherNames = {"Mel", "Khaonh"},
}

m["hks"] = {
	"香港手話",
	"Q17038844",
	"sgn",
}

m["hla"] = {
	"ハリア語",
	"Q3125959",
	"poz-ocw",
	scripts = Latn,
}

m["hlb"] = {
	"ハルビ語",
	"Q3695692",
	"inc-eas",
	scripts = {"Deva", "Orya"},
	ancestors = {"inc-mgd"},
}

m["hld"] = {
	"Halang Doan",
	"Q3914632",
	"mkh-ban",
	otherNames = {"Duan", "Doan"},
}

m["hle"] = {
	"Hlersu",
	"Q5873537",
	"tbq-lol",
	otherNames = {"Sansu"},
}

m["hlt"] = {
	"Nga La",
	"Q12952942",
	"tbq-kuk",
	otherNames = {"Matu Chin", "Matu"},
}

m["hma"] = {
	"南部麻山フモン語",
	"Q12953560",
	"hmn",
	otherNames = {"Southern Mashan Miao"},
}

m["hmb"] = {
	"Humburi Senni",
	"Q35486",
	"son",
	otherNames = {"Central Songhay"},
}

m["hmc"] = {
	"中部恵水フモン語",
	"Q12953558",
	"hmn",
	otherNames = {"Central Huishui Miao"},
}

m["hmd"] = {
	"大花苗語",
	"Q1108934",
	"hmn",
	otherNames = {"A Hmao", "Big Flowery Miao", "Large Flowery Miao"},
	scripts = {"Latn", "Plrd"},
}

m["hme"] = {
	"東部恵水フモン語",
	"Q12953559",
	"hmn",
	otherNames = {"Eastern Huishui Miao"},
}

m["hmf"] = {
	"Hmong Don",
	"Q22911602",
	"hmn",
}

m["hmg"] = {
	"南西部貴陽フモン語",
	"Q27478542",
	"hmn",
}

m["hmh"] = {
	"南西部恵水フモン語",
	"Q12953565",
	"hmn",
	otherNames = {"Southwestern Huishui Miao"},
}

m["hmi"] = {
	"北部恵水フモン語",
	"Q27434946",
	"hmn",
	otherNames = {"Northern Huishui Miao"},
}

m["hmj"] = {
	"Ge",
	"Q11251864",
	"hmn",
	otherNames = {"Gedou Miao"},
}

m["hmk"] = {
	"貊語",
	"Q8050724",
	"qfa-kor",
	otherNames = {"Ye-Maek", "Yemaek"},
}

m["hml"] = {
	"羅泊河フモン語",
	"Q14468943",
	"hmn",
}

m["hmm"] = {
	"中部麻山フモン語",
	"Q12953561",
	"hmn",
	otherNames = {"Central Mashan Miao"},
}

m["hmp"] = {
	"北部麻山フモン語",
	"Q12953564",
	"hmn",
	otherNames = {"Northern Mashan Miao"},
}

m["hmq"] = {
	"東部黔東苗語",
	"Q27431369",
	"hmn",
	otherNames = {"Black Miao"},
}

m["hmr"] = {
	"フマール語",
	"Q2992841",
	"tbq-kuk",
	ancestors = {"lus"},
}

m["hms"] = {
	"南部黔東苗語",
	"Q12953562",
	"hmn",
	otherNames = {"Black Miao"},
}

m["hmt"] = {
	"ハムタイ語",
	"Q5646436",
	"ngf",
	otherNames = {"Kapau"},
}

m["hmu"] = {
	"ハマップ語",
	"Q12952484",
	"qfa-tap",
}

m["hmv"] = {
	"Hmong Dô",
	"Q22911598",
	"hmn",
	otherNames = {"Hmong Do"},
}

m["hmw"] = {
	"西部麻山フモン語",
	"Q12953563",
	"hmn",
	otherNames = {"Western Mashan Miao"},
}

m["hmy"] = {
	"南部貴陽フモン語",
	"Q12953553",
	"hmn",
}

m["hmz"] = {
	"Hmong Shua",
	"Q25559603",
	"hmn",
	otherNames = {"Hmong Sua"},
}

m["hna"] = {
	"ミナ語",
	"Q56532",
	"cdc-cbm",
	otherNames = {"Mina (Cameroon)", "Hina", "Besleri"},
}

m["hnd"] = {
	"南部ヒンドコ語",
	"Q382273",
	"inc-pan",
	ancestors = {"lah"},
}

m["hne"] = {
	"チャッティースガリー語",
	"Q33158",
	"inc-hie",
	scripts = {"Deva"},
	ancestors = {"inc-pra"},
}

m["hnh"] = {
	"ǁAni",
	"Q3832982",
	"khi-kal",
	scripts = {"Latinx"},
}

m["hni"] = {
	"ハニ語",
	"Q56516",
	"tbq-lol",
}

m["hnj"] = {
	"フモン・ジュア語",
	"Q3138831",
	"hmn",
	otherNames = {"Hmong Njua", "Hmong Leng", "Mong Leng", "Green Miao", "Blue Hmong"},
	scripts = {"Latn", "Hmng"},
}

m["hnm"] = {
	"海南語",
	"Q934541",
	"zhx-nan",
	"Hants",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["hnn"] = {
	"ハヌノオ語",
	"Q35435",
	"phi",
	otherNames = {"Hanuno'o"},
	scripts = {"Hano", "Latn"},
}

m["hno"] = {
	"北部ヒンドコ語",
	"Q6346358",
	"inc-pan",
	otherNames = {"Kagani", "Hazara Hindko", "Hindki of Hazara"},
	scripts = {"Arab"},
	ancestors = {"lah"},
}

m["hns"] = {
	"カリブ・ヒンドゥスターニー語",
	"Q1843468",
	"inc-hie",
	otherNames = {"Caribbean Bhojpuri"},
	ancestors = {"bho"},
}

m["hnu"] = {
	"フン語",
	"Q12632753",
	"mkh-vie",
}

m["hoa"] = {
	"Hoava",
	"Q3138887",
	"poz-ocw",
	scripts = Latn,
}

m["hob"] = {
	"マリ語",
	"Q6760941",
	"poz-ocw",
	otherNames = {"Mari (Madang Province)", "Hop"},
	scripts = Latn,
}

m["hoc"] = {
	"ホー語",
	"Q33270",
	"mun",
	scripts = {"Wara", "Orya", "Deva", "Latn"},
}

m["hod"] = {
	"ホルマ語",
	"Q56331",
	"cdc",
	scripts = Latn,
}

m["hoe"] = {
	"ホロム語",
	"Q3914008",
	"nic-ple",
	scripts = Latn,
}

m["hoh"] = {
	"ホブヨート語",
	"Q33299",
	"sem-sar",
	scripts = {"Arab", "Latn"},
}

m["hoi"] = {
	"ホリカチャック語",
	"Q28508",
	"ath-nor",
	scripts = Latn,
}

m["hoj"] = {
	"Hadothi",
	"Q33227",
	"inc-wes",
	otherNames = {"Harauti"},
	ancestors = {"mwr"},
}

m["hol"] = {
	"ホル語",
	"Q4121133",
	"bnt-pen",
	scripts = Latn,
}

m["hom"] = {
	"ホマ語",
	"Q3449953",
	"bnt-boa",
	scripts = Latn,
}

m["hoo"] = {
	"ホロホロ語",
	otherNames = "Holoholo",
	"Q3139484",
	"bnt-tkm",
	scripts = Latn,
}

m["hop"] = {
	"ホピ語",
	"Q56421",
	"azc",
	otherNames = {"Moqui"},
	scripts = Latn,
}

m["hor"] = {
	"ホロ語",
	"Q641748",
	"csu-sar",
}

m["hos"] = {
	"ホーチミン市手話",
	"Q16111971",
	"sgn",
	scripts = Latn, -- when documented
}

m["hot"] = {
	"ホテ語",
	"Q12632404",
	"poz-ocw",
	scripts = Latn,
}

m["hov"] = {
	"ホヴォガン語",
	"Q5917269",
	"poz",
}

m["how"] = {
	"Honi",
	"Q56842",
	"tbq-lol",
	otherNames = {"Haoni", "Baihong", "Hao-Bai", "Ho"},
}

m["hoy"] = {
	"Holiya",
	"Q5880707",
	"dra",
}

m["hoz"] = {
	"ホゾ語",
	"Q5923010",
	"omv-mao",
}

m["hpo"] = {
	"ポン語",
	"Q5923277",
	"tbq-brm",
}

m["hps"] = {
	"ハワイ手話",
	"Q33358",
	"sgn",
	otherNames = {"Hawaiian Sign Language", "Hula", "Hawaii Sign Language"},
	scripts = Latn, -- when documented
}

m["hra"] = {
	"Hrangkhol",
	"Q5923435",
	"tbq-kuk",
}

m["hrc"] = {
	"Niwer Mil",
	nil,
	"poz-oce",
	otherNames = {"Tangga"}, -- this variety of Tangga macrolanguage is on Tangga island
	scripts = Latn,
}

m["hre"] = {
	"フレー語",
	"Q3915794",
	"mkh-nbn",
	otherNames = {"Hrê"},
}

m["hrk"] = {
	"ハルク語",
	"Q5675762",
	"poz-cma",
}

m["hrm"] = {
	"角苗語",
	nil,
	"hmn",
}

m["hro"] = {
	"ハロイ語",
	"Q3127568",
	"cmc",
	scripts = Latn,
}

m["hrp"] = {
	"Nhirrpi",
	"Q32571318",
	"aus-kar",
}

m["hrt"] = {
	"ヘルテヴィン語",
	"Q33290",
	"sem-nna",
	scripts = Latn,
}

m["hru"] = {
	"Hruso",
	"Q5923933",
	"sit-hrs",
}

m["hrw"] = {
	"Warwar Feni",
	nil,
	"poz-oce",
	otherNames = {"Feni"},
	scripts = Latn,
}

m["hrx"] = {
	"フンスリク語",
	"Q304049",
	"gmw",
	otherNames = {"Riograndenser Hunsrückisch"},
	scripts = Latn,
	ancestors = {"gmw-cfr"},
}

m["hrz"] = {
	"ハルザニ語",
	"Q56464",
	"xme-ttc",
	otherNames = {"Harzandi"},
	ancestors = {"xme-ttc-nor"},
}

m["hsb"] = {
	"高地ソルブ語",
	"Q13248",
	"wen",
	aliases = {"Upper Lusatian", "Upper Wendish"},
	scripts = Latn,
	sort_key = {
		from = {"č",  "ć",   "ě",  "ch", "ł",  "ń",  "ó", "ř",  "š",  "ž",  "ź"    },
		to   = {"c~", "c~~", "e~", "h~", "l`", "n~", "o", "r~", "s~", "z~", "z~~" }} , --the digraph ch comes after h; ł comes before l
}

m["hsh"] = {
	"ハンガリー手話",
	"Q13636869",
	"sgn",
	scripts = Latn, -- when documented
}

m["hsl"] = {
	"ハウサ手話",
	"Q3915462",
	"sgn",
	scripts = Latn, -- when documented
}

m["hsn"] = {
	"湘語",
	"Q13220",
	"zhx",
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["hss"] = {
	"ハルスースィ語",
	"Q33423",
	"sem-sar",
	scripts = {"Arab", "Latn"},
}

m["hti"] = {
	"ホティ語",
	"Q5912372",
	"poz-cma",
	scripts = Latn,
}

m["hto"] = {
	"ミニカ・ウィトト語",
	"Q948514",
	"sai-wit",
	otherNames = {"Minica", "Minica Witoto"},
	scripts = Latn,
}

m["hts"] = {
	"ハヅァ語",
	"Q33411",
	"qfa-iso",
	scripts = Latn,
}

m["htu"] = {
	"ヒツ語",
	"Q5872700",
	"poz-cma",
	scripts = Latn,
}

m["hub"] = {
	"ワンビサ語",
	"Q1526037",
	"sai-jiv",
	otherNames = {"Huambiza", "Wambisa"},
	scripts = Latn,
}

m["huc"] = {
	"フア語",
	"Q2053913",
	"khi-kxa",
	otherNames = {"ǂ’Amkoe", "ǂHȍã", "ǂHȍȁn"},
	scripts = {"Latinx"},
}

m["hud"] = {
	"Huaulu",
	"Q12952504",
	"poz-cma",
	scripts = Latn,
}

m["huf"] = {
	"フメネ語",
	"Q11732231",
	"ngf",
	scripts = Latn,
}

m["hug"] = {
	"ワチパイリ語",
	"Q3446617",
	"sai-har",
	scripts = Latn,
}

m["huh"] = {
	"ウィジチェ語",
	"Q35531",
	"sai-ara",
	scripts = Latn,
}

m["hui"] = {
	"フリ語",
	"Q3125121",
	"paa-eng",
	scripts = Latn,
}

m["huj"] = {
	"北部貴陽フモン語",
	"Q12953554",
	"hmn",
}

m["huk"] = {
	"フルン語",
	"Q12952505",
	"poz-cet",
}

m["hul"] = {
	"フラ語",
	"Q6382179",
	"poz-ocw",
	scripts = Latn,
}

m["hum"] = {
	"Hungana",
	"Q10975396",
	"bnt-yak",
}

m["huo"] = {
	"フ語",
	"Q3141783",
	"mkh-pal",
}

m["hup"] = {
	"フーパ語",
	"Q28058",
	"ath-pco",
	scripts = Latn,
}

m["huq"] = {
	"回輝語",
	"Q34133",
	"cmc",
	otherNames = {"Hainan Cham", "Hui", "Huihui", "Sanya Hui", "Utsat", "Utset"},
}

m["hur"] = {
	"ハルコメレム語",
	"Q35388",
	"sal",
	scripts = Latn,
}

m["hus"] = {
	"ワステカ語",
	"Q35573",
	"myn",
	otherNames = {"Huastek", "Huasteka", "Huasteque", "Huaxteca", "Huaxteco", "Huaxteque", "Huastecan"},
	scripts = Latn,
}

m["huu"] = {
	"ムルイ・ウィトト語",
	"Q2640935",
	"sai-wit",
	otherNames = {"Murui", "Murui Witoto"},
	scripts = Latn,
}

m["huv"] = {
	"サン・マテオ・デル・マル・ワベ語",
	"Q12954031",
	"qfa-iso",
	otherNames = {"San Mateo del Mar Huave", "San Dionisio del Mar Huave", "Santa María del Mar Huave", "San Francisco del Mar Huave"},
	scripts = Latn,
}

m["huw"] = {
	"Hukumina",
	"Q3142988",
	"poz-cma",
	otherNames = {"Palumata"},
	scripts = Latn,
}

m["hux"] = {
	"ニポデ・ウィトト語",
	"Q56333",
	"sai-wit",
	otherNames = {"Nüpode", "Nüpode Witoto"},
	scripts = Latn,
}

m["huy"] = {
	"ハラウラ語",
	"Q33426",
	"sem-nna",
}

m["huz"] = {
	"フンズィブ語",
	"Q56564",
	"cau-tsz",
	scripts = {"Cyrl"},
	translit_module = "huz-translit",
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["hvc"] = {
	"Haitian Vodoun Culture Language",
	"Q3504239",
	"crp",
	otherNames = {"Langaj", "Langay"},
	scripts = Latn,
}

m["hvk"] = {
	"ハヴェケ語",
	"Q5683513",
	"poz-cln",
	scripts = Latn,
}

m["hvn"] = {
	"サボ語",
	"Q3128792",
	"poz-cet",
	otherNames = {"Savu"},
	scripts = Latn,
}

m["hwa"] = {
	"グワネ語",
	"Q3914887",
	"kro-ekr",
	scripts = Latn,
}

m["hwc"] = {
	"ハワイ・ピジン語",
	"Q35602",
	"crp",
	otherNames = {"Hawaiian Creole English", "Hawai'ian Creole English", "Hawaiian Pidgin", "Hawai'ian Creole"},
	scripts = Latn,
}

m["hwo"] = {
	"フヮナ語",
	"Q56498",
	"cdc-cbm",
	scripts = Latn,
}

m["hya"] = {
	"ヒャ語",
	"Q56798",
	"cdc-cbm",
	scripts = Latn,
}

return m