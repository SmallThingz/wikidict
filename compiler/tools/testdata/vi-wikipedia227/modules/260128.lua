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

m["maa"] = {
	"San Jerónimo Tecóatl Mazatec",
	7692927,
	"omq-maz",
	"Latn",
}

m["mab"] = {
	"Yutanduchi Mixtec",
	12645448,
	"omq-mxt",
	"Latn",
}

m["mad"] = {
	"tiếng Madura",
	36213,
	"poz-msa",
	"Latn",
	"Tiếng Madura",
	"Madura",
}

m["mae"] = {
	"Bo-Rukul",
	34967,
	"nic-ple",
	"Latn",
}

m["maf"] = {
	"Mafa",
	35819,
	"cdc-cbm",
	"Latn",
}

m["mag"] = {
	"tiếng Magaha",
	33728,
	"inc-eas",
	"Deva, Kthi",
	"Tiếng Magaha",
	"Magaha",
	ancestors = "bh",
}

m["mai"] = {
	"tiếng Maithil",
	36109,
	"inc-eas",
	"Deva, Tirh, Kthi, Newa",
	"Tiếng Maithil",
	"Maithil",
	ancestors = "bh",
	translit = {
		Deva = "mai-translit",
		Tirh = "mai-Tirh-translit",
		Kthi = "bho-Kthi-translit",
	},
}

m["maj"] = {
	"Jalapa de Díaz Mazatec",
	3915999,
	"omq-maz",
	"Latn",
}

m["mak"] = {
	"tiếng Makassar",
	33643,
	"poz-ssw",
	"Latn, Bugi, Maka",
	"Tiếng Makassar",
	"Makassar",
}

m["mam"] = {
	"Mam",
	33467,
	"myn",
	"Latn",
}

m["man"] = {
	"Mandingo",
	35772,
	"dmn-man",
	"Latn",
}

m["maq"] = {
	"Chiquihuitlán Mazatec",
	5101757,
	"omq-maz",
	"Latn",
}

m["mas"] = {
	"tiếng Maasai",
	35787,
	"sdv-lma",
	"Latn",
	"Tiếng Maasai",
	"Maasai",
}

m["mat"] = {
	"Matlatzinca",
	12953704,
	"omq",
	"Latn",
}

m["mau"] = {
	"Huautla Mazatec",
	36230,
	"omq-maz",
	"Latn",
}

m["mav"] = {
	"Sateré-Mawé",
	6794475,
	"tup",
	"Latn",
}

m["maw"] = {
	"tiếng Mampruli",
	35804,
	"nic-wov",
	"Latn",
	"Tiếng Mampruli",
	"Mampruli",
}

m["max"] = {
	"tiếng Mã Lai Bắc Maluku",
	7056136,
	"crp",
	"Latn",
	"Tiếng Mã Lai Bắc Maluku",
	"Mã Lai Bắc Maluku",
}

m["maz"] = {
	"tiếng Mazahua Trung",
	36228,
	"oto",
	"Latn",
	"Tiếng Mazahua Trung",
	"Mazahua Trung",
}

m["mba"] = {
	"tiếng Higaonon",
	5753411,
	"mno",
	"Latn",
	"Tiếng Higaonon",
	"Higaonon",
}

m["mbb"] = {
	"Western Bukidnon Manobo",
	7987643,
	"mno",
	"Latn",
}

m["mbc"] = {
	"tiếng Macushi",
	56633,
	"sai-pem",
	"Latn",
	"Tiếng Macushi",
	"Macushi",
}

m["mbd"] = {
	"tiếng Dibabawon",
	18755523,
	"mno",
	"Latn",
	"Tiếng Dibabawon",
	"Dibabawon",
}

m["mbe"] = {
	"Molale",
	3319444,
	"nai-plp",
	"Latn",
}

m["mbf"] = {
	"tiếng Mã Lai Baba",
	18642798,
	"crp",
	"Latn",
	"Tiếng Mã Lai Baba",
	"Mã Lai Baba",
	ancestors = "ms",
}

m["mbh"] = {
	"Mangseng",
	6749147,
	"poz-ocw",
	"Latn",
}

m["mbi"] = {
	"Ilianen Manobo",
	14916911,
	"mno",
	"Latn",
}

m["mbj"] = {
	"Nadëb",
	3335011,
	"sai-nad",
	"Latn",
}

m["mbk"] = {
	"Malol",
	6744477,
	"poz-ocw",
	"Latn",
}

m["mbl"] = {
	"Maxakalí",
	3029682,
	"sai-mje",
	"Latn",
}

m["mbm"] = {
	"Ombamba",
	36407,
	"bnt-mbt",
	"Latn",
}

m["mbn"] = {
	"Macaguán",
	3273980,
	"sai-guh",
	"Latn",
}

m["mbo"] = { -- is, like 'bqz', 'bsi' and 'bss', a dialect of Manenguba
	"Mbo (Cameroon)",
	nil,
	"bnt-mne",
	"Latn",
}

m["mbp"] = {
	"Wiwa",
	3012604,
	"cba",
	"Latn",
}

m["mbq"] = {
	"Maisin",
	3448149,
	nil,
	"Latn",
}

m["mbr"] = {
	"Nukak Makú",
	3346228,
	"sai-nad",
	"Latn",
}

m["mbs"] = {
	"Sarangani Manobo",
	7423093,
	"mno",
	"Latn",
}

m["mbt"] = {
	"Matigsalug Manobo",
	6787447,
	"mno",
	"Latn",
}

m["mbu"] = {
	"Mbula-Bwazza",
	3913324,
	"nic-jrn",
	"Latn",
}

m["mbv"] = {
	"Mbulungish",
	36003,
	"alv-nal",
	"Latn",
}

m["mbw"] = {
	"Maring",
	3293280,
	nil,
	"Latn",
}

m["mbx"] = {
	"Sepik Mari",
	6760942,
	"paa-spk",
	"Latn",
}

m["mby"] = {
	"tiếng Memon",
	4180871,
	"inc-snd",
	"Gujr, ur-Arab",
	"Tiếng Memon",
	"Memon",
}

m["mbz"] = {
	"Amoltepec Mixtec",
	13583504,
	"omq-mxt",
	"Latn",
}

m["mca"] = {
	"Maca",
	3281043,
	"sai-mtc",
	"Latn",
}

m["mcb"] = {
	"Machiguenga",
	3915441,
	"awd",
	"Latn",
}

m["mcc"] = {
	"Bitur",
	4919173,
}

m["mcd"] = {
	"Sharanahua",
	12953881,
	"sai-pan",
	"Latn",
}

m["mce"] = {
	"Itundujia Mixtec",
	12953727,
	"omq-mxt",
	"Latn",
}

m["mcf"] = {
	"Matsés",
	2981620,
	"sai-pan",
	"Latn",
}

m["mcg"] = {
	"Mapoyo",
	56946,
	"sai-map",
	"Latn",
}

m["mch"] = {
	"tiếng Ye'kwana",
	3082027,
	"sai-car",
	"Latn",
	"Tiếng Ye'kwana",
	"Ye'kwana",
	sort_key = {
		remove_diacritics = "%-%s",
		from = {"'", "ñ", "ö", "sh", "ü"},
		to = {"’", "n" .. p[1], "o" .. p[1], "s" .. p[1], "u" .. p[1]}
    }
}

m["mci"] = {
	"Mese",
	6821190,
}

m["mcj"] = {
	"Mvanip",
	3913281,
	"nic-mmb",
	"Latn",
}

m["mck"] = {
	"Mbunda",
	34170,
	"bnt-clu",
	"Latn",
}

m["mcl"] = {
	"Macaguaje",
	6722435,
	"sai-tuc",
	"Latn",
}

m["mcm"] = {
	"Kristang",
	2669169,
	"crp",
	"Latn",
	ancestors = "pt",
}

m["mcn"] = {
	"Masana",
	56668,
	"cdc-mas",
}

m["mco"] = {
	"Coatlán Mixe",
	25559716,
	"nai-miz",
	"Latn",
}

m["mcp"] = {
	"Makaa",
	35803,
	"bnt-mka",
}

m["mcq"] = {
	"tiếng Ese",
	5397551,
	"ngf-koi",
	"Latn",
	"Tiếng Ese",
	"Ese",
}

m["mcr"] = {
	"Menya",
	11732444,
	"ngf",
}

m["mcs"] = {
	"Mambai",
	6748872,
	"alv-mbm",
}

m["mcu"] = {
	"Cameroon Mambila",
	19359039,
	"nic-mmb",
	"Latn",
}

m["mcv"] = {
	"Minanibai",
	6863167,
	"ngf",
}

m["mcw"] = {
	"Mawa",
	3441333,
	"cdc-est",
	"Latn",
}

m["mcx"] = {
	"Mpiemo",
	35908,
	"bnt-bek",
}

m["mcy"] = {
	"South Watut",
	12953293,
	"poz-ocw",
}

m["mcz"] = {
	"Mawan",
	11732429,
	"ngf-mad",
}

m["mda"] = {
	"Mada (Nigeria)",
	3915843,
	"nic-nin",
	"Latn",
}

m["mdb"] = {
	"Morigi",
	6912195,
	"paa-kiw",
}

m["mdc"] = {
	"Male",
	6742927,
	"ngf-mad",
}

m["mdd"] = {
	"Mbum",
	36170,
	"alv-mbm",
}

m["mde"] = {
	"tiếng Mabang",
	35860,
	"ssa",
	"Arab, Latn",
	"Tiếng Mabang",
	"Mabang",
}

