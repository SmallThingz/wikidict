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

m["laa"] = {
	"Lapuyan Subanun",
	"Q12635302",
	"phi",
}

m["lab"] = {
	"Linear A",
	nil,
}

m["lac"] = {
	"Lacandon",
	"Q35766",
	"myn",
	otherNames = {"Jach t’aan", "Hach t’an"},
}

m["lad"] = {
	"Ладино",
	"Q36196",
	"roa",
	otherNames = {"Judaeo-Spanish", "Judæo-Spanish", "Judeo-Spanish"},
	scripts = {"Hebr", "Latn", "Cyrl"},
	ancestors = {"osp"},
}

m["lae"] = {
	"Pattani",
	"Q7148323",
}

m["laf"] = {
	"Lafofa",
	"Q35711",
}

m["lag"] = {
	"Langi",
	"Q584983",
}

m["lah"] = {
	"Lahnda",
	"Q1334774",
	"inc",
	otherNames = {"Western Punjabi"},
	scripts = {"pa-Arab"},
	ancestors = {"pa"},
}

m["lai"] = {
	"Lambya",
	"Q6481626",
}

m["laj"] = {
	"Lango (Uganda)",
	"Q35670",
	"sdv",
	otherNames = {"Lango", "Leb Lango"}, -- the last, though listed in Ethnologue, is not a name but rather the phrase "Lango language"
	scripts = Latn,
}

m["lak"] = {
	"Laka",
	"Q6474529",
	"alv",
	otherNames = {"Laka (Nigeria)"},
}

m["lal"] = {
	"Lalia",
	"Q6480326",
	"bnt",
	scripts = Latn,
}

m["lam"] = {
	"Lamba",
	"Q36098",
	"bnt",
	scripts = Latn,
}

m["lan"] = {
	"Laru",
	"Q3913987",
	"nic-knj",
	scripts = Latn,
}

m["lap"] = {
	"Kabba-Laka",
	"Q6474528",
	"csu-sar",
	otherNames = {"Kabba Laka", "Laka (Chad)", "Laka"},
}

m["laq"] = {
	"Qabiao",
	"Q3436700",
	"qfa-tak",
	otherNames = {"Laqua"},
}

m["lar"] = {
	"Larteh",
	"Q35639",
	"alv-kwa",
	scripts = Latn,
}

m["las"] = {
	"Gur Lama",
	"Q35652",
	"nic-gur",
	otherNames = {"Lama (West Africa)", "Lama (Togo)", "Lama"}, -- contrast 'lay', "Tibeto-Burman Lama"
	scripts = Latn,
}

m["lau"] = {
	"Laba",
	"Q12952694",
}

m["law"] = {
	"Lauje",
	"Q6498258",
	"poz",
	scripts = Latn,
}

m["lax"] = {
	"Tiwa",
	"Q7810466",
	"sit",
	otherNames = {"Lalung"},
	scripts = Latn,
}

m["lay"] = {
	"Lama Bai",
	"Q6480756",
	"sit",
	otherNames = {"Lama (Southeast Asia)", "Lama (Burma)", "Lama (Myanmar)", "Lama", "Northern Bai", "Laemae"}, -- the last two names are ambiguous, and also denote another Bai language
}

m["laz"] = {
	"Aribwatsa",
	"Q3502104",
	"poz-ocw",
	scripts = Latn,
}

m["lba"] = {
	"Lui",
	"Q23009966",
	"sit",
	ancestors = {"kdv"},
}

m["lbb"] = {
	"Label",
	"Q3214296",
	"poz-ocw",
	scripts = Latn,
}

m["lbc"] = {
	"Lakkia",
	"Q3027879",
	"qfa-tak",
	otherNames = {"Lakkja"},
}

m["lbe"] = {
	"Lak",
	"Q36206",
	"cau-nec",
	scripts = {"Cyrl"},
	translit_module = "lbe-translit",
	override_translit = true,
}

m["lbf"] = {
	"Tinani",
	"Q784502",
}

m["lbg"] = {
	"Laopang",
	"Q12952711",
	"tbq-lol",
}

m["lbi"] = {
	"La'bi",
	"Q6460637",
}

m["lbj"] = {
	"Ladakhi",
	"Q35833",
	otherNames = {"Bhoti"},
	translit_module = "bo-translit",
}

m["lbk"] = {
	"Central Bontoc",
	nil,
	"phi",
	otherNames = {"Central Bontok", "Igorot Bontoc", "Igorot Bontok", "Bontok Igorot", "Bontoc", "Bontok", "Finallig"},
	scripts = Latn,
}

m["lbl"] = {
	"Libon Bikol",
	"Q18664462",
	"phi",
}

m["lbm"] = {
	"Lodhi",
	"Q6666374",
	"mun",
}

m["lbn"] = {
	"Lamet",
	"Q3216723",
	"aav-pal",
}

