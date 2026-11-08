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

m["pab"] = {
	"パレシス語",
	"Q3504312",
	"awd",
	otherNames = {"Parecis", "Parecís", "Paresi", "Paresí"},
	scripts = Latn,
}

m["pac"] = {
	"パコー語",
	"Q3441136",
	"mkh-kat",
}

m["pad"] = {
	"パウマリ語",
	"Q389827",
	"auf",
	scripts = Latn,
}

m["pae"] = {
	"Pagibete",
	"Q7124357",
	"bnt-bta",
	scripts = Latn,
}

m["paf"] = {
	"Paranawát",
	"Q12953806",
	"tup-gua",
	scripts = Latn,
}

m["pag"] = {
	"パンガシナン語",
	"Q33879",
	"phi",
	scripts = Latn,
}

m["pah"] = {
	"Tenharim",
	"Q10266010",
	"tup-gua",
	otherNames = {"Parintintín"},
	scripts = Latn,
}

m["pai"] = {
	"Pe",
	"Q3914871",
	"nic-tar",
}

m["pak"] = {
	"Parakanã",
	"Q12953804",
	"tup-gua",
	otherNames = {"Awaeté"},
	scripts = Latn,
}

m["pal"] = {
	"パフラヴィー語",
	"Q32063",
	"ira-swi",
	otherNames = {"Pahlavi", "Manichaean Middle Persian"},
	scripts = {"Latn", "Phli", "pal-Avst", "Mani", "Phlp", "Phlv"}, -- Latn for translit; Phlv not in Unicode
	translit_module = "translit-redirect",
	ancestors = {"peo"},
}

m["pam"] = {
	"パンパンガ語",
	"Q36121",
	"phi",
	otherNames = {"Pampango"},
	scripts = Latn, -- also Kulitan, which lacks a code
}

m["pao"] = {
	"北パイユート語",
	"Q3360656",
	"azc-num",
	otherNames = {"Numu", "Numa", "Paviotso", "Mono-Paviotso", "Mono-Bannock", "Bannock"},
	scripts = Latn,
}

m["pap"] = {
	"パピアメント語",
	"Q33856",
	"crp",
	otherNames = {"Papiamento"},
	scripts = Latn,
	ancestors = {"pt"},
}

m["paq"] = {
	"パリア語",
	"Q1135134",
	"inc-cen",
	ancestors = {"psu"},
}

m["par"] = {
	"パナミント語",
	"Q33926",
	"azc-num",
	otherNames = {"Panamint Shoshone", "Timbisha", "Tümpisha", "Koso"},
	scripts = Latn,
}

m["pas"] = {
	"パパセナ語",
	"Q7132508",
	"paa-lkp",
	scripts = Latn,
}

m["pat"] = {
	"パピタライ語",
	"Q6528659",
	"poz-aay",
	scripts = Latn,
}

m["pau"] = {
	"パラオ語",
	"Q33776",
	"poz-sus",
	scripts = Latn,
}

m["pav"] = {
	"パカースノボス語'",
	"Q3027909",
	"sai-cpc",
	scripts = Latn,
}

m["paw"] = {
	"ポーニー語",
	"Q56751",
	"cdd",
	scripts = Latn,
}

m["pax"] = {
	"Pankararé",
	"Q25559779",
	otherNames = {"Pancaré", "Pankaré", "Pankarare", "Pancare", "Pankare"},
}

m["pay"] = {
	"ペチ語",
	"Q4898889",
	"cba",
}

m["paz"] = {
	"パンカラルー語",
	"Q7131310",
	otherNames = {"Pankararu", "Pankarú", "Pankaru", "Pankarurú", "Pankaruru", "Pancaru", "Pankaroru", "Brancararu"},
}

m["pbb"] = {
	"パエス語",
	"Q33677",
	scripts = Latn,
}

m["pbc"] = {
	"パタモナ語",
	"Q3915921",
	"sai-car",
	scripts = Latn,
}

m["pbe"] = {
	"Mezontla Popoloca",
	"Q42365630",
	"omq-pop",
	scripts = Latn,
}

m["pbf"] = {
	"コヨテペック・ポポロカ語",
	"Q5180100",
	"omq-pop",
	scripts = Latn,
}

m["pbg"] = {
	"パラオハン語",
	"Q3501747",
	"awd-taa",
	ancestors = {"awd-taa-pro"},
	scripts = Latn,
}

m["pbh"] = {
	"Panare",
	"Q56610",
	"sai-car",
	scripts = Latn,
}

m["pbi"] = {
	"Podoko",
	"Q3515096",
	"cdc-cbm",
	otherNames = {"Parkwa", "Parəkwa"},
	scripts = Latn,
}

m["pbl"] = {
	"Mak (Nigeria)",
	"Q3915349",
	"alv-bwj",
	otherNames = {"Mak", "Panya", "Zo"}, -- Panya and Zo are dialects
	scripts = Latn,
}

m["pbm"] = {
	"プエブラ・マサテク語",
	nil,
	"omq-maz",
	otherNames = {"Mazateco de Puebla y del Noroeste"},
	scripts = Latn,
}

m["pbn"] = {
	"Kpasam",
	"Q3914902",
	"alv-mye",
}

m["pbo"] = {
	"パペル語",
	"Q36314",
	"alv-pap",
}

m["pbp"] = {
	"バジャラ語",
	"Q35095",
	"alv-ten",
}

m["pbr"] = {
	"パングワ語",
	"Q3847550",
	"bnt-bki",
	scripts = Latn,
}

m["pbs"] = {
	"中部パメ語",
	"Q3361763",
	"omq",
	scripts = Latn,
}

m["pbv"] = {
	"プナール語",
	"Q3501850",
	"aav-pkl",
}

