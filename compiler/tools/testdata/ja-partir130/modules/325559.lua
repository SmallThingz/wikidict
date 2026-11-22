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

m["iai"] = {
	"イアーイ語",
	"Q282888",
	"poz-occ",
	scripts = Latn,
}

m["ian"] = {
	"イアトムル語",
	"Q5983460",
	"paa-spk",
}

m["iar"] = {
	"プラリ語",
	"Q3499934",
	"paa",
}

m["iba"] = {
	"イバン語",
	"Q33424",
	"poz-mly",
	scripts = Latn,
}

m["ibb"] = {
	"イビビオ語",
	"Q33792",
	"nic-ief",
	scripts = Latn,
}

m["ibd"] = {
	"イワイジャ語",
	"Q1977429",
	"aus-wdj",
	scripts = Latn,
}

m["ibe"] = {
	"アクペス語",
	"Q35457",
	"alv-von",
	scripts = Latn,
}

m["ibg"] = {
	"イバナグ語",
	"Q1775596",
	"phi",
}

m["ibh"] = {
	"Bih",
	nil,
	"cmc",
	scripts = Latn,
}

m["ibl"] = {
	"イバロイ語",
	"Q3147383",
	"phi",
	otherNames = {"Ibaloy", "Inibaloi", "Inibaloy"},
}

m["ibm"] = {
	"アゴイ語",
	"Q34727",
	"nic-ucr",
	scripts = Latn,
}

m["ibn"] = {
	"イビノ語",
	"Q3813281",
	"nic-lcr",
	scripts = Latn,
}

m["ibr"] = {
	"Ibuoro",
	"Q3813306",
	"nic-ief",
}

m["ibu"] = {
	"イブ語",
	"Q11732235",
	"paa-wpa",
}

m["iby"] = {
	"イバニ語",
	"Q11280479",
	"ijo",
}

m["ica"] = {
	"Ede Ica",
	"Q12952405",
	"alv-ede",
	scripts = Latn,
}

m["ich"] = {
	"Etkywan",
	"Q3914462",
	"nic-jkn",
	otherNames = {"Etekwe", "Icen", "Itchen"},
	scripts = Latn,
}

m["icl"] = {
	"アイスランド手話",
	"Q3436654",
	"sgn",
	scripts = Latn, -- when documented
}

m["icr"] = {
	"アイランダー・クリオール語",
	"Q2044587",
	"crp",
	otherNames = {"San Andrés-Providencia Creole"},
	scripts = Latn,
	ancestors = {"en"},
}

m["ida"] = {
	"イダホ・イスハ・ティリキ語",
	"Q12952512",
	"bnt-lok",
}

m["idb"] = {
	"インドポルトガル語",
	"Q6025550",
	"crp",
	scripts = Latn,
	ancestors = {"pt"},
}

m["idc"] = {
	"Idon",
	"Q3913366",
	"nic-plc",
}

m["idd"] = {
	"Ede Idaca",
	"Q13123376",
	"alv-ede",
	scripts = Latn,
}

m["ide"] = {
	"Idere",
	"Q3813288",
	"nic-ief",
}

m["idi"] = {
	"イディ語",
	"Q5988630",
	"paa",
}

m["idr"] = {
	"インドリ語",
	"Q35662",
	"nic-ser",
}

m["ids"] = {
	"イデサ語",
	"Q3913979",
	"alv-swd",
	ancestors = {"oke"},
	scripts = Latn,
}

m["idt"] = {
	"イダテ語",
	"Q12952511",
	"poz-tim",
	scripts = Latn,
}

m["idu"] = {
	"イドマ語",
	"Q35478",
	"alv-ido",
	scripts = Latn,
}

m["ifa"] = {
	"アムガナッド・イフガオ語",
	"Q18748222",
	"phi",
	otherNames = {"Amganad Ifugaw"},
}

m["ifb"] = {
	"バタッド・イフガオ語",
	"Q12953578",
	"phi",
	otherNames = {"Batad Ifugaw", "Ifugaw", "Batad"},
}

m["ife"] = {
	"Ifè",
	"Q33606",
	"alv-ede",
	scripts = Latn,
}

m["iff"] = {
	"Ifo",
	"Q7902545",
	"poz-oce",
	otherNames = {"Utaha"},
	scripts = Latn,
}

m["ifk"] = {
	"トゥワリ・イフガオ語",
	"Q7857158",
	"phi",
	otherNames = {"Tuwali Ifugaw"},
}

