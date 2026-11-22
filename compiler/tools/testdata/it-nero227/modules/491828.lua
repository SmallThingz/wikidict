local export = {}

local ignore_cap = {
	["ko"] = true,
}

local phonetic_extraction = {
	["th"] = "Modulo:th"
}

local pos_tags = {
	["a"] = "adjective",
	["adv"] = "adverb",
	["int"] = "interjection",
	["n"] = "noun",
	["pron"] = "pronoun",
	["v"] = "verb",
	["vi"] = "intransitive verb",
	["vt"] = "transitive verb",
	["vti"] = "transitive and intransitive verb",
}

local unsupported_titles = mw.loadData("Modulo:links/unsupported titles")

function export.getLinkPage(target, lang)
	if unsupported_titles[target] then
		return "Unsupported titles/" .. unsupported_titles[target]
	end
	
	-- If the link contains unexpanded template parameters, then don't create a link.
	if target:find("{{{", nil, true) then
		return nil
	end
	
	if target:find("^:") or target:find("^w:") or target:find("^wikipedia:") then
		return target
	end
	
	-- Remove diacritics from the page name
	target = lang:makeEntryName(target)
	
	-- Link to appendix for reconstructed terms and terms in appendix-only languages
	if target:find("^*.") then
		if lang:getCode() == "und" then
			return nil
		end
		
		target = "Reconstruction:" .. lang:getCanonicalName() .. "/" .. mw.ustring.sub(target, 2)
	elseif lang:getType() == "reconstructed" then
		error("The specified language " .. lang:getCanonicalName() .. " is unattested, while the given word is not marked with '*' to indicate that it is reconstructed")
	elseif lang:getType() == "appendix-constructed" then
		target = "Appendix:" .. lang:getCanonicalName() .. "/" .. target
	end
	
	return target
end

-- Make a language-specific link from given link's parts
local function makeLangLink(link, lang, id, allowSelfLink)
	-- If there is no display form, then create a default one
	if not link.display then
		link.display = link.target
		
		-- Strip the prefix from the displayed form
		-- TODO: other interwiki links?
		if link.display:find("^:") and not unsupported_titles[link.display] then
			link.display = link.display:gsub("^:", "")
		elseif link.display:find("^w:") then
			link.display = link.display:gsub("^w:", "")
		elseif link.display:find("^wikipedia:") then
			link.display = link.display:gsub("^wikipedia:", "")
		end
	end
	
	-- Process the target
	link.target = export.getLinkPage(link.target, lang)
	
	if not link.target then
		return link.display
	end
	
	-- If the target is the same as the current page, then return a "self-link" like the software does
	if not allowSelfLink and not id and (link.target == mw.title.getCurrentTitle().prefixedText or link.target == ":" .. mw.title.getCurrentTitle().prefixedText) then
		return "<strong class=\"selflink\">" .. link.display .. "</strong>"
	end
	
	-- Add fragment
	-- Do not add a section link to "Undetermined", as such sections do not exist and are invalid.
	-- TabbedLanguages handles links without a section by linking to the "last visited" section,
	-- but adding "Undetermined" would break that feature.
	if not (link.target:find("^w:") or link.target:find("^wikipedia:")) then
		if link.fragment or mw.ustring.find(link.target, "#$") then
			require("Modulo:debug").track("links/fragment")
			require("Modulo:debug").track("links/fragment/" .. lang:getCode())
		end
		
		if not link.fragment and lang:getCode() ~= "und" then
			if id then
				link.fragment = lang:getCanonicalName() .. "-" .. id
			elseif not link.target:find("^Appendix:") and not link.target:find("^Reconstruction:") then
				link.fragment = lang:getCanonicalName()
			end
		end
	end
	
	-- This allows linking to pages like [[sms:a]] without it being treated weirdly.
	link.target = mw.ustring.gsub(link.target, ":", "&#x3a;")
	
	return "[[" .. link.target .. (link.fragment and "#" .. link.fragment or "") .. "|" .. link.display .. "]]"
end


-- Split a link into its parts
local function parseLink(linktext)
	local link = {target = linktext}
	local found, _, first, second
	
	found, _, first, second = mw.ustring.find(link.target, "^([^|]+)|(.+)$")
	
	if found then
		link.target = first
		link.display = second
	else
		link.display = link.target
	end
	
	found, _, first, second = mw.ustring.find(link.target, "^(.+)#(.+)$")
	
	if found then
		link.target = first
		link.fragment = second
	end
	
	return link
