//! End-to-end bundle test: Lua/templates execute before data blobs are published.
const std = @import("std");
const expander = @import("bundle_expander.zig");

const source =
    "==English==\n===Noun===\n{{forms-alias|mouse}}\n" ++
    "# A small rodent.\n{{Template:Template:nested}}\n{{nested}}\n{{T:nested}}\n" ++
    "{{:SharedAlias}}\n{{WT:Sandbox}}\n" ++
    "{{User:Fixture/Forms|word=mouse}}\n" ++
    "{{#categorytree:Integration categories|mode=pages}}\n" ++
    "# Missing transclusions: {{User:Absent}} / {{:Absent article}} / {{Category:Absent}}\n" ++
    "# Styled kanji: '''<span class=\"Jpan\" lang=\"ja\">兇</span>''' / '''<span lang=\"ja\">[[:凶#Japanese|凶]]</span>'''\n" ++
    "# Title magic: {{SUBJECTSPACE:Wiktionary talk:Sandbox}} / {{TALKSPACE:WT:Sandbox}}\n" ++
    "# Parser functions: {{#time:Y M d|2013-3-31 +8 days}} / {{#formatdate:2010-01-02|dmy}} / {{#sub:αβγ|-1}} / {{#iferror:{{#expr:bogus}}|ERR|OK}}\n" ++
    "# Synth fork: {{#invoke:IntegrationSynth|run|forked}}\n" ++
    "# Pure fork: {{#invoke:IntegrationPureDataProbe|run}}\n" ++
    "# Captured fork: {{#invoke:IntegrationCapturedProbe|run}}\n" ++
    "# Repair recovery: {{repair-parent|x=term&lt;t:gloss&gt;}}\n" ++
    "# Graceful Lua error: {{#invoke:IntegrationForms|fail_probe}}\n" ++
    "# Formatting magic: {{formatnum:11000}} / {{formatnum:1,234.50|R}} / {{anchorencode:[[foo|A B]] <b>x</b>&nbsp;C}}\n" ++
    "# Title parts: {{#titleparts:A/B/C|1|2}} / {{#titleparts:A/B/C|-1}}\n" ++
    "# Escaped title: {{PAGENAMEE:Appendix:A B/é?x}} / {{FULLPAGENAMEE:Appendix:A B/é?x}}\n" ++
    "# Subpage namespaces: {{BASEPAGENAME:Template:foo/bar}} / {{BASEPAGENAME:Category:foo/bar}}\n" ++
    "# Site magic: {{SERVER}} / {{SERVERNAME}}\n" ++
    "# Revision metadata: {{PAGEID}} / {{REVISIONID}} / {{REVISIONTIMESTAMP}} / {{REVISIONUSER}} / {{PAGEID:rat}} / {{REVISIONUSER:rat}}\n";
