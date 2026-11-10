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

m["naa"] = {
	"Namla",
	3508760,
	"paa-pau",
	"Latn",
}

m["nab"] = {
	"tiếng Nambikwara",
	2068190,
	"sai-nmk",
	"Latn",
	"Tiếng Nambikwara",
	"Nambikwara",
}

m["nac"] = {
	"Narak",
	6965295,
	"ngf",
	"Latn",
}

m["nae"] = {
	"Naka'ela",
	6960073,
	"poz",
	"Latn",
}

m["naf"] = {
	"Nabak",
	11732491,
	"ngf",
	"Latn",
}

m["nag"] = {
	"Naga Pidgin",
	3503454,
	"crp",
	"Latn",
	ancestors = "as",
}

m["nah"] = {
	"tiếng Nahuatl",
	13300,
	"azc-nah",
	"Latn",
	"Tiếng Nahuatl",
	"Nahuatl",
}

m["naj"] = {
	"Nalu",
	36026,
	"alv-nal",
	"Latn",
}

m["nak"] = {
	"Nakanai",
	6528669,
	"poz-ocw",
	"Latn",
}

m["nal"] = {
	"Nalik",
	3335387,
	"poz-ocw",
	"Latn",
}

m["nam"] = {
	"Ngan'gityemerri",
	3298041,
	"aus-dal",
	"Latn",
}

-- Being converted into the family "Southern Min" ("zhx-nan", which will take the code "nan" once the language can be removed). Retain the name "Min Nan" here to avoid having to move things that are scheduled for deletion anyway.
m["nan"] = {
	"tiếng Mân Nam",
	36495,
	"zhx-com",
	"Hants, Latn, Bopo, Kana",
	"Tiếng Mân Nam",
	"Mân Nam",
	wikimedia_codes = "zh-min-nan",
	generate_forms = "zh-generateforms",
	sort_key = {
		Hani = "Hani-sortkey",
		Kana = "Kana-sortkey"
	},
}

m["nao"] = {
	"Naaba",
	11883865,
	"sit-tib",
	ancestors = "xct",
}

m["nap"] = {
	"tiếng Napoli",
	33845,
	"roa-itd",
	"Latn",
	"Tiếng Napoli",
	"Napoli",
}

m["naq"] = {
	"tiếng Khoekhoe",
	13301,
	"khi-khk",
	"Latn",
	"Tiếng Khoekhoe",
	"Khoekhoe",
}

m["nar"] = {
	"Iguta",
	5621686,
	"nic-jer",
	"Latn",
}

m["nas"] = {
	"Nasioi",
	56772,
	"paa-sbo",
	"Latn",
}

m["nat"] = {
	"Hungworo",
	3914395,
	"nic-kmk",
	"Latn",
}

m["naw"] = {
	"Nawuri",
	35906,
	"alv-gng",
	"Latn",
}

m["nax"] = {
	"Nakwi",
	3504178,
	"qfa-mal",
	"Latn",
}

m["nay"] = {
	"Ngarrindjeri",
	7022091,
	"aus-pam",
	"Latn",
}

m["naz"] = {
	"Coatepec Nahuatl",
	5138605,
	"azc-nah",
	"Latn",
}

m["nba"] = {
	"Nyemba",
	3346655,
	"bnt-clu",
	"Latn",
	ancestors = "lch",
}

m["nbb"] = {
	"Ndoe",
	36134,
	"nic-eko",
	"Latn",
}

m["nbc"] = {
	"Chang",
	5071694,
	"sit-kch",
	"Latn",
}

m["nbd"] = {
	"Ngbinda",
	11132859,
	"bnt-boa",
	"Latn",
}

m["nbe"] = {
	"Konyak Naga",
	6430448,
	"sit-kch",
	"Latn",
}

m["nbg"] = {
	"Nagarchal",
	13299,
	"dra-gon",
}

m["nbh"] = {
	"Ngamo",
	3438705,
	"cdc-wst",
	"Latn",
}

m["nbi"] = {
	"Mao Naga",
	12952905,
	"tbq-anp",
	"Latn",
}

m["nbj"] = {
	"Ngarinman",
	10600380,
	nil,
	"Latn",
}

m["nbk"] = {
	"Nake",
	11732496,
	"ngf-mad",
	"Latn",
}

m["nbm"] = {
	"Ngbaka Ma'bo",
	3915331,
	"nic-nkm",
	"Latn",
}

m["nbn"] = {
	"Kuri",
	3200540,
	"poz",
	"Latn",
}

m["nbo"] = {
	"Nkukoli",
	3914482,
	"nic-uce",
	"Latn",
}

m["nbp"] = {
	"Nnam",
	36138,
	"nic-eko",
	"Latn",
}

m["nbq"] = {
	"Nggem",
	12952956,
	"ngf",
	"Latn",
}

m["nbr"] = {
	"Numana",
	5529310,
	"nic-nin",
	"Latn",
}

m["nbs"] = {
	"Namibian Sign Language",
	6961792,
	"sgn",
	"Latn", -- when documented
}

m["nbt"] = {
	"Na",
	12952895,
	"sit-tan",
	"Deva, Latn",
}

m["nbu"] = {
	"Rongmei Naga",
	12952912,
	"sit-zem",
	"Latn",
}

m["nbv"] = {
	"Ngamambo",
	11129694,
	"nic-mom",
	"Latn",
}

m["nbw"] = {
	"Southern Ngbandi",
	17522635,
	"nic-ngd",
	"Latn",
}

m["nby"] = {
	"Ningera",
	11732524,
	"paa-brd",
	"Latn",
}

m["nca"] = {
	"Iyo",
	6101336,
	"ngf-fin",
	"Latn",
}

m["ncb"] = {
	"tiếng Nicobar Trung",
	3335553,
	"aav-nic",
	"Deva, Latn",
	"Tiếng Nicobar Trung",
	"Nicobar Trung",
}

m["ncc"] = {
	"Ponam",
	3396122,
	"poz-aay",
	"Latn",
}

m["ncd"] = {
	"Nachering",
	6957144,
	"sit-kic",
	"Deva",
}

m["nce"] = {
	"Yale",
	2992915,
	"paa", --kwomtari or isolate
	"Latn",
}

m["ncf"] = {
	"Notsi",
	3344784,
	"poz-ocw",
	"Latn",
}

m["ncg"] = {
	"tiếng Nisga'a",
	3342138,
	"nai-tsi",
	"Latn",
	"Tiếng Nisga'a",
	"Nisga'a",
}

m["nch"] = {
	"tiếng Trung Nahuatl Huasteca",
	2194290,
	"azc-hua",
	"Latn",
	"Tiếng Trung Nahuatl Huasteca",
	"Trung Nahuatl Huasteca",
}

m["nci"] = {
	"tiếng Nahuatl cổ điển",
	559242,
	"azc-nah",
	"Latn",
	"Tiếng Nahuatl cổ điển",
	"Nahuatl cổ điển",
	entry_name = {remove_diacritics = c.macron},
}

m["ncj"] = {
	"Northern Puebla Nahuatl",
	15705671,
	"azc-nah",
	"Latn",
}

m["nck"] = {
	"Nakara",
	6960662,
	"aus-arn",
	"Latn",
}