m["pby"] = {
	"ピュ語",
	"Q2567925",
	"paa-asa",
	otherNames = {"Papuan Pyu", "Pyu (New Guinea)", "Pyu (Papua New Guinea)"}, -- distinguish from 'pyx'
}

m["pca"] = {
	"サンタ・イネス・アワテンパン・ポポロカ語",
	"Q42365276",
	"omq-pop",
	scripts = Latn,
}

m["pcb"] = {
	"ペアル語",
	"Q6583669",
	"mkh-pea",
	scripts = {"Khmr"},
}

m["pcc"] = {
	"ブイ語",
	"Q35100",
	"tai-nor",
	aliases = {"Buyi", "Buyei", "Puyi", "Giay", "Yay"},
	scripts = {"Latn", "Hani"},
	sort_key = {
		from = {"%p"},
		to   = {""}},
}

m["pcd"] = {
	"ピカルディ語",
	"Q34024",
	"roa-oil",
	otherNames = {"Chti", "Ch'ti", "Rouchi", "Rouchy"},
	scripts = Latn,
	ancestors = {"fro"},
	sort_key = {
		from = {"[áàâä]", "[éèêë]", "[íìîï]", "[óòôö]", "[úùûü]", "[ýỳŷÿ]", "ç", "'"},
		to   = {"a"	 , "e"	 , "i"	 , "o"	 , "u"	 , "y"	 , "c"}} ,
}

m["pce"] = {
	"Ruching Palaung",
	"Q12953798",
	"mkh-pal",
}

m["pcf"] = {
	"Paliyan",
	"Q7127643",
	"dra",
}

m["pcg"] = {
	"Paniya",
	"Q7131211",
	"dra",
}

m["pch"] = {
	"パルダーン語",
	"Q7133207",
	"dra",
	ancestors = {"gon"},
}

m["pci"] = {
	"Duruwa",
	"Q56753",
	"dra",
	scripts = {"Deva", "Orya"},
}

m["pcj"] = {
	"パレンガ語",
	"Q3111396",
	"mun",
}

m["pck"] = {
	"パイテ・チン語",
	"Q12952337",
	"tbq-kuk",
	otherNames = {"Paite Chin"},
}

m["pcl"] = {
	"パルディー語",
	"Q7136554",
	"inc-bhi",
}

m["pcm"] = {
	"ナイジェリア・ピジン語",
	"Q33655",
	"crp",
	scripts = Latn,
	ancestors = {"en"},
}

m["pcn"] = {
	"ピティ語",
	"Q3913375",
	"nic-kne",
}

m["pcp"] = {
	"パカワラ語",
	"Q2591165",
	"sai-pan",
	scripts = Latn,
}

m["pcw"] = {
	"ピャプン語",
	"Q3438807",
}

m["pda"] = {
	"Anam",
	"Q3501930",
	"ngf-mad",
}

m["pdc"] = {
	"ペンシルヴァニア・ドイツ語",
	"Q22711",
	"gmw",
	otherNames = {"Pennsylvania Dutch"},
	scripts = Latn,
	ancestors = {"gmw-rfr"},
}

m["pdi"] = {
	"パ・ジ語",
	"Q3359940",
}

m["pdn"] = {
	"Fedan",
	"Q7206699",
	"poz-ocw",
	scripts = Latn,
}

m["pdo"] = {
	"パドエ語",
	"Q3360370",
	"poz-btk",
	scripts = Latn,
}

m["pdt"] = {
	"メノー派低地ドイツ語",
	"Q1751432",
	"gmw",
	otherNames = {"Mennonite Low German", "Russian Mennonite Low German", "Chortitza", "Molotschna", "Chortica", "Molotcha"},
	scripts = Latn,
	ancestors = {"nds-de"},
}

m["pdu"] = {
	"カヤン語",
	"Q7123283",
}

m["pea"] = {
	"プラナカン語",
	"Q653415",
	scripts = Latn,
}

m["peb"] = {
	"東部ポモ語",
	"Q3396032",
	"nai-pom",
	scripts = Latn,
}

m["ped"] = {
	"Mala (New Guinea)",
	"Q11732569",
	"ngf-mad",
	otherNames = {"Mala (Papua New Guinea)", "Mala"},
	scripts = Latn,
}

m["pee"] = {
	"Taje",
	"Q12953902",
}

m["pef"] = {
	"北東部ポモ語",
	"Q3396018",
	"nai-pom",
	scripts = Latn,
}

m["peg"] = {
	"ペンゴ語",
	"Q56758",
	"dra",
	scripts = {"Orya"},
}

m["peh"] = {
	"ボウナン語",
	"Q32983",
	"xgn",
}

m["pei"] = {
	"チチメコ＝ホナス語",
	"Q3915427",
	"omq-otp",
	scripts = Latn,
}

m["pej"] = {
	"北部ポモ語",
	"Q3396021",
	"nai-pom",
	scripts = Latn,
}

m["pek"] = {
	"Penchal",
	"Q3374631",
	"poz-aay",
	scripts = Latn,
}

m["pel"] = {
	"プカル語",
	"Q3241781",
}

m["pem"] = {
	"Phende",
	"Q7162372",
	"bnt-pen",
}

m["peo"] = {
	"古代ペルシア語",
	"Q35225",
	"ira-swi",
	scripts = {"Xpeo", "Latinx"},
	translit_module = "peo-translit",
}

m["pep"] = {
	"Kunja",
	"Q6444807",
}

m["peq"] = {
	"南部ポモ語",
	"Q3396023",
	"nai-pom",
	scripts = Latn,
}

-- "pes" IS TREATED AS "fa" (or as etymology-only), SEE WT:LT

m["pev"] = {
	"ぺモノ語",
	"Q3439012",
	"sai-car",
	scripts = Latn,
}

m["pex"] = {
	"ペタツ語",
	"Q3376353",
	"poz-ocw",
	scripts = Latn,
}

