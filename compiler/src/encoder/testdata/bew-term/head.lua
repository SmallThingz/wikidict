local langModule = require('Modul:lang')
local scripts = require('Modul:scripts')
local utils = require('Modul:utilities')
local p = {}

-- Generate anchor for a language
local function getLangAnchor(lang)
	return langModule.getLangName({ args = { [1] = lang } })
end

-- Generate homid anchor
local function makeAnchor(lang, homid)
	if not homid or homid == "" then
		return ""
	end

	local langName = getLangAnchor(lang)
	local id = langName .. ":" .. homid

	return mw.html.create("span")
		:attr("id", mw.uri.anchorEncode(id))
		:allDone()
end

-- Link individual words only if multi-word; single word = no link
local function linkWords(text, lang)
	if not text then return nil end
	text = mw.text.trim(text)
	local isProto = langModule.protoLangs[lang]
	local words = mw.text.split(text, "[%s,!?]+")
	local separators = mw.text.split(text, "[^%s,!?]+")

	-- Unlink single-word protolang
	if isProto and #words == 1 then
		return text
	end

	local linkedWords = {}
	local anchor = getLangAnchor(lang)
	for _, word in ipairs(words) do
		word = mw.text.trim(word)
		if isProto then
			table.insert(linkedWords, string.format("[[Lampiran:%s/%s|%s]]", anchor, word, word))
		elseif #words > 1 then
			table.insert(linkedWords, string.format("[[%s#%s|%s]]", word, anchor, word))
		else
			table.insert(linkedWords, word)
		end
	end

	local result = {}
	for i, w in ipairs(linkedWords) do
		table.insert(result, w)
		if separators[i + 1] then
			table.insert(result, separators[i + 1])
		end
	end

	return table.concat(result)
end

-- Reformat all wiki links in text with language anchors
local function reformatAllLinks(text, lang)
	if not text then return nil end
	text = mw.text.trim(text)
	local isProto = langModule.protoLangs[lang]
	local anchor = getLangAnchor(lang)

	if isProto and not mw.ustring.find(text, "%s") then
		return text
	end

	return mw.ustring.gsub(text, "%[%[([^%[%]|]+)(|?)([^%[%]]*)%]%]", function(target, bar, display)
		target = mw.text.trim(target)
		display = (bar == "|" and display ~= "") and display or target
		if isProto then
			return string.format("[[Tèmplokan:%s/%s|%s]]", anchor, target, display)
		else
			return string.format("[[%s#%s|%s]]", target, anchor, display)
		end
	end)
end

local function formatNum(num)
	return num and string.format('<sup style="font-weight:normal; color:#888888;">%s</sup>&#32;', num) or ""
end

local function formatForms(forms)
	if not forms or #forms == 0 then return "" end
	return string.format('&#32;<span style="font-weight:normal;">(%s)</span>', table.concat(forms, ", "))
end

local function formatCategory(isMultiword, namespace, lang, hasTr, hasAlt, hasNum)
	local cats = {}
	local sortkey = utils.getSortkey()
	
	-- only in mainspace
	if namespace == "" then
		if isMultiword then
			table.insert(cats, utils.langcat(lang, "Setilah rèndèngan kata", sortkey))
		end
		if hasTr then
			table.insert(cats, utils.langcat(lang, "Setilah dengen penglatènan", sortkey))
		end
		if hasAlt then
			table.insert(cats, utils.langcat(lang, "Setilah dengen ragem hurup laènan", sortkey))
		end
		if hasNum then
			table.insert(cats, utils.langcat(lang, "Setilah sejogrokan", sortkey))
		end
	end

	return table.concat(cats)
end

-- Add asterisk if language is a protolang
local function addAsterisk(lang, content)
	if langModule.protoLangs[lang] then
		return "&#42;" .. content
	else
		return content
	end
end

-- Main function
function p.box(frame)
	local args = frame:getParent().args
	local lang = args[1] or ""
	local homid = args["homid"]
	local entry = args["entry"]
	local entrysc = args["entrysc"]
	local tr = args["tr"]
	local num = args["num"]
	local altscGlobal = args["altsc"]

	-- Detect scripts if not provided
	if not entrysc and entry then entrysc = scripts.detect(entry) end

	-- Process entry
	local linkedEntry = scripts.wrap(reformatAllLinks(entry, lang) or linkWords(entry, lang), entrysc)

	-- Collect alternative forms (alt= or altN=)
	local alts, trs = {}, {}

	-- alt= is treated as alt1=
	if args["alt"] and not args["alt1"] then
		args["alt1"] = args["alt"]
		if args["altsc"] and not args["alt1sc"] then
			args["alt1sc"] = args["altsc"]
		end
	end

	local i = 1
	while args["alt" .. i] do
		local alt = args["alt" .. i]
		local altsc = args["alt" .. i .. "sc"] or altscGlobal or scripts.detect(alt)
		local rawAlt

		if mw.ustring.find(alt, "%[%[") then
			rawAlt = reformatAllLinks(alt, lang)
		else
			local anchor = getLangAnchor(lang)
			rawAlt = string.format("[[%s#%s|%s]]", alt, anchor, alt)
		end

		if rawAlt then
			table.insert(alts, scripts.wrap(rawAlt, altsc))
		end
		i = i + 1
	end

	-- Collect tr separately
	if tr then
		local rawTr
		if mw.ustring.find(tr, "%[%[") then
			rawTr = reformatAllLinks(tr, lang)
		else
			rawTr = tr
		end
		if rawTr then
			table.insert(trs, scripts.wrap(rawTr, scripts.detect(tr)))
		end
	end

	-- Fallback: use subpagename if no entry
	local title = mw.title.getCurrentTitle()
	local subpagename = title.subpageText
	local namespace = title.nsText
	local isMultiword = mw.ustring.find(subpagename, "%s")

	local content
	if linkedEntry then
		content = linkedEntry
	elseif subpagename then
		local fallback = linkWords(subpagename, lang)
		local fallbacksc = scripts.detect(subpagename)
		content = scripts.wrap(fallback, fallbacksc)
	end

	-- Apply protolang asterisk
	content = addAsterisk(lang, content)

	-- Interwiki + language name
	local interwiki = langModule.getInterwikiLink(lang, subpagename)
	local langName = langModule.getLangName({ args = { [1] = lang, nocap = "1" } })

	local anchorSpan = makeAnchor(lang, homid)

	-- Build HTML
	local html = string.format([[
<div class="headword-wrapper" title="Jèmbrèngan%s bakal &quot;%s&quot; dalem %s" style="margin-top:0.4em; border-top:1px dashed var(--faded-border,#AAA); color:var(--faded-font,#333); overflow-x:auto; overflow-y:clip; display:block;">%s
  <div class="headword-inner" style="padding-top: 1.2em; color: var(--faded-font, #333);">
    <h3 data-lang="%s" data-title="%s" style="padding:0; margin:0;">%s<span style="font-weight: normal; line-height:1.4em; font-size: 1.4em; color: var(--faded-font, #333);">%s</span>%s&#32;<sub style="font-size:0.7em; font-weight: normal; color: #888888;">&#91;%s&#93;</sub></h3>
  </div>
</div>%s
]],
	num and (' ' .. num) or "",
	subpagename or "",
	langName or "",
	tostring(anchorSpan),
	lang,
	subpagename or "",
	formatNum(num),
	content or "",
	formatForms(#alts > 0 and alts or trs),
	interwiki,
	formatCategory(isMultiword, namespace, lang, #trs > 0, #alts > 0, num ~= nil)
	)

	return html
end

return p