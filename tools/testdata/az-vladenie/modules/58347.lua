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

m["baa"] = {
	canonicalName = "Babatana",
	otherNames = {"Mbambatana"},
	family = "poz-ocw",
}

m["bab"] = {
	canonicalName = "Bainouk-Gunyuño",
	family = "alv-sng",
}

m["bac"] = {
	canonicalName = "Badui",
	family = "poz-msa",
}

m["bae"] = {
	canonicalName = "Baré",
	otherNames = {"Barawana"},
	scripts = {"Latn"},
	family = "awd",
}

m["baf"] = {
	canonicalName = "Nubaca",
	family = "nic-bod",
}

m["bag"] = {
	canonicalName = "Tuki",
	family = "nic-bod",
}

m["bah"] = {
	canonicalName = "Bahamian Creole",
	otherNames = {"Bahamian Creole English", "Bahamian", "Bahamas Creole", "Bahamas Creole English"},
	family = "crp",
}

m["baj"] = {
	canonicalName = "Barakai",
	family = "plf",
}

m["bal"] = {
	canonicalName = "Baluchi",
	otherNames = {"Balochi", "Southern Baluchi", "Southern Balochi", "Eastern Baluchi", "Eastern Balochi", "Western Baluchi", "Western Balochi"},
	scripts = {"fa-Arab"},
	family = "ira",
}

m["ban"] = {
	canonicalName = "Balinese",
	scripts = {"Latn", "Bali"},
	family = "poz-msa",
}

m["bao"] = {
	canonicalName = "Waimaha",
	family = "sai-tuc",
}

m["bap"] = {
	canonicalName = "Bantawa",
	family = "sit",
}

