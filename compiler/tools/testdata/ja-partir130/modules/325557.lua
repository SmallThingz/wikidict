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
	"ババタナ語",
	"Q2877785",
	"poz-ocw",
	aliases = {"Mbambatana", "Bambatana"},
	scripts = Latn,
}

m["bab"] = {
	"Bainouk-Gunyuño",
	"Q35508",
	"alv-bny",
	scripts = Latn,
}

m["bac"] = {
	"バドゥイ語",
	"Q3449885",
	"poz-msa",
	scripts = Latn,
}

m["bae"] = {
	"バレ語",
	"Q3504087",
	"awd",
	aliases = {"Barawana"},
	scripts = Latn,
}

m["baf"] = {
	"Nubaca",
	"Q36270",
	"nic-ymb",
	otherNames = {"Nu Baca", "Baca"},
	scripts = Latn,
}

m["bag"] = {
	"Tuki",
	"Q36621",
	"nic-mba",
	scripts = Latn,
}

m["bah"] = {
	"バハマ・クレオール語",
	"Q2669229",
	"crp",
	aliases = {"Bahamian Creole English", "Bahamian", "Bahamas Creole", "Bahamas Creole English"},
	scripts = Latn,
	ancestors = {"en"},
}

m["baj"] = {
	"バラカイ語",
	"Q3502030",
	"poz-cet",
	scripts = Latn,
}

m["bal"] = {
	"バローチー語",
	"Q33049",
	"ira-nwi",
	otherNames = {"Balochi", "Southern Baluchi", "Southern Balochi", "Eastern Baluchi", "Eastern Balochi", "Western Baluchi", "Western Balochi"},
	scripts = {"fa-Arab"},
}

m["ban"] = {
	"バリ語",
	otherNames = {"バリ語 (インドネシア)", "Balinese"},
	"Q33070",
	"poz-mcm",
	scripts = {"Latn", "Bali"},
}

m["bao"] = {
	"ワイマハ語",
	"Q2883738",
	"sai-tuc",
	scripts = Latn,
}

m["bap"] = {
	"バンタワ語",
	"Q56500",
	"sit-kic",
	scripts = Deva,
}

m["bar"] = {
	"バイエルン語",
	"Q29540",
	"gmw",
	aliases = {"Austro-Bavarian"},
	scripts = Latn,
	ancestors = {"gmh"},
}

m["bas"] = {
	"バサ語",
	"Q33093",
	"bnt-bsa",
	aliases = {"Basa", "Basa (Cameroon)", "Basaa"},
	scripts = Latn,
}

m["bau"] = {
	"Badanchi",
	"Q11001650",
	"nic-jrw",
	otherNames = {"Bada", "Bada (Nigeria)"},
	scripts = Latn,
}

m["bav"] = {
	"バブンゴ語",
	"Q34885",
	"nic-rnn",
	otherNames = {"Vengo"},
	scripts = Latn,
}

m["baw"] = {
	"バンビリ＝バンブイ語",
	"Q34880",
	"nic-nge",
	scripts = Latn,
}

m["bax"] = {
	"バムン語",
	"Q35280",
	"nic-nun",
	aliases = {"Bamun"},
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
	"alv-sav",
	scripts = Latn,
}

m["bbb"] = {
	"バライ語",
	"Q4858206",
	"ngf",
	scripts = Latn,
}

m["bbc"] = {
	"バタク・トバ語",
	"Q33017",
	"btk",
	aliases = {"Batak Toba"},
	scripts = {"Latn", "Batk"},
}

m["bbd"] = {
	"バウ語",
	"Q4873415",
	"ngf-mad",
	scripts = Latn,
}

m["bbe"] = {
	"バングバ語",
	"Q34895",
	"nic-nke",
	scripts = Latn,
}

m["bbf"] = {
	"バイバイ語",
	"Q56902",
	"paa",
	scripts = Latn,
}

m["bbg"] = {
	"ヴァラマ語",
	"Q34884",
	"bnt-sir",
	scripts = Latn,
}

m["bbh"] = {
	"Bugan",
	"Q3033554",
	"mkh-pkn",
	aliases = {"Bogan"},
	scripts = Latn,
}

m["bbi"] = {
	"Barombi",
	"Q34985",
	"bnt-bsa",
	aliases = {"Rombi", "Lombi", "Lombe"},
	scripts = Latn,
}

m["bbj"] = {
	"ゴーマラ語",
	"Q35271",
	"bai",
	otherNames = {"Ghomálá'", "Bamileke-Banjun"},
	scripts = Latn,
}

m["bbk"] = {
	"ババンキ語",
	"Q34790",
	"nic-rnc",
	otherNames = {"Kejom", "Kidzem"},
	scripts = Latn,
}

m["bbl"] = {
	"バツ語",
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
	"bnt-bta",
	otherNames = {"Bango", "Mobango", "Ebango"},
	scripts = Latn,
}

m["bbn"] = {
	"ウネアパ語",
	"Q7884126",
	"poz-ocw",
	scripts = Latn,
}

m["bbo"] = {
	"Konabéré",
	"Q35371",
	"dmn-snb",
	otherNames = {"Bobo Fing", "Black Bobo", "Northern Bobo Madaré", "Bobo", "Jèrè", "Kukoma", "Kure", "Sankuma", "Tankri", "Yaba"},
	scripts = Latn,
}

m["bbp"] = {
	"中西部バンダ語",
	"Q7984377",
	"bad",
	scripts = Latn,
}

m["bbq"] = {
	"バマリ語",
	"Q34901",
	"nic-nun",
	scripts = Latn,
}

m["bbr"] = {
	"ギラワ語",
	"Q5564185",
	"ngf-mad",
	scripts = Latn,
}

m["bbs"] = {
	"バクピンカ語",
	"Q3515061",
	"nic-ucr",
	scripts = Latn,
}

m["bbt"] = {
	"Mburku",
	"Q3441324",
	"cdc-wst",
	scripts = Latn,
}

m["bbu"] = {
	"クルン語",
	"Q35580",
	"nic-jrn",
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
	"nic-nun",
	scripts = Latn,
}

m["bbx"] = { -- cf bvb
	"Bubia",
	"Q34953",
	"nic-bds",
	ancestors = {"bvb"},
	scripts = Latn,
}

m["bby"] = {
	"ベファン語",
	"Q34960",
	"nic-bds",
	scripts = Latn,
}

m["bca"] = {
	"ペー語中部方言",
	"Q12628803",
	"zhx-gba",
	otherNames = {"Jianchuan Bai"},
	scripts = {"Hani", "Latn"},
}

m["bcb"] = {
	"Bainouk-Samik",
	"Q36390",
	"alv-bny",
	scripts = Latn,
}

m["bcd"] = {
	"北ババル語",
	"Q7054041",
	"poz-tim",
	scripts = Latn,
}

m["bce"] = {
	"バメニャム語",
	"Q34968",
	"nic-nun",
	scripts = Latn,
}

m["bcf"] = {
	"バム語",
	"Q3503788",
	"paa-kiw",
	scripts = Latn,
}

m["bcg"] = {
	"バガ・ビナリ語",
	"Q31172660",
	"alv-nal",
	otherNames = {"Baga Binari", "Baga Mboteni"},
	scripts = Latn,
}

m["bch"] = {
	"バリアイ語",
	"Q2884502",
	"poz-ocw",
	scripts = Latn,
}

m["bci"] = {
	"バウレ語 (コートジボワール)",
	"Q35107",
	"alv-ctn",
	aliases = {"Baoule", "Baoulé", "Baule", "Bawule"},
	scripts = Latn,
}

m["bcj"] = {
	"バディ語",
	"Q3913852",
	"aus-nyu",
	scripts = Latn,
}

m["bck"] = {
	"ブナバ語",
	"Q580923",
	"aus-bub",
	scripts = Latn,
}

m["bcl"] = {
	"中央ビコール語",
	"Q33284",
	"phi",
	aliases = {"Central Bikol", "Bikol"}, -- also "Central Bicolano"?
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
	"バリ語 (ナイジェリア)",
	"Q34892",
	"alv-mye",
	otherNames = {"Bali", "Bali (Nigeria)", "Abaali"},
	scripts = Latn,
}

m["bco"] = {
	"カルリ語",
	"Q6354586",
	"ngf",
	scripts = Latn,
}

m["bcp"] = {
	"バリ語 (コンゴ民主共和国)",
	"Q3515074",
	"bnt-kbi",
	otherNames = {"Bali", "Bali (Congo)", "Bali (Democratic Republic of the Congo)", "Baali", "Kibali", "Libaali"},
	scripts = Latn,
}

m["bcq"] = {
	"ベンチ語",
	"Q35108",
	"omv",
	scripts = Latn,
}

m["bcr"] = {
	"バビーン・ウィツウィテン語",
	"Q27864",
	"ath-nor",
	otherNames = {"Babine", "Witsuwit'en", "Northern Carrier", "Western Carrier", "Nadot’en-Wets’uwet’en"},
	scripts = Latn,
}

m["bcs"] = {
	"コフモノ語",
	"Q35590",
	"nic-ucn",
	scripts = Latn,
}

m["bct"] = {
	"ベンディ語",
	"Q8836662",
	"csu-mle",
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
	"nic-jkn",
	otherNames = {"Shoo", "Minda", "Nye"},
	scripts = Latn,
}

m["bcw"] = {
	"バナ語",
	"Q56272",
	"cdc-cbm",
	scripts = Latn,
}

m["bcy"] = {
	"バチャマ語",
	"Q56274",
	"cdc",
	scripts = Latn,
}

m["bcz"] = {
	"Bainouk-Gunyaamolo",
	"Q35506",
	"alv-bny",
	scripts = Latn,
}

m["bda"] = {
	"バヨット語",
	"Q35019",
	"alv-jol",
	aliases = {"Baiot", "Baiote", "Bayotte"},
	scripts = Latn,
}

m["bdb"] = {
	"バサプ語",
	"Q3504208",
	"poz-bnn",
	scripts = Latn,
}

m["bdc"] = {
	"エンベラ＝バウド語",
	"Q11173166",
	"sai-chc",
	scripts = Latn,
}

m["bdd"] = {
	"ブナマ語",
	"Q4997416",
	"poz-ocw",
	scripts = Latn,
}

m["bde"] = {
	"バデ語",
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
	"バカ語",
	"Q2880165",
	"csu-bbk",
	otherNames = {"Baka", "Baka (Sudan)"},
	scripts = Latn,
}

