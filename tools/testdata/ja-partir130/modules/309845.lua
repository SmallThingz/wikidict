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

m["waa"] = {
	"ワラワラ語",
	"Q12953960",
	"nai-shp",
	ancestors = {"nai-spt"},
	scripts = Latn,
}

m["wab"] = {
	"ワブ語",
	"Q11222271",
	"poz-ocw",
	scripts = Latn,
}

m["wac"] = {
	"ワスコ＝ウィシュラム語",
	"Q12645081",
	"nai-ckn",
	scripts = Latn,
}

m["wad"] = {
	"ワンダメン語",
	"Q2806128",
	"poz-hce",
	scripts = Latn,
}

m["waf"] = {
	"Wakoná",
	"Q7961205",
	otherNames = {"Wakona"},
}

m["wag"] = {
	"Wa'ema",
	"Q12953264",
	"poz-ocw",
	scripts = Latn,
}

m["wah"] = {
	"ワトゥベラ語",
	"Q7975070",
	"poz-cma",
	scripts = Latn,
}

m["waj"] = {
	"ワッファ語",
	"Q3565058",
	"paa-kag",
	scripts = Latn,
}

m["wal"] = {
	"ウォライタ語",
	"Q36943",
	"omv-nom",
	otherNames = {"Walamo", "Wolayta", "Wolaitta", "Wolaita", "Welayta"},
}

m["wam"] = {
	"ワンパノアグ語",
	"Q56519",
	"alg-eas",
	otherNames = {"Wampanoag"},
	scripts = Latn,
}

m["wan"] = {
	"Wan",
	"Q3913272",
	"dmn-nbe",
}

m["wao"] = {
	"ワッポー語",
	"Q56530",
}

m["wap"] = {
	"ワピシャナ語",
	"Q3450493",
	"awd",
	scripts = Latn,
}

m["waq"] = {
	"Wageman",
	"Q3436843",
	"aus-gun",
	otherNames = {"Wagiman", "Wakiman", "Wogeman"},
	scripts = Latn,
}

m["war"] = {
	"ワライ語",
	"Q34279",
	"phi",
	otherNames = {"Waray", "Winaray", "Samar-Leyte"},
	scripts = Latn,
}

m["was"] = {
	"ワショー語",
	"Q34198",
}

m["wat"] = {
	"Kaninuwa",
	"Q12952565",
	"poz-ocw",
	scripts = Latn,
}

m["wau"] = {
	"ワウラ語",
	"Q3450522",
	"awd",
	otherNames = {"Waura", "Waurá", "Uaura"},
	scripts = Latn,
}

m["wav"] = {
	"ワカ語",
	"Q3913394",
	"alv-mye",
}

m["waw"] = {
	"ワイワイ語",
	"Q56632",
	"sai-car",
	otherNames = {"Wai Wai", "Uaiuai", "Uaieue", "Ouayeone", "Katawian", "Karahawyana"},
	scripts = Latn,
}

m["wax"] = {
	"ワタム語",
	"Q3566597",
	"paa",
	otherNames = {"Marangis"},
	scripts = Latn,
}

m["way"] = {
	"ワヤナ語",
	"Q5908753",
	"sai-car",
	scripts = Latn,
}

m["waz"] = {
	"ワンプル語",
	"Q7966957",
	"poz-ocw",
	scripts = Latn,
}

m["wba"] = {
	"ワラオ語",
	"Q36946",
	"qfa-iso",
	scripts = Latn,
}

m["wbb"] = {
	"Wabo",
	"Q7958701",
	"poz-hce",
	scripts = Latn,
}

m["wbe"] = {
	"Waritai",
	"Q7969453",
	"paa-lkp",
	scripts = Latn,
}

m["wbf"] = {
	"ワラ語",
	"Q3914052",
	"alv-wan",
}

m["wbh"] = {
	"ワンダ語",
	"Q7967153",
	"bnt-mwi",
}

m["wbi"] = {
	"Wanji",
	"Q3376818",
	"bnt-bki",
	otherNames = {"Vwanji"},
	scripts = Latn,
}

