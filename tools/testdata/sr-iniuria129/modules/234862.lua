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

local Cyrl = {"Cyrl"}
local Deva = {"Deva"}
local Latn = {"Latn"}

local m = {}

m["caa"] = {
	"Ch'orti'",
	"Q35177",
	"myn",
	aliases = {"Chorti"},
	scripts = Latn,
}

m["cab"] = {
	"Garifuna",
	"Q35490",
	"awd-taa",
	ancestors = {"awd-taa-pro"},
	scripts = Latn,
}

m["cac"] = {
	"Chuj",
	"Q35233",
	"myn",
	scripts = Latn,
}

m["cad"] = {
	"Caddo",
	"Q56756",
	"cdd",
	scripts = Latn,
}

m["cae"] = {
	"Laalaa",
	"Q35564",
	"alv-cng",
	scripts = Latn,
}

m["caf"] = {
	"Southern Carrier",
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
	"Cahuarano",
	"Q2933175",
	"sai-zap",
	scripts = Latn,
}

m["caj"] = {
	"Chané",
	"Q56721",
	"awd",
	scripts = Latn,
}

m["cak"] = {
	"Kaqchikel",
	"Q35115",
	"myn",
	aliases = {"Cakchiquel", "Kakchiquel", "Cachiquel"},
	scripts = Latn,
}

m["cal"] = {
	"Carolinian",
	"Q28427",
	"poz-mic",
	scripts = Latn,
}

m["cam"] = {
	"Cemuhî",
	"Q3009690",
	"poz-cln",
	scripts = Latn,
}

m["can"] = {
	"Chambri",
	"Q5069707",
	"paa-lsp",
	scripts = Latn,
}

m["cao"] = {
	"Chácobo",
	"Q2591202",
	"sai-pan",
	scripts = Latn,
}

m["cap"] = {
	"Chipaya",
	"Q35235",
	"sai-ucp",
	scripts = Latn,
}

m["caq"] = {
	"Car Nicobarese",
	"Q35156",
	"aav",
	aliases = {"Car"},
	scripts = Latn,
}

m["car"] = {
	"Galibi Carib",
	"Q56611",
	"sai-car",
	otherNames = {"Carib", "Caribe", "Cariña", "Galibi", "Galibí", "Kalihna", "Kali'na", "Kalinya", "Maraworno", "Marworno"},
	scripts = Latn,
}

m["cas"] = {
	"Tsimané",
	"Q35950",
	"qfa-iso",
	otherNames = {"Chimané", "Mosetén"},
	scripts = Latn,
}

m["cav"] = {
	"Cavineña",
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
	"Cayuga",
	"Q32967",
	"iro",
	scripts = Latn,
}

m["caz"] = {
	"Canichana",
	"Q2936374",
	"qfa-iso",
	scripts = Latn,
}

m["cbb"] = {
	"Cabiyarí",
	"Q3450660",
	"awd-nwk",
	scripts = Latn,
}

m["cbc"] = {
	"Carapana",
	"Q924405",
	"sai-tuc",
	scripts = Latn,
}

m["cbd"] = {
	"Carijona",
	"Q3446655",
	"sai-car",
	otherNames = {"Carihona", "Karijona", "Karihona", "Jianacoto", "Jianácoto", "Hianakoto", "Hianacoto", "Hianákoto", "Guaque", "Omagua", "Umaua", "Umawa"},
	scripts = Latn,
}

m["cbg"] = {
	"Chimila",
	"Q2963680",
	"cba",
	scripts = Latn,
}

m["cbi"] = {
	"Chachi",
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
	"Chavacano",
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
	"Nyah Kur",
	"Q116849",
	"aav",
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
	"Cashibo-Cacataibo",
	"Q5359560",
	"sai-pan",
	otherNames = {"Cashibo", "Cacataibo"},
	scripts = Latn,
}

m["cbs"] = {
	"Cashinahua",
	"Q2591230",
	"sai-pan",
	scripts = Latn,
}

m["cbt"] = {
	"Chayahuita",
	"Q1526525",
	"sai-cah",
	scripts = Latn,
}

m["cbu"] = {
	"Candoshi-Shapra",
	"Q642843",
	"qfa-iso",
	scripts = Latn,
}

m["cbv"] = {
	"Cacua",
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
	"Carabayo",
	"Q3441762",
	"sai-tyu",
	otherNames = {"Caraballo", "Yuri", "Aroje", "Yacumo", "Maku", "Macu", "Macusa"},
	scripts = Latn,
}

