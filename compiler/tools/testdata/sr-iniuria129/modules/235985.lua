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

-- Use these in "scripts" to save a little memory.
local Arab = {"Arab"}
local Cyrl = {"Cyrl"}
local Deva = {"Deva"}
local Latn = {"Latn"}

local m = {}

m["baa"] = {
	"Babatana",
	"Q2877785",
	"poz-ocw",
	otherNames = {"Mbambatana", "Bambatana"},
	scripts = Latn,
}

m["bab"] = {
	"Bainouk-Gunyuño",
	"Q35508",
	"alv-sng",
	scripts = Latn,
}

m["bac"] = {
	"Badui",
	"Q3449885",
	"poz-msa",
	scripts = Latn,
}

m["bae"] = {
	"Baré",
	"Q3504087",
	"awd",
	otherNames = {"Barawana"},
	scripts = Latn,
}

m["baf"] = {
	"Nubaca",
	"Q36270",
	"nic-bod",
	otherNames = {"Nu Baca", "Baca"},
	scripts = Latn,
}

m["bag"] = {
	"Tuki",
	"Q36621",
	"nic-bod",
	scripts = Latn,
}

m["bah"] = {
	"Bahamian Creole",
	"Q2669229",
	"crp",
	otherNames = {"Bahamian Creole English", "Bahamian", "Bahamas Creole", "Bahamas Creole English"},
	scripts = Latn,
}

m["baj"] = {
	"Barakai",
	"Q3502030",
	"poz-cet",
	scripts = Latn,
}

m["bal"] = {
	"Baluchi",
	"Q33049",
	"ira-wes",
	otherNames = {"Balochi", "Southern Baluchi", "Southern Balochi", "Eastern Baluchi", "Eastern Balochi", "Western Baluchi", "Western Balochi"},
	scripts = {"fa-Arab"},
}

m["ban"] = {
	"Balinese",
	"Q33070",
	"poz-mcm",
	scripts = {"Latn", "Bali"},
}

m["bao"] = {
	"Waimaha",
	"Q2883738",
	"sai-tuc",
	scripts = Latn,
}

m["bap"] = {
	"Bantawa",
	"Q56500",
	"sit",
	scripts = Deva,
}

m["bar"] = {
	"Bavarian",
	"Q29540",
	"gmw",
	otherNames = {"Austro-Bavarian"},
	scripts = Latn,
	ancestors = {"gmh"},
}

m["bas"] = {
	"Basaa",
	"Q33093",
	"bnt",
	otherNames = {"Basa (Cameroon)", "Basa"},
	scripts = Latn,
}

m["bau"] = {
	"Badanchi",
	"Q11001650",
	"nic-bod",
	otherNames = {"Bada", "Bada (Nigeria)"},
	scripts = Latn,
}

m["bav"] = {
	"Babungo",
	"Q34885",
	"nic-grf",
	otherNames = {"Vengo"},
	scripts = Latn,
}

m["baw"] = {
	"Bambili-Bambui",
	"Q34880",
	"nic-bod",
	scripts = Latn,
}

m["bax"] = {
	"Bamum",
	"Q35280",
	"nic-bod",
	otherNames = {"Bamun"},
	scripts = {"Latn", "Bamu"},
}

m["bay"] = {
	"Batuley",
	"Q8828787",
	"poz",
	scripts = Latn,
}

m["bba"] = {
	"Baatonum",
	"Q34889",
	"alv",
	scripts = Latn,
}

m["bbb"] = {
	"Barai",
	"Q4858206",
	"ngf",
	scripts = Latn,
}

m["bbc"] = {
	"Toba Batak",
	"Q33017",
	"btk",
	otherNames = {"Batak Toba"},
	scripts = {"Latn", "Batk"},
}

m["bbd"] = {
	"Bau",
	"Q4873415",
	"ngf-mad",
	scripts = Latn,
}

m["bbe"] = {
	"Bangba",
	"Q34895",
	"nic-ubg",
	scripts = Latn,
}

m["bbf"] = {
	"Baibai",
	"Q56902",
	"paa",
	scripts = Latn,
}

m["bbg"] = {
	"Barama",
	"Q34884",
	"bnt",
	scripts = Latn,
}

m["bbh"] = {
	"Bugan",
	"Q3033554",
	"mkh",
	otherNames = {"Bogan"},
	scripts = Latn,
}

m["bbi"] = {
	"Barombi",
	"Q34985",
	"bnt",
	otherNames = {"Rombi", "Lombi", "Lombe"},
	scripts = Latn,
}

m["bbj"] = {
	"Ghomala'",
	"Q35271",
	"bai",
	otherNames = {"Ghomálá'", "Bamileke-Banjun"},
	scripts = Latn,
}

m["bbk"] = {
	"Babanki",
	"Q34790",
	"bnt",
	otherNames = {"Kejom", "Kidzem"},
	scripts = Latn,
}

m["bbl"] = {
	"Bats",
	"Q33259",
	"cau-nkh",
	otherNames = {"Batsbi", "Tsova-Tush"},
	scripts = {"Geor"},
	translit_module = "Geor-translit",
	entry_name = {
		from = {"̃", "<sup>ნ</sup>", MACRON, BREVE}, 
		to   = {"", "ნ"}} ,
}

m["bbm"] = { -- name includes prefix
	"Babango",
	"Q34819",
	"bnt",
	otherNames = {"Bango", "Mobango", "Ebango"},
	scripts = Latn,
}

m["bbn"] = {
	"Uneapa",
	"Q7884126",
	"poz-ocw",
	scripts = Latn,
}

m["bbo"] = {
	"Konabéré",
	"Q35371",
	"dmn",
	otherNames = {"Bobo Fing", "Black Bobo", "Northern Bobo Madaré", "Bobo", "Jèrè", "Kukoma", "Kure", "Sankuma", "Tankri", "Yaba"},
	scripts = Latn,
}

m["bbp"] = {
	"West Central Banda",
	"Q7984377",
	"nic-ubg",
	scripts = Latn,
}

m["bbq"] = {
	"Bamali",
	"Q34901",
	"nic-bod",
	scripts = Latn,
}

m["bbr"] = {
	"Girawa",
	"Q5564185",
	"ngf-mad",
	scripts = Latn,
}

m["bbs"] = {
	"Bakpinka",
	"Q3515061",
	"nic-bco",
	scripts = Latn,
}

m["bbt"] = {
	"Mburku",
	"Q3441324",
	"cdc-wst",
	scripts = Latn,
}

m["bbu"] = {
	"Bakulung",
	"Q35580",
	"nic-bod",
	otherNames = {"Kulung", "Kulung (Nigeria)"},
	scripts = Latn,
}

m["bbv"] = {
	"Karnai",
	"Q6372803",
	"poz-ocw",
	scripts = Latn,
}

m["bbw"] = {
	"Baba",
	"Q34822",
	"nic-bod",
	scripts = Latn,
}

m["bbx"] = { -- cf bvb
	"Bubia",
	"Q34953",
	"bnt",
	scripts = Latn,
}

m["bby"] = {
	"Befang",
	"Q34960",
	"nic-bod",
	scripts = Latn,
}

m["bbz"] = {
	"Babalia Creole Arabic",
	"Q3504186",
	"crp",
	otherNames = {"Babalia Arabic"},
	scripts = Arab,
	ancestors = {"ar"},
}

m["bca"] = {
	"Central Bai",
	"Q12628803",
	"sit",
	otherNames = {"Jianchuan Bai"},
	scripts = {"Hani", "Latn"},
}

m["bcb"] = {
	"Bainouk-Samik",
	"Q36390",
	"alv-sng",
	scripts = Latn,
}

m["bcd"] = {
	"North Babar",
	"Q7054041",
	"poz",
	scripts = Latn,
}

m["bce"] = {
	"Bamenyam",
	"Q34968",
	"nic-bod",
	scripts = Latn,
}

m["bcf"] = {
	"Bamu",
	"Q3503788",
	"ngf",
	scripts = Latn,
}

m["bcg"] = {
	"Baga Pokur",
	"Q31172660",
	"alv-sng",
	otherNames = {"Baga Binari", "Baga Mboteni"},
	scripts = Latn,
}

m["bch"] = {
	"Bariai",
	"Q2884502",
	"poz-ocw",
	scripts = Latn,
}

m["bci"] = {
	"Baoule",
	"Q35107",
	"alv-kwa",
	otherNames = {"Baoulé", "Bawule"},
	scripts = Latn,
}

m["bcj"] = {
	"Bardi",
	"Q3913852",
	"aus-nyu",
	scripts = Latn,
}

m["bck"] = {
	"Bunaba",
	"Q580923",
	"aus-bub",
	scripts = Latn,
}

m["bcl"] = {
	"Bikol Central",
	"Q33284",
	"phi",
	otherNames = {"Central Bikol", "Bikol"}, -- also "Central Bicolano"?
	scripts = Latn,
}

m["bcm"] = {
	"Banoni",
	"Q2882857",
	"poz-ocw",
	otherNames = {"Bannoni", "Tsunari"},
	scripts = Latn,
}

m["bcn"] = {
	"Bibaali",
	"Q34892",
	"alv",
	otherNames = {"Bali", "Bali (Nigeria)", "Abaali"},
	scripts = Latn,
}

m["bco"] = {
	"Kaluli",
	"Q6354586",
	"ngf",
	scripts = Latn,
}

m["bcp"] = {
	"Bali",
	"Q3515074",
	"bnt",
	otherNames = {"Bali (Congo)", "Bali (Democratic Republic of the Congo)", "Baali", "Kibali", "Libaali"},
	scripts = Latn,
}

m["bcq"] = {
	"Bench",
	"Q35108",
	"omv",
	scripts = Latn,
}

m["bcr"] = {
	"Babine-Witsuwit'en",
	"Q27864",
	"ath-nor",
	otherNames = {"Babine", "Witsuwit'en", "Northern Carrier", "Western Carrier", "Nadot’en-Wets’uwet’en"},
	scripts = Latn,
}

m["bcs"] = {
	"Kohumono",
	"Q35590",
	"nic-bco",
	scripts = Latn,
}

m["bct"] = {
	"Bendi",
	"Q8836662",
	"csu",
	scripts = Latn,
}

m["bcu"] = {
	"Biliau",
	"Q2874658",
	"poz-ocw",
	otherNames = {"Awad Bing"},
	scripts = Latn,
}

m["bcv"] = {
	"Shoo-Minda-Nye",
	"Q36548",
	"nic-bco",
	otherNames = {"Shoo", "Minda", "Nye"},
	scripts = Latn,
}