m["bdi"] = {
	"ブルン語",
	"Q35040",
	"sdv-niw",
	otherNames = {"Northern Burun", "Maiak", "Mayak", "Mughaja", "Kurmuk"},
	scripts = Latn,
}

m["bdj"] = {
	"バイ語",
	"Q34894",
	"nic-ser",
	otherNames = {"Belanda", "Biri", "BGamba", "Gumba", "Mbegumba", "Mvegumba"},
	scripts = Latn,
}

m["bdk"] = {
	"ブドゥフ語",
	"Q35397",
	"cau-lzg",
	aliases = {"Budugh"},
	translit_module = "bdk-translit",
	override_translit = true,
	scripts = Cyrl,
	entry_name = {
		from = {GRAVE, ACUTE},
		to   = {}} ,
}

m["bdl"] = {
	"インドネシア・バジャウ語",
	"Q2880038",
	"poz",
	otherNames = {"Indonesian Bajo", "Sulawesi Bajau", "Sulawesi Bajaw", "Bajau", "Bajaw", "Bajo"},
	scripts = Latn,
}

m["bdm"] = {
	"ブドゥマ語",
	"Q56287",
	"cdc-cbm",
	otherNames = {"Yedina", "Kuri"},
	scripts = Latn,
}

m["bdn"] = {
	"バルデム語",
	"Q56280",
	"cdc-cbm",
	scripts = Latn,
}

m["bdo"] = {
	"Morom",
	"Q759770",
	"csu-bgr",
	scripts = Latn,
}

m["bdp"] = {
	"ベンデ語",
	"Q8836490",
	"bnt",
	scripts = Latn,
}

m["bdq"] = {
	"バーナル語",
	"Q32924",
	"mkh-ban",
	scripts = Latn,
	ancestors = {"mkh-ban-pro"},
}

m["bdr"] = {
	"西海岸バジャウ語",
	"Q2880037",
	"poz-sbj",
	scripts = Latn,
}

m["bds"] = {
	"ブルンゲ語",
	"Q56617",
	"cus",
	scripts = Latn,
}

m["bdt"] = {
	"ボコト語",
	"Q4938812",
	"alv-gbw",
	scripts = Latn,
}

m["bdu"] = {
	"Oroko",
	"Q36278",
	"bnt-saw",
	otherNames = {"Bima", "Bakundu-Balue", "Balundu-Bima"},
	scripts = Latn,
}

m["bdv"] = {
	"ボド・パルジャ語",
	"Q8845881",
	"inc-eas",
	scripts = {"Orya"},
	ancestors = {"inc-mgd"},
}

m["bdw"] = {
	"バハム語",
	"Q3513309",
	"paa",
	scripts = Latn,
}

m["bdx"] = {
	"ブドン＝ブドン語",
	"Q4985158",
	"poz-ssw",
	scripts = Latn,
}

m["bdy"] = {
	"バンジャラン語",
	"Q2980386",
	"aus-pam",
	scripts = Latn,
}

m["bdz"] = {
	"Badeshi",
	"Q33028",
	"inc-wes",
	ancestors = {"noe"},
}

m["bea"] = {
	"ビーバー語",
	"Q20826",
	"ath-nor",
	otherNames = {"Dane-zaa", "Danezaa", "Danezaa ZaageɁ"},
	scripts = Latn,
}

m["beb"] = {
	"Bebele",
	"Q34976",
	"bnt-btb",
	scripts = Latn,
}

m["bec"] = {
	"Iceve-Maci",
	"Q35449",
	"nic-tvc",
	scripts = Latn,
}

m["bed"] = {
	"ベドアナス語",
	"Q4879330",
	"poz-hce",
	scripts = Latn,
}

m["bee"] = {
	"ビャンシ語",
	"Q56904",
	"sit-alm",
	scripts = Deva,
}

m["bef"] = {
	"ベナベナ語",
	"Q2895638",
	"paa-kag",
	scripts = Latn,
}

m["beg"] = {
	"べライト語",
	"Q2894198",
	"poz-swa",
	otherNames = {"Lemeting"},
	scripts = Latn,
}

m["beh"] = {
	"ビアリ語",
	"Q34961",
	"nic-eov",
	otherNames = {"Berba", "Bieri"},
	scripts = Latn,
}

m["bei"] = {
	"ブカティ語",
	"Q3441683",
	"day",
	aliases = {"Bekati’", "Bekatiq", "Bakati"},
	scripts = Latn,
}

m["bej"] = {
	"ベジャ語",
	"Q33025",
	"cus",
	scripts = {"Arab", "Latn"},
}

m["bek"] = {
	"ベベリ語",
	"Q4878430",
	"poz-ocw",
	scripts = Latn,
}

m["bem"] = {
	"ベンバ語",
	"Q33052",
	"bnt-sbi",
	aliases = {"Bemba (Zambia)"},
	scripts = Latn,
}

m["beo"] = {
	"ベアミ語",
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
	"ベエンベ語",
	"Q3196320",
	"bnt-kng",
	otherNames = {"Bembe", "Kibeembe"},
	scripts = Latn,
}

m["bes"] = {
	"ベスメ語",
	"Q289832",
	"alv-kim",
	scripts = Latn,
}

m["bet"] = {
	"ギベルア・ベテ語",
	"Q11019185",
	"kro-bet",
	otherNames = {"Bété of Guiberoua", "Western Bété"},
	scripts = Latn,
}

m["beu"] = {
	"ブラガル語",
	"Q4923846",
	"ngf",
	aliases = {"Belagar"},
	scripts = Latn,
}

m["bev"] = {
	"Daloa Bété",
	"Q11155819",
	"kro-bet",
	otherNames = {"Bété of Daloa", "Northern Bété"},
	scripts = Latn,
}