m["cca"] = {
	"Cauca",
	"Q5054242",
	"sai-chc",
	scripts = Latn,
}

m["ccc"] = {
	"Chamicuro",
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
	"Chopi",
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
	"Kasanga",
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
	"Malaccan Creole Malay",
	"Q12636092",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["cco"] = {
	"Comaltepec Chinantec",
	"Q2963735",
	"omq-chi",
	scripts = Latn,
}

m["ccp"] = {
	"Chakma",
	"Q32952",
	"inc",
	scripts = {"Cakm"},
	ancestors = {"inc-mgd"},
}

m["ccr"] = {
	"Cacaopera",
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
	"Chenchu",
	"Q32981",
	"dra",
	scripts = {"Telu"},
	ancestors = {"te"},
}

m["cdf"] = {
	"Chiru",
	"Q5102016",
	"tbq-kuk",
	scripts = {"Latn", "Beng"},
}

m["cdh"] = {
	"Chambeali",
	"Q12953424",
	"him",
	scripts = {"Deva", "Takr"},
}

m["cdi"] = {
	"Chodri",
	"Q5103788",
	"inc-bhi",
	scripts = {"Gujr"},
}

m["cdj"] = {
	"Churahi",
	"Q12629039",
	"him",
}

m["cdm"] = {
	"Chepang",
	"Q5091700",
	"sit-gma",
	scripts = Deva,
}

m["cdn"] = {
	"Chaudangsi",
	"Q5088056",
	"sit-alm",
}

m["cdo"] = {
	"Мин Донг",
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
	"Chadian Sign Language",
	"Q10322099",
	"sgn",
	scripts = Latn, -- when documented
}

m["cdy"] = {
	"Chadong",
	"Q926742",
	"qfa-kms",
}

m["cdz"] = {
	"Koda",
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
	"Cebuano",
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
	"Rukiga",
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
	"Chibcha",
	"Q2356431",
	"cba",
}

m["chc"] = {
	"Catawba",
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
	"Tabasco Chontal",
	"Q35175",
	"myn",
	scripts = Latn,
}

m["chg"] = {
	"Chagatai",
	"Q36831",
	"trk-kar",
	scripts = {"Arab"},
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}
	},
}

m["chh"] = {
	"Chinook",
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
	"Chuukese",
	"Q33161",
	"poz-mic",
	scripts = Latn,
}

m["chl"] = {
	"Cahuilla",
	"Q56438",
	"azc-cup",
	scripts = Latn,
	entry_name = {
		from = {"Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú", MACRON},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}} ,
}

m["chm"] = {
	"Eastern Mari",
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
	"Chinook Jargon",
	"Q35173",
	"crp",
	scripts = {"Latn", "Dupl"},
	ancestors = {"chh", "nuk"},
}

m["cho"] = {
	"Choctaw",
	"Q32979",
	"nai-mus",
	scripts = Latn,
}

m["chp"] = {
	"Chipewyan",
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
	"Cherokee",
	"Q33388",
	"iro",
	scripts = {"Cher"},
	translit_module = "Cher-translit",
}

m["cht"] = {
	"Cholón",
	"Q2591243",
	scripts = Latn,
}

m["chw"] = {
	"Chuwabu",
	"Q5118412",
	"bnt-mak",
	scripts = Latn,
}

m["chx"] = {
	"Chantyal",
	"Q4926344",
	"sit-tam",
	scripts = Deva,
}

m["chy"] = {
	"Cheyenne",
	"Q33265",
	"alg",
	scripts = Latn,
}

m["chz"] = {
	"Ozumacín Chinantec",
	"Q5100111",
	"omq-chi",
	scripts = Latn,
}

m["cia"] = {
	"Cia-Cia",
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
	"Chickasaw",
	"Q33192",
	"nai-mus",
	scripts = Latn,
}

m["cid"] = {
	"Chimariko",
	"Q1294251",
	"qfa-iso",
	scripts = Latn,
}

m["cie"] = {
	"Cineni",
	"Q56243",
	"cdc-cbm",
	scripts = Latn,
}

m["cih"] = {
	"Chinali",
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
	"Cimbrian",
	"Q37053",
	"gmw",
	scripts = Latn,
	ancestors = {"bar"},
}