m["mdf"] = {
	"tiếng Moksha",
	13343,
	"urj-mdv",
	"Cyrl",
	"Tiếng Moksha",
	"Moksha",
	translit = "mdf-translit",
	entry_name = {remove_diacritics = c.acute},
	override_translit = true,
	sort_key = "mdf-sortkey",
}

m["mdg"] = {
	"Massalat",
	759984,
}

m["mdh"] = {
	"tiếng Maguindanao",
	33717,
	"phi",
	"Latn, Arab",
	"Tiếng Maguindanao",
	"Maguindanao",
}

m["mdi"] = {
	"Mamvu",
	3033594,
	"csu-mle",
}

m["mdj"] = {
	"Mangbetu",
	56327,
	"csu-maa",
}

m["mdk"] = {
	"Mangbutu",
	6748877,
	"csu-mle",
}

m["mdl"] = {
	"Maltese Sign Language",
	6744816,
	"sgn",
}

m["mdm"] = {
	"tiếng Mayogo",
	6797580,
	"nic-nke",
	"Latn",
	"Tiếng Mayogo",
	"Mayogo",
}

m["mdn"] = {
	"Mbati",
	36165,
	"bnt-ngn",
}

m["mdp"] = {
	"Mbala",
	6799583,
	"bnt-pen",
}

m["mdq"] = {
	"Mbole",
	6799727,
	"bnt-mbe",
}

m["mdr"] = {
	"Mandar",
	35995,
	"poz-ssw",
	"Bugi, Latn",
}

m["mds"] = {
	"Maria",
	3448673,
}

m["mdt"] = {
	"Mbere",
	36062,
	"bnt-mbt",
}

m["mdu"] = {
	"Mboko",
	36058,
	"bnt-mbo",
}

m["mdv"] = {
	"Santa Lucía Monteverde Mixtec",
	12953722,
	"omq-mxt",
	"Latn",
}

m["mdw"] = {
	"Mbosi",
	36035,
	"bnt-mbo",
}

m["mdx"] = {
	"tiếng Dizi",
	35313,
	"omv-diz",
	"Ethi, Latn",
	"Tiếng Dizi",
	"Dizi",
}

m["mdy"] = {
	"tiếng Maale",
	795327,
	"omv-ome",
	"Ethi",
	"Tiếng Maale",
	"Maale",
}

m["mdz"] = {
	"Suruí Do Pará",
	10322149,
	"tup-gua",
	"Latn",
}

m["mea"] = {
	"Menka",
	36078,
	"nic-grs",
	"Latn",
}

m["meb"] = {
	"Ikobi-Mena",
	11732241,
	"ngf",
	"Latn",
}

m["mec"] = {
	"Mara",
	6772774,
}

m["med"] = {
	"tiếng Melpa",
	36166,
	nil,
	"Latn",
	"Tiếng Melpa",
	"Melpa",
}

m["mee"] = {
	"Mengen",
	3305831,
	"poz-ocw",
}

m["mef"] = {
	"Megam",
	6808589,
}

m["meg"] = {
	"Mea",
	12952836,
	"poz-cln",
}

m["meh"] = {
	"Southwestern Tlaxiaco Mixtec",
	7070686,
	"omq-mxt",
	"Latn",
}

m["mei"] = {
	"Midob",
	36007,
	"nub",
	"Latn",
}

m["mej"] = {
	"Meyah",
	11732436,
	"paa-wpa",
}

m["mek"] = {
	"Mekeo",
	3304803,
	"poz-ocw",
}

m["mel"] = {
	"Central Melanau",
	18638319,
	"poz-swa",
	"Latn",
}

m["mem"] = {
	"Mangala",
	6748664,
}

m["men"] = {
	"tiếng Mende",
	1478672,
	"dmn-msw",
	"Latn, Mend",
	"Tiếng Mende",
	"Mende",
}

m["meo"] = {
	"tiếng Mã Lai Kedah",
	4925684,
	"poz-mly",
	"Latn, ms-Arab, Thai",
	"Tiếng Mã Lai Kedah",
	"Mã Lai Kedah",
	entry_name = {
		from = {u(0xF70F)},
		to = {"ญ"}
	},
	sort_key = {Thai = "Thai-sortkey"},
}

m["mep"] = {
	"Miriwung",
	3111847,
}

m["meq"] = {
	"Merey",
	3502314,
	"cdc-cbm",
	"Latn",
}

m["mer"] = {
	"Meru",
	13313,
	"bnt-kka",
	"Latn",
}

m["mes"] = {
	"Masmaje",
	3440448,
}

m["met"] = {
	"Mato",
	3299190,
	"poz-ocw",
	"Latn",
}

m["meu"] = {
	"tiếng Motu",
	33516,
	"poz-ocw",
	"Latn",
	"Tiếng Motu",
	"Motu",
}

m["mev"] = {
	"tiếng Mano",
	3913286,
	"dmn-mda",
	"Latn",
	"Tiếng Mano",
	"Mano",
}

m["mew"] = {
	"tiếng Maaka",
	3438764,
	"cdc-wst",
	"Latn",
	"Tiếng Maaka",
	"Maaka",
}

m["mey"] = {
	"tiếng Ả Rập Hassaniya",
	56231,
	"sem-arb",
	"Arab",
	"Tiếng Ả Rập Hassaniya",
	"Ả Rập Hassaniya",
}

m["mez"] = {
	"tiếng Menominee",
	13363,
	"alg",
	"Latn",
	"Tiếng Menominee",
	"Menominee",
	sort_key = {remove_diacritics = "·"},
}

m["mfa"] = {
	"tiếng Mã Lai Pattani",
	1199751,
	"poz-mly",
	"Latn, ms-Arab, Thai",
	"Tiếng Mã Lai Pattani",
	"Mã Lai Pattani",
	entry_name = {
		from = {u(0xF70F)},
		to = {"ญ"}
	},
	sort_key = {Thai = "Thai-sortkey"},
}

m["mfb"] = {
	"Bangka",
	3258818,
}

m["mfc"] = {
	"Mba",
	4286464,
	"nic-mbc",
	"Latn",
}

m["mfd"] = {
	"tiếng Mendankwe-Nkwen",
	11129537,
	"nic-nge",
	"Latn",
	"Tiếng Mendankwe-Nkwen",
	"Mendankwe-Nkwen",
}