m["pey"] = {
	"Petjo",
	"Q940486",
}

m["pez"] = {
	"東部プナン語",
	"Q18638342",
	"poz-swa",
	scripts = Latn,
}

m["pfa"] = {
	"Pááfang",
	"Q3063517",
	"poz-mic",
	scripts = Latn,
}

m["pfe"] = {
	"Peere",
	"Q36377",
	"alv-dur",
	otherNames = {"Kutin"},
	scripts = Latn,
}

m["pga"] = {
	"スーダン・アラビア語クレオール",
	"Q1262143",
	"crp",
	scripts = Latn,
	ancestors = {"apd"},
}

m["pgd"] = {
	"ガンダーラ語",
	nil,
	"pra",
	otherNames = {"Gāndhārī", "Gāndhārī Prakrit"},
	scripts = {"Deva", "Khar"},
	ancestors = {"inc-ash"},
	translit_module = "Khar-translit",
}

m["pgg"] = {
	"パングワーリー語",
	"Q13600429",
	"him",
	scripts = {"Deva", "Takr"},
	translit_module = "hi-translit",
}

m["pgi"] = {
	"パギ語",
	"Q7124354",
	"paa-brd",
}

m["pgk"] = {
	"レレプ語",
	"Q586907",
	"poz-vnc",
	scripts = Latn,
}

m["pgl"] = {
	"原始アイルランド語",
	"Q3320030",
	"cel-gae",
	scripts = {"Ogam"},
	translit_module = "pgl-translit",
}

m["pgn"] = {
	"パエリグニ語",
	nil,
	"itc",
	scripts = Latn,
}

m["pgs"] = {
	"パンセン語",
	"Q3914027",
	"alv-mum",
}

m["pgu"] = {
	"パグ語",
	"Q7124462",
	"paa-wpa",
}

m["pgz"] = {
	"パプアニューギニア手話",
	"Q25044405",
	"sgn",
	otherNames = {"Papua New Guinea Sign Language", "Melanesian Sign Language", "PNGSL"},
}

m["pha"] = {
	"パフン語",
	"Q2625410",
	"hmn",
}

m["phd"] = {
	"フダギ語",
	"Q7188289",
}

m["phg"] = {
	"プオン語",
	"Q7188376",
	"mkh-kat",
}

m["phh"] = {
	"Phukha",
	"Q7188298",
	"tbq-lol",
}

m["phk"] = {
	"Phake",
	"Q7675798",
	"tai-swe",
	otherNames = {"Tai Phake"},
	scripts = {"Mymr"},
	entry_name = {
		from = {u(0xFE00)}, --VS01
		to = {""}},
}

m["phl"] = {
	"パルーラ語",
	"Q2449549",
	"inc-dar",
	otherNames = {"Palula", "Palola", "Phalulo", "Ashreti"},
}

m["phm"] = {
	"Phimbi",
	"Q11007144",
	"bnt-sna",
}

m["phn"] = {
	"フェニキア語",
	"Q36734",
	"sem-can",
	scripts = {"Phnx"},
	translit_module = "Phnx-translit",
}

m["pho"] = {
	"プノイ語",
	"Q7188361",
	"tbq-lol",
}

m["phq"] = {
	"Phana'",
	"Q7180427",
	"tbq-lol",
}

m["phr"] = {
	"パハリー＝ポトワリ語",
	"Q33739",
	"inc-pan",
	otherNames = {"Pothohari", "Pothwari"},
	scripts = {"fa-Arab", "Latn"},
	ancestors = {"lah"},
}

m["pht"] = {
	"プー・タイ語",
	"Q3626597",
	"tai-swe",
}

m["phu"] = {
	"プアン語",
	"Q3915665",
}

m["phv"] = {
	"パフラヴァーン語",
	"Q7124567",
}

m["phw"] = {
	"バンドゥワリ語",
	"Q12953036",
	"sit-kie",
	ancestors = {"ybh"},
}

m["pia"] = {
	"ピマ・バホ語",
	"Q3388544",
	"azc",
	scripts = Latn,
}

m["pib"] = {
	"イネ語",
	"Q3135432",
	"awd",
	otherNames = {"Piro", "Pirro", "Pira", "Chontaquiro", "Contaquiro", "Simirinche", "Simiranch"},
	scripts = Latn,
}

m["pic"] = {
	"ピンジ語",
	"Q36296",
	"bnt-tso",
}

m["pid"] = {
	"ピアロア語",
	"Q3382207",
	scripts = Latn,
}

m["pie"] = {
	"ピロ語",
	"Q7198055",
	"nai-kta",
	scripts = Latn,
}

m["pif"] = {
	"ピンゲラップ語",
	"Q36421",
	"poz-mic",
	scripts = Latn,
}

m["pig"] = {
	"ピサボ語",
	"Q966883",
	"sai-pan",
	scripts = Latn,
}

m["pih"] = {
	"ピトケアン・ノーフォーク語",
	"Q36554",
	"crp",
	otherNames = {"Pitkern-Norfuk", "Pitcairn", "Pitkern", "Norfolk", "Norfuk"},
	scripts = Latn,
	ancestors = {"en"},
}

m["pii"] = {
	"Pini",
	"Q10631925",
}

m["pij"] = {
	"ピハオ語",
	"Q7193519",
}

m["pil"] = {
	"ヨム語",
	"Q36893",
	"nic-yon",
}

m["pim"] = {
	"ポウハタン語",
	"Q2270532",
	"alg-eas",
	scripts = Latn,
}

m["pin"] = {
	"ピアメ語",
	"Q7190042",
}

m["pio"] = {
	"ピアポコ語",
	"Q3382208",
	"awd-nwk",
	scripts = Latn,
}

m["pip"] = {
	"Pero",
	"Q2411063",
	"cdc-wst",
}