m["ncl"] = {
	"Michoacán Nahuatl",
	2896217,
	"azc-nah",
	"Latn",
}

m["ncm"] = {
	"Nambo",
	42173731,
	nil,
	"Latn",
}

m["ncn"] = {
	"Nauna",
	3337158,
	"poz-aay",
	"Latn",
}

m["nco"] = {
	"Sibe",
	56806,
	"paa-sbo",
	"Latn",
}

m["ncq"] = {
	"tiếng Katang Bắc",
	12638175,
	"mkh-kat",
	"Laoo, Thai",
	"Tiếng Katang Bắc",
	"Katang Bắc",
	sort_key = {
		Laoo = "Laoo-sortkey",
		Thai = "Thai-sortkey",
	},
}

m["ncr"] = {
	"Ncane",
	11297920,
	"nic-bbe",
	"Latn",
	ancestors = "nhu",
}

m["ncs"] = {
	"Nicaraguan Sign Language",
	33765,
	"sgn",
	"Sgnw",
}

m["nct"] = {
	"tiếng Naga Chothe",
	5105385,
	"tbq-kuk",
	"Beng, Latn",
	"Tiếng Naga Chothe",
	"Naga Chothe",
}

m["ncu"] = {
	"Chumburung",
	35198,
	"alv-gng",
	"Latn",
}

m["ncx"] = {
	"tiếng Trung Nahuatl Puebla",
	5061727,
	"azc-nah",
	"Latn",
	"Tiếng Trung Nahuatl Puebla",
	"Trung Nahuatl Puebla",
}

m["ncz"] = {
	"Natchez",
	3111838,
	nil,
	"Latn",
}

m["nda"] = {
	"Ndasa",
	35904,
	"bnt-kel",
	"Latn",
}

m["ndb"] = {
	"Kenswei Nsei",
	7067553,
	"nic-rnn",
	"Latn",
}

m["ndc"] = {
	"tiếng Ndau",
	13311,
	"bnt-sho",
	"Latn",
	"Tiếng Ndau",
	"Ndau",
}

m["ndd"] = {
	"Nde-Nsele-Nta",
	36131,
	"nic-eko",
	"Latn",
}

m["ndf"] = {
	"Nadruvian",
	6957967,
	nil,
	"Latn",
}

m["ndg"] = {
	"Ndengereko",
	6983726,
	"bnt-mbi",
	"Latn",
}

m["ndh"] = {
	"Ndali",
	6983678,
	"bnt-run",
	"Latn",
}

m["ndi"] = {
	"Chamba Leko",
	36381,
	"alv-lek",
	"Latn",
}

m["ndj"] = {
	"Ndamba",
	6983684,
	"bnt-kil",
	"Latn",
}

m["ndk"] = {
	"Ndaka",
	11164947,
	"bnt-nya",
	"Latn",
}

m["ndl"] = {
	"Ndolo",
	6983788,
	"bnt-zbi",
	"Latn",
	ancestors = "lse",
}

m["ndm"] = {
	"Ndam",
	56283,
	"cdc-est",
	"Latn",
}

m["ndn"] = {
	"Ngundi",
	35916,
	"bnt-ngn",
	"Latn",
}

m["ndp"] = {
	"Ndo",
	6983774,
	"csu-mle",
	"Latn",
}

m["ndq"] = {
	"Ndombe",
	6983792,
	"bnt-swb",
	"Latn",
}

m["ndr"] = {
	"Ndoola",
	35837,
	"nic-mmb",
	"Latn",
}

m["nds"] = {
	"tiếng Hạ Đức",
	25433,
	"gmw-lgm",
	"Latn",
	"Tiếng Hạ Đức",
	"Hạ Đức",
	ancestors = "gml",
}

m["ndt"] = {
	"Ndunga",
	6983857,
	"nic-mbc",
	"Latn",
}

m["ndu"] = {
	"Dugun",
	11015189,
	"alv-dur",
	"Latn",
}

m["ndv"] = {
	"Ndut",
	36028,
	"alv-cng",
	"Latn",
}

m["ndw"] = {
	"Ndobo",
	11008568,
	"bnt-ngn",
	"Latn",
}

m["ndx"] = {
	"Nduga",
	6983833,
	nil,
	"Latn",
}

m["ndy"] = {
	"Lutos",
	6705910,
	"csu-val",
	"Latn",
}

m["ndz"] = {
	"tiếng Ndogo",
	35983,
	"nic-ser",
	"Latn",
	"Tiếng Ndogo",
	"Ndogo",
}

m["nea"] = {
	"Eastern Ngad'a",
	12473454,
	"poz-cet",
}

m["neb"] = {
	"Toura",
	7853636,
	"dmn-mda",
	"Latn",
}

m["nec"] = {
	"Nedebang",
	4925378,
	"ngf",
}

m["ned"] = {
	"Nde-Gbite",
	11010279,
	"nic-grf",
}

m["nee"] = {
	"Kumak",
	3347266,
	"poz-cln",
	"Latn",
}

m["nef"] = {
	"Nefamese",
	6987002,
	"crp",
}

m["neg"] = {
	"tiếng Negidal",
	33676,
	"tuw-ewe",
	"Cyrl",
	"Tiếng Negidal",
	"Negidal",
}

