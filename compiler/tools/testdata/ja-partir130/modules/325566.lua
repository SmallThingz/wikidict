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

local Latn = {"Latn"}

local m = {}

m["zaa"] = {
	"シエラ・デ・フアレス・サポテク語",
	"Q12953989",
	"omq-zap",
	otherNames = {"Ixtlán Zapotec", "Atepec"},
	scripts = Latn,
}

m["zab"] = {
	"サン・フアン・グラビア・サポテク語",
	"Q5614751",
	"omq-zpc",
	otherNames = {"Western Tlacolula Zapotec", "Western Tlacolula Valley Zapotec", "Tlacolula Valley Zapotec", "Valley Zapotec", "San Juan Zapotec", "Guelavía Zapotec", "Santa Ana del Valle Zapotec", "Teotitlán del Valle Zapotec", "San Lucas Quiaviní Zapotec", "Tlacolula de Matamoros Zapotec", "San Jerónimo Tlacochahuaya Zapotec", "Jalieza Zapotec", "San Martín Tilcajete Zapotec"},
	scripts = Latn,
}

m["zac"] = {
	"オコトラン・サポテク語",
	"Q7076643",
	"omq-zap",
	scripts = Latn,
}

m["zad"] = {
	"カホノス・サポテク語",
	"Q5017997",
	"omq-zpc",
	otherNames = {"Southern Villa Alta Zapotec", "Yaganiza Zapotec", "Yaganiza-Xagacía Zapotec", "San Mateo Zapotec"},
	scripts = Latn,
}

m["zae"] = {
	"ヤレニ・サポテク語",
	"Q12645368",
	"omq-zap",
	otherNames = {"Western Ixtlán Zapotec", "Etla Zapotec"},
	scripts = Latn,
}

m["zaf"] = {
	"Ayoquesco Zapotec",
	"Q4831570",
	"omq-zpc",
	scripts = Latn,
}

m["zag"] = {
	"ザガワ語",
	"Q37007",
	"ssa-sah",
	aliases = {"Zakhawa", "Beria"},
	scripts = Latn, -- also Beria
}

m["zah"] = {
	"ザングワル語",
	"Q3441387",
	"cdc-wst",
	scripts = Latn,
}

m["zai"] = {
	"地峡サポテク語",
	"Q56728",
	"omq-zpc",
	scripts = Latn,
}

m["zaj"] = {
	"ザラモ語",
	"Q8066599",
	"bnt-ruv",
	scripts = Latn,
}

m["zak"] = {
	"ザナキ語",
	"Q8066018",
	"bnt-lok",
	scripts = Latn,
}

m["zal"] = {
	"ザオゾウ語",
	"Q3616358",
	"tbq-lol",
	scripts = {"Latn", "Hani"},
}

m["zam"] = {
	"ミアワトラン・サポテク語",
	"Q13541830",
	"omq-zap",
	scripts = Latn,
}

m["zao"] = {
	"オソロテペック・サポテク語",
	"Q7116610",
	"omq-zap",
	scripts = Latn,
}

m["zap"] = {
	"ザポテック語",
	"Q13214",
	"omq-zap",
	scripts = Latn,
}

m["zaq"] = {
	"アロアパム・サポテク語",
	"Q4734726",
	"omq-zap",
	scripts = Latn,
}

m["zar"] = {
	"リンコン・サポテク語",
	"Q7334628",
	"omq-zap",
	scripts = Latn,
}

m["zas"] = {
	"サント・ドミンゴ・アルバラデス・サポテク語",
	"Q4709425",
	"omq-zap",
	scripts = Latn,
}

m["zat"] = {
	"タバア・サポテク語",
	"Q7672849",
	"omq-zap",
	scripts = Latn,
}

m["zau"] = {
	"ザンスカール語",
	"Q771203",
	"sit-lab",
	aliases = {"Zanskari"},
	scripts = {"Tibt"},
	ancestors = {"lbj"},
}