m["bew"] = {
	"ベタウィ語",
	"Q33014",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["bex"] = {
	"Jur Modo",
	"Q56682",
	"csu-bbk",
	scripts = Latn,
}

m["bey"] = {
	"ベリ語 (パプアニューギニア)",
	"Q3504170",
	"qfa-tor",
	otherNames = {"Beli", "Beli (New Guinea)", "Beli (Papua New Guinea)"},
	scripts = Latn,
}

m["bez"] = {
	"ベナ語 (タンザニア)",
	"Q2502949",
	"bnt-bki",
	otherNames = {"Bena", "Bena (Tanzania)"},
	scripts = Latn,
}

m["bfa"] = {
	"バリ語 (南スーダン)",
	"Q35042",
	"sdv-bri",
	otherNames = {"Bari", "Pojulu", "Pöjulu", "Fadjulu", "Fajelu", "Madi", "Pajulu"},
	scripts = Latn,
}

m["bfb"] = {
	"パウリ・バレリ語",
	"Q7155462",
	"inc-bhi",
	scripts = Deva,
}

m["bfc"] = {
	"ペー語北部方言",
	"Q12642165",
	"zhx-gba",
	otherNames = {"Bijiang Bai", "Laemae", "Lama", "Panyi Bai"},
	scripts = {"Hani", "Latn"},
}

m["bfd"] = {
	"バフット語",
	"Q34888",
	"nic-nge",
	scripts = Latn,
}

m["bfe"] = {
	"Betaf",
	"Q4897329",
	"paa-tkw",
	scripts = Latn,
}

m["bff"] = {
	"ボフィ語",
	"Q34914",
	"alv-gbf",
	scripts = Latn,
}

m["bfg"] = {
	"ブサン・カヤン語",
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
	"イギリス手話",
	"Q33000",
	"sgn",
	aliases = {"BSL"},
	scripts = Latn, -- when documented
}

m["bfj"] = {
	"バファンジ語",
	"Q34890",
	"nic-nun",
	scripts = Latn,
}

m["bfk"] = {
	"バンコール手話",
	"Q3441103",
	"sgn",
}

m["bfl"] = {
	"Banda-Ndélé",
	"Q34850",
	"bad-cnt",
	scripts = Latn,
}

m["bfm"] = {
	"Mmen",
	"Q36132",
	"nic-rnc",
	scripts = Latn,
}

m["bfn"] = {
	"ブナク語",
	"Q35101",
	"ngf",
	scripts = Latn,
}

m["bfo"] = {
	"Malba Birifor",
	"Q11150710",
	"nic-mre",
	scripts = Latn,
}

m["bfp"] = {
	"ベバ語",
	"Q35050",
	"nic-nge",
	scripts = Latn,
}

m["bfq"] = {
	"バダガ語",
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
	"ペー語南部方言",
	"Q12952250",
	"zhx-gba",
	otherNames = {"Dali Bai"},
	scripts = {"Hani", "Latn"},
}

m["bft"] = {
	"バルティ語",
	"Q33086",
	"sit-lab",
	scripts = {"Arab", "Tibt"},
}

m["bfu"] = {
	"ガハル語",
	"Q5516952",
	"sit-whm",
	scripts = {"Takr", "Tibt"},
}

m["bfw"] = {
	"ボンド語",
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
	"バゲーリー語",
	"Q2356364",
	"inc-hie",
	scripts = Deva,
	ancestors = {"pka"},
	translit_module = "hi-translit",
}

m["bfz"] = {
	"Mahasu Pahari",
	"Q6733460",
	"him",
	scripts = Deva,
	translit_module = "hi-translit",
}

m["bga"] = {
	"Gwamhi-Wuri",
	"Q6707102",
	"nic-knn",
	otherNames = {"Wurə-Gwamhyə-Mba", "Lyase"},
	scripts = Latn,
}

m["bgb"] = {
	"ボボンコ語",
	"Q4935896",
	"poz-slb",
	scripts = Latn,
}

m["bgc"] = {
	"ハリヤーンウィー語",
	"Q33410",
	"inc-cen",
	scripts = Deva,
	ancestors = {"inc-ohi"},
	translit_module = "hi-translit",
}

m["bgd"] = {
	"Rathwi Bareli",
	"Q7295692",
	"inc-bhi",
	scripts = Deva,
}

m["bge"] = {
	"バウリア語",
	"Q4873579",
	"inc-bhi",
	scripts = Deva,
}

m["bgf"] = {
	"バンガンド語",
	"Q34938",
	"alv-gbs",
	scripts = Latn,
}

m["bgg"] = {
	"Bugun",
	"Q3514220",
	"sit-khb",
	scripts = Latn,
}

m["bgi"] = {
	"ギアンガン語",
	"Q4842057",
	"phi",
	scripts = Latn,
}

m["bgj"] = {
	"Bangolan",
	"Q34862",
	"nic-nun",
	scripts = Latn,
}

m["bgk"] = {
	"ビット語",
	"Q2904868",
	"mkh-pal",
	scripts = Latn, -- also Hani?
}

m["bgl"] = {
	"ボー語",
	"Q8845514",
	"mkh-vie",
	aliases = {"Bo (Laos)"}, -- if 'bpw' is added, the disambig name will have to be made canonical
}

m["bgo"] = {
	"Baga Koga",
	"Q35695",
	"alv-bag",
	scripts = Latn,
}

m["bgq"] = {
	"バーガル語",
	"Q2426319",
	"inc-wes",
	scripts = Deva,
	ancestors = {"raj"},
}

m["bgr"] = {
	"ボーン・チン語",
	"Q56765",
	"tbq-kuk",
	otherNames = {"Bawm", "Banjogi"},
	scripts = Latn,
}

m["bgs"] = {
	"タガバワ語",
	"Q7675121",
	"mno",
	scripts = Latn,
}

m["bgt"] = {
	"ブゴトゥ語",
	"Q2927723",
	"poz-sls",
	aliases = {"Bugotu"},
	scripts = Latn,
}

m["bgu"] = {
	"Mbongno",
	"Q36141",
	"nic-mmb",
	scripts = Latn,
}

m["bgv"] = {
	"ワルカイ・ビピム語",
	"Q4915439",
	"ngf",
	scripts = Latn,
}

m["bgw"] = {
	"Bhatri",
	"Q8841054",
	"inc-eas",
	scripts = Deva,
	ancestors = {"inc-mgd"},
}

m["bgx"] = {
	"バルカン・ガガウズ・トルコ語",
	"Q2360396",
	"trk-ogz",
	aliases = {"Balkan Turkic"},
	scripts = Latn,
	ancestors = {"trk-oat"},
}

m["bgy"] = {
	"Benggoi",
	"Q4887742",
	"poz-cma",
	scripts = Latn,
}

m["bgz"] = {
	"バンガイ語",
	"Q3441692",
	"poz-slb",
	scripts = Latn,
}

m["bha"] = {
	"バーリア語",
	"Q4901287",
	"dra",
	scripts = Deva,
}

m["bhb"] = {
	"ビーリ語",
	"Q33229",
	"inc-bhi",
	scripts = Deva,
}

m["bhc"] = {
	"ビガ語",
	"Q2902375",
	"poz-hce",
	scripts = Latn,
}

m["bhd"] = {
	"バドラワーヒー語",
	"Q4900565",
	"him",
	aliases = {"Bhadarwahi"},
	scripts = {"Arab", "Deva"},
	translit_module = "hi-translit",
}

m["bhe"] = {
	"バーヤ語",
	"Q8841168",
	"inc-wes",
	ancestors = {"raj"},
}

m["bhf"] = {
	"Odiai",
	"Q56690",
	"paa-kwm",
	scripts = Latn,
}

m["bhg"] = {
	"ビナンデレ語",
	"Q3503802",
	"ngf",
	scripts = Latn,
}

m["bhh"] = {
	"ブハラ語",
	"Q56469",
	"ira-swi",
	aliases = {"Bukhori", "Bukharian", "Bukharic", "Buchari", "Buchori", "Bucharian", "Bucharic"},
	scripts = {"Cyrl", "Hebr", "Latn", "fa-Arab"},
	ancestors = {"tg"},
}

m["bhi"] = {
	"ビーラリ語",
	"Q4901729",
	"inc-bhi",
	scripts = Deva,
}

m["bhj"] = {
	"バヒン語",
	"Q56442",
	"sit-kiw",
	scripts = {"Deva", "Latn"},
}

m["bhl"] = {
	"ビミン語",
	"Q4913743",
	"ngf-okk",
	scripts = Latn,
}

m["bhm"] = {
	"バトハリ語",
	"Q2586893",
	"sem-sar",
	otherNames = {"Batahari", "Bat'hari", "Bautahari", "Botahari", "Bathara"},
	scripts = {"Arab", "Latn"},
}

m["bhn"] = {
	"ボータン現代アラム語",
	"Q33230",
	"sem-nna",
}

m["bho"] = {
	"ボージュプリー語",
	otherNames = {"ボージュプリー", "ボジュプリー語", "Bhojpuri"},
	"Q33268",
	"inc-hie",
	scripts = {"Deva", "Kthi"},
	ancestors = {"bh"},
	translit_module = "translit-redirect",
}

m["bhp"] = {
	"ビマ語",
	"Q2796873",
	"poz-cet",
	aliases = {"Bimanese"},
	scripts = Latn,
}

m["bhq"] = {
	"トゥカンブシ南語",
	"Q12643975",
	"poz-mun",
	scripts = Latn,
}

m["bhs"] = {
	"ブワル語",
	"Q3515065",
	"cdc-cbm",
	scripts = Latn,
}

m["bht"] = {
	"バッティヤリ語",
	"Q4901452",
	"him",
	scripts = Deva,
}

m["bhu"] = {
	"ブーンジア語",
	"Q8841766",
	"inc-eas",
	scripts = {"Deva", "Orya"},
	ancestors = {"inc-mgd"},
}

m["bhv"] = {
	"バハウ語",
	"Q3502039",
	"poz",
	scripts = Latn,
}

m["bhw"] = {
	"ビアク語",
	"Q1961488",
	"poz-hce",
	scripts = Latn,
}

m["bhx"] = { -- spurious?
	"バライ語",
	"Q8840773",
	"inc",
	otherNames = {"Bhalay-Gowlan"},
}

m["bhy"] = {
	"Bhele",
	"Q4901671",
	"bnt-kbi",
	otherNames = {"Ebhele", "Piri", "Kipiri"},
	scripts = Latn,
}

m["bhz"] = {
	"バダ語",
	"Q4840520",
	"poz-kal",
	aliases = {"Bada (Indonesia)"},
	scripts = Latn,
}

m["bia"] = {
	"バディマヤ語",
	"Q3442745",
	"aus-psw",
	scripts = Latn,
}

m["bib"] = {
	"ビサ語",
	"Q32934",
	"dmn-bbu",
	scripts = Latn,
}

m["bic"] = {
	"ビカル語",
	"Q56342",
	"paa-eng",
	scripts = Latn,
}

m["bid"] = {
	"ビディヨ語",
	"Q56258",
	"cdc-est",
	scripts = Latn,
}

m["bie"] = {
	"ベポウル語",
	"Q4890914",
	"ngf-mad",
	scripts = Latn,
}

m["bif"] = {
	"ビアファダ語",
	"Q35099",
	"alv-ten",
	scripts = Latn,
}

m["big"] = {
	"ビアンガイ語",
	"Q8842027",
	"paa",
	scripts = Latn,
}

m["bij"] = {
	"Kwanka",
	"Q35598",
	"nic-tar",
	otherNames = {"Kwang", "Vaghat-Ya-Bijim-Legeri", "Vaghat", "Ya", "Bijim", "Legeri"},
	scripts = Latn,
}

m["bil"] = {
	"ビレ語",
	"Q34987",
	"nic-jrn",
	aliases = {"Bille"},
	scripts = Latn,
}

m["bim"] = {
	"ビモバ語",
	"Q34971",
	"nic-grm",
	scripts = Latn,
}

m["bin"] = {
	"エド語",
	"Q35375",
	"alv-eeo",
	otherNames = {"Bini", "Edo"},
	scripts = Latn,
}

m["bio"] = {
	"ナイ語",
	"Q3508074",
	"paa-kwm",
	otherNames = {"Biaka"},
	scripts = Latn,
}

m["bip"] = {
	"ビラ語",
	"Q2902626",
	"bnt-kbi",
	otherNames = {"Forest Bira"},
	scripts = Latn,
}

m["biq"] = {
	"ビピ語",
	"Q2904312",
	"poz-aay",
	scripts = Latn,
}

m["bir"] = {
	"ビソリオ語",
	"Q8844749",
	"paa-eng",
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
	"ビエテ語",
	"Q4904687",
	"tbq-kuk",
	scripts = Latn,
}

m["biv"] = {
	"南部ビリフォル語",
	"Q32859745",
	"nic-mre",
	scripts = Latn,
}

m["biw"] = {
	"Kol (Cameroon)",
	"Q35582",
	"bnt-mka",
	aliases = {"Kol"},
	scripts = Latn,
}

m["bix"] = {
	"Bijori",
	"Q3450686",
	"mun",
	scripts = Deva,
}

m["biy"] = {
	"ビルホル語",
	"Q3450469",
	"mun",
	scripts = Deva,
}

m["biz"] = {
	"Baloi",
	"Q3450590",
	"bnt-ngn",
	scripts = Latn,
}

m["bja"] = {
	"ブジャ語",
	otherNames = {"Budza", "Buja"},
	"Q3046889",
	"bnt-bun",
	aliases = {"Buja"},
	scripts = Latn,
}

m["bjb"] = {
	"バンガラ語",
	"Q3439071",
	"aus-pam",
	otherNames = {"Parnkalla", "Banggarla", "Parnkala", "Parnkarla", "Barngala", "Bangala", "Bungala", "Bungela", "Banggala", "Bahngala", "Pankalla", "Punkalla", "Pangkala", "Pankarla", "Parkalla", "Pakarla", "Bungeha", "Bahanga-La", "Kortabina", "Arkaba-tura", "Port Lincon", "Kooapidna", "Punkirla", "Wanbirujurari", "Willara", "Willeuroo"},
	scripts = Latn,
}

m["bjc"] = {
	"バリジ語",
	"Q4690919",
	"ngf",
	otherNames = {"Bareji", "Aga Bereho"},
	scripts = Latn,
}

m["bje"] = {
	"标交瑶語",
	"Q3503800",
	"hmx-mie",
	otherNames = {"Biao Min", "Jiaogong Mian"},
	scripts = {"Hani", "Latn"},
}

m["bjf"] = {
	"バルザニ・ユダヤ現代アラム語",
	"Q33234",
	"sem-nna",
	scripts = {"Hebr"}, -- maybe others
}

m["bjg"] = {
	"Bidyogo",
	"Q35365",
	"alv-bak",
	aliases = {"Bijago"},
	scripts = Latn,
}

m["bjh"] = {
	"バヒネモ語",
	"Q56361",
	"paa-spk",
	scripts = Latn,
}

m["bji"] = {
	"ブルジ語",
	"Q34999",
	"cus",
	scripts = {"Latn", "Ethi"},
}

m["bjj"] = {
	"カナウジー語",
	"Q2726867",
	"inc-cen",
	scripts = Deva,
	ancestors = {"inc-ohi"},
}

m["bjk"] = {
	"バロック語",
	"Q2884743",
	"poz-ocw",
	scripts = Latn,
}

m["bjl"] = {
	"ブル語（パプアニューギニア）",
	"Q4997162",
	"poz-ocw",
	aliases = {"Bulu (Papua New Guinea)", "Bulu"},
	scripts = Latn,
}

m["bjm"] = {
	"バジェラニ語",
	"Q4848866",
	"ira-zgr",
	scripts = {"Latn", "Arab"},
	ancestors = {"hac"},
}

m["bjn"] = {
	"バンジャール語",
	"Q33151",
	"poz-mly",
	aliases = {"Banjar"},
	scripts = {"Latn", "Arab"},
}

m["bjo"] = {
	"Mid-Southern Banda",
	"Q42303990",
	"bad-cnt",
	scripts = Latn,
}

m["bjp"] = {
	"Fanamaket",
	nil,
	"poz-oce",
	scripts = Latn,
}

m["bjr"] = {
	"ビヌマリエン語",
	"Q538364",
	"paa-kag",
	scripts = Latn,
}

m["bjs"] = {
	"ベイジャン語",
	"Q2524014",
	"crp",
	otherNames = {"Barbadian", "Barbadian Creole", "Barbadian Creole English"},
	scripts = Latn,
	ancestors = {"en"},
}

m["bjt"] = {
	"バランタ＝ガンジャ語",
	"Q19359034",
	"alv-bak",
	scripts = {"Arab", "Latn"},
}

m["bju"] = {
	"ブスー語",
	"Q35046",
	"nic-fru",
	scripts = Latn,
}

m["bjv"] = {
	"Bedjond",
	"Q8829831",
	"csu-sar",
	scripts = Latn,
}

m["bjw"] = {
	"バクウェ語",
	"Q34899",
	"kro-ekr",
	scripts = Latn,
}

m["bjx"] = {
	"バナオ・イトゥネグ語",
	"Q12627559",
	"phi",
	scripts = Latn,
}

m["bjy"] = {
	"バヤリ語",
	"Q4874263",
	"aus-pam",
	scripts = Latn,
}

m["bjz"] = {
	"バルガ語",
	"Q2886189",
	"ngf",
	scripts = Latn,
}

m["bka"] = {
	"Kyak",
	"Q35653",
	"alv-bwj",
	otherNames = {"Nyakyak", "Bambuka"},
	scripts = Latn,
}

m["bkc"] = {
	"バカ語 (カメルーン)",
	"Q34905",
	"nic-nkb",
	aliases = {"Baka (Cameroon)"},
	scripts = Latn,
}

m["bkd"] = {
	"ビヌキド語",
	"Q4914553",
	"mno",
	scripts = Latn,
}

m["bkf"] = {
	"ベエケ語",
	"Q3441375",
	"bnt-kbi",
	scripts = Latn,
}

m["bkg"] = {
	"Buraka",
	"Q35066",
	"nic-nkg",
	scripts = Latn,
}

m["bkh"] = {
	"バココ語",
	otherNames = "Bakoko",
	"Q34866",
	"bnt-bsa",
	scripts = Latn,
}

m["bki"] = {
	"バキ語",
	"Q11024697",
	"poz-vnc",
	scripts = Latn,
}

m["bkj"] = {
	"パンデ語",
	"Q36263",
	"bnt-ngn",
	otherNames = {"Pande-Gongo"},
	scripts = Latn,
}

m["bkk"] = { -- written in Balti script
	"ブロクスカト語",
	"Q2925988",
	"inc-dar",
}

m["bkl"] = {
	"ベリック語",
	"Q378743",
	"paa-tkw",
	scripts = Latn,
}

m["bkm"] = {
	"コム語 (カメルーン)",
	"Q1656595",
	"nic-rnc",
	aliases = {"Kom"},
	scripts = Latn,
}

m["bkn"] = {
	"ブキタン語",
	"Q3446774",
	"poz-bnn",
	aliases = {"Bekatan", "Bakatan", "Baketan"}, 
	scripts = Latn,
}

m["bko"] = {
	"クワ語'",
	"Q35567",
	"bai",
	scripts = Latn,
}

m["bkp"] = {
	"ボコ語",
	"Q35089",
	"bnt-ngn",
	aliases = {"Boko", "Boko (Congo)", "Boko (Democratic Republic of the Congo)"},
	scripts = Latn,
}

m["bkq"] = {
	"バカイリ語",
	"Q56846",
	"sai-car",
	aliases = {"Bakairi", "Bacairí", "Bacairi"},
	scripts = Latn,
}

m["bkr"] = {
	"バクンパイ語",
	"Q3436626",
	"poz-brw",
	scripts = Latn,
}

m["bks"] = {
	"マスバテ・ソルソゴン語",
	"Q16113356",
	"phi",
	scripts = Latn,
}

m["bkt"] = {
	"ボロキ語",
	"Q4144560",
	"bnt-zbi",
	ancestors = {"lse"},
	scripts = Latn,
}

m["bku"] = {
	"ブヒッド語",
	"Q1002956",
	"phi",
	scripts = {"Buhd"},
}

m["bkv"] = {
	"ベクワラ語",
	"Q34954",
	"nic-ben",
	scripts = Latn,
}

m["bkw"] = {
	"バクウェレ語",
	"Q34950",
	"bnt-bek",
	aliases = {"Bakwele", "Bekwel", "Bekwil"},
	scripts = Latn,
}

m["bkx"] = {
	"Baikeno",
	"Q11200640",
	"poz-tim",
	scripts = Latn,
}

m["bky"] = {
	"ボキ語",
	otherNames = {"Boki", "Bokyi"},
	"Q35087",
	"nic-ben",
	scripts = Latn,
}

m["bkz"] = {
	"ブンク語",
	"Q2928207",
	"poz-btk",
	scripts = Latn,
}

m["bla"] = {
	"ブラックフット語",
	"Q33060",
	"alg",
	otherNames = {"Siksika", "Blackfeet"},
	scripts = {"Latn", "Cans"},
}

m["blb"] = {
	"ビルア語",
	"Q35003",
	"ngf",
	scripts = Latn,
}

m["blc"] = {
	"ベーラ・コーラ語",
	"Q977808",
	"sal",
	aliases = {"Nuxálk", "Nuxalk"},
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
	"alv-bak",
	scripts = Latn,
}

m["blf"] = {
	"ブオル語",
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
	"クワア語",
	"Q35579",
	"kro",
	otherNames = {"Belle", "Belleh", "Kowaao", "Kwaa"},
	scripts = Latn,
}

m["bli"] = {
	"ボリア語",
	"Q34910",
	"bnt-mon",
	otherNames = {"Bolia", "Lia"},
	scripts = Latn,
}

m["blj"] = {
	"Bolongan",
	"Q9229310",
	"poz",
	scripts = Latn,
}

m["blk"] = {
	"パーオー・カレン語",
	"Q7121294",
	"kar",
	aliases = {"Pa'o", "Black Karen"},
	scripts = {"Mymr"},
}

m["bll"] = {
	"ビロキシー語",
	"Q2903780",
	"sio-ohv",
	scripts = Latn,
}

m["blm"] = {
	"ベリ語",
	"Q56821",
	"csu-bbk",
	otherNames = {"Behli", "Beili", "Jur Beli", "Beli (Sudan)", "Beli (South Sudan)"},
	scripts = Latn,
}

m["bln"] = {
	"南部カタンドアネス・ビコル語",
	"Q7569754",
	"phi",
	otherNames = {"Virac"},
	scripts = Latn,
}

m["blo"] = {
	"Anii",
	"Q34838",
	"alv-ntg",
	otherNames = {"Bassila", "Basila", "Baseca", "Ouinji-Ouinji", "Winji-Winji"},
	scripts = Latn,
}

m["blp"] = {
	"ブラブランガ語",
	"Q2905245",
	"poz-ocw",
	scripts = Latn,
}

m["blq"] = {
	"バルアン・パム語",
	"Q2881675",
	"poz-aay",
	scripts = Latn,
}

m["blr"] = {
	"プラン語",
	"Q4925096",
	"mkh-pal",
	otherNames = {"Bulang", "Pulang", "Kontoi", "Shinman"},
	scripts = {"Latn", "Tale", "Lana", "Thai"},
	sort_key = {
		from = {"[%pᪧๆ]", "[᩠ᩳ-᩿]", "ᩔ", "ᩕ", "ᩖ", "ᩘ", "([ᨭ-ᨱ])ᩛ", "([ᨷ-ᨾ])ᩛ", "ᩤ", "[็-๎]", "([เแโใไ])([ก-ฮ])"},
		to   = {"", "", "ᩈᩈ", "ᩁ", "ᩃ", "ᨦ", "%1ᨮ", "%1ᨻ", "ᩣ", "", "%2%1"}},
}

m["bls"] = {
	"Balaesang",
	"Q4849796",
	"poz",
	scripts = Latn,
}

m["blt"] = {
	"タイ・ダム語",
	"Q56407",
	"tai-swe",
	aliases = {"Tai Noi", "Black Tai"},
	scripts = {"Tavt", "Latn"},
	--translit_module = "Tavt-translit",
	sort_key = {
		from = {"[꪿ꫀ꫁ꫂ]", "([ꪵꪶꪹꪻꪼ])([ꪀ-ꪯ])"},
		to   = {"", "%2%1"}},
}

m["blv"] = {
	"Kibala",
	"Q4939959",
	"bnt-kmb",
	otherNames = {"Bolo", "Ngoya", "Kibala-Ngoya"},
	scripts = Latn,
}

m["blw"] = {
	"バランガオ語",
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
	"nic-wov",
	aliases = {"Nootre"},
	scripts = Latn,
}

m["blz"] = {
	"バランタク語",
	"Q4850053",
	"poz-slb",
	scripts = Latn,
}

m["bma"] = {
	"ラメ語",
	"Q3913997",
	"nic-jrn",
	scripts = Latn,
}

m["bmb"] = {
	"ベンベ語",
	"Q4885023",
	"bnt-lgb",
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
	"alv-bag",
	aliases = {"Baga Maduri", "Baga Mandari"},
	scripts = Latn,
}

m["bme"] = {
	"Limassa",
	"Q11004666",
	"nic-nkb",
	scripts = Latn,
}

m["bmf"] = {
	"ボム語",
	"Q35088",
	"alv-mel",
	scripts = Latn,
}

m["bmg"] = {
	"Bamwe",
	"Q34867",
	"bnt-bun",
	scripts = Latn,
}

m["bmh"] = {
	"ケイン語",
	"Q6383764",
	"ngf-mad",
	otherNames = {"Bemal"},
	scripts = Latn,
}

m["bmi"] = {
	"バギルミ語",
	"Q34903",
	"csu-bgr",
	scripts = Latn,
}

m["bmj"] = {
	"Bote-Majhi",
	"Q9229570",
	"inc-eas",
	scripts = Deva,
	ancestors = {"bh"},
}

m["bmk"] = {
	"Ghayavi",
	"Q5555976",
	"poz-ocw",
	scripts = Latn,
}

m["bml"] = {
	"ボンボリ語",
	"Q35055",
	"bnt-ngn",
	scripts = Latn,
}

m["bmn"] = {
	"ビナ語",
	"Q8843664",
	"poz-ocw",
	aliases = {"Bina (New Guinea)", "Bina (Papua New Guinea)"},
	scripts = Latn,
}

m["bmo"] = {
	"バンバラン語",
	"Q34868",
	"nic-nun",
	scripts = Latn,
}

m["bmp"] = {
	"ブルゲビ語",
	"Q4996380",
	"ngf-fin",
	scripts = Latn,
}

m["bmq"] = {
	"Bomu",
	"Q35065",
	"nic-bwa",
	scripts = Latn,
}

m["bmr"] = {
	"ムイナネ語",
	"Q3027894",
	"sai-bor",
	scripts = Latn,
}

m["bmt"] = {
	"标曼語",
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
	"ブム語",
	"Q35058",
	"nic-rnc",
	scripts = Latn,
}

m["bmw"] = {
	"ボンワリ語",
	otherNames = {"Bomwali", "Lino"},
	"Q34984",
	"bnt-ndb",
	scripts = Latn,
}

m["bmx"] = {
	"バイマク語",
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
	"ボネラテ語",
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

m["bnc"] = {
	"ボントク語",
	nil,
	scripts = Latn,
}

m["bnd"] = {
	"バンダ語",
	"Q3504147",
	"poz-cma",
	aliases = {"Banda (Indonesia)"},
	scripts = Latn,
}

m["bne"] = {
	"ビンタウナ語",
	"Q4914533",
	"phi",
	scripts = Latn,
}

m["bnf"] = {
	"マシワン語",
	"Q6783305",
	"poz-cma",
	otherNames = {"Bonfia"},
	scripts = Latn,
}

m["bng"] = {
	"ベンガ語",
	"Q34952",
	"bnt-saw",
	scripts = Latn,
}

m["bni"] = {
	"バンギ語",
	"Q34936",
	"bnt-bmo",
	otherNames = {"Bobangi", "Bubangi"},
	scripts = Latn,
}

m["bnj"] = {
	"東部タウブイッド語",
	"Q18757427",
	"phi",
	scripts = Latn,
}

m["bnk"] = {
	"ビエレボ語",
	"Q2902029",
	"poz-vnc",
	scripts = Latn,
}

m["bnl"] = {
	"ブーン語",
	"Q56616",
	"cus",
	scripts = Latn,
}

m["bnm"] = {
	"バタンガ語",
	"Q34979",
	"bnt-saw",
	scripts = Latn,
}

m["bnn"] = {
	"ブヌン語",
	"Q56505",
	"map",
	scripts = Latn,
}

m["bno"] = {
	"アスィ語",
	"Q29490",
	"phi",
	scripts = Latn,
}

m["bnp"] = {
	"ボラ語",
	"Q4938876",
	"poz-ocw",
	scripts = Latn,
}

m["bnq"] = {
	"バンティック語",
	"Q2883521",
	"poz",
	scripts = Latn,
}

m["bnr"] = {
	"ブトマス＝トゥル語",
	"Q2928942",
	"poz-vnc",
	scripts = Latn,
}

m["bns"] = {
	"ブンデーリー語",
	"Q56399",
	"inc-cen",
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
	"ボネリフ語",
	"Q4941733",
	"paa-tkw",
	scripts = Latn,
}

m["bnw"] = {
	"ビシス語",
	"Q56356",
	"paa-spk",
	scripts = Latn,
}

m["bnx"] = {
	"バングバング語",
	otherNames = {"Bangubangu"},
	"Q3438330",
	"bnt-lbn",
	scripts = Latn,
}

m["bny"] = {
	"ビントゥル語",
	"Q3450775",
	"poz-swa",
	scripts = Latn,
}

m["bnz"] = {
	"Beezen",
	"Q35083",
	"nic-ykb",
	scripts = Latn,
}

m["boa"] = {
	"ボラ語",
	"Q2375468",
	"sai-bor",
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
	"nic-beb",
	scripts = Latn,
}

m["bof"] = {
	"ボロン語",
	"Q3913301",
	"dmn-emn",
	scripts = Latn,
}

m["bog"] = {
	"バマコ手話",
	"Q4853284",
	"sgn",
}

m["boh"] = {
	"ボマ語",
	"Q35080",
	"bnt-bdz",
	scripts = Latn,
}

m["boi"] = {
	"バルバレーニョ語",
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
	"ボレ語",
	"Q3436680",
	"cdc-wst",
	scripts = Latn,
}

m["bom"] = {
	"ベロム語",
	"Q35013",
	"nic-beo",
	aliases = {"Birom"},
	scripts = Latn,
}

m["bon"] = {
	"ビネ語",
	"Q4914077",
	"paa",
	scripts = Latn,
}

m["boo"] = {
	"Tiemacèwè Bozo",
	"Q12643582",
	"dmn-snb",
	scripts = Latn, -- and others?
}

m["bop"] = {
	"ボンキマン語",
	"Q4942134",
	"ngf-fin",
	scripts = Latn,
}

m["boq"] = {
	"ボガヤ語",
	"Q7207578",
	"ngf",
	scripts = Latn,
}

m["bor"] = {
	"ボロロ語",
	"Q32986",
	"sai-mje",
	scripts = Latn,
}

m["bot"] = {
	"ボンゴ語",
	"Q2910067",
	"csu-bbk",
	scripts = Latn,
}

m["bou"] = {
	"ボンディ語",
	"Q4941378",
	"bnt-seu",
	aliases = {"Boondei", "Boondéi"},
	scripts = Latn,
}

m["bov"] = {
	"Tuwuli",
	"Q36974",
	"alv-ktg",
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
	"nic-bwa",
	aliases = {"Bwamu"},
	scripts = Latn,
}

m["boy"] = {
	"ボド語（中央アフリカ）",
	"Q4936715",
	"bnt-leb",
	aliases = {"Bodo (Central African Republic)", "Bodo"},
	scripts = Latn,
}

m["boz"] = {
	"Tiéyaxo Bozo",
	"Q32860401",
	"dmn-snb",
	scripts = Latn,
}

m["bpa"] = {
	"Dakaka",
	"Q1157729",
	"poz-vnc",
	otherNames = {"Daakaka", "South Ambrym", "Baiap"},
	scripts = Latn,
}

m["bpd"] = {
	"バンダ＝バンダ語",
	"Q3450674",
	"bad-cnt",
	scripts = Latn,
}

m["bpg"] = {
	"ボンゴ語",
	"Q4941860",
	"poz-ocw",
	scripts = Latn,
}

m["bph"] = {
	"ボトリフ語",
	"Q56560",
	"cau-ava",
	aliases = {"Botlix"},
	scripts = Cyrl,
}

m["bpi"] = {
	"バグピ語",
	"Q3450697",
	"ngf-mad",
	scripts = Latn,
}

m["bpj"] = {
	"ビンジ語",
	"Q4914403",
	"bnt-lbn",
	scripts = Latn,
}

m["bpk"] = {
	"オロウェ語",
	"Q7103905",
	"poz-cln",
	scripts = Latn,
}

m["bpl"] = {
	"ブルーム採貝船ピジン",
	"Q4975277",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["bpm"] = {
	"ビヨム語",
	"Q4919327",
	"ngf-mad",
	scripts = Latn,
}

m["bpn"] = {
	"ザウミン語",
	"Q3042189",
	"hmx-mie",
}

m["bpo"] = {
	"Anasi",
	"Q11207813",
	"paa-egb",
	scripts = Latn,
}

m["bpp"] = {
	"カウレ語",
	"Q20526532",
	"paa",
	scripts = Latn,
}

m["bpq"] = {
	"バンダ・マライ語",
	"Q12473442",
	"crp",
	scripts = Latn,
	ancestors = {"ms"},
}

m["bpr"] = {
	"コロナダル・ブラアン語",
	"Q16115430",
	"phi",
	scripts = Latn,
}

m["bps"] = {
	"サランガニ・ブラアン語",
	"Q16117272",
	"phi",
	scripts = Latn,
}

m["bpt"] = {
	"バロウ・ポイント語",
	"Q2567916",
	"aus-pmn",
	scripts = Latn,
}

m["bpu"] = {
	"ボング語",
	"Q4941930",
	"ngf-mad",
	scripts = Latn,
}

m["bpv"] = {
	"ビアン・マリンド語",
	"Q8841889",
	"ngf",
	scripts = Latn,
}

m["bpx"] = {
	"パーリャ・バレリ語",
	"Q7128872",
	"inc-bhi",
	scripts = {"Deva"},
	ancestors = {"psu"},
	translit_module = "hi-translit",
}

m["bpy"] = {
	"ビシュヌプリヤ・マニプリ語",
	"Q37059",
	"inc-eas",
	aliases = {"Bishnupriya", "Manipuri Bishnupriya"},
	scripts = {"Beng"},
	ancestors = {"inc-mgd"},
}

m["bpz"] = {
	"ビルバ語",
	"Q8843362",
	"poz-tim",
	scripts = Latn,
}

m["bqa"] = {
	"チュンブリ語",
	"Q11008162",
	"alv-ctn",
	ancestors = {"ak"},
	scripts = Latn,
}

m["bqb"] = {
	"Bagusa",
	"Q4842178",
	"paa-tkw",
	scripts = Latn,
}

m["bqc"] = {
	"ボコ語",
	"Q34983",
	"dmn-bbu",
	aliases = {"Boko (Benin)"},
	scripts = Latn,
}

m["bqd"] = {
	"Bung",
	"Q3436612",
	"nic-bdn",
	scripts = Latn,
}

m["bqf"] = {
	"Baga Kaloum",
	"Q3502293",
	"alv-bag",
	scripts = Latn,
}

m["bqg"] = {
	"Bago-Kusuntu",
	"Q34878",
	"nic-gne",
}

m["bqh"] = {
	"白馬語",
	"Q674990",
	"sit-qia",
}

m["bqi"] = {
	"バクティアリ語",
	"Q257829",
	"ira-swi",
	scripts = {"fa-Arab"},
	ancestors = {"pal"},
}

m["bqj"] = {
	"バンジャル語",
	"Q34872",
	"alv-jol",
	scripts = Latn,
}

m["bqk"] = {
	"Banda-Mbrès",
	"Q3450724",
	"bad-cnt",
	scripts = Latn,
}

m["bql"] = {
	"ビラクラ語",
	"Q4907504",
	"ngf-mad",
	scripts = Latn,
}

m["bqm"] = {
	"Wumboko",
	"Q37051",
	"bnt-kpw",
	scripts = Latn,
}

m["bqn"] = {
	"ブルガリア手話",
	"Q3438325",
	"sgn",
}

m["bqo"] = {
	"Balo",
	"Q34865",
	"nic-grs",
	scripts = Latn,
}

m["bqp"] = {
	"ブサ語",
	"Q35185",
	"dmn-bbu",
	scripts = Latn,
}

m["bqq"] = {
	"Biritai",
	"Q56382",
	"paa-lkp",
	scripts = Latn,
}

m["bqr"] = {
	"ブルス語",
	"Q5001028",
	"poz-san",
	scripts = Latn,
}

m["bqs"] = {
	"ボスングン語",
	"Q56838",
	"paa",
	scripts = Latn,
}

m["bqt"] = {
	"バムクンビット語",
	"Q35078",
	"nic-nge",
	scripts = Latn,
}

m["bqu"] = {
	"ボグル語",
	"Q3438444",
	"bnt-boa",
	scripts = Latn,
}

m["bqv"] = {
	"Begbere-Ejar",
	"Q7194098",
	"nic-plc",
	scripts = Latn,
}

m["bqw"] = {
	"Buru (Nigeria)",
	"Q1017152",
	"nic-bds",
	aliases = {"Buru"},
	scripts = Latn,
}

m["bqx"] = {
	"Baangi",
	"Q3450648",
	"nic-kam",
	scripts = Latn,
}

m["bqy"] = {
	"ベンカラ手話",
	"Q3322119",
	"sgn",
}

m["bqz"] = {
	"Bakaka",
	"Q34855",
	"bnt-mne",
	scripts = Latn,
}

m["bra"] = {
	"ブラジ語",
	"Q35243",
	"inc-cen",
	otherNames = {"Braj Bhasha"},
	scripts = Deva,
	ancestors = {"inc-ohi"},
	translit_module = "hi-translit",
}


m["brb"] = {
	"ラヴェー語",
	"Q4957737",
	"mkh-ban",
	otherNames = {"Laveh", "Rawe", "Brao"},
}

m["brc"] = {
	"バービス・オランダ語クリオール",
	"Q35215",
	"crp",
	aliases = {"Berbice Dutch", "Berbice Dutch Creole", "Berbice Creole"},
	scripts = Latn,
	ancestors = {"nl"},
}

m["brd"] = {
	"Baraamu",
	"Q56804",
	"sit-new",
	scripts = Deva,
}

m["brf"] = {
	"Bera",
	"Q2896850",
	"bnt-kbi",
	aliases = {"Bira"},
	scripts = Latn,
}

m["brg"] = {
	"バウレ語",
	"Q2839722",
	"awd",
	aliases = {"Bauré"},
	scripts = Latn,
}

m["brh"] = {
	"ブラーフーイー語",
	"Q33202",
	"dra",
	scripts = {"Arab", "Latn"},
}

m["bri"] = {
	"バクエリ語",
	otherNames = {"バクウェリ語", "Bakueri", "Bakweri", "Mokpwe"},
	"Q36428",
	"bnt-kpw",
	scripts = Latn,
}

m["brj"] = {
	"ビエリア語",
	"Q4904607",
	"poz-vnc",
	scripts = Latn,
}

m["brk"] = {
	"ビルケッド語",
	"Q56823",
	"nub",
	aliases = {"Birked"},
	scripts = Latn,
}

m["brl"] = {
	"ビルワ語",
	"Q3501019",
	"bnt-sts",
	aliases = {"Sebirwa"},
	scripts = Latn,
}

m["brm"] = {
	"バランブ語",
	"Q34893",
	"znd",
	scripts = Latn,
}

m["brn"] = {
	"ボルカ語",
	"Q4946773",
	"cba",
	scripts = Latn,
}

m["bro"] = {
	"ドクカト語",
	"Q56605",
	"sit-tib",
	scripts = {"Tibt", "Latn"},
}

m["brp"] = {
	"Barapasi",
	"Q56995",
	"paa-egb",
	scripts = Latn,
}

m["brq"] = {
	"ブレリ語",
	"Q4961835",
	"paa",
	scripts = Latn,
}

m["brr"] = {
	"ビラオ語",
	"Q2904383",
	"poz-sls",
	scripts = Latn,
}

m["brs"] = {
	"バラス語",
	"Q8827053",
	"poz",
	otherNames = {"Ende", "West Kaili"},
	scripts = Latn,
}

m["brt"] = {
	"ビタレ語",
	"Q34946",
	"nic-tvn",
	otherNames = {"Njwande"},
	scripts = Latn,
}

m["bru"] = {
	"東部ブル語",
	"Q16115463",
	"mkh-kat",
	scripts = {"Latn", "Laoo", "Thai"},
}

m["brv"] = {
	"西部ブル語",
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
	"ボド語",
	"Q33223",
	"tbq-bdg",
	otherNames = {"Bodo", "Boro", "Boro (India)", "Mech"},
	scripts = {"Deva", "Latn"},
	translit_module = "brx-translit",
}

m["bry"] = {
	"Burui",
	"Q5000976",
	"paa-spk",
	scripts = Latn,
}

m["brz"] = {
	"Bilbil",
	"Q4907473",
	"poz-ocw",
	scripts = Latn,
}

m["bsa"] = {
	"アビノムン語",
	"Q56648",
	"qfa-iso",
	scripts = Latn,
}

m["bsb"] = {
	"ブルネイ・ビサヤ語",
	"Q3450611",
	"poz-san",
	scripts = Latn,
}

m["bsc"] = {
	"バサリ語",
	"Q35098",
	"alv-ten",
	otherNames = {"Basari", "Oniyan", "Onian", "Onëyan", "Ayan", "Biyan", "Wo"},
	scripts = Latn,
}

m["bse"] = {
	"Wushi",
	"Q36973",
	"nic-rnn",
	otherNames = {"Babessi"},
	scripts = Latn,
}

m["bsf"] = {
	"バウチ語",
	"Q34974",
	"nic-shi",
	scripts = Latn,
}

m["bsg"] = {
	"バシュカルディ語",
	"Q33030",
	"ira-swi",
	scripts = {"fa-Arab", "Latn"},
}

m["bsh"] = {
	"カティ語",
	"Q2605045",
	"nur-nor",
	otherNames = {"Kati"},
	ancestors = {"iir-nur-pro"},
	scripts = {"Latn", "Arab"},
}

m["bsi"] = {
	"Bassossi",
	"Q34940",
	"bnt-mne",
	scripts = Latn,
}

m["bsj"] = {
	"バングウィンジ語",
	"Q3446631",
	"alv-wjk",
	scripts = Latn,
}

m["bsk"] = {
	"ブルシャスキー語",
	"Q216286",
	"qfa-iso",
	scripts = Latn,
}

m["bsl"] = {
	"Basa-Gumna",
	"Q4866150",
	"nic-bas",
	scripts = Latn,
}

m["bsm"] = {
	"Busami",
	"Q5001255",
	"poz-hce",
	scripts = Latn,
}

m["bsn"] = {
	"バラサナ＝エドゥリア語",
	"Q2883843",
	"sai-tuc",
	scripts = Latn,
}

m["bso"] = {
	"ブソ語",
	"Q3441370",
	"cdc-est",
	scripts = Latn,
}

m["bsp"] = {
	"バガ・スィテム語",
	"Q36466",
	"alv-bag",
	scripts = Latn,
}

m["bsq"] = {
	"バサ語",
	"Q34949",
	"kro-wkr",
	scripts = {"Latn", "Bass"},
}

m["bsr"] = {
	"Bassa-Kontagora",
	"Q4866152",
	"nic-bas",
	aliases = {"Basa-Kontagora"},
	scripts = Latn,
}

m["bss"] = {
	"アコース語",
	"Q34806",
	"bnt-mne",
	scripts = Latn,
}

m["bst"] = {
	"バスケト語",
	"Q56531",
	"omv-ome",
	aliases = {"Basketto", "Baskatta", "Mesketo", "Misketto"},
	scripts = {"Ethi"},
}

m["bsu"] = {
	"Bahonsuai",
	"Q2879298",
	"poz-btk",
	scripts = Latn,
}

m["bsv"] = {
	"バガ・ソバネ語",
	"Q3450433",
	"alv-bag",
	scripts = Latn,
}

m["bsw"] = {
	"バイソ語",
	"Q56615",
	"cus",
	scripts = Latn,
}

m["bsx"] = {
	"Yangkam",
	"Q36922",
	"nic-tar",
	scripts = Latn,
}

m["bsy"] = {
	"サバ・ビサヤ語",
	"Q12641557",
	"poz-san",
	scripts = Latn,
}

m["bta"] = {
	"バタ語",
	"Q56254",
	"cdc-cbm",
	scripts = Latn,
}

m["btc"] = {
	"バティ語（カメルーン）",
	"Q34944",
	"nic-mbw",
	aliases = {"Bati"},
	scripts = Latn,
}

m["btd"] = {
	"バタク・ダイリ語",
	"Q2891045",
	"btk",
	aliases = {"Batak Dairi"},
	scripts = {"Latn", "Batk"},
}

m["bte"] = {
	"ガモ＝ニンギ語",
	"Q5520366",
	"nic-jer",
	scripts = Latn,
}

m["btf"] = {
	"ビルギット語",
	"Q56302",
	"cdc-est",
	scripts = Latn,
}

m["btg"] = {
	"ガニョア・ベテ語",
	"Q11005602",
	"kro-bet",
	scripts = Latn,
}

m["bth"] = {
	"ビアタ・ビダユ語",
	"Q2900881",
	"day",
	scripts = Latn,
}

m["bti"] = {
	"Burate",
	"Q56900",
	"paa-egb",
	scripts = Latn,
}

m["btj"] = {
	"バカン・マレー語",
	"Q8828608",
	"poz-mly",
	scripts = Latn,
}

m["btm"] = {
	"バタク・マンダイリン語",
	"Q2891049",
	"btk",
	aliases = {"Batak Mandailing"},
	scripts = {"Latn", "Batk"},
}

m["btn"] = {
	"ラタグノン語",
	"Q13197",
	"phi",
	scripts = Latn,
}

m["bto"] = {
	"リンコナダ・ビコル語",
	"Q12633026",
	"phi",
	scripts = Latn,
}

m["btp"] = {
	"ブディブド語",
	"Q4985086",
	"poz-ocw",
	scripts = Latn,
}

m["btq"] = {
	"バテック語",
	"Q860315",
	"mkh-asl",
	scripts = Latn,
}

m["btr"] = {
	"バエトラ語",
	"Q2878874",
	"poz-vnc",
	scripts = Latn,
}

m["bts"] = {
	"バタク・シマルングン語",
	"Q2891054",
	"btk",
	aliases = {"Batak Simalungun"},
	scripts = {"Latn", "Batk"},
}

m["btt"] = {
	"ベテ＝ベンディ語",
	"Q4887064",
	"nic-ben",
	scripts = Latn,
}

m["btu"] = {
	"バトゥ語",
	"Q34964",
	"nic-tvn",
	scripts = Latn,
}

m["btv"] = {
	"バテリ語",
	"Q3812564",
	"inc-dar",
	scripts = Deva,
}

m["btw"] = {
	"ブツアノン語",
	"Q5003156",
	"phi",
	scripts = Latn,
}

m["btx"] = {
	"バタク・カロ語",
	"Q33012",
	"btk",
	aliases = {"Batak Karo"},
	scripts = {"Latn", "Batk"},
}

m["bty"] = {
	"ボボト語",
	"Q3446788",
	"poz-cma",
	scripts = Latn,
}

m["btz"] = {
	"バタク・アラス＝クルット語",
	"Q2891042",
	"btk",
	aliases = {"Batak Alas-Kluet"},
	scripts = {"Latn", "Batk"},
}

m["bua"] = {
	"ブリヤート語",
	"Q33120",
	"xgn",
	aliases = {"Buriat"},
	scripts = {"Cyrl", "Mong"},
	translit_module = "bua-translit",
	override_translit = true,
	wikimedia_codes = {"bxr"},
}

m["bub"] = {
	"ブア語",
	"Q32928",
	"alv-bua",
	scripts = Latn,
}

m["bud"] = {
	"Ntcham",
	"Q36266",
	"nic-grm",
	otherNames = {"Tobote", "Ncam", "Basar", "Basari"},
	scripts = Latn,
}

m["bue"] = {
	"ベオサック語",
	"Q56234",
	scripts = Latn,
}

m["buf"] = {
	"ブショオン語",
	"Q3449964",
	"bnt-bsh",
	scripts = Latn,
}

m["bug"] = {
	"ブギ語",
	"Q33190",
	"poz-ssw",
	scripts = {"Bugi", "Latn"},
}

m["buh"] = {
	"ユヌオ・ブヌ語",
	"Q56299",
	"hmn",
	otherNames = {"Yuno"},
	scripts = Latn,
}

m["bui"] = {
	"ボンギリ語",
	otherNames = {"Bongili"},
	"Q35084",
	"bnt-ngn",
	scripts = Latn,
}

m["buj"] = {
	"Basa-Gurmana",
	"Q6432515",
	"nic-bas",
	scripts = Latn,
}

m["buk"] = {
	"Bukawa",
	"Q35043",
	"poz-ocw",
	aliases = {"Bukaua", "Bugawac", "Gawac"},
	scripts = Latn,
}

m["bum"] = {
	"ブル語 (カメルーン)",
	"Q35028",
	"bnt-btb",
	aliases = {"Bulu"},
	scripts = Latn,
}

m["bun"] = {
	"シェルブロ語",
	"Q36339",
	"alv-mel",
	scripts = Latn,
}

m["buo"] = {
	"テレイ語",
	"Q56831",
	"paa-sbo",
	scripts = Latn,
}

m["bup"] = {
	"Busoa",
	"Q5002001",
	"poz",
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
	"ボコバル語",
	"Q9228931",
	"dmn-bbu",
	scripts = Latn,
}

m["but"] = {
	"ブンガイン語",
	"Q3450623",
	"qfa-tor",
	scripts = Latn,
}

m["buu"] = {
	"ブドゥ語",
	"Q3450207",
	"bnt-nya",
	scripts = Latn,
}

m["buv"] = {
	"ブン語",
	"Q56351",
	"paa-yua",
	scripts = Latn,
}

m["buw"] = {
	"ボヴェ語",
	"Q35017",
	"bnt-tso",
	otherNames = {"Bubi", "Pove", "Vove"},
	scripts = Latn,
}

m["bux"] = {
	"ボゴム語",
	"Q3440412",
	"cdc-wst",
	scripts = Latn,
}

m["buy"] = {
	"Mmani",
	"Q35061",
	"alv-mel",
	otherNames = {"Mani", "Bullom So", "Mandingi"},
	scripts = Latn,
}

m["bva"] = {
	"バレイン語",
	"Q56285",
	"cdc-est",
	scripts = Latn,
}

m["bvb"] = {
	"ブベ語",
	"Q35110",
	"nic-bds",
	scripts = Latn,
}

m["bvc"] = {
	"バエレレア語",
	"Q2878833",
	"poz-sls",
	scripts = Latn,
}

m["bvd"] = {
	"バエグ語",
	"Q2878850",
	"poz-sls",
	aliases = {"Mbaenggu", "Baegu"},
	scripts = Latn,
}

m["bve"] = {
	"ベラウ・マレー語",
	"Q3915770",
	"poz-mly",
	scripts = Latn,
}

m["bvf"] = {
	"ボール語",
	"Q56250",
	"cdc-est",
	scripts = Latn,
}

m["bvg"] = {
	"ボンケン語",
	"Q34958",
	"bnt-bbo",
	scripts = Latn,
}

m["bvh"] = {
	"ブレ語",
	"Q56294",
	"cdc",
	scripts = Latn,
}

m["bvi"] = {
	"ベランダ・ヴィリ語",
	"Q35247",
	"nic-ser",
	scripts = Latn,
}

m["bvj"] = {
	"Baan",
	"Q3515067",
	"nic-ogo",
	scripts = Latn,
}

m["bvk"] = {
	"ブカット語",
	"Q4986814",
	"poz-bnn",
	scripts = Latn,
}

m["bvl"] = {
	"ボリビア手話",
	"Q1783590",
	"sgn",
	scripts = Latn, -- when documented
}

m["bvm"] = {
	"Bamunka",
	"Q34882",
	"nic-rnn",
	scripts = Latn,
}

m["bvn"] = {
	"ブナ語",
	"Q3450516",
	"qfa-tor",
	scripts = Latn,
}

m["bvo"] = {
	"ボルゴ語",
	"Q35038",
	"alv-bua",
	scripts = Latn,
}

m["bvp"] = {
	"Bumang",
	"Q4997235",
	"mkh-pal",
}

m["bvq"] = {
	"ビリ語",
	"Q56514",
	"csu-bkr",
	scripts = Latn,
}

m["bvr"] = {
	"ブララ語",
	"Q4998124",
	"aus-arn",
	scripts = Latn,
}

m["bvt"] = {
	"バティ語（インドネシア）",
	"Q4869253",
	"poz-cma",
	aliases = {"Bati"},
	scripts = Latn,
}

m["bvu"] = {
	"ブキット・マレー語",
	"Q9230148",
	"poz-mly",
	scripts = Latn,
}

m["bvv"] = {
	"バニバ語",
	"Q3515198",
	"awd",
	scripts = Latn,
}

m["bvw"] = {
	"ボガ語",
	"Q56262",
	"cdc-cbm",
	scripts = Latn,
}

m["bvx"] = {
	"Babole",
	"Q35180",
	"bnt-ngn",
	aliases = {"Dibole", "Bole"},
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
	"バウジ語",
	"Q56360",
	"paa-egb",
	otherNames = {"Bauzi", "Baudi", "Bauri", "バウディ語", "バウリ語"},
	scripts = Latn,
}

m["bwa"] = {
	"ブアトー語",
	"Q9232446",
	"poz-cln",
	scripts = Latn,
}

m["bwb"] = {
	"ナモシ＝ナイタシリ＝セルア語",
	"Q3130290",
	"poz-occ",
	scripts = Latn,
}

m["bwc"] = {
	"ブイレ語",
	"Q3447440",
	"bnt-sbi",
	scripts = Latn,
}

m["bwd"] = {
	"ブァイドカ語",
	"Q2929111",
	"poz-ocw",
	aliases = {"Bwaidoga"},
	scripts = Latn,
}

m["bwe"] = {
	"ボエー・カレン語",
	"Q56994",
	"kar",
}

m["bwf"] = {
	"Boselewa",
	"Q4947229",
	"poz-ocw",
	aliases = {"Bosilewa"},
	scripts = Latn,
}

m["bwg"] = {
	"バルウェ語",
	"Q8826802",
	"bnt-sna",
	scripts = Latn,
}

m["bwh"] = {
	"Bishuo",
	"Q34973",
	"nic-fru",
	scripts = Latn,
}

m["bwi"] = {
	"バニワ語",
	"Q3501735",
	"awd-nwk",
	otherNames = {"Baniba", "Baniva", "Carutana", "Carútana", "Carúzana", "Izaneni", "Karu", "Tapuya"},
	scripts = Latn,
}

m["bwj"] = {
	"Láá Láá Bwamu",
	"Q11017275",
	"nic-bwa",
	scripts = Latn,
}

m["bwk"] = {
	"バウワキ語",
	"Q4873607",
	"ngf",
	scripts = Latn,
}

m["bwl"] = {
	"ブウェラ語",
	"Q5003678",
	"bnt-bun",
	scripts = Latn,
}

m["bwm"] = {
	"ビワト語",
	"Q56352",
	"paa-yua",
	otherNames = {"Mundugumor"},
	scripts = Latn,
}

m["bwn"] = {
	"Wunai Bunu",
	"Q56452",
	"hmn",
	aliases = {"Hm Nai", "Ng-nai", "Wunai"},
}

m["bwo"] = {
	"ボロ語（エチオピア）",
	"Q56260",
	"omv-gon",
	otherNames = {"Boro", "Boro (Ethiopia)", "Borna", "Bworo", "Sinicho"},
	scripts = Latn,
}

m["bwp"] = {
	"Mandobo Bawah",
	"Q12636155",
	"ngf",
	scripts = Latn,
}

m["bwq"] = {
	"Southern Bobo",
	"Q11001714",
	"dmn-snb",
	otherNames = {"Bobo Madaré", "Southern Bobo Madaré", "Bobo", "Syabéré", "Sya", "Benge", "Sogokiré", "Voré", "Zara", "Bobo Jula", "Jula"},
	scripts = Latn,
}

m["bwr"] = {
	"ブラ＝パビル語",
	"Q56552",
	"cdc-cbm",
	otherNames = {"Bura-Pabir", "Pabir", "Burra"},
	scripts = Latn,
}

m["bws"] = {
	"Bomboma",
	"Q9229429",
	"bnt-bun",
	scripts = Latn,
}

m["bwt"] = {
	"Bafaw",
	"Q34853",
	"bnt-bbo",
	scripts = Latn,
}

m["bwu"] = {
	"ブリ語（ガーナ）",
	"Q35085",
	"nic-buk",
	aliases = {"Buli"},
	scripts = Latn,
}

m["bww"] = {
	"ブワ語",
	otherNames = {"Bwa", "Libenge", "Libwali"},
	"Q3515058",
	"bnt-bta",
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
	"nic-bwa",
	scripts = Latn,
}

m["bwz"] = {
	"ブウィシ語",
	"Q35067",
	"bnt-sir",
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
	"ベランダ・ボル語",
	"Q56678",
	"sdv-lon",
	scripts = Latn,
}

m["bxc"] = {
	"Molengue",
	"Q13345",
	"bnt-kel",
	scripts = Latn,
}

m["bxd"] = {
	"パラ語",
	"Q57000",
	"tbq-brm",
}

m["bxe"] = {
	"ビラレ語",
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
	"バンガラ語",
	"Q34989",
	"bnt-bmo",
	aliases = {"Ngala"},
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
	"バユング語",
	"Q10427485",
	"aus-psw",
	scripts = Latn,
}

m["bxk"] = {
	"ブクス語",
	"Q32930",
	"bnt-msl",
	scripts = Latn,
}

m["bxl"] = {
	"Jalkunan",
	"Q11009787",
	"dmn-jje",
	scripts = Latn,
}

m["bxn"] = {
	"ブドゥナ語",
	"Q4998313",
	"aus-psw",
	scripts = Latn,
}

m["bxo"] = {
	"Barikanchi",
	"Q3450802",
	"crp",
	aliases = {"Barikanci", "Barikanchi Pidgin"},
	scripts = Latn,
	ancestors = {"ha"},
}

m["bxp"] = {
	"Bebil",
	"Q34941",
	"bnt-btb",
	scripts = Latn,
}

m["bxq"] = {
	"ベエレ語",
	"Q56238",
	"cdc-wst",
	scripts = Latn,
}

m["bxs"] = {
	"Busam",
	"Q35189",
	"nic-grs",
	scripts = Latn,
}

m["bxv"] = {
	"Berakou",
	"Q56796",
	"csu-bgr",
	scripts = Latn,
}

m["bxw"] = {
	"Banka",
	"Q3438402",
	"dmn-smg",
	aliases = {"Bankagooma"},
	scripts = Latn,
}

m["bxz"] = {
	"ビナハリ語",
	"Q4913840",
	"ngf",
	scripts = Latn,
}

m["bya"] = {
	"バタク語",
	"Q3450443",
	"phi",
	otherNames = {"Batak"},
	scripts = {"Tagb"},
}

m["byb"] = {
	"Bikya",
	"Q33257",
	"nic-fru",
	scripts = Latn,
}

m["byc"] = {
	"ウバガラ語",
	"Q36625",
	"nic-ucn",
	scripts = Latn,
}

m["byd"] = {
	"ブニャドゥ語'",
	"Q11173588",
	"day",
	scripts = Latn,
}

m["bye"] = {
	"ポウイェ語",
	"Q7235814",
	"paa-spk",
	scripts = Latn,
}

m["byf"] = {
	"ベテ語",
	"Q32932",
	"nic-ykb",
	scripts = Latn,
}

m["byg"] = {
	"バイゴ語",
	"Q56836",
	"sdv-daj",
	scripts = Latn,
}

m["byh"] = {
	"ブジェル語",
	"Q56317",
	"sit-gma",
	scripts = Deva,
}

m["byi"] = {
	"Buyu",
	"Q5003401",
	"bnt-nyb",
	otherNames = {"Buya"},
	scripts = Latn,
}

m["byj"] = {
	"Binawa",
	"Q4913807",
	"nic-kau",
	aliases = {"Bina", "Bina (Nigeria)"},
	scripts = Latn,
}

m["byk"] = {
	"ビアオ語",
	"Q4902547",
	"qfa-tak",
	scripts = Latn, -- also Hani?
}

m["byl"] = {
	"バヨノ語",
	"Q3503856",
	"ngf",
	scripts = Latn,
}

m["bym"] = {
	"ビジャラ語",
	"Q8842355",
	"aus-pam",
	scripts = Latn,
}

m["byn"] = {
	"ビリン語",
	"Q56491",
	"cus",
	aliases = {"Bilin", "Bilen", "Belen", "Bilein"},
	scripts = {"Ethi", "Latn"},
	translit_module = "translit-redirect",
}

m["byo"] = {
	"Biyo",
	"Q56848",
	"tbq-lol",
	otherNames = {"Piyo", "Biyue"},
	scripts = {"Latn", "Hani"},
}

m["byp"] = {
	"ブマジ語",
	"Q4997234",
	"nic-ben",
	scripts = Latn,
}

m["byq"] = {
	"バサイ語",
	"Q716647",
	"map",
	aliases = {"Basai"},
	scripts = Latn,
}

m["byr"] = {
	"バルヤ語",
	"Q3450812",
	"ngf",
	scripts = Latn,
}

m["bys"] = {
	"ブラック語",
	"Q4998097",
	"alv-bwj",
	scripts = Latn,
}

m["byt"] = {
	"ベルティ語",
	"Q35008",
	"ssa-sah",
	scripts = Latn,
}

m["byv"] = {
	"メドゥンバ語",
	"Q36019",
	"bai",
	scripts = Latn,
}

m["byw"] = {
	"ベルハリヤ語",
	"Q32961",
	"sit-kie",
	scripts = Deva,
}

m["byx"] = {
	"Qaqet",
	"Q3503009",
	"paa-bng",
	otherNames = {"Kakat", "Baining"},
	scripts = Latn,
}

m["byz"] = {
	"バナロ語",
	"Q56858",
	"paa",
	scripts = Latn,
}

m["bza"] = {
	"バンディ語",
	"Q34912",
	"dmn-msw",
	aliases = {"Gbandi"},
	scripts = Latn,
}

m["bzb"] = {
	"Andio",
	"Q4754487",
	"poz-slb",
	scripts = Latn,
}

m["bzd"] = {
	"ブリブリ語",
	"Q28400",
	"cba",
	scripts = Latn,
}

m["bze"] = {
	"Jenaama Bozo",
	"Q10950633",
	"dmn-snb",
	scripts = Latn,
}

m["bzf"] = {
	"Boikin",
	"Q56829",
	"paa-spk",
	scripts = Latn,
}

m["bzg"] = {
	"バブサ語",
	"Q716615",
	"map",
	otherNames = {"Favorlang", "Poavosa", "Taokas"},
}

m["bzh"] = {
	"マポス・ブアン語",
	"Q2927370",
	"poz-ocw",
	scripts = Latn,
}

m["bzi"] = {
	"ビス語",
	"Q56852",
	"tbq-lol",
	scripts = {"Latn", "Thai"},
}

m["bzj"] = {
	"ベリーズ語",
	"Q1363055",
	"crp",
	aliases = {"Belizean Creole English", "Belizean Kriol", "Belize Kriol English", "Kriol"},
	scripts = Latn,
	ancestors = {"en"},
}

m["bzk"] = {
	"ニカラグア・クレオール語",
	"Q3504097",
	"crp",
	otherNames = {"Miskito Coast Creole", "Nicaraguan Creole English", "Nicaragua Creole English"},
	scripts = Latn,
	ancestors = {"en"},
}

m["bzl"] = {  -- supposedly also called "Bolano", but I can find no evidence of that
	"Boano (Sulawesi)",
	"Q4931258",
	"poz",
	otherNames = {"Boano", "Austronesian Boano", "Totoli Boano"},
	scripts = Latn,
}

m["bzm"] = {
	"ボロンド語",
	"Q35071",
	"bnt-bun",
	scripts = Latn,
}

m["bzn"] = {
	"Boano (Maluku)",
	"Q4931255",
	"poz-cma",
	otherNames = {"Boano", "Austronesian Boano", "Seram Boano"},
	scripts = Latn,
}

m["bzo"] = {
	"Bozaba",
	"Q4952785",
	"bnt-ngn",
	scripts = Latn,
}

m["bzp"] = {
	"Kemberano",
	"Q12634399",
	"ngf-sbh",
	scripts = Latn,
}

m["bzq"] = {
	"ブリ語",
	"Q2927952",
	"poz-hce",
	aliases = {"Buli"},
	scripts = Latn,
}

m["bzr"] = {
	"ビリ語",
	"Q4087011",
	"aus-pam",
	scripts = Latn,
}

m["bzs"] = {
	"ブラジル手話",
	"Q3436689",
	"sgn",
	otherNames = {"LGB", "LSB", "LSCB", "Libras"},
	scripts = Latn,
}

m["bzu"] = {
	"Burmeso",
	"Q56746",
	"paa-wpa",
	otherNames = {"Taurap"},
	scripts = Latn,
}

m["bzv"] = {
	"Bebe",
	"Q34977",
	"nic-bbe",
	otherNames = {"Naami"},
	scripts = Latn,
}

m["bzw"] = {
	"Basa",
	"Q34898",
	"nic-bas",
	otherNames = {"Basa (Nigeria)", "Basa-Benue"},
	scripts = Latn,
}

m["bzx"] = {
	"Hainyaxo Bozo",
	"Q11159536",
	"dmn-snb",
	scripts = Latn,
}

m["bzy"] = {
	"オバンリク語",
	"Q36276",
	"nic-ben",
	scripts = Latn,
}

m["bzz"] = {
	"エヴァント語",
	"Q35259",
	"nic-tvc",
	scripts = Latn,
}

return m