m["bar"] = {
	canonicalName = "Bavarian",
	otherNames = {"Austro-Bavarian"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmh"},
}

m["bas"] = {
	canonicalName = "Basaa",
	otherNames = {"Basa (Cameroon)", "Basa"},
	family = "bnt",
}

m["bau"] = {
	canonicalName = "Badanchi",
	otherNames = {"Bada", "Bada (Nigeria)"},
	family = "nic-bod",
}

m["bav"] = {
	canonicalName = "Babungo",
	otherNames = {"Vengo"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["baw"] = {
	canonicalName = "Bambili-Bambui",
	family = "nic-bod",
}

m["bax"] = {
	canonicalName = "Bamum",
	otherNames = {"Bamun"},
	scripts = {"Latn", "Bamu"},
	family = "nic-bod",
}

m["bay"] = {
	canonicalName = "Batuley",
	family = "poz",
}

m["bba"] = {
	canonicalName = "Baatonum",
	family = "alv",
}

m["bbb"] = {
	canonicalName = "Barai",
}

m["bbc"] = {
	canonicalName = "Toba Batak",
	otherNames = {"Batak Toba"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["bbd"] = {
	canonicalName = "Bau",
}

m["bbe"] = {
	canonicalName = "Bangba",
	family = "nic-ubg",
}

m["bbf"] = {
	canonicalName = "Baibai",
}

m["bbg"] = {
	canonicalName = "Barama",
}

m["bbh"] = {
	canonicalName = "Bugan",
	otherNames = {"Bogan"},
	family = "mkh",
}

m["bbi"] = {
	canonicalName = "Barombi",
}

m["bbj"] = {
	canonicalName = "Ghomálá'",
	family = "bai",
}

m["bbk"] = {
	canonicalName = "Babanki",
}

m["bbl"] = {
	canonicalName = "Bats",
	otherNames = {"Batsbi", "Tsova-Tush"},
	scripts = {"Geor"},
	translit_module = "Geor-translit",
	family = "cau-nkh",
	entry_name = {
		from = {"̃", "<sup>ნ</sup>", MACRON, BREVE}, 
		to   = {"", "ნ"}} ,
}

m["bbm"] = {
	canonicalName = "Babango",
}

m["bbn"] = {
	canonicalName = "Uneapa",
	family = "poz-ocw",
}

m["bbo"] = {
	canonicalName = "Konabéré",
	otherNames = {"Bobo Fing", "Black Bobo", "Northern Bobo Madaré", "Bobo"},
}

m["bbp"] = {
	canonicalName = "West Central Banda",
}

m["bbq"] = {
	canonicalName = "Bamali",
	family = "nic-bod",
}

m["bbr"] = {
	canonicalName = "Girawa",
}

m["bbs"] = {
	canonicalName = "Bakpinka",
	family = "nic-bco",
}

m["bbt"] = {
	canonicalName = "Mburku",
}

m["bbu"] = {
	canonicalName = "Bakulung",
	otherNames = {"Kulung", "Kulung (Nigeria)"},
}

m["bbv"] = {
	canonicalName = "Karnai",
}

m["bbw"] = {
	canonicalName = "Baba",
	family = "nic-bod",
}

m["bbx"] = {
	canonicalName = "Bubia",
}

m["bby"] = {
	canonicalName = "Befang",
	family = "nic-bod",
}

m["bbz"] = {
	canonicalName = "Babalia Creole Arabic",
	otherNames = {"Babalia Arabic"},
	family = "crp",
	ancestors = {"ar"},
}

m["bca"] = {
	canonicalName = "Central Bai",
	otherNames = {"Jianchuan Bai"},
	family = "sit",
}

m["bcb"] = {
	canonicalName = "Bainouk-Samik",
	family = "alv-sng",
}

m["bcd"] = {
	canonicalName = "North Babar",
}

m["bce"] = {
	canonicalName = "Bamenyam",
	family = "nic-bod",
}

m["bcf"] = {
	canonicalName = "Bamu",
}

m["bcg"] = {
	canonicalName = "Baga Pokur",
	otherNames = {"Baga Binari", "Baga Mboteni"},
}

m["bch"] = {
	canonicalName = "Bariai",
	family = "poz-ocw",
}

m["bci"] = {
	canonicalName = "Baoule",
	otherNames = {"Baoulé", "Bawule"},
	scripts = {"Latn"},
}

m["bcj"] = {
	canonicalName = "Bardi",
}

m["bck"] = {
	canonicalName = "Bunaba",
	family = "aus-bub",
}

m["bcl"] = {
	canonicalName = "Bikol Central",
	otherNames = {"Central Bikol", "Bikol"}, -- also "Central Bicolano"?
	scripts = {"Latn"},
	family = "phi",
}

m["bcm"] = {
	canonicalName = "Bannoni",
	family = "poz-ocw",
}

m["bcn"] = {
	canonicalName = "Bibaali",
	otherNames = {"Bali", "Bali (Nigeria)", "Abaali"},
}

m["bco"] = {
	canonicalName = "Kaluli",
}

m["bcp"] = {
	canonicalName = "Bali",
	otherNames = {"Bali (Congo)", "Bali (Democratic Republic of the Congo)", "Baali", "Kibali", "Libaali"},
}

m["bcq"] = {
	canonicalName = "Bench",
}

m["bcr"] = {
	canonicalName = "Babine-Witsuwit'en",
	otherNames = {"Babine", "Witsuwit'en"},
	scripts = {"Latn"},
	family = "ath",
}

m["bcs"] = {
	canonicalName = "Kohumono",
	family = "nic-bco",
}

m["bct"] = {
	canonicalName = "Bendi",
}

m["bcu"] = {
	canonicalName = "Biliau",
	otherNames = {"Awad Bing"},
	family = "poz-ocw",
}

m["bcv"] = {
	canonicalName = "Shoo-Minda-Nye",
	otherNames = {"Shoo", "Minda", "Nye"},
	family = "nic-bco",
}

m["bcw"] = {
	canonicalName = "Bana",
}

m["bcy"] = {
	canonicalName = "Bacama",
}

m["bcz"] = {
	canonicalName = "Bainouk-Gunyaamolo",
	family = "alv-sng",
}

m["bda"] = {
	canonicalName = "Bayot",
}

m["bdb"] = {
	canonicalName = "Basap",
}

m["bdc"] = {
	canonicalName = "Emberá-Baudó",
}

m["bdd"] = {
	canonicalName = "Bunama",
	family = "poz-ocw",
}

m["bde"] = {
	canonicalName = "Bade",
}

m["bdf"] = {
	canonicalName = "Biage",
}

m["bdg"] = {
	canonicalName = "Bonggi",
}

m["bdh"] = {
	canonicalName = "Tara Baka",
	otherNames = {"Baka", "Baka (Sudan)"},
}

m["bdi"] = {
	canonicalName = "Burun",
	otherNames = {"Northern Burun", "Maiak", "Mayak", "Mughaja", "Kurmuk"},
	scripts = {"Latn"},
	family = "sdv",
}

m["bdj"] = {
	canonicalName = "Bai",
}

m["bdk"] = {
	canonicalName = "Budukh",
	otherNames = {"Budugh"},
	scripts = {"Cyrl"},
	family = "cau-lzg",
}

m["bdl"] = {
	canonicalName = "Indonesian Bajau",
}

m["bdm"] = {
	canonicalName = "Buduma",
	otherNames = {"Yedina", "Kuri"},
	scripts = {"Latn"},
	family = "cdc-cbm",
}

m["bdn"] = {
	canonicalName = "Baldemu",
}

m["bdo"] = {
	canonicalName = "Morom",
}

m["bdp"] = {
	canonicalName = "Bende",
}

m["bdq"] = {
	canonicalName = "Bahnar",
	family = "mkh",
}

m["bdr"] = {
	canonicalName = "West Coast Bajau",
	scripts = {"Latn"},
	family = "poz-sbj",
}

m["bds"] = {
	canonicalName = "Burunge",
	family = "cus",
}

m["bdt"] = {
	canonicalName = "Bokoto",
}

m["bdu"] = {
	canonicalName = "Oroko",
	otherNames = {"Bima"},
}

m["bdv"] = {
	canonicalName = "Bodo Parja",
}

m["bdw"] = {
	canonicalName = "Baham",
}

m["bdx"] = {
	canonicalName = "Budong-Budong",
}

m["bdy"] = {
	canonicalName = "Bandjalang",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["bdz"] = {
	canonicalName = "Badeshi",
}

m["bea"] = {
	canonicalName = "Beaver",
}

m["beb"] = {
	canonicalName = "Bebele",
	family = "bnt",
}

m["bec"] = {
	canonicalName = "Iceve-Maci",
	family = "nic-bod",
}

m["bed"] = {
	canonicalName = "Bedoanas",
	family = "poz-hce",
}

m["bee"] = {
	canonicalName = "Byangsi",
	family = "sit",
}

m["bef"] = {
	canonicalName = "Benabena",
}

m["beg"] = {
	canonicalName = "Belait",
	otherNames = {"Lemeting"},
	family = "poz-swa",
}

m["beh"] = {
	canonicalName = "Biali",
}

m["bei"] = {
	canonicalName = "Bekati'",
}

m["bej"] = {
	canonicalName = "Beja",
	scripts = {"Arab"},
	family = "cus",
}

m["bek"] = {
	canonicalName = "Bebeli",
	family = "poz-ocw",
}

m["bem"] = {
	canonicalName = "Bemba",
	otherNames = {"Bemba (Zambia)"},
	family = "bnt",
}

m["beo"] = {
	canonicalName = "Beami",
}

m["bep"] = {
	canonicalName = "Besoa",
}

m["beq"] = {
	canonicalName = "Beembe",
}

m["bes"] = {
	canonicalName = "Besme",
}

m["bet"] = {
	canonicalName = "Guiberoua Béte",
}

m["beu"] = {
	canonicalName = "Blagar",
	otherNames = {"Belagar"},
}

m["bev"] = {
	canonicalName = "Daloa Bété",
}

m["bew"] = {
	canonicalName = "Betawi",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"ms"},
}

m["bex"] = {
	canonicalName = "Jur Modo",
}

m["bey"] = {
	canonicalName = "Akuwagel",
	otherNames = {"Beli", "Beli (New Guinea)", "Beli (Papua New Guinea)"},
	family = "qfa-tor",
}

m["bez"] = {
	canonicalName = "Kibena",
	otherNames = {"Bena", "Bena (Tanzania)"},
}

m["bfa"] = {
	canonicalName = "Bari",
	scripts = {"Latn"},
	family = "sdv",
}

m["bfb"] = {
	canonicalName = "Pauri Bareli",
}

m["bfc"] = {
	canonicalName = "Northern Bai",
	otherNames = {"Bijiang Bai", "Laemae", "Lama", "Panyi Bai"},
	family = "sit",
}

m["bfd"] = {
	canonicalName = "Bafut",
	family = "nic-bod",
}

m["bfe"] = {
	canonicalName = "Betaf",
}

m["bff"] = {
	canonicalName = "Bofi",
}

m["bfg"] = {
	canonicalName = "Busang Kayan",
}

m["bfh"] = {
	canonicalName = "Blafe",
}

m["bfi"] = {
	canonicalName = "British Sign Language",
	otherNames = {"BSL"},
	family = "sgn",
}

m["bfj"] = {
	canonicalName = "Bafanji",
	family = "nic-bod",
}

m["bfk"] = {
	canonicalName = "Ban Khor Sign Language",
	family = "sgn",
}

m["bfl"] = {
	canonicalName = "Banda-Ndélé",
}

m["bfm"] = {
	canonicalName = "Mmen",
	family = "nic-bod",
}

m["bfn"] = {
	canonicalName = "Bunak",
}

m["bfo"] = {
	canonicalName = "Malba Birifor",
}

m["bfp"] = {
	canonicalName = "Beba",
	family = "nic-bod",
}

m["bfq"] = {
	canonicalName = "Badaga",
	scripts = {"Knda"},
	family = "dra",
}

m["bfr"] = {
	canonicalName = "Bazigar",
	family = "dra",
}

m["bfs"] = {
	canonicalName = "Southern Bai",
	otherNames = {"Dali Bai"},
	family = "sit",
}

m["bft"] = {
	canonicalName = "Balti",
	scripts = {"Arab", "Tibt"},
	family = "tbq",
	ancestors = {"xct"},
}

m["bfu"] = {
	canonicalName = "Gahri",
}

m["bfw"] = {
	canonicalName = "Bondo",
	otherNames = {"Remo"},
	family = "mun",
}

m["bfx"] = {
	canonicalName = "Bantayanon",
}

m["bfy"] = {
	canonicalName = "Bagheli",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"psu"},
}

m["bfz"] = {
	canonicalName = "Mahasu Pahari",
}

m["bga"] = {
	canonicalName = "Gwamhi-Wuri",
}

m["bgb"] = {
	canonicalName = "Bobongko",
}

m["bgc"] = {
	canonicalName = "Haryanvi",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"psu"},
}

m["bgd"] = {
	canonicalName = "Rathwi Bareli",
}

m["bge"] = {
	canonicalName = "Bauria",
}

m["bgf"] = {
	canonicalName = "Bangandu",
}

m["bgg"] = {
	canonicalName = "Bugun",
}

m["bgi"] = {
	canonicalName = "Giangan",
}

m["bgj"] = {
	canonicalName = "Bangolan",
	family = "nic-bod",
}

m["bgk"] = {
	canonicalName = "Bit",
	family = "mkh",
}

m["bgl"] = {
	canonicalName = "Bo",
	otherNames = {"Bo (Laos)"}, -- if 'bpw' is added, the disambiguating name will have to be made the canonical one 
	family = "mkh-vie",
}

m["bgo"] = {
	canonicalName = "Baga Koga",
}

m["bgq"] = {
	canonicalName = "Bagri",
	family = "inc",
	ancestors = {"raj"},
}

m["bgr"] = {
	canonicalName = "Bawm Chin",
	otherNames = {"Bawm", "Banjogi"},
	family = "tbq-kuk",
}

m["bgs"] = {
	canonicalName = "Tagabawa",
}

m["bgt"] = {
	canonicalName = "Bughotu",
	otherNames = {"Bugotu"},
	scripts = {"Latn"},
	family = "poz-sls",
}

m["bgu"] = {
	canonicalName = "Mbongno",
	family = "nic-bod",
}

m["bgv"] = {
	canonicalName = "Warkay-Bipim",
}

m["bgw"] = {
	canonicalName = "Bhatri",
	family = "inc",
	ancestors = {"pka"},
}

m["bgx"] = {
	canonicalName = "Balkan Gagauz Turkish",
	otherNames = {"Balkan Turkic"},
	scripts = {"Latn"},
	family = "trk-ogz",
}

m["bgy"] = {
	canonicalName = "Benggoi",
}

m["bgz"] = {
	canonicalName = "Banggai",
	scripts = {"Latn"},
	family = "poz-slb",
}

m["bha"] = {
	canonicalName = "Bharia",
	scripts = {"Deva"},
	family = "dra",
}

m["bhb"] = {
	canonicalName = "Bhili",
	scripts = {"Deva"},
	family = "inc",
}

m["bhc"] = {
	canonicalName = "Biga",
	family = "poz-hce",
}

m["bhd"] = {
	canonicalName = "Bhadrawahi",
}

m["bhe"] = {
	canonicalName = "Bhaya",
	family = "inc",
	ancestors = {"raj"},
}

m["bhf"] = {
	canonicalName = "Odiai",
}

m["bhg"] = {
	canonicalName = "Binandere",
}

m["bhh"] = {
	canonicalName = "Bukhari",
	otherNames = {"Bukhori", "Bukharian", "Bukharic", "Buchari", "Buchori", "Bucharian", "Bucharic"},
	scripts = {"Cyrl", "Hebr", "Latn", "fa-Arab"},
	family = "ira",
	ancestors = {"tg"},
}

m["bhi"] = {
	canonicalName = "Bhilali",
}

m["bhj"] = {
	canonicalName = "Bahing",
}

m["bhl"] = {
	canonicalName = "Bimin",
}

m["bhm"] = {
	canonicalName = "Bathari",
}

m["bhn"] = {
	canonicalName = "Bohtan Neo-Aramaic",
	family = "sem-ara",
}

m["bho"] = {
	canonicalName = "Bhojpuri",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"bh"},
}

m["bhp"] = {
	canonicalName = "Bima",
	otherNames = {"Bimanese"},
	scripts = {"Latn"},
	family = "plf",
}

m["bhq"] = {
	canonicalName = "Tukang Besi South",
}

m["bhs"] = {
	canonicalName = "Buwal",
}

m["bht"] = {
	canonicalName = "Bhattiyali",
}

m["bhu"] = {
	canonicalName = "Bhunjia",
	scripts = {"Deva", "Orya"},
	family = "inc",
	ancestors = {"pka"},
}

m["bhv"] = {
	canonicalName = "Bahau",
}

m["bhw"] = {
	canonicalName = "Biak",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["bhx"] = {
	canonicalName = "Bhalay",
}

m["bhy"] = {
	canonicalName = "Bhele",
}

m["bhz"] = {
	canonicalName = "Bada",
	otherNames = {"Bada (Indonesia)"},
}

m["bia"] = {
	canonicalName = "Badimaya",
	family = "aus-psw",
}

m["bib"] = {
	canonicalName = "Bissa",
}

m["bic"] = {
	canonicalName = "Bikaru",
}

m["bid"] = {
	canonicalName = "Bidiyo",
}

m["bie"] = {
	canonicalName = "Bepour",
}

m["bif"] = {
	canonicalName = "Biafada",
	family = "alv-sng",
}

m["big"] = {
	canonicalName = "Biangai",
}

m["bij"] = {
	canonicalName = "Vaghat-Ya-Bijim-Legeri",
}

m["bil"] = {
	canonicalName = "Bile",
}

m["bim"] = {
	canonicalName = "Bimoba",
}

m["bin"] = {
	canonicalName = "Edo",
	otherNames = {"Bini"},
	scripts = {"Latn"},
	family = "alv-edo",
}

m["bio"] = {
	canonicalName = "Nai",
}

m["bip"] = {
	canonicalName = "Bila",
}

m["biq"] = {
	canonicalName = "Bipi",
	family = "poz-aay",
}

m["bir"] = {
	canonicalName = "Bisorio",
}

m["bit"] = {
	canonicalName = "Berinomo",
}

m["biu"] = {
	canonicalName = "Biete",
	family = "tbq-kuk",
}

m["biv"] = {
	canonicalName = "Southern Birifor",
}

m["biw"] = {
	canonicalName = "Kol (Cameroon)",
	otherNames = {"Kol"},
	family = "bnt",
}

m["bix"] = {
	canonicalName = "Bijori",
	family = "mun",
}

m["biy"] = {
	canonicalName = "Birhor",
	family = "mun",
}

m["biz"] = {
	canonicalName = "Baloi",
}

m["bja"] = {
	canonicalName = "Budza",
	otherNames = {"Buja"},
	family = "bnt",
}

m["bjb"] = {
	canonicalName = "Banggarla",
}

m["bjc"] = {
	canonicalName = "Bariji",
}

m["bje"] = {
	canonicalName = "Biao-Jiao Mien",
	family = "hmx-mie",
}

m["bjf"] = {
	canonicalName = "Barzani Jewish Neo-Aramaic",
	family = "sem-ara",
}

m["bjg"] = {
	canonicalName = "Bidyogo",
}

m["bjh"] = {
	canonicalName = "Bahinemo",
}

m["bji"] = {
	canonicalName = "Burji",
	family = "cus",
}

m["bjj"] = {
	canonicalName = "Kanauji",
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"psu"},
}

m["bjk"] = {
	canonicalName = "Barok",
	family = "poz-ocw",
}

m["bjl"] = {
	canonicalName = "Bulu (New Guinea)",
	otherNames = {"Bulu (Papua New Guinea)", "Bulu"},
	family = "poz-ocw",
}

m["bjm"] = {
	canonicalName = "Bajelani",
	family = "ira",
}

m["bjn"] = {
	canonicalName = "Banjarese",
	otherNames = {"Banjar"},
	scripts = {"Latn", "Arab"},
	family = "poz-mly",
}

m["bjo"] = {
	canonicalName = "Mid-Southern Banda",
}

m["bjp"] = {
	canonicalName = "Fanamaket",
	family = "poz-oce",
}

m["bjr"] = {
	canonicalName = "Binumarien",
}

m["bjs"] = {
	canonicalName = "Bajan",
}

m["bjt"] = {
	canonicalName = "Balanta-Ganja",
}

m["bju"] = {
	canonicalName = "Busuu",
	family = "nic-bod",
}

m["bjv"] = {
	canonicalName = "Bedjond",
}

m["bjw"] = {
	canonicalName = "Bakwé",
}

m["bjx"] = {
	canonicalName = "Banao Itneg",
}

m["bjy"] = {
	canonicalName = "Bayali",
}

m["bjz"] = {
	canonicalName = "Baruga",
	scripts = {"Latn"},
	family = "ngf",
}

m["bka"] = {
	canonicalName = "Kyak",
}

m["bkc"] = {
	canonicalName = "Baka",
	otherNames = {"Baka (Cameroon)"},
	family = "nic-ubg",
}

m["bkd"] = {
	canonicalName = "Binukid",
}

m["bkf"] = {
	canonicalName = "Beeke",
}

m["bkg"] = {
	canonicalName = "Buraka",
	family = "nic-ubg",
}

m["bkh"] = {
	canonicalName = "Bakoko",
}

m["bki"] = {
	canonicalName = "Baki",
	family = "poz-vnc",
}

m["bkj"] = {
	canonicalName = "Pande",
}

m["bkk"] = {
	canonicalName = "Brokskat",
}

m["bkl"] = {
	canonicalName = "Berik",
}

m["bkm"] = {
	canonicalName = "Kom (Cameroon)",
	otherNames = {"Kom"},
	scripts = {"Latn"},
	family = "nic-bod",
}

m["bkn"] = {
	canonicalName = "Bukitan",
	otherNames = {"Bekatan", "Bakatan", "Baketan"}, 
	family = "poz",
}

m["bko"] = {
	canonicalName = "Kwa'",
	family = "bai",
}

m["bkp"] = {
	canonicalName = "Iboko",
	otherNames = {"Boko", "Boko (Congo)", "Boko (Democratic Republic of the Congo)"},
}

m["bkq"] = {
	canonicalName = "Bakairí",
	family = "sai-car",
}

m["bkr"] = {
	canonicalName = "Bakumpai",
}

m["bks"] = {
	canonicalName = "Masbate Sorsogon",
}

m["bkt"] = {
	canonicalName = "Boloki",
}

m["bku"] = {
	canonicalName = "Buhid",
	scripts = {"Buhd"},
	family = "phi",
}

m["bkv"] = {
	canonicalName = "Bekwarra",
	family = "nic-bco",
}

m["bkw"] = {
	canonicalName = "Bekwel",
}

m["bkx"] = {
	canonicalName = "Baikeno",
	family = "plf",
}

m["bky"] = {
	canonicalName = "Bokyi",
	family = "nic-bco",
}

m["bkz"] = {
	canonicalName = "Bungku",
}

m["bla"] = {
	canonicalName = "Blackfoot",
	otherNames = {"Siksika", "Blackfeet"},
	scripts = {"Latn"},
	family = "alg",
}

m["blb"] = {
	canonicalName = "Bilua",
}

m["blc"] = {
	canonicalName = "Bella Coola",
	otherNames = {"Nuxálk", "Nuxalk"},
	scripts = {"Latn"},
	family = "sal",
}

m["bld"] = {
	canonicalName = "Bolango",
}

m["ble"] = {
	canonicalName = "Balanta-Kentohe",
}

m["blf"] = {
	canonicalName = "Buol",
}

m["blg"] = {
	canonicalName = "Balau",
}

m["blh"] = {
	canonicalName = "Kuwaa",
}

m["bli"] = {
	canonicalName = "Bolia",
}

m["blj"] = {
	canonicalName = "Bolongan",
}

m["blk"] = {
	canonicalName = "Pa'o Karen",
}

m["bll"] = {
	canonicalName = "Biloxi",
	family = "sio",
}

m["blm"] = {
	canonicalName = "Beli",
	otherNames = {"Behli", "Beili", "Jur Beli", "Beli (Sudan)", "Beli (South Sudan)"},
}

m["bln"] = {
	canonicalName = "Southern Catanduanes Bicolano",
}

m["blo"] = {
	canonicalName = "Anii",
}

m["blp"] = {
	canonicalName = "Blablanga",
	family = "poz-ocw",
}

m["blq"] = {
	canonicalName = "Baluan-Pam",
	scripts = {"Latn"},
	family = "poz-aay",
}

m["blr"] = {
	canonicalName = "Blang",
	otherNames = {"Bulang", "Pulang", "Kontoi", "Shinman"},
	family = "aav",
}

m["bls"] = {
	canonicalName = "Balaesang",
}

m["blt"] = {
	canonicalName = "Tai Dam",
	scripts = {"Tavt"},
	family = "tai-swe",
}

m["blv"] = {
	canonicalName = "Bolo",
}

m["blw"] = {
	canonicalName = "Balangao",
}

m["blx"] = {
	canonicalName = "Mag-Indi Ayta",
}

m["bly"] = {
	canonicalName = "Notre",
}

m["blz"] = {
	canonicalName = "Balantak",
}

m["bma"] = {
	canonicalName = "Lame",
}

m["bmb"] = {
	canonicalName = "Bembe",
	otherNames = {"Bemba", "Kinyabemba"},
	scripts = {"Latn"},
}


m["bmc"] = {
	canonicalName = "Biem",
	family = "poz-ocw",
}

m["bmd"] = {
	canonicalName = "Baga Manduri",
}

m["bme"] = {
	canonicalName = "Limassa",
	family = "nic-ubg",
}

m["bmf"] = {
	canonicalName = "Bom",
}

m["bmg"] = {
	canonicalName = "Bamwe",
}

m["bmh"] = {
	canonicalName = "Kein",
}

m["bmi"] = {
	canonicalName = "Bagirmi",
}

m["bmj"] = {
	canonicalName = "Bote-Majhi",
}

m["bmk"] = {
	canonicalName = "Ghayavi",
	family = "poz-ocw",
}

m["bml"] = {
	canonicalName = "Bomboli",
}

m["bmn"] = {
	canonicalName = "Bina",
	otherNames = {"Bina (New Guinea)", "Bina (Papua New Guinea)"},
	family = "poz-ocw",
}

m["bmo"] = {
	canonicalName = "Bambalang",
	family = "nic-bod",
}

m["bmp"] = {
	canonicalName = "Bulgebi",
	family = "ngf-fin",
}

m["bmq"] = {
	canonicalName = "Bomu",
}

m["bmr"] = {
	canonicalName = "Muinane",
}

m["bmt"] = {
	canonicalName = "Biao Mon",
	family = "hmx-mie",
}

m["bmu"] = {
	canonicalName = "Somba-Siawari",
}

m["bmv"] = {
	canonicalName = "Bum",
	family = "nic-bod",
}

m["bmw"] = {
	canonicalName = "Bomwali",
}

m["bmx"] = {
	canonicalName = "Baimak",
}

m["bmz"] = {
	canonicalName = "Baramu",
}

m["bna"] = {
	canonicalName = "Bonerate",
}

m["bnb"] = {
	canonicalName = "Bookan",
}

m["bnd"] = {
	canonicalName = "Banda",
	otherNames = {"Banda (Indonesia)"},
	family = "plf",
}

m["bne"] = {
	canonicalName = "Bintauna",
	family = "phi",
}

m["bnf"] = {
	canonicalName = "Masiwang",
	otherNames = {"Bonfia"},
	scripts = {"Latn"},
	family = "plf",
}

m["bng"] = {
	canonicalName = "Benga",
}

m["bni"] = {
	canonicalName = "Bangi",
	otherNames = {"Bobangi", "Bubangi"},
	scripts = {"Latn"},
	family = "bnt",
}

m["bnj"] = {
	canonicalName = "Eastern Tawbuid",
}

m["bnk"] = {
	canonicalName = "Bierebo",
	family = "poz-vnc",
}

m["bnl"] = {
	canonicalName = "Boon",
	family = "cus",
}

m["bnm"] = {
	canonicalName = "Batanga",
	scripts = {"Latn"},
	family = "bnt",
}

m["bnn"] = {
	canonicalName = "Bunun",
	scripts = {"Latn"},
	family = "map",
}

m["bno"] = {
	canonicalName = "Asi",
}

m["bnp"] = {
	canonicalName = "Bola",
	family = "poz-ocw",
}

m["bnq"] = {
	canonicalName = "Bantik",
}

m["bnr"] = {
	canonicalName = "Butmas-Tur",
	family = "poz-vnc",
}

m["bns"] = {
	canonicalName = "Bundeli",
	otherNames = {"Bundelkhandi"},
	scripts = {"Deva"},
	family = "inc",
	ancestors = {"psu"},
}

m["bnu"] = {
	canonicalName = "Bentong",
}

m["bnv"] = {
	canonicalName = "Beneraf",
}

m["bnw"] = {
	canonicalName = "Bisis",
}

m["bnx"] = {
	canonicalName = "Bangubangu",
}

m["bny"] = {
	canonicalName = "Bintulu",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["bnz"] = {
	canonicalName = "Beezen",
}

m["boa"] = {
	canonicalName = "Bora",
}

m["bob"] = {
	canonicalName = "Aweer",
	family = "cus",
}

m["boe"] = {
	canonicalName = "Mundabli",
	family = "nic-bod",
}

m["bof"] = {
	canonicalName = "Bolon",
}

m["bog"] = {
	canonicalName = "Bamako Sign Language",
	family = "sgn",
}

m["boh"] = {
	canonicalName = "Boma",
}

m["boi"] = {
	canonicalName = "Barbareño",
	family = "nai-chu",
}

m["boj"] = {
	canonicalName = "Anjam",
}

m["bok"] = {
	canonicalName = "Bonjo",
	family = "alv",
}

m["bol"] = {
	canonicalName = "Bole",
	family = "cdc",
}

m["bom"] = {
	canonicalName = "Berom",
	otherNames = {"Birom"},
	scripts = {"Latn"},
	family = "alv",
}

m["bon"] = {
	canonicalName = "Bine",
}

m["boo"] = {
	canonicalName = "Tiemacèwè Bozo",
}

m["bop"] = {
	canonicalName = "Bonkiman",
	family = "ngf-fin",
}

m["boq"] = {
	canonicalName = "Bogaya",
}

m["bor"] = {
	canonicalName = "Borôro",
	scripts = {"Latn"},
}

m["bot"] = {
	canonicalName = "Bongo",
}

m["bou"] = {
	canonicalName = "Bondei",
	otherNames = {"Boondei", "Boondéi"},
	scripts = {"Latn"},
	family = "bnt",
}

m["bov"] = {
	canonicalName = "Tuwuli",
}

m["bow"] = {
	canonicalName = "Rema",
}

m["box"] = {
	canonicalName = "Buamu",
}

m["boy"] = {
	canonicalName = "Bodo (Central Africa)",
	otherNames = {"Bodo (Central African Republic)", "Bodo"},
}

m["boz"] = {
	canonicalName = "Tiéyaxo Bozo",
}

m["bpa"] = {
	canonicalName = "Dakaka",
}

m["bpb"] = {
	canonicalName = "Barbacoas",
}

m["bpd"] = {
	canonicalName = "Banda-Banda",
}

m["bpg"] = {
	canonicalName = "Bonggo",
	family = "poz-ocw",
}

m["bph"] = {
	canonicalName = "Botlikh",
	otherNames = {"Botlix"},
	scripts = {"Cyrl"},
	family = "cau-ava",
}

m["bpi"] = {
	canonicalName = "Bagupi",
}

m["bpj"] = {
	canonicalName = "Binji",
}

m["bpk"] = {
	canonicalName = "Orowe",
	family = "poz-cln",
}

m["bpl"] = {
	canonicalName = "Broome Pearling Lugger Pidgin",
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"ms"},
}

m["bpm"] = {
	canonicalName = "Biyom",
}

m["bpn"] = {
	canonicalName = "Dzao Min",
	family = "hmx-mie",
}

m["bpo"] = {
	canonicalName = "Anasi",
}

m["bpp"] = {
	canonicalName = "Kaure",
}

m["bpq"] = {
	canonicalName = "Banda Malay",
}

m["bpr"] = {
	canonicalName = "Koronadal Blaan",
}

m["bps"] = {
	canonicalName = "Sarangani Blaan",
}

m["bpt"] = {
	canonicalName = "Barrow Point",
}

m["bpu"] = {
	canonicalName = "Bongu",
}

m["bpv"] = {
	canonicalName = "Bian Marind",
}

m["bpx"] = {
	canonicalName = "Palya Bareli",
}

m["bpy"] = {
	canonicalName = "Bishnupriya Manipuri",
	otherNames = {"Bishnupriya", "Manipuri Bishnupriya"},
	scripts = {"Beng"},
	family = "inc",
	ancestors = {"pka"},
}

m["bpz"] = {
	canonicalName = "Bilba",
	scripts = {"Latn"},
	family = "plf",
}

m["bqa"] = {
	canonicalName = "Tchumbuli",
}

m["bqb"] = {
	canonicalName = "Bagusa",
}

m["bqc"] = {
	canonicalName = "Boko",
	otherNames = {"Boko (Benin)"},
}

m["bqd"] = {
	canonicalName = "Bung",
}

m["bqf"] = {
	canonicalName = "Baga Kaloum",
}

m["bqg"] = {
	canonicalName = "Bago-Kusuntu",
}

m["bqh"] = {
	canonicalName = "Baima",
}

m["bqi"] = {
	canonicalName = "Bakhtiari",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["bqj"] = {
	canonicalName = "Bandial",
}

m["bqk"] = {
	canonicalName = "Banda-Mbrès",
}

m["bql"] = {
	canonicalName = "Bilakura",
}

m["bqm"] = {
	canonicalName = "Wumboko",
}

m["bqn"] = {
	canonicalName = "Bulgarian Sign Language",
	family = "sgn",
}

m["bqo"] = {
	canonicalName = "Balo",
	family = "nic-bod",
}

m["bqp"] = {
	canonicalName = "Busa",
}

m["bqq"] = {
	canonicalName = "Biritai",
}

m["bqr"] = {
	canonicalName = "Burusu",
}

m["bqs"] = {
	canonicalName = "Bosngun",
	family = "paa",
}

m["bqt"] = {
	canonicalName = "Bamukumbit",
	family = "nic-bod",
}

m["bqu"] = {
	canonicalName = "Boguru",
}

m["bqv"] = {
	canonicalName = "Begbere-Ejar",
}

m["bqw"] = {
	canonicalName = "Buru (Nigeria)",
	otherNames = {"Buru"},
	family = "nic-bod",
}

m["bqx"] = {
	canonicalName = "Baangi",
}

m["bqy"] = {
	canonicalName = "Bengkala Sign Language",
	family = "sgn",
}

m["bqz"] = {
	canonicalName = "Bakaka",
}

m["bra"] = {
	canonicalName = "Braj",
	otherNames = {"Brij Bhasha", "Braj Bhasha", "Braj Bhakha", "Dehaati Zabaan"},
	scripts = {"Deva", "Guru"},
	family = "inc",
}

m["brb"] = {
	canonicalName = "Lave",
}

m["brc"] = {
	canonicalName = "Berbice Creole Dutch",
	otherNames = {"Berbice Dutch", "Berbice Dutch Creole", "Berbice Creole"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"nl"},
}

m["brd"] = {
	canonicalName = "Baraamu",
}

m["brf"] = {
	canonicalName = "Bera",
}

m["brg"] = {
	canonicalName = "Baure",
	otherNames = {"Bauré"},
	scripts = {"Latn"},
	family = "awd",
}

m["brh"] = {
	canonicalName = "Brahui",
	scripts = {"Arab", "Latn"},
	family = "dra",
}

m["bri"] = {
	canonicalName = "Mokpwe",
	scripts = {"Latn"},
	family = "bnt",
}

m["brj"] = {
	canonicalName = "Bieria",
	family = "poz-vnc",
}

m["brk"] = {
	canonicalName = "Birgid",
	otherNames = {"Birked"},
	scripts = {"Latn"},
	family = "nub",
}

m["brl"] = {
	canonicalName = "Birwa",
}

m["brm"] = {
	canonicalName = "Barambu",
	family = "znd",
}

m["brn"] = {
	canonicalName = "Boruca",
}

m["bro"] = {
	canonicalName = "Brokkat",
}

m["brp"] = {
	canonicalName = "Barapasi",
}

m["brq"] = {
	canonicalName = "Breri",
	family = "paa",
}

m["brr"] = {
	canonicalName = "Birao",
	family = "poz-sls",
}

m["brs"] = {
	canonicalName = "Baras",
	otherNames = {"Ende", "West Kaili"},
}

m["brt"] = {
	canonicalName = "Bitare",
	otherNames = {"Njwande"},
	family = "nic-bod",
}

m["bru"] = {
	canonicalName = "Eastern Bru",
	family = "mkh",
}

m["brv"] = {
	canonicalName = "Western Bru",
	family = "mkh",
}

m["brw"] = {
	canonicalName = "Bellari",
	family = "dra",
}

m["brx"] = {
	canonicalName = "Bodo (India)",
	otherNames = {"Bodo", "Mech"},
	scripts = {"Deva", "Latn"},
	family = "tbq",
}

m["bry"] = {
	canonicalName = "Burui",
}

m["brz"] = {
	canonicalName = "Bilbil",
	family = "poz-ocw",
}

m["bsa"] = {
	canonicalName = "Abinomn",
}

m["bsb"] = {
	canonicalName = "Brunei Bisaya",
}

m["bsc"] = {
	canonicalName = "Bassari",
}

m["bse"] = {
	canonicalName = "Wushi",
}

m["bsf"] = {
	canonicalName = "Bauchi",
	family = "nic-knj",
}

m["bsg"] = {
	canonicalName = "Bashkardi",
	family = "ira",
}

m["bsh"] = {
	canonicalName = "Kati",
	family = "iir-nur",
}

m["bsi"] = {
	canonicalName = "Bassossi",
}

m["bsj"] = {
	canonicalName = "Bangwinji",
}

m["bsk"] = {
	canonicalName = "Burushaski",
	family = "qfa-iso",
}

m["bsl"] = {
	canonicalName = "Basa-Gumna",
	family = "nic-knj",
}

m["bsm"] = {
	canonicalName = "Busami",
	family = "poz-hce",
}

m["bsn"] = {
	canonicalName = "Barasana",
	family = "sai-tuc",
}

m["bso"] = {
	canonicalName = "Buso",
}

m["bsp"] = {
	canonicalName = "Baga Sitemu",
}

m["bsq"] = {
	canonicalName = "Bassa",
	scripts = {"Latn", "Bass"},
	family = "kro",
}

m["bsr"] = {
	canonicalName = "Bassa-Kontagora",
}

m["bss"] = {
	canonicalName = "Akoose",
}

m["bst"] = {
	canonicalName = "Basketo",
	otherNames = {"Basketto", "Baskatta", "Mesketo", "Misketto"},
}

m["bsu"] = {
	canonicalName = "Bahonsuai",
}

m["bsv"] = {
	canonicalName = "Baga Sobané",
}

m["bsw"] = {
	canonicalName = "Baiso",
	family = "cus",
}

m["bsx"] = {
	canonicalName = "Yangkam",
	family = "nic-bod",
}

m["bsy"] = {
	canonicalName = "Sabah Bisaya",
}

m["bta"] = {
	canonicalName = "Bata",
}

m["btc"] = {
	canonicalName = "Bati (Cameroon)",
	otherNames = {"Bati"},
	family = "nic-bco",
}

m["btd"] = {
	canonicalName = "Dairi Batak",
	otherNames = {"Batak Dairi"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["bte"] = {
	canonicalName = "Gamo-Ningi",
	family = "nic-knj",
}

m["btf"] = {
	canonicalName = "Birgit",
}

m["btg"] = {
	canonicalName = "Gagnoa Bété",
}

m["bth"] = {
	canonicalName = "Biatah Bidayuh",
}

m["bti"] = {
	canonicalName = "Burate",
}

m["btj"] = {
	canonicalName = "Bacanese Malay",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["btm"] = {
	canonicalName = "Mandailing Batak",
	otherNames = {"Batak Mandailing"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["btn"] = {
	canonicalName = "Ratagnon",
}

m["bto"] = {
	canonicalName = "Iriga Bicolano",
}

m["btp"] = {
	canonicalName = "Budibud",
	family = "poz-ocw",
}

m["btq"] = {
	canonicalName = "Batek",
}

m["btr"] = {
	canonicalName = "Baetora",
}

m["bts"] = {
	canonicalName = "Simalungun Batak",
	otherNames = {"Batak Simalungun"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["btt"] = {
	canonicalName = "Bete-Bendi",
	family = "nic-bco",
}

m["btu"] = {
	canonicalName = "Batu",
	family = "nic-bod",
}

m["btv"] = {
	canonicalName = "Bateri",
}

m["btw"] = {
	canonicalName = "Butuanon",
}

m["btx"] = {
	canonicalName = "Karo Batak",
	otherNames = {"Batak Karo"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["bty"] = {
	canonicalName = "Bobot",
	family = "plf",
}

m["btz"] = {
	canonicalName = "Alas-Kluet Batak",
	otherNames = {"Batak Alas-Kluet"},
	scripts = {"Latn", "Batk"},
	family = "btk",
}

m["bua"] = {
	canonicalName = "Buryat",
	otherNames = {"Buriat"},
	scripts = {"Cyrl"},
	family = "xgn",
	translit_module = "bua-translit",
	wikimedia_codes = {"bxr"},
}

m["bub"] = {
	canonicalName = "Bua",
}

m["bud"] = {
	canonicalName = "Ntcham",
}

m["bue"] = {
	canonicalName = "Beothuk",
}

m["buf"] = {
	canonicalName = "Bushoong",
}

m["bug"] = {
	canonicalName = "Buginese",
	scripts = {"Bugi", "Latn"},
	family = "poz-ssw",
}

m["buh"] = {
	canonicalName = "Younuo Bunu",
	otherNames = {"Yuno"},
	family = "hmn",
}

m["bui"] = {
	canonicalName = "Bongili",
}

m["buj"] = {
	canonicalName = "Basa-Gurmana",
	family = "nic-knj",
}

m["buk"] = {
	canonicalName = "Bukawa",
	otherNames = {"Bukaua", "Bugawac"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["bum"] = {
	canonicalName = "Bulu (Cameroon)",
	otherNames = {"Bulu"},
	scripts = {"Latn"},
	family = "bnt",
}

m["bun"] = {
	canonicalName = "Sherbro",
}

m["buo"] = {
	canonicalName = "Terei",
}

m["bup"] = {
	canonicalName = "Busoa",
}

m["buq"] = {
	canonicalName = "Brem",
}

m["bus"] = {
	canonicalName = "Bokobaru",
}

m["but"] = {
	canonicalName = "Bungain",
	family = "qfa-tor",
}

m["buu"] = {
	canonicalName = "Budu",
}

m["buv"] = {
	canonicalName = "Bun",
}

m["buw"] = {
	canonicalName = "Bubi",
}

m["bux"] = {
	canonicalName = "Boghom",
}

m["buy"] = {
	canonicalName = "Mmani",
	otherNames = {"Mani", "Bullom So", "Mandingi"},
}

m["bva"] = {
	canonicalName = "Barein",
}

m["bvb"] = {
	canonicalName = "Bube",
	scripts = {"Latn"},
	family = "bnt",
}

m["bvc"] = {
	canonicalName = "Baelelea",
	family = "poz-sls",
}

m["bvd"] = {
	canonicalName = "Baeggu",
	otherNames = {"Mbaenggu", "Baegu"},
	family = "poz-sls",
}

m["bve"] = {
	canonicalName = "Berau Malay",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["bvf"] = {
	canonicalName = "Boor",
}

m["bvg"] = {
	canonicalName = "Bonkeng",
}

m["bvh"] = {
	canonicalName = "Bure",
	family = "cdc",
}

m["bvi"] = {
	canonicalName = "Belanda Viri",
}

m["bvj"] = {
	canonicalName = "Baan",
	family = "nic-bco",
}

m["bvk"] = {
	canonicalName = "Bukat",
}

m["bvl"] = {
	canonicalName = "Bolivian Sign Language",
	family = "sgn",
}

m["bvm"] = {
	canonicalName = "Bamunka",
}

m["bvn"] = {
	canonicalName = "Buna",
	family = "qfa-tor",
}

m["bvo"] = {
	canonicalName = "Bolgo",
}

m["bvp"] = {
	canonicalName = "Bumang",
}

m["bvq"] = {
	canonicalName = "Birri",
}

m["bvr"] = {
	canonicalName = "Burarra",
	family = "aus-arn",
}

m["bvt"] = {
	canonicalName = "Bati (Indonesia)",
	otherNames = {"Bati"},
	family = "poz",
}

m["bvu"] = {
	canonicalName = "Bukit Malay",
}

m["bvv"] = {
	canonicalName = "Baniva",
	family = "awd",
}

m["bvw"] = {
	canonicalName = "Boga",
}

m["bvx"] = {
	canonicalName = "Babole",
	otherNames = {"Dibole", "Bole"},
	scripts = {"Latn"},
	family = "bnt",
}

m["bvy"] = {
	canonicalName = "Baybayanon",
}

m["bvz"] = {
	canonicalName = "Bauzi",
}

m["bwa"] = {
	canonicalName = "Bwatoo",
	family = "poz-cln",
}

m["bwb"] = {
	canonicalName = "Namosi-Naitasiri-Serua",
	family = "poz-occ",
}

m["bwc"] = {
	canonicalName = "Bwile",
}

m["bwd"] = {
	canonicalName = "Bwaidoka",
	family = "poz-ocw",
}

m["bwe"] = {
	canonicalName = "Bwe Karen",
}

m["bwf"] = {
	canonicalName = "Boselewa",
	family = "poz-ocw",
}

m["bwg"] = {
	canonicalName = "Barwe",
}

m["bwh"] = {
	canonicalName = "Bishuo",
	family = "nic-bod",
}

m["bwi"] = {
	canonicalName = "Baniwa",
	otherNames = {"Baniba", "Baniva", "Carutana", "Carútana", "Carúzana", "Izaneni", "Karu", "Tapuya"},
	family = "awd",
}

m["bwj"] = {
	canonicalName = "Láá Láá Bwamu",
}

m["bwk"] = {
	canonicalName = "Bauwaki",
	family = "ngf",
}

m["bwl"] = {
	canonicalName = "Bwela",
	family = "bnt",
}

m["bwm"] = {
	canonicalName = "Biwat",
	otherNames = {"Mundugumor"},
}

m["bwn"] = {
	canonicalName = "Wunai Bunu",
	otherNames = {"Hm Nai", "Ng-nai", "Wunai"},
	family = "hmn",
}

m["bwo"] = {
	canonicalName = "Shinasha",
	otherNames = {"Boro", "Boro (Ethiopia)", "Borna", "Bworo", "Sinicho"},
}

m["bwp"] = {
	canonicalName = "Mandobo Bawah",
}

m["bwq"] = {
	canonicalName = "Southern Bobo",
	otherNames = {"Bobo Madaré", "Southern Bobo Madaré", "Bobo"},
}

m["bwr"] = {
	canonicalName = "Bura",
	otherNames = {"Bura-Pabir", "Pabir", "Burra"},
	scripts = {"Latn"},
	family = "cdc",
}

m["bws"] = {
	canonicalName = "Bomboma",
	family = "bnt",
}

m["bwt"] = {
	canonicalName = "Bafaw-Balong",
}

m["bwu"] = {
	canonicalName = "Buli (Ghana)",
	otherNames = {"Buli"},
	family = "nic-gur",
}

m["bww"] = {
	canonicalName = "Bwa",
}

m["bwx"] = {
	canonicalName = "Bu-Nao Bunu",
	family = "hmn",
}

m["bwy"] = {
	canonicalName = "Cwi Bwamu",
	family = "nic-gur",
}

m["bwz"] = {
	canonicalName = "Bwisi",
}

m["bxa"] = {
	canonicalName = "Bauro",
	otherNames = {"Tairaha"},
	family = "poz-sls",
}

m["bxb"] = {
	canonicalName = "Belanda Bor",
	family = "sdv",
}

m["bxc"] = {
	canonicalName = "Molengue",
}

m["bxd"] = {
	canonicalName = "Pela",
}

m["bxe"] = {
	canonicalName = "Ongota",
	otherNames = {"Birale", "Birayle"},
	family = "cus",
}

m["bxf"] = {
	canonicalName = "Bilur",
	family = "poz-ocw",
}

m["bxg"] = {
	canonicalName = "Bangala",
	otherNames = {"Ngala"},
	scripts = {"Latn"},
	family = "bnt",
}

m["bxh"] = {
	canonicalName = "Buhutu",
	family = "poz-ocw",
}

m["bxi"] = {
	canonicalName = "Pirlatapa",
	family = "aus-kar",
}

m["bxj"] = {
	canonicalName = "Bayungu",
	family = "aus-psw",
}

m["bxk"] = {
	canonicalName = "Bukusu",
}

m["bxl"] = {
	canonicalName = "Jalkunan",
}

m["bxn"] = {
	canonicalName = "Burduna",
	family = "aus-psw",
}

m["bxo"] = {
	canonicalName = "Barikanchi",
	otherNames = {"Barikanci", "Barikanchi Pidgin"},
}

m["bxp"] = {
	canonicalName = "Bebil",
}

m["bxq"] = {
	canonicalName = "Beele",
	family = "cdc",
}

m["bxs"] = {
	canonicalName = "Busam",
}

m["bxv"] = {
	canonicalName = "Berakou",
}

m["bxw"] = {
	canonicalName = "Banka",
	otherNames = {"Bankagooma"},
}

m["bxz"] = {
	canonicalName = "Binahari",
}

m["bya"] = {
	canonicalName = "Palawan Batak",
	otherNames = {"Batak"},
	scripts = {"Tagb"},
	family = "phi",
}

m["byb"] = {
	canonicalName = "Bikya",
	family = "nic-bod",
	scripts = {"Latn"},
}

m["byc"] = {
	canonicalName = "Ubaghara",
	family = "nic-bco",
}

m["byd"] = {
	canonicalName = "Benyadu'",
}

m["bye"] = {
	canonicalName = "Pouye",
}

m["byf"] = {
	canonicalName = "Bete",
}

m["byg"] = {
	canonicalName = "Baygo",
	family = "sdv",
}

m["byh"] = {
	canonicalName = "Bujhyal",
}

m["byi"] = {
	canonicalName = "Buyu",
	otherNames = {"Buya"},
}

m["byj"] = {
	canonicalName = "Binawa",
	otherNames = {"Bina", "Bina (Nigeria)"},
	scripts = {"Latn"},
}

m["byk"] = {
	canonicalName = "Biao",
}

m["byl"] = {
	canonicalName = "Bayono",
}

m["bym"] = {
	canonicalName = "Bidyara",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["byn"] = {
	canonicalName = "Blin",
	otherNames = {"Bilin", "Bilen", "Belen", "Bilein"},
	scripts = {"Ethi", "Latn"},
	family = "cus",
	translit_module = "Ethi-translit",
}

m["byo"] = {
	canonicalName = "Biyo",
	otherNames = {"Piyo", "Biyue"},
	family = "tbq-lol",
}

m["byp"] = {
	canonicalName = "Bumaji",
	family = "nic-bco",
	scripts = {"Latn"},
}

m["byq"] = {
	canonicalName = "Basay",
	otherNames = {"Basai"},
	family = "map",
	scripts = {"Latn"},
}

m["byr"] = {
	canonicalName = "Baruya",
}

m["bys"] = {
	canonicalName = "Burak",
}

m["byt"] = {
	canonicalName = "Berti",
}

m["byv"] = {
	canonicalName = "Medumba",
	family = "bai",
}

m["byw"] = {
	canonicalName = "Belhariya",
}

m["byx"] = {
	canonicalName = "Qaqet",
}

m["byz"] = {
	canonicalName = "Banaro",
	family = "paa",
}

m["bza"] = {
	canonicalName = "Bandi",
}

m["bzb"] = {
	canonicalName = "Andio",
}

m["bzd"] = {
	canonicalName = "Bribri",
	family = "cba",
	scripts = {"Latn"},
}

m["bze"] = {
	canonicalName = "Jenaama Bozo",
}

m["bzf"] = {
	canonicalName = "Boikin",
}

m["bzg"] = {
	canonicalName = "Babuza",
	otherNames = {"Favorlang", "Poavosa", "Taokas"},
	family = "map",
}

m["bzh"] = {
	canonicalName = "Mapos Buang",
	family = "poz-ocw",
}

m["bzi"] = {
	canonicalName = "Bisu",
	family = "tbq-lol",
}

m["bzj"] = {
	canonicalName = "Belizean Creole",
	otherNames = {"Belizean Creole English", "Belizean Kriol", "Belize Kriol English", "Kriol"},
	scripts = {"Latn"},
}

m["bzk"] = {
	canonicalName = "Nicaraguan Creole",
	otherNames = {"Nicaraguan Creole English", "Nicaragua Creole English"},
	scripts = {"Latn"},
}

m["bzl"] = {  -- supposedly also called "Bolano", but I can find no evidence of that
	canonicalName = "Boano (Sulawesi)",
	otherNames = {"Boano", "Austronesian Boano", "Totoli Boano"},
	family = "poz",
	scripts = {"Latn"},
}

m["bzm"] = {
	canonicalName = "Bolondo",
	family = "bnt",
	scripts = {"Latn"},
}

m["bzn"] = {
	canonicalName = "Boano (Maluku)",
	otherNames = {"Boano", "Austronesian Boano", "Seram Boano"},
	family = "poz",
	scripts = {"Latn"},
}

m["bzo"] = {
	canonicalName = "Bozaba",
	family = "bnt",
	scripts = {"Latn"},
}

m["bzp"] = {
	canonicalName = "Kemberano",
	family = "ngf-sbh",
	scripts = {"Latn"},
}

m["bzq"] = {
	canonicalName = "Buli (Indonesia)",
	otherNames = {"Buli"},
	family = "poz-hce",
	scripts = {"Latn"},
}

m["bzr"] = {
	canonicalName = "Biri",
	family = "aus-pam",
	scripts = {"Latn"},
}

m["bzs"] = {
	canonicalName = "Brazilian Sign Language",
	otherNames = {"LGB", "LSB", "LSCB", "Libras"},
	family = "sgn",
}

m["bzu"] = {
	canonicalName = "Burmeso",
	scripts = {"Latn"},
}

m["bzv"] = {
	canonicalName = "Bebe",
	otherNames = {"Naami"},
	family = "nic-bod",
	scripts = {"Latn"},
}

m["bzw"] = {
	canonicalName = "Basa",
	otherNames = {"Basa (Nigeria)", "Basa-Benue"},
	family = "nic-knj",
	scripts = {"Latn"},
}

m["bzx"] = {
	canonicalName = "Hainyaxo Bozo",
	family = "dmn",
	scripts = {"Latn"},
}

m["bzy"] = {
	canonicalName = "Obanliku",
	family = "nic-bco",
	scripts = {"Latn"},
}

m["bzz"] = {
	canonicalName = "Evant",
	family = "nic-bod",
	scripts = {"Latn"},
}

return m