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

m["oaa"] = {
	"ウィルタ語",
	"Q33928",
	"tuw",
	scripts = {"Cyrl", "Latn"},
}

m["oac"] = {
	"オロチ語",
	"Q33650",
	"tuw",
	scripts = {"Latn", "Cyrl"},
}

m["oav"] = {
	"古アヴァル語",
	nil,
	"cau-ava",
	scripts = {"Geor"},
}

m["obi"] = {
	"オビスペーニョ語",
	"Q1288385",
	"nai-chu",
	scripts = Latn,
}

m["obk"] = {
	"南部ボントク語",
	nil,
	"phi",
	otherNames = {"Southern Bontok"},
	scripts = Latn,
}

m["obl"] = {
	"Oblo",
	"Q36309",
}

m["obm"] = {
	"モアブ語",
	"Q36385",
	"sem-can",
	scripts = {"Phnx"},
	translit_module = "Phnx-translit",
}

m["obo"] = {
	"オボ・マノボ語",
	"Q12953699",
	"mno",
	otherNames = {"Obo"},
	scripts = Latn,
}

m["obr"] = {
	"古ビルマ語",
	"Q17006600",
	"tbq-brm",
	scripts = {"Mymr", "Latn"}, --and also Pallava
}

m["obt"] = {
	"古ブルトン語",
	"Q3558112",
	"cel-bry",
	scripts = Latn,
}

m["obu"] = {
	"オブロム語",
	"Q3813403",
	"nic-cde",
	scripts = Latn,
}

m["oca"] = {
	"オカイナ語",
	"Q3182577",
	"sai-wit",
	scripts = Latn,
}

m["och"] = {
	"上古漢語",
	"Q35137",
	"zhx",
	scripts = {"Hani"},
}

m["oco"] = {
	"古コーンウォール語",
	"Q48304520",
	"cel-bry",
	scripts = Latn,
}

m["ocu"] = {
	"アツィンゴ・マトラツィンカ語",
	"Q10751739",
	"omq",
	otherNames = {"Ocuiltec", "Atzingo Matlatzinca"},
	scripts = Latn,
}

m["oda"] = {
	"オドゥト語",
	"Q3915388",
	"nic-uce",
	ancestors = {"mfn"},
	scripts = Latn,
}

m["odk"] = {
	"オド語",
	"Q7077191",
	"inc-wes",
	scripts = {"Arab"},
}

