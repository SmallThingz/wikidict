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

m["kaa"] = {
	canonicalName = "Karakalpak",
	scripts = {"Latn", "Cyrl"},
	family = "trk",
}

m["kab"] = {
	canonicalName = "Kabyle",
	scripts = {"Latn"},
	family = "ber",
}

m["kac"] = {
	canonicalName = "Jingpho",
	scripts = {"Latn"},
	family = "tbq",
}

m["kad"] = {
	canonicalName = "Kadara",
}

m["kae"] = {
	canonicalName = "Ketangalan",
	family = "map",
}

m["kaf"] = {
	canonicalName = "Katso",
	otherNames = {"Kazhuo"},
	family = "tbq-lol",
}

m["kag"] = {
	canonicalName = "Kajaman",
	family = "poz",
}

m["kah"] = {
	canonicalName = "Fer",
	otherNames = {"Kara"},
}

m["kai"] = {
	canonicalName = "Karekare",
	family = "cdc",
}

m["kaj"] = {
	canonicalName = "Jju",
}

m["kak"] = {
	canonicalName = "Kayapa Kallahan",
}

m["kam"] = {
	canonicalName = "Kamba",
	otherNames = {"Kikamba", "Kamba (Kenya)"},
	scripts = {"Latn"},
	family = "bnt",
}

m["kao"] = {
	canonicalName = "Kassonke",
	otherNames = {"Khasonke", "Kasonke", "Khassonké"},
	scripts = {"Latn"},
	family = "dmn",
}

m["kap"] = {
	canonicalName = "Bezhta",
	otherNames = {"Bezheta", "Kapucha", "Bezhita"},
	scripts = {"Cyrl"},
	family = "cau-tsz",
}

m["kaq"] = {
	canonicalName = "Capanahua",
	otherNames = {"Kapanawa"},
	scripts = {"Latn"},
	family = "sai-pan",
}

m["kaw"] = {
	canonicalName = "Old Javanese",
	otherNames = {"Kawi"},
	scripts = {"Latn", "Java"},
	family = "poz-sus",
}

m["kax"] = {
	canonicalName = "Kao",
}

m["kay"] = {
	canonicalName = "Kamayurá",
}

m["kba"] = {
	canonicalName = "Kalarko",
}

m["kbb"] = {
	canonicalName = "Kaxuyana",
	otherNames = {"Kachuyana", "Kaxuiana", "Kaxuiâna", "Kashuyana"},
	family = "sai-car",
}

m["kbc"] = {
	canonicalName = "Kadiwéu",
	otherNames = {"Caduveo", "Ediu-Adig", "Guaicurú", "Kadiweu", "Mbayá", "Mbayá-Guaycuru", "Waikurú"},
	scripts = {"Latn"},
	family = "sai-mgc",
}

m["kbd"] = {
	canonicalName = "Kabardian",
	otherNames = {"East Circassian"},
	scripts = {"Cyrl"},
	family = "cau-cir",
	translit_module = "kbd-translit",
}

m["kbe"] = {
	canonicalName = "Kanju",
}

m["kbh"] = {
	canonicalName = "Camsá",
	family = "qfa-iso",
}

m["kbi"] = {
	canonicalName = "Kaptiau",
}

m["kbj"] = {
	canonicalName = "Kari",
	otherNames = {"Kare", "Kare (Central African Republic)", "Bantoid Kare"},
}

m["kbk"] = {
	canonicalName = "Grass Koiari",
	otherNames = {"Koiari"},
}

m["kbm"] = {
	canonicalName = "Iwal",
	family = "poz-ocw",
}

m["kbn"] = {
	canonicalName = "Kare (Africa)",
	otherNames = {"Kare (Central African Republic)", "Mbum Kare"},
}

m["kbo"] = {
	canonicalName = "Keliko",
}

m["kbp"] = {
	canonicalName = "Kabiyé",
}

m["kbq"] = {
	canonicalName = "Kamano",
}

m["kbr"] = {
	canonicalName = "Kafa",
}

m["kbs"] = {
	canonicalName = "Kande",
}

m["kbt"] = {
	canonicalName = "Gabadi",
	family = "poz-ocw",
}

m["kbu"] = {
	canonicalName = "Kabutra",
	family = "inc",
	ancestors = {"psu"},
}

m["kbv"] = {
	canonicalName = "Kamberataro",
	otherNames = {"Dera", "Dera (New Guinea)"},
	family = "paa",
}

m["kbw"] = {
	canonicalName = "Kaiep",
	family = "poz-ocw",
}

m["kbx"] = {
	canonicalName = "Ap Ma",
}

m["kbz"] = {
	canonicalName = "Duhwa",
}

m["kca"] = {
	canonicalName = "Khanty",
	scripts = {"Cyrl"},
	family = "fiu-ugr",
	translit_module = "kca-translit",
}

m["kcb"] = {
	canonicalName = "Kawacha",
}

m["kcc"] = {
	canonicalName = "Lubila",
	family = "nic-bco",
}

m["kcd"] = {
	canonicalName = "Ngkâlmpw Kanum",
}

m["kce"] = {
	canonicalName = "Kaivi",
}

m["kcf"] = {
	canonicalName = "Ukaan",
}

m["kcg"] = {
	canonicalName = "Tyap",
}

m["kch"] = {
	canonicalName = "Vono",
}

m["kci"] = {
	canonicalName = "Kamantan",
}

m["kcj"] = {
	canonicalName = "Kobiana",
}

m["kck"] = {
	canonicalName = "Kalanga",
	scripts = {"Latn"},
	family = "bnt",
}

