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

m["vaa"] = {
	"ヴァーグリ・ボーリ語",
	"Q7907798",
}

m["vae"] = {
	"バレ語",
	"Q3450194",
	"csu-val",
}

m["vag"] = {
	"Vagla",
	"Q36637",
	"nic-gnw",
}

m["vah"] = {
	"ヴァルハディ＝ナーグプリ語",
	"Q155645",
	"inc-sou",
	ancestors = {"mr"},
}

m["vai"] = {
	"ヴァイ語",
	"Q36939",
	"dmn-vak",
	otherNames = {"Gallinas", "Vy"},
	scripts = {"Vaii"},
	translit_module = "Vaii-translit",
}

m["vaj"] = {
	"Sekele",
	"Q56528",
	otherNames = {"Sekela", "Vasekele", "Vasekela", "Vasekela Bushman", "ǃ'OǃKung"},
}

m["val"] = {
	"Vehes",
	"Q7918407",
}

m["vam"] = {
	"ヴァニモ語",
	"Q3327415",
	"paa-msk",
}

m["van"] = {
	"ヴァルマン語",
	"Q7912479",
	"qfa-tor",
}

m["vao"] = {
	"ヴァオ語",
	"Q2160405",
	"poz-vnc",
}

m["vap"] = {
	"ヴァイペイ語",
	"Q56368",
	"tbq-kuk",
}

m["var"] = {
	"Huarijio",
	"Q10974017",
	"azc-trc",
	otherNames = {"Guarijío", "Varihío", "Warihío"},
	scripts = Latn,
}

m["vas"] = {
	"ヴァサヴィ語",
	"Q765418",
}

m["vau"] = {
	"ヴァヌマ語",
	"Q7915259",
	"bnt-nya",
}

m["vav"] = {
	"ヴァルリ語",
	"Q7915983",
	"inc-sou",
	otherNames = {"Warli"},
	scripts = {"Deva", "Gujr"},
}

m["vay"] = {
	"ワユ語",
	"Q7917585",
	"sit-kiw",
}

m["vbb"] = {
	"南東ババール語",
	"Q12952247",
	"poz-tim",
}

m["vbk"] = {
	"南西部ボントク語",
	nil,
	"phi",
	otherNames = {"Southwestern Bontok"},
	scripts = Latn,
}

m["vec"] = {
	"ヴェネツィア語",
	"Q32724",
	"roa",
	aliases = {"Venetan"},
	scripts = Latn,
}

m["ved"] = {
	"ヴェッダ語",
	"Q2567934",
}

m["vem"] = {
	"ヴェンゴ＝マバス語",
	"Q56268",
}

m["veo"] = {
	"ヴェントゥレーニョ語",
	"Q56712",
	"nai-chu",
	scripts = Latn,
}

m["vep"] = {
	"ヴェプス語",
	"Q32747",
	"fiu-fin",
	scripts = Latn,
}

m["ver"] = {
	"Mom Jango",
	"Q35862",
	"alv-dur",
}

m["vgr"] = {
	"ヴァグハリ語",
	"Q7908480",
	"inc-bhi",
	scripts = {"Gujr"},
	translit_module = "gu-translit",
}

m["vgt"] = {
	"フラマン手話",
	"Q2107617",
	"sgn",
}