m["neh"] = {
	"tiếng Nyen",
	3695185,
	"sit-ebo",
	"Tibt, Latn",
	"Tiếng Nyen",
	"Nyen",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["nej"] = {
	"Neko",
	6989840,
	"ngf-fin",
	"Latn",
}

m["nek"] = {
	"Neku",
	14916900,
	"poz-cln",
}

m["nem"] = {
	"Nemi",
	3338008,
	"poz-cln",
	"Latn",
}

m["nen"] = {
	"Nengone",
	3338052,
	"poz-occ",
	"Latn",
}

m["neo"] = {
	"tiếng Na Miểu",
	15977293,
	"hmn",
	nil,
	"Tiếng Na Miểu",
	"Na Miểu",
}

m["neq"] = {
	"North Central Mixe",
	25559729,
	nil,
	"Latn",
}

m["ner"] = {
	"Yahadian",
	8046778,
	nil,
	"Latn",
}

m["nes"] = {
	"Bhoti Kinnauri",
	21179921,
	"sit-las",
}

m["net"] = {
	"Nete",
	6998869,
	"paa-eng",
}

m["neu"] = {
	"Neo",
	606917,
	"art",
	"Latn",
	type = "appendix-constructed",
}

m["nev"] = {
	"Nyaheun",
	7070801,
	"mkh-ban",
}

m["new"] = {
	"tiếng Newa",
	33979,
	"sit-new",
	"Deva, Newa, Ranj",
	"Tiếng Newa",
	"Newa",
	ancestors = "nwx",
	translit = {
		Deva = "new-translit",
		Newa = "new-Newa-translit",
	},
}

m["nex"] = {
	"Neme",
	12952941,
}

m["ney"] = {
	"Neyo",
	36410,
	"kro",
}

m["nez"] = {
	"Nez Perce",
	3339226,
	"nai-shp",
	"Latn",
}

m["nfa"] = {
	"Dhao",
	2053828,
	"poz",
}

m["nfd"] = {
	"Ahwai",
	3913957,
	"nic-plt",
	"Latn",
}

m["nfl"] = {
	"Aiwoo",
	56742,
	"poz-oce",
	"Latn",
}

m["nfr"] = {
	"tiếng Nafaanra",
	13297,
	"alv-snf",
	"Latn",
	"Tiếng Nafaanra",
	"Nafaanra",
}

m["nfu"] = {
	"Mfumte",
	6826794,
	"nic-nka",
	"Latn",
}

m["nga"] = {
	"tiếng Ngbaka",
	36022,
	"alv-gbf",
	"Latn",
	"Tiếng Ngbaka",
	"Ngbaka",
}

m["ngb"] = {
	"Northern Ngbandi",
	17522631,
	"nic-ngd",
	"Latn",
}

m["ngc"] = {
	"tiếng Ngombe (Congo)",
	3123524,
	"bnt-bun",
	"Latn",
	"Tiếng Ngombe (Congo)",
	"Ngombe (Congo)",
}

m["ngd"] = {
	"Ngando (Central African Republic)",
	35910,
	"bnt-ngn",
}

m["nge"] = {
	"Ngemba",
	6750551,
	"nic-nge",
	"Latn",
}

m["ngg"] = { -- compare 'aiy'
	"Ngbaka Manza",
	11033316,
	"alv-gbf",
	"Latn",
}

m["ngh"] = {
	"tiếng Nǀuu",
	2618974,
	"khi-tuu",
	"Latn",
	"Tiếng Nǀuu",
	"Nǀuu",
}

m["ngi"] = {
	"Ngizim",
	3914924,
	"cdc-wst",
	"Latn",
}

m["ngj"] = {
	"Ngie",
	36361,
	"nic-mom",
	"Latn",
}

m["ngk"] = {
	"Ngalkbun",
	3913790,
	"aus-gun",
	"Latn",
}

m["ngl"] = {
	"Lomwe",
	35824,
	"bnt-mak",
	"Latn",
}

m["ngm"] = {
	"Ngatik Men's Creole",
	36400,
	"crp",
	ancestors = "en, pon",
}

m["ngn"] = {
	"Ngwo",
	36051,
	"nic-mom",
	"Latn",
}

m["ngo"] = {
	"Ngoni",
	7022547,
	"bnt-ngu",
	"Latn",
}

m["ngp"] = {
	"Ngulu",
	7193332,
	"bnt-seu",
	"Latn",
}

m["ngq"] = {
	"Ngoreme",
	7022573,
	"bnt-lok",
	"Latn",
}

m["ngr"] = {
	"Nagu",
	3063524,
	"poz-oce",
	"Latn",
}

m["ngs"] = {
	"Gvoko",
	3441188,
	"cdc-cbm",
	"Latn",
}

m["ngt"] = {
	"tiếng Ngeq",
	25559548,
	"mkh-kat",
	"Laoo",
	"Tiếng Ngeq",
	"Ngeq",
	translit = "lo-translit",
}

m["ngu"] = {
	"Guerrero Nahuatl",
	5614980,
	"azc-nah",
	"Latn",
}

m["ngv"] = {
	"Nagumi",
	35842,
	"nic-jrn",
}

m["ngw"] = {
	"Ngwaba",
	3440480,
	"cdc-cbm",
	"Latn",
}

m["ngx"] = {
	"Nggwahyi",
	56265,
	"cdc-cbm",
	"Latn",
}

m["ngy"] = {
	"Tibea",
	36598,
	"bnt-baf",
	"Latn",
}

m["ngz"] = {
	"Ngungwel",
	35920,
	"bnt-tkc",
	"Latn",
}

m["nha"] = {
	"Nhanda",
	3339380,
	"aus-psw",
	"Latn",
}

m["nhb"] = {
	"Beng",
	3913311,
	"dmn-nbe",
	"Latn",
}

m["nhc"] = {
	"Tabasco Nahuatl",
	6047326,
	"azc-nah",
	"Latn",
}

m["nhd"] = {
	"Chiripá",
	2873230,
	"tup-gua",
	ancestors = "gn",
}

m["nhe"] = {
	"Eastern Huasteca Nahuatl",
	4358289,
	"azc-nah",
	"Latn",
}

m["nhf"] = {
	"Nhuwala",
	10600396,
	"aus-nga",
	"Latn",
}

m["nhg"] = {
	"Tetelcingo Nahuatl",
	3450252,
	"azc-nah",
	"Latn",
}

m["nhh"] = {
	"Nahari",
	6583560,
	"inc-eas",
}

m["nhi"] = {
	"Zacatlán-Ahuacatlán-Tepetzintla Nahuatl",
	12953764,
	"azc-nah",
	"Latn",
}

m["nhk"] = {
	"Cosoleacaque Nahuatl",
	12953757,
	"azc-nah",
	"Latn",
}

m["nhm"] = {
	"Morelos Nahuatl",
	4800819,
	"azc-nah",
	"Latn",
}

m["nhn"] = {
	"tiếng Trung Nahuatl",
	6047309,
	"azc-nah",
	"Latn",
	"Tiếng Trung Nahuatl",
	"Trung Nahuatl",
}

m["nho"] = {
	"Takuu",
	3409818,
	"poz-pnp",
	"Latn",
}

m["nhp"] = {
	"Pajapan Nahuatl",
	12953760,
	"azc-nah",
	"Latn",
}

m["nhq"] = {
	"Huaxcaleca Nahuatl",
	12953758,
	"azc-nah",
	"Latn",
}

m["nhr"] = {
	"Naro",
	2164778,
	"khi-kal",
	"Latn",
}

m["nht"] = {
	"tiếng Nahuatl Ometepec",
	7090132,
	"azc-nah",
	"Latn",
}

m["nhu"] = {
	"tiếng Noone",
	36072,
	"nic-bbe",
	"Latn",
}

m["nhv"] = {
	"tiếng Nahuatl Temascaltepec",
	2379405,
	"azc-nah",
	"Latn",
	"Tiếng Nahuatl Temascaltepec",
	"Nahuatl Temascaltepec",
}

m["nhw"] = {
	"tiếng Tây Huasteca Nahuatl",
	2678840,
	"azc-nah",
	"Latn",
	"Tiếng Tây Nahuatl Huasteca",
	"Tây Nahuatl Huasteca",
}

m["nhx"] = {
	"Mecayapan Nahuatl",
	12953756,
	"azc-nah",
	"Latn",
}

m["nhy"] = {
	"Northern Oaxaca Nahuatl",
	12953763,
	"azc-nah",
	"Latn",
}

m["nhz"] = {
	"Santa María La Alta Nahuatl",
	15705753,
	"azc-nah",
	"Latn",
}

m["nia"] = {
	"tiếng Nias",
	2407831,
	"poz-nws",
	"Latn",
	"Tiếng Nias",
	"Nias",
}

m["nib"] = {
	"Nakame",
	11732495,
	"ngf-fin",
	"Latn",
}

m["nid"] = {
	"Ngandi",
	7021977,
	"aus-arn",
	"Latn",
}

m["nie"] = {
	"Niellim",
	33662,
	"alv-bua",
}

m["nif"] = {
	"Nek",
	6989781,
	"ngf-fin",
	"Latn",
}

m["nig"] = {
	"Ngalakan",
	3913796,
	"aus-gun",
	"Latn",
}

m["nih"] = {
	"Nyiha",
	11128374,
	"bnt-mby",
	"Latn",
}

m["nii"] = {
	"Nii",
	35237,
	"ngf",
	"Latn",
}

m["nij"] = {
	"Ngaju",
	2992872,
	"poz-brw",
	"Latn",
}

m["nik"] = {
	"tiếng Nicobar Nam",
	7570194,
	"aav-nic",
	"Deva, Latn",
	"Tiếng Nicobar Nam",
	"Nicobar Nam",
}

m["nil"] = {
	"Nila",
	7036821,
}

m["nim"] = {
	"Nilamba",
	4121200,
	"bnt-tkm",
	"Latn",
}

m["nin"] = {
	"Ninzo",
	3914021,
	"nic-nin",
}

m["nio"] = {
	"tiếng Nganasan",
	36743,
	"syd",
	"Cyrl",
	"Tiếng Nganasan",
	"Nganasan",
	translit = "nio-translit",
}

m["niq"] = {
	"Nandi",
	6956591,
	"sdv-nma",
}

m["nir"] = {
	"Nimboran",
	301116,
	"paa-nim",
}

m["nis"] = {
	"Nimi",
	11732523,
	"ngf-fin",
	"Latn",
}

m["nit"] = {
	"tiếng Nam Kolami",
	56767,
	"dra-knk",
	"Deva, Telu",
	"Tiếng Nam Kolami",
	"Nam Kolami",
	translit = {
		Telu = "te-translit"
	},
}

m["niu"] = {
	"tiếng Niue",
	33790,
	"poz-pol",
	"Latn",
	"Tiếng Niue",
	"Niue",
}

m["niv"] = {
	"tiếng Nivkh",
	36464,
	"qfa-iso",
	"Cyrl",
	"Tiếng Nivkh",
	"Nivkh",
	translit = "niv-translit",
	entry_name = {
		from = {"['’]"},
		to   = {"ʼ"}
	},
	sort_key = "niv-sortkey",
}

m["niw"] = {
	"Nimo",
	3504126,
	"paa-asa",
}

m["nix"] = {
	"Hema",
	5710904,
	"bnt-nyg",
	"Latn",
}

m["niy"] = {
	"tiếng Ngiti",
	7022396,
	"csu-lnd",
	"Latn",
	"Tiếng Ngiti",
	"Ngiti",
}

m["niz"] = {
	"Ningil",
	11732527,
	"qfa-tor",
}

m["nja"] = {
	"Nzanyi",
	3441299,
	"cdc-cbm",
	"Latn",
}

m["njb"] = {
	"Nocte Naga",
	7046410,
	"sit-tno",
}

m["njh"] = {
	"tiếng Lotha Naga",
	33590,
	"sit-aao",
}

m["nji"] = {
	"Gudanji",
	3915692,
	"aus-mir",
}

m["njj"] = {
	"Njen",
	36112,
	"nic-mom",
	"Latn",
}

m["njl"] = {
	"Njalgulgule",
	7071229,
	"sdv-daj",
}

m["njm"] = {
	"tiếng Angami",
	56761,
	"tbq-anp",
	"Latn",
	"Tiếng Angami",
	"Angami",
}

m["njn"] = {
	"Liangmai Naga",
	14194500,
	"sit-zem",
}

m["njo"] = {
	"tiếng Ao",
	28433,
	"sit-aao",
	"Latn",
	"Tiếng Ao",
	"Ao",
}

m["njr"] = {
	"Njerep",
	35844,
	"nic-mmb",
	"Latn",
}

m["njs"] = {
	"Nisa",
	13593518,
	"paa-egb",
}

m["njt"] = {
	"Ndyuka-Trio Pidgin",
	13591205,
	"crp",
	ancestors = "djk, tri",
}

m["nju"] = {
	"Ngadjunmaya",
	7021846,
	"aus-pam",
}

m["njx"] = {
	"Kunyi",
	3196559,
	"bnt-kng",
	"Latn",
}

m["njy"] = {
	"Njyem",
	35898,
	"bnt-ndb",
	"Latn",
}

m["njz"] = {
	"tiếng Nyishi",
	56870,
	"sit-tan",
	"Latn, Beng",
	"Tiếng Nyishi",
	"Nyishi",
}

m["nka"] = {
	"Nkoya",
	7042633,
	"bnt-lbn",
	"Latn",
}

m["nkb"] = {
	"Khoibu Naga",
	21481876,
	"sit-mar",
}

m["nkc"] = {
	"Nkongho",
	35863,
	"bnt-saw",
	"Latn",
}

m["nkd"] = {
	"Koireng",
	6426342,
	"sit-zem",
}

m["nke"] = {
	"Duke",
	3041075,
	"poz-ocw",
}

m["nkf"] = {
	"Inpui Naga",
	21481817,
	"sit-zem",
}

m["nkg"] = {
	"Nekgini",
	11732509,
	"ngf-fin",
	"Latn",
}

m["nkh"] = {
	"Khezha Naga",
	6401519,
	"tbq-anp",
}

m["nki"] = {
	"tiếng Naga Thangal",
	56374,
	"sit-zem",
	"Latn, Beng",
	"Tiếng Naga Thangal",
	"Naga Thangal",
}

m["nkj"] = {
	"Nakai",
	14916897,
	"ngf-okk",
	"Latn",
}

m["nkk"] = {
	"Nokuku",
	7048122,
	"poz-vnc",
}

m["nkm"] = {
	"Namat",
	15634505,
}

m["nkn"] = {
	"Nkangala",
	10962292,
	"bnt-clu",
	"Latn",
	ancestors = "mck",
}

m["nko"] = {
	"tiếng Nkonya",
	35867,
	"alv-gng",
	"Latn",
	"Tiếng Nkonya",
	"Nkonya",
}

m["nkp"] = {
	"Niuatoputapu",
	3399095,
	"poz-pnp",
}

m["nkq"] = {
	"Nkami",
	7042522,
	"alv-gng",
	"Latn",
}

m["nkr"] = {
	"Nukuoro",
	2635961,
	"poz-pnp",
	"Latn",
}

m["nks"] = {
	"North Asmat",
	11732049,
}

m["nkt"] = {
	"Nyika",
	16917497,
	"bnt-mwi",
	"Latn",
}

m["nku"] = {
	"tiếng Kulango Bouna",
	20668241,
	"alv-kul",
	"Latn",
	"Tiếng Kulango Bouna",
	"Kulango Bouna",
}

-- nkv is treated as nkt, see WT:LT

m["nkw"] = {
	"Nkutu",
	7193313,
	"bnt-tet",
	"Latn",
}

m["nkx"] = {
	"Nkoroo",
	36000,
	"ijo",
}

m["nkz"] = {
	"tiếng Nkari",
	11130307,
	"nic-ief",
	ancestors = "ibr",
	"Latn",
	"Tiếng Nkari",
	"Nkari",
}

m["nla"] = {
	"Ngombale",
	36292,
	"bai",
	"Latn",
}

m["nlc"] = {
	"Nalca",
	6960839,
	"ngf",
	"Latn",
}

m["nle"] = {
	"East Nyala",
	25559347,
	"bnt-msl",
	"Latn",
	ancestors = "luy",
}

m["nlg"] = {
	"Gela",
	3063531,
	"poz-sls",
	"Latn",
}

m["nli"] = {
	"Grangali",
	3444203,
	"inc-kun",
}

m["nlj"] = {
	"Nyali",
	7070830,
	"bnt-nya",
	"Latn",
}

m["nlk"] = {
	"Ninia Yali",
	12953310,
}

m["nll"] = {
	"Nihali",
	33904,
	"qfa-iso",
	"Deva, Latn",
}

m["nlm"] = {
	"Mankiyali",
	47522426,
	"inc-koh",
}

m["nlo"] = {
	"Ngul",
	35894,
	"bnt-bdz",
	"Latn",
}

m["nlq"] = {
	"Lao Naga",
	63283609,
	"sit-tno",
}

m["nlu"] = {
	"Nchumbulu",
	36143,
	"alv-gng",
	"Latn",
}

m["nlv"] = {
	"Orizaba Nahuatl",
	3086050,
	"azc-nah",
	"Latn",
}

m["nlw"] = {
	"Walangama",
	7961277,
}

m["nlx"] = {
	"Nahali",
	33361,
	"inc-bhi",
}

m["nly"] = {
	"Nyamal",
	7070837,
	"aus-nga",
	"Latn",
}

m["nlz"] = {
	"Nalögo",
	20527138,
	"poz-oce",
}

m["nma"] = {
	"Maram Naga",
	56378,
	"sit-zem",
}

m["nmb"] = {
	"Big Nambas",
	2902304,
	"poz-vnc",
}

m["nmc"] = {
	"tiếng Ngam",
	3915446,
	"csu-sar",
	"Latn",
	"Tiếng Ngam",
	"Ngam",
}

m["nmd"] = {
	"Ndumu",
	35901,
	"bnt-mbt",
	"Latn",
}

m["nme"] = {
	"Mzieme Naga",
	6949473,
	"sit-zem",
}

m["nmf"] = {
	"tiếng Tangkhul Naga",
	7682992,
	"sit-tng",
	nil,
	"Tiếng Tangkhul Naga",
	"Tangkhul Naga",
}

m["nmg"] = {
	"Kwasio",
	34098,
	"bnt-mnj",
	"Latn",
}

m["nmh"] = {
	"Monsang Naga",
	6902496,
}

m["nmi"] = {
	"Nyam",
	3438738,
	"cdc-wst",
	"Latn",
}

m["nmj"] = {
	"Ngombe (Central African Republic)",
	3913949,
	"alv-gbs",
}

m["nmk"] = {
	"Namakura",
	3335410,
	"poz-vnc",
}

m["nml"] = {
	"Ndemli",
	36089,
	"nic-grf",
	"Latn",
}

m["nmm"] = {
	"tiếng Manangba",
	6746900,
	"sit-tam",
	"Tibt, Deva",
	"Tiếng Manangba",
	"Manangba",
	translit = {Tibt = "Tibt-translit"},
	override_translit = true,
	display_text = {Tibt = s["Tibt-displaytext"]},
	entry_name = {Tibt = s["Tibt-entryname"]},
	sort_key = {Tibt = "Tibt-sortkey"},
}

m["nmn"] = {
	"tiếng ǃXóõ",
	13229,
	"khi-tuu",
	"Latn",
	"Tiếng ǃXóõ",
	"ǃXóõ",
}

m["nmo"] = {
	"tiếng Naga Moyon",
	6927748,
	"tbq-kuk",
	"Latn, Beng",
	"Tiếng Naga Moyon",
	"Naga Moyon",
}

m["nmp"] = {
	"Nimanbur",
	nil,
}

m["nmq"] = {
	"Nambya",
	11008869,
	"bnt-sho",
	"Latn",
}

m["nmr"] = {
	"Nimbari",
	36069,
	"alv-lni",
}

m["nms"] = {
	"Letemboi",
	3236886,
	"poz-vnc",
}

m["nmt"] = {
	"Namonuito",
	12908815,
	"poz-mic",
}

m["nmu"] = {
	"Northeast Maidu",
	3278074,
	"nai-mdu",
	"Latn",
}

m["nmv"] = {
	"Ngamini",
	7021944,
	"aus-kar",
	"Latn",
}

m["nmw"] = {
	"Nimoa",
	7037729,
	"poz-ocw",
}

m["nmy"] = {
	"Namuyi",
	56844,
	"sit-nax",
	"Latn",
}

m["nmz"] = {
	"Nawdm",
	36085,
	"nic-yon",
	"Latn",
}

m["nna"] = {
	"Nyangumarta",
	33653,
}

m["nnb"] = {
	"Nande",
	3196953,
	"bnt-glb",
	"Latn",
}

m["nnc"] = {
	"Nancere",
	3140491,
	"cdc-est",
	"Latn",
}

m["nnd"] = {
	"West Ambae",
	2841479,
	"poz-vnc",
	"Latn",
}

m["nne"] = {
	"Ngandyera",
	10961003,
	"bnt-ova",
	"Latn",
}

m["nnf"] = {
	"Ngaing",
	11732510,
	"ngf-fin",
	"Latn",
}

m["nng"] = {
	"tiếng Naga Maring",
	12952908,
	"sit-mar",
	"Latn, Beng",
	"Tiếng Naga Maring",
	"Naga Maring",
}

m["nnh"] = {
	"tiếng Ngiemboon",
	36286,
	"bai",
	"Latn",
	"Tiếng Ngiemboon",
	"Ngiemboon",
}

m["nni"] = {
	"North Nuaulu",
	12952968,
	"poz-cma",
}

m["nnj"] = {
	"Nyangatom",
	4662604,
	"sdv-ttu",
}

m["nnk"] = {
	"tiếng Nankina",
	11732502,
	"ngf-fin",
	"Latn",
	"Tiếng Nankina",
	"Nankina",
}

m["nnl"] = {
	"Northern Rengma Naga",
	7067615,
	"tbq-anp",
}

m["nnm"] = {
	"Namia",
	56363,
	"paa-spk",
	"Latn",
}

m["nnn"] = {
	"Ngete",
	56625,
	"cdc-mas",
	"Latn",
}

m["nnp"] = {
	"tiếng Wancho",
	7967085,
	"sit-kch",
	"Wcho, Deva, Latn",
	"Tiếng Wancho",
	"Wancho",
}

m["nnq"] = {
	"Ngindo",
	7022366,
	"bnt-mbi",
	"Latn",
}

m["nnr"] = {
	"Narungga",
	13591127,
	"aus-pam",
}

m["nnt"] = {
	"Nanticoke",
	3915517,
	"alg-eas",
	"Latn",
}

m["nnu"] = {
	"Dwang",
	35258,
	"alv-gng",
	"Latn",
}

m["nnv"] = {
	"Nukunu",
	10604066,
}

m["nnw"] = {
	"Southern Nuni",
	11152248,
	"nic-gnn",
	"Latn",
}

m["nnx"] = {
	"Ngong",
	12952915,
}

m["nny"] = { -- contrast aus-ynk
	"Nyangga",
	10604331,
	"aus-tnk",
	"Latn",
}

m["nnz"] = {
	"Nda'nda'",
	36016,
	"bai",
	"Latn",
}

m["noa"] = {
	"Woun Meu",
	3111873,
	"sai-chc",
	"Latn",
}

m["noc"] = {
	"Nuk",
	11732534,
	"ngf-fin",
	"Latn",
}

m["nod"] = {
	"tiếng Bắc Thái",
	565110,
	"tai-swe",
	"Lana, Thai",
	"Tiếng Bắc Thái",
	"Bắc Thái",
	entry_name = {remove_diacritics = c.ZWNJ},
	sort_key = {
		Lana = "Lana-sortkey",
		Thai = "Thai-sortkey"
	},
}

m["noe"] = {
	"Nimadi",
	3502294,
	"inc-wes",
	"Deva",
	ancestors = "raj",
	translit = "hi-translit",
}

m["nof"] = {
	"Nomane",
	11732531,
}

m["nog"] = {
	"tiếng Nogai",
	33871,
	"trk-kno",
	"Cyrl, Arab, Latn",
	"Tiếng Nogai",
	"Nogai",
	translit = "nog-translit",
	override_translit = true,
}

m["noh"] = {
	"Nomu",
	11732532,
}

m["noi"] = {
	"Noiri",
	12953774,
	"inc-bhi",
}

m["noj"] = {
	"Nonuya",
	5372139,
	"sai-wit",
	"Latn",
}

m["nok"] = {
	"Nooksack",
	3343396,
}

m["nol"] = {
	"Nomlaki",
	3343229,
	"nai-wtq",
	"Latn",
}

m["nom"] = {
	"Nocamán",
	7046289,
	"sai-pan",
	"Latn",
}

m["non"] = {
	"tiếng Bắc Âu cổ",
	35505,
	"gmq",
	"Latn, Runr",
	"Tiếng Bắc Âu cổ",
	"Bắc Âu cổ",
	translit = {Runr = "Runr-translit"},
}

m["nop"] = {
	"Numanggang",
	7069052,
	"ngf-fin",
	"Latn",
}

m["noq"] = {
	"Ngongo",
	11057478,
	"bnt-yak",
	"Latn",
}

m["nos"] = {
	"Eastern Nisu",
	25559419,
	"tbq-nis",
}

m["not"] = {
	"Nomatsiguenga",
	3342992,
	"awd",
	"Latn",
}

m["nou"] = {
	"Ewage-Notu",
	5418860,
}

m["nov"] = {
	"tiếng Novial",
	36738,
	"art",
	"Latn",
	"Tiếng Novial",
	"Novial",
	type = "appendix-constructed"
}

m["now"] = {
	"Nyambo",
	4967930,
	"bnt-haj",
	"Latn",
}

m["noy"] = {
	"Noy",
	36321,
	"alv-bua",
}

m["noz"] = {
	"Nayi",
	3183349,
	"omv-diz",
}

m["npa"] = {
	"Nar Phu",
	4926353,
	"sit-tam",
}

m["npb"] = {
	"Nupbikha",
	3695201,
	"sit-ebo",
}

m["npg"] = {
	"Ponyo",
	7228475,
	"sit-kch",
}

m["nph"] = {
	"Phom",
	7187109,
	"sit-kch",
}

m["npl"] = {
	"Southeastern Puebla Nahuatl",
	4632950,
	"azc-nah",
	"Latn",
}

m["npn"] = {
	"Mondropolon",
	3320594,
	"poz-aay",
}

m["npo"] = {
	"Pochuri Naga",
	7206342,
	"tbq-anp",
}

m["nps"] = {
	"Nipsan",
	11732528,
}

m["npu"] = {
	"Puimei Naga",
	7259044,
	"sit-zem",
}

m["npy"] = {
	"Napu",
	12953768,
}

m["nqg"] = {
	"tiếng Ede Nago",
	12952408,
	"alv-ede",
	nil,
	"Tiếng Ede Nago",
	"Ede Nago",
}

m["nqk"] = {
	"Kura Ede Nago",
	12952409,
	"alv-ede",
}

m["nql"] = {
	"Ngendelengo",
	63283693,
	"bnt-swb",
	"Latn",
}

m["nqm"] = {
	"Ndom",
	6983791,
	"ngf",
	"Latn",
}

m["nqn"] = {
	"Nen",
	20816352,
	"paa-yam",
}

m["nqo"] = {
	"N'Ko",
	18546266,
	"dmn-man",
	"Nkoo",
}

m["nqq"] = {
	"Kyan-Karyaw Naga",
	63283784,
	"sit-tno",
}

m["nqy"] = {
	"Akyaung Ari",
	4702035,
	"sit-tng",
}

m["nra"] = {
	"Ngom",
	36087,
	"bnt-kel",
	"Latn",
}

m["nrb"] = {
	"Nara",
	36179,
	"sdv-nes",
}

m["nrc"] = {
	"tiếng Noreia",
	37023,
	"cel-con",
	"Ital",
	"Tiếng Noreia",
	"Noreia",
	translit = "Ital-translit",
}

m["nre"] = {
	"Southern Rengma Naga",
	7313205,
	"tbq-anp",
}

m["nrf"] = {
	"tiếng Norman",
	33850,
	"roa-oil",
	"Latn",
	"Tiếng Norman",
	"Norman",
	wikimedia_codes = "nrm",
	ancestors = "frm",
	sort_key = s["roa-oil-sortkey"],
}

m["nrg"] = {
	"Narango",
	12952929,
	"poz-vnc",
}

m["nri"] = {
	"Chokri Naga",
	5104247,
	"tbq-anp",
}

m["nrk"] = {
	"Ngarla",
	3915860,
	"aus-nga",
	"Latn",
}

m["nrl"] = {
	"Ngarluma",
	7022078,
	"aus-nga",
	"Latn",
}

m["nrm"] = {
	"Narom",
	3336135,
	"poz-swa",
	"Latn",
}

m["nrn"] = {
	"Norn",
	36708,
	"gmq-ins",
	"Latn",
}

m["nrp"] = {
	"tiếng Piceni Bắc",
	430138,
	nil,
	"Ital",
	"Tiếng Piceni Bắc",
	"Piceni Bắc",
	translit = "Ital-translit",
}

m["nrr"] = {
	"Norra",
	12952967,
	"tai",
}

m["nrt"] = {
	"Northern Kalapuya",
	3192121,
	"nai-klp",
}

m["nru"] = {
	"tiếng Ma Thoa",
	21658869,
	"sit-nas",
	"Latn",
	"Tiếng Ma Thoa",
	"Ma Thoa",
}

m["nrx"] = {
	"Ngurmbur",
	2591251,
}

m["nrz"] = {
	"Lala (New Guinea)",
	6480151,
	"poz-ocw",
}

m["nsa"] = {
	"Sangtam Naga",
	7418144,
	"sit-aao",
}

m["nsb"] = {
	"Lower Nossob",
	6693681,
	"khi-tuu",
	"Latn",
}

m["nsc"] = {
	"Nshi",
	11129508,
	"nic-rnn",
	"Latn",
}

m["nsd"] = {
	"Southern Nisu",
	nil,
	"tbq-nis",
}

m["nse"] = {
	"Nsenga",
	3081996,
	"bnt-sna",
	"Latn",
}

m["nsg"] = {
	"Ngasa",
	56345,
	"sdv-lma",
}

m["nsh"] = {
	"Ngoshie",
	7022582,
	"nic-mom",
	"Latn",
}

m["nsi"] = {
	"Nigerian Sign Language",
	7033021,
	"sgn",
}

m["nsk"] = {
	"tiếng Naskapi",
	1704302,
	"alg",
	"Cans",
	"Tiếng Naskapi",
	"Naskapi",
	ancestors = "cr",
	translit = "nsk-translit",
}

m["nsl"] = {
	"Norwegian Sign Language",
	1781613,
	"sgn",
}

m["nsm"] = {
	"Sema",
	3478238,
	"tbq-anp",
}

m["nsn"] = {
	"Nehan",
	3337774,
	"poz-ocw",
}

m["nso"] = {
	"tiếng Sotho Bắc",
	33890,
	"bnt-sts",
	"Latn",
	"Tiếng Sotho Bắc",
	"Sotho Bắc",
}

m["nsp"] = {
	"Nepalese Sign Language",
	3915492,
	"sgn",
}

m["nsq"] = {
	"Northern Sierra Miwok",
	3344226,
	"nai-utn",
	"Latn",
}

m["nsr"] = {
	"Maritime Sign Language",
	3915483,
	"sgn",
}

m["nss"] = {
	"Nali",
	3335385,
	"poz-aay",
}

m["nst"] = {
	"Tangsa",
	56350,
	"sit-tno",
	"Latn, Tnsa",
}

m["nsu"] = {
	"Sierra Negra Nahuatl",
	nil,
	"azc-nah",
	"Latn",
}

m["nsv"] = {
	"Southwestern Nisu",
	nil,
	"tbq-nis",
}

m["nsw"] = {
	"Navut",
	3337327,
	"poz-vnc",
}

m["nsx"] = {
	"Nsongo",
	7067577,
	"bnt-tmb",
	"Latn",
}

m["nsy"] = {
	"Nasal",
	6966574,
}

m["nsz"] = {
	"Nisenan",
	33665,
	"nai-mdu",
	"Latn",
}

m["ntd"] = {
	"Northern Tidong",
	nil,
	"poz-san",
}

m["nte"] = {
	"Nathembo",
	11030947,
	"bnt-mak",
}

m["ntg"] = {
	"Ngantangarra",
	33060509,
}

m["nti"] = {
	"Natioro",
	36140,
	"alv-wan",
}

m["ntj"] = {
	"Ngaanyatjarra",
	3915409,
	"aus-pam",
	"Latn",
}

m["ntk"] = {
	"Ikoma",
	5996114,
	"bnt-lok",
	"Latn",
}

m["ntm"] = {
	"tiếng Nateni",
	3070731,
	"nic-grm",
	"Latn",
	"Tiếng Nateni",
	"Nateni",
}

m["nto"] = {
	"Ntomba",
	11130292,
	"bnt-mon",
	"Latn",
}

m["ntp"] = {
	"tiếng Tepehuan Bắc",
	15615651,
	"azc",
	"Latn",
	"Tiếng Tepehuan Bắc",
	"Tepehuan Bắc",
	sort_key = {remove_diacritics = c.acute},
}

m["ntr"] = {
	"Delo",
	35195,
	"nic-gne",
	"Latn",
}

m["nts"] = {
	"Natagaimas",
	6967931,
}

m["ntu"] = {
	"Natügu",
	nil,
	"poz-oce",
}

m["ntw"] = {
	"Nottoway",
	3344791,
	"iro-nor",
}

m["ntx"] = {
	"Somra",
	7560536,
	"sit-tng",
}

m["nty"] = {
	"Mantsi",
	56878,
	"sit-mnz",
}

m["nua"] = {
	"Yuaga",
	3573088,
	"poz-cln",
	"Latn",
}

m["nuc"] = {
	"Nukuini",
	3346231,
}

m["nud"] = {
	"Ngala",
	7021893,
	"paa-spk",
	"Latn",
}

m["nue"] = {
	"Ngundu",
	12952953,
	"bad-cnt",
	"Latn",
}

m["nuf"] = {
	"Nusu",
	56413,
	"tbq-nus",
}

m["nug"] = {
	"Nungali",
	7069826,
	"aus-mir",
}

m["nuh"] = {
	"Ndunda",
	3913968,
	"nic-mmb",
	"Latn",
}

m["nui"] = {
	"Ngumbi",
	36459,
	"bnt-yko",
}

m["nuj"] = {
	"Nyole (Uganda)",
	3739448,
	"bnt-msl",
	"Latn",
}

m["nuk"] = {
	"tiếng Nuu-chah-nulth",
	2992876,
	"wak",
	"Latn",
	"Tiếng Nuu-chah-nulth",
	"Nuu-chah-nulth",
}

m["nul"] = {
	"Nusa Laut",
	7070332,
	"poz-cma",
}

m["num"] = {
	"Niuafo'ou",
	36173,
	"poz-pol",
	"Latn",
}

m["nun"] = {
	"Anong",
	2748232,
	"sit-nng",
}

m["nuo"] = {
	"tiếng Nguồn",
	3915785,
	"mkh-vie",
	"Latn",
	"Tiếng Nguồn",
	"Nguồn",
	sort_key = "vi-sortkey",
}

m["nup"] = {
	"tiếng Nupe",
	36720,
	"alv-ngb",
	"Latn",
	"Tiếng Nupe",
	"Nupe",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.macron .. c.caron},
	sort_key = "nup-sortkey",
}