m["zav"] = {
	"ヤツァチ・サポテク語",
	"Q8050301",
	"omq-zpc",
	scripts = Latn,
}

m["zaw"] = {
	"ミトラ・サポテク語",
	"Q3053288",
	"omq-zpc",
	scripts = Latn,
}

m["zax"] = {
	"サダニ・サポテク語",
	"Q8042823",
	"omq-zap",
	scripts = Latn,
}

m["zay"] = {
	"ザイセ＝ゼルグラ語",
	"Q673895",
	"omv-eom",
	scripts = Latn,
}

m["zaz"] = {
	"ザリ語",
	"Q3914398",
	"cdc-wst",
	scripts = Latn,
}

m["zbt"] = {
	"Batui",
	"Q16839143",
	"poz-slb",
	scripts = Latn,
}

m["zca"] = {
	"コアテカス・アルタス・サポテク語",
	"Q5138603",
	"omq-zap",
	scripts = Latn,
}

m["zdj"] = {
	"ンガズィジャ・コモロ語",
	"Q3114653",
	"bnt-com",
	aliases = {"Ngazidja", "Shingazidja"},
	scripts = Latn,
		sort_key = {
		from = {"ɓ", "ɗ"},
		to   = {"bz", "dz"}} ,
}

m["zea"] = {
	"ゼーランド語",
	"Q237409",
	"gmw",
	scripts = Latn,
	ancestors = {"dum"},
	sort_key = {
		from = {"^'([aeiouy].*)$"},
		to   = {"%1'"},
	}
}

m["zeg"] = {
	"Zenag",
	"Q12953345",
	"poz-ocw",
	scripts = Latn,
}

m["zen"] = {
	"ゼナガ語",
	"Q37005",
	"ber",
	scripts = Latn,
}

m["zga"] = {
	"キンガ語",
	"Q11005332",
	"bnt-bki",
	scripts = Latn,
}

m["zgh"] = {
	"標準モロッコ・タマジクト語",
	7598268,
	"ber",
	"Tfng",
	translit = "Tfng-translit",
}

m["zgr"] = {
	"マゴリ語",
	"Q3277370",
	"poz-ocw",
	scripts = Latn,
}

m["zhb"] = {
	"ジャバ語",
	"Q56334",
	"sit-qia",
	aliases = {"Zaba"},
}

m["zhi"] = {
	"Zhire",
	"Q3914910",
	"nic-plc",
	varieties = {"Shang"},
	scripts = Latn,
}

m["zhn"] = {
	"硯広チワン語",
	"Q7049385",
	"tai-cen",
	aliases = {"Yanguang Zhuang", "Western Nung", "Nung Din"},
	scripts = {"Latn"},
	sort_key = {
		from = {"%p"},
		to   = {""}},
}

m["zhw"] = {
	"Zhoa",
	"Q8070885",
	"nic-rnw",
	scripts = Latn,
}

m["zia"] = {
	"ジア語",
	"Q3038636",
	"ngf",
	scripts = Latn,
}

m["zib"] = {
	"ジンバブエ手話",
	"Q8072097",
	"sgn",
}

m["zik"] = {
	"ジマカニ語",
	"Q56740",
	"ngf",
	scripts = Latn,
}

m["zil"] = {
	"Zialo",
	"Q36991",
	"dmn-msw",
	scripts = Latn,
}

m["zim"] = {
	"メスメ語",
	"Q56282",
	"cdc-mas",
	scripts = Latn,
}

m["zin"] = {
	"ジンザ語",
	"Q8072460",
	"bnt-haj",
	scripts = Latn,
}

m["zir"] = {
	"ズィリヤ語",
	"Q3913943",
	"nic-jer",
	scripts = Latn,
}

m["ziw"] = {
	"ジグア語",
	otherNames = {"Zigua", "Zigula"},
	"Q37010",
	"bnt-seu",
	scripts = Latn,
}

m["ziz"] = {
	"ズィズィリヴァカン語",
	"Q56300",
	"cdc-cbm",
	scripts = Latn,
}

