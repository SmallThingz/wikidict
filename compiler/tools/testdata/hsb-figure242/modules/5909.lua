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
	"Chamling",
	3436664,
	"sit-kic",
	"Deva",
}

m["rac"] = {
	"Rasawa",
	56443,
	"paa-lkp",
	"Latn",
}

m["rad"] = {
	"Rade",
	3429088,
	"cmc",
	"Latn",
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
	"Rabha",
	7278686,
	"tbq-bdg",
	"Beng, Latn",
}

m["rai"] = {
	"Ramoaaina",
	3418509,
	"poz-ocw",
	"Latn",
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
	"Canela",
	2936334,
	"sai-nje",
	"Latn",
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
	"Rapa Nui",
	36746,
	"poz-pep",
	"Latn",
}

m["raq"] = {
	"Saam",
	7395644,
	"sit-kic",
}

m["rar"] = {
	"Rarotongan",
	36745,
	"poz-pep",
	"Latn",
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
	"Raute",
	7296262,
	"sit-gma",
	"Deva, Latn",
}

m["rav"] = {
	"Sampang",
	3449115,
	"sit-kic",
}

m["raw"] = {
	"Rawang",
	542564,
	"sit-nng",
	"Latn",
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
	"Rumai Palaung",
	12953797,
	"mkh-pal",
	"Mymr",
}

m["rbk"] = {
	"Northern Bontoc",
	63311016,
	"phi",
	"Latn",
}

m["rbl"] = {
	"Miraya Bikol",
	18664557,
	"phi",
	"Latn",
}

m["rcf"] = {
	"Réunion Creole French",
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
	"Reli",
	7310982,
}

m["rej"] = {
	"Rejang",
	3056339,
	"poz",
	"Rjng",
}

m["rel"] = {
	"Rendille",
	3447297,
	"cus-som",
	"Latn",
}

m["rem"] = {
	"Remo",
	3501825,
	"sai-pan",
	"Latn",
}

m["ren"] = {
	"Rengao",
	6583692,
	"mkh",
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
	"poz-vnn",
	"Latn",
}

m["rge"] = {
	"Romano-Greek",
	3915435,
	"qfa-mix",
	"Latn", -- and/or Grek?
	ancestors = "rom, el",
}

m["rgk"] = {
	"Rangkas",
	7292645,
	"sit-alm",
}

m["rgn"] = {
	"Romagnol",
	1641543,
	"roa-git",
	"Latn",
	wikimedia_codes = "eml",
}

m["rgr"] = {
	"Resígaro",
	3450504,
	"awd",
	"Latn",
}

m["rgs"] = {
	"Southern Roglai",
	12953069,
}

m["rgu"] = {
	"Ringgou",
	7334886,
	"poz-tim",
}