m["bcw"] = {
	"Bana",
	"Q56272",
	"cdc-cbm",
	scripts = Latn,
}

m["bcy"] = {
	"Bacama",
	"Q56274",
	"cdc",
	scripts = Latn,
}

m["bcz"] = {
	"Bainouk-Gunyaamolo",
	"Q35506",
	"alv-sng",
	scripts = Latn,
}

m["bda"] = {
	"Bayot",
	"Q35019",
	"alv",
	otherNames = {"Baiot", "Baiote", "Bayotte"},
	scripts = Latn,
}

m["bdb"] = {
	"Basap",
	"Q3504208",
	"poz-bnn",
	scripts = Latn,
}

m["bdc"] = {
	"Emberá-Baudó",
	"Q11173166",
	"sai-chc",
	scripts = Latn,
}

m["bdd"] = {
	"Bunama",
	"Q4997416",
	"poz-ocw",
	scripts = Latn,
}

m["bde"] = {
	"Bade",
	"Q56239",
	"cdc-wst",
	scripts = Latn,
}

m["bdf"] = {
	"Biage",
	"Q48037487",
	"ngf",
	scripts = Latn,
}

m["bdg"] = {
	"Bonggi",
	"Q2910053",
	"poz-bnn",
	scripts = Latn,
}

m["bdh"] = {
	"Tara Baka",
	"Q2880165",
	"csu",
	otherNames = {"Baka", "Baka (Sudan)"},
	scripts = Latn,
}

m["bdi"] = {
	"Burun",
	"Q35040",
	"sdv",
	otherNames = {"Northern Burun", "Maiak", "Mayak", "Mughaja", "Kurmuk"},
	scripts = Latn,
}

m["bdj"] = {
	"Bai",
	"Q34894",
	"nic-ubg",
	otherNames = {"Belanda", "Biri", "BGamba", "Gumba", "Mbegumba", "Mvegumba"},
	scripts = Latn,
}

