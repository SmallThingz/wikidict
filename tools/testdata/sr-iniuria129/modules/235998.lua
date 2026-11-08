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
	"Iaai",
	"Q282888",
	"poz-occ",
	scripts = Latn,
}

m["ian"] = {
	"Iatmul",
	"Q5983460",
	"paa-spk",
}

m["iar"] = {
	"Purari",
	"Q3499934",
}

m["iba"] = {
	"Iban",
	"Q33424",
	"poz-mly",
	scripts = Latn,
}

m["ibb"] = {
	"Ibibio",
	"Q33792",
	"nic-bco",
	scripts = Latn,
}

m["ibd"] = {
	"Iwaidja",
	"Q1977429",
	"aus-wdj",
	scripts = Latn,
}

m["ibe"] = {
	"Akpes",
	"Q35457",
	"alv-von",
	scripts = Latn,
}

m["ibg"] = {
	"Ibanag",
	"Q1775596",
	"phi",
}

m["ibl"] = {
	"Ibaloi",
	"Q3147383",
	"phi",
	otherNames = {"Ibaloy", "Inibaloi", "Inibaloy"},
}

m["ibm"] = {
	"Agoi",
	"Q34727",
	"nic-bco",
	scripts = Latn,
}

m["ibn"] = {
	"Ibino",
	"Q3813281",
	"nic-bco",
	scripts = Latn,
}

m["ibr"] = {
	"Ibuoro",
	"Q3813306",
	"nic-bco",
}

m["ibu"] = {
	"Ibu",
	"Q11732235",
}

m["iby"] = {
	"Ibani",
	"Q11280479",
	"ijo",
}

m["ica"] = {
	"Ede Ica",
	"Q12952405",
}

m["ich"] = {
	"Etkywan",
	"Q3914462",
}

m["icl"] = {
	"Icelandic Sign Language",
	"Q3436654",
	"sgn",
	scripts = Latn, -- when documented
}

m["icr"] = {
	"Islander Creole English",
	"Q2044587",
	scripts = Latn,
}

m["ida"] = {
	"Idakho-Isukha-Tiriki",
	"Q12952512",
}

m["idb"] = {
	"Indo-Portuguese",
	"Q6025550",
	"crp",
	scripts = Latn,
}

m["idc"] = {
	"Idon",
	"Q3913366",
}

m["idd"] = {
	"Ede Idaca",
	"Q13123376",
}

m["ide"] = {
	"Idere",
	"Q3813288",
}

m["idi"] = {
	"Idi",
	"Q5988630",
}

m["idr"] = {
	"Indri",
	"Q35662",
}

m["ids"] = {
	"Idesa",
	"Q3913979",
	"alv-edo",
	scripts = Latn,
}

m["idt"] = {
	"Idaté",
	"Q12952511",
	"poz-cet",
	scripts = Latn,
}

m["idu"] = {
	"Idoma",
	"Q35478",
	"alv",
	scripts = Latn,
}

m["ifa"] = {
	"Amganad Ifugao",
	"Q18748222",
	"phi",
	otherNames = {"Amganad Ifugaw"},
}

m["ifb"] = {
	"Batad Ifugao",
	"Q12953578",
	"phi",
	otherNames = {"Batad Ifugaw", "Ifugaw", "Batad"},
}

m["ife"] = {
	"Ifè",
	"Q33606",
}

m["iff"] = {
	"Ifo",
	"Q7902545",
}

m["ifk"] = {
	"Tuwali Ifugao",
	"Q7857158",
	"phi",
	otherNames = {"Tuwali Ifugaw"},
}

m["ifm"] = {
	"Teke-Fuumu",
	"Q36603",
}

m["ifu"] = {
	"Mayoyao Ifugao",
	"Q12953579",
	"phi",
	otherNames = {"Mayoyao Ifugaw"},
	scripts = Latn,
}

m["ify"] = {
	"Keley-I Kallahan",
	"Q3192221",
	"phi",
}

m["igb"] = {
	"Ebira",
	"Q35363",
	otherNames = {"Igbira"},
	scripts = Latn,
}

m["ige"] = {
	"Igede",
	"Q35420",
	"alv",
	scripts = Latn,
}

m["igg"] = {
	"Igana",
	"Q5991454",
	"paa",
	scripts = Latn,
}

m["igl"] = {
	"Igala",
	"Q35513",
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
	"Isebe",
	"Q11732248",
	"ngf-mad",
}

m["igs"] = {
	"Glosa",
	"Q2314240",
	"art",
	type = "appendix-constructed",
}

m["igw"] = {
	"Igwe",
	"Q3913985",
	"alv-edo",
	scripts = Latn,
}

