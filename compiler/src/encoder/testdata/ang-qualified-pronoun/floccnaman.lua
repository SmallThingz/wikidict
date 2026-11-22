--[=[
	Floccnaman (category names) for the Old English Wiktionary.

	Every category that a reader sees on an entry page is built as "<sprǣc> <word>" or
	"<sprǣc> <word> <word>", exactly like the categories that already exist by hand on this wiki
	("Englisc nama", "Nīwenglisc fégung", "Eald Noren werlic nama"), so only the words need
	translating, never the word order.

	The modules that build such categories ([[Module:headword]], [[Module:headword utilities]],
	[[Module:form of]], [[Module:gender and number]], [[Module:affix]], [[Module:etymology]],
	[[Module:etymology/specialized]], [[Module:ang-headword]]) ask this module for the Old English
	wording first and keep the English wording if it is not here yet. Every missing wording is
	tracked in [[Wiktionary:Tracking/flocc/untranslated/<wording>]], so the list of what still needs
	to be added is always up to date:

	[[Special:WhatLinksHere/Wiktionary:Tracking/flocc/untranslated]]

	Words are entered without leading or trailing spaces, in the singular for parts of speech
	("nama", not "naman"), because that is what the pre-existing categories use. The plural forms
	used for the lemma categories are entered separately ("lemmas", "non-lemma forms", ...).

	Only categories a reader sees on an entry page are translated here. Maintenance and tracking
	categories (sortkeys, script codes, requests, pages with ...), the categories of the template
	namespace and the ones produced by MediaWiki itself stay English on purpose.
]=]

local export = {}

--[=[
	English wording -> Old English wording.

	The words in this first group are already used by categories and template names that exist on
	this wiki, so their spelling is established ("Flocc:Nama", "Flocc:Bīnaman", "Flocc:Nīwenglisc
	fégung", "Bysen:Tōgeīecendlic-Tabule", "Cynn 1 strang forþgewiten dǣlnimend"), and the gender
	words match the existing "Eald Noren werlic nama" style.
]=]
local words = {
	-- Parts of speech.
	["nouns"] = "naman",
	["verbs"] = "word",
	["adjectives"] = "tōgeīecendlice word",
	["adverbs"] = "bīword",
	["conjunctions"] = "fégunga",
	["pronouns"] = "bīnaman",
	["prepositions"] = "foresetnessa",
	["participles"] = "dǣlnimend",
	["past participles"] = "forþgewiten dǣlnimend",
	["present participles"] = "andweard dǣlnimend",
	["masculine"] = "werlic",
	["masculine nouns"] = "werlic naman",
	["masculine a-stem nouns"] = "werlic a-stefn naman",
	["feminine"] = "wīflic",
	["feminine nouns"] = "wīflic naman",
	["neuter"] = "nāhwæðer",
	["neuter nouns"] = "nāhwæðer naman",
	["neuter a-stem nouns"] = "nāhwæðer a-stefn naman",
	["lemmas"] = "frumcennede word",
	["non-lemma forms"] = "gebīegede word",
	["variant lemmas"] = "ōþre frumcennede word",
	["variant non-lemma forms"] = "ōþre gebīegede word",
	["proper nouns"] = "āgennama",
	["numerals"] = "getælu",
	["letters"] = "stafas",
	["proverbs"] = "gecyndesprǣce",
	["other languages"] = "ōþre sprǣce",
	["terms borrowed from"] = "word borgodon of",
	["terms borrowed back into"] = "word borgodon tō",
	["terms inherited from"] = "word ierfde of",
	["terms derived from"] = "word ofgangende fram",
	["learned borrowings"] = "leornode borgiende",
	["compound words"] = "manigfeald word",
	["abbreviations"] = "scortnessa",
	["plural"] = "manigfeald",
	["phrases"] = "cwidas",
	["determiners"] = "bīnama",
	["symbols"] = "rūna",
	["countable nouns"] = "tellendlīc naman",
	["uncountable nouns"] = "untellendlīc naman",
	["initialisms"] = "styrtende stæfgefēg",
	["particles"] = "grot",
	["pages with entries"] = "trāmetas mid word"
}

--[=[
	Wording still to be translated. Anything listed here (or used in a module but not listed at
	all) falls back to its English form and shows up in
	[[Wiktionary:Tracking/flocc/untranslated]], so nothing breaks while the table is filled in.
	Suggestions, commented out until checked against a source:

	-- ["suffixes"] = "?", -- "Englisc ?"
	-- ["prefixes"] = "?",
	-- ["interjections"] = "?",
	-- ["Translingual"] = "?",
	-- ["taxonomic names"] = "?",
]=]

--[=[
	Wording that carries a variable part, as a leading phrase. For example the affix templates
	build categories such as "terms suffixed with -kas", where only the beginning is fixed; the
	language name is prepended by the caller. Longest phrase first, so the most specific rule wins.
]=]
local prefixes = {
		{"terms spelled with ", "word areahton mid "}
	-- {"terms suffixed with ", "?"},
	-- {"terms prefixed with ", "?"},
	-- {"terms circumfixed with ", "?"},
	-- {"terms infixed with ", "?"},
	-- {"terms interfixed with ", "?"},
}

local function track(text)
	local ok, track_module = pcall(require, "Module:debug/track")
	if ok then
		track_module("flocc/untranslated/" .. tostring(text))
	end
end

--[==[
	Return the Old English wording for one category name, or nil if it is not known yet. `lang` is
	accepted so that a wording can later be made language-specific if that turns out to be needed.
]==]
function export.translate(lang, text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	if words[text] then
		return words[text]
	end
	for _, rule in ipairs(prefixes) do
		if text:sub(1, #rule[1]) == rule[1] then
			return rule[2] .. text:sub(#rule[1] + 1)
		end
	end
	track(text)
	return nil
end

--[==[
	Return the Old English wording for one category name, or the English wording unchanged if it is
	not known yet. Use this in the modules that build categories: the language name is prepended by
	the caller, so only the wording itself is passed in.
]==]
function export.get(lang, text)
	return export.translate(lang, text) or text
end

-- The table is exposed for tests and maintenance scripts; use get() elsewhere.
export.words = words

return export