m["zka"] = {
	"Kaimbulawa",
	"Q6348011",
	"poz-mun",
	scripts = Latn,
}

m["zkb"] = {
	"コイバル語",
	"Q949259",
	"syd",
	scripts = {"Latn", "Cyrl"},
}

m["zkg"] = {
	"高句麗語",
	"Q706327",
	"qfa-kor",
	scripts = {"Hani"},
}

m["zkh"] = {
	"ホレズム語",
	"Q25502",
	"trk",
	aliases = {"Khorezmian", "Khorezmian-Turkic"},
	scripts = {"Arab"},
}

m["zkk"] = {
	"カランカワ語",
	"Q3192947",
	scripts = Latn,
}

m["zko"] = {
	"コット語",
	"Q34163",
	"qfa-yen",
	scripts = Latn,
}

m["zkp"] = {
	"サンパウロ・カインガンギ語",
	"Q7665661",
	"sai-jee",
	scripts = Latn,
}

m["zkr"] = {
	"Zakhring",
	"Q56996",
	"sit-mdz",
	scripts = {"Latn", "Hani"},
}

m["zkt"] = {
	"契丹語",
	"Q1064482",
	"xgn",
	scripts = {"Kitl", "Kits"},
}

m["zku"] = {
	"カウナ語",
	"Q6378899",
	"aus-psw",
	scripts = Latn,
}

m["zkv"] = {
	"クリエヴィニ・ヴォート語",
	"Q6436902",
	"fiu-fin",
	scripts = Latn,
	ancestors = {"vot"},
}

m["zkz"] = {
	"ハザール語",
	"Q1067986",
	"trk",
	scripts = {"Orkh"},
}

m["zle"] = {
	"東スラヴ語群",
	"Q144713",
	scripts = {"Latn", "Cyrl"},
}

m["zls"] = {
	"南スラヴ語群",
	"Q146665",
	scripts = {"Latn", "Cyrl"},
}

m["zlw"] = {
	"西スラヴ語群",
	"Q145852",
	scripts = {"Latn", "Cyrl"},
}

m["zma"] = {
	"マンダ語(オーストラリア)",
	"Q18650060",
	"aus-dal",
	scripts = Latn,
}

m["zmb"] = {
	"ジンバ語",
	"Q8071960",
	"bnt-lgb",
	scripts = Latn,
}

m["zmc"] = {
	"マルガン語",
	"Q10577017",
	"aus-pam",
	scripts = Latn,
}

m["zmd"] = {
	"マリダン語",
	"Q10577273",
	"aus-dal",
	scripts = Latn,
}

m["zme"] = {
	"マンゲル語",
	"Q10576387",
	scripts = Latn,
}

m["zmf"] = {
	"ンフィヌ語",
	otherNames = {"Mfinu"},
	"Q35915",
	"bnt-tek",
	scripts = Latn,
}

m["zmg"] = {
	"Marti Ke",
	"Q10577823",
	"aus-dal",
	scripts = Latn,
}

m["zmh"] = {
	"Makolkol",
	"Q12636052",
	"paa-bng",
	scripts = Latn,
}

m["zmi"] = {
	"ヌグリ・スンビラン・マレー語",
	"Q3915909",
	"poz-mly",
	scripts = Latn,
}

m["zmj"] = {
	"マリジャビン語",
	"Q10577274",
	"aus-dal",
	scripts = Latn,
}

m["zmk"] = {
	"マンダンダニ語",
	"Q10576338",
	"aus-pam",
	scripts = Latn,
}

m["zml"] = {
	"マドゥンゲレ語",
	"Q10575155",
	"aus-dal",
	scripts = Latn,
}

m["zmm"] = {
	"マリマニンジ語",
	"Q10577424",
	"aus-dal",
	scripts = Latn,
}

m["zmn"] = {
	"Mbangwe",
	"Q35928",
	"bnt-kel",
	scripts = Latn,
}

m["zmo"] = {
	"モロ語",
	"Q15974357",
	"sdv-eje",
	aliases = {"Malkan"},
	scripts = Latn,
}

