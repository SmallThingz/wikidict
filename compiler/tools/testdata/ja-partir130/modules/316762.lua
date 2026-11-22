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

local Cyrl = {"Cyrl"}
local Deva = {"Deva"}
local Latn = {"Latn"}
local Latinx = {"Latinx"}

local m = {}

m["kaa"] = {
	"カラカルパク語",
	"Q33541",
	"trk-kno",
	scripts = {"Latn", "Cyrl"},
}

m["kab"] = {
	"カビル語",
	"Q35853",
	"ber",
	scripts = Latn,
}

m["kac"] = {
	"ジンポー語",
	"Q33332",
	"sit-jnp",
	scripts = Latn,
}

m["kad"] = {
	"アダラ語",
	"Q3914011",
	"nic-plc",
	scripts = Latn,
}

m["kae"] = {
	"Ketangalan",
	"Q2779411",
	"map",
}

m["kaf"] = {
	"Katso",
	"Q246122",
	"tbq-lol",
	otherNames = {"Kazhuo"},
}

m["kag"] = {
	"カジャマン語",
	"Q6348863",
	"poz",
	scripts = Latn,
}

m["kah"] = {
	"カラ語",
	"Q5443742",
	"csu-bgr",
	otherNames = {"Kara"},
	scripts = Latn,
}

m["kai"] = {
	"カレカレ語",
	"Q3438770",
	"cdc-wst",
	scripts = Latn,
}

m["kaj"] = {
	"Jju",
	"Q35401",
	"nic-plc",
	scripts = Latn,
}

m["kak"] = {
	"カヤパ・カッラハン語",
	"Q3192220",
	"phi",
	scripts = Latn,
}

m["kam"] = {
	"カンバ語",
	"Q2574767",
	"bnt-kka",
	otherNames = {"Kikamba", "Kamba (Kenya)"},
	scripts = Latn,
}

m["kao"] = {
	"ハアソンガハンノ語",
	"Q36905",
	"dmn-wmn",
	otherNames = {"Khasonke", "Kasonke", "Khassonké"},
	scripts = Latn,
}

m["kap"] = {
	"ベジュタ語",
	"Q33054",
	"cau-tsz",
	otherNames = {"Bezheta", "Kapucha", "Bezhita"},
	scripts = Cyrl,
	translit_module = "kap-translit",
}

m["kaq"] = {
	"カパナワ語",
	"Q2937196",
	"sai-pan",
	otherNames = {"Kapanawa"},
	scripts = Latn,
}

m["kaw"] = {
	"カウィ語",
	"Q49341",
	"poz-sus",
	otherNames = {"Kawi"},
	scripts = {"Latn", "Java"},
	translit_module = "jv-translit", --same as jv
}

m["kax"] = {
	"カオ語",
	"Q3192799",
}

m["kay"] = {
	"カマユラ語",
	"Q3192336",
	"tup-gua",
	scripts = Latn,
}

m["kba"] = {
	"Kalarko",
	"Q5517764",
	"aus-pam",
	scripts = Latn,
}

m["kbb"] = {
	"カシュイアナ語",
	"Q12953626",
	"sai-car",
	otherNames = {"Kachuyana", "Kaxuiana", "Kaxuiâna", "Kashuyana"},
	scripts = Latn,
}

m["kbc"] = {
	"カドゥベオ語",
	"Q18168288",
	"sai-guc",
	otherNames = {"Caduveo", "Ediu-Adig", "Guaicurú", "Kadiweu", "Mbayá", "Mbayá-Guaycuru", "Waikurú"},
	scripts = Latn,
}

m["kbd"] = {
	"カバルド語",
	"Q33522",
	"cau-cir",
	otherNames = {"East Circassian"},
	scripts = Cyrl,
	translit_module = "kbd-translit",
	override_translit = true,	
}

m["kbe"] = {
	"カンジュ語",
	"Q10543322",
	"aus-pam",
	otherNames = {"Kaanytju", "Kandju", "Kaantyu", "Gandju", "Gandanju", "Kamdhue", "Kandyu", "Kanyu"},
	scripts = Latn,
}

m["kbh"] = {
	"カムサ語",
	"Q2842667",
	"qfa-iso",
	scripts = Latn,
}

m["kbi"] = {
	"Kaptiau",
	"Q6367294",
	"poz-oce",
	scripts = Latn,
}

m["kbj"] = {
	"カリ語",
	"Q6370438",
	"bnt-boa",
	otherNames = {"Kare", "Kare (Central African Republic)", "Bantoid Kare"},
	scripts = Latn,
}

m["kbk"] = {
	"草地コイアリ語",
	"Q12952642",
	"ngf",
	otherNames = {"Koiari"},
	scripts = Latn,
}

m["kbm"] = {
	"Iwal",
	"Q3156391",
	"poz-ocw",
	scripts = Latn,
}

m["kbn"] = {
	"Kare (Africa)",
	"Q35554",
	"alv-mbm",
	otherNames = {"Kare (Central African Republic)", "Mbum Kare"},
	scripts = Latn,
}

m["kbo"] = {
	"ケリコ語",
	"Q11275553",
	"csu-mma",
}

m["kbp"] = {
	"カビイェ語",
	"Q35475",
	"nic-gne",
	otherNames = {"Kabiye", "Kabye"},
	scripts = Latn,
}

m["kbq"] = {
	"カマノ語",
	"Q11732272",
	"paa-kag",
	scripts = Latn,
}

m["kbr"] = {
	"カファ語",
	"Q35481",
	"omv-gon",
	scripts = {"Ethi", "Latn"},
}

m["kbs"] = {
	"カンデ語",
	"Q35556",
	"bnt-tso",
	scripts = Latn,
}

m["kbt"] = {
	"アバディ語",
	"Q3291159",
	"poz-ocw",
	scripts = Latn,
}

m["kbu"] = {
	"Kabutra",
	"Q10966761",
	"inc-wes",
	ancestors = {"raj"},
}

m["kbv"] = {
	"ドゥラ語",
	"Q5261289",
	"paa",
	otherNames = {"Dera", "Dera (New Guinea)"},
	scripts = Latn,
}

m["kbw"] = {
	"カイエプ語",
	"Q6347632",
	"poz-ocw",
	scripts = Latn,
}

m["kbx"] = {
	"Ap Ma",
	"Q56298",
	"paa-ram",
}

m["kbz"] = {
	"Duhwa",
	"Q56295",
	"cdc-wst",
	scripts = Latn,
}

m["kca"] = {
	"ハンティ語",
	"Q33563",
	"urj-ugr",
	scripts = Cyrl,
	translit_module = "kca-translit",
	override_translit = true,
}

m["kcb"] = {
	"カワチャ語",
	"Q11732302",
	"ngf",
}

m["kcc"] = {
	"ルビラ語",
	"Q3914381",
	"nic-uce",
	scripts = Latn,
}

m["kcd"] = {
	"Ngkâlmpw Kanum",
	"Q12952566",
	"paa-yam",
}

m["kce"] = {
	"カイヴィ語",
	"Q6348685",
	"nic-kau",
}

m["kcf"] = {
	"ウカアン語",
	"Q36651",
	"nic-bco",
}

m["kcg"] = {
	"Tyap",
	"Q3912765",
	"nic-plc",
}

m["kch"] = {
	"Vono",
	"Q3913920",
	"nic-kau",
}

m["kci"] = {
	"Kamantan",
	"Q3914019",
	"nic-plc",
}

m["kcj"] = {
	"コビアナ語",
	"Q35609",
	"alv-nyn",
}

m["kck"] = {
	"カランガ語",
	"Q33672",
	"bnt-sho",
	scripts = Latn,
}

m["kcl"] = {
	"ケラ語 (パプアニューギニア)",
	"Q6349982",
	"poz-ocw",
	otherNames = {"Kala", "Kela", "Gela"},
	scripts = Latn,
}

m["kcm"] = {
	"グラ語",
	"Q277963",
	"csu-bba",
}

m["kcn"] = {
	"ヌビ語",
	"Q36388",
	"crp",
	otherNames = {"Ki-Nubi"},
	scripts = {"Latn", "Arab"},
	ancestors = {"apd"},
	entry_name = {
		from = {'Á', 'á', 'É', 'é', 'Í', 'í', 'Ó', 'ó', 'Ú', 'ú'},
		to   = {'A', 'a', 'E', 'e', 'I', 'i', 'O', 'o', 'U', 'u'}},
}

m["kco"] = {
	"キナラクナ語",
	"Q11732320",
	"ngf",
}

m["kcp"] = {
	"カンガ語",
	"Q6362384",
	"qfa-kad",
	scripts = Latn,
}

m["kcq"] = {
	"カモ語",
	"Q3914879",
	"alv-wjk",
}

m["kcr"] = {
	"カトラ語",
	"Q35688",
	"nic-ktl",
}

m["kcs"] = {
	"カナム語",
	"Q3438755",
	"cdc-wst",
}

m["kct"] = {
	"カイアン語",
	"Q6347538",
	"paa-ram",
}

m["kcu"] = {
	"カミ語",
	"Q3915212",
	"bnt-ruv",
	otherNames = {"Kami"},
	scripts = Latn,
}

m["kcv"] = {
	"ケテ語",
	"Q3195598",
	"bnt-lub",
}

m["kcw"] = {
	"カブワリ語",
	"Q6344539",
	"bnt-glb",
}

m["kcx"] = {
	"カチャマ＝ガンジュレ語",
	"Q12634070",
	"omv-eom",
}

m["kcy"] = {
	"Korandje",
	"Q33427",
	"son",
}

m["kcz"] = {
	"コノンゴ語",
	"Q11732345",
	"bnt-tkm",
	scripts = Latn,
}

m["kda"] = {
	"ウオリミ語",
	"Q3914062",
	"aus-pam",
	otherNames = {"Gadang", "Gadhang", "Gadjang", "Kattang", "Kutthung"},
	scripts = Latn,
}

m["kdc"] = {
	"クトゥ語",
	"Q6448634",
	"bnt-ruv",
}

m["kdd"] = {
	"ヤンクンチャジャーラ語",
	"Q34207",
	"aus-pam",
	scripts = Latn,
}

