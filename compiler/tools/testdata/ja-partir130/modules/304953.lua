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

-- Puncuation to be used for standardChars field
local PUNCTUATION = ' !#$%&*+,-./:;<=>?@^_`|~\'()'

local Cyrl = {"Cyrl"}
local Deva = {"Deva"}
local Latn = {"Latn"}

local m = {}

m["caa"] = {
	"チョルティ語",
	"Q35177",
	"myn",
	aliases = {"Chorti"},
	scripts = Latn,
}

m["cab"] = {
	"ガリフナ語",
	"Q35490",
	"awd-taa",
	ancestors = {"awd-taa-pro"},
	scripts = Latn,
}

m["cac"] = {
	"チュフ語",
	"Q35233",
	"myn",
	scripts = Latn,
}

m["cad"] = {
	"カドー語",
	"Q56756",
	"cdd",
	scripts = Latn,
}

m["cae"] = {
	"レハル語",
	"Q35564",
	"alv-cng",
	scripts = Latn,
}

m["caf"] = {
	"南部キャリア語",
	"Q12953426",
	"ath-nor",
	scripts = Latn,
}

m["cag"] = {
	"Nivaclé",
	"Q3182557",
	"sai-mtc",
	scripts = Latn,
}

m["cah"] = {
	"カワラノ語",
	"Q2933175",
	"sai-zap",
	scripts = Latn,
}

m["caj"] = {
	"チャネ語",
	"Q56721",
	"awd",
	scripts = Latn,
}

m["cak"] = {
	"カクチケル語",
	"Q35115",
	"myn",
	aliases = {"Cakchiquel", "Kakchiquel", "Cachiquel"},
	scripts = Latn,
}

m["cal"] = {
	"カロリン語",
	"Q28427",
	"poz-mic",
	scripts = Latn,
}

m["cam"] = {
	"チェムヒ語",
	"Q3009690",
	"poz-cln",
	scripts = Latn,
}

m["can"] = {
	"チャンブリ語",
	"Q5069707",
	"paa-lsp",
	scripts = Latn,
}

m["cao"] = {
	"チャコボ語",
	"Q2591202",
	"sai-pan",
	scripts = Latn,
}

m["cap"] = {
	"チパヤ語",
	"Q35235",
	"sai-ucp",
	scripts = Latn,
}

m["caq"] = {
	"カール・ニコバル語",
	"Q35156",
	"aav-nic",
	aliases = {"Car"},
	scripts = Latn,
}

m["car"] = {
	"カリブ語",
	"Q56611",
	"sai-car",
	otherNames = {"Carib", "Caribe", "Cariña", "Galibi", "Galibí", "Kalihna", "Kali'na", "Kalinya", "Maraworno", "Marworno"},
	scripts = Latn,
}

m["cas"] = {
	"チマネ語",
	"Q35950",
	"qfa-iso",
	otherNames = {"Chimané", "Mosetén"},
	scripts = Latn,
}

m["cav"] = {
	"カビネニャ語",
	"Q524102",
	"sai-tac",
	aliases = {"Cavinena"},
	scripts = Latn,
}

m["caw"] = {
	"Callawalla",
	"Q266417",
	"qfa-mix",
	scripts = Latn,
}

m["cax"] = {
	"Chiquitano",
	"Q1844993",
	"qfa-iso",
	scripts = Latn,
}

m["cay"] = {
	"カユガ語",
	"Q32967",
	"iro",
	scripts = Latn,
}

m["caz"] = {
	"カニチャナ語",
	"Q2936374",
	"qfa-iso",
	scripts = Latn,
}

m["cbb"] = {
	"カビヤリ語",
	"Q3450660",
	"awd-nwk",
	scripts = Latn,
}

m["cbc"] = {
	"カラパナ語",
	"Q924405",
	"sai-tuc",
	scripts = Latn,
}

m["cbd"] = {
	"カリホナ語",
	"Q3446655",
	"sai-car",
	otherNames = {"Carihona", "Karijona", "Karihona", "Jianacoto", "Jianácoto", "Hianakoto", "Hianacoto", "Hianákoto", "Guaque", "Omagua", "Umaua", "Umawa"},
	scripts = Latn,
}

m["cbg"] = {
	"チミラ語",
	"Q2963680",
	"cba",
	scripts = Latn,
}

m["cbi"] = {
	"チャチ語",
	"Q2591329",
	"sai-bar",
	aliases = {"Cha'palaa", "Chapalaa", "Cha'palaachi", "Chapalaachi", "Cayapa"},
	scripts = Latn,
}

m["cbj"] = {
	"Ede Cabe",
	"Q33112829",
	"alv-ede",
	scripts = Latn,
}

m["cbk"] = {
	"チャバカノ語",
	"Q33281",
	"crp",
	ancestors = {"es"},
	otherNames = {"Zamboanga Chavacano"},
	scripts = Latn,
}

m["cbl"] = {
	"Bualkhaw Chin",
	"Q9229830",
	"tbq-kuk",
	otherNames = {"Bualkhaw"},
	scripts = Latn,
}

