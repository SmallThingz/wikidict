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

m["raa"] = {
	"Dungmali",
	56871,
	"sit-kic",
}

m["rab"] = {
	"tiếng Camling",
	3436664,
	"sit-kic",
	"Deva",
	"Tiếng Camling",
	"Camling",
}

m["rac"] = {
	"tiếng Rasawa",
	56443,
	"paa-lkp",
	"Latn",
	"Tiếng Rasawa",
	"Rasawa"
}

m["rad"] = {
	"tiếng Ê Đê",
	3429088,
	"cmc",
	"Latn",
	"Tiếng Ê Đê",
	"Ê Đê",
}

m["raf"] = {
	"Western Meohang",
	17442461,
	"sit-kie",
}

m["rag"] = {
	"Logooli",
	6667767,
	"bnt-lok",
	"Latn",
}

m["rah"] = {
	"tiếng Rabha",
	7278686,
	"tbq-bdg",
	"Beng, Latn",
	"Tiếng Rabha",
	"Rabha",
	translit = {
		Beng = "bn-translit",
	}
}

m["rai"] = {
	"Ramoaaina",
	3418509,
	"poz-ocw",
	"Latn",
}

m["raj"] = {
	"tiếng Rajasthan",
	13196,
	"inc-wes",
	"Deva",
	"Tiếng Rajasthan",
	"Rajasthan",
	ancestors = "inc-ogu",
}

m["rak"] = {
	"Tulu-Bohuai",
	2908807,
	"poz-aay",
	"Latn",
}

m["ral"] = {
	"Ralte",
	7288392,
	"tbq-kuk",
	"Latn",
}

m["ram"] = {
	"tiếng Canela",
	2936334,
	"sai-nje",
	"Latn",
	"Tiếng Canela",
	"Canela",
}

m["ran"] = {
	"Riantana",
	7322169,
	"ngf",
	"Latn",
}

m["rao"] = {
	"Rao",
	11732596,
	"paa",
	"Latn",
}

m["rap"] = {
	"tiếng Rapa Nui",
	36746,
	"poz-pep",
	"Latn",
	"Tiếng Rapa Nui",
	"Rapa Nui",
}

m["raq"] = {
	"Saam",
	7395644,
	"sit-kic",
}

m["rar"] = {
	"tiếng Rarotonga",
	36745,
	"poz-pep",
	"Latn",
	"Tiếng Rarotonga",
	"Rarotonga",
}

m["ras"] = {
	"Tegali",
	36522,
	"nic-ras",
	"Latn",
}

m["rat"] = {
	"Razajerdi",
	7299461,
	"xme-ttc",
	ancestors = "xme-ttc-eas",
}

m["rau"] = {
	"tiếng Raute",
	7296262,
	"sit-gma",
	"Deva, Latn",
	"Tiếng Raute",
	"Raute",
}

m["rav"] = {
	"Sampang",
	3449115,
	"sit-kic",
}

m["raw"] = {
	"tiếng Rawang",
	542564,
	"sit-nng",
	"Latn",
	"Tiếng Rawang",
	"Rawang",
	sort_key = {remove_diacritics = c.grave .. c.acute .. c.macron},
}

m["rax"] = {
	"Rang",
	3913345,
	"alv-mum",
}

m["ray"] = {
	"Rapa",
	36417,
	"poz-pep",
}

m["raz"] = {
	"Rahambuu",
	3417555,
	"poz-btk",
}

m["rbb"] = {
	"tiếng Palaung Rumai",
	12953797,
	"mkh-pal",
	"Mymr",
	"Tiếng Palaung Rumai",
	"Palaung Rumai",
}

m["rbk"] = {
	"Northern Bontoc",
	nil,
	"phi",
}

m["rbl"] = {
	"Miraya Bikol",
	18664557,
	"phi",
}

m["rcf"] = {
	"tiếng Creole Réunion",
	13198,
	"crp",
	"Latn",
	ancestors = "fr",
	sort_key = s["roa-oil-sortkey"],
}

m["rdb"] = {
	"Rudbari",
	12953072,
	"xme",
	ancestors = "xme-mid",
}

m["rea"] = {
	"Rerau",
	7314883,
	"ngf-mad",
}