const module_source =
    \\local concat_prefix = 'A'
    \\local concat_first = concat_prefix .. ('\000' .. 'β')
    \\assert(concat_first == 'A\000β')
    \\assert(concat_first .. ('c' .. '') == 'A\000βc')
    \\assert(('\255' .. '\000') == string.char(255, 0))
    \\local function concat_dynamic(x) return x .. ('b' .. 'c') end
    \\assert(concat_dynamic('a') == 'abc')
    \\local concat_mutable = 'old'
    \\local function concat_change() concat_mutable = 'new'; return 'tail' end
    \\assert(concat_mutable .. concat_change() == 'oldtail' and concat_mutable == 'new')
    \\assert(not pcall(function() return ('a' .. 'b') .. {} end))
    \\assert('x' .. 12 == 'x12')
    \\local concat_ok, concat_error = pcall(function()
    \\    return ('a' .. 'b') .. (function() error('concat-late-error') end)()
    \\end)
    \\assert(not concat_ok and tostring(concat_error):find('concat-late-error', 1, true))
    \\local forms = require('Module:IntegrationFormsAlias')
    \\local synth = require('Module:IntegrationSynth')
    \\assert(synth.kind == 'mixed' and synth.answer == 42 and synth.nested.ok == true)
    \\assert(synth.run('direct') == 'synth:direct')
    \\synth.run = function(x) return 'mutated:' .. x end
    \\assert(synth.run('direct') == 'mutated:direct')
    \\assert(require('Module:IntegrationSynth') == synth)
    \\assert(package.loaded['Module:IntegrationSynth'] == synth)
    \\local pure = require('Module:IntegrationPureData')
    \\assert(pure.alpha[2] == 2 and pure.beta.ok == true and pure.beta.extra == 'x')
    \\pure.beta.extra = 'mutated'
    \\assert(require('Module:IntegrationPureData') == pure)
    \\assert(require('Module:IntegrationPureData').beta.extra == 'mutated')
    \\local captured = require('Module:IntegrationCapturedRoot')
    \\assert(captured('direct') == 'captured:direct')
    \\assert(require('Module:IntegrationCapturedRoot') == captured)
    \\assert(package.loaded['Module:IntegrationCapturedRoot'] == captured)
    \\local captured_override = function(x) return 'override:' .. x end
    \\package.loaded['Module:IntegrationCapturedRoot'] = captured_override
    \\assert(require('Module:IntegrationCapturedRoot') == captured_override)
    \\assert(require('Module:IntegrationCapturedRoot')('direct') == 'override:direct')
    \\package.loaded['Module:IntegrationCapturedRoot'] = captured
    \\local poison = require('Module:IntegrationPoison')
    \\assert(poison.probe() == 'poison' and type(next) == 'function')
    \\local saved_next = next
    \\next = 'local-poison'
    \\local local_pairs_text = ''
    \\for k, v in pairs({x = 1}) do local_pairs_text = local_pairs_text .. k .. v end
    \\assert(local_pairs_text == 'x1' and next == 'local-poison')
    \\next = saved_next
    \\local large_static = require('Module:IntegrationLargeStatic')
    \\assert(large_static.k129[1] == 129 and large_static.k129[2] == 'v129')
    \\local bit32 = require('bit32')
    \\assert(bit32.band(240, 60) == 48 and bit32.bor(16, 3, 64) == 83)
    \\assert(require('bit32') == bit32)
    \\local libraryUtil = require('libraryUtil')
    \\libraryUtil.checkType('integration', 1, 'ok', 'string')
    \\local type_ok, type_err = pcall(libraryUtil.checkType, 'integration', 2, 7, 'string')
    \\assert(not type_ok and type_err == "bad argument #2 to 'integration' (string expected, got number)")
    \\libraryUtil.checkTypeMulti('integration', 1, 7, {'string', 'number'})
    \\assert(require('libraryUtil') == libraryUtil)
    \\assert(type(debug) == 'table' and type(debug.traceback) == 'function')
    \\assert(debug.getmetatable == nil and debug.getinfo == nil)
    \\local protected_pairs = setmetatable({x = 1}, {__metatable = 'hidden', __pairs = function() return next, {y = 2}, nil end})
    \\local protected_pairs_text = ''
    \\for k, v in pairs(protected_pairs) do protected_pairs_text = protected_pairs_text .. k .. v end
    \\assert(protected_pairs_text == 'y2' and getmetatable(protected_pairs) == 'hidden')
    \\local protected_ipairs = setmetatable({1}, {__metatable = false, __ipairs = function() return ipairs({7, 8}) end})
    \\local protected_ipairs_text = ''
    \\for i, v in ipairs(protected_ipairs) do protected_ipairs_text = protected_ipairs_text .. i .. v end
    \\assert(protected_ipairs_text == '1728')
    \\local false_pairs_ok = pcall(function() for _ in pairs(setmetatable({}, {__pairs = false})) do end end)
    \\local false_ipairs_ok = pcall(function() for _ in ipairs(setmetatable({}, {__ipairs = false})) do end end)
    \\assert(not false_pairs_ok and not false_ipairs_ok)
    \\local order_mt = {__lt = function(a, b) return a.n < b.n end}
    \\local order_a = setmetatable({n = 1}, order_mt)
    \\local order_b = setmetatable({n = 2}, order_mt)
    \\assert(order_a < order_b and order_a <= order_b and not (order_b <= order_a) and order_b >= order_a)
    \\order_mt.__le = function() return false end
    \\assert(not (order_a <= order_b))
    \\local bad_a = setmetatable({}, {__lt = function() return true end})
    \\local bad_b = setmetatable({}, {__lt = function() return true end})
    \\local bad_compare_ok = pcall(function() return bad_a < bad_b end)
    \\assert(not bad_compare_ok)
    \\assert(tonumber(' \t1\r\n') == 1 and tonumber('0x10') == 16 and tonumber('0x10', 10) == 16)
    \\assert(tonumber('+0xFF', 16) == 255 and tonumber(10, 16) == 16 and tonumber('0xFF', 34) == 38673)
    \\assert(tonumber('-FFFFFFFFFFFFFFFF', 16) == 1 and tonumber('F.F', 16) == nil)
    \\assert(1 + ' 2 ' == 3 and 1 + '0x10' == 17)
    \\local function guarded_arith(a, b) return a + b, a - b, a * b, a / b, a % b, a ^ b end
    \\local ga, gs, gm, gd, gr, gp = guarded_arith(6, 2)
    \\assert(ga == 8 and gs == 4 and gm == 12 and gd == 3 and gr == 0 and gp == 36)
    \\assert(select(1, guarded_arith(' 2 ', 1)) == 3 and select(1, guarded_arith('0x10', 1)) == 17)
    \\local function guarded_compare(a, b) return a == b, a ~= b, a < b, a <= b, a > b, a >= b end
    \\local eq, ne, lt, le, gt, ge = guarded_compare(2, 3)
    \\assert(not eq and ne and lt and le and not gt and not ge)
    \\local nan = 0 / 0
    \\local nan_eq, nan_ne, nan_lt = guarded_compare(nan, nan)
    \\assert(not nan_eq and nan_ne and not nan_lt)
    \\local inf = 1 / 0
    \\assert(select(1, guarded_arith(inf, 1)) == inf)
    \\local _, _, neg_zero = guarded_arith(-0, 1)
    \\assert(neg_zero == 0 and 1 / neg_zero < 0)
    \\local boxed_events = {}
    \\local boxed_mt = {__add = function(a, b) boxed_events[#boxed_events + 1] = 'add'; return 19 end}
    \\local boxed_obj = setmetatable({}, boxed_mt)
    \\local function guarded_add(a, b) return a + b end
    \\assert(guarded_add(boxed_obj, 1) == 19 and boxed_events[1] == 'add')
    \\local boxed_bad = pcall(function() return select(1, guarded_arith(true, 1)) end)
    \\assert(not boxed_bad)
    \\local compare_bad = pcall(function() return select(3, guarded_compare(1, '1')) end)
    \\assert(not compare_bad)
    \\local order = {}
    \\local function mark(n) order[#order + 1] = n; return n end
    \\assert(mark(1) + mark(2) == 3 and order[1] == 1 and order[2] == 2)
    \\assert(tostring(1 / 3) == '0.33333333333333' and tostring(1e14) == '1e+14' and tostring(1e13) == '10000000000000')
    \\assert(tostring(1e-6) == '1e-06' and tostring(-0) == '-0' and (-0) .. '/' .. 1e14 == '-0/1e+14')
    \\assert(string.format('%s', 1 / 3) == '0.33333333333333')
    \\local base_type_ok = pcall(tonumber, true, 16)
    \\assert(not base_type_ok)
    \\local alias_name = 'Module:IntegrationFormsAlias'
    \\assert(require(alias_name).mouse == 'mice')
    \\return {
    \\frame_probe = function(frame) return frame.args.x end,
    \\repair_parent_probe = function(frame)
    \\    local x = frame:getParent().args.x
    \\    if string.find(x, '&lt;', 1, true) then error('Invalid page title "Reconstruction:Probe/' .. x .. '" encountered.') end
    \\    return 'repaired invoke'
    \\end,
    \\fail_probe = function() error('fixture failure') end,
    \\random_probe = function(frame) return math.random(1, 10), math.random(1, 10) end,
    \\render_dictionary_fixture = function(frame)
    \\    local auxiliary_title = mw.title.new('Appendix:IntegrationFixture')
    \\    assert(auxiliary_title:getContent() == 'a real auxiliary source page' and auxiliary_title.content == auxiliary_title:getContent())
    \\    assert(string.find(mw.title.new('Template:forms-alias'):getContent(), '#REDIRECT', 1, true))
    \\    assert(string.find(mw.title.new('SharedAlias'):getContent(), '#REDIRECT', 1, true))
    \\    local shared_alias = mw.title.new('SharedAlias')
    \\    assert(shared_alias.isRedirect and shared_alias.redirectTarget.prefixedText == 'Shared')
    \\    assert(shared_alias.id == 24 and shared_alias.redirectTarget.id == 23)
    \\    assert(mw.title.new('rat').contentModel == 'wikitext')
    \\    assert(mw.title.new('rat').isContentPage and not mw.title.new('Appendix:IntegrationFixture').isContentPage and not mw.title.new('Template:show-forms').isContentPage)
    \\    assert(not mw.title.new('rat').isExternal and mw.title.new('rat').isLocal)
    \\    local seen_namespaces, namespace_count = {}, 0
    \\    for id, namespace in next, mw.site.namespaces do
    \\        assert(type(id) == 'number' and not seen_namespaces[namespace])
    \\        seen_namespaces[namespace], namespace_count = true, namespace_count + 1
    \\    end
    \\    assert(namespace_count > 30)
    \\    assert(mw.site.namespaces.Template == mw.site.namespaces[10])
    \\    assert(mw.site.namespaces.user_talk == mw.site.namespaces[3])
    \\    assert(mw.site.namespaces.Special.isCapitalized and mw.site.namespaces.User.isCapitalized)
    \\    assert(not mw.site.namespaces[0].isCapitalized and not mw.site.namespaces.Template.isCapitalized)
    \\    local user_title = mw.title.new('User:example')
    \\    assert(user_title.prefixedText == 'User:Example' and user_title:inNamespace('User') and user_title:inNamespace(2) and not user_title:inNamespace('Module'))
    \\    assert(mw.title.new('User:ǰfoo').prefixedText == 'User:J̌foo')
    \\    assert(mw.title.new('User:ßeta').prefixedText == 'User:ßeta')
    \\    assert(mw.title.new('Template:example').prefixedText == 'Template:example')
    \\    assert(mw.title.makeTitle(2, 'example').prefixedText == 'User:Example')
    \\    local parameters_title = mw.title.new('Module:parameters')
    \\    local parameters_track_title = mw.title.new('Module:parameters/track')
    \\    assert(parameters_track_title:isSubpageOf(parameters_title) and not parameters_title:isSubpageOf(parameters_track_title))
    \\    local interwiki_ok = pcall(mw.title.new, 'w:Example')
    \\    assert(not interwiki_ok)
    \\    assert(mw.title.new('Module:IntegrationForms').contentModel == 'Scribunto')
    \\    assert(mw.title.new('Module:IntegrationForms', 10).prefixedText == 'Module:IntegrationForms')
    \\    assert(mw.title.makeTitle(10, 'Module:IntegrationForms').prefixedText == 'Template:Module:IntegrationForms')
    \\    local archive_title = mw.title.makeTitle('Wiktionary', 'Word of the day/Archive/2026/September', '17')
    \\    assert(archive_title.prefixedText == 'Wiktionary:Word of the day/Archive/2026/September' and archive_title.fragment == '17' and archive_title.fullText == 'Wiktionary:Word of the day/Archive/2026/September#17')
    \\    assert(mw.title.new('Foo&amp;Bar').prefixedText == 'Foo&Bar')
    \\    assert(mw.title.new('Module&#58;IntegrationForms', 10).prefixedText == 'Module:IntegrationForms')
    \\    assert(mw.title.makeTitle(0, 'Foo&amp;Bar') == nil)
    \\    assert(mw.title.new('Foo&amp;amp;Bar') == nil)
    \\    assert(mw.title.new('  foo__  bar  ').prefixedText == 'foo bar')
    \\    assert(mw.title.new(':foo', 10).prefixedText == 'foo')
    \\    assert(mw.title.new('Template : Foo').prefixedText == 'Template:Foo')
    \\    assert(mw.title.new('foo[bar') == nil and mw.title.new('foo%20bar') == nil and mw.title.new('foo/../bar') == nil)
    \\    assert(mw.title.new('Cafe&#x301;').prefixedText == 'Café')
    \\    local bad_namespace = pcall(mw.title.new, 'Thing', 'not-a-namespace')
    \\    assert(not bad_namespace)
    \\    assert(mw.title.new('Module:DefinitelyMissing').contentModel == 'Scribunto')
    \\    assert(mw.title.new('User:Example/common.css').contentModel == 'css')
    \\    assert(mw.hash.hashValue('md5', 'abc') == '900150983cd24fb0d6963f7d28e17f72')
    \\    assert(mw.ustring.upper('straße ﬃ') == 'STRASSE FFI')
    \\    assert(mw.ustring.lower('İ') == 'i̇')
    \\    assert(mw.text.truncate('wako', -2, '') == 'ko')
    \\    assert(mw.text.decode('can&#39;t &amp; stay') == [[can't & stay]])
    \\    local official_uri = mw.uri.new('https://main.knesset.gov.il/apps/smartprotocol/session/123/456?itemid=7')
    \\    assert(mw.uri.validate(official_uri))
    \\    assert(official_uri.protocol == 'https' and official_uri.host == 'main.knesset.gov.il')
    \\    assert(official_uri.path == '/apps/smartprotocol/session/123/456' and official_uri.query.itemid == '7')
    \\    assert(type(mw.site.stats.pagesInCategory) == 'function' and type(mw.site.stats.pagesInNamespace) == 'function' and type(mw.site.stats.usersInGroup) == 'function')
    \\    local stats_ok = pcall(function() return mw.site.stats.pages end)
    \\    assert(not stats_ok)
    \\    assert(type(mw.wikibase.getEntityIdForTitle) == 'function')
    \\    local wikibase_ok = pcall(mw.wikibase.getEntityIdForTitle, 'cat')
    \\    assert(not wikibase_ok)
    \\    assert(type(mw.ext.data.get) == 'function')
    \\    local jsonconfig_ok = pcall(mw.ext.data.get, 'Unicode/data')
    \\    assert(not jsonconfig_ok)
    \\    local main_message = mw.message.new('mainpage')
    \\    assert(main_message:exists() and not main_message:isBlank() and not main_message:isDisabled())
    \\    assert(main_message:plain() == '{{ns:Project}}:Main Page' and tostring(main_message) == '{{ns:Project}}:Main Page')
    \\    assert(frame:preprocess(main_message:plain()) == 'Wiktionary:Main Page')
    \\    local missing_message = mw.message.new('definitely-missing-message')
    \\    assert(not missing_message:exists() and missing_message:isBlank() and missing_message:isDisabled())
    \\    assert(missing_message:plain() == '⧼definitely-missing-message⧽')
    \\    assert(mw.message.newRawMessage('raw $1 / $2', 'value', 7):plain() == 'raw value / 7')
    \\    assert(tostring(mw.html.create('div'):tag('br'):allDone()) == '<div><br /></div>')
    \\    assert(mw.text.encode('a&b') == 'a&amp;b')
    \\    assert(mw.text.tag('div', {class = 'chart'}, 'x') == '<div class=\"chart\">x</div>')
    \\    assert(mw.text.tag('div', {class = 'chart'}) == '<div class=\"chart\">')
    \\    local strip_marker = frame:extensionTag('nowiki', 'hidden')
    \\    assert(mw.text.killMarkers('a' .. strip_marker .. 'b') == 'ab')
    \\    assert(frame:preprocess('{{#len:é猫}}') == '2')
    \\    assert(frame:preprocess('{{ucfirst:ßeta}}|{{ucfirst:ǰfoo}}|{{lcfirst:Éclair}}') == 'ßeta|J̌foo|éclair')
    \\    local json_value = mw.text.jsonDecode('{"x":[1,2]}', mw.text.JSON_TRY_FIXING)
    \\    assert(json_value.x[2] == 2 and mw.text.jsonEncode(json_value) == '{"x":[1,2]}')
    \\    local json_data = mw.loadJsonData('Module:IntegrationFormsData.json')
    \\    assert(json_data.cuts[2] == 2 and json_data.nested.ok)
    \\    assert(json_data == mw.loadJsonData('Module:IntegrationFormsData.json'))
    \\    local json_write_ok = pcall(function() json_data.cuts[1] = 9 end)
    \\    assert(not json_write_ok)
    \\    assert(mw.getContentLanguage():uc('straße ﬃ') == 'STRASSE FFI')
    \\    assert(mw.getContentLanguage():lc('ÉCLAIR İ ΣΊΣΥΦΟΣ') == 'éclair i̇ σίσυφος')
    \\    assert(mw.getContentLanguage():ucfirst('hello') == 'Hello')
    \\    assert(mw.getContentLanguage():ucfirst('éclair') == 'Éclair')
    \\    assert(mw.getContentLanguage():ucfirst('ßeta') == 'ßeta')
    \\    assert(mw.getLanguage('it'):ucfirst('istanza') == 'Istanza')
    \\    assert(mw.getLanguage('it'):ucfirst('ǰfoo') == 'J̌foo')
    \\    local locale_registry_ok, locale_registry_known = pcall(mw.language.isKnownLanguageTag, 'fr')
    \\    assert(locale_registry_ok and locale_registry_known == false and mw.language.isKnownLanguageTag('en'))
    \\    local batch = mw.title.newBatch({'rat', 'definitely-not-a-real-entry'}):lookupExistence():getTitles()
    \\    assert(batch[1].exists and not batch[2].exists)
    \\    local media = mw.title.new('Media:Remote.svg')
    \\    assert(media.prefixedText == 'Media:Remote.svg')
    \\    local media_ok = pcall(function() return media.exists end)
    \\    assert(not media_ok)
    \\    local media_batch = mw.title.newBatch({'Media:Remote.svg'}):lookupExistence():getTitles()
    \\    local media_batch_ok = pcall(function() return media_batch[1].exists end)
    \\    assert(not media_batch_ok)
    \\    local child = frame:newChild{args = {x = 'child-frame', [1] = 7, flag = false}}
    \\    assert(child:getTitle() == frame:getTitle() and child:getParent() == frame and child.args.x == 'child-frame' and child.args[1] == '7' and child.args.flag == '')
    \\    local pinned_now = os.time()
    \\    assert(os.date('!%Y', pinned_now) == frame:preprocess('{{CURRENTYEAR}}'))
    \\    assert(os.date('!%Y%m%d%H%M%S', pinned_now) == frame:preprocess('{{CURRENTTIMESTAMP}}'))
    \\    local normalized_time = {year = 2024, month = 13, day = 1}
    \\    assert(os.date('!%Y-%m-%d %H:%M', os.time(normalized_time)) == '2025-01-01 12:00')
    \\    local rnd_a, rnd_b = require('Module:IntegrationForms').random_probe(frame)
    \\    assert(rnd_a == 9 and rnd_b == 4)
    \\    local xp_ok, xp_value = xpcall(function() error('xp') end, function(err) return 'handled:' .. err end)
    \\    assert(not xp_ok and xp_value == 'handled:xp')
    \\    local xp_success, xp_left, xp_right = xpcall(function() return 'left', 7 end, function(err) return err end)
    \\    assert(xp_success and xp_left == 'left' and xp_right == 7)
    \\    local protected_effects = 0
    \\    local function protected_tail() protected_effects = protected_effects + 1; return 9 end
    \\    local function protected_values() return 7, protected_tail() end
    \\    local protected_status = pcall(protected_values)
    \\    pcall(protected_values)
    \\    assert(protected_status and protected_effects == 2)
    \\    local late_ok, late_error = pcall(function() return 7, error(nil) end)
    \\    assert(not late_ok and late_error == nil)
    \\    local handled_count = 0
    \\    local function protected_handler(err) assert(err == nil); handled_count = handled_count + 1; return {}, 99 end
    \\    xpcall(function() error(nil) end, protected_handler)
    \\    local handled_status = xpcall(function() error(nil) end, protected_handler)
    \\    assert(not handled_status and handled_count == 2)
    \\    local handler_ok, handler_error = xpcall(function() error('body') end, function() return 7, error('handler tail') end)
    \\    assert(not handler_ok and handler_error == 'error in error handling')
    \\    assert(frame:callParserFunction{ name = '#invoke', args = {'IntegrationForms', 'frame_probe', x = 'frame-parser'} } == 'frame-parser')
    \\    assert(frame:callParserFunction{ name = '#tag:syntaxhighlight', args = {'x', lang = 'text'} } == '<syntaxhighlight lang="text">x</syntaxhighlight>')
    \\    assert(frame:callParserFunction{ name = '#tag', args = {'ref', 'body', 'name=n'} } == '<ref name="n">body</ref>')
    \\    assert(mw.title.new('rat'):fullUrl({action = 'view'}, 'https') == 'https://en.wiktionary.org/w/index.php?title=rat&action=view')
    \\    assert(mw.title.new('rat').exists)
    \\    assert(mw.title.new('rat').redirectTarget == false)
    \\    assert(string.find(mw.title.new('rat'):getContent(), 'Another rodent', 1, true))
    \\    local missing_entry = mw.title.new('definitely-not-a-real-entry')
    \\    assert(not missing_entry.exists and missing_entry.content == false and missing_entry:getContent() == nil)
    \\    for _, missing_title in ipairs({'Definitely absent template', 'User:Absent'}) do
    \\        local ok, err = pcall(function() return frame:expandTemplate{title = missing_title} end)
    \\        assert(not ok and err == 'expandTemplate: template "' .. missing_title .. '" does not exist')
    \\    end
    \\    local word = frame.args[1]
    \\    local plural = forms[word]
    \\    frame:callParserFunction("DISPLAYTITLE", "''" .. word .. "''")
    \\    return "'''"..word.."''' (plural ''"..plural.."'')\n\n" ..
    \\        "<table><caption>Forms from native Lua</caption><tr><td>"..plural.."</td></tr></table>\n"
    \\end }
;
const template_source =
    "<includeonly>{{#invoke:IntegrationForms|render_dictionary_fixture|{{{1}}}}}</includeonly>" ++
    "<noinclude>Documentation must not leak.</noinclude>";

const Page = struct { title: []const u8, ns: u16, id: u32, body: []const u8, user: []const u8 = "Fixture editor", redirect: ?[]const u8 = null, model: ?[]const u8 = null };
fn xml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(ch),
    };
}

fn writeFixture(io: std.Io, a: std.mem.Allocator, path: []const u8) !void {
    var large_static: std.Io.Writer.Allocating = .init(a);
    defer large_static.deinit();
    try large_static.writer.writeAll("return {");
    for (0..130) |index|
        try large_static.writer.print("k{d}={{{d},'v{d}'}},", .{ index, index, index });
    try large_static.writer.writeByte('}');

    const pages = [_]Page{
        .{ .title = "Category:Integration categories", .ns = 14, .id = 29, .body = "Category root" },
        .{ .title = "User:Fixture/Forms", .ns = 2, .id = 27, .body = "<noinclude>private documentation</noinclude><includeonly>{{/Child|{{{word}}}}}</includeonly>" },
        .{ .title = "User:Fixture/Forms/Child", .ns = 2, .id = 28, .body = "<templatestyles src=\"Template:forms.css\" /><div class=\"NavFrame\">\n{| class=\"wikitable\"\n| user-space inflection {{{1}}}\n|}\n</div>" },
        .{ .title = "mouse", .ns = 0, .id = 20, .body = source },
        .{ .title = "rat", .ns = 0, .id = 22, .body = "==English==\n===Noun===\n# Another rodent.\n", .user = "Rat editor" },
        .{ .title = "Shared", .ns = 0, .id = 23, .body = "shared main transclusion" },
        .{ .title = "SharedAlias", .ns = 0, .id = 24, .body = "#REDIRECT [[Shared]]", .redirect = "Shared" },
        .{ .title = "Wiktionary:Sandbox", .ns = 4, .id = 25, .body = "project namespace transclusion" },
        .{ .title = "MediaWiki:Mainpage", .ns = 8, .id = 26, .body = "{{ns:Project}}:Main Page" },
        .{ .title = "Appendix:IntegrationFixture", .ns = 100, .id = 21, .body = "a real auxiliary source page" },
        .{ .title = "Template:show-forms", .ns = 10, .id = 10, .body = template_source },
        .{ .title = "Template:repair-parent", .ns = 10, .id = 17, .body = "{{#invoke:IntegrationForms|repair_parent_probe}}" },
        .{ .title = "Template:forms-alias", .ns = 10, .id = 11, .body = "#REDIRECT [[Template:show-forms]]", .redirect = "Template:show-forms" },
        .{ .title = "Template:Template:nested", .ns = 10, .id = 12, .body = "nested namespace retained" },
        .{ .title = "Template:nested", .ns = 10, .id = 13, .body = "ordinary namespace distinct" },
        .{ .title = "Module:IntegrationForms", .ns = 828, .id = 1, .body = module_source },
        .{ .title = "Module:IntegrationSynth", .ns = 828, .id = 8, .body = "local answer = 42; local export = { kind = 'mixed', nested = { ok = true } }; local alias = export; alias.answer = answer; function alias.run(x) if type(x) == 'table' then return 'synth:' .. x.args[1] end; return 'synth:' .. x end; return export" },
        .{ .title = "Module:IntegrationPureData", .ns = 828, .id = 9, .body = "local root = {}; root.alpha = {1, 2}; root.beta = { ok = true }; local alias = root.beta; alias.extra = 'x'; return root" },
        .{ .title = "Module:IntegrationPureDataProbe", .ns = 828, .id = 14, .body = "local pure = require('Module:IntegrationPureData'); return { run = function() return pure.beta.extra end }" },
        .{ .title = "Module:IntegrationCapturedRoot", .ns = 828, .id = 15, .body = "local missing = nil; local enabled = false; local count = 7; local data; local function run(x) if missing == nil and not enabled and count == 7 then return data .. x end; return 'bad' end; data = 'captured:'; return run" },
        .{ .title = "Module:IntegrationCapturedProbe", .ns = 828, .id = 16, .body = "local captured = require('Module:IntegrationCapturedRoot'); return { run = function() return captured('forked') end }" },
        .{ .title = "Module:languages/canonical names", .ns = 828, .id = 3, .body = "return { [\"English\"] = \"en\" }" },
        .{ .title = "Module:IntegrationFormsData", .ns = 828, .id = 2, .body = "return { mouse = 'mice' }" },
        .{ .title = "Module:IntegrationPoison", .ns = 828, .id = 7, .body = "next = 'poison'; return { probe = function() return next end }" },
        .{ .title = "Module:IntegrationLargeStatic", .ns = 828, .id = 6, .body = large_static.written() },
        .{ .title = "Module:IntegrationFormsData.json", .ns = 828, .id = 5, .body = "{\"cuts\":[1,2],\"nested\":{\"ok\":true}}", .model = "json" },
        .{ .title = "Module:IntegrationFormsAlias", .ns = 828, .id = 4, .body = "#REDIRECT [[Module:IntegrationFormsData]]", .redirect = "Module:IntegrationFormsData" },
    };
    try writePages(io, a, path, &pages);
}

fn writePages(io: std.Io, a: std.mem.Allocator, path: []const u8, pages: []const Page) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<mediawiki>\n");
    for (pages) |page| {
        try w.print("<page><title>{s}</title><ns>{d}</ns><id>{d}</id>", .{ page.title, page.ns, page.id });
        if (page.redirect) |target| try w.print("<redirect title=\"{s}\"/>", .{target});
        try w.print("<revision><id>{d}</id><timestamp>2024-03-04T05:06:07Z</timestamp><contributor><username>", .{page.id + 100});
        try xml(w, page.user);
        const model = page.model orelse if (page.ns == 828 and page.redirect == null) "Scribunto" else "wikitext";
        try w.print("</username></contributor><model>{s}</model><text>", .{model});
        try xml(w, page.body);
        try w.writeAll("</text></revision></page>\n");
    }
    try w.writeAll("</mediawiki>\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

const Harness = struct {
    a: std.mem.Allocator,
    io: std.Io,
    checks: usize = 0,

    fn run(self: *Harness, argv: []const []const u8, expected: u8) ![]const u8 {
        const result = try std.process.run(self.a, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
            .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(180), .clock = .awake } }).toDeadline(self.io),
        });
        if (result.term != .exited or result.term.exited != expected) {
            std.debug.print("bundle integration child failed: {any}, expected {d}\n{s}\n{s}\n", .{
                result.term, expected, result.stdout, result.stderr,
            });
            return error.ChildFailed;
        }
        self.checks += 1;
        return result.stdout;
    }

    fn require(self: *Harness, ok: bool, label: []const u8) !void {
        if (ok) return;
        std.debug.print("bundle integration assertion failed after {d} checks: {s}\n", .{ self.checks, label });
        return error.AssertionFailed;
    }

    fn requireTimeout(self: *Harness, argv: []const []const u8) !void {
        const result = try std.process.run(self.a, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } }).toDeadline(self.io),
        });
        try self.require(result.term == .exited and result.term.exited == 1, "timeout fixture exits with failure");
        try self.require(std.mem.indexOf(u8, result.stderr, "error=Timeout") != null, "timeout fixture reached actual page expansion deadline");
        self.checks += 1;
    }
};

