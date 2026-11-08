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

m["faa"] = {
	"ファス語",
	"Q3446687",
	"paa-kut",
	otherNames = {"Namumi", "Namome", "Namo Me", "Kaipu", "Kaibu", "Some"},
	scripts = Latn,
}

m["fab"] = {
	"アノボネセ語",
	"Q34992",
	"crp",
	otherNames = {"Fa d'Ambu"},
	scripts = Latn,
	ancestors = {"pt"},
}

m["fad"] = {
	"Wagi",
	"Q7959569",
	"ngf-mad",
	scripts = Latn,
}

m["faf"] = {
	"ファガニ語",
	"Q3063759",
	"poz-sls",
	aliases = {"Faghani"},
	scripts = Latn,
}

m["fag"] = {
	"Finongan",
	"Q3450761",
	"ngf-fin",
	scripts = Latn,
}

m["fah"] = {
	"Baissa Fali",
	"Q3446632",
	"nic-bco",
	aliases = {"Fali of Baissa"},
	scripts = Latn,
}

m["fai"] = {
	"ファイウォル語",
	"Q3501773",
	"ngf-okk",
	scripts = Latn,
}

m["faj"] = {
	"ファイタ語",
	"Q976953",
	"ngf-mad",
	scripts = Latn,
}

m["fak"] = {
	"ファン語（カメルーン）",
	"Q5433811",
	"nic-beb",
	aliases = {"Fang", "Fang (Cameroon)"},
	scripts = Latn,
}

m["fal"] = {
	"南ファリ語",
	"Q15637351",
	"alv-fli",
	scripts = Latn,
}

m["fam"] = {
	"Fam",
	"Q35290",
	"nic-mmb",
	scripts = Latn,
}

m["fan"] = {
	"ファン語",
	"Q33484",
	"bnt-btb",
	aliases = {"Pahouin", "Fang (Equatorial Guinea)", "Fang (Gabon)", "Fang"},
	scripts = Latn,
}

m["fap"] = {
	"Palor",
	"Q36318",
	"alv-cng",
	otherNames = {"Paloor", "Falor", "Palar", "Sili", "Sili-Sili", "Waro"},
	scripts = Latn,
}

m["far"] = {
	"ファタレカ語",
	"Q3067168",
	"poz-sls",
	scripts = Latn,
}

-- "fat" IS TREATED AS "ak", SEE WT:LT

m["fau"] = {
	"Fayu",
	"Q5439113",
	"paa-lkp",
	scripts = Latn,
}

m["fax"] = {
	"ファラ語",
	"Q300402",
	"roa-ibe",
	scripts = Latn,
	ancestors = {"roa-opt"},
}

m["fay"] = {
	"南部ファールス語",
	"Q5228140",
	"ira-swi",
}

m["faz"] = {
	"北西部ファールス語",
	"Q7060307",
	"ira-swi",
}

m["fbl"] = {
	"西アルバイ・ビコル語",
	"Q18603801",
	"phi",
	scripts = Latn,
}

m["fcs"] = {
	"ケベック手話",
	"Q13193",
	"sgn",
	scripts = Latn, -- when documented
}

m["fer"] = {
	"フリウリ語",
	"Q35287",
	"nic-ser",
	scripts = Latn,
}

m["ffi"] = {
	"Foia Foia",
	"Q8564176",
	"ngf",
	scripts = Latn,
}

-- "ffm" IS TREATED AS "ff", SEE WT:LT

m["fgr"] = {
	"Fongoro",
	"Q3437645",
	"csu",
	scripts = Latn,
}

m["fia"] = {
	"Nobiin",
	"Q36503",
	"nub",
	scripts = Latn,
	ancestors = {"onw"},
}

m["fie"] = {
	"フィエル語",
	"Q56273",
	"cdc-wst",
	scripts = Latn,
}

m["fil"] = {
	"フィリピン語",
	"Q33298",
	"phi",
	scripts = Latn,
	entry_name = {
		from = {"[áàâ]", "[éèê]", "[íìî]", "[óòô]", "[úùû]", ACUTE, GRAVE, CIRC},
		to   = {"a"    , "e"    , "i"    , "o"    , "u"    }},
}

m["fip"] = {
	"フィパ語",
	"Q667747",
	"bnt-mwi",
	scripts = Latn,
}

m["fir"] = {
	"フィラン語",
	"Q3915847",
	"nic-plc",
	scripts = Latn,
}

m["fit"] = {
	"メアンキエリ",
	"Q13357",
	"fiu-fin",
	scripts = Latn,
	ancestors = {"fi"},
}

m["fiw"] = {
	"フィワガ語",
	"Q5456292",
	"paa-kut",
	scripts = Latn,
}

m["fkk"] = {
	"Kirya-Konzel",
	"Q6416310",
	"cdc-cbm",
	aliases = {"Kirya-Konzəl"},
	scripts = Latn,
}

m["fkv"] = {
	"クヴェン語",
	"Q165795",
	"fiu-fin",
	scripts = Latn,
	ancestors = {"fi"},
}

m["fla"] = {
	"カリスペル＝ペンド・オレイル語",
	"Q3111983",
	"sal",
	otherNames = {"Flathead", "Salish", "Séliš", "Kalispel-Pend d'oreille", "Kalispel"},
	scripts = Latn,
}

m["flh"] = {
	"フォアウ語",
	"Q5463819",
	"paa-lkp",
	scripts = Latn,
}

m["fli"] = {
	"ファリ語",
	"Q56244",
	"cdc-cbm",
	aliases = {"Fali of Mubi"},
	scripts = Latn,
}

m["fll"] = {
	"北ファリ語",
	"Q12952419",
	"alv-fli",
	scripts = Latn,
}