m["reb"] = {
	"Rembong",
	7311570,
	"poz-cet",
}

m["ree"] = {
	"Rejang Kayan",
	3423957,
	"poz",
}

m["reg"] = {
	"Kara (Tanzania)",
	6367567,
	"bnt-haj",
}

m["rei"] = {
	"tiếng Reli",
	7310982,
	"inc-eas",
	"Orya, Telu",
	"Tiếng Reli",
	"Reli",
	translit = {
		Telu = "te-translit",
		Orya = "or-translit",
	}
}

m["rej"] = {
	"tiếng Rejang",
	3056339,
	"poz-sus",
	"Rjng",
	"Tiếng Rejang",
	"Rejang",
}

m["rel"] = {
	"tiếng Rendille",
	3447297,
	"cus-som",
	nil,
	"Tiếng Rendille",
	"Rendille",
}

m["rem"] = {
	"Remo",
	3501825,
	"sai-pan",
	"Latn",
}

m["ren"] = {
	"tiếng Rơ Ngao",
	6583692,
	"mkh-nbn",
	"Latn",
	"Tiếng Rơ Ngao",
	"Rơ Ngao",
}

m["rer"] = {
	"Rer Bare",
	12953857,
}

m["res"] = {
	"Reshe",
	36258,
	"nic-knj",
}

m["ret"] = {
	"Retta",
	7317113,
	"ngf",
}

m["rey"] = {
	"Reyesano",
	3111857,
	"sai-tac",
	"Latn",
}

m["rga"] = {
	"Roria",
	7366825,
	"poz-vnc",
}

m["rge"] = {
	"Romani Greek",
	3915435,
}

m["rgk"] = {
	"Rangkas",
	7292645,
	"sit-alm",
}

m["rgn"] = {
	"tiếng Romagnol",
	1641543,
	"roa-git",
	"Latn",
	"Tiếng Romagnol",
	"Romagnol",
	wikimedia_codes = "eml",
}

m["rgr"] = {
	"Resígaro",
	3450504,
	"awd",
	"Latn",
}

m["rgs"] = {
	"tiếng Ra Glai Nam",
	12953069,
	"cmc",
	nil,
	"Tiếng Ra Glai Nam",
	"Ra Glai Nam",
}

m["rgu"] = {
	"Ringgou",
	7334886,
	"poz-tim",
}

m["rhg"] = {
	"tiếng Rohingya",
	3241177,
	"inc-eas",
	"Rohg, Arab, Mymr, Latn, Beng",
	"Tiếng Rohingya",
	"Rohingya",
	ancestors = "inc-obn",
	translit = {Rohg = "Rohg-translit"},
}

m["rhp"] = {
	"Yahang",
	8046792,
	"qfa-tor",
}

m["ria"] = {
	"Reang",
	12953063,
	"tbq-bdg",
}

m["rif"] = {
	"tiếng Tarifit",
	34174,
	"ber",
	"Latn, Tfng, Arab",
	"Tiếng Tarifit",
	"Tarifit",
	translit = { Tfng = "Tfng-translit" },
	standard_chars = {
		Latn = "AaBbCcDdḌḍEeƐɛFfGgƔɣĞğHhḤḥIiJjKkLlMmNnPpQqRrŘřSsṢṣTtṬṭUuWwXxYyZzẒẓʷ",
		Tfng = "ⴰⴳⴷⴹⴼⵖⵉⴽⵍⵎⵏⵓⵔⵙⵛⵜⵡⵢⵣⵥⴱⵀⵅⵊⴳⵯⵕⵚⵟⵇⵃⵄⴻⴽⵯ",
		c.punc
	},
}

m["ril"] = {
	"Riang",
	2741615,
	"mkh-pal",
}

m["rim"] = {
	"Nyaturu",
	7193418,
	"bnt-tkm",
	"Latn",
}

m["rin"] = {
	"Nungu",
	3913350,
	"nic-nin",
	"Latn",
}

m["rir"] = {
	"Ribun",
	7322443,
	"day",
	"Latn",
}

m["rit"] = {
	"Ritarungo",
	7336730,
	"aus-yol",
	"Latn",
}