m["wbj"] = {
	"アラグヮ語",
	"Q56621",
	"cus",
}

m["wbk"] = {
	"ワイガル語",
	"Q34196",
	"nur-sou",
}

m["wbl"] = {
	"ワヒー語",
	"Q34208",
	"xsc-skw",
	scripts = {"Cyrl", "Latn", "Arab"},
	translit_module = "translit-redirect",
}

m["wbm"] = {
	"ワ語",
	"Q12644869",
	"mkh-pal",
	otherNames = {"Va"}, -- cf 'vwa'
}

m["wbp"] = {
	"ワルピリ語",
	"Q1639998",
	"aus-pam",
	scripts = Latn,
}

m["wbq"] = {
	"Waddar",
	"Q6708569",
	"dra",
	ancestors = {"te"},
}

m["wbr"] = {
	"ワグディ語",
	"Q7959490",
	"inc-bhi",
}

m["wbt"] = {
	"ワンマン語",
	"Q7967989",
}

m["wbv"] = {
	"ワジャリ語",
	"Q3913856",
	"aus-psw",
	scripts = Latn,
}

m["wbw"] = {
	"ウォイ語",
	"Q8029092",
	"poz-hce",
	scripts = Latn,
}

m["wca"] = {
	"ヤノマム語",
	"Q7960056",
}

m["wci"] = {
	"ワチ・グベ語",
	"Q36987",
	"alv-gbe",
}

m["wdd"] = {
	"ワンジ語",
	"Q36976",
	"bnt-nze",
}

m["wdg"] = {
	"Wadaginam",
	"Q7958930",
}

m["wdj"] = {
	"ワジギン語",
	"Q7959489",
	otherNames = {"Wagaydy", "Wadyiginy", "Wogaity", "Patjtjamalh", "Batjamalh", "Batytyamalh", "Batyamal", "Bachamal", "Wogait", "Wagaitj", "Wogati", "Worgait", "Worgite", "Waggait", "Waggite", "Waggote", "Waggate", "Wagatsch", "Waogatsch"},
}

m["wdu"] = {
	"ワジグ語",
	"Q10719025",
}

m["wdy"] = {
	"Wadjabangayi",
	nil,
}

m["wea"] = {
	"ウェウォー語",
	"Q15895870",
}

m["wec"] = {
	"ウェ西部語",
	"Q11159067",
	"kro-wee",
}

m["wed"] = {
	"ウェダウ語",
	"Q12953294",
	"poz-ocw",
	scripts = Latn,
}

m["weh"] = {
	"ウェ語",
	"Q7979690",
	"nic-rnw",
}

m["wei"] = {
	"Kiunum",
	"Q7983230",
}

m["wem"] = {
	"Weme Gbe",
	"Q18379970",
	"alv-gbe",
}

m["weo"] = {
	"ウェマーレ語",
	"Q7982165",
	"poz-cma",
	otherNames = {"North Wemale", "South Wemale"},
}

m["wer"] = {
	"ウェリ語",
	"Q11732752",
	"paa",
}

m["wes"] = {
	"カメルーン・ピジン語",
	"Q35541",
	"crp",
	otherNames = {"Cameroonian Pidgin English", "Cameroonian Creole", "Kamtok"},
	scripts = Latn,
	ancestors = {"en"},
}

m["wet"] = {
	"Perai",
	"Q12953035",
	"poz-tim",
}

m["weu"] = {
	"Welaung",
	"Q7980503",
	"tbq-kuk",
	otherNames = {"Rawngtu Chin", "Rawngtu"},
}

m["wew"] = {
	"ウェイェワ語",
	"Q4314526",
	"poz-cet",
	scripts = Latn,
}

m["wfg"] = {
	"ヤフィ語",
	"Q8074520",
	"paa-pau",
}

m["wga"] = {
	"ワガヤ語",
	"Q7959487",
	"aus-pam",
}

m["wgb"] = {
	"ワガワガ語",
	"Q7959485",
}