m["cin"] = {
	"Cinta Larga",
	"Q5121095",
	"tup",
	scripts = Latn,
}

m["cip"] = {
	"Chiapanec",
	"Q3364475",
	"omq",
	scripts = Latn,
}

m["cir"] = {
	"Tiri",
	"Q7862281",
	"poz-cln",
	otherNames = {"Tîrî", "Ciri", "Tinrin", "Méa", "Haméa"},
	scripts = Latn,
}

m["ciy"] = {
	"Chaima",
	"Q12628867",
	"sai-car",
	scripts = Latn,
}

m["cja"] = {
	"Western Cham",
	"Q12645578",
	"cmc",
	scripts = {"Arab"},
}

m["cje"] = {
	"Chru",
	"Q2967321",
	"cmc",
	scripts = Latn,
}

m["cjh"] = {
	"Upper Chehalis",
	"Q2962074",
	"sal",
	scripts = Latn,
}

m["cji"] = {
	"Chamalal",
	"Q56567",
	"cau-ava",
	scripts = Cyrl,
}

m["cjk"] = {
	"Chokwe",
	"Q2422065",
	"bnt-clu",
	scripts = Latn,
}

m["cjm"] = {
	"Eastern Cham",
	"Q2948019",
	"cmc",
	scripts = {"Cham"},
}

m["cjn"] = {
	"Chenapian",
	"Q5091044",
	"paa-spk",
	scripts = Latn,
}

m["cjo"] = {
	"Ashéninka Pajonal",
	"Q3450481",
	"awd",
	scripts = Latn,
}

m["cjp"] = {
	"Cabécar",
	"Q27878",
	"cba",
	scripts = Latn,
}

m["cjs"] = {
	"Shor",
	"Q34139",
	"trk-sib",
	scripts = Cyrl,
}

m["cjv"] = {
	"Chuave",
	"Q5115226",
	"ngf",
	scripts = Latn,
}

m["cjy"] = {
	"Jin",
	"Q56479",
	"zhx",
	otherNames = {"Jinyu", "Jinhua", "Jinese", "Shanxinese", "Jin Chinese", "Jinyu Chinese"},
	scripts = {"Hani"},
	ancestors = {"ltc"},
}

m["ckb"] = {
	"Central Kurdish",
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
	"Chak",
	"Q12628870",
	"sit-luu",
	aliases = {"Sak"},
	scripts = Latn,
	ancestors = {"kdv"},
}

m["ckl"] = {
	"Cibak",
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
	"Anufo",
	"Q34845",
	"alv-ctn",
	aliases = {"Chakosi"},
	scripts = Latn,
}

m["ckq"] = {
	"Kajakse",
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
	"Tayo",
	"Q1133089",
	"crp",
	ancestors = {"fr"},
	scripts = Latn,
}

m["ckt"] = {
	"Chukchi",
	"Q33170",
	"qfa-cka",
	scripts = Cyrl,
}

m["cku"] = {
	"Koasati",
	"Q35162",
	"nai-mus",
	scripts = Latn,
}

m["ckv"] = {
	"Kavalan",
	"Q716627",
	"map",
	aliases = {"Kebalan"},
	scripts = Latn,
}

m["ckx"] = {
	"Caka",
	"Q5018037",
	"nic-tvc",
	scripts = Latn,
}

m["cky"] = {
	"Cakfem-Mushere",
	"Q3441199",
	"cdc-wst",
	scripts = Latn,
}

m["ckz"] = {
	"Cakchiquel-Quiché Mixed Language",
	"Q5054550",
	"myn",
	otherNames = {"Cauque Mayan"},
	scripts = Latn,
}

m["cla"] = {
	"Ron",
	"Q3440432",
	"cdc-wst",
	otherNames = {"Bokkos", "Daffo-Butura", "Shagawu"},
	scripts = Latn,
}

m["clc"] = {
	"Chilcotin",
	"Q28535",
	"ath-nor",
	aliases = {"Tsilhqot'in", "Tsilhqut'in", "Tzilkotin"},
	scripts = Latn,
}

m["cld"] = {
	"Chaldean Neo-Aramaic",
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
	"Chilisso",
	"Q3250629",
	"inc-dar",
}

m["cli"] = {
	"Chakali",
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
	"Chala",
	"Q35190",
	"nic-gne",
	scripts = Latn,
}

m["clm"] = {
	"Klallam",
	"Q33404",
	"sal",
	aliases = {"Clallam", "S'Klallam"},
	scripts = Latn,
}