m["riu"] = {
	"Riung",
	7336938,
	"poz-cet",
	"Latn",
}

m["rjg"] = {
	"Rajong",
	7286370,
	"poz-cet",
	"Latn",
}

m["rji"] = {
	"Raji",
	7286138,
	"sit-gma",
}

m["rjs"] = {
	"tiếng Rajbanshi",
	12640969,
	"inc-eas",
	"Deva, as-Beng",
	"Tiếng Rajbanshi",
	"Rajbanshi",
}

m["rka"] = {
	"tiếng Kraol",
	3199593,
	"mkh-ban",
	"Khmr", -- also Latn?
	"Tiếng Kraol",
	"Kraol"
}

m["rkb"] = {
	"Rikbaktsa",
	2585357,
	"sai-mje",
	"Latn",
}

m["rkh"] = {
	"Rakahanga-Manihiki",
	3119695,
	"poz-pep",
	"Latn",
}

m["rki"] = {
	"tiếng Rakhine",
	3450749,
	"tbq-brm",
	"Mymr",
	"Tiếng Rakhine",
	"Rakhine",
	ancestors = "obr",
}

m["rkm"] = {
	"Marka",
	36030,
	"dmn-wmn",
	"Latn",
}

m["rkt"] = {
	"tiếng Rangpur",
	3241618,
	"inc-eas",
	"as-Beng",
	"Tiếng Rangpur",
	"Rangpur",
	ancestors = "inc-ork",
	translit = "as-translit",
}

m["rkw"] = {
	"tiếng Arakwal",
	34295800,
	"aus-pam",
	"Latn",
	"Tiếng Arakwal",
	"Arakwal",
}

m["rma"] = {
	"tiếng Rama",
	3444486,
	"cba",
	"Latn",
	"Tiếng Rama",
	"Rama",
}

m["rmb"] = {
	"Rembarunga",
	7311553,
	"aus-gun",
	"Latn",
}

m["rmc"] = {
	"tiếng Digan Karpat",
	5045611,
	"inc-rom",
	"Latn, Cyrl",
	"Tiếng Digan Karpat",
	"Digan Karpat",
}

m["rmd"] = {
	"Traveller Danish",
	12640779,
	"inc-rom",
}

m["rme"] = {
	"Angloromani",
	541279,
	"crp",
	"Latn",
	ancestors = "en, rom",
}

m["rmf"] = {
	"tiếng Kalo Phần Lan",
	2093214,
	"inc-rom",
	nil,
	"Tiếng Kalo Phần Lan",
	"Kalo Phần Lan",
}

m["rmg"] = {
	"Traveller Norwegian",
	3177352,
	"inc-rom",
}

m["rmh"] = {
	"Murkim",
	4308074,
	"paa-pau",
}

m["rmi"] = {
	"tiếng Lomavren",
	2495696,
	"qfa-mix",
	"Latn, Armn",
	"Tiếng Lomavren",
	"Lomavren",
	ancestors = "pra-sau, hy",
	translit = {Armn = "Armn-translit"},
	override_translit = true,
}

m["rmk"] = {
	"Romkun",
	7363236,
	"paa",
	"Latn",
}

m["rml"] = {
	"tiếng Digan Baltic",
	513736,
	"inc-rom",
	"Latn, Cyrl",
	"Tiếng Digan Baltic",
	"Digan Baltic",
}

m["rmm"] = {
	"Roma",
	4414831,
}

m["rmn"] = {
	"tiếng Digan Balkan",
	1256701,
	"inc-rom",
	"Cyrl",
	"Tiếng Digan Balkan",
	"Digan Balkan",
}

m["rmo"] = {
	"Sinte Romani",
	1793299,
	"qfa-mix",
	"Latn",
	ancestors = "rom",
}

m["rmp"] = {
	"Rempi",
	7312214,
	"ngf-mad",
}

m["rmq"] = {
	"Caló",
	35466,
	"qfa-mix",
	"Latn",
	ancestors = "rom, osp, roa-opt",
}

m["rms"] = {
	"Romanian Sign Language",
	7362575,
	"sgn",
}