m["wgg"] = {
	"ワンガングル語",
	"Q7967859",
	"aus-kar",
	scripts = Latn,
}

m["wgi"] = {
	"ワフギ語",
	"Q3565122",
}

m["wgo"] = {
	"ワイゲオ語",
	"Q7959937",
	"poz-hce",
}

m["wgu"] = {
	"ウィラング語",
	"Q2092286",
	"aus-pam",
	scripts = Latn,
}

m["wgy"] = {
	"ワルガマイ語",
	"Q3915942",
	"aus-pam",
	scripts = Latn,
}

m["wha"] = {
	"マヌセラ語",
	"Q3287127",
	"poz-cma",
	otherNames = {"Sou Upaa"},
}

m["whg"] = {
	"北ワフギ語",
	"Q12953273",
	"ngf",
}

m["whk"] = {
	"ワハウ・クニャ語",
	"Q7959737",
	"poz-swa",
}

m["whu"] = {
	"ワハウ・カヤン語",
	"Q12473397",
}

m["wib"] = {
	"南部トゥシャン語",
	"Q11158982",
	"alv-sav",
}

m["wic"] = {
	"ウィチタ語",
	"Q56513",
	"cdd",
	scripts = Latn,
}

m["wie"] = {
	"ウィク＝エパ語",
	"Q10720035",
	"aus-pmn",
}

m["wif"] = {
	"ウィク＝ケヤンガン語",
	"Q10720037",
	"aus-pmn",
}

m["wig"] = {
	"ウィク＝ンガタナ語",
	"Q3915695",
	"aus-pmn",
}

m["wih"] = {
	"ウィク＝メアナ語",
	"Q10720039",
	"aus-pmn",
}

m["wii"] = {
	"Minidien",
	"Q6865237",
	"qfa-tor",
	scripts = Latn,
}

m["wij"] = {
	"ウィク＝イイヤン語",
	"Q10720036",
	"aus-pmn",
}

m["wik"] = {
	"Wikalkan",
	"Q7999800",
	"aus-pmn",
}

m["wil"] = {
	"ウィラウィラ語",
	"Q10720050",
	"aus-wor",
}

m["wim"] = {
	"ウィク・ムンカン語",
	"Q2092246",
	"aus-pmn",
	scripts = Latn,
}

m["win"] = {
	"ホーチャンク語",
	"Q1957108",
	"sio-msv",
	otherNames = {"Hocak", "Hochank", "Hochunk"},
	scripts = Latn,
}

m["wir"] = {
	"Wiraféd",
	"Q12953970",
	"tup-gua",
	scripts = Latn,
}

m["wiu"] = {
	"ウィル語",
	"Q8027044",
	"paa",
}

m["wiv"] = {
	"ヴィトゥ語",
	"Q3121040",
	"poz-ocw",
	otherNames = {"Vitu", "Vittu", "Witu"},
	scripts = Latn,
}

m["wiy"] = {
	"ウィヨット語",
	"Q36937",
	"aql",
	scripts = Latn,
}

m["wja"] = {
	"ワジャ語",
	"Q3914415",
	"alv-wjk",
}

m["wji"] = {
	"ワルジ語",
	"Q3440381",
}

m["wka"] = {
	"クワァズァ語",
	"Q3807652",
	"cus",
}

m["wkb"] = {
	"Kumbaran",
	"Q16878146",
	"dra",
}

m["wkd"] = {
	"ワクデ語",
	"Q7960881",
	"poz-ocw",
	otherNames = {"Wakde"},
	scripts = Latn,
}

m["wkl"] = {
	"Kalanadi",
	"Q6350515",
	"dra",
}

m["wku"] = {
	"Kunduvadi",
	"Q6444383",
	"dra",
}

m["wkw"] = {
	"ワカワカ語",
	"Q10719110",
	"aus-pam",
}

m["wky"] = {
	"Wangkayutyuru",
	"Q33060533",
	"aus-kar",
}

m["wla"] = {
	"ワリオ語",
	"Q7961958",
}