m["nuq"] = {
	"Nukumanu",
	12909019,
	"poz-pnp",
}

m["nur"] = {
	"Nuguria",
	7068910,
	"poz-pnp",
}

m["nus"] = {
	"tiếng Nuer",
	33675,
	"sdv-dnu",
	"Latn",
	"Tiếng Nuer",
	"Nuer",
}

m["nut"] = {
	"tiếng Nùng",
	72695,
	"tai",
	"Latn, Hani",
	"Tiếng Nùng",
	"Nùng",
	sort_key = {Hani = "Hani-sortkey"},
}

m["nuu"] = {
	"Ngbundu",
	11126081,
	"bad",
	"Latn",
}

m["nuv"] = {
	"Northern Nuni",
	11016572,
	"nic-gnn",
	"Latn",
}

m["nuw"] = {
	"Nguluwan",
	6528643,
}

m["nux"] = {
	"Mehek",
	6809452,
	"paa-spk",
	"Latn",
}

m["nuy"] = {
	"Nunggubuyu",
	1747811,
	"aus-arn",
}

m["nuz"] = {
	"Tlamacazapa Nahuatl",
	2073277,
	"azc-nah",
	"Latn",
}

m["nvh"] = {
	"Nasarian",
	6966614,
	"poz-vnc",
}

