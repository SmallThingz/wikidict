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
	"Walla Walla",
	"Q12953960",
	"nai-shp",
	scripts = Latn,
}

m["wab"] = {
	"Wab",
	"Q11222271",
	"poz-ocw",
	scripts = Latn,
}

m["wac"] = {
	"Wasco-Wishram",
	"Q12645081",
	"nai-ckn",
	scripts = Latn,
}

m["wad"] = {
	"Wandamen",
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
	"Watubela",
	"Q7975070",
	"poz-cet",
	scripts = Latn,
}

m["waj"] = {
	"Waffa",
	"Q3565058",
	"paa-kag",
	scripts = Latn,
}

m["wal"] = {
	"Wolaytta",
	"Q36943",
	otherNames = {"Walamo", "Wolayta", "Wolaitta", "Wolaita", "Welayta"},
}

m["wam"] = {
	"Massachusett",
	"Q56519",
	"alg",
	otherNames = {"Wampanoag"},
	scripts = Latn,
}

m["wan"] = {
	"Wan",
	"Q3913272",
	"dmn",
}

m["wao"] = {
	"Wappo",
	"Q56530",
}

m["wap"] = {
	"Wapishana",
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
	"Waray-Waray",
	"Q34279",
	"phi",
	otherNames = {"Waray", "Winaray", "Samar-Leyte"},
	scripts = Latn,
}

m["was"] = {
	"Washo",
	"Q34198",
}

m["wat"] = {
	"Kaninuwa",
	"Q12952565",
	"poz-ocw",
	scripts = Latn,
}

m["wau"] = {
	"Wauja",
	"Q3450522",
	"awd",
	otherNames = {"Waura", "Waurá", "Uaura"},
	scripts = Latn,
}

m["wav"] = {
	"Waka",
	"Q3913394",
}

m["waw"] = {
	"Waiwai",
	"Q56632",
	"sai-car",
	otherNames = {"Wai Wai", "Uaiuai", "Uaieue", "Ouayeone", "Katawian", "Karahawyana"},
	scripts = Latn,
}

m["wax"] = {
	"Watam",
	"Q3566597",
	"paa",
	otherNames = {"Marangis"},
	scripts = Latn,
}

m["way"] = {
	"Wayana",
	"Q5908753",
	"sai-car",
	scripts = Latn,
}

m["waz"] = {
	"Wampur",
	"Q7966957",
	"poz-ocw",
	scripts = Latn,
}

m["wba"] = {
	"Warao",
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
	"Wara",
	"Q3914052",
}

m["wbh"] = {
	"Wanda",
	"Q7967153",
}

m["wbi"] = {
	"Wanji",
	"Q3376818",
}

m["wbj"] = {
	"Alagwa",
	"Q56621",
	"cus",
}

m["wbk"] = {
	"Waigali",
	"Q34196",
	"iir-nur",
}

m["wbl"] = {
	"Wakhi",
	"Q34208",
	"ira-eas",
	scripts = {"Cyrl", "Latn", "Arab"},
	translit_module = "translit-redirect",
}

m["wbm"] = {
	"Wa",
	"Q12644869",
	"aav",
	otherNames = {"Va"}, -- cf 'vwa'
}

m["wbp"] = {
	"Warlpiri",
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
	"Wagdi",
	"Q7959490",
}

m["wbt"] = {
	"Wanman",
	"Q7967989",
}

m["wbv"] = {
	"Wajarri",
	"Q3913856",
	"aus-psw",
	scripts = Latn,
}

m["wbw"] = {
	"Woi",
	"Q8029092",
	"poz-hce",
	scripts = Latn,
}

m["wca"] = {
	"Yanomámi",
	"Q7960056",
}

m["wci"] = {
	"Waci Gbe",
	"Q36987",
}

m["wdd"] = {
	"Wandji",
	"Q36976",
}

m["wdg"] = {
	"Wadaginam",
	"Q7958930",
}

m["wdj"] = {
	"Wadjiginy",
	"Q7959489",
	otherNames = {"Wagaydy", "Wadyiginy", "Wogaity", "Patjtjamalh", "Batjamalh", "Batytyamalh", "Batyamal", "Bachamal", "Wogait", "Wagaitj", "Wogati", "Worgait", "Worgite", "Waggait", "Waggite", "Waggote", "Waggate", "Wagatsch", "Waogatsch"},
}