m["pir"] = {
	"Piratapuyo",
	"Q3389119",
	"sai-tuc",
	scripts = Latn,
}

m["pis"] = {
	"ピジン語",
	"Q36699",
	"crp",
	otherNames = {"Kanaka", "Neo-Solomonic", "Solomons Pidgin"},
	scripts = Latn,
	ancestors = {"en"},
}

m["pit"] = {
	"ピタ・ピタ語",
	"Q6433116",
	"aus-kar",
	otherNames = {"Pitta Pitta"},
	scripts = Latn,
}

m["piu"] = {
	"ピントゥピ＝ルリチャ語",
	"Q2591175",
	"aus-pam",
}

m["piv"] = {
	"ピレニ語",
	"Q2976736",
	"poz-pnp",
	otherNames = {"Vaeakau-Taumako"},
	scripts = Latn,
}

m["piw"] = {
	"ピンブウェ語",
	"Q3894132",
	"bnt-mwi",
}

m["pix"] = {
	"Piu",
	"Q7199578",
}

m["piy"] = {
	"Piya-Kwonci",
	"Q3440492",
}

m["piz"] = {
	"ピジェ語",
	"Q3388339",
	"poz-cln",
	scripts = Latn,
}

m["pjt"] = {
	"ピッチャンチャジャーラ語",
	"Q2982063",
	"aus-pam",
	scripts = {"pjt-Latn"},
}

m["pka"] = {
	"アルダマーガディ・プラークリット",
	"Q2652214",
	"pra",
	scripts = {"Brah", "Deva"},
	translit_module = "Brah-translit",
	ancestors = {"inc-pra"},
}

m["pkb"] = {
	"ポコモ語",
	"Q7208693",
	"bnt-sab",
	scripts = Latn,
}

m["pkc"] = {
	"韓系百済語",
	"Q4841264",
	"qfa-kor",
	scripts = {"Hani"},
}

m["pkg"] = {
	"Pak-Tong",
	"Q3360711",
}

m["pkh"] = {
	"パンク語",
	"Q7130962",
	"tbq-kuk",
	otherNames = {"Pankho", "Pangkhua", "Pangkho", "Pangkhu", "Panko"},
}

m["pkn"] = {
	"パカナ語",
	"Q954916",
	"aus-pmn",
}

m["pko"] = {
	"ポコット語",
	"Q36323",
	"sdv-kln",
}

m["pkp"] = {
	"プカプカ語",
	"Q36447",
	"poz-pnp",
	scripts = Latn,
}

m["pkr"] = {
	"Attapady Kurumba",
	"Q16835180",
	"dra",
}

m["pks"] = {
	"パキスタン手話",
	"Q22964057",
	"sgn",
	otherNames = {"Pakistani Sign Language"},
}

m["pkt"] = {
	"マレン語",
	"Q6583562",
	"mkh-vie",
}

m["pku"] = {
	"パク語",
	"Q2932604",
}

m["pla"] = {
	"Miani",
	"Q12952844",
	scripts = Latn,
}

m["plb"] = {
	"ポロノンバウク語",
	"Q7225957",
	"poz-vnc",
	scripts = Latn,
}

m["plc"] = {
	"中央パラワン語",
	"Q12953795",
	"phi",
	scripts = Latn,
}

m["ple"] = {
	"パルエ語",
	"Q2196866",
	"poz-cet",
	scripts = Latn,
}

m["plg"] = {
	"ピラガ語",
	"Q2748259",
	"sai-guc",
	otherNames = {"Pilacá"},
	scripts = Latn,
}

m["plh"] = {
	"パウロヒ語",
	"Q7155331",
	"poz-cma",
}

m["plj"] = {
	"Polci",
	"Q3914383",
}

m["plk"] = {
	"コーヒスターン・シナー語",
	"Q12953882",
	"inc-dar",
}

m["pll"] = {
	"パラウン語",
	"Q27941664",
	"mkh-pal",
}

m["pln"] = {
	"パレンケ語",
	"Q36665",
	"crp",
	ancestors = {"es"},
	scripts = Latn,
}

m["plo"] = {
	"オルータ・ポポルカ語",
	"Q5908687",
	"nai-miz",
	scripts = Latn,
}

m["plq"] = {
	"パラー語",
	"Q36582",
	"ine-ana",
	scripts = {"Xsux"},
}

m["plr"] = {
	"パラカ・セヌフォ語",
	"Q36346",
	"alv-snf",
	scripts = Latn,
}

m["pls"] = {
	"San Marcos Tlalcoyalco Popoloca",
	"Q12641692",
	"omq-pop",
	scripts = Latn,
}

m["plu"] = {
	"パリクール語",
	"Q3073448",
	"awd",
	otherNames = {"Palikúr"},
	scripts = Latn,
}

m["plv"] = {
	"南西パラワン語",
	"Q15614922",
	"phi",
	scripts = Latn,
}

m["plw"] = {
	"ブルックス・ポイント・パラワン語",
	"Q12953796",
	"phi",
	scripts = Latn,
}

m["ply"] = {
	"Bolyu",
	"Q3361723",
	"mkh-pkn",
	scripts = Latn,
}

m["plz"] = {
	"パルアン語",
	"Q7128795",
	scripts = Latn,
}

m["pma"] = {
	"パアマ語",
	"Q3130286",
	"poz-vnc",
	scripts = Latn,
}

m["pmb"] = {
	"パンピア語",
	"Q36267",
	"znd",
	scripts = Latn,
}

m["pmd"] = {
	"Pallanganmiddang",
	"Q7127734",
	"aus-pam",
	scripts = Latn,
}

m["pme"] = {
	"プアーメイ語",
	"Q3411152",
	"poz-cln",
	scripts = Latn,
}

m["pmf"] = {
	"パモナ語",
	"Q3513320",
	"poz-kal",
	otherNames = {"Bare'e"},
	scripts = Latn,
}