m["ihb"] = {
	"Iha Based Pidgin",
	"Q12639686",
}

m["ihi"] = {
	"Ihievbe",
	"Q3441193",
	"alv-edo",
	scripts = Latn,
}

m["ihp"] = {
	"Iha",
	"Q5994495",
}

m["ijc"] = {
	"Izon",
	"Q35483",
	"nic",
	otherNames = {"Kolokuma", "Ekpetiama", "Gbanran", "Central-Western Ijo"},
	scripts = Latn,
}

m["ije"] = {
	"Biseni",
	"Q35010",
}

m["ijj"] = {
	"Ede Ije",
	"Q12952406",
}

m["ijn"] = {
	"Kalabari",
	"Q35697",
	"ijo",
}

m["ijs"] = {
	"Southeast Ijo",
	"Q3915854",
	"nic",
	otherNames = {"Southeastern Ijo", "Nembe"},
	scripts = Latn,
}

m["ike"] = {
	"Eastern Canadian Inuktitut",
	"Q4126517",
	"esx-inu",
	scripts = {"Cans"},
}

m["iki"] = {
	"Iko",
	"Q3813290",
	"nic-bco",
	scripts = Latn,
}

m["ikk"] = {
	"Ika",
	"Q35406",
}

m["ikl"] = {
	"Ikulu",
	"Q425973",
	"nic-bco",
	otherNames = {"Kulu"},
	scripts = Latn,
}

m["iko"] = {
	"Olulumo-Ikom",
	"Q3914402",
	"nic-bco",
	scripts = Latn,
}

m["ikp"] = {
	"Ikpeshi",
	"Q3912777",
	"alv-edo",
	scripts = Latn,
}

m["ikr"] = {
	"Ikaranggal",
	"Q5995402",
	"aus-pam",
	otherNames = {"Ikarranggal", "Ikarranggali"},
}

m["iks"] = {
	"Inuit Sign Language",
	"Q13360244",
	"sgn",
	otherNames = {"Inuit Uukturausingit", "ISL", "IUR"},
	scripts = Latn, -- when documented
}

m["ikt"] = {
	"Inuvialuktun",
	"Q27990",
	"esx-inu",
	otherNames = {"Western Canadian Inuktitut", "Western Canadian Inuktun", "Western Canadian Inuit"},
	scripts = {"Cans"},
}

m["ikv"] = {
	"Iku-Gora-Ankwa",
	"Q3913940",
}

m["ikw"] = {
	"Ikwere",
	"Q35399",
}

m["ikx"] = {
	"Ik",
	"Q35472",
	"ssa",
	scripts = Latn,
}

m["ikz"] = {
	"Ikizu",
	"Q10977626",
	"bnt",
	scripts = Latn,
}

m["ila"] = {
	"Ile Ape",
	"Q12473380",
}

m["ilb"] = {
	"Ila",
	"Q10962725",
	"bnt",
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
	"Ili Turki",
	"Q33627",
	"trk",
}

m["ilk"] = {
	"Ilongot",
	"Q3148787",
	"phi",
	scripts = Latn,
}

m["ill"] = {
	"Iranun",
	"Q12953581",
	"phi",
	otherNames = {"Ilanun", "Iranun (Malaysia)", "Iranun (Philippines)"},
	scripts = Latn,
}

m["ilo"] = {
	"Ilocano",
	"Q35936",
	"phi",
	otherNames = {"Ilokano"},
	scripts = {"Latn", "Tglg"},
	entry_name = {
		from = {"[áàâ]", "[éèê]", "[íìî]", "[óòô]", "[úùû]", ACUTE, GRAVE, CIRC},
		to   = {"a"    , "e"    , "i"    , "o"    , "u"    }},
}

m["ils"] = {
	"International Sign",
	"Q35754",
}

m["ilu"] = {
	"Ili'uun",
	"Q12632888",
}

m["ilv"] = {
	"Ilue",
	"Q3813301",
	"nic-bco",
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
}

m["iml"] = {
	"Miluk",
	"Q3314550",
	otherNames = {"Lower Coquille", "Miluk Coos"},
	scripts = Latn,
}

m["imn"] = {
	"Imonda",
	"Q6005721",
}

m["imo"] = {
	"Imbongu",
	"Q12632895",
}

m["imr"] = {
	"Imroing",
	"Q6008394",
}

m["ims"] = {
	"Marsian",
	"Q1265446",
	"itc",
	scripts = Latn,
}

m["imy"] = {
	"Milyan",
	"Q3832946",
	"ine-ana",
	scripts = {"Lyci"},
}