m["nvm"] = {
	"Namiae",
	12952922,
}

m["nvo"] = {
	"Nyokon",
	nil,
	"nic-mbw",
	"Latn",
}

m["nwa"] = {
	"Nawathinehena",
	6982892,
	"alg-ara",
	"Latn",
}

m["nwb"] = {
	"Nyabwa",
	33664,
	"kro-wee",
}

m["nwc"] = {
	"Classical Newar",
	5128301,
	"sit-new",
}

m["nwe"] = {
	"Ngwe",
	36181,
	"bai",
	"Latn",
}

m["nwi"] = {
	"Southwest Tanna",
	3504488,
}

m["nwm"] = {
	"Nyamusa-Molo",
	12747951,
	"csu-bbk",
}

m["nwo"] = {
	"Nauo",
	6981305,
	"aus-pam",
	"Latn",
}

m["nwr"] = {
	"Nawaru",
	12638166,
	"ngf",
}

m["nwx"] = {
	"Middle Newar",
	nil,
	"sit-new",
	"Deva, Newa, Ranj",
	ancestors = "nwc",
}

m["nwy"] = {
	"Nottoway-Meherrin",
	nil,
	"iro-nor",
}

m["nxa"] = {
	"Nauete",
	6981095,
	"poz-tim",
}