m["clo"] = {
	"Lowland Oaxaca Chontal",
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
	"Chulym",
	"Q33125",
	"trk-sib",
	otherNames = {"Chulim", "Chulym-Turkic", "Küerik", "Chulym Tatar", "Melets Tatar"},
	scripts = {"Latn", "Cyrl"},
}

m["cly"] = {
	"Eastern Highland Chatino",
	"Q12642078",
	"omq-cha",
	scripts = Latn,
}

m["cma"] = {
	"Maa",
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
	"Classical Mongolian",
	"Q5128303",
	"xgn",
	scripts = {"Mong"},
	ancestors = {"xng"},
	translit_module = "mn-translit",
}

m["cmi"] = {
	"Emberá-Chamí",
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
	"Мандарин",
	"Q9192",
	"zhx",
	otherNames = {"Mandarin Chinese", "Putonghua", "Guoyu", "Huayu", "Guanhua", "Beifanghua", "Standard Chinese"},
	scripts = {"Hani", "Latn"},
	ancestors = {"ltc"},
	wikimedia_codes = {"zh"},
}

m["cmo"] = {
	"Central Mnong",
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
	"Messapic",
	"Q36383",
	"ine",
	aliases = {"Messapian"},
	scripts = Latn, -- when documented here; otherwise written in a native script
}

m["cmt"] = {
	"Camtho",
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
	"Chinbon Chin",
	"Q12952327",
	"tbq-kuk",
	aliases = {"Chinbon"},
}

m["cnc"] = {
	"Côông",
	"Q5202780",
	"tbq-lol",
}

m["cng"] = {
	"Northern Qiang",
	"Q56559",
	"sit-qia",
}

m["cnh"] = {
	"Lai",
	"Q3250286",
	"tbq-kuk",
	otherNames = {"Haka Chin", "Haka"},
}

m["cni"] = {
	"Asháninka",
	"Q3437230",
	"awd",
	aliases = {"Ashaninka"},
	scripts = Latn,
}

m["cnk"] = {
	"Khumi Chin",
	"Q56308",
	"tbq-kuk",
	otherNames = {"Khumi", "Khami", "Nisay", "Nise", "Eastern Khumi", "Eastern Khumi Chin"},
}

m["cnl"] = {
	"Lalana Chinantec",
	"Q12953437",
	"omq-chi",
	scripts = Latn,
}

m["cno"] = {
	"Con",
	"Q3440883",
	"mkh-pal",
}

m["cns"] = {
	"Central Asmat",
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
	"Middle Cornish",
	"Q12642603",
	"cel-bry",
	scripts = Latn,
	ancestors = {"oco"},
}

m["coa"] = {
	"Cocos Islands Malay",
	"Q3441699",
	"crp",
	aliases = {"Cocos Malay"},
	scripts = Latn,
	ancestors = {"ms"},
}

m["cob"] = {
	"Chicomuceltec",
	"Q3307204",
	"myn",
	scripts = Latn,
}

m["coc"] = {
	"Cocopa",
	"Q33044",
	"nai-yuc",
	scripts = Latn,
}

m["cod"] = {
	"Cocama",
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
	"Tsafiki",
	"Q2567055",
	"sai-bar",
	otherNames = {"Colorado", "Tsáchila"},
	scripts = Latn,
}

m["cog"] = {
	"Chong",
	"Q3914630",
	"mkh-pea",
	scripts = {"Thai", "Khmr"},
	sort_key = {
		from = {"[%pๆ]", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "%2%1"}},
}

m["coh"] = {
	"Chichonyi-Chidzihana-Chikauma",
	"Q12629011",
	"bnt-mij",
	scripts = Latn,
}

m["coj"] = {
	"Cochimi",
	"Q3915551",
	"nai-yuc",
	scripts = Latn,
}

m["cok"] = {
	"Santa Teresa Cora",
	"Q12641754",
	"azc",
	scripts = Latn,
}

m["col"] = {
	"Columbia-Wenatchi",
	"Q3324744",
	"sal",
	otherNames = {"Columbia-Wenatchee", "Columbia-Moses", "Nxaamxcin", "Wenatchi", "Wenatchee"},
	scripts = Latn,
}

m["com"] = {
	"Comanche",
	"Q32972",
	"azc-num",
	scripts = Latn,
}