m["pmh"] = {
	"マハーラーシュトリ・プラークリット",
	"Q2586773",
	"pra",
	otherNames = {"Maharashtri Prakrit", "Maharastri", "Maharashtri"},
	scripts = {"Brah", "Deva"},
	ancestors = {"inc-pra"},
	translit_module = "Brah-translit",
}

m["pmi"] = {
	"北プミ語",
	"Q3403245",
	"sit-qia",
	otherNames = {"Northern Prinmi", "Northern Pimi"},
}

m["pmj"] = {
	"南プミ語",
	"Q3403246",
	"sit-qia",
	otherNames = {"Southern Prinmi", "Southern Pimi"},
}

m["pmk"] = {
	"パムリコ語",
	nil,
	"alg-eas",
	scripts = Latn,
}

m["pml"] = {
	"サビール語",
	"Q636479",
	"crp",
	ancestors = {"lij", "pro", "vec"},
	otherNames = {"Mediterranean Lingua Franca", "リングワ・フランカ"},
	scripts = Latn,
}

m["pmm"] = {
	"Pol",
	"Q36408",
	"bnt-kak",
	otherNames = {"Pol Pomo", "Pomo"},
	scripts = Latn,
}

m["pmn"] = {
	"パム語",
	"Q7129017",
	"alv-mbm",
}

m["pmo"] = {
	"Pom",
	"Q7227178",
	"poz-hce",
	scripts = Latn,
}

m["pmq"] = {
	"北部パメ語",
	"Q3361762",
	"omq",
	scripts = Latn,
}

m["pmr"] = {
	"パイナマル語",
	"Q3450824",
}

m["pms"] = {
	"ピエモンテ語",
	"Q15085",
	"roa-git",
	scripts = Latn,
}

m["pmt"] = {
	"ツアモツ語",
	"Q36763",
	"poz-pep",
	scripts = Latn,
}

m["pmu"] = {
	"ミルプル・パンジャーブ語",
	"Q6874480",
}

m["pmw"] = {
	"平原ミウォク語",
	"Q3391031",
	"nai-you",
	scripts = Latn,
}

m["pmx"] = {
	"Poumei Naga",
	"Q12952910",
	"tbq-anp",
}

m["pmy"] = {
	"パプア・マレー語",
	"Q12473446",
	scripts = Latn,
}

m["pmz"] = {
	"南部パメ語",
	"Q3361765",
	"omq",
	scripts = Latn,
}

m["pna"] = {
	"プナン・バー・ビアウ語",
	"Q4842201",
}

m["pnb"] = {
	"西パンジャーブ語",
	"Q58635",
	"inc-pan",
	scripts = {"pa-Arab"},
	ancestors = {"pa"},
}

m["pnc"] = {
	"Pannei",
	"Q7131391",
}

m["pnd"] = {
	"Mpinda",
	"Q63308194",
	"bnt-kmb",
}

m["pne"] = {
	"西部プナン語",
	"Q12953808",
	"poz-swa",
	scripts = Latn,
}

m["png"] = {
	"ポング語",
	"Q36282",
	"nic-shi",
}

m["pnh"] = {
	"ペンリャン語",
	"Q3130301",
	"poz-pep",
	otherNames = {"Tongareva", "Tongarewa"},
	scripts = Latn,
}

m["pni"] = {
	"アオヘン語",
	"Q4778608",
	"poz",
}

m["pnj"] = {
	"Pinjarup",
	"Q33103591",
}

m["pnk"] = {
	"Paunaca",
	"Q2064378",
	"awd",
	otherNames = {"Pauna", "Paunaka"},
	scripts = Latn,
}

m["pnl"] = {
	"Paleni",
	"Q7127118",
	"alv-wan",
	scripts = Latn,
}

m["pnm"] = {
	"Punan Batu",
	"Q7259892",
}

m["pnn"] = {
	"Pinai-Hagahai",
	"Q5638511",
}

m["pno"] = {
	"パノボ語",
	"Q3141869",
	"sai-pan",
	scripts = Latn,
}

m["pnp"] = {
	"Pancana",
	"Q7130204",
}

m["pnq"] = {
	"パナ語(西アフリカ)",
	"Q7129739",
	"nic-gnn",
	otherNames = {"Pana (Burkina Faso)", "Pana"},
	scripts = Latn,
}

m["pnr"] = {
	"パニム語",
	"Q11732562",
	"ngf-mad",
}

m["pns"] = {
	"ポノサカン語",
	"Q7227956",
	"phi",
}

m["pnt"] = {
	"ギリシア語ポントス方言",
	"Q36748",
	"grk",
	otherNames = {"Pontic"},
	scripts = {"Grek", "Latn", "Cyrl"},
	ancestors = {"grc"},
	translit_module = "grc-translit",
	sort_key = {  -- Keep this synchronized with el, grc, cpg
		from = {"[ᾳάᾴὰᾲᾶᾷἀᾀἄᾄἂᾂἆᾆἁᾁἅᾅἃᾃἇᾇ]", "[έὲἐἔἒἑἕἓ]", "[ῃήῄὴῂῆῇἠᾐἤᾔἢᾒἦᾖἡᾑἥᾕἣᾓἧᾗ]", "[ίὶῖἰἴἲἶἱἵἳἷϊΐῒῗ]", "[όὸὀὄὂὁὅὃ]", "[ύὺῦὐὔὒὖὑὕὓὗϋΰῢῧ]", "[ῳώῴὼῲῶῷὠᾠὤᾤὢᾢὦᾦὡᾡὥᾥὣᾣὧᾧ]", "ῥ", "ς"},
		to   = {"α"						, "ε"		 , "η"						, "ι"				, "ο"		 , "υ"				, "ω"						, "ρ", "σ"}} ,
}

