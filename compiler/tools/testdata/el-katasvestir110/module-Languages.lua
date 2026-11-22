--[=[
Κατάλογος γλωσσών και γλωσσών ετυμολογίας
List of language codes with their corresponding names in Greek.
Αναλυτικά, οδηγίες συμπλήρωσης στο: Βικιλεξικό:Οδηγός ονομασίας γλωσσών
	name = ουδέτερο πληθυντικός. cat=όπως στην Κατηγορία. link= τίτλος ενότητας.
	from = προέλευσης... frm = θηλυκό ενικός. words = θηλυκό πληθυντικός με κεφαλαίο 'λέξεις'.
	apo = θηλυκό ενικός άρθρο + γλώσσα. apota= από + άρθρο (τα, την , τη) + γλώσσα. wiki=άρθρο ΒΠαίδειας (ελληνικό).
	wikiExists: αν υπάρχει wiktionary αυτής της γλώσσας
	(subordinate / sublang) Οι υπαγόμενες γλώσσες ή διάλεκτοι έχουν επιπλέον sublang=true και host, host_name, host_key, apot_key
	key: για όλες τις ελληνικές γλώσσες, αστερίσκος. Για άλλες ομάδες γλώσσες+sublangs, σύμβολο + (όπως για τις λατινικές γλώσσες) 
		Διεθνή και διαγλωσσικά, διπλό "  apot_key, μονό  '
Συνοπτικά:
Το γενικό όνομα για τις γλώσσες είναι το ΟΥΔΕΤΕΡΟ ΠΛΗΘΥΝΤΙΚΟ  (π.χ. [[νέα ελληνικά]], [[αγγλικά]])
	Εξαιρέσεις: σε θηλυκό είναι: 
			[[ελληνιστική κοινή]]
			''Μέση ...ή'' (αποφεύγεται η κακόηχη έκφραση Μέσα αγγλικά κ.λπ.)
			οι πρωτο-... γλώσσες ([[πρωτοϊνδοευρωπαϊκή]])
			οι προ-... γλώσσες (όπως pregrc προελληνική)
			γλώσσα ΧΧ (όπως km γλώσσα χμερ)
	ΟΙΚΟΓΕΝΕΙΕΣ: family=true για 'τάδε γλώσσες'. π.χ. ine (ινδοευρωπαϊκές γλώσσες), bnt (γλώσσες μπαντού), sem (σημιτικές γλώσσες)
	πρωτο...ή (θηλυκό, όχι ουδέτερο) για reconstructed γλώσσες π.χ. gem-pro
	παλαιά ... 	με 2 λέξεις: π.χ. fro / με 3 λέξεις: π.χ. goh
	μέση...	με 2 λέξεις: π.χ. enm /	με 3 λέξεις: π.χ. gmh
Για θυγατρικές γλώσσες, φιλοξενούμενες σε υπερκείμενη γλώσσα, π.χ. en-us,  προσθέτουμε
	-- for Category with auto cat
	sublang=true, host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*κυπριακα", apota_key="'κυπριακα",
	-- status = 'main' Γλώσσας με γραμματικές κατηγορίες έχουν MONO οι γλώσσες, βάσει απόφασης απόφασης (βλ. τεκμηρίωση)
	-- regional=true (όπως [[:Κατηγορία:Ποντιακά]]) ή regional=false ([[:Κατηγορία:Καθαρεύουσα]]) ή τίποτα [[:Κατηγορία:Νέα ελληνικά)]]
	-- grc-koi, el-cyp (ξένες aat, acy)
	-- More subordinate languages should be added (e.g. at Norwegian, Chinese etc)
PROBLEMS: [[:Κατηγορία:Προέλευση λέξεων από τουρκικές γλώσσες (νέα ελληνικά)]] at  [[Module:auto cat]]
]=]--

local Languages = {}
-- SCRIPTS TEST add scripts Arab  Latn, Grek Cyrl (to move them at a module:scripts and update module ετυμολογία)  test at  [[Todorov]]
Languages['Cyrl'] = { iso='Cyrl', name='κυριλλική γραφή', cat='', link='',
                   from='κυριλλική γραφή', frm='κυριλλική γραφή', words='κυριλλική γραφή',
                   apo='κυριλλική γραφή', apota='από κυριλλική γραφή', wiki='', wikiExists=false, key='"', script=true}
Languages['Latn'] = { iso='Latn', name='λατινική γραφή', cat='', link='',
                   from='λατινική γραφή', frm='λατινική γραφή', words='λατινική γραφή',
                   apo='λατινική γραφή', apota='από λατινική γραφή', wiki='', wikiExists=false, key='"', script=true }
                   

----------------------------------------
-- universal (διεθνείς όροι - international)
Languages['uni'] = { iso='uni', name='διεθνείς όροι', cat='Διεθνείς όροι', link='Διεθνείς όροι',
                   from='προέλευσης από διεθνείς όρους', frm='διεθνής ορολογία', words='Διεθνείς όροι',
                   apo='διεθνείς όρους', apota='από διεθνείς όρους', wiki='', wikiExists=false, key='"' }
                   -- not real iso
-- translingual
Languages['mul'] = { iso='mul', name='διαγλωσσικοί όροι', cat='Διαγλωσσικοί όροι', link='Διαγλωσσικοί όροι',
                   from='προέλευσης από διαγλωσσικούς όρους', frm='διαγλωσσική ορολογία', words='Διαγλωσσικοί όροι',
                   apo='διαγλωσσικούς όρους', apota='από διαγλωσσικούς όρους', wiki='', wikiExists=false, key='"' }
                   -- not real iso
-- πολλαπλές και άγνωστο ποιες ακριβώς γλώσσες. Π.χ. [[Αρίφ]] 
-- mutliple unknown languages at etymologies of transliterations of proper nouns
Languages['-'] = { iso='-', name='διάφορες γλώσσες', cat='Διάφορες γλώσσες', link='',
                   from='προέλευσης από διάφορες γλώσσες', frm='διάφορες γλώσσες', words='Λέξεις από διάφορες γλώσσες',
                   apo='διάφορες γλώσσες', apota='από διάφορες γλώσσες', wiki='', wikiExists=false, key='"', family=true }
                   -- not real iso  -- family=true gives only Ετυμολογικές κατηγορίες.  
-- a ... z ===============================
Languages['aa'] = { iso='aa', name='αφαρικά', cat='Αφαρική γλώσσα', link='Αφαρικά (aa)',
                   from='αφαρικής προέλευσης', frm='αφαρική', words='Αφαρικές λέξεις',
                   apo='την αφαρική', apota='από τα αφαρικά', wiki='en:Afar language', wikiExists=false, key='αφαρικα' }
Languages['aaa'] = { iso='aaa', name='Ghotuo', cat='Γλώσσα Ghotuo', link='Ghotuo (aaa)',
                   from='προέλευσης από τη γλώσσα Ghotuo', frm='Ghotuo', words='Λέξεις της γλώσσας Ghotuo',
                   apo='τη γλώσσα Ghoto', apota='από τη γλώσσα Ghotuo', wiki='Γκοτούο', wikiExists=false, key='γκοτο' }
Languages['aat'] = { iso='aat', name='αρβανίτικα', cat='Αρβανίτικα', link='Αρβανίτικα (aat)',
	from='αρβανίτικης προέλευσης', frm='αρβανίτικη', words='Αρβανίτικες λέξεις',
	apo='την αρβανίτικη', apota='από τα αρβανίτικα', wiki='Αρβανίτικα', wikiExists=false, key="αρβανιτικα",
	-- for Category with auto cat
	sublang=true, regional=true, host='Αλβανική γλώσσα', host_show='Αλβανικά', host_name='αλβανικά', host_apota='από τα αλβανικά', 
	host_iso='sq', host_key="+αρβανιτικα", apota_key="'αρβανιτικα" }
Languages['ab'] = { iso='ab', name='αμπχαζικά', cat='Αμπχαζική γλώσσα', link='Αμπχαζικά (ab)',
                   from='αμπχαζικής προέλευσης', frm='αμπχαζική', words='Αμπχαζικές λέξεις',
                   apo='την αμπχαζική', apota='από τα αμπχαζικά', wiki='Αμπχαζική γλώσσα', wikiExists=false, key='αμπχαζικα' }
-- status main ? why?
Languages['acy'] = { iso='acy', name='κυπριακά αραβικά', cat='Κυπριακά αραβικά', link='Κυπριακά αραβικά (acy)',
	from='κυπριακής αραβικής προέλευσης', frm='κυπριακή αραβική', words='Κυπριακές αραβικές λέξεις',
	apo='την κυπριακή αραβική', apota='από τα κυπριακά αραβικά', wiki='Αραβικά της Κύπρου', wikiExists=true, key="κυπριακααραβικα",
	-- these keys handle the Category as in auto cat
	sublang=true, regional=true, status = 'main', host='Αραβική γλώσσα', host_show='Αραβικά', host_name='αραβικά', host_apota='από τα αραβικά', 
	host_iso='ar', host_key="+κυπριακααραβικα", apota_key="'αραβικα",}
	-- check [[xallum]] Script=Latn
Languages['ae'] = { iso='ae', name='αβεστικά', cat='Αβεστική γλώσσα', link='Αβεστικά (ae)',
                   from='αβεστικής προέλευσης', frm='αβεστική', words='Αβεστικές λέξεις',
                   apo='την αβεστική', apota='από τα αβεστικά', wiki='Αβεστική γλώσσα', wikiExists=false, key='αβεστικα' }
					-- Avestan ή Zend (ζενδική γλώσσα), πρόδρομος της peo