m["con"] = {
	"Cofán",
	"Q2669254",
	"qfa-iso",
	otherNames = {"Cofan", "Kofan", "Kofane", "A'ingae", "Maku", "Macu"},
	scripts = Latn,
}

m["coo"] = {
	"Comox",
	"Q13583746",
	"sal",
	scripts = Latn,
}

m["cop"] = {
	"Coptic",
	"Q36155",
	"egx",
	-- Don't include varieties in [[Module:etymology languages/data]]
	scripts = {"Copt"},
	translit_module = "Copt-translit",
	ancestors = {"egx-dem"},
	entry_name = {
		from =	{ "ˋ", GRAVE, MACRON, },
		to =	{},
	},
	sort_key = "cop-sortkey",
}

m["coq"] = {
	"Coquille",
	"Q12953452",
	"ath-pco",
	scripts = Latn,
}

m["cot"] = {
	"Caquinte",
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
	"Cao Miao",
	"Q2936935",
	"qfa-tak",
}

m["cow"] = {
	"Cowlitz",
	"Q3001877",
	"sal",
	scripts = Latn,
}

m["cox"] = {
	"Nanti",
	"Q15342275",
	"awd",
	scripts = Latn,
}

m["coy"] = {
	"Coyaima",
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
	"Palantla Chinantec",
	"Q5100112",
	"omq-chi",
	scripts = Latn,
}

m["cpb"] = {
	"Ucayali-Yurúa Ashéninka",
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
	"Cappadocian Greek",
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
	"Chinese Pidgin English",
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
	"Capiznon",
	"Q2937525",
	"phi",
	scripts = Latn,
}

m["cpu"] = {
	"Pichis Ashéninka",
	"Q7190661",
	"awd",
	scripts = Latn,
}

m["cpx"] = {
	"Puxian",
	"Q56583",
	"zhx-min-hai",
	otherNames = {"Pu-Xian", "Puxian Min", "Pu-Xian Min", "Pu Xian", "Pu Xian Chinese", "Putian", "Xinghua", "Hinghwa"},
	scripts = {"Hani"},
}

m["cpy"] = {
	"South Ucayali Ashéninka",
	"Q3501868",
	"awd",
	scripts = Latn,
}

m["cqd"] = {
	"Chuanqiandian Cluster Miao",
	"Q3307894",
	"hmn",
	scripts = {"Latn", "Plrd"},
}

m["cra"] = {
	"Chara",
	"Q5073694",
	"omv",
	scripts = Latn,
}

m["crb"] = {
	"Island Carib",
	"Q3450735",
	"awd-taa",
	ancestors = {"awd-taa-pro"},
	scripts = Latn,
}

m["crc"] = {
	"Lonwolwol",
	"Q3259216",
	"poz-oce",
	scripts = Latn,
}

m["crd"] = {
	"Coeur d'Alene",
	"Q32915",
	"sal",
	scripts = Latn,
}

m["crf"] = {
	"Caramanta",
	"Q3504195",
	"sai-chc",
	scripts = Latn,
}

m["crg"] = {
	"Michif",
	"Q13315",
	"qfa-mix",
	ancestors = {"cr", "fr"},
	scripts = Latn,
}

m["crh"] = {
	"Crimean Tatar",
	"Q33357",
	"trk-kcu",
	scripts = {"Latn", "Cyrl"},
}

m["cri"] = {
	"Sãotomense",
	"Q36536",
	"crp",
	ancestors = {"pt"},
	aliases = {"Forro", "São Tomense"},
	scripts = Latn,
}

m["crj"] = {
	"Southern East Cree",
	"Q12953464",
	"alg",
	scripts = {"Cans"},
	ancestors = {"cr"},
	translit_module = "cr-translit",
}

m["crk"] = {
	"Plains Cree",
	"Q56699",
	"alg",
	scripts = {"Cans", "Latn"},
	ancestors = {"cr"},
}

m["crl"] = {
	"Northern East Cree",
	"Q12642195",
	"alg",
	scripts = {"Cans"},
	ancestors = {"cr"},
	translit_module = "cr-translit",
}

m["crm"] = {
	"Moose Cree",
	"Q3446671",
	"alg",
	scripts = {"Cans"},
	ancestors = {"cr"},
}

m["crn"] = {
	"Cora",
	"Q12953454",
	"azc",
	scripts = Latn,
}