m["wdu"] = {
	"Wadjigu",
	"Q10719025",
}

m["wdy"] = {
	"Wadjabangayi",
	nil,
}

m["wea"] = {
	"Wewaw",
	"Q15895870",
}

m["wec"] = {
	"Wè Western",
	"Q11159067",
}

m["wed"] = {
	"Wedau",
	"Q12953294",
	"poz-ocw",
	scripts = Latn,
}

m["weh"] = {
	"Weh",
	"Q7979690",
}

m["wei"] = {
	"Kiunum",
	"Q7983230",
}

m["wem"] = {
	"Weme Gbe",
	"Q18379970",
}

m["weo"] = {
	"Wemale",
	"Q7982165",
	"poz-cet",
	otherNames = {"North Wemale", "South Wemale"},
}

m["wer"] = {
	"Weri",
	"Q11732752",
}

m["wes"] = {
	"Cameroon Pidgin",
	"Q35541",
	scripts = Latn,
}

m["wet"] = {
	"Perai",
	"Q12953035",
}

m["weu"] = {
	"Welaung",
	"Q7980503",
	"tbq-kuk",
	otherNames = {"Rawngtu Chin", "Rawngtu"},
}

m["wew"] = {
	"Weyewa",
	"Q4314526",
	"poz-cet",
	scripts = Latn,
}

m["wfg"] = {
	"Yafi",
	"Q8074520",
}

m["wga"] = {
	"Wagaya",
	"Q7959487",
}

m["wgb"] = {
	"Wagawaga",
	"Q7959485",
}

m["wgg"] = {
	"Wangganguru",
	"Q7967859",
	"aus-kar",
	scripts = Latn,
}

m["wgi"] = {
	"Wahgi",
	"Q3565122",
}

m["wgo"] = {
	"Waigeo",
	"Q7959937",
	"poz-hce",
}

m["wgu"] = {
	"Wirangu",
	"Q2092286",
	"aus-pam",
	scripts = Latn,
}

m["wgy"] = {
	"Warrgamay",
	"Q3915942",
	"aus-pam",
	scripts = Latn,
}

m["wha"] = {
	"Manusela",
	"Q3287127",
	"poz-cet",
	otherNames = {"Sou Upaa"},
}

m["whg"] = {
	"North Wahgi",
	"Q12953273",
}

m["whk"] = {
	"Wahau Kenyah",
	"Q7959737",
	"poz-swa",
}

m["whu"] = {
	"Wahau Kayan",
	"Q12473397",
}

m["wib"] = {
	"Southern Toussian",
	"Q11158982",
}

m["wic"] = {
	"Wichita",
	"Q56513",
	"cdd",
	scripts = Latn,
}

m["wie"] = {
	"Wik-Epa",
	"Q10720035",
}

m["wif"] = {
	"Wik-Keyangan",
	"Q10720037",
}

m["wig"] = {
	"Wik-Ngathana",
	"Q3915695",
}

m["wih"] = {
	"Wik-Me'anha",
	"Q10720039",
}

m["wii"] = {
	"Minidien",
	"Q6865237",
	"qfa-tor",
	scripts = Latn,
}

m["wij"] = {
	"Wik-Iiyanh",
	"Q10720036",
}

m["wik"] = {
	"Wikalkan",
	"Q7999800",
}

m["wil"] = {
	"Wilawila",
	"Q10720050",
}

m["wim"] = {
	"Wik-Mungkan",
	"Q2092246",
	"aus-pam",
	scripts = Latn,
}

m["win"] = {
	"Winnebago",
	"Q1957108",
	"sio",
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
	"Wiru",
	"Q8027044",
}

m["wiv"] = {
	"Muduapa",
	"Q3121040",
	"poz-ocw",
	otherNames = {"Vitu", "Vittu", "Witu"},
	scripts = Latn,
}

m["wiy"] = {
	"Wiyot",
	"Q36937",
	"aql",
	scripts = Latn,
}

m["wja"] = {
	"Waja",
	"Q3914415",
}

m["wji"] = {
	"Warji",
	"Q3440381",
}

