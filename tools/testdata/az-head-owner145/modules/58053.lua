local export = {}

-- Part of speech types that should not be pluralized.
local invariable = {
	["cmavo"] = true,
	["cmene"] = true,
	["fu'ivla"] = true,
	["gismu"] = true,
	["Han tu"] = true,
	["hanzi"] = true,
	["hanja"] = true,
	["jyutping"] = true,
	["kanji"] = true,
	["lujvo"] = true,
	["phrasebook"] = true,
	["pinyin"] = true,
	["rafsi"] = true,
	["romaji"] = true,
	["İsim"] = true,
	["Feilin formaları"] = true,
	["Feil"] = true,
	["İsmin halları"] = true,
	["Ədat"] = true,
	["Xüsusi isim"] = true,
	["Nida"] = true,
	["İsmin halları"] = true,
}

local params = {
	[1] = {required = true, default = "und"},
	["sc"] = {},
	["cat sc"] = {},
	["sort"] = {},
	
	[2] = {required = true},
	["cat2"] = {},
	["cat3"] = {},
	["cat4"] = {},
	
	["head"] = {list = true, allow_holes = true, default = ""},
	["tr"] = {list = true, allow_holes = true},
	["g"] = {list = true},
	
	[3] = {list = true, allow_holes = true},
	
	["f=accel"]   = {list = true, allow_holes = true},
	["f=request"] = {list = true, allow_holes = true},
	["f=alt"]     = {list = true, allow_holes = true},
	["f=sc"]      = {list = true, allow_holes = true},
	["f=id"]      = {list = true, allow_holes = true},
	["f=tr"]      = {list = true, allow_holes = true},
	["f=g"]       = {list = true, allow_holes = true},
	["f=qual"]    = {list = true, allow_holes = true},
	["f=nolink"]  = {list = true, allow_holes = true, type = "boolean"},
	["f=lang"]    = {list = true, allow_holes = true},
}

function export.head_t(frame)
	local args = require("Module:parameters").process(frame:getParent().args, params)
	
	-- Get language and script information
	local lang = args[1]
	local sc = args["sc"]
	local cat_sc = args["cat sc"]
	lang = require("Module:languages").getByCode(lang) or error("The language code \"" .. lang .. "\" is not valid.")
	
	if cat_sc then
		cat_sc = (cat_sc and (require("Module:scripts").getByCode(cat_sc) or error("The script code \"" .. cat_sc .. "\" is not valid.")) or nil)
		sc = cat_sc
	else
		sc = (sc and (require("Module:scripts").getByCode(sc) or error("The script code \"" .. sc .. "\" is not valid.")) or nil)
	end
	
	-- Gather basic parameters
	local sort_key = args["sort"]
	local pos = args[2]
	local cat2 = args["cat2"]
	local cat3 = args["cat3"]
	local cat4 = args["cat4"]
	local heads = args["head"]
	local translits = args["tr"]
	local genders = args["g"]
	local accels = args["faccel"]
	local requests = args["frequest"]
	local alts = args["falt"]
	local gs = args["fg"]
	local ids = args["fid"]
	local langs = args["flang"]
	local nolinks = args["fnolink"]
	local quals = args["fqual"]
	local scs = args["fsc"]
	local trs = args["ftr"]
	
	-- Gather inflected forms
	local inflections = {}
	
	-- Go over all the inflection parameters
	for i = 1, math.ceil(args[3].maxindex / 2) do
		local infl_part = {
			label    = args[3][i * 2 - 1],
			accel    = accels[i],
			request  = requests[i],
			}
		
		local form = {
			term       =  args[3][i * 2],
			alt        =  alts[i],
			genders    = {gs[i]},
			id         =  ids[i],
			lang       =  langs[i],
			nolink     =  nolinks[i],
			qualifiers = {quals[i]},
			sc         =  scs[i],
			translit   =  trs[i],
			}
		
		if form.lang ~= nil then
			form.lang = require("Module:languages").getByCode(form.lang) or error("The language code \"" .. form.lang .. "\" is not valid.")
		end
		
		if form.sc ~= nil then
			form.sc = require("Module:scripts").getByCode(form.sc) or error("The script code \"" .. form.sc .. "\" is not valid.")
		end
		
		-- If no term or alt is given, then the label is shown alone.
		if form.term or form.alt then
			table.insert(infl_part, form)
		end
		
		if infl_part.label == "or" then
			-- Append to the previous inflection part, if one exists
			if #infl_part > 0 and inflections[1] then
				table.insert(inflections[#inflections], form)
			end
		elseif infl_part.label then
			-- Add a new inflection part
			table.insert(inflections, infl_part)
		end
	end
	
	-- Get/set categories
	local categories = {}
	local tracking_categories = {}
	
	if pos then
		if not pos:find("s$") and not invariable[pos] then
			-- Make the plural form of the part of speech
			if pos:find("x$") then
				pos = pos .. "es"
			else
				pos = pos .. "s"
			end
		end
		
		table.insert(categories, lang:getCanonicalName() .. " " .. pos .. (cat_sc and " in " .. cat_sc:getCategoryName() or ""))
	end
	
	if cat2 then
		table.insert(categories, lang:getCanonicalName() .. " " .. cat2)
	end
	
	if cat3 then
		table.insert(categories, lang:getCanonicalName() .. " " .. cat3)
	end
	
	if cat4 then
		table.insert(categories, lang:getCanonicalName() .. " " .. cat4)
	end
	
	if #categories == 0 and mw.title.getCurrentTitle().nsText == "Template" then
		categories = {"Undetermined nouns"}
	end
	
	return
		require("Module:headword").full_headword(lang, sc, heads, translits, genders, inflections, categories, sort_key) ..
		require("Module:utilities").format_categories(tracking_categories, lang, sort_key)
end

return export