m["odt"] = {
	"古オランダ語",
	"Q443089",
	"gmw",
	scripts = {"Latn", "Runr"},
	ancestors = {"gmw-pro"},
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["odu"] = {
	"オドゥアル語",
	"Q3813392",
	"nic-cde",
	scripts = Latn,
}

m["ofo"] = {
	"オフォ語",
	"Q3349758",
	"sio-ohv",
}

m["ofs"] = {
	"古フリジア語",
	"Q35133",
	"gmw-fri",
	scripts = Latn,
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["ofu"] = {
	"エフトップ語",
	"Q35297",
	"nic-eko",
	scripts = Latn,
}

m["ogb"] = {
	"オグビア語",
	"Q3813400",
	"nic-cde",
	scripts = Latn,
}

m["ogc"] = {
	"オグバ語",
	"Q36291",
	"alv-igb",
	scripts = Latn,
}

m["oge"] = {
	"古グルジア語",
	"Q34834",
	"ccs-gzn",
	scripts = {"Geor"},
	translit_module = "Geor-translit",
	override_translit = true,
	entry_name = {
		from = {"̂"},
		to   = {""}} ,
}

m["ogg"] = {
	"オグボゴロ語",
	"Q3813405",
	"nic-cde",
	scripts = Latn,
}

m["ogo"] = {
	"カナ語",
	"Q3914409",
	"nic-ogo",
	scripts = Latn,
}

m["ogu"] = {
	"オグブロヌアグム語",
	"Q3914485",
	"nic-cde",
	scripts = Latn,
}

m["ohu"] = {
	"古ハンガリー語",
	nil,
	"urj-ugr",
	scripts = Latn,
}

m["oia"] = {
	"オイラタ語",
	"Q56738",
	"ngf",
	scripts = Latn,
}

m["oin"] = {
	"Inebu One",
	"Q12953782",
	"qfa-tor",
}

m["ojb"] = {
	"北西部オジブワ語",
	"Q7060356",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojc"] = {
	"中部オジブワ語",
	"Q5061548",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojg"] = {
	"東部オジブワ語",
	"Q5330342",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojp"] = {
	"古典日本語",
	"Q5736700",
	"jpx",
	scripts = {"Jpan"},
}

m["ojs"] = {
	"セヴァーン・オジブワ語",
	"Q56494",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["ojv"] = {
	"オントン・ジャヴァ語",
	"Q7095071",
	"poz-pnp",
	scripts = Latn,
}

m["ojw"] = {
	"西部オジブワ語",
	"Q3474222",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["oka"] = {
	"オカナガン語",
	"Q2984602",
	"sal",
	otherNames = {"Okanagan Salish", "Okanagan-Colville", "Colville-Okanagan"},
	scripts = Latn,
}

m["okb"] = {
	"オコボ語",
	"Q3813398",
	"nic-lcr",
	scripts = Latn,
}

m["okd"] = {
	"Okodia",
	"Q36300",
	"ijo",
	otherNames = {"Okordia", "Akita"},
}

m["oke"] = {
	"オクペ語",
	"Q268924",
	"alv-swd",
	otherNames = {"Okpe", "Okpe (Nigeria)", "Southwestern Edo"},
	scripts = Latn,
}

m["okg"] = {
	"Kok-Paponk",
	nil,
	"aus-pmn",
	scripts = Latn,
}

m["okh"] = {
	"コレシュ＝ロスタム語",
	"Q6432160",
	"xme-ttc",
	ancestors = {"xme-ttc-cen"},
}

m["oki"] = {
	"オキエク語",
	"Q56367",
	"sdv-kln",
	otherNames = {"Ogiek", "Akiek", "Akie", "Aki", "Mosiro", "Mediak", "Kisankasa"},
	scripts = Latn,
}

m["okj"] = {
	"オコ＝ジュウォイ語",
	"Q3436832",
	"qfa-adc",
	otherNames = {"Juwoi", "Juwai", "Junoi"},
}

m["okk"] = {
	"Kwamtim One",
	"Q19830649",
	"qfa-tor",
	scripts = Latn,
}

m["okl"] = {
	"古ケント手話",
	"Q7084319",
	"sgn",
}

m["okm"] = {
	"中期朝鮮語",
	"Q715339",
	"qfa-kor",
	scripts = {"Kore"},
	ancestors = {"oko"},
	entry_name = {
		from = {"[〮〯]"},
		to   = {""}},
	translit_module = "okm-translit",
}

m["okn"] = {
	"沖永良部語",
	"Q3350036",
	"jpx-ryu",
	scripts = {"Jpan"},
	otherNames = {"Okino-Erabu", "Okinoerabu"}, -- distinguish Okinawan
}

m["oko"] = {
	"古代朝鮮語",
	"Q715364",
	"qfa-kor",
	scripts = {"Kore"},
}

m["okr"] = {
	"Kirike",
	"Q11006763",
	"ijo",
}

m["oks"] = {
	"オコ＝エニ＝オサイエン語",
	"Q36302",
	"alv-von",
	scripts = Latn,
}

m["oku"] = {
	"Oku",
	"Q36289",
	"nic-rnc",
	scripts = Latn,
}

m["okv"] = {
	"オロカイヴァ語",
	otherNames = {"Orokaiva"},
	"Q7103752",
	"ngf",
	scripts = Latn,
}

m["okx"] = {
	"オクペ語",
	"Q7082547",
	"alv-nwd",
	otherNames = {"Okpe", "Okpe (Nigeria)"},
	scripts = Latn,
}

m["okz"] = {
	"古クメール語",
	"Q31745045",
	"mkh-kmr",
	otherNames = {"古代クメール語"},
	scripts = Khmr,
	ancestors = {"mkh-mkm"},
}

m["old"] = {
	"チャガ語",
	otherNames = {"Chaga", "Chagga", "Mochi"},
	"Q12952852",
	"bnt-chg",
	scripts = Latn,
}

m["ole"] = {
	"オレ語",
	"Q3695204",
	"sit-bdi",
}

m["olm"] = {
	"オロマ語",
	"Q3441166",
	"alv-nwd",
	scripts = Latn,
}

m["olo"] = {
	"オロネツ語",
	"Q36584",
	"fiu-fin",
	otherNames = {"Livvi-Karelian", "Livvikovian", "Olonets", "Southern Olonetsian"},
	scripts = Latn,
}

m["olr"] = {
	"Olrat",
	"Q3351562",
	"poz-vnc",
}

m["olt"] = {
	"古リトアニア語",
	"Q17417801",
	"bat",
	scripts = Latn,
	entry_name = {
		from = {"[áãà]", "[éẽè]", "[íĩì]", "[ýỹ]", "ñ", "[óõò]", "[úù]", ACUTE, GRAVE, TILDE},
		to   = {"a"    , "e"    , "i", "y"   , "n", "o"	   , "u"   }} ,
}

m["olu"] = {
	"Kuvale",
	"Q6448765",
	"bnt-swb",
	scripts = Latn,
}

m["oma"] = {
	"オマハ＝ポンカ語",
	"Q2917968",
	"sio-dhe",
	otherNames = {"Omaha", "Ponca"},
	scripts = Latn,
}

m["omb"] = {
	"東アンバエ語",
	"Q2841471",
	"poz-vnc",
	otherNames = {"East Ambae"},
	scripts = Latn,
}

m["omc"] = {
	"Mochica",
	"Q1951641",
}

m["omg"] = {
	"オマグア語",
	"Q33663",
	"tup-gua",
	otherNames = {"Agua", "Cambeba", "Cambeeba", "Kambeba", "Cambela", "Campeba", "Compeva", "Umaua", "Omáua", "Omaua", "Omayali"}, -- last three might actually be names of a different language
	scripts = Latn,
}

m["omi"] = {
	"Omi",
	"Q56795",
	"csu-mma",
}

m["omk"] = {
	"Omok",
	"Q4334657",
	"qfa-yuk",
	scripts = { "Cyrl" },
	translit_module = "omk-translit",
}

m["oml"] = {
	"オンボ語",
	"Q7089928",
	"bnt-tet",
	scripts = Latn,
}

m["omn"] = {
	"ミノア語",
	"Q1669994",
	scripts = {"Lina"},
}

m["omo"] = {
	"Utarmbung",
	"Q7902577",
	"ngf",
	scripts = Latn,
}

m["omp"] = {
	"古マニプリ語",
	nil,
	"sit",
}

m["omr"] = {
	"古マラーティー語",
	nil,
	"inc-sou",
	scripts = {"Deva", "Modi"},
	ancestors = {"pmh"},
	translit_module = "translit-redirect",
}

m["omt"] = {
	"オモティク語",
	"Q36313",
	"sdv-nis",
}

m["omu"] = {
	"オムラノ語",
	"Q1957612",
}

m["omw"] = {
	"南タイロラ語",
	"Q20210553",
	"paa-kag",
	scripts = Latn,
}

m["omx"] = {
	"古モン語",
	nil,
	"mkh-mnc",
	translit_module = "mnw-translit",
	scripts = {"Mymr", "Latn"}, --and also Pallava
}

m["ona"] = {
	"オナ語",
	"Q2721227",
	"sai-cho",
	otherNames = {"Ona", "Aona", "Selknam", "Shelknam"},
	scripts = Latn,
}

m["onb"] = {
	"リンガオ語",
	"Q7093790",
	"qfa-onb",
	aliases = {"Ong-Be", "Be", "Bê"},
}

m["one"] = {
	"オネイダ語",
	"Q857858",
	"iro",
	scripts = Latn,
}

m["ong"] = {
	"オロ語",
	"Q592162",
	"qfa-tor",
	scripts = Latn,
}

m["oni"] = {
	"オニン語",
	"Q7093910",
	"poz-cet",
	scripts = Latn,
}

m["onj"] = {
	"オンジョブ語",
	"Q7093968",
	"ngf",
	scripts = Latn,
}

m["onk"] = {
	"Kabore One",
	"Q12953783",
	"qfa-tor",
	scripts = Latn,
}

m["onn"] = {
	"Onobasulu",
	"Q7094437",
	"ngf",
	scripts = Latn,
}

m["ono"] = {
	"オノンダガ語",
	"Q1077450",
	"iro",
	scripts = Latn,
}

m["onp"] = {
	"Sartang",
	"Q7424639",
	"sit-khb",
}

m["onr"] = {
	"北部オネ語",
	"Q19830648",
	"qfa-tor",
	scripts = Latn,
}

m["ons"] = {
	"オノ語",
	"Q11732548",
	"ngf",
	scripts = Latn,
}

m["ont"] = {
	"Ontenu",
	"Q3352827",
}

m["onu"] = {
	"ウヌア語",
	"Q3552042",
	"poz-vnc",
	otherNames = {"Onua"},
	scripts = Latn,
}

m["onw"] = {
	"古ヌビア語",
	"Q2268",
	"nub",
	scripts = {"Copt"},
}

m["onx"] = {
	"Pidgin Onin",
	"Q12953788",
	"crp",
	scripts = Latn,
	ancestors = {"oni"},
}

m["ood"] = {
	"トホノ・オオダム語",
	"Q2393095",
	"azc",
	otherNames = {"Papago"},
	scripts = Latn,
}

m["oog"] = {
	"オン語",
	"Q12953787",
	"mkh-kat",
}

m["oon"] = {
	"オンゲ語",
	"Q2475551",
	"qfa-ong",
}

m["oor"] = {
	"Oorlams",
	"Q2484337",
}

m["oos"] = {
	"古オセット語",
	nil,
	"xsc",
	otherNames = {"Old Ossetian", "Alanic", "Sarmatian"},
	scripts = {"Grek", "Latn"},
	translit_module = "grc-translit",
	ancestors = {"os-pro"},
}

m["opa"] = {
	"オクパメリ語",
	"Q3913331",
	"alv-nwd",
	otherNames = {"Opameri", "Ibilo"},
	scripts = Latn,
}

m["opk"] = {
	"Kopkaka",
	"Q6431129",
	"ngf-okk",
	scripts = Latn,
}

m["opm"] = {
	"オクサプミン語",
	"Q1068097",
	"ngf",
	scripts = Latn,
}

m["opo"] = {
	"オパオ語",
	"Q7095585",
	"ngf",
	scripts = Latn,
}

m["opt"] = {
	"オパタ語",
	"Q2304583",
	"azc-trc",
	otherNames = {"Heve", "Hegue", "Eudeve", "Teguima"},
	scripts = Latn,
}

m["opy"] = {
	"オファイェ語",
	"Q3446691",
	"sai-mje",
	scripts = Latn,
}

m["ora"] = {
	"オロハ語",
	"Q36298",
	"poz-sls",
}

m["ore"] = {
	"オレホン語",
	"Q3355834",
	"sai-tuc",
	scripts = Latn,
}

m["org"] = {
	"オリン語",
	"Q3915308",
	"nic-ucn",
	scripts = Latn,
}

m["orh"] = {
	"オロチョン語",
	"Q1367309",
	"tuw",
	scripts = Latn,
}

m["oro"] = {
	"オロコロ語",
	otherNames = {"ヴァイララ語", "Orokolo", "Vailala"},
	"Q7103758",
	"ngf",
	scripts = Latn,
}

m["orr"] = {
	"Oruma",
	"Q36299",
	"ijo",
	scripts = Latn,
}

m["ort"] = {
	"アーディヴァーシー・オリヤー語",
	"Q12953791",
	"inc-eas",
	scripts = {"Orya"},
	ancestors = {"or"},
}

m["oru"] = {
	"オールムリー語",
	"Q33740",
	"ira-orp",
	scripts = {"fa-Arab"},
}

m["orv"] = {
	"古東スラヴ語",
	"Q35228",
	"zle",
	otherNames = {"Old Russian"},
	scripts = {"Cyrs"},
	translit_module = "Cyrs-Glag-translit",
	entry_name = {
		from = {u(0x0484)}, -- kamora
		to   = {}},
	sort_key = {
		from = {"оу", "є"},
		to   = {"у" , "е"}} ,
}

m["orw"] = {
	"オロ・ウィン語",
	"Q3450423",
	"sai-cpc",
	scripts = Latn,
}

m["orx"] = {
	"Oro",
	"Q3813396",
	"nic-lcr",
	scripts = Latn,
}

m["orz"] = {
	"オルム語",
	"Q7103494",
	"poz-ocw",
	scripts = Latn,
}

m["osa"] = {
	"オセージ語",
	"Q2600085",
	"sio-dhe",
	scripts = {"Latn", "Osge"},
}

m["osc"] = {
	"オスク語",
	"Q36653",
	"itc",
	scripts = {"Ital", "Latn"},
	translit_module = "Ital-translit",
}

m["osi"] = {
	"ウシン語",
	"Q2701322",
	"poz-sus",
	scripts = Latn,
}

m["osn"] = {
	"古スンダ語",
	56197074,
	"poz-msa",
	"Latn, Sund, Kawi",
}

m["oso"] = {
	"Ososo",
	"Q3913398",
	"alv-yek",
	scripts = Latn,
}

m["osp"] = {
	"古スペイン語",
	"Q1088025",
	"roa-ibe",
	scripts = Latn,
}

m["ost"] = {
	"Osatu",
	"Q36243",
	"nic-grs",
	scripts = Latn,
}

m["osu"] = {
	"南部オネ語",
	"Q12953785",
	"qfa-tor",
	scripts = Latn,
}

m["osx"] = {
	"古ザクセン語",
	"Q35219",
	"gmw",
	otherNames = {"Old Low German"},
	scripts = Latn,
	entry_name = {
		from = {"[ĀÂ]", "[āâ]", "[ĒÊ]", "[ēê]", "[ĪÎ]", "[īî]", "[ŌÔ]", "[ōô]", "[ŪÛ]", "[ūû]"},
		to   = {"A"   , "a"   , "E"   , "e"   , "I"   , "i"   , "O"   , "o"   , "U"   , "u"}} ,
}

m["ota"] = {
	"オスマン語",
	"Q36730",
	"trk-ogz",
	otherNames = {"Ottoman"},
	scripts = {"ota-Arab", "Armn"},
	ancestors = {"trk-oat"},
	translit = {Armn = "ota-Armn-translit"},
}

m["otd"] = {
	"ドホイ語",
	"Q3033781",
	"poz-brw",
	otherNames = {"Dohoi"},
	scripts = Latn,
}

m["ote"] = {
	"メスキタル・オトミ語",
	"Q23755711",
	"oto-otm",
	scripts = Latn,
}

m["oti"] = {
	"Oti",
	"Q3357881",
}

m["otk"] = {
	"古トルコ語",
	"Q34988",
	"trk",
	otherNames = {"Orkhon Turkic", "Orkhon"},
	scripts = {"Orkh"},
	translit_module = "Orkh-translit",
}

m["otl"] = {
	"ティラパ・オトミ語",
	"Q7802050",
	"oto-otm",
	scripts = Latn,
}

m["otm"] = {
	"東部高地オトミ語",
	"Q13581718",
	"oto-otm",
	scripts = Latn,
}

m["otn"] = {
	"テナンゴ・オトミ語",
	"Q25559589",
	"oto-otm",
	scripts = Latn,
}

m["otq"] = {
	"ケレタロ・オトミ語",
	"Q23755688",
	"oto-otm",
	scripts = Latn,
}

m["otr"] = {
	"オトロ語",
	"Q36328",
	"alv-hei",
}

m["ots"] = {
	"メヒコ州オトミ語",
	"Q7413841",
	"oto-otm",
	scripts = Latn,
}

m["ott"] = {
	"テモアヤ・オトミ語",
	"Q7698191",
	"oto-otm",
	scripts = Latn,
}

m["otu"] = {
	"オトゥケ語",
	"Q7110049",
	"sai-mje",
	scripts = Latn,
}

m["otw"] = {
	"オタワ語",
	"Q133678",
	"alg",
	ancestors = {"oj"},
	scripts = Latn,
}

m["otx"] = {
	"テスカテペク・オトミ語",
	"Q25559590",
	"oto-otm",
	scripts = Latn,
}

m["oty"] = {
	"古タミル語",
	"Q20987452",
	"dra",
	scripts = {"Brah"},
	translit_module = "Brah-translit",
}

m["otz"] = {
	"イシュテンコ・オトミ語",
	"Q6101171",
	"oto-otm",
	scripts = Latn,
}

m["oua"] = {
	"テガルグレン語",
	"Q56586",
	"ber",
	otherNames = {"Ouargli", "Wargli", "Teggargrent"},
}

m["oub"] = {
	"グリオ＝ウビ語",
	"Q3914977",
	"kro-grb",
}

m["oue"] = {
	"オウネ語",
	"Q7110521",
	"paa-sbo",
}

m["oui"] = {
	"古ウイグル語",
	nil,
	"trk-sib",
	otherNames = {"Old Uighur"},
	scripts = {"Latn", "Brah", "Mani", "Syrc"},
}

m["oum"] = {
	"オウマ語",
	"Q7110494",
	"poz-ocw",
	scripts = Latn,
}

m["ovd"] = {
	"エルヴダーレン語",
	"Q254950",
	"gmq",
	otherNames = {"Övdalian"},
	scripts = Latn,
	ancestors = {"non"},
}

m["owi"] = {
	"オウィニガ語",
	"Q56454",
	"qfa-mal",
	scripts = Latn,
}

m["owl"] = {
	"古ウェールズ語",
	"Q2266723",
	"cel-bry",
	scripts = Latn,
}

m["oyb"] = {
	"オイ語",
	"Q13593748",
	"mkh-ban",
	otherNames = {"Oi", "The"}, -- The is a dialect of Oi. No, seriously.
}

m["oyd"] = {
	"オイダ語",
	"Q7116251",
	"omv-nom",
}

m["oym"] = {
	"ワヤンピ語",
	"Q7975842",
	"tup-gua",
	otherNames = {"Guayapi", "Oiampi", "Oiampí", "Wayampi"},
	scripts = Latn,
}

m["oyy"] = {
	"Oya'oya",
	"Q7116243",
	"poz-ocw",
	scripts = Latn,
}

m["ozm"] = {
	"Koonzime",
	"Q35566",
	"bnt-ndb",
	scripts = Latn,
}

return m