m["wka"] = {
	"Kw'adza",
	"Q3807652",
	"cus",
}

m["wkb"] = {
	"Kumbaran",
	"Q16878146",
	"dra",
}

m["wkd"] = {
	"Mo",
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
	"Wakawaka",
	"Q10719110",
}

m["wky"] = {
	"Wangkayutyuru",
	"Q33060533",
}

m["wla"] = {
	"Walio",
	"Q7961958",
}

m["wlc"] = {
	"Mwali Comorian",
	"Q3319155",
}

m["wle"] = {
	"Wolane",
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
	"Waioli",
	"Q7960241",
}

m["wlk"] = {
	"Wailaki",
	"Q20832",
	"ath-pco",
	scripts = Latn,
}

m["wll"] = {
	"Wali (Sudan)",
	"Q30597440",
	"nub",
	otherNames = {"Wali"}, -- part of the Hill Nubian or Kordofanian Nubian dialect continuum
}

m["wlm"] = {
	"Middle Welsh",
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
	"Wolio",
	"Q1185114",
	"poz-wot",
	scripts = {"Latn", "Arab"},
}

m["wlr"] = {
	"Wailapa",
	"Q7960062",
	"poz-vnc",
	scripts = Latn,
}

m["wls"] = {
	"Wallisian",
	"Q36979",
	"poz-pnp",
	otherNames = {"East Uvean", "ʻUvean", "Fakaʻuvea"},
	scripts = Latn,
}

m["wlu"] = {
	"Wuliwuli",
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
	"Wali (Ghana)",
	"Q36895",
	"nic-gur",
	otherNames = {"Wali", "Waali", "Walii"},
	scripts = Latn,
}

m["wly"] = {
	"Waling",
	"Q7961957",
}

m["wma"] = {
	"Mawa",
	"Q6794339",
	otherNames = {"Mawa (Nigeria)"},
	scripts = Latn,
}

m["wmb"] = {
	"Wambaya",
	"Q2083197",
}

m["wmc"] = {
	"Wamas",
	"Q7966909",
	"ngf-mad",
}

m["wmd"] = {
	"Mamaindé",
	"Q3284890",
	"sai-nmk",
	otherNames = {"Mamaindê", "Mamainde"},
	scripts = Latn,
}

m["wme"] = {
	"Wambule",
	"Q56785",
	"tbq",
	scripts = Latn,
}

m["wmh"] = {
	"Waima'a",
	"Q7960132",
	"poz",
	otherNames = {"Waimoa"},
	scripts = Latn,
}

m["wmi"] = {
	"Wamin",
	"Q7966934",
}

m["wmm"] = {
	"Maiwa (Indonesia)",
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
	"Wam",
	"Q8030620",
	"qfa-tor",
	otherNames = {"Wom (New Guinea)", "Wom (Papua New Guinea)", "Wom"},
	scripts = Latn,
}

m["wms"] = {
	"Wambon",
	"Q7966922",
	"ngf",
	scripts = Latn,
}

m["wmt"] = {
	"Walmajarri",
	"Q2232696",
	"aus-pam",
	scripts = Latn,
}

m["wmw"] = {
	"Mwani",
	"Q3042206",
	"bnt",
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
	"Wanambre",
	"Q7967057",
	"ngf",
	scripts = Latn,
}

m["wnc"] = {
	"Wantoat",
	"Q7968184",
	"ngf-fin",
	scripts = Latn,
}

m["wnd"] = {
	"Wandarang",
	"Q3913767",
	"aus-arn",
	scripts = Latn,
}

m["wne"] = {
	"Waneci",
	"Q7967334",
	"ira-eas",
	otherNames = {"Wanetsi", "Wanechi", "Chalgari", "Tarino"},
	scripts = {"ps-Arab"},
	ancestors = {"ps"},
}

m["wng"] = {
	"Wanggom",
	"Q11732736",
	"ngf",
	scripts = Latn,
}

m["wni"] = {
	"Ndzwani Comorian",
	"Q2850262",
}

m["wnk"] = {
	"Wanukaka",
	"Q2370136",
	"poz",
	scripts = Latn,
}

m["wnm"] = {
	"Wanggamala",
	"Q7967860",
	"aus-kar",
	scripts = Latn,
}