m["wlc"] = {
	"ムワリ・コモロ語",
	"Q3319155",
	"bnt-com",
	scripts = Latn,
		sort_key = {
		from = {"ɓ", "ɗ"},
		to   = {"bz", "dz"}} ,
}

m["wle"] = {
	"ウォラネ語",
	"Q12645275",
	"sem-eth",
}

m["wlg"] = {
	"Kunbarlang",
	"Q5618523",
	"aus-gun",
	scripts = Latn,
}

m["wli"] = {
	"ワイオリ語",
	"Q7960241",
}

m["wlk"] = {
	"ワイラキ語",
	"Q20832",
	"ath-pco",
	scripts = Latn,
}

m["wll"] = {
	"ワリ語（スーダン）",
	"Q30597440",
	"nub-hil",
	otherNames = {"Wali"}, -- part of the Hill Nubian or Kordofanian Nubian dialect continuum
}

m["wlm"] = {
	"中世ウェールズ語",
	"Q2487263",
	"cel-bry",
	scripts = Latn,
	entry_name = {
		from = {"Ð", "ð"},
		to   = {"D", "d"}},
 	sort_key = {
		from = {"K", "k"},
		to   = {"C", "c"}},
	ancestors = {"owl"},
}

m["wlo"] = {
	"ウォリオ語",
	"Q1185114",
	"poz-wot",
	scripts = {"Latn", "Arab"},
}

m["wlr"] = {
	"ワイラパ語",
	"Q7960062",
	"poz-vnc",
	scripts = Latn,
}

m["wls"] = {
	"ワリシア語",
	"Q36979",
	"poz-pnp",
	otherNames = {"East Uvean", "ʻUvean", "Fakaʻuvea"},
	scripts = Latn,
}

m["wlu"] = {
	"ウリウリ語",
	"Q8039208",
}

m["wlv"] = {
	"Wichí Lhamtés Vejoz",
	"Q13526867",
	"sai-wic",
	scripts = Latn,
}

m["wlw"] = {
	"Walak",
	"Q7961258",
}

m["wlx"] = {
	"ワリ語（ガーナ）",
	"Q36895",
	"nic-mre",
	otherNames = {"Wali", "Waali", "Walii"},
	scripts = Latn,
}

m["wly"] = {
	"ワリン語",
	"Q7961957",
	"sit-kic",
	ancestors = {"bap"},
}

m["wmb"] = {
	"ワンバヤ語",
	"Q2083197",
	"aus-mir",
}

m["wmc"] = {
	"ワマス語",
	"Q7966909",
	"ngf-mad",
}

m["wmd"] = {
	"ママインデ語",
	"Q3284890",
	"sai-nmk",
	otherNames = {"Mamaindê", "Mamainde"},
	scripts = Latn,
}

m["wme"] = {
	"Wambule",
	"Q56785",
	"sit-kiw",
	scripts = Latn,
}

m["wmh"] = {
	"ワイマ語",
	"Q7960132",
	"poz-tim",
	otherNames = {"Waimoa"},
	scripts = Latn,
}

m["wmi"] = {
	"ワミン語",
	"Q7966934",
}

m["wmm"] = {
	"マイワ語（インドネシア）",
	"Q6737226",
	"poz",
	otherNames = {"Maiwa"},
	scripts = Latn,
}

m["wmn"] = {
	"Waamwang",
	"Q7958575",
	"poz-cln",
	scripts = Latn,
}

m["wmo"] = {
	"ウォム語",
	"Q8030620",
	"qfa-tor",
	otherNames = {"Wom (New Guinea)", "Wom (Papua New Guinea)", "Wom"},
	scripts = Latn,
}

m["wms"] = {
	"ワンボン語",
	"Q7966922",
	"ngf",
	scripts = Latn,
}

m["wmt"] = {
	"ワルマジャッリ語",
	"Q2232696",
	"aus-pam",
	scripts = Latn,
}

m["wmw"] = {
	"ンワニ語",
	"Q3042206",
	"bnt-swh",
	otherNames = {"Kimwani"},
	scripts = Latn,
}