fn exists(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn deadlineProbe(io: std.Io, a: std.mem.Allocator, dir: []const u8) !void {
    var worker = expander.Worker.init(io, dir, "tail", "missing-dump.xml");
    worker.timeout_ms = 100;
    defer worker.deinit();
    try std.testing.expectError(error.Timeout, worker.expand(a, 0, "probe", "==English==\n"));
}

fn writeFailureExpander(h: *Harness, script: []const u8, stage: []const u8) !void {
    var reply: std.Io.Writer.Allocating = .init(h.a);
    defer reply.deinit();
    try @import("bundle_protocol").writeError(&reply.writer, stage, "E", "d");
    var text: std.Io.Writer.Allocating = .init(h.a);
    defer text.deinit();
    try text.writer.writeAll("#!/bin/sh\ndd bs=4096 count=1 of=/dev/null 2>/dev/null\nprintf '");
    for (reply.written()) |byte| try text.writer.print("\\{o:0>3}", .{byte});
    try text.writer.writeAll("'\n");
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = script, .data = text.written() });
    _ = try h.run(&.{ "chmod", "755", script }, 0);
}

fn failureMetadataProbe(h: *Harness, dir: []const u8) !void {
    const script = try std.fs.path.join(h.a, &.{ dir, "failure-expander.sh" });
    try writeFailureExpander(h, script, "x");
    var worker = expander.Worker.init(h.io, dir, script, "missing-dump.xml");
    defer worker.deinit();
    try std.testing.expectError(error.BundleInfrastructureFailed, worker.expand(h.a, 0, "probe", "==English==\n"));
    const failure = worker.last_failure orelse return error.MissingFailureMetadata;
    try h.require(std.mem.eql(u8, failure.stage, "x"), "worker failure stage survives transport");
    try h.require(std.mem.eql(u8, failure.error_name, "E"), "worker failure error name survives transport");
    try h.require(std.mem.eql(u8, failure.detail, "d"), "worker failure detail survives transport");
    const closed_script = try std.fs.path.join(h.a, &.{ dir, "closed-expander.sh" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = closed_script, .data = "#!/bin/sh\ndd bs=4096 count=1 of=/dev/null 2>/dev/null\nexit 7\n" });
    _ = try h.run(&.{ "chmod", "755", closed_script }, 0);
    var closed = expander.Worker.init(h.io, dir, closed_script, "missing-dump.xml");
    defer closed.deinit();
    try std.testing.expectError(error.WorkerClosed, closed.expand(h.a, 17, "closed-probe", "==English==\n"));
    try h.require(closed.child == null, "closed worker is reaped after bounded status capture");
}

