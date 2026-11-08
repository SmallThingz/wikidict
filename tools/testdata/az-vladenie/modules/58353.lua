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

local m = {}

m["iai"] = {
	canonicalName = "Iaai",
	family = "poz-occ",
}

m["ian"] = {
	canonicalName = "Iatmul",
}

m["iar"] = {
	canonicalName = "Purari",
}

m["iba"] = {
	canonicalName = "Iban",
	scripts = {"Latn"},
	family = "poz-mly",
}

m["ibb"] = {
	canonicalName = "Ibibio",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ibd"] = {
	canonicalName = "Iwaidja",
	scripts = {"Latn"},
	family = "aus-wdj",
}

m["ibe"] = {
	canonicalName = "Akpes",
}

m["ibg"] = {
	canonicalName = "Ibanag",
	family = "phi",
}

m["ibl"] = {
	canonicalName = "Ibaloi",
	otherNames = {"Ibaloy", "Inibaloi", "Inibaloy"},
	family = "phi",
}

m["ibm"] = {
	canonicalName = "Agoi",
	family = "nic-bco",
}

m["ibn"] = {
	canonicalName = "Ibino",
}

m["ibr"] = {
	canonicalName = "Ibuoro",
}

m["ibu"] = {
	canonicalName = "Ibu",
}

m["iby"] = {
	canonicalName = "Ibani",
}

m["ica"] = {
	canonicalName = "Ede Ica",
}

m["ich"] = {
	canonicalName = "Etkywan",
}

m["icl"] = {
	canonicalName = "Icelandic Sign Language",
	family = "sgn",
}

m["icr"] = {
	canonicalName = "Islander Creole English",
}

m["ida"] = {
	canonicalName = "Idakho-Isukha-Tiriki",
}

m["idb"] = {
	canonicalName = "Indo-Portuguese",
	scripts = {"Latn"},
	family = "crp",
}

m["idc"] = {
	canonicalName = "Idon",
}

m["idd"] = {
	canonicalName = "Ede Idaca",
}

m["ide"] = {
	canonicalName = "Idere",
}

m["idi"] = {
	canonicalName = "Idi",
}

m["idr"] = {
	canonicalName = "Indri",
}