m["nxd"] = {
	"Ngando (Congo)",
	3913277,
	"bnt-ske",
}

m["nxe"] = {
	"Nage",
	2295569,
	"poz-cet",
}

m["nxg"] = {
	"tiếng Ngadha",
	1516651,
	"poz-cet",
	"Latn",
	"Tiếng Ngadha",
	"Ngadha",
}

m["nxi"] = {
	"Nindi",
	7038230,
	"bnt-mbi",
	"Latn",
}

m["nxl"] = {
	"South Nuaulu",
	18544857,
	"poz-cma",
}

m["nxm"] = {
	"tiếng Numidia",
	35761,
	"afa",
	"Tfng, Latn", --Tfng may not support all the needed characters
	"Tiếng Numidia",
	"Numidia",
	translit = {Tfng = "Tfng-translit"},
}

m["nxn"] = {
	"Ngawun",
	3915711,
	"aus-pam",
	"Latn",
}

m["nxo"] = {
	"Ndambomo",
	6983681,
	"bnt-kel",
	"Latn",
}

m["nxq"] = {
	"tiếng Nạp Tây",
	2478711,
	"sit-nas",
	"Nkdb, Nkgb, Latn, Lisu",
	"Tiếng Nạp Tây",
	"Nạp Tây",
	translit = {Lisu = "Lisu-translit"},
	sort_key = {Lisu = s["Lisu-sortkey"]},
}