m["inb"] = {
	"Inga",
	"Q35491",
	"qwe",
}

m["ing"] = {
	"Deg Xinag",
	"Q27782",
}

m["inh"] = {
	"Ingush",
	"Q33509",
	"cau-nkh",
	scripts = {"Cyrl"},
	translit_module = "inh-translit",
	override_translit = true,
	entry_name = {
		from = {MACRON},
		to   = {}},
}

m["inj"] = {
	"Jungle Inga",
	"Q16115012",
}

m["inl"] = {
	"Indonesian Sign Language",
	"Q3915477",
	"sgn",
	scripts = Latn, -- when documented
}

m["inm"] = {
	"Minaean",
	"Q737784",
	scripts = {"Sarb"},
}

m["inn"] = {
	"Isinai",
	"Q6081098",
	"phi",
}

m["ino"] = {
	"Inoke-Yate",
	"Q6036531",
}

m["inp"] = {
	"Iñapari",
	"Q15338035",
	"awd",
	scripts = Latn,
}

m["ins"] = {
	"Indian Sign Language",
	"Q12953486",
	"sgn",
}

m["int"] = {
	"Intha",
	"Q6057507",
    "tbq-brm",
    ancestors = {"obr"},
}

m["inz"] = {
	"Ineseño",
	"Q35443",
	"nai-chu",
	scripts = Latn,
}

m["ior"] = {
	"Inor",
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
	"Chiwere",
	"Q56737",
	"sio",
	otherNames = {"Iowa", "Otoe", "Oto", "Iowa-Otoe-Missouria", "Jiwere", "Jíwere", "Baxoje", "Báxoje", "Báxoje-Jíwere-Ñút'achi", "Báxoje-Jiwére-Ñútˀačhi", "Maʔúŋke", "Nut'achi"},
	scripts = Latn,
}

m["ipi"] = {
	"Ipili",
	"Q6065141",
}

m["ipo"] = {
	"Ipiko",
	"Q10566515",
	"ngf",
}

m["iqu"] = {
	"Iquito",
	"Q2669184",
	"sai-zap",
	scripts = Latn,
}

m["iqw"] = {
	"Ikwo",
	"Q11926474",
	"alv-von",
	scripts = Latn,
}

m["ire"] = {
	"Iresim",
	"Q6069398",
	"poz-hce",
	scripts = Latn,
}

m["irh"] = {
	"Irarutu",
	"Q3027928",
	"poz",
	scripts = Latn,
}

m["iri"] = {
	"Rigwe",
	"Q3912756",
	otherNames = {"Irigwe"},
	scripts = Latn,
}

m["irk"] = {
	"Iraqw",
	"Q33595",
	"cus",
	scripts = Latn,
}

m["irn"] = {
	"Irántxe",
	"Q3409301",
	scripts = Latn,
}

m["irr"] = {
	"Ir",
	"Q3071880",
	"mkh-kat",
}

m["iru"] = {
	"Irula",
	"Q33363",
	"dra",
	scripts = {"Taml"},
}

m["irx"] = {
	"Kamberau",
	"Q6356317",
}

m["iry"] = {
	"Iraya",
	"Q6068356",
	"phi",
}

m["isa"] = {
	"Isabi",
	"Q11732247",
	"paa-kag",
}

m["isc"] = {
	"Isconahua",
	"Q3052971",
	"sai-pan",
	scripts = Latn,
}

m["isd"] = {
	"Isnag",
	"Q6085162",
	"phi",
	otherNames = {"Isneg"},
	scripts = Latn,
}

m["ise"] = {
	"Italian Sign Language",
	"Q375619",
	"sgn",
	scripts = Latn, -- when documented
}

m["isg"] = {
	"Irish Sign Language",
	"Q14183",
	"sgn",
	scripts = Latn, -- when documented
}

m["ish"] = {
	"Esan",
	"Q35268",
	"alv-edo",
	scripts = Latn,
}

m["isi"] = {
	"Nkem-Nkum",
	"Q36261",
	"nic-bod",
	otherNames = {"Isibiri", "Nkem", "Nkim", "Nkum"},
	scripts = Latn,
}

m["isk"] = {
	"Ishkashimi",
	"Q33419",
	"ira-eas",
}

m["ism"] = {
	"Masimasi",
	"Q6783273",
	"poz-ocw",
	scripts = Latn,
}

m["isn"] = {
	"Isanzu",
	"Q6078891",
	scripts = Latn,
}

m["iso"] = {
	"Isoko",
	"Q35414",
	"alv-edo",
	scripts = Latn,
}