fn coldRetryProbe(h: *Harness, blob_builder: []const u8, verifier: []const u8, root: []const u8, dump: []const u8, dir: []const u8) !void {
    const script = try std.fs.path.join(h.a, &.{ root, "dict-bundle-expander" });
    const mode_path = try std.fs.path.join(h.a, &.{ root, "retry-mode" });
    const count_path = try std.fs.path.join(h.a, &.{ root, "retry-count" });
    const pids_path = try std.fs.path.join(h.a, &.{ root, "retry-pids" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = script, .data =
        \\#!/usr/bin/env python3
        \\import os, struct, sys, time
        \\from pathlib import Path
        \\root = Path(__file__).parent
        \\mode = (root/'retry-mode').read_text().strip()
        \\attempt = int((root/'retry-count').read_text()) + 1
        \\(root/'retry-count').write_text(str(attempt))
        \\with (root/'retry-pids').open('a') as f: f.write(str(os.getpid())+'\n')
        \\def exact(n):
        \\    out = bytearray()
        \\    while len(out) < n:
        \\        part = sys.stdin.buffer.read(n-len(out))
        \\        if not part: return None
        \\        out.extend(part)
        \\    return bytes(out)
        \\def failure(name):
        \\    stage=b'expand'
        \\    return b'\x01'+struct.pack('<III',len(stage),len(name),0)+stage+name
        \\while True:
        \\    head=exact(4)
        \\    if head is None: break
        \\    body=exact(struct.unpack('<I',head)[0])
        \\    if body is None: break
        \\    (root/('retry-request-'+str(attempt))).write_bytes(head+body)
        \\    if mode=='semantic-initial': reply=failure(b'ExpectedSemanticError')
        \\    elif mode!='output-initial' and attempt==1: reply=failure(b'OutOfMemory')
        \\    elif mode=='oom': reply=failure(b'OutOfMemory')
        \\    elif mode=='semantic': reply=failure(b'ExpectedSemanticError')
        \\    elif mode=='skip': reply=b'\x02'
        \\    elif mode=='malformed': reply=b'\xff'
        \\    elif mode=='eof': break
        \\    elif mode=='truncated':
        \\        sys.stdout.buffer.write(struct.pack('<I',12)+b'\x00');sys.stdout.buffer.flush();break
        \\    elif mode=='timeout': time.sleep(5);break
        \\    else:
        \\        output=b'==English==\n# recovered\n'; title=b'Recovered' if mode=='output' else b''
        \\        reply=b'\x00'+struct.pack('<II',len(output),len(title))+output+title
        \\    sys.stdout.buffer.write(struct.pack('<I',len(reply))+reply);sys.stdout.buffer.flush()
        \\    if mode!='output-initial' and mode!='semantic-initial' and attempt==1: break
        \\
    });
    _ = try h.run(&.{ "chmod", "755", script }, 0);
    const input_source = "==English==\n# original input\n";
    const cases = [_]struct { mode: []const u8, expected: ?anyerror }{
        .{ .mode = "output", .expected = null },
        .{ .mode = "oom", .expected = error.OutOfMemory },
        .{ .mode = "semantic", .expected = error.ColdRetryFailed },
        .{ .mode = "skip", .expected = error.ColdRetryFailed },
        .{ .mode = "malformed", .expected = error.ColdRetryFailed },
        .{ .mode = "truncated", .expected = error.ColdRetryFailed },
        .{ .mode = "eof", .expected = error.ColdRetryFailed },
        .{ .mode = "timeout", .expected = error.ColdRetryFailed },
    };
    for (cases) |case| {
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = mode_path, .data = case.mode });
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = count_path, .data = "0" });
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = pids_path, .data = "" });
        var worker = expander.Worker.init(h.io, root, script, dump);
        defer worker.deinit();
        worker.now_unix = 1791072000;
        worker.timeout_ms = 1000;
        if (case.expected) |err| {
            try std.testing.expectError(err, worker.expand(h.a, 17, "retry-probe", input_source));
            try h.require(worker.child == null and worker.oom_retry_failed == 1, "failed cold retry is terminal and reaped");
        } else {
            const output = (try worker.expand(h.a, 17, "retry-probe", input_source)).?;
            try std.testing.expectEqualStrings("==English==\n# recovered\n", output.source);
            try std.testing.expectEqualStrings("Recovered", output.display_title.?);
            try h.require(worker.last_failure == null and worker.oom_retry_recovered == 1, "recovery clears stale failure metadata");
            const first = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, "retry-request-1" }), h.a, .limited(1024 * 1024));
            const second = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, "retry-request-2" }), h.a, .limited(1024 * 1024));
            try std.testing.expectEqualSlices(u8, first, second);
            const pids = try std.Io.Dir.cwd().readFileAlloc(h.io, pids_path, h.a, .limited(1024));
            var lines = std.mem.tokenizeScalar(u8, pids, '\n');
            const old = lines.next().?;
            const fresh = lines.next().?;
            try h.require(!std.mem.eql(u8, old, fresh), "OOM replacement has a distinct process");
            _ = (try worker.expand(h.a, 18, "next-probe", input_source)).?;
            try h.require(worker.last_failure == null and worker.generation == 2, "subsequent page reuses only recovered healthy child");
        }
        try h.require(worker.oom_retry_attempts == 1 and worker.generation == 2, "remote OOM gets exactly one replacement attempt");
    }
    // Allocation failure in the parent is never mistaken for a remote OOM.
    for ([_]usize{ 0, 1 }) |fail_at| {
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = mode_path, .data = if (fail_at == 0) "output-initial" else "output" });
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = count_path, .data = "0" });
        var arena = std.heap.ArenaAllocator.init(h.a);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = fail_at });
        var worker = expander.Worker.init(h.io, root, script, dump);
        defer worker.deinit();
        try std.testing.expectError(if (fail_at == 0) error.OutOfMemory else error.ColdRetryFailed, worker.expand(failing.allocator(), 17, "allocation-probe", input_source));
        try h.require(worker.child == null and worker.oom_retry_attempts == fail_at, "local OOM never starts an extra recovery");
    }
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = mode_path, .data = "output-valid-display" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = count_path, .data = "0" });
    const output_root = try std.fs.path.join(h.a, &.{ dir, "recovered-dictionary" });
    _ = try h.run(&.{ blob_builder, dump, output_root, "--expander-root", root, "--workers", "1", "--now-unix", "1791072000" }, 0);
    _ = try h.run(&.{ verifier, output_root }, 0);
    const fallbacks = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ output_root, "fallback-pages.jsonl" }), h.a, .limited(1024));
    try h.require(fallbacks.len == 0, "recovered output never becomes fallback text");
    try h.require(exists(h.io, try std.fs.path.join(h.a, &.{ output_root, "page-coverage.json" })), "successful cold recovery has complete coverage");
    for ([_][]const u8{ "semantic", "skip", "malformed" }) |mode| {
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = mode_path, .data = mode });
        try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = count_path, .data = "0" });
        const failed_output = try std.fmt.allocPrint(h.a, "{s}/cold-failed-{s}", .{ dir, mode });
        _ = try h.run(&.{ blob_builder, dump, failed_output, "--expander-root", root, "--workers", "1" }, 1);
        try h.require(!exists(h.io, try std.fs.path.join(h.a, &.{ failed_output, "page-coverage.json" })), "unsuccessful cold replay cannot publish coverage");
    }
}

