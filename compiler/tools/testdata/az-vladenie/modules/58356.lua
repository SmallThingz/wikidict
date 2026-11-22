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

m["laa"] = {
	canonicalName = "Lapuyan Subanun",
	family = "phi",
}

m["lab"] = {
	canonicalName = "Linear A",
}

m["lac"] = {
	canonicalName = "Lacandon",
	otherNames = {"Jach t’aan", "Hach t’an"},
	family = "myn",
}

m["lad"] = {
	canonicalName = "Ladino",
	otherNames = {"Judaeo-Spanish", "Judæo-Spanish", "Judeo-Spanish"},
	scripts = {"Hebr", "Latn", "Cyrl"},
	family = "roa",
	ancestors = {"osp"},
}

m["lae"] = {
	canonicalName = "Pattani",
}

m["laf"] = {
	canonicalName = "Lafofa",
}

m["lag"] = {
	canonicalName = "Langi",
}

m["lah"] = {
	canonicalName = "Lahnda",
	otherNames = {"Western Punjabi"},
	scripts = {"pa-Arab"},
	family = "inc",
	ancestors = {"pa"},
}

m["lai"] = {
	canonicalName = "Lambya",
}

m["laj"] = {
	canonicalName = "Lango (Uganda)",
	otherNames = {"Lango", "Leb Lango"}, -- the last, though listed in Ethnologue, is not a name but rather the phrase "Lango language"
	scripts = {"Latn"},
	family = "sdv",
}

m["lak"] = {
	canonicalName = "Laka",
	otherNames = {"Laka (Nigeria)"},
	family = "alv",
}

m["lal"] = {
	canonicalName = "Lalia",
}

m["lam"] = {
	canonicalName = "Lamba",
}

m["lan"] = {
	canonicalName = "Laru",
}

m["lap"] = {
	canonicalName = "Kabba-Laka",
	otherNames = {"Kabba Laka", "Laka (Chad)", "Laka"},
	family = "csu",
}

m["laq"] = {
	canonicalName = "Qabiao",
	otherNames = {"Laqua"},
	family = "qfa-tak",
}

m["lar"] = {
	canonicalName = "Larteh",
	family = "alv-kwa",
}

m["las"] = {
	canonicalName = "Gur Lama",
	otherNames = {"Lama (West Africa)", "Lama (Togo)", "Lama"}, -- contrast 'lay', "Tibeto-Burman Lama"
	family = "nic-gur",
}

m["lau"] = {
	canonicalName = "Laba",
}

m["law"] = {
	canonicalName = "Lauje",
	scripts = {"Latn"},
	family = "poz",
}

m["lax"] = {
	canonicalName = "Tiwa",
	otherNames = {"Lalung"},
	scripts = {"Latn"},
	family = "sit",
}

m["lay"] = {
	canonicalName = "Lama Bai",
	otherNames = {"Lama (Southeast Asia)", "Lama (Burma)", "Lama (Myanmar)", "Lama", "Northern Bai", "Laemae"}, -- the last two names are ambiguous, and also denote another Bai language
	family = "sit",
}

m["laz"] = {
	canonicalName = "Aribwatsa",
	family = "poz-ocw",
}

m["lba"] = {
	canonicalName = "Lui",
	family = "sit",
	ancestors = {"kdv"},
}

