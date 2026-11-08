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

m["saa"] = {
	canonicalName = "Saba",
	scripts = {"Latn"},
	family = "cdc",
}

m["sab"] = {
	canonicalName = "Buglere",
	otherNames = {"Bugle", "Murire", "Muoy", "Sabanero", "Bokotá", "Bogota"},
	scripts = {"Latn"},
	family = "cba",
}

m["sac"] = {
	canonicalName = "Fox",
	otherNames = {"Sac", "Sauk", "Kickapoo", "Mesquakie", "Meskwaki"},
	scripts = {"Latn"},
	family = "alg",
}

m["sad"] = {
	canonicalName = "Sandawe",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["sae"] = {
	canonicalName = "Sabanê",
	scripts = {"Latn"},
	family = "sai-nmk",
}

m["saf"] = {
	canonicalName = "Safaliba",
	scripts = {"Latn"},
	family = "nic-gur",
}

m["sah"] = {
	canonicalName = "Yakut",
	otherNames = {"Sakha"},
	scripts = {"Cyrl"},
	family = "trk",
	translit_module = "sah-translit",
}

m["saj"] = {
	canonicalName = "Sahu",
	scripts = {"Latn"},
	family = "paa",
}

m["sak"] = {
	canonicalName = "Sake",
	otherNames = {"Shake"},
	scripts = {"Latn"},
	family = "nic-bod",
}

m["sam"] = {
	canonicalName = "Samaritan Aramaic",
	otherNames = {"Samaritan"},
	scripts = {"Samr"},
	family = "sem-ara",
}

m["sao"] = {
	canonicalName = "Sause",
	scripts = {"Latn"},
}

m["saq"] = {
	canonicalName = "Samburu",
	family = "sdv",
}

m["sar"] = {
	canonicalName = "Saraveca",
	otherNames = {"Sarabeca", "Saraveka", "Sarave"},
	family = "awd",
}

m["sas"] = {
	canonicalName = "Sasak",
	scripts = {"Latn"},
	family = "poz-msa",
}

m["sat"] = {
	canonicalName = "Santali",
	scripts = {"Olck"},
	family = "mun",
}

m["sau"] = {
	canonicalName = "Saleman",
	family = "plf",
}

m["sav"] = {
	canonicalName = "Saafi-Saafi",
	family = "alv-sng",
}

m["saw"] = {
	canonicalName = "Sawi",
	scripts = {"Latn"},
	family = "ngf",
}

m["sax"] = {
	canonicalName = "Sa",
	otherNames = {"Saa"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["say"] = {
	canonicalName = "Saya",
}

m["saz"] = {
	canonicalName = "Saurashtra",
	scripts = {"Saur", "Latn", "Taml", "Deva"},
	family = "inc",
}

m["sba"] = {
	canonicalName = "Ngambay",
}

m["sbb"] = {
	canonicalName = "Simbo",
	family = "poz-ocw",
}

m["sbc"] = {
	canonicalName = "Gele'",
	otherNames = {"Kele (New Guinea)", "Kele (Papua New Guinea)", "Kele"},
	family = "poz-oce",
}

m["sbd"] = {
	canonicalName = "Southern Samo",
}

m["sbe"] = {
	canonicalName = "Saliba (New Guinea)",
	otherNames = {"Saliba"},
	family = "poz-ocw",
}

m["sbf"] = {
	canonicalName = "Shabo",
	otherNames = {"Mikeyir", "Mekeyir", "Mekeyer"},
	scripts = {"Latn"},
	family = "ssa",
}

m["sbg"] = {
	canonicalName = "Seget",
}

m["sbh"] = {
	canonicalName = "Sori-Harengan",
	otherNames = {"Sori", "Harengan"},
	scripts = {"Latn"},
	family = "poz-aay",
}

m["sbi"] = {
	canonicalName = "Seti",
	family = "qfa-tor",
}

m["sbj"] = {
	canonicalName = "Surbakhal",
}

m["sbk"] = {
	canonicalName = "Safwa",
}

m["sbl"] = {
	canonicalName = "Botolan Sambal",
}

m["sbm"] = {
	canonicalName = "Sagala",
}

m["sbn"] = {
	canonicalName = "Sindhi Bhil",
	scripts = {"Arab", "Deva", "Sind", "Guru"},
	family = "inc",
	ancestors = {"sd"},
}

m["sbo"] = {
	canonicalName = "Sabüm",
}

m["sbp"] = {
	canonicalName = "Sangu",
}

m["sbq"] = {
	canonicalName = "Sileibi",
}

m["sbr"] = {
	canonicalName = "Sembakung Murut",
}

m["sbs"] = {
	canonicalName = "Subiya",
}

m["sbt"] = {
	canonicalName = "Kimki",
}

m["sbu"] = {
	canonicalName = "Stod Bhoti",
}

m["sbv"] = {
	canonicalName = "Sabine",
	scripts = {"Latn"},
	family = "itc",
}

m["sbw"] = {
	canonicalName = "Simba",
}

m["sbx"] = {
	canonicalName = "Seberuang",
}

m["sby"] = {
	canonicalName = "Soli",
}

m["sbz"] = {
	canonicalName = "Sara Kaba",
}

m["scb"] = {
	canonicalName = "Chut",
	family = "mkh-vie",
}

m["sce"] = {
	canonicalName = "Dongxiang",
	otherNames = {"Santa"},
	scripts = {"Arab", "Latn"},
	family = "xgn",
}

m["scf"] = {
	canonicalName = "San Miguel Creole French",
}

m["scg"] = {
	canonicalName = "Sanggau",
}

m["sch"] = {
	canonicalName = "Sakachep",
	otherNames = {"Khelma"},
	family = "sit",
}

m["sci"] = {
	canonicalName = "Sri Lankan Creole Malay",
}

m["sck"] = {
	canonicalName = "Sadri",
	family = "inc",
	ancestors = {"bh"},
}

m["scl"] = {
	canonicalName = "Shina",
}

m["scn"] = {
	canonicalName = "Sicilian",
	scripts = {"Latn"},
	family = "roa",
}

m["sco"] = {
	canonicalName = "Scots",
	otherNames = {"Lowland Scots"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"enm"},
}

m["scp"] = {
	canonicalName = "Helambu Sherpa",
}

m["scq"] = {
	canonicalName = "Sa'och",
}

m["scs"] = {
	canonicalName = "North Slavey",
}

m["scu"] = {
	canonicalName = "Shumcho",
}

m["scv"] = {
	canonicalName = "Sheni",
}

m["scw"] = {
	canonicalName = "Sha",
}

m["scx"] = {
	canonicalName = "Sicel",
	family = "ine",
}

m["sda"] = {
	canonicalName = "Toraja-Sa'dan",
}

m["sdb"] = {
	canonicalName = "Shabak",
	family = "ira",
}

m["sdc"] = {
	canonicalName = "Sassarese",
	scripts = {"Latn"},
	family = "roa",
}

m["sde"] = {
	canonicalName = "Surubu",
}

m["sdf"] = {
	canonicalName = "Sarli",
	family = "ira",
}

m["sdg"] = {
	canonicalName = "Savi",
}

m["sdh"] = {
	canonicalName = "Southern Kurdish",
	otherNames = {"Kermanshani", "Kermanshahi", "Kermanshahi Kurdish", "Kermanshani Kurdish"},
	scripts = {"ku-Arab"},
	family = "ira",
	ancestors = {"ku"},
}

m["sdj"] = {
	canonicalName = "Suundi",
}

m["sdk"] = {
	canonicalName = "Sos Kundi",
}

m["sdl"] = {
	canonicalName = "Saudi Arabian Sign Language",
	family = "sgn",
}

m["sdm"] = {
	canonicalName = "Semandang",
}

m["sdn"] = {
	canonicalName = "Gallurese",
	scripts = {"Latn"},
	family = "roa",
	ancestors = {"co"},
}

m["sdo"] = {
	canonicalName = "Bukar-Sadung Bidayuh",
}

m["sdp"] = {
	canonicalName = "Sherdukpen",
}

m["sdr"] = {
	canonicalName = "Oraon Sadri",
	family = "inc",
	ancestors = {"bh"},
}

m["sds"] = {
	canonicalName = "Sened",
}

m["sdu"] = {
	canonicalName = "Sarudu",
}

m["sdx"] = {
	canonicalName = "Sibu Melanau",
}

m["sea"] = {
	canonicalName = "Semai",
}

m["sec"] = {
	canonicalName = "Sechelt",
	family = "sal",
}

m["sed"] = {
	canonicalName = "Sedang",
	family = "aav-nbn",
}

m["see"] = {
	canonicalName = "Seneca",
	scripts = {"Latn"},
	family = "iro",
}

m["sef"] = {
	canonicalName = "Cebaara Senoufo",
}

m["seg"] = {
	canonicalName = "Segeju",
}

m["seh"] = {
	canonicalName = "Sena",
}

m["sei"] = {
	canonicalName = "Seri",
	scripts = {"Latn"},
	family = "qfa-iso",
}

m["sej"] = {
	canonicalName = "Sene",
}

m["sek"] = {
	canonicalName = "Sekani",
	otherNames = {"Tsek'ene", "Kwadacha", "Kwadacha Sekani", "Kwadacha Tsek'ene"},
	scripts = {"Latn"},
}

m["sel"] = {
	canonicalName = "Selkup",
	scripts = {"Cyrl"},
	family = "syd",
}

m["sen"] = {
	canonicalName = "Nanerigé Sénoufo",
}

m["seo"] = {
	canonicalName = "Suarmin",
}

m["sep"] = {
	canonicalName = "Sìcìté Sénoufo",
}

m["seq"] = {
	canonicalName = "Senara Sénoufo",
}

m["ser"] = {
	canonicalName = "Serrano",
	otherNames = {"Kitanemuk"},
	scripts = {"Latn"},
	family = "azc-tak",
}

m["ses"] = {
	canonicalName = "Koyraboro Senni",
	otherNames = {"Koyraboro Senni Songhai", "Koroboro Senni", "Eastern Songhay"},
	scripts = {"Latn"},
	family = "son",
}

m["set"] = {
	canonicalName = "Sentani",
}

m["seu"] = {
	canonicalName = "Serui-Laut",
	scripts = {"Latn"},
	family = "poz-hce",
}

m["sev"] = {
	canonicalName = "Nyarafolo Senoufo",
}

m["sew"] = {
	canonicalName = "Sewa Bay",
	family = "poz-ocw",
}

m["sey"] = {
	canonicalName = "Secoya",
	scripts = {"Latn"},
	family = "sai-tuc",
}

m["sez"] = {
	canonicalName = "Senthang Chin",
	otherNames = {"Senthang"},
	family = "tbq-kuk",
}

m["sfb"] = {
	canonicalName = "French Belgian Sign Language",
	family = "sgn",
}

m["sfm"] = {
	canonicalName = "Small Flowery Miao",
	family = "hmn",
}

m["sfs"] = {
	canonicalName = "South African Sign Language",
	family = "sgn",
}

m["sfw"] = {
	canonicalName = "Sehwi",
}

m["sga"] = {
	canonicalName = "Old Irish",
	scripts = {"Latn"},
	family = "cel-gae",
	ancestors = {"pgl"},
	entry_name = {
		from = {"ḟ", "ṡ", "Ḟ", "Ṡ", "ä", "ë", "ï", "ö", "ü", "·"},
		to   = {"f", "s", "F", "S", "a", "e", "i", "o", "u"}} ,
	sort_key = {
		from = {"á", "é", "æ", "ǽ", "í", "ó", "ú", "^h"},
		to   = {"a", "e", "e", "e", "i", "o", "u"}} ,
}

m["sgb"] = {
	canonicalName = "Mag-Anchi Ayta",
}

m["sgc"] = {
	canonicalName = "Kipsigis",
	family = "sdv",
}

m["sgd"] = {
	canonicalName = "Surigaonon",
	scripts = {"Latn"},
	family = "phi",
}

m["sge"] = {
	canonicalName = "Segai",
}

m["sgg"] = {
	canonicalName = "Swiss-German Sign Language",
	otherNames = {"Swiss German Sign Language"},
	family = "sgn",
}

m["sgh"] = {
	canonicalName = "Shughni",
	scripts = {"Cyrl"},
	family = "ira",
	translit_module = "sgh-translit",
}

m["sgi"] = {
	canonicalName = "Suga",
	family = "nic-bod",
}

m["sgk"] = {
	canonicalName = "Sangkong",
	family = "tbq-lol",
}

m["sgm"] = {
	canonicalName = "Singa",
}

m["sgp"] = {
	canonicalName = "Singpho",
}

m["sgr"] = {
	canonicalName = "Sangisari",
	family = "ira",
}

m["sgs"] = {
	canonicalName = "Samogitian",
	scripts = {"Latn"},
	family = "bat",
	ancestors = {"olt"},
	wikimedia_codes = {"bat-smg"},
}

m["sgt"] = {
	canonicalName = "Brokpake",
}

m["sgu"] = {
	canonicalName = "Salas",
}

m["sgw"] = {
	canonicalName = "Sebat Bet Gurage",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["sgx"] = {
	canonicalName = "Sierra Leone Sign Language",
	family = "sgn",
}

m["sgy"] = {
	canonicalName = "Sanglechi",
	otherNames = {"Sanglich", "Warduji"},
	family = "ira",
}

m["sgz"] = {
	canonicalName = "Sursurunga",
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["sha"] = {
	canonicalName = "Shall-Zwall",
}

m["shb"] = {
	canonicalName = "Ninam",
}

m["shc"] = {
	canonicalName = "Sonde",
}

m["shd"] = {
	canonicalName = "Kundal Shahi",
}

m["she"] = {
	canonicalName = "Sheko",
	otherNames = {"Ho Ne", "Ho Nte"},
	family = "hmn",
}

m["shg"] = {
	canonicalName = "Shua",
}

m["shh"] = {
	canonicalName = "Shoshone",
	otherNames = {"Shoshoni", "Gosiute", "Goshute", "Eastern Shoshone", "Eastern Shoshoni", "Western Shoshone", "Western Shoshoni", "Northern Shoshone", "Northern Shoshoni"},
	scripts = {"Latn"},
	family = "azc-num",
}

m["shi"] = {
	canonicalName = "Tashelhit",
	otherNames = {"Tachelhit", "Chleuh", "Shilha", "Tashlhiyt", "Tashelhit Berber", "Tachelhit Berber", "Tashlhiyt Berber"},
	scripts = {"Tfng", "Arab", "Latn"},
	family = "ber",
}

m["shj"] = {
	canonicalName = "Shatt",
	family = "sdv",
}

m["shk"] = {
	canonicalName = "Shilluk",
	family = "sdv",
}

m["shl"] = {
	canonicalName = "Shendu",
	family = "tbq-kuk",
}

m["shm"] = {
	canonicalName = "Shahrudi",
	family = "ira",
	ancestors = {"ira-azr"},
}

m["shn"] = {
	canonicalName = "Shan",
	scripts = {"Mymr"},
	family = "tai-swe",
	sort_key = {
		from = {"[ၢႃ]", "ဵ", "ႅ", "ႇ", "ႈ", "း", "ႉ", "ႊ"},
		to   = {"ာ", "ေ", "ႄ", "႒", "႓", "႔", "႕", "႖"}},
}

m["sho"] = {
	canonicalName = "Shanga",
}

m["shp"] = {
	canonicalName = "Shipibo-Conibo",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["shq"] = {
	canonicalName = "Sala",
}

m["shr"] = {
	canonicalName = "Shi",
}

m["shs"] = {
	canonicalName = "Shuswap",
	scripts = {"Latn"},
	family = "sal",
}

m["sht"] = {
	canonicalName = "Shasta",
	scripts = {"Latn"},
	family = "nai-shs",
}

m["shu"] = {
	canonicalName = "Chadian Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["shv"] = {
	canonicalName = "Shehri",
	ancestors = {"sem-pro"},
}

m["shw"] = {
	canonicalName = "Shwai",
}

m["shx"] = {
	canonicalName = "She",
}

m["shy"] = {
	canonicalName = "Tachawit",
	otherNames = {"Shawiya Berber", "Chaouïa"},
	family = "ber",
}

m["shz"] = {
	canonicalName = "Syenara Senoufo",
}

m["sia"] = {
	canonicalName = "Akkala Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["sib"] = {
	canonicalName = "Sebop",
	family = "poz-swa",
}

m["sid"] = {
	canonicalName = "Sidamo",
	family = "cus",
}

m["sie"] = {
	canonicalName = "Simaa",
}

m["sif"] = {
	canonicalName = "Siamou",
}

m["sig"] = {
	canonicalName = "Paasaal",
}

m["sih"] = {
	canonicalName = "Zire",
	family = "poz-cln",
}

m["sii"] = {
	canonicalName = "Shom Peng",
	family = "aav",
}

m["sij"] = {
	canonicalName = "Numbami",
	family = "poz-ocw",
}

m["sik"] = {
	canonicalName = "Sikiana",
	scripts = {"Latn"},
	family = "sai-car",
}

m["sil"] = {
	canonicalName = "Tumulung Sisaala",
}

m["sim"] = {
	canonicalName = "Seim",
	otherNames = {"Mende", "Mende (New Guinea)"},
}

m["sip"] = {
	canonicalName = "Sikkimese",
	otherNames = {"Dranjongke", "Dranjoke", "Denjongka", "Denzongpeke", "Denzongke"},
	scripts = {"Tibt"},
	family = "tbq",
	ancestors = {"xct"},
	translit_module = "bo-translit",
}

m["siq"] = {
	canonicalName = "Sonia",
}

m["sir"] = {
	canonicalName = "Siri",
}

m["sis"] = {
	canonicalName = "Siuslaw",
}

m["siu"] = {
	canonicalName = "Sinagen",
	family = "qfa-tor",
}

m["siv"] = {
	canonicalName = "Sumariup",
}

m["siw"] = {
	canonicalName = "Siwai",
}

m["six"] = {
	canonicalName = "Sumau",
}

m["siy"] = {
	canonicalName = "Sivandi",
	family = "ira",
}

m["siz"] = {
	canonicalName = "Siwa",
	scripts = {"Tfng", "Arab"},
	family = "ber",
}

m["sja"] = {
	canonicalName = "Epena",
}

m["sjb"] = {
	canonicalName = "Sajau Basap",
}

m["sjd"] = {
	canonicalName = "Kildin Sami",
	scripts = {"Cyrl"},
	family = "smi",
	translit_module = "sjd-translit",
}

m["sje"] = {
	canonicalName = "Pite Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["sjg"] = {
	canonicalName = "Assangori",
}

m["sjk"] = {
	canonicalName = "Kemi Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["sjl"] = {
	canonicalName = "Miji",
}

m["sjm"] = {
	canonicalName = "Mapun",
}

m["sjn"] = {
	canonicalName = "Sindarin",
	type = "appendix-constructed",
	scripts = {"Latn", "Teng"},
	family = "art",
}

m["sjo"] = {
	canonicalName = "Xibe",
	otherNames = {"Sibo", "Sibe", "Xibo"},
	scripts = {"Mong"},
	family = "tuw",
}

m["sjp"] = {
	canonicalName = "Surjapuri",
}

m["sjr"] = {
	canonicalName = "Siar-Lak",
	family = "poz-ocw",
}

m["sjs"] = {
	canonicalName = "Senhaja De Srair",
	family = "ber",
}

m["sjt"] = {
	canonicalName = "Ter Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["sju"] = {
	canonicalName = "Ume Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["sjw"] = {
	canonicalName = "Shawnee",
	scripts = {"Latn"},
	family = "alg",
}

m["ska"] = {
	canonicalName = "Skagit",
}

m["skb"] = {
	canonicalName = "Saek",
}

m["skc"] = {
	canonicalName = "Ma Manda",
	otherNames = {"Sauk"},
	family = "ngf-fin",
}

m["skd"] = {
	canonicalName = "Southern Sierra Miwok",
	family = "nai-utn",
}

m["ske"] = {
	canonicalName = "Ske",
	otherNames = {"Seke"},
	scripts = {"Latn"},
	family = "poz-vnc",
}

m["skf"] = {
	canonicalName = "Sakirabiá",
}

m["skh"] = {
	canonicalName = "Sikule",
}

m["ski"] = {
	canonicalName = "Sika",
	otherNames = {"Sikanese"},
	scripts = {"Latn"},
	family = "plf",
}

m["skj"] = { -- compare 'ths'
	canonicalName = "Seke",
	family = "tbq",
}

m["skk"] = {
	canonicalName = "Sok",
	family = "aav-ban",
}

m["skm"] = {
	canonicalName = "Sakam",
	otherNames = {"Kutong"},
	family = "ngf-fin",
}

m["skn"] = {
	canonicalName = "Kolibugan Subanon",
	family = "phi",
}

m["sko"] = {
	canonicalName = "Seko Tengah",
	family = "poz",
}

m["skp"] = {
	canonicalName = "Sekapan",
}

m["skq"] = {
	canonicalName = "Sininkere",
}

m["skr"] = {
	canonicalName = "Seraiki",
	otherNames = {"Siraiki", "Saraiki"},
	scripts = {"ur-Arab"},
	family = "inc",
	ancestors = {"lah"},
}

m["sks"] = {
	canonicalName = "Maia",
}

m["skt"] = {
	canonicalName = "Sakata",
}

m["sku"] = {
	canonicalName = "Sakao",
	family = "poz-vnc",
}

m["skv"] = {
	canonicalName = "Skou",
}

m["skw"] = {
	canonicalName = "Skepi Creole Dutch",
	otherNames = {"Skepi Dutch", "Skepi Dutch Creole", "Essequibo Dutch"},
}

m["skx"] = {
	canonicalName = "Seko Padang",
}

m["sky"] = {
	canonicalName = "Sikaiana",
	otherNames = {"Sikayana"},
	scripts = {"Latn"},
	family = "poz-pol",
}

m["skz"] = {
	canonicalName = "Sekar",
}

m["slc"] = {
	canonicalName = "Saliba (Colombia)",
	otherNames = {"Saliba", "Sáliba", "Saliva", "Sáliva"},
}

m["sld"] = {
	canonicalName = "Sissala",
}

m["sle"] = {
	canonicalName = "Sholaga",
	family = "dra",
}

m["slf"] = {
	canonicalName = "Swiss-Italian Sign Language",
	otherNames = {"Swiss Italian Sign Language"},
	family = "sgn",
}

m["slg"] = {
	canonicalName = "Selungai Murut",
}

m["slh"] = {
	canonicalName = "Southern Puget Sound Salish",
}

m["sli"] = {
	canonicalName = "Silesian German",
	otherNames = {"Silesian"},
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gmh"},
}

m["slj"] = {
	canonicalName = "Salumá",
	scripts = {"Latn"},
	family = "sai-car",
}

m["sll"] = {
	canonicalName = "Salt-Yui",
}

m["slm"] = {
	canonicalName = "Pangutaran Sama",
}

m["sln"] = {
	canonicalName = "Salinan",
}

m["slp"] = {
	canonicalName = "Lamaholot",
	otherNames = {"Solor", "Solorese"},
	scripts = {"Latn"},
}

m["slq"] = {
	canonicalName = "Salchuq",
}

m["slr"] = {
	canonicalName = "Salar",
	scripts = {"Arab"},
	family = "trk",
}

m["sls"] = {
	canonicalName = "Singapore Sign Language",
	family = "sgn",
}

m["slt"] = {
	canonicalName = "Sila",
	family = "tbq-lol",
}

m["slu"] = {
	canonicalName = "Selaru",
}

m["slw"] = {
	canonicalName = "Sialum",
}

m["slx"] = {
	canonicalName = "Salampasu",
}

m["sly"] = {
	canonicalName = "Selayar",
}

m["slz"] = {
	canonicalName = "Ma'ya",
	family = "poz-hce",
}

m["sma"] = {
	canonicalName = "Southern Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["smb"] = {
	canonicalName = "Simbari",
}

m["smc"] = {
	canonicalName = "Som",
	family = "ngf-fin",
}

m["smd"] = {
	canonicalName = "Sama",
}

m["smf"] = {
	canonicalName = "Auwe",
}

m["smg"] = {
	canonicalName = "Simbali",
}

m["smh"] = {
	canonicalName = "Samei",
	family = "tbq-lol",
}

m["smj"] = {
	canonicalName = "Lule Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["smk"] = {
	canonicalName = "Bolinao",
	otherNames = {"Binubolinao"},
}

m["sml"] = {
	canonicalName = "Central Sama",
}

m["smm"] = {
	canonicalName = "Musasa",
}

m["smn"] = {
	canonicalName = "Inari Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["smp"] = {
	canonicalName = "Samaritan Hebrew",
	otherNames = {"Samaritan"},
	scripts = {"Samr"},
	family = "sem-can",
}

m["smq"] = {
	canonicalName = "Samo",
}

m["smr"] = {
	canonicalName = "Simeulue",
	otherNames = {"Simalur", "Devayan", "Defayan", "Simolol", "Simulul", "Simeuloë"},
	scripts = {"Latn"},
	family = "poz-nws",
}

m["sms"] = {
	canonicalName = "Skolt Sami",
	scripts = {"Latn"},
	family = "smi",
}

m["smt"] = {
	canonicalName = "Simte",
	family = "tbq-kuk",
}

m["smu"] = {
	canonicalName = "Somray",
}

m["smv"] = {
	canonicalName = "Samvedi",
}

m["smw"] = {
	canonicalName = "Sumbawa",
	scripts = {"Latn"},
	family = "poz-msa",
}

m["smx"] = {
	canonicalName = "Samba",
}

m["smy"] = {
	canonicalName = "Semnani",
	family = "ira",
}

m["smz"] = {
	canonicalName = "Simeku",
}

m["snb"] = {
	canonicalName = "Sebuyau",
}

m["snc"] = {
	canonicalName = "Sinaugoro",
	family = "poz-ocw",
}

m["sne"] = {
	canonicalName = "Bau Bidayuh",
	scripts = {"Latn"},
	family = "day",
}

m["snf"] = {
	canonicalName = "Noon",
	family = "alv-sng",
}

m["sng"] = {
	canonicalName = "Sanga (Congo)",
	otherNames = {"Sanga", "Luba-Sanga", "Sanga (Democratic Republic of Congo)", "Sanga (Democratic Republic of the Congo)"},
	scripts = {"Latn"},
	family = "bnt",
}

m["snh"] = {
	canonicalName = "Shinabo",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["sni"] = {
	canonicalName = "Sensi",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["snj"] = {
	canonicalName = "Riverain Sango",
}

m["snk"] = {
	canonicalName = "Soninke",
	scripts = {"Latn"},
	family = "dmn",
}

m["snl"] = {
	canonicalName = "Sangil",
}

m["snm"] = {
	canonicalName = "Southern Ma'di",
}

m["snn"] = {
	canonicalName = "Siona",
	scripts = {"Latn"},
	family = "sai-tuc",
}

m["sno"] = {
	canonicalName = "Snohomish",
}

m["snp"] = {
	canonicalName = "Siane",
}

m["snq"] = {
	canonicalName = "Chango",
	otherNames = {"Sangu"},
}

m["snr"] = {
	canonicalName = "Sihan",
}

m["sns"] = {
	canonicalName = "Nahavaq",
	family = "poz-vnc",
}

m["snu"] = {
	canonicalName = "Senggi",
}

m["snv"] = {
	canonicalName = "Sa'ban",
	scripts = {"Latn"},
	family = "poz-swa",
}

m["snw"] = {
	canonicalName = "Selee",
}

m["snx"] = {
	canonicalName = "Sam",
}

m["sny"] = {
	canonicalName = "Saniyo-Hiyewe",
}

m["snz"] = {
	canonicalName = "Sinsauru",
}

m["soa"] = {
	canonicalName = "Thai Song",
}

m["sob"] = {
	canonicalName = "Sobei",
	family = "poz-ocw",
}

m["soc"] = {
	canonicalName = "Soko",
	otherNames = {"So"},
	scripts = {"Latn"},
	family = "nic-bod",
}

m["sod"] = {
	canonicalName = "Songoora",
}

m["soe"] = {
	canonicalName = "Songomeno",
}

m["sog"] = {
	canonicalName = "Sogdian",
	scripts = {"Zzzz", "Mani", "Syrc"}, -- Sogdian alphabet not in Unicode yet
	family = "ira",
}

m["soh"] = {
	canonicalName = "Aka (Sudan)",
	otherNames = {"Aka", "Sillok"},
	scripts = {"Latn"},
	family = "sdv",
}

m["soi"] = {
	canonicalName = "Sonha",
}

m["soj"] = {
	canonicalName = "Soi",
	family = "ira",
}

m["sok"] = {
	canonicalName = "Sokoro",
}

m["sol"] = {
	canonicalName = "Solos",
	family = "poz-ocw",
}

m["soo"] = {
	canonicalName = "Songo",
}

m["sop"] = {
	canonicalName = "Songe",
}

m["soq"] = {
	canonicalName = "Kanasi",
}

m["sor"] = {
	canonicalName = "Somrai",
}

m["sos"] = {
	canonicalName = "Seenku",
	otherNames = {"Seeku", "Sembla", "Sambla"},
}

m["sou"] = {
	canonicalName = "Southern Thai",
}

m["sov"] = {
	canonicalName = "Sonsorolese",
	scripts = {"Latn"},
	family = "poz-mic",
}

m["sow"] = {
	canonicalName = "Sowanda",
}

m["sox"] = {
	canonicalName = "Swo",
	otherNames = {"So", "Sso", "Shwo", "Fo"},
	scripts = {"Latn"},
	family = "bnt",
}

m["soy"] = {
	canonicalName = "Miyobe",
}

m["soz"] = {
	canonicalName = "Temi",
}

m["spb"] = {
	canonicalName = "Sepa (Indonesia)",
	otherNames = {"Sepa"},
	scripts = {"Latn"},
	family = "poz",
}

m["spc"] = {
	canonicalName = "Sapé",
}

m["spd"] = {
	canonicalName = "Saep",
}

m["spe"] = {
	canonicalName = "Sepa (New Guinea)",
	otherNames = {"Sepa", "Sepa (Papua New Guinea)"},
	scripts = {"Latn"},
	family = "poz-ocw",
}

m["spg"] = {
	canonicalName = "Sian",
}

m["spi"] = {
	canonicalName = "Saponi",
}

m["spk"] = {
	canonicalName = "Sengo",
}

m["spl"] = {
	canonicalName = "Selepet",
}

m["spm"] = {
	canonicalName = "Sepen",
	family = "paa",
}

m["spn"] = {
	canonicalName = "Sanapaná",
}

m["spo"] = {
	canonicalName = "Spokane",
	otherNames = {"Montana Salish", "Salish", "Séliš", "Kalispel–Pend d'oreille", "Kalispel"},
	family = "sal",
}

m["spp"] = {
	canonicalName = "Supyire",
	otherNames = {"Suppire", "Supyire Senoufo", "Supyire Senufo", "Shempire Senoufo", "Shempire"},
	scripts = {"Latn"},
	family = "alv",
}

m["spr"] = {
	canonicalName = "Saparua",
}

m["sps"] = {
	canonicalName = "Saposa",
	family = "poz-ocw",
}

m["spt"] = {
	canonicalName = "Spiti Bhoti",
}

m["spu"] = {
	canonicalName = "Sapuan",
	family = "aav-ban",
}

m["spx"] = {
	canonicalName = "South Picene",
	otherNames = {"Old Sabellic", "Old Sabellian", "Middle Adriatic", "Central Adriatic"},
	scripts = {"Ital", "Latn"},
	family = "itc",
	translit_module = "Ital-translit",
}

m["spy"] = {
	canonicalName = "Sabaot",
	family = "sdv",
}

m["sqa"] = {
	canonicalName = "Shama-Sambuga",
}

m["sqh"] = {
	canonicalName = "Shau",
}

m["sqk"] = {
	canonicalName = "Albanian Sign Language",
	family = "sgn",
}

m["sqm"] = {
	canonicalName = "Suma",
}

m["sqn"] = {
	canonicalName = "Susquehannock",
	family = "iro",
}

m["sqo"] = {
	canonicalName = "Sorkhei",
	family = "ira",
}

m["sqq"] = {
	canonicalName = "Sou",
}

m["sqr"] = {
	canonicalName = "Siculo-Arabic",
	family = "sem-arb",
}

m["sqs"] = {
	canonicalName = "Sri Lankan Sign Language",
	family = "sgn",
}

m["sqt"] = {
	canonicalName = "Soqotri",
	otherNames = {"Socotri"},
	family = "sem-sar",
}

m["squ"] = {
	canonicalName = "Squamish",
}

m["sra"] = {
	canonicalName = "Saruga",
}

m["srb"] = {
	canonicalName = "Sora",
	scripts = {"Sora"},
	family = "mun",
}

m["sre"] = {
	canonicalName = "Sara",
}

m["srf"] = {
	canonicalName = "Nafi",
	family = "poz-ocw",
}

m["srg"] = {
	canonicalName = "Sulod",
}

m["srh"] = {
	canonicalName = "Sarikoli",
	family = "ira",
}

m["sri"] = {
	canonicalName = "Siriano",
	scripts = {"Latn"},
	family = "sai-tuc",
}

m["srk"] = {
	canonicalName = "Serudung Murut",
}

m["srl"] = {
	canonicalName = "Isirawa",
}

m["srm"] = {
	canonicalName = "Saramaccan",
	scripts = {"Latn"},
	family = "crp",
}

m["srn"] = {
	canonicalName = "Sranan Tongo",
	scripts = {"Latn"},
	family = "crp",
}

m["srq"] = {
	canonicalName = "Sirionó",
	scripts = {"Latn"},
	family = "tup",
}

m["srr"] = {
	canonicalName = "Serer",
	family = "alv-sng",
}

m["srs"] = {
	canonicalName = "Sarcee",
	otherNames = {"Sarsi", "Tsuu T'ina", "Tsuut'ina", "Tsu T'ina"},
	scripts = {"Latn"},
	family = "ath-nor",
}

m["srt"] = {
	canonicalName = "Sauri",
}

m["sru"] = {
	canonicalName = "Suruí",
}

m["srv"] = {
	canonicalName = "Waray Sorsogon",
}

m["srw"] = {
	canonicalName = "Serua",
}

m["srx"] = {
	canonicalName = "Sirmauri",
}

m["sry"] = {
	canonicalName = "Sera",
	family = "poz-ocw",
}

m["srz"] = {
	canonicalName = "Shahmirzadi",
	scripts = {"fa-Arab"},
	family = "ira",
}

m["ssb"] = {
	canonicalName = "Southern Sama",
	scripts = {"Latn"},
	family = "poz-sbj",
}

m["ssc"] = {
	canonicalName = "Suba-Simbiti",
}

m["ssd"] = {
	canonicalName = "Siroi",
}

m["sse"] = {
	canonicalName = "Balangingi",
}

m["ssf"] = {
	canonicalName = "Thao",
	otherNames = {"Sao"},
	scripts = {"Latn"},
	family = "map",
}

m["ssg"] = {
	canonicalName = "Seimat",
	family = "poz-aay",
}

m["ssh"] = {
	canonicalName = "Shihhi Arabic",
	scripts = {"Arab"},
	family = "sem-arb",
	entry_name = {
		from = {u(0x0671), u(0x064B), u(0x064C), u(0x064D), u(0x064E), u(0x064F), u(0x0650), u(0x0651), u(0x0652), u(0x0670), u(0x0640)},
		to   = {u(0x0627)}},
}

m["ssi"] = {
	canonicalName = "Sansi",
	otherNames = {"Bhilki"},
	family = "inc",
	ancestors = {"psu"},
}

m["ssj"] = {
	canonicalName = "Sausi",
}

m["ssk"] = {
	canonicalName = "Sunam",
}

m["ssl"] = {
	canonicalName = "Western Sisaala",
}

m["ssm"] = {
	canonicalName = "Semnam",
}

m["ssn"] = {
	canonicalName = "Waata",
	family = "cus",
}

m["sso"] = {
	canonicalName = "Sissano",
	family = "poz-ocw",
}

m["ssp"] = {
	canonicalName = "Spanish Sign Language",
	family = "sgn",
}

m["ssq"] = {
	canonicalName = "So'a",
	scripts = {"Latn"},
	family = "plf",
}

m["ssr"] = {
	canonicalName = "Swiss-French Sign Language",
	otherNames = {"Swiss French Sign Language"},
	family = "sgn",
}

m["sss"] = {
	canonicalName = "Sô",
	family = "mkh",
}

m["sst"] = {
	canonicalName = "Sinasina",
}

m["ssu"] = {
	canonicalName = "Susuami",
}

m["ssv"] = {
	canonicalName = "Shark Bay",
	family = "poz-vnc",
}

m["ssx"] = {
	canonicalName = "Samberigi",
}

m["ssy"] = {
	canonicalName = "Saho",
	family = "cus",
}

m["ssz"] = {
	canonicalName = "Sengseng",
	family = "poz-ocw",
}

m["stb"] = {
	canonicalName = "Northern Subanen",
}

m["std"] = {
	canonicalName = "Sentinelese",
	scripts = {"Zyyy"},
}

m["ste"] = {
	canonicalName = "Liana-Seti",
}

m["stf"] = {
	canonicalName = "Seta",
	family = "qfa-tor",
}

m["stg"] = {
	canonicalName = "Trieng",
}

m["sth"] = {
	canonicalName = "Shelta",
	otherNames = {"Cant"},
	scripts = {"Latn"},
	family = "crp",
	ancestors = {"en"},
}

m["sti"] = {
	canonicalName = "Bulo Stieng",
}

m["stj"] = {
	canonicalName = "Matya Samo",
}

m["stk"] = {
	canonicalName = "Arammba",
}

m["stm"] = {
	canonicalName = "Setaman",
}

m["stn"] = {
	canonicalName = "Owa",
	scripts = {"Latn"},
	family = "poz-sls",
}

m["sto"] = {
	canonicalName = "Stoney",
	family = "sio",
}

m["stp"] = {
	canonicalName = "Southeastern Tepehuan",
	scripts = {"Latn"},
	family = "azc",
}

m["stq"] = {
	canonicalName = "Saterland Frisian",
	otherNames = {"East Frisian", "Eastern Frisian"}, -- Saterland F is a dialect of East F; see [[WT:T:ASTQ]]
	scripts = {"Latn"},
	family = "gmw-fri",
}

m["str"] = {
	canonicalName = "Saanich",
	scripts = {"Latn"},
	family = "sal",
}

m["sts"] = {
	canonicalName = "Shumashti",
}

m["stt"] = {
	canonicalName = "Budeh Stieng",
}

m["stu"] = {
	canonicalName = "Samtao",
	family = "aav",
}

m["stv"] = {
	canonicalName = "Silt'e",
	scripts = {"Ethi"},
	family = "sem-eth",
}

m["stw"] = {
	canonicalName = "Satawalese",
	family = "poz-mic",
}

m["sty"] = {
	canonicalName = "Siberian Tatar",
	scripts = {"Cyrl"},
	family = "trk-kip",
}

m["sua"] = {
	canonicalName = "Sulka",
}

m["sub"] = {
	canonicalName = "Suku",
}

m["suc"] = {
	canonicalName = "Western Subanon",
}

m["sue"] = {
	canonicalName = "Suena",
}

m["sug"] = {
	canonicalName = "Suganga",
}

m["sui"] = {
	canonicalName = "Suki",
}

m["suk"] = {
	canonicalName = "Sukuma",
	scripts = {"Latn"},
	family = "bnt",
}

m["suq"] = {
	canonicalName = "Suri",
	family = "sdv",
}

m["sur"] = {
	canonicalName = "Mwaghavul",
	otherNames = {"Sura", "Mupun"},
	scripts = {"Latn"},
	family = "cdc",
}

m["sus"] = {
	canonicalName = "Susu",
}

m["sut"] = {
	canonicalName = "Subtiaba",
}

m["suv"] = {
	canonicalName = "Sulung",
}

m["suw"] = {
	canonicalName = "Sumbwa",
}

m["sux"] = {
	canonicalName = "Sumerian",
	scripts = {"Xsux"},
	family = "qfa-iso",
}

m["suy"] = {
	canonicalName = "Suyá",
}

m["suz"] = {
	canonicalName = "Sunwar",
}

m["sva"] = {
	canonicalName = "Svan",
	scripts = {"Geor", "Cyrl"},
	family = "ccs",
	translit_module = "sva-translit",
	entry_name = {
		from = {DIAER, MACRON},
		to   = {}} ,
}

m["svb"] = {
	canonicalName = "Ulau-Suain",
	family = "poz-ocw",
}

m["svc"] = {
	canonicalName = "Vincentian Creole English",
}

m["sve"] = {
	canonicalName = "Serili",
}

m["svk"] = {
	canonicalName = "Slovakian Sign Language",
	family = "sgn",
}

m["svm"] = {
	canonicalName = "Molise Croatian",
	otherNames = {"Slavo-molisano", "Slavomolisano", "Molise Slavic"},
	scripts = {"Latn"},
	family = "zls",
	ancestors = {"sh"},
}

m["svs"] = {
	canonicalName = "Savosavo",
}

m["svx"] = {
	canonicalName = "Skalvian",
	family = "bat",
}

m["swb"] = {
	canonicalName = "Maore Comorian",
	scripts = {"Latn"},
	family = "bnt",
}

m["swf"] = {
	canonicalName = "Sere",
}

m["swg"] = {
	canonicalName = "Swabian",
	scripts = {"Latn"},
	family = "gmw",
	ancestors = {"gsw"},
}

m["swi"] = {
	canonicalName = "Sui",
}

m["swj"] = {
	canonicalName = "Sira",
}

m["swk"] = {
	canonicalName = "Malawi Sena",
}

m["swl"] = {
	canonicalName = "Swedish Sign Language",
	family = "sgn",
}

m["swm"] = {
	canonicalName = "Samosa",
}

m["swn"] = {
	canonicalName = "Sokna",
	otherNames = {"Sawknah", "Fezzan", "Fogaha"},
	family = "ber",
}

m["swo"] = {
	canonicalName = "Shanenawa",
	scripts = {"Latn"},
	family = "sai-pan",
}

m["swp"] = {
	canonicalName = "Suau",
}

m["swq"] = {
	canonicalName = "Sharwa",
}

m["swr"] = {
	canonicalName = "Saweru",
}

m["sws"] = {
	canonicalName = "Seluwasan",
}

m["swt"] = {
	canonicalName = "Sawila",
}

m["swu"] = {
	canonicalName = "Suwawa",
}

m["sww"] = {
	canonicalName = "Sowa",
	family = "poz-vnc",
}

m["swx"] = {
	canonicalName = "Suruahá",
	otherNames = {"Zuruahá", "Suruaha", "Suruwaha", "Zuruaha", "Índios do Coxodoá"},
	family = "auf",
}

m["swy"] = {
	canonicalName = "Sarua",
}

m["sxb"] = {
	canonicalName = "Suba",
}

m["sxc"] = {
	canonicalName = "Sicanian",
}

m["sxe"] = {
	canonicalName = "Sighu",
}

m["sxg"] = {
	canonicalName = "Shixing",
}

m["sxk"] = {
	canonicalName = "Southern Kalapuya",
}

m["sxl"] = {
	canonicalName = "Selonian",
	otherNames = {"Selian"},
	family = "bat",
}

m["sxm"] = {
	canonicalName = "Samre",
	family = "aav",
}

m["sxn"] = {
	canonicalName = "Sangir",
	scripts = {"Latn"},
	family = "phi",
}

m["sxo"] = {
	canonicalName = "Sorothaptic", -- possibly ine, but this language is an odd duck
}

m["sxr"] = {
	canonicalName = "Saaroa",
	scripts = {"Latn"},
	family = "map",
}

m["sxs"] = {
	canonicalName = "Sasaru",
	scripts = {"Latn"},
	family = "alv-edo",
}

m["sxu"] = {
	canonicalName = "Upper Saxon",
	scripts = {"Latn"},
	ancestors = {"gmh"},
	family = "gmw",
}

m["sxw"] = {
	canonicalName = "Saxwe Gbe",
}

m["sya"] = {
	canonicalName = "Siang",
}

m["syb"] = {
	canonicalName = "Central Subanen",
}

m["syc"] = {
	canonicalName = "Classical Syriac",
	scripts = {"Syrc"},
	family = "sem-ara",
	entry_name = {
		from = {"[" .. u(0x0304) .. u(0x0308) .. u(0x0331) .. u(0x0730) .. "-" .. u(0x0748) .. "]"},
		to   = {},
	},
}

m["syi"] = {
	canonicalName = "Seki",
}

m["syk"] = {
	canonicalName = "Sukur",
	family = "cdc",
}

m["syl"] = {
	canonicalName = "Sylheti",
	scripts = {"Sylo", "Beng"},
	family = "inc",
	ancestors = {"pka"},
}

m["sym"] = {
	canonicalName = "Maya Samo",
}

m["syn"] = {
	canonicalName = "Senaya",
}

m["syo"] = {
	canonicalName = "Suoy",
}

m["syr"] = {
	canonicalName = "Syriac",
	scripts = {"Syrc"},
	family = "sem-ara",
	ancestors = {"syc"},
	entry_name = {
		from = {"[" .. u(0x0304) .. u(0x0308) .. u(0x0331) .. u(0x0730) .. "-" .. u(0x0748) .. "]"},
		to   = {},
	},
}

m["sys"] = {
	canonicalName = "Sinyar",
}

m["syw"] = {
	canonicalName = "Kagate",
}

m["syx"] = {
	canonicalName = "Shamay",
	otherNames = {"Osamayi", "Samayi", "Samay", "Shamayi"},
	scripts = {"Latn"},
	family = "bnt",
}

m["syy"] = {
	canonicalName = "Al-Sayyid Bedouin Sign Language",
	family = "sgn",
}

m["sza"] = {
	canonicalName = "Semelai",
}

m["szb"] = {
	canonicalName = "Ngalum",
}

m["szc"] = {
	canonicalName = "Semaq Beri",
	family = "afa",
}

m["szd"] = {
	canonicalName = "Seru",
	family = "poz-bnn",
}

m["sze"] = {
	canonicalName = "Seze",
	family = "omv",
}

m["szg"] = {
	canonicalName = "Sengele",
	family = "bnt",
}

m["szl"] = {
	canonicalName = "Silesian",
	otherNames = {"Upper Silesian", "Silesian Polish", "Upper Silesian Polish"},
	scripts = {"Latn"},
	family = "zlw",
}

m["szn"] = {
	canonicalName = "Sula",
	family = "plf",
}

m["szp"] = {
	canonicalName = "Suabo",
	otherNames = {"Inanwatan"},
	scripts = {"Latn"},
	family = "ngf-sbh",
}

m["szv"] = {
	canonicalName = "Isubu",
	otherNames = {"Isu", "Isu (Fako Division)", "Isuwu", "Suwu", "Subu"},
	scripts = {"Latn"},
	family = "bnt",
}

m["szw"] = {
	canonicalName = "Sawai",
	family = "poz-hce",
}

return m