fn expansionFallbackProbe(h: *Harness, blob_builder: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const root = try std.fs.path.join(h.a, &.{ dir, "failure-root" });
    try std.Io.Dir.cwd().createDirPath(h.io, root);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ root, "namespace-registry.tsv" }), .data = @import("namespace_registry").english_test_fixture });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ root, "manifest.jsonl" }), .data = "" });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = try std.fs.path.join(h.a, &.{ root, "language-registry.tsv" }),
        .data = "# wikidict-language-registry-v2\n" ++
            "# content-language\ten\n" ++
            "# mediawiki\n" ++
            "en\tEnglish\ten\teng\n" ++
            "# iso-639-3\n",
    });
    const script = try std.fs.path.join(h.a, &.{ root, "dict-bundle-expander" });
    try writeFailureExpander(h, script, "expand");

    const dump = try std.fs.path.join(h.a, &.{ dir, "failure-page.txt" });
    const source_text = "==English==\n# source that must not become synthetic error text\n";
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = dump, .data = source_text });
    const page_index = try std.fs.path.join(h.a, &.{ root, "page-index.tsv" });
    const index_line = try std.fmt.allocPrint(h.a, "0\t{d}\tfailure-page\t\t1\t1\t20260901000000\t\twikitext\t0\t1\t0\n", .{source_text.len});
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = page_index, .data = index_line });

    const output = try std.fs.path.join(h.a, &.{ dir, "failure-dictionary" });
    _ = try h.run(&.{ blob_builder, dump, output, "--expander-root", root, "--workers", "1" }, 0);
    _ = try h.run(&.{ verifier, output }, 0);
    const report_path = try std.fs.path.join(h.a, &.{ output, "fallback-pages.jsonl" });
    const report = try std.Io.Dir.cwd().readFileAlloc(h.io, report_path, h.a, .unlimited);
    var parsed = try std.json.parseFromSlice(std.json.Value, h.a, std.mem.trim(u8, report, " \t\r\n"), .{});
    defer parsed.deinit();
    const reasons = parsed.value.object.get("reasons") orelse return error.InvalidFallbackReport;
    try h.require(reasons == .array and reasons.array.items.len == 2, "operational fallback report contains generic and precise reasons");
    try h.require(std.mem.eql(u8, reasons.array.items[0].string, "expansion_error"), "operational fallback report names expansion category");
    try h.require(std.mem.eql(u8, reasons.array.items[1].string, "expansion_error:expand:E"), "operational fallback report preserves worker stage and error name");
    const text = try h.run(&.{ bin, "lookup", "failure-page", "--root", output, "--language", "English", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, text, "Script error") == null and std.mem.indexOf(u8, text, "source that must not become synthetic") == null, "operational fallback publishes no invented or original body text");

    for ([_][]const u8{ "assets", "request", "install", "unknown" }) |stage| {
        try writeFailureExpander(h, script, stage);
        const failed_output = try std.fmt.allocPrint(h.a, "{s}/infrastructure-{s}", .{ dir, stage });
        _ = try h.run(&.{ blob_builder, dump, failed_output, "--expander-root", root, "--workers", "1" }, 1);
        try h.require(!exists(h.io, try std.fs.path.join(h.a, &.{ failed_output, "page-coverage.json" })), "infrastructure failures cannot publish coverage");
    }

    // Real framed worker response, rather than a local allocator failure.
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = script, .data = "#!/bin/sh\n" ++
        "dd bs=4096 count=1 of=/dev/null 2>/dev/null\n" ++
        "printf '\\036\\000\\000\\000\\001\\006\\000\\000\\000\\013\\000\\000\\000\\000\\000\\000\\000expandOutOfMemory'\n" });
    var exhausted = expander.Worker.init(h.io, root, script, dump);
    defer exhausted.deinit();
    try std.testing.expectError(error.OutOfMemory, exhausted.expand(h.a, 0, "probe", source_text));
    try h.require(exhausted.child == null, "exhausted worker is retired");
    try h.require(std.mem.eql(u8, exhausted.last_failure.?.error_name, "OutOfMemory"), "remote OOM retains diagnostics");
    const oom_output = try std.fs.path.join(h.a, &.{ dir, "oom-dictionary" });
    _ = try h.run(&.{ blob_builder, dump, oom_output, "--expander-root", root, "--workers", "1" }, 1);
    try h.require(!exists(h.io, try std.fs.path.join(h.a, &.{ oom_output, "page-coverage.json" })), "remote OOM cannot publish successful coverage");
    const oom_shards = try std.fs.path.join(h.a, &.{ dir, "oom-shards" });
    _ = try h.run(&.{ blob_builder, dump, oom_shards, "--expander-root", root, "--workers", "1", "--shard-pages", "1", "--limit-pages", "1", "--index-byte-offset", "0" }, 1);
    try h.require(!exists(h.io, try std.fs.path.join(h.a, &.{ oom_shards, "00000000" })), "remote OOM cannot publish a continuous shard");

    try coldRetryProbe(h, blob_builder, verifier, root, dump, dir);

    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = script, .data = "#!/bin/sh\nexec tail -f /dev/null\n" });
    const timed_out = try std.fs.path.join(h.a, &.{ dir, "timeout-dictionary" });
    try h.requireTimeout(&.{ blob_builder, dump, timed_out, "--expander-root", root, "--workers", "1", "--expansion-timeout-ms", "100" });
    try h.require(!exists(h.io, try std.fs.path.join(h.a, &.{ timed_out, "page-coverage.json" })), "timed-out build cannot publish successful coverage");
    const timed_shards = try std.fs.path.join(h.a, &.{ dir, "timeout-shards" });
    try h.requireTimeout(&.{ blob_builder, dump, timed_shards, "--expander-root", root, "--workers", "1", "--shard-pages", "1", "--limit-pages", "1", "--index-byte-offset", "0", "--expansion-timeout-ms", "100" });
    try h.require(!exists(h.io, try std.fs.path.join(h.a, &.{ timed_shards, "00000000" })), "timed-out continuous shard cannot publish");
}