m["kde"] = {
	"マコンデ語",
	"Q35172",
	"bnt-rvm",
	scripts = Latn,
}

m["kdf"] = {
	"マムシ語",
	"Q6746036",
	"poz-ocw",
	scripts = Latn,
}

m["kdg"] = {
	"セバ語",
	"Q7442316",
	"bnt-sbi",
	scripts = Latn,
}

m["kdh"] = {
	"テム語",
	"Q36531",
	"nic-gne",
}

m["kdi"] = {
	"クマム語",
	"Q6443410",
	"sdv-los",
	otherNames = {"Kuman"},
}

m["kdj"] = {
	"カラモジョン語",
	"Q56326",
	"sdv-ttu",
	scripts = Latn,
}

m["kdk"] = {
	"Numee",
	"Q3346774",
	"poz-cln",
}

m["kdl"] = {
	"Tsikimba",
	"Q3914404",
	"nic-kam",
}

m["kdm"] = {
	"カゴマ語",
	"Q3914420",
	"nic-plc",
}

m["kdn"] = {
	"クンダ語",
	"Q4121130",
	"bnt-sna",
}

m["kdp"] = {
	"Kaningdon-Nindem",
	"Q3914956",
	"nic-nin",
}

m["kdq"] = {
	"コチ語",
	"Q56431",
	"tbq-bdg",
}

m["kdr"] = {
	"カライム語",
	"Q33725",
	"trk-kcu",
	scripts = {"Cyrl", "Latn", "Hebr"},
}

m["kdt"] = {
	"クイ語",
	"Q56310",
	"mkh-kat",
}

m["kdu"] = {
	"カダル語",
	"Q35441",
	"nub-hil",
	otherNames = {"Kedaru", "Debri"}, -- Debri is subsumed for now as it lacks an ISO code, may need to be split
	scripts = Latn,
}

m["kdv"] = {
	"カド語",
	"Q7402721",
	"sit-luu",
	otherNames = {"Kadu"},
}

m["kdw"] = {
	"コネラウ語",
	"Q11732341",
	"ngf",
}

m["kdx"] = {
	"カム語",
	"Q36753",
	"alv-wjk",
}

m["kdy"] = {
	"Keder",
	"Q6383641",
	"paa-tkw",
}

m["kdz"] = {
	"Kwaja",
	"Q11128866",
	"nic-nka",
	otherNames = {"Ndaktup", "Ncha", "Bitwi"},
	scripts = Latn,
}

m["kea"] = {
	"カーボベルデ・クレオール語",
	"Q35963",
	"crp",
	otherNames = {"Cape Verdean Creole", "Kriolu", "Creole", "Barlavento", "Sotavento"},
	scripts = Latn,
	ancestors = {"pt"},
}

m["keb"] = {
	"ケレ語 (ガボン)",
	"Q35559",
	"bnt-kel",
}

m["kec"] = {
	"ケイガ語",
	"Q3409311",
	"qfa-kad",
	scripts = Latn,
}

m["ked"] = {
	"ケレウェ語",
	"Q6393846",
	"bnt-haj",
}

m["kee"] = {
	"東部ケレス語",
	"Q15649021",
	"nai-ker",
	scripts = Latn,
}

m["kef"] = {
	"Kpessi",
	"Q35748",
	"alv-gbe",
}

m["keg"] = {
	"Tese",
	"Q16887296",
	"sdv",
}

m["keh"] = {
	"Keak",
	"Q6382110",
	"paa-spk",
}

m["kei"] = {
	"ケイ語",
	"Q2410352",
}

m["kej"] = {
	"カダル語",
	"Q6345179",
	"dra",
}

m["kek"] = {
	"ケクチ語",
	"Q35536",
	"myn",
	scripts = Latn,
}

m["kel"] = {
	"ケラ語 (コンゴ民主共和国)",
	"Q6385426",
	"bnt-mon",
	otherNames = {"Kela", "Kela-Yela", "Lemba", "Yela"},
	scripts = Latn,
}

m["kem"] = {
	"ケマク語",
	"Q35549",
	"poz-tim",
}

m["ken"] = {
	"Kenyang",
	"Q35650",
	"nic-mam",
	scripts = Latn,
}

m["keo"] = {
	"カクワ語",
	"Q3033547",
	"sdv-bri",
}

m["kep"] = {
	"Kaikadi",
	"Q6347757",
	"dra",
}