m["zmp"] = {
	"Mbuun",
	"Q106249400",
	"bnt",
	scripts = Latn,
}

m["zmq"] = {
	"ミトゥク語",
	"Q6883590",
	"bnt-mbe",
	scripts = Latn,
}

m["zmr"] = {
	"マラヌング語",
	"Q6772792",
	"aus-dal",
	aliases = {"Maranunggu", "Marranunggu", "Marranungku", "Maranunga", "Marranungga", "Maranunggo"},
	scripts = Latn,
}

m["zms"] = {
	"ンベサ語",
	otherNames = "Mbesa",
	"Q6799676",
	"bnt-ske",
	scripts = Latn,
}

m["zmt"] = {
	"マリンガル語",
	"Q10577443",
	"aus-dal",
	scripts = Latn,
}

m["zmu"] = {
	"ムルワリ語",
	"Q3915442",
	"aus-pam",
	scripts = Latn,
}

m["zmv"] = {
	"ムバリマン・グディンマ語",
	"Q3915672",
	"aus-pmn",
	aliases = {"Rimanggudhinma", "Rimang-Gudinhma", "Parimankutinma"},
	scripts = Latn,
}

m["zmw"] = {
	"ンボ語(コンゴ)",
	"Q6799710",
	"bnt-nya",
	aliases = {"Mbo (Democratic Republic of the Congo)", "Mbo"},
	scripts = Latn,
}

m["zmx"] = {
	"ボミタバ語",
	"Q35063",
	"bnt-ngn",
	scripts = Latn,
}

m["zmy"] = {
	"マリイェディ語",
	"Q10577501",
	"aus-dal",
	scripts = Latn,
}

m["zmz"] = {
	"ンバンジャ語",
	"Q3915310",
	"bad",
	scripts = Latn,
}

m["zna"] = {
	"ザン・グラ語",
	"Q863726",
	"alv-bua",
	scripts = Latn,
}

m["zne"] = {
	"ザンデ語",
	otherNames = "Zande",
	"Q35015",
	"znd",
	scripts = Latn,
}

m["zng"] = {
	"マン語",
	"Q720192",
	"mkh-mng",
}

m["znk"] = {
	"Manangkari",
	"Q6746906",
	"aus-wdj",
	aliases = {"Naragani"},
	scripts = Latn,
}

m["zns"] = {
	"マガス語",
	"Q3438780",
	"cdc-wst",
	scripts = Latn,
}

m["zoc"] = {
	"コパイナラ・ソケ語",
	"Q12954017",
	"nai-miz",
	scripts = Latn,
}

m["zoh"] = {
	"チマラパ・ソケ語",
	"Q5099289",
	"nai-miz",
	scripts = Latn,
}

m["zom"] = {
	"ゾウ語",
	"Q37011",
	"tbq-kuk",
	aliases = {"Zo", "Yo", "Yos"},
}

m["zoo"] = {
	"アスンシオン・ミステペック・サポテク語",
	"Q4811888",
	"omq-zap",
	scripts = Latn,
}

m["zoq"] = {
	"タバスコ・ソケ語",
	"Q323325",
	"nai-miz",
	scripts = Latn,
}

m["zor"] = {
	"ラヨン・ソケ語",
	"Q12954015",
	"nai-miz",
	scripts = Latn,
}

m["zos"] = {
	"フランシスコ・レオン・ソケ語",
	"Q12954011",
	"nai-miz",
	scripts = Latn,
}

m["zpa"] = {
	"ラチグイリ・サポテク語",
	"Q6468403",
	"omq-zap",
	scripts = Latn,
}

m["zpb"] = {
	"ヤウテペク・サポテク語",
	"Q7413392",
	"omq-zap",
	scripts = Latn,
}

m["zpc"] = {
	"チョアパン・サポテク語",
	"Q5103425",
	"omq-zap",
	aliases = {"Choapan Zapoteco"},
	scripts = Latn,
}