m["wno"] = {
	"Wano",
	"Q3566166",
	"ngf",
	scripts = Latn,
}

m["wnp"] = {
	"Wanap",
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
	"Wintu",
	"Q56754",
	"nai-wtq",
	scripts = Latn,
}

m["wny"] = {
	"Wanyi",
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
	"Wè Northern",
	"Q3915363",
}

m["woc"] = {
	"Wogeo",
	"Q8029061",
	"poz-ocw",
	scripts = Latn,
}

m["wod"] = {
	"Wolani",
	"Q8029704",
	"ngf",
	scripts = Latn,
}

m["woe"] = {
	"Woleaian",
	"Q34037",
	"poz-mic",
	scripts = Latn,
}

m["wog"] = {
	"Wogamusin",
	"Q56991",
	"paa-spk",
	scripts = Latn,
}

m["woi"] = {
	"Kamang",
	"Q8029096",
	"ngf",
	otherNames = {"Woisika"},
	scripts = Latn,
}

m["wok"] = {
	"Longto",
	"Q35795",
	"alv",
	otherNames = {"Voko", "Woko"},
	scripts = Latn,
}

m["wom"] = {
	"Perema",
	"Q3913378",
	"alv",
	otherNames = {"Wom (Nigeria)", "Wom"},
	scripts = Latn,
}

m["won"] = {
	"Wongo",
	"Q8032058",
	"bnt",
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
	"Wirö",
	"Q12953684",
	otherNames = {"Wiru", "Maco", "Mako", "Maku", "Macu", "Wotuja"},
	scripts = Latn,
}

m["wra"] = {
	"Warapu",
	"Q56739",
	"paa-msk",
	otherNames = {"Barupu"},
	scripts = Latn,
}

m["wrb"] = {
	"Warluwara",
	"Q3913761",
	"aus-pam",
	scripts = Latn,
}

m["wrg"] = {
	"Warungu",
	"Q7970854",
	"aus-pam",
	otherNames = {"Warrungu", "Warrongo", "Warrangu", "Warrango"},
	scripts = Latn,
}

m["wrh"] = {
	"Wiradhuri",
	"Q3913840",
	"aus-cww",
	scripts = Latn,
}

m["wri"] = {
	"Wariyangga",
	"Q10719289",
	"aus-psw",
	scripts = Latn,
}

m["wrk"] = {
	"Garawa",
	"Q2524022",
	"aus-gar",
	otherNames = {"Garrwa", "Karawa", "Karrwa", "Gaarwa"},
	scripts = Latn,
}

m["wrl"] = {
	"Warlmanpa",
	"Q3913823",
}

m["wrm"] = {
	"Warumungu",
	"Q1764544",
}

m["wrn"] = {
	"Warnang",
	"Q36971",
}

m["wro"] = {
	"Worora",
	"Q3504106",
	otherNames = {"Worrorra", "Wororan", "Worrorran"},
}

m["wrp"] = {
	"Waropen",
	"Q7969851",
	"poz-hce",
	scripts = Latn,
}

m["wrr"] = {
	"Wardaman",
	"Q3913842",
}

m["wrs"] = {
	"Waris",
	"Q3502610",
}

m["wru"] = {
	"Waru",
	"Q3566463",
}

m["wrv"] = {
	"Waruna",
	"Q7971078",
}

m["wrw"] = {
	"Gugu Warra",
	"Q5615286",
}

m["wrx"] = {
	"Wae Rana",
	"Q7959375",
}

m["wrz"] = {
	"Warray",
	"Q7969971",
	"aus-gun",
	otherNames = {"Waray"},
}

m["wsa"] = {
	"Warembori",
	"Q56459",
}

m["wsi"] = {
	"Wusi",
	"Q8039349",
	"poz-vnc",
	otherNames = {"Kerepua", "Wusi-Kerepua"},
	scripts = Latn,
}

m["wsk"] = {
	"Waskia",
	"Q7972683",
	"ngf-mad",
	scripts = Latn,
}

m["wsr"] = {
	"Owenia",
	"Q7114727",
}

m["wss"] = {
	"Wasa",
	"Q36914",
}

m["wsu"] = {
	"Wasu",
	"Q7972892",
}