m["wmx"] = {
	"Womo",
	"Q8031646",
	"paa-msk",
	scripts = Latn,
}

m["wnb"] = {
	"ワナンブレ語",
	"Q7967057",
	"ngf",
	scripts = Latn,
}

m["wnc"] = {
	"ワントアト語",
	"Q7968184",
	"ngf-fin",
	scripts = Latn,
}

m["wnd"] = {
	"ワンダラン語",
	"Q3913767",
	"aus-arn",
	scripts = Latn,
}

m["wne"] = {
	"ワネツィ語",
	"Q7967334",
	"ira-pat",
	otherNames = {"Wanetsi", "Wanechi", "Chalgari", "Tarino"},
	scripts = {"ps-Arab"},
	ancestors = {"ira-pat-pro"},
}

m["wng"] = {
	"ワンゴム語",
	"Q11732736",
	"ngf",
	scripts = Latn,
}

m["wni"] = {
	"Ndzwani Comorian",
	"Q2850262",
	"bnt-com",
	scripts = Latn,
	sort_key = {
		from = {"ɓ", "ɗ"},
		to   = {"bz", "dz"}} ,
}

m["wnk"] = {
	"Wanukaka",
	"Q2370136",
	"poz",
	scripts = Latn,
}

m["wnm"] = {
	"ワンガマラ語",
	"Q7967860",
	"aus-kar",
	scripts = Latn,
}

m["wno"] = {
	"ワノ語",
	"Q3566166",
	"ngf",
	scripts = Latn,
}

m["wnp"] = {
	"ワナプ語",
	"Q7967060",
	"qfa-tor",
	scripts = Latn,
}

m["wnu"] = {
	"Usan",
	"Q7901709",
	"ngf",
	scripts = Latn,
}

m["wnw"] = {
	"ウィントゥ語",
	"Q56754",
	"nai-wtq",
	scripts = Latn,
}

m["wny"] = {
	"ワーニ語",
	"Q7968201",
	"aus-gar",
	otherNames = {"Wanji", "Waanyi"},
	scripts = Latn,
}

m["woa"] = {
	"Tyaraity",
	"Q10706951",
}

m["wob"] = {
	"ウォベ語",
	"Q3915363",
	"kro-wee",
}

m["woc"] = {
	"ウォゲオ語",
	"Q8029061",
	"poz-ocw",
	scripts = Latn,
}

m["wod"] = {
	"ウォラニ語",
	"Q8029704",
	"ngf",
	scripts = Latn,
}

m["woe"] = {
	"ウォレアイ語",
	"Q34037",
	"poz-mic",
	scripts = Latn,
}

m["wog"] = {
	"ウォガムシン語",
	"Q56991",
	"paa-spk",
	scripts = Latn,
}

m["woi"] = {
	"カマン語",
	"Q8029096",
	"ngf",
	otherNames = {"Woisika"},
	scripts = Latn,
}

m["wok"] = {
	"Longto",
	"Q35795",
	"alv-dur",
	otherNames = {"Voko", "Woko"},
	scripts = Latn,
}

m["wom"] = {
	"ウォム語（ナイジェリア）",
	"Q3913378",
	"alv-lek",
	otherNames = {"Wom (Nigeria)", "Wom"},
	scripts = Latn,
}

m["won"] = {
	"Wongo",
	"Q8032058",
	"bnt-bsh",
	scripts = Latn,
}

m["woo"] = {
	"Manombai",
	"Q6751253",
	"poz",
	scripts = Latn,
}

m["wor"] = {
	"Woria",
	"Q8034514",
	"paa-egb",
	scripts = Latn,
}

m["wos"] = {
	"Hanga Hundi",
	"Q6450232",
	"paa-spk",
	scripts = Latn,
}

m["wow"] = {
	"Wawonii",
	"Q3566780",
	"poz-btk",
	scripts = Latn,
}

m["wpc"] = {
	"マコ語",
	"Q12953684",
	otherNames = {"Wiru", "Maco", "Mako", "Maku", "Macu", "Wotuja"},
	scripts = Latn,
}

