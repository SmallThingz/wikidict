local m_langdata = require("Module:languages/data")

-- Loaded on demand, as it may not be needed (depending on the data).
local function u(...)
	u = require("Module:string utilities").char
	return u(...)
end

local c = m_langdata.chars
local p = m_langdata.puaChars
local s = m_langdata.shared

local m = {}

m["laa"] = {
	"Lapuyan Subanun",
	12635302,
	"phi",
}

m["lab"] = {
	"Linear A",
	nil,
}

m["lac"] = {
	"Lacandon",
	35766,
	"myn",
	"Latn",
}

m["lad"] = {
	"Ladino",
	36196,
	"roa-cas",
	"Hebr, Latn, Cyrl",
	display_text = {
		Hebr = "Hebr-common",
	},
	entry_name = {
		Hebr = "Hebr-common",
	},
	sort_key = {
		Hebr = "Hebr-common",
	},
}

m["lae"] = {
	"Pattani",
	7148323,
	"sit-whm",
}

m["laf"] = {
	"Lafofa",
	35711,
	"alv",
}

m["lag"] = {
	"Langi",
	584983,
	"bnt-mra",
}

m["lah"] = {
	"Lahnda",
	1334774,
	"inc-pan",
	"pa-Arab",
	ancestors = "inc-opa",
}

m["lai"] = {
	"Lambya",
	6481626,
	"bnt-mby",
}

m["laj"] = {
	"Lango (Uganda)",
	35670,
	"sdv-los",
	"Latn",
}

m["lak"] = {
	"Laka",
	6474529, -- also Q55616620
	"csu-sar", -- formerly classified as "alv-mbm"; see [[w:Lau Laka language]]
}

m["lam"] = {
	"Lamba",
	36098,
	"bnt-sbi",
	"Latn",
}

m["lan"] = {
	"Laru",
	3913987,
	"nic-knj",
	"Latn",
}

m["lap"] = {
	"Kabba-Laka",
	6474528,
	"csu-sar",
}

m["laq"] = {
	"Qabiao",
	3436700,
	"qfa-kra",
}

m["lar"] = {
	"Larteh",
	35639,
	"alv-gng",
	"Latn",
}

m["las"] = {
	"Gur Lama",
	35652,
	"nic-gne",
	"Latn",
}

m["lau"] = {
	"Laba",
	12952694,
	"paa-nha"
}

m["law"] = {
	"Lauje",
	6498258,
	"poz",
	"Latn",
}

m["lax"] = {
	"Tiwa",
	7810466,
	"tbq-bdg",
	"Latn",
}

m["lay"] = {
	"Lama Bai",
	6480756,
	"sit-nba",
	"Hani, Latn",
	sort_key = {Hani = "Hani-sortkey"},
}

m["laz"] = {
	"Aribwatsa",
	3502104,
	"poz-ocw",
	"Latn",
}

m["lbb"] = {
	"Label",
	3214296,
	"poz-ocw",
	"Latn",
}

m["lbc"] = {
	"Lakkia",
	3027879,
	"qfa-tak",
}

m["lbe"] = {
	"Lak",
	36206,
	"cau-nec",
	"Cyrl, Latn, Arab, Geor",
	translit = "lbe-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
	sort_key = "lbe-sortkey",
}

m["lbf"] = {
	"Tinani",
	784502,
	"sit-whm",
}

m["lbg"] = {
	"Laopang",
	12952711,
	"tbq-bis",
}

m["lbi"] = {
	"La'bi",
	6460637,
	"alv-mbm",
}