m["pnu"] = {
	"ジョンナイ・ブヌ語",
	"Q56325",
	"hmn",
	otherNames = {"Kiong Nai"},
}

m["pnv"] = {
	"ピニグラ語",
	"Q10631927",
	"aus-psw",
	scripts = Latn,
}

m["pnw"] = {
	"パンチマ語",
	"Q3913830",
	"aus-nga",
	scripts = Latn,
}

m["pnx"] = {
	"Phong-Kniang",
	"Q3914627",
	"mkh",
}

m["pny"] = {
	"ピニン語",
	"Q36250",
	"nic-nge",
	scripts = Latn,
}

m["pnz"] = {
	"パナ語(中央アフリカ)",
	"Q36241",
	"alv-mbm",
	otherNames = {"Pana (Central African Republic)", "Pana"},
	scripts = Latn,
}

m["poc"] = {
	"ポコマム語",
	"Q36416",
	scripts = Latn,
}

m["poe"] = {
	"サン・フアン・アツィンゴ・ポポロカ語",
	"Q12953819",
	"omq-pop",
	scripts = Latn,
}

m["pof"] = {
	"パナ語",
	"Q7208577",
	"bnt-ske",
}

m["pog"] = {
	"ポティグアラ語",
	"Q56722",
	"tup-gua",
	scripts = Latn,
}

m["poh"] = {
	"ポコムチ語",
	"Q36414",
	scripts = Latn,
}

m["poi"] = {
	"高地ポポルカ語",
	"Q7511556",
	"nai-miz",
	scripts = Latn,
}

m["pok"] = {
	"Pokangá",
	"Q25559704",
	"sai-tuc",
	scripts = Latn,
}

m["pom"] = {
	"東南部ポモ語",
	"Q3396025",
	"nai-pom",
	scripts = Latn,
}

m["pon"] = {
	"ポンペイ語",
	"Q28422",
	"poz-mic",
	scripts = Latn,
}

m["poo"] = {
	"中部ポモ語",
	"Q3396020",
	"nai-pom",
	scripts = Latn,
}

m["pop"] = {
	"Pwapwa",
	"Q3411153",
	"poz-cln",
	scripts = Latn,
}

m["poq"] = {
	"テシステペック・ポポルカ語",
	"Q5908707",
	"nai-miz",
	scripts = Latn,
}

m["pos"] = {
	"Sayula Popoluca",
	"Q5908722",
	"nai-miz",
	scripts = Latn,
}

m["pot"] = {
	"ポタワトミ語",
	"Q56749",
	"alg",
	otherNames = {"Pottawatomie"},
	scripts = Latn,
}

m["pov"] = {
	"上ギニア・クレオール語",
	"Q33339",
	"crp",
	otherNames = {"Upper Guinea Creole", "Upper Guinea Crioulo", "Kriol", "Crioulo", "Kriolu", "Kriyol", "Kiriol"},
	scripts = Latn,
	ancestors = {"pt"},
}

m["pow"] = {
	"サン・フェリペ・オトラルテペック・ポポロカ語",
	"Q25559598",
	"omq-pop",
	scripts = Latn,
}

m["pox"] = {
	"ポラーブ語",
	"Q36741",
	"zlw-lch",
	scripts = Latn,
}

m["poy"] = {
	"ポゴロ語",
	"Q2429648",
	"bnt-kil",
}

m["ppa"] = {
	"パオ語",
	"Q7132069",
}

m["ppe"] = {
	"パピ語",
	"Q7132809",
}

m["ppi"] = {
	"パイパイ語",
	"Q56726",
	"nai-yuc",
	otherNames = {"Akwa'ala"},
	scripts = Latn,
}

m["ppk"] = {
	"ウマ語",
	"Q7881036",
	"poz-kal",
	scripts = Latn,
}

m["ppl"] = {
	"ピピル語",
	"Q1186896",
	"azc-nah",
	otherNames = {"Nahuat", "Náhuat", "Nawat", "Náwat"},
	scripts = Latn,
	entry_name = {
		from = {"Ā", "ā", "Ē", "ē", "Ī", "ī", "Ō", "ō", "Ū", "ū", "Ȳ", "ȳ", "Á", "á", "É", "é", "Í", "í", "Ó", "ó", "Ú", "ú"},
		to   = {"A", "a", "E", "e", "I", "i", "O", "o", "U", "u", "Y", "y", "A", "a", "E", "e", "I", "i", "O", "o", "U", "u"}
	},
}

m["ppm"] = {
	"Papuma",
	"Q7133239",
	"poz-hce",
	scripts = Latn,
}

m["ppn"] = {
	"パパパナ語",
	"Q3362757",
	"poz-ocw",
	scripts = Latn,
}

m["ppo"] = {
	"Folopa",
	"Q5464843",
	"paa",
	otherNames = {"Podopa", "Polopa", "Podoba", "Foraba", "Tebera", "Boro", "Suri", "Sopese"},
	scripts = Latn,
}

m["ppq"] = {
	"Pei",
	"Q7160903",
}

m["pps"] = {
	"サン・ルイス・テマラカユカ・ポポロカ語",
	"Q25559602",
	"omq-pop",
	scripts = Latn,
}

m["ppt"] = {
	"パレ語",
	"Q3504757",
	"ngf",
	otherNames = {"Pari", "Pare", "Akium-Pare"},
	scripts = Latn,
}

m["ppu"] = {
	"パポラ語",
	"Q2094884",
	"map",
	otherNames = {"Hoanya", "Papola", "Paporan", "Bupuran", "Vupuran", "Hinapavosa"},
	scripts = Latn,
}

m["pqa"] = {
	"Pa'a",
	"Q3441315",
	"cdc-wst",
}

m["pqm"] = {
	"マレシート＝パサマコディ語",
	"Q3183144",
	"alg-eas",
	otherNames = {"Malecite", "Maliseet", "Passamaquoddy"},
	scripts = Latn,
}

