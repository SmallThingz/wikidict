local export = {}

local find = mw.ustring.find

--[=[	This function checks for things that could plausibly be a language code:
		two or three lowercase letters, two or three groups of three lowercase
		letters with hyphens between them. If such a pattern is not found,
		it is likely the editor simply forgot to enter a language code. ]=]

function export.err(langCode, param, text)
	local ordinals = { "first", "second", "third", "fourth" }
	
	if type(param) == "number" then
		ordinal = ordinals[param]
		param = ordinal .. ' parameter'
	elseif type(param) == "string" then
		param = 'parameter "' .. param .. '"'
	else
		error("The parameter name is "
			.. ( type(param) == "table" and "a table" or tostring(param) )
			.. ", but it should be a number or a string.")
	end
	
	--[[	Can't use "%l" because that would include all Unicode
			lowercase letters; language codes only use ASCII.	]]
	local lower = "[a-z]"
		
	if not langCode or langCode == "" then
		error("The " .. param .. " (" .. (text or "language code" ) .. ") is missing.", 2)
	elseif find(langCode, "^" .. lower .. lower .. lower .. "?$")
		or find(langCode, "^" .. lower .. lower .. lower
			.. "%-" .. lower .. lower .. lower .. "$")
		or find(langCode, "^" .. lower .. lower .. lower
			.. "%-" .. lower .. lower .. lower
			.. "%-" .. lower .. lower .. lower .. "$") then
		error("The language code \"" .. langCode .. "\" is not valid.", 2)
	else
		error("Please enter a " .. ( text or "language code" ) .. " in the " .. param .. ".", 2)
	end
end

local Language = {}

function Language:getCode()
	return self._code
end


function Language:getCanonicalName()
	return self._rawData.canonicalName
end


-- Commented out; I don't think anything uses this, the presence/absence of script errors should confirm
--function Language:getAllNames()
--	return self._rawData.names
--end


function Language:getOtherNames()
	return self._rawData.otherNames or {}
end


function Language:getType()
	return self._rawData.type or "regular"
end


function Language:getWikimediaLanguages()
	if not self._wikimediaLanguageObjects then
		local m_wikimedia_languages = require("Modulo:wikimedia languages")
		self._wikimediaLanguageObjects = {}
		local wikimedia_codes = self._rawData.wikimedia_codes or {self._code}
		
		for _, wlangcode in ipairs(wikimedia_codes) do
			table.insert(self._wikimediaLanguageObjects, m_wikimedia_languages.getByCode(wlangcode))
		end
	end
	
	return self._wikimediaLanguageObjects
end


function Language:getWikipediaArticle()
	return self._rawData.wikipedia_article or self:getCategoryName()
end



function Language:makeWikipediaLink()
	return "[[w:" .. self:getWikipediaArticle() .. "|" .. self:getCanonicalName() .. "]]"
end


function Language:getScripts()
	if not self._scriptObjects then
		local m_scripts = require("Modulo:scripts")
		self._scriptObjects = {}
		
		for _, sc in ipairs(self._rawData.scripts or {"None"}) do
			table.insert(self._scriptObjects, m_scripts.getByCode(sc))
		end
	end
	
	return self._scriptObjects
end


function Language:getFamily()
	if self._rawData.family and not self._familyObject then
		self._familyObject = require("Modulo:families").getByCode(self._rawData.family)
	end
	
	return self._familyObject
end


function Language:getAncestors()
	if not self._ancestorObjects then
		self._ancestorObjects = {}
		
		if self._rawData.ancestors then
			for _, ancestor in ipairs(self._rawData.ancestors) do
				table.insert(self._ancestorObjects, export.getByCode(ancestor) or require("Modulo:etymology languages").getByCode(ancestor))
			end
		else
			local fam = self:getFamily()
			local protoLang = fam and fam:getProtoLanguage() or nil
			
			-- For the case where the current language is the proto-language
			-- of its family, we need to step up a level higher right from the start.
			if protoLang and protoLang:getCode() == self:getCode() then
				fam = fam:getFamily()
				protoLang = fam and fam:getProtoLanguage() or nil
			end
			
			while not protoLang and not (not fam or fam:getCode() == "qfa-not") do
				fam = fam:getFamily()
				protoLang = fam and fam:getProtoLanguage() or nil
			end
			
			table.insert(self._ancestorObjects, protoLang)
		end
	end
	
	return self._ancestorObjects
end

local function iterateOverAncestorTree(node, func)
	for _, ancestor in ipairs(node:getAncestors()) do
		if ancestor then
			local ret = func(ancestor) or iterateOverAncestorTree(ancestor, func)
			if ret then
				return ret
			end
		end
	end
end

function Language:getAncestorChain()
	if not self._ancestorChain then
		self._ancestorChain = {}
		local step = #self:getAncestors() == 1 and self:getAncestors()[1] or nil
		
		while step do
			table.insert(self._ancestorChain, 1, step)
			step = #step:getAncestors() == 1 and step:getAncestors()[1] or nil
		end
	end
	
	return self._ancestorChain
end


function Language:hasAncestor(otherlang)
	local function compare(ancestor)
		return ancestor:getCode() == otherlang:getCode()
	end
	return iterateOverAncestorTree(self, compare) or false
end


function Language:getCategoryName()
	local name = self._rawData.canonicalName
	
	-- If the name already has "language" in it, don't add it.
	if name:find("[Ll]anguage$") then
		return name
	else
		return name .. " language"
	end
end


function Language:getStandardCharacters()
	return self._rawData.standardChars
end