m["nxr"] = {
	"Ninggerum",
	11732526,
	"ngf-okk",
	"Latn",
}

m["nxu"] = {
	"Narau",
	6965452,
	"ngf",
	"Latn",
}

m["nxx"] = {
	"Nafri",
	6958211,
	"paa-sen",
	"Latn",
}

m["nyb"] = {
	"Nyangbo",
	36256,
	"alv-ktg",
	"Latn",
}

m["nyc"] = {
	"Nyanga-li",
	7070876,
	"bnt-boa",
	"Latn",
}

m["nyd"] = {
	"Nyole (Kenya)",
	7071227,
	"bnt-msl",
	"Latn",
}

m["nye"] = {
	"Nyengo",
	7071068,
	"bnt-clu",
	"Latn",
}

m["nyf"] = {
	"tiếng Giryama",
	3107606,
	"bnt-mij",
	"Latn",
	"Tiếng Giryama",
	"Giryama",
}

m["nyg"] = {
	"Nyindu",
	11030685,
	"bnt-shh",
	"Latn",
}

m["nyh"] = {
	"Nyigina",
	3913780,
	"aus-nyu",
	"Latn",
}

m["nyi"] = {
	"Nyimang",
	34846,
	"sdv-nyi",
	"Latn",
}

m["nyj"] = {
	"Nyanga (Congo)",
	7070879,
	"bnt-nyb",
	"Latn",
}