m["vic"] = {
	"ヴァージン諸島クレオール語",
	"Q7933935",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["vid"] = {
	"ヴィドゥンダ語",
	otherNames = {"Vidunda", "Kividunda"},
	"Q7928151",
	"bnt-ruv",
}

m["vif"] = {
	"ヴィリ語",
	"Q3558409",
	"bnt-kng",
}

m["vig"] = {
	"ヴィエモ語",
	"Q36912",
	"alv-sav",
}

m["vil"] = {
	"ヴィレラ語",
	"Q3409297",
}

m["vis"] = {
	"Vishavan",
	"Q14916908",
	"dra",
}

m["vit"] = {
	"ヴィティ語",
	"Q11011055",
	"nic-grf",
}

m["viv"] = {
	"イドゥナ語",
	"Q5989839",
	"poz-ocw",
}

m["vka"] = {
	"カリヤラ語",
	"Q13586632",
	"aus-nga",
	scripts = Latn,
}

m["vki"] = {
	"Ija-Zuba",
	"Q11011389",
	"nic-pls",
	ancestors = {"uji"},
}

m["vkj"] = {
	"Kujarge",
	"Q33448",
}

m["vkk"] = {
	"Kaur",
	"Q6378867",
}

m["vkl"] = {
	"Kulisusu",
	"Q3200326",
	"poz-btk",
}

m["vkm"] = {
	"カマカン語",
	"Q3192316",
	"sai-mje",
	otherNames = {"Kamakã", "Ezeshio", "Kotoxó", "Kotoxo", "Mongoyó", "Mangaló"},
	scripts = Latn,
}

m["vko"] = {
	"Kodeoha",
	"Q3198209",
}

m["vkp"] = {
	"コルライ・クレオール・ポルトガル語",
	"Q3915520",
	"crp",
 	scripts = Latn,
	ancestors = {"idb"},
}

m["vkt"] = {
	"テンガロン・クタイ・マレー語",
	"Q12683226",
}

m["vku"] = {
	"クラマ語",
	"Q3915684",
	"aus-nga",
	scripts = Latn,
}

m["vlp"] = {
	"Valpei",
	"Q7912582",
	"poz-vnc",
}

m["vls"] = {
	"フラマン語",
	"Q100103",
	"gmw",
	scripts = Latn,
	ancestors = {"dum"},
}

m["vma"] = {
	"マトゥイフニラ語",
	"Q975399",
	"aus-nga",
	scripts = Latn,
}

m["vmb"] = {
	"Mbabaram",
	"Q3303475",
	"aus-pam",
	scripts = Latn,
}

m["vmc"] = {
	"フストラワカ・ミステク語",
	"Q25559582",
	"omq-mxt",
	scripts = Latn,
}

m["vmd"] = {
	"Mudu Koraga",
	"Q12952656",
	"dra",
	scripts = {"Knda"},
}

m["vme"] = {
	"東マセラ語",
	"Q18487451",
	"poz-tim",
}

m["vmf"] = {
	"マインフランケン方言",
	"Q497345",
	"gmw",
	otherNames = {"Ansbachisch", "Eastern Franconian", "Hohenlohisch", "Main Franconian", "Mainfränkisch", "Nürnbergisch", "Oberfränkisch", "Upper Franconian", "Vogtländisch"},
	scripts = Latn,
	ancestors = {"gmh"},
	sort_key = {
		from = {"[äàáâå]", "[ëèéê]", "[ïìíî]", "[öòóô]", "[üùúû]", "ß" },
		to   = {"a"	  , "e"	 , "i"	 , "o"	 , "u"	 , "ss"}} ,
}

m["vmg"] = {
	"Minigir",
	"Q17053237",
	"poz-ocw",
	otherNames = {"Lungalunga"},
	scripts = Latn,
}

m["vmh"] = {
	"マラグヘイ語",
	"Q36220",
	"xme-ttc",
	ancestors = {"xme-ttc-eas"},
}

m["vmi"] = {
	"ミワ語",
	"Q10586712",
	"aus-wor",
}

m["vmj"] = {
	"イスタユトラ・ミステク語",
	"Q6101163",
	"omq-mxt",
	scripts = Latn,
}

m["vmk"] = {
	"Makhuwa-Shirima",
	"Q2963909",
	"bnt-mak",
	ancestors = {"vmw"},
	scripts = Latn,
}

m["vml"] = {
	"マルガナ語",
	"Q6743201",
	"aus-psw",
	scripts = Latn,
}

m["vmm"] = {
	"Mitlatongo Mixtec",
	"Q6881813",
	"omq-mxt",
	scripts = Latn,
}

m["vmp"] = {
	"ソヤルテペック・マサテク語",
	"Q7572000",
	scripts = Latn,
}

m["vmq"] = {
	"Soyaltepec Mixtec",
	"Q7572001",
	"omq-mxt",
	scripts = Latn,
}

m["vmr"] = {
	"Marenje",
	"Q11128833",
	ancestors = {"vmw"},
	"bnt-mak",
}

-- vms "Moskela" is extinct and unattested; see Wikipedia

m["vmu"] = {
	"ムルリジ語",
	"Q10590149",
}

m["vmv"] = {
	"渓谷マイドゥ語",
	"Q5096458",
	"nai-mdu",
	scripts = Latn,
}

m["vmw"] = {
	"Makhuwa",
	"Q33882",
	"bnt-mak",
	scripts = Latn,
}

m["vmx"] = {
	"タマソラ・ミステク語",
	"Q12953734",
	"omq-mxt",
	scripts = Latn,
}

m["vmy"] = {
	"アヤウトラ・マサテク語",
	"Q14916912",
	scripts = Latn,
}

m["vmz"] = {
	"マサトラン・マサテク語",
	"Q12953706",
	"omq-maz",
	scripts = Latn,
}

m["vnk"] = {
	"ヴァノ語",
	"Q3211090",
	"poz-oce",
}

m["vnm"] = {
	"Neve'ei",
	"Q2157431",
	"poz-vnc",
}

m["vnp"] = {
	"ヴナプ語",
	"Q7943647",
	"poz-vnc",
}

m["vor"] = {
	"ヴォロ語",
	"Q3914407",
	"alv-yun",
}

m["vot"] = {
	"ヴォート語",
	"Q32858",
	"fiu-fin",
	scripts = Latn,
}

m["vra"] = {
	"Vera'a",
	"Q3555689",
	scripts = Latn,
}

m["vro"] = {
	"ヴォロ語",
	"Q32762",
	"fiu-fin",
	scripts = Latn,
	wikimedia_codes = {"fiu-vro"},
}

m["vrs"] = {
	"ヴァリシ語",
	"Q3554807",
	"poz-ocw",
}

m["vrt"] = {
	"Banam Bay",
	"Q2928522",
	"poz-vnc",
}

m["vsi"] = {
	"モルドバ手話",
	"Q12953478",
	"sgn",
}

m["vsl"] = {
	"ベネズエラ手話",
	"Q3322064",
	"sgn",
}

m["vsv"] = {
	"バレンシア手話",
	"Q32663",
	"sgn",
}

m["vto"] = {
	"Vitou",
	"Q7937210",
	"paa-tkw",
}

m["vum"] = {
	"ヴング語",
	"Q36629",
	"bnt-sir",
}

m["vun"] = {
	"ヴンジョ語",
	"Q12953261",
	"bnt-chg",
	otherNames = {"KiVunjo", "Wunjo", "Chaga", "KiVunjo Chaga", "Central Kilimanjaro", "Central Chaga"},
	scripts = Latn,
}

m["vut"] = {
	"ヴテ語",
	"Q36897",
	"nic-mmb",
	scripts = Latn,
}

m["vwa"] = {
	"Awa (China)",
	"Q2874642",
	"mkh-pal",
	otherNames = {"Awa", "Ava", "Va"}, -- last two are confusingly also names of sibling dialect 'wbm'
}

return m