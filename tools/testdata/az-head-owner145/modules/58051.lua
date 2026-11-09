local export = {}

local lemmas = {
	["abbreviations"] = true,
	["acronyms"] = true,
	["adjectives"] = true,
	["adnominals"] = true,
	["adpositions"] = true,
	["adverbs"] = true,
	["affixes"] = true,
	["ambipositions"] = true,
	["articles"] = true,
	["circumfixes"] = true,
	["circumpositions"] = true,
	["classifiers"] = true,
	["cmavo"] = true,
	["cmavo clusters"] = true,
	["cmene"] = true,
	["comparative adjectives"] = true,
	["comparative adverbs"] = true,
	["conjunctions"] = true,
	["contractions"] = true,
	["counters"] = true,
	["determiners"] = true,
	["diacritical marks"] = true,
	["equative adjectives"] = true,
	["fu'ivla"] = true,
	["gismu"] = true,
	["Han characters"] = true,
	["Han tu"] = true,
	["hanzi"] = true,
	["hanja"] = true,
	["idioms"] = true,
	["infixes"] = true,
	["interfixes"] = true,
	["initialisms"] = true,
	["interjections"] = true,
	["kanji"] = true,
	["letters"] = true,
	["ligatures"] = true,
	["lujvo"] = true,
	["morphemes"] = true,
	["non-constituents"] = true,
	["nouns"] = true,
	["numbers"] = true,
	["numeral symbols"] = true,
	["numerals"] = true,
	["particles"] = true,
	["phrases"] = true,
	["postpositions"] = true,
	["predicatives"] = true,
	["prefixes"] = true,
	["prepositions"] = true,
	["prepositional phrases"] = true,
	["preverbs"] = true,
	["pronominal adverbs"] = true,
	["pronouns"] = true,
	["proverbs"] = true,
	["proper nouns"] = true,
	["punctuation marks"] = true,
	["relatives"] = true,
	["roots"] = true,
	["suffixes"] = true,
	["superlative adjectives"] = true,
	["superlative adverbs"] = true,
	["syllables"] = true,
	["symbols"] = true,
	["verbs"] = true,
	["İsim"] = true,
	["Feil"] = true,
	["Ədat"] = true,
	["Xüsusi isim"] = true,
	["Nida"] = true,
}

local nonlemmas = {
	["active participles"] = true,
	["adjectival participles"] = true,
	["adjective forms"] = true,
	["adjective comparative forms"] = true,
	["adjective feminine forms"] = true,
	["adjective equative forms"] = true,
	["adjective plural forms"] = true,
	["adjective superlative forms"] = true,
	["adverb forms"] = true,
	["adverb comparative forms"] = true,
	["adverb superlative forms"] = true,
	["adverbial participles"] = true,
	["agent participles"] = true,
	["article forms"] = true,
	["circumfix forms"] = true,
	["combined forms"] = true,
	["determiner comparative forms"] = true,
	["determiner forms"] = true,
	["determiner superlative forms"] = true,
	["diminutive nouns"] = true,
	["future participles"] = true,
	["gerunds"] = true,
	["infinitive forms"] = true,
	["infinitives"] = true,
	["jyutping"] = true,
	["kanji readings"] = true,
	["misspellings"] = true,
	["negative participles"] = true,
	["nominal participles"] = true,
	["noun case forms"] = true,
	["noun dual forms"] = true,
	["noun forms"] = true,
	["noun plural forms"] = true,
	["noun possessive forms"] = true,
	["noun singulative forms"] = true,
	["numeral forms"] = true,
	["participles"] = true,
	["participle forms"] = true,
	["particle forms"] = true,
	["passive participles"] = true,
	["past active participles"] = true,
	["past participles"] = true,
	["past participle forms"] = true,
	["past passive participles"] = true,
	["perfect active participles"] = true,
	["perfect participles"] = true,
	["perfect passive participles"] = true,
	["pinyin"] = true,
	["plurals"] = true,
	["postposition forms"] = true,
	["prefix forms"] = true,
	["preposition contractions"] = true,
	["preposition forms"] = true,
	["prepositional pronouns"] = true,
	["present active participles"] = true,
	["present participles"] = true,
	["present passive participles"] = true,
	["pronoun forms"] = true,
	["pronoun possessive forms"] = true,
	["proper noun forms"] = true,
	["proper noun plural forms"] = true,
	["rafsi"] = true,
	["romanizations"] = true,
	["singulatives"] = true,
	["suffix forms"] = true,
	["verb forms"] = true,
	["verbal nouns"] = true,
	["Feilin formaları"] = true,
	["İsmin halları"] = true,
}