m["rhg"] = {
	"Rohingya",
	3241177,
	"inc-bas",
	"Rohg, Arab, Mymr, Latn, Beng",
	ancestors = "inc-obn",
	translit = {
		Rohg = "Rohg-translit",
	},
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
	"Tarifit",
	34174,
	"ber",
	"Latn, Tfng, Arab",
	translit = { Tfng = "Tfng-translit" },
	standardChars = {
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
	"Rajbanshi",
	12640969,
	"inc-krn",
	"Deva",
}

m["rka"] = {
	"Kraol",
	3199593,
	"mkh-ban",
	"Khmr", -- also Latn?
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
	"Rakhine",
	3450749,
	"tbq-brm",
	"Mymr",
	ancestors = "obr",
}

m["rkm"] = {
	"Marka",
	36030,
	"dmn-wmn",
	"Latn",
}

m["rkt"] = {
	"Kamta",
	3241618,
	"inc-krn",
	"as-Beng, Latn",
	translit = "as-translit",
}

m["rkw"] = {
	"Arakwal",
	34295800,
	"aus-pam",
	"Latn",
}

m["rma"] = {
	"Rama",
	3444486,
	"cba",
}

m["rmb"] = {
	"Rembarunga",
	7311553,
	"aus-gun",
	"Latn",
}

m["rmc"] = {
	"Carpathian Romani",
	5045611,
	"inc-rom",
	"Latn",
}

m["rmd"] = {
	"Traveller Danish",
	12640779,
	"qfa-mix",
	"Latn",
	ancestors = "rom, da",
}

m["rme"] = {
	"Angloromani",
	541279,
	"qfa-mix",
	"Latn",
	ancestors = "rom, en",
}

m["rmf"] = {
	"Kalo Finnish Romani",
	2093214,
	"inc-rom",
	"Latn",
}

m["rmg"] = {
	"Traveller Norwegian",
	3177352,
	"qfa-mix",
	"Latn",
	ancestors = "rom, no",
}

m["rmh"] = {
	"Murkim",
	4308074,
	"paa-pau",
}

m["rmi"] = {
	"Lomavren",
	2495696,
	"qfa-mix",
	"Latn, Armn",
	ancestors = "pra-sau, hy",
	translit = {
		Armn = "Armn-translit"
	},
	override_translit = true,
}

m["rmk"] = {
	"Romkun",
	7363236,
	"paa",
	"Latn",
}

m["rml"] = {
	"Baltic Romani",
	513736,
	"inc-rom",
	"Latn",
}

m["rmm"] = {
	"Roma",
	4414831,
}

m["rmn"] = {
	"Balkan Romani",
	1256701,
	"inc-rom",
	"Latn",
}

m["rmo"] = {
	"Sinte Romani",
	1793299,
	"inc-rom",
	"Latn",
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
	"Domari",
	35394,
	"inc-cen",
}

m["rmu"] = {
	"Tavringer Romani",
	27808413,
	"qfa-mix",
	"Latn",
	ancestors = "rom, sv",
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
	"Latn",
}

m["rmx"] = {
	"Romam",
	22694600,
	"mkh",
}

m["rmy"] = {
	"Vlax Romani",
	2669199,
	"inc-rom",
	"Latn",
}

m["rmz"] = {
	"Marma",
	21403256,
	"tbq-brm",
	"Mymr",
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
	"Cacgia Roglai",
	2932485,
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
	"Northern Roglai",
	3439680,
	"cmc",
	"Latn",
}

m["rol"] = {
	"Romblomanon",
	13202,
	"phi",
}

m["rom"] = {
	"Romani",
	13201,
	"inc-rom",
	"Latn, Cyrl",
}

m["roo"] = {
	"Rotokas",
	13203,
	"paa-nbo",
	"Latn",
}

m["rop"] = {
	"Australian Kriol",
	35671,
	"crp",
	"Latn",
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
	"Latn",
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
	"qfa-mix",
	"Latn", -- and Cyrl?
	ancestors = "rom, sh",
}

m["rsl"] = {
	"Russian Sign Language",
	13210,
	"sgn",
}

m["rsk"] = {
	"Pannonian Rusyn",
	35660,
	"zlw",
	"Cyrl",
	ancestors = "zlw-osk",
	translit = "rsk-translit",
	sort_key = {
		Cyrl = {
			from = {"ґ", "є", "ї", "ь"},
			to = {"г" .. p[1], "е" .. p[1], "и" .. p[1], "я" .. p[1]}
		}
	},
	standardChars = "АаБбВвГгҐґДдЕеЄєЖжЗзИиІіЇїЙйКкЛлМмНнОоПпРрСсТтУуФфХхЦцЧчШшЩщЬьЮюЯя" .. c.punc:gsub("'", ""),  -- Exclude apostrophe.
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
	"Rotuman",
	36754,
	"poz-pcc",
	"Latn",
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
	"Latn",
}

m["ruc"] = {
	"Ruuli",
	7383562,
	"bnt-nyg",
}

m["rue"] = {
	"Carpathian Rusyn",
	26245,
	"zle",
	"Cyrl",
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
	"Istro-Romanian",
	33622,
	"roa-eas",
	"Latn",
}

m["rup"] = {
	"Aromanian",
	29316,
	"roa-eas",
	"Latn, Polyt",
	display_text = {
		Polyt = s["Polyt-displaytext"],
	},
	entry_name = {
		Polyt = s["Polyt-entryname"],
	},
	sort_key = {
		Polyt = s["Polyt-sortkey"],
	},
	wikimedia_codes = "roa-rup",
}

m["ruq"] = {
	"Megleno-Romanian",
	13358,
	"roa-eas",
	"Latn",
}

m["rut"] = {
	"Rutul",
	36757,
	"cau-wsm",
	"Cyrl, Latn",
	translit = "rut-translit",
	override_translit = true,
	display_text = {
		Cyrl = s["cau-Cyrl-displaytext"]
	},
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
	"Northern Amami Ōshima",
	2840988,
	"jpx-nry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["rys"] = {
	"Yaeyama",
	34203,
	"jpx-sry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["ryu"] = {
	"Okinawan",
	34233,
	"jpx-nry",
	"Jpan",
	translit = s["jpx-translit"],
	display_text = s["jpx-displaytext"],
	entry_name = s["jpx-entryname"],
	sort_key = s["jpx-sortkey"],
}

m["rzh"] = {
	"Razihi",
	16911222,
	"sem-osa",
	"Arab",
	ancestors = "sem-srb",
}

return require("Module:languages").finalizeData(m, "language")