fn compilerPipelineProbe(h: *Harness, compiler: []const u8, leaf_bc: []const u8, dir: []const u8) !void {
    const root = try std.fs.path.join(h.a, &.{ dir, "compiler-probe" });
    try std.Io.Dir.cwd().createDirPath(h.io, root);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ root, "namespace-registry.tsv" }), .data = @import("namespace_registry").english_test_fixture });
    const manifest = try std.fs.path.join(h.a, &.{ root, "manifest.jsonl" });
    const usage_path = try std.fs.path.join(h.a, &.{ root, "lua-usage.tsv" });
    const unused = try std.fs.path.join(h.a, &.{ root, "unused.lua" });
    const root_source = try std.fs.path.join(h.a, &.{ root, "root.lua" });
    try std.Io.Dir.cwd().writeFile(h.io, .{
        .sub_path = manifest,
        .data = "{\"page_id\":1,\"title\":\"Module:Root\",\"path\":\"root.lua\",\"bytes\":100}\n" ++
            "{\"page_id\":2,\"title\":\"Module:Dependency\",\"path\":\"dependency.lua\",\"bytes\":100}\n" ++
            "{\"page_id\":3,\"title\":\"Module:Unused\",\"path\":\"unused.lua\",\"bytes\":100}\n",
    });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = root_source, .data = "local d = require('Module:Alias'); return {run=function() return d end}" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ root, "dependency.lua" }), .data = "return {run=function() return require('Module:Root') end}" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ root, "module-redirects.tsv" }), .data = "M\tModule:Alias\tModule:Dependency\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = usage_path, .data = "P\tModule:Root\t1\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = unused, .data = "this is deliberately invalid Lua !!!" });
    const serial = try std.fs.path.join(h.a, &.{ root, "serial" });
    const parallel = try std.fs.path.join(h.a, &.{ root, "parallel" });
    _ = try h.run(&.{ compiler, manifest, root, serial, "--parse-workers", "1", "--value-leaf-bc", leaf_bc }, 0);
    _ = try h.run(&.{ compiler, manifest, root, parallel, "--parse-workers", "4", "--value-leaf-bc", leaf_bc }, 0);
    const plan = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ serial, "compile-plan.tsv" }), h.a, .unlimited);
    const parallel_plan = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ parallel, "compile-plan.tsv" }), h.a, .unlimited);
    try h.require(std.mem.eql(u8, plan, parallel_plan), "parallel parsing preserves deterministic plans through redirects and cycles");
    try h.require(std.mem.count(u8, plan, "\n") == 4, "unreachable invalid Lua is never parsed");
    const serial_metadata = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ serial, "program.meta" }), h.a, .unlimited);
    const parallel_metadata = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ parallel, "program.meta" }), h.a, .unlimited);
    try h.require(std.mem.eql(u8, serial_metadata, parallel_metadata), "parallel parsing preserves emitted program metadata");
    // A dynamic target must widen conservatively and surface the syntax error;
    // failure must drain/join parser workers rather than hanging the process.
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = usage_path, .data = "D\tmodule\n" });
    _ = try h.run(&.{ compiler, manifest, root, parallel, "--analysis-only", "--parse-workers", "4" }, 1);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = usage_path, .data = "P\tModule:Root\t1\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = root_source, .data = "return {run=function(name) return require(name) end}" });
    _ = try h.run(&.{ compiler, manifest, root, parallel, "--analysis-only", "--parse-workers", "4" }, 1);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = unused, .data = "return {ok=true}" });
    _ = try h.run(&.{ compiler, manifest, root, parallel, "--analysis-only", "--parse-workers", "4" }, 0);
}

