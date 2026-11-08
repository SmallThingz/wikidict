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

local Cyrl = {"Cyrl"}
local Latn = {"Latn"}

local m = {}

m["maa"] = {
	"サン・ヘロニモ・テコアトル・マサテク語",
	"Q7692927",
	"omq-maz",
	scripts = Latn,
}

m["mab"] = {
	"ユタンドゥチ・ミステク語",
	"Q12645448",
	"omq-mxt",
	scripts = Latn,
}

m["mad"] = {
	"マドゥラ語",
	otherNames = "Madurese",
	"Q36213",
	"poz-msa",
	scripts = Latn,
}

m["mae"] = {
	"Bo-Rukul",
	"Q34967",
	"nic-ple",
	scripts = Latn,
}

m["maf"] = {
	"マファ語",
	"Q35819",
	scripts = Latn,
}

m["mag"] = {
	"マガヒー語",
	"Q33728",
	"inc-eas",
	scripts = {"Deva"},
	ancestors = {"bh"},
}

m["mai"] = {
	"マイティリー語",
	"Q36109",
	"inc-eas",
	scripts = {"Tirh", "Kthi", "Newa", "Deva"},
	ancestors = {"bh"},
}

m["maj"] = {
	"ハラパ・デ・ディアス・マサテク語",
	"Q3915999",
	"omq-maz",
	scripts = Latn,
}

m["mak"] = {
	"マカサル語",
	"Q33643",
	"poz-ssw",
	scripts = {"Latn", "Maka"},
}

m["mam"] = {
	"マム語",
	"Q33467",
	"myn",
	scripts = Latn,
}

m["man"] = {
	"マンディンゴ語",
	"Q35772",
	"dmn-man",
	scripts = Latn,
}

m["maq"] = {
	"チキウィトラン・マサテク語",
	"Q5101757",
	"omq-maz",
	scripts = Latn,
}

m["mas"] = {
	"マサイ語",
	"Q35787",
	"sdv-lma",
	scripts = Latn,
}

m["mat"] = {
	"サンフランシスコ・マトラツィンカ語",
	"Q12953704",
	"omq",
	otherNames = {"San Francisco Matlatzinca", "San Francisco Oxtotilpa Matlatzinca"},
	scripts = Latn,
}

m["mau"] = {
	"ワウトラ・マサテク語",
	"Q36230",
	"omq-maz",
	scripts = Latn,
}

m["mav"] = {
	"サテレ＝マウェ語",
	"Q6794475",
	"tup",
	scripts = Latn,
}

m["maw"] = {
	"マンプルリ語",
	"Q35804",
	"nic-wov",
	scripts = Latn,
}

m["max"] = {
	"北モルッカ・マレー語",
	"Q7056136",
	"crp",
	scripts = Latn,
}

m["maz"] = {
	"中央マサワ語",
	"Q36228",
	"oto",
	scripts = Latn,
}

m["mba"] = {
	"ヒガオノン語",
	"Q5753411",
	"mno",
	scripts = Latn,
}

m["mbb"] = {
	"西部ブキドゥノン・マノボ語",
	"Q7987643",
	"mno",
	scripts = Latn,
}

m["mbc"] = {
	"マクシ語",
	"Q56633",
	"sai-car",
	otherNames = {"Makushi", "Makusi", "Makuxi", "Macusi", "Macussi", "Teweya"},
	scripts = Latn,
}

m["mbd"] = {
	"ディババウォン・マノボ語",
	"Q18755523",
	"mno",
	scripts = Latn,
}

m["mbe"] = {
	"モラレ語",
	"Q3319444",
	"nai-plp",
	otherNames = {"Molala", "Molalla", "Molele"},
	scripts = Latn,
}

m["mbf"] = {
	"ババ・マライ語",
	"Q18642798",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["mbh"] = {
	"マンセン語",
	"Q6749147",
	"poz-ocw",
	scripts = Latn,
}

m["mbi"] = {
	"イリアヌン・マノボ語",
	"Q14916911",
	"mno",
	scripts = Latn,
}

m["mbj"] = {
	"ナドゥブ語",
	"Q3335011",
	"sai-nad",
	scripts = Latn,
}

m["mbk"] = {
	"マロル語",
	"Q6744477",
	"poz-ocw",
	scripts = Latn,
}

m["mbl"] = {
	"マシャカリ語",
	"Q3029682",
	"sai-mje",
	scripts = Latn,
}

m["mbm"] = {
	"ンバンバ語",
	otherNames = {"ンバーマ語", "Mbaama", "Mbamba", "Ombamba"},
	"Q36407",
	"bnt-mbt",
	scripts = Latn,
}

m["mbn"] = {
	"Macaguán",
	"Q3273980",
	"sai-guh",
	scripts = Latn,
}

m["mbo"] = { -- is, like 'bqz', 'bsi' and 'bss', a dialect of Manenguba
	"ンボ語 (カメルーン)",
	nil,
	"bnt-mne",
	otherNames = {"Mbo"},
	scripts = Latn,
}

m["mbp"] = {
	"マラヨ語",
	"Q3012604",
	"cba",
	otherNames = {"Damana", "Malayo"},
	scripts = Latn,
}

m["mbq"] = {
	"マイシン語",
	"Q3448149",
	scripts = Latn,
}

m["mbr"] = {
	"ヌカク・マクー語",
	"Q3346228",
	"sai-nad",
	scripts = Latn,
}

m["mbs"] = {
	"サランガニ・マノボ語",
	"Q7423093",
	"mno",
	scripts = Latn,
}

m["mbt"] = {
	"マティグサルグ・マノボ語",
	"Q6787447",
	"mno",
	scripts = Latn,
}

m["mbu"] = {
	"ンブラ・ブワッザ語",
	"Q3913324",
	"nic-jrn",
	scripts = Latn,
}

m["mbv"] = {
	"ンブルンギシ語",
	"Q36003",
	"alv-nal",
	scripts = Latn,
}

m["mbw"] = {
	"Maring",
	"Q3293280",
	scripts = Latn,
}

m["mbx"] = {
	"マリ語",
	"Q6760942",
	"paa-spk",
	otherNames = {"Mari (East Sepik Province)"},
	scripts = Latn,
}

m["mby"] = {
	"メーモニー語",
	"Q4180871",
	"inc-snd",
	scripts = {"Gujr", "ur-Arab"},
	ancestors = {"inc-vra"},
}

m["mbz"] = {
	"アモルテペク・ミステク語",
	"Q13583504",
	"omq-mxt",
	scripts = Latn,
}

m["mca"] = {
	"マカ語",
	"Q3281043",
	"sai-mtc",
	scripts = Latn,
}

m["mcb"] = {
	"マチゲンガ語",
	"Q3915441",
	"awd",
	scripts = Latn,
}

m["mcc"] = {
	"Bitur",
	"Q4919173",
}

m["mcd"] = {
	"シャラナワ語",
	"Q12953881",
	"sai-pan",
	scripts = Latn,
}

m["mce"] = {
	"Itundujia Mixtec",
	"Q12953727",
	"omq-mxt",
	scripts = Latn,
}

m["mcf"] = {
	"マツェス語",
	"Q2981620",
	"sai-pan",
	scripts = Latn,
}

m["mcg"] = {
	"マポヨ語",
	"Q56946",
	"sai-car",
	scripts = Latn,
}

m["mch"] = {
	"マキリタリ語",
	"Q3082027",
	"sai-car",
	otherNames = {"Makiritare", "Ye'kwana", "Ye'kuana", "Yekuana", "De'kwana", "So'to", "Maiongong"},
	scripts = Latn,
}

m["mci"] = {
	"メセ語",
	"Q6821190",
}

m["mcj"] = {
	"Mvanip",
	"Q3913281",
	"nic-mmb",
	scripts = Latn,
}

m["mck"] = {
	"ンブンダ語",
	"Q34170",
	"bnt-clu",
	scripts = Latn,
}

m["mcl"] = {
	"マカグワヘ語",
	"Q6722435",
	"sai-tuc",
	scripts = Latn,
}

m["mcm"] = {
	"マラッカ・クレオール・ポルトガル語",
	"Q2669169",
	"crp",
	ancestors = {"pt"},
	otherNames = {"Malacca Creole Portuguese", "Malaccan Creole Portuguese"},
	scripts = Latn,
}

m["mcn"] = {
	"マサナ語",
	"Q56668",
	"cdc-mas",
	otherNames = {"Massa", "Masa"},
}

m["mco"] = {
	"コアトラン・ミヘ語",
	"Q25559716",
	"nai-miz",
	scripts = Latn,
}

m["mcp"] = {
	"マカア語",
	"Q35803",
	"bnt-mka",
}

m["mcq"] = {
	"Ese",
	"Q5397551",
	"ngf",
	scripts = Latn,
}

m["mcr"] = {
	"メニャ語",
	"Q11732444",
	"ngf",
}

m["mcs"] = {
	"マンバイ語",
	"Q6748872",
	"alv-mbm",
}

m["mcu"] = {
	"カメルーン・マンビラ語",
	"Q19359039",
	"nic-mmb",
	scripts = Latn,
}

m["mcv"] = {
	"ミナニバイ語",
	"Q6863167",
	"ngf",
}

m["mcw"] = {
	"マワ語",
	"Q3441333",
	"cdc-est",
	otherNames = {"Mawa (Chad)", "Mahwa"},
	scripts = Latn,
}

m["mcx"] = {
	"Mpiemo",
	"Q35908",
	"bnt-bek",
}

m["mcy"] = {
	"南ワトゥット語",
	"Q12953293",
	"poz-ocw",
}

m["mcz"] = {
	"マワン語",
	"Q11732429",
	"ngf-mad",
}

m["mda"] = {
	"マダ語（ナイジェリア）",
	"Q3915843",
	"nic-nin",
	otherNames = {"Mada"},
	scripts = Latn,
}

m["mdb"] = {
	"モリギ語",
	"Q6912195",
	"paa-kiw",
}

m["mdc"] = {
	"マレ語",
	"Q6742927",
	"ngf-mad",
}

m["mdd"] = {
	"ムブム語",
	"Q36170",
	"alv-mbm",
}

m["mde"] = {
	"マバ語",
	"Q35860",
	"ssa",
}

m["mdf"] = {
	"モクシャ語",
	"Q13343",
	"urj-mdv",
	otherNames = {"Mordvin"},
	scripts = Cyrl,
	translit_module = "mdf-translit",
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}},
	override_translit = true,
}

