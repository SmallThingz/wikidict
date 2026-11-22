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

m["taa"] = {
	"下タナナ語",
	"Q28565",
	"ath-nor",
	otherNames = {"Tanana", "Middle Tanana"},
	scripts = Latn,
}

m["tab"] = {
	"タバサラン語",
	"Q34079",
	"cau-lzg",
	otherNames = {"Tabassaran"},
	scripts = {"Cyrl"},
	translit_module = "tab-translit",
	override_translit = true,
	entry_name = {
		from = {ACUTE},
		to   = {}} ,
}

m["tac"] = {
	"低地タラフマラ語",
	"Q15616384",
	"azc-trc",
	scripts = Latn,
}

m["tad"] = {
	"Tause",
	"Q2356440",
	"paa-lkp",
	scripts = Latn,
}

m["tae"] = {
	"タリアナ語",
	"Q732726",
	"awd-nwk",
	scripts = Latn,
}

m["taf"] = {
	"タピラペ語",
	"Q7684673",
	"tup-gua",
	scripts = Latn,
}

m["tag"] = {
	"タゴイ語",
	"Q36537",
	"nic-ras",
	scripts = Latn,
}

m["taj"] = {
	"東部タマン語",
	"Q12953177",
	"sit-tam",
	scripts = {"Deva"},
}

m["tak"] = {
	"Tala",
	"Q3914494",
	"cdc-wst",
	scripts = Latn,
}

m["tal"] = {
	"タル語",
	"Q3440387",
	"cdc-wst",
	scripts = Latn,
}

m["tan"] = {
	"タンカレ語",
	"Q529921",
	"cdc-wst",
	scripts = Latn,
}

m["tao"] = {
	"ヤミ語",
	"Q715760",
	"phi",
	otherNames = {"Tao"},
	scripts = Latn,
}

m["tap"] = {
	"ターブワ語",
	"Q7673650",
	"bnt-sbi",
	scripts = Latn,
}

m["taq"] = {
	"タマシェク語",
	"Q4670066",
	"ber",
	scripts = {"Tfng", "Arab", "Latn"},
	ancestors = {"tmh"},
}

m["tar"] = {
	"中部タラフマラ語",
	"Q20090009",
	"azc-trc",
	scripts = Latn,
	sort_key = {
		from = {"á", "é", "í", "ó", "ú", "ꞌ"},
		to   = {"a", "e", "i", "o", "u"}
	},
}

m["tas"] = {
	"タイ・ボイ語",
	"Q2233794",
	"crp",
	otherNames = {"Tay Boi Pidgin French", "Vietnamese Pidgin French"},
	scripts = Latn,
	ancestors = {"fr"},
}

m["tau"] = {
	"高地タナナ語",
	"Q28281",
	"ath-nor",
	otherNames = {"Tabesna", "Nabesna"},
	scripts = Latn,
}

m["tav"] = {
	"タトゥジョ語",
	"Q2524007",
	"sai-tuc",
	scripts = Latn,
}

m["taw"] = {
	"Tai",
	"Q7675861",
	"ngf-mad",
	scripts = Latn,
}

m["tax"] = {
	"Tamki",
	"Q3449082",
	"cdc",
	scripts = Latn,
}

m["tay"] = {
	"タイヤル語",
	"Q715766",
	"map-ata",
	scripts = Latn,
}

m["taz"] = {
	"Tocho",
	"Q36680",
	"alv-tal",
	scripts = Latn,
}

m["tba"] = {
	"アイカナ語",
	"Q3409307",
	"qfa-iso",
}

m["tbb"] = {
	"Tapeba",
	"Q12953908",
}

m["tbc"] = {
	"タキア語",
	"Q3514336",
	"poz-oce",
}

m["tbd"] = {
	"Kaki Ae",
	"Q6349417",
	"poz-ocw",
	scripts = Latn,
}

m["tbe"] = {
	"Tanimbili",
	"Q3515188",
	"poz-oce",
	scripts = Latn,
}

m["tbf"] = {
	"マンダラ語",
	"Q3285424",
	"poz-ocw",
	scripts = Latn,
}

m["tbg"] = {
	"北タイロラ語",
	"Q20210398",
	"paa-kag",
}

m["tbh"] = {
	"Thurawal",
	"Q3537135",
	"aus-yuk",
}

m["tbi"] = {
	"ガム語",
	"Q35338",
	"sdv-eje",
	otherNames = {"Ingessana", "Gaahmg"},
	scripts = Latn,
}

m["tbj"] = {
	"Tiang",
	"Q3528020",
	"poz-ocw",
	scripts = Latn,
}

m["tbk"] = {
	"カラミアン=タグバンワ語",
	"Q3915487",
	"phi-kal",
}

m["tbl"] = {
	"トボリ語",
	"Q7690594",
	"phi",
}

m["tbm"] = {
	"タグブ語",
	"Q7675188",
	"nic-ser",
}

m["tbn"] = {
	"バロ・ネグロ・トゥネボ語",
	"Q12953943",
	"cba",
}

m["tbo"] = {
	"Tawala",
	"Q7689206",
	"poz-ocw",
	scripts = Latn,
}

m["tbp"] = {
	"タウォルタ語",
	"Q7689337",
	"paa-lkp",
	otherNames = {"Diebroud", "Dabra"},
	scripts = Latn,
}

m["tbr"] = {
	"トゥムトゥム語",
	"Q3407029",
	"qfa-kad",
}

m["tbs"] = {
	"タングアト語",
	"Q7683166",
	"paa",
	scripts = Latn,
}

m["tbt"] = {
	"テンボ語",
	"Q13123561",
	"bnt-shh",
	otherNames = {"Tembo"},
	scripts = Latn,
}

m["tbu"] = {
	"トゥバル語",
	"Q56730",
	"azc-trc",
	otherNames = {"Tubare"},
	scripts = Latn,
}

m["tbv"] = {
	"トボ語",
	"Q7811712",
	"ngf",
}

m["tbw"] = {
	"タグバンワ語",
	"Q3915475",
	"phi",
	scripts = Latn,
}

m["tbx"] = {
	"カピン語",
	"Q6366665",
	"poz-ocw",
	otherNames = {"Middle Watut"},
	scripts = Latn,
}

m["tby"] = {
	"タバル語",
	"Q11732670",
	"paa-wpa",
}

m["tbz"] = {
	"Ditammari",
	"Q35186",
	"nic-eov",
}

m["tca"] = {
	"チクーナ語",
	"Q1815205",
	"sai-tyu",
	otherNames = {"Tikuna"},
	scripts = Latn,
}

m["tcb"] = {
	"タナクロス語",
	"Q28268",
	"ath-nor",
	scripts = Latn,
}

m["tcc"] = {
	"ダトーガ語",
	"Q35327",
	"sdv-nis",
	scripts = Latn,
}

m["tcd"] = {
	"タフィ語",
	"Q36545",
	"alv-ktg",
}

m["tce"] = {
	"南部トゥトチョネ語",
	"Q31091048",
	"ath-nor",
	scripts = Latn,
}

m["tcf"] = {
	"マリナルテペック・メパー語",
	"Q25559732",
	"omq",
	scripts = Latn,
}

m["tcg"] = {
	"タマガリオ語",
	"Q7680531",
	"ngf",
}