fn localizedEditionProbe(h: *Harness, pipeline: []const u8, verifier: []const u8, bin: []const u8, dir: []const u8) !void {
    const namespaces = @import("namespace_registry");
    const german_root = try std.fs.path.join(h.a, &.{ dir, "german-dictionary" });
    const german_xml = try std.fs.path.join(h.a, &.{ dir, "german.xml" });
    const german_ns = try std.fs.path.join(h.a, &.{ dir, "german-namespaces.tsv" });
    const german_languages = try std.fs.path.join(h.a, &.{ dir, "german-languages.tsv" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = german_ns, .data = namespaces.german_test_fixture });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = german_languages, .data = "# wikidict-language-registry-v2\n# content-language\tde\n# mediawiki\nde\tDeutsch\tde\tdeu\n# iso-639-3\n" });
    try writePages(h.io, h.a, german_xml, &.{
        .{ .title = "Wort", .ns = 0, .id = 1, .body = "==Deutsch==\n===Substantiv===\n# {{:Template:Probe}}\n" },
        .{ .title = "Vorlage:Probe", .ns = 10, .id = 2, .body = "{{#in<!-- join -->voke:Probe|run}}" },
        .{ .title = "Modul:Probe", .ns = 828, .id = 3, .body = "local export = {}; function export.run(frame) " ++
            "assert(require('math') == math); local ns = mw.site.namespaces; " ++
            "assert(ns.Template.name == 'Vorlage' and ns.Module.name == 'Modul'); " ++
            "assert(ns.Rhymes == nil and ns[106].name == 'Reim'); " ++
            "assert(mw.title.new('Module:Data').prefixedText == 'Modul:Data'); " ++
            "local data = require('Module:Alias'); " ++
            "assert(mw.loadData('Modul:Data').word == data.word); " ++
            "package.loaded['Module:Alias'] = false; assert(require('Module:Alias') == false); " ++
            "return data.word end; return export" },
        .{ .title = "Modul:Data", .ns = 828, .id = 4, .body = "return {word='localized native module'}" },
        .{ .title = "Modul:Alias", .ns = 828, .id = 5, .body = "#REDIRECT [[Module:Data]]", .redirect = "Module:Data" },
        .{ .title = "Modul:math", .ns = 828, .id = 6, .body = "return {wrong_builtin=true}" },
        .{ .title = "Flexion:gehen", .ns = 108, .id = 7, .body = "Supplemental German inflection." },
    });
    _ = try h.run(&.{ pipeline, german_xml, german_root, "--namespace-registry-snapshot", german_ns, "--language-registry-snapshot", german_languages, "--llvm-workers", "1", "--page-workers", "1", "--now-unix", "1791072000" }, 0);
    _ = try h.run(&.{ verifier, german_root }, 0);
    const word = try h.run(&.{ bin, "lookup", "Wort", "--root", german_root, "--language", "Deutsch", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, word, "localized native module") != null, "localized templates, invokes, module aliases and raw package overrides survive native compilation");
    const inflection = try h.run(&.{ bin, "lookup", "Flexion:gehen", "--root", german_root, "--kind", "supplemental", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, inflection, "Supplemental German inflection") != null, "custom German subject namespaces are retained");
    const french_root = try std.fs.path.join(h.a, &.{ dir, "french-dictionary" });
    const french_xml = try std.fs.path.join(h.a, &.{ dir, "french.xml" });
    const french_ns = try std.fs.path.join(h.a, &.{ dir, "french-namespaces.tsv" });
    const french_languages = try std.fs.path.join(h.a, &.{ dir, "french-languages.tsv" });
    const french_files = try std.fs.path.join(h.a, &.{ dir, "french-file-metadata.tsv" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = french_ns, .data = namespaces.french_test_fixture });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = french_languages, .data = "# wikidict-language-registry-v2\n# content-language\tfr\n# mediawiki\nfr\tfrançais\tfr\tfra\n# iso-639-3\n" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = french_files, .data = "Fichier:Example.svg\t1\t640\t480\nFichier:Missing.svg\t0\t0\t0\n" });
    try writePages(h.io, h.a, french_xml, &.{
        .{ .title = "mot", .ns = 0, .id = 11, .body = "==français==\n# Un mot. [[Catégorie:Exemple]]\n" ++
            "# {{#invoke:MetadataProbe|run}}\n" ++
            "# {{#ifexist:Média:Example.svg|existing-media-confirmed|wrong-existing-media}} / {{#ifexist:Media:Missing.svg|wrong-missing-media|missing-media-confirmed}}\n" },
        .{ .title = "Thésaurus:mot", .ns = 106, .id = 12, .body = "French thesaurus content." },
        .{ .title = "Conjugaison:aller", .ns = 116, .id = 13, .body = "French conjugation content." },
        .{ .title = "Racine:aller", .ns = 118, .id = 14, .body = "French root content." },
        .{ .title = "Module:MetadataProbe", .ns = 828, .id = 15, .body = "return {run=function() " ++
            "assert(mw.title.new('Thésaurus:mot').isContentPage); " ++
            "assert(mw.title.new('Annexe:missing').isContentPage); " ++
            "assert(not mw.title.new('Discussion Thésaurus:mot').isContentPage); " ++
            "assert(mw.title.new('Sujet:missing').contentModel == 'flow-board'); " ++
            "for _, prefix in ipairs({'Fichier:', 'File:', 'Image:', 'Média:', 'Media:'}) do " ++
            "local present = mw.title.new(prefix .. 'Example.svg'); " ++
            "assert(present.file.exists and present.fileExists); " ++
            "assert(present.file.width == 640 and present.file.height == 480); " ++
            "local absent = mw.title.new(prefix .. 'Missing.svg'); " ++
            "assert(not absent.file.exists and not absent.fileExists); " ++
            "if prefix == 'Média:' or prefix == 'Media:' then assert(present.exists and not absent.exists) end; " ++
            "end; return 'French native metadata verified' end}" },
    });
    _ = try h.run(&.{ pipeline, french_xml, french_root, "--namespace-registry-snapshot", french_ns, "--language-registry-snapshot", french_languages, "--file-metadata-snapshot", french_files, "--llvm-workers", "1", "--page-workers", "1", "--now-unix", "1791072000" }, 0);
    _ = try h.run(&.{ verifier, french_root }, 0);
    const thesaurus = try h.run(&.{ bin, "lookup", "mot", "--root", french_root, "--kind", "thesaurus", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, thesaurus, "French thesaurus content") != null, "French namespace106 routes to thesaurus rather than English rhymes");
    for ([_][]const u8{ "Conjugaison:aller", "Racine:aller" }) |title| {
        const text = try h.run(&.{ bin, "lookup", title, "--root", french_root, "--kind", "supplemental", "--details" }, 0);
        try h.require(std.mem.indexOf(u8, text, "content") != null, "distinct supplemental namespace titles do not collide");
    }
    const french_word = try h.run(&.{ bin, "lookup", "mot", "--root", french_root, "--language", "français", "--details" }, 0);
    try h.require(std.mem.indexOf(u8, french_word, "Catégorie:Exemple") == null, "localized category membership stays metadata rather than visible prose");
    try h.require(std.mem.indexOf(u8, french_word, "French native metadata verified") != null, "localized content flags, default models and file metadata survive native compilation");
    try h.require(std.mem.indexOf(u8, french_word, "existing-media-confirmed") != null and std.mem.indexOf(u8, french_word, "missing-media-confirmed") != null, "localized media existence uses the pinned file snapshot");

    const supplemental_path = try std.fs.path.join(h.a, &.{ french_root, "supplemental.wikblb" });
    const complete = try std.Io.Dir.cwd().readFileAlloc(h.io, supplemental_path, h.a, .limited(1024 * 1024));
    const smaller = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ german_root, "supplemental.wikblb" }), h.a, .limited(1024 * 1024));
    errdefer std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = supplemental_path, .data = complete }) catch {};
    // The German blob is valid but has one record; French coverage requires two.
    for ([_]?[]const u8{ null, smaller }) |replacement| {
        if (replacement) |bytes| {
            try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = supplemental_path, .data = bytes });
        } else try std.Io.Dir.cwd().deleteFile(h.io, supplemental_path);
        const rejected = try std.process.run(h.a, h.io, .{
            .argv = &.{ verifier, french_root },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } }).toDeadline(h.io),
        });
        try h.require(rejected.term == .exited and rejected.term.exited == 1 and std.mem.indexOf(u8, rejected.stderr, "NamespaceCoverageRecordMismatch") != null, "missing or incomplete feature blobs fail namespace record coverage");
        h.checks += 1;
    }
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = supplemental_path, .data = complete });
    _ = try h.run(&.{ verifier, french_root }, 0);
}