function Language:makeEntryName(text)
	text = mw.ustring.gsub(text, "^[¿¡]", "")
	text = mw.ustring.gsub(text, "(.)[؟?!;՛՜ ՞ ՟？！︖︕।॥။၊་།]$", "%1")
	
	if self:getCode() == "ar" then
		local U = mw.ustring.char
		local taTwiil = U(0x640)
		local waSla = U(0x671)
		-- diacritics ordinarily removed by entry_name replacements
		local Arabic_diacritics = U(0x64B, 0x64C, 0x64D, 0x64E, 0x64F, 0x650, 0x651, 0x652, 0x670)
		
		if text == waSla or mw.ustring.find(text, "^" .. taTwiil .. "?[" .. Arabic_diacritics .. "]" .. "$") then
			return text
		end
	end
	
	if self._rawData.entry_name then
		for i, from in ipairs(self._rawData.entry_name.from) do
			local to = self._rawData.entry_name.to[i] or ""
			text = mw.ustring.gsub(text, from, to)
		end
	end
	
	--[=[ For instance, ᾰ (alpha-breve) + combining smooth breathing is converted
		to alpha + combining smooth breathing by the entry_name replacements.
		It must be re-combined to alpha-smooth breathing (ἀ) so that
		allowSelfLink in [[Modulo:links]] will work properly. ]=]
	if self:getCode() == "grc"
		then text = mw.ustring.toNFC(text)
	end
	
	return text
end


function Language:makeSortKey(name)
	name = mw.ustring.lower(name)
	
	-- Remove initial hyphens and *
	local hyphens_regex = "^[-־ـ*]+(.)"
	name = mw.ustring.gsub(name, hyphens_regex, "%1")

	-- Remove parentheses, as long as they are either preceded or followed by something
	name = mw.ustring.gsub(name, "(.)[()]+", "%1")
	name = mw.ustring.gsub(name, "[()]+(.)", "%1")
	
	-- If there are language-specific rules to generate the key, use those
	if self._rawData.sort_key then
		for i, from in ipairs(self._rawData.sort_key.from) do
			local to = self._rawData.sort_key.to[i] or ""
			name = mw.ustring.gsub(name, from, to)
		end
	end
	
	return mw.ustring.upper(name)
end

function Language:overrideManualTranslit()
	if self._rawData.override_translit then
		return true
	else
		return false
	end
end


function Language:transliterate(text, sc, modulo_override)
	if not ((modulo_override or self._rawData.translit_module) and text) then
		return nil
	end
	
	if modulo_override then
		require("Modulo:debug").track("modulo_override")
	end
	
	return require("Modulo:" .. (modulo_override or self._rawData.translit_module)).tr(text, self:getCode(), sc and sc:getCode() or nil)
end

function Language:hasTranslit()
	return self._rawData.translit_module and true or false
end


function Language:link_tr()
	return self._rawData.link_tr and true or false
end


function Language:toJSON()
	local entryNamePatterns = nil
	
	if self._rawData.entry_name then
		entryNamePatterns = {}
		
		for i, from in ipairs(self._rawData.entry_name.from) do
			local to = self._rawData.entry_name.to[i] or ""
			table.insert(entryNamePatterns, {from = from, to = to})
		end
	end
	
	local ret = {
		ancestors = self._rawData.ancestors,
		canonicalName = self:getCanonicalName(),
		categoryName = self:getCategoryName(),
		code = self._code,
		entryNamePatterns = entryNamePatterns,
		family = self._rawData.family,
		otherNames = self:getOtherNames(),
		scripts = self._rawData.scripts,
		type = self:getType(),
		wikimediaLanguages = self._rawData.wikimedia_codes,
		}
	
	return require("Modulo:JSON").toJSON(ret)
end


-- Do NOT use this method!
-- All uses should be pre-approved on the talk page!
function Language:getRawData()
	return self._rawData
end

Language.__index = Language


function export.getDataModuleName(code)
	if code:find("^[a-z][a-z]$") then
		return "languages/data2"
	elseif code:find("^[a-z][a-z][a-z]$") then
		local prefix = code:sub(1, 1)
		return "languages/data3/" .. prefix
	elseif code:find("^[a-z-]+$") then
		return "languages/datax"
	else
		return nil
	end
end


local function getRawLanguageData(code)
	local modulename = export.getDataModuleName(code)
	return modulename and mw.loadData("Modulo:" .. modulename)[code] or nil
end


function export.makeObject(code, data)
	if data and data.deprecated then
		require("Modulo:debug").track("languages/deprecated")
		require("Modulo:debug").track("languages/deprecated/" .. code)
	end
	
	return data and setmetatable({ _rawData = data, _code = code }, Language) or nil
end


function export.getByCode(code)
	if type(code) ~= "string" then
		error("The function getByCode expects a string as its first argument, but received " .. ( code == nil and "nil" or "a " .. type(code) ) .. ".")
	end
	
	return export.makeObject(code, getRawLanguageData(code))
end


function export.getByName(name)
	local byName = mw.loadData("Modulo:languages/by name")
	local code = byName.all and byName.all[name] or byName[name]
	
	if not code then
		return nil
	end
	
	return export.makeObject(code, getRawLanguageData(code))
end


function export.getByCanonicalName(name)
	local byName = mw.loadData("Modulo:languages/canonical names")
	local code = byName and byName[name]
	
	if not code then
		return nil
	end
	
	return export.makeObject(code, getRawLanguageData(code))
end


function export.iterateAll()
	mw.incrementExpensiveFunctionCount()
	local m_data = mw.loadData("Modulo:languages/alldata")
	local func, t, var = pairs(m_data)
	
	return function()
		local code, data = func(t, var)
		return export.makeObject(code, data)
	end
end

return export