m["wsv"] = {
	"Wotapuri-Katarqalai",
	"Q3877569",
}

m["wtf"] = {
	"Watiwa",
	"Q35316",
	"ngf-mad",
	otherNames = {"Dumpu"},
	scripts = Latn,
}

m["wth"] = {
	"Wathaurong",
	"Q7974656",
	"aus-pam",
	otherNames = {"Wathawurrung", "Wathaurung", "Wada wurrung", "Barrabool"},
	scripts = Latn,
}

m["wti"] = {
	"Berta",
	"Q33178",
}

m["wtk"] = {
	"Watakataui",
	"Q7972975",
	"paa-spk",
}

m["wtm"] = {
	"Mewati",
	"Q2605943",
}

m["wtw"] = {
	"Wotu",
	"Q12473488",
}

m["wua"] = {
	"Wikngenchera",
	"Q10720045",
}

m["wub"] = {
	"Wunambal",
	"Q3913805",
}

m["wud"] = {
	"Wudu",
	"Q36972",
	"alv-kwa",
	scripts = Latn,
}

m["wuh"] = {
	"Wutunhua",
	"Q1012917",
}

m["wul"] = {
	"Silimo",
	"Q11732514",
	"ngf",
}

m["wum"] = {
	"Wumbvu",
	"Q36891",
	"bnt",
	scripts = Latn,
}

m["wun"] = {
	"Bungu",
	"Q4997686",
	"bnt",
	scripts = Latn,
}

m["wur"] = {
	"Wurrugu",
	"Q8039305",
	"aus-wdj",
	otherNames = {"Popham Bay"},
}

m["wut"] = {
	"Wutung",
	"Q56743",
	"paa-msk",
	scripts = Latn,
}

m["wuu"] = {
	"Ву",
	"Q34290",
	"zhx",
	otherNames = {"Suzhounese", "Shanghainese"},
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["wuv"] = {
	"Wuvulu-Aua",
	"Q3062746",
	"poz-aay",
	otherNames = {"Wuvulu"},
}

m["wux"] = {
	"Wulna",
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
	"nic-gur",
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
	"Wawa",
	"Q36889",
	"nic-bod",
	scripts = Latn,
}

m["wxa"] = {
	"Waxianghua",
	"Q2252191",
}

m["wxw"] = {
	"Wardandi",
	nil,
}

m["wya"] = {
	"Wyandot",
	"Q1185119",
	"iro",
	scripts = Latn,
}

m["wyb"] = {
	"Ngiyambaa",
	"Q3913825",
	"aus-cww",
	otherNames = {"Wangaaybuwan-Ngiyambaa", "Wangaaybuwan", "Wayilwan"},
	scripts = Latn,
}

m["wyi"] = {
	"Woiwurrung",
	"Q8029099",
	"aus-pam",
	otherNames = {"Woiworung", "Woiwurrong", "Wuywurung", "Wurundjeri", "Warerong", "Warorong", "Waverong", "Wavoo-rong", "Wawoorong", "Wawoo-rong", "Wawurong", "Wawurrong", "Woewo-rung", "Woiwurong", "Woi-wurrong", "Woiwurru", "Woiwurung", "Wooeewoorong", "Wowerong", "Wainworra", "Wairwaioo", "Warwaroo", "Wurrundyirra-baluk", "Wurrunjeri", "Wurunjeri", "Wurunjerri-baluk", "Oorongie", "Urunjeri", "Bunurong", "Bunwurrung", "Boonwerung", "Boonwurrung", "Bunurowrung", "Boonoorong", "Boonerwrung", "Bururong"},
	scripts = Latn,
}

m["wym"] = {
	"Vilamovian",
	"Q56485",
	"gmw",
	otherNames = {"Wilamowicean", "Vilamovicean", "Wymysorys"}, -- Vilamovian and Wym. may not even meet CFI
	scripts = Latn,
	ancestors = {"gmh"},
}

m["wyr"] = {
	"Wayoró",
	"Q2875044",
	"tup",
	otherNames = {"Ajurú", "Ayurú", "Uaiora", "Wajaru", "Wayurú"},
}

m["wyy"] = {
	"Western Fijian",
	"Q3062751",
	"poz-occ",
}

return m