m["lbj"] = {
	"Ladakhi",
	35833,
	"sit-lab",
	"Tibt",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["lbk"] = {
	"Central Bontoc",
	63257803,
	"phi",
	"Latn",
}

m["lbl"] = {
	"Libon Bikol",
	18664462,
	"phi",
	"Latn",
}

m["lbm"] = {
	"Lodhi",
	6666374,
	"mun",
}

m["lbn"] = {
	"Lamet",
	3216723,
	"mkh-pal",
}

m["lbo"] = {
	"Laven",
	6298648,
	"mkh-ban",
	"Latn",
}

m["lbq"] = {
	"Wampar",
	7966946,
	"poz-ocw",
	"Latn",
}

m["lbr"] = {
	"Northern Lorung",
	6668040,
	"sit-kie",
}

m["lbs"] = {
	"Libyan Sign Language",
	11775688,
	"sgn",
}

m["lbt"] = {
	"Lachi",
	6583606,
	"qfa-kra",
}

m["lbu"] = {
	"Labu",
	6467660,
	"poz-ocw",
	"Latn",
}

m["lbv"] = {
	"Lavatbura-Lamusong",
	2405981,
	"poz-ocw",
	"Latn",
}

m["lbw"] = {
	"Tolaki",
	3033597,
	"poz-btk",
	"Latn",
}

m["lbx"] = {
	"Lawangan",
	3120345,
	"poz-bre",
	"Latn",
}

m["lby"] = {
	"Lamu-Lamu",
	6482727,
	nil,
	"Latn",
}

m["lbz"] = {
	"Lardil",
	3915688,
	"aus-tnk",
	"Latn",
}

m["lcc"] = {
	"Legenyem",
	12952713,
	"poz-hce",
	"Latn",
}

m["lcd"] = {
	"Lola",
	6668867,
	"poz-cet",
	"Latn",
}

m["lce"] = {
	"Loncong",
	3058192,
}

m["lcf"] = {
	"Lubu",
	3264685,
}

m["lch"] = {
	"Luchazi",
	3265143,
	"bnt-clu",
}

m["lcl"] = {
	"Lisela",
	6558753,
	"poz-cma",
	"Latn",
}

m["lcm"] = {
	"Tungag",
	3542085,
	"poz-ocw",
	"Latn",
}

m["lcp"] = {
	"Western Lawa",
	18644465,
	"mkh-pal",
	"Thai",
	sort_key = "Thai-sortkey",
}

m["lcq"] = {
	"Luhu",
	6699890,
	"poz-cma",
	"Latn",
}

m["lcs"] = {
	"Lisabata-Nuniali",
	6558534,
}

m["lda"] = {
	"Kla",
	63257856,
	"dmn-mda",
	"Latn",
}

m["ldb"] = {
	"Idun",
	3914441,
	"nic-plc",
	"Latn",
}

m["ldd"] = {
	"Luri (Nigeria)",
	4701277,
	"cdc-wst",
}

m["ldg"] = {
	"Lenyima",
	3914423,
	"nic-uce",
	"Latn",
}

m["ldh"] = {
	"Lamja-Dengsa-Tola",
	11001739,
	"nic-dak",
}

m["ldj"] = {
	"Lemoro",
	3912761,
	"nic-jer",
}

m["ldk"] = {
	"Leelau",
	3914465,
	"alv-bwj",
}

m["ldl"] = {
	"Kaan",
	3914501,
	"alv-yun",
}

m["ldm"] = {
	"Landoma",
	35568,
	"alv-mel",
}

m["ldn"] = {
	"Láadan",
	35757,
	"art",
	"Latn",
	type = "appendix-constructed",
}

m["ldo"] = {
	"Loo",
	3915378,
	"alv-bwj",
}

m["ldp"] = {
	"Tso",
	3913953,
	"alv-wjk",
}

m["ldq"] = {
	"Lufu",
	35796,
	"nic-ykb",
	"Latn",
}

m["lea"] = {
	"Lega-Shabunda",
	12952719,
	"bnt-lgb",
}

m["leb"] = {
	"Lala-Bisa",
	6480112,
	"bnt-sbi",
}

m["lec"] = {
	"Leco",
	2625398,
	"qfa-iso",
}

m["led"] = {
	"Lendu",
	523823,
	"csu-lnd",
	"Latn",
}

m["lee"] = {
	"Lyélé",
	3089032,
	"nic-gnn",
}

m["lef"] = {
	"Lelemi",
	35585,
	"alv-ntg",
}

m["leh"] = {
	"Lenje",
	6522666,
	"bnt-bot",
}

m["lei"] = {
	"Lemio",
	6521165,
	"ngf-mad",
}

m["lej"] = {
	"Lengola",
	6522474,
	"bnt-leb",
}

m["lek"] = {
	"Leipon",
	3229216,
	"poz-aay",
	"Latn",
}

m["lel"] = {
	"Lele (Congo)",
	56733,
	"bnt-bsh",
}

m["lem"] = {
	"Nomaande",
	13479983,
	"nic-mbw",
	"Latn",
}

m["len"] = {
	"Honduran Lenca",
	36189,
	"nai-len",
	"Latn",
}

m["leo"] = {
	"Mengisa",
	1345684,
	"nic-mba",
	ancestors = "bag",
}

m["lep"] = {
	"Lepcha",
	35990,
	"sit",
	"Lepc",
	translit = "lep-translit",
}

m["leq"] = {
	"Lembena",
	6521067,
	"paa-eng",
}

m["ler"] = {
	"Lenkau",
	3229472,
	"poz-aay",
	"Latn",
}

m["les"] = {
	"Lese",
	11033939,
	"csu-mle",
}

m["let"] = {
	"Lesing-Gelimi",
	12635445,
	"poz-ocw",
	"Latn",
}

m["leu"] = {
	"Kara (New Guinea)",
	3192889,
	"poz-ocw",
	"Latn",
}

m["lev"] = {
	"Lamma",
	6583582,
	"ngf",
}

m["lew"] = { -- this code was basically assigned as a catch-all for things that aren't brs, kzf or unz
	"Ledo Kaili",
	35877,
	"poz-kal",
	"Latn",
}

m["lex"] = {
	"Luang",
	6695015,
	"poz-tim",
}

m["ley"] = {
	"Lemolang",
	3033560,
}

m["lez"] = {
	"Lezgi",
	31746,
	"cau-esm",
	"Cyrl, Latn, Arab",
	translit = "lez-translit",
	override_translit = true,
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
}

m["lfa"] = {
	"Lefa",
	35643,
	"bnt-baf",
}

m["lfn"] = {
	"Lingua Franca Nova",
	146803,
	"art",
	"Latn, Cyrl",
	type = "appendix-constructed",
}

m["lga"] = {
	"Lungga",
	3267590,
	"poz-ocw",
	"Latn",
}

m["lgb"] = {
	"Laghu",
	3216169,
	"poz-ocw",
	"Latn",
}

m["lgg"] = {
	"Lugbara",
	3272737,
	"csu-mma",
}

m["lgh"] = {
	"Laghuu",
	6472114,
	"tbq-muj",
}

m["lgi"] = {
	"Lengilu",
	6522465,
	"poz-swa",
	"Latn",
}

m["lgk"] = {
	"Neverver",
	3241515,
	"poz-vnc",
	"Latn",
}

m["lgl"] = {
	"Wala",
	3565284,
	"poz-sls",
}

m["lgm"] = {
	"Lega-Mwenga",
	14916883,
	"bnt-lgb",
}

m["lgn"] = {
	"Opuuo",
	3354339,
	"ssa-kom",
}

m["lgq"] = {
	"Logba",
	35813,
	"alv-ntg",
	"Latn",
}

m["lgr"] = {
	"Lengo",
	3229454,
	"poz-sls",
	"Latn",
}

m["lgs"] = {
	"Guinea-Bissau Sign Language",
	5616441,
	"sgn",
}

m["lgt"] = {
	"Pahi",
	7124545,
	"paa-spk",
	"Latn",
}

m["lgu"] = {
	"Longgu",
	3259105,
	"poz-sls",
}

m["lgz"] = {
	"Ligenza",
	5531038,
	"bnt-bun",
}

m["lha"] = {
	"Laha (Vietnam)",
	3112363,
	"qfa-kra",
}

m["lhh"] = {
	"Laha (Indonesia)",
	6473107,
	"poz-cma",
}

m["lhi"] = {
	"Lahu Shi",
	25559457,
	"tbq-lho",
}

m["lhl"] = {
	"Lahul Lohar",
	12953672,
}

m["lhn"] = {
	"Lahanan",
	12953660,
}

m["lhp"] = {
	"Lhokpu",
	3436603,
	"sit-dhi",
}

m["lhs"] = {
	"Mlahsö",
	3393063,
	"sem-cna",
}

m["lht"] = {
	"Lo-Toga",
	3257566,
	"poz-vnn",
	"Latn",
}

m["lhu"] = {
	"Lahu",
	35780,
	"tbq-lho",
}

m["lia"] = {
	"West-Central Limba",
	32867815,
	"alv-lim",
}

m["lib"] = {
	"Likum",
	3240737,
	"poz-aay",
	"Latn",
}

m["lic"] = {
	"Hlai",
	934738,
	"qfa-lic",
	"Latn",
}

m["lid"] = {
	"Nyindrou",
	3346666,
	"poz-aay",
	"Latn",
}

m["lie"] = {
	"Likila",
	11011614,
	"bnt-ngn",
}

m["lif"] = {
	"Limbu",
	56477,
	"sit-kir",
	"Limb, Latn, Deva",
	translit = "lif-translit",
}

m["lig"] = {
	"Ligbi",
	33594,
	"dmn-jje",
}

m["lih"] = {
	"Lihir",
	6546938,
	"poz-ocw",
	"Latn",
}

m["lii"] = {
	"Lingkhim",
	12635536,
}

m["lij"] = {
	"Ligurian",
	36106,
	"roa-git",
	"Latn",
}

m["lik"] = {
	"Lika",
	1530394,
	"bnt-boa",
}

m["lil"] = {
	"Lillooet",
	34154,
	"sal",
	"Latn",
}

m["lio"] = {
	"Liki",
	4261493,
	"poz-ocw",
	"Latn",
}

m["lip"] = {
	"Sekpele",
	36257,
	"alv-ntg",
}

m["liq"] = {
	"Libido",
	35691,
	"cus-hec",
}

m["lir"] = {
	"Liberian Kreyol",
	6541128,
	"crp",
	"Latn",
	ancestors = "en",
}

m["lis"] = {
	"Lisu",
	56480,
	"tbq-lso",
	"Lisu, Latn",
	translit = {Lisu = "Lisu-translit"},
	override_translit = true,
	sort_key = {Lisu = s["Lisu-sortkey"]},
}

m["liu"] = {
	"Logorik",
	6667811,
	"sdv-daj",
}

m["liv"] = {
	"Livonian",
	33698,
	"urj-fin",
	"Latn",
	entry_name = {
		remove_diacritics = "'" .. u(0x2019),
		from = {"Ǭ", "ǭ"},
		to = {"Ō", "ō"}
	},
}

m["liw"] = {
	"Col",
	2981948,
}

m["lix"] = {
	"Liabuku",
	13580912,
}

m["liy"] = {
	"Banda-Bambari",
	11051591,
	"bad-cnt",
}

m["liz"] = {
	"Libinza",
	4914576,
	"bnt-zbi",
}

m["lja"] = {
	"Golpa",
	50934920,
	"aus-yol",
	"Latn",
}

m["lje"] = {
	"Rampi",
	7290041,
	"poz",
}

m["lji"] = {
	"Laiyolo",
	6474218,
}

m["ljl"] = {
	"Li'o",
	2697010,
	"poz",
}

m["ljp"] = {
	"Lampung Api",
	49215,
	"poz-lgx",
	"Latn",
}

m["ljw"] = {
	"Yirandali",
	17059380,
}

m["ljx"] = {
	"Yuru",
	63257867,
}

m["lka"] = {
	"Lakalei",
	12952700,
	"poz-tim",
	"Latn",
}

m["lkb"] = {
	"Kabras",
	63257894,
	"bnt-msl",
	ancestors = "luy",
}

m["lkc"] = {
	"Kucong",
	6441572,
	"tbq-lho",
}

m["lkd"] = {
	"Lakondê",
	20527166,
	"sai-nmk",
	"Latn",
}

m["lke"] = {
	"Kenyi",
	12952628,
	"bnt-nyg",
}

m["lkh"] = {
	"Lakha",
	56606,
	"sit-tib",
}

m["lki"] = {
	"Laki",
	56483,
	"ku",
	"fa-Arab",
	translit = "lki-translit",
	entry_name = {remove_diacritics = c.kasra .. c.sukun},
}

m["lkj"] = {
	"Remun",
	7312239,
	"poz-mly",
	"Latn",
}

m["lkl"] = {
	"Laeko-Libuat",
	3504331,
	"qfa-tor",
}

m["lkm"] = {
	"Kalaamaya",
	6349988,
}

m["lkn"] = {
	"Lakon",
	3216494,
	"poz-vnn",
	"Latn",
}

m["lko"] = {
	"Khayo",
	6401095,
	"bnt-msl",
}

m["lkr"] = {
	"Päri",
	36487,
	"sdv-lon",
}

m["lks"] = {
	"Kisa",
	63259208,
	"bnt-msl",
	ancestors = "luy",
}

m["lkt"] = {
	"Lakota",
	33537,
	"sio-dkt",
	"Latn",
}

m["lku"] = {
	"Kungkari",
	6444526,
}

m["lky"] = {
	"Lokoya",
	56687,
	"sdv-lma",
}

m["lla"] = {
	"Lala-Roba",
	3914878,
	"alv-yun",
}

m["llb"] = {
	"Lolo",
	11006056,
	"bnt-mak",
	ancestors = "vmw",
}

m["llc"] = {
	"Lele (Guinea)",
	6520837,
	"dmn-mok",
}

m["lld"] = {
	"Ladin",
	36202,
	"roa-rhe",
	"Latn",
}

m["lle"] = {
	"Lele (Papua New Guinea)",
	3229269,
	"poz-aay",
	"Latn",
}

m["llf"] = {
	"Hermit",
	3134240,
	"poz-aay",
	"Latn",
}

m["llg"] = {
	"Lole",
	6668883,
	"poz-tim",
}

m["llh"] = {
	"Lamu",
	6482736,
	"tbq-lso",
}

m["lli"] = {
	"Teke-Laali",
	36543,
	"bnt-nze",
}

m["llj"] = {
	"Ladji-Ladji",
	6512694,
	"aus-pam",
}

m["llk"] = {
	"Lelak",
	3229263,
	"poz-swa",
	"Latn",
}

m["lll"] = {
	"Lilau",
	6547570,
	"qfa-tor",
}

m["llm"] = {
	"Lasalimu",
	6492774,
}

m["lln"] = {
	"Lele (Chad)",
	1641493,
	"cdc-est",
}

m["llo"] = {
	"Khlor",
	27921409,
	"mkh-kat",
}

m["llp"] = {
	"North Efate",
	3580152,
	"poz-vnc",
	"Latn",
}

m["llq"] = {
	"Lolak",
	12953679,
	"phi",
}

m["lls"] = {
	"Lithuanian Sign Language",
	3915480,
	"sgn",
}

m["llu"] = {
	"Lau",
	3218574,
	"poz-sls",
	"Latn",
}

m["llx"] = {
	"Lauan",
	35682,
	"poz-pcc",
	"Latn",
}

m["lma"] = {
	"East Limba",
	11034212,
	"alv-lim",
}

m["lmb"] = {
	"Merei",
	12952843,
	"poz-vnn",
	"Latn",
}

m["lmc"] = {
	"Limilngan",
	6549414,
}

m["lmd"] = {
	"Lumun",
	35777,
	"alv-tal",
}

m["lme"] = {
	"Pévé",
	56249,
	"cdc-mas",
}

m["lmf"] = {
	"South Lembata",
	7567815,
}

m["lmg"] = {
	"Lamogai",
	278365,
	"poz-ocw",
	"Latn",
}

m["lmh"] = {
	"Lambichhong",
	6481472,
	"sit-kie",
	ancestors = "ybh",
}

m["lmi"] = {
	"Lombi",
	11259563,
	"csu-maa",
}

m["lmj"] = {
	"West Lembata",
	6864697,
}

m["lmk"] = {
	"Lamkang",
	12952703,
	"tbq-kuk",
}

m["lml"] = {
	"Raga",
	3063193,
	"poz-vnn",
	"Latn",
}

m["lmn"] = {
	"Lambadi",
	33474,
	"raj",
}

m["lmo"] = {
	"Lombard",
	33754,
	"roa-git",
	"Latn",
}

m["lmp"] = {
	"Limbum",
	35801,
	"nic-nka",
	"Latn",
}

m["lmq"] = {
	"Lamatuka",
	6480982,
}

m["lmr"] = {
	"Lamalera",
	6480787,
}

m["lmu"] = {
	"Lamenu",
	740604,
	"poz-vnc",
	"Latn",
}

m["lmv"] = {
	"Lomaiviti",
	3130221,
	"poz-pcc",
	"Latn",
}

m["lmw"] = {
	"Lake Miwok",
	3216471,
	"nai-you",
	"Latn",
}

m["lmx"] = {
	"Laimbue",
	6473933,
	"nic-rnw",
}

m["lmy"] = {
	"Laboya",
	6481538,
	"poz-cet",
	"Latn",
	sort_key = "lmy-sortkey",
}

m["lmz"] = {
	"Lumbee",
	12635887,
	nil,
	"Latn",
}

m["lna"] = {
	"Langbashe",
	11137550,
	"bad",
}

m["lnb"] = {
	"Mbalanhu",
	12952830,
	"bnt-ova",
}

m["lnd"] = {
	"Lun Bawang",
	13479839,
	"poz-swa",
	"Latn",
}

m["lnh"] = {
	"Lanoh",
	6487291,
	"mkh-asl",
}

m["lni"] = {
	"Daantanai'",
	5207384,
	"paa-sbo",
}

m["lnj"] = {
	"Linngithigh",
	3915694,
	"aus-pmn",
	"Latn",
}

m["lnl"] = {
	"South Central Banda",
	41354532,
	"bad",
}

m["lnm"] = {
	"Langam",
	6485678,
	"paa",
	"Latn",
}

m["lnn"] = {
	"Lorediakarkar",
	6680287,
	"poz-vnn",
	"Latn",
}

m["lno"] = {
	"Lango (Sudan)",
	223306,
	"sdv-lma",
}

m["lns"] = {
	"Lamnso'",
	35788,
	"nic-rng",
}

m["lnu"] = {
	"Longuda",
	35797,
	"alv-bam",
	"Latn",
}

m["lnw"] = {
	"Lanima",
	56825017,
	"aus-pam",
	"Latn",
}

m["loa"] = {
	"Loloda",
	6669025,
	"paa-nha",
	"Latn",
}

m["lob"] = {
	"Lobi",
	35807,
}

m["loc"] = {
	"Inonhan",
	2400870,
	"phi",
}

m["lod"] = {
	"Berawan",
	4891018,
	"poz-swa",
	"Latn",
}

m["loe"] = {
	"Saluan",
	12953867,
	"poz",
}

m["lof"] = {
	"Logol",
	35779,
	"alv-hei",
}

m["log"] = {
	"Logo",
	2613477,
	"csu-mma",
}

m["loh"] = {
	"Narim",
	56353,
	"sdv",
}

m["loi"] = {
	"Lomakka",
	3913961,
	"alv-kul",
}

m["loj"] = {
	"Lou",
	3260104,
	"poz-aay",
	"Latn",
}

m["lok"] = {
	"Loko",
	3914912,
	"dmn-msw",
	"Latn",
}

m["lol"] = {
	"Mongo",
	112893,
	"bnt-mon",
	"Latn",
}

m["lom"] = {
	"Loma",
	35885,
	"dmn-msw",
	"Latn, Loma"
}

m["lon"] = {
	"Malawi Lomwe",
	10975286,
}

m["loo"] = {
	"Lombo",
	11167192,
	"bnt-ske",
}

m["lop"] = {
	"Lopa",
	3914875,
}

m["loq"] = {
	"Lobala",
	4849710,
	"bnt-ngn",
}

m["lor"] = {
	"Téén",
	36467,
	"alv-kul",
}

m["los"] = {
	"Loniu",
	3259202,
	"poz-aay",
	"Latn",
}

m["lot"] = {
	"Lotuko",
	56672,
	"sdv-lma",
}

m["lou"] = {
	"Louisiana Creole",
	1185127,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["lov"] = {
	"Lopi",
	12952740,
	"tbq-tal",
}

m["low"] = {
	"Tampias Lobu",
	12953674,
}

m["lox"] = {
	"Loun",
	6689636,
	"poz-cet",
	"Latn",
}

m["loz"] = {
	"Lozi",
	33628,
	"bnt-sts",
	"Latn",
}

m["lpa"] = {
	"Lelepa",
	3229273,
	"poz-vnc",
	"Latn",
}

m["lpe"] = {
	"Lepki",
	4259152,
	"paa-pau",
}

m["lpn"] = {
	"Long Phuri Naga",
	6673049,
	"sit-aao",
}

m["lpo"] = {
	"Lipo",
	56921,
	"tbq-llo",
	"Plrd",
}

m["lpx"] = {
	"Lopit",
	56684,
	"sdv-lma",
}

m["lra"] = {
	"Rara Bakati'",
	3419746,
	"day",
}

m["lrc"] = {
	"Northern Luri",
	19933293,
	"ira-swi",
	"fa-Arab",
	ancestors = "pal",
}

m["lre"] = {
	"Laurentian",
	1790301,
	"iro-nor",
	"Latn",
}

m["lrg"] = {
	"Laragia",
	2591193,
}

m["lri"] = {
	"Marachi",
	6754565,
	"bnt-msl",
}

m["lrk"] = {
	"Loarki",
	6663513,
}

m["lrl"] = {
	"Larestani",
	33468,
	"ira-swi",
	"fa-Arab",
}

m["lrm"] = {
	"Marama",
	6325931,
	"bnt-msl",
	ancestors = "luy",
}

m["lrn"] = {
	"Lorang",
	6678781,
}

m["lro"] = {
	"Laro",
	35687,
	"alv-hei",
}

m["lrr"] = {
	"Southern Lorung",
	12952742,
	"sit-kie",
}

m["lrt"] = {
	"Larantuka Malay",
	6488691,
	"poz-mly",
	"Latn",
}

m["lrv"] = {
	"Larëvat",
	3217892,
	"poz-vnc",
	"Latn",
}

m["lrz"] = {
	"Lemerig",
	2028448,
	"poz-vnn",
	"Latn",
}

m["lsa"] = {
	"Lasgerdi",
	3218296,
	"ira-kms",
}

m["lsd"] = {
	"Lishana Deni",
	3436461,
	"sem-nna",
	"Hebr",
	display_text = "Hebr-common",
	entry_name = "Hebr-common",
	sort_key = "Hebr-common",
}

m["lse"] = {
	"Lusengo",
	6683546,
	"bnt-zbi",
}

m["lsh"] = {
	"Lish",
	6558822,
	"sit-khc",
}

m["lsi"] = {
	"Lashi",
	6493203,
	"tbq-brm",
	"Latn",
}

m["lsl"] = {
	"Latvian Sign Language",
	6497414,
	"sgn",
}

m["lsm"] = {
	"Saamia",
	3739441,
	"bnt-msl",
}

m["lso"] = {
	"Laos Sign Language",
	6488022,
	"sgn",
}

m["lsp"] = {
	"Panamanian Sign Language",
	7129968,
	"sgn",
}

m["lsr"] = {
	"Aruop",
	3450566,
	"qfa-tor",
}

m["lss"] = {
	"Lasi",
	12953669,
	"inc-snd",
	"Arab",
	ancestors = "sd",
}

m["lst"] = {
	"Trinidad and Tobago Sign Language",
	7842495,
	"sgn",
}

m["lsy"] = {
	"Mauritian Sign Language",
	6793754,
	"sgn",
}

m["ltc"] = {
	"Middle Chinese",
	2016252,
	"zhx",
	"Hant, Phag, Tang",
	translit = {Hant = "zh-translit"},
	sort_key = {Hant = "Hani-sortkey"},
}

m["ltg"] = {
	"Latgalian",
	36212,
	"bat-eas",
	"Latn",
}

m["lti"] = {
	"Leti",
	3236912,
	"poz-tim",
	"Latn",
}

m["ltn"] = {
	"Latundê",
	63259736,
	"sai-nmk",
	"Latn",
}

m["lto"] = {
	"Olutsotso",
	63259915,
	"bnt-msl",
	ancestors = "luy",
}

m["lts"] = {
	"Lutachoni",
	63283459,
	"bnt-msl",
}

m["ltu"] = {
	"Latu",
	6497181,
	"poz-cma",
}

m["lua"] = {
	"Luba-Kasai",
	34173,
	"bnt-lub",
	"Latn",
}

m["luc"] = {
	"Aringa",
	56556,
	"csu-mma",
}

m["lud"] = {
	"Ludian",
	33918,
	"urj-fin",
	"Latn",
}

m["lue"] = {
	"Luvale",
	33597,
	"bnt-clu",
	"Latn",
}

m["luf"] = {
	"Laua",
	6497673,
}

m["luh"] = {
	"Leizhou Min",
	1988433,
	"zhx-nan",
	"Hants",
	generate_forms = "zh-generateforms",
	sort_key = "Hani-sortkey",
}

m["lui"] = {
	"Luiseño",
	56236,
	"azc-cup",
	"Latn",
	entry_name = {remove_diacritics = c.acute .. c.circ},
}

m["luj"] = {
	"Luna",
	11003832,
	"bnt-lbn",
}

m["luk"] = {
	"Lunanakha",
	56446,
	"sit-tib",
	"Tibt",
	ancestors = "dz",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["lul"] = {
	"Olu'bo",
	6589401,
	"csu-mma",
}

m["lum"] = {
	"Luimbi",
	10963134,
	"bnt-clu",
}

m["lun"] = {
	"Lunda",
	33607,
	"bnt-lun",
	"Latn",
}

m["luo"] = {
	"Luo",
	5414796,
	"sdv-los",
	"Latn",
}

m["lup"] = {
	"Lumbu",
	35793,
	"bnt-sir",
}

m["luq"] = {
	"Lucumí",
	1768321,
	"alv-yor",
	"Latn",
	ancestors = "yo",
	sort_key = {
		remove_diacritics = c.acute,
	},
}

m["lur"] = {
	"Laura",
	2984540,
}

m["lus"] = {
	"Mizo",
	36147,
	"tbq-kuk",
	"Latn",
}

m["lut"] = {
	"Lushootseed",
	33658,
	"sal",
	"Latn",
}

m["luu"] = {
	"Lumba-Yakkha",
	6703050,
	"sit-kie",
	ancestors = "ybh",
}

m["luv"] = {
	"Luwati",
	33402,
	"inc-snd",
	"Khoj",
}

m["luy"] = {
	"Luhya",
	35893,
	"bnt-msl",
	"Latn",
}

m["luz"] = {
	"Southern Luri",
	12952748,
	"ira-swi",
	"fa-Arab",
	ancestors = "pal",
}

m["lva"] = {
	"Maku'a",
	35790,
	"poz-tim",
}

m["lvi"] = {
	"Lawi",
	6502657,
	"mkh-ban",
	"Latn",
}

m["lvk"] = {
	"Lavukaleve",
	770547,
	"paa",
	"Latn",
}

m["lvl"] = {
	"Lwel",
	93936908,
	"bnt-bdz",
	"Latn",
}

m["lvu"] = {
	"Levuka",
	6535860,
}

m["lwa"] = {
	"Lwalu",
	6706953,
	"bnt-lbn",
}

m["lwe"] = {
	"Lewo Eleng",
	6537465,
}

m["lwg"] = {
	"Wanga",
	nil,
	"bnt-msl",
	ancestors = "luy",
}

m["lwh"] = {
	"White Lachi",
	8842956,
	"qfa-kra",
}

m["lwl"] = {
	"Eastern Lawa",
	18644464,
	"mkh-pal",
	"Thai",
	sort_key = "Thai-sortkey",
}

m["lwm"] = {
	"Laomian",
	19597674,
	"tbq-bis",
}

m["lwo"] = {
	"Luwo",
	56362,
	"sdv-lon",
	"Latn",
}

m["lws"] = {
	"Malawian Sign Language",
	47522462,
	"sgn",
}

m["lwt"] = {
	"Lewotobi",
	14916885,
}

m["lwu"] = {
	"Lawu",
	6505073,
	"tbq-lwo",
}

m["lww"] = {
	"Lewo",
	3237321,
	"poz-vnc",
	"Latn",
}

m["lya"] = {
	"Layakha",
	56602,
	"sit-tib",
	"Tibt",
	ancestors = "dz",
	translit = "Tibt-translit",
	override_translit = true,
	display_text = s["Tibt-displaytext"],
	entry_name = s["Tibt-entryname"],
	sort_key = "Tibt-sortkey",
}

m["lyg"] = {
	"Lyngngam",
	12635902,
	"aav-pkl",
}

m["lyn"] = {
	"Luyana",
	3268098,
}

m["lzh"] = {
	"Literary Chinese",
	37041,
	"zhx",
	"Hant",
	wikimedia_codes = "zh-classical",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["lzl"] = {
	"Litzlitz",
	6653424,
	"poz-vnc",
	"Latn",
}

m["lzn"] = {
	"Leinong Naga",
	5924455,
	"sit-kch",
}

m["lzz"] = {
	"Laz",
	1160372,
	"ccs-zan",
	"Geor, Latn",
	translit = {Geor = "lzz-translit"},
	override_translit = true,
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ},
}

return require("Module:languages").finalizeData(m, "language")