m["keq"] = {
	"カマル語",
	"Q14916877",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["ker"] = {
	"ケラ語 (チャド)",
	otherNames = "Kera",
	"Q56251",
	"cdc-est",
	scripts = Latn,
}

m["kes"] = {
	"クグボ語",
	"Q3813394",
	"nic-cde",
	scripts = Latn,
}

m["ket"] = {
	"ケット語",
	"Q33485",
	"qfa-yen",
	scripts = Cyrl,
}

m["keu"] = {
	"アケブ語",
	"Q35026",
	"alv-ktg",
}

m["kev"] = {
	"Kanikkaran",
	"Q6363201",
	"dra",
}

m["kew"] = {
	"西ケワ語",
	"Q12952619",
	"paa-eng",
	otherNames = {"West Kewa", "East Kewa", "South Kewa", "Erave", "Pasuma"},
	scripts = Latn,
}

m["kex"] = {
	"クックナ語",
	"Q5031131",
	"inc-eas",
	ancestors = {"bh"},
}

m["key"] = {
	"Kupia",
	"Q6445354",
	"inc-eas",
}

m["kez"] = {
	"クケレ語",
	"Q3915391",
	"nic-ucn",
	scripts = Latn,
}

m["kfa"] = {
	"コダヴァ語",
	"Q33531",
	"dra",
	scripts = {"Knda"},
}

m["kfb"] = {
	"北西部コーラーミー語",
	"Q33479",
	"dra",
	scripts = Deva,
}

m["kfc"] = {
	"コンダ＝ドラ語",
	"Q35679",
	"dra",
	scripts = {"Telu"},
}

m["kfd"] = {
	"Korra Koraga",
	"Q12952655",
	"dra",
	scripts = {"Knda"},
}

m["kfe"] = {
	"コータ語（インド）",
	"Q33483",
	"dra",
	otherNames = {"Kota"},
	scripts = {"Taml"},
}

m["kff"] = {
	"コーヤ語",
	"Q33471",
	"dra",
}

m["kfg"] = {
	"クディヤ語",
	"Q12952667",
	"dra",
}

m["kfh"] = {
	"Kurichiya",
	"Q12952676",
	"dra",
}

m["kfi"] = {
	"カンナダ・クルンバ語",
	"Q56589",
	"dra",
}

m["kfj"] = {
	"クミエ語",
	"Q27144776",
	"mkh-pal",
}

m["kfk"] = {
	"キナウル語",
	"Q2383208",
	"sit-kin",
}

m["kfl"] = {
	"クン語",
	"Q6444510",
	"nic-rnc",
	scripts = Latn,
}

m["kfn"] = {
	"Kuk",
	"Q6442398",
	"nic-rnc",
	scripts = Latn,
}

m["kfo"] = {
	"コロ語（西アフリカ）",
	"Q11160588",
	"dmn-mnk",
	otherNames = {"Koro", "Koro Jula"}, -- the last name is misleading, as Jula is a diff. language
	scripts = {"Latn", "Nkoo"},
}

m["kfp"] = {
	"コルワ語",
	"Q6432786",
	"mun",
}

m["kfq"] = {
	"コルク語",
	"Q33715",
	"mun",
}

m["kfr"] = {
	"カッチ語",
	"Q56487",
	"inc-snd",
	otherNames = {"Kutchi", "Cutchi", "Kachchhi", "Kutchhi"},
	translit_module = "gu-translit",
	scripts = {"Gujr", "sd-Arab"},
	ancestors = {"inc-vra"},
}

m["kfs"] = {
	"ビラースプリ語",
	"Q12953397",
	"him",
	scripts = {"Deva", "Takr"},
	translit_module = "hi-translit",
}

m["kft"] = {
	"キナウル語",
	"Q12953610",
	"inc-pan",
	ancestors = {"pa"},
}

m["kfu"] = {
	"カトカリ語",
	"Q6377671",
	"inc-sou",
	ancestors = {"pmh"},
}

m["kfv"] = {
	"クルムカル語",
	"Q6446193",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["kfw"] = {
	"Kharam Naga",
	"Q12952906",
	"tbq-kuk",
	otherNames = {"Kharam"},
}

m["kfx"] = {
	"クッルー・パハリー語",
	"Q6443148",
	"him",
	otherNames = {"Kullu"},
	scripts = Deva,
	translit_module = "hi-translit",
}

m["kfy"] = {
	"クマオニ語",
	"Q33529",
	"inc-pah",
	scripts = {"Deva", "Shrd", "Takr"},
}

m["kfz"] = {
	"Koromfé",
	"Q35701",
	"nic-gur",
	scripts = Latn,
}

m["kga"] = {
	"Koyaga",
	"Q11155632",
	"dmn-mnk",
}

m["kgb"] = {
	"Kawe",
	"Q12952750",
	"poz-hce",
}

m["kgd"] = {
	"カタン語",
	"Q12953622",
	"mkh",
}

m["kge"] = {
	"コメリン語",
	"Q49224",
	"poz-lgx",
}

m["kgf"] = {
	"クベ語",
	"Q11732359",
	"ngf",
}

m["kgg"] = {
	"クスンダ語",
	"Q33630",
	"qfa-iso",
	scripts = Latn,
}

m["kgi"] = {
	"セランゴール手話",
	"Q33731",
	"sgn",
}

m["kgj"] = {
	"Gamale Kham",
	"Q22236996",
	"sit-kha",
}

m["kgk"] = {
	"カイワ語",
	"Q3111883",
	"tup-gua",
	scripts = Latn,
}

m["kgl"] = {
	"Kunggari",
	"Q10550184",
	"aus-pam",
}

m["kgm"] = {
	"カリプナ語",
	"Q6371069",
}

m["kgn"] = {
	"カリンガニ語",
	"Q6371041",
	"xme-ttc",
	otherNames = {"Keringani"},
	ancestors = {"xme-ttc-nor"},
}

m["kgo"] = {
	"クロンゴ語",
	"Q6438927",
	"qfa-kad",
	scripts = Latn,
}

m["kgp"] = {
	"カインガング語",
	"Q2665734",
	"sai-sje",
	scripts = Latn,
}

m["kgq"] = {
	"カモロ語",
	"Q6359001",
	"ngf",
}

m["kgr"] = {
	"Abun",
	"Q56657",
	"paa",
}

m["kgs"] = {
	"Kumbainggar",
	"Q3915412",
	"aus-pam",
}

m["kgt"] = {
	"Somyev",
	"Q3913354",
	"nic-mmb",
	scripts = Latn,
}

m["kgu"] = {
	"Kobol",
	"Q11732325",
	"ngf-mad",
}

m["kgv"] = {
	"カラス語",
	"Q6368621",
	"ngf",
}

m["kgw"] = {
	"Karon Dori",
	"Q56817",
}

m["kgx"] = {
	"Kamaru",
	"Q12953604",
	"poz",
}

m["kgy"] = {
	"Kyerung",
	"Q12952691",
	"sit-kyk",
}

m["kha"] = {
	"カシ語",
	"Q33584",
	"aav-pkl",
	scripts = {"Latn", "as-Beng"},
}

m["khb"] = {
	"タイ・ルー語",
	"Q36948",
	"tai-swe",
	aliases = {"Lue", "Tai Lü", "Tai Lue", "Dai Lue"},
	scripts = {"Talu", "Lana"},
	translit_module = "translit-redirect",
	sort_key = {
		from = {"[%pᪧ]", "᧞", "᧟", "([ᦵᦶᦷᦺ])([ᦀ-ᦫ])", "[᩠ᩳ-᩿]", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ"},
		to = {"", "ᦶᦜ", "ᦶᦜᧁ", "%2%1", "", "ᩈᩈ", "ᩁ", "ᩃ", "ᨦ", "%1ᨮ", "%1ᨻ", "ᩣ"}},
	entry_name = {
		from = {" "},
		to = {""}},
}

m["khc"] = {
	"トゥカンブシ北語",
	"Q18611555",
	"poz",
}

m["khd"] = {
	"Bädi Kanum",
	"Q20888004",
	"paa-yam",
}

m["khe"] = {
	"コロワイ語",
	"Q6432598",
	"ngf",
}

m["khf"] = {
	"Khuen",
	"Q27144893",
	"mkh",
}

m["khh"] = {
	"Kehu",
	"Q10994953",
}

m["khj"] = {
	"クトゥルミ語",
	"Q3914490",
	"nic-plc",
	scripts = Latn,
}

m["khk"] = {
	"ハルハ・モンゴル語",
	"Q6399808",
	"xgn",
	otherNames = {"Khalkha Mongolian", "Mongolian (Khalkha)"}
}

m["khl"] = {
	"ルシ語",
	"Q3267788",
	"poz-ocw",
	scripts = Latn,
}

m["khn"] = {
	"カーンデーシュ語",
	"Q33726",
	"inc-sou",
	ancestors = {"pmh"},
}

m["kho"] = {
	"コータン語",
	"Q6583551",
	"xsc-sak",
	scripts = {"Brah", "Khar"},
	translit_module = "Brah-translit",
}

m["khp"] = {
	"カポリ語",
	"Q3502575",
	"paa-tkw",
}

m["khq"] = {
	"Koyra Chiini",
	"Q33600",
	"son",
	otherNames = {"Western Songhay", "Koyra Chiini Songhay"},
}

m["khr"] = {
	"カリア語",
	"Q3915562",
	"mun",
}

m["khs"] = {
	"カスア語",
	"Q6374863",
	"ngf",
}

m["kht"] = {
	"カムティー語",
	"Q3915502",
	"tai-swe",
}

m["khu"] = {
	"Nkhumbi",
	"Q11019169",
	"bnt-swb",
}

m["khv"] = {
	"フバルシ語",
	"Q56425",
	"cau-tsz",
	otherNames = {"Khwarshi", "Xvarshi", "Inkhokvari"},
	scripts = Cyrl,
	translit_module = "khv-translit",
}

m["khw"] = {
	"コワール語",
	"Q938216",
	"inc-dar",
	scripts = {"Arab"},
}

m["khx"] = {
	"Kanu",
	"Q12952571",
	"bnt-lgb",
}

m["khy"] = {
	"ケレ語 (コンゴ民主共和国)",
	"Q6385549",
	"bnt-ske",
	otherNames = {"Ekele", "Kele", "Kele (Congo)", "Kele (Democratic Republic of the Congo)", "Lokele"},
	scripts = Latn,
}

m["khz"] = {
	"ケアパラ語",
	"Q12952603",
	"poz-ocw",
	scripts = Latn,
}

m["kia"] = {
	"キム語",
	"Q35685",
	"alv-kim",
}

m["kib"] = {
	"コアリブ語",
	"Q35859",
	"alv-hei",
}

m["kic"] = {
	"キカプー語",
	"Q20162127",
	"alg-sfk",
	scripts = Latn,
}

m["kid"] = {
	"Koshin",
	"Q35632",
	"nic-beb",
	scripts = Latn,
}

m["kie"] = {
	"キベト語",
	"Q56893",
}

m["kif"] = {
	"東部パルバテ・カム語",
	"Q12953022",
	"sit-kha",
}

m["kig"] = {
	"Kimaama",
	"Q11732321",
	"ngf",
}

m["kih"] = {
	"キルメリ語",
	"Q6408020",
	"paa-brd",
}

m["kii"] = {
	"キツァイ語",
	"Q56627",
	"cdd",
	otherNames = {"Kichai"},
	scripts = Latn,
}

m["kij"] = {
	"キリヴィラ語",
	"Q3196601",
	"poz-ocw",
	scripts = Latn,
}

m["kil"] = {
	"カリヤ語",
	"Q3438708",
	"cdc-wst",
}

m["kim"] = {
	"トファ語",
	"Q36848",
	"trk-sib",
	otherNames = {"Tofalar", "Karagas"},
	scripts = Cyrl,
}

m["kio"] = {
	"カイオワ語",
	"Q56631",
	"nai-kta",
	scripts = Latn,
}

m["kip"] = {
	"Sheshi Kham",
	"Q12952622",
	"sit-kha",
}

m["kiq"] = {
	"Kosadle",
	"Q6432994",
}

m["kis"] = {
	"キス語",
	"Q6416362",
	"poz-ocw",
	scripts = Latn,
}

m["kit"] = {
	"アゴブ語",
	"Q3332143",
}

m["kiv"] = {
	"キンブ語",
	"Q10997740",
	"bnt-tkm",
}

m["kiw"] = {
	"北東部キワイ語",
	"Q11732324",
	"paa-kiw",
}

m["kix"] = {
	"キアムニウンガン・ナガ語",
	"Q6401546",
	"sit-kch",
}

m["kiy"] = {
	"Kirikiri",
	"Q6415159",
	"paa-lkp",
	otherNames = {"Faia"},
}

m["kiz"] = {
	"キスィ語",
	"Q3912772",
	"bnt-bki",
}

m["kja"] = {
	"Mlap",
	"Q6885683",
	"paa-nim",
}

m["kjb"] = {
	"カンホバル語",
	"Q35551",
	"myn",
	scripts = Latn,
}

m["kjc"] = {
	"海岸コンジョ語",
	"Q3198689",
	"poz",
}

m["kjd"] = {
	"南部キワイ語",
	"Q11732322",
	"paa-kiw",
}

m["kje"] = {
	"キサール語",
	"Q3197441",
	"poz",
}

m["kjg"] = {
	"クム語",
	otherNames = {"Khmu", "Khmu'"},
	"Q33335",
	"mkh",
	scripts = {"Laoo"},
	sort_key = {
		from = {"[%pໆ]", "[່-ໍ]", "ຼ", "ຽ", "ໜ", "ໝ", "([ເແໂໃໄ])([ກ-ຮໞໟ])"},
		to   = {"", "", "ລ", "ຍ", "ຫນ", "ຫມ", "%2%1"}},
}

m["kjh"] = {
	"ハカス語",
	"Q33575",
	"trk-sib",
	scripts = Cyrl,
	translit_module = "kjh-translit",
	override_translit = true,
}

m["kji"] = {
	"ザバナ語",
	"Q379130",
	"poz-ocw",
	scripts = Latn,
}

m["kjj"] = {
	"キナルグ語",
	"Q35278",
	"cau-nec",
	otherNames = {"Khinalig", "Xinalug", "Xinalugh", "Khinalugh"},
	scripts = Cyrl,
	translit_module = "kjj-translit",
	override_translit = true,
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["kjk"] = {
	"山地コンジョ語",
	"Q3198688",
	"poz",
}

m["kjl"] = {
	"西部パルバテ・カム語",
	"Q22237017",
	"sit-kha",
}

m["kjm"] = {
	"カン語",
	"Q6403501",
	"mkh-pal",
}

m["kjn"] = {
	"クンジェン語",
	"Q3200468",
	"aus-pmn",
	otherNames = {"Uw Oykangand", "Uw Olkola", "Olkol", "Olgolo", "Uw-Oykangand", "Uw-Olgol", "Koko Wanggara", "Ogh-Undjan", "Undjan", "Kawarrangg", "Athima", "Uw", "Kunjen-Undjan-Athima"},
	scripts = Latn,
}

m["kjo"] = {
	"ハリジャン・キナウル語",
	"Q5657463",
	"him",
}

m["kjp"] = {
	"ポー東部カレン語",
	"Q5330390",
	"kar",
	aliases = {"Phlou", "Eastern Pwo Karen"},
	scripts = {"Mymr", "Leke", "Thai"},
}

m["kjq"] = {
	"西部ケレス語",
	"Q12645568",
	"nai-ker",
	scripts = Latn,
}

m["kjr"] = {
	"クルドゥ語",
	"Q12952678",
	"poz-hce",
	scripts = Latn,
}

m["kjs"] = {
	"東ケワ語",
	"Q20050949",
	"paa-eng",
}

m["kjt"] = {
	"プレー・ポー・カレン語",
	"Q7187991",
	"kar",
	aliases = {"Phrae Pwo Karen", "Northeastern Pwo", "Northeastern Pwo Karen"},
	scripts = {"Thai"},
}

m["kju"] = {
	"Kashaya",
	"Q3193689",
	"nai-pom",
	scripts = Latn,
}

m["kjx"] = {
	"Ramopa",
	"Q56830",
	"paa-nbo",
	otherNames = {"Keriaka"},
}

m["kjy"] = {
	"エラヴェ語",
	"Q12952416",
	"paa-eng",
}

m["kjz"] = {
	"ブムタンカ語",
	"Q2786408",
	"sit-ebo",
	scripts = {"Tibt"},
}

m["kka"] = {
	"カカンダ語",
	"Q3915342",
	"alv-ngb",
}

m["kkb"] = {
	"クェリサ語",
	"Q56881",
	"paa-lkp",
}

m["kkc"] = {
	"Odoodee",
	"Q12952987",
}

m["kkd"] = {
	"キヌク語",
	"Q6414422",
	"nic-kau",
}

m["kke"] = {
	"Kakabe",
	"Q3913966",
	"dmn-mok",
	scripts = Latn,
}

m["kkf"] = {
	"カラクタン・モンパ語",
	nil,
	"sit-tsk",
}

m["kkg"] = {
	"Mabaka Valley Kalinga",
	"Q18753304",
	"phi",
}

m["kkh"] = {
	"ゴンシャン語",
	"Q3545044",
	"tai-swe",
	otherNames = {"クン語", "Khün", "Gon Shan", "Tai Khün", "Dai Kun"},
	scripts = {"Lana", "Thai"},
	sort_key = {
		from = {"[%pᪧๆ]", "[᩠ᩳ-᩿]", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "ᩈᩈ", "ᩁ", "ᩃ", "ᨦ", "%1ᨮ", "%1ᨻ", "ᩣ", "", "%2%1"}},
}

m["kki"] = {
	"カグル語",
	"Q12952537",
	"bnt-ruv",
	otherNames = {"Kaguru"},
	scripts = Latn,
}

m["kkj"] = {
	"カコ語",
	"Q35755",
	"bnt-kak",
}

m["kkk"] = {
	"ココタ語",
	"Q3198399",
	"poz-ocw",
	scripts = Latn,
}

m["kkl"] = {
	"Kosarek Yale",
	"Q6432995",
	"ngf",
}

m["kkm"] = {
	"キオン語",
	"Q6414512",
	"nic-ucr",
	scripts = Latn,
}

m["kkn"] = {
	"コン・ク語",
	"Q6428686",
	"mkh-pal",
}

m["kko"] = {
	"カルコ語",
	"Q35529",
	"nub-hil",
	otherNames = {"Kithonirishe"},
}

m["kkp"] = {
	"Koko-Bera",
	"Q6426699",
	"aus-pmn",
	otherNames = {"Kok-Kaper", "Gugubera", "Koko-Pera"},
	scripts = Latn,
}

m["kkq"] = {
	"カイク語",
	"Q6347840",
	"bnt-kbi",
	scripts = Latn,
}

m["kkr"] = {
	"キル・バラル語",
	"Q3440527",
	"cdc-wst",
	otherNames = {"Kir"},
	scripts = Latn,
}

m["kks"] = {
	"Kirfi",
	"Q56242",
	"cdc-wst",
	otherNames = {"Giiwo"},
	scripts = Latn,
}

m["kkt"] = {
	"コイ語",
	"Q6426194",
	"sit-kiw",
}

m["kku"] = {
	"Tumi",
	"Q3913934",
	"nic-kau",
}

m["kkv"] = {
	"カゲアン語",
	"Q2071325",
}

m["kkw"] = {
	"テケ＝ククヤ語",
	"Q36560",
	"bnt-tek",
}

m["kkx"] = {
	"Kohin",
	"Q6425997",
	"poz-brw",
}

m["kky"] = {
	"グーグ・イミディル語",
	"Q56543",
	"aus-pam",
	scripts = Latn,
}

m["kkz"] = {
	"カスカ語",
	"Q20823",
	"ath-nor",
	scripts = Latn,
}

m["kla"] = {
	"クラマス＝モードック語",
	"Q2669248",
	"nai-plp",
	otherNames = {"Klamath"},
	scripts = Latn,
}

m["klb"] = {
	"キリワ語",
	"Q3182593",
	"nai-yuc",
	scripts = Latn,
}

m["klc"] = {
	"コルビラ語",
	"Q6427122",
	"alv-lek",
}

m["kld"] = {
	"ガミララーイ語",
	"Q3111818",
	"aus-cww",
	otherNames = {"Kamilaroi", "Kamilarai", "Kamalarai", "Gamilaroi"},
	scripts = Latn,
}

m["kle"] = {
	"クルン語",
	"Q6443304",
	"sit-kic",
}

m["klf"] = {
	"Kendeje",
	"Q56895",
}

m["klg"] = {
	"タガカウル語",
	"Q18756514",
	"phi",
}

m["klh"] = {
	"ウェリキ語",
	"Q7981017",
	"ngf-fin",
	scripts = Latn,
}

m["kli"] = {
	"カルンパン語",
	"Q13561407",
	"poz",
}

m["klj"] = {
	"ハラジ語",
	"Q33455",
	"trk",
	otherNames = {"Turkic Khalaj", "Arghu"},
}

m["klk"] = {
	"コノ語（ナイジェリア）",
	"Q6429589",
	"nic-kau",
	otherNames = {"Kono"},
	scripts = Latn,
}

m["kll"] = {
	"カガン・カラガン語",
	"Q18748913",
	"phi",
}

m["klm"] = {
	"Kolom",
	"Q6844970",
	"ngf-mad",
	otherNames = {"Migum"},
	scripts = Latn,
}

m["kln"] = {
	"カレンジン語",
	"Q637228",
	"sdv-nma",
	scripts = Latn,
}

m["klo"] = {
	"Kapya",
	"Q6367410",
	"nic-ykb",
}

m["klp"] = {
	"カマサ語",
	"Q6356107",
	"ngf",
}

m["klq"] = {
	"Rumu",
	"Q7379420",
	"ngf",
}

m["klr"] = {
	"カリン語",
	"Q56381",
	"sit-kiw",
}

m["kls"] = {
	"カラシュ語",
	"Q33416",
	"inc-dar",
	scripts = {"Latn", "ks-Arab"},
}

m["klt"] = {
	"Nukna",
	"Q7068874",
	"ngf-fin",
	scripts = Latn,
}

m["klu"] = {
	"クラオ語",
	"Q3914866",
	"kro-wkr",
}

m["klv"] = {
	"マスケリネス語",
	"Q3297282",
	"poz-vnc",
	scripts = Latn,
}

m["klw"] = {
	"リンドゥ語",
	"Q18390055",
	"poz-kal",
	otherNames = {"Tado"},
}

m["klx"] = {
	"Koluwawa",
	"Q6427954",
	"poz-ocw",
	scripts = Latn,
}

m["kly"] = {
	"カラオ語",
	"Q6350643",
	"poz",
}

m["klz"] = {
	"カボラ語",
	"Q11732258",
	"qfa-tap",
}

m["kma"] = {
	"Konni",
	"Q35680",
	"nic-buk",
}

m["kmb"] = {
	"キンブンド語",
	"Q35891",
	"bnt-kmb",
	otherNames = {"North Mbundu"},
	scripts = Latn,
}

m["kmc"] = {
	"南部トン語",
	"Q35379",
	"qfa-kms",
	otherNames = {"Southern Gam", "Southern Dong"},
	scripts = Latn,
}

m["kmd"] = {
	"Madukayang Kalinga",
	"Q18753305",
	"phi",
}

m["kme"] = {
	"Bakole",
	"Q35068",
	"bnt-kpw",
}

m["kmf"] = {
	"Kare (New Guinea)",
	"Q11732286",
	"ngf-mad",
	otherNames = {"Kare", "Kare (Papua New Guinea)"},
	scripts = Latn,
}

m["kmg"] = {
	"カーテ語",
	"Q3201059",
	"ngf",
}

m["kmh"] = {
	"カラム語",
	"Q12952550",
	"ngf-mad",
}

m["kmi"] = {
	"カミ語",
	"Q3915372",
	"alv-ngb",
	scripts = Latn,
}

m["kmj"] = {
	"Kumarbhag Paharia",
	"Q3130374",
	"dra",
	otherNames = {"Kumarbhag", "Kumarbhag Pahariya", "Kumar Paharia", "Malto"},
	scripts = {"Beng", "Deva"},
}

m["kmk"] = {
	"リモス・カリンガ語",
	"Q18753303",
	"phi",
}

m["kml"] = {
	"タヌダン・カリンガ語",
	"Q18753307",
	"phi",
	otherNames = {"Lower Tanudan Kalinga", "Upper Tanudan Kalinga"},
	scripts = Latn,
}

m["kmm"] = {
	"コム語（インド）",
	"Q12952647",
	"tbq-kuk",
	otherNames = {"Kom"},
}

m["kmn"] = {
	"Awtuw",
	"Q3504217",
	"paa-spk",
}

m["kmo"] = {
	"クウォマ語",
	"Q11732376",
	"paa-spk",
}

m["kmp"] = {
	"Gimme",
	"Q11152236",
	"alv-dur",
}

m["kmq"] = {
	"クワマ語",
	"Q2591184",
	"ssa-kom",
}

m["kmr"] = {
	"クルマンジー",
	"Q36163",
	"ira-nwi",
	otherNames = {"Kurmanji"},
	scripts = {"Latn", "Cyrl", "Armn", "ku-Arab"},
	ancestors = {"ku"},
	translit_module = "translit-redirect",
	entry_name = {
		from = {"'"},
		to   = {"’"}},
	wikimedia_codes = {"ku"},
}

m["kms"] = {
	"カマサウ語",
	"Q6356117",
	"qfa-tor",
	scripts = Latn,
}

m["kmt"] = {
	"ケムトゥク語",
	"Q6387179",
	"paa-nim",
}

m["kmu"] = {
	"Kanite",
	"Q12952567",
	"paa-kag",
}

m["kmv"] = {
	"カリプナ・フランス語クレオル",
	"Q2523999",
	"crp",
	otherNames = {"Karipúna French Creole", "Amapá French Creole"},
	ancestors = {"fr"},
}

m["kmw"] = {
	"クム語 (コンゴ民主共和国)",
	otherNames = "Kumu",
	"Q6428450",
	"bnt-kbi",
	otherNames = {"Kikomo", "Komo (Democratic Republic of the Congo)", "Komo", "Kikumu"},
	scripts = Latn,
}

m["kmx"] = {
	"Waboda",
	"Q7958705",
	"paa-kiw",
}

m["kmy"] = {
	"コマ語",
	"Q35634",
	"alv-dur",
}

m["kmz"] = {
	"ホラーサーニー・トルコ語",
	"Q35373",
	"trk-ogz",
	otherNames = {"Khorasani Turkic"},
	ancestors = {"trk-oat"},
}

m["kna"] = {
	"デラ語",
	"Q56811",
	"cdc",
	otherNames = {"Dera", "Dera (Nigeria)"},
	scripts = Latn,
}

m["knb"] = {
	"ルブアガン・カリンガ語",
	"Q12953602",
	"phi",
}

m["knd"] = {
	"コンダ語",
	"Q11732340",
	"ngf-sbh",
	scripts = Latn,
}

m["kne"] = {
	"カンカナウイ語",
	"Q18753329",
	"phi",
	scripts = Latn,
}

m["knf"] = {
	"マンカニャ語",
	"Q35789",
	"alv-pap",
}

m["kni"] = {
	"カヌフィ語",
	"Q3913297",
	"nic-nin",
	scripts = Latn,
}

m["knj"] = {
	"アカテク語",
	"Q34923",
	"myn",
	otherNames = {"Acateco", "Western Kanjobal"},
	scripts = Latn,
}

m["knk"] = {
	"クランコ語",
	"Q3198896",
	"dmn-mok",
	scripts = Latn,
}

m["knl"] = {
	"Keninjal",
	"Q6389309",
	"poz-mly",
}

m["knm"] = { -- two unrelated lects have this name; this is the Katukinian one
	"カナマリ語",
	"Q3438373",
	"sai-ktk",
	otherNames = {"Kanamarí", "Katukina-Kanamari", "Kanamare", "Katukína", "Katukina"},
	scripts = Latn,
}

m["kno"] = {
	"コノ語（シエラレオネ）",
	"Q35675",
	"dmn-vak",
	otherNames = {"Kono", "Konnoh"},
}

m["knp"] = {
	"Kwanja",
	"Q35641",
	"nic-mmb",
	scripts = Latn,
}

m["knq"] = {
	"キンタック語",
	"Q6414335",
	"mkh-asl",
}

m["knr"] = {
	"カニングラ語",
	"Q6363253",
	"paa-spk",
}

m["kns"] = {
	"ケンスィウ語",
	"Q6391529",
	"mkh-asl",
}

m["knt"] = {
	"パノ・カトキナ語",
	"Q3194265",
	"sai-pan",
	otherNames = {"Panoan Katukína", "Katukína", "Catuquina", "Waninawa", "Waninnawa", "Kamanawa", "Kamannaua", "Katukina do Jurua", "Katukina of Olinda", "Katukina of Sete Estreles", "Kanamari"},
	scripts = Latn,
}

m["knu"] = { -- a dialect of 'kpe'
	"コノ語（ギニア）",
	"Q3198703",
	"dmn-msw",
	otherNames = {"Kono"},
	scripts = Latn,
	ancestors = {"kpe"},
}

m["knv"] = {
	"Tabo",
	"Q7959888",
	"aav",
}

m["knx"] = {
	"クンダヤン語",
	"Q6388963",
	"poz-mly",
	otherNames = {"Salako", "Selako", "Ahe"},
	scripts = Latn,
}

m["kny"] = {
	"カニョク語",
	otherNames = {"Kanyok", "Kanioka"},
	"Q11110766",
	"bnt-lub",
}

m["knz"] = {
	"Kalamsé",
	"Q3914000",
	"nic-gnn",
}

m["koa"] = {
	"Konomala",
	"Q3198732",
	"poz-ocw",
	scripts = Latn,
}

m["koc"] = {
	"クパティ語",
	"Q3913279",
	"nic-nge",
	scripts = Latn,
}

m["kod"] = {
	"コディ語",
	"Q4577633",
}

m["koe"] = {
	"Kacipo-Balesi",
	"Q5364424",
	"sdv",
}

m["kof"] = {
	"クビ語",
	"Q3438718",
	"cdc",
	scripts = Latn,
}

m["kog"] = {
	"コウギ語",
	"Q3198286",
	"cba",
	otherNames = {"Kogi", "Cogi", "Kagaba", "Cagaba", "Cágaba"},
}

m["koh"] = {
	"コヨ語",
	otherNames = {"Koyo"},
	"Q35649",
	"bnt-mbo",
	scripts = Latn,
}

m["koi"] = {
	"コミ・ペルミャク語",
	"Q56318",
	"urj-prm",
	scripts = {"Cyrl", "Perm"},
	translit_module = "kv-translit",
	override_translit = true,	
}

m["kok"] = {
	"コンカニ語",
	"Q34239",
	"inc-sou",
	scripts = {"Deva", "Knda", "Mlym", "fa-Arab", "Latn"},
	ancestors = {"pmh"},
	translit_module = "mr-translit",
}

m["kol"] = {
	"コル語（パプアニューギニア）",
	"Q4227542",
	otherNames = {"Kol", "Kol (Papua New Guina)"},
}

m["koo"] = {
	"コンゾ語",
	"Q2361829",
	"bnt-glb",
}

m["kop"] = {
	"Waube",
	"Q11732373",
	otherNames = {"Waupe", "Kwato"},
	"ngf-mad",
}

m["koq"] = {
	"コタ語 (ガボン)",
	"Q35607",
	"bnt-kel",
	otherNames = {"iKota", "Ikota", "Kota"},
	scripts = Latn,
}

m["kos"] = {
	"コスラエ語",
	"Q33464",
	"poz-mic",
	scripts = Latn,
}

m["kot"] = {
	"ラグワン語",
	"Q3502264",
	"cdc-cbm",
	scripts = Latn,
}

m["kou"] = {
	"コケ語",
	"Q797249",
	"alv-bua",
}

m["kov"] = {
	"Kudu-Camo",
	"Q3915850",
	"nic-jer",
}

m["kow"] = {
	"クガマ語",
	"Q3913307",
	"alv-mye",
}

m["koy"] = {
	"コユーコン語",
	"Q28304",
	"ath-nor",
	otherNames = {"Denaakk'e"},
	scripts = Latn,
}

m["koz"] = {
	"コラク語",
	"Q6431365",
	"ngf-mad",
}

m["kpa"] = {
	"クット語",
	"Q3437656",
	"cdc-wst",
}

m["kpb"] = {
	"Mullu Kurumba",
	"Q19573111",
	"dra",
}

m["kpc"] = {
	"クリパコ語",
	"Q2882543",
	"awd-nwk",
	otherNames = {"Kurripako"},
	scripts = Latn,
}

m["kpd"] = {
	"コバ語",
	"Q6424249",
	"poz",
}

m["kpe"] = {
	"クペレ語",
	"Q35673",
	"dmn-msw",
	scripts = Latn,
}

m["kpf"] = {
	"コンバ語",
	"Q6428239",
	"ngf",
}

m["kpg"] = {
	"カピンガマランギ語",
	"Q35771",
	"poz-pnp",
	scripts = Latn,
}

m["kph"] = {
	"Kplang",
	"Q35628",
	"alv-gng",
}

m["kpi"] = {
	"Kofei",
	"Q6425665",
	"paa-egb",
}

m["kpj"] = {
	"カラジャ語",
	"Q10322066",
	"sai-mje",
	scripts = Latn,
}

m["kpk"] = {
	"クパン語",
	"Q3915380",
	"nic-jkn",
	scripts = Latn,
}

m["kpl"] = {
	"クパラ語",
	otherNames = {"Kpala", "Kwala"},
	"Q11154769",
	"nic-nkk",
	scripts = Latn,
}

m["kpm"] = {
	"コホ語",
	"Q3511919",
	"mkh-ban",
	scripts = Latn,
}

m["kpn"] = {
	"Kepkiriwát",
	"Q3195366",
	"tup",
	scripts = Latn,
}

m["kpo"] = {
	"Ikposo",
	"Q35029",
	"alv-ktg",
	scripts = Latn,
}

m["kpp"] = {
	"パク・カレン語",
	nil,
}

m["kpq"] = {
	"Korupun-Sela",
	"Q6432769",
	"ngf",
}

m["kpr"] = {
	"コラフェ＝イェガ語",
	"Q11732347",
	"ngf",
}

m["kps"] = {
	"テヒト語",
	"Q7694851",
}

m["kpt"] = {
	"カラタ語",
	"Q56636",
	"cau-ava",
	scripts = Cyrl,
}

m["kpu"] = {
	"カフォア語",
	"Q6346151",
	"qfa-tap",
}

m["kpv"] = {
	"コミ・ジリエーン語",
	"Q34114",
	"urj-prm",
	otherNames = {"Komi"},
	scripts = Cyrl,
	translit_module = "kv-translit",
	override_translit = true,
	wikimedia_codes = {"kv"},
}

m["kpw"] = {
	"コボン語",
	"Q11732326",
	"ngf-mad",
}

m["kpx"] = {
	"山地コイアリ語",
	"Q6925030",
	"ngf",
	otherNames = {"Mountain Koiali"},
}

m["kpy"] = {
	"コリャーク語",
	"Q36199",
	"qfa-cka",
	scripts = Cyrl,
}

m["kpz"] = {
	"クプサビニィ語",
	"Q56445",
	"sdv-kln",
}

m["kqa"] = {
	"Mum",
	"Q6935252",
	"ngf-mad",
}

m["kqb"] = {
	"コヴァイ語",
	"Q6434822",
	"ngf",
}

m["kqc"] = {
	"Doromu-Koki",
	"Q5298175",
	"ngf",
}

m["kqd"] = {
	"コイ・サンジャク・スラト語",
	"Q33463",
	"sem-nna",
}

m["kqe"] = {
	"カラガン語",
	"Q18748906",
	"phi",
}

m["kqf"] = {
	"Kakabai",
	"Q6349119",
	"poz-ocw",
	scripts = Latn,
}

m["kqg"] = {
	"Khe",
	"Q3914015",
	"nic-gur",
}

m["kqh"] = {
	"キサンカサ語",
	"Q6416409",
	"sdv",
}

m["kqi"] = {
	"Koitabu",
	"Q6426363",
	"ngf",
}

m["kqj"] = {
	"コロミラ語",
	"Q6432520",
	"paa-sbo",
}

m["kqk"] = {
	"コタフォン・グベ語",
	"Q12952447",
	"alv-pph",
}

m["kql"] = {
	"Kyenele",
	"Q11732453",
	"paa-yua",
}

m["kqm"] = {
	"Khisa",
	"Q3913955",
	"nic-gur",
}

m["kqn"] = {
	"カオンデ語",
	"Q33601",
	"bnt-lub",
	otherNames = {"Chikaonde", "Kawonde"},
	scripts = Latn,
}

m["kqo"] = {
	"東部クラン語",
	"Q3915374",
	"kro-wee",
}

m["kqp"] = {
	"キムレ語",
	"Q3441210",
	"cdc-est",
}

m["kqq"] = {
	"クレナック語",
	"Q6436747",
	"sai-cer",
}

m["kqr"] = {
	"キマラガング語",
	"Q3196845",
	"poz-san",
	scripts = Latn,
}

m["kqs"] = {
	"北部キシ語",
	"Q19921576",
	"alv-kis",
}

m["kqt"] = {
	"クリアス川カダザン語",
	"Q12953594",
	"poz-san",
}

m["kqu"] = {
	"セロア語",
	"Q33127766",
	"khi-tuu",
}

m["kqv"] = {
	"Okolod",
	"Q7082487",
	"poz-san",
}

m["kqw"] = {
	"カンダス語",
	"Q3192590",
	"poz-ocw",
	scripts = Latn,
}

m["kqx"] = {
	"ムセル語",
	"Q3502347",
	"cdc-cbm",
}

m["kqy"] = {
	"コーレテ語",
	"Q6430753",
	"omv-eom",
}

m["kqz"] = {
	"コラナ語",
	"Q2756709",
	"khi-khk",
	scripts = Latinx,
}

m["kra"] = {
	"クムハリ語",
	"Q13580783",
	"inc-eas",
	ancestors = {"bh"},
}

m["krb"] = {
	"Karkin",
	"Q3193345",
	"nai-you",
	scripts = Latn,
}

m["krc"] = {
	"カラチャイ・バルカル語",
	"Q33714",
	"trk-kcu",
	scripts = Cyrl,
	translit_module = "krc-translit",
}

m["krd"] = {
	"Kairui-Midiki",
	"Q12953277",
	"poz-tim",
}

m["kre"] = {
	"パナラ語",
	"Q3361895",
	"sai-cer",
}

m["krf"] = {
	"コロ語（バヌアツ）",
	"Q3198995",
	"poz-oce",
	otherNames = {"Koro"},
	scripts = Latn,
}

m["krh"] = {
	"クラマ語",
	"Q35593",
	"nic-kau",
}

m["kri"] = {
	"クリオ語",
	"Q35744",
	"crp",
	otherNames = {"Sierra Leonean Creole"},
	scripts = Latn,
	ancestors = {"en"},
}

m["krj"] = {
	"キナライア語",
	"Q33720",
	"phi",
	scripts = Latn,
}

m["krk"] = {
	"ケレク語",
	"Q332792",
	"qfa-cka",
	scripts = Cyrl,
}

m["krl"] = {
	"カレリア語",
	"Q33557",
	"fiu-fin",
	scripts = Latn,
}

m["krm"] = {
	"クルマンジー",
	"Q35713",
	"alv",
}

m["krn"] = {
	"Sapo",
	"Q3915386",
	"kro-wee",
}

m["krp"] = {
	"コロップ語",
	"Q35626",
	"nic-ucr",
	scripts = Latn,
}

m["krr"] = {
	"クルング語",
	"Q12953650",
	"mkh-ban",
	otherNames = {"Krung", "Kreung", "Krüng"},
}

m["krs"] = {
	"グバヤ語",
	"Q56674",
	"csu-bkr",
	otherNames = {"Gbaya"},
}

m["kru"] = {
	"クルク語",
	"Q33492",
	"dra",
	otherNames = {"Kurux"},
	scripts = Deva,
}

m["krv"] = {
	"カベット語",
	"Q12953649",
	"sai-ktk",
	otherNames = {"Kravet"},
	scripts = Latn,
}

m["krw"] = {
	"西部クラン語",
	"Q10975611",
	"kro-wee",
}

m["krx"] = {
	"カロン語",
	"Q35704",
	"alv-jol",
}

m["kry"] = {
	"クリツ語",
	"Q35861",
	"cau-lzg",
	otherNames = {"Kryc", "Kryz"},
	varieties = {"Jek", "Dzhek", "Cek", "Khaput", "Yergyudzh", "Alyk"},
}

m["krz"] = {
	"Sota Kanum",
	"Q12952568",
	"paa-yam",
}

m["ksa"] = {
	"Shuwa-Zamani",
	"Q3913929",
	"nic-kau",
}

m["ksb"] = {
	"サンバー語",
	"Q3788739",
	"bnt-seu",
	otherNames = {"Shambaa", "Shambala"},
	scripts = Latn,
}

m["ksc"] = {
	"南部カリンガ語",
	"Q18753301",
	"phi",
}

m["ksd"] = {
	"クアヌア語",
	"Q35870",
	"poz-ocw",
	otherNames = {"Kuanua"},
	scripts = Latn,
}

m["kse"] = {
	"Kuni",
	"Q6444619",
	"poz-ocw",
	scripts = Latn,
}

m["ksf"] = {
	"Bafia",
	"Q34930",
	"bnt-baf",
}

m["ksg"] = {
	"Kusaghe",
	"Q3200638",
	"poz-ocw",
	scripts = Latn,
}

m["ksi"] = {
	"イ・サカ語",
	"Q841704",
	"paa-msk",
	scripts = Latn,
}

m["ksj"] = {
	"Uare",
	"Q6450052",
	"ngf",
}

m["ksk"] = {
	"Kansa",
	"Q3192772",
	"sio-dhe",
}

m["ksl"] = {
	"Kumalu",
	"Q17584381",
	"poz-ocw",
	scripts = Latn,
}

m["ksm"] = {
	"Kumba",
	"Q3913972",
	"alv-mye",
}

m["ksn"] = {
	"Kasiguranin",
	"Q6374525",
	"phi",
}

m["kso"] = {
	"Kofa",
	"Q56278",
	"cdc-cbm",
}

m["ksp"] = {
	"Kaba",
	"Q3915316",
	"csu-sar",
}

m["ksq"] = {
	"Kwaami",
	"Q3440525",
	"cdc-wst",
}

m["ksr"] = {
	"Borong",
	"Q4946263",
	"ngf",
}

m["kss"] = {
	"Southern Kissi",
	"Q11028974",
	"alv-kis",
}

m["kst"] = {
	"Winyé",
	"Q3913360",
	"nic-gnw",
}

m["ksu"] = {
	"Khamyang",
	"Q6583541",
	"tai-swe",
}

m["ksv"] = {
	"Kusu",
	"Q6448199",
	"bnt-tet",
}

m["ksw"] = {
	"スゴー・カレン語",
	"Q56410",
	"kar",
	aliases = {"S'gaw Kayin", "S'gaw", "Sgaw", "White Karen"},
	scripts = {"Mymr"},
	translit_module = "ksw-translit",
}

m["ksx"] = {
	"クンダン語",
	"Q6382520",
	"poz",
	scripts = Latn,
}

m["ksy"] = {
	"Kharia Thar",
	"Q6400661",
	"inc-eas",
	ancestors = {"inc-mgd"},
}

m["ksz"] = {
	"Kodaku",
	"Q21179986",
	"mun",
}

m["kta"] = {
	"Katua",
	"Q6378404",
	"mkh-ban",
}

m["ktb"] = {
	"Kambaata",
	"Q35664",
	"cus",
}

m["ktc"] = {
	"Kholok",
	"Q3440464",
	"cdc-wst",
}

m["ktd"] = {
	"Kokata",
	"Q10547021",
	"aus-pam",
}

m["ktf"] = {
	"Kwami",
	"Q12952687",
	"bnt-lgb",
}

m["ktg"] = {
	"Kalkatungu",
	"Q3914057",
	"aus-pam",
	otherNames = {"Kalkutungu", "Galgadungu", "Kalkutung", "Kalkadoon", "Galgaduun"},
	scripts = Latn,
}

m["kth"] = {
	"Karanga",
	"Q713643",
}

m["kti"] = {
	"North Muyu",
	"Q20857698",
	otherNames = {"Kati"},
	"ngf",
	scripts = Latn,
}

m["ktj"] = {
	"Plapo Krumen",
	"Q10975356",
	"kro-grb",
}

m["ktk"] = {
	"Kaniet",
	"Q3399050",
	"poz-aay",
	scripts = Latn,
}

m["ktl"] = {
	"Koroshi",
	"Q3775265",
	"ira-nwi",
	ancestors = {"bal"},
}

m["ktm"] = {
	"Kurti",
	"Q3200615",
	"poz-aay",
	scripts = Latn,
}

m["ktn"] = {
	"カリティアナ語",
	"Q3112184",
	"tup",
	otherNames = {"Caritiana"},
	scripts = Latn,
}

m["kto"] = {
	"Kuot",
	"Q56537",
}

m["ktp"] = {
	"Kaduo",
	"Q769809",
	"tbq-lol",
	otherNames = {"Khatu"},
}

m["ktq"] = {
	"Katabaga",
	"Q3193895",
}

m["ktr"] = {
	"Kota Marudu Tinagas",
	"Q18642280",
}

m["kts"] = {
	"South Muyu",
	"Q42308820",
	"ngf",
	scripts = Latn,
}

m["ktt"] = {
	"Ketum",
	"Q12952616",
	"ngf",
}

m["ktu"] = {
	"キチュバ語",
	"Q35746",
	"crp",
	otherNames = {"Munukutuba", "Kikongo-Kituba", "Kikongo", "Kikongo ya leta", "Kibulamatadi", "Kikwango", "Ikeleve", "Kizabave"},
	scripts = Latn,
	ancestors = {"kg"},
}

m["ktv"] = {
	"Eastern Katu",
	"Q22808951",
	"mkh-kat",
}

m["ktw"] = {
	"Kato",
	"Q20831",
	"ath-pco",
	otherNames = {"Cahto"},
	scripts = Latn,
}

m["ktx"] = {
	"Kaxararí",
	"Q6380124",
	"sai-pan",
	scripts = Latn,
}

m["kty"] = {
	"Kango",
	"Q6362818",
	"bnt-bta",
	otherNames = {"Kango (Bas-Uélé District)"}, -- distinct in name, but not necessarily in identity, from 'kzy'
	scripts = Latn,
}

m["ktz"] = {
	"ジューホアン語",
	"Q1192295",
	"khi-kxa",
	otherNames = {"Zhuǀ'hoan", "ǂKxʼauǁʼein", "ǁAuǁei", "ǁAuǁen", "Auen", "Kaukau", "Koko", "Kung-Gobabis", "‡Kx'auǁ'ei", "ǂKx'auǁ'ein", "ǁX'auǁ'e", "Juǀ'hoansi"},
	scripts = Latn,
}

m["kub"] = {
	"クテップ語",
	"Q35645",
	"nic-jkn",
}

m["kuc"] = {
	"Kwinsu",
	"Q6450460",
	"paa-tkw",
}

m["kud"] = {
	"アウヘラワ語",
	"Q5166",
	"poz-ocw",
	otherNames = {"'Auhelawa"},
	scripts = Latn,
}

m["kue"] = {
	"クマン語 (ニューギニア)",
	"Q137525",
	"ngf",
	otherNames = {"Simbu", "Chimbu"},
	scripts = Latn,
}

m["kuf"] = {
	"西部カトゥ",
	"Q6378400",
	"mkh-kat",
	scripts = {"Laoo", "Tale"},
}

m["kug"] = {
	"クパ語",
	"Q3915336",
	"alv-ngb",
}

m["kuh"] = {
	"クシ語",
	"Q3438747",
	"cdc-wst",
}

m["kui"] = {
	"クイクロ＝カラパロ語",
	"Q3915522",
	"sai-car",
	otherNames = {"Kuikúro-Kalapálo", "Kuikuro", "Apalakiri"},
	scripts = Latn,
}

m["kuj"] = {
	"クリア語",
	"Q6445968",
	"bnt-lok",
	scripts = Latn,
}

m["kuk"] = {
	"ケポ語'",
	"Q6393217",
	"poz",
}

m["kul"] = {
	"クレレ語",
	"Q3440506",
	"cdc-wst",
	otherNames = {"Tof", "Korom Boye", "Akandi", "Akande", "Kande", "Richa"},
}

m["kum"] = {
	"クムク語",
	"Q36209",
	"trk-kcu",
	scripts = Cyrl,
	translit_module = "kum-translit",
}

m["kun"] = {
	"クナマ語",
	"Q36041",
}

m["kuo"] = {
	"クムキオ語",
	"Q11732362",
	"ngf",
}

m["kup"] = {
	"クニマイパ語",
	"Q6444696",
}

m["kuq"] = {
	"カリプナ語",
	"Q6371071",
	"tup-gua",
	scripts = Latn,
}

m["kus"] = {
	"クサアル語",
	"Q35708",
	"nic-dag",
	scripts = Latn,
}

m["kut"] = {
	"クテナイ語",
	"Q33434",
	"qfa-iso",
}

m["kuu"] = {
	"アッパー・クスコキム語",
	"Q28062",
	"ath-nor",
}

m["kuv"] = {
	"Kur",
	"Q12635082",
	"poz-cma",
	scripts = Latn,
}

m["kuw"] = {
	"クパグア語",
	"Q11137573",
	"bad-cnt",
}

m["kux"] = {
	"クカチャ語",
	"Q10549839",
	"aus-pam",
}

m["kuy"] = {
	"クーク＝ヤウ語",
	"Q10550697",
	"aus-pmn",
}

m["kuz"] = {
	"クンサ語",
	"Q2669181",
	"qfa-iso",
}

m["kva"] = {
	"バグバリ語",
	"Q56638",
	"cau-ava",
}

m["kvb"] = {
	"クブ語",
	"Q6441341",
	"poz-mly",
}

m["kvc"] = {
	"コヴェ語",
	"Q3199402",
	"poz-ocw",
	scripts = Latn,
}

m["kvd"] = {
	"クイ語（インドネシア）",
	"Q6442230",
	"ngf",
	otherNames = {"Kui"},
}

m["kve"] = {
	"カラバカン語",
	"Q6350003",
	"poz-san",
}

m["kvf"] = {
	"Kabalai",
	"Q3440427",
	"cdc-est",
}

m["kvg"] = {
	"Kuni-Boazi",
	"Q2907551",
	"ngf",
}

m["kvh"] = {
	"コモド語",
	"Q3198565",
	"poz-cet",
}

m["kvi"] = {
	"クワン語",
	"Q3440398",
	"cdc-est",
	scripts = Latn,
}

m["kvj"] = {
	"プシキェ語",
	"Q56304",
	"cdc-cbm",
}

m["kvk"] = {
	"韓国手話",
	"Q3073428",
	"sgn-jsl",
}

m["kvl"] = {
	"カヨー語",
	"Q12952577",
	"kar",
}

m["kvm"] = {
	"Kendem",
	"Q35751",
	"nic-mam",
	scripts = Latn,
}

m["kvn"] = {
	"クナ語",
	"Q31777873",
	"cba",
}

m["kvo"] = {
	"ドベル語",
	"Q5286559",
	"poz",
}

m["kvp"] = {
	"Kompane",
	"Q18343041",
	"poz",
}

m["kvq"] = {
	"ゲバ・カレン語",
	"Q12952581",
	"kar",
}

m["kvr"] = {
	"ケリンチ語",
	"Q3195442",
	"poz-mly",
}

m["kvt"] = {
	"Lahta Karen",
	"Q12952582",
	"kar",
}

m["kvu"] = {
	"インボー・カレン語",
	"Q14426328",
	"kar",
}

m["kvv"] = {
	"コラ語",
	"Q6426967",
	"poz",
}

m["kvw"] = {
	"ウェルシン語",
	"Q7983599",
	"qfa-tap",
}

m["kvx"] = {
	"パルカリ・コーリー語",
	"Q3244176",
	"inc-wes",
}

m["kvy"] = {
	"インタレー・カレン語",
	"Q14426329",
	"kar",
}

m["kvz"] = {
	"Tsakwambo",
	"Q7849438",
	"ngf",
}

m["kwa"] = {
	"ダウ語",
	"Q3042278",
	"sai-nad",
}

m["kwb"] = {
	"クワ語",
	"Q34842",
	"alv-ada",
	otherNames = {"Kwa"},
}

m["kwc"] = {
	"Likwala",
	"Q35597",
	"bnt-mbo",
}

m["kwd"] = {
	"クワイオ語",
	"Q3200796",
	"poz-sls",
	scripts = Latn,
}

m["kwe"] = {
	"クェルバ語",
	"Q6450328",
	"paa-tkw",
}

m["kwf"] = {
	"クワラアエ語",
	"Q3200829",
	"poz-oce",
}

m["kwg"] = {
	"Sara Kaba Deme",
	"Q3915384",
	"csu-kab",
}

m["kwh"] = {
	"コウィアイ語",
	"Q6435028",
	"poz",
}

m["kwi"] = {
	"アワ-コワイケル語",
	"Q2603103",
	"sai-bar",
	otherNames = {"Awa", "Cuaiquer", "Awa Pit", "Awapit", "Kwaiker", "Coaiquer", "Quaiquer"},
	scripts = Latn,
}

m["kwj"] = {
	"クワンガ語",
	"Q3438383",
	"paa-spk",
}

m["kwk"] = {
	"クワキウトル語",
	"Q2640628",
	"wak",
	scripts = Latn,
}

m["kwl"] = {
	"コフィヤル語",
	"Q3441382",
	"cdc-wst",
	scripts = Latn,
}

m["kwm"] = {
	"クワンビ語",
	"Q3487165",
	"bnt-ova",
}

m["kwn"] = {
	"クワンガリ語",
	"Q36334",
	"bnt-kav",
	scripts = Latn,
}

m["kwo"] = {
	"クォムタリ語",
	"Q3508116",
}

m["kwp"] = {
	"Kodia",
	"Q3914867",
	"kro-ekr",
}

m["kwq"] = {
	"クワック語",
	"Q11014183",
	"nic-nka",
	ancestors = {"yam"},
}

m["kwr"] = {
	"Kwer",
	"Q12635137",
	"ngf-okk",
}

m["kws"] = {
	"クウェセ語",
	"Q3200846",
	"bnt-pen",
}

m["kwt"] = {
	"クェステン語",
	"Q6450354",
	"paa-tkw",
}

m["kwu"] = {
	"クワクム語",
	"Q35624",
	"bnt-kak",
}

m["kwv"] = {
	"Sara Kaba Náà",
	"Q3915361",
	"csu-kab",
	otherNames = {"Sara Dunjo"},
}

m["kww"] = {
	"クウィンティ語",
	"Q721182",
}

m["kwx"] = {
	"キールワル語",
	"Q12976968",
	"dra",
}

m["kwz"] = {
	"クワディ語",
	"Q2364661",
	"khi-kkw",
	scripts = Latn,
}

m["kxa"] = {
	"カイリル語",
	"Q3398785",
	"poz-ocw",
	scripts = Latn,
}

m["kxb"] = {
	"クロブ語",
	"Q35586",
	"alv-ptn",
	scripts = Latn,
}

m["kxc"] = {
	"コンソ語",
	"Q56624",
	"cus",
}

m["kxd"] = {
	"ブルネイ語",
	"Q3182878",
	"poz-mly",
	otherNames = {"Brunei"},
	scripts = Latn,
}

m["kxe"] = {
	"Kakihum",
	"Q3914433",
	"nic-kam",
	ancestors = {"tvd"},
}

m["kxf"] = {
	"マヌマノー・カレン語",
	"Q12952592",
	"kar",
	scripts = {"Mymr", "Latn"},
}

m["kxh"] = {
	"カロ語",
	"Q3447116",
	"omv-aro",
}

m["kxi"] = {
	"ケニンガウ・ムルット語",
	"Q6389308",
	"poz-san",
	otherNames = {"Nabay", "Nabaay"},
	scripts = Latn,
}

m["kxj"] = {
	"Kulfa",
	"Q713654",
	"csu-kab",
}

m["kxk"] = {
	"ザヨウン・カレン語",
	"Q14352960",
	"kar",
}

m["kxl"] = {
	"ネパール・クルク語",
	"Q3200624",
	"dra",
	scripts = Deva,
}

m["kxm"] = {
	"北部クメール語",
	"Q3502234",
	"mkh-kmr",
	otherNames = {"Thai Khmer", "Surin Khmer"},
	scripts = {"Thai", "Khmr"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["kxn"] = {
	"カノウィト＝タンジョン・メラナウ語",
	"Q6364300",
	"poz-bnn",
	otherNames = {"Tanjong", "Kanowit-Tanjong Melanau"},
	scripts = Latn,
}

m["kxo"] = {
	"カノエ語",
	"Q4356223",
	"qfa-iso",
}

m["kxp"] = {
	"Wadiyara Koli",
	"Q12953645",
	"inc-wes",
}

m["kxq"] = {
	"Smärky Kanum",
	"Q12952569",
	"paa-yam",
}

m["kxr"] = {
	"コロ語 (ニューギニア)",
	"Q3198994",
	"poz-oce",
	otherNames = {"Koro (Papua New Guinea)", "Koro"},
	scripts = Latn,
}

m["kxs"] = {
	"カンカ語",
	"Q3182570",
	"xgn",
}

m["kxt"] = {
	"Koiwat",
	"Q6426388",
	"paa-spk",
}

m["kxu"] = {
	"クイー語 (インド)",
	"Q33919",
	"dra",
	otherNames = {"Kui", "Kuy"},
	scripts = {"Orya"},
}

m["kxv"] = {
	"クヴィー語",
	"Q3200721",
	"dra",
	scripts = {"Orya"},
}

m["kxw"] = {
	"コナイ語",
	"Q11732339",
}

m["kxx"] = {
	"クバ語",
	otherNames = {"Kuba", "Likuba"},
	"Q35646",
	"bnt-bmo",
}

m["kxy"] = {
	"カヨン語",
	"Q6380673",
	"mkh",
}

m["kxz"] = {
	"ケレウォ語",
	"Q6393847",
	"paa-kiw",
}

m["kya"] = {
	"クワヤ語",
	"Q6450276",
	"bnt-haj",
	scripts = Latn,
}

m["kyb"] = {
	"ブトブト・カリンガ語",
	"Q18753300",
	"phi",
}

m["kyc"] = {
	"キャカ語",
	"Q12952690",
	"paa-eng",
}

m["kyd"] = {
	"Karey",
	"Q6370196",
	"poz",
}

m["kye"] = {
	"Krache",
	"Q35658",
	"alv-gng",
}

m["kyf"] = {
	"クヤ語",
	"Q35595",
	"kro-bet",
}

m["kyg"] = {
	"Keyagana",
	"Q6398208",
	"paa-kag",
}

m["kyh"] = {
	"カルク語",
	"Q1288440",
	"qfa-iso",
	otherNames = {"Karuk"},
	scripts = Latn,
}

m["kyi"] = {
	"キプ語",
	"Q3038653",
	"poz-swa",
	scripts = Latn,
}

m["kyj"] = {
	"カラオ語",
	"Q3192950",
	"phi",
}

m["kyk"] = {
	"カマヨ語",
	"Q3192339",
	"phi",
}

m["kyl"] = {
	"カラプヤ語",
	"Q3192120",
	"nai-klp",
}

m["kym"] = {
	"Kpatili",
	"Q3913982",
	"znd",
}

m["kyn"] = {
	"Karolanos",
	"Q6373093",
	"phi",
}

m["kyo"] = {
	"ケロン語",
	"Q6386414",
	"ngf",
}

m["kyp"] = {
	"Kang",
	"Q25559558",
	"tai",
}

m["kyq"] = {
	"ケンガ語",
	"Q35707",
	"csu-bgr",
}

m["kyr"] = {
	"クルアヤ語",
	"Q3200633",
	"tup",
	otherNames = {"Caravare", "Curuaia", "Kuruaia"},
	scripts = Latn,
}

m["kys"] = {
	"バラム・カヤン語",
	"Q2883794",
	"poz",
}

m["kyt"] = {
	"カヤガル語",
	"Q6380394",
	"ngf",
}

m["kyu"] = {
	"西部カヤ語",
	"Q12952596",
	"kar",
	scripts = {"Kali", "Mymr", "Latn"},
	translit_module = "translit-redirect",
}

m["kyv"] = {
	"Kayort",
	"Q6380675",
	"inc-eas",
	scripts = {"as-Beng"},
	ancestors = {"inc-mgd"},
}

m["kyw"] = {
	"Kudmali",
	"Q6446173",
	"inc-eas",
	ancestors = {"bh"},
	otherNames = {"Kurmali"},
}

m["kyx"] = {
	"Rapoisi",
	"Q7294279",
	"paa-nbo",
	otherNames = {"Konua"},
}

m["kyy"] = {
	"Kambaira",
	"Q6356254",
	"paa-kag",
}

m["kyz"] = {
	"カヤビ語",
	"Q6380372",
	"tup-gua",
	scripts = Latn,
}

m["kza"] = {
	"西部カラボロ語",
	"Q36601",
	"alv-krb",
}

m["kzb"] = {
	"Kaibobo",
	"Q6347565",
	"poz-cma",
}

m["kzc"] = {
	"ボンドゥク・クランゴ語",
	"Q11031321",
	"alv-kul",
}

m["kzd"] = {
	"カダイ語",
	"Q7679471",
	"poz-cma",
	scripts = Latn,
}

m["kze"] = {
	"Kosena",
	"Q12952663",
	"ngf",
	scripts = Latn,
}

m["kzf"] = {
	"Da'a Kaili",
	"Q33103997",
	"poz-kal",
	otherNames = {"Tado", "Inde", "Pekava", "West Kaili"},
	scripts = Latn,
}

m["kzg"] = {
	"喜界語",
	"Q3196527",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["kzh"] = {
	"ケヌジ＝ドンゴラ語",
	"Q5295991",
	"nub",
	otherNames = {"Kenuzi-Dongola", "Andaandi", "Kenzi", "Mattoki"},
	scripts = Latn,
}

m["kzi"] = {
	"クラビト語",
	"Q6385445",
	"poz-swa",
	scripts = Latn,
}

m["kzj"] = {
	"海岸カダザン語",
	"Q3307195",
	"poz-san",
	scripts = Latn,
}

m["kzk"] = {
	"カズクル語",
	"Q1089069",
	"poz-ocw",
	otherNames = {"Dororo", "Guliguli"},
}

m["kzl"] = {
	"カイェリ語",
	"Q4207444",
	"poz-cma",
	scripts = Latn,
}

m["kzm"] = {
	"Kais",
	"Q6348319",
	"paa",
	scripts = Latn,
}

m["kzn"] = {
	"Kokola",
	"Q11128329",
	"bnt-mak",
	ancestors = {"vmw"},
	scripts = Latn,
}

m["kzo"] = {
	"カニンギ語",
	otherNames = "Kaningi",
	"Q35683",
	"bnt-mbt",
}

m["kzp"] = {
	"Kaidipang",
	"Q6347611",
	"phi",
}

m["kzq"] = {
	"カイケ語",
	"Q10951226",
	"sit-tam",
}

m["kzr"] = {
	"カラン語",
	"Q35681",
	"alv-mbm",
	aliases = {"Mbum East", "Lakka"},
	scripts = Latn,
}

m["kzs"] = {
	"スグト・ドゥスン語",
	"Q12953510",
	"poz-san",
	scripts = Latn,
}

m["kzt"] = {
	"タンブナン・ドゥスン語",
	"Q12953514",
	"poz-san",
	scripts = Latn,
}

m["kzu"] = {
	"Kayupulau",
	"Q6380723",
	"poz-ocw",
}

m["kzv"] = {
	"Komyandaret",
	"Q6428671",
	"ngf-okk",
	scripts = Latn,
}

m["kzw"] = { -- contrast xoo, sai-kat, sai-xoc, the last of which the ISO conflated into this code
	"Kariri",
	"Q12953620",
	"sai-mje",
	otherNames = {"Kipeá", "Quipea", "Kamurú", "Camuru", "Dzubukuá", "Dzubucua", "Karirí", "Sabujá", "Sapoyá", "Pedra Branca"},
	scripts = Latn,
}

m["kzx"] = {
	"カマリアン語",
	"Q6356040",
	"poz-cma",
	scripts = Latn,
}

m["kzy"] = {
	"カンゴ語",
	"Q11008360",
	"bnt-kbi",
	ancestors = {"bip"},
	otherNames = {"Kango", "Kango (Tshopo District)"}, -- distinct in name, but not necessarily in identity, from 'kty'
	scripts = Latn,
}

m["kzz"] = {
	"カラブラ語",
	"Q6350038",
	"paa",
	scripts = Latn,
}

return m