m["ifm"] = {
	"Teke-Fuumu",
	"Q36603",
	"bnt-tek",
}

m["ifu"] = {
	"マヨヤオ・イフガオ語",
	"Q12953579",
	"phi",
	otherNames = {"Mayoyao Ifugaw"},
	scripts = Latn,
}

m["ify"] = {
	"ケレイイ・カッラハン語",
	"Q3192221",
	"phi",
}

m["igb"] = {
	"エビラ語",
	"Q35363",
	"alv-nup",
	otherNames = {"Ebira", "Igbira"},
	scripts = Latn,
}

m["ige"] = {
	"イゲデ語",
	"Q35420",
	"alv-ido",
	scripts = Latn,
}

m["igg"] = {
	"イガナ語",
	"Q5991454",
	"paa",
	scripts = Latn,
}

m["igl"] = {
	"イガラ語",
	"Q35513",
	"alv-yor",
}

m["igm"] = {
	"Kanggape",
	"Q6362743",
	"paa",
	scripts = Latn,
}

m["ign"] = {
	"Ignaciano",
	"Q3148190",
	"awd",
	otherNames = {"Ignaciano Moxos", "Moxo", "Moxos", "Mojo", "Moxa"},
}

m["igo"] = {
	"イセベ語",
	"Q11732248",
	"ngf-mad",
}

m["igs"] = {
	"グロサ",
	"Q2314240",
	"art",
	type = "appendix-constructed",
}

m["igw"] = {
	"イグウェ語",
	"Q3913985",
	"alv-yek",
	scripts = Latn,
}

m["ihb"] = {
	"Pidgin Iha",
	"Q12639686",
	"crp",
	ancestors = {"ihp"},
}

m["ihi"] = {
	"Ihievbe",
	"Q3441193",
	"alv-eeo",
	ancestors = {"ema"},
	scripts = Latn,
}

m["ihp"] = {
	"イハ語",
	"Q5994495",
	"ngf",
}

m["ijc"] = {
	"イゾン語",
	"Q35483",
	"ijo",
	otherNames = {"Kolokuma", "Ekpetiama", "Gbanran", "Central-Western Ijo"},
	scripts = Latn,
}

m["ije"] = {
	"ビセニ語",
	"Q35010",
	"ijo",
}

m["ijj"] = {
	"Ede Ije",
	"Q12952406",
	"alv-ede",
	scripts = Latn,
}

m["ijn"] = {
	"カラバリ語",
	"Q35697",
	"ijo",
}

m["ijs"] = {
	"南東イジョ語",
	"Q3915854",
	"ijo",
	otherNames = {"Southeastern Ijo", "Nembe"},
	scripts = Latn,
}

m["ike"] = {
	"東部カナダ・イヌクティトット語",
	"Q4126517",
	"esx-inu",
	scripts = {"Cans"},
}

m["iki"] = {
	"Iko",
	"Q3813290",
	"nic-lcr",
	scripts = Latn,
}

m["ikk"] = {
	"イカ語",
	"Q35406",
	"alv-igb",
}

m["ikl"] = {
	"イクル語",
	"Q425973",
	"nic-plc",
	otherNames = {"Kulu"},
	scripts = Latn,
}

m["iko"] = {
	"オルルモ・イコム語",
	"Q3914402",
	"nic-uce",
	scripts = Latn,
}

m["ikp"] = {
	"Ikpeshi",
	"Q3912777",
	"alv-yek",
	scripts = Latn,
}

m["ikr"] = {
	"イカランガル語",
	"Q5995402",
	"aus-pam",
	otherNames = {"Ikarranggal", "Ikarranggali"},
}

m["iks"] = {
	"イヌイット手話",
	"Q13360244",
	"sgn",
	otherNames = {"Inuit Uukturausingit", "ISL", "IUR"},
	scripts = Latn, -- when documented
}

m["ikt"] = {
	"イヌイナクトゥン語",
	"Q27990",
	"esx-inu",
	otherNames = {"Western Canadian Inuktitut", "Western Canadian Inuktun", "Western Canadian Inuit"},
	scripts = {"Cans", "Latn"},
}

m["ikv"] = {
	"イク・ゴラ・アンクワ語",
	"Q3913940",
	"nic-plc",
}

m["ikw"] = {
	"イクウェレ語",
	"Q35399",
	"alv-igb",
}