m["cro"] = {
	"Crow",
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
	"Carolina Algonquian",
	"Q16113723",
	"alg-eas",
	scripts = Latn,
}

m["crs"] = {
	"Seychellois Creole",
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
	"aav",
	otherNames = {"Tutet"},
}

m["crw"] = {
	"Chrau",
	"Q5105629",
	"mkh-ban",
	scripts = Latn,
}

m["crx"] = {
	"Carrier",
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
	"Cruzeño",
	"Q2967636",
	"nai-chu",
	scripts = Latn,
}

m["csa"] = {
	"Chiltepec Chinantec",
	"Q12953435",
	"omq-chi",
	scripts = Latn,
}

m["csb"] = {
	"Kashubian",
	"Q33690",
	"zlw-lch",
	scripts = Latn,
	ancestors = {"zlw-pom"},
}

m["csc"] = {
	"Catalan Sign Language",
	"Q35768",
	"sgn",
	scripts = Latn, -- when documented
}

m["csd"] = {
	"Chiangmai Sign Language",
	"Q5095211",
	"sgn",
}

m["cse"] = {
	"Czech Sign Language",
	"Q5201809",
	"sgn",
	scripts = Latn, -- when documented
}

m["csf"] = {
	"Cuban Sign Language",
	"Q5192046",
	"sgn",
	scripts = Latn, -- when documented
}

m["csg"] = {
	"Chilean Sign Language",
	"Q3322112",
	"sgn",
	scripts = Latn, -- when documented
}

m["csh"] = {
	"Asho Chin",
	"Q12627282",
	"tbq-kuk",
	aliases = {"Asho"},
}

m["csi"] = {
	"Coast Miwok",
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
	"Jola-Kasa",
	"Q3446622",
	"alv-jol",
	scripts = Latn,
}

m["csl"] = {
	"Chinese Sign Language",
	"Q1094190",
	"sgn",
}

m["csm"] = {
	"Central Sierra Miwok",
	"Q2944443",
	"nai-you",
	scripts = Latn,
}

m["csn"] = {
	"Colombian Sign Language",
	"Q2748229",
	"sgn",
	scripts = Latn, -- when documented
}

m["cso"] = {
	"Sochiapam Chinantec",
	"Q7550388",
	"omq-chi",
	scripts = Latn,
}

m["csq"] = {
	"Croatian Sign Language",
	"Q3507506",
	"sgn",
}

m["csr"] = {
	"Costa Rican Sign Language",
	"Q5174901",
	"sgn",
	scripts = Latn, -- when documented
}

m["css"] = {
	"Southern Ohlone",
	"Q25559664",
	"nai-you",
	otherNames = {"Mutsun", "San Juan Bautista Costanoan", "Rumsien", "San Carlos Costanoan", "Carmeleno"},
	scripts = Latn,
}

m["cst"] = {
	"Northern Ohlone",
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
	"Swampy Cree",
	"Q56696",
	"alg",
	scripts = {"Latn", "Cans"},
	ancestors = {"cr"},
}

m["csy"] = {
	"Siyin Chin",
	"Q7533375",
	"tbq-kuk",
	aliases = {"Siyin"},
}

m["csz"] = {
	"Coos",
	"Q3126783",
	"nai-coo",
	otherNames = {"Hanis", "Hanis Coos"},
	scripts = Latn,
}

m["cta"] = {
	"Tataltepec Chatino",
	"Q7687853",
	"omq-cha",
	scripts = Latn,
}

m["ctc"] = {
	"Chetco-Tolowa",
	"Q12628946",
	"ath-pco",
	otherNames = {"Chetco", "Siletz Dee-ni", "Deeni", "Tututni", "Siletz"},
	scripts = Latn,
}

m["ctd"] = {
	"Tedim Chin",
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
	"Chittagonian",
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
	"Chitimacha",
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
	"Emberá-Catío",
	"Q3052039",
	"sai-chc",
	scripts = Latn,
}

m["ctp"] = {
	"Western Highland Chatino",
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
	"Northern Catanduanes Bicolano",
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
	"Chol",
	"Q35179",
	"myn",
	scripts = Latn,
}

m["ctz"] = {
	"Zacatepec Chatino",
	"Q8063754",
	"omq-cha",
	scripts = Latn,
}

m["cua"] = {
	"Cua",
	"Q3441115",
	"mkh-ban",
	scripts = Latn,
}

