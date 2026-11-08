local export = {}

local debug_track_module = "Module:debug/track"
local etymology_languages_data_module = "Module:etymology languages/data"
local families_module = "Module:families"
local headword_page_module = "Module:headword/page"
local json_module = "Module:JSON"
local language_like_module = "Module:language-like"
local languages_data_module = "Module:languages/data"
local languages_data_patterns_module = "Module:languages/data/patterns"
local links_data_module = "Module:links/data"
local load_module = "Module:load"
local scripts_module = "Module:scripts"
local scripts_data_module = "Module:scripts/data"
local string_encode_entities_module = "Module:string/encode entities"
local string_pattern_escape_module = "Module:string/patternEscape"
local string_replacement_escape_module = "Module:string/replacementEscape"
local string_utilities_module = "Module:string utilities"
local table_module = "Module:table"
local utilities_module = "Module:utilities"
local wikimedia_languages_module = "Module:wikimedia languages"

local mw = mw
local string = string
local table = table

local char = string.char
local concat = table.concat
local find = string.find
local floor = math.floor
local get_by_code -- Defined below.
local get_data_module_name -- Defined below.
local get_extra_data_module_name -- Defined below.
local getmetatable = getmetatable
local gmatch = string.gmatch
local gsub = string.gsub
local insert = table.insert
local ipairs = ipairs
local is_known_language_tag = mw.language.isKnownLanguageTag
local make_object -- Defined below.
local match = string.match
local next = next
local pairs = pairs
local remove = table.remove
local require = require
local select = select
local setmetatable = setmetatable
local sub = string.sub
local type = type
local unstrip = mw.text.unstrip