m["ikx"] = {
	"イク語",
	"Q35472",
	"ssa-klk",
	scripts = Latn,
}

m["ikz"] = {
	"イク語",
	"Q10977626",
	"bnt-lok",
	scripts = Latn,
}

m["ila"] = {
	"Ile Ape",
	"Q12473380",
	"poz-cet",
}

m["ilb"] = {
	"イラ語",
	"Q10962725",
	"bnt-bot",
	scripts = Latn,
}

m["ilg"] = {
	"Ilgar",
	"Q5997810",
	"aus-wdj",
	otherNames = {"Garig"},
	scripts = Latn,
}

m["ili"] = {
	"イリ・チュルク語",
	"Q33627",
	"trk-kar",
}

m["ilk"] = {
	"イロンゴット語",
	"Q3148787",
	"phi",
	scripts = Latn,
}

m["ill"] = {
	"イラヌン語",
	"Q12953581",
	"phi",
	otherNames = {"Ilanun", "Iranun (Malaysia)", "Iranun (Philippines)"},
	scripts = {"Latn", "Arab"},
}

m["ilo"] = {
	"イロカノ語",
	"Q35936",
	"phi",
	otherNames = {"Ilokano"},
	scripts = {"Latn", "Tglg"},
	entry_name = {
		from = {"[áàâ]", "[éèê]", "[íìî]", "[óòô]", "[úùû]", ACUTE, GRAVE, CIRC},
		to   = {"a"    , "e"    , "i"    , "o"    , "u"    }},
}

m["ils"] = {
	"国際手話",
	"Q35754",
	"sgn",
}

m["ilu"] = {
	"Ili'uun",
	"Q12632888",
	"poz-tim",
}

m["ilv"] = {
	"Ilue",
	"Q3813301",
	"nic-lcr",
	scripts = Latn,
}

m["ima"] = {
	"Mala Malasar",
	"Q6740693",
	"dra",
}

m["imi"] = {
	"Anamgura",
	"Q3501881",
	"ngf-mad",
}

m["iml"] = {
	"Miluk",
	"Q3314550",
	"nai-coo",
	otherNames = {"Lower Coquille", "Miluk Coos"},
	scripts = Latn,
}

m["imn"] = {
	"イモンダ語",
	"Q6005721",
	"paa-brd",
}

m["imo"] = {
	"Imbongu",
	"Q12632895",
	"ngf-mad",
	otherNames = {"Ibo Ugu", "Imbo Ungu"},
}

m["imr"] = {
	"Imroing",
	"Q6008394",
	"poz-tim",
}

m["ims"] = {
	"マルシ語",
	"Q1265446",
	"itc",
	scripts = Latn,
}

m["imy"] = {
	"ミリア語",
	"Q3832946",
	"ine-ana",
	scripts = {"Lyci"},
}

m["inb"] = {
	"インガ語",
	"Q35491",
	"qwe",
	ancestors = {"qwe-kch",}
}

m["ing"] = {
	"Deg Xinag",
	"Q27782",
	"ath-nor",
}

m["inh"] = {
	"イングーシ語",
	"Q33509",
	"cau-vay",
	scripts = {"Cyrl"},
	translit_module = "inh-translit",
	override_translit = true,
	entry_name = {
		from = {MACRON},
		to   = {}},
}

m["inj"] = {
	"ジャングル・インガ語",
	"Q16115012",
	"qwe",
	ancestors = {"qwe-kch",}
}

m["inl"] = {
	"インドネシア手話",
	"Q3915477",
	"sgn",
	scripts = Latn, -- when documented
}

m["inm"] = {
	"ミナ語",
	"Q737784",
	"sem-osa",
	scripts = {"Sarb"},
	translit_module = "Sarb-translit",
}

m["inn"] = {
	"イシナイ語",
	"Q6081098",
	"phi",
}

m["ino"] = {
	"Inoke-Yate",
	"Q6036531",
	"paa-kag",
}

m["inp"] = {
	"イニャパリ語",
	"Q15338035",
	"awd",
	scripts = Latn,
}

m["ins"] = {
	"インド手話",
	"Q12953486",
	"sgn",
}

m["int"] = {
	"インダー語",
	"Q6057507",
	"tbq-brm",
	ancestors = {"obr"},
}

m["inz"] = {
	"イネセーニョ語",
	"Q35443",
	"nai-chu",
	scripts = Latn,
}