m["rmt"] = {
	"tiếng Domari",
	35394,
	"inc-cen",
	nil,
	"Tiếng Domari",
	"Domari",
}

m["rmu"] = {
	"tiếng Digan Tavringer",
	27808413,
	"inc-rom",
	nil,
	"Tiếng Digan Tavringer",
	"Digan Tavringer",
}

m["rmv"] = {
	"Romanova",
	1298715,
	"art",
	type = "appendix-constructed",
}

m["rmw"] = {
	"Welsh Romani",
	2097387,
	"inc-rom",
}

m["rmx"] = {
	"tiếng Rơ Măm",
	22694600,
	"mkh-nbn",
	nil,
	"Tiếng Rơ Măm",
	"Rơ Măm",
}

m["rmy"] = {
	"Vlax Romani",
	2669199,
	"inc-rom",
}

m["rmz"] = {
	"tiếng Marma",
	21403256,
	"tbq-brm",
	"Mymr, Beng",
	"Tiếng Marma",
	"Marma",
	ancestors = "obr",
}

m["rnd"] = {
	"Ruwund",
	7383564,
	"bnt-lun",
}

m["rng"] = {
	"Ronga",
	2520717,
	"bnt-tsr",
	"Latn",
}

m["rnl"] = {
	"Ranglong",
	7292878,
}

m["rnn"] = {
	"Roon",
	7366335,
	"poz-hce",
}

m["rnp"] = {
	"Rongpo",
	7365672,
	"sit-whm",
}

m["rnw"] = {
	"Rungwa",
	7379873,
	"bnt-mwi",
	"Latn",
}

m["rob"] = {
	"Tae'",
	12473476,
	"poz-ssw",
	"Latn",
}

m["roc"] = {
	"tiếng Ra Glai Cát Gia",
	2932485,
	"cmc",
	"Latn",
	"Tiếng Ra Glai Cát Gia",
	"Ra Glai Cát Gia",
}

m["rod"] = {
	"Rogo",
	3914894,
	"nic-kmk",
}

m["roe"] = {
	"Ronji",
	3441763,
	"poz-ocw",
}

m["rof"] = {
	"Rombo",
	33330,
	"bnt-chg",
	"Latn",
}

m["rog"] = {
	"tiếng Ra Glai Bắc",
	3439680,
	"cmc",
	"Latn",
	"Tiếng Ra Glai Bắc",
	"Ra Glai Bắc",
}

m["rol"] = {
	"Romblomanon",
	13202,
	"phi",
}

m["rom"] = {
	"tiếng Digan",
	13201,
	"inc-rom",
	"Latn, Cyrl",
	"Tiếng Digan",
	"Digan",
}

m["roo"] = {
	"Rotokas",
	13203,
	"paa-nbo",
	"Latn",
}

m["rop"] = {
	"tiếng Kriol Úc",
	35671,
	"crp",
	"Latn",
	"Tiếng Kriol Úc",
	"Kriol Úc",
	ancestors = "en",
}

m["ror"] = {
	"Rongga",
	12473464,
}

m["rou"] = {
	"Runga",
	56793,
}

m["row"] = {
	"Dela-Oenale",
	5253046,
	"poz-tim",
}

m["rpn"] = {
	"Repanbitip",
	7313900,
	"poz-vnc",
}

m["rpt"] = {
	"Rapting",
	7294362,
	"ngf-mad",
}

m["rri"] = {
	"Ririo",
	2404190,
	"poz-ocw",
}

m["rro"] = {
	"Roro",
	34197,
	"poz-ocw",
	"Latn",
}

m["rrt"] = {
	"Arritinngithigh",
	4796002,
	nil,
	"Latn",
}

m["rsb"] = {
	"Romano-Serbian",
	1268244,
}

m["rsl"] = {
	"Russian Sign Language",
	13210,
	"sgn",
}

m["rsk"] = {
	"tiếng Rusnak",
	35660,
	"zlw",
	"Cyrl",
	ancestors = "zlw-osk",
	translit = {Cyrl="rsk-translit"},
	"Tiếng Rusnak",
	"Rusnak",
}

m["rsm"] = {
	"Miriwoong Sign Language",
	24090240,
	"sgn",
}