m["cbn"] = {
	"ニャークル語",
	"Q116849",
	"mkh-mnc",
	aliases = {"Nyahkur"},
	scripts = {"Thai"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["cbo"] = {
	"Izora",
	"Q3915454",
	"nic-jer",
	scripts = Latn,
}

m["cbq"] = {
	"Shuba",
	nil,
	"nic-knj",
	ancestors = {"lan"},
	otherNames = {"Tsucuba", "Cuba"},
	scripts = Latn,
}

m["cbr"] = {
	"カシボ＝カカタイボ語",
	"Q5359560",
	"sai-pan",
	otherNames = {"Cashibo", "Cacataibo"},
	scripts = Latn,
}

m["cbs"] = {
	"カシナワ語",
	"Q2591230",
	"sai-pan",
	scripts = Latn,
}

m["cbt"] = {
	"チャヤウィタ語",
	"Q1526525",
	"sai-cah",
	scripts = Latn,
}

m["cbu"] = {
	"カンドシ＝シャプラ語",
	"Q642843",
	"qfa-iso",
	scripts = Latn,
}

m["cbv"] = {
	"カクア語",
	"Q3192052",
	"sai-nad",
	ancestors = {"mbr"},
	scripts = Latn,
}

m["cbw"] = {
	"Kinabalian",
	"Q6410324",
	"phi",
	scripts = Latn,
}

m["cby"] = {
	"カラバヨ語",
	"Q3441762",
	"sai-tyu",
	otherNames = {"Caraballo", "Yuri", "Aroje", "Yacumo", "Maku", "Macu", "Macusa"},
	scripts = Latn,
}

m["cca"] = {
	"カウカ語",
	"Q5054242",
	"sai-chc",
	scripts = Latn,
}

m["ccc"] = {
	"チャミクロ語",
	"Q2155119",
	"awd",
	scripts = Latn,
}

m["ccd"] = {
	"Cafundó",
	"Q3331506",
	"roa-ibe",
	scripts = Latn,
	ancestors = {"pt"},
}

m["cce"] = {
	"チョピ語",
	"Q3437616",
	"bnt-bso",
	scripts = Latn,
}

m["ccg"] = {
	"Chamba Daka",
	"Q33120805",
	"nic-dak",
	otherNames = {"Samba Daka", "Nakanyare"},
	scripts = Latn,
}

m["cch"] = {
	"Atsam",
	"Q34794",
	"nic-kne",
	scripts = Latn,
}

m["ccj"] = {
	"カサンガ語",
	"Q35542",
	"alv-nyn",
	scripts = Latn,
}

m["ccl"] = {
	"Cutchi-Swahili",
	"Q5196729",
	"crp",
	scripts = Latn,
	ancestors = {"sw"},
}

m["ccm"] = {
	"マラッカ・クレオール・マレー語",
	"Q12636092",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["cco"] = {
	"コマルテペク・チナンテク語",
	"Q2963735",
	"omq-chi",
	scripts = Latn,
}

m["ccp"] = {
	"チャクマ語",
	"Q32952",
	"inc",
	scripts = {"Cakm"},
	ancestors = {"inc-mgd"},
}

m["ccr"] = {
	"カカオペラ語",
	"Q3438338",
	"nai-min",
	scripts = Latn,
}

m["cda"] = {
	"Choni",
	"Q2964447",
	"sit-tib",
}

m["cde"] = {
	"チェンチュ語",
	"Q32981",
	"dra",
	scripts = {"Telu"},
	ancestors = {"te"},
}

m["cdf"] = {
	"チル語",
	"Q5102016",
	"tbq-kuk",
	scripts = {"Latn", "Beng"},
}

m["cdh"] = {
	"チャンベアリ語",
	"Q12953424",
	"him",
	scripts = {"Deva", "Takr"},
}

m["cdi"] = {
	"チョドリ語",
	"Q5103788",
	"inc-bhi",
	scripts = {"Gujr"},
}

m["cdj"] = {
	"チュラーヒー語",
	"Q12629039",
	"him",
}

m["cdm"] = {
	"チェパン語",
	"Q5091700",
	"sit-gma",
	scripts = Deva,
}

m["cdn"] = {
	"チャウダンシ語",
	"Q5088056",
	"sit-alm",
}

m["cdo"] = {
	"閩東語",
	"Q36455",
	"zhx-min-hai",
	aliases = {"Min Dong Chinese"},
	scripts = {"Hani"},
}

m["cdr"] = {
	"Cinda-Regi-Tiyal",
	"Q35596",
	"nic-kmk",
	scripts = Latn,
}

m["cds"] = {
	"チャド手話",
	"Q10322099",
	"sgn",
	scripts = Latn, -- when documented
}

m["cdy"] = {
	"チャドン語",
	"Q926742",
	"qfa-kms",
}

m["cdz"] = {
	"コーダー語",
	"Q6425038",
	"mun",
	scripts = {"Beng"},
}

m["cea"] = {
	"Lower Chehalis",
	"Q6693377",
	"sal",
	scripts = Latn,
}

m["ceb"] = {
	"セブアノ語",
	"Q33239",
	"phi",
	scripts = Latn,
}

m["ceg"] = {
	"Chamacoco",
	"Q3436637",
	"sai-zam",
	scripts = Latn,
}

m["cen"] = {
	"Cen",
	"Q12628777",
	"nic-plc",
	ancestors = {"izr"},
	otherNames = {"Cèn", "Chen"},
	scripts = Latn,
}

m["cet"] = {
	"Centúúm",
	"Q33608",
	"qfa-iso",
	otherNames = {"Jalaa", "Cèntûm", "Cen Tuum"},
	scripts = Latn,
}

m["cfa"] = {
	"Dijim-Bwilim",
	"Q3438350",
	"alv-wjk",
	scripts = Latn,
}

m["cfd"] = {
	"Cara",
	"Q35048",
	"nic-beo",
	scripts = Latn,
}

m["cfg"] = {
	"Como Karim",
	"Q35304",
	"nic-jkn",
	scripts = Latn,
}

m["cfm"] = {
	"Falam Chin",
	"Q56815",
	"tbq-kuk",
	aliases = {"Falam"},
	scripts = {"Beng", "Latn"},
}

m["cga"] = {
	"Changriwa",
	"Q5072105",
	"paa-yua",
	scripts = Latn,
}

m["cgc"] = {
	"Kagayanen",
	"Q6346422",
	"mno",
	scripts = Latn,
}

m["cgg"] = {
	"キガ語",
	"Q3270727",
	"bnt-nyg",
	scripts = Latn,
}

m["cgk"] = {
	"Chocangaca",
	"Q56604",
	"sit-tib",
	scripts = {"Tibt"},
	ancestors = {"xct"},
}

m["chb"] = {
	"チブチャ語",
	"Q2356431",
	"cba",
}

m["chc"] = {
	"カトーバ語",
	"Q5051602",
	"nai-cat",
	scripts = Latn,
}

m["chd"] = {
	"Highland Oaxaca Chontal",
	"Q2964457",
	"nai-tqn",
	otherNames = {"Oaxaca Chontal", "Oaxacan Chontal", "Chontal", "Tequistlatec", "Mountain Tequistlateco", "Highland Chontal", "Mountain Chontal"},
	scripts = Latn,
}

m["chf"] = {
	"チョンタル語",
	"Q35175",
	"myn",
	scripts = Latn,
}

m["chg"] = {
	"チャガタイ語",
	"Q36831",
	"trk-kar",
	scripts = {"Arab"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}
	},
}

m["chh"] = {
	"チヌーク語",
	"Q6693380",
	"nai-ckn",
	scripts = Latn,
}

m["chj"] = {
	"Ojitlán Chinantec",
	"Q5100110",
	"omq-chi",
	scripts = Latn,
}

m["chk"] = {
	"チューク語",
	"Q33161",
	"poz-mic",
	scripts = Latn,
}

m["chl"] = {
	"カフイラ語",
	"Q56438",
	"azc-cup",
	scripts = Latn,
	entry_name = {
		from = {"Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", MACRON},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["chm"] = {
	"マリ語",
	"Q973685",
	"urj",
	otherNames = {"Meadow Mari", "Lowland Mari", "Midland Mari", "Standard Mari", "Upo Mari", "Mari", "Mari (Russia)"},	
	scripts = Cyrl,
	translit_module = "chm-translit",
	override_translit = true,
	wikimedia_codes = {"mhr"},
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["chn"] = {
	"チヌーク・ジャーゴン",
	"Q35173",
	"crp",
	scripts = {"Latn", "Dupl"},
	ancestors = {"chh", "nuk"},
}

m["cho"] = {
	"チョクトウ語",
	"Q32979",
	"nai-mus",
	scripts = Latn,
}

m["chp"] = {
	"チペワイアン語",
	"Q27692",
	"ath-nor",
	otherNames = {"Dëne Sųłiné", "Dënesųłiné", "Dëne", "Dene Suline", "Denesuline", "Dene"},
	scripts = {"Latn", "Cans"},
}

m["chq"] = {
	"Quiotepec Chinantec",
	"Q5758709",
	"omq-chi",
	scripts = Latn,
}

m["chr"] = {
	"チェロキー語",
	"Q33388",
	"iro",
	scripts = {"Cher"},
	translit_module = "Cher-translit",
}

m["cht"] = {
	"チョロン語",
	"Q2591243",
	scripts = Latn,
}

m["chw"] = {
	"Chuabo",
	"Q5118412",
	"bnt-mak",
	otherNames = {"Chuwabu", "Cuwabo", "Cuwabu", "Cuabo", "Txuwabo", "Echuabo"},
	scripts = Latn,
}

m["chx"] = {
	"Chantyal",
	"Q4926344",
	"sit-tam",
	scripts = Deva,
}

m["chy"] = {
	"シャイアン語",
	"Q33265",
	"alg",
	scripts = Latn,
	sort_key = {
		from = {"[àáāȧ]", "[èéēė]", "[òóōȯ]", GRAVE, ACUTE, MACRON, DOTABOVE, "-"},
		to   = {"a", "e", "o"}},
	standardChars = "0-9'AEHKMNOPSŠTVXaehkmnopsštvxÀÁĀȦÈÉĒĖÒÓŌȮàáāȧèéēėòóōȯ" .. PUNCTUATION, --umlaut and circumflex not allowed
}

m["chz"] = {
	"Ozumacín Chinantec",
	"Q5100111",
	"omq-chi",
	scripts = Latn,
}

m["cia"] = {
	"チアチア語",
	"Q35284",
	"poz-mun",
	scripts = {"Hang", "Latn", "Arab"},
}

m["cib"] = {
	"Ci Gbe",
	"Q12952445",
	"alv-gbe",
	scripts = Latn,
}

m["cic"] = {
	"チカソー語",
	"Q33192",
	"nai-mus",
	scripts = Latn,
}

m["cid"] = {
	"チマリコ語",
	"Q1294251",
	"qfa-iso",
	scripts = Latn,
}

m["cie"] = {
	"チネニ語",
	"Q56243",
	"cdc-cbm",
	scripts = Latn,
}

m["cih"] = {
	"チナール語",
	"Q11855245",
	"inc",
	scripts = Deva,
}

m["cik"] = {
	"Chitkuli Kinnauri",
	"Q15615982",
	"sit-kin",
}

m["cim"] = {
	"キンブリ語",
	"Q37053",
	"gmw",
	varieties= {"Luserna Cimbrian", "Sette Comuni Cimbrian", "Thirteen Communities Cimbrian"}, 
	scripts = Latn,
	ancestors = {"bar"},
	entry_name = {
		from = {"à", "ì", "ù"},
		to = {"a", "i", "u"}
		},
	sort_key = {
		from = {"å", "č", "[èé]", "[òóôö]", "ü"},
		to = {"a", "c", "e", "o", "u"}
	},
}

m["cin"] = {
	"シンタラルガ語",
	"Q5121095",
	"tup",
	scripts = Latn,
}

m["cip"] = {
	"チアパネック語",
	"Q3364475",
	"omq",
	scripts = Latn,
}

m["cir"] = {
	"ティリ語",
	"Q7862281",
	"poz-cln",
	otherNames = {"Tîrî", "Ciri", "Tinrin", "Méa", "Haméa"},
	scripts = Latn,
}

m["ciw"] = {
	"チペワ語",
	"oji",
	scripts = Latn,
}
m["ciy"] = {
	"チャイマ語",
	"Q12628867",
	"sai-car",
	scripts = Latn,
}

m["cja"] = {
	"西部チャム語",
	"Q12645578",
	"cmc",
	scripts = {"Arab"}, --Western Cham script is not yet available.
}

m["cje"] = {
	"チュル語",
	"Q2967321",
	"cmc",
	scripts = Latn,
}

m["cjh"] = {
	"上チェハリス語",
	"Q2962074",
	"sal",
	scripts = Latn,
}

m["cji"] = {
	"チャマラル語",
	"Q56567",
	"cau-ava",
	scripts = Cyrl,
}

m["cjk"] = {
	"チョクウェ語",
	"Q2422065",
	"bnt-clu",
	scripts = Latn,
}

m["cjm"] = {
	"東部チャム語",
	"Q2948019",
	"cmc",
	scripts = {"Cham"},
}

m["cjn"] = {
	"チェナピアン語",
	"Q5091044",
	"paa-spk",
	scripts = Latn,
}

m["cjo"] = {
	"アシェニンカ・パホナル語",
	"Q3450481",
	"awd",
	scripts = Latn,
}

m["cjp"] = {
	"カベカル語",
	"Q27878",
	"cba",
	scripts = Latn,
}

m["cjs"] = {
	"ショル語",
	"Q34139",
	"trk-sib",
	scripts = Cyrl,
	translit_module = "cjs-translit",
}

m["cjv"] = {
	"チュアヴェ語",
	"Q5115226",
	"ngf",
	scripts = Latn,
}

m["cjy"] = {
	"晋語",
	"Q56479",
	"zhx",
	otherNames = {"Jinyu", "Jinhua", "Jinese", "Shanxinese", "Jin Chinese", "Jinyu Chinese"},
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["ckb"] = {
	"ソラニー",
	"Q36811",
	"ira-nwi",
	aliases = {"Sorani"},
	scripts = {"ku-Arab"},
	ancestors = {"ku"},
	translit_module = "ckb-translit",
	entry_name = {
		from = {u(0x0650), u(0x0652)},
		to   = {}} ,
}

m["ckh"] = {
	"チャック語",
	"Q12628870",
	"sit-luu",
	aliases = {"Sak"},
	scripts = Latn,
	ancestors = {"kdv"},
}

m["ckl"] = {
	"チバク語",
	"Q56279",
	"cdc-cbm",
	aliases = {"Chibuk", "Chibok", "Chibbak", "Chibbuk", "Kyibaku", "Kibbaku", "Kibaku"},
	scripts = Latn,
}

m["ckn"] = {
	"Kaang Chin",
	"Q6343432",
	"tbq-kuk",
	aliases = {"Kaang"},
	scripts = Latn,
}

m["cko"] = {
	"アヌフォ語",
	"Q34845",
	"alv-ctn",
	aliases = {"Chakosi"},
	scripts = Latn,
}

m["ckq"] = {
	"カジャクセ語",
	"Q3440422",
	"cdc-est",
	scripts = Latn,
}

m["ckr"] = {
	"Kairak",
	"Q3503002",
	"paa-bng",
	scripts = Latn,
}

m["cks"] = {
	"タヨ語",
	"Q1133089",
	"crp",
	ancestors = {"fr"},
	scripts = Latn,
}

m["ckt"] = {
	"チュクチ語",
	"Q33170",
	"qfa-cka",
	scripts = Cyrl,
}

m["cku"] = {
	"コアサティ語",
	"Q35162",
	"nai-mus",
	scripts = Latn,
}

m["ckv"] = {
	"クバラン語",
	"Q716627",
	"map",
	aliases = {"Kbalan", "Kebalan"},
	scripts = Latn,
}

m["ckx"] = {
	"Caka",
	"Q5018037",
	"nic-tvc",
	scripts = Latn,
}

m["cky"] = {
	"チャクフェム・ムシェレ語",
	"Q3441199",
	"cdc-wst",
	scripts = Latn,
}

m["ckz"] = {
	"カクチケル＝キチェ混交語",
	"Q5054550",
	"myn",
	otherNames = {"Cauque Mayan"},
	scripts = Latn,
}

m["cla"] = {
	"ロン語",
	"Q3440432",
	"cdc-wst",
	otherNames = {"Bokkos", "Daffo-Butura", "Shagawu"},
	scripts = Latn,
}

m["clc"] = {
	"チルコーティン語",
	"Q28535",
	"ath-nor",
	aliases = {"Tsilhqot'in", "Tsilhqut'in", "Tzilkotin"},
	scripts = Latn,
}

m["cld"] = {
	"カルデア現代アラム語",
	"Q33236",
	"sem-are",
	scripts = {"Syrc"},
}

m["cle"] = {
	"Lealao Chinantec",
	"Q6509365",
	"omq-chi",
	scripts = Latn,
}

m["clh"] = {
	"チリッソ語",
	"Q3250629",
	"inc-dar",
}

m["cli"] = {
	"チャカリ語",
	"Q35206",
	"nic-gnw",
	scripts = Latn,
}

m["clj"] = {
	"Laitu Chin",
	"Q6474196",
	"tbq-kuk",
	aliases = {"Laitu"},
}

m["clk"] = {
	"Idu",
	"Q56412",
	"sit-gsi",
	otherNames = {"Idu-Mishmi", "Idu Mishmi"},
	scripts = {"Tibt"},
}

m["cll"] = {
	"チャンラ語",
	"Q35190",
	"nic-gne",
	scripts = Latn,
}

m["clm"] = {
	"クララム語",
	"Q33404",
	"sal",
	aliases = {"Clallam", "S'Klallam"},
	scripts = Latn,
}

m["clo"] = {
	"低地オアハカ・チョンタル語",
	"Q2964450",
	"nai-tqn",
	otherNames = {"Oaxaca Chontal", "Oaxacan Chontal", "Chontal", "Huamelultec", "Huamelula Chontal", "Coastal Chontal"},
	scripts = Latn,
}

m["clt"] = {
	"Lautu Chin",
	"Q6502107",
	"tbq-kuk",
	aliases = {"Lautu"},
}

m["clu"] = {
	"Caluyanun",
	"Q32964",
	"phi",
	scripts = Latn,
}

m["clw"] = {
	"チュリム語",
	"Q33125",
	"trk-sib",
	otherNames = {"Chulim", "Chulym-Turkic", "Küerik", "Chulym Tatar", "Melets Tatar"},
	scripts = {"Latn", "Cyrl"},
}

m["cly"] = {
	"東部高地チャティーノ語",
	"Q12642078",
	"omq-cha",
	scripts = Latn,
}

m["cma"] = {
	"マー語",
	"Q12953680",
	"mkh-ban",
	scripts = Latn,
}

m["cme"] = {
	"Cerma",
	"Q35074",
	"nic-gur",
	scripts = Latn,
}

m["cmg"] = {
	"古典モンゴル語",
	"Q5128303",
	"xgn",
	scripts = {"Mong"},
	ancestors = {"xng"},
	translit_module = "mn-translit",
}

m["cmi"] = {
	"エンベラ＝チャミ語",
	"Q3052042",
	"sai-chc",
	scripts = Latn,
}

m["cml"] = {
	"Campalagian",
	"Q5027893",
	"poz-ssw",
	scripts = Latn,
}

m["cmm"] = {
	"Michigamea",
	"Q12636809",
	"sio-msv",
	scripts = Latn,
}

m["cmn"] = {
	"北京官話",
	"Q9192",
	"zhx",
	otherNames = {"Mandarin Chinese", "Putonghua", "Guoyu", "Huayu", "Guanhua", "Beifanghua", "Standard Chinese"},
	scripts = {"Hani", "Latn"},
	ancestors = {"ltc"},
	wikimedia_codes = {"zh"},
}

m["cmo"] = {
	"中部ムノン語",
	"Q33369881",
	"mkh-ban",
}

m["cmr"] = {
	"Mro Chin",
	"Q16889978",
	"tbq-kuk",
	otherNames = {"Mro-Khimi Chin", "Mro", "Mro-Khimi"},
}

m["cms"] = {
	"メッサピ語",
	"Q36383",
	"ine",
	aliases = {"Messapian"},
	scripts = Latn, -- when documented here; otherwise written in a native script
}

m["cmt"] = {
	"ツァムト語",
	"Q12628652",
	"crp",
	scripts = Latn,
	ancestors = {"fly", "zu"}
}

m["cna"] = {
	"Changthang",
	"Q12952322",
	"sit-lab",
	scripts = {"Tibt"},
}

m["cnb"] = {
	"チンボーン・チン語",
	"Q12952327",
	"tbq-kuk",
	aliases = {"Chinbon"},
}

m["cnc"] = {
	"コーン語",
	"Q5202780",
	"tbq-lol",
}

m["cng"] = {
	"北部チャン語",
	"Q56559",
	"sit-qia",
}

m["cnh"] = {
	"ハカ・チン語",
	"Q3250286",
	"tbq-kuk",
	otherNames = {"Haka Chin", "Haka"},
}

m["cni"] = {
	"アシャニンカ語",
	"Q3437230",
	"awd",
	aliases = {"Ashaninka"},
	scripts = Latn,
}

m["cnk"] = {
	"クミ語",
	"Q56308",
	"tbq-kuk",
	otherNames = {"Khumi", "Khami", "Nisay", "Nise", "Eastern Khumi", "Eastern Khumi Chin"},
}

m["cnl"] = {
	"ララナ・チナンテク語",
	"Q12953437",
	"omq-chi",
	scripts = Latn,
}

m["cno"] = {
	"Con",
	"Q3440883",
	"mkh-pal",
}

m["cnp"] = {
	"桂北平話",
	"Q84302463",
	otherNames = {"Northern Pinghua"},
	scripts = {"Hani"},
}

m["cnr"] = {
	"モンテネグロ語",
	"Q8821",
	"zls",
	scripts = {"Latn", "Cyrl"},
}

m["cns"] = {
	"中部アスマット語",
	"Q11732048",
	"ngf",
	scripts = Latn,
}

m["cnt"] = {
	"Tepetotutla Chinantec",
	"Q5100113",
	"omq-chi",
	scripts = Latn,
}

m["cnu"] = {
	"Chenoua",
	"Q33276",
	"ber",
	aliases = {"Shenwa"},
}

m["cnw"] = {
	"Ngawn Chin",
	"Q6583675",
	"tbq-kuk",
	aliases = {"Ngawn"},
}

m["cnx"] = {
	"中期コーンウォール語",
	"Q12642603",
	"cel-bry",
	scripts = Latn,
	ancestors = {"oco"},
}

m["coa"] = {
	"ココスマレー語",
	"Q3441699",
	"crp",
	aliases = {"Cocos Malay"},
	scripts = Latn,
	ancestors = {"ms"},
}

m["cob"] = {
	"チコムセルテコ語",
	"Q3307204",
	"myn",
	scripts = Latn,
}

m["coc"] = {
	"ココパ語",
	"Q33044",
	"nai-yuc",
	scripts = Latn,
}

m["cod"] = {
	"コカマ＝コカミリャ語",
	"Q33317",
	"tup",
	otherNames = {"Kokama", "Kokáma", "Cocama-Cocamilla", "Kukama-Kukamiria", "Cocamilla", "Kokamíya", "Cocaima"},
	scripts = Latn,
}

m["coe"] = {
	"Koreguaje",
	"Q3198924",
	"sai-tuc",
	scripts = Latn,
}

m["cof"] = {
	"コロラド語",
	"Q2567055",
	"sai-bar",
	otherNames = {"Colorado", "Tsáchila"},
	scripts = Latn,
}

m["cog"] = {
	"チョン語",
	"Q3914630",
	"mkh-pea",
	scripts = {"Thai", "Khmr"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["coh"] = {
	"チョニ＝ジハナ＝カウマ語",
	"Q12629011",
	"bnt-mij",
	scripts = Latn,
}

m["coj"] = {
	"コチミ語",
	"Q3915551",
	"nai-yuc",
	scripts = Latn,
}

m["cok"] = {
	"サンタ・テレサ・コラ語",
	"Q12641754",
	"azc",
	scripts = Latn,
}

m["col"] = {
	"コロンビア＝ウェナチー語",
	"Q3324744",
	"sal",
	otherNames = {"Columbia-Wenatchee", "Columbia-Moses", "Nxaamxcin", "Wenatchi", "Wenatchee"},
	scripts = Latn,
}

m["com"] = {
	"コマンチェ語",
	"Q32972",
	"azc-num",
	scripts = Latn,
}

m["con"] = {
	"コファン語",
	"Q2669254",
	"qfa-iso",
	otherNames = {"Cofan", "Kofan", "Kofane", "A'ingae", "Maku", "Macu"},
	scripts = Latn,
}

m["coo"] = {
	"コーモックス語",
	"Q13583746",
	"sal",
	scripts = Latn,
}

m["cop"] = {
	"コプト語",
	"Q36155",
	"egx",
	-- Don't include varieties in [[Module:etymology languages/data]]
	scripts = {"Copt"},
	translit_module = "Copt-translit",
	ancestors = {"egx-dem"},
	entry_name = {
		from =	{ "ˋ", GRAVE, MACRON, DIAER, },
		to =	{},
	},
	sort_key = "cop-sortkey",
}

m["coq"] = {
	"コキーユ語",
	"Q12953452",
	"ath-pco",
	scripts = Latn,
}

m["cot"] = {
	"カキンテ語",
	"Q3915557",
	"awd",
	scripts = Latn,
}

m["cou"] = {
	"Wamey",
	"Q36935",
	"alv-ten",
	scripts = Latn,
}

m["cov"] = {
	"草苗語",
	"Q2936935",
	"qfa-tak",
}

m["cow"] = {
	"コーリッツ語",
	"Q3001877",
	"sal",
	scripts = Latn,
}

m["cox"] = {
	"ナンティ語",
	"Q15342275",
	"awd",
	scripts = Latn,
}

m["coy"] = {
	"コヤイマ語",
	"Q56450",
	"sai-car",
	scripts = Latn,
}

m["coz"] = {
	"Chochotec",
	"Q2964262",
	"omq-pop",
	otherNames = {"Chocho", "Chocholtec"},
	scripts = Latn,
}

m["cpa"] = {
	"パラントラ・チナンテク語",
	"Q5100112",
	"omq-chi",
	scripts = Latn,
}

m["cpb"] = {
	"ウカヤリ＝ユルア・アシェニンカ語",
	"Q3501858",
	"awd",
	scripts = Latn,
}

m["cpc"] = {
	"Ajyíninka Apurucayali",
	"Q3327405",
	"awd",
	scripts = Latn,
}

m["cpg"] = {
	"カッパドキア・ギリシア語",
	"Q853414",
	"grk",
	aliases = {"Cappadocian"},
	scripts = {"polytonic", "fa-Arab"},
	ancestors = {"grc"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, grc, pnt
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
}

m["cpi"] = {
	"中国沿岸ピジン英語",
	"Q3435078",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["cpn"] = {
	"Cherepon",
	"Q35181",
	"alv-gng",
	otherNames = {"Chiripon", "Chiripong", "Kyerepong", "Okere"},
	scripts = Latn,
}

m["cpo"] = {
	"Kpee",
	"Q6435722",
	"dmn-jje",
	otherNames = {"Kpeego", "Kpeen", "Numu"},
}

m["cps"] = {
	"カピス語",
	"Q2937525",
	"phi",
	scripts = Latn,
}

m["cpu"] = {
	"ピチス・アシェニンカ語",
	"Q7190661",
	"awd",
	scripts = Latn,
}

m["cpx"] = {
	"莆仙語",
	"Q56583",
	"zhx-min-hai",
	otherNames = {"Pu-Xian", "Puxian Min", "Pu-Xian Min", "Pu Xian", "Pu Xian Chinese", "Putian", "Xinghua", "Hinghwa"},
	scripts = {"Hani"},
}

m["cpy"] = {
	"南ウカヤリ・アシェニンカ語",
	"Q3501868",
	"awd",
	scripts = Latn,
}

m["cqd"] = {
	"川黔滇苗語",
	"Q3307894",
	"hmn",
	scripts = {"Latn", "Plrd"},
}

m["cra"] = {
	"チャラ語",
	"Q5073694",
	"omv",
	scripts = Latn,
}

m["crb"] = {
	"島嶼カリブ語",
	"Q3450735",
	"awd-taa",
	ancestors = {"awd-taa-pro"},
	scripts = Latn,
}

m["crc"] = {
	"ロンウォルウォル語",
	"Q3259216",
	"poz-oce",
	scripts = Latn,
}

m["crd"] = {
	"クーダレン語",
	"Q32915",
	"sal",
	scripts = Latn,
}

m["crf"] = {
	"カラマンタ語",
	"Q3504195",
	"sai-chc",
	scripts = Latn,
}

m["crg"] = {
	"ミチフ語",
	"Q13315",
	"qfa-mix",
	ancestors = {"cr", "fr"},
	scripts = Latn,
}

m["crh"] = {
	"クリミア・タタール語",
	"Q33357",
	"trk-kcu",
	scripts = {"Latn", "Cyrl"},
}

m["cri"] = {
	"サントメ語",
	"Q36536",
	"crp",
	ancestors = {"pt"},
	aliases = {"Forro", "São Tomense"},
	scripts = Latn,
}

m["crj"] = {
	"東部クリー語（南部）",
	"Q12953464",
	"alg",
	scripts = {"Cans"},
	ancestors = {"cr"},
	translit_module = "cr-translit",
}

m["crk"] = {
	"平原クリー語",
	"Q56699",
	"alg",
	scripts = {"Cans", "Latn"},
	ancestors = {"cr"},
}

m["crl"] = {
	"東部クリー語（北部）",
	"Q12642195",
	"alg",
	scripts = {"Cans"},
	ancestors = {"cr"},
	translit_module = "cr-translit",
}

m["crm"] = {
	"ムース・クリー語",
	"Q3446671",
	"alg",
	scripts = {"Cans"},
	ancestors = {"cr"},
}

m["crn"] = {
	"エル・ナヤール・コラ語",
	"Q12953454",
	"azc",
	scripts = Latn,
}

m["cro"] = {
	"クロウ語",
	"Q1207611",
	"sio-mor",
	otherNames = {"Apsalooke"},
	scripts = Latn,
}

m["crq"] = {
	"Iyo'wujwa Chorote",
	"Q3540927",
	"sai-mtc",
	scripts = Latn,
}

m["crr"] = {
	"カロライナ・アルゴンキン語",
	"Q16113723",
	"alg-eas",
	scripts = Latn,
}

m["crs"] = {
	"セーシェル・クレオール語",
	"Q34015",
	"crp",
	scripts = Latn,
	ancestors = {"fr"},
}

m["crt"] = {
	"Iyojwa'ja Chorote",
	"Q3504118",
	"sai-mtc",
	scripts = Latn,
}

m["crv"] = {
	"Chaura",
	"Q2605680",
	"aav-nic",
	otherNames = {"Tutet"},
}

m["crw"] = {
	"チュラウ語",
	"Q5105629",
	"mkh-ban",
	scripts = Latn,
}

m["crx"] = {
	"キャリア語",
	"Q12953431",
	"ath-nor",
	scripts = {"Latn", "Cans"},
}

m["cry"] = {
	"Cori",
	"Q35204",
	"nic-plc",
	scripts = Latn,
}

m["crz"] = {
	"クルセーニョ語",
	"Q2967636",
	"nai-chu",
	scripts = Latn,
}

m["csa"] = {
	"チルテペク・チナンテク語",
	"Q12953435",
	"omq-chi",
	scripts = Latn,
}

m["csb"] = {
	"カシューブ語",
	"Q33690",
	"zlw-lch",
	scripts = Latn,
	ancestors = {"zlw-pom"},
}

m["csc"] = {
	"カタラン手話",
	"Q35768",
	"sgn",
	scripts = Latn, -- when documented
}

m["csd"] = {
	"チェンマイ手話",
	"Q5095211",
	"sgn",
}

m["cse"] = {
	"チェコ手話",
	"Q5201809",
	"sgn",
	scripts = Latn, -- when documented
}

m["csf"] = {
	"キューバ手話",
	"Q5192046",
	"sgn",
	scripts = Latn, -- when documented
}

m["csg"] = {
	"チリ手話 ",
	"Q3322112",
	"sgn",
	scripts = Latn, -- when documented
}

m["csh"] = {
	"アショウ・チン語",
	"Q12627282",
	"tbq-kuk",
	aliases = {"Asho"},
}

m["csi"] = {
	"海岸ミウォク語",
	"Q2981109",
	"nai-you",
	scripts = Latn,
}

m["csj"] = {
	"Songlai Chin",
	"Q7561280",
	"tbq-kuk",
	aliases = {"Songlai"},
}

m["csk"] = {
	"ジョラ＝カサ語",
	"Q3446622",
	"alv-jol",
	scripts = Latn,
}

m["csl"] = {
	"中国手話",
	"Q1094190",
	"sgn",
}

m["csm"] = {
	"中央シエラ・ミウォク語",
	"Q2944443",
	"nai-you",
	scripts = Latn,
}

m["csn"] = {
	"コロンビア手話",
	"Q2748229",
	"sgn",
	scripts = Latn, -- when documented
}

m["cso"] = {
	"ソチアパム・チナンテク語",
	"Q7550388",
	"omq-chi",
	scripts = Latn,
}

m["csp"] = {
	"桂南平話",
	"Q84302019",
	otherNames = {"Southern Pinghua"},
	scripts = {"Hani"},
}

m["csq"] = {
	"クロアチア手話",
	"Q3507506",
	"sgn",
}

m["csr"] = {
	"コスタリカ手話",
	"Q5174901",
	"sgn",
	scripts = Latn, -- when documented
}

m["css"] = {
	"南部オローニ語",
	"Q25559664",
	"nai-you",
	otherNames = {"Mutsun", "San Juan Bautista Costanoan", "Rumsien", "San Carlos Costanoan", "Carmeleno"},
	scripts = Latn,
}

m["cst"] = {
	"北部オローニ語",
	"Q25559666",
	"nai-you",
	scripts = Latn,
}

m["csv"] = {
	"Sumtu Chin",
	"Q7638087",
	"tbq-kuk",
	aliases = {"Sumtu"},
}

m["csw"] = {
	"湿原クリー語",
	"Q56696",
	"alg",
	scripts = {"Latn", "Cans"},
	ancestors = {"cr"},
}

m["csy"] = {
	"シーイン・チン語",
	"Q7533375",
	"tbq-kuk",
	aliases = {"Siyin"},
}

m["csz"] = {
	"クース語",
	"Q3126783",
	"nai-coo",
	otherNames = {"Hanis", "Hanis Coos"},
	scripts = Latn,
}

m["cta"] = {
	"タタルテペック・チャティーノ語",
	"Q7687853",
	"omq-cha",
	scripts = Latn,
}

m["ctc"] = {
	"チェトコ語",
	"Q12628946",
	"ath-pco",
	otherNames = {"Chetco", "Siletz Dee-ni", "Deeni", "Tututni", "Siletz"},
	scripts = Latn,
}

m["ctd"] = {
	"テディム・チン語",
	"Q56357",
	"tbq-kuk",
	otherNames = {"Tedim", "Tiddim", "Sukte"},
	scripts = {"Latn", "Pauc"},
}

m["cte"] = {
	"Tepinapa Chinantec",
	"Q12953443",
	"omq-chi",
	scripts = Latn,
}

m["ctg"] = {
	"チッタゴン語",
	"Q33173",
	"inc",
	scripts = {"Beng"},
	ancestors = {"inc-mgd"},
}

m["cth"] = {
	"Thaiphum Chin",
	"Q16912048",
	"tbq-kuk",
	aliases = {"Thaiphum"},
}

m["ctl"] = {
	"Tlacoatzintepec Chinantec",
	"Q12643657",
	"omq-chi",
	scripts = Latn,
}

m["ctm"] = {
	"シティマシャ語",
	"Q1294227",
	"qfa-iso",
	scripts = Latn,
}

m["ctn"] = {
	"Chhintange",
	"Q32994",
	"sit-kie",
	scripts = Deva,
}

m["cto"] = {
	"エンベラ＝カティオ語",
	"Q3052039",
	"sai-chc",
	scripts = Latn,
}

m["ctp"] = {
	"西部高地チャティーノ語",
	"Q32861734",
	"omq-cha",
	scripts = Latn,
	sort_key = {
		from = {"á", "é", "í", "ó", "ú"},
		to   = {"a", "e", "i", "o", "u"}},
	entry_name = {
		from = {"[¹²³⁴⁵]"},
		to   = {}}
}

m["cts"] = {
	"北部カタンドアネス・ビコル語",
	"Q7130477",
	"phi",
	scripts = Latn,
}

m["ctt"] = {
	"Wayanad Chetti",
	"Q7975850",
	"dra",
	aliases = {"Chetti"},
	scripts = {"Taml"},
}

m["ctu"] = {
	"チョル語",
	"Q35179",
	"myn",
	scripts = Latn,
}

m["ctz"] = {
	"サカテペク・チャティーノ語",
	"Q8063754",
	"omq-cha",
	scripts = Latn,
}

m["cua"] = {
	"クア語",
	"Q3441115",
	"mkh-ban",
	scripts = Latn,
}

m["cub"] = {
	"クベオ語",
	"Q3006705",
	"sai-tuc",
	aliases = {"Cuveo", "Kubéo", "Kubeo", "Kubéu", "Kubeu", "Cobewa", "Cobéua", "Cobeua", "Kubéwa", "Kubewa", "Kobéua", "Kobeua", "Kobewa", "Pamiwa"},
	scripts = Latn,
}

m["cuc"] = {
	"ウシラ・チナンテク語",
	"Q7901979",
	"omq-chi",
	scripts = Latn,
}

m["cug"] = {
	"Cung",
	"Q35194",
	"nic-bbe",
	otherNames = {"Chung", "Chungmboko", "Chung-Mboko", "Mboko"},
	scripts = Latn,
}

m["cuh"] = {
	"チュカ語",
	"Q12952344",
	"bnt-kka",
	scripts = Latn,
}

m["cui"] = {
	"クイバ語",
	"Q2980421",
	"sai-guh",
	scripts = Latn,
}

m["cuj"] = {
	"マシュコ・ピロ語",
	"Q3446596",
	"awd",
	scripts = Latn,
}

m["cuk"] = {
	"クナ語",
	"Q12953659",
	"cba",
	scripts = Latn,
}

m["cul"] = {
	"クリーナ語",
	"Q2475442",
	"auf",
	otherNames = {"Kulina", "Kulína", "Kulyna", "Curina", "Corina", "Korina", "Culina-Madijá", "Madijá", "Madija", "Madiha", "Madihá"},
	scripts = Latn,
}

m["cuo"] = {
	"クマナゴト語",
	"Q5193784",
	"sai-cpc",
	otherNames = {"Cumanogota", "Cumana", "Cumaná", "Kumana", "Kumaná"},
	scripts = Latn,
}

m["cup"] = {
	"クペーニョ語",
	"Q143130",
	"azc-cup",
	scripts = Latn,
}

m["cuq"] = {
	"クン語",
	"Q2475478",
	"qfa-lic",
	scripts = Latn,
}

m["cur"] = {
	"チュルン語",
	"Q5116126",
	"sit-kie",
	scripts = Deva,
}

m["cut"] = {
	"テウティラ・クイカテク語",
	"Q12953453",
	"omq-cui",
	scripts = Latn,
}

m["cuu"] = {
	"タイ・ヤー語",
	"Q3441122",
	"qfa-tak",
	scripts = Latn,
}

m["cuv"] = {
	"Cuvok語",
	"Q3515056",
	"cdc-cbm",
	scripts = Latn,
}

m["cuw"] = {
	"チュクワ語",
	"Q12629033",
	"sit-kic",
}

m["cux"] = {
	"テペウクシラ・クイカテク語",
	"Q20527242",
	"omq-cui",
	scripts = Latn,
}

m["cuy"] = {
	"クイトラテック語",
	"Q2030998",
	"qfa-iso",
	aliases = {"Cuitlateco"},
	scripts = Latn,
}

m["cvg"] = {
	"Chug",
	"Q47683644",
	"sit-khb",
}

m["cvn"] = {
	"バジェ・ナシオナル・チナンテク語",
	"Q12953442",
	"omq-chi",
	scripts = Latn,
}

m["cwa"] = {
	"Kabwa",
	"Q6344537",
	"bnt-lok",
	scripts = Latn,
}

m["cwb"] = {
	"Maindo",
	"Q11002891",
	"bnt-mak",
	ancestors = {"chw"},
	scripts = Latn,
}

m["cwd"] = {
	"森林クリー語",
	"Q56305",
	"alg",
	scripts = {"Latn", "Cans"},
	ancestors = {"cr"},
}

m["cwe"] = {
	"クウェレ語",
	"Q779632",
	"bnt-ruv",
	scripts = Latn,
}

m["cwg"] = {
	"チェウォン語",
	"Q646718",
	"mkh-asl",
	aliases = {"Cheq Wong", "Cheq-Wong", "Ceq Wong"},
	scripts = Latn,
}

m["cwt"] = {
	"クワータイ語",
	"Q35699",
	"alv-jol",
	scripts = Latn,
}

m["cya"] = {
	"ノパラ・チャティーノ語",
	"Q15616302",
	"omq-cha",
	scripts = Latn,
}

m["cyb"] = {
	"カユババ語",
	"Q3183382",
	"qfa-iso",
	aliases = {"Cayuvava", "Cayuwaba"},
	scripts = Latn,
}

m["cyo"] = {
	"クヨヌン語",
	"Q33153",
	"phi",
	scripts = Latn,
}

m["czh"] = {
	"徽語",
	"Q56546",
	"zhx",
	aliases = {"Huizhou Chinese"},
	scripts = {"Hani"}, -- ?
	ancestors = {"ltc"},
}

m["czk"] = {
	"クナアン語",
	"Q56384",
	"zlw",
	scripts = {"Hebr"},
	ancestors = {"zlw-ocs"},
}

m["czn"] = {
	"センソンテペック・チャティーノ語",
	"Q603106",
	"omq-cha",
	scripts = Latn,
}

m["czo"] = {
	"閩中語",
	"Q56435",
	"zhx-min-shn",
	aliases = {"Min Zhong Chinese"},
	scripts = {"Hani"},
}

m["czt"] = {
	"ゾトン・チン語",
	"Q8074599",
	"tbq-kuk",
	aliases = {"Zotung"},
	scripts = Latn,
}

return m