end


-- Creates a basic wikilink to the given term. If the text already contains
-- links, these are replaced with links to the correct section.
function export.language_link(data, allowSelfLink, dontLinkRecons)
	if type(data) ~= "table" then
		error("The first argument to the function language_link must be a table. See Modulo:links/documentation for more information.")
	end
	
	local text = data.term
	
	if ignore_cap[data.lang:getCode()] and text then
		text = mw.ustring.gsub(text, "%^", "")
	end
	
	-- If the text begins with * and another character,
	-- then act as if each link begins with *
	local allReconstructed = false
	
	if text:find("^*.") then
		allReconstructed = true
	end
	
	-- Do we have embedded wikilinks?
	if text:find("[[", nil, true) then
		--[=[
		[[Special:WhatLinksHere/Template:tracking/links/alt-ignored]]
		[[Special:WhatLinksHere/Template:tracking/links/id-ignored]]
		]=]
		
		if data.alt then
			require("Modulo:debug").track("links/alt-ignored")
		end
		
		if data.id then
			require("Modulo:debug").track("links/id-ignored")
		end
		
		-- Begins and ends with a wikilink tag
		if mw.ustring.find(text, "^%[%[(.+)%]%]$") then
			-- There are no [ ] in between.
			-- This makes the wikilink tag redundant.
			if mw.ustring.find(text, "^%[%[[^%[%]]+%]%]$") then
				require("Modulo:debug").track("links/redundant wikilink")
			else
				local temp = mw.ustring.gsub(text, "^%[%[(.+)%]%]$", "%1")
				temp = mw.ustring.gsub(temp, "%]%], %[%[", "|")
				
				if not mw.ustring.find(temp, "[%[%]]") then
					require("Modulo:debug").track("links/list")
				end
			end
		end
		
		text = mw.ustring.gsub(text, "%[%[([^%]]+)%]%]",
			function(linktext)
				local link = parseLink(linktext)
				
				if allReconstructed then
					link.target = "*" .. link.target
				end
				
				return makeLangLink(link, data.lang, data.id, allowSelfLink, dontLinkRecons)
			end
			)
		
		-- Remove the extra * at the beginning if it's immediately followed
		-- by a link whose display begins with * too
		if allReconstructed then
			text = mw.ustring.gsub(text, "^%*%[%[([^|%]]+)|%*", "[[%1|*")
		end
	else
		-- There is no embedded wikilink, make a link using the parameters.
		text = makeLangLink({target = text, display = data.alt}, data.lang, data.id, allowSelfLink, dontLinkRecons)
	end
	
	return text
end
	
local function mark(text, itemType, face)
	local tag = { "", "" }
	
	if itemType == "gloss" then
		tag = { '<span class="mention-gloss-double-quote">“</span><span class="mention-gloss">', '</span><span class="mention-gloss-double-quote">”</span>' }
	elseif itemType == "tr" then
		if face == "term" then
			tag = { '<span lang="" class="tr mention-tr">', '</span>' }
		else
			tag = { '<span lang="" class="tr">', '</span>' }
		end
	elseif itemType == "annotations" then
		tag = { '<span class="mention-gloss-paren">(</span>', '<span class="mention-gloss-paren">)</span>' }
	end
	
	if type(text) == "string" then
		return tag[1] .. text .. tag[2]
	else
		return ""
	end
end

-- Format the annotations (things following the linked term)
function export.format_link_annotations(data, face)
	local output = {}
	
	-- Interwiki link
	if data.interwiki then
		table.insert(output, data.interwiki)
	end
	
	-- Genders
	if data.genders and #data.genders > 0 then
		local m_gen = require("Modulo:gender and number")
		table.insert(output, "&nbsp;" .. m_gen.format_list(data.genders, data.lang))
	end
	
	local annotations = {}
	
	-- Transliteration
	if data.tr then
		table.insert(annotations, mark(data.tr, "tr", face))
	end
	
	-- Gloss/translation
	if data.gloss then
		table.insert(annotations, mark(data.gloss, "gloss"))
	end
	
	-- Part of speech
	if data.pos then
		table.insert(annotations, pos_tags[data.pos] or data.pos)
	end
	
	-- Literal/sum-of-parts meaning
	if data.lit then
		table.insert(annotations, "literally " .. mark(data.lit, "gloss"))
	end
	
	if #annotations > 0 then
		table.insert(output, " " .. mark(table.concat(annotations, ", "), "annotations"))
	end
	
	return table.concat(output)