m["mdg"] = {
	"Massalat",
	"Q759984",
}

m["mdh"] = {
	"マギンダナオ語",
	"Q33717",
	"phi",
	scripts = {"Latn", "Arab"},
}

m["mdi"] = {
	"マムブ語",
	"Q3033594",
	"csu-mle",
}

m["mdj"] = {
	"マンベトゥ語",
	"Q56327",
	"csu-maa",
}

m["mdk"] = {
	"マングブトゥ語",
	"Q6748877",
	"csu-mle",
}

m["mdl"] = {
	"マルタ手話",
	"Q6744816",
	"sgn",
}

m["mdm"] = {
	"マヨゴ語",
	"Q6797580",
	"nic-nke",
	scripts = Latn,
}

m["mdn"] = {
	"ンバティ語",
	otherNames = {"Lissongo", "Songo"},
	"Q36165",
	"bnt-ngn",
}

m["mdp"] = {
	"ンバラ語",
	"Q6799583",
	"bnt-pen",
}

m["mdq"] = {
	"ンボレ語",
	otherNames = "Mbole",
	"Q6799727",
	"bnt-mbe",
}

m["mdr"] = {
	"マンダル語",
	"Q35995",
	"poz-ssw",
	scripts = {"Bugi", "Latn"},
}

m["mds"] = {
	"マリア語",
	"Q3448673",
	otherNames = {"Maria (New Guinea)", "Maria (Papua New Guinea)"},
}

m["mdt"] = {
	"ンベテ語",
	otherNames = {"ンベレ語", "Mbere", "Mbété"},
	"Q36062",
	"bnt-mbt",
}

m["mdu"] = {
	"ンボコ語",
	"Q36058",
	"bnt-mbo",
}

m["mdv"] = {
	"サンタ・ルシア・モンテベルデ・ミステク語",
	"Q12953722",
	"omq-mxt",
	scripts = Latn,
}

m["mdw"] = {
	"ムボシ語",
	"Q36035",
	"bnt-mbo",
}

m["mdx"] = {
	"ディジン語",
	"Q35313",
	"omv-diz",
}

m["mdy"] = {
	"マレ語",
	"Q795327",
	"omv-ome",
}

m["mdz"] = {
	"スルイ・ド・パラー語",
	"Q10322149",
	"tup-gua",
	scripts = Latn,
}

m["mea"] = {
	"メンカ語",
	"Q36078",
	"nic-grs",
	scripts = Latn,
}

m["meb"] = {
	"イコビ語",
	"Q11732241",
	"ngf",
	otherNames = {"Ikobi", "Mena", "Ikobi-Mina"},
	scripts = Latn,
}

m["mec"] = {
	"マラ語",
	"Q6772774",
	otherNames = {"Leelawarra", "Leelalwarra", "Mala", "Marra"},
}

m["med"] = {
	"メルパ語",
	"Q36166",
}

m["mee"] = {
	"メンゲン語",
	"Q3305831",
	"poz-ocw",
}

m["mef"] = {
	"Megam",
	"Q6808589",
}

m["meg"] = {
	"メア語",
	"Q12952836",
	"poz-cln",
}

m["meh"] = {
	"南西部トラヒアコ・ミステク語",
	"Q7070686",
	"omq-mxt",
	scripts = Latn,
}

m["mei"] = {
	"ミドブ語",
	"Q36007",
	"nub",
	scripts = Latn,
}

m["mej"] = {
	"メアフ語",
	"Q11732436",
	"paa-wpa",
	otherNames = {"Meyah", "Arfak", "Mansibaber", "Mejah",  "Meax", "マンシバベル語"},
}

m["mek"] = {
	"メケオ語",
	"Q3304803",
	"poz-ocw",
}

m["mel"] = {
	"中央メラナウ語",
	"Q18638319",
	"poz-swa",
	scripts = Latn,
}

m["mem"] = {
	"マンガラ語",
	"Q6748664",
}

m["men"] = {
	"メンデ語",
	"Q1478672",
	"dmn-msw",
	scripts = {"Latn", "Mend"},
}

m["meo"] = {
	"ケダ・マレー語",
	"Q4925684",
	"poz-mly",
	scripts = Latn,
}

m["mep"] = {
	"ミリウン語",
	"Q3111847",
}

m["meq"] = {
	"メレイ語",
	"Q3502314",
	"cdc-cbm",
	scripts = Latn,
}

m["mer"] = {
	"メル語",
	"Q13313",
	"bnt-kka",
	scripts = Latn,
}

m["mes"] = {
	"マスマジェ語",
	"Q3440448",
}

m["met"] = {
	"Mato",
	"Q3299190",
	"poz-ocw",
	otherNames = {"Nenaya", "Nengaya", "Nineia"},
	scripts = Latn,
}

m["meu"] = {
	"モトゥ語",
	"Q33516",
	"poz-ocw",
	otherNames = {"Pure Motu", "True Motu"},
	scripts = Latn,
}

m["mev"] = {
	"Mano",
	"Q3913286",
	"dmn-mda",
	scripts = Latn,
}

m["mew"] = {
	"マアカ語",
	"Q3438764",
	"cdc-wst",
	scripts = Latn,
}

m["mey"] = {
	"ハッサーニーヤ語",
	"Q56231",
	"sem-arb",
	scripts = {"Arab"},
}

m["mez"] = {
	"メノミネ語",
	"Q13363",
	"alg",
	scripts = Latn,
	sort_key = {
		from = {"·"},
		to   = {""}} ,
}