m["fln"] = {
	"Flinders Island",
	"Q3915702",
	"aus-pmn",
	otherNames = {"Yalgawarra", "Wurima", "Mutumui"},
	scripts = Latn,
}

m["flr"] = {
	"フリル語",
	"Q7166821",
	"bnt-shh",
	scripts = Latn,
}

m["fly"] = {
	"ツォツィタール",
	"Q12643960",
	"crp",
	ancestors = {"af"},
	otherNames = {"Flaaitaal"},
	scripts = Latn,
}

m["fmp"] = {
	"フェフェ語",
	"Q35276",
	"bai",
	scripts = Latn,
}

m["fmu"] = {
	"極西部ムリア語",
	"Q42589412",
	"dra",
	ancestors = {"gon"},
}

m["fng"] = {
	"ファナガロ語",
	"Q35727",
	"crp",
	scripts = Latn,
	ancestors = {"zu"},
}

m["fni"] = {
	"Fania",
	"Q317642",
	"alv-bua",
	scripts = Latn,
}

m["fod"] = {
	"Foodo",
	"Q5465566",
	"alv-gng",
	scripts = Latn,
}

m["foi"] = {
	"フォイ語",
	"Q5464146",
	"paa-kut",
	scripts = Latn,
}

m["fom"] = {
	"Foma",
	"Q5464911",
	"bnt-ske",
	ancestors = {"khy"},
	scripts = Latn,
}

m["fon"] = {
	"フォン語",
	"Q33291",
	"alv-gbe",
	scripts = Latn,
}

m["for"] = {
	"フォレ語",
	"Q3077126",
	"paa-kag",
	scripts = Latn,
}

m["fos"] = {
	"シラヤ語",
	"Q716604",
	"map",
	scripts = Latn,
}

m["fpe"] = {
	"フェルナンド・ポー・クリオール語",
	"Q35288",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["fqs"] = {
	"ファス語",
	"Q56320",
	"paa",
	scripts = Latn,
}

-- "frc" IS TREATED AS "fr" (or as etymology-only), SEE WT:LT

m["frd"] = {
	"フォルダタ語",
	"Q5468035",
	"poz",
	scripts = Latn,
}

m["frk"] = {
	"古フランク語",
	nil,
}

m["frm"] = {
	"中期フランス語",
	"Q1473289",
	"roa-oil",
	scripts = Latn,
	ancestors = {"fro"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["fro"] = {
	"古フランス語",
	"Q35222",
	"roa-oil",
	varieties = { {"Judeo-French", "Zarphatic"} },
	scripts = {"Latn", "Hebr"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["frp"] = {
	"アルピタン語",
	"Q15087",
	"roa",
	aliases = {"Arpetan", "Arpitan"},
	scripts = Latn,
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["frq"] = {
	"フォラク語",
	"Q5467173",
	"ngf-fin",
	scripts = Latn,
}

m["frr"] = {
	"北フリジア語",
	"Q28224",
	"gmw-fri",
	scripts = Latn,
}

-- "frs" IS NOT USED, SEE WT:LT

m["frs"] = {
	"低地ドイツ語東フリースラント方言",
	scripts = Latn,
}

m["frt"] = {
	"Fortsenal",
	"Q2666835",
	"poz-vnc",
	scripts = Latn,
}

m["fse"] = {
	"フィンランド手話",
	"Q33225",
	"sgn",
	scripts = Latn, -- when documented
}

m["fsl"] = {
	"フランス手話",
	"Q33302",
	"sgn-fsl",
	scripts = Latn, -- when documented
}

m["fss"] = {
	"Finnish-Swedish Sign Language",
	"Q5450448",
	"sgn",
	scripts = Latn, -- when documented
}

-- "fub" IS TREATED AS "ff", SEE WT:LT

-- "fuc" IS TREATED AS "ff", SEE WT:LT

m["fud"] = {
	"東部フツナ語",
	"Q35334",
	"poz-pnp",
	aliases = {"Futunan", "Futunian", "Futuna"},
	scripts = Latn,
}

-- "fue" IS TREATED AS "ff", SEE WT:LT

-- "fuf" IS TREATED AS "ff", SEE WT:LT

-- "fuh" IS TREATED AS "ff", SEE WT:LT

-- "fui" IS TREATED AS "ff", SEE WT:LT

m["fuj"] = {
	"コ語",
	"Q35693",
	"alv-hei",
	scripts = Latn,
}

m["fum"] = {
	"Fum",
	"Q11011870",
	"nic-nka",
	scripts = Latn,
}

m["fun"] = {
	"フルニオ語",
	"Q774441",
	"qfa-iso",
	scripts = Latn,
}

-- "fuq" IS TREATED AS "ff", SEE WT:LT

m["fur"] = {
	"フリウリ語",
	"Q33441",
	"roa-rhe",
	scripts = Latn,
}

m["fut"] = {
	"アニワ・フツナ語",
	"Q3064409",
	"poz-pnp",
	scripts = Latn,
}

m["fuu"] = {
	"フル語",
	"Q3441160",
	"csu-bkr",
	scripts = Latn,
}

-- "fuv" IS TREATED AS "ff", SEE WT:LT

m["fuy"] = {
	"フユグ語",
	"Q3073472",
	"ngf",
	scripts = Latn,
}

m["fvr"] = {
	"フル語",
	"Q33364",
	"ssa-fur",
	scripts = Latn,
}

m["fwa"] = {
	"フワイ語",
	"Q3091331",
	"poz-cln",
	scripts = Latn,
}

m["fwe"] = {
	"フェ語",
	"Q5511159",
	"bnt-bot",
	scripts = Latn,
}

return m