m["pra"] = {
	"プラークリット",
	"Q192170",
	scripts = {"Brah", "Khar"},
	translit = {
		-- Brah translit in [[Module:scripts/data]]
		Deva = "pra-Deva-translit",
		Gujr = "sa-Gujr-translit",
		Knda = "pra-Knda-translit",
	},
}

m["prc"] = {
	"パラーチー語",
	"Q2640637",
	"ira-orp",
}

-- "prd" IS NOT INCLUDED, SEE WT:LT

m["pre"] = {
	"プリンシペ島クレオル語",
	"Q36520",
	"crp",
	scripts = Latn,
	ancestors = {"pt"},
}

m["prf"] = {
	"パラナン語",
	"Q7135433",
	"phi",
}

m["prg"] = {
	"プロシア語",
	"Q35501",
	"bat",
	otherNames = {"Prussian"},
	scripts = Latn,
	entry_name = {remove_diacritics = MACRON},
}

m["prh"] = {
	"Porohanon",
	"Q6583710",
	"phi",
}

m["pri"] = {
	"パイチ語",
	"Q732131",
	"poz-cln",
	scripts = Latn,
}

m["prk"] = {
	"パラウク語",
	"Q3363719",
	"mkh-pal",
}

m["prl"] = {
	"ペルー手話",
	"Q3915508",
	"sgn",
}

m["prm"] = {
	"キビリ語",
	"Q56745",
	"paa",
}

m["prn"] = {
	"プラスニ語",
	"Q32689",
	"nur-nor",
}

m["pro"] = {
	"古プロヴァンス語",
	"Q2779185",
	"roa",
	otherNames = {"Old Provençal", "Old Provencal"},
	scripts = Latn,
	sort_key = {
		from = {"ç"},
		to   = {"c"}} ,
}

-- "prp" IS NOT INCLUDED, SEE WT:LT

m["prq"] = {
	"アシェニンカ・ペレネ語",
	"Q3450601",
	"awd",
	scripts = Latn,
}

m["prr"] = {
	"プリー語",
	"Q7261687",
}

-- "prs" IS TREATED AS "fa" (or as etymology-only), SEE WT:LT

m["prt"] = {
	"パイ語",
	"Q7180184",
	"mkh",
	otherNames = {"Prai", "Pray", "Phray"},
}

m["pru"] = {
	"プラギ語",
	"Q7260800",
	"ngf-sbh",
}

m["prw"] = {
	"パラウェン語",
	"Q7136291",
	"ngf-mad",
}

m["prx"] = {
	"プリク語",
	"Q567905",
	"sit-lab",
}

m["prz"] = {
	"プロビデンシア手話",
	"Q3322084",
	"sgn",
	otherNames = {"Providence Island Sign Language"},
}

m["psa"] = {
	"Asue Awyu",
	"Q11266334",
	otherNames = {"Pisa"},
}

m["psc"] = {
	"ペルシャ手話",
	"Q7170221",
	"sgn",
}

m["psd"] = {
	"プレーンズ・インディアン手話",
	"Q2380124",
	"sgn",
}

m["pse"] = {
	"中央マレー語",
	"Q3367751",
	"poz-mly",
}

m["psg"] = {
	"ペナン手話",
	"Q4924925",
	"sgn",
}

m["psh"] = {
	"南西パシャイ語",
	"Q16112270",
	"inc-dar",
}

m["psi"] = {
	"南東パシャイ語",
	"Q23713536",
	"inc-dar",
	otherNames = {"Southeastern Pashayi","Southeastern Pashai", "Southeast Pashai"},
	scripts = {"Arab"},
}

m["psl"] = {
	"プエルトリコ手話",
	"Q7258608",
	"sgn-fsl",
}

m["psm"] = {
	"パウセルナ語",
	"Q2912846",
	"tup-gua",
	otherNames = {"Guarasugwé"},
	scripts = Latn,
}

m["psn"] = {
	"パナスアン語",
	"Q7130113",
	"poz",
}

m["pso"] = {
	"ポーランド手話",
	"Q3915194",
	"sgn-gsl",
}

m["psp"] = {
	"フィリピン手話",
	"Q3551357",
	"sgn-fsl",
}

m["psq"] = {
	"パシ語",
	"Q7142091",
}

m["psr"] = {
	"ポルトガル手話",
	"Q3915472",
	"sgn",
}

m["pss"] = {
	"パシスマヌア語",
	otherNames = {"Kaulong", "Pasismanua"},
	"Q3194294",
	"poz-ocw",
}

m["psu"] = {
	"シャウラセーニー",
	"Q2452885",
	"inc-psu",
	otherNames = {"Sauraseni", "Shauraseni"},
	scripts = {"Deva", "Brah"},
	translit_module = "Brah-translit",
	ancestors = {"inc-pra"},
}

m["psw"] = {
	"ポート・サンドウィッチ語",
	"Q3398324",
	"poz-vnc",
	scripts = Latn,
}

m["psy"] = {
	"ピスカタウェイ語",
	"Q3504233",
	"alg-eas",
}

m["pta"] = {
	"パイ・タビテラ語",
	"Q7124619",
	"tup-gua",
	scripts = Latn,
}

m["pth"] = {
	"Pataxó Hã-Ha-Hãe",
	"Q7144304",
}

m["pti"] = {
	"ピンティーニ語",
	"Q10632026",
	"aus-pam",
}

m["ptn"] = {
	"パタニ語",
	"Q7144242",
	"poz-hce",
	scripts = Latn,
}

m["pto"] = {
	"Zo'é",
	"Q8073148",
	"tup-gua",
	otherNames = {"Jo'é"},
	scripts = Latn,
}

m["ptp"] = {
	"Patep",
	"Q3368679",
	"poz-ocw",
	scripts = Latn,
}