m["isr"] = {
	"Israeli Sign Language",
	"Q2911863",
	"sgn",
	scripts = {"Sgnw"},
}

m["ist"] = {
	"Istriot",
	"Q35845",
	"roa",
	scripts = Latn,
}

m["isu"] = {
	"Isu",
	"Q6089423",
	"nic-grf",
	otherNames = {"Isu (Menchum Division)"},
	scripts = Latn,
}

m["itb"] = {
	"Binongan Itneg",
	"Q12953584",
	"phi",
}

m["itd"] = {
	"Southern Tidong",
	nil,
	otherNames = {"Nonukan Tidong", "Southern Tidung", "Nonukan Tidung"},
}

m["ite"] = {
	"Itene",
	"Q3038640",
	"sai-cpc",
	otherNames = {"Itoreauhip"},
	scripts = Latn,
}

m["iti"] = {
	"Inlaod Itneg",
	"Q12953585",
	"phi",
}

m["itk"] = {
	"Judeo-Italian",
	"Q1145414",
	"roa",
	scripts = {"Hebr"},
}

m["itl"] = {
	"Itelmen",
	"Q33624",
	"qfa-cka",
	otherNames = {"Western Itelmen", "Kamchadal"},
	scripts = {"Cyrl", "Latn"},
}

m["itm"] = {
	"Itu Mbon Uzo",
	"Q10977737",
	"nic-bco",
	scripts = Latn,
}

m["ito"] = {
	"Itonama",
	"Q950585",
}

m["itr"] = {
	"Iteri",
	"Q2083185",
}

m["its"] = {
	"Isekiri",
	"Q36045",
	"alv-von",
	otherNames = {"Itsekiri"},
    scripts = Latn,
}

m["itt"] = {
	"Maeng Itneg",
	"Q18748761",
	"phi",
}

m["itv"] = {
	"Itawit",
	"Q3915527",
	"phi",
	otherNames = {"Itawis", "Tawit", "Malaweg", "Malaueg"}, -- Malaweg may need own code
	scripts = Latn,
}

m["itw"] = {
	"Ito",
	"Q11128810",
}

m["itx"] = {
	"Itik",
	"Q6094713",
}

m["ity"] = {
	"Moyadan Itneg",
	"Q12953583",
	"phi",
}

m["itz"] = {
	"Itzá",
	"Q35537",
	"myn",
	otherNames = {"Itza’", "Itza", "Itzaj"},
}

m["ium"] = {
	"Iu Mien",
	"Q2498808",
	"hmx-mie",
}

m["ivb"] = {
	"Ibatan",
	"Q18748212",
	"phi",
	otherNames = {"Ibataan", "Itbayat", "Itbayaten", "Babuyan", "Isamurongen", "Ivatan"}, -- or is Isamurongen ivv
	scripts = Latn,
}

m["ivv"] = {
	"Ivatan",
	"Q3547080",
	"phi",
	otherNames = {"Ivatanen", "Basco Ivatan", "Ivasayen"},
	scripts = Latn,
}

m["iwk"] = {
	"I-Wak",
	"Q12632789",
	"phi",
}

m["iwm"] = {
	"Iwam",
	"Q3915215",
	"paa-spk",
}

m["iwo"] = {
	"Iwur",
	"Q6101006",
}

m["iws"] = {
	"Sepik Iwam",
	"Q16893603",
}

m["ixc"] = {
	"Ixcatec",
	"Q56706",
	"omq",
}

m["ixl"] = {
	"Ixil",
	"Q35528",
	"myn",
	otherNames = {"Ixhil"},
	scripts = Latn,
}

m["iya"] = {
	"Iyayu",
	"Q3913390",
	"alv-edo",
	scripts = Latn,
}

m["iyo"] = {
	"Mesaka",
	"Q36080",
	"nic-bod",
	scripts = Latn,
}

m["iyx"] = {
	"Yaa",
	"Q36909",
	"bnt",
	otherNames = {"Yaka (Republic of Congo)", "Yaka"}, -- a dialect of West Teke; distinguish from 'axk' and especially 'yaf'
	scripts = Latn,
}

m["izh"] = {
	"Ingrian",
	"Q33559",
	"fiu-fin",
	otherNames = {"Izhorian"},
	scripts = Latn,
}

m["izi"] = {
	"Izi-Ezaa-Ikwo-Mgbo",
	nil,
}

m["izr"] = {
	"Izere",
	"Q6101921",
	"nic-bco",
	scripts = Latn,
}

m["izz"] = {
	"Izi",
	"Q3914387",
	"alv-von",
	otherNames = {"Izii", "Izzi"},
	scripts = Latn,
}

return m