m["lbo"] = {
	"Laven",
	"Q6298648",
	"aav-ban",
	otherNames = {"Loven", "Boloven", "Jru'", "Jruq", "Jru", "Boriwen", "Jaru", "Lawen", "Laweenjru"},
	scripts = Latn,
}

m["lbq"] = {
	"Wampar",
	"Q7966946",
	"poz-ocw",
	scripts = Latn,
}

m["lbr"] = {
	"Northern Lorung",
	"Q6668040",
	otherNames = {"Northern Lohorung"},
}

m["lbs"] = {
	"Libyan Sign Language",
	"Q11775688",
	"sgn",
}

m["lbt"] = {
	"Lachi",
	"Q6583606",
}

m["lbu"] = {
	"Labu",
	"Q6467660",
	"poz-ocw",
	scripts = Latn,
}

m["lbv"] = {
	"Lavatbura-Lamusong",
	"Q2405981",
	"poz-ocw",
	otherNames = {"Lavatbura", "Lamusong", "Lamasong"},
	scripts = Latn,
}

m["lbw"] = {
	"Tolaki",
	"Q3033597",
	"poz-btk",
	scripts = Latn,
}

m["lbx"] = {
	"Lawangan",
	"Q3120345",
	"poz-bre",
	scripts = Latn,
}

m["lby"] = {
	"Lamu-Lamu",
	"Q6482727",
	scripts = Latn,
}

m["lbz"] = {
	"Lardil",
	"Q3915688",
	"aus-tnk",
	otherNames = {"Leerdil", "Leertil", "Damin", "Demiin"},
	scripts = Latn,
}

m["lcc"] = {
	"Legenyem",
	"Q12952713",
	"poz-hce",
	scripts = Latn,
}

m["lcd"] = {
	"Lola",
	"Q6668867",
	"poz-cet",
	scripts = Latn,
}

m["lce"] = {
	"Loncong",
	"Q3058192",
}

m["lcf"] = {
	"Lubu",
	"Q3264685",
}

m["lch"] = {
	"Luchazi",
	"Q3265143",
}

m["lcl"] = {
	"Lisela",
	"Q6558753",
	"poz-cet",
	scripts = Latn,
}

m["lcm"] = {
	"Tungag",
	"Q3542085",
	"poz-ocw",
	otherNames = {"Lavongai", "Tungak"},
	scripts = Latn,
}

m["lcp"] = {
	"Western Lawa",
	"Q18644465",
	"aav",
	scripts = {"Thai", "Latn"},
}

m["lcq"] = {
	"Luhu",
	"Q6699890",
	"poz-cet",
	otherNames = {"Piru"},
	scripts = Latn,
}

m["lcs"] = {
	"Lisabata-Nuniali",
	"Q6558534",
}

m["lda"] = {
	"Kla",
	nil,
	"dmn",
	scripts = Latn,
}

m["ldb"] = {
	"Idun",
	"Q3914441",
	"nic-bco",
	scripts = Latn,
}

m["ldd"] = {
	"Luri (Nigeria)",
	"Q4701277",
	"cdc-wst",
}

m["ldg"] = {
	"Lenyima",
	"Q3914423",
	"nic-bco",
	scripts = Latn,
}

m["ldh"] = {
	"Lamja-Dengsa-Tola",
	"Q11001739",
}

m["ldj"] = {
	"Lemoro",
	"Q3912761",
}

m["ldk"] = {
	"Leelau",
	"Q3914465",
}

m["ldl"] = {
	"Kaan",
	"Q3914501",
}

m["ldm"] = {
	"Landoma",
	"Q35568",
}

m["ldn"] = {
	"Láadan",
	"Q35757",
	"art",
	type = "appendix-constructed",
	scripts = Latn,
}

m["ldo"] = {
	"Loo",
	"Q3915378",
}

m["ldp"] = {
	"Tso",
	"Q3913953",
	"nic-gur",
}

m["ldq"] = {
	"Lufu",
	"Q35796",
	"alv",
	scripts = Latn,
}

m["lea"] = {
	"Lega-Shabunda",
	"Q12952719",
	otherNames = {"Lega-Malinga", "Lega Malinga", "Lega Shabunda", "Shabunda Lega", "Upper Lega", "Lower Lega", "Forest Lega", "Western Lega", "Southern Lega", "Liga", "Kiliga", "Lega", "Kilega", "KiLega", "Kanu", "Kikanu", "Gala", "Kigala", "Yoma", "Kiyoma", "Sede", "Kisede", "Gonzabale", "Beya", "Beia", "Nyamunsange", "KiNyamunsange", "Banagabo", "Kabango", "Bene"},
}

m["leb"] = {
	"Lala-Bisa",
	"Q6480112",
}

m["lec"] = {
	"Leco",
	"Q2625398",
	"qfa-iso",
}

m["led"] = {
	"Lendu",
	"Q523823",
	"csu",
	scripts = Latn,
}