m["cub"] = {
	"Cubeo",
	"Q3006705",
	"sai-tuc",
	aliases = {"Cuveo", "Kubéo", "Kubeo", "Kubéu", "Kubeu", "Cobewa", "Cobéua", "Cobeua", "Kubéwa", "Kubewa", "Kobéua", "Kobeua", "Kobewa", "Pamiwa"},
	scripts = Latn,
}

m["cuc"] = {
	"Usila Chinantec",
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
	"Chuka",
	"Q12952344",
	"bnt-kka",
	scripts = Latn,
}

m["cui"] = {
	"Cuiba",
	"Q2980421",
	"sai-guh",
	scripts = Latn,
}

m["cuj"] = {
	"Mashco Piro",
	"Q3446596",
	"awd",
	scripts = Latn,
}

m["cuk"] = {
	"Kuna",
	"Q12953659",
	"cba",
	scripts = Latn,
}

m["cul"] = {
	"Culina",
	"Q2475442",
	"auf",
	otherNames = {"Kulina", "Kulína", "Kulyna", "Curina", "Corina", "Korina", "Culina-Madijá", "Madijá", "Madija", "Madiha", "Madihá"},
	scripts = Latn,
}

m["cuo"] = {
	"Cumanagoto",
	"Q5193784",
	"sai-cpc",
	otherNames = {"Cumanogota", "Cumana", "Cumaná", "Kumana", "Kumaná"},
	scripts = Latn,
}

m["cup"] = {
	"Cupeño",
	"Q143130",
	"azc-cup",
	scripts = Latn,
}

m["cuq"] = {
	"Cun",
	"Q2475478",
	"qfa-lic",
}

m["cur"] = {
	"Chhulung",
	"Q5116126",
	"sit-kie",
	scripts = Deva,
}

m["cut"] = {
	"Teutila Cuicatec",
	"Q12953453",
	"omq-mix",
	scripts = Latn,
}

m["cuu"] = {
	"Tai Ya",
	"Q3441122",
	"qfa-tak",
	scripts = Latn,
}

m["cuv"] = {
	"Cuvok",
	"Q3515056",
	"cdc-cbm",
	scripts = Latn,
}

m["cuw"] = {
	"Chukwa",
	"Q12629033",
	"sit-kic",
}

m["cux"] = {
	"Tepeuxila Cuicatec",
	"Q20527242",
	"omq-mix",
	scripts = Latn,
}

m["cuy"] = {
	"Cuitlatec",
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
	"Valle Nacional Chinantec",
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
	"Woods Cree",
	"Q56305",
	"alg",
	scripts = {"Latn", "Cans"},
	ancestors = {"cr"},
}

m["cwe"] = {
	"Kwere",
	"Q779632",
	"bnt-ruv",
	scripts = Latn,
}

m["cwg"] = {
	"Chewong",
	"Q646718",
	"mkh-asl",
	aliases = {"Cheq Wong", "Cheq-Wong", "Ceq Wong"},
	scripts = Latn,
}

m["cwt"] = {
	"Kuwaataay",
	"Q35699",
	"alv-jol",
	scripts = Latn,
}

m["cya"] = {
	"Nopala Chatino",
	"Q15616302",
	"omq-cha",
	scripts = Latn,
}

m["cyb"] = {
	"Cayubaba",
	"Q3183382",
	"qfa-iso",
	aliases = {"Cayuvava", "Cayuwaba"},
	scripts = Latn,
}

m["cyo"] = {
	"Cuyunon",
	"Q33153",
	"phi",
	scripts = Latn,
}

m["czh"] = {
	"Huizhou",
	"Q56546",
	"zhx",
	aliases = {"Huizhou Chinese"},
	scripts = {"Hani"}, -- ?
	ancestors = {"ltc"},
}

m["czk"] = {
	"Knaanic",
	"Q56384",
	"zlw",
	scripts = {"Hebr"},
	ancestors = {"zlw-ocs"},
}

m["czn"] = {
	"Zenzontepec Chatino",
	"Q603106",
	"omq-cha",
	scripts = Latn,
}

m["czo"] = {
	"Min Zhong",
	"Q56435",
	"zhx-min-shn",
	aliases = {"Min Zhong Chinese"},
	scripts = {"Hani"},
}

m["czt"] = {
	"Zotung Chin",
	"Q8074599",
	"tbq-kuk",
	aliases = {"Zotung"},
	scripts = Latn,
}

return m