m["zpd"] = {
	"南東部イストラン・サポテク語",
	"Q8050392",
	"omq-zap",
	scripts = Latn,
}

m["zpe"] = {
	"ペタパ・サポテク語",
	"Q7171675",
	"omq-zap",
	scripts = Latn,
}

m["zpf"] = {
	"サン・ペドロ・キアトニン・サポテク語",
	"Q7271640",
	"omq-zpc",
	scripts = Latn,
}

m["zpg"] = {
	"Guevea de Humboldt Zapotec",
	"Q13459953",
	"omq-zap",
	scripts = Latn,
}

m["zph"] = {
	"Totomachapan Zapotec",
	"Q7828390",
	"omq-zap",
	scripts = Latn,
}

m["zpi"] = {
	"サンタ・マリア・キエゴラニ・サポテク語",
	"Q7271823",
	"omq-zpc",
	scripts = Latn,
}

m["zpj"] = {
	"Quiavicuzas Zapotec",
	"Q7271642",
	"omq-zap",
	scripts = Latn,
}

m["zpk"] = {
	"トラコルリタ・サポテク語",
	"Q7810685",
	"omq-zpc",
	scripts = Latn,
}

m["zpl"] = {
	"ラチシオ・サポテク語",
	"Q6468420",
	"omq-zap",
	scripts = Latn,
}

m["zpm"] = {
	"ミステペック・サポテク語",
	"Q7414598",
	"omq-zpc",
	scripts = Latn,
}

m["zpn"] = {
	"サンタ・イネス・ヤツェチ・サポテク語",
	"Q8050300",
	"omq-zap",
	scripts = Latn,
}

m["zpo"] = {
	"アマトラン・サポテク語",
	"Q4740613",
	"omq-zpc",
	scripts = Latn,
}

m["zpp"] = {
	"エル・アルト・サポテク語",
	"Q5350733",
	"omq-zap",
	aliases = {"El Alto Zapoteco"},
	scripts = Latn,
}

m["zpq"] = {
	"ソオゴチョ・サポテク語",
	"Q8074100",
	"omq-zpc",
	scripts = Latn,
}

m["zpr"] = {
	"サンティアゴ・サニカ・サポテク語",
	"Q8042924",
	"omq-zap",
	scripts = Latn,
}

m["zps"] = {
	"コアトラン・サポテク語",
	"Q7420514",
	"omq-zap",
	scripts = Latn,
}

m["zpt"] = {
	"サン・ビセンテ・コアトラン・サポテク語",
	"Q13541831",
	"omq-zap",
	scripts = Latn,
}

m["zpu"] = {
	"ヤララグ・サポテク語",
	"Q8047534",
	"omq-zpc",
	scripts = Latn,
}

m["zpv"] = {
	"チチカパン・サポテク語",
	"Q5096050",
	"omq-zap",
	scripts = Latn,
}

m["zpw"] = {
	"サニサ・サポテク語",
	"Q8066220",
	"omq-zpc",
	scripts = Latn,
}

m["zpx"] = {
	"サン・バルタサル・ロシチャ・サポテク語",
	"Q7413390",
	"omq-zap",
	scripts = Latn,
}

m["zpy"] = {
	"マサルテペク・サポテク語",
	"Q6798223",
	"omq-zap",
	scripts = Latn,
}

m["zpz"] = {
	"テスメルカン・サポテク語",
	"Q7708357",
	"omq-zpc",
	scripts = Latn,
}

m["zra"] = {
	"加羅語",
	"Q5528695",
	"qfa-kor",
	aliases = {"Kara"},
}

m["zrg"] = {
	"ミルガン語",
	"Q6873206",
	"inc-eas",
	aliases = {"Panika"},
	ancestors = {"inc-mgd"},
}

m["zrn"] = {
	"ゼレンケル語",
	"Q3441365",
	"cdc-est",
	scripts = Latn,
}