m["lee"] = {
	"Lyélé",
	"Q3089032",
}

m["lef"] = {
	"Lelemi",
	"Q35585",
}

m["leh"] = {
	"Lenje",
	"Q6522666",
}

m["lei"] = {
	"Lemio",
	"Q6521165",
}

m["lej"] = {
	"Lengola",
	"Q6522474",
}

m["lek"] = {
	"Leipon",
	"Q3229216",
	"poz-aay",
	scripts = Latn,
}

m["lel"] = {
	"Bashilele",
	"Q56733",
	"bnt",
	otherNames = {"Lele (Congo)", "Lele (Democratic Republic of the Congo)", "Lele", "Usilele"},
}

m["lem"] = {
	"Nomaande",
	"Q13479983",
	"nic-bod",
	scripts = Latn,
}

m["len"] = {
	"Honduran Lenca",
	"Q36189",
	"nai-len",
	otherNames = {"Lenca", "Lencan"},
	scripts = Latn,
}

m["leo"] = {
	"Leti (Cameroon)",
	"Q1345684",
	"nic-bco",
	otherNames = {"Leti"}, -- Ethnologue says this secret language has never had native speakers or been written
}

m["lep"] = {
	"Lepcha",
	"Q35990",
	"tbq",
	scripts = {"Lepc"},
	translit_module = "lep-translit",
}

m["leq"] = {
	"Lembena",
	"Q6521067",
}

m["ler"] = {
	"Lenkau",
	"Q3229472",
	"poz-aay",
	scripts = Latn,
}

m["les"] = {
	"Lese",
	"Q11033939",
}

m["let"] = {
	"Lesing-Gelimi",
	"Q12635445",
	"poz-ocw",
	scripts = Latn,
}

m["leu"] = {
	"Kara (New Guinea)",
	"Q3192889",
	"poz-ocw",
	otherNames = {"Kara (Papua New Guinea)", "Kara", "Lemakot"},
	scripts = Latn,
}

m["lev"] = {
	"Lamma",
	"Q6583582",
	"ngf",
}

m["lew"] = { -- this code was basically assigned as a catch-all for things that aren't brs, kzf or unz
	"Ledo Kaili",
	"Q35877",
	"poz-kal",
	otherNames = {"Rai", "Tara", "Ta'a", "Taa", "Central Kaili", "East Kaili", "Ledo", "Edo", "Ado", "Doi", "Ija", "Tawaili", "Palu", "Parigi", "Sigi"},
	scripts = Latn,
}

m["lex"] = {
	"Luang",
	"Q6695015",
	"poz",
}

m["ley"] = {
	"Lemolang",
	"Q3033560",
}