m["ptq"] = {
	"Pattapu",
	nil,
	"dra",
}

m["ptr"] = {
	"Piamatsina",
	"Q7190040",
	"poz-vnc",
	scripts = Latn,
}

m["ptt"] = {
	"エンレカン語",
	"Q12953520",
}

m["ptu"] = {
	"Bambam",
	"Q4853321",
	"poz-ssw",
}

m["ptv"] = {
	"ポート・ヴァト語",
	"Q3398323",
	scripts = Latn,
}

m["ptw"] = {
	"ペントラッチ語",
	"Q2069475",
}

m["pty"] = {
	"Pathiya",
	"Q7144790",
	"dra",
}

m["pua"] = {
	"タラスコ語",
	"Q16114351",
	"qfa-iso",
	otherNames = {"Tarascan", "Tarasco", "P'urhepecha", "Purépecha", "P'urhépecha", "Phorhépecha", "Phorhé", "Porhé"},
	scripts = Latn,
	sort_key = {
		from = {"á", "é", "í", "ó", "ú"},
		to   = {"a", "e", "i", "o", "u"}},
}

m["pub"] = {
	"プールーム語",
	"Q6400562",
	"tbq-kuk",
	otherNames = {"Purum Naga"},
	scripts = Latn,
}

m["puc"] = {
	"Punan Merap",
	"Q7259895",
}

m["pud"] = {
	"Punan Aput",
	"Q4782333",
}

m["pue"] = {
	"プウェルチェ語",
	"Q33660",
}

m["puf"] = {
	"プナン・メラー語",
	"Q7259894",
}

m["pug"] = {
	"Phuie",
	"Q36375",
	"nic-gnw",
}

m["pui"] = {
	"プイナベ語",
	"Q3027918",
	otherNames = {"Puinabe", "Wãnsöhöt", "Guipunave", "Güipunave", "Waipunavi", "Guaipunabi"},
}

m["puj"] = {
	"プナン・トゥブ語",
	"Q7259896",
	"poz-swa",
}

m["pum"] = {
	"プマ語",
	"Q33736",
	"sit-kic",
}

m["puo"] = {
	"プオク語",
	"Q6440803",
	"mkh",
}

m["pup"] = {
	"プラブ語",
	"Q7259163",
	"ngf-mad",
}

m["puq"] = {
	"プキーナ語",
	"Q1207739",
}

m["pur"] = {
	"プルボラ語",
	"Q7261619",
	"tup",
	otherNames = {"Aurã", "Cujubim", "Burubora", "Kuyubi", "Migueleno", "Miguelenho", "Pumbora", "Puroborá", "Puruba"},
}

m["put"] = {
	"プト語",
	"Q12953832",
	"poz-swa",
	scripts = Latn,
}

m["puu"] = {
	"プヌ語",
	"Q36401",
	"bnt-sir",
	scripts = Latn,
}

m["puw"] = {
	"プルワト語",
	"Q36397",
	"poz-mic",
	otherNames = {"Puluwatese"},
	scripts = Latn,
}

m["pux"] = {
	"Puare",
	"Q3507983",
}

m["puy"] = {
	"プリシメーニョ語",
	"Q2967638",
	"nai-chu",
	scripts = Latn,
}

m["pwa"] = {
	"パワイア語",
	"Q7156099",
	"paa",
	scripts = Latn,
}

m["pwb"] = {
	"Panawa",
	"Q47385077",
	"nic-jer",
	ancestors = {"jer"},
	scripts = Latn,
}

m["pwg"] = {
	"Gapapaiwa",
	"Q3095245",
	"poz-ocw",
	scripts = Latn,
}

m["pwi"] = {
	"パトウィン語",
	"Q3370188",
	"nai-wtq",
	otherNames = {"River Patwin", "Valley Patwin", "Hill Patwin", "Southern Patwin"},
	scripts = Latn,
}

m["pwm"] = {
	"モルボグ語",
	"Q6895718",
	"poz-san",
	scripts = Latn,
}

m["pwn"] = {
	"パイワン語",
	"Q715755",
	"map",
	scripts = Latn,
}

m["pwo"] = {
	"ポー西部カレン語",
	"Q7988202",
	"kar",
	aliases = {"Delta Pwo", "Western Pwo Karen"},
	scripts = {"Mymr"},
}

m["pwr"] = {
	"Powari",
	"Q12640277",
	"inc-hie",
	scripts = {"Deva"}
}

m["pww"] = {
	"ポー北部カレン語",
	"Q7058885",
	"kar",
	aliases = {"Phlong", "Northern Pwo Karen"},
	scripts = {"Thai"},
}

m["pxm"] = {
	"ケツァルテペック・ミヘ語",
	"Q6842374",
	"nai-miz",
	scripts = Latn,
}

m["pye"] = {
	"Pye Krumen",
	"Q11157382",
	"kro-grb",
}

m["pym"] = {
	"フィアム語",
	"Q3914025",
	"nic-ple",
	otherNames = {"Fyem", "Pyem"},
	scripts = Latn,
}

m["pyn"] = {
	"ポヤナワ語",
	"Q3401023",
	"sai-pan",
	otherNames = {"Poyanawa"},
}

m["pys"] = {
	"パラグアイ手話",
	"Q7134698",
	"sgn",
}

m["pyu"] = {
	"プユマ語",
	"Q716690",
	"map",
	scripts = Latn,
}

m["pyx"] = {
	"ピュー語",
	"Q36259",
	"sit",
	otherNames = {"Pyu"},
}

m["pyy"] = {
	"ピエン語",
	"Q7262966",
	"tbq-lol",
	otherNames = {"Hpyin", "Phen"},
}

m["pzn"] = {
	"Para Naga",
	"Q7133667",
	"sit-aao",
}

return m