m["mfe"] = {
	"tiếng Creole Mauritius",
	33661,
	"crp",
	"Latn",
	"Tiếng Creole Mauritius",
	"Creole Mauritius",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["mff"] = {
	"Naki",
	36083,
	"nic-bbe",
	"Latn",
}

m["mfg"] = {
	"Mixifore",
	3914478,
	"dmn-mok",
}

m["mfh"] = {
	"tiếng Matal",
	3501751,
	"cdc-cbm",
	"Latn",
	"Tiếng Matal",
	"Matal",
}

m["mfi"] = {
	"Wandala",
	3441249,
	"cdc-cbm",
	"Latn",
}

m["mfj"] = {
	"Mefele",
	3501871,
	"cdc-cbm",
}

m["mfk"] = {
	"North Mofu",
	56303,
	"cdc-cbm",
}

m["mfl"] = {
	"Putai",
	56291,
}

m["mfm"] = {
	"Marghi South",
	56248,
}

m["mfn"] = {
	"tiếng Mbembe sông Cross",
	3915395,
	"nic-uce",
	"Latn",
	"Tiếng Mbembe sông Cross",
	"Mbembe sông Cross",
}

m["mfo"] = {
	"Mbe",
	36075,
	"nic-eko",
	"Latn",
}

m["mfp"] = {
	"Makassar Malay",
	12952776,
	"qfa-mix",
	"Latn",
}

m["mfq"] = {
	"Moba",
	19921578,
	"nic-grm",
	"Latn",
}

m["mfr"] = {
	"Marrithiyel",
	6773014,
	"aus-dal",
	"Latn",
}

m["mfs"] = {
	"Mexican Sign Language",
	3915511,
	"sgn",
	"Latn", -- when documented
}

m["mft"] = {
	"Mokerang",
	3319387,
	"poz-aay",
	"Latn",
}

m["mfu"] = {
	"Mbwela",
	11004988,
	"bnt-clu",
	ancestors = "lch",
}

m["mfv"] = {
	"Mandjak",
	35822,
	"alv-pap",
}

m["mfw"] = {
	"Mulaha",
	6933720,
}

m["mfx"] = {
	"tiếng Melo",
	6813268,
	"omv-nom",
	"Latn, Ethi",
	"Tiếng Melo",
	"Melo",
}

m["mfy"] = {
	"Mayo",
	56729,
	"azc-trc",
	"Latn",
	sort_key = {remove_diacritics = c.acute},
}

m["mfz"] = {
	"tiếng Mabaan",
	20526385,
	"sdv",
	"Latn",
	"Tiếng Mabaan",
	"Mabaan",
}

m["mga"] = {
	"tiếng Ireland trung đại",
	36116,
	"cel-gae",
	"Latn",
	"Tiếng Ireland trung đại",
	"Ireland trung đại",
	ancestors = "sga",
	entry_name = {remove_diacritics = c.dotabove .. c.diaer .. "·"},
	sort_key = "mga-sortkey",
}

m["mgb"] = {
	"Mararit",
	56359,
	"sdv-tmn",
}

m["mgc"] = {
	"tiếng Morokodo",
	6913216,
	"csu-bbk",
	"Latn",
	"Tiếng Morokodo",
	"Morokodo",
}

m["mgd"] = {
	"Moru",
	6915014,
	"csu-mma",
}

m["mge"] = {
	"tiếng Mango",
	713659,
	"csu-sar",
	"Latn",
	"Tiếng Mango",
	"Mango",
}

m["mgf"] = {
	"Maklew",
	6739816,
}

m["mgg"] = {
	"Mpongmpong",
	35924,
	"bnt-bek",
}

m["mgh"] = {
	"Makhuwa-Meetto",
	33604,
	"bnt-mak",
	"Latn",
	ancestors = "vmw",
}

m["mgi"] = {
	"Jili",
	3914497,
	"nic-pls",
}

m["mgj"] = {
	"Abureni",
	3441256,
	"nic-cde",
	"Latn",
}

m["mgk"] = {
	"Mawes",
	6794395,
	"paa",
}

m["mgl"] = {
	"Maleu-Kilenge",
	3281884,
}

m["mgm"] = {
	"Mambae",
	35774,
	"poz-tim",
	"Latn",
}

m["mgn"] = {
	"Mbangi",
	11017443,
	"nic-ngd",
	"Latn",
}

m["mgo"] = {
	"Meta'",
	36054,
	"nic-mom",
	"Latn",
}

m["mgp"] = {
	"tiếng Magar Đông",
	12952758,
	"sit-gma",
	nil,
	"Tiếng Magar Đông",
	"Magar Đông",
}

m["mgq"] = {
	"Malila",
	6743679,
	"bnt-mby",
	"Latn",
}

m["mgr"] = {
	"Mambwe-Lungu",
	626210,
	"bnt-mwi",
	"Latn",
}

m["mgs"] = {
	"Manda (Tanzania)",
	16939267,
	"bnt-bki",
}

m["mgt"] = {
	"Mongol",
	11260674,
	"paa",
	"Latn",
}

m["mgu"] = {
	"Mailu",
	3278246,
	"ngf",
}

m["mgv"] = {
	"Matengo",
	6786446,
	"bnt-mbi",
	"Latn",
}

m["mgw"] = {
	"Matumbi",
	6791974,
	"bnt-mbi",
	"Latn",
}

m["mgy"] = {
	"Mbunga",
	6799817,
	"bnt-kil",
}

m["mgz"] = {
	"Mbugwe",
	3426367,
	"bnt-mra",
}

m["mha"] = {
	"tiếng Manda (Ấn Độ)",
	56760,
	"dra-kki",
	"Orya",
	"Tiếng Manda (Ấn Độ)",
	"Manda (Ấn Độ)",
	translit = "kxv-translit",
}

m["mhb"] = {
	"Mahongwe",
	35816,
	"bnt-kel",
}

m["mhc"] = {
	"Mocho",
	1941682,
	"myn",
}

m["mhd"] = {
	"Mbugu",
	36152,
	"qfa-mix",
	"Latn",
	ancestors = "asa",
}

m["mhe"] = {
	"tiếng Mah Meri",
	2742262,
	"mkh-asl",
	"Latn",
	"Tiếng Mah Meri",
	"Mah Meri"
}

m["mhf"] = {
	"Mamaa",
	6745346,
	"ngf-fin",
	"Latn",
}

m["mhg"] = {
	"Marrgu",
	6772812,
}

m["mhi"] = {
	"Ma'di",
	56670,
	"csu-mma",
}

m["mhj"] = {
	"tiếng Mogholi",
	13336,
	"xgn",
	"fa-Arab, Latn",
	"Tiếng Mogholi",
	"Mogholi",
}

m["mhk"] = {
	"Mungaka",
	36068,
	"nic-nun",
	"Latn",
}

m["mhl"] = {
	"Mauwake",
	6794095,
	"ngf-mad",
}

m["mhm"] = {
	"Makhuwa-Moniga",
	6900145,
	"bnt-mak",
}

m["mhn"] = {
	"tiếng Mòcheno",
	268130,
	"gmw-hgm",
	"Latn",
	"Tiếng Mòcheno",
	"Mòcheno",
	ancestors = "bar",
	sort_key = {remove_diacritics = c.grave},
}

m["mho"] = {
	"Mashi",
	10962737,
	"bnt-kav",
	"Latn",
}

m["mhp"] = {
	"Balinese Malay",
	12473441,
	"crp",
}

m["mhq"] = {
	"Mandan",
	1957120,
	"sio",
}

m["mhr"] = {
	"tiếng Mari Đông",
	3906614,
	"chm",
	"Cyrl",
	"Tiếng Mari Đông",
	"Mari Đông",
	translit = "chm-translit",
	override_translit = true,
	entry_name = {remove_diacritics = c.grave .. c.acute},
	sort_key = {
		from = {"ё", "ҥ", "ӧ", "ӱ"},
		to = {"е" .. p[1], "н" .. p[1], "о" .. p[1], "у" .. p[1]}
	}
}

m["mhs"] = {
	"Buru (Indonesia)",
	2928650,
	"poz-cma",
}

m["mht"] = {
	"tiếng Mandahuaca",
	6747924,
	"awd-nwk",
	"Latn",
	"Tiếng Mandahuaca",
	"Mandahuaca",
}

m["mhu"] = {
	"Taraon",
	56400,
	"sit-gsi",
	"Latn",
}

m["mhw"] = {
	"Mbukushu",
	2691548,
}

m["mhx"] = {
	"tiếng Lhao Vo",
	11149315,
	"tbq-brm",
	"Latn",
	"Tiếng Lhao Vo",
	"Lhao Vo",
}

m["mhy"] = {
	"tiếng Ma'anyan",
	2328761,
	"poz-bre",
	nil,
	"Tiếng Ma'anyan",
	"Ma'anyan",
}

m["mhz"] = {
	"Mor (Austronesian)",
	2122792,
	"poz-hce",
	"Latn",
}

m["mia"] = {
	"tiếng Miami",
	56523,
	"alg",
	"Latn",
	"Tiếng Miami",
	"Miami",
}

m["mib"] = {
	"Atatláhuca Mixtec",
	32093046,
	"omq-mxt",
	"Latn",
}

m["mic"] = {
	"tiếng Mi'kmaq",
	13321,
	"alg-eas",
	"Latn",
	"Tiếng Mi'kmaq",
	"Mi'kmaq",
}

m["mid"] = {
	"Mandaic",
	6991742,
	"sem-ase",
	"Mand",
	ancestors = "myz",
}

m["mie"] = {
	"Ocotepec Mixtec",
	25559575,
	"omq-mxt",
	"Latn",
}

m["mif"] = {
	"Mofu-Gudur",
	1365132,
	"cdc-cbm",
	"Latn",
}

m["mig"] = {
	"San Miguel el Grande Mixtec",
	12953719,
	"omq-mxt",
	"Latn",
}

m["mih"] = {
	"tiếng Mixtec Chayuco",
	13583510,
	"omq-mxt",
	"Latn",
	"Tiếng Mixtec Chayuco",
	"Mixtec Chayuco",
}

m["mii"] = {
	"Chigmecatitlán Mixtec",
	12953724,
	"omq-mxt",
	"Latn",
}

m["mij"] = {
	"Mungbam",
	34725,
	"nic-beb",
	"Latn",
}

m["mik"] = {
	"Mikasuki",
	13316,
	"nai-mus",
	"Latn",
}

m["mil"] = {
	"Peñoles Mixtec",
	42411307,
	"omq-mxt",
	"Latn",
}

m["mim"] = {
	"Alacatlatzala Mixtec",
	14697894,
	"omq-mxt",
	"Latn",
}

m["min"] = {
	"tiếng Minangkabau",
	13324,
	"poz-mly",
	"Latn, Arab",
	"Tiếng Minangkabau",
	"Minangkabau",
}

m["mio"] = {
	"Pinotepa Nacional Mixtec",
	7196415,
	"omq-mxt",
	"Latn",
}

m["mip"] = {
	"Apasco-Apoala Mixtec",
	13583505,
	"omq-mxt",
	"Latn",
}

m["miq"] = {
	"tiếng Miskito",
	1516803,
	"nai-min",
	"Latn",
	"Tiếng Miskito",
	"Miskito",
	entry_name = {remove_diacritics = c.circ},
}

m["mir"] = {
	"Isthmus Mixe",
	6088873,
	"nai-miz",
}

m["mit"] = {
	"Southern Puebla Mixtec",
	7570345,
	"omq-mxt",
	"Latn",
}

m["miu"] = {
	"Cacaloxtepec Mixtec",
	12953723,
	"omq-mxt",
	"Latn",
}

m["miw"] = {
	"Akoye",
	3327462,
	"ngf",
	"Latn",
}

m["mix"] = {
	"Mixtepec Mixtec",
	6884125,
	"omq-mxt",
	"Latn",
}

m["miy"] = {
	"Ayutla Mixtec",
	13583508,
	"omq-mxt",
	"Latn",
}

m["miz"] = {
	"Coatzospan Mixtec",
	3317290,
	"omq-mxt",
	"Latn",
}

m["mjb"] = {
	"tiếng Makalero",
	35729,
	"paa-alp",
	"Latn",
}

m["mjc"] = {
	"San Juan Colorado Mixtec",
	12953718,
	"omq-mxt",
	"Latn",
}

m["mjd"] = {
	"Northwest Maidu",
	3198700,
	"nai-mdu",
	"Latn",
}

m["mje"] = {
	"Muskum",
	3913334,
}

-- mjg "Monguor" is not recognized as a language, but it is a family code

m["mji"] = {
	"tiếng Kim Môn",
	1115317,
	"hmx-mie",
	"Latn",
	"Tiếng Kim Môn",
	"Kim Môn"
}

m["mjj"] = {
	"Mawak",
	11732427,
	"ngf-mad",
}

m["mjk"] = {
	"Matukar",
	6791963,
	"poz-ocw",
	"Latn",
}

m["mjl"] = {
	"tiếng Mandi",
	6747931,
	"him",
	"Deva, Takr",
	"Tiếng Mandi",
	"Mandi",
	translit = {Deva = "hi-translit"},
}

m["mjm"] = {
	"Medebur",
	6805227,
	"poz-ocw",
	"Latn",
}

m["mjn"] = {
	"Mebu",
	6804364,
	"ngf-fin",
}

m["mjo"] = {
	"tiếng Malankurava",
	14916887,
	"dra-mal",
	"Mlym",
	"Tiếng Malankurava",
	"Malankurava",
	translit = "ml-translit",
}

m["mjp"] = {
	"tiếng Malapandaram",
	10575729,
	"dra-tam",
	"Taml",
	"Tiếng Malapandaram",
	"Malapandaram",
	translit = "ta-translit",
}

m["mjq"] = {
	"tiếng Malarya",
	12952773,
	"dra-mal",
	"Mlym",
	"Tiếng Malarya",
	"Malarya",
	translit = "ml-translit",
}

m["mjr"] = {
	"tiếng Malavedan",
	12952775,
	"dra-mal",
	"Mlym",
	"Tiếng Malavedan",
	"Malavedan",
	translit = "ml-translit",
}

m["mjs"] = {
	"Miship",
	3441264,
	"cdc-wst",
	"Latn",
}

m["mjt"] = {
	"tiếng Paharia Sauria",
	33907,
	"dra-mlo",
	"Beng, Deva",
	"Tiếng Paharia Sauria",
	"Paharia Sauria",
}

m["mju"] = {
	"Manna-Dora",
	10576453,
	"dra-tel",
}

m["mjv"] = {
	"tiếng Mannan",
	3286037,
	"dra-tam",
	"Mlym, Taml",
	"Tiếng Mannan",
	"Mannan",
	translit = {
		Mlym = "ml-translit",
		Taml = "ta-translit",
	},
}

m["mjw"] = {
	"tiếng Karbi",
	56591,
	"tbq-kuk",
	"Latn, Beng",
	"Tiếng Karbi",
	"Karbi",
}

m["mjx"] = {
	"tiếng Mahal",
	12953686,
	"mun",
	"Olck, Deva, Beng, Orya",
	"Tiếng Mahal",
	"Mahal",
	translit = {
		Olck = "Olck-translit",
		Deva = "hi-translit",
		Beng = "bn-translit",
	}
}

m["mjy"] = {
	"Mahican",
	3182562,
	"alg-eas",
	"Latn",
}

m["mjz"] = {
	"Majhi",
	6737786,
	"inc-eas",
	ancestors = "bh",
}

m["mka"] = {
	"Mbre",
	3450154,
	"nic", --unclassified within niger-congo tho
}

m["mkb"] = {
	"Mal Paharia",
	6583595,
}

m["mkc"] = {
	"Siliput",
	7515090,
	"qfa-tor",
	"Latn",
}

m["mke"] = {
	"Mawchi",
	21403317,
}

m["mkf"] = {
	"Miya",
	43328,
	"cdc-wst",
	"Latn",
}

m["mkg"] = {
	"Mak (China)",
	3280623,
	"qfa-kms",
}

m["mki"] = {
	"tiếng Dhatki",
	32480,
	"inc-wes",
	"Arab, Deva",
	"Tiếng Dhatki",
	"Dhatki",
	ancestors = "mwr",
}

m["mkj"] = {
	"tiếng Mokil",
	2335528,
	"poz-mic",
	"Latn",
	"Tiếng Mokil",
	"Mokil",
}

m["mkk"] = {
	"Byep",
	35052,
	"bnt-mka",
}

m["mkl"] = {
	"Mokole",
	36047,
}

m["mkm"] = {
	"tiếng Moklen",
	3319380,
	"poz",
	"Latn, Thai",
	"Tiếng Moklen",
	"Moklen"
}

m["mkn"] = {
	"Kupang Malay",
	18458203,
	"crp",
}

m["mko"] = {
	"Mingang Doso",
	3915382,
	"alv-bwj",
}

m["mkp"] = {
	"Moikodi",
	6894594,
	"ngf",
}

m["mkq"] = {
	"Bay Miwok",
	3460957,
	"nai-you",
	"Latn",
}

m["mkr"] = {
	"Malas",
	11732402,
	"ngf-mad",
}

m["mks"] = {
	"Silacayoapan Mixtec",
	7514027,
	"omq-mxt",
	"Latn",
}

m["mkt"] = {
	"Vamale",
	14916907,
	"poz-cln",
	"Latn",
}

m["mku"] = {
	"Konyanka Maninka",
	11163298,
	"dmn-mnk",
}

m["mkv"] = {
	"Mafea",
	3073532,
	"poz-vnc",
	"Latn",
}

m["mkx"] = {
	"Cinamiguin Manobo",
	12953697,
	"mno",
}

m["mky"] = {
	"East Makian",
	3512690,
	"poz-hce",
	"Latn",
}

m["mkz"] = {
	"tiếng Makasae",
	35782,
	"paa-eti",
	"Latn",
}

m["mla"] = {
	"Tamambo",
	1153276,
	"poz-vnc",
	"Latn",
}

m["mlb"] = {
	"Mbule",
	35843,
	"nic-ymb",
	"Latn",
}

m["mlc"] = {
	"tiếng Sán Chay",
	3446682,
	"tai-cho",
	"Latn, Hani",
	"Tiếng Sán Chay",
	"Sán Chay",
	sort_key = {Hani = "Hani-sortkey"},
}

m["mle"] = {
	"Manambu",
	11732406,
	"paa-spk",
	"Latn",
}

m["mlf"] = {
	"tiếng Mal",
	3281057,
	"mkh-khm",
	"Thai",
	"Tiếng Mal",
	"Mal",
}

m["mlh"] = {
	"Mape",
	6753787,
}

m["mli"] = {
	"Malimpung",
	12473435,
}

m["mlj"] = {
	"Miltu",
	3441310,
}

m["mlk"] = {
	"Ilwana",
	6001357,
	"bnt-sab",
}

m["mll"] = {
	"Malua Bay",
	6744946,
	"poz-vnc",
	"Latn",
}

m["mlm"] = {
	"Mulam",
	3092284,
	"qfa-kms",
	"Latn",
}

m["mln"] = {
	"Malango",
	3281522,
	"poz-sls",
	"Latn",
}

m["mlo"] = {
	"Mlomp",
	36009,
	"alv-bak",
}

m["mlp"] = {
	"Bargam",
	4860543,
	"ngf-mad",
	"Latn",
}

m["mlq"] = {
	"Western Maninkakan",
	11028033,
	"dmn-wmn",
}

m["mlr"] = {
	"Vame",
	3515088,
}

m["mls"] = {
	"Masalit",
	56557,
	"ssa",
}

m["mlu"] = {
	"To'abaita",
	36645,
	"poz-sls",
	"Latn",
}

m["mlv"] = {
	"tiếng Mwotlap",
	2475538,
	"poz-vnc",
	"Latn",
	"Tiếng Mwotlap",
	"Mwotlap",
}

m["mlw"] = {
	"Moloko",
	1965222,
	"cdc-cbm",
	"Latn",
}

m["mlx"] = {
	"Malfaxal",
	2157421,
	"poz-vnc",
	"Latn",
}

m["mlz"] = {
	"Malaynon",
	18755512,
	"phi",
}

m["mma"] = {
	"Mama",
	3913963,
	"nic-jrn",
}

m["mmb"] = {
	"Momina",
	6897297,
}

m["mmc"] = {
	"tiếng Mazahua Michoacán",
	12953705,
	"oto",
	"Latn",
	"Tiếng Mazahua Michoacán",
	"Mazahua Michoacán",
}

m["mmd"] = {
	"tiếng Mao Nam",
	3092293,
	"qfa-kms",
	"Latn",
	"Tiếng Mao Nam",
	"Mao Nam",
}

m["mme"] = {
	"Mae",
	3276286,
	"poz-vnc",
	"Latn",
}

m["mmf"] = {
	"Mundat",
	56263,
	"cdc-wst",
	"Latn",
}

m["mmg"] = {
	"North Ambrym",
	2842468,
	"poz-vnc",
	"Latn",
}

m["mmh"] = {
	"Mehináku",
	3501838,
	"awd",
	"Latn",
}

m["mmi"] = {
	"Musar",
	6940113,
	"ngf-mad",
}

m["mmj"] = {
	"Majhwar",
	6737795,
}

m["mmk"] = {
	"Mukha-Dora",
	6933447,
}

m["mml"] = {
	"Man Met",
	3194984,
	"mkh-pal",
}

m["mmm"] = {
	"Maii",
	6735599,
	"poz-vnc",
	"Latn",
}

m["mmn"] = {
	"Mamanwa",
	3206623,
	"phi",
	"Latn",
}

m["mmo"] = {
	"Mangga Buang",
	12952294,
	"poz-ocw",
	"Latn",
}

m["mmp"] = {
	"Musan",
	2605703,
	"paa-asa",
}

m["mmq"] = {
	"Aisi",
	6940074,
	"ngf-mad",
	"Latn",
}

m["mmr"] = {
	"tiếng H'Mông Tương Tây Tây",
	3307901,
	"hmn",
	nil,
	"Tiếng H'Mông Tương Tây Tây",
	"H'Mông Tương Tây Tây",
}

m["mmt"] = {
	"Malalamai",
	3281496,
	"poz-ocw",
	"Latn",
}

m["mmu"] = {
	"Mmaala",
	13123461,
	"nic-ymb",
	"Latn",
}

m["mmv"] = {
	"Miriti",
	6873567,
	"sai-tuc",
	"Latn",
}

m["mmw"] = {
	"Emae",
	3051961,
	"poz-pnp",
	"Latn",
}

m["mmx"] = {
	"Madak",
	3275205,
	"poz-ocw",
	"Latn",
}

m["mmy"] = {
	"Migaama",
	56259,
	"cdc-est",
	"Latn",
}

m["mmz"] = {
	"Mabaale",
	11003249,
	"bnt-ngn",
}

m["mna"] = {
	"Mbula",
	3303572,
	"poz-ocw",
	"Latn",
}

m["mnb"] = {
	"tiếng Muna",
	6935584,
	"poz-mun",
	"Latn",
	"Tiếng Muna",
	"Muna",
}

m["mnc"] = {
	"tiếng Mãn Châu",
	33638,
	"tuw-jrc",
	"mnc-Mong, Latn",
	"Tiếng Mãn Châu",
	"Mãn Châu",
	ancestors = "juc",
	translit = "mnc-translit",
}

m["mnd"] = {
	"Mondé",
	6898840,
	"tup",
	"Latn",
}

m["mne"] = {
	"Naba",
	760732,
	"csu-bgr",
}

m["mnf"] = {
	"Mundani",
	35839,
	"nic-mom",
	"Latn",
}

m["mng"] = {
	"tiếng M'Nông Đông",
	12953747,
	"mkh-ban",
	"Latn, Khmr",
	"Tiếng M'Nông Đông",
	"M'Nông Đông",
}

m["mnh"] = {
	"Mono (Congo)",
	33501,
	"bad-cnt",
	"Latn",
}

m["mni"] = {
	"tiếng Manipur",
	33868,
	"sit",
	"Mtei, Beng",
	"Tiếng Manipur",
	"Manipur",
	ancestors = "omp",
	translit = {Mtei = "Mtei-translit"},
}

m["mnj"] = {
	"tiếng Munji",
	33639,
	"ira-mny",
	"Arab",
	"Tiếng Munji",
	"Munji",
}

m["mnk"] = {
	"tiếng Mandinka",
	33678,
	"dmn-wmn",
	"Latn, Arab",
	"Tiếng Mandinka",
	"Mandinka",
}

m["mnl"] = {
	"Tiale",
	6744350,
	"poz-vnc",
	"Latn",
}

m["mnm"] = {
	"Mapena",
	11732415,
}

m["mnn"] = {
	"tiếng M'Nông Nam",
	23857582,
	"mkh-ban",
	nil,
	"Tiếng M'Nông Nam",
	"M'Nông Nam"
}

m["mnp"] = {
	"tiếng Mân Bắc",
	36457,
	"zhx-inm",
	"Hants",
	"Tiếng Mân Bắc",
	"Mân Bắc",
	generate_forms = "zh-generateforms",
	translit = "zh-translit",
	sort_key = "Hani-sortkey",
}

m["mnq"] = {
	"tiếng Minriq",
	2742268,
	"mkh-asl",
	"Latn",
	"Tiếng Minriq",
	"Minriq"
}

m["mnr"] = {
	"Mono (California)",
	33591,
	"azc-num",
	"Latn",
}

m["mnt"] = {
	"Maykulan",
	3915696,
	"aus-pam",
	"Latn",
}

m["mnu"] = {
	"Mer",
	6817854,
}

m["mnv"] = {
	"Rennellese",
	3397346,
	"poz-pnp",
	"Latn",
}

m["mnw"] = {
	"tiếng Môn",
	13349,
	"mkh-mnc",
	"Mymr",
	"Tiếng Môn",
	"Môn",
	ancestors = "mkh-mmn",
	translit = "mnw-translit",
	sort_key = {
		from = {"ျ", "ြ", "ွ", "ှ", "ၞ", "ၟ", "ၠ", "ၚ", "ဿ"},
		to = {"္ယ", "္ရ", "္ဝ", "္ဟ", "္န", "္မ", "္လ", "င", "သ္သ"}
	},
}

m["mnx"] = {
	"Manikion",
	3507964,
	"paa-wpa",
}

m["mny"] = {
	"Manyawa",
	11002622,
	"bnt-mak",
	ancestors = "vmw",
}

m["mnz"] = {
	"Moni",
	6899857,
}

m["moa"] = {
	"tiếng Mwan",
	3320111,
	"dmn-nbe",
	"Latn",
	"Tiếng Mwan",
	"Mwan",
}

m["moc"] = {
	"Mocoví",
	3027906,
	"sai-guc",
	"Latn",
}

m["mod"] = {
	"Mobilian",
	13333,
	"crp",
	"Latn",
	ancestors = "cho, cic",
}

m["moe"] = {
	"Montagnais",
	13351,
	"alg",
	"Latn",
	ancestors = "cr",
	entry_name = {remove_diacritics = c.macron},
}

m["mog"] = {
	"tiếng Mongondow",
	3058458,
	"phi",
	"Latn",
	"Tiếng Mongondow",
	"Mongondow",
}

m["moh"] = {
	"tiếng Mohawk",
	13339,
	"iro-nor",
	"Latn",
	"Tiếng Mohawk",
	"Mohawk",
	ancestors = "iro-omo",
}

m["moi"] = {
	"Mboi",
	3914417,
	"alv-yun",
}

m["moj"] = {
	"Monzombo",
	11154772,
	"nic-nkk",
	"Latn",
}

m["mok"] = {
	"Morori",
	6913275,
}

m["mom"] = {
	"Monimbo",
	56542,
}

m["moo"] = {
	"tiếng Mơ Nâm",
	6901726,
	"mkh-nbn",
	"Latn",
	"Tiếng Mơ Nâm",
	"Mơ Nâm"
}

m["mop"] = {
	"Mopan Maya",
	36183,
	"myn",
	"Latn",
}

m["moq"] = {
	"Mor (Papuan)",
	11732468,
	"paa",
}

m["mor"] = {
	"tiếng Moro",
	36172,
	"alv-hei",
	"Latn",
	"Tiếng Moro",
	"Moro",
}

m["mos"] = {
	"tiếng Mooré",
	36096,
	"nic-mre",
	"Latn",
	"Tiếng Mooré",
	"Mooré",
}

m["mot"] = {
	"Barí",
	2886281,
	"cba",
	"Latn",
}

m["mou"] = {
	"Mogum",
	3440473,
	"cdc-est",
	"Latn",
}

m["mov"] = {
	"Mojave",
	56510,
	"nai-yuc",
	"Latn",
}

m["mow"] = {
	"Moi (Congo)",
	11124792,
	"bnt-bmo",
	"Latn",
}

m["mox"] = {
	"Molima",
	3319495,
	"poz-ocw",
	"Latn",
}

m["moy"] = {
	"tiếng Shekkacho",
	56827,
	"omv-gon",
	"Ethi, Latn",
	"Tiếng Shekkacho",
	"Shekkacho",
}

m["moz"] = {
	"Mukulu",
	3440403,
	"cdc-est",
}

m["mpa"] = {
	"Mpoto",
	6928303,
	"bnt-mbi",
}

m["mpb"] = {
	"Mullukmulluk",
	6741120,
}

m["mpc"] = {
	"Mangarayi",
	6748829,
}

m["mpd"] = {
	"Machinere",
	12953681,
	"awd",
	"Latn",
}

m["mpe"] = {
	"tiếng Majang",
	56724,
	"sdv",
	"Ethi",
	"Tiếng Majang",
	"Majang",
}

m["mpg"] = {
	"Marba",
	56614,
	"cdc-mas",
}

m["mph"] = {
	"tiếng Maung",
	6792550,
	"aus-wdj",
	"Latn",
}

m["mpi"] = {
	"tiếng Mpade",
	3280670,
	"cdc-cbm",
	"Latn",
	"Tiếng Mpade",
	"Mpade",
}

m["mpj"] = {
	"Martu Wangka",
	3295916,
	"aus-pam",
	"Latn",
}

m["mpk"] = {
	"Mbara (Chad)",
	3912770,
	"cdc-cbm",
}

m["mpl"] = {
	"Middle Watut",
	15887910,
	"poz-ocw",
	"Latn",
}

m["mpm"] = {
	"tiếng Mixtec Yosondúa",
	12953741,
	"omq-mxt",
	"Latn",
	"Tiếng Mixtec Yosondúa",
	"Mixtec Yosondúa",
}

m["mpn"] = {
	"Mindiri",
	6863842,
	"poz-ocw",
	"Latn",
}

m["mpo"] = {
	"Miu",
	6883668,
	"poz-ocw",
	"Latn",
}

m["mpp"] = {
	"Migabac",
	11732448,
}

m["mpq"] = {
	"Matís",
	3299145,
	"sai-pan",
	"Latn",
}

m["mpr"] = {
	"Vangunu",
	3554582,
	"poz-ocw",
	"Latn",
}

m["mps"] = {
	"tiếng Dadibi",
	5208077,
	"ngf",
	"Latn",
	"Tiếng Dadibi",
	"Dadibi",
}

m["mpt"] = {
	"Mian",
	12952846,
	"ngf-okk",
	"Latn",
}

m["mpu"] = {
	"Makuráp",
	3281037,
	"tup",
	"Latn",
}

m["mpv"] = {
	"Mungkip",
	11732485,
	"ngf-fin",
	"Latn",
}

m["mpw"] = {
	"Mapidian",
	6753812,
	"awd",
	"Latn",
}

m["mpx"] = {
	"Misima-Paneati",
	6875666,
	"poz-ocw",
	"Latn",
}

m["mpy"] = {
	"Mapia",
	3287224,
	"poz-mic",
	"Latn",
}

m["mpz"] = {
	"tiếng Mpi",
	6928276,
	"tbq-bka",
	"Thai",
	"Tiếng Mpi",
	"Mpi",
}

m["mqa"] = {
	"Maba",
	3273750,
}

m["mqb"] = {
	"Mbuko",
	3502213,
	"cdc-cbm",
	"Latn",
}

m["mqc"] = {
	"Mangole",
	6749097,
	"poz-cma",
	"Latn",
}

m["mqe"] = {
	"Matepi",
	11732426,
	"ngf-mad",
}

m["mqf"] = {
	"Momuna",
	6897518,
}

m["mqg"] = {
	"Kota Bangun Kutai Malay",
	12952778,
}

m["mqh"] = {
	"Tlazoyaltepec Mixtec",
	12953740,
	"omq-mxt",
	"Latn",
}

m["mqi"] = {
	"Mariri",
	6765544,
}

m["mqj"] = {
	"Mamasa",
	6745452,
	"poz-ssw",
	"Latn",
}

m["mqk"] = {
	"Rajah Kabunsuwan Manobo",
	12953700,
	"mno",
}

m["mql"] = {
	"tiếng Mbelime",
	4286473,
	"nic-eov",
	"Latn",
	"Tiếng Mbelime",
	"Mbelime",
}

m["mqm"] = {
	"tiếng Marquises Nam",
	19694214,
	"poz-pep",
	"Latn",
	"Tiếng Marquises Nam",
	"Marquises Nam",
}

m["mqn"] = {
	"Moronene",
	642581,
	"poz-btk",
	"Latn",
}

m["mqo"] = {
	"Modole",
	11732457,
	"paa-nha",
}

m["mqp"] = {
	"Manipa",
	6749799,
	"poz-cma",
	"Latn",
}

m["mqq"] = {
	"Minokok",
	18642293,
}

m["mqr"] = {
	"Mander",
	6747979,
	"paa-tkw",
}

m["mqs"] = {
	"tiếng Tây Makian",
	3033575,
	"paa-nha",
	nil,
	"Tiếng Tây Makian",
	"Tây Makian",
}

m["mqt"] = {
	"Mok",
	13018559,
	"mkh-pal",
}

m["mqu"] = {
	"Mandari",
	3285426,
	"sdv-bri",
}

m["mqv"] = {
	"Mosimo",
	11732478,
	"ngf-mad",
	"Latn",
}

m["mqw"] = {
	"Murupi",
	11732486,
	"ngf-mad",
	"Latn",
}

m["mqx"] = {
	"Mamuju",
	6746004,
	"poz-ssw",
	"Latn",
}

m["mqy"] = {
	"tiếng Manggarai",
	3285748,
	"poz-cet",
	"Latn",
	"Tiếng Manggarai",
	"Manggarai",
}

m["mqz"] = {
	"Malasanga",
	14916889,
	"poz-ocw",
	"Latn",
}

m["mra"] = {
	"tiếng Mlabri",
	3073465,
	"mkh-khm",
	nil,
	"Tiếng Mlabri",
	"Mlabri"
}

m["mrb"] = {
	"Marino",
	3293299,
}

m["mrc"] = {
	"tiếng Maricopa",
	56386,
	"nai-yuc",
	"Latn",
	"Tiếng Maricopa",
	"Maricopa",
}

m["mrd"] = {
	"tiếng Magar Tây",
	22303263,
	"sit-gma",
	"Deva",
	"Tiếng Magar Tây",
	"Magar Tây",
}

m["mre"] = {
	"Martha's Vineyard Sign Language",
	33494,
	"sgn",
	"Latn, Sgnw",
}

m["mrf"] = {
	"Elseng",
	3915667,
	"paa-brd",
}

m["mrg"] = {
	"tiếng Mising",
	3316328,
	"sit-tan",
	"Latn, Beng, Deva",
	"Tiếng Mising",
	"Mising",
	ancestors = "adi",
}

m["mrh"] = {
	"Mara Chin",
	4175893,
	"tbq-kuk",
	"Latn",
}

m["mrj"] = {
	"tiếng Mari Tây",
	1776032,
	"chm",
	"Cyrl",
	"Tiếng Mari Tây",
	"Mari Tây",
	translit = "chm-translit",
	sort_key = "mrj-sortkey",
}

m["mrk"] = {
	"Hmwaveke",
	5873712,
	"poz-cln",
	"Latn",
}

m["mrl"] = {
	"Mortlockese",
	3324598,
	"poz-mic",
	"Latn",
}

m["mrm"] = {
	"Merlav",
	3331115,
	"poz-vnc",
	"Latn",
}

m["mrn"] = {
	"Cheke Holo",
	2962165,
	"poz-ocw",
	"Latn",
}

m["mro"] = {
	"Mru",
	1951521,
	"sit-mru",
	"Latn, Mroo",
}

m["mrp"] = {
	"Morouas",
	6913299,
	"poz-vnc",
	"Latn",
}

m["mrq"] = {
	"tiếng Marquises Bắc",
	2603808,
	"poz-pep",
	"Latn",
	"Tiếng Marquises Bắc",
	"Marquises Bắc",
}

m["mrr"] = {
	"tiếng Maria (Ấn Độ)",
	27602,
	"dra-mdy",
	"Deva",
	"Tiếng Maria (Ấn Độ)",
	"Maria (Ấn Độ)",
}

m["mrs"] = {
	"Maragus",
	6754640,
	"poz-vnc",
	"Latn",
}

m["mrt"] = {
	"Margi",
	56241,
	"cdc-cbm",
	"Latn",
}

m["mru"] = {
	"Mono (Cameroon)",
	11031964,
	"alv-mbm",
	"Latn",
}

m["mrv"] = {
	"Mangarevan",
	36237,
	"poz-pep",
	"Latn",
}

m["mrw"] = {
	"tiếng Maranao",
	33800,
	"phi",
	"Latn, Arab",
	"Tiếng Maranao",
	"Maranao",
}

m["mrx"] = {
	"Dineor",
	5278044,
	"paa-tkw",
}

m["mry"] = {
	"Karaga Mandaya",
	6747925,
	"phi",
}

m["mrz"] = {
	"Marind",
	6763970,
}

m["msb"] = {
	"tiếng Masbatenyo",
	33948,
	"phi",
	"Latn",
	"Tiếng Masbatenyo",
	"Masbatenyo",
}

m["msc"] = {
	"Sankaran Maninka",
	11155812,
	"dmn-mnk",
}

m["msd"] = {
	"Yucatec Maya Sign Language",
	34281,
	"sgn",
	"Latn", -- when documented
}

m["mse"] = {
	"Musey",
	56328,
	"cdc-mas",
}

m["msf"] = {
	"Mekwei",
	4544752,
	"paa-nim",
	"Latn",
}

m["msg"] = {
	"Moraid",
	6909020,
}

m["msi"] = {
	"Sabah Malay",
	10867404,
	"crp",
}

m["msj"] = {
	"Ma",
	6720909,
	"nic-mbc",
	"Latn",
}

m["msk"] = {
	"tiếng Mansaka",
	12952800,
	"phi",
	"Latn",
	"Tiếng Mansaka",
	"Mansaka",
}

m["msl"] = {
	"Molof",
	4300950,
}

m["msm"] = {
	"Agusan Manobo",
	12953696,
	"mno",
}

m["msn"] = {
	"tiếng Vurës",
	3563857,
	"poz-vnc",
	"Latn",
	"Tiếng Vurës",
	"Vurës",
}

m["mso"] = {
	"Mombum",
	6897079,
}

m["msp"] = {
	"Maritsauá",
	6765915,
	"tup",
	"Latn",
}

m["msq"] = {
	"Caac",
	2932212,
	"poz-cln",
	"Latn",
}

m["msr"] = {
	"Mongolian Sign Language",
	3915499,
	"sgn",
}

m["mss"] = {
	"West Masela",
	12952816,
	"poz-tim",
}

m["msu"] = {
	"Musom",
	6943041,
	"poz-ocw",
	"Latn",
}

m["msv"] = {
	"Maslam",
	3502273,
}

m["msw"] = {
	"Mansoanka",
	35814,
}

m["msx"] = {
	"Moresada",
	11732475,
}

m["msy"] = {
	"Aruamu",
	3501809,
	"paa",
	"Latn",
}

m["msz"] = {
	"Momare",
	6897030,
}

m["mta"] = {
	"Cotabato Manobo",
	12953698,
	"mno",
}

m["mtb"] = {
	"Anyin Morofo",
	3502338,
	"alv-ctn",
	"Latn",
	ancestors = "any",
}

m["mtc"] = {
	"Munit",
	11732482,
	"ngf-mad",
}

m["mtd"] = {
	"Mualang",
	3073458,
	"poz-mly",
}

m["mte"] = {
	"Alu",
	33503,
	"poz-ocw",
	"Latn",
}

m["mtf"] = {
	"Murik (New Guinea)",
	7050035,
	"paa-lsp",
	"Latn",
}

m["mtg"] = {
	"Una",
	5580728,
}

m["mth"] = {
	"tiếng Munggui",
	6936018,
	"poz-hce",
	"Latn",
}

m["mti"] = {
	"Maiwa (New Guinea)",
	6737223,
	"ngf",
	"Latn",
}

m["mtj"] = {
	"Moskona",
	11288953,
}

m["mtk"] = {
	"Mbe'",
	10964025,
	"nic-nka",
	"Latn",
}

m["mtl"] = {
	"Montol",
	3440457,
	"cdc-wst",
	"Latn",
}

m["mtm"] = {
	"tiếng Mator",
	20669419,
	"syd",
	"Cyrl",
	"Tiếng Mator",
	"Mator",
}

m["mtn"] = {
	"Matagalpa",
	3490756,
	"nai-min",
}

m["mto"] = {
	"Totontepec Mixe",
	7828400,
	"nai-miz",
}

m["mtp"] = {
	"Wichí Lhamtés Nocten",
	5908756,
	"sai-wic",
	"Latn",
}

m["mtq"] = {
	"tiếng Mường",
	3236789,
	"mkh-vie",
	"Latn",
	"Tiếng Mường",
	"Mường",
	sort_key = "vi-sortkey",
}

m["mtr"] = {
	"Mewari",
	nil,
	"inc-wes",
	"Deva",
	ancestors = "raj",
	translit = "hi-translit", -- for now
}

m["mts"] = {
	"Yora",
	3572572,
	"sai-pan",
	"Latn",
}

m["mtt"] = {
	"tiếng Mota",
	3325052,
	"poz-vnc",
	"Latn",
	"Tiếng Mota",
	"Mota",
}

m["mtu"] = {
	"Tututepec Mixtec",
	7857069,
	"omq-mxt",
	"Latn",
}

m["mtv"] = {
	"Asaro'o",
	3503684,
	"ngf-fin",
	"Latn",
}

m["mtw"] = {
	"Magahat",
	6729600,
	"phi",
}

m["mtx"] = {
	"Tidaá Mixtec",
	7800805,
	"omq-mxt",
	"Latn",
}

m["mty"] = {
	"Nabi",
	6956858,
	"qfa-tor",
	"Latn",
}

m["mua"] = {
	"Mundang",
	36032,
	"alv-mbm",
}

m["mub"] = {
	"Mubi",
	3440518,
	"cdc-est",
	"Latn",
}

m["muc"] = {
	"Mbu'",
	35868,
	"nic-beb",
	"Latn",
}

m["mud"] = {
	"Mednyj Aleut",
	1977419,
	"qfa-mix",
	ancestors = "ale, ru"
}

m["mue"] = {
	"tiếng Quichuañol",
	36066,
	"crp",
	"Latn",
	"Tiếng Quichuañol",
	"Quichuañol",
	ancestors = "es, qu",
}

m["mug"] = {
	"Musgu",
	3123545,
	"cdc-cbm",
	"Latn",
}

m["muh"] = {
	"Mündü",
	35981,
	"nic-nke",
	"Latn",
}

m["mui"] = {
	"tiếng Musi",
	615660,
	"poz-mly",
	"Latn",
}

m["muj"] = {
	"Mabire",
	3440437,
}

m["mul"] = {
	"đa ngữ",
	20923490,
	"qfa-not",
	"All",
	"Đa ngữ",
	"đa ngữ",
	wikipedia_article = "Translingualism",
	sort_key = {
		Hani = "Hani-sortkey",
		Jpan = "Jpan-sortkey",
		Hrkt = "Hira-sortkey", -- Sort all kana as Hira.
		Hira = "Hira-sortkey",
		Kana = "Hira-sortkey",
	},
	standardChars = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz" .. c.punc,
}

m["mum"] = {
	"Maiwala",
	12952764,
	"poz-ocw",
	"Latn",
}

m["muo"] = {
	"Nyong",
	36373,
	"alv-lek",
}

m["mup"] = {
	"tiếng Malvi",
	33413,
	"inc-wes",
	"Deva",
	"Tiếng Malvi",
	"Malvi",
	ancestors = "raj",
	translit = "hi-translit"
}

m["muq"] = {
	"Eastern Xiangxi Miao",
	27431376,
	"hmn",
}

m["mur"] = {
	"tiếng Murle",
	56727,
	"sdv",
	"Latn",
	"Tiếng Murle",
	"Murle",
}

m["mus"] = {
	"tiếng Muscogee",
	523014,
	"nai-mus",
	"Latn",
	"Tiếng Muscogee",
	"Muscogee",
}

m["mut"] = {
	"Western Muria",
	12952886,
	"dra-mur",
}

m["muu"] = {
	"tiếng Yaaku",
	34222,
	"cus-eas",
	"Latn",
	"Tiếng Yaaku",
	"Yaaku",
}

m["muv"] = {
	"tiếng Muthuvan",
	3327420,
	"dra-tam",
	"Mlym, Taml",
	"Tiếng Muthuvan",
	"Muthuvan",
	translit = {
		Mlym = "ml-translit",
		Taml = "ta-translit",
	},
}

m["mux"] = {
	"Bo-Ung",
	15831607,
}

m["muy"] = {
	"Muyang",
	3502301,
	"cdc-cbm",
	"Latn",
}

m["muz"] = {
	"tiếng Mursi",
	36013,
	"sdv",
	"Ethi, Latn",
	"Tiếng Mursi",
	"Mursi",
}

m["mva"] = {
	"Manam",
	6746851,
	"poz-ocw",
	"Latn",
}

m["mvb"] = {
	"Mattole",
	20824,
	"ath-pco",
	"Latn",
}

m["mvd"] = {
	"Mamboru",
	578815,
	"poz",
}

m["mvg"] = {
	"Yucuañe Mixtec",
	25562736,
	"omq-mxt",
	"Latn",
}

m["mvh"] = {
	"Mire",
	3441359,
}

m["mvi"] = {
	"tiếng Miyako",
	36218,
	"jpx-sry",
	"Jpan",
	"Tiếng Miyako",
	"Miyako",
	translit = s["Jpan-translit"],
	sort_key = s["Jpan-sortkey"],
}

m["mvk"] = {
	"Mekmek",
	6810592,
	"paa-yua",
}

m["mvl"] = {
	"Mbara (Australia)",
	6799620,
	"aus-pam",
}

m["mvm"] = {
	"Muya",
	2422759,
	"sit-qia",
}

m["mvn"] = {
	"Minaveha",
	6863278,
	"poz-ocw",
	"Latn",
}

m["mvo"] = {
	"Marovo",
	3294683,
	"poz-ocw",
	"Latn",
}

m["mvp"] = {
	"Duri",
	3915414,
	"poz-ssw",
}

m["mvq"] = {
	"Moere",
	11732458,
	"ngf-mad",
}

m["mvr"] = {
	"tiếng Marau",
	6755069,
	"poz-hce",
	"Latn",
}

m["mvs"] = {
	"Massep",
	3502895,
	"paa-tkw",
}

m["mvt"] = {
	"Mpotovoro",
	6928305,
	"poz-vnc",
	"Latn",
}

m["mvu"] = {
	"Marfa",
	713633,
}

m["mvv"] = {
	"tiếng Tagal Murut",
	7675300,
	"poz-san",
	"Latn",
	"Tiếng Tagal Murut",
	"Tagal Murut",
}

m["mvw"] = {
	"Machinga",
	12952754,
	"bnt-rvm",
}

m["mvx"] = {
	"Meoswar",
	6817777,
	"poz-hce",
	"Latn",
}

m["mvy"] = {
	"tiếng Kohistan",
	33399,
	"inc-koh",
	nil,
	"Tiếng Kohistan",
	"Kohistan",
}

m["mvz"] = {
	"tiếng Mesqan",
	6821677,
	"sem-eth",
	"Ethi",
	"Tiếng Mesqan",
	"Mesqan",
}

m["mwa"] = {
	"Mwatebu",
	14916896,
	"poz-ocw",
	"Latn",
}

m["mwb"] = {
	"Juwal",
	6319103,
	"qfa-tor",
	"Latn",
}

m["mwc"] = {
	"Are",
	29277,
	"poz-ocw",
	"Latn",
}

m["mwe"] = {
	"Mwera",
	6944725,
	"bnt-rvm",
	"Latn",
}

m["mwf"] = {
	"Murrinh-Patha",
	2980398,
	"aus-dal",
	"Latn",
}

m["mwg"] = {
	"Aiklep",
	3399652,
	"poz-ocw",
	"Latn",
}

m["mwh"] = {
	"Mouk-Aria",
	3325498,
	"poz-ocw",
	"Latn",
}

m["mwi"] = {
	"Labo",
	2157452,
	"poz-vnc",
	"Latn",
}

m["mwk"] = {
	"Kita Maninkakan",
	3015523,
	"dmn-wmn",
}

m["mwl"] = {
	"tiếng Miranda",
	13330,
	"roa-ibe",
	"Latn",
	"Tiếng Miranda",
	"Miranda",
	ancestors = "roa-ole",
}

m["mwm"] = {
	"tiếng Sar",
	56850,
	"csu-sar",
	"Latn",
	"Tiếng Sar",
	"Sar",
}

m["mwn"] = {
	"Nyamwanga",
	6944666,
	"bnt-mwi",
}

m["mwo"] = {
	"Central Maewo",
	3276435,
}

m["mwp"] = {
	"Kala Lagaw Ya",
	2591262,
	"aus-pam",
	"Latn",
}

m["mwq"] = {
	"Mün Chin",
	331340,
	"tbq-kuk",
}

m["mwr"] = {
	"tiếng Marwar",
	56312,
	"inc-wes",
	"Deva, Mahj",
	"Tiếng Marwar",
	"Marwar",
	ancestors = "raj",
	translit = {
		Deva = "hi-translit", -- for now
		Mahj = "Mahj-translit",
	},
}

m["mws"] = {
	"Mwimbi-Muthambi",
	15632357,
	"bnt-kka",
	"Latn",
}

m["mwt"] = {
	"tiếng Moken",
	18648701,
	"poz",
	nil,
	"Tiếng Moken",
	"Moken"
}

m["mwu"] = {
	"Mittu",
	6883573,
	"csu-bbk",
	"Latn",
}

m["mwv"] = {
	"tiếng Mentawai",
	13365,
	"poz-nws",
	"Latn",
	"Tiếng Mentawai",
	"Mentawai",
}

m["mww"] = {
	"tiếng Mông Trắng",
	3138829,
	"hmn",
	"Latn, Hmng, Hmnp",
	"Tiếng Mông Trắng",
	"Mông Trắng",
}

m["mwz"] = {
	"Moingi",
	11011905,
}

m["mxa"] = {
	"Northwest Oaxaca Mixtec",
	12953739,
	"omq-mxt",
	"Latn",
}

m["mxb"] = {
	"Tezoatlán Mixtec",
	3317286,
	"omq-mxt",
	"Latn",
}

m["mxd"] = {
	"Modang",
	6888037,
	"poz",
}

m["mxe"] = {
	"Mele-Fila",
	3305008,
	"poz-pnp",
	"Latn",
}

m["mxf"] = {
	"Malgbe",
	3502224,
}

m["mxg"] = {
	"Mbangala",
	6799612,
	"bnt-yak",
}

m["mxh"] = {
	"Mvuba",
	6944591,
	"csu-mle",
	"Latn",
}

m["mxi"] = {
	"tiếng Mozarab",
	317044,
	"roa-ibe",
	"Arab, Hebr, Latn",
	"Tiếng Mozarab",
	"Mozarab",
	translit = "mxi-translit",
}

m["mxj"] = {
	"Miju",
	56332,
	"sit-mdz",
	"Latn, Deva",
}

m["mxk"] = {
	"Monumbo",
	6906792,
	"qfa-tor",
}

m["mxl"] = {
	"Maxi Gbe",
	35770,
	"alv-gbe",
}

m["mxm"] = {
	"Meramera",
	6817936,
	"poz-ocw",
	"Latn",
}

m["mxn"] = {
	"Moi (Indonesia)",
	11732459,
	"paa",
}

m["mxo"] = {
	"Mbowe",
	10962309,
	"bnt-kav",
}

m["mxp"] = {
	"Tlahuitoltepec Mixe",
	7810697,
}

m["mxq"] = {
	"Juquila Mixe",
	25559721,
}

m["mxr"] = {
	"Murik (Malaysia)",
	3328150,
	nil,
	"Latn",
}

m["mxs"] = {
	"Huitepec Mixtec",
	12953729,
	"omq-mxt",
	"Latn",
}

m["mxt"] = {
	"Jamiltepec Mixtec",
	12953730,
	"omq-mxt",
	"Latn",
}

m["mxu"] = {
	"Mada (Cameroon)",
	3441206,
	"cdc-cbm",
	"Latn",
}

m["mxv"] = {
	"Metlatónoc Mixtec",
	36363,
	"omq-mxt",
	"Latn",
}

m["mxw"] = {
	"Namo",
	12952923,
}

m["mxx"] = {
	"Mahou",
	11004334,
	"dmn-mnk",
}

m["mxy"] = {
	"Southeastern Nochixtlán Mixtec",
	7070684,
	"omq-mxt",
	"Latn",
}

m["mxz"] = {
	"Central Masela",
	42575433,
	"poz-tim",
}

m["myb"] = {
	"tiếng Mbay",
	3033565,
	"csu-sar",
	"Latn",
	"Tiếng Mbay",
	"Mbay",
}

m["myc"] = {
	"Mayeka",
	11129517,
	"bnt-boa",
}

m["mye"] = {
	"tiếng Myene",
	35832,
	"bnt-tso",
	"Latn",
	"Tiếng Myene",
	"Myene",
}

m["myf"] = {
	"tiếng Bambassi",
	56540,
	"omv-mao",
	nil,
	"Tiếng Bambassi",
	"Bambassi",
}

m["myg"] = {
	"Manta",
	35799,
	"nic-mom",
	"Latn",
}

m["myh"] = {
	"Makah",
	3280640,
	"wak",
	"Latn",
}

m["myj"] = {
	"Mangayat",
	35988,
	"nic-ser",
}

m["myk"] = {
	"tiếng Senoufo Mamara",
	36187,
	"alv-sma",
	"Latn",
	"Tiếng Senoufo Mamara",
	"Senoufo Mamara",
}

m["myl"] = {
	"Moma",
	6897018,
	"poz",
}

m["mym"] = {
	"tiếng Me'en",
	3408516,
	"sdv",
	"Ethi, Latn",
	"Tiếng Me'en",
	"Me'en",
}

m["myo"] = {
	"Anfillo",
	34928,
	"omv-gon",
}

m["myp"] = {
	"Pirahã",
	33825,
	"sai-mur",
	"Latn",
}

m["myr"] = {
	"Muniche",
	3915654,
}

m["mys"] = {
	"Mesmes",
	3508617,
	"sem-eth",
}

m["myu"] = {
	"Mundurukú",
	746723,
	"tup",
	"Latn",
}

m["myv"] = {
	"tiếng Erzya",
	29952,
	"urj-mdv",
	"Cyrl",
	"Tiếng Erzya",
	"Erzya",
	translit = "myv-translit",
	override_translit = true,
}

m["myw"] = {
	"Muyuw",
	3502878,
	"poz-ocw",
	"Latn",
}

m["myx"] = {
	"Masaba",
	12952814,
	"bnt-msl",
	"Latn",
}

m["myy"] = {
	"Macuna",
	3275059,
	"sai-tuc",
	"Latn",
}

m["myz"] = {
	"Classical Mandaic",
	25559314,
	"sem-ase",
	"Mand",
}

m["mza"] = {
	"Santa María Zacatepec Mixtec",
	8063756,
	"omq-mxt",
	"Latn",
}

m["mzb"] = {
	"tiếng Berber Bắc Sahara",
	11156769,
	"ber",
	nil,
	"Tiếng Berber Bắc Sahara",
	"Berber Bắc Sahara",
}

m["mzc"] = {
	"Madagascar Sign Language",
	12715020,
	"sgn",
}

m["mzd"] = {
	"Malimba",
	35806,
	"bnt-saw",
}

m["mze"] = {
	"Morawa",
	6909384,
}

m["mzg"] = {
	"Monastic Sign Language",
	3217333,
	"sgn",
}

m["mzh"] = {
	"Wichí Lhamtés Güisnay",
	7998197,
	"sai-wic",
	"Latn",
}

m["mzi"] = {
	"Ixcatlán Mazatec",
	6101049,
	"omq-maz",
	"Latn",
}

m["mzj"] = {
	"Manya",
	11006832,
	"dmn-mnk",
}

m["mzk"] = {
	"Nigeria Mambila",
	11004163,
	"nic-mmb",
	"Latn",
}

m["mzl"] = {
	"Mazatlán Mixe",
	25559728,
}

m["mzm"] = {
	"Mumuye",
	36021,
	"alv-mum",
	"Latn",
}

m["mzn"] = {
	"tiếng Mazandaran",
	13356,
	"ira-msh",
	"mzn-Arab",
	"Tiếng Mazandaran",
	"Mazandaran",
}

m["mzo"] = {
	"Matipuhy",
	6787588,
	"sai-kui",
	"Latn",
}

m["mzp"] = {
	"Movima",
	1659701,
	"qfa-iso",
}

m["mzq"] = {
	"Mori Atas",
	3324070,
	"poz-btk",
}

m["mzr"] = {
	"Marúbo",
	3296011,
	"sai-pan",
	"Latn",
}

m["mzs"] = {
	"Macanese",
	35785,
	"crp",
	"Latn",
	ancestors = "pt",
	sort_key = {Latn = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.tilde .. c.diaer .. c.cedilla}},
}

m["mzt"] = {
	"tiếng Mintil",
	6869641,
	"mkh-asl",
	nil,
	"Tiếng Mintil",
	"Mintil"
}

m["mzu"] = {
	"Inapang",
	6013569,
	"paa",
	"Latn",
}

m["mzv"] = {
	"Manza",
	36038,
	"alv-gbf",
}

m["mzw"] = {
	"Deg",
	35183,
	"nic-gnw",
	"Latn",
}

m["mzx"] = {
	"Mawayana",
	6794377,
	"awd",
}

m["mzy"] = {
	"Mozambican Sign Language",
	6927809,
	"sgn",
}

m["mzz"] = {
	"Maiadomu",
	6735234,
	"poz-ocw",
	"Latn",
}

return require("Module:languages").finalizeData(m, "language")