m["rtc"] = {
	"Rungtu",
	7379867,
	"tbq-kuk",
}

m["rth"] = {
	"Ratahan",
	3420026,
	"phi",
	"Latn",
}

m["rtm"] = {
	"tiếng Rotuma",
	36754,
	"poz-occ",
	"Latn",
	"Tiếng Rotuma",
	"Rotuma",
}

m["rtw"] = {
	"Rathawi",
	12953854,
	"inc-bhi",
}

m["rub"] = {
	"Gungu",
	11165235,
	"bnt-glb",
}

m["ruc"] = {
	"Ruuli",
	7383562,
	"bnt-nyg",
}

m["rue"] = {
	"tiếng Rusyn",
	26245,
	"zle",
	"Cyrl",
	"Tiếng Rusyn",
	"Rusyn",
	ancestors = "zle-ort",
	translit = "rue-translit",
	entry_name = {remove_diacritics = c.grave .. c.acute},
	sort_key = "rue-sortkey",
}

m["ruf"] = {
	"Luguru",
	3437661,
	"bnt-ruv",
	"Latn",
}

m["rug"] = {
	"Roviana",
	3445546,
	"poz-ocw",
	"Latn",
}

m["ruh"] = {
	"Ruga",
	7378127,
}

m["rui"] = {
	"Rufiji",
	7377946,
	"bnt-mbi",
}

m["ruk"] = {
	"Che",
	3915445,
	"nic-nin",
}

m["ruo"] = {
	"tiếng Istria Rumani",
	33622,
	"roa-eas",
	"Latn",
	"Tiếng Istria Rumani",
	"Istria Rumani",
}

m["rup"] = {
	"tiếng Aromania",
	29316,
	"roa-eas",
	"Latn, Grek",
	"Tiếng Aromania",
	"Aromania",
	wikimedia_codes = "roa-rup",
}

m["ruq"] = {
	"tiếng Moglena-Rumani",
	13358,
	"roa-eas",
	"Latn",
	"Tiếng Moglena-Rumani",
	"Moglena-Rumani",
}

m["rut"] = {
	"tiếng Rutul",
	36757,
	"cau-wsm",
	"Cyrl, Latn",
	"Tiếng Rutul",
	"Rutul",
	display_text = {Cyrl = s["cau-Cyrl-displaytext"]},
	entry_name = {
		Cyrl = s["cau-Cyrl-entryname"],
		Latn = s["cau-Latn-entryname"],
	},
}

m["ruu"] = {
	"Lanas Lobu",
	12953676,
}

m["ruy"] = {
	"Mala (Nigeria)",
	3913381,
	"nic-kau",
}

m["ruz"] = {
	"Ruma",
	3913326,
	"nic-kau",
}

m["rwa"] = {
	"Rawo",
	3504269,
}

m["rwk"] = {
	"Rwa",
	7985624,
	"bnt-chg",
}

m["rwm"] = {
	"Amba",
	788423,
	"bnt-kbi",
	"Latn",
}

m["rwo"] = {
	"Rawa",
	11732598,
	"ngf-fin",
	"Latn",
}

m["rxd"] = {
	"Ngardi",
	7022063,
}

m["rxw"] = {
	"Karuwali",
	6881575,
}

m["ryn"] = {
	"tiếng Bắc Amami Ōshima",
	2840988,
	"jpx-nry",
	"Jpan",
	"Tiếng Bắc Amami Ōshima",
	"Bắc Amami Ōshima",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["rys"] = {
	"tiếng Yaeyama",
	34203,
	"jpx-sry",
	"Jpan",
	"Tiếng Yaeyama",
	"Yaeyama",
	translit = s["Jpan-translit"],
	sort_key = s["Jpan-sortkey"],
}

m["ryu"] = {
	"tiếng Okinawa",
	34233,
	"jpx-nry",
	"Jpan",
	"Tiếng Okinawa",
	"Okinawa",
	translit = s["Jpan-translit"],
	sort_key = s["Jpan-sortkey"],
}

m["rzh"] = {
	"Razihi",
	16911222,
	"sem-osa",
	"Arab",
	ancestors = "sem-srb",
}

return require("Module:languages").finalizeData(m, "language")