fn usageRebuildProbe(h: *Harness, extractor: []const u8, dir: []const u8) !void {
    const root = try std.fs.path.join(h.a, &.{ dir, "usage-rebuild" });
    try std.Io.Dir.cwd().createDirPath(h.io, root);
    const ns = try std.fs.path.join(h.a, &.{ root, "namespace-registry.tsv" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = ns, .data = @import("namespace_registry").english_test_fixture });
    const dump = try std.fs.path.join(h.a, &.{ dir, "usage.xml" });
    try writePages(h.io, h.a, dump, &.{
        .{ .title = "word", .ns = 0, .id = 1, .body = "==English==\n# {<!--join-->{:User:Example}}" },
        .{ .title = "User:Example", .ns = 2, .id = 2, .body = "{{Probe}}" },
        .{ .title = "Template:Probe", .ns = 10, .id = 3, .body = "{{#invoke:Probe|run}}" },
        .{ .title = "Module:Probe", .ns = 828, .id = 4, .body = "return {run=function() return 'ok' end}" },
        .{ .title = "word", .ns = 0, .id = 5, .body = "==English==\n# {{Probe}}" },
    });
    _ = try h.run(&.{ extractor, dump, root, "--page-index" }, 0);
    const names = [_][]const u8{ "manifest.jsonl", "module-redirects.tsv", "page-index.tsv", "page-title-index.bin", "template-source.bin", "template-source.idx", "modules/4.lua", "compiler-inputs.ready", "lua-usage.tsv", "extraction-source.json" };
    var before: [names.len][]const u8 = undefined;
    for (names, 0..) |name, i| before[i] = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, name }), h.a, .limited(8 * 1024 * 1024));
    const worker = try std.fs.path.join(h.a, &.{ root, "dict-bundle-expander" });
    const incomplete = try std.fs.path.join(h.a, &.{ root, ".incomplete" });
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = worker, .data = "synthetic worker witness" });
    _ = try h.run(&.{ extractor, dump, root, "--usage-only" }, 0);
    try h.require(!exists(h.io, incomplete), "identical usage preserves native readiness");
    for (names, 0..) |name, i| {
        const after = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, name }), h.a, .limited(8 * 1024 * 1024));
        try h.require(std.mem.eql(u8, before[i], after), "usage-only preserves all extraction assets and exact usage");
    }
    const replacement = try std.fs.path.join(h.a, &.{ dir, "different-usage.xml" });
    const raw = try std.Io.Dir.cwd().readFileAlloc(h.io, dump, h.a, .limited(8 * 1024 * 1024));
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = replacement, .data = raw });
    _ = try h.run(&.{ extractor, replacement, root, "--usage-only" }, 1);
    const usage = try std.Io.Dir.cwd().readFileAlloc(h.io, try std.fs.path.join(h.a, &.{ root, "lua-usage.tsv" }), h.a, .limited(8 * 1024 * 1024));
    try h.require(std.mem.eql(u8, before[8], usage), "different source preserves old usage");
    const lock = try std.Io.Dir.cwd().openFile(h.io, try std.fs.path.join(h.a, &.{ root, ".compiler-inputs.lock" }), .{ .lock = .shared });
    _ = try h.run(&.{ extractor, dump, root, "--usage-only" }, 1);
    lock.close(h.io);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = incomplete, .data = "building" });
    _ = try h.run(&.{ extractor, dump, root, "--usage-only" }, 1);
    try std.Io.Dir.cwd().deleteFile(h.io, incomplete);
    try std.Io.Dir.cwd().writeFile(h.io, .{ .sub_path = try std.fs.path.join(h.a, &.{ root, "lua-usage.tsv" }), .data = "# stale graph\n" });
    _ = try h.run(&.{ extractor, dump, root, "--usage-only" }, 0);
    try h.require(exists(h.io, incomplete), "changed usage invalidates linked native worker");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(a);
    if (argv.len != 9) return error.Usage;
    const bin = argv[1];
    const pipeline = argv[2];
    const verifier = argv[3];
    const dir = try std.fmt.allocPrint(a, "{s}/bundle-integration-{d}-{d}", .{
        argv[4], std.os.linux.getpid(), std.Io.Clock.awake.now(init.io).toNanoseconds(),
    });
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    var h: Harness = .{ .a = a, .io = init.io };

    try usageRebuildProbe(&h, argv[8], dir);
    try compilerPipelineProbe(&h, argv[5], argv[7], dir);
    try localizedEditionProbe(&h, pipeline, verifier, bin, dir);
    try deadlineProbe(init.io, a, dir);
    try failureMetadataProbe(&h, dir);
    try expansionFallbackProbe(&h, argv[6], verifier, bin, dir);
    h.checks += 1;

    const dump = try std.fs.path.join(a, &.{ dir, "fixture.xml" });
    try writeFixture(init.io, a, dump);

    // Small editions may use no Lua at all; they still need a native bundle worker.
    const plain_dump = try std.fs.path.join(a, &.{ dir, "plain.xml" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = plain_dump,
        .data = "<mediawiki><page><title>plain</title><ns>0</ns><id>1</id><revision><id>1</id>" ++
            "<timestamp>2026-09-01T00:00:00Z</timestamp><contributor><username>Test</username></contributor>" ++
            "<model>wikitext</model><format>text/x-wiki</format><text>==English==\n===Noun===\n# A plain word.\n</text></revision></page></mediawiki>",
    });
    const language_registry = try std.fs.path.join(a, &.{ dir, "language-registry.tsv" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = language_registry,
        .data = "# wikidict-language-registry-v2\n" ++
            "# content-language\ten\n" ++
            "# mediawiki\n" ++
            "en\tEnglish\ten\teng\n" ++
            "# iso-639-3\n",
    });
    const namespace_registry = try std.fs.path.join(a, &.{ dir, "namespace-registry.tsv" });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = namespace_registry, .data = @import("namespace_registry").english_test_fixture });
    const plain_root = try std.fs.path.join(a, &.{ dir, "plain-dictionary" });
    _ = try h.run(&.{ pipeline, plain_dump, plain_root, "--namespace-registry-snapshot", namespace_registry, "--language-registry-snapshot", language_registry }, 0);
    _ = try h.run(&.{ verifier, plain_root }, 0);

    const existing_root = try std.fs.path.join(a, &.{ dir, "existing-dictionary" });
    try std.Io.Dir.cwd().createDir(init.io, existing_root, .default_dir);
    _ = try h.run(&.{ pipeline, dump, existing_root }, 1);
    const existing_marker = try std.fs.path.join(a, &.{ existing_root, ".incomplete" });
    try h.require(!exists(init.io, existing_marker), "existing output directory stays untouched");

    const failed_root = try std.fs.path.join(a, &.{ dir, "failed-dictionary" });
    const missing_dump = try std.fs.path.join(a, &.{ dir, "missing.xml" });
    _ = try h.run(&.{ pipeline, missing_dump, failed_root }, 1);
    const failed_marker = try std.fs.path.join(a, &.{ failed_root, ".incomplete" });
    try h.require(exists(init.io, failed_marker), "failed build retains incomplete marker");

    const category_snapshot = try std.fs.path.join(a, &.{ dir, "category-tree.tsv" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = category_snapshot,
        .data = "Integration_categories\tmain\tmouse\nIntegration_categories\tpages\tmouse\tTalk:Category discussion\tCategory:Nested category\n",
    });
    const root = try std.fs.path.join(a, &.{ dir, "dictionary" });
    _ = try h.run(&.{ pipeline, dump, root, "--namespace-registry-snapshot", namespace_registry, "--category-tree-snapshot", category_snapshot, "--language-registry-snapshot", language_registry, "--llvm-workers", "1", "--page-workers", "2" }, 0);
    _ = try h.run(&.{ verifier, root }, 0);
    const language_manifest_path = try std.fs.path.join(a, &.{ root, "languages.tsv" });
    const language_manifest = try std.Io.Dir.cwd().readFileAlloc(init.io, language_manifest_path, a, .limited(4096));
    try h.require(std.mem.indexOf(u8, language_manifest, "Unclassified") == null, "content-language fallback never publishes Unclassified");

    const forbidden = [_][]const u8{
        ".bundle-expander", "runtime",          "dict-bundle-expander",
        "symbols.wikblb",   "templates.wikblb", "redirects.wikblb",
        "pages.wikblb",
    };
    for (forbidden) |name| {
        const path = try std.fs.path.join(a, &.{ root, name });
        try h.require(!exists(init.io, path), name);
    }
    const incomplete = try std.fs.path.join(a, &.{ root, ".incomplete" });
    try h.require(!exists(init.io, incomplete), "completed bundle marker removed");

    const text = try h.run(&.{ bin, "lookup", "mouse", "--root", root, "--details" }, 0);
    try h.require(std.mem.indexOf(u8, text, "Talk:Category discussion") != null and std.mem.indexOf(u8, text, "Nested category") != null, "default CategoryTree pages mode compiles other namespaces and subcategory links");
    try h.require(std.mem.indexOf(u8, text, "plural mice") != null, "Lua result is baked into data");
    try h.require(std.mem.indexOf(u8, text, "user-space inflection mouse") != null, "User namespace transclusion and relative child expand before publication");
    try h.require(std.mem.indexOf(u8, text, "User:Absent") != null and std.mem.indexOf(u8, text, "Absent article") != null and std.mem.indexOf(u8, text, "Category:Absent") != null, "missing transclusions in every namespace compile to semantic links");
    try h.require(std.mem.indexOf(u8, text, "private documentation") == null, "User namespace noinclude remains excluded");
    try h.require(std.mem.indexOf(u8, text, "{|") == null and std.mem.indexOf(u8, text, "templatestyles") == null, "wrapped wiki tables survive semantic encoding without source markup");
    try h.require(std.mem.indexOf(u8, text, "Forms from native Lua") != null, "template result is baked into data");
    try h.require(std.mem.indexOf(u8, text, "shared main transclusion") != null, "main-page redirect transclusion is baked into data");
    try h.require(std.mem.indexOf(u8, text, "project namespace transclusion") != null, "namespace-alias transclusion is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Styled kanji: 兇 / 凶") != null, "emphasized HTML compiles to semantic styled text and links");
    try h.require(std.mem.indexOf(u8, text, "Title magic: Wiktionary / Wiktionary talk") != null, "title magic words are resolved before publication");
    try h.require(std.mem.indexOf(u8, text, "Parser functions: 2013 Apr 08 / 2 January 2010 / γ / ERR") != null, "corpus parser functions are baked into data");
    try h.require(std.mem.indexOf(u8, text, "Synth fork: synth:forked") != null, "synthesized roots materialize in fresh invoke contexts");
    try h.require(std.mem.indexOf(u8, text, "Pure fork: x") != null, "pure-data roots materialize independently in fresh invoke contexts");
    try h.require(std.mem.indexOf(u8, text, "Captured fork: captured:forked") != null, "synthesized callable roots rebuild scalar capture cells in fresh invoke contexts");
    try h.require(std.mem.indexOf(u8, text, "Repair recovery: repaired invoke") != null, "invalid-title invoke retries entity-escaped inline modifiers once");
    try h.require(std.mem.indexOf(u8, text, "Graceful Lua error: Lua error in Module:IntegrationForms: fixture failure") != null, "unrepaired Scribunto failures compile as inert error text");
    try h.require(std.mem.indexOf(u8, text, "Formatting magic: 11,000 / 1234.50 / A_B_x_C") != null, "formatting magic is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Title parts: B / A/B") != null, "titleparts is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Escaped title: A_B/%C3%A9%3Fx / Appendix:A_B/%C3%A9%3Fx") != null, "escaped title magic is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Subpage namespaces: foo / foo/bar") != null, "namespace subpage semantics are baked into data");
    try h.require(std.mem.indexOf(u8, text, "Site magic: //en.wiktionary.org / en.wiktionary.org") != null, "site URL magic is baked into data");
    try h.require(std.mem.indexOf(u8, text, "Revision metadata: 20 / 120 / 20240304050607 / Fixture editor / 22 / Rat editor") != null, "page revision metadata is baked into data");
    try h.require(std.mem.indexOf(u8, text, "ordinary namespace distinct") != null, "Template namespace alias resolves through corpus transclusion");
    try h.require(std.mem.indexOf(u8, text, "Documentation") == null, "noinclude does not leak");
    try h.require(std.mem.indexOf(u8, text, "#invoke") == null, "no executable invoke syntax survives");

    const exported = try h.run(&.{ bin, "export", "mouse", "--root", root }, 0);
    var exported_json = try std.json.parseFromSlice(std.json.Value, a, exported, .{});
    defer exported_json.deinit();
    const exported_entries = exported_json.value.object.get("entries") orelse return error.InvalidExport;
    try h.require(exported_entries == .array and exported_entries.array.items.len == 1, "compiled export contains the requested entry");
    const exported_entry = exported_entries.array.items[0].object;
    const display_title = exported_entry.get("display_title") orelse return error.InvalidExport;
    try h.require(display_title == .array and display_title.array.items.len == 1, "DISPLAYTITLE survives publication as semantic spans");
    const display_span = display_title.array.items[0].object;
    try h.require(std.mem.eql(u8, display_span.get("text").?.string, "mouse"), "display-title text remains the canonical page name");
    try h.require(display_span.get("italic").?.bool, "display-title emphasis is compiled into presentation data");
    try h.require(std.mem.eql(u8, exported_entry.get("title").?.string, "mouse"), "display title does not replace the canonical lookup key");
    try h.require(std.mem.eql(u8, exported_entry.get("language_code").?.string, "en"), "language code comes from extracted canonical-name module metadata");

    std.debug.print(
        "BUNDLE_INTEGRATION_PASS checks={d}: destination refusal, incomplete failure marker, verified pre-expanded Lua/templates, data-only final tree. Artifacts: {s}\n",
        .{ h.checks, dir },
    );
}