m["lbb"] = {
	canonicalName = "Label",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["lbc"] = {
	canonicalName = "Lakkia",
}

m["lbe"] = {
	canonicalName = "Lak",
	scripts = {"Cyrl"},
	family = "cau-nec",
	translit_module = "lbe-translit",
}

m["lbf"] = {
	canonicalName = "Tinani",
}

m["lbg"] = {
	canonicalName = "Laopang",
	family = "tbq-lol",
}

m["lbi"] = {
	canonicalName = "La'bi",
}

m["lbj"] = {
	canonicalName = "Ladakhi",
	otherNames = {"Bhoti"},
	translit_module = "bo-translit",
}

m["lbk"] = {
	canonicalName = "Central Bontoc",
	otherNames = {"Central Bontok", "Igorot Bontoc", "Igorot Bontok", "Bontok Igorot", "Bontoc", "Bontok", "Finallig"},
	scripts = {"Latn"},
	family = "phi",
}

m["lbl"] = {
	canonicalName = "Libon Bikol",
}

m["lbm"] = {
	canonicalName = "Lodhi",
	family = "mun",
}

m["lbn"] = {
	canonicalName = "Lamet",
}

m["lbo"] = {
	canonicalName = "Laven",
}

m["lbq"] = {
	canonicalName = "Wampar",
	family = "poz-ocw",
}

m["lbr"] = {
	canonicalName = "Northern Lorung",
	otherNames = {"Northern Lohorung"},
}

m["lbs"] = {
	canonicalName = "Libyan Sign Language",
	family = "sgn",
}

m["lbt"] = {
	canonicalName = "Lachi",
}

m["lbu"] = {
	canonicalName = "Labu",
	family = "poz-ocw",
}

m["lbv"] = {
	canonicalName = "Lavatbura-Lamusong",
	family = "poz-ocw",
}

m["lbw"] = {
	canonicalName = "Tolaki",
	scripts = {"Latn"},
	family = "poz-btk",
}

m["lbx"] = {
	canonicalName = "Lawangan",
}

m["lby"] = {
	canonicalName = "Lamu-Lamu",
}

m["lbz"] = {
	canonicalName = "Lardil",
	otherNames = {"Leerdil", "Leertil", "Damin", "Demiin"},
}

m["lcc"] = {
	canonicalName = "Legenyem",
	family = "poz-hce",
}

m["lcd"] = {
	canonicalName = "Lola",
	family = "plf",
}

m["lce"] = {
	canonicalName = "Loncong",
}

m["lcf"] = {
	canonicalName = "Lubu",
}

m["lch"] = {
	canonicalName = "Luchazi",
}

m["lcl"] = {
	canonicalName = "Lisela",
	family = "plf",
}

m["lcm"] = {
	canonicalName = "Tungag",
	family = "poz-ocw",
}

m["lcp"] = {
	canonicalName = "Western Lawa",
	family = "aav",
}

m["lcq"] = {
	canonicalName = "Luhu",
	otherNames = {"Piru"},
	family = "plf",
}

m["lcs"] = {
	canonicalName = "Lisabata-Nuniali",
}

m["lda"] = {
	canonicalName = "Kla",
	family = "dmn",
}

m["ldb"] = {
	canonicalName = "Idun",
}

m["ldd"] = {
	canonicalName = "Luri",
}

m["ldg"] = {
	canonicalName = "Lenyima",
	family = "nic-bco",
}

m["ldh"] = {
	canonicalName = "Lamja-Dengsa-Tola",
}

m["ldj"] = {
	canonicalName = "Lemoro",
}

m["ldk"] = {
	canonicalName = "Leelau",
}

m["ldl"] = {
	canonicalName = "Kaan",
}

m["ldm"] = {
	canonicalName = "Landoma",
}

m["ldn"] = {
	canonicalName = "Láadan",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["ldo"] = {
	canonicalName = "Loo",
}

m["ldp"] = {
	canonicalName = "Tso",
}

m["ldq"] = {
	canonicalName = "Lufu",
	family = "alv",
}

m["lea"] = {
	canonicalName = "Lega-Shabunda",
	otherNames = {"Lega-Malinga", "Lega Malinga", "Lega Shabunda", "Shabunda Lega", "Upper Lega", "Lower Lega", "Forest Lega", "Western Lega", "Southern Lega", "Liga", "Kiliga", "Lega", "Kilega", "KiLega", "Kanu", "Kikanu", "Gala", "Kigala", "Yoma", "Kiyoma", "Sede", "Kisede", "Gonzabale", "Beya", "Beia", "Nyamunsange", "KiNyamunsange", "Banagabo", "Kabango", "Bene"},
}

m["leb"] = {
	canonicalName = "Lala-Bisa",
}

m["lec"] = {
	canonicalName = "Leco",
	family = "qfa-iso",
}

m["led"] = {
	canonicalName = "Lendu",
	scripts = {"Latn"},
	family = "csu",
}

m["lee"] = {
	canonicalName = "Lyélé",
}

m["lef"] = {
	canonicalName = "Lelemi",
}

m["leh"] = {
	canonicalName = "Lenje",
}

m["lei"] = {
	canonicalName = "Lemio",
}

m["lej"] = {
	canonicalName = "Lengola",
}

m["lek"] = {
	canonicalName = "Leipon",
	family = "poz-aay",
}

m["lel"] = {
	canonicalName = "Bashilele",
	otherNames = {"Lele (Congo)", "Lele (Democratic Republic of the Congo)", "Lele", "Usilele"},
	family = "bnt",
}

m["lem"] = {
	canonicalName = "Nomaande",
	family = "nic-bod",
}

m["len"] = {
	canonicalName = "Honduran Lenca",
	otherNames = {"Lenca", "Lencan"},
	scripts = {"Latn"},
	family = "nai-len",
}

m["leo"] = {
	canonicalName = "Leti (Cameroon)",
	otherNames = {"Leti"}, -- Ethnologue says this secret language has never had native speakers or been written
	family = "nic-bco",
}

m["lep"] = {
	canonicalName = "Lepcha",
	scripts = {"Lepc"},
	family = "tbq",
	translit_module = "lep-translit"
}

m["leq"] = {
	canonicalName = "Lembena",
}

m["ler"] = {
	canonicalName = "Lenkau",
	family = "poz-aay",
}

m["les"] = {
	canonicalName = "Lese",
}

m["let"] = {
	canonicalName = "Lesing-Gelimi",
	family = "poz-ocw",
}

m["leu"] = {
	canonicalName = "Kara (New Guinea)",
	otherNames = {"Kara (Papua New Guinea)", "Kara", "Lemakot"},
	family = "poz-ocw",
}

m["lev"] = {
	canonicalName = "Lamma",
}

m["lew"] = { -- this code was basically assigned as a catch-all for things that aren't brs, kzf or unz
	canonicalName = "Ledo Kaili",
	otherNames = {"Rai", "Tara", "Ta'a", "Taa", "Central Kaili", "East Kaili", "Ledo", "Edo", "Ado", "Doi", "Ija", "Tawaili", "Palu", "Parigi", "Sigi"},
	scripts = {"Latn"},
	family = "poz-kal",
}

m["lex"] = {
	canonicalName = "Luang",
}

m["ley"] = {
	canonicalName = "Lemolang",
}

m["lez"] = {
	canonicalName = "Lezgi",
	otherNames = {"Lezgian", "Lezgin"},
	scripts = {"Cyrl"},
	family = "cau-lzg",
	translit_module = "lez-translit",
}

m["lfa"] = {
	canonicalName = "Lefa",
}

m["lfn"] = {
	canonicalName = "Lingua Franca Nova",
	type = "appendix-constructed",
	scripts = {"Latn"},
	family = "art",
}

m["lga"] = {
	canonicalName = "Lungga",
	family = "poz-ocw",
}

m["lgb"] = {
	canonicalName = "Laghu",
	family = "poz-ocw",
}

m["lgg"] = {
	canonicalName = "Lugbara",
}

m["lgh"] = {
	canonicalName = "Laghuu",
	otherNames = {"Xá Phó", "Phù Lá Lão"},
	family = "tbq-lol",
}

m["lgi"] = {
	canonicalName = "Lengilu",
	family = "poz-swa",
}

m["lgk"] = {
	canonicalName = "Lingarak",
	family = "poz-vnc",
}

m["lgl"] = {
	canonicalName = "Wala",
	family = "poz-sls",
}

m["lgm"] = {
	canonicalName = "Lega-Mwenga",
	otherNames = {"Lega-Ntara", "Lega Ntara", "Lega Mwenga", "Mwenga Lega", "Lower Lega", "Upper Lega", "Eastern Lega", "Northern Lega", "Isile", "Ishile", "Kisile", "Mwenda-Liga"},
	family = "bnt",
}

m["lgn"] = {
	canonicalName = "Opuuo",
}

m["lgq"] = {
	canonicalName = "Logba",
	otherNames = {"Ikpana"},
	scripts = {"Latn"},
	family = "alv",
}

m["lgr"] = {
	canonicalName = "Lengo",
	family = "poz-sls",
}

m["lgt"] = {
	canonicalName = "Pahi",
}

m["lgu"] = {
	canonicalName = "Longgu",
	family = "poz-sls",
}

m["lgz"] = {
	canonicalName = "Ligenza",
}

m["lha"] = {
	canonicalName = "Laha (Vietnam)",
	otherNames = {"Laha", "La Ha"},
	family = "qfa-tak",
}

m["lhh"] = {
	canonicalName = "Laha (Indonesia)",
	otherNames = {"Laha", "Central Ambon"},
	family = "poz",
}

m["lhi"] = {
	canonicalName = "Lahu Shi",
	family = "tbq-lol",
}

m["lhl"] = {
	canonicalName = "Lahul Lohar",
}

m["lhn"] = {
	canonicalName = "Lahanan",
}

m["lhp"] = {
	canonicalName = "Lhokpu",
	family = "sit",
}

m["lhs"] = {
	canonicalName = "Mlahsö",
}

m["lht"] = {
	canonicalName = "Lo-Toga",
	family = "poz-vnc",
}

m["lhu"] = {
	canonicalName = "Lahu",
	family = "tbq-lol",
}

m["lia"] = {
	canonicalName = "West-Central Limba",
}

m["lib"] = {
	canonicalName = "Likum",
	family = "poz-aay",
}

m["lic"] = {
	canonicalName = "Hlai",
	otherNames = {"Bouhin", "Heitu", "Ha Em", "Zhongsha", "Lauhut", "Baoding", "Tongzha", "tongshi", "Zandui", "Baoting", "Nadou", "Dongfang", "Changjiang", "Moyjaw", "Xifang", "Baisha", "Yuanmen"}, -- some of these may need to be split off as languages
}

m["lid"] = {
	canonicalName = "Nyindrou",
	family = "poz-aay",
}

m["lie"] = {
	canonicalName = "Likila",
}

m["lif"] = {
	canonicalName = "Limbu",
	scripts = {"Limb"},
	family = "tbq",
}

m["lig"] = {
	canonicalName = "Ligbi",
}

m["lih"] = {
	canonicalName = "Lihir",
	family = "poz-ocw",
}

m["lii"] = {
	canonicalName = "Lingkhim",
}

m["lij"] = {
	canonicalName = "Ligurian",
	scripts = {"Latn"},
	family = "roa",
}

m["lik"] = {
	canonicalName = "Lika",
}

m["lil"] = {
	canonicalName = "Lillooet",
}

m["lio"] = {
	canonicalName = "Liki",
	family = "poz-ocw",
}

m["lip"] = {
	canonicalName = "Sekpele",
}

m["liq"] = {
	canonicalName = "Libido",
	family = "cus",
}

m["lir"] = {
	canonicalName = "Liberian English",
}

m["lis"] = {
	canonicalName = "Lisu",
	scripts = {"Lisu"},
	family = "tbq-lol",
}

m["liu"] = {
	canonicalName = "Logorik",
	family = "sdv",
}

m["liv"] = {
	canonicalName = "Livonian",
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["liw"] = {
	canonicalName = "Col",
}

m["lix"] = {
	canonicalName = "Liabuku",
}

m["liy"] = {
	canonicalName = "Banda-Bambari",
}

m["liz"] = {
	canonicalName = "Libinza",
}

m["lja"] = {
	canonicalName = "Golpa",
	family = "aus-yol",
}

m["lje"] = {
	canonicalName = "Rampi",
	family = "poz",
}

m["lji"] = {
	canonicalName = "Laiyolo",
}

m["ljl"] = {
	canonicalName = "Li'o",
}

m["ljp"] = {
	canonicalName = "Lampung Api",
	scripts = {"Latn"},
	family = "poz-lgx",
}

m["ljw"] = {
	canonicalName = "Yirandali",
}

m["ljx"] = {
	canonicalName = "Yuru",
}

m["lka"] = {
	canonicalName = "Lakalei",
	family = "plf",
}

m["lkb"] = {
	canonicalName = "Kabras",
}

m["lkc"] = {
	canonicalName = "Kucong",
	family = "tbq-lol",
}

m["lkd"] = {
	canonicalName = "Lakondê",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["lke"] = {
	canonicalName = "Kenyi",
}

m["lkh"] = {
	canonicalName = "Lakha",
}

m["lki"] = {
	canonicalName = "Laki",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["lkj"] = {
	canonicalName = "Remun",
}

m["lkl"] = {
	canonicalName = "Laeko-Libuat",
	family = "qfa-tor",
}

m["lkm"] = {
	canonicalName = "Kalaamaya",
}

m["lkn"] = {
	canonicalName = "Lakon",
	family = "poz-vnc",
}

m["lko"] = {
	canonicalName = "Khayo",
}

m["lkr"] = {
	canonicalName = "Päri",
	family = "sdv",
}

m["lks"] = {
	canonicalName = "Kisa",
}

m["lkt"] = {
	canonicalName = "Lakota",
	otherNames = {"Lakhota"},
	scripts = {"Latn"},
	family = "sio",
}

m["lku"] = {
	canonicalName = "Kungkari",
}

m["lky"] = {
	canonicalName = "Lokoya",
	family = "sdv",
}

m["lla"] = {
	canonicalName = "Lala-Roba",
}

m["llb"] = {
	canonicalName = "Lolo",
}

m["llc"] = {
	canonicalName = "Lele (Guinea)",
	otherNames = {"Lele"},
	family = "dmn",
}

m["lld"] = {
	canonicalName = "Ladin",
	scripts = {"Latn"},
	family = "roa",
}

m["lle"] = {
	canonicalName = "Lele (New Guinea)",
	otherNames = {"Lele (Papua New Guinea)", "Lele", "Lele Hai"},
	family = "poz-oce",
}

m["llf"] = {
	canonicalName = "Hermit",
	family = "poz-aay",
}

m["llg"] = {
	canonicalName = "Lole",
	family = "plf",
}

m["llh"] = {
	canonicalName = "Lamu",
	family = "tbq-lol",
}

m["lli"] = {
	canonicalName = "Teke-Laali",
}

m["llj"] = {
	canonicalName = "Ladji-Ladji",
	otherNames = {"Ledji-Ledji"},
	family = "aus-pam",
}

m["llk"] = {
	canonicalName = "Lelak",
	family = "poz-swa",
}

m["lll"] = {
	canonicalName = "Lilau",
	family = "qfa-tor",
}

m["llm"] = {
	canonicalName = "Lasalimu",
}

m["lln"] = {
	canonicalName = "Lele (Chad)",
	otherNames = {"Lele"},
	family = "cdc",
}

m["llo"] = {
	canonicalName = "Khlor",
	family = "mkh",
}

m["llp"] = {
	canonicalName = "North Efate",
	otherNames = {"Efate", "Vate", "Vaté", "Nguna"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["llq"] = {
	canonicalName = "Lolak",
}

m["lls"] = {
	canonicalName = "Lithuanian Sign Language",
	family = "sgn",
}

m["llu"] = {
	canonicalName = "Lau",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["llx"] = {
	canonicalName = "Lauan",
	family = "poz-occ",
}

m["lma"] = {
	canonicalName = "East Limba",
}

m["lmb"] = {
	canonicalName = "Merei",
	family = "poz-vnc",
}

m["lmc"] = {
	canonicalName = "Limilngan",
}

m["lmd"] = {
	canonicalName = "Lumun",
}

m["lme"] = {
	canonicalName = "Pévé",
}

m["lmf"] = {
	canonicalName = "South Lembata",
}

m["lmg"] = {
	canonicalName = "Lamogai",
	family = "poz-ocw",
}

m["lmh"] = {
	canonicalName = "Lambichhong",
}

m["lmi"] = {
	canonicalName = "Lombi",
}

m["lmj"] = {
	canonicalName = "West Lembata",
}

m["lmk"] = {
	canonicalName = "Lamkang",
	family = "tbq-kuk",
}

m["lml"] = {
	canonicalName = "Raga",
	otherNames = {"Hano", "Bwatvenua", "Lamalanga", "Vunmarama", "Loltong"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["lmn"] = {
	canonicalName = "Lambadi",
}

m["lmo"] = {
	canonicalName = "Lombard",
	scripts = {"Latn"},
	family = "roa",
}

m["lmp"] = {
	canonicalName = "Limbum",
	family = "nic-bod",
}

m["lmq"] = {
	canonicalName = "Lamatuka",
}

m["lmr"] = {
	canonicalName = "Lamalera",
}

m["lmu"] = {
	canonicalName = "Lamenu",
	family = "poz-vnc",
}

m["lmv"] = {
	canonicalName = "Lomaiviti",
	family = "poz-occ",
}

m["lmw"] = {
	canonicalName = "Lake Miwok",
	family = "nai-you",
}

m["lmx"] = {
	canonicalName = "Laimbue",
}

m["lmy"] = {
	canonicalName = "Lamboya",
}

m["lmz"] = {
	canonicalName = "Lumbee",
	scripts = {"Latn"},
}

m["lna"] = {
	canonicalName = "Langbashe",
}

m["lnb"] = {
	canonicalName = "Mbalanhu",
}

m["lnd"] = {
	canonicalName = "Lun Bawang",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["lng"] = {
	canonicalName = "Lombardic",
	scripts = {"Runr"},
	family = "gem",
}

m["lnh"] = {
	canonicalName = "Lanoh",
}

m["lni"] = {
	canonicalName = "Daantanai'",
}

m["lnj"] = {
	canonicalName = "Linngithigh",
	otherNames = {"Linngithig", "Leningitij"},
}

m["lnl"] = {
	canonicalName = "South Central Banda",
}

m["lnm"] = {
	canonicalName = "Langam",
	family = "paa",
}

m["lnn"] = {
	canonicalName = "Lorediakarkar",
	family = "poz-vnc",
}

m["lno"] = {
	canonicalName = "Lango (Sudan)",
	otherNames = {"Lango", "Lango (South Sudan)", "Langgo"},
	family = "sdv",
}

m["lns"] = {
	canonicalName = "Lamnso'",
}

m["lnu"] = {
	canonicalName = "Longuda",
	scripts = {"Latn"},
	family = "nic",
}

m["lnw"] = {
	canonicalName = "Lanima",
	family = "aus-pam",
}

m["lnz"] = {
	canonicalName = "Lonzo",
	family = "nic-bco",
}

m["loa"] = {
	canonicalName = "Loloda",
	family = "paa",
}

m["lob"] = {
	canonicalName = "Lobi",
}

m["loc"] = {
	canonicalName = "Inonhan",
}

m["lod"] = {
	canonicalName = "Berawan",
	otherNames = {"Central Berawan", "East Berawan", "West Berawan", "Long Terawan", "Batu Belah", "Long Teru", "Long Jegan", "Long Pata"},
	scripts = {"Latn"},
	family = "poz-swa",
}

m["loe"] = {
	canonicalName = "Saluan",
}

m["lof"] = {
	canonicalName = "Logol",
}

m["log"] = {
	canonicalName = "Logo",
}

m["loh"] = {
	canonicalName = "Narim",
	family = "sdv",
}

m["loi"] = {
	canonicalName = "Lomakka",
	otherNames = {"Loma"},
	family = "nic",
}

m["loj"] = {
	canonicalName = "Lou",
	scripts = {"Latn"},
	family = "poz-aay",
}

m["lok"] = {
	canonicalName = "Loko",
}

m["lol"] = {
	canonicalName = "Mongo",
	scripts = {"Latn"},
	family = "bnt",
}

m["lom"] = {
	canonicalName = "Looma",
	otherNames = {"Loma"},
	family = "dmn",
}

m["lon"] = {
	canonicalName = "Malawi Lomwe",
}

m["loo"] = {
	canonicalName = "Lombo",
}

m["lop"] = {
	canonicalName = "Lopa",
}

m["loq"] = {
	canonicalName = "Lobala",
}

m["lor"] = {
	canonicalName = "Téén",
}

m["los"] = {
	canonicalName = "Loniu",
	family = "poz-aay",
}

m["lot"] = {
	canonicalName = "Lotuko",
	family = "sdv",
}

m["lou"] = {
	canonicalName = "Louisiana Creole French",
	otherNames = {"Louisiana Creole", "Kréyol"},
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"fr"},
}

m["lov"] = {
	canonicalName = "Lopi",
}

m["low"] = {
	canonicalName = "Tampias Lobu",
}

m["lox"] = {
	canonicalName = "Loun",
	family = "plf",
}

m["loz"] = {
	canonicalName = "Lozi",
	scripts = {"Latn"},
	family = "bnt",
}

m["lpa"] = {
	canonicalName = "Lelepa",
	family = "poz-vnc",
}

m["lpe"] = {
	canonicalName = "Lepki",
}

m["lpn"] = {
	canonicalName = "Long Phuri Naga",
}

m["lpo"] = {
	canonicalName = "Lipo",
	otherNames = {"Eastern Lisu"},
	scripts = {"Plrd"},
	family = "tbq-lol",
}

m["lpx"] = {
	canonicalName = "Lopit",
	family = "sdv",
}

m["lra"] = {
	canonicalName = "Rara Bakati'",
}

m["lrc"] = {
	canonicalName = "Northern Luri",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["lre"] = {
	canonicalName = "Laurentian",
	otherNames = {"St. Lawrence Iroquoian"},
	scripts = {"Latn"},
	family = "iro",
}

m["lrg"] = {
	canonicalName = "Laragia",
}

m["lri"] = {
	canonicalName = "Marachi",
}

m["lrk"] = {
	canonicalName = "Loarki",
	otherNames = {"Gade Lohar"},
}

m["lrl"] = {
	canonicalName = "Lari",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["lrm"] = {
	canonicalName = "Marama",
}

m["lrn"] = {
	canonicalName = "Lorang",
}

m["lro"] = {
	canonicalName = "Laro",
}

m["lrr"] = {
	canonicalName = "Southern Lorung",
	otherNames = {"Yamphe", "Southern Yamphe", "Yamphu", "Southern Yamphu"},
}

m["lrt"] = {
	canonicalName = "Larantuka Malay",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["lrv"] = {
	canonicalName = "Larevat",
	family = "poz-vnc",
}

m["lrz"] = {
	canonicalName = "Lemerig",
	family = "poz-vnc",
}

m["lsa"] = {
	canonicalName = "Lasgerdi",
	family = "ira",
}

m["lsd"] = {
	canonicalName = "Lishana Deni",
	otherNames = {"Betanure Jewish Neo-Aramaic"},
	scripts = {"Hebr"},
	family = "sem-ara",
}

m["lse"] = {
	canonicalName = "Lusengo",
}

m["lsg"] = {
	canonicalName = "Lyons Sign Language",
	family = "sgn",
}

m["lsh"] = {
	canonicalName = "Lish",
}

m["lsi"] = {
	canonicalName = "Lashi", -- Chashan is either a dialect or needs a code
	otherNames = {"Lacid", "Lachik", "Leqi"},
	family = "tbq-brm",
}

m["lsl"] = {
	canonicalName = "Latvian Sign Language",
	family = "sgn",
}

m["lsm"] = {
	canonicalName = "Saamia",
}

m["lso"] = {
	canonicalName = "Laos Sign Language",
	otherNames = {"Laotian Sign Language"},
	family = "sgn",
}

m["lsp"] = {
	canonicalName = "Panamanian Sign Language",
	family = "sgn",
}

m["lsr"] = {
	canonicalName = "Aruop",
	otherNames = {"Srenge", "Sreengge","Lawu"},
	family = "qfa-tor",
}

m["lss"] = {
	canonicalName = "Lasi",
	scripts = {"Arab"},
	family = "inc",
	ancestors = {"sd"},
}

m["lst"] = {
	canonicalName = "Trinidad and Tobago Sign Language",
	family = "sgn",
}

m["lsy"] = {
	canonicalName = "Mauritian Sign Language",
	family = "sgn",
}

m["ltc"] = {
	canonicalName = "Middle Chinese",
	otherNames = {"Late Middle Chinese", "Early Middle Chinese"},
	scripts = {"Hani"},
	family = "zhx",
	ancestors = {"och"},
}

m["ltg"] = {
	canonicalName = "Latgalian",
	scripts = {"Latn"},
	family = "bat",
}

m["lti"] = {
	canonicalName = "Leti (Indonesia)",
	otherNames = {"Leti"},
	scripts = {"Latn"},
	family = "plf",
}

m["ltn"] = {
	canonicalName = "Latundê",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["lto"] = {
	canonicalName = "Olutsotso",
}

m["lts"] = {
	canonicalName = "Lutachoni",
}

m["ltu"] = {
	canonicalName = "Latu",
}

m["lua"] = {
	canonicalName = "Tshiluba",
	scripts = {"Latn"},
	family = "bnt",
}

m["luc"] = {
	canonicalName = "Aringa",
}

m["lud"] = {
	canonicalName = "Ludian",
	otherNames = {"Ludic", "Lude"},
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["lue"] = {
	canonicalName = "Luvale",
}

m["luf"] = {
	canonicalName = "Laua",
}

m["lui"] = {
	canonicalName = "Luiseño",
	otherNames = {"Luiseno", "Juaneño", "Juaneno"},
	scripts = {"Latn"},
	family = "azc-cup",
	entry_name = {
		from = {"̂", ACUTE},
		to   = {}
	},
}

m["luj"] = {
	canonicalName = "Luna",
}

m["luk"] = {
	canonicalName = "Lunanakha",
}

m["lul"] = {
	canonicalName = "Olu'bo",
}

m["lum"] = {
	canonicalName = "Luimbi",
}

m["lun"] = {
	canonicalName = "Lunda",
	scripts = {"Latn"},
	family = "bnt",
}

m["luo"] = {
	canonicalName = "Luo",
	otherNames = {"Dholuo"},
	scripts = {"Latn"},
	family = "sdv",
}

m["lup"] = {
	canonicalName = "Lumbu",
}

m["luq"] = {
	canonicalName = "Lucumi",
}

m["lur"] = {
	canonicalName = "Laura",
}

m["lus"] = {
	canonicalName = "Mizo",
	otherNames = {"Lushai", "Lushei"},
	scripts = {"Latn"},
	family = "tbq-kuk",
}

m["lut"] = {
	canonicalName = "Lushootseed",
	scripts = {"Latn"},
	family = "sal",
}

m["luu"] = {
	canonicalName = "Lumba-Yakkha",
}

m["luv"] = {
	canonicalName = "Luwati",
}

m["luy"] = {
	canonicalName = "Luhya",
	scripts = {"Latn"},
	family = "bnt",
}

m["luz"] = {
	canonicalName = "Southern Luri",
	scripts = {"fa-Arab"},
	family = "ira",
	ancestors = {"pal"},
}

m["lva"] = {
	canonicalName = "Maku'a",
}

m["lvk"] = {
	canonicalName = "Lavukaleve",
	scripts = {"Latn"},
	family = "paa",
}

m["lvu"] = {
	canonicalName = "Levuka",
}

m["lwa"] = {
	canonicalName = "Lwalu",
}

m["lwe"] = {
	canonicalName = "Lewo Eleng",
}

m["lwg"] = {
	canonicalName = "Oluwanga",
}

m["lwh"] = {
	canonicalName = "White Lachi",
}

m["lwl"] = {
	canonicalName = "Eastern Lawa",
	family = "aav",
}

m["lwm"] = {
	canonicalName = "Laomian",
	family = "tbq-lol",
}

m["lwo"] = {
	canonicalName = "Luwo",
	family = "sdv",
}

m["lwt"] = {
	canonicalName = "Lewotobi",
}

m["lwu"] = {
	canonicalName = "Lawu",
}

m["lww"] = {
	canonicalName = "Lewo",
	family = "poz-vnc",
}

m["lya"] = {
	canonicalName = "Layakha",
}

m["lyg"] = {
	canonicalName = "Lyngngam",
	family = "aav",
}

m["lyn"] = {
	canonicalName = "Luyana",
}

m["lzh"] = {
	canonicalName = "Literary Chinese",
	scripts = {"Hani"},
	family = "zhx",
	wikimedia_codes = {"zh-classical"},
}

m["lzl"] = {
	canonicalName = "Litzlitz",
	family = "poz-vnc",
}

m["lzn"] = {
	canonicalName = "Leinong Naga",
}

m["lzz"] = {
	canonicalName = "Laz",
	scripts = {"Geor", "Latn"},
	family = "ccs-zan",
	translit_module = "Geor-translit",
	entry_name = {
		from = {"̂", GRAVE, ACUTE},
		to   = {}},
}

return m