m["mfa"] = {
	"ジャウィ語",
	"Q1199751",
	"poz-mly",
	scripts = {"Latn", "Thai", "Arab"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["mfb"] = {
	"バンカ語",
	"Q3258818",
}

m["mfc"] = {
	"ンバ語",
	"Q4286464",
	"nic-mbc",
	scripts = Latn,
}

m["mfd"] = {
	"メンダンクウェ＝ンクウェン語",
	"Q11129537",
	"nic-nge",
	scripts = Latn,
}

m["mfe"] = {
	"モーリシャス・クレオール語",
	"Q33661",
	"crp",
	otherNames = {"Mauritian"},
	scripts = Latn,
	ancestors = {"fr"},
}

m["mff"] = {
	"Naki",
	"Q36083",
	"nic-bbe",
	otherNames = {"Bukwen", "Mashi"},
	scripts = Latn,
}

m["mfg"] = {
	"Mixifore",
	"Q3914478",
	"dmn-mok",
	otherNames = {"Mogofin"},
}

m["mfh"] = {
	"マタル語",
	"Q3501751",
	"cdc-cbm",
	scripts = Latn,
}

m["mfi"] = {
	"ワンダラ語",
	"Q3441249",
	"cdc-cbm",
	otherNames = {"Mandara"},
	scripts = Latn,
}

m["mfj"] = {
	"メフェレ語",
	"Q3501871",
	"cdc-cbm",
}

m["mfk"] = {
	"北モフ語",
	"Q56303",
}

m["mfl"] = {
	"プタイ語",
	"Q56291",
}

m["mfm"] = {
	"南マルギ語",
	"Q56248",
}

m["mfn"] = {
	"クロスリバー・ムベンベ語",
	"Q3915395",
	"nic-uce",
	scripts = Latn,
}

m["mfo"] = {
	"ンベ語",
	"Q36075",
	"nic-eko",
	scripts = Latn,
}

m["mfp"] = {
	"マカッサル・マレー語",
	"Q12952776",
	"qfa-mix",
	scripts = Latn,
}

m["mfq"] = {
	"モバ語",
	"Q19921578",
	"nic-grm",
	scripts = Latn,
}

m["mfr"] = {
	"Marrithiyel",
	"Q6773014",
	"aus-dal",
	otherNames = {"Marrithiyal", "Marithiel", "Maridhiel", "Maridhiyel", "Berringen", "Bringen", "Brinken", "Nganygit", "Marriammu", "Mare-Ammu", "Maridjabin", "Maredyerbin", "Maretyabin", "Maridyerbin", "Maritjabin", "Marridan", "Meradan", "Marramanindjdji", "Marramaninydyi", "Marimanindji", "Mariyedi"},
	scripts = Latn,
}

m["mfs"] = {
	"メキシコ手話",
	"Q3915511",
	"sgn",
	scripts = Latn, -- when documented
}

m["mft"] = {
	"モケラン語",
	"Q3319387",
	"poz-aay",
	scripts = Latn,
}

m["mfu"] = {
	"ムブウェラ語",
	"Q11004988",
	"bnt-clu",
	ancestors = {"lch"},
}

m["mfv"] = {
	"マンジャク語",
	"Q35822",
	"alv-pap",
}

m["mfw"] = {
	"ムラハ語",
	"Q6933720",
}

m["mfx"] = {
	"メロ語",
	"Q6813268",
	"omv-nom",
}

m["mfy"] = {
	"マヨ語",
	"Q56729",
	"azc-trc",
	scripts = Latn,
	sort_key = {
		from = {"á", "é", "í", "ó", "ú"},
		to   = {"a", "e", "i", "o", "u"}},
}

m["mfz"] = {
	"マバン語",
	"Q20526385",
	"sdv",
}

m["mga"] = {
	"中世アイルランド語",
	"Q36116",
	"cel-gae",
	scripts = Latn,
	ancestors = {"sga"},
	entry_name = {
		from = {"ḟ", "ṁ", "ṅ", "ṡ", "Ḟ", "Ṁ", "Ṅ", "Ṡ", "ä", "ë", "ï", "ö", "ü", "·"},
		to   = {"f", "m", "n", "s", "F", "M", "N", "S", "a", "e", "i", "o", "u"}} ,
	sort_key = {
		from = {"á", "é", "æ", "ǽ", "í", "ó", "ú", "^h", "-"},
		to   = {"a", "e", "e", "e", "i", "o", "u"}} ,
}

m["mgb"] = {
	"Mararit",
	"Q56359",
	"sdv-tmn",
}

m["mgc"] = {
	"Morokodo",
	"Q6913216",
	"csu-bbk",
	scripts = Latn,
}

m["mgd"] = {
	"Moru",
	"Q6915014",
	"csu-mma",
}

m["mge"] = {
	"Mango",
	"Q713659",
	"csu-sar",
}

m["mgf"] = {
	"Maklew",
	"Q6739816",
}

m["mgg"] = {
	"Mpongmpong",
	"Q35924",
	"bnt-bek",
}

m["mgh"] = {
	"Makhuwa-Meetto",
	"Q33604",
	"bnt-mak",
	ancestors = {"vmw"},
	scripts = Latn,
}

m["mgi"] = {
	"Jili",
	"Q3914497",
	"nic-pls",
	otherNames = {"Lijili", "Migili", "Mijili"},
}

m["mgj"] = {
	"Abureni",
	"Q3441256",
	"nic-cde",
	scripts = Latn,
}

m["mgk"] = {
	"Mawes",
	"Q6794395",
	"paa",
}

m["mgl"] = {
	"Maleu-Kilenge",
	"Q3281884",
}

m["mgm"] = {
	"マンバエ語",
	"Q35774",
	"poz-tim",
	scripts = Latn,
}

m["mgn"] = {
	"Mbangi",
	"Q11017443",
	"nic-ngd",
	scripts = Latn,
}

m["mgo"] = {
	"Meta'",
	"Q36054",
	"nic-mom",
	scripts = Latn,
}

m["mgp"] = {
	"Eastern Magar",
	"Q12952758",
	"sit-gma",
}

m["mgq"] = {
	"Malila",
	"Q6743679",
	"bnt-mby",
	scripts = Latn,
}

m["mgr"] = {
	"Mambwe-Lungu",
	"Q626210",
	"bnt-mwi",
	scripts = Latn,
}

m["mgs"] = {
	"Manda (Tanzania)",
	"Q16939267",
	"bnt-bki",
	otherNames = {"Kimanda", "Kinyasa", "Nyasa"},
}

m["mgt"] = {
	"Mongol",
	"Q11260674",
	"paa",
	scripts = Latn,
}

m["mgu"] = {
	"Mailu",
	"Q3278246",
	"ngf",
}

m["mgv"] = {
	"Matengo",
	"Q6786446",
	"bnt-mbi",
	scripts = Latn,
}

m["mgw"] = {
	"Matumbi",
	"Q6791974",
	"bnt-mbi",
	otherNames = {"Matuumbi", "Kimatumbi", "Kimatuumbi"},
	scripts = Latn,
}

m["mgy"] = {
	"Mbunga",
	"Q6799817",
	"bnt-kil",
}

m["mgz"] = {
	"Mbugwe",
	"Q3426367",
	"bnt-mra",
}

m["mha"] = {
	"マンダ語 (インド)",
	"Q56760",
	"dra",
}

m["mhb"] = {
	"マホングウェ語",
	"Q35816",
	"bnt-kel",
}

m["mhc"] = {
	"モトシントレク語",
	"Q1941682",
	"myn",
}

m["mhd"] = {
	"ンブグ語",
	"Q36152",
	"qfa-mix",
	otherNames = {"Ma'a", "Normal Mbugu", "Inner Mbugu"},
	scripts = Latn,
	ancestors = {"asa"},
}

m["mhe"] = {
	"ベシシ語",
	"Q2742262",
	"mkh-asl",
}

m["mhf"] = {
	"ママア語",
	"Q6745346",
	"ngf-fin",
	scripts = Latn,
}

m["mhg"] = {
	"マルグ語",
	"Q6772812",
}

m["mhi"] = {
	"マディ語",
	"Q56670",
	"csu-mma",
}

m["mhj"] = {
	"モゴール語",
	"Q13336",
	"xgn",
	otherNames = {"Moghol"},
}

m["mhk"] = {
	"ムンガカ語",
	"Q36068",
	"nic-nun",
	scripts = Latn,
}

m["mhl"] = {
	"Mauwake",
	"Q6794095",
	"ngf-mad",
}

m["mhm"] = {
	"Makhuwa-Moniga",
	"Q6900145",
	"bnt-mak",
}

m["mhn"] = {
	"モケーニ語",
	"Q268130",
	"gmw",
	scripts = Latn,
	ancestors = {"bar"},
	sort_key = {
		from = {"è", "ò"},
		to = {"e", "o"}
	},
}

m["mho"] = {
	"マシ語",
	"Q10962737",
	"bnt-kav",
	scripts = Latn,
}

m["mhp"] = {
	"バリ島マレー語",
	"Q12473441",
	"crp",
}

m["mhq"] = {
	"マンダン語",
	"Q1957120",
	"sio",
}

m["mhr"] = {
	"東部マリ語",
	"Q973685",
	"urj",
}

m["mhs"] = {
	"ブル語",
	"Q2928650",
	"poz-cma",
	otherNames = {"Buru"},
}

m["mht"] = {
	"マンダワカ語",
	"Q6747924",
	"awd-nwk",
	otherNames = {"Mandauaca", "Mandawaka", "Mandawaca", "Mandauaka", "Mandauáka"},
}

m["mhu"] = {
	"ディガロ＝ミシュミ語",
	"Q56400",
	"sit-gsi",
	otherNames = {"Darang", "Digaro-Mishmi", "Digaro Mishmi"},
	scripts = Latn,
}

m["mhw"] = {
	"ムブクシュ語",
	"Q2691548",
}

m["mhx"] = {
	"ロンウォー語",
	"Q11149315",
	"tbq-brm",
	otherNames = {"Langsu", "Maru"},
}

m["mhy"] = {
	"マアニャン語",
	"Q2328761",
	"poz-bre",
}

m["mhz"] = {
	"モア語",
	"Q2122792",
	"poz-hce",
	otherNames = {"Mor", "Moor", "Austronesian Mor"},
	scripts = Latn,
}

m["mia"] = {
	"マイアミ語",
	"Q56523",
	"alg",
	scripts = Latn,
}

m["mib"] = {
	"アタトラウカ・ミステク語",
	"Q32093046",
	"omq-mxt",
	scripts = Latn,
}

m["mic"] = {
	"ミクマク語",
	"Q13321",
	"alg-eas",
	scripts = Latn,
}

m["mid"] = {
	"マンダ語",
	"Q6991742",
	"sem-ase",
	scripts = {"Mand"},
	ancestors = {"myz"},
}

m["mie"] = {
	"オコテペック・ミステク語",
	"Q25559575",
	"omq-mxt",
	scripts = Latn,
}

m["mif"] = {
	"モフ＝グドゥル語",
	"Q1365132",
	"cdc-cbm",
	scripts = Latn,
}

m["mig"] = {
	"サン・ミゲル・エル・グランデ・ミステク語",
	"Q12953719",
	"omq-mxt",
	otherNames = {"Chalcatongo Mixtec"},
	scripts = Latn,
}

m["mih"] = {
	"チャユコ・ミステク語",
	"Q13583510",
	"omq-mxt",
	scripts = Latn,
}

m["mii"] = {
	"チグメカティトラン・ミステク語",
	"Q12953724",
	"omq-mxt",
	scripts = Latn,
}

m["mij"] = {
	"Mungbam",
	"Q34725",
	"nic-beb",
	otherNames = {"Abar", "Missong", "Munken", "Ngun"},
	scripts = Latn,
}

m["mik"] = {
	"ミカズキ語",
	"Q13316",
	"nai-mus",
	scripts = Latn,
}

m["mil"] = {
	"ペニョーレス・ミステク語",
	"Q42411307",
	"omq-mxt",
	scripts = Latn,
}

m["mim"] = {
	"アラカトラトザラ・ミステク語",
	"Q14697894",
	"omq-mxt",
	scripts = Latn,
}

m["min"] = {
	"ミナンカバウ語",
	"Q13324",
	"poz-mly",
	scripts = {"Latn", "Arab"},
}

m["mio"] = {
	"ピノテーパ・ナショナル・ミステク語",
	"Q7196415",
	"omq-mxt",
	scripts = Latn,
}

m["mip"] = {
	"アパスコ＝アポアラ・ミステク語",
	"Q13583505",
	"omq-mxt",
	scripts = Latn,
}

m["miq"] = {
	"ミスキート語",
	"Q1516803",
	"nai-min",
	otherNames = {"Miskitu"},
	scripts = Latn,
	entry_name = {
		from = {"Â", "â", "Î", "î", "Û", "û"},
		to   = {"A", "a", "I", "i", "U", "u"}},
}

m["mir"] = {
	"イスムス・ミヘ語",
	"Q6088873",
	"nai-miz",
}

m["mit"] = {
	"南部プエブラ・ミステク語",
	"Q7570345",
	"omq-mxt",
	scripts = Latn,
}

m["miu"] = {
	"カカロステペク・ミステク語",
	"Q12953723",
	"omq-mxt",
	scripts = Latn,
}

m["miw"] = {
	"Akoye",
	"Q3327462",
	"ngf",
	scripts = Latn,
}

m["mix"] = {
	"ミステペック・ミステク語",
	"Q6884125",
	"omq-mxt",
	scripts = Latn,
}

m["miy"] = {
	"アユトラ・ミステク語",
	"Q13583508",
	"omq-mxt",
	scripts = Latn,
}

m["miz"] = {
	"コアツォスパン・ミステク語",
	"Q3317290",
	"omq-mxt",
	scripts = Latn,
}

m["mjb"] = {
	"Makalero",
	"Q35729",
	"ngf",
	otherNames = {"Maklere"},
	scripts = Latn,
}

m["mjc"] = {
	"サン・フアン・コロラド・ミステク語",
	"Q12953718",
	"omq-mxt",
	scripts = Latn,
}

m["mjd"] = {
	"北西マイドゥ語",
	"Q3198700",
	"nai-mdu",
	scripts = Latn,
}

m["mje"] = {
	"ムスクム語",
	"Q3913334",
}

m["mjg"] = {
	"トゥ語",
	"Q34214",
	"xgn",
	scripts = Latn,
}

m["mji"] = {
	"ムン語",
	"Q1115317",
	"hmx-mie",
}

m["mjj"] = {
	"マワク語",
	"Q11732427",
	"ngf-mad",
}

m["mjk"] = {
	"マトゥカル語",
	"Q6791963",
	"poz-ocw",
	scripts = Latn,
}

m["mjl"] = {
	"マンデアーリー語",
	"Q6747931",
	"him",
	scripts = {"Deva", "Takr"},
	translit_module = "hi-translit",
}

m["mjm"] = {
	"Medebur",
	"Q6805227",
	"poz-ocw",
	scripts = Latn,
}

m["mjn"] = {
	"Mebu",
	"Q6804364",
	"ngf-fin",
	otherNames = {"Ma"},
}

m["mjo"] = {
	"Malankuravan",
	"Q14916887",
	"dra",
}

m["mjp"] = {
	"Malapandaram",
	"Q10575729",
	"dra",
}

m["mjq"] = {
	"Malaryan",
	"Q12952773",
	"dra",
}

m["mjr"] = {
	"Malavedan",
	"Q12952775",
	"dra",
}

m["mjs"] = {
	"ミシプ語",
	"Q3441264",
	"cdc-wst",
	otherNames = {"Chip"},
	scripts = Latn,
}

m["mjt"] = {
	"サウリア・パハリア語",
	"Q33907",
	"dra",
	otherNames = {"Sauria Paharia", "Sawriya", "Sawriya Pahariya", "Sawriya Malto", "Malto", " Malti", "Maltu", "Maler"},
	scripts = {"Beng", "Deva"},
}

m["mju"] = {
	"マナ・ドーラ語",
	"Q10576453",
	"dra",
	ancestors = {"te"},
}

m["mjv"] = {
	"マナン語",
	"Q3286037",
	"dra",
}

m["mjw"] = {
	"カルビ語",
	"Q56591",
	"tbq-kuk",
	otherNames = {"Arleng", "Mikir"},
	scripts = Latn,
}

m["mjx"] = {
	"マハリ語",
	"Q12953686",
	"mun",
}

m["mjy"] = {
	"マヒカン語",
	"Q3182562",
	"alg-eas",
	scripts = Latn,
}

m["mjz"] = {
	"マジー語",
	"Q6737786",
	"inc-eas",
	ancestors = {"bh"},
}

m["mka"] = {
	"Mbre",
	"Q3450154",
	"nic", --unclassified within niger-congo tho
}

m["mkb"] = {
	"マル・パハリヤ語",
	"Q6583595",
}

m["mkc"] = {
	"シリプト語",
	"Q7515090",
	"qfa-tor",
	scripts = Latn,
}

m["mke"] = {
	"マウチ語",
	"Q21403317",
}

m["mkf"] = {
	"ミヤ語",
	"Q43328",
	"cdc-wst",
	scripts = Latn,
}

m["mkg"] = {
	"莫語",
	"Q3280623",
	"qfa-kms",
	otherNames = {"Mak"},
}

m["mki"] = {
	"ダートキ語",
	"Q32480",
	"inc-wes",
	ancestors = {"mwr"},
}

m["mkj"] = {
	"モキル語",
	otherNames = "Mokilese",
	"Q2335528",
	"poz-mic",
	scripts = Latn,
}

m["mkk"] = {
	"Byep",
	"Q35052",
	"bnt-mka",
}

m["mkl"] = {
	"モコレ語",
	"Q36047",
}

m["mkm"] = {
	"モクレン語",
	"Q3319380",
}

m["mkn"] = {
	"クパン・マライ語",
	"Q18458203",
	"crp",
}

m["mko"] = {
	"Mingang Doso",
	"Q3915382",
	"alv-bwj",
}

m["mkp"] = {
	"Moikodi語",
	"Q6894594",
	"ngf",
}

m["mkq"] = {
	"ベイ・ミウォク語",
	"Q3460957",
	"nai-you",
	scripts = Latn,
}

m["mkr"] = {
	"マラス語",
	"Q11732402",
	"ngf-mad",
}

m["mks"] = {
	"シラカヨアパン・ミステク語",
	"Q7514027",
	"omq-mxt",
	scripts = Latn,
}

m["mkt"] = {
	"ヴァマレ語",
	"Q14916907",
	"poz-cln",
	scripts = Latn,
}

m["mku"] = {
	"Konyanka Maninka",
	"Q11163298",
	"dmn-mnk",
}

m["mkv"] = {
	"マフェア語",
	"Q3073532",
	"poz-vnc",
	scripts = Latn,
}

m["mkx"] = {
	"Cinamiguin Manobo",
	"Q12953697",
	"mno",
}

m["mky"] = {
	"東マキアン語",
	"Q3512690",
	"poz-hce",
	scripts = Latn,
}

m["mkz"] = {
	"Makasae",
	"Q35782",
	"ngf",
}

m["mla"] = {
	"タマンボ語",
	"Q1153276",
	"poz-vnc",
	otherNames = {"Malo", "Tamabo", "Maloese"},
	scripts = Latn,
}

m["mlb"] = {
	"Mbule",
	"Q35843",
	"nic-ymb",
	scripts = Latn,
}

m["mlc"] = {
	"カオ・ラン語",
	"Q3446682",
	"tai-cho",
	otherNames = {"Man Cao Lan"},
	scripts = {"Latn", "Hani"},
}

m["mle"] = {
	"マナンブ語",
	"Q11732406",
	"paa-spk",
	scripts = Latn,
}

m["mlf"] = {
	"マル語",
	"Q3281057",
	"mkh-khm",
	otherNames = {"Thin"},
}

m["mlh"] = {
	"マペ語",
	"Q6753787",
}

m["mli"] = {
	"マリンプン語",
	"Q12473435",
}

m["mlj"] = {
	"ミルトゥ語",
	"Q3441310",
}

m["mlk"] = {
	"Ilwana",
	"Q6001357",
	"bnt-sab",
}

m["mll"] = {
	"マルア・ベイ語",
	"Q6744946",
	"poz-vnc",
	scripts = Latn,
}

m["mlm"] = {
	"ムーラオ語",
	"Q3092284",
	"qfa-kms",
	scripts = Latn,
}

m["mln"] = {
	"マランゴ語",
	"Q3281522",
	"poz-sls",
	scripts = Latn,
}

m["mlo"] = {
	"Mlomp",
	"Q36009",
	"alv-bak",
}

m["mlp"] = {
	"Bargam",
	"Q4860543",
	"ngf-mad",
	otherNames = {"Mugil"},
	scripts = Latn,
}

m["mlq"] = {
	"西部マニンカカン語",
	"Q11028033",
	"dmn-wmn",
}

m["mlr"] = {
	"ヴァメ語",
	"Q3515088",
}

m["mls"] = {
	"マサリト語",
	"Q56557",
	"ssa",
}

m["mlu"] = {
	"トアバイタ語",
	"Q36645",
	"poz-sls",
	otherNames = {"Toqabaqita"},
	scripts = Latn,
}

m["mlv"] = {
	"モトラヴ語",
	"Q2475538",
	"poz-vnc",
	otherNames = {"Motlav", "Volow"}, -- or Volow could be separated as a language
	scripts = Latn,
}

m["mlw"] = {
	"モロコ語",
	"Q1965222",
	"cdc-cbm",
	scripts = Latn,
}

m["mlx"] = {
	"Malfaxal",
	"Q2157421",
	"poz-vnc",
	scripts = Latn,
}

m["mlz"] = {
	"Malaynon",
	"Q18755512",
	"phi",
}

m["mma"] = {
	"ママ語",
	"Q3913963",
	"nic-jrn",
}

m["mmb"] = {
	"Momina",
	"Q6897297",
}

m["mmc"] = {
	"ミチョアカン・マサワ語",
	"Q12953705",
	"oto",
	scripts = Latn,
}

m["mmd"] = {
	"マオナン語",
	"Q3092293",
	"qfa-kms",
}

m["mme"] = {
	"マエ語",
	"Q3276286",
	"poz-vnc",
	scripts = Latn,
}

m["mmf"] = {
	"ムンダット語",
	"Q56263",
	"cdc-wst",
	scripts = Latn,
}

m["mmg"] = {
	"北アンブリム語",
	"Q2842468",
	"poz-vnc",
	scripts = Latn,
}

m["mmh"] = {
	"メヒナク語",
	"Q3501838",
	"awd",
	scripts = Latn,
}

m["mmi"] = {
	"ムサル語",
	"Q6940113",
	"ngf-mad",
}

m["mmj"] = {
	"マジワル語",
	"Q6737795",
}

m["mmk"] = {
	"ムカー・ドーラ語",
	"Q6933447",
}

m["mml"] = {
	"Man Met",
	"Q3194984",
	"mkh-pal",
}

m["mmm"] = {
	"マイイ語",
	"Q6735599",
	"poz-vnc",
	scripts = Latn,
}

m["mmn"] = {
	"ママンワ語",
	"Q3206623",
	"phi",
	scripts = Latn,
}

m["mmo"] = {
	"マンガ・ブアン語",
	"Q12952294",
	"poz-ocw",
	scripts = Latn,
}

m["mmp"] = {
	"Musan",
	"Q2605703",
	"paa-asa",
}

m["mmq"] = {
	"ムサク語",
	"Q6940074",
	"ngf-mad",
	otherNames = {"Musak", "Mabɨŋ", "Mabing"},
	scripts = Latn,
}

m["mmr"] = {
	"西部湘西苗語",
	"Q3307901",
	"hmn",
}

m["mmt"] = {
	"Malalamai",
	"Q3281496",
	"poz-ocw",
	scripts = Latn,
}

m["mmu"] = {
	"Mmaala",
	"Q13123461",
	"nic-ymb",
	scripts = Latn,
}

m["mmv"] = {
	"ミリティ語",
	"Q6873567",
	"sai-tuc",
	scripts = Latn,
}

m["mmw"] = {
	"エマエ語",
	"Q3051961",
	"poz-pnp",
	scripts = Latn,
}

m["mmx"] = {
	"マダク語",
	"Q3275205",
	"poz-ocw",
	scripts = Latn,
}

m["mmy"] = {
	"ミガアマ語",
	"Q56259",
	"cdc-est",
	scripts = Latn,
}

m["mmz"] = {
	"マバアレ語",
	"Q11003249",
	"bnt-ngn",
}

m["mna"] = {
	"ンブラ語",
	"Q3303572",
	"poz-ocw",
	scripts = Latn,
}

m["mnb"] = {
	"ムナ語",
	"Q6935584",
	"poz-mun",
	scripts = Latn,
}

m["mnc"] = {
	"満洲語",
	"Q33638",
	"tuw-jrc",
	scripts = {"mnc-Mong", "Latn"},
	ancestors = "juc",
	translit_module = "mnc-translit",
	override_translit = true,
}

m["mnd"] = {
	"モンデ語",
	"Q6898840",
	"tup",
	otherNames = {"Monde", "Salamãi", "Salamai", "Salamaikã", "Sanamaica", "Sanamaiká", "Sanamaykã"},
	scripts = Latn,
}

m["mne"] = {
	"Naba",
	"Q760732",
	"csu-bgr",
}

m["mnf"] = {
	"ムンダニ語",
	"Q35839",
	"nic-mom",
	scripts = Latn,
}

m["mng"] = {
	"東部ムノン語",
	"Q12953747",
	"mkh-ban",
}

m["mnh"] = {
	"モノ語(コンゴ)",
	"Q33501",
	"bad-cnt",
	otherNames = {"Mono (Democratic Republic of the Congo)", "Mono"},
	scripts = Latn,
}

m["mni"] = {
	"マニプリ語",
	"Q33868",
	"sit",
	otherNames = {"Meitei", "Meithei"},
	scripts = {"Mtei", "Beng"},
	ancestors = {"omp"},
}

m["mnj"] = {
	"ムンジー語",
	"Q33639",
	"ira-mny",
	otherNames = {"Munjani", "Mundzhan", "Mundzhani", "Mundzi"},
	ancestors = {"ira-mny-pro"},
}

m["mnk"] = {
	"マンディンカ語",
	"Q33678",
	"dmn-wmn",
	otherNames = {"Mandingo"},
	scripts = Latn,
}

m["mnl"] = {
	"Tiale",
	"Q6744350",
	"poz-vnc",
	scripts = Latn,
}

m["mnm"] = {
	"マペナ語",
	"Q11732415",
}

m["mnn"] = {
	"南部ムノン語",
	"Q23857582",
}

m["mnp"] = {
	"閩北語",
	"Q36457",
	"zhx-min-shn",
	scripts = {"Hani"},
}

m["mnq"] = {
	"Minriq",
	"Q2742268",
	"mkh-asl",
}

m["mnr"] = {
	"モノ語(カリフォルニア)",
	"Q33591",
	"azc-num",
	otherNames = {"Mono (United States of America)", "Mono", "Western Mono", "Monache", "Monachi", "Owens Valley Paiute", "Eastern Mono"},
	scripts = Latn,
}

m["mns"] = {
	"マンシ語",
	"Q33759",
	"urj-ugr",
	scripts = Cyrl,
   	translit_module = "mns-translit",
	override_translit = true,
}

m["mnt"] = {
	"Maykulan",
	"Q3915696",
	"aus-pam",
	otherNames = {"Mayi-Kulan", "Wunumara", "Mayi-Yapi", "Mayi-Thakurti"},
	scripts = Latn,
}

m["mnu"] = {
	"Mer",
	"Q6817854",
}

m["mnv"] = {
	"レンネル語",
	"Q3397346",
	"poz-pnp",
	otherNames = {"Rennell-Bellona"},
	scripts = Latn,
}

m["mnw"] = {
	"モン語",
	"Q13349",
	"mkh-mnc",
	otherNames = {"Peguan", "Raman"},
	scripts = {"Mymr"},
	ancestors = {"mkh-mmn"},
	translit_module = "mnw-translit",
	sort_key = {
		from = {"ျ", "ြ", "ွ", "ှ", "ၞ", "ၟ", "ၠ", "ဩ", "ဿ", "ဨ", "ဉ"},
		to = {"္ယ", "္ရ", "္ဝ", "္ဟ", "္န", "္မ", "္လ", "သ", "သ္သ", "အ", "ဥ"}},
}

m["mnx"] = {
	"マンティオン語",
	"Q3507964",
	"paa-wpa",
	otherNames = {"マニキオン語", "Manikion", "Mantion", "Sougb", "Sogh"},
}

m["mny"] = {
	"Manyawa",
	"Q11002622",
	"bnt-mak",
	ancestors = {"vmw"},
}

m["mnz"] = {
	"モニ語",
	"Q6899857",
}

m["moa"] = {
	"Mwan",
	"Q3320111",
	"dmn-nbe",
	scripts = Latn,
}

m["moc"] = {
	"Mocoví",
	"Q3027906",
	"sai-guc",
	otherNames = {"Mbocobí", "Mokoví", "Moqoyt"},
	scripts = Latn,
}

m["mod"] = {
	"Mobilian",
	"Q13333",
	"crp",
	scripts = Latn,
	ancestors = {"cho", "cic"},
}

m["moe"] = {
	"モンターネ語",
	"Q13351",
	"alg",
	scripts = Latn,
	ancestors = {"cr"},
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["mog"] = {
	"モゴンドウ語",
	"Q3058458",
	"phi",
	scripts = Latn,
}

m["moh"] = {
	"モーホーク語",
	"Q13339",
	"iro",
	scripts = Latn,
}

m["moi"] = {
	"Mboi",
	"Q3914417",
	"alv-yun",
}

m["moj"] = {
	"Monzombo",
	"Q11154772",
	"nic-nkk",
	scripts = Latn,
}

m["mok"] = {
	"Morori",
	"Q6913275",
}

m["mom"] = {
	"Monimbo",
	"Q56542",
}

m["moo"] = {
	"Monom",
	"Q6901726",
	"mkh-ban",
	otherNames = {"Monam", "Bonam"},
}

m["mop"] = {
	"モパン語",
	"Q36183",
	"myn",
	otherNames = {"Mopan", "Mopán Maya", "Mopán"},
	scripts = Latn,
}

m["moq"] = {
	"Mor (Papuan)",
	"Q11732468",
	"paa",
	otherNames = {"Mor", "Papuan Mor"},
}

m["mor"] = {
	"Moro",
	"Q36172",
	"alv-hei",
}

m["mos"] = {
	"モシ語",
	"Q36096",
	"nic-mre",
	otherNames = {"More", "Mossi", "Moshi", "Mõõré", "Mòoré", "Mooré", "Moré", "Möré"},
	scripts = Latn,
}

m["mot"] = {
	"Barí",
	"Q2886281",
	"cba",
	otherNames = {"Bari", "Baria", "Barira", "Motilón", "Motilon", "Motilone"},
	scripts = Latn,
}

m["mou"] = {
	"Mogum",
	"Q3440473",
	"cdc-est",
	scripts = Latn,
}

m["mov"] = {
	"Mojave",
	"Q56510",
	"nai-yuc",
	scripts = Latn,
}

m["mow"] = {
	"モイ語 (コンゴ共和国)",
	"Q11124792",
	"bnt-bmo",
	otherNames = {"Moi", "Moi (Congo)"},
	scripts = Latn,
}

m["mox"] = {
	"Molima",
	"Q3319495",
	"poz-ocw",
	scripts = Latn,
}

m["moy"] = {
	"Shekkacho",
	"Q56827",
	"omv-gon",
}

m["moz"] = {
	"ムクル語",
	"Q3440403",
}

m["mpa"] = {
	"ンポト語",
	"Q6928303",
	"bnt-mbi",
}

m["mpb"] = {
	"Mullukmulluk",
	"Q6741120",
}

m["mpc"] = {
	"マンガライ語",
	"Q6748829",
}

m["mpd"] = {
	"マチネレ語",
	"Q12953681",
	"awd",
	scripts = Latn,
}

m["mpe"] = {
	"マジャン語",
	"Q56724",
	"sdv",
}

m["mpg"] = {
	"マルバ語",
	"Q56614",
	"cdc-mas",
}

m["mph"] = {
	"マウン語",
	"Q6792550",
	"aus-wdj",
	scripts = Latn,
}

m["mpi"] = {
	"ムパデ語",
	"Q3280670",
	"cdc-cbm",
	scripts = Latn,
}

m["mpj"] = {
	"Martu Wangka",
	"Q3295916",
	"aus-pam",
	otherNames = {"Yulparija", "Yulparitja"},
	scripts = Latn,
}

m["mpk"] = {
	"ムバラ語",
	"Q3912770",
	"cdc-cbm",
	otherNames = {"Mbara"},
}

m["mpl"] = {
	"ミドル・ワトゥット語",
	"Q15887910",
	"poz-ocw",
	scripts = Latn,
}

m["mpm"] = {
	"ヨソンドゥア・ミステク語",
	"Q12953741",
	"omq-mxt",
	scripts = Latn,
}

m["mpn"] = {
	"ミンディリ語",
	"Q6863842",
	"poz-ocw",
	scripts = Latn,
}

m["mpo"] = {
	"Miu",
	"Q6883668",
	"poz-ocw",
	scripts = Latn,
}

m["mpp"] = {
	"ミガバチ語",
	"Q11732448",
}

m["mpq"] = {
	"Matís",
	"Q3299145",
	"sai-pan",
	scripts = Latn,
}

m["mpr"] = {
	"ヴァングヌ語",
	"Q3554582",
	"poz-ocw",
	scripts = Latn,
}

m["mps"] = {
	"ダディビ語",
	"Q5208077",
	"ngf",
	otherNames = {"Daribi", "Karimui"},
	scripts = Latn,
}

m["mpt"] = {
	"ミアン語",
	"Q12952846",
	"ngf-okk",
	scripts = Latn,
}

m["mpu"] = {
	"マクラップ語",
	"Q3281037",
	"tup",
	otherNames = {"Macurapi", "Makurápi", "Massaka"},
	scripts = Latn,
}

m["mpv"] = {
	"ムンキプ語",
	"Q11732485",
	"ngf-fin",
	scripts = Latn,
}

m["mpw"] = {
	"マピディアン語",
	"Q6753812",
	"awd",
	scripts = Latn,
}

m["mpx"] = {
	"Misima-Paneati",
	"Q6875666",
	"poz-ocw",
	scripts = Latn,
}

m["mpy"] = {
	"マピア語",
	"Q3287224",
	"poz-mic",
	scripts = Latn,
}

m["mpz"] = {
	"ムピ語",
	"Q6928276",
	"tbq-lol",
}

m["mqa"] = {
	"マバ語",
	"Q3273750",
}

m["mqb"] = {
	"ムブコ語",
	"Q3502213",
	"cdc-cbm",
	scripts = Latn,
}

m["mqc"] = {
	"マンゴレ語",
	"Q6749097",
	"poz-cma",
	scripts = Latn,
}

m["mqe"] = {
	"マテピ語",
	"Q11732426",
	"ngf-mad",
}

m["mqf"] = {
	"Momuna",
	"Q6897518",
}

m["mqg"] = {
	"コタ・バングン・クタイ・マレー語",
	"Q12952778",
}

m["mqh"] = {
	"トラソヤルテペク・ミステク語",
	"Q12953740",
	"omq-mxt",
	scripts = Latn,
}

m["mqi"] = {
	"Mariri",
	"Q6765544",
}

m["mqj"] = {
	"ママサ語",
	"Q6745452",
	"poz-ssw",
	scripts = Latn,
}

m["mqk"] = {
	"ラジャ・カブンスワン・マノボ語",
	"Q12953700",
	"mno",
}

m["mql"] = {
	"Mbelime",
	"Q4286473",
	"nic-eov",
}

m["mqm"] = {
	"南部マルケサス語",
	"Q19694214",
	"poz-pep",
	scripts = Latn,
}

m["mqn"] = {
	"モロネネ語",
	"Q642581",
	"poz-btk",
	scripts = Latn,
}

m["mqo"] = {
	"モドレ語",
	"Q11732457",
	"paa-wpa",
}

m["mqp"] = {
	"Manipa",
	"Q6749799",
	"poz-cma",
	scripts = Latn,
}

m["mqq"] = {
	"ミノコ語",
	"Q18642293",
}

m["mqr"] = {
	"マンデル語",
	"Q6747979",
	"paa-tkw",
}

m["mqs"] = {
	"西マキアン語",
	"Q3033575",
	"paa-wpa",
}

m["mqt"] = {
	"Mok",
	"Q13018559",
	"mkh-pal",
}

m["mqu"] = {
	"モンダリ語",
	"Q3285426",
	"sdv-bri",
}

m["mqv"] = {
	"モシモ語",
	"Q11732478",
	"ngf-mad",
	scripts = Latn,
}

m["mqw"] = {
	"モシモ語",
	"Q11732486",
	"ngf-mad",
	scripts = Latn,
}

m["mqx"] = {
	"マムジュ語",
	"Q6746004",
	"poz-ssw",
	scripts = Latn,
}

m["mqy"] = {
	"マンガライ語",
	"Q3285748",
	"poz-cet",
	scripts = Latn,
}

m["mqz"] = {
	"Malasanga",
	"Q14916889",
	"poz-ocw",
	otherNames = {"Pano"},
	scripts = Latn,
}

m["mra"] = {
	"ムラブリ語",
	"Q3073465",
	"mkh",
}

m["mrb"] = {
	"マリノ語",
	"Q3293299",
}

m["mrc"] = {
	"マリコパ語",
	"Q56386",
	"nai-yuc",
	scripts = Latn,
}

m["mrd"] = {
	"西部マガル語",
	"Q22303263",
	"sit-gma",
}

m["mre"] = {
	"マーサズ・ビニヤード手話",
	"Q33494",
	"sgn",
	scripts = {"Latn", "Sgnw"},
}

m["mrf"] = {
	"Elseng",
	"Q3915667",
	"paa-brd",
}

m["mrg"] = {
	"ミシン語",
	"Q3316328",
	"sit-tan",
	otherNames = {"Mishing", "Plains Miri", "Takam", "Hill Miri", "Sarak"},
	scripts = {"Latn", "Beng", "Deva"},
	ancestors = {"adi"},
}

m["mrh"] = {
	"マラ・チン語",
	"Q4175893",
	"tbq-kuk",
	otherNames = {"Chin Mara", "Lakher", "Mara", "Maram", "Mira", "Zao"},
	scripts = Latn,
}

m["mrj"] = {
	"西マリ語",
	"Q1776032",
	"urj",
	otherNames = {"Hill Mari", "Mountain Mari", "Highland Mari"},
	scripts = Cyrl,
	ancestors = {"chm"},
	translit_module = "chm-translit",
}

m["mrk"] = {
	"フムアヴェケ語",
	"Q5873712",
	"poz-cln",
	scripts = Latn,
}

m["mrl"] = {
	"モートロック語",
	"Q3324598",
	"poz-mic",
	scripts = Latn,
}

m["mrm"] = {
	"メルラヴ語",
	"Q3331115",
	"poz-vnc",
	scripts = Latn,
}

m["mrn"] = {
	"チェケ・ホロ語",
	"Q2962165",
	"poz-ocw",
	otherNames = {"Maringe"},
	scripts = Latn,
}

m["mro"] = {
	"カルビ語",
	"Q1951521",
	"sit-mru",
	scripts = {"Latn", "Mroo"},
}

m["mrp"] = {
	"モロウアス語",
	"Q6913299",
	"poz-vnc",
	scripts = Latn,
}

m["mrq"] = {
	"北部マルケサス語",
	"Q2603808",
	"poz-pep",
	scripts = Latn,
}

m["mrr"] = {
	"マリア語",
	"Q27602",
	"dra",
	otherNames = {"Garhchiroli Maria", "Madia", "Madiya", "Maria (India)", "Maria"}, -- the last four are also names of mrr's sibling lect, daq
	ancestors = {"gon"},
}

m["mrs"] = {
	"Maragus",
	"Q6754640",
	"poz-vnc",
	scripts = Latn,
}

m["mrt"] = {
	"中央マルギ語",
	"Q56241",
	"cdc-cbm",
	otherNames = {"Marghi Central", "Marghi"},
	scripts = Latn,
}

m["mru"] = {
	"モノ語（カメルーン）",
	"Q11031964",
	"alv-mbm",
	otherNames = {"Mono"},
	scripts = Latn,
}

m["mrv"] = {
	"マンガレヴァ語",
	"Q36237",
	"poz-pep",
	scripts = Latn,
}

m["mrw"] = {
	"マラナオ語",
	"Q33800",
	"phi",
	scripts = {"Latn", "Arab"},
}

m["mrx"] = {
	"マレムギ語",
	"Q5278044",
	"paa-tkw",
}

m["mry"] = {
	"マンダヤ語",
	"Q6747925",
	"phi",
}

m["mrz"] = {
	"マリンド語",
	"Q6763970",
}

m["msb"] = {
	"マスバテニョ語",
	"Q33948",
	"phi",
	otherNames = {"Masbateño", "Masbateno", "Minasbate"},
	scripts = Latn,
}

m["msc"] = {
	"Sankaran Maninka",
	"Q11155812",
	"dmn-mnk",
}

m["msd"] = {
	"ユカテク・マヤ手話",
	"Q34281",
	"sgn",
	scripts = Latn, -- when documented
}

m["mse"] = {
	"ムセイ語",
	"Q56328",
	"cdc-mas",
}

m["msf"] = {
	"メクウェイ語",
	"Q4544752",
	"paa-nim",
	otherNames = {"Mekwei (New Guinea)", "Menggwei"},
	scripts = Latn,
}

m["msg"] = {
	"モライド語",
	"Q6909020",
}

m["msi"] = {
	"サバ・マレー語",
	"Q10867404",
	"crp",
}

m["msj"] = {
	"マ語",
	"Q6720909",
	"nic-mbc",
	otherNames = {"Madi"},
	scripts = Latn,
}

m["msk"] = {
	"マンサカ語",
	"Q12952800",
	"phi",
	scripts = Latn,
}

m["msl"] = {
	"モロフ語",
	"Q4300950",
}

m["msm"] = {
	"アグサン・マノボ語",
	"Q12953696",
	"mno",
}

m["msn"] = {
	"ヴレス語",
	"Q3563857",
	"poz-vnc",
	scripts = Latn,
}

m["mso"] = {
	"モンブム語",
	"Q6897079",
}

m["msp"] = {
	"Maritsauá",
	"Q6765915",
	"tup",
	otherNames = {"Manitsawá", "Mantizula"},
	scripts = Latn,
}

m["msq"] = {
	"チャーチ語",
	"Q2932212",
	"poz-cln",
	scripts = Latn,
}

m["msr"] = {
	"モンゴル手話",
	"Q3915499",
	"sgn",
}

m["mss"] = {
	"西マセラ語",
	"Q12952816",
	"poz-tim",
}

m["msu"] = {
	"ムソム語",
	"Q6943041",
	"poz-ocw",
	scripts = Latn,
}

m["msv"] = {
	"マスラム語",
	"Q3502273",
}

m["msw"] = {
	"マンソアンカ語",
	"Q35814",
}

m["msx"] = {
	"モレサダ語",
	"Q11732475",
}

m["msy"] = {
	"Aruamu",
	"Q3501809",
	"paa",
	scripts = Latn,
}

m["msz"] = {
	"モマレ語",
	"Q6897030",
}

m["mta"] = {
	"コタバト・マノボ語",
	"Q12953698",
	"mno",
}

m["mtb"] = {
	"Anyin Morofo",
	"Q3502338",
	"alv-ctn",
	ancestors = {"any"},
	scripts = Latn,
}

m["mtc"] = {
	"ムニト語",
	"Q11732482",
	"ngf-mad",
}

m["mtd"] = {
	"ムアラン語",
	"Q3073458",
	"poz-mly",
}

m["mte"] = {
	"モノ語",
	"Q33503",
	"poz-ocw",
	otherNames = {"Mono", "Mono-Alu"},
	scripts = Latn,
}

m["mtf"] = {
	"ムリック語",
	"Q7050035",
	"paa-lsp",
	otherNames = {"Murik (Papua New Guinea)", "Murik", "Sepik Murik"},
	scripts = Latn,
}

m["mtg"] = {
	"Una",
	"Q5580728",
}

m["mth"] = {
	"Munggui",
	"Q6936018",
	"poz-hce",
	scripts = Latn,
}

m["mti"] = {
	"マイワ語",
	"Q6737223",
	"ngf",
	otherNames = {"Maiwa (Papua New Guinea)", "Maiwa"},
	scripts = Latn,
}

m["mtj"] = {
	"メニンゴ語",
	"Q11288953",
	otherNames = {"Moskona", "Meninggo"},
}

m["mtk"] = {
	"ンベ語'",
	"Q10964025",
	"nic-nka",
	scripts = Latn,
}

m["mtl"] = {
	"モントル語",
	"Q3440457",
	"cdc-wst",
	scripts = Latn,
}

m["mtm"] = {
	"マトル語",
	"Q20669419",
	"syd",
	otherNames = {"Taygi", "Karagas", "Mator-Taygi-Karagas"},
	scripts = Cyrl,
}

m["mtn"] = {
	"マタガルパ語",
	"Q3490756",
	"nai-min",
}

m["mto"] = {
	"トトンテペック・ミヘ語",
	"Q7828400",
	"nai-miz",
}

m["mtp"] = {
	"Wichí Lhamtés Nocten",
	"Q5908756",
	"sai-wic",
	scripts = Latn,
}

m["mtq"] = {
	"ムオン語",
	"Q3236789",
	"mkh-vie",
	scripts = Latn,
	sort_key = "vi-sortkey",
}

m["mtr"] = {
	"メワール語",
	nil,
	"inc-wes",
	scripts = {"Deva"},
	ancestors = {"raj"},
	translit_module = "hi-translit", -- for now
}

m["mts"] = {
	"Yora",
	"Q3572572",
	"sai-pan",
	scripts = Latn,
}

m["mtt"] = {
	"モタ語",
	"Q3325052",
	"poz-vnc",
	scripts = Latn,
}

m["mtu"] = {
	"トゥトゥテペク・ミステク語",
	"Q7857069",
	"omq-mxt",
	scripts = Latn,
}

m["mtv"] = {
	"Asaro'o",
	"Q3503684",
	"ngf-fin",
	otherNames = {"Molet", "Molet Kasu", "Molet Mur"}, -- or Molet could be a sep. lang.
	scripts = Latn,
}

m["mtw"] = {
	"Magahat",
	"Q6729600",
}

m["mtx"] = {
	"Tidaá Mixtec",
	"Q7800805",
	"omq-mxt",
	scripts = Latn,
}

m["mty"] = {
	"ナビ語",
	"Q6956858",
	"qfa-tor",
	scripts = Latn,
}

m["mua"] = {
	"ムンダン語",
	"Q36032",
	"alv-mbm",
}

m["mub"] = {
	"ムビ語",
	"Q3440518",
	"cdc-est",
	scripts = Latn,
}

m["muc"] = {
	"Mbu'",
	"Q35868",
	"nic-beb",
	scripts = Latn,
}

m["mud"] = {
	"野島アリュート語",
	"Q1977419",
}

m["mue"] = {
	"Media Lengua",
	"Q36066",
	"crp",
	ancestors = {"es", "qu"},
	scripts = Latn,
}

m["mug"] = {
	"ムスグム語",
	otherNames = {"Musgu", "Musgum"},
	"Q3123545",
	"cdc-cbm",
	scripts = Latn,
}

m["muh"] = {
	"ムンドゥ語",
	"Q35981",
	"nic-nke",
	otherNames = {"Mundu"},
	scripts = Latn,
}

m["mui"] = {
	"ムシ語",
	"Q615660",
	"poz-mly",
	otherNames = {"Palembang Malay", "Basa Pelembang Sari-sari", "Sekayu"},
	scripts = Latn,
}

m["muj"] = {
	"マビレ語",
	"Q3440437",
}

m["mul"] = {
	"多言語",
	"Q20923490",
	"qfa-not",
	scripts = {"None", "Latn", "Bopo", "Brai", "Cyrl", "Hani", "Hans", "Hant", "IPAchar", "musical", "Ruminumerals", "Zsym", "Zmth"},
	wikipedia_article = "Translingualism",
}

m["mum"] = {
	"Maiwala",
	"Q12952764",
	"poz-ocw",
	scripts = Latn,
}

m["muo"] = {
	"Nyong",
	"Q36373",
	"alv-lek",
}

m["mup"] = {
	"マールヴィー語",
	"Q33413",
	"inc-wes",
	ancestors = {"raj"},
}

m["muq"] = {
	"東部湘西苗語",
	"Q27431376",
	"hmn",
}

m["mur"] = {
	"ムルレ語",
	"Q56727",
	"sdv",
}

m["mus"] = {
	"クリーク語",
	"Q523014",
	"nai-mus",
	otherNames = {"Muscogee"},
	scripts = Latn,
}

m["mut"] = {
	"西部ムリア語",
	"Q12952886",
	"dra",
	ancestors = {"gon"},
}

m["muu"] = {
	"ヤーク語",
	"Q34222",
	"cus",
}

m["muv"] = {
	"ムトゥヴァン語",
	"Q3327420",
	"dra",
}

m["mux"] = {
	"Bo-Ung",
	"Q15831607",
}

m["muy"] = {
	"ムヤン語",
	"Q3502301",
	"cdc-cbm",
	scripts = Latn,
}

m["muz"] = {
	"ムルシ語",
	"Q36013",
	"sdv",
}

m["mva"] = {
	"マナム語",
	"Q6746851",
	"poz-ocw",
	scripts = Latn,
}

m["mvb"] = {
	"マトール語",
	"Q20824",
	"ath-pco",
	scripts = Latn,
}

m["mvd"] = {
	"マンボル語",
	"Q578815",
	"poz",
}

m["mvg"] = {
	"ユクアニェ・ミステク語",
	"Q25562736",
	"omq-mxt",
	scripts = Latn,
}

m["mvh"] = {
	"ムルギ語",
	"Q3441359",
}

m["mvi"] = {
	"宮古語",
	"Q36218",
	"jpx-ryu",
	scripts = {"Jpan"},
}

m["mvk"] = {
	"メクメク語",
	"Q6810592",
	"paa-yua",
}

m["mvl"] = {
	"ムバラ語（オーストラリア）",
	"Q6799620",
	"aus-pam",
	otherNames = {"Mbara", "Midjamba"},
}

m["mvm"] = {
	"ムーヤー語",
	"Q2422759",
	"sit-qia",
}

m["mvn"] = {
	"Minaveha",
	"Q6863278",
	"poz-ocw",
	scripts = Latn,
}

m["mvo"] = {
	"マロヴォ語",
	"Q3294683",
	"poz-ocw",
	scripts = Latn,
}

m["mvp"] = {
	"ドゥリ語",
	"Q3915414",
	"poz-ssw",
}

m["mvq"] = {
	"モエレ語",
	"Q11732458",
	"ngf-mad",
}

m["mvr"] = {
	"マラウ語",
	"Q6755069",
	"poz-hce",
	scripts = Latn,
}

m["mvs"] = {
	"マッセプ語",
	"Q3502895",
	"paa-tkw",
}

m["mvt"] = {
	"Mpotovoro",
	"Q6928305",
	"poz-vnc",
	scripts = Latn,
}

m["mvu"] = {
	"マルバ語",
	"Q713633",
}

m["mvv"] = {
	"タガル・ムルット語",
	"Q7675300",
	"poz-san",
	scripts = Latn,
}

m["mvw"] = {
	"マチンガ語",
	"Q12952754",
	"bnt-rvm",
}

m["mvx"] = {
	"Meoswar",
	"Q6817777",
	"poz-hce",
	scripts = Latn,
}

m["mvy"] = {
	"インダス・コーヒスターン語",
	"Q33399",
	"inc-dar",
}

m["mvz"] = {
	"マスカン語",
	"Q6821677",
	"sem-eth",
}

m["mwa"] = {
	"Mwatebu",
	"Q14916896",
	"poz-ocw",
	scripts = Latn,
}

m["mwb"] = {
	"Juwal",
	"Q6319103",
	"qfa-tor",
	scripts = Latn,
}

m["mwc"] = {
	"Are",
	"Q29277",
	"poz-ocw",
	scripts = Latn,
}

m["mwe"] = {
	"ムウェラ語",
	"Q6944725",
	"bnt-rvm",
	otherNames = {"Chimwera", "Cimwera", "Mwela"},
	scripts = Latn,
}

m["mwf"] = {
	"ムリンパタ語",
	"Q2980398",
	"aus-dal",
	scripts = Latn,
}

m["mwg"] = {
	"Aiklep",
	"Q3399652",
	"poz-ocw",
	scripts = Latn,
}

m["mwh"] = {
	"Mouk-Aria",
	"Q3325498",
	"poz-ocw",
	scripts = Latn,
}

m["mwi"] = {
	"ラボ語",
	"Q2157452",
	"poz-vnc",
	scripts = Latn,
}

m["mwk"] = {
	"Kita Maninkakan",
	"Q3015523",
	"dmn-wmn",
}

m["mwl"] = {
	"ミランダ語",
	"Q13330",
	"roa-ibe",
	scripts = Latn,
	ancestors = {"roa-ole"},
}

m["mwm"] = {
	"Sar",
	"Q56850",
	"csu-sar",
}

m["mwn"] = {
	"ニャムワンガ語",
	"Q6944666",
	"bnt-mwi",
}

m["mwo"] = {
	"中央マエウォ語",
	"Q3276435",
}

m["mwp"] = {
	"西中部トレス海峡語",
	"Q2591262",
	"aus-pam",
	scripts = Latn,
}

m["mwq"] = {
	"ムン・チン語",
	"Q331340",
	"tbq-kuk",
	otherNames = {"Mün", "Müün Chin"},
}

m["mwr"] = {
	"Marwari",
	"Q56312",
	"inc-wes",
	otherNames = {"Merwari", "Dhundari", "Shekhawati", "Harauti", "Goaria", "Gurgula"},
	scripts = {"Deva", "Mahj"},
	ancestors = {"raj"},
	translit_module = "hi-translit", -- for now
}

m["mws"] = {
	"ムウィンビ＝ムザンビ語",
	"Q15632357",
	"bnt-kka",
	scripts = Latn,
}

m["mwt"] = {
	"モーケン語",
	"Q18648701",
	"poz",
}

m["mwu"] = {
	"Mittu",
	"Q6883573",
	"csu-bbk",
	scripts = Latn,
}

m["mwv"] = {
	"メンタワイ語",
	"Q13365",
	"poz-nws",
	scripts = Latn,
}

m["mww"] = {
	"白苗語",
	"Q3138829",
	"hmn",
	otherNames = {"Hmong Daw", "Hmoob Dawb"},
	scripts = {"Latn", "Hmng"},
}

m["mwz"] = {
	"Moingi",
	"Q11011905",
}

m["mxa"] = {
	"北西オアハカ・ミステク語",
	"Q12953739",
	"omq-mxt",
	scripts = Latn,
}

m["mxb"] = {
	"テソアトラン・ミステク語",
	"Q3317286",
	"omq-mxt",
	scripts = Latn,
}

m["mxd"] = {
	"モダン語",
	"Q6888037",
	"poz",
}

m["mxe"] = {
	"メレ＝フィラ語",
	"Q3305008",
	"poz-pnp",
	scripts = Latn,
}

m["mxf"] = {
	"マルグベ語",
	"Q3502224",
}

m["mxg"] = {
	"Mbangala",
	"Q6799612",
	"bnt-yak",
}

m["mxh"] = {
	"ムブバ語",
	"Q6944591",
	"csu-mle",
	scripts = Latn,
}

m["mxi"] = {
	"モサラベ語",
	"Q317044",
	"roa-ibe",
	scripts = {"Arab", "Hebr", "Latn"},
}

m["mxj"] = {
	"ミジュー＝ミシュミ語",
	"Q56332",
	"sit-mdz",
	otherNames = {"Miju Mishmi", "Miju-Mishmi", "Geman Deng", "Geman", "Kaman", "Kman", "Midzu"},
	scripts = {"Latn", "Deva"},
}

m["mxk"] = {
	"モヌンボ語",
	"Q6906792",
	"qfa-tor",
}

m["mxl"] = {
	"Maxi Gbe",
	"Q35770",
	"alv-gbe",
}

m["mxm"] = {
	"メラメラ語",
	"Q6817936",
	"poz-ocw",
	scripts = Latn,
}

m["mxn"] = {
	"モイ語 (インドネシア)",
	"Q11732459",
	"paa",
	otherNames = {"Moi", "Mekwei"},
}

m["mxo"] = {
	"ンボウェ語",
	"Q10962309",
	"bnt-kav",
}

m["mxp"] = {
	"トラウィトルテペク・ミヘ語",
	"Q7810697",
}

m["mxq"] = {
	"フキラ・ミヘ語",
	"Q25559721",
}

m["mxr"] = {
	"ムリク語（マレーシア）",
	"Q3328150",
	otherNames = {"Murik", "Kayan Murik"},
	scripts = Latn,
}

m["mxs"] = {
	"ウイテペク・ミステク語",
	"Q12953729",
	"omq-mxt",
	scripts = Latn,
}

m["mxt"] = {
	"ハミルテペック・ミステク語",
	"Q12953730",
	"omq-mxt",
	scripts = Latn,
}

m["mxu"] = {
	"マダ語（カメルーン）",
	"Q3441206",
	"cdc-cbm",
	otherNames = {"Mada"},
	scripts = Latn,
}

m["mxv"] = {
	"メトラトノック・ミステク語",
	"Q36363",
	"omq-mxt",
	scripts = Latn,
}

m["mxw"] = {
	"Namo",
	"Q12952923",
}

m["mxx"] = {
	"Mahou",
	"Q11004334",
	"dmn-mnk",
	otherNames = {"Mawukakan", "Mahu", "Maou", "Mau", "Mawu"},
}

m["mxy"] = {
	"南東部ノチシュトラン・ミステク語",
	"Q7070684",
	"omq-mxt",
	scripts = Latn,
}

m["mxz"] = {
	"中央マセラ語",
	"Q42575433",
	"poz-tim",
}

m["myb"] = {
	"Mbay",
	"Q3033565",
	"csu-sar",
}

m["myc"] = {
	"マイェカ語",
	"Q11129517",
	"bnt-boa",
}

m["mye"] = {
	"ミエネ語",
	"Q35832",
	"bnt-tso",
}

m["myf"] = {
	"バンバシ語",
	"Q56540",
	"omv-mao",
}

m["myg"] = {
	"Manta",
	"Q35799",
	"nic-mom",
	scripts = Latn,
}

m["myh"] = {
	"マカー語",
	"Q3280640",
	"wak",
	scripts = Latn,
}

m["myj"] = {
	"Mangayat",
	"Q35988",
	"nic-ser",
}

m["myk"] = {
	"ママラ・セヌフォ語",
	"Q36187",
	"alv-sma",
}

m["myl"] = {
	"Moma",
	"Q6897018",
	"poz",
}

m["mym"] = {
	"メ・エン語",
	"Q3408516",
	"sdv",
}

m["myo"] = {
	"アンフィロ語",
	"Q34928",
	"omv-gon",
}

m["myp"] = {
	"ピダハン語",
	otherNames = {"ピラハー語", "Pirahã"},
	"Q33825",
	"sai-mur",
	scripts = Latn,
}

m["myr"] = {
	"ムニチェ語",
	"Q3915654",
}

m["mys"] = {
	"メスメス語",
	"Q3508617",
	"sem-eth",
}

m["myu"] = {
	"Mundurukú",
	"Q746723",
	"tup",
	scripts = Latn,
}

m["myv"] = {
	"エルジャ語",
	"Q29952",
	"urj-mdv",
	otherNames = {"Mordvin"},
	scripts = Cyrl,
	translit_module = "myv-translit",
	override_translit = true,
}

m["myw"] = {
	"ムユウ語",
	"Q3502878",
	"poz-ocw",
	scripts = Latn,
}

m["myx"] = {
	"Masaba",
	"Q12952814",
	"bnt-msl",
	otherNames = {"Masaaba"},
	scripts = Latn,
}

m["myy"] = {
	"マクナ語",
	"Q3275059",
	"sai-tuc",
	otherNames = {"Buhagana", "Bujagana", "Wahana"},
	scripts = Latn,
}

m["myz"] = {
	"古典マンダ語",
	"Q25559314",
	"sem-ase",
	scripts = {"Mand"},
}

m["mza"] = {
	"サンタ・マリア・サカテペク・ミステク語",
	"Q8063756",
	"omq-mxt",
	scripts = Latn,
}

m["mzb"] = {
	"ムザブ語",
	"Q36149",
	"ber",
	otherNames = {"Mozabite", "Tumẓabt"},
}

m["mzc"] = {
	"マダガスカル手話",
	"Q12715020",
	"sgn",
}

m["mzd"] = {
	"Malimba",
	"Q35806",
	"bnt-saw",
}

m["mze"] = {
	"モラワ語",
	"Q6909384",
}

m["mzg"] = {
	"修道院手話",
	"Q3217333",
	"sgn",
}

m["mzh"] = {
	"Wichí Lhamtés Güisnay",
	"Q7998197",
	"sai-wic",
	scripts = Latn,
}

m["mzi"] = {
	"イシュカトラン・マサテク語",
	"Q6101049",
	"omq-maz",
	scripts = Latn,
}

m["mzj"] = {
	"マニャ語",
	"Q11006832",
	"dmn-mnk",
}

m["mzk"] = {
	"ナイジェリア・マンビラ語",
	"Q11004163",
	"nic-mmb",
	scripts = Latn,
}

m["mzl"] = {
	"マサトラン・ミヘ語",
	"Q25559728",
}

m["mzm"] = {
	"ムムイェ語",
	"Q36021",
	"alv-mum",
	scripts = Latn,
}

m["mzn"] = {
	"マーザンダラーン語",
	"Q13356",
	"ira-msh",
	otherNames = {"Mazandarani", "Tabari"},
	scripts = {"mzn-Arab"},
}

m["mzo"] = {
	"Matipuhy",
	"Q6787588",
	"sai-car",
	scripts = Latn,
}

m["mzp"] = {
	"モビマ語",
	"Q1659701",
	"qfa-iso",
}

m["mzq"] = {
	"Mori Atas",
	"Q3324070",
	"poz-btk",
}

m["mzr"] = {
	"マルボ語",
	"Q3296011",
	"sai-pan",
	scripts = Latn,
}

m["mzs"] = {
	"マカオ語",
	"Q35785",
	"crp",
	scripts = Latn,
	ancestors = {"pt"},
}

m["mzt"] = {
	"ミンティル語",
	"Q6869641",
	"mkh-asl",
}

m["mzu"] = {
	"Inapang",
	"Q6013569",
	"paa",
	scripts = Latn,
}

m["mzv"] = {
	"マンザ語",
	"Q36038",
	"alv-gbf",
}

m["mzw"] = {
	"Deg",
	"Q35183",
	"nic-gnw",
	scripts = Latn,
}

m["mzx"] = {
	"マワヤナ語",
	"Q6794377",
	"awd",
}

m["mzy"] = {
	"モザンビーク手話",
	"Q6927809",
	"sgn",
}

m["mzz"] = {
	"Maiadomu",
	"Q6735234",
	"poz-ocw",
	scripts = Latn,
}

return m