Languages['ady'] = { iso='ady', name='δυτικά κιρκασιανά', cat='Δυτική κιρκασιανή γλώσσα', link='Δυτικά κιρκασιανά (ady)',
                   from='προέλευσης από τη δυτική κιρκασιανή', frm='δυτική κιρκασιανή', words='Δυτικές κιρκασιανές λέξεις',
                   apo='τη δυτική κιρκασιανή', apota='από τα δυτικά κιρκασιανά', wiki='Καμπαρντιανή γλώσσα', wikiExists=false, key='δυτικακιρκασιανα' }
                   -- = γλώσσα Adyghe. Δε βρέθηκε λέξη αντιγκεϊκά, Συζήτηση στα [[Βικιλεξικό:Ζητούμενα_λήμματα/2021#αντιγκεϊκά_->_[αντιγκεγιακά]|Ζητούμενα, 2021]]
Languages['af'] = { iso='af', name='αφρικάανς', cat='Γλώσσα αφρικάανς', link='Αφρικάανς (af)',
                   from='προέλευσης από τη γλώσσα αφρικάανς', frm='αφρικάανς', words='Λέξεις της γλώσσας αφρικάανς',
                   apo='τη γλώσσα αφρικάανς', apota='από τη γλώσσα αφρικάανς', wiki='Αφρικάανς γλώσσα', wikiExists=true, key='αφρικαανσ' }
Languages['ak'] = { iso='ak', name='ακάν', cat='Γλώσσα ακάν', link='Ακάν (ak)',
                   from='προέλευσης από τη γλώσσα ακάν', frm='ακάν', words='Λέξεις της γλώσσας ακάν',
                   apo='τη γλώσσα ακάν', apota='από τη γλώσσα ακάν', wiki='', wikiExists=false, key='ακαν' }
                   -- γλώσσα της Γκάνα
Languages['akz'] = { iso='akz', name='αλαμπάμα', cat='Γλώσσα αλαμπάμα', link='Αλαμπάμα (akz)',
                   from='προέλευσης από τη γλώσσα αλαμπάμα', frm='αλαμπάμα', words='Λέξεις της γλώσσας αλαμπάμα',
                   apo='τη γλώσσα αλαμπάμα', apota='από τη γλώσσα αλαμπάμα', wiki='en:Alabama language', wikiExists=false, key='αλαμπαμα' }
Languages['akk'] = { iso='akk', name='ακκαδικά', cat='Ακκαδική γλώσσα', link='Ακκαδικά (akk)',
                   from='ακκαδικής προέλευσης', frm='ακκαδική', words='Ακκαδικές λέξεις',
                   apo='την ακκαδική', apota='από τα ακκαδικά', wiki='Ακκαδική γλώσσα', wikiExists=false, key='ακκαδικα' }
Languages['alq'] = { iso='alq', name='αλγκονκίν', cat='Γλώσσα αλγκονκίν', link='Αλγκονκίν (alq)',
                   from='προέλευσης από τη γλώσσα αλγκονκίν', frm='αλγκονκίν', words='Λέξεις της γλώσσας αλγκονκίν',
                   apo='τη γλώσσα αλγκονκίν', apota='από τη γλώσσα αλγκονκίν', wiki='', wikiExists=false, key='αλγκονκιν' }
Languages['am'] = { iso='am', name='αμχαρικά', cat='Αμχαρική γλώσσα', link='Αμχαρικά (am)',
                   from='αμχαρικής προέλευσης', frm='αμχαρική', words='Αμχαρικές λέξεις',
                   apo='την αμχαρική', apota='από τα αμχαρικά', wiki='Αμχαρική γλώσσα', wikiExists=true, key='αμχαρικα' }
Languages['an'] = { iso='an', name='αραγονικά', cat='Αραγονική γλώσσα', link='Αραγονικά (an)',
                   from='αραγονικής προέλευσης', frm='αραγονική', words='Αραγονικές λέξεις',
                   apo='την αραγονική', apota='από τα αραγονικά', wiki='Αραγονική γλώσσα', wikiExists=true, key='αραγονικα' }

-- #? αυτό πρέπει να αλλάξει σε παλαιά αγγλικά
Languages['ang'] = { iso='ang', name='αγγλοσαξονικά', cat='Αγγλοσαξονική γλώσσα', link='Αγγλοσαξονικά (ang)',
                   from='αγγλοσαξονικής προέλευσης', frm='αγγλοσαξονική', words='Αγγλοσαξονικές λέξεις',
                   apo='την αγγλοσαξονική', apota='από τα αγγλοσαξονικά', wiki='Αρχαία αγγλική γλώσσα', wikiExists=true, key='αγγλοσαξονικα' }
                   -- συνώνυμο: παλαιά αγγλικά (Old English)
Languages['ar'] = { iso='ar', name='αραβικά', cat='Αραβική γλώσσα', link='Αραβικά (ar)', script='Arab',
                   from='αραβικής προέλευσης', frm='αραβική', words='Αραβικές λέξεις',
                   apo='την αραβική', apota='από τα αραβικά', wiki='Αραβική γλώσσα', wikiExists=true, key='αραβικα' }
Languages['arc'] = { iso='arc', name='αραμαϊκά', cat='Αραμαϊκή γλώσσα', link='Αραμαϊκά (arc)',
                   from='αραμαϊκής προέλευσης', frm='αραμαϊκή', words='Αραμαϊκές λέξεις',
                   apo='την αραμαϊκή', apota='από τα αραμαϊκά', wiki='Αραμαϊκή γλώσσα', wikiExists=false, key='αραμαικα' }
Languages['arn'] = { iso='arn', name='Mapudungun', cat='Γλώσσα Mapudungun', link='Mapudungun (arn)',
                   from='προέλευσης από τη γλώσσα Mapudungun', frm='Mapudungun', words='Λέξεις της γλώσσας Mapudungun',
                   apo='τη γλώσσα Mapudungun', apota='από τη γλώσσα Mapudungun', wiki='', wikiExists=false, key='μαπουντουνγκουν' }
Languages['arz'] = { iso='arz', name='αιγυπτιακά αραβικά', cat='Αιγυπτιακά αραβικά', link='Αιγυπτιακά αραβικά (arz)',
                   from='προέλευσης από την αιγυπτιακή αραβική', frm='αιγυπτιακή αραβική', words='Αιγυπτιακές αραβικές λέξεις',
                   apo='την αιγυπτιακή αραβική', apota='από τα αιγυπτιακά αραβικά', wiki='en:Egyptian Arabic', wikiExists=false, key='αιγυπτιακααραβικα' }
-- status main, regional
Languages['arz'] = { iso='arz', name='αιγυπτιακά αραβικά', cat='Αιγυπτιακά αραβικά', link='Αιγυπτιακά αραβικά (arz)',
	from='προέλευσης από την αιγυπτιακή αραβική', frm='αιγυπτιακή αραβική', words='Αιγυπτιακές αραβικές λέξεις',
	apo='την αιγυπτιακή αραβική', apota='από τα αιγυπτιακά αραβικά', wiki='en:Egyptian Arabic', wikiExists=false, key='αιγυπτιακααραβικα',
	-- these keys handle the Category as in auto cat
	sublang=true, regional=true, status = 'main', host='Αραβική γλώσσα', host_show='Αραβικά', host_name='αραβικά', host_apota='από τα αραβικά', 
	host_iso='ar', host_key="+αιγυπτιακααραβικα", apota_key="'αραβικα",}
	-- check [[لأمم المتحدها]] Script=Arab
Languages['as'] = { iso='as', name='ασαμικά', cat='Ασαμική γλώσσα', link='Ασαμικά (as)',
                   from='ασαμικής προέλευσης', frm='ασαμική', words='Ασαμικές λέξεις',
                   apo='την ασαμική', apota='από τα ασαμικά', wiki='Ασσαμέζικη γλώσσα', wikiExists=true, key='ασαμικα' }
Languages['ast'] = { iso='ast', name='αστουριανά', cat='Αστουριανή γλώσσα', link='Αστουριανά (ast)',
                   from='αστουριανής προέλευσης', frm='αστουριανή', words='Αστουριανές λέξεις',
                   apo='την αστουριανή', apota='από τα αστουριανά', wiki='Αστουριανή γλώσσα', wikiExists=true, key='ασουριανα' }
Languages['avk'] = { iso='avk', name='κοτάβα', cat='Γλώσσα κοτάβα', link='Κοτάβα (avk)',
                   from='προέλευσης από τη γλώσσα κοτάβα', frm='κοτάβα', words='Λέξεις της γλώσσας κοτάβα',
                   apo='τη γλώσσα κοτάβα', apota='από τη γλώσσα κοτάβα', wiki='', wikiExists=false, key='κοταβα' }
                   -- τεχνητή γλώσσα (βλ. λήμμα [[beg]])
Languages['axm'] = { iso='axm', name='μέση αρμενική', cat='Μέση αρμενική γλώσσα', link='Μέση αρμενική (axm)',
                   from='προέλευσης από τη μέση αρμενική', frm='μέση αρμενική', words='Λέξεις της μέσης αρμενικής',
                   apo='τη μέση αρμενική', apota='από τη μέση αρμενική', wiki='', wikiExists=false, key='μεσηαρμενικη' }
Languages['ay'] = { iso='ay', name='αϊμάρα', cat='Γλώσσα αϊμάρα', link='Αϊμάρα (ay)',
                   from='προέλευσης από τη γλώσσα αϊμάρα', frm='αϊμάρα', words='Λέξεις της γλώσσας αϊμάρα',
                   apo='τη γλώσσα αϊμάρα', apota='από τη γλώσσα αϊμάρα', wiki='Γλώσσα Αϊμάρα', wikiExists=true, key='αιμαρα' }
Languages['az'] = { iso='az', name='αζεριανά', cat='Αζεριανή γλώσσα', link='Αζεριανά (az)',
                   from='αζεριανής προέλευσης', frm='αζεριανή', words='Αζεριανές λέξεις',
                   apo='την αζεριανή', apota='από τα αζεριανά', wiki='Αζερική γλώσσα', wikiExists=true, key='αζεριανα' }
Languages['ba'] = { iso='ba', name='μπασκίρ', cat='Γλώσσα μπασκίρ', link='Μπασκίρ (ba)',
                   from='προέλευσης από τη γλώσσα μπασκίρ', frm='μπασκίρ', words='Λέξεις της γλώσσας μπασκίρ',
                   apo='τη γλώσσα μπασκίρ', apota='από τη γλώσσα μπασκίρ', wiki='Γλώσσα Μπακσίρ', wikiExists=false, key='μπασκιρ' }
Languages['ban'] = { iso='ban', name='μπαλινέζικα', cat='Μπαλινέζικη γλώσσα', link='Μπαλινέζικα (ban)',
                   from='μπαλινέζικης προέλευσης', frm='μπαλινέζικη', words='Μπαλινέζικες λέξεις',
                   apo='τη μπαλινέζικη', apota='από τα μπαλινέζικα', wiki='Μπαλινέζικη γλώσσα', wikiExists=true, key='μπαλινεζικα' }
Languages['bar'] = { iso='bar', name='βαυαρικά', cat='Βαυαρική γλώσσα', link='Βαυαρικά (bar)',
                   from='βαυαρικής προέλευσης', frm='βαυαρική', words='Βαυαρικές λέξεις',
                   apo='τη βαυαρική', apota='από τα βαυαρικά', wiki='en:Bavarian language', wikiExists=false, key='βαυαραικα' }
Languages['bat-smg'] = { iso='bat-smg', name='σαμογιτιανά', cat='Σαμογιτιανά', link='Σαμογιτιανά (bat-smg)',
                   from='σαμογιτιανής προέλευσης', frm='σαμογιτιανή', words='Σαμογιτιανές λέξεις',
                   apo='τη σαμογιτιανή', apota='από τα σαμογιτιανά', wiki='en:Samogitian dialect', wikiExists=false, key='σαμογιτιανα' }
					-- διάλεκτος
Languages['bcl'] = { iso='bcl', name='φιλιππινέζικα της κεντρικής Μπικόλ', cat='Φιλιππινέζικα της κεντρικής Μπικόλ', link='Φιλιππινέζικα της κεντρικής Μπικόλ (bcl)',
                   from='προέλευσης από τη φιλιππινέζικη της κεντρικής Μπικόλ', frm='φιλιππινέζικη της κεντρικής Μπικόλ', words='Φιλιππινέζικες λέξεις της κεντρικής Μπικόλ',
                   apo='τα φιλιππινέζικα της κεντρικής Μπικόλ', apota='από τα φιλιππινέζικα της κεντρικής Μπικόλ', wiki='', wikiExists=false, key='φιλιππινεζικαμπικολ' }
Languages['be'] = { iso='be', name='λευκορωσικά', cat='Λευκορωσική γλώσσα', link='Λευκορωσικά (be)',
                   from='λευκορωσικής προέλευσης', frm='λευκορωσική', words='Λευκορωσικές λέξεις',
                   apo='τη λευκορωσική', apota='από τα λευκορωσικά', wiki='Λευκορωσική γλώσσα', wikiExists=true, key='λευκορωσικα' }
Languages['bem'] = { iso='bem', name='μπέμπα', cat='Γλώσσα μπέμπα', link='Μπέμπα (bem)',
                   from='προέλευσης από τη γλώσσα μπέμπα', frm='μπέμπα', words='Λέξεις της γλώσσας μπέμπα',
                   apo='τη γλώσσα μπέμπα', apota='από τη γλώσσα μπέμπα', wiki='en:Bemba language', wikiExists=false, key='μπεμπα' }
Languages['bg'] = { iso='bg', name='βουλγαρικά', cat='Βουλγαρική γλώσσα', link='Βουλγαρικά (bg)',
                   from='βουλγαρικής προέλευσης', frm='βουλγαρική', words='Βουλγαρικές λέξεις',
                   apo='τη βουλγαρική', apota='από τα βουλγαρικά', wiki='Βουλγαρική γλώσσα', wikiExists=true, key='βουλγαρικα' }
Languages['bh'] = { iso='bh', name='μπιχάρι', cat='Γλώσσα μπιχάρι', link='Μπιχάρι (bh)',
                   from='προέλευσης από τη γλώσσα μπιχάρι', frm='μπιχάρι', words='Λέξεις της γλώσσας μπιχάρι',
                   apo='τη γλώσσα μπιχάρι', apota='από τη γλώσσα μπιχάρι', wiki='Γλώσσα Μπιχάρι', wikiExists=false, key='μπιχαρι' }
Languages['bi'] = { iso='bi', name='μπισλάμα', cat='Γλώσσα μπισλάμα', link='Μπισλάμα (bi)',
                   from='προέλευσης από τη γλώσσα μπισλάμα', frm='μπισλάμα', words='Λέξεις της γλώσσας μπισλάμα',
                   apo='τη γλώσσα μπισλάμα', apota='από τη γλώσσα μπισλάμα', wiki='Μπισλάμα', wikiExists=false, key='μπισλαμα' }
Languages['bm'] = { iso='bm', name='μπαμπάρα', cat='Γλώσσα μπαμπάρα', link='Μπαμπάρα (bm)',
                   from='προέλευσης από τη γλώσσα μπαμπάρα', frm='μπαμπάρα', words='Λέξεις της γλώσσας μπαμπάρα',
                   apo='τη γλώσσα μπαμπάρα', apota='από τη γλώσσα μπαμπάρα', wiki='', wikiExists=false, key='μπαμπαρα' }
Languages['bn'] = { iso='bn', name='μπενγκάλι', cat='Γλώσσα μπενγκάλι', link='Μπενγκάλι (bn)',
                   from='προέλευσης από τη γλώσσα μπενγκάλι', frm='μπενγκάλι', words='Λέξεις της γλώσσας μπενγκάλι',
                   apo='τη γλώσσα μπενγκάλι', apota='από τη γλώσσα μπενγκάλι', wiki='', wikiExists=true, key='μπενγκαλι' }
Languages['bnt'] = { iso='bnt', name='γλώσσες μπαντού', cat='Γλώσσες μπαντού', link='',
                   from='προέλευσης από γλώσσες μπαντού', frm='μπαντού', words='Λέξεις των γλωσσών μπαντού',
                   apo='τις γλώσσες μπαντού', apota='από γλώσσες μπαντού', wiki='Μπαντού', wikiExists=false, key='μπαντου', family=true }
                   -- bnt οικογένεια γλωσσών Bantu
Languages['bo'] = { iso='bo', name='θιβετιανά', cat='Θιβετιανή γλώσσα', link='Θιβετιανά (bo)',
                   from='θιβετιανής προέλευσης', frm='θιβετιανή', words='Θιβετιανές λέξεις',
                   apo='τη θιβετιανή', apota='από τα θιβετιανά', wiki='en:Standard Tibetan', wikiExists=false, key='θιβετιανα' }
Languages['br'] = { iso='br', name='βρετονικά', cat='Βρετονική γλώσσα', link='Βρετονικά (br)',
                   from='βρετονικής προέλευσης', frm='βρετονική', words='Βρετονικές λέξεις',
                   apo='τη βρετονική', apota='από τα βρετονικά', wiki='Βρετονική γλώσσα', wikiExists=true, key='βρετονικα' }
Languages['bs'] = { iso='bs', name='βοσνιακά', cat='Βοσνιακή γλώσσα', link='Βοσνιακά (bs)',
                   from='βοσνιακής προέλευσης', frm='βοσνιακή', words='Βοσνιακές λέξεις',
                   apo='τη βοσνιακή', apota='από τα βοσνιακά', wiki='Βοσνιακή γλώσσα', wikiExists=true, key='βοσνιακα' }
Languages['byn'] = { iso='byn', name='Blin', cat='Γλώσσα Blin', link='Blin (byn)',
                   from='προέλευσης από τη γλώσσα Blin', frm='Blin', words='Λέξεις της γλώσσας Blin',
                   apo='τη γλώσσα Blin', wiki='', wikiExists=false, key='μπλιν' }
					-- The Bilen language (ብሊና b(ɨ)lina or ብሊን b(ɨ)lin) is spoken by the Bilen people in and around the city of Keren in Eritrea. 
Languages['ca'] = { iso='ca', name='καταλανικά', cat='Καταλανική γλώσσα', link='Καταλανικά (ca)',
                   from='καταλανικής προέλευσης', frm='καταλανική', words='Καταλανικές λέξεις',
                   apo='την καταλανική', apota='από τα καταλανικά', wiki='Καταλανική γλώσσα', wikiExists=true, key='καταλανικα' }
					-- Languages['cal'] Carolinian language, όχι Καλαβρέζικα
Languages['cdo'] = { iso='cdo', name='κινεζική ανατολική μιν', cat='Κινεζική ανατολική μιν', link='Κινεζική ανατολική μιν (cdo)',
                   from='προέλευσης από την κινεζική ανατολική μιν', frm='κινεζική ανατολική μιν', words='Λέξεις της κινεζικής ανατολικής μιν',
                   apo='την κινέζικη ανατολική μιν', apota='από την κινεζική ανατολική μιν', wiki='', wikiExists=false, key='κινεζικαανατολικημιν' }
Languages['ce'] = { iso='ce', name='τσετσενικά', cat='Τσετσενική γλώσσα', link='Τσετσενικά (ce)',
                   from='τσετσενικής προέλευσης', frm='τσετσενική', words='Τσετσενικές λέξεις',
                   apo='την τσετσενική', apota='από τα τσετσενικά', wiki='Τσετσενική γλώσσα', wikiExists=false, key='τσετσενικα' }
Languages['ceb'] = { iso='ceb', name='σεμπουάνο', cat='Γλώσσα σεμπουάνο', link='Σεμπουάνο (ceb)',
                   from='προέλευσης από τη γλώσσα σεμπουάνο', frm='σεμπουάνο', words='Λέξεις της γλώσσας σεμπουάνο',
                   apo='τη γλώσσα σεμπουάνο', apota='από τη γλώσσα σεμπουάνο', wiki='', wikiExists=false, key='σεμπουανο' }
Languages['cel'] = { iso='cel', name='κελτικές γλώσσες', cat='Κελτικές γλώσσες', link='',
                   from='κελτικής προέλευσης', frm='κελτική', words='Κελτικές λέξεις',
                   apo='κελτικές γλώσσες', apota='από κελτικές γλώσσες', wiki='Κελτικές γλώσσες', wikiExists=false, key='κελτικα', family=true }
                   --  cel οικογένεια κελτικών γλωσσών
Languages['cel-gau'] = { iso='cel-gau', name='γαλατικά', cat='Γαλατική γλώσσα', link='Γαλατικά (cel-gau)',
                   from='γαλατικής προέλευσης', frm='γαλατική', words='Γαλατικές λέξεις',
                   apo='τη γαλατική', apota='από τα γαλατικά', wiki='Γαλατική γλώσσα', wikiExists=false, key='γαλατικα' }
Languages['cel-pro'] = { iso='cel-pro', name='πρωτοκελτική', cat='Πρωτοκελτική γλώσσα', link='Πρωτοκελτική γλώσσα (cel-pro)',
                   from='πρωτοκελτικής προέλευσης', frm='πρωτοκελτική', words='Πρωτοκελτικές λέξεις',
                   apo='την πρωτοκελτική', apota='από την πρωτοκελτική', wiki='', wikiExists=false, key='πρωτοκελτικη' }
Languages['ch'] = { iso='ch', name='τσαμόρο', cat='Γλώσσα τσαμόρο', link='Τσαμόρο (ch)',
                   from='προέλευσης από τη γλώσσα τσαμόρο', frm='τσαμόρο', words='Λέξεις της γλώσσας τσαμόρο',
                   apo='τη γλώσσα τσαμόρο', apota='από τη γλώσσα τσαμόρο', wiki='', wikiExists=false, key='τσαμορο' }
Languages['chm'] = { iso='chm', name='ανατολικά μαρί', cat='Γλώσσα ανατολική μαρί', link='Ανατολική μαρί (chm)',
                   from='προέλευσης από την ανατολική μαρί', frm='ανατολική μαρί', words='Λέξεις της ανατολικής μαρί',
                   apo='την ανατολική μαρί', apota='από τα ανατολικά μαρί', wiki='Ανατολική Μάρι γλώσσα', wikiExists=false, key='ανατολικημαρι' }
Languages['chr'] = { iso='chr', name='τσερόκι', cat='Γλώσσα τσερόκι', link='Τσερόκι (chr)',
                   from='προέλευσης από τη γλώσσα τσερόκι', frm='τσερόκι', words='Λέξεις της γλώσσας τσερόκι',
                   apo='τη γλώσσα τσερόκι', apota='από τη γλώσσα τσερόκι', wiki='', wikiExists=true, key='τσεροκι' }
Languages['chy'] = { iso='chy', name='τσεγιέν', cat='Γλώσσα τσεγιέν', link='Τσεγιέν (chy)',
                   from='προέλευσης από τη γλώσσα τσεγιέν', frm='τσεγιέν', words='Λέξεις της γλώσσας τσεγιέν',
                   apo='τη γλώσσα τσεγιέν', apota='από τη γλώσσα τσεγιέν', wiki='', wikiExists=false, key='τσεγιεν' }
Languages['ckb'] = { iso='ckb', name='κουρδικά σοράνι', cat='Κουρδική γλώσσα σοράνι', link='Κουρδικά σοράνι (ckb)',
                   from='προέλευσης από την κουρδική σοράνι', frm='κουρδική σοράνι', words='Λέξεις της γλώσσας κουρδικά σοράνι',
                   apo='την κουρδική σοράνι', apota='από τα κουρδικά σοράνι', wiki='', wikiExists=false, key='κουρικασορανι' }
Languages['cmn'] = { iso='cmn', name='κινεζικά μανδαρίνικα', cat='Κινεζική μανδαρίνικη γλώσσα', link='Κινεζικά μανδαρίνικα (cmn)',
                   from='κινεζικής μανδαρίνικης προέλευσης', frm='κινεζική μανδαρίνικη', words='Κινεζικές μανδαρίνικες λέξεις',
                   apo='την κινεζική μανδαρίνικη', apota='από τα μανδαρίνικα κινεζικά', wiki='Κινεζική γλώσσα', wikiExists=false, key='κινεζικαμανδαρινικα' }
Languages['co'] = { iso='co', name='κορσικανικά', cat='Κορσικανική γλώσσα', link='Κορσικανικά (co)',
                   from='κορσικανικής προέλευσης', frm='κορσικανική', words='Κορσικανικές λέξεις',
                   apo='την κορσικανική', apota='από τα κορσικανικά', wiki='Κορσικανική γλώσσα', wikiExists=true, key='κορσικανικα' }
Languages['cop'] = { iso='cop', name='κοπτικά', cat='Κοπτική γλώσσα', link='Κοπτικά (cop)',
                   from='κοπτικής προέλευσης', frm='κοπτική', words='Κοπτικές λέξεις',
                   apo='την κοπτική', apota='από τα κοπτικά', wiki='Κοπτική γλώσσα', wikiExists=false, key='κοπτικα' }
-- status main, regional
Languages['cpg'] = { iso='cpg', name='καππαδοκικά', cat='Καππαδοκικά', link='Καππαδοκικά (cpg)',
	from='καππαδοκικής προέλευσης', frm='καππαδοκική', words='Καππαδοκικές λέξεις',
	apo='την καππαδοκική', apota='από τα καππαδοκικά', wiki='Καππαδοκική διάλεκτος', wikiExists=false, key='*καππαδοκικα',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*καππαδοκικα", apota_key="'καππαδοκικα" }
Languages['cr'] = { iso='cr', name='κρι', cat='Γλώσσα κρι', link='Κρι (cr)',
                   from='προέλευσης από τη γλώσσα κρι', frm='κρι', words='Λέξεις της γλώσσας κρι',
                   apo='τη γλώσσα κρι', apota='από τη γλώσσα κρι', wiki='', wikiExists=false, key='κρι' }
Languages['crh'] = { iso='crh', name='κριμαϊκά ταταρικά', cat='Κριμαϊκή ταταρική γλώσσα', link='Κριμαϊκά ταταρικά (crh)',
                   from='κριμαϊκής ταταρικής προέλευσης', frm='κριμαϊκή ταταρική', words='Κριμαϊκές ταταρικές λέξεις',
                   apo='την κριμαϊκή ταταρική', apota='από τα κριμαϊκά ταταρικά', wiki='Κριμαϊκή Ταταρική γλώσσα', wikiExists=false, key='κριμαικαταταρικα' }
Languages['cs'] = { iso='cs', name='τσεχικά', cat='Τσεχική γλώσσα', link='Τσεχικά (cs)',
                   from='τσεχικής προέλευσης', frm='τσεχική', words='Τσεχικές λέξεις',
                   apo='την τσεχική', apota='από τα τσεχικά', wiki='Τσεχική γλώσσα', wikiExists=true, key='τσεχικα' }
Languages['csb'] = { iso='csb', name='κασουβικά', cat='Κασουβική γλώσσα', link='Κασουβικά (csb)',
                   from='κασουβικής προέλευσης', frm='κασουβική', words='Κασουβικές λέξεις',
                   apo='την κασουβική', apota='από τα κασουβικά', wiki='Κασουβική γλώσσα', wikiExists=true, key='κασουβικα' }
Languages['cv'] = { iso='cv', name='τσουβασικά', cat='Τσουβασική γλώσσα', link='Τσουβασικά (cv)',
                   from='τσουβασικής προέλευσης', frm='τσουβασική', words='Τσουβασικές λέξεις',
                   apo='την τσουβασική', apota='από τα τσουβασικά', wiki='Τσουβασική γλώσσα', wikiExists=false, key='τσουβασικα' }
Languages['cu'] = { iso='cu', name='παλαιά εκκλησιαστικά σλαβονικά', cat='Παλαιά εκκλησιαστική σλαβονική γλώσσα', link='Παλαιά εκκλησιαστική σλαβονική (cu)',
                   from='προέλευσης από την παλαιά εκκλησιαστική σλαβονική', frm='παλαιά εκκλησιαστική σλαβονική', words='Λέξεις της παλαιάς εκκλησιαστικής σλαβονικής',
                   apo='την παλαιά εκκλησιαστική σλαβονική', apota='από τα παλαιά εκκλησιαστικά σλαβονικά', wiki='Παλαιά εκκλησιαστική σλαβονική γλώσσα', wikiExists=false, key='παλαιαεκκλησιαστικασλαβονικα' }
Languages['cy'] = { iso='cy', name='ουαλικά', cat='Ουαλική γλώσσα', link='Ουαλικά (cy)',
                   from='ουαλικής προέλευσης', frm='ουαλική', words='Ουαλικές λέξεις',
                   apo='την ουαλική', apota='από τα ουαλικά', wiki='Ουαλική γλώσσα', wikiExists=true, key='ουαλικα' }
Languages['da'] = { iso='da', name='δανικά', cat='Δανική γλώσσα', link='Δανικά (da)',
                   from='δανικής προέλευσης', frm='δανική', words='Δανικές λέξεις',
                   apo='τη δανική', apota='από τα δανικά', wiki='Δανική γλώσσα', wikiExists=true, key='δανικα' }
Languages['de'] = { iso='de', name='γερμανικά', cat='Γερμανική γλώσσα', link='Γερμανικά (de)',
                   from='γερμανικής προέλευσης', frm='γερμανική', words='Γερμανικές λέξεις',
                   apo='τη γερμανική', apota='από τα γερμανικά', wiki='Γερμανική γλώσσα', wikiExists=true, key='γερμανικα' }
Languages['diq'] = { iso='diq', name='ζαζάκι', cat='Γλώσσα ζαζάκι', link='Ζαζάκι (diq)',
                   from='προέλευσης από τη γλώσσα ζαζάκι', frm='ζαζάκι', words='Λέξεις της γλώσσας ζαζάκι',
                   apo='τη γλώσσα ζαζάκι', apota='από τη γλώσσα ζαζάκι', wiki='Ζαζαϊκή γλώσσα', wikiExists=false, key='ζαζακι' }
Languages['dlm'] = { iso='dlm', name='δαλματική', cat='Δαλματική γλώσσα', link='Δαλματικά (diq)',
                   from='προέλευσης από τη δαλματική γλώσσα', frm='δαλματική', words='Δαλματικές λέξεις', 
                   apo='τη δαλματική', apota='από τα δαλματικά', wiki='Δαλματία', wikiExists=false, key='δαλματικη' }
Languages['dra-pro'] = { iso='dra-pro', name='πρωτοδραβιδική', cat='Πρωτοδραβιδική γλώσσα', link='Πρωτοδραβιδική γλώσσα (dra-pro)',
                   from='πρωτοδραβιδικής προέλευσης', frm='πρωτοδραβιδική', words='Πρωτοδραβιδικές λέξεις',
                   apo='την πρωτοδραβιδική', apota='από την πρωτοδραβιδική', wiki='', wikiExists=false, key='πρωτοδραβιδικη' }
                   -- e.g. lemma Malayalam: [[കൈ]]
Languages['dsb'] = { iso='dsb', name='κάτω σορβικά', cat='Κάτω σορβική γλώσσα', link='Κάτω σορβικά (hsb)',
                   from='προέλευσης από την κάτω σορβική', frm='κάτω σορβική', words='Λέξεις της κάτω σορβικής',
                   apo='την κάτω σορβική', apota='από τα κάτω σορβικά', wiki='', wikiExists=false, key='κατωσορβικα' }
Languages['dua'] = { iso='dua', name='ντουάλα', cat='Γλώσσα ντουάλα', link='Ντουάλα (dua)',
                   from='προέλευσης από τη γλώσσα ντουάλα', frm='ντουάλα', words='Λέξεις της γλώσσας ντουάλα',
                   apo='τη γλώσσα ντουάλα', apota='από τη γλώσσα ντουάλα', wiki='en:Duala language', wikiExists=false, key='ντουαλα' }
Languages['dum'] = { iso='dum', name='μέση ολλανδική', cat='Μέση ολλανδική γλώσσα', link='Μέση ολλανδική (dum)',
                   from='προέλευσης από τη μέση ολλανδική', frm='μέση ολλανδική', words='Λέξεις της μέσης ολλανδικής',
                   apo='τη μέση ολλανδική', apota='από τη μέση ολλανδική', wiki='', wikiExists=false, key='μεσηολλανδικη' }
Languages['dv'] = { iso='dv', name='ντιβέχι', cat='Γλώσσα ντιβέχι', link='Ντιβέχι (dv)',
                   from='προέλευσης από τη γλώσσα ντιβέχι', frm='ντιβέχι', words='Λέξεις της γλώσσας ντιβέχι',
                   apo='τη γλώσσα ντιβέχι', apota='από τη γλώσσα ντιβέχι', wiki='Γλώσσα Ντιβέχι', wikiExists=true, key='ντιβεχι' }
Languages['dz'] = { iso='dz', name='τζόνγκα', cat='Γλώσσα τζόνγκα', link='Τζόνγκα (dz)',
                   from='προέλευσης από τη γλώσσα τζόνγκα', frm='τζόνγκα', words='Λέξεις της γλώσσας τζόνγκα',
                   apo='τη γλώσσα τζόνγκα', apota='από τη γλώσσα τζόνγκα', wiki='Τζόνγκα', wikiExists=false, key='τζονγκα' }
Languages['ee'] = { iso='ee', name='έουε', cat='Γλώσσα έουε', link='Έουε (ee)',
                   from='προέλευσης από τη γλώσσα έουε', frm='έουε', words='Λέξεις της γλώσσας έουε',
                   apo='τη γλώσσα έουε', apota='από τη γλώσσα έουε', wiki='', wikiExists=false, key='εουε' }
Languages['egy'] = { iso='egy', name='αρχαία αιγυπτιακά', cat='Αρχαία αιγυπτιακή γλώσσα', link='Αρχαία αιγυπτιακά (egy)',
                   from='αρχαίας αιγυπτιακής προέλευσης', frm='αρχαία αιγυπτιακή', words='Αρχαίες αιγυπτιακές λέξεις',
                   apo='την αρχαία αιγυπτιακή', apota='από τα αρχαία αιγυπτιακά', wiki='Αρχαία αιγυπτιακή γλώσσα', wikiExists=false, key='αρχαιααιγυπτιακα' }
Languages['egx-dem'] = { iso='egx-dem', name='δημώδη αιγυπτιακά', cat='Δημώδης αιγυπτιακή γλώσσα', link='Δημώδη αιγυπτιακά (egx-dem)',
                   from='δημώδους αιγυπτιακής προέλευσης', frm='δημώδης αιγυπτιακή', words='Δημώδεις αιγυπτιακές λέξεις',
                   apo='τη δημώδη αιγυπτιακή', apota='από τα δημώδη αιγυπτιακά', wiki='', wikiExists=false, key='δημωδηαιγυπτιακα' }
Languages['el'] = { iso='el', name='νέα ελληνικά', cat='Νέα ελληνικά', link='Νέα ελληνικά (el)',
                   from='νεοελληνικής προέλευσης', frm='νέα ελληνική', words='Νεοελληνικές λέξεις',
                   apo='τη νέα ελληνική', apota='από τα νέα ελληνικά', wiki='Νέα ελληνική γλώσσα', wikiExists=true, key='*νεαελληνικα' }
-- status main, regional
Languages['el-cyp'] = { iso='el-cyp', name='κυπριακά', cat='Κυπριακά', link='Κυπριακά (el-cyp)',
	from='κυπριακής προέλευσης', frm='κυπριακή', words='Κυπριακές λέξεις',
	apo='την κυπριακή', apota='από τα κυπριακά', wiki='Κυπριακή διάλεκτος της ελληνικής γλώσσας', wikiExists=true, key='*κυπριακα',
	-- for Category with auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*κυπριακα", apota_key="'κυπριακα",
}
-- status main, regional
Languages['el-crt'] = { iso='el-crt', name='κρητικά', cat='Κρητικά', link='Κρητικά (el-crt)',
	from='κρητικής προέλευσης', frm='κρητική', words='Κρητικές λέξεις',
	apo='την κρητική', apota='από τα κρητικά', wiki='Κρητική διάλεκτος', wikiExists=true, key='*κρητικα',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*κρητικα", apota_key="'κρητικα" }
Languages['elx'] = { iso='elx', name='ελαμικά', cat='Ελαμική γλώσσα', link='Ελαμικά (elx)',
                   from='ελαμικής προέλευσης', frm='ελαμική', words='Ελαμικές λέξεις',
                   apo='την ελαμική', apota='από τα ελαμικά', wiki='Ελαμιτική γλώσσα', wikiExists=false, key='ελαμικα' }
Languages['en'] = { iso='en', name='αγγλικά', cat='Αγγλική γλώσσα', link='Αγγλικά (en)',
                   from='αγγλικής προέλευσης', frm='αγγλική', words='Αγγλικές λέξεις',
                   apo='την αγγλική', apota='από τα αγγλικά', wiki='Αγγλική γλώσσα', wikiExists=true, key='αγγλικα' }
-- plus regional en-.... for audio [[Πρότυπο:ήχος]] and some Cat. like {ετ|αργκό}
Languages['en-au'] = { iso='en-au', name='αυστραλιανά αγγλικά', cat='Αυστραλιανά αγγλικά', link='Αγγλικά (en)',
	from='αυστραλιανής προέλευσης', frm='αυστραλιανή αγγλική', words='Αυστραλιανές αγγλικές λέξεις',
	apo='την αυστραλιανή αγγλική', apota='από τα αυστραλιανά αγγλικά', wiki='Αγγλική γλώσσα', wikiExists=false, key='αυστραλιανααγγλικα',
	-- for auto cat
	sublang=true, regional=true, host='Αγγλική γλώσσα', host_show='Αγγλικά', host_name='αγγλικά', host_apota='από τα αγγλικά', 
	host_iso='en', host_key="+αυστραλιανααγγλικα", apota_key="'αυστραλιανααγγλικα" }
Languages['en-br'] = { iso='en-br', name='βρετανικά αγγλικά', cat='Βρετανικά αγγλικά', link='Αγγλικά (en)',
	from='βρετανικής προέλευσης', frm='βρετανικήα αγγλική', words='Βρετανικές αγγλικές λέξεις',
	apo='τη βρετανική αγγλική', apota='από τα βρετανικά αγγλικά', wiki='Αγγλική γλώσσα', wikiExists=false, key='αυστραλιανααγγλικα',
	-- for auto cat
	sublang=true, regional=true, host='Αγγλική γλώσσα', host_show='Αγγλικά', host_name='αγγλικά', host_apota='από τα αγγλικά', 
	host_iso='en', host_key="+βρετανικανααγγλικα", apota_key="'βρετανικααγγλικα" }
Languages['en-ca'] = { iso='en-ca', name='καναδικά αγγλικά', cat='Καναδικά αγγλικά', link='Αγγλικά (en)',
	from='καναδικής προέλευσης', frm='καναδική αγγλική', words='Καναδικές αγγλικές λέξεις',
	apo='την καναδική αγγλική', apota='από τα καναδικά αγγλικά', wiki='Αγγλική γλώσσα', wikiExists=false, key='καναδικααγγλικα',
	-- for auto cat
	sublang=true, regional=true, host='Αγγλική γλώσσα', host_show='Αγγλικά', host_name='αγγλικά', host_apota='από τα αγγλικά', 
	host_iso='en', host_key="+καναδικααγγλικα", apota_key="'καναδικααγγλικα",
}
Languages['en-us'] = { iso='en-us', name='αμερικανικά αγγλικά', cat='Αμερικανικά αγγλικά', link='Αγγλικά (en)',
	from='αμερικανικής προέλευσης', frm='αμερικανική αγγλική', words='Αμερικανικές αγγλικές λέξεις',
	apo='την αμερικανική αγγλική', apota='από τα αμερικανικά αγγλικά', wiki='Αγγλική γλώσσα', wikiExists=true, key='αμερικανικααγγλικα',
	-- for Category with auto cat
	sublang=true, regional=true, host='Αγγλική γλώσσα', host_show='Αγγλικά', host_name='αγγλικά', host_apota='από τα αγγλικά', 
	host_iso='en', host_key="+αμερικανικααγγλικα", apota_key="'αμερικανικααγγλικα" }
Languages['enm'] = { iso='enm', name='μέση αγγλική', cat='Μέση αγγλική γλώσσα', link='Μέση αγγλική (enm)',
                   from='προέλευσης από τη μέση αγγλική', frm='μέση αγγλική', words='Λέξεις της μέσης αγγλικής',
                   apo='τη μέση αγγλική', apota='από τη μέση αγγλική', wiki='Μέση αγγλική γλώσσα', wikiExists=false, key='μεσηαγγλικη' }
                   -- Middle English
Languages['eo'] = { iso='eo', name='εσπεράντο', cat='Γλώσσα εσπεράντο', link='Εσπεράντο (eo)',
                   from='προέλευσης από τη γλώσσα εσπεράντο', frm='εσπεράντο', words='Λέξεις της εσπεράντο',
                   apo='τη γλώσσα εσπεράντο', apota='από την εσπεράντο', wiki='Εσπεράντο', wikiExists=true, key='εσπεραντο' }
Languages['es'] = { iso='es', name='ισπανικά', cat='Ισπανική γλώσσα', link='Ισπανικά (es)',
                   from='ισπανικής προέλευσης', frm='ισπανική', words='Ισπανικές λέξεις',
                   apo='την ισπανική', apota='από τα ισπανικά', wiki='Ισπανική γλώσσα', wikiExists=true, key='ισπανικα' }
Languages['et'] = { iso='et', name='εσθονικά', cat='Εσθονική γλώσσα', link='Εσθονικά (et)',
                   from='εσθονικής προέλευσης', frm='εσθονική', words='Εσθονικές λέξεις',
                   apo='την εσθονική', apota='από τα εσθονικά', wiki='Εσθονική γλώσσα', wikiExists=true, key='εσθονικα' }
Languages['ett'] = { iso='ett', name='ετρουσκικά', cat='Ετρουσκική γλώσσα', link='Ετρουσκικά (ett)',
                   from='ετρουσκικής προέλευσης', frm='ετρουσκική', words='Ετρουσκικές λέξεις',
                   apo='την ετρουσκική', apota='από τα ετρουσκικά', wiki='Ετρουσκική γλώσσα', wikiExists=false, key='ετρουσκικα' }
Languages['ext'] = { iso='ext', name='εξτρεμαδουρικά', cat='Εξτρεμαδουρική γλώσσα', link='Εξτρεμαδουρικά (ext)',
                   from='εξτρεμαδουρικής προέλευσης', frm='εξτρεμαδουρική', words='Εξτρεμαδουρικές λέξεις',
                   apo='την εξτρεμαδουρική', apota='από τα εξτρεμαδουρικά', wiki='Εξτρεμαδουρική γλώσσα', wikiExists=false, key='εξτρεμοδουρικα' }
Languages['eu'] = { iso='eu', name='βασκικά', cat='Βασκική γλώσσα', link='Βασκικά (eu)',
                   from='βασκικής προέλευσης', frm='βασκική', words='Βασκικές λέξεις',
                   apo='τη βασκική', apota='από τα βασκικά', wiki='Βασκική γλώσσα', wikiExists=true, key='βασκικα' }
Languages['fa'] = { iso='fa', name='περσικά', cat='Περσική γλώσσα', link='Περσικά (fa)', script='Arab',
                   from='περσικής προέλευσης', frm='περσική', words='Περσικές λέξεις',
                   apo='την περσική', apota='από τα περσικά', wiki='Περσική γλώσσα', wikiExists=true, key='περσικα' }
Languages['ff'] = { iso='ff', name='Fula', cat='Γλώσσα Fula', link='Fula (ff)',
                   from='προέλευσης από τη γλώσσα Fula', frm='γλώσσα Fula', words='Λέξεις της γλώσσας Fula',
                   apo='τη γλώσσα Fula', apota='από τη γλώσσα Fula', wiki='', wikiExists=false, key='φουλα' }
Languages['fi'] = { iso='fi', name='φινλανδικά', cat='Φινλανδική γλώσσα', link='Φινλανδικά (fi)',
                   from='φινλανδικής προέλευσης', frm='φινλανδική', words='Φινλανδικές λέξεις',
                   apo='τη φινλανδική', apota='από τα φινλανδικά', wiki='Φινλανδική γλώσσα', wikiExists=true, key='φινλανδικα' }
Languages['fiu-vro'] = { iso='fiu-vro', name='Võro', cat='Γλώσσα Võro', link='Võro (fiu-vro)',
                   from='προέλευσης από τη γλώσσα Võro', frm='γλώσσα Võro', words='Λέξεις της γλώσσας Võro',
                   apo='τη γλώσσα Võro', apota='από τη γλώσσα Võro', wiki='', wikiExists=false, key='βορο' }
Languages['fj'] = { iso='fj', name='φίτζι', cat='Γλώσσα φίτζι', link='Φίτζι (fj)',
                   from='προέλευσης από τη γλώσσα φίτζι', frm='φίτζι', words='Λέξεις της γλώσσας φίτζι',
                   apo='τη γλώσσα φίτζι', apota='από τη γλώσσα φίτζι', wiki='', wikiExists=true, key='φιτζι' }
Languages['fo'] = { iso='fo', name='φεροϊκά', cat='Φεροϊκή γλώσσα', link='Φεροϊκά (fo)',
                   from='φεροϊκής προέλευσης', frm='φεροϊκή', words='Φεροϊκές λέξεις',
                   apo='τη φεροϊκή', apota='από τα φεροϊκά', wiki='Φεροϊκή γλώσσα', wikiExists=true, key='φεροικα' }
Languages['fr'] = { iso='fr', name='γαλλικά', cat='Γαλλική γλώσσα', link='Γαλλικά (fr)',
                   from='γαλλικής προέλευσης', frm='γαλλική', words='Γαλλικές λέξεις',
                   apo='τη γαλλική', apota='από τα γαλλικά', wiki='Γαλλική γλώσσα', wikiExists=true, key='γαλλικα' }
Languages['frk'] = { iso='frk', name='φραγκικά', cat='Φραγκική γλώσσα', link='Φραγκικά (frk)',
                   from='φραγκικής προέλευσης', frm='φραγκική', words='Φραγκικές λέξεις',
                   apo='τη φραγκική', apota='από τα φραγκικά', wiki='', wikiExists=false, key='φραγκικα' }
                   -- συνώνυμα: παλαιά φραγκικά. Frankish (ή Old Frankish)
Languages['frm'] = { iso='frm', name='μέση γαλλική', cat='Μέση γαλλική γλώσσα', link='Μέση γαλλική (frm)',
                   from='προέλευσης από τη μέση γαλλική', frm='μέση γαλλική', words='Λέξεις της μέσης γαλλικής',
                   apo='τη μέση γαλλική', apota='από τη μέση γαλλική', wiki=':en:Middle French', wikiExists=false, key='μεσηγαλλικη' }
Languages['fro'] = { iso='fro', name='παλαιά γαλλικά', cat='Παλαιά γαλλική γλώσσα', link='Παλαιά γαλλικά (fro)',
                   from='προέλευσης από την παλαιά γαλλική', frm='παλαιά γαλλική', words='Λέξεις της παλαιάς γαλλικής',
                   apo='την παλαιά γαλλική', apota='από τα παλαιά γαλλικά', wiki='', wikiExists=false, key='παλαιαγαλλικα' }
Languages['frp'] = { iso='frp', name='γαλλοπροβηγκιανά', cat='Γαλλοπροβηγκιανή γλώσσα', link='Γαλλοπροβηγκιανά (frp)',
                   from='γαλλοπροβηγκιανής προέλευσης', frm='γαλλοπροβηγκιανή', words='Γαλλοπροβηγκιανές λέξεις',
                   apo='τη γαλλοπροβηγκιανή', apota='από τα γαλλοπροβηγκιανά', wiki='Γαλλοπροβηγκιανή γλώσσα', wikiExists=false, key='γαλλοπροβηγκιανα' }
					-- δείτε και oc, pro, prv
Languages['fur'] = { iso='fur', name='φριουλανικά', cat='Φριουλανική γλώσσα', link='Φριουλανικά (fur)',
                   from='φριουλανικής προέλευσης', frm='φριουλανική', words='Φριουλανικές λέξεις',
                   apo='τη φριουλανική', apota='από τα φριουλανικά', wiki='Φριουλανική γλώσσα', wikiExists=false, key='φριουλανικα' }
Languages['fy'] = { iso='fy', name='δυτικά φριζικά', cat='Δυτική φριζική γλώσσα',  link='Δυτική φριζική (fy)',
                   from='προέλευσης από τη δυτική φριζική', frm='δυτική φριζική', words='Δυτικές φριζικές λέξεις',
                   apo='τη δυτική φριζική', apota='από τα δυτικά φριζικά', wiki='Φριζικές γλώσσες', wikiExists=true, key='φριζικαδυτικα' } 
                   --το άρθο της ΒΠ, χρησιμοποιεί όρο 'γλώσσες', ενώ είναι 'γλώσσα'
Languages['ga'] = { iso='ga', name='ιρλανδικά γαελικά', cat='Ιρλανδική γαελική γλώσσα', link='Ιρλανδικά γαελικά (ga)',
                   from='ιρλανδικής γαελικής προέλευσης', frm='ιρλανδική γαελική', words='Ιρλανδικές γαελικές λέξεις',
                   apo='την ιρλανδική γαελική', apota='από τα ιρλανδικά γαελικά', wiki='Ιρλανδική γλώσσα', wikiExists=true, key='ιρλανδικαγαελικα' }
Languages['gal'] = { iso='gal', name='γκαλό', cat='Γλώσσα γκαλό', link='Γκαλό (gal)',
                   from='προέλευσης από τη γλώσσα γκαλό', frm='γκαλό', words='Λέξεις της γλώσσας γκαλό',
                   apo='τη γλώσσα γκαλό', apota='από τη γλώσσα γκαλό', wiki='', wikiExists=false, key='γκαλο' }
Languages['gan'] = { iso='gan', name='κινεζικά γκαν', cat='Κινεζικά γκαν', link='Κινεζικά γκαν (gan)',
                   from='προέλευσης από την κινεζική γκαν', frm='κινεζική γκαν', words='Λέξεις της κινεζικής γκαν',
                   apo='την κινεζική γκαν', apota='από τα κινεζικά γκαν', wiki='', wikiExists=false, key='κινεζικαγκαν' }
Languages['gcr'] = { iso='gcr', name='κρεολικά της Γουϊάνας', cat='Κρεολική γλώσσα της Γουϊάνας', link='Κρεολικά της Γουϊάνας (gcr)',
                   from='προέλευσης από την κρεολική της Γουϊάνας', frm='κρεολική της Γουϊάνας', words='Λέξεις της κρεολικής της Γουϊάνας',
                   apo='την κρεολική της Γουϊάνας', apota='από τα κρεολικά της Γουϊάνας', wiki='', wikiExists=false, key='κρεολικαγουιανασ' }
Languages['gd'] = { iso='gd', name='σκωτικά γαελικά', cat='Σκωτική γαελική γλώσσα', link='Σκωτικά γαελικά (gd)',
                   from='σκωτικής γαελικής προέλευσης', frm='σκωτική γαελική', words='Σκωτικές γαελικές λέξεις',
                   apo='τη σκωτική γαελική', apota='από τα σκωτικά γαελικά', wiki='Σκωτική Γαελική γλώσσα', wikiExists=true, key='σκωτικαγαελικα' }
Languages['gem-sue'] = { iso='gem-sue', name='σουηβικά', cat='Σουηβική γλώσσα', link='Σουηβικά (gem-sue)',
                   from='σουηβικής προέλευσης', frm='σουηβική', words='Σουηβικές λέξεις',
                   apo='τη σουηβική', apota='από τα σουηβικά', wiki='', wikiExists=false, key='σουηβικα' }
Languages['gem-pro'] = { iso='gem-pro', name='πρωτογερμανική', cat='Πρωτογερμανική γλώσσα', link='Πρωτογερμανική γλώσσα (gem-pro)',
                   from='πρωτογερμανικής προέλευσης', frm='πρωτογερμανική', words='Πρωτογερμανικές λέξεις',
                   apo='την πρωτογερμανική', apota='από την πρωτογερμανική', wiki='', wikiExists=false, key='πρωτογερμανικη' }
Languages['gmw-pro'] = { iso='gmw-pro', name='δυτική πρωτογερμανική', cat='Δυτική πρωτογερμανική γλώσσα', link='Δυτική πρωτογερμανική γλώσσα (gmw-pro)',
                   from='δυτικής πρωτογερμανικής προέλευσης', frm='δυτική πρωτογερμανική', words='Δυτικές pρωτογερμανικές λέξεις',
                   apo='την δυτική πρωτογερμανική', apota='από τη δυτική πρωτογερμανική', wiki='Δυτικές γερμανικές γλώσσες', wikiExists=false, key='δυτικηπρωτογερμανικη' }
Languages['gkm'] = { iso='gkm', name='μεσαιωνικά ελληνικά', cat='Μεσαιωνικά ελληνικά', link='Μεσαιωνικά ελληνικά (gkm)',
                   from='μεσαιωνικής ελληνικής προέλευσης', frm='μεσαιωνική ελληνική', words='Μεσαιωνικές ελληνικές λέξεις',
                   apo='τη μεσαιωνική ελληνική', apota='από τα μεσαιωνικά ελληνικά', wiki='Μεσαιωνική ελληνική γλώσσα', wikiExists=false, key='*μεσαιωνικαελληνικα' }
-- κωδικός για ετυμολογίες και ετικέτες -- ειδικά για τις Ασσίζες κ.λπ.
Languages['gkm-cyp'] = { iso='gkm-cyp', name='μεσαιωνικά κυπριακά', cat='Μεσαιωνικά κυπριακά', link='Μεσαιωνικά κυπριακά (gkm-cyp)',
	from='μεσαιωνικής κυπριακής προέλευσης', frm='μεσαιωνική κυπριακή', words='Μεσαιωνικές κυπριακές λέξεις',
	apo='τη μεσαιωνική κυπριακή', apota='από τα μεσαιωνικά κυπριακά', wiki='', wikiExists=true, key='*κυπριακαμεσαιωνικα',
	-- for Category with auto cat
	sublang=true, regional=true, host='Μεσαιωνικά ελληνικά', host_show='Μεσαιωνικά ελληνικά', host_name='μεσαιωνικά ελληνικά', host_apota='από τα μεσαιωνικά ελληνικά', 
	host_iso='el', host_key="*κυπριακαμεσαιωνικα", apota_key="'κυπριακαμεσαιωνικα" }
-- κωδικός για ετυμολογίες και ετικέτες
Languages['gkm-crt'] = { iso='gkm-crt', name='μεσαιωνικά κρητικά', cat='Μεσαιωνικά κρητικά', link='Μεσαιωνικά κρητικά (gkm-crt)',
	from='μεσαιωνικής κρητικής προέλευσης', frm='μεσαιωνική κρητική', words='Μεσαιωνικές κρητικές λέξεις',
	apo='τη μεσαιωνική κρητική', apota='από τα μεσαιωνικά κρητικά', wiki='', wikiExists=true, key='*κρητικαμεσαιωνικα',
	-- for Category with auto cat
	sublang=true, regional=true, host='Μεσαιωνικά ελληνικά', host_show='Μεσαιωνικά ελληνικά', host_name='μεσαιωνικά ελληνικά', host_apota='από τα μεσαιωνικά ελληνικά', 
	host_iso='el', host_key="*κρητικαμεσαιωνικα", apota_key="'κρητικαμεσαιωνικα" }
Languages['gl'] = { iso='gl', name='γαλικιανά', cat='Γαλικιανή γλώσσα', link='Γαλικιανά (gl)',
                   from='γαλικιανής προέλευσης', frm='γαλικιανή', words='Γαλικιανές λέξεις',
                   apo='τη γαλικιανή', apota='από τα γαλικιανά', wiki='Γαλικιανή γλώσσα', wikiExists=true, key='γαλικιανα' }
Languages['gmh'] = { iso='gmh', name='μέση άνω γερμανική', cat='Μέση άνω γερμανική γλώσσα', link='Μέση άνω γερμανική (gmh)',
                   from='προέλευσης από τη μέση άνω γερμανική', frm='μέση άνω γερμανική', words='Λέξεις της μέσης άνω γερμανικής',
                   apo='τη μέση άνω γερμανική', apota='από τη μέση άνω γερμανική', wiki='', wikiExists=false, key='μεσηανωγερμανικη' }
Languages['gml'] = { iso='gml', name='μέση κάτω γερμανική', cat='Μέση κάτω γερμανική γλώσσα', link='Μέση κάτω γερμανική (gml)',
                   from='προέλευσης από τη μέση κάτω γερμανική', frm='μέση κάτω γερμανική', words='Λέξεις της μέσης κάτω γερμανικής',
                   apo='τη μέση κάτω γερμανική', apota='από τη μέση κάτω γερμανική', wiki='', wikiExists=false, key='μεσηκατωγερμανικη' }
Languages['gmy'] = { iso='gmy', name='μυκηναϊκή διάλεκτος', cat='Μυκηναϊκή διάλεκτος', link='Μυκηναϊκή διάλεκτος (gmy)',
	from='μυκηναϊκής προέλευσης', frm='μυκηναϊκή', words='Μυκηναϊκές λέξεις',
	apo='τη μυκηναϊκή', apota='από τη μυκηναϊκή', wiki='Μυκηναϊκή ελληνική', wikiExists=false, key='*μυκηναικη',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*μυκηναικη", apota_key="'μυκηναικη" }
Languages['gmy2'] = { iso='', name='μυκηναϊκή διάλεκτος', cat='Μυκηναϊκή διάλεκτος', link='Μυκηναϊκή διάλεκτος (gmy)',
                   from='μυκηναϊκής προέλευσης', frm='μυκηναϊκή', words='Μυκηναϊκές λέξεις',
                   apo='τη μυκηναϊκή', apota='από τη μυκηναϊκή', wiki='Μυκηναϊκή ελληνική', wikiExists=false, key='' }
                   -- gmy2 directly from Latn -  για εντολή μεταγραφής ΑΠΟ τη διεθνή μεταγραφή ΠΡΟΣ τα Unicode σύμβολα
Languages['gn'] = { iso='gn', name='γκουαρανί', cat='Γλώσσα γκουαρανί', link='Γκουαρανί (gn)',
                   from='προέλευσης από τη γλώσσα γκουαρανί', frm='γκουαρανί', words='Λέξεις της γλώσσας γκουαρανί',
                   apo='τη γλώσσα γκουαρανί', apota='από τη γλώσσα γκουαρανί', wiki='Γλώσσα Γκουαρανί', wikiExists=true, key='γκουαρανι' }
Languages['goh'] = { iso='goh', name='παλαιά άνω γερμανικά', cat='Παλαιά άνω γερμανική γλώσσα', link='Παλαιά άνω γερμανικά (goh)',
                   from='προέλευσης από την παλαιά άνω γερμανική', frm='παλαιά άνω γερμανική', words='Λέξεις της παλαιάς άνω γερμανικής',
                   apo='την παλαιά άνω γερμανική', apota='από τα παλαιά άνω γερμανικά', wiki='', wikiExists=false, key='παλαιαανωγερμανικα' }
Languages['got'] = { iso='got', name='γοτθικά', cat='Γοτθική γλώσσα', link='Γοτθικά (got)',
                   from='γοτθικής προέλευσης', frm='γοτθική', words='Γοτθικές λέξεις',
                   apo='τη γοτθική', apota='από τα γοτθικά', wiki='Γοτθική γλώσσα', wikiExists=false, key='γοτθικα' }
Languages['grc'] = { iso='grc', name='αρχαία ελληνικά', cat='Αρχαία ελληνικά', link='Αρχαία ελληνικά (grc)',
                   from='αρχαίας ελληνικής προέλευσης', frm='αρχαία ελληνική', words='Αρχαίες ελληνικές λέξεις',
                   apo='την αρχαία ελληνική', apota='από τα αρχαία ελληνικά', wiki='Αρχαία ελληνική γλώσσα', wikiExists=false, key='*αρχαιαελληνικα' }
--[=[ end test για grc-dor, grc-ion μέχρι να βρεθεί τρόπος να μπαίνουν μονο σε ετυμολογίες. Δεν είναι αυτόνομοι τομείς. Μπαινουν μόνο σε 'Κατηγορία:..... δωρικής διαλέκτου (αρχαία ελληνικά)'
-- TEST Μόνο για ετυμολογίες - Etymology ONLY:
Languages['grc-dor'] = { iso='grc-dor', name='δωρική διάλεκτος', cat='Δωρική διάλεκτος', link='Αρχαία ελληνικά (grc)',
	from='δωρικής προέλευσης', frm='δωρική διάλεκτος', words='Δωρικές λέξεις',
	apo='τη δωρική διάλεκτο', apota='από τη δωρική διάλεκτο', wiki='Δωρική διάλεκτος', wikiExists=false, key='*δωρικη',
	-- for auto cat
	sublang=true, regional=true, host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*δωρικη", apota_key="'δωρικη", }
		--  αρχαία ελληνική διάλεκτος. Κωδικός για ετυμολογίες. [[Πρότυπο:δωρ]] στους ορισμούς.  Χρήση στην ετυμολογία: π.χ. [[σάμερε]]
-- TEST Μόνο για ετυμολογίες - Etymology ONLY:
Languages['grc-ion'] = { iso='grc-ion', name='ιωνική διάλεκτος', cat='Ιωνική διάλεκτος', link='Αρχαία ελληνικά (grc)',
	from='ιωνικής προέλευσης', frm='ιωνική διάλεκτος', words='Ιωνικές λέξεις',
	apo='την ιωνική διάλεκτο', apota='από την ιωνική διάλεκτο', wiki='Ιωνική διάλεκτος', wikiExists=false, key='*ιωνικη',
	-- for auto cat
	sublang=true, regional=true, host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*ιωνικη", apota_key="'ιωνικη", }
		-- αρχαία ελληνική διάλεκτος. Κωδικός για ετυμολογίες. [[Πρότυπο:ιων]] στους ορισμούς. Χρήση στην ετυμολογία: π.χ. [[ούλος]]
]=]--
-- TEST Μόνο για ετυμολογίες - Etymology ONLY:: DO NOT write iso=grc-dor, it would be added everywhere.
Languages['grc-dor'] = { iso='grc', name='αρχαία ελληνικά', cat='Δωρική διάλεκτος', link='Αρχαία ελληνικά (grc)',
	from='δωρικής προέλευσης', frm='δωρική διάλεκτος', words='Λέξεις δωρικής διαλέκτου',
	apo='τη δωρική διάλεκτο', apota='από τη δωρική διάλεκτο', wiki='Δωρική διάλεκτος', wikiExists=false, key='*δωρικη',
	-- for auto cat
	sublang=true, regional=true, host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*δωρικη", apota_key="'δωρικη", }
		--  αρχαία ελληνική διάλεκτος. Κωδικός για ετυμολογίες. [[Πρότυπο:δωρ]] στους ορισμούς.  Χρήση στην ετυμολογία: π.χ. [[σάμερε]]
-- TEST Μόνο για ετυμολογίες - Etymology ONLY: DO NOT write iso=grc-ion, it would be added everywhere.
Languages['grc-ion'] = { iso='grc', name='αρχαία ελληνικά', cat='Ιωνική διάλεκτος', link='Αρχαία ελληνικά (grc)',
	from='ιωνικής προέλευσης', frm='ιωνική διάλεκτος', words='Λέξεις ιωνικής διαλέκτου',
	apo='την ιωνική διάλεκτο', apota='από την ιωνική διάλεκτο', wiki='Ιωνική διάλεκτος', wikiExists=false, key='*ιωνικη',
	-- for auto cat
	sublang=true, regional=true, host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*ιωνικη", apota_key="'ιωνικη", }
		-- αρχαία ελληνική διάλεκτος. Κωδικός για ετυμολογίες. [[Πρότυπο:ιων]] στους ορισμούς. Χρήση στην ετυμολογία: π.χ. [[ούλος]]
-- Eλληνιστική κοινή  grc-koi έχει status = 'main' regional=false
Languages['grc-koi'] = { 
	-- these keys handle the lemma: they put it in various categories with the aid of etymology modules, of the page's modules
	iso='grc-koi', name='ελληνιστική κοινή', cat='Ελληνιστική κοινή', link='Αρχαία ελληνικά (grc)',
	from='ελληνιστικής προέλευσης', frm='ελληνιστική κοινή', words='Ελληνιστικές λέξεις',
	apo='την ελληνιστική κοινή', apota='από την ελληνιστική κοινή', wiki='Ελληνιστική Κοινή', wikiExists=false, key='*ελληνιστικη', 
	-- for auto cat
	sublang=true, regional=false, status = 'main', host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*ελληνιστικη", apota_key="'ελληνιστική" }
Languages['grk'] = { iso='grk', name='ελληνικά', cat='Ελληνική γλώσσα', link='Ελληνική γλώσσα (grk)',
                   from='ελληνικής προέλευσης', frm='ελληνική γλώσσα', words='Ελληνικές λέξεις',
                   apo='ελληνική γλώσσα', apota='από ελληνική γλώσσα', wiki='Ελληνική γλώσσα', wikiExists=false, key='ελληνικα' }
                   --  Hellenic not a family
-- status main, regional
Languages['grk-ita'] = { iso='grk-ita', name='κατωιταλικά', cat='Κατωιταλικά', link='Κατωιταλικά (grk-ita)',
	from='κατωιταλικής προέλευσης', frm='κατωιταλική', words='Κατωιταλικές λέξεις',
	apo='την κατωιταλική', apota='από τα κατωιταλικά', wiki='Κατωιταλική διάλεκτος', wikiExists=false, key='*κατωιταλικα',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*κατωιταλικα", apota_key="'κατωιταλικα" }
-- status main, regional
Languages['grk-mar'] = { iso='grk-mar', name='μαριουπολίτικα', cat='Μαριουπολίτικα', link='Μαριουπολίτικα (grk-mar)',
	from='μαριουπολίτικης προέλευσης', frm='μαριουπολίτικη', words='Μαριουπολίτικες λέξεις',
	apo='την μαριουπολίτικη', apota='από τα μαριουπολίτικα', wiki='Μαριουπολίτικη διάλεκτος', wikiExists=false, key='*μαριουπολιτικα',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*μαριουπολιτικα", apota_key="'μαριουπολιτικα" }
Languages['grk-pro'] = { iso='grk-pro', name='πρωτοελληνική', cat='Πρωτοελληνική γλώσσα', link='Αρχαία ελληνικά (grc)', -- εξαίρεση: χωρίς Πρωτοελληνική γλώσσα (grk-pro)
                   from='πρωτοελληνικής προέλευσης', frm='πρωτοελληνική', words='Πρωτοελληνικές λέξεις',
                   apo='την πρωτοελληνική', apota='από την πρωτοελληνική', wiki='Πρωτοελληνική γλώσσα', wikiExists=false, key='πρωτοελληνικη' }
Languages['gsw'] = { iso='gsw', name='αλεμανικά γερμανικά', cat='Αλεμανικά γερμανικά', link='Αλεμανικά γερμανικά (gsw)',
                   from='αλεμανικής γερμανικής προέλευσης', frm='αλεμανική γερμανική', words='Αλεμανικές γερμανικές λέξεις',
                   apo='την αλεμανική γερμανική', apota='από τα αλεμανικά γερμανικά', wiki='Αλεμανική γερμανική γλώσσα', wikiExists=false, key='αλεμανικαγερμανικα' }
                   --  ελβετικά γερμανικά
                   -- τα προηγούμενα 'αλσατικά' θα γίνουν με ετικέτα, όπως στο en.wikt. 2025.06.05. [[User:Sarri.greek]]
Languages['gu'] = { iso='gu', name='γκουτζαράτι', cat='Γλώσσα γκουτζαράτι', link='Γκουτζαράτι (gu)',
                   from='προέλευσης από τη γλώσσα γκουτζαράτι', frm='γκουτζαράτι', words='Λέξεις της γλώσσας γκουτζαράτι',
                   apo='τη γλώσσα γκουτζαράτι', apota='από τη γλώσσα γκουτζαράτι', wiki='Γλώσσα Γκουτζαράτι', wikiExists=true, key='γκουτζαρατι' }
Languages['gv'] = { iso='gv', name='μανξ', cat='Γλώσσα μανξ', link='Μανξ (gv)',
                   from='προέλευσης από τη γλώσσα μανξ', frm='μανξ', words='Λέξεις της γλώσσας μανξ',
                   apo='τη γλώσσα μανξ', apota='από τη γλώσσα μανξ', wiki='Γλώσσα Μανξ', wikiExists=true, key='μανξ' }
Languages['ha'] = { iso='ha', name='χάουσα', cat='Γλώσσα χάουσα', link='Χάουσα (ha)',
                   from='προέλευσης από τη γλώσσα χάουσα', frm='χάουσα', words='Λέξεις της γλώσσας χάουσα',
                   apo='τη γλώσσα χάουσα', apota='από τη γλώσσα χάουσα', wiki='Γλώσσα Χάουσα', wikiExists=true, key='χαουσα' }
Languages['hak'] = { iso='hak', name='χάκα', cat='Γλώσσα χάκα', link='Χάκα (hak)',
                   from='προέλευσης από τη γλώσσα χάκα', frm='χάκα', words='Λέξεις της γλώσσας χάκα',
                   apo='τη γλώσσα χάκα', apota='από τη γλώσσα χάκα', wiki='', wikiExists=false, key='χακα' }
Languages['hanja'] = { iso='hanja', name='κορεατικά χάνζα', cat='Κορεατική γλώσσα χάνζα', link='Κορεατικά χάνζα (hanja)',
                   from='προέλευσης από την κορεατική χάνζα', frm='κορεατική χάνζα', words='Λέξεις της κορεατικής χάνζα',
                   apo='την κορεατική χάνζα', apota='από τα κορεατικά χάνζα', wiki='', wikiExists=false, key='κορεατικαχανζα' }
Languages['haw'] = { iso='haw', name='χαβανέζικα', cat='Χαβανέζικη γλώσσα', link='Χαβανέζικα (haw)',
                   from='χαβανέζικης προέλευσης', frm='χαβανέζικη', words='Χαβανέζικες λέξεις',
                   apo='τη χαβανέζικη', apota='από τα χαβανέζικα', wiki='Χαβαϊκή γλώσσα', wikiExists=false, key='χαβαικα' }
Languages['hbo'] = { iso='hbo', name='αρχαία εβραϊκά', cat='Αρχαία εβραϊκή γλώσσα', link='Αρχαία εβραϊκά (hbo)',
                   from='αρχαίας εβραϊκής προέλευσης', frm='αρχαία εβραϊκή', words='Αρχαίες εβραϊκές λέξεις',
                   apo='την αρχαία εβραϊκή', apota='από τα αρχαία εβραϊκά', wiki='Εβραϊκή_γλώσσα#Κλασική Εβραϊκή', wikiExists=false, key='αρχαιαεβραικα' }
Languages['he'] = { iso='he', name='εβραϊκά', cat='Εβραϊκή γλώσσα', link='Εβραϊκά (he)',
                   from='εβραϊκής προέλευσης', frm='εβραϊκή', words='Εβραϊκές λέξεις',
                   apo='την εβραϊκή', apota='από τα εβραϊκά', wiki='Εβραϊκή γλώσσα', wikiExists=true, key='εβραικα' }
Languages['hi'] = { iso='hi', name='χίντι', cat='Γλώσσα χίντι', link='Χίντι (hi)',
                   from='προέλευσης από τη γλώσσα χίντι', frm='χίντι', words='Λέξεις της γλώσσας χίντι',
                   apo='τη γλώσσα χίντι', apota='από τη γλώσσα χίντι', wiki='Χίντι', wikiExists=true, key='χιντι' }
Languages['hif'] = { iso='hif', name='φίτζι χίντι', cat='Γλώσσα φίτζι χίντι', link='Φίτζι χίντι (hif)',
                   from='προέλευσης από τη γλώσσα φίτζι χίντι', frm='φίτζι χίντι', words='Λέξεις της γλώσσας φίτζι χίντι',
                   apo='από τη γλώσσα φίτζι χίντι', apota='από τη γλώσσα φίτζι χίντι', wiki='Ινδουστανικά του Φίτζι', wikiExists=true, key='φιτζιχιντι' }
Languages['hit'] = { iso='hit', name='χεττιτικά', cat='Χεττιτική γλώσσα', link='Χεττιτικά (hit)',
                   from='χεττιτικής προέλευσης', frm='χεττιτική', words='Χεττιτικές λέξεις',
                   apo='τη χεττιτική', apota='από τα χεττιτικά', wiki='Χεττιτική γλώσσα', wikiExists=false, key='χιττιτικα' }
                   -- ή χιττιτικά. Hittite language.
Languages['hr'] = { iso='hr', name='κροατικά', cat='Κροατική γλώσσα', link='Κροατικά (hr)',
                   from='κροατικής προέλευσης', frm='κροατική', words='Κροατικές λέξεις',
                   apo='την κροατική', apota='από τα κροατικά', wiki='Κροατική γλώσσα', wikiExists=true, key='κροατικα' }
Languages['hsb'] = { iso='hsb', name='άνω σορβικά', cat='Άνω σορβική γλώσσα', link='Άνω σορβικά (hsb)',
                   from='προέλευσης από την άνω σορβική', frm='άνω σορβική', words='Λέξεις της άνω σορβικής',
                   apo='την άνω σορβική', apota='από τα άνω σορβικά', wiki='', wikiExists=true, key='ανωσορβικα' }
Languages['ht'] = { iso='ht', name='αϊτινά', cat='Αϊτινή γλώσσα', link='Αϊτινά (ht)',
                   from='αϊτινής προέλευσης', frm='αϊτινή', words='Αϊτινές λέξεις',
                   apo='την αϊτινή', apota='από τα αϊτινά', wiki='Αϊτινή κρεολή γλώσσα', wikiExists=false, key='αιτινα' }
Languages['hu'] = { iso='hu', name='ουγγρικά', cat='Ουγγρική γλώσσα', link='Ουγγρικά (hu)',
                   from='ουγγρικής προέλευσης', frm='ουγγρική', words='Ουγγρικές λέξεις',
                   apo='την ουγγρική', apota='από τα ουγγρικά', wiki='Ουγγρική γλώσσα', wikiExists=true, key='ουγγρικα' }
Languages['hy'] = { iso='hy', name='αρμενικά', cat='Αρμενική γλώσσα', link='Αρμενικά (hy)',
                   from='αρμενικής προέλευσης', frm='αρμενική', words='Αρμενικές λέξεις',
                   apo='την αρμενική', apota='από τα αρμενικά', wiki='Αρμενική γλώσσα', wikiExists=true, key='αρμενικα' }
Languages['hz'] = { iso='hz', name='χερέρο', cat='Γλώσσα χερέρο', link='Χερέρο (hz)',
                   from='προέλευσης από τη γλώσσα χερέρο', frm='χερέρο', words='Λέξεις της γλώσσας χερέρο',
                   apo='τη γλώσσα χερέρο', apota='από τη γλώσσα χερέρο', wiki='', wikiExists=false, key='χερερο' }
Languages['ia'] = { iso='ia', name='ιντερλίνγκουα', cat='Γλώσσα ιντερλίνγκουα', link='Ιντερλίνγκουα (ia)',
                   from='προέλευσης από τη γλώσσα ιντερλίνγκουα', frm='ιντερλίνγκουα', words='Λέξεις της γλώσσας ιντερλίνγκουα',
                   apo='τη γλώσσα ιντερλίνγκουα', apota='από τη γλώσσα ιντερλίνγκουα', wiki='Ιντερλίνγκουα', wikiExists=true, key='ιντερλινγκουα' }
Languages['id'] = { iso='id', name='ινδονησιακά', cat='Ινδονησιακή γλώσσα', link='Ινδονησιακά (id)',
                   from='ινδονησιακής προέλευσης', frm='ινδονησιακή', words='Ινδονησιακές λέξεις',
                   apo='την ινδονησιακή', apota='από τα ινδονησιακά', wiki='Ινδονησιακή γλώσσα', wikiExists=true, key='ινδονησιακα' }
Languages['ie'] = { iso='ie', name='ιντερλίνγκουε', cat='Γλώσσα ιντερλίνγκουε', link='Ιντερλίνγκουε (ie)',
                   from='προέλευσης από τη γλώσσα ιντερλίνγκουε', frm='ιντερλίνγκουε', words='Λέξεις της γλώσσας ιντερλίνγκουε',
                   apo='τη γλώσσα ιντερλίνγκουε', apota='από τη γλώσσα ιντερλίνγκουε', wiki='', wikiExists=true, key='ιντερλινγκουε' }
Languages['ig'] = { iso='ig', name='ίγκμπο', cat='Γλώσσα ίγκμπο', link='Ίγκμπο (ig)',
                   from='προέλευσης από τη γλώσσα ίγκμπο', frm='ίγκμπο', words='Λέξεις της γλώσσας ίγκμπο',
                   apo='τη γλώσσα ίγκμπο', apota='από τη γλώσσα ίγκμπο', wiki='', wikiExists=false, key='ιγκμπο' }
Languages['iir'] = { iso='iir', name='ινδοϊρανικές γλώσσες', cat='Ινδοϊρανικές γλώσσες', link='',
                   from='ινδοϊρανικής προέλευσης', frm='ινδοϊρανική', words='Iνδοϊρανικές λέξεις',
                   apo='ινδοϊρανικές γλώσσες', apota='από ινδοϊρανικές γλώσσες', wiki='Ινδοϊρανικές γλώσσες', wikiExists=false, key='ινδοιρανικη', family=true }
                   -- iir: οικογένεια Indo-Iranian ή Aryan
Languages['iir-pro'] = { iso='iir-pro', name='πρωτοϊνδοϊρανική', cat='Πρωτοϊνδοϊρανική γλώσσα', link='Πρωτοϊνδοϊρανική γλώσσα (iir-pro)',
                   from='πρωτοϊνδοϊρανικής προέλευσης', frm='πρωτοϊνδοϊρανική', words='Πρωτοϊνδοϊρανικές λέξεις',
                   apo='την πρωτοϊνδοϊρανική', apota='από την πρωτοϊνδοϊρανική', wiki='', wikiExists=false, key='πρωτοινδοιρανικη' }
					-- iir-pro (κωδικός-ετυμολογίας) Proto-Indo-Iranian ή Proto-Indo-Iranic (λήμμα [[𐏃𐎡𐎯𐎢𐏁]])
Languages['ik'] = { iso='ik', name='ινούπιακ', cat='Γλώσσα ινούπιακ', link='Ινούπιακ (ik)',
                   from='προέλευσης από τη γλώσσα ινούπιακ', frm='ινούπιακ', words='Λέξεις της γλώσσας ινούπιακ',
                   apo='τη γλώσσα ινούπιακ', apota='από τη γλώσσα ινούπιακ', wiki='', wikiExists=true, key='ινουπιακ' }
Languages['ilo'] = { iso='ilo', name='ιλοκάνο', cat='Γλώσσα ιλοκάνο', link='Ιλοκάνο (ilo)',
                   from='προέλευσης από τη γλώσσα ιλοκάνο', frm='ιλοκάνο', words='Λέξεις της γλώσσας ιλοκάνο',
                   apo='τη γλώσσα ιλοκάνο', apota='από τη γλώσσα ιλοκάνο', wiki='', wikiExists=false, key='ιλοκανο' }
Languages['ine'] = { iso='ine', name='ινδοευρωπαϊκές γλώσσες', cat='Ινδοευρωπϊκές γλώσσες', link='',
                   from='ινδοευρωπαϊκής προέλευσης', frm='ινδοευρωπαϊκή', words='Iνδοευρωπαϊκές λέξεις',
                   apo='ινδοευρωπαϊκές γλώσσες', apota='από ινδοευρωπαϊκές γλώσσες', wiki='Ινδοευρωπαϊκές γλώσσες', wikiExists=false, key='ινδοευρωπαικεσ', family=true }
                   -- ine: οικογένεια γλωσσών
Languages['ine-ana'] = { iso='ine-ana', name='γλώσσες της Ανατολίας', cat='Γλώσσες της Ανατολίας', link='',
                   from='προέλευσης από γλώσσες της Ανατολίας', frm='γλώσσα της Ανατολίας', words='Λέξεις γλωσσών της Ανατολίας',
                   apo='γλώσσες της Ανατολίας', apota='από γλώσσες της Ανατολίας', wiki='Γλώσσες της Ανατολίας', wikiExists=false, key='ανατολιασ', family=true }
                   -- οικογένεια γλωσσών όπως Καρική κλπ π.χ. λήμμα [[Ταρσός]] όταν δεν είναι βέβαιο από ποια ακριβώς 
                   -- = ανατολιακές γλώσσες (διαφοροποίηση από 'ανατολικές', που αφορά γενικά τις ασιατικές)
                   -- PROBLEM από την + frm  Χρησιμποιώ +προέλευση
Languages['ine-pro'] = { iso='ine-pro', name='πρωτοϊνδοευρωπαϊκή', cat='Πρωτοϊνδοευρωπαϊκή γλώσσα', link='Πρωτοϊνδοευρωπαϊκή γλώσσα (ine-pro)',
                   from='πρωτοϊνδοευρωπαϊκής προέλευσης', frm='πρωτοϊνδοευρωπαϊκή', words='Πρωτοϊνδοευρωπαϊκές λέξεις',
                   apo='την πρωτοϊνδοευρωπαϊκή', apota='από την πρωτοϊνδοευρωπαϊκή', wiki='', wikiExists=false, key='πρωτοινδοευρωπαικη' }
Languages['io'] = { iso='io', name='ίντο', cat='Γλώσσα ίντο', link='Ίντο (io)',
                   from='προέλευσης από τη γλώσσα ίντο', frm='ίντο', words='Λέξεις της γλώσσας ίντο',
                   apo='τη γλώσσα ίντο', apota='από τη γλώσσα ίντο', wiki='Ίντο', wikiExists=true, key='ιντο' }
Languages['ira'] = { iso='ira', name='ιρανικές γλώσσες', cat='Ιρανικές γλώσσες', link='',
                   from='ιρανικής προέλευσης', frm='ιρανική', words='Ιρανικές λέξεις',
                   apo='ιρανικές γλώσσες', apota='από ιρανικές γλώσσες', wiki='', wikiExists=false, key='ιρανικα', family=true }
                   -- ira ιρανική οικογένεια γλωσσών
Languages['ira-pro'] = { iso='ira-pro', name='πρωτοϊρανική', cat='Πρωτοϊρανική γλώσσα', link='Πρωτοϊρανική γλώσσα (ira-pro)',
                   from='πρωτοϊρανικής προέλευσης', frm='πρωτοϊρανική', words='Πρωτοϊρανικές λέξεις',
                   apo='την πρωτοϊρανική', apota='από την πρωτοϊρανική', wiki='Περσική γλώσσα', wikiExists=false, key='πρωτοιρανικη' }
Languages['ira-mid'] = { iso='ira-mid', name='μέση ιρανική', cat='Μέση ιρανική γλώσσα', link='Μέση ιρανική γλώσσα (ira-mid)',
                   from='προέλευσης από τη μέση ιρανική', frm='μεσοϊρανική', words='Λέξεις της μέσης ιρανικής',
                   apo='τη μέση ιρανική', apota='από τη μέση ιρανικήα', wiki='Περσική γλώσσα', wikiExists=false, key='μεσοιρανικη' }
Languages['is'] = { iso='is', name='ισλανδικά', cat='Ισλανδική γλώσσα', link='Ισλανδικά (is)',
                   from='ισλανδικής προέλευσης', frm='ισλανδική', words='Ισλανδικές λέξεις',
                   apo='την ισλανδική', apota='από τα ισλανδικά', wiki='Ισλανδική γλώσσα', wikiExists=true, key='ισλανδικα' }
Languages['it'] = { iso='it', name='ιταλικά', cat='Ιταλική γλώσσα', link='Ιταλικά (it)',
                   from='ιταλικής προέλευσης', frm='ιταλική', words='Ιταλικές λέξεις',
                   apo='την ιταλική', apota='από τα ιταλικά', wiki='Ιταλική γλώσσα', wikiExists=true, key='ιταλικα' }
Languages['it-oit'] = { iso='it-oit', name='παλαιά ιταλικά', cat='Παλαιά ιταλική γλώσσα', link='Παλαιά ιταλικά (it-oit)',
                   from='προέλευσης από την παλαιά ιταλική', frm='παλαιά ιταλική', words='Λέξεις της παλαιάς ιταλικής',
                   apo='την παλαιά ιταλική', apota='από τα παλαιά ιταλικά', wiki='', wikiExists=true, key='παλαιαιταλικα' }
-- ΕΚΚΡΕΜΟΤΗΤΑ FIX THIS
Languages['roa-oit'] = { iso='roa-oit', name='παλαιά ιταλικά', cat='Παλαιά ιταλική γλώσσα', link='Παλαιά ιταλικά (it-oit)',
                   from='προέλευσης από την παλαιά ιταλική', frm='παλαιά ιταλική', words='Λέξεις της παλαιάς ιταλικής',
                   apo='την παλαιά ιταλική', apota='από την παλαιά ιταλική', wiki='', wikiExists=true, key='παλαιαοιταλικα' }
Languages['itc-ola'] = { iso='itc-ola', name='παλαιά λατινικά', cat='Παλαιά λατινικά', link='Λατινικά (la)',
	from='παλαιάς λατινικής προέλευσης', frm='παλαιά λατινική', words='Λέξεις της παλαιάς λατινικής',
	apo='την παλαιά λατινική', apota='από τα παλαιά λατινικά', wiki='', wikiExists=false, key='παλαιαλατινικα',
	-- for auto cat
	sublang=true, regional=false, host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+παλαιαλατινικα", apota_key="'παλαιαλατινικα" }
	-- Old Latin, Archaic Latin, Early Latin, Pre-Classical Latin, Ante-Classical Latin
Languages['itc-pro'] = { iso='itc-pro', name='πρωτοϊταλική', cat='Πρωτοϊταλική γλώσσα', link='Πρωτοϊταλική γλώσσα (itc-pro)',
                   from='πρωτοϊταλικής προέλευσης', frm='πρωτοϊταλική', words='Πρωτοϊταλικές λέξεις',
                   apo='την πρωτοϊταλική', apota='από την πρωτοϊταλική', wiki='', wikiExists=false, key='πρωτοιταλικη' }
Languages['iu'] = { iso='iu', name='ινουκτιτούτ', cat='Γλώσσα ινουκτιτούτ', link='Ινουκτιτούτ (iu)',
                   from='προέλευσης από τη γλώσσα ινουκτιτούτ', frm='ινουκτιτούτ', words='Λέξεις της γλώσσας ινουκτιτούτ',
                   apo='τη γλώσσα ινουκτιτούτ', apota='από τη γλώσσα ινουκτιτούτ', wiki='Ινουκτιτούτ', wikiExists=true, key='ινουκτιτουτ' }
Languages['ja'] = { iso='ja', name='ιαπωνικά', cat='Ιαπωνική γλώσσα', link='Ιαπωνικά (ja)',
                   script='Hani', -- (για μεγέθυνση όπως τα zh, αλλά θα εφαρμοστεί και στη γραφή Kana)
                   from='ιαπωνικής προέλευσης', frm='ιαπωνική', words='Ιαπωνικές λέξεις',
                   apo='την ιαπωνική', apota='από τα ιαπωνικά', wiki='Ιαπωνική γλώσσα', wikiExists=true, key='ιαπωνικα' }
Languages['jam'] = { iso='jam', name='τζαμαϊκανά κρεολικά', cat='Τζαμαϊκανή κρεολική γλώσσα', link='Τζαμαϊκανά κρεολικά (jam)',
                   from='τζαμαϊκανής κρεολικής προέλευσης', frm='τζαμαϊκανή κρεολική', words='Τζαμαϊκανές κρεολικές λέξεις',
                   apo='την τζαμαϊκανή κρεολική', apota='από τα τζαμαϊκανά κρεολικά', wiki='', wikiExists=true, key='τζαμαικανακρεολικα' }
                   -- ή τζαμαϊκανά πατουά (Patwa, Patois)
Languages['jbo'] = { iso='jbo', name='λόζμπαν', cat='Γλώσσα λόζμπαν', link='Λόζμπαν (jbo)',
                   from='προέλευσης από τη γλώσσα λόζμπαν', frm='λόζμπαν', words='Λέξεις της γλώσσας λόζμπαν',
                   apo='τη γλώσσα λόζμπαν', apota='από τη γλώσσα λόζμπαν', wiki='', wikiExists=true, key='λοζμπαν' }
Languages['jv'] = { iso='jv', name='ιαβαϊκά', cat='Ιαβαϊκή γλώσσα', link='Ιαβαϊκά (jv)',
                   from='ιαβαϊκής προέλευσης', frm='ιαβαϊκή', words='Ιαβαϊκές λέξεις',
                   apo='την ιαβαϊκή', apota='από τα ιαβαϊκά', wiki='Ιαβαϊκή γλώσσα', wikiExists=true, key='ιαβαικα' }
Languages['ka'] = { iso='ka', name='γεωργιανά', cat='Γεωργιανή γλώσσα', link='Γεωργιανά (ka)',
                   from='γεωργιανής προέλευσης', frm='γεωργιανή', words='Γεωργιανές λέξεις',
                   apo='τη γεωργιανή', apota='από τα γεωργιανά', wiki='Γεωργιανή γλώσσα', wikiExists=true, key='γεωργιανα' }
Languages['kab'] = { iso='kab', name='καβυλικά', cat='Καβυλική γλώσσα', link='Καβυλικά (kab)',
                   from='καβυλικής προέλευσης', frm='καβυλική', words='Καβυλικές λέξεις',
                   apo='την καβυλική', apota='από τα καβυλικά', wiki='Καβυλική γλώσσα', wikiExists=false, key='καβυλικα' }
-- Καθαρεύουσα kath  status = 'main' για να έχει χωριστό index (βλ. απόφαση στην τεκμηρίωση)
-- is el-kth at [[wikt:en:Module:languages]]
Languages['kath'] = { iso='kath', name='καθαρεύουσα', cat='Καθαρεύουσα', link='Ελληνικά (el)',
	from='προέλευσης από την καθαρεύουσα', frm='καθαρεύουσα', words='Λέξεις της καθαρεύουσας',
	apo='την καθαρεύουσα', apota='από την καθαρεύουσα', wiki='Καθαρεύουσα', wikiExists=false, key='*καθαρευουσα',
	-- for auto cat
	sublang=true, regional=false, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*καθαρευουσα", apota_key="'καθαρευουσα" }
Languages['kbd'] = { iso='kbd', name='ανατολικά κιρκασιανά', cat='Ανατολική κιρκασιανή γλώσσα', link='Ανατολικά κιρκασιανά (kbd)',
                   from='προέλευσης από την ανατολική κιρκασιανή', frm='ανατολική κιρκασιανή', words='Ανατολικές κιρκασιανές λέξεις',
                   apo='την ανατολική κιρκασιανή', apota='από τα ανατολικά κιρκασιανά', wiki='Καμπαρντιανή γλώσσα', wikiExists=false, key='ανατολικακιρκασιανα' }
Languages['kg'] = { iso='kg', name='κoνγκό', cat='Γλώσσα κονγκό', link='Κoνγκό (kg)',
                   from='προέλευσης από τη γλώσσα κoνγκό', frm='κονγκό', words='Λέξεις της γλώσσας κoνγκό',
                   apo='τη γλώσσα κoνγκό', apota='από τη γλώσσα κονγκό', wiki='', wikiExists=false, key='κονγκο' }
Languages['kj'] = { iso='kj', name='κουανγιάμα', cat='Γλώσσα κουανγιάμα', link='Κουανγιάμα (kj)',
                   from='προέλευσης από τη γλώσσα κουανγιάμα', frm='κουανγιάμα', words='Λέξεις της γλώσσας κουανγιάμα',
                   apo='τη γλώσσα κουανγιάμα', apota='από τη γλώσσα κουανγιάμα', wiki='', wikiExists=false, key='κουανγιαμα' }
Languages['kk'] = { iso='kk', name='καζακικά', cat='Καζακική γλώσσα', link='Καζακικά (kk)',
                   from='καζακικής προέλευσης', frm='καζακική', words='Καζακικές λέξεις',
                   apo='την καζακική', apota='από τα καζακικά', wiki='Καζακική γλώσσα', wikiExists=true, key='καζακικα' }
Languages['kl'] = { iso='kl', name='γροιλανδικά', cat='Γροιλανδική γλώσσα', link='Γροιλανδικά (kl)',
                   from='γροιλανδικής προέλευσης', frm='γροιλανδική', words='Γροιλανδικές λέξεις',
                   apo='τη γροιλανδική', apota='από τα γροιλανδικά', wiki='Γροιλανδική γλώσσα', wikiExists=true, key='γροιλανδικα' }
Languages['km'] = { iso='km', name='χμερ', cat='Γλώσσα χμερ', link='Γλώσσα χμερ (km)',
                   from='προέλευσης από τη γλώσσα χμερ', frm='χμερ', words='Λέξεις της γλώσσας χμερ',
                   apo='τη γλώσσα χμερ', apota='από τη γλώσσα χμερ', wiki='Γλώσσα χμερ', wikiExists=true, key='χμερ' }
                   -- χμερ (ή καμποτζιανή γλώσσα)
Languages['kn'] = { iso='kn', name='κανάντα', cat='Γλώσσα κανάντα', link='Κανάντα (kn)',
                   from='προέλευσης από τη γλώσσα κανάντα', frm='κανάντα', words='Λέξεις της γλώσσας κανάντα',
                   apo='τη γλώσσα κανάντα', apota='από τη γλώσσα κανάντα', wiki='Κανάντα γλώσσα', wikiExists=true, key='καναντα' }
Languages['ko'] = { iso='ko', name='κορεατικά', cat='Κορεατική γλώσσα', link='Κορεατικά (ko)',
                   from='κορεατικής προέλευσης', frm='κορεατική', words='Κορεατικές λέξεις',
                   apo='την κορεατική', apota='από τα κορεατικά', wiki='Κορεατική γλώσσα', wikiExists=true, key='κορεατικα' }
Languages['krc'] = { iso='krc', name='καρατσάι μπαλκάρ', cat='Γλώσσα καρατσάι μπαλκάρ', link='Καρατσάι Μπαλκάρ (krc)',
                   from='προέλευσης από τη γλώσσα καρατσάι μπαλκάρ', frm='καρατσάι  μπαλκάρ', words='Λέξεις της γλώσσας καρατσάι μπαλκάρ',
                   apo='τη γλώσσα καρατσάι μπαλκάρ', apota='από τη γλώσσα καρατσάι μπαλκάρ', wiki='', wikiExists=false, key='καρατσαιμπαλκαρ' }
Languages['ks'] = { iso='ks', name='κασμιρικά', cat='Κασμιρική γλώσσα', link='Κασμιρικά (ks)',
                   from='κασμιρικής προέλευσης', frm='κασμιρική', words='Κασμιρικές λέξεις',
                   apo='την κασμιρική', apota='από τα κασμιρικά', wiki='Κασμιρική γλώσσα', wikiExists=true, key='κασμιρικα' }
Languages['ksh'] = { iso='ksh', name='κολωνικά', cat='Κολωνική γλώσσα', link='Κολωνικά (ksh)',
                   from='κολωνικής προέλευσης', frm='κολωνική', words='Κολωνικές λέξεις',
                   apo='τη κολωνική', apota='από τα ΄κολωνικά', wiki='Κολωνική γλώσσα', wikiExists=false, key='κολωνικα' }
Languages['ku'] = { iso='ku', name='κουρδικά', cat='Κουρδική γλώσσα', link='Κουρδικά (ku)',
                   from='κουρδικής προέλευσης', frm='κουρδική', words='Κουρδικές λέξεις',
                   apo='την κουρδική', apota='από τα κουρδικά', wiki='Κουρδική γλώσσα', wikiExists=true, key='κουρδικα' }
Languages['kw'] = { iso='kw', name='κορνουαλικά', cat='Κορνουαλική γλώσσα', link='Κορνουαλικά (kw)',
                   from='κορνουαλικής προέλευσης', frm='κορνουαλική', words='Κορνουαλικές λέξεις',
                   apo='την κορνουαλική', apota='από τα κορνουαλικά', wiki='Κορνουαλική γλώσσα', wikiExists=true, key='κορνουαλικα' }
Languages['ky'] = { iso='ky', name='κιργιζικά', cat='Κιργιζική γλώσσα', link='Κιργιζικά (ky)',
                   from='κιργιζικής προέλευσης', frm='κιργιζική', words='Κιργιζικές λέξεις',
                   apo='την κιργιζική', apota='από τα κιργιζικά', wiki='Κιργιζική γλώσσα', wikiExists=true, key='κιργιζικα' }
Languages['la'] = { iso='la', name='λατινικά', cat='Λατινική γλώσσα', link='Λατινικά (la)',
                   from='λατινικής προέλευσης', frm='λατινική', words='Λατινικές λέξεις',
                   apo='τη λατινική', apota='από τα λατινικά', wiki='Λατινική γλώσσα', wikiExists=true, key='λατινικα' }
Languages['la-ecc'] = { iso='la-ecc', name='εκκλησιαστικά λατινικά', cat='Εκκλησιαστικά λατινικά', link='Λατινικά (la)',
	from='εκκλησιαστικής λατινικής προέλευσης', frm='εκκλησιαστική λατινική', words='Εκκλησιαστικές λατινικές λέξεις',
	apo='την εκκλησιαστική λατινική', apota='από τα εκκλησιαστικά λατινικά', wiki='', wikiExists=false, key='λατινικαεκκλησιαστικα',
	-- for auto cat
	sublang=true, regional=false, host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+εκκλησιατικαλατινικα", apota_key="'εκκλησιαστικαλατινικα" }
Languages['la-lat'] = { iso='la-lat', name='υστερολατινικά', cat='Υστερολατινικά', link='Λατινικά (la)',
	from='υστερολατινικής προέλευσης', frm='υστερολατινική', words='Υστερολατινικές λέξεις',
	apo='την υστερολατινική', apota='από τα υστερολατινικά', wiki='', wikiExists=false, key='υστερολατινικα',
	-- for auto cat
	sublang=true, regional=false, host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+υστερολατινικα", apota_key="'υστερολατινικα"
}

Languages['la-med'] = { iso='la-med', name='μεσαιωνικά λατινικά', cat='Μεσαιωνικά λατινικά', link='Λατινικά (la)',
	from='μεσαιωνικής λατινικής προέλευσης', frm='μεσαιωνική λατινική', words='Μεσαιωνικές λατινικές λέξεις',
	apo='τη μεσαιωνική λατινική', apota='από τα μεσαιωνικά λατινικά', wiki='', wikiExists=false, key='μεσαιωνικαλατινικα',
	-- these keys handle the Category as in auto cat
	sublang=true, regional=false, host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+μεσαιωνικαλατινικα", apota_key="'μεσαιωνικαλατινικα" }
-- status main για να έχει χωριστό index (βλ. απόφαση στην τεκμηρίωση)
Languages['la-new'] = { iso='la-new', name='νεολατινικά', cat='Νεολατινικά', link='Λατινικά (la)',
	from='νεολατινικής προέλευσης', frm='νεολατινική', words='Νεολατινικές λέξεις',
	apo='τη νεολατινική', apota='από τα νεολατινικά', wiki='', wikiExists=false, key='νεολατινικα',
	-- for auto cat
	sublang=true, regional=false, status = 'main', host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+νεολατινικα", apota_key="'νεολατινικα" }
Languages['la-ren'] = { iso='la-ren', name='αναγεννησιακά λατινικά', cat='Αναγεννησιακά λατινικά', link='Λατινικά (la)',
	from='προέλευσης από την αναγεννησιακή λατινική', frm='αναγεννησιακή λατινική', words='Αναγεννησιακές λατινικές λέξεις',
	apo='την αναγεννησιακή λατινική', apota='από τα αναγεννησιακά λατινικά', wiki='', wikiExists=false, key='λατινικααναγεννησιακα',
	-- for auto cat
	sublang=true, regional=false, host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+αναγεννησιακαλατινικα", apota_key="'αναγεννησιακαλατινικα" }
Languages['la-vul'] = { iso='la-vul', name='δημώδη λατινικά', cat='Δημώδη λατινικά', link='Λατινικά (la)',
	from='δημώδους λατινικής προέλευσης', frm='δημώδης λατινική', words='Δημώδεις λατινικές λέξεις',
	apo='τη δημώδη λατινική', apota='από τα δημώδη λατινικά', wiki='Λαϊκή Λατινική γλώσσα', wikiExists=false, key='λατινικαδημωδη',
	-- for auto cat
	sublang=true, regional=false, host='Λατινική γλώσσα', host_show='Λατινικά', host_name='λατινικά', host_apota='από τα λατινικά', 
	host_iso='la', host_key="+δημωδηλατινικα", apota_key="'δημωδηλατινικα" }
Languages['lad'] = { iso='lad', name='εβραιοϊσπανικά', cat='Εβραιοϊσπανική γλώσσα', link='Εβραιοϊσπανικά (lad)',
                   from='εβραιοϊσπανικής προέλευσης', frm='εβραιοϊσπανική', words='Εβραιοϊσπανικές λέξεις',
                   apo='την εβραιοϊσπανική', apota='από τα εβραιοϊσπανικά', wiki='Ισπανοεβραϊκή γλώσσα', wikiExists=false, key='εβραιοισπανικα' }
                   -- lad (Ladino) = Judaeo-Spanish εβραιοϊσπανικά
Languages['lng'] = { iso='lng', name='λομβαρδικά', cat='Λομβαρδική γλώσσα', link='Λομβαρδικά (lb)',
                   from='λομβαρδικής προέλευσης', frm='λομβαρδική', words='Λομβαρδικέως λέξεις',
                   apo='τη λομβαρδική', apota='από τα λομβαρδικά', wiki='Λομβαρδική γλώσσα', wikiExists=true, key='λομβαρδικα' }
Languages['lb'] = { iso='lb', name='λουξεμβουργιανά', cat='Λουξεμβουργιανή γλώσσα', link='Λουξεμβουργιανά (lb)',
                   from='λουξεμβουργιανής προέλευσης', frm='λουξεμβουργιανή', words='Λουξεμβουργιανές λέξεις',
                   apo='τη λουξεμβουργιανή', apota='από τα λουξεμβουργιανά', wiki='Λουξεμβουργιανή γλώσσα', wikiExists=true, key='λουξεμβουργιανα' }
Languages['lbe'] = { iso='lbe', name='λακ', cat='Γλώσσα λακ', link='Λακ (lbe)',
                   from='προέλευσης από τη γλώσσα λακ', frm='γλώσσα λακ', words='Λέξεις της γλώσσας λακ',
                   apo='τη γλώσσα λακ', apota='από τη γλώσσα λακ', wiki='', wikiExists=false, key='λακ' }
Languages['li'] = { iso='li', name='λιμβουργιανά', cat='Λιμβουργιανή γλώσσα', link='Λιμβουργιανά (li)',
                   from='λιμβουργιανής προέλευσης', frm='λιμβουργιανή', words='Λιμβουργιανές λέξεις',
                   apo='τη λιμβουργιανή', apota='από τα λιμβουργιανά', wiki='Λιμβουργιανή γλώσσα', wikiExists=true, key='λιμβουργιανα' }
Languages['lij'] = { iso='lij', name='λιγουριανά', cat='Λιγουριανή γλώσσα', link='Λιγουριανά (lij)',
                   from='λιγουριανής προέλευσης', frm='λιγουριανή', words='Λιγουριανές λέξεις',
                   apo='τη λιγουριανή', apota='από τα λιγουριανά', wiki='Λιγουριανή γλώσσα', wikiExists=false, key='λιγουριανα' }
Languages['liv'] = { iso='liv', name='λιβονικά', cat='Λιβονική γλώσσα', link='Λιβονικά (liv)',
                   from='λιβονικής προέλευσης', frm='λιβονική', words='Λιβονικές λέξεις',
                   apo='τη λιβονική', apota='από τα λιβονικά', wiki='Λιβονική γλώσσα', wikiExists=false, key='λιβονικα' }
Languages['lkt'] = { iso='lkt', name='λακότα', cat='Γλώσσα λακότα', link='Λακότα (lkt)',
                   from='προέλευσης από τη γλώσσα λακότα', frm='λακότα', words='Λέξεις της γλώσσας λακότα',
                   apo='τη γλώσσα λακότα', apota='από τη γλώσσα λακότα', wiki='', wikiExists=false, key='λακοτα' }
Languages['lld'] = { iso='lld', name='λαδινικά', cat='Λαδινική γλώσσα', link='Λαδινικά (lld)',
                   from='λαδινικής προέλευσης', frm='λαδινική', words='Λαδινικές λέξεις',
                   apo='τη λαδινική', apota='από τα λαδινικά', wiki='Λαδινική γλώσσα', wikiExists=false, key='λαδινικα' }
Languages['lmo'] = { iso='lmo', name='λομβαρδικά', cat='Λομβαρδική γλώσσα', link='Λομβαρδικά (lmo)',
                   from='λομβαρδικής προέλευσης', frm='λομβαρδική', words='Λομβαρδικές λέξεις',
                   apo='τη λομβαρδική', apota='από τα λομβαρδικά', wiki='Λομβαρδική γλώσσα', wikiExists=false, key='λομβαρδικα' }
Languages['ln'] = { iso='ln', name='λινγκάλα', cat='Γλώσσα λινγκάλα', link='Λινγκάλα (ln)',
                   from='προέλευσης από τη γλώσσα λινγκάλα', frm='λινγκάλα', words='Λέξεις της γλώσσας λινγκάλα',
                   apo='τη γλώσσα λινγκάλα', apota='από τη γλώσσα λινγκάλα', wiki='', wikiExists=true, key='λινγκαλα' }
Languages['lo'] = { iso='lo', name='λαοτινά', cat='Λαοτινή γλώσσα', link='Λαοτινά (lo)',
                   from='λαοτινής προέλευσης', frm='λαοτινή', words='Λαοτινές λέξεις',
                   apo='τη λαοτινή', apota='από τα λαοτινά', wiki='Λαοτινή γλώσσα', wikiExists=true, key='λαοτινα' }
Languages['lt'] = { iso='lt', name='λιθουανικά', cat='Λιθουανική γλώσσα', link='Λιθουανικά (lt)',
                   from='λιθουανικής προέλευσης', frm='λιθουανική', words='Λιθουανικές λέξεις',
                   apo='τη λιθουανική', apota='από τα λιθουανικά', wiki='Λιθουανική γλώσσα', wikiExists=true, key='λιθουανικα' }
Languages['ltc'] = { iso='ltc', name='μέση κινεζική', cat='Μέση κινεζική γλώσσα', link='Κινεζικά (zh)',
                   from='προέλευσης από τη μέση κινεζική', frm='μέση κινεζική', words='Λέξεις της μέσης κινεζικής',
                   apo='τη μέση κινεζική', apota='από τη μέση κινεζική', wiki='', wikiExists=false, key='μεσηκινεζικη' }
Languages['lv'] = { iso='lv', name='λετονικά', cat='Λετονική γλώσσα', link='Λετονικά (lv)',
                   from='λετονικής προέλευσης', frm='λετονική', words='Λετονικές λέξεις',
                   apo='τη λετονική', apota='από τα λετονικά', wiki='Λετονική γλώσσα', wikiExists=true, key='λετονικα' }
Languages['mdf'] = { iso='mdf', name='μόκσα', cat='Γλώσσα μόκσα', link='Μόκσα (mdf)',
                   from='προέλευσης από τη γλώσσα μόκσα', frm='μόκσα', words='Λέξεις της γλώσσας μόκσα',
                   apo='τη γλώσσα μόκσα', apota='από τη γλώσσα μόκσα', wiki='', wikiExists=false, key='μοκσα' }
Languages['mg'] = { iso='mg', name='μαλγασικά', cat='Μαλγασική γλώσσα', link='Μαλγασικά (mg)',
                   from='μαλγασικής προέλευσης', frm='μαλγασική', words='Μαλγασικές λέξεις',
                   apo='τη μαλγασική', apota='από τα μαλγασικά', wiki='Μαλγασική γλώσσα', wikiExists=true, key='μαλγασικα' }
Languages['mi'] = { iso='mi', name='μάορι', cat='Γλώσσα μάορι', link='Μάορι (mi)',
                   from='προέλευσης από τη γλώσσα μάορι', frm='μάορι', words='Λέξεις της γλώσσας μάορι',
                   apo='τη γλώσσα μάορι', apota='από τη γλώσσα μάορι', wiki='Μάορι γλώσσα', wikiExists=true, key='μαορι' }
Languages['mk'] = { iso='mk', name='σλαβομακεδονικά', cat='Σλαβομακεδονική γλώσσα', link='Σλαβομακεδονικά (mk)',
                   from='σλαβομακεδονικής προέλευσης', frm='σλαβομακεδονική', words='Σλαβομακεδονικές λέξεις',
                   apo='τη σλαβομακεδονική', apota='από τα σλαβομακεδονικά', wiki='Σλαβομακεδονική γλώσσα', wikiExists=true, key='σλαβομακεδονικα' }
Languages['ml'] = { iso='ml', name='μαλαγιάλαμ', cat='Γλώσσα μαλαγιάλαμ', link='Μαλαγιάλαμ (ml)',
                   from='προέλευσης από τη γλώσσα μαλαγιάλαμ', frm='μαλαγιάλαμ', words='Λέξεις της γλώσσας μαλαγιάλαμ',
                   apo='τη γλώσσα μαλαγιάλαμ', apota='από τη γλώσσα μαλαγιάλαμ', wiki='Μαλαγιαλάμ', wikiExists=true, key='μαλαγιαλαμ' }
Languages['mlq'] = { iso='mlq', name='δυτικά μαλίνκε', cat='Γλώσσα δυτική μαλίνκε', link='Δυτική μαλίνκε (mlq)',
                   from='προέλευσης από τη δυτική μαλίνκε', frm='δυτική μαλίνκε', words='Λέξεις της δυτικής μαλίνκε',
                   apo='τη δυτική μαλίνκε', apota='από τα δυτικά μαλίνκε', wiki='Γλώσσα Μανίνκα', wikiExists=false, key='μαλινκε' }
Languages['mn'] = { iso='mn', name='μογγολικά', cat='Μογγολική γλώσσα', link='Μογγολικά (mn)',
                   from='μογγολικής προέλευσης', frm='μογγολική', words='Μογγολικές λέξεις',
                   apo='τη μογγολική', apota='από τα μογγολικά', wiki='Μογγολική γλώσσα', wikiExists=true, key='μογγολικα' }
Languages['mnc'] = { iso='mnc', name='μαντζουριανά', cat='Μαντζουριανή γλώσσα', link='Μαντζουριανά (mnc)',
                   from='μαντζουριανής προέλευσης', frm='μαντζουριανή', words='Μαντζουριανές λέξεις',
                   apo='τη μαντζουριανή', apota='από τα μαντζουριανά', wiki='Μαντζουριανή γλώσσα', wikiExists=false, key='μαντζουριανα' }
Languages['mns'] = { iso='mns', name='γλώσσα μάνσι', cat='Γλώσσα μάνσι', link='γλώσσα μάνσι (mns)', 
                   from='προέλευσης από τη γλώσσα μάνσι', frm='γλώσσα μάνσι', words='Λέξεις της γλώσσας μάνσι', 
                   apo='τη γλώσσα μάνσι', apota='από τη γλώσσα μάνσι', wiki='Μάνσι', wikiExists=true, key='μανσι' }
Languages['mo'] = { iso='mo', name='μολδαβικά', cat='Μολδαβική γλώσσα', link='Μολδαβικά (mo)',
                   from='μολδαβικής προέλευσης', frm='μολδαβική', words='Μολδαβικές λέξεις',
                   apo='τη μολδαβική', apota='από τα μολδαβικά', wiki='Μολδαβική γλώσσα', wikiExists=true, key='μολδαβικα' }
Languages['mr'] = { iso='mr', name='μαράθι', cat='Γλώσσα μαράθι', link='Μαράθι (mr)',
                   from='προέλευσης από τη γλώσσα μαράθι', frm='μαράθι', words='Λέξεις της γλώσσας μαράθι',
                   apo='τη γλώσσα μαράθι', apota='από τη γλώσσα μαράθι', wiki='Μαράτι (γλώσσα)', wikiExists=true, key='μαραθι' }
Languages['ms'] = { iso='ms', name='μαλαϊκά', cat='Μαλαϊκή γλώσσα', link='Μαλαϊκά (ms)',
                   from='μαλαϊκής προέλευσης', frm='μαλαϊκή', words='Μαλαϊκές λέξεις',
                   apo='τη μαλαϊκή', apota='από τα μαλαϊκά', wiki='Μαλαϊκή γλώσσα', wikiExists=true, key='μαλαικα' }
Languages['ms-ar'] = { iso='', name='μαλαισιακά-αραβική γραφή', cat='Μαλαισιακή γλώσσα-αραβική γραφή', link='Μαλαισιακά (ms)',
                   from='', frm='', words='',
                   apo='', wiki='', wikiExists=true, key='' }
Languages['mt'] = { iso='mt', name='μαλτέζικα', cat='Μαλτέζικη γλώσσα', link='Μαλτέζικα (mt)',
                   from='μαλτέζικης προέλευσης', frm='μαλτέζικη', words='Μαλτέζικες λέξεις',
                   apo='τη μαλτέζικη', apota='από τα μαλτέζικα', wiki='Μαλτεζική γλώσσα', wikiExists=true, key='μαλτεζικα' }
                   -- ως 'μαλτέζικα' στο https://europa.eu/european-union/about-eu/countries/member-countries/malta_el
Languages['mwl'] = { iso='mwl', name='μιραντέζ', cat='Γλώσσα μιραντέζ', link='Μιραντέζ (mwl)',
                   from='προέλευσης από τη γλώσσα μιραντέζ', frm='μιραντέζ', words='Λέξεις της γλώσσας μιραντέζ',
                   apo='τη γλώσσα μιραντέζ', apota='από τη γλώσσα μιραντέζ', wiki='', wikiExists=false, key='μιραντεζ' }
Languages['my'] = { iso='my', name='βιρμανικά', cat='Βιρμανική γλώσσα', link='Βιρμανικά (my)',
                   from='βιρμανικής προέλευσης', frm='βιρμανική', words='Βιρμανικές λέξεις',
                   apo='τη βιρμανική', apota='από τα βιρμανικά', wiki='Βιρμανική γλώσσα', wikiExists=true, key='βιρμανικα' }
Languages['mzn'] = { iso='mzn', name='μαζανταρανί', cat='Γλώσσα μαζανταρανί', link='Μαζανταρανί (mzn)',
                   from='προέλευσης από τη γλώσσα μαζανταρανί', frm='μαζανταρανί', words='Λέξεις της γλώσσας μαζανταρανί',
                   apo='τη γλώσσα μαζανταρανί', apota='από τη γλώσσα μαζανταρανί', wiki='Μαζανταρανί (γλώσσα)', wikiExists=false, key='μαζανταρανι' }
Languages['na'] = { iso='na', name='ναουρού', cat='Γλώσσα ναουρού', link='Ναουρού (na)',
                   from='προέλευσης από τη γλώσσα ναουρού', frm='ναουρού', words='Λέξεις της γλώσσας ναουρού',
                   apo='τη γλώσσα ναουρού', apota='από τη γλώσσα ναουρού', wiki='Ναουρού (γλώσσα)', wikiExists=true, key='ναουρου' }
Languages['nah'] = { iso='nah', name='νάουατλ', cat='Γλώσσα νάουατλ', link='Nάουατλ (nah)',
                   from='προέλευσης από τη γλώσσα νάουατλ', frm='νάουατλ', words='Λέξεις της γλώσσας νάουατλ',
                   apo='τη γλώσσα νάουατλ', apota='από τη γλώσσα νάουατλ', wiki='Γλώσσα Νάουατλ', wikiExists=false, key='ναουατλ' }
Languages['nap'] = { iso='nap', name='ναπολιτάνικα', cat='Ναπολιτάνικη γλώσσα', link='Ναπολιτάνικα (nap)',
                   from='ναπολιτάνικης προέλευσης', frm='ναπολιτάνικη', words='Ναπολιτάνικες λέξεις',
                   apo='τη ναπολιτάνικη', apota='από τα ναπολιτάνικα', wiki='', wikiExists=false, key='ναπολιτανικα' }
Languages['nb'] = { iso='nb', name='νορβηγικά μπούκμολ', cat='Νορβηγικά μπούκμολ', link='Νορβηγικά μπούκμολ (nb)',
	from='προέλευσης από τα νορβηγικά μπούκμολ', frm='νορβηγική μπούκμολ', words='Λέξεις της νορβηγικής μπούκμολ',
	apo='τη νορβηγική μπούκμολ', apota='από τα νορβηγικά μπούκμολ', wiki='', wikiExists=false, key='νορβηγικαμπουκμολ',
	-- for auto cat
	sublang=true, regional=false, status = "main", host='Νορβηγική γλώσσα', host_show='Νορβηγικά', host_name='νορβηγικά', host_apota='από τα νορβηγικά', 
	host_iso='no', host_key="+νορβηγικα", apota_key="'νεονορβηγικα" }
	-- bad wiki Μποκμάλ
Languages['nci'] = { iso='nci', name='κλασικά νάουατλ', cat='Κλασικά νάουατλ', link='Κλασικά νάουατλ (nci)',
                   from='προέλευσης από την κλασική νάουατλ', frm='κλασική νάουατλ', words='Λέξεις της κλασικής νάουατλ',
                   apo='την κλασική νάουατλ', apota='από τα κλασικά νάουατλ', wiki='', wikiExists=false, key='ναουατλκλασικη' }
Languages['nd'] = { iso='nd', name='βόρεια νδεμπέλε', cat='Γλώσσα βόρεια νδεμπέλε', link='Βόρεια νδεμπέλε (nd)',
                   from='προέλευσης από τη βόρεια νδεμπέλε', frm='βόρεια νδεμπέλε', words='Λέξεις της βόρειας νδεμπέλε',
                   apo='τη βόρεια νδεμπέλε', apota='από τα βόρεια νδεμπέλε', wiki='', wikiExists=false, key='βορειανδεμπελε' }
Languages['nds'] = { iso='nds', name='κάτω σαξονικά', cat='Κάτω σαξονική γλώσσα', link='Κάτω σαξονικά (nds)',
                   from='κάτω σαξονικής προέλευσης', frm='κάτω σαξονική', words='Κάτω σαξονικές λέξεις',
                   apo='την κάτω σαξονική', apota='από τα κάτω σαξονικά', wiki='', wikiExists=true, key='κατωσαξονικα' }
Languages['nds-nl'] = { iso='nds-nl', name='κάτω σαξονικά Ολλανδίας', cat='Κάτω σαξονική γλώσσα Ολλανδίας', link='Κάτω σαξονικά Ολλανδίας (nds-nl)',
                   from='ολλανδικής κάτω σαξονικής προέλευσης', frm='κάτω σαξονική Ολλανδίας', words='Ολλανδικές κάτω σαξονικές λέξεις',
                   apo='την κάτω σαξονική Ολλανδίας', apota='από τα κάτω σαξονικά ολλανδικά', wiki='', wikiExists=false, key='κατωσαξονικαολλανδιασ' }
Languages['ne'] = { iso='ne', name='νεπάλι', cat='Γλώσσα νεπάλι', link='Νεπάλι (ne)',
                   from='προέλευσης από τη γλώσσα νεπάλι', frm='νεπάλι', words='Λέξεις της γλώσσας νεπάλι',
                   apo='τη γλώσσα νεπάλι', apota='από τα νεπάλι', wiki='Νεπαλική γλώσσα', wikiExists=true, key='νεπαλι' }
Languages['new'] = { iso='new', name='νεβάρι', cat='Γλώσσα νεβάρι', link='Νεβάρι (new)',
                   from='προέλευσης από τη γλώσσα νεβάρι', frm='νεβάρι', words='Λέξεις της γλώσσας νεβάρι',
                   apo='τη γλώσσα νεβάρι', apota='από τη γλώσσα νεβάρι', wiki='Νεβάρι', wikiExists=false, key='νεβαρι' }
Languages['ngo'] = { iso='ngo', name='νγκόνι', cat='Γλώσσα νγκόνι', link='Νγκόνι (ngo)',
                   from='προέλευσης από τη γλώσσα νγκόνι', frm='νγκόνι', words='Λέξεις της γλώσσας νγκόνι',
                   apo='τη γλώσσα νγκόνι', apota='από τη γλώσσα νγκόνι', wiki='', wikiExists=false, key='νγκονι' }
Languages['nl'] = { iso='nl', name='ολλανδικά', cat='Ολλανδική γλώσσα', link='Ολλανδικά (nl)',
                   from='ολλανδικής προέλευσης', frm='ολλανδική', words='Ολλανδικές λέξεις',
                   apo='την ολλανδική', apota='από τα ολλανδικά', wiki='Ολλανδική γλώσσα', wikiExists=true, key='ολλανδικα' }
Languages['nn'] = { iso='nn', name='νεονορβηγικά', cat='Νεονορβηγικά', link='Νεονορβηγικά (nn)',
	from='νεονορβηγικής προέλευσης', frm='νεονορβηγική', words='Νεονορβηγικές λέξεις',
	apo='τη νεονορβηγική', apota='από τα νεονορβηγικά', wiki='Νεονορβηγική γλώσσα', wikiExists=true, key='νεονορβηγικα',
	-- for auto cat
	sublang=true, regional=false, status = "main", host='Νορβηγική γλώσσα', host_show='Νορβηγικά', host_name='νορβηγικά', host_apota='από τα νορβηγικά', 
	host_iso='no', host_key="+νορβηγικα", apota_key="'νεονορβηγικα" }
Languages['no'] = { iso='no', name='νορβηγικά', cat='Νορβηγική γλώσσα', link='Νορβηγικά (no)',
                   from='νορβηγικής προέλευσης', frm='νορβηγική', words='Νορβηγικές λέξεις',
                   apo='τη νορβηγική', apota='από τα νορβηγικά', wiki='Νορβηγική γλώσσα', wikiExists=true, key='νορβηγικα' }
                   -- 2 sublangs should be added: nb νορβηγικά μπούκμολ and nn νεονορβηγικά
Languages['non'] = { iso='non', name='παλαιά νορβηγικά', cat='Παλαιά νορβηγική γλώσσα', link='Παλαιά νορβηγική (non)',
                   from='προέλευσης από την παλαιά νορβηγική', frm='παλαιά νορβηγική', words='Λέξεις της παλαιάς νορβηγικής',
                   apo='την παλαιά νορβηγική', apota='από τα παλαιά νορβηγικά', wiki='Αρχαία σκανδιναβική γλώσσα', wikiExists=false, key='παλαιανορβηγικα' }
Languages['gmq-pro'] = { iso='gmq-pro', name='πρωτονορβηγικά', cat='Πρωτονορβηγική γλώσσα', link='Πρωτονορβηγική (gmq-pro)', 
			from='πρωτονορβηγικής προέλευσης', frm='πρωτονορβηγική', words='Λέξεις της πρωτονορβηγικής', 
			apo='την πρωτονορβηγική', apota='από τα πρωτονορβηγικά', wiki='Αρχαία σκανδιναβική γλώσσα', wikiExists=false, key='πρωτονορβηγικα' }
Languages['nov'] = { iso='nov', name='νόβιαλ', cat='Γλώσσα νόβιαλ', link='Νόβιαλ (nov)',
                   from='προέλευσης από τη γλώσσα νόβιαλ', frm='νόβιαλ', words='Λέξεις της γλώσσας νόβιαλ',
                   apo='τη γλώσσα νόβιαλ', apota='από τη γλώσσα νόβιαλ', wiki='', wikiExists=false, key='νοβιαλ' }
Languages['nr'] = { iso='nr', name='νότια νδεμπέλε', cat='Γλώσσα νότια νδεμπέλε', link='Νότια νδεμπέλε (nr)',
                   from='προέλευσης από τη νότια νδεμπέλε', frm='νότια νδεμπέλε', words='Λέξεις της νότιας νδεμπέλε',
                   apo='τη νότια νδεμπέλε', apota='από τα νότια νδεμπέλε', wiki='', wikiExists=false, key='νοταινδεμπελε' }
Languages['nrm'] = { iso='nrm', name='νορμανδικά', cat='Νορμανδική γλώσσα', link='Νορμανδικά (nrm)',
                   from='νορμανδικής προέλευσης', frm='νορμανδική', words='Νορμανδικές λέξεις',
                   apo='τη νορμανδική', apota='από τα νορμανδικά', wiki='Νορμανδική γλώσσα', wikiExists=false, key='νορμανδικα' }
Languages['nso'] = { iso='nso', name='βόρεια σότο', cat='Γλώσσα βόρεια σότο', link='Βόρεια σότο (nso)',
                   from='προέλευσης από τη βόρεια σότο', frm='βόρεια σότο', words='Λέξεις της βόρειας σότο',
                   apo='τη βόρεια σότο', apota='από τα βόρεια σότο', wiki='', wikiExists=false, key='βορειασοτο' }
Languages['nv'] = { iso='nv', name='ναβάχο', cat='Γλώσσα ναβάχο', link='Ναβάχο (nv)',
                   from='προέλευσης από τη γλώσσα ναβάχο', frm='ναβάχο', words='Λέξεις της γλώσσας ναβάχο',
                   apo='τη γλώσσα ναβάχο', apota='από τη γλώσσα ναβάχο', wiki='Γλώσσα Ναβάχο', wikiExists=false, key='ναβαχο' }
Languages['oc'] = { iso='oc', name='οξιτανικά', cat='Οξιτανική γλώσσα', link='Οξιτανικά (oc)',
                   from='οξιτανικής προέλευσης', frm='οξιτανική', words='Οξιτανικές λέξεις',
                   apo='την οξιτανική', apota='από τα οξιτανικά', wiki='Οξιτανική γλώσσα', wikiExists=true, key='οξιτανικα' }
                   -- όνομα: οξιτανικά, ποικιλίες ή άλλα ονόματα: προβηγκιανά (Provençal -δείτε και prv-), γασκονικά, εβραιοπροβηγκιανά
                   -- προέρχεται από: pro (παλαιά οξιτανική ή παλαιά προβηγκιανή)
Languages['och'] = { iso='och', name='παλαιά κινεζικά', cat='Κινεζική γλώσσα', link='Κινεζικά (zh)',
                   from='προέλευσης από την παλαιά κινεζική', frm='παλαιά κινεζική', words='Λέξεις της παλαιάς κινεζικής',
                   apo='την παλαιά κινεζική', apota='από τα παλαιά κινεζικά', wiki='Κινεζική γλώσσα', wikiExists=true, key='παλαιακινεζικα' }
Languages['oge'] = { iso='oge', name='παλαιά γεωργιανά', cat='Παλαιά γεωργιανή γλώσσα', link='Παλαιά γεωργιανά (one)',
                   from='προέλευσης από την παλαιά γεωργιανή', frm='παλαιά γεωργιανή', words='Παλαιές γεωργιανές λέξεις',
                   apo='την παλαιά γεωργιανή', apota='από τα παλαιά γεωργιανά', wiki='Γεωργιανή γλώσσα', wikiExists=true, key='παλαιαγεωργιανα' }
Languages['oj'] = { iso='oj', name='οτζίμπουε', cat='Γλώσσα οτζίμπουε', link='Οτζίμπουε (oj)',
                   from='προέλευσης από τη γλώσσα οτζίμπουε', frm='οτζίμπουε', words='Λέξεις της γλώσσας οτζίμπουε',
                   apo='τη γλώσσα οτζίμπουε', apota='από τη γλώσσα οτζίμπουε', wiki='', wikiExists=false, key='οτζιμπουε' }
Languages['om'] = { iso='om', name='ορόμο', cat='Γλώσσα ορόμο', link='Ορόμο (om)',
                   from='προέλευσης από τη γλώσσα ορόμο', frm='ορόμο', words='Λέξεις της γλώσσας ορόμο',
                   apo='τη γλώσσα ορόμο', apota='από τη γλώσσα ορόμο', wiki='', wikiExists=true, key='ορομο' }
Languages['or'] = { iso='or', name='ορίγια', cat='Γλώσσα ορίγια', link='Ορίγια (or)',
                   from='προέλευσης από τη γλώσσα ορίγια', frm='ορίγια', words='Λέξεις της γλώσσας ορίγια',
                   apo='τη γλώσσα ορίγια', apota='από τη γλώσσα ορίγια', wiki='Γλώσσα Όντια', wikiExists=true, key='οριγια' }
Languages['orv'] = { iso='orv', name='παλαιά ανατολική σλαβονική', cat='Παλαιά ανατολική σλαβονική γλώσσα', link='Παλαιά ανατολική σλαβονική (orv)',
                   from='προέλευσης από την παλαιά ανατολική σλαβονική', frm='παλαιά ανατολική σλαβονική', words='Λέξεις της παλαιάς ανατολικής σλαβονικής',
                   apo='την παλαιά ανατολική σλαβονική', apota='από την παλαιά ανατολική σλαβονική', wiki='Παλαιά ανατολική σλαβονική γλώσσα', wikiExists=true, key='παλαιαανατολικησλαβονικη' }                   
Languages['os'] = { iso='os', name='οσσετικά', cat='Οσσετική γλώσσα', link='Οσσετικά (os)',
                   from='οσσετικής προέλευσης', frm='οσσετική', words='Οσσετικές λέξεις',
                   apo='την οσσετική', apota='από τα οσσετικά', wiki='Οσετική γλώσσα', wikiExists=false, key='οσσετικα' }
Languages['osp'] = { iso='osp', name='παλαιά ισπανικά', cat='Παλαιά ισπανική γλώσσα', link='Παλαιά ισπανικά (osp)',
                   from='παλαιάς ισπανικής προέλευσης', frm='παλαιά ισπανική', words='Παλαιές ισπανικές λέξεις',
                   apo='την παλαιά ισπανική', apota='από τα παλαιά ισπανικά', wiki='Παλαιά ισπανική γλώσσα', wikiExists=false, key='παλαια ισπανικα' }                    
Languages['os-pro'] = { iso='os-pro', name='πρωτοοσσετικά', cat='Πρωτοοσσετική γλώσσα', link='Πρωτοοσσετικά (os)',
                   from='πρωτοοσσετικής προέλευσης', frm='πρωτοοσσετική', words='Πρωτοοσσετικές λέξεις',
                   apo='την πρωτοοσσετική', apota='από τα πρωτοοσσετικά', wiki='Πρωτοοσετική γλώσσα', wikiExists=false, key='πρωτοοσσετικα' }
Languages['osx'] = { iso='osx', name='παλαιά σαξονικά', cat='Παλαιά σαξονική γλώσσα', link='Παλαιά σαξονικά (osx)',
                   from='προέλευσης από την παλαιά σαξονική', frm='παλαιά σαξονική', words='Λέξεις της παλαιάς σαξονικής',
                   apo='την παλαιά σαξονική', apota='από τα παλαιά σαξονικά', wiki='', wikiExists=false, key='παλαιασαξονικα' }
					-- ή παλαιά γερμανική (λήμμα [[τίγκα]] Μπαμπινιώτης 2010: παλ. γερμ (σαξον)
Languages['ota'] = { iso='ota', name='οθωμανικά τουρκικά', cat='Οθωμανική τουρκική γλώσσα', link='Οθωμανικά τουρκικά (ota)', 
                   script='Arab',
                   from='οθωμανικής τουρκικής προέλευσης', frm='οθωμανική τουρκική', words='Οθωμανικές τουρκικές λέξεις',
                   apo='την οθωμανική τουρκική', apota='από τα οθωμανικά τουρκικά', wiki='Οθωμανική Τουρκική γλώσσα', wikiExists=false, key='οθωμανικα' }
Languages['otk'] = { iso='otk', name='παλαιά τουρκικά', cat='Παλαιά τουρκική γλώσσα', link='Παλαιά τουρκικά (otk)',
                   from='προέλευσης από την παλαιά τουρκική', frm='παλαιά τουρκική', words='Λέξεις της παλαιάς τουρκικής',
                   apo='την παλαιά τουρκική', apota='από τα παλαιά τουρκικά', wiki='en:Old Turkic language', wikiExists=false, key='παλαιατουρκικα' }
					-- ή αρχαία τουρκικά 7ος - 13ος αιώνας, Old Turcik
Languages['pa'] = { iso='pa', name='παντζάμπι', cat='Γλώσσα παντζάμπι', link='Παντζάμπι (pa)',
                   from='προέλευσης από τη γλώσσα παντζάμπι', frm='παντζάμπι', words='Λέξεις της γλώσσας παντζάμπι',
                   apo='τη γλώσσα παντζάμπι', apota='από τη γλώσσα παντζάμπι', wiki='Παντζάμπι', wikiExists=true, key='παντζαμπι' }
Languages['pal'] = { iso='pal', name='μέση περσική', cat='Μέση περσική γλώσσα', link='Μέση περσική (pal)',
                   from='προέλευσης από τη μέση περσική', frm='μέση περσική', words='Λέξεις της μέσης περσικής',
                   apo='τη μέση περσική', apota='από τη μέση περσική', wiki='Περσική γλώσσα', wikiExists=false, key='μεσηπερσικη' }
Languages['pam'] = { iso='pam', name='καπαμπάνγκαν', cat='Γλώσσα καπαμπάνγκαν', link='Καπαμπάνγκαν (pam)',
                   from='προέλευσης από τη γλώσσα καπαμπάνγκαν', frm='καπαμπάνγκαν', words='Λέξεις της γλώσσας καπαμπάνγκαν',
                   apo='τη γλώσσα καπαμπάνγκαν', apota='από τη γλώσσα καπαμπάνγκαν', wiki='', wikiExists=false, key='καπαμπανγκαν' }
Languages['pap'] = { iso='pap', name='παπιαμέντο', cat='Γλώσσα παπιαμέντο', link='Παπιαμέντο (pap)',
                   from='προέλευσης από τη γλώσσα παπιαμέντο', frm='παπιαμέντο', words='Λέξεις της γλώσσας παπιαμέντο',
                   apo='τη γλώσσα παπιαμέντο', apota='από τη γλώσσα παπιαμέντο', wiki='', wikiExists=false, key='παπιαμεντο' }
Languages['pdc'] = { iso='pdc', name='γερμανικά της Πενσυλβανίας', cat='Γερμανικά της Πενσυλβανίας', link='Γερμανικά της Πενσυλβανίας (pdc)',
                   from='προέλευσης από τη γερμανική της Πενσυλβανίας', frm='γερμανική της Πενσυλβανίας', words='Λέξεις της γερμανικής της Πενσυλβανίας',
                   apo='τη γερμανική της Πενσυλβανίας', apota='από τα γερμανικά της Πενσυλβανίας', wiki='', wikiExists=false, key='γερμανικαπενσυλβανιασ' }
Languages['peo'] = { iso='peo', name='αρχαία περσικά', cat='Αρχαία περσικά', link='Αρχαία περσικά (peo)',
                   from='αρχαίας περσικής προέλευσης', frm='αρχαία περσική', words='Αρχαίες περσικές λέξεις',
                   apo='την αρχαία περσική', apota='από τα αρχαία περσικά', wiki='Αρχαία περσική γλώσσα', wikiExists=false, key='αρχαιαπερσικα' }
Languages['pfl'] = { iso='pfl', name='γερμανικά του Παλατινάτου', cat='Γερμανικά του Παλατινάτου', link='Γερμανικά του Παλατινάτου (pfl)',
                   from='προέλευσης από τη γερμανική του Παλατινάτου', frm='γερμανική του Παλατινάτου', words='Λέξεις της γερμανικής του Παλατινάτου',
                   apo='τη γερμανική του Παλατινάτου', apota='από τα γερμανικά του Παλατινάτου', wiki='', wikiExists=false, key='γερμανικαπαλατινατου' }
Languages['phn'] = { iso='phn', name='φοινικικά', cat='Φοινικική γλώσσα', link='Φοινικικά (phn)',
                   from='φοινικικής προέλευσης', frm='φοινικική', words='Φοινικικές λέξεις',
                   apo='τη φοινικική', apota='από τα φοινικικά', wiki='Φοινικική γλώσσα', wikiExists=false, key='φοινικικα' }
Languages['pi'] = { iso='pi', name='πάλι', cat='Γλώσσα πάλι', link='Πάλι (pi)',
                   from='προέλευσης από τη γλώσσα πάλι', frm='πάλι', words='Λέξεις της γλώσσας πάλι',
                   apo='τη γλώσσα πάλι', apota='από τη γλώσσα πάλι', wiki='Πάλι', wikiExists=true, key='παλι' }
Languages['pl'] = { iso='pl', name='πολωνικά', cat='Πολωνική γλώσσα', link='Πολωνικά (pl)',
                   from='πολωνικής προέλευσης', frm='πολωνική', words='Πολωνικές λέξεις',
                   apo='την πολωνική', apota='από τα πολωνικά', wiki='Πολωνική γλώσσα', wikiExists=true, key='πολωνικα' }
Languages['pms'] = { iso='pms', name='πιεμοντέζικα', cat='Πιεμοντέζικη γλώσσα', link='Πιεμοντέζικα (pms)',
                   from='πιεμοντέζικης προέλευσης', frm='πιεμοντέζικη', words='Πιεμοντέζικες λέξεις',
                   apo='την πιεμοντέζικη', apota='από τα πιεμοντέζικα', wiki='', wikiExists=false, key='πιεμοντεζικα' }
Languages['pnb'] = { iso='pnb', name='δυτικά παντζάμπι', cat='Γλώσσα δυτική παντζάμπι', link='Δυτική παντζάμπι (pnb)',
                   from='προέλευσης από τη δυτική παντζάμπι', frm='δυτική παντζάμπι', words='Λέξεις της δυτικής παντζάμπι',
                   apo='τη δυτική παντζάμπι', apota='από τα δυτικά παντζάμπι', wiki='Γλώσσα Παντζάμπι', wikiExists=true, key='δυτικηπαντζαμπι' }
-- status main, regional
Languages['pnt'] = { iso='pnt', name='ποντιακά', cat='Ποντιακά', link='Ποντιακά (pnt)',
	from='ποντιακής προέλευσης', frm='ποντιακή', words='Ποντιακές λέξεις',
	apo='την ποντιακή', apota='από τα ποντιακά', wiki='Ποντιακή γλώσσα', wikiExists=false, key='*ποντιακα',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*ποντιακα", apota_key="'ποντιακα" }
Languages['pro'] = { iso='pro', name='παλαιά οξιτανικά', cat='Παλαιά οξιτανική γλώσσα', link='Παλαιά οξιτανικά (pro)',
                   from='προέλευσης από την παλαιά οξιτανική', frm='παλαιά οξιτανική', words='Λέξεις της παλαιάς οξιτανικής',
                   apo='την παλαιά οξιτανική', apota='από τα παλαιά οξιτανικά', wiki='', wikiExists=false, key='παλαιαοξιτανικα' }
                   -- άλλο όνομα: παλαιά προβηγκιανά (δείτε: oc οξιτανικά ή προβηγκιανά, frp γαλλοπροβηγκιανά και Ετυμολογική γλώσσα prv προβηγκιανά)
Languages['prv'] = { iso='prv', name='προβηγκιανά', cat='Προβηγκιανή γλώσσα', link='Προβηγκιανά (prv)',
                   from='προβηγκιανής προέλευσης', frm='προβηγκιανή', words='Προβηγκιανές λέξεις',
                   apo='την προβηγκιανή', apota='από τα προβηγκιανά', wiki='Προβηγκιανή γλώσσα', wikiExists=false, key='προβηγκιανα' }
                   -- Ετυμολογική γλώσσα με κωδικούς prv (ή oc-pro). Όνομα: Provençal
                   -- ΧΡΗΣΙΜΟΠΟΙΟΥΜΕ το pro (παλαιά οξιτανική  ή παλαιά προβηγκιανή με άλλο όνομα, ποικιλίες προβηγκιανή, γασκονική, εβραιοπροβηγκιανή)
                   -- και frp (γαλλοπροβηγκιανά)
Languages['pot'] = { iso='pot', name='Potawatomi', cat='Γλώσσα Potawatomi', link='Potawatomi (pot)',
                   from='', frm='', words='',
                   apo='', wiki='', wikiExists=false, key='ποταουατομι' }
Languages['pregrc'] = { iso='pregrc', name='προελληνική', cat='Προελληνική γλώσσα', link='Προελληνική γλώσσα (pregrc)',
                   from='προελληνικής προέλευσης', frm='προελληνική', words='Προελληνικές λέξεις',
                   apo='την προελληνική', apota='από την προελληνική', wiki='', wikiExists=false, key='προελληνικη' }
Languages['ps'] = { iso='ps', name='παστό', cat='Γλώσσα παστό', link='Παστό (ps)', script='Arab',
                   from='προέλευσης από τη γλώσσα παστό', frm='παστό', words='Λέξεις της γλώσσας παστό',
                   apo='τη γλώσσα παστό', apota='από τη γλώσσα παστό', wiki='Παστού', wikiExists=true, key='παστο' }
Languages['pt'] = { iso='pt', name='πορτογαλικά', cat='Πορτογαλική γλώσσα', link='Πορτογαλικά (pt)',
                   from='πορτογαλικής προέλευσης', frm='πορτογαλική', words='Πορτογαλικές λέξεις',
                   apo='την πορτογαλική', apota='από τα πορτογαλικά', wiki='Πορτογαλική γλώσσα', wikiExists=true, key='πορτογαλικα' }
Languages['qu'] = { iso='qu', name='κέτσουα', cat='Γλώσσα κέτσουα', link='Κέτσουα (qu)',
                   from='προέλευσης από τη γλώσσα κέτσουα', frm='κέτσουα', words='Λέξεις της γλώσσας κέτσουα',
                   apo='τη γλώσσα κέτσουα', apota='από τη γλώσσα κέτσουα', wiki='Γλώσσες Κέτσουα', wikiExists=true, key='κετσουα' }
                   -- Quechua language  Quechuan languages? Έχουμε λέξεις στην [[:Κατηγορία:Γλώσσα κέτσουα]]
Languages['qwe'] = { iso='qwe', name='γλώσσες κέτσουα', cat='Γλώσσες κέτσουα', link='',
                   from='προέλευσης από γλώσσες κέτσουα', frm='γλώσσες κέτσουα', words='Λέξεις των γλωσσών κέτσουα',
                   apo='τις γλώσσες κέτσουα', apota='από γλώσσες κέτσουα', wiki='Γλώσσες Κέτσουα', wikiExists=false, key='κετσουαγλωσσεσ', family=true }
                   -- qwe οικογένεια γλωσσών Quechuan languages
Languages['rap'] = { iso='rap', name='ράπα νούι', cat='Γλώσσα ράπα νούι', link='Ράπα νούι (rap)',
                   from='προέλευσης από τη γλώσσα ράπα νούι', frm='ράπα νούι', words='Λέξεις της γλώσσας ράπα νούι',
                   apo='τη γλώσσα ράπα νούι', apota='από τη γλώσσα ράπα νούι', wiki='Νησί του Πάσχα#Κατοίκηση-γλώσσα', wikiExists=false, key='ραπανουι' }
Languages['rm'] = { iso='rm', name='ραιτορομανικά', cat='Ραιτορομανική γλώσσα', link='Ραιτορομανικά (rm)',
                   from='ραιτορομανικής προέλευσης', frm='ραιτορομανική', words='Ραιτορομανικές λέξεις',
                   apo='τη ραιτορομανική', apota='από τα ραιτορομανικά', wiki='Ραιτορομανική γλώσσα', wikiExists=false, key='ραιτορομανικα' }
Languages['rn'] = { iso='rn', name='κιρούντι', cat='Γλώσσα κιρούντι', link='Κιρούντι (rn)',
                   from='προέλευσης από τη γλώσσα κιρούντι', frm='κιρούντι', words='Λέξεις της γλώσσας κιρούντι',
                   apo='τη γλώσσα κιρούντι', apota='από τη γλώσσα κιρούντι', wiki='', wikiExists=false, key='κιρουντι' }
Languages['ro'] = { iso='ro', name='ρουμανικά', cat='Ρουμανική γλώσσα', link='Ρουμανικά (ro)',
                   from='ρουμανικής προέλευσης', frm='ρουμανική', words='Ρουμανικές λέξεις',
                   apo='τη ρουμανική', apota='από τα ρουμανικά', wiki='Ρουμανική γλώσσα', wikiExists=true, key='ρουμανικα' }
Languages['roa-opt'] = { iso='roa-opt', name='παλαιά πορτογαλικά', cat='Παλαιά πορτογαλικά', link='Παλαιά πορτογαλικά (roa-opt)',
                   from='προέλευσης από την παλαιά πορτογαλική', frm='παλαιά πορτογαλική', words='Λέξεις της παλαιάς πορτογαλικής',
                   apo='την παλαιά πορτογαλική', apota='από τα παλαιά πορτογαλικά', wiki='', wikiExists=false, key='παλαιαπορτογαλικα' }
Languages['roa-rup'] = { iso='roa-rup', name='αρωμουνικά', cat='Αρωμουνική γλώσσα', link='Αρωμουνικά (βλάχικα) (roa-rup)',
                   from='αρωμουνικής προέλευσης', frm='αρωμουνική', words='Αρωμουνικές λέξεις',
                   apo='την αρωμουνική', apota='από τα αρωμουνικά', wiki='Βλάχικη γλώσσα', wikiExists=true, key='αρωμουνικα' }
Languages['roa-tara'] = { iso='roa-tara', name='ταραντίνο', cat='Γλώσσα ταραντίνο', link='Ταραντίνο (roa-tara)',
                   from='προέλευσης από τη γλώσσα ταραντίνο', frm='ταραντίνο', words='Λέξεις της γλώσσας ταραντίνο',
                   apo='τη γλώσσα ταραντίνο', apota='από τα ταραντίνο', wiki='', wikiExists=false, key='ταραντινο' }
Languages['rom'] = { iso='rom', name='ρομανί', cat='Γλώσσα ρομανί', link='Ρομανί (rom)',
                   from='προέλευσης από τη γλώσσα ρομανί', frm='ρομανί', words='Λέξεις της γλώσσας ρομανί',
                   apo='τη γλώσσα ρομανί', apota='από τα ρομανί', wiki='', wikiExists=false, key='ρομανι' }
Languages['ru'] = { iso='ru', name='ρωσικά', cat='Ρωσική γλώσσα', link='Ρωσικά (ru)',
                   from='ρωσικής προέλευσης', frm='ρωσική', words='Ρωσικές λέξεις',
                   apo='τη ρωσική', apota='από τα ρωσικά', wiki='Ρωσική γλώσσα', wikiExists=true, key='ρωσικα' }
Languages['rue'] = { iso='rue', name='ρουθηνικά', cat='Ρουθηνική γλώσσα', link='Ρουθηνικά (rue)',
                   from='ρουθηνικής προέλευσης', frm='ρουθηνική', words='Ρουθηνικές λέξεις',
                   apo='τη ρουθηνική', apota='από τα ρουθηνικά', wiki='Ρουθηνικά', wikiExists=false, key='ρουθηνικα' }
Languages['rw'] = { iso='rw', name='κινιαρουάντα', cat='Γλώσσα κινιαρουάντα', link='Κινιαρουάντα (rw)',
                   from='προέλευσης από τη γλώσσα κινιαρουάντα', frm='κινιαρουάντα', words='Λέξεις της γλώσσας κινιαρουάντα',
                   apo='τη γλώσσα κινιαρουάντα', apota='από τη γλώσσα κινιαρουάντα', wiki='', wikiExists=true, key='κινιαρουαντα' }
Languages['sa'] = { iso='sa', name='σανσκριτικά', cat='Σανσκριτική γλώσσα', link='Σανσκριτικά (sa)',
                   from='σανσκριτικής προέλευσης', frm='σανσκριτική', words='Σανσκριτικές λέξεις',
                   apo='τη σανσκριτική', apota='από τα σανσκριτικά', wiki='Σανσκριτική γλώσσα', wikiExists=true, key='σανσκριτικα' }
Languages['sah'] = { iso='sah', name='γιακουτικά', cat='Γιακουτική γλώσσα', link='Γιακουτικά (sah)',
                   from='γιακουτικής προέλευσης', frm='γιακουτική', words='Γιακουτικές λέξεις',
                   apo='τη γιακουτική', apota='από τα γιακουτικά', wiki='Γιακουτική γλώσσα', wikiExists=false, key='γιακουτικα' }
Languages['sc'] = { iso='sc', name='σαρδηνιακά', cat='Σαρδηνιακή γλώσσα', link='Σαρδηνιακά (sc)',
                   from='σαρδηνιακής προέλευσης', frm='σαρδηνιακή', words='Σαρδηνιακές λέξεις',
                   apo='τη σαρδηνική', apota='από τα σαρδηνιακά', wiki='', wikiExists=false, key='σαρδηνιακα' }
Languages['scn'] = { iso='scn', name='σικελικά', cat='Σικελική γλώσσα', link='Σικελικά (scn)',
                   from='σικελικής προέλευσης', frm='σικελική', words='Σικελικές λέξεις',
                   apo='τη σικελική', apota='από τα σικελικά', wiki='Σικελική γλώσσα', wikiExists=true, key='σικελικα' }
Languages['sco'] = { iso='sco', name='σκοτς', cat='Γλώσσα σκοτς', link='Σκοτς (sco)',
                   from='προέλευσης από τη γλώσσα σκοτς', frm='σκοτς', words='Λέξεις της γλώσσας σκοτς',
                   apo='τη γλώσσα σκοτς', apota='από τη γλώσσα σκοτς', wiki='Σκωτς γλώσσα', wikiExists=false, key='σκοτσ' }
Languages['sd'] = { iso='sd', name='Sindhi', cat='Γλώσσα Sindhi', link='Sindhi (sd)',
                   from='προέλευσης από τη γλώσσα Sindhi', frm='από τη γλώσσα Sindhi', words='Λέξεις της γλώσσες Sindhi',
                   apo='τη γλώσσα Sinhdi', apota='από τη γλώσσα Sinhdi', wiki='Γλώσσα Σίντι', wikiExists=true, key='σιντι' }
Languages['se'] = { iso='se', name='βόρεια λαπωνικά', cat='Βόρεια λαπωνική γλώσσα', link='Βόρεια λαπωνικά (se)',
                   from='βόρειας λαπωνικής προέλευσης', frm='βόρεια λαπωνική', words='Βόρειες λαπωνικές λέξεις',
                   apo='τη βόρεια λαπωνική', apota='από τα βόρεια λαπωνικά', wiki='Βόρεια λαπωνική γλώσσα', wikiExists=false, key='βορειαλαπωνικα' }
Languages['see'] = { iso='see', name='σενέκα', cat='Γλώσσα σενέκα', link='Σενέκα (see)',
                   from='προέλευσης από τη γλώσσα σενέκα', frm='σενέκα', words='Λέξεις της γλώσσας σενέκα',
                   apo='τη γλώσσα σενέκα', apota='από τη γλώσσα σενέκα', wiki='', wikiExists=false, key='σενεκα' }
Languages['sei'] = { iso='sei', name='σέρι', cat='Γλώσσα σέρι', link='Σέρι (sei)',
                   from='προέλευσης από τη γλώσσα σέρι', frm='σέρι', words='Λέξεις της γλώσσας σέρι',
                   apo='τη γλώσσα σέρι', apota='από τη γλώσσα σέρι', wiki='Σέρι', wikiExists=false, key='σερι' }
Languages['sem'] = { iso='sem', name='σημιτικές γλώσσες', cat='Σημιτικές γλώσσες', link='',
                   from='σημιτικής προέλευσης', frm='σημιτική', words='Σημιτικές λέξεις',
                   apo='σημιτικές γλώσσες', apota='από σημιτικές γλώσσες', wiki='Σημιτικές γλώσσες', wikiExists=false, key='σημιτικα', family=true }
                   -- sem οικογένεια σημιτικών γλωσσών
Languages['sem-can'] = { iso='sem-can', name='χαναανικά', cat='Χαναανική γλώσσα', link='Χαναανικά (sem-can)',
                   from='χαναανικής προέλευσης', frm='χαναανική', words='Χαναανικές λέξεις',
                   apo='τη χαναανική', apota='από τα χαναανικά', wiki='Χαναανικές γλώσσες', wikiExists=false, key='χαναανικα' }
Languages['sem-pro'] = { iso='sem-pro', name='πρωτοσημιτική', cat='Πρωτοσημιτική γλώσσα', link='Πρωτοσημιτική γλώσσα (sem-pro)',
                   from='πρωτοσημιτικής προέλευσης', frm='πρωτοσημιτική', words='Πρωτοσημιτικές λέξεις',
                   apo='την πρωτοσημιτική', apota='από την πρωτοσημιτική', wiki='', wikiExists=false, key='πρωτοσημιτικη' }
Languages['sg'] = { iso='sg', name='σάνγκο', cat='Γλώσσα σάνγκο', link='Σάνγκο (sg)',
                   from='προέλευσης από τη γλώσσα σάνγκο', frm='σάνγκο', words='Λέξεις της γλώσσας σάνγκο',
                   apo='τη γλώσσα σάνγκο', apota='από τη γλώσσα σάνγκο', wiki='', wikiExists=true, key='σανγκο' }
Languages['sga'] = { iso='sga', name='παλαιά ιρλανδικά', cat='Παλαιά ιρλανδική γλώσσα', link='Παλαιά ιρλανδικά (sga)',
                   from='προέλευσης από την παλαιά ιρλανδική', frm='παλαιά ιρλανδικά', words='Λέξεις της παλαιάς ιρλανδικής', 
                   apo='την παλαιά ιρλανδική', apota='από τα παλαιά ιρλανδικά', wiki='', wikiExists=false, key='παλαια ιρλανδικη' }
Languages['sh'] = { iso='sh', name='σερβοκροατικά', cat='Σερβοκροατική γλώσσα', link='Σερβοκροατικά (sh)',
                   from='σερβοκροατικής προέλευσης', frm='σερβοκροατική', words='Σερβοκροατικές λέξεις',
                   apo='τη σερβοκροατική', apota='από τα σερβοκροατικά', wiki='Σερβοκροατική γλώσσα', wikiExists=true, key='σερβοκροατικα' }
Languages['si'] = { iso='si', name='σιναλεζικά', cat='Σιναλεζική γλώσσα', link='Σιναλεζικά (si)',
                   from='σιναλεζικής προέλευσης', frm='σιναλεζική', words='Σιναλεζικές λέξεις',
                   apo='τη σιναλεζική', apota='από τα σιναλεζικά', wiki='Σιναλεζική γλώσσα', wikiExists=true, key='σιναλεζικα' }
Languages['sk'] = { iso='sk', name='σλοβακικά', cat='Σλοβακική γλώσσα', link='Σλοβακικά (sk)',
                   from='σλοβακικής προέλευσης', frm='σλοβακική', words='Σλοβακικές λέξεις',
                   apo='τη σλοβακική', apota='από τα σλοβακικά', wiki='Σλοβακική γλώσσα', wikiExists=true, key='σλοβακικα' }
Languages['sl'] = { iso='sl', name='σλοβενικά', cat='Σλοβενική γλώσσα', link='Σλοβενικά (sl)',
                   from='σλοβενικής προέλευσης', frm='σλοβενική', words='Σλοβενικές λέξεις',
                   apo='τη σλοβενική', apota='από τα σλοβενικά', wiki='Σλοβενική γλώσσα', wikiExists=true, key='σλοβενικα' }
Languages['sla'] = { iso='sla', name='σλαβικές γλώσσες', cat='Σλαβικές γλώσσες', link='',
                   from='σλαβικής προέλευσης', frm='σλαβική', words='Σλαβικές λέξεις',
                   apo='σλαβικές γλώσσες', apota='από σλαβικές γλώσσες', wiki='Σλαβικές γλώσσες', wikiExists=false, key='σλαβικα', family=true }
					-- sla οικογένεια γλωσσών
Languages['sla-pro'] = { iso='sla-pro', name='πρωτοσλαβική', cat='Πρωτοσλαβική γλώσσα', link='Πρωτοσλαβική γλώσσα (sla-pro)',
                   from='πρωτοσλαβικής προέλευσης', frm='πρωτοσλαβική', words='Πρωτοσλαβικές λέξεις',
                   apo='την πρωτοσλαβική', apota='από την πρωτοσλαβική', wiki='', wikiExists=false, key='πρωτοσλαβικη' }
Languages['ine-bsl-pro'] = { iso='ine-bsl-pro', name='πρωτοβαλτοσλαβική', cat='Πρωτοβαλτοσλαβική γλώσσα', link='Πρωτοβαλτοσλαβική γλώσσα (ine-bsl-pro)',
                   from='πρωτοβαλτοσλαβικής προέλευσης', frm='πρωτοβαλτοσλαβική', words='Πρωτοβαλτοσλαβικές λέξεις',
                   apo='την πρωτοβαλτοσλαβική', apota='από την πρωτοβαλτοσλαβική', wiki='', wikiExists=false, key='πρωτοβαλτοσλαβικη' }
Languages['sm'] = { iso='sm', name='σαμοανικά', cat='Σαμοανική γλώσσα', link='Σαμοανικά (sm)',
                   from='σαμοανικής προέλευσης', frm='σαμοανική', words='Σαμοανικές λέξεις',
                   apo='τη σαμοανική', apota='από τα σαμοανικά', wiki='Σαμόα (γλώσσα)', wikiExists=true, key='σαμοανικα' }
Languages['smn'] = { iso='smn', name='λαπωνικά ινάρι', cat='Λαπωνικά ινάρι', link='Λαπωνικά ινάρι (smn)',
                   from='προέλευσης από τη λαπωνική γλώσσα ινάρι', frm='λαπωνική ινάρι', words='Λέξεις της λαπωνικής γλώσσας ινάρι',
                   apo='τη λαπωνική ινάρι', apota='από τα λαπωνικά ινάρι', wiki='en:Inari Sami language', wikiExists=false, key='λαπωνικαιναρι' }
Languages['smi'] = { iso='smi', name='λαπωνικές γλώσσες', cat='Λαπωνικές γλώσσες', link='',
                   from='λαπωνικής προέλευσης', frm='λαπωνική', words='Λαπωνικές λέξεις',
                   apo='λαπωνικές γλώσσες', apota='από λαπωνικές γλώσσες', wiki='Σάμι γλώσσες', wikiExists=false, key='λαπωνικα', family=true }
                   -- smi Sami languages οικογένεια λαπωνικών (Sami ή Saami) γλωσσών
Languages['sn'] = { iso='sn', name='σόνα', cat='Γλώσσα σόνα', link='Σόνα (sn)',
                   from='προέλευσης από τη γλώσσα σόνα', frm='σόνα', words='Λέξεις της γλώσσας σόνα',
                   apo='τη γλώσσα σόνα', apota='από τη γλώσσα σόνα', wiki='Γλώσσα Σόνα', wikiExists=false, key='σονα' }
Languages['so'] = { iso='so', name='σομαλικά', cat='Σομαλική γλώσσα', link='Σομαλικά (so)',
                   from='σομαλικής προέλευσης', frm='σομαλική', words='Σομαλικές λέξεις',
                   apo='τη σομαλική', apota='από τα σομαλικά', wiki='Σομαλική γλώσσα', wikiExists=true, key='σομαλικα' }
Languages['sq'] = { iso='sq', name='αλβανικά', cat='Αλβανική γλώσσα', link='Αλβανικά (sq)',
                   from='αλβανικής προέλευσης', frm='αλβανική', words='Αλβανικές λέξεις',
                   apo='την αλβανική', apota='από τα αλβανικά', wiki='Αλβανική γλώσσα', wikiExists=true, key='αλβανικα' }
Languages['sqj-pro'] = { iso='sqj-pro', name='πρωτοαλβανική', cat='Πρωτοαλβανική γλώσσα', link='Πρωτοαλβανική γλώσσα (sqj-pro)',
                   from='πρωτοαλβανικής προέλευσης', frm='πρωτοαλβανική', words='Πρωτοαλβανικές λέξεις',
                   apo='την πρωτοαλβανική', apota='από την πρωτοαλβανική', wiki='', wikiExists=false, key='πρωτοαλβανικη' }
Languages['sr'] = { iso='sr', name='σερβικά', cat='Σερβική γλώσσα', link='Σερβικά (sr)',
                   from='σερβικής προέλευσης', frm='σερβική', words='Σερβικές λέξεις',
                   apo='τη σερβική', apota='από τα σερβικά', wiki='Σερβική γλώσσα', wikiExists=true, key='σερβικα' }
-- status main για τη διπλή γραφή της
Languages['sr-la'] = { iso='sr-la', name='σερβικά-λατινικό αλφάβητο', cat='Σερβική γλώσσα - λατινικό αλφάβητο', link='Σερβική γλώσσα (sr)',
	from='σερβικής προέλευσης', frm='σερβική - λατινικό αλφάβητο', words='Σερβικές λέξεις - λατινικό αλφάβητο',
	apo='τη σερβική - λατινικό αλφάβητο', apota='από τα σερβικά - λατινικό αλφάβητο', wiki='', wikiExists=false, key='σερβικηλατινικοαλφαβητο', 
	-- for auto cat sublang=true,  CREATES PROBLEM WITH DASH? no
	sublang=true, regional=false, status = 'main', host='Σερβική γλώσσα', host_show='Σερβικά', host_name='σερβικά', host_apota='από τα σερβικά', 
	host_iso='sr', host_key="+λατινικοσερβικα", apota_key="'λατινικοσερβικα" }
	-- υπαγόμενη γραφή
Languages['srn'] = { iso='srn', name='σράναν', cat='Γλώσσα σράναν', link='Σράναν (srn)',
                   from='προέλευσης από τη γλώσσα σράναν', frm='σράναν', words='Λέξεις της γλώσσας σράναν',
                   apo='τη γλώσσα σράναν', apota='από τη γλώσσα σράναν', wiki='', wikiExists=false, key='σραναν' }
Languages['ss'] = { iso='ss', name='σουάζι', cat='Γλώσσα σουάζι', link='Σουάζι (ss)',
                   from='προέλευσης από τη γλώσσα σουάζι', frm='σουάζι', words='Λέξεις της γλώσσας σουάζι',
                   apo='τη γλώσσα σουάζι', apota='από τη γλώσσα σουάζι', wiki='', wikiExists=true, key='σουαζι' }
Languages['st'] = { iso='st', name='νότια σότο', cat='Γλώσσα νότια σότο', link='Νότια σότο (st)',
                   from='προέλευσης από τη νότια σότο', frm='νότια σότο', words='Λέξεις της νότιας σότο',
                   apo='τη νότια σότο', apota='από τα νότια σότο', wiki='', wikiExists=true, key='νοτιασοτο' }
Languages['stq'] = { iso='stq', name='ανατολικά φριζικά', cat='Ανατολική φριζική γλώσσα', link='Ανατολικά φριζικά (stq)',
                   from='προέλευσης από την ανατολική φριζική', frm='ανατολική φριζική', words='Λέξεις της ανατολικής φριζικής',
                   apo='την ανατολική φριζική', apota='από τα ανατολικά φριζικά', wiki='Φριζικές γλώσσες', wikiExists=false, key='ανατολικαφριζικα' }
Languages['su'] = { iso='su', name='σουνδανικά', cat='Σουνδανική γλώσσα', link='Σουνδανικά (su)',
                   from='σουνδανικής προέλευσης', frm='σουνδανική', words='Σουνδανικές λέξεις',
                   apo='τη σουδανική', apota='από τα σουδανικά', wiki='', wikiExists=true, key='σουδανικα' }
Languages['sux'] = { iso='sux', name='σουμεριακά', cat='Σουμεριακή γλώσσα', link='Σουμεριακά (sux)',
                   from='σουμεριακής προέλευσης', frm='σουμεριακή', words='Σουμεριακές λέξεις',
                   apo='τη σουμεριακή', apota='από τα σουμεριακά', wiki='Σουμεριακή γλώσσα', wikiExists=false, key='σουμεριακα' }
Languages['sv'] = { iso='sv', name='σουηδικά', cat='Σουηδική γλώσσα', link='Σουηδικά (sv)',
                   from='σουηδικής προέλευσης', frm='σουηδική', words='Σουηδικές λέξεις',
                   apo='τη σουηδική', apota='από τα σουηδικά', wiki='Σουηδική γλώσσα', wikiExists=true, key='σουηδικα' }
Languages['sw'] = { iso='sw', name='σουαχίλι', cat='Γλώσσα σουαχίλι', link='Σουαχίλι (sw)',
                   from='προέλευσης από τη γλώσσα σουαχίλι', frm='σουαχίλι', words='Λέξεις της γλώσσας σουαχίλι',
                   apo='τη γλώσσα σουαχίλι', apota='από τα σουαχίλι', wiki='Σουαχίλι γλώσσα', wikiExists=true, key='σουαχιλι' }
Languages['syc'] = { iso='syc', name='κλασικά συριακά', cat='Κλασικά συριακά', link='Κλασικά συριακά (syc)',
                   from='προέλευσης από την κλασική συριακή', frm='κλασική συριακή', words='Λέξεις της κλασικής συριακής',
                   apo='την κλασική συριακή', apota='από τα κλασικά συριακά', wiki='', wikiExists=false, key='συρικακλασικα' }     
Languages['ta'] = { iso='ta', name='ταμίλ', cat='Γλώσσα ταμίλ', link='Ταμίλ (ta)',
                   from='προέλευσης από τη γλώσσα ταμίλ', frm='ταμίλ', words='Λέξεις της γλώσσας ταμίλ',
                   apo='τη γλώσσα ταμίλ', apota='από τη γλώσσα ταμίλ', wiki='Ταμίλ γλώσσα', wikiExists=true, key='ταμιλ' }
Languages['te'] = { iso='te', name='τελούγκου', cat='Γλώσσα τελούγκου', link='Τελούγκου (te)',
                   from='προέλευσης από τη γλώσσα τελούγκου', frm='τελούγκου', words='Λέξεις της γλώσσας τελούγκου',
                   apo='τη γλώσσα τελούγκου', apota='από τη γλώσσα τελούγκου', wiki='Τελούγκου', wikiExists=true, key='τελουγκου' }
Languages['tet'] = { iso='tet', name='τετούμ', cat='Γλώσσα τετούμ', link='Τετούμ (tet)',
                   from='προέλευσης από τη γλώσσα τετούμ', frm='τετούμ', words='Λέξεις της γλώσσας τετούμ',
                   apo='τη γλώσσα τετούμ', apota='από τη γλώσσα τετούμ', wiki='', wikiExists=false, key='τετουμ' }
Languages['tg'] = { iso='tg', name='τατζικικά', cat='Τατζικική γλώσσα', link='Τατζικικά (tg)',
                   from='τατζικικής προέλευσης', frm='τατζικική', words='Τατζικικές λέξεις',
                   apo='την τατζικική', apota='από τα τατζικικά', wiki='Τατζίκ γλώσσα', wikiExists=true, key='τατζικικα' }
Languages['th'] = { iso='th', name='ταϊλανδικά', cat='Ταϊλανδική γλώσσα', link='Ταϊλανδικά (th)',
                   from='ταϊλανδικής προέλευσης', frm='ταϊλανδική', words='Ταϊλανδικές λέξεις',
                   apo='την ταϊλανδικη', apota='από τα ταϊλανδικά', wiki='Ταϊλανδική γλώσσα', wikiExists=true, key='ταιλανδικα' }
Languages['ti'] = { iso='ti', name='τιγκρίνια', cat='Γλώσσα τιγκρίνια', link='Τιγκρίνια (ti)',
                   from='προέλευσης από τη γλώσσα τιγκρίνια', frm='τιγκρίνια', words='Λέξεις της γλώσσας τιγκρίνια',
                   apo='τη γλώσσα τιγκρίνια', apota='από τη γλώσσα τιγκρίνια', wiki='Τιγκριανική γλώσσα', wikiExists=true, key='τιγκρινια' }
Languages['tk'] = { iso='tk', name='τουρκμενικά', cat='Τουρκμενική γλώσσα', link='Τουρκμενικά (tk)',
                   from='τουρκμενικής προέλευσης', frm='τουρκμενική', words='Τουρκμενικές λέξεις',
                   apo='την τουρκμενική', apota='από τα τουρκμενικά', wiki='Τουρκμενική γλώσσα', wikiExists=true, key='τουρκμενικα' }
Languages['tmh'] = { iso='tmh', name='τουαρέγκ', cat='Γλώσσα τουαρέγκ', link='Τουαρέγκ (tmh)',
                   from='προέλευσης από τη γλώσσα τουαρέγκ', frm='τουαρέγκ', words='Λέξεις της γλώσσας τουαρέγκ',
                   apo='τη γλώσσα τουαρέγκ', apota='από τη γλώσσα τουαρέγκ', wiki='Τουαρέγκ', wikiExists=true, key='τουαρεγκ' }
Languages['tl'] = { iso='tl', name='φιλιππινέζικα', cat='Φιλιππινέζικη γλώσσα', link='Φιλιππινέζικα (tl)',
                   from='φιλιππινέζικης προέλευσης', frm='φιλιππινέζικη', words='Φιλιππινέζικες λέξεις',
                   apo='τη φιλιππινέζικη', apota='από τα φιλιππινέζικα', wiki='Φιλιππινέζικη γλώσσα', wikiExists=true, key='φιλιππινεζικα' }
Languages['tlh'] = { iso='tlh', name='κλίγκον', cat='Γλώσσα κλίγκον', link='Κλίγκον (tlh)',
                   from='προέλευσης από τη γλώσσα κλίγκον', frm='κλίγκον', words='Λέξεις της γλώσσας κλίγκον',
                   apo='τη γλώσσα κλίγκον', apota='από τη γλώσσα κλίγκον - Σταρ Τρεκ', wiki='Γλώσσα Κλίνγκον', wikiExists=false, key='κλιγκον' }
Languages['tn'] = { iso='tn', name='τσουάνα', cat='Γλώσσα τσουάνα', link='Τσουάνα (tn)',
                   from='προέλευσης από τη γλώσσα τσουάνα', frm='τσουάνα', words='Λέξεις της γλώσσας τσουάνα',
                   apo='τη γλώσσα τσουάνα', apota='από τη γλώσσα τσουάνα', wiki='Γλώσσα Τσουάνα', wikiExists=true, key='τσουανα' }
Languages['tnq'] = { iso='tnq', name='ταΐνο', cat='Γλώσσα ταΐνο', link='Ταΐνο (tnq)',
                   from='προέλευσης από τη γλώσσα ταΐνο', frm='ταΐνο', words='Λέξεις της γλώσσας ταΐνο',
                   apo='τη γλώσσα ταΐνο', apota='από τη γλώσσα ταΐνο', wiki='', wikiExists=false, key='ταινο' }
Languages['to'] = { iso='to', name='τόνγκα', cat='Γλώσσα τόνγκα', link='Τόνγκα (to)',
                   from='προέλευσης από τη γλώσσα τόνγκα', frm='τόνγκα', words='Λέξεις της γλώσσας τόνγκα',
                   apo='τη γλώσσα τόνγκα', apota='από τη γλώσσα τόνγκα', wiki='', wikiExists=false, key='τονγκα' }
Languages['tpi'] = { iso='tpi', name='τοκ πίσιν', cat='Γλώσσα τοκ πίσιν', link='Τοκ πίσιν (tpi)',
                   from='προέλευσης από τη γλώσσα τοκ πίσιν', frm='τοκ πίσιν', words='',
                   apo='τη γλώσσα τοκ πίσιν', apota='από τη γλώσσα τοκ πισίν', wiki='Γλώσσες της Παπούα Νέας Γουινέας#Τοκ Πισίν', wikiExists=true, key='τοκπισιν' }
Languages['tpn'] = { iso='tpn', name='τουπινάμπα', cat='Γλώσσα τουπινάμπα', link='Τουπινάμπα (tpn)',
                   from='προέλευσης από τη γλώσσα τουπινάμπα', frm='τουπινάμπα', words='Λέξεις της γλώσσας τουπινάμπα',
                   apo='τη γλώσσα τουπινάμπα', apota='από τη γλώσσα τουπινάμπα', wiki='', wikiExists=false, key='τουπιναμπα' }
Languages['tpw'] = { iso='tpw', name='τούπι', cat='Γλώσσα τούπι', link='Τούπι (tpw)',
                   from='προέλευσης από τη γλώσσα τούπι', frm='τούπι', words='Λέξεις της γλώσσας τούπι',
                   apo='τη γλώσσα τούπι', apota='από τη γλώσσα τούπι', wiki='', wikiExists=false, key='τουπι' }
                   -- τούπι ή παλαιά τούπι - Old Tupi langage
Languages['tr'] = { iso='tr', name='τουρκικά', cat='Τουρκική γλώσσα', link='Τουρκικά (tr)',
                   from='τουρκικής προέλευσης', frm='τουρκική', words='Τουρκικές λέξεις',
                   apo='την τουρκική', apota='από τα τουρκικά', wiki='Τουρκική γλώσσα', wikiExists=true, key='τουρκικα' }
Languages['trk'] = { iso='trk', name='τουρκικές γλώσσες', cat='Τουρκικές γλώσσες', link='',
                   from='προέλευσης από τουρκικές γλώσσες', frm='τουρκικές γλώσσες', words='Λέξεις τουρκικών γλωσσών',
                   apo='τουρκικές γλώσσες', apota='από τουρκικές γλώσσες', wiki='', wikiExists=false, key='τουρκικεσγλωσσεσ', family=true }
                   -- trk οικογένεια γλωσσών  @en.wikt: trk-cmn [[w:en:Common Turkic languages]] βάσει κατάταξης με εξαίρεση τις γλώσσες Oghur     
Languages['trk-oat'] = { iso='trk-oat', name='παλαιά τουρκικά της Ανατολίας', cat='Παλαιά τουρκική της Ανατολίας', link='Παλαιά τουρκική της Ανατολίας (trk-oat)',
                   from='προέλευσης από την παλαιά τουρκική της Ανατολίας', frm='παλαιά τουρκική της Ανατολίας', words='Λέξεις της παλαιάς τουρκικής της Ανατολίας',
                   apo='την παλαιά τουρκική της Ανατολίας', apota='από τα παλαιά τουρκικά της Ανατολίας', wiki='', wikiExists=false, key='παλαιατουρκικηανατολιασ' }                 
Languages['trk-pro'] = { iso='trk-pro', name='πρωτοτουρκική', cat='Πρωτοτουρκική γλώσσα', link='Πρωτοτουρκική γλώσσα (trk-pro)',
                   from='πρωτοτουρκικής προέλευσης', frm='πρωτοτουρκική', words='Πρωτοτουρκικές λέξεις',
                   apo='την πρωτοτουρκική', apota='από την πρωτοτουρκική', wiki='', wikiExists=false, key='πρωτοτουρκικη' }
Languages['ts'] = { iso='ts', name='τσόνγκα', cat='Γλώσσα τσόνγκα', link='Τσόνγκα (ts)',
                   from='προέλευσης από τη γλώσσα τσόνγκα', frm='τσόνγκα', words='Λέξεις της γλώσσας τσόνγκα',
                   apo='τη γλώσσα τσόνγκα', apota='από τη γλώσσα τσόνγκα', wiki='', wikiExists=true, key='τσονγκα' }
-- status main, regional
Languages['tsd'] = { iso='tsd', name='τσακωνικά', cat='Τσακωνικά', link='Τσακωνικά (tsd)',
	from='τσακωνικής προέλευσης', frm='τσακωνική', words='Τσακωνικές λέξεις',
	apo='την τσακωνική', apota='από τα τσακωνικά', wiki='Τσακωνική διάλεκτος', wikiExists=true, key='*τσακωνικα',
	-- for auto cat
	sublang=true, regional=true, status = 'main', host='Νέα ελληνικά', host_show='Νέα ελληνικά', host_name='νέα ελληνικά', host_apota='από τα νέα ελληνικά', 
	host_iso='el', host_key="*τσακωνικα", apota_key="'τσακωνικα" }
                   -- 'τσακώνικα'  πιο λόγιο = 'τσακωνικά', αλλά λογιότερο 'τσακωνική' (εννοείται είτε διάλεκτος, είτε γλώσσα)
                   -- η parent γλώσσα είναι τα αρχαία δωρικά
Languages['tt'] = { iso='tt', name='ταταρικά', cat='Ταταρική γλώσσα', link='Ταταρικά (tt)',
                   from='ταταρικής προέλευσης', frm='ταταρική', words='Ταταρικές λέξεις',
                   apo='την ταταρική', apota='από τα ταταρικά', wiki='Ταταρική γλώσσα', wikiExists=true, key='ταταρικα' }
Languages['txh'] = { iso='txh', name='θρακικά', cat='Θρακική γλώσσα', link='Θρακικά (txh)',
                   from='θρακικής προέλευσης', frm='θρακική', words='Θρακικές λέξεις',
                   apo='τη θρακική', apota='από τα θρακικά', wiki='en:Thracian language', wikiExists=false, key='θρακικα' }
Languages['ty'] = { iso='ty', name='ταϊτιανά', cat='Ταϊτιανή γλώσσα', link='Ταϊτιανά (ty)',
                   from='ταϊτιανής προέλευσης', frm='ταϊτιανή', words='Ταϊτιανές λέξεις',
                   apo='την ταϊτιανή', apota='από τα ταϊτιανά', wiki='Ταϊτιανή γλώσσα', wikiExists=false, key='ταιτινα' }
Languages['udm'] = { iso='udm', name='ούντμουρτ', cat='Γλώσσα ούντμουρτ', link='Ούντμουρτ (udm)',
                   from='προέλευσης από τη γλώσσα ούντμουρτ', frm='ούντμουρτ', words='Λέξεις της γλώσσας ούντμουρτ',
                   apo='τη γλώσσα ούντμουρτ', apota='από τη γλώσσα ούντμουρτ', wiki='', wikiExists=false, key='ουντμουρτ' }
Languages['ug'] = { iso='ug', name='ουιγουρικά', cat='Ουιγουρική γλώσσα', link='Ουιγουρικά (ug)',
                   from='ουιγουρικής προέλευσης', frm='ουιγουρική', words='Λέξεις της γλώσσας ουϊγκούρ',
                   apo='την ουιγουρική', apota='από τα ουιγουρικά', wiki='Ουιγούρ γλώσσα', wikiExists=true, key='ουιγουρικα' }
Languages['uga'] = { iso='uga', name='ουγκαριτικά', cat='Ουγκαριτική γλώσσα', link='Ουγκαριτικά (uga)',
                   from='ουγκαριτικής προέλευσης', frm='ουγκαριτική', words='Ουγκαριτικές λέξεις',
                   apo='την ουγκαριτική', apota='από τα ουγκαριτικά', wiki='Ουγκαριτική γλώσσα', wikiExists=false, key='ουγκαριτικα' }
Languages['uk'] = { iso='uk', name='ουκρανικά', cat='Ουκρανική γλώσσα', link='Ουκρανικά (uk)',
                   from='ουκρανικής προέλευσης', frm='ουκρανική', words='Ουκρανικές λέξεις',
                   apo='την ουκρανική', apota='από τα ουκρανικά', wiki='Ουκρανική γλώσσα', wikiExists=true, key='ουκρανικα' }
Languages['ur'] = { iso='ur', name='ούρντου', cat='Γλώσσα ούρντου', link='Ούρντου (ur)', script='Arab',
                   from='προέλευσης από τη γλώσσα ούρντου', frm='ούρντου', words='Λέξεις της γλώσσας ούρντου',
                   apo='τη γλώσσα ούρντου', apota='από τη γλώσσα ούρντου', wiki='Γλώσσα Ούρντου', wikiExists=true, key='ουρντου' }
Languages['uz'] = { iso='uz', name='ουζμπεκικά', cat='Ουζμπεκική γλώσσα', link='Ουζμπεκικά (uz)',
                   from='ουζμπεκικής προέλευσης', frm='ουζμπεκική', words='Ουζμπεκικές λέξεις',
                   apo='την ουζμπεκική', apota='από τα ουζμπεκικά', wiki='Ουζμπεκική γλώσσα', wikiExists=true, key='ουζμπεκικα' }
Languages['ve'] = { iso='ve', name='βένδα', cat='Γλώσσα βένδα', link='Βένδα (ve)',
                   from='προέλευσης από τη γλώσσα βένδα', frm='βένδα', words='Λέξεις της γλώσσας βένδα',
                   apo='τη γλώσσα βένδα', apota='από τη γλώσσα βένδα', wiki='', wikiExists=false, key='βενδα' }
Languages['vec'] = { iso='vec', name='βενετικά', cat='Βενετική γλώσσα', link='Βενετικά (vec)',
                   from='βενετικής προέλευσης', frm='βενετική', words='Βενετικές λέξεις',
                   apo='τη βενετική', apota='από τα βενετικά', wiki='Βενετική γλώσσα', wikiExists=true, key='βενετικα' }
Languages['vep'] = { iso='vep', name='βεψικά', cat='Βεψική γλώσσα', link='Βεψικά (vep)',
                   from='βεψικής προέλευσης', frm='βεψική', words='Βεψικές λέξεις',
                   apo='τη βεψική', apota='από τα βεψικά', wiki='', wikiExists=false, key='βεψικα' }
Languages['vi'] = { iso='vi', name='βιετναμικά', cat='Βιετναμική γλώσσα', link='Βιετναμικά (vi)',
                   from='βιετναμικής προέλευσης', frm='βιετναμική', words='Βιετναμικές λέξεις',
                   apo='τη βιετναμική', apota='από τα βιετναμικά', wiki='Βιετναμέζικη γλώσσα', wikiExists=true, key='βιετναμικα' }
Languages['vls'] = { iso='vls', name='φλαμανδικά', cat='Φλαμανδική γλώσσα', link='Φλαμανδικά (vls)',
                   from='φλαμανδικής προέλευσης', frm='φλαμανδική', words='Φλαμανδικές λέξεις',
                   apo='τη φλαμανδική', apota='από τα φλαμανδικά', wiki='Φλαμανδική γλώσσα', wikiExists=false, key='φλαμανδικα' }
Languages['vo'] = { iso='vo', name='βολαπούκ', cat='Γλώσσα βολαπούκ', link='Βολαπούκ (vo)',
                   from='προέλευσης από τη γλώσσα βολαπούκ', frm='βολαπούκ', words='Λέξεις της γλώσσας βολαπούκ',
                   apo='τη γλώσσα βολαπούκ', apota='από τη γλώσσα βολαπιούκ', wiki='Βολαπιούκ', wikiExists=true, key='βολαπουκ' }
Languages['wa'] = { iso='wa', name='βαλονικά', cat='Βαλονική γλώσσα', link='Βαλονικά (wa)',
                   from='βαλονικής προέλευσης', frm='βαλονική', words='Βαλονικές λέξεις',
                   apo='τη βαλονική', apota='από τα βαλονικά', wiki='Βαλλωνική γλώσσα', wikiExists=true, key='βαλονικα' }
Languages['war'] = { iso='war', name='γουαράι γουαράι', cat='Γλώσσα γουαράι γουαράι', link='Γουαράι γουαράι (war)',
                   from='προέλευσης από τη γλώσσα γουαράι γουαράι', frm='γουαράι γουαράι', words='Λέξεις της γλώσσας γουαράι γουαράι',
                   apo='τη γλώσσα γουαράι γουαράι', apota='από τη γλώσσα γουαράι γουαράι', wiki='', wikiExists=false, key='γουαραι' }
					-- παλιά: Winaray
Languages['wen'] = { iso='wen', name='σορβικά', cat='Σορβική γλώσσα', link='Σορβικά (wen)',
                   from='σορβικής προέλευσης', frm='σορβική', words='Σορβικές λέξεις',
                   apo='τη σορβική', apota='από τα σορβικά', wiki='Σορβικές γλώσσες', wikiExists=false, key='σορβικα' }
                   -- ομάδα γλωσσών : Άνω σορβική hsb, Κάτω σορβική dsb
Languages['wo'] = { iso='wo', name='γουόλοφ', cat='Γλώσσα γουόλοφ', link='Γουόλοφ (wo)',
                   from='προέλευσης από τη γλώσσα γουόλοφ', frm='γουόλοφ', words='Λέξεις της γλώσσας γουόλοφ',
                   apo='τη γλώσσα γουόλοφ', apota='από τη γλώσσα γουόλοφ', wiki='', wikiExists=true, key='γουολοφ' }
Languages['wuu'] = { iso='wuu', name='κινεζικά γου', cat='Κινεζικά γου', link='Κινεζικά γου (wuu)',
                   from='προέλευσης από την κινεζική γου', frm='κινεζική γου', words='Λέξεις της κινεζικής γου',
                   apo='την κινεζική γου', apota='από τα κινεζικά γου', wiki='', wikiExists=false, key='κινεζικαγου' }
Languages['xh'] = { iso='xh', name='κόσα', cat='Γλώσσα κόσα', link='Κόσα (xh)',
                   from='προέλευσης από τη γλώσσα κόσα', frm='κόσα', words='Λέξεις της γλώσσας κόσα',
                   apo='τη γλώσσα κόσα', apota='από τη γλώσσα κόσα', wiki='Κόσα', wikiExists=false, key='κοσα' }
Languages['xno'] = { iso='xno', name='αγγλονορμανδικά', cat='Αγγλονορμανδική γλώσσα', link='Αγγλονορμανδικά (xno)',
                   from='αγγλονορμανδικής προέλευσης', frm='αγγλονορμανδική', words='Αγγλονορμανδικές λέξεις',
                   apo='την αγγλονορμανδική', apota='από τα αγγλονορμανδικά', wiki='Αγγλονορμανδική γλώσσα', wikiExists=false, key='αγγλονορμανδικα' }
Languages['xcl'] = { iso='xcl', name='παλαιά αρμενικά', cat='Παλαιά αρμενική γλώσσα', link='Παλαιά αρμενικά (xcl)',
                   from='προέλευσης από την παλαιά αρμενική', frm='παλαιά αρμενική', words='Λέξεις της παλαιάς αρμενικής',
                   apo='την παλαιά αρμενική', apota='από τα παλαιά αρμενικά', wiki='Παλαιοαρμενική γλώσσα', wikiExists=false, key='παλαιααρμενικα' }
Languages['xcr'] = { iso='xcr', name='καρικά', cat='Καρική γλώσσα', link='Καρικά (xcr)',
                   from='καρικής προέλευσης', frm='καρική', words='Καρικές λέξεις',
                   apo='την καρική', apota='από τα καρικά', wiki='Καρική γλώσσα', wikiExists=false, key='καρικα' }
Languages['xdc'] = { iso='xdc', name='δακικά', cat='Δακική γλώσσα', link='Δακικά (xdk)',
                   from='προέλευσης από τη Δακική γλώσσα', frm='δακική', words='Δακικές λέξεις',
                   apo='τη δακική γλώσσα', apota='από τα δακικά', wiki='Δακική γλώσσα', wikiExists=false, key='δακικα' }
Languages['xdk'] = { iso='xdk', name='Darug', cat='Γλώσσα Darug', link='Darug (xdk)',
                   from='προέλευσης από τη γλώσσα Darug', frm='Darug', words='Λέξεις της γλώσσας Darug',
                   apo='τη γλώσσα Darug', apota='από τη γλώσσα Darug', wiki='Νταρούκ', wikiExists=false, key='νταρουγκ' }
Languages['xlc'] = { iso='xlc', name='λυκιακά', cat='Λυκιακή γλώσσα', link='Λυκιακά (xlc)',
                   from='λυκιακής προέλευσης', frm='λυκιακή', words='Λυκιακές λέξεις',
                   apo='τη λυκιακή', apota='από τα λυκιακά', wiki='Λυκιακή γλώσσα', wikiExists=false, key='λυκιακα' }
Languages['xld'] = { iso='xld', name='λυδικά', cat='Λυδική γλώσσα', link='Λυδικά (xld)',
                   from='λυδικής προέλευσης', frm='λυδική', words='Λυδικές λέξεις',
                   apo='τη λυδική', apota='από τα λυδικά', wiki='Λυδική γλώσσα', wikiExists=false, key='λυδικα' }   
Languages['xlu'] = { iso='xlu', name='λουβικά', cat='Λουβική γλώσσα', link='Λουβικά (xlu)',
                   from='λουβικής προέλευσης', frm='λουβική', words='Λουβικές λέξεις',
                   apo='τη λουβική', apota='από τα λουβικά', wiki='Λουβική γλώσσα', wikiExists=false, key='λουβικα' }
Languages['xme-old'] = { iso='xme-old', name='παλαιά μηδικά', cat='Παλαιά μηδική γλώσσα', link='Παλαιά μηδικά (xme-old)',
                   from='προέλευσης από την παλαιά μηδική', frm='παλαιά μηδική', words='Λέξεις της παλαιάς μηδικής',
                   apo='την παλαιά μηδική', apota='από τα παλαιά μηδικά', wiki='en:Old Median', wikiExists=false, key='παλαιαμηδικα' }  
                   -- αρκετά δάνεια προς ελληνιστική, όπως [[γάζα]] / [[wikt:en:Old Median]]
--[=[ moved under Ancient Greek
Languages['xmk'] = { iso='xmk', name='αρχαία μακεδονικά', cat='Αρχαία μακεδονικά', link='Αρχαία ελληνικά (grc)',
	from='αρχαίας μακεδονικής προέλευσης', frm='αρχαία μακεδονική', words='Αρχαίες μακεδονικές λέξεις',
	apo='την αρχαία μακεδονική', apota='από τα αρχαία μακεδονικά', wiki='Αρχαία μακεδονική γλώσσα', wikiExists=false, key='μακεδονικα',
	-- for auto cat
	sublang=true, status = 'main', host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*μακεδονικα", apota_key="'μακεδονικα" }
]=]--
Languages['xmk'] = { iso='xmk', name='μακεδονική διάλεκτος', cat='Μακεδονική διάλεκτος', link='Αρχαία ελληνικά (grc)',
	from='μακεδονικής προέλευσης', frm='μακεδονική διάλεκτος', words='Μακεδονικές λέξεις',
	apo='τη μακεδονική διάλεκτο', apota='από τη μακεδονική διάλεκτο', wiki='Μακεδονική διάλεκτος', wikiExists=false, key='*μακεδονικη',
	-- for auto cat
	sublang=true, regional=true, host='Αρχαία ελληνικά', host_show='Αρχαία ελληνικά', host_name='αρχαία ελληνικά', host_apota='από τα αρχαία ελληνικά', 
	host_iso='grc', host_key="*μακεδονικη", apota_key="'μακεδονικη", }
		--  αρχαία ελληνική διάλεκτος. Κωδικός για ετυμολογίες. [[Πρότυπο:μκεδ]] στους ορισμούς.  Χρήση στην ετυμολογία: π.χ. [[Βερενίκη]]
Languages['xpr'] = { iso='xpr', name='παρθικά', cat='Παρθική γλώσσα', link='Παρθικά (xpr)',
                   from='παρθικής προέλευσης', frm='παρθική', words='Παρθικές λέξεις',
                   apo='την παρθική', apota='από τα παρθικά', wiki='Παρθική γλώσσα', wikiExists=false, key='παρθικα' }
Languages['yi'] = { iso='yi', name='γίντις', cat='Γλώσσα γίντις', link='Γίντις (yi)',
                   from='προέλευσης από τη γλώσσα γίντις', frm='γίντις', words='Λέξεις της γλώσσας γίντις',
                   apo='τη γλώσσα γίντις', apota='από τη γλώσσα γίντις', wiki='Γίντις', wikiExists=true, key='γιντισ' }
Languages['yo'] = { iso='yo', name='γιορούμπα', cat='Γλώσσα γιορούμπα', link='Γιορούμπα (yo)',
                   from='προέλευσης από τη γλώσσα γιορούμπα', frm='γιορούμπα', words='Λέξεις της γλώσσας γιορούμπα',
                   apo='τη γλώσσα γιορούμπα', apota='από τη γλώσσα γιορούμπα', wiki='Γλώσσα Γιορούμπα', wikiExists=false, key='γιορουμπα' }
Languages['yua'] = { iso='yua', name='μάγια του Γιουκατάν', cat='Γλώσσα μάγια του Γιουκατάν', link='Μάγια του Γιουκατάν (yua)',
                   from='', frm='', words='',
                   apo='', apota='από τη γλώσσα μάγια του Γιουκατάν', wiki='Γλώσσες Μάγια', wikiExists=false, key='μαγιαγιουκαταν' }
Languages['za'] = { iso='za', name='τσουανγκ', cat='Γλώσσα τσουανγκ', link='Τσουανγκ (za)',
                   from='προέλευσης από τη γλώσσα τσουανγκ', frm='τσουανγκ', words='Λέξεις της γλώσσας τσουανγκ',
                   apo='τη γλώσσα τσουανγκ', apota='από τη γλώσσα τσουανγκ', wiki='', wikiExists=true, key='τσουανγκ' }
                   --za οικογένεια κινεζικών γλωσσών Τάι. Προφέρεται: τσουανγκ (ουα δίφθογγος)
Languages['zea'] = { iso='zea', name='ζηλανδικά', cat='Ζηλανδική γλώσσα', link='Ζηλανδικά (zea)',
                   from='ζηλανδικής προέλευσης', frm='ζηλανδική', words='Ζηλανδικές λέξεις',
                   apo='τη ζηλανδική', apota='από τα ζηλανδικά', wiki='Ζηλανδική γλώσσα', wikiExists=false, key='ζηλανδικα' }
Languages['zh'] = { iso='zh', name='κινεζικά', cat='Κινεζική γλώσσα', link='Κινεζικά (zh)', script='Hani',
                   from='κινεζικής προέλευσης', frm='κινεζική', words='Κινεζικές λέξεις',
                   apo='την κινεζική', apota='από τα κινεζικά', wiki='Κινεζική γλώσσα', wikiExists=true, key='κινεζικα' }
	-- βλ och παλαιά κινεζική με link προς εδώ, ltc μέση κινεζική
-- status main για τη διπλή γραφή της
Languages['zh2'] = { iso='zh2', name='κινεζικά - απλοποιημένη γραφή', cat='Λήμματα απλοποιημένης γραφής (κινεζικά)', link='Κινεζικά (zh)',
	script='Hani',
	from='προέλευσης από την απλοποιημένη κινεζική γραφή', frm='κινεζική - απλοποιημένη γραφή', words='Λέξεις κινεζικής απλοποιημένης γραφής',
	apo='την κινεζική απλοποιημένη γραφή', apota='από τα κινεζικά - απλοποιημένη γραφή', wiki='', wikiExists=false, key='απλοποιημενακινεζικα',
	-- ειδικά για την απλοποιημένη γραφή: ξεχωριστή καταμέτρηση - ΔΕΝ προσμετρώνται στην Κατηγορία:Κινεζική γλώσσα, αλλά χωριστά
	-- for auto cat
	sublang=true, regional=false, status = 'main', host='Κινεζική γλώσσα', host_show='Κινεζικά', host_name='κινεζικά', host_apota='από τα κινεζικά', 
	host_iso='zh', host_key="+απλοποιημενακινεζικα", apota_key="'απλοποιημενακινεζικα" }
Languages['zh-min-nan'] = { iso='zh-min-nan', name='κινεζικά μινάν', cat='Κινεζικά μινάν', link='Κινεζικά μινάν (zh-min-nan)',
                   from='προέλευσης από την κινεζική μινάν', frm='κινεζική μινάν', words='Λέξεις της κινεζικής μινάν',
                   apo='την κινεζική μινάν', apota='από τα κινεζικά μινάν', wiki='', wikiExists=false, key='κινεζικαμιναν' }
Languages['zh-yue'] = { iso='zh-yue', name='καντόν', cat='Γλώσσα καντόν', link='Καντόν (zh-yue)',
                   from='προέλευσης από τη γλώσσα καντόν', frm='καντόν', words='Λέξεις της γλώσσας καντόν',
                   apo='τη γλώσσα καντόν', apota='από τη γλώσσα καντόν', wiki='Καντονέζικη γλώσσα', wikiExists=true, key='καντον' }
Languages['zsm'] = { iso='zsm', name='μαλαισιακά', cat='Μαλαισιακή γλώσσα', link='Μαλαισιακά (zsm)',
                   from='μαλαισιακής προέλευσης', frm='μαλαισιακή', words='Μαλαισιακές λέξεις',
                   apo='τη μαλαισιακή', apota='από τα μαλαισιακά', wiki='', wikiExists=true, key='μαλαισιακα' }
Languages['zu'] = { iso='zu', name='ζουλού', cat='Γλώσσα ζουλού', link='Ζουλού (zu)',
                   from='προέλευσης από τη γλώσσα ζουλού', frm='ζουλού', words='Λέξεις της γλώσσας ζουλού',
                   apo='τη γλώσσα ζουλού', apota='από τη γλώσσα ζουλού', wiki='Ζουλού γλώσσα', wikiExists=true, key='ζουλου' }


----------------------------------------
return Languages