m["wra"] = {
	"ワラプ語",
	"Q56739",
	"paa-msk",
	otherNames = {"Barupu"},
	scripts = Latn,
}

m["wrb"] = {
	"ワルワラ語",
	"Q3913761",
	"aus-pam",
	scripts = Latn,
}

m["wrg"] = {
	"ワルング語",
	"Q7970854",
	"aus-pam",
	otherNames = {"Warrungu", "Warrongo", "Warrangu", "Warrango"},
	scripts = Latn,
}

m["wrh"] = {
	"ウィラージューリー語",
	"Q3913840",
	"aus-cww",
	scripts = Latn,
}

m["wri"] = {
	"ワリヤンガ語",
	"Q10719289",
	"aus-psw",
	scripts = Latn,
}

m["wrk"] = {
	"ガラワ語",
	"Q2524022",
	"aus-gar",
	otherNames = {"Garrwa", "Karawa", "Karrwa", "Gaarwa"},
	scripts = Latn,
}

m["wrl"] = {
	"ワルマンパ語",
	"Q3913823",
	"aus-pam",
}

m["wrm"] = {
	"ワルムング語",
	"Q1764544",
}

m["wrn"] = {
	"Warnang",
	"Q36971",
	"alv-hei",
}

m["wro"] = {
	"ウォロラ語",
	"Q3504106",
	"aus-wor",
	otherNames = {"Worrorra", "Wororan", "Worrorran"},
}

m["wrp"] = {
	"ワロペン語",
	"Q7969851",
	"poz-hce",
	scripts = Latn,
}

m["wrr"] = {
	"ワダマン語",
	"Q3913842",
	"aus-yng",
}

m["wrs"] = {
	"ワリス語",
	"Q3502610",
	"paa-brd",
}

m["wru"] = {
	"Waru",
	"Q3566463",
}

m["wrv"] = {
	"ワルナ語",
	"Q7971078",
}

m["wrw"] = {
	"ググ・ワラ語",
	"Q5615286",
}

m["wrx"] = {
	"Wae Rana",
	"Q7959375",
}

m["wrz"] = {
	"ワライ語（オーストラリア）",
	"Q7969971",
	"aus-gun",
	otherNames = {"Waray"},
}

m["wsa"] = {
	"ワレンボリ語",
	"Q56459",
	otherNames = {"Warembori", "Warenbori"},
}

m["wsi"] = {
	"ウシ語",
	"Q8039349",
	"poz-vnc",
	otherNames = {"Kerepua", "Wusi-Kerepua"},
	scripts = Latn,
}

m["wsk"] = {
	"ワスキア語",
	"Q7972683",
	"ngf-mad",
	scripts = Latn,
}

m["wsr"] = {
	"Owenia",
	"Q7114727",
}

m["wss"] = {
	"ワサ語",
	otherNames = {"アカン語ワサ方言", "アカン語ワッサ方言", "ワッサ語", "Wasa", "Wasaw", "Wassa"},
	"Q36914",
	"alv-ctn",
	ancestors = {"ak"},
}

m["wsu"] = {
	"Wasu",
	"Q7972892",
}

m["wsv"] = {
	"ウォタプーリー・カタールカラー語",
	"Q3877569",
	"inc-dar",
}

m["wtf"] = {
	"Watiwa",
	"Q35316",
	"ngf-mad",
	otherNames = {"Dumpu"},
	scripts = Latn,
}

m["wth"] = {
	"ワサウルング語",
	"Q7974656",
	"aus-pam",
	otherNames = {"Wathawurrung", "Wathaurung", "Wada wurrung", "Barrabool"},
	scripts = Latn,
}

m["wti"] = {
	"ベルタ語",
	"Q33178",
}

m["wtk"] = {
	"ワタカタウイ語",
	"Q7972975",
	"paa-spk",
}

m["wtm"] = {
	"メワティ語",
	"Q2605943",
}

m["wtw"] = {
	"ウォトゥ語",
	"Q12473488",
}