-- Loaded as needed by findBestScript.
local Hans_chars
local Hant_chars
--[=[
Throw an error for an invalid language code or script code.

`lang_code` (required) is the bad code and can be nil or a non-string.

`param` (required) is the name of the parameter in which the code was contained. It can be a string, a number
	(for a numeric param, in which case the param will show up in the error message as an ordinal such as
	"first" or "second"), or `true` if no parameter can be clearly identified.

`code_desc` (optional) is text describing what the code is; by default, "language code".

`template_text` (optional) is a string specifying the template that generated the error, or a function
	to generate this string. If given, it will be displayed in the error message.

`not_real_lang` (optional), if given, indicates that the code is not in the form of a language code
	(e.g. it's a script code). Normally, this function checks for things that could plausibly be a language code:
	two or three lowercase letters, two or three groups of three lowercase letters with hyphens between them.
	If such a pattern is found, a different error message is displayed (indicating an invalid code) than otherwise
	(indicating a missing code). If `not_real_lang` is given, this check is suppressed.
]=]

local function check_object(...)
	check_object = require(utilities_module).check_object
	return check_object(...)
end

local function debug_track(...)
	debug_track = require(debug_track_module)
	return debug_track(...)
end

local function decode_entities(...)
	decode_entities = require(string_utilities_module).decode_entities
	return decode_entities(...)
end

local function decode_uri(...)
	decode_uri = require(string_utilities_module).decode_uri
	return decode_uri(...)
end

local function deep_copy(...)
	deep_copy = require(table_module).deepCopy
	return deep_copy(...)
end

local function encode_entities(...)
	encode_entities = require(string_encode_entities_module)
	return encode_entities(...)
end

local function get_L2_sort_key(...)
	get_L2_sort_key = require(headword_page_module).get_L2_sort_key
	return get_L2_sort_key(...)
end

local function get_script(...)
	get_script = require(scripts_module).getByCode
	return get_script(...)
end

local function find_best_script_without_lang(...)
	find_best_script_without_lang = require(scripts_module).findBestScriptWithoutLang
	return find_best_script_without_lang(...)
end

local function get_family(...)
	get_family = require(families_module).getByCode
	return get_family(...)
end

local function get_plaintext(...)
	get_plaintext = require(utilities_module).get_plaintext
	return get_plaintext(...)
end

local function get_wikimedia_lang(...)
	get_wikimedia_lang = require(wikimedia_languages_module).getByCode
	return get_wikimedia_lang(...)
end

local function keys_to_list(...)
	keys_to_list = require(table_module).keysToList
	return keys_to_list(...)
end

local function list_to_set(...)
	list_to_set = require(table_module).listToSet
	return list_to_set(...)
end

local function load_data(...)
	load_data = require(load_module).load_data
	return load_data(...)
end

local function make_family_object(...)
	make_family_object = require(families_module).makeObject
	return make_family_object(...)
end

local function pattern_escape(...)
	pattern_escape = require(string_pattern_escape_module)
	return pattern_escape(...)
end

local function replacement_escape(...)
	replacement_escape = require(string_replacement_escape_module)
	return replacement_escape(...)
end

local function safe_require(...)
	safe_require = require(load_module).safe_require
	return safe_require(...)
end

local function shallow_copy(...)
	shallow_copy = require(table_module).shallowCopy
	return shallow_copy(...)
end

local function split(...)
	split = require(string_utilities_module).split
	return split(...)
end

local function to_json(...)
	to_json = require(json_module).toJSON
	return to_json(...)
end

local function u(...)
	u = require(string_utilities_module).char
	return u(...)
end

local function ugsub(...)
	ugsub = require(string_utilities_module).gsub
	return ugsub(...)
end

local function ulen(...)
	ulen = require(string_utilities_module).len
	return ulen(...)
end

local function ulower(...)
	ulower = require(string_utilities_module).lower
	return ulower(...)
end

local function umatch(...)
	umatch = require(string_utilities_module).match
	return umatch(...)
end

local function uupper(...)
	uupper = require(string_utilities_module).upper
	return uupper(...)
end

local function track(page)
	debug_track("languages/" .. page)
	return true
end

local function normalize_code(code)
	return load_data(languages_data_module).aliases[code] or code
end

function export.err(lang_code, param, code_desc, template_tag, not_real_lang)
	local ordinals = {
		"first", "second", "third", "fourth", "fifth", "sixth",
		"seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth",
		"thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
		"eighteenth", "nineteenth", "twentieth"
	}
	
	code_desc = code_desc or "language code"
	
	if not template_tag then
		template_tag = ""
	else
		if type(template_tag) ~= "string" then
			template_tag = template_tag()
		end
		template_tag = " (Original template: " .. template_tag .. ")"
	end
	local function err(msg)
		error(msg .. template_tag, 3)
	end
	local param_type = type(param)
	local in_the_param
	if param == true then
		-- handled specially below
		in_the_param = ""
	else
		if param_type == "number" then
			param = ordinals[param] .. "パラメータ"
		elseif param_type == "string" then
			param = 'パラメータ"' .. param .. '"'
		else
			err("パラメータの名前は"
					.. (param_type == "table" and "a table" or tostring(param))
					.. "ですが、これは数値または文字列であるべきです。")
		end
		in_the_param = " in the " .. param
	end
	
	if not lang_code or lang_code == "" then
		if param == true then
			err("" .. code_desc .. "が見つかりません。")
		else
			err("" .. param .. " (" .. code_desc .. ")が見つかりません。")
		end
	elseif type(lang_code) ~= "string" then
		err("The " .. code_desc .. in_the_param .. " is supposed to be a string but is a " .. type(lang_code) .. ".")
	-- Can use string.find because language codes only contain ASCII.
	elseif not_real_lang or lang_code:find("^%l%l%l?$")
			or lang_code:find("^%l%l%l%-%l%l%l$")
			or lang_code:find("^%l%l%l%-%l%l%l%-%l%l%l$") then
		err("The " .. code_desc .. " \"" .. lang_code .. "\"" .. in_the_param .. " is not valid.")
	else
		err("" .. code_desc .. in_the_param .. "を指定してください。値\"" .. lang_code .. "\"が無効です。")
	end
end

local function check_object(...)
	check_object = require(utilities_module).check_object
	return check_object(...)
end

local function checkScript(text, self, sc)
	if not check_object("script", true, sc) or sc:getCode() == "None" then
		return self:findBestScript(text)
	end
	return sc
end

local function do_entry_name_or_sort_key_replacements(text, replacements)
	if replacements.from then
		for i, from in ipairs(replacements.from) do
			local to = replacements.to[i] or ""
			text = mw.ustring.gsub(text, from, to)
		end
	end
	
	if replacements.remove_diacritics then
		text = mw.ustring.toNFD(text)
		text = mw.ustring.gsub(text,
			'[' .. replacements.remove_diacritics .. ']',
			'')
		text = mw.ustring.toNFC(text)
	end
	
	return text
end

local Language = {}

function Language:getCode()
	return self._code
end


function Language:getCanonicalName()
	return self._rawData[1] or self._rawData.canonicalName
end


function Language:getDisplayForm()
	return self:getCanonicalName()
end


function Language:getOtherNames(onlyOtherNames)
	return require("モジュール:language-like").getOtherNames(self, onlyOtherNames)
end


function Language:getAliases()
	return self._rawData.aliases or {}
end


function Language:getVarieties(flatten)
	return require("モジュール:language-like").getVarieties(self, flatten)
end


function Language:getType()
	return self._rawData.type or "regular"
end

--[==[
If the language is etymology-only, this iterates through parents until a full language or family is found, and the
corresponding object is returned. If the language is a full language, then it simply returns itself.
]==]
function Language:getFull()
	local full = self._fullObject
	if full == nil then
		full = self:getFullCode()
		full = full == self._code and self or get_by_code(full)
		self._fullObject = full
	end
	return full
end

--[==[
If the language is an etymology-only language, this iterates through parents until a full language or family is
found, and the corresponding code is returned. If the language is a full language, then it simply returns the
language code.
]==]
function Language:getFullCode()
	return self._fullCode or self._code
end

function Language:getFullName()
	local full = self._fullName
	if full == nil then
		full = self:getFull():getCanonicalName()
		self._fullName = full
	end
	return full
end


function Language:getWikimediaLanguages()
	if not self._wikimediaLanguageObjects then
		local m_wikimedia_languages = require("モジュール:wikimedia languages")
		self._wikimediaLanguageObjects = {}
		local wikimedia_codes = self._rawData.wikimedia_codes or { self._code }
		
		for _, wlangcode in ipairs(wikimedia_codes) do
			table.insert(self._wikimediaLanguageObjects, m_wikimedia_languages.getByCode(wlangcode))
		end
	end
	
	return self._wikimediaLanguageObjects
end

function Language:getWikipediaArticle()
	if self._rawData.wikipedia_article then
		return self._rawData.wikipedia_article 
	elseif self._wikipedia_article then
		return self._wikipedia_article
	elseif self:getWikidataItem() and mw.wikibase then
		self._wikipedia_article = mw.wikibase.sitelink(self:getWikidataItem(), 'enwiki')
	end
	if not self._wikipedia_article then
		self._wikipedia_article = mw.ustring.gsub(self:getCategoryName(), "Creole language", "Creole")
	end
	return self._wikipedia_article
end

function Language:makeWikipediaLink()
	return "[[w:" .. self:getWikipediaArticle() .. "|" .. self:getCanonicalName() .. "]]"
end

function Language:getWikidataItem()
	return self._rawData[2] or self._rawData.wikidata_item
end

function Language:getScripts()
	if not self._scriptObjects then
		local m_scripts = require("モジュール:scripts")
		self._scriptObjects = {}
		
		for _, sc in ipairs(self._rawData.scripts or { "None" }) do
			table.insert(self._scriptObjects, m_scripts.getByCode(sc))
		end
	end
	
	return self._scriptObjects
end

function Language:getScriptCodes()
	return self._rawData.scripts or { "None" }
end

function Language:findBestScript(text, forceDetect)
	if not text or text == "" or text == "-" then
		return get_script("None")
	end

	-- Differs from table returned by getScriptCodes, as Hants is not normalized into its constituents.
	local codes = self._bestScriptCodes
	if codes == nil then
		codes = self._data[4]
		codes = codes and split(codes, ",", true, true) or {"None"}
		self._bestScriptCodes = codes
	end

	local first_sc = codes[1]

	if first_sc == "All" then
		return find_best_script_without_lang(text)
	end

	local codes_len = #codes

	if not (forceDetect or first_sc == "Hants" or codes_len > 1) then
		first_sc = get_script(first_sc)
		local charset = first_sc.characters
		return charset and umatch(text, "[" .. charset .. "]") and first_sc or get_script("None")
	end

	-- Remove all formatting characters.
	text = get_plaintext(text)

	-- Remove all spaces and any ASCII punctuation. Some non-ASCII punctuation is script-specific, so can't be removed.
	text = ugsub(text, "[%s!\"#%%&'()*,%-./:;?@[\\%]_{}]+", "")
	if #text == 0 then
		return get_script("None")
	end

	-- Try to match every script against the text,
	-- and return the one with the most matching characters.
	local bestcount, bestscript, length = 0
	for i = 1, codes_len do
		local sc = codes[i]
		-- Special case for "Hants", which is a special code that represents whichever of "Hant" or "Hans" best matches, or "Hani" if they match equally. This avoids having to list all three. In addition, "Hants" will be treated as the best match if there is at least one matching character, under the assumption that a Han script is desirable in terms that contain a mix of Han and other scripts (not counting those which use Jpan or Kore).
		if sc == "Hants" then
			local Hani = get_script("Hani")
			if not Hant_chars then
				Hant_chars = load_data("Module:zh/data/ts")
				Hans_chars = load_data("Module:zh/data/st")
			end
			local t, s, found = 0, 0
			-- This is faster than using mw.ustring.gmatch directly.
			for ch in gmatch((ugsub(text, "[" .. Hani.characters .. "]", "\255%0")), "\255(.[\128-\191]*)") do
				found = true
				if Hant_chars[ch] then
					t = t + 1
					if Hans_chars[ch] then
						s = s + 1
					end
				elseif Hans_chars[ch] then
					s = s + 1
				else
					t, s = t + 1, s + 1
				end
			end

			if found then
				if t == s then
					return Hani
				end
				return get_script(t > s and "Hant" or "Hans")
			end
		else
			sc = get_script(sc)

			if not length then
				length = ulen(text)
			end

			-- Count characters by removing everything in the script's charset and comparing to the original length.
			local charset = sc.characters
			local count = charset and length - ulen((ugsub(text, "[" .. charset .. "]+", ""))) or 0

			if count >= length then
				return sc
			elseif count > bestcount then
				bestcount = count
				bestscript = sc
			end
		end
	end

	-- Return best matching script, or otherwise None.
	return bestscript or get_script("None")
end

function Language:getFamily()
	if self._familyObject then
		return self._familyObject
	end
		
	local family = self._rawData[3] or self._rawData.family 
	if family then
		self._familyObject = require("モジュール:families").getByCode(family)
	end
	
	return self._familyObject
end

function Language:getParent()
	local parent = self._parentObject
	if parent == nil then
		parent = self:getParentCode()
		-- If the value is nil, it's cached as false.
		parent = parent and get_by_code(parent, nil, true, true) or false
		self._parentObject = parent
	end
	return parent or nil
end

function Language:getParentCode()
	local parent = self._parentCode
	if parent == nil then
		-- If the value is nil, it's cached as false.
		parent = self._data.parent or false
		self._parentCode = parent
	end
	return parent or nil
end

function Language:getAncestors()
	if not self._ancestorObjects then
		self._ancestorObjects = {}
		
		if self._rawData.ancestors then
			for _, ancestor in ipairs(self._rawData.ancestors) do
				table.insert(self._ancestorObjects, export.getByCode(ancestor) or require("モジュール:etymology languages").getByCode(ancestor))
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
	local name = self:getCanonicalName()
	
	-- If the name already has "language" in it, don't add it.
	if name:find("[Ll]anguage$") then
		return name
	else
		return name .. ""
	end
end


function Language:makeCategoryLink()
	return "[[:Category:" .. self:getCategoryName() .. "|" .. self:getCanonicalName() .. "]]"
end


function Language:getStandardCharacters()
	return self._rawData.standardChars
end


function Language:makeEntryName(text)
	text = mw.ustring.match(text, "^[¿¡]?(.-[^%s%p].-)%s*[؟?!;՛՜ ՞ ՟？！︖︕।॥။၊་།]?$") or text
	
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
	
	if type(self._rawData.entry_name) == "table" then
		text = do_entry_name_or_sort_key_replacements(text, self._rawData.entry_name)
	end
	
	return text
end


-- Add to data tables?
local has_dotted_undotted_i = {
	["az"] = true,
	["crh"] = true,
	["gag"] = true,
	["kaa"] = true,
	["tt"] = true,
	["tr"] = true,
	["zza"] = true,
}

function Language:generateForms(text, sc)
	local generate_forms = self._data.generate_forms
	if generate_forms == nil then
		return {text}
	end
	sc = checkScript(text, self, sc)
	return require("モジュール:" .. self._data.generate_forms).generateForms(text, self, sc)
end

function Language:makeSortKey(name, sc)
	if has_dotted_undotted_i[self:getCode()] then
		name = name:gsub("I", "ı")
	end
	
	name = mw.ustring.lower(name)
	
	-- Remove initial hyphens and *
	local hyphens_regex = "^[-־ـ*]+(.)"
	name = mw.ustring.gsub(name, hyphens_regex, "%1")
	
	-- If there are language-specific rules to generate the key, use those
	if type(self._rawData.sort_key) == "table" then
		name = do_entry_name_or_sort_key_replacements(name, self._rawData.sort_key)
	elseif type(self._rawData.sort_key) == "string" then
		name = require("モジュール:" .. self._rawData.sort_key).makeSortKey(name, self:getCode(), sc and sc:getCode())
	end
	
	-- Remove parentheses, as long as they are either preceded or followed by something
	name = mw.ustring.gsub(name, "(.)[()]+", "%1")
	name = mw.ustring.gsub(name, "[()]+(.)", "%1")
	
	if has_dotted_undotted_i[self:getCode()] then
		name = name:gsub("i", "İ")
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


function Language:transliterate(text, sc, module_override)
	if not ((module_override or self._rawData.translit_module) and text) then
		return nil
	end
	
	if module_override then
		require("モジュール:debug").track("module_override")
	end
	
	return require("モジュール:" .. (module_override or self._rawData.translit_module)).tr(text, self:getCode(), sc and sc:getCode() or nil)
end

function Language:hasTranslit()
	return self._rawData.translit_module and true or false
end


function Language:link_tr()
	return self._rawData.link_tr and true or false
end


function Language:toJSON()
	local entryNamePatterns = nil
	local entryNameRemoveDiacritics = nil
	
	if self._rawData.entry_name then
		entryNameRemoveDiacritics = self._rawData.entry_name.remove_diacritics
		if self._rawData.entry_name.from then
			entryNamePatterns = {}
			for i, from in ipairs(self._rawData.entry_name.from) do
				local to = self._rawData.entry_name.to[i] or ""
				table.insert(entryNamePatterns, { from = from, to = to })
			end
		end
	end
	
	local ret = {
		ancestors = self._rawData.ancestors,
		canonicalName = self:getCanonicalName(),
		categoryName = self:getCategoryName(),
		code = self._code,
		entryNamePatterns = entryNamePatterns,
		entryNameRemoveDiacritics = entryNameRemoveDiacritics,
		family = self._rawData[3] or self._rawData.family,
		otherNames = self:getOtherNames(true),
		aliases = self:getAliases(),
		varieties = self:getVarieties(),
		scripts = self._rawData.scripts,
		type = self:getType(),
		wikimediaLanguages = self._rawData.wikimedia_codes,
		wikidataItem = self:getWikidataItem(),
	}
	
	return require("モジュール:JSON").toJSON(ret)
end


-- Do NOT use this method!
-- All uses should be pre-approved on the talk page!
function Language:getRawData()
	return self._rawData
end

Language.__index = Language


function export.getDataModuleName(code)
	if code:find("^%l%l$") then
		return "languages/data2"
	elseif code:find("^%l%l%l$") then
		local prefix = code:sub(1, 1)
		return "languages/data3/" .. prefix
	elseif code:find("^[%l-]+$") then
		return "languages/datax"
	else
		return nil
	end
end


local function getRawLanguageData(code)
	local modulename = export.getDataModuleName(code)
	return modulename and mw.loadData("モジュール:" .. modulename)[code] or nil
end


function export.makeObject(code, data)
	if data and data.deprecated then
		require("モジュール:debug").track {
			"languages/deprecated",
			"languages/deprecated/" .. code
		}
	end
	
	return data and setmetatable({ _rawData = data,  _data = data,  _code = code }, Language) or nil
end


function export.getByCode(code, paramForError, allowEtymLang, allowFamily)
	if type(code) ~= "string" then
		error("The function getByCode expects a string as its first argument, but received " .. (code == nil and "nil" or "a " .. type(code)) .. ".")
	end
	
	local retval = export.makeObject(code, getRawLanguageData(code))
	if not retval and allowEtymLang then
		retval = require("モジュール:etymology languages").getByCode(code)
	end
	if not retval and allowFamily then
		retval = require("モジュール:families").getByCode(code)
	end
	if not retval and paramForError then
		local codetext = nil
		if allowEtymLang and allowFamily then
			codetext = "language, etymology language or family code"
		elseif allowEtymLang then
			codetext = "language or etymology language code"
		elseif allowFamily then
			codetext = "language or family code"
		else
			codetext = "language code"
		end
		export.err(code, paramForError, codetext)
	end
	return retval
end


function export.getByName(name, errorIfInvalid)
	local byName = mw.loadData("モジュール:languages/by name")
	local code = byName.all and byName.all[name] or byName[name]
	
	if not code then
		if errorIfInvalid then
			error("The language name \"" .. name .. "\" is not valid.")
		else
			return nil
		end
	end
	
	return export.makeObject(code, getRawLanguageData(code))
end

function export.getByCanonicalName(name, errorIfInvalid, allowEtymLang, allowFamily)
	local byName = mw.loadData("モジュール:languages/code to canonical name")
	local code = byName and byName[name]

	local retval = code and export.makeObject(code, getRawLanguageData(code)) or nil
	if not retval and allowEtymLang then
		retval = require("モジュール:etymology languages").getByCanonicalName(name)
	end
	if not retval and allowFamily then
		local famname = name:match("^(.*) languages$")
		famname = famname or name
		retval = require("モジュール:families").getByCanonicalName(famname)
	end
	if not retval and errorIfInvalid then
		local text
		if allowEtymLang and allowFamily then
			text = "language, etymology language or family name"
		elseif allowEtymLang then
			text = "language or etymology language name"
		elseif allowFamily then
			text = "language or family name"
		else
			text = "language name"
		end
		error("The " .. text .. " \"" .. name .. "\" is not valid.")
	end
	return retval
end

function export.iterateAll()
	mw.incrementExpensiveFunctionCount()
	local m_data = mw.loadData("モジュール:languages/alldata")
	local func, t, var = pairs(m_data)
	
	return function()
		local code, data = func(t, var)
		return export.makeObject(code, data)
	end
end

function export.getNonEtymological(lang)
	while lang:getType() == "etymology language" do
		local parentCode = lang:getParentCode()
		lang = export.getByCode(parentCode)
			or require("モジュール:etymology languages").getByCode(parentCode)
			or require("モジュール:families").getByCode(parentCode)
	end
	
	return lang
end

-- "eng" -> "en"
-- "cmn" -> "cmn"
function export.code3_to_code2(code)
	return mw.loadData("モジュール:languages/code3 to code2")[code] or code
end

function export.getCanonicalNameByCode(code)
	return mw.loadData("モジュール:languages/code to canonical name")[code]
end

function export.getSectionNameByCode(code)
	return mw.loadData("モジュール:languages/section names")[code] or mw.loadData("モジュール:languages/code to canonical name")[code]
end

function export.getTranslationNameByCode(code)
	return mw.loadData("モジュール:languages/translation names")[code] or mw.loadData("モジュール:languages/code to canonical name")[code]
end

function export.finalizeData(data, type, sort)
    return data
end

function export.finalizeData(data, type, sort)
    for _, lang in pairs(data) do
        if type == "language" and _ ~= "alias" then
            if not lang.getFullCode then
                lang.getFullCode = lang.getCode or function(self) return self._code or self[1] end
            end
        end
    end
    return data
end

if export.Language and export.Language.getCode then
    export.Language.getFullCode = export.Language.getCode
end

return export