m["ids"] = {
	canonicalName = "Idesa",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["idt"] = {
	canonicalName = "Idaté",
	family = "plf",
}

m["idu"] = {
	canonicalName = "Idoma",
	family = "alv",
}

m["ifa"] = {
	canonicalName = "Amganad Ifugao",
	otherNames = {"Amganad Ifugaw"},
}

m["ifb"] = {
	canonicalName = "Batad Ifugao",
	otherNames = {"Batad Ifugaw", "Ifugaw", "Batad"},
}

m["ife"] = {
	canonicalName = "Ifè",
}

m["iff"] = {
	canonicalName = "Ifo",
}

m["ifk"] = {
	canonicalName = "Tuwali Ifugao",
	otherNames = {"Tuwali Ifugaw"},
}

m["ifm"] = {
	canonicalName = "Teke-Fuumu",
}

m["ifu"] = {
	canonicalName = "Mayoyao Ifugao",
	otherNames = {"Mayoyao Ifugaw"},
	scripts = {"Latn"},
	family = "phi",
}

m["ify"] = {
	canonicalName = "Keley-I Kallahan",
}

m["igb"] = {
	canonicalName = "Ebira",
	otherNames = {"Igbira"},
	scripts = {"Latn"},
}

m["ige"] = {
	canonicalName = "Igede",
	family = "alv",
}

m["igg"] = {
	canonicalName = "Igana",
	family = "paa",
}

m["igl"] = {
	canonicalName = "Igala",
}

m["igm"] = {
	canonicalName = "Kanggape",
	family = "paa",
}

m["ign"] = {
	canonicalName = "Ignaciano",
	otherNames = {"Ignaciano Moxos", "Moxo", "Moxos", "Mojo", "Moxa"},
	family = "awd",
}

m["igo"] = {
	canonicalName = "Isebe",
}

m["igs"] = {
	canonicalName = "Glosa",
	type = "appendix-constructed",
	family = "art",
}

m["igw"] = {
	canonicalName = "Igwe",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ihb"] = {
	canonicalName = "Iha Based Pidgin",
}

m["ihi"] = {
	canonicalName = "Ihievbe",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ihp"] = {
	canonicalName = "Iha",
}

m["ijc"] = {
	canonicalName = "Izon",
	otherNames = {"Kolokuma", "Ekpetiama", "Gbanran", "Central-Western Ijo"},
	scripts = {"Latn"},
	family = "nic",
}

m["ije"] = {
	canonicalName = "Biseni",
}

m["ijj"] = {
	canonicalName = "Ede Ije",
}

m["ijn"] = {
	canonicalName = "Kalabari",
}

m["ijs"] = {
	canonicalName = "Southeast Ijo",
	otherNames = {"Southeastern Ijo", "Nembe"},
	scripts = {"Latn"},
	family = "nic",
}

m["ike"] = {
	canonicalName = "Eastern Canadian Inuktitut",
	scripts = {"Cans"},
	family = "esx-inu",
}

m["iki"] = {
	canonicalName = "Iko",
}

m["ikk"] = {
	canonicalName = "Ika",
}

m["ikl"] = {
	canonicalName = "Ikulu",
	otherNames = {"Kulu"},
	scripts = {"Latn"},
	family = "nic-bco",
}

m["iko"] = {
	canonicalName = "Olulumo-Ikom",
	family = "nic-bco",
}

m["ikp"] = {
	canonicalName = "Ikpeshi",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["ikr"] = {
	canonicalName = "Ikaranggal",
	otherNames = {"Ikarranggal", "Ikarranggali"},
	family = "aus-pam",
}

m["iks"] = {
	canonicalName = "Inuit Sign Language",
	otherNames = {"Inuit Uukturausingit", "ISL", "IUR"},
	family = "sgn",
}

m["ikt"] = {
	canonicalName = "Western Canadian Inuktitut",
	scripts = {"Cans"},
	family = "esx-inu",
}

m["ikv"] = {
	canonicalName = "Iku-Gora-Ankwa",
}

m["ikw"] = {
	canonicalName = "Ikwere",
}

m["ikx"] = {
	canonicalName = "Ik",
	scripts = {"Latn"},
	family = "ssa",
}

m["ikz"] = {
	canonicalName = "Ikizu",
}

m["ila"] = {
	canonicalName = "Ile Ape",
}

m["ilb"] = {
	canonicalName = "Ila",
	scripts = {"Latn"},
	family = "bnt",
}

m["ilg"] = {
	canonicalName = "Ilgar",
	otherNames = {"Garig"},
	scripts = {"Latn"},
	family = "aus-wdj",
}

m["ili"] = {
	canonicalName = "Ili Turki",
	family = "trk",
}

m["ilk"] = {
	canonicalName = "Ilongot",
	scripts = {"Latn"},
	family = "phi",
}

m["ill"] = {
	canonicalName = "Iranun",
	otherNames = {"Iranun", "Ilanun", "Iranun (Malaysia)", "Iranun (Philippines)"},
	scripts = {"Latn"},
	family = "phi",
}

m["ilo"] = {
	canonicalName = "Ilocano",
	otherNames = {"Ilokano"},
	scripts = {"Latn", "Tglg"},
	family = "phi",
}

m["ils"] = {
	canonicalName = "International Sign",
}

m["ilu"] = {
	canonicalName = "Ili'uun",
}

m["ilv"] = {
	canonicalName = "Ilue",
}

m["ima"] = {
	canonicalName = "Mala Malasar",
	family = "dra",
}

m["imi"] = {
	canonicalName = "Anamgura",
}

m["iml"] = {
	canonicalName = "Miluk",
	otherNames = {"Lower Coquille", "Miluk Coos"},
	scripts = {"Latn"},
}

m["imn"] = {
	canonicalName = "Imonda",
}

m["imo"] = {
	canonicalName = "Imbongu",
}

m["imr"] = {
	canonicalName = "Imroing",
}

m["ims"] = {
	canonicalName = "Marsian",
	scripts = {"Latn"},
	family = "itc",
}

m["imy"] = {
	canonicalName = "Milyan",
	scripts = {"Lyci"},
	family = "ine-ana",
}

m["inb"] = {
	canonicalName = "Inga",
}

m["ing"] = {
	canonicalName = "Deg Xinag",
}

m["inh"] = {
	canonicalName = "Ingush",
	scripts = {"Cyrl"},
	family = "cau-nkh",
	translit_module = "inh-translit",
	entry_name = {
		from = {MACRON},
		to   = {}},
}

m["inj"] = {
	canonicalName = "Jungle Inga",
}

m["inl"] = {
	canonicalName = "Indonesian Sign Language",
	family = "sgn",
}

m["inm"] = {
	canonicalName = "Minaean",
}

m["inn"] = {
	canonicalName = "Isinai",
}

m["ino"] = {
	canonicalName = "Inoke-Yate",
}

m["inp"] = {
	canonicalName = "Iñapari",
	family = "awd",
}

m["ins"] = {
	canonicalName = "Indian Sign Language",
	family = "sgn",
}

m["int"] = {
	canonicalName = "Intha",
}

m["inz"] = {
	canonicalName = "Ineseño",
	scripts = {"Latn"},
	family = "nai-chu",
}

m["ior"] = {
	canonicalName = "Inor",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["iou"] = {
	canonicalName = "Tuma-Irumu",
	family = "ngf-fin",
}

m["iow"] = {
	canonicalName = "Chiwere",
	otherNames = {"Iowa", "Otoe", "Oto", "Iowa-Otoe-Missouria", "Jiwere", "Jíwere", "Baxoje", "Báxoje", "Báxoje-Jíwere-Ñút'achi", "Báxoje-Jiwére-Ñútˀačhi", "Maʔúŋke", "Nut'achi"},
	scripts = {"Latn"},
	family = "sio",
}

m["ipi"] = {
	canonicalName = "Ipili",
}

m["ipo"] = {
	canonicalName = "Ipiko",
}

m["iqu"] = {
	canonicalName = "Iquito",
	family = "sai-zap",
}

m["iqw"] = {
	canonicalName = "Ikwo",
	family = "alv-von",
}

m["ire"] = {
	canonicalName = "Iresim",
	family = "poz-hce",
}

m["irh"] = {
	canonicalName = "Irarutu",
}

m["iri"] = {
	canonicalName = "Irigwe",
}

m["irk"] = {
	canonicalName = "Iraqw",
	family = "cus",
}

m["irn"] = {
	canonicalName = "Irántxe",
}

m["irr"] = {
	canonicalName = "Ir",
	family = "mkh",
}

m["iru"] = {
	canonicalName = "Irula",
	scripts = {"Taml"},
	family = "dra",
}

m["irx"] = {
	canonicalName = "Kamberau",
}

m["iry"] = {
	canonicalName = "Iraya",
}

m["isa"] = {
	canonicalName = "Isabi",
}

m["isc"] = {
	canonicalName = "Isconahua",
	family = "sai-pan",
}

m["isd"] = {
	canonicalName = "Isnag",
	otherNames = {"Isneg"},
	scripts = {"Latn"},
	family = "phi",
}

m["ise"] = {
	canonicalName = "Italian Sign Language",
	family = "sgn",
}

m["isg"] = {
	canonicalName = "Irish Sign Language",
	family = "sgn",
}

m["ish"] = {
	canonicalName = "Esan",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["isi"] = {
	canonicalName = "Nkem-Nkum",
	otherNames = {"Isibiri", "Nkem", "Nkim", "Nkum"},
	family = "nic-bod",
}

m["isk"] = {
	canonicalName = "Ishkashimi",
	family = "ira",
}

m["ism"] = {
	canonicalName = "Masimasi",
	family = "poz-ocw",
}

m["isn"] = {
	canonicalName = "Isanzu",
}

m["iso"] = {
	canonicalName = "Isoko",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["isr"] = {
	canonicalName = "Israeli Sign Language",
	scripts = {"Sgnw"},
	family = "sgn",
}

m["ist"] = {
	canonicalName = "Istriot",
	scripts = {"Latn"},
	family = "roa",
}

m["isu"] = {
	canonicalName = "Isu",
	otherNames = {"Isu (Menchum Division)"},
	scripts = {"Latn"},
	family = "nic-grf",
}

m["itb"] = {
	canonicalName = "Binongan Itneg",
}

m["itd"] = {
	canonicalName = "Southern Tidong",
	otherNames = {"Nonukan Tidong", "Southern Tidung", "Nonukan Tidung"},
}

m["ite"] = {
	canonicalName = "Itene",
	otherNames = {"Itoreauhip"},
	scripts = {"Latn"},
	family = "sai-cpc",
}

m["iti"] = {
	canonicalName = "Inlaod Itneg",
}

m["itk"] = {
	canonicalName = "Judeo-Italian",
	scripts = {"Hebr"},
	family = "roa",
}

m["itl"] = {
	canonicalName = "Itelmen",
	otherNames = {"Western Itelmen", "Kamchadal"},
	scripts = {"Cyrl", "Latn"},
	family = "qfa-cka",
}

m["itm"] = {
	canonicalName = "Itu Mbon Uzo",
	scripts = {"Latn"},
	family = "nic-bco",
}

m["ito"] = {
	canonicalName = "Itonama",
}

m["itr"] = {
	canonicalName = "Iteri",
}

m["its"] = {
	canonicalName = "Isekiri",
}

m["itt"] = {
	canonicalName = "Maeng Itneg",
}

m["itv"] = {
	canonicalName = "Itawit",
	otherNames = {"Itawis", "Tawit", "Malaweg", "Malaueg"}, -- Malaweg may need own code
	scripts = {"Latn"},
	family = "phi",
}

m["itw"] = {
	canonicalName = "Ito",
}

m["itx"] = {
	canonicalName = "Itik",
}

m["ity"] = {
	canonicalName = "Moyadan Itneg",
}

m["itz"] = {
	canonicalName = "Itzá",
	otherNames = {"Itza’", "Itza", "Itzaj"},
	family = "myn",
}

m["ium"] = {
	canonicalName = "Iu Mien",
	family = "hmx-mie",
}

m["ivb"] = {
	canonicalName = "Ibatan",
	otherNames = {"Ibataan", "Itbayat", "Itbayaten", "Babuyan", "Isamurongen", "Ivatan"}, -- or is Isamurongen ivv
	scripts = {"Latn"},
	family = "phi",
}

m["ivv"] = {
	canonicalName = "Ivatan",
	otherNames = {"Ivatanen", "Basco Ivatan", "Ivasayen"},
	scripts = {"Latn"},
	family = "phi",
}

m["iwk"] = {
	canonicalName = "I-Wak",
}

m["iwm"] = {
	canonicalName = "Iwam",
}

m["iwo"] = {
	canonicalName = "Iwur",
}

m["iws"] = {
	canonicalName = "Sepik Iwam",
}

m["ixc"] = {
	canonicalName = "Ixcatec",
}

m["ixl"] = {
	canonicalName = "Ixil",
}

m["iya"] = {
	canonicalName = "Iyayu",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["iyo"] = {
	canonicalName = "Mesaka",
	family = "nic-bod",
}

m["iyx"] = {
	canonicalName = "Yaa",
	otherNames = {"Yaka (Republic of Congo)", "Yaka"}, -- a dialect of West Teke; distinguish from 'axk' and especially 'yaf'
	family = "bnt",
}

m["izh"] = {
	canonicalName = "Ingrian",
	otherNames = {"Izhorian"},
	scripts = {"Latn"},
	family = "fiu-fin",
}

m["izi"] = {
	canonicalName = "Izi-Ezaa-Ikwo-Mgbo",
}

m["izr"] = {
	canonicalName = "Izere",
}

m["izz"] = {
	canonicalName = "Izi",
	otherNames = {"Izii", "Izzi"},
	family = "alv-von",
}

return m