m["wua"] = {
	"Wikngenchera",
	"Q10720045",
	"aus-pmn",
}

m["wub"] = {
	"ウナンバル語",
	"Q3913805",
	"aus-wor",
}

m["wud"] = {
	"Wudu",
	"Q36972",
	"alv-gbe",
	scripts = Latn,
}

m["wuh"] = {
	"五屯語",
	"Q1012917",
}

m["wul"] = {
	"Silimo",
	"Q11732514",
	"ngf",
}

m["wum"] = {
	"ウンブ語",
	"Q36891",
	"bnt-kel",
	scripts = Latn,
}

m["wun"] = {
	"ブング語",
	"Q4997686",
	"bnt-mby",
	scripts = Latn,
}

m["wur"] = {
	"Wurrugu",
	"Q8039305",
	"aus-wdj",
	otherNames = {"Popham Bay"},
}

m["wut"] = {
	"ウトゥン語",
	"Q56743",
	"paa-msk",
	scripts = Latn,
}

m["wuu"] = {
	"呉語",
	"Q34290",
	"zhx",
	otherNames = {"Suzhounese", "Shanghainese"},
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["wuv"] = {
	"ウブル＝アウア語",
	"Q3062746",
	"poz-aay",
	otherNames = {"Wuvulu"},
}

m["wux"] = {
	"ウルナ語",
	"Q13591670",
}

m["wuy"] = {
	"Wauyai",
	"Q12953295",
	"poz-hce",
}

m["wwa"] = {
	"Waama",
	"Q7958576",
	"nic-eov",
	scripts = Latn,
}

m["wwo"] = {
	"Dorig",
	"Q3037047",
	"poz-vnc",
}

m["wwr"] = {
	"Warrwa",
	"Q7970852",
}

m["www"] = {
	"ワワ語",
	"Q36889",
	"nic-mmb",
	scripts = Latn,
}

m["wxa"] = {
	"瓦郷語",
	"Q2252191",
}

m["wxw"] = {
	"Wardandi",
	nil,
}

m["wya"] = {
	"ワイアンドット語",
	"Q1185119",
	"iro",
	scripts = Latn,
}

m["wyb"] = {
	"ンギヤンバー語",
	"Q3913825",
	"aus-cww",
	otherNames = {"Wangaaybuwan-Ngiyambaa", "Wangaaybuwan", "Wayilwan"},
	scripts = Latn,
}

m["wyi"] = {
	"ウォイウラン語",
	"Q8029099",
	"aus-pam",
	otherNames = {"Woiworung", "Woiwurrong", "Wuywurung", "Wurundjeri", "Warerong", "Warorong", "Waverong", "Wavoo-rong", "Wawoorong", "Wawoo-rong", "Wawurong", "Wawurrong", "Woewo-rung", "Woiwurong", "Woi-wurrong", "Woiwurru", "Woiwurung", "Wooeewoorong", "Wowerong", "Wainworra", "Wairwaioo", "Warwaroo", "Wurrundyirra-baluk", "Wurrunjeri", "Wurunjeri", "Wurunjerri-baluk", "Oorongie", "Urunjeri", "Bunurong", "Bunwurrung", "Boonwerung", "Boonwurrung", "Bunurowrung", "Boonoorong", "Boonerwrung", "Bururong"},
	scripts = Latn,
}

m["wym"] = {
	"ヴィラモヴィアン語",
	"Q56485",
	"gmw",
	otherNames = {"Wilamowicean", "Vilamovicean", "Wymysorys"}, -- Vilamovian and Wym. may not even meet CFI
	scripts = Latn,
	ancestors = {"gmh"},
	entry_name = {
		from = {"ȧ", "ḱ",},
		to   = {"a", "k",}} ,
}

m["wyr"] = {
	"ワヨロ語",
	"Q2875044",
	"tup",
	otherNames = {"Ajurú", "Ayurú", "Uaiora", "Wajaru", "Wayurú"},
}

m["wyy"] = {
	"西部フィジー語",
	"Q3062751",
	"poz-occ",
}

return m