m["kcl"] = {
	canonicalName = "Kala",
	otherNames = {"Kela", "Gela"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["kcm"] = {
	canonicalName = "Tar Gula",
}

m["kcn"] = {
	canonicalName = "Nubi",
	otherNames = {"Ki-Nubi"},
	scripts = {"Arab"},
	family = "crp",
	ancestors = {"apd"},
}

m["kco"] = {
	canonicalName = "Kinalakna",
}

m["kcp"] = {
	canonicalName = "Kanga",
	scripts = {"Latn"},
	family = "qfa-kad",
}

m["kcq"] = {
	canonicalName = "Kamo",
}

m["kcr"] = {
	canonicalName = "Katla",
}

m["kcs"] = {
	canonicalName = "Koenoem",
}

m["kct"] = {
	canonicalName = "Kaian",
}

m["kcu"] = {
	canonicalName = "Kikami",
	otherNames = {"Kami"},
}

m["kcv"] = {
	canonicalName = "Kete",
}

m["kcw"] = {
	canonicalName = "Kabwari",
}

m["kcx"] = {
	canonicalName = "Kachama-Ganjule",
}

m["kcy"] = {
	canonicalName = "Korandje",
}

m["kcz"] = {
	canonicalName = "Konongo",
	family = "bnt",
}

m["kda"] = {
	canonicalName = "Worimi",
	otherNames = {"Gadang", "Gadhang", "Gadjang", "Kattang", "Kutthung"},
	scripts = {"Latn"},
	family = "aus-pam",
}

m["kdc"] = {
	canonicalName = "Kutu",
}

m["kdd"] = {
	canonicalName = "Yankunytjatjara",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["kde"] = {
	canonicalName = "Makonde",
	scripts = {"Latn"},
	family = "bnt",
}

m["kdf"] = {
	canonicalName = "Mamusi",
	family = "poz-ocw",
}

m["kdg"] = {
	canonicalName = "Seba",
	family = "bnt",
}

m["kdh"] = {
	canonicalName = "Tem",
}

m["kdi"] = {
	canonicalName = "Kumam",
	otherNames = {"Kuman"},
	family = "sdv",
}

m["kdj"] = {
	canonicalName = "Karamojong",
	scripts = {"Latn"},
	family = "sdv",
}

m["kdk"] = {
	canonicalName = "Numee",
	family = "poz-cln",
}

m["kdl"] = {
	canonicalName = "Tsikimba",
}

m["kdm"] = {
	canonicalName = "Kagoma",
}

m["kdn"] = {
	canonicalName = "Kunda",
}

m["kdp"] = {
	canonicalName = "Kaningdon-Nindem",
}

m["kdq"] = {
	canonicalName = "Koch",
}

m["kdr"] = {
	canonicalName = "Karaim",
	scripts = {"Cyrl", "Latn", "Hebr"},
	family = "trk",
}

m["kdt"] = {
	canonicalName = "Kuy",
	family = "mkh",
}

m["kdu"] = {
	canonicalName = "Kadaru",
	otherNames = {"Kedaru", "Debri"}, -- Debri is subsumed for now as it lacks an ISO code, may need to be split
	scripts = {"Latn"},
	family = "nub",
}

m["kdv"] = {
	canonicalName = "Kado",
	otherNames = {"Kadu"},
	family = "sit",
}

m["kdw"] = {
	canonicalName = "Koneraw",
}

m["kdx"] = {
	canonicalName = "Kam",
}

m["kdy"] = {
	canonicalName = "Keder",
}

m["kdz"] = {
	canonicalName = "Kwaja",
	family = "nic-bod",
}

m["kea"] = {
	canonicalName = "Kabuverdianu",
	otherNames = {"Cape Verdean Creole", "Kriolu", "Creole", "Barlavento", "Sotavento"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"pt"},
}

m["keb"] = {
	canonicalName = "Kélé",
}

m["kec"] = {
	canonicalName = "Keiga",
	scripts = {"Latn"},
	family = "qfa-kad",
}

m["ked"] = {
	canonicalName = "Kerewe",
}

m["kee"] = {
	canonicalName = "Eastern Keres",
	family = "nai-ker",
}

m["kef"] = {
	canonicalName = "Kpessi",
}

m["keg"] = {
	canonicalName = "Tese",
	family = "sdv",
}

m["keh"] = {
	canonicalName = "Keak",
}

m["kei"] = {
	canonicalName = "Kei",
}

m["kej"] = {
	canonicalName = "Kadar",
	family = "dra",
}

m["kek"] = {
	canonicalName = "Q'eqchi",
	family = "myn",
}

m["kel"] = {
	canonicalName = "Kela",
	scripts = {"Latn"},
	family = "bnt",
}

m["kem"] = {
	canonicalName = "Kemak",
	family = "plf",
}

m["ken"] = {
	canonicalName = "Kenyang",
	family = "nic-bod",
}

m["keo"] = {
	canonicalName = "Kakwa",
	family = "sdv",
}

m["kep"] = {
	canonicalName = "Kaikadi",
	family = "dra",
}

m["keq"] = {
	canonicalName = "Kamar",
	family = "inc",
	ancestors = {"pka"},
}

m["ker"] = {
	canonicalName = "Kera",
}

m["kes"] = {
	canonicalName = "Kugbo",
	family = "nic-bco",
}

m["ket"] = {
	canonicalName = "Ket",
	scripts = {"Cyrl"},
	family = "qfa-yen",
}

m["keu"] = {
	canonicalName = "Akebu",
}

m["kev"] = {
	canonicalName = "Kanikkaran",
	family = "dra",
}

m["kew"] = {
	canonicalName = "West Kewa",
}

m["kex"] = {
	canonicalName = "Kukna",
}

m["key"] = {
	canonicalName = "Kupia",
}

m["kez"] = {
	canonicalName = "Kukele",
	family = "nic-bco",
}

m["kfa"] = {
	canonicalName = "Kodava",
	scripts = {"Knda"},
	family = "dra",
}

m["kfb"] = {
	canonicalName = "Northwestern Kolami",
	scripts = {"Deva"},
	family = "dra",
}

m["kfc"] = {
	canonicalName = "Konda-Dora",
	scripts = {"Telu"},
	family = "dra",
}

m["kfd"] = {
	canonicalName = "Korra Koraga",
	scripts = {"Knda"},
	family = "dra",
}

m["kfe"] = {
	canonicalName = "Kota",
	otherNames = {"Kota (India)"},
	scripts = {"Taml"},
	family = "dra",
}

m["kff"] = {
	canonicalName = "Koya",
	family = "dra",
}

m["kfg"] = {
	canonicalName = "Kudiya",
	family = "dra",
}

m["kfh"] = {
	canonicalName = "Kurichiya",
	family = "dra",
}

m["kfi"] = {
	canonicalName = "Kannada Kurumba",
	family = "dra",
}

m["kfj"] = {
	canonicalName = "Kemiehua",
	family = "mkh",
}

m["kfk"] = {
	canonicalName = "Kinnauri",
	family = "sit",
}

m["kfl"] = {
	canonicalName = "Kung",
	family = "nic-bod",
}

m["kfm"] = {
	canonicalName = "Khunsari",
	family = "ira",
}

m["kfn"] = {
	canonicalName = "Kuk",
	family = "nic-bod",
}

m["kfo"] = {
	canonicalName = "Koro (West Africa)",
	otherNames = {"Koro", "Koro Jula"}, -- the last name is misleading, as Jula is a diff. language
	scripts = {"Latn", "Nkoo"},
	family = "dmn",
}

m["kfp"] = {
	canonicalName = "Korwa",
	family = "mun",
}

m["kfq"] = {
	canonicalName = "Korku",
	family = "mun",
}

m["kfr"] = {
	canonicalName = "Kachchi",
	otherNames = {"Kutchi", "Cutchi", "Kachchhi", "Kutchhi"},
	scripts = {"Gujr"},
	family = "inc",
}

m["kfs"] = {
	canonicalName = "Bilaspuri",
	family = "inc",
}

m["kft"] = {
	canonicalName = "Kanjari",
	family = "inc",
}

m["kfu"] = {
	canonicalName = "Katkari",
	family = "inc",
	ancestors = {"pmh"},
}

m["kfv"] = {
	canonicalName = "Kurmukar",
	family = "inc",
	ancestors = {"pka"},
}

m["kfw"] = {
	canonicalName = "Kharam Naga",
	otherNames = {"Kharam"},
	family = "tbq-kuk",
}

m["kfx"] = {
	canonicalName = "Kullu Pahari",
	otherNames = {"Kullu"},
	scripts = {"Deva"},
	family = "inc",
}

m["kfy"] = {
	canonicalName = "Kumaoni",
	scripts = {"Deva", "Shrd", "Takr"},
	family = "inc",
}

m["kfz"] = {
	canonicalName = "Koromfé",
	family = "nic-gur",
}

m["kga"] = {
	canonicalName = "Koyaga",
}

m["kgb"] = {
	canonicalName = "Kawe",
	family = "poz-hce",
}

m["kgd"] = {
	canonicalName = "Kataang",
	family = "mkh",
}

m["kge"] = {
	canonicalName = "Komering",
}

m["kgf"] = {
	canonicalName = "Kube",
}

m["kgg"] = {
	canonicalName = "Kusunda",
	scripts = {"Latn"},
}

m["kgi"] = {
	canonicalName = "Selangor Sign Language",
	family = "sgn",
}

m["kgj"] = {
	canonicalName = "Gamale Kham",
}

m["kgk"] = {
	canonicalName = "Kaiwá",
}

m["kgl"] = {
	canonicalName = "Kunggari",
}

m["kgm"] = {
	canonicalName = "Karipúna",
}

m["kgn"] = {
	canonicalName = "Karingani",
	otherNames = {"Keringani"},
	family = "ira",
	ancestors = {"ira-azr"},
}

m["kgo"] = {
	canonicalName = "Krongo",
	scripts = {"Latn"},
	family = "qfa-kad",
}

m["kgp"] = {
	canonicalName = "Kaingang",
	scripts = {"Latn"},
	family = "sai-jee",
}

m["kgq"] = {
	canonicalName = "Kamoro",
}

m["kgr"] = {
	canonicalName = "Abun",
}

m["kgs"] = {
	canonicalName = "Kumbainggar",
}

m["kgt"] = {
	canonicalName = "Somyev",
	family = "nic-bod",
}

m["kgu"] = {
	canonicalName = "Kobol",
}

m["kgv"] = {
	canonicalName = "Karas",
}

m["kgw"] = {
	canonicalName = "Karon Dori",
}

m["kgx"] = {
	canonicalName = "Kamaru",
}

m["kgy"] = {
	canonicalName = "Kyerung",
}

m["kha"] = {
	canonicalName = "Khasi",
	family = "aav",
}

m["khb"] = {
	canonicalName = "Lü",
	otherNames = {"Tai Lü"},
	scripts = {"Talu", "Lana", "Thai"},
	family = "tai-swe",
	translit_module = "khb-translit",
	sort_key = {
		from = {"ᦦ", "ᦧ", "ᦨ", "ᦩ", "ᦪ", "ᦫ", "᧞", "᧟", "([ᦵᦶᦷᦺ])([ᦀ-ᦫ])"},
		to = {"ᦂᦞ", "ᦃᦞ", "ᦅᦞ", "ᦆᦞ", "ᦉᦞ", "ᦌᦞ", "ᦶᦜ", "ᦶᦜᧁ", "%2%1"}},
}

m["khc"] = {
	canonicalName = "Tukang Besi North",
}

m["khd"] = {
	canonicalName = "Bädi Kanum",
}

m["khe"] = {
	canonicalName = "Korowai",
}

m["khf"] = {
	canonicalName = "Khuen",
	family = "mkh",
}

m["khh"] = {
	canonicalName = "Kehu",
}

m["khj"] = {
	canonicalName = "Kuturmi",
}

m["khl"] = {
	canonicalName = "Lusi",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["khn"] = {
	canonicalName = "Khandesi",
	family = "inc",
}

m["kho"] = {
	canonicalName = "Khotanese",
	scripts = {"Brah"},
	family = "ira",
}

m["khp"] = {
	canonicalName = "Kapauri",
}

m["khq"] = {
	canonicalName = "Koyra Chiini",
	otherNames = {"Western Songhay", "Koyra Chiini Songhay"},
}

m["khr"] = {
	canonicalName = "Kharia",
	family = "mun",
}

m["khs"] = {
	canonicalName = "Kasua",
}

m["kht"] = {
	canonicalName = "Khamti",
}

m["khu"] = {
	canonicalName = "Nkhumbi",
}

m["khv"] = {
	canonicalName = "Khvarshi",
	otherNames = {"Khwarshi", "Xvarshi", "Inkhokvari"},
	scripts = {"Cyrl"},
	family = "cau-tsz",
}

m["khw"] = {
	canonicalName = "Khowar",
	scripts = {"Arab"},
	family = "inc-dar",
}

m["khy"] = {
	canonicalName = "Ekele",
	otherNames = {"Kele", "Kele (Congo)", "Kele (Democratic Republic of the Congo)", "Lokele"},
	family = "bnt",
}

m["khz"] = {
	canonicalName = "Keapara",
	family = "poz-ocw",
}

m["kia"] = {
	canonicalName = "Kim",
}

m["kib"] = {
	canonicalName = "Koalib",
}

m["kic"] = {
	canonicalName = "Kickapoo",
	scripts = {"Latn"},
	family = "alg",
}

m["kid"] = {
	canonicalName = "Koshin",
	scripts = {"Latn"},
	family = "nic-bod",
}

m["kie"] = {
	canonicalName = "Kibet",
}

m["kif"] = {
	canonicalName = "Eastern Parbate Kham",
}

m["kig"] = {
	canonicalName = "Kimaama",
}

m["kih"] = {
	canonicalName = "Kilmeri",
}

m["kii"] = {
	canonicalName = "Kitsai",
	otherNames = {"Kichai"},
	scripts = {"Latn"},
	family = "cdd",
}

m["kij"] = {
	canonicalName = "Kilivila",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["kil"] = {
	canonicalName = "Kariya",
}

m["kim"] = {
	canonicalName = "Tofa",
	otherNames = {"Tofalar", "Karagas"},
	scripts = {"Cyrl"},
	family = "trk",
}

m["kio"] = {
	canonicalName = "Kiowa",
	scripts = {"Latn"},
	family = "nai-kta",
}

m["kip"] = {
	canonicalName = "Sheshi Kham",
}

m["kiq"] = {
	canonicalName = "Kosadle",
}

m["kis"] = {
	canonicalName = "Kis",
	family = "poz-ocw",
}

m["kit"] = {
	canonicalName = "Agob",
}

m["kiv"] = {
	canonicalName = "Kimbu",
}

m["kiw"] = {
	canonicalName = "Northeast Kiwai",
}

m["kix"] = {
	canonicalName = "Khiamniungan Naga",
}

m["kiy"] = {
	canonicalName = "Kirikiri",
	otherNames = {"Faia"},
	family = "paa-lkp",
}

m["kiz"] = {
	canonicalName = "Kisi",
}

m["kja"] = {
	canonicalName = "Mlap",
}

m["kjb"] = {
	canonicalName = "Q'anjob'al",
	scripts = {"Latn"},
	family = "myn",
}

m["kjc"] = {
	canonicalName = "Coastal Konjo",
}

m["kjd"] = {
	canonicalName = "Southern Kiwai",
}

m["kje"] = {
	canonicalName = "Kisar",
}

m["kjf"] = {
	canonicalName = "Khalaj",
}

m["kjg"] = {
	canonicalName = "Khmu",
	scripts = {"Laoo"},
	family = "mkh",
}

m["kjh"] = {
	canonicalName = "Khakas",
	scripts = {"Cyrl"},
	family = "trk",
	translit_module = "kjh-translit",
}

m["kji"] = {
	canonicalName = "Zabana",
	family = "poz-ocw",
}

m["kjj"] = {
	canonicalName = "Khinalug",
	otherNames = {"Khinalig", "Xinalug", "Xinalugh", "Khinalugh"},
	scripts = {"Cyrl"},
	family = "cau-nec",
	translit_module = "kjj-translit",
	entry_name = {
		from = {ACUTE},
		to   = {}},
}

m["kjk"] = {
	canonicalName = "Highland Konjo",
}

m["kjl"] = {
	canonicalName = "Kham",
}

m["kjm"] = {
	canonicalName = "Kháng",
	family = "mkh",
}

m["kjn"] = {
	canonicalName = "Kunjen",
	otherNames = {"Uw Oykangand", "Uw Olkola", "Olkol"},
	scripts = {"Latn"},
}

m["kjo"] = {
	canonicalName = "Harijan Kinnauri",
}

m["kjp"] = {
	canonicalName = "Pwo Eastern Karen",
}

m["kjq"] = {
	canonicalName = "Western Keres",
	scripts = {"Latn"},
	family = "nai-ker",
}

m["kjr"] = {
	canonicalName = "Kurudu",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["kjs"] = {
	canonicalName = "East Kewa",
}

m["kjt"] = {
	canonicalName = "Phrae Pwo Karen",
}

m["kju"] = {
	canonicalName = "Kashaya",
	scripts = {"Latn"},
	family = "nai-pom",
}

m["kjx"] = {
	canonicalName = "Ramopa",
}

m["kjy"] = {
	canonicalName = "Erave",
}

m["kjz"] = {
	canonicalName = "Bumthangkha",
}

m["kka"] = {
	canonicalName = "Kakanda",
}

m["kkb"] = {
	canonicalName = "Kwerisa",
}

m["kkc"] = {
	canonicalName = "Odoodee",
}

m["kkd"] = {
	canonicalName = "Kinuku",
}

m["kke"] = {
	canonicalName = "Kakabe",
}

m["kkf"] = {
	canonicalName = "Kalaktang Monpa",
}

m["kkg"] = {
	canonicalName = "Mabaka Valley Kalinga",
}

m["kkh"] = {
	canonicalName = "Khün",
	otherNames = {"Tai Khün", "Dai Kun"},
	scripts = {"Lana", "Thai"},
	family = "tai-swe",
}

m["kki"] = {
	canonicalName = "Kagulu",
	otherNames = {"Kaguru"},
	family = "bnt",
}

m["kkj"] = {
	canonicalName = "Kako",
}

m["kkk"] = {
	canonicalName = "Kokota",
	family = "poz-ocw",
}

m["kkl"] = {
	canonicalName = "Kosarek Yale",
}

m["kkm"] = {
	canonicalName = "Kiong",
	family = "nic-bco",
}

m["kkn"] = {
	canonicalName = "Kon Keu",
	family = "aav",
}

m["kko"] = {
	canonicalName = "Karko",
	otherNames = {"Kithonirishe"},
	family = "nub",
}

m["kkp"] = {
	canonicalName = "Koko-Bera",
	otherNames = {"Kok-Kaper", "Gugubera", "Koko-Pera"},
	scripts = {"Latn"},
	family = "aus-pmn",
}

m["kkq"] = {
	canonicalName = "Kaiku",
	family = "bnt",
}

m["kkr"] = {
	canonicalName = "Kir-Balar",
	otherNames = {"Kir"},
	scripts = {"Latn"},
	family = "cdc",
}

m["kks"] = {
	canonicalName = "Kirfi",
	otherNames = {"Giiwo"},
	scripts = {"Latn"},
	family = "cdc",
}

m["kkt"] = {
	canonicalName = "Koi",
}

m["kku"] = {
	canonicalName = "Tumi",
}

m["kkv"] = {
	canonicalName = "Kangean",
}

m["kkw"] = {
	canonicalName = "Teke-Kukuya",
}

m["kkx"] = {
	canonicalName = "Kohin",
}

m["kky"] = {
	canonicalName = "Guugu Yimidhirr",
	scripts = {"Latn"},
	family = "aus-pam",
}

m["kkz"] = {
	canonicalName = "Kaska",
}

m["kla"] = {
	canonicalName = "Klamath-Modoc",
	otherNames = {"Klamath"},
	scripts = {"Latn"},
}

m["klb"] = {
	canonicalName = "Kiliwa",
	family = "nai-yuc",
}

m["klc"] = {
	canonicalName = "Kolbila",
}

m["kld"] = {
	canonicalName = "Gamilaraay",
	otherNames = {"Kamilaroi", "Kamilarai", "Kamalarai", "Gamilaroi"},
	scripts = {"Latn"},
	family = "aus-cww",
}

m["kle"] = {
	canonicalName = "Kulung",
}

m["klf"] = {
	canonicalName = "Kendeje",
}

m["klg"] = {
	canonicalName = "Tagakaulu Kalagan",
}

m["klh"] = {
	canonicalName = "Weliki",
	family = "ngf-fin",
}

m["kli"] = {
	canonicalName = "Kalumpang",
}

m["klj"] = {
	canonicalName = "Turkic Khalaj",
	otherNames = {"Khalaj", "Arghu"},
	family = "trk",
}

m["klk"] = {
	canonicalName = "Kono (Nigeria)",
	otherNames = {"Kono"},
	family = "nic-bco",
}

m["kll"] = {
	canonicalName = "Kagan Kalagan",
}

m["klm"] = {
	canonicalName = "Kolom",
}

m["kln"] = {
	canonicalName = "Kalenjin",
	scripts = {"Latn"},
	family = "sdv",
}

m["klo"] = {
	canonicalName = "Kapya",
}

m["klp"] = {
	canonicalName = "Kamasa",
}

m["klq"] = {
	canonicalName = "Rumu",
}

m["klr"] = {
	canonicalName = "Khaling",
	family = "sit",
}

m["kls"] = {
	canonicalName = "Kalasha",
	family = "inc-dar",
}

m["klt"] = {
	canonicalName = "Nukna",
	family = "ngf-fin",
}

m["klu"] = {
	canonicalName = "Klao",
}

m["klv"] = {
	canonicalName = "Maskelynes",
	family = "poz-vnc",
}

m["klw"] = {
	canonicalName = "Lindu",
}

m["klx"] = {
	canonicalName = "Koluwawa",
	family = "poz-ocw",
}

m["kly"] = {
	canonicalName = "Kalao",
}

m["klz"] = {
	canonicalName = "Kabola",
}

m["kma"] = {
	canonicalName = "Konni",
}

m["kmb"] = {
	canonicalName = "Kimbundu",
	otherNames = {"North Mbundu"},
	scripts = {"Latn"},
	family = "bnt",
}

m["kmc"] = {
	canonicalName = "Gam",
	otherNames = {"Dong", "Northern Dong", "Southern Dong"},
	family = "qfa-tak",
}

m["kmd"] = {
	canonicalName = "Madukayang Kalinga",
}

m["kme"] = {
	canonicalName = "Bakole",
}

m["kbn"] = {
	canonicalName = "Kare (New Guinea)",
	otherNames = {"Kare (Papua New Guinea)"},
}

m["kmg"] = {
	canonicalName = "Kâte",
}

m["kmh"] = {
	canonicalName = "Kalam",
}

m["kmi"] = {
	canonicalName = "Kami",
}

m["kmj"] = {
	canonicalName = "Kumarbhag Paharia",
	otherNames = {"Kumarbhag", "Kumarbhag Pahariya", "Kumar Paharia", "Malto"},
	scripts = {"Beng", "Deva"},
	family = "dra",
}

m["kmk"] = {
	canonicalName = "Limos Kalinga",
}

m["kml"] = {
	canonicalName = "Tanudan Kalinga",
	otherNames = {"Lower Tanudan Kalinga", "Upper Tanudan Kalinga"},
	scripts = {"Latn"},
}

m["kmm"] = {
	canonicalName = "Kom (India)",
	otherNames = {"Kom"},
	family = "tbq-kuk",
}

m["kmn"] = {
	canonicalName = "Awtuw",
}

m["kmo"] = {
	canonicalName = "Kwoma",
}

m["kmp"] = {
	canonicalName = "Gimme",
}

m["kmq"] = {
	canonicalName = "Kwama",
}

m["kmr"] = {
	canonicalName = "Northern Kurdish",
	otherNames = {"Kurmanji"},
	scripts = {"Latn", "Cyrl", "Armn", "ku-Arab"},
	family = "ira",
	ancestors = {"ku"},
	translit_module = "kmr-translit",
	entry_name = {
		from = {"'"},
		to   = {"’"}},
	wikimedia_codes = {"ku"},
}

m["kms"] = {
	canonicalName = "Kamasau",
	scripts = {"Latn"},
	family = "qfa-tor",
}

m["kmt"] = {
	canonicalName = "Kemtuik",
}

m["kmu"] = {
	canonicalName = "Kanite",
}

m["kmv"] = {
	canonicalName = "Karipúna Creole French",
}

m["kmw"] = {
	canonicalName = "Kikumu",
	otherNames = {"Kikomo", "Komo (Democratic Republic of the Congo)", "Komo"},
	scripts = {"Latn"},
	family = "bnt",
}

m["kmx"] = {
	canonicalName = "Waboda",
}

m["kmy"] = {
	canonicalName = "Koma",
}

m["kmz"] = {
	canonicalName = "Khorasani Turkish",
	otherNames = {"Khorasani Turkic"},
	family = "trk-ogz",
}

m["kna"] = {
	canonicalName = "Kanakuru",
	otherNames = {"Dera", "Dera (Nigeria)"},
	scripts = {"Latn"},
	family = "cdc",
}

m["knb"] = {
	canonicalName = "Lubuagan Kalinga",
	family = "phi",
}

m["knd"] = {
	canonicalName = "Konda",
	family = "ngf-sbh",
}

m["kne"] = {
	canonicalName = "Kankanaey",
	scripts = {"Latn"},
	family = "phi",
}

m["knf"] = {
	canonicalName = "Mankanya",
}

m["kni"] = {
	canonicalName = "Kanufi",
}

m["knj"] = {
	canonicalName = "Akatek",
	otherNames = {"Acateco", "Western Kanjobal"},
	scripts = {"Latn"},
	family = "myn",
}

m["knk"] = {
	canonicalName = "Kuranko",
}

m["knl"] = {
	canonicalName = "Keninjal",
}

m["knm"] = { -- two unrelated lects have this name; this is the Katukinian one
	canonicalName = "Kanamari",
	otherNames = {"Kanamarí", "Katukina-Kanamari", "Kanamare", "Katukína", "Katukina"},
	scripts = {"Latn"},
	family = "sai-ktk",
}

m["kno"] = {
	canonicalName = "Kono (Sierra Leone)",
	otherNames = {"Kono", "Konnoh"},
}

m["knp"] = {
	canonicalName = "Kwanja",
	family = "nic-bod",
}

m["knq"] = {
	canonicalName = "Kintaq",
}

m["knr"] = {
	canonicalName = "Kaningra",
}

m["kns"] = {
	canonicalName = "Kensiu",
}

m["knt"] = {
	canonicalName = "Katukina",
	otherNames = {"Panoan Katukína", "Katukína", "Catuquina", "Waninawa", "Waninnawa", "Kamanawa", "Kamannaua", "Katukina do Jurua", "Katukina of Olinda", "Katukina of Sete Estreles", "Kanamari"},
	family = "sai-pan",
}

m["knu"] = { -- a dialect of 'kpe'
	canonicalName = "Kono (Guinea)",
	otherNames = {"Kono"},
	scripts = {"Latn"},
	family = "dmn",
}

m["knv"] = {
	canonicalName = "Tabo",
}

m["knx"] = {
	canonicalName = "Kendayan",
	otherNames = {"Salako", "Selako", "Ahe"},
	family = "poz-mly",
}

m["kny"] = {
	canonicalName = "Kanyok",
}

m["knz"] = {
	canonicalName = "Kalamsé",
}

m["koa"] = {
	canonicalName = "Konomala",
	family = "poz-ocw",
}

m["koc"] = {
	canonicalName = "Kpati",
	family = "nic-bod",
}

m["kod"] = {
	canonicalName = "Kodi",
}

m["koe"] = {
	canonicalName = "Kacipo-Balesi",
	family = "sdv",
}

m["kof"] = {
	canonicalName = "Kubi",
	family = "cdc",
}

m["kog"] = {
	canonicalName = "Cogui",
	otherNames = {"Kogi", "Cogi", "Kagaba", "Cagaba", "Cágaba"},
}

m["koh"] = {
	canonicalName = "Koyo",
}

m["koi"] = {
	canonicalName = "Komi-Permyak",
	scripts = {"Cyrl"},
	family = "fiu-prm",
	translit_module = "kv-translit",
}

m["kok"] = {
	canonicalName = "Konkani",
	scripts = {"Deva", "Knda", "Mlym", "fa-Arab", "Latn"},
	family = "inc",
	ancestors = {"pmh"},
}

m["kol"] = {
	canonicalName = "Kol (New Guinea)",
	otherNames = {"Kol", "Kol (Papua New Guina)"},
}

m["koo"] = {
	canonicalName = "Konzo",
}

m["kop"] = {
	canonicalName = "Waube",
}

m["koq"] = {
	canonicalName = "Ikota",
	otherNames = {"iKota", "Kota (Gabon)", "Kota"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["kos"] = {
	canonicalName = "Kosraean",
	family = "poz-mic",
}

m["kot"] = {
	canonicalName = "Lagwan",
}

m["kou"] = {
	canonicalName = "Koke",
}

m["kov"] = {
	canonicalName = "Kudu-Camo",
}

m["kow"] = {
	canonicalName = "Kugama",
}

m["koy"] = {
	canonicalName = "Koyukon",
	otherNames = {"Denaakk'e"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["koz"] = {
	canonicalName = "Korak",
}

m["kpa"] = {
	canonicalName = "Kutto",
}

m["kpb"] = {
	canonicalName = "Mullu Kurumba",
	family = "dra",
}

m["kpc"] = {
	canonicalName = "Curripaco",
	otherNames = {"Kurripako"},
	scripts = {"Latn"},
	family = "awd",
}

m["kpd"] = {
	canonicalName = "Koba",
}

m["kpe"] = {
	canonicalName = "Kpelle",
	scripts = {"Latn"},
	family = "dmn",
}

m["kpf"] = {
	canonicalName = "Komba",
}

m["kpg"] = {
	canonicalName = "Kapingamarangi",
	scripts = {"Latn"},
	family = "poz-pol",
}

m["kph"] = {
	canonicalName = "Kplang",
}

m["kpi"] = {
	canonicalName = "Kofei",
}

m["kpj"] = {
	canonicalName = "Karajá",
}

m["kpk"] = {
	canonicalName = "Kpan",
}

m["kpl"] = {
	canonicalName = "Kpala",
	family = "nic-ubg",
}

m["kpm"] = {
	canonicalName = "Koho",
}

m["kpn"] = {
	canonicalName = "Kepkiriwát",
}

m["kpo"] = {
	canonicalName = "Ikposo",
	family = "alv-kwa",
}

m["kpp"] = {
	canonicalName = "Paku Karen",
}

m["kpq"] = {
	canonicalName = "Korupun-Sela",
}

m["kpr"] = {
	canonicalName = "Korafe-Yegha",
}

m["kps"] = {
	canonicalName = "Tehit",
}

m["kpt"] = {
	canonicalName = "Karata",
	scripts = {"Cyrl"},
	family = "cau-ava",
}

m["kpu"] = {
	canonicalName = "Kafoa",
}

m["kpv"] = {
	canonicalName = "Komi-Zyrian",
	otherNames = {"Komi"},
	scripts = {"Cyrl"},
	family = "fiu-prm",
	translit_module = "kv-translit",
}

m["kpw"] = {
	canonicalName = "Kobon",
}

m["kpx"] = {
	canonicalName = "Mountain Koiari",
	otherNames = {"Mountain Koiali"},
}

m["kpy"] = {
	canonicalName = "Koryak",
	scripts = {"Cyrl"},
	family = "qfa-cka",
}

m["kpz"] = {
	canonicalName = "Kupsabiny",
	family = "sdv",
}

m["kqa"] = {
	canonicalName = "Mum",
}

m["kqb"] = {
	canonicalName = "Kovai",
}

m["kqc"] = {
	canonicalName = "Doromu-Koki",
}

m["kqd"] = {
	canonicalName = "Koy Sanjaq Surat",
}

m["kqe"] = {
	canonicalName = "Kalagan",
	family = "phi",
}

m["kqf"] = {
	canonicalName = "Kakabai",
	family = "poz-ocw",
}

m["kqg"] = {
	canonicalName = "Khe",
}

m["kqh"] = {
	canonicalName = "Kisankasa",
	family = "sdv",
}

m["kqi"] = {
	canonicalName = "Koitabu",
}

m["kqj"] = {
	canonicalName = "Koromira",
}

m["kqk"] = {
	canonicalName = "Kotafon Gbe",
}

m["kql"] = {
	canonicalName = "Kyenele",
}

m["kqm"] = {
	canonicalName = "Khisa",
}

m["kqn"] = {
	canonicalName = "Kaonde",
	otherNames = {"Chikaonde", "Kawonde"},
	scripts = {"Latn"},
	family = "bnt",
}

m["kqo"] = {
	canonicalName = "Eastern Krahn",
}

m["kqp"] = {
	canonicalName = "Kimré",
}

m["kqq"] = {
	canonicalName = "Krenak",
}

m["kqr"] = {
	canonicalName = "Kimaragang",
	scripts = {"Latn"},
	family = "poz-san",
}

m["kqs"] = {
	canonicalName = "Northern Kissi",
}

m["kqt"] = {
	canonicalName = "Klias River Kadazan",
}

m["kqu"] = {
	canonicalName = "Seroa",
}

m["kqv"] = {
	canonicalName = "Okolod",
}

m["kqw"] = {
	canonicalName = "Kandas",
	family = "poz-ocw",
}

m["kqx"] = {
	canonicalName = "Mser",
}

m["kqy"] = {
	canonicalName = "Koorete",
}

m["kqz"] = {
	canonicalName = "Korana",
}

m["kra"] = {
	canonicalName = "Kumhali",
}

m["krb"] = {
	canonicalName = "Karkin",
	family = "nai-you",
}

m["krc"] = {
	canonicalName = "Karachay-Balkar",
	scripts = {"Cyrl"},
	family = "trk",
}

m["krd"] = {
	canonicalName = "Kairui-Midiki",
}

m["kre"] = {
	canonicalName = "Panará",
}

m["krf"] = {
	canonicalName = "Koro (Vanuatu)",
	otherNames = {"Koro"},
	family = "poz-oce",
}

m["krh"] = {
	canonicalName = "Kurama",
}

m["kri"] = {
	canonicalName = "Krio",
	scripts = {"Latn"},
	family = "crp",
}

m["krj"] = {
	canonicalName = "Kinaray-a",
	scripts = {"Latn"},
	family = "phi",
}

m["krk"] = {
	canonicalName = "Kerek",
}

m["krl"] = {
	canonicalName = "Karelian",
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["krm"] = {
	canonicalName = "Krim",
}

m["krn"] = {
	canonicalName = "Sapo",
}

m["krp"] = {
	canonicalName = "Korop",
	family = "nic-bco",
}

m["krr"] = {
	canonicalName = "Kru'ng",
}

m["krs"] = {
	canonicalName = "Kresh",
	otherNames = {"Gbaya"},
	family = "csu",
}

m["kru"] = {
	canonicalName = "Kurukh",
	otherNames = {"Kurux"},
	scripts = {"Deva"},
	family = "dra",
}

m["krv"] = {
	canonicalName = "Kavet",
}

m["krw"] = {
	canonicalName = "Western Krahn",
}

m["krx"] = {
	canonicalName = "Karon",
}

m["kry"] = {
	canonicalName = "Kryts",
	otherNames = {"Kryc", "Kryz"},
	family = "cau-lzg",
}

m["krz"] = {
	canonicalName = "Sota Kanum",
}

m["ksa"] = {
	canonicalName = "Shuwa-Zamani",
}

m["ksb"] = {
	canonicalName = "Shambala",
}

m["ksc"] = {
	canonicalName = "Southern Kalinga",
}

m["ksd"] = {
	canonicalName = "Tolai",
	otherNames = {"Kuanua"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["kse"] = {
	canonicalName = "Kuni",
	family = "poz-ocw",
}

m["ksf"] = {
	canonicalName = "Bafia",
}

m["ksg"] = {
	canonicalName = "Kusaghe",
	family = "poz-ocw",
}

m["ksi"] = {
	canonicalName = "Krisa",
	scripts = {"Latn"},
	family = "paa-msk",
}

m["ksj"] = {
	canonicalName = "Uare",
}

m["ksk"] = {
	canonicalName = "Kansa",
	family = "sio",
}

m["ksl"] = {
	canonicalName = "Kumalu",
	family = "poz-ocw",
}

m["ksm"] = {
	canonicalName = "Kumba",
}

m["ksn"] = {
	canonicalName = "Kasiguranin",
}

m["kso"] = {
	canonicalName = "Kofa",
}

m["ksp"] = {
	canonicalName = "Kaba",
}

m["ksq"] = {
	canonicalName = "Kwaami",
}

m["ksr"] = {
	canonicalName = "Borong",
}

m["kss"] = {
	canonicalName = "Southern Kisi",
}

m["kst"] = {
	canonicalName = "Winyé",
}

m["ksu"] = {
	canonicalName = "Khamyang",
}

m["ksv"] = {
	canonicalName = "Kusu",
}

m["ksw"] = {
	canonicalName = "S'gaw Karen",
}

m["ksx"] = {
	canonicalName = "Kedang",
}

m["ksy"] = {
	canonicalName = "Kharia Thar",
	family = "inc",
	ancestors = {"pka"},
}

m["ksz"] = {
	canonicalName = "Kodaku",
	family = "mun",
}

m["kta"] = {
	canonicalName = "Katua",
}

m["ktb"] = {
	canonicalName = "Kambaata",
	family = "cus",
}

m["ktc"] = {
	canonicalName = "Kholok",
}

m["ktd"] = {
	canonicalName = "Kokata",
}

m["ktf"] = {
	canonicalName = "Kwami",
}

m["ktg"] = {
	canonicalName = "Kalkatungu",
	otherNames = {"Kalkutungu", "Galgadungu", "Kalkutung", "Kalkadoon", "Galgaduun"},
	scripts = {"Latn"},
}

m["kth"] = {
	canonicalName = "Karanga",
}

m["kti"] = {
	canonicalName = "North Muyu",
}

m["ktj"] = {
	canonicalName = "Plapo Krumen",
}

m["ktk"] = {
	canonicalName = "Kaniet",
	family = "poz-aay",
}

m["ktl"] = {
	canonicalName = "Koroshi",
	family = "ira",
}

m["ktm"] = {
	canonicalName = "Kurti",
	family = "poz-aay",
}

m["ktn"] = {
	canonicalName = "Karitiâna",
	scripts = {"Latn"},
	family = "tup",
}

m["kto"] = {
	canonicalName = "Kuot",
}

m["ktp"] = {
	canonicalName = "Kaduo",
	otherNames = {"Khatu"},
	family = "tbq-lol",
}

m["ktq"] = {
	canonicalName = "Katabaga",
}

m["ktr"] = {
	canonicalName = "Kota Marudu Tinagas",
}

m["kts"] = {
	canonicalName = "South Muyu",
}

m["ktt"] = {
	canonicalName = "Ketum",
}

m["ktu"] = {
	canonicalName = "Kituba",
	otherNames = {"Munukutuba", "Kikongo-Kituba", "Kikongo", "Kikongo ya leta", "Kibulamatadi", "Kikwango", "Ikeleve", "Kizabave"},
	scripts = {"Latn"},
	family = "crp",
}

m["ktv"] = {
	canonicalName = "Eastern Katu",
	family = "mkh",
}

m["ktw"] = {
	canonicalName = "Kato",
	otherNames = {"Cahto"},
	scripts = {"Latn"},
	family = "ath-pco",
}

m["ktx"] = {
	canonicalName = "Kaxararí",
	family = "sai-pan",
}

m["kty"] = {
	canonicalName = "Kango",
	otherNames = {"Kango (Bas-Uélé District)"}, -- distinct in name, but not necessarily in identity, from 'kzy'
	family = "bnt",
}

m["ktz"] = {
	canonicalName = "Juǀ'hoan",
	otherNames = {"Zhuǀ'hoan", "ǂKxʼauǁʼein", "ǁAuǁei", "ǁAuǁen", "Auen", "Kaukau", "Koko", "Kung-Gobabis", "‡Kx'auǁ'ei", "ǂKx'auǁ'ein", "ǁX'auǁ'e"},
	scripts = {"Latn"},
	family = "qfa-kxa",
}

m["kub"] = {
	canonicalName = "Kutep",
}

m["kuc"] = {
	canonicalName = "Kwinsu",
}

m["kud"] = {
	canonicalName = "Auhelawa",
	otherNames = {"'Auhelawa"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["kue"] = {
	canonicalName = "Kuman",
	otherNames = {"Simbu", "Chimbu"},
	scripts = {"Latn"},
	family = "ngf",
}

m["kuf"] = {
	canonicalName = "Western Katu",
	scripts = {"Laoo", "Tale"},
	family = "mkh",
}

m["kug"] = {
	canonicalName = "Kupa",
}

m["kuh"] = {
	canonicalName = "Kushi",
}

m["kui"] = {
	canonicalName = "Kuikúro",
	otherNames = {"Kuikúro-Kalapálo", "Kuikuro", "Apalakiri"},
	scripts = {"Latn"},
	family = "sai-car",
}

m["kuj"] = {
	canonicalName = "Kuria",
}

m["kuk"] = {
	canonicalName = "Kepo'",
}

m["kul"] = {
	canonicalName = "Kulere",
	otherNames = {"Tof", "Korom Boye", "Akandi", "Akande", "Kande", "Richa"},
}

m["kum"] = {
	canonicalName = "Kumyk",
	scripts = {"Cyrl"},
	family = "trk",
}

m["kun"] = {
	canonicalName = "Kunama",
}

m["kuo"] = {
	canonicalName = "Kumukio",
}

m["kup"] = {
	canonicalName = "Kunimaipa",
}

m["kuq"] = {
	canonicalName = "Karipuna",
}

m["kus"] = {
	canonicalName = "Kusaal",
}

m["kut"] = {
	canonicalName = "Kutenai",
}

m["kuu"] = {
	canonicalName = "Upper Kuskokwim",
}

m["kuv"] = {
	canonicalName = "Kur",
	family = "plf",
}

m["kuw"] = {
	canonicalName = "Kpagua",
}

m["kux"] = {
	canonicalName = "Kukatja",
}

m["kuy"] = {
	canonicalName = "Kuuku-Ya'u",
}

m["kuz"] = {
	canonicalName = "Kunza",
}

m["kva"] = {
	canonicalName = "Bagvalal",
	family = "cau-ava",
}

m["kvb"] = {
	canonicalName = "Kubu",
}

m["kvc"] = {
	canonicalName = "Kove",
	family = "poz-ocw",
}

m["kvd"] = {
	canonicalName = "Kui (Indonesia)",
	otherNames = {"Kui"},
	family = "ngf",
}

m["kve"] = {
	canonicalName = "Kalabakan",
}

m["kvf"] = {
	canonicalName = "Kabalai",
}

m["kvg"] = {
	canonicalName = "Kuni-Boazi",
}

m["kvh"] = {
	canonicalName = "Komodo",
}

m["kvi"] = {
	canonicalName = "Kwang",
}

m["kvj"] = {
	canonicalName = "Psikye",
}

m["kvk"] = {
	canonicalName = "Korean Sign Language",
	family = "sgn-jsl",
}

m["kvl"] = {
	canonicalName = "Brek Karen",
}

m["kvm"] = {
	canonicalName = "Kendem",
	family = "nic-bod",
}

m["kvn"] = {
	canonicalName = "Border Kuna",
}

m["kvo"] = {
	canonicalName = "Dobel",
}

m["kvp"] = {
	canonicalName = "Kompane",
}

m["kvq"] = {
	canonicalName = "Geba Karen",
}

m["kvr"] = {
	canonicalName = "Kerinci",
}

m["kvt"] = {
	canonicalName = "Lahta Karen",
}

m["kvu"] = {
	canonicalName = "Yinbaw Karen",
}

m["kvv"] = {
	canonicalName = "Kola",
}

m["kvw"] = {
	canonicalName = "Wersing",
}

m["kvx"] = {
	canonicalName = "Parkari Koli",
	family = "inc",
}

m["kvy"] = {
        canonicalName = "Yintale Karen",
        family = "kar",
}

m["kvz"] = {
	canonicalName = "Tsakwambo",
}

m["kwa"] = {
	canonicalName = "Dâw",
}

m["kwb"] = {
	canonicalName = "Baa",
	otherNames = {"Kwa"},
	family = "alv",
}

m["kwc"] = {
	canonicalName = "Likwala",
}

m["kwd"] = {
	canonicalName = "Kwaio",
	family = "poz-sls",
}

m["kwe"] = {
	canonicalName = "Kwerba",
}

m["kwf"] = {
	canonicalName = "Kwara'ae",
}

m["kwg"] = {
	canonicalName = "Sara Kaba Deme",
}

m["kwh"] = {
	canonicalName = "Kowiai",
}

m["kwi"] = {
	canonicalName = "Awa-Cuaiquer",
	otherNames = {"Awa", "Cuaiquer", "Awa Pit", "Awapit", "Kwaiker", "Coaiquer", "Quaiquer"},
	scripts = {"Latn"},
	family = "sai-bar",
}

m["kwj"] = {
	canonicalName = "Kwanga",
}

m["kwk"] = {
	canonicalName = "Kwak'wala",
	scripts = {"Latn"},
	family = "wak",
}

m["kwl"] = {
	canonicalName = "Kofyar",
}

m["kwm"] = {
	canonicalName = "Kwambi",
}

m["kwn"] = {
	canonicalName = "Kwangali",
}

m["kwo"] = {
	canonicalName = "Kwomtari",
}

m["kwp"] = {
	canonicalName = "Kodia",
}

m["kwq"] = {
	canonicalName = "Kwak",
}

m["kwr"] = {
	canonicalName = "Kwer",
}

m["kws"] = {
	canonicalName = "Kwese",
}

m["kwt"] = {
	canonicalName = "Kwesten",
}

m["kwu"] = {
	canonicalName = "Kwakum",
}

m["kwv"] = {
	canonicalName = "Sara Kaba Náà",
	otherNames = {"Sara Dunjo"},
}

m["kww"] = {
	canonicalName = "Kwinti",
}

m["kwx"] = {
	canonicalName = "Khirwar",
}

m["kwz"] = {
	canonicalName = "Kwadi",
}

m["kxa"] = {
	canonicalName = "Kairiru",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["kxb"] = {
	canonicalName = "Krobu",
}

m["kxc"] = {
	canonicalName = "Khonso",
	family = "cus",
}

m["kxd"] = {
	canonicalName = "Brunei",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["kxe"] = {
	canonicalName = "Kakihum",
}

m["kxf"] = {
        canonicalName = "Manumanaw Karen",
        scripts = {"Latn", "Mymr"},
        family = "kar",
}

m["kxh"] = {
	canonicalName = "Karo",
}

m["kxi"] = {
	canonicalName = "Keningau Murut",
	otherNames = {"Nabay", "Nabaay"},
        scripts = {"Latn"},
}

m["kxj"] = {
	canonicalName = "Kulfa",
}

m["kxk"] = {
	canonicalName = "Zayein Karen",
}

m["kxl"] = {
	canonicalName = "Nepali Kurux",
	scripts = {"Deva"},
	family = "dra",
}

m["kxm"] = {
	canonicalName = "Northern Khmer",
}

m["kxn"] = {
	canonicalName = "Kanowit",
	otherNames = {"Tanjong", "Kanowit-Tanjong Melanau"},
}

m["kxo"] = {
	canonicalName = "Kanoé",
}

m["kxp"] = {
	canonicalName = "Wadiyara Koli",
}

m["kxq"] = {
	canonicalName = "Smärky Kanum",
}

m["kxr"] = {
	canonicalName = "Koro (New Guinea)",
	otherNames = {"Koro (Papua New Guinea)", "Koro"},
	family = "poz-oce",
}

m["kxs"] = {
	canonicalName = "Kangjia",
}

m["kxt"] = {
	canonicalName = "Koiwat",
}

m["kxu"] = {
	canonicalName = "Kui (India)",
	otherNames = {"Kui", "Kuy"},
	scripts = {"Orya"},
	family = "dra",
}

m["kxv"] = {
	canonicalName = "Kuvi",
	scripts = {"Orya"},
	family = "dra",
}

m["kxw"] = {
	canonicalName = "Konai",
}

m["kxx"] = {
	canonicalName = "Likuba",
}

m["kxy"] = {
	canonicalName = "Kayong",
	family = "mkh",
}

m["kxz"] = {
	canonicalName = "Kerewo",
}

m["kya"] = {
	canonicalName = "Kwaya",
}

m["kyb"] = {
	canonicalName = "Butbut Kalinga",
}

m["kyc"] = {
	canonicalName = "Kyaka",
}

m["kyd"] = {
	canonicalName = "Karey",
}

m["kye"] = {
	canonicalName = "Krache",
}

m["kyf"] = {
	canonicalName = "Kouya",
}

m["kyg"] = {
	canonicalName = "Keyagana",
}

m["kyh"] = {
	canonicalName = "Karok",
	otherNames = {"Karuk"},
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["kyi"] = {
	canonicalName = "Kiput",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["kyj"] = {
	canonicalName = "Karao",
}

m["kyk"] = {
	canonicalName = "Kamayo",
}

m["kyl"] = {
	canonicalName = "Kalapuya",
}

m["kym"] = {
	canonicalName = "Kpatili",
	family = "znd",
}

m["kyn"] = {
	canonicalName = "Karolanos",
}

m["kyo"] = {
	canonicalName = "Kelon",
}

m["kyp"] = {
	canonicalName = "Kang",
}

m["kyq"] = {
	canonicalName = "Kenga",
}

m["kyr"] = {
	canonicalName = "Kuruáya",
}

m["kys"] = {
	canonicalName = "Baram Kayan",
}

m["kyt"] = {
	canonicalName = "Kayagar",
}

m["kyu"] = {
        canonicalName = "Western Kayah",
        scripts = {"Kali", "Latn", "Mymr"},
        family = "kar",
}

m["kyv"] = {
	canonicalName = "Kayort",
	family = "inc",
	ancestors = {"pka"},
}

m["kyw"] = {
	canonicalName = "Kudmali",
}

m["kyx"] = {
	canonicalName = "Rapoisi",
}

m["kyy"] = {
	canonicalName = "Kambaira",
}

m["kyz"] = {
	canonicalName = "Kayabí",
}

m["kza"] = {
	canonicalName = "Western Karaboro",
}

m["kzb"] = {
	canonicalName = "Kaibobo",
}

m["kzc"] = {
	canonicalName = "Bondoukou Kulango",
}

m["kzd"] = {
	canonicalName = "Kadai",
	family = "plf",
}

m["kze"] = {
	canonicalName = "Kosena",
	family = "ngf",
}

m["kzf"] = {
	canonicalName = "Da'a Kaili",
	otherNames = {"Tado", "Inde", "Pekava", "West Kaili"},
	scripts = {"Latn"},
	family = "poz-kal",
}

m["kzg"] = {
	canonicalName = "Kikai",
	family = "jpx-ryu",
}

m["kzh"] = {
	canonicalName = "Dongolawi",
	otherNames = {"Kenuzi-Dongola", "Andaandi", "Kenzi", "Mattoki"},
	scripts = {"Latn"},
	family = "nub",
}

m["kzi"] = {
	canonicalName = "Kelabit",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["kzj"] = {
	canonicalName = "Coastal Kadazan",
	scripts = {"Latn"},
	family = "poz-san",
}

m["kzk"] = {
	canonicalName = "Kazukuru",
	family = "poz-ocw",
}

m["kzl"] = {
	canonicalName = "Kayeli",
	family = "plf",
}

m["kzm"] = {
	canonicalName = "Kais",
	family = "paa",
}

m["kzn"] = {
	canonicalName = "Kokola",
	family = "bnt",
}

m["kzo"] = {
	canonicalName = "Kaningi",
}

m["kzp"] = {
	canonicalName = "Kaidipang",
	family = "phi",
}

m["kzq"] = {
	canonicalName = "Kaike",
}

m["kzr"] = {
	canonicalName = "Karang",
	family = "alv-mbm",
}

m["kzs"] = {
	canonicalName = "Sugut Dusun",
	scripts = {"Latn"},
	family = "poz-san",
}

m["kzt"] = {
	canonicalName = "Tambunan Dusun",
	scripts = {"Latn"},
	family = "poz-san",
}

m["kzu"] = {
	canonicalName = "Kayupulau",
	family = "poz-ocw",
}

m["kzv"] = {
	canonicalName = "Komyandaret",
	family = "ngf-okk",
}

m["kzw"] = { -- contrast xoo, sai-kat, sai-xoc, the last of which the ISO conflated into this code
	canonicalName = "Kariri",
	otherNames = {"Kipeá", "Quipea", "Kamurú", "Camuru", "Dzubukuá", "Dzubucua", "Karirí", "Sabujá", "Sapoyá", "Pedra Branca"},
	family = "sai-mje",
}

m["kzx"] = {
	canonicalName = "Kamarian",
	scripts = {"Latn"},
	family = "plf",
}

m["kzy"] = {
	canonicalName = "Kango-Sua",
	otherNames = {"Kango", "Kango (Tshopo District)"}, -- distinct in name, but not necessarily in identity, from 'kty'
	family = "bnt",
}

m["kzz"] = {
	canonicalName = "Kalabra",
	family = "paa",
}

return m