m["ior"] = {
	"イノール語",
	"Q35763",
	"sem-eth",
	scripts = {"Ethi"},
}

m["iou"] = {
	"Tuma-Irumu",
	"Q7852460",
	"ngf-fin",
	scripts = Latn,
}

m["iow"] = {
	"アイオワ・オート語",
	"Q56737",
	"sio-msv",
	otherNames = {"Iowa", "Otoe", "Oto", "Iowa-Otoe-Missouria", "Jiwere", "Jíwere", "Baxoje", "Báxoje", "Báxoje-Jíwere-Ñút'achi", "Báxoje-Jiwére-Ñútˀačhi", "Maʔúŋke", "Nut'achi"},
	scripts = Latn,
}

m["ipi"] = {
	"イピリ語",
	"Q6065141",
	"paa-eng",
}

m["ipo"] = {
	"イピコ語",
	"Q10566515",
	"ngf",
}

m["iqu"] = {
	"イキート語",
	"Q2669184",
	"sai-zap",
	scripts = Latn,
}

m["iqw"] = {
	"Ikwo",
	"Q11926474",
	"alv-igb",
	ancestors = {"izi"},
	scripts = Latn,
}

m["ire"] = {
	"Iresim",
	"Q6069398",
	"poz-hce",
	scripts = Latn,
}

m["irh"] = {
	"イラルトゥ語",
	"Q3027928",
	"poz",
	scripts = Latn,
}

m["iri"] = {
	"Rigwe",
	"Q3912756",
	"nic-plc",
	otherNames = {"Irigwe"},
	scripts = Latn,
}

m["irk"] = {
	"イラク語",
	"Q33595",
	"cus",
	scripts = Latn,
}

m["irn"] = {
	"イランシェ語",
	"Q3409301",
	otherNames = {"Irántxe"},
	scripts = Latn,
}

m["irr"] = {
	"イル語",
	"Q3071880",
	"mkh-kat",
}

m["iru"] = {
	"イルラ語",
	"Q33363",
	"dra",
	scripts = {"Taml"},
}

m["irx"] = {
	"Kamberau",
	"Q6356317",
	"ngf",
}

m["iry"] = {
	"イラヤ語",
	"Q6068356",
	"phi",
}

m["isa"] = {
	"イサビ語",
	"Q11732247",
	"paa-kag",
}

m["isc"] = {
	"イスコナワ語",
	"Q3052971",
	"sai-pan",
	scripts = Latn,
}

m["isd"] = {
	"イスナグ語",
	"Q6085162",
	"phi",
	otherNames = {"Isneg"},
	scripts = Latn,
}

m["ise"] = {
	"イタリア手話",
	"Q375619",
	"sgn",
	scripts = Latn, -- when documented
}

m["isg"] = {
	"アイルランド手話",
	"Q14183",
	"sgn",
	scripts = Latn, -- when documented
}

m["ish"] = {
	"エサン語",
	"Q35268",
	"alv-eeo",
	scripts = Latn,
}

m["isi"] = {
	"ンケム・ンクム語",
	"Q36261",
	"nic-eko",
	otherNames = {"Isibiri", "Nkem", "Nkim", "Nkum"},
	scripts = Latn,
}

m["isk"] = {
	"イシュカーシミー語",
	"Q33419",
	"ira-sgi",
	ancestors = {"ira-sgi-pro"},
}

m["ism"] = {
	"マシマシ語",
	"Q6783273",
	"poz-ocw",
	scripts = Latn,
}

m["isn"] = {
	"イサンス語",
	"Q6078891",
	"bnt-tkm",
	scripts = Latn,
}

m["iso"] = {
	"イソコ語",
	"Q35414",
	"alv-swd",
	scripts = Latn,
}

m["isr"] = {
	"イスラエル手話",
	"Q2911863",
	"sgn",
	scripts = {"Sgnw"},
}

m["ist"] = {
	"イストリア語",
	"Q35845",
	"roa-itd",
	scripts = Latn,
}

m["isu"] = {
	"Isu",
	"Q6089423",
	"nic-rnw",
	otherNames = {"Isu (Menchum Division)"},
	scripts = Latn,
}

m["itb"] = {
	"ビノガン・イトゥネグ語",
	"Q12953584",
	"phi",
}

m["itd"] = {
	"南部ティドゥン語",
	"Q7049643",
	"poz-san",
	otherNames = {"Tidong", "Nonukan Tidong", "Southern Tidung", "Nonukan Tidung"},
}