m["tch"] = {
	"タークス・カイコス諸島クリオール語",
	"Q7855478",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["tci"] = {
	"ワラ語",
	"Q20825638",
	"paa-yam",
}

m["tck"] = {
	"Tchitchege",
	"Q36595",
	"bnt-tek",
}

m["tcl"] = {
	"タマン語",
	"Q15616518",
	"sit-jnp",
	otherNames = {"Taman", "Taman (Myanmar)"},
	scripts = Latn,
}

m["tcm"] = {
	"タナーメラー語",
	"Q3514927",
	"ngf",
}

m["tco"] = {
	"タウンヨー語",
	"Q12953186",
	"tbq-brm",
	ancestors = {"obr"},
}

m["tcp"] = {
	"Tawr Chin",
	"Q7689338",
	"tbq-kuk",
	otherNames = {"Tawr"},
}

m["tcq"] = {
	"Kaiy",
	"Q6348709",
	"paa-lkp",
}

m["tcs"] = {
	"トレス海峡諸島クレオール語",
	"Q36648",
	"crp",
	otherNames = {"Big Thap", "Blaikman", "Brokan", "Broken", "Broken English", "Cape York Creole", "Lockhart Creole", "Papuan Pidgin English", "Torres Strait Brokan", "Torres Strait Broken", "Torres Strait Pidgin", "Yumplatok"},
	scripts = Latn,
	ancestors = {"en"},
}

m["tct"] = {
	"テン語",
	"Q3442330",
	"qfa-kms",
}

m["tcu"] = {
	"南東部タラフマラ語",
	"Q36807",
	"azc-trc",
	scripts = Latn,
}

m["tcw"] = {
	"Tecpatlán Totonac",
	"Q7692795",
	"nai-ttn",
	scripts = Latn,
}

m["tcx"] = {
	"トダ語",
	"Q34042",
	"dra",
}

m["tcy"] = {
	"トゥル語",
	"Q34251",
	"dra",
	scripts = {"Knda"},
	translit_module = "kn-translit",
}

m["tcz"] = {
	"タドー・チン語",
	"Q6583558",
	"tbq-kuk",
	otherNames = {"Thado"},
}

m["tda"] = {
	"Tagdal",
	"Q36570",
	"son",
}

m["tdb"] = {
	"Panchpargania",
	"Q21946879",
	"inc-eas",
	ancestors = {"bh"},
}

m["tdc"] = {
	"エンベラ＝タード語",
	"Q3052041",
	"sai-chc",
}

m["tdd"] = {
	"タイ・ヌア語",
	"Q36556",
	"tai-swe",
	aliases = {"Tai Nuea", "Dehong Dai", "Tai Dehong", "Tai Le", "Chinese Shan", "Chinese Tai"},
	scripts = {"Tale"},
	translit_module = "Tale-translit",
}

m["tde"] = {
	"Tiranige Diga Dogon",
	"Q5313387",
	"nic-dgw",
}

m["tdf"] = {
	"タリアン語",
	"Q37525108",
	"mkh-ban",
	otherNames = {"Taliang", "Tariang", "Kasseng"},
}

m["tdg"] = {
	"Western Tamang",
	"Q12953178",
	"sit-tam",
}

m["tdh"] = {
	"トゥルン語",
	"Q56553",
	"sit-kiw",
}

m["tdi"] = {
	"トマディノ語",
	"Q7818197",
	"poz-btk",
	scripts = Latn,
}

m["tdj"] = {
	"Tajio",
	"Q7676870",
	"poz",
}

m["tdk"] = {
	"タンバス語",
	"Q3440392",
	"cdc-wst",
}

m["tdl"] = {
	"スル語",
	"Q3914453",
	"nic-tar",
	otherNames = {"Tapshin"},
}

m["tdm"] = {
	"Taruma",
	nil,
	otherNames = {"Taruamá"},
}

m["tdn"] = {
	"トンダノ語",
	"Q3531514",
	"phi",
}

m["tdo"] = {
	"テメ語",
	"Q3913994",
	"alv-mye",
}

m["tdq"] = {
	"ティタ語",
	"Q3914899",
	"nic-bco",
}

m["tdr"] = {
	"トドラ語",
	"Q7812881",
	"mkh",
}

m["tds"] = {
	"Doutai",
	"Q5302331",
	"paa-lkp",
	otherNames = {"Taori"},
}

m["tdt"] = {
	"テトゥン・ディリ語",
	"Q12643484",
	"crp",
	otherNames = {"Tetum Dili", "Tetun Prasa", "Tétum Praça", "Tetun-Dili", "Tetun-Prasa"},
	scripts = Latn,
	ancestors = {"tet"},
}

m["tdu"] = {
	"テンパスク・ドゥスン語",
	"Q3529155",
	"poz-san",
}

m["tdv"] = {
	"トーロ語",
	"Q3438367",
	"nic-alu",
}

m["tdy"] = {
	"タジャワン語",
	"Q7674700",
	"phi",
}

m["tea"] = {
	"テミアル語",
	"Q3914693",
	"mkh-asl",
}

m["teb"] = {
	"テテテ語",
	"Q7706087",
	"sai-tuc",
	scripts = Latn,
}

m["tec"] = {
	"テリック語",
	"Q3518379",
	"sdv-nma",
}

m["ted"] = {
	"Tepo Krumen",
	"Q11152243",
	"kro-grb",
}

m["tee"] = {
	"ウエウエトラ・テペワ語",
	"Q56455",
	"nai-ttn",
}

m["tef"] = {
	"テレッサ語",
	"Q3518362",
	"aav-nic",
}

m["teg"] = {
	"Teke-Tege",
	"Q36478",
	"bnt-tek",
}

m["teh"] = {
	"テウェルチェ語",
	"Q33930",
	"sai-cho",
	otherNames = {"Patagón", "Chon", "Chon Patagón", "Chon Patagon", "Aoniken", "Aonikenk", "Inaquen", "Aonek'o 'ajen"},
}

m["tei"] = {
	"トリチェリ語",
	"Q3450788",
	"qfa-tor",
}

m["tek"] = {
	"Ibali Teke",
	"Q2802914",
	"bnt-tek",
}

m["tem"] = {
	"テムネ語",
	"Q36613",
	"alv-mel",
	otherNames = {"Temne", "Themne", "Timne", "KaThemne"},
}

m["ten"] = {
	"Tama (Colombia)",
	"Q3832969",
	"sai-tuc",
	otherNames = {"Tama"},
}

m["teo"] = {
	"テソ語",
	otherNames = {"Ateso", "Teso"},
	"Q29474",
	"sdv-ttu",
	scripts = Latn,
}

m["tep"] = {
	"テペカノ語",
	"Q3915525",
	"azc",
	scripts = Latn,
}

m["teq"] = {
	"テメイン語",
	"Q7698064",
	"sdv",
}

m["ter"] = {
	"テレノ語",
	"Q3314742",
	"awd",
	scripts = Latn,
}

m["tes"] = {
	"トゥングル語",
	"Q12473479",
	"poz",
}

m["tet"] = {
	"テトゥン語",
	"Q34125",
	"poz-tim",
	otherNames = {"Tetun"},
	scripts = Latn,
}

m["teu"] = {
	"ソー語",
	"Q3437607",
	"ssa-klk",
}

m["tev"] = {
	"Teor",
	"Q12953198",
	"poz-cma",
}

m["tew"] = {
	"テワ語",
	"Q56492",
	"nai-kta",
	otherNames = {"Tano", "Santa Clara Tewa", "San Ildefonso Tewa", "Tesuque Tewa", "Nambe Tewa", "Ohkay Owingeh", "Pojoaque"},
	scripts = Latn,
}

m["tex"] = {
	"Tennet",
	"Q56346",
	"sdv",
}

m["tey"] = {
	"トゥリシ語",
	"Q12911106",
	"qfa-kad",
	scripts = Latn,
}

m["tez"] = {
	"ティンセルト語",
	"Q7706841",
	"ber",
	otherNames = {"Tin Sert"},
	scripts = Latn,
}

m["tfi"] = {
	"Tofin Gbe",
	"Q3530330",
	"alv-pph",
}

m["tfn"] = {
	"タナイナ語",
	"Q27785",
	"ath-nor",
	otherNames = {"Tanaina"},
	scripts = Latn,
}

m["tfo"] = {
	"Tefaro",
	"Q7694618",
	"paa-egb",
}

m["tfr"] = {
	"テリベ語",
	"Q36533",
	"cba",
}

m["tft"] = {
	"テルナテ語",
	"Q3518492",
	"paa-wpa",
	scripts = {"Latn", "Arab"},
}

m["tga"] = {
	"Sagalla",
	"Q12953082",
	"bnt-cht",
}

m["tgb"] = {
	"Tobilung",
	"Q12953913",
	"poz-san",
}

m["tgc"] = {
	"ティガク語",
	"Q3528276",
	"poz-ocw",
}

m["tgd"] = {
	"チウォガイ語",
	"Q3438799",
	"cdc-wst",
}

m["tge"] = {
	"東部ゴルカ・タマン語",
	"Q12953175",
	"sit-tam",
}

m["tgf"] = {
	"チャリカ語",
	"Q3695197",
	"sit-ebo",
	scripts = {"Tibt"},
	otherNames = {"Chalikha", "Chalipkha", "Tshali", "Tshalingpa"},
}

m["tgh"] = {
	"トバゴ島クリオール語",
	"Q7811541",
	"crp",
	ancestors = {"en"},
}

m["tgi"] = {
	"Lawunuia",
	"Q3219937",
	"poz-ocw",
}

m["tgn"] = {
	"タンダガノン語",
	nil,
	"phi",
}

m["tgo"] = {
	"スデスト語",
	"Q7675351",
	"poz-ocw",
}

m["tgp"] = {
	"タンゴア語",
	"Q2410276",
	"poz-vnc",
	scripts = Latn,
}

m["tgq"] = {
	"トリン語",
	"Q7842360",
	"poz-swa",
}

m["tgr"] = {
	"タレン語",
	"Q25559541",
	"mkh",
}

m["tgs"] = {
	"ヌメ語",
	"Q3346290",
	"poz-vnc",
}

m["tgt"] = {
	"中央タグバンワ語",
	"Q3915515",
	"phi",
	scripts = {"Tagb"},
}

m["tgu"] = {
	"タング語",
	"Q7682930",
	"paa",
	scripts = Latn,
}

m["tgv"] = {
	"Tingui-Boto",
	"Q7808195",
	"sai-mje",
}

m["tgw"] = {
	"Tagwana Senoufo",
	"Q36514",
	"alv-tdj",
}

m["tgx"] = {
	"タギシュ語",
	"Q28064",
	"ath-nor",
	scripts = Latn,
}

m["tgy"] = {
	"トゴヨ語",
	"Q36825",
	"nic-ser",
}

m["thc"] = {
	"タイ・パオ語",
	"Q7675753",
	"tai-nor",
}

m["thd"] = {
	"タヨレ語",
	"Q6448718",
	"aus-pmn",
	otherNames = {"Thaayorre", "Thayore"},
	scripts = Latn,
}

m["the"] = {
	"チトワン・タルー語",
	"Q22083804",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["thf"] = {
	"Thangmi",
	"Q7710314",
	"sit-new",
}

m["thh"] = {
	"Northern Tarahumara",
	"Q15616395",
	"azc-trc",
	scripts = Latn,
}

m["thi"] = {
	"タイ・ロン語",
	"Q25559562",
	"tai-swe",
}

m["thk"] = {
	"ザラカ語",
	"Q15407179",
	"bnt-kka",
}

m["thl"] = {
	"ダンガウラ・タルー語",
	"Q22083815",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["thm"] = {
	"Thavung",
	"Q34780",
	"mkh-vie",
	otherNames = {"Aheu", "So (Thavung)"},
	scripts = {"Thai"}, --Laoo is feasible but no evidence yet.
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["thn"] = {
	"Thachanadan",
	"Q7708880",
	"dra",
}

m["thp"] = {
	"トンプソン語",
	"Q1755054",
	"sal",
}

m["thq"] = {
	"コチラ・タルー語",
	"Q22083826",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["thr"] = {
	"ラナ・タルー語",
	"Q12953920",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["ths"] = {
	"タカリー語",
	"Q7709348",
	"sit-tam",
}

m["tht"] = {
	"タールタン語",
	"Q30125",
	"ath-nor",
	scripts = Latn,
}

m["thu"] = {
	"トゥリ語",
	"Q7799291",
	"sdv-lon",
}

m["thv"] = {
	"Tahaggart Tamahaq",
	"Q56703",
	"ber",
	otherNames = {"Tamahaq", "Tahaggart", "Ahaggar"},
	scripts = {"Tfng", "Arab", "Latn"},
	ancestors = {"tmh"},
}

m["thy"] = {
	"Tha",
	"Q3915849",
	"alv-bwj",
}

m["thz"] = {
	"タヤルト・タマジェク語",
	"Q56388",
	"ber",
	otherNames = {"Air Tamajeq"},
	scripts = {"Tfng", "Arab", "Latn"},
}

m["tia"] = {
	"Tidikelt Tamazight",
	"Q56392",
	"ber",
	otherNames = {"Tidikelt"},
}

m["tic"] = {
	"ティラ語",
	"Q36677",
	"alv-hei",
}

m["tif"] = {
	"ティファル語",
	"Q11732691",
	"ngf-okk",
}

m["tig"] = {
	"ティグレ語",
	"Q34129",
	"sem-eth",
	scripts = {"Ethi"},
	translit_module = "Ethi-translit",
}

m["tih"] = {
	"ティムゴン・ムルット語",
	"Q7807680",
	"poz-san",
}

m["tii"] = {
	"Tiene",
	"Q36469",
	"bnt-tek",
}

m["tij"] = {
	"ティルン語",
	"Q7803037",
	"sit-kiw",
}

m["tik"] = {
	"ティカル語",
	"Q36483",
	"nic-bdn",
	scripts = Latn,
}

m["til"] = {
	"ティラムーク語",
	"Q2109432",
	"sal",
}

m["tim"] = {
	"ティンベ語",
	"Q7804599",
	"ngf",
}

m["tin"] = {
	"ティンディ語",
	"Q36860",
	"cau-ava",
}

m["tio"] = {
	"テオプ語",
	"Q3518239",
	"poz-ocw",
}

m["tip"] = {
	"Trimuris",
	"Q7842270",
	"paa-tkw",
}

m["tiq"] = {
	"チェフォ語",
	"Q3914874",
	"alv-sav",
}

m["tis"] = {
	"マサディイット・イトゥネグ語",
	"Q18748769",
	"phi",
}

m["tit"] = {
	"ティニワ語",
	"Q3029805",
}

m["tiu"] = {
	"Adasen",
	"Q11214797",
	"phi",
}

m["tiv"] = {
	"ティヴ語",
	"Q34131",
	"nic-tvc",
	otherNames = {"Tivi"},
	scripts = Latn,
}

m["tiw"] = {
	"ティウィ語",
	"Q1656014",
	"qfa-iso",
	scripts = Latn,
}

m["tix"] = {
	"南部ティワ語",
	"Q7570552",
	"nai-kta",
	otherNames = {"Isleta", "Isleta Tiwa", "Isleta Pueblo", "Sandia", "Sandia Tiwa", "Sandia Pueblo"},
	scripts = Latn,
}

m["tiy"] = {
	"ティルライ語",
	"Q7809425",
	"phi",
	scripts = Latn,
}

m["tiz"] = {
	"紅金タイ語",
	"Q3915716",
	"tai-swe",
}

m["tja"] = {
	"タジュオソン語",
	"Q3915326",
	"kro-wkr",
}

m["tjg"] = {
	"トゥンジュン語",
	"Q3542117",
	"poz",
}

m["tji"] = {
	"ビジ語",
	"Q12953229",
	"sit-tja",
}

m["tjm"] = {
	"ティムクア語",
	"Q638300",
	"qfa-iso",
}

m["tjn"] = {
	"Tonjon",
	"Q3913372",
	"dmn-jje",
}

m["tjo"] = {
	"テマキン・タマジクト語",
	"Q3507211",
	"ber",
}

m["tjs"] = {
	"ムズ語",
	"Q12633994",
	"sit-tja",
	scripts = Latn,
}

m["tju"] = {
	"チュルル語",
	"Q3913834",
	"aus-nga",
	scripts = Latn,
}

m["tjw"] = {
	"Chaap Wuurong",
	"Q5285187",
	"aus-pam",
	otherNames = {"Djabwurrung", "Djab Wurrung", "Tjapwurrung"},
	scripts = Latn,
}

m["tka"] = {
	"Truká",
	"Q7847648",
}

m["tkb"] = {
	"ブクサ語",
	"Q20983638",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["tkd"] = {
	"トコデデ語",
	"Q36863",
	"poz-tim",
	scripts = Latn,
}

m["tke"] = {
	"Takwane",
	"Q11030092",
	"bnt-mak",
	ancestors = {"vmw"},
}

m["tkf"] = {
	"Tukumanféd",
	"Q42330115",
	"tup-gua",
	scripts = Latn,
}

m["tkl"] = {
	"トケラウ語",
	"Q34097",
	"poz-pnp",
	scripts = Latn,
}

m["tkm"] = {
	"Takelma",
	"Q56710",
}

m["tkn"] = {
	"徳之島語",
	"Q3530484",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["tkp"] = {
	"ティコピア語",
	"Q36682",
	"poz-pnp",
	scripts = Latn,
}

m["tkq"] = {
	"Tee",
	"Q3075144",
	"nic-ogo",
	scripts = Latn,
}

m["tkr"] = {
	"ツァフル語",
	"Q36853",
	"cau-lzg",
	otherNames = {"Caxur", "Tsaxur"},
	scripts = {"Cyrl"},
}

m["tks"] = {
	"ターケスターニー語",
	otherNames = {"Takestani"},
	"Q25261947",
	"xme-ttc",
	ancestors = {"xme-ttc-sou"},
}

m["tkt"] = {
	"Kathoriya Tharu",
	"Q22083822",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["tku"] = {
	"上ネカクサ・トトナク語",
	"Q56343",
	"nai-ttn",
	scripts = Latn,
}

m["tkv"] = {
	"Mur Pano",
	nil,
	"poz-ocw",
	otherNames = {"Pano"},
	scripts = Latn,
}

m["tkw"] = {
	"Teanu",
	"Q3516731",
	"poz-oce",
	scripts = Latn,
}

m["tkx"] = {
	"Tangko",
	"Q7682993",
	"ngf-okk",
}

m["tkz"] = {
	"タクア語",
	"Q7678544",
	"mkh",
}

m["tla"] = {
	"南西部テペワン語",
	"Q3518245",
	"azc",
	scripts = Latn,
}

m["tlb"] = {
	"トベロ語",
	"Q1142333",
	"paa-wpa",
}

m["tlc"] = {
	"イェクアトラ・トトナク語",
	"Q56460",
	"nai-ttn",
	otherNames = {"Yecuatla Totonac"},
	scripts = Latn,
}

m["tld"] = {
	"タラウド語",
	"Q7678964",
	"phi",
}

m["tlf"] = {
	"テレフォル語",
	"Q7696150",
	"ngf-okk",
}

m["tlg"] = {
	"トファンマ語",
	"Q4461493",
	"paa-pau",
}

m["tlh"] = {
	"クリンゴン語",
	"Q10134",
	"art",
	type = "appendix-constructed",
	scripts = Latn,
}

m["tli"] = {
	"トリンギット語",
	"Q27792",
	"xnd",
	scripts = {"Latn", "Cyrl"},
}

m["tlj"] = {
	"タリンガ＝ブィシ語",
	"Q7679530",
	"bnt-haj",
}

m["tlk"] = {
	"Taloki",
	"Q3514563",
	"poz-btk",
}

m["tll"] = {
	"テテラ語",
	"Q2613465",
	"bnt-tet",
	varieties = {"Indanga"},
}

m["tlm"] = {
	"トロマコ語",
	"Q3130514",
	"poz-vnc",
}

m["tln"] = {
	"タロンド語'",
	"Q7680293",
	"poz-ssw",
}

m["tlo"] = {
	"タローディ語",
	"Q36525",
	"alv-tal",
}

m["tlp"] = {
	"Filomena Mata-Coahuitlán Totonac",
	"Q5449202",
	"nai-ttn",
	scripts = Latn,
}

m["tlq"] = {
	"タイ・ロイ語",
	"Q7675784",
	"mkh-pal",
}

m["tlr"] = {
	"タリセ語",
	"Q3514510",
	"poz-sls",
}

m["tls"] = {
	"タンボタロ語",
	"Q7681065",
	"poz-vnc",
}

m["tlt"] = {
	"テルティ語",
	"Q12953194",
	"poz-cma",
	otherNames = {"Sou Nama"},
}

m["tlu"] = {
	"Tulehu",
	"Q7852006",
	"poz-cma",
}

m["tlv"] = {
	"タリアブ語",
	"Q3514498",
	"poz-cma",
	otherNames = {"Soboyo"},
	scripts = Latn,
}

m["tlx"] = {
	"Khehek",
	"Q3196124",
	"poz-aay",
}

m["tly"] = {
	"タリシュ語",
	"Q34318",
	"xme-ttc",
	otherNames = {"Talyshi", "Talishi", "Taleshi", "Tolashi", "Asalemi", "Anbarani"},
	scripts = {"Latn", "Cyrl", "fa-Arab"},
	ancestors = {"xme-ttc-pro"},
}

m["tma"] = {
	"タマ語（チャド）",
	"Q57001",
	"sdv-tmn",
	otherNames = {"Tama"},
}

m["tmb"] = {
	"カトボル語",
	"Q2157461",
	"poz-vnc",
}

m["tmc"] = {
	"トゥマック語",
	"Q3121045",
	"cdc-est",
}

m["tmd"] = {
	"ハルアイ語",
	"Q12632146",
	"ngf-mad",
}

m["tme"] = {
	"トレメンベ語",
	"Q5246937",
}

m["tmf"] = {
	"トバ＝マスコイ語",
	"Q3033544",
	"sai-mas",
}

m["tmg"] = {
	"テルナテーニョ",
	"Q7232597",
}

m["tmh"] = {
	"トゥアレグ語",
	"Q34065",
	"ber",
	otherNames = {"Tamashek", "Tamahaq", "Tamajaq", "Tamasheq"},
	scripts = {"Tfng", "Arab", "Latn"},
}

m["tmi"] = {
	"ツツバ語",
	"Q7857052",
	"poz-vnc",
}

m["tmj"] = {
	"サマロケナ語",
	"Q7408865",
	"paa-tkw",
}

m["tmk"] = {
	"北西タマン語",
	"Q15616509",
	"sit-tam",
}

m["tml"] = {
	"Tamnim Citak",
	"Q12643315",
	"ngf",
}

m["tmm"] = {
	"タイ・タィン語",
	"Q7675842",
	"tai-swe",
}

m["tmn"] = {
	"タマン語（インドネシア）",
	"Q7680671",
	"poz",
	otherNames = {"Taman"},
	scripts = Latn,
}

m["tmo"] = {
	"トゥモック語",
	"Q7698205",
	"mkh-asl",
}

m["tmp"] = {
	"Tai Mène",
	"Q7675790",
	"tai-nor",
}

m["tmq"] = {
	"トゥムレオ語",
	"Q7852641",
	"poz-ocw",
}

m["tms"] = {
	"ティマ語",
	"Q36684",
	"nic-ktl",
}

m["tmt"] = {
	"タスマテ語",
	"Q7687571",
	"poz-vnc",
}

m["tmu"] = {
	"Iau",
	"Q56867",
	"paa-lkp",
	otherNames = {"Turu"},
}

m["tmv"] = {
	"テンボ語",
	"Q11013108",
	"bnt-bun",
	otherNames = {"Tembo"},
}

m["tmy"] = {
	"タミ語",
	"Q3514812",
	"poz-oce",
}

m["tmz"] = {
	"タマナク語",
	"Q3441435",
	"sai-car",
	scripts = Latn,
}

m["tna"] = {
	"タカナ語",
	"Q3182551",
	"sai-tac",
	scripts = Latn,
}

m["tnb"] = {
	"Western Tunebo",
	"Q3181238",
	"cba",
}

m["tnc"] = {
	"Tanimuca-Retuarã",
	"Q36535",
	"sai-tuc",
	scripts = Latn,
}

m["tnd"] = {
	"アンゴストゥラス・トゥネボ語",
	"Q25559604",
	"cba",
}

m["tne"] = {
	"ティノック・カッラハン語",
	"Q3192219",
}

m["tng"] = {
	"トバンガ語",
	"Q3440501",
	"cdc-est",
}

m["tnh"] = {
	"Maiani",
	"Q6735243",
	scripts = Latn,
	"ngf-mad",
}

m["tni"] = {
	"Tandia",
	"Q7682454",
	"poz-hce",
	scripts = Latn,
}

m["tnk"] = {
	"クワメラ語",
	"Q3200806",
	"poz-oce",
}

m["tnl"] = {
	"レナケル語",
	"Q3229429",
	"poz-oce",
}

m["tnm"] = {
	"Tabla",
	"Q7673105",
	"paa-sen",
}

m["tnn"] = {
	"北タンナ語",
	"Q957945",
	"poz-oce",
}

m["tno"] = {
	"トロモノ語",
	"Q510544",
	"sai-tac",
	scripts = Latn,
}

m["tnp"] = {
	"ホワイトサンズ語",
	"Q3063761",
	"poz-oce",
}

m["tnq"] = {
	"タイノ語",
	"Q5232952",
	"awd-taa",
	ancestors = {"awd-taa-pro"},
	otherNames = {"Taino"},
	scripts = Latn,
}

m["tnr"] = {
	"Bedik",
	"Q35096",
	"alv-ten",
}

m["tns"] = {
	"テニス語",
	"Q7699870",
	"poz-ocw",
}

m["tnt"] = {
	"トンテンボアン語",
	"Q3531666",
	"phi",
	scripts = Latn,
}

m["tnu"] = {
	"タイー・カン語",
	"Q6362363",
	"tai",
}

m["tnv"] = {
	"トンチョンギャ語",
	"Q7682361",
	"inc-eas",
	scripts = {"Cakm"},
	ancestors = {"inc-mgd"},
}

m["tnw"] = {
	"トンサワン語",
	"Q3531660",
	"phi",
}

m["tnx"] = {
	"Tanema",
	"Q2106984",
	"poz-oce",
}

m["tny"] = {
	"トングウェ語",
	"Q7821200",
	"bnt",
}

m["tnz"] = {
	"Ten'edn",
	"Q3073453",
	"mkh-asl",
	otherNames = {"Tonga"},
	scripts = Latn,
}

m["tob"] = {
	"トバ語",
	"Q3113756",
	"sai-guc",
	otherNames = {"Chaco Sur", "Namqom", "Qom", "Toba Qom"},
	scripts = Latn,
}

m["toc"] = {
	"コユトラ・トトナク語",
	"Q15615591",
	"nai-ttn",
	scripts = Latn,
}

m["tod"] = {
	"トマ語",
	"Q11055484",
	"dmn-msw",
}

m["tof"] = {
	"Gizrra",
	"Q5565941",
}

m["tog"] = {
	"西ニアサ語",
	"Q3847648",
	"bnt-nys",
	otherNames = {"Kitonga", "Chitonga", "Siska", "Sisya", "Tonga", "Western Nyasa"},
	scripts = Latn,
}

m["toh"] = {
	"ギトンガ語",
	"Q7820988",
	"bnt-bso",
	otherNames = {"Gitonga", "Tonga"},
}

m["toi"] = {
	"チトンガ語",
	"Q34101",
	"bnt-bot",
	otherNames = {"Tonga", "Chitonga", "Plateau Tonga", "Zambezi"},
}

m["toj"] = {
	"トホラバル語",
	"Q36762",
	"myn",
}

m["tok"] = {
	"トキポナ",
	36846,
	"art",
	"Latn",
}

m["tol"] = {
	"トロワ語",
	"Q20827",
	"ath-pco",
	otherNames = {"Smith River", "Smith River Tolowa"},
	scripts = Latn,
}

m["tom"] = {
	"トムブル語",
	"Q3531199",
	"phi",
}

m["too"] = {
	"クシコテペク・デ・ファレス・トトナク語",
	"Q8044353",
	"nai-ttn",
	scripts = Latn,
}

m["top"] = {
	"パパントラ・トトナク語",
	"Q56329",
	"nai-ttn",
	scripts = Latn,
}

m["toq"] = {
	"トポサ語",
	"Q3033588",
	"sdv-ttu",
}

m["tor"] = {
	"Togbo-Vara Banda",
	"Q11002922",
	"bad-cnt",
}

m["tos"] = {
	"高地トトナク語",
	"Q13154149",
	"nai-ttn",
	scripts = Latn,
}

m["tou"] = {
	"トー語",
	"Q22694631",
	"mkh-vie",
}

m["tov"] = {
	"上ターロム語",
	"Q12953183",
	"xme-ttc",
	ancestors = {"xme-ttc-cen"},
}

m["tow"] = {
	"ヘメス語",
	"Q3912876",
	"nai-kta",
	otherNames = {"Towa"},
	scripts = Latn,
}

m["tox"] = {
	"トビ語",
	"Q34022",
	"poz-mic",
}

m["toy"] = {
	"トポイヨ語",
	"Q7824977",
	"poz-kal",
}

m["toz"] = {
	"To",
	"Q7811216",
	"alv-mbm",
}

m["tpa"] = {
	"タウポタ語",
	"Q7688832",
	"poz-ocw",
}

m["tpc"] = {
	"アソユ・メパー語",
	"Q25559730",
	"omq",
}

m["tpe"] = {
	"ティペラ語",
	"Q16115423",
	"tbq-bdg",
}

m["tpf"] = {
	"タルピア語",
	"Q12953185",
	"poz-ocw",
}

m["tpg"] = {
	"クラ語",
	"Q6442714",
	"qfa-tap",
}

m["tpi"] = {
	"トク・ピシン",
	"Q34159",
	"crp",
	otherNames = {"Melanesian Pidgin English", "Neo-Melanesian", "New Guinea Pidgin"},
	scripts = Latn,
	ancestors = {"en"},
}

m["tpj"] = {
	"タピエテ語",
	"Q3121063",
}

m["tpk"] = {
	"Tupinikin",
	"Q33924",
	"tup-gua",
	otherNames = {"Coastal Tupi", "Tupiniquim"},
}

m["tpl"] = {
	"トラコアパ・メパー語",
	"Q16115511",
	"omq",
}

m["tpm"] = {
	"Tampulma",
	"Q36590",
	"nic-gnw",
}

m["tpn"] = {
	"トゥピナンバ語",
	"Q31528147",
	"tup-gua",
	scripts = Latn,
}

m["tpo"] = {
	"タイ・パオ語",
	"Q7675795",
	"tai-nor",
}

m["tpp"] = {
	"ピサフロレス・テペワ語",
	"Q56349",
	"nai-ttn",
}

m["tpq"] = {
	"Tukpa",
	"Q12953230",
	"sit-las",
}

m["tpr"] = {
	"トゥパリ語",
	"Q3542217",
	"tup",
	scripts = Latn,
}

m["tpt"] = {
	"トラチチルコ・テペワ語",
	"Q56330",
	"nai-ttn",
}

m["tpu"] = {
	"タンプアン語",
	"Q3514882",
	"mkh-ban",
}

m["tpv"] = {
	"タナパグ語",
	"Q3397371",
	"poz-mic",
}

m["tpw"] = {
	"トゥピ語",
	"Q56944",
	"tup-gua",
	otherNames = {"Classical Tupi"},
	scripts = Latn,
}

m["tpx"] = {
	"アカテペック・メパー語",
	"Q31157882",
	"omq",
}

m["tpy"] = {
	"ツルマイ語",
	"Q12294279",
	"qfa-iso",
}

m["tpz"] = {
	"ティンプツ語",
	"Q3529205",
	"poz-ocw",
}

m["tqb"] = {
	"Tembé",
	"Q10322157",
	"tup-gua",
	scripts = Latn,
}

m["tql"] = {
	"レハリ語",
	"Q3229119",
	"poz-oce",
}

m["tqm"] = {
	"Turumsa",
	"Q7856508",
	"paa",
}

m["tqn"] = {
	"テニノ語",
	"Q15699255",
	"nai-shp",
	ancestors = {"nai-spt"},
	scripts = Latn,
}

m["tqo"] = {
	"トアリピ語",
	"Q7811403",
	"ngf",
}

m["tqp"] = {
	"トモイプ語",
	"Q3531388",
	"poz-ocw",
}

m["tqq"] = {
	"トゥニ語",
	"Q3514343",
	"cus",
}

m["tqr"] = {
	"トロナ語",
	"Q36679",
	"alv-tal",
}

m["tqt"] = {
	"西部トトナク語",
	"Q7116691",
	"nai-ttn",
	scripts = Latn,
}

m["tqu"] = {
	"Touo",
	"Q56750",
}

m["tqw"] = {
	"トンカワ語",
	"Q2454881",
	"qfa-iso",
}

m["tra"] = {
	"ティラーヒー語",
	"Q3812406",
	"inc-dar",
}

m["trb"] = {
	"テレブ語",
	"Q7701797",
	"poz-ocw",
}

m["trc"] = {
	"コパラ・トゥリケ語",
	"Q12953935",
	"omq-tri",
	scripts = Latn,
}

m["trd"] = {
	"トゥーリー語",
	"Q7854914",
	"mun",
}

m["tre"] = {
	"東タラガン語",
	"Q18609750",
	"poz",
}

m["trf"] = {
	"トリニダード島クレオール語",
	"Q7842493",
	"crp",
	ancestors = {"en"},
}

m["trg"] = {
	"ディダン語",
	"Q56473",
	"sem-nna",
}

m["trh"] = {
	"トゥラカ語",
	"Q12953237",
	"ngf",
}

m["tri"] = {
	"トリオ語",
	"Q56885",
	"sai-car",
	otherNames = {"Trio", "Tiriyó", "Tarano"},
	scripts = Latn,
}

m["trj"] = {
	"トラム語",
	"Q3441225",
	"cdc-est",
}

m["trl"] = {
	"Traveller Scottish",
	"Q3915671",
}

m["trm"] = {
	"トレガミ語",
	"Q34081",
	"nur-sou",
}

m["trn"] = {
	"トリニタリオ語",
	"Q3539279",
	"awd",
	otherNames = {"Trinitario Moxos", "Moxo", "Moxos", "Mojo", "Moxa"},
}

m["tro"] = {
	"Tarao",
	"Q3515603",
	"tbq-kuk",
	otherNames = {"Tarao Naga", "Taraotrong", "Tarau"},
	scripts = Latn,
}

m["trp"] = {
	"コク・ボロック語",
	"Q35947",
	"tbq-bdg",
}

m["trq"] = {
	"サン・マルティン・イトゥンヨソ・トゥリケ語",
	"Q12953934",
	"omq-tri",
	scripts = Latn,
}

m["trr"] = {
	"Taushiro",
	"Q1957508",
}

m["trs"] = {
	"チカワシュトラ・トゥリケ語",
	"Q3539587",
	"omq-tri",
	scripts = Latn,
}

m["trt"] = {
	"Tunggare",
	"Q615071",
	"paa-egb",
}

m["tru"] = {
	"トゥロヨ語",
	"Q34040",
	"sem-cna",
	scripts = {"Syrc", "Latn"},
	entry_name = {
		from = { "[" .. u(0x0711, 0x0730, ("-"):byte(), 0x074A) .. "]" },
		to = {},
	},
}

m["trv"] = {
	"タロコ語",
	"Q716686",
	"map-ata",
	otherNames = {"Seediq"},
	scripts = Latn,
}

m["trw"] = {
	"トールワーリー語",
	"Q2665246",
	"inc-dar",
	scripts = {"ur-Arab"},
}

m["trx"] = {
	"Tringgus",
	"Q7842365",
	"day",
	otherNames = {"Tringus", "Tringgus-Sembaan Bidayuh"},
}

m["try"] = {
	"Turung",
	"Q7856514",
	"tai-swe",
	otherNames = {"Tai Turung"},
	scripts = {"as-Beng"},
}

m["trz"] = {
	"トラ語",
	"Q7827518",
	"sai-cpc",
}

m["tsa"] = {
	"ツァーンギ語",
	otherNames = {"Tsaangi", "ツアンギ語"},
	"Q36675",
	"bnt-nze",
}

m["tsb"] = {
	"ツァマイ語",
	"Q2371358",
	"cus",
}

m["tsc"] = {
	"ツワ語",
	"Q2085051",
	"bnt-tsr",
}

m["tsd"] = {
	"ツァコン語",
	"Q220607",
	"grk",
	scripts = {"Grek"},
	sort_key = {  -- Keep this synchronized with el, grc, cpg, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
	ancestors = {"grc"},
}

m["tse"] = {
	"チュニジア手話",
	"Q7853191",
	"sgn",
}

m["tsf"] = {
	"南西タマン語",
	"Q12953176",
	"sit-tam",
}

m["tsg"] = {
	"タウスグ語",
	"Q34142",
	"phi",
	otherNames = {"Sūg"},
	scripts = {"Latn", "Arab"},
}

m["tsh"] = {
	"ツヴァン語",
	"Q3502326",
	"cdc-cbm",
}

m["tsi"] = {
	"ツィムシア語",
	"Q20085721",
	"nai-tsi",
}

m["tsj"] = {
	"ツァンラ語",
	"Q36840",
	"sit-tsk",
	otherNames = {"Sharchop"},
	scripts = {"Latn", "Deva", "Tibt"},
}

m["tsl"] = {
	"ツン・ラオ語",
	"Q3446675",
	"tai",
}

m["tsm"] = {
	"トルコ手話",
	"Q36885",
	"sgn",
}

m["tsp"] = {
	"北部トゥシャン語",
	"Q11155635",
	"alv-sav",
}

m["tsq"] = {
	"タイ手話",
	"Q7709156",
	"sgn",
}

m["tsr"] = {
	"アケイ語",
	"Q2828964",
	"poz-vnc",
}

m["tss"] = {
	"台湾手話",
	"Q34019",
	"sgn-jsl",
}

m["tsu"] = {
	"ツォウ語",
	"Q716681",
	"map",
	scripts = Latn,
}

m["tsv"] = {
	"ツォゴ語",
	"Q36674",
	"bnt-tso",
}

m["tsw"] = {
	"Tsishingini",
	"Q13123571",
	"nic-kam",
}

m["tsx"] = {
	"Mubami",
	"Q6930815",
	"ngf",
}

m["tsy"] = {
	"テブル手話",
	"Q7692090",
	"sgn",
}

m["tta"] = {
	"トゥテロ語",
	"Q2311602",
	"sio-ohv",
}

m["ttb"] = {
	"Gaa",
	"Q3438361",
	"nic-dak",
}

m["ttc"] = {
	"テクティテク語",
	"Q36686",
	"myn",
}

m["ttd"] = {
	"タウアデ語",
	"Q7688634",
}

m["tte"] = {
	"Bwanabwana",
	"Q5003667",
	"poz-ocw",
	otherNames = {"Tubetube"},
	scripts = Latn,
}

m["ttf"] = {
	"Tuotomb",
	"Q7853459",
	"nic-mbw",
	scripts = Latn,
}

m["ttg"] = {
	"ツトン語",
	"Q3507990",
	"poz-swa",
}

m["tth"] = {
	"Upper Ta'oih",
	"Q3512660",
	"mkh-kat",
}

m["tti"] = {
	"トバティ語",
	"Q7811556",
	"poz-ocw",
}

m["ttj"] = {
	"トーロ語",
	otherNames = {"Tooro"},
	"Q7824218",
	"bnt-nyg",
}

m["ttk"] = {
	"トトロ語",
	"Q3532756",
	"sai-bar",
	aliases = {"Totoró"},
}

m["ttl"] = {
	"トテラ語",
	"Q10962316",
	"bnt-bot",
}

m["ttm"] = {
	"北部トゥトチョネ語",
	"Q20822",
	"ath-nor",
	scripts = Latn,
}

m["ttn"] = {
	"トウェイ語",
	"Q7829606",
	"paa-pau",
}

m["tto"] = {
	"Lower Ta'oih",
	"Q25559539",
	"mkh-kat",
}

m["ttp"] = {
	"Tombelala",
	"Q6799663",
	"poz-kal",
}

m["ttq"] = {
	"タワラマト・タマジャク語",
	"Q56390",
	"ber",
	scripts = {"Tfng", "Arab", "Latn"},
	ancestors = {"tmh"},
}

m["ttr"] = {
	"テーラ語",
	"Q56267",
	"cdc-cbm",
}

m["tts"] = {
	"イーサーン語",
	"Q33417",
	"tai-swe",
	aliases = {"Isanese", "Isaan", "Issan", "Northeastern Thai"},
	scripts = {"Thai"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["ttt"] = {
	"タト語",
	"Q56489",
	"ira-swi",
	otherNames = {"Caucasian Tat", "Muslim Tat", "Armeno-Tat"},
	scripts = {"Cyrl", "Latn", "Armn", "fa-Arab"},
	ancestors = {"fa"},
}

m["ttu"] = {
	"トラウ語",
	"Q3532208",
	"poz-ocw",
}

m["ttv"] = {
	"Titan",
	"Q3445811",
	"poz-aay",
}

m["ttw"] = {
	"Long Wat",
	"Q7856961",
	"poz-swa",
	otherNames = {"Tutoh"},
}

m["tty"] = {
	"Sikaritai",
	"Q7513600",
	"paa-lkp",
}

m["ttz"] = {
	"ツム語",
	"Q12953223",
	"sit-kyk",
}

m["tua"] = {
	"Wiarumus",
	"Q7998045",
	"qfa-tor",
	scripts = Latn,
}

m["tub"] = {
	"トゥバトゥラバル語",
	"Q56704",
	"azc",
	scripts = Latn,
}

m["tuc"] = {
	"ムトゥ語",
	"Q3331003",
	"poz-ocw",
	scripts = Latn,
}

m["tud"] = {
	"トゥシャ語",
	"Q7857217",
}

m["tue"] = {
	"トゥユカ語",
	"Q2520538",
	"sai-tuc",
	scripts = Latn,
}

m["tuf"] = {
	"中央トゥネボ語",
	"Q12953942",
	"cba",
}

m["tug"] = {
	"トゥニヤ語",
	"Q863721",
	"alv-bua",
}

m["tuh"] = {
	"タウリル語",
	"Q3516141",
	"paa-bng",
}

m["tui"] = {
	"トゥプリ語",
	"Q36646",
	"alv-mbm",
	scripts = Latn,
}

m["tuj"] = {
	"Tugutil",
	"Q12953228",
}

m["tul"] = {
	"トゥラ語",
	"Q3914907",
	"alv-wjk",
}

m["tum"] = {
	"トゥンブカ語",
	"Q34138",
	"bnt-nys",
	scripts = Latn,
}

m["tun"] = {
	"トゥーニカ語",
	"Q56619",
	"qfa-iso",
	scripts = Latn,
}

m["tuo"] = {
	"トゥカノ語",
	"Q3541834",
	"sai-tuc",
	scripts = Latn,
}

m["tuq"] = {
	"Tedaga",
	"Q36639",
	"ssa-sah",
	otherNames = {"Teda"},
}

m["tus"] = {
	"タスカローラ語",
	"Q36944",
	"iro",
	scripts = {"Latinx"},
}

m["tuu"] = {
	"トゥトゥトニ語",
	"Q20627",
	"ath-pco",
	scripts = Latn,
}

m["tuv"] = {
	"トゥルカナ語",
	"Q36958",
	"sdv-ttu",
	scripts = Latn,
}

m["tux"] = {
	"Tuxináwa",
	"Q7857204",
	"sai-pan",
	scripts = Latn,
}

m["tuy"] = {
	"トゥゲン語",
	"Q3541935",
	"sdv-nma",
}

m["tuz"] = {
	"Turka",
	"Q36643",
	"nic-gur",
	scripts = Latn,
}

m["tva"] = {
	"ヴァグア語",
	"Q3553248",
	"poz-ocw",
	scripts = Latn,
}

m["tvd"] = {
	"Tsuvadi",
	"Q3914936",
	"nic-kam",
}

m["tve"] = {
	"Te'un",
	"Q7690709",
	"poz-cet",
	scripts = Latn,
}

m["tvk"] = {
	"アンブレム語",
	"Q252411",
	"poz-vnc",
	scripts = Latn,
}

m["tvl"] = {
	"ツバル語",
	"Q34055",
	"poz-pnp",
	scripts = Latn,
}

m["tvm"] = {
	"Tela-Masbuar",
	"Q7695666",
	"poz-tim",
}

m["tvn"] = {
	"タボイ語",
	"Q7689158",
	"tbq-brm",
	scripts = {"Mymr"},
	ancestors = {"obr"},
}

m["tvo"] = {
	"ティドレ語",
	"Q3528199",
	"paa-wpa",
}

m["tvs"] = {
	"タベタ語",
	"Q15632387",
	"bnt-par",
}

m["tvt"] = {
	"Tutsa Naga",
	"Q7856987",
	"sit-tno",
}

m["tvu"] = {
	"トゥネン語",
	"Q36632",
	"nic-mbw",
	otherNames = {"Banen", "Tunen-Aling'a"},
}

m["tvw"] = {
	"セドア語",
	"Q7445362",
	"poz-kal",
}

m["tvx"] = {
	"Taivoan",
	"Q1975271",
	"map",
	scripts = Latn,
}

m["tvy"] = {
	"Timor Pidgin",
	"Q4904029",
	"crp",
	otherNames = {"Bidau Creole Portuguese"},
	ancestors = {"pt"},
}

m["twa"] = {
	"トワナ語",
	"Q7857412",
	"sal",
}

m["twb"] = {
	"西部タウブイッド語",
	"Q12953912",
	"phi",
}

m["twc"] = {
	"テシェナワ語",
	"Q3436597",
	"phi",
}

m["twe"] = {
	"テワ語",
	"Q3519302",
	"ngf",
	otherNames = {"Tewa"},
	scripts = Latn,
}

m["twf"] = {
	"タオス語",
	"Q7684320",
	"nai-kta",
	otherNames = {"Northern Tiwa"},
	scripts = Latn,
}

m["twg"] = {
	"Tereweng",
	"Q12953200",
	"qfa-tap",
}

m["twh"] = {
	"タイ・ドン語",
	"Q7675751",
	"tai-swe",
	otherNames = {"Tai Khao", "White Tai"},
	scripts = {"Tavt"},
	--translit_module = "Tavt-translit",
	sort_key = {
		from = {"[꪿ꫀ꫁ꫂ]", "([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])"},
		to   = {"", "%2%1"}},
}

m["twm"] = {
	"タワン・モンパ語",
	"Q36586",
	"sit-ebo",
}

m["twn"] = {
	"Twendi",
	"Q7857682",
	"nic-mmb",
}

m["two"] = {
	"Tswapong",
	"Q3446241",
	"bnt-sts",
}

m["twp"] = {
	"Ere",
	"Q3056045",
	"poz-aay",
	scripts = Latn,
}

m["twq"] = {
	"タサワク語",
	"Q36564",
	"son",
}

m["twr"] = {
	"南西部タラフマラ語",
	"Q12953909",
	"azc-trc",
	scripts = Latn,
}

m["twt"] = {
	"トリワラ語",
	"Q3542307",
	"tup-gua",
	scripts = Latn,
}

m["twu"] = {
	"トゥルマヌ語",
	"Q7702572",
	"poz-tim",
}

m["tww"] = {
	"トゥワリ語",
	"Q7857159",
	"paa-spk",
}

m["twy"] = {
	"Tawoyan",
	"Q3513542",
	"poz-bre",
	otherNames = {"Taboyan"},
}

m["txa"] = {
	"Tombonuo",
	"Q7818692",
	"poz-san",
}

m["txb"] = {
	"トカラ語B",
	"Q3199353",
	"ine-toc",
	otherNames = {"West Tocharian", "Kuchean"},
	scripts = Latn,
	wikipedia_article = "Tocharian languages", -- wikidata id has no associated article
	standardChars = "ACEIK-PR-UWYaceik-pr-uwyÄäĀāṂṃṄṅÑñŚśṢṣ" .. PUNCTUATION,
}

m["txc"] = {
	"ツェツァウト語",
	"Q20829",
	"ath-nor",
	scripts = Latn,
}

m["txe"] = {
	"トリトリ語",
	"Q7828387",
	"poz-tot",
	scripts = Latn,
}

m["txg"] = {
	"西夏語",
	"Q2727930",
	"sit-qia",
	scripts = {"Tang"},
}

m["txj"] = {
	"Tarjumo",
	nil,
	"ssa-sah",
	scripts = {"Latn", "Arab"},
}

m["txh"] = {
	"トラキア語",
	"Q36793",
	"ine",
	scripts = {"Grek"},
	translit_module = "el-translit",
}

m["txi"] = {
	"イクペン語",
	"Q9344891",
	"sai-car",
	scripts = Latn,
}

m["txm"] = {
	"トミニ語",
	"Q7818911",
	"poz",
}

m["txn"] = {
	"西タラガン語",
	"Q3515594",
	"poz",
}

m["txo"] = {
	"トト語",
	"Q36709",
	"sit-dhi",
}

m["txq"] = {
	"Tii",
	"Q7801784",
	"poz-tim",
}

m["txr"] = {
	"Tartessian",
	"Q36795",
}

m["txs"] = {
	"トンセア語",
	"Q3531659",
	"phi",
}

m["txt"] = {
	"チタック語",
	"Q3447279",
	"ngf",
}

m["txu"] = {
	"カイアポー語",
	"Q3101212",
	"sai-nje",
	scripts = Latn,
}

m["txx"] = {
	"タタナ語",
	"Q18643518",
	"poz-san",
}

m["tya"] = {
	"タウヤ語",
	"Q7688978",
	"ngf-mad",
}

m["tye"] = {
	"Kyenga",
	"Q3913304",
	"dmn-bbu",
	scripts = Latn,
}

m["tyh"] = {
	"オズ語",
	"Q3347428",
	"mkh",
}

m["tyi"] = {
	"テケ＝ツァアイ語",
	"Q33123613",
	"bnt-nze",
}

m["tyj"] = {
	"タイ・ドー語",
	"Q7675746",
	"tai-nor",
}

m["tyl"] = {
	"トゥー・ラオ語",
	"Q12953921",
	"tai-cen",
}

m["tyn"] = {
	"コンバイ語",
	"Q6428241",
	"ngf",
}

m["typ"] = {
	"クク・タイパン語",
	"Q3915693",
	"aus-pmn",
	otherNames = {"Gugu Thaypan", "Thaypan", "Kuku Thaypan", "Agu Alaya", "Awu Alaya", "Alaya", "Gugu-Rarmul", "Koko-Rarmul", "Rarmul"},
	scripts = Latn,
}

m["tyr"] = {
	"タイ・デン語",
	"Q3915207",
	"tai-swe",
}

m["tys"] = {
	"サパ語",
	"Q3446668",
	"tai-sap",
	otherNames = {"Sa Pa", "Tày Sa Pa", "Tai Sapa"},
	scripts = Latn,
}

m["tyt"] = {
	"タイー・タック語",
	"Q7862029",
	"tai-swe",
}

m["tyu"] = {
	"Kua",
	"Q3832933",
	"khi-kal",
}

m["tyv"] = {
	"トゥバ語",
	"Q34119",
	"trk-sib",
	otherNames = {"Tyvan"},
	scripts = {"Cyrl"},
	translit_module = "tyv-translit",
	override_translit = true,
}

m["tyx"] = {
	"Teke-Tyee",
	"Q36634",
	"bnt-nze",
}

m["tyz"] = {
	"タイー語", -- This does not mean its umbrella "Tai" languages.
	"Q2511476",
	"tai-tay",
	aliases = {"Tay", "Tho", "Bao Yen", "Cao Bang"}, -- Both Bao Lac and Trung Khanh are located in Cao Bang.
	varieties = {"Central Tày", "Eastern Tày", "Northern Tày", "Southern Tày", "Tày Bao Lac", "Tày Trung Khanh"},
	scripts = Latn,
}

m["tza"] = {
	"タンザニア手話",
	"Q7684177",
	"sgn",
}

m["tzh"] = {
	"ツェルタル語",
	"Q36808",
	"myn",
	scripts = Latn,
}

m["tzj"] = {
	"ツトゥヒル語",
	"Q36941",
	"myn",
	otherNames = {"Tzutujil"},
	scripts = Latn,
}

m["tzl"] = {
	"タロッサ語",
	"Q1063911",
	"art",
	type = "appendix-constructed",
	scripts = Latn,
	sort_key = {
		from = {"[àáâäå]", "ç", "ð",   "[ëèéê]", "[ìíîï]", "ñ", "[öòóô]", "ß", "[üùúû]", "þ"},
		to   = {"a",       "c", "d∙", "e",      "i",      "n", "o",      "s",  "u", "z∙"}} ,  -- bullet so ð and þ are sorted after all other words with d and z, respectively
}

m["tzm"] = {
	"中央アトラス・タマジクト語",
	"Q49741",
	"ber",
	scripts = {"Tfng", "Arab", "Latn"},
	translit_module = "Tfng-translit",
}

m["tzn"] = {
	"チューガン語",
	"Q12953225",
	"poz-tim",
}

m["tzo"] = {
	"ツォツィル語",
	"Q36809",
	"myn",
	scripts = Latn,
}

m["tzx"] = {
	"タブリアク語",
	"Q56872",
	"paa-lsp",
	otherNames = {"Karawari"},
	scripts = Latn,
}

return m