m["lez"] = {
	"Lezgi",
	"Q31746",
	"cau-lzg",
	otherNames = {"Lezgian", "Lezgin"},
	scripts = {"Cyrl"},
	translit_module = "lez-translit",
	override_translit = true,
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["lfa"] = {
	"Lefa",
	"Q35643",
}

m["lfn"] = {
	"Lingua Franca Nova",
	"Q146803",
	"art",
	type = "appendix-constructed",
	scripts = {"Latn", "Cyrl"},
}

m["lga"] = {
	"Lungga",
	"Q3267590",
	"poz-ocw",
	scripts = Latn,
}

m["lgb"] = {
	"Laghu",
	"Q3216169",
	"poz-ocw",
	scripts = Latn,
}

m["lgg"] = {
	"Lugbara",
	"Q3272737",
	"csu",
}

m["lgh"] = {
	"Laghuu",
	"Q6472114",
	"tbq-lol",
	otherNames = {"Xá Phó", "Phù Lá Lão"},
}

m["lgi"] = {
	"Lengilu",
	"Q6522465",
	"poz-swa",
	scripts = Latn,
}

m["lgk"] = {
	"Neverver",
	"Q3241515",
	"poz-vnc",
	otherNames = {"Lingarak"},
	scripts = Latn,
}

m["lgl"] = {
	"Wala",
	"Q3565284",
	"poz-sls",
}

m["lgm"] = {
	"Lega-Mwenga",
	"Q14916883",
	"bnt",
	otherNames = {"Lega-Ntara", "Lega Ntara", "Lega Mwenga", "Mwenga Lega", "Lower Lega", "Upper Lega", "Eastern Lega", "Northern Lega", "Isile", "Ishile", "Kisile", "Mwenda-Liga"},
}

m["lgn"] = {
	"Opuuo",
	"Q3354339",
	otherNames = {"Opo", "Opuo", "Opo-Shita", "Shita", "Shiita", "Cita", "Ciita", "Ansita", "Kina", "Kwina", "T'apo"},
}

m["lgq"] = {
	"Logba",
	"Q35813",
	"alv-kwa",
	otherNames = {"Ikpana"},
	scripts = Latn,
}

m["lgr"] = {
	"Lengo",
	"Q3229454",
	"poz-sls",
	scripts = Latn,
}

m["lgt"] = {
	"Pahi",
	"Q7124545",
	"paa-spk",
	scripts = Latn,
}

m["lgu"] = {
	"Longgu",
	"Q3259105",
	"poz-sls",
}

m["lgz"] = {
	"Ligenza",
	"Q5531038",
}

m["lha"] = {
	"Laha (Vietnam)",
	"Q3112363",
	"qfa-tak",
	otherNames = {"Laha", "La Ha"},
}

m["lhh"] = {
	"Laha (Indonesia)",
	"Q6473107",
	"poz",
	otherNames = {"Laha", "Central Ambon"},
}

m["lhi"] = {
	"Lahu Shi",
	"Q25559457",
	"tbq-lol",
}

m["lhl"] = {
	"Lahul Lohar",
	"Q12953672",
}

m["lhn"] = {
	"Lahanan",
	"Q12953660",
}

m["lhp"] = {
	"Lhokpu",
	"Q3436603",
	"sit",
}

m["lhs"] = {
	"Mlahsö",
	"Q3393063",
	"sem-ara",
}

m["lht"] = {
	"Lo-Toga",
	"Q3257566",
	"poz-vnc",
	scripts = Latn,
}

m["lhu"] = {
	"Lahu",
	"Q35780",
	"tbq-lol",
}

m["lia"] = {
	"West-Central Limba",
	"Q32867815",
}

m["lib"] = {
	"Likum",
	"Q3240737",
	"poz-aay",
	scripts = Latn,
}

m["lic"] = {
	"Hlai",
	"Q934738",
	"qfa-lic",
	otherNames = {"Bouhin", "Heitu", "Ha Em", "Zhongsha", "Lauhut", "Baoding", "Tongzha", "Tongshi", "Zandui", "Baoting", "Nadou", "Dongfang", "Changjiang", "Moyjaw", "Xifang", "Baisha", "Yuanmen"}, -- some of these may need to be split off as languages
	scripts = Latn,
}

m["lid"] = {
	"Nyindrou",
	"Q3346666",
	"poz-aay",
	scripts = Latn,
}

m["lie"] = {
	"Likila",
	"Q11011614",
}

m["lif"] = {
	"Limbu",
	"Q56477",
	"tbq",
	scripts = {"Limb"},
	translit_module = "lif-translit",
}

m["lig"] = {
	"Ligbi",
	"Q33594",
	"dmn",
}

m["lih"] = {
	"Lihir",
	"Q6546938",
	"poz-ocw",
	scripts = Latn,
}

m["lii"] = {
	"Lingkhim",
	"Q12635536",
}

m["lij"] = {
	"Ligurian",
	"Q36106",
	"roa",
	scripts = Latn,
}

m["lik"] = {
	"Lika",
	"Q1530394",
}

m["lil"] = {
	"Lillooet",
	"Q34154",
}

m["lio"] = {
	"Liki",
	"Q4261493",
	"poz-ocw",
	scripts = Latn,
}

m["lip"] = {
	"Sekpele",
	"Q36257",
}

m["liq"] = {
	"Libido",
	"Q35691",
	"cus",
}

m["lir"] = {
	"Liberian English",
	"Q6541128",
}

m["lis"] = {
	"Lisu",
	"Q56480",
	"tbq-lol",
	scripts = {"Lisu"},
}

m["liu"] = {
	"Logorik",
	"Q6667811",
	"sdv",
}

m["liv"] = {
	"Livonian",
	"Q33698",
	"fiu-fin",
	scripts = Latn,
	entry_name = {
		from = {u(0x01ed), u(0x0027), u(0x2019)},
		to   = {u(0x014d)}},
}

m["liw"] = {
	"Col",
	"Q2981948",
}

m["lix"] = {
	"Liabuku",
	"Q13580912",
}

m["liy"] = {
	"Banda-Bambari",
	"Q11051591",
}

m["liz"] = {
	"Libinza",
	"Q4914576",
}

m["lja"] = {
	"Golpa",
	nil,
	"aus-yol",
	scripts = Latn,
}

m["lje"] = {
	"Rampi",
	"Q7290041",
	"poz",
}

m["lji"] = {
	"Laiyolo",
	"Q6474218",
}

m["ljl"] = {
	"Li'o",
	"Q2697010",
	"poz",
}

m["ljp"] = {
	"Lampung Api",
	"Q49215",
	"poz-lgx",
	scripts = Latn,
}

m["ljw"] = {
	"Yirandali",
	"Q17059380",
}

m["ljx"] = {
	"Yuru",
	nil,
}

m["lka"] = {
	"Lakalei",
	"Q12952700",
	"poz-cet",
	scripts = Latn,
}

m["lkb"] = {
	"Kabras",
	nil,
}

m["lkc"] = {
	"Kucong",
	"Q6441572",
	"tbq-lol",
}

m["lkd"] = {
	"Lakondê",
	"Q20527166",
	"sai-nmk",
	scripts = Latn,
}

m["lke"] = {
	"Kenyi",
	"Q12952628",
}

m["lkh"] = {
	"Lakha",
	"Q56606",
}

m["lki"] = {
	"Laki",
	"Q56483",
	"ira-wes",
	scripts = {"fa-Arab"},
	ancestors = {"pal"},
}

m["lkj"] = {
	"Remun",
	"Q7312239",
}

m["lkl"] = {
	"Laeko-Libuat",
	"Q3504331",
	"qfa-tor",
}

m["lkm"] = {
	"Kalaamaya",
	"Q6349988",
}

m["lkn"] = {
	"Lakon",
	"Q3216494",
	"poz-vnc",
	scripts = Latn,
}

m["lko"] = {
	"Khayo",
	"Q6401095",
}

m["lkr"] = {
	"Päri",
	"Q36487",
	"sdv",
}

m["lks"] = {
	"Kisa",
	nil,
}

m["lkt"] = {
	"Lakota",
	"Q33537",
	"sio",
	otherNames = {"Lakhota"},
	scripts = Latn,
}

m["lku"] = {
	"Kungkari",
	"Q6444526",
}

m["lky"] = {
	"Lokoya",
	"Q56687",
	"sdv",
}

m["lla"] = {
	"Lala-Roba",
	"Q3914878",
}

m["llb"] = {
	"Lolo",
	"Q11006056",
}

m["llc"] = {
	"Lele (Guinea)",
	"Q6520837",
	"dmn",
	otherNames = {"Lele"},
}

m["lld"] = {
	"Ladin",
	"Q36202",
	"roa-rhe",
	scripts = Latn,
}

m["lle"] = {
	"Lele (New Guinea)",
	"Q3229269",
	"poz-oce",
	otherNames = {"Lele (Papua New Guinea)", "Lele", "Lele Hai"},
	scripts = Latn,
}

m["llf"] = {
	"Hermit",
	"Q3134240",
	"poz-aay",
	scripts = Latn,
}

m["llg"] = {
	"Lole",
	"Q6668883",
	"poz-cet",
}

m["llh"] = {
	"Lamu",
	"Q6482736",
	"tbq-lol",
}

m["lli"] = {
	"Teke-Laali",
	"Q36543",
}

m["llj"] = {
	"Ladji-Ladji",
	"Q6512694",
	"aus-pam",
	otherNames = {"Ledji-Ledji"},
}

m["llk"] = {
	"Lelak",
	"Q3229263",
	"poz-swa",
	scripts = Latn,
}

m["lll"] = {
	"Lilau",
	"Q6547570",
	"qfa-tor",
}

m["llm"] = {
	"Lasalimu",
	"Q6492774",
}

m["lln"] = {
	"Lele (Chad)",
	"Q1641493",
	"cdc-est",
	otherNames = {"Lele"},
}

m["llo"] = {
	"Khlor",
	"Q27921409",
	"mkh-kat",
}

m["llp"] = {
	"North Efate",
	"Q3580152",
	"poz-vnc",
	otherNames = {"Efate", "Vate", "Vaté", "Nguna"},
	scripts = Latn,
}

m["llq"] = {
	"Lolak",
	"Q12953679",
	"phi",
}

m["lls"] = {
	"Lithuanian Sign Language",
	"Q3915480",
	"sgn",
}

m["llu"] = {
	"Lau",
	"Q3218574",
	"poz-sls",
	scripts = Latn,
}

m["llx"] = {
	"Lauan",
	"Q35682",
	"poz-occ",
	scripts = Latn,
}

m["lma"] = {
	"East Limba",
	"Q11034212",
}

m["lmb"] = {
	"Merei",
	"Q12952843",
	"poz-vnc",
	scripts = Latn,
}

m["lmc"] = {
	"Limilngan",
	"Q6549414",
}

m["lmd"] = {
	"Lumun",
	"Q35777",
}

m["lme"] = {
	"Pévé",
	"Q56249",
}

m["lmf"] = {
	"South Lembata",
	"Q7567815",
}

m["lmg"] = {
	"Lamogai",
	"Q278365",
	"poz-ocw",
	scripts = Latn,
}

m["lmh"] = {
	"Lambichhong",
	"Q6481472",
}

m["lmi"] = {
	"Lombi",
	"Q11259563",
}

m["lmj"] = {
	"West Lembata",
	"Q6864697",
}

m["lmk"] = {
	"Lamkang",
	"Q12952703",
	"tbq-kuk",
}

m["lml"] = {
	"Raga",
	"Q3063193",
	"poz-vnc",
	otherNames = {"Hano", "Bwatvenua", "Lamalanga", "Vunmarama", "Loltong"},
	scripts = Latn,
}

m["lmn"] = {
	"Lambadi",
	"Q33474",
	"inc",
	otherNames = {"Banjari", "Goar-boali"},
	ancestors = {"raj"},
}

m["lmo"] = {
	"Lombard",
	"Q33754",
	"roa",
	scripts = Latn,
}

m["lmp"] = {
	"Limbum",
	"Q35801",
	"nic-bod",
	scripts = Latn,
}

m["lmq"] = {
	"Lamatuka",
	"Q6480982",
}

m["lmr"] = {
	"Lamalera",
	"Q6480787",
}

m["lmu"] = {
	"Lamenu",
	"Q740604",
	"poz-vnc",
	scripts = Latn,
}

m["lmv"] = {
	"Lomaiviti",
	"Q3130221",
	"poz-occ",
	scripts = Latn,
}

m["lmw"] = {
	"Lake Miwok",
	"Q3216471",
	"nai-you",
	scripts = Latn,
}

m["lmx"] = {
	"Laimbue",
	"Q6473933",
}

m["lmy"] = {
	"Lamboya",
	"Q6481538",
	"poz-cet",
	scripts = { "Latn" },
}

m["lmz"] = {
	"Lumbee",
	"Q12635887",
	scripts = Latn,
}

m["lna"] = {
	"Langbashe",
	"Q11137550",
}

m["lnb"] = {
	"Mbalanhu",
	"Q12952830",
}

m["lnd"] = {
	"Lun Bawang",
	"Q13479839",
	"poz-swa",
	scripts = Latn,
}

m["lnh"] = {
	"Lanoh",
	"Q6487291",
}

m["lni"] = {
	"Daantanai'",
	"Q5207384",
}

m["lnj"] = {
	"Linngithigh",
	"Q3915694",
	otherNames = {"Linngithig", "Leningitij"},
}

m["lnl"] = {
	"South Central Banda",
	"Q41354532",
}

m["lnm"] = {
	"Langam",
	"Q6485678",
	"paa",
	scripts = Latn,
}

m["lnn"] = {
	"Lorediakarkar",
	"Q6680287",
	"poz-vnc",
	scripts = Latn,
}

m["lno"] = {
	"Lango (Sudan)",
	"Q223306",
	"sdv",
	otherNames = {"Lango", "Lango (South Sudan)", "Langgo"},
}

m["lns"] = {
	"Lamnso'",
	"Q35788",
}

m["lnu"] = {
	"Longuda",
	"Q35797",
	"nic",
	scripts = Latn,
}

m["lnw"] = {
	"Lanima",
	nil,
	"aus-pam",
	scripts = Latn,
}

m["lnz"] = {
	"Lonzo",
	"Q11002185",
	"nic-bco",
	scripts = Latn,
}

m["loa"] = {
	"Loloda",
	"Q6669025",
	"paa",
	scripts = Latn,
}

m["lob"] = {
	"Lobi",
	"Q35807",
}

m["loc"] = {
	"Inonhan",
	"Q2400870",
	"phi",
}

m["lod"] = {
	"Berawan",
	"Q4891018",
	"poz-swa",
	otherNames = {"Central Berawan", "East Berawan", "West Berawan", "Long Terawan", "Batu Belah", "Long Teru", "Long Jegan", "Long Pata"},
	scripts = Latn,
}

m["loe"] = {
	"Saluan",
	"Q12953867",
	"poz",
}

m["lof"] = {
	"Logol",
	"Q35779",
}

m["log"] = {
	"Logo",
	"Q2613477",
	"csu",
}

m["loh"] = {
	"Narim",
	"Q56353",
	"sdv",
}

m["loi"] = {
	"Lomakka",
	"Q3913961",
	"nic",
	otherNames = {"Loma"},
}

m["loj"] = {
	"Lou",
	"Q3260104",
	"poz-aay",
	scripts = Latn,
}

m["lok"] = {
	"Loko",
	"Q3914912",
	"dmn",
	scripts = Latn,
}

m["lol"] = {
	"Mongo",
	"Q112893",
	"bnt",
	scripts = Latn,
}

m["lom"] = {
	"Looma",
	"Q35885",
	"dmn",
	otherNames = {"Loma"},
}

m["lon"] = {
	"Malawi Lomwe",
	"Q10975286",
}

m["loo"] = {
	"Lombo",
	"Q11167192",
}

m["lop"] = {
	"Lopa",
	"Q3914875",
}

m["loq"] = {
	"Lobala",
	"Q4849710",
}

m["lor"] = {
	"Téén",
	"Q36467",
}

m["los"] = {
	"Loniu",
	"Q3259202",
	"poz-aay",
	scripts = Latn,
}

m["lot"] = {
	"Lotuko",
	"Q56672",
	"sdv",
}

m["lou"] = {
	"Louisiana Creole French",
	"Q1185127",
	"crp",
	otherNames = {"Louisiana Creole", "Kréyol"},
	scripts = Latn,
	ancestors = {"fr"},
}

m["lov"] = {
	"Lopi",
	"Q12952740",
	"tbq-lol",
}

m["low"] = {
	"Tampias Lobu",
	"Q12953674",
}

m["lox"] = {
	"Loun",
	"Q6689636",
	"poz-cet",
	scripts = Latn,
}

m["loz"] = {
	"Lozi",
	"Q33628",
	"bnt",
	scripts = Latn,
}

m["lpa"] = {
	"Lelepa",
	"Q3229273",
	"poz-vnc",
}

m["lpe"] = {
	"Lepki",
	"Q4259152",
}

m["lpn"] = {
	"Long Phuri Naga",
	"Q6673049",
}

m["lpo"] = {
	"Lipo",
	"Q56921",
	"tbq-lol",
	otherNames = {"Eastern Lisu"},
	scripts = {"Plrd"},
}

m["lpx"] = {
	"Lopit",
	"Q56684",
	"sdv",
}

m["lra"] = {
	"Rara Bakati'",
	"Q3419746",
	"day",
}

m["lrc"] = {
	"Northern Luri",
	"Q19933293",
	"ira-wes",
	scripts = {"fa-Arab"},
	ancestors = {"pal"},
}

m["lre"] = {
	"Laurentian",
	"Q1790301",
	"iro",
	otherNames = {"St. Lawrence Iroquoian"},
	scripts = Latn,
}

m["lrg"] = {
	"Laragia",
	"Q2591193",
}

m["lri"] = {
	"Marachi",
	"Q6754565",
}

m["lrk"] = {
	"Loarki",
	"Q6663513",
	otherNames = {"Gade Lohar"},
}

m["lrl"] = {
	"Lari",
	"Q33468",
	"ira-wes",
	otherNames = {"Achomi"},
	scripts = {"fa-Arab"},
}

m["lrm"] = {
	"Marama",
	nil,
}

m["lrn"] = {
	"Lorang",
	"Q6678781",
}

m["lro"] = {
	"Laro",
	"Q35687",
}

m["lrr"] = {
	"Southern Lorung",
	"Q12952742",
	otherNames = {"Yamphe", "Southern Yamphe", "Yamphu", "Southern Yamphu"},
}

m["lrt"] = {
	"Larantuka Malay",
	"Q6488691",
	"poz-mly",
	scripts = Latn,
}

m["lrv"] = {
	"Larevat",
	"Q3217892",
	"poz-vnc",
	scripts = Latn,
}

m["lrz"] = {
	"Lemerig",
	"Q2028448",
	"poz-vnc",
}

m["lsa"] = {
	"Lasgerdi",
	"Q3218296",
	"ira-wes",
}

m["lsd"] = {
	"Lishana Deni",
	"Q3436461",
	"sem-ara",
	otherNames = {"Betanure Jewish Neo-Aramaic"},
	scripts = {"Hebr"},
}

m["lse"] = {
	"Lusengo",
	"Q6683546",
}

m["lsh"] = {
	"Lish",
	"Q6558822",
}

m["lsi"] = {
	"Lashi",
	"Q6493203",
	"tbq-brm",
	otherNames = {"Lacid", "Lachik", "Leqi"},
}

m["lsl"] = {
	"Latvian Sign Language",
	"Q6497414",
	"sgn",
}

m["lsm"] = {
	"Saamia",
	"Q3739441",
}

m["lso"] = {
	"Laos Sign Language",
	"Q6488022",
	"sgn",
	otherNames = {"Laotian Sign Language"},
}

m["lsp"] = {
	"Panamanian Sign Language",
	"Q7129968",
	"sgn",
}

m["lsr"] = {
	"Aruop",
	"Q3450566",
	"qfa-tor",
	otherNames = {"Srenge", "Sreengge","Lawu"},
}

m["lss"] = {
	"Lasi",
	"Q12953669",
	"inc",
	scripts = {"Arab"},
	ancestors = {"sd"},
}

m["lst"] = {
	"Trinidad and Tobago Sign Language",
	"Q7842495",
	"sgn",
}

m["lsy"] = {
	"Mauritian Sign Language",
	"Q6793754",
	"sgn",
}

m["ltc"] = {
	"Средњи Кинески",
	"Q2016252",
	"zhx",
	otherNames = {"Late Middle Chinese", "Early Middle Chinese"},
	scripts = {"Hani"},
	ancestors = {"och"},
}

m["ltg"] = {
	"Latgalian",
	"Q36212",
	"bat",
	scripts = Latn,
}

m["lti"] = {
	"Leti (Indonesia)",
	"Q3236912",
	"poz-cet",
	otherNames = {"Leti"},
	scripts = Latn,
}

m["ltn"] = {
	"Latundê",
	nil,
	"sai-nmk",
	scripts = Latn,
}

m["lto"] = {
	"Olutsotso",
	nil,
}

m["lts"] = {
	"Lutachoni",
	nil,
}

m["ltu"] = {
	"Latu",
	"Q6497181",
}

m["lua"] = {
	"Luba-Kasai",
	"Q34173",
	"bnt",
	otherNames = {"Tshiluba", "Luba"},
	scripts = Latn,
}

m["luc"] = {
	"Aringa",
	"Q56556",
	"csu",
}

m["lud"] = {
	"Ludian",
	"Q33918",
	"fiu-fin",
	otherNames = {"Ludic", "Lude"},
	scripts = Latn,
}

m["lue"] = {
	"Luvale",
	"Q33597",
	"bnt",
	scripts = Latn,
}

m["luf"] = {
	"Laua",
	"Q6497673",
}

m["lui"] = {
	"Luiseño",
	"Q56236",
	"azc-cup",
	otherNames = {"Luiseno", "Juaneño", "Juaneno"},
	scripts = Latn,
	entry_name = {
		from = {"̂", ACUTE},
		to   = {}
	},
}

m["luj"] = {
	"Luna",
	"Q11003832",
}

m["luk"] = {
	"Lunanakha",
	"Q56446",
}

m["lul"] = {
	"Olu'bo",
	"Q6589401",
}

m["lum"] = {
	"Luimbi",
	"Q10963134",
}

m["lun"] = {
	"Lunda",
	"Q33607",
	"bnt",
	scripts = Latn,
}

m["luo"] = {
	"Luo",
	"Q5414796",
	"sdv",
	otherNames = {"Dholuo"},
	scripts = Latn,
}

m["lup"] = {
	"Lumbu",
	"Q35793",
}

m["luq"] = {
	"Lucumi",
	"Q1768321",
}

m["lur"] = {
	"Laura",
	"Q2984540",
}

m["lus"] = {
	"Mizo",
	"Q36147",
	"tbq-kuk",
	otherNames = {"Lushai", "Lushei"},
	scripts = Latn,
}

m["lut"] = {
	"Lushootseed",
	"Q33658",
	"sal",
	scripts = Latn,
}

m["luu"] = {
	"Lumba-Yakkha",
	"Q6703050",
}

m["luv"] = {
	"Luwati",
	"Q33402",
	scripts = {"Khoj"},
}

m["luy"] = {
	"Luhya",
	"Q35893",
	"bnt",
	scripts = Latn,
}

m["luz"] = {
	"Southern Luri",
	"Q12952748",
	"ira-wes",
	scripts = {"fa-Arab"},
	ancestors = {"pal"},
}

m["lva"] = {
	"Maku'a",
	"Q35790",
}

m["lvk"] = {
	"Lavukaleve",
	"Q770547",
	"paa",
	scripts = Latn,
}

m["lvu"] = {
	"Levuka",
	"Q6535860",
}

m["lwa"] = {
	"Lwalu",
	"Q6706953",
}

m["lwe"] = {
	"Lewo Eleng",
	"Q6537465",
}

m["lwg"] = {
	"Oluwanga",
	nil,
}

m["lwh"] = {
	"White Lachi",
	"Q8842956",
	"qfa-tak",
}

m["lwl"] = {
	"Eastern Lawa",
	"Q18644464",
	"aav",
	scripts = {"Thai", "Latn"},
}

m["lwm"] = {
	"Laomian",
	"Q19597674",
	"tbq-lol",
}

m["lwo"] = {
	"Luwo",
	"Q56362",
	"sdv",
	otherNames = {"Jur", "Giur"},
	scripts = Latn,
}

m["lws"] = {
	"Malawian Sign Language",
	"Q47522462",
	"sgn",
}

m["lwt"] = {
	"Lewotobi",
	"Q14916885",
}

m["lwu"] = {
	"Lawu",
	"Q6505073",
}

m["lww"] = {
	"Lewo",
	"Q3237321",
	"poz-vnc",
	scripts = Latn,
}

m["lya"] = {
	"Layakha",
	"Q56602",
}

m["lyg"] = {
	"Lyngngam",
	"Q12635902",
	"aav",
}

m["lyn"] = {
	"Luyana",
	"Q3268098",
}

m["lzh"] = {
	"Literary Chinese",
	"Q37041",
	"zhx",
	scripts = {"Hani"},
	wikimedia_codes = {"zh-classical"},
}

m["lzl"] = {
	"Litzlitz",
	"Q6653424",
	"poz-vnc",
	scripts = Latn,
}

m["lzn"] = {
	"Leinong Naga",
	"Q5924455",
}

m["lzz"] = {
	"Laz",
	"Q1160372",
	"ccs-zan",
	scripts = {"Geor", "Latn"},
	translit_module = "Geor-translit",
	override_translit = true,
	entry_name = {
		from = {"̂", GRAVE, ACUTE},
		to   = {}},
}

return m