m["zro"] = {
	"サパロ語",
	"Q10206",
	"sai-zap",
	aliases = {"Zaparo"},
	varieties = {"Conambo"}, -- Conambo refers to two dialects, one sometimes considered a language
	scripts = Latn,
}

m["zrs"] = {
	"マイラシ語",
	"Q3038645",
	"paa-mai",
	scripts = Latn,
}

m["zsa"] = {
	"Sarasira",
	nil,
	"poz-ocw",
}

m["zsk"] = { -- attested?
	"Kaskean",
	"Q6374586",
	aliases = {"Kaskian"},
}

m["zsl"] = {
	"ザンビア手話",
	"Q8065713",
	"sgn",
}

m["zsr"] = {
	"南部リンコン・サポテク語",
	"Q12954000",
	"omq-zpc",
	scripts = Latn,
}

m["zsu"] = {
	"スクルム語",
	nil,
	"poz-ocw",
}

m["zte"] = {
	"エロテペック・サポテク語",
	"Q5367223",
	"omq-zap",
	scripts = Latn,
}

m["ztg"] = {
	"サナグイア・サポテク語",
	"Q8042887",
	"omq-zpc",
	scripts = Latn,
}

m["ztl"] = {
	"Lapaguía-Guivini Zapotec",
	"Q6488084",
	"omq-zap",
	scripts = Latn,
}

m["ztm"] = {
	"サン・アグスティン・ミステペック・サポテク語",
	"Q7413220",
	"omq-zap",
	scripts = Latn,
}

m["ztn"] = {
	"サンタ・カタリーナ・アルバラデス・サポテク語",
	"Q7419277",
	"omq-zap",
	scripts = Latn,
}

m["ztp"] = {
	"ロシチャ・サポテク語",
	"Q6694268",
	"omq-zap",
	scripts = Latn,
}

m["ztq"] = {
	"キオキタニ＝キエリ・サポテク語",
	"Q3574818",
	"omq-zpc",
	scripts = Latn,
}

m["zts"] = {
	"ティルキアパン・サポテク語",
	"Q7802959",
	"omq-zpc",
	scripts = Latn,
}

m["ztt"] = {
	"テハラパン・サポテク語",
	"Q13510225",
	"omq-zap",
	scripts = Latn,
}

m["ztu"] = {
	"ギラ・サポテク語",
	"Q5626813",
	"omq-zap",
	scripts = Latn,
}

m["ztx"] = {
	"サアチラ・サポテク語",
	"Q8063390",
	"omq-zap",
	aliases = {"Zaachila Zapoteco"},
	scripts = Latn,
}

m["zty"] = {
	"ヤテエ・サポテク語",
	"Q3574815",
	"omq-zpc",
	scripts = Latn,
}

m["zua"] = {
	"ゼーム語",
	"Q3450131",
	"cdc",
	scripts = Latn,
}

m["zuh"] = {
	"Tokano",
	"Q7813481",
	"ngf",
	scripts = Latn,
}

m["zum"] = {
	"クムザール語",
	"Q36158",
	"ira-swi",
}

m["zun"] = {
	"ズニ語",
	"Q10188",
	"qfa-iso",
	aliases = {"Zuñi", "Shiwi'ma"},
	scripts = Latn,
}

m["zuy"] = {
	"ズマヤ語",
	"Q56626",
	"cdc-mas",
	scripts = Latn,
}

m["zwa"] = {
	"ザイ語",
	"Q10195",
	"sem-eth",
}

m["zyp"] = {
	"Zyphe",
	"Q57004",
	"tbq-kuk",
	aliases = {"Zyphe Chin", "Zophei", "Zoptei", "Vawngtu"},
	scripts = Latn,
}

m["zza"] = {
	"ザザキ語",
	"Q10199",
	"ira-zgr",
	aliases = {"Zaza"},
	scripts = Latn,
	wikimedia_codes = {"diq"},
}

m["zzj"] = {
	"左江チワン語",
	"Q13848149",
	"tai-cen",
	scripts = {"Latn"},
	sort_key = {
		from = {"%p"},
		to   = {""}},
}

return m