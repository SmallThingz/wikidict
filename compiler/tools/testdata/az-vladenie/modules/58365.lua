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

m["waa"] = {
	canonicalName = "Walla Walla",
	scripts = {"Latn"},
	family = "nai-shp",
}

m["wab"] = {
	canonicalName = "Wab",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wac"] = {
	canonicalName = "Wasco-Wishram",
	scripts = {"Latn"},
	family = "nai-ckn",
}

m["wad"] = {
	canonicalName = "Wandamen",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["waf"] = {
	canonicalName = "Wakoná",
	otherNames = {"Wakona"},
}

m["wag"] = {
	canonicalName = "Wa'ema",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wah"] = {
	canonicalName = "Watubela",
	scripts = {"Latn"},
	family = "plf",
}

m["wai"] = {
	canonicalName = "Wares",
	scripts = {"Latn"},
	family = "paa",
}

m["waj"] = {
	canonicalName = "Waffa",
	scripts = {"Latn"},
	family = "ngf",
}

m["wal"] = {
	canonicalName = "Wolaytta",
	otherNames = {"Walamo", "Wolayta", "Wolaitta", "Wolaita", "Welayta"},
}

m["wam"] = {
	canonicalName = "Massachusett",
	otherNames = {"Wampanoag"},
	scripts = {"Latn"},
	family = "alg",
}

m["wan"] = {
	canonicalName = "Wan",
}

m["wao"] = {
	canonicalName = "Wappo",
}

m["wap"] = {
	canonicalName = "Wapishana",
	scripts = {"Latn"},
	family = "awd",
}

m["waq"] = {
	canonicalName = "Wageman",
	otherNames = {"Wagiman", "Wakiman", "Wogeman"},
	scripts = {"Latn"},
	family = "aus-gun",
}

m["war"] = {
	canonicalName = "Waray-Waray",
	otherNames = {"Waray", "Winaray", "Samar-Leyte"},
	scripts = {"Latn"},
	family = "phi",
}

m["was"] = {
	canonicalName = "Washo",
}

m["wat"] = {
	canonicalName = "Kaninuwa",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wau"] = {
	canonicalName = "Wauja",
	otherNames = {"Waura", "Waurá", "Uaura"},
	scripts = {"Latn"},
	family = "awd",
}

m["wav"] = {
	canonicalName = "Waka",
}

m["waw"] = {
	canonicalName = "Waiwai",
	otherNames = {"Uaiuai", "Uaieue", "Ouayeone", "Katawian", "Karahawyana"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["wax"] = {
	canonicalName = "Watam",
	otherNames = {"Marangis"},
	scripts = {"Latn"},
	family = "paa",
}

m["way"] = {
	canonicalName = "Wayana",
	scripts = {"Latn"},
	family = "sai-car",
}

m["waz"] = {
	canonicalName = "Wampur",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wba"] = {
	canonicalName = "Warao",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["wbb"] = {
	canonicalName = "Wabo",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["wbe"] = {
	canonicalName = "Waritai",
	scripts = {"Latn"},
	family = "paa-lkp",
}

m["wbf"] = {
	canonicalName = "Wara",
}

m["wbh"] = {
	canonicalName = "Wanda",
}

m["wbi"] = {
	canonicalName = "Wanji",
}

m["wbj"] = {
	canonicalName = "Alagwa",
	family = "cus",
}

m["wbk"] = {
	canonicalName = "Waigali",
	family = "iir-nur",
}

m["wbl"] = {
	canonicalName = "Wakhi",
	scripts = {"Cyrl", "Latn", "Arab"},
	family = "ira",
}

m["wbm"] = {
	canonicalName = "Wa",
	otherNames = {"Va"}, -- cf 'vwa'
	family = "aav",
}

m["wbp"] = {
	canonicalName = "Warlpiri",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wbq"] = {
	canonicalName = "Waddar",
	family = "dra",
	ancestors = {"te"},
}

m["wbr"] = {
	canonicalName = "Wagdi",
}

m["wbt"] = {
	canonicalName = "Wanman",
}

m["wbv"] = {
	canonicalName = "Wajarri",
	scripts = {"Latn"},
	family = "aus-psw",
}

m["wbw"] = {
	canonicalName = "Woi",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["wca"] = {
	canonicalName = "Yanomámi",
}

m["wci"] = {
	canonicalName = "Waci Gbe",
}

m["wdd"] = {
	canonicalName = "Wandji",
}

m["wdg"] = {
	canonicalName = "Wadaginam",
}

m["wdj"] = {
	canonicalName = "Wadjiginy",
	otherNames = {"Wagaydy", "Wadyiginy", "Wogaity", "Patjtjamalh", "Batjamalh", "Batytyamalh", "Batyamal", "Bachamal", "Wogait", "Wagaitj", "Wogati", "Worgait", "Worgite", "Waggait", "Waggite", "Waggote", "Waggate", "Wagatsch", "Waogatsch"},
}

m["wdu"] = {
	canonicalName = "Wadjigu",
}

m["wdy"] = {
	canonicalName = "Wadjabangayi",
}

m["wea"] = {
	canonicalName = "Wewaw",
}

m["wec"] = {
	canonicalName = "Wè Western",
}

m["wed"] = {
	canonicalName = "Wedau",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["weh"] = {
	canonicalName = "Weh",
}

m["wei"] = {
	canonicalName = "Kiunum",
}

m["wem"] = {
	canonicalName = "Weme Gbe",
}

m["weo"] = {
	canonicalName = "Wemale",
	otherNames = {"North Wemale", "South Wemale"},
	family = "plf",
}

m["wer"] = {
	canonicalName = "Weri",
}

m["wes"] = {
	canonicalName = "Cameroon Pidgin",
	scripts = {"Latn"},
}

m["wet"] = {
	canonicalName = "Perai",
}

m["weu"] = {
	canonicalName = "Welaung",
	otherNames = {"Rawngtu Chin", "Rawngtu"},
	family = "tbq-kuk",
}

m["wew"] = {
	canonicalName = "Weyewa",
	scripts = {"Latn"},
	family = "plf",
}

m["wfg"] = {
	canonicalName = "Yafi",
}

m["wga"] = {
	canonicalName = "Wagaya",
}

m["wgb"] = {
	canonicalName = "Wagawaga",
}

m["wgg"] = {
	canonicalName = "Wangganguru",
	family = "aus-kar",
}

m["wgi"] = {
	canonicalName = "Wahgi",
}

m["wgo"] = {
	canonicalName = "Waigeo",
	family = "poz-hce",
}

m["wgu"] = {
	canonicalName = "Wirangu",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wgy"] = {
	canonicalName = "Warrgamay",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wha"] = {
	canonicalName = "Manusela",
	otherNames = {"Sou Upaa"},
	family = "plf",
}

m["whg"] = {
	canonicalName = "North Wahgi",
}

m["whk"] = {
	canonicalName = "Wahau Kenyah",
	family = "poz-swa",
}

m["whu"] = {
	canonicalName = "Wahau Kayan",
}

m["wib"] = {
	canonicalName = "Southern Toussian",
}

m["wic"] = {
	canonicalName = "Wichita",
	family = "cdd",
}

m["wie"] = {
	canonicalName = "Wik-Epa",
}

m["wif"] = {
	canonicalName = "Wik-Keyangan",
}

m["wig"] = {
	canonicalName = "Wik-Ngathana",
}

m["wih"] = {
	canonicalName = "Wik-Me'anha",
}

m["wii"] = {
	canonicalName = "Minidien",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["wij"] = {
	canonicalName = "Wik-Iiyanh",
}

m["wik"] = {
	canonicalName = "Wikalkan",
}

m["wil"] = {
	canonicalName = "Wilawila",
}

m["wim"] = {
	canonicalName = "Wik-Mungkan",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["win"] = {
	canonicalName = "Winnebago",
	otherNames = {"Hocak", "Hochank", "Hochunk"},
	scripts = {"Latn"},
	family = "sio",
}

m["wir"] = {
	canonicalName = "Wiraféd",
}

m["wiu"] = {
	canonicalName = "Wiru",
}

m["wiv"] = {
	canonicalName = "Muduapa",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wiy"] = {
	canonicalName = "Wiyot",
	scripts = {"Latn"},
	family = "aql",
}

m["wja"] = {
	canonicalName = "Waja",
}

m["wji"] = {
	canonicalName = "Warji",
}

m["wka"] = {
	canonicalName = "Kw'adza",
	family = "cus",
}

m["wkb"] = {
	canonicalName = "Kumbaran",
	family = "dra",
}

m["wkd"] = {
	canonicalName = "Mo",
	otherNames = {"Wakde"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wkl"] = {
	canonicalName = "Kalanadi",
	family = "dra",
}

m["wku"] = {
	canonicalName = "Kunduvadi",
	family = "dra",
}

m["wkw"] = {
	canonicalName = "Wakawaka",
}

m["wky"] = {
	canonicalName = "Wangkayutyuru",
}

m["wla"] = {
	canonicalName = "Walio",
}

m["wlc"] = {
	canonicalName = "Mwali Comorian",
}

m["wle"] = {
	canonicalName = "Wolane",
	family = "sem-eth",
}

m["wlg"] = {
	canonicalName = "Kunbarlang",
	scripts = {"Latn"},
	family = "aus-gun",
}

m["wli"] = {
	canonicalName = "Waioli",
}

m["wlk"] = {
	canonicalName = "Wailaki",
	scripts = {"Latn"},
	family = "ath-pco",
}

m["wll"] = {
	canonicalName = "Wali (Sudan)",
	otherNames = {"Wali"}, -- part of the Hill Nubian or Kordofanian Nubian dialect continuum
	family = "nub",
}

m["wlm"] = {
	canonicalName = "Middle Welsh",
	scripts = {"Latn"},
	family = "cel-bry",
	ancestors = {"owl"},
}

m["wlo"] = {
	canonicalName = "Wolio",
	scripts = {"Latn", "Arab"},
	family = "poz-wot",
}

m["wlr"] = {
	canonicalName = "Wailapa",
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["wls"] = {
	canonicalName = "Wallisian",
	otherNames = {"East Uvean", "ʻUvean", "Fakaʻuvea"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["wlu"] = {
	canonicalName = "Wuliwuli",
}

m["wlv"] = {
	canonicalName = "Wichí Lhamtés Vejoz",
	scripts = {"Latn"},
	family = "sai-wic",
}

m["wlw"] = {
	canonicalName = "Walak",
}

m["wlx"] = {
	canonicalName = "Wali (Ghana)",
	otherNames = {"Wali", "Waali", "Walii"},
	scripts = {"Latn"},
	family = "nic-gur",
}

m["wly"] = {
	canonicalName = "Waling",
}

m["wma"] = {
	canonicalName = "Mawa",
	otherNames = {"Mawa (Nigeria)"},
	scripts = {"Latn"},
}

m["wmb"] = {
	canonicalName = "Wambaya",
}

m["wmc"] = {
	canonicalName = "Wamas",
}

m["wmd"] = {
	canonicalName = "Mamaindé",
	otherNames = {"Mamaindê", "Mamainde"},
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["wme"] = {
	canonicalName = "Wambule",
	scripts = {"Latn"},
	family = "tbq",
}

m["wmh"] = {
	canonicalName = "Waima'a",
	otherNames = {"Waimoa"},
	scripts = {"Latn"},
	family = "poz",
}

m["wmi"] = {
	canonicalName = "Wamin",
}

m["wmm"] = {
	canonicalName = "Maiwa (Indonesia)",
	otherNames = {"Maiwa"},
	scripts = {"Latn"},
	family = "poz",
}

m["wmn"] = {
	canonicalName = "Waamwang",
	scripts = {"Latn"},
	family = "poz-cln",
}

m["wmo"] = {
	canonicalName = "Wam",
	otherNames = {"Wom (New Guinea)", "Wom (Papua New Guinea)", "Wom"},
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["wms"] = {
	canonicalName = "Wambon",
	scripts = {"Latn"},
	family = "ngf",
}

m["wmt"] = {
	canonicalName = "Walmajarri",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wmw"] = {
	canonicalName = "Mwani",
}

m["wmx"] = {
	canonicalName = "Womo",
	scripts = {"Latn"},
	family = "paa-msk",
}

m["wnb"] = {
	canonicalName = "Wanambre",
	scripts = {"Latn"},
	family = "ngf",
}

m["wnc"] = {
	canonicalName = "Wantoat",
	scripts = {"Latn"},
	family = "ngf-fin",
}

m["wnd"] = {
	canonicalName = "Wandarang",
	scripts = {"Latn"},
	family = "aus-arn",
}

m["wne"] = {
	canonicalName = "Waneci",
	otherNames = {"Wanetsi", "Wanechi", "Chalgari", "Tarino"},
	scripts = {"ps-Arab"},
	family = "ira",
	ancestors = {"ps"},
}

m["wng"] = {
	canonicalName = "Wanggom", -- possibly not distinct from 'tyn'
	scripts = {"Latn"},
	family = "ngf",
}

m["wni"] = {
	canonicalName = "Ndzwani Comorian",
}

m["wnk"] = {
	canonicalName = "Wanukaka",
	scripts = {"Latn"},
	family = "poz",
}

m["wnm"] = {
	canonicalName = "Wanggamala",
	scripts = {"Latn"},
	family = "aus-kar",
}

m["wno"] = {
	canonicalName = "Wano",
	scripts = {"Latn"},
	family = "ngf",
}

m["wnp"] = {
	canonicalName = "Wanap",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["wnu"] = {
	canonicalName = "Usan",
	scripts = {"Latn"},
	family = "ngf",
}

m["wnw"] = {
	canonicalName = "Wintu",
	scripts = {"Latn"},
	family = "nai-wtq",
}

m["wny"] = {
	canonicalName = "Wanyi",
	otherNames = {"Wanji", "Waanyi"},
	scripts = {"Latn"},
	family = "aus-gar",
}

m["woa"] = {
	canonicalName = "Tyaraity", -- lot of alt names
}

m["wob"] = {
	canonicalName = "Wè Northern",
}

m["woc"] = {
	canonicalName = "Wogeo",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["wod"] = {
	canonicalName = "Wolani",
	scripts = {"Latn"},
	family = "ngf",
}

m["woe"] = {
	canonicalName = "Woleaian",
	scripts = {"Latn"},
	family = "poz-mic",
}

m["wog"] = {
	canonicalName = "Wogamusin",
	scripts = {"Latn"},
	family = "paa-spk",
}

m["woi"] = {
	canonicalName = "Kamang",
	otherNames = {"Woisika"},
	scripts = {"Latn"},
	family = "ngf",
}

m["wok"] = {
	canonicalName = "Longto",
	otherNames = {"Voko", "Woko"},
	scripts = {"Latn"},
	family = "alv",
}

m["wom"] = {
	canonicalName = "Perema",
	otherNames = {"Wom (Nigeria)", "Wom"},
	scripts = {"Latn"},
	family = "alv",
}

m["won"] = {
	canonicalName = "Wongo",
	scripts = {"Latn"},
	family = "bnt",
}

m["woo"] = {
	canonicalName = "Manombai",
	scripts = {"Latn"},
	family = "poz",
}

m["wor"] = {
	canonicalName = "Woria",
	scripts = {"Latn"},
}

m["wos"] = {
	canonicalName = "Hanga Hundi",
	scripts = {"Latn"},
	family = "paa-spk",
}

m["wow"] = {
	canonicalName = "Wawonii",
	scripts = {"Latn"},
	family = "poz",
}

m["woy"] = {
	canonicalName = "Weyto",
	scripts = {"Latn"},
}

m["wpc"] = {
	canonicalName = "Wirö",
	otherNames = {"Wiru", "Maco", "Mako", "Maku", "Macu", "Wotuja"},
	scripts = {"Latn"},
}

m["wra"] = {
	canonicalName = "Warapu",
	otherNames = {"Barupu"},
	scripts = {"Latn"},
	family = "paa-msk",
}

m["wrb"] = {
	canonicalName = "Warluwara",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wrg"] = {
	canonicalName = "Warungu",
	otherNames = {"Warrungu", "Warrongo", "Warrangu", "Warrango"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wrh"] = {
	canonicalName = "Wiradhuri",
	scripts = {"Latn"},
	family = "aus-cww",
}

m["wri"] = {
	canonicalName = "Wariyangga",
	family = "aus-psw",
}

m["wrk"] = {
	canonicalName = "Garawa",
	otherNames = {"Garrwa", "Karawa"},
	scripts = {"Latn"},
	family = "aus-gar",
}

m["wrl"] = {
	canonicalName = "Warlmanpa",
}

m["wrm"] = {
	canonicalName = "Warumungu",
}

m["wrn"] = {
	canonicalName = "Warnang",
}

m["wro"] = {
	canonicalName = "Worora",
	otherNames = {"Worrorra", "Wororan", "Worrorran"},
}

m["wrp"] = {
	canonicalName = "Waropen",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["wrr"] = {
	canonicalName = "Wardaman",
}

m["wrs"] = {
	canonicalName = "Waris",
}

m["wru"] = {
	canonicalName = "Waru",
}

m["wrv"] = {
	canonicalName = "Waruna",
}

m["wrw"] = {
	canonicalName = "Gugu Warra",
}

m["wrx"] = {
	canonicalName = "Wae Rana",
}

m["wrz"] = {
	canonicalName = "Warray",
	otherNames = {"Waray"},
	family = "aus-gun",
}

m["wsa"] = {
	canonicalName = "Warembori",
}

m["wsi"] = {
	canonicalName = "Wusi",
	otherNames = {"Kerepua", "Wusi-Kerepua"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["wsk"] = {
	canonicalName = "Waskia",
	scripts = {"Latn"},
	family = "ngf",
}

m["wsr"] = {
	canonicalName = "Owenia",
}

m["wss"] = {
	canonicalName = "Wasa",
}

m["wsu"] = {
	canonicalName = "Wasu",
}

m["wsv"] = {
	canonicalName = "Wotapuri-Katarqalai",
}

m["wtf"] = {
	canonicalName = "Watiwa",
	family = "ngf",
}

m["wth"] = {
	canonicalName = "Wathaurong",
	otherNames = {"Wathawurrung", "Wathaurung", "Wada wurrung", "Barrabool"},
	family = "aus-pam",
}

m["wti"] = {
	canonicalName = "Berta",
}

m["wtk"] = {
	canonicalName = "Watakataui",
}

m["wtm"] = {
	canonicalName = "Mewati",
}

m["wtw"] = {
	canonicalName = "Wotu",
}

m["wua"] = {
	canonicalName = "Wikngenchera",
}

m["wub"] = {
	canonicalName = "Wunambal",
}

m["wud"] = {
	canonicalName = "Wudu",
	family = "alv-kwa",
}

m["wuh"] = {
	canonicalName = "Wutunhua",
}

m["wul"] = {
	canonicalName = "Silimo",
}

m["wum"] = {
	canonicalName = "Wumbvu",
	family = "bnt",
}

m["wun"] = {
	canonicalName = "Bungu",
	family = "bnt",
}

m["wur"] = {
	canonicalName = "Wurrugu",
	otherNames = {"Popham Bay language"},
	family = "aus-wdj",
}

m["wut"] = {
	canonicalName = "Wutung",
	family = "paa-msk",
}

m["wuu"] = {
	canonicalName = "Wu",
	otherNames = {"Suzhounese", "Shanghainese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"ltc"},
}

m["wuv"] = {
	canonicalName = "Wuvulu-Aua",
	otherNames = {"Wuvulu"},
	family = "poz-aay",
}

m["wux"] = {
	canonicalName = "Wulna",
}

m["wuy"] = {
	canonicalName = "Wauyai",
	family = "poz-hce",
}

m["wwa"] = {
	canonicalName = "Waama",
	family = "nic-gur",
}

m["wwo"] = {
	canonicalName = "Dorig",
	family = "poz-vnc",
}

m["wwr"] = {
	canonicalName = "Warrwa",
}

m["www"] = {
	canonicalName = "Wawa",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["wxa"] = {
	canonicalName = "Waxianghua",
}

m["wxw"] = {
	canonicalName = "Wardandi",
}

m["wya"] = {
	canonicalName = "Wyandot",
	scripts = {"Latn"},
	family = "iro",
}

m["wyb"] = {
	canonicalName = "Ngiyambaa",
	otherNames = {"Wangaaybuwan-Ngiyambaa", "Wangaaybuwan", "Wayilwan"},
	scripts = {"Latn"},
	family = "aus-cww",
}

m["wyi"] = {
	canonicalName = "Woiwurrung",
	otherNames = {"Woiworung", "Woiwurrong", "Wuywurung", "Wurundjeri", "Warerong", "Warorong", "Waverong", "Wavoo-rong", "Wawoorong", "Wawoo-rong", "Wawurong", "Wawurrong", "Woewo-rung", "Woiwurong", "Woi-wurrong", "Woiwurru", "Woiwurung", "Wooeewoorong", "Wowerong", "Wainworra", "Wairwaioo", "Warwaroo", "Wurrundyirra-baluk", "Wurrunjeri", "Wurunjeri", "Wurunjerri-baluk", "Oorongie", "Urunjeri", "Bunurong", "Bunwurrung", "Boonwerung", "Boonwurrung", "Bunurowrung", "Boonoorong", "Boonerwrung", "Bururong"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["wym"] = {
	canonicalName = "Vilamovian",
	otherNames = {"Wilamowicean", "Vilamovicean", "Wymysorys"}, -- Vilamovian and Wym. may not even meet CFI
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmh"},
}

m["wyr"] = {
	canonicalName = "Wayoró",
	family = "tup",
}

m["wyy"] = {
	canonicalName = "Western Fijian",
	family = "poz-occ",
}

return m