local notranslit = {
	["az"] = true,
	["bbc"] = true,
	["bug"] = true,
	["cia"] = true,
	["cjm"] = true,
	["cmn"] = true,
	["hak"] = true,
	["ja"] = true,
	["lad"] = true,
	["lzh"] = true,
	["ms"] = true,
	["mul"] = true,
	["nan"] = true,
	["oj"] = true,
	["pi"] = true,
	["ro"] = true,
	["ryu"] = true,
	["sh"] = true,
	["tgt"] = true,
	["th"] = true,
	["tly"] = true,
	["und"] = true,
	["vi"] = true,
	["yue"] = true,
	["zh"] = true,
}


local function preprocess(data)
	if type(data.heads) ~= "table" then
		data.heads = {data.heads}
	end
	
	if type(data.translits) ~= "table" then
		data.translits = {data.translits}
	end
	
	if #data.heads == 0 then
		data.heads = {""}
	end
	
	-- Create a default headword.
	local default_head = mw.title.getCurrentTitle().subpageText
	
	-- Determine if term is reconstructed
	local is_reconstructed = data.lang:getType() == "reconstructed" or mw.title.getCurrentTitle().nsText == "Reconstruction"
	
	-- Add links to multi-word page names when appropriate
	if data.lang:getCode() ~= "zh" then
		local WORDBREAKCHARS = "([%p%s]+)"
		local EXCLUDECHARS = "([^-־׳״'.·*]+)" -- workaround for excluding characters from the above
		local contains_words = false; mw.ustring.gsub(default_head, WORDBREAKCHARS, function(b) contains_words = contains_words or mw.ustring.match(b, "^" .. EXCLUDECHARS .. "$"); end)
		
		if (not is_reconstructed) and contains_words then
			local function workaround_to_exclude_chars(s)
				return mw.ustring.gsub(s, EXCLUDECHARS, "]]%1[[")
			end
			
			default_head = "[[" .. mw.ustring.gsub(default_head, WORDBREAKCHARS, workaround_to_exclude_chars) .. "]]"
			-- default_head = "[[" .. mw.ustring.gsub(default_head, WORDBREAKCHARS, "]]%1[[") .. "]]" -- use this when workaround is no longer needed
			default_head = mw.ustring.gsub(default_head, "%[%[%]%]", "") -- remove any empty links (which could have been created above at the beginning or end of the string)
		end
	end
	
	if is_reconstructed then
		default_head = "*" .. default_head
	end
	
	-- If a head is the empty string "", then replace it with the default
	for i, head in ipairs(data.heads) do
		if head == "" then
			head = default_head
		end
		
		data.heads[i] = head
	end
	
	-- Try to detect the script if it was not provided
	-- We use the first headword for this, and assume that all of them have the same script
	-- This *should* always be true, right?
	if not data.sc then
		data.sc = require("Module:scripts").findBestScript(data.heads[1], data.lang)
	end
	
	-- Make transliterations
	for i, head in ipairs(data.heads) do
		local translit = data.translits[i]
		
		-- Try to generate a transliteration if necessary
		-- Generate it if the script is not Latn or similar, and if no transliteration was provided
		if translit == "-" then
			translit = nil
		elseif not translit and not ((data.sc:getCode():find("Latn", nil, true)) or data.sc:getCode() == "Latinx" or data.sc:getCode() == "None") then
			translit = data.lang:transliterate(require("Module:links").remove_links(head), data.sc)
			
			-- There is still no transliteration?
			-- Add the entry to a cleanup category.
			if not translit and not notranslit[data.lang:getCode()] then
				translit = "<small>transliteration needed</small>"
				table.insert(data.categories, data.lang:getCanonicalName() .. " terms needing transliteration")
			end
		end
		
		-- Link to the transliteration entry for languages that require this
		if translit and data.lang:link_tr() then
			translit = require("Module:links").full_link({term = translit, lang = data.lang, sc = require("Module:scripts").getByCode("Latn"), tr = "-"})
		end
		
		data.translits[i] = translit
	end