m["nyk"] = {
	"Nyaneka",
	10962298,
	"bnt-swb",
	"Latn",
}

m["nyl"] = {
	"tiếng Nyeu",
	3033578,
	"mkh-kat",
	"Thai, Khmr, Laoo",
	"Tiếng Nyeu",
	"Nyeu",
}

m["nym"] = {
	"Nyamwezi",
	4121131,
	"bnt-tkm",
	"Latn",
}

m["nyn"] = {
	"Nyankole",
	13207,
	"bnt-nyg",
	"Latn",
}

m["nyo"] = {
	"tiếng Nyoro",
	33794,
	"bnt-nyg",
	"Latn",
	"Tiếng Nyoro",
	"Nyoro",
}

m["nyp"] = {
	"Nyang'i",
	7070894,
	"ssa-klk",
}

m["nys"] = {
	"tiếng Nyunga",
	7049771,
	"aus-pam",
	"Latn",
	"Tiếng Nyunga",
	"Nyunga",
}

m["nyt"] = {
	"Nyawaygi",
	3915783,
	"aus-dyb",
}

m["nyu"] = {
	"Nyungwe",
	7071318,
	"bnt-sna",
	"Latn",
}

m["nyv"] = {
	"Nyulnyul",
	3442732,
	"aus-nyu",
	"Latn",
}

m["nyw"] = {
	"tiếng Nyaw",
	26425602,
	"tai",
	"Thai, Latn, Tayo", -- Vietnamese alphabet
	"Tiếng Nyaw",
	"Nyaw",
	sort_key = "Thai-sortkey", -- no effect on Latn
}

m["nyx"] = {
	"Nganyaywana",
	3913800,
	"aus-cww",
	"Latn",
}

m["nyy"] = {
	"Nyakyusa",
	3272620,
	"bnt-run",
	"Latn",
}

m["nza"] = {
	"tiếng Mbembe Tigon",
	36518,
	"nic-jkn",
	"Latn",
	"Tiếng Mbembe Tigon",
	"Mbembe Tigon",
}

m["nzb"] = {
	"Njebi",
	35923,
	"bnt-nze",
	"Latn",
}

m["nzd"] = {
	"tiếng Nzadi",
	17152586,
	"bnt-bdz",
	"Latn",
	"Tiếng Nzadi",
	"Nzadi",
	entry_name = {remove_diacritics = c.grave .. c.acute .. c.circ .. c.caron},
}

m["nzi"] = {
	"Nzima",
	36337,
	"alv-ctn",
}

m["nzk"] = {
	"Nzakara",
	3913339,
	"znd",
	"Latn",
}

m["nzm"] = {
	"Zeme Naga",
	21491053,
	"sit-zem",
}

m["nzs"] = {
	"New Zealand Sign Language",
	36239,
	"sgn",
}

m["nzu"] = {
	"Central Teke",
	36473,
	"bnt-tkc",
}

m["nzy"] = {
	"Nzakambay",
	36374,
	"alv-mbm",
	"Latn",
}

m["nzz"] = {
	"Nanga Dama Dogon",
	6963443,
	"nic-nwa",
}

return require("Module:languages").finalizeData(m, "language")