m["ite"] = {
	"イテン語",
	"Q3038640",
	"sai-cpc",
	otherNames = {"Itoreauhip"},
	scripts = Latn,
}

m["iti"] = {
	"インラオッド・イトゥネグ語",
	"Q12953585",
	"phi",
}

m["itk"] = {
	"ユダヤ・イタリア語",
	"Q1145414",
	"roa-itd",
	scripts = {"Hebr"},
}

m["itl"] = {
	"イテリメン語",
	"Q33624",
	"qfa-cka",
	otherNames = {"Western Itelmen", "Kamchadal"},
	scripts = {"Cyrl", "Latn"},
}

m["itm"] = {
	"Itu Mbon Uzo",
	"Q10977737",
	"nic-ief",
	ancestors = {"ibr"},
	scripts = Latn,
}

m["ito"] = {
	"イトナマ語",
	"Q950585",
	"qfa-iso",
}

m["itr"] = {
	"イテリ語",
	"Q2083185",
	"paa-asa",
}

m["its"] = {
	"イセキリ語",
	"Q36045",
	"alv-yor",
	otherNames = {"Itsekiri"},
	scripts = Latn,
}

m["itt"] = {
	"マエン・イトゥネグ語",
	"Q18748761",
	"phi",
}

m["itv"] = {
	"イタウィット語",
	"Q3915527",
	"phi",
	otherNames = {"Itawis", "Tawit", "Malaweg", "Malaueg"}, -- Malaweg may need own code
	scripts = Latn,
}

m["itw"] = {
	"Ito",
	"Q11128810",
	"nic-ief",
	ancestors = {"ibr"},
}

m["itx"] = {
	"イティク語",
	"Q6094713",
	"paa-tkw",
}

m["ity"] = {
	"ムヤダン・イトゥネグ語",
	"Q12953583",
	"phi",
}

m["itz"] = {
	"イツァ語",
	"Q35537",
	"myn",
	otherNames = {"Itza’", "Itza", "Itzaj"},
}

m["ium"] = {
	"ヤオ語",
	"Q2498808",
	"hmx-mie",
}

m["ivb"] = {
	"イバタン語",
	"Q18748212",
	"phi",
	otherNames = {"Ibataan", "Itbayat", "Itbayaten", "Babuyan", "Isamurongen", "Ivatan"}, -- or is Isamurongen ivv
	scripts = Latn,
}

m["ivv"] = {
	"イヴァタン語",
	"Q3547080",
	"phi",
	otherNames = {"Ivatanen", "Basco Ivatan", "Ivasayen"},
	scripts = Latn,
}

m["iwk"] = {
	"イワック語",
	"Q12632789",
	"phi",
}

m["iwm"] = {
	"イワム語",
	"Q3915215",
	"paa-spk",
}

m["iwo"] = {
	"イウル語",
	"Q6101006",
	"ngf-okk",
}

m["iws"] = {
	"セピック・イワム語",
	"Q16893603",
	"paa-spk",
}

m["ixc"] = {
	"イシュカテック語",
	"Q56706",
	"omq",
}

m["ixl"] = {
	"イシル語",
	"Q35528",
	"myn",
	otherNames = {"Ixhil"},
	scripts = Latn,
}

m["iya"] = {
	"イヤユ語",
	"Q3913390",
	"alv-nwd",
	scripts = Latn,
}

m["iyo"] = {
	"Mesaka",
	"Q36080",
	"nic-tiv",
	scripts = Latn,
}

m["iyx"] = {
	"ヤア語",
	"Q36909",
	"bnt-nze",
	otherNames = {"Yaa", "Yaka (Republic of Congo)", "Yaka"}, -- a dialect of West Teke; distinguish from 'axk' and especially 'yaf'
	scripts = Latn,
}

m["izh"] = {
	"イングリア語",
	"Q33559",
	"fiu-fin",
	otherNames = {"Izhorian"},
	scripts = Latn,
}

m["izi"] = {
	"Izi-Ezaa-Ikwo-Mgbo",
	nil,
	"alv-igb",
}

m["izr"] = {
	"Izere",
	"Q6101921",
	"nic-plc",
	scripts = Latn,
}

m["izz"] = {
	"Izi",
	"Q3914387",
	"alv-igb",
	ancestors = {"izi"},
	otherNames = {"Izii", "Izzi"},
	scripts = Latn,
}

return m