end


-- Format a headword with transliterations
local function format_headword(data)
	local m_links = require("Module:links")
	local m_scriptutils = require("Module:script utilities")
	
	-- Are there non-empty transliterations?
	-- Need to do it this way because translit[1] might be nil while translit[2] is not
	local has_translits = false
	
	-- Format the headwords
	for i, head in ipairs(data.heads) do
		if data.translits[i] then
			has_translits = true
		end
		
		-- Apply processing to the headword, for formatting links and such
		if head:find("[[", nil, true) then
			head = m_links.language_link({term = head, lang = data.lang}, false)
		end
		
		-- Add language and script wrapper
		head = m_scriptutils.tag_text(head, data.lang, data.sc, "head")
		
		data.heads[i] = head
	end
	
	local translits_formatted = ""
	
	if has_translits then
		-- Format the transliterations
		for i, head in ipairs(data.heads) do
			local translit = data.translits[i]
			
			if not translit then
				translit = "?"
			end
			
			translit = "<span class=\"tr\" lang=\"\">" .. translit .. "</span>"
			
			data.translits[i] = translit
		end
		
		translits_formatted = " &lrm;(<span class=\"tr\" lang=\"\">" .. table.concat(data.translits, " ''or'' ") .. "</span>)"
		
		if mw.title.new(data.lang:getCanonicalName() .. " transliteration", "Vikilüğət").exists then
			translits_formatted = " [[Wiktionary:" .. data.lang:getCanonicalName() .. " transliteration|•]]" .. translits_formatted
		end
	end
	
	return table.concat(data.heads, " ''or'' ") .. translits_formatted
end


local function format_genders(data)
	if data.genders and #data.genders > 0 then
		local gen = require("Module:gender and number")
		return "&nbsp;" .. gen.format_list(data.genders, data.lang)
	else
		return ""
	end
end


local function format_inflection_parts(data, parts)
	local m_links = require("Module:links")
	
	for key, part in ipairs(parts) do
		if type(part) ~= "table" then
			part = {term = part}
		end
		
		local qualifiers = ""
		
		if part.qualifiers and #part.qualifiers > 0 then
			qualifiers = mw.getCurrentFrame():expandTemplate{title = "qualifier", args = part.qualifiers} .. " "
		end
		
		local partaccel = part.accel
		local face = part.hypothetical and "hypothetical" or "bold"
		local nolink = part.hypothetical or part.nolink
		
		-- Convert the term into a full link
		-- Don't show a transliteration here, the consensus seems to be not to
		-- show them in headword lines to avoid clutter.
		part = m_links.full_link({term = not nolink and part.term or nil, alt = part.alt or (nolink and part.term or nil), lang = part.lang or data.lang, sc = part.sc or (not part.lang and data.sc), id = part.id, genders = part.genders, tr = part.translit or ((not (parts.enable_auto_translit or data.lang:getCode() == "ar")) and "-" or nil)}, face, false)
		
		if parts.accel or partaccel then
			part = "<span class=\"form-of lang-" .. data.lang:getCode() .. " " .. (parts.accel or "") .. " " .. (partaccel or "") .. "\">" .. part .. "</span>"
		end
		
		part = qualifiers .. part
		
		parts[key] = part
	end
	
	local parts_output = ""
	
	if #parts > 0 then
		parts_output = " " .. table.concat(parts, " ''or'' ")
	elseif parts.request then
		parts_output = " <small>[please provide]</small>" .. require("Module:utilities").format_categories({data.lang:getCanonicalName() .. " entries needing inflection"}, lang, nil, nil, data.force_cat_output)
	end
	
	return "''" .. parts.label .. "''" .. parts_output
end

-- Format the inflections following the headword
local function format_inflections(data)
	if data.inflections and #data.inflections > 0 then
		-- Format each inflection individually
		for key, infl in ipairs(data.inflections) do
			data.inflections[key] = format_inflection_parts(data, infl)
		end
		
		return " &lrm;(" .. table.concat(data.inflections, ", ") .. ")"
	else
		return ""
	end
end

function export.show_headword_line(data)
	-- Check the namespace against the language type
	if mw.title.getCurrentTitle().nsText == "" then
		if data.lang:getType() == "reconstructed" then
			error("Entries for this language must be placed in the Reconstruction: namespace.")
		elseif data.lang:getType() == "appendix-constructed" then
			error("Entries for this language must be placed in the Appendix: namespace.")
		end
	end
	
	data.categories = {}
	local tracking_categories = {}
	
	-- Is it a lemma category?
	if lemmas[data.pos_category] or lemmas[data.pos_category:gsub("^reconstructed ", "")] then
		table.insert(data.categories, data.lang:getCanonicalName() .. " dilindəki sözlər")
	-- Is it a nonlemma category?
	elseif nonlemmas[data.pos_category] or nonlemmas[data.pos_category:gsub("^reconstructed ", "")] or lemmas[data.pos_category:gsub("^mutated ", "")] or nonlemmas[data.pos_category:gsub("^mutated ", "")] then
		table.insert(data.categories, data.lang:getCanonicalName() .. " dilindəki baş söz formasında olmayan sözlər")
	-- It's neither; we don't know what this category is, so tag it with a tracking category.
	else
		table.insert(tracking_categories, "head tracking/unrecognized pos")
		require("Module:debug").track("head tracking/unrecognized pos")
		require("Module:debug").track("head tracking/unrecognized pos/lang/" .. data.lang:getCode())
		require("Module:debug").track("head tracking/unrecognized pos/pos/" .. data.pos_category)
	end
	
	table.insert(data.categories, data.pos_category .. " (" ..  data.lang:getCanonicalName().." dili)" )
	
	-- Preprocess
	preprocess(data)
	
	-- Format and return all the gathered information
	return
		format_headword(data) ..
		format_genders(data) ..
		format_inflections(data) ..
		require("Module:utilities").format_categories(data.categories, data.lang, data.sort_key, nil, data.force_cat_output) ..
		require("Module:utilities").format_categories(tracking_categories, data.lang, data.sort_key, nil, data.force_cat_output)
end

function export.full_headword(lang, sc, heads, translits, genders, inflections, categories, sort_key, force_cat_output)
	local data = {lang = lang, sc = sc, heads = heads, translits = translits, genders = genders, inflections = inflections, pos_category = nil, sort_key = sort_key, force_cat_output = force_cat_output}
	local tracking_categories = {}
	categories = categories or {}
	
	-- Were any categories specified?
	if #categories == 0 then
		if lang:getCode() ~= "und" then
			table.insert(tracking_categories, "head tracking/no pos")
			require("Module:debug").track("head tracking/no pos")
			require("Module:debug").track("head tracking/no pos/lang/" .. lang:getCode())
		end
	else
		for _, cat in ipairs(categories) do
			-- Does the category begin with the language name? If not, tag it with a tracking category.
			if mw.ustring.sub(cat, 1, mw.ustring.len(lang:getCanonicalName()) + 1) ~= lang:getCanonicalName() .. " " then
				table.insert(tracking_categories, "head tracking/no lang category")
				require("Module:debug").track("head tracking/no lang category")
				require("Module:debug").track("head tracking/no lang category/lang/" .. lang:getCode())
			end
		end
		
		if mw.ustring.sub(categories[1], 1, mw.ustring.len(lang:getCanonicalName() .. " ")) == lang:getCanonicalName() .. " " then
			data.pos_category = mw.ustring.sub(categories[1], mw.ustring.len(lang:getCanonicalName()) + 2)
			table.remove(categories, 1)
		end
	end
	
	local standard = data.lang:getStandardCharacters()
	
	if standard then
		if mw.ustring.len(mw.title.getCurrentTitle().subpageText) ~= 1 then
			for character in mw.ustring.gmatch(mw.title.getCurrentTitle().subpageText, "([^" .. standard .. "])") do
				table.insert(categories, lang:getCanonicalName() .. " terms spelled with " .. mw.ustring.upper(character))
			end
		end
	end

	if require('Module:palindromes').is_palindrome(mw.title.getCurrentTitle().subpageText, lang) then
		table.insert(categories, lang:getCanonicalName() .. " dilindəki palindromlar")
	end
	
	return
		export.show_headword_line(data) ..
		require("Module:utilities").format_categories(categories, data.lang, data.sort_key, nil, data.force_cat_output) ..
		require("Module:utilities").format_categories(tracking_categories, data.lang, data.sort_key, nil, data.force_cat_output)
end

return export