end

-- A version of {{l}} or {{m}} that can be called from other modules too
function export.full_link(data, face, allowSelfLink, dontLinkRecons)
	if type(data) ~= "table" then
		error("The first argument to the function full_link must be a table. See Modulo:links/documentation for more information.")
	end
	
	-- Create the link
	local output = {}
	local categories = {}
	local link = ""
	local annotations
	
	local m_utilities = require("Modulo:utilities")
	local m_scriptutils = require("Modulo:script utilities")
	
	-- Is there any text to show?
	if (data.term or data.alt) then
		-- Try to detect the script if it was not provided
		if not data.sc then
			data.sc = require("Modulo:scripts").findBestScript(data.alt or data.term, data.lang)
		end
		
		-- Only make a link if the term has been given, otherwise just show the alt text without a link
		link = m_scriptutils.tag_text(data.term and export.language_link(data, allowSelfLink, dontLinkRecons) or data.alt, data.lang, data.sc, face)
	else
		--[[	No term to show.
				Is there at least a transliteration we can work from?	]]
		link = m_scriptutils.request_script(data.lang, data.sc)
		
		if link == "" or not data.tr or data.tr == "-" then
			-- No link to show, and no transliteration either. Show a term request.
			local category = ""
			
			if mw.title.getCurrentTitle().nsText ~= "Template" then
				table.insert(categories, "[[Category:" .. data.lang:getCanonicalName() .. " term requests]]")
			end
			
			link = "<small>[Term?]</small>"
		end
	end
	
	table.insert(output, link)
	
	if data.tr == "" or data.tr == "-" then
		data.tr = nil
	
	elseif phonetic_extraction[data.lang:getCode()] then
		local m_phonetic = require(phonetic_extraction[data.lang:getCode()])
		data.tr = data.tr or m_phonetic.getTranslit(export.remove_links(data.term))
	
	elseif (data.term or data.alt)
		and not ((data.sc:getCode():find("Latn", nil, true)) or data.sc:getCode() == "Latinx") then
		
		-- Try to generate a transliteration if necessary
		local automated_tr = data.lang:transliterate(export.remove_links(data.alt or data.term), data.sc)
		
		if automated_tr then
			local manual_tr = data.tr
			
			if manual_tr then
				if manual_tr == automated_tr then
					table.insert(
						categories,
						"[[Category:Terms with redundant transliterations]]"
						.. "[[Category:Terms with redundant transliterations/" .. data.lang:getCode() .. "]]"
					)
				else
					table.insert(
						categories,
						"[[Category:Terms with manual transliterations different from the automated ones]]"
						.. "[[Category:Terms with manual transliterations different from the automated ones/" .. data.lang:getCode() .. "]]"
					)
				end
			end
		
			if (not manual_tr) or data.lang:overrideManualTranslit() then
				data.tr = automated_tr
			end
		end
	end
	
	-- Link to the transliteration entry for languages that require this
	if data.tr and data.lang:link_tr() then
		data.tr = export.language_link{ lang = data.lang, term = data.tr }
	end
	
	annotations = export.format_link_annotations(data, face)
	
	table.insert(output, annotations)
	
	return table.concat(output) .. table.concat(categories)
end


-- Strips all square brackets out or replaces them.
function export.remove_links(text)
	if type(text) == "table" then text = text.args[1] end; if not text then text = "" end
	
	text = text:gsub("%[%[Category:[^|%]]-|?[^|%]]-%]%]", "")
	text = text:gsub("%[%[[^|%]]-|", "")
	text = text:gsub("%[%[", "")
	text = text:gsub("%]%]", "")

	return text
end

function export.english_links(text)
	local lang = require("Modulo:languages").getByCode("en")
	
	text = mw.ustring.gsub(text, "%[%[([^%]]+)%]%]",
		function(linktext)
			local link = parseLink(linktext)
			return makeLangLink(link, lang, nil, true, false)
		end
	)
	
	return text
end

return export