m["bdk"] = {
	"Budukh",
	"Q35397",
	"cau-lzg",
	otherNames = {"Budugh"},
	translit_module = "bdk-translit",
	override_translit = true,
	scripts = Cyrl,
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["bdl"] = {
	"Indonesian Bajau",
	"Q2880038",
	"poz",
	otherNames = {"Indonesian Bajo", "Sulawesi Bajau", "Sulawesi Bajaw", "Bajau", "Bajaw", "Bajo"},
	scripts = Latn,
}

m["bdm"] = {
	"Buduma",
	"Q56287",
	"cdc-cbm",
	otherNames = {"Yedina", "Kuri"},
	scripts = Latn,
}

m["bdn"] = {
	"Baldemu",
	"Q56280",
	"cdc-cbm",
	scripts = Latn,
}

m["bdo"] = {
	"Morom",
	"Q759770",
	"csu",
	scripts = Latn,
}

m["bdp"] = {
	"Bende",
	"Q8836490",
	"bnt",
	scripts = Latn,
}

m["bdq"] = {
	"Bahnar",
	"Q32924",
	"mkh-ban",
	scripts = Latn,
	ancestors = {"mkh-ban-pro"},
}

m["bdr"] = {
	"West Coast Bajau",
	"Q2880037",
	"poz-sbj",
	scripts = Latn,
}

m["bds"] = {
	"Burunge",
	"Q56617",
	"cus",
	scripts = Latn,
}

m["bdt"] = {
	"Bokoto",
	"Q4938812",
	"alv-sav",
	scripts = Latn,
}

m["bdu"] = {
	"Oroko",
	"Q36278",
	"bnt",
	otherNames = {"Bima", "Bakundu-Balue", "Balundu-Bima"},
	scripts = Latn,
}

m["bdv"] = {
	"Bodo Parja",
	"Q8845881",
	"inc",
	scripts = {"Orya"},
}

m["bdw"] = {
	"Baham",
	"Q3513309",
	"paa",
	scripts = Latn,
}

m["bdx"] = {
	"Budong-Budong",
	"Q4985158",
	"poz-ssw",
	scripts = Latn,
}

m["bdy"] = {
	"Bandjalang",
	"Q2980386",
	"aus-pam",
	scripts = Latn,
}

m["bdz"] = { -- spurious?
	"Badeshi",
	"Q33028",
	"inc",
}

m["bea"] = {
	"Beaver",
	"Q20826",
	"ath-nor",
	otherNames = {"Dane-zaa", "Danezaa", "Danezaa ZaageɁ"},
	scripts = Latn,
}

m["beb"] = {
	"Bebele",
	"Q34976",
	"bnt",
	scripts = Latn,
}

m["bec"] = {
	"Iceve-Maci",
	"Q35449",
	"nic-bod",
	scripts = Latn,
}

m["bed"] = {
	"Bedoanas",
	"Q4879330",
	"poz-hce",
	scripts = Latn,
}

m["bee"] = {
	"Byangsi",
	"Q56904",
	"sit",
	scripts = Deva,
}

m["bef"] = {
	"Benabena",
	"Q2895638",
	"paa-kag",
	scripts = Latn,
}

m["beg"] = {
	"Belait",
	"Q2894198",
	"poz-swa",
	otherNames = {"Lemeting"},
	scripts = Latn,
}

m["beh"] = {
	"Biali",
	"Q34961",
	"nic-gur",
	otherNames = {"Berba", "Bieri"},
	scripts = Latn,
}

m["bei"] = {
	"Bekati'",
	"Q3441683",
	"day",
	otherNames = {"Bekati’", "Bekatiq", "Bakati"},
	scripts = Latn,
}

m["bej"] = {
	"Beja",
	"Q33025",
	"cus",
	scripts = {"Arab", "Latn"},
}

m["bek"] = {
	"Bebeli",
	"Q4878430",
	"poz-ocw",
	scripts = Latn,
}

m["bem"] = {
	"Bemba",
	"Q33052",
	"bnt",
	otherNames = {"Bemba (Zambia)"},
	scripts = Latn,
}

m["beo"] = {
	"Beami",
	"Q3504079",
	"paa",
	otherNames = {"Bedamini", "Bedamuni", "Mougulu"},
	scripts = Latn,
}

m["bep"] = {
	"Besoa",
	"Q8840465",
	"poz-kal",
	scripts = Latn,
}

m["beq"] = {
	"Beembe",
	"Q3196320",
	"bnt",
	otherNames = {"Bembe", "Kibeembe"},
	scripts = Latn,
}

m["bes"] = {
	"Besme",
	"Q289832",
	"alv",
	scripts = Latn,
}

m["bet"] = {
	"Guiberoua Bété",
	"Q11019185",
	"kro",
	otherNames = {"Bété of Guiberoua", "Western Bété"},
	scripts = Latn,
}

m["beu"] = {
	"Blagar",
	"Q4923846",
	"ngf",
	otherNames = {"Belagar"},
	scripts = Latn,
}

m["bev"] = {
	"Daloa Bété",
	"Q11155819",
	"kro",
	otherNames = {"Bété of Daloa ", "Northern Bété"},
	scripts = Latn,
}

m["bew"] = {
	"Betawi",
	"Q33014",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["bex"] = {
	"Jur Modo",
	"Q56682",
	"csu",
	scripts = Latn,
}

m["bey"] = {
	"Akuwagel",
	"Q3504170",
	"qfa-tor",
	otherNames = {"Beli", "Beli (New Guinea)", "Beli (Papua New Guinea)"},
	scripts = Latn,
}

m["bez"] = {
	"Kibena",
	"Q2502949",
	"bnt",
	otherNames = {"Bena", "Bena (Tanzania)"},
	scripts = Latn,
}

m["bfa"] = {
	"Bari",
	"Q35042",
	"sdv",
	otherNames = {"Pojulu", "Pöjulu", "Fadjulu", "Fajelu", "Madi", "Pajulu"},
	scripts = Latn,
}

m["bfb"] = {
	"Pauri Bareli",
	"Q7155462",
	"inc",
	scripts = Deva,
}

m["bfc"] = {
	"Northern Bai",
	"Q12642165",
	"sit",
	otherNames = {"Bijiang Bai", "Laemae", "Lama", "Panyi Bai"},
	scripts = {"Hani", "Latn"},
}

m["bfd"] = {
	"Bafut",
	"Q34888",
	"nic-grf",
	scripts = Latn,
}

m["bfe"] = {
	"Betaf",
	"Q4897329",
	"paa",
	scripts = Latn,
}

m["bff"] = {
	"Bofi",
	"Q34914",
	"alv-sav",
	scripts = Latn,
}

m["bfg"] = {
	"Busang Kayan",
	"Q9231909",
	"poz",
	scripts = Latn,
}

m["bfh"] = {
	"Blafe",
	"Q12628007",
	"paa",
	scripts = Latn,
}

m["bfi"] = {
	"British Sign Language",
	"Q33000",
	"sgn",
	otherNames = {"BSL"},
	scripts = Latn, -- when documented
}

m["bfj"] = {
	"Bafanji",
	"Q34890",
	"nic-grf",
	scripts = Latn,
}

m["bfk"] = {
	"Ban Khor Sign Language",
	"Q3441103",
	"sgn",
}

m["bfl"] = {
	"Banda-Ndélé",
	"Q34850",
	"bad",
	scripts = Latn,
}

m["bfm"] = {
	"Mmen",
	"Q36132",
	"nic-bod",
	scripts = Latn,
}

m["bfn"] = {
	"Bunak",
	"Q35101",
	"ngf",
	scripts = Latn,
}

m["bfo"] = {
	"Malba Birifor",
	"Q11150710",
	"nic-gur",
	scripts = Latn,
}

m["bfp"] = {
	"Beba",
	"Q35050",
	"nic-bod",
	scripts = Latn,
}

m["bfq"] = {
	"Badaga",
	"Q33205",
	"dra",
	scripts = {"Knda"},
}

m["bfr"] = {
	"Bazigar",
	"Q8829558",
	"dra",
}

m["bfs"] = {
	"Southern Bai",
	"Q12952250",
	"sit",
	otherNames = {"Dali Bai"},
	scripts = {"Hani", "Latn"},
}

m["bft"] = {
	"Balti",
	"Q33086",
	"tbq",
	scripts = {"Arab", "Tibt"},
	ancestors = {"xct"},
}

m["bfu"] = {
	"Gahri",
	"Q5516952",
	"tbq",
	scripts = {"Takr", "Tibt"},
}

m["bfw"] = {
	"Bondo",
	"Q2567942",
	"mun",
	otherNames = {"Remo"},
	scripts = {"Orya"},
}

m["bfx"] = {
	"Bantayanon",
	"Q16837866",
	"phi",
	scripts = Latn,
}

m["bfy"] = {
	"Bagheli",
	"Q2356364",
	"inc",
	scripts = Deva,
	ancestors = {"inc-mgd"},
	translit_module = "hi-translit",
}

m["bfz"] = {
	"Mahasu Pahari",
	"Q6733460",
	"inc-pah",
	scripts = Deva,
}

m["bga"] = {
	"Gwamhi-Wuri",
	"Q6707102",
	"nic-knj",
	otherNames = {"Wurə-Gwamhyə-Mba", "Lyase"},
	scripts = Latn,
}

m["bgb"] = {
	"Bobongko",
	"Q4935896",
	"poz-slb",
	scripts = Latn,
}

m["bgc"] = {
	"Haryanvi",
	"Q33410",
	"inc",
	scripts = Deva,
	ancestors = {"inc-ohi"},
	translit_module = "hi-translit",
}

m["bgd"] = {
	"Rathwi Bareli",
	"Q7295692",
	"inc",
	scripts = Deva,
}

m["bge"] = {
	"Bauria",
	"Q4873579",
	"inc",
	scripts = Deva,
}

m["bgf"] = {
	"Bangandu",
	"Q34938",
	"alv-sav",
	scripts = Latn,
}

m["bgg"] = {
	"Bugun",
	"Q3514220",
	"tbq",
	scripts = Latn,
}

m["bgi"] = {
	"Giangan",
	"Q4842057",
	"phi",
	scripts = Latn,
}

m["bgj"] = {
	"Bangolan",
	"Q34862",
	"nic-bod",
	scripts = Latn,
}

m["bgk"] = {
	"Bit",
	"Q2904868",
	"mkh-pal",
	scripts = Latn, -- also Hani?
}

m["bgl"] = {
	"Bo",
	"Q8845514",
	"mkh-vie",
	otherNames = {"Bo (Laos)"}, -- if 'bpw' is added, the disambig name will have to be made canonical
}

m["bgo"] = {
	"Baga Koga",
	"Q35695",
	"alv",
	scripts = Latn,
}

m["bgq"] = {
	"Bagri",
	"Q2426319",
	"inc",
	scripts = Deva,
	ancestors = {"raj"},
}

m["bgr"] = {
	"Bawm Chin",
	"Q56765",
	"tbq-kuk",
	otherNames = {"Bawm", "Banjogi"},
	scripts = Latn,
}

m["bgs"] = {
	"Tagabawa",
	"Q7675121",
	"mno",
	scripts = Latn,
}

m["bgt"] = {
	"Bughotu",
	"Q2927723",
	"poz-sls",
	otherNames = {"Bugotu"},
	scripts = Latn,
}

m["bgu"] = {
	"Mbongno",
	"Q36141",
	"nic-bod",
	scripts = Latn,
}

m["bgv"] = {
	"Warkay-Bipim",
	"Q4915439",
	"ngf",
	scripts = Latn,
}

m["bgw"] = {
	"Bhatri",
	"Q8841054",
	"inc",
	scripts = Deva,
	ancestors = {"inc-mgd"},
}

m["bgx"] = {
	"Balkan Gagauz Turkish",
	"Q2360396",
	"trk-ogz",
	otherNames = {"Balkan Turkic"},
	scripts = Latn,
}

m["bgy"] = {
	"Benggoi",
	"Q4887742",
	"poz-cet",
	scripts = Latn,
}

m["bgz"] = {
	"Banggai",
	"Q3441692",
	"poz-slb",
	scripts = Latn,
}

m["bha"] = {
	"Bharia",
	"Q4901287",
	"dra",
	scripts = Deva,
}

m["bhb"] = {
	"Bhili",
	"Q33229",
	"inc",
	scripts = Deva,
	ancestors = {"psu"},
}

m["bhc"] = {
	"Biga",
	"Q2902375",
	"poz-hce",
	scripts = Latn,
}

m["bhd"] = {
	"Bhadrawahi",
	"Q4900565",
	"inc-pah",
	otherNames = {"Bhadarwahi"},
	scripts = {"Arab", "Deva"},
}

m["bhe"] = {
	"Bhaya",
	"Q8841168",
	"inc",
	ancestors = {"raj"},
}

m["bhf"] = {
	"Odiai",
	"Q56690",
	"paa",
	scripts = Latn,
}

m["bhg"] = {
	"Binandere",
	"Q3503802",
	"ngf",
	scripts = Latn,
}

m["bhh"] = {
	"Bukhari",
	"Q56469",
	"ira-wes",
	otherNames = {"Bukhori", "Bukharian", "Bukharic", "Buchari", "Buchori", "Bucharian", "Bucharic"},
	scripts = {"Cyrl", "Hebr", "Latn", "fa-Arab"},
	ancestors = {"tg"},
}

m["bhi"] = {
	"Bhilali",
	"Q4901729",
	"inc",
	scripts = Deva,
	ancestors = {"psu"},
}

m["bhj"] = {
	"Bahing",
	"Q56442",
	"tbq",
	scripts = {"Deva", "Latn"},
}

m["bhl"] = {
	"Bimin",
	"Q4913743",
	"ngf-okk",
	scripts = Latn,
}

m["bhm"] = {
	"Bathari",
	"Q2586893",
	"sem-sar",
	scripts = Arab,
}

m["bhn"] = {
	"Bohtan Neo-Aramaic",
	"Q33230",
	"sem-ara",
}

m["bho"] = {
	"Bhojpuri",
	"Q33268",
	"inc",
	scripts = {"Deva", "Kthi"},
	ancestors = {"bh"},
	translit_module = "translit-redirect",
}

m["bhp"] = {
	"Bima",
	"Q2796873",
	"poz-cet",
	otherNames = {"Bimanese"},
	scripts = Latn,
}

m["bhq"] = {
	"Tukang Besi South",
	"Q12643975",
	"poz-mun",
	scripts = Latn,
}

m["bhs"] = {
	"Buwal",
	"Q3515065",
	"cdc-cbm",
	scripts = Latn,
}

m["bht"] = {
	"Bhattiyali",
	"Q4901452",
	"inc-pah",
	scripts = Deva,
}

m["bhu"] = {
	"Bhunjia",
	"Q8841766",
	"inc",
	scripts = {"Deva", "Orya"},
	ancestors = {"inc-mgd"},
}

m["bhv"] = {
	"Bahau",
	"Q3502039",
	"poz",
	scripts = Latn,
}

m["bhw"] = {
	"Biak",
	"Q1961488",
	"poz-hce",
	scripts = Latn,
}

m["bhx"] = { -- spurious?
	"Bhalay",
	"Q8840773",
	"inc",
	otherNames = {"Bhalay-Gowlan"},
}

m["bhy"] = {
	"Bhele",
	"Q4901671",
	"bnt",
	otherNames = {"Ebhele", "Piri", "Kipiri"},
	scripts = Latn,
}

m["bhz"] = {
	"Bada",
	"Q4840520",
	"poz-kal",
	otherNames = {"Bada (Indonesia)"},
	scripts = Latn,
}

m["bia"] = {
	"Badimaya",
	"Q3442745",
	"aus-psw",
	scripts = Latn,
}

m["bib"] = {
	"Bissa",
	"Q32934",
	"dmn",
	scripts = Latn,
}

m["bic"] = {
	"Bikaru",
	"Q56342",
	"ngf",
	scripts = Latn,
}

m["bid"] = {
	"Bidiyo",
	"Q56258",
	"cdc-est",
	scripts = Latn,
}

m["bie"] = {
	"Bepour",
	"Q4890914",
	"ngf-mad",
	scripts = Latn,
}

m["bif"] = {
	"Biafada",
	"Q35099",
	"alv-sng",
	scripts = Latn,
}

m["big"] = {
	"Biangai",
	"Q8842027",
	"paa",
	scripts = Latn,
}

m["bij"] = {
	"Kwanka",
	"Q35598",
	"alv",
	otherNames = {"Kwang", "Vaghat-Ya-Bijim-Legeri", "Vaghat", "Ya", "Bijim", "Legeri"},
	scripts = Latn,
}

m["bil"] = {
	"Bile",
	"Q34987",
	"bnt",
	otherNames = {"Bille"},
	scripts = Latn,
}

m["bim"] = {
	"Bimoba",
	"Q34971",
	"nic-gur",
	scripts = Latn,
}

m["bin"] = {
	"Edo",
	"Q35375",
	"alv-edo",
	otherNames = {"Bini"},
	scripts = Latn,
}

m["bio"] = {
	"Nai",
	"Q3508074",
	"paa",
	otherNames = {"Biaka"},
	scripts = Latn,
}

m["bip"] = {
	"Bila",
	"Q2902626",
	"bnt",
	otherNames = {"Forest Bira"},
	scripts = Latn,
}

m["biq"] = {
	"Bipi",
	"Q2904312",
	"poz-aay",
	scripts = Latn,
}

m["bir"] = {
	"Bisorio",
	"Q8844749",
	"ngf",
	scripts = Latn,
}

m["bit"] = {
	"Berinomo",
	"Q56447",
	"paa-spk",
	otherNames = {"Bitara"},
	scripts = Latn,
}

m["biu"] = {
	"Biete",
	"Q4904687",
	"tbq-kuk",
	scripts = Latn,
}

m["biv"] = {
	"Southern Birifor",
	"Q32859745",
	"nic-gur",
	scripts = Latn,
}

m["biw"] = {
	"Kol (Cameroon)",
	"Q35582",
	"bnt",
	otherNames = {"Kol"},
	scripts = Latn,
}

m["bix"] = {
	"Bijori",
	"Q3450686",
	"mun",
	scripts = Deva,
}

m["biy"] = {
	"Birhor",
	"Q3450469",
	"mun",
	scripts = Deva,
}

m["biz"] = {
	"Baloi",
	"Q3450590",
	"bnt",
	scripts = Latn,
}

m["bja"] = {
	"Budza",
	"Q3046889",
	"bnt",
	otherNames = {"Buja"},
	scripts = Latn,
}

m["bjb"] = {
	"Barngarla",
	"Q3439071",
	"aus-pam",
	otherNames = {"Parnkalla", "Banggarla", "Parnkala", "Parnkarla", "Barngala", "Bangala", "Bungala", "Bungela", "Banggala", "Bahngala", "Pankalla", "Punkalla", "Pangkala", "Pankarla", "Parkalla", "Pakarla", "Bungeha", "Bahanga-La", "Kortabina", "Arkaba-tura", "Port Lincon", "Kooapidna", "Punkirla", "Wanbirujurari", "Willara", "Willeuroo"},
	scripts = Latn,
}

m["bjc"] = {
	"Bariji",
	"Q4690919",
	"ngf",
	otherNames = {"Bareji", "Aga Bereho"},
	scripts = Latn,
}

m["bje"] = {
	"Biao-Jiao Mien",
	"Q3503800",
	"hmx-mie",
	otherNames = {"Biao Min", "Jiaogong Mian"},
	scripts = {"Hani", "Latn"},
}

m["bjf"] = {
	"Barzani Jewish Neo-Aramaic",
	"Q33234",
	"sem-ara",
	scripts = {"Hebr"}, -- maybe others
}

m["bjg"] = {
	"Bidyogo",
	"Q35365",
	"alv",
	otherNames = {"Bijago"},
	scripts = Latn,
}

m["bjh"] = {
	"Bahinemo",
	"Q56361",
	"paa-spk",
	scripts = Latn,
}

m["bji"] = {
	"Burji",
	"Q34999",
	"cus",
	scripts = {"Ethi"},
}

m["bjj"] = {
	"Kannauji",
	"Q2726867",
	"inc",
	scripts = Deva,
	ancestors = {"inc-ohi"},
}

m["bjk"] = {
	"Barok",
	"Q2884743",
	"poz-ocw",
	scripts = Latn,
}

m["bjl"] = {
	"Bulu (New Guinea)",
	"Q4997162",
	"poz-ocw",
	otherNames = {"Bulu (Papua New Guinea)", "Bulu"},
	scripts = Latn,
}

m["bjm"] = {
	"Bajelani",
	"Q4848866",
	"ira-wes",
	scripts = {"Latn", "Arab"},
	ancestors = {"hac"},
}

m["bjn"] = {
	"Banjarese",
	"Q33151",
	"poz-mly",
	otherNames = {"Banjar"},
	scripts = {"Latn", "Arab"},
}

m["bjo"] = {
	"Mid-Southern Banda",
	"Q42303990",
	"bad",
	scripts = Latn,
}

m["bjp"] = {
	"Fanamaket",
	nil,
	"poz-oce",
	scripts = Latn,
}

m["bjr"] = {
	"Binumarien",
	"Q538364",
	"paa-kag",
	scripts = Latn,
}

m["bjs"] = {
	"Bajan",
	"Q2524014",
	"crp",
	otherNames = {"Barbadian", "Barbadian Creole", "Barbadian Creole English"},
	scripts = Latn,
}

m["bjt"] = {
	"Balanta-Ganja",
	"Q19359034",
	"alv-sng",
	scripts = {"Arab", "Latn"},
}

m["bju"] = {
	"Busuu",
	"Q35046",
	"nic-bod",
	scripts = Latn,
}

m["bjv"] = {
	"Bedjond",
	"Q8829831",
	"csu-sar",
	scripts = Latn,
}

m["bjw"] = {
	"Bakwé",
	"Q34899",
	"kro",
	scripts = Latn,
}

m["bjx"] = {
	"Banao Itneg",
	"Q12627559",
	"phi",
	scripts = Latn,
}

m["bjy"] = {
	"Bayali",
	"Q4874263",
	"aus-pam",
	scripts = Latn,
}

m["bjz"] = {
	"Baruga",
	"Q2886189",
	"ngf",
	scripts = Latn,
}

m["bka"] = {
	"Kyak",
	"Q35653",
	"alv-sav",
	otherNames = {"Nyakyak", "Bambuka"},
	scripts = Latn,
}

m["bkc"] = {
	"Baka",
	"Q34905",
	"nic-ubg",
	otherNames = {"Baka (Cameroon)"},
	scripts = Latn,
}

m["bkd"] = {
	"Binukid",
	"Q4914553",
	"mno",
	scripts = Latn,
}

m["bkf"] = {
	"Beeke",
	"Q3441375",
	"bnt",
	scripts = Latn,
}

m["bkg"] = {
	"Buraka",
	"Q35066",
	"nic-ubg",
	scripts = Latn,
}

m["bkh"] = {
	"Bakoko",
	"Q34866",
	"bnt",
	scripts = Latn,
}

m["bki"] = {
	"Baki",
	"Q11024697",
	"poz-vnc",
	scripts = Latn,
}

m["bkj"] = {
	"Pande",
	"Q36263",
	"bnt",
	otherNames = {"Pande-Gongo"},
	scripts = Latn,
}

m["bkk"] = { -- written in Balti script
	"Brokskat",
	"Q2925988",
	"inc-dar",
}

m["bkl"] = {
	"Berik",
	"Q378743",
	"paa",
	scripts = Latn,
}

m["bkm"] = {
	"Kom (Cameroon)",
	"Q1656595",
	"nic-grf",
	otherNames = {"Kom"},
	scripts = Latn,
}

m["bkn"] = {
	"Bukitan",
	"Q3446774",
	"poz-bnn",
	otherNames = {"Bekatan", "Bakatan", "Baketan"}, 
	scripts = Latn,
}

m["bko"] = {
	"Kwa'",
	"Q35567",
	"bai",
	scripts = Latn,
}

m["bkp"] = {
	"Iboko",
	"Q35089",
	"bnt",
	otherNames = {"Boko", "Boko (Congo)", "Boko (Democratic Republic of the Congo)"},
	scripts = Latn,
}

m["bkq"] = {
	"Bakairí",
	"Q56846",
	"sai-car",
	otherNames = {"Bakairi", "Bacairí", "Bacairi"},
	scripts = Latn,
}

m["bkr"] = {
	"Bakumpai",
	"Q3436626",
	"poz-brw",
	scripts = Latn,
}

m["bks"] = {
	"Masbate Sorsogon",
	"Q16113356",
	"phi",
	scripts = Latn,
}

m["bkt"] = {
	"Boloki",
	"Q4144560",
	"bnt",
	scripts = Latn,
}

m["bku"] = {
	"Buhid",
	"Q1002956",
	"phi",
	scripts = {"Buhd"},
}

m["bkv"] = {
	"Bekwarra",
	"Q34954",
	"nic-bco",
	scripts = Latn,
}

m["bkw"] = {
	"Bekwel",
	"Q34950",
	"bnt",
	otherNames = {"Bekwil"},
	scripts = Latn,
}

m["bkx"] = {
	"Baikeno",
	"Q11200640",
	"poz-cet",
	scripts = Latn,
}

m["bky"] = {
	"Bokyi",
	"Q35087",
	"nic-bco",
	scripts = Latn,
}

m["bkz"] = {
	"Bungku",
	"Q2928207",
	"poz",
	scripts = Latn,
}

m["bla"] = {
	"Blackfoot",
	"Q33060",
	"alg",
	otherNames = {"Siksika", "Blackfeet"},
	scripts = Latn,
}

m["blb"] = {
	"Bilua",
	"Q35003",
	"ngf",
	scripts = Latn,
}

m["blc"] = {
	"Bella Coola",
	"Q977808",
	"sal",
	otherNames = {"Nuxálk", "Nuxalk"},
	scripts = Latn,
}

m["bld"] = {
	"Bolango",
	"Q3450578",
	"phi",
	scripts = Latn,
}

m["ble"] = {
	"Balanta-Kentohe",
	"Q56789",
	"alv-sng",
	scripts = Latn,
}

m["blf"] = {
	"Buol",
	"Q2928278",
	"phi",
	scripts = Latn,
}

m["blg"] = {
	"Balau",
	"Q4850134",
	"poz-mly",
	scripts = Latn,
}

m["blh"] = {
	"Kuwaa",
	"Q35579",
	"kro",
	otherNames = {"Belle", "Belleh", "Kowaao", "Kwaa"},
	scripts = Latn,
}

m["bli"] = {
	"Bolia",
	"Q34910",
	"bnt",
	otherNames = {"Lia"},
	scripts = Latn,
}

m["blj"] = {
	"Bolongan",
	"Q9229310",
	"poz",
	scripts = Latn,
}

m["blk"] = {
	"Pa'o Karen",
	"Q7121294",
	"kar",
	otherNames = {"Pa'o", "Black Karen"},
	scripts = {"Mymr"},
}

m["bll"] = {
	"Biloxi",
	"Q2903780",
	"sio",
	scripts = Latn,
}

m["blm"] = {
	"Beli",
	"Q56821",
	"csu",
	otherNames = {"Behli", "Beili", "Jur Beli", "Beli (Sudan)", "Beli (South Sudan)"},
	scripts = Latn,
}

m["bln"] = {
	"Southern Catanduanes Bicolano",
	"Q7569754",
	"phi",
	otherNames = {"Virac"},
	scripts = Latn,
}

m["blo"] = {
	"Anii",
	"Q34838",
	"alv-kwa",
	otherNames = {"Bassila", "Basila", "Baseca", "Ouinji-Ouinji", "Winji-Winji"},
	scripts = Latn,
}

m["blp"] = {
	"Blablanga",
	"Q2905245",
	"poz-ocw",
	scripts = Latn,
}

m["blq"] = {
	"Baluan-Pam",
	"Q2881675",
	"poz-aay",
	scripts = Latn,
}

m["blr"] = {
	"Blang",
	"Q4925096",
	"mkh-pal",
	otherNames = {"Bulang", "Pulang", "Kontoi", "Shinman"},
	scripts = {"Latn", "Tale", "Lana", "Thai"},
}

m["bls"] = {
	"Balaesang",
	"Q4849796",
	"poz",
	scripts = Latn,
}

m["blt"] = {
	"Tai Dam",
	"Q56407",
	"tai-swe",
	otherNames = {"Tai Noi", "Black Tai"},
	scripts = {"Tavt", "Latn"},
	--translit_module = "Tavt-translit",
	sort_key = {
		from = {"[꪿ꫀ꫁ꫂ]", "([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])"},
		to   = {"", "%2%1"}},
}

m["blv"] = {
	"Bolo",
	"Q4939959",
	"bnt",
	otherNames = {"Kibala", "Ngoya"},
	scripts = Latn,
}

m["blw"] = {
	"Balangao",
	"Q4850033",
	"phi",
	scripts = Latn,
}

m["blx"] = {
	"Mag-Indi Ayta",
	"Q1931221",
	"phi",
	scripts = Latn,
}

m["bly"] = {
	"Notre",
	"Q11009194",
	"nic-gur",
	otherNames = {"Nootre"},
	scripts = Latn,
}

m["blz"] = {
	"Balantak",
	"Q4850053",
	"poz-slb",
	scripts = Latn,
}

m["bma"] = {
	"Lame",
	"Q3913997",
	"bnt",
	scripts = Latn,
}

m["bmb"] = {
	"Bembe",
	"Q4885023",
	"bnt",
	otherNames = {"Bemba", "Kinyabemba"},
	scripts = Latn,
}


m["bmc"] = {
	"Biem",
	"Q4904523",
	"poz-ocw",
	scripts = Latn,
}

m["bmd"] = {
	"Baga Manduri",
	"Q35815",
	"alv",
	otherNames = {"Baga Maduri", "Baga Mandari"},
	scripts = Latn,
}

m["bme"] = {
	"Limassa",
	"Q11004666",
	"nic-ubg",
	scripts = Latn,
}

m["bmf"] = {
	"Bom",
	"Q35088",
	"alv",
	scripts = Latn,
}

m["bmg"] = {
	"Bamwe",
	"Q34867",
	"bnt",
	scripts = Latn,
}

m["bmh"] = {
	"Kein",
	"Q6383764",
	"ngf-mad",
	otherNames = {"Bemal"},
	scripts = Latn,
}

m["bmi"] = {
	"Bagirmi",
	"Q34903",
	"csu",
	scripts = Latn,
}

m["bmj"] = {
	"Bote-Majhi",
	"Q9229570",
	"inc",
	scripts = Deva,
}

m["bmk"] = {
	"Ghayavi",
	"Q5555976",
	"poz-ocw",
	scripts = Latn,
}

m["bml"] = {
	"Bomboli",
	"Q35055",
	"bnt",
	scripts = Latn,
}

m["bmn"] = {
	"Bina",
	"Q8843664",
	"poz-ocw",
	otherNames = {"Bina (New Guinea)", "Bina (Papua New Guinea)"},
	scripts = Latn,
}

m["bmo"] = {
	"Bambalang",
	"Q34868",
	"nic-bod",
	scripts = Latn,
}

m["bmp"] = {
	"Bulgebi",
	"Q4996380",
	"ngf-fin",
	scripts = Latn,
}

m["bmq"] = {
	"Bomu",
	"Q35065",
	"nic-gur",
	scripts = Latn,
}

m["bmr"] = {
	"Muinane",
	"Q3027894",
	scripts = Latn,
}

m["bmt"] = {
	"Biao Mon",
	"Q8842159",
	"hmx-mie",
}

m["bmu"] = {
	"Somba-Siawari",
	"Q5000983",
	"ngf",
	scripts = Latn,
}

m["bmv"] = {
	"Bum",
	"Q35058",
	"nic-grf",
	scripts = Latn,
}

m["bmw"] = {
	"Bomwali",
	"Q34984",
	"bnt",
	scripts = Latn,
}

m["bmx"] = {
	"Baimak",
	"Q3450546",
	"ngf-mad",
	scripts = Latn,
}

m["bmz"] = {
	"Baramu",
	"Q4858315",
	"ngf",
	scripts = Latn,
}

m["bna"] = {
	"Bonerate",
	"Q4941729",
	"poz-mun",
	scripts = Latn,
}

m["bnb"] = {
	"Bookan",
	"Q4943150",
	"poz-san",
	scripts = Latn,
}

m["bnd"] = {
	"Banda",
	"Q3504147",
	"poz-cet",
	otherNames = {"Banda (Indonesia)"},
	scripts = Latn,
}

m["bne"] = {
	"Bintauna",
	"Q4914533",
	"phi",
	scripts = Latn,
}

m["bnf"] = {
	"Masiwang",
	"Q6783305",
	"poz-cet",
	otherNames = {"Bonfia"},
	scripts = Latn,
}

m["bng"] = {
	"Benga",
	"Q34952",
	"bnt",
	scripts = Latn,
}

m["bni"] = {
	"Bangi",
	"Q34936",
	"bnt",
	otherNames = {"Bobangi", "Bubangi"},
	scripts = Latn,
}

m["bnj"] = {
	"Eastern Tawbuid",
	"Q18757427",
	"phi",
	scripts = Latn,
}

m["bnk"] = {
	"Bierebo",
	"Q2902029",
	"poz-vnc",
	scripts = Latn,
}

m["bnl"] = {
	"Boon",
	"Q56616",
	"cus",
	scripts = Latn,
}

m["bnm"] = {
	"Batanga",
	"Q34979",
	"bnt",
	scripts = Latn,
}

m["bnn"] = {
	"Bunun",
	"Q56505",
	"map",
	scripts = Latn,
}

m["bno"] = {
	"Asi",
	"Q29490",
	"phi",
	scripts = Latn,
}

m["bnp"] = {
	"Bola",
	"Q4938876",
	"poz-ocw",
	scripts = Latn,
}

m["bnq"] = {
	"Bantik",
	"Q2883521",
	"poz",
	scripts = Latn,
}

m["bnr"] = {
	"Butmas-Tur",
	"Q2928942",
	"poz-vnc",
	scripts = Latn,
}

m["bns"] = {
	"Bundeli",
	"Q56399",
	"inc",
	otherNames = {"Bundelkhandi"},
	scripts = Deva,
	ancestors = {"inc-ohi"},
	translit_module = "hi-translit",
}

m["bnu"] = {
	"Bentong",
	"Q4890644",
	"poz-ssw",
	scripts = Latn,
}

m["bnv"] = {
	"Beneraf",
	"Q4941733",
	"paa",
	scripts = Latn,
}

m["bnw"] = {
	"Bisis",
	"Q56356",
	"paa-spk",
	scripts = Latn,
}

m["bnx"] = {
	"Bangubangu",
	"Q3438330",
	"bnt",
	scripts = Latn,
}

m["bny"] = {
	"Bintulu",
	"Q3450775",
	"poz-swa",
	scripts = Latn,
}

m["bnz"] = {
	"Beezen",
	"Q35083",
	"nic-bco",
	scripts = Latn,
}

m["boa"] = {
	"Bora",
	"Q2375468",
	scripts = Latn,
}

m["bob"] = {
	"Aweer",
	"Q56526",
	"cus",
	scripts = Latn,
}

m["boe"] = {
	"Mundabli",
	"Q36127",
	"nic-bod",
	scripts = Latn,
}

m["bof"] = {
	"Bolon",
	"Q3913301",
	"dmn",
	scripts = Latn,
}

m["bog"] = {
	"Bamako Sign Language",
	"Q4853284",
	"sgn",
}

m["boh"] = {
	"Boma",
	"Q35080",
	"bnt",
	scripts = Latn,
}

m["boi"] = {
	"Barbareño",
	"Q56391",
	"nai-chu",
	scripts = Latn,
}

m["boj"] = {
	"Anjam",
	"Q3504136",
	"ngf-mad",
	scripts = Latn,
}

m["bok"] = {
	"Bonjo",
	"Q34942",
	"alv",
	scripts = Latn,
}

m["bol"] = {
	"Bole",
	"Q3436680",
	"cdc-wst",
	scripts = Latn,
}

m["bom"] = {
	"Berom",
	"Q35013",
	"alv",
	otherNames = {"Birom"},
	scripts = Latn,
}

m["bon"] = {
	"Bine",
	"Q4914077",
	"paa",
	scripts = Latn,
}

m["boo"] = {
	"Tiemacèwè Bozo",
	"Q12643582",
	"dmn",
	scripts = Latn, -- and others?
}

m["bop"] = {
	"Bonkiman",
	"Q4942134",
	"ngf-fin",
	scripts = Latn,
}

m["boq"] = {
	"Bogaya",
	"Q7207578",
	"ngf",
	scripts = Latn,
}

m["bor"] = {
	"Borôro",
	"Q32986",
	"sai-mje",
	scripts = Latn,
}

m["bot"] = {
	"Bongo",
	"Q2910067",
	"csu",
	scripts = Latn,
}

m["bou"] = {
	"Bondei",
	"Q4941378",
	"bnt",
	otherNames = {"Boondei", "Boondéi"},
	scripts = Latn,
}

m["bov"] = {
	"Tuwuli",
	"Q36974",
	"alv-kwa",
	otherNames = {"Bowili", "Bowiri", "Liwuli", "Siwuri", "Tuwili", "Tora"},
	scripts = Latn,
}

m["bow"] = {
	"Rema",
	"Q7311502",
	"paa",
	otherNames = {"Bothar"},
	scripts = Latn,
}

m["box"] = {
	"Buamu",
	"Q35157",
	"nic-gur",
	otherNames = {"Bwamu"},
	scripts = Latn,
}

m["boy"] = {
	"Bodo (Central Africa)",
	"Q4936715",
	"bnt",
	otherNames = {"Bodo (Central African Republic)", "Bodo"},
	scripts = Latn,
}

m["boz"] = {
	"Tiéyaxo Bozo",
	"Q32860401",
	"dmn",
	scripts = Latn,
}

m["bpa"] = {
	"Dakaka",
	"Q1157729",
	"poz-vnc",
	otherNames = {"Daakaka", "South Ambrym", "Baiap"},
	scripts = Latn,
}

m["bpb"] = {
	"Barbacoas",
	"Q2669202",
	"sai-bar",
	otherNames = {"Pasto"},
	scripts = Latn,
}

m["bpd"] = {
	"Banda-Banda",
	"Q3450674",
	"bad",
	scripts = Latn,
}

m["bpg"] = {
	"Bonggo",
	"Q4941860",
	"poz-ocw",
	scripts = Latn,
}

m["bph"] = {
	"Botlikh",
	"Q56560",
	"cau-ava",
	otherNames = {"Botlix"},
	scripts = Cyrl,
}

m["bpi"] = {
	"Bagupi",
	"Q3450697",
	"ngf-mad",
	scripts = Latn,
}

m["bpj"] = {
	"Binji",
	"Q4914403",
	"bnt",
	scripts = Latn,
}

m["bpk"] = {
	"Orowe",
	"Q7103905",
	"poz-cln",
	scripts = Latn,
}

m["bpl"] = {
	"Broome Pearling Lugger Pidgin",
	"Q4975277",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["bpm"] = {
	"Biyom",
	"Q4919327",
	"ngf-mad",
	scripts = Latn,
}

m["bpn"] = {
	"Dzao Min",
	"Q3042189",
	"hmx-mie",
}

m["bpo"] = {
	"Anasi",
	"Q11207813",
	"paa",
	scripts = Latn,
}

m["bpp"] = {
	"Kaure",
	"Q20526532",
	"paa",
	scripts = Latn,
}

m["bpq"] = {
	"Banda Malay",
	"Q12473442",
	"crp",
	scripts = Latn,
}

m["bpr"] = {
	"Koronadal Blaan",
	"Q16115430",
	"phi",
	scripts = Latn,
}

m["bps"] = {
	"Sarangani Blaan",
	"Q16117272",
	"phi",
	scripts = Latn,
}

m["bpt"] = {
	"Barrow Point",
	"Q2567916",
	"aus-pmn",
	scripts = Latn,
}

m["bpu"] = {
	"Bongu",
	"Q4941930",
	"ngf-mad",
	scripts = Latn,
}

m["bpv"] = {
	"Bian Marind",
	"Q8841889",
	"ngf",
	scripts = Latn,
}

m["bpx"] = {
	"Palya Bareli",
	"Q7128872",
	"inc",
}

m["bpy"] = {
	"Bishnupriya Manipuri",
	"Q37059",
	"inc",
	otherNames = {"Bishnupriya", "Manipuri Bishnupriya"},
	scripts = {"Beng"},
	ancestors = {"inc-mgd"},
}

m["bpz"] = {
	"Bilba",
	"Q8843362",
	"poz-cet",
	scripts = Latn,
}

m["bqa"] = {
	"Tchumbuli",
	"Q11008162",
	"alv-kwa",
	scripts = Latn,
}

m["bqb"] = {
	"Bagusa",
	"Q4842178",
	"paa",
	scripts = Latn,
}

m["bqc"] = {
	"Boko",
	"Q34983",
	"dmn",
	otherNames = {"Boko (Benin)"},
	scripts = Latn,
}

m["bqd"] = {
	"Bung",
	"Q3436612",
	scripts = Latn,
}

m["bqf"] = {
	"Baga Kaloum",
	"Q3502293",
	"alv",
	scripts = Latn,
}

m["bqg"] = {
	"Bago-Kusuntu",
	"Q34878",
	"alv",
}

m["bqh"] = {
	"Baima",
	"Q674990",
	"sit-qia",
}

m["bqi"] = {
	"Bakhtiari",
	"Q257829",
	"ira-wes",
	scripts = {"fa-Arab"},
	ancestors = {"pal"},
}

m["bqj"] = {
	"Bandial",
	"Q34872",
	scripts = Latn,
}

m["bqk"] = {
	"Banda-Mbrès",
	"Q3450724",
	scripts = Latn,
}

m["bql"] = {
	"Bilakura",
	"Q4907504",
	"ngf-mad",
	scripts = Latn,
}

m["bqm"] = {
	"Wumboko",
	"Q37051",
	scripts = Latn,
}

m["bqn"] = {
	"Bulgarian Sign Language",
	"Q3438325",
	"sgn",
}

m["bqo"] = {
	"Balo",
	"Q34865",
	"nic-grf",
	scripts = Latn,
}

m["bqp"] = {
	"Busa",
	"Q35185",
	"dmn",
	scripts = Latn,
}

m["bqq"] = {
	"Biritai",
	"Q56382",
	scripts = Latn,
}

m["bqr"] = {
	"Burusu",
	"Q5001028",
	"poz-san",
	scripts = Latn,
}

m["bqs"] = {
	"Bosngun",
	"Q56838",
	"paa",
	scripts = Latn,
}

m["bqt"] = {
	"Bamukumbit",
	"Q35078",
	"nic-bod",
	scripts = Latn,
}

m["bqu"] = {
	"Boguru",
	"Q3438444",
	scripts = Latn,
}

m["bqv"] = {
	"Begbere-Ejar",
	"Q7194098",
	scripts = Latn,
}

m["bqw"] = {
	"Buru (Nigeria)",
	"Q1017152",
	"nic-bod",
	otherNames = {"Buru"},
	scripts = Latn,
}

m["bqx"] = {
	"Baangi",
	"Q3450648",
	scripts = Latn,
}

m["bqy"] = {
	"Bengkala Sign Language",
	"Q3322119",
	"sgn",
}

m["bqz"] = {
	"Bakaka",
	"Q34855",
	scripts = Latn,
}

m["bra"] = {
	"Брај",
	"Q35243",
	"inc",
	otherNames = {"Braj Bhasha"},
	scripts = Deva,
	ancestors = {"inc-ohi"},
	translit_module = "hi-translit",
}


m["brb"] = {
	"Lave",
	"Q4957737",
	"mkh-ban",
	otherNames = {"Laveh", "Rawe", "Brao"},
}

m["brc"] = {
	"Berbice Creole Dutch",
	"Q35215",
	"crp",
	otherNames = {"Berbice Dutch", "Berbice Dutch Creole", "Berbice Creole"},
	scripts = Latn,
	ancestors = {"nl"},
}

m["brd"] = {
	"Baraamu",
	"Q56804",
	scripts = Deva,
}

m["brf"] = {
	"Bera",
	"Q2896850",
	scripts = Latn,
}

m["brg"] = {
	"Baure",
	"Q2839722",
	"awd",
	otherNames = {"Bauré"},
	scripts = Latn,
}

m["brh"] = {
	"Brahui",
	"Q33202",
	"dra",
	scripts = {"Arab", "Latn"},
}

m["bri"] = {
	"Mokpwe",
	"Q36428",
	"bnt",
	scripts = Latn,
}

m["brj"] = {
	"Bieria",
	"Q4904607",
	"poz-vnc",
	scripts = Latn,
}

m["brk"] = {
	"Birgid",
	"Q56823",
	"nub",
	otherNames = {"Birked"},
	scripts = Latn,
}

m["brl"] = {
	"Birwa",
	"Q3501019",
	scripts = Latn,
}

m["brm"] = {
	"Barambu",
	"Q34893",
	"znd",
	scripts = Latn,
}

m["brn"] = {
	"Boruca",
	"Q4946773",
	scripts = Latn,
}

m["bro"] = {
	"Brokkat",
	"Q56605",
	scripts = {"Tibt", "Latn"},
}

m["brp"] = {
	"Barapasi",
	"Q56995",
	scripts = Latn,
}

m["brq"] = {
	"Breri",
	"Q4961835",
	"paa",
	scripts = Latn,
}

m["brr"] = {
	"Birao",
	"Q2904383",
	"poz-sls",
	scripts = Latn,
}

m["brs"] = {
	"Baras",
	"Q8827053",
	otherNames = {"Ende", "West Kaili"},
	scripts = Latn,
}

m["brt"] = {
	"Bitare",
	"Q34946",
	"nic-bod",
	otherNames = {"Njwande"},
	scripts = Latn,
}

m["bru"] = {
	"Eastern Bru",
	"Q16115463",
	"mkh-kat",
	scripts = {"Latn", "Laoo", "Thai"},
}

m["brv"] = {
	"Western Bru",
	"Q16113806",
	"mkh-kat",
	scripts = {"Latn", "Laoo"},
}

m["brw"] = {
	"Bellari",
	"Q4883496",
	"dra",
}

m["brx"] = {
	"Bodo (India)",
	"Q33223",
	"tbq",
	otherNames = {"Bodo", "Mech"},
	scripts = {"Deva", "Latn"},
}

m["bry"] = {
	"Burui",
	"Q5000976",
	scripts = Latn,
}

m["brz"] = {
	"Bilbil",
	"Q4907473",
	"poz-ocw",
	scripts = Latn,
}

m["bsa"] = {
	"Abinomn",
	"Q56648",
	scripts = Latn,
}

m["bsb"] = {
	"Brunei Bisaya",
	"Q3450611",
	scripts = Latn,
}

m["bsc"] = {
	"Bassari",
	"Q35098",
	scripts = Latn,
}

m["bse"] = {
	"Wushi",
	"Q36973",
	scripts = Latn,
}

m["bsf"] = {
	"Bauchi",
	"Q34974",
	"nic-knj",
	scripts = Latn,
}

m["bsg"] = {
	"Bashkardi",
	"Q33030",
	"ira-wes",
	scripts = {"fa-Arab", "Latn"},
}

m["bsh"] = {
	"Kati",
	"Q2605045",
	"iir-nur",
	scripts = Arab,
}

m["bsi"] = {
	"Bassossi",
	"Q34940",
	scripts = Latn,
}

m["bsj"] = {
	"Bangwinji",
	"Q3446631",
	scripts = Latn,
}

m["bsk"] = {
	"Burushaski",
	"Q216286",
	"qfa-iso",
	scripts = Latn,
}

m["bsl"] = {
	"Basa-Gumna",
	"Q4866150",
	"nic-knj",
	scripts = Latn,
}

m["bsm"] = {
	"Busami",
	"Q5001255",
	"poz-hce",
	scripts = Latn,
}

m["bsn"] = {
	"Barasana",
	"Q2883843",
	"sai-tuc",
	scripts = Latn,
}

m["bso"] = {
	"Buso",
	"Q3441370",
	scripts = Latn,
}

m["bsp"] = {
	"Baga Sitemu",
	"Q36466",
	scripts = Latn,
}

m["bsq"] = {
	"Bassa",
	"Q34949",
	"kro",
	scripts = {"Latn", "Bass"},
}

m["bsr"] = {
	"Bassa-Kontagora",
	"Q4866152",
	scripts = Latn,
}

m["bss"] = {
	"Akoose",
	"Q34806",
	"bnt",
	scripts = Latn,
}

m["bst"] = {
	"Basketo",
	"Q56531",
	"omv",
	otherNames = {"Basketto", "Baskatta", "Mesketo", "Misketto"},
	scripts = {"Ethi"},
}

m["bsu"] = {
	"Bahonsuai",
	"Q2879298",
	scripts = Latn,
}

m["bsv"] = {
	"Baga Sobané",
	"Q3450433",
	scripts = Latn,
}

m["bsw"] = {
	"Baiso",
	"Q56615",
	"cus",
	scripts = Latn,
}

m["bsx"] = {
	"Yangkam",
	"Q36922",
	"nic-bod",
	scripts = Latn,
}

m["bsy"] = {
	"Sabah Bisaya",
	"Q12641557",
	scripts = Latn,
}

m["bta"] = {
	"Bata",
	"Q56254",
	scripts = Latn,
}

m["btc"] = {
	"Bati (Cameroon)",
	"Q34944",
	"nic-bco",
	otherNames = {"Bati"},
	scripts = Latn,
}

m["btd"] = {
	"Dairi Batak",
	"Q2891045",
	"btk",
	otherNames = {"Batak Dairi"},
	scripts = {"Latn", "Batk"},
}

m["bte"] = {
	"Gamo-Ningi",
	"Q5520366",
	"nic-knj",
	scripts = Latn,
}

m["btf"] = {
	"Birgit",
	"Q56302",
	"cdc-est",
	scripts = Latn,
}

m["btg"] = {
	"Gagnoa Bété",
	"Q11005602",
	scripts = Latn,
}

m["bth"] = {
	"Biatah Bidayuh",
	"Q2900881",
	scripts = Latn,
}

m["bti"] = {
	"Burate",
	"Q56900",
	scripts = Latn,
}

m["btj"] = {
	"Bacanese Malay",
	"Q8828608",
	"poz-mly",
	scripts = Latn,
}

m["btm"] = {
	"Mandailing Batak",
	"Q2891049",
	"btk",
	otherNames = {"Batak Mandailing"},
	scripts = {"Latn", "Batk"},
}

m["btn"] = {
	"Ratagnon",
	"Q13197",
	"phi",
	scripts = Latn,
}

m["bto"] = {
	"Iriga Bicolano",
	"Q12633026",
	"phi",
	scripts = Latn,
}

m["btp"] = {
	"Budibud",
	"Q4985086",
	"poz-ocw",
	scripts = Latn,
}

m["btq"] = {
	"Batek",
	"Q860315",
	scripts = Latn,
}

m["btr"] = {
	"Baetora",
	"Q2878874",
	scripts = Latn,
}

m["bts"] = {
	"Simalungun Batak",
	"Q2891054",
	"btk",
	otherNames = {"Batak Simalungun"},
	scripts = {"Latn", "Batk"},
}

m["btt"] = {
	"Bete-Bendi",
	"Q4887064",
	"nic-bco",
	scripts = Latn,
}

m["btu"] = {
	"Batu",
	"Q34964",
	"nic-bod",
	scripts = Latn,
}

m["btv"] = {
	"Bateri",
	"Q3812564",
	scripts = Deva,
}

m["btw"] = {
	"Butuanon",
	"Q5003156",
	"phi",
	scripts = Latn,
}

m["btx"] = {
	"Karo Batak",
	"Q33012",
	"btk",
	otherNames = {"Batak Karo"},
	scripts = {"Latn", "Batk"},
}

m["bty"] = {
	"Bobot",
	"Q3446788",
	"poz-cet",
	scripts = Latn,
}

m["btz"] = {
	"Alas-Kluet Batak",
	"Q2891042",
	"btk",
	otherNames = {"Batak Alas-Kluet"},
	scripts = {"Latn", "Batk"},
}

m["bua"] = {
	"Buryat",
	"Q33120",
	"xgn",
	otherNames = {"Buriat"},
	scripts = Cyrl,
	translit_module = "bua-translit",
	override_translit = true,
	wikimedia_codes = {"bxr"},
}

m["bub"] = {
	"Bua",
	"Q32928",
	scripts = Latn,
}

m["bud"] = {
	"Ntcham",
	"Q36266",
	"nic-gur",
	otherNames = {"Tobote", "Ncam", "Basar", "Basari"},
	scripts = Latn,
}

m["bue"] = {
	"Beothuk",
	"Q56234",
	scripts = Latn,
}

m["buf"] = {
	"Bushoong",
	"Q3449964",
	scripts = Latn,
}

m["bug"] = {
	"Buginese",
	"Q33190",
	"poz-ssw",
	scripts = {"Bugi", "Latn"},
}

m["buh"] = {
	"Younuo Bunu",
	"Q56299",
	"hmn",
	otherNames = {"Yuno"},
	scripts = Latn,
}

m["bui"] = {
	"Bongili",
	"Q35084",
	"bnt",
	scripts = Latn,
}

m["buj"] = {
	"Basa-Gurmana",
	"Q6432515",
	"nic-knj",
	scripts = Latn,
}

m["buk"] = {
	"Bukawa",
	"Q35043",
	"poz-ocw",
	otherNames = {"Bukaua", "Bugawac", "Gawac"},
	scripts = Latn,
}

m["bum"] = {
	"Bulu (Cameroon)",
	"Q35028",
	"bnt",
	otherNames = {"Bulu"},
	scripts = Latn,
}

m["bun"] = {
	"Sherbro",
	"Q36339",
	scripts = Latn,
}

m["buo"] = {
	"Terei",
	"Q56831",
	scripts = Latn,
}

m["bup"] = {
	"Busoa",
	"Q5002001",
	scripts = Latn,
}

m["buq"] = {
	"Brem",
	"Q4960502",
	"ngf",
	otherNames = {"Barem", "Bunabun", "Bububun", "Bunubun"},
	scripts = Latn,
}

m["bus"] = {
	"Bokobaru",
	"Q9228931",
	"dmn",
	scripts = Latn,
}

m["but"] = {
	"Bungain",
	"Q3450623",
	"qfa-tor",
	scripts = Latn,
}

m["buu"] = {
	"Budu",
	"Q3450207",
	scripts = Latn,
}

m["buv"] = {
	"Bun",
	"Q56351",
	scripts = Latn,
}

m["buw"] = {
	"Bubi",
	"Q35017",
	"bnt",
	scripts = Latn,
}

m["bux"] = {
	"Boghom",
	"Q3440412",
	"cdc-wst",
	scripts = Latn,
}

m["buy"] = {
	"Mmani",
	"Q35061",
	otherNames = {"Mani", "Bullom So", "Mandingi"},
	scripts = Latn,
}

m["bva"] = {
	"Barein",
	"Q56285",
	scripts = Latn,
}

m["bvb"] = {
	"Bube",
	"Q35110",
	"bnt",
	scripts = Latn,
}

m["bvc"] = {
	"Baelelea",
	"Q2878833",
	"poz-sls",
	scripts = Latn,
}

m["bvd"] = {
	"Baeggu",
	"Q2878850",
	"poz-sls",
	otherNames = {"Mbaenggu", "Baegu"},
	scripts = Latn,
}

m["bve"] = {
	"Berau Malay",
	"Q3915770",
	"poz-mly",
	scripts = Latn,
}

m["bvf"] = {
	"Boor",
	"Q56250",
	scripts = Latn,
}

m["bvg"] = {
	"Bonkeng",
	"Q34958",
	scripts = Latn,
}

m["bvh"] = {
	"Bure",
	"Q56294",
	"cdc",
	scripts = Latn,
}

m["bvi"] = {
	"Belanda Viri",
	"Q35247",
	scripts = Latn,
}

m["bvj"] = {
	"Baan",
	"Q3515067",
	"nic-bco",
	scripts = Latn,
}

m["bvk"] = {
	"Bukat",
	"Q4986814",
	"poz-bnn",
	scripts = Latn,
}

m["bvl"] = {
	"Bolivian Sign Language",
	"Q1783590",
	"sgn",
	scripts = Latn, -- when documented
}

m["bvm"] = {
	"Bamunka",
	"Q34882",
	scripts = Latn,
}

m["bvn"] = {
	"Buna",
	"Q3450516",
	"qfa-tor",
	scripts = Latn,
}

m["bvo"] = {
	"Bolgo",
	"Q35038",
	scripts = Latn,
}

m["bvp"] = {
	"Bumang",
	"Q4997235",
	"mkh-pal",
}

m["bvq"] = {
	"Birri",
	"Q56514",
	scripts = Latn,
}

m["bvr"] = {
	"Burarra",
	"Q4998124",
	"aus-arn",
	scripts = Latn,
}

m["bvt"] = {
	"Bati (Indonesia)",
	"Q4869253",
	"poz",
	otherNames = {"Bati"},
	scripts = Latn,
}

m["bvu"] = {
	"Bukit Malay",
	"Q9230148",
	scripts = Latn,
}

m["bvv"] = {
	"Baniva",
	"Q3515198",
	"awd",
	scripts = Latn,
}

m["bvw"] = {
	"Boga",
	"Q56262",
	scripts = Latn,
}

m["bvx"] = {
	"Babole",
	"Q35180",
	"bnt",
	otherNames = {"Dibole", "Bole"},
	scripts = Latn,
}

m["bvy"] = {
	"Baybayanon",
	"Q16839275",
	"phi",
	otherNames = {"Babay", "Utudnon", "Leyte"},
	scripts = Latn,
}

m["bvz"] = {
	"Bauzi",
	"Q56360",
	scripts = Latn,
}

m["bwa"] = {
	"Bwatoo",
	"Q9232446",
	"poz-cln",
	scripts = Latn,
}

m["bwb"] = {
	"Namosi-Naitasiri-Serua",
	"Q3130290",
	"poz-occ",
	scripts = Latn,
}

m["bwc"] = {
	"Bwile",
	"Q3447440",
	"bnt",
	scripts = Latn,
}

m["bwd"] = {
	"Bwaidoka",
	"Q2929111",
	"poz-ocw",
	otherNames = {"Bwaidoga"},
	scripts = Latn,
}

m["bwe"] = {
	"Bwe Karen",
	"Q56994",
}

m["bwf"] = {
	"Boselewa",
	"Q4947229",
	"poz-ocw",
	otherNames = {"Bosilewa"},
	scripts = Latn,
}

m["bwg"] = {
	"Barwe",
	"Q8826802",
	scripts = Latn,
}

m["bwh"] = {
	"Bishuo",
	"Q34973",
	"nic-bod",
	scripts = Latn,
}

m["bwi"] = {
	"Baniwa",
	"Q3501735",
	"awd-nwk",
	otherNames = {"Baniba", "Baniva", "Carutana", "Carútana", "Carúzana", "Izaneni", "Karu", "Tapuya"},
	scripts = Latn,
}

m["bwj"] = {
	"Láá Láá Bwamu",
	"Q11017275",
	scripts = Latn,
}

m["bwk"] = {
	"Bauwaki",
	"Q4873607",
	"ngf",
	scripts = Latn,
}

m["bwl"] = {
	"Bwela",
	"Q5003678",
	"bnt",
	scripts = Latn,
}

m["bwm"] = {
	"Biwat",
	"Q56352",
	"ngf",
	otherNames = {"Mundugumor"},
	scripts = Latn,
}

m["bwn"] = {
	"Wunai Bunu",
	"Q56452",
	"hmn",
	otherNames = {"Hm Nai", "Ng-nai", "Wunai"},
}

m["bwo"] = {
	"Shinasha",
	"Q56260",
	otherNames = {"Boro", "Boro (Ethiopia)", "Borna", "Bworo", "Sinicho"},
	scripts = Latn,
}

m["bwp"] = {
	"Mandobo Bawah",
	"Q12636155",
	scripts = Latn,
}

m["bwq"] = {
	"Southern Bobo",
	"Q11001714",
	"dmn",
	otherNames = {"Bobo Madaré", "Southern Bobo Madaré", "Bobo", "Syabéré", "Sya", "Benge", "Sogokiré", "Voré", "Zara", "Bobo Jula", "Jula"},
	scripts = Latn,
}

m["bwr"] = {
	"Bura",
	"Q56552",
	"cdc-cbm",
	otherNames = {"Bura-Pabir", "Pabir", "Burra"},
	scripts = Latn,
}

m["bws"] = {
	"Bomboma",
	"Q9229429",
	"bnt",
	scripts = Latn,
}

m["bwt"] = {
	"Bafaw-Balong",
	"Q34853",
	scripts = Latn,
}

m["bwu"] = {
	"Buli (Ghana)",
	"Q35085",
	"nic-gur",
	otherNames = {"Buli"},
	scripts = Latn,
}

m["bww"] = {
	"Bwa",
	"Q3515058",
	scripts = Latn,
}

m["bwx"] = {
	"Bu-Nao Bunu",
	"Q56411",
	"hmn",
	otherNames = {"Bu Nao", "Bunu", "Dongnu", "Dahua Dongnu", "Tung Nu", "Bunuo", "Pu No", "Naoklao", "Baonao", "Nao Klao", "Numao", "Nu Mhou", "Nunu", "Lingyun Nunu", "Nu Nu"},
	scripts = Latn,
}

m["bwy"] = {
	"Cwi Bwamu",
	"Q11150714",
	"nic-gur",
	scripts = Latn,
}

m["bwz"] = {
	"Bwisi",
	"Q35067",
	scripts = Latn,
}

m["bxa"] = {
	"Bauro",
	"Q2892068",
	"poz-sls",
	otherNames = {"Tairaha"},
	scripts = Latn,
}

m["bxb"] = {
	"Belanda Bor",
	"Q56678",
	"sdv",
	scripts = Latn,
}

m["bxc"] = {
	"Molengue",
	"Q13345",
	scripts = Latn,
}

m["bxd"] = {
	"Pela",
	"Q57000",
	"tbq-brm",
}

m["bxe"] = {
	"Ongota",
	"Q36344",
	"cus",
	otherNames = {"Birale", "Birayle"},
	scripts = Latn,
}

m["bxf"] = {
	"Bilur",
	"Q2903788",
	"poz-ocw",
	scripts = Latn,
}

m["bxg"] = {
	"Bangala",
	"Q34989",
	"bnt",
	otherNames = {"Ngala"},
	scripts = Latn,
}

m["bxh"] = {
	"Buhutu",
	"Q4986329",
	"poz-ocw",
	scripts = Latn,
}

m["bxi"] = {
	"Pirlatapa",
	"Q10632195",
	"aus-kar",
	scripts = Latn,
}

m["bxj"] = {
	"Bayungu",
	"Q10427485",
	"aus-psw",
	scripts = Latn,
}

m["bxk"] = {
	"Bukusu",
	"Q32930",
	"bnt",
	scripts = Latn,
}

m["bxl"] = {
	"Jalkunan",
	"Q11009787",
	scripts = Latn,
}

m["bxn"] = {
	"Burduna",
	"Q4998313",
	"aus-psw",
	scripts = Latn,
}

m["bxo"] = {
	"Barikanchi",
	"Q3450802",
	otherNames = {"Barikanci", "Barikanchi Pidgin"},
	scripts = Latn,
}

m["bxp"] = {
	"Bebil",
	"Q34941",
	scripts = Latn,
}

m["bxq"] = {
	"Beele",
	"Q56238",
	"cdc-wst",
	scripts = Latn,
}

m["bxs"] = {
	"Busam",
	"Q35189",
	"nic-grf",
	scripts = Latn,
}

m["bxv"] = {
	"Berakou",
	"Q56796",
	scripts = Latn,
}

m["bxw"] = {
	"Banka",
	"Q3438402",
	"dmn",
	otherNames = {"Bankagooma"},
	scripts = Latn,
}

m["bxz"] = {
	"Binahari",
	"Q4913840",
	scripts = Latn,
}

m["bya"] = {
	"Palawan Batak",
	"Q3450443",
	"phi",
	otherNames = {"Batak"},
	scripts = {"Tagb"},
}

m["byb"] = {
	"Bikya",
	"Q33257",
	"nic-bod",
	scripts = Latn,
}

m["byc"] = {
	"Ubaghara",
	"Q36625",
	"nic-bco",
	scripts = Latn,
}

m["byd"] = {
	"Benyadu'",
	"Q11173588",
	scripts = Latn,
}

m["bye"] = {
	"Pouye",
	"Q7235814",
	scripts = Latn,
}

m["byf"] = {
	"Bete",
	"Q32932",
	scripts = Latn,
}

m["byg"] = {
	"Baygo",
	"Q56836",
	"sdv",
	scripts = Latn,
}

m["byh"] = {
	"Bujhyal",
	"Q56317",
	scripts = Deva,
}

m["byi"] = {
	"Buyu",
	"Q5003401",
	otherNames = {"Buya"},
	scripts = Latn,
}

m["byj"] = {
	"Binawa",
	"Q4913807",
	"nic-knj",
	otherNames = {"Bina", "Bina (Nigeria)"},
	scripts = Latn,
}

m["byk"] = {
	"Biao",
	"Q4902547",
	scripts = Latn, -- also Hani?
}

m["byl"] = {
	"Bayono",
	"Q3503856",
	scripts = Latn,
}

m["bym"] = {
	"Bidyara",
	"Q8842355",
	"aus-pam",
	scripts = Latn,
}

m["byn"] = {
	"Blin",
	"Q56491",
	"cus",
	otherNames = {"Bilin", "Bilen", "Belen", "Bilein"},
	scripts = {"Ethi", "Latn"},
	translit_module = "Ethi-translit",
}

m["byo"] = {
	"Biyo",
	"Q56848",
	"tbq-lol",
	otherNames = {"Piyo", "Biyue"},
	scripts = {"Latn", "Hani"},
}

m["byp"] = {
	"Bumaji",
	"Q4997234",
	"nic-bco",
	scripts = Latn,
}

m["byq"] = {
	"Basay",
	"Q716647",
	"map",
	otherNames = {"Basai"},
	scripts = Latn,
}

m["byr"] = {
	"Baruya",
	"Q3450812",
	"ngf",
	scripts = Latn,
}

m["bys"] = {
	"Burak",
	"Q4998097",
	scripts = Latn,
}

m["byt"] = {
	"Berti",
	"Q35008",
	"ssa-sah",
	scripts = Latn,
}

m["byv"] = {
	"Medumba",
	"Q36019",
	"bai",
	scripts = Latn,
}

m["byw"] = {
	"Belhariya",
	"Q32961",
	scripts = Deva,
}

m["byx"] = {
	"Qaqet",
	"Q3503009",
	otherNames = {"Kakat", "Baining"},
	scripts = Latn,
}

m["byz"] = {
	"Banaro",
	"Q56858",
	"paa",
	scripts = Latn,
}

m["bza"] = {
	"Bandi",
	"Q34912",
	"dmn",
	otherNames = {"Gbandi"},
	scripts = Latn,
}

m["bzb"] = {
	"Andio",
	"Q4754487",
	"poz-slb",
	scripts = Latn,
}

m["bzd"] = {
	"Bribri",
	"Q28400",
	"cba",
	scripts = Latn,
}

m["bze"] = {
	"Jenaama Bozo",
	"Q10950633",
	"dmn",
	scripts = Latn,
}

m["bzf"] = {
	"Boikin",
	"Q56829",
	scripts = Latn,
}

m["bzg"] = {
	"Babuza",
	"Q716615",
	"map",
	otherNames = {"Favorlang", "Poavosa", "Taokas"},
}

m["bzh"] = {
	"Mapos Buang",
	"Q2927370",
	"poz-ocw",
	scripts = Latn,
}

m["bzi"] = {
	"Bisu",
	"Q56852",
	"tbq-lol",
	scripts = {"Latn", "Thai"},
}

m["bzj"] = {
	"Belizean Creole",
	"Q1363055",
	otherNames = {"Belizean Creole English", "Belizean Kriol", "Belize Kriol English", "Kriol"},
	scripts = Latn,
}

m["bzk"] = {
	"Nicaraguan Creole",
	"Q3504097",
	otherNames = {"Nicaraguan Creole English", "Nicaragua Creole English"},
	scripts = Latn,
}

m["bzl"] = {  -- supposedly also called "Bolano", but I can find no evidence of that
	"Boano (Sulawesi)",
	"Q4931258",
	"poz",
	otherNames = {"Boano", "Austronesian Boano", "Totoli Boano"},
	scripts = Latn,
}

m["bzm"] = {
	"Bolondo",
	"Q35071",
	"bnt",
	scripts = Latn,
}

m["bzn"] = {
	"Boano (Maluku)",
	"Q4931255",
	"poz",
	otherNames = {"Boano", "Austronesian Boano", "Seram Boano"},
	scripts = Latn,
}

m["bzo"] = {
	"Bozaba",
	"Q4952785",
	"bnt",
	scripts = Latn,
}

m["bzp"] = {
	"Kemberano",
	"Q12634399",
	"ngf-sbh",
	scripts = Latn,
}

m["bzq"] = {
	"Buli (Indonesia)",
	"Q2927952",
	"poz-hce",
	otherNames = {"Buli"},
	scripts = Latn,
}

m["bzr"] = {
	"Biri",
	"Q4087011",
	"aus-pam",
	scripts = Latn,
}

m["bzs"] = {
	"Brazilian Sign Language",
	"Q3436689",
	"sgn",
	otherNames = {"LGB", "LSB", "LSCB", "Libras"},
	scripts = Latn,
}

m["bzu"] = {
	"Burmeso",
	"Q56746",
	scripts = Latn,
}

m["bzv"] = {
	"Bebe",
	"Q34977",
	"nic-bod",
	otherNames = {"Naami"},
	scripts = Latn,
}

m["bzw"] = {
	"Basa",
	"Q34898",
	"nic-knj",
	otherNames = {"Basa (Nigeria)", "Basa-Benue"},
	scripts = Latn,
}

m["bzx"] = {
	"Hainyaxo Bozo",
	"Q11159536",
	"dmn",
	scripts = Latn,
}

m["bzy"] = {
	"Obanliku",
	"Q36276",
	"nic-bco",
	scripts = Latn,
}

m["bzz"] = {
	"Evant",
